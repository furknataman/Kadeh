//
//  PlaytimeTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("Playtime Tests")
struct PlaytimeTests {
    private let localConfig = """
    "UserLocalConfigStore"
    {
        "Software"
        {
            "Valve"
            {
                "Steam"
                {
                    "apps"
                    {
                        "1817070"
                        {
                            "LastPlayed"        "1792343492"
                            "Playtime"      "8045"
                            "autocloud"
                            {
                                "lastlaunch"        "1792327710"
                            }
                        }
                        "7"
                        {
                            "cloud" { "quota" "1" }
                        }
                    }
                }
            }
        }
    }
    """

    @Test("Reads Steam's playtime and last played per App ID")
    func parsesLocalConfig() throws {
        let records = SteamPlaytimeReader.parse(localConfig: localConfig)
        let spiderMan = try #require(records[1_817_070])

        #expect(spiderMan.minutes == 8_045)
        #expect(spiderMan.lastPlayed == Date(timeIntervalSince1970: 1_792_343_492))
        #expect(spiderMan.lastLaunch == Date(timeIntervalSince1970: 1_792_327_710))
        #expect(spiderMan.playtime.seconds == 8_045 * 60)
        // An app with neither is not a played game.
        #expect(records[7] == nil)
    }

    @Test("Picks the account marked most recent, else the newest sign-in")
    func picksAccount() {
        let marked = """
        "users" {
            "76561198142995931" { "MostRecent" "0" "timestamp" "200" }
            "76561198000000001" { "MostRecent" "1" "timestamp" "100" }
        }
        """
        let unmarked = """
        "users" {
            "76561198142995931" { "timestamp" "200" }
            "76561198000000001" { "timestamp" "100" }
        }
        """

        #expect(SteamPlaytimeReader.mostRecentSteamID(loginUsers: marked) == "76561198000000001")
        #expect(SteamPlaytimeReader.mostRecentSteamID(loginUsers: unmarked) == "76561198142995931")
        #expect(SteamPlaytimeReader.accountID(steamID64: "76561198142995931") == "182730203")
    }

    @Test("Counts sessions of a minute or more")
    func storesSessions() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kadeh-playtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlaytimeStore(url: folder.appending(path: "Playtime.json"))
        let start = Date(timeIntervalSince1970: 1_000_000)

        store.record(entryID: "game", from: start, to: start.addingTimeInterval(3_600))
        store.record(entryID: "game", from: start, to: start.addingTimeInterval(30))
        store.record(entryID: "game", from: start, to: start.addingTimeInterval(600))

        let total = try #require(store.all()["game"])
        #expect(total.seconds == 4_200)
        #expect(total.lastPlayed == start.addingTimeInterval(3_600))
    }
}

@Suite("Play history")
struct PlayHistoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "tr_TR")
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("Two games ending together both keep their session")
    func concurrentWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kadeh-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = PlayHistoryStore(url: folder.appending(path: "PlayHistory.json"))
        let totals = PlaytimeStore(url: folder.appending(path: "Playtime.json"))
        let start = Date().addingTimeInterval(-3_600)

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    history.append(entryID: "game\(index)", from: start, to: start.addingTimeInterval(600))
                    totals.record(entryID: "game\(index)", from: start, to: start.addingTimeInterval(600))
                }
            }
        }

        #expect(history.sessions().count == 20)
        #expect(totals.all().count == 20)
    }

    @Test("Short sessions are dropped and a year is kept")
    func pruning() {
        let now = date("2026-10-19T12:00:00")
        let old = PlaySession(entryID: "a", start: now.addingTimeInterval(-400 * 86_400),
                              end: now.addingTimeInterval(-400 * 86_400 + 3_600))
        let recent = PlaySession(entryID: "b", start: now.addingTimeInterval(-86_400),
                                 end: now.addingTimeInterval(-82_800))
        #expect(PlayHistoryStore.pruned([recent, old], now: now) == [recent])
    }

    @Test("A session over the week's edge is split between the weeks")
    func weekSplit() {
        // Sunday 23:00 to Monday 01:00, Istanbul time.
        let session = PlaySession(entryID: "a", start: date("2026-10-18T23:00:00"), end: date("2026-10-19T01:00:00"))
        let weeks = PlayHistoryStats.weeks(of: [session], count: 8, now: date("2026-10-19T12:00:00"),
                                           calendar: calendar)

        #expect(weeks.count == 8)
        #expect(weeks.last?.start == date("2026-10-19T00:00:00"))
        #expect(weeks.last?.seconds == 3_600)
        #expect(weeks[6].seconds == 3_600)
        #expect(weeks.dropLast(2).allSatisfy { $0.seconds == 0 })
    }

    @Test("This week and this month count only their own part")
    func currentPeriods() {
        let now = date("2026-10-19T12:00:00")
        let sessions = [
            PlaySession(entryID: "a", start: date("2026-09-30T23:00:00"), end: date("2026-10-01T01:00:00")),
            PlaySession(entryID: "b", start: date("2026-10-19T09:00:00"), end: date("2026-10-19T10:30:00"))
        ]
        #expect(PlayHistoryStats.seconds(of: sessions, inCurrent: .weekOfYear, now: now, calendar: calendar) == 5_400)
        #expect(PlayHistoryStats.seconds(of: sessions, inCurrent: .month, now: now, calendar: calendar) == 9_000)
    }

    @Test("Sessions round-trip through the small file format")
    func coding() throws {
        let session = PlaySession(entryID: "steam:/b:7", start: Date(timeIntervalSince1970: 100),
                                  end: Date(timeIntervalSince1970: 4_000))
        let data = try JSONEncoder().encode([session])
        #expect(try JSONDecoder().decode([PlaySession].self, from: data) == [session])
    }
}
