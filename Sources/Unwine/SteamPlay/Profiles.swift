import Foundation

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
    static func write(appID: Int?, settings: GameSettings, renderer: Renderer,
                      engine: InstalledEngine, d3dmetal: D3DMetalInstall?, gameDir: URL? = nil) throws {
        try Paths.ensure(Runner.profiles)
        let (dxvk, dxmt) = configs(settings: settings, renderer: renderer, gameDir: gameDir)
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

    /// The DXVK and DXMT config files a game needs, or nil when Unwine has nothing to set.
    static func configs(settings s: GameSettings, renderer: Renderer, gameDir: URL?) -> (dxvk: String?, dxmt: String?) {
        func shipped(_ name: String) -> String {
            guard let dir = gameDir, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return "" }
            return "# From the game's own \(name):\n\(text)\n"
        }
        var dxvk: [String] = []
        if renderer != .wined3d {
            // DXVK 3 reads dxvk.maxFrameRate, older builds dxgi/d3d9.maxFrameRate; unknown keys are ignored.
            if let cap = s.fpsCap { dxvk += ["dxgi.maxFrameRate = \(cap)", "d3d9.maxFrameRate = \(cap)", "dxvk.maxFrameRate = \(cap)"] }
            if s.lowLatency { dxvk.append("dxvk.latencySleep = True") }
        }
        var dxmt: [String] = []
        // DXMT runs every layer choice except DXVK, WineD3D and a real D3DMetal (which has its own cap).
        if renderer == .dxmt || renderer == .auto, let cap = s.fpsCap {
            dxmt.append("d3d11.preferredMaxFrameRate = \(cap)")
        }
        let header = "# Written by Unwine. Settings from Steam's launch options still apply on top.\n"
        return (dxvk.isEmpty ? nil : header + shipped("dxvk.conf") + dxvk.joined(separator: "\n") + "\n",
                dxmt.isEmpty ? nil : header + shipped("dxmt.conf") + dxmt.joined(separator: "\n") + "\n")
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
            if engine.supports("WINEDLLPATH_D9VK") { export("WINEDLLPATH_D9VK", dir("d9vk")) }
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
            export("WINEDLLPATH_DXVK", FileManager.default.fileExists(atPath: three.path) ? three.path : dir("dxvk"))
            export("DXVK_ASYNC", "1")
            if let cap = s.fpsCap { export("DXVK_FRAME_RATE", String(cap)) }   // DXVK 1.x; 3.x reads the config file
        case .wined3d:
            break
        default: // .dxmt, .auto, or .d3dmetal without an import
            export("WINEDLLPATH_DXMT", dir("dxmt"))
            export("DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN", "1")
            if s.metalFX { export("DXMT_ENABLE_NVEXT", "1") }
            // Bottles run without Retina mode, so a game draws at the screen's point size and
            // DXMT's default 2x MetalFX output lands on the screen's real pixels.
            if s.metalFXSpatial { export("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1") }
            if hasDXMTConfig { export("DXMT_CONFIG_FILE", dxmtConfig(for: appID).path) }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
