import AppKit
import FaugusCore
import SwiftUI

/// Winetricks for one prefix. Upstream hands the prefix to winetricks' own zenity GUI plus a
/// log window; zenity does not exist on macOS, so Faugus shows the verbs itself (from
/// `winetricks list-all`), then installs the picked ones unattended (`-q`) and streams the
/// output in the same window.
struct WinetricksView: View {
    let model: AppModel
    let prefix: String
    /// `"Default"` or a runner folder name, like a game's `runner` field.
    let runnerName: String
    /// Folder under the logs directory that receives `winetricks.log`.
    let logName: String
    let subtitle: String
    let dismiss: () -> Void

    private enum Phase: Equatable {
        case preparing
        case failed(String)
        case picking
        case running
        case finished(Int32, cancelled: Bool)
    }

    @State private var phase: Phase = .preparing
    @State private var downloadProgress: Double?
    @State private var categories: [WinetricksCategory] = []
    @State private var category = ""
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var installedVerbs: Set<String> = []
    @State private var lines: [String] = []
    @State private var pid: pid_t = 0
    @State private var cancelRequested = false
    @State private var cabextract = Winetricks.cabextractPath() != nil

    var body: some View {
        let t = model.translator
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Winetricks").font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !cabextract {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Many verbs need cabextract. Install it with: ")
                        + Text(Winetricks.cabextractInstallHint).font(.body.monospaced())
                    Spacer()
                    Button("Check again") { cabextract = Winetricks.cabextractPath() != nil }
                }
                .font(.callout)
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            content(t)
            footer(t)
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task { await prepare() }
        .accessibilityIdentifier("winetricks-view")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ t: Translator) -> some View {
        switch phase {
        case .preparing:
            VStack(spacing: 10) {
                Spacer()
                if let downloadProgress {
                    ProgressView(value: downloadProgress).frame(width: 240)
                    Text("Downloading winetricks…").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Loading verbs…").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case let .failed(message):
            VStack(spacing: 10) {
                Spacer()
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Retry") { Task { await prepare() } }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .picking:
            picker(t)
        case .running, .finished:
            logView
        }
    }

    private func picker(_ t: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $category) {
                ForEach(categories) { Text($0.name.capitalized).tag($0.name) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("winetricks-category")
            TextField("", text: $search, prompt: Text(t("Search")))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityIdentifier("winetricks-search")
            let verbs = visibleVerbs
            List {
                ForEach(verbs) { verb in
                    Toggle(isOn: binding(for: verb.name)) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(verb.name).font(.body.monospaced())
                                if installedVerbs.contains(verb.name) {
                                    Text("Installed").font(.caption2).padding(.horizontal, 5)
                                        .background(.green.opacity(0.2), in: Capsule())
                                }
                            }
                            if !verb.summary.isEmpty {
                                Text(verb.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .overlay {
                if verbs.isEmpty {
                    Text("No verb found.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
            .accessibilityIdentifier("winetricks-log")
        }
    }

    private func footer(_ t: Translator) -> some View {
        HStack {
            switch phase {
            case .picking:
                Text(selected.isEmpty ? "" : "\(selected.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { Task { await install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("winetricks-install")
            case .running:
                ProgressView().controlSize(.small)
                Text(selected.sorted().joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(t("Cancel")) { cancel() }.disabled(cancelRequested)
            case let .finished(status, cancelled):
                Image(systemName: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? .green : .red)
                Text(cancelled ? "Cancelled" : (status == 0 ? "Done" : "winetricks exited with status \(status)"))
                Spacer()
                Button("Back") { selected = []
                    phase = .picking
                }
                Button(t("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            case .preparing, .failed:
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Verbs

    private var visibleVerbs: [WinetricksVerb] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            return categories.flatMap(\.verbs).filter {
                $0.name.lowercased().contains(query) || $0.summary.lowercased().contains(query)
            }
        }
        return categories.first { $0.name == category }?.verbs ?? []
    }

    private func binding(for verb: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(verb) },
            set: {
                if $0 {
                    selected.insert(verb)
                } else {
                    selected.remove(verb)
                }
            }
        )
    }

    // MARK: Work

    private var runner: InstalledRunner? {
        let store = RunnerStore(paths: model.paths)
        if case let .installed(r) = store.resolve(
            runnerName,
            defaultRunner: model.config?.defaultRunner ?? FaugusConfig.defaultRunner
        ) {
            return r
        }
        return nil
    }

    private func prepare() async {
        phase = .preparing
        guard let runner else {
            phase = .failed("The runner is not installed. Install it in the Runner Manager first.")
            return
        }
        let component = WinetricksComponent(paths: model.paths)
        do {
            if !component.isInstalled {
                downloadProgress = 0
                try await component.install { p in Task { @MainActor in downloadProgress = p } }
                downloadProgress = nil
            }
            if let cached = model.winetricksCatalog {
                categories = cached
            } else {
                let inv = WinetricksInvocation.listAll(prefix: prefix, runner: runner, paths: model.paths)
                let result = try await ProcessRunner.run(
                    inv.argv[0], Array(inv.argv.dropFirst()), environment: inv.environment,
                    currentDirectory: model.paths.tempDir
                )
                let parsed = Winetricks.parseList(result.stdout)
                guard result.succeeded, !parsed.isEmpty else {
                    throw RunnerError.downloadFailed(
                        result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "winetricks list-all exited with \(result.status)" : result.stderr
                    )
                }
                model.winetricksCatalog = parsed
                categories = parsed
            }
            if !categories.contains(where: { $0.name == category }) {
                category = categories.first?.name ?? ""
            }
            installedVerbs = Winetricks.installedVerbs(prefix: prefix)
            phase = .picking
        } catch {
            downloadProgress = nil
            phase = .failed("\(error)")
        }
    }

    private func install() async {
        guard let runner, !selected.isEmpty else { return }
        let verbs = selected.sorted()
        lines = []
        cancelRequested = false
        phase = .running

        let prefixes = PrefixManager(paths: model.paths)
        if !prefixes.isCreated(prefix: prefix) {
            lines.append("Creating the prefix \(prefix)…")
            do {
                try await prefixes.create(prefix: prefix, runner: runner)
            } catch {
                lines.append("\(error)")
                phase = .finished(1, cancelled: false)
                return
            }
        }

        let inv = WinetricksInvocation.install(
            verbs: verbs, prefix: prefix, runner: runner, paths: model.paths, logName: logName
        )
        try? FileManager.default.createDirectory(
            atPath: (inv.logFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: inv.logFile)
        lines.append("winetricks -q " + verbs.joined(separator: " "))

        let child: pid_t
        do {
            child = try ProcessSpawner.spawn(
                argv: inv.argv,
                options: .init(
                    workingDirectory: inv.workingDirectory,
                    environment: inv.environment,
                    outputFile: inv.logFile
                )
            )
        } catch {
            lines.append("\(error)")
            phase = .finished(1, cancelled: false)
            return
        }
        pid = child
        let tail = LogTail(path: inv.logFile)
        let exit = ExitBox()
        Task { await exit.set(ProcessSpawner.waitForExit(pid: child)) }
        while exit.status == nil {
            append(tail.poll())
            try? await Task.sleep(for: .milliseconds(250))
        }
        let status = exit.status
        append(tail.poll(flush: true))
        pid = 0
        installedVerbs = Winetricks.installedVerbs(prefix: prefix)
        phase = .finished(status ?? -1, cancelled: cancelRequested)
    }

    private func append(_ new: [String]) {
        guard !new.isEmpty else { return }
        lines.append(contentsOf: new)
        if lines.count > 5000 {
            lines.removeFirst(lines.count - 5000)
        }
    }

    /// Stops winetricks and everything it started (the child runs as its own process group),
    /// then the prefix's wineserver.
    private func cancel() {
        guard pid > 0 else { return }
        cancelRequested = true
        let target = pid
        kill(-target, SIGTERM)
        let runner = runner
        let prefix = prefix
        Task.detached {
            try? await Task.sleep(for: .seconds(3))
            if ProcessSpawner.isAlive(target) {
                kill(-target, SIGKILL)
            }
            if let runner {
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = prefix
                _ = try? await ProcessRunner.run(
                    runner.wineserverBinary,
                    ["-k"],
                    environment: env,
                    currentDirectory: prefix
                )
            }
        }
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ v: Int32) {
        lock.lock()
        value = v
        lock.unlock()
    }
}
