//
//  GameSavesSection.swift
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

/// The "Kayıtlar" part of a game page: which folders hold the saves, and the
/// backups of them.
///
/// Three steps, one at a time, so the section never shows more than the
/// person needs right now: a single button until a folder is known, the
/// suggestions while they choose, and the folders and backups after.
///
/// Lays itself out with stacks and dividers: the page hosts it in a plain
/// card, not a `Form`.
struct GameSavesSection: View {
    let entry: LibraryEntry
    /// Starting or running: restoring is not allowed while the game can write.
    /// Read live on every render, never copied.
    let isBusy: Bool

    private enum Step: Equatable {
        case loading
        /// No confirmed folder yet.
        case start
        case searching
        case choosing
        case confirmed
    }

    @State private var step: Step = .loading
    @State private var folders: [SaveFolder] = []
    @State private var candidates: [SaveCandidate] = []
    @State private var chosen: Set<SaveFolder> = []
    @State private var backups: [SaveBackup] = []
    @State private var lastAttempt: SaveBackupAttempt?
    @State private var working = false
    /// Set from ``SaveRestoreGuard``, so a restore started anywhere locks the buttons.
    @State private var restoringNow = false
    @State private var message: String?
    @State private var errorText: String?
    /// Something Kadeh changed on its own and the person should know about.
    @State private var notice: String?
    @State private var restoring: SaveBackup?

    private var store: SaveBackupStore { SaveBackupStore.configured() }
    private var game: SaveGame { SaveGame(entry) }
    private var locked: Bool { working || restoringNow }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("saves.title")
                .font(.title3.weight(.semibold))
            switch step {
            case .loading:
                ProgressView().controlSize(.small)
            case .start:
                startView
            case .searching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("saves.searching")
                }
            case .choosing:
                choosingView
            case .confirmed:
                confirmedView
            }
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Label(notice, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: entry.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .saveBackupsChanged)) { note in
            guard note.object as? String == entry.id else { return }
            Task { await reloadBackups() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveRestoreStateChanged)) { note in
            guard note.object as? String == entry.id else { return }
            restoringNow = SaveRestoreGuard.isRestoring(entry.id)
        }
        .alert(
            "saves.restore.confirm.title",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            presenting: restoring
        ) { backup in
            Button("saves.restore.confirm.action") { restore(backup) }
            Button("saves.cancel", role: .cancel) { restoring = nil }
                .keyboardShortcut(.defaultAction)
        } message: { backup in
            if case .steam = entry.launch {
                Text("saves.restore.confirm.message \(SaveTimeText.full(backup.created))")
                    + Text(verbatim: "\n\n") + Text("saves.restore.confirm.steam")
            } else {
                Text("saves.restore.confirm.message \(SaveTimeText.full(backup.created))")
            }
        }
    }

    // MARK: - Steps

    private var startView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("saves.start.explanation")
                .fixedSize(horizontal: false, vertical: true)
            Button("saves.start.find") { search() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private var choosingView: some View {
        if candidates.isEmpty {
            Text("saves.choose.none")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("saves.choose.explanation")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
        HStack {
            Button("saves.addFolder") { addFolder() }
            Spacer()
            Button("saves.cancel") {
                step = folders.isEmpty ? .start : .confirmed
            }
            if !candidates.isEmpty {
                Button("saves.choose.confirm") { confirm(Array(chosen)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private func candidateRow(_ candidate: SaveCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { chosen.contains(candidate.folder) },
            set: { isOn in
                if isOn { chosen.insert(candidate.folder) } else { chosen.remove(candidate.folder) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SavePlaceText.path(of: candidate.folder))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(SavePlaceText.details(of: candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if candidate.isLarge {
                    Text("saves.candidate.large \(Self.size(candidate.bytes) + (candidate.isCapped ? "+" : ""))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("saves.showInFinder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
        }
    }

    @ViewBuilder
    private var confirmedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(folders, id: \.self) { folder in
                folderRow(folder)
            }
        }
        HStack {
            Button("saves.addFolder") { addFolder() }
                .disabled(locked)
            Spacer()
            Button {
                backUpNow()
            } label: {
                Label("saves.backUpNow", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(locked)
        }
        Text("saves.auto.note")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()
        statusView
        backupsView
    }

    private func folderRow(_ folder: SaveFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(SavePlaceText.path(of: folder))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Menu {
                Button("saves.showInFinder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.url(bottleURL: entry.bottleURL)])
                }
                Button("saves.removeFolder") { remove(folder) }
                    .disabled(locked)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("saves.folder.options")
            .accessibilityLabel(Text("saves.folder.options"))
        }
    }

    /// "Son yedek: dün 21.40 · 7 yedek · 312 MB", and the last failure in red.
    @ViewBuilder
    private var statusView: some View {
        if let lastAttempt, !lastAttempt.succeeded {
            Label(
                String(localized: "saves.status.failed \(lastAttempt.message ?? "")"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let newest = backups.first(where: { !$0.isSafety }) ?? backups.first {
            let total = backups.reduce(Int64(0)) { $0 + $1.bytes }
            Text(
                "saves.status.summary \(SaveTimeText.relative(newest.created)) \(backups.count) \(Self.size(total))"
            )
            .font(.callout)
        }
    }

    @ViewBuilder
    private var backupsView: some View {
        Text("saves.backups.title")
            .font(.headline)
            .padding(.top, 4)
        if isBusy {
            Label("saves.restore.busy", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if backups.isEmpty {
            Text("saves.backups.empty")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                    if index > 0 { Divider() }
                    backupRow(backup)
                }
            }
        }
        HStack(spacing: 4) {
            Text("saves.location")
                .foregroundStyle(.secondary)
            Button(SavePlaceText.location(store.root)) {
                revealBackups()
            }
            .buttonStyle(.link)
            .help("saves.showInFinder")
        }
        .font(.callout)
        .padding(.top, 4)
    }

    private func backupRow(_ backup: SaveBackup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SaveTimeText.relative(backup.created, capitalized: true))
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol(for: backup.kind))
                        .imageScale(.small)
                    Text("\(Self.kindName(backup.kind)) · \(Self.size(backup.bytes))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("saves.restore") { restoring = backup }
                .disabled(isBusy || locked)
                .help(isBusy ? Text("saves.restore.busy") : Text("saves.restore.help"))
        }
        .padding(.vertical, 6)
    }

    static func kindName(_ kind: SaveBackup.Kind) -> String {
        switch kind {
        case .automatic: String(localized: "saves.backup.automatic")
        case .manual: String(localized: "saves.backup.manual")
        case .safety: String(localized: "saves.backup.safety")
        }
    }

    static func symbol(for kind: SaveBackup.Kind) -> String {
        switch kind {
        case .automatic: "gamecontroller"
        case .manual: "hand.tap"
        case .safety: "clock.arrow.circlepath"
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Actions

extension GameSavesSection {
    private func load() async {
        let entryID = entry.id
        let bottleURL = entry.bottleURL
        restoringNow = SaveRestoreGuard.isRestoring(entryID)
        let (loaded, unnested) = await Task.detached {
            let store = SaveFolderStore()
            let stored = store.folders(for: entryID)
            // Confirmed before nested folders were refused: the outer one
            // already holds the inner one, and both would make every backup
            // impossible to restore.
            let nesting = SaveFolderNesting.outermost(stored, bottleURL: bottleURL)
            // No bottleURL: a folder confirmed before places were recorded
            // keeps none rather than silently taking wherever its link points
            // now, so its restore stays limited to the bottle.
            if !nesting.dropped.isEmpty {
                store.setFolders(nesting.kept, for: entryID)
                return (store.folders(for: entryID), !nesting.dropped.isEmpty)
            }
            return (stored, false)
        }.value
        folders = loaded
        if unnested {
            notice = String(localized: "saves.nested.fixed")
        }
        step = folders.isEmpty ? .start : .confirmed
        await reloadBackups()
    }

    private func reloadBackups() async {
        let store = store
        let game = game
        let (found, attempt) = await Task.detached {
            (store.backups(for: game), SaveBackupStatusStore().attempt(for: game.id))
        }.value
        backups = found
        lastAttempt = attempt
    }

    private func search() {
        step = .searching
        clearMessages()
        let entry = entry
        let root = store.root
        let confirmed = Set(folders)
        Task {
            var search = await Self.search(for: entry)
            search.backupRoot = root
            let found = await Task.detached { [search] in SaveLocator.candidates(for: search) }.value
                .filter { !confirmed.contains($0.folder) }
            candidates = found
            // The two reasons that are rarely wrong start ticked; the
            // guesses, and anything large enough to be a cache, wait for the person.
            chosen = Set(found.filter { $0.reason <= .nameMatch && !$0.isLarge }.map(\.folder))
            step = .choosing
        }
    }

    /// What the locator needs, read off the main actor.
    private static func search(for entry: LibraryEntry) async -> SaveSearch {
        await Task.detached {
            switch entry.launch {
            case let .steam(appID):
                let game = SteamLibrary.enumerate(bottleURL: entry.bottleURL).first { $0.appId == appID }
                let started = SteamPlaytimeReader.records(inBottleAt: entry.bottleURL)[appID]?.lastLaunch
                    ?? GameRouting().lastLaunched(forAppId: appID)
                return SaveSearch(
                    title: entry.name, bottleURL: entry.bottleURL, steamAppID: appID,
                    gameFolder: game?.installURL, changedSince: started
                )
            case let .program(url):
                let started = RunLogStore.load(for: url.lastPathComponent, in: entry.bottleURL)
                    .entries.map(\.startTime).max()
                return SaveSearch(
                    title: entry.name, bottleURL: entry.bottleURL,
                    gameFolder: url.deletingLastPathComponent(), changedSince: started
                )
            }
        }.value
    }

    private func confirm(_ added: [SaveFolder]) {
        clearMessages()
        let store = store
        let bottleURL = entry.bottleURL
        // A save folder around or inside the backups could replace them on a
        // restore, or zip itself on a backup.
        let game = game
        let clashing = added.filter { store.overlapsBackups($0, game: game, bottleURL: bottleURL) }
        if !clashing.isEmpty {
            errorText = String(localized: "saves.error.folderOverlap")
        }
        let wasEmpty = folders.isEmpty
        let new = added.filter { !folders.contains($0) && !clashing.contains($0) }
            .map { $0.confirmingLocation(bottleURL: bottleURL) }
        // A folder inside another one is already in its backups; only the
        // outer one is kept.
        let nesting = SaveFolderNesting.outermost(folders + new, bottleURL: bottleURL)
        if !nesting.dropped.isEmpty {
            notice = String(localized: "saves.nested.dropped")
        }
        let merged = nesting.kept
        save(merged)
        candidates = []
        chosen = []
        step = merged.isEmpty ? .start : .confirmed
        // The first backup right away, so the person sees it work.
        if wasEmpty, !merged.isEmpty {
            backUpNow(first: true)
        }
    }

    private func remove(_ folder: SaveFolder) {
        let remaining = folders.filter { $0 != folder }
        save(remaining)
        if remaining.isEmpty {
            step = .start
        }
    }

    private func save(_ new: [SaveFolder]) {
        folders = new
        SaveFolderStore().setFolders(new, for: entry.id, bottleURL: entry.bottleURL)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "saves.addFolder.message")
        panel.directoryURL = entry.bottleURL.appending(path: "drive_c").appending(path: "users")
        let bottleURL = entry.bottleURL
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                confirm([SaveFolder(url: url, bottleURL: bottleURL)])
            }
        }
    }

    private func backUpNow(first: Bool = false) {
        message = nil
        if !first { errorText = nil }
        guard !SaveRestoreGuard.isRestoring(entry.id) else {
            errorText = SaveBackupError.restoreInProgress.localizedDescription
            return
        }
        working = true
        let store = store
        let game = game
        let bottleURL = entry.bottleURL
        let folders = folders
        Task {
            do {
                _ = try await Task.detached {
                    try store.backUp(game: game, folders: folders, bottleURL: bottleURL, trigger: .manual)
                }.value
                message = first ? String(localized: "saves.backUp.first") : String(localized: "saves.backUp.done")
            } catch {
                errorText = error.localizedDescription
            }
            await reloadBackups()
            working = false
        }
    }

    private func restore(_ backup: SaveBackup) {
        restoring = nil
        clearMessages()
        guard !isBusy, !locked else {
            errorText = String(localized: "saves.restore.busy")
            return
        }
        let entry = entry
        // Marked before anything else runs, on the main actor, so the game
        // cannot be started in between.
        SaveRestoreGuard.begin(entry.id)
        restoringNow = true
        working = true
        let store = store
        let game = game
        let folders = folders
        Task {
            defer {
                SaveRestoreGuard.end(entry.id)
                restoringNow = SaveRestoreGuard.isRestoring(entry.id)
                working = false
            }
            // The card can lag behind a game started some other way, so the
            // process list has the last word.
            guard await !GameSessions.isRunning(entry) else {
                errorText = String(localized: "saves.restore.busy")
                return
            }
            do {
                _ = try await Task.detached {
                    try store.restore(backup, game: game, bottleURL: entry.bottleURL, confirmed: folders)
                }.value
                message = String(localized: "saves.restore.done \(SaveTimeText.full(backup.created))")
            } catch {
                errorText = error.localizedDescription
            }
            await reloadBackups()
        }
    }

    private func revealBackups() {
        let folder = store.gameFolder(for: game)
        let target = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) ? folder : store.root
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func clearMessages() {
        message = nil
        errorText = nil
        notice = nil
    }
}

/// Backup times as a person says them: "dün 21.40", "bugün 09.05", older
/// ones by date.
enum SaveTimeText {
    /// The language the app is showing, which dates follow too.
    private static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static func time(_ date: Date) -> String {
        if locale.language.languageCode == .turkish {
            // TDK writes the hour and minute apart with a full stop.
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = "HH.mm"
            return formatter.string(from: date)
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        var style = Date.FormatStyle().locale(locale).day().month(.wide)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    static func relative(_ date: Date, capitalized: Bool = false, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let text: String = if calendar.isDate(date, inSameDayAs: now) {
            String(localized: "saves.when.today \(time(date))")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            String(localized: "saves.when.yesterday \(time(date))")
        } else {
            "\(day(date, now: now)) \(time(date))"
        }
        guard capitalized, let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    /// "12 Ekim 2026 21.40", for "… tarihli yedek".
    static func full(_ date: Date) -> String {
        "\(date.formatted(Date.FormatStyle().locale(locale).day().month(.wide).year())) \(time(date))"
    }
}
