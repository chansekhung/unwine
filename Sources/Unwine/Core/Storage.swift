import Darwin
import Foundation

// MARK: - Disk use

/// How much disk a file or folder takes. Links are not followed, so the Mac folders that Wine links
/// to (Documents, Desktop) and the games that Online mode links to do not count. Copies that share
/// their disk space (APFS clones, which Unwine uses for engines and bottles) count in full, so the
/// real use can be lower. The UI says "up to" for that reason.
enum DiskUse {
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let top = try? url.resourceValues(forKeys: keys) else { return 0 }
        if top.isRegularFile == true { return Int64(top.totalFileAllocatedSize ?? 0) }
        guard top.isDirectory == true,
              let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walk {
            guard let v = try? item.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: - Shader caches

/// Where the graphics layers keep the shaders they built, so that the next start of a game is quicker.
/// Each layer has its own place: DXMT and D3DMetal name theirs after the game's .exe file, Metal after
/// the app that the game runs as, and DXVK 3 keeps its own inside the game's Windows bottle. Deleting
/// them is safe: the layers build them again at the next start, which is slower one time.
enum ShaderCache {
    /// $(getconf DARWIN_USER_CACHE_DIR), the per-user cache folder. macOS does not clean it by itself.
    static let userCache: URL = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.deletingLastPathComponent().appendingPathComponent("C", isDirectory: true)
    }()

    static var dxmt: URL { userCache.appendingPathComponent("dxmt", isDirectory: true) }
    static var d3dmetal: URL { userCache.appendingPathComponent("d3dm", isDirectory: true) }

    /// Windows Steam's own programs. Their shaders belong to Online mode, never to one game.
    static let steamPrograms: Set<String> = ["steam.exe", "steamwebhelper.exe", "gameoverlayui.exe", "gameoverlayui64.exe",
                                             "steamsysinfo.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe", "steamservice.exe"]

    /// The app a game runs as, which names Metal's own cache folder: NotProton's launcher app for a
    /// Steam game, Unwine's Game Mode app for an added game (LocalGames names it the same way).
    static func bundleID(for game: SteamGame) -> String {
        game.localExe != nil ? "app.unwine.game.\(game.id)" : "com.notproton.launcher.\(game.id)"
    }

    /// One game's cache folders that exist now. DXMT and D3DMetal go by the .exe file's name, so two
    /// games with the same .exe name share theirs. Walks the game's folder, so call it off the main thread.
    static func folders(for game: SteamGame, mainExe: String?) -> [URL] {
        var names: Set<String> = []
        if let exe = game.localExe {
            names.insert(exe.lastPathComponent)
        } else {
            names = exeNames(in: game.installDir)
            if let mainExe { names.insert(URL(fileURLWithPath: mainExe).lastPathComponent) }
        }
        var out: [URL] = []
        for name in names.subtracting(steamPrograms) {
            out.append(dxmt.appendingPathComponent(name, isDirectory: true))
            out.append(d3dmetal.appendingPathComponent(name, isDirectory: true))
        }
        out.append(userCache.appendingPathComponent("\(bundleID(for: game))/com.apple.metal", isDirectory: true))
        out += dxvk(in: game.compatData.appendingPathComponent("pfx", isDirectory: true))
        return out.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The .exe file names in a game folder, up to `depth` folders down.
    static func exeNames(in folder: URL, depth: Int = 4) -> Set<String> {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var names: Set<String> = []
        for case let url as URL in walk {
            if walk.level > depth { walk.skipDescendants() }
            if url.pathExtension.lowercased() == "exe" { names.insert(url.lastPathComponent) }
        }
        return names
    }

    /// DXVK 3's cache folders in one Windows bottle: drive_c/users/<user>/AppData/Local/dxvk.
    static func dxvk(in prefix: URL) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("AppData/Local/dxvk", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every shader cache of Unwine's games, by layer. `prefixes` are the Windows bottles to look in.
    static func everything(prefixes: [URL]) -> [(layer: String, folders: [URL])] {
        let fm = FileManager.default
        func children(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        let metal = children(userCache).filter { app in
            let n = app.lastPathComponent
            return n.hasPrefix("app.unwine.game.") || n == "app.unwine.online-steam" || n.hasPrefix("com.notproton.launcher.")
        }
        .map { $0.appendingPathComponent("com.apple.metal", isDirectory: true) }
        .filter { fm.fileExists(atPath: $0.path) }
        return [("DXMT", children(dxmt)), ("D3DMetal", children(d3dmetal)), ("Metal", metal), ("DXVK", prefixes.flatMap(dxvk(in:)))]
    }

    /// Only folders inside these caches may ever be deleted here.
    private static func isCache(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(dxmt.standardizedFileURL.path + "/") || path.hasPrefix(d3dmetal.standardizedFileURL.path + "/")
            || (path.hasPrefix(userCache.standardizedFileURL.path + "/") && url.lastPathComponent == "com.apple.metal")
            || path.hasSuffix("/AppData/Local/dxvk")
    }

    /// Deletes the folders and returns the bytes freed. The layers build new ones at the next start.
    @discardableResult
    static func clear(_ folders: [URL]) -> Int64 {
        var freed: Int64 = 0
        for folder in folders where isCache(folder) {
            let bytes = DiskUse.size(of: folder)
            if (try? FileManager.default.removeItem(at: folder)) != nil { freed += bytes }
        }
        return freed
    }
}

// MARK: - Downloads

/// Unwine's Downloads folder holds each archive only until its install passed its checks. These rules
/// keep what an unfinished or waiting install still needs. Everything else Unwine put there is a
/// leftover, and the archives' pinned checksums fetch them again if they are ever needed.
enum DownloadsCleanup {
    /// Engine archives that an install still needs: setup's own engine before it is installed, and
    /// an engine that needs a newer Unwine (that Unwine installs it from these, with no new download).
    struct Keep: Sendable {
        var names: Set<String> = []
    }

    /// The leftovers, with their sizes. Reads Downloads and a few markers, so call it off the main thread.
    static func leftovers(_ keep: Keep) -> [(url: URL, bytes: Int64)] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.downloads, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        // Kit folders that hold all their files (SteamPlayKit.isDownloaded reads only the version).
        let kits = ((try? fm.contentsOfDirectory(atPath: SteamPlayPaths.kit.path)) ?? [])
            .filter { $0.hasPrefix("kit-") }.map { String($0.dropFirst(4)) }
            .filter { SteamPlayKit.isDownloaded(SteamPlayKitRelease(version: $0, url: SteamPlayKitRelease.pinned.url, size: 0)) }
        let newestKit = kits.max { LooseVersion($0) < LooseVersion($1) }
        var onlineInstalled: Bool?     // read once, only when SteamSetup.exe is there
        var out: [(url: URL, bytes: Int64)] = []
        for url in items {
            let name = url.lastPathComponent
            guard !keep.names.contains(name) else { continue }
            let lower = name.lowercased()
            let leftover: Bool
            if lower.hasSuffix(".resume") {
                // The rest of a cut-off download; the part it goes on from is gone after some days.
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                leftover = Date().timeIntervalSince(date) > 7 * 86_400
            } else if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".dmg") {
                leftover = true         // engine archives after their install, and Unwine's own disk images
            } else if lower.hasPrefix("notproton-"), lower.hasSuffix(".zip") {
                // A kit's zip is done when its kit folder (or a newer one) holds all its files.
                let version = String(name.dropFirst("NotProton-".count).dropLast(".zip".count))
                leftover = newestKit.map { LooseVersion($0) >= LooseVersion(version) } ?? false
            } else if lower.hasPrefix("bins_") {
                leftover = newestKit != nil    // Valve's pinned files are in the kit folder now
            } else if lower == "steamsetup.exe" {
                if onlineInstalled == nil { onlineInstalled = OnlineSteam.isInstalled }
                leftover = onlineInstalled == true   // Online mode only needs it before Steam is in its bottle
            } else {
                leftover = false
            }
            if leftover { out.append((url, DiskUse.size(of: url))) }
        }
        return out
    }

    /// Deletes the leftovers. Returns the bytes freed.
    @discardableResult
    static func sweep(_ keep: Keep) -> Int64 {
        var freed: Int64 = 0
        for item in leftovers(keep) where (try? FileManager.default.removeItem(at: item.url)) != nil { freed += item.bytes }
        return freed
    }
}

// MARK: - Storage report

/// What Unwine and its games keep on disk, measured for Settings' Storage group.
struct StorageReport: Sendable {
    struct Entry: Identifiable, Sendable {
        var id: String
        var title: String
        var note: String? = nil
        var bytes: Int64
        var folder: URL? = nil      // shown in Finder
    }

    /// A Windows bottle of a game that is gone: Steam left it after an uninstall, or an added game was removed.
    struct Orphan: Identifiable, Sendable {
        enum Owner: Sendable { case steam(Int), added(Int) }
        var owner: Owner
        var title: String
        var folder: URL
        var bytes: Int64
        var id: String { folder.path }
    }

    /// What the measure needs from the app's state, read on the main actor before it starts.
    struct Inputs: Sendable {
        var engines: [(engine: InstalledEngine, role: String)]
        var gptk: [D3DMetalInstall]                         // newest first; the first is the one in use
        var addedBottles: [(bottle: Int, names: [String])]
        var steamGames: [(id: Int, name: String, compatData: URL)]   // Windows games Steam runs through Unwine
        var keep: DownloadsCleanup.Keep
        var localIDs: Set<Int>                              // every added game; other ids' logs are of removed games
        var localBottles: Set<Int>                          // the bottles added games use
    }

    var engines: [Entry] = []
    var steamPlay: Entry?                   // Unwine's Steam tool, the Steam bridge and Steam Play's starting bottles
    var gptk: [Entry] = []
    var downloads = Entry(id: "downloads", title: "Downloads", bytes: 0, folder: Paths.downloads)
    var leftovers: Int64 = 0                // what "Delete leftovers" frees in Downloads
    var online: Entry?
    var addedBottles: [Entry] = []
    var steamBottles: [Entry] = []
    var shaders: [Entry] = []               // DXMT, D3DMetal, Metal and DXVK
    var shaderFolders: [URL] = []           // every shader cache folder, for "Clear all"
    var logs = Entry(id: "logs", title: "Logs", bytes: 0, folder: Paths.logs)
    var oldLogs: [URL] = []                 // logs of added games that are no longer in the library
    var oldLogBytes: Int64 = 0
    var orphans: [Orphan] = []
    var measuredAt = Date()

    /// DXVK keeps its shaders inside the bottles, and the bottles are counted already.
    static let dxvkShadersID = "shaders-DXVK"

    var total: Int64 {
        let lists = [engines, gptk, addedBottles, steamBottles, shaders.filter { $0.id != Self.dxvkShadersID }].flatMap { $0 }.map(\.bytes)
        return lists.reduce(0, +) + (steamPlay?.bytes ?? 0) + downloads.bytes + (online?.bytes ?? 0) + logs.bytes
            + orphans.map(\.bytes).reduce(0, +)
    }

    /// Walks the folders. Each part reports its share of `progress` (0...1) as it ends.
    static func measure(_ inputs: Inputs, progress: @Sendable (Double) -> Void) -> StorageReport {
        let fm = FileManager.default
        var r = StorageReport()
        let parts = 9.0
        var done = 0.0
        func next() { done += 1; progress(done / parts) }

        r.engines = inputs.engines.map {
            Entry(id: "engine-\($0.engine.folder)", title: $0.engine.label, note: $0.role, bytes: DiskUse.size(of: $0.engine.root), folder: $0.engine.root)
        }
        next()
        // NotProton's script keeps one starting bottle in each Steam library and copies it for each new game.
        let templates = SteamLibrary.steamappsFolders().map { $0.appendingPathComponent("compatdata/notproton-template", isDirectory: true) }
        let steamPlayParts = [SteamPlayPaths.kit, SteamPlayPaths.runners, SteamPlayPaths.bridge, SteamPlayPaths.fonts] + templates
        r.steamPlay = Entry(id: "steamplay", title: "Steam Play parts",
                            note: "Unwine's Steam tool, the Steam bridge and the starting bottle for new games. Steam Play needs them.",
                            bytes: steamPlayParts.map(DiskUse.size(of:)).reduce(0, +), folder: SteamPlayPaths.support)
        next()
        r.gptk = inputs.gptk.enumerated().map { i, g in
            Entry(id: "gptk-\(g.folder)", title: g.label, note: i == 0 ? "In use" : "An older copy. Games do not use it.", bytes: DiskUse.size(of: g.root), folder: g.root)
        }
        next()
        r.downloads.bytes = DiskUse.size(of: Paths.downloads)
        r.leftovers = DownloadsCleanup.leftovers(inputs.keep).map(\.bytes).reduce(0, +)
        next()
        if fm.fileExists(atPath: OnlineSteam.root.path) {
            r.online = Entry(id: "online", title: "Online mode (Windows Steam)", note: "Windows Steam, its sign-in, and saves that games keep in its bottle",
                             bytes: DiskUse.size(of: OnlineSteam.root), folder: OnlineSteam.root)
        }
        next()
        let compat = LocalGames.root.appendingPathComponent("compatdata", isDirectory: true)
        r.addedBottles = inputs.addedBottles.compactMap { b in
            let dir = compat.appendingPathComponent("\(b.bottle)", isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { return nil }
            return Entry(id: "added-\(b.bottle)", title: b.names.joined(separator: " and "), bytes: DiskUse.size(of: dir), folder: dir)
        }
        .sorted { $0.bytes > $1.bytes }
        r.steamBottles = inputs.steamGames.compactMap { g in
            guard fm.fileExists(atPath: g.compatData.path) else { return nil }
            return Entry(id: "steam-\(g.id)", title: g.name, bytes: DiskUse.size(of: g.compatData), folder: g.compatData)
        }
        .sorted { $0.bytes > $1.bytes }
        next()
        var prefixes = r.addedBottles.compactMap { $0.folder?.appendingPathComponent("pfx", isDirectory: true) }
        prefixes += r.steamBottles.compactMap { $0.folder?.appendingPathComponent("pfx", isDirectory: true) }
        prefixes.append(OnlineSteam.prefix)
        for (layer, folders) in ShaderCache.everything(prefixes: prefixes) {
            r.shaderFolders += folders
            // DXMT and D3DMetal keep one folder per .exe name for every Wine app on this Mac.
            let note = layer == "DXVK" ? "Inside the bottles above" : layer == "Metal" ? "Apple's own cache for each game" : "Shared with other Wine apps on this Mac"
            r.shaders.append(Entry(id: "shaders-\(layer)", title: layer, note: note, bytes: folders.map(DiskUse.size(of:)).reduce(0, +),
                                   folder: layer == "DXMT" ? ShaderCache.dxmt : layer == "D3DMetal" ? ShaderCache.d3dmetal : nil))
        }
        next()
        r.logs.bytes = DiskUse.size(of: Paths.logs)
        r.oldLogs = removedGameLogs(keeping: inputs.localIDs)
        r.oldLogBytes = r.oldLogs.map(DiskUse.size(of:)).reduce(0, +)
        next()
        r.orphans = orphans(localBottles: inputs.localBottles)
        next()
        return r
    }

    /// Logs of added games that are no longer in the library ("local-<id>.log" and its ".1").
    static func removedGameLogs(keeping ids: Set<Int>) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.logs, includingPropertiesForKeys: nil)) ?? []).filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("local-"), let id = Int(name.dropFirst(6).prefix(while: \.isNumber)) else { return false }
            return !ids.contains(id)
        }
    }

    /// App ids Steam knows as installed: a manifest in a library that is connected now, or a line in
    /// libraryfolders.vdf (that list also names the games on a drive that is not connected).
    private static func knownSteamApps() -> Set<Int> {
        let fm = FileManager.default
        var ids = Set<Int>()
        for apps in SteamLibrary.steamappsFolders() {
            for file in (try? fm.contentsOfDirectory(atPath: apps.path)) ?? [] where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                if let id = Int(file.dropFirst("appmanifest_".count).dropLast(".acf".count)) { ids.insert(id) }
            }
        }
        if let folders = VDF.parse(contentsOf: SteamLibrary.mainSteamapps.appendingPathComponent("libraryfolders.vdf"))?["libraryfolders"] {
            for (_, library) in folders.entries {
                for (key, _) in library["apps"]?.entries ?? [] { if let id = Int(key) { ids.insert(id) } }
            }
        }
        return ids
    }

    /// Windows bottles of games that are gone. Steam keeps a game's bottle (compatdata) after it
    /// uninstalls the game. A bottle that runs now never counts.
    static func orphans(localBottles: Set<Int>) -> [Orphan] {
        let fm = FileManager.default
        var out: [Orphan] = []
        let known = knownSteamApps()
        for apps in SteamLibrary.steamappsFolders() {
            let compat = apps.appendingPathComponent("compatdata", isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: compat.path)) ?? [] {
                // Real Steam apps only. A shortcut to a game outside Steam has an id from 2^31 up and never a manifest.
                guard let id = Int(name), id > 0, id < 2_147_483_648, !known.contains(id) else { continue }
                let dir = compat.appendingPathComponent(name, isDirectory: true)
                guard !OnlineSteam.serverIsAlive(dir.appendingPathComponent("pfx")) else { continue }
                out.append(Orphan(owner: .steam(id), title: launcherName(id) ?? "Steam app \(id)", folder: dir, bytes: DiskUse.size(of: dir)))
            }
        }
        let local = LocalGames.root.appendingPathComponent("compatdata", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: local.path)) ?? [] {
            guard let id = Int(name), !localBottles.contains(id) else { continue }
            let dir = local.appendingPathComponent(name, isDirectory: true)
            guard !OnlineSteam.serverIsAlive(dir.appendingPathComponent("pfx")) else { continue }
            out.append(Orphan(owner: .added(id), title: "A game you removed from Unwine", folder: dir, bytes: DiskUse.size(of: dir)))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// True while the bottle still belongs to no game and nothing runs in it. Checked again just
    /// before it goes to the Trash.
    static func isStillOrphan(_ o: Orphan, localBottles: Set<Int>) -> Bool {
        guard FileManager.default.fileExists(atPath: o.folder.path),
              !OnlineSteam.serverIsAlive(o.folder.appendingPathComponent("pfx")) else { return false }
        switch o.owner {
        case .steam(let id): return !knownSteamApps().contains(id)
        case .added(let id): return !localBottles.contains(id)
        }
    }

    /// The game's name from the launcher app NotProton made for it ("Left 4 Dead 2.app").
    private static func launcherName(_ id: Int) -> String? {
        let dir = SteamPlayPaths.launchers.appendingPathComponent("\(id)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }
}
