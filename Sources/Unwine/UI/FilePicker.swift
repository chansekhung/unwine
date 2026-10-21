import AppKit
import UniformTypeIdentifiers

/// The Mac's Open panel for one file, with a message that says what the file is for. Unlike
/// SwiftUI's file importer, it can start in the game's own folder and needs no state in a view.
@MainActor
enum FilePicker {
    static func pick(message: String, prompt: String, extensions: [String], in folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        if let folder, FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
