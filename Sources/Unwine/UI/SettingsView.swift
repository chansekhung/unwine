import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickingGPTK = false
    @State private var confirmRemoveOnline = false
    @State private var removeSizes: (games: Int64, saves: Int64)?
    @State private var measuring = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.text)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Updates") {
                        Toggle("Update by itself when needed", isOn: $model.stored.autoUpdate)
                            .onChange(of: model.stored.autoUpdate) { model.save() }
                        row("Engine", model.engine?.wineVersion ?? "Not installed")
                        if let pending = model.stored.pendingEngine {
                            Text("New engine \(pending) is out. It needs a newer Unwine; your current engine keeps working.")
                                .font(.system(size: 11)).foregroundStyle(Palette.warn)
                        }
                        row("Steam Play files", model.stored.kitVersion.map { "NotProton \($0)" } ?? "Not installed")
                        row("Unwine", appVersionText)
                        HStack(spacing: 10) {
                            Button(model.isCheckingUpdates ? "Checking…" : "Check now") { Task { await model.checkForUpdates() } }
                                .buttonStyle(QuietButtonStyle()).disabled(model.isCheckingUpdates || !model.showsLibrary)
                            if model.isCheckingUpdates { ProgressTrack(progress: nil).frame(width: 120) }
                            if case .readyToInstall(let v) = model.appUpdater.status {
                                Button("Install Unwine \(v)") { model.appUpdater.installAndRelaunch() }.buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        if let note = model.updateNote { Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        if let last = model.stored.lastUpdateCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named))).").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }

                    group("GPTK (Apple D3DMetal)") {
                        row("Installed", addingGPTK ? "Adding…" : model.d3dmetal?.label ?? "Not added")
                        Text("Apple only lets you get GPTK with your own Apple ID. When Apple ships a newer one, download it and add it here.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        HStack(spacing: 8) {
                            Button("Get GPTK from Apple") { NSWorkspace.shared.open(D3DMetalStore.appleDownloadPage) }.buttonStyle(QuietButtonStyle())
                            Button("Add from Downloads") { Task { await model.findGPTKInDownloads() } }.buttonStyle(QuietButtonStyle())
                                .disabled(addingGPTK).help(addingGPTK ? "GPTK is being added. Wait for it to finish." : "Adds the newest GPTK file in your Downloads folder")
                            Button("Choose file…") { pickingGPTK = true }.buttonStyle(QuietButtonStyle())
                                .disabled(addingGPTK).help(addingGPTK ? "GPTK is being added. Wait for it to finish." : "Pick a GPTK file from anywhere")
                        }
                        if case .running(let progress, let words) = model.steps[.gptk] {
                            HStack(spacing: 10) {
                                UnwineMark(progress: nil, size: 20)
                                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                            }
                            ProgressTrack(progress: progress)
                        }
                        if case .failed(let why) = model.steps[.gptk] { Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn) }
                        if case .needsUser(let why) = model.steps[.gptk] { Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn) }
                    }

                    group("Steam") {
                        row("Steam Play", stateText)
                        row("Steam version", model.steamVersion ?? "Unknown")
                        Text("Unwine's tool shows in Steam as \u{201C}\(Runner.toolDisplay)\u{201D}. Unwine never changes Steam.app.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        HStack(spacing: 8) {
                            Button("Restart Steam") { Task { await model.restartSteam() } }.buttonStyle(QuietButtonStyle())
                                .disabled(model.gameRunning || model.macSteamBlocked)
                                .help(model.gameRunning ? "Close your game first" : model.macSteamBlocked ? AppModel.macSteamBlockedReason : "Steam closes and opens again")
                            Button("How Steam Play works") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton#readme")!) }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }

                    group("Online mode (Windows Steam)") {
                        row("Status", onlineText)
                        Text("For games with Valve Anti-Cheat (VAC), like Left 4 Dead 2 online. Mac Steam closes while it runs. Open a VAC game in Unwine to set it up.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if case .running(let progress, let words) = model.onlineStep {
                            HStack(spacing: 10) {
                                UnwineMark(progress: nil, size: 20)
                                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                            }
                            ProgressTrack(progress: progress)
                        } else if let words = model.onlineWords {
                            HStack(spacing: 10) {
                                UnwineMark(progress: nil, size: 20)
                                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                            }
                        } else if model.online.installed {
                            Toggle("High Resolution Mode", isOn: $model.stored.onlineHighResolution)
                                .onChange(of: model.stored.onlineHighResolution) { OnlineSteam.highResolution = model.stored.onlineHighResolution; model.save() }
                            Text("On: games and Windows Steam use your screen's full pixels, like CrossOver's switch of the same name. Set a game to your screen's full size (\(fullScreenPixels)). Off: everything draws at half size and macOS scales it up, which is lighter on the GPU; set games to \(halfScreenPixels). Applies the next time Windows Steam starts.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Toggle("Game Mode for games in Windows Steam (experimental)", isOn: $model.stored.onlineGameMode)
                                .onChange(of: model.stored.onlineGameMode) { OnlineSteam.gameModeForGames = model.stored.onlineGameMode; model.save() }
                            Text(model.online.inUse
                                 ? "Takes effect the next time Windows Steam starts. macOS Game Mode gives the game more of the CPU and quiets background work."
                                 : "macOS Game Mode gives the game more of the CPU and quiets background work. If Windows Steam does not start after you turn this on, turn it off again.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            HStack(spacing: 8) {
                                if model.online.running {
                                    Button("Quit Windows Steam") { Task { await model.stopOnline() } }.buttonStyle(QuietButtonStyle())
                                        .help("Steam Cloud saves sync first")
                                } else if model.online.inUse {
                                    Button("Stop Windows programs") { Task { await model.stopOnline() } }.buttonStyle(QuietButtonStyle())
                                        .help("Something still runs inside Windows Steam's bottle. This closes it.")
                                } else {
                                    Button("Open Windows Steam") { Task { await model.openOnline(nil) } }.buttonStyle(QuietButtonStyle())
                                        .disabled(model.gameRunning)
                                        .help(model.gameRunning ? "Close your game first" : "Mac Steam closes while Windows Steam is open")
                                }
                                Button(measuring ? "Checking what is inside…" : "Remove Online mode…") {
                                    measuring = true
                                    Task {
                                        removeSizes = await Task.detached(priority: .userInitiated) { OnlineSteam.bottleDataSizes() }.value
                                        measuring = false
                                        confirmRemoveOnline = true
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(model.online.inUse || measuring)
                                    .help(model.online.inUse ? "Close Windows Steam and its programs first" : "Asks first. Then moves Windows Steam to the Trash.")
                            }
                        }
                    }

                    group("Moving to a new Mac") {
                        Text("1. Copy Unwine.dmg to the new Mac and drag Unwine to Applications.\n2. Open Unwine and run setup again (it downloads the engine once).\n3. Steam Play must be on in the new Mac's Steam.\n4. Your games come back with Steam: copy the Steam library folder, or let Steam download them.")
                            .font(.system(size: 12)).foregroundStyle(Palette.text.opacity(0.9))
                        Button("Show Unwine's folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }.buttonStyle(QuietButtonStyle())
                    }

                    group("Credits") {
                        Text("Wine (LGPL) · Sikarugir engine by Gcenx · DXMT by 3Shain · DXVK · KosmicKrisp (Mesa/LunarG) · MoltenVK · Steam Play parts and Steam bridge by NotProton (GPL-3.0), built on Valve's Proton code · Apple D3DMetal, used under Apple's licence from your own download · Game advice from the Highball database (CC0) and AreWeAntiCheatYet (MIT). Unwine is free and GPL-3.0.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .toggleStyle(.switch).tint(Palette.accent)
            }
        }
        .frame(width: 560, height: 640)
        .background(AppBackground())
        .confirmationDialog("Remove Online mode?", isPresented: $confirmRemoveOnline) {
            Button("Move to Trash", role: .destructive) { model.removeOnline() }
        } message: {
            Text(removeMessage)
        }
        .fileImporter(isPresented: $pickingGPTK, allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]) { result in
            if case .success(let url) = result { Task { await model.importGPTK(url) } }
        }
    }

    private var appVersionText: String {
        let v = model.appUpdater.currentVersion
        switch model.appUpdater.status {
        case .off: return "\(v) (self-update not set up)"
        case .available(let n), .readyToInstall(let n): return "\(v), \(n) ready"
        case .downloading(let p): return "\(v), downloading \(Int((p ?? 0) * 100))%"
        case .failed(let why): return "\(v) (\(why))"
        default: return v
        }
    }

    private var addingGPTK: Bool { model.steps[.gptk]?.isRunning == true }

    private var fullScreenPixels: String {
        guard let s = NSScreen.main else { return "3024 x 1964" }
        return "\(Int(s.frame.width * s.backingScaleFactor)) x \(Int(s.frame.height * s.backingScaleFactor))"
    }

    private var halfScreenPixels: String {
        guard let s = NSScreen.main else { return "1512 x 982" }
        return "\(Int(s.frame.width)) x \(Int(s.frame.height))"
    }

    private var removeMessage: String {
        let f = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var text = "Windows Steam and its sign-in go to the Trash. Games in your Mac Steam library stay: Online mode only links to them."
        if let s = removeSizes {
            if s.games > 0 { text += " Games downloaded inside Windows Steam itself (\(f(s.games))) go to the Trash too." }
            if s.saves > 0 { text += " Saves and settings kept inside its bottle (\(f(s.saves))) go too. Steam Cloud saves stay in the cloud." }
        }
        return text
    }

    private var onlineText: String {
        let o = model.online
        if model.onlineStep.isRunning { return "Setting up…" }
        if let words = model.onlineWords { return words.first ?? "Working…" }
        if o.running { return "Windows Steam is open" }
        if o.inUse { return "Windows programs still running" }
        if o.installed { return o.signedIn ? "Ready, signed in" : "Installed, not signed in" }
        if case .failed = model.onlineStep { return "Setup failed. Open a VAC game to try again." }
        return "Not set up"
    }

    private var stateText: String {
        switch model.steamPlay {
        case .on: return "On, Unwine listed"
        case .off: return "Not seen in Steam"
        case .outdated: return "Steam updated, add-on behind"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).foregroundStyle(Palette.text).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.glow.opacity(0.8))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.stroke))
        }
        .foregroundStyle(Palette.text)
    }
}
