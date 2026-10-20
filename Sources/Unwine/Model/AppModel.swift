import AppKit
import Foundation

/// Everything Unwine remembers between launches. Every field decodes with a default,
/// so adding fields in a later Unwine never throws away the user's settings.
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
    var pendingEngine: String?          // a newer engine this Unwine cannot bridge yet
    var stagedEngine: String?           // installed and waiting for games to close
    var onlineEngine: String?           // engine folder Online mode's bottle was last set up with
    var onlineReopenMacSteam = false    // Unwine closed Mac Steam for Online mode and owes it a reopen
    var onlineEnvHash: String?          // the settings Windows Steam last started with; its games inherit them
    var onlineEnv: [String: String]?    // those settings, to name what changed when a game needs others
    var onlineGameMode = false          // experimental: macOS Game Mode for the games Windows Steam starts
    var onlineHighResolution = false    // CrossOver's High Resolution Mode for the Windows Steam bottle
    var onlineFillScreen = false        // games in Windows Steam take the whole display (no Dock over them)
    var presetChoice: [Int: String] = [:]   // the preset last clicked per game, to break ties
    var localGames: [LocalGameRecord] = []  // Windows games the user added by their .exe

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
        onlineEngine = try? c.decodeIfPresent(String.self, forKey: .onlineEngine)
        onlineReopenMacSteam = (try? c.decodeIfPresent(Bool.self, forKey: .onlineReopenMacSteam)) ?? false
        onlineEnvHash = try? c.decodeIfPresent(String.self, forKey: .onlineEnvHash)
        onlineEnv = try? c.decodeIfPresent([String: String].self, forKey: .onlineEnv)
        onlineGameMode = (try? c.decodeIfPresent(Bool.self, forKey: .onlineGameMode)) ?? false
        onlineHighResolution = (try? c.decodeIfPresent(Bool.self, forKey: .onlineHighResolution)) ?? false
        onlineFillScreen = (try? c.decodeIfPresent(Bool.self, forKey: .onlineFillScreen)) ?? false
        presetChoice = (try? c.decodeIfPresent([Int: String].self, forKey: .presetChoice)) ?? [:]
        localGames = (try? c.decodeIfPresent([LocalGameRecord].self, forKey: .localGames)) ?? []
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
        case .runner: return "Build Unwine's Steam tool"
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
        case .steam: return "Checks that Steam lists Unwine as a compatibility tool."
        }
    }
}

/// Online mode: Windows Steam inside Unwine's engine, for games whose VAC needs the Windows client.
/// A game needs settings the running Windows Steam did not start with: restart it, or play as it is.
struct OnlineRestartAsk: Identifiable {
    let game: SteamGame
    let changes: [String]
    var id: Int { game.id }
}

struct OnlineStatus: Equatable, Sendable {
    var installed = false
    var installing = false              // Unwine's own setup runs Windows Steam's updater
    var running = false                 // the Windows Steam client itself
    var inUse = false                   // anything alive in its bottle: Steam, a game or a helper
    var signedIn = false

    static func read() -> OnlineStatus {
        OnlineStatus(installed: OnlineSteam.isInstalled, installing: OnlineSteam.isInstalling, running: OnlineSteam.isRunning,
                     inUse: OnlineSteam.isInUse, signedIn: OnlineSteam.isSignedIn)
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
    var online: OnlineStatus

    static func read() -> SteamSnapshot {
        let mappings = MacSteam.compatMappings()
        let mapped = Set(mappings.filter { $0.value == Runner.toolName }.keys)
        return SteamSnapshot(installed: MacSteam.isInstalled, running: MacSteam.isRunning, play: MacSteam.steamPlayState(),
                             version: MacSteam.clientVersion(), mappings: mappings,
                             games: SteamLibrary.scan(unwineMapped: mapped), runnerInUse: Runner.isInUse(),
                             online: OnlineStatus.read())
    }
}

/// The two one-click setting sets the advisor offers for each game.
enum Preset: String, CaseIterable, Identifiable {
    case speed, battery
    var id: String { rawValue }
    var title: String { self == .speed ? "Best speed" : "Best battery" }
    var icon: String { self == .speed ? "bolt.fill" : "leaf.fill" }
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
    var gameRunning = false             // any game or helper running through Unwine
    var busyGame: Int?                  // a game whose Steam setting is being changed
    var localRunning = Set<Int>()       // added games whose bottle is running
    var localStarting: [Int: String] = [:]  // added games starting now, with the step for the waiting screen
    var banner: String?                 // short notice shown at the top

    // Advice and Online mode
    var highballLoads = 0               // bumps when the Highball list loads, so advice redraws
    var online = OnlineStatus()
    var onlineStep: StepStatus = .pending
    var onlineWords: [String]?          // phase words while Unwine opens, restarts or closes Windows Steam
    var onlineRestartAsk: OnlineRestartAsk?   // a game needs settings Windows Steam did not start with
    var onlineForceQuit: [String]?      // games still running when the user asked to quit Windows Steam
    var onlineClosing = false           // Windows Steam is closing (it syncs Steam Cloud saves first)
    private var onlineStartedAt = Date.distantPast
    private var onlineGoneTicks = 0
    private var tickCount = 0
    private var fontsChecked = Set<String>()    // bottles already given the font stand-ins this run
    private var lastHighballCheck = Date()
    private var runnerNeedsRefresh = false  // the runner is from an older Unwine and was in use at launch

    /// Switching between Mac Steam and Windows Steam.
    var onlineBusy: Bool { onlineWords != nil }
    /// Mac Steam must stay closed while Windows Steam runs: two clients on one account sign each
    /// other out and write the same game files.
    var macSteamBlocked: Bool { online.running || onlineBusy }
    var willReopenMacSteam: Bool { stored.onlineReopenMacSteam }
    static let macSteamBlockedReason = "Windows Steam is open. Quit it first."

    // Updates
    var updateNote: String?
    var isCheckingUpdates = false
    let appUpdater = AppUpdater()

    var stored = StoredState()
    let log = LogFile("unwine.log")
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
        if LegacyFolder.renameAppIfNeeded() { return }
        load()
        EngineStore.cleanStaging()
        Runner.pruneOldRunners()
        let engines = EngineStore.installed()
        engine = engines.first { $0.folder == stored.activeEngine } ?? engines.first
        d3dmetal = D3DMetalStore.installed().first
        if let engine { RendererPatches.prepare(engine: engine, log: log) }
        OnlineSteam.gameModeForGames = stored.onlineGameMode
        OnlineSteam.highResolution = stored.onlineHighResolution
        OnlineSteam.fillScreen = stored.onlineFillScreen
        if let engine {
            if Runner.matches(engine) {
                runnerReady = true
            } else if Runner.isBuilt, Runner.record()?.engineFolder == engine.folder {
                // Same engine, older wrapper format: rewrite the small generated files. The old
                // wrappers keep working, so a game running right now just delays the rewrite.
                if Runner.isInUse() {
                    runnerReady = true
                    runnerNeedsRefresh = true
                } else {
                    runnerReady = (try? Runner.refresh(engine: engine, d3dmetal: d3dmetal)) != nil
                }
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
        Task { await refreshHighball() }
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

    /// Developer switches for unattended testing: `--import-gptk <dmg>`, `--run-setup`, `--install-update`,
    /// `--play-exe <path>` (adds that .exe as a game if needed and starts it).
    private func runTestSwitches() {
        let args = CommandLine.arguments
        var gptk: URL?
        if let i = args.firstIndex(of: "--import-gptk"), i + 1 < args.count { gptk = URL(fileURLWithPath: args[i + 1]) }
        var exe: URL?
        if let i = args.firstIndex(of: "--play-exe"), i + 1 < args.count { exe = URL(fileURLWithPath: args[i + 1]) }
        guard args.contains("--run-setup") || args.contains("--install-update") || gptk != nil || exe != nil else { return }
        Task {
            if let exe {
                if !stored.localGames.contains(where: { $0.exePath == exe.path }) { addLocalGame(exe: exe) }
                if let record = stored.localGames.first(where: { $0.exePath == exe.path }) {
                    await analyze(LocalGames.game(from: record))
                    await playLocal(LocalGames.game(from: record))
                }
            }
            if let gptk { await importGPTK(gptk) }
            if args.contains("--run-setup") && !showsLibrary { await runSetup() }
            if args.contains("--install-update") {
                await appUpdater.checkAndStage()
                if case .readyToInstall = appUpdater.status { appUpdater.installAndRelaunch() }
            }
        }
    }

    /// Runs every few seconds: refresh Steam, finish work that waited for games to close.
    /// While a game runs, Unwine looks only every third tick, so it takes less from the game.
    private func tick() async {
        tickCount += 1
        if (gameRunning || online.inUse) && !onlineBusy && tickCount % 3 != 0 { return }
        await refreshSteam()
        if Date().timeIntervalSince(lastHighballCheck) > 600 {
            lastHighballCheck = Date()
            Task { await refreshHighball() }
        }
        if !gameRunning {
            if runnerNeedsRefresh, let engine, !Runner.isInUse() {
                runnerNeedsRefresh = (try? Runner.refresh(engine: engine, d3dmetal: d3dmetal)) == nil
            }
            flushProfiles()
            addBottleFonts()
            // Windows Steam runs on the engine too, so an engine switch waits for it as well.
            if stored.stagedEngine != nil, !isCheckingUpdates, !online.inUse, !onlineStep.isRunning { await activateStagedEngine() }
        }
        if !stored.setupComplete, !isSettingUp, steps[.runner]?.isDone == true, steps[.steam]?.isDone != true {
            checkSteamConnection()
        }
    }

    /// Fetches the Highball list when the copy on disk is stale. Redraws only when it changed.
    private func refreshHighball() async {
        guard await HighballDB.refreshIfStale(log: log) else { return }
        highballLoads += 1
        if showsLibrary { writeAllProfiles() }     // "Automatic" may now follow a tested layer
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
        games = snap.games + stored.localGames.map(LocalGames.game(from:))
        localRunning = Set(games.filter { $0.localExe != nil && LocalGames.isRunning($0) }.map(\.id))
        gameRunning = snap.runnerInUse
        online = snap.online
        // A closed bottle has no settings left to compare with, so the next start sets them fresh.
        if !online.inUse, stored.onlineEnvHash != nil, !onlineBusy { stored.onlineEnvHash = nil; stored.onlineEnv = nil; save() }
        reopenMacSteamIfOnlineEnded()
    }

    /// Brings Mac Steam back once Windows Steam is gone. Waits three reads in a row,
    /// because Windows Steam restarts itself when it updates.
    /// The promise survives an Unwine restart: it is saved with the rest of Unwine's state.
    private func reopenMacSteamIfOnlineEnded() {
        guard stored.onlineReopenMacSteam, !onlineBusy else { onlineGoneTicks = 0; return }
        if steamRunning && !online.running { setReopenMacSteam(false); return }   // already open again
        guard !online.running, !online.installing, Date().timeIntervalSince(onlineStartedAt) > 20 else { onlineGoneTicks = 0; return }
        onlineGoneTicks += 1
        guard onlineGoneTicks >= 3 else { return }
        onlineGoneTicks = 0
        setReopenMacSteam(false)
        if !MacSteam.isRunning { MacSteam.start() }
    }

    private func setReopenMacSteam(_ on: Bool) {
        guard stored.onlineReopenMacSteam != on else { return }
        stored.onlineReopenMacSteam = on
        save()
    }

    // MARK: Opening Mac Steam

    /// Every way Unwine opens Mac Steam goes through here, so none of them can open it while
    /// Windows Steam runs.
    private func macSteamAllowed() -> Bool {
        guard !macSteamBlocked else { banner = Self.macSteamBlockedReason + " Mac Steam comes back after that."; return false }
        return true
    }

    func openMacSteam() { if macSteamAllowed() { MacSteam.start() } }
    func showInSteam(_ id: Int) { if macSteamAllowed() { MacSteam.showInSteam(id) } }
    func openStore() { if macSteamAllowed() { MacSteam.openStore() } }

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
        guard isArm == 1 else { steps[.mac] = .failed("Unwine needs an Apple Silicon Mac (M1 or newer)."); return false }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            steps[.mac] = .failed("Unwine needs macOS 15 Sequoia or newer."); return false
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
        RendererPatches.prepare(engine: engine, log: log)
        if Runner.matches(engine) {
            try? Runner.refresh(engine: engine, d3dmetal: d3dmetal)
            runnerReady = true
            writeAllProfiles()
            steps[.runner] = .done("Ready")
            return true
        }
        if Runner.isInUse() {
            steps[.runner] = .needsUser("A game is running through Unwine. Close it, then continue setup.")
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
            steps[.steam] = .done("Steam lists Unwine")
            if isReady && steps[.mac]?.isDone == true && steps[.runner]?.isDone == true {
                stored.setupComplete = true
                save()
            }
        case .outdated:
            steps[.steam] = .needsUser("Steam updated, and Steam Play does not match it yet.")
        case .off:
            steps[.steam] = .needsUser(steamRunning
                ? "Steam does not list Unwine yet. Restart Steam after Steam Play is on."
                : "Open Steam. Unwine checks again by itself.")
        }
    }

    /// Restarts Steam, but never while a game runs (Steam's quit would close the game).
    func restartSteam() async {
        guard !gameRunning else { banner = "A game is running. Close it first, then restart Steam."; return }
        guard macSteamAllowed() else { return }
        guard await MacSteam.quit() else { banner = "Steam did not close. Close it yourself, then open it again."; return }
        MacSteam.start()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await refreshSteam()
        if !stored.setupComplete { checkSteamConnection() }
    }

    // MARK: GPTK 4

    func importGPTK(_ url: URL) async {
        // One at a time: a second click while one runs would open Apple's file twice.
        guard steps[.gptk]?.isRunning != true else { return }
        steps[.gptk] = .running(nil, ["Opening Apple's file…", "Checking Apple's signature…", "Copying D3DMetal…", "Setting up your games…"])
        do {
            let item = try await D3DMetalStore.importToolkit(from: url, log: log)
            d3dmetal = D3DMetalStore.installed().first ?? item
            if let engine, runnerReady {
                try Runner.refresh(engine: engine, d3dmetal: d3dmetal)
            }
            writeAllProfiles()
            steps[.gptk] = .done(d3dmetal?.label ?? item.label)
            if showsLibrary { banner = "\(d3dmetal?.label ?? item.label) is added. DirectX 12 games use it the next time they start." }
        } catch {
            fail(.gptk, error)
        }
    }

    /// Returns true when a toolkit file was found and imported.
    @discardableResult
    func findGPTKInDownloads() async -> Bool {
        guard steps[.gptk]?.isRunning != true else { return false }
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
        // A newer analyzer reads games better, so its results replace older ones at once.
        if let a = stored.analyses[game.id], a.isCurrent, Date().timeIntervalSince(a.analyzedAt) < 7 * 86_400 { return }
        let dir = game.installDir
        let result = await Task.detached(priority: .utility) { GameAnalyzer.analyze(installDir: dir) }.value
        stored.analyses[game.id] = result
        save()
        writeProfile(for: game.id)
    }

    func resolvedRenderer(for game: SteamGame) -> Renderer { renderer(for: game.id) }

    /// The layer a game really runs on. "Automatic" follows the advice: a layer people
    /// tested in Highball first, then what the game's own files say.
    func renderer(for id: Int) -> Renderer {
        let choice = settings(for: id).renderer
        guard choice == .auto else { return Profiles.resolve(choice, analysis: stored.analyses[id], hasD3DMetal: d3dmetal != nil) }
        let advised = advice(appID: id, name: games.first { $0.id == id }?.name ?? "").renderer
        return advised == .auto ? Profiles.resolve(.auto, analysis: stored.analyses[id], hasD3DMetal: d3dmetal != nil) : advised
    }

    func advice(for game: SteamGame) -> Advice { advice(appID: game.id, name: game.name) }

    private func advice(appID: Int, name: String) -> Advice {
        _ = highballLoads       // read so SwiftUI redraws when the Highball list arrives
        return Advisor.advise(appID: appID, name: name, analysis: stored.analyses[appID],
                              highball: HighballDB.game(appID), hasD3DMetal: d3dmetal != nil,
                              d3dmetalIsV4: d3dmetal?.isVersion4 ?? false, screenPixels: Self.screenPixels)
    }

    private static var screenPixels: CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 3024, height: 1964) }
        return CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
    }

    /// Applies one of the advisor's setting sets. The layer goes back to Automatic (which is the
    /// advised layer), and the Metal overlay stays as the user set it: it is a display choice.
    /// The Metal overlay, Low latency and background shader building stay as the user set them:
    /// they are the user's choices, not speed or battery settings.
    func apply(_ preset: Preset, to game: SteamGame) {
        let now = settings(for: game.id)
        var s = settings(preset, for: game, advice: advice(for: game))
        s.metalHUD = now.metalHUD
        s.lowLatency = now.lowLatency
        s.asyncShaders = now.asyncShaders
        stored.games[game.id] = s
        stored.presetChoice[game.id] = preset.rawValue
        save()
        writeProfile(for: game.id)
    }

    /// Which preset the game's settings match now, if any. Settings that do nothing for this game
    /// (Metal 4 without GPTK 4, a cap Unwine cannot apply, MetalFX the layer cannot use) are left
    /// out of the comparison. When both presets match, the one clicked last wins.
    func activePreset(for game: SteamGame) -> Preset? {
        let a = advice(for: game)
        let api = stored.analyses[game.id]?.api
        let gptk4 = d3dmetal?.isVersion4 == true
        func normal(_ s: GameSettings) -> GameSettings {
            var s = s
            let real = s.renderer == .auto ? a.renderer
                : Profiles.resolve(s.renderer, analysis: stored.analyses[game.id], hasD3DMetal: d3dmetal != nil)
            if s.renderer == a.renderer { s.renderer = .auto }
            s.metalHUD = false
            s.lowLatency = false
            s.asyncShaders = true
            if !(real == .d3dmetal && gptk4) { s.metal4 = true }
            if real == .wined3d || (real == .d3dmetal && !gptk4) || (real == .dxvk && api == .dx12) { s.fpsCap = nil }
            if !((api == .dx11 || api == .dx12) && (real == .d3dmetal || real == .dxmt)) { s.metalFX = false }
            if !(real == .dxmt && (api == .dx10 || api == .dx11)) { s.metalFXSpatial = false }
            if real != .d3dmetal { s.rayTracing = nil }
            return s
        }
        let now = normal(settings(for: game.id))
        let matches = Preset.allCases.filter { now == normal(settings($0, for: game, advice: a)) }
        if matches.count > 1, let last = stored.presetChoice[game.id].flatMap(Preset.init(rawValue:)), matches.contains(last) { return last }
        return matches.first
    }

    /// A preset's full settings for one game: exactly what a click stores.
    func settings(_ preset: Preset, for game: SteamGame, advice a: Advice) -> GameSettings {
        var s = preset == .speed ? a.performance : a.battery
        s.renderer = .auto
        // MetalFX sharpening lets a DirectX 10/11 game draw at half size and still fill the
        // screen sharply. It costs a little GPU time, so only the battery set turns it on.
        s.metalFXSpatial = preset == .battery && canSharpen(game, renderer: a.renderer)
        return s
    }

    /// DXMT's MetalFX sharpening works only for DirectX 10/11 games running on DXMT.
    func canSharpen(_ game: SteamGame, renderer: Renderer? = nil) -> Bool {
        guard let api = stored.analyses[game.id]?.api, api == .dx10 || api == .dx11 else { return false }
        return (renderer ?? self.renderer(for: game.id)) == .dxmt
    }

    /// DXVK's latency sleep works where DXVK draws: every DirectX 8/9 game (DXVK's DirectX 9
    /// layer rides along with DXMT and D3DMetal), and any game on the DXVK layer.
    func canLowerLatency(_ game: SteamGame) -> Bool {
        let r = renderer(for: game.id)
        if r == .dxvk { return true }
        guard let api = stored.analyses[game.id]?.api else { return false }
        return (api == .dx9 || api == .dx8) && r != .wined3d
    }

    /// The background-shader fix lives in DXVK's DirectX 9 layer, so it works where that layer draws.
    func canBuildShadersAsync(_ game: SteamGame) -> Bool {
        guard let api = stored.analyses[game.id]?.api, api == .dx9 || api == .dx8 else { return false }
        return renderer(for: game.id) != .wined3d
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
        if game.localExe != nil { Task { await playLocal(game) }; return }
        guard macSteamAllowed() else { return }
        writeProfile(for: game.id)
        MacSteam.play(game.id)
        // Steam starts the game in the background; bring its window to the front once it shows,
        // so the keyboard and mouse go to the game at once.
        let pfx = game.compatData.appendingPathComponent("pfx")
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let pid = await Task.detached(operation: { Self.windowOwner(prefix: pfx) }).value {
                    self?.bringToFront(pid)
                    return
                }
            }
        }
    }

    /// Sets this game to use Unwine in Steam. Steam must restart for that.
    func useDecant(_ on: Bool, for game: SteamGame) async {
        guard !gameRunning else { banner = "A game is running. Close it first: Steam restarts for this."; return }
        busyGame = game.id
        defer { busyGame = nil }
        let wasRunning = MacSteam.isRunning
        guard await MacSteam.quit() else { banner = "Steam did not close. Close it, then try again."; return }
        do {
            try MacSteam.setCompatTool(on ? Runner.toolName : nil, for: [game.id])
            banner = on ? "\(game.name) now uses Unwine." : "\(game.name) is back to Steam's default."
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
            banner = "Windows bottle for \(game.name) moved to the Trash. \(game.localExe == nil ? "Steam" : "Unwine") builds a fresh one on next Play."
        } catch {
            banner = "Could not move the bottle to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Games added by their .exe

    /// Adds a Windows game or program by its .exe. It shows in the library like a Steam game.
    func addLocalGame(exe: URL, folder: URL? = nil) {
        if let known = stored.localGames.first(where: { $0.exePath == exe.path }) {
            banner = "\(known.name) is already in your library."
            return
        }
        let id = max(LocalGames.idBase, (stored.localGames.map(\.id).max() ?? LocalGames.idBase)) + 1
        // Named after the folder the user picked, else the folder the program sits in.
        let name = folder.map { $0.lastPathComponent.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? LocalGames.suggestedName(for: exe)
        let record = LocalGameRecord(id: id, name: name, exePath: exe.path, addedAt: Date())
        stored.localGames.append(record)
        save()
        let game = LocalGames.game(from: record)
        games.append(game)
        banner = "\(record.name) is in your library. Unwine is reading its files to pick the best settings."
        Task { await analyze(game) }
    }

    /// Takes an added game out of the library. Its files stay where they are; its Windows bottle
    /// (settings and saves the game kept inside it) goes to the Trash.
    func removeLocalGame(_ game: SteamGame) {
        guard game.localExe != nil else { return }
        guard !localRunning.contains(game.id) else { banner = "\(game.name) is running. Quit it first."; return }
        stored.localGames.removeAll { $0.id == game.id }
        stored.games[game.id] = nil
        stored.analyses[game.id] = nil
        stored.presetChoice[game.id] = nil
        save()
        Profiles.remove(appID: game.id)
        if FileManager.default.fileExists(atPath: game.compatData.path) {
            try? FileManager.default.trashItem(at: game.compatData, resultingItemURL: nil)
        }
        games.removeAll { $0.id == game.id }
        banner = "\(game.name) is out of your library. Its files stay in \(game.installDir.path)."
    }

    func renameLocalGame(_ id: Int, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = stored.localGames.firstIndex(where: { $0.id == id }) else { return }
        stored.localGames[i].name = clean
        save()
        if let g = games.firstIndex(where: { $0.id == id }) { games[g] = LocalGames.game(from: stored.localGames[i]) }
    }

    private func playLocal(_ game: SteamGame) async {
        guard let engine else { banner = "Unwine's engine is not set up yet."; return }
        guard localStarting[game.id] == nil else { return }
        if localRunning.contains(game.id) { banner = "\(game.name) is already running."; return }
        localStarting[game.id] = "Getting \(game.name) ready…"
        defer { localStarting[game.id] = nil }
        writeProfile(for: game.id)
        let log = LogFile(LocalGames.logName(game.id))
        do {
            try await LocalGames.start(game, engine: engine, profile: Profiles.file(for: game.id), log: log,
                                       phase: { [weak self] words in self?.localStarting[game.id] = words },
                                       onExit: { status in log.line("The game's process ended with status \(status)") })
            // Wait for the game to show a window, so the waiting screen covers the slow part.
            for _ in 0..<90 {
                if await Task.detached(operation: { LocalGames.isRunning(game) }).value { localRunning.insert(game.id) }
                if let pid = Self.windowOwner(prefix: LocalGames.prefix(game)) { bringToFront(pid); break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            banner = "\(game.name) did not start: \(error.localizedDescription)"
            log.line("start failed: \(error)")
        }
        await refreshSteam()
    }

    func stopLocal(_ game: SteamGame) async {
        guard let engine else { return }
        localStarting[game.id] = "Closing \(game.name)…"
        defer { localStarting[game.id] = nil }
        await LocalGames.stop(game, engine: engine, log: LogFile(LocalGames.logName(game.id)))
        await refreshSteam()
    }

    /// The process of this bottle that shows a real window, once there is one.
    nonisolated private static func windowOwner(prefix: URL) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let path = prefix.path
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, w[kCGWindowLayer as String] as? Int == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) >= 300, (b["Height"] ?? 0) >= 200
            else { continue }
            if processUsesPrefix(pid, path) { return pid }
        }
        return nil
    }

    /// A Wine process carries its bottle in WINEPREFIX.
    nonisolated private static func processUsesPrefix(_ pid: pid_t, _ prefix: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        // The environment strings end with NUL, so the match cannot run into a longer path.
        return String(decoding: buffer.prefix(size), as: UTF8.self).contains("WINEPREFIX=" + prefix + "\u{0}")
    }

    // MARK: Online mode

    /// Installs Windows Steam inside Unwine's engine (a small installer, then Steam updates itself).
    func setUpOnline() async {
        guard let engine, !onlineStep.isRunning, !onlineBusy else { return }
        onlineStep = .running(nil, ["Getting ready…"])
        do {
            try await OnlineSteam.install(engine: engine) { [weak self] phase in
                Task { @MainActor in self?.onlineStep = Self.step(for: phase) }
            }
            stored.onlineEngine = engine.folder
            save()
            onlineStep = .done("Ready")
        } catch {
            onlineStep = .failed(error.localizedDescription)
            log.line("online setup failed: \(error)")
        }
        await refreshSteam()
    }

    private static func step(for phase: OnlineSteam.Phase) -> StepStatus {
        switch phase {
        case .preparing: return .running(nil, ["Making a Windows bottle for Steam…", "Setting up Wine…"])
        case .downloading(let p): return .running(p, ["Downloading Windows Steam…"])
        case .installing: return .running(nil, ["Installing Windows Steam…", "Valve's installer is running"])
        case .updating(let pass): return .running(nil, ["Steam is updating itself (step \(pass) of 2)…",
                                                        "About \(OnlineSteam.approximateDownloadMB) MB from Valve in all", "This takes a few minutes"])
        case .finishing: return .running(nil, ["Finishing…"])
        }
    }

    /// The games Windows Steam may see: Windows builds that need Online mode. Mac versions of
    /// games are never shown to it, so it can never "update" them with Windows files.
    private func onlineGames(adding game: SteamGame?) -> [OnlineSteam.SharedGame] {
        var list = windowsGames.filter { g in
            guard g.isWindowsBuild, g.localExe == nil else { return false }
            if case .needsOnlineMode = advice(for: g).online { return true }
            return false
        }
        if let game, game.isWindowsBuild, !list.contains(where: { $0.id == game.id }) { list.append(game) }
        return list.map { OnlineSteam.SharedGame(appID: $0.id, installDir: $0.installDir, steamapps: $0.steamapps) }
    }

    /// Opens Windows Steam: with a game it starts that game online, without one it shows the
    /// sign-in window. Mac Steam closes first, so the two never write the same game files at once.
    func openOnline(_ game: SteamGame?, restart: Bool? = nil) async {
        guard let engine, online.installed, !onlineBusy, !onlineStep.isRunning else { return }
        guard !Runner.isInUse() else { banner = "A game is running in Mac Steam. Close it first."; return }
        // After an engine update the bottle needs the new engine's files once (no new download).
        // Its progress shows in the Online play section like the first setup.
        if stored.onlineEngine != engine.folder {
            await setUpOnline()
            guard stored.onlineEngine == engine.folder else { return }
        }
        onlineWords = ["Getting Windows Steam ready…"]
        defer { onlineWords = nil }
        // Without a game, Windows Steam opens with the settings for new games, so a game that keeps
        // those settings starts in the same Steam with no restart.
        let profile = Profiles.file(for: game?.id)
        if let game { writeProfile(for: game.id) }
        let hash = OnlineSteam.environmentHash(engine: engine, profile: profile)
        var steamUp = await Task.detached(priority: .userInitiated) { OnlineSteam.isRunning }.value
        // Games inherit Windows Steam's settings. Settings DXVK and DXMT read from a file need no
        // restart; the rest (a different graphics layer, the Metal HUD) do. Unwine asks first, and
        // never restarts under a running game. An unknown start (an older Unwine) counts as the same.
        if steamUp, let last = stored.onlineEnvHash, last != hash, restart == nil, let game {
            let now = OnlineSteam.environment(engine: engine, profile: profile)
            onlineRestartAsk = OnlineRestartAsk(game: game, changes: OnlineSteam.describeChanges(from: stored.onlineEnv ?? [:], to: now))
            return
        }
        if steamUp, let last = stored.onlineEnvHash, last != hash, restart == true {
            onlineWords = ["Restarting Windows Steam with this game's settings…", "Steam Cloud saves sync first"]
            if case .gamesRunning(let names) = await OnlineSteam.shutdown(engine: engine, force: false) {
                banner = "\(names.joined(separator: ", ")) is still running in Windows Steam. Quit it first, then press Play online again."
                return
            }
            steamUp = false
        }
        // Checked again here: a game may have started in Mac Steam while Unwine was busy.
        guard !Runner.isInUse() else { banner = "A game is running in Mac Steam. Close it first."; return }
        if MacSteam.isRunning {
            onlineWords = ["Closing Mac Steam…", "It comes back after Online mode"]
            guard await MacSteam.quit() else { banner = "Mac Steam did not close. Close it, then try again."; return }
            setReopenMacSteam(true)
        }
        do {
            let opens = online.signedIn ? "Your Steam library opens soon" : "The sign-in window opens soon"
            onlineWords = game == nil ? ["Starting Windows Steam…", "Steam checks for its own updates…", "Loading Steam's window…",
                                         "Windows programs start slowly on a Mac", opens]
                                      : ["Starting Windows Steam…", "Steam checks for its own updates…", "Starting \(game!.name)…",
                                         "VAC checks the game", "The game window opens soon"]
            if !steamUp {
                await OnlineSteam.applyDisplaySettings(engine: engine)
                try OnlineSteam.shareGames(onlineGames(adding: game))
            }
            try OnlineSteam.start(engine: engine, profile: profile, appID: game?.id, silent: online.signedIn && game != nil)
            if !steamUp {
                stored.onlineEnvHash = hash
                stored.onlineEnv = OnlineSteam.environment(engine: engine, profile: profile)
                save()
            }
            onlineStartedAt = Date()
            // Wait until a window shows. Steam runs through Wine and Rosetta, and its window is a
            // built-in web browser, so this takes up to a minute or more. The words keep moving all
            // that time, and a second click cannot start Steam twice.
            var shown = false, stopped = false
            let gameOnly = game != nil
            for second in 0..<240 {
                if let pid = await Task.detached(priority: .userInitiated, operation: { OnlineSteam.windowOwner(gameOnly: gameOnly) }).value {
                    shown = true
                    bringToFront(pid)
                    break
                }
                if second >= 10, !(await Task.detached(priority: .userInitiated, operation: { OnlineSteam.isInUse }).value) { stopped = true; break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let back = willReopenMacSteam ? " Mac Steam comes back by itself." : ""
            if stopped {
                banner = "Windows Steam closed while it started. Try again. If it happens again, the log in Settings says why."
                log.line("online start: Windows Steam quit before it showed a window")
            } else if !shown {
                banner = "Windows Steam is still starting. Its window shows soon."
            } else {
                banner = game.map { "\($0.name) is starting online in Windows Steam. Quit Windows Steam when you finish.\(back)" }
                    ?? (online.signedIn ? "Windows Steam is open.\(back)" : "Windows Steam is open. Sign in once and tick \u{201C}Remember me\u{201D}.")
            }
        } catch {
            banner = "Windows Steam did not start: \(error.localizedDescription)"
            log.line("online start failed: \(error)")
        }
        await refreshSteam()
    }

    /// Closes Windows Steam (it syncs Steam Cloud saves first), then brings Mac Steam back if
    /// Unwine closed it. A game still running in Windows Steam is never closed without asking.
    func stopOnline(force: Bool = false) async {
        guard let engine, !onlineBusy, !onlineStep.isRunning else { return }
        onlineForceQuit = nil
        onlineWords = force ? ["Asking the game to close…", "Closing Windows Steam…", "Syncing Steam Cloud saves…"]
                            : ["Closing Windows Steam…", "Syncing Steam Cloud saves…", "This can take a minute"]
        onlineClosing = true
        let result = await OnlineSteam.shutdown(engine: engine, force: force)
        onlineClosing = false
        onlineWords = nil
        if case .gamesRunning(let names) = result {
            onlineForceQuit = names
            return
        }
        stored.onlineEnvHash = nil; stored.onlineEnv = nil
        save()
        await refreshSteam()
        if !online.running, stored.onlineReopenMacSteam {
            setReopenMacSteam(false)
            if !MacSteam.isRunning { MacSteam.start() }
        }
    }

    /// Gives every closed Windows bottle the font stand-ins (see BottleFonts), once per run.
    private func addBottleFonts() {
        var prefixes = games.filter(\.isWindowsBuild).map { $0.compatData.appendingPathComponent("pfx") }
        if online.installed { prefixes.append(OnlineSteam.prefix) }
        for pfx in prefixes where !fontsChecked.contains(pfx.path) {
            guard FileManager.default.fileExists(atPath: pfx.appendingPathComponent("user.reg").path) else { continue }
            guard !OnlineSteam.serverIsAlive(pfx) else { continue }   // try again once it closes
            fontsChecked.insert(pfx.path)
            if BottleFonts.ensure(prefix: pfx) { log.line("Added font stand-ins to \(pfx.deletingLastPathComponent().lastPathComponent)") }
        }
    }

    /// Closes Windows Steam now instead of waiting for Steam Cloud to finish syncing.
    func hurryOnlineQuit() {
        guard onlineClosing else { return }
        onlineWords = ["Closing Windows Steam now…"]
        OnlineSteam.hurryShutdown()
    }

    /// Brings a game's window to the front, so the keyboard and mouse go to it at once. A Windows
    /// game started in the background otherwise shows its window without getting the keyboard.
    func bringToFront(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: NSRunningApplication.current, options: [])
    }

    func removeOnline() {
        guard !online.inUse, !onlineBusy, !onlineStep.isRunning else { banner = "Quit Windows Steam and its game first."; return }
        do {
            try OnlineSteam.remove()
            stored.onlineEngine = nil
            stored.onlineEnvHash = nil; stored.onlineEnv = nil
            save()
            onlineStep = .pending
            banner = "Online mode moved to the Trash. Your games stay in Mac Steam."
        } catch {
            banner = "Could not remove Online mode: \(error.localizedDescription)"
        }
        Task { await refreshSteam() }
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
        let r = renderer(for: id)
        let dir = games.first { $0.id == id }?.installDir
        do { try Profiles.write(appID: id, settings: s, renderer: r, engine: engine, d3dmetal: d3dmetal, gameDir: dir) }
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

    /// Engine, Steam Play files and Unwine itself. Nothing is swapped while a game runs.
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
                notes.append("Steam updated past Steam Play's add-on. A newer add-on comes from NotProton's project; Unwine cannot put it into Steam.app.")
            }
        } catch {
            failures += 1
            notes.append("Steam Play check failed: \(error.localizedDescription)")
        }

        // 2. Engine: install side by side; switch only when no game runs and this Unwine can bridge it.
        do {
            if let candidate = try await EngineFeed.newest(), candidate.key != engine?.release.key,
               candidate.id != stored.pendingEngine, stored.stagedEngine == nil {
                let next = try await EngineStore.install(candidate, log: log) { _ in }
                if NtdllPatcher.supports(wineLib: next.wineDir.appendingPathComponent("lib/wine")) {
                    stored.stagedEngine = next.folder
                    save()
                    if gameRunning || OnlineSteam.isInUse {
                        notes.append("New engine \(next.wineVersion) is ready. Unwine switches to it after your game and Windows Steam close.")
                    } else {
                        await activateStagedEngine()
                        notes.append(updateNote ?? "")
                    }
                } else {
                    try? FileManager.default.removeItem(at: next.root)
                    stored.pendingEngine = candidate.id
                    notes.append("New engine \(candidate.id) needs a newer Unwine. Your current engine keeps working.")
                }
            }
        } catch {
            failures += 1
            notes.append("Engine check failed: \(error.localizedDescription)")
        }

        // 3. Unwine itself (only when an update source is set up).
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
        // Online mode's bottle runs on the engine itself, so it must be closed as well.
        guard !Runner.isInUse(), !OnlineSteam.isInUse, localRunning.isEmpty else { return }
        do {
            RendererPatches.prepare(engine: next, log: log)
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
        if let s = try? JSONDecoder.unwine.decode(StoredState.self, from: data) {
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
        if let data = try? JSONEncoder.unwine.encode(stored) { try? data.write(to: Self.storeURL, options: .atomic) }
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
