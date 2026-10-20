import Foundation

/// Small, checked fixes to the engine's graphics files. Each recipe names the exact file it was made
/// for (by SHA-256) and the bytes it changes. A file with any other content is left alone, so a new
/// engine build simply runs stock until Unwine has a recipe for it. The engine's own files are never
/// changed: the fixes go into copies next to them.
enum RendererPatches {
    struct Edit: Sendable {
        let offset: Int
        let old: [UInt8]
        let new: [UInt8]
    }

    struct Recipe: Sendable {
        let path: String            // relative to the folder being copied
        let cleanSHA256: String
        let patchedSHA256: String
        let edits: [Edit]
    }

    // MARK: Async shaders for the game's main picture (DirectX 9)

    /// Sikarugir's DXVK 3.1.1-async builds a new shader in the background and skips that draw for a
    /// frame or two, but only for render targets bound in 5 frames in a row. Direct3D 9 swaps its
    /// back buffers on every Present, so draws into the game's main picture never qualified: each one
    /// built its shader while the whole game waited. That is the in-game freeze (the sound loops for a
    /// moment). The fix counts a binding within 4 frames as "in a row" ('addl $1; jne' becomes
    /// 'addl $4; ja'), which covers 3 rotating back buffers plus the front buffer.
    static let asyncBackBuffer: [Recipe] = [
        Recipe(path: "wine/i386-windows/d3d9.dll",
               cleanSHA256: "7cc1b4f37f19783a3d356e4a5c47aa163b6b791ccadaee3d672d7dba44718d68",
               patchedSHA256: "d782fbc1f828985e798b5b1d9af181446c8c23c799ba74ef0d98e539cfd76ac5",
               edits: [Edit(offset: 0x15e89d, old: [0x01], new: [0x04]), Edit(offset: 0x15e8a2, old: [0x75], new: [0x77])]),
        Recipe(path: "wine/x86_64-windows/d3d9.dll",
               cleanSHA256: "ab26d9ea248127922ec038c7e3ce10ca3627af923bc4c057100a9a7ab0c70ca2",
               patchedSHA256: "ecd5ff023636544917cf4df08d6b878fb870b278a533a1dbad5aec6965bda5eb",
               edits: [Edit(offset: 0x142712, old: [0x01], new: [0x04]), Edit(offset: 0x142717, old: [0x75], new: [0x77])]),
    ]

    /// The renderers that carry DXVK's Direct3D 9 layer.
    static let d3d9Renderers = ["d9vk", "dxvk3"]

    /// renderer/<name>-unwine/wine when its patched copy is ready, else nil (the game uses stock files).
    static func asyncDir(_ name: String, engine: InstalledEngine) -> URL? {
        let copy = engine.rendererRoot.appendingPathComponent("\(name)-unwine", isDirectory: true)
        guard (try? String(contentsOf: copy.appendingPathComponent(markerName), encoding: .utf8)) == marker(asyncBackBuffer) else { return nil }
        return copy.appendingPathComponent("wine", isDirectory: true)
    }

    // MARK: Vulkan memory budget (KosmicKrisp under Rosetta)

    /// Mesa counts free memory as pages × PAGE_SIZE. Under Rosetta PAGE_SIZE is 4 KiB, but macOS counts
    /// 16 KiB pages, so KosmicKrisp reported a quarter of the real free memory (about 1.3 GiB of 18).
    /// DXVK then treated normal play as memory pressure: it kept freeing and moving memory. The fix
    /// multiplies by 16 KiB ('imulq (%rcx),%rdx' becomes 'shlq $14,%rdx'). Every Apple chip uses 16 KiB.
    static let vulkanBudget = Recipe(
        path: "libvulkan_kosmickrisp.dylib",
        cleanSHA256: "34e50544998477671ba2ee5a288ebd0855128b0da92e671370abeadc505dbfe3",
        patchedSHA256: "70b24b82d244e6c127f5df65ef38469ba8ffaaae25a7707a6c57a39e6f85a259",
        edits: [Edit(offset: 0x2b3a6c, old: [0x48, 0x0f, 0xaf, 0x11], new: [0x48, 0xc1, 0xe2, 0x0e])])

    private static let patchedDriver = "libvulkan_kosmickrisp-unwine.dylib"
    private static let patchedICD = "kosmickrisp_unwine_icd.json"

    /// The Vulkan driver file games should load: Unwine's fixed copy when ready, else KosmicKrisp,
    /// else MoltenVK. KosmicKrisp is a full Vulkan driver on Apple chips; MoltenVK lacks features
    /// DXVK 3 needs.
    static func vulkanICD(engine: InstalledEngine) -> URL {
        let icd = engine.runtime.appendingPathComponent("Resources/vulkan/icd.d", isDirectory: true)
        let fixed = icd.appendingPathComponent(patchedICD)
        if FileManager.default.fileExists(atPath: fixed.path),
           (try? String(contentsOf: engine.frameworks.appendingPathComponent(patchedDriver + ".unwine"), encoding: .utf8)) == marker([vulkanBudget]) {
            return fixed
        }
        let kosmic = icd.appendingPathComponent("kosmickrisp_mesa_icd.json")
        return FileManager.default.fileExists(atPath: kosmic.path) ? kosmic : icd.appendingPathComponent("MoltenVK_icd.json")
    }

    // MARK: Preparing the copies

    /// Makes the patched copies for this engine once. Cheap when they exist. Safe to call often.
    static func prepare(engine: InstalledEngine, log: LogFile) {
        for name in d3d9Renderers where asyncDir(name, engine: engine) == nil {
            prepareCopy(of: engine.rendererRoot.appendingPathComponent(name, isDirectory: true),
                        to: engine.rendererRoot.appendingPathComponent("\(name)-unwine", isDirectory: true), log: log)
        }
        prepareDriver(engine: engine, log: log)
    }

    private static let markerName = ".unwine-patch"
    private static func marker(_ recipes: [Recipe]) -> String { recipes.map(\.patchedSHA256).joined(separator: "\n") + "\n" }

    private static func prepareCopy(of source: URL, to copy: URL, log: LogFile) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        // Only when every file is the exact build a recipe was made for.
        for r in asyncBackBuffer {
            guard (try? Downloader.sha256(of: source.appendingPathComponent(r.path))) == r.cleanSHA256 else {
                log.line("\(source.lastPathComponent): not the DXVK build Unwine's async fix was made for, so its games use it unchanged")
                return
            }
        }
        let stage = copy.deletingLastPathComponent().appendingPathComponent(".\(copy.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        do {
            try clone(source, to: stage)
            for r in asyncBackBuffer { try apply(r, to: stage.appendingPathComponent(r.path)) }
            try marker(asyncBackBuffer).write(to: stage.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: copy)
            try fm.moveItem(at: stage, to: copy)
            log.line("Made \(copy.lastPathComponent): DXVK's async shaders now also cover the game's main picture")
        } catch {
            try? fm.removeItem(at: stage)
            log.line("Could not make \(copy.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func prepareDriver(engine: InstalledEngine, log: LogFile) {
        let fm = FileManager.default
        let source = engine.frameworks.appendingPathComponent(vulkanBudget.path)
        let target = engine.frameworks.appendingPathComponent(patchedDriver)
        let markerFile = engine.frameworks.appendingPathComponent(patchedDriver + ".unwine")
        let icd = engine.runtime.appendingPathComponent("Resources/vulkan/icd.d", isDirectory: true)
        guard (try? String(contentsOf: markerFile, encoding: .utf8)) != marker([vulkanBudget]) || !fm.fileExists(atPath: icd.appendingPathComponent(patchedICD).path) else { return }
        guard fm.fileExists(atPath: source.path), (try? Downloader.sha256(of: source)) == vulkanBudget.cleanSHA256 else {
            if fm.fileExists(atPath: source.path) { log.line("KosmicKrisp: not the build Unwine's memory fix was made for, so it runs unchanged") }
            return
        }
        let stage = engine.frameworks.appendingPathComponent(".\(patchedDriver)-\(UUID().uuidString)")
        do {
            try clone(source, to: stage)
            try apply(vulkanBudget, to: stage)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: stage, to: target)
            // Same folder and same relative path as the stock driver file, so it finds the same libraries.
            let json = """
            {
                "ICD": {
                    "api_version": "1.4.363",
                    "library_path": "../../../Frameworks/\(patchedDriver)"
                },
                "file_format_version": "1.0.1"
            }

            """
            if let stock = try? Data(contentsOf: icd.appendingPathComponent("kosmickrisp_mesa_icd.json")),
               let text = String(data: stock, encoding: .utf8), text.contains("libvulkan_kosmickrisp.dylib") {
                try text.replacingOccurrences(of: "libvulkan_kosmickrisp.dylib", with: patchedDriver)
                    .write(to: icd.appendingPathComponent(patchedICD), atomically: true, encoding: .utf8)
            } else {
                try json.write(to: icd.appendingPathComponent(patchedICD), atomically: true, encoding: .utf8)
            }
            try marker([vulkanBudget]).write(to: markerFile, atomically: true, encoding: .utf8)
            log.line("Made \(patchedDriver): Vulkan now reports the Mac's real free memory to games")
        } catch {
            try? fm.removeItem(at: stage)
            log.line("Could not make \(patchedDriver): \(error.localizedDescription)")
        }
    }

    /// An APFS clone (no extra disk space), or a plain copy elsewhere.
    private static func clone(_ source: URL, to target: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-c", "-R", source.path, target.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    private enum PatchError: LocalizedError {
        case mismatch(String)
        var errorDescription: String? {
            switch self { case .mismatch(let file): return "\(file) did not match the recipe" }
        }
    }

    private static func apply(_ recipe: Recipe, to file: URL) throws {
        var data = try Data(contentsOf: file)
        for e in recipe.edits {
            guard e.offset + e.old.count <= data.count,
                  Array(data[e.offset..<(e.offset + e.old.count)]) == e.old else { throw PatchError.mismatch(file.lastPathComponent) }
            data.replaceSubrange(e.offset..<(e.offset + e.new.count), with: e.new)
        }
        try data.write(to: file, options: .atomic)
        guard (try? Downloader.sha256(of: file)) == recipe.patchedSHA256 else { throw PatchError.mismatch(file.lastPathComponent) }
    }
}
