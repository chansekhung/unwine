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
    }
}

enum LocalGamesError: LocalizedError {
    case missing(String)
    case bottle(String)

    var errorDescription: String? {
        switch self {
        // Adding it again would make a second entry with a new, empty bottle. The failed-start banner
        // and the game's page both have Locate….
        case .missing(let path): return "Its program is not in \(path) now. Press Locate… and pick it where it is now. Its bottle and saves stay."
        case .bottle(let why): return "Unwine could not make the game's Windows bottle: \(why)"
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

    /// Folders like bin, x64 or Binaries say nothing about the game. Program Files and drive_c are
    /// where an installer puts it.
    private static let generic: Set<String> = ["bin", "bin32", "bin64", "x64", "x86", "win32", "win64", "binaries", "game", "games",
                                               "release", "retail", "shipping", "debug", "system", "data", "downloads", "desktop", "documents",
                                               "program files", "program files (x86)", "drive_c"]

    /// A readable name from the game's folder ("Romance_of_X_14" becomes "Romance of X 14"): the game
    /// folder the user picked when it says something, else the program's folder or one above it.
    static func suggestedName(for exe: URL, root: URL? = nil) -> String {
        if let root, !generic.contains(root.lastPathComponent.lowercased()) {
            let name = root.lastPathComponent.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && name != "/" { return name }
        }
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<3 where generic.contains(dir.lastPathComponent.lowercased()) { dir = dir.deletingLastPathComponent() }
        let folder = dir.lastPathComponent
        let base = folder.isEmpty || folder == "/" || generic.contains(folder.lowercased())
            ? exe.deletingPathExtension().lastPathComponent : folder
        return base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

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

    /// Starts the game with `arguments` after its program's name. On its first start, makes the bottle
    /// first: a clone of the engine's template from `template` (which builds it once if needed), else
    /// with wineboot (about 25 s under Rosetta). `phase` names each step for the waiting screen.
    /// Returns when the game process has started; with `watchInstalls`, it returns the programs that
    /// were in the bottle just before (to find what an installer adds).
    @discardableResult
    static func start(_ game: SteamGame, engine: InstalledEngine, profile: URL, arguments: [String] = [], log: LogFile,
                      template: (@MainActor () async -> URL?)? = nil, watchInstalls: Bool = false,
                      phase: @escaping @MainActor (String) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) async throws -> Set<String>? {
        guard let exe = game.localExe, FileManager.default.fileExists(atPath: exe.path) else {
            throw LocalGamesError.missing(game.localExe?.deletingLastPathComponent().path ?? game.name)
        }
        let pfx = prefix(game)
        try Paths.ensure(game.compatData)
        var env = environment(engine: engine, prefix: pfx, profile: profile)

        // A folder that is there without a registry may hold files: wineboot finishes it in place.
        if !FileManager.default.fileExists(atPath: pfx.path), let template {
            await phase(BottleTemplate.ready(engine) == nil ? "Setting up Windows once for your added games…" : "Making a Windows bottle for this game…")
            if let source = await template() {
                await phase("Making a Windows bottle for this game…")
                do { try await BottleTemplate.clone(source, to: pfx, log: log) }
                catch { log.line("Could not copy the bottle template, so Wine makes the bottle: \(error.localizedDescription)") }
            }
        }
        if !FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) {
            await phase("Making a Windows bottle for this game…")
            log.line("Making the bottle for \(game.name)")
            do {
                try await Shell.run(engine.wine, ["wineboot", "--init"], env: env, log: log)
                try await Shell.run(engine.wineserver, ["-w"], env: env, log: log, check: false)
            } catch {
                // A half-made bottle would be used as it is next time: it goes to the Trash.
                _ = try? await Shell.run(engine.wineserver, ["-k"], env: env, log: log, check: false)
                try? FileManager.default.trashItem(at: pfx, resultingItemURL: nil)
                throw LocalGamesError.bottle("Wine stopped while it set up the bottle. Press Play to try again; if it fails again, Show logs on the game's page says why.")
            }
            guard FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) else {
                try? FileManager.default.trashItem(at: pfx, resultingItemURL: nil)
                throw LocalGamesError.bottle("Wine made no bottle. Press Play to try again; Show logs on the game's page says why.")
            }
            BottleFonts.ensure(prefix: pfx)
        }

        // Read the profile again now: the user may have changed settings while the bottle was made.
        env = environment(engine: engine, prefix: pfx, profile: profile)
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
            loader = GameModeBundle.matches(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name)
                ? GameModeBundle.loader(bundle) : engine.wine
        } else {
            loader = GameModeBundle.ensure(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name, log: log)
                ?? engine.wine
        }
        env["WINELOADER"] = loader.path
        let before = watchInstalls ? installedPrograms(in: pfx) : nil
        log.line("Starting \(exe.path) from \(loader == engine.wine ? "the engine" : "its Game Mode app")"
                 + (arguments.isEmpty ? "" : " with \(arguments.count) launch option\(arguments.count == 1 ? "" : "s")"))
        _ = try Shell.spawn(loader, [exe.path] + arguments, env: env, cwd: exe.deletingLastPathComponent(), log: log, onExit: onExit)
        return before
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

    private static func info(bundleID: String, name: String) -> Data {
        let safe = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>CFBundleExecutable</key>
            \t<string>wine</string>
            \t<key>CFBundleIdentifier</key>
            \t<string>\(bundleID)</string>
            \t<key>CFBundleInfoDictionaryVersion</key>
            \t<string>6.0</string>
            \t<key>CFBundleName</key>
            \t<string>\(safe)</string>
            \t<key>CFBundlePackageType</key>
            \t<string>APPL</string>
            \t<key>GCSupportsGameMode</key>
            \t<true/>
            \t<key>LSApplicationCategoryType</key>
            \t<string>public.app-category.games</string>
            \t<key>LSSupportsGameMode</key>
            \t<true/>
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
    static func matches(engine: InstalledEngine, bundle: URL, bundleID: String, name: String) -> Bool {
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard let want = try? fm.contentsOfDirectory(atPath: source.path), want.contains("wine"),
              let have = try? fm.contentsOfDirectory(atPath: macOS.path),
              (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))) == info(bundleID: bundleID, name: name)
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
    static func ensure(engine: InstalledEngine, bundle: URL, bundleID: String, name: String, log: LogFile) -> URL? {
        if matches(engine: engine, bundle: bundle, bundleID: bundleID, name: name) { return loader(bundle) }
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let stage = bundle.deletingLastPathComponent().appendingPathComponent(".bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        do {
            let macOS = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try Paths.ensure(macOS)
            try info(bundleID: bundleID, name: name).write(to: stage.appendingPathComponent("Contents/Info.plist"))
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
