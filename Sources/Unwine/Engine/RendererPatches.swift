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

    // MARK: DXVK 3.1.1 (Sikarugir's async build)

    /// Async shaders for the game's main picture (DirectX 9). Sikarugir's DXVK 3.1.1-async builds a
    /// new shader in the background and skips that draw for a frame or two, but only for render
    /// targets bound in 5 frames in a row. Direct3D 9 swaps its back buffers on every Present, so
    /// draws into the game's main picture never qualified: each one built its shader while the whole
    /// game waited. That is the in-game freeze (the sound loops for a moment). The fix counts a
    /// binding within 4 frames as "in a row" ('addl $1; jne' becomes 'addl $4; ja'), which covers 3
    /// rotating back buffers plus the front buffer. With async shaders off the count is never read.
    private static let asyncBackBuffer32 = [Edit(offset: 0x15e89d, old: [0x01], new: [0x04]), Edit(offset: 0x15e8a2, old: [0x75], new: [0x77])]
    private static let asyncBackBuffer64 = [Edit(offset: 0x142712, old: [0x01], new: [0x04]), Edit(offset: 0x142717, old: [0x75], new: [0x77])]

    /// Shared textures the Mac cannot share. A Direct3D 9Ex or 11 game can ask for a texture that
    /// another device opens too: Romance of the Three Kingdoms XIV decodes its videos in Direct3D 9
    /// and shows them in Direct3D 11. Sharing needs VK_KHR_external_memory_win32, which KosmicKrisp
    /// lacks. DXVK sees that and makes a plain texture, but still tells the memory allocator to make
    /// a handle for it, and the allocator calls the driver's missing vkGetMemoryWin32HandleKHR: a
    /// jump to address 0 that closed the game. DXVK's own source still has this bug. The fix gives
    /// the plain texture no handle type (0x7fffffff), as every unshared texture has, in the code
    /// all three DLLs build in. The game keeps running; what it wanted to share stays black.
    /// 64-bit: 'movl $0,0x84(%rsp)' becomes 'movl $0x7fffffff,%eax; movups %xmm0,0x78(%rsp); nop'.
    /// 32-bit: 'movl $0,-0xc4(%ebp); pxor; movl $0,-0xc0(%ebp)' becomes
    /// 'movl $0x7fffffff,%eax; pxor; movq %xmm0,-0xc4(%ebp); nopl'. Both clear the same 8 bytes as before.
    private static func plainNotShared64(_ offset: Int) -> Edit {
        Edit(offset: offset, old: [0xc7, 0x84, 0x24, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
             new: [0xb8, 0xff, 0xff, 0xff, 0x7f, 0x0f, 0x11, 0x44, 0x24, 0x78, 0x90])
    }
    private static func plainNotShared32(_ offset: Int) -> Edit {
        Edit(offset: offset, old: [0xc7, 0x85, 0x3c, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x66, 0x0f,
                                   0xef, 0xc0, 0xc7, 0x85, 0x40, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00],
             new: [0xb8, 0xff, 0xff, 0xff, 0x7f, 0x66, 0x0f, 0xef, 0xc0, 0x66, 0x0f, 0xd6,
                   0x85, 0x3c, 0xff, 0xff, 0xff, 0x0f, 0x1f, 0x80, 0x00, 0x00, 0x00, 0x00])
    }

    /// DXVK's Direct3D 9 layer, in both folders that carry it.
    private static let d3d9Fixes: [Recipe] = [
        Recipe(path: "wine/i386-windows/d3d9.dll",
               cleanSHA256: "7cc1b4f37f19783a3d356e4a5c47aa163b6b791ccadaee3d672d7dba44718d68",
               patchedSHA256: "d9b0855368d9a62c23e129f01db1c8bf3fddf245d969efb8578cb4a6e739399a",
               edits: asyncBackBuffer32 + [plainNotShared32(0x1ad88d)]),
        Recipe(path: "wine/x86_64-windows/d3d9.dll",
               cleanSHA256: "ab26d9ea248127922ec038c7e3ce10ca3627af923bc4c057100a9a7ab0c70ca2",
               patchedSHA256: "b537fba7faece1a6dbe53a637b1befb7bf537c4a17cbe4e9bccbd163eda3bcf8",
               edits: asyncBackBuffer64 + [plainNotShared64(0x18b836)]),
    ]

    /// DXVK's Direct3D 10/11 layer (DXVK as the game's graphics layer).
    private static let d3d11Fixes: [Recipe] = [
        Recipe(path: "wine/i386-windows/d3d11.dll",
               cleanSHA256: "2e356566e51d764b7dd97757b69c0322f0a798519dec345cf41cee60620611df",
               patchedSHA256: "0251878c84d3984ce3ab13c42d91b06e5684cc89ce535998bd0c22fd0d264231",
               edits: [plainNotShared32(0x128ccd)]),
        Recipe(path: "wine/x86_64-windows/d3d11.dll",
               cleanSHA256: "38eb97953a1f77c236dd8903de41cf0fcb9308c61e699d5216ef1438e504cfe1",
               patchedSHA256: "15a23a4e99da35695f766d364a3a6e0c9288fd458f67950dcaf0130794a97154",
               edits: [plainNotShared64(0xf36f6)]),
        Recipe(path: "wine/i386-windows/dxgi.dll",
               cleanSHA256: "6b4cfbcce7416e08be09753d464a47e2814a64397587b54dfa3243232d68f99a",
               patchedSHA256: "6d6c271b44c65dcb89fadf6116659d5298306256cea8e69501a55c3e31bd4c11",
               edits: [plainNotShared32(0x47f0d)]),
        Recipe(path: "wine/x86_64-windows/dxgi.dll",
               cleanSHA256: "660790b21c1e78dd565e96c95e02cb7a0fdee5a345243e2dcac0f2f3326ff083",
               patchedSHA256: "acc33d1badca36e43db69e25ff6e4293c64e02e7069b3796544afba7b0e41052",
               edits: [plainNotShared64(0x42c76)]),
    ]

    /// The DXVK folders Unwine makes fixed copies of, and the fixes each copy gets.
    static let dxvkRenderers = ["d9vk", "dxvk3"]
    private static func recipes(for name: String) -> [Recipe] {
        name == "dxvk3" ? d3d9Fixes + d3d11Fixes : d3d9Fixes
    }

    /// renderer/<name>-unwine/wine when its fixed copy is ready, else nil (the game uses stock files).
    static func fixedDir(_ name: String, engine: InstalledEngine) -> URL? {
        let copy = engine.rendererRoot.appendingPathComponent("\(name)-unwine", isDirectory: true)
        guard (try? String(contentsOf: copy.appendingPathComponent(markerName), encoding: .utf8)) == marker(recipes(for: name)) else { return nil }
        return copy.appendingPathComponent("wine", isDirectory: true)
    }

    // MARK: DEP for 32-bit games, decided by the game's .exe

    /// Wine turns DEP off for a whole 32-bit game as soon as it loads any DLL built without the
    /// NX_COMPAT flag. Windows decides from the game's .exe only. With DEP off, Wine marks every
    /// readable page executable, and DXMT then waits up to a second at a time for macOS to hand back
    /// a frame to draw into: Age of Mythology froze about 100 times a minute until DEP stayed on.
    /// The fix does what Windows does: a DLL without the flag no longer turns DEP off; a .exe without
    /// it still does, so old games that need it keep working. The check moves into padding at the end
    /// of the code ('testb $1,0x5f(%edi); jne' becomes a jump there, which also compares the module
    /// with the .exe's base address). This recipe patches the Steam Play runner's ntdll after the
    /// Steam bridge recipe; `exeDecidesDEPEngine` makes the same change in a copy of the engine's
    /// 32-bit folder, for Online mode and games outside Steam.
    static let exeDecidesDEP = Recipe(
        path: "i386-windows/ntdll.dll",
        cleanSHA256: "2b4b4beb0c2c2db3507ae72869b2b2f3573c6998639c1516e5d6022afc01e6c9",
        patchedSHA256: "6841711c24e16af6d1d317ce65bc74ac00e92fc0a5e6dda159c70aca9c75f231",
        edits: [
            Edit(offset: 0x2f2ad, old: [0xf6, 0x47, 0x5f, 0x01, 0x75, 0x41],
                 new: [0xe9, 0x53, 0x38, 0x03, 0x00, 0x90]),
            Edit(offset: 0x62b05, old: [UInt8](repeating: 0xcc, count: 30),
                 new: [0xf6, 0x47, 0x5f, 0x01, 0x75, 0x13, 0x64, 0xa1, 0x30, 0x00, 0x00, 0x00, 0x8b, 0x40, 0x08,
                       0x3b, 0x46, 0x18, 0x75, 0x05, 0xe9, 0x95, 0xc7, 0xfc, 0xff, 0xe9, 0xd1, 0xc7, 0xfc, 0xff]),
        ])

    /// Patches the runner's 32-bit ntdll in place (`wineLib` is the runner's lib/wine). A file that
    /// is already patched, or is not the build the recipe was made for, is left as it is.
    static func applyExeDecidesDEP(wineLib: URL, log: LogFile?) {
        let file = wineLib.appendingPathComponent(exeDecidesDEP.path)
        guard let sha = try? Downloader.sha256(of: file), sha != exeDecidesDEP.patchedSHA256 else { return }
        guard sha == exeDecidesDEP.cleanSHA256 else {
            log?.line("ntdll: not the build Unwine's DEP fix was made for, so DLLs can still turn DEP off")
            return
        }
        do {
            try apply(exeDecidesDEP, to: file)
            log?.line("Runner: 32-bit games keep DEP on unless their own .exe asks for it off, as on Windows")
        } catch {
            log?.line("Could not apply the DEP fix: \(error.localizedDescription)")
        }
    }

    /// The same edits on the engine's own 32-bit ntdll (no Steam bridge in it).
    static let exeDecidesDEPEngine = Recipe(
        path: "i386-windows/ntdll.dll",
        cleanSHA256: "ae3ce87f0744ea9180fc91371a2ca5a6ddb5e045e7469480b447c8cd0365c20c",
        patchedSHA256: "117ad3de04812a1d0508cb90879c85a0ca3f86eddbf814bd4ab88a4b6690aed3",
        edits: exeDecidesDEP.edits)

    /// wine/lib/wine-unwine/i386-windows: a clone of the engine's 32-bit Windows folder with that fix.
    private static func windowsCopy(engine: InstalledEngine) -> URL {
        engine.wineDir.appendingPathComponent("lib/wine-unwine/i386-windows", isDirectory: true)
    }

    /// The folder Unwine's own Wine bundles (Online mode, games outside Steam) should load this
    /// arch's Windows files from: the fixed 32-bit copy when it is ready, else the engine's own.
    static func windowsDir(_ arch: String, engine: InstalledEngine) -> URL {
        let own = engine.wineDir.appendingPathComponent("lib/wine/\(arch)", isDirectory: true)
        guard arch == "i386-windows" else { return own }
        let copy = windowsCopy(engine: engine)
        guard (try? String(contentsOf: copy.appendingPathComponent(markerName), encoding: .utf8)) == marker([exeDecidesDEPEngine]) else { return own }
        return copy
    }

    private static func prepareWindowsCopy(engine: InstalledEngine, log: LogFile) {
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/i386-windows", isDirectory: true)
        let copy = windowsCopy(engine: engine)
        guard fm.fileExists(atPath: source.path) else { return }
        guard (try? Downloader.sha256(of: source.appendingPathComponent("ntdll.dll"))) == exeDecidesDEPEngine.cleanSHA256 else {
            log.line("i386-windows: not the ntdll build Unwine's DEP fix was made for, so Online mode and games outside Steam use it unchanged")
            return
        }
        let stage = copy.deletingLastPathComponent().appendingPathComponent(".i386-windows-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try clone(source, to: stage)
            try apply(exeDecidesDEPEngine, to: stage.appendingPathComponent("ntdll.dll"))
            try marker([exeDecidesDEPEngine]).write(to: stage.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: copy)
            try fm.moveItem(at: stage, to: copy)
            log.line("Made wine-unwine/i386-windows: in Online mode and games outside Steam, only a 32-bit game's .exe can turn DEP off")
        } catch {
            try? fm.removeItem(at: stage)
            log.line("Could not make wine-unwine/i386-windows: \(error.localizedDescription)")
        }
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
    /// DXVK 3 needs. KosmicKrisp is built for macOS 26 and later (its minos is 26.0), so on macOS 15
    /// to 25 it does not load at all, and MoltenVK (macOS 11 and later) is the only driver that runs.
    static func vulkanICD(engine: InstalledEngine) -> URL {
        let icd = engine.runtime.appendingPathComponent("Resources/vulkan/icd.d", isDirectory: true)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
            return icd.appendingPathComponent("MoltenVK_icd.json")
        }
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
        for name in dxvkRenderers where fixedDir(name, engine: engine) == nil {
            prepareCopy(of: engine.rendererRoot.appendingPathComponent(name, isDirectory: true),
                        to: engine.rendererRoot.appendingPathComponent("\(name)-unwine", isDirectory: true),
                        recipes: recipes(for: name), log: log)
        }
        if windowsDir("i386-windows", engine: engine) != windowsCopy(engine: engine) { prepareWindowsCopy(engine: engine, log: log) }
        prepareDriver(engine: engine, log: log)
    }

    private static let markerName = ".unwine-patch"
    private static func marker(_ recipes: [Recipe]) -> String { recipes.map(\.patchedSHA256).joined(separator: "\n") + "\n" }

    private static func prepareCopy(of source: URL, to copy: URL, recipes: [Recipe], log: LogFile) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        // Only when every file is the exact build a recipe was made for.
        for r in recipes {
            guard (try? Downloader.sha256(of: source.appendingPathComponent(r.path))) == r.cleanSHA256 else {
                log.line("\(source.lastPathComponent): not the DXVK build Unwine's fixes were made for, so its games use it unchanged")
                return
            }
        }
        let stage = copy.deletingLastPathComponent().appendingPathComponent(".\(copy.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        do {
            try clone(source, to: stage)
            for r in recipes { try apply(r, to: stage.appendingPathComponent(r.path)) }
            try marker(recipes).write(to: stage.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: copy)
            try fm.moveItem(at: stage, to: copy)
            log.line("Made \(copy.lastPathComponent): DXVK's async shaders now also cover the game's main picture, and a texture the Mac cannot share no longer closes the game")
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
