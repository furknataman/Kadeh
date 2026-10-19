//
//  PerformanceOverlayTests.swift
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

@Suite("Performance Overlay")
struct PerformanceOverlayTests {
    @Test("The Metal HUD is on when either the bottle or the global overlay asks for it, compact only for the overlay")
    func metalHudIsGlobalOrBottle() {
        for (bottle, global) in [(false, false), (true, false), (false, true), (true, true)] {
            var settings = BottleSettings()
            settings.metalHud = bottle
            var builder = EnvironmentBuilder()
            _ = settings.populateBottleManagedLayer(builder: &builder, performanceOverlay: global)
            let environment = builder.resolve().environment
            #expect(environment["MTL_HUD_ENABLED"] == (bottle || global ? "1" : nil))
            #expect(environment["MTL_HUD_ELEMENTS"] == (global ? "fps,frameinterval,gputime" : nil))
            #expect(environment["MTL_HUD_SCALE"] == (global ? "0.15" : nil))
            #expect(environment["MTL_HUD_OPACITY"] == (global ? "0.85" : nil))
            #expect(environment["MTL_HUD_ALIGNMENT"] == (global ? "topright" : nil))
            #expect(environment["MTL_HUD_DISABLE_MENU_BAR"] == (global ? "1" : nil))
            #expect(environment["D3DM_SHOW_HUD_STATS"] == (global ? "0" : nil))
        }
    }

    @Test("Unreadable and implausible readings are left out of the panel")
    func implausibleReadingsAreDropped() {
        let sane = SystemSnapshot(
            cpuTemperature: 64.6, gpuTemperature: 50, cpuUsage: 12.4, gpuUsage: 99.6,
            memoryUsed: 34 << 30, memoryTotal: 64 << 30, fanSpeeds: [0, 1341.4]
        )
        #expect(sane.line == "CPU 65° 12% · GPU 50° 100% · RAM 34/64 GB · Fan 0/1341")

        let garbage = SystemSnapshot(
            cpuTemperature: -40, gpuTemperature: 3000, cpuUsage: nil, gpuUsage: 140,
            memoryUsed: 2, memoryTotal: 1, fanSpeeds: [65535]
        )
        #expect(garbage.line.isEmpty)
        #expect(SystemSnapshot(cpuUsage: 30).line == "CPU 30%")
    }
}
