import SwiftUI

// The game page's parts for logs, the Mac display and renderer extras (group f). GameSheet places
// them; the settings behind them are in GameSettings, and AppModel+Bottles writes the display values
// into the game's closed bottle.

/// The Display section: how Wine shows the game on the Mac (Retina, the whole screen, the Command
/// keys), HDR, and the picture of a DirectDraw game. Wine reads the Mac values from the game's bottle.
struct DisplayControls: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    @State private var copied = false

    var body: some View {
        let s = model.settings(for: game.id)
        Group {
            if game.localExe != nil { retinaToggle(s) } else { retinaFromSteam() }
            Toggle("Game takes the whole screen", isOn: binding(\.fillScreen))
            settingNote("On: a full-screen game takes over the display, so the Dock and menu bar cannot cover it, and macOS can more often turn on Game Mode. While the game is in front, other windows, notifications and any other displays go dark. Cmd-Tab leaves it.")
            Toggle("Command key acts as Ctrl", isOn: binding(\.commandIsCtrl))
            settingNote("On: both Command keys reach the game as Ctrl, and both Option keys as Alt. Off: Wine's own keys. Command acts as Alt, and Option types special characters.")
            bottleState()
            Picker("HDR", selection: binding(\.hdr)) {
                ForEach(HDRChoice.allCases) { Text($0.title).tag($0) }
            }
            let hdr = hdrNote(s)
            settingNote(hdr.text, warn: hdr.warn)
            if model.usesDirectDraw(game) { directDraw(s) }
            if game.localExe == nil && model.online.installed {
                settingNote("Online mode uses its own display settings, in Settings.")
            }
        }
    }

    // MARK: Retina

    /// An added game: Unwine writes Retina mode and the 192 DPI into its bottle.
    @ViewBuilder
    private func retinaToggle(_ s: GameSettings) -> some View {
        Toggle("Sharp picture (Retina)", isOn: binding(\.retina))
        settingNote(s.retina
            ? "On: the game draws at all of your screen's pixels (Retina mode), with Windows text at 192 DPI. The GPU draws 4x the pixels, so it works harder and the battery drains faster. Set the game to your screen's full size (\(fullScreen))."
            : "Off: the game draws at half your screen's pixels, and macOS scales it up. On: the game draws at all of them (Retina mode), with Windows text at 192 DPI, like Online mode's High Resolution Mode. The picture is sharper, but the GPU draws 4x the pixels, so the battery drains faster.")
        if s.retina && s.metalFXSpatial {
            settingNote("MetalFX sharpening is on too. Turn it off: the game draws at full size already, so sharpening only costs battery.", warn: true)
        }
    }

    /// A Steam game: NotProton turns Retina mode on only from Steam's launch options, so Unwine shows
    /// the line to put there. Unwine adds the 192 DPI that goes with it.
    @ViewBuilder
    private func retinaFromSteam() -> some View {
        let on = SteamLaunchOptions.hasRetina(game.id)
        HStack {
            Text("Sharp picture (Retina)")
            Spacer()
            StatusPill(text: on ? "On in Steam" : "Off", color: on ? Palette.ok : Palette.muted)
        }
        if on {
            settingNote("On: this game's launch options in Steam have \(SteamLaunchOptions.retinaWord). The game draws at all of your screen's pixels, and Unwine sets Windows text to 192 DPI in its bottle. The GPU draws 4x the pixels, so the battery drains faster. To turn it off, remove \(SteamLaunchOptions.retinaWord) from the launch options in Steam.")
        } else {
            settingNote("Steam Play turns Retina mode off at every start. To turn it on, put this line in the game's launch options in Steam (the game's Properties, General). The line keeps the options that the game has now:")
            Text(SteamLaunchOptions.retinaLine(for: game.id))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.glow).textSelection(.enabled)
            settingNote("Retina mode draws 4x the pixels, so the GPU works harder and the battery drains faster. Then set the game to your screen's full size (\(fullScreen)). Unwine sees the line after Steam saves it.")
        }
        HStack(spacing: 8) {
            if !on {
                Button(copied ? "Copied" : "Copy line") {
                    SteamLaunchOptions.copyRetinaLine(for: game.id)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                }
                .buttonStyle(QuietButtonStyle())
                .help("Copies the whole line. Paste it over the game's launch options in Steam.")
            }
            Button("Show in Steam") { model.showInSteam(game.id) }.buttonStyle(QuietButtonStyle())
                .disabled(model.macSteamBlocked)
                .help(model.macSteamBlocked ? AppModel.macSteamBlockedReason
                      : "Opens this game's page in Mac Steam. Its gear button opens Properties, with the launch options.")
        }
    }

    /// The real pixels of the main screen, the size a game draws at in Retina mode.
    private var fullScreen: String {
        guard let screen = NSScreen.main else { return "your screen's full size" }
        return "\(Int(screen.frame.width * screen.backingScaleFactor))×\(Int(screen.frame.height * screen.backingScaleFactor))"
    }

    // MARK: The bottle

    /// Where the values stand against the game's bottle. Writing them starts Wine for a few seconds.
    @ViewBuilder
    private func bottleState() -> some View {
        switch model.displayState(for: game) {
        case .current:
            EmptyView()
        case .writing:
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: ["Writing these settings into the game's bottle…", "Wine runs for a few seconds to do this",
                                   "Play waits until this is done"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
        case .waitingOpen:
            pending("The game's Windows bottle is open now. These settings go into it when the game closes.")
        case .waitingNew:
            pending("Steam makes this game's Windows bottle at its first start. These settings go into it after that start.")
        case .nextStart:
            pending(game.localExe != nil ? "These settings go into the game's Windows bottle when you press Play."
                                         : "Unwine writes these settings into the game's Windows bottle in a moment.")
        case .failed:
            HStack(spacing: 8) {
                settingNote("Unwine could not write these settings into the game's Windows bottle. Press Play in Unwine to try again.", warn: true)
                Spacer(minLength: 0)
                // The bottle writes go to Unwine's own log.
                ShowLogsButton(game: game, log: "unwine", title: "Show log", help: "Shows Unwine's log. Its last lines say what went wrong.")
            }
        }
    }

    /// A status line, set apart from the notes: the settings wait for the bottle.
    private func pending(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(Palette.glow.opacity(0.9))
        .padding(.bottom, 4)
    }

    // MARK: HDR

    /// DXMT gives a game HDR by itself and reads dxgi.forceSDR. DXVK reads dxgi.enableHDR, which stays off
    /// unless On asks for it. D3DMetal and WineD3D have no switch. Each note says what this game gets.
    private func hdrNote(_ s: GameSettings) -> (text: String, warn: Bool) {
        let r = model.resolvedRenderer(for: game)
        let api = model.analysis(for: game)?.api
        let picked = s.hdr != .auto     // a choice that does nothing for this game turns its note orange
        if let api, api == .vulkan || api == .opengl {
            return ("\(api.label) games draw without DXMT or DXVK, so this choice does nothing for them.", picked)
        }
        if model.usesDirectDraw(game) && api != .dx9 && api != .dx8 {
            return ("DirectDraw games have no HDR, so this choice does nothing for this game.", picked)
        }
        if r == .wined3d { return ("WineD3D has no HDR, so this choice does nothing for this game.", picked) }
        if r == .d3dmetal { return ("D3DMetal has no switch for HDR, so this choice does nothing for this game.", picked) }
        if let api, api == .dx9 || api == .dx8 {
            return ("\(api.label) games have no HDR picture, so this choice does nothing for them.", picked)
        }
        let power = "HDR makes the screen brighter, and on an XDR Mac screen it uses more power."
        let sdr = "so the game draws a normal (SDR) picture."
        if r == .dxvk {
            // Online mode runs a DXVK game on DXMT, which gives HDR by itself (only Off stops it there).
            let online = game.localExe == nil && model.online.installed
                ? " In Online mode, the game runs on DXMT, so Automatic and On both let it use HDR there." : ""
            switch s.hdr {
            case .auto: return ("Automatic: DXVK tells the game that the screen has no HDR, \(sdr) To try HDR, pick On.\(online)", false)
            case .on: return ("On (test): DXVK tells the game that the screen has HDR, so a game with HDR can use it on a screen that shows HDR. DXVK's HDR on a Mac has no public test yet. If the picture looks wrong, pick Automatic. \(power)\(online)", false)
            case .off: return ("Off: DXMT and DXVK tell the game that the screen has no HDR, \(sdr)", false)
            }
        }
        switch s.hdr {
        case .auto: return ("Automatic: a game with HDR can use it on a screen that shows HDR. \(power) To save battery, pick Off.", false)
        case .on: return ("On: DXMT gives HDR to a game by itself, so On is the same as Automatic for this game. A game with HDR can use it on a screen that shows HDR. \(power) To save battery, pick Off.", false)
        case .off: return ("Off: DXMT tells the game that the screen has no HDR, \(sdr)", false)
        }
    }

    // MARK: DirectDraw

    @ViewBuilder
    private func directDraw(_ s: GameSettings) -> some View {
        Picker("DirectDraw picture", selection: binding(\.ddrawMode)) {
            ForEach(DirectDrawMode.allCases) { Text($0.title).tag($0) }
        }
        if model.resolvedRenderer(for: game) == .wined3d {
            settingNote("WineD3D draws this DirectDraw game itself, so this choice does nothing. Another graphics layer uses cnc-ddraw, which reads it.", warn: s.ddrawMode != .auto)
        } else {
            let how: String = {
                switch s.ddrawMode {
                case .auto: return "The game decides between a window and full screen."
                case .window: return "The game opens in a window that you can move and make bigger."
                case .fullScreen: return "The game fills the screen and keeps its shape, with no switch of the display mode."
                }
            }()
            settingNote("cnc-ddraw draws this DirectDraw game. \(how) The frame rate cap under Speed holds it too. Unwine keeps these settings in its own file, never in the game's folder.")
        }
    }

    private func binding<T>(_ key: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(get: { model.settings(for: game.id)[keyPath: key] },
                set: { v in model.update(game.id) { $0[keyPath: key] = v } })
    }
}

/// The Experimental section, for DirectX 12 games: DXMT's own DirectX 12 part.
struct DXMTD3D12Control: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let on = model.settings(for: game.id).dxmtD3D12
        let resolved = model.resolvedRenderer(for: game)
        Group {
            Toggle("DirectX 12 through DXMT", isOn: Binding(get: { model.settings(for: game.id).dxmtD3D12 },
                                                            set: { model.setDXMTD3D12($0, for: game.id) }))
                .disabled(!model.hasDXMTD3D12)
                .help(model.hasDXMTD3D12 ? "Experimental: the game may not start" : "Unwine's engine has no DXMT DirectX 12 part")
            if !model.hasDXMTD3D12 {
                settingNote("Unwine's engine has no DXMT DirectX 12 part, so this switch cannot work. A newer engine can bring it: in Settings, under Updates, click Check now.")
            } else if on && resolved != .dxmt {
                HStack(spacing: 8) {
                    settingNote("This works only on the DXMT layer. This game uses \(resolved.title) now, so this switch does nothing.", warn: true)
                    Spacer(minLength: 0)
                    Button("Use DXMT") { model.update(game.id) { $0.renderer = .dxmt } }.buttonStyle(QuietButtonStyle())
                        .help("Sets the graphics layer to DXMT")
                }
            } else {
                settingNote("Experimental. DXMT's own DirectX 12 part is still in development. The game may not start, or it may draw wrong. On: the game runs on the DXMT layer with it. Off: the game goes back to Automatic. If the game does not start, turn this off.")
            }
        }
    }
}

/// Detailed logs, in Fix things next to Show logs. A launcher runs with its game's settings, so it
/// shares its game's choice.
struct DetailedLogsControl: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let source = model.settingsSource(for: game)
        let id = source?.id ?? game.id
        let on = model.settings(for: id).detailedLogs
        Group {
            Toggle("Detailed logs", isOn: Binding(get: { model.settings(for: id).detailedLogs },
                                                  set: { v in model.update(id) { $0.detailedLogs = v } }))
            settingNote((on
                ? "On: the next start writes Wine's errors, and the notes of DXVK and DXMT, into the logs. Turn this off when you are done: the logs grow fast."
                : "Off: the logs keep only the warnings and errors of DXVK and DXMT, and nothing from Wine. When a game fails, turn this on, press Play, then open Show logs.")
                // The runner's wrappers put back the levels that Steam's launch options set (Runner.restoreAskedLogs).
                + (game.localExe == nil ? " A log level in Steam's launch options (WINEDEBUG, DXVK_LOG_LEVEL or DXMT_LOG_LEVEL) always wins." : "")
                + (source.map { " This program shares the choice with \($0.name)." } ?? ""))
        }
    }
}

/// At the top of a Steam game's page: Play waits while Unwine writes the display settings into the bottle.
struct BottleWaitRow: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        if model.bottlePlayQueued.contains(game.id) && model.bottleWriting.contains(game.id) {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 22)
                PhaseWords(words: ["Writing the display settings into the game's bottle…", "Steam starts \(game.name) when this is done"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
        }
    }
}

/// The game page's small note under a control. It turns orange while a control is on but does nothing.
private func settingNote(_ text: String, warn: Bool = false) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(warn ? Palette.warn : Palette.muted).padding(.bottom, 4)
}
