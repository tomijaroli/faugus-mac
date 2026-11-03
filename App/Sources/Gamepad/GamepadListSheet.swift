import FaugusCore
import SwiftUI

/// Gamepad-friendly list used for the power menu and the Y-button context menu
/// (upstream's Gtk.Popover that D-pad and A can walk).
struct GamepadListSheet: View {
    let model: AppModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.gamepadOverlayTitle).font(.title3.weight(.semibold))
            ForEach(Array(model.gamepadOverlayItems.enumerated()), id: \.offset) { index, item in
                Button {
                    activate(index)
                } label: {
                    HStack {
                        Text(item.title)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        index == model.gamepadOverlayIndex
                            ? Color.accentColor.opacity(0.25)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }
        }
        .padding(16)
        .frame(minWidth: 280)
        .onChange(of: model.gamepadOverlayConfirm) { _, shouldConfirm in
            if shouldConfirm {
                model.gamepadOverlayConfirm = false
                activate(model.gamepadOverlayIndex)
            }
        }
    }

    private func activate(_ index: Int) {
        guard model.gamepadOverlayItems.indices.contains(index) else { return }
        let item = model.gamepadOverlayItems[index]
        guard item.isEnabled else { return }
        SoundPlayer.shared.play(.confirm)
        item.action()
        dismiss()
    }
}
