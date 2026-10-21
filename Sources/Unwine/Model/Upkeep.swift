import AppKit
import Foundation

/// One log the Logs sheet can show.
struct LogSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: URL
    /// What the sheet says while there is no such log yet, with the next step.
    let empty: String
}

// Storage, logs, updates and safety: what Settings' Storage, Logs and Compatibility data groups do,
// and the clean-ups behind them.
extension AppModel {
    // MARK: Downloads

    /// Archives that an install still needs, so a clean-up keeps them.
    func downloadsKeep() -> DownloadsCleanup.Keep {
        var keep = DownloadsCleanup.Keep()
        if engine == nil { keep.names.formUnion(EngineRelease.pinned.archiveNames) }    // setup still installs it
        if let waiting = stored.pendingRelease { keep.names.formUnion(waiting.archiveNames) }   // a newer Unwine installs it
        return keep
    }

    /// Clears leftovers from Downloads at launch, from the update loop and after each update check.
    /// It never runs while something downloads or installs, and it ends before the caller goes on.
    func sweepDownloads() async {
        guard !isSettingUp, !isCheckingUpdates, !onlineStep.isRunning, !appUpdater.isBusy, engineDownload == nil else { return }
        let keep = downloadsKeep(), log = self.log
        let freed = await Task.detached(priority: .utility) { DownloadsCleanup.sweep(keep) }.value
        if freed > 0 { log.line("Deleted \(DiskUse.text(freed)) of downloads that no install needs") }
    }

    // MARK: Storage

    /// Measures Unwine's disk use off the main thread. Settings shows the progress while it runs.
    func measureStorage() async {
        guard storageProgress == nil else { return }
        storageProgress = 0
        let inputs = storageInputs()
        let report = await Task.detached(priority: .utility) {
            StorageReport.measure(inputs) { p in
                // A late report after the end must not bring the wait back.
                Task { @MainActor in if self.storageProgress != nil { self.storageProgress = p } }
            }
        }.value
        storageReport = report
        storageProgress = nil
    }

    private func storageInputs() -> StorageReport.Inputs {
        let engines = EngineStore.installed().map { e -> (engine: InstalledEngine, role: String) in
            if e.folder == engine?.folder { return (e, "In use") }
            if e.folder == stored.previousEngine { return (e, "Kept, so you can go back to it") }
            if e.folder == stored.stagedEngine { return (e, "New. Unwine switches to it after your games close.") }
            if e.folder == stored.heldEngine?.folder { return (e, "New. It waits, because one of Unwine's fixes does not fit it yet.") }
            return (e, "Not used. Unwine deletes it at the next engine change.")
        }
        let added = Dictionary(grouping: stored.localGames, by: \.bottle)
            .map { (bottle: $0.key, names: $0.value.sorted { $0.addedAt < $1.addedAt }.map(\.name)) }
        // Steam runs a game through Unwine when it is set to, or when no tool is set (Unwine is the add-on's only tool).
        let steam = games.filter { $0.localExe == nil && $0.isWindowsBuild && (mappings[$0.id] ?? Runner.toolName) == Runner.toolName }
            .map { (id: $0.id, name: $0.name, compatData: $0.compatData) }
        return StorageReport.Inputs(engines: engines, gptk: D3DMetalStore.installed(), addedBottles: added, steamGames: steam,
                                    keep: downloadsKeep(), localIDs: Set(stored.localGames.map(\.id)),
                                    localBottles: Set(stored.localGames.map(\.bottle)))
    }

    /// Runs one clean-up of Storage off the main thread. Settings shows `words` while it runs, then
    /// the note that `work` returns, and measures again.
    private func storageCleanUp(_ words: [String], _ work: @escaping @Sendable () -> String) async {
        guard storageWork == nil, storageProgress == nil else { return }
        storageWork = words
        let note = await Task.detached(priority: .utility, operation: work).value
        storageWork = nil
        storageNote = note
        await measureStorage()
    }

    /// Storage's "Delete leftovers" in Downloads.
    func deleteDownloadLeftovers() async {
        guard !isSettingUp, !isCheckingUpdates, !appUpdater.isBusy, engineDownload == nil else {
            storageNote = "A download runs now. Try again when it ends."
            return
        }
        let keep = downloadsKeep()
        await storageCleanUp(["Deleting downloads that no install needs…"]) {
            let freed = DownloadsCleanup.sweep(keep)
            return freed > 0 ? "Deleted \(DiskUse.text(freed)) of downloads that no install needs." : "There was nothing to delete."
        }
    }

    /// Storage's "Delete old GPTK": keeps only the GPTK that games use.
    func deleteOldGPTK() async {
        guard let current = d3dmetal else { return }
        if let why = engineSwitchBlocker { storageNote = why; return }
        // Steam games reach GPTK through a link in Unwine's Steam tool. It must name the copy that stays.
        if let engine, runnerReady, Runner.record()?.d3dmetalFolder != current.folder {
            try? Runner.refresh(engine: engine, d3dmetal: current)
        }
        await storageCleanUp(["Deleting the older GPTK copies…"]) {
            let freed = D3DMetalStore.removeOld(keeping: current)
            return "Deleted the older GPTK copies (\(DiskUse.text(freed))). Games keep \(current.label)."
        }
    }

    /// Storage's "Clear all…" for shader caches.
    func clearAllShaderCaches() async {
        if let why = engineSwitchBlocker { storageNote = why; return }
        let folders = storageReport?.shaderFolders ?? [], log = self.log
        await storageCleanUp(["Deleting the saved shaders…", "Each game builds them again at its next start"]) {
            let freed = ShaderCache.clear(folders)
            log.line("Cleared \(DiskUse.text(freed)) of saved shaders")
            return "Cleared \(DiskUse.text(freed)) of saved shaders. Each game builds its shaders again at its next start."
        }
    }

    /// Storage's "Delete logs of removed games".
    func deleteRemovedGameLogs() async {
        let ids = Set(stored.localGames.map(\.id))
        await storageCleanUp(["Deleting the logs of removed games…"]) {
            var freed: Int64 = 0
            for file in StorageReport.removedGameLogs(keeping: ids) {
                let bytes = DiskUse.size(of: file)
                if (try? FileManager.default.removeItem(at: file)) != nil { freed += bytes }
            }
            return "Deleted \(DiskUse.text(freed)) of logs of removed games."
        }
    }

    /// Storage's "Move to Trash…" for bottles of games that are gone. Each one is checked again first.
    func trashOrphanBottles() async {
        let orphans = storageReport?.orphans ?? [], log = self.log
        let bottles = Set(stored.localGames.map(\.bottle))
        await storageCleanUp(["Moving the bottles to the Trash…"]) {
            var freed: Int64 = 0, failed = 0
            for o in orphans where StorageReport.isStillOrphan(o, localBottles: bottles) {
                if (try? FileManager.default.trashItem(at: o.folder, resultingItemURL: nil)) != nil { freed += o.bytes } else { failed += 1 }
            }
            log.line("Moved \(DiskUse.text(freed)) of bottles of removed games to the Trash")
            return "Moved \(DiskUse.text(freed)) to the Trash. Empty the Trash to get the space back."
                + (failed > 0 ? " \(failed) bottle(s) could not move. Show them in Finder and move them yourself." : "")
        }
    }

    // MARK: One game's shader cache

    /// Why a game's saved shaders cannot be cleared now, or nil. The files are open while the game runs.
    func shaderClearBlocker(for game: SteamGame) -> String? {
        if game.localExe != nil {
            let bottle = game.bottleID ?? game.id
            let busy = stored.localGames.contains { $0.bottle == bottle && (localRunning.contains($0.id) || localStarting[$0.id] != nil) }
            return busy ? "Quit the game first" : nil
        }
        if gameRunning { return "A game is running. Quit it first." }
        if online.inUse { return "Windows Steam is open. Quit it first." }
        return nil
    }

    /// Deletes one game's saved shaders. Returns the bytes freed, or nil when the game runs.
    func clearShaderCache(_ folders: [URL], of game: SteamGame) async -> Int64? {
        if let why = shaderClearBlocker(for: game) { banner = why; return nil }
        guard !Runner.isPrefixRunning(LocalGames.prefix(game)) else { banner = "\(game.name) is running. Quit the game first."; return nil }
        let freed = await Task.detached(priority: .utility) { ShaderCache.clear(folders) }.value
        log.line("Cleared \(DiskUse.text(freed)) of saved shaders for \(game.name)")
        storageReport = nil     // the totals in Storage changed
        return freed
    }

    // MARK: Logs

    /// The logs a Logs sheet offers. For a game: its own log (and the Wine log of a Steam game), then
    /// Unwine's. Without a game: Unwine's, then Windows Steam's and the Steam Play add-on's when they exist.
    func logSources(for gameID: Int?) -> [LogSource] {
        let unwine = LogSource(id: "unwine", title: "Unwine", url: log.url,
                               empty: "Unwine has written nothing yet. Its log fills as it works.")
        guard let gameID, let game = games.first(where: { $0.id == gameID }) else {
            var list = [unwine]
            let online = Paths.logs.appendingPathComponent("online-steam.log")
            if FileManager.default.fileExists(atPath: online.path) {
                list.append(LogSource(id: "online", title: "Windows Steam", url: online, empty: "Online mode has no log yet."))
            }
            if FileManager.default.fileExists(atPath: SteamPlayPaths.addOnLog.path) {
                list.append(LogSource(id: "steamplay", title: "Steam Play", url: SteamPlayPaths.addOnLog,
                                      empty: "Steam Play has no log yet. It starts when Mac Steam opens."))
            }
            return list
        }
        if game.localExe != nil {
            return [LogSource(id: "game", title: "Game", url: game.runLog,
                              empty: "This game has no log yet. It starts the first time you press Play."), unwine]
        }
        return [LogSource(id: "game", title: "Game start", url: game.runLog,
                          empty: "Steam writes this log when it starts the game through Unwine. Press Play, then open the logs again."),
                LogSource(id: "wine", title: "Wine", url: game.wineLog,
                          empty: "Wine writes this log while the game runs. Press Play, then open the logs again."),
                unwine]
    }

    /// Unwine's own page for a new issue on GitHub.
    var reportProblemURL: URL {
        URL(string: "https://github.com/\(appUpdater.repo ?? "chansekhung/unwine")/issues/new")!
    }

    /// Plain text for a bug report: Unwine, macOS, the Mac's chip, the engine and GPTK, the game's layer
    /// and settings, and the last 200 lines of the log shown. The home folder's path and the user's
    /// name become "~" and "<user>", so the report does not carry them.
    func bugReport(gameID: Int?, logTitle: String, logText: String) -> String {
        var lines: [String] = []
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        lines.append("Unwine \(appUpdater.currentVersion)\(build.map { " (build \($0))" } ?? "")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac: \(Self.chipName), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB memory")
        if let engine {
            lines.append("Engine: \(engine.label) [\(engine.folder)]")
            let fixes = PatchStatus.fixes(engine: engine)
            lines.append("Unwine's fixes: " + fixes.map { "\($0.kind.title) \($0.on ? "on" : "off")" }.joined(separator: ", "))
        } else {
            lines.append("Engine: not installed")
        }
        if let previous = previousEngineInstalled { lines.append("Previous engine: \(previous.label)") }
        lines.append("GPTK: \(d3dmetal?.label ?? "not added")")
        lines.append("Steam: \(steamVersion ?? "version unknown"), Steam Play \(steamPlay == .on ? "on" : steamPlay == .off ? "not seen" : "behind Steam")")
        if let gameID, let game = games.first(where: { $0.id == gameID }) {
            lines.append("Game: \(game.name) (\(game.localExe.map { "added game, \($0.lastPathComponent)" } ?? "Steam app \(game.id)"))")
            let s = settings(for: gameID)
            lines.append("Layer: \(renderer(for: gameID).title) (set to \(s.renderer.title))")
            if let a = stored.analyses[gameID] {
                lines.append("Game files: \(a.api.label), \(a.is64Bit ? "64-bit" : "32-bit")\(a.engine.map { ", \($0)" } ?? "")\(a.antiCheat.isEmpty ? "" : ", anti-cheat: \(a.antiCheat.joined(separator: ", "))")")
            }
            lines.append("Settings: " + Mirror(reflecting: s).children.map { "\($0.label ?? "?") \(Self.plain($0.value))" }.joined(separator: ", "))
        }
        let tail = logText.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        lines.append("")
        lines.append("Last 200 lines of the \(logTitle) log:")
        lines.append(tail.isEmpty ? "(empty)" : tail)
        return Self.redacted(lines.joined(separator: "\n"))
    }

    /// A setting's value in plain words: an empty optional is "default".
    private static func plain(_ value: Any) -> String {
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional else { return "\(value)" }
        return m.children.first.map { "\($0.value)" } ?? "default"
    }

    /// The report with the home folder and the user's name taken out (Wine's paths carry the name too).
    private static func redacted(_ text: String) -> String {
        let user = NSUserName()
        var out = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard user.count > 1 else { return out }
        for form in ["users/\(user)", "users\\\(user)", "Users/\(user)", "/\(user)/"] {
            out = out.replacingOccurrences(of: form, with: form.replacingOccurrences(of: user, with: "<user>"), options: .caseInsensitive)
        }
        return out
    }

    /// "Apple M4 Pro", from the kernel.
    private static var chipName: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Apple silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Apple silicon" }
        return String(cString: buffer)
    }

    // MARK: Compatibility data

    /// Settings' "Refresh now": asks Highball for its newest list. An unchanged list costs one short answer.
    func refreshCompatibilityData() async {
        guard !highballRefreshing else { return }
        highballRefreshing = true
        defer { highballRefreshing = false }
        switch await HighballDB.refresh(force: true, log: log) {
        case .updated(let count):
            highballNote = "Unwine got the newest list: \(count) games."
            highballLoads += 1
            if showsLibrary { writeAllProfiles() }     // "Automatic" may now follow a tested layer
        case .unchanged:
            highballNote = "The list is up to date."
            highballLoads += 1      // the date shown changes
        case .failed(let why):
            highballNote = "Unwine could not get the list: \(why) Check the internet connection, then try again."
        case .notNeeded:
            break
        }
    }
}
