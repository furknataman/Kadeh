//
//  GameArt.swift
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

/// The pieces the home screen and a game page share: the big art, the
/// game's logo, the page tint and the two buttons that sit on the art.

/// A game's wide key art filling its frame, or its icon on its own colour
/// when it has none.
///
/// Steam's `library_hero.jpg` first, since it is made for exactly this; then
/// the header banner the library cards use; then, for a program with no art
/// at all, the icon on a gradient of the icon's own colour.
struct GameHeroArt: View {
    let item: LibraryEntry
    /// A small tile (a cover) rather than a page header: the icon sits centred and smaller.
    var compact = false

    @State private var image: Image?
    @State private var icon: Image?
    @State private var palette: IconPalette = .neutral
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let image {
                // Sized by an empty layer, so scaledToFill cannot push the frame outwards.
                Color.clear
                    .overlay { image.resizable().scaledToFill() }
                    .clipped()
            } else if loaded {
                LinearGradient(
                    colors: [Color(palette.deepened(toLuminance: 0.22)), Color(palette.deepened(toLuminance: 0.06))],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                if let icon {
                    icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 72 : 150, height: compact ? 72 : 150)
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                        .frame(maxWidth: .infinity, alignment: compact ? .center : .trailing)
                        .padding(.trailing, compact ? 0 : 70)
                }
            } else {
                Color.black.opacity(0.25)
            }
        }
        .accessibilityHidden(true)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        if let url = item.heroURL ?? item.artworkURL,
           let decoded = await GameArtwork.shared.image(at: url, maxPixels: 2_400) {
            image = Image(nsImage: decoded)
        } else if let iconURL = item.iconURL {
            let sampled = await IconCache.shared.sampledIcon(for: iconURL)
            palette = sampled.palette
            icon = Image(nsImage: sampled.image)
        }
        loaded = true
    }
}

/// The game's own logo, or its name set large when Steam left no logo.
struct GameLogoOrTitle: View {
    let item: LibraryEntry
    var maxWidth: CGFloat = 380
    var maxHeight: CGFloat = 130

    @State private var logo: Image?
    @State private var loaded = false

    var body: some View {
        // A ZStack rather than a Group: an empty Group has no view to run `.task` on,
        // so the logo would never load.
        ZStack(alignment: .leading) {
            if let logo {
                logo
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
            } else if loaded || item.logoURL == nil {
                Text(item.name)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            }
        }
        // The logo is a picture of the name, so VoiceOver reads the name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(.isHeader)
        .task(id: item.id) {
            if let url = item.logoURL, let decoded = await GameArtwork.shared.image(at: url, maxPixels: 1_000) {
                logo = Image(nsImage: decoded)
            }
            loaded = true
        }
    }
}

extension LibraryEntry {
    /// The colour a page about this entry is tinted with: the average of its
    /// key art, or the colour of its icon when there is no art.
    func pageTint() async -> IconPalette? {
        if let url = heroURL ?? artworkURL, let tint = await GameArtwork.shared.tint(of: url) {
            return tint
        }
        guard let iconURL else { return nil }
        return await IconCache.shared.sampledIcon(for: iconURL).palette
    }
}

/// The window background with a soft wash of the art's colour at the top.
///
/// The wash is taken to a fixed lightness per appearance (dark and deep in
/// dark mode, pale in light mode) so the system's own text colours stay
/// readable on it whatever the art is.
struct TintedPageBackground: View {
    let tint: IconPalette?
    @Environment(\.colorScheme) private var colorScheme

    /// The colour the art fades into at its bottom edge, so the two meet without a seam.
    static func wash(_ tint: IconPalette, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return Color(tint.deepened(toLuminance: 0.09))
        }
        let pale = 0.82
        return Color(
            .sRGB,
            red: tint.red * (1 - pale) + pale,
            green: tint.green * (1 - pale) + pale,
            blue: tint.blue * (1 - pale) + pale
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            if let tint {
                LinearGradient(
                    stops: [
                        .init(color: Self.wash(tint, scheme: colorScheme), location: 0),
                        .init(color: Self.wash(tint, scheme: colorScheme), location: 0.35),
                        .init(color: Self.wash(tint, scheme: colorScheme).opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1_100)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: tint)
        .ignoresSafeArea()
    }
}

/// The darkening laid over key art so white text and buttons on it stay
/// readable, fading at the bottom into the page.
struct HeroScrim: View {
    let pageColor: Color

    var body: some View {
        ZStack {
            // Left side darker: that is where the logo and buttons sit.
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: pageColor.opacity(0.6), location: 0.82),
                    .init(color: pageColor, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

/// The large white "Oyna" button, the most visible thing on the art.
struct PlayPillButton: View {
    let state: LibraryEntryState
    var isRestoring = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                switch state {
                case .idle where isRestoring:
                    ProgressView().controlSize(.small)
                    Text("home.restoring")
                case .idle:
                    Image(systemName: "play.fill")
                    Text("game.page.play")
                case .launching:
                    ProgressView().controlSize(.small)
                    Text("library.card.launching")
                case .running:
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.green)
                    Text("library.card.running")
                }
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 30)
            .frame(minWidth: 150, minHeight: 46)
            .background(.white, in: Capsule())
            .contentShape(Capsule())
            // Black on white in either appearance, the progress spinner too.
            .environment(\.colorScheme, .light)
        }
        .buttonStyle(PressableButtonStyle())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        .disabled(state != .idle || isRestoring)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: LocalizedStringKey {
        if isRestoring { return "home.restoring" }
        return switch state {
        case .idle: "game.page.play"
        case .launching: "library.card.launching"
        case .running: "library.card.running"
        }
    }
}

/// The orange mark on a card or cover whose last save backup failed. The
/// game page says what happened; this only says to look.
struct BackupFailedBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.orange, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .help(Text("library.card.backupFailed"))
            .accessibilityLabel(Text("library.card.backupFailed"))
    }
}

/// "Kapat" beside the "Açık" pill while the game runs; asks before closing.
struct CloseGameButton: View {
    let action: () -> Void

    var body: some View {
        ArtCapsuleButton(title: "library.card.closeGame", systemImage: "xmark", action: action)
    }
}

/// A round glass button on the art, for the "i" and the back arrow.
struct ArtCircleButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var help: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .cardGlass(.circle, interactive: true)
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressableButtonStyle())
        .help(Text(help ?? label))
        .accessibilityLabel(Text(label))
    }
}

/// A capsule glass button on the art, for actions next to "Oyna".
struct ArtCapsuleButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(minHeight: 46)
                .contentShape(Capsule())
                .cardGlass(.capsule, interactive: true)
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Shrinks a little while pressed, so a plain-looking button still answers the click.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// For a page whose art runs up under the toolbar: no toolbar backdrop
    /// over the art and no title, since the art carries the game's own logo.
    /// The controls keep the window's colour scheme: forcing them light
    /// would also whiten the sidebar's own toolbar button over a light sidebar.
    func artPageToolbar() -> some View {
        self
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
    }
}

/// Small uppercase, widely tracked text, the label style of a stats strip and section eyebrow.
struct EyebrowText: View {
    let text: String

    /// Uppercased here in the UI's own language rather than with `.textCase`, so Turkish
    /// gets a dotted capital İ ("ŞİŞE", not "ŞIŞE").
    init(_ key: String.LocalizationValue) {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        text = String(localized: key).uppercased(with: Locale(identifier: language))
    }

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .tracking(1.6)
    }
}
