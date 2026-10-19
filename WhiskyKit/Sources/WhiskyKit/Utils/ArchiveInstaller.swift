//
//  ArchiveInstaller.swift
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

/// Unpacks a game or installer archive into a bottle and finds what to run in it.
public enum ArchiveInstaller {
    public static let archiveExtensions = ["zip", "rar", "7z", "iso", "tar", "gz", "tgz", "bz2", "xz", "cab"]

    private static let installerNames: Set<String> = ["setup", "install", "installer", "autorun"]
    private static let installerPrefixes = ["setup", "install"]
    private static let redistMarkers = [
        "vcredist", "vc_redist", "dxsetup", "directx", "dotnet", "ndp", "physx", "oalinst", "unins", "crashhandler"
    ]
    private static let redistFolders: Set<String> = ["redist", "_commonredist"]

    /// Extracts into `<bottle>/drive_c/Kurulum/<archive name without extension>`,
    /// appending " 2", " 3"… when that folder exists. Returns the folder.
    ///
    /// Downloads often wrap a disc image or another archive in a zip. When the
    /// first pass holds no program, the archives inside are unpacked next to
    /// themselves (two levels at most) and the inner copies are removed; the
    /// user's own download is never touched.
    public static func extract(_ archive: URL, bottleURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let dir = uniqueFolder(bottleURL.appending(path: "drive_c").appending(path: "Kurulum"),
                               name: archive.deletingPathExtension().lastPathComponent)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            try unpack(archive, into: dir)
            for _ in 0..<2 where programs(in: dir).isEmpty {
                let inner = nestedArchives(in: dir)
                if inner.isEmpty { break }
                for file in inner {
                    let target = uniqueFolder(file.deletingLastPathComponent(),
                                              name: file.deletingPathExtension().lastPathComponent)
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    try unpack(file, into: target)
                    try? fileManager.removeItem(at: file)
                }
            }
        } catch {
            try? fileManager.removeItem(at: dir)
            throw error
        }
        return dir
    }

    private static func uniqueFolder(_ parent: URL, name: String) -> URL {
        var dir = parent.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = parent.appending(path: "\(name) \(counter)")
            counter += 1
        }
        return dir
    }

    private static func nestedArchives(in dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            archiveExtensions.contains($0.pathExtension.lowercased())
                && !$0.pathComponents.contains("__MACOSX")
        }
    }

    /// Disc images are mounted read-only and copied: macOS reads every disc layout, while bsdtar
    /// only reads ISO 9660 and quietly returns an empty stub for UDF-only discs, so it is the fallback.
    private static func unpack(_ archive: URL, into dir: URL) throws {
        let bsdtar = { try runTool("/usr/bin/bsdtar", ["-xf", archive.path, "-C", dir.path]) }
        guard archive.pathExtension.lowercased() == "iso" else { return try bsdtar() }
        let mount = FileManager.default.temporaryDirectory.appending(path: "kadeh-iso-\(UUID().uuidString)")
        defer {
            try? runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try runTool("/usr/bin/hdiutil", [
                "attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path
            ])
        } catch {
            return try bsdtar()
        }
        try runTool("/usr/bin/ditto", [mount.path, dir.path])
    }

    /// .exe/.msi files under `dir`, best installer candidate first.
    public static func programs(in dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = dir.standardizedFileURL.pathComponents.count

        var found: [(url: URL, installer: Bool, redist: Bool, depth: Int)] = []
        for case let item as URL in walker {
            if item.lastPathComponent == "__MACOSX" {
                walker.skipDescendants()
                continue
            }
            let ext = item.pathExtension.lowercased()
            guard ext == "exe" || ext == "msi" else { continue }
            found.append((item, isInstaller(item), isRedistributable(item, base: dir), item.standardizedFileURL.pathComponents.count - base))
        }
        return found.sorted { lhs, rhs in
            if lhs.installer != rhs.installer { return lhs.installer }
            if lhs.redist != rhs.redist { return !lhs.redist }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
        }.map(\.url)
    }

    /// True when the file name looks like an installer (setup/install/installer/autorun, or starting with setup/install).
    public static func isInstaller(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return installerNames.contains(name) || installerPrefixes.contains { name.hasPrefix($0) }
    }

    /// True for runtimes and helpers bundled next to a game (vcredist, DirectX, uninstallers…).
    public static func isRedistributable(_ url: URL, base: URL) -> Bool {
        let baseCount = base.standardizedFileURL.pathComponents.count
        let components = url.standardizedFileURL.pathComponents.dropFirst(baseCount).map { $0.lowercased() }
        if components.dropLast().contains(where: { redistFolders.contains($0) }) { return true }
        let path = components.joined(separator: "/")
        return redistMarkers.contains { path.contains($0) }
    }

    /// Runs a command-line tool and throws its stderr when it fails.
    private static func runTool(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveInstallerError.extractFailed(
                text.flatMap { $0.isEmpty ? nil : $0 } ?? "\(URL(fileURLWithPath: tool).lastPathComponent) \(process.terminationStatus)"
            )
        }
    }
}

public enum ArchiveInstallerError: LocalizedError {
    case extractFailed(String)

    public var errorDescription: String? {
        switch self {
        case .extractFailed(let message): message
        }
    }
}
