import Foundation

/// Apple's D3DMetal, imported from the user's own Game Porting Toolkit download.
/// Unwine never ships or downloads Apple's files itself; Apple's licence only lets people get them from Apple.
struct D3DMetalInstall: Codable, Equatable, Sendable {
    var version: String         // "4.0b3"
    var folder: String          // under Paths.layers
    var importedAt: Date

    var root: URL { Paths.layers.appendingPathComponent(folder, isDirectory: true) }
    var wineDir: URL { root.appendingPathComponent("lib/wine", isDirectory: true) }
    var externalDir: URL { root.appendingPathComponent("lib/external", isDirectory: true) }
    var libd3dshared: URL { externalDir.appendingPathComponent("libd3dshared.dylib") }
    var licence: URL { root.appendingPathComponent("License.rtf") }
    var isVersion4: Bool { LooseVersion(version) >= LooseVersion("4.0") }

    /// Sort key where a final release beats its betas: "4.0" > "4.0b3" > "4.0b2" > "3.0".
    var sortKey: [Int] { Self.sortKey(version) }

    static func sortKey(_ v: String) -> [Int] {
        let lower = v.lowercased()
        let parts = lower.split(separator: "b", maxSplits: 1)
        let main = LooseVersion(String(parts.first ?? "")).parts + [0, 0]
        let beta = parts.count == 2 ? (Int(parts[1].filter(\.isNumber)) ?? 0) : Int.max
        return Array(main.prefix(3)) + [beta]
    }
    var isBeta: Bool { version.lowercased().contains("b") }

    var label: String {
        let parts = version.lowercased().split(separator: "b", maxSplits: 1)
        if parts.count == 2 { return "GPTK \(parts[0]) beta \(parts[1])" }
        return "GPTK \(version)"
    }
}

enum D3DMetalError: LocalizedError {
    case notToolkit
    case badSignature

    var errorDescription: String? {
        switch self {
        case .notToolkit: return "That file is not Apple's Game Porting Toolkit. Pick the .dmg you downloaded from Apple."
        case .badSignature: return "Apple's signature on D3DMetal did not check out, so Unwine did not use it."
        }
    }
}

enum D3DMetalStore {
    static let appleDownloadPage = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    static func installed() -> [D3DMetalInstall] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: Paths.layers, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> D3DMetalInstall? in
            guard dir.lastPathComponent.hasPrefix("D3DMetal-"),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("d3dmetal.json")),
                  let item = try? JSONDecoder.unwine.decode(D3DMetalInstall.self, from: data),
                  FileManager.default.fileExists(atPath: item.libd3dshared.path) else { return nil }
            return item
        }
        .sorted { $1.sortKey.lexicographicallyPrecedes($0.sortKey) }   // newest first
    }

    /// Deletes every imported GPTK except `keep`, the one games use. Each import is a copy of Apple's
    /// file, which the user still has. Callers make sure no game runs. Returns the bytes freed.
    @discardableResult
    static func removeOld(keeping keep: D3DMetalInstall) -> Int64 {
        var freed: Int64 = 0
        for old in installed() where old.folder != keep.folder {
            let bytes = DiskUse.size(of: old.root)
            if (try? FileManager.default.removeItem(at: old.root)) != nil { freed += bytes }
        }
        return freed
    }

    /// GPTK disk images sitting in ~/Downloads, newest first. Reading Downloads may show a macOS permission prompt.
    static func findInDownloads() -> [URL] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let items = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "dmg" && $0.lastPathComponent.lowercased().contains("game_porting_toolkit") }
            .sorted { D3DMetalInstall.sortKey(versionHint($1.lastPathComponent)).lexicographicallyPrecedes(D3DMetalInstall.sortKey(versionHint($0.lastPathComponent))) }
    }

    /// "Game_Porting_Toolkit_4.0_beta_3.dmg" -> "4.0b3"; "Game_Porting_Toolkit_4.0.dmg" -> "4.0".
    static func versionHint(_ name: String) -> String {
        let lower = name.lowercased().replacingOccurrences(of: ".dmg", with: "")
        guard let range = lower.range(of: #"\d+(\.\d+)*(_beta_\d+)?"#, options: .regularExpression) else { return "0" }
        return String(lower[range]).replacingOccurrences(of: "_beta_", with: "b")
    }

    /// Imports from Apple's outer GPTK .dmg, the inner "Evaluation environment" .dmg, or an already-open folder.
    static func importToolkit(from source: URL, log: LogFile) async throws -> D3DMetalInstall {
        var mounts: [URL] = []
        defer {
            for m in mounts.reversed() {
                Task.detached { try? await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", m.path, "-force"], check: false) }
            }
        }
        func mount(_ dmg: URL) async throws -> URL {
            let point = FileManager.default.temporaryDirectory.appendingPathComponent("decant-gptk-\(UUID().uuidString)")
            try Paths.ensure(point)
            try await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", point.path], log: log)
            mounts.append(point)
            return point
        }

        var root = source
        if source.pathExtension.lowercased() == "dmg" { root = try await mount(source) }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("redist/lib/external/libd3dshared.dylib").path) {
            let inner = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension.lowercased() == "dmg" && $0.lastPathComponent.lowercased().contains("evaluation") }
            guard let inner else { throw D3DMetalError.notToolkit }
            root = try await mount(inner)
        }
        let lib = root.appendingPathComponent("redist/lib")
        let framework = lib.appendingPathComponent("external/D3DMetal.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { throw D3DMetalError.notToolkit }

        // Apple's own signature must be intact; we never modify or re-sign it.
        let sig = try await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                      ["-v", "-R=anchor apple generic and identifier \"com.apple.D3DMetal\"", framework.path],
                                      log: log, check: false)
        guard sig.status == 0 else { throw D3DMetalError.badSignature }

        let plist = NSDictionary(contentsOf: framework.appendingPathComponent("Resources/version.plist"))
        let version = (plist?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let folder = "D3DMetal-\(version)"
        let dest = Paths.layers.appendingPathComponent(folder, isDirectory: true)
        let stage = Paths.layers.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensure(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        // ditto keeps the relative .so -> libd3dshared.dylib symlinks exactly as Apple made them.
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), [lib.path, stage.appendingPathComponent("lib").path], log: log)
        for doc in ["License.rtf", "Acknowledgements.rtf", "Read Me.rtf"] {
            let src = root.appendingPathComponent(doc)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: stage.appendingPathComponent(doc))
            }
        }
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", stage.path], check: false)

        let item = D3DMetalInstall(version: version, folder: folder, importedAt: Date())
        try JSONEncoder.unwine.encode(item).write(to: stage.appendingPathComponent("d3dmetal.json"))
        // Keep the old copy until the new one is in place.
        let aside = Paths.layers.appendingPathComponent(".import-old-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: dest, to: aside) }
        do {
            try FileManager.default.moveItem(at: stage, to: dest)
        } catch {
            if FileManager.default.fileExists(atPath: aside.path) { try? FileManager.default.moveItem(at: aside, to: dest) }
            throw error
        }
        try? FileManager.default.removeItem(at: aside)
        log.line("Imported D3DMetal \(version)")
        return item
    }
}
