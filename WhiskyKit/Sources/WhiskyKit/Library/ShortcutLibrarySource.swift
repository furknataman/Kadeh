//
//  ShortcutLibrarySource.swift
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

/// Programs an installer left a shortcut to on the desktop or in the Start menu.
///
/// A setup run from a disc or an archive puts the game in a folder of its own
/// choosing, often outside Program Files, and the shortcut it creates is the one
/// place that says which executable is the game. Setups, uninstallers and
/// runtimes are left out by the same rule the archive installer uses, so this
/// stays a library rather than a file browser.
public enum ShortcutLibrarySource: LibrarySource {
    public static let id = LibrarySourceID.shortcut

    public static func items(inBottleAt url: URL, settings _: BottleSettings) -> [LibraryEntry] {
        entries(inBottleAt: url)
    }

    /// Without the settings parameter so it can run off the main actor: it
    /// reads every shortcut file in the prefix.
    public static func entries(inBottleAt url: URL) -> [LibraryEntry] {
        let driveC = url.appending(path: "drive_c")
        var seen = Set<String>()
        var entries: [LibraryEntry] = []
        for link in shortcutFiles(driveC: driveC) {
            guard let data = try? Data(contentsOf: link),
                  let windowsPath = targetPath(in: data),
                  let target = localURL(windowsPath, driveC: driveC),
                  target.pathExtension.lowercased() == "exe",
                  !ArchiveInstaller.isInstaller(target),
                  !ArchiveInstaller.isRedistributable(target, base: driveC),
                  FileManager.default.fileExists(atPath: target.path(percentEncoded: false)),
                  seen.insert(target.path(percentEncoded: false).lowercased()).inserted
            else { continue }
            entries.append(LibraryEntry(
                id: "shortcut:\(target.path(percentEncoded: false))",
                name: link.deletingPathExtension().lastPathComponent,
                iconURL: target,
                bottleURL: url,
                source: id,
                launch: .program(target),
                launcher: LauncherType.detect(from: target)
            ))
        }
        return entries
    }

    /// Desktops first, so their names win over the Start menu's. Desktops are
    /// read one level deep only: a prefix can link one to the Mac's own desktop.
    private static func shortcutFiles(driveC: URL) -> [URL] {
        let fileManager = FileManager.default
        let users = (try? fileManager.contentsOfDirectory(
            at: driveC.appending(path: "users"), includingPropertiesForKeys: nil
        )) ?? []
        let startMenu = "Microsoft/Windows/Start Menu/Programs"
        let desktops = users.flatMap {
            (try? fileManager.contentsOfDirectory(
                at: $0.appending(path: "Desktop"), includingPropertiesForKeys: nil
            )) ?? []
        }
        let menus = (users.map { $0.appending(path: "AppData/Roaming/\(startMenu)") }
            + [driveC.appending(path: "ProgramData/\(startMenu)")]).flatMap {
            fileManager.enumerator(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL } ?? []
        }
        return (desktops + menus).filter { $0.pathExtension.lowercased() == "lnk" }
    }

    /// The local path a `.lnk` points at, read from its LinkInfo block
    /// ([MS-SHLLINK] 2.3): the base path plus the common suffix.
    static func targetPath(in data: Data) -> String? {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func ansi(_ start: Int) -> String? {
            guard start >= 0, start < bytes.count, let end = bytes[start...].firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[start..<end], encoding: .windowsCP1254)
        }
        func unicode(_ start: Int) -> String? {
            var end = start
            while end + 1 < bytes.count, bytes[end] != 0 || bytes[end + 1] != 0 { end += 2 }
            guard start >= 0, end + 1 < bytes.count else { return nil }
            return String(bytes: bytes[start..<end], encoding: .utf16LittleEndian)
        }

        guard let headerSize = u32(0), let flags = u32(0x14) else { return nil }
        var info = headerSize
        if flags & 0x1 != 0 {
            guard info + 2 <= bytes.count else { return nil }
            info += (Int(bytes[info]) | Int(bytes[info + 1]) << 8) + 2
        }
        guard flags & 0x2 != 0, let infoHeader = u32(info + 4), let infoFlags = u32(info + 8),
              infoFlags & 0x1 != 0 else { return nil }
        if infoHeader >= 0x24, let base = u32(info + 28), let suffix = u32(info + 32),
           let path = unicode(info + base) {
            return path + (unicode(info + suffix) ?? "")
        }
        guard let base = u32(info + 16), let suffix = u32(info + 24), let path = ansi(info + base) else {
            return nil
        }
        return path + (ansi(info + suffix) ?? "")
    }

    /// `C:\Games\X\x.exe` inside the bottle. Other drives are mounts that come
    /// and go, so they are not library material.
    static func localURL(_ windowsPath: String, driveC: URL) -> URL? {
        guard windowsPath.count > 3, windowsPath.prefix(3).uppercased() == "C:\\" else { return nil }
        return windowsPath.dropFirst(3).split(separator: "\\").reduce(driveC) { $0.appending(path: String($1)) }
    }
}
