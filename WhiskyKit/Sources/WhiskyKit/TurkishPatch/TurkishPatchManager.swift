//
//  TurkishPatchManager.swift
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

import CryptoKit
import Foundation

/// Whether a Turkish patch is installed in a game directory.
public enum TurkishPatchStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// The patch was installed but the game's patched files changed afterwards (e.g. a Steam update).
    case gameUpdated
}

/// Persisted record of an installed patch (`<game>/.kadeh-yama/<id>/state.json`).
public struct TurkishPatchState: Codable, Equatable {
    public let installedAt: Date
    public let fileSHA256: String
    /// SHA-256 of each `modifiedFiles` entry right after installation, keyed by relative path.
    public let modifiedFileHashes: [String: String]

    public init(installedAt: Date, fileSHA256: String, modifiedFileHashes: [String: String]) {
        self.installedAt = installedAt
        self.fileSHA256 = fileSHA256
        self.modifiedFileHashes = modifiedFileHashes
    }
}

/// Errors raised while installing or removing a Turkish patch.
public enum TurkishPatchError: LocalizedError, Equatable {
    case notInstallable
    case alreadyInstalled
    case hashMismatch(expected: String, actual: String)
    case extractFailed(String)
    case installerMissing(String)
    case addedFilesMissing([String])
    case fixupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstallable:
            return "Bu yama Kadeh ile kurulamaz."
        case .alreadyInstalled:
            return "Bu yama zaten kurulu."
        case .hashMismatch:
            return "İndirilen dosya beklenen dosya değil (SHA-256 eşleşmedi)."
        case .extractFailed(let detail):
            return "Arşiv açılamadı: \(detail)"
        case .installerMissing(let path):
            return "Arşivde yükleyici bulunamadı: \(path)"
        case .addedFilesMissing:
            return "Yükleyici beklenen dosyaları oluşturmadı. "
                + "Yükleyicide oyun klasörünü doğru seçtiğinizden emin olun."
        case .fixupFailed(let detail):
            return "Yama oyunun bu sürümüne uyarlanamadı; değişiklikler geri alındı. (\(detail))"
        }
    }
}

/// Installs and removes known Turkish patches: verify, extract, back up, finish, uninstall.
public enum TurkishPatchManager {
    private static let installerName = "Kurulum.exe"

    // MARK: Hashing and discovery

    /// Streams `url` through SHA-256 and returns the lowercase hex digest.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Finds the downloaded archive in `dir` by size and SHA-256, ignoring its name.
    public static func findDownload(_ file: TurkishPatch.File, in dir: URL) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == file.size,
                  let digest = try? sha256(of: item),
                  digest == file.sha256.lowercased()
            else { continue }
            return item
        }
        return nil
    }

    // MARK: Paths

    /// `<bottle>/drive_c/KadehYama/<patch.id>`
    public static func stagingURL(bottleURL: URL, patch: TurkishPatch) -> URL {
        bottleURL.appendingPathComponent("drive_c/KadehYama/\(patch.id)", isDirectory: true)
    }

    /// Converts a path under `<bottle>/drive_c` to a Windows `C:\` path.
    public static func windowsPath(of url: URL, bottleURL: URL) -> String {
        let prefix = bottleURL.appendingPathComponent("drive_c").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return path }
        let rest = path.dropFirst(prefix.count).split(separator: "/").joined(separator: "\\")
        return rest.isEmpty ? "C:\\" : "C:\\" + rest
    }

    private static func patchDir(_ patch: TurkishPatch, gameURL: URL) -> URL {
        gameURL.appendingPathComponent(".kadeh-yama/\(patch.id)", isDirectory: true)
    }

    private static func backupDir(_ patch: TurkishPatch, gameURL: URL) -> URL {
        patchDir(patch, gameURL: gameURL).appendingPathComponent("backup", isDirectory: true)
    }

    private static func stateURL(_ patch: TurkishPatch, gameURL: URL) -> URL {
        patchDir(patch, gameURL: gameURL).appendingPathComponent("state.json")
    }

    // MARK: Stage

    /// Verifies the archive hash, extracts it, copies the installer to an ASCII name and backs up `modifiedFiles`.
    ///
    /// - Returns: The URL of `Kurulum.exe` inside the staging directory.
    public static func stage(
        _ patch: TurkishPatch, archive: URL, gameURL: URL, bottleURL: URL
    ) throws -> URL {
        guard patch.isInstallable, let file = patch.file, let installer = patch.installer else {
            throw TurkishPatchError.notInstallable
        }
        guard status(of: patch, gameURL: gameURL) != .installed else {
            throw TurkishPatchError.alreadyInstalled
        }
        let actual = try sha256(of: archive)
        guard actual == file.sha256.lowercased() else {
            throw TurkishPatchError.hashMismatch(expected: file.sha256, actual: actual)
        }

        let fileManager = FileManager.default
        let staging = stagingURL(bottleURL: bottleURL, patch: patch)
        let extracted = staging.appendingPathComponent("extract", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        do {
            try extract(archive, to: extracted)
            guard let source = findInstaller(installer, in: extracted) else {
                throw TurkishPatchError.installerMissing(installer)
            }
            let exe = staging.appendingPathComponent(installerName)
            try fileManager.copyItem(at: source, to: exe)
            try backUp(patch, gameURL: gameURL)
            return exe
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func extract(_ archive: URL, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-xf", archive.path, "-C", dir.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TurkishPatchError.extractFailed(error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TurkishPatchError.extractFailed(text.flatMap { $0.isEmpty ? nil : $0 } ?? "bsdtar \(process.terminationStatus)")
        }
    }

    /// Archive names are NFD; the catalog is NFC, so compare the canonically composed forms.
    private static func findInstaller(_ installer: String, in dir: URL) -> URL? {
        let wanted = installer.precomposedStringWithCanonicalMapping
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let item as URL in walker {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if relative.precomposedStringWithCanonicalMapping == wanted { return item }
        }
        return nil
    }

    /// Starts from a fresh `.kadeh-yama/<id>` so the backup always reflects the files the installer is about to change.
    private static func backUp(_ patch: TurkishPatch, gameURL: URL) throws {
        let fileManager = FileManager.default
        let backup = backupDir(patch, gameURL: gameURL)
        // A backup without state.json is from an install that never reached `finish`.
        // The installer may already have overwritten the game's files by then, so that
        // backup is the only clean copy left: keep it rather than back up patched files.
        if fileManager.fileExists(atPath: backup.path),
           !fileManager.fileExists(atPath: stateURL(patch, gameURL: gameURL).path) {
            return
        }
        try? fileManager.removeItem(at: patchDir(patch, gameURL: gameURL))
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        for relative in patch.modifiedFiles {
            let source = gameURL.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = backup.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: target)
        }
    }

    // MARK: Finish

    /// Completes an installation after the user closed the installer. Rolls everything back on any error.
    public static func finish(
        _ patch: TurkishPatch, gameURL: URL, bottleURL: URL, fileSHA256: String
    ) throws {
        defer { try? FileManager.default.removeItem(at: stagingURL(bottleURL: bottleURL, patch: patch)) }
        do {
            let fileManager = FileManager.default
            let missing = patch.addedFiles.filter {
                !fileManager.fileExists(atPath: gameURL.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else { throw TurkishPatchError.addedFilesMissing(missing) }

            try applyFixup(patch, gameURL: gameURL)

            var hashes: [String: String] = [:]
            for relative in patch.modifiedFiles {
                let url = gameURL.appendingPathComponent(relative)
                if fileManager.fileExists(atPath: url.path) { hashes[relative] = try sha256(of: url) }
            }
            let state = TurkishPatchState(installedAt: Date(), fileSHA256: fileSHA256, modifiedFileHashes: hashes)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL(patch, gameURL: gameURL), options: .atomic)
        } catch {
            rollback(patch, gameURL: gameURL)
            throw error
        }
    }

    private static func applyFixup(_ patch: TurkishPatch, gameURL: URL) throws {
        guard let fixup = patch.fixup else { return }
        switch fixup {
        case .spiderManTocMerge:
            do {
                let original = try Data(contentsOf: backupDir(patch, gameURL: gameURL)
                    .appendingPathComponent("asset_archive/toc"))
                let tocURL = gameURL.appendingPathComponent("asset_archive/toc")
                let patched = try Data(contentsOf: tocURL)
                let merged = try SpiderManToc.merge(original: original, patched: patched)
                try merged.toc.write(to: tocURL, options: .atomic)
            } catch {
                throw TurkishPatchError.fixupFailed(String(describing: error))
            }
        }
    }

    private static func rollback(_ patch: TurkishPatch, gameURL: URL) {
        restoreBackups(patch, gameURL: gameURL)
        removeAddedFiles(patch, gameURL: gameURL)
        try? FileManager.default.removeItem(at: patchDir(patch, gameURL: gameURL))
    }

    private static func restoreBackups(_ patch: TurkishPatch, gameURL: URL) {
        let fileManager = FileManager.default
        let backup = backupDir(patch, gameURL: gameURL)
        for relative in patch.modifiedFiles {
            let source = backup.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = gameURL.appendingPathComponent(relative)
            try? fileManager.removeItem(at: target)
            try? fileManager.copyItem(at: source, to: target)
        }
    }

    private static func removeAddedFiles(_ patch: TurkishPatch, gameURL: URL) {
        for relative in patch.addedFiles {
            try? FileManager.default.removeItem(at: gameURL.appendingPathComponent(relative))
        }
    }

    // MARK: Status and uninstall

    public static func status(of patch: TurkishPatch, gameURL: URL) -> TurkishPatchStatus {
        guard let data = try? Data(contentsOf: stateURL(patch, gameURL: gameURL)) else { return .notInstalled }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(TurkishPatchState.self, from: data) else { return .notInstalled }
        for relative in patch.modifiedFiles {
            let current = try? sha256(of: gameURL.appendingPathComponent(relative))
            if current != state.modifiedFileHashes[relative] { return .gameUpdated }
        }
        return .installed
    }

    /// Removes the patch. The backup is restored only when the patched files are still untouched.
    public static func uninstall(_ patch: TurkishPatch, gameURL: URL) throws {
        let current = status(of: patch, gameURL: gameURL)
        if current == .installed { restoreBackups(patch, gameURL: gameURL) }
        if current != .notInstalled { removeAddedFiles(patch, gameURL: gameURL) }
        let dir = patchDir(patch, gameURL: gameURL)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
