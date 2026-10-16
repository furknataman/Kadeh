//
//  WineControllerBusTests.swift
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
import Testing
@testable import WhiskyKit

/// Covers when ``Wine/syncControllerBus(bottle:runtimeLacksSDL:importer:)`` writes winebus's options.
/// The `reg import` itself is not run, same policy as the CJK font sync.
@Suite("Wine Controller Bus Tests")
struct WineControllerBusTests {
    /// The winebus key as Wine saves it, under the link's target.
    private static func systemReg(values: String = "") -> String {
        #"""
        WINE REGISTRY Version 2
        ;; All keys relative to \\Machine

        [System\\ControlSet001\\Services\\winebus] 1792006964
        #time=1dd5c142f07634e
        "Description"="Wine HID bus driver"
        "Start"=dword:00000003
        """# + values + #"""

        [System\\ControlSet001\\Services\\winebus\\Enum] 1792006964
        "Enable SDL"=dword:00000001

        """#
    }

    private func makeBottle(systemReg: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "controller-bus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let systemReg {
            try systemReg.write(to: url.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test("A runtime without SDL needs the options in a fresh prefix")
    func noSDLNeedsOptions() throws {
        let bottle = try makeBottle(systemReg: Self.systemReg())
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(WineControllerBus.needsOptions(runtimeLacksSDL: true, bottleURL: bottle))
    }

    @Test("A runtime with SDL keeps its SDL bus")
    func sdlRuntimeIsLeftAlone() throws {
        let bottle = try makeBottle(systemReg: Self.systemReg())
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!WineControllerBus.needsOptions(runtimeLacksSDL: false, bottleURL: bottle))
    }

    @Test("Nothing to do once both values are saved")
    func nothingOnceSaved() throws {
        let values = "\n\"DisableInput\"=dword:00000001\n\"Enable SDL\"=dword:00000000"
        let bottle = try makeBottle(systemReg: Self.systemReg(values: values))
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!WineControllerBus.needsOptions(runtimeLacksSDL: true, bottleURL: bottle))
    }

    @Test("Waits for a prefix that has no system.reg yet")
    func waitsForThePrefix() throws {
        let bottle = try makeBottle(systemReg: nil)
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!WineControllerBus.needsOptions(runtimeLacksSDL: true, bottleURL: bottle))
    }

    @Test("Looks for SDL in the runtime's Wine/lib, and leaves other layouts alone")
    func findsRuntimeSDL() throws {
        let libraries = try makeBottle(systemReg: nil)
        defer { try? FileManager.default.removeItem(at: libraries) }
        #expect(!WineControllerBus.runtimeLacksSDL(libraryFolder: libraries))
        let lib = libraries.appending(path: "Wine/lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        #expect(WineControllerBus.runtimeLacksSDL(libraryFolder: libraries))
        try Data().write(to: lib.appending(path: "libSDL2-2.0.0.dylib"))
        #expect(!WineControllerBus.runtimeLacksSDL(libraryFolder: libraries))
    }

    @Test("Imports SDL off and input off under the CurrentControlSet link")
    @MainActor
    func importsBothValues() async throws {
        let url = try makeBottle(systemReg: Self.systemReg())
        defer { try? FileManager.default.removeItem(at: url) }
        var documents: [String] = []
        await Wine.syncControllerBus(bottle: Bottle(bottleUrl: url), runtimeLacksSDL: true) { document, _ in
            documents.append(document)
        }
        #expect(documents == [
            "Windows Registry Editor Version 5.00\r\n\r\n"
                + #"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\winebus]"# + "\r\n"
                + "\"Enable SDL\"=dword:00000000\r\n\"DisableInput\"=dword:00000001\r\n"
        ])
    }
}
