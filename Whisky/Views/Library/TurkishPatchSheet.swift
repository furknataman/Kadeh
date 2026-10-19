//
//  TurkishPatchSheet.swift
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

// ponytail: Türkçe-only feature, no catalog keys
/// Lists the known Turkish patches of one Steam game and installs or removes them.
struct TurkishPatchSheet: View {
    /// A verified archive waiting for the user's go-ahead, or for the installer to finish.
    struct Pending {
        let patch: TurkishPatch
        let archive: URL
        let size: Int64
    }

    enum Step {
        case list
        case confirm(Pending)
        case installer(Pending)
    }

    let row: LibraryRow
    let bottle: Bottle?

    @Environment(\.dismiss) private var dismiss
    @State private var patches: [TurkishPatch] = []
    @State private var gameURL: URL?
    @State private var statuses: [String: TurkishPatchStatus] = [:]
    @State private var step: Step = .list
    @State private var busy = false
    @State private var message: String?
    @State private var errorText: String?
    @State private var removing: TurkishPatch?

    private var appID: Int? {
        if case let .steam(appID) = row.item.launch { return appID }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "Türkçe Yama · \(row.item.name)").font(.title2.bold())
                    if busy { ProgressView().controlSize(.small) }
                    if let message { Text(verbatim: message).foregroundStyle(.green) }
                    if let errorText { Text(verbatim: errorText).foregroundStyle(.red) }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button { dismiss() } label: { Text(verbatim: "Kapat") }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
        .task { await load() }
        .alert(Text(verbatim: "Türkçe yama kaldırılsın mı?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button(role: .destructive) {
                if let patch = removing { remove(patch) }
                removing = nil
            } label: { Text(verbatim: "Kaldır") }
            Button(role: .cancel) { removing = nil } label: { Text(verbatim: "Vazgeç") }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .list:
            if patches.isEmpty {
                noPatches
            } else {
                ForEach(patches) { patch in patchRow(patch) }
            }
        case let .confirm(pending):
            confirmation(pending)
        case let .installer(pending):
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Yükleyicideki kurulumu bitirip pencereyi kapattıysanız "
                     + "aşağıdaki düğmeye basın.")
                Button { finish(pending) } label: { Text(verbatim: "Yükleyici bitti") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
    }

    private var noPatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Bu oyun için Kadeh'in bildiği bir Türkçe yama yok.")
            Button { searchOnSite() } label: { Text(verbatim: "turkceyama.com'da ara") }
        }
    }

    private func patchRow(_ patch: TurkishPatch) -> some View {
        let status = statuses[patch.id] ?? .notInstalled
        let installed = status != .notInstalled
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: patch.source).bold()
            Text(verbatim: [patch.translator, patch.kind, accessLabel(patch.access)]
                .compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            if let note = patch.note { Text(verbatim: note).font(.callout) }
            if status == .installed { Text(verbatim: "Kurulu").foregroundStyle(.green) }
            if status == .gameUpdated {
                Text(verbatim: "Oyun güncellenmiş, yama bozulmuş olabilir").foregroundStyle(.orange)
            }
            HStack {
                Button { NSWorkspace.shared.open(patch.pageURL) } label: { Text(verbatim: "Sayfayı aç") }
                if installed {
                    Button { removing = patch } label: { Text(verbatim: "Kaldır") }
                }
                if patch.isInstallable && status != .installed {
                    Button { begin(patch) } label: { Text(verbatim: "Kur…") }
                }
            }
            .disabled(busy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func accessLabel(_ access: TurkishPatch.Access) -> String {
        switch access {
        case .free: "Ücretsiz"
        case .paid: "Ücretli"
        case .account: "Hesap gerekiyor"
        }
    }

    private func confirmation(_ pending: Pending) -> some View {
        let patch = pending.patch
        return VStack(alignment: .leading, spacing: 8) {
            field("Kaynak", patch.pageURL.absoluteString)
            field("Dosya", pending.archive.path)
            field("Boyut", ByteCountFormatter.string(fromByteCount: pending.size, countStyle: .file))
            field("SHA-256", "doğrulandı")
            field("Çalıştırılacak program", patch.installer ?? "")
            field("Değiştirilecek dosyalar", patch.modifiedFiles.joined(separator: "\n"))
            field("Eklenecek dosyalar", patch.addedFiles.joined(separator: "\n"))
            if let gameURL, let bottle {
                let path = TurkishPatchManager.windowsPath(of: gameURL, bottleURL: bottle.url)
                Text(verbatim: "Yükleyicide oyun klasörü olarak şunu seçin:")
                HStack {
                    Text(verbatim: path).textSelection(.enabled).font(.system(.body, design: .monospaced))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    } label: { Text(verbatim: "Kopyala") }
                }
            }
            HStack {
                Button { step = .list } label: { Text(verbatim: "Vazgeç") }
                Button { install(pending) } label: { Text(verbatim: "Kur") }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(busy)
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value.isEmpty ? "-" : value).textSelection(.enabled)
        }
    }

    // MARK: Actions

    private func load() async {
        guard let appID else { return }
        let bottleURL = row.item.bottleURL
        let found = await Task.detached {
            let patches = GameDBLoader.loadDefaults().first { $0.steamAppId == appID }?.turkishPatches ?? []
            let game = SteamLibrary.enumerate(bottleURL: bottleURL).first { $0.appId == appID }?.installURL
            return (patches, game)
        }.value
        patches = found.0
        gameURL = found.1
        await refreshStatuses()
    }

    private func refreshStatuses() async {
        guard let gameURL else { return }
        let patches = patches
        statuses = await Task.detached {
            Dictionary(uniqueKeysWithValues: patches.map {
                ($0.id, TurkishPatchManager.status(of: $0, gameURL: gameURL))
            })
        }.value
    }

    private func searchOnSite() {
        let query = row.item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://turkceyama.com/ara?q=\(query)") { NSWorkspace.shared.open(url) }
    }

    private func begin(_ patch: TurkishPatch) {
        guard let file = patch.file else { return }
        guard gameURL != nil, bottle != nil else {
            errorText = "Oyun klasörü bulunamadı."
            return
        }
        message = nil
        errorText = nil
        busy = true
        Task {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            var archive: URL?
            if let downloads {
                archive = await Task.detached { TurkishPatchManager.findDownload(file, in: downloads) }.value
            }
            if archive == nil {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.directoryURL = downloads
                if panel.runModal() == .OK { archive = panel.url }
            }
            guard let archive else {
                busy = false
                return
            }
            let digest = try? await Task.detached { try TurkishPatchManager.sha256(of: archive) }.value
            busy = false
            guard digest == file.sha256.lowercased() else {
                errorText = "Seçilen dosya beklenen dosya değil (SHA-256 eşleşmedi)."
                return
            }
            step = .confirm(Pending(patch: patch, archive: archive, size: file.size))
        }
    }

    private func install(_ pending: Pending) {
        guard let gameURL, let bottle else { return }
        let bottleURL = bottle.url
        busy = true
        errorText = nil
        Task {
            do {
                let exe = try await Task.detached {
                    try TurkishPatchManager.stage(
                        pending.patch, archive: pending.archive, gameURL: gameURL, bottleURL: bottleURL
                    )
                }.value
                try await Wine.runProgram(at: exe, bottle: bottle)
                step = .installer(pending)
            } catch {
                errorText = error.localizedDescription
                step = .list
            }
            busy = false
        }
    }

    private func finish(_ pending: Pending) {
        guard let gameURL, let bottle, let file = pending.patch.file else { return }
        let bottleURL = bottle.url
        busy = true
        errorText = nil
        Task {
            do {
                try await Task.detached {
                    try TurkishPatchManager.finish(
                        pending.patch, gameURL: gameURL, bottleURL: bottleURL, fileSHA256: file.sha256.lowercased()
                    )
                }.value
                message = "Türkçe yama kuruldu."
            } catch {
                errorText = error.localizedDescription
            }
            step = .list
            await refreshStatuses()
            busy = false
        }
    }

    private func remove(_ patch: TurkishPatch) {
        guard let gameURL else { return }
        busy = true
        message = nil
        errorText = nil
        Task {
            do {
                try await Task.detached { try TurkishPatchManager.uninstall(patch, gameURL: gameURL) }.value
            } catch {
                errorText = error.localizedDescription
            }
            await refreshStatuses()
            busy = false
        }
    }
}
