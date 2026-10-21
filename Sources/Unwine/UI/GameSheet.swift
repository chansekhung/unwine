import SwiftUI
import UniformTypeIdentifiers

struct GameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: Int
    @State private var confirmReset = false
    @State private var confirmOnlineSetup = false
    @State private var confirmRemove = false
    @State private var locating = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var pickingInstalled = false
    @State private var installedList: [(url: URL, size: Int64)] = []   // kept while the chooser closes

    private var game: SteamGame? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let game {
            content(game)
        } else {
            VStack(spacing: 12) {
                Text("This game is no longer installed.").foregroundStyle(Palette.text)
                Button("Close") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            .padding(40)
        }
    }

    private func content(_ game: SteamGame) -> some View {
        let s = model.settings(for: game.id)
        let analysis = model.analysis(for: game)
        let resolved = model.resolvedRenderer(for: game)
        let advice = model.advice(for: game)
        let isLocal = game.localExe != nil
        // A launcher runs with its game's settings (the game it starts inherits them).
        let followed = model.settingsSource(for: game)
        // Online mode is Windows Steam: it has nothing to offer a game added by its .exe.
        let needsOnline: String? = { if !isLocal, case .needsOnlineMode(let ac) = advice.online { return ac }; return nil }()
        // DLSS becomes MetalFX through D3DMetal or DXMT; DXVK and Wine's own layer have no MetalFX.
        let canMetalFX = (analysis.map { $0.api == .dx11 || $0.api == .dx12 } ?? false) && (resolved == .d3dmetal || resolved == .dxmt)
        let canSharpen = model.canSharpen(game)
        let usesDecant = model.mappings[game.id] == Runner.toolName
        // Steam uses Unwine when it is mapped, or when no tool is mapped and the add-on's
        // default (Unwine, the only tool it lists) already ran this game.
        let mappedElsewhere = model.mappings[game.id].map { $0 != Runner.toolName } ?? false
        let neverRun = model.mappings[game.id] == nil && !FileManager.default.fileExists(atPath: game.compatData.path)

        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GameArt(appID: game.id, kind: .hero, title: game.name)
                    .frame(height: 170).clipped()
                LinearGradient(colors: [.clear, Palette.night.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.text)
                        Text(facts(game, analysis)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if needsOnline != nil && model.online.installed && model.online.signedIn {
                        Button { Task { await model.openOnline(game) } } label: { Label("Play online", systemImage: "globe") }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(playOnlineBlocker(game) != nil)
                            .help(playOnlineBlocker(game) ?? "Starts the game in Windows Steam, so online servers accept it")
                    }
                    if isLocal && model.localRunning.contains(game.id) {
                        Button { Task { await model.stopLocal(game) } } label: { Label("Quit game", systemImage: "stop.fill") }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.localStarting[game.id] != nil)
                            .help(model.localStarting[game.id] ?? "Ends everything running in this game's Windows bottle. Save in the game first.")
                    } else if isLocal {
                        Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.localStarting[game.id] != nil)
                            .help(model.localStarting[game.id] ?? "Starts the game with these settings, without Steam")
                    } else {
                        Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(game.state != .installed || model.macSteamBlocked)
                            .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason
                                  : game.state == .installed ? (needsOnline != nil ? "Single player and offline, through Mac Steam" : "Starts in Steam with these settings")
                                  : "Finish the download in Steam first")
                    }
                }
                .padding(18)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let banner = model.banner {
                        NoticeRow(color: Palette.glow, icon: "info.circle", text: banner) {
                            Button { model.banner = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Hide this message")
                        }
                    }
                    if let step = model.localStarting[game.id] {
                        HStack(spacing: 10) {
                            UnwineMark(progress: nil, size: 22)
                            PhaseWords(words: step.hasPrefix("Closing") ? [step, "Ending the game's programs…"]
                                                                       : [step, "Windows games start slowly on a Mac", "The game's window opens soon"])
                                .font(.system(size: 12)).foregroundStyle(Palette.glow)
                        }
                    }
                    if !isLocal { BottleWaitRow(game: game) }
                    if isLocal, let exe = game.localExe, !FileManager.default.fileExists(atPath: exe.path) {
                        NoticeRow(color: Palette.warn, icon: "questionmark.folder",
                                  text: "Unwine cannot find \(exe.lastPathComponent) in \(exe.deletingLastPathComponent().path). If the game moved, or its drive is not connected, point Unwine at it again. Its bottle and saves stay.") {
                            Button("Locate…") { locating = true }.buttonStyle(QuietButtonStyle())
                                .help("Pick the game's program where it is now")
                        }
                    }
                    if let found = model.installedPrograms[game.id], !found.isEmpty {
                        NoticeRow(color: Palette.ok, icon: "shippingbox",
                                  text: "The installer put \(found.count == 1 ? "a new program" : "\(found.count) new programs") in this game's Windows bottle. Pick the one that starts the game. This entry then starts it, in the same bottle.") {
                            Button("Pick the installed program") { installedList = found; pickingInstalled = true }.buttonStyle(PrimaryButtonStyle())
                                .help("Shows the new programs, the likeliest first")
                            Button { model.installedPrograms[game.id] = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Keep the installer as this entry")
                        }
                    }
                    if game.bottleIncomplete {
                        NoticeRow(color: Palette.warn, icon: "wrench.and.screwdriver",
                                  text: "This game's Windows bottle is incomplete: its 32-bit part is missing, so the game and its launcher quit at once. A fresh bottle fixes it.\(isLocal ? " Saves the game keeps in its own folder stay." : " Steam Cloud saves stay.")") {
                            Button("Fresh bottle…") { confirmReset = true }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    if case .publisherBlocked = advice.online {
                        NoticeRow(color: Palette.warn, icon: "nosign",
                                  text: "The publisher blocks this game on macOS, so it will not run here. No compatibility layer changes that, CrossOver included.")
                    }
                    if case .blocked(let names) = advice.online {
                        NoticeRow(color: Palette.warn, icon: "shield.lefthalf.filled",
                                  text: "Uses \(names.joined(separator: ", ")). Online play with this anti-cheat does not work on any Mac Wine tool, CrossOver too. Offline modes may work.")
                    }
                    if !isLocal && !usesDecant && (mappedElsewhere || neverRun) {
                        NoticeRow(color: Palette.warn, icon: "hand.point.right.fill",
                                  text: mappedElsewhere
                                    ? "Steam runs this game with another tool (\(model.mappings[game.id] ?? "")), so these settings do nothing. Switch it to Unwine? Steam restarts for a few seconds."
                                    : "Steam is not set to use Unwine for this game yet. Steam restarts for a few seconds.") {
                            Button("Use Unwine") { Task { await model.useDecant(true, for: game) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                .help(model.gameRunning ? "Close your running game first" : "Steam restarts for a few seconds")
                        }
                    }

                    if let followed {
                        NoticeRow(color: Palette.accent, icon: "arrow.triangle.branch",
                                  text: "This \(LocalGames.role(of: game.localExe!)?.lowercased() ?? "program") starts with the settings of \(followed.name), because the game it opens gets everything the \(LocalGames.role(of: game.localExe!)?.lowercased() ?? "program") got. To change graphics, speed or Apple extras, close this page and open \(followed.name).")
                    } else {
                    adviceSection(game, advice)

                    if let ac = needsOnline { onlineSection(game, anticheat: ac) }

                    section("Graphics") {
                        Picker("Graphics layer", selection: binding(game.id, \.renderer)) {
                            ForEach(Renderer.allCases) { r in
                                Text(r == .auto ? "Automatic (\(oldDirectX(analysis) && advice.renderer != .wined3d ? "DXVK for DirectX 9" : advice.renderer.short))" : r.title)
                                    .tag(r)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if let a = analysis, oldDirectX(a), resolved != .wined3d {
                            // Say what really draws: the picker's names are for DirectX 10 to 12.
                            Text("\(a.api.label) game: DXMT and D3DMetal only draw DirectX 10 to 12. On DXMT, DXVK, D3DMetal or Automatic, this game draws with DXVK's DirectX 9 part. Only WineD3D draws it another way.")
                                .font(.system(size: 12)).foregroundStyle(Palette.glow)
                        }
                        Text(s.renderer == .auto ? (analysis == nil ? "Unwine is reading the game's files to pick the best layer." : advice.rendererReason) : s.renderer.blurb)
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        if s.renderer == .d3dmetal && model.d3dmetal == nil {
                            Text("GPTK is not added yet, so this game uses DXMT. Add GPTK 4 in Settings.")
                                .font(.system(size: 12)).foregroundStyle(Palette.warn)
                        } else if s.renderer == .d3dmetal, analysis?.is64Bit == false {
                            Text("D3DMetal runs 64-bit games only, and this game looks 32-bit. It may not start. Your choice stays.")
                                .font(.system(size: 12)).foregroundStyle(Palette.warn)
                        } else if s.renderer != .auto && s.renderer != advice.renderer {
                            Text("Your choice. Unwine would pick \(advice.renderer.title).")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }

                    section("Speed") {
                        Toggle("Fast sync (msync)", isOn: binding(game.id, \.msync))
                        hint("Faster in most games. Turn off if a game freezes or a download stalls.")
                        Toggle("Tell games the CPU has AVX", isOn: binding(game.id, \.advertiseAVX))
                        hint("Some new games refuse to start without it. Rosetta handles it.")
                        FrameCapPicker(cap: binding(game.id, \.fpsCap))
                        if resolved == .wined3d && s.fpsCap != nil {
                            note("Unwine has no frame cap for Wine's own layer (WineD3D), so this cap does nothing for this game. Use the game's own frame limit instead.", warn: true)
                        } else if resolved == .dxvk && analysis?.api == .dx12 && s.fpsCap != nil {
                            note("On the DXVK layer, Wine's own DirectX 12 draws this game, and Unwine cannot cap it. Use the game's own frame limit instead.", warn: true)
                        } else if resolved == .d3dmetal && model.d3dmetal?.isVersion4 != true && s.fpsCap != nil {
                            note("D3DMetal takes a frame cap only from GPTK 4. Yours is \(model.d3dmetal?.label ?? "older"), so this cap does nothing for this game.", warn: true)
                        } else if let cap = s.fpsCap, cap > Profiles.screenHz {
                            hint("Your screen shows at most \(Profiles.screenHz) frames a second, so a \(cap) fps cap saves little. Pick \(evenCaps) to save more.")
                        } else if let cap = s.fpsCap, Profiles.screenHz % max(1, cap) != 0 {
                            hint("\(cap) fps does not divide your screen's \(Profiles.screenHz) Hz, so some frames show longer than others. Pick \(evenCaps) for even motion.")
                        } else {
                            hint("Off lets the game run as fast as it can. A cap saves battery and heat. Each value in the list divides your screen's \(Profiles.screenHz) Hz, so every frame shows for the same time.")
                        }
                        Toggle("Save battery when unplugged", isOn: binding(game.id, \.saveBatteryUnplugged))
                        note(batteryNote(game, s), warn: false)
                        Toggle("120 fps mode (DirectX 10 and 11)", isOn: binding(game.id, \.fps120))
                        note(fps120Note(game, s, analysis, resolved), warn: s.fps120 && !fps120Works(game, s))
                        Toggle("Low latency (DXVK)", isOn: binding(game.id, \.lowLatency))
                        let lowers = model.canLowerLatency(game)
                        note(lowers
                             ? "Like NVIDIA Reflex: DXVK waits a moment before the game reads your mouse and keys, so frames do not pile up and input feels quicker. It keeps no spare frame, so with V-Sync on a 120 Hz screen any frame that misses 8 ms shows twice, and menus can sit near 60 fps. If that happens, turn this off."
                             : "Works only where DXVK draws: DirectX 8 and 9 games, or any game on the DXVK layer. This game uses \(resolved.title)\(analysis.map { " for \($0.api.label)" } ?? ""), so this switch does nothing.",
                             warn: s.lowLatency && !lowers)
                        Toggle("Build shaders in the background (DirectX 8 and 9)", isOn: binding(game.id, \.asyncShaders))
                        let builds = model.canBuildShadersAsync(game)
                        note(builds
                             ? "On: when something new shows up (a gun flash, a new room), DXVK builds its shader in the background and the game keeps running. The first time, that effect can show a moment late. Off: DXVK's own files, and the game stops for a moment for each new effect."
                             : "Works only where DXVK draws DirectX 8 and 9. This game uses \(resolved.title)\(analysis.map { " for \($0.api.label)" } ?? ""), so this switch does nothing.",
                             warn: false)
                    }

                    section("Apple extras") {
                        Toggle("Show the Metal performance overlay", isOn: binding(game.id, \.metalHUD))
                        hint("Shows FPS, GPU time and the GPTK version in a corner of the game.")
                        // Every switch stays yours to flip. When Unwine thinks one does nothing for
                        // this game, the note says why, and turns orange while the switch is on.
                        Toggle("MetalFX sharpening (DirectX 10 and 11)", isOn: binding(game.id, \.metalFXSpatial))
                        note(sharpenNote(canSharpen, analysis, resolved),
                             warn: s.metalFXSpatial && (!canSharpen || Profiles.screenScale < 2))
                        Toggle("MetalFX for DLSS games", isOn: binding(game.id, \.metalFX))
                        // An analysis from an older Unwine did not look for DLSS, so only a current one can say "none".
                        let noDLSS = analysis.map { $0.isCurrent && !$0.hasDLSS } ?? false
                        note(dlssNote(canMetalFX, noDLSS: noDLSS, analysis, resolved),
                             warn: s.metalFX && (!canMetalFX || noDLSS))
                        Picker("Ray tracing (D3DMetal)", selection: binding(game.id, \.rayTracing)) {
                            Text("Apple's default").tag(Bool?.none)
                            Text("Off").tag(Bool?.some(false))
                            Text("On").tag(Bool?.some(true))
                        }
                        note(rayTracingNote(resolved), warn: s.rayTracing != nil && resolved != .d3dmetal)
                        Toggle("Metal 4 mode (GPTK 4)", isOn: binding(game.id, \.metal4))
                        note(metal4Note(resolved), warn: false)
                    }

                    section("Display") { DisplayControls(game: game) }
                    if analysis?.api == .dx12 { section("Experimental") { DXMTD3D12Control(game: game) } }
                    }

                    section("Launch options and mods") {
                        LaunchOptionsEditor(game: game, followed: followed)
                    }

                    section("Fix things") {
                        let busy = isLocal && (model.localStarting[game.id] != nil || model.localRunning.contains(game.id))
                        let logs = [game.runLog, game.wineLog, Paths.logs.appendingPathComponent("tools-\(game.id).log")]
                            .filter { FileManager.default.fileExists(atPath: $0.path) }
                        HStack(spacing: 8) {
                            Button("Reset settings") { model.resetSettings(game.id) }.buttonStyle(QuietButtonStyle())
                                .help("Back to Unwine's defaults for new games")
                            Button("Fresh Windows bottle…") { confirmReset = true }.buttonStyle(QuietButtonStyle())
                                .disabled(busy)
                                .help(busy ? "Quit the game first"
                                      : "Moves this game's Windows bottle to the Trash. \(isLocal ? "Unwine" : "Steam") builds a new one on next Play.")
                            Button("Show logs") { NSWorkspace.shared.activateFileViewerSelecting(logs) }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(logs.isEmpty)
                                .help(logs.isEmpty ? "Logs appear after the first Play" : "Shows the game's logs in Finder")
                        }
                        DetailedLogsControl(game: game)
                        HStack(spacing: 8) {
                            if isLocal {
                                Button("Rename…") { newName = game.name; renaming = true }.buttonStyle(QuietButtonStyle())
                                    .help("Change the name Unwine shows for this game")
                                Button("Change program…") { model.changeLocalProgram(game) }.buttonStyle(QuietButtonStyle())
                                    .disabled(busy)
                                    .help(busy ? "Quit the game first" : "Points this game at another .exe, such as the game after its launcher, or the program that an installer put in the bottle. The bottle and its saves stay.")
                                Button("Remove from Unwine…") { confirmRemove = true }.buttonStyle(QuietButtonStyle())
                                    .disabled(busy)
                                    .help(busy ? "Quit the game first" : "Asks first. The game's own files stay where they are.")
                            } else {
                                Button("Show in Steam") { model.showInSteam(game.id) }.buttonStyle(QuietButtonStyle())
                                    .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens this game's page in Mac Steam")
                                if usesDecant {
                                    Button("Stop using Unwine") { Task { await model.useDecant(false, for: game) } }
                                        .buttonStyle(QuietButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                        .help(model.gameRunning ? "Close your running game first" : "Steam goes back to its default for this game")
                                }
                            }
                        }
                        // The game's Windows bottle: programs for it (installers, patches, mod tools),
                        // Wine's own tools, and its C: drive, where games keep saves and settings.
                        let blocker = model.bottleBlocker(game)
                        HStack(spacing: 8) {
                            Button("Run a program in this bottle…") { model.pickProgramForBottle(game) }.buttonStyle(QuietButtonStyle())
                                .disabled(blocker != nil)
                                .help(blocker ?? "Runs an .exe, .msi, .bat or .cmd file inside this game's bottle, with the game's settings")
                            Menu {
                                ForEach(WineTool.allCases) { tool in
                                    Button(tool.title) { Task { await model.runInBottle(game, .tool(tool)) } }
                                }
                            } label: { Text("Wine tools") }
                                .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize()
                                .disabled(blocker != nil)
                                .help(blocker ?? "Wine settings, the registry editor, the task manager and the uninstaller, for this game's bottle")
                        }
                        HStack(spacing: 8) {
                            Button("Show bottle (C: drive)") { model.showBottleDrive(game) }.buttonStyle(QuietButtonStyle())
                                .disabled(!model.bottleExists(game))
                                .help(model.bottleExists(game) ? "Opens the bottle's C: drive in Finder. Games keep saves and settings in its users folder."
                                      : "Play the game once first. \(isLocal ? "Unwine" : "Steam") makes its Windows bottle then.")
                            Button("Show game files") { model.showGameFiles(game) }.buttonStyle(QuietButtonStyle())
                                .help(isLocal ? "Opens the game's folder in Finder" : "Shows the game's folder in Finder")
                        }
                        if let step = model.bottleToolStarting[game.id] {
                            HStack(spacing: 10) {
                                UnwineMark(progress: nil, size: 20)
                                PhaseWords(words: [step, "Windows programs start slowly on a Mac", "Its window opens soon"])
                                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
                            }
                        }
                        Text("Settings apply the next time the game starts.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                .padding(20)
                .toggleStyle(.switch)
                .tint(Palette.accent)
            }

            HStack {
                if model.busyGame == game.id {
                    UnwineMark(progress: nil, size: 22)
                    PhaseWords(words: ["Closing Steam…", "Saving the choice…", "Opening Steam again…"])
                        .font(.system(size: 12)).foregroundStyle(Palette.glow)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Palette.night)
        }
        .frame(width: 560, height: 680)
        .background(AppBackground())
        .confirmationDialog("Set up Online mode?", isPresented: $confirmOnlineSetup) {
            Button("Set up Online mode") { Task { await model.setUpOnline() } }
        } message: {
            Text("Online mode is experimental. It runs Windows Steam inside Unwine, like CrossOver. Valve does not support Wine, and VAC bans are permanent: they cannot be appealed. No ban caused by Wine is known, but that is not a promise. If you worry, try a spare Steam account first. Unwine never changes game files and never uses insecure mode.")
        }
        .confirmationDialog("Quit the game too?", isPresented: Binding(get: { model.onlineForceQuit != nil }, set: { if !$0 { model.onlineForceQuit = nil } })) {
            Button("Quit game and Windows Steam", role: .destructive) { Task { await model.stopOnline(force: true) } }
        } message: {
            Text("\((model.onlineForceQuit ?? []).joined(separator: ", ")) is still running in Windows Steam. Unwine asks it to close first. Progress you have not saved can be lost.")
        }
        .confirmationDialog("Restart Windows Steam?", isPresented: Binding(get: { model.onlineRestartAsk != nil }, set: { if !$0 { model.onlineRestartAsk = nil } }),
                            presenting: model.onlineRestartAsk) { ask in
            Button("Restart and play") { Task { await model.openOnline(ask.game, restart: true) } }
            Button("Play without restarting") { Task { await model.openOnline(ask.game, restart: false) } }
        } message: { ask in
            Text(restartMessage(ask))
        }
        .confirmationDialog("Start this game with a fresh Windows bottle?", isPresented: $confirmReset) {
            Button("Move bottle to Trash", role: .destructive) { model.resetBottle(game) }
        } message: {
            Text(game.localExe == nil
                 ? "Your game files and Steam Cloud saves stay. Saves kept only inside the bottle go to the Trash with it."
                 : "Your game files stay. Settings and saves the game kept inside its bottle go to the Trash with it. Unwine makes a new bottle on the next Play.")
        }
        .confirmationDialog("Remove \(game.name) from Unwine?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeLocalGame(game); dismiss() }
        } message: {
            Text(model.removeNote(for: game))
        }
        .fileImporter(isPresented: $locating, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            if case .success(let url) = result { model.relocateLocalGame(game.id, exe: url) }
        }
        .alert("Rename \(game.name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renameLocalGame(game.id, to: newName) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $pickingInstalled) {
            ProgramChooser(folder: game.compatData.appendingPathComponent("pfx/drive_c", isDirectory: true),
                           programs: installedList,
                           title: "Which program did the installer put in the bottle?",
                           intro: "The likeliest is first. Press Return to use it. This entry keeps its bottle and takes the program's name.",
                           pickSingle: false) { exe in
                pickingInstalled = false
                if let exe { model.useInstalledProgram(game.id, exe: exe) }
            }
        }
    }

    /// DirectX 8 and 9 games draw with DXVK's DirectX 9 part under every layer but WineD3D.
    private func oldDirectX(_ a: GameAnalysis?) -> Bool { a?.api == .dx9 || a?.api == .dx8 }

    private func restartMessage(_ ask: OnlineRestartAsk) -> String {
        let what = ask.changes.isEmpty ? "settings Windows Steam did not start with"
                                       : "settings Windows Steam did not start with: " + ask.changes.joined(separator: ", ")
        return "\(ask.game.name) uses \(what). Games take Windows Steam's settings, so it restarts to use them (Steam Cloud saves sync first). Without a restart the game plays with the settings Steam has now. Low latency and frame caps apply either way."
    }

    private func facts(_ game: SteamGame, _ a: GameAnalysis?) -> String {
        var parts: [String] = []
        if let a { parts.append(a.api.label); parts.append(a.is64Bit ? "64-bit" : "32-bit"); if let e = a.engine { parts.append(e) } }
        if game.sizeOnDisk > 0 { parts.append(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Advice

    private func adviceSection(_ game: SteamGame, _ advice: Advice) -> some View {
        let active = model.activePreset(for: game)
        let custom = model.settings(for: game.id).renderer != .auto
        return section("Unwine's advice") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(Palette.glow)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Best layer: \(oldDirectX(model.analysis(for: game)) && advice.renderer != .wined3d ? "DXVK (DirectX 9 part)" : advice.renderer.title)").font(.system(size: 13, weight: .semibold))
                    Text(advice.rendererReason).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            // The next step when only Apple's file stands between this game and D3DMetal.
            if advice.needsGPTK { GPTKOffer() }
            HStack(spacing: 8) {
                ForEach(Preset.allCases) { p in
                    PresetCard(preset: p, detail: summary(model.settings(p, for: game, advice: advice), renderer: advice.renderer),
                               active: active == p, resetsLayer: custom) { model.apply(p, to: game) }
                }
            }
            if active == nil {
                hint("Your own settings are in use. Unwine keeps them.")
            }
            ForEach(Array(advice.tips.enumerated()), id: \.offset) { _, tip in
                TipRow(icon: tipIcon(tip.kind), color: tipColor(tip.kind), text: tip.text, link: tip.link)
            }
            Text("Advice from \(advice.source).").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }

    /// Half the main screen's real pixels each way. On a Retina screen that is also the size a
    /// game draws at, because game bottles run without Retina mode.
    private var halfScreen: String {
        guard let screen = NSScreen.main else { return "half your screen size" }
        let scale = screen.backingScaleFactor
        return "\(Int(screen.frame.width * scale / 2))×\(Int(screen.frame.height * scale / 2))"
    }

    private func metal4Note(_ resolved: Renderer) -> String {
        // Metal 4 came with macOS 26; Unwine sets nothing for it on an older macOS.
        guard Profiles.hasMetal4 else {
            return "Needs macOS 26 or newer. This Mac has macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), so this switch does nothing."
        }
        guard let d = model.d3dmetal, d.isVersion4 else {
            return "Needs GPTK 4. \(model.d3dmetal.map { "You have \($0.label)." } ?? "GPTK is not added yet.") Until then this switch does nothing."
        }
        guard resolved == .d3dmetal else {
            return "Works only with the D3DMetal layer. This game uses \(resolved.title) now, so this switch does nothing."
        }
        return "GPTK 4's newest path. Usually faster; turn off if this game crashes."
    }

    /// 120 fps mode sets DXMT's DirectX 10/11 pacing, so it reaches the games MetalFX sharpening
    /// reaches. The user's own frame cap wins, and a 60 Hz screen has nothing more to show.
    private func fps120Works(_ game: SteamGame, _ s: GameSettings) -> Bool {
        model.canSharpen(game) && s.fpsCap == nil && Profiles.screenHz > 60
    }

    private func fps120Note(_ game: SteamGame, _ s: GameSettings, _ a: GameAnalysis?, _ resolved: Renderer) -> String {
        let hz = Profiles.screenHz
        if !model.canSharpen(game) {
            return "Works only where DXMT draws DirectX 10 and 11. This game uses \(resolved.title)\(a.map { " for \($0.api.label)" } ?? ""), so this switch does nothing."
        }
        if hz <= 60 { return "Your screen shows at most \(hz) frames a second, so this switch does nothing here." }
        if let cap = s.fpsCap { return "Your frame rate cap (\(cap) fps) wins, so this switch does nothing. Set the cap to Off to use it." }
        if s.fps120, s.saveBatteryUnplugged, let battery = model.batteryOverlayNow {
            return "Your Mac saves battery now, so this game starts without 120 fps mode, capped at \(battery.cap) fps. When you plug in, 120 fps mode comes back."
        }
        return "Some full-screen games ask for 60 Hz, or for a rate your screen does not have, like 75 Hz. Your screen stays at \(hz) Hz, but DXMT then holds the game at 60 fps. On: DXMT paces to \(hz) Hz instead. It only helps when your Mac draws each frame well under \(String(format: "%.1f", 1000.0 / Double(hz))) ms (GPU time in the Metal overlay). A slower frame waits for the next refresh, so you still see 60, and motion can look uneven: then turn this off, or lower the game's graphics settings. It costs battery and heat. A game in a window, or set to \(hz) Hz in its own menu, gets \(hz) already. It also holds games with V-Sync off at \(hz). If the game runs too fast, turn this off."
    }

    /// The caps that divide the screen's rate, in words: "30, 40, 60 or 120 fps".
    private var evenCaps: String {
        let caps = Profiles.capChoices().map(String.init)
        guard let last = caps.last else { return "a lower cap" }
        return (caps.count > 1 ? caps.dropLast().joined(separator: ", ") + " or " + last : last) + " fps"
    }

    /// What "Save battery when unplugged" does for this game, for the Mac's power right now.
    /// PowerState is observed, so the line changes the moment the Mac is plugged in or unplugged.
    private func batteryNote(_ game: SteamGame, _ s: GameSettings) -> String {
        guard s.saveBatteryUnplugged else { return "Off: this game starts with the same settings on battery and on power." }
        guard model.takesFrameCap(game) else {
            return "Unwine has no frame cap for this game's layer, so this switch changes nothing for it. Use the game's own frame limit to save battery."
        }
        let power = PowerState.shared
        let hz = Profiles.screenHz
        // Where DXVK draws (the same games Low latency reaches), it also builds fewer shaders at once.
        let shaders = model.canLowerLatency(game) ? " DXVK builds fewer shaders at the same time, for less heat." : " Nothing else changes for this game."
        if let battery = model.batteryOverlayNow {
            let now = power.lowPowerMode ? "Low Power Mode is on" : battery.strict ? "Your Mac is hot" : "On battery now"
            if let own = s.fpsCap { return "\(now): your own cap of \(own) fps stays.\(shaders)" }
            return "\(now): this game starts capped at \(battery.cap) fps. Plugged in, it starts as usual. A running game keeps its settings until it closes."
        }
        if let own = s.fpsCap { return "Plugged in now. On battery, your own cap of \(own) fps stays.\(shaders)" }
        let normal = BatteryOverlay(strict: false, screenHz: hz).cap, strict = BatteryOverlay(strict: true, screenHz: hz).cap
        return "Plugged in now. On battery, this game starts capped at \(normal) fps, and at \(strict) fps in Low Power Mode or when your Mac is hot."
    }

    /// DXMT enlarges by the screen's own scale (see Profiles.configs), so a 1x screen gets nothing.
    private func sharpenNote(_ can: Bool, _ a: GameAnalysis?, _ r: Renderer) -> String {
        guard can else { return noMetalFXReason(a, r, dlss: false) }
        guard Profiles.screenScale >= 2 else {
            return "Your screen has no Retina pixels (1x), so MetalFX has nothing to add, and this switch does nothing here. On a Retina screen, DXMT draws the picture 2x larger."
        }
        return "DXMT draws the picture 2x larger with MetalFX, to your screen's real pixels. Set the game to \(halfScreen) and it fills your screen sharply. If you set the game to your screen's full size, turn this off: a second enlargement only costs battery. On a screen without Retina (1x), this switch does nothing."
    }

    private func dlssNote(_ can: Bool, noDLSS: Bool, _ a: GameAnalysis?, _ r: Renderer) -> String {
        guard can else { return noMetalFXReason(a, r, dlss: true) }
        if noDLSS {
            return "Unwine found no DLSS files in this game, so MetalFX has nothing to replace."
                + (r == .dxmt ? " On DXMT this switch still makes the game see an NVIDIA graphics card, and some games then take slower paths. Leave it off."
                              : " This switch does nothing for it.")
        }
        return "\(a?.hasDLSS == true ? "This game has DLSS. " : "")Turns the game's DLSS option into Apple's MetalFX. Set the game to DLSS to get the gain."
    }

    private func rayTracingNote(_ resolved: Renderer) -> String {
        guard resolved == .d3dmetal else {
            return "Works only with the D3DMetal layer (DirectX 12 with GPTK). This game uses \(resolved.title) now, so this choice does nothing."
        }
        let here = MacChip.name.flatMap { name in MacChip.raysByDefault.map { " This Mac has an \(name), so the default here is \($0 ? "on" : "off")." } } ?? ""
        return "Apple's default is on for M3 and newer chips, and off for M1 and M2.\(here) Off saves battery and heat in games with ray-traced light and shadows. If a game shows broken shadows or crashes, try Off."
    }

    /// Why Play online cannot start now, or nil when it can.
    private func playOnlineBlocker(_ game: SteamGame) -> String? {
        if game.state != .installed { return "Finish the download in Steam first" }
        if model.gameRunning { return "A game is running in Mac Steam. Close it first." }
        if model.onlineStep.isRunning { return "Online mode is still setting up" }
        if model.onlineBusy { return "Unwine is switching Steam. Wait a moment." }
        return nil
    }

    private func noMetalFXReason(_ a: GameAnalysis?, _ r: Renderer, dlss: Bool) -> String {
        guard let a else { return "Unwine is still reading the game's files." }
        switch a.api {
        case .dx9, .dx8:
            return "\(a.api.label) games run on DXVK, which has no MetalFX. Most \(a.api.label) games are light, so the GPU is not what limits them."
        case .opengl, .vulkan, .unknown:
            return "MetalFX works only with the DirectX 10, 11 and 12 layers. This game is \(a.api.label)."
        case .dx12 where !dlss:
            return "Sharpening is a DXMT feature, for DirectX 10 and 11. For DirectX 12, use MetalFX for DLSS games."
        case .dx10 where dlss:
            return "DirectX 10 games have no DLSS. Use MetalFX sharpening instead."
        default:
            return "Needs the \(dlss ? "D3DMetal or DXMT" : "DXMT") layer. This game uses \(r.title) now."
        }
    }

    private func summary(_ s: GameSettings, renderer: Renderer) -> String {
        var parts = [s.fpsCap.map { "\($0) fps cap" } ?? "No frame cap"]
        if renderer == .d3dmetal && s.metal4 && model.d3dmetal?.isVersion4 == true { parts.append("Metal 4") }
        if renderer == .d3dmetal && s.rayTracing == false { parts.append("Ray tracing off") }
        if renderer == .dxmt, let tess = s.maxTessFactor { parts.append("Tessellation up to \(tess)x") }
        if s.metalFX { parts.append("MetalFX for DLSS") }
        if s.msync { parts.append("msync") }
        return parts.joined(separator: " · ")
    }

    private func steamComesBack(_ prefix: String) -> String {
        model.willReopenMacSteam ? prefix + " Mac Steam comes back when you quit Windows Steam." : prefix
    }

    private func tipIcon(_ kind: Advice.Tip.Kind) -> String {
        switch kind {
        case .info: return "lightbulb"
        case .warning: return "exclamationmark.triangle"
        case .fix: return "wrench.and.screwdriver"
        }
    }

    private func tipColor(_ kind: Advice.Tip.Kind) -> Color {
        switch kind {
        case .info: return Palette.glow
        case .warning: return Palette.warn
        case .fix: return Palette.ok
        }
    }

    // MARK: Online mode

    private func onlineSection(_ game: SteamGame, anticheat: String) -> some View {
        let online = model.online
        return section("Online play") {
            Text("\(game.name) uses \(anticheat). Mac Steam's Steam Play cannot load \(anticheat), so online servers block you. Online mode runs Windows Steam inside Unwine, like CrossOver does. It is experimental.")
                .font(.system(size: 12))
            // Setup, and the re-setup after an engine update, show here whether installed or not.
            switch model.onlineStep {
            case .running(let progress, let words):
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 22)
                    PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                }
                ProgressTrack(progress: progress)
                hint("You can close this window. Setup keeps going.")
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(Palette.warn).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Try again") { Task { await model.setUpOnline() } }.buttonStyle(PrimaryButtonStyle())
                        .disabled(model.onlineBusy).help(model.onlineBusy ? "Unwine is switching Steam. Wait a moment." : "Runs setup again. Finished steps are skipped.")
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs]) }.buttonStyle(QuietButtonStyle())
                }
            default:
                onlineControls(game, online: online)
            }
            if online.installed, model.analysis(for: game)?.api == .dx12 {
                note("DirectX 12 games cannot run in Online mode yet: Windows Steam's own window needs DXMT, and DXMT has no DirectX 12.", warn: true)
            }
            if online.installed, let engine = model.engine {
                ForEach(Array(OnlineSteam.notes(engine: engine, profile: Profiles.file(for: game.id)).enumerated()), id: \.offset) { _, text in
                    note(text, warn: false)
                }
            }
            if online.installed {
                note("Windows Steam uses the same game files as Mac Steam. Uninstalling the game in Windows Steam deletes it for Mac Steam too.", warn: false)
            }
            if let words = model.onlineWords {
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 20)
                    PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                    if model.onlineClosing {
                        Spacer()
                        Button("Close now") { model.hurryOnlineQuit() }.buttonStyle(QuietButtonStyle())
                            .help("Ends Windows Steam without waiting. Steam Cloud may not finish saving this session.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func onlineControls(_ game: SteamGame, online: OnlineStatus) -> some View {
        if !online.installed {
            Button("Set up Online mode…") { confirmOnlineSetup = true }.buttonStyle(PrimaryButtonStyle())
                .disabled(model.engine == nil || model.onlineBusy)
                .help(model.engine == nil ? "Finish Unwine's setup first" : "Shows what Online mode does before anything downloads")
            hint("Downloads Windows Steam once: about \(OnlineSteam.approximateDownloadMB) MB from Valve. Your games are not downloaded again: Windows Steam uses the same game files.")
        } else if !online.signedIn {
            HStack(spacing: 8) {
                Button(online.running ? "Windows Steam is open" : "Sign in to Windows Steam") { Task { await model.openOnline(nil) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(online.running || model.onlineBusy || model.gameRunning)
                    .help(online.running ? "Sign in in the Windows Steam window"
                          : model.gameRunning ? "A game is running in Mac Steam. Close it first."
                          : model.onlineBusy ? "Unwine is switching Steam. Wait a moment." : "Opens Windows Steam's sign-in window")
                quitControl(online)
            }
            hint(online.running
                 ? "Sign in, and tick \u{201C}Remember me\u{201D}. Then press Play online at the top."
                 : "Do this once. Mac Steam closes while Windows Steam is open.")
        } else {
            HStack(spacing: 8) {
                Button { Task { await model.openOnline(game) } } label: { Label("Play online", systemImage: "globe") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(playOnlineBlocker(game) != nil)
                    .help(playOnlineBlocker(game) ?? "Starts the game in Windows Steam, so online servers accept it")
                quitControl(online)
            }
            hint(steamComesBack("Mac Steam closes while you play online. Single player can keep using Play."))
        }
    }

    /// Quit when Windows Steam runs; a way out when only leftover Windows programs run.
    @ViewBuilder
    private func quitControl(_ online: OnlineStatus) -> some View {
        if online.running {
            Button("Quit Windows Steam") { Task { await model.stopOnline() } }.buttonStyle(QuietButtonStyle())
                .disabled(model.onlineBusy).help(model.onlineBusy ? "Unwine is switching Steam. Wait a moment." : "Steam Cloud saves sync first")
        } else if online.inUse {
            Button("Stop Windows programs") { Task { await model.stopOnline() } }.buttonStyle(QuietButtonStyle())
                .disabled(model.onlineBusy).help("Something is still running inside Windows Steam's bottle. This closes it.")
        }
    }

    private func binding<T>(_ id: Int, _ key: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(get: { model.settings(for: id)[keyPath: key] },
                set: { v in model.update(id) { $0[keyPath: key] = v } })
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.glow.opacity(0.8))
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.stroke))
        }
        .foregroundStyle(Palette.text)
    }

    private func note(_ text: String, warn: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warn ? Palette.warn : Palette.muted).padding(.bottom, 4)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.bottom, 4)
    }
}

/// One of the advisor's two setting sets. A click applies it; the next game start uses it.
private struct PresetCard: View {
    let preset: Preset
    let detail: String
    let active: Bool
    let resetsLayer: Bool
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: preset.icon)
                    Text(preset.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok) }
                }
                Text(active ? "In use · \(detail)" : detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Palette.accent.opacity(0.22) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(active ? Palette.accent.opacity(0.7) : Palette.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text)
        .help(active ? "Already in use"
              : "Sets: \(detail)\(resetsLayer ? ", and the graphics layer back to Automatic" : ""). Your Metal overlay, MetalFX sharpening, Low latency, 120 fps mode and Save battery when unplugged choices stay. Applies the next time the game starts.")
    }
}

private struct TipRow: View {
    let icon: String
    let color: Color
    let text: String
    let link: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12)).foregroundStyle(Palette.text.opacity(0.9))
                if let link {
                    Button("Read more") { NSWorkspace.shared.open(link) }
                        .buttonStyle(.link).font(.system(size: 11)).help(link.absoluteString)
                }
            }
        }
    }
}

struct NoticeRow<Actions: View>: View {
    let color: Color
    let icon: String
    let text: String
    @ViewBuilder var actions: Actions

    init(color: Color, icon: String, text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.color = color; self.icon = icon; self.text = text; self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.text)
            Spacer(minLength: 0)
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
    }
}
