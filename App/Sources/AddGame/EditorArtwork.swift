import AppKit
import FaugusCore
import SwiftUI

/// Which image the editor is changing.
enum ArtworkSlot: Hashable, Identifiable {
    case cover, icon
    var id: Self {
        self
    }
}

/// The images of the Add / Edit dialog before they are saved. Files live in a per-dialog
/// temporary folder (upstream's `cover_path_temp` and `icon_temp`) and are copied into the data
/// folders on Confirm.
struct EditorArtworkDraft {
    let folder = NSTemporaryDirectory() + "faugus-editor-\(UUID().uuidString)"
    private(set) var cover: String?
    private(set) var icon: String?
    private var counter = 0
    var prepared = false

    mutating func nextPath(_ stem: String) -> String {
        counter += 1
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return "\(folder)/\(stem)-\(counter).png"
    }

    mutating func setCover(data: Data) -> Bool {
        let path = nextPath("cover")
        guard ImageTools.isValid(data), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        cover = path
        return true
    }

    mutating func setIcon(data: Data) -> Bool {
        guard let png = ImageTools.iconPNG(from: data, size: 256) else { return false }
        let path = nextPath("icon")
        guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        icon = path
        return true
    }

    mutating func clear(_ slot: ArtworkSlot) {
        switch slot {
        case .cover: cover = nil
        case .icon: icon = nil
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// The popup upstream shows when an image is clicked (Refresh is for SteamGridDB, which this
/// build does not have yet).
struct ArtworkMenu<Label: View>: View {
    let t: Translator
    let hasImage: Bool
    let loadFile: () -> Void
    let loadURL: () -> Void
    let remove: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button(t("Load from file"), action: loadFile)
            Button(t("Load from URL"), action: loadURL)
            Button(t("Remove"), action: remove).disabled(!hasImage)
        } label: {
            label()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

/// `on_load_url`: asks for an address and downloads it.
struct ImageURLPrompt: View {
    let t: Translator
    let slot: ArtworkSlot
    let done: (Data?) -> Void

    @State private var text = ""
    @State private var busy = false
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Enter the image URL")).font(.title3.weight(.semibold))
            TextField("", text: $text)
                .disabled(busy)
                .onSubmit { submit() }
                .accessibilityIdentifier("image-url")
            if invalid {
                Text(t("The selected file is not a valid image.")).foregroundStyle(.red)
                Text(t("Please choose another one.")).foregroundStyle(.secondary)
            }
            HStack {
                Button(t("Cancel"), role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button(t("Ok")) { submit() }
                    .keyboardShortcut(.defaultAction).frame(maxWidth: .infinity).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        guard let url = GameArtwork.validatedImageURL(text) else { invalid = true
            return
        }
        busy = true
        invalid = false
        Task {
            do {
                let data = try await GameArtwork.download(url)
                busy = false
                done(data)
            } catch {
                busy = false
                invalid = true
            }
        }
    }
}

/// An image file at a fixed size, or a placeholder when there is none.
struct TempImage<Placeholder: View>: View {
    let path: String?
    let size: CGSize
    var fill = false
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        ArtworkView(path: path ?? "", size: size, fill: fill, placeholder: placeholder)
    }
}
