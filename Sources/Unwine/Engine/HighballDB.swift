import Foundation

/// One game in the Highball compatibility database (gethighball.com).
struct HighballGame: Decodable, Sendable, Equatable {
    enum Status: String, Sendable {
        case verifiedLocal = "verified-local"        // Highball ran it on real Apple Silicon
        case community                               // community consensus, not verified
        case reportedUpstream = "reported-upstream"  // named as working in an upstream release note
        case blockedAnticheat = "blocked-anticheat"  // kernel anti-cheat: no compatibility layer can run it
        case blockedPublisher = "blocked-publisher"  // the publisher stops it on macOS on purpose
        case unknown                                 // a status newer than this Unwine knows

        var isBlocked: Bool { self == .blockedAnticheat || self == .blockedPublisher }
    }

    struct AntiCheat: Decodable, Sendable, Equatable {
        var names: [String]
        /// "blocked" (cannot work on a Mac) or "warning" (present, may work in its user-space form).
        var macVerdict: String?
        var note: String?

        private enum Keys: String, CodingKey { case names, macVerdict, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            names = (try? c.decodeIfPresent([String].self, forKey: .names)) ?? []
            macVerdict = try? c.decodeIfPresent(String.self, forKey: .macVerdict)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    var id: String
    var title: String
    var status: Status
    var appID: Int?
    /// "dxmt", "d3dmetal", "dxvk", "wined3d" or "vkd3d": the layer Highball's page recommends. That is a
    /// suggestion, not a promise the game runs (some entries say it does not start), so read `notes` too.
    var renderer: String?
    var lastVerified: String?
    var notes: String
    var anticheat: AntiCheat?
    var reports: Int
    /// Highball's own setup for the game goes beyond the graphics layer (settings, files, launch
    /// options). Unwine does not apply those, so its result can differ from Highball's test.
    var hasRecipe: Bool
    /// The game's page on gethighball.com.
    var url: URL?

    private enum Keys: String, CodingKey {
        case id, title, status, steamAppID = "steam_appid", renderer, lastVerified, notes, anticheat, reports, recipe, url
    }

    /// Lenient on purpose: a field that is missing or has an odd type becomes a default, never an error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:))) ?? .unknown
        appID = try? c.decodeIfPresent(Int.self, forKey: .steamAppID)
        renderer = try? c.decodeIfPresent(String.self, forKey: .renderer)
        lastVerified = try? c.decodeIfPresent(String.self, forKey: .lastVerified)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        anticheat = try? c.decodeIfPresent(AntiCheat.self, forKey: .anticheat)
        reports = (try? c.decodeIfPresent(Int.self, forKey: .reports)) ?? 0
        hasRecipe = (try? c.decodeIfPresent(Bool.self, forKey: .recipe)) ?? false
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap(Self.highballPage)
    }

    /// Links open in the user's browser, so only Highball's own https pages are accepted.
    private static func highballPage(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              host == "gethighball.com" || host.hasSuffix(".gethighball.com") else { return nil }
        return url
    }
}

/// The free Highball compatibility database. Unwine downloads the whole file, never one game at a
/// time, so the games a person owns are not sent anywhere. Data is CC0-1.0; the anti-cheat fields
/// come from AreWeAntiCheatYet (MIT).
enum HighballDB {
    static let attribution = "Compatibility data from the Highball database (CC0-1.0, gethighball.com). Anti-cheat details from AreWeAntiCheatYet (MIT)."

    private static let source = URL(string: "https://gethighball.com/data/games.json")!
    private static let maxAge: TimeInterval = 3 * 86_400
    private static let maxBytes = 8 * 1024 * 1024
    /// Don't hammer the server when a refresh fails (offline is normal) or is asked for in a loop.
    private static let retryAfter: TimeInterval = 600

    private static let cacheURL = Paths.support.appendingPathComponent("Cache/highball-games.json")

    /// Highball's entry for a Steam app, from the cached file. Safe from any thread.
    static func game(_ appID: Int) -> HighballGame? { index.games[appID] }

    /// Highball's entry for a game by its title, for games added by their .exe. Letter case, accents,
    /// punctuation, ™ and ®, a leading "The" and Roman numbers do not count (see GameTitles.key). A
    /// title that two games share finds nothing: Unwine does not guess. Safe from any thread.
    static func game(title: String) -> HighballGame? { index.titleTables.game(title: title) }

    /// Downloads the database when the cached copy is missing, unreadable or older than three days.
    /// The old copy stays in place unless the new one passes `parse`, so any failure is harmless.
    /// When there is nothing to do it costs one file-date check, and after a failed try only the
    /// retry wait, so a timer can call it often. Returns true only when it wrote a new cache file.
    @discardableResult
    static func refreshIfStale(log: LogFile? = nil) async -> Bool {
        guard isStale, await throttle.allow(every: retryAfter) else { return false }
        do {
            let data = try await download()
            guard let games = parse(data) else { throw RefreshError.notADatabase }
            try Paths.ensure(cacheURL.deletingLastPathComponent())
            try data.write(to: cacheURL, options: .atomic)
            index.set(games)
            log?.line("Highball database refreshed: \(games.count) games")
            return true
        } catch {
            log?.line("Highball database not refreshed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Cache

    /// One stat call, so asking is cheap enough for a timer.
    private static var isStale: Bool {
        var info = stat()
        guard stat(cacheURL.path, &info) == 0 else { return true }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let age = Date().timeIntervalSince1970 - modified
        return age < 0 || age > maxAge || index.games.isEmpty
    }

    /// Parsed once, then kept. `refreshIfStale` replaces it after writing a new file. The title
    /// tables are built on the first title lookup, so a library of Steam games never pays for them.
    private final class Index: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [HighballGame]?
        private var byAppID: [Int: HighballGame] = [:]
        private var titles: Titles?

        var games: [Int: HighballGame] {
            lock.lock(); defer { lock.unlock() }
            loadIfNeeded()
            return byAppID
        }

        var titleTables: Titles {
            lock.lock(); defer { lock.unlock() }
            loadIfNeeded()
            if let titles { return titles }
            let made = Titles(list ?? [])
            titles = made
            return made
        }

        func set(_ games: [HighballGame]) {
            lock.lock(); defer { lock.unlock() }
            use(games)
        }

        private func loadIfNeeded() {
            if list == nil { use(HighballDB.loadFromDisk()) }
        }

        private func use(_ games: [HighballGame]) {
            list = games
            byAppID = Dictionary(games.compactMap { game in game.appID.map { ($0, game) } }, uniquingKeysWith: { first, _ in first })
            titles = nil
        }
    }

    private static let index = Index()

    private static func loadFromDisk() -> [HighballGame] {
        guard let data = try? Data(contentsOf: cacheURL), let games = parse(data) else { return [] }
        return games
    }

    /// The games by title keys (see GameTitles.key).
    private struct Titles {
        /// Whole titles.
        var whole: [String: HighballGame] = [:]
        /// Titles without their "(...)" part, or cut before a numbered subtitle, where no whole title
        /// has that key.
        var loose: [String: HighballGame] = [:]

        init(_ games: [HighballGame]) {
            var whole: [String: [HighballGame]] = [:]
            var loose: [String: [HighballGame]] = [:]
            for game in games {
                if let key = GameTitles.key(game.title) { whole[key, default: []].append(game) }
                for key in GameTitles.looseKeys(game.title) { loose[key, default: []].append(game) }
            }
            // A key that two games share would be a guess, so it finds nothing.
            self.whole = whole.compactMapValues { $0.count == 1 ? $0[0] : nil }
            self.loose = loose.filter { whole[$0.key] == nil }.compactMapValues { $0.count == 1 ? $0[0] : nil }
        }

        /// The whole title first, then the title's own looser forms against whole titles. Two loose
        /// forms are never matched with each other: that would join "Star Wars: A" and "Star Wars: B".
        func game(title: String) -> HighballGame? {
            guard !whole.isEmpty, let key = GameTitles.key(title) else { return nil }
            if let game = whole[key] ?? loose[key] { return game }
            for form in GameTitles.looseKeys(title) { if let game = whole[form] { return game } }
            return nil
        }
    }

    // MARK: Parsing

    /// Decodes each game on its own, so one odd entry never costs the rest.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct DatabaseFile: Decodable {
        let games: [HighballGame]

        private enum Keys: String, CodingKey { case games, license, count }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // The real file always carries its license and game count beside the list. A web page,
            // an error message or a changed layout does not.
            guard let license = try? c.decode(String.self, forKey: .license), !license.isEmpty,
                  (try? c.decode(Int.self, forKey: .count)) != nil else { throw RefreshError.notADatabase }
            games = try c.decode([Lossy<HighballGame>].self, forKey: .games).compactMap(\.value)
        }
    }

    /// The real file has about 460 games with a Steam app id. A file with far fewer (a renamed field,
    /// a cut-down list) is not the database and must not replace a good cache.
    private static let minimumGamesWithAppID = 100

    /// Nil unless this really is the database.
    private static func parse(_ data: Data) -> [HighballGame]? {
        guard let file = try? JSONDecoder().decode(DatabaseFile.self, from: data),
              file.games.filter({ ($0.appID ?? 0) > 0 }).count >= minimumGamesWithAppID else { return nil }
        return file.games
    }

    // MARK: Download

    private enum RefreshError: LocalizedError {
        case tooLarge, notADatabase

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The file is larger than 8 MB."
            case .notADatabase: return "The file is not a Highball database."
            }
        }
    }

    private actor Throttle {
        private var last: Date?

        func allow(every seconds: TimeInterval) -> Bool {
            if let last, Date().timeIntervalSince(last) < seconds { return false }
            last = Date()
            return true
        }
    }

    private static let throttle = Throttle()

    /// Reads at most `maxBytes`, counted after decompression, so a bad server cannot fill memory.
    private static func download() async throws -> Data {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Unwine", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false   // fail fast offline; the next launch tries again
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1, source)
        }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw RefreshError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw RefreshError.tooLarge }
        }
        return data
    }
}
