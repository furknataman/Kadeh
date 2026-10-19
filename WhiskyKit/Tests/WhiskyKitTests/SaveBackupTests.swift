//
//  SaveBackupTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

/// Every test works in a fresh folder under the temporary directory: a fake
/// bottle and a fake backup root, never a real one.
private struct Sandbox {
    let root: URL
    var bottle: URL { root.appending(path: "Bottle") }
    var backups: URL { root.appending(path: "Backups") }

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "kadeh-saves-\(UUID().uuidString)")
    }

    func write(_ text: String, to relative: String) throws {
        let url = bottle.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: bottle.appending(path: relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Save Locator Tests")
struct SaveLocatorTests {
    @Test("Title keys include the part before a subtitle and the bare name")
    func nameKeys() {
        let keys = SaveLocator.nameKeys("Marvel's Spider-Man Remastered")
        #expect(keys.contains("marvelsspidermanremastered"))
        #expect(keys.contains("spiderman"))
        #expect(SaveLocator.nameKeys("Trine 4: The Nightmare Prince").contains("trine4"))
        #expect(SaveLocator.matches("Trine4", keys: SaveLocator.nameKeys("Trine 4: The Nightmare Prince")))
        #expect(!SaveLocator.matches("Microsoft", keys: keys))
    }

    @Test("Finds named folders and skips launcher folders")
    func findsFolders() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let profile = "drive_c/users/crossover"
        try sandbox.write("save", to: "\(profile)/Documents/Marvel's Spider-Man Remastered/1/slot0.save")
        try sandbox.write("cfg", to: "\(profile)/AppData/Roaming/Insomniac Games/Marvel's Spider-Man Remastered/a.cfg")
        try sandbox.write("x", to: "\(profile)/AppData/Local/Steam/spiderman/x")
        try sandbox.write("x", to: "\(profile)/Documents/Unrelated/x")
        try FileManager.default.createSymbolicLink(
            at: sandbox.bottle.appending(path: "drive_c/users/furkan"),
            withDestinationURL: sandbox.bottle.appending(path: profile)
        )

        let found = SaveLocator.candidates(
            for: SaveSearch(title: "Marvel's Spider-Man Remastered", bottleURL: sandbox.bottle)
        )
        let paths = found.map(\.folder.path)

        #expect(paths.contains("\(profile)/Documents/Marvel's Spider-Man Remastered"))
        #expect(paths.contains("\(profile)/AppData/Roaming/Insomniac Games/Marvel's Spider-Man Remastered"))
        #expect(!paths.contains { $0.contains("Steam") || $0.contains("Unrelated") })
        // The linked profile is the same folder, so it is not listed twice.
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.folder.inBottle && $0.reason == .nameMatch })
    }

    @Test("Looks one company folder deep, keeps Rockstar Games, finds Unreal saves, skips the backups")
    func deeperSuggestions() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let profile = "drive_c/users/crossover"
        try sandbox.write("s", to: "\(profile)/Saved Games/Remedy/Alan Wake 2/slot")
        try sandbox.write("s", to: "\(profile)/Documents/Rockstar Games/Alan Wake 2/Profiles/p")
        try sandbox.write("s", to: "\(profile)/Documents/My Games/Remedy Entertainment/Alan Wake 2/x")
        try sandbox.write("s", to: "\(profile)/Documents/Remedy/Alan Wake 2/y")
        try sandbox.write("s", to: "\(profile)/AppData/Local/AW2Project/Saved/SaveGames/a.sav")
        try sandbox.write("s", to: "\(profile)/Documents/Kadeh Kayıt Yedekleri/Alan Wake 2 (abcd1234)/b.zip")

        let found = SaveLocator.candidates(for: SaveSearch(
            title: "Alan Wake 2", bottleURL: sandbox.bottle, changedSince: Date().addingTimeInterval(-600),
            backupRoot: sandbox.bottle.appending(path: "\(profile)/Documents/Kadeh Kayıt Yedekleri")
        ))
        let reasons = Dictionary(uniqueKeysWithValues: found.map { ($0.folder.path, $0.reason) })

        #expect(reasons["\(profile)/Saved Games/Remedy/Alan Wake 2"] == .nameMatch)
        #expect(reasons["\(profile)/Documents/Rockstar Games/Alan Wake 2"] == .nameMatch)
        #expect(reasons["\(profile)/Documents/My Games/Remedy Entertainment/Alan Wake 2"] == .nameMatch)
        #expect(reasons["\(profile)/Documents/Remedy/Alan Wake 2"] == .nameMatch)
        #expect(reasons["\(profile)/AppData/Local/AW2Project/Saved/SaveGames"] == .recentlyChanged)
        #expect(reasons["\(profile)/AppData/Local/AW2Project/Saved"] == nil)
        #expect(!reasons.keys.contains { $0.contains("Kadeh") })
    }

    @Test("A large folder is marked so it starts unticked")
    func largeCandidate() {
        let folder = SaveFolder(path: "x", inBottle: true)
        let large = SaveCandidate(
            folder: folder, url: URL(filePath: "/x"), reason: .nameMatch, files: 1,
            bytes: SaveCandidate.largeBytes + 1, modified: nil, isCapped: false
        )
        #expect(large.isLarge)
        let capped = SaveCandidate(
            folder: folder, url: URL(filePath: "/x"), reason: .nameMatch, files: 5_000, bytes: 1_000,
            modified: nil, isCapped: true
        )
        #expect(capped.isLarge)
    }

    @Test("Counting stops at the limit and says so")
    func measureCaps() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        for index in 0 ..< 4 {
            try sandbox.write("x", to: "big/\(index)")
        }
        #expect(FileScan.measure(sandbox.bottle.appending(path: "big"), limit: 3).capped)
        #expect(!FileScan.measure(sandbox.bottle.appending(path: "big"), limit: 10).capped)
    }
}

@Suite("Save Backup Tests")
struct SaveBackupTests {
    private let folder = SaveFolder(path: "drive_c/users/crossover/Documents/Game", inBottle: true)
    private let game = SaveGame(id: "steam:/bottles/A:42", name: "Game")

    private func archiveIsIntact(_ url: URL) -> Bool {
        SaveBackupManifestReader.unzip(["-tqq", url.lastPathComponent], in: url)?.status == 0
    }

    @Test("File names carry the date and label and read back")
    func naming() throws {
        let date = Date(timeIntervalSince1970: 1_792_343_492)
        let stem = SaveBackupStore.fileStem(for: date, label: "Geri yüklemeden önce")
        let parsed = try #require(SaveBackupStore.parse(fileName: stem + ".zip"))

        #expect(parsed.created == date)
        #expect(parsed.label == "Geri yüklemeden önce")
        #expect(SaveBackupStore.parse(fileName: "notes.txt") == nil)
        let second = "\(SaveBackupStore.fileStem(for: date, label: "")) (2).zip"
        #expect(SaveBackupStore.parse(fileName: second)?.label == "")
        #expect(SaveBackupStore.folderName(forGame: "Half-Life: Alyx") == "Half-Life- Alyx")
    }

    @Test("Keeps the newest ten and prunes only its own archives")
    func retention() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let store = SaveBackupStore(root: sandbox.backups)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fileManager = FileManager.default

        // Another game's archive, a date-named zip with no manifest and a
        // date-named folder, all older than every backup and in its folder.
        let other = SaveGame(id: "other", name: "Game")
        let foreign = try store.backUp(game: other, folders: [folder], bottleURL: sandbox.bottle, now: start)
        let gameFolder = store.gameFolder(for: game)
        try fileManager.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        let strays = [
            gameFolder.appending(path: "notes.txt"),
            gameFolder.appending(path: "2000-01-01 00.00.00.zip"),
            gameFolder.appending(path: "2000-01-02 00.00.00 kopya.zip")
        ]
        try Data("mine".utf8).write(to: strays[0])
        try Data("not a zip".utf8).write(to: strays[1])
        try fileManager.createDirectory(at: strays[2], withIntermediateDirectories: true)
        let moved = gameFolder.appending(path: "1999-01-01 00.00.00.zip")
        try fileManager.copyItem(at: foreign.url, to: moved)

        for step in 1 ... 12 {
            try store.backUp(
                game: game, folders: [folder], bottleURL: sandbox.bottle, trigger: .manual,
                now: start.addingTimeInterval(Double(step))
            )
        }

        let kept = store.backups(for: game)
        #expect(kept.count == 10)
        #expect(kept.first?.created == start.addingTimeInterval(12))
        #expect(kept.last?.created == start.addingTimeInterval(3))
        for path in strays + [moved, foreign.url] {
            #expect(fileManager.fileExists(atPath: path.path(percentEncoded: false)))
        }
        #expect(store.backups(for: other).count == 1)
    }

    @Test("A backup with no existing folder fails, leaves no file and is recorded")
    func nothingToBackUp() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let status = SaveBackupStatusStore(url: sandbox.root.appending(path: "status.json"))
        let store = SaveBackupStore(root: sandbox.backups, status: status)

        #expect(throws: SaveBackupError.nothingToBackUp) {
            try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        }
        #expect(store.backups(for: game).isEmpty)
        let failed = try #require(status.attempt(for: game.id))
        #expect(!failed.succeeded)
        #expect(failed.message == SaveBackupError.nothingToBackUp.shortReason)

        try sandbox.write("v1", to: folder.path + "/slot.save")
        let made = try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(status.attempt(for: game.id)?.succeeded == true)
        #expect(status.attempt(for: game.id)?.lastBackup == made.created)
    }

    @Test("Restore puts the backup back and keeps a safety copy")
    func restore() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("old", to: folder.path + "/slot.save")
        let backup = try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, now: Date(timeIntervalSince1970: 1)
        )
        try sandbox.write("new", to: folder.path + "/slot.save")
        try sandbox.write("extra", to: folder.path + "/later.save")

        let safety = try store.restore(
            backup, game: game, bottleURL: sandbox.bottle, confirmed: [folder],
            safetyLabel: "Geri yüklemeden önce", now: Date(timeIntervalSince1970: 2)
        )

        #expect(sandbox.read(folder.path + "/slot.save") == "old")
        #expect(sandbox.read(folder.path + "/later.save") == nil)
        let all = store.backups(for: game)
        #expect(all.count == 2)
        #expect(all.first?.isSafety == true)
        #expect(all.first?.url.lastPathComponent == safety?.url.lastPathComponent)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: sandbox.bottle.appending(path: folder.path).deletingLastPathComponent().path
        )
        #expect(leftovers == ["Game"])
    }

    // A1
    @Test("A backup folder inside a save folder is refused, and a restore there touches nothing")
    func refusesBackupRootInsideSaves() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("old", to: folder.path + "/slot.save")
        let backup = try SaveBackupStore(root: sandbox.backups)
            .backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        try sandbox.write("new", to: folder.path + "/slot.save")

        let inside = SaveBackupStore(root: sandbox.bottle.appending(path: folder.path).appending(path: "Backups"))
        #expect(inside.overlapsRoot(folder, bottleURL: sandbox.bottle))
        #expect(throws: SaveBackupError.overlapsBackupLocation) {
            try inside.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        }
        #expect(throws: SaveBackupError.overlapsBackupLocation) {
            try inside.restore(backup, game: game, bottleURL: sandbox.bottle, confirmed: [folder])
        }
        #expect(sandbox.read(folder.path + "/slot.save") == "new")
        #expect(!FileManager.default.fileExists(atPath: inside.root.path(percentEncoded: false)))

        // The other way round: a save folder inside the backup folder.
        let around = SaveBackupStore(root: sandbox.bottle.appending(path: "drive_c"))
        #expect(around.overlapsRoot(folder, bottleURL: sandbox.bottle))
    }

    // A2
    @Test("Backups started together each get their own intact archive")
    func concurrentBackups() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let store = SaveBackupStore(root: sandbox.backups)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bottle = sandbox.bottle
        let folder = folder
        let game = game

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            _ = try? store.backUp(game: game, folders: [folder], bottleURL: bottle, trigger: .manual, now: now)
        }

        let all = store.backups(for: game)
        #expect(all.count == 4)
        #expect(Set(all.map(\.url.lastPathComponent)).count == 4)
        #expect(all.allSatisfy { archiveIsIntact($0.url) })
        let hidden = try FileManager.default.contentsOfDirectory(atPath: store.gameFolder(for: game).path)
            .filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test("A damaged archive fails verification")
    func verifyCatchesDamage() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let store = SaveBackupStore(root: sandbox.backups)
        let backup = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        let manifest = try #require(SaveBackupManifestReader.manifest(ofArchive: backup.url, cached: false))
        let damaged = sandbox.root.appending(path: "damaged.zip")
        let data = try Data(contentsOf: backup.url)
        try data.prefix(data.count / 2).write(to: damaged)

        #expect(throws: SaveBackupError.archiveDamaged) {
            try SaveBackupStore.verify(archive: damaged, matches: manifest)
        }
        try SaveBackupStore.verify(archive: backup.url, matches: manifest)
    }

    // A3
    @Test("A save path that became a file is kept in the safety copy and comes back")
    func safetyCopyKeepsFiles() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("old", to: folder.path + "/slot.save")
        let backup = try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, now: Date(timeIntervalSince1970: 1)
        )
        try FileManager.default.removeItem(at: sandbox.bottle.appending(path: folder.path))
        try sandbox.write("a file now", to: folder.path)

        let safety = try #require(try store.restore(
            backup, game: game, bottleURL: sandbox.bottle, confirmed: [folder], now: Date(timeIntervalSince1970: 2)
        ))
        #expect(sandbox.read(folder.path + "/slot.save") == "old")

        try store.restore(
            safety, game: game, bottleURL: sandbox.bottle, confirmed: [folder], now: Date(timeIntervalSince1970: 3)
        )
        #expect(sandbox.read(folder.path) == "a file now")
    }

    // A4
    @Test("Restore refuses another game's archive and folders not confirmed now")
    func restoreChecksIdentity() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("old", to: folder.path + "/slot.save")
        let foreign = try store.backUp(game: SaveGame(id: "other", name: "Game"), folders: [folder],
                                       bottleURL: sandbox.bottle)
        let own = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        try sandbox.write("new", to: folder.path + "/slot.save")

        #expect(throws: SaveBackupError.wrongGame) {
            try store.restore(foreign, game: game, bottleURL: sandbox.bottle, confirmed: [folder])
        }
        let elsewhere = SaveFolder(path: "drive_c/users/crossover/Documents/Other", inBottle: true)
        #expect(throws: SaveBackupError.folderNotConfirmed) {
            try store.restore(own, game: game, bottleURL: sandbox.bottle, confirmed: [elsewhere])
        }
        #expect(sandbox.read(folder.path + "/slot.save") == "new")
        #expect(store.backups(for: game).count == 1)
    }

    @Test("Restore refuses a folder a link has moved out of the bottle")
    func restoreRefusesEscapingLink() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        let fileManager = FileManager.default
        let outside = sandbox.root.appending(path: "Outside")
        try fileManager.createDirectory(at: outside.appending(path: "Game"), withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: outside.appending(path: "Game/file"))
        let profile = sandbox.bottle.appending(path: "drive_c/users/crossover")
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: profile.appending(path: "Documents"), withDestinationURL: outside)

        let backup = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        #expect(throws: SaveBackupError.outsideBottle) {
            try store.restore(backup, game: game, bottleURL: sandbox.bottle, confirmed: [folder])
        }
        #expect((try? String(contentsOf: outside.appending(path: "Game/file"), encoding: .utf8)) == "theirs")

        // Confirmed where it really is, the linked folder restores.
        let confirmed = folder.confirmingLocation(bottleURL: sandbox.bottle)
        try store.restore(backup, game: game, bottleURL: sandbox.bottle, confirmed: [confirmed])
        #expect((try? String(contentsOf: outside.appending(path: "Game/file"), encoding: .utf8)) == "theirs")
    }

    // A5
    @Test("Pruning after a restore keeps the new safety copy, and keeps three of those")
    func pruningSparesSafetyCopy() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let future = Date().addingTimeInterval(86_400 * 365)
        for step in 0 ..< 10 {
            try store.backUp(
                game: game, folders: [folder], bottleURL: sandbox.bottle, trigger: .manual,
                now: future.addingTimeInterval(Double(step))
            )
        }
        let restored = try #require(store.backups(for: game).last)

        var safeties: [URL] = []
        for step in 0 ..< 4 {
            let safety = try store.restore(
                restored, game: game, bottleURL: sandbox.bottle, confirmed: [folder],
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(step))
            )
            let url = try #require(safety?.url)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            safeties.append(url)
        }

        let all = store.backups(for: game)
        #expect(all.filter { !$0.isSafety }.count == 10)
        let kept = all.filter(\.isSafety).map(\.url.lastPathComponent)
        #expect(kept == safeties.suffix(3).reversed().map(\.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: restored.url.path(percentEncoded: false)))
    }

    @Test("The archive just made survives pruning, even into a new folder")
    func newArchiveIsProtected() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        var store = SaveBackupStore(root: sandbox.backups)
        store.keep = 0
        try sandbox.write("v1", to: folder.path + "/slot.save")

        let made = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        #expect(FileManager.default.fileExists(atPath: made.url.path(percentEncoded: false)))
    }

    // A7
    @Test("Two games with one name keep separate backups, and old name-only backups still list")
    func keyedByEntry() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let twin = SaveGame(id: "steam:/bottles/B:42", name: "Game")

        let mine = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        try store.backUp(game: twin, folders: [folder], bottleURL: sandbox.bottle)

        #expect(store.gameFolder(for: game) != store.gameFolder(for: twin))
        #expect(store.gameFolder(for: game).lastPathComponent == "Game (\(game.shortID))")
        #expect(store.backups(for: game).map(\.url.lastPathComponent) == [mine.url.lastPathComponent])

        let legacy = store.legacyFolder(forGame: "Game")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old = legacy.appending(path: "2001-01-01 00.00.00.zip")
        try FileManager.default.copyItem(at: mine.url, to: old)
        let listed = store.backups(for: game)
        #expect(listed.count == 2)
        #expect(listed.last?.isLegacy == true)
        #expect(SaveGame(id: game.id, name: "Renamed").shortID == game.shortID)
    }

    // A8
    @Test("No backup runs while the game is restoring")
    @MainActor
    func restoreGuardBlocksBackups() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let store = SaveBackupStore(root: sandbox.backups)
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let id = game.id + ":guard"
        let guarded = SaveGame(id: id, name: "Game")

        SaveRestoreGuard.begin(id)
        #expect(SaveRestoreGuard.isRestoring(id))
        #expect(throws: SaveBackupError.restoreInProgress) {
            try store.backUp(game: guarded, folders: [folder], bottleURL: sandbox.bottle)
        }
        SaveRestoreGuard.end(id)
        #expect(!SaveRestoreGuard.isRestoring(id))
        try store.backUp(game: guarded, folders: [folder], bottleURL: sandbox.bottle)
    }

    // Round 2, A1
    @Test("A game's backup folder linked into its saves is refused at backup and restore")
    func refusesLinkedGameFolder() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let fileManager = FileManager.default
        try sandbox.write("old", to: folder.path + "/slot.save")
        let backup = try SaveBackupStore(root: sandbox.root.appending(path: "Elsewhere"))
            .backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        try sandbox.write("new", to: folder.path + "/slot.save")

        let store = SaveBackupStore(root: sandbox.backups)
        let inSaves = sandbox.bottle.appending(path: folder.path).appending(path: "Backups")
        try fileManager.createDirectory(at: inSaves, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sandbox.backups, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: store.gameFolder(for: game), withDestinationURL: inSaves
        )

        #expect(store.overlapsBackups(folder, game: game, bottleURL: sandbox.bottle))
        #expect(throws: SaveBackupError.overlapsBackupLocation) {
            try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle, trigger: .manual)
        }
        let confirmed = folder.confirmingLocation(bottleURL: sandbox.bottle)
        #expect(throws: SaveBackupError.overlapsBackupLocation) {
            try store.restore(backup, game: game, bottleURL: sandbox.bottle, confirmed: [confirmed])
        }
        #expect(sandbox.read(folder.path + "/slot.save") == "new")
        #expect(try fileManager.contentsOfDirectory(atPath: inSaves.path).isEmpty)
    }

    // Round 2, A2
    @Test("A confirmed folder swapped for a link to another game's saves is refused")
    func refusesSwappedLinkInBottle() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let fileManager = FileManager.default
        let gameA = SaveFolder(path: "drive_c/Games/A/Saves", inBottle: true)
        try sandbox.write("A save", to: gameA.path + "/slot")
        try sandbox.write("B save", to: "drive_c/Games/B/Saves/slot")
        let confirmed = gameA.confirmingLocation(bottleURL: sandbox.bottle)
        let store = SaveBackupStore(root: sandbox.backups)
        let backup = try store.backUp(game: game, folders: [confirmed], bottleURL: sandbox.bottle)

        let aSaves = sandbox.bottle.appending(path: gameA.path)
        try fileManager.removeItem(at: aSaves)
        try fileManager.createSymbolicLink(
            at: aSaves, withDestinationURL: sandbox.bottle.appending(path: "drive_c/Games/B/Saves")
        )

        #expect(throws: SaveBackupError.folderMoved) {
            try store.restore(backup, game: game, bottleURL: sandbox.bottle, confirmed: [confirmed])
        }
        #expect(sandbox.read("drive_c/Games/B/Saves/slot") == "B save")
    }

    // Round 2, A3
    @Test("Nested folders keep only the outer one, and old nested archives still restore")
    func nestedFolders() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let inner = SaveFolder(path: folder.path + "/Saves", inBottle: true)
        try sandbox.write("old", to: inner.path + "/slot")
        let nesting = SaveFolderNesting.outermost([inner, folder, folder], bottleURL: sandbox.bottle)
        #expect(nesting.kept == [folder])
        #expect(nesting.dropped.count == 2)

        // Made the way the first version allowed: both folders confirmed.
        let store = SaveBackupStore(root: sandbox.backups)
        let both = try store.backUp(game: game, folders: [folder, inner], bottleURL: sandbox.bottle)
        try sandbox.write("new", to: inner.path + "/slot")
        try store.restore(both, game: game, bottleURL: sandbox.bottle, confirmed: [folder])
        #expect(sandbox.read(inner.path + "/slot") == "old")
    }

    @Test("An automatic backup is skipped when nothing changed; a manual one never is")
    func skipsUnchanged() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let status = SaveBackupStatusStore(url: sandbox.root.appending(path: "status.json"))
        let store = SaveBackupStore(root: sandbox.backups, status: status)
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle, now: start)
        let again = try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, now: start.addingTimeInterval(60)
        )
        #expect(again.url.lastPathComponent == first.url.lastPathComponent)
        #expect(store.backups(for: game).count == 1)
        #expect(status.attempt(for: game.id)?.lastBackup == start)

        try sandbox.write("v2, longer", to: folder.path + "/slot.save")
        try store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle, now: start.addingTimeInterval(120))
        try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, trigger: .manual,
            now: start.addingTimeInterval(180)
        )
        let kinds = store.backups(for: game).map(\.kind)
        #expect(kinds == [.manual, .automatic, .automatic])
    }

    @Test("Automatic, manual and safety backups are pruned only among their own kind")
    func separatePools() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        var store = SaveBackupStore(root: sandbox.backups)
        store.keep = 2
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0 ..< 3 {
            try sandbox.write("auto \(step)", to: folder.path + "/slot.save")
            try store.backUp(
                game: game, folders: [folder], bottleURL: sandbox.bottle, now: start.addingTimeInterval(Double(step))
            )
        }
        for step in 3 ..< 6 {
            try store.backUp(
                game: game, folders: [folder], bottleURL: sandbox.bottle, trigger: .manual,
                now: start.addingTimeInterval(Double(step))
            )
        }
        let all = store.backups(for: game)
        #expect(all.filter { $0.kind == .automatic }.count == 2)
        #expect(all.filter { $0.kind == .manual }.count == 2)
    }

    @Test("The first archives' kind reads as automatic")
    func oldKindDecodes() throws {
        let json = #"{"format":1,"created":"2026-10-01T10:00:00Z","game":"Game","kind":"regular","folders":[]}"#
        let manifest = try #require(SaveBackupManifest.decode(Data(json.utf8)))
        #expect(manifest.kind == .automatic)
    }

    @Test("The overview says whether backups are on, when the last one was and whether it failed")
    func overview() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let folders = SaveFolderStore(url: sandbox.root.appending(path: "folders.json"))
        let status = SaveBackupStatusStore(url: sandbox.root.appending(path: "status.json"))
        let store = SaveBackupStore(root: sandbox.backups, status: status)
        func overview() -> SaveBackupOverview {
            SaveBackupOverviews.overview(for: game.id, folders: folders, status: status, backups: store)
        }
        #expect(overview() == SaveBackupOverview(configured: false, lastBackup: nil, lastAttemptFailed: false))

        folders.setFolders([folder], for: game.id, bottleURL: sandbox.bottle)
        try sandbox.write("v1", to: folder.path + "/slot.save")
        let made = try store.backUp(
            game: game, folders: [folder], bottleURL: sandbox.bottle, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(overview() == SaveBackupOverview(configured: true, lastBackup: made.created, lastAttemptFailed: false))

        try FileManager.default.removeItem(at: sandbox.bottle.appending(path: folder.path))
        _ = try? store.backUp(game: game, folders: [folder], bottleURL: sandbox.bottle)
        #expect(overview() == SaveBackupOverview(configured: true, lastBackup: made.created, lastAttemptFailed: true))
    }

    @Test("A failed swap puts every folder back")
    func swapRollsBack() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("current A", to: "a/file")
        try sandbox.write("current B", to: "b/file")
        try sandbox.write("restored A", to: "restored/a/file")
        try sandbox.write("restored B", to: "restored/b/file")
        let bottle = sandbox.bottle

        var moves = 0
        let failing: (URL, URL) throws -> Void = { source, target in
            moves += 1
            // a: aside, a: in place, b: aside, then the fourth move fails.
            if moves == 4 { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: source, to: target)
        }

        #expect(throws: CocoaError.self) {
            try SaveFolderSwap.swap(
                [
                    (bottle.appending(path: "restored/a"), bottle.appending(path: "a")),
                    (bottle.appending(path: "restored/b"), bottle.appending(path: "b"))
                ],
                move: failing
            )
        }

        #expect(sandbox.read("a/file") == "current A")
        #expect(sandbox.read("b/file") == "current B")
        let names = try FileManager.default.contentsOfDirectory(atPath: bottle.path).sorted()
        #expect(names == ["a", "b", "restored"])
    }

    @Test("A swap replaces folders and removes the old copies")
    func swapSucceeds() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try sandbox.write("current", to: "a/file")
        try sandbox.write("restored", to: "restored/a/file")
        let bottle = sandbox.bottle

        try SaveFolderSwap.swap([(bottle.appending(path: "restored/a"), bottle.appending(path: "a"))])

        #expect(sandbox.read("a/file") == "restored")
        let names = try FileManager.default.contentsOfDirectory(atPath: bottle.path).sorted()
        #expect(names == ["a", "restored"])
    }
}
