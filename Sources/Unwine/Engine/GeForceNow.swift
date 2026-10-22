import AppKit
import Foundation

/// GeForce NOW, NVIDIA's cloud gaming service. No Wine tool can load kernel anti-cheat, but GeForce NOW
/// runs the game on a Windows PC in a data center and streams it to the Mac. Unwine only opens GeForce
/// NOW for the user; it is not part of Unwine.
///
/// Checked on 22 October 2026 with GeForce NOW 2.0.86 for macOS:
/// - The app registers the URL scheme "geforcenow". "geforcenow://route/#deeplink?action=view-game&game-id=<id>"
///   opens the game's page: the app's own deeplink handler takes it, and its log said ViewGame with no error.
/// - The website opens the same page at "https://play.geforcenow.com/games?game-id=<id>", the app's share link.
/// - The id is NVIDIA's (a UUID), not a Steam app id. NVIDIA's public games page (nvidia.com/geforce-now/games)
///   gets it from `gameList`, where each store copy of a game carries its store's id: for Steam, the app id.
enum GeForceNow {
    static let bundleID = "com.nvidia.gfnpc.mall"
    static let website = URL(string: "https://play.geforcenow.com/")!

    private static let gameList = URL(string: "https://api-prod.nvidia.com/services/gfngames/v1/gameList")!
    /// A search needs the nearest GeForce NOW region. NVIDIA's games page asks this address for it.
    private static let serverInfo = URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverinfo")!

    /// The GeForce NOW app, when it is installed.
    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Riot Vanguard does not run on virtual machines, which cloud gaming uses. So no cloud service has
    /// Valorant or League of Legends, and GeForce NOW's list has neither.
    static func refusesCloud(_ antiCheat: [String]) -> Bool {
        antiCheat.contains { $0.lowercased().contains("vanguard") }
    }

    /// One game in GeForce NOW's list.
    struct Match: Sendable {
        let id: String
        let title: String
    }

    /// The game in GeForce NOW's list, or nil when the list does not have it. A Steam game counts only
    /// when GeForce NOW has its Steam copy (the same app id); a game added by its .exe needs a title that
    /// only one entry has. Sends this one game's name to NVIDIA, and only when the user asks, so the rest
    /// of the library stays private.
    static func find(steamAppID: Int?, title: String) async throws -> Match? {
        // Only letters, digits and plain punctuation go into the query: no quotes, ™ or ®.
        let words = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " '-:&.!".unicodeScalars.contains($0) })
        let search = words.split(separator: " ").joined(separator: " ")
        guard !search.isEmpty else { return nil }

        let region = try await fetch(Region.self, URLRequest(url: serverInfo, timeoutInterval: 10)).requestStatus.serverId
        guard region.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        // The same query as NVIDIA's games page, which sends GraphQL text without variables.
        var request = URLRequest(url: gameList, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            { apps(country:"US" language:"en_US" orderBy:"itemMetadata.relevance:DESC,sortName:ASC" after:"" \
            searchQuery:"\(search)" vpcId:"\(region)" first:50) { items { id title variants { appStore storeId } } } }
            """.utf8)
        let items = try await fetch(Reply.self, request).data.apps.items.filter { isGameID($0.id) }

        if let steamAppID {
            let store = String(steamAppID)
            return items.first { $0.variants?.contains { $0.appStore == "STEAM" && $0.storeId == store } == true }
                .map { Match(id: $0.id, title: $0.title) }
        }
        guard let key = GameTitles.key(title) else { return nil }
        let same = items.filter { GameTitles.key($0.title) == key }
        return same.count == 1 ? Match(id: same[0].id, title: same[0].title) : nil
    }

    /// The game's page in the app when it is installed, else on the website. Without a game, the app's
    /// own start page or the website's.
    static func page(_ match: Match?) -> URL {
        let app = app
        guard let match else { return app ?? website }
        return app == nil
            ? URL(string: "https://play.geforcenow.com/games?game-id=\(match.id)") ?? website
            : URL(string: "geforcenow://route/#deeplink?action=view-game&game-id=\(match.id)") ?? website
    }

    // MARK: Network

    private struct Region: Decodable {
        struct Status: Decodable { let serverId: String }
        let requestStatus: Status
    }

    private struct Reply: Decodable {
        struct Body: Decodable { let apps: Apps }
        struct Apps: Decodable { let items: [Item] }
        struct Item: Decodable {
            let id: String
            let title: String
            let variants: [Variant]?
        }
        struct Variant: Decodable {
            let appStore: String?
            let storeId: String?
        }
        let data: Body
    }

    /// NVIDIA's ids are UUIDs. Anything else is not put into a link.
    private static func isGameID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func fetch<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        var request = request
        request.setValue("Unwine", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1, request.url ?? gameList)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
