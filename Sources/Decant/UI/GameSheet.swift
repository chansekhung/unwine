import SwiftUI

struct GameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: Int
    @State private var confirmReset = false

    private var game: SteamGame? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let game {
            content(game)
        } else {
            VStack(spacing: 12) {
                Text("This game is no longer installed.").foregroundStyle(Palette.cream)
                Button("Close") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            .padding(40)
        }
    }

    private func content(_ game: SteamGame) -> some View {
        let s = model.settings(for: game.id)
        let analysis = model.analysis(for: game)
        let resolved = model.resolvedRenderer(for: game)
        let usesDecant = model.mappings[game.id] == Runner.toolName
        // Steam uses Decant when it is mapped, or when no tool is mapped and the add-on's
        // default (Decant, the only tool it lists) already ran this game.
        let mappedElsewhere = model.mappings[game.id].map { $0 != Runner.toolName } ?? false
        let neverRun = model.mappings[game.id] == nil && !FileManager.default.fileExists(atPath: game.compatData.path)

        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GameArt(appID: game.id, kind: .hero, title: game.name)
                    .frame(height: 170).clipped()
                LinearGradient(colors: [.clear, Palette.night.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.cream)
                        Text(facts(game, analysis)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(game.state != .installed)
                        .help(game.state == .installed ? "Starts in Steam with these settings" : "Finish the download in Steam first")
                }
                .padding(18)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let ac = analysis?.antiCheat, !ac.isEmpty {
                        NoticeRow(color: Palette.warn, icon: "shield.lefthalf.filled",
                                  text: "Uses \(ac.joined(separator: ", ")). Online play with this anti-cheat usually fails on any Mac Wine tool, CrossOver too.")
                    }
                    if !usesDecant && (mappedElsewhere || neverRun) {
                        NoticeRow(color: Palette.warn, icon: "hand.point.right.fill",
                                  text: mappedElsewhere
                                    ? "Steam runs this game with another tool (\(model.mappings[game.id] ?? "")), so these settings do nothing. Switch it to Decant? Steam restarts for a few seconds."
                                    : "Steam is not set to use Decant for this game yet. Steam restarts for a few seconds.") {
                            Button("Use Decant") { Task { await model.useDecant(true, for: game) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                .help(model.gameRunning ? "Close your running game first" : "Steam restarts for a few seconds")
                        }
                    }

                    section("Graphics") {
                        Picker("Graphics layer", selection: binding(game.id, \.renderer)) {
                            ForEach(Renderer.allCases) { r in
                                Text(r == .auto ? "Automatic (\(Profiles.resolve(.auto, analysis: analysis, hasD3DMetal: model.d3dmetal != nil).short))" : r.title)
                                    .tag(r)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text(s.renderer == .auto ? autoReason(analysis, resolved) : s.renderer.blurb)
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        if s.renderer == .d3dmetal && model.d3dmetal == nil {
                            Text("GPTK is not added yet, so this game uses DXMT. Add GPTK 4 in Settings.")
                                .font(.system(size: 12)).foregroundStyle(Palette.warn)
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
                        hint("Caps save battery and heat. Pick a value that divides your screen's refresh rate.")
                    }

                    section("Apple extras") {
                        Toggle("Show the Metal performance overlay", isOn: binding(game.id, \.metalHUD))
                        hint("Shows FPS, GPU time and the GPTK version in a corner of the game.")
                        Toggle("MetalFX upscaling (for DLSS games)", isOn: binding(game.id, \.metalFX))
                        hint("Turns the game's DLSS option into Apple's MetalFX.")
                        Toggle("Metal 4 mode (GPTK 4)", isOn: binding(game.id, \.metal4))
                            .disabled(!(model.d3dmetal?.isVersion4 ?? false) || resolved != .d3dmetal)
                        hint(model.d3dmetal?.isVersion4 == true
                             ? "GPTK 4's newest path. Usually faster; turn off if this game crashes."
                             : "Needs GPTK 4 and the D3DMetal layer.")
                    }

                    section("Fix things") {
                        HStack(spacing: 8) {
                            Button("Reset settings") { model.resetSettings(game.id) }.buttonStyle(QuietButtonStyle())
                                .help("Back to Decant's defaults for new games")
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
                            Button("Show in Steam") { MacSteam.showInSteam(game.id) }.buttonStyle(QuietButtonStyle())
                            Button("Show game files") { NSWorkspace.shared.activateFileViewerSelecting([game.installDir]) }.buttonStyle(QuietButtonStyle())
                            if usesDecant {
                                Button("Stop using Decant") { Task { await model.useDecant(false, for: game) } }
                                    .buttonStyle(QuietButtonStyle()).disabled(model.busyGame != nil || model.gameRunning)
                                    .help("Steam goes back to its default for this game")
                            }
                        }
                        Text("Settings apply the next time the game starts.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                .padding(20)
                .toggleStyle(.switch)
                .tint(Palette.wine)
            }

            HStack {
                if model.busyGame == game.id {
                    DecanterMark(progress: nil, size: 22)
                    PhaseWords(words: ["Closing Steam…", "Saving the choice…", "Opening Steam again…"])
                        .font(.system(size: 12)).foregroundStyle(Palette.gold)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Palette.night)
        }
        .frame(width: 560, height: 680)
        .background(AppBackground())
        .confirmationDialog("Start this game with a fresh Windows bottle?", isPresented: $confirmReset) {
            Button("Move bottle to Trash", role: .destructive) { model.resetBottle(game) }
        } message: {
            Text("Your game files and Steam Cloud saves stay. Saves kept only inside the bottle go to the Trash with it.")
        }
    }

    private func facts(_ game: SteamGame, _ a: GameAnalysis?) -> String {
        var parts: [String] = []
        if let a { parts.append(a.api.label); parts.append(a.is64Bit ? "64-bit" : "32-bit"); if let e = a.engine { parts.append(e) } }
        if game.sizeOnDisk > 0 { parts.append(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    private func autoReason(_ a: GameAnalysis?, _ r: Renderer) -> String {
        guard let a else { return "Decant is reading the game's files to pick the best layer." }
        switch (a.api, r) {
        case (.dx12, .d3dmetal): return "DirectX 12 game, so Apple's D3DMetal (GPTK) runs it."
        case (.dx12, _): return "DirectX 12 game. Add GPTK 4 in Settings for the fastest path; until then DXVK runs it."
        case (.dx11, _), (.dx10, _): return "\(a.api.label) game, so DXMT turns it straight into Metal."
        case (.dx9, _), (.dx8, _): return "\(a.api.label) game, so DXVK runs it on the KosmicKrisp Vulkan driver."
        case (.opengl, _): return "OpenGL game, so Wine's own layer runs it."
        case (.vulkan, _): return "Vulkan game, so it talks to KosmicKrisp directly."
        case (.unknown, _): return "Could not tell the DirectX version, so DXMT is the safe pick."
        }
    }

    private func binding<T>(_ id: Int, _ key: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(get: { model.settings(for: id)[keyPath: key] },
                set: { v in model.update(id) { $0[keyPath: key] = v } })
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.gold.opacity(0.8))
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.stroke))
        }
        .foregroundStyle(Palette.cream)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.bottom, 4)
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
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.cream)
            Spacer(minLength: 0)
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
    }
}
