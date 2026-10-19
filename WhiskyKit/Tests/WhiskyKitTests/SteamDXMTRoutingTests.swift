//
//  SteamDXMTRoutingTests.swift
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

/// A Steam game the GameDB puts on DXMT, in a bottle whose system32 holds
/// Steam's DXVK: any launch in the bottle places DXMT next to the game and
/// writes the game's entry, so Steam's own Play button starts it on DXMT.
@Suite("Steam DXMT routing")
@MainActor
final class SteamDXMTRoutingTests {
    private let tempRoot: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory.appending(path: "steam_dxmt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func entry(_ appId: Int, _ exe: String, _ backend: GraphicsBackend) -> GameDBEntry {
        GameDBEntry(
            id: exe, title: exe, steamAppId: appId, rating: .unverified, exeNames: [exe],
            variants: [GameConfigVariant(
                id: "recommended", label: "Recommended", isDefault: true,
                settings: GameConfigVariantSettings(graphicsBackend: backend)
            )]
        )
    }

    /// A bottle with Steam and two installed games, Trine 4 (690640) and
    /// Modern (1), and a DXMT payload whose files carry `tag`.
    private struct Fixture {
        let bottle: Bottle
        let driveC: URL
        let steamApps: URL
        let payload: URL

        var gameFolder: URL { steamApps.appending(path: "common/Trine 4") }
    }

    private func makeFixture() throws -> Fixture {
        let bottleURL = tempRoot.appending(path: "Bottle")
        let driveC = bottleURL.appending(path: "drive_c")
        let steamApps = driveC.appending(path: "Program Files (x86)/Steam/steamapps")
        try write(Data("MZ".utf8), to: driveC.appending(path: "Program Files (x86)/Steam/steam.exe"))
        try FileManager.default.createDirectory(
            at: driveC.appending(path: "windows/system32"), withIntermediateDirectories: true
        )
        for (appId, folder, exe) in [(690_640, "Trine 4", "trine4_game.exe"), (1, "Modern", "modern.exe")] {
            try write(Data("MZ".utf8), to: steamApps.appending(path: "common/\(folder)/\(exe)"))
            let manifest = "\"AppState\"\n{\n\"appid\" \"\(appId)\"\n\"name\" \"\(folder)\"\n"
                + "\"installdir\" \"\(folder)\"\n\"StateFlags\" \"4\"\n}\n"
            try write(Data(manifest.utf8), to: steamApps.appending(path: "appmanifest_\(appId).acf"))
        }
        let fixture = Fixture(
            bottle: Bottle(bottleUrl: bottleURL), driveC: driveC, steamApps: steamApps,
            payload: tempRoot.appending(path: "DXMT")
        )
        try writePayload(at: fixture.payload, tag: "v1")
        return fixture
    }

    private func writePayload(at payload: URL, tag: String) throws {
        for arch in ["x64", "x32"] {
            for name in ["d3d11.dll", "dxgi.dll", "d3d10core.dll"] {
                let native = Data(count: 0x40) + Data("dxmt-\(tag)-\(arch)-\(name)".utf8) + Data(count: 16)
                try write(native, to: payload.appending(path: "\(arch)/\(name)"))
            }
            try write(
                Data(count: 0x40) + Data("Wine builtin DLL".utf8), to: payload.appending(path: "\(arch)/winemetal.dll")
            )
        }
    }

    /// A tool launch in the fixture's bottle with Trine 4 on `trine4`.
    private func applyOverrides(_ fixture: Fixture, trine4: GraphicsBackend) async throws -> ScopeRecorder {
        let recorder = ScopeRecorder()
        var environment: [String: String] = [:]
        try await Wine.applyDLLOverrides(
            for: fixture.driveC.appending(path: "tool.exe"), bottle: fixture.bottle, wineEnvironment: &environment,
            applyToDescendants: false, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: true,
            gameDB: [entry(690_640, "trine4_game.exe", trine4), entry(1, "modern.exe", .d3dMetal)],
            dxmtPayloadRoot: fixture.payload, overlayRuntime: nil, writer: recorder.writer
        )
        return recorder
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("Only the DXMT game gets the trio beside it and the DXMT set; system32 and Steam keep DXVK's")
    func dxmtGameIsRoutedAppLocal() async throws {
        let fixture = try makeFixture()
        let recorder = try await applyOverrides(fixture, trine4: .dxmt)

        let game = recorder.overrides(for: .program("trine4_game.exe"))
        for dll in ["d3d11", "dxgi", "d3d10core"] {
            #expect(game?[dll] == "n,b", "\(dll)")
        }
        #expect(game?["winemetal"] == "b")
        #expect(game?["nvapi64"] == "" && game?["nvngx"] == "")
        #expect(recorder.overrides(for: .program("modern.exe")) == nil)
        #expect(recorder.overrides(for: .program("steam.exe"))?["d3d11"] == "n,b")

        let deployed = try Data(contentsOf: fixture.gameFolder.appending(path: "d3d11.dll"))
        #expect(deployed == (try Data(contentsOf: fixture.payload.appending(path: "x64/d3d11.dll"))))
        #expect(exists(fixture.gameFolder.appending(path: Wine.AppLocalDXMTManifest.fileName)))
        #expect(!exists(fixture.driveC.appending(path: "windows/system32/d3d11.dll")))
        #expect(exists(fixture.driveC.appending(path: "windows/system32/winemetal.dll")))
        #expect(!exists(fixture.steamApps.appending(path: "common/Modern/d3d11.dll")))
    }

    @Test("A DLL the game folder already holds is kept, and the game gets no DXMT entry")
    func foreignDLLIsPreserved() async throws {
        let fixture = try makeFixture()
        let reshade = Data(count: 0x40) + Data("ReShade d3d11 proxy".utf8) + Data(count: 64)
        try write(reshade, to: fixture.gameFolder.appending(path: "d3d11.dll"))

        let recorder = try await applyOverrides(fixture, trine4: .dxmt)

        #expect(recorder.overrides(for: .program("trine4_game.exe")) == nil)
        #expect(try Data(contentsOf: fixture.gameFolder.appending(path: "d3d11.dll")) == reshade)
        #expect(!exists(fixture.gameFolder.appending(path: "dxgi.dll")))
        #expect(!exists(fixture.gameFolder.appending(path: "d3d10core.dll")))
        #expect(!exists(fixture.gameFolder.appending(path: Wine.AppLocalDXMTManifest.fileName)))
    }

    @Test("A game moved off DXMT loses the trio and its DXMT entry is cleared")
    func staleEntryIsCleared() async throws {
        let fixture = try makeFixture()
        _ = try await applyOverrides(fixture, trine4: .dxmt)
        #expect(exists(fixture.gameFolder.appending(path: "d3d11.dll")))

        let recorder = try await applyOverrides(fixture, trine4: .d3dMetal)

        // Empty, not absent: the sync deletes the key rather than leave the old set.
        #expect(recorder.overrides(for: .program("trine4_game.exe")) == [:])
        #expect(recorder.overrides(for: .program("modern.exe")) == nil)
        for name in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", Wine.AppLocalDXMTManifest.fileName] {
            #expect(!exists(fixture.gameFolder.appending(path: name)), "\(name)")
        }
    }

    @Test("Removal goes by the manifest: a runtime update's new payload still clears the old copies")
    func removalFollowsManifestAfterPayloadChange() async throws {
        let fixture = try makeFixture()
        let executable = fixture.gameFolder.appending(path: "trine4_game.exe")
        try Wine.enableAppLocalDXMT(
            for: executable, prefixRoot: fixture.bottle.url, payloadRoot: fixture.payload
        )
        // The user replaced one copy after it was placed: it is theirs now.
        let replaced = Data(count: 0x40) + Data("user dxgi".utf8) + Data(count: 16)
        try write(replaced, to: fixture.gameFolder.appending(path: "dxgi.dll"))
        try writePayload(at: fixture.payload, tag: "v2")

        #expect(Wine.removeAppLocalDXMT(for: executable, payloadRoot: fixture.payload))

        #expect(!exists(fixture.gameFolder.appending(path: "d3d11.dll")))
        #expect(!exists(fixture.gameFolder.appending(path: "d3d10core.dll")))
        #expect(try Data(contentsOf: fixture.gameFolder.appending(path: "dxgi.dll")) == replaced)
        #expect(!exists(fixture.gameFolder.appending(path: Wine.AppLocalDXMTManifest.fileName)))
        #expect(!Wine.removeAppLocalDXMT(for: executable, payloadRoot: fixture.payload))
    }
}
