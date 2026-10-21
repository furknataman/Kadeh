//
//  SwitchSetupSheet.swift
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
import UniformTypeIdentifiers
import WhiskyKit

/// The four steps that make Switch games playable, each with whether it is
/// done and the one button that does it.
///
/// One sheet whatever opened it: the library's toolbar, an empty library,
/// Settings, or a press of Play that found a step missing, which is named in
/// orange at the top. The steps can be done in any order; the first one left
/// has the prominent button, so there is always one obvious thing to do.
struct SwitchSetupSheet: View {
    typealias Step = SwitchEmulator.Step

    /// The step a press of Play found missing, until it is done.
    let notice: Step?
    /// Starts the game whose Play opened the sheet; offered once nothing it needs is missing.
    var play: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Read from disk on appear and after each step: nothing announces a change.
    @State private var done: Set<Step> = []
    @State private var version: String?
    @State private var gameCount: Int?
    @State private var working: Set<Step> = []
    /// The running download, so it can be called off: the sheet cannot be
    /// closed mid-step, and a slow line must not trap the person in it.
    @State private var installTask: Task<Void, Never>?
    /// The download's fraction done; 0 until the server has said how big it is.
    @State private var downloaded: Double = 0
    @State private var errors: [Step: String] = [:]

    private var next: Step? { Step.allCases.first { !done.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("switch.setup.title")
                    .font(.title2.bold())
                Text("switch.setup.intro")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Always the next thing playing still needs, so the line does not
                // vanish while other steps are left.
                if notice != nil, let missing = [Step.emulator, .keys, .firmware].first(where: { !done.contains($0) }),
                   let text = noticeText(missing) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Step.allCases) { step in
                    row(step)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 16) {
                Text("switch.setup.ownFiles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                footerButton
                    .controlSize(.large)
                    // Closed mid-step, a reopened sheet would not know and could start the same step twice.
                    .disabled(!working.isEmpty)
            }
            .padding(16)
        }
        .frame(width: ViewWidth.medium)
        .interactiveDismissDisabled(!working.isEmpty)
        .task {
            refresh()
            await countGames()
        }
    }

    /// "Oyna" when Play opened the sheet and the game can now start; "Bitti"
    /// when every step is done; "Kapat" otherwise, so closing early never
    /// reads as being finished. Only the first two are blue and take Return:
    /// while a step is left, its button is the one obvious thing to press.
    @ViewBuilder
    private var footerButton: some View {
        if let play, [Step.emulator, .keys, .firmware].allSatisfy(done.contains) {
            Button("library.card.play") {
                dismiss()
                play()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else if next == nil {
            Button("switch.setup.done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("switch.setup.close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Rows

    private func row(_ step: Step) -> some View {
        let isDone = done.contains(step)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle")
                .font(.title2)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
                // The detail line says done or not in words.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title(step))
                    .font(.headline)
                detail(step)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if working.contains(step) {
                    progress(step)
                } else {
                    button(step)
                }
                if let error = errors[step] {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func title(_ step: Step) -> LocalizedStringKey {
        switch step {
        case .emulator: "switch.step.emulator.title"
        case .keys: "switch.step.keys.title"
        case .firmware: "switch.step.firmware.title"
        case .games: "switch.step.games.title"
        }
    }

    @ViewBuilder
    private func detail(_ step: Step) -> some View {
        let isDone = done.contains(step)
        switch step {
        case .emulator:
            if isDone, let version {
                Text("switch.step.emulator.done \(version)")
            } else {
                Text("switch.step.emulator.missing")
            }
        case .keys:
            Text(isDone ? "switch.step.keys.done" : "switch.step.keys.missing")
        case .firmware:
            Text(isDone ? "switch.step.firmware.done" : "switch.step.firmware.missing")
        case .games:
            if gameCount == 0 {
                Text("switch.step.games.none")
            } else if !isDone {
                Text("switch.step.games.missing")
            } else if let gameCount {
                Text("switch.step.games.done \(gameCount)")
                    .help(SwitchEmulator.gamesFolder?.path(percentEncoded: false) ?? "")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// What a press of Play said was missing. The games folder never is:
    /// a game being played came from it.
    private func noticeText(_ step: Step) -> LocalizedStringKey? {
        switch step {
        case .emulator: "switch.notice.emulator"
        case .keys: "switch.notice.keys"
        case .firmware: "switch.notice.firmware"
        case .games: nil
        }
    }

    /// The button's title, `nil` for the emulator once the pinned build is in.
    /// A Kadeh that pins a newer emulator shows it again, as the way to update.
    /// A done step keeps a "Değiştir…" button: keys and firmware get replaced
    /// after a console update.
    private func actionTitle(_ step: Step) -> String? {
        if step == .emulator {
            if version == SwitchEmulator.pinned.version { return nil }
            if errors[.emulator] != nil { return String(localized: "switch.step.emulator.retry") }
            return version == nil
                ? String(localized: "switch.step.emulator.action") : String(localized: "switch.step.emulator.update")
        }
        if done.contains(step) { return String(localized: "switch.step.change") }
        switch step {
        case .keys: return String(localized: "switch.step.keys.action")
        case .firmware: return String(localized: "switch.step.firmware.action")
        case .games, .emulator: return String(localized: "switch.step.games.action")
        }
    }

    @ViewBuilder
    private func button(_ step: Step) -> some View {
        if let title = actionTitle(step) {
            let button = Button(title) { act(step) }
                .controlSize(.large)
            if step == next {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func progress(_ step: Step) -> some View {
        HStack(spacing: 12) {
            if step == .emulator, downloaded > 0 {
                ProgressView("switch.step.emulator.downloading", value: downloaded)
            } else {
                // The download can take a while to report a size, and copying
                // reports nothing, so a spinner rather than an empty bar.
                ProgressView()
                    .controlSize(.small)
                Text(step == .emulator ? "switch.step.emulator.downloading" : "switch.step.firmware.copying")
            }
            if step == .emulator {
                Button("switch.step.cancel") { installTask?.cancel() }
            }
        }
    }

    // MARK: - Actions

    private func act(_ step: Step) {
        errors[step] = nil
        switch step {
        case .emulator: install()
        case .keys: importKeys()
        case .firmware: importFirmware()
        case .games: chooseGamesFolder()
        }
    }

    private func install() {
        working.insert(.emulator)
        downloaded = 0
        installTask = Task {
            do {
                try await SwitchEmulator.install { fraction in
                    Task { @MainActor in downloaded = fraction }
                }
            } catch is CancellationError {
                // Called off with "Vazgeç": nothing went wrong.
            } catch {
                errors[.emulator] = Self.message(for: error)
            }
            installTask = nil
            working.remove(.emulator)
            refresh()
        }
    }

    private func importKeys() {
        guard let file = choose(.keys) else { return }
        do {
            try SwitchEmulator.importKeys(from: file)
        } catch {
            errors[.keys] = Self.message(for: error)
        }
        refresh()
    }

    private func importFirmware() {
        guard let source = choose(.firmware) else { return }
        working.insert(.firmware)
        Task {
            do {
                try await SwitchEmulator.importFirmware(from: source)
            } catch {
                errors[.firmware] = Self.message(for: error)
            }
            working.remove(.firmware)
            refresh()
        }
    }

    private func chooseGamesFolder() {
        guard let folder = choose(.games) else { return }
        SwitchEmulator.gamesFolder = folder
        refresh()
        Task { await countGames() }
    }

    /// An open panel for the step. Its button says what the row's button
    /// said, without the "…": the choosing is done there.
    private func choose(_ step: Step) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        let prompt: String.LocalizationValue
        switch step {
        case .keys:
            prompt = "switch.step.keys.action"
            panel.message = String(localized: "switch.step.keys.missing")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            // Every other file on the stick greyed out, so the right one stands out.
            panel.allowedContentTypes = [UTType(filenameExtension: "keys") ?? .data]
        case .firmware:
            prompt = "switch.step.firmware.action"
            panel.message = String(localized: "switch.step.firmware.missing")
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.zip, .folder]
        case .games:
            prompt = "switch.step.games.action"
            panel.message = String(localized: "switch.step.games.missing")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = SwitchEmulator.gamesFolder
        case .emulator:
            return nil
        }
        panel.prompt = String(localized: prompt).trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func refresh() {
        // A folder with no games in it is not done: the library would stay empty.
        done = Set(Step.allCases.filter(SwitchEmulator.isDone)).subtracting(gameCount == 0 ? [.games] : [])
        version = SwitchEmulator.installedVersion()
    }

    /// Off the main actor: the first scan of a folder also draws the covers.
    private func countGames() async {
        gameCount = nil
        guard let folder = SwitchEmulator.gamesFolder, SwitchEmulator.isDone(.games) else { return }
        let count = await Task.detached { SwitchLibrarySource.entries(in: folder).count }.value
        // A folder chosen again meanwhile has its own count coming.
        if SwitchEmulator.gamesFolder == folder {
            gameCount = count
            refresh()
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? SwitchEmulator.SetupError {
        case .unreachable: String(localized: "switch.error.unreachable")
        case .mismatch: String(localized: "switch.error.mismatch")
        case .badArchive: String(localized: "switch.error.badArchive")
        case .notKeys: String(localized: "switch.error.notKeys")
        case .notFirmware: String(localized: "switch.error.notFirmware")
        // A disk that is full or a folder that cannot be written: nothing the person chose wrong.
        case nil: String(localized: "switch.error.generic")
        }
    }
}
