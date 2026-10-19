import AppKit
import Foundation

/// Everything Decant remembers between launches. Every field decodes with a default,
/// so adding fields in a later Decant never throws away the user's settings.
struct StoredState: Codable {
    var games: [Int: GameSettings] = [:]
    var analyses: [Int: GameAnalysis] = [:]
    var defaults = GameSettings()
    var autoUpdate = true
    var setupComplete = false
    var activeEngine: String?           // engine folder the runner is built from
    var previousEngine: String?         // kept one update back, for rollback
    var lastUpdateCheck: Date?
    var kitVersion: String?
    var pendingEngine: String?          // a newer engine this Decant cannot bridge yet
    var stagedEngine: String?           // installed and waiting for games to close

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = (try? c.decodeIfPresent([Int: GameSettings].self, forKey: .games)) ?? [:]
        analyses = (try? c.decodeIfPresent([Int: GameAnalysis].self, forKey: .analyses)) ?? [:]
        defaults = (try? c.decodeIfPresent(GameSettings.self, forKey: .defaults)) ?? GameSettings()
        autoUpdate = (try? c.decodeIfPresent(Bool.self, forKey: .autoUpdate)) ?? true
        setupComplete = (try? c.decodeIfPresent(Bool.self, forKey: .setupComplete)) ?? false
        activeEngine = try? c.decodeIfPresent(String.self, forKey: .activeEngine)
        previousEngine = try? c.decodeIfPresent(String.self, forKey: .previousEngine)
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        kitVersion = try? c.decodeIfPresent(String.self, forKey: .kitVersion)
        pendingEngine = try? c.decodeIfPresent(String.self, forKey: .pendingEngine)
        stagedEngine = try? c.decodeIfPresent(String.self, forKey: .stagedEngine)
    }
}

enum StepStatus: Equatable {
    case pending
    case running(Double?, [String])     // progress (nil = unknown) and rotating phase words
    case done(String)
    case needsUser(String)
    case failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    var isRunning: Bool { if case .running = self { return true }; return false }
}

enum SetupStep: String, CaseIterable, Identifiable {
    case mac, engine, steamPlayKit, runner, gptk, steam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mac: return "Check this Mac"
        case .engine: return "Get the free engine"
        case .steamPlayKit: return "Get the Steam bridge"
        case .runner: return "Build Decant's Steam tool"
        case .gptk: return "Add GPTK 4 (optional)"
        case .steam: return "Connect to your Mac Steam"
        }
    }

    var blurb: String {
        switch self {
        case .mac: return "Apple Silicon, Rosetta and Steam."
        case .engine: return "Wine 11 by Gcenx (Sikarugir), with DXMT, DXVK and KosmicKrisp. About 260 MB."
        case .steamPlayKit: return "Lets Windows games talk to your Mac Steam. NotProton's open parts plus Valve's files. About 175 MB."
        case .runner: return "Puts the engine where Steam Play can use it."
        case .gptk: return "Apple's D3DMetal for DirectX 12 games. You download it from Apple with your Apple ID."
        case .steam: return "Checks that Steam lists Decant as a compatibility tool."
        }
    }
}

/// One background read of Steam's state, applied on the main actor in one go.
private struct SteamSnapshot: Sendable {
    var installed: Bool
    var running: Bool
    var play: MacSteam.SteamPlayState
    var version: String?
    var mappings: [Int: String]
    var games: [SteamGame]
    var runnerInUse: Bool

    static func read() -> SteamSnapshot {
        let mappings = MacSteam.compatMappings()
        let mapped = Set(mappings.filter { $0.value == Runner.toolName }.keys)
        return SteamSnapshot(installed: MacSteam.isInstalled, running: MacSteam.isRunning, play: MacSteam.steamPlayState(),
                             version: MacSteam.clientVersion(), mappings: mappings,
                             games: SteamLibrary.scan(decantMapped: mapped), runnerInUse: Runner.isInUse())
    }
}

@MainActor
@Observable
final class AppModel {
    // Setup
    var steps: [SetupStep: StepStatus] = Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, .pending) })
    var isSettingUp = false
    var gptkSkipped = false

    // Installed parts
    var engine: InstalledEngine?
    var d3dmetal: D3DMetalInstall?
    var runnerReady = false

    // Steam
    var steamInstalled = MacSteam.isInstalled
    var steamRunning = false
    var steamPlay: MacSteam.SteamPlayState = .off
    var steamVersion: String?
    var games: [SteamGame] = []
    var mappings: [Int: String] = [:]
    var gameRunning = false             // any game or helper running through Decant
    var busyGame: Int?                  // a game whose Steam setting is being changed
    var banner: String?                 // short notice shown at the top

    // Updates
    var updateNote: String?
    var isCheckingUpdates = false
    let appUpdater = AppUpdater()

    var stored = StoredState()
    let log = LogFile("decant.log")
    private var started = false
    private var refreshing = false
    private var pendingProfiles = Set<Int?>()

    static let storeURL = Paths.support.appendingPathComponent("state.json")

    var isReady: Bool { engine != nil && runnerReady }
    var showsLibrary: Bool { stored.setupComplete && isReady }

    var windowsGames: [SteamGame] {
        games.filter { $0.isWindowsBuild || mappings[$0.id] == Runner.toolName }
    }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        load()
        EngineStore.cleanStaging()
        Runner.pruneOldRunners()
        let engines = EngineStore.installed()
        engine = engines.first { $0.folder == stored.activeEngine } ?? engines.first
        d3dmetal = D3DMetalStore.installed().first
        if let engine {
            if Runner.matches(engine) {
                runnerReady = true
            } else if Runner.isBuilt, Runner.record()?.engineFolder == engine.folder, !Runner.isInUse() {
                // Same engine, older wrapper format: rewrite the small generated files.
                runnerReady = (try? Runner.refresh(engine: engine, d3dmetal: d3dmetal)) != nil
            }
        }
        if showsLibrary {
            for step in SetupStep.allCases { steps[step] = .done("Ready") }
            if d3dmetal == nil { steps[.gptk] = .needsUser("Not added yet. DirectX 12 games need it.") }
            writeAllProfiles()
        } else if stored.setupComplete {
            stored.setupComplete = false     // parts went missing; setup repairs them
        }
        Task { await refreshSteam() }
        runTestSwitches()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await self.tick()
            }
        }
        Task { await autoUpdateIfDue() }
    }

    /// Developer switches for unattended testing: `--import-gptk <dmg>` and `--run-setup`.
    private func runTestSwitches() {
        let args = CommandLine.arguments
        var gptk: URL?
        if let i = args.firstIndex(of: "--import-gptk"), i + 1 < args.count { gptk = URL(fileURLWithPath: args[i + 1]) }
        guard args.contains("--run-setup") || gptk != nil else { return }
        Task {
            if let gptk { await importGPTK(gptk) }
            if args.contains("--run-setup") && !showsLibrary { await runSetup() }
        }
    }

    /// Runs every few seconds: refresh Steam, finish work that waited for games to close.
    private func tick() async {
        await refreshSteam()
        if !gameRunning {
            flushProfiles()
            if stored.stagedEngine != nil, !isCheckingUpdates { await activateStagedEngine() }
        }
        if !stored.setupComplete, !isSettingUp, steps[.runner]?.isDone == true, steps[.steam]?.isDone != true {
            checkSteamConnection()
        }
    }

    func refreshSteam() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let snap = await Task.detached(priority: .utility) { SteamSnapshot.read() }.value
        steamInstalled = snap.installed
        steamRunning = snap.running
        steamPlay = snap.play
        steamVersion = snap.version
        mappings = snap.mappings
        games = snap.games
        gameRunning = snap.runnerInUse
    }

    // MARK: Setup

    func runSetup() async {
        guard !isSettingUp else { return }
        isSettingUp = true
        defer { isSettingUp = false }
        guard await checkMac() else { return }
        guard await installEngine() else { return }
        guard await installKit() else { return }
        guard await buildRunner() else { return }
        if d3dmetal == nil && !gptkSkipped {
            if steps[.gptk]?.isRunning != true { steps[.gptk] = .needsUser("Get it from Apple, then add the file. You can also skip this.") }
        } else {
            steps[.gptk] = .done(d3dmetal?.label ?? "Skipped. DirectX 12 games use DXVK until you add it.")
        }
        await refreshSteam()
        checkSteamConnection()
    }

    private func fail(_ step: SetupStep, _ error: Error) {
        steps[step] = .failed(error.localizedDescription)
        log.line("\(step.rawValue) failed: \(error)")
    }

    func checkMac() async -> Bool {
        steps[.mac] = .running(nil, ["Looking at your Mac…"])
        var isArm = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.optional.arm64", &isArm, &size, nil, 0)
        guard isArm == 1 else { steps[.mac] = .failed("Decant needs an Apple Silicon Mac (M1 or newer)."); return false }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            steps[.mac] = .failed("Decant needs macOS 15 Sequoia or newer."); return false
        }
        let rosetta = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"], check: false)
        guard rosetta?.status == 0 else { steps[.mac] = .needsUser("Rosetta is missing. Windows games need it."); return false }
        guard MacSteam.isInstalled else { steps[.mac] = .needsUser("Steam is not in Applications."); return false }
        steps[.mac] = .done("Apple Silicon, macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), Rosetta, Steam")
        return true
    }

    /// Opens macOS's own password prompt to install Rosetta.
    func installRosetta() async {
        steps[.mac] = .running(nil, ["Installing Rosetta…", "macOS asks for your password", "This takes a minute"])
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], log: log, check: false)
        _ = await checkMac()
    }

    func installEngine() async -> Bool {
        if let engine {
            steps[.engine] = .done(engine.wineVersion)
            return true
        }
        let words = ["Downloading Wine 11…", "Fetching DXMT and DXVK…", "Grabbing KosmicKrisp…", "Almost there…"]
        steps[.engine] = .running(0, words)
        do {
            let installed = try await EngineStore.install(.pinned, log: log) { step in
                Task { @MainActor in
                    switch step {
                    case .downloading(let p): self.steps[.engine] = .running(p, words)
                    case .unpacking: self.steps[.engine] = .running(nil, ["Unpacking the engine…", "Leaving Apple's files out", "Checking every part"])
                    case .checking: self.steps[.engine] = .running(nil, ["Test-starting Wine…"])
                    }
                }
            }
            engine = installed
            stored.activeEngine = installed.folder
            save()
            steps[.engine] = .done(installed.wineVersion)
            return true
        } catch {
            fail(.engine, error)
            return false
        }
    }

    func installKit() async -> Bool {
        let release = SteamPlayKitRelease.pinned
        let words = ["Downloading the Steam bridge…", "Fetching Valve's Windows Steam files…", "Checking every file"]
        steps[.steamPlayKit] = .running(SteamPlayKit.isDownloaded(release) ? 1 : 0, words)
        do {
            try await SteamPlayKit.download(release, log: log) { p in
                Task { @MainActor in self.steps[.steamPlayKit] = .running(p, words) }
            }
            try SteamPlayKit.stage(release, log: log)
            if LooseVersion(stored.kitVersion ?? "0") < LooseVersion(release.version) { stored.kitVersion = release.version }
            save()
            steps[.steamPlayKit] = .done("NotProton \(release.version) parts, Valve files checked")
            return true
        } catch {
            fail(.steamPlayKit, error)
            return false
        }
    }

    func buildRunner() async -> Bool {
        guard let engine else { return false }
        if Runner.matches(engine) {
            try? Runner.refresh(engine: engine, d3dmetal: d3dmetal)
            runnerReady = true
            writeAllProfiles()
            steps[.runner] = .done("Ready")
            return true
        }
        if Runner.isInUse() {
            steps[.runner] = .needsUser("A game is running through Decant. Close it, then continue setup.")
            return false
        }
        steps[.runner] = .running(nil, ["Copying the engine…", "Patching the Steam bridge into Wine…", "Writing launch settings…"])
        do {
            try await Runner.build(engine: engine, d3dmetal: d3dmetal, log: log)
            runnerReady = true
            writeAllProfiles()
            steps[.runner] = .done("Steam tool ready")
            return true
        } catch {
            fail(.runner, error)
            return false
        }
    }

    func checkSteamConnection() {
        switch steamPlay {
        case .on:
            steps[.steam] = .done("Steam lists Decant")
            if isReady && steps[.mac]?.isDone == true && steps[.runner]?.isDone == true {
                stored.setupComplete = true
                save()
            }
        case .outdated:
            steps[.steam] = .needsUser("Steam updated, and Steam Play does not match it yet.")
        case .off:
            steps[.steam] = .needsUser(steamRunning
                ? "Steam does not list Decant yet. Restart Steam after Steam Play is on."
                : "Open Steam. Decant checks again by itself.")
        }
    }

    /// Restarts Steam, but never while a game runs (Steam's quit would close the game).
    func restartSteam() async {
        guard !gameRunning else { banner = "A game is running. Close it first, then restart Steam."; return }
        guard await MacSteam.quit() else { banner = "Steam did not close. Close it yourself, then open it again."; return }
        MacSteam.start()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await refreshSteam()
        if !stored.setupComplete { checkSteamConnection() }
    }

    // MARK: GPTK 4

    func importGPTK(_ url: URL) async {
        steps[.gptk] = .running(nil, ["Opening Apple's file…", "Checking Apple's signature…", "Copying D3DMetal…"])
        do {
            let item = try await D3DMetalStore.importToolkit(from: url, log: log)
            d3dmetal = D3DMetalStore.installed().first ?? item
            if let engine, runnerReady {
                try Runner.refresh(engine: engine, d3dmetal: d3dmetal)
            }
            writeAllProfiles()
            steps[.gptk] = .done(d3dmetal?.label ?? item.label)
        } catch {
            fail(.gptk, error)
        }
    }

    /// Returns true when a toolkit file was found and imported.
    @discardableResult
    func findGPTKInDownloads() async -> Bool {
        guard let dmg = D3DMetalStore.findInDownloads().first else {
            steps[.gptk] = .needsUser("No Game Porting Toolkit file in Downloads yet. Get it from Apple first.")
            return false
        }
        await importGPTK(dmg)
        return steps[.gptk]?.isDone == true
    }

    func skipGPTK() {
        gptkSkipped = true
        steps[.gptk] = .done("Skipped. DirectX 12 games use DXVK until you add it.")
    }

    // MARK: Games

    func settings(for id: Int) -> GameSettings { stored.games[id] ?? stored.defaults }

    func analysis(for game: SteamGame) -> GameAnalysis? { stored.analyses[game.id] }

    func analyze(_ game: SteamGame) async {
        guard case .installed = game.state else { return }
        if let a = stored.analyses[game.id], Date().timeIntervalSince(a.analyzedAt) < 7 * 86_400 { return }
        let dir = game.installDir
        let result = await Task.detached(priority: .utility) { GameAnalyzer.analyze(installDir: dir) }.value
        stored.analyses[game.id] = result
        save()
        writeProfile(for: game.id)
    }

    func resolvedRenderer(for game: SteamGame) -> Renderer {
        Profiles.resolve(settings(for: game.id).renderer, analysis: stored.analyses[game.id], hasD3DMetal: d3dmetal != nil)
    }

    func update(_ id: Int, _ change: (inout GameSettings) -> Void) {
        var s = settings(for: id)
        change(&s)
        stored.games[id] = s
        save()
        writeProfile(for: id)
    }

    func resetSettings(_ id: Int) {
        stored.games[id] = nil
        save()
        writeProfile(for: id)
    }

    func play(_ game: SteamGame) {
        writeProfile(for: game.id)
        MacSteam.play(game.id)
    }

    /// Sets this game to use Decant in Steam. Steam must restart for that.
    func useDecant(_ on: Bool, for game: SteamGame) async {
        guard !gameRunning else { banner = "A game is running. Close it first: Steam restarts for this."; return }
        busyGame = game.id
        defer { busyGame = nil }
        let wasRunning = MacSteam.isRunning
        guard await MacSteam.quit() else { banner = "Steam did not close. Close it, then try again."; return }
        do {
            try MacSteam.setCompatTool(on ? Runner.toolName : nil, for: [game.id])
            banner = on ? "\(game.name) now uses Decant." : "\(game.name) is back to Steam's default."
        } catch {
            banner = error.localizedDescription
        }
        if wasRunning { MacSteam.start() }
        await refreshSteam()
    }

    /// Moves this game's Windows bottle to the Trash (not the game, not its Steam Cloud saves).
    func resetBottle(_ game: SteamGame) {
        let pfx = game.compatData.appendingPathComponent("pfx")
        guard !Runner.isPrefixRunning(pfx) else { banner = "\(game.name) is running. Quit the game first."; return }
        guard FileManager.default.fileExists(atPath: pfx.path) else { banner = "\(game.name) has no Windows bottle yet."; return }
        do {
            try FileManager.default.trashItem(at: pfx, resultingItemURL: nil)
            for marker in ["notproton-build", "notproton-game-drive", "notproton-hidden-controllers"] {
                try? FileManager.default.removeItem(at: game.compatData.appendingPathComponent(marker))
            }
            banner = "Windows bottle for \(game.name) moved to the Trash. Steam builds a fresh one on next Play."
        } catch {
            banner = "Could not move the bottle to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Profiles

    /// Writes a game's profile now, or later if that game is running (a running bottle
    /// must keep one sync mode, or Wine stops new processes).
    func writeProfile(for id: Int) {
        guard let engine else { return }
        if let game = games.first(where: { $0.id == id }), Runner.isPrefixRunning(game.compatData.appendingPathComponent("pfx")) {
            pendingProfiles.insert(id)
            return
        }
        let s = settings(for: id)
        let r = Profiles.resolve(s.renderer, analysis: stored.analyses[id], hasD3DMetal: d3dmetal != nil)
        do { try Profiles.write(appID: id, settings: s, renderer: r, engine: engine, d3dmetal: d3dmetal) }
        catch { log.line("profile \(id) failed: \(error)") }
    }

    func writeAllProfiles() {
        guard let engine else { return }
        if gameRunning {
            pendingProfiles.insert(nil)
        } else {
            let r = Profiles.resolve(stored.defaults.renderer, analysis: nil, hasD3DMetal: d3dmetal != nil)
            try? Profiles.write(appID: nil, settings: stored.defaults, renderer: r, engine: engine, d3dmetal: d3dmetal)
        }
        for id in Set(stored.games.keys).union(stored.analyses.keys) { writeProfile(for: id) }
    }

    private func flushProfiles() {
        guard !pendingProfiles.isEmpty else { return }
        let pending = pendingProfiles
        pendingProfiles.removeAll()
        if pending.contains(nil) { writeAllProfiles() }
        for case let id? in pending { writeProfile(for: id) }
    }

    // MARK: Updates

    func autoUpdateIfDue() async {
        guard stored.autoUpdate, showsLibrary else { return }
        if let last = stored.lastUpdateCheck, Date().timeIntervalSince(last) < 20 * 3600 { return }
        await checkForUpdates()
    }

    /// Engine, Steam Play files and Decant itself. Nothing is swapped while a game runs.
    func checkForUpdates() async {
        guard showsLibrary, !isSettingUp, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        var notes: [String] = []
        var failures = 0

        // 1. Steam Play signature files help the add-on match new Steam builds. Only new files are added.
        do {
            if let latest = try await SteamPlayKit.latestRelease(), LooseVersion(latest.version) > LooseVersion(stored.kitVersion ?? "0") {
                try await SteamPlayKit.download(latest, log: log) { _ in }
                let added = try addNewSignatures(from: latest)
                stored.kitVersion = latest.version
                SteamPlayKit.prune(keep: latest)
                notes.append(added > 0 ? "Steam Play now matches \(added) more Steam version(s)." : "Steam Play files are current.")
            }
            if case .outdated = steamPlay {
                notes.append("Steam updated past Steam Play's add-on. A newer add-on comes from NotProton's project; Decant cannot put it into Steam.app.")
            }
        } catch {
            failures += 1
            notes.append("Steam Play check failed: \(error.localizedDescription)")
        }

        // 2. Engine: install side by side; switch only when no game runs and this Decant can bridge it.
        do {
            if let candidate = try await EngineFeed.newest(), candidate.key != engine?.release.key,
               candidate.id != stored.pendingEngine, stored.stagedEngine == nil {
                let next = try await EngineStore.install(candidate, log: log) { _ in }
                if NtdllPatcher.supports(wineLib: next.wineDir.appendingPathComponent("lib/wine")) {
                    stored.stagedEngine = next.folder
                    save()
                    if gameRunning {
                        notes.append("New engine \(next.wineVersion) is ready. Decant switches to it after your game closes.")
                    } else {
                        await activateStagedEngine()
                        notes.append(updateNote ?? "")
                    }
                } else {
                    try? FileManager.default.removeItem(at: next.root)
                    stored.pendingEngine = candidate.id
                    notes.append("New engine \(candidate.id) needs a newer Decant. Your current engine keeps working.")
                }
            }
        } catch {
            failures += 1
            notes.append("Engine check failed: \(error.localizedDescription)")
        }

        // 3. Decant itself (only when an update source is set up).
        await appUpdater.checkAndStage()
        if case .failed(let why) = appUpdater.status { notes.append(why) }

        if failures == 0 { stored.lastUpdateCheck = Date() }
        save()
        let text = notes.filter { !$0.isEmpty }.joined(separator: " ")
        updateNote = text.isEmpty ? "Everything is up to date." : text
    }

    /// Switches to an engine installed by the updater. Keeps the old one for rollback.
    private func activateStagedEngine() async {
        guard let folder = stored.stagedEngine,
              let next = EngineStore.installed().first(where: { $0.folder == folder }) else { stored.stagedEngine = nil; return }
        guard !Runner.isInUse() else { return }
        do {
            try await Runner.build(engine: next, d3dmetal: d3dmetal, log: log)
            stored.previousEngine = engine?.folder
            stored.activeEngine = next.folder
            stored.stagedEngine = nil
            engine = next
            runnerReady = true
            writeAllProfiles()
            EngineStore.prune(keep: [next.folder, stored.previousEngine].compactMap { $0 })
            save()
            updateNote = "Engine updated to \(next.wineVersion)."
        } catch {
            log.line("engine switch failed: \(error)")
            stored.stagedEngine = nil
            try? FileManager.default.removeItem(at: next.root)
            save()
            updateNote = "Engine update failed and was undone: \(error.localizedDescription)"
        }
    }

    private func addNewSignatures(from release: SteamPlayKitRelease) throws -> Int {
        let src = SteamPlayKit.kitFolder(release).appendingPathComponent("signatures/macos.arm64")
        try Paths.ensure(SteamPlayPaths.signatures)
        var added = 0
        for file in (try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
            let dst = SteamPlayPaths.signatures.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(at: file, to: dst)
                added += 1
            }
        }
        return added
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        if let s = try? JSONDecoder.decant.decode(StoredState.self, from: data) {
            stored = s
        } else {
            // Keep the unreadable file for recovery instead of overwriting it.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(at: Self.storeURL, to: Self.storeURL.appendingPathExtension("unreadable-\(stamp)"))
            log.line("state.json could not be read; kept a copy and started fresh")
        }
    }

    func save() {
        _ = try? Paths.ensure(Paths.support)
        if let data = try? JSONEncoder.decant.encode(stored) { try? data.write(to: Self.storeURL, options: .atomic) }
    }
}

/// Sikarugir's engine feed: the newest engine and the matching runtime template.
enum EngineFeed {
    static func newest() async throws -> EngineRelease? {
        func text(_ url: String) async throws -> String {
            let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1, URL(string: url)!) }
            return String(decoding: data, as: UTF8.self)
        }
        let engineName = try await text("https://raw.githubusercontent.com/Sikarugir-App/Engines/main/EngineList.txt")
            .split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        let template = try await text("https://raw.githubusercontent.com/Sikarugir-App/Template/main/NewestVersion.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engineName, engineName.hasPrefix("WS12WineSikarugir"), template.hasPrefix("Template-") else { return nil }
        if engineName == EngineRelease.pinned.id && template == EngineRelease.pinned.runtimeID { return .pinned }

        let engines = try await GitHub.releases("Sikarugir-App/Engines", limit: 3)
        let templates = try await GitHub.releases("Sikarugir-App/Template", limit: 3)
        guard let e = engines.flatMap(\.assets).first(where: { $0.name == "\(engineName).tar.xz" }),
              let t = templates.flatMap(\.assets).first(where: { $0.name == "\(template).tar.xz" }),
              e.sha256 != nil, t.sha256 != nil else { return nil }
        return EngineRelease(id: engineName, engineURL: e.browser_download_url, engineSHA256: e.sha256, engineSize: e.size,
                             runtimeID: template, runtimeURL: t.browser_download_url, runtimeSHA256: t.sha256, runtimeSize: t.size)
    }
}
