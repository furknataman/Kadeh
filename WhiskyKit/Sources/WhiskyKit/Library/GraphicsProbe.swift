//
//  GraphicsProbe.swift
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

import Foundation

/// A DirectX generation a game's files show it using.
public enum DirectXLevel: Int, Comparable, Sendable {
    case dx9 = 9
    case dx10 = 10
    case dx11 = 11
    case dx12 = 12

    public static func < (lhs: DirectXLevel, rhs: DirectXLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// "DirectX 12", for labels.
    public var displayName: String { "DirectX \(rawValue)" }
}

/// Finds out which DirectX a library entry uses by reading its files, without
/// starting Wine, so the library can show it and warn before a DirectX 12 game
/// starts on a graphics backend that cannot run it.
///
/// It only reads: backend selection stays with ``GraphicsBackendResolver``.
public enum GraphicsProbe {
    /// Highest DirectX the entry's files show; `nil` when unknown (launchers,
    /// missing files, engines that load their renderer by a name this does not read).
    public static func directX(for entry: LibraryEntry) async -> DirectXLevel? {
        guard !entry.isLauncher else { return nil }
        let launch = entry.launch
        let bottleURL = entry.bottleURL
        return await Task.detached(priority: .utility) {
            switch launch {
            case let .program(url):
                return directX(ofProgram: url)
            case let .steam(appID):
                return directX(ofSteamApp: appID, bottleURL: bottleURL)
            }
        }.value
    }

    /// Why a DirectX 12 game may not start, for the warning shown before it does.
    public struct DX12Warning: Sendable, Equatable {
        /// The backend the launch would use, by name, for the message.
        public let backendName: String
        /// The full, localized explanation.
        public let message: String
    }

    /// The warning when a DX12 game would start on a backend that can't run
    /// DirectX 12, else `nil`.
    ///
    /// Only the bottle's settings and its scanned programs are read on the main
    /// actor; Steam enumeration, the executable scan, persisted overrides and
    /// the GameDB all run detached, so a slow disk cannot hold up the UI or
    /// the caller's timeout.
    ///
    /// No warning when the GameDB chose the backend for this game: that is a
    /// curated pick, usually for a game with a DirectX 11 mode.
    @MainActor
    public static func dx12Warning(for entry: LibraryEntry, bottle: Bottle) async -> DX12Warning? {
        guard !entry.isLauncher else { return nil }
        let bottleURL = bottle.url
        let bottleBackend = bottle.settings.graphicsBackend
        // The same per-program overrides `SteamLauncher.userCandidate` reads, taken here because
        // `bottle.programs` is main-actor state.
        let scanned = Dictionary(
            bottle.programs.compactMap { program in
                program.settings.overrides.map { (program.url.standardizedFileURL, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let launch = entry.launch
        return await Task.detached(priority: .userInitiated) {
            switch launch {
            case let .program(url):
                guard directX(ofProgram: url) == .dx12 else { return nil }
                let overrides = scanned[url.standardizedFileURL]
                    ?? Program.persistedOverrides(for: url, bottleURL: bottleURL)
                return warning(backend: launchBackend(overrides: overrides, bottleBackend: bottleBackend))
            case let .steam(appID):
                return steamWarning(appID: appID, bottleURL: bottleURL, bottleBackend: bottleBackend, scanned: scanned)
            }
        }.value
    }

    /// The Steam half of ``dx12Warning(for:bottle:)``, off the main actor: the
    /// same plan a Steam launch carries, the GameDB's pick under the user's
    /// own settings.
    private static func steamWarning(
        appID: Int, bottleURL: URL, bottleBackend: GraphicsBackend, scanned: [URL: ProgramOverrides]
    ) -> DX12Warning? {
        guard let game = SteamLibrary.enumerate(bottleURL: bottleURL).first(where: { $0.appId == appID }),
              directX(ofSteamGame: game) == .dx12
        else { return nil }
        let candidates = SteamLibrary.executableURLs(under: game.installURL).map { url in
            ProgramOverrideCandidate(
                url: url,
                overrides: scanned[url.standardizedFileURL]
                    ?? Program.persistedOverrides(for: url, bottleURL: bottleURL)
                    ?? ProgramOverrides()
            )
        }
        let user = SteamLibrary.preferredCandidate(among: candidates)?.overrides
        let plan = LaunchResolver.plan(steamAppId: appID, userOverrides: user)
        // `LaunchResolver.merge` only fills what the user left unset, so a
        // backend that is set now but was not before came from the GameDB.
        if user?.graphicsBackend == nil, plan.overrides.graphicsBackend != nil {
            return nil
        }
        return warning(backend: launchBackend(overrides: plan.overrides, bottleBackend: bottleBackend))
    }

    private static func warning(backend: GraphicsBackend) -> DX12Warning? {
        dx12Warning(level: .dx12, backend: backend).map {
            DX12Warning(backendName: backend.displayName, message: $0)
        }
    }

    // MARK: - Backend decision

    /// The backend a launch with these overrides ends up on.
    static func launchBackend(overrides: ProgramOverrides?, bottleBackend: GraphicsBackend) -> GraphicsBackend {
        // The older per-program DXVK switch, honoured by the launch only while no backend is chosen.
        if overrides?.graphicsBackend == nil, overrides?.dxvk == true {
            return .dxvk
        }
        return GraphicsBackendResolver.concrete(overrides?.graphicsBackend ?? bottleBackend)
    }

    /// Whether a backend can run DirectX 12. Only D3DMetal can: on the overlay
    /// runtime it is the one renderer set with a `d3d12`, and on a WhiskyWine
    /// runtime the DXVK and DXMT presets switch the builtin `d3d12` off.
    static func runsDirectX12(_ backend: GraphicsBackend) -> Bool {
        backend == .d3dMetal
    }

    /// The warning for a game at `level` on `backend`, or `nil` when there is nothing to warn about.
    static func dx12Warning(level: DirectXLevel?, backend: GraphicsBackend) -> String? {
        guard level == .dx12, !runsDirectX12(backend) else { return nil }
        return String(
            localized: "library.warning.dx12",
            defaultValue: """
            Oyun DirectX 12 kullanıyor gibi görünüyor; şişenin grafik ayarı (\(backend.displayName)) \
            bunu çalıştıramıyor. “Ayarları aç” ile D3DMetal'i seçebilirsiniz. Bu ayar, şişedeki \
            bütün oyunları etkiler.
            """
        )
    }

    // MARK: - Detection

    /// Files that only a DirectX 12 game ships next to its executable: the
    /// Agility SDK runtime and its folder, and the shader compiler.
    static let dx12FileNames: Set<String> = ["d3d12core.dll", "d3d12", "dxil.dll", "dxcompiler.dll"]

    /// Names (lowercased) of executables that are never the game.
    private static let skippedNameParts = [
        "unins", "crash", "report", "launcher", "setup", "install", "redist", "dxsetup", "easyanticheat",
        "beclient", "battleye", "helper", "updater", "touchup", "vcredist", "dotnet", "cefprocess", "webhelper"
    ]
    /// Folders (lowercased) never searched for the game's executable.
    private static let skippedFolderParts = [
        "redist", "_commonredist", "directx", "vcredist", "dotnet", "crashreport", "crashhandler",
        "easyanticheat", "battleye", "launcher", "support", "installers", "prerequisites", "__macosx"
    ]
    /// Executables below this size are helpers, not games.
    private static let minimumExecutableSize: Int64 = 200 * 1024
    /// How deep below a Steam install folder executables are looked for, and how many entries are visited.
    private static let maximumDepth = 4
    private static let maximumVisited = 4000
    /// How many of the largest candidate executables are read.
    private static let maximumScanned = 3

    private static func directX(ofProgram url: URL) -> DirectXLevel? {
        let folder = url.deletingLastPathComponent()
        return highest(folderLevel([folder]), scanExecutable(at: url))
    }

    private static func directX(ofSteamApp appID: Int, bottleURL: URL) -> DirectXLevel? {
        guard let game = SteamLibrary.enumerate(bottleURL: bottleURL).first(where: { $0.appId == appID }) else {
            return nil
        }
        return directX(ofSteamGame: game)
    }

    private static func directX(ofSteamGame game: SteamGame) -> DirectXLevel? {
        let appID = game.appId
        let known = Set(LaunchResolver.plan(steamAppId: appID).gameExecutables.map { $0.lowercased() })
        let executables = mainExecutables(under: game.installURL, preferring: known)
        let folders = [game.installURL] + executables.map { $0.deletingLastPathComponent() }
        return executables.reduce(folderLevel(folders)) { highest($0, scanExecutable(at: $1)) }
    }

    private static func highest(_ first: DirectXLevel?, _ second: DirectXLevel?) -> DirectXLevel? {
        [first, second].compactMap { $0 }.max()
    }

    /// `.dx12` when any of `folders` holds a DirectX 12 only file, else `nil`.
    private static func folderLevel(_ folders: [URL]) -> DirectXLevel? {
        for folder in Set(folders) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            if names.contains(where: { dx12FileNames.contains($0.lowercased()) }) {
                return .dx12
            }
        }
        return nil
    }

    /// The executables most likely to be the game inside an install folder:
    /// those the GameDB names when any are present, otherwise the largest.
    static func mainExecutables(under installURL: URL, preferring known: Set<String> = []) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: installURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(url: URL, size: Int64)] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > maximumVisited { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let name = url.lastPathComponent.lowercased()
            if values?.isDirectory == true {
                let depth = url.pathComponents.count - installURL.pathComponents.count
                if depth >= maximumDepth || skippedFolderParts.contains(where: name.contains) {
                    walker.skipDescendants()
                }
                continue
            }
            guard name.hasSuffix(".exe"), !skippedNameParts.contains(where: name.contains) else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if size >= minimumExecutableSize || known.contains(name) {
                found.append((url, size))
            }
        }

        let named = found.filter { known.contains($0.url.lastPathComponent.lowercased()) }
        return (named.isEmpty ? found : named)
            .sorted { $0.size > $1.size }
            .prefix(maximumScanned)
            .map(\.url)
    }

    // MARK: - Executable scan

    /// Strings an executable holds when it imports or loads that DirectX
    /// generation, lowercased. Import names are plain ASCII in the file.
    private static let signatures: [(level: DirectXLevel, needle: [UInt8])] = [
        (.dx12, Array("d3d12.dll".utf8)),
        (.dx12, Array("d3d12createdevice".utf8)),
        (.dx11, Array("d3d11.dll".utf8)),
        (.dx10, Array("d3d10".utf8)),
        (.dx9, Array("d3d9.dll".utf8))
    ]
    private static let chunkSize = 4 * 1024 * 1024

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: DirectXLevel?] = [:]

        func level(for key: String) -> DirectXLevel?? {
            lock.lock()
            defer { lock.unlock() }
            return results[key]
        }

        func store(_ level: DirectXLevel?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            results[key] = level
        }
    }

    private static let cache = Cache()

    /// The highest DirectX the executable's bytes name, `nil` when none or unreadable.
    /// Cached by path, size and modification date, so a game that was not
    /// updated is read once per app run.
    static func scanExecutable(at url: URL) -> DirectXLevel? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(modified)"
        if let cached = cache.level(for: key) { return cached }

        let level = scan(fileAt: url)
        cache.store(level, for: key)
        return level
    }

    /// Streams the file in overlapping chunks so a name split across two reads
    /// is still found, and stops as soon as DirectX 12 turns up.
    static func scan(fileAt url: URL) -> DirectXLevel? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let overlap = (signatures.map(\.needle.count).max() ?? 1) - 1
        var best: DirectXLevel?
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var buffer = carry
            buffer.append(chunk)
            let lowered = buffer.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
            for signature in signatures where best.map({ signature.level > $0 }) ?? true {
                if contains(lowered, signature.needle) {
                    best = signature.level
                }
            }
            if best == .dx12 { break }
            carry = buffer.suffix(overlap)
        }
        return best
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress else { return false }
                return memmem(hayBase, hay.count, pinBase, pin.count) != nil
            }
        }
    }
}
