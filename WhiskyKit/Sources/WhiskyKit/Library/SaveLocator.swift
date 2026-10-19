//
//  SaveLocator.swift
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

/// A folder that holds a game's saves, as stored.
///
/// Kept relative to the bottle when it is inside it, so the record survives
/// the bottle moving. The path is never resolved through symlinks before it is
/// stored: a profile's `Documents` can be a link to the Mac's own folder, and
/// keeping the link in the path keeps that working if the link changes.
public struct SaveFolder: Codable, Hashable, Sendable {
    /// Relative to the bottle when ``inBottle``, absolute otherwise.
    public let path: String
    public let inBottle: Bool
    /// Where the folder really was, links resolved, when the person confirmed
    /// it. A restore writes outside the bottle only to this place, so a link
    /// changed since cannot send it elsewhere. Not part of equality.
    public var realPath: String?

    public init(path: String, inBottle: Bool, realPath: String? = nil) {
        self.path = path
        self.inBottle = inBottle
        self.realPath = realPath
    }

    /// Stores `url` relative to `bottleURL` when it is inside it.
    public init(url: URL, bottleURL: URL) {
        let full = url.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        let bottle = bottleURL.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        if full.hasPrefix(bottle + "/") {
            self.init(path: String(full.dropFirst(bottle.count + 1)), inBottle: true)
        } else {
            self.init(path: full, inBottle: false)
        }
    }

    public func url(bottleURL: URL) -> URL {
        inBottle
            ? bottleURL.appending(path: path, directoryHint: .isDirectory)
            : URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The same folder, with where it really is now as its confirmed place.
    public func confirmingLocation(bottleURL: URL) -> SaveFolder {
        var copy = self
        copy.realPath = url(bottleURL: bottleURL).resolvingSymlinksInPath()
            .standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        return copy
    }

    /// Where the folder is known to be without a bottle: its confirmed place,
    /// or its own path when it is outside any bottle.
    public var knownLocation: URL? {
        (realPath ?? (inBottle ? nil : path)).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// The folder's own name, for a backup's folder inside the archive.
    public var name: String {
        (path as NSString).lastPathComponent
    }

    public static func == (lhs: SaveFolder, rhs: SaveFolder) -> Bool {
        lhs.path == rhs.path && lhs.inBottle == rhs.inBottle
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(inBottle)
    }
}

/// A folder that probably holds a game's saves, and why it was suggested.
public struct SaveCandidate: Identifiable, Hashable, Sendable {
    /// Why a folder was suggested, most convincing first.
    public enum Reason: Int, Comparable, Sendable {
        /// Steam Cloud's own folder for this game.
        case steamCloud
        /// Named like the game.
        case nameMatch
        /// Named like saves, inside the game's own folder.
        case gameFolder
        /// Its files changed since the game last started.
        case recentlyChanged

        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let folder: SaveFolder
    public let url: URL
    public let reason: Reason
    public let files: Int
    public let bytes: Int64
    public let modified: Date?
    /// Counting stopped at its file limit, so ``files`` and ``bytes`` are
    /// only a floor: that many files is no save folder anyway.
    public let isCapped: Bool

    public var id: SaveFolder { folder }

    /// Over this, a folder is more likely a cache than saves, so it starts unticked.
    public static let largeBytes: Int64 = 500_000_000
    public var isLarge: Bool { isCapped || bytes > Self.largeBytes }
}

/// What ``SaveLocator`` needs to know about one game.
public struct SaveSearch: Sendable {
    public var title: String
    public var bottleURL: URL
    public var steamAppID: Int?
    /// The game's own folder.
    public var gameFolder: URL?
    /// When the game last started; folders written since then are suggested.
    public var changedSince: Date?
    /// Kadeh's backup folder: never suggested, nor anything around it.
    public var backupRoot: URL?

    public init(
        title: String, bottleURL: URL, steamAppID: Int? = nil, gameFolder: URL? = nil, changedSince: Date? = nil,
        backupRoot: URL? = nil
    ) {
        self.title = title
        self.bottleURL = bottleURL
        self.steamAppID = steamAppID
        self.gameFolder = gameFolder
        self.changedSince = changedSince
        self.backupRoot = backupRoot
    }
}

/// Suggests the folders a Windows game keeps its saves in.
///
/// Nothing records where a game saves, so this guesses from where games
/// conventionally put them and lets the person confirm. It never walks the
/// whole of `Documents`, which Wine may link to the Mac's own, and never
/// follows a link out of a folder it scans.
public enum SaveLocator {
    /// Launcher, runtime and cache folders: never a game's saves. Compared
    /// normalised, so "NVIDIA Corporation" and "nvidiacorporation" both hit.
    static let noise: Set<String> = [
        "microsoft", "windows", "temp", "tmp", "packages", "programs", "cef", "steam", "valve",
        "epicgames", "epicgameslauncher", "epiconlineservices", "epiconlineservicesinstallhelper",
        "epiconlineservicesuihelper", "unrealengine", "unrealenginelauncher", "nvidia", "nvidiacorporation",
        "amd", "intel", "d3dscache", "dxvk", "vkd3d", "vkd3dproton", "mesashadercache", "shadercache",
        "crashdumps", "crashpad", "crashreportclient", "google", "mozilla", "chromium", "discord",
        "origin", "eadesktop", "electronicarts", "ubisoft", "ubisoftgamelauncher", "gogcom", "galaxy",
        "goggalaxy", "rockstargames", "battlenet", "blizzardentertainment", "wine", "fontconfig",
        "cache", "caches", "logs", "connecteddevicesplatform", "comms", "insomniacengine", "vulkan"
    ]

    /// Names a game uses for its save folder inside its own folder.
    static let saveFolderNames: Set<String> = [
        "save", "saves", "saved", "savegame", "savegames", "savedata", "savedgames", "profiles"
    ]

    /// Words that end a title without being part of what a game names its folder after.
    static let editionWords: Set<String> = [
        "remastered", "remake", "definitive", "edition", "goty", "deluxe", "complete", "enhanced",
        "ultimate", "anniversary", "hd", "collection", "gold", "premium", "redux"
    ]

    /// Every likely folder, most convincing first. Folders with no files are left out.
    public static func candidates(for search: SaveSearch) -> [SaveCandidate] {
        var scan = Scan(search: search)
        scan.run()
        return scan.found.values.sorted { lhs, rhs in
            lhs.reason != rhs.reason
                ? lhs.reason < rhs.reason
                : lhs.folder.path.localizedStandardCompare(rhs.folder.path) == .orderedAscending
        }
    }

    // MARK: - Names

    /// Lowercase letters and digits, diacritics folded.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The names a game's folder is likely to carry.
    ///
    /// The full title, the part before a subtitle, and the title without a
    /// possessive brand and edition words: "Marvel's Spider-Man Remastered"
    /// also gives "spidermanremastered" and "spiderman".
    static func nameKeys(_ title: String) -> Set<String> {
        var titles = [title]
        for separator in [":", " - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                titles.append(String(title[..<range.lowerBound]))
            }
        }
        for candidate in titles {
            var words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > 1, let first = words.first, first.hasSuffix("'s") || first.hasSuffix("’s") {
                words.removeFirst()
                titles.append(words.joined(separator: " "))
            }
            while words.count > 1, let last = words.last, editionWords.contains(normalize(last)) {
                words.removeLast()
            }
            titles.append(words.joined(separator: " "))
        }
        return Set(titles.map(normalize).filter { $0.count >= 4 })
    }

    static func matches(_ folderName: String, keys: Set<String>) -> Bool {
        let name = normalize(folderName)
        guard name.count >= 4 else { return false }
        return keys.contains { key in
            name == key || (min(name.count, key.count) >= 5 && (name.contains(key) || key.contains(name)))
        }
    }

    /// - Parameter keepRockstar: In Documents, `Rockstar Games` holds the
    ///   games' own saves rather than a launcher's files.
    static func isNoise(_ name: String, keepRockstar: Bool = false) -> Bool {
        let normalized = normalize(name)
        if keepRockstar, normalized == "rockstargames" { return false }
        return name.hasPrefix(".") || noise.contains(normalized)
    }

    // MARK: - Scan

    private struct Scan {
        let search: SaveSearch
        let keys: Set<String>
        let bottle: URL
        var found: [SaveFolder: SaveCandidate] = [:]

        init(search: SaveSearch) {
            self.search = search
            self.keys = SaveLocator.nameKeys(search.title)
            self.bottle = search.bottleURL.standardizedFileURL
        }

        mutating func run() {
            steamCloud()
            for profile in profiles() {
                let appData = profile.appending(path: "AppData")
                for kind in ["Roaming", "Local", "LocalLow"] {
                    scanNamed(in: appData.appending(path: kind), depth: 2)
                }
                unrealSaves(in: appData.appending(path: "Local"))
                companyLevel(in: profile.appending(path: "Saved Games"), suggestChanged: true)
                documents(profile.appending(path: "Documents"))
            }
            gameFolder()
        }

        /// `userdata/<account>/<appid>/remote`, Steam Cloud's copy of the saves.
        mutating func steamCloud() {
            guard let appID = search.steamAppID,
                  let steamRoot = SteamLibrary.detectInstall(bottleURL: search.bottleURL)
            else { return }
            let userdata = steamRoot.appending(path: "userdata")
            for account in FileScan.children(of: userdata) where account.lastPathComponent != "0" {
                let remote = account.appending(path: "\(appID)").appending(path: "remote")
                if FileScan.isDirectory(remote) {
                    add(remote, .steamCloud)
                }
            }
        }

        /// Each user profile in the bottle once. `users/<name>` is often a
        /// link to `users/crossover`; following it is fine while it stays in
        /// the bottle, and resolving it is what stops one profile being
        /// scanned twice.
        func profiles() -> [URL] {
            let users = bottle.appending(path: "drive_c").appending(path: "users")
            var seen = Set<String>()
            var result: [URL] = []
            for entry in FileScan.children(of: users, followingLinks: true) where entry.lastPathComponent != "Public" {
                let resolved = entry.resolvingSymlinksInPath()
                guard FileScan.isInside(resolved, bottle.resolvingSymlinksInPath()),
                      FileScan.isDirectory(resolved),
                      seen.insert(resolved.path(percentEncoded: false)).inserted
                else { continue }
                // Stored through the real folder, so a link that points
                // elsewhere later cannot redirect a backup.
                result.append(users.appending(path: resolved.lastPathComponent))
            }
            return result
        }

        /// Folders named like the game, `depth` levels down; on the last
        /// level, folders the last session wrote to as well.
        mutating func scanNamed(in parent: URL, depth: Int) {
            for child in FileScan.children(of: parent) where !SaveLocator.isNoise(child.lastPathComponent) {
                guard FileScan.isDirectory(child) else { continue }
                if SaveLocator.matches(child.lastPathComponent, keys: keys) {
                    add(child, .nameMatch)
                } else if depth > 1 {
                    scanNamed(in: child, depth: depth - 1)
                } else if changedRecently(child) {
                    add(child, .recentlyChanged)
                }
            }
        }

        /// `<Game>` or `<Company>/<Game>`: folders named like the game one or
        /// two levels down. A first-level folder with no such child is
        /// suggested when the last session wrote to it and `suggestChanged`.
        mutating func companyLevel(in parent: URL, suggestChanged: Bool, keepRockstar: Bool = false) {
            for child in FileScan.children(of: parent) where FileScan.isDirectory(child) {
                let name = child.lastPathComponent
                guard !SaveLocator.isNoise(name, keepRockstar: keepRockstar) else { continue }
                if SaveLocator.matches(name, keys: keys) {
                    add(child, .nameMatch)
                    continue
                }
                let games = FileScan.children(of: child).filter {
                    FileScan.isDirectory($0) && SaveLocator.matches($0.lastPathComponent, keys: keys)
                }
                if !games.isEmpty {
                    games.forEach { add($0, .nameMatch) }
                } else if suggestChanged, changedRecently(child) {
                    add(child, .recentlyChanged)
                }
            }
        }

        /// Unreal games keep saves in `AppData/Local/<Project>/Saved/SaveGames`
        /// under a project name that rarely matches the title, so the folder is
        /// suggested when the last session wrote to it. A project already
        /// suggested by name is covered.
        mutating func unrealSaves(in local: URL) {
            for project in FileScan.children(of: local)
                where FileScan.isDirectory(project) && !SaveLocator.isNoise(project.lastPathComponent) {
                let saved = project.appending(path: "Saved")
                let saves = saved.appending(path: "SaveGames")
                guard FileScan.kind(of: saves) == .directory,
                      found[SaveFolder(url: project, bottleURL: search.bottleURL)] == nil,
                      changedRecently(saves)
                else { continue }
                // The scan above may have offered all of `Saved`, logs and
                // config included; the save games alone are the better pick.
                let whole = SaveFolder(url: saved, bottleURL: search.bottleURL)
                if found[whole]?.reason == .recentlyChanged {
                    found[whole] = nil
                }
                add(saves, .recentlyChanged)
            }
        }

        /// Folders named like the game one or two levels down
        /// (`Documents/<Company>/<Game>`), and the same inside the `My Games`
        /// and `Saved Games` folders games conventionally use. Never deeper:
        /// this can be the Mac's own Documents.
        mutating func documents(_ documents: URL) {
            // The folder itself may be a link to the Mac's Documents, which
            // listing it follows; links inside it are not followed.
            for child in FileScan.children(of: documents) {
                let name = child.lastPathComponent
                guard !SaveLocator.isNoise(name, keepRockstar: true), FileScan.isDirectory(child) else { continue }
                if SaveLocator.matches(name, keys: keys) {
                    add(child, .nameMatch)
                } else if ["mygames", "savedgames"].contains(SaveLocator.normalize(name)) {
                    companyLevel(in: child, suggestChanged: false, keepRockstar: true)
                } else {
                    for game in FileScan.children(of: child)
                        where FileScan.isDirectory(game) && SaveLocator.matches(game.lastPathComponent, keys: keys) {
                        add(game, .nameMatch)
                    }
                }
            }
        }

        /// Save-named folders in the game's own folder, two levels down.
        mutating func gameFolder() {
            guard let root = search.gameFolder, FileScan.isDirectory(root) else { return }
            look(in: root, depth: 2)
        }

        private mutating func look(in folder: URL, depth: Int) {
            for child in FileScan.children(of: folder) where FileScan.isDirectory(child) {
                if SaveLocator.saveFolderNames.contains(SaveLocator.normalize(child.lastPathComponent)) {
                    add(child, .gameFolder)
                } else if depth > 1 {
                    look(in: child, depth: depth - 1)
                }
            }
        }

        func changedRecently(_ folder: URL) -> Bool {
            guard let since = search.changedSince else { return false }
            return (FileScan.measure(folder).newest ?? .distantPast) >= since
        }

        mutating func add(_ url: URL, _ reason: SaveCandidate.Reason) {
            let folder = SaveFolder(url: url, bottleURL: search.bottleURL)
            if let existing = found[folder], existing.reason <= reason { return }
            if let root = search.backupRoot, SaveBackupStore.overlap(url, root) { return }
            let measured = FileScan.measure(url)
            guard measured.files > 0 else { return }
            found[folder] = SaveCandidate(
                folder: folder, url: url, reason: reason,
                files: measured.files, bytes: measured.bytes, modified: measured.newest,
                isCapped: measured.capped
            )
        }
    }
}

/// Filesystem reads that never follow a link unless told to.
enum FileScan {
    /// Entries of a folder. Links are left out unless `followingLinks`, which
    /// only the scan's own roots ask for.
    static func children(of folder: URL, followingLinks: Bool = false) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        )) ?? []
        return entries
            .filter { followingLinks || !isLink($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// The same path with no trailing slash, so a file at a save folder's
    /// path can be copied and moved like one.
    static func plain(_ url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false).trimmingSlashes, directoryHint: .inferFromPath)
    }

    enum Kind: Equatable {
        case file, directory, link
    }

    /// What is at `url` itself, a link not followed; `nil` when nothing is,
    /// or something that is neither a file, a folder nor a link.
    static func kind(of url: URL) -> Kind? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false).trimmingSlashes, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .link
        default: return nil
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        let base = folder.standardizedFileURL.path(percentEncoded: false).trimmingSlashes
        return path == base || path.hasPrefix(base + "/")
    }

    /// File count, total size and newest change under `folder`, links not
    /// followed. Stops counting at `limit` files: a suggestion needs a rough
    /// size, not an exact one, and a wrong guess must not walk a whole drive.
    struct Measure {
        var files = 0
        var bytes: Int64 = 0
        var newest: Date?
        /// Stopped at the limit.
        var capped = false
    }

    static func measure(_ folder: URL, limit: Int = 5_000) -> Measure {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: keys, options: []
        ) else { return Measure() }

        var measure = Measure()
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            if url.lastPathComponent == ".DS_Store" { continue }
            measure.files += 1
            measure.bytes += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate, modified > (measure.newest ?? .distantPast) {
                measure.newest = modified
            }
            if measure.files >= limit {
                measure.capped = true
                break
            }
        }
        return measure
    }
}

extension String {
    /// Without trailing slashes, the root aside.
    var trimmingSlashes: String {
        var path = self
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
