//
//  SteamLauncher.swift
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

import Foundation
import os.log

private let steamLauncherLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamLauncher")

/// Errors thrown when launching a Steam game.
public enum SteamLaunchError: LocalizedError, Equatable {
    /// The bottle has no Steam installation.
    case steamNotInstalled
    /// No bottle known to Whisky has that App ID installed.
    case gameNotFound(appId: Int)

    public var errorDescription: String? {
        switch self {
        case .steamNotInstalled:
            String(localized: "steam.launch.error.noClient")
        case let .gameNotFound(appId):
            String(localized: "steam.launch.error.gameNotFound \(appId)")
        }
    }
}

/// The single launch path for Steam games: resolve the game's GameDB profile,
/// then hand `-applaunch` to the Windows client, which owns DRM and the game
/// process itself.
public enum SteamLauncher {
    /// Launches a game through the bottle's Steam client.
    ///
    /// The game's DLL overrides go into the `AppDefaults` entries of its
    /// executables, and the `-applaunch` invocation carries none in its
    /// environment, which every process it starts would inherit and which
    /// outranks their own entries. So the game gets its plan whether the
    /// running client or this invocation starts it, and the client and its
    /// helpers keep DXVK even when `-applaunch` brings them up (#276).
    ///
    /// Starts the client first when it isn't running, the way Play does: with
    /// `-silent`, as a launch of its own, and only then hands over `-applaunch`,
    /// so the client never inherits the game's environment variables. The
    /// returned task is the `-applaunch` invocation. A command-line
    /// caller has to await it: the launch only happens inside the task, and a
    /// process that exits first takes the task with it before Wine has started
    /// anything.
    ///
    /// - Parameters:
    ///   - appId: The Steam App ID to launch.
    ///   - bottle: The bottle whose Steam client to use.
    ///   - installURL: The game's install folder, to save a library rescan when
    ///     the caller already knows it.
    ///   - record: Whether to remember this bottle for the App ID.
    ///   - clientIsRunning: Whether the caller has already made sure the client
    ///     is up, as Play does, which saves checking again.
    ///   - onOutput: Receives the `-applaunch` invocation's output events,
    ///     starting with ``ProcessOutput/started`` once Wine is running it.
    /// - Returns: The client invocation, which finishes with its run result.
    /// - Throws: ``SteamLaunchError/steamNotInstalled`` if the bottle has no client.
    @MainActor
    @discardableResult
    public static func launch(
        appId: Int, bottle: Bottle, installURL: URL? = nil, record: Bool = true,
        clientIsRunning: Bool = false,
        onOutput: (@MainActor (ProcessOutput) -> Void)? = nil
    ) throws -> Task<Wine.ProgramRunResult, any Error> {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamLaunchError.steamNotInstalled
        }

        if record {
            GameRouting().record(appId: appId, bottleURL: bottle.url)
        }

        let installURL = installURL ?? SteamLibrary.enumerate(bottleURL: bottle.url)
            .first { $0.appId == appId }?.installURL
        let plan = plan(appId: appId, installURL: installURL, bottle: bottle)
        let steamExe = steamRoot.appending(path: "steam.exe")
        let gameExecutables = gameExecutables(installURL: installURL, plan: plan)
        let renderer = clientBackend(for: plan, bottle: bottle)

        return Task {
            try await Wine.prepareBottlePrefix(bottle: bottle)
            await Wine.syncAudioRegistry(bottle: bottle)
            var clientIsRunning = clientIsRunning
            if let renderer, let overlay = OverlayRuntime.installed,
               await stopClientIfMismatched(bottle: bottle, steamExe: steamExe, backend: renderer, overlay: overlay) {
                clientIsRunning = false
            }
            if !clientIsRunning {
                let running = await hostSteamPIDs()
                await startClientIfNeeded(
                    isRunning: { await isClientRunning(bottle: bottle, hostSteamPIDs: running) },
                    start: { startClient(steamExe: steamExe, bottle: bottle, backend: renderer) },
                    hasStarted: { await !hostSteamPIDs().subtracting(running).isEmpty }
                )
            }
            return try await Wine.runProgram(
                at: steamExe, args: ["-applaunch", String(appId)], bottle: bottle,
                programOverrides: plan.overrides,
                gameProfileEnvironment: plan.gameProfileEnvironment,
                // The plan is the game's; steam.exe is only the vehicle. It goes
                // into the game executables' own entries, so it reaches the game
                // whichever process starts it, and the client keeps DXVK even
                // when this invocation is what brings it up.
                overridesApplyToDescendants: true,
                descendantExecutables: gameExecutables,
                descendantLaunchers: plan.startsLaunchers,
                onOutput: onOutput
            )
        }
    }

    /// The game's plan: its GameDB profile under the user's own settings for it.
    @MainActor
    static func plan(appId: Int, installURL: URL?, bottle: Bottle) -> LaunchPlan {
        LaunchResolver.plan(
            steamAppId: appId,
            userOverrides: installURL.flatMap { userOverrides(forInstallURL: $0, bottle: bottle) }
        )
    }

    /// The renderer the client has to run on for this game, or `nil` off the
    /// overlay runtime. There the renderer set is an environment and every
    /// game the client starts inherits the client's, so the client runs on
    /// the game's: D3DMetal for a DirectX 12 game, DXMT where the GameDB says
    /// so. Resolved the way the `-applaunch` invocation resolves it.
    @MainActor
    static func clientBackend(
        for plan: LaunchPlan, bottle: Bottle, overlayRuntime: OverlayRuntime? = .installed
    ) -> GraphicsBackend? {
        guard let overlayRuntime else { return nil }
        let choice = plan.overrides.graphicsBackend ?? bottle.settings.graphicsBackend
        return GraphicsBackendResolver.concrete(choice, overlayRuntime: overlayRuntime)
    }

    /// Starts `steam.exe -silent` with the user's own overrides for it, the
    /// way the Programs tab would, so the client's entry matches the one a
    /// game launch writes for it. A game launch passes the game's renderer,
    /// which wins over the client's own. Runs for the whole session, so it is
    /// never awaited.
    @MainActor
    static func startClient(steamExe: URL, bottle: Bottle, backend: GraphicsBackend? = nil) {
        var overrides = Program.persistedOverrides(for: steamExe, bottleURL: bottle.url)
        if let backend {
            var pinned = overrides ?? ProgramOverrides()
            pinned.graphicsBackend = backend
            overrides = pinned
        }
        Task {
            _ = try? await Wine.runProgram(
                at: steamExe, args: ["-silent"], bottle: bottle, programOverrides: overrides
            )
        }
    }

    /// The installed games' executables DXMT may be placed next to, each with
    /// the overrides the game's launch resolves to: its GameDB entry under the
    /// user's own settings for the game, found as ``launch`` finds them, so a
    /// backend the user picked counts as much as one the GameDB recommends.
    ///
    /// A target is an executable the entry lists, or the one the user's
    /// settings come from. Only those get the DXMT trio, since a whole install
    /// folder's worth would scatter it into tool and launcher directories. The
    /// others are executables an earlier launch routed, here to be cleaned up.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose Steam libraries to read.
    ///   - entries: The GameDB entries to match against. Defaults to the
    ///     bundled database.
    @MainActor
    static func appLocalDXMTCandidates(
        bottle: Bottle, entries: [GameDBEntry]? = nil
    ) -> [(url: URL, overrides: ProgramOverrides, isTarget: Bool)] {
        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard !games.isEmpty else { return [] }
        let database = entries ?? GameDBLoader.loadDefaults()
        var result: [(url: URL, overrides: ProgramOverrides, isTarget: Bool)] = []
        for game in games {
            let user = userCandidate(forInstallURL: game.installURL, bottle: bottle)
            let plan = LaunchResolver.plan(steamAppId: game.appId, userOverrides: user?.overrides, entries: database)
            let names = Set(plan.gameExecutables.map { $0.lowercased() })
            for url in SteamLibrary.executableURLs(under: game.installURL) {
                let isTarget = names.contains(url.lastPathComponent.lowercased())
                    || url.standardizedFileURL == user?.url.standardizedFileURL
                guard isTarget || Wine.isAppLocalDXMTRouted(url) else { continue }
                result.append((url, plan.overrides, isTarget))
            }
        }
        return result
    }

    /// The executable names a game launch scopes the game's plan to: what the
    /// install folder holds, then what the GameDB lists, each name once.
    static func gameExecutables(installURL: URL?, plan: LaunchPlan) -> [String] {
        let found = installURL.map { SteamLibrary.executableURLs(under: $0).map(\.lastPathComponent) } ?? []
        var seen = Set<String>()
        return (found + plan.gameExecutables).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Starts the client when it isn't running, then waits until it is.
    ///
    /// Gives up waiting after `timeout` and lets `-applaunch` go ahead anyway,
    /// which is what happened before the client was started separately.
    ///
    /// - Parameters:
    ///   - isRunning: Whether `steam.exe` is running in the bottle. Asked once.
    ///   - start: Starts `steam.exe -silent`. Must return promptly: the client
    ///     runs for the whole session.
    ///   - hasStarted: Whether the client this started is up. Polled, so it must
    ///     not start a Wine process: on a prefix the start is still booting, a
    ///     poll every few seconds keeps the boot's services alive, and the
    ///     launch's registry import waits on their output until they exit.
    ///   - timeout: How long to wait for the client to appear.
    ///   - pollInterval: How often to look.
    /// - Returns: Whether the client is running.
    @MainActor
    @discardableResult
    static func startClientIfNeeded(
        isRunning: @MainActor () async -> Bool,
        start: @MainActor () -> Void,
        hasStarted: @MainActor () async -> Bool,
        timeout: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2)
    ) async -> Bool {
        if await isRunning() {
            return true
        }
        start()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if await hasStarted() {
                return true
            }
        }
        return false
    }

    /// Whether `steam.exe` is running in the bottle.
    ///
    /// Without a `steam.exe` anywhere on the host the answer is no, and no Wine
    /// process is started to find that out.
    @MainActor
    static func isClientRunning(bottle: Bottle, hostSteamPIDs: Set<Int32>) async -> Bool {
        guard !hostSteamPIDs.isEmpty else { return false }
        return await WineSteamClientDriver(bottle: bottle).processList()
            .contains { $0.imageName.lowercased() == "steam.exe" }
    }

    /// The host process IDs of every process whose Windows image is `steam.exe`,
    /// in any bottle. Wine's processes carry their Windows path in the host
    /// process list, so this costs one `ps` and no Wine process.
    static func hostSteamPIDs() async -> Set<Int32> {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/ps")
            process.arguments = ["-Ao", "pid=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return steamPIDs(inProcessListing: String(bytes: data, encoding: .utf8) ?? "")
        }.value
    }

    /// The IDs in a `ps -Ao pid=,comm=` listing whose command is a Windows
    /// `steam.exe`.
    static func steamPIDs(inProcessListing output: String) -> Set<Int32> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line -> Int32? in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
            let image = fields[1].split(separator: "\\").last ?? fields[1]
            return image.lowercased() == "steam.exe" ? pid : nil
        })
    }

    /// Shuts the bottle's client down when it runs on another renderer set
    /// than `backend`: `-applaunch` only hands the game to a running client,
    /// and the game inherits the client's set (Highball's
    /// `restartSteamIfMismatched`). A client that serves a running game stays,
    /// since stopping it would end the game. Nothing happens when the
    /// client's environment cannot be read.
    /// - Returns: Whether the client was stopped.
    @MainActor
    static func stopClientIfMismatched(
        bottle: Bottle, steamExe: URL, backend: GraphicsBackend, overlay: OverlayRuntime
    ) async -> Bool {
        let wanted = overlay.rendererEnvironment(for: backend)["WINEDLLPATH_PREPEND"]
        guard clientMustStop(bottleProcesses(bottleURL: bottle.url), wanted: wanted) else {
            return false
        }

        // Highball's sequence: ask, then SIGTERM the client's own processes, then SIGKILL.
        if let shutdown = try? Wine.runWineProcess(
            name: "steam-shutdown", args: [steamExe.path(percentEncoded: false), "-shutdown"], bottle: bottle
        ) {
            for await _ in shutdown {}
        }
        func waitForClientExit(tenths: Int) async {
            for _ in 0 ..< tenths {
                guard bottleProcesses(bottleURL: bottle.url).contains(where: { imageName($0.argv0) == "steam.exe" })
                else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await waitForClientExit(tenths: 300)
        let leftovers = bottleProcesses(bottleURL: bottle.url).filter { clientImages.contains(imageName($0.argv0)) }
        guard !leftovers.isEmpty else { return true }
        for process in leftovers {
            kill(process.pid, SIGTERM)
        }
        await waitForClientExit(tenths: 50)
        for process in leftovers where kill(process.pid, 0) == 0 {
            kill(process.pid, SIGKILL)
        }
        await waitForClientExit(tenths: 20)
        return true
    }

    /// Whether the bottle's client runs on another renderer set than the one
    /// whose `WINEDLLPATH_PREPEND` is `wanted`, and serves no running game.
    static func clientMustStop(_ processes: [BottleProcess], wanted: String?) -> Bool {
        guard let client = processes.first(where: { imageName($0.argv0) == "steam.exe" }),
              client.environment["WINEDLLPATH_PREPEND"] != wanted else {
            return false
        }
        if processes.contains(where: { isGame($0.argv0) }) {
            steamLauncherLogger.warning("Steam runs on another renderer than the game, but a game is open; kept")
            return false
        }
        return true
    }

    /// A process of the bottle: its host ID, its `argv[0]`, and its environment.
    typealias BottleProcess = (pid: pid_t, argv0: String, environment: [String: String])

    /// The Steam client's own processes: what a shutdown stops. Games are not
    /// among them.
    static let clientImages: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe", "gameoverlayui.exe"
    ]

    /// The lower-cased image name of a Windows path or a host path.
    static func imageName(_ argv0: String) -> String {
        String(argv0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "").lowercased()
    }

    /// Whether a process runs from a Steam game's folder.
    static func isGame(_ argv0: String) -> Bool {
        argv0.replacingOccurrences(of: "\\", with: "/").lowercased().contains("/steamapps/common/")
    }

    /// The processes whose environment names this bottle as `WINEPREFIX`: Wine
    /// hands its whole environment to every process it starts. Each with its
    /// `argv[0]`, which for a Windows process is its Windows path.
    static func bottleProcesses(bottleURL: URL) -> [BottleProcess] {
        let prefix = bottleURL.path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(found, 0))).compactMap { pid in
            guard pid > 0, pid != getpid(), let (argv0, environment) = argumentsAndEnvironment(of: pid),
                  environment["WINEPREFIX"] == prefix else { return nil }
            return (pid, argv0, environment)
        }
    }

    /// `argv[0]` and the environment of one of our own processes, from
    /// `KERN_PROCARGS2`. Nil when the kernel refuses or the process is gone.
    static func argumentsAndEnvironment(of pid: pid_t) -> (String, [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // Layout: executable path, argv[0..<argc], then the environment.
        let strings = buffer[MemoryLayout<Int32>.size ..< size].split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        guard argc > 0, strings.count >= 1 + argc else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(1 + argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (strings[1], environment)
    }

    /// The user's persisted overrides for a game's executables, so settings
    /// tuned in the Programs tab survive a launch from the library or the cli.
    ///
    /// Resolution is read-only: no ``Program`` is materialized, so Play never
    /// writes settings plists for the executables that don't win. Only an
    /// executable with persisted overrides can win, so skipping the default
    /// plists changes nothing for the winner.
    @MainActor
    static func userOverrides(forInstallURL installURL: URL, bottle: Bottle) -> ProgramOverrides? {
        userCandidate(forInstallURL: installURL, bottle: bottle)?.overrides
    }

    /// The executable ``userOverrides(forInstallURL:bottle:)`` takes its
    /// overrides from, with them.
    @MainActor
    static func userCandidate(forInstallURL installURL: URL, bottle: Bottle) -> ProgramOverrideCandidate? {
        let scanned = Dictionary(
            bottle.programs.compactMap { program in
                program.settings.overrides.map { (program.url.standardizedFileURL, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = SteamLibrary.executableURLs(under: installURL).map { url in
            // Falls back to a plist read for executables the bottle scan has
            // not reached, so Play works before the Programs tab is opened.
            let overrides = scanned[url.standardizedFileURL]
                ?? Program.persistedOverrides(for: url, bottleURL: bottle.url)
            return ProgramOverrideCandidate(url: url, overrides: overrides ?? ProgramOverrides())
        }
        return SteamLibrary.preferredCandidate(among: candidates)
    }

    /// Finds the installed game an App ID names, and the bottle holding it.
    ///
    /// Narrowing `bottles` to a single bottle chooses where to look, never
    /// whether to look: an App ID that arrives from outside the app may only
    /// ever reach a game the user actually has. The library entry is also what
    /// lets a caller name the game rather than echo the App ID back.
    ///
    /// - Parameters:
    ///   - appId: The Steam App ID to locate.
    ///   - bottles: The bottles to search.
    ///   - routing: The route store to consult.
    /// - Returns: The library entry and the bottle it was found in.
    /// - Throws: ``SteamLaunchError/gameNotFound(appId:)`` when no bottle has it.
    @MainActor
    public static func resolveGame(
        appId: Int, in bottles: [Bottle], routing: GameRouting = GameRouting()
    ) throws -> (game: SteamGame, bottle: Bottle) {
        let bottle = try resolveBottle(appId: appId, in: bottles, routing: routing)
        guard let game = SteamLibrary.enumerate(bottleURL: bottle.url)
            .first(where: { $0.appId == appId })
        else {
            throw SteamLaunchError.gameNotFound(appId: appId)
        }
        return (game, bottle)
    }

    /// Finds the bottle to launch an App ID from: the remembered route when it
    /// still has the game installed, otherwise the first bottle that does.
    ///
    /// - Parameters:
    ///   - appId: The Steam App ID to locate.
    ///   - bottles: The bottles to search.
    ///   - routing: The route store to consult.
    /// - Returns: The bottle holding the game.
    /// - Throws: ``SteamLaunchError/gameNotFound(appId:)`` when no bottle has it.
    @MainActor
    public static func resolveBottle(
        appId: Int, in bottles: [Bottle], routing: GameRouting = GameRouting()
    ) throws -> Bottle {
        let installs: (Bottle) -> Bool = { bottle in
            SteamLibrary.enumerate(bottleURL: bottle.url).contains { $0.appId == appId }
        }

        if let routed = routing.bottleURL(forAppId: appId),
           let bottle = bottles.first(where: { $0.url.standardizedFileURL == routed.standardizedFileURL }),
           installs(bottle) {
            return bottle
        }

        guard let bottle = bottles.first(where: installs) else {
            throw SteamLaunchError.gameNotFound(appId: appId)
        }
        return bottle
    }
}
