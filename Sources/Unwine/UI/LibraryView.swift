import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var chosenProgram: (exe: URL, folder: URL?)?   // added once the chooser has closed, so a question can show
    @State private var renaming: SteamGame?
    @State private var newName = ""
    @State private var removing: SteamGame?
    @State private var search = ""
    @State private var showHidden = false
    @State private var dropping = false
    @State private var gridWidth: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedTile: Int?

    private static let tileWidth: CGFloat = 150, tileSpacing: CGFloat = 18, gridPadding: CGFloat = 24
    private let columns = [GridItem(.adaptive(minimum: tileWidth, maximum: 190), spacing: tileSpacing)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            BannerHost()
            steamPlayNotice
                .confirmationDialog("Quit the game too?", isPresented: Binding(get: { model.onlineForceQuit != nil && model.librarySheet == nil },
                                                                             set: { if !$0 { model.onlineForceQuit = nil } })) {
                    Button("Quit game and Windows Steam", role: .destructive) { Task { await model.stopOnline(force: true) } }
                } message: {
                    Text("\((model.onlineForceQuit ?? []).joined(separator: ", ")) is still running in Windows Steam. Unwine asks it to close first. Progress you have not saved can be lost.")
                }
            updateNotice
            library
        }
        .overlay { if dropping { DropHint() } }
        // A game's folder or .exe dropped on the window goes the same way as Add game.
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .sheet(item: $model.librarySheet, onDismiss: {
            // The chosen program is added once the chooser has closed, so a question about it can show.
            if let chosen = chosenProgram { model.addLocalGame(exe: chosen.exe, folder: chosen.folder) }
            chosenProgram = nil
        }) { sheet in
            switch sheet {
            case .game(let id):
                GameSheet(gameID: id).environment(model)
            case .settings:
                SettingsView().environment(model)
            case .chooser(let folder, let programs):
                // Without a list, the chooser looks through the folder itself, with a designed wait.
                ProgramChooser(folder: folder, programs: programs) { exe in
                    if let exe { chosenProgram = (exe, folder) }
                    model.librarySheet = nil
                }
            case .logs(let id, let log, let back):
                // From a banner's Show logs. Opened over a game's page or Settings, Done goes back there.
                LogsView(gameID: id, log: log, done: back.map { sheet in { model.librarySheet = sheet } })
                    .environment(model)
            }
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let game = renaming { model.renameLocalGame(game.id, to: newName) } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing?.name ?? "") from Unwine?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { game in
            Button("Remove", role: .destructive) { model.removeLocalGame(game) }
        } message: { game in
            Text(model.removeNote(for: game))
        }
        // A game folder goes to the chooser, which finds its programs and asks when it is not obvious.
        .fileImporter(isPresented: $model.pickingGame, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data, .folder]) { result in
            if case .success(let url) = result { model.add([url]) }
        }
        .modifier(SteamCopyDialog(open: { model.openPage($0) }))
        .onChange(of: model.findRequests) { searchFocused = true }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            UnwineMark(progress: 1, size: 34)
            Text("Unwine").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Palette.text)
            if model.libraryLoaded && !model.windowsGames.isEmpty {
                searchField.padding(.leading, 8)
            }
            Spacer()
            steamPill
            Button { model.openMacSteam() } label: { Label("Open Steam", systemImage: "arrow.up.forward.app") }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.macSteamBlocked || model.steamMissing)
                .help(model.steamMissing ? AppModel.steamMissingReason : model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens Mac Steam")
            Button { model.pickingGame = true } label: { Label("Add game", systemImage: "plus") }
                .buttonStyle(QuietButtonStyle())
                .help("Add a Windows game by its folder or its .exe (⌘O). You can also drop it on this window. It runs without Steam.")
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(QuietButtonStyle())
                .help("Settings, updates and GPTK (⌘,)")
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Search games", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // Return or the down arrow goes on to the first game, so the keyboard can open or play it.
                .onSubmit(focusFirstTile)
                .onKeyPress(.downArrow) { focusFirstTile(); return .handled }
                .onExitCommand { search = ""; searchFocused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().stroke(searchFocused ? Palette.accent : Palette.stroke))
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 240)
        .help("Find a game by its name (⌘F)")
    }

    private func focusFirstTile() {
        focusedTile = model.shelves(search: search).first?.id
    }

    private var steamPill: some View {
        if model.steamMissing { return StatusPill(text: "Steam not installed", color: Palette.muted) }
        if model.onlineStep.isRunning { return StatusPill(text: "Setting up Online mode", color: Palette.glow) }
        if model.online.running { return StatusPill(text: "Online mode on", color: Palette.glow) }
        switch (model.steamRunning, model.steamPlay) {
        case (true, .on): return StatusPill(text: "Steam Play on", color: Palette.ok)
        case (_, .outdated): return StatusPill(text: "Steam updated", color: Palette.warn)
        case (false, _): return StatusPill(text: "Steam closed", color: Palette.muted)
        case (true, .off): return StatusPill(text: "Steam Play off", color: Palette.warn)
        }
    }

    @ViewBuilder private var steamPlayNotice: some View {
        if model.onlineQuitOffer != nil && model.online.running && !model.onlineBusy {
            OnlineQuitOffer()
        } else if model.online.running || model.onlineBusy {
            NoticeCard(icon: "globe", color: Palette.glow,
                       title: model.online.running ? "Online mode is on" : "Switching Steam",
                       text: model.willReopenMacSteam
                        ? "Windows Steam is open for online play. Mac Steam stays closed and comes back when you quit Windows Steam."
                        : "Windows Steam is open for online play. Mac Steam stays closed while it runs.") {
                if let words = model.onlineWords {
                    UnwineMark(progress: nil, size: 20)
                    PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                    if model.onlineClosing {
                        Button("Close now") { model.hurryOnlineQuit() }.buttonStyle(QuietButtonStyle())
                            .help("Ends Windows Steam without waiting. Steam Cloud may not finish saving this session.")
                    }
                } else {
                    Button("Quit Windows Steam") { Task { await model.stopOnline() } }.buttonStyle(PrimaryButtonStyle())
                        .help("Steam Cloud saves sync first.")
                }
            }
        } else if model.online.inUse && !model.onlineStep.isRunning {
            NoticeCard(icon: "globe", color: Palette.warn,
                       title: "Windows programs are still running",
                       text: "Windows Steam is closed, but something still runs in its bottle. Engine updates wait for it.") {
                Button("Stop them") { Task { await model.stopOnline() } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.onlineBusy)
            }
        } else {
            macSteamNotice
        }
    }

    @ViewBuilder private var macSteamNotice: some View {
        switch model.steamPlay {
        case .outdated:
            NoticeCard(icon: "exclamationmark.triangle.fill", color: Palette.warn,
                       title: "Steam updated, and Steam Play does not match it yet",
                       text: "Your games stay installed. Steam Play's add-on needs a newer build from NotProton's project. Unwine already pulled in its newest matching files.") {
                RestartSteamButton()
                Button("NotProton releases") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton/releases")!) }
                    .buttonStyle(QuietButtonStyle())
            }
        case .off where model.steamRunning || model.steamRestartWords != nil:     // stays through a restart
            NoticeCard(icon: "hand.point.right.fill", color: Palette.warn,
                       title: "Steam does not list Unwine right now",
                       text: "Unwine's tool is ready. It appears in Steam once Steam Play is on in Steam.") {
                RestartSteamButton()
                Button("How Steam Play works") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton#readme")!) }
                    .buttonStyle(QuietButtonStyle())
            }
        default:
            EmptyView()
        }
    }

    /// A downloaded Unwine update waits for a click. Settings has the same button; this card is for
    /// people who never open Settings.
    @ViewBuilder private var updateNotice: some View {
        if model.menuUpdateCheck && model.isCheckingUpdates {
            // Check for Updates… from the menu: the menu closes, so the wait shows here.
            NoticeCard(icon: "arrow.triangle.2.circlepath", color: Palette.glow, title: "Checking for updates",
                       text: "Unwine looks for a newer engine, newer Steam Play files and a newer Unwine. The result shows at the top.") {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: ["Looking for a newer engine…", "Checking the Steam Play files…", "Looking for a newer Unwine…",
                                   "A new engine is about 260 MB"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
        } else if case .readyToInstall(let version) = model.appUpdater.status, !model.updateCardHidden {
            NoticeCard(icon: "arrow.down.circle.fill", color: Palette.ok, title: "Unwine \(version) is ready",
                       text: "It installs in a few seconds. Then Unwine opens again. Your games and settings stay.") {
                Button("Install") { model.appUpdater.installAndRelaunch() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.updateBlocker != nil)
                    .help(model.updateBlocker ?? "Unwine closes, puts in the new version and opens again")
                Button("Later") { model.updateCardHidden = true }.buttonStyle(QuietButtonStyle())
                    .help("Hides this card until Unwine opens again. Settings also has the Install button.")
            }
        }
    }

    // MARK: Library

    @ViewBuilder private var library: some View {
        if !model.libraryLoaded {
            LibrarySkeleton(columns: columns)
        } else if model.windowsGames.isEmpty {
            emptyState
        } else {
            let shelves = model.shelves(search: search)
            filterBar(shelves)
            if shelves.isEmpty && !(showHidden && !shelves.hidden.isEmpty) {
                noMatch(shelves)
            } else {
                grid(shelves)
            }
        }
    }

    private func filterBar(_ shelves: LibraryShelves) -> some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { filter in
                FilterChip(title: filter.title, count: shelves.counts[filter] ?? 0, selected: model.libraryFilter == filter) {
                    model.libraryFilter = filter
                }
                .help(filter.help)
            }
            Spacer(minLength: 8)
            sortMenu
        }
        .padding(.horizontal, 24).padding(.top, 10)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { model.librarySort }, set: { model.librarySort = $0 })) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Sort: \(model.librarySort.title)", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Palette.text)
        .help("How the library orders your games")
    }

    private func grid(_ shelves: LibraryShelves) -> some View {
        let rows = [shelves.favourites, shelves.games] + (showHidden ? [shelves.hidden] : [])
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    shelf("Favourites", shelves.favourites, rows: rows)
                    shelf(shelves.favourites.isEmpty ? nil : "Games", shelves.games, rows: rows)
                    if showHidden { shelf("Hidden", shelves.hidden, rows: rows, dimmed: true) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(Self.gridPadding)
                hiddenFooter(shelves.hidden.count)
            }
            .onChange(of: focusedTile) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String?, _ games: [SteamGame], rows: [[SteamGame]], dimmed: Bool = false) -> some View {
        if !games.isEmpty {
            Section {
                ForEach(games) { game in
                    GameTile(game: game, focus: $focusedTile, dimmed: dimmed,
                             open: { model.openPage(game) },
                             rename: { newName = game.name; renaming = game },
                             remove: { removing = game },
                             move: { moveFocus($0, from: game.id, rows: rows) },
                             typed: typeToSearch)
                        .id(game.id)
                }
            } header: {
                if let title {
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.glow.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    /// Typing on a tile searches, like in Finder. The focus goes on to the first game that matches,
    /// so the next key searches on; the search field would select its text and lose the letters.
    private func typeToSearch(_ key: TileKey) {
        let before = search
        switch key {
        case .text(let letters): search += letters
        case .deleteLast: if !search.isEmpty { search.removeLast() }
        case .clear: search = ""
        }
        guard search != before else { return }
        if let first = model.shelves(search: search).first { focusedTile = first.id } else { searchFocused = true }
    }

    /// Hidden games stay one click away, so hiding never makes a game unreachable.
    @ViewBuilder private func hiddenFooter(_ count: Int) -> some View {
        if count > 0 {
            Button { showHidden.toggle() } label: {
                Label(showHidden ? "Hidden games (\(count)) · Hide again" : "Hidden games (\(count)) · Show",
                      systemImage: showHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(QuietButtonStyle())
            .help(showHidden ? "Puts the hidden games away again" : "Shows the games you hid. Right-click one and choose Show in Library to bring it back.")
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
    }

    /// Arrow keys move between tiles: along a row, and to the same column a row up or down, also
    /// into the shelf above or below. Up from the top row goes to the search field.
    private func moveFocus(_ move: TileMove, from id: Int, rows: [[SteamGame]]) {
        let shelves = rows.filter { !$0.isEmpty }
        guard let s = shelves.firstIndex(where: { $0.contains { $0.id == id } }),
              let i = shelves[s].firstIndex(where: { $0.id == id }) else { return }
        // As many columns as the adaptive grid fits: each at least tileWidth, with the spacing between.
        let n = max(1, Int((gridWidth + Self.tileSpacing) / (Self.tileWidth + Self.tileSpacing)))
        let flat = shelves.flatMap { $0 }
        switch move {
        case .left, .right:
            guard let f = flat.firstIndex(where: { $0.id == id }) else { return }
            let j = f + (move == .left ? -1 : 1)
            if flat.indices.contains(j) { focusedTile = flat[j].id }
        case .down:
            if i + n < shelves[s].count {
                focusedTile = shelves[s][i + n].id
            } else if i / n < (shelves[s].count - 1) / n {
                focusedTile = shelves[s].last?.id      // the last row is shorter
            } else if s + 1 < shelves.count {
                focusedTile = shelves[s + 1][min(i % n, shelves[s + 1].count - 1)].id
            }
        case .up:
            if i >= n {
                focusedTile = shelves[s][i - n].id
            } else if s > 0 {
                let above = shelves[s - 1]
                focusedTile = above[min((above.count - 1) / n * n + i % n, above.count - 1)].id
            } else {
                searchFocused = true
            }
        }
    }

    /// The search or the filter left no game. Each way out is one click.
    private func noMatch(_ shelves: LibraryShelves) -> some View {
        let filter = model.libraryFilter
        let hidden = shelves.hidden.count
        let title: String, detail: String
        if !search.isEmpty {
            title = "No game matches \u{201C}\(search)\u{201D}"
            detail = filter != .all ? "Unwine looked only in \u{201C}\(filter.title)\u{201D}."
                : hidden > 0 ? "Hidden games do not show in the results." : "Check the spelling, or type a part of the name."
        } else {
            switch filter {
            case .running: title = "No game runs now"; detail = "Games show here while they run."
            case .attention: title = "No game needs attention"; detail = "Every game is ready to play."
            case .steam:
                title = "No Steam games here"
                detail = model.steamMissing ? AppModel.steamMissingReason : "Install a Windows game in Steam. It shows up here by itself."
            case .added: title = "No added games yet"; detail = "Add a Windows game by its folder or its .exe. It runs without Steam."
            case .all: title = "All your games are hidden"; detail = "Hidden games stay in Unwine. Show them to bring one back."
            }
        }
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: search.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 34)).foregroundStyle(Palette.glow.opacity(0.8))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                if !search.isEmpty {
                    Button("Clear search") { search = ""; searchFocused = true }.buttonStyle(PrimaryButtonStyle())
                }
                if filter != .all {
                    Button("Show all games") { model.libraryFilter = .all }
                        .buttonStyle(search.isEmpty ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
                }
                if filter == .added && search.isEmpty {
                    Button("Add a game folder or .exe") { model.pickingGame = true }.buttonStyle(QuietButtonStyle())
                }
                if filter == .steam && search.isEmpty && model.steamMissing {
                    Button("Get Steam") { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/about/")!) }
                        .buttonStyle(QuietButtonStyle())
                        .help("Opens Valve's page, where you download Steam for Mac")
                }
                if hidden > 0 {
                    Button("Show hidden games (\(hidden))") { showHidden = true }
                        .buttonStyle(search.isEmpty && filter == .all ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            UnwineMark(progress: 0.1, size: 80)
            Text("No Windows games yet").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.text)
            Text(model.steamMissing
                 ? "Add a Windows game by its folder or its .exe. It runs without Steam. To play Steam games, get Steam first."
                 : "Install any Windows game in Steam, like on a Steam Deck. It shows up here by itself, ready to tune.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                if model.steamMissing {
                    Button("Add a game folder or .exe") { model.pickingGame = true }.buttonStyle(PrimaryButtonStyle())
                        .help("For Windows games from outside Steam. They run without Steam.")
                    Button("Get Steam") { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/about/")!) }
                        .buttonStyle(QuietButtonStyle())
                        .help("Opens Valve's page, where you download Steam for Mac")
                } else {
                    Button("Open the Steam Store") { model.openStore() }.buttonStyle(PrimaryButtonStyle())
                        .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens the store in Mac Steam")
                    Button("Open Steam") { model.openMacSteam() }.buttonStyle(QuietButtonStyle())
                        .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens Mac Steam")
                    Button("Add a game folder or .exe") { model.pickingGame = true }.buttonStyle(QuietButtonStyle())
                        .help("For Windows games from outside Steam. They run without Steam.")
                }
            }
            Text("You can also drop a game's folder or .exe on this window.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Picks between the app's two button styles at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: @MainActor (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Tile

struct GameTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: SteamGame
    var focus: FocusState<Int?>.Binding
    var dimmed = false
    let open: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    let move: (TileMove) -> Void
    let typed: (TileKey) -> Void        // letters typed on a tile search the library
    @State private var hovering = false
    @State private var confirmQuit = false

    private var busy: Bool { model.localStarting[game.id] != nil || model.localRunning.contains(game.id) }
    private var focused: Bool { focus.wrappedValue == game.id }
    private var favourite: Bool { model.isFavourite(game.id) }
    private var hidden: Bool { model.isHidden(game.id) }

    /// A menu item cannot show a tooltip, so a Steam game's blocked Play says why in its title.
    private var steamPlayTitle: String {
        if model.macSteamBlocked { return "Play (Steam is closed while Online mode runs)" }
        switch game.state {
        case .downloading: return "Play (finish the download in Steam first)"
        case .needsUpdate: return "Play (finish the update in Steam first)"
        case .installed: break
        }
        if model.steamRestartWords != nil || model.busyGame != nil { return "Play (Steam is restarting)" }
        switch model.runState(of: game) {
        case .starting: return "Play (the game is starting)"
        case .closing: return "Play (the game is closing)"
        case .idle, .running: return "Play in Steam"
        }
    }

    private var busy: Bool { model.localStarting[game.id] != nil || model.localRunning.contains(game.id) }

    var body: some View {
        let badge = model.badges(for: game).first
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                GameArt(appID: game.id, kind: .capsule, title: game.name)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hovering ? Palette.accent : Palette.stroke, lineWidth: hovering ? 2 : 1))
                    .overlay(alignment: .topTrailing) { if let badge { TileBadgeView(badge: badge).padding(8) } }
                overlay
            }
            // The keyboard focus ring sits outside the art, so it never covers a badge or a button.
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Palette.accent, lineWidth: 3).padding(-4)
                }
            }
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            Text(game.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            Text(game.playedShort).font(.system(size: 11)).foregroundStyle(Palette.muted.opacity(0.8)).lineLimit(1)
        }
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        // A tile is a button for the keyboard: Return opens its page, ⌘Return plays, arrows move on.
        // Like a Finder icon, a click selects it too, and Tab reaches it without Full Keyboard Access.
        .focusable(interactions: .edit)
        .focused(focus, equals: game.id)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .contextMenu { menu }
        .confirmationDialog("Quit \(game.name)?", isPresented: $confirmQuit) {
            Button("Quit game", role: .destructive) { Task { await model.quitSteamGame(game) } }
        } message: {
            Text(AppModel.quitGameWarning)
        }
        .task(id: game.state) { await model.analyze(game) }
        .help("Opens the page of \(game.name). Right-click for more.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityValue(spoken(badge))
        .accessibilityHint("Opens the game's page")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Play") { model.playIfReady(game) }
        .accessibilityAction(named: favourite ? "Remove from Favourites" : "Add to Favourites") { model.setFavourite(!favourite, game) }
        .accessibilityAction(named: hidden ? "Show in Library" : "Hide") { model.setHidden(!hidden, game) }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            if press.modifiers.contains(.command) { model.playIfReady(game) } else { open() }
            return .handled
        case .leftArrow: move(.left); return .handled
        case .rightArrow: move(.right); return .handled
        case .upArrow: move(.up); return .handled
        case .downArrow: move(.down); return .handled
        case .delete where press.modifiers.isEmpty: typed(.deleteLast); return .handled
        case .escape: typed(.clear); return .handled
        default:
            // Typing a name finds the game, like in Finder. Tab and shortcuts keep their own jobs.
            let printable = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).union(.init(charactersIn: " "))
            guard press.modifiers.subtracting(.shift).isEmpty, !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy(printable.contains) else { return .ignored }
            typed(.text(press.characters))
            return .handled
        }
    }

    /// What VoiceOver reads after the name: the layer, when it was played, a badge, a download, and
    /// what a start or a quit is doing.
    private func spoken(_ badge: TileBadge?) -> String {
        var parts = [subtitle, game.playedShort]
        if let badge { parts.append("\(badge.text): \(badge.reason)") }
        switch game.state {
        case .downloading(let p): parts.append(p.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Downloading")
        case .needsUpdate: parts.append("Needs an update in Steam")
        case .installed: if let step = model.runState(of: game).waitWords?.first { parts.append(step) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Right-click: the actions people look for on a game, without opening its page first. A menu
    /// item cannot show a tooltip, so a blocked one says why in its own title.
    @ViewBuilder private var menu: some View {
        if game.localExe != nil {
            // While a start or a quit goes on, the step says which ("Closing …" is a quit, as in RunState).
            let step = model.localStarting[game.id]
            let closing = step?.hasPrefix("Closing") == true
            if model.localRunning.contains(game.id) {
                // The page's Quit game: it ends everything in the game's bottle at once.
                Button { Task { await model.stopLocal(game) } } label: {
                    Label(step == nil ? "Quit game" : closing ? "Quit game (closing now)" : "Quit game (the game is starting)", systemImage: "stop.fill")
                }
                .disabled(step != nil)
            } else {
                Button { model.play(game) } label: {
                    Label(step == nil ? "Play" : closing ? "Play (the game is closing)" : "Play (the game is starting)", systemImage: "play.fill")
                }
                .disabled(step != nil)
            }
        } else if model.steamGamesRunning.contains(game.id) {
            // The bottle is open: the game runs, or its start hangs. Quit game asks first.
            Button { confirmQuit = true } label: {
                Label(model.quittingGames.contains(game.id) ? "Quit game (closing now)" : "Quit game…", systemImage: "stop.fill")
            }
            .disabled(model.quittingGames.contains(game.id))
        } else {
            Button { model.play(game) } label: { Label(steamPlayTitle, systemImage: "play.fill") }
                .disabled(model.steamPlayBlocker(game) != nil)
        }
        Button { open() } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
        if let exe = game.localExe, !FileManager.default.fileExists(atPath: exe.path) {
            Button { model.locateLocalGame(game) } label: { Label("Locate \(exe.lastPathComponent)…", systemImage: "questionmark.folder") }
        }
        Divider()
        Button { model.setFavourite(!favourite, game) } label: {
            Label(favourite ? "Remove from Favourites" : "Add to Favourites", systemImage: favourite ? "star.slash" : "star")
        }
        Button { model.setHidden(!hidden, game) } label: {
            Label(hidden ? "Show in Library" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
        }
        Divider()
        if game.localExe != nil {
            Button { rename() } label: { Label("Rename…", systemImage: "pencil") }
            // The cover items wait while Unwine copies a picked picture.
            let copying = ArtState.shared.preparing.contains(game.id)
            Button { model.chooseCover(for: game) } label: {
                Label(copying ? "Choose cover… (Unwine is copying a picture)" : "Choose cover…", systemImage: "photo")
            }
            .disabled(copying)
            if model.hasCover(game.id) {
                Button { model.resetCover(for: game) } label: {
                    Label(copying ? "Reset cover (Unwine is copying a picture)" : "Reset cover", systemImage: "arrow.uturn.backward")
                }
                .disabled(copying)
            }
            Button(role: .destructive) { remove() } label: {
                Label(busy ? "Remove from Unwine… (quit the game first)" : "Remove from Unwine…", systemImage: "trash")
            }
            .disabled(busy)
        } else {
            Button { model.showInSteam(game.id) } label: { Label("Show in Steam (rename or uninstall it there)", systemImage: "arrow.up.forward.app") }
                .disabled(model.macSteamBlocked)
        }
    }

    private var subtitle: String {
        let r = model.resolvedRenderer(for: game)
        let api = model.analysis(for: game)?.api.label
        return [game.localExe.flatMap(LocalGames.role(of:)), r.short, api].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .downloading(let p):
            // Nothing to play yet: the click goes to the download in Steam.
            Button { model.openSteamDownloads() } label: {
                VStack(spacing: 6) {
                    Text(p.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…").font(.system(size: 11, weight: .medium))
                    ProgressTrack(progress: p, height: 4)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.macSteamBlocked)
            .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens Steam's downloads. Play works when the download finishes.")
            .padding(8)
        case .needsUpdate:
            Button { model.showInSteam(game.id) } label: {
                Label("Update in Steam", systemImage: "arrow.down.circle").font(.system(size: 11, weight: .medium)).padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.macSteamBlocked)
            .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens this game in Steam. Steam has an update for it. Play works after the update.")
            .padding(8)
        case .installed:
            // Starting and closing show their words, an idle game Play on hover. A running game has
            // its Running badge in the tile's badge slot (TileBadge).
            let run = model.runState(of: game)
            if let words = run.waitWords {
                HStack(spacing: 8) {
                    UnwineMark(progress: nil, size: 18)
                    PhaseWords(words: words).font(.system(size: 11, weight: .medium))
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            } else if run != .running && hovering {
                let blocker = game.localExe == nil ? model.steamPlayBlocker(game) : nil
                Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(blocker != nil)
                    .help(blocker ?? (game.localExe == nil ? "Starts in Steam with this game's settings" : "Starts the game without Steam"))
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

extension Renderer {
    var short: String {
        switch self {
        case .auto: return "Auto"
        case .d3dmetal: return "GPTK"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }
}

// MARK: - Picking the program in a game folder

/// Lists the programs in a game folder, the likeliest first, so the user picks the one that starts
/// the game. Without a list it looks through the folder itself, three folders deep and off the main
/// thread, with a designed wait. Return picks the first program; "Choose another file…" any other.
struct ProgramChooser: View {
    let folder: URL?
    /// The programs to list. Nil: the chooser looks through `folder` itself.
    var programs: [(url: URL, size: Int64)]? = nil
    var title = "Which program starts the game?"
    var intro: String? = nil
    /// When the folder holds only one program, it is picked with no question.
    var pickSingle = true
    let done: (URL?) -> Void
    @State private var found: [(url: URL, size: Int64)]?

    private var list: [(url: URL, size: Int64)]? { programs ?? found }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.text)
            if let list {
                if list.isEmpty {
                    Text("No .exe file is in \(folder?.lastPathComponent ?? "this folder") or in the folders in it. Press Choose another file… to pick the program yourself, or press Cancel and add the folder that holds it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    Text(intro ?? "Unwine found \(list.count == 1 ? "1 program" : "\(list.count) programs") in \(folder?.lastPathComponent ?? "the folder"). The likeliest is first: usually the biggest one that is not a setup or a tool. A launcher works too, if the game has one. Press Return to add the first one.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    rows(list)
                }
            } else {
                searching
            }
            HStack {
                Button("Choose another file…") {
                    if let url = FilePicker.pick(message: "Pick the program that starts the game.", prompt: "Choose", extensions: ["exe"], in: folder) { done(url) }
                }
                .buttonStyle(QuietButtonStyle())
                .help("Pick any .exe file yourself")
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(AppBackground())
        .task(id: folder) { await scan() }
    }

    private func rows(_ list: [(url: URL, size: Int64)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, p in
                    let row = Button { done(p.url) } label: {
                        HStack {
                            Image(systemName: i == 0 ? "star.fill" : "app").foregroundStyle(i == 0 ? Palette.glow : Palette.muted)
                            Text(relative(p.url)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if i == 0 { Text("Return").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.glow) }
                            Text(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file)).foregroundStyle(Palette.muted)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == 0 ? Palette.accent.opacity(0.18) : Palette.card))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Uses \(p.url.lastPathComponent) as the game")
                    if i == 0 { row.keyboardShortcut(.defaultAction) } else { row }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    /// While the folder is read: the coil, words that change, and rows still to come.
    private var searching: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 22)
                PhaseWords(words: ["Looking for the game's program…", "Reading \(folder?.lastPathComponent ?? "the folder") and the folders in it",
                                   "Big games have many files"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ForEach(0..<4, id: \.self) { _ in
                Shimmer().frame(height: 30).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func scan() async {
        guard programs == nil else { return }
        guard let folder else { found = []; return }
        let list = await Task.detached(priority: .userInitiated) { LocalGames.programs(in: folder) }.value
        if pickSingle, list.count == 1 { done(list[0].url) } else { found = list }
    }

    private func relative(_ url: URL) -> String {
        guard let folder else { return url.lastPathComponent }
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
    }
}

// MARK: - Art

/// A game's picture. A Steam game: Steam's own cache (works offline), then Unwine's copy of Steam's
/// CDN art, then the CDN; art that failed tries again when the next Steam refresh lands. An added
/// game: the cover the user chose, else its program's icon on a tile of the game's own colour.
/// Without either, that tile shows the game's initials.
struct GameArt: View {
    @Environment(AppModel.self) private var model
    let appID: Int
    let kind: SteamLibrary.ArtKind
    let title: String
    /// The last picture loaded, with the source it came from.
    @State private var picture: Picture?
    /// The source whose load finished, with a picture or without one.
    @State private var settled: String?

    private struct Picture {
        let source: String
        let image: NSImage
        let isIcon: Bool
    }

    init(appID: Int, kind: SteamLibrary.ArtKind, title: String) {
        self.appID = appID
        self.kind = kind
        self.title = title
        // A tile that scrolls back into view shows its art at once, or its placeholder when the art
        // failed, instead of a shimmer.
        guard !LocalGames.isLocal(appID) else { return }
        let source = "steam:\(appID):\(kind.rawValue)"
        if let known = ArtCache.remembered(steamAppID: appID, kind) {
            _picture = State(initialValue: Picture(source: source, image: NSImage(cgImage: known, size: .zero), isIcon: false))
            _settled = State(initialValue: source)
        } else if ArtCache.hasFailed(appID, kind) {
            _settled = State(initialValue: source)
        }
    }

    var body: some View {
        let local = LocalGames.isLocal(appID) ? model.localArt(for: appID) : nil
        let want = source(local)
        let failed = local == nil && settled == want && picture?.source != want
        ZStack {
            if local?.waiting == true {
                Shimmer()
            } else if let picture, picture.source == want || settled != want {
                // The new picture, or the old one while the new one loads.
                if picture.isIcon {
                    ArtPlaceholder(title: title, wide: kind == .hero, icon: picture.image)
                } else {
                    Image(nsImage: picture.image).resizable().scaledToFill()
                }
            } else if settled == want {
                ArtPlaceholder(title: title, wide: kind == .hero, icon: nil)
            } else {
                Shimmer()
            }
        }
        // Only a tile whose Steam art failed watches the refreshes.
        .task(id: failed ? "\(want)#\(ArtState.shared.refreshes)" : want) { await load(want, local) }
    }

    /// Which picture this game should show now.
    private func source(_ local: LocalArt?) -> String {
        guard let local else { return "steam:\(appID):\(kind.rawValue)" }
        if local.waiting { return "wait" }
        if let cover = local.cover { return "cover:\(cover.lastPathComponent)" }
        if let icon = local.icon { return "icon:\(icon.lastPathComponent)|\(local.stamp)" }
        return "none"
    }

    private func load(_ want: String, _ local: LocalArt?) async {
        var image: CGImage?
        var isIcon = false
        if let local {
            guard !local.waiting else { return }
            if let cover = local.cover { image = await ArtCache.picture(at: cover) }
            // A cover file that went missing gives way to the icon.
            if image == nil, let icon = local.icon {
                image = await ArtCache.picture(at: icon)
                isIcon = image != nil
            }
        } else {
            image = await ArtCache.steamPicture(appID, kind)
        }
        guard !Task.isCancelled else { return }
        if let image { picture = Picture(source: want, image: NSImage(cgImage: image, size: .zero), isIcon: isIcon) }
        settled = want
    }
}

// MARK: - Small pieces

struct NoticeCard<Actions: View>: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted)
                HStack(spacing: 8) { actions }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.4)))
        .padding(.horizontal, 24).padding(.top, 8)
    }
}
