//
//  SaveFolders.swift
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

/// The save folders a person confirmed for each library entry.
///
/// One JSON file keyed by library entry id. Nothing is backed up until a
/// folder is in here: a guess is only ever a suggestion.
public struct SaveFolderStore: Sendable {
    public static var defaultURL: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "SaveFolders").appendingPathExtension("json")
    }

    private let url: URL

    public init(url: URL = SaveFolderStore.defaultURL) {
        self.url = url
    }

    public func folders(for entryID: String) -> [SaveFolder] {
        load()[entryID] ?? []
    }

    /// Every entry's folders, for checks that span games.
    public func allFolders() -> [String: [SaveFolder]] {
        load()
    }

    /// Where every confirmed folder is known to be, bottle or not.
    public func knownLocations() -> [URL] {
        load().values.flatMap { $0 }.compactMap(\.knownLocation)
    }

    /// - Parameter bottleURL: When given, folders without a confirmed place
    ///   get where they really are now.
    public func setFolders(_ folders: [SaveFolder], for entryID: String, bottleURL: URL? = nil) {
        var all = load()
        let recorded = folders.map { folder in
            guard folder.realPath == nil, let bottleURL else { return folder }
            return folder.confirmingLocation(bottleURL: bottleURL)
        }
        all[entryID] = recorded.isEmpty ? nil : recorded
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: url, options: .atomic)
        } catch {
            Logger.wineKit.error("Failed to write save folders: \(error.localizedDescription)")
        }
        SaveBackupOverviews.invalidate(entryID)
    }

    private func load() -> [String: [SaveFolder]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [SaveFolder]].self, from: data)) ?? [:]
    }
}

/// Save folders that lie inside one another.
public enum SaveFolderNesting {
    /// The folders without any that lies inside another one in the list, or
    /// is the same place reached another way: the outer folder's backup
    /// already holds it, and restoring both would replace one twice.
    public static func outermost(
        _ folders: [SaveFolder], bottleURL: URL
    ) -> (kept: [SaveFolder], dropped: [SaveFolder]) {
        let places = folders.map { $0.url(bottleURL: bottleURL).resolvingSymlinksInPath() }
        var kept: [SaveFolder] = []
        var dropped: [SaveFolder] = []
        for (index, folder) in folders.enumerated() {
            let place = places[index]
            let inside = places.indices.contains { other in
                guard other != index else { return false }
                let same = FileScan.isInside(place, places[other]) && FileScan.isInside(places[other], place)
                // The same place twice: the first one stays.
                return same ? other < index : FileScan.isInside(place, places[other])
            }
            if inside { dropped.append(folder) } else { kept.append(folder) }
        }
        return (kept, dropped)
    }
}

/// Replaces folders with restored copies so that a failure part-way leaves
/// every folder as it was.
///
/// Per folder: the current one becomes `<name>.kadeh-old`, the restored one
/// moves into place. Only once every folder is in place are the old ones
/// removed. Restored copies are moved in from a folder next to the target,
/// so on the same volume each step is a rename.
public enum SaveFolderSwap {
    /// - Parameters:
    ///   - pairs: The restored folder and where it goes.
    ///   - move: Injected so tests can make a step fail.
    public static func swap(
        _ pairs: [(source: URL, target: URL)],
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let fileManager = FileManager.default
        var done: [(target: URL, old: URL?)] = []
        var staged: [URL] = []

        func rollBack() {
            for step in done.reversed() {
                try? fileManager.removeItem(at: step.target)
                if let old = step.old {
                    try? move(old, step.target)
                }
            }
            for item in staged {
                try? fileManager.removeItem(at: item)
            }
        }

        do {
            for pair in pairs {
                let parent = pair.target.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

                // Beside the target first, so the final step is a rename.
                let incoming = uniqueSibling(of: pair.target, suffix: ".kadeh-new")
                try fileManager.copyItem(at: pair.source, to: incoming)
                staged.append(incoming)

                var old: URL?
                if fileManager.fileExists(atPath: pair.target.path(percentEncoded: false)) {
                    // Never over a leftover from an earlier, interrupted
                    // restore: that could be somebody's only copy.
                    let aside = uniqueSibling(of: pair.target, suffix: ".kadeh-old")
                    try move(pair.target, aside)
                    old = aside
                }
                done.append((pair.target, old))
                try move(incoming, pair.target)
                staged.removeAll { $0 == incoming }
            }
        } catch {
            rollBack()
            throw error
        }

        for old in done.compactMap(\.old) {
            try? fileManager.removeItem(at: old)
        }
    }

    static func uniqueSibling(of url: URL, suffix: String) -> URL {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var candidate = parent.appending(path: name + suffix)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = parent.appending(path: "\(name)\(suffix)-\(counter)")
            counter += 1
        }
        return candidate
    }
}
