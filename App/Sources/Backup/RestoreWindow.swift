import FaugusCore
import SwiftUI

struct RestoreRequest: Identifiable {
    var path: String
    var id: String {
        path
    }
}

/// Upstream's `RestoreWindow`.
struct RestoreWindow: View {
    let model: AppModel
    let archivePath: String
    let dismiss: () -> Void

    @State private var phase: Phase = .extracting
    @State private var preview: BackupRestore.Preview?
    @State private var rows: [RestoreRowDraft] = []
    @State private var runners: [BackupRunnerDraft] = []
    @State private var confirmOverwrite = false
    @State private var errorText = ""

    enum Phase {
        case extracting, ready, restoring, failed
    }

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 12) {
            if phase == .extracting {
                VStack(spacing: 12) {
                    Text(translate("Extracting backup..."))
                    ProgressView()
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if phase == .restoring {
                VStack(spacing: 12) {
                    Text(translate("Restoring backup..."))
                    ProgressView()
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if phase == .failed {
                Text(errorText.isEmpty ? translate("This is not a valid Faugus backup file.") : errorText)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else if preview?.isLegacy == true {
                Text(translate("This backup has no manifest. Restore every settings file it contains?"))
            } else {
                restoreLists(translate)
            }
            HStack {
                Button(translate("Cancel")) { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                    .disabled(phase == .restoring)
                Button(translate("Ok")) { confirmOverwrite = true }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
                    .disabled(phase != .ready)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
        .task { await extract() }
        .confirmationDialog(
            translate("Are you sure you want to overwrite the settings?"),
            isPresented: $confirmOverwrite,
            titleVisibility: .visible
        ) {
            Button(translate("Yes")) { startRestore() }
            Button(translate("No"), role: .cancel) {}
        }
    }

    private func restoreLists(_: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach($rows) { $row in
                        HStack {
                            Toggle("", isOn: Binding(get: { row.gameSelected }, set: { row.setGame($0) }))
                                .labelsHidden()
                            Text(row.item.title).frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: $row.prefixSelected)
                                .labelsHidden()
                                .disabled(!row.item.hasPrefix)
                                .opacity(row.item.hasPrefix ? 1 : 0)
                            Text(row.item.path).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: $row.shortcutSelected)
                                .labelsHidden()
                                .disabled(row.item.shortcutFiles.isEmpty)
                                .opacity(row.item.shortcutFiles.isEmpty ? 0 : 1)
                            Text(row.sizeText).frame(width: 80, alignment: .trailing)
                        }
                    }
                    ForEach($runners) { $runner in
                        HStack {
                            Toggle("", isOn: $runner.selected).labelsHidden()
                            Text(runner.item.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(runner.item.path).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(runner.sizeText).frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func extract() async {
        do {
            let loaded = try await BackupRestore(paths: model.paths).preview(archivePath: archivePath)
            preview = loaded
            if loaded.isLegacy {
                phase = .ready
                return
            }
            rows = loaded.prefixItems.map {
                RestoreRowDraft(
                    item: $0,
                    gameSelected: true,
                    prefixSelected: $0.hasPrefix,
                    shortcutSelected: !$0.shortcutFiles.isEmpty,
                    sizeText: BackupFormat.formatSize($0.sizeBytes)
                )
            }
            runners = loaded.runnerItems.map {
                BackupRunnerDraft(item: $0, selected: true, sizeText: BackupFormat.formatSize($0.sizeBytes))
            }
            phase = .ready
        } catch {
            errorText = error.localizedDescription
            phase = .failed
        }
    }

    private func startRestore() {
        guard let preview else { return }
        phase = .restoring
        Task {
            do {
                let outcome = try BackupRestore(paths: model.paths).restore(
                    preview: preview,
                    selectedGameIDs: Set(rows.filter(\.gameSelected).map(\.item.gameID)),
                    selectedPrefixes: rows.filter(\.prefixSelected).map(\.item),
                    selectedShortcuts: rows.filter(\.shortcutSelected).map(\.item),
                    selectedRunners: runners.filter(\.selected).map(\.item)
                )
                var configuration = try FaugusConfig.load(paths: model.paths)
                BackupSchedule.suppressImmediateAutoBackup(&configuration)
                try configuration.save()
                await repairImportedPrefixes(outcome)
                await MainActor.run {
                    model.reload()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorText = "\(error)"
                    phase = .failed
                }
            }
        }
    }

    private func repairImportedPrefixes(_ outcome: LinuxFixup.Result) async {
        guard !outcome.prefixesNeedingWineboot.isEmpty else { return }
        let configuration = try? FaugusConfig.load(paths: model.paths)
        let resolved = RunnerStore(paths: model.paths).resolve(
            "Default", defaultRunner: configuration?.defaultRunner ?? FaugusConfig.defaultRunner
        )
        guard case let .installed(runner) = resolved else { return }
        let prefixes = PrefixManager(paths: model.paths)
        let dxvk = DXVKComponent(paths: model.paths)
        let games = (try? GamesStore(paths: model.paths).loadAll()) ?? []
        for prefix in outcome.prefixesNeedingWineboot {
            try? await prefixes.updateAfterImport(prefix: prefix, runner: runner)
            if let game = games.first(where: { model.paths.expand($0.prefix) == prefix }),
               let config = configuration
            {
                let requested = GraphicsPlan.effectiveRequest(game: game, config: config)
                let plan = GraphicsPlan.resolve(
                    requested: requested, capabilities: runner.capabilities, dxvkInstalled: dxvk.isInstalled
                )
                try? prefixes.applyGraphics(plan, prefix: prefix, runner: runner, dxvk: dxvk)
            }
        }
        if !outcome.shortcutGameIDs.isEmpty {
            recreateShortcuts(gameIDs: outcome.shortcutGameIDs)
        }
    }

    private func recreateShortcuts(gameIDs: [String]) {
        let shortcuts = GameShortcuts(
            paths: model.paths,
            executablePath: Bundle.main.executablePath ?? "",
            fallbackIconPath: model.fallbackIconPath
        )
        let games = (try? GamesStore(paths: model.paths).loadAll()) ?? []
        for game in games where gameIDs.contains(game.gameID) {
            try? shortcuts.install(for: game, locations: [.applicationsMenu])
        }
    }

    private func cancel() {
        if let preview {
            BackupRestore(paths: model.paths).discard(preview: preview)
        } else {
            try? FileManager.default.removeItem(atPath: model.paths.restoreStagingDirectory)
        }
        dismiss()
    }
}

private struct RestoreRowDraft: Identifiable {
    var item: BackupPrefixItem
    var gameSelected: Bool
    var prefixSelected: Bool
    var shortcutSelected: Bool
    var sizeText: String

    var id: String {
        item.gameID
    }

    mutating func setGame(_ value: Bool) {
        gameSelected = value
        prefixSelected = value && item.hasPrefix
        shortcutSelected = value && !item.shortcutFiles.isEmpty
    }
}

private struct BackupRunnerDraft: Identifiable {
    var item: BackupRunnerItem
    var selected: Bool
    var sizeText: String

    var id: String {
        item.gameID
    }
}
