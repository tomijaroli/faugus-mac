import FaugusCore
import SwiftUI

/// "Manage Categories" (`on_manage_categories_clicked`): add, edit and remove.
struct CategoryManagerView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var selected: String?
    @State private var newName = ""
    @State private var editing: String?
    @State private var editName = ""
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case new, edit }

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 12) {
            Text(translate("Manage Categories")).font(.title3.weight(.semibold))
            List(selection: $selected) {
                ForEach(model.categoryNames, id: \.self) { name in
                    if editing == name {
                        TextField("", text: $editName)
                            .labelsHidden()
                            .focused($focus, equals: .edit)
                            .onSubmit { commitEdit(name) }
                            .onExitCommand { editing = nil }
                    } else {
                        Text(name).tag(name)
                    }
                }
                if editing?.isEmpty == true {
                    TextField("", text: $newName)
                        .labelsHidden()
                        .focused($focus, equals: .new)
                        .onSubmit { commitAdd() }
                        .onExitCommand { editing = nil }
                }
            }
            .frame(minHeight: 200)
            .border(Color.secondary.opacity(0.3))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(translate("Add")) {
                    newName = ""
                    editing = ""
                    error = nil
                    focus = .new
                }
                Button(translate("Edit")) {
                    guard let selectedName = selected else { return }
                    editName = selectedName
                    editing = selectedName
                    error = nil
                    focus = .edit
                }
                .disabled(selected == nil)
                Button(translate("Remove"), role: .destructive) {
                    guard let selectedName = selected else { return }
                    _ = model.removeCategory(selectedName)
                    selected = nil
                }
                .disabled(selected == nil)
                Spacer()
                Button(translate("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 400)
    }

    private func commitAdd() {
        let name = newName
        editing = nil
        // Like upstream, an empty, reserved or duplicate name is dropped silently.
        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = model.addCategory(name)
        }
    }

    private func commitEdit(_ oldName: String) {
        let renamedName = editName
        editing = nil
        if model.renameCategory(oldName, to: renamedName) == nil {
            selected = renamedName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
