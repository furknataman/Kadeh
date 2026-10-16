//
//  WineControllerBus.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineControllerBus")

/// Hands gamepads to winebus's IOHID bus when the runtime cannot load SDL.
///
/// winebus takes gamepads from SDL. Its IOHID bus sees them too, but since
/// Wine 10 `is_hidraw_enabled` (`dlls/winebus.sys/main.c`) keeps IOHID's copy
/// of a gamepad only when the registry turns SDL off and `DisableInput` on,
/// whether or not SDL actually loaded. The 4.x WhiskyWine runtimes are built
/// without SDL ("SDL support not compiled in!" in `winebus.so`) and ship no
/// libSDL2, so no bus reported an Xbox controller and every game ran without
/// one, with nothing above a WARN in the log. 3.1.1 ships libSDL2 and keeps
/// its SDL bus.
enum WineControllerBus {
    /// Where the options are written.
    static let registryKey = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\winebus"#
    /// Where Wine saves them: `CurrentControlSet` is a link to this key, and `system.reg` holds only the target.
    static let savedKey = #"HKEY_LOCAL_MACHINE\System\ControlSet001\Services\winebus"#

    /// SDL off and input devices off: together they make every gamepad's IOHID device the one winebus keeps.
    static let values: [(name: String, data: String)] = [
        ("Enable SDL", "dword:00000000"),
        ("DisableInput", "dword:00000001")
    ]

    /// Whether the runtime's `Wine/lib` lacks the SDL that winebus loads by
    /// name. The 4.x runtimes ship none, and their winebus cannot use one
    /// anyway. A runtime without `Wine/lib` is a layout this check does not
    /// know, so it is left alone.
    static func runtimeLacksSDL(libraryFolder: URL = WhiskyWineInstaller.libraryFolder) -> Bool {
        let lib = libraryFolder.appending(path: "Wine/lib")
        let manager = FileManager.default
        return manager.fileExists(atPath: lib.path(percentEncoded: false))
            && !manager.fileExists(atPath: lib.appending(path: "libSDL2-2.0.0.dylib").path(percentEncoded: false))
    }

    /// Whether a bottle still needs the options, read from its prefix without
    /// starting Wine. Only when the runtime lacks SDL, and not when
    /// `system.reg` cannot be read yet.
    static func needsOptions(runtimeLacksSDL: Bool, bottleURL: URL) -> Bool {
        let systemReg = bottleURL.appending(path: "system.reg")
        guard runtimeLacksSDL, FileManager.default.fileExists(atPath: systemReg.path(percentEncoded: false)) else {
            return false
        }
        return values.contains {
            WineRegistryFile.readValue(bottleURL: bottleURL, key: savedKey, valueName: $0.name) != $0.data
        }
    }

    static func registryDocument() -> String {
        var lines = ["Windows Registry Editor Version 5.00", "", "[\(registryKey)]"]
        lines += values.map { "\"\($0.name)\"=\($0.data)" }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }
}

extension Wine {
    /// Writes ``WineControllerBus``'s options into a bottle whose runtime has no SDL.
    ///
    /// winebus reads them when the prefix starts, and the import itself starts
    /// it, so they take effect from the prefix's next start. Once written, a
    /// launch costs a read of `system.reg`. It never fails a launch.
    @MainActor
    static func syncControllerBus(
        bottle: Bottle,
        runtimeLacksSDL: Bool = WineControllerBus.runtimeLacksSDL(),
        importer: RegistryImporter = { try await importRegistry(document: $0, bottle: $1) }
    ) async {
        // Off the main actor: the whole hive is read, and it grows with the prefix.
        let bottleURL = bottle.url
        let needed = await Task.detached(priority: .userInitiated) {
            WineControllerBus.needsOptions(runtimeLacksSDL: runtimeLacksSDL, bottleURL: bottleURL)
        }.value
        guard needed else {
            return
        }

        do {
            try await importer(WineControllerBus.registryDocument(), bottle)
            logger.info("Moved gamepads to the IOHID bus for '\(bottle.settings.name)': the runtime has no SDL")
        } catch {
            logger.error("Controller bus sync failed for '\(bottle.settings.name)': \(error.localizedDescription)")
        }
    }
}
