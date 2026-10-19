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

/// What Decant learned by looking inside a game's folder.
struct GameAnalysis: Codable, Sendable, Equatable {
    var api: GraphicsAPI
    var is64Bit: Bool
    var mainExe: String?          // path relative to the install folder
    var antiCheat: [String]       // human names, e.g. "Easy Anti-Cheat"
    var engine: String?           // "Unity", "Unreal", ...
    var analyzedAt: Date
}

enum GameAnalyzer {
    /// Kernel or "Windows-only" anti-cheat that no Wine tool on macOS (CrossOver included) can satisfy.
    static let antiCheatMarkers: [(needle: String, name: String)] = [
        ("easyanticheat", "Easy Anti-Cheat"),
        ("battleye", "BattlEye"),
        ("beservice", "BattlEye"),
        ("vgk.sys", "Riot Vanguard"),
        ("vanguard", "Riot Vanguard"),
        ("xigncode", "XIGNCODE3"),
        ("gameguard", "nProtect GameGuard"),
        ("punkbuster", "PunkBuster"),
        ("pnkbstr", "PunkBuster"),
        ("eaanticheat", "EA Javelin Anti-Cheat"),
        ("mhyprot", "miHoYo Protect"),
        ("ace-base", "ACE (Tencent)"),
        ("equ8", "EQU8"),
        ("faceit", "FACEIT"),
        ("ricochet", "Ricochet"),
    ]

    private static let skipExeWords = ["unins", "crash", "redist", "setup", "vcredist", "vc_redist", "dxsetup",
                                       "directx", "dotnet", "uninstall", "report", "helper", "installer", "cefprocess",
                                       "easyanticheat", "be_service", "beservice", "touchup", "prereq", "ue4prereq"]

    static func analyze(installDir: URL) -> GameAnalysis {
        let fm = FileManager.default
        var exes: [(url: URL, size: Int)] = []
        var dlls: [URL] = []
        var antiCheat = Set<String>()
        var engine: String?
        var hasAgilitySDK = false

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        if let walker = fm.enumerator(at: installDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if walker.level > 5 { walker.skipDescendants(); continue }
                let lower = url.lastPathComponent.lowercased()
                for marker in antiCheatMarkers where lower.contains(marker.needle) { antiCheat.insert(marker.name) }
                let ext = url.pathExtension.lowercased()
                if ext == "exe" {
                    if skipExeWords.contains(where: { lower.contains($0) }) { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    exes.append((url, size))
                } else if ext == "dll" {
                    switch lower {
                    case "unityplayer.dll": engine = "Unity"; dlls.append(url)
                    case "gameassembly.dll": engine = engine ?? "Unity"
                    case "d3d12core.dll": hasAgilitySDK = true
                    default: break
                    }
                } else if lower == "engine", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          fm.fileExists(atPath: url.appendingPathComponent("Binaries").path) {
                    engine = "Unreal"
                }
            }
        }

        // The biggest real executable is almost always the game.
        exes.sort { $0.size > $1.size }
        let candidates = Array(exes.prefix(3))
        var imports = Set<String>()
        var is64 = true
        for (i, c) in candidates.enumerated() {
            guard let info = PEInspector.inspect(c.url) else { continue }
            if i == 0 { is64 = info.is64Bit }
            imports.formUnion(info.imports)
        }
        for dll in dlls { if let info = PEInspector.inspect(dll) { imports.formUnion(info.imports) } }

        // Many engines load the renderer at runtime, so also look for DLL names as text.
        if !imports.contains(where: { $0.hasPrefix("d3d") }), let main = candidates.first?.url {
            imports.formUnion(PEInspector.fileMentions(main, anyOf: ["d3d12.dll", "d3d11.dll", "d3d10.dll", "d3d9.dll", "d3d8.dll", "vulkan-1.dll"]))
            for dll in dlls {
                imports.formUnion(PEInspector.fileMentions(dll, anyOf: ["d3d12.dll", "d3d11.dll", "d3d9.dll"]))
            }
        }

        let api: GraphicsAPI
        if imports.contains("d3d12.dll") || hasAgilitySDK { api = .dx12 }
        else if imports.contains("d3d11.dll") { api = .dx11 }
        else if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("d3d10core.dll") { api = .dx10 }
        else if imports.contains("d3d9.dll") { api = .dx9 }
        else if imports.contains("d3d8.dll") { api = .dx8 }
        else if imports.contains("vulkan-1.dll") { api = .vulkan }
        else if imports.contains("opengl32.dll") { api = .opengl }
        else if imports.contains("dxgi.dll") { api = .dx11 }
        else { api = .unknown }

        let main = candidates.first.map { String($0.url.path.dropFirst(installDir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return GameAnalysis(api: api, is64Bit: is64, mainExe: main, antiCheat: antiCheat.sorted(), engine: engine, analyzedAt: Date())
    }
}
