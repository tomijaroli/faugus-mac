import AppKit
import FaugusCore
import SwiftUI

/// Upstream's `BackupWindow`.
struct BackupWindow: View { // swiftlint:disable:this type_body_length
    let model: AppModel
    @Binding var configuration: FaugusConfig
    let dismiss: () -> Void

    @State private var destinationDirectory = ""
    @State private var frequency = "daily"
    @State private var weekday = 0
    @State private var monthDay = 1
    @State private var targetTime = Date()
    @State private var lastBackup = ""
    @State private var rows: [BackupRowDraft] = []
    @State private var runners: [BackupRunnerDraft] = []
    @State private var settingsSize: Int64 = 0
    @State private var backupActive = false
    @State private var destinationInvalid = false
    @State private var statusMessage = ""

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                destinationColumn(translate)
                frequencyColumn(translate)
                actionColumn(translate)
            }
            prefixTable(translate)
            runnerTable(translate)
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(translate("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button(translate("Ok")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .task { load() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            pollRunning()
        }
    }

    private func destinationColumn(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(translate("Backup Destination"))
            HStack {
                TextField("", text: $destinationDirectory)
                    .labelsHidden()
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                        Color.red,
                        lineWidth: destinationInvalid ? 1.5 : 0
                    ))
                Button {
                    chooseDestination(translate)
                } label: {
                    Image(systemName: "folder")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frequencyColumn(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(translate("Automatic Backup"))
            Picker("", selection: $frequency) {
                Text(translate("Disabled")).tag("disabled")
                Text(translate("Daily")).tag("daily")
                Text(translate("Weekly")).tag("weekly")
                Text(translate("Monthly")).tag("monthly")
            }
            .labelsHidden()
            if frequency == "weekly" {
                Picker("", selection: $weekday) {
                    ForEach(0 ..< BackupSchedule.weekdays.count, id: \.self) { index in
                        Text(translate(BackupSchedule.weekdays[index])).tag(index)
                    }
                }
                .labelsHidden()
            }
            if frequency == "monthly" {
                Picker(translate("Day"), selection: $monthDay) {
                    ForEach(1 ... 31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
            }
            DatePicker(
                "",
                selection: $targetTime,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .disabled(frequency == "disabled")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionColumn(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(translate("Last backup:")) \(lastBackup.isEmpty ? translate("No backup yet") : lastBackup)")
            Button(backupButtonTitle(translate)) {
                if backupActive {
                    BackupLock.requestCancel(paths: model.paths)
                    statusMessage = translate("Cancelling...")
                } else {
                    startBackup()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prefixTable(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                toggleHeader(translate("Game/App"), allSelected: rows.allSatisfy(\.gameSelected)) {
                    let value = !rows.allSatisfy(\.gameSelected)
                    for index in rows.indices {
                        rows[index].setGame(value)
                    }
                }
                Text(translate("Game/App")).frame(maxWidth: .infinity, alignment: .leading)
                toggleHeader(
                    translate("Prefix"),
                    allSelected: rows.filter(\.item.hasPrefix).allSatisfy(\.prefixSelected)
                ) {
                    let eligible = rows.filter(\.item.hasPrefix)
                    let value = !eligible.allSatisfy(\.prefixSelected)
                    for index in rows.indices where rows[index].item.hasPrefix {
                        rows[index].prefixSelected = value
                    }
                }
                Text(translate("Prefix")).frame(maxWidth: .infinity, alignment: .leading)
                toggleHeader(
                    translate("Shortcuts"),
                    allSelected: rows.filter { !$0.item.shortcutFiles.isEmpty }.allSatisfy(\.shortcutSelected)
                ) {
                    let eligible = rows.filter { !$0.item.shortcutFiles.isEmpty }
                    let value = !eligible.allSatisfy(\.shortcutSelected)
                    for index in rows.indices where !rows[index].item.shortcutFiles.isEmpty {
                        rows[index].shortcutSelected = value
                    }
                }
                Text(translate("Size")).frame(width: 80, alignment: .trailing)
            }
            .font(.caption)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach($rows) { $row in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { row.gameSelected },
                                set: { row.setGame($0) }
                            ))
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
                        .font(.callout)
                    }
                }
            }
            .frame(minHeight: 140)
            Text("\(translate("Total:")) \(BackupFormat.formatSize(totalSize))")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .font(.caption)
        }
    }

    private func runnerTable(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                toggleHeader(
                    translate("Proton"),
                    allSelected: !runners.isEmpty && runners.allSatisfy(\.selected)
                ) {
                    let value = !runners.allSatisfy(\.selected)
                    for index in runners.indices {
                        runners[index].selected = value
                    }
                }
                Text(translate("Proton")).frame(maxWidth: .infinity, alignment: .leading)
                Text(translate("Path")).frame(maxWidth: .infinity, alignment: .leading)
                Text(translate("Size")).frame(width: 80, alignment: .trailing)
            }
            .font(.caption)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach($runners) { $runner in
                        HStack {
                            Toggle("", isOn: $runner.selected).labelsHidden()
                            Text(runner.item.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(runner.item.path).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(runner.sizeText).frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(minHeight: 80)
        }
    }

    private func toggleHeader(
        _ title: String,
        allSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: allSelected ? "checkmark.square.fill" : "square")
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var totalSize: Int64 {
        settingsSize
            + rows.filter { $0.prefixSelected || $0.shortcutSelected }.reduce(Int64(0)) { $0 + $1.item.sizeBytes }
            + runners.filter(\.selected).reduce(Int64(0)) { $0 + $1.item.sizeBytes }
    }

    private func backupButtonTitle(_ translate: Translator) -> String {
        if backupActive {
            return translate("Cancel backup")
        }
        return "\(translate("Backup now")) (\(BackupFormat.formatSize(totalSize)))"
    }

    private func load() {
        let loaded = (try? FaugusConfig.load(paths: model.paths)) ?? configuration
        destinationDirectory = loaded.string("backup-dest-dir")
        if destinationDirectory.isEmpty {
            destinationDirectory = model.paths.defaultBackupDestination
        }
        lastBackup = loaded.string("backup-last-date")
        if loaded.bool("backup-auto-enabled") {
            frequency = loaded.string("backup-frequency", default: "daily")
        } else {
            frequency = "disabled"
        }
        weekday = loaded.int("backup-target-day")
        monthDay = max(1, loaded.int("backup-target-day"))
        if frequency == "monthly", weekday == 0, monthDay == 0 {
            monthDay = 1
        }
        let parsedTime = BackupSchedule.parseTargetTime(
            loaded.string("backup-target-time", default: BackupSchedule.defaultTargetTime)
        )
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parsedTime.hour
        components.minute = parsedTime.minute
        targetTime = Calendar.current.date(from: components) ?? Date()

        let games = (try? GamesStore(paths: model.paths).loadAll()) ?? []
        let items = BackupInventory.prefixItemsWithShortcuts(
            paths: model.paths,
            configuration: loaded,
            games: games,
            executablePath: Bundle.main.executablePath ?? "",
            fallbackIconPath: ""
        )
        let excludedGames = Set(BackupInventory.stringArray(loaded, "backup-excluded-game-ids"))
        let excludedPrefixes = BackupInventory.resolveExcludedIDs(
            configuration: loaded,
            excludedKey: "backup-excluded-prefix-ids",
            includedKey: "backup-prefix-ids",
            allIDs: Set(items.map(\.gameID))
        )
        let excludedShortcuts = BackupInventory.resolveExcludedIDs(
            configuration: loaded,
            excludedKey: "backup-excluded-shortcut-ids",
            includedKey: "backup-shortcut-ids",
            allIDs: Set(items.filter { !$0.shortcutFiles.isEmpty }.map(\.gameID))
        )
        rows = items.map { item in
            BackupRowDraft(
                item: item,
                gameSelected: !excludedGames.contains(item.gameID),
                prefixSelected: item.hasPrefix && !excludedPrefixes.contains(item.gameID),
                shortcutSelected: !item.shortcutFiles.isEmpty && !excludedShortcuts.contains(item.gameID)
            )
        }
        let savedRunners = Set(BackupInventory.stringArray(loaded, "backup-proton-ids"))
        runners = BackupInventory.runnerItems(paths: model.paths).map {
            BackupRunnerDraft(item: $0, selected: savedRunners.contains($0.gameID))
        }
        let paths = model.paths
        Task.detached {
            let size = BackupInventory.settingsSize(paths: paths)
            var sizedRows = items
            for index in sizedRows.indices {
                sizedRows[index].sizeBytes = BackupCopy.directorySize(at: sizedRows[index].path)
                    + sizedRows[index].shortcutFiles.reduce(0) { $0 + BackupCopy.directorySize(at: $1) }
            }
            var sizedRunners = BackupInventory.runnerItems(paths: paths)
            for index in sizedRunners.indices {
                sizedRunners[index].sizeBytes = BackupCopy.directorySize(at: sizedRunners[index].path)
            }
            await MainActor.run {
                settingsSize = size
                for index in rows.indices {
                    if let match = sizedRows.first(where: { $0.gameID == rows[index].item.gameID }) {
                        rows[index].item.sizeBytes = match.sizeBytes
                        rows[index].sizeText = BackupFormat.formatSize(match.sizeBytes)
                    }
                }
                for index in runners.indices {
                    if let match = sizedRunners.first(where: { $0.gameID == runners[index].item.gameID }) {
                        runners[index].item.sizeBytes = match.sizeBytes
                        runners[index].sizeText = BackupFormat.formatSize(match.sizeBytes)
                    }
                }
            }
        }
    }

    private func pollRunning() {
        let running = BackupLock.isRunning(paths: model.paths)
        if running, !backupActive {
            backupActive = true
        } else if !running, backupActive {
            backupActive = false
            if let reloaded = try? FaugusConfig.load(paths: model.paths) {
                lastBackup = reloaded.string("backup-last-date")
            }
            statusMessage = ""
        }
    }

    private func chooseDestination(_ translate: Translator) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = translate("Select the backup destination")
        panel.directoryURL = URL(fileURLWithPath: model.paths.expand(destinationDirectory))
        if panel.runModal() == .OK, let url = panel.url {
            destinationDirectory = url.path
            destinationInvalid = false
        }
    }

    private func currentSelection() -> BackupSelection {
        BackupSelection(
            gameIDs: rows.filter(\.gameSelected).map(\.item.gameID),
            prefixes: rows.filter(\.prefixSelected).map(\.item),
            shortcuts: rows.filter(\.shortcutSelected).map(\.item),
            runners: runners.filter(\.selected).map(\.item)
        )
    }

    private func startBackup() {
        let translate = model.translator
        if destinationDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            destinationInvalid = true
            return
        }
        let needed = totalSize
        let expanded = model.paths.expand(destinationDirectory)
        if let available = BackupCopy.freeSpace(at: expanded), needed > available {
            BackupNotifications.send(
                body: translate("Backup failed: not enough disk space ({} needed, {} available).")
                    .replacingOccurrences(
                        of: "{} needed, {} available",
                        with: "\(BackupFormat.formatSize(needed)) needed, \(BackupFormat.formatSize(available)) available"
                    )
            )
            return
        }
        backupActive = true
        let selection = currentSelection()
        let games = (try? GamesStore(paths: model.paths).loadAll()) ?? []
        let destination = BackupFormat.uniqueArchivePath(in: expanded)
        Task {
            BackupNotifications.send(body: translate("Backup started"))
            do {
                let stamp = try await BackupSession(paths: model.paths).perform(
                    destinationPath: destination, selection: selection, games: games
                )
                var saved = try FaugusConfig.load(paths: model.paths)
                saved.setValue("backup-last-date", stamp)
                try saved.save()
                BackupNotifications.send(body: translate("Backup completed"))
                await MainActor.run {
                    lastBackup = stamp
                    backupActive = false
                    configuration.setValue("backup-last-date", stamp)
                }
            } catch BackupError.cancelled {
                BackupNotifications.send(body: translate("Backup cancelled"))
                await MainActor.run { backupActive = false }
            } catch {
                BackupNotifications.send(body: translate("Backup failed."))
                await MainActor.run {
                    backupActive = false
                    statusMessage = "\(error)"
                }
            }
        }
    }

    private func save() {
        var saved = (try? FaugusConfig.load(paths: model.paths)) ?? configuration
        let enabled = frequency != "disabled"
        saved.setValue("backup-auto-enabled", bool: enabled)
        saved.setValue("backup-frequency", enabled ? frequency : "daily")
        if frequency == "weekly" {
            saved.setValue("backup-target-day", String(weekday))
        } else if frequency == "monthly" {
            saved.setValue("backup-target-day", String(monthDay))
        } else {
            saved.setValue("backup-target-day", "0")
        }
        let hour = Calendar.current.component(.hour, from: targetTime)
        let minute = Calendar.current.component(.minute, from: targetTime)
        saved.setRaw("backup-target-time", .string(BackupSchedule.formatTargetTime(hour: hour, minute: minute)))
        saved.setValue("backup-dest-dir", destinationDirectory)
        saved.setRaw(
            "backup-excluded-game-ids",
            .array(rows.filter { !$0.gameSelected }.map { .string($0.item.gameID) })
        )
        saved.setRaw(
            "backup-excluded-prefix-ids",
            .array(rows.filter { !$0.prefixSelected }.map { .string($0.item.gameID) })
        )
        saved.setRaw(
            "backup-excluded-shortcut-ids",
            .array(
                rows.filter { !$0.item.shortcutFiles.isEmpty && !$0.shortcutSelected }.map { .string($0.item.gameID) }
            )
        )
        saved.removeValue("backup-prefix-ids")
        saved.removeValue("backup-shortcut-ids")
        saved.setRaw("backup-proton-ids", .array(runners.filter(\.selected).map { .string($0.item.gameID) }))
        do {
            try saved.save()
            try BackupAgent.apply(enabled: enabled)
            configuration = saved
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct BackupRowDraft: Identifiable {
    var item: BackupPrefixItem
    var gameSelected: Bool
    var prefixSelected: Bool
    var shortcutSelected: Bool
    var sizeText = "—"

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
    var sizeText = "—"

    var id: String {
        item.gameID
    }
}
