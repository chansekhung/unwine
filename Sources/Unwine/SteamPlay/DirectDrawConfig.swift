import Foundation

/// How cnc-ddraw shows a DirectDraw game: the game's own mode, in a window, or full screen.
enum DirectDrawMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, window, fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "The game's choice"
        case .window: return "In a window"
        case .fullScreen: return "Full screen"
        }
    }
}

/// cnc-ddraw draws DirectDraw games under every layer but WineD3D. It keeps its settings in a ddraw.ini:
/// one next to its DLL (Wine says the bottle's system folder), else one in the game's folder, and it
/// writes its default file there when it finds none. The engine's cnc-ddraw (7.1) reads the path in
/// CNC_DDRAW_CONFIG_FILE first, and writes its default file at that path when it is missing (both
/// checked in its ddraw.dll). So a DirectDraw game's profile names Unwine's own file, and the game's
/// files stay as they are.
enum DirectDrawConfig {
    static func file(for appID: Int?) -> URL {
        Runner.profiles.appendingPathComponent(appID.map { "\($0).ddraw.ini" } ?? "default.ddraw.ini")
    }

    /// The path as Windows programs name it: Wine's Z: drive is the Mac's /.
    static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }

    /// The Mac file of a Windows path on the Z: drive (the reverse of `windowsPath`), or nil for another drive.
    static func macPath(_ windows: String) -> URL? {
        guard windows.count > 2, windows.prefix(2).lowercased() == "z:" else { return nil }
        return URL(fileURLWithPath: windows.dropFirst(2).replacingOccurrences(of: "\\", with: "/"))
    }

    private static let header = "; Written by Unwine. cnc-ddraw reads this file, not a ddraw.ini in the game's folder, so the game's files stay as they are."

    /// DirectDraw games read as "unknown" (DirectDraw alone), or as DirectX 8 or 9 when they use those too.
    /// Only their folders are searched, so a newer game costs nothing.
    static func mayUse(_ api: GraphicsAPI?) -> Bool { api == .unknown || api == .dx8 || api == .dx9 }

    /// Writes or removes Unwine's ddraw.ini for a game. True when the game uses DirectDraw, so its
    /// profile names the file. With nothing to set and no ddraw.ini of the game's own, Unwine writes no
    /// file: cnc-ddraw then makes its default one there, never in the game's folder.
    static func write(appID: Int?, settings: GameSettings, api: GraphicsAPI?, gameDir: URL?, engine: InstalledEngine) -> Bool {
        guard let appID, let gameDir else { return false }
        let url = file(for: appID)
        let found = mayUse(api) ? programs(in: gameDir) : []
        guard !found.isEmpty else { removeOwn(url); return false }
        if let text = text(settings: settings, programs: found, gameDir: gameDir, engine: engine) {
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
        } else {
            removeOwn(url)
        }
        return true
    }

    /// A file cnc-ddraw made itself (it saves the window's place there) stays; only Unwine's goes.
    private static func removeOwn(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix(header) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The file for a DirectDraw game, or nil when Unwine has nothing to set and the game has no ddraw.ini.
    /// It starts from the game's own ddraw.ini, else from cnc-ddraw's defaults (kept inside ddraw.dll,
    /// with its fixes for named games), and sets the player's choices in it.
    static func text(settings s: GameSettings, programs: [URL], gameDir: URL, engine: InstalledEngine) -> String? {
        var keys: [(String, String)] = []
        switch s.ddrawMode {
        case .auto: break
        case .window: keys += [("windowed", "true"), ("fullscreen", "false")]
        // A borderless window over the whole screen, so macOS keeps its display mode, and the game keeps its shape.
        case .fullScreen: keys += [("windowed", "true"), ("fullscreen", "true"), ("maintas", "true")]
        }
        // The game's frame cap: cnc-ddraw draws at most that many frames a second (not the game's speed).
        if let cap = s.fpsCap { keys.append(("maxfps", String(cap))) }
        let own = ([programs.first?.deletingLastPathComponent(), gameDir].compactMap { $0 })
            .lazy.compactMap { readText($0.appendingPathComponent("ddraw.ini")) }.first
        guard own != nil || !keys.isEmpty else { return nil }
        let base = own ?? defaults(engine) ?? "[ddraw]\n"
        let names = programs.map { $0.deletingPathExtension().lastPathComponent }
        let note = own != nil ? "; It starts with the game's own ddraw.ini." : "; It starts with cnc-ddraw's own defaults."
        return header + "\n" + note + "\n\n" + set(keys, in: base, programs: names) + "\n"
    }

    /// Sets `keys` in the first [ddraw] section, adding the ones it lacks under its header: Wine reads
    /// only the first section of a name. A game's own sections ([game], [game/2], [game/wine]) come first
    /// for cnc-ddraw, so a key they set is changed there too.
    static func set(_ keys: [(String, String)], in text: String, programs: [String]) -> String {
        guard !keys.isEmpty else { return text }
        let games = Set(programs.map { $0.lowercased() })
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var section: String?
        var firstDDraw: Int?
        var inFirstDDraw = false
        var done = Set<String>()
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                let name = t[t.index(after: t.startIndex)..<close].lowercased()
                section = name
                inFirstDDraw = name == "ddraw" && firstDDraw == nil
                if inFirstDDraw { firstDDraw = i }
                continue
            }
            guard let section, !t.hasPrefix(";"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = keys.first(where: { $0.0 == key })?.1 else { continue }
            let game = String(section.split(separator: "/").first ?? Substring(section))
            if inFirstDDraw || games.contains(game) {
                lines[i] = "\(key)=\(value)"
                if inFirstDDraw { done.insert(key) }
            }
        }
        let missing = keys.filter { !done.contains($0.0) }.map { "\($0.0)=\($0.1)" }
        if let at = firstDDraw { lines.insert(contentsOf: missing, at: at + 1) } else { lines.insert(contentsOf: ["[ddraw]"] + missing + [""], at: 0) }
        return lines.joined(separator: "\n")
    }

    /// cnc-ddraw's default ddraw.ini, as the engine's ddraw.dll writes it when it finds none.
    static func defaults(_ engine: InstalledEngine) -> String? {
        let dll = engine.renderer("cnc_ddraw").appendingPathComponent("i386-windows/ddraw.dll")
        lock.lock()
        defer { lock.unlock() }
        if let hit = defaultsCache, hit.path == dll.path { return hit.text }
        var text: String?
        if let data = try? Data(contentsOf: dll, options: .mappedIfSafe),
           let start = data.range(of: Data("; cnc-ddraw - https://github.com/FunkyFr3sh/cnc-ddraw".utf8))?.lowerBound {
            let end = data[start...].firstIndex(of: 0) ?? data.endIndex
            let found = String(decoding: data[start..<end], as: UTF8.self)
            if found.contains("[ddraw]") { text = found }
        }
        defaultsCache = (dll.path, text)
        return text
    }

    /// The programs in a game's folder, and one level down, that use DirectDraw: they import ddraw.dll,
    /// or (an older program that loads it by name) mention it and use no newer graphics API. Read once
    /// per folder until the folder changes. Profiles are written on the main thread, so only a small
    /// program is read as text: DirectDraw-era programs are a few MB.
    static func programs(in gameDir: URL) -> [URL] {
        let fm = FileManager.default
        let date = (try? fm.attributesOfItem(atPath: gameDir.path))?[.modificationDate] as? Date
        lock.lock()
        if let hit = programsCache[gameDir.path], hit.date == date { lock.unlock(); return hit.programs }
        lock.unlock()
        let skip = ["unins", "setup", "install", "redist", "dxsetup", "crash", "report", "dotnet", "directx"]
        let newer: Set<String> = ["d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "vulkan-1.dll", "opengl32.dll"]
        var found: [URL] = []
        for (exe, size) in LocalGames.programs(in: gameDir) {
            let name = exe.lastPathComponent.lowercased()
            guard !skip.contains(where: name.contains), let info = PEInspector.inspect(exe) else { continue }
            if info.imports.contains("ddraw.dll")
                || (size < 16_000_000 && info.imports.isDisjoint(with: newer) && !PEInspector.fileMentions(exe, anyOf: ["ddraw.dll"]).isEmpty) {
                found.append(exe)
            }
        }
        lock.lock()
        programsCache[gameDir.path] = (date, found)
        lock.unlock()
        return found
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static let lock = NSLock()
    private static var defaultsCache: (path: String, text: String?)?
    private static var programsCache: [String: (date: Date?, programs: [URL])] = [:]
}
