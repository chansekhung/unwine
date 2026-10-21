import AppKit
import Foundation

/// An .exe the user added that the Steam library already has. Unwine asks before it adds it.
struct SteamCopyAsk: Identifiable {
    let exe: URL
    let folder: URL?
    let title: String
    let message: String
    /// The Steam game that has the program, when Unwine knows it: the question can open its page.
    var game: SteamGame? = nil
    var id: String { exe.path }
}

/// Set once, from any thread, when a process ends: its exit status.
final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    func set(_ status: Int32) { lock.withLock { code = status } }
    var status: Int32? { lock.withLock { code } }
}

/// Added games, bottles, mods and Wine tools.
extension AppModel {
    // MARK: Start

    /// Runs once, from start(), right after state.json is read and before the profiles are written.
    func startAddedGames() {
        // The profiles take each game's launch options from here.
        LaunchOptions.publish(stored.launchOptions)
        // start() picks the engine next. Then the template for new added games is made if it is
        // missing, and an added game that was already running is followed again.
        Task {
            self.followEngineForTemplate()
            self.followRunningSessions()
        }
        // A template that waited while the Mac saved battery is made once it is on power again.
        PowerState.shared.onChange { [weak self] in
            if !PowerState.shared.savesBattery { self?.warmBottleTemplate() }
        }
    }

    /// An added game whose bottle runs as Unwine opens (Unwine was quit while it played): its
    /// playtime counts on, and the display stays awake. Unwine cannot tell if its first process
    /// ended, so it closes no leftovers there.
    private func followRunningSessions() {
        var bottles = Set<Int>()
        for r in stored.localGames.sorted(by: { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }) {
            guard bottles.insert(r.bottle).inserted else { continue }
            let game = LocalGames.game(from: r)
            guard LocalGames.isRunning(game) else { continue }
            Task { await self.watchLocalSession(game, exited: ExitFlag(), installsBefore: nil, since: Date()) }
        }
    }

    // MARK: Launch options and mods

    func launchOptions(for id: Int) -> LaunchOptions { stored.launchOptions[id] ?? LaunchOptions() }

    /// Changes a game's launch options and mods. The game's profile gets them at once (or when its
    /// bottle closes), so they apply the next time the game starts, from Unwine or from Steam.
    func setLaunchOptions(_ id: Int, _ change: (inout LaunchOptions) -> Void) {
        // The page of a game that was just removed saves its unsaved text as it closes: not kept.
        guard games.contains(where: { $0.id == id }) else { return }
        var options = launchOptions(for: id)
        change(&options)
        guard options != launchOptions(for: id) else { return }
        stored.launchOptions[id] = options.isEmpty ? nil : options
        save()
        LaunchOptions.publish(stored.launchOptions)
        writeProfile(for: id)
    }

    // MARK: Adding

    /// The Steam game that already has this program, said the way the add dialog asks. Nil when
    /// the program is not in a Steam library folder.
    func steamCopy(of exe: URL, folder: URL?) -> SteamCopyAsk? {
        let path = exe.standardizedFileURL.path.lowercased()
        func inside(_ dir: URL) -> Bool { path.hasPrefix(dir.standardizedFileURL.path.lowercased() + "/") }
        let steam = games.filter { $0.localExe == nil }
        if let game = steam.first(where: { inside($0.installDir) }) {
            return SteamCopyAsk(exe: exe, folder: folder, title: "This game is in your Steam library as \(game.name). Play it from there.",
                                message: "Steam keeps it up to date, and its page in Unwine has the same settings. If you add it anyway, it runs without Steam, in a Windows bottle of its own.",
                                game: game)
        }
        if let game = steam.first(where: { inside($0.compatData) }) {
            return SteamCopyAsk(exe: exe, folder: folder, title: "This program is in the Windows bottle of \(game.name).",
                                message: "To run it there, open the page of \(game.name) and press Run a program in this bottle. If you add it anyway, it runs in a new bottle of its own.",
                                game: game)
        }
        if SteamLibrary.steamappsFolders().contains(where: inside) {
            return SteamCopyAsk(exe: exe, folder: folder, title: "This program is in a Steam library folder.",
                                message: "If Steam has it as a game, play it from Steam. If you add it anyway, it runs without Steam, in a Windows bottle of its own.")
        }
        return nil
    }

    // MARK: Play history

    func markPlayed(_ id: Int) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == id }) else { return }
        stored.localGames[i].lastPlayed = Date()
        save()
    }

    private func addPlaytime(_ id: Int, minutes: Int) {
        guard minutes > 0, let i = stored.localGames.firstIndex(where: { $0.id == id }) else { return }
        stored.localGames[i].playtimeMinutes += minutes
        save()
    }

    /// Follows a game until its bottle closes: counts its playtime from `started` (saved every 5
    /// minutes, so a quit Unwine loses little), keeps the display awake while it shows a window, as
    /// NotProton does for Steam Play games (caffeinate -d -i), and closes leftovers. Leftovers: the
    /// game's own process ended, yet the bottle runs on for 30 s with no window (a crash reporter, a
    /// helper). The tile would show "running" and block Play. A process that may still be starting
    /// is never a leftover: one under two minutes old, or under ten that keeps the CPU busy. The game
    /// behind a launcher can take that long under Rosetta to show its first window.
    func watchLocalSession(_ game: SteamGame, exited: ExitFlag, installsBefore: Set<String>?, since started: Date) async {
        let pfx = LocalGames.prefix(game)
        // Programs that share a bottle share one session.
        guard watchedBottles.insert(pfx.path).inserted else { return }
        defer { watchedBottles.remove(pfx.path) }
        var credited = 0
        var activity: NSObjectProtocol?
        var quietSince: Date?
        var firstSeen: [pid_t: Date] = [:]
        var cpuBefore: [pid_t: Double] = [:]
        var round = 0
        while true {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            round += 1
            let alive = await Task.detached(operation: { LocalGames.isRunning(game) }).value
            let minutes = Int(Date().timeIntervalSince(started) / 60)
            if minutes - credited >= 5 { addPlaytime(game.id, minutes: minutes - credited); credited = minutes }
            guard alive else { break }
            // The process list costs more than the bottle check, so it is read every 10 s.
            guard round % 2 == 0 else { continue }
            let (pids, cpu) = await Task.detached { () -> ([pid_t], [pid_t: Double]) in
                let pids = Self.bottlePIDs(prefix: pfx)
                return (pids, BottleTools.cpuSeconds(pids))
            }.value
            let shown = !Self.withWindows(pids).isEmpty
            if shown, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                                 reason: "Playing \(game.name)")
            } else if !shown, let a = activity {
                ProcessInfo.processInfo.endActivity(a)
                activity = nil
            }
            let now = Date()
            firstSeen = firstSeen.filter { pids.contains($0.key) }
            for pid in pids where firstSeen[pid] == nil { firstSeen[pid] = now }
            let youngest = firstSeen.values.map { now.timeIntervalSince($0) }.min() ?? .infinity
            // CPU seconds the bottle used since the last look, 10 s ago. 3 s or more: it works.
            let used = cpu.reduce(0.0) { $0 + max(0, $1.value - (cpuBefore[$1.key] ?? 0)) }
            cpuBefore = cpu
            let starting = youngest < 120 || (youngest < 600 && used >= 3)
            // A program the user ran in the bottle (a patch, a mod tool) may work with no window.
            guard !shown, !starting, exited.status != nil, (bottleRuns[pfx.path] ?? 0) == 0 else { quietSince = nil; continue }
            let since = quietSince ?? now
            quietSince = since
            if now.timeIntervalSince(since) >= 30, let engine {
                let log = localLog(game.id)
                log.line("The game's process ended, and its bottle ran on for 30 s with no window. Closing what was left.")
                await LocalGames.stop(game, engine: engine, log: log)
                banner = "\(game.name) ended, but some of its programs stayed open without a window. Unwine closed them."
                quietSince = nil
            }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        // The last part of a minute counts when it is half a minute or more.
        addPlaytime(game.id, minutes: Int((Date().timeIntervalSince(started) / 60).rounded()) - credited)
        await offerInstalledPrograms(game, before: installsBefore)
        await refreshSteam()
        // The template is not made while a game runs.
        warmBottleTemplate()
    }

    // MARK: After an installer

    /// After an installer's bottle closed: the programs it put there. Its page then offers them, so
    /// the entry can start the installed game in the same bottle, with no second entry.
    func offerInstalledPrograms(_ game: SteamGame, before: Set<String>?) async {
        guard let before else { return }
        let pfx = LocalGames.prefix(game)
        let found = await Task.detached(priority: .utility) { () -> [(url: URL, size: Int64)] in
            let added = LocalGames.installedPrograms(in: pfx).subtracting(before).map { URL(fileURLWithPath: $0) }
                .filter { !$0.lastPathComponent.lowercased().contains("unins") }
            return LocalGames.ranked(added.map { ($0, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) })
        }.value
        guard !found.isEmpty, stored.localGames.contains(where: { $0.id == game.id }) else { return }
        installedPrograms[game.id] = found
        banner = "\(game.name) ended. It put \(found.count == 1 ? "a new program" : "\(found.count) new programs") in its Windows bottle. Open its page and press Pick the installed program."
    }

    /// Makes an installer's entry start the program it installed. The bottle and its saves stay,
    /// and the entry takes the installed game's name.
    func useInstalledProgram(_ id: Int, exe: URL) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == id }) else { return }
        let old = stored.localGames[i].name
        var name = LocalGames.suggestedName(for: exe)
        if let role = LocalGames.role(of: exe) { name += " · \(role)" }
        stored.localGames[i].name = uniqueLocalName(name, exe: exe, except: id)
        installedPrograms[id] = nil
        relocateLocalGame(id, exe: exe)
        banner = "\(old) is now \(stored.localGames[i].name). It starts \(exe.lastPathComponent), which the installer put in its Windows bottle. The bottle and its saves stay."
    }

    // MARK: The bottle template

    /// Makes the bottle template in the background each time the engine changes (setup, an update),
    /// so the next new added game starts at once. Watches the engine again after each change.
    func followEngineForTemplate() {
        // The template of an engine that is no longer in use only takes space (about 340 MB).
        if let keep = engine?.folder, templateTask == nil {
            Task.detached(priority: .utility) { BottleTemplate.prune(keep: keep) }
        }
        warmBottleTemplate()
        withObservationTracking { _ = engine?.folder } onChange: { [weak self] in
            Task { @MainActor in self?.followEngineForTemplate() }
        }
    }

    /// Starts making the template when added games can use it and it is missing. Not while a game
    /// runs or the Mac saves battery: Wine works hard for half a minute. The first Play makes it then.
    /// What runs is read here, not from the last refresh: at start there was none yet.
    func warmBottleTemplate() {
        guard let engine, !stored.localGames.isEmpty, templateTask == nil, !templateFailed.contains(engine.folder),
              !PowerState.shared.savesBattery, BottleTemplate.ready(engine) == nil,
              !Runner.isInUse(), !OnlineSteam.isInUse,
              !stored.localGames.contains(where: { LocalGames.isRunning(LocalGames.game(from: $0)) }) else { return }
        Task { _ = await bottleTemplate() }
    }

    /// The engine's ready bottle template, made first when it is missing. One build runs at a time,
    /// and the others wait for it. Nil when it cannot be made: the bottle is then made with wineboot.
    func bottleTemplate() async -> URL? {
        guard let engine else { return nil }
        if let ready = BottleTemplate.ready(engine) { return ready }
        if let task = templateTask {
            _ = await task.value
            return BottleTemplate.ready(engine)
        }
        guard !templateFailed.contains(engine.folder) else { return nil }
        let log = self.log
        let task = Task { () -> URL? in
            do { return try await BottleTemplate.build(engine: engine) }
            catch { log.line("The bottle template failed, so bottles are made with wineboot: \(error.localizedDescription)"); return nil }
        }
        templateTask = task
        let url = await task.value
        templateTask = nil
        if url == nil { templateFailed.insert(engine.folder) }
        return url
    }

    // MARK: The game's Windows bottle

    func bottleExists(_ game: SteamGame) -> Bool {
        FileManager.default.fileExists(atPath: game.compatData.appendingPathComponent("pfx/system.reg").path)
    }

    /// Why no program can run in this game's bottle now, or nil when one can.
    func bottleBlocker(_ game: SteamGame) -> String? {
        if engine == nil { return "Unwine's engine is not set up yet." }
        if bottleToolStarting[game.id] != nil { return "A program is starting in this bottle. Wait a moment." }
        if game.localExe != nil {
            if localStarting[game.id] != nil { return "Wait until the game has started." }
        } else {
            if let tool = mappings[game.id], tool != Runner.toolName { return "Steam runs this game with another tool (\(tool)), so its bottle is not Unwine's." }
        }
        if !bottleExists(game) {
            return "Play the game once first. \(game.localExe == nil ? "Steam" : "Unwine") makes its Windows bottle then."
        }
        return nil
    }

    /// The log for programs run in a Steam game's bottle. An added game's programs write to its own log.
    func bottleLog(_ game: SteamGame) -> LogFile {
        if game.localExe != nil { return localLog(game.id) }
        if let log = toolLogs[game.id] { return log }
        let log = LogFile("tools-\(game.id).log")
        toolLogs[game.id] = log
        return log
    }

    /// Runs a program or one of Wine's tools in the game's bottle, with the game's own settings, so it
    /// joins a running game (the same msync). The waiting line shows until its window does.
    func runInBottle(_ game: SteamGame, _ program: BottleProgram) async {
        if let why = bottleBlocker(game) { banner = why; return }
        guard let engine else { return }
        let pfx = game.compatData.appendingPathComponent("pfx", isDirectory: true)
        let source = settingsSource(for: game).flatMap { s in games.first { $0.id == s.id } } ?? game
        bottleToolStarting[game.id] = "Starting \(program.title)…"
        defer { bottleToolStarting[game.id] = nil }
        writeProfile(for: source.id)    // waits by itself while the bottle runs, so its msync stays
        // A Steam game's display write into this closed bottle (AppModel+Bottles) finishes first: a
        // program that joined its regedit would hold the bottle open past the write's check. Seconds.
        await bottleTasks[game.id]?.value
        let launch = BottleTools.launch(engine: engine, prefix: pfx, profile: Profiles.file(for: source.id))
        let log = bottleLog(game)
        let before = Self.withWindows(await Task.detached(operation: { Self.bottlePIDs(prefix: pfx) }).value)
        let ended = ExitFlag()
        let title = program.title, key = pfx.path
        log.line("Running \(title) in the Windows bottle of \(game.name)")
        do {
            _ = try Shell.spawn(launch.loader, program.arguments, env: launch.env,
                                cwd: program.folder ?? pfx.appendingPathComponent("drive_c", isDirectory: true), log: log,
                                onExit: { [weak self] status in
                                    log.line("\(title) ended with status \(status)")
                                    ended.set(status)
                                    Task { @MainActor in self?.bottleRuns[key, default: 1] -= 1 }
                                })
            bottleRuns[key, default: 0] += 1
        } catch {
            banner = "\(title) did not start: \(error.localizedDescription)"
            return
        }
        var shown = false
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = Self.withWindows(await Task.detached(operation: { Self.bottlePIDs(prefix: pfx) }).value)
            if let pid = now.subtracting(before).first { bringToFront(pid); shown = true; break }
            if ended.status != nil { break }
        }
        // A program with no window (a silent patch) says how it went here, as the waiting line goes.
        if !shown {
            switch ended.status {
            case 0?: banner = "\(title) ran in the Windows bottle of \(game.name) and finished."
            case _?: banner = "\(title) closed before it showed a window. Show logs on the game's page says why."
            case nil: banner = "\(title) is still running in the Windows bottle of \(game.name), with no window yet."
            }
        }
        await refreshSteam()
    }

    /// Asks for a program (.exe, .msi, .bat or .cmd), then runs it in the game's bottle.
    func pickProgramForBottle(_ game: SteamGame) {
        guard let url = FilePicker.pick(message: "Pick a program to run in the Windows bottle of \(game.name), such as an installer, a patch or a mod tool.",
                                        prompt: "Run", extensions: ["exe", "msi", "bat", "cmd"], in: game.installDir) else { return }
        Task { await runInBottle(game, .file(url)) }
    }

    func showBottleDrive(_ game: SteamGame) {
        NSWorkspace.shared.open(game.compatData.appendingPathComponent("pfx/drive_c", isDirectory: true))
    }

    /// The game folder the user picked when there is one, else the program in its folder.
    func showGameFiles(_ game: SteamGame) {
        guard let exe = game.localExe else { NSWorkspace.shared.activateFileViewerSelecting([game.installDir]); return }
        if game.installDir.standardizedFileURL != exe.deletingLastPathComponent().standardizedFileURL,
           FileManager.default.fileExists(atPath: game.installDir.path) {
            NSWorkspace.shared.open(game.installDir)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([exe])
        }
    }

    // MARK: Pointing an added game at a program

    /// Points the game at another .exe. The bottle and its saves stay. An installer's entry looks in
    /// its bottle's C: drive first, and takes the name of the program it installed there.
    func changeLocalProgram(_ game: SteamGame) {
        let drive = game.compatData.appendingPathComponent("pfx/drive_c", isDirectory: true)
        let installer = game.localExe.map(LocalGames.looksLikeInstaller) == true && FileManager.default.fileExists(atPath: drive.path)
        guard let url = FilePicker.pick(message: "Pick the program that \(game.name) starts. Its Windows bottle and saves stay.",
                                        prompt: "Use This Program", extensions: ["exe"], in: installer ? drive : game.installDir) else { return }
        if installer, LocalGames.isInside(url, bottle: game.bottleID ?? game.id) {
            useInstalledProgram(game.id, exe: url)
        } else {
            relocateLocalGame(game.id, exe: url)
        }
    }

    /// Finds a moved or missing program again, starting the search where it was.
    func locateLocalGame(_ game: SteamGame) {
        guard let exe = game.localExe else { return }
        var dir = exe.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        guard let url = FilePicker.pick(message: "Unwine cannot find \(exe.lastPathComponent). Pick it where it is now. Its Windows bottle and saves stay.",
                                        prompt: "Use This Program", extensions: ["exe"], in: dir) else { return }
        relocateLocalGame(game.id, exe: url)
    }
}
