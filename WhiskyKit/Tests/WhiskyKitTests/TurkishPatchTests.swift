//
//  TurkishPatchTests.swift
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

final class TurkishPatchTests: XCTestCase {
    func testSpiderManCatalogEntry() throws {
        let patches = try XCTUnwrap(
            GameDBLoader.loadDefaults().first { $0.steamAppId == 1_817_070 }?.turkishPatches
        )
        XCTAssertEqual(patches.count, 3)
        let first = patches[0]
        XCTAssertEqual(first.id, "turkceyama-calypso")
        XCTAssertTrue(first.isInstallable)
        XCTAssertEqual(first.file?.size, 14_357_728)
        XCTAssertEqual(first.file?.sha256, "a30611ad9acc9de1b6567f50378fb8cccbe66f5f1e56ea3e34bf1962386c09b3")
        XCTAssertEqual(first.modifiedFiles, ["asset_archive/toc"])
        XCTAssertEqual(first.addedFiles, [
            "asset_archive/calypso.SMTR",
            "SpidermanRemastered_YamaKaldır.exe"
        ])
        XCTAssertEqual(first.fixup, .spiderManTocMerge)
        XCTAssertFalse(patches[1].isInstallable)
        XCTAssertFalse(patches[2].isInstallable)
    }

    func testMinimalPatchDecodes() throws {
        let json = #"{"id":"x","source":"s","pageURL":"https://e.com","access":"paid"}"#
        let patch = try JSONDecoder().decode(TurkishPatch.self, from: Data(json.utf8))
        XCTAssertEqual(patch.modifiedFiles, [])
        XCTAssertEqual(patch.addedFiles, [])
        XCTAssertFalse(patch.isInstallable)
    }
}
