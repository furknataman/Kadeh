//
//  SettingsView.swift
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

struct SettingsView: View {
    @AppStorage("SUEnableAutomaticChecks") var whiskyUpdate = true
    @AppStorage("killOnTerminate") var killOnTerminate = true
    @AppStorage("showMenuBarExtra") var showMenuBarExtra = false
    @AppStorage(PerformanceOverlay.defaultsKey) var performanceOverlay = false
    @AppStorage("checkWhiskyWineUpdates") var checkWhiskyWineUpdates = true
    @AppStorage("defaultBottleLocation") var defaultBottleLocation = BottleData.defaultBottleDir
    @AppStorage("preferredTerminal") var preferredTerminal = "terminal"
    /// Empty means the default, which follows iCloud Drive being on or off.
    @AppStorage(SaveBackupStore.rootDefaultsKey) private var saveBackupRoot = ""
    /// A backup folder refused because it and a game's save folder are inside one another.
    @State private var refusedBackupFolder = false
    @AppStorage(Telemetry.consentDefaultsKey) private var telemetryConsentRaw: String = Telemetry.ConsentState
        .undecided.rawValue

    /// Mirrors the setup-flow opt-in; writing records the explicit choice.
    private var telemetryOptIn: Binding<Bool> {
        Binding(
            get: { telemetryConsentRaw == Telemetry.ConsentState.granted.rawValue },
            set: { Telemetry.setConsent(granted: $0) }
        )
    }

    var body: some View {
        Form {
            Section("settings.general") {
                Toggle("settings.toggle.kill.on.terminate", isOn: $killOnTerminate)
                Toggle("settings.toggle.menubar", isOn: $showMenuBarExtra)
                    .help("settings.toggle.menubar.help")
                Toggle(isOn: $performanceOverlay) {
                    Text("settings.toggle.performanceOverlay")
                    Text("settings.toggle.performanceOverlay.info")
                }
                Picker("settings.terminal", selection: $preferredTerminal) {
                    // installedTerminals should always include Terminal.app on macOS,
                    // but fall back to showing just Terminal if somehow empty
                    let terminals = TerminalApp.installedTerminals
                    ForEach(terminals.isEmpty ? [.terminal] : terminals) { terminal in
                        Text(terminal.displayName).tag(terminal.rawValue)
                    }
                }
                ActionView(
                    text: "settings.path",
                    subtitle: defaultBottleLocation.prettyPath(),
                    actionName: "create.browse"
                ) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = BottleData.containerDir
                    panel.begin { result in
                        if result == .OK, let url = panel.urls.first {
                            defaultBottleLocation = url
                        }
                    }
                }
            }
            Section("settings.saves") {
                LabeledContent {
                    HStack {
                        Button("settings.saves.showInFinder") { revealSaveBackups() }
                        Button("settings.saves.change") { chooseSaveBackupFolder() }
                    }
                } label: {
                    Text("settings.saves.location")
                    Text(SavePlaceText.location(saveBackupFolder))
                }
                Text("settings.saves.info")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("settings.updates") {
                Toggle("settings.toggle.whisky.updates", isOn: $whiskyUpdate)
                Toggle("settings.toggle.whiskywine.updates", isOn: $checkWhiskyWineUpdates)
            }
            GPTKSettingsSection()
            Section("settings.privacy") {
                Toggle("settings.toggle.telemetry", isOn: telemetryOptIn)
                    .help("setup.telemetry.consent.help")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ViewWidth.medium)
        .alert("settings.saves.refused.title", isPresented: $refusedBackupFolder) {
            Button("settings.saves.refused.ok", role: .cancel) {}
        } message: {
            Text("settings.saves.refused.message")
        }
    }

    private var saveBackupFolder: URL {
        saveBackupRoot.isEmpty
            ? SaveBackupStore.defaultRoot
            : URL(filePath: saveBackupRoot, directoryHint: .isDirectory)
    }

    private func revealSaveBackups() {
        let folder = saveBackupFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func chooseSaveBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveBackupFolder.deletingLastPathComponent()
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            // Backups kept inside a save folder would be replaced, and could
            // be lost, when that folder is restored.
            let saves = SaveFolderStore().knownLocations()
            if saves.contains(where: { SaveBackupStore.overlap($0, url) }) {
                refusedBackupFolder = true
            } else {
                saveBackupRoot = url.path(percentEncoded: false)
            }
        }
    }
}

#Preview {
    SettingsView()
}
