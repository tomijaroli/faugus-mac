import FaugusCore
import SwiftUI

/// List mode (P0: renders the empty list and the toolbar with upstream's translated labels).
struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var selection: String?

    var body: some View {
        let t = model.translator
        List(model.games, selection: $selection) { game in
            Text(game.title)
        }
        .overlay {
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).padding()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(t("Add"), systemImage: "plus") {}
                    .help(t("Add"))
                Button(t("Settings"), systemImage: "gearshape") {}
                    .help(t("Settings"))
            }
        }
        .navigationTitle("Faugus")
        .environment(\.layoutDirection, model.isRightToLeft ? .rightToLeft : .leftToRight)
        .accessibilityIdentifier("library-list")
    }
}
