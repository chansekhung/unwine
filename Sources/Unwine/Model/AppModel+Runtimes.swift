import Foundation

/// What an added program needs, and which of it its bottle holds, from the last look.
struct RuntimeCheck: Equatable, Sendable {
    var needs: [RuntimeNeed]
    /// Runtimes whose files are in the bottle: the needed ones, and any the user installed by hand.
    var installed: Set<RuntimeID>
    /// What the program needs that no runtime Unwine offers gives it (a Debug build, an unpinned .NET).
    var unoffered: [String] = []
    /// The program file's size and date when its needs were read: a changed file is read again.
    var stamp = ""
}

/// A runtime that installs into an added program's bottle now, for its page.
struct RuntimeJob: Equatable, Sendable {
    let runtime: RuntimeID
    var phase: RuntimeInstaller.Phase
    /// While the bottle is made, before the download: the words of that step.
    var bottleStep: String? = nil
}

/// Microsoft runtimes for added programs: what each one needs, and the one-click install.
extension AppModel {
    /// Reads what the program needs and what its bottle holds, off the main thread. The program's
    /// needs are read again only when its file changed; what the bottle holds is looked at each time.
    func checkRuntimes(_ game: SteamGame) async {
        guard let exe = game.localExe, let engine else { return }
        let pfx = LocalGames.prefix(game)
        let lib = engine.wineDir.appendingPathComponent("lib/wine", isDirectory: true)
        let known = runtimeChecks[game.id]
        let check = await Task.detached(priority: .utility) { () -> RuntimeCheck in
            let stamp = MacApps.stamp(exe)
            var check: RuntimeCheck
            if let known, !stamp.isEmpty, known.stamp == stamp {
                check = known
            } else {
                let needs = RuntimeNeeds.read(exe: exe) { dll, is64 in
                    let copy = lib.appendingPathComponent(is64 ? "x86_64-windows" : "i386-windows").appendingPathComponent(dll)
                    return FileManager.default.fileExists(atPath: copy.path) ? copy : nil
                }
                check = RuntimeCheck(needs: needs, installed: [], unoffered: RuntimeNeeds.unoffered(exe: exe), stamp: stamp)
            }
            let ids = Set(check.needs.map(\.runtime)).union(RuntimeState.recorded(pfx))
            check.installed = ids.filter { RuntimeState.isInstalled($0, prefix: pfx) }
            return check
        }.value
        guard games.contains(where: { $0.id == game.id }) else { return }
        if runtimeChecks[game.id] != check { runtimeChecks[game.id] = check }
    }

    /// The runtimes the program needs that its bottle does not hold yet.
    func missingRuntimes(_ game: SteamGame) -> [RuntimeNeed] {
        // A game's page has no runtime section, so a program moved to Games asks for none.
        guard isApp(game), let check = runtimeChecks[game.id] else { return [] }
        return check.needs.filter { !check.installed.contains($0.runtime) }
    }

    static let runtimeInstallingReason = "A runtime is installing in this bottle. Wait until it is done."

    /// The runtime install that runs in this program's bottle now: its own, or one of a program that
    /// shares the bottle. While it runs, nothing else may start, stop or change in the bottle.
    func runtimeJob(inBottleOf game: SteamGame) -> RuntimeJob? {
        if let job = runtimeJobs[game.id] { return job }
        let bottle = game.bottleID ?? game.id
        return runtimeJobs.first { id, _ in games.first { $0.id == id }.map { ($0.bottleID ?? $0.id) == bottle } ?? false }?.value
    }

    /// Why this runtime cannot install for this program now because it installs for another one, or
    /// nil. One install of a runtime at a time: all of them use one checked download.
    func runtimeBusy(_ id: RuntimeID, for game: SteamGame) -> String? {
        guard let other = runtimeJobs.first(where: { $0.key != game.id && $0.value.runtime == id }) else { return nil }
        let name = games.first { $0.id == other.key }?.name ?? "another app"
        return "\(WindowsRuntime.pinned(id).title) is installing for \(name) now. Install it here when that is done."
    }

    /// Why a runtime cannot go into this program's bottle now, or nil when it can.
    func runtimeBlocker(_ game: SteamGame) -> String? {
        if engine == nil { return "Unwine's engine is not set up yet." }
        if runtimeJob(inBottleOf: game) != nil { return Self.runtimeInstallingReason }
        if localStarting[game.id] != nil || localRunning.contains(game.id) {
            return "Quit \(game.name) first. A runtime goes into its Windows bottle while the bottle is closed."
        }
        if bottleToolStarting[game.id] != nil { return "A program is starting in this bottle. Wait a moment." }
        if LocalGames.isRunning(game) { return "Something still runs in this Windows bottle. Quit it first." }
        return nil
    }

    /// Downloads Microsoft's installer, checks it and runs it in the program's bottle. Makes the
    /// bottle first when the program never ran. The page shows each step while it works.
    func installRuntime(_ id: RuntimeID, for game: SteamGame) async {
        if let why = runtimeBlocker(game) ?? runtimeBusy(id, for: game) { banner = why; return }
        guard let engine else { return }
        let runtime = WindowsRuntime.pinned(id)
        guard runtime.works else { banner = "\(runtime.title) does not work in Wine yet, so Unwine does not install it."; return }
        runtimeJobs[game.id] = RuntimeJob(runtime: id, phase: .downloading(nil), bottleStep: "Getting the app's Windows bottle ready…")
        defer { runtimeJobs[game.id] = nil }
        let log = localLog(game.id)
        // A launcher's bottle is its game's: the program with the settings is the one to follow.
        let source = settingsSource(for: game).flatMap { s in games.first { $0.id == s.id } } ?? game
        writeProfile(for: source.id)
        let profile = Profiles.file(for: source.id)
        do {
            try await LocalGames.ensureBottle(game, engine: engine, profile: profile, log: log, isApp: isApp(game),
                                              template: { [weak self] in await self?.bottleTemplate() },
                                              phase: { [weak self] words in self?.runtimeJobs[game.id]?.bottleStep = words })
            runtimeJobs[game.id]?.bottleStep = nil
            let pfx = LocalGames.prefix(game)
            let env = LocalGames.withoutX87(LocalGames.environment(engine: engine, prefix: pfx, profile: profile))
            try await RuntimeInstaller.install(runtime, prefix: pfx, engine: engine, env: env, log: log) { [weak self] phase in
                Task { @MainActor in if self?.runtimeJobs[game.id] != nil { self?.runtimeJobs[game.id]?.phase = phase } }
            }
            show("\(runtime.title) is in the Windows bottle of \(game.name) now. Press \(startWord(game)) to start it.", .success)
        } catch {
            log.line("\(runtime.title) did not install: \(error)")
            show("\(runtime.title) did not install: \(error.localizedDescription) Press Install to try again.", .problem,
                 action: .init("Show log") { [weak self] in self?.showLogs(of: game) })
        }
        // Programs that share the bottle have the runtime now too.
        await recheckRuntimes(ofBottle: game)
        // The installer's bottle closes: the page shows Open again at once, not Quit app.
        await refreshSteam()
    }
}
