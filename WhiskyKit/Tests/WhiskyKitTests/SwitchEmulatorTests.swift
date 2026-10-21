//
//  SwitchEmulatorTests.swift
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

/// Every test works in a fresh temporary folder, never in Kadeh's own `Switch/`.
final class SwitchEmulatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "kadeh-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ text: String, to relative: String, in folder: URL) throws {
        let url = folder.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func assertNotFirmware(_ source: URL, to registered: URL, file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertThrowsError(try SwitchEmulator.copyFirmware(ncaFilesIn: source, to: registered),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? SwitchEmulator.SetupError, .notFirmware, file: file, line: line)
        }
    }

    func testKeysFileNeedsHeaderKey() {
        let key = String(repeating: "a", count: 64)
        XCTAssertTrue(SwitchEmulator.isKeysFile("header_key = " + key))
        XCTAssertTrue(SwitchEmulator.isKeysFile(
            "aes_kek_generation_source = 00\r\n  header_key=\(key)  \r\nkey_area_key_application_00 = 11\r\n"
        ))
        XCTAssertTrue(SwitchEmulator.isKeysFile("master_key_00 = 22\nheader_key = \(key.uppercased())\n"))
        XCTAssertFalse(SwitchEmulator.isKeysFile("header_key = abc"))
        XCTAssertFalse(SwitchEmulator.isKeysFile("header_key = \(key)a"))
        XCTAssertFalse(SwitchEmulator.isKeysFile(""))
    }

    func testFirmwareCopyLayout() throws {
        let source = root.appending(path: "Firmware 19.0.1")
        for index in 0 ..< 51 {
            // Some nested one folder deeper, as a zip often has them.
            let relative = index % 5 == 0 ? "nested/a\(index).nca" : "a\(index).nca"
            try write("content \(index)", to: relative, in: source)
        }
        try write("meta", to: "nested/meta.cnmt.nca", in: source)
        let registered = root.appending(path: "bis/system/Contents/registered")

        try SwitchEmulator.copyFirmware(ncaFilesIn: source, to: registered)

        XCTAssertEqual(read(registered.appending(path: "a0.nca/00")), "content 0")
        XCTAssertEqual(read(registered.appending(path: "a7.nca/00")), "content 7")
        XCTAssertEqual(read(registered.appending(path: "meta.nca/00")), "meta")
        let slots = try FileManager.default.contentsOfDirectory(atPath: registered.path(percentEncoded: false))
        XCTAssertEqual(slots.count, 52)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: registered.deletingLastPathComponent().path(percentEncoded: false)
        )
        XCTAssertEqual(siblings, ["registered"])
    }

    func testFirmwareRejectsTooFew() throws {
        let registered = root.appending(path: "registered")

        let few = root.appending(path: "few")
        for index in 0 ..< 9 {
            try write("x", to: "a\(index).nca", in: few)
        }
        try write("meta", to: "meta.cnmt.nca", in: few)
        assertNotFirmware(few, to: registered)

        let noMeta = root.appending(path: "noMeta")
        for index in 0 ..< 60 {
            try write("x", to: "a\(index).nca", in: noMeta)
        }
        assertNotFirmware(noMeta, to: registered)

        XCTAssertFalse(FileManager.default.fileExists(atPath: registered.path(percentEncoded: false)))
    }

    func testFirmwareReplacesOnlyOnSuccess() throws {
        let registered = root.appending(path: "registered")
        try write("old", to: "old.nca/00", in: registered)

        let broken = root.appending(path: "broken")
        for index in 0 ..< 60 {
            try write("x", to: "a\(index).nca", in: broken)
        }
        assertNotFirmware(broken, to: registered)

        XCTAssertEqual(read(registered.appending(path: "old.nca/00")), "old")
    }
}
