import Foundation

/// Where a game is in its run, for its tile, its page and its right-click menu. Steam games and added
/// games answer the same way: a Steam game from its Windows bottle's lock and Unwine's start watcher,
/// an added game from Unwine's own start and stop.
enum RunState: Equatable {
    case idle
    case starting([String])     // the words for the wait
    case running
    case closing([String])

    /// The words to show while Unwine waits, or nil when nothing waits.
    var waitWords: [String]? {
        switch self {
        case .starting(let words), .closing(let words): return words
        case .idle, .running: return nil
        }
    }
}

extension AppModel {
    func runState(of game: SteamGame) -> RunState {
        if game.localExe != nil {
            // A runtime that installs is a wait of its own: the tile and the page say what it is.
            if let job = runtimeJob(inBottleOf: game) {
                return .starting(["Installing \(WindowsRuntime.pinned(job.runtime).title)…", "It comes from Microsoft"])
            }
            if let step = localStarting[game.id] {
                let app = isApp(game)
                // A question from macOS stays in view until it is answered.
                if step.hasPrefix("macOS asks") { return .starting([step]) }
                return step.hasPrefix("Closing") ? .closing([step, app ? "Ending the app's programs…" : "Ending the game's programs…"])
                                                 : .starting([step, app ? "Windows apps start slowly on a Mac" : "Windows games start slowly on a Mac",
                                                              app ? "The app's window opens soon" : "The game's window opens soon"])
            }
            return localRunning.contains(game.id) ? .running : .idle
        }
        if quittingGames.contains(game.id) { return .closing(["Closing \(game.name)…", "Ending the game's programs…"]) }
        if let words = steamStarting[game.id] { return .starting(words) }
        return steamGamesRunning.contains(game.id) ? .running : .idle
    }

    /// "Portal 2 is running. Close it first", with each Steam game that runs by name, or "A game is
    /// running" when Unwine cannot name it (a helper that Steam Play left behind). For the messages
    /// of what waits for Steam Play's games to close.
    func closeRunningFirst() -> String {
        let names = windowsGames.filter { $0.localExe == nil && runState(of: $0) != .idle }.map(\.name)
        switch names.count {
        case 0: return "A game is running. Close it first"
        case 1: return "\(names[0]) is running. Close it first"
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1]) are running. Close them first"
        }
    }

    /// Why a change to a game's Windows bottle must wait, or nil while the bottle is closed.
    func bottleBusyReason(_ game: SteamGame) -> String? {
        switch runState(of: game) {
        case .idle: return nil
        case .starting where runtimeJob(inBottleOf: game) != nil: return Self.runtimeInstallingReason
        case .starting: return "\(game.name) is starting. Wait for its window, then quit the \(noun(game)) first."
        case .running: return "\(game.name) is running. Quit the \(noun(game)) first."
        case .closing: return "\(game.name) is closing. Wait a moment."
        }
    }

    /// Why Play cannot start this Steam game now, or nil when it can. One start at a time: a second
    /// click would ask Steam for a second launch.
    func steamPlayBlocker(_ game: SteamGame) -> String? {
        if macSteamBlocked { return Self.macSteamBlockedReason }
        if game.state != .installed { return "Finish the download in Steam first" }
        if steamRestartWords != nil || busyGame != nil { return "Steam is restarting. Wait for it to finish." }
        switch runState(of: game) {
        case .idle: return nil
        case .starting: return "\(game.name) is starting in Steam. Its window opens soon. If Steam asks something, answer it in Steam."
        case .running: return "\(game.name) is running."
        case .closing: return "\(game.name) is closing. Wait a moment."
        }
    }

    /// The Steam game whose start Unwine waits on, by name, or nil. Mac Steam must not close
    /// meanwhile: that ends the start. Before its bottle opens, nothing else shows that it starts.
    var startingSteamGame: String? {
        steamStarting.keys.sorted().compactMap { id in games.first { $0.id == id }?.name }.first
    }

    /// Why Restart Steam cannot run now, or nil when it can. Steam closes its games when it quits.
    var restartSteamBlocker: String? {
        // Set up with "Use without Steam for now": there is no Steam to restart.
        if steamMissing { return Self.steamMissingReason }
        if steamRestartWords != nil { return "Steam is restarting now. Wait for it to finish." }
        if busyGame != nil { return "Steam is restarting for a game's setting. Wait for it to finish." }
        if let name = startingSteamGame { return "\(name) is starting in Steam. Wait for its window, then close the game first." }
        if gameRunning { return "\(closeRunningFirst()): Steam closes its games when it quits." }
        if macSteamBlocked { return Self.macSteamBlockedReason }
        return nil
    }

    /// Why a game cannot switch to Unwine in Steam, or back, now (Steam restarts for it), or nil.
    var steamSwitchBlocker: String? {
        if steamRestartWords != nil { return "Steam is restarting now. Wait for it to finish." }
        if busyGame != nil { return "Steam is restarting for a game's setting. Wait for it to finish." }
        if let name = startingSteamGame { return "\(name) is starting in Steam. Steam restarts for this change. Wait for its window, then close the game first." }
        if gameRunning { return "\(closeRunningFirst()): Steam restarts for this." }
        return nil
    }

    /// Said before Quit game ends a Steam game.
    static let quitGameWarning = "Unwine closes the game and every program in its Windows bottle at once. Progress you have not saved is lost."
}
