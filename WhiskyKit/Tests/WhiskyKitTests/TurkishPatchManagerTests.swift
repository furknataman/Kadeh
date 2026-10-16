//
//  TurkishPatchManagerTests.swift
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
import XCTest
@testable import WhiskyKit

final class TurkishPatchManagerTests: XCTestCase {
    private var root: URL!
    private var bottle: URL!
    private var game: URL!
    private var downloads: URL!
    private let installerNFC = "T\u{00FC}rk\u{00E7}e/Kur.exe"
    private let installerNFD = "Tu\u{0308}rkc\u{0327}e/Kur.exe"

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent("yama-\(UUID().uuidString)")
        bottle = root.appendingPathComponent("Bottle")
        game = bottle.appendingPathComponent("drive_c/Steam/common/Marvel's Game")
        downloads = root.appendingPathComponent("Downloads")
        try fileManager.createDirectory(at: game, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func write(_ text: String, to relative: String, in base: URL) throws {
        try write(Data(text.utf8), to: relative, in: base)
    }

    private func write(_ data: Data, to relative: String, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: game.appendingPathComponent(relative))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Builds a zip whose single entry is the NFD-named installer; returns the archive and its catalog file entry.
    private func makeArchive(named name: String = "yama.zip") throws -> (URL, TurkishPatch.File) {
        let content = root.appendingPathComponent("content")
        try? FileManager.default.removeItem(at: content)
        try write("installer-bytes", to: installerNFD, in: content)
        let archive = downloads.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-a", "-cf", archive.path, "-C", content.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        let file = TurkishPatch.File(name: name, size: size, sha256: try TurkishPatchManager.sha256(of: archive))
        return (archive, file)
    }

    private func makePatch(
        file: TurkishPatch.File,
        modified: [String] = ["data/main.bin"],
        added: [String] = ["data/tr.pak"],
        fixup: TurkishPatch.Fixup? = nil
    ) -> TurkishPatch {
        TurkishPatch(
            id: "test-patch",
            source: "example.com",
            pageURL: URL(string: "https://example.com/yama")!,
            access: .free,
            file: file,
            installer: installerNFC,
            modifiedFiles: modified,
            addedFiles: added,
            fixup: fixup
        )
    }

    private func simulateInstaller(modified: String = "data/main.bin", added: Bool = true) throws {
        try write("patched", to: modified, in: game)
        if added { try write("turkish", to: "data/tr.pak", in: game) }
    }

    // MARK: Tests

    func testFindDownloadIgnoresName() throws {
        let (archive, file) = try makeArchive()
        let renamed = downloads.appendingPathComponent("foo (1).zip")
        try FileManager.default.moveItem(at: archive, to: renamed)
        // Same size, different content: must not match.
        try write(Data(repeating: 7, count: Int(file.size)), to: "decoy.zip", in: downloads)
        XCTAssertEqual(
            TurkishPatchManager.findDownload(file, in: downloads)?.lastPathComponent, "foo (1).zip"
        )
        try FileManager.default.removeItem(at: renamed)
        XCTAssertNil(TurkishPatchManager.findDownload(file, in: downloads))
    }

    func testStageRejectsHashMismatch() throws {
        let (archive, file) = try makeArchive()
        let bad = TurkishPatch.File(name: file.name, size: file.size, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(
            try TurkishPatchManager.stage(makePatch(file: bad), archive: archive, gameURL: game, bottleURL: bottle)
        ) { error in
            guard case TurkishPatchError.hashMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func testStageCopiesInstallerToAsciiName() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        let exe = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        XCTAssertEqual(exe.lastPathComponent, "Kurulum.exe")
        XCTAssertEqual(exe.deletingLastPathComponent(), TurkishPatchManager.stagingURL(bottleURL: bottle, patch: patch))
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "installer-bytes")
        let backup = game.appendingPathComponent(".kadeh-yama/test-patch/backup/data/main.bin")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
    }

    func testStageReportsMissingInstaller() throws {
        let (archive, file) = try makeArchive()
        let patch = TurkishPatch(
            id: "x", source: "s", pageURL: URL(string: "https://example.com")!, access: .free,
            file: file, installer: "yok/Kur.exe"
        )
        XCTAssertThrowsError(try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)) {
            XCTAssertEqual($0 as? TurkishPatchError, .installerMissing("yok/Kur.exe"))
        }
    }

    func testInstallUninstallRoundTrip() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        XCTAssertEqual(TurkishPatchManager.status(of: patch, gameURL: game), .notInstalled)
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller()
        try TurkishPatchManager.finish(patch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        XCTAssertEqual(TurkishPatchManager.status(of: patch, gameURL: game), .installed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TurkishPatchManager.stagingURL(bottleURL: bottle, patch: patch).path
        ))
        try TurkishPatchManager.uninstall(patch, gameURL: game)
        XCTAssertEqual(read("data/main.bin"), "original")
        XCTAssertNil(read("data/tr.pak"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent(".kadeh-yama/test-patch").path))
        XCTAssertEqual(TurkishPatchManager.status(of: patch, gameURL: game), .notInstalled)
    }

    func testStageRefusesWhenInstalled() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller()
        try TurkishPatchManager.finish(patch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        XCTAssertThrowsError(
            try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        ) {
            XCTAssertEqual($0 as? TurkishPatchError, .alreadyInstalled)
        }
        try TurkishPatchManager.uninstall(patch, gameURL: game)
        XCTAssertEqual(read("data/main.bin"), "original")
    }

    /// The installer ran but the user never pressed "Yükleyici bitti": staging
    /// again must not back up the files the installer already overwrote.
    func testRestageKeepsUnfinishedBackup() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller()
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller()
        try TurkishPatchManager.finish(patch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        try TurkishPatchManager.uninstall(patch, gameURL: game)
        XCTAssertEqual(read("data/main.bin"), "original")
    }

    func testFinishRollsBackWhenAddedFilesMissing() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller(added: false)
        XCTAssertThrowsError(
            try TurkishPatchManager.finish(patch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        ) {
            XCTAssertEqual($0 as? TurkishPatchError, .addedFilesMissing(["data/tr.pak"]))
        }
        XCTAssertEqual(read("data/main.bin"), "original")
        XCTAssertEqual(TurkishPatchManager.status(of: patch, gameURL: game), .notInstalled)
    }

    func testFinishRollsBackWhenFixupFails() throws {
        let (archive, file) = try makeArchive()
        try write("original-toc", to: "data/main.bin", in: game)
        let patch = makePatch(file: file, fixup: .spiderManTocMerge)
        let tocPatch = TurkishPatch(
            id: patch.id, source: patch.source, pageURL: patch.pageURL, access: .free, file: file,
            installer: installerNFC, modifiedFiles: ["asset_archive/toc"], addedFiles: ["data/tr.pak"],
            fixup: .spiderManTocMerge
        )
        try write("original-toc", to: "asset_archive/toc", in: game)
        _ = try TurkishPatchManager.stage(tocPatch, archive: archive, gameURL: game, bottleURL: bottle)
        try write("garbage-toc", to: "asset_archive/toc", in: game)
        try write("turkish", to: "data/tr.pak", in: game)
        XCTAssertThrowsError(
            try TurkishPatchManager.finish(tocPatch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        ) { error in
            guard case TurkishPatchError.fixupFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(read("asset_archive/toc"), "original-toc")
        XCTAssertNil(read("data/tr.pak"))
    }

    func testUninstallAfterGameUpdateKeepsNewToc() throws {
        let (archive, file) = try makeArchive()
        try write("original", to: "data/main.bin", in: game)
        let patch = makePatch(file: file)
        _ = try TurkishPatchManager.stage(patch, archive: archive, gameURL: game, bottleURL: bottle)
        try simulateInstaller()
        try TurkishPatchManager.finish(patch, gameURL: game, bottleURL: bottle, fileSHA256: file.sha256)
        try write("steam-update", to: "data/main.bin", in: game)
        XCTAssertEqual(TurkishPatchManager.status(of: patch, gameURL: game), .gameUpdated)
        try TurkishPatchManager.uninstall(patch, gameURL: game)
        XCTAssertEqual(read("data/main.bin"), "steam-update")
        XCTAssertNil(read("data/tr.pak"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent(".kadeh-yama/test-patch").path))
    }

    func testWindowsPath() {
        let url = bottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Marvel's X"
        )
        XCTAssertEqual(
            TurkishPatchManager.windowsPath(of: url, bottleURL: bottle),
            "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Marvel's X"
        )
    }
}
