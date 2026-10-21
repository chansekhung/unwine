import AppKit
import UniformTypeIdentifiers

/// How Unwine found a game's entry in Highball.
struct HighballMatch: Equatable {
    enum Way: Equatable {
        case appID              // a Steam game, by its own app id
        case steamAppIDFile     // an added game, by the steam_appid.txt next to its program
        case title              // an added game, by its ProductName, its name or its folder's name
    }

    let game: HighballGame
    let way: Way
}

/// The pictures Unwine has for an added game.
struct LocalArt: Equatable {
    /// The picture the user chose.
    var cover: URL?
    /// The program's icon, once Unwine has read the program. The file is missing when it has none.
    var icon: URL?
    /// Unwine is reading the program's icon or preparing a new cover, so the tile shows a shimmer.
    var waiting: Bool
    /// Changes when the program was read again (it moved), so the tile loads its icon again.
    var stamp: String
}

// Group: added-game identity (icons, names, covers, art).
extension AppModel {
    /// The Covers folder is checked for pictures of removed games once per run.
    private static var leftoversChecked = false

    // MARK: Pictures

    func localArt(for id: Int) -> LocalArt? {
        guard let r = stored.localGames.first(where: { $0.id == id }) else { return nil }
        let read = r.productRead == r.exePath
        let state = ArtState.shared
        return LocalArt(cover: r.cover.map(ArtCache.coverFile), icon: read ? ArtCache.iconFile(id) : nil,
                        waiting: state.preparing.contains(id) || (!read && state.reading.contains(id)),
                        stamp: read ? r.exePath : "")
    }

    /// Runs when a Steam refresh lands: art that failed may load now, and added programs that Unwine
    /// has not read yet (new, moved, or on a drive that is back) are read.
    func refreshArtAndIdentities() {
        ArtState.shared.refreshLanded()
        readLocalIdentities()
    }

    /// Reads the ProductName, the Steam app id and the icon of each added program that Unwine has not
    /// read yet, or that moved. The reading runs in the background. A program already read costs one
    /// comparison, so the Steam refresh can call this each time.
    func readLocalIdentities() {
        if !Self.leftoversChecked, !stored.localGames.isEmpty {
            Self.leftoversChecked = true
            let records = stored.localGames
            Task.detached(priority: .utility) {
                ArtCache.removeLeftovers(keeping: records)
                _ = HighballDB.game(title: "")      // builds the title tables now, not during a redraw
            }
        }
        let state = ArtState.shared
        for r in stored.localGames where r.productRead != r.exePath && !state.reading.contains(r.id) {
            let exe = URL(fileURLWithPath: r.exePath), id = r.id
            guard FileManager.default.fileExists(atPath: exe.path) else { continue }   // a drive that is not connected: later
            state.reading.insert(id)
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) { ExeIcon.identity(of: exe, iconFile: ArtCache.iconFile(id)) }.value
                state.reading.remove(id)
                guard let self, let found, let i = self.stored.localGames.firstIndex(where: { $0.id == id }),
                      self.stored.localGames[i].exePath == exe.path else { return }
                self.stored.localGames[i].productName = found.productName
                self.stored.localGames[i].steamAppID = found.steamAppID
                self.stored.localGames[i].productRead = exe.path
                self.save()
                // Highball may know the game now, and "Automatic" follows its advice.
                self.writeProfile(for: id)
            }
        }
    }

    /// True when the user chose a cover for this added game.
    func hasCover(_ id: Int) -> Bool { stored.localGames.first { $0.id == id }?.cover != nil }

    /// Lets the user pick a picture for an added game. Unwine keeps its own copy, so the picture
    /// can move or go later.
    func chooseCover(for game: SteamGame) {
        guard game.localExe != nil, !ArtState.shared.preparing.contains(game.id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a cover for \(game.name)"
        panel.message = "Pick a picture for \(game.name). A tall picture fits the tile best."
        panel.prompt = "Use as cover"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let id = game.id
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.setCover(from: url, id: id) }
        }
    }

    private func setCover(from url: URL, id: Int) async {
        ArtState.shared.preparing.insert(id)
        defer { ArtState.shared.preparing.remove(id) }
        let saved = await Task.detached(priority: .userInitiated) { Result { try ArtCache.importCover(from: url, for: id) } }.value
        switch saved {
        case .failure(let error):
            banner = "Unwine could not save a copy of \(url.lastPathComponent): \(error.localizedDescription)"
        case .success(nil):
            banner = "Unwine cannot read \(url.lastPathComponent) as a picture. Use Choose cover… again and pick a PNG, JPEG or HEIC file."
        case .success(let file?):
            guard let i = stored.localGames.firstIndex(where: { $0.id == id }) else {
                try? FileManager.default.removeItem(at: ArtCache.coverFile(file))   // removed while the picture was read
                return
            }
            let old = stored.localGames[i].cover
            stored.localGames[i].cover = file
            save()
            if let old { try? FileManager.default.removeItem(at: ArtCache.coverFile(old)) }
        }
    }

    /// Back to the program's own icon (or the game's initials when it has none).
    func resetCover(for game: SteamGame) {
        guard let i = stored.localGames.firstIndex(where: { $0.id == game.id }), let old = stored.localGames[i].cover else { return }
        stored.localGames[i].cover = nil
        save()
        try? FileManager.default.removeItem(at: ArtCache.coverFile(old))
    }

    // MARK: Highball

    /// Highball's entry for a game. A Steam game by its app id, as always. An added game by the
    /// steam_appid.txt next to its program, else by its ProductName, its name or its folder's name.
    func highballMatch(for appID: Int) -> HighballMatch? {
        guard LocalGames.isLocal(appID) else { return HighballDB.game(appID).map { HighballMatch(game: $0, way: .appID) } }
        guard let r = stored.localGames.first(where: { $0.id == appID }) else { return nil }
        if let steam = r.steamAppID, let game = HighballDB.game(steam) {
            return HighballMatch(game: Self.forAddedGame(game), way: .steamAppIDFile)
        }
        // The name without " · Launcher": a launcher is named after its game.
        let name = r.name.components(separatedBy: " · ").first ?? r.name
        for title in [r.productName, name, LocalGames.folderName(for: URL(fileURLWithPath: r.exePath))].compactMap({ $0 }) {
            if let game = HighballDB.game(title: title) { return HighballMatch(game: Self.forAddedGame(game), way: .title) }
        }
        return nil
    }

    /// A game added by its .exe runs without Steam, so Valve's anti-cheat (VAC) does not come into
    /// it, and Online mode (Windows Steam) is not offered for it. Highball's VAC entry would only tell
    /// the player to use Online mode.
    private static func forAddedGame(_ game: HighballGame) -> HighballGame {
        guard var anticheat = game.anticheat else { return game }
        anticheat.names.removeAll { ["vac", "valve anti-cheat"].contains($0.lowercased()) }
        var copy = game
        copy.anticheat = anticheat.names.isEmpty && anticheat.macVerdict?.lowercased() != "blocked" ? nil : anticheat
        return copy
    }
}

extension Advice {
    /// Names the Highball entry when Unwine found an added game there by itself, so a wrong match
    /// shows on the game page.
    func found(by match: HighballMatch?) -> Advice {
        guard let match, match.way != .appID else { return self }
        var advice = self
        advice.source += ", for \u{201C}\(match.game.title)\u{201D}. Unwine found the game there "
            + (match.way == .title ? "by its name" : "by the Steam app ID in its folder")
        return advice
    }
}
