//
//  SwitchLibrarySourceTests.swift
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
@testable import WhiskyKit
import XCTest

final class SwitchLibrarySourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "kadeh-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A path both sides agree on: the scan reports the temporary folder as
    /// `/private/var/...`, while it is built here as `/var/...`.
    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testTitleFromFileName() {
        XCTAssertEqual(
            SwitchLibrarySource.title(fromFileName: "Super Mario Odyssey [0100000000010000][v0].nsp"),
            "Super Mario Odyssey"
        )
        XCTAssertEqual(SwitchLibrarySource.title(fromFileName: "Zelda_Tears (USA).xci"), "Zelda Tears")
        XCTAssertEqual(SwitchLibrarySource.title(fromFileName: "Game.nsp"), "Game")
    }

    func testUpdatesAndDLCHidden() {
        XCTAssertFalse(SwitchLibrarySource.isBaseGame(fileName: "X [0100000000010800][v65536].nsp"))
        XCTAssertFalse(SwitchLibrarySource.isBaseGame(fileName: "X [DLC].nsp"))
        XCTAssertFalse(SwitchLibrarySource.isBaseGame(fileName: "X [UPD].nsp"))
        XCTAssertFalse(SwitchLibrarySource.isBaseGame(fileName: "X [0100000000011001].nsp"))
        XCTAssertTrue(SwitchLibrarySource.isBaseGame(fileName: "X [0100000000010000].nsp"))
        XCTAssertTrue(SwitchLibrarySource.isBaseGame(fileName: "Zelda.nsp"))
    }

    func testEntriesScanFolder() throws {
        let games = root.appending(path: "Games")
        let covers = root.appending(path: "covers")
        for name in ["A.nsp", "sub/B.xci", "C.txt", ".hidden.nsp", "U [0100000000010800].nsp"] {
            let url = games.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("game".utf8).write(to: url)
        }

        let entries = SwitchLibrarySource.entries(in: games, covers: covers)

        let expected = [games.appending(path: "A.nsp"), games.appending(path: "sub/B.xci")]
        XCTAssertEqual(entries.map(\.name), ["A", "B"])
        for (entry, url) in zip(entries, expected) {
            guard case let .switchGame(game) = entry.launch else {
                return XCTFail("\(entry.name) is not launched as a Switch game")
            }
            XCTAssertEqual(resolved(game), resolved(url))
            XCTAssertEqual(entry.id, "switch:" + game.path(percentEncoded: false))
            XCTAssertEqual(entry.source, .nintendoSwitch)
            XCTAssertEqual(entry.bottleURL, SwitchEmulator.dataFolder)
            // Covers go where they were asked to, never into Kadeh's own folder.
            let art = try XCTUnwrap(entry.artworkURL)
            XCTAssertTrue(art.path(percentEncoded: false).hasPrefix(covers.path(percentEncoded: false)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: art.path(percentEncoded: false)))
        }
    }

    func testMissingFolderIsEmpty() {
        let entries = SwitchLibrarySource.entries(
            in: root.appending(path: "nowhere"), covers: root.appending(path: "covers")
        )
        XCTAssertEqual(entries, [])
    }
}
