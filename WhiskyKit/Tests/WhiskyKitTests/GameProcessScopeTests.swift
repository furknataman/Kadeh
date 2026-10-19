//
//  GameProcessScopeTests.swift
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

@Suite("Game process scope")
struct GameProcessScopeTests {
    private func makeBottle() throws -> URL {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "kadeh-scope-\(UUID().uuidString)")
        let game = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common/Deep Rock Galactic")
        try FileManager.default.createDirectory(
            at: game.appending(path: "FSD/Binaries/Win64"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: game.appending(path: "_CommonRedist/vcredist"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bottle.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: bottle.appending(path: "dosdevices/c:"), withDestinationURL: bottle.appending(path: "drive_c")
        )
        try Data().write(to: game.appending(path: "FSD.exe"))
        try Data().write(to: game.appending(path: "FSD/Binaries/Win64/FSD-Win64-Shipping.exe"))
        try Data().write(to: game.appending(path: "_CommonRedist/vcredist/vc_redist.x64.exe"))
        return bottle
    }

    private func gameFolder(_ bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common/Deep Rock Galactic")
    }

    private func process(_ path: String, in bottle: URL) -> HostWineProcess {
        HostWineProcess(pid: 1, imagePath: path, prefixPath: bottle.path(percentEncoded: false))
    }

    @Test("A Steam game's deep shipping executable counts once its bootstrap is gone")
    func deepExecutable() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let scope = GameProcessScope(bottleURL: bottle, folder: gameFolder(bottle), executable: nil, names: [])
        let shipping = #"C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD\Binaries\Win64\"#
            + "FSD-Win64-Shipping.exe"

        #expect(scope.matches(process(shipping, in: bottle)))
        #expect(scope.matches(process(#"\\?\"# + shipping.lowercased(), in: bottle)))
        #expect(!scope.matches(process(#"C:\Program Files (x86)\Steam\steam.exe"#, in: bottle)))
        // A sibling folder whose name starts the same is another game.
        #expect(!scope.matches(process(
            #"C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic 2\game.exe"#, in: bottle
        )))
    }

    @Test("Another bottle's process never counts")
    func otherBottle() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let scope = GameProcessScope(bottleURL: bottle, folder: gameFolder(bottle), executable: nil, names: ["fsd.exe"])
        let other = HostWineProcess(
            pid: 2, imagePath: #"C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD.exe"#,
            prefixPath: "/tmp/another-bottle"
        )
        #expect(!scope.matches(other))
    }

    @Test("Z: is the host root, and a bare name falls back to the name list")
    func hostRootAndBareNames() {
        let bottle = URL(filePath: "/tmp/kadeh-scope-no-such-bottle")
        let folder = URL(filePath: "/tmp/kadeh-scope-games/Blur")
        let scope = GameProcessScope(bottleURL: bottle, folder: folder, executable: nil, names: ["blur.exe"])

        #expect(scope.matches(process(#"Z:\tmp\kadeh-scope-games\Blur\Blur.exe"#, in: bottle)))
        #expect(scope.matches(process("Blur.exe", in: bottle)))
        #expect(!scope.matches(process("other.exe", in: bottle)))
        // Wine's own host binaries are not programs.
        #expect(!scope.matches(process("/Applications/Kadeh.app/wineserver", in: bottle)))
    }

    @Test("A program is its own executable, not its folder")
    func programIsItsExecutable() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let exe = gameFolder(bottle).appending(path: "FSD.exe")
        let scope = GameProcessScope(bottleURL: bottle, folder: nil, executable: exe, names: [])

        #expect(scope.matches(process(
            #"C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD.exe"#, in: bottle
        )))
        #expect(!scope.matches(process(
            #"C:\Program Files (x86)\Steam\steamapps\common\Deep Rock Galactic\FSD\Binaries\Win64\x.exe"#, in: bottle
        )))
    }

    @Test("Names reach Unreal's Binaries folder and skip redistributables")
    func deepNames() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let names = GameProcessScope.executableNames(under: gameFolder(bottle))
        #expect(names == ["fsd.exe", "fsd-win64-shipping.exe"])
    }
}

@Suite("Running programs")
struct RunningProgramTests {
    @Test("A game and its helpers are one row, Wine's own processes are none")
    func grouping() {
        let bottle = URL(filePath: "/tmp/kadeh-running-test")
        let prefix = bottle.path(percentEncoded: false)
        let common = #"Z:\tmp\kadeh-running-games\Deep Rock Galactic"#
        let processes = [
            HostWineProcess(pid: 1, imagePath: common + #"\FSD.exe"#, prefixPath: prefix,
                            startedAt: Date(timeIntervalSince1970: 200)),
            HostWineProcess(pid: 2, imagePath: common + #"\FSD\Binaries\Win64\FSD-Win64-Shipping.exe"#,
                            prefixPath: prefix, startedAt: Date(timeIntervalSince1970: 100)),
            HostWineProcess(pid: 3, imagePath: #"C:\Program Files (x86)\Steam\steam.exe"#, prefixPath: prefix),
            HostWineProcess(pid: 4, imagePath: #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe"#,
                            prefixPath: prefix),
            HostWineProcess(pid: 5, imagePath: #"C:\windows\system32\services.exe"#, prefixPath: prefix),
            HostWineProcess(pid: 6, imagePath: "/Applications/Kadeh.app/wineserver", prefixPath: prefix),
            HostWineProcess(pid: 7, imagePath: #"C:\Games\Blur\Blur.exe"#, prefixPath: "/tmp/other-bottle")
        ]
        let folders = [HostWineProcesses.hostKey(URL(filePath: "/tmp/kadeh-running-games/Deep Rock Galactic")):
            "Deep Rock Galactic"]

        let rows = RunningProgram.group(processes, bottleURL: bottle, gameFolders: folders)

        #expect(rows.map(\.name) == ["Deep Rock Galactic", "Steam"])
        #expect(rows.first?.processes.count == 2)
        #expect(rows.first?.startedAt == Date(timeIntervalSince1970: 100))
        #expect(rows.first?.imageNames == ["fsd.exe", "fsd-win64-shipping.exe"])
    }
}

@Suite("Game process scope: folders and helpers")
struct GameProcessScopeFolderTests {
    private let bottle = URL(filePath: "/tmp/kadeh-shared-test")

    @Test("Shared folders keep a program to its executable")
    func sharedFolders() {
        let drive = bottle.appending(path: "drive_c")
        for shared in [bottle, drive, drive.appending(path: "Program Files"),
                       drive.appending(path: "Program Files (x86)"), drive.appending(path: "windows/system32"),
                       drive.appending(path: "Games"),
                       drive.appending(path: "users/crossover/Desktop")] {
            #expect(GameProcessScope.isSharedFolder(shared, bottleURL: bottle), "\(shared.path)")
        }
        for own in [drive.appending(path: "Program Files/Blur"), drive.appending(path: "Games/Blur"),
                    drive.appending(path: "users/crossover/AppData/Local/Programs/Game")] {
            #expect(!GameProcessScope.isSharedFolder(own, bottleURL: bottle), "\(own.path)")
        }
    }

    @Test("A program in its own folder counts its deeper executables, not its crash reporter")
    func programFolderAndHelpers() {
        let exe = bottle.appending(path: "drive_c/Games/Blur/Blur.exe")
        let entry = LibraryEntry(
            id: "pinned:blur", name: "Blur", iconURL: nil, bottleURL: bottle, source: .pinned, launch: .program(exe)
        )
        let scope = GameProcessScope.of(entry)
        let prefix = bottle.path(percentEncoded: false)
        func running(_ path: String) -> Bool {
            scope.matches(HostWineProcess(pid: 1, imagePath: path, prefixPath: prefix))
        }

        #expect(running(#"C:\Games\Blur\Blur.exe"#))
        #expect(running(#"C:\Games\Blur\Game\Binaries\Win64\Blur-Win64-Shipping.exe"#))
        #expect(!running(#"C:\Games\Blur\Engine\Binaries\Win64\CrashReportClient.exe"#))
        #expect(!running(#"C:\Games\Blur\_CommonRedist\vcredist\setup.exe"#))
        #expect(!running(#"C:\Games\Other\Blur.exe"#))
    }

    @Test("Only names no other process in the bottle shares are closed by name")
    @MainActor func askableNames() {
        let prefix = bottle.path(percentEncoded: false)
        let mine = HostWineProcess(pid: 1, imagePath: #"C:\Games\A\game.exe"#, prefixPath: prefix)
        let helper = HostWineProcess(pid: 2, imagePath: #"C:\Games\A\helper.exe"#, prefixPath: prefix)
        let other = HostWineProcess(pid: 3, imagePath: #"C:\Games\B\game.exe"#, prefixPath: prefix)

        #expect(GameCloser.askableNames([mine, helper], bottleProcesses: [mine, helper, other]) == ["helper.exe"])
        #expect(GameCloser.stillRunning([mine], in: [other]).isEmpty)
    }

    @Test("Playtime reads in hours from ten hours, rounded down")
    func playtimeFormat() {
        #expect(PlaytimeFormat.short(36_000) == PlaytimeFormat.short(39_599))
        #expect(PlaytimeFormat.short(7_140) != PlaytimeFormat.short(7_200))
        #expect(PlaytimeFormat.short(59) == PlaytimeFormat.short(0))
        #expect(!PlaytimeFormat.short(0).isEmpty)
    }
}
