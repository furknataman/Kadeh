//
//  SwitchEmulator.swift
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

/// Eden, the emulator Kadeh runs Nintendo Switch games in, and the files
/// from the user's own console it needs.
///
/// Everything emulator-specific is in this file and ``launchArguments(for:)``:
/// Ryubing was the first choice and can come back by changing only these.
/// Its release server (git.ryujinx.app) was unreachable from everywhere on
/// 2026-10-20, so the user chose Eden.
///
/// It lives in `Switch/` beside `Libraries/` rather than inside it, because
/// installing the Wine engine deletes and rewrites `Libraries/`. Eden runs in
/// portable mode: on macOS it changes into the folder that holds `eden.app`
/// and keeps keys, firmware, saves and settings in a `user` folder there, so
/// Kadeh's copy never mixes with an Eden the user runs on their own.
///
/// Kadeh never downloads keys, firmware or games. It only copies the files
/// the user picks.
public enum SwitchEmulator {
    /// One emulator build, pinned by its digest.
    public struct Release: Sendable {
        public let version: String
        public let url: URL
        /// Lowercase hex SHA-256 of the file at ``url``.
        public let sha256: String
    }

    /// The Eden build Kadeh installs.
    ///
    /// Eden publishes neither checksums nor signatures and its macOS app is
    /// ad hoc signed, so the digest is pinned here; a file that differs is
    /// not installed. The URL is the one the stable release on
    /// git.eden-emu.dev links to. When this pin was taken the file also
    /// matched the piece hashes of the `.torrent` attached to that release,
    /// a second copy served from another host.
    ///
    /// To update: the newest stable from
    /// `https://git.eden-emu.dev/api/v1/repos/eden-emu/eden/releases`, its
    /// `Eden-macOS-<tag>.dmg`, and that file's SHA-256.
    // ponytail: one pinned build; bump version+url+sha256 to update Eden.
    public static let pinned = Release(
        version: "0.2.1",
        // swiftlint:disable:next force_unwrapping
        url: URL(string: "https://stable.eden-emu.dev/v0.2.1/Eden-macOS-v0.2.1.dmg")!,
        sha256: "40575fc79a61550fbb9e332cbae94ccd20f5de20ff61b4b60fe1d42f2525c0b5"
    )

    /// How a game is started: Eden's own `-f` (full screen) and `-g` (game).
    static func launchArguments(for game: URL) -> [String] {
        ["-f", "-g", game.path(percentEncoded: false)]
    }

    /// Turns off Eden's own update check before a launch: Kadeh pins the
    /// version, and an English "new version" prompt over a game helps nobody.
    /// Only an existing settings file is touched; Eden writes it on its first
    /// quit, and before that its defaults are left alone.
    static func prepareForLaunch() {
        let settings = dataFolder.appending(path: "config/qt-config.ini")
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return }
        let quiet = text
            .replacingOccurrences(of: "check_for_updates\\default=true", with: "check_for_updates\\default=false")
            .replacingOccurrences(of: "check_for_updates=true", with: "check_for_updates=false")
        if quiet != text {
            try? quiet.write(to: settings, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Paths

    /// `Switch/` in Kadeh's Application Support folder.
    public static var folder: URL { WhiskyWineInstaller.applicationFolder.appending(path: "Switch") }
    public static var appURL: URL { folder.appending(path: "eden.app") }
    public static var executableURL: URL { appURL.appending(path: "Contents/MacOS/eden") }
    /// Everything Eden keeps. That this folder exists beside ``appURL`` is
    /// what turns on portable mode, so it is created on install and never
    /// deleted: it holds the user's saves.
    public static var dataFolder: URL { folder.appending(path: "user") }
    public static var keysURL: URL { dataFolder.appending(path: "keys/prod.keys") }
    public static var firmwareFolder: URL { dataFolder.appending(path: "nand/system/Contents/registered") }
    /// The installed emulator's version, as plain text.
    private static var versionURL: URL { folder.appending(path: "version") }

    private static let gamesFolderKey = "switch.gamesFolder"

    /// The folder the user keeps their game files in, `nil` until one is
    /// chosen. A plain path rather than a bookmark: Kadeh is not sandboxed.
    public static var gamesFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: gamesFolderKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        }
        set {
            UserDefaults.standard.set(newValue?.path(percentEncoded: false), forKey: gamesFolderKey)
        }
    }

    // MARK: - Readiness

    /// What playing needs, in the order the setup sheet shows it.
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case emulator, keys, firmware, games

        public var id: Int { rawValue }
    }

    /// Whether `step` is done. Only checks that the files are there: whether
    /// the keys fit the firmware is the emulator's to say, in its own window.
    public static func isDone(_ step: Step) -> Bool {
        let fileManager = FileManager.default
        switch step {
        case .emulator:
            return installedVersion() != nil
        case .keys:
            return fileManager.fileExists(atPath: keysURL.path(percentEncoded: false))
        case .firmware:
            let contents = try? fileManager.contentsOfDirectory(
                at: firmwareFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return !(contents ?? []).isEmpty
        case .games:
            guard let gamesFolder else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: gamesFolder.path(percentEncoded: false), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// First of emulator/keys/firmware that is missing; nil = ready to play.
    ///
    /// The games folder is not asked for: a game being played came from it.
    public static func missingForPlay() -> Step? {
        [Step.emulator, .keys, .firmware].first { !isDone($0) }
    }

    /// The installed emulator's version, or `nil` when there is none that can run.
    public static func installedVersion() -> String? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: versionURL)
        else { return nil }
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    // MARK: - Setup

    /// Why a setup step failed, one case per message the setup sheet shows.
    public enum SetupError: Error, Equatable {
        /// The download failed: no network, or the server is down.
        case unreachable
        /// The download is not the pinned build. It was deleted.
        case mismatch
        /// The pinned build came down but did not unpack into a runnable app.
        case badArchive
        /// The chosen file has no `header_key`, so it is not a prod.keys file.
        case notKeys
        /// The chosen folder or zip does not hold a whole firmware.
        case notFirmware
    }

    /// Downloads ``pinned``, checks its digest and puts it in place of any
    /// installed emulator. ``dataFolder`` is left alone, so keys, firmware and
    /// saves survive an update.
    ///
    /// - Parameter progress: The download's fraction done, from 0 to 1.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        // In Caches, like the Wine engine's archive, so an interrupted download
        // resumes after a relaunch.
        let archive = URL.cachesDirectory.appending(path: Bundle.whiskyBundleIdentifier)
            .appending(path: "Switch").appending(path: pinned.url.lastPathComponent)
        // A dead server should say so in seconds rather than after four
        // one-minute timeouts; a transfer that stalls still resumes on retry.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let downloader = ResumableDownloader(
            sessionConfiguration: configuration, retryPolicy: ResumableDownloadRetryPolicy(maxAttempts: 3)
        )
        do {
            try await downloader.download(from: pinned.url, to: archive, progress: { snapshot in
                guard let total = snapshot.expectedBytes, total > 0 else { return }
                progress(min(1, Double(snapshot.bytesOnDisk) / Double(total)))
            })
        } catch let error as CancellationError {
            throw error
        } catch {
            // A dead server, no network and a missing file all mean the same
            // to the user: try again later.
            throw SetupError.unreachable
        }
        try await Task.detached(priority: .userInitiated) {
            // Matching or not, the archive has no use after this: a retry
            // downloads it again.
            defer { ResumableDownloader.discardArtifacts(at: archive) }
            try installApp(fromArchive: archive)
        }.value
    }

    /// Everything after the download. Unpacked into a staging folder first,
    /// so a failed install leaves the old emulator working.
    private static func installApp(fromArchive archive: URL) throws {
        guard WhiskyWineInstaller.integrityResult(forFileAt: archive, expectedSHA256: pinned.sha256) == .match else {
            throw SetupError.mismatch
        }
        let fileManager = FileManager.default
        // Its own name, so a second install started from another window cannot delete it.
        let staging = folder.appending(path: ".staging-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // Eden ships a disk image: mounted read-only and out of sight, its
        // app copied out, and unmounted whatever happens.
        let mount = staging.appending(path: "mount")
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        let image = mount.path(percentEncoded: false)
        guard run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", image, archive.path(percentEncoded: false)
        ]) == 0 else { throw SetupError.badArchive }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", image]) }
        let app = staging.appending(path: appURL.lastPathComponent)
        // ditto rather than a plain copy: keeps the bundle's permissions and signature intact.
        guard run("/usr/bin/ditto", [mount.appending(path: appURL.lastPathComponent).path(percentEncoded: false),
                                     app.path(percentEncoded: false)]) == 0
        else { throw SetupError.badArchive }

        // Eden is ad hoc signed and not notarized, so Gatekeeper refuses a
        // quarantined copy. The status is ignored: xattr fails when there
        // was nothing to clear.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path(percentEncoded: false)])
        let executable = app.appending(path: "Contents/MacOS").appending(path: executableURL.lastPathComponent)
        guard fileManager.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw SetupError.badArchive
        }

        try replace(appURL, with: app)
        try Data(pinned.version.utf8).write(to: versionURL, options: .atomic)
        try fileManager.createDirectory(at: dataFolder, withIntermediateDirectories: true)
    }

    /// Copies the user's prod.keys into the emulator's portable folder, and a
    /// `title.keys` from the same folder when there is one.
    public static func importKeys(from file: URL) throws {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8),
              isKeysFile(text)
        else { throw SetupError.notKeys }

        let system = keysURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try data.write(to: keysURL, options: .atomic)
        // Optional: only some games need title keys, so one that is missing
        // or unreadable is not an error.
        if let titleKeys = try? Data(contentsOf: file.deletingLastPathComponent().appending(path: "title.keys")) {
            try titleKeys.write(to: system.appending(path: "title.keys"), options: .atomic)
        }
    }

    /// Imports the firmware the user dumped from their console, from a folder
    /// or a `.zip`, replacing the one the emulator has.
    public static func importFirmware(from source: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDirectory) else {
                throw SetupError.notFirmware
            }
            if isDirectory.boolValue {
                try copyFirmware(ncaFilesIn: source, to: firmwareFolder)
                return
            }
            guard source.pathExtension.lowercased() == "zip" else { throw SetupError.notFirmware }

            let unpacked = fileManager.temporaryDirectory.appending(path: "kadeh-firmware-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: unpacked) }
            let status = run(
                "/usr/bin/ditto", ["-x", "-k", source.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
            )
            guard status == 0 else { throw SetupError.notFirmware }
            try copyFirmware(ncaFilesIn: unpacked, to: firmwareFolder)
        }.value
    }

    // MARK: - Testable cores

    /// Whether `text` reads like a prod.keys file: it has a `header_key`,
    /// which reading any game file needs, so every real dump carries it.
    static func isKeysFile(_ text: String) -> Bool {
        // Split by line rather than a multiline regex: `\r\n` is one
        // Character in Swift, and `isNewline` covers it.
        text.split(whereSeparator: \.isNewline).contains { line in
            line.wholeMatch(of: /\s*header_key\s*=\s*[0-9a-fA-F]{64}\s*/) != nil
        }
    }

    /// More content files than this, and at least one content meta, is a
    /// whole firmware. A real one has well over a hundred; a handful is a
    /// game's or an update's.
    static let firmwareFileThreshold = 50

    /// Copies a firmware's content files into `registered`: each `<id>.nca`
    /// or `<id>.cnmt.nca` becomes `<id>.nca/00`. Eden reads that layout as
    /// well as plain files, and Ryujinx writes it, so the folder suits either
    /// emulator. Nothing is decrypted, so no keys are needed.
    ///
    /// Walked at any depth, since a zip often holds one folder named after the
    /// version. A folder already in the `<id>.nca/00` layout counts as its
    /// file. Written into a temporary sibling first, and only a complete copy
    /// replaces `registered`, so a failed import keeps the old firmware.
    static func copyFirmware(ncaFilesIn root: URL, to registered: URL) throws {
        let fileManager = FileManager.default
        // Destination folder name to source file; the first of a name wins.
        var files: [String: URL] = [:]
        var hasMeta = false
        // Hidden files skipped: a zip made on a Mac carries `__MACOSX/._<id>.nca`.
        let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        )
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".nca") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            var source = url
            if values?.isDirectory == true {
                walker?.skipDescendants()
                source = url.appending(path: "00")
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            } else if values?.isRegularFile != true {
                continue
            }
            // A folder in the `<id>.nca/00` layout was installed by an emulator
            // or Kadeh, which drop the `.cnmt` from the name: trusted as whole.
            hasMeta = hasMeta || name.lowercased().contains(".cnmt.") || values?.isDirectory == true
            let id = name.prefix { $0 != "." }
            if files["\(id).nca"] == nil {
                files["\(id).nca"] = source
            }
        }
        guard files.count > firmwareFileThreshold, hasMeta else { throw SetupError.notFirmware }

        // Its own name, so two imports at once cannot delete each other's copy.
        let staging = registered.deletingLastPathComponent().appending(path: "registered.tmp-\(UUID().uuidString)")
        do {
            for (name, source) in files {
                let slot = staging.appending(path: name)
                try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: slot.appending(path: "00"))
            }
            try replace(registered, with: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Puts `new` where `old` is in one swap, so there is never a moment
    /// with neither, and a failed swap leaves `old` as it was.
    private static func replace(_ old: URL, with new: URL) throws {
        if FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(old, withItemAt: new)
        } else {
            try FileManager.default.moveItem(at: new, to: old)
        }
    }

    /// Runs a system tool to its end with its output discarded. The exit
    /// status, or `nil` when it could not start.
    private static func run(_ tool: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
