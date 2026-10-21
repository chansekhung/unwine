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

    private var busy: Bool { model.localStarting[game.id] != nil || model.localRunning.contains(game.id) }

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
            Button { model.play(game) } label: {
                Label(model.macSteamBlocked ? "Play (Steam is closed while Online mode runs)" : "Play in Steam", systemImage: "play.fill")
            }
            .disabled(model.macSteamBlocked || game.state != .installed)
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
            if let step = model.localStarting[game.id] {
                HStack(spacing: 8) {
                    UnwineMark(progress: nil, size: 18)
                    PhaseWords(words: [step, "Windows games start slowly on a Mac"]).font(.system(size: 11, weight: .medium))
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            } else if hovering {
                Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(game.localExe == nil ? model.macSteamBlocked : (model.localStarting[game.id] != nil || model.localRunning.contains(game.id)))
                    .help(game.localExe == nil
                          ? (model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Starts in Steam with this game's settings")
                          : (model.localRunning.contains(game.id) ? "\(game.name) is running. Open its page to quit it." : model.localStarting[game.id] ?? "Starts the game without Steam"))
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
