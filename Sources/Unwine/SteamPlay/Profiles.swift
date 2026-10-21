import AppKit

/// What the user picked for one game. Stored in Unwine's settings; turned into a shell
/// profile the runner wrappers read at every launch, so changes apply next time the game starts.
struct GameSettings: Codable, Equatable, Sendable {
    var renderer: Renderer = .auto
    var msync = true
    var advertiseAVX = true
    var metalHUD = false
    var metalFX = false                 // the game's DLSS becomes MetalFX (DirectX 11/12 games with DLSS)
    var metalFXSpatial = false          // DXMT draws the game's picture 2x larger with MetalFX (any DirectX 10/11 game)
    var metal4 = true
    var rayTracing: Bool? = nil
    var fpsCap: Int? = nil
    var lowLatency = false              // DXVK's latency sleep, a Reflex-like wait before the game reads input
    var asyncShaders = true             // DirectX 8/9: build new shaders in the background, never stop the game for one
    var fps120 = false                  // 120 fps mode: DXMT paces DirectX 10/11 games to the screen's refresh, not a 60 Hz game mode
}

extension GameSettings {
    /// Every field decodes with a default, so settings saved by an older Unwine keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        renderer = (try? c.decodeIfPresent(Renderer.self, forKey: .renderer)) ?? d.renderer
        msync = (try? c.decodeIfPresent(Bool.self, forKey: .msync)) ?? d.msync
        advertiseAVX = (try? c.decodeIfPresent(Bool.self, forKey: .advertiseAVX)) ?? d.advertiseAVX
        metalHUD = (try? c.decodeIfPresent(Bool.self, forKey: .metalHUD)) ?? d.metalHUD
        metalFX = (try? c.decodeIfPresent(Bool.self, forKey: .metalFX)) ?? d.metalFX
        metalFXSpatial = (try? c.decodeIfPresent(Bool.self, forKey: .metalFXSpatial)) ?? d.metalFXSpatial
        metal4 = (try? c.decodeIfPresent(Bool.self, forKey: .metal4)) ?? d.metal4
        rayTracing = (try? c.decodeIfPresent(Bool.self, forKey: .rayTracing)) ?? d.rayTracing
        fpsCap = (try? c.decodeIfPresent(Int.self, forKey: .fpsCap)) ?? d.fpsCap
        lowLatency = (try? c.decodeIfPresent(Bool.self, forKey: .lowLatency)) ?? d.lowLatency
        asyncShaders = (try? c.decodeIfPresent(Bool.self, forKey: .asyncShaders)) ?? d.asyncShaders
        fps120 = (try? c.decodeIfPresent(Bool.self, forKey: .fps120)) ?? d.fps120
    }
}

enum Profiles {
    static func file(for appID: Int?) -> URL {
        Runner.profiles.appendingPathComponent(appID.map { "\($0).env" } ?? "default.env")
    }

    /// DXVK and DXMT settings go in config files, not in DXVK_CONFIG / DXMT_CONFIG, so a value the
    /// user sets in Steam's launch options still applies (DXVK and DXMT read the variable over the file).
    static func dxvkConfig(for appID: Int?) -> URL {
        Runner.profiles.appendingPathComponent(appID.map { "\($0).dxvk.conf" } ?? "default.dxvk.conf")
    }

    static func dxmtConfig(for appID: Int?) -> URL {
        Runner.profiles.appendingPathComponent(appID.map { "\($0).dxmt.conf" } ?? "default.dxmt.conf")
    }

    /// Picks the real layer for `.auto` from what the game's files say it uses.
    static func resolve(_ choice: Renderer, analysis: GameAnalysis?, hasD3DMetal: Bool) -> Renderer {
        guard choice == .auto else {
            if choice == .d3dmetal && !hasD3DMetal { return .dxmt }
            return choice
        }
        guard let analysis else { return .dxmt }
        switch analysis.api {
        case .dx12:
            return hasD3DMetal && analysis.is64Bit ? .d3dmetal : .dxvk
        case .dx11, .dx10, .unknown:
            return .dxmt
        case .dx9, .dx8:
            return .dxmt          // the DXMT profile also carries DXVK's DirectX 9 layer
        case .opengl:
            return .wined3d
        case .vulkan:
            return .wined3d       // no DirectX layer needed; Vulkan goes straight to KosmicKrisp
        }
    }

    /// Writes the profile for one game (or the default one when `appID` is nil). `gameDir` lets a
    /// dxvk.conf or dxmt.conf that ships with the game keep working: Unwine's file starts with it.
    static func write(appID: Int?, settings: GameSettings, renderer: Renderer, api: GraphicsAPI? = nil,
                      engine: InstalledEngine, d3dmetal: D3DMetalInstall?, gameDir: URL? = nil) throws {
        try Paths.ensure(Runner.profiles)
        let (dxvk, dxmt) = configs(settings: settings, renderer: renderer, api: api, gameDir: gameDir)
        try writeOrRemove(dxvk, at: dxvkConfig(for: appID))
        try writeOrRemove(dxmt, at: dxmtConfig(for: appID))
        let text = render(appID: appID, settings: settings, renderer: renderer, engine: engine, d3dmetal: d3dmetal,
                          hasDXVKConfig: dxvk != nil, hasDXMTConfig: dxmt != nil)
        try text.write(to: file(for: appID), atomically: true, encoding: .utf8)
    }

    static func remove(appID: Int) {
        for url in [file(for: appID), dxvkConfig(for: appID), dxmtConfig(for: appID)] { try? FileManager.default.removeItem(at: url) }
    }

    private static func writeOrRemove(_ text: String?, at url: URL) throws {
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    /// The main screen's top refresh rate: 120 on a ProMotion Mac. Wine shows games this screen
    /// as its primary one. Profiles are written again at every Play, so a new screen counts then.
    static var screenHz: Int { NSScreen.screens.first?.maximumFramesPerSecond ?? 60 }

    /// The DXVK and DXMT config files a game needs, or nil when Unwine has nothing to set.
    static func configs(settings s: GameSettings, renderer: Renderer, api: GraphicsAPI? = nil, gameDir: URL?,
                        screenHz: Int = Profiles.screenHz) -> (dxvk: String?, dxmt: String?) {
        func shipped(_ name: String) -> String {
            guard let dir = gameDir, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return "" }
            return "# From the game's own \(name):\n\(text)\n"
        }
        var dxvk: [String] = []
        if renderer != .wined3d {
            // DXVK 3 reads dxvk.maxFrameRate, older builds dxgi/d3d9.maxFrameRate; unknown keys are ignored.
            if let cap = s.fpsCap { dxvk += ["dxgi.maxFrameRate = \(cap)", "d3d9.maxFrameRate = \(cap)", "dxvk.maxFrameRate = \(cap)"] }
            if s.lowLatency { dxvk.append("dxvk.latencySleep = True") }
            // Background shader builds, said out loud so no build default decides it.
            dxvk.append(s.asyncShaders ? "dxvk.enableAsync = True" : "dxvk.enableAsync = False")
            // A DirectX 10/11/12 game can open a DirectX 9 device on its own window only to decode
            // videos (Romance of the Three Kingdoms XIV). On a Mac every swap chain adds its own layer
            // to the window, and the DirectX 9 one never draws, so it hid the whole game: a black
            // screen with music. With this, DXVK makes that layer only when DirectX 9 really presents.
            if api != .dx9 && api != .dx8 { dxvk.append("d3d9.deferSurfaceCreation = True") }
        }
        var dxmt: [String] = []
        // DXMT runs every layer choice except DXVK, WineD3D and a real D3DMetal (which has its own cap).
        if renderer == .dxmt || renderer == .auto {
            if let cap = s.fpsCap {
                dxmt.append("d3d11.preferredMaxFrameRate = \(cap)")
            } else if s.fps120 && screenHz > 60 {
                // A game in a 60 Hz full-screen mode gets paced to 60 by DXMT, though the Mac screen
                // stays at its own rate. The user's own cap above wins over this.
                dxmt.append("# 120 fps mode: pace to the screen's \(screenHz) Hz, not the game's display mode.")
                dxmt.append("d3d11.preferredMaxFrameRate = \(screenHz)")
            }
        }
        // A game's own dxvk.conf or dxmt.conf counts too: Unwine's file replaces the game's, so it carries it.
        let header = "# Written by Unwine. Settings from Steam's launch options still apply on top.\n"
        let ownDXVK = renderer != .wined3d ? shipped("dxvk.conf") : "", ownDXMT = shipped("dxmt.conf")
        return (dxvk.isEmpty && ownDXVK.isEmpty ? nil : header + ownDXVK + dxvk.joined(separator: "\n") + "\n",
                dxmt.isEmpty && ownDXMT.isEmpty ? nil : header + ownDXMT + dxmt.joined(separator: "\n") + "\n")
    }

    static func render(appID: Int?, settings s: GameSettings, renderer: Renderer,
                       engine: InstalledEngine, d3dmetal: D3DMetalInstall?,
                       hasDXVKConfig: Bool = false, hasDXMTConfig: Bool = false) -> String {
        let q = Runner.shellQuote
        var out = ["# Written by Unwine for \(appID.map { "Steam app \($0)" } ?? "games without their own settings").",
                   "# Renderer: \(renderer.rawValue)"]
        func export(_ k: String, _ v: String) { out.append("export \(k)=\(q(v))") }
        func dir(_ name: String) -> String { engine.renderer(name).path }

        export("WINEMSYNC", s.msync && engine.supportsMsync ? "1" : "0")
        export("ROSETTA_ADVERTISE_AVX", s.advertiseAVX ? "1" : "0")
        if s.metalHUD { export("MTL_HUD_ENABLED", "1") }

        // DirectX 9 and DirectDraw helpers ride along with every modern layer.
        if renderer != .wined3d {
            // Unwine's copy lets DXVK's background shader builds reach the game's main picture too, and
            // keeps a texture the Mac cannot share from closing the game. It is used with async shaders
            // off as well: the crash fix applies either way, and the async fix then does nothing.
            let d9vk = RendererPatches.fixedDir("d9vk", engine: engine)?.path
            if engine.supports("WINEDLLPATH_D9VK") { export("WINEDLLPATH_D9VK", d9vk ?? dir("d9vk")) }
            if engine.supports("WINEDLLPATH_CNCD") { export("WINEDLLPATH_CNCD", dir("cnc_ddraw")) }
            // DXVK (also behind the DirectX 9 helper) reads the frame cap and latency sleep from its file.
            if hasDXVKConfig { export("DXVK_CONFIG_FILE", dxvkConfig(for: appID).path) }
        }

        switch renderer {
        case .d3dmetal where d3dmetal != nil:
            let d = d3dmetal!
            export("WINEDLLPATH_D3DMETAL", d.wineDir.path)
            export("CX_APPLEGPTK_LIBD3DSHARED_PATH", d.libd3dshared.path)
            out.append("export DYLD_FALLBACK_LIBRARY_PATH=\(q(d.externalDir.path)):\"$DYLD_FALLBACK_LIBRARY_PATH\"")
            if s.metalFX { export("D3DM_ENABLE_METALFX", "1") }
            if let rt = s.rayTracing { export("D3DM_SUPPORT_DXR", rt ? "1" : "0") }
            if d.isVersion4 {
                export("D3DM_MTL4", s.metal4 ? "1" : "0")
                if let cap = s.fpsCap { export("D3DM_MAX_FPS", String(cap)) }
            }
        case .dxvk:
            let three = engine.renderer("dxvk3")
            let patched = RendererPatches.fixedDir("dxvk3", engine: engine)
            export("WINEDLLPATH_DXVK", patched?.path ?? (FileManager.default.fileExists(atPath: three.path) ? three.path : dir("dxvk")))
            export("DXVK_ASYNC", s.asyncShaders ? "1" : "0")
            if let cap = s.fpsCap { export("DXVK_FRAME_RATE", String(cap)) }   // DXVK 1.x; 3.x reads the config file
        case .wined3d:
            break
        default: // .dxmt, .auto, or .d3dmetal without an import
            export("WINEDLLPATH_DXMT", dir("dxmt"))
            export("DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN", "1")
            if s.metalFX { export("DXMT_ENABLE_NVEXT", "1") }
            // Steam Play bottles run without Retina mode (Online mode's follows its High Resolution
            // Mode switch), so a game draws at the screen's point size and DXMT's default 2x MetalFX
            // output lands on the screen's real pixels.
            if s.metalFXSpatial { export("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1") }
            if hasDXMTConfig { export("DXMT_CONFIG_FILE", dxmtConfig(for: appID).path) }
        }
        out += LaunchOptions.profileLines(for: appID)   // the game page's language, DLL overrides and extra settings
        return out.joined(separator: "\n") + "\n"
    }
}
