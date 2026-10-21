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
    var saveBatteryUnplugged = true     // on battery, in Low Power Mode or hot: the profile gets the battery overlay
    var maxTessFactor: Int? = nil       // DXMT: the most tessellation a DirectX 11 game gets (4 to 64); nil = the game's own
    // Logs, display and renderer extras. The display values go into the game's closed bottle (BottlePrep).
    var detailedLogs = false            // Wine's error lines and DXVK's and DXMT's notes in the logs (quiet otherwise)
    var retina = false                  // added games: Wine's Retina mode and 192 DPI (Steam Play: NOTPROTON_RETINA=1 in Steam)
    var fillScreen = false              // Wine's CaptureDisplaysForFullscreen: a full-screen game takes the whole display
    var commandIsCtrl = false           // both Command keys reach the game as Ctrl (and Option as Alt)
    var hdr: HDRChoice = .auto          // Automatic: DXMT passes HDR on; On: DXVK too (a test); Off: DXMT and DXVK say no HDR
    var dxmtD3D12 = false               // experimental: a DirectX 12 game runs on DXMT's own DirectX 12 part
    var ddrawMode: DirectDrawMode = .auto   // DirectDraw games (cnc-ddraw): the game's own mode, a window, or full screen
    // Faster x87 math (x87sidecar group)
    var x87 = false                     // Faster x87 math: x87sidecar speeds up a 32-bit game's x87 math under Rosetta
    var x87PreciseFaults = false        // set by Unwine after the game stopped on an x87 fault (X87_PRECISE_FAULTS=1)
}

/// The HDR choice in a game's Display section. DXMT gives a game HDR by itself when the Mac screen shows
/// HDR. DXVK gives it only when asked (dxgi.enableHDR, off by default), so On asks it too. D3DMetal and
/// WineD3D have no switch, and DirectX 8 and 9 games have no HDR picture at all.
enum HDRChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .on: return "On (test)"
        case .off: return "Off (force SDR)"
        }
    }
}

extension GameSettings {
    /// HDR was one switch before it had three choices: forceSDR true meant Off.
    private enum LegacyKeys: String, CodingKey { case forceSDR }

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
        saveBatteryUnplugged = (try? c.decodeIfPresent(Bool.self, forKey: .saveBatteryUnplugged)) ?? d.saveBatteryUnplugged
        maxTessFactor = (try? c.decodeIfPresent(Int.self, forKey: .maxTessFactor)) ?? d.maxTessFactor
        detailedLogs = (try? c.decodeIfPresent(Bool.self, forKey: .detailedLogs)) ?? d.detailedLogs
        retina = (try? c.decodeIfPresent(Bool.self, forKey: .retina)) ?? d.retina
        fillScreen = (try? c.decodeIfPresent(Bool.self, forKey: .fillScreen)) ?? d.fillScreen
        commandIsCtrl = (try? c.decodeIfPresent(Bool.self, forKey: .commandIsCtrl)) ?? d.commandIsCtrl
        let wasOff = (try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .forceSDR)) == true
        hdr = (try? c.decodeIfPresent(HDRChoice.self, forKey: .hdr)) ?? (wasOff ? .off : d.hdr)
        dxmtD3D12 = (try? c.decodeIfPresent(Bool.self, forKey: .dxmtD3D12)) ?? d.dxmtD3D12
        ddrawMode = (try? c.decodeIfPresent(DirectDrawMode.self, forKey: .ddrawMode)) ?? d.ddrawMode
        x87 = (try? c.decodeIfPresent(Bool.self, forKey: .x87)) ?? d.x87
        x87PreciseFaults = (try? c.decodeIfPresent(Bool.self, forKey: .x87PreciseFaults)) ?? d.x87PreciseFaults
    }
}

/// What a launch profile changes while the Mac saves battery (on battery, in Low Power Mode or
/// hot), for a game with "Save battery when unplugged" on. Plugged in, a profile has none of it.
/// Unwine writes the profiles again when the power changes, and games read them at every start,
/// so this works for games started from Mac Steam too.
struct BatteryOverlay: Equatable, Sendable {
    /// Low Power Mode or heat. Low Power Mode cuts the GPU clock (to about 67% on an M4 Pro), and
    /// with V-Sync a game that then misses 60 fps drops to 30, so the cap goes lower.
    var strict: Bool
    var screenHz: Int

    /// DXVK builds shaders on every core by default. Four at a time gives smaller CPU spikes and less heat.
    static let compilerThreads = 4

    /// The cap when the user set none: 60 on a screen above 60 Hz, the screen's own rate on a slower
    /// one. In Low Power Mode or heat: 40 on a faster screen, half the rate (30) on a 60 Hz one.
    var cap: Int {
        let hz = screenHz > 0 ? screenHz : 60
        if strict { return hz > 60 ? 40 : max(24, hz / 2) }
        return min(60, hz)
    }

    /// The settings the profile is written with: the user's own cap wins, and 120 fps mode waits.
    func applied(to s: GameSettings) -> GameSettings {
        var s = s
        if s.fpsCap == nil { s.fpsCap = cap }
        s.fps120 = false
        return s
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
    /// `battery` is the overlay while the Mac saves battery, nil plugged in.
    static func write(appID: Int?, settings: GameSettings, renderer: Renderer, api: GraphicsAPI? = nil,
                      engine: InstalledEngine, d3dmetal: D3DMetalInstall?, gameDir: URL? = nil,
                      battery: BatteryOverlay? = nil) throws {
        try Paths.ensure(Runner.profiles)
        let s = battery?.applied(to: settings) ?? settings
        let (dxvk, dxmt) = configs(settings: s, renderer: renderer, api: api, gameDir: gameDir, battery: battery)
        try writeOrRemove(dxvk, at: dxvkConfig(for: appID))
        try writeOrRemove(dxmt, at: dxmtConfig(for: appID))
        // A DirectDraw game's cnc-ddraw reads Unwine's own ddraw.ini, never one in the game's folder.
        // It gets the battery cap too (its maxfps), like the DXVK and DXMT files above.
        let directDraw = renderer != .wined3d
            && DirectDrawConfig.write(appID: appID, settings: s, api: api, gameDir: gameDir, engine: engine)
        let text = render(appID: appID, settings: s, renderer: renderer, api: api, engine: engine, d3dmetal: d3dmetal,
                          hasDXVKConfig: dxvk != nil, hasDXMTConfig: dxmt != nil, directDraw: directDraw, battery: battery)
        try text.write(to: file(for: appID), atomically: true, encoding: .utf8)
    }

    static func remove(appID: Int) {
        for url in [file(for: appID), dxvkConfig(for: appID), dxmtConfig(for: appID), DirectDrawConfig.file(for: appID)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeOrRemove(_ text: String?, at url: URL) throws {
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    /// The main screen's top refresh rate: 120 on a ProMotion Mac. Wine shows games this screen
    /// as its primary one. Profiles are written again at every Play, so a new screen counts then.
    static var screenHz: Int { NSScreen.screens.first?.maximumFramesPerSecond ?? 60 }

    /// Pixels per point on the same screen: 2 on a Retina screen, 1 on most external ones.
    static var screenScale: CGFloat { NSScreen.screens.first?.backingScaleFactor ?? 2 }

    /// The frame caps that divide the screen's rate, lowest first: 30, 40, 60 and 120 on a 120 Hz
    /// screen, 30 and 60 on a 60 Hz one. Each frame then shows for the same number of refreshes.
    static func capChoices(screenHz hz: Int = Profiles.screenHz) -> [Int] {
        [4, 3, 2, 1].compactMap { n in hz % n == 0 && hz / n >= 24 ? hz / n : nil }
    }

    /// The DXVK and DXMT config files a game needs, or nil when Unwine has nothing to set.
    static func configs(settings s: GameSettings, renderer: Renderer, api: GraphicsAPI? = nil, gameDir: URL?,
                        screenHz: Int = Profiles.screenHz, screenScale: CGFloat = Profiles.screenScale,
                        battery: BatteryOverlay? = nil) -> (dxvk: String?, dxmt: String?) {
        func shipped(_ name: String) -> String {
            guard let dir = gameDir, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return "" }
            return "# From the game's own \(name):\n\(text)\n"
        }
        var dxvk: [String] = []
        if renderer != .wined3d {
            if let cap = s.fpsCap, cap > 0, screenHz >= cap, screenHz % cap == 0 {
                // A cap that divides the screen's rate becomes V-Sync on every Nth refresh: DXVK shows
                // each frame for exactly that many refreshes, with no CPU timer. DXVK's own limiter
                // paces badly, its log says. Still to check on KosmicKrisp: the frame-interval graph
                // of the Metal HUD should show one even bar.
                let interval = screenHz / cap
                dxvk += ["dxgi.syncInterval = \(interval)", "d3d9.presentInterval = \(interval)"]
            } else if let cap = s.fpsCap {
                // DXVK 3 reads dxvk.maxFrameRate, older builds dxgi/d3d9.maxFrameRate; unknown keys are ignored.
                dxvk += ["dxgi.maxFrameRate = \(cap)", "d3d9.maxFrameRate = \(cap)", "dxvk.maxFrameRate = \(cap)"]
            }
            if battery != nil { dxvk.append("dxvk.numCompilerThreads = \(BatteryOverlay.compilerThreads)") }
            if s.lowLatency { dxvk.append("dxvk.latencySleep = True") }
            // Background shader builds, said out loud so no build default decides it.
            dxvk.append(s.asyncShaders ? "dxvk.enableAsync = True" : "dxvk.enableAsync = False")
            // A DirectX 10/11/12 game can open a DirectX 9 device on its own window only to decode
            // videos (Romance of the Three Kingdoms XIV). On a Mac every swap chain adds its own layer
            // to the window, and the DirectX 9 one never draws, so it hid the whole game: a black
            // screen with music. With this, DXVK makes that layer only when DirectX 9 really presents.
            if api != .dx9 && api != .dx8 { dxvk.append("d3d9.deferSurfaceCreation = True") }
            // HDR (the game's Display choice). DXVK tells a DirectX 10/11 game the screen has HDR only when
            // asked, so Automatic gives it none. On asks (a test: DXVK's HDR through KosmicKrisp has no
            // public test yet). Off says no, also over a DXVK_HDR=1 in Steam's launch options.
            switch s.hdr {
            case .on: dxvk.append("dxgi.enableHDR = True")
            case .off: dxvk.append("dxgi.enableHDR = False")
            case .auto: break
            }
        }
        var dxmt: [String] = []
        // DXMT runs every layer choice except DXVK, WineD3D and a real D3DMetal (which has its own cap).
        if renderer == .dxmt || renderer == .auto {
            if let cap = s.fpsCap {
                dxmt.append("d3d11.preferredMaxFrameRate = \(cap)")
                // DXMT's DirectX 12 part (experimental) reads a cap of its own.
                if s.dxmtD3D12 && api == .dx12 { dxmt.append("d3d12.preferredMaxFrameRate = \(cap)") }
            } else if s.fps120 && screenHz > 60 {
                // A game in a 60 Hz full-screen mode gets paced to 60 by DXMT, though the Mac screen
                // stays at its own rate. The user's own cap above wins over this.
                dxmt.append("# 120 fps mode: pace to the screen's \(screenHz) Hz, not the game's display mode.")
                dxmt.append("d3d11.preferredMaxFrameRate = \(screenHz)")
            }
            // MetalFX sharpening enlarges the picture by the screen's own scale, so it lands on the
            // real pixels. A 1x screen gets 1.0: there is nothing to add, and the switch does nothing.
            if s.metalFXSpatial {
                dxmt.append("d3d11.metalSpatialUpscaleFactor = \(String(format: "%.1f", min(2, max(1, screenScale))))")
            }
            if let tess = s.maxTessFactor { dxmt.append("d3d11.maxTessFactor = \(min(64, max(4, tess)))") }
        }
        // Online mode runs a DXVK or D3DMetal game on DXMT and gives DXMT this file, so the game's cap holds
        // there with no Windows Steam restart. DXVK_FRAME_RATE (only DXVK 1.x reads it) and D3DM_MAX_FPS
        // mean nothing to DXMT, and Online mode drops them.
        if renderer == .dxvk || renderer == .d3dmetal, let cap = s.fpsCap { dxmt.append("d3d11.preferredMaxFrameRate = \(cap)") }
        // HDR Off: DXMT tells the game the screen has no HDR (Online mode runs DXVK games on DXMT too).
        // Automatic and On leave DXMT as it is: it gives a game HDR when the Mac screen shows HDR.
        if s.hdr == .off && (renderer == .dxmt || renderer == .auto || renderer == .dxvk) { dxmt.append("dxgi.forceSDR = True") }
        // A game's own dxvk.conf or dxmt.conf counts too: Unwine's file replaces the game's, so it carries it.
        let header = "# Written by Unwine. Settings from Steam's launch options still apply on top.\n"
        let ownDXVK = renderer != .wined3d ? shipped("dxvk.conf") : "", ownDXMT = shipped("dxmt.conf")
        return (dxvk.isEmpty && ownDXVK.isEmpty ? nil : header + ownDXVK + dxvk.joined(separator: "\n") + "\n",
                dxmt.isEmpty && ownDXMT.isEmpty ? nil : header + ownDXMT + dxmt.joined(separator: "\n") + "\n")
    }

    /// Metal 4 exists from macOS 26. D3DMetal makes it its default on macOS 27; below 26 there is nothing to switch on.
    static var hasMetal4: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    static func render(appID: Int?, settings s: GameSettings, renderer: Renderer, api: GraphicsAPI? = nil,
                       engine: InstalledEngine, d3dmetal: D3DMetalInstall?,
                       hasDXVKConfig: Bool = false, hasDXMTConfig: Bool = false, directDraw: Bool = false,
                       battery: BatteryOverlay? = nil) -> String {
        let q = Runner.shellQuote
        var out = ["# Written by Unwine for \(appID.map { "Steam app \($0)" } ?? "games without their own settings").",
                   "# Renderer: \(renderer.rawValue)"]
        // `s` already carries the overlay's cap (D3DMetal's below, DXVK's and DXMT's in their files).
        if let battery {
            out.append("# Saving battery (\(battery.strict ? "Low Power Mode or heat" : "on battery")): frame cap "
                       + "\(s.fpsCap.map { "\($0) fps" } ?? "none"), no 120 fps mode, \(BatteryOverlay.compilerThreads) DXVK shader threads.")
        }
        func export(_ k: String, _ v: String) { out.append("export \(k)=\(q(v))") }
        func dir(_ name: String) -> String { engine.renderer(name).path }

        // Wine never reads this line: Unwine writes these values into the closed bottle before the game
        // starts (BottlePrep). In Steam Play, RetinaMode is NotProton's, from Steam's launch options.
        if let appID { out.append(MacDriverValues(settings: s, appID: appID).profileLine) }

        export("WINEMSYNC", s.msync && engine.supportsMsync ? "1" : "0")
        export("ROSETTA_ADVERTISE_AVX", s.advertiseAVX ? "1" : "0")
        for (k, v) in X87Sidecar.exports(s) { export(k, v) }     // Faster x87 math: ROSETTA_X87_PATH (X87Sidecar.swift)
        if s.metalHUD { export("MTL_HUD_ENABLED", "1") }
        // Logs are quiet unless this game's Detailed logs is on (engine.env and WineEnvironment set the
        // quiet levels). A level from Steam's launch options still wins: the runner's wrappers keep it.
        if s.detailedLogs {
            export("WINEDEBUG", WineEnvironment.detailedDebug)
            export("DXVK_LOG_LEVEL", WineEnvironment.detailedLayerLog)
            export("DXMT_LOG_LEVEL", WineEnvironment.detailedLayerLog)
        }

        // DirectX 9 and DirectDraw helpers ride along with every modern layer.
        if renderer != .wined3d {
            // Unwine's copy lets DXVK's background shader builds reach the game's main picture too, and
            // keeps a texture the Mac cannot share from closing the game. It is used with async shaders
            // off as well: the crash fix applies either way, and the async fix then does nothing.
            let d9vk = RendererPatches.fixedDir("d9vk", engine: engine)?.path
            if engine.supports("WINEDLLPATH_D9VK") { export("WINEDLLPATH_D9VK", d9vk ?? dir("d9vk")) }
            if engine.supports("WINEDLLPATH_CNCD") {
                export("WINEDLLPATH_CNCD", dir("cnc_ddraw"))
                // Unwine's own ddraw.ini for a DirectDraw game, as a Windows path (Wine's Z: drive is the
                // Mac's /). Without it, cnc-ddraw keeps its file in the bottle or in the game's folder.
                if directDraw, let appID { export("CNC_DDRAW_CONFIG_FILE", DirectDrawConfig.windowsPath(DirectDrawConfig.file(for: appID))) }
            }
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
                // Below macOS 26 there is no Metal 4, so the variable stays out.
                if hasMetal4 { export("D3DM_MTL4", s.metal4 ? "1" : "0") }
                if let cap = s.fpsCap { export("D3DM_MAX_FPS", String(cap)) }
            }
            // D3DMetal never reads this. Online mode runs the game on DXMT, and its cap reaches DXMT through this file.
            if hasDXMTConfig { export("DXMT_CONFIG_FILE", dxmtConfig(for: appID).path) }
        case .dxvk:
            let three = engine.renderer("dxvk3")
            let patched = RendererPatches.fixedDir("dxvk3", engine: engine)
            let legacy = patched == nil && !FileManager.default.fileExists(atPath: three.path)
            export("WINEDLLPATH_DXVK", patched?.path ?? (legacy ? dir("dxvk") : three.path))
            export("DXVK_ASYNC", s.asyncShaders ? "1" : "0")
            // Only the old DXVK 1.x folder reads DXVK_FRAME_RATE; DXVK 3 takes the cap from its file.
            if legacy, let cap = s.fpsCap { export("DXVK_FRAME_RATE", String(cap)) }
            // Online mode runs this game on DXMT, and its cap reaches DXMT through this file.
            if hasDXMTConfig { export("DXMT_CONFIG_FILE", dxmtConfig(for: appID).path) }
        case .wined3d:
            break
        default: // .dxmt, .auto, or .d3dmetal without an import
            // Experimental: a DirectX 12 game with the switch on gets DXMT's own DirectX 12 part.
            let d3d12 = s.dxmtD3D12 && api == .dx12 ? DXMTD3D12.folder(engine: engine) : nil
            export("WINEDLLPATH_DXMT", d3d12?.path ?? dir("dxmt"))
            export("DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN", "1")
            if s.metalFX { export("DXMT_ENABLE_NVEXT", "1") }
            // Bottles run without Retina mode unless the game's Sharp picture (or Steam's launch options,
            // or Online mode's High Resolution Mode) turns it on, so a game draws at the screen's point
            // size and DXMT's default 2x MetalFX output lands on the screen's real pixels.
            if s.metalFXSpatial { export("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1") }
            if hasDXMTConfig { export("DXMT_CONFIG_FILE", dxmtConfig(for: appID).path) }
        }
        out += LaunchOptions.profileLines(for: appID)   // the game page's language, DLL overrides and extra settings
        return out.joined(separator: "\n") + "\n"
    }
}
