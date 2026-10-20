import Foundation

/// Where Unwine keeps things.
///
/// Machine-local parts (engine, graphics layers, logs) live in Application Support and are
/// re-downloaded on a new Mac. The *library* folder (Windows Steam + games + per-game settings)
/// is portable: copy it to a new Mac and point Unwine at it.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LegacyFolder.migrate(from: base.appendingPathComponent("Decant", isDirectory: true),
                                    to: base.appendingPathComponent("Unwine", isDirectory: true))
    }()

    static var engines: URL { support.appendingPathComponent("Engines", isDirectory: true) }
    static var layers: URL { support.appendingPathComponent("Graphics", isDirectory: true) }
    static var downloads: URL { support.appendingPathComponent("Downloads", isDirectory: true) }
    static var logs: URL { support.appendingPathComponent("Logs", isDirectory: true) }
    static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    static var defaultLibrary: URL { support.appendingPathComponent("Library", isDirectory: true) }

    /// Inside a library folder.
    static func bottle(in library: URL) -> URL { library.appendingPathComponent("Bottle", isDirectory: true) }
    static func profilesFile(in library: URL) -> URL { library.appendingPathComponent("Unwine Library.json") }

    @discardableResult
    static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A library folder is valid if it has our marker file or a Wine bottle inside.
    static func looksLikeLibrary(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: profilesFile(in: url).path)
            || fm.fileExists(atPath: bottle(in: url).appendingPathComponent("system.reg").path)
    }
}
