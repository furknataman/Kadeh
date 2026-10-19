//
//  OverlayRuntimeTests.swift
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
import SemanticVersion
import Testing
@testable import WhiskyKit

/// The Highball/Sikarugir layout: detection, the environment each backend
/// runs with, launcher resolution, and the prefix cleanup that keeps stale
/// native copies from shadowing the renderer sets.
@Suite("Overlay runtime")
@MainActor
final class OverlayRuntimeTests {
    private let tempRoot: URL
    private let builtinMarker = Data(count: 0x40) + Data("Wine builtin DLL".utf8) + Data(count: 16)
    private let nativePE = Data(count: 0x40) + Data("native PE file!!".utf8) + Data(count: 16)

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory.appending(path: "overlay_runtime_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: path(url)) }

    /// An overlay runtime with the engine, its builtin `dxgi` and the renderer
    /// sets on disk, D3DMetal's only when `d3dMetal`.
    private func makeRuntime(d3dMetal: Bool = true) throws -> OverlayRuntime {
        let root = tempRoot.appending(path: "Libraries")
        try write(Data(), to: root.appending(path: "engine/bin/wine"))
        try write(Data("wine sikarugir 10.0 (revision 6)\n".utf8), to: root.appending(path: "engine/version"))
        try write(Data(), to: root.appending(path: "frameworks/libhbaudiobuf.dylib"))
        for arch in ["x86_64-windows", "i386-windows"] {
            try write(builtinMarker + Data(arch.utf8), to: root.appending(path: "engine/lib/wine/\(arch)/dxgi.dll"))
        }
        var sets = ["renderers/dxmt/wine", "frameworks/renderer/dxvk/wine"]
        if d3dMetal {
            sets.append("renderers/d3dmetal/wine")
        }
        for set in sets {
            try FileManager.default.createDirectory(at: root.appending(path: set), withIntermediateDirectories: true)
        }
        return try #require(OverlayRuntime(libraryFolder: root))
    }

    private func makeBottle(steam: Bool = false) throws -> Bottle {
        let bottleURL = tempRoot.appending(path: "Bottle")
        for directory in ["system32", "syswow64"] {
            try FileManager.default.createDirectory(
                at: bottleURL.appending(path: "drive_c/windows/\(directory)"), withIntermediateDirectories: true
            )
        }
        if steam {
            try write(Data("MZ".utf8), to: bottleURL.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"))
        }
        return Bottle(bottleUrl: bottleURL)
    }

    // MARK: - Detection and binaries

    @Test("Detected by its loader, and installed without a version plist")
    func detection() throws {
        let frankea = tempRoot.appending(path: "Frankea")
        try write(Data(), to: frankea.appending(path: "Wine/bin/wine64"))
        #expect(OverlayRuntime(libraryFolder: frankea) == nil)
        #expect(OverlayRuntime(libraryFolder: tempRoot.appending(path: "Empty")) == nil)

        let runtime = try makeRuntime()
        #expect(WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: runtime.root))
        #expect(runtime.binFolder == runtime.root.appending(path: "engine").appending(path: "bin"))
        #expect(runtime.wineBinary == runtime.binFolder.appending(path: "wine"))
    }

    @Test("Version comes from the engine; DXMT advertised, never GPTK-capable")
    func versionInfo() throws {
        #expect(OverlayRuntime.engineVersion(from: "wine sikarugir 10.0 (revision 6)") == SemanticVersion(10, 0, 6))
        #expect(OverlayRuntime.engineVersion(from: "garbage") == SemanticVersion(0, 0, 0))

        let info = try makeRuntime().versionInfo
        #expect(info.version == SemanticVersion(10, 0, 6))
        #expect(info.dxmtVersion != nil)
        #expect(info.gptkCapable == false)
        #expect(GraphicsBackend.dxmt.isAvailable(runtimeInfo: info))
    }

    // MARK: - Environment

    @Test("Each backend's renderer set, exactly as the engine expects it")
    func rendererEnvironment() throws {
        let runtime = try makeRuntime()
        let renderers = path(runtime.root.appending(path: "renderers"))
        let frameworks = path(runtime.root.appending(path: "frameworks"))

        #expect(runtime.rendererEnvironment(for: .dxmt) == [
            "WINEDLLPATH_PREPEND": "\(renderers)/dxmt/wine:\(renderers)/d9vk-modern/wine"
        ])

        let shim = "\(renderers)/d3dmetal-tsshim/wine/x86_64-windows/apd12.dll"
        let external = "\(renderers)/d3dmetal/external"
        #expect(runtime.rendererEnvironment(for: .d3dMetal) == [
            "WINEDLLPATH_PREPEND": "\(renderers)/d3dmetal-tsshim/wine:\(renderers)/d3dmetal/wine:"
                + "\(renderers)/dxmt/wine:\(renderers)/d9vk-modern/wine",
            "HB_D3D12_REAL": "Z:" + shim.replacingOccurrences(of: "/", with: "\\"),
            "CX_D3DMETALPATH": external,
            "DYLD_FALLBACK_LIBRARY_PATH":
                "\(frameworks):\(frameworks)/GStreamer.framework/Versions/1.0/lib:\(external)",
            "DYLD_FALLBACK_FRAMEWORK_PATH": "\(frameworks):\(external)"
        ])

        #expect(runtime.rendererEnvironment(for: .dxvk) == [
            "WINEDLLPATH_PREPEND": "\(frameworks)/renderer/d9vk/wine:\(frameworks)/renderer/dxvk/wine"
        ])
        #expect(runtime.rendererEnvironment(for: .wined3d).isEmpty)
    }

    @Test("A game's launch: base paths, D3DMetal's set, the bottle's sync, no native DXMT preset")
    func gameEnvironment() throws {
        let runtime = try makeRuntime()
        let bottle = try makeBottle()
        bottle.settings.enhancedSync = .msync
        let frameworks = path(runtime.root.appending(path: "frameworks"))

        let env = Wine.constructWineEnvironment(
            for: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false, overlayRuntime: runtime
        )
        #expect(env["DYLD_FALLBACK_FRAMEWORK_PATH"]?.hasPrefix(frameworks) == true)
        #expect(env["GST_PLUGIN_PATH"] == "\(frameworks)/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0")
        #expect(env["DYLD_INSERT_LIBRARIES"] == "\(frameworks)/libhbaudiobuf.dylib")
        #expect(env["CX_FWD_COMPAT_GL_CTX"] == "1")
        #expect(env["D3DM_MTL4"] == "0")
        let shim = path(runtime.root.appending(path: "renderers/d3dmetal-tsshim"))
        #expect(env["WINEDLLPATH_PREPEND"]?.hasPrefix(shim) == true)
        #expect(env["CX_D3DMETALPATH"] != nil)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "0")
        #expect(Wine.parseDLLOverrides(env["WINEDLLOVERRIDES"] ?? "")["winemenubuilder.exe"] == "")

        bottle.settings.graphicsBackend = .dxmt
        let dxmt = Wine.constructWineEnvironment(
            for: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false, overlayRuntime: runtime
        )
        let overrides = Wine.parseDLLOverrides(dxmt["WINEDLLOVERRIDES"] ?? "")
        for dll in ["dxgi", "d3d11", "d3d10core", "winemetal"] {
            #expect(overrides[dll] == nil, "\(dll) must come from the renderer set, not a forced load order")
        }
        #expect(dxmt["WINEDLLPATH_PREPEND"]?.hasPrefix(path(runtime.root.appending(path: "renderers/dxmt"))) == true)
        #expect(dxmt["CX_D3DMETALPATH"] == nil)
    }

    @Test("A launcher's process runs DXMT's set with sync off, whatever the bottle says")
    func launcherEnvironment() throws {
        let runtime = try makeRuntime()
        let bottle = try makeBottle()
        bottle.settings.enhancedSync = .msync

        let env = Wine.constructWineEnvironment(
            for: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false,
            overlayRuntime: runtime, launcherBackend: .dxmt
        )
        #expect(env["WINEDLLPATH_PREPEND"]?.hasPrefix(path(runtime.root.appending(path: "renderers/dxmt"))) == true)
        #expect(env["WINEMSYNC"] == "0")
        #expect(env["WINEESYNC"] == "0")
    }

    @Test("The terminal environment aliases the overlay's loader")
    func terminalAliases() throws {
        let runtime = try makeRuntime()
        let command = Wine.generateTerminalEnvironmentCommand(
            binFolder: runtime.binFolder, environment: [:], wine: "wine"
        )
        #expect(command.contains("alias wine=\"wine\""))
        #expect(!command.contains("wine64"))
    }

    @Test("A printed command hands the DYLD_ variables to env, which SIP would strip them from")
    func runCommandKeepsDYLD() {
        let launch = Wine.PreparedLaunch(
            environment: ["DYLD_FALLBACK_LIBRARY_PATH": "/fw", "WINEPREFIX": "/p"],
            arguments: ["start", "/unix", "/p/game.exe"]
        )
        let command = Wine.generateRunCommand(for: launch, wineBinary: URL(filePath: "/e/wine"))
        #expect(command == "WINEPREFIX=/p env -u WINEDLLOVERRIDES DYLD_FALLBACK_LIBRARY_PATH=/fw "
            + "/e/wine start /unix /p/game.exe")
    }

    // MARK: - Resolution

    @Test("Games and Steam resolve to D3DMetal when the runtime carries it, else DXMT; other launchers to DXMT")
    func resolution() throws {
        let runtime = try makeRuntime()
        #expect(GraphicsBackendResolver.resolve(for: .steam, overlayRuntime: runtime) == .d3dMetal)
        #expect(GraphicsBackendResolver.resolve(for: .epicGames, overlayRuntime: runtime) == .dxmt)
        #expect(GraphicsBackendResolver.resolve(overlayRuntime: runtime) == .d3dMetal)
        for backend in [GraphicsBackend.d3dMetal, .dxmt, .dxvk] {
            #expect(runtime.isAvailable(backend))
        }

        try FileManager.default.removeItem(at: runtime.root.appending(path: "renderers/d3dmetal"))
        #expect(GraphicsBackendResolver.resolve(overlayRuntime: runtime) == .dxmt)
        #expect(GraphicsBackendResolver.resolve(for: .steam, overlayRuntime: runtime) == .dxmt)
        #expect(!runtime.isAvailable(.d3dMetal))
    }

    @Test("Steam runs on its games' set with CEF's GPU process off, writes no forced-native D3D entries, copies nothing")
    func steamLaunch() async throws {
        let runtime = try makeRuntime()
        let bottle = try makeBottle(steam: true)
        bottle.settings.graphicsBackend = .recommended
        let steam = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let recorder = ScopeRecorder()

        let launch = try await Wine.prepareProgramLaunch(
            at: steam, args: ["-silent"], bottle: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false,
            overrideWriter: recorder.writer, importer: recorder.importer, overlayRuntime: runtime
        )

        // Games Steam starts inherit this environment, and DirectX 12 ones need D3DMetal's `d3d12`.
        #expect(launch.environment["WINEDLLPATH_PREPEND"]?.hasPrefix(
            path(runtime.root.appending(path: "renderers/d3dmetal-tsshim"))
        ) == true)
        #expect(launch.environment["CX_D3DMETALPATH"] != nil)
        #expect(Array(launch.arguments.suffix(2)) == ["-cef-disable-gpu", "-silent"])

        // A bottle's explicit choice reaches Steam, and so its games, too.
        bottle.settings.graphicsBackend = .dxmt
        let explicitRecorder = ScopeRecorder()
        let explicit = try await Wine.prepareProgramLaunch(
            at: steam, bottle: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false,
            overrideWriter: explicitRecorder.writer, importer: explicitRecorder.importer, overlayRuntime: runtime
        )
        #expect(explicit.environment["WINEDLLPATH_PREPEND"]?.hasPrefix(
            path(runtime.root.appending(path: "renderers/dxmt"))
        ) == true)
        #expect(launch.environment["WINEMSYNC"] == "0")
        #expect(launch.environment["WINEESYNC"] == "0")
        for executable in ["steam.exe", "steamwebhelper.exe", "SteamSetup.exe"] {
            let overrides = try #require(recorder.overrides(for: .program(executable)))
            for dll in ["dxgi", "d3d9", "d3d10core", "d3d11", "d3d12"] {
                #expect(overrides[dll] != "n,b" && overrides[dll] != "n", "\(executable) forces \(dll) native")
            }
        }
        let system32 = bottle.url.appending(path: "drive_c/windows/system32")
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(system32)).isEmpty)
    }

    @Test("A game launch puts the client on the game's set: -applaunch, the client start, and the restart check")
    func steamGameLaunch() async throws {
        let runtime = try makeRuntime()
        let bottle = try makeBottle(steam: true)
        bottle.settings.graphicsBackend = .recommended
        let steam = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let dxmtSet = path(runtime.root.appending(path: "renderers/dxmt"))
        let d3dMetalSet = path(runtime.root.appending(path: "renderers/d3dmetal-tsshim"))

        // The GameDB's backend picks the client's: DXMT for Trine 4, D3DMetal for the rest.
        let trine4 = GameDBEntry(
            id: "trine-4", title: "Trine 4", steamAppId: 690_640, rating: .works, exeNames: ["trine4_game.exe"],
            variants: [GameConfigVariant(
                id: "recommended", label: "Recommended", isDefault: true,
                settings: GameConfigVariantSettings(graphicsBackend: .dxmt)
            )]
        )
        let dxmtPlan = LaunchResolver.plan(steamAppId: 690_640, entries: [trine4])
        let modernPlan = LaunchResolver.plan(steamAppId: 1_817_070, entries: [trine4])
        #expect(SteamLauncher.clientBackend(for: dxmtPlan, bottle: bottle, overlayRuntime: runtime) == .dxmt)
        #expect(SteamLauncher.clientBackend(for: modernPlan, bottle: bottle, overlayRuntime: runtime) == .d3dMetal)
        #expect(SteamLauncher.clientBackend(for: modernPlan, bottle: bottle, overlayRuntime: nil) == nil)

        // A cold `-applaunch` brings the client up on the game's set.
        for (plan, set) in [(dxmtPlan, dxmtSet), (modernPlan, d3dMetalSet)] {
            let recorder = ScopeRecorder()
            let launch = try await Wine.prepareProgramLaunch(
                at: steam, args: ["-applaunch", "1"], bottle: bottle, programOverrides: plan.overrides,
                overridesApplyToDescendants: true, descendantExecutables: ["game.exe"],
                recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false,
                overrideWriter: recorder.writer, importer: recorder.importer, overlayRuntime: runtime
            )
            #expect(launch.environment["WINEDLLPATH_PREPEND"]?.hasPrefix(set) == true, "\(set)")
            // Steam hands what follows `-applaunch <id>` to the game, so Steam's own flag comes first.
            #expect(Array(launch.arguments.suffix(3)) == ["-cef-disable-gpu", "-applaunch", "1"])
        }

        // A running client on another set stops, unless a game is open; one on the same set serves.
        let dxmtWanted = runtime.rendererEnvironment(for: .dxmt)["WINEDLLPATH_PREPEND"]
        let d3dMetalWanted = runtime.rendererEnvironment(for: .d3dMetal)["WINEDLLPATH_PREPEND"]
        let client: SteamLauncher.BottleProcess = (
            1, #"C:\Program Files (x86)\Steam\steam.exe"#, ["WINEDLLPATH_PREPEND": d3dMetalWanted ?? ""]
        )
        let game: SteamLauncher.BottleProcess = (
            2, #"C:\Program Files (x86)\Steam\steamapps\common\Trine 4\trine4_game.exe"#, [:]
        )
        let helper: SteamLauncher.BottleProcess = (3, #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe"#, [:])
        #expect(SteamLauncher.clientMustStop([client, helper], wanted: dxmtWanted))
        #expect(!SteamLauncher.clientMustStop([client, helper], wanted: d3dMetalWanted))
        #expect(!SteamLauncher.clientMustStop([client, helper, game], wanted: dxmtWanted))
        #expect(!SteamLauncher.clientMustStop([helper], wanted: dxmtWanted))
        #expect(SteamLauncher.clientImages.contains(SteamLauncher.imageName(helper.argv0)))
        #expect(!SteamLauncher.clientImages.contains(SteamLauncher.imageName(game.argv0)))

        // A process's environment reads back as it was started with.
        let read = try #require(SteamLauncher.argumentsAndEnvironment(of: getpid()))
        #expect(read.1["HOME"] != nil)
        #expect(read.1["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    /// A minimal PE32+ whose export directory names itself `name`.
    private func fakePE(exportName name: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put32(_ value: Int, at offset: Int) {
            for index in 0 ..< 4 { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        bytes[0] = 0x4D; bytes[1] = 0x5A
        put32(0x40, at: 0x3C)
        bytes[0x40] = 0x50; bytes[0x41] = 0x45
        bytes[0x46] = 1 // one section
        bytes[0x54] = 0xF0 // optional header size
        bytes[0x58] = 0x0B; bytes[0x59] = 0x02 // PE32+
        put32(0x1000, at: 0x58 + 112); put32(0x40, at: 0x58 + 116) // export directory
        let section = 0x58 + 0xF0
        put32(0x200, at: section + 8); put32(0x1000, at: section + 12)
        put32(0x200, at: section + 16); put32(0x200, at: section + 20)
        put32(0x1028, at: 0x200 + 12) // the name's RVA
        bytes.replaceSubrange(0x228 ..< 0x228 + name.utf8.count, with: Array(name.utf8))
        return Data(bytes)
    }

    @Test("D3DMetal's real d3d12 is laid out beside the shim as apd12, under its own export name")
    func realD3D12BesideShim() throws {
        let runtime = try makeRuntime()
        let real = runtime.root.appending(path: "renderers/d3dmetal/wine")
        let shim = runtime.root.appending(path: "renderers/d3dmetal-tsshim/wine")
        try write(fakePE(exportName: "d3d12.dll"), to: real.appending(path: "x86_64-windows/d3d12.dll"))
        try write(Data(), to: real.appending(path: "x86_64-unix/d3d12.so"))
        try write(Data(), to: shim.appending(path: "x86_64-windows/d3d12.dll"))

        try runtime.layOutRealD3D12()
        let pe = try Data(contentsOf: shim.appending(path: "x86_64-windows/apd12.dll"))
        let offset = try #require(OverlayRuntime.exportNameOffset(in: pe))
        #expect(pe[offset ..< offset + 10] == Data("apd12.dll\0".utf8))
        #expect(pe.count == 0x400)
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: path(shim.appending(path: "x86_64-unix/apd12.so"))
        )
        #expect(link == path(real.appending(path: "x86_64-unix/d3d12.so")))
        // The path HB_D3D12_REAL names is the file laid out.
        let named = try #require(runtime.rendererEnvironment(for: .d3dMetal)["HB_D3D12_REAL"])
        #expect(named.hasSuffix(#"\d3dmetal-tsshim\wine\x86_64-windows\apd12.dll"#))
        try runtime.layOutRealD3D12()
        #expect(try Data(contentsOf: shim.appending(path: "x86_64-windows/apd12.dll")) == pe)
        #expect(throws: (any Error).self) { try OverlayRuntime.renamingExport(of: Data("MZ".utf8), to: "x") }
    }

    // MARK: - Prefix cleanup

    @Test("Native translation DLLs go and get the engine's builtin back; builtin ones stay")
    func nativeCleanup() throws {
        let runtime = try makeRuntime()
        let windows = tempRoot.appending(path: "Prefix/drive_c/windows")
        let sys32DXGI = windows.appending(path: "system32/dxgi.dll")
        let sys32D3D11 = windows.appending(path: "system32/d3d11.dll")
        let wowDXGI = windows.appending(path: "syswow64/dxgi.dll")
        let wowD3D12 = windows.appending(path: "syswow64/d3d12.dll")
        let unrelated = windows.appending(path: "system32/d2d1.dll")
        try write(nativePE, to: sys32DXGI)
        try write(builtinMarker, to: sys32D3D11)
        try write(nativePE, to: wowDXGI)
        try write(nativePE, to: wowD3D12)
        try write(nativePE, to: unrelated)

        let removed = runtime.removeNativeTranslationDLLs(prefixRoot: tempRoot.appending(path: "Prefix"))

        #expect(Set(removed.map(\.lastPathComponent)) == ["dxgi.dll", "d3d12.dll"])
        #expect(removed.count == 3)
        let engine = runtime.root.appending(path: "engine/lib/wine")
        #expect(try Data(contentsOf: sys32DXGI) == Data(contentsOf: engine.appending(path: "x86_64-windows/dxgi.dll")))
        #expect(try Data(contentsOf: wowDXGI) == Data(contentsOf: engine.appending(path: "i386-windows/dxgi.dll")))
        #expect(!exists(wowD3D12), "nothing to restore it from, so the slot stays empty")
        #expect(try Data(contentsOf: sys32D3D11) == builtinMarker)
        #expect(try Data(contentsOf: unrelated) == nativePE)

        #expect(runtime.removeNativeTranslationDLLs(prefixRoot: tempRoot.appending(path: "Prefix")).isEmpty)
    }
}
