import Foundation

/// What the user picked for one game. Stored in Decant's settings; turned into a shell
/// profile the runner wrappers read at every launch, so changes apply next time the game starts.
struct GameSettings: Codable, Equatable, Sendable {
    var renderer: Renderer = .auto
    var msync = true
    var advertiseAVX = true
    var metalHUD = false
    var metalFX = false
    var metal4 = true
    var rayTracing: Bool? = nil
    var fpsCap: Int? = nil
}

enum Profiles {
    static func file(for appID: Int?) -> URL {
        Runner.profiles.appendingPathComponent(appID.map { "\($0).env" } ?? "default.env")
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

    /// Writes the profile for one game (or the default one when `appID` is nil).
    static func write(appID: Int?, settings: GameSettings, renderer: Renderer,
                      engine: InstalledEngine, d3dmetal: D3DMetalInstall?) throws {
        try Paths.ensure(Runner.profiles)
        let text = render(appID: appID, settings: settings, renderer: renderer, engine: engine, d3dmetal: d3dmetal)
        try text.write(to: file(for: appID), atomically: true, encoding: .utf8)
    }

    static func remove(appID: Int) {
        try? FileManager.default.removeItem(at: file(for: appID))
    }

    static func render(appID: Int?, settings s: GameSettings, renderer: Renderer,
                       engine: InstalledEngine, d3dmetal: D3DMetalInstall?) -> String {
        let q = Runner.shellQuote
        var out = ["# Written by Decant for \(appID.map { "Steam app \($0)" } ?? "games without their own settings").",
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
            if let cap = s.fpsCap { export("DXVK_FRAME_RATE", String(cap)) }
        case .wined3d:
            break
        default: // .dxmt, .auto, or .d3dmetal without an import
            export("WINEDLLPATH_DXMT", dir("dxmt"))
            export("DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN", "1")
            if s.metalFX { export("DXMT_ENABLE_NVEXT", "1") }
            if let cap = s.fpsCap { export("DXMT_CONFIG", "d3d11.preferredMaxFrameRate=\(cap);") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
