import Darwin
import Foundation

/// DLSS to MetalFX through D3DMetal. EXPERIMENTAL: no DLSS game was run with it, so the path is
/// untested end to end.
///
/// Apple's Game Porting Toolkit Read Me says to rename D3DMetal's nvngx-on-metalfx.so and .dll to
/// nvngx, and to copy nvngx.dll and nvapi64.dll into the bottle's system32. A bottle made with DXMT
/// (Steam Play's template, an added game) holds DXMT's two files there instead, and D3DMetal's nvngx
/// is not there under the name games load. So Unwine adds the renamed nvngx next to Apple's files
/// (Apple's own files stay as they are), and puts D3DMetal's two files into a closed bottle before a
/// D3DMetal game with "MetalFX for DLSS" starts. DXMT's two go back before the game runs on DXMT again.
enum NGXFiles {
    enum Layer: String, Sendable { case d3dmetal, dxmt }

    /// Whose files Unwine put in the bottle, kept inside it, so a fresh bottle starts with no record.
    private static func recordFile(_ prefix: URL) -> URL { prefix.appendingPathComponent(".unwine-dlss") }
    private static func system32(_ prefix: URL) -> URL { prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true) }

    /// The layer's two files, from its wine folder (the one its WINEDLLPATH_* names).
    private static func sources(_ layer: Layer, layerDir: URL) -> [(from: URL, to: String)] {
        let win = layerDir.appendingPathComponent("x86_64-windows", isDirectory: true)
        let ngx = layer == .d3dmetal ? "nvngx-on-metalfx.dll" : "nvngx.dll"
        return [(win.appendingPathComponent(ngx), "nvngx.dll"), (win.appendingPathComponent("nvapi64.dll"), "nvapi64.dll")]
    }

    /// Apple's rename, done as additions: nvngx.dll is a clone of nvngx-on-metalfx.dll, and nvngx.so links
    /// where Apple's nvngx-on-metalfx.so links (D3DMetal's shared library). Wine finds a DLL's Mac half by
    /// the DLL's name. Cheap when both are there.
    @discardableResult
    static func prepareD3DMetal(wineDir: URL, log: LogFile) -> Bool {
        let fm = FileManager.default
        let win = wineDir.appendingPathComponent("x86_64-windows", isDirectory: true)
        let unix = wineDir.appendingPathComponent("x86_64-unix", isDirectory: true)
        let apple = win.appendingPathComponent("nvngx-on-metalfx.dll"), appleUnix = unix.appendingPathComponent("nvngx-on-metalfx.so")
        let dll = win.appendingPathComponent("nvngx.dll"), so = unix.appendingPathComponent("nvngx.so")
        guard fm.fileExists(atPath: apple.path), fm.fileExists(atPath: appleUnix.path) else { return false }
        do {
            if !fm.contentsEqual(atPath: dll.path, andPath: apple.path) {
                try? fm.removeItem(at: dll)
                if clonefile(apple.path, dll.path, 0) != 0 { try fm.copyItem(at: apple, to: dll) }
                log.line("D3DMetal: added nvngx.dll (Apple's nvngx-on-metalfx.dll under the name games load), for MetalFX for DLSS")
            }
            if let target = try? fm.destinationOfSymbolicLink(atPath: appleUnix.path) {
                if (try? fm.destinationOfSymbolicLink(atPath: so.path)) != target {
                    try? fm.removeItem(at: so)
                    try fm.createSymbolicLink(atPath: so.path, withDestinationPath: target)
                }
            } else if !fm.contentsEqual(atPath: so.path, andPath: appleUnix.path) {
                try? fm.removeItem(at: so)
                if clonefile(appleUnix.path, so.path, 0) != 0 { try fm.copyItem(at: appleUnix, to: so) }
            }
            return true
        } catch {
            log.line("D3DMetal: could not add nvngx for MetalFX for DLSS: \(error.localizedDescription)")
            return false
        }
    }

    /// True when the bottle needs a swap for this layer. Cheap: a small record file and file sizes.
    static func needsSwap(to layer: Layer, layerDir: URL, prefix: URL) -> Bool {
        let placed = (try? String(contentsOf: recordFile(prefix), encoding: .utf8)) == Layer.d3dmetal.rawValue
        switch layer {
        case .d3dmetal: return !placed || !holds(.d3dmetal, layerDir: layerDir, prefix: prefix)
        case .dxmt: return placed      // only Unwine's own swap is undone
        }
    }

    /// Puts the layer's two files into a closed bottle's system32. For DXMT, only after Unwine put
    /// D3DMetal's there. Logs each swap. False when a copy failed.
    @discardableResult
    static func place(_ layer: Layer, layerDir: URL, prefix: URL, game: String, log: LogFile) -> Bool {
        let fm = FileManager.default
        let dir = system32(prefix)
        guard fm.fileExists(atPath: dir.path), needsSwap(to: layer, layerDir: layerDir, prefix: prefix) else { return true }
        let files = sources(layer, layerDir: layerDir)
        guard files.allSatisfy({ fm.fileExists(atPath: $0.from.path) }) else {
            log.line("DLSS files: \(layer == .d3dmetal ? "D3DMetal" : "DXMT") has no nvngx.dll and nvapi64.dll to put in \(game)'s bottle")
            return false
        }
        do {
            for f in files where !fm.contentsEqual(atPath: f.from.path, andPath: dir.appendingPathComponent(f.to).path) {
                let target = dir.appendingPathComponent(f.to)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: f.from, to: target)
            }
            if layer == .d3dmetal {
                try Layer.d3dmetal.rawValue.write(to: recordFile(prefix), atomically: true, encoding: .utf8)
                log.line("DLSS files: D3DMetal's nvngx.dll and nvapi64.dll are now in \(game)'s bottle, for MetalFX for DLSS (experimental)")
            } else {
                try? fm.removeItem(at: recordFile(prefix))
                log.line("DLSS files: DXMT's nvngx.dll and nvapi64.dll are back in \(game)'s bottle")
            }
            return true
        } catch {
            log.line("DLSS files: could not swap them in \(game)'s bottle: \(error.localizedDescription)")
            return false
        }
    }

    /// True when system32 holds files the size of the layer's two (DXMT's and D3DMetal's sizes differ a lot).
    private static func holds(_ layer: Layer, layerDir: URL, prefix: URL) -> Bool {
        let fm = FileManager.default
        return sources(layer, layerDir: layerDir).allSatisfy { f in
            let a = (try? fm.attributesOfItem(atPath: f.from.path))?[.size] as? NSNumber
            let b = (try? fm.attributesOfItem(atPath: system32(prefix).appendingPathComponent(f.to).path))?[.size] as? NSNumber
            return a != nil && a == b
        }
    }
}
