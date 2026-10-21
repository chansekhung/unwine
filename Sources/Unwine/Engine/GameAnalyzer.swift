import Foundation

/// The graphics API a game was built for, best guess first.
enum GraphicsAPI: String, Codable, Sendable {
    case dx12, dx11, dx10, dx9, dx8, opengl, vulkan, unknown

    var label: String {
        switch self {
        case .dx12: return "DirectX 12"
        case .dx11: return "DirectX 11"
        case .dx10: return "DirectX 10"
        case .dx9: return "DirectX 9"
        case .dx8: return "DirectX 8"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        case .unknown: return "Unknown"
        }
    }
}

/// What Unwine learned by looking inside a game's folder.
struct GameAnalysis: Codable, Sendable, Equatable {
    var api: GraphicsAPI
    var is64Bit: Bool
    var mainExe: String?          // path relative to the install folder
    var antiCheat: [String]       // human names, e.g. "Easy Anti-Cheat"
    var engine: String?           // "Unity", "Unreal", "Source", "Source 2", ...
    var analyzedAt: Date
    /// The `GameAnalyzer.version` that made this. Nil on analyses saved before versions existed,
    /// so those count as out of date.
    var analyzerVersion: Int?
    /// The game ships NVIDIA's DLSS (nvngx_dlss.dll), so MetalFX can take its place.
    var hasDLSS = false
    /// `GameAnalyzer.fingerprint` of the game when it was read. A new one means the game changed.
    var fingerprint: String? = nil

    /// False when a newer Unwine detects more than the one that made this, so it is worth redoing.
    var isCurrent: Bool { analyzerVersion == GameAnalyzer.version }
}

extension GameAnalysis {
    /// Fields added later decode with a default, so an analysis saved by an older Unwine still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api = try c.decode(GraphicsAPI.self, forKey: .api)
        is64Bit = try c.decode(Bool.self, forKey: .is64Bit)
        mainExe = try c.decodeIfPresent(String.self, forKey: .mainExe)
        antiCheat = try c.decode([String].self, forKey: .antiCheat)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        analyzedAt = try c.decode(Date.self, forKey: .analyzedAt)
        analyzerVersion = try c.decodeIfPresent(Int.self, forKey: .analyzerVersion)
        hasDLSS = (try? c.decodeIfPresent(Bool.self, forKey: .hasDLSS)) ?? false
        fingerprint = try? c.decodeIfPresent(String.self, forKey: .fingerprint)
    }
}

/// One clue to an anti-cheat in the name of a file or folder inside a game.
struct AntiCheatMarker: Sendable {
    /// Lower case. It must begin a word in the name, so "ace-base" does not match "surface-base".
    let needle: String
    /// What the UI calls it.
    let name: String
    /// The whole name must be the needle, for short names that mean something only on their own.
    var wholeName = false
    /// No letter may follow the needle, so "faceit" does not match "faceitems".
    var endsWord = false
    /// Only a file with this extension counts, which keeps folders and unrelated mods out.
    var fileExtension: String?

    /// `name` is a file or folder name in lower case; `ext` is its extension in lower case.
    func matches(_ name: String, extension ext: String) -> Bool {
        if let fileExtension, ext != fileExtension { return false }
        if wholeName { return name == needle }
        var from = name.startIndex
        while let found = name.range(of: needle, range: from..<name.endIndex) {
            let startsWord = found.lowerBound == name.startIndex || !name[name.index(before: found.lowerBound)].isLetterOrDigit
            let endsOK = !endsWord || found.upperBound == name.endIndex || !name[found.upperBound].isLetter
            if startsWord && endsOK { return true }
            from = name.index(after: found.lowerBound)
        }
        return false
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}

enum GameAnalyzer {
    /// Bump when detection changes, so games analysed by an older Unwine are looked at again.
    /// 4: DLSS, and the fingerprint that replaced the 7-day timer.
    static let version = 4

    /// What changes when the game changes: Steam's build id (the appmanifest's "buildid") for a Steam
    /// game, the program's size and date for one added by its .exe. Nil when neither can be read.
    /// One small file read or one file check, so it is cheap enough for every library visit.
    static func fingerprint(appID: Int, steamapps: URL, exe: URL?) -> String? {
        if let exe {
            // Read fresh: URL.resourceValues keeps the first answer on the URL object.
            guard let a = try? FileManager.default.attributesOfItem(atPath: exe.path),
                  let size = (a[.size] as? NSNumber)?.int64Value, let date = a[.modificationDate] as? Date else { return nil }
            return "exe:\(size):\(Int64(date.timeIntervalSince1970 * 1000))"
        }
        guard let app = VDF.parse(contentsOf: steamapps.appendingPathComponent("appmanifest_\(appID).acf"))?["AppState"] else { return nil }
        if let build = app["buildid"]?.string, !build.isEmpty, build != "0" { return "build:\(build)" }
        // Very old manifests have no build id; Steam still stamps each update.
        if let updated = app["LastUpdated"]?.string, !updated.isEmpty, updated != "0" { return "updated:\(updated)" }
        return nil
    }

    /// NVIDIA's DLSS file. Games keep it beside the program, or deep in an Unreal plugin folder
    /// (Engine/Plugins/Runtime/Nvidia/DLSS/Binaries/ThirdParty/Win64), deeper than the main walk goes.
    private static let dlssFile = "nvngx_dlss.dll"

    /// Plugin folders are walked this deep, and only for the DLSS file.
    private static let maxPluginLevel = 12

    /// An Unreal game added by its Project/Binaries/Win64 program: the DLSS plugin sits in the game's
    /// top folder, three levels up, next to the Engine folder that every packaged Unreal game has.
    private static func unrealRoot(above dir: URL) -> URL? {
        let parts = dir.standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard parts.count > 5, parts.suffix(2) == ["binaries", "win64"] else { return nil }
        let root = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Engine").path) ? root : nil
    }

    /// Looks for the DLSS file anywhere under `root`, but not in folders of game content, saves or videos.
    private static func findsDLSS(under root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return false }
        let skip: Set<String> = ["content", "saved", "movies", "paks", "redist", "_commonredist"]
        for case let url as URL in walker {
            let lower = url.lastPathComponent.lowercased()
            if lower == dlssFile { return true }
            if skip.contains(lower) || walker.level > maxPluginLevel { walker.skipDescendants() }
        }
        return false
    }

    /// Names of files and folders that give away an anti-cheat that no Wine tool on macOS can be sure
    /// to satisfy. Files alone never prove a game is blocked: the Advisor turns a hit into a warning.
    static let antiCheatMarkers: [AntiCheatMarker] = [
        AntiCheatMarker(needle: "easyanticheat", name: "Easy Anti-Cheat"),
        AntiCheatMarker(needle: "battleye", name: "BattlEye"),
        AntiCheatMarker(needle: "beservice", name: "BattlEye"),
        // Riot Vanguard is a driver (vgk.sys) and a service (vgc.exe). The word "vanguard" alone is
        // also the name of games and folders, so it is not a clue.
        AntiCheatMarker(needle: "vgk.sys", name: "Riot Vanguard", wholeName: true),
        AntiCheatMarker(needle: "vgc.exe", name: "Riot Vanguard", wholeName: true),
        AntiCheatMarker(needle: "xigncode", name: "XIGNCODE3"),
        AntiCheatMarker(needle: "gameguard", name: "nProtect GameGuard", endsWord: true),
        AntiCheatMarker(needle: "punkbuster", name: "PunkBuster"),
        AntiCheatMarker(needle: "pnkbstr", name: "PunkBuster"),
        AntiCheatMarker(needle: "eaanticheat", name: "EA Javelin Anti-Cheat"),
        AntiCheatMarker(needle: "mhyprot", name: "miHoYo Protect"),
        AntiCheatMarker(needle: "ace-base", name: "ACE (Tencent)"),
        AntiCheatMarker(needle: "equ8", name: "EQU8", endsWord: true),
        AntiCheatMarker(needle: "faceit", name: "FACEIT", endsWord: true),
        // Activision's Ricochet is a kernel driver. "ricochet" is also Valve's GoldSrc mod: a folder
        // and a ricochet.dll inside Half-Life, which are not anti-cheat.
        AntiCheatMarker(needle: "ricochet", name: "Ricochet", fileExtension: "sys"),
    ]

    private static let skipExeWords = ["unins", "crash", "redist", "setup", "vcredist", "vc_redist", "dxsetup",
                                       "directx", "dotnet", "uninstall", "report", "helper", "installer", "cefprocess",
                                       "easyanticheat", "be_service", "beservice", "touchup", "prereq", "ue4prereq"]

    /// DLL names that carry a game's renderer. Engines like Source and Unity keep the graphics API
    /// in these, not in the .exe (Left 4 Dead 2's exe is a 300 KB launcher), so we read them too.
    private static let rendererNeedles = ["shaderapi", "rendersystem", "materialsystem", "renderer", "gfx",
                                          "d3d", "vulkan", "opengl", "unityplayer"]

    /// Names to look for as plain text when nothing is imported by name.
    private static let apiDLLNames = ["d3d12.dll", "d3d11.dll", "d3d10.dll", "d3d9.dll", "d3d8.dll", "vulkan-1.dll"]

    /// Reading imports and text is the slow part, so a game with many matching DLLs gets the nearest ones.
    private static let maxRendererDLLs = 24

    /// Folder names (relative to the game's folder) above `url`, lowercased. `level` is the walker's depth.
    private static func folders(above url: URL, level: Int) -> [String] {
        url.pathComponents.suffix(level).dropLast().map { $0.lowercased() }
    }

    /// Redistributable installers (_CommonRedist, DirectX, ...) carry Windows' own files, not the game's.
    private static func isInRedist(_ folders: [String]) -> Bool {
        folders.contains { $0 == "redist" || $0 == "_commonredist" || $0.hasPrefix("directx") }
    }

    /// `mainExe` is the program the user picked for a game added by its .exe: it is read first, so
    /// the facts and advice describe it rather than the biggest .exe nearby.
    static func analyze(installDir: URL, mainExe: URL? = nil) -> GameAnalysis {
        let fm = FileManager.default
        var exes: [(url: URL, size: Int)] = []
        var rendererDLLs: [URL] = []
        var antiCheat = Set<String>()
        var engine: String?
        var hasAgilitySDK = false
        // Source clues. A Source game keeps bin/engine.dll beside a game folder holding gameinfo.txt.
        var hasSourceEngineDLL = false
        var hasSource2EngineDLL = false
        var hasGameInfo = false
        var hasShaderAPIDX9 = false
        var hasDLSS = false
        var pluginFolders: [String] = []    // paths of the "Plugins" folders seen, each ending in "/"

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        if let walker = fm.enumerator(at: installDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let level = walker.level
                let lower = url.lastPathComponent.lowercased()
                if lower == "plugins" { pluginFolders.append(url.path + "/") }
                if level > 5 {
                    // Deeper than this only plugin folders count, and only for the DLSS file.
                    if lower == dlssFile { hasDLSS = true }
                    if level > maxPluginLevel || (lower != "plugins" && !pluginFolders.contains { url.path.hasPrefix($0) }) {
                        walker.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                for marker in antiCheatMarkers where marker.matches(lower, extension: ext) { antiCheat.insert(marker.name) }
                if ext == "exe" {
                    if skipExeWords.contains(where: { lower.contains($0) }) { continue }
                    if isInRedist(folders(above: url, level: level)) { continue }   // e.g. a .NET installer
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    exes.append((url, size))
                } else if ext == "dll" {
                    let parents = folders(above: url, level: level)
                    switch lower {
                    case "unityplayer.dll": engine = "Unity"
                    case "gameassembly.dll": engine = engine ?? "Unity"
                    case "d3d12core.dll": hasAgilitySDK = true
                    case "engine.dll": if parents == ["bin"] || parents == ["bin", "win64"] { hasSourceEngineDLL = true }
                    case "engine2.dll": if parents.suffix(2) == ["bin", "win64"] { hasSource2EngineDLL = true }
                    case "shaderapidx9.dll": hasShaderAPIDX9 = true
                    case dlssFile: hasDLSS = true
                    default: break
                    }
                    if level <= 4, rendererNeedles.contains(where: { lower.contains($0) }), !isInRedist(parents) {
                        rendererDLLs.append(url)
                    }
                } else if lower == "gameinfo.txt", level == 2 {
                    hasGameInfo = true
                } else if lower == "engine", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          fm.fileExists(atPath: url.appendingPathComponent("Binaries").path) {
                    engine = "Unreal"
                }
            }
        }
        if engine == nil {
            if hasSource2EngineDLL { engine = "Source 2" }
            else if hasSourceEngineDLL && (hasGameInfo || hasShaderAPIDX9) { engine = "Source" }
        }
        if !hasDLSS, let root = unrealRoot(above: installDir) { hasDLSS = findsDLSS(under: root) }

        // The biggest real executable is almost always the game.
        exes.sort { $0.size > $1.size }
        var candidates = Array(exes.prefix(3))
        if let mainExe {
            let size = ((try? mainExe.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
            candidates.removeAll { $0.url.standardizedFileURL == mainExe.standardizedFileURL }
            candidates.insert((mainExe, size), at: 0)
        }
        var imports = Set<String>()
        var is64 = true
        for (i, c) in candidates.enumerated() {
            guard let info = PEInspector.inspect(c.url) else { continue }
            if i == 0 { is64 = info.is64Bit }
            imports.formUnion(info.imports)
        }
        let renderers = rendererDLLs
            .sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
            .prefix(maxRendererDLLs)
        for dll in renderers { if let info = PEInspector.inspect(dll) { imports.formUnion(info.imports) } }

        // Many engines load the renderer at runtime, so also look for DLL names as text.
        if !imports.contains(where: { $0.hasPrefix("d3d") }) {
            for file in (candidates.first.map { [$0.url] } ?? []) + renderers {
                imports.formUnion(PEInspector.fileMentions(file, anyOf: apiDLLNames))
            }
        }

        var api: GraphicsAPI
        if imports.contains("d3d12.dll") || hasAgilitySDK { api = .dx12 }
        else if imports.contains("d3d11.dll") { api = .dx11 }
        else if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("d3d10core.dll") { api = .dx10 }
        else if imports.contains("d3d9.dll") { api = .dx9 }
        else if imports.contains("d3d8.dll") { api = .dx8 }
        else if imports.contains("vulkan-1.dll") { api = .vulkan }
        else if imports.contains("opengl32.dll") { api = .opengl }
        else if imports.contains("dxgi.dll") { api = .dx11 }
        else { api = .unknown }

        // Source ships every shader API (Left 4 Dead 2 carries DX9, DX10 and Vulkan ones) but starts
        // on DirectX 9, so the highest import would be wrong. The DX9 layer is the one it really uses.
        if engine == "Source", hasShaderAPIDX9 { api = .dx9 }

        let main = candidates.first.map { String($0.url.path.dropFirst(installDir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return GameAnalysis(api: api, is64Bit: is64, mainExe: main, antiCheat: antiCheat.sorted(), engine: engine,
                            analyzedAt: Date(), analyzerVersion: version, hasDLSS: hasDLSS)
    }
}
