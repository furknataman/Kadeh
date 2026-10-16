//
//  TurkishPatch.swift
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

/// A known Turkish translation patch for a game, as listed in the game database.
///
/// Only patches with ``Access/free`` access, a ``file`` and an ``installer``
/// can be installed by Kadeh; all others are link-only.
public struct TurkishPatch: Codable, Sendable, Equatable, Identifiable {
    /// How the patch can be obtained.
    public enum Access: String, Codable, Sendable { case free, paid, account }

    /// Post-install fixups Kadeh can apply.
    public enum Fixup: String, Codable, Sendable { case spiderManTocMerge }

    /// The downloadable archive, identified by size and SHA-256 rather than name.
    public struct File: Codable, Sendable, Equatable {
        /// The expected archive file name.
        public let name: String
        /// The archive size in bytes.
        public let size: Int64
        /// The lowercase hex SHA-256 of the archive.
        public let sha256: String

        public init(name: String, size: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.sha256 = sha256
        }
    }

    /// Stable identifier for this patch.
    public let id: String
    /// The site the patch comes from (e.g. "turkceyama.com").
    public let source: String
    /// The page where the patch is described and downloaded.
    public let pageURL: URL
    /// The translator or team.
    public let translator: String?
    /// The kind of translation (e.g. "Düzenlenmiş makine çevirisi").
    public let kind: String?
    /// How the patch can be obtained.
    public let access: Access
    /// A free-form note shown to the user.
    public let note: String?
    /// The downloadable archive, if installable.
    public let file: File?
    /// Path of the installer inside the archive.
    public let installer: String?
    /// Files the installer overwrites, relative to the game directory.
    public let modifiedFiles: [String]
    /// Files the installer creates, relative to the game directory.
    public let addedFiles: [String]
    /// An optional fixup applied after the installer finishes.
    public let fixup: Fixup?

    /// Whether Kadeh can download-verify-install this patch.
    public var isInstallable: Bool { access == .free && file != nil && installer != nil }

    public init(
        id: String,
        source: String,
        pageURL: URL,
        translator: String? = nil,
        kind: String? = nil,
        access: Access,
        note: String? = nil,
        file: File? = nil,
        installer: String? = nil,
        modifiedFiles: [String] = [],
        addedFiles: [String] = [],
        fixup: Fixup? = nil
    ) {
        self.id = id
        self.source = source
        self.pageURL = pageURL
        self.translator = translator
        self.kind = kind
        self.access = access
        self.note = note
        self.file = file
        self.installer = installer
        self.modifiedFiles = modifiedFiles
        self.addedFiles = addedFiles
        self.fixup = fixup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.source = try container.decode(String.self, forKey: .source)
        self.pageURL = try container.decode(URL.self, forKey: .pageURL)
        self.translator = try container.decodeIfPresent(String.self, forKey: .translator)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.access = try container.decode(Access.self, forKey: .access)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.file = try container.decodeIfPresent(File.self, forKey: .file)
        self.installer = try container.decodeIfPresent(String.self, forKey: .installer)
        self.modifiedFiles = try container.decodeIfPresent([String].self, forKey: .modifiedFiles) ?? []
        self.addedFiles = try container.decodeIfPresent([String].self, forKey: .addedFiles) ?? []
        self.fixup = try container.decodeIfPresent(Fixup.self, forKey: .fixup)
    }
}
