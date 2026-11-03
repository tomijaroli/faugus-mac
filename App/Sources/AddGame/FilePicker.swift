import AppKit
import UniformTypeIdentifiers

/// `NSOpenPanel` wrappers shared by the editor, Settings and the run-file flow.
@MainActor
enum FilePicker {
    /// Picks one file or folder. Upstream's "Windows files" filter is not applied: the panel
    /// shows every file, as with upstream's "All files" choice.
    static func choose(message: String, directories: Bool = false, startIn: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = message
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.canCreateDirectories = directories
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if let startIn, !startIn.isEmpty {
            var directoryPath = (startIn as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory)
            if !(exists && isDirectory.boolValue) {
                directoryPath = (directoryPath as NSString).deletingLastPathComponent
            }
            if FileManager.default.fileExists(atPath: directoryPath) {
                panel.directoryURL = URL(fileURLWithPath: directoryPath)
            }
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseImage(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
