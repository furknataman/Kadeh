//
//  ActivityView.swift
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

import SwiftUI
import WhiskyKit

/// The Etkinlik window: which bottles are up, what runs in them, and a way
/// to close one program or everything.
///
/// Everything here comes from the host process list (``HostWineProcesses``),
/// which costs nothing and starts nothing. Asking a bottle with
/// `tasklist.exe` would start its wineserver just to learn that it is idle,
/// so that only happens on "Kapat", and only while the bottle's wineserver
/// answers (``GameCloser``).
struct ActivityView: View {
    @EnvironmentObject private var bottleVM: BottleVM
    @StateObject private var model = ActivityModel()
    @State private var programToClose: RunningProgram?
    @State private var confirmStopAll = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if model.programs.isEmpty {
                        Group {
                            if model.hasLoaded {
                                Text("activity.nothingRunning")
                            } else {
                                Text("activity.checking")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    } else {
                        ForEach(model.programs) { program in
                            RunningProgramRow(
                                program: program,
                                bottleName: bottleName(for: program.bottleURL),
                                isClosing: model.closing.contains(program.id),
                                now: model.lastRefresh
                            ) {
                                programToClose = program
                            }
                        }
                    }
                } header: {
                    Text("activity.programs")
                }
                Section {
                    ForEach(bottleVM.bottles) { bottle in
                        BottleStatusRow(
                            name: bottle.settings.name,
                            isRunning: model.runningBottles.contains(bottle.url),
                            engine: model.engineName
                        )
                    }
                } header: {
                    Text("activity.bottles")
                }

            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
        .task {
            // Tied to the window being open: SwiftUI cancels it on close.
            await model.poll(bottles: { bottleVM.bottles })
        }
        .confirmationDialog(
            programToClose.map { String(localized: "activity.close.title \($0.name)") } ?? "",
            isPresented: Binding(get: { programToClose != nil }, set: { if !$0 { programToClose = nil } }),
            titleVisibility: .visible,
            presenting: programToClose
        ) { program in
            Button("activity.close.confirm", role: .destructive) {
                guard let bottle = bottleVM.bottles.first(where: { $0.url == program.bottleURL }) else { return }
                Task { await model.close(program, in: bottle) }
            }
            Button("activity.cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("activity.close.message")
        }
        .confirmationDialog(
            String(localized: "activity.stopAll.title"),
            isPresented: $confirmStopAll,
            titleVisibility: .visible
        ) {
            Button("activity.stopAll.confirm", role: .destructive) {
                let running = bottleVM.bottles.filter { model.runningBottles.contains($0.url) }
                Task { await model.stopAll(running) }
            }
            Button("activity.cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("activity.stopAll.message")
        }
    }

    private var footer: some View {
        HStack {
            Button("activity.openLogs") {
                WhiskyApp.openLogsFolder()
            }
            .help("activity.openLogs.help")

            Spacer()

            if model.isStoppingAll {
                ProgressView()
                    .controlSize(.small)
                Text("activity.stopping")
                    .foregroundStyle(.secondary)
            }
            // Not red and not next to the rows: closing everything is the
            // exception, and its dialog carries the warning.
            Button("activity.stopAll") {
                confirmStopAll = true
            }
            .disabled(model.runningBottles.isEmpty || model.isStoppingAll)
            .help("activity.stopAll.help")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func bottleName(for url: URL) -> String {
        bottleVM.bottles.first { $0.url == url }?.settings.name ?? url.lastPathComponent
    }
}

/// One bottle: a dot and a word for whether it is up, and what it runs on.
private struct BottleStatusRow: View {
    let name: String
    let isRunning: Bool
    let engine: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let status = String(localized: isRunning ? "activity.bottle.running" : "activity.bottle.stopped")
        guard let engine else { return status }
        return "\(status) · \(engine)"
    }
}

/// One running program with its bottle, how long it has been open, and Kapat.
private struct RunningProgramRow: View {
    let program: RunningProgram
    let bottleName: String
    let isClosing: Bool
    let now: Date
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if isClosing {
                ProgressView()
                    .controlSize(.small)
                Text("activity.closing")
                    .foregroundStyle(.secondary)
            } else {
                Button("activity.close", action: close)
                    .accessibilityLabel(Text("activity.close.accessibility \(program.name)"))
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        let bottle = String(localized: "activity.program.bottle \(bottleName)")
        guard let started = program.startedAt else { return bottle }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        let elapsed = max(now.timeIntervalSince(started), 60)
        formatter.allowedUnits = elapsed >= 3_600 ? [.hour, .minute] : [.minute]
        let duration = formatter.string(from: elapsed) ?? ""
        return bottle + " · " + String(localized: "activity.program.openFor \(duration)")
    }
}

/// Polls the host process list while the window is open, and closes things.
@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var runningBottles: Set<URL> = []
    @Published private(set) var programs: [RunningProgram] = []
    @Published private(set) var engineName: String?
    @Published private(set) var closing: Set<String> = []
    @Published private(set) var isStoppingAll = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastRefresh = Date()

    /// Steam install folders per bottle, keyed as ``HostWineProcesses/hostKey(_:)``
    /// writes them, so a game's processes read as its name.
    private var gameFolders: [URL: [String: String]] = [:]

    /// Refreshes every three seconds until the task is cancelled.
    func poll(bottles: @escaping @MainActor () -> [Bottle]) async {
        if engineName == nil {
            engineName = await Task.detached { Self.engineDescription() }.value
        }
        while !Task.isCancelled {
            await refresh(bottles: bottles())
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh(bottles: [Bottle]) async {
        let snapshot = await HostWineProcesses.current()
        var running: Set<URL> = []
        var found: [RunningProgram] = []
        for bottle in bottles where snapshot.contains(where: { $0.belongs(to: bottle.url) }) {
            running.insert(bottle.url)
            let folders = await folders(for: bottle.url)
            found += RunningProgram.group(snapshot, bottleURL: bottle.url, gameFolders: folders)
        }
        runningBottles = running
        programs = found
        lastRefresh = Date()
        hasLoaded = true
    }

    private func folders(for bottleURL: URL) async -> [String: String] {
        if let cached = gameFolders[bottleURL] { return cached }
        let folders = await Task.detached {
            Dictionary(
                SteamLibrary.enumerate(bottleURL: bottleURL)
                    .map { (HostWineProcesses.hostKey($0.installURL), $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        }.value
        gameFolders[bottleURL] = folders
        return folders
    }

    /// Closes exactly this row's processes, through ``GameCloser``: asked
    /// first, ended from the host after its grace period, and no Wine call
    /// once the bottle has stopped.
    func close(_ program: RunningProgram, in bottle: Bottle) async {
        closing.insert(program.id)
        defer { closing.remove(program.id) }
        await GameCloser.close(program.processes, in: bottle)
        await refresh(bottles: BottleVM.shared.bottles)
    }

    /// Stops every running bottle the way the Stop All menu item does.
    func stopAll(_ bottles: [Bottle]) async {
        isStoppingAll = true
        defer { isStoppingAll = false }
        for bottle in bottles {
            // `wineserver -k` is only sent to a server that answers the
            // `-k0` probe, which starts nothing.
            if await Wine.isWineserverRunning(for: bottle) {
                Wine.killBottle(bottle: bottle)
            }
            ProcessRegistry.shared.clearRegistry(for: bottle.url)
        }
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(500))
            let snapshot = await HostWineProcesses.current()
            if !bottles.contains(where: { bottle in snapshot.contains { $0.belongs(to: bottle.url) } }) { break }
        }
        await refresh(bottles: BottleVM.shared.bottles)
    }

    /// "Wine 10.0.6", or nil before a runtime is installed.
    nonisolated static func engineDescription() -> String? {
        guard let version = WhiskyWineInstaller.whiskyWineInfo()?.version else { return nil }
        return "Wine \(version.major).\(version.minor).\(version.patch)"
    }
}
