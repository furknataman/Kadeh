//
//  LibraryView.swift
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
import SwiftUI
import WhiskyKit

/// Everything worth launching, across every bottle, in the order the person
/// picked.
///
/// The home screen is ``HomeView``; this is the whole collection with search
/// and sort. Entries come from ``LibraryCatalogue``, so Steam games sit beside
/// pinned programs and a future launcher needs no change here. Rows, running
/// state and launching belong to the shared ``LibraryModel``.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let bottles: [Bottle]
    let play: (LibraryRow) -> Void
    let openPage: (LibraryRow) -> Void
    let openBottle: (URL) -> Void

    @AppStorage("librarySort") private var sort: LibrarySort = .recent

    @State private var search: String = ""
    @State private var patchRow: LibraryRow?

    private var visible: [LibraryRow] {
        guard !search.isEmpty else { return model.rows }
        return model.rows.filter { $0.item.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                if model.hasLoaded {
                    LibraryEmptyState(bottles: bottles, openBottle: openBottle)
                }
            } else {
                grid
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .toolbar { sortMenu }
        .sheet(item: $patchRow) { row in
            TurkishPatchSheet(row: row, bottle: bottles.first { $0.url == row.item.bottleURL })
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // 180 rather than 220 so two columns fit at the window's own
                // minimum width, where the sidebar leaves about 330pt: one
                // column of landscape cards is a list with wasted space.
                columns: [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 14)],
                spacing: 14
            ) {
                ForEach(visible) { row in
                    LibraryCard(
                        item: row.item,
                        bottleName: row.bottleName,
                        lastPlayed: row.lastPlayed,
                        playtime: row.playtime,
                        state: model.state(for: row.item),
                        backupFailed: model.backupFailed(row.item),
                        launch: { play(row) },
                        openPage: row.item.isLauncher ? nil : { openPage(row) }
                    )
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("library.card.play") { play(row) }
        if !row.item.isLauncher {
            Button("library.card.openPage") { openPage(row) }
        }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.closeRequest = row }
        }
        Divider()
        if case let .program(url) = row.item.launch {
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if row.item.source == .pinned {
                Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
            }
        }
        if model.hasTurkishPatch(row.item) {
            Button("library.card.turkishPatch") { patchRow = row }
        }
        // Per-program settings live inside the bottle's own navigation stack,
        // which the library cannot push onto, so this is as close as the menu
        // gets without a deep link into it.
        Button("library.card.configure") {
            openBottle(row.item.bottleURL)
        }
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        bottle.settings.pins.removeAll { $0.url == url }
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }
}

/// What the home screen and the library show before anything is installed.
struct LibraryEmptyState: View {
    let bottles: [Bottle]
    let openBottle: (URL) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        } actions: {
            if let first = bottles.first {
                Button("library.empty.pinHint") { openBottle(first.url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
