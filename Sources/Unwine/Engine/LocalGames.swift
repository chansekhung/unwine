import Darwin
import Foundation

/// A Windows game or program the user added by its .exe. It runs without Steam, on Unwine's own
/// engine, in a Windows bottle of its own.
struct LocalGameRecord: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var exePath: String
    var addedAt: Date
}

enum LocalGamesError: LocalizedError {
    case missing(String)
    case bottle(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): return "The game's file is gone from \(path). Add it again from where it is now."
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
    /// layout as Steam's, so the bottle checks and "Fresh bottle" work for it too.
    static func game(from r: LocalGameRecord) -> SteamGame {
        let exe = URL(fileURLWithPath: r.exePath)
        return SteamGame(id: r.id, name: r.name, installDir: exe.deletingLastPathComponent(), steamapps: root,
                         sizeOnDisk: 0, state: .installed, lastPlayed: nil, isWindowsBuild: true, localExe: exe)
    }

    /// A readable name from the game's folder ("Romance_of_X_14" becomes "Romance of X 14").
    static func suggestedName(for exe: URL) -> String {
        let folder = exe.deletingLastPathComponent().lastPathComponent
        let base = folder.isEmpty || folder == "/" ? exe.deletingPathExtension().lastPathComponent : folder
        return base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func logName(_ id: Int) -> String { "local-\(id).log" }

    static func prefix(_ game: SteamGame) -> URL { game.compatData.appendingPathComponent("pfx", isDirectory: true) }

    static func isRunning(_ game: SteamGame) -> Bool { OnlineSteam.serverIsAlive(prefix(game)) }

    /// The variables the game starts with: the engine's base, the game's Unwine profile on top,
    /// and the Vulkan driver (the Steam path takes it from the runner's engine.env).
    static func environment(engine: InstalledEngine, prefix: URL, profile: URL) -> [String: String] {
        var env = WineEnvironment.base(engine: engine, prefix: prefix, debug: true)
        if let text = try? String(contentsOf: profile, encoding: .utf8) {
            for (key, raw) in OnlineSteam.profileAssignments(text) {
                if let value = OnlineSteam.shellWord(raw, env: env) { env[key] = value }
            }
        }
        let vulkan = RendererPatches.vulkanICD(engine: engine).path
        env["VK_DRIVER_FILES"] = vulkan
        env["VK_ICD_FILENAMES"] = vulkan
        return env
    }

    /// Starts the game. On its first start, makes the bottle first (a minute or two under Rosetta);
    /// `phase` names each step for the waiting screen. Returns when the game process has started.
    static func start(_ game: SteamGame, engine: InstalledEngine, profile: URL, log: LogFile,
                      phase: @escaping @MainActor (String) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) async throws {
        guard let exe = game.localExe, FileManager.default.fileExists(atPath: exe.path) else {
            throw LocalGamesError.missing(game.localExe?.deletingLastPathComponent().path ?? game.name)
        }
        let pfx = prefix(game)
        try Paths.ensure(game.compatData)
        var env = environment(engine: engine, prefix: pfx, profile: profile)

        if !FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) {
            await phase("Making a Windows bottle for this game…")
            log.line("Making the bottle for \(game.name)")
            do {
                try await Shell.run(engine.wine, ["wineboot", "--init"], env: env, log: log)
                try await Shell.run(engine.wineserver, ["-w"], env: env, log: log, check: false)
            } catch {
                throw LocalGamesError.bottle(error.localizedDescription)
            }
            guard FileManager.default.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) else {
                throw LocalGamesError.bottle("Wine made no bottle. The log has the details.")
            }
            BottleFonts.ensure(prefix: pfx)
        }

        // The game runs from an app bundle that says "game", so macOS can give it Game Mode. A
        // bundle is only rebuilt while the bottle is closed: running processes use its files.
        await phase("Starting \(game.name)…")
        let bundle = game.compatData.appendingPathComponent("Game.app", isDirectory: true)
        let loader: URL
        if isRunning(game) {
            loader = GameModeBundle.matches(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name)
                ? GameModeBundle.loader(bundle) : engine.wine
        } else {
            loader = GameModeBundle.ensure(engine: engine, bundle: bundle, bundleID: bundleID(game), name: game.name, log: log)
                ?? engine.wine
        }
        env["WINELOADER"] = loader.path
        log.line("Starting \(exe.path) from \(loader == engine.wine ? "the engine" : "its Game Mode app")")
        _ = try Shell.spawn(loader, [exe.path], env: env, cwd: exe.deletingLastPathComponent(), log: log, onExit: onExit)
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
                ("Contents/MacOS/i386-windows", lib.appendingPathComponent("i386-windows").path),
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
