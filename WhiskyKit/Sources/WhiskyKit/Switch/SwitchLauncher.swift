//
//  SwitchLauncher.swift
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

import AppKit
import Darwin

/// Starts Switch games in the emulator and stops them.
///
/// The emulator is one native process per game, so Kadeh keeps the `Process` it
/// started and hears it exit; nothing has to poll a process list. The
/// output goes to the null device rather than a pipe: a pipe would tie
/// the emulator's life to Kadeh's, and quitting Kadeh must not end a game.
///
/// Kadeh does not adopt an emulator it finds running after a relaunch; that
/// session is simply not counted.
@MainActor
public enum SwitchLauncher {
    /// Running emulator processes by library entry id, until their exit is handled.
    private static var running: [String: Process] = [:]

    /// Starts `game` full screen in the emulator. When that entry is already
    /// running, brings its window to the front instead of starting a second copy.
    public static func launch(_ entry: LibraryEntry, game: URL) throws {
        if let process = running[entry.id] {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
            return
        }
        SwitchEmulator.prepareForLaunch()
        let process = Process()
        process.executableURL = SwitchEmulator.executableURL
        process.arguments = SwitchEmulator.launchArguments(for: game)
        process.currentDirectoryURL = SwitchEmulator.folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let entryID = entry.id
        process.terminationHandler = { _ in
            Task { @MainActor in
                running[entryID] = nil
                GameSessions.shared.finished(entryID)
            }
        }
        try process.run()
        running[entryID] = process
        GameSessions.shared.beganNative(entry)
    }

    /// Whether Kadeh started the emulator for this entry and has not yet seen it
    /// exit. The exit is what clears it, not `Process.isRunning`, so a launch
    /// can never slip in between the exit and its session ending.
    public static func isRunning(_ entryID: String) -> Bool {
        running[entryID] != nil
    }

    /// Asks the emulator to quit, and ends it if it is still up ten seconds later.
    public static func stop(_ entryID: String) async {
        guard let process = running[entryID] else { return }
        // A Mac app's own Quit, so it saves its settings; Eden ignores SIGTERM
        // on macOS (measured 2026-10-20: quit in 2 s, SIGTERM never).
        if NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate() != true {
            process.terminate()
        }
        for _ in 0 ..< 20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
