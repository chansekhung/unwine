import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SteamGame?
    @State private var showSettings = false
    @State private var addingGame = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            steamPlayNotice
            if model.windowsGames.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(model.windowsGames) { game in
                            GameTile(game: game) { selected = game }
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
        .fileImporter(isPresented: $addingGame, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            if case .success(let url) = result { model.addLocalGame(exe: url) }
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
                .help("Add a Windows game or program by its .exe. It runs without Steam.")
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
        if model.online.running || model.onlineBusy {
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
            .confirmationDialog("Quit the game too?", isPresented: Binding(get: { model.onlineForceQuit != nil && selected == nil && !showSettings },
                                                                         set: { if !$0 { model.onlineForceQuit = nil } })) {
                Button("Quit game and Windows Steam", role: .destructive) { Task { await model.stopOnline(force: true) } }
            } message: {
                Text("\((model.onlineForceQuit ?? []).joined(separator: ", ")) is still running in Windows Steam. Unwine asks it to close first. Progress you have not saved can be lost.")
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
                Button("Restart Steam") { Task { await model.restartSteam() } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.gameRunning).help(model.gameRunning ? "Close your game first" : "Steam closes and opens again")
                Button("NotProton releases") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton/releases")!) }
                    .buttonStyle(QuietButtonStyle())
            }
        case .off where model.steamRunning:
            NoticeCard(icon: "hand.point.right.fill", color: Palette.warn,
                       title: "Steam does not list Unwine right now",
                       text: "Unwine's tool is ready. It appears in Steam once Steam Play is on in Steam.") {
                Button("Restart Steam") { Task { await model.restartSteam() } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.gameRunning).help(model.gameRunning ? "Close your game first" : "Steam closes and opens again")
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
                Button("Add a game by its .exe") { addingGame = true }.buttonStyle(QuietButtonStyle())
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
    @State private var hovering = false

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
        .task(id: game.state) { await model.analyze(game) }
        .help("Settings for \(game.name)")
    }

    private var subtitle: String {
        let r = model.resolvedRenderer(for: game)
        let api = model.analysis(for: game)?.api.label
        return [r.short, api].compactMap { $0 }.joined(separator: " · ")
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
            if hovering {
                Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(game.localExe == nil ? model.macSteamBlocked : (model.localStarting[game.id] != nil || model.localRunning.contains(game.id)))
                    .help(game.localExe == nil
                          ? (model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Starts in Steam with this game's settings")
                          : (model.localRunning.contains(game.id) ? "Already running" : model.localStarting[game.id] ?? "Starts the game without Steam"))
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
