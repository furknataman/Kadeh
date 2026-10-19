//
//  PerformanceOverlayPanel.swift
//  Whisky
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

import AppKit
import SwiftUI
import WhiskyKit

/// The performance overlay's system panel: a one-line click-through window in
/// the top-left corner, above full-screen games, refreshed every second while
/// the setting is on and a Windows program is running. The top-right corner is
/// the compact Metal HUD's.
@MainActor
final class PerformanceOverlayPanel {
    static let shared = PerformanceOverlayPanel()

    private let content = NSHostingView(rootView: PerformanceOverlayView(line: ""))
    private var panel: NSPanel?
    private var sensors: SystemSensors?

    func start() {
        Task {
            while true {
                update()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func update() {
        guard PerformanceOverlay.isEnabled, Self.wineIsRunning() else {
            panel?.orderOut(nil)
            sensors = nil
            return
        }
        let sensors = sensors ?? SystemSensors()
        self.sensors = sensors
        let panel = panel ?? makePanel()
        self.panel = panel

        content.rootView = PerformanceOverlayView(line: sensors.sample().line)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            // Below the notch's band, where there is one.
            let size = content.fittingSize
            let top = screen.frame.maxY - screen.safeAreaInsets.top
            let origin = NSPoint(x: screen.frame.minX + 8, y: top - size.height - 8)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = content
        return panel
    }

    /// Whether a program from Kadeh's own Wine is running, whether the app or
    /// WhiskyCmd started it. `ProcessRegistry` is asked first, but nothing
    /// registers into it yet, so the bottle's wineserver, which lives exactly as
    /// long as its Windows programs, is what actually answers.
    private static func wineIsRunning() -> Bool {
        if ProcessRegistry.shared.getAllProcesses().values.contains(where: { !$0.isEmpty }) {
            return true
        }
        let wineserver = WhiskyWineInstaller.binFolder.appending(path: "wineserver").path(percentEncoded: false)
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var path = [UInt8](repeating: 0, count: 4096)
        return pids.prefix(max(count, 0)).contains { pid in
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            return length > 0 && String(decoding: path.prefix(length), as: UTF8.self) == wineserver
        }
    }
}

private struct PerformanceOverlayView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .environment(\.colorScheme, .dark)
    }
}
