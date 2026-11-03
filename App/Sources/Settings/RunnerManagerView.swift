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
        let t = model.translator
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Runner Manager")).font(.title2.weight(.semibold))
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
                            runnerRow(row, t)
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
                Button(t("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { installed = model.installedRunners(); await loadFeed() }
        .task { rosetta = await Rosetta.isInstalled() }
        .onDisappear { downloads.values.forEach { $0.cancel() } }
    }

    private func label(for f: WineFlavor) -> String {
        switch f {
        case .staging: return "Wine Staging"
        case .devel: return "Wine Devel"
        case .stable: return "Wine Stable"
        }
    }

    // MARK: Rows

    private func runnerRow(_ row: RunnerRow, _ t: Translator) -> some View {
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
            actionButton(row, t)
        }
        .padding(.vertical, 6)
    }

    private var latestWord: String { model.translator("Latest") }

    @ViewBuilder
    private func actionButton(_ row: RunnerRow, _ t: Translator) -> some View {
        if downloads[row.id] != nil {
            Button(t("Cancel")) { downloads[row.id]?.cancel() }
                .frame(width: 96)
        } else if row.isInstalled {
            Button(t("Remove"), role: .destructive) { remove(row) }
                .frame(width: 96)
        } else {
            Button(t("Download")) { download(row) }
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
                _ = try await installer.install(remote) { p in
                    Task { @MainActor in if !Task.isCancelled { progress[row.id] = p } }
                }
            } catch {
                if !Task.isCancelled { errors[row.id] = "\(error)" }
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
