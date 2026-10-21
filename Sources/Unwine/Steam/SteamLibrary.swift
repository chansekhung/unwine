import Foundation

struct SteamGame: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case installed
        case downloading(Double?)   // 0...1 when Steam reports sizes
        case needsUpdate
    }

    let id: Int                     // Steam appid
    let name: String
    let installDir: URL
    let steamapps: URL              // the library's steamapps folder
    let sizeOnDisk: Int64
    let state: State
    let lastPlayed: Date?
    /// Steam installed the Windows version (it runs through Steam Play).
    let isWindowsBuild: Bool
    /// Set for a game the user added by its .exe (it runs without Steam).
    var localExe: URL? = nil
    /// An added game that shares another added game's bottle (one game folder, one bottle).
    var bottleID: Int? = nil

    var compatData: URL { steamapps.appendingPathComponent("compatdata/\(bottleID ?? id)", isDirectory: true) }
    var runLog: URL {
        localExe == nil ? compatData.appendingPathComponent("notproton-run.log") : Paths.logs.appendingPathComponent(LocalGames.logName(id))
    }
    var wineLog: URL { SteamPlayPaths.launchers.appendingPathComponent("\(id)/notproton-wine.log") }

    /// The game's Windows bottle has no 32-bit half (its first start was cut short, or it was copied
    /// from an unfinished template). 32-bit games and launchers then quit at once ("could not load
    /// kernel32.dll"). A fresh bottle fixes it.
    var bottleIncomplete: Bool {
        let windows = compatData.appendingPathComponent("pfx/drive_c/windows", isDirectory: true)
        let fm = FileManager.default
        return fm.fileExists(atPath: windows.appendingPathComponent("system32/kernel32.dll").path)
            && !fm.fileExists(atPath: windows.appendingPathComponent("syswow64/kernel32.dll").path)
    }
}

/// Reads Mac Steam's own library files. No login, no API key, no network.
enum SteamLibrary {
    /// Tools and runtimes Steam lists as apps but that are not games.
    static let hiddenAppIDs: Set<Int> = [228980, 1070560, 1391110, 1628350, 4183110, 1493710, 2348590,
                                         2805730, 3658110, 1826330, 1887720, 2180100, 961940, 1420170, 250820, 1007]

    static var mainSteamapps: URL { SteamPlayPaths.steamData.appendingPathComponent("steamapps", isDirectory: true) }

    /// Every steamapps folder Steam knows about (internal disk plus extra library folders).
    static func steamappsFolders() -> [URL] {
        var folders = [mainSteamapps]
        if let root = VDF.parse(contentsOf: mainSteamapps.appendingPathComponent("libraryfolders.vdf")),
           let lib = root["libraryfolders"] {
            for (_, entry) in lib.entries {
                guard let path = entry["path"]?.string ?? entry.string else { continue }
                let apps = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("steamapps", isDirectory: true)
                if !folders.contains(where: { $0.standardizedFileURL.path == apps.standardizedFileURL.path }) { folders.append(apps) }
            }
        }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func scan(unwineMapped: Set<Int> = []) -> [SteamGame] {
        let fm = FileManager.default
        var games: [Int: SteamGame] = [:]
        for apps in steamappsFolders() {
            guard let files = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let acf = VDF.parse(contentsOf: apps.appendingPathComponent(file)),
                      let st = acf["AppState"],
                      let id = st["appid"]?.string.flatMap(Int.init),
                      !hiddenAppIDs.contains(id) else { continue }
                let name = st["name"]?.string ?? "App \(id)"
                if name.hasPrefix("Steamworks") || name.hasPrefix("Proton") || name.hasPrefix("Steam Linux Runtime") { continue }
                let dir = apps.appendingPathComponent("common/\(st["installdir"]?.string ?? name)", isDirectory: true)
                let flags = st["StateFlags"]?.string.flatMap(Int.init) ?? 0
                let size = st["SizeOnDisk"]?.string.flatMap(Int64.init) ?? 0
                let lastPlayed = st["LastPlayed"]?.string.flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }

                let state: SteamGame.State
                let updating = flags & 1024 != 0 || flags & 1_048_576 != 0
                if updating || flags & 4 == 0 {
                    let done = st["BytesDownloaded"]?.string.flatMap(Double.init)
                    let total = st["BytesToDownload"]?.string.flatMap(Double.init)
                    let p: Double? = (done != nil && (total ?? 0) > 0) ? min(1, done! / total!) : nil
                    state = .downloading(p)
                } else if flags & 2 != 0 {
                    state = .needsUpdate
                } else {
                    state = .installed
                }
                let compat = fm.fileExists(atPath: apps.appendingPathComponent("compatdata/\(id)").path)
                let windows = compat || unwineMapped.contains(id) || looksLikeWindowsBuild(dir)
                games[id] = SteamGame(id: id, name: name, installDir: dir, steamapps: apps, sizeOnDisk: size,
                                      state: state, lastPlayed: lastPlayed, isWindowsBuild: windows)
            }
        }
        return games.values.sorted {
            switch ($0.lastPlayed, $1.lastPlayed) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// A Windows install has .exe files near the top and no macOS app bundle.
    static func looksLikeWindowsBuild(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        if top.contains(where: { $0.hasSuffix(".app") }) { return false }
        if top.contains(where: { $0.lowercased().hasSuffix(".exe") }) { return true }
        for sub in top.prefix(40) {
            let path = dir.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue,
                  let inner = try? fm.contentsOfDirectory(atPath: path.path) else { continue }
            if inner.contains(where: { $0.hasSuffix(".app") }) { return false }
            if inner.contains(where: { $0.lowercased().hasSuffix(".exe") }) { return true }
        }
        return false
    }

    // MARK: Artwork

    enum ArtKind: String { case capsule = "library_600x900", hero = "library_hero", header = "header" }

    /// Art Steam already cached on disk (works offline).
    static func cachedArt(_ kind: ArtKind, appID: Int) -> URL? {
        let fm = FileManager.default
        let cache = SteamPlayPaths.steamData.appendingPathComponent("appcache/librarycache", isDirectory: true)
        for ext in ["jpg", "png"] {
            let flat = cache.appendingPathComponent("\(appID)_\(kind.rawValue).\(ext)")
            if fm.fileExists(atPath: flat.path) { return flat }
        }
        let wanted: [String] = {
            switch kind {
            case .capsule: return ["library_600x900", "library_capsule"]
            case .hero: return ["library_hero"]
            case .header: return ["header", "library_header"]
            }
        }()
        guard let walker = fm.enumerator(at: cache.appendingPathComponent("\(appID)"), includingPropertiesForKeys: nil) else { return nil }
        var best: URL?
        for case let url as URL in walker {
            let base = url.deletingPathExtension().lastPathComponent
            if base == wanted[0] { return url }
            if wanted.contains(base) { best = best ?? url }
        }
        return best
    }

    /// Public CDN art, used when Steam has not cached it yet.
    static func remoteArt(_ kind: ArtKind, appID: Int) -> [URL] {
        let hosts = ["https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps",
                     "https://cdn.cloudflare.steamstatic.com/steam/apps"]
        let files = kind == .capsule ? ["library_600x900_2x.jpg", "library_600x900.jpg"] : ["\(kind.rawValue).jpg"]
        return hosts.flatMap { h in files.compactMap { URL(string: "\(h)/\(appID)/\($0)") } }
    }
}
