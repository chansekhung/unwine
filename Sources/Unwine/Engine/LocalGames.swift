import Darwin
import Foundation

/// A Windows game or program the user added by its .exe. It runs without Steam, on Unwine's own
/// engine, in a Windows bottle of its own.
struct LocalGameRecord: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var exePath: String
    var addedAt: Date
    /// The added game whose Windows bottle this one uses. Programs from one game folder share a
    /// bottle, as on Windows they share one registry: a launcher's settings then reach the game.
    var bottleOf: Int? = nil
    /// The game folder the user picked, when the program sits deeper in it (bin/x64). Unwine reads the
    /// game's files from here, so anti-cheat and engine clues in the top folders count too.
    var rootPath: String? = nil
    var lastPlayed: Date? = nil
    var playtimeMinutes = 0             // while its bottle ran after Play, in whole minutes
    /// The program's own name from its version info (ProductName), for Highball advice.
    var productName: String? = nil
    /// The Steam app id in a steam_appid.txt next to the program, for Highball advice.
    var steamAppID: Int? = nil
    /// The program file that `productName`, `steamAppID` and the icon in Covers were read from. Nil
    /// until Unwine reads them; a program that moved is read again.
    var productRead: String? = nil
    /// A picture the user chose for the game: a file name in Unwine's Covers folder.
    var cover: String? = nil
    /// Game or app, as the user set it. Nil: Unwine's guess from the program's files (GameAnalysis).
    var kind: ProgramKind? = nil
    /// File name extensions ("fem", "dxf") the program's Mac app opens from Finder, beyond the ones the
    /// program registered in its bottle. Without a dot, lower case.
    var fileTypes: [String] = []
    /// The extensions the program registered in its bottle (its installer usually does), from the last
    /// read of the bottle's registry. Nil: not read yet. Kept here, so each Unwine start builds the
    /// Mac app with the same types without reading the registry again.
    var registeredFileTypes: [String]? = nil
    /// Registered extensions the user took away: the Mac app does not open these.
    var excludedFileTypes: [String] = []
    /// The program's own Mac app in ~/Applications/Unwine Apps, for Launchpad and the Dock. Nil: on for
    /// apps, off for games.
    var macApp: Bool? = nil

    var folder: URL { URL(fileURLWithPath: exePath).deletingLastPathComponent().standardizedFileURL }
    /// Where the game's own files start: the folder the user picked, else the program's folder.
    var root: URL { rootPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? folder }
    var bottle: Int { bottleOf ?? id }
}

extension LocalGameRecord {
    /// Fields added after Unwine 1.0.2 decode with a default, so older libraries keep every game.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        exePath = try c.decode(String.self, forKey: .exePath)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        bottleOf = try? c.decodeIfPresent(Int.self, forKey: .bottleOf)
        rootPath = try? c.decodeIfPresent(String.self, forKey: .rootPath)
        lastPlayed = try? c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        playtimeMinutes = (try? c.decodeIfPresent(Int.self, forKey: .playtimeMinutes)) ?? 0
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        steamAppID = try? c.decodeIfPresent(Int.self, forKey: .steamAppID)
        productRead = try? c.decodeIfPresent(String.self, forKey: .productRead)
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        kind = try? c.decodeIfPresent(ProgramKind.self, forKey: .kind)
        fileTypes = (try? c.decodeIfPresent([String].self, forKey: .fileTypes)) ?? []
        registeredFileTypes = try? c.decodeIfPresent([String].self, forKey: .registeredFileTypes)
        excludedFileTypes = (try? c.decodeIfPresent([String].self, forKey: .excludedFileTypes)) ?? []
        macApp = try? c.decodeIfPresent(Bool.self, forKey: .macApp)
    }
}

/// What an added program is for. A game gets the game page (graphics, speed, Apple extras); an app gets
/// the app page (runtimes, sharp text, Mac keys, file types, Launchpad).
enum ProgramKind: String, Codable, Sendable {
    case game, app
}

enum LocalGamesError: LocalizedError {
    case missing(String)
    case bottle(String)

    var errorDescription: String? {
        switch self {
        // Adding it again would make a second entry with a new, empty bottle. The failed-start banner
        // and the game's page both have Locate….
        case .missing(let path): return "Its program is not in \(path) now. Press Locate… and pick it where it is now. Its bottle and saves stay."
        case .bottle(let why): return "Unwine could not make its Windows bottle. \(why) Try again. If it fails again, the log says why."
        }
    }
}

enum LocalGames {
    /// Added games get ids far above any Steam appid, so their settings, profiles and file checks
    /// share the tables Steam games use.
    static let idBase = 2_100_000_000
    static var root: URL { Paths.support.appendingPathComponent("LocalGames", isDirectory: true) }
    static func isLocal(_ id: Int) -> Bool { id >= idBase }

    /// The game as the library shows it. Its bottle is LocalGames/compatdata/<id>/pfx, the same
    /// layout as Steam's, so the bottle checks and "Fresh bottle" work for it too. Its install folder
    /// is the game folder the user picked, so the file check reads the whole game.
    static func game(from r: LocalGameRecord) -> SteamGame {
        SteamGame(id: r.id, name: r.name, installDir: r.root, steamapps: root,
                  sizeOnDisk: 0, state: .installed, lastPlayed: r.lastPlayed, isWindowsBuild: true,
                  localExe: URL(fileURLWithPath: r.exePath), bottleID: r.bottleOf,
                  playtimeMinutes: r.playtimeMinutes > 0 ? r.playtimeMinutes : nil, addedAt: r.addedAt)
    }

    /// Steam's own order (last played first, then by name), with the added games in it.
    static func inLibraryOrder(_ games: [SteamGame]) -> [SteamGame] {
        games.sorted {
            switch ($0.lastPlayed, $1.lastPlayed) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// True when a program's file lies inside an added game's bottle (an installer put it there).
    static func isInside(_ exe: URL, bottle: Int) -> Bool {
        let dir = root.appendingPathComponent("compatdata/\(bottle)", isDirectory: true).standardizedFileURL.path + "/"
        return exe.standardizedFileURL.path.hasPrefix(dir)
    }

    /// What a program is for when it is not the game itself, from its file name. Version info does
    /// not help: Romance of the Three Kingdoms XIV's launcher describes itself with the game's name.
    static func role(of exe: URL) -> String? {
        let n = exe.deletingPathExtension().lastPathComponent.lowercased()
        if n.contains("launch") { return "Launcher" }
        if ["config", "setting", "option"].contains(where: n.contains) { return "Settings" }
        if ["tool", "editor"].contains(where: n.contains) { return "Tool" }
        return nil
    }

    /// True when an added game's bottle holds files a program wrote itself (saves, settings files).
    /// Caches do not count, and Documents, Desktop and the like are links to the Mac's own folders.
    static func bottleHoldsOwnFiles(_ bottle: Int) -> Bool {
        let users = root.appendingPathComponent("compatdata/\(bottle)/pfx/drive_c/users", isDirectory: true)
        let skip: Set<String> = ["temp", "microsoft", "dxvk", "mesa_shader_cache", "d3dscache", "nvidia", "cache", "caches", "crashdumps"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walk = FileManager.default.enumerator(at: users, includingPropertiesForKeys: keys) else { return false }
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true || skip.contains(url.lastPathComponent.lowercased()) { walk.skipDescendants(); continue }
            if v?.isRegularFile == true { return true }
        }
        return false
    }

    /// An added game from the same game folder as `exe`, whose bottle a new program should share:
    /// the same folder, or one folder inside the other at most two levels down (a launcher next to
    /// a bin folder). Further apart is more likely a folder of several games.
    static func bottleMate(for exe: URL, in records: [LocalGameRecord]) -> LocalGameRecord? {
        // A program an installer put inside another added program's bottle runs in that bottle:
        // its files, registry entries and helpers are there.
        if let host = records.first(where: { isInside(exe, bottle: $0.bottle) }) { return host }
        let dir = exe.deletingLastPathComponent().standardizedFileURL.pathComponents
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        func near(_ a: [String], _ b: [String]) -> Bool {
            let (short, long) = a.count <= b.count ? (a, b) : (b, a)
            if short.count <= home.count || shelves.contains(short.last?.lowercased() ?? "") { return false }
            return long.count - short.count <= 2 && Array(long.prefix(short.count)) == short
        }
        return records.first { near($0.folder.pathComponents, dir) }
    }

    /// Folders that hold many unrelated things are never one game's folder.
    static let shelves: Set<String> = ["documents", "desktop", "downloads", "applications", "games", "steamapps", "common", "volumes"]

    // A new game's name comes from LocalGames.defaultName (GameTitles.swift): its folder, past
    // generic ones such as bin, Program Files and drive_c, else the program's ProductName.

    /// The game's top folder, from the folder the user picked: that folder, or for a folder of many
    /// games (Games, Downloads, a whole drive) the folder in it that holds the program. Nil when that
    /// is the program's own folder (nothing more to read), or when the program is not inside it.
    static func gameRoot(for exe: URL, picked: URL?) -> URL? {
        guard let picked else { return nil }
        // Folder listings hand back resolved paths (/private/var for /var), so both sides are resolved.
        var root = picked.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dir = exe.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard dir.count >= root.count, Array(dir.prefix(root.count)) == root else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        if root.count <= home.count || shelves.contains(root.last?.lowercased() ?? "") {
            guard dir.count > root.count else { return nil }
            root = Array(dir.prefix(root.count + 1))
        }
        guard root.count < dir.count else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: root), isDirectory: true)
    }

    /// The game folder after the program moved: the same folder if the program is still in it, or the
    /// folder that now holds the program at the same place inside (the whole game moved).
    static func movedRoot(of record: LocalGameRecord, to exe: URL) -> URL? {
        // With no folder picked, the old program's folder is the game's: a program deeper in it (the
        // game in bin/x64, after its launcher) keeps it.
        guard record.rootPath != nil else { return gameRoot(for: exe, picked: record.folder) }
        let old = record.root.path + "/"
        let path = exe.standardizedFileURL.path
        if path.hasPrefix(old) { return gameRoot(for: exe, picked: record.root) }
        let inside = URL(fileURLWithPath: record.exePath).standardizedFileURL.path
        guard inside.hasPrefix(old), path.hasSuffix("/" + inside.dropFirst(old.count)) else { return nil }
        let moved = URL(fileURLWithPath: String(path.dropLast(inside.count - old.count + 1)), isDirectory: true)
        return gameRoot(for: exe, picked: moved)
    }

    /// True when a program's name says it installs something (setup, install). An uninstaller is not one.
    static func looksLikeInstaller(_ exe: URL) -> Bool {
        let n = exe.lastPathComponent.lowercased()
        return !n.contains("unins") && (n.contains("setup") || n.contains("install"))
    }

    static func logName(_ id: Int) -> String { "local-\(id).log" }

    /// The .exe files in a game folder and three folders down (an Unreal game keeps its program in
    /// Game/Binaries/Win64), the likeliest game first. Mac apps and a bottle's own Windows folder are
    /// skipped. Walks folders, so call it off the main thread.
    static func programs(in folder: URL, depth maxDepth: Int = 3) -> [(url: URL, size: Int64)] {
        let fm = FileManager.default
        var found: [(url: URL, size: Int64)] = []
        func scan(_ dir: URL, depth: Int) {
            guard found.count < 2000,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    let name = item.lastPathComponent.lowercased()
                    let skip = name.hasSuffix(".app") || (name == "windows" && dir.lastPathComponent.lowercased() == "drive_c")
                    if depth < maxDepth && !skip { scan(item, depth: depth + 1) }
                } else if item.pathExtension.lowercased() == "exe" {
                    found.append((item, Int64(values?.fileSize ?? 0)))
                }
            }
        }
        scan(folder, depth: 0)
        return Array(ranked(found).prefix(200))
    }

    /// Programs in likeliest-game order: installers, uninstallers, crash reporters, helpers and
    /// redistributables last, then bigger files before smaller.
    static func ranked(_ found: [(url: URL, size: Int64)]) -> [(url: URL, size: Int64)] {
        let unlikely = ["unins", "setup", "install", "redist", "vcredist", "dxsetup", "crash", "report", "dotnet", "directx", "uninst",
                        "helper", "prereq", "cefprocess", "easyanticheat", "beservice", "be_service", "touchup", "updater"]
        func score(_ u: URL) -> Int { unlikely.contains { u.lastPathComponent.lowercased().contains($0) } ? 1 : 0 }
        return found.sorted { a, b in
            score(a.url) != score(b.url) ? score(a.url) < score(b.url) : a.size > b.size
        }
    }

    /// Every .exe an installer can have put in a bottle: in Program Files, the other folders on its
    /// C: drive (GOG Games) and the user's AppData/Local/Programs, but not in Windows' own folders.
    /// Walks folders, so call it off the main thread.
    static func installedPrograms(in pfx: URL) -> Set<String> {
        let fm = FileManager.default
        let drive = pfx.appendingPathComponent("drive_c", isDirectory: true)
        var tops = ((try? fm.contentsOfDirectory(at: drive, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { !["windows", "users", "programdata"].contains($0.lastPathComponent.lowercased()) }
        for user in (try? fm.contentsOfDirectory(at: drive.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? [] {
            tops.append(user.appendingPathComponent("AppData/Local/Programs", isDirectory: true))
        }
        var found = Set<String>()
        for top in tops {
            guard let walk = fm.enumerator(at: top, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                if walk.level > 5 || found.count > 5000 { walk.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe" { found.insert(url.standardizedFileURL.path) }
            }
        }
        return found
    }

    static func prefix(_ game: SteamGame) -> URL { game.compatData.appendingPathComponent("pfx", isDirectory: true) }

    static func isRunning(_ game: SteamGame) -> Bool { OnlineSteam.serverIsAlive(prefix(game)) }

    /// The variables the game starts with: the engine's base, the game's Unwine profile on top,
    /// and the Vulkan driver (the Steam path takes it from the runner's engine.env). Logs are quiet
    /// unless the game's Detailed logs is on: its profile then sets the detailed levels.
    static func environment(engine: InstalledEngine, prefix: URL, profile: URL) -> [String: String] {
        var env = WineEnvironment.base(engine: engine, prefix: prefix, debug: false)
        if let text = try? String(contentsOf: profile, encoding: .utf8) {
            for (key, raw) in OnlineSteam.profileAssignments(text) {
                if let value = OnlineSteam.shellWord(raw, env: env) { env[key] = value }
            }
        }
        let vulkan = RendererPatches.vulkanICD(engine: engine).path
        env["VK_DRIVER_FILES"] = vulkan
        env["VK_ICD_FILENAMES"] = vulkan
        // Wine's menu builder writes Linux menu entries and icons into ~/.local/share for every
        // installer. A Mac never reads them, so it is off, as in Online mode. The game's own DLL
        // overrides stay.
        env["WINEDLLOVERRIDES"] = LaunchOptions.overrides(env["WINEDLLOVERRIDES"], adding: "winemenubuilder.exe=d")
        return env
    }

    /// `env` without Faster x87 math, for the wineboot that makes a bottle. wineboot starts 32-bit
    /// programs too, and x87sidecar would attach to them: macOS could then ask for the password while
    /// only a bottle is made. The game itself starts with it.
    static func withoutX87(_ env: [String: String]) -> [String: String] {
        env.filter { !X87Sidecar.variables.contains($0.key) }
    }

    /// Starts the game with `arguments` after its program's name. On its first start, makes the bottle
    /// first: a clone of the engine's template from `template` (which builds it once if needed), else
    /// with wineboot (about 25 s under Rosetta). `phase` names each step for the waiting screen.
    /// Returns when the game process has started; with `watchInstalls`, it returns the programs that
    /// were in the bottle just before (to find what an installer adds).
    @discardableResult
    static func start(_ game: SteamGame, engine: InstalledEngine, profile: URL, arguments: [String] = [], isApp: Bool = false, log: LogFile,
                      template: (@MainActor () async -> URL?)? = nil, watchInstalls: Bool = false,
                      phase: @escaping @MainActor (String) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) async throws -> Set<String>? {
        guard let exe = game.localExe, FileManager.default.fileExists(atPath: exe.path) else {
            throw LocalGamesError.missing(game.localExe?.deletingLastPathComponent().path ?? game.name)
        }
        let pfx = prefix(game)
        try await ensureBottle(game, engine: engine, profile: profile, log: log, isApp: isApp, template: template, phase: phase)
        // Bottles made before Unwine 1.0.6 get the crash box turned off too. A cheap read when done.
        if !isRunning(game) { BottleFonts.ensure(prefix: pfx, quietCrashes: true) }
        // Read the profile now: the user may have changed settings while the bottle was made.
        var env = environment(engine: engine, prefix: pfx, profile: profile)
        // The game's Display choices (and, for D3DMetal, Apple's DLSS files) go into the closed bottle
        // now: Wine reads them when the game starts. An open bottle keeps what it has (BottlePrep).
        _ = await BottlePrep.apply(profile: profile, prefix: pfx, engine: engine, game: game.name, log: log, announce: phase)
        // A bottle that is open already (a Wine tool, the game's launcher) keeps its server's msync.
        // BottlePrep's regedit runs with the profile's own msync, so a server it leaves matches it.
        if let live = BottleTools.serverMsync(pfx), live != env["WINEMSYNC"] {
            log.line("The bottle is open with msync \(live == "1" ? "on" : "off"), so the game uses that until the bottle closes")
            env["WINEMSYNC"] = live
        }
        // The game runs from an app bundle that says "game", so macOS can give it Game Mode. A
        // bundle is only rebuilt while the bottle is closed: running processes use its files.
        await phase("Starting \(game.name)…")
        // Programs that share a bottle each keep their own app, with their own name.
        let bundle = game.compatData.appendingPathComponent(game.bottleID == nil ? "Game.app" : "Game-\(game.id).app", isDirectory: true)
        let loader: URL
        if isRunning(game) {
            loader = GameModeBundle.matches(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name, isGame: !isApp)
                ? GameModeBundle.loader(bundle) : engine.wine
        } else {
            loader = GameModeBundle.ensure(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name, isGame: !isApp,
                                           icon: ArtCache.iconFile(game.id), log: log) ?? engine.wine
        }
        // A closed bottle starts its Windows session first (wineboot --init), and wineboot looks up the
        // Mac's own name (Name.local). macOS lets an app bundle do that only with Local Network access,
        // so from the bundle the lookup waits 35 s and fails. Wine's own loader is not an app bundle and
        // gets the answer at once: the session starts there, and the game joins it a moment later.
        // The installer's look at the bottle comes first: the session's server waits only about 3 s for
        // the game once the session is up.
        let before = watchInstalls ? installedPrograms(in: pfx) : nil
        if loader != engine.wine, !isRunning(game) {
            var session = withoutX87(env)
            session["WINELOADER"] = engine.wine.path
            let started = Date()
            await startSession(engine: engine, env: session, cwd: pfx, log: log)
            log.line(String(format: "Started the bottle's Windows session in %.1f s", Date().timeIntervalSince(started)))
        }
        env["WINELOADER"] = loader.path
        log.line("Starting \(exe.path) from \(loader == engine.wine ? "the engine" : "its Game Mode app")"
                 + (arguments.isEmpty ? "" : " with \(arguments.count) launch option\(arguments.count == 1 ? "" : "s")"))
        // Faster x87 math: Wine starts x87sidecar for each process the game starts (ROSETTA_X87_PATH),
        // but the bundle's loader does not start itself again, so the game's first process needs
        // x87sidecar to start it. x87sidecar keeps this process ID for the game.
        var program = loader, args = [exe.path] + arguments
        if let x87 = env["ROSETTA_X87_PATH"], FileManager.default.isExecutableFile(atPath: x87) {
            program = URL(fileURLWithPath: x87)
            args.insert(loader.path, at: 0)
        }
        _ = try Shell.spawn(program, args, env: env, cwd: exe.deletingLastPathComponent(), log: log, onExit: onExit)
        return before
    }

    /// Starts the bottle's Windows session with a program that ends at once, and returns when it ends.
    /// The session's services inherit its output and write to the game's log while they run (Detailed
    /// logs shows their errors). Only the end of cmd is waited for, never the end of the output.
    /// The session's server stays a few seconds for the game.
    private static func startSession(engine: InstalledEngine, env: [String: String], cwd: URL, log: LogFile) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            do { _ = try Shell.spawn(engine.wine, ["cmd", "/c", "exit"], env: env, cwd: cwd, log: log, onExit: { _ in done.resume() }) }
            catch { done.resume() }
        }
    }

    /// Makes the game's bottle when it has none: a clone of the engine's template from `template`
    /// (which builds it once if needed), else with wineboot (about 25 s under Rosetta). `phase` names
    /// each step for the waiting screen. Does nothing for a bottle that is there.
    static func ensureBottle(_ game: SteamGame, engine: InstalledEngine, profile: URL, log: LogFile, isApp: Bool = false,
                             template: (@MainActor () async -> URL?)?, phase: @escaping @MainActor (String) -> Void) async throws {
        let pfx = prefix(game)
        let making = "Making a Windows bottle for this \(isApp ? "app" : "game")…"
        try Paths.ensure(game.compatData)

        // A folder that is there without a registry may hold files: wineboot finishes it in place.
        if !FileManager.default.fileExists(atPath: pfx.path), let template {
            await phase(BottleTemplate.ready(engine) == nil ? "Setting up Windows once for your added games and apps…" : making)
            if let source = await template() {
                await phase(making)
                do { try await BottleTemplate.clone(source, to: pfx, log: log) }
                catch { log.line("Could not copy the bottle template, so Wine makes the bottle: \(error.localizedDescription)") }
            }
        }
        if !FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) {
            await phase(making)
            log.line("Making the bottle for \(game.name)")
            let boot = withoutX87(environment(engine: engine, prefix: pfx, profile: profile))
            do {
                try await Shell.run(engine.wine, ["wineboot", "--init"], env: boot, log: log)
                try await Shell.run(engine.wineserver, ["-w"], env: boot, log: log, check: false)
            } catch {
                // A half-made bottle would be used as it is next time: it goes to the Trash.
                _ = try? await Shell.run(engine.wineserver, ["-k"], env: boot, log: log, check: false)
                try? FileManager.default.trashItem(at: pfx, resultingItemURL: nil)
                // The failed-start banner's Show logs opens this game's log.
                throw LocalGamesError.bottle("Wine stopped while it set up the bottle.")
            }
            guard FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) else {
                try? FileManager.default.trashItem(at: pfx, resultingItemURL: nil)
                throw LocalGamesError.bottle("Wine made no bottle.")
            }
            BottleFonts.ensure(prefix: pfx, quietCrashes: true)
        }
    }

    /// Ends everything running in the game's bottle.
    static func stop(_ game: SteamGame, engine: InstalledEngine, log: LogFile) async {
        var env = WineEnvironment.base(engine: engine, prefix: prefix(game))
        env["WINELOADER"] = engine.wine.path
        log.line("Stopping \(game.name)")
        _ = try? await Shell.run(engine.wineserver, ["-k"], env: env, log: log, check: false)
    }

    private static func bundleID(_ game: SteamGame) -> String { "app.unwine.game.\(game.id)" }
}

/// An app bundle that holds a whole copy of Wine's unix files (APFS clones, no extra space), so
/// every process of a bottle runs from inside it and macOS labels it a game. Wine 11 starts each new
/// process from the loader next to the real ntdll.so, so a bundle that only links ntdll.so loses
/// the game's own processes. Links next to the clones lead Wine to its Windows files and data.
enum GameModeBundle {
    static func loader(_ bundle: URL) -> URL { bundle.appendingPathComponent("Contents/MacOS/wine") }

    /// The icon a bundle shows in the Dock and Command-Tab: the game program's own, made when the
    /// bundle is built. An icon that turns up later waits for the next build.
    private static let iconName = "game.icns"

    /// An app's bundle says "productivity" and asks for no Game Mode: macOS gives Game Mode only to games.
    static func info(bundleID: String, name: String, icon: Bool, isGame: Bool = true) -> Data {
        let safe = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let iconKey = icon ? "\t<key>CFBundleIconFile</key>\n\t<string>\(iconName)</string>\n" : ""
        let gameMode = isGame ? "true" : "false"
        let category = isGame ? "public.app-category.games" : "public.app-category.productivity"
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>CFBundleExecutable</key>
            \t<string>wine</string>
            \(iconKey)\t<key>CFBundleIdentifier</key>
            \t<string>\(bundleID)</string>
            \t<key>CFBundleInfoDictionaryVersion</key>
            \t<string>6.0</string>
            \t<key>CFBundleName</key>
            \t<string>\(safe)</string>
            \t<key>CFBundlePackageType</key>
            \t<string>APPL</string>
            \t<key>GCSupportsGameMode</key>
            \t<\(gameMode)/>
            \t<key>LSApplicationCategoryType</key>
            \t<string>\(category)</string>
            \t<key>LSSupportsGameMode</key>
            \t<\(gameMode)/>
            \t<key>LSUIElement</key>
            \t<true/>
            \t<key>NSHighResolutionCapable</key>
            \t<true/>
            \t<key>NSPrincipalClass</key>
            \t<string>WineApplication</string>
            </dict>
            </plist>

            """.utf8)
    }

    private static func links(_ engine: InstalledEngine) -> [(path: String, target: String)] {
        let lib = engine.wineDir.appendingPathComponent("lib/wine", isDirectory: true)
        return [("Contents/MacOS/x86_64-unix", "."),
                ("Contents/MacOS/x86_64-windows", lib.appendingPathComponent("x86_64-windows").path),
                ("Contents/MacOS/i386-windows", RendererPatches.windowsDir("i386-windows", engine: engine).path),
                ("bin", engine.wineDir.appendingPathComponent("bin").path),
                ("share", engine.wineDir.appendingPathComponent("share").path)]
    }

    /// True when the bundle holds clones of this engine's files, its links and its Info.plist.
    static func matches(engine: InstalledEngine, bundle: URL, bundleID: String, name: String, isGame: Bool = true) -> Bool {
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        // With or without an icon: an icon alone is no reason to build the bundle again.
        let plist = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let want = try? fm.contentsOfDirectory(atPath: source.path), want.contains("wine"),
              let have = try? fm.contentsOfDirectory(atPath: macOS.path),
              plist == info(bundleID: bundleID, name: name, icon: false, isGame: isGame) || plist == info(bundleID: bundleID, name: name, icon: true, isGame: isGame)
        else { return false }
        let all = links(engine)
        guard Set(have) == Set(want).union(all.compactMap { $0.path.hasPrefix("Contents/MacOS/") ? String($0.path.dropFirst(15)) : nil })
        else { return false }
        for link in all {
            guard (try? fm.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent(link.path).path)) == link.target else { return false }
        }
        for name in want {
            var a = stat(), b = stat()
            guard lstat(macOS.appendingPathComponent(name).path, &a) == 0, lstat(source.appendingPathComponent(name).path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFREG, a.st_ino != b.st_ino, a.st_size == b.st_size,
                  a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec else { return false }
        }
        return true
    }

    /// The bundle's loader, building the bundle first when it is missing or out of date. Nil when
    /// it cannot be built; the caller then starts Wine from the engine (no Game Mode).
    /// `icon` is the PNG of the game program's icon; the bundle gets it as an .icns when it is built.
    static func ensure(engine: InstalledEngine, bundle: URL, bundleID: String, name: String, isGame: Bool = true, icon: URL? = nil, log: LogFile) -> URL? {
        if matches(engine: engine, bundle: bundle, bundleID: bundleID, name: name, isGame: isGame) { return loader(bundle) }
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let stage = bundle.deletingLastPathComponent().appendingPathComponent(".bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        do {
            let macOS = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try Paths.ensure(macOS)
            // Without an icon the Dock shows a blank app; a failed icon only costs the icon.
            var hasIcon = false
            if let icon, fm.fileExists(atPath: icon.path) {
                let resources = try Paths.ensure(stage.appendingPathComponent("Contents/Resources", isDirectory: true))
                hasIcon = ExeIcon.writeICNS(from: icon, to: resources.appendingPathComponent(iconName))
                if !hasIcon { log.line("Could not make the Dock icon for \(name), so its app has none") }
            }
            try info(bundleID: bundleID, name: name, icon: hasIcon, isGame: isGame).write(to: stage.appendingPathComponent("Contents/Info.plist"))
            for file in try fm.contentsOfDirectory(atPath: source.path) {
                let from = source.appendingPathComponent(file), to = macOS.appendingPathComponent(file)
                if clonefile(from.path, to.path, 0) != 0 { try fm.copyItem(at: from, to: to) }
            }
            for link in links(engine) {
                try fm.createSymbolicLink(atPath: stage.appendingPathComponent(link.path).path, withDestinationPath: link.target)
            }
            if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
            try fm.moveItem(at: stage, to: bundle)
        } catch {
            log.line("Could not make the Game Mode app, so the game starts without it: \(error.localizedDescription)")
            return nil
        }
        let lsregister = URL(fileURLWithPath:
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        let p = Process()
        p.executableURL = lsregister
        p.arguments = ["-f", bundle.path]
        try? p.run()
        p.waitUntilExit()
        log.line("Made the Game Mode app for \(name)")
        return loader(bundle)
    }
}
