//
//  LibraryModel+Launch.swift
//  Whisky
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
import Foundation
import WhiskyKit

/// A launch held back until the person has read why it may not work.
struct LibraryLaunchWarning {
    let row: LibraryRow
    let warning: GraphicsProbe.DX12Warning
    let useTerminal: Bool
}

/// Whichever of the probe and its timeout answers first decides.
@MainActor
private final class LaunchDecision {
    private var taken = false

    func take() -> Bool {
        defer { taken = true }
        return !taken
    }
}

extension LibraryModel {
    /// Games the person chose to open despite the DirectX 12 warning, each
    /// with the backend it was accepted for: a different backend warns again.
    private static let acceptedWarningsKey = "library.dx12.acceptedBackends"

    /// Every launch from the home screen, the library and a game page goes
    /// through here, so the DirectX 12 warning cannot be skipped by launching
    /// another way.
    ///
    /// The entry shows as starting from the click on, and a second click
    /// while it is starting is ignored. The probe is cached and usually
    /// answers at once. When it does not, the game starts anyway after a
    /// short wait: a warning is not worth a launch that feels stuck. The
    /// probe still runs to the end, so the next launch finds its answer cached.
    func requestLaunch(_ row: LibraryRow, bottles: [Bottle]) {
        let id = row.item.id
        // Read now: by the time the probe answers the key may be up.
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        guard !pendingLaunches.contains(id) else { return }
        // Restoring rewrites the save folder; a game started now would read half of it.
        if SaveRestoreGuard.isRestoring(id) {
            launchBlockedByRestore = true
            return
        }
        switch state(for: row.item) {
        case .launching:
            return
        case .running:
            // Steam brings a running game to the front rather than starting another.
            launch(row, bottles: bottles, useTerminal: useTerminal)
            return
        case .idle:
            break
        }
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else {
            launch(row, bottles: bottles, useTerminal: useTerminal)
            return
        }
        pendingLaunches.insert(id)
        // Two tasks rather than a task group: a group waits for every child,
        // so a slow probe would hold the launch however short the timeout.
        let decision = LaunchDecision()
        Task {
            let warning = await GraphicsProbe.dx12Warning(for: row.item, bottle: bottle)
            if decision.take() { finishProbe(row, warning: warning, bottles: bottles, useTerminal: useTerminal) }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if decision.take() { finishProbe(row, warning: nil, bottles: bottles, useTerminal: useTerminal) }
        }
    }

    /// How the person answered the warning that is showing.
    enum WarningAnswer {
        case openSettings
        case launchAnyway
        case cancel
    }

    /// Closes the warning that is showing, acts on the answer, and brings up
    /// the next queued one, if another launch is waiting on its own warning.
    func answerWarning(_ answer: WarningAnswer, bottles: [Bottle]) {
        guard let warning = launchWarning else { return }
        launchWarning = nil
        pendingLaunches.remove(warning.row.id)
        if answer == .launchAnyway {
            var accepted = UserDefaults.standard.dictionary(forKey: Self.acceptedWarningsKey) as? [String: String]
                ?? [:]
            accepted[warning.row.id] = warning.warning.backendName
            UserDefaults.standard.set(accepted, forKey: Self.acceptedWarningsKey)
            launch(warning.row, bottles: bottles, useTerminal: warning.useTerminal)
        }
        guard !queuedWarnings.isEmpty else { return }
        // After the closing alert has gone: one presented while it is still
        // dismissing would be dropped. Warnings arriving meanwhile queue behind.
        warningHandoff = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            warningHandoff = false
            if launchWarning == nil, !queuedWarnings.isEmpty {
                launchWarning = queuedWarnings.removeFirst()
            }
        }
    }

    private func hasAccepted(_ warning: GraphicsProbe.DX12Warning, for entry: LibraryEntry) -> Bool {
        let accepted = UserDefaults.standard.dictionary(forKey: Self.acceptedWarningsKey) as? [String: String]
        return accepted?[entry.id] == warning.backendName
    }

    private func finishProbe(
        _ row: LibraryRow, warning: GraphicsProbe.DX12Warning?, bottles: [Bottle], useTerminal: Bool
    ) {
        guard let warning, !hasAccepted(warning, for: row.item) else {
            pendingLaunches.remove(row.item.id)
            launch(row, bottles: bottles, useTerminal: useTerminal)
            return
        }
        // Still pending: the entry stays "starting" until the person answers.
        // Queued rather than replacing a warning already up, so no launch is
        // lost without a word.
        let held = LibraryLaunchWarning(row: row, warning: warning, useTerminal: useTerminal)
        if launchWarning == nil, !warningHandoff {
            launchWarning = held
        } else {
            queuedWarnings.append(held)
        }
    }
}
