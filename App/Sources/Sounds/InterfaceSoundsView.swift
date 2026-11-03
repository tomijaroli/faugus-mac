import FaugusCore
import SwiftUI

/// Upstream's `InterfaceSoundsDialog`. Ok writes into the Settings draft; Cancel restores it.
struct InterfaceSoundsView: View {
    let model: AppModel
    @Binding var configuration: FaugusConfig
    let dismiss: () -> Void

    @State private var settings: InterfaceSoundsSettings
    @State private var original: InterfaceSoundsSettings

    init(model: AppModel, configuration: Binding<FaugusConfig>, dismiss: @escaping () -> Void) {
        self.model = model
        _configuration = configuration
        self.dismiss = dismiss
        let initial = InterfaceSoundsSettings(configuration: configuration.wrappedValue)
        _settings = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    var body: some View {
        let translate = model.translator
        VStack(alignment: .leading, spacing: 16) {
            Text(translate("Interface Sounds")).font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 20) {
                generalColumn(translate)
                filesColumn(translate)
            }
            HStack {
                Button(translate("Cancel")) { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button(translate("Ok")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 640)
        .onAppear {
            SoundPlayer.shared.previewSettings = settings
        }
        .onDisappear {
            SoundPlayer.shared.previewSettings = nil
        }
        .onChange(of: settings) { _, newSettings in
            newSettings.write(to: &configuration)
            SoundPlayer.shared.previewSettings = newSettings
        }
    }

    private func generalColumn(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(translate("Enable"), isOn: $settings.isEnabled)
            Text(translate("Sound"))
            Picker("", selection: $settings.theme) {
                ForEach(UISoundTheme.allCases, id: \.self) { theme in
                    Text(themeLabel(theme, translate)).tag(theme)
                }
            }
            .labelsHidden()
            .disabled(!settings.isEnabled)
            Text(translate("Volume"))
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(settings.volumePercent) },
                        set: { settings.volumePercent = Int($0.rounded()) }
                    ),
                    in: 0 ... 100, step: 1
                )
                .onChange(of: settings.volumePercent) { _, _ in
                    if settings.isEnabled {
                        SoundPlayer.shared.play(.navigate)
                    }
                }
                Text("\(settings.volumePercent)").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            .disabled(!settings.isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filesColumn(_ translate: Translator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(UISoundKind.allCases, id: \.self) { kind in
                Text(kindLabel(kind, translate))
                HStack {
                    TextField(
                        "",
                        text: Binding(
                            get: { settings.customPaths[kind] ?? "" },
                            set: { settings.customPaths[kind] = $0 }
                        ),
                        prompt: Text(translate("Sound file"))
                    )
                    .disabled(!settings.isEnabled || settings.theme != .custom)
                    Button {
                        if let path = FilePicker.choose(message: translate("Sound file")) {
                            settings.customPaths[kind] = path
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(!settings.isEnabled || settings.theme != .custom)
                    .help(translate("Sound file"))
                    Button {
                        SoundPlayer.shared.preview(kind: kind, settings: settings)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(!settings.isEnabled)
                    .help(translate("Preview"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themeLabel(_ theme: UISoundTheme, _ translate: Translator) -> String {
        switch theme {
        case .cloud: "\(theme.settingsLabel) (\(translate("Default")))"
        case .custom: translate("Custom")
        default: theme.settingsLabel
        }
    }

    private func kindLabel(_ kind: UISoundKind, _ translate: Translator) -> String {
        switch kind {
        case .navigate: translate("Navigate")
        case .confirm: translate("Confirm")
        case .cancel: translate("Cancel")
        case .warning: translate("Warning")
        }
    }

    private func cancel() {
        original.write(to: &configuration)
        SoundPlayer.shared.play(.cancel)
        dismiss()
    }

    private func save() {
        settings.write(to: &configuration)
        SoundPlayer.shared.play(.confirm)
        dismiss()
    }
}
