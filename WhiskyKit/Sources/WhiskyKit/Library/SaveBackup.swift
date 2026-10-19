//
//  SaveBackup.swift
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

import CryptoKit
import Foundation
import os
import os.log

/// The game a backup belongs to: the library entry's id, which is unique
/// across bottles, and its name, which is only for people.
public struct SaveGame: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ entry: LibraryEntry) {
        self.init(id: entry.id, name: entry.name)
    }

    /// Eight hex digits of the id's hash: short enough for a folder name,
    /// stable across renames.
    var shortID: String {
        SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// One backup on disk.
public struct SaveBackup: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Made when the game closed.
        case automatic
        /// Made with "Şimdi yedekle".
        case manual
        /// What was there just before a restore replaced it.
        case safety

        /// The first archives said `regular` for both of the ordinary kinds;
        /// they were nearly all made when the game closed.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .automatic
        }
    }

    public let url: URL
    public let created: Date
    /// The words after the date in the file name, such as the mark a
    /// before-restore backup carries. Empty for an ordinary backup.
    public let label: String
    public let bytes: Int64
    public let kind: Kind
    /// Saved in the old folder named after the game alone, before backups
    /// carried the game's id. Listed and restorable, never pruned: two games
    /// with one name shared that folder, so it cannot say whose they are.
    public let isLegacy: Bool

    public var isSafety: Bool { kind == .safety }
    public var id: URL { url }
}

/// What started an ordinary backup.
public enum SaveBackupTrigger: Sendable {
    /// The game closed. Skipped when nothing changed since the last backup.
    case automatic
    /// The person asked for it; always made.
    case manual

    var kind: SaveBackup.Kind { self == .automatic ? .automatic : .manual }
}

public enum SaveBackupError: LocalizedError, Equatable {
    /// None of the folders exist, so there is nothing to back up.
    case nothingToBackUp
    /// `ditto` failed; the message is its own.
    case archiveFailed(String)
    /// The new archive did not read back intact, so it was thrown away.
    case archiveDamaged
    /// The archive is not one Kadeh made, or is damaged.
    case invalidBackup
    /// The archive belongs to another game.
    case wrongGame
    /// The archive names a folder that is not one of the game's confirmed ones.
    case folderNotConfirmed
    /// A folder resolves to somewhere outside the bottle.
    case outsideBottle
    /// A folder no longer leads where it led when it was confirmed: a link
    /// in its path changed.
    case folderMoved
    /// A save folder and the backup folder are inside one another.
    case overlapsBackupLocation
    /// What is there now could not be backed up, so the restore did nothing.
    case cannotSecureCurrent
    /// The game's saves are being restored right now.
    case restoreInProgress

    public var errorDescription: String? {
        switch self {
        case .nothingToBackUp: String(localized: "saves.error.nothingToBackUp")
        case let .archiveFailed(detail): String(localized: "saves.error.archive \(detail)")
        case .archiveDamaged: String(localized: "saves.error.damaged")
        case .invalidBackup: String(localized: "saves.error.invalid")
        case .wrongGame: String(localized: "saves.error.wrongGame")
        case .folderNotConfirmed: String(localized: "saves.error.notConfirmed")
        case .outsideBottle: String(localized: "saves.error.outsideBottle")
        case .folderMoved: String(localized: "saves.error.folderMoved")
        case .overlapsBackupLocation: String(localized: "saves.error.overlap")
        case .cannotSecureCurrent: String(localized: "saves.error.cannotSecure")
        case .restoreInProgress: String(localized: "saves.error.restoring")
        }
    }

    /// A few lowercase words for "Son yedek alınamadı: …".
    public var shortReason: String {
        switch self {
        case .nothingToBackUp: String(localized: "saves.reason.short.nothingToBackUp")
        case .archiveFailed, .archiveDamaged: String(localized: "saves.reason.short.archive")
        case .overlapsBackupLocation: String(localized: "saves.reason.short.overlap")
        case .restoreInProgress: String(localized: "saves.reason.short.restoring")
        case .invalidBackup, .wrongGame, .folderNotConfirmed, .outsideBottle, .folderMoved, .cannotSecureCurrent:
            errorDescription ?? ""
        }
    }

    static func shortReason(for error: Error) -> String {
        (error as? SaveBackupError)?.shortReason ?? error.localizedDescription
    }
}

/// Zips a game's save folders into a backup folder and puts them back.
///
/// Layout: `<root>/<game name> (<short id>)/<yyyy-MM-dd HH.mm.ss>[ <label>].zip`.
/// Each zip holds one folder with a `kadeh-backup.json` naming the game and
/// where each numbered item came from, so a backup still restores after the
/// confirmed folders change, and can be opened in Finder by anyone.
///
/// Only files whose manifest names the game are ever pruned, and one game's
/// backups and restores run one at a time.
public struct SaveBackupStore: Sendable {
    /// The defaults key for a backup folder the person picked.
    public static let rootDefaultsKey = "saveBackupRoot"
    static let manifestName = "kadeh-backup.json"

    public let root: URL
    /// Backups kept per game of each ordinary kind (automatic, manual), newest first.
    public var keep = 10
    /// Before-restore backups kept per game, apart from the ordinary ones.
    public var keepSafety = 3
    /// Where the outcome of each ordinary backup is recorded; `nil` records nothing.
    public var status: SaveBackupStatusStore?

    public init(root: URL, status: SaveBackupStatusStore? = nil) {
        self.root = root
        self.status = status
    }

    /// The folder in Settings, or the default, recording each backup's outcome.
    public static func configured(defaults: UserDefaults = .standard) -> SaveBackupStore {
        if let path = defaults.string(forKey: rootDefaultsKey), !path.isEmpty {
            return SaveBackupStore(root: URL(filePath: path, directoryHint: .isDirectory), status: .init())
        }
        return SaveBackupStore(root: defaultRoot, status: .init())
    }

    /// iCloud Drive when this Mac has it, so saves survive the Mac; the
    /// Documents folder otherwise.
    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        if FileScan.isDirectory(iCloud) {
            return iCloud.appending(path: "Kadeh").appending(path: "Kayıt Yedekleri", directoryHint: .isDirectory)
        }
        return home.appending(path: "Documents").appending(path: "Kadeh Kayıt Yedekleri", directoryHint: .isDirectory)
    }

    // MARK: - Names

    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }

    /// A game's name made safe for a folder name, as the first backups did it.
    static func folderName(forGame name: String) -> String {
        let cleaned = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Oyun" : String(cleaned.prefix(80))
    }

    /// Also without the characters `unzip` reads as wildcards.
    static func safeName(_ name: String) -> String {
        let cleaned = String(folderName(forGame: name).map { "[]*?{}".contains($0) ? "-" : $0 })
        return cleaned.isEmpty ? "Oyun" : cleaned
    }

    /// `<date>[ <label>]`, without the extension.
    static func fileStem(for date: Date, label: String) -> String {
        let stamp = stampFormatter().string(from: date)
        return label.isEmpty ? stamp : "\(stamp) \(safeName(label))"
    }

    /// The date and label a backup's file name carries, or `nil` for a file
    /// that is not a backup.
    static func parse(fileName: String) -> (created: Date, label: String)? {
        guard fileName.hasSuffix(".zip"), !fileName.hasPrefix(".") else { return nil }
        let stem = String(fileName.dropLast(4))
        let stampLength = 19
        guard stem.count >= stampLength,
              let created = stampFormatter().date(from: String(stem.prefix(stampLength)))
        else { return nil }
        var label = String(stem.dropFirst(stampLength)).trimmingCharacters(in: .whitespaces)
        // A second backup in the same second carries a counter, not a label.
        if label.hasPrefix("("), label.hasSuffix(")"), Int(label.dropFirst().dropLast()) != nil {
            label = ""
        }
        return (created, label)
    }

    /// `<name> (<short id>)`. A folder already there for the id is kept even
    /// when the game's name has changed since.
    public func gameFolder(for game: SaveGame) -> URL {
        let suffix = " (\(game.shortID))"
        if let existing = FileScan.children(of: root).first(where: {
            $0.lastPathComponent.hasSuffix(suffix) && FileScan.isDirectory($0)
        }) {
            return existing
        }
        let name = String(Self.safeName(game.name).prefix(70))
        return root.appending(path: name + suffix, directoryHint: .isDirectory)
    }

    /// Where backups went before they were kept per game id.
    func legacyFolder(forGame name: String) -> URL {
        root.appending(path: Self.folderName(forGame: name), directoryHint: .isDirectory)
    }

    // MARK: - Listing

    /// A game's backups, newest first: the ones whose manifest names the game,
    /// then any from the old name-only folder.
    public func backups(for game: SaveGame) -> [SaveBackup] {
        var result: [SaveBackup] = []
        for file in Self.archives(in: gameFolder(for: game)) {
            guard let parsed = Self.parse(fileName: file.url.lastPathComponent),
                  let manifest = SaveBackupManifestReader.manifest(ofArchive: file.url),
                  manifest.gameID == game.id
            else { continue }
            result.append(SaveBackup(
                url: file.url, created: parsed.created, label: parsed.label, bytes: file.bytes,
                kind: manifest.kind ?? .automatic, isLegacy: false
            ))
        }
        let legacy = legacyFolder(forGame: game.name)
        if !game.name.isEmpty, legacy.resolvingSymlinksInPath() != gameFolder(for: game).resolvingSymlinksInPath() {
            for file in Self.archives(in: legacy) {
                guard let parsed = Self.parse(fileName: file.url.lastPathComponent) else { continue }
                result.append(SaveBackup(
                    url: file.url, created: parsed.created, label: parsed.label, bytes: file.bytes,
                    kind: parsed.label.isEmpty ? .automatic : .safety, isLegacy: true
                ))
            }
        }
        return result.sorted { lhs, rhs in
            lhs.created != rhs.created
                ? lhs.created > rhs.created
                : lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    /// Regular files in `folder`, never directories or links.
    private static func archives(in folder: URL) -> [(url: URL, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            return (file, Int64(values.fileSize ?? 0))
        }
    }

    /// Keeps the newest ``keep`` automatic, ``keep`` manual and ``keepSafety``
    /// before-restore backups, each kind pruned only among its own. Only
    /// archives whose manifest names this game are candidates, and
    /// `protecting` (the archive just made, the one being restored) never
    /// goes, whatever its date says.
    func prune(_ game: SaveGame, protecting: Set<URL>) {
        // Compared resolved: a listed URL can read `/private/var` where the
        // one a backup returned reads `/var`.
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }
        let protected = Set(protecting.map(key))
        let owned = backups(for: game).filter { !$0.isLegacy }
        for (kind, limit) in [(SaveBackup.Kind.automatic, keep), (.manual, keep), (.safety, keepSafety)] {
            for old in owned.filter({ $0.kind == kind }).dropFirst(limit) where !protected.contains(key(old.url)) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
    }

    // MARK: - Where things may go

    /// Whether two places are the same or one is inside the other, links resolved.
    public static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let one = lhs.resolvingSymlinksInPath()
        let two = rhs.resolvingSymlinksInPath()
        return FileScan.isInside(one, two) || FileScan.isInside(two, one)
    }

    /// Whether a save folder and this store's root are inside one another, so
    /// a restore could replace the backups or a backup could zip itself.
    public func overlapsRoot(_ folder: SaveFolder, bottleURL: URL) -> Bool {
        Self.overlap(folder.url(bottleURL: bottleURL), root)
    }

    /// The same for the root and the game's own backup folder, which may be
    /// a link somewhere else.
    public func overlapsBackups(_ folder: SaveFolder, game: SaveGame, bottleURL: URL) -> Bool {
        let place = folder.url(bottleURL: bottleURL)
        return Self.overlap(place, root) || Self.overlap(place, gameFolder(for: game))
    }

    /// Where a confirmed folder is restored to: its real location, links
    /// resolved, which must be exactly where it was when it was confirmed. A
    /// link swapped since, even one to another game's saves in the same
    /// bottle, is refused. A folder confirmed before places were recorded may
    /// only go inside the bottle.
    static func restoreTarget(for folder: SaveFolder, bottleURL: URL) throws -> URL {
        let target = FileScan.plain(folder.url(bottleURL: bottleURL).resolvingSymlinksInPath())
        let path = target.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        if let confirmedPlace = folder.realPath ?? (folder.inBottle ? nil : folder.path) {
            guard path == confirmedPlace.trimmingSlashes, path.split(separator: "/").count >= 3 else {
                throw SaveBackupError.folderMoved
            }
            return target
        }
        let bottle = bottleURL.resolvingSymlinksInPath()
        let bottlePath = bottle.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        guard path.hasPrefix(bottlePath + "/") else { throw SaveBackupError.outsideBottle }
        return target
    }

    // MARK: - Backing up

    /// Zips every folder that exists into one new backup, verifies it, then
    /// prunes its kind. The outcome is recorded in ``status`` for the game.
    ///
    /// An automatic backup whose folders are unchanged since the game's last
    /// ordinary backup makes nothing and returns that backup.
    ///
    /// - Throws: ``SaveBackupError/nothingToBackUp`` when no folder exists,
    ///   ``SaveBackupError/restoreInProgress`` while the game's saves are being
    ///   restored (not recorded: it is not a failure of the backup).
    @discardableResult
    public func backUp(
        game: SaveGame, folders: [SaveFolder], bottleURL: URL,
        trigger: SaveBackupTrigger = .automatic, now: Date = Date()
    ) throws -> SaveBackup {
        guard !SaveRestoreGuard.isActive(game.id) else { throw SaveBackupError.restoreInProgress }
        do {
            let (backup, archived) = try SaveBackupLocks.withLock(game.id) { () throws -> (SaveBackup, Bool) in
                // A restore may have started while this waited.
                guard !SaveRestoreGuard.isActive(game.id) else { throw SaveBackupError.restoreInProgress }
                let destination = gameFolder(for: game)
                let present = try collect(folders, bottleURL: bottleURL, destination: destination)
                let fingerprint = Self.fingerprint(present)
                if trigger == .automatic, let last = lastOrdinary(game), last.fingerprint == fingerprint {
                    return (last.backup, false)
                }
                let made = try makeBackup(
                    gameID: game.id, name: game.name, present: present, fingerprint: fingerprint,
                    kind: trigger.kind, label: "", now: now, into: destination
                )
                prune(game, protecting: [made.backup.url])
                return (made.backup, true)
            }
            status?.record(succeeded: true, message: nil, archived: archived, time: now, for: game.id)
            return backup
        } catch SaveBackupError.restoreInProgress {
            throw SaveBackupError.restoreInProgress
        } catch {
            let reason = SaveBackupError.shortReason(for: error)
            status?.record(succeeded: false, message: reason, archived: false, time: now, for: game.id)
            throw error
        }
    }

    /// The newest automatic or manual backup that carries a fingerprint.
    private func lastOrdinary(_ game: SaveGame) -> (backup: SaveBackup, fingerprint: String)? {
        guard let last = backups(for: game).first(where: { !$0.isLegacy && !$0.isSafety }),
              let fingerprint = SaveBackupManifestReader.manifest(ofArchive: last.url)?.fingerprint
        else { return nil }
        return (last, fingerprint)
    }

    private struct Present {
        var folder: SaveFolder
        var source: URL
        var isFile: Bool
    }

    /// The folders that exist, refusing any that holds, or lies inside, the
    /// backup root or this game's own backup folder (either may be a link).
    private func collect(_ folders: [SaveFolder], bottleURL: URL, destination: URL) throws -> [Present] {
        var present: [Present] = []
        var seen = Set<SaveFolder>()
        for folder in folders where seen.insert(folder).inserted {
            // Resolved so a folder that is itself a link is copied as what it
            // points to; links inside it are copied as links, never followed.
            let source = FileScan.plain(folder.url(bottleURL: bottleURL).resolvingSymlinksInPath())
            guard let item = FileScan.kind(of: source), item != .link else { continue }
            guard !Self.overlap(source, root), !Self.overlap(source, destination) else {
                throw SaveBackupError.overlapsBackupLocation
            }
            present.append(Present(folder: folder, source: source, isFile: item == .file))
        }
        guard !present.isEmpty else { throw SaveBackupError.nothingToBackUp }
        return present
    }

    /// Every file's path inside `source`, size, change time and, for a link,
    /// where it points: cheap to read, and different whenever a save changed.
    static func fingerprintLines(_ source: URL, isFile: Bool) -> [String] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func line(_ url: URL, _ relative: String) -> String {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? -1
            let modified = Int(((values?.contentModificationDate?.timeIntervalSince1970) ?? 0) * 1000)
            let link = values?.isSymbolicLink == true
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) ?? ""
                : ""
            return "\(relative)\t\(size)\t\(modified)\t\(link)"
        }
        guard !isFile else { return [line(source, "")] }
        let base = source.path(percentEncoded: false).trimmingSlashes
        var lines: [String] = []
        let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [])
        while let url = walker?.nextObject() as? URL {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            let path = url.path(percentEncoded: false).trimmingSlashes
            lines.append(line(url, path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path))
        }
        return lines
    }

    private static func fingerprint(_ present: [Present]) -> String {
        var lines: [String] = []
        for entry in present {
            let prefix = "\(entry.folder.inBottle ? "b" : "a"):\(entry.folder.path)"
            lines.append(prefix)
            lines += fingerprintLines(entry.source, isFile: entry.isFile).sorted().map { prefix + "\t" + $0 }
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct Made {
        var backup: SaveBackup
        var manifest: SaveBackupManifest
    }

    /// One archive, unlocked: callers hold the game's lock.
    private func makeBackup(
        gameID: String, name: String, present: [Present], fingerprint: String?,
        kind: SaveBackup.Kind, label: String, now: Date, into destination: URL
    ) throws -> Made {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let stem = uniqueStem(in: destination, now: now, label: label)
        let staging = fileManager.temporaryDirectory.appending(path: "kadeh-backup-\(UUID().uuidString)")
        let content = staging.appending(path: stem, directoryHint: .isDirectory)
        // Unique per run, so two backups can never write into one file.
        let partial = destination.appending(path: ".\(UUID().uuidString).zip.partial")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: partial)
        }

        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        var manifest = SaveBackupManifest(
            created: now, game: name, gameID: gameID, kind: kind, fingerprint: fingerprint, folders: []
        )
        for (index, entry) in present.enumerated() {
            let item = "\(index + 1) \(Self.safeName(entry.folder.name))"
            try fileManager.copyItem(at: entry.source, to: content.appending(path: item))
            manifest.folders.append(SaveBackupManifestItem(
                item: item, path: entry.folder.path, inBottle: entry.folder.inBottle, isFile: entry.isFile
            ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: content.appending(path: Self.manifestName))

        try Self.ditto(["-c", "-k", "--keepParent", content.path(percentEncoded: false),
                        partial.path(percentEncoded: false)])
        try Self.verify(archive: partial, matches: manifest)
        let final = destination.appending(path: "\(stem).zip")
        // Fails rather than overwrites if the name was taken after all.
        try fileManager.moveItem(at: partial, to: final)

        let size = (try? final.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let backup = SaveBackup(
            url: final, created: now, label: label, bytes: Int64(size), kind: kind, isLegacy: false
        )
        return Made(backup: backup, manifest: manifest)
    }

    /// Every entry's checksum, then the manifest read back out of the archive.
    static func verify(archive: URL, matches manifest: SaveBackupManifest) throws {
        guard SaveBackupManifestReader.unzip(["-tqq", archive.lastPathComponent], in: archive)?.status == 0,
              let read = SaveBackupManifestReader.manifest(ofArchive: archive, cached: false),
              read.gameID == manifest.gameID,
              read.folders.map(\.item) == manifest.folders.map(\.item)
        else { throw SaveBackupError.archiveDamaged }
    }

    private func uniqueStem(in folder: URL, now: Date, label: String) -> String {
        let base = Self.fileStem(for: now, label: label)
        var stem = base
        var counter = 2
        func taken(_ stem: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: "\(stem).zip").path(percentEncoded: false))
        }
        while taken(stem) {
            stem = label.isEmpty ? "\(base) (\(counter))" : "\(base) \(counter)"
            counter += 1
        }
        return stem
    }

    // MARK: - Restoring

    /// Puts a backup's folders back in place.
    ///
    /// Order matters, and is the point of the function:
    /// 1. The archive is unpacked and checked before anything is touched: it
    ///    must be this game's, name only folders confirmed now, and each must
    ///    resolve inside the bottle or to its confirmed place, clear of the
    ///    backup folder.
    /// 2. Everything the restore replaces, files included, is backed up,
    ///    marked with `safetyLabel`, so a restore can itself be undone. If
    ///    that fails, nothing else happens.
    /// 3. Each folder is swapped in (see ``SaveFolderSwap``); any failure
    ///    puts every folder back as it was.
    ///
    /// ``SaveRestoreGuard`` reports the game as restoring throughout.
    ///
    /// - Returns: The before-restore backup, or `nil` when nothing was there.
    @discardableResult
    public func restore(
        _ backup: SaveBackup, game: SaveGame, bottleURL: URL, confirmed: [SaveFolder],
        safetyLabel: String = String(localized: "saves.restore.safetyLabel"), now: Date = Date()
    ) throws -> SaveBackup? {
        SaveRestoreGuard.begin(game.id)
        defer { SaveRestoreGuard.end(game.id) }
        return try SaveBackupLocks.withLock(game.id) {
            let fileManager = FileManager.default
            let unpacked = fileManager.temporaryDirectory.appending(path: "kadeh-restore-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: unpacked) }

            try Self.ditto(["-x", "-k", backup.url.path(percentEncoded: false), unpacked.path(percentEncoded: false)])
            let (content, manifest) = try Self.readUnpacked(unpacked)
            let plan = try restorePlan(
                manifest, content: content, game: game, bottleURL: bottleURL, confirmed: confirmed,
                keepClearOf: [root, gameFolder(for: game), backup.url.deletingLastPathComponent()]
            )

            let safety = try secureCurrent(
                plan, game: game, bottleURL: bottleURL, confirmed: confirmed, safetyLabel: safetyLabel, now: now
            )
            try SaveFolderSwap.swap(plan.map { ($0.source, $0.target) })
            prune(game, protecting: Set([backup.url, safety?.url].compactMap { $0 }))
            return safety
        }
    }

    private struct RestoreStep {
        var source: URL
        var folder: SaveFolder
        var target: URL
    }

    /// - Parameter keepClearOf: Where backups live; no target may hold or lie
    ///   inside any of them, links resolved.
    private func restorePlan(
        _ manifest: SaveBackupManifest, content: URL, game: SaveGame, bottleURL: URL, confirmed: [SaveFolder],
        keepClearOf backupPlaces: [URL]
    ) throws -> [RestoreStep] {
        if let id = manifest.gameID {
            guard id == game.id else { throw SaveBackupError.wrongGame }
        } else {
            // Made before archives carried an id: the name has to do.
            guard manifest.game == game.name else { throw SaveBackupError.wrongGame }
        }
        for item in manifest.folders {
            guard !item.item.isEmpty, !item.item.contains("/"), !item.item.hasPrefix("."),
                  !item.path.split(separator: "/").contains("..")
            else { throw SaveBackupError.invalidBackup }
        }
        // An archive from before nested folders were refused can hold a folder
        // and one inside it. The outer one already carries the inner one's
        // files, so only it is written.
        let items = manifest.folders.filter { inner in
            !manifest.folders.contains { outer in
                outer.inBottle == inner.inBottle && inner.path.hasPrefix(outer.path.trimmingSlashes + "/")
            }
        }

        var plan: [RestoreStep] = []
        for item in items {
            let named = SaveFolder(path: item.path, inBottle: item.inBottle)
            guard let folder = confirmed.first(where: { $0 == named }) else {
                throw SaveBackupError.folderNotConfirmed
            }
            let source = content.appending(path: item.item)
            guard FileScan.kind(of: source) == (item.isFile == true ? .file : .directory) else {
                throw SaveBackupError.invalidBackup
            }
            let target = try Self.restoreTarget(for: folder, bottleURL: bottleURL)
            guard !backupPlaces.contains(where: { Self.overlap(target, $0) }) else {
                throw SaveBackupError.overlapsBackupLocation
            }
            guard !plan.contains(where: { Self.overlap($0.target, target) }) else {
                throw SaveBackupError.invalidBackup
            }
            plan.append(RestoreStep(source: source, folder: folder, target: target))
        }
        guard !plan.isEmpty else { throw SaveBackupError.invalidBackup }
        return plan
    }

    /// Backs up what the restore will replace, and proves it did.
    private func secureCurrent(
        _ plan: [RestoreStep], game: SaveGame, bottleURL: URL, confirmed: [SaveFolder],
        safetyLabel: String, now: Date
    ) throws -> SaveBackup? {
        let replaced = plan.filter { FileScan.kind(of: $0.target) != nil }
        // A link or anything else that is neither file nor folder cannot be
        // copied faithfully, so it is not replaced either.
        guard replaced.allSatisfy({ FileScan.kind(of: $0.target) != .link }) else {
            throw SaveBackupError.cannotSecureCurrent
        }
        do {
            let destination = gameFolder(for: game)
            let present = try collect(plan.map(\.folder) + confirmed, bottleURL: bottleURL, destination: destination)
            let made = try makeBackup(
                gameID: game.id, name: game.name, present: present, fingerprint: nil,
                kind: .safety, label: safetyLabel, now: now, into: destination
            )
            let secured = Set(made.manifest.folders.map { SaveFolder(path: $0.path, inBottle: $0.inBottle) })
            guard replaced.allSatisfy({ secured.contains($0.folder) }) else {
                try? FileManager.default.removeItem(at: made.backup.url)
                throw SaveBackupError.cannotSecureCurrent
            }
            return made.backup
        } catch SaveBackupError.nothingToBackUp {
            // Nothing there yet, so nothing to lose.
            guard replaced.isEmpty else { throw SaveBackupError.cannotSecureCurrent }
            return nil
        } catch let error as SaveBackupError where error == .overlapsBackupLocation || error == .cannotSecureCurrent {
            throw error
        } catch {
            Logger.wineKit.error("Before-restore backup failed: \(error.localizedDescription)")
            throw SaveBackupError.cannotSecureCurrent
        }
    }

    static func readUnpacked(_ unpacked: URL) throws -> (content: URL, manifest: SaveBackupManifest) {
        let top = FileScan.children(of: unpacked).filter { FileScan.kind(of: $0) == .directory }
        for folder in top {
            if let data = try? Data(contentsOf: folder.appending(path: manifestName)),
               let manifest = SaveBackupManifest.decode(data) {
                return (folder, manifest)
            }
        }
        throw SaveBackupError.invalidBackup
    }

    static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SaveBackupError.archiveFailed(
                String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

// MARK: - Manifest

/// What a backup's `kadeh-backup.json` says: whose it is and where each
/// numbered item in the archive came from.
struct SaveBackupManifest: Codable, Sendable {
    var format = 2
    var created: Date
    var game: String
    /// The library entry id; missing in the first version's archives.
    var gameID: String?
    /// Missing in the first version's archives, which count as automatic.
    var kind: SaveBackup.Kind?
    /// See ``SaveBackupStore/fingerprintLines(_:isFile:)``; missing in older archives.
    var fingerprint: String?
    var folders: [SaveBackupManifestItem]

    static func decode(_ data: Data) -> SaveBackupManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SaveBackupManifest.self, from: data)
    }
}

struct SaveBackupManifestItem: Codable, Sendable {
    /// The numbered folder inside the archive.
    var item: String
    var path: String
    var inBottle: Bool
    /// A save path that was a file rather than a folder; missing means a folder.
    var isFile: Bool?
}

/// Reads a manifest straight out of an archive with `unzip`, without
/// unpacking the saves, and remembers it while the file is unchanged.
enum SaveBackupManifestReader {
    private struct Cached: Sendable {
        var size: Int
        var modified: Date
        var manifest: SaveBackupManifest?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [String: Cached]())

    static func manifest(ofArchive url: URL, cached useCache: Bool = true) -> SaveBackupManifest? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate ?? .distantPast
        if useCache, let hit = cache.withLock({ $0[path] }), hit.size == size, hit.modified == modified {
            return hit.manifest
        }
        // Exactly one level down: the archive's own folder, not a save that
        // happens to carry the same name. Wildcards also match names `unzip`
        // cannot spell.
        let output = unzip(
            ["-p", url.lastPathComponent, "*/\(SaveBackupStore.manifestName)",
             "-x", "*/*/\(SaveBackupStore.manifestName)"],
            in: url
        )
        let manifest = output.flatMap { $0.status == 0 ? SaveBackupManifest.decode($0.output) : nil }
        if useCache {
            cache.withLock { $0[path] = Cached(size: size, modified: modified, manifest: manifest) }
        }
        return manifest
    }

    /// Runs `unzip` beside the archive, so its name is passed bare.
    static func unzip(_ arguments: [String], in archive: URL) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = arguments
        process.currentDirectoryURL = archive.deletingLastPathComponent()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

// MARK: - One at a time

/// One lock per game, shared by every store value: backups and restores of a
/// game never overlap.
enum SaveBackupLocks {
    private static let locks = OSAllocatedUnfairLock(initialState: [String: NSLock]())

    static func withLock<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let lock = locks.withLock { all in
            if let existing = all[key] { return existing }
            let made = NSLock()
            all[key] = made
            return made
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public extension Notification.Name {
    /// Posted on the main thread when a game starts or stops restoring. The
    /// object is the library entry id.
    static let saveRestoreStateChanged = Notification.Name("com.furkan.kadeh.saveRestoreStateChanged")
}

/// Whether a game's saves are being restored, from the moment the restore
/// starts until it finished or rolled back. The game must not start, and no
/// backup of it may run, while this is true.
public enum SaveRestoreGuard {
    private static let active = OSAllocatedUnfairLock(initialState: [String: Int]())

    @MainActor
    public static func isRestoring(_ entryID: String) -> Bool {
        isActive(entryID)
    }

    /// The same, from any thread.
    static func isActive(_ entryID: String) -> Bool {
        active.withLock { ($0[entryID] ?? 0) > 0 }
    }

    /// Nests: the page marks a restore before it hands it to the store,
    /// which marks it again.
    public static func begin(_ entryID: String) {
        let started = active.withLock { all in
            all[entryID, default: 0] += 1
            return all[entryID] == 1
        }
        if started { announce(entryID) }
    }

    public static func end(_ entryID: String) {
        let ended = active.withLock { all in
            let count = max((all[entryID] ?? 0) - 1, 0)
            all[entryID] = count == 0 ? nil : count
            return count == 0
        }
        if ended { announce(entryID) }
    }

    private static func announce(_ entryID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .saveRestoreStateChanged, object: entryID)
        }
    }
}

// MARK: - Last attempt

/// How a game's last ordinary backup, by hand or after a session, went.
public struct SaveBackupAttempt: Codable, Equatable, Sendable {
    public var time: Date
    public var succeeded: Bool
    /// Why it failed, in a few words.
    public var message: String?
    /// When an archive was last actually made. An automatic backup that found
    /// nothing changed succeeds without moving this.
    public var lastBackup: Date?

    public init(time: Date, succeeded: Bool, message: String?, lastBackup: Date? = nil) {
        self.time = time
        self.succeeded = succeeded
        self.message = message
        self.lastBackup = lastBackup
    }
}

/// One JSON file of ``SaveBackupAttempt``s keyed by library entry id, written
/// by ``SaveBackupStore/backUp(game:folders:bottleURL:trigger:now:)`` itself,
/// so a backup started anywhere is recorded.
public struct SaveBackupStatusStore: Sendable {
    public static var defaultURL: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "SaveBackupStatus").appendingPathExtension("json")
    }

    private static let writing = OSAllocatedUnfairLock()
    private let url: URL

    public init(url: URL = SaveBackupStatusStore.defaultURL) {
        self.url = url
    }

    public func attempt(for entryID: String) -> SaveBackupAttempt? {
        load()[entryID]
    }

    /// - Parameter archived: Whether an archive was made, which moves
    ///   ``SaveBackupAttempt/lastBackup``.
    func record(succeeded: Bool, message: String?, archived: Bool, time: Date, for entryID: String) {
        Self.writing.withLock {
            var all = load()
            let previous = all[entryID]?.lastBackup
            all[entryID] = SaveBackupAttempt(
                time: time, succeeded: succeeded, message: message, lastBackup: archived ? time : previous
            )
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(all).write(to: url, options: .atomic)
            } catch {
                Logger.wineKit.error("Failed to record save backup status: \(error.localizedDescription)")
            }
        }
        SaveBackupOverviews.invalidate(entryID)
    }

    private func load() -> [String: SaveBackupAttempt] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: SaveBackupAttempt].self, from: data)) ?? [:]
    }
}

// MARK: - Overview

public extension Notification.Name {
    /// Posted on the main thread when a game's ``SaveBackupOverview`` may have
    /// changed. The object is the library entry id.
    static let saveBackupStatusChanged = Notification.Name("com.furkan.kadeh.saveBackupStatusChanged")
}

/// What a card or a game page's stat needs to know about a game's backups.
public struct SaveBackupOverview: Sendable, Equatable {
    /// Whether the person confirmed save folders, so backups are on.
    public let configured: Bool
    /// When the last archive was made.
    public let lastBackup: Date?
    /// Whether the last automatic or manual attempt failed.
    public let lastAttemptFailed: Bool

    public init(configured: Bool, lastBackup: Date?, lastAttemptFailed: Bool) {
        self.configured = configured
        self.lastBackup = lastBackup
        self.lastAttemptFailed = lastAttemptFailed
    }
}

/// ``SaveBackupOverview``s, read from the small folder and status files once
/// and cached until a backup or a folder change invalidates them. Safe from
/// any thread.
public enum SaveBackupOverviews {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: SaveBackupOverview]())

    public static func overview(for entryID: String) -> SaveBackupOverview {
        if let hit = cache.withLock({ $0[entryID] }) { return hit }
        let value = overview(
            for: entryID, folders: SaveFolderStore(), status: SaveBackupStatusStore(),
            backups: SaveBackupStore.configured(defaults: .standard)
        )
        cache.withLock { $0[entryID] = value }
        return value
    }

    /// Uncached, with the stores given.
    static func overview(
        for entryID: String, folders: SaveFolderStore, status: SaveBackupStatusStore, backups: SaveBackupStore
    ) -> SaveBackupOverview {
        let configured = !folders.folders(for: entryID).isEmpty
        let attempt = status.attempt(for: entryID)
        var last = attempt?.lastBackup
        if last == nil, configured {
            // Archives made before attempts were recorded: read them once.
            last = backups.backups(for: SaveGame(id: entryID, name: "")).first(where: { !$0.isSafety })?.created
        }
        return SaveBackupOverview(
            configured: configured, lastBackup: last, lastAttemptFailed: attempt?.succeeded == false
        )
    }

    /// Forgets a game's overview and tells whoever shows it.
    static func invalidate(_ entryID: String) {
        cache.withLock { $0[entryID] = nil }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .saveBackupStatusChanged, object: entryID)
        }
    }
}
