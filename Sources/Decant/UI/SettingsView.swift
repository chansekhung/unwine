import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickingGPTK = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.cream)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Updates") {
                        Toggle("Update by itself when needed", isOn: $model.stored.autoUpdate)
                            .onChange(of: model.stored.autoUpdate) { model.save() }
                        row("Engine", model.engine?.wineVersion ?? "Not installed")
                        if let pending = model.stored.pendingEngine {
                            Text("New engine \(pending) is out. It needs a newer Decant; your current engine keeps working.")
                                .font(.system(size: 11)).foregroundStyle(Palette.warn)
                        }
                        row("Steam Play files", model.stored.kitVersion.map { "NotProton \($0)" } ?? "Not installed")
                        row("Decant", appVersionText)
                        HStack(spacing: 10) {
                            Button(model.isCheckingUpdates ? "Checking…" : "Check now") { Task { await model.checkForUpdates() } }
                                .buttonStyle(QuietButtonStyle()).disabled(model.isCheckingUpdates || !model.showsLibrary)
                            if model.isCheckingUpdates { ProgressTrack(progress: nil).frame(width: 120) }
                            if case .readyToInstall(let v) = model.appUpdater.status {
                                Button("Install Decant \(v)") { model.appUpdater.installAndRelaunch() }.buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        if let note = model.updateNote { Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        if let last = model.stored.lastUpdateCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named))).").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }

                    group("GPTK (Apple D3DMetal)") {
                        row("Installed", model.d3dmetal?.label ?? "Not added")
                        Text("Apple only lets you get GPTK with your own Apple ID. When Apple ships a newer one, download it and add it here.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        HStack(spacing: 8) {
                            Button("Get GPTK from Apple") { NSWorkspace.shared.open(D3DMetalStore.appleDownloadPage) }.buttonStyle(QuietButtonStyle())
                            Button("Add from Downloads") { Task { await model.findGPTKInDownloads() } }.buttonStyle(QuietButtonStyle())
                            Button("Choose file…") { pickingGPTK = true }.buttonStyle(QuietButtonStyle())
                        }
                        if case .failed(let why) = model.steps[.gptk] { Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn) }
                        if case .needsUser(let why) = model.steps[.gptk] { Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn) }
                    }

                    group("Steam") {
                        row("Steam Play", stateText)
                        row("Steam version", model.steamVersion ?? "Unknown")
                        Text("Decant's tool shows in Steam as \u{201C}\(Runner.toolDisplay)\u{201D}. Decant never changes Steam.app.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        HStack(spacing: 8) {
                            Button("Restart Steam") { Task { await model.restartSteam() } }.buttonStyle(QuietButtonStyle())
                                .disabled(model.gameRunning).help(model.gameRunning ? "Close your game first" : "Steam closes and opens again")
                            Button("How Steam Play works") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton#readme")!) }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }

                    group("Moving to a new Mac") {
                        Text("1. Copy Decant.dmg to the new Mac and drag Decant to Applications.\n2. Open Decant and run setup again (it downloads the engine once).\n3. Steam Play must be on in the new Mac's Steam.\n4. Your games come back with Steam: copy the Steam library folder, or let Steam download them.")
                            .font(.system(size: 12)).foregroundStyle(Palette.cream.opacity(0.9))
                        Button("Show Decant's folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }.buttonStyle(QuietButtonStyle())
                    }

                    group("Credits") {
                        Text("Wine (LGPL) · Sikarugir engine by Gcenx · DXMT by 3Shain · DXVK · KosmicKrisp (Mesa/LunarG) · MoltenVK · Steam Play parts and Steam bridge by NotProton (GPL-3.0), built on Valve's Proton code · Apple D3DMetal, used under Apple's licence from your own download. Decant is free and GPL-3.0.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .toggleStyle(.switch).tint(Palette.wine)
            }
        }
        .frame(width: 560, height: 640)
        .background(AppBackground())
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

    private var stateText: String {
        switch model.steamPlay {
        case .on: return "On, Decant listed"
        case .off: return "Not seen in Steam"
        case .outdated: return "Steam updated, add-on behind"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).foregroundStyle(Palette.cream).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.gold.opacity(0.8))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.stroke))
        }
        .foregroundStyle(Palette.cream)
    }
}
