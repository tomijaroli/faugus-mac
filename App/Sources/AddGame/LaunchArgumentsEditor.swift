import FaugusCore
import SwiftUI

/// One editable row of the launch arguments or presets list.
struct ArgLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// The two editable lists of upstream's `LaunchArgumentsEditor`: the game's launch arguments
/// (one per line, `KEY=VALUE` or a wrapper command) and the shared presets. Rows are edited in
/// place; a blank row at the end is always kept. Drag a row by its grip to reorder it or to
/// copy it into the other list.
struct LaunchArgumentsEditor: View {
    let t: Translator
    @Binding var arguments: [ArgLine]
    @Binding var presets: [ArgLine]

    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 10) {
            list(title: t("Launch Arguments"), origin: "args", lines: $arguments, other: $presets)
            list(title: t("Presets"), origin: "presets", lines: $presets, other: $arguments)
        }
    }

    static func normalized(_ lines: [ArgLine]) -> [ArgLine] {
        var out = lines
        if out.last.map({ !$0.text.isEmpty }) ?? true { out.append(ArgLine(text: "")) }
        return out
    }

    private func list(
        title: String, origin: String, lines: Binding<[ArgLine]>, other: Binding<[ArgLine]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            List(selection: $selection) {
                ForEach(lines) { $line in
                    row($line, origin: origin, lines: lines, other: other)
                        .tag(line.id)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, onto: line.id, lines: lines, origin: origin)
                        }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 110)
            .onDeleteCommand {
                guard let id = selection else { return }
                remove(id, from: lines)
            }
            .dropDestination(for: String.self) { items, _ in
                drop(items, onto: nil, lines: lines, origin: origin)
            }
            .accessibilityIdentifier("launch-list-\(origin)")
        }
    }

    private func row(
        _ line: Binding<ArgLine>, origin: String, lines: Binding<[ArgLine]>, other: Binding<[ArgLine]>
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(line.wrappedValue.text.isEmpty ? .clear : .secondary)
                .draggable("\(origin)|\(line.wrappedValue.id.uuidString)|\(line.wrappedValue.text)")
            TextField("", text: line.text)
                .textFieldStyle(.plain)
                .onChange(of: line.wrappedValue.text) { _, _ in
                    lines.wrappedValue = Self.normalized(lines.wrappedValue)
                }
            if origin == "presets", !line.wrappedValue.text.isEmpty {
                Button {
                    insert(line.wrappedValue.text, into: other, at: nil)
                } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .help(t("Launch Arguments"))
            }
            if !line.wrappedValue.text.isEmpty {
                Button { remove(line.wrappedValue.id, from: lines) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }

    private func remove(_ id: UUID, from lines: Binding<[ArgLine]>) {
        var l = lines.wrappedValue
        l.removeAll { $0.id == id }
        lines.wrappedValue = Self.normalized(l)
    }

    /// Inserts before the blank last row (or `index`).
    private func insert(_ text: String, into lines: Binding<[ArgLine]>, at index: Int?) {
        var l = lines.wrappedValue
        let at = min(index ?? max(l.count - 1, 0), max(l.count - 1, 0))
        l.insert(ArgLine(text: text), at: at)
        lines.wrappedValue = Self.normalized(l)
    }

    private func drop(_ items: [String], onto target: UUID?, lines: Binding<[ArgLine]>, origin: String) -> Bool {
        guard let payload = items.first else { return false }
        let parts = payload.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[2].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        var l = lines.wrappedValue
        let lastIndex = max(l.count - 1, 0)
        let dst = target.flatMap { id in l.firstIndex { $0.id == id } }
        if parts[0] == origin, let id = UUID(uuidString: parts[1]), let src = l.firstIndex(where: { $0.id == id }) {
            // Reorder inside one list.
            let to = min(dst ?? lastIndex - 1, lastIndex - 1)
            guard to != src, to >= 0 else { return false }
            let item = l.remove(at: src)
            l.insert(item, at: to)
            lines.wrappedValue = Self.normalized(l)
            return true
        }
        insert(parts[2], into: lines, at: dst)
        return true
    }
}
