import SwiftUI

struct GameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: Int
    @State private var confirmReset = false
    @State private var confirmOnlineSetup = false

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
        let needsOnline: String? = { if case .needsOnlineMode(let ac) = advice.online { return ac }; return nil }()
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
                    Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(game.state != .installed || model.macSteamBlocked)
                        .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason
                              : game.state == .installed ? (needsOnline != nil ? "Single player and offline, through Mac Steam" : "Starts in Steam with these settings")
                              : "Finish the download in Steam first")
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
                    if case .publisherBlocked = advice.online {
                        NoticeRow(color: Palette.warn, icon: "nosign",
                                  text: "The publisher blocks this game on macOS, so it will not run here. No compatibility layer changes that, CrossOver included.")
                    }
                    if case .blocked(let names) = advice.online {
                        NoticeRow(color: Palette.warn, icon: "shield.lefthalf.filled",
                                  text: "Uses \(names.joined(separator: ", ")). Online play with this anti-cheat does not work on any Mac Wine tool, CrossOver too. Offline modes may work.")
                    }
                    if !usesDecant && (mappedElsewhere || neverRun) {
                        NoticeRow(color: Palette.warn, icon: "hand.point.right.fill",
                                  text: mappedElsewhere
                                    ? "Steam runs this game with another tool (\(model.mappings[game.id] ?? "")), so these settings do nothing. Switch it to Unwine? Steam restarts for a few seconds."
                                    : "Steam is not set to use Unwine for this game yet. Steam restarts for a few seconds.") {
                            Button("Use Unwine") { Task { await model.useDecant(true, for: game) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                .help(model.gameRunning ? "Close your running game first" : "Steam restarts for a few seconds")
                        }
                    }

                    adviceSection(game, advice)

                    if let ac = needsOnline { onlineSection(game, anticheat: ac) }

                    section("Graphics") {
                        Picker("Graphics layer", selection: binding(game.id, \.renderer)) {
                            ForEach(Renderer.allCases) { r in
                                Text(r == .auto ? "Automatic (\(advice.renderer.short))" : r.title)
                                    .tag(r)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
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
                        Picker("Frame rate cap", selection: binding(game.id, \.fpsCap)) {
                            Text("Off").tag(Int?.none)
                            ForEach([30, 40, 60, 120], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                        }
                        if resolved == .wined3d && s.fpsCap != nil {
                            note("Unwine has no frame cap for Wine's own layer (WineD3D), so this cap does nothing for this game. Use the game's own frame limit instead.", warn: true)
                        } else if resolved == .dxvk && analysis?.api == .dx12 && s.fpsCap != nil {
                            note("On the DXVK layer, Wine's own DirectX 12 draws this game, and Unwine cannot cap it. Use the game's own frame limit instead.", warn: true)
                        } else if resolved == .d3dmetal && model.d3dmetal?.isVersion4 != true && s.fpsCap != nil {
                            note("D3DMetal takes a frame cap only from GPTK 4. Yours is \(model.d3dmetal?.label ?? "older"), so this cap does nothing for this game.", warn: true)
                        } else {
                            hint("Off lets the game run as fast as it can. A cap saves battery and heat; pick a value that divides your screen's refresh rate.")
                        }
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
                        note(canSharpen
                             ? "DXMT doubles the size the game draws, with MetalFX. Set the game to \(halfScreen) and it fills your screen sharply. If you set the game to your screen's full size, turn this off: doubling it again only costs battery."
                             : noMetalFXReason(analysis, resolved, dlss: false),
                             warn: s.metalFXSpatial && !canSharpen)
                        Toggle("MetalFX for DLSS games", isOn: binding(game.id, \.metalFX))
                        note(canMetalFX
                             ? "Turns the game's DLSS option into Apple's MetalFX. Set the game to DLSS to get the gain."
                             : noMetalFXReason(analysis, resolved, dlss: true),
                             warn: s.metalFX && !canMetalFX)
                        Toggle("Metal 4 mode (GPTK 4)", isOn: binding(game.id, \.metal4))
                        note(metal4Note(resolved), warn: false)
                    }

                    section("Fix things") {
                        HStack(spacing: 8) {
                            Button("Reset settings") { model.resetSettings(game.id) }.buttonStyle(QuietButtonStyle())
                                .help("Back to Unwine's defaults for new games")
                            Button("Fresh Windows bottle…") { confirmReset = true }.buttonStyle(QuietButtonStyle())
                                .help("Moves this game's Windows bottle to the Trash. Steam builds a new one on next Play.")
                            Button("Show logs") {
                                NSWorkspace.shared.activateFileViewerSelecting([game.runLog, game.wineLog].filter { FileManager.default.fileExists(atPath: $0.path) })
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(!FileManager.default.fileExists(atPath: game.runLog.path))
                            .help("Logs appear after the first Play")
                        }
                        HStack(spacing: 8) {
                            Button("Show in Steam") { model.showInSteam(game.id) }.buttonStyle(QuietButtonStyle())
                                .disabled(model.macSteamBlocked).help(model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Opens this game's page in Mac Steam")
                            Button("Show game files") { NSWorkspace.shared.activateFileViewerSelecting([game.installDir]) }.buttonStyle(QuietButtonStyle())
                            if usesDecant {
                                Button("Stop using Unwine") { Task { await model.useDecant(false, for: game) } }
                                    .buttonStyle(QuietButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                    .help("Steam goes back to its default for this game")
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
            Text("Your game files and Steam Cloud saves stay. Saves kept only inside the bottle go to the Trash with it.")
        }
    }

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
                    Text("Best layer: \(advice.renderer.title)").font(.system(size: 13, weight: .semibold))
                    Text(advice.rendererReason).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
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
        guard let d = model.d3dmetal, d.isVersion4 else {
            return "Needs GPTK 4. \(model.d3dmetal.map { "You have \($0.label)." } ?? "GPTK is not added yet.") Until then this switch does nothing."
        }
        guard resolved == .d3dmetal else {
            return "Works only with the D3DMetal layer. This game uses \(resolved.title) now, so this switch does nothing."
        }
        return "GPTK 4's newest path. Usually faster; turn off if this game crashes."
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
        if s.metalFXSpatial { parts.append("MetalFX sharpening") }
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
              : "Sets: \(detail)\(resetsLayer ? ", and the graphics layer back to Automatic" : ""). Your Metal overlay and Low latency choices stay. Applies the next time the game starts.")
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
