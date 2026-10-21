import Foundation

/// One of Unwine's own fixes to an engine's files (see RendererPatches), and whether it is in place.
struct UnwineFix: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case directX9       // d9vk-unwine: DXVK's DirectX 9 layer, which every DirectX 8 and 9 game uses
        case dxvk           // dxvk3-unwine: DXVK as the game's whole graphics layer
        case dep            // wine/lib/wine-unwine: 32-bit games keep DEP on
        case vulkanMemory   // the KosmicKrisp driver copy that reports the real free memory

        var title: String {
            switch self {
            case .directX9: return "DirectX 8 and 9 games"
            case .dxvk: return "Games on the DXVK layer"
            case .dep: return "32-bit games (DEP)"
            case .vulkanMemory: return "Vulkan memory (KosmicKrisp)"
            }
        }

        /// The words after "Unwine's fix for".
        var subject: String {
            switch self {
            case .directX9: return "DirectX 8 and 9 games"
            case .dxvk: return "games on the DXVK layer"
            case .dep: return "32-bit games"
            case .vulkanMemory: return "Vulkan memory"
            }
        }

        /// What the fix does, when it is on.
        var effect: String {
            switch self {
            case .directX9: return "Shaders for the game's main picture build in the background. A picture that the Mac cannot share no longer closes the game."
            case .dxvk: return "A picture that the Mac cannot share no longer closes the game."
            case .dep: return "Only the game's own .exe can turn DEP off, as on Windows. This stops freezes like the ones in Age of Mythology."
            case .vulkanMemory: return "Vulkan tells games how much memory the Mac really has free."
            }
        }
    }

    let kind: Kind
    let on: Bool
    let why: String     // what it does when on; why it is off otherwise

    var id: String { kind.rawValue }
}

/// An engine Unwine installed but did not switch to, because a fix the current engine has does not
/// fit it. A newer Unwine may carry that fix, so it looks again after an update of Unwine itself.
struct HeldEngine: Codable, Equatable, Sendable {
    var folder: String
    var since: String               // the Unwine version that held it back
    var missing: [UnwineFix.Kind]
}

/// Which of Unwine's fixes are in place for an engine. RendererPatches leaves a marker next to each
/// fixed copy it makes; this only reads those markers, through the same checks the launch code uses.
enum PatchStatus {
    /// Every fix, on or off, for one engine. Reads a few small files. With `explain`, a fix that is off
    /// also gets its reason from the engine's own files, which reads checksums (slower).
    static func fixes(engine: InstalledEngine, explain: Bool = false) -> [UnwineFix] {
        let fm = FileManager.default
        func has(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let newBuild = "This engine has a different build of these files. Unwine's fix does not fit it yet."

        var out: [UnwineFix] = []
        for (kind, folder) in [(UnwineFix.Kind.directX9, "d9vk"), (.dxvk, "dxvk3")] {
            let on = RendererPatches.fixedDir(folder, engine: engine) != nil
            let why = on ? kind.effect
                : !has(engine.rendererRoot.appendingPathComponent(folder)) ? "This engine has no \(folder == "d9vk" ? "DirectX 9 part of DXVK" : "DXVK 3")."
                : newBuild
            out.append(UnwineFix(kind: kind, on: on, why: why))
        }

        let copy = engine.wineDir.appendingPathComponent("lib/wine-unwine/i386-windows", isDirectory: true)
        let depOn = RendererPatches.windowsDir("i386-windows", engine: engine).standardizedFileURL == copy.standardizedFileURL
        var depWhy = UnwineFix.Kind.dep.effect
        let ntdll = engine.wineDir.appendingPathComponent("lib/wine/i386-windows/ntdll.dll")
        if !depOn {
            depWhy = !has(ntdll) ? "This engine has no 32-bit part."
                : explain && (try? Downloader.sha256(of: ntdll)) == RendererPatches.exeDecidesDEPEngine.cleanSHA256
                    ? "Unwine could not make its fixed copy. Quit and open Unwine to try again."
                    : newBuild
        } else if explain, Runner.record()?.engineFolder == engine.folder,
                  let sha = try? Downloader.sha256(of: Runner.root.appendingPathComponent("lib/wine/i386-windows/ntdll.dll")),
                  sha != RendererPatches.exeDecidesDEP.patchedSHA256 {
            depWhy += " Games from Steam do not have it yet. They get it when Unwine builds its Steam tool again."
        }
        out.append(UnwineFix(kind: .dep, on: depOn, why: depWhy))

        // KosmicKrisp loads on macOS 26 and later only. Before that, MoltenVK draws, and the fix has no use.
        let modern = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        let vkOn = modern && RendererPatches.vulkanICD(engine: engine).lastPathComponent == "kosmickrisp_unwine_icd.json"
        let driver = engine.frameworks.appendingPathComponent(RendererPatches.vulkanBudget.path)
        let vkWhy = vkOn ? UnwineFix.Kind.vulkanMemory.effect
            : !modern ? "Not needed: on this macOS, games use MoltenVK. KosmicKrisp needs macOS 26 or newer."
            : !has(driver) ? "This engine has no KosmicKrisp driver."
            : explain && (try? Downloader.sha256(of: driver)) == RendererPatches.vulkanBudget.cleanSHA256
                ? "Unwine could not make its fixed copy. Quit and open Unwine to try again."
                : newBuild
        out.append(UnwineFix(kind: .vulkanMemory, on: vkOn, why: vkWhy))
        return out
    }

    /// The fixes `current` has that `next` would not have.
    static func lost(from current: InstalledEngine, to next: InstalledEngine) -> [UnwineFix.Kind] {
        let now = Set(fixes(engine: current).filter(\.on).map(\.kind))
        let then = Set(fixes(engine: next).filter(\.on).map(\.kind))
        return UnwineFix.Kind.allCases.filter { now.contains($0) && !then.contains($0) }
    }

    /// "Unwine's fix for 32-bit games", or "fixes for … and …" when there are more.
    static func fixPhrase(_ kinds: [UnwineFix.Kind]) -> String {
        let names = kinds.map(\.subject)
        let list = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Unwine's \(kinds.count == 1 ? "fix" : "fixes") for \(list)"
    }

    /// What Settings says about a held engine.
    static func heldNote(_ engine: InstalledEngine, missing: [UnwineFix.Kind]) -> String {
        "New engine \(engine.label) is ready, but \(fixPhrase(missing)) \(missing.count == 1 ? "does" : "do") not fit it yet. Your current engine stays."
    }
}
