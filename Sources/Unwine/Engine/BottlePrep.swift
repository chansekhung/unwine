import Foundation

/// What a game's Windows bottle must hold before the game starts, read from the game's Unwine profile:
/// the Display section's Mac values (in Wine's registry) and, for MetalFX for DLSS on D3DMetal, Apple's
/// DLSS files. Only while the bottle is closed: Wine reads both when a process starts, and saves its
/// registry as its server quits. An open bottle keeps what it has until it closes.
enum BottlePrep {
    struct Plan: Sendable {
        var display: MacDriverValues? = nil
        var dlss: (layer: NGXFiles.Layer, dir: URL)? = nil
        var msync: String? = nil
    }

    /// The plan in a profile that Profiles.render wrote.
    static func plan(profile: URL) -> Plan {
        guard let text = try? String(contentsOf: profile, encoding: .utf8) else { return Plan() }
        var values: [String: String] = [:]
        for (key, raw) in OnlineSteam.profileAssignments(text) {
            if let value = OnlineSteam.shellWord(raw, env: [:]) { values[key] = value }
        }
        var plan = Plan(display: MacDriverValues.fromProfile(text), msync: values["WINEMSYNC"])
        // EXPERIMENTAL (DLSS to MetalFX on D3DMetal): see NGXFiles. A game on DXMT gets DXMT's files back.
        if let d3dmetal = values["WINEDLLPATH_D3DMETAL"], values["D3DM_ENABLE_METALFX"] == "1" {
            plan.dlss = (.d3dmetal, URL(fileURLWithPath: d3dmetal, isDirectory: true))
        } else if let dxmt = values["WINEDLLPATH_DXMT"] {
            plan.dlss = (.dxmt, URL(fileURLWithPath: dxmt, isDirectory: true))
        }
        return plan
    }

    enum Outcome: Sendable {
        case done
        case waiting    // the bottle is open, or not made yet, and something must change once it is closed
        case failed
    }

    /// Brings a closed bottle in line with the game's profile. Cheap when nothing changed: it reads two
    /// small record files in the bottle. `announce` names the slow step (a Wine start) for the waiting screen.
    static func apply(profile: URL, prefix: URL, engine: InstalledEngine, game: String, log: LogFile,
                      announce: @escaping @MainActor (String) -> Void) async -> Outcome {
        let wanted = plan(profile: profile)
        // Apple's rename goes next to D3DMetal's own files, whatever the bottle holds.
        if let dlss = wanted.dlss, dlss.layer == .d3dmetal { NGXFiles.prepareD3DMetal(wineDir: dlss.dir, log: log) }
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path) else {
            // No bottle yet (Steam makes one at the game's first start).
            let later = !(wanted.display?.isWineDefault ?? true) || wanted.dlss?.layer == .d3dmetal
            return later ? .waiting : .done
        }
        let display = wanted.display.flatMap { $0.differs(from: prefix) ? $0 : nil }
        let swap = wanted.dlss.flatMap { NGXFiles.needsSwap(to: $0.layer, layerDir: $0.dir, prefix: prefix) ? $0 : nil }
        guard display != nil || swap != nil else { return .done }
        guard !OnlineSteam.serverIsAlive(prefix) else { return .waiting }
        var ok = true
        if let swap, !NGXFiles.place(swap.layer, layerDir: swap.dir, prefix: prefix, game: game, log: log) { ok = false }
        if let display {
            await announce("Writing the display settings into the game's bottle…")
            switch await BottleRegistry.write(display.entries, prefix: prefix, engine: engine, msync: wanted.msync, log: log) {
            case .written:
                try? display.line.write(to: MacDriverValues.recordFile(prefix), atomically: true, encoding: .utf8)
                log.line("Display settings for \(game) are in its bottle: \(display.line)")
            case .unchecked:
                // No record yet, so the next start checks again.
                log.line("Display settings for \(game) went into its bottle. Wine still runs there and saves them when it closes.")
            case .busy:
                return .waiting
            case .failed:
                log.line("Warning: the display settings did not take in \(game)'s bottle")
                ok = false
            }
        }
        return ok ? .done : .failed
    }
}
