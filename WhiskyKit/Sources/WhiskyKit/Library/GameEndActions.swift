//
//  GameEndActions.swift
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

public extension Notification.Name {
    /// Posted on the main thread after a game's save backups changed. The
    /// object is the library entry id.
    static let saveBackupsChanged = Notification.Name("com.furkan.kadeh.saveBackupsChanged")
    /// Posted on the main thread after a session was written to the playtime
    /// files. The object is the library entry id.
    static let playtimeChanged = Notification.Name("com.furkan.kadeh.playtimeChanged")
}

/// What happens when a game ends: its session is counted, kept in the play
/// history, and its saves are backed up. Both hang off ``GameSessions/ended`` so there is one detector.
@MainActor
public enum GameEndActions {
    private static var subscription: AnyCancellable?

    /// Subscribes once; later calls do nothing.
    public static func install(sessions: GameSessions = .shared) {
        guard subscription == nil else { return }
        subscription = sessions.ended.sink { end in
            handle(end)
        }
    }

    private static func handle(_ end: GameSessionEnd) {
        let entry = end.session.entry
        let start = end.session.startedAt
        let stop = end.endedAt
        Task.detached(priority: .utility) {
            // Every game goes into the week-by-week history; only a program's
            // time goes into the totals, since Steam keeps its own count,
            // which also knows about other PCs.
            PlayHistoryStore().append(entryID: entry.id, from: start, to: stop)
            if case .program = entry.launch {
                PlaytimeStore().record(entryID: entry.id, from: start, to: stop)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .playtimeChanged, object: entry.id)
            }
        }

        let folders = SaveFolderStore().folders(for: entry.id)
        guard !folders.isEmpty else { return }
        let store = SaveBackupStore.configured()
        Task.detached(priority: .utility) {
            // A game can still be flushing a save as its last process exits.
            try? await Task.sleep(for: .seconds(5))
            do {
                try store.backUp(game: SaveGame(entry), folders: folders, bottleURL: entry.bottleURL)
            } catch {
                // Skipped, not reported: the next session tries again, and an
                // alert after quitting a game is the wrong moment for it.
                Logger.wineKit.info("Automatic save backup skipped: \(error.localizedDescription)")
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .saveBackupsChanged, object: entry.id)
            }
        }
    }
}
