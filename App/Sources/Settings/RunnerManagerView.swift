import FaugusCore
import SwiftUI

/// Minimal Runner Manager (P1): install Wine Staging Latest, list and remove runners, and
/// install Rosetta. The full manager (Devel/Stable, versions, DXVK) arrives in P3.
struct RunnerManagerView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var runners: [InstalledRunner] = []
    @State private var busy = false
    @State private var progress: Double?
    @State private var status = ""
    @State private var rosetta: Bool?

    var body: some View {
        let t = model.translator
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Settings")).font(.title2.weight(.semibold))
            GroupBox("Rosetta 2") {
                HStack {
                    Text(rosetta == nil ? "…" : (rosetta! ? "Installed" : "Not installed"))
                    Spacer()
                    if rosetta == false {
                        Button("Install Rosetta") { Task { await installRosetta() } }.disabled(busy)
                    }
                }.padding(4)
            }
            GroupBox("Runner Manager") {
                VStack(alignment: .leading, spacing: 6) {
                    if runners.isEmpty {
                        Text("No runner installed.").foregroundStyle(.secondary)
                    }
                    ForEach(runners) { r in
                        HStack {
                            Text(r.name)
                            Spacer()
                            Button(t("Delete"), role: .destructive) { remove(r) }.disabled(busy)
                        }
                    }
                    Divider()
                    HStack {
                        Button("Install \(WineFlavor.staging.latestIdentifier)") { Task { await installLatest() } }
                            .disabled(busy)
                        if let progress { ProgressView(value: progress).frame(width: 140) }
                        else if busy { ProgressView().controlSize(.small) }
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.padding(4)
            }
            HStack {
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await refresh() }
    }

    private func refresh() async {
        runners = model.installedRunners()
        rosetta = await Rosetta.isInstalled()
    }

    private func remove(_ r: InstalledRunner) {
        try? RunnerInstaller(paths: model.paths).uninstall(name: r.name)
        runners = model.installedRunners()
    }

    private func installRosetta() async {
        busy = true; status = "Installing Rosetta 2…"
        do { try await Rosetta.install(); status = "" } catch { status = "\(error)" }
        busy = false
        await refresh()
    }

    private func installLatest() async {
        busy = true; progress = 0; status = "Looking up the latest release…"
        defer { busy = false; progress = nil }
        do {
            let feed = try await GcenxFeed.fetchAll()
            guard let latest = GcenxFeed.latest(.staging, in: feed) else {
                status = "No Wine Staging release found."; return
            }
            status = "Downloading \(latest.directoryName)…"
            _ = try await RunnerInstaller(paths: model.paths).install(latest) { p in
                Task { @MainActor in progress = p }
            }
            status = "Installed \(latest.directoryName)."
        } catch {
            status = "\(error)"
        }
        await refresh()
    }
}
