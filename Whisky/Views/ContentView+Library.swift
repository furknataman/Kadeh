//
//  ContentView+Library.swift
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

import SwiftUI
import WhiskyKit

// MARK: - Home, library and game pages

extension ContentView {
    var activeBottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    /// Every input that changes what the library should contain. Pins live in
    /// bottle settings, so a program pinned in the bottle screen shows up
    /// without a relaunch; the toolbar's refresh is folded in because the
    /// bottle list is unchanged by a refresh.
    var libraryReloadTrigger: String {
        let bottles = activeBottles
        let pins = bottles.flatMap { $0.settings.pins.map(\.name) }
        return (bottles.map(\.url.path) + pins + [switchGamesFolder, "\(triggerRefresh)"]).joined(separator: "\u{1F}")
    }

    /// The home screen, library or playtime list, with game pages pushed over
    /// them. A stack rather than a sheet, so going back keeps the library's
    /// search and scroll position.
    var libraryDetail: some View {
        NavigationStack(path: $gamePath) {
            Group {
                switch selected ?? .home {
                case .library:
                    LibraryView(
                        model: library,
                        bottles: activeBottles,
                        play: play,
                        openPage: openPage,
                        openBottle: { selected = .bottle($0) }
                    )
                case .playtime:
                    PlaytimeView(entries: library.rows.map(\.item)) { entry in
                        gamePath.append(entry.id)
                    }
                case .home, .bottle:
                    HomeView(
                        model: library,
                        bottles: activeBottles,
                        play: play,
                        openPage: openPage,
                        showLibrary: { selected = .library },
                        openBottle: { selected = .bottle($0) },
                        isFrontmost: gamePath.isEmpty
                    )
                }
            }
            .navigationDestination(for: String.self) { id in
                gamePage(id: id)
            }
        }
        .toast($library.toast)
    }

    @ViewBuilder
    func gamePage(id: String) -> some View {
        if let row = library.row(id: id) {
            GamePageView(
                row: row,
                bottle: activeBottles.first { $0.url == row.item.bottleURL },
                model: library,
                play: { play(row) },
                openBottleSettings: { openBottleSettings(row.item.bottleURL) }
            )
        } else {
            // The game was uninstalled or its bottle removed while the page was open.
            ContentUnavailableView("game.page.missing", systemImage: "questionmark.square.dashed")
        }
    }

    func play(_ row: LibraryRow) {
        library.requestLaunch(row, bottles: activeBottles)
    }

    func openPage(_ row: LibraryRow) {
        gamePath.append(row.id)
    }

    /// The bottle's configuration, where its graphics backend is chosen.
    func openBottleSettings(_ url: URL) {
        settingsRequest = url
        settingsToken = UUID()
        selected = .bottle(url)
    }
}

// MARK: - Launch alerts

extension View {
    /// The alerts a launch from any screen can raise, attached once at the
    /// top so the home screen, the library and game pages share them.
    func libraryLaunchAlerts(
        model: LibraryModel, bottles: [Bottle], openSettings: @escaping (URL) -> Void
    ) -> some View {
        modifier(LibraryLaunchAlerts(model: model, bottles: bottles, openSettings: openSettings))
    }
}

private struct LibraryLaunchAlerts: ViewModifier {
    @ObservedObject var model: LibraryModel
    let bottles: [Bottle]
    let openSettings: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "library.warning.title",
                isPresented: Binding(
                    get: { model.launchWarning != nil },
                    // Only reached when the alert closes without a button;
                    // after a button the warning is already answered.
                    set: { if !$0 { model.answerWarning(.cancel, bottles: bottles) } }
                ),
                presenting: model.launchWarning
            ) { warning in
                // Fixing the setting is the default: Return takes the safe way
                // that makes the game work, Esc gives up.
                Button("library.warning.openSettings") {
                    model.answerWarning(.openSettings, bottles: bottles)
                    openSettings(warning.row.item.bottleURL)
                }
                .keyboardShortcut(.defaultAction)
                Button("library.warning.launchAnyway") {
                    model.answerWarning(.launchAnyway, bottles: bottles)
                }
                Button("library.warning.cancel", role: .cancel) {
                    model.answerWarning(.cancel, bottles: bottles)
                }
            } message: { warning in
                Text(warning.warning.message)
            }
            .alert(
                "library.launch.failed",
                isPresented: Binding(
                    get: { model.launchError != nil },
                    set: { if !$0 { model.launchError = nil } }
                )
            ) {
                Button("button.ok") { model.launchError = nil }
            } message: {
                Text(model.launchError ?? "")
            }
            // The same wording as closing from the Etkinlik window.
            .confirmationDialog(
                model.closeRequest.map { String(localized: "activity.close.title \($0.item.name)") } ?? "",
                isPresented: Binding(
                    get: { model.closeRequest != nil },
                    set: { if !$0 { model.closeRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: model.closeRequest
            ) { row in
                Button("activity.close.confirm", role: .destructive) {
                    model.close(row, bottles: bottles)
                }
                Button("activity.cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("activity.close.message")
            }
            .alert("library.restoring.title", isPresented: $model.launchBlockedByRestore) {
                Button("button.ok", role: .cancel) {}
            } message: {
                Text("library.restoring.message")
            }
    }
}
