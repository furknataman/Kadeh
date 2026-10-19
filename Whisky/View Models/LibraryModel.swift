//
//  LibraryModel.swift
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
import Combine
import Foundation
import WhiskyKit

/// How the library grid is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case mostPlayed
    case name
    case bottle

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .mostPlayed: "library.sort.mostPlayed"
        case .name: "library.sort.name"
        case .bottle: "library.sort.bottle"
        }
    }
}

/// A library entry plus what the grid needs to draw it. `bottleName`,
/// `lastPlayed` and `playtime` are presentation, which is why they live here
/// rather than in ``LibraryEntry``.
struct LibraryRow: Identifiable {
    let item: LibraryEntry
    let bottleName: String?
    /// The newest of every date known: Kadeh's own launches, Steam's
    /// `LastPlayed` and Kadeh's counted sessions.
    let lastPlayed: Date?
    /// Steam's own total for a Steam game, Kadeh's count for anything else.
    /// `nil` when nothing has been played.
    let playtime: TimeInterval?

    var id: String { item.id }
}

/// Builds the library and owns what is currently starting or running.
///
/// A view model rather than view state because the running half comes from a
/// ``SteamClientOrchestrator`` per bottle, and those are long-lived objects with
/// their own pollers: the library previously made one per launch and threw it
/// away, so everything it published (the launch phase, the running App IDs, the
/// launch error) went nowhere.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [LibraryRow] = []
    /// Whether a reload has finished at least once, so an empty library can
    /// be told from one that has not been read yet.
    @Published private(set) var hasLoaded = false
    @Published var launchError: String?
    @Published var toast: ToastData?
    /// A launch held back until the person has read why it may not work.
    @Published var launchWarning: LibraryLaunchWarning?
    /// Set when a launch was refused because the game's saves are being restored.
    @Published var launchBlockedByRestore = false
    /// Entries between the click on Play and their launch actually starting:
    /// probing for DirectX 12, waiting on the warning, or reading the install.
    @Published var pendingLaunches: Set<String> = []
    /// Warnings for other launches that came while one was showing.
    var queuedWarnings: [LibraryLaunchWarning] = []
    /// A queued warning is about to be shown after the last one closed.
    var warningHandoff = false
    /// Each entry's save backup state, for the game page and the failed-backup badge.
    @Published private(set) var backupOverviews: [String: SaveBackupOverview] = [:]
    /// A running game the person asked to close, waiting on their confirmation.
    @Published var closeRequest: LibraryRow?
    /// Steam games the bundled catalogue knows a Türkçe yama for.
    @Published private(set) var turkishPatchAppIDs: Set<Int> = []

    /// App IDs with a launch in flight, per bottle.
    @Published private var steamLaunching: [URL: Set<Int>] = [:]
    /// App IDs whose own processes are in the bottle's process list.
    @Published private var steamRunning: [URL: Set<Int>] = [:]
    /// Programs whose launch call has not returned yet.
    @Published private var programLaunching: Set<URL> = []

    var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue else { return }
            rows = sorted(rows)
        }
    }

    private var orchestrators: [URL: SteamClientOrchestrator] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// What the last reload built from, so a game ending can refresh the
    /// playtime without the view asking.
    private var lastBottles: [Bottle] = []
    private var sessionRefresh: Task<Void, Never>?

    init() {
        GameEndActions.install()
        let sessions = GameSessions.shared
        // A program's running state comes from the session watcher, so the
        // cards have to redraw when it changes.
        sessions.$active
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessions.ended
            .sink { [weak self] end in self?.refreshAfter(end) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .saveBackupStatusChanged)
            .compactMap { $0.object as? String }
            .sink { [weak self] entryID in self?.refreshBackupOverviews(for: [entryID]) }
            .store(in: &cancellables)
        // The play buttons are disabled while a game's saves are restored.
        NotificationCenter.default.publisher(for: .saveRestoreStateChanged)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - State

    /// What a card should be showing.
    ///
    /// Running is checked before launching because a Steam launch stays in its
    /// grace period for up to two minutes while shaders precompile, which can
    /// outlast the game actually appearing.
    func state(for entry: LibraryEntry) -> LibraryEntryState {
        switch entry.launch {
        case let .program(url):
            if GameSessions.shared.active[entry.id]?.seenRunning == true {
                .running
            } else {
                programLaunching.contains(url) || pendingLaunches.contains(entry.id) ? .launching : .idle
            }
        case let .steam(appID):
            if steamRunning[entry.bottleURL]?.contains(appID) == true {
                .running
            } else if steamLaunching[entry.bottleURL]?.contains(appID) == true
                        || pendingLaunches.contains(entry.id) {
                .launching
            } else {
                .idle
            }
        }
    }

    /// Whether the entry's last save backup failed, for the badge on its card.
    func backupFailed(_ entry: LibraryEntry) -> Bool {
        backupOverviews[entry.id]?.lastAttemptFailed == true
    }

    /// Re-reads the backup state of these entries off the main actor.
    func refreshBackupOverviews(for ids: [String]) {
        Task {
            let read = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: ids.map { ($0, SaveBackupOverviews.overview(for: $0)) })
            }.value
            backupOverviews.merge(read) { _, new in new }
        }
    }

    /// Whether the catalogue lists a Türkçe yama for the entry.
    func hasTurkishPatch(_ entry: LibraryEntry) -> Bool {
        guard case let .steam(appID) = entry.launch else { return false }
        return turkishPatchAppIDs.contains(appID)
    }

    /// Whether the entry's saves are being restored, when it must not start.
    func isRestoring(_ entry: LibraryEntry) -> Bool {
        SaveRestoreGuard.isRestoring(entry.id)
    }

    /// Whether any game Kadeh knows of is starting or running, for the
    /// sidebar's activity dot.
    var isAnythingRunning: Bool {
        steamRunning.values.contains { !$0.isEmpty }
            || GameSessions.shared.active.values.contains { $0.seenRunning }
    }

    /// Games (not launchers), most recently played first whatever the grid's
    /// sort is: the home screen is about what was played last.
    var recentGames: [LibraryRow] {
        rows.filter { !$0.item.isLauncher }.sorted(by: byRecency)
    }

    /// The row for an entry id, from the latest reload.
    func row(id: String) -> LibraryRow? {
        rows.first { $0.id == id }
    }

    // MARK: - Building

    /// Rebuilds every row in one pass.
    ///
    /// Rebuilt whole rather than per card: enumerating Steam walks
    /// `libraryfolders.vdf` and every run log lookup is a plist read, so doing
    /// it inside a card turns scrolling into disk traffic.
    func reload(bottles: [Bottle]) async {
        lastBottles = bottles
        var built: [LibraryRow] = []
        let showBottleName = bottles.count > 1
        let routed = GameRouting().lastLaunches()
        let counted = await Task.detached { PlaytimeStore().all() }.value
        if turkishPatchAppIDs.isEmpty {
            turkishPatchAppIDs = await Task.detached(priority: .utility) {
                Set(GameDBLoader.loadDefaults().compactMap { entry in
                    entry.turkishPatches?.isEmpty == false ? entry.steamAppId : nil
                })
            }.value
        }

        for bottle in bottles {
            let url = bottle.url
            // Pins come straight from settings, which is a main-actor read.
            // Steam is the part that walks the filesystem, so only that goes
            // off the main actor, and it needs nothing but the bottle URL.
            let pinned = PinnedLibrarySource.items(inBottleAt: url, settings: bottle.settings)
            let steam = await Task.detached { SteamLibrarySource.entries(inBottleAt: url) }.value
            let shortcuts = await Task.detached { ShortcutLibrarySource.entries(inBottleAt: url) }.value
            let steamPlay = await Task.detached { SteamPlaytimeReader.records(inBottleAt: url) }.value

            for item in LibraryCatalogue.merge([pinned, steam, shortcuts]) {
                let played = playtime(for: item, steam: steamPlay, counted: counted)
                let dates = [lastLaunched(for: item, routed: routed), played?.lastPlayed].compactMap { $0 }
                built.append(
                    LibraryRow(
                        item: item,
                        bottleName: showBottleName ? bottle.settings.name : nil,
                        lastPlayed: dates.max(),
                        playtime: played.map(\.seconds).flatMap { $0 > 0 ? $0 : nil }
                    )
                )
            }
        }

        rows = sorted(built)
        hasLoaded = true
        refreshBackupOverviews(for: built.map(\.id))
        // After the rows exist: the first poll can report a game that is
        // already running, and that report needs a row to belong to.
        for bottle in bottles {
            trackSteam(in: bottle)
        }
    }

    /// Steam's record for a Steam game, which knows about play outside
    /// Kadeh; Kadeh's own count for anything else. A Steam game's own count
    /// is still read for its date, in case Steam has not written yet.
    private func playtime(
        for item: LibraryEntry, steam: [Int: SteamPlayRecord], counted: [String: Playtime]
    ) -> Playtime? {
        let own = counted[item.id]
        guard case let .steam(appID) = item.launch, let record = steam[appID] else { return own }
        let dates = [record.lastPlayed, own?.lastPlayed].compactMap { $0 }
        return Playtime(seconds: record.playtime.seconds, lastPlayed: dates.max())
    }

    /// When an entry was last started in Kadeh.
    private func lastLaunched(
        for item: LibraryEntry, routed: [Int: Date]
    ) -> Date? {
        switch item.launch {
        case let .program(url):
            RunLogStore.load(for: url.lastPathComponent, in: item.bottleURL)
                .entries.map(\.startTime).max()
        case let .steam(appID):
            routed[appID]
        }
    }

    /// Launchers last whatever the sort is. A storefront client is how you reach
    /// a game, not one of them, and it would otherwise take the top of the grid
    /// on recency because every game launch runs it.
    private func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { first, second in
            if first.item.isLauncher != second.item.isLauncher {
                return second.item.isLauncher
            }
            return switch sort {
            case .recent: byRecency(first, second)
            case .mostPlayed: byPlaytime(first, second)
            case .name: byName(first, second)
            case .bottle: byBottle(first, second)
            }
        }
    }

    private func byRecency(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        switch (first.lastPlayed, second.lastPlayed) {
        case let (lhs?, rhs?): lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): byName(first, second)
        }
    }

    private func byPlaytime(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        let lhs = first.playtime ?? 0
        let rhs = second.playtime ?? 0
        guard lhs == rhs else { return lhs > rhs }
        return byRecency(first, second)
    }

    private func byName(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        first.item.name.localizedStandardCompare(second.item.name) == .orderedAscending
    }

    private func byBottle(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        let lhs = first.bottleName ?? ""
        let rhs = second.bottleName ?? ""
        guard lhs == rhs else { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
        return byName(first, second)
    }
}

// MARK: - Launching

extension LibraryModel {
    /// - Parameter useTerminal: Whether Shift was held when the person asked,
    ///   read by the caller at that moment. `nil` reads it now.
    ///
    /// Reading the install (Steam's manifests, the game's executables) runs
    /// off the main actor; the entry shows as starting meanwhile. Restoring
    /// saves is checked again at the last moment, since one can start while
    /// the launch was waiting.
    func launch(_ row: LibraryRow, bottles: [Bottle], useTerminal: Bool? = nil) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }
        let entry = row.item
        let terminal = useTerminal ?? NSEvent.modifierFlags.contains(.shift)
        pendingLaunches.insert(entry.id)

        Task {
            switch entry.launch {
            case let .program(url):
                let names = await Task.detached(priority: .userInitiated) {
                    GameSessions.executables(for: entry)
                }.value
                defer { pendingLaunches.remove(entry.id) }
                guard !blockedByRestore(entry) else { return }
                GameSessions.shared.began(entry, executables: names)
                launchProgram(at: url, in: bottle, useTerminal: terminal)
            case let .steam(appID):
                let bottleURL = bottle.url
                let found = await Task.detached(priority: .userInitiated) { () -> (SteamGame, Set<String>)? in
                    guard let game = SteamLibrary.enumerate(bottleURL: bottleURL).first(where: { $0.appId == appID })
                    else { return nil }
                    return (game, SteamLibrary.executableNames(under: game.installURL))
                }.value
                // Removed in the same turn the orchestrator takes over, so the card never flickers idle.
                defer { pendingLaunches.remove(entry.id) }
                guard let found else {
                    launchError = String(localized: "library.launch.steamGameMissing")
                    return
                }
                guard !blockedByRestore(entry) else { return }
                orchestrator(for: bottle).launch(found.0)
                GameSessions.shared.began(entry, executables: found.1)
            }
        }
    }

    private func blockedByRestore(_ entry: LibraryEntry) -> Bool {
        guard SaveRestoreGuard.isRestoring(entry.id) else { return false }
        launchBlockedByRestore = true
        return true
    }

    /// Whether an entry is starting or running, by any source Kadeh has.
    /// What restoring saves checks before it touches a folder.
    func isBusy(_ entry: LibraryEntry) -> Bool {
        state(for: entry) != .idle || GameSessions.shared.isActive(entry.id)
    }

    /// Closes a running game, Steam or not, the way the Etkinlik window
    /// does: asked politely first, ended after a grace period.
    func close(_ row: LibraryRow, bottles: [Bottle]) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }
        Task { await GameCloser.close(row.item, in: bottle) }
    }

    private func launchProgram(at url: URL, in bottle: Bottle, useTerminal: Bool) {
        // Through the bottle's own program list where possible, so the launch
        // picks up that program's overrides rather than only the bottle's.
        // A program outside the scanned folders (`C:\Games\…`) is not in that
        // list; it still gets its own settings, or it launches on the bottle's
        // renderer instead of the one set for it.
        let program = bottle.programs.first(where: { $0.url == url }) ?? Program(url: url, bottle: bottle)

        programLaunching.insert(url)
        Telemetry.capture(.firstProgramLaunchAttempted)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal)
            programLaunching.remove(url)
            toast = result.toastData
        }
    }

    /// The orchestrator for a bottle, made once and kept.
    ///
    /// Its `phases` and `runningAppIds` are what the cards read, so it has to
    /// outlive the launch that created it.
    private func orchestrator(for bottle: Bottle) -> SteamClientOrchestrator {
        if let existing = orchestrators[bottle.url] {
            return existing
        }

        let made = SteamClientOrchestrator(bottle: bottle, driver: AppSteamClientDriver(bottle: bottle))
        let url = bottle.url
        made.$phases
            .sink { [weak self] phases in
                self?.steamLaunching[url] = Set(phases.keys)
            }
            .store(in: &cancellables)
        made.$runningAppIds
            .sink { [weak self] running in
                self?.reportTransitions(in: url, to: running)
                self?.steamRunning[url] = running
            }
            .store(in: &cancellables)
        made.$launchError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.launchError = error
            }
            .store(in: &cancellables)

        orchestrators[bottle.url] = made
        return made
    }

    /// Starts (or restarts) running-state polling for a bottle's Steam games.
    private func trackSteam(in bottle: Bottle) {
        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard !games.isEmpty else { return }
        orchestrator(for: bottle).startTracking(games: games)
    }

    /// Hands what the poller saw to the session detector, which owns telling
    /// a game that ended from one that never started.
    private func reportTransitions(in bottleURL: URL, to running: Set<Int>) {
        let previous = steamRunning[bottleURL] ?? []
        for appID in running.symmetricDifference(previous) {
            guard let entry = rows.first(where: {
                $0.item.bottleURL == bottleURL && $0.item.launch == .steam(appID: appID)
            })?.item else { continue }
            GameSessions.shared.observe(entry, running: running.contains(appID))
        }
    }

    /// Re-reads playtime once a game has ended, after Steam has written its
    /// own record for a Steam game.
    private func refreshAfter(_ end: GameSessionEnd) {
        let entry = end.session.entry
        sessionRefresh?.cancel()
        sessionRefresh = Task { [weak self] in
            if case .steam = entry.launch {
                await SteamPlaytimeReader.waitForWrite(inBottleAt: entry.bottleURL, after: end.endedAt)
            } else {
                // Long enough for the session to be written.
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, let self else { return }
            await reload(bottles: lastBottles)
        }
    }

    /// Stops every poller. Called when the library leaves the screen.
    func stopTracking() {
        for orchestrator in orchestrators.values {
            orchestrator.stop()
        }
    }
}
