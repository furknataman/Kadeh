//
//  Playtime.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

/// How long something has been played and when it last was.
public struct Playtime: Equatable, Sendable {
    public var seconds: TimeInterval
    public var lastPlayed: Date?

    public init(seconds: TimeInterval, lastPlayed: Date?) {
        self.seconds = seconds
        self.lastPlayed = lastPlayed
    }
}

/// What Steam itself recorded for one game.
public struct SteamPlayRecord: Equatable, Sendable {
    /// Account total, other PCs included: that is what Steam keeps.
    public let minutes: Int
    public let lastPlayed: Date?
    /// When the game last started, from Steam Cloud's own bookkeeping. Used
    /// to tell which folders the last session wrote to.
    public let lastLaunch: Date?

    public var playtime: Playtime { Playtime(seconds: TimeInterval(minutes) * 60, lastPlayed: lastPlayed) }
}

/// Reads Steam's own playtime out of a bottle's Steam install.
///
/// Steam keeps it per account in `userdata/<account>/config/localconfig.vdf`,
/// under `UserLocalConfigStore › Software › Valve › Steam › apps › <appid>`,
/// and writes the file when a game exits. Reading Steam's record rather than
/// timing launches means a game played before Kadeh, or on another PC, shows
/// its real total.
public enum SteamPlaytimeReader {
    /// The difference between a SteamID64 and the account id `userdata` uses.
    static let steamID64Base: UInt64 = 76_561_197_960_265_728

    /// Every game's record in the bottle, keyed by App ID. Empty without Steam.
    ///
    /// Cached by the file's modification date, so the library can ask on every
    /// refresh and only pay for a parse when Steam has written.
    public static func records(inBottleAt bottleURL: URL) -> [Int: SteamPlayRecord] {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL),
              let url = localConfigURL(steamRoot: steamRoot)
        else { return [:] }
        return cache.records(at: url)
    }

    /// Waits, up to a minute, for Steam to write its record after a game ended.
    ///
    /// Steam writes `localconfig.vdf` as the game exits, a little after the
    /// process is gone, so this watches the file rather than guessing a
    /// delay. A write from shortly before `date` counts: the session watcher
    /// notices an exit up to one poll late.
    public static func waitForWrite(inBottleAt bottleURL: URL, after date: Date) async {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !Task.isCancelled {
            let modified = await Task.detached { () -> Date? in
                guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL),
                      let url = localConfigURL(steamRoot: steamRoot)
                else { return nil }
                let path = url.path(percentEncoded: false)
                return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }.value
            guard let modified else { return }
            if modified >= date.addingTimeInterval(-30) { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The account folder in `userdata` that belongs to whoever last signed in.
    public static func accountFolder(steamRoot: URL) -> URL? {
        let userdata = steamRoot.appending(path: "userdata")
        let loginUsers = steamRoot.appending(path: "config").appending(path: "loginusers.vdf")
        if let text = try? String(contentsOf: loginUsers, encoding: .utf8),
           let steamID = mostRecentSteamID(loginUsers: text),
           let account = accountID(steamID64: steamID) {
            let folder = userdata.appending(path: account)
            if FileManager.default.fileExists(atPath: localConfig(in: folder).path(percentEncoded: false)) {
                return folder
            }
        }
        return newestAccountFolder(userdata: userdata)
    }

    /// `localconfig.vdf` of the account ``accountFolder(steamRoot:)`` picks.
    public static func localConfigURL(steamRoot: URL) -> URL? {
        accountFolder(steamRoot: steamRoot).map { localConfig(in: $0) }
    }

    private static func localConfig(in accountFolder: URL) -> URL {
        accountFolder.appending(path: "config").appending(path: "localconfig.vdf")
    }

    /// The account folder whose `localconfig.vdf` is newest, `0` (the
    /// anonymous account) aside.
    static func newestAccountFolder(userdata: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: userdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { $0.lastPathComponent != "0" }
            .compactMap { folder -> (URL, Date)? in
                let config = localConfig(in: folder).path(percentEncoded: false)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: config),
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return (folder, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// The SteamID64 `loginusers.vdf` marks as most recent.
    ///
    /// Not every file has `MostRecent` (the user's own does not), so the
    /// newest `timestamp` decides when it is missing.
    static func mostRecentSteamID(loginUsers text: String) -> String? {
        guard let users = (try? VDFParser.parse(text))?["users"]?.objectValue else { return nil }
        if let marked = users.first(where: { $0.value.objectValue?["mostrecent"]?.stringValue == "1" }) {
            return marked.key
        }
        return users.max { lhs, rhs in
            (lhs.value.objectValue?["timestamp"]?.intValue ?? 0) < (rhs.value.objectValue?["timestamp"]?.intValue ?? 0)
        }?.key
    }

    /// `userdata` names an account by the low 32 bits of its SteamID64.
    static func accountID(steamID64: String) -> String? {
        guard let value = UInt64(steamID64), value > steamID64Base else { return nil }
        return String(value - steamID64Base)
    }

    /// Every app's record in a `localconfig.vdf`.
    ///
    /// `VDFParser` lowercases keys, which is what makes `Playtime` and
    /// `LastPlayed` readable whatever casing this Steam build writes.
    public static func parse(localConfig text: String) -> [Int: SteamPlayRecord] {
        guard let root = try? VDFParser.parse(text),
              let apps = root["userlocalconfigstore"]?.objectValue?["software"]?.objectValue?["valve"]?
              .objectValue?["steam"]?.objectValue?["apps"]?.objectValue
        else { return [:] }

        var records: [Int: SteamPlayRecord] = [:]
        for (key, value) in apps {
            guard let appID = Int(key), let fields = value.objectValue else { continue }
            let minutes = fields["playtime"]?.intValue ?? 0
            let lastPlayed = fields["lastplayed"]?.intValue.flatMap(date(unix:))
            let lastLaunch = fields["autocloud"]?.objectValue?["lastlaunch"]?.intValue.flatMap(date(unix:))
            guard minutes > 0 || lastPlayed != nil else { continue }
            records[appID] = SteamPlayRecord(minutes: minutes, lastPlayed: lastPlayed, lastLaunch: lastLaunch)
        }
        return records
    }

    private static func date(unix: Int) -> Date? {
        unix > 0 ? Date(timeIntervalSince1970: TimeInterval(unix)) : nil
    }

    private static let cache = RecordCache()

    /// Parsed files keyed by path, valid while the file's modification date holds.
    private final class RecordCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (modified: Date, records: [Int: SteamPlayRecord])] = [:]

        func records(at url: URL) -> [Int: SteamPlayRecord] {
            let path = url.path(percentEncoded: false)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                as? Date
            else { return [:] }

            lock.lock()
            let cached = entries[path]
            lock.unlock()
            if let cached, cached.modified == modified { return cached.records }

            // Steam writes this file with whatever bytes a persona name holds,
            // so a strict UTF-8 read can fail on a valid file.
            guard let data = try? Data(contentsOf: url) else { return [:] }
            let records = parse(localConfig: String(decoding: data, as: UTF8.self))

            lock.lock()
            entries[path] = (modified, records)
            lock.unlock()
            return records
        }
    }
}


public extension Playtime {
    /// What a library entry has been played: Steam's record for a Steam game,
    /// which knows about play outside Kadeh, and Kadeh's own count for
    /// anything else. Kadeh's count of a Steam game still lends its date, in
    /// case Steam has not written yet.
    static func combined(
        for entry: LibraryEntry, steam: [Int: SteamPlayRecord], counted: [String: Playtime]
    ) -> Playtime? {
        let own = counted[entry.id]
        guard case let .steam(appID) = entry.launch, let record = steam[appID] else { return own }
        let dates = [record.lastPlayed, own?.lastPlayed].compactMap { $0 }
        return Playtime(seconds: record.playtime.seconds, lastPlayed: dates.max())
    }
}

/// The one queue every playtime file is read and written on.
///
/// Sessions end on detached tasks, and two games ending together used to
/// read the same file, each add its own session and write, so one was lost.
/// A serial queue makes each read-modify-write whole; the writes stay atomic
/// so a crash mid-write leaves the old file.
private let playtimeFileQueue = DispatchQueue(label: "com.furkan.kadeh.playtime-files")

/// Kadeh's own count of how long non-Steam games were played.
///
/// Steam keeps its own record, so this only matters for everything else: a
/// pinned program or a shortcut. One small JSON file, keyed by library entry id.
public struct PlaytimeStore: Sendable {
    public static var defaultURL: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Playtime").appendingPathExtension("json")
    }

    private struct Record: Codable {
        var seconds: TimeInterval
        var sessions: Int
        var lastPlayed: Date
    }

    private let url: URL

    public init(url: URL = PlaytimeStore.defaultURL) {
        self.url = url
    }

    /// Every entry's total, keyed by library entry id.
    public func all() -> [String: Playtime] {
        playtimeFileQueue.sync { load() }.mapValues { Playtime(seconds: $0.seconds, lastPlayed: $0.lastPlayed) }
    }

    /// Adds one session. Sessions under a minute are a launch that went
    /// nowhere, not play, and are not counted.
    public func record(entryID: String, from start: Date, to end: Date) {
        let seconds = end.timeIntervalSince(start)
        guard seconds >= 60 else { return }
        playtimeFileQueue.sync {
            var records = load()
            var record = records[entryID] ?? Record(seconds: 0, sessions: 0, lastPlayed: end)
            record.seconds += seconds
            record.sessions += 1
            record.lastPlayed = max(record.lastPlayed, end)
            records[entryID] = record
            save(records)
        }
    }

    private func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private func save(_ records: [String: Record]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        writeAtomically({ try encoder.encode(records) }, to: url)
    }
}

private func writeAtomically(_ data: () throws -> Data, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: url, options: .atomic)
    } catch {
        Logger.wineKit.error("Failed to write playtime: \(error.localizedDescription)")
    }
}

/// One stretch of play Kadeh saw, for the week-by-week chart.
public struct PlaySession: Codable, Equatable, Sendable {
    public let entryID: String
    public let start: Date
    public let end: Date

    public init(entryID: String, start: Date, end: Date) {
        self.entryID = entryID
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    // Whole seconds and short keys: a year of sessions stays a few dozen KB.
    private enum CodingKeys: String, CodingKey {
        case entryID = "id", start = "s", end = "e"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(String.self, forKey: .entryID)
        start = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .start))
        end = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .end))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryID, forKey: .entryID)
        try container.encode(start.timeIntervalSince1970.rounded(), forKey: .start)
        try container.encode(end.timeIntervalSince1970.rounded(), forKey: .end)
    }
}

/// Every session Kadeh saw, Steam games included, over the last year.
///
/// Display only: totals come from ``PlaytimeStore`` and Steam's own record.
/// Steam keeps no week-by-week history Kadeh could read, so the chart can
/// only ever show what Kadeh itself watched.
public struct PlayHistoryStore: Sendable {
    public static var defaultURL: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "PlayHistory").appendingPathExtension("json")
    }

    /// How far back sessions are kept.
    public static let retention: TimeInterval = 366 * 24 * 3_600

    private let url: URL

    public init(url: URL = PlayHistoryStore.defaultURL) {
        self.url = url
    }

    /// The kept sessions, oldest first.
    public func sessions() -> [PlaySession] {
        playtimeFileQueue.sync { load() }
    }

    /// Adds one session; under a minute is not play and is not kept.
    public func append(entryID: String, from start: Date, to end: Date, now: Date = Date()) {
        guard end.timeIntervalSince(start) >= 60 else { return }
        playtimeFileQueue.sync {
            var sessions = load()
            sessions.append(PlaySession(entryID: entryID, start: start, end: end))
            save(Self.pruned(sessions, now: now))
        }
    }

    /// Sessions that ended within ``retention`` of `now`, oldest first.
    static func pruned(_ sessions: [PlaySession], now: Date) -> [PlaySession] {
        let cutoff = now.addingTimeInterval(-retention)
        return sessions.filter { $0.end >= cutoff }.sorted { $0.start < $1.start }
    }

    private func load() -> [PlaySession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlaySession].self, from: data)) ?? []
    }

    private func save(_ sessions: [PlaySession]) {
        writeAtomically({ try JSONEncoder().encode(sessions) }, to: url)
    }
}

/// Sums over play history for the playtime page.
public enum PlayHistoryStats {
    /// One calendar week's play.
    public struct Week: Identifiable, Equatable, Sendable {
        public let start: Date
        public let seconds: TimeInterval
        public var id: Date { start }
    }

    /// Seconds of play inside `interval`. A session crossing its edge counts
    /// only the part inside, so a night that runs past midnight on Sunday is
    /// split between the two weeks.
    public static func seconds(of sessions: [PlaySession], in interval: DateInterval) -> TimeInterval {
        sessions.reduce(0) { total, session in
            let start = max(session.start, interval.start)
            let end = min(session.end, interval.end)
            return total + max(0, end.timeIntervalSince(start))
        }
    }

    /// Play in the calendar unit (`.weekOfYear`, `.month`) holding `now`.
    public static func seconds(
        of sessions: [PlaySession], inCurrent unit: Calendar.Component, now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        guard let interval = calendar.dateInterval(of: unit, for: now) else { return 0 }
        return seconds(of: sessions, in: interval)
    }

    /// The last `count` calendar weeks, oldest first, this one last. The
    /// calendar decides where a week starts: Monday in Turkey.
    public static func weeks(
        of sessions: [PlaySession], count: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> [Week] {
        guard count > 0, let current = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return (0 ..< count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current.start),
                  let week = calendar.dateInterval(of: .weekOfYear, for: start)
            else { return nil }
            return Week(start: week.start, seconds: seconds(of: sessions, in: week))
        }
    }
}

/// How playtime reads, the same on every screen.
public enum PlaytimeFormat {
    /// One format everywhere: under 10 hours "1 sa. 59 dk." (minutes only:
    /// "45 dk."), from 10 hours "19 sa.". Rounded down, so a minute is
    /// never shown before it is over; nothing played reads "0 dk.".
    ///
    /// Apple's formatter supplies the units, so they follow the language.
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(0, (seconds / 60).rounded(.down))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        if minutes >= 600 {
            formatter.allowedUnits = [.hour]
            return formatter.string(from: (minutes / 60).rounded(.down) * 3_600) ?? ""
        }
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        // "3 sa." rather than "3 sa. 0 dk.", but "0 dk." rather than nothing.
        formatter.zeroFormattingBehavior = minutes == 0 ? .default : .dropAll
        return formatter.string(from: minutes * 60) ?? ""
    }
}
