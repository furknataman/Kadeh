//
//  BottleActionBar.swift
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
import UniformTypeIdentifiers
import WhiskyKit

/// The four actions along the bottom of a bottle.
struct BottleActionBar: View {
    @ObservedObject var bottle: Bottle
    @Binding var showWinetricksSheet: Bool
    @Binding var programLoading: Bool
    @Binding var toast: ToastData?
    /// Called after a launch so the caller can refresh what it keeps in step
    /// with the prefix, the start menu among it.
    let onLaunch: () async -> Void

    /// The bar's four actions.
    ///
    /// Running a program is the reason the app exists, so it is the only
    /// prominent control here; the other three were visually identical to it
    /// before, which made opening a terminal look as important as launching a
    /// game.
    ///
    /// Liquid Glass where the system has it. GlassEffectContainer is macOS 26
    /// only and is what lets the capsules blend instead of stacking their own
    /// layers, so the older path is the same buttons in bordered styles, which
    /// still carries the emphasis.
    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                buttons
            }
        } else {
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button("button.cDrive") {
                bottle.openCDrive()
            }
            .glassButton()
            .accessibilityIdentifier("bottle.openCDrive")
            Button("button.terminal") {
                bottle.openTerminal()
            }
            .glassButton()
            .accessibilityIdentifier("bottle.openTerminal")
            Button("button.winetricks") {
                showWinetricksSheet.toggle()
            }
            .glassButton()
            .accessibilityIdentifier("bottle.openWinetricks")
            Button("button.installFromArchive") {
                installFromArchive()
            }
            .glassButton()
            .help("button.installFromArchive.help")
            .accessibilityIdentifier("bottle.installFromArchive")
            .disabled(programLoading)
            Button("button.run") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = Self.programTypes
                panel.directoryURL = bottle.url.appending(path: "drive_c")
                panel.begin { result in
                    programLoading = true
                    Task(priority: .userInitiated) {
                        if result == .OK, let url = panel.urls.first {
                            await run(url)
                        } else {
                            await MainActor.run {
                                programLoading = false
                            }
                        }
                        await onLaunch()
                    }
                }
            }
            // Running a program is the reason the app exists, so it is
            // the only prominent control on this bar.
            .glassButton(prominent: true)
            .accessibilityIdentifier("bottle.runProgram")
            .disabled(programLoading)
            if programLoading {
                Spacer()
                    .frame(width: 10)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
    }

    private static let programTypes: [UTType] = [
        UTType.exe,
        UTType(exportedAs: "com.microsoft.msi-installer"),
        UTType(exportedAs: "com.microsoft.bat"),
        UTType(exportedAs: "com.microsoft.msix-package"),
        UTType(exportedAs: "com.microsoft.appx-package"),
        UTType(exportedAs: "com.microsoft.windows-internet-shortcut")
    ]

    /// Runs one program in the bottle and reports the outcome as a toast.
    @discardableResult
    private func run(_ url: URL) async -> Bool {
        var launched = false
        do {
            // Auto-detect launcher and apply fixes if compatibility mode enabled
            // This completes synchronously on MainActor, ensuring settings are
            // persisted before Wine.runProgram() reads them
            LauncherFixes.detectAndApply(from: url, for: bottle)

            Telemetry.capture(.firstProgramLaunchAttempted)
            if url.pathExtension == "bat" {
                try await Wine.runBatchFile(url: url, bottle: bottle)
            } else {
                try await Wine.runProgram(at: url, bottle: bottle)
            }
            launched = true
            await MainActor.run {
                withAnimation {
                    toast = ToastData(
                        message: String(localized: "status.launched \(url.lastPathComponent)"),
                        style: .success
                    )
                }
            }
        } catch {
            let errDesc = error.localizedDescription
            await MainActor.run {
                withAnimation {
                    toast = ToastData(
                        message: String(localized: "status.launchFailed \(errDesc)"),
                        style: .error,
                        autoDismiss: false
                    )
                }
            }
        }
        await MainActor.run {
            programLoading = false
        }
        return launched
    }

    /// Picks an archive, unpacks it into the bottle and starts the installer inside.
    private func installFromArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ArchiveInstaller.archiveExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in
            guard result == .OK, let archive = panel.urls.first else { return }
            programLoading = true
            Task(priority: .userInitiated) {
                await installArchive(archive)
                await onLaunch()
            }
        }
    }

    private func installArchive(_ archive: URL) async {
        let name = archive.lastPathComponent
        await MainActor.run {
            // Archives can be several GB, so the toast stays until extraction ends.
            withAnimation {
                toast = ToastData(
                    message: String(localized: "status.extracting \(name)"),
                    style: .info,
                    autoDismiss: false
                )
            }
        }
        let bottleURL = bottle.url
        let extraction = await Task.detached(priority: .userInitiated) {
            () -> Result<(folder: URL, programs: [URL]), Error> in
            do {
                let folder = try ArchiveInstaller.extract(archive, bottleURL: bottleURL)
                return .success((folder, ArchiveInstaller.programs(in: folder)))
            } catch {
                return .failure(error)
            }
        }.value

        switch extraction {
        case .failure(let error):
            let errDesc = error.localizedDescription
            await MainActor.run {
                withAnimation {
                    toast = ToastData(
                        message: String(localized: "status.extractFailed \(errDesc)"),
                        style: .error,
                        autoDismiss: false
                    )
                }
                programLoading = false
            }
        case .success(let (folder, programs)):
            await MainActor.run { withAnimation { toast = nil } }
            if programs.isEmpty {
                await MainActor.run {
                    withAnimation {
                        toast = ToastData(
                            message: String(localized: "status.noProgramInArchive"),
                            style: .error
                        )
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                    programLoading = false
                }
            } else {
                // Runtimes and uninstallers never start the game, so they are
                // left out of the automatic pick; the picker still shows them.
                let usable = programs.filter { !ArchiveInstaller.isRedistributable($0, base: folder) }
                if let first = usable.first, ArchiveInstaller.isInstaller(first) || usable.count == 1 {
                    await start(first)
                } else if let url = await chooseProgram(in: folder) {
                    await start(url)
                } else {
                    await MainActor.run { programLoading = false }
                }
            }
        }
    }

    /// Runs a program from an extracted archive. A setup gets a hint on where the
    /// game shows up afterwards; anything else is the game itself, so it is
    /// pinned first and lands in the library.
    private func start(_ url: URL) async {
        let installer = ArchiveInstaller.isInstaller(url)
        if !installer {
            await MainActor.run {
                if !bottle.settings.pins.contains(where: { $0.url == url }) {
                    bottle.settings.pins.append(PinnedProgram(name: url.deletingPathExtension().lastPathComponent, url: url))
                }
            }
        }
        guard await run(url), installer else { return }
        await MainActor.run {
            withAnimation {
                toast = ToastData(
                    message: String(localized: "status.installerStarted"),
                    style: .info,
                    autoDismiss: false
                )
            }
        }
    }

    @MainActor
    private func chooseProgram(in folder: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.programTypes
        panel.directoryURL = folder
        panel.message = String(localized: "archive.chooseProgram")
        return await withCheckedContinuation { continuation in
            panel.begin { result in
                continuation.resume(returning: result == .OK ? panel.urls.first : nil)
            }
        }
    }
}

private extension View {
    /// Glass on macOS 26, bordered before it. The emphasis is the point and it
    /// survives either way.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}
