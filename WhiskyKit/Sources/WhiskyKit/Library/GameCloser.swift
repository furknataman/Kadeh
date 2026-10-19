//
//  GameCloser.swift
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

import Darwin
import Foundation
import os.log

/// Closes a running game or program, the same way from the game page and
/// from the Etkinlik window.
///
/// First the game is asked to close, the way its own window's close button
/// would (`taskkill.exe` without `/F`), so it can save and quit cleanly. What
/// is still up eight seconds later is ended from the host, by its exact
/// process id: no Wine call, so nothing can start a wineserver.
///
/// The polite step does need Wine: `taskkill.exe` knows Wine's own process
/// ids, which only `tasklist.exe` lists, and both are Wine processes. So
/// each is only run after the bottle's wineserver answers a `-k0` probe,
/// which starts nothing; a bottle that stopped in the meantime is left
/// alone. `tasklist.exe` lists image names without paths, so an image name
/// is only asked to close when every process of that name in the bottle is
/// one of those being closed; two games that both run `game.exe` from
/// different folders never close each other.
@MainActor
public enum GameCloser {
    /// How long a game gets to close by itself before it is ended.
    public static let gracePeriod = 8

    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "GameCloser")

    /// Closes every process of a library entry.
    public static func close(_ entry: LibraryEntry) async {
        await close(entry, in: Bottle(bottleUrl: entry.bottleURL))
    }

    /// ``close(_:)`` with the bottle already at hand.
    public static func close(_ entry: LibraryEntry, in bottle: Bottle) async {
        let scope = await Task.detached { GameProcessScope.of(entry) }.value
        let processes = await HostWineProcesses.current().filter(scope.matches)
        await close(processes, in: bottle)
    }

    /// Closes exactly these processes of `bottle`.
    public static func close(_ processes: [HostWineProcess], in bottle: Bottle) async {
        let snapshot = await HostWineProcesses.current()
        let targets = stillRunning(processes, in: snapshot)
        guard !targets.isEmpty else { return }

        let names = askableNames(targets, bottleProcesses: snapshot.filter { $0.belongs(to: bottle.url) })
        if !names.isEmpty, await Wine.isWineserverRunning(for: bottle) {
            let wine = ((try? await Wine.listProcesses(for: bottle)) ?? [])
                .filter { names.contains($0.imageName.lowercased()) }
            for process in wine {
                guard await Wine.isWineserverRunning(for: bottle) else { break }
                await Wine.gracefulKillProcess(winePID: process.winePID, bottle: bottle)
            }
        }
        if await waitUntilGone(targets, seconds: gracePeriod) { return }

        for signal in [SIGTERM, SIGKILL] {
            let left = stillRunning(targets, in: await HostWineProcesses.current())
            guard !left.isEmpty else { return }
            for process in left {
                Darwin.kill(process.pid, signal)
            }
            logger.info("Sent signal \(signal) to \(left.count) process(es) left after closing")
            if await waitUntilGone(left, seconds: 2) { return }
        }
    }

    /// The image names that can be asked to close by name: those where every
    /// process of that name in the bottle is a target.
    static func askableNames(_ targets: [HostWineProcess], bottleProcesses: [HostWineProcess]) -> Set<String> {
        let targetPIDs = Set(targets.map(\.pid))
        return Set(targets.map(\.imageName)).filter { name in
            bottleProcesses.allSatisfy { $0.imageName != name || targetPIDs.contains($0.pid) }
        }
    }

    /// The targets still in `snapshot`, matched by id, image, bottle and
    /// start time so a recycled process id is never signalled.
    static func stillRunning(_ targets: [HostWineProcess], in snapshot: [HostWineProcess]) -> [HostWineProcess] {
        let running = Set(snapshot.map(identity))
        return targets.filter { running.contains(identity($0)) }
    }

    private static func identity(_ process: HostWineProcess) -> String {
        let start = process.startedAt.map { "\($0.timeIntervalSince1970)" } ?? "-"
        return [String(process.pid), process.imagePath, process.prefixPath, start].joined(separator: "\u{0}")
    }

    /// Whether every one of `processes` exited within `seconds`.
    private static func waitUntilGone(_ processes: [HostWineProcess], seconds: Int) async -> Bool {
        for _ in 0 ..< seconds * 2 {
            if stillRunning(processes, in: await HostWineProcesses.current()).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return stillRunning(processes, in: await HostWineProcesses.current()).isEmpty
    }
}
