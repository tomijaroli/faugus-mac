import FaugusCore
import SwiftUI

/// `DuplicateDialog`: asks for the title of the copy.
struct DuplicateGameView: View {
    let model: AppModel
    let game: Game
    let dismiss: () -> Void

    @State private var title = ""
    @State private var invalid = false
    @State private var warning: String?
    @FocusState private var focused: Bool

    var body: some View {
        let t = model.translator
        VStack(alignment: .leading, spacing: 10) {
            Text(t.format("Duplicate %s", game.title)).font(.title3.weight(.semibold))
            Text(t("Title"))
            TextField("", text: $title)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: invalid ? 1.5 : 0))
                .onChange(of: title) { _, _ in invalid = false }
                .onSubmit { confirm() }
                .accessibilityIdentifier("duplicate-title")
            HStack {
                Button(t("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button(t("Ok")) { confirm() }
                    .keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("duplicate-ok")
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 360)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .onAppear { focused = true }
        .alert(warning ?? "", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
            Button(t("Ok")) {}
        }
    }

    private func confirm() {
        switch model.duplicate(game, as: title) {
        case nil: dismiss()
        case .invalidTitle?: invalid = true
        case .exists?: warning = model.translator.format("%s already exists", title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// `DeleteDialog`: asks for confirmation and offers to remove the prefix. Unlike upstream, a
/// prefix that other games still use cannot be removed from here; it is only warned about.
struct DeleteGameView: View {
    let model: AppModel
    let game: Game
    let dismiss: () -> Void

    @State private var removePrefix = false

    var body: some View {
        let t = model.translator
        let others = model.gamesSharingPrefix(with: game)
        let offers = GameEditing.offersPrefixRemoval(for: game, paths: model.paths)
        VStack(spacing: 16) {
            Text(t.format("Are you sure you want to delete %s?", game.title)).multilineTextAlignment(.center)
            if offers {
                Toggle(t("Also remove the prefix:"), isOn: $removePrefix)
                    .disabled(others > 0)
                    .accessibilityIdentifier("delete-remove-prefix")
                Text(game.prefix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if others > 0 {
                    Text(others == 1
                        ? t("WARNING: This prefix is used by 1 other game.")
                        : t.format("WARNING: This prefix is used by %d other games.", String(others)))
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Button(t("No"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button(t("Yes"), role: .destructive) {
                    model.delete(game, removePrefix: removePrefix && others == 0)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
                .accessibilityIdentifier("delete-yes")
            }
        }
        .padding(24)
        .frame(width: 380)
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
