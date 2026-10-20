import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Security

/// "Online mode": the Windows Steam client running inside Unwine's own Wine engine.
///
/// Games with Valve Anti-Cheat (VAC) need the Windows client, which Mac Steam's Steam Play cannot
/// give them. Running that client in Wine is how CrossOver gets them online. Windows Steam sees the
/// games Unwine shares with it through a library folder of Unwine's own, so nothing is downloaded twice.
///
/// It keeps a bottle of its own, apart from the per-game bottles Steam Play makes. Nothing here
/// touches Steam.app or writes into Mac Steam's library folders.
enum OnlineSteam {
    // MARK: Where things live

    static var root: URL { Paths.support.appendingPathComponent("OnlineSteam", isDirectory: true) }
    static var prefix: URL { root.appendingPathComponent("pfx", isDirectory: true) }
    static var steamDir: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true) }

    /// Unwine's own library folder for Windows Steam. It holds links to the Mac games it shares.
    private static var library: URL { root.appendingPathComponent("library", isDirectory: true) }
    private static var libraryApps: URL { library.appendingPathComponent("steamapps", isDirectory: true) }
    /// What `shareGames` made, so it only ever takes back its own links and manifests.
    private static var sharedRecord: URL { root.appendingPathComponent("shared-games.json") }

    private static let log = LogFile("online-steam.log")
    private static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#
    private static let steamFolder = #"C:\Program Files (x86)\Steam"#
    private static let state = OnlineState()

    // MARK: State

    /// Steam and its browser helper are both on disk. The helper arrives with the second update.
    static var isInstalled: Bool {
        find("steam.exe") != nil && find("bin/cef/cef.win64/steamwebhelper.exe") != nil
    }

    /// True for the whole of `install()`, seen from any thread. The Steam runs during setup are
    /// Unwine's own update passes, not Windows Steam being open.
    static var isInstalling: Bool { state.isInstalling }

    /// Windows Steam itself is running in this bottle. False while `install()` runs and for Unwine's
    /// `-shutdown` helper. A game left running without Steam does not count (see `runningGames`).
    /// Reads the process table, so call it off the main thread.
    static var isRunning: Bool {
        guard !isInstalling, isInUse else { return false }
        return bottleProcesses().map(\.commandLine).contains(where: isSteamClient)
    }

    /// True once something of the bottle shows a real window: Steam's sign-in or main window, or a
    /// game. Steam's window belongs to steamwebhelper, a Wine process of its own, and it shows up to a
    /// minute after steam.exe starts. Window owners and sizes need no screen-recording permission.
    static var hasWindow: Bool {
        let pids = Set(bottleProcesses().map(\.pid))
        guard !pids.isEmpty else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  w[kCGWindowLayer as String] as? Int == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: Double] else { return false }
            // Wine also keeps hidden helper windows and a thin menu-bar strip. A real window is bigger.
            return (bounds["Width"] ?? 0) >= 300 && (bounds["Height"] ?? 0) >= 200
        }
    }

    /// Anything of the bottle is running: Steam, a game, or a helper that is still quitting. Cheap.
    static var isInUse: Bool { serverIsAlive(prefix) }

    /// Steam kept a login for this bottle ("Remember my password" was ticked).
    static var isSignedIn: Bool {
        guard let file = find("config/loginusers.vdf"),
              let users = VDF.parse(contentsOf: file)?["users"] else { return false }
        return users.entries.contains { $0.value["RememberPassword"]?.string == "1" }
    }

    /// What setup downloads, for the text before it starts: Valve's 2.4 MB installer, then two full
    /// Steam updates (241,937 KB and 238,534 KB in Valve's logs on 19 Oct 2026).
    static let approximateDownloadMB = 490

    /// Windows programs alive in the bottle other than Steam's own and Wine's, as image names such as
    /// "left4dead2.exe". Runs the engine's tasklist in the bottle, so call it off the main thread.
    static func runningGames(engine: InstalledEngine) -> [String] {
        guard isInUse else { return [] }
        let loader = currentLoader(engine)
        let programs = programsInBottle(loader: loader, env: helperEnvironment(engine, loader: loader)) ?? []
        return names(of: programs.filter { isGame($0.name) })
    }

    // MARK: Install

    enum Phase: Equatable, Sendable {
        case preparing
        case downloading(Double?)   // Valve's installer, 0...1
        case installing             // the bottle, its settings and Steam's own installer
        case updating(Int)          // Steam's self-update, pass 1 or 2. Pass 2 brings the browser.
        case finishing
    }

    /// Sets up the bottle, installs Steam and lets it update itself. Safe to run again: when Steam is
    /// already there it skips the download and the installer, and only repairs the bottle and updates.
    /// If it fails or is cancelled, it stops whatever Wine it started.
    static func install(engine: InstalledEngine, progress: @escaping @Sendable (Phase) -> Void) async throws {
        guard state.beginInstall() else { throw OnlineSteamError.failed("Online mode is already being set up.") }
        defer { state.endInstall() }
        // Setup runs for minutes. Idle sleep would pause Wine and Steam's download.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Setting up Windows Steam")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        progress(.preparing)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: engine.wine.path), fm.isExecutableFile(atPath: engine.wineserver.path) else {
            throw EngineError.broken("Wine is missing.")
        }
        guard !isInUse else { throw OnlineSteamError.running }
        try Paths.ensure(root)
        try Paths.ensure(Paths.downloads)
        log.line("Setting up Online mode with \(engine.wineVersion)")
        do {
            try await setUp(engine: engine, progress: progress)
        } catch {
            log.line("Setup stopped: \(error.localizedDescription)")
            await stopBottle(engine)
            throw error
        }
    }

    private static func setUp(engine: InstalledEngine, progress: @escaping @Sendable (Phase) -> Void) async throws {
        let loader = gameModeLoader(engine)
        var env = makeEnvironment(engine: engine, profile: nil).env
        env["WINELOADER"] = loader.path
        state.session = env
        var setupEnv = env
        setupEnv["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"   // no menu entries or shortcuts from Wine

        var installer: URL?
        if find("steam.exe") == nil {
            installer = try await fetchInstaller { progress(.downloading($0)) }
        }
        try Task.checkCancellation()

        progress(.installing)
        try await prepareBottle(loader, engine, env: setupEnv)
        if let installer {
            log.line("Running Valve's Steam installer")
            // Its exit code means nothing. The check below is whether steam.exe is there.
            await run(loader, [installer.path, "/S"], env: setupEnv, timeout: .seconds(10 * 60))
            await run(engine.wineserver, ["-w"], env: setupEnv, timeout: .seconds(3 * 60))
        }
        try Task.checkCancellation()
        guard find("steam.exe") != nil else { throw OnlineSteamError.failed("Steam did not install. Try again.") }
        // The installer makes Steam start with Windows. That does nothing useful in Wine.
        await run(loader, ["reg", "delete", #"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"#, "/v", "Steam", "/f"],
                  env: env, timeout: .seconds(60))

        // Pass 1 updates the old 32-bit client. Pass 2 moves to the 64-bit one and fetches its browser.
        for pass in 1...2 {
            progress(.updating(pass))
            log.line("Steam update, pass \(pass) of 2")
            try finished(await run(loader, [steamExe, "-forcesteamupdate", "-exitsteam"], env: env, cwd: steamDir,
                                   timeout: .seconds(25 * 60)), "Steam's update")
            await run(engine.wineserver, ["-w"], env: env, timeout: .seconds(2 * 60))
            try Task.checkCancellation()
        }

        progress(.finishing)
        await settle(engine)
        guard isInstalled else { throw OnlineSteamError.failed("Steam did not finish updating. Try again.") }
        // Older Unwine builds listed Mac Steam's own library folders here.
        do { try updateLibraryList(unwineApps: nil) } catch { log.line("Could not tidy Steam's library list: \(error.localizedDescription)") }
        log.line("Online mode is ready")
    }

    /// Creates the bottle and writes its settings.
    private static func prepareBottle(_ loader: URL, _ engine: InstalledEngine, env: [String: String]) async throws {
        log.line("Preparing the Windows bottle")
        // `env` already carries the graphics layer variables. Wine needs them now, or winemetal.dll
        // never reaches the bottle's system folders.
        try finished(await run(loader, ["wineboot", "-u"], env: env, timeout: .seconds(10 * 60)), "Setting up the Windows bottle")
        await run(engine.wineserver, ["-w"], env: env, timeout: .seconds(3 * 60))
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw OnlineSteamError.failed("Wine could not set up its bottle. The log has the details.")
        }

        // A file next to the bottle's C: drive keeps the path free of spaces.
        let regFile = prefix.appendingPathComponent("drive_c/decant-settings.reg")
        try registrySettings().write(to: regFile)
        defer { try? FileManager.default.removeItem(at: regFile) }
        await run(loader, ["regedit", "/S", #"C:\decant-settings.reg"#], env: env, timeout: .seconds(2 * 60))
        await run(engine.wineserver, ["-w"], env: env, timeout: .seconds(3 * 60))   // Wine saves user.reg as the server quits
        let saved = (try? Data(contentsOf: prefix.appendingPathComponent("user.reg"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !saved.contains("\"RetinaMode\"=\"n\"") { log.line("Warning: the bottle's settings did not take.") }
    }

    /// The bottle's settings as a .reg file. Wine's regedit wants UTF-16 with a byte-order mark and CRLF
    /// line ends. The Mac driver values must be strings, never DWORDs.
    static func registrySettings() -> Data {
        let lines = [
            "Windows Registry Editor Version 5.00",
            "",
            "[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]",
            "\"RetinaMode\"=\"n\"",             // Steam draws at normal size, not doubled
            "\"LeftOptionIsAlt\"=\"y\"",
            "\"RightOptionIsAlt\"=\"y\"",
            "",
            "[HKEY_CURRENT_USER\\Software\\Wine\\WineDbg]",
            "\"ShowCrashDialog\"=dword:00000000",
            "",
            "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]",
            "\"winemenubuilder.exe\"=\"\"",
            "",
        ]
        return Data([0xFF, 0xFE]) + (lines.joined(separator: "\r\n").data(using: .utf16LittleEndian) ?? Data())
    }

    // MARK: Valve's installer

    private static let installerMirrors = [
        "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe",
        "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe",
        "https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe",
    ].compactMap { URL(string: $0) }
    private static let installerSize: Int64 = 2_380_800
    private static let installerSHA256 = "7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb"

    private static func fetchInstaller(progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let file = Paths.downloads.appendingPathComponent("SteamSetup.exe")
        if FileManager.default.fileExists(atPath: file.path), (try? checkInstaller(file)) != nil {
            log.line("Using the SteamSetup.exe that is already downloaded")
            progress(1)
            return file
        }
        var failure: Error?
        for mirror in installerMirrors {
            do {
                log.line("Downloading \(mirror.absoluteString)")
                _ = try await Downloader.fetch(mirror, to: file, expectedBytes: installerSize, progress: progress)
                try checkInstaller(file)
                return file
            } catch {
                if Task.isCancelled { throw error }
                failure = error
                log.line("That download was not used: \(error.localizedDescription)")
            }
        }
        throw failure ?? OnlineSteamError.badInstaller
    }

    /// Valve's installer has a known hash. When Valve replaces it, the new file is used only if it
    /// carries Valve's Authenticode signature over these exact bytes, through a certificate chain
    /// macOS trusts. Anything else is deleted unrun.
    private static func checkInstaller(_ file: URL) throws {
        let hash = try Downloader.sha256(of: file)
        if hash == installerSHA256 { return }
        let bytes = [UInt8](try Data(contentsOf: file))
        let problem = (1 << 20)...(20 << 20) ~= bytes.count
            ? Authenticode.problem(with: bytes, organization: "Valve Corp.")
            : "it is \(bytes.count) bytes"
        if let problem {
            log.line("Refused SteamSetup.exe (sha256 \(hash)): \(problem).")
            try? FileManager.default.removeItem(at: file)
            throw OnlineSteamError.failed("Valve's Steam installer did not pass its signature check, so Unwine did not run it. Try again later.")
        }
        log.line("SteamSetup.exe is newer than the copy Unwine knows (sha256 \(hash)). Valve's signature on it checks out.")
    }

    // MARK: Sharing games

    /// A game Windows Steam may see. Built from a SteamGame.
    struct SharedGame: Sendable, Equatable {
        let appID: Int
        let installDir: URL
        let steamapps: URL
    }

    /// Makes exactly these games visible to Windows Steam, through Unwine's own library folder: a link
    /// to each game's folder and a copy of its manifest, which Windows Steam then keeps up to date.
    /// Mac Steam's library folders are never listed and nothing is written into them, so Windows Steam
    /// cannot touch the Mac's own games. Only possible while Windows Steam is closed, because Steam
    /// rewrites its library list while it runs.
    static func shareGames(_ games: [SharedGame]) throws {
        guard !isRunning else { throw OnlineSteamError.running }
        let fm = FileManager.default
        let common = libraryApps.appendingPathComponent("common", isDirectory: true)
        try Paths.ensure(common)
        var record = (try? JSONDecoder().decode(SharedRecord.self, from: Data(contentsOf: sharedRecord))) ?? SharedRecord()
        var links = Set<String>(), manifests = Set<Int>()

        for game in games where !manifests.contains(game.appID) {
            let folder = game.installDir.lastPathComponent
            let manifest = "appmanifest_\(game.appID).acf"
            var isDir: ObjCBool = false
            guard !folder.isEmpty, folder != ".", folder != "..",
                  fm.fileExists(atPath: game.installDir.path, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: game.steamapps.appendingPathComponent(manifest).path) else {
                log.line("Not sharing app \(game.appID): its folder or manifest is missing.")
                continue
            }
            // Windows Steam installed this one itself. A second copy would confuse it.
            if fm.fileExists(atPath: steamDir.appendingPathComponent("steamapps/\(manifest)").path) { continue }

            let link = common.appendingPathComponent(folder)
            if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if target != game.installDir.path {
                    guard record.links.contains(folder) else {
                        log.line("Not sharing app \(game.appID): \(folder) already links somewhere else.")
                        continue
                    }
                    try fm.removeItem(at: link)
                    try fm.createSymbolicLink(at: link, withDestinationURL: game.installDir)
                }
            } else if fm.fileExists(atPath: link.path) {
                // A real folder: Windows Steam downloaded the game here. It is Windows Steam's now.
                record.links.removeAll { $0 == folder }
            } else {
                try fm.createSymbolicLink(at: link, withDestinationURL: game.installDir)
            }
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, !record.links.contains(folder) { record.links.append(folder) }
            links.insert(folder)

            let copy = libraryApps.appendingPathComponent(manifest)
            if !fm.fileExists(atPath: copy.path) {
                try fm.copyItem(at: game.steamapps.appendingPathComponent(manifest), to: copy)
                if !record.manifests.contains(game.appID) { record.manifests.append(game.appID) }
            }
            manifests.insert(game.appID)
        }

        // Take back what Unwine shared earlier for games that are not on the list now.
        for folder in record.links where !links.contains(folder) {
            let link = common.appendingPathComponent(folder)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { try? fm.removeItem(at: link) }
        }
        record.links.removeAll { !links.contains($0) }
        for id in record.manifests where !manifests.contains(id) {
            let copy = libraryApps.appendingPathComponent("appmanifest_\(id).acf")
            let folder = VDF.parse(contentsOf: copy)?["AppState", "installdir"]?.string
            let installed = folder.map { common.appendingPathComponent($0).path }
            // Keep the manifest of a game Windows Steam downloaded into this folder for real.
            if let installed, fm.fileExists(atPath: installed), (try? fm.destinationOfSymbolicLink(atPath: installed)) == nil { continue }
            try? fm.removeItem(at: copy)
        }
        record.manifests.removeAll { !manifests.contains($0) }
        try JSONEncoder.unwine.encode(record).write(to: sharedRecord, options: .atomic)

        // Steam lists each library's apps with their sizes. Every manifest here counts, Unwine's or not.
        let files = (try? fm.contentsOfDirectory(atPath: libraryApps.path)) ?? []
        let apps: [(id: String, size: String)] = files.sorted().compactMap { name in
            guard name.hasPrefix("appmanifest_"), name.hasSuffix(".acf"),
                  let state = VDF.parse(contentsOf: libraryApps.appendingPathComponent(name))?["AppState"],
                  let id = state["appid"]?.string else { return nil }
            return (id, state["SizeOnDisk"]?.string ?? "0")
        }
        try updateLibraryList(unwineApps: apps)
        log.line("Windows Steam can see \(manifests.count) shared game(s)")
    }

    private struct SharedRecord: Codable {
        var links: [String] = []      // folder names under steamapps/common
        var manifests: [Int] = []     // apps whose appmanifest Unwine copied
    }

    /// Rewrites Windows Steam's library list, steamapps/libraryfolders.vdf and the copy in config/ that
    /// Steam keeps the same. With `unwineApps`, Unwine's library is listed with those apps. Mac Steam's
    /// library folders are always taken out. Only while Steam is closed.
    private static func updateLibraryList(unwineApps: [(id: String, size: String)]?) throws {
        let files = [steamDir.appendingPathComponent("steamapps/libraryfolders.vdf"),
                     steamDir.appendingPathComponent("config/libraryfolders.vdf")]
        let existing = files.lazy.compactMap { VDF.parse(contentsOf: $0) }.first
        guard existing != nil || unwineApps != nil else { return }

        var decant: (path: String, contentID: String, apps: [(id: String, size: String)])?
        if let unwineApps {
            let path = windowsPath(of: library)
            let listed = existing?["libraryfolders"]?.entries.first { ($0.value["path"]?.string).map(normalized) == normalized(path) }
            let id = listed?.value["contentid"]?.string
                ?? VDF.parse(contentsOf: library.appendingPathComponent("libraryfolder.vdf"))?["libraryfolder", "contentid"]?.string
                ?? randomContentID()
            try markLibrary(id)
            decant = (path, id, unwineApps)
        }
        let text = libraryList(existing: existing, macLibraries: macLibraryPaths(), decant: decant)
        for file in files where (try? String(contentsOf: file, encoding: .utf8)) != text {
            try Paths.ensure(file.deletingLastPathComponent())
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Windows Steam's library list without any Mac Steam library, with Steam's own folder in it and,
    /// when `decant` is given, Unwine's library holding exactly `decant.apps`. Other entries keep their
    /// values. Libraries are renumbered from 0 in their old order.
    static func libraryList(existing: VDF?, macLibraries: [String],
                            decant: (path: String, contentID: String, apps: [(id: String, size: String)])?) -> String {
        var items = existing?["libraryfolders"]?.entries ?? []
        func isLibrary(_ item: (key: String, value: VDF)) -> Bool { Int(item.key) != nil }
        func pathOf(_ node: VDF) -> String? { node["path"]?.string ?? node.string }   // old files list bare paths
        func slot(of path: String) -> Int? {
            items.firstIndex { isLibrary($0) && pathOf($0.value).map(normalized) == normalized(path) }
        }
        func entry(_ path: String, _ id: String, _ apps: [(id: String, size: String)]) -> VDF {
            .object([("path", .string(path)), ("label", .string("")), ("contentid", .string(id)), ("totalsize", .string("0")),
                     ("apps", .object(apps.map { ($0.id, .string($0.size)) }))])
        }

        let mac = Set(macLibraries.map(normalized))
        items.removeAll { isLibrary($0) && pathOf($0.value).map { mac.contains(normalized($0)) } == true }
        if slot(of: steamFolder) == nil {
            let first = items.firstIndex(where: isLibrary) ?? items.count
            items.insert(("0", entry(steamFolder, randomContentID(), [])), at: first)
        }
        if let decant {
            if let i = slot(of: decant.path), case .object(var fields) = items[i].value {
                let apps = VDF.object(decant.apps.map { ($0.id, .string($0.size)) })
                if let a = fields.firstIndex(where: { $0.key.caseInsensitiveCompare("apps") == .orderedSame }) { fields[a].value = apps }
                else { fields.append(("apps", apps)) }
                items[i].value = .object(fields)
            } else if let i = slot(of: decant.path) {
                items[i].value = entry(decant.path, decant.contentID, decant.apps)
            } else {
                items.append(("\(Int.max)", entry(decant.path, decant.contentID, decant.apps)))
            }
        }
        var next = 0
        for i in items.indices where isLibrary(items[i]) {
            items[i].key = String(next)
            next += 1
        }
        return "\"libraryfolders\"\n{\n" + vdfLines(items, depth: 1) + "}\n"
    }

    /// Steam marks each library folder with a small file that holds its ID. Unwine writes it both at the
    /// top of its folder and in steamapps/, because Steam versions differ on where they look.
    private static func markLibrary(_ id: String) throws {
        let text = "\"libraryfolder\"\n{\n" + vdfLines([("contentid", .string(id)), ("label", .string(""))], depth: 1) + "}\n"
        for file in [library.appendingPathComponent("libraryfolder.vdf"), libraryApps.appendingPathComponent("libraryfolder.vdf")]
        where (try? String(contentsOf: file, encoding: .utf8)) != text {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Mac Steam's library folders as Windows sees them, listed or not, present or not.
    private static func macLibraryPaths() -> [String] {
        var roots = [SteamPlayPaths.steamData.path]
        let listed = VDF.parse(contentsOf: SteamLibrary.mainSteamapps.appendingPathComponent("libraryfolders.vdf"))?["libraryfolders"]?.entries ?? []
        for (_, entry) in listed { if let path = entry["path"]?.string ?? entry.string { roots.append(path) } }
        roots += SteamLibrary.steamappsFolders().map { $0.deletingLastPathComponent().path }
        return roots.map { windowsPath(of: URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    /// Steam's own layout: tabs, and two tabs between a key and its value.
    private static func vdfLines(_ items: [(key: String, value: VDF)], depth: Int) -> String {
        let tabs = String(repeating: "\t", count: depth)
        var out = ""
        for (key, value) in items {
            switch value {
            case .string(let text):
                out += "\(tabs)\(quoted(key))\t\t\(quoted(text))\n"
            case .object(let children):
                out += "\(tabs)\(quoted(key))\n\(tabs){\n\(vdfLines(children, depth: depth + 1))\(tabs)}\n"
            }
        }
        return out
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for c in text {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// Windows paths compare without regard to case, slash direction or a trailing slash.
    private static func normalized(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "/", with: "\\").lowercased()
        while p.hasSuffix("\\") { p.removeLast() }
        return p
    }

    /// Wine maps Z: to the Mac's whole disk.
    private static func windowsPath(of mac: URL) -> String { "Z:" + mac.path.replacingOccurrences(of: "/", with: "\\") }

    private static func randomContentID() -> String { String(Int64.random(in: 1...Int64.max)) }

    // MARK: Environment

    /// What every Wine process of this bottle runs with. Games that Windows Steam starts inherit Steam's
    /// environment, so a game's Unwine profile goes in here, and Steam is started with it. A game started
    /// into a Steam that is already running keeps that Steam's environment: restart Steam to change it.
    static func environment(engine: InstalledEngine, profile: URL?) -> [String: String] {
        makeEnvironment(engine: engine, profile: profile).env
    }

    /// A stable SHA-256 of `environment(engine:profile:)`, to tell later whether Steam needs a restart.
    static func environmentHash(engine: InstalledEngine, profile: URL?) -> String {
        let env = environment(engine: engine, profile: profile)
        var hasher = SHA256()
        for key in env.keys.sorted() { hasher.update(data: Data("\(key)=\(env[key] ?? "")\0".utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Plain notes on how Online mode treats a game's settings, for the game's sheet.
    static func notes(engine: InstalledEngine, profile: URL?) -> [String] {
        makeEnvironment(engine: engine, profile: profile).notes
    }

    private static func makeEnvironment(engine: InstalledEngine, profile: URL?) -> (env: [String: String], notes: [String]) {
        var env = WineEnvironment.base(engine: engine, prefix: prefix)
        env["WINELOADER"] = bundleLoader.path
        let identity = env.filter { ["WINEPREFIX", "WINESERVER", "WINELOADER"].contains($0.key) }
        var notes: [String] = []

        // Steam's own windows (Chromium) draw only on DXMT. On D3DMetal they stay black.
        env["WINEDLLPATH_DXMT"] = engine.renderer("dxmt").path
        env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1"
        if engine.supports("WINEDLLPATH_D9VK") { env["WINEDLLPATH_D9VK"] = engine.renderer("d9vk").path }
        if engine.supports("WINEDLLPATH_CNCD") { env["WINEDLLPATH_CNCD"] = engine.renderer("cnc_ddraw").path }
        // KosmicKrisp is a full Vulkan driver on Apple chips. MoltenVK lacks features DXVK 3 needs.
        let icd = engine.runtime.appendingPathComponent("Resources/vulkan/icd.d", isDirectory: true)
        let kosmic = icd.appendingPathComponent("kosmickrisp_mesa_icd.json")
        let vulkan = FileManager.default.fileExists(atPath: kosmic.path) ? kosmic : icd.appendingPathComponent("MoltenVK_icd.json")
        env["VK_DRIVER_FILES"] = vulkan.path
        env["VK_ICD_FILENAMES"] = vulkan.path
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["WINEMSYNC"] = "1"

        if let profile {
            if let text = try? String(contentsOf: profile, encoding: .utf8) {
                let keys = Set(profileAssignments(text).map(\.key))
                let applied = apply(text, to: &env)
                if applied.dropped {
                    let layer = keys.contains("WINEDLLPATH_D3DMETAL") ? "D3DMetal" : "DXVK"
                    notes.append("Online mode runs this game on DXMT, not \(layer). Windows Steam's own windows need DXMT, and the game inherits Steam's settings.")
                } else if keys.isDisjoint(with: ["WINEDLLPATH_DXMT", "WINEDLLPATH_D3DMETAL", "WINEDLLPATH_DXVK"]) {
                    notes.append("Online mode runs this game on DXMT, not WineD3D. Windows Steam's own windows need DXMT.")
                }
                if !applied.skipped.isEmpty {
                    notes.append("Unwine skipped profile lines it cannot read: \(applied.skipped.joined(separator: ", ")).")
                }
                if dxmtCaps(env) { notes.append("The frame cap also applies to Windows Steam's own windows.") }
                if env["MTL_HUD_ENABLED"] == "1" { notes.append("The Metal HUD also shows on Windows Steam's own windows.") }
                if env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1" { notes.append("MetalFX upscaling also applies to Windows Steam's own windows.") }
            } else {
                notes.append("No profile at \(profile.lastPathComponent). Steam starts with the default settings.")
            }
        }

        // Wine refuses a process whose msync setting differs from the server's, so the game's choice
        // holds for the whole bottle. Steam restarts when it changes.
        env["WINEMSYNC"] = engine.supportsMsync && env["WINEMSYNC"] != "0" ? "1" : "0"
        env.merge(identity) { _, mine in mine }
        return (env, notes)
    }

    /// DXMT draws Steam's windows too, so its frame cap holds for them.
    private static func dxmtCaps(_ env: [String: String]) -> Bool {
        if env["DXMT_CONFIG"]?.contains("preferredMaxFrameRate") == true { return true }
        guard let file = env["DXMT_CONFIG_FILE"], let text = try? String(contentsOfFile: file, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.contains("preferredMaxFrameRate")
        }
    }

    /// Applies the `export KEY='value'` lines of an Unwine profile (see `Profiles.render`) over `env`.
    /// Steam's own window draws only with DXMT, and every game Steam starts inherits Steam's
    /// environment. So a D3DMetal profile loses its D3DMetal lines (and the DYLD line that only adds
    /// D3DMetal's folder), and a DXVK profile loses its DXVK folder, which the engine would load
    /// ahead of DXMT. DXVK's DirectX 9 layer (D9VK) stays. A dropped frame cap becomes DXMT's, unless
    /// the profile already gives DXMT one. Lines Unwine cannot read are skipped. Returns true when
    /// lines were dropped.
    @discardableResult
    static func applyProfile(_ text: String, to env: inout [String: String]) -> Bool {
        let applied = apply(text, to: &env)
        for key in applied.skipped { log.line("Skipped a profile line Unwine cannot read: \(key)") }
        return applied.dropped
    }

    /// `applyProfile` without the log, which `environment()` would repeat on every call. `skipped`
    /// names the lines Unwine could not read.
    private static func apply(_ text: String, to env: inout [String: String]) -> (dropped: Bool, skipped: [String]) {
        let items = profileAssignments(text)
        let usesD3DMetal = items.contains { $0.key == "WINEDLLPATH_D3DMETAL" }
        let usesDXVK = items.contains { $0.key == "WINEDLLPATH_DXVK" }
        var cap: Int?
        var skipped: [String] = []
        for (key, raw) in items {
            let dropped = (usesD3DMetal && (key == "WINEDLLPATH_D3DMETAL" || key == "CX_APPLEGPTK_LIBD3DSHARED_PATH"
                                            || key.hasPrefix("D3DM_") || key == "DYLD_FALLBACK_LIBRARY_PATH"))
                || (usesDXVK && (key == "WINEDLLPATH_DXVK" || key == "DXVK_ASYNC" || key == "DXVK_FRAME_RATE"))
            guard let value = shellWord(raw, env: env) else {
                skipped.append(key)
                continue
            }
            if dropped {
                if key == "D3DM_MAX_FPS" || key == "DXVK_FRAME_RATE", let n = Int(value), n > 0 { cap = n }
                continue
            }
            env[key] = value
        }
        if let cap, env["DXMT_CONFIG"] == nil, env["DXMT_CONFIG_FILE"] == nil {
            env["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=\(cap);"
        }
        return (usesD3DMetal || usesDXVK, skipped)
    }

    /// The `KEY=value` pairs of a profile, in file order. Comments, blank lines and anything else are skipped.
    static func profileAssignments(_ text: String) -> [(key: String, raw: String)] {
        var out: [(key: String, raw: String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("export ") { s = String(s.dropFirst(7)) }
            guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            guard let first = key.first, first.isLetter || first == "_",
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
            out.append((key, String(s[s.index(after: eq)...])))
        }
        return out
    }

    /// Reads one shell word the way `sh` does: 'single', "double" and bare parts joined together, with
    /// $NAME, ${NAME}, ${NAME:-word} and ${NAME:+word} looked up in `env` (the word taken as it is).
    /// Profiles quote with '\'' for an apostrophe and write a DYLD line like 'folder':"$DYLD_FALLBACK_LIBRARY_PATH".
    /// Returns nil for anything else sh would expand or run, and for a quote that never closes, so such a
    /// line is skipped rather than copied as it stands.
    static func shellWord(_ raw: String, env: [String: String]) -> String? {
        let c = Array(raw)
        var out = ""
        var i = 0
        func name(from start: Int) -> (name: String, next: Int)? {
            var j = start
            while j < c.count, c[j].isASCII, c[j].isLetter || c[j] == "_" || (c[j].isNumber && j > start) { j += 1 }
            return j > start ? (String(c[start..<j]), j) : nil
        }
        /// The `$` expansion at `start` and the index after it, or nil when Unwine does not support it.
        func expansion(at start: Int) -> (value: String, next: Int)? {
            guard start + 1 < c.count else { return nil }
            guard c[start + 1] == "{" else {
                guard let plain = name(from: start + 1) else { return nil }
                return (env[plain.name] ?? "", plain.next)
            }
            guard let braced = name(from: start + 2), braced.next < c.count else { return nil }
            let value = env[braced.name] ?? ""
            let j = braced.next
            if c[j] == "}" { return (value, j + 1) }
            guard j + 1 < c.count, c[j] == ":", c[j + 1] == "-" || c[j + 1] == "+",
                  let close = c[(j + 2)...].firstIndex(of: "}") else { return nil }
            let word = c[(j + 2)..<close]
            guard !word.contains(where: { "$`\\\"'{".contains($0) }) else { return nil }
            if c[j + 1] == "-" { return (value.isEmpty ? String(word) : value, close + 1) }
            return (value.isEmpty ? "" : String(word), close + 1)
        }
        while i < c.count {
            switch c[i] {
            case "'":
                guard let end = c[(i + 1)...].firstIndex(of: "'") else { return nil }
                out += String(c[(i + 1)..<end])
                i = end + 1
            case "\"":
                i += 1
                var closed = false
                while i < c.count {
                    if c[i] == "\"" { closed = true; i += 1; break }
                    if c[i] == "`" { return nil }
                    if c[i] == "\\", i + 1 < c.count, "\"\\$`".contains(c[i + 1]) { out.append(c[i + 1]); i += 2; continue }
                    if c[i] == "$" {
                        guard let v = expansion(at: i) else { return nil }
                        out += v.value
                        i = v.next
                        continue
                    }
                    out.append(c[i])
                    i += 1
                }
                if !closed { return nil }
            case "\\":
                guard i + 1 < c.count else { return nil }
                out.append(c[i + 1])
                i += 2
            case "$":
                guard let v = expansion(at: i) else { return nil }
                out += v.value
                i = v.next
            case "`", ";", "&", "|", "<", ">", "(", ")":
                return nil          // a command, not a value
            case "~" where i == 0 || c[i - 1] == ":":
                return nil          // a home folder expansion
            case " ", "\t":
                return out          // an unquoted space ends the value
            default:
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Game Mode

    /// macOS gives Game Mode only to apps that say they are games, and Wine's loader is a bare
    /// executable. So Online mode starts Wine from an app bundle of its own: a hard link of the
    /// engine's loader, its other files as links, and an Info.plist that says "game".
    ///
    /// Wine 11 starts each new process from the loader next to the real ntdll.so (`init_paths` in
    /// ntdll's unix/loader.c) and never reads WINELOADER. So only the processes Unwine starts itself,
    /// such as steam.exe, run from this bundle; the programs Steam starts run from the engine. Putting
    /// a real ntdll.so in the bundle moves them too, but then Wine looks for its other folders next to
    /// the bundle, and in tests under Rosetta its processes hung.
    static var appBundle: URL { root.appendingPathComponent("Steam (Unwine).app", isDirectory: true) }
    private static var bundleLoader: URL { appBundle.appendingPathComponent("Contents/MacOS/wine") }
    private static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    /// Wine's own Info.plist keys (a background app until it shows a window), plus the game ones.
    private static let bundleInfo = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleAllowMixedLocalizations</key>
        \t<true/>
        \t<key>CFBundleExecutable</key>
        \t<string>wine</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>app.unwine.online-steam</string>
        \t<key>CFBundleInfoDictionaryVersion</key>
        \t<string>6.0</string>
        \t<key>CFBundleName</key>
        \t<string>Steam (Unwine)</string>
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

    /// The loader to start Wine with. Builds the bundle for `engine` when it is missing or was made
    /// from another engine; uses the engine's own loader when that is not possible.
    private static func gameModeLoader(_ engine: InstalledEngine) -> URL {
        if bundleMatches(engine) { return bundleLoader }
        // Processes still running from an older bundle would start new ones from a changed one.
        guard !isInUse else {
            log.line("The Game Mode app is out of date and the bottle is open, so Wine starts without it.")
            return engine.wine
        }
        do {
            try buildBundle(engine)
            return bundleLoader
        } catch {
            log.line("Could not make the Game Mode app, so Wine starts without it: \(error.localizedDescription)")
            return engine.wine
        }
    }

    /// The loader the bottle runs from now, for helpers. Never builds anything.
    private static func currentLoader(_ engine: InstalledEngine) -> URL {
        bundleMatches(engine) ? bundleLoader : engine.wine
    }

    private static func bundleMatches(_ engine: InstalledEngine) -> Bool {
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let macOS = appBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard let want = try? fm.contentsOfDirectory(atPath: source.path), want.contains("wine"),
              let have = try? fm.contentsOfDirectory(atPath: macOS.path), Set(want) == Set(have),
              (try? Data(contentsOf: appBundle.appendingPathComponent("Contents/Info.plist"))) == bundleInfo else { return false }
        for name in want where name != "wine" {
            let target = try? fm.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent(name).path)
            guard target == source.appendingPathComponent(name).path else { return false }
        }
        let loader = macOS.appendingPathComponent("wine"), original = source.appendingPathComponent("wine")
        var a = stat(), b = stat()
        guard lstat(loader.path, &a) == 0, stat(original.path, &b) == 0, a.st_mode & S_IFMT == S_IFREG else { return false }
        if a.st_dev == b.st_dev && a.st_ino == b.st_ino { return true }
        return (try? Data(contentsOf: loader)) == (try? Data(contentsOf: original))   // the copy made when linking failed
    }

    /// Builds the bundle in a staging folder and swaps it in, then tells Launch Services about it.
    private static func buildBundle(_ engine: InstalledEngine) throws {
        let fm = FileManager.default
        let source = engine.wineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try Paths.ensure(root)
        let stage = root.appendingPathComponent(".bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let macOS = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try Paths.ensure(macOS)
        try bundleInfo.write(to: stage.appendingPathComponent("Contents/Info.plist"))
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name), to = macOS.appendingPathComponent(name)
            if name == "wine" {
                // A real file: macOS finds a process's app from where its executable lives.
                do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
            } else {
                // Links, so the loader finds the engine's ntdll.so and Wine its other folders.
                try fm.createSymbolicLink(at: to, withDestinationURL: from)
            }
        }
        if (try? appBundle.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: appBundle.path)) != nil {
            try fm.removeItem(at: appBundle)
        }
        try fm.moveItem(at: stage, to: appBundle)
        let registered = runAndWait(lsregister, ["-f", appBundle.path], env: nil, timeout: 20).status
        log.line("Made the Game Mode app for \(engine.folder)" + (registered == 0 ? "" : " (Launch Services did not take it)"))
    }

    // MARK: Start and stop

    /// Starts Windows Steam in its bottle with `engine`. `profile` is a game's Unwine .env file (or nil).
    /// With `appID`, Steam also starts that game; if Steam was already running, it forwards the request
    /// and this process ends at once. Closes nothing: Mac Steam and Windows Steam on one account would
    /// sign each other out, so quit Mac Steam first. Call `shareGames` first so Steam sees the games.
    @discardableResult
    static func start(engine: InstalledEngine, profile: URL?, appID: Int? = nil, silent: Bool = false,
                      onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        guard isInstalled else { throw OnlineSteamError.notInstalled }
        guard !isInstalling else { throw OnlineSteamError.failed("Online mode is still being set up. Try again when it finishes.") }
        let running = isRunning
        if !running {
            // Only safe while Steam is closed.
            removeBrowserLocks()
            do { try updateLibraryList(unwineApps: nil) } catch { log.line("Could not tidy Steam's library list: \(error.localizedDescription)") }
        }
        let loader = gameModeLoader(engine)
        let made = makeEnvironment(engine: engine, profile: profile)
        var env = made.env
        env["WINELOADER"] = loader.path
        // Wine refuses a process whose msync setting differs from the server that is still running.
        if let live = serverMsync(), live != env["WINEMSYNC"] {
            log.line("The bottle is still open with msync \(live == "1" ? "on" : "off"), so Steam keeps that until it closes.")
            env["WINEMSYNC"] = live
        }
        for note in made.notes { log.line(note) }
        var args = [steamExe]
        if silent { args.append("-silent") }
        if let appID { args += ["-applaunch", String(appID)] }
        let process = try Shell.spawn(loader, args, env: env, cwd: steamDir, log: log, onExit: onExit)
        if !running { state.session = env }
        return process
    }

    enum ShutdownResult: Equatable, Sendable {
        case stopped
        case gamesRunning([String])
    }

    /// Closes Windows Steam. While a game runs in the bottle it does nothing and names the games, unless
    /// `force` is set: then it asks each game to close and gives them 20 seconds. Then it asks Steam to
    /// quit and waits up to three minutes, because Steam syncs cloud saves while it closes, and ends
    /// whatever is left. It does not stop early when the task is cancelled: cutting it short is how
    /// saves get lost.
    static func shutdown(engine: InstalledEngine, force: Bool) async -> ShutdownResult {
        guard isInUse else {
            state.session = nil
            return .stopped
        }
        let loader = currentLoader(engine)
        let env = helperEnvironment(engine, loader: loader)
        let games = (await programsInBottleAsync(loader: loader, env: env) ?? []).filter { isGame($0.name) }
        if !games.isEmpty {
            let running = names(of: games)
            guard force else {
                log.line("Not closing Windows Steam: \(running.joined(separator: ", ")) still running")
                return .gamesRunning(running)
            }
            log.line("Asking \(running.joined(separator: ", ")) to close")
            // Without /F, taskkill asks a program's windows to close, as their close button does.
            await run(loader, ["taskkill.exe"] + games.flatMap { ["/pid", String($0.pid)] }, env: env,
                      timeout: .seconds(30), cancellable: false)
            let clock = SuspendingClock()
            let deadline = clock.now.advanced(by: .seconds(20))
            while clock.now < deadline {
                await pause(1000)
                guard let left = await programsInBottleAsync(loader: loader, env: env), left.contains(where: { isGame($0.name) }) else { break }
            }
        }
        if isRunning {
            log.line("Asking Windows Steam to quit")
            await run(loader, [steamExe, "-shutdown"], env: env, cwd: steamDir, timeout: .seconds(60), cancellable: false)
            let clock = SuspendingClock()
            let deadline = clock.now.advanced(by: .seconds(180))
            while isRunning, clock.now < deadline { await pause(1000) }
            if isRunning { log.line("Steam was still open after three minutes") }
        }
        await stopBottle(engine)
        return .stopped
    }

    /// Moves the whole Online mode folder to the Trash: the bottle, Windows Steam and its login, the saves
    /// and settings games kept in the bottle, and any game Windows Steam downloaded itself (see
    /// `bottleDataSizes`). Games shared from Mac Steam stay where they are; only Unwine's links to them go.
    static func remove() throws {
        guard !isInUse else { throw OnlineSteamError.running }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        _ = runAndWait(lsregister, ["-u", appBundle.path], env: nil, timeout: 20)
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        state.session = nil
        log.line("Moved Online mode to the Trash")
    }

    /// What `remove()` would also put in the Trash, in bytes: games Windows Steam downloaded into its own
    /// folders, and the saves and settings games keep in the bottle. Links to Mac games do not count.
    /// Walks folders, so call it off the main thread.
    static func bottleDataSizes() -> (games: Int64, saves: Int64) {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let games = size(of: steamDir.appendingPathComponent("steamapps", isDirectory: true)) + size(of: libraryApps)
        var saves = size(of: users) + size(of: steamDir.appendingPathComponent("userdata", isDirectory: true))
        // Steam's browser cache is not a save.
        for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            saves -= size(of: user.appendingPathComponent("AppData/Local/Steam", isDirectory: true))
        }
        return (games, max(0, saves))
    }

    /// Bytes in the files under `folder`. Links are not followed, so the Mac games and folders that
    /// Wine links to (Documents, Desktop) do not count.
    private static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Chromium leaves Singleton* lock files in Steam's browser cache when Wine is killed, and a stale one
    /// can stop the next browser from starting. Only call this while Steam is closed.
    private static func removeBrowserLocks() {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let cache = user.appendingPathComponent("AppData/Local/Steam/htmlcache", isDirectory: true)
            for item in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.lowercased().hasPrefix("singleton") {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Gives leftovers a moment to quit on their own, then closes the bottle.
    private static func settle(_ engine: InstalledEngine) async {
        for _ in 0..<60 where isInUse { await pause(500) }
        await stopBottle(engine)
    }

    /// `wineserver -k`: ends every process in the bottle. Not cancellable, so clean-up always finishes.
    private static func stopBottle(_ engine: InstalledEngine) async {
        defer { if !isInUse { state.session = nil } }
        guard isInUse else { return }
        log.line("Stopping the bottle")
        await run(engine.wineserver, ["-k"], env: helperEnvironment(engine, loader: currentLoader(engine)),
                  timeout: .seconds(30), cancellable: false)
        for _ in 0..<40 where isInUse { await pause(250) }
    }

    /// The environment for a helper (tasklist, taskkill, `-shutdown`, `wineserver -k`): the one the
    /// bottle's Steam was started with, or the default, with the running server's own msync setting.
    /// Wine refuses a process whose setting differs.
    private static func helperEnvironment(_ engine: InstalledEngine, loader: URL) -> [String: String] {
        var env = state.session ?? makeEnvironment(engine: engine, profile: nil).env
        env["WINELOADER"] = loader.path
        if let live = serverMsync() { env["WINEMSYNC"] = live }
        return env
    }

    // MARK: Looking at processes

    /// True when this command line is Windows Steam itself. Mac Steam's own games run through a stand-in
    /// `steam.exe` with the same name in their bottle; it is told which game to start, so a path
    /// follows its name. Windows Steam is given nothing, or options like -silent. Unwine's `-shutdown`
    /// helper only passes the request on to Steam, so it does not count.
    static func isSteamClient(_ commandLine: String) -> Bool {
        guard let hit = commandLine.range(of: #"\Steam\steam.exe"#, options: .caseInsensitive) else { return false }
        var rest = commandLine[hit.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if rest.hasPrefix("/") || rest.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return false }
        return !rest.split(separator: " ").contains { $0.caseInsensitiveCompare("-shutdown") == .orderedSame }
    }

    /// This bottle's processes and their command lines. Only the Online bottle runs Wine from Unwine's own
    /// engines or from its Game Mode app (Steam Play games run from the runner's copy), so a process's
    /// executable says which bottle it belongs to. Wine rewrites a process's arguments to its Windows
    /// command line.
    private static func bottleProcesses() -> [(pid: pid_t, commandLine: String)] {
        // Wine starts its processes from real paths, so links on the way are resolved first.
        let engines = (try? FileManager.default.contentsOfDirectory(at: Paths.engines, includingPropertiesForKeys: nil)) ?? []
        let homes = ([Paths.engines, appBundle] + engines).flatMap { [$0.path + "/", $0.resolvingSymlinksInPath().path + "/"] }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var out: [(pid: pid_t, commandLine: String)] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            // Cheap first look: Wine's processes all run a file named wine.
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0, String(decoding: path.prefix(length), as: UTF8.self).split(separator: "/").last?.hasPrefix("wine") == true,
                  let info = processArguments(pid), homes.contains(where: info.executable.hasPrefix) else { continue }
            out.append((pid, info.arguments.filter { !$0.isEmpty }.joined(separator: " ")))
        }
        return out
    }

    /// A process's executable path (as it was started), arguments and environment, from the kernel.
    /// Nil for another user's process.
    private static func processArguments(_ pid: pid_t) -> (executable: String, arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        func string() -> String {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buffer[start..<i], as: UTF8.self)
        }
        let executable = string()
        while i < size, buffer[i] == 0 { i += 1 }
        var arguments: [String] = []
        while arguments.count < argc, i < size { arguments.append(string()) }
        var environment: [String] = []
        while i < size, buffer[i] != 0 { environment.append(string()) }
        return (executable, arguments, environment)
    }

    /// Wine's server for a bottle holds a lock on a file in /tmp/.wine-<uid>/server-<device>-<inode> for as
    /// long as it lives. A killed server leaves its socket behind, so the lock, not the socket, says if it is alive.
    static func serverIsAlive(_ pfx: URL) -> Bool { serverPID(pfx) != nil }

    /// The process that holds the server lock: the bottle's wineserver.
    private static func serverPID(_ pfx: URL) -> pid_t? {
        var st = stat()
        guard stat(pfx.path, &st) == 0 else { return nil }
        let dir = String(format: "/tmp/.wine-%d/server-%llx-%llx", getuid(), UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        let fd = open(dir + "/lock", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }

    /// The WINEMSYNC value the bottle's running server was started with, read from its environment.
    private static func serverMsync() -> String? {
        guard let pid = serverPID(prefix), let info = processArguments(pid) else { return nil }
        let value = info.environment.first { $0.hasPrefix("WINEMSYNC=") }?.dropFirst("WINEMSYNC=".count)
        return value == nil || value == "0" ? "0" : "1"
    }

    private struct Program: Sendable {
        let name: String
        let pid: Int
    }

    /// The Windows programs in the bottle, from the engine's own tasklist. Nil when it did not answer.
    private static func programsInBottle(loader: URL, env: [String: String]) -> [Program]? {
        let result = runAndWait(loader, ["tasklist.exe", "/fo", "csv", "/nh"], env: env, timeout: 30)
        guard result.status == 0 else {
            log.line("tasklist did not answer (\(result.status.map { "code \($0)" } ?? "stopped")).")
            return nil
        }
        // Lines look like "steam.exe","300","Console","1","0 K".
        return result.output.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count > 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
            let fields = s.dropFirst().dropLast().components(separatedBy: "\",\"")
            guard fields.count >= 2, !fields[0].isEmpty, let pid = Int(fields[1]) else { return nil }
            return Program(name: fields[0], pid: pid)
        }
    }

    private static func programsInBottleAsync(loader: URL, env: [String: String]) async -> [Program]? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: programsInBottle(loader: loader, env: env)) }
        }
    }

    /// Steam's own programs and Wine's, which are not games.
    private static let notGames: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "gameoverlayui.exe", "gameoverlayui64.exe",
        "streaming_client.exe", "x86launcher.exe", "x64launcher.exe", "steamxboxutil.exe", "steamxboxutil64.exe",
        "services.exe", "winedevice.exe", "plugplay.exe", "explorer.exe", "rpcss.exe", "svchost.exe", "conhost.exe",
        "start.exe", "tasklist.exe", "taskkill.exe", "wineboot.exe", "winemenubuilder.exe", "rundll32.exe",
        "reg.exe", "regedit.exe", "winedbg.exe",
    ]

    private static func isGame(_ name: String) -> Bool {
        let n = name.lowercased()
        return !notGames.contains(n) && !n.hasPrefix("steamerrorreporter")
    }

    /// Each name once, in the order first seen.
    private static func names(of programs: [Program]) -> [String] {
        var seen = Set<String>()
        return programs.map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }

    /// A path inside Steam's folder, found without caring about letter case: Valve ships both Steam.exe
    /// and steam.exe, and a Mac disk can be case sensitive.
    private static func find(_ relative: String) -> URL? {
        let fm = FileManager.default
        var url = steamDir
        for part in relative.split(separator: "/").map(String.init) {
            let direct = url.appendingPathComponent(part)
            if fm.fileExists(atPath: direct.path) { url = direct; continue }
            guard let name = (try? fm.contentsOfDirectory(atPath: url.path))?.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame })
            else { return nil }
            url = url.appendingPathComponent(name)
        }
        return url
    }

    // MARK: Running Wine

    /// Runs one Wine tool to the end, with its output in the log. A tool that outlives `timeout`, or the
    /// task being cancelled, stops it. The clock skips time the Mac sleeps, since Wine sleeps too.
    /// Returns the exit code, or nil when the tool had to be stopped.
    @discardableResult
    private static func run(_ exe: URL, _ args: [String], env: [String: String], cwd: URL? = nil,
                            timeout: Duration, cancellable: Bool = true) async -> Int32? {
        let process: Process
        do {
            process = try Shell.spawn(exe, args, env: env, cwd: cwd, log: log)
        } catch {
            log.line("Could not start \(exe.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            let cancelled = cancellable && Task.isCancelled
            if cancelled || clock.now >= deadline {
                log.line(cancelled ? "Stopped \(exe.lastPathComponent)." : "\(exe.lastPathComponent) took too long and was stopped.")
                process.terminate()
                for _ in 0..<30 where process.isRunning { await pause(100) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
            await pause(250)
        }
        return process.terminationStatus
    }

    /// Runs a short tool to the end and returns its exit code and output, or a nil code when it outlived
    /// `timeout` seconds. Dispatch's clock also skips sleep. Blocks, so call it off the main thread.
    private static func runAndWait(_ exe: URL, _ args: [String], env: [String: String]?, timeout: Double) -> (status: Int32?, output: String) {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("decant-\(UUID().uuidString).txt")
        guard fm.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else { return (nil, "") }
        defer {
            try? handle.close()
            try? fm.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        if let env { process.environment = env }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            log.line("Could not start \(exe.lastPathComponent): \(error.localizedDescription)")
            return (nil, "")
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            log.line("\(args.first ?? exe.lastPathComponent) took too long and was stopped.")
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            return (nil, "")
        }
        return (process.terminationStatus, (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    /// A nil result from `run` means it was stopped. That is a cancel if the task was cancelled, a timeout if not.
    private static func finished(_ status: Int32?, _ what: String) throws {
        guard status == nil else { return }
        try Task.checkCancellation()
        throw OnlineSteamError.timedOut(what)
    }

    /// Sleeps for real even after the task was cancelled, where `Task.sleep` would return at once.
    private static func pause(_ milliseconds: UInt64) async {
        if Task.isCancelled {
            usleep(useconds_t(milliseconds * 1000))
        } else {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
    }
}

/// Online mode's process-wide state. Install, start and the status reads run on any thread.
private final class OnlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var installing = false
    private var launchEnvironment: [String: String]?

    var isInstalling: Bool { lock.withLock { installing } }

    /// Takes the install slot. False when another install holds it.
    func beginInstall() -> Bool {
        lock.withLock {
            guard !installing else { return false }
            installing = true
            return true
        }
    }

    func endInstall() { lock.withLock { installing = false } }

    /// The environment this run of Unwine started the bottle's server with, for later helpers.
    var session: [String: String]? {
        get { lock.withLock { launchEnvironment } }
        set { lock.withLock { launchEnvironment = newValue } }
    }
}

enum OnlineSteamError: LocalizedError {
    case notInstalled
    case running
    case badInstaller
    case failed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Online mode is not set up yet."
        case .running: return "Online Steam is still running. Quit it first."
        case .badInstaller: return "Valve's Steam installer did not download properly. Try again."
        case .failed(let why): return why
        case .timedOut(let what): return "\(what) took too long. Try again."
        }
    }
}

// MARK: - Authenticode

/// Checks a Windows program's Authenticode signature with Security.framework.
///
/// CMSDecoder does not take Authenticode's PKCS #7 as it is: the signed content is a bare SEQUENCE
/// rather than an OCTET STRING, and the timestamp countersignature in the unsigned attributes makes
/// it report a bad signature. So the message is rebuilt with the same signed bytes, the content
/// wrapped and the unsigned attributes left out, and the countersignature is checked on its own.
private enum Authenticode {
    /// Nil when `file` is signed by `organization` through a certificate chain macOS trusts, over
    /// exactly these bytes. Otherwise a short reason for the log.
    static func problem(with file: [UInt8], organization: String) -> String? {
        guard let layout = PELayout(file) else { return "it is not a signed Windows program" }
        let t = layout.table.lowerBound
        let length = Int(file[t]) | Int(file[t + 1]) << 8 | Int(file[t + 2]) << 16 | Int(file[t + 3]) << 24
        // WIN_CERTIFICATE: revision 2.0, type PKCS #7 signed data.
        guard file[t + 4] == 0x00, file[t + 5] == 0x02, file[t + 6] == 0x02, file[t + 7] == 0x00,
              length > 8, t + length <= layout.table.upperBound,
              let info = DER(file[(t + 8)..<(t + length)]), info.tag == 0x30 else { return "its signature is unreadable" }

        // ContentInfo { signedData, [0] SignedData { version, digests, content, [0] certificates, [1] crls, signers } }
        let top = info.children
        guard top.count == 2, Array(top[0].bytes) == OID.signedData, top[1].tag == 0xA0,
              let signed = top[1].children.first, signed.tag == 0x30 else { return "its signature is unreadable" }
        let parts = signed.children
        guard parts.count >= 4, parts[2].tag == 0x30, let signerSet = parts.last, signerSet.tag == 0x31 else { return "its signature is unreadable" }
        let content = parts[2].children
        guard content.count == 2, Array(content[0].bytes) == OID.spcIndirectData, content[1].tag == 0xA0,
              let indirect = content[1].children.first, indirect.tag == 0x30 else { return "it is not an Authenticode signature" }
        let signers = signerSet.children
        guard signers.count == 1, signers[0].tag == 0x30 else { return "it has more than one signer" }
        let signerParts = signers[0].children
        guard let signature = signerParts.first(where: { $0.tag == 0x04 }) else { return "its signature is unreadable" }

        // The signed digest of the file.
        let spc = indirect.children
        guard spc.count == 2, let dataType = spc[0].children.first, Array(dataType.bytes) == OID.peImageData else {
            return "it does not sign a Windows program"
        }
        let digestInfo = spc[1].children
        guard digestInfo.count == 2, let algorithm = digestInfo[0].children.first, digestInfo[1].tag == 0x04 else {
            return "its signed digest is unreadable"
        }
        let actual: [UInt8]
        switch Array(algorithm.bytes) {
        case OID.sha256: actual = layout.digest(of: file, using: SHA256.self)
        case OID.sha384: actual = layout.digest(of: file, using: SHA384.self)
        case OID.sha512: actual = layout.digest(of: file, using: SHA512.self)
        default: return "it uses a digest Unwine does not accept"
        }
        guard actual == Array(digestInfo[1].contents) else { return "the file was changed after it was signed" }

        // The signature over that digest.
        let wrapped = DER.encode(0x30, Array(content[0].bytes) + DER.encode(0xA0, DER.encode(0x04, Array(indirect.contents))))
        let signerInfo = DER.encode(0x30, signerParts.filter { $0.tag != 0xA1 }.flatMap { Array($0.bytes) })
        var body: [UInt8] = []
        for (k, part) in parts.enumerated() {
            body += k == 2 ? wrapped : k == parts.count - 1 ? DER.encode(0x31, signerInfo) : Array(part.bytes)
        }
        guard let check = verified(DER.encode(0x30, OID.signedData + DER.encode(0xA0, DER.encode(0x30, body)))),
              check.content == Array(indirect.contents) else { return "the signature does not match what it signs" }

        // The chain, at the time a timestamp authority vouches for, or now. Code signing certificates
        // expire long before the programs they signed.
        let certificates = parts.first { $0.tag == 0xA0 }
        let unsigned = signerParts.first { $0.tag == 0xA1 }
        let signedAt = unsigned.flatMap { timestamp(in: $0, signature: Array(signature.contents), certificates: certificates) }
        if let reason = trustProblem(check.trust, at: signedAt ?? Date()) { return "its certificate is not trusted (\(reason))" }
        guard let fields = certificateFields(check.signer), fields.organization == organization else {
            return "it is signed by \(certificateFields(check.signer)?.organization ?? "someone unknown"), not \(organization)"
        }
        guard allows(fields, OID.codeSigning) else { return "its certificate is not for signing programs" }
        return nil
    }

    /// The time in the first valid timestamp among the signer's unsigned attributes: the PKCS #9
    /// countersignature (signtool /t) or an RFC 3161 token (signtool /tr). Each must be signed over
    /// this signature by a timestamp authority macOS trusts.
    private static func timestamp(in unsigned: DER, signature: [UInt8], certificates: DER?) -> Date? {
        for attribute in unsigned.children where attribute.tag == 0x30 {
            let fields = attribute.children
            guard fields.count == 2, fields[1].tag == 0x31, let value = fields[1].children.first else { continue }
            let type = Array(fields[0].bytes)
            if type == OID.counterSignature, let date = counterSignatureTime(value, signature: signature, certificates: certificates) {
                return date
            }
            if type == OID.timeStampToken || type == OID.msTimeStampToken, let date = tokenTime(value, signature: signature) {
                return date
            }
        }
        return nil
    }

    /// A countersignature is a SignerInfo over the signature's bytes. Put into a SignedData of its own,
    /// with those bytes as the content, CMSDecoder can check it.
    private static func counterSignatureTime(_ counter: DER, signature: [UInt8], certificates: DER?) -> Date? {
        let fields = counter.children
        guard counter.tag == 0x30, fields.count >= 5, fields[2].tag == 0x30 else { return nil }
        var body: [UInt8] = [0x02, 0x01, 0x01] + DER.encode(0x31, Array(fields[2].bytes))
        body += DER.encode(0x30, OID.data + DER.encode(0xA0, DER.encode(0x04, signature)))
        if let certificates { body += Array(certificates.bytes) }
        body += DER.encode(0x31, Array(counter.bytes))
        guard let check = verified(DER.encode(0x30, OID.signedData + DER.encode(0xA0, DER.encode(0x30, body)))),
              check.content == signature else { return nil }
        var time: CFAbsoluteTime = 0
        guard CMSDecoderCopySignerSigningTime(check.decoder, 0, &time) == errSecSuccess else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: time)
        guard date <= Date(), trustProblem(check.trust, at: date) == nil,
              let tsa = certificateFields(check.signer), allows(tsa, OID.timeStamping) else { return nil }
        return date
    }

    /// An RFC 3161 token is a CMS message of its own; its TSTInfo holds the time and a hash of the signature.
    private static func tokenTime(_ token: DER, signature: [UInt8]) -> Date? {
        guard let check = verified(Array(token.bytes)), let info = DER(check.content[...]), info.tag == 0x30 else { return nil }
        let fields = info.children      // version, policy, messageImprint, serialNumber, genTime, ...
        guard fields.count >= 5, fields[2].tag == 0x30, fields[4].tag == 0x18 else { return nil }
        let imprint = fields[2].children
        guard imprint.count == 2, let algorithm = imprint[0].children.first, imprint[1].tag == 0x04 else { return nil }
        let expected: [UInt8]
        switch Array(algorithm.bytes) {
        case OID.sha1: expected = Array(Insecure.SHA1.hash(data: signature))
        case OID.sha256: expected = Array(SHA256.hash(data: signature))
        case OID.sha384: expected = Array(SHA384.hash(data: signature))
        case OID.sha512: expected = Array(SHA512.hash(data: signature))
        default: return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let text = String(decoding: fields[4].contents, as: UTF8.self)
        guard expected == Array(imprint[1].contents), text.hasSuffix("Z"), let date = formatter.date(from: String(text.prefix(14))),
              date <= Date(), trustProblem(check.trust, at: date) == nil,
              let tsa = certificateFields(check.signer), allows(tsa, OID.timeStamping) else { return nil }
        return date
    }

    /// Decodes a CMS message and checks its one signature over its content. The certificate chain is
    /// left for the caller to judge, at the date it picks.
    private static func verified(_ message: [UInt8]) -> (decoder: CMSDecoder, signer: SecCertificate, content: [UInt8], trust: SecTrust)? {
        var made: CMSDecoder?
        guard !message.isEmpty, CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else { return nil }
        let fed = message.withUnsafeBufferPointer { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard fed == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var signers = 0
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers == 1,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust, nil) == errSecSuccess,
              status == .valid, let trust else { return nil }
        var signer: SecCertificate?
        var content: CFData?
        guard CMSDecoderCopySignerCert(decoder, 0, &signer) == errSecSuccess, let signer,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return (decoder, signer, [UInt8](content as Data), trust)
    }

    /// Nil when the chain holds at `date`, else macOS's reason.
    private static func trustProblem(_ trust: SecTrust, at date: Date) -> String? {
        guard SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { return "the date could not be set" }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { CFErrorCopyDescription($0) as String } ?? "no reason given"
    }

    /// A certificate's subject organization and its extended key usages (nil when it lists none).
    private static func certificateFields(_ certificate: SecCertificate) -> (organization: String?, usages: [[UInt8]]?)? {
        let data = [UInt8](SecCertificateCopyData(certificate) as Data)
        guard let cert = DER(data[...]), let tbs = cert.children.first, tbs.tag == 0x30 else { return nil }
        let fields = tbs.children
        let base = fields.first?.tag == 0xA0 ? 1 : 0          // version
        guard fields.count > base + 5 else { return nil }
        var organization: String?
        for set in fields[base + 4].children {                 // subject
            for pair in set.children {
                let item = pair.children
                if item.count == 2, Array(item[0].bytes) == OID.organization { organization = text(item[1]) }
            }
        }
        var usages: [[UInt8]]?
        for ext in fields.first(where: { $0.tag == 0xA3 })?.children.first?.children ?? [] {
            let item = ext.children
            guard let id = item.first, Array(id.bytes) == OID.extendedKeyUsage, let value = item.last, value.tag == 0x04,
                  let list = DER(value.contents) else { continue }
            usages = list.children.map { Array($0.bytes) }
        }
        return (organization, usages)
    }

    /// A certificate may be used for `usage` when it names it, or names no usages at all.
    private static func allows(_ fields: (organization: String?, usages: [[UInt8]]?), _ usage: [UInt8]) -> Bool {
        guard let usages = fields.usages else { return true }
        return usages.contains(usage) || usages.contains(OID.anyUsage)
    }

    private static func text(_ node: DER) -> String? {
        switch node.tag {
        case 0x0C, 0x13, 0x16: return String(decoding: node.contents, as: UTF8.self)     // UTF8, Printable, IA5
        case 0x14: return String(bytes: node.contents, encoding: .isoLatin1)             // T61
        case 0x1E: return String(bytes: node.contents, encoding: .utf16BigEndian)        // BMP
        default: return nil
        }
    }
}

/// Where a PE file keeps its checksum and its certificate table, which Authenticode's digest leaves out.
private struct PELayout {
    let checksum: Int           // the optional header's 4-byte CheckSum
    let tableEntry: Int         // the 8-byte data directory entry of the certificate table
    let table: Range<Int>       // the certificate table itself

    init?(_ b: [UInt8]) {
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { return nil }
        let pe = u32(0x3C)
        guard pe >= 0x40, pe + 24 + 160 <= b.count, b[pe] == 0x50, b[pe + 1] == 0x45, b[pe + 2] == 0, b[pe + 3] == 0 else { return nil }
        let opt = pe + 24
        let magic = u16(opt)
        guard magic == 0x10B || magic == 0x20B else { return nil }
        let wide = magic == 0x20B
        guard u32(opt + (wide ? 108 : 92)) > 4 else { return nil }   // NumberOfRvaAndSizes
        checksum = opt + 64
        tableEntry = opt + (wide ? 112 : 96) + 4 * 8
        let start = u32(tableEntry), size = u32(tableEntry + 4)
        guard size > 8, start >= tableEntry + 8, start + size <= b.count else { return nil }
        table = start..<(start + size)
    }

    /// Authenticode's digest: every byte except the checksum, the certificate table's entry and the table.
    func digest<H: HashFunction>(of b: [UInt8], using _: H.Type) -> [UInt8] {
        var hasher = H()
        for range in [0..<checksum, (checksum + 4)..<tableEntry, (tableEntry + 8)..<table.lowerBound, table.upperBound..<b.count] {
            b[range].withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return Array(hasher.finalize())
    }
}

/// Just enough DER to take a PKCS #7 signature apart and put it back together: definite lengths only.
private struct DER {
    let tag: UInt8
    let bytes: ArraySlice<UInt8>        // the whole element
    let contents: ArraySlice<UInt8>

    init?(_ data: ArraySlice<UInt8>) {
        var i = data.startIndex
        guard data.endIndex - i >= 2 else { return nil }
        tag = data[i]
        var length = Int(data[i + 1])
        i += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), data.endIndex - i >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(data[i])
                i += 1
            }
        }
        guard data.endIndex - i >= length else { return nil }
        contents = data[i..<(i + length)]
        bytes = data[data.startIndex..<(i + length)]
    }

    var children: [DER] {
        var out: [DER] = []
        var rest = contents
        while !rest.isEmpty, let child = DER(rest) {
            out.append(child)
            rest = rest[child.bytes.endIndex...]
        }
        return out
    }

    static func encode(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        var length: [UInt8] = []
        var n = contents.count
        if n < 0x80 {
            length = [UInt8(n)]
        } else {
            while n > 0 {
                length.insert(UInt8(n & 0xFF), at: 0)
                n >>= 8
            }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return [tag] + length + contents
    }
}

/// Object identifiers, DER-encoded with their tag and length so they compare as bytes.
private enum OID {
    static let data = encode("1.2.840.113549.1.7.1")
    static let signedData = encode("1.2.840.113549.1.7.2")
    static let counterSignature = encode("1.2.840.113549.1.9.6")
    static let timeStampToken = encode("1.2.840.113549.1.9.16.2.14")
    static let msTimeStampToken = encode("1.3.6.1.4.1.311.3.3.1")
    static let spcIndirectData = encode("1.3.6.1.4.1.311.2.1.4")
    static let peImageData = encode("1.3.6.1.4.1.311.2.1.15")
    static let sha1 = encode("1.3.14.3.2.26")
    static let sha256 = encode("2.16.840.1.101.3.4.2.1")
    static let sha384 = encode("2.16.840.1.101.3.4.2.2")
    static let sha512 = encode("2.16.840.1.101.3.4.2.3")
    static let organization = encode("2.5.4.10")
    static let extendedKeyUsage = encode("2.5.29.37")
    static let anyUsage = encode("2.5.29.37.0")
    static let codeSigning = encode("1.3.6.1.5.5.7.3.3")
    static let timeStamping = encode("1.3.6.1.5.5.7.3.8")

    private static func encode(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var value = arc
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body += chunk
        }
        return [0x06, UInt8(body.count)] + body
    }
}
