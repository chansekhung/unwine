import Foundation

/// DXMT's own DirectX 12 part. EXPERIMENTAL: DXMT still develops it, and the engine ships it as
/// _d3d12.dll so Wine never loads it. For a DirectX 12 game with "DirectX 12 through DXMT" on, Unwine
/// points the game at a clone of DXMT's folder (APFS clones, no extra disk space) in which the file is
/// d3d12.dll. The engine's own files stay as they are. It is 64-bit only, like the file.
enum DXMTD3D12 {
    private static let markerName = ".unwine-d3d12"

    private static func source(_ engine: InstalledEngine) -> URL {
        engine.renderer("dxmt").appendingPathComponent("x86_64-windows/_d3d12.dll")
    }

    /// The engine carries DXMT's DirectX 12 file.
    static func isAvailable(engine: InstalledEngine) -> Bool {
        FileManager.default.fileExists(atPath: source(engine).path)
    }

    /// renderer/dxmt-d3d12/wine: the WINEDLLPATH_DXMT of a game with the switch on. Online mode leaves
    /// it out (OnlineSteam), so Windows Steam's bottle keeps DXMT as it ships.
    static func wineFolder(_ engine: InstalledEngine) -> URL {
        engine.rendererRoot.appendingPathComponent("dxmt-d3d12/wine", isDirectory: true)
    }

    /// `wineFolder`, made on first use and again when DXMT's file changes. Nil when the engine has no
    /// DXMT DirectX 12 file or the copy failed (the game then gets DXMT as it ships). Cheap once made.
    static func folder(engine: InstalledEngine, log: LogFile? = nil) -> URL? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source(engine).path) else { return nil }
        let stamp = "\((attrs[.size] as? NSNumber)?.int64Value ?? 0) \((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)\n"
        let wine = wineFolder(engine)
        let copy = wine.deletingLastPathComponent()
        if (try? String(contentsOf: copy.appendingPathComponent(markerName), encoding: .utf8)) == stamp { return wine }
        let stage = engine.rendererRoot.appendingPathComponent(".dxmt-d3d12-\(UUID().uuidString)", isDirectory: true)
        do {
            // FileManager clones on APFS: the copy takes no extra space and no time.
            try fm.copyItem(at: engine.rendererRoot.appendingPathComponent("dxmt", isDirectory: true), to: stage)
            let win = stage.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
            try fm.moveItem(at: win.appendingPathComponent("_d3d12.dll"), to: win.appendingPathComponent("d3d12.dll"))
            try stamp.write(to: stage.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: copy)
            try fm.moveItem(at: stage, to: copy)
            log?.line("Made renderer/dxmt-d3d12: DXMT's DirectX 12 part as d3d12.dll, for games with DirectX 12 through DXMT (experimental)")
            return wine
        } catch {
            try? fm.removeItem(at: stage)
            log?.line("Could not make renderer/dxmt-d3d12: \(error.localizedDescription)")
            return nil
        }
    }
}
