//
//  GameProcesses.swift
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

import Darwin
import Foundation

/// A process of some bottle, as the host process list sees it.
///
/// Wine hands its whole environment to every process it starts, so
/// `WINEPREFIX` says which bottle a process belongs to, and Wine rewrites a
/// Windows process's `argv[0]` to its Windows path
/// (`Z:\Users\me\Games\Deep Rock Galactic\FSD\Binaries\Win64\FSD-Win64-Shipping.exe`).
/// The Wine host binaries (`wineserver`, the preloader) carry the same
/// environment with a host path, which is how an idle-looking bottle still
/// reads as running while its server is up.
public struct HostWineProcess: Identifiable, Hashable, Sendable {
    public let pid: Int32
    /// `argv[0]`: the Windows path of a Windows program, a host path otherwise.
    public let imagePath: String
    /// The bottle folder, from `WINEPREFIX`.
    public let prefixPath: String
    public let startedAt: Date?

    public var id: Int32 { pid }

    public init(pid: Int32, imagePath: String, prefixPath: String, startedAt: Date? = nil) {
        self.pid = pid
        self.imagePath = imagePath
        self.prefixPath = prefixPath
        self.startedAt = startedAt
    }

    /// The lowercased file name, `game.exe`.
    public var imageName: String {
        String(imagePath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "").lowercased()
    }

    /// Whether this is a Windows program rather than one of Wine's host binaries.
    public var isWindowsProgram: Bool { imageName.hasSuffix(".exe") }

    /// Whether the process belongs to the bottle at `bottleURL`.
    /// Both sides are resolved, so a bottle reached through a symlink is
    /// still the same bottle.
    public func belongs(to bottleURL: URL) -> Bool {
        HostWineProcesses.prefixKey(prefixPath) == HostWineProcesses.hostKey(bottleURL)
    }

    /// Where the image lives on the host, lowercased with symlinks resolved,
    /// so it compares with an install folder however either was reached
    /// (`D:` is a `dosdevices` link, `Z:` is `/`). Nil for a bare name.
    public var hostImagePath: String? {
        HostWineProcesses.hostPath(ofImage: imagePath, bottleURL: URL(filePath: prefixPath))
    }
}

/// Reads the bottles' processes from the host: free, and it starts nothing.
///
/// `tasklist.exe` is the other way to ask, and it is a Wine process, so in an
/// idle bottle it starts a wineserver to answer that nothing runs.
public enum HostWineProcesses {
    /// Every process of every bottle, read off the main thread.
    public static func current() async -> [HostWineProcess] {
        await Task.detached(priority: .utility) { snapshot() }.value
    }

    /// Every process of ours whose environment names a `WINEPREFIX`.
    public static func snapshot() -> [HostWineProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let ownPID = getpid()
        return pids.prefix(Int(max(found, 0))).compactMap { pid in
            guard pid > 0, pid != ownPID,
                  let (argv0, environment) = SteamLauncher.argumentsAndEnvironment(of: pid),
                  let prefix = environment["WINEPREFIX"], !prefix.isEmpty
            else { return nil }
            return HostWineProcess(pid: pid, imagePath: argv0, prefixPath: prefix, startedAt: startDate(of: pid))
        }
    }

    /// When the kernel started `pid`.
    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// A path without a trailing slash, for comparing prefixes.
    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// The host location of a process image, lowercased with symlinks resolved.
    ///
    /// Takes a Windows path (`C:\…`, also with the `\\?\` and `\??\` prefixes
    /// NT paths carry) through the bottle's drives, or a host path as is. A
    /// bare file name has no location and gives nil.
    public static func hostPath(ofImage imagePath: String, bottleURL: URL) -> String? {
        var path = imagePath
        for ntPrefix in [#"\\?\"#, #"\??\"#] where path.hasPrefix(ntPrefix) {
            path.removeFirst(ntPrefix.count)
        }
        let host: URL
        if path.hasPrefix("/") {
            host = URL(filePath: path)
        } else if path.lowercased().hasPrefix("z:"), !driveLinkExists("z", bottleURL: bottleURL) {
            // Wine's default Z: is the host root; a bottle without the link
            // still means that.
            let rest = path.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
            host = URL(filePath: "/" + rest.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        } else if let mapped = SteamLibrary.mapWindowsPath(path, bottleURL: bottleURL) {
            host = mapped
        } else {
            return nil
        }
        return hostKey(host)
    }

    /// A `WINEPREFIX` value in the form ``hostKey(_:)`` writes.
    static func prefixKey(_ prefix: String) -> String {
        hostKey(URL(filePath: prefix, directoryHint: .isDirectory))
    }

    /// A host URL in the form ``hostPath(ofImage:bottleURL:)`` returns.
    public static func hostKey(_ url: URL) -> String {
        normalized(url.resolvingSymlinksInPath().path(percentEncoded: false)).lowercased()
    }

    private static func driveLinkExists(_ letter: String, bottleURL: URL) -> Bool {
        let link = bottleURL.appending(path: "dosdevices").appending(path: "\(letter):")
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))) != nil
    }
}

/// What it means for one library entry to be running: which processes of
/// which bottle belong to it.
///
/// A Steam game is anything running from inside its install folder, at any
/// depth. What Steam starts is often a bootstrap at the root that hands over
/// to `Game/Binaries/Win64/Game-Win64-Shipping.exe` and exits; matching on
/// the folder rather than on a list of names is what keeps that one session.
/// A program is anything in its own folder too, for the same reason, unless
/// that folder is a shared one (``isSharedFolder(_:bottleURL:)``): then only
/// the executable itself counts.
///
/// Crash reporters, anti-cheat services, installers and web helpers in the
/// folder do not count: they can outlive the game by minutes.
public struct GameProcessScope: Equatable, Sendable {
    /// The bottle folder, as ``HostWineProcesses/hostKey(_:)`` writes it.
    public let bottlePath: String
    /// The folder whose whole tree is the game: a Steam game's install
    /// folder, or a program's own folder. As ``HostWineProcesses/hostKey(_:)`` writes it.
    public let folder: String?
    /// A program's executable, as ``HostWineProcesses/hostKey(_:)`` writes it.
    public let executable: String?
    /// Lowercased image names that count when a process shows a bare name
    /// and no path, so there is nothing to place.
    public let names: Set<String>

    public init(bottleURL: URL, folder: URL?, executable: URL?, names: Set<String>) {
        bottlePath = HostWineProcesses.hostKey(bottleURL)
        self.folder = folder.map(HostWineProcesses.hostKey)
        self.executable = executable.map(HostWineProcesses.hostKey)
        self.names = names
    }

    /// The scope of a library entry. Reads the disk for a Steam game, so not
    /// for the main thread.
    ///
    /// - Parameter extraNames: More image names to accept for a bare name.
    public static func of(_ entry: LibraryEntry, extraNames: Set<String> = []) -> GameProcessScope {
        switch entry.launch {
        case let .program(url):
            let folder = url.deletingLastPathComponent()
            return GameProcessScope(
                bottleURL: entry.bottleURL,
                folder: isSharedFolder(folder, bottleURL: entry.bottleURL) ? nil : folder,
                executable: url,
                names: extraNames.union([url.lastPathComponent.lowercased()])
            )
        case let .steam(appID):
            let install = SteamLibrary.enumerate(bottleURL: entry.bottleURL).first { $0.appId == appID }?.installURL
            return GameProcessScope(
                bottleURL: entry.bottleURL, folder: install, executable: nil,
                names: extraNames.union(install.map { GameProcessScope.executableNames(under: $0) } ?? [])
            )
        case .switchGame:
            // Matches nothing: the emulator is not a Wine process, and
            // ``SwitchLauncher`` follows the one it started.
            return GameProcessScope(bottleURL: entry.bottleURL, folder: nil, executable: nil, names: [])
        }
    }

    /// Whether `process` belongs to this entry.
    public func matches(_ process: HostWineProcess) -> Bool {
        guard process.isWindowsProgram, HostWineProcesses.prefixKey(process.prefixPath) == bottlePath else {
            return false
        }
        guard let path = process.hostImagePath else {
            return names.contains(process.imageName)
        }
        if let executable, path == executable { return true }
        guard let folder, path.hasPrefix(folder + "/") else { return false }
        let inside = path.dropFirst(folder.count + 1).split(separator: "/")
        return !Self.isHelper(name: process.imageName, folders: inside.dropLast().map(String.init))
    }

    /// Whether an executable is a helper rather than the game: by its name,
    /// or by a folder on the way to it.
    static func isHelper(name: String, folders: [String]) -> Bool {
        ignoredNameParts.contains(where: name.contains)
            || folders.contains { folder in ignoredFolderParts.contains(where: folder.lowercased().contains) }
    }

    /// Parts of an executable's lowercased name that mark a helper.
    static let ignoredNameParts = [
        "crash", "webhelper", "webcore", "browsersubprocess", "qtwebengine", "redist", "anticheat",
        "battleye", "unins", "installer"
    ]

    /// Whether `folder` holds things other than one program, so its tree
    /// cannot stand for that program: the bottle, `drive_c` and what is
    /// directly in it (`Program Files`, `ProgramData`, `Games`), `windows`, a user's own folders (`users/me/Desktop`),
    /// and on the host the root, a volume, a home and what is directly in it.
    public static func isSharedFolder(_ folder: URL, bottleURL: URL) -> Bool {
        let key = HostWineProcesses.hostKey(folder)
        let bottle = HostWineProcesses.hostKey(bottleURL)
        if key == bottle { return true }
        if key.hasPrefix(bottle + "/") {
            let inside = key.dropFirst(bottle.count + 1).split(separator: "/").map(String.init)
            guard inside.first == "drive_c" else { return inside.count <= 2 }
            let drive = Array(inside.dropFirst())
            guard let top = drive.first else { return true }
            switch top {
            case "windows": return true
            case "users": return drive.count <= 3
            // ponytail: `C:\Games` holding many programs is shared; a game
            // installed straight into `C:\Game` loses its launcher handoff.
            default: return drive.count == 1
            }
        }
        let parts = key.split(separator: "/")
        let home = HostWineProcesses.hostKey(FileManager.default.homeDirectoryForCurrentUser)
        let homeDepth = home.split(separator: "/").count
        return parts.count <= 2 || (key.hasPrefix(home + "/") && parts.count <= homeDepth + 1)
    }

    /// Whether any of `processes` belongs to this entry.
    public func isRunning(in processes: [HostWineProcess]) -> Bool {
        processes.contains(where: matches)
    }

    /// Folders that hold installers, anti-cheat services and crash reporters,
    /// none of which is the game being played. Matched as parts of a
    /// lowercased folder name.
    static let ignoredFolderParts = ["redist", "anticheat", "battleye", "crash", "prereq", "installer", "directx"]

    /// Lowercased executable names under a game's install folder, down to
    /// four folders deep: deep enough for Unreal's `Game/Binaries/Win64`,
    /// without the folders ``ignoredFolderParts`` names.
    public static func executableNames(under installURL: URL, maxDepth: Int = 4) -> Set<String> {
        var names: Set<String> = []
        var level = [installURL]
        for depth in 0 ... maxDepth where !level.isEmpty {
            var next: [URL] = []
            for folder in level {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []
                for item in items {
                    let name = item.lastPathComponent.lowercased()
                    if item.pathExtension.lowercased() == "exe" {
                        if !ignoredNameParts.contains(where: name.contains) {
                            names.insert(name)
                        }
                    } else if depth < maxDepth,
                              (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                              !ignoredFolderParts.contains(where: name.contains) {
                        next.append(item)
                    }
                }
            }
            level = next
        }
        return names
    }
}

/// One thing a person would say is running in a bottle: a game with its
/// helper processes, or a program.
public struct RunningProgram: Identifiable, Equatable, Sendable {
    /// Stable across refreshes: the game's folder, or the image path.
    public let id: String
    /// The game's name, `Steam` for the client, otherwise the file name
    /// without `.exe`.
    public let name: String
    public let bottleURL: URL
    /// Every process this row stands for.
    public let processes: [HostWineProcess]

    /// When the earliest of its processes started.
    public var startedAt: Date? { processes.compactMap(\.startedAt).min() }
    /// The lowercased image names, which is what `tasklist.exe` and
    /// `taskkill.exe` know them by.
    public var imageNames: Set<String> { Set(processes.map(\.imageName)) }

    public init(id: String, name: String, bottleURL: URL, processes: [HostWineProcess]) {
        self.id = id
        self.name = name
        self.bottleURL = bottleURL
        self.processes = processes
    }

    /// Images that are part of something else rather than something a person
    /// started: the Steam client's helpers and Wine's own housekeeping. The
    /// Wine services and system processes ``ProcessKind`` knows are left out
    /// as well.
    public static let hiddenImages: Set<String> = [
        "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "gameoverlayui.exe", "gameoverlayui64.exe", "wineboot.exe", "winemenubuilder.exe"
    ]

    /// The bottle's running programs, games first by name.
    ///
    /// - Parameter gameFolders: Install folders, as ``HostWineProcesses/hostKey(_:)``
    ///   writes them, mapped to the game's name. Every process inside one is
    ///   that game, so a launcher and the game it started read as one row.
    public static func group(
        _ processes: [HostWineProcess], bottleURL: URL, gameFolders: [String: String]
    ) -> [RunningProgram] {
        var groups: [String: (name: String, isGame: Bool, processes: [HostWineProcess])] = [:]
        for process in processes where process.belongs(to: bottleURL) && process.isWindowsProgram {
            let image = process.imageName
            guard ProcessKind.classify(image) == .app, !hiddenImages.contains(image) else { continue }
            let path = process.hostImagePath
            if let path, let game = gameFolders.first(where: { path.hasPrefix($0.key + "/") }) {
                groups["game:" + game.key, default: (game.value, true, [])].processes.append(process)
                continue
            }
            let key = path ?? image
            let name = image == "steam.exe" ? "Steam" : displayName(of: process.imagePath)
            groups[key, default: (name, false, [])].processes.append(process)
        }
        return groups
            .map { key, group -> (Bool, RunningProgram) in
                let program = RunningProgram(
                    id: key, name: group.name, bottleURL: bottleURL, processes: group.processes
                )
                return (group.isGame, program)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 }
                return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
            }
            .map(\.1)
    }

    /// `C:\Games\Blur\Blur.exe` → `Blur`.
    static func displayName(of imagePath: String) -> String {
        let file = String(imagePath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(imagePath))
        return file.lowercased().hasSuffix(".exe") ? String(file.dropLast(4)) : file
    }
}
