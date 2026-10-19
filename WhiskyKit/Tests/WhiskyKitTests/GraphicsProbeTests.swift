//
//  GraphicsProbeTests.swift
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

final class GraphicsProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "graphics_probe_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ text: String, padding: Int = 0, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data(count: padding) + Data(text.utf8) + Data(count: 16)).write(to: url)
        return url
    }

    func testScanFindsHighestLevelIgnoringCase() throws {
        let exe = try write("a.exe", "xx D3D11.DLL yy d3d9.dll zz d3d12.dll")
        XCTAssertEqual(GraphicsProbe.scan(fileAt: exe), .dx12)
        XCTAssertEqual(GraphicsProbe.scan(fileAt: try write("b.exe", "D3D11.dll and D3d9.dll")), .dx11)
        XCTAssertEqual(GraphicsProbe.scan(fileAt: try write("c.exe", "d3d10_1.dll")), .dx10)
        XCTAssertEqual(GraphicsProbe.scan(fileAt: try write("d.exe", "D3D9.DLL")), .dx9)
        XCTAssertEqual(GraphicsProbe.scan(fileAt: try write("e.exe", "D3D12CreateDevice")), .dx12)
        XCTAssertNil(GraphicsProbe.scan(fileAt: try write("f.exe", "nothing here")))
    }

    func testScanFindsNameSplitAcrossChunks() throws {
        // Put the name so it straddles the 4 MiB read boundary.
        let exe = try write("big.exe", "d3d12.dll", padding: 4 * 1024 * 1024 - 4)
        XCTAssertEqual(GraphicsProbe.scan(fileAt: exe), .dx12)
    }

    func testScanOfMissingFileIsNil() {
        XCTAssertNil(GraphicsProbe.scan(fileAt: dir.appending(path: "missing.exe")))
    }

    func testProgramEntryUsesFolderHints() async throws {
        let exe = try write("game/game.exe", "d3d11.dll")
        let entry = entry(for: exe)
        let plain = await GraphicsProbe.directX(for: entry)
        XCTAssertEqual(plain, .dx11)

        try write("game/D3D12Core.dll", "x")
        let withAgility = await GraphicsProbe.directX(for: entry)
        XCTAssertEqual(withAgility, .dx12)
    }

    func testLauncherEntryIsUnknown() async throws {
        let exe = try write("steam.exe", "d3d12.dll")
        let launcher = LibraryEntry(
            id: "x", name: "Steam", iconURL: nil, bottleURL: dir, source: .pinned,
            launch: .program(exe), launcher: .steam
        )
        let level = await GraphicsProbe.directX(for: launcher)
        XCTAssertNil(level)
    }

    func testMainExecutablesSkipsHelpersAndRedist() throws {
        let install = dir.appending(path: "install")
        try write("Game.exe", "d3d12.dll", padding: 300_000, in: install)
        try write("UnityCrashHandler64.exe", "x", padding: 300_000, in: install)
        try write("Launcher.exe", "x", padding: 300_000, in: install)
        try write("tiny.exe", "x", in: install)
        try write("_CommonRedist/vc_redist.exe", "x", padding: 300_000, in: install)
        try write("Binaries/Win64/Game-Win64.exe", "d3d11.dll", padding: 600_000, in: install)

        let names = GraphicsProbe.mainExecutables(under: install).map(\.lastPathComponent)
        XCTAssertEqual(names, ["Game-Win64.exe", "Game.exe"])
        let preferred = GraphicsProbe.mainExecutables(under: install, preferring: ["game.exe"]).map(\.lastPathComponent)
        XCTAssertEqual(preferred, ["Game.exe"])
    }

    func testWarningDecision() {
        XCTAssertNotNil(GraphicsProbe.dx12Warning(level: .dx12, backend: .dxmt))
        XCTAssertNotNil(GraphicsProbe.dx12Warning(level: .dx12, backend: .dxvk))
        XCTAssertNotNil(GraphicsProbe.dx12Warning(level: .dx12, backend: .wined3d))
        XCTAssertNil(GraphicsProbe.dx12Warning(level: .dx12, backend: .d3dMetal))
        XCTAssertNil(GraphicsProbe.dx12Warning(level: .dx11, backend: .dxmt))
        XCTAssertNil(GraphicsProbe.dx12Warning(level: nil, backend: .dxmt))
    }

    private func entry(for exe: URL) -> LibraryEntry {
        LibraryEntry(
            id: exe.path, name: "Game", iconURL: nil, bottleURL: dir, source: .pinned, launch: .program(exe)
        )
    }
}
