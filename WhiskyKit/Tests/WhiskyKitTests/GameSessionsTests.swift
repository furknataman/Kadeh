//
//  GameSessionsTests.swift
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

import Combine
import Foundation
import Testing
@testable import WhiskyKit

/// A process list a test can change while a watcher polls it.
private final class FakeProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    /// Sets the running programs by Windows path inside the test bottle.
    func set(_ names: Set<String>) {
        lock.lock()
        self.names = names
        lock.unlock()
    }

    func get() -> [HostWineProcess] {
        lock.lock()
        defer { lock.unlock() }
        return names.enumerated().map { index, path in
            HostWineProcess(pid: Int32(index + 100), imagePath: path, prefixPath: "/tmp/kadeh-session-test")
        }
    }
}

@MainActor
@Suite("Game Sessions Tests")
struct GameSessionsTests {
    private let entry = LibraryEntry(
        id: "pinned:/tmp/kadeh-session-test/drive_c/Game/game.exe",
        name: "Game",
        iconURL: nil,
        bottleURL: URL(fileURLWithPath: "/tmp/kadeh-session-test"),
        source: .pinned,
        launch: .program(URL(fileURLWithPath: "/tmp/kadeh-session-test/drive_c/Game/game.exe"))
    )

    private func make(_ processes: FakeProcesses, appearTimeout: TimeInterval = 5) -> GameSessions {
        GameSessions(
            timing: .init(pollInterval: .milliseconds(10), appearTimeout: appearTimeout, seenTimeout: 0.05),
            processes: { processes.get() }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A launched game that exits ends its session once")
    func endsOnce() async {
        let processes = FakeProcesses()
        let sessions = make(processes)
        var ends: [GameSessionEnd] = []
        let subscription = sessions.ended.sink { ends.append($0) }
        defer { subscription.cancel() }

        sessions.began(entry, executables: ["game.exe"])
        processes.set([#"C:\Game\game.exe"#])
        await waitUntil { sessions.active[entry.id]?.seenRunning == true }
        processes.set([])
        await waitUntil { !ends.isEmpty }

        // The library poller noticing the same exit must not end it again.
        sessions.observe(entry, running: false)

        #expect(ends.count == 1)
        #expect(ends.first?.session.entry == entry)
        #expect(!sessions.isActive(entry.id))
    }

    @Test("A launch whose game never appears is not a session")
    func neverAppears() async {
        let processes = FakeProcesses()
        let sessions = make(processes, appearTimeout: 0.05)
        var ends = 0
        let subscription = sessions.ended.sink { _ in ends += 1 }
        defer { subscription.cancel() }

        sessions.began(entry, executables: ["game.exe"])
        await waitUntil { !sessions.isActive(entry.id) }

        #expect(ends == 0)
        #expect(!sessions.isActive(entry.id))
    }

    @Test("A session without names still ends, and only after it was seen")
    func pollerNeedsToSeeTheGame() async {
        let processes = FakeProcesses()
        let sessions = make(processes)
        var ends = 0
        let subscription = sessions.ended.sink { _ in ends += 1 }
        defer { subscription.cancel() }

        sessions.began(entry, executables: [])
        sessions.observe(entry, running: false)
        #expect(ends == 0)
        #expect(sessions.isActive(entry.id))

        sessions.observe(entry, running: true)
        sessions.observe(entry, running: false)
        await waitUntil { ends > 0 }
        #expect(ends == 1)
        #expect(!sessions.isActive(entry.id))
    }

    @Test("A game started outside Kadeh still ends a session when seen")
    func outsideStart() async {
        let sessions = make(FakeProcesses())
        var ends = 0
        let subscription = sessions.ended.sink { _ in ends += 1 }
        defer { subscription.cancel() }

        sessions.observe(entry, running: true)
        sessions.observe(entry, running: false)
        sessions.observe(entry, running: false)
        await waitUntil { ends > 0 }

        #expect(ends == 1)
        #expect(!sessions.isActive(entry.id))
    }

    @Test("A game the poller saw but that was gone before the first look still ends")
    func goneBeforeFirstPoll() async {
        let processes = FakeProcesses()
        let sessions = make(processes)
        var ends: [GameSessionEnd] = []
        let subscription = sessions.ended.sink { ends.append($0) }
        defer { subscription.cancel() }

        sessions.began(entry, executables: ["game.exe"])
        // The poller sees it; the watcher never does.
        sessions.observe(entry, running: true)
        await waitUntil { !ends.isEmpty }

        #expect(ends.count == 1)
        #expect(!sessions.isActive(entry.id))
    }

    @Test("The poller seeing a stop does not end a session the watcher still sees")
    func watcherOutranksPoller() async {
        let steamEntry = entry
        let processes = FakeProcesses()
        let sessions = make(processes)
        var ends = 0
        let subscription = sessions.ended.sink { _ in ends += 1 }
        defer { subscription.cancel() }

        sessions.began(steamEntry, executables: ["game.exe"])
        processes.set([#"C:\Game\game.exe"#])
        await waitUntil { sessions.active[steamEntry.id]?.seenRunning == true }
        // The poller only knows the root name and reports a stop; the
        // watcher still sees the game and keeps the session.
        sessions.observe(steamEntry, running: false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ends == 0)
        #expect(sessions.isActive(steamEntry.id))

        processes.set([])
        await waitUntil { ends > 0 }
        #expect(ends == 1)
    }
}
