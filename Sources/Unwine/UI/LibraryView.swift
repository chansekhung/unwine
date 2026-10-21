import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SteamGame?
    @State private var showSettings = false
    @State private var addingGame = false
    @State private var choosingProgram: [(url: URL, size: Int64)] = []
    @State private var choosingFolder: URL?
    @State private var renaming: SteamGame?
    @State private var newName = ""
    @State private var removing: SteamGame?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            steamPlayNotice
                .confirmationDialog("Quit the game too?", isPresented: Binding(get: { model.onlineForceQuit != nil && selected == nil && !showSettings },
                                                                             set: { if !$0 { model.onlineForceQuit = nil } })) {
                    Button("Quit game and Windows Steam", role: .destructive) { Task { await model.stopOnline(force: true) } }
                } message: {
                    Text("\((model.onlineForceQuit ?? []).joined(separator: ", ")) is still running in Windows Steam. Unwine asks it to close first. Progress you have not saved can be lost.")
                }
            if model.windowsGames.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(model.windowsGames) { game in
                            GameTile(game: game, open: { selected = game },
                                     rename: { newName = game.name; renaming = game },
                                     remove: { removing = game })
                        }
                    }
                    .padding(24)
                }
            }
        }
        .sheet(item: $selected) { game in
            GameSheet(gameID: game.id).environment(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(model)
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let game = renaming { model.renameLocalGame(game.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing?.name ?? "") from Unwine?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { game in
            Button("Remove", role: .destructive) { model.removeLocalGame(game) }
        } message: { game in
            Text(model.removeNote(for: game))
        }
        .fileImporter(isPresented: $addingGame, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data, .folder]) { result in
            guard case .success(let url) = result else { return }
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // A game folder: find its programs, then let the user pick when it is not obvious.
                let programs = LocalGames.programs(in: url)
                if programs.isEmpty {
                    model.banner = "No .exe file in \(url.lastPathComponent). Pick the folder that holds the game's program."
                } else if programs.count == 1 {
                    model.addLocalGame(exe: programs[0].url, folder: url)
                } else {
                    choosingFolder = url
                    choosingProgram = programs
                }
            } else {
                model.addLocalGame(exe: url)
            }
        }
        .sheet(isPresented: Binding(get: { !choosingProgram.isEmpty }, set: { if !$0 { choosingProgram = [] } })) {
            ProgramChooser(folder: choosingFolder, programs: choosingProgram) { exe in
                choosingProgram = []
                if let exe { model.addLocalGame(exe: exe, folder: choosingFolder) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            UnwineMark(progress: 1, size: 34)
            Text("Unwine").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Palette.text)
            Spacer()
            steamPill
            Button { model.openMacSteam() } label: { Label("Open Steam", systemImage: "arrow.up.forward.app") }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.macSteamBlocked)
                .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens Mac Steam")
            Button { addingGame = true } label: { Label("Add game", systemImage: "plus") }
                .buttonStyle(QuietButtonStyle())
                .help("Add a Windows game from its folder or its .exe. It runs without Steam.")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(QuietButtonStyle())
                .help("Settings, updates and GPTK")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var steamPill: some View {
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            UnwineMark(progress: 0.1, size: 80)
            Text("No Windows games yet").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.text)
            Text("Install any Windows game in Steam, like on a Steam Deck. It shows up here by itself, ready to tune.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Open the Steam Store") { model.openStore() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens the store in Mac Steam")
                Button("Open Steam") { model.openMacSteam() }.buttonStyle(QuietButtonStyle())
                    .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens Mac Steam")
                Button("Add a game folder or .exe") { addingGame = true }.buttonStyle(QuietButtonStyle())
                    .help("For Windows games from outside Steam. They run without Steam.")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tile

struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    let open: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    @State private var confirmQuit = false

    private var busy: Bool { model.localStarting[game.id] != nil || model.localRunning.contains(game.id) }

    /// A menu item cannot show a tooltip, so a Steam game's blocked Play says why in its title.
    private var steamPlayTitle: String {
        if model.macSteamBlocked { return "Play (Steam is closed while Online mode runs)" }
        if game.state != .installed { return "Play (finish the download in Steam first)" }
        if model.steamRestartWords != nil || model.busyGame != nil { return "Play (Steam is restarting)" }
        switch model.runState(of: game) {
        case .starting: return "Play (the game is starting)"
        case .closing: return "Play (the game is closing)"
        case .idle, .running: return "Play in Steam"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                GameArt(appID: game.id, kind: .capsule, title: game.name)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hovering ? Palette.accent : Palette.stroke, lineWidth: hovering ? 2 : 1))
                overlay
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            Text(game.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { menu }
        .confirmationDialog("Quit \(game.name)?", isPresented: $confirmQuit) {
            Button("Quit game", role: .destructive) { Task { await model.quitSteamGame(game) } }
        } message: {
            Text(AppModel.quitGameWarning)
        }
        .task(id: game.state) { await model.analyze(game) }
        .help("Settings for \(game.name). Right-click for more.")
    }

    /// Right-click: the actions people look for on a game, without opening its page first. A menu
    /// item cannot show a tooltip, so a blocked one says why in its own title.
    @ViewBuilder private var menu: some View {
        if game.localExe != nil {
            Button { model.play(game) } label: { Label(busy ? "Play (already running)" : "Play", systemImage: "play.fill") }
                .disabled(busy)
            Button { open() } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
            Divider()
            Button { rename() } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { remove() } label: {
                Label(busy ? "Remove from Unwine… (quit the game first)" : "Remove from Unwine…", systemImage: "trash")
            }
            .disabled(busy)
        } else {
            if model.steamGamesRunning.contains(game.id) {
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
            Divider()
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
            VStack(spacing: 6) {
                Text(p.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…").font(.system(size: 11, weight: .medium))
                ProgressTrack(progress: p, height: 4)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
        case .needsUpdate:
            Text("Update in Steam").font(.system(size: 11, weight: .medium)).padding(8)
                .background(.ultraThinMaterial, in: Capsule()).padding(8)
        case .installed:
            // Starting and closing show their words, a running game its badge, an idle one Play on hover.
            let run = model.runState(of: game)
            if let words = run.waitWords {
                HStack(spacing: 8) {
                    UnwineMark(progress: nil, size: 18)
                    PhaseWords(words: words).font(.system(size: 11, weight: .medium))
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            } else if run == .running {
                RunningBadge(help: game.localExe == nil ? "\(game.name) is running. To quit it, right-click it or open its page."
                                                        : "\(game.name) is running. To quit it, open its page.")
                    .padding(8)
            } else if hovering {
                let blocker = game.localExe == nil ? model.steamPlayBlocker(game) : nil
                Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(blocker != nil)
                    .help(blocker ?? (game.localExe == nil ? "Starts in Steam with this game's settings" : "Starts the game without Steam"))
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
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

/// Lists the programs found in a game folder, the likeliest first, so the user picks the one that
/// starts the game.
struct ProgramChooser: View {
    let folder: URL?
    let programs: [(url: URL, size: Int64)]
    let done: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which program starts the game?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.text)
            Text("Unwine found \(programs.count) programs in \(folder?.lastPathComponent ?? "the folder"). The likeliest is first: usually the biggest one that is not a setup or a tool. A launcher works too, if the game has one.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(programs.enumerated()), id: \.offset) { i, p in
                        Button { done(p.url) } label: {
                            HStack {
                                Image(systemName: i == 0 ? "star.fill" : "app").foregroundStyle(i == 0 ? Palette.glow : Palette.muted)
                                Text(relative(p.url)).foregroundStyle(Palette.text)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file)).foregroundStyle(Palette.muted)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == 0 ? Palette.accent.opacity(0.18) : Palette.card))
                        }
                        .buttonStyle(.plain)
                        .help("Adds \(p.url.lastPathComponent) as the game")
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(AppBackground())
    }

    private func relative(_ url: URL) -> String {
        guard let folder else { return url.lastPathComponent }
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
    }
}

// MARK: - Art

/// Steam's cached art first (offline), then Steam's CDN, then a lettered placeholder.
struct GameArt: View {
    let appID: Int
    let kind: SteamLibrary.ArtKind
    let title: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                ZStack {
                    LinearGradient(colors: [Palette.deep, Palette.accentDeep.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    Text(initials).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Palette.text.opacity(0.8))
                }
            } else {
                Shimmer()
            }
        }
        .task(id: appID) { await load() }
    }

    private var initials: String {
        title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func load() async {
        if let local = SteamLibrary.cachedArt(kind, appID: appID), let img = NSImage(contentsOf: local) {
            image = img
            return
        }
        // A game added by its .exe has no Steam art: it gets the lettered tile.
        for url in LocalGames.isLocal(appID) ? [] : SteamLibrary.remoteArt(kind, appID: appID) {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) {
                image = img
                return
            }
        }
        failed = true
    }
}

// MARK: - Small pieces

struct BannerView: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("Hide this message")
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Palette.accent.opacity(0.25))
    }
}

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
