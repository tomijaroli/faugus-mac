import FaugusCore
import SwiftUI

/// Runner Manager (upstream's Proton Manager): Gcenx Wine Staging, Devel and Stable builds,
/// one tab per flavor, newest first, with Download, Cancel and Remove per release.
struct RunnerManagerView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var flavor: WineFlavor = .staging
    @State private var feed: [RemoteRunner] = []
    @State private var feedLoaded = false
    @State private var feedError: String?
    @State private var installed: [InstalledRunner] = []
    @State private var downloads: [String: Task<Void, Never>] = [:]
    @State private var progress: [String: Double] = [:]
    @State private var errors: [String: String] = [:]
    @State private var rosetta: Bool?
    @State private var rosettaBusy = false

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 12) {
            Text(translate("Runner Manager")).font(.title2.weight(.semibold))
            rosettaBox()
            Picker("", selection: $flavor) {
                ForEach(WineFlavor.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("runner-flavor")

            GroupBox {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let rows = RunnerCatalog.rows(flavor: flavor, remote: feed, installed: installed)
                        if rows.isEmpty {
                            Text(feedLoaded ? "No release found." : "Loading…")
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(rows) { row in
                            runnerRow(row, translate)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: 320)
            }
            if let feedError {
                HStack {
                    Text(feedError).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { Task { await loadFeed() } }
                }
            }
            HStack {
                Spacer()
                Button(translate("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { installed = model.installedRunners()
            await loadFeed()
        }
        .task { rosetta = await Rosetta.isInstalled() }
        .onDisappear { downloads.values.forEach { $0.cancel() } }
    }

    private func label(for wineFlavor: WineFlavor) -> String {
        switch wineFlavor {
        case .staging: "Wine Staging"
        case .devel: "Wine Devel"
        case .stable: "Wine Stable"
        }
    }

    // MARK: Rows

    private func runnerRow(_ row: RunnerRow, _ translate: Translator) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.isLatest ? "\(row.version) (\(latestWord))" : row.version)
                if let message = errors[row.id] {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if let value = progress[row.id] {
                ProgressView(value: value).frame(width: 100)
            }
            actionButton(row, translate)
        }
        .padding(.vertical, 6)
    }

    private var latestWord: String {
        model.translator("Latest")
    }

    @ViewBuilder
    private func actionButton(_ row: RunnerRow, _ translate: Translator) -> some View {
        if downloads[row.id] != nil {
            Button(translate("Cancel")) { downloads[row.id]?.cancel() }
                .frame(width: 96)
        } else if row.isInstalled {
            Button(translate("Remove"), role: .destructive) { remove(row) }
                .frame(width: 96)
        } else {
            Button(translate("Download")) { download(row) }
                .disabled(row.remote == nil)
                .frame(width: 96)
        }
    }

    // MARK: Rosetta

    private func rosettaBox() -> some View {
        GroupBox("Rosetta 2") {
            HStack {
                Text(rosetta == nil ? "…" : (rosetta! ? "Installed" : "Not installed"))
                Spacer()
                if rosetta == false {
                    Button("Install Rosetta") { Task { await installRosetta() } }.disabled(rosettaBusy)
                }
            }.padding(4)
        }
    }

    private func installRosetta() async {
        rosettaBusy = true
        do { try await Rosetta.install() } catch { feedError = "\(error)" }
        rosettaBusy = false
        rosetta = await Rosetta.isInstalled()
    }

    // MARK: Actions

    private func loadFeed() async {
        feedError = nil
        do {
            feed = try await GcenxFeed.fetchAll()
        } catch {
            feedError = "\(error)"
        }
        feedLoaded = true
    }

    private func download(_ row: RunnerRow) {
        guard let remote = row.remote else { return }
        errors[row.id] = nil
        progress[row.id] = 0
        let installer = RunnerInstaller(paths: model.paths)
        downloads[row.id] = Task {
            do {
                _ = try await installer.install(remote) { fraction in
                    Task {
                        @MainActor in if !Task.isCancelled {
                            progress[row.id] = fraction
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errors[row.id] = "\(error)"
                }
            }
            downloads[row.id] = nil
            progress[row.id] = nil
            installed = model.installedRunners()
        }
    }

    private func remove(_ row: RunnerRow) {
        do {
            try RunnerInstaller(paths: model.paths).uninstall(name: row.directoryName)
            errors[row.id] = nil
        } catch {
            errors[row.id] = "\(error)"
        }
        installed = model.installedRunners()
    }
}
