import Foundation

// Measured session summary (metalperftrace): while a game runs, Unwine notes which Wine processes are
// the game's. When the last of them ends (for most games, when the bottle closes), it asks macOS 27
// how they drew, and keeps a few numbers per game for the "Last session" row on the game page.

/// How a game ran the last time it played, as macOS measured it. Small on purpose: state.json keeps
/// one per game.
struct SessionSummary: Codable, Equatable, Sendable {
    var ended = Date.distantPast        // when the game's bottle closed
    var seconds: Double = 0             // time the game was on the screen
    var fps: Double = 0                 // frames on the screen each second
    var gpuMs: Double = 0               // GPU time for one frame
    var shaderSeconds: Double = 0       // time the game spent building new shaders
    var settings = GameSettings()       // what the game ran with, to tell when the user changed them since
    var screenHz = 60                   // the screen's refresh rate then
    // The battery overlay the game's profile had (BatteryOverlay.strict): nil when it started with its own settings.
    var batteryStrict: Bool? = nil
}

extension SessionSummary {
    /// Every field decodes with a default, so a summary saved by an older Unwine keeps working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionSummary()
        ended = (try? c.decodeIfPresent(Date.self, forKey: .ended)) ?? d.ended
        seconds = (try? c.decodeIfPresent(Double.self, forKey: .seconds)) ?? d.seconds
        fps = (try? c.decodeIfPresent(Double.self, forKey: .fps)) ?? d.fps
        gpuMs = (try? c.decodeIfPresent(Double.self, forKey: .gpuMs)) ?? d.gpuMs
        shaderSeconds = (try? c.decodeIfPresent(Double.self, forKey: .shaderSeconds)) ?? d.shaderSeconds
        settings = (try? c.decodeIfPresent(GameSettings.self, forKey: .settings)) ?? d.settings
        screenHz = (try? c.decodeIfPresent(Int.self, forKey: .screenHz)) ?? d.screenHz
        batteryStrict = (try? c.decodeIfPresent(Bool.self, forKey: .batteryStrict)) ?? d.batteryStrict
    }

    /// "58 fps · GPU 9.1 ms a frame · shaders 3.2 s"
    var line: String {
        let shaders = shaderSeconds >= 0.05 ? "shaders \(String(format: "%.1f", shaderSeconds)) s" : "no new shaders"
        return "\(Int(fps.rounded())) fps · GPU \(String(format: "%.1f", gpuMs)) ms a frame · \(shaders)"
    }

    /// One plain tip from the numbers, or nil when nothing stands out. `now` is what the game is set to
    /// now. `canSharpen` is true where DXMT draws a DirectX 10/11 game: MetalFX sharpening and 120 fps
    /// mode reach only those games. Sharpening also needs a Retina screen (`screenScale` 2 or more).
    /// `takesCap` is false where Unwine has no frame cap for the game's layer (AppModel.takesFrameCap).
    func tip(now: GameSettings, canSharpen: Bool, takesCap: Bool, screenScale: CGFloat = Profiles.screenScale) -> String? {
        if now != settings { return "You changed settings after this session. Play again to see how they run." }
        // What the game really ran with: while the Mac saved battery, its profile had the battery
        // overlay (a cap when the user set none, and no 120 fps mode). A layer with no cap ignores both caps.
        let ran = batteryStrict.map { BatteryOverlay(strict: $0, screenHz: screenHz).applied(to: settings) } ?? settings
        let cap = takesCap ? ran.fpsCap : nil
        let fast = canSharpen && screenHz > 60
        // 120 fps mode paces to the screen only when no cap is set: the cap wins.
        let paced = ran.fps120 && fast && cap == nil
        // The rate the game aims for: its cap, the screen with 120 fps mode, or else 60.
        let goal = Double(cap ?? (paced ? screenHz : 60))
        // The GPU needs longer than a frame may take, and the game stays below its goal.
        if gpuMs > 1000 / goal, fps < goal * 0.95 {
            // A frame that misses a refresh waits for the next one (the 120 fps mode note says the same).
            if paced {
                return "Each frame needs more than \(String(format: "%.1f", 1000 / goal)) ms of GPU time. 120 fps mode needs less, so motion can look uneven. Turn it off in Speed, or lower the game's graphics settings."
            }
            // Sharpening alone costs GPU time: it helps only with a lower resolution in the game. On a
            // screen without Retina pixels it does nothing (DXMT enlarges by the screen's scale).
            return canSharpen && screenScale >= 2 && !settings.metalFXSpatial
                ? "The GPU is the limit. Lower the game's resolution. MetalFX sharpening in Apple extras keeps a lower resolution sharp."
                : "The GPU is the limit. Lower the game's resolution or its graphics quality."
        }
        // Shader caches stay between starts, so this stutter goes away.
        if shaderSeconds >= 5 {
            return "The first minutes can stutter while the game builds shaders. Later starts are faster."
        }
        // The cap holds the game (a game far above its cap has a cap that does nothing), and each frame
        // fits a higher cap with a margin. A cap that divides the screen's refresh rate paces evenly.
        let roomFor = { (rate: Int) in gpuMs < 0.85 * 1000 / Double(rate) }
        if let cap, abs(fps - Double(cap)) <= Double(cap) * 0.07 {
            // The battery overlay's cap held the game, not one the user set.
            if settings.fpsCap == nil, let strict = batteryStrict {
                return strict
                    ? "Low Power Mode was on or your Mac was hot, so this game started capped at \(cap) fps. To play without this cap, turn off Save battery when unplugged in Speed."
                    : "Your Mac was on battery, so this game started capped at \(cap) fps. Plug in, or turn off Save battery when unplugged in Speed, to play without this cap."
            }
            // The next cap the Frame rate cap picker offers: those caps divide the screen's rate.
            if let next = Profiles.capChoices(screenHz: screenHz).first(where: { $0 > cap }), roomFor(next) {
                guard fast, roomFor(screenHz) else { return "Your Mac has room to spare. Try a higher frame rate cap." }
                return settings.fps120
                    ? "Your Mac has room to spare. Try a higher frame rate cap, or set it to Off so 120 fps mode works."
                    : "Your Mac has room to spare. Try a higher frame rate cap. Or set the cap to Off and turn on 120 fps mode."
            }
        }
        // A full-screen game that asks for 60 Hz stays at 60 on a faster screen. 120 fps mode is for that.
        if cap == nil, fast, !settings.fps120, abs(fps - 60) < 3, roomFor(screenHz) {
            return "The game stays at 60 fps, but your Mac has room to spare. Try 120 fps mode in Speed."
        }
        return nil
    }
}

/// The games running now, with their Wine processes, and the games whose numbers are being read.
@MainActor
@Observable
final class SessionWatch {
    /// One game running now: its Wine processes, when the first one started, and the settings the
    /// game started with (with the battery overlay its profile had, if any).
    struct Run: Sendable {
        var pids = Set<pid_t>()
        var started: Date
        var settings: GameSettings
        var batteryStrict: Bool?
    }

    var measuring = Set<Int>()                                          // games whose numbers are being read now
    @ObservationIgnored var running: [Int: Run] = [:]                   // by game
    @ObservationIgnored var ended: [(game: Int, run: Run, at: Date)] = []    // waiting until no game runs
    @ObservationIgnored var known = Set<pid_t>()                        // Wine processes already read
    @ObservationIgnored var sampling = false
    @ObservationIgnored var saidMissing = false
    @ObservationIgnored var reading: Task<Void, Never>?                 // one reading at a time
}

/// Unwine's bottles by tidied path (see `WineProcesses.tidy`), to tell whose a Wine process is.
struct SessionBottles {
    var online = ""                                 // Windows Steam's bottle
    var steam: [String: Int] = [:]                  // each Steam game's own bottle
    var added: [String: [LocalGameRecord]] = [:]    // the added games that share each bottle
}

extension AppModel {
    /// Runs after each refresh while a game bottle is open, and once more after the last game ends.
    /// It notes which game each Wine process belongs to; once no game runs, it reads how each game
    /// that ended ran. Both run off the main thread, and each session is read once.
    func watchSessions() {
        let watch = sessionWatch
        guard MetalPerfTrace.isAvailable else {
            if MetalPerfTrace.isMacOS27, !watch.saidMissing {
                watch.saidMissing = true
                log.line("Session numbers: \(MetalPerfTrace.tool.path) is missing, so game pages show none")
            }
            return
        }
        guard !watch.sampling, gameRunning || !localRunning.isEmpty || online.inUse || !watch.running.isEmpty else { return }
        watch.sampling = true
        let known = watch.known
        Task {
            let sample = await Task.detached(priority: .utility) { WineProcesses.sample(known: known) }.value
            watch.sampling = false
            noteSessions(sample)
        }
    }

    private func noteSessions(_ sample: WineProcesses.Sample) {
        let watch = sessionWatch
        watch.known = watch.known.intersection(sample.alive).union(sample.read.keys)
        let found = sample.read.compactMapValues { $0 }
        // Each bottle's path is worked out once per look, not once per process.
        let bottles = found.isEmpty ? SessionBottles() : sessionBottles()
        for (pid, info) in found {
            guard let id = sessionGame(info, bottles: bottles) else { continue }
            var run = watch.running[id] ?? sessionRun(id, started: info.started)
            run.pids.insert(pid)
            run.started = min(run.started, info.started)
            watch.running[id] = run
        }
        // A game's session ends with its last process. In most bottles that is when the bottle closes;
        // Windows Steam's bottle stays open after its games quit.
        for (id, run) in watch.running where run.pids.isDisjoint(with: sample.alive) {
            watch.running[id] = nil
            watch.ended.append((id, run, Date()))
        }
        // Reading takes a second or two of CPU, so it waits until no game runs.
        if watch.running.isEmpty, !watch.ended.isEmpty {
            let ended = watch.ended
            watch.ended = []
            readSessions(ended)
        }
    }

    /// A game's run as Unwine first sees it: the settings it started with, and the battery overlay its
    /// profile got then (see writeProfile), so the tip reads the numbers against what really ran.
    private func sessionRun(_ id: Int, started: Date) -> SessionWatch.Run {
        let s = settings(for: id)
        return SessionWatch.Run(started: started, settings: s, batteryStrict: s.saveBatteryUnplugged ? batteryOverlayNow?.strict : nil)
    }

    /// Unwine's bottles by tidied path: Windows Steam's, each Steam game's own, and the ones added games share.
    private func sessionBottles() -> SessionBottles {
        var steam: [String: Int] = [:]
        for game in games where game.localExe == nil { steam[WineProcesses.tidy(LocalGames.prefix(game).path)] = game.id }
        let added = Dictionary(grouping: stored.localGames) {
            WineProcesses.tidy(LocalGames.root.appendingPathComponent("compatdata/\($0.bottle)/pfx").path)
        }
        return SessionBottles(online: WineProcesses.tidy(OnlineSteam.prefix.path), steam: steam, added: added)
    }

    /// The game a Wine process belongs to, from its bottle and its program: a Steam game's own bottle,
    /// the bottle added games share, or Windows Steam's. Nil for anything else, such as Windows Steam
    /// itself or a bottle that is not Unwine's.
    private func sessionGame(_ info: WineProcesses.Info, bottles: SessionBottles) -> Int? {
        let parts = (info.program ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { $0.lowercased() }
        if info.prefix == bottles.online {
            // Windows Steam starts each game from steamapps\common\<the game's folder>.
            guard let i = parts.indices.first(where: { $0 > 0 && parts[$0] == "common" && parts[$0 - 1] == "steamapps" }),
                  i + 1 < parts.count else { return nil }
            return games.first { $0.localExe == nil && $0.installDir.lastPathComponent.lowercased() == parts[i + 1] }?.id
        }
        if let sharers = bottles.added[info.prefix], !sharers.isEmpty {
            // Programs from one game folder share a bottle. A program with no entry of its own (the game
            // a launcher starts, Wine's helpers) counts for the game, not for the launcher.
            let named = sharers.first { URL(fileURLWithPath: $0.exePath).lastPathComponent.lowercased() == parts.last }
            return (named ?? sharers.first { LocalGames.role(of: URL(fileURLWithPath: $0.exePath)) == nil } ?? sharers[0]).id
        }
        return bottles.steam[info.prefix]
    }

    /// Asks macOS how each of these games ran, one after the other, and keeps a summary for each page.
    private func readSessions(_ ended: [(game: Int, run: SessionWatch.Run, at: Date)]) {
        let watch = sessionWatch
        watch.measuring.formUnion(ended.map(\.game))
        let hz = Profiles.screenHz, log = log, previous = watch.reading
        watch.reading = Task {
            await previous?.value
            // macOS writes a layer's last frames a moment after its process ends.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let before = stored.sessions
            for (id, run, at) in ended {
                defer { watch.measuring.remove(id) }
                let frames = await Task.detached(priority: .utility) {
                    await MetalPerfTrace.frames(of: run.pids, from: run.started, to: at, log: log)
                }.value
                guard let frames else { continue }     // the log already says why
                let name = games.first { $0.id == id }?.name ?? "game \(id)"
                // A launcher or a helper can draw too, for less time: the process on the screen longest is the game.
                guard let best = run.pids.compactMap({ frames[$0] }).max(by: { $0.seconds < $1.seconds }),
                      best.seconds >= 30, best.gpuFrames > 0 else {
                    log.line("Session numbers for \(name): less than 30 seconds on the screen with GPU times, so none kept")
                    continue
                }
                let summary = SessionSummary(ended: at, seconds: best.seconds, fps: best.fps, gpuMs: best.gpuPerFrame,
                                             shaderSeconds: best.shaderSeconds, settings: run.settings, screenHz: hz,
                                             batteryStrict: run.batteryStrict)
                stored.sessions[id] = summary
                log.line("Session numbers for \(name): \(summary.line), \(Int(best.seconds / 60)) min on the screen")
            }
            // Added games that were removed keep no numbers.
            let added = Set(stored.localGames.map(\.id))
            stored.sessions = stored.sessions.filter { !LocalGames.isLocal($0.key) || added.contains($0.key) }
            if stored.sessions != before { save() }
        }
    }
}
