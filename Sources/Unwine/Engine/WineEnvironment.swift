import Foundation

/// The graphics layer a game runs on.
enum Renderer: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, d3dmetal, dxmt, dxvk, wined3d

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .d3dmetal: return "D3DMetal (Apple GPTK)"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    var blurb: String {
        switch self {
        case .auto: return "Unwine reads the game and picks for you."
        case .d3dmetal: return "Apple's layer. Best for DirectX 12 and many DirectX 11 games. 64-bit only."
        case .dxmt: return "Open layer straight to Metal. Best for most DirectX 10 and 11 games."
        case .dxvk: return "Through Vulkan. Try it when the other two fail."
        case .wined3d: return "Wine's own. For very old games (DirectX 7 to 9)."
        }
    }
}

enum WineEnvironment {
    /// Logs stay quiet by default: a game that runs well then writes little more than what it prints
    /// itself. In two added games' logs, DXVK's start-up notes were 924 of 1,084 lines and 3,929 of
    /// 4,235, and most of Wine's error lines repeated one memory message.
    static let quietDebug = "-all"
    /// Wine's error lines (its "fixme" notes stay off): NotProton's own default, and what a game's
    /// Detailed logs brings back.
    static let detailedDebug = "err+all,fixme-all"
    /// DXVK_LOG_LEVEL and DXMT_LOG_LEVEL. Both layers print their notes at "info" when nothing is set;
    /// "warn" keeps their warnings and errors.
    static let quietLayerLog = "warn"
    static let detailedLayerLog = "info"

    /// Variables every Wine process needs, built from scratch so nothing leaks in from the shell.
    /// A game's profile goes on top, so its Detailed logs lines replace the quiet levels set here.
    static func base(engine: InstalledEngine, prefix: URL, debug: Bool = false) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": host["HOME"] ?? NSHomeDirectory(),
            "USER": host["USER"] ?? NSUserName(),
            "LOGNAME": host["LOGNAME"] ?? NSUserName(),
            "TMPDIR": host["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "\(engine.wineDir.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": prefix.path,
            "WINESERVER": engine.wineserver.path,
            "WINELOADER": engine.wine.path,
            "WINEDEBUG": debug ? detailedDebug : quietDebug,
            "DXVK_LOG_LEVEL": debug ? detailedLayerLog : quietLayerLog,
            "DXMT_LOG_LEVEL": debug ? detailedLayerLog : quietLayerLog,
            "DYLD_FALLBACK_LIBRARY_PATH": [
                engine.wineDir.appendingPathComponent("lib").path,
                engine.frameworks.path,
                engine.frameworks.appendingPathComponent("GStreamer.framework/Versions/1.0/lib").path,
                "/usr/lib",
            ].joined(separator: ":"),
            "DYLD_FALLBACK_FRAMEWORK_PATH": engine.frameworks.path,
            "GST_PLUGIN_PATH": engine.frameworks.appendingPathComponent("GStreamer.framework/Versions/1.0/lib/gstreamer-1.0").path,
            // No WINEESYNC: this Wine has no esync (the name is not in its ntdll.so, wine or wineserver).
            "WINEMSYNC": "0",
        ]
        if let tz = TimeZone.current.identifier as String? { env["TZ"] = tz }
        for (k, v) in engine.markerEnv { env[k] = v }
        return env
    }
}
