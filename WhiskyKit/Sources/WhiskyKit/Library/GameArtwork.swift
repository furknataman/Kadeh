//
//  GameArtwork.swift
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
import CoreImage
import Foundation
import ImageIO

/// Large game art, decoded at the size it is shown and tinted by its own colour.
///
/// Separate from ``IconCache`` because the sizes differ by an order of
/// magnitude: Steam's `library_hero.jpg` is 3840x1240, and decoding a few of
/// those at full size would push every card's banner out of that cache.
public actor GameArtwork {
    public static let shared = GameArtwork()

    private final class ImageBox {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private let images = NSCache<NSString, ImageBox>()
    private var tints: [URL: IconPalette] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        images.countLimit = 40
        images.totalCostLimit = 120 * 1_024 * 1_024
    }

    /// The image at `url`, decoded so its longer side is at most `maxPixels`.
    public func image(at url: URL, maxPixels: Int) -> NSImage? {
        let key = "\(url.path(percentEncoded: false))|\(maxPixels)" as NSString
        if let cached = images.object(forKey: key) { return cached.image }
        guard let cgImage = Self.downsampled(url, maxPixels: maxPixels) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(ImageBox(image), forKey: key, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    /// The average colour of the image at `url`, for tinting a page behind it.
    ///
    /// A plain average rather than ``IconPalette/palette(for:sampleSize:)``:
    /// that one hunts for the saturated mark in an icon, while a backdrop
    /// should match the overall cast of the art, which is what an average is.
    public func tint(of url: URL) -> IconPalette? {
        if let cached = tints[url] { return cached }
        guard let cgImage = Self.downsampled(url, maxPixels: 64) else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent)
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let tint = IconPalette(
            red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255
        )
        tints[url] = tint
        return tint
    }

    /// ImageIO's thumbnail path decodes straight to the smaller size, so the
    /// full-resolution bitmap never exists in memory.
    private static func downsampled(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// How much disk a library entry's install takes.
public enum InstallSize {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [String: Int64?] = [:]

        func size(for key: String) -> Int64?? {
            lock.lock()
            defer { lock.unlock() }
            return sizes[key]
        }

        func store(_ size: Int64?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            sizes[key] = size
        }
    }

    private static let cache = Cache()
    /// A folder with more entries than this is not one game's install.
    private static let maximumVisited = 200_000

    /// Bytes on disk, or `nil` when it cannot be told. Cached per entry for the app run.
    public static func bytes(for entry: LibraryEntry) async -> Int64? {
        guard !entry.isLauncher else { return nil }
        if let cached = cache.size(for: entry.id) { return cached }
        let launch = entry.launch
        let bottleURL = entry.bottleURL
        let size = await Task.detached(priority: .utility) { () -> Int64? in
            switch launch {
            case let .steam(appID):
                // Steam already counted it, and walking a 70 GB folder to agree would take a while.
                let game = SteamLibrary.enumerate(bottleURL: bottleURL).first { $0.appId == appID }
                guard let game else { return nil }
                return game.manifest.sizeOnDisk ?? folderSize(game.installURL)
            case let .program(url):
                let folder = url.deletingLastPathComponent()
                return isOwnFolder(folder) ? folderSize(folder) : nil
            }
        }.value
        cache.store(size, for: entry.id)
        return size
    }

    // ponytail: a program's install is taken to be its executable's folder.
    // Good for the usual `Program Files/<Game>/game.exe`; anything sitting
    // straight in a shared folder gets no size rather than a wrong one.
    private static func isOwnFolder(_ folder: URL) -> Bool {
        let shared: Set<String> = [
            "drive_c", "program files", "program files (x86)", "desktop", "downloads", "documents", "windows",
            "system32", "syswow64", "users", "public"
        ]
        return !shared.contains(folder.lastPathComponent.lowercased())
    }

    private static func folderSize(_ folder: URL) -> Int64? {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return nil }
        var total: Int64 = 0
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > maximumVisited { return nil }
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total > 0 ? total : nil
    }
}
