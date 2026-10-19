//
//  HomeView.swift
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

/// The landing screen: the game played last, ready to start with one click,
/// and the others played recently beside it.
///
/// Everything here is a shortcut into the library. The full collection, with
/// search and sort, is one click away under "Tümünü gör".
struct HomeView: View {
    @ObservedObject var model: LibraryModel
    let bottles: [Bottle]
    let play: (LibraryRow) -> Void
    let openPage: (LibraryRow) -> Void
    let showLibrary: () -> Void
    let openBottle: (URL) -> Void
    /// False while a game page is pushed over this screen, so Return plays
    /// the game on that page rather than the one under it.
    var isFrontmost = true

    @State private var tint: IconPalette?
    @Environment(\.colorScheme) private var colorScheme

    /// The hero plus the covers row, at most this many.
    private static let recentLimit = 12

    private var games: [LibraryRow] { model.recentGames }
    private var hero: LibraryRow? { games.first }

    var body: some View {
        Group {
            if let hero {
                content(hero: hero)
            } else if model.hasLoaded {
                LibraryEmptyState(bottles: bottles, openBottle: openBottle)
            }
        }
        .navigationTitle("home.title")
        .artPageToolbar()
        .task(id: hero?.id) {
            tint = await hero?.item.pageTint()
        }
    }

    private func content(hero: LibraryRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HomeHero(
                    row: hero,
                    state: model.state(for: hero.item),
                    isRestoring: model.isRestoring(hero.item),
                    pageColor: tint.map { TintedPageBackground.wash($0, scheme: colorScheme) }
                        ?? Color(nsColor: .windowBackgroundColor),
                    isFrontmost: isFrontmost,
                    play: { play(hero) },
                    close: { model.closeRequest = hero },
                    openPage: { openPage(hero) }
                )
                if games.count > 1 {
                    recentRow
                        .padding(.top, 28)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background { TintedPageBackground(tint: tint) }
        .ignoresSafeArea(edges: .top)
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("home.recent")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("home.seeAll", action: showLibrary)
                    .buttonStyle(.link)
                    .font(.body.weight(.medium))
            }
            .padding(.horizontal, HomeHero.margin)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(games.prefix(Self.recentLimit)) { row in
                        GameCover(
                            row: row,
                            state: model.state(for: row.item),
                            backupFailed: model.backupFailed(row.item),
                            play: { play(row) },
                            openPage: { openPage(row) }
                        )
                    }
                }
                .padding(.horizontal, HomeHero.margin)
                // Room for the hover lift and shadow, which a scroll view would clip.
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// "Oynamaya devam et": the last game played, its art across the top of
/// the window and the play button on it.
private struct HomeHero: View {
    static let margin: CGFloat = 40

    let row: LibraryRow
    let state: LibraryEntryState
    let isRestoring: Bool
    let pageColor: Color
    let isFrontmost: Bool
    let play: () -> Void
    let close: () -> Void
    let openPage: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GameHeroArt(item: row.item)
            HeroScrim(pageColor: pageColor)
            VStack(alignment: .leading, spacing: 18) {
                EyebrowText(row.lastPlayed == nil ? "home.start" : "home.continue")
                    .foregroundStyle(.white.opacity(0.85))
                GameLogoOrTitle(item: row.item)
                HStack(spacing: 12) {
                    PlayPillButton(state: state, isRestoring: isRestoring, action: play)
                        .keyboardShortcut(isFrontmost ? .defaultAction : nil)
                    if state == .running {
                        CloseGameButton(action: close)
                    }
                    ArtCircleButton(
                        systemImage: "info",
                        label: "library.card.openPage",
                        help: "library.card.openPage.help",
                        action: openPage
                    )
                }
                if let summary {
                    Text(summary)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 34)
        }
        .frame(height: 470)
        .frame(maxWidth: .infinity)
        .clipped()
        .contextMenu {
            Button("game.page.play", action: play)
            Button("library.card.openPage", action: openPage)
        }
    }

    /// "Toplam 134 sa. · Son oynama: dün".
    private var summary: String? {
        var parts: [String] = []
        if let playtime = row.playtime {
            parts.append(String(localized: "library.card.total \(WhiskyKit.PlaytimeFormat.short(playtime))"))
        }
        if let lastPlayed = row.lastPlayed {
            parts.append(String(localized: "library.card.lastPlayed \(PlaytimeText.relative(lastPlayed))"))
        }
        if let bottleName = row.bottleName {
            parts.append(bottleName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A portrait cover in the "Son oynananlar" row. Clicking it plays the game,
/// like a library card; the "i" and the right-click menu open its page.
struct GameCover: View {
    static let size = CGSize(width: 150, height: 225)

    let row: LibraryRow
    let state: LibraryEntryState
    var backupFailed = false
    let play: () -> Void
    let openPage: () -> Void

    @State private var cover: Image?
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) {
                art
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if isActive {
                    // Outside the cover's button, so a click here does not launch.
                    Button(action: openPage) {
                        Image(systemName: "info")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .cardGlass(.circle, interactive: true)
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .help(Text("library.card.openPage.help"))
                    .accessibilityLabel(Text("library.card.openPage"))
                    .padding(8)
                    .transition(.opacity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Self.size.width, alignment: .leading)
            .accessibilityHidden(true)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            play()
            return .handled
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .contextMenu {
            Button("game.page.play", action: play)
            Button("library.card.openPage", action: openPage)
        }
        .task(id: row.item.id) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(row.item.name))
        .accessibilityValue(Text(subtitle))
        .accessibilityHint(Text("library.card.hint"))
        .accessibilityAction(named: Text("library.card.openPage"), openPage)
    }

    private var art: some View {
        ZStack {
            if let cover {
                Color.clear
                    .overlay { cover.resizable().scaledToFill() }
                    .clipped()
            } else {
                // No portrait art: the wide art or the icon, with the name
                // along the bottom, since the name below may be cut short.
                GameHeroArt(item: row.item, compact: true)
                Text(row.item.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(12)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            stateBadge
            if backupFailed {
                BackupFailedBadge()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : .white.opacity(0.1), lineWidth: isFocused ? 3 : 1)
        }
        .shadow(color: .black.opacity(isActive ? 0.35 : 0.2), radius: isActive ? 12 : 6, y: isActive ? 6 : 3)
        .scaleEffect(isActive ? 1.03 : 1)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .idle:
            if isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .cardGlass(.circle)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity.combined(with: .scale))
            }
        case .launching:
            ProgressView()
                .controlSize(.small)
                .frame(width: 48, height: 48)
                .cardGlass(.circle)
                .environment(\.colorScheme, .dark)
        case .running:
            Label("library.card.running", systemImage: "circle.fill")
                .font(.caption.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .cardGlass(.capsule)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }

    private var subtitle: String {
        if let playtime = row.playtime {
            return String(localized: "library.card.total \(WhiskyKit.PlaytimeFormat.short(playtime))")
        }
        if let lastPlayed = row.lastPlayed {
            return PlaytimeText.relativeStart(lastPlayed)
        }
        return String(localized: "game.page.neverPlayed")
    }

    private func load() async {
        if let url = row.item.portraitURL, let decoded = await GameArtwork.shared.image(at: url, maxPixels: 600) {
            cover = Image(nsImage: decoded)
        }
    }
}
