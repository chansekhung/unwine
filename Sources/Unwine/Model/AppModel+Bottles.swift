import AppKit

// Logs, Mac display options and renderer extras (group f). A Steam game's display settings and DLSS
// files go into its closed bottle as soon as they change, so a start from Mac Steam gets them too. An
// added game's bottle gets them in LocalGames.start, because only Unwine starts it.
extension AppModel {
    /// Where a game's display settings stand against its bottle, for the Display section.
    enum DisplayState: Equatable {
        case current        // the bottle holds them (or they are Wine's defaults)
        case writing        // Unwine writes them into the closed bottle now
        case waitingOpen    // the bottle is open: they go in when the game closes
        case waitingNew     // Steam makes the bottle at the game's first start: they go in after it
        case nextStart      // they go in just before the next start
        case failed         // the last write did not take
    }

    /// Steam runs this game through Unwine: mapped to Unwine's tool, or not mapped and run before
    /// (Unwine's tool is the add-on's default). The same test the game page uses.
    func runsThroughUnwine(_ game: SteamGame) -> Bool {
        guard game.localExe == nil, game.isWindowsBuild || mappings[game.id] == Runner.toolName else { return false }
        return mappings[game.id].map { $0 == Runner.toolName } ?? FileManager.default.fileExists(atPath: game.compatData.path)
    }

    /// Writes a Steam game's display settings and DLSS files into its bottle in the background, once
    /// the bottle is closed. Called after each profile write; cheap when nothing changed.
    func prepareBottle(for id: Int) {
        guard let engine, let game = games.first(where: { $0.id == id }), runsThroughUnwine(game) else { return }
        let prefix = game.compatData.appendingPathComponent("pfx", isDirectory: true)
        let profile = Profiles.file(for: id)
        let name = game.name
        let log = self.log
        let previous = bottleTasks[id]
        bottleTasks[id] = Task { [weak self] in
            await previous?.value
            let outcome = await BottlePrep.apply(profile: profile, prefix: prefix, engine: engine, game: name, log: log,
                                                 announce: { _ in self?.bottleWriting.insert(id) })
            guard let self else { return }
            self.bottleWriting.remove(id)
            switch outcome {
            case .done: self.bottleWaiting.remove(id); self.bottleFailed.remove(id)
            case .waiting: self.bottleWaiting.insert(id)
            case .failed: self.bottleWaiting.remove(id); self.bottleFailed.insert(id)
            }
        }
    }

    /// Opens a Steam game in Steam once a bottle write in progress is done: a few seconds, and only
    /// right after a change. NotProton stops every Wine program in the bottle as the game starts, so a
    /// game started during the write would cut it short. `begin` runs just before Steam is asked, and
    /// returns false when the start was called off meanwhile (Stop waiting, Quit game): Steam is not asked.
    func startWhenBottleReady(_ game: SteamGame, begin: @escaping @MainActor () -> Bool = { true }) {
        guard let task = bottleTasks[game.id] else {
            if begin() { MacSteam.play(game.id) }
            return
        }
        bottlePlayQueued.insert(game.id)
        Task { [weak self] in
            await task.value
            self?.bottlePlayQueued.remove(game.id)
            if begin() { MacSteam.play(game.id) }
        }
    }

    /// Called from the refresh loop while no game runs. Tries again for bottles that were open, or not
    /// made yet, when their settings changed (a lock check each). Once after Unwine opens, it also
    /// checks every Steam game's bottle, for changes made while a game ran when Unwine last quit.
    func prepareWaitingBottles() {
        if !bottlesChecked, steamChecked {
            bottlesChecked = true
            for game in windowsGames where runsThroughUnwine(game) { prepareBottle(for: game.id) }
            return
        }
        // Not while Steam starts the game: its bottle closes for a moment between Steam's install
        // scripts and the game, and NotProton would stop the write's Wine run as the game starts.
        for id in bottleWaiting where !bottleWriting.contains(id) && steamStarting[id] == nil {
            guard let game = games.first(where: { $0.id == id }) else { bottleWaiting.remove(id); continue }
            let prefix = game.compatData.appendingPathComponent("pfx", isDirectory: true)
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path),
                  !OnlineSteam.serverIsAlive(prefix) else { continue }
            bottleWaiting.remove(id)    // the write puts it back when the bottle is still not ready
            prepareBottle(for: id)
        }
    }

    /// Compares what the game's settings ask for with what Unwine last wrote into the bottle. Reads
    /// two small files and the bottle's lock, so it is fine to call while the page draws.
    func displayState(for game: SteamGame) -> DisplayState {
        if bottleWriting.contains(game.id) { return .writing }
        // Another tool's bottle never gets them; the page says so above.
        if game.localExe == nil && !runsThroughUnwine(game) { return .current }
        let prefix = game.compatData.appendingPathComponent("pfx", isDirectory: true)
        guard MacDriverValues(settings: settings(for: game.id), appID: game.id).differs(from: prefix) else { return .current }
        if bottleFailed.contains(game.id) { return .failed }
        if game.localExe == nil && !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path) { return .waitingNew }
        if OnlineSteam.serverIsAlive(prefix) { return .waitingOpen }
        return .nextStart
    }

    /// The bottle writes go to Unwine's own log: Show logs on a game's page opens Steam Play's logs.
    func showBottleLog() { NSWorkspace.shared.activateFileViewerSelecting([log.url]) }

    /// The game uses DirectDraw, so cnc-ddraw draws it (under every layer but WineD3D). Cached per
    /// game folder, and the profile writes at Unwine's start have read it already.
    func usesDirectDraw(_ game: SteamGame) -> Bool {
        DirectDrawConfig.mayUse(stored.analyses[game.id]?.api) && !DirectDrawConfig.programs(in: game.installDir).isEmpty
    }

    /// The engine carries DXMT's DirectX 12 part.
    var hasDXMTD3D12: Bool { engine.map { DXMTD3D12.isAvailable(engine: $0) } ?? false }

    /// The game runs on DXMT's own DirectX 12 part (experimental): a DirectX 12 game with the switch on,
    /// on the DXMT layer, with an engine that carries that part.
    func usesDXMTD3D12(_ id: Int) -> Bool {
        settings(for: id).dxmtD3D12 && stored.analyses[id]?.api == .dx12 && renderer(for: id) == .dxmt && hasDXMTD3D12
    }

    /// "DirectX 12 through DXMT" on also puts the game on the DXMT layer, the only one it works with.
    /// Off puts a game on DXMT back to Automatic.
    func setDXMTD3D12(_ on: Bool, for id: Int) {
        if on, let engine { _ = DXMTD3D12.folder(engine: engine, log: log) }
        update(id) { s in
            s.dxmtD3D12 = on
            if on { s.renderer = .dxmt } else if s.renderer == .dxmt { s.renderer = .auto }
        }
    }
}

extension GameSettings {
    /// Logs, display and experimental choices are the player's, not speed or battery settings, so a
    /// preset keeps them.
    mutating func keepPlayerChoices(from other: GameSettings) {
        detailedLogs = other.detailedLogs
        retina = other.retina
        fillScreen = other.fillScreen
        commandIsCtrl = other.commandIsCtrl
        forceSDR = other.forceSDR
        dxmtD3D12 = other.dxmtD3D12
        ddrawMode = other.ddrawMode
    }

    /// For the comparison with a preset: the player's own choices go back to their defaults, and so
    /// does Metal 4 below macOS 26, where it does nothing.
    mutating func dropPlayerChoices() {
        keepPlayerChoices(from: GameSettings())
        if !Profiles.hasMetal4 { metal4 = GameSettings().metal4 }
    }
}
