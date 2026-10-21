import AppKit
import Foundation

/// Talks to the user's own Mac Steam: start, quit, launch games, read its state,
/// and pick Unwine as a game's compatibility tool. It never changes Steam.app itself.
enum MacSteam {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: SteamPlayPaths.steamApp.appendingPathComponent("Contents/MacOS/steam_osx").path)
    }

    static var isRunning: Bool { Processes.anyNamed("steam_osx") }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func start() {
        NSWorkspace.shared.openApplication(at: SteamPlayPaths.steamApp, configuration: NSWorkspace.OpenConfiguration())
    }

    static func play(_ appID: Int) { open("steam://rungameid/\(appID)") }
    static func showInSteam(_ appID: Int) { open("steam://nav/games/details/\(appID)") }
    static func openStore() { open("steam://store") }

    /// Asks Steam to quit and waits. Returns false if it is still running after the timeout.
    @discardableResult
    static func quit(timeout: Double = 60) async -> Bool {
        guard isRunning else { return true }
        open("steam://exit")
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return !isRunning
    }

    /// The client build, e.g. 1792192922, from Steam's own log. The log grows to megabytes and the
    /// refresh loop asks every few seconds, so a read is kept until the file changes, and the search
    /// starts from the end (the newest line wins). Reading and splitting the whole log each time was
    /// most of Unwine's idle CPU.
    static func clientVersion() -> String? {
        let log = SteamPlayPaths.steamLogs.appendingPathComponent("console_log.txt")
        guard let a = try? FileManager.default.attributesOfItem(atPath: log.path),
              let size = (a[.size] as? NSNumber)?.intValue, let date = a[.modificationDate] as? Date else { return nil }
        versionLock.lock()
        defer { versionLock.unlock() }
        if let c = versionCache, c.size == size, c.date == date { return c.version }
        var version: String?
        if let data = try? Data(contentsOf: log, options: .mappedIfSafe),
           let hit = data.range(of: Data("Client version: ".utf8), options: .backwards) {
            let rest = data[hit.upperBound...]
            let end = rest.firstIndex { $0 == 0x0A || $0 == 0x0D } ?? rest.endIndex
            version = String(decoding: rest[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        versionCache = (size, date, version)
        return version
    }
    private static let versionLock = NSLock()
    private static var versionCache: (size: Int, date: Date, version: String?)?

    // MARK: Steam Play status (read only)

    enum SteamPlayState: Equatable, Sendable {
        case off                    // no sign of Steam Play in Steam
        case on                     // Steam lists Unwine as a compatibility tool
        case outdated(String)       // Steam updated and Steam Play no longer matches it
    }

    /// Reads Steam Play's own log from Steam's latest start, plus Steam's tool folder.
    static func steamPlayState() -> SteamPlayState {
        let toolFile = SteamPlayPaths.compatTools.appendingPathComponent("\(Runner.toolName)/compatibilitytool.vdf")
        guard let text = try? String(contentsOf: SteamPlayPaths.addOnLog, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: toolFile.path) ? .on : .off
        }
        let lines = text.split(whereSeparator: \.isNewline)
        let start = lines.lastIndex { $0.contains("resolver: scanning steamclient.dylib") } ?? lines.startIndex
        let session = lines[start...]
        if let ready = session.last(where: { $0.contains("install_thread: ready,") }) {
            let parts = ready.components(separatedBy: "ready, ").last?.components(separatedBy: " ").first ?? ""
            let nums = parts.split(separator: "/").compactMap { Int($0) }
            if nums.count == 2, nums[0] < nums[1] { return .outdated(String(ready)) }
            return FileManager.default.fileExists(atPath: toolFile.path) ? .on : .off
        }
        if let sig = session.last(where: { $0.contains("signatures") && $0.contains("resolved") }) {
            return .outdated(String(sig))
        }
        return FileManager.default.fileExists(atPath: toolFile.path) ? .on : .off
    }

    // MARK: Per-game tool choice (Steam's config.vdf, only while Steam is closed)

    /// appid -> tool name, from CompatToolMapping.
    static func compatMappings() -> [Int: String] {
        guard let root = VDF.parse(contentsOf: SteamPlayPaths.configVDF),
              let steam = root["InstallConfigStore", "Software", "Valve", "Steam"],
              let mapping = steam["CompatToolMapping"] else { return [:] }
        var out: [Int: String] = [:]
        for (key, value) in mapping.entries {
            if let id = Int(key), let name = value["name"]?.string, !name.isEmpty { out[id] = name }
        }
        return out
    }

    enum ConfigError: LocalizedError {
        case steamRunning, unreadable

        var errorDescription: String? {
            switch self {
            case .steamRunning: return "Steam must be closed to change this."
            case .unreadable: return "Steam's settings file could not be read."
            }
        }
    }

    /// Sets (or with `tool == nil` removes) the compatibility tool for these games.
    /// Never touches app 0, which would switch every game at once. Keeps a backup.
    static func setCompatTool(_ tool: String?, for appIDs: [Int]) throws {
        guard !isRunning else { throw ConfigError.steamRunning }
        let ids = appIDs.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        let url = SteamPlayPaths.configVDF
        guard var text = try? String(contentsOf: url, encoding: .utf8), let before = VDF.parse(text) else { throw ConfigError.unreadable }
        let backups = Paths.support.appendingPathComponent("Backups", isDirectory: true)
        try Paths.ensure(backups)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(at: url, to: backups.appendingPathComponent("config.vdf.\(stamp)"))

        guard var steam = path(in: text, ["InstallConfigStore", "Software", "Valve", "Steam"]) else { throw ConfigError.unreadable }
        if block(named: "CompatToolMapping", in: text, from: steam.lowerBound, to: steam.upperBound) == nil {
            let insert = "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t}"
            let at = text.index(after: steam.lowerBound)
            text.insert(contentsOf: insert, at: at)
            steam = path(in: text, ["InstallConfigStore", "Software", "Valve", "Steam"]) ?? steam
        }
        for id in ids {
            guard let mapping = block(named: "CompatToolMapping", in: text, from: steam.lowerBound, to: text.endIndex) else { break }
            if let old = block(named: String(id), in: text, from: text.index(after: mapping.lowerBound), to: mapping.upperBound) {
                // Remove `"id" { ... }` including the key and its line break.
                let keyRange = text.range(of: "\"\(id)\"", options: .backwards, range: mapping.lowerBound..<old.lowerBound)
                let lineStart = keyRange.flatMap { text.range(of: "\n", options: .backwards, range: mapping.lowerBound..<$0.lowerBound)?.lowerBound }
                    ?? keyRange?.lowerBound ?? old.lowerBound
                text.removeSubrange(lineStart...old.upperBound)
            }
            if let tool, let mapping = block(named: "CompatToolMapping", in: text, from: steam.lowerBound, to: text.endIndex) {
                let entry = "\n\t\t\t\t\t\"\(id)\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"\(tool)\"\n\t\t\t\t\t\t\"config\"\t\t\"\"\n\t\t\t\t\t\t\"priority\"\t\t\"250\"\n\t\t\t\t\t}"
                text.insert(contentsOf: entry, at: text.index(after: mapping.lowerBound))
            }
            steam = path(in: text, ["InstallConfigStore", "Software", "Valve", "Steam"]) ?? steam
        }
        // Safety net: everything outside CompatToolMapping must read back exactly the same,
        // and the mapping must now say what we asked for. Otherwise nothing is written.
        guard let after = VDF.parse(text),
              canonical(before, skipping: "CompatToolMapping") == canonical(after, skipping: "CompatToolMapping") else {
            throw ConfigError.unreadable
        }
        let mapped = after["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
        for id in ids where mapped?[String(id)]?["name"]?.string != tool {
            if tool != nil || mapped?[String(id)] != nil { throw ConfigError.unreadable }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A stable text form of a VDF tree, leaving out every block named `skipping`.
    static func canonical(_ node: VDF, skipping: String) -> String {
        switch node {
        case .string(let s): return "\"" + s + "\""
        case .object(let items):
            let parts = items.filter { $0.key.caseInsensitiveCompare(skipping) != .orderedSame }
                .map { "\"" + $0.key.lowercased() + "\"" + canonical($0.value, skipping: skipping) }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    /// Range from a block's "{" to its matching "}" for the key `name` within bounds.
    private static func block(named name: String, in text: String, from: String.Index, to: String.Index) -> ClosedRange<String.Index>? {
        var search = from
        while search < to, let key = text.range(of: "\"\(name)\"", options: .caseInsensitive, range: search..<to) {
            var i = key.upperBound
            while i < to, text[i].isWhitespace { i = text.index(after: i) }
            guard i < to else { return nil }
            if text[i] == "{" {
                var depth = 0
                var inString = false
                var j = i
                while j < to {
                    let c = text[j]
                    if c == "\"" { inString.toggle() }
                    else if !inString && c == "{" { depth += 1 }
                    else if !inString && c == "}" {
                        depth -= 1
                        if depth == 0 { return i...j }
                    }
                    j = text.index(after: j)
                }
                return nil
            }
            search = key.upperBound
        }
        return nil
    }

    private static func path(in text: String, _ keys: [String]) -> ClosedRange<String.Index>? {
        var lower = text.startIndex
        var upper = text.endIndex
        var found: ClosedRange<String.Index>?
        for key in keys {
            guard let b = block(named: key, in: text, from: lower, to: upper) else { return nil }
            found = b
            lower = text.index(after: b.lowerBound)
            upper = b.upperBound
        }
        return found
    }
}
