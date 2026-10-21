//
//  GameSessions.swift
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

import Combine
import Foundation
import os.log

/// One play of one library entry, from when it started to when it ended.
public struct GameSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let entry: LibraryEntry
    public let startedAt: Date
    /// Whether the game's own process has been seen. A launch that never puts
    /// a process up is dropped rather than reported as a session.
    public internal(set) var seenRunning: Bool
}

/// A session that just ended, handed to whoever listens on ``GameSessions/ended``.
public struct GameSessionEnd: Equatable, Sendable {
    public let session: GameSession
    public let endedAt: Date

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(session.startedAt)) }
}

/// The one place that knows when a game started from Kadeh has ended.
///
/// App-wide rather than owned by the library view, because the things that
/// react to a game ending (playtime, save backups) have to happen whether or
/// not the library is on screen when it does.
///
/// Two sources feed it and are de-duplicated into a single ``ended`` event per
/// session: a watcher started by ``began(_:executables:at:)``, and the
/// library's own Steam poller reporting through ``observe(_:running:at:)``.
/// The watcher has the last word: it places every process by where its image
/// lives (``GameProcessScope``), while the poller only knows the names at the
/// top of an install folder, so a bootstrap handing over to a deeper
/// executable looks to it like the game ending.
///
/// `ProcessRegistry` would be the obvious source but cannot be: a launch runs
/// `start /unix`, which returns seconds after the game starts, so nothing in
/// the app ever sees the game's own process exit. The watcher reads the host
/// process list instead (``HostWineProcesses``). It only reads: it never
/// starts, stops or signals anything, and in particular never runs
/// `tasklist.exe`, which would start a wineserver in an idle bottle.
@MainActor
public final class GameSessions: ObservableObject {
    public static let shared = GameSessions()

    /// The waits, injectable so tests do not sit through them.
    public struct Timing: Sendable {
        /// How often a running game's processes are looked for.
        public var pollInterval: Duration
        /// How long a launch may take to put its process up. Covers a cold
        /// Steam client (90 s) plus Steam's own launch grace (120 s).
        public var appearTimeout: TimeInterval
        /// How long the watcher looks for a game the poller already saw
        /// before deciding it was gone by the time it looked.
        public var seenTimeout: TimeInterval

        public init(
            pollInterval: Duration = .seconds(10), appearTimeout: TimeInterval = 240, seenTimeout: TimeInterval = 30
        ) {
            self.pollInterval = pollInterval
            self.appearTimeout = appearTimeout
            self.seenTimeout = seenTimeout
        }
    }

    /// Fires once for every session that ends.
    public let ended = PassthroughSubject<GameSessionEnd, Never>()

    /// Sessions in progress, keyed by library entry id.
    @Published public private(set) var active: [String: GameSession] = [:]

    private var watchers: [String: Task<Void, Never>] = [:]
    /// When each session's game was last seen running, by session id.
    private var lastSeen: [UUID: Date] = [:]
    private let timing: Timing
    private let processes: @Sendable () async -> [HostWineProcess]
    private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "GameSessions")

    /// - Parameters:
    ///   - timing: Poll interval and launch timeout.
    ///   - processes: The bottles' running processes. Defaults to the host
    ///     process list.
    public init(
        timing: Timing = Timing(),
        processes: @escaping @Sendable () async -> [HostWineProcess] = HostWineProcesses.current
    ) {
        self.timing = timing
        self.processes = processes
    }

    /// Whether the entry is starting or running as far as Kadeh knows.
    public func isActive(_ entryID: String) -> Bool {
        active[entryID] != nil
    }

    /// Records that Kadeh just launched `entry`, and watches it until it exits.
    ///
    /// A second launch of something already active keeps the first session:
    /// Steam ignores `-applaunch` for a running game, and a session that
    /// restarted would lose its start time.
    ///
    /// - Parameter executables: Lowercased image names of the game. The
    ///   watcher places processes by path; the names only count for a process
    ///   that shows no path. Every session gets a watcher, names or not, so
    ///   every session has an end: one nothing ever sees is dropped at the
    ///   launch deadline, one only the poller saw ends shortly after.
    public func began(_ entry: LibraryEntry, executables: Set<String>, at date: Date = Date()) {
        guard !entry.isLauncher, active[entry.id] == nil else { return }
        let session = GameSession(id: UUID(), entry: entry, startedAt: date, seenRunning: false)
        active[entry.id] = session
        startWatcher(for: session, extraNames: executables)
    }

    /// A game Kadeh runs as its own macOS process: running from the start, ended by ``finished(_:at:)``.
    ///
    /// No watcher: the process list only knows Wine processes, and whoever
    /// started the process hears it exit. Keep such an entry out of
    /// ``observe(_:running:at:)``: a session no watcher follows ends on the
    /// first "not running" the poller reports.
    public func beganNative(_ entry: LibraryEntry, at date: Date = Date()) {
        guard !entry.isLauncher, active[entry.id] == nil else { return }
        active[entry.id] = GameSession(id: UUID(), entry: entry, startedAt: date, seenRunning: true)
    }

    /// Ends the session of a game started with ``beganNative(_:at:)``, once
    /// its process exited.
    public func finished(_ entryID: String, at date: Date = Date()) {
        guard let session = active[entryID] else { return }
        finish(entryID, sessionID: session.id, at: date)
    }

    /// What the library's Steam poller saw for one entry.
    ///
    /// A game the poller sees running without a launch from Kadeh starts a
    /// session at that moment, so a game started from Steam itself still gets
    /// its saves backed up and its time recorded when it exits. That session
    /// gets a watcher too: the poller stops with the library view, and a
    /// session nothing can end would block restoring that game's saves.
    ///
    /// The poller seeing the game stop ends a session only when no watcher
    /// follows it; a watcher looks deeper and ends it itself.
    public func observe(_ entry: LibraryEntry, running: Bool, at date: Date = Date()) {
        if running {
            if let session = active[entry.id] {
                active[entry.id]?.seenRunning = true
                lastSeen[session.id] = date
            } else {
                guard !entry.isLauncher else { return }
                let session = GameSession(id: UUID(), entry: entry, startedAt: date, seenRunning: true)
                active[entry.id] = session
                lastSeen[session.id] = date
                startWatcher(for: session, extraNames: [])
            }
        } else if let session = active[entry.id], session.seenRunning, watchers[entry.id] == nil {
            finish(entry.id, sessionID: session.id, at: date)
        }
    }

    private func startWatcher(for session: GameSession, extraNames: Set<String>) {
        let entry = session.entry
        watchers[entry.id] = Task { [weak self] in
            let scope = await Task.detached { GameProcessScope.of(entry, extraNames: extraNames) }.value
            await self?.watch(session, scope: scope)
        }
    }

    /// Follows one session until its game is gone.
    ///
    /// Two misses in a row end it, at the first miss: a launcher handing over
    /// to the game can leave a moment with neither up. A session the watcher
    /// never saw ends at its deadline: dropped when nothing ever saw it (a
    /// launch that went nowhere), ended at the last sighting when the poller
    /// did, so a game that was gone before the first look cannot keep its
    /// session, and with it the saves restore lock, forever.
    private func watch(_ session: GameSession, scope: GameProcessScope) async {
        let entryID = session.entry.id
        let launchDeadline = Date().addingTimeInterval(timing.appearTimeout)
        var confirmed = false
        var firstMiss: Date?

        while !Task.isCancelled {
            let running = scope.isRunning(in: await processes())
            guard !Task.isCancelled, let current = active[entryID], current.id == session.id else { return }
            let now = Date()
            if running {
                confirmed = true
                firstMiss = nil
                active[entryID]?.seenRunning = true
                lastSeen[session.id] = now
            } else if confirmed {
                if let firstMiss {
                    finish(entryID, sessionID: session.id, at: firstMiss)
                    return
                }
                firstMiss = now
            } else if now >= deadline(for: current, launchDeadline: launchDeadline) {
                if current.seenRunning {
                    finish(entryID, sessionID: session.id, at: lastSeen[session.id] ?? current.startedAt)
                } else {
                    active[entryID] = nil
                    watchers[entryID] = nil
                    lastSeen[session.id] = nil
                }
                return
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    /// When a session the watcher has not seen gives up: once the poller has
    /// seen the game, a short wait from that sighting rather than the whole
    /// launch allowance.
    private func deadline(for session: GameSession, launchDeadline: Date) -> Date {
        guard session.seenRunning else { return launchDeadline }
        let sighting = lastSeen[session.id] ?? session.startedAt
        return min(launchDeadline, sighting.addingTimeInterval(timing.seenTimeout))
    }

    /// Ends a session once, whichever source noticed first.
    private func finish(_ entryID: String, sessionID: UUID, at date: Date) {
        guard let session = active[entryID], session.id == sessionID else { return }
        active[entryID] = nil
        lastSeen[sessionID] = nil
        watchers.removeValue(forKey: entryID)?.cancel()
        logger.info("Session of '\(session.entry.name, privacy: .public)' ended")
        ended.send(GameSessionEnd(session: session, endedAt: max(date, session.startedAt)))
    }

    /// Whether any process of `entry` runs right now, by where its image
    /// lives. What a saves restore should ask before it touches a folder.
    public nonisolated static func isRunning(_ entry: LibraryEntry) async -> Bool {
        let processes = await HostWineProcesses.current()
        return await Task.detached { GameProcessScope.of(entry).isRunning(in: processes) }.value
    }

    /// The `.exe` names in the host process list.
    ///
    /// `ps` rather than `tasklist.exe` because it costs nothing and starts
    /// nothing. Not scoped to a bottle; ``isRunning(_:)`` is.
    public nonisolated static func hostImageNames() async -> Set<String> {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/ps")
            process.arguments = ["-Ao", "comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(bytes: data, encoding: .utf8) else { return [] }
            return WineSteamClientDriver.exeImageNames(inProcessListing: output)
        }.value
    }

    /// The image names that mean `entry` is running.
    ///
    /// A Steam game is any executable in its install folder, down to the
    /// depth Unreal puts its real game at, since what Steam starts is often a
    /// launcher that hands over to it. A program is its own executable: its
    /// folder can be a shared one.
    public nonisolated static func executables(for entry: LibraryEntry) -> Set<String> {
        GameProcessScope.of(entry).names
    }
}
