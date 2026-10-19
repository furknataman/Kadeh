//
//  OverlayRuntime.swift
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
import os.log
import SemanticVersion

/// The Highball/Sikarugir runtime layout, installed as the `Libraries` folder
/// in place of a WhiskyWine runtime.
///
/// ```
/// Libraries/engine/bin/wine          the loader (no wine64)
/// Libraries/frameworks/              the dylibs the engine links against
/// Libraries/renderers/<name>/wine/   builtin D3D sets, put in front of the
///                                    engine's own with WINEDLLPATH_PREPEND
/// ```
///
/// Translation layers are never copied into a prefix here. Each one is a set of
/// builtin DLLs the engine finds through `WINEDLLPATH_PREPEND`, so picking a
/// backend is picking an environment, and a native copy in `system32` is what
/// would shadow it.
public struct OverlayRuntime: Equatable, Sendable {
    /// The runtime root, the folder that holds `engine`, `frameworks` and `renderers`.
    public let root: URL

    /// The overlay runtime at `libraryFolder`, or `nil` when that folder holds
    /// some other layout (or nothing).
    public init?(libraryFolder: URL) {
        let wine = libraryFolder.appending(path: "engine").appending(path: "bin").appending(path: "wine")
        guard FileManager.default.fileExists(atPath: wine.path(percentEncoded: false)) else { return nil }
        root = libraryFolder
    }

    /// The overlay runtime installed as ``WhiskyWineInstaller/libraryFolder``, if
    /// that is the layout installed. Read from disk on every call, so a runtime
    /// swapped while the app runs is picked up by the next launch.
    public static var installed: OverlayRuntime? {
        OverlayRuntime(libraryFolder: WhiskyWineInstaller.libraryFolder)
    }

    /// The folder holding `wine` and `wineserver`.
    public var binFolder: URL { root.appending(path: "engine").appending(path: "bin") }
    /// The loader every Windows program runs through.
    public var wineBinary: URL { binFolder.appending(path: "wine") }
    var frameworks: URL { root.appending(path: "frameworks") }
    var renderers: URL { root.appending(path: "renderers") }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: path(url)) }

    // MARK: - Environment

    /// What every process started from this engine needs, `wineserver -k` and
    /// `wine --version` included: the engine links against dylibs that live in
    /// `frameworks/`, and without these dyld cannot load `libinotify` and the
    /// process dies before `main`.
    public var baseEnvironment: [String: String] {
        let frameworks = path(frameworks)
        return [
            "DYLD_FALLBACK_LIBRARY_PATH": "\(frameworks):\(frameworks)/GStreamer.framework/Versions/1.0/lib",
            "DYLD_FALLBACK_FRAMEWORK_PATH": frameworks,
            "GST_PLUGIN_PATH": "\(frameworks)/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"
        ]
    }

    /// What a bottle's processes add to ``baseEnvironment``, whatever the backend.
    ///
    /// The audio buffer library caps the period the Mac asks Wine's audio
    /// driver for, which otherwise plays a game's shortfall as dropouts. Only
    /// inserted when present: dyld refuses to start a process whose inserted
    /// library is missing, and engines before r20 ship none.
    var programEnvironment: [String: String] {
        var environment = baseEnvironment
        environment["CX_FWD_COMPAT_GL_CTX"] = "1"
        let audioBuffer = frameworks.appending(path: "libhbaudiobuf.dylib")
        if exists(audioBuffer) {
            environment["DYLD_INSERT_LIBRARIES"] = path(audioBuffer)
        }
        return environment
    }

    /// The renderer set a backend runs on, as the variables that select it.
    ///
    /// D3DMetal's set goes in front of DXMT's, so a D3D12 game gets D3DMetal's
    /// `d3d11`/`dxgi` too, with the timestamp shim in front of its `d3d12`. The
    /// shim forwards to D3DMetal's real one, which it finds through
    /// `HB_D3D12_REAL` as a Windows path.
    func rendererEnvironment(for backend: GraphicsBackend) -> [String: String] {
        let renderers = renderers
        let wine = { (name: String) in self.path(renderers.appending(path: name).appending(path: "wine")) }
        switch backend {
        case .dxmt:
            return ["WINEDLLPATH_PREPEND": [wine("dxmt"), wine("d9vk-modern")].joined(separator: ":")]
        case .d3dMetal:
            let external = path(renderers.appending(path: "d3dmetal").appending(path: "external"))
            let realD3D12 = renderers.appending(path: "d3dmetal-tsshim").appending(path: "wine")
                .appending(path: "x86_64-windows").appending(path: "apd12.dll")
            let base = baseEnvironment
            return [
                "WINEDLLPATH_PREPEND": [wine("d3dmetal-tsshim"), wine("d3dmetal"), wine("dxmt"), wine("d9vk-modern")]
                    .joined(separator: ":"),
                "HB_D3D12_REAL": "Z:" + path(realD3D12).replacingOccurrences(of: "/", with: "\\"),
                "CX_D3DMETALPATH": external,
                "DYLD_FALLBACK_LIBRARY_PATH": base["DYLD_FALLBACK_LIBRARY_PATH", default: ""] + ":" + external,
                "DYLD_FALLBACK_FRAMEWORK_PATH": base["DYLD_FALLBACK_FRAMEWORK_PATH", default: ""] + ":" + external
            ]
        case .dxvk:
            let renderer = frameworks.appending(path: "renderer")
            return ["WINEDLLPATH_PREPEND": [
                path(renderer.appending(path: "d9vk").appending(path: "wine")),
                path(renderer.appending(path: "dxvk").appending(path: "wine"))
            ].joined(separator: ":")]
        case .wined3d, .recommended:
            return [:]
        }
    }

    /// The sync variables for a sync mode. Unlike the WhiskyWine runtime, msync
    /// here runs without esync beside it, and "none" really is none.
    static func syncEnvironment(_ sync: EnhancedSync) -> [String: String] {
        switch sync {
        case .none:
            ["WINEMSYNC": "0", "WINEESYNC": "0"]
        case .esync:
            ["WINEMSYNC": "0", "WINEESYNC": "1"]
        case .msync:
            ["WINEMSYNC": "1", "WINEESYNC": "0"]
        }
    }

    // MARK: - Backends

    /// Whether the renderer set behind `backend` is on disk.
    public func isAvailable(_ backend: GraphicsBackend) -> Bool {
        switch backend {
        case .d3dMetal:
            exists(renderers.appending(path: "d3dmetal").appending(path: "wine"))
        case .dxmt:
            exists(renderers.appending(path: "dxmt").appending(path: "wine"))
        case .dxvk:
            exists(frameworks.appending(path: "renderer").appending(path: "dxvk").appending(path: "wine"))
        case .wined3d, .recommended:
            true
        }
    }

    /// What `.recommended` resolves to here. A game gets D3DMetal when the
    /// runtime carries it, since that is the only set with `d3d12`, and DXMT
    /// otherwise. Steam gets its games' set: every game it starts inherits the
    /// client's environment, so a client on DXMT left DirectX 12 games with no
    /// `d3d12`. Its CEF runs with the GPU process off (see
    /// ``Wine/prepareProgramLaunch``), which D3DMetal's `d3d11` would draw
    /// black. Other launchers keep DXMT, which their UIs render on.
    func recommendedBackend(for launcher: LauncherType?) -> GraphicsBackend {
        // ponytail: only Steam verified with its GPU process off; other launchers
        // starting DirectX 12 games need their own CEF/WebEngine switch first.
        if launcher == nil || launcher == .steam, isAvailable(.d3dMetal) {
            return .d3dMetal
        }
        return .dxmt
    }

    // MARK: - Version

    /// A version record for a runtime that ships none, so the rest of the app
    /// sees it as installed: the engine's version from `engine/version`
    /// (`wine sikarugir 10.0 (revision 6)` reads as 10.0.6), DXMT advertised
    /// when its set is on disk, and never GPTK-capable, because D3DMetal comes
    /// with the runtime and nothing may be deployed into it.
    public var versionInfo: WhiskyWineVersion {
        let text = (try? String(contentsOf: root.appending(path: "engine").appending(path: "version"), encoding: .utf8))
            ?? ""
        return WhiskyWineVersion(
            version: Self.engineVersion(from: text),
            dxmtVersion: isAvailable(.dxmt) ? "overlay" : nil,
            gptkCapable: false
        )
    }

    /// Parses `wine <flavour> <major>.<minor> (revision <n>)`; whatever is
    /// missing reads as zero.
    static func engineVersion(from text: String) -> SemanticVersion {
        let release = text.firstMatch(of: /(\d+)\.(\d+)/)
        let revision = text.firstMatch(of: /revision (\d+)/)
        return SemanticVersion(
            release.flatMap { Int($0.1) } ?? 0,
            release.flatMap { Int($0.2) } ?? 0,
            revision.flatMap { Int($0.1) } ?? 0
        )
    }

    // MARK: - Prefix cleanup

    /// The translation DLLs whose native copies shadow the renderer sets.
    static let translationDLLs = ["dxgi", "d3d9", "d3d10core", "d3d11", "d3d12", "d3d12core", "winemetal"]

    /// Removes native copies of the translation DLLs from a prefix's system
    /// directories, the ones an earlier runtime's DXVK, DXMT or D3DMetal
    /// deployment left there. Wine loads such a copy ahead of the builtin set
    /// `WINEDLLPATH_PREPEND` points at, so the backend picked would never run.
    ///
    /// A builtin-marked file is Wine's own placeholder and stays. A removed
    /// copy is replaced by the engine's builtin, because the loader reaches a
    /// builtin only through a file in the system directory.
    ///
    /// Idempotent and cheap: a prefix with nothing to remove costs a few
    /// 16-byte reads.
    ///
    /// - Returns: The files removed.
    @discardableResult
    func removeNativeTranslationDLLs(prefixRoot: URL) -> [URL] {
        let fileManager = FileManager.default
        let windows = prefixRoot.appending(path: "drive_c").appending(path: "windows")
        let builtins = root.appending(path: "engine").appending(path: "lib").appending(path: "wine")
        var removed: [URL] = []
        for (directory, arch) in [("system32", "x86_64-windows"), ("syswow64", "i386-windows")] {
            for name in Self.translationDLLs.map({ "\($0).dll" }) {
                let dll = windows.appending(path: directory).appending(path: name)
                guard (try? Wine.isNativePE(dll)) == true,
                      (try? fileManager.removeItem(at: dll)) != nil
                else { continue }
                removed.append(dll)
                Logger.wineKit.info("Removed native \(name, privacy: .public) from \(directory, privacy: .public)")
                try? fileManager.copyItem(at: builtins.appending(path: arch).appending(path: name), to: dll)
            }
        }
        return removed
    }

    // MARK: - Timestamp shim

    /// Lays out D3DMetal's real `d3d12` beside the timestamp shim as `apd12`,
    /// the file `HB_D3D12_REAL` names: the PE under its own export name, and
    /// its Mach-O half linked as `x86_64-unix/apd12.so`. The engine's manifest
    /// ships neither; Highball lays them out when it builds a launch
    /// (`timestampShimDir`). Without them the shim finds no `d3d12` and games
    /// report no DirectX 12 support. Wine 10 tells builtins apart by file name
    /// and CrossOver's Wine 11 by export name, so the copy gets both of its
    /// own. Idempotent, and redone when D3DMetal's `d3d12` changes.
    func layOutRealD3D12() throws {
        let shim = renderers.appending(path: "d3dmetal-tsshim").appending(path: "wine")
        let real = renderers.appending(path: "d3dmetal").appending(path: "wine")
        guard exists(shim), exists(real) else { return }
        let fileManager = FileManager.default
        let pe = shim.appending(path: "x86_64-windows").appending(path: "apd12.dll")
        let so = shim.appending(path: "x86_64-unix").appending(path: "apd12.so")
        let realSO = path(real.appending(path: "x86_64-unix").appending(path: "d3d12.so"))
        let wanted = try Self.renamingExport(
            of: Data(contentsOf: real.appending(path: "x86_64-windows").appending(path: "d3d12.dll")), to: "apd12.dll"
        )
        if (try? Data(contentsOf: pe)) != wanted {
            try? fileManager.removeItem(at: pe)
            try wanted.write(to: pe)
        }
        try fileManager.createDirectory(at: so.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fileManager.destinationOfSymbolicLink(atPath: path(so))) != realSO {
            try? fileManager.removeItem(at: so)
            try fileManager.createSymbolicLink(atPath: path(so), withDestinationPath: realSO)
        }
    }

    /// The PE with the name in its export directory replaced in place,
    /// zero-padded: nothing else in the file moves. From Highball's
    /// `PEExportName.patched`.
    static func renamingExport(of data: Data, to name: String) throws -> Data {
        guard let start = exportNameOffset(in: data) else { throw CocoaError(.fileReadCorruptFile) }
        let end = data[start...].firstIndex(of: 0) ?? data.endIndex
        let bytes = Array(name.utf8)
        guard bytes.count <= end - start else { throw CocoaError(.fileWriteInvalidFileName) }
        var out = data
        out.replaceSubrange(start ..< end, with: bytes + [UInt8](repeating: 0, count: end - start - bytes.count))
        return out
    }

    /// The file offset of a PE's export name string (PE32 or PE32+), or nil.
    static func exportNameOffset(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int {
            offset + 2 <= bytes.count ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : 0
        }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count > 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return nil }
        let header = u32(0x3C)
        guard header + 24 <= bytes.count, bytes[header ..< header + 4] == [0x50, 0x45, 0, 0] else { return nil }
        let sections = u16(header + 6), optionalSize = u16(header + 20), optional = header + 24
        guard optionalSize >= 96, optional + optionalSize <= bytes.count else { return nil }
        let directories = optional + (u16(optional) == 0x20B ? 112 : 96)
        let exportRVA = u32(directories)
        guard exportRVA > 0, u32(directories + 4) > 0 else { return nil }
        func fileOffset(_ rva: Int) -> Int? {
            for index in 0 ..< sections {
                let section = optional + optionalSize + 40 * index
                guard section + 40 <= bytes.count else { return nil }
                let address = u32(section + 12), size = max(u32(section + 8), u32(section + 16))
                if rva >= address, rva < address + max(size, 1) {
                    return rva - address + u32(section + 20)
                }
            }
            return nil
        }
        guard let directory = fileOffset(exportRVA), directory + 40 <= bytes.count,
              let name = fileOffset(u32(directory + 12)), name < bytes.count else { return nil }
        return name
    }
}
