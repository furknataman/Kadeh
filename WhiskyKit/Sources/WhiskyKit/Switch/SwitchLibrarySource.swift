//
//  SwitchLibrarySource.swift
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

import AppKit
import CryptoKit
import Foundation

/// The Switch games in the folder the user chose.
///
/// Not a ``LibrarySource``: those are read per bottle, and Switch games have
/// no bottle. Names come from the file name and covers are drawn by Kadeh;
/// reading the real title and icon out of a game file is a later step.
public enum SwitchLibrarySource {
    /// Every base game under `folder`, at any depth, sorted by name. Reads
    /// the disk and may draw covers, so not for the main thread.
    public static func entries(in folder: URL) -> [LibraryEntry] {
        entries(in: folder, covers: SwitchEmulator.folder.appending(path: "covers"))
    }

    /// ``entries(in:)`` drawing its covers into `covers`, so a test never
    /// writes into Kadeh's own folder.
    static func entries(in folder: URL, covers: URL) -> [LibraryEntry] {
        let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let games = (walker?.compactMap { $0 as? URL } ?? []).filter { url in
            ["nsp", "xci"].contains(url.pathExtension.lowercased())
                && isBaseGame(fileName: url.lastPathComponent)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return games.map { game in
            // Tied to the path, like a pinned program: a moved file is a new entry.
            let id = "switch:\(game.path(percentEncoded: false))"
            let name = title(fromFileName: game.lastPathComponent)
            let art = coverURLs(id: id, title: name, in: covers)
            return LibraryEntry(
                id: id,
                name: name,
                iconURL: nil,
                artworkURL: art.wide,
                heroURL: art.wide,
                logoURL: nil,
                portraitURL: art.tall,
                bottleURL: SwitchEmulator.dataFolder,
                source: .nintendoSwitch,
                launch: .switchGame(game)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A readable title from a dump's file name: without the extension, the
    /// `[title id]`, `[v0]` and `(region)` tags, and underscores.
    static func title(fromFileName name: String) -> String {
        let bare = (name as NSString).deletingPathExtension
        let title = bare.replacing(/\[[^\]]*\]|\([^)]*\)/, with: "")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return title.isEmpty ? bare : title
    }

    /// Whether a file is a game rather than its update or DLC, which the emulator
    /// installs from its own window. A base game's title id always ends in
    /// `000` (an update's in `800`); a name with no id in it is shown.
    static func isBaseGame(fileName name: String) -> Bool {
        let upper = name.uppercased()
        guard !upper.contains("[UPD]"), !upper.contains("[DLC]") else { return false }
        guard let match = upper.firstMatch(of: /\[([0-9A-F]{16})\]/) else { return true }
        return match.1.hasSuffix("000")
    }

    // MARK: - Covers

    /// The wide and the portrait cover for an entry, drawn the first time it
    /// is seen. `nil` where drawing failed: the card then falls back the way
    /// it does for any game without art.
    private static func coverURLs(id: String, title: String, in folder: URL) -> (wide: URL?, tall: URL?) {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        func cover(_ kind: String, width: Int, height: Int) -> URL? {
            let url = folder.appending(path: "\(key)-\(kind).png")
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
            guard let png = drawCover(title: title, width: width, height: height),
                  (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? png.write(to: url, options: .atomic)) != nil
            else { return nil }
            return url
        }
        // Steam's header and portrait capsule sizes, so a Switch card sits like a Steam one.
        return (cover("wide", width: 920, height: 430), cover("tall", width: 600, height: 900))
    }

    /// A dark-to-Switch-red gradient with the title in bold white, wrapped and
    /// centred. Drawn into a bitmap of its own, so it is safe off the main thread.
    private static func drawCover(title: String, width: Int, height: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let dark = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        let red = NSColor(srgbRed: 230 / 255, green: 0, blue: 18 / 255, alpha: 1)
        // From the top left to the bottom right.
        NSGradient(starting: dark, ending: red)?.draw(in: bounds, angle: -45)

        let box = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Shrunk until a long title fits the box.
        var fontSize = min(bounds.width, bounds.height) * 0.15
        var text: NSAttributedString
        var used: CGRect
        repeat {
            text = NSAttributedString(string: title, attributes: [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ])
            used = text.boundingRect(
                with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
            )
            fontSize *= 0.9
        } while used.height > box.height && fontSize > 12
        text.draw(
            with: CGRect(x: box.minX, y: box.midY - used.height / 2, width: box.width, height: used.height),
            options: [.usesLineFragmentOrigin]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }
}
