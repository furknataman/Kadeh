//
//  GamePageView.swift
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

/// One game's own page: its art, the play button, how much it has been
/// played, what it needs, and its saves.
///
/// A full page in the detail column, pushed over the home screen, the
/// library or the playtime list, with a back button to return. It was a
/// sheet, which left no room for the art and put a second window's worth of
/// chrome around a short visit.
struct GamePageView: View {
    let row: LibraryRow
    let bottle: Bottle?
    @ObservedObject var model: LibraryModel
    let play: () -> Void
    /// Opens the bottle's settings, where the graphics backend is chosen.
    let openBottleSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var directX: DirectXLevel?
    @State private var dx12Warning: GraphicsProbe.DX12Warning?
    @State private var size: Int64?
    @State private var tint: IconPalette?
    @State private var showPatch = false

    private var isSteam: Bool {
        if case .steam = row.item.launch { return true }
        return false
    }

    /// A Switch game runs in the emulator, which keeps its own saves: no bottle
    /// to back up from or configure.
    private var isSwitch: Bool { row.item.source == .nintendoSwitch }

    private var state: LibraryEntryState { model.state(for: row.item) }

    private var pageColor: Color {
        tint.map { TintedPageBackground.wash($0, scheme: colorScheme) } ?? Color(nsColor: .windowBackgroundColor)
    }

    private static let savesID = "saves"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content(proxy)
            }
        }
        .scrollContentBackground(.hidden)
        .background { TintedPageBackground(tint: tint) }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(row.item.name)
        .artPageToolbar()
        .background { backShortcuts }
        .sheet(isPresented: $showPatch) {
            TurkishPatchSheet(row: row, bottle: bottle)
        }
        .task(id: row.item.id) { await load() }
    }

    private func content(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 24) {
                GameStatsStrip(
                    row: row, size: size, directX: directX, dx12Warning: dx12Warning,
                    backup: isSwitch ? nil : model.backupOverviews[row.id],
                    openBottleSettings: openBottleSettings,
                    showSaves: {
                        withAnimation { proxy.scrollTo(Self.savesID, anchor: .top) }
                    }
                )
                if isSteam, row.playtime != nil {
                    Text("game.page.steamPlaytimeNote")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isSwitch {
                    VStack(alignment: .leading, spacing: 12) {
                        // Live, so restoring locks the moment the game starts.
                        GameSavesSection(entry: row.item, isBusy: model.isBusy(row.item))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .id(Self.savesID)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            GameHeroArt(item: row.item)
            HeroScrim(pageColor: pageColor)
            VStack(alignment: .leading, spacing: 20) {
                GameLogoOrTitle(item: row.item)
                HStack(spacing: 12) {
                    PlayPillButton(state: state, isRestoring: model.isRestoring(row.item), action: play)
                        .keyboardShortcut(.defaultAction)
                    if state == .running {
                        CloseGameButton { model.closeRequest = row }
                    }
                    if model.hasTurkishPatch(row.item) {
                        ArtCapsuleButton(title: "game.page.turkishPatch", systemImage: "character.bubble") {
                            showPatch = true
                        }
                    }
                }
                if let dx12Warning {
                    DX12Capsule(warning: dx12Warning, action: openBottleSettings)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        // Low enough that the saves start above the fold on a laptop screen.
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Esc and ⌘[ go back, as they do in Finder and Safari. The toolbar's back
    /// button is the visible way; these are the keyboard's.
    private var backShortcuts: some View {
        Group {
            Button("game.page.back") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("game.page.back") { dismiss() }
                .keyboardShortcut("[", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func load() async {
        let item = row.item
        async let level = GraphicsProbe.directX(for: item)
        async let bytes = InstallSize.bytes(for: item)
        async let pageTint = item.pageTint()
        tint = await pageTint
        directX = await level
        if directX == .dx12, let bottle {
            dx12Warning = await GraphicsProbe.dx12Warning(for: item, bottle: bottle)
        }
        size = await bytes
    }
}

/// The row of figures under a game's art: total time, last played, size,
/// DirectX and bottle, each with a small uppercase label above its value.
private struct GameStatsStrip: View {
    let row: LibraryRow
    let size: Int64?
    let directX: DirectXLevel?
    let dx12Warning: GraphicsProbe.DX12Warning?
    let backup: SaveBackupOverview?
    let openBottleSettings: () -> Void
    /// Scrolls to the saves section, where backups are set up.
    let showSaves: () -> Void

    /// "Dün 21:40", "Bugün 09:12", else the date.
    private static let backupDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) { items(divided: true) }
            VStack(alignment: .leading, spacing: 16) { items(divided: false) }
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func items(divided: Bool) -> some View {
        if row.playtime == nil, row.lastPlayed == nil {
            stat("game.page.stat.total", divided: divided, isFirst: true) { Text("game.page.neverPlayed") }
        } else {
            if let playtime = row.playtime {
                stat("game.page.stat.total", divided: divided, isFirst: true) {
                    Text(WhiskyKit.PlaytimeFormat.short(playtime))
                        .accessibilityLabel(Text(PlaytimeText.full(playtime)))
                }
            }
            if let lastPlayed = row.lastPlayed {
                stat("game.page.stat.lastPlayed", divided: divided, isFirst: row.playtime == nil) {
                    Text(PlaytimeText.relativeStart(lastPlayed))
                        .help(lastPlayed.formatted(date: .long, time: .shortened))
                }
            }
        }
        if let size {
            stat("game.page.stat.size", divided: divided) {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
        if let directX {
            stat("game.page.stat.directX", divided: divided) { directXValue(directX) }
        }
        if let backup {
            stat("game.page.stat.backup", divided: divided) { backupValue(backup) }
        }
        // A Switch game's "Nintendo Switch" is not a bottle, and the label would say it was.
        if let bottleName = row.bottleName, row.item.source != .nintendoSwitch {
            stat("game.page.stat.bottle", divided: divided) { Text(bottleName) }
        }
    }

    @ViewBuilder
    private func backupValue(_ backup: SaveBackupOverview) -> some View {
        if !backup.configured {
            HStack(spacing: 10) {
                Text("game.page.backup.off")
                Button("game.page.backup.setUp", action: showSaves)
                    .controlSize(.small)
                    .help(Text("game.page.backup.setUp.help"))
            }
        } else if backup.lastAttemptFailed {
            Text("game.page.backup.failed")
                .foregroundStyle(.red)
        } else if let last = backup.lastBackup {
            Text(Self.backupDate.string(from: last))
        } else {
            Text("game.page.backup.none")
        }
    }

    @ViewBuilder
    private func directXValue(_ level: DirectXLevel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(level.rawValue)")
            if let dx12Warning {
                Label("game.page.dx12.short", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(dx12Warning.message)
                Button("library.warning.openSettings", action: openBottleSettings)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(dx12Warning.message)
                    .accessibilityHint(Text(dx12Warning.message))
            }
        }
    }

    private func stat(
        _ label: String.LocalizationValue, divided: Bool, isFirst: Bool = false, @ViewBuilder value: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if divided && !isFirst {
                Divider().frame(height: 52)
                    .padding(.horizontal, 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                EyebrowText(label)
                    .foregroundStyle(.secondary)
                value()
                    .font(.title2.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The orange note beside "Oyna" when the bottle's graphics setting cannot
/// run the game's DirectX 12; a click opens that setting.
private struct DX12Capsule: View {
    let warning: GraphicsProbe.DX12Warning
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("game.page.dx12.short", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.orange, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .help(warning.message)
        .accessibilityHint(Text("library.warning.openSettings"))
    }
}

/// How save folders and the backup folder read to a person rather than to Wine.
enum SavePlaceText {
    /// "Belgeler › Marvel's Spider-Man Remastered" rather than
    /// "drive_c/users/crossover/Documents/Marvel's Spider-Man Remastered".
    static func path(of folder: SaveFolder) -> String {
        guard folder.inBottle else {
            return (folder.path as NSString).abbreviatingWithTildeInPath
                .split(separator: "/").joined(separator: " › ")
        }
        var parts = folder.path.split(separator: "/").map(String.init)
        if parts.first == "drive_c" { parts.removeFirst() }
        if parts.first == "users", parts.count > 2 {
            parts.removeFirst(2)
            switch parts.first {
            case "Documents": parts[0] = String(localized: "saves.place.documents")
            case "Saved Games": parts[0] = String(localized: "saves.place.savedGames")
            default: break
            }
        } else if let steam = parts.firstIndex(of: "Steam"), parts.count > steam + 1 {
            parts.removeFirst(steam)
        }
        return parts.joined(separator: " › ")
    }

    /// Why it was suggested, how big it is and when it last changed.
    static func details(of candidate: SaveCandidate) -> String {
        let reason = switch candidate.reason {
        case .steamCloud: String(localized: "saves.reason.steamCloud")
        case .nameMatch: String(localized: "saves.reason.nameMatch")
        case .gameFolder: String(localized: "saves.reason.gameFolder")
        case .recentlyChanged: String(localized: "saves.reason.recentlyChanged")
        }
        var parts = [reason, ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file)]
        if let modified = candidate.modified {
            parts.append(String(localized: "saves.lastChanged \(PlaytimeText.relative(modified))"))
        }
        return parts.joined(separator: " · ")
    }

    /// "iCloud Drive › Kadeh › Kayıt Yedekleri" for the iCloud folder.
    static func location(_ url: URL) -> String {
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
            .path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasPrefix(iCloud) {
            let rest = path.dropFirst(iCloud.count).split(separator: "/")
            return (["iCloud Drive"] + rest.map(String.init)).joined(separator: " › ")
        }
        return ("/" + path as NSString).abbreviatingWithTildeInPath
            .split(separator: "/").joined(separator: " › ")
    }
}
