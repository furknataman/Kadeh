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

    /// Where a runtime keeps the SDL library winebus loads, for each layout
    /// this knows: WhiskyWine's `Wine/lib`, and the overlay runtime's `frameworks`.
    private static func sdlLocations(libraryFolder: URL) -> (folder: URL, library: URL)? {
        let manager = FileManager.default
        let candidates = ["Wine/lib", "frameworks"].map { libraryFolder.appending(path: $0) }
        for folder in candidates where manager.fileExists(atPath: folder.path(percentEncoded: false)) {
            return (folder, folder.appending(path: "libSDL2-2.0.0.dylib"))
        }
        return nil
    }

    /// Whether the runtime's library folder lacks the SDL that winebus loads
    /// by name. The 4.x runtimes ship none, and their winebus cannot use one
    /// anyway. A runtime with neither a `Wine/lib` nor a `frameworks` folder is
    /// a layout this check does not know, so it is left alone.
    static func runtimeLacksSDL(libraryFolder: URL = WhiskyWineInstaller.libraryFolder) -> Bool {
        guard let location = sdlLocations(libraryFolder: libraryFolder) else { return false }
        return !FileManager.default.fileExists(atPath: location.library.path(percentEncoded: false))
    }

    /// Whether the runtime is known to ship SDL: the opposite of
    /// ``runtimeLacksSDL(libraryFolder:)``, except that an unknown layout
    /// counts as having none.
    static func runtimeHasSDL(libraryFolder: URL = WhiskyWineInstaller.libraryFolder) -> Bool {
        sdlLocations(libraryFolder: libraryFolder) != nil && !runtimeLacksSDL(libraryFolder: libraryFolder)
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

/// Presents Sony gamepads to games as XInput pads.
///
/// Wine's winebus gives a DualShock 4 or DualSense to games as a raw HID device
/// and drops the SDL (XInput) copy, so a game that only reads XInput sees no
/// controller. Wine 10's only switch for this is the global `DisableHidraw`
/// bus option: set, winebus does not start its IOHID bus at all and every pad
/// comes through SDL, Sony pads as XInput ones. Because it is global, other
/// special controllers (steering wheels, flight sticks) can be affected too.
///
/// It needs SDL: without it winebus keeps the raw copy on purpose (see
/// ``WineControllerBus``), and `DisableHidraw` would remove every pad.
public enum WinePlayStationPads {
    /// Whether the installed runtime can show Sony pads as Xbox pads: only one that ships SDL can.
    public static var isSupported: Bool { WineControllerBus.runtimeHasSDL() }

    static let valueName = "DisableHidraw"
    static let valueData = "dword:00000001"

    /// Whether the saved registry still has ``WineControllerBus``'s SDL-off
    /// and input-off values from an earlier runtime without SDL. With
    /// `DisableHidraw` as well, no bus keeps the pad and it vanishes.
    static func hasLeftovers(bottleURL: URL) -> Bool {
        WineControllerBus.values.contains {
            WineRegistryFile.readValue(
                bottleURL: bottleURL, key: WineControllerBus.savedKey, valueName: $0.name
            ) == $0.data
        }
    }

    /// Whether the saved registry differs from what a bottle wants, read from
    /// `system.reg` without starting Wine. Never before that file exists.
    ///
    /// - Parameters:
    ///   - enabled: Whether the bottle asks for Sony pads as Xbox pads. When
    ///     on, leftovers from an SDL-less runtime count as a difference; when
    ///     off they are left as they are.
    ///   - runtimeHasSDL: Without SDL the value is unwanted whatever the
    ///     setting says, so a bottle that has it from an earlier runtime
    ///     gets it removed.
    static func needsSync(enabled: Bool, runtimeHasSDL: Bool, bottleURL: URL) -> Bool {
        let systemReg = bottleURL.appending(path: "system.reg")
        guard FileManager.default.fileExists(atPath: systemReg.path(percentEncoded: false)) else { return false }
        let saved = WineRegistryFile.readValue(
            bottleURL: bottleURL, key: WineControllerBus.savedKey, valueName: valueName
        )
        if enabled && runtimeHasSDL {
            return saved != valueData || hasLeftovers(bottleURL: bottleURL)
        }
        return saved != nil
    }

    /// The `.reg` document that sets (`enabled`) or removes the value. When
    /// setting it, `removingLeftovers` also deletes the SDL-off and input-off
    /// values, which would otherwise hide every pad.
    static func registryDocument(enabled: Bool, removingLeftovers: Bool = false) -> String {
        var lines = [
            "Windows Registry Editor Version 5.00", "",
            "[\(WineControllerBus.registryKey)]",
            enabled ? "\"\(valueName)\"=\(valueData)" : "\"\(valueName)\"=-"
        ]
        if enabled && removingLeftovers {
            lines += WineControllerBus.values.map { "\"\($0.name)\"=-" }
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }
}

extension Wine {
    /// Brings a bottle's `DisableHidraw` value in line with ``BottleSettings/playStationAsXbox``.
    ///
    /// Imports only when the saved state differs, so a launch with nothing to
    /// change costs a read of `system.reg`. winebus reads the option when the
    /// prefix starts, so a change applies from its next start. It never
    /// restarts a wineserver (that would kill a running game) and never fails
    /// a launch.
    @MainActor
    static func syncPlayStationPads(
        bottle: Bottle,
        runtimeHasSDL: Bool = WineControllerBus.runtimeHasSDL(),
        importer: RegistryImporter = { try await importRegistry(document: $0, bottle: $1) }
    ) async {
        let enabled = bottle.settings.playStationAsXbox
        let bottleURL = bottle.url
        let (needed, leftovers) = await Task.detached(priority: .userInitiated) {
            (
                WinePlayStationPads.needsSync(enabled: enabled, runtimeHasSDL: runtimeHasSDL, bottleURL: bottleURL),
                enabled && runtimeHasSDL && WinePlayStationPads.hasLeftovers(bottleURL: bottleURL)
            )
        }.value
        guard needed else { return }

        let wanted = enabled && runtimeHasSDL
        do {
            let document = WinePlayStationPads.registryDocument(enabled: wanted, removingLeftovers: leftovers)
            try await importer(document, bottle)
            logger.info("PlayStation pads for '\(bottle.settings.name)': \(wanted ? "Xbox" : "native")")
        } catch {
            logger.error("PlayStation pad sync failed for '\(bottle.settings.name)': \(error.localizedDescription)")
        }
    }
}
