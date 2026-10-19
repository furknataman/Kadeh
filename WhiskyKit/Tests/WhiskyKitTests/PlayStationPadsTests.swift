//
//  PlayStationPadsTests.swift
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

import Foundation
import XCTest
@testable import WhiskyKit

final class PlayStationPadsTests: XCTestCase {
    private var bottleURL: URL!

    override func setUpWithError() throws {
        bottleURL = FileManager.default.temporaryDirectory.appending(path: "ps_pads_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bottleURL)
    }

    private func writeSystemReg(disableHidraw: Bool, sdlOffLeftovers: Bool = false) throws {
        var text = "WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n"
        text += "[System\\\\ControlSet001\\\\Services\\\\winebus] 1760000000\n#time=1dc0000000000000\n"
        text += sdlOffLeftovers
            ? "\"DisableInput\"=dword:00000001\n\"Enable SDL\"=dword:00000000\n"
            : "\"Enable SDL\"=dword:00000001\n"
        if disableHidraw { text += "\"DisableHidraw\"=dword:00000001\n" }
        try text.write(to: bottleURL.appending(path: "system.reg"), atomically: true, encoding: .utf8)
    }

    func testDocumentWhenOn() {
        XCTAssertEqual(WinePlayStationPads.registryDocument(enabled: true), [
            "Windows Registry Editor Version 5.00", "",
            #"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\winebus]"#,
            "\"DisableHidraw\"=dword:00000001", ""
        ].joined(separator: "\r\n"))
    }

    func testDocumentWhenOffRemovesValue() {
        let document = WinePlayStationPads.registryDocument(enabled: false)
        XCTAssertTrue(document.contains("\"DisableHidraw\"=-"))
        XCTAssertFalse(document.contains("dword"))
    }

    func testNoSyncWithoutSystemReg() {
        XCTAssertFalse(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: true, bottleURL: bottleURL))
    }

    func testOnSyncsOnlyWhenMissing() throws {
        try writeSystemReg(disableHidraw: false)
        XCTAssertTrue(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: true, bottleURL: bottleURL))
        try writeSystemReg(disableHidraw: true)
        XCTAssertFalse(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: true, bottleURL: bottleURL))
    }

    func testOffSyncsOnlyWhenPresent() throws {
        try writeSystemReg(disableHidraw: true)
        XCTAssertTrue(WinePlayStationPads.needsSync(enabled: false, runtimeHasSDL: true, bottleURL: bottleURL))
        try writeSystemReg(disableHidraw: false)
        XCTAssertFalse(WinePlayStationPads.needsSync(enabled: false, runtimeHasSDL: true, bottleURL: bottleURL))
    }

    func testNoSDLNeverWritesAndCleansUp() throws {
        try writeSystemReg(disableHidraw: true)
        XCTAssertTrue(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: false, bottleURL: bottleURL))
        try writeSystemReg(disableHidraw: false)
        XCTAssertFalse(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: false, bottleURL: bottleURL))
    }

    func testOnRemovesSDLOffLeftovers() throws {
        try writeSystemReg(disableHidraw: true, sdlOffLeftovers: true)
        XCTAssertTrue(WinePlayStationPads.hasLeftovers(bottleURL: bottleURL))
        // DisableHidraw is already set, but with SDL off as well the pad vanishes.
        XCTAssertTrue(WinePlayStationPads.needsSync(enabled: true, runtimeHasSDL: true, bottleURL: bottleURL))
        let document = WinePlayStationPads.registryDocument(enabled: true, removingLeftovers: true)
        XCTAssertTrue(document.contains("\"DisableHidraw\"=dword:00000001"))
        XCTAssertTrue(document.contains("\"Enable SDL\"=-"))
        XCTAssertTrue(document.contains("\"DisableInput\"=-"))
    }

    func testOffLeavesSDLOffLeftoversAlone() throws {
        try writeSystemReg(disableHidraw: false, sdlOffLeftovers: true)
        XCTAssertFalse(WinePlayStationPads.needsSync(enabled: false, runtimeHasSDL: true, bottleURL: bottleURL))
        let document = WinePlayStationPads.registryDocument(enabled: false, removingLeftovers: true)
        XCTAssertFalse(document.contains("Enable SDL"))
        XCTAssertFalse(document.contains("DisableInput"))
    }

    func testSDLDetectionInBothLayouts() throws {
        let library = bottleURL.appending(path: "Libraries")
        XCTAssertFalse(WineControllerBus.runtimeHasSDL(libraryFolder: library))
        XCTAssertFalse(WineControllerBus.runtimeLacksSDL(libraryFolder: library))

        let wineLib = library.appending(path: "Wine/lib")
        try FileManager.default.createDirectory(at: wineLib, withIntermediateDirectories: true)
        XCTAssertTrue(WineControllerBus.runtimeLacksSDL(libraryFolder: library))
        XCTAssertFalse(WineControllerBus.runtimeHasSDL(libraryFolder: library))
        FileManager.default.createFile(atPath: wineLib.appending(path: "libSDL2-2.0.0.dylib").path, contents: Data())
        XCTAssertTrue(WineControllerBus.runtimeHasSDL(libraryFolder: library))

        let overlay = bottleURL.appending(path: "Overlay")
        try FileManager.default.createDirectory(
            at: overlay.appending(path: "frameworks"), withIntermediateDirectories: true
        )
        XCTAssertTrue(WineControllerBus.runtimeLacksSDL(libraryFolder: overlay))
        FileManager.default.createFile(
            atPath: overlay.appending(path: "frameworks/libSDL2-2.0.0.dylib").path, contents: Data()
        )
        XCTAssertTrue(WineControllerBus.runtimeHasSDL(libraryFolder: overlay))
    }

    func testSettingDefaultsOffAndOldFilesDecode() throws {
        XCTAssertFalse(BottleInputConfig().playStationAsXbox)
        let data = try PropertyListEncoder().encode([String: String]())
        XCTAssertFalse(try PropertyListDecoder().decode(BottleInputConfig.self, from: data).playStationAsXbox)
    }
}
