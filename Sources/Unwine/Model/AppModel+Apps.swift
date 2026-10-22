import AppKit
import Foundation

/// Windows apps beside Windows games: which added programs are apps, the words the library uses for
/// them, and their own defaults.
extension AppModel {
    func localRecord(_ id: Int) -> LocalGameRecord? { stored.localGames.first { $0.id == id } }

    /// Game or app, as saved with the program: Unwine's guess once its files were read, or the user's
    /// choice. Until then, and for Steam games, a game. Unwine never changes it by itself later.
    func kind(of game: SteamGame) -> ProgramKind { kind(ofID: game.id) }

    func kind(ofID id: Int) -> ProgramKind {
        guard LocalGames.isLocal(id), let r = localRecord(id) else { return .game }
        return r.kind ?? .game
    }

    /// Unwine's guess from the program's files, once read. An installer is no app: the program it puts
    /// in the bottle is guessed when the entry starts that one.
    func guessedKind(_ id: Int) -> ProgramKind? {
        guard let r = localRecord(id), let a = stored.analyses[id], a.isCurrent else { return nil }
        if LocalGames.looksLikeInstaller(URL(fileURLWithPath: r.exePath)) { return .game }
        return a.looksLikeApp == true ? .app : .game
    }

    /// Saves the guess for a program that has none yet, right after it was added or became another
    /// program. Its settings and its Mac app follow.
    func settleKind(_ game: SteamGame) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }), stored.localGames[i].kind == nil,
              let guess = guessedKind(game.id) else { return }
        stored.localGames[i].kind = guess
        save()
        writeProfile(for: game.id)
        refreshMacApp(for: game.id)
    }

    /// Once, at the first start of 1.0.6: each program keeps the half it had. Programs added before
    /// 1.0.6 were games, so they stay games. A program this version read already keeps its guess.
    func saveKinds() {
        guard !stored.kindsSaved else { return }
        for i in stored.localGames.indices where stored.localGames[i].kind == nil {
            let id = stored.localGames[i].id
            if let guess = guessedKind(id) {
                stored.localGames[i].kind = guess
            } else {
                stored.localGames[i].kind = .game
                stored.appCheck.insert(id)
            }
        }
        stored.kindsSaved = true
        save()
    }

    /// One banner for the games from before 1.0.6 whose files look like an app's, a moment after the
    /// last of them is read. Nothing moves until the user says so.
    func suggestApp(_ id: Int) {
        appSuggestions.insert(id)
        appSuggestionTask?.cancel()
        appSuggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let found = self.games.filter { self.appSuggestions.contains($0.id) && !self.isApp($0) }
            self.appSuggestions = []
            guard !found.isEmpty else { return }
            let names = found.count == 1 ? found[0].name
                : found.dropLast().map(\.name).joined(separator: ", ") + " and " + found[found.count - 1].name
            self.log.line("Offered to move \(names) to Apps: \(found.count == 1 ? "its files look" : "their files look") like an app's")
            self.show("\(names) \(found.count == 1 ? "looks" : "look") like Windows \(found.count == 1 ? "an app" : "apps"), not \(found.count == 1 ? "a game" : "games"). In Apps, \(found.count == 1 ? "it gets" : "they get") sharp text, Mac keys and Launchpad.",
                      action: .init(found.count == 1 ? "Move to Apps" : "Move them to Apps") { [weak self] in
                          for g in found { self?.setKind(.app, for: g) }
                          if found.count > 1 { self?.banner = "\(names) are in your Apps now. Each page has what apps need: runtimes, sharp text and Mac keys." }
                      })
        }
    }

    func isApp(_ game: SteamGame) -> Bool { kind(ofID: game.id) == .app }

    /// The library has at least one app, so it shows the Games | Apps switch.
    var hasApps: Bool { stored.localGames.contains { kind(ofID: $0.id) == .app } }

    /// "game" or "app", for the words on tiles, pages and banners.
    func noun(_ game: SteamGame) -> String { isApp(game) ? "app" : "game" }

    /// What starts the program: Play for a game, Open for an app.
    func startWord(_ game: SteamGame) -> String { isApp(game) ? "Open" : "Play" }

    /// A new app's settings: Unwine's defaults for new games, with sharp text (Wine's Retina mode and
    /// 192 DPI) and Mac keys (Command acts as Ctrl, so ⌘C, ⌘V and ⌘S work) on. A game starts with the
    /// defaults as they are.
    func defaults(forID id: Int) -> GameSettings {
        var s = stored.defaults
        if kind(ofID: id) == .app {
            s.retina = true
            s.commandIsCtrl = true
        }
        return s
    }

    /// Moves an added program between Games and Apps. Its settings follow when the user never changed
    /// them, so an app gets sharp text and Mac keys, and a game loses them.
    func setKind(_ kind: ProgramKind, for game: SteamGame) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }), stored.localGames[i].kind != kind else { return }
        stored.localGames[i].kind = kind
        save()
        writeProfile(for: game.id)
        libraryKind = kind == .app ? .apps : .games
        refreshMacApp(for: game.id)
        if kind == .app { Task { await checkRuntimes(game) } }
        banner = kind == .app
            ? "\(game.name) is in your Apps now. Its page has what apps need: runtimes, sharp text and Mac keys."
            : "\(game.name) is in your Games now. Its page has the game settings: graphics, speed and Apple extras."
    }

    /// Says where a program that was just added went, once its files are read: Games or Apps, with a
    /// one-click move when Unwine guessed wrong.
    func announceAdded(_ game: SteamGame) {
        guard let r = localRecord(game.id), !LocalGames.looksLikeInstaller(URL(fileURLWithPath: r.exePath)) else { return }
        let app = isApp(game)
        libraryKind = app ? .apps : .games
        show(app ? "\(game.name) is in your Apps. Unwine read its files and set it up as an app, with sharp text and Mac keys."
                 : "\(game.name) is in your Games. Unwine read its files to pick the best settings.",
             action: .init(app ? "It is a game" : "It is an app") { [weak self] in self?.setKind(app ? .game : .app, for: game) })
        if app { Task { await checkRuntimes(game) } }
    }
}

/// Which half of the library shows: games or apps. The choice is saved.
enum LibraryKind: String, CaseIterable, Identifiable {
    case games, apps

    var id: String { rawValue }
    var title: String { self == .games ? "Games" : "Apps" }
}

// MARK: - The app's own Mac app, and the files it opens

extension AppModel {
    /// The app has its own Mac app in Launchpad: on for apps unless the user turned it off. An installer
    /// gets none, so Launchpad never runs a setup again.
    func macAppOn(_ game: SteamGame) -> Bool { macAppDefault(game.id) }

    private func macAppDefault(_ id: Int) -> Bool {
        guard let r = localRecord(id) else { return false }
        return r.macApp ?? (kind(ofID: id) == .app && !LocalGames.looksLikeInstaller(URL(fileURLWithPath: r.exePath)))
    }

    func setMacApp(_ on: Bool, for game: SteamGame) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }) else { return }
        stored.localGames[i].macApp = on
        save()
        refreshMacApp(for: game.id)
    }

    /// Every file type the app's Mac app opens: the ones the app registered in its bottle and the ones
    /// the user added, without the ones the user took away.
    func fileTypes(of game: SteamGame) -> [String] {
        guard let r = localRecord(game.id) else { return [] }
        return Array(Set(r.registeredFileTypes ?? []).union(r.fileTypes).subtracting(r.excludedFileTypes)).sorted()
    }

    /// The types the app registered in its bottle, from the last read.
    func registeredTypes(of game: SteamGame) -> Set<String> { Set(localRecord(game.id)?.registeredFileTypes ?? []) }

    /// Adds a file type by its extension ("dxf", ".dxf" or "*.dxf"). Returns why it was not added, or nil.
    func addFileType(_ text: String, for game: SteamGame) -> String? {
        var ext = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.hasPrefix("*") { ext.removeFirst() }
        if ext.hasPrefix(".") { ext.removeFirst() }
        guard !ext.isEmpty, ext.count <= 12, ext.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return "Type the end of the file name, such as dxf. Letters and numbers only."
        }
        guard !["exe", "app", "dll", "lnk"].contains(ext) else { return ".\(ext) files are programs, not documents." }
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }) else { return nil }
        guard !fileTypes(of: game).contains(ext) else { return ".\(ext) is in the list already." }
        // A registered type the user took away comes back; any other type joins the user's list.
        if stored.localGames[i].excludedFileTypes.contains(ext) {
            stored.localGames[i].excludedFileTypes.removeAll { $0 == ext }
        } else {
            stored.localGames[i].fileTypes.append(ext)
        }
        save()
        refreshMacApp(for: game.id)
        return nil
    }

    /// Stops the Mac app opening a type. A type the app registered in its bottle stays taken away,
    /// also after the next read of the bottle.
    func removeFileType(_ ext: String, for game: SteamGame) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }) else { return }
        stored.localGames[i].fileTypes.removeAll { $0 == ext }
        if stored.localGames[i].registeredFileTypes?.contains(ext) == true, !stored.localGames[i].excludedFileTypes.contains(ext) {
            stored.localGames[i].excludedFileTypes.append(ext)
        }
        save()
        refreshMacApp(for: game.id)
    }

    /// Reads the file types the app registered in its bottle (its installer usually does) and keeps
    /// them with the program. Small reads of the registry files, off the main thread. Wine writes the
    /// registry while the bottle runs, so a running bottle is read later. The Mac app follows a change.
    func readRegisteredFileTypes(_ game: SteamGame) async {
        guard let exe = game.localExe, !LocalGames.isRunning(game) else { return }
        let pfx = LocalGames.prefix(game)
        guard let found = await Task.detached(priority: .utility, operation: { RegisteredFileTypes.read(prefix: pfx, exe: exe) }).value,
              let i = stored.localGames.firstIndex(where: { $0.id == game.id }),
              stored.localGames[i].registeredFileTypes != found else { return }
        stored.localGames[i].registeredFileTypes = found
        save()
        if macAppOn(game) { refreshMacApp(for: game.id) }
    }

    /// Makes, renews or removes the program's Mac app to match its name, icon, file types and switch.
    /// Each program's renewals run one after another, off the main thread.
    func refreshMacApp(for id: Int) {
        let log = localLog(id)
        let previous = macAppTasks[id]
        guard let r = localRecord(id), macAppDefault(id) else {
            macAppPlaces[id] = nil
            macAppTasks[id] = Task.detached(priority: .utility) { await previous?.value; MacApps.remove(id, log: log) }
            return
        }
        let game = LocalGames.game(from: r)
        let icon = ArtCache.iconFile(id)
        let plan = MacApps.Plan(id: id, name: r.name, fileTypes: fileTypes(of: game), unwine: Bundle.main.bundleURL.path,
                                program: Bundle.main.executableURL.map(MacApps.stamp) ?? "", icon: MacApps.stamp(icon), key: macAppKey)
        macAppFailed.remove(id)
        macAppTasks[id] = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            let place = MacApps.write(plan, icon: icon, log: log)
            let model = self
            await MainActor.run {
                model?.macAppPlaces[id] = place
                if place == nil { model?.macAppFailed.insert(id) }
            }
        }
    }

    /// Once after Unwine opens: every app's Mac app is checked, so a new Unwine renews the copies and
    /// a removed program's Mac app goes. Cheap when nothing changed (one Info.plist read each).
    func refreshAllMacApps() {
        let known = Set(stored.localGames.map(\.id))
        let log = self.log
        // The folder is tidied first, so no renewal finds a half-made or second copy.
        let tidy = Task.detached(priority: .utility) {
            MacApps.tidy(log: log)
            for app in MacApps.all() where !known.contains(app.id) { MacApps.remove(app.id, log: log) }
        }
        for r in stored.localGames {
            macAppTasks[r.id] = tidy
            refreshMacApp(for: r.id)
        }
    }

    /// The secret the Mac apps carry, made once and kept in state.json.
    var macAppKey: String {
        if let key = stored.macAppKey { return key }
        let key = UUID().uuidString
        stored.macAppKey = key
        save()
        return key
    }

    /// "unwine://open?program=<id>&key=<secret>&file=<path>" from an app's Mac app: starts the app, or,
    /// when it runs already, asks it to open the files (Windows apps pass a second start to the first
    /// one). A request without the secret (a web page's link) starts nothing.
    func openFromMacApp(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let key = stored.macAppKey, items.first(where: { $0.name == "key" })?.value == key else {
            log.line("Ignored an unwine:// link without the Mac apps' key")
            return
        }
        let files = items.filter { $0.name == "file" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
        guard let id = items.first(where: { $0.name == "program" })?.value.flatMap(Int.init), let r = localRecord(id) else {
            NSApp.activate()
            show("This Mac app belongs to a program that is not in Unwine any more. Move it from Applications › Unwine Apps to the Trash.", .problem)
            return
        }
        let game = games.first { $0.id == id } ?? LocalGames.game(from: r)
        // While a runtime installs, nothing starts in the bottle: the page shows the install.
        if runtimeJob(inBottleOf: game) != nil {
            show("A runtime is installing in \(game.name)'s bottle. \(startWord(game)) it when the install is done.")
            bringUnwineForward(to: game)
            return
        }
        let starting = localStarting[id] != nil || startScheduled.contains(id) || bottleToolStarting[id] != nil
        if starting || localRunning.contains(id) || LocalGames.isRunning(game) {
            if !files.isEmpty {
                queueOpen(files, for: game)
            } else if !starting {
                if let pid = Self.withWindows(Self.bottlePIDs(prefix: LocalGames.prefix(game))).first {
                    bringToFront(pid)
                } else if let exe = game.localExe {
                    // Only leftovers run in the bottle, with no window: the app starts in it again.
                    Task { await runInBottle(game, .open(exe, [])) }
                }
            }
            return
        }
        // Marked before the start runs, so a second request in the same moment joins this start.
        startScheduled.insert(id)
        Task {
            startScheduled.remove(id)
            await playLocal(game, files: files, fromMacApp: true)
        }
    }

    /// Files for an app that starts, or that opens other files now. They wait in one list, and one
    /// task hands them over together once the app is ready, so none is lost.
    private func queueOpen(_ files: [URL], for game: SteamGame) {
        let id = game.id
        pendingOpenFiles[id, default: []] += files
        guard openDrains[id] == nil, let exe = game.localExe else { return }
        openDrains[id] = Task { [weak self] in
            guard let self else { return }
            let since = Date()
            while true {
                while self.localStarting[id] != nil || self.startScheduled.contains(id) || self.bottleToolStarting[id] != nil,
                      Date().timeIntervalSince(since) < 180 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let all = self.pendingOpenFiles.removeValue(forKey: id) ?? []
                guard !all.isEmpty else { break }
                guard self.localRunning.contains(id) || LocalGames.isRunning(game), self.localStarting[id] == nil else {
                    let names = all.map(\.lastPathComponent).joined(separator: ", ")
                    self.show("\(game.name) did not open \(names), because it did not start. Its log says why.", .problem,
                              action: .init("Show logs") { [weak self] in self?.showLogs(of: game) })
                    self.bringUnwineForward(to: game)
                    break
                }
                await self.runInBottle(game, .open(exe, all.map(BottleTools.windowsPath)))
            }
            self.openDrains[id] = nil
        }
    }

    /// Unwine comes to the front on the program's page, where the banner says what went wrong. The
    /// program's Mac app stops waiting for a window, so a second click on it starts again.
    func bringUnwineForward(to game: SteamGame) {
        NSApp.activate()
        openPage(game)
        StartPanel.hide(game.id)
        for launcher in NSRunningApplication.runningApplications(withBundleIdentifier: MacApps.bundleID(game.id)) { launcher.terminate() }
    }

    /// Quit app: asks the app to quit the Mac way, as the Dock's Quit does. Wine hands that to the
    /// app's windows, so an app with unsaved work asks to save it, and its Cancel keeps it open. Nothing
    /// ends by force here. An app that is still open after 10 s gets a banner with Force quit.
    func quitApp(_ game: SteamGame) async {
        if runtimeJob(inBottleOf: game) != nil { banner = Self.runtimeInstallingReason; return }
        guard localStarting[game.id] == nil else { return }
        let pfx = LocalGames.prefix(game)
        let windowed = Self.withWindows(await Task.detached { Self.bottlePIDs(prefix: pfx) }.value)
        // No window: there is no work to save, and what is left ends at once.
        guard let first = windowed.first else { await stopLocal(game); return }
        localStarting[game.id] = "Closing \(game.name)…"
        endedByUnwine.insert(game.id)
        localLog(game.id).line("Asked \(game.name) to quit")
        bringToFront(first)     // a question to save shows in front
        for pid in windowed { NSRunningApplication(processIdentifier: pid)?.terminate() }
        let asked = Date()
        var open = true
        while Date().timeIntervalSince(asked) < 10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Self.withWindows(await Task.detached { Self.bottlePIDs(prefix: pfx) }.value).isEmpty { open = false; break }
        }
        localStarting[game.id] = nil
        if open {
            show("\(game.name) is still open. It may ask you to save your work: answer it in the app. Force quit ends it at once, and work you did not save is lost.",
                 action: .init("Force quit") { [weak self] in Task { await self?.stopLocal(game) } })
        }
        await refreshSteam()
    }
}

// MARK: - The Mac's Documents folder

extension AppModel {
    /// Wine links the bottle's Documents folder to the Mac's own, and many Windows programs open it as
    /// they start. macOS then asks once if Unwine may open Documents, and the program waits until the
    /// question is answered, with no window: a question behind other windows looks like a hang. So
    /// Unwine reads the folder itself before the start, and the wait says what to answer.
    func askFolderAccess(for game: SteamGame) async {
        guard !folderAccessAsked else { return }
        let link = LocalGames.prefix(game).appendingPathComponent("drive_c/users/\(NSUserName())/Documents")
        let folder = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let read = Task.detached(priority: .userInitiated) { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil }
        // An answer that macOS has already comes at once. A slow read means its question is up.
        let words = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.localStarting[game.id] = "macOS asks if Unwine may open your Documents folder. Choose Allow, so \(game.name) can open and save your files there."
        }
        let allowed = await read.value
        words.cancel()
        folderAccessAsked = true
        if localStarting[game.id] != nil { localStarting[game.id] = "Getting \(game.name) ready…" }
        if !allowed { localLog(game.id).line("macOS does not let Unwine open \(folder.path), so the program cannot use its Documents folder") }
    }
}
