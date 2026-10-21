import Foundation

/// How the library orders its games. The choice is saved.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, added, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recently played"
        case .name: return "Name"
        case .added: return "Recently added"
        case .size: return "Size"
        }
    }
}

/// Which games the library shows. The choice is saved.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, steam, added, running, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .steam: return "Steam"
        case .added: return "Added"
        case .running: return "Running"
        case .attention: return "Needs attention"
        }
    }

    var help: String {
        switch self {
        case .all: return "Shows every game"
        case .steam: return "Shows the games from your Mac Steam"
        case .added: return "Shows the games you added by their folder or .exe"
        case .running: return "Shows the games that run now"
        case .attention: return "Shows the games with something to fix or to know first. Their pages say what."
        }
    }
}

/// The library as the grid shows it: favourites on top, then the other games. Hidden games show
/// only when the user asks for them.
struct LibraryShelves {
    var favourites: [SteamGame] = []
    var games: [SteamGame] = []
    var hidden: [SteamGame] = []
    var counts: [LibraryFilter: Int] = [:]     // games each filter shows now, hidden games left out

    var isEmpty: Bool { favourites.isEmpty && games.isEmpty }
    var first: SteamGame? { favourites.first ?? games.first }
}

extension AppModel {
    var librarySort: LibrarySort {
        get { stored.librarySort.flatMap(LibrarySort.init(rawValue:)) ?? .recent }
        set { stored.librarySort = newValue == .recent ? nil : newValue.rawValue; save() }
    }

    var libraryFilter: LibraryFilter {
        get { stored.libraryFilter.flatMap(LibraryFilter.init(rawValue:)) ?? .all }
        set { stored.libraryFilter = newValue == .all ? nil : newValue.rawValue; save() }
    }

    func isFavourite(_ id: Int) -> Bool { stored.favourites.contains(id) }
    func isHidden(_ id: Int) -> Bool { stored.hiddenGames.contains(id) }

    func setFavourite(_ on: Bool, _ game: SteamGame) {
        if on { stored.favourites.insert(game.id) } else { stored.favourites.remove(game.id) }
        save()
    }

    func setHidden(_ on: Bool, _ game: SteamGame) {
        if on { stored.hiddenGames.insert(game.id) } else { stored.hiddenGames.remove(game.id) }
        save()
        if on {
            show("\(game.name) is hidden. \u{201C}Hidden games\u{201D} under the library shows it again.",
                 action: .init("Undo") { [weak self] in self?.setHidden(false, game) })
        }
    }

    /// The games the grid shows for this search, with the saved filter and order.
    func shelves(search: String) -> LibraryShelves {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let found = windowsGames.filter { g in words.allSatisfy { g.name.localizedStandardContains($0) } }
        var shelves = LibraryShelves()
        let shown = found.filter { !stored.hiddenGames.contains($0.id) }
        for f in LibraryFilter.allCases { shelves.counts[f] = f == .all ? shown.count : shown.filter { passes($0, f) }.count }
        let filter = libraryFilter
        for g in ordered(found.filter { passes($0, filter) }) {
            if stored.hiddenGames.contains(g.id) {
                shelves.hidden.append(g)
            } else if stored.favourites.contains(g.id) {
                shelves.favourites.append(g)
            } else {
                shelves.games.append(g)
            }
        }
        return shelves
    }

    private func passes(_ game: SteamGame, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .steam: return game.localExe == nil
        case .added: return game.localExe != nil
        case .running: return isRunning(game)
        case .attention: return needsAttention(game)
        }
    }

    private func ordered(_ list: [SteamGame]) -> [SteamGame] {
        let byName: (SteamGame, SteamGame) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Newest first; games without a date go last, by name.
        func newest(_ date: (SteamGame) -> Date?) -> [SteamGame] {
            list.sorted { a, b in
                switch (date(a), date(b)) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            }
        }
        switch librarySort {
        case .recent:
            return newest(\.lastPlayed)
        case .name:
            return list.sorted(by: byName)
        case .added:
            // A Steam game's install folder date, an added game's date of adding (LocalGames.game(from:)).
            return newest(\.addedAt)
        case .size:
            return list.sorted { $0.sizeOnDisk != $1.sizeOnDisk ? $0.sizeOnDisk > $1.sizeOnDisk : byName($0, $1) }
        }
    }

    /// True while the game starts, runs or closes. The run state answers for Steam games (their
    /// bottle's lock, read with each refresh) and added games alike, so the grid reads no files.
    func isRunning(_ game: SteamGame) -> Bool { runState(of: game) != .idle }

    /// Something stands between the player and a good start, or is worth knowing first. The game's
    /// page says what and has the fix. A missing program file is a badge too.
    func needsAttention(_ game: SteamGame) -> Bool {
        if game.state == .needsUpdate { return true }
        if badges(for: game).contains(where: \.needsAttention) { return true }
        return game.state == .installed && game.bottleIncomplete
    }
}

// MARK: - When and how long a game was played

extension SteamGame {
    /// "Played 3 days ago · 12 h" for the game's page, or nil when Unwine knows neither.
    var playedLine: String? {
        let time = playtimeMinutes.flatMap { $0 > 0 ? PlayedWords.time($0) : nil }
        switch (lastPlayed, time) {
        case let (date?, time?): return "Played \(PlayedWords.ago(date)) · \(time)"
        case let (date?, nil): return "Played \(PlayedWords.ago(date))"
        case let (nil, time?): return "\(time) played"
        default: return nil
        }
    }

    /// The tile's short form: "3 days ago · 12 h", or "Not played yet".
    var playedShort: String {
        let time = playtimeMinutes.flatMap { $0 > 0 ? PlayedWords.time($0) : nil }
        let when = lastPlayed.map { date -> String in
            let ago = PlayedWords.ago(date)
            return ago.prefix(1).uppercased() + ago.dropFirst()
        }
        switch (when, time) {
        case let (when?, time?): return "\(when) · \(time)"
        case let (when?, nil): return when
        case let (nil, time?): return "\(time) played"
        default: return "Not played yet"
        }
    }
}

enum PlayedWords {
    /// "today", "yesterday", "3 days ago", "2 weeks ago", "5 months ago", "2 years ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<30: return days / 7 == 1 ? "1 week ago" : "\(days / 7) weeks ago"
        case 30..<365: return days / 30 == 1 ? "1 month ago" : "\(days / 30) months ago"
        default: return days / 365 == 1 ? "1 year ago" : "\(days / 365) years ago"
        }
    }

    /// "45 min" or "12 h".
    static func time(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\((minutes / 60).formatted()) h"
    }
}
