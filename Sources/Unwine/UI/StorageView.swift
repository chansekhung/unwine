import AppKit
import SwiftUI

/// A label and a value, styled like the rows in Settings.
struct SettingsFactRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).foregroundStyle(Palette.text).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

/// Settings' Storage group: what Unwine and its games keep on disk, and safe ways to free it.
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmTrash = false
    @State private var confirmShaders = false
    @State private var confirmGPTK = false

    var body: some View {
        if let words = model.storageWork {
            working(words)
        } else if let report = model.storageReport, model.storageProgress == nil {
            content(report)
                // Numbers from long ago say little: Settings measures again when it opens.
                .task { if Date().timeIntervalSince(report.measuredAt) > 600 { await model.measureStorage() } }
        } else {
            measuring
        }
    }

    // A full measure walks tens of thousands of files: about a second, so it shows its progress.
    private var measuring: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                UnwineMark(progress: model.storageProgress, size: 20)
                PhaseWords(words: ["Measuring engines and downloads…", "Measuring the Windows bottles…",
                                   "Measuring the shader caches…", "Looking for bottles of removed games…"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ProgressTrack(progress: model.storageProgress)
            ForEach(0..<4, id: \.self) { _ in
                Shimmer().frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .task { if model.storageReport == nil { await model.measureStorage() } }
    }

    /// A clean-up runs: deleting many small files takes a moment. The measure comes after it.
    private func working(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ProgressTrack(progress: nil)
        }
    }

    private func content(_ r: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Unwine and its games use up to \(DiskUse.text(r.total)).").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Measure again") { Task { await model.measureStorage() } }
                    .buttonStyle(.link).font(.system(size: 12))
                    .help("Measured \(r.measuredAt.formatted(.relative(presentation: .named))). This measures every folder again.")
            }
            if let note = model.storageNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.glow)
            }

            part("Engines") {
                ForEach(r.engines) { entry($0) }
                hint("To go back to an older engine, use Engine rollback above.")
            }

            if let steamPlay = r.steamPlay {
                part("Steam Play") { entry(steamPlay) }
            }

            part("GPTK") {
                if r.gptk.isEmpty {
                    hint("No GPTK added yet. Add it in the GPTK group above, from Apple's file.")
                } else {
                    ForEach(r.gptk) { entry($0) }
                }
                if r.gptk.count > 1 {
                    Button("Delete old GPTK…") { confirmGPTK = true }.buttonStyle(QuietButtonStyle())
                        .disabled(model.engineSwitchBlocker != nil)
                        .help(model.engineSwitchBlocker ?? "Keeps only the GPTK that your games use")
                }
            }

            part("Downloads") {
                entry(r.downloads)
                if r.leftovers > 0 {
                    HStack(spacing: 10) {
                        Text("\(DiskUse.text(r.leftovers)) of it is left over: no install needs it.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Delete leftovers") { Task { await model.deleteDownloadLeftovers() } }.buttonStyle(QuietButtonStyle())
                            .disabled(downloadBusy).help(downloadBusy ? "A download runs now. Try again when it ends." : "Unwine can get these files again if it ever needs them")
                    }
                } else {
                    hint("Nothing is left over. Each archive goes once its install passed its checks.")
                }
            }

            part("Online mode") {
                if let online = r.online {
                    entry(online)
                    hint("To remove it, use Remove Online mode in the Online mode group above.")
                } else {
                    hint("Not set up. Online mode makes its bottle when you set it up for a VAC game.")
                }
            }

            part("Games you added") {
                if r.addedBottles.isEmpty {
                    hint("No added game has a Windows bottle yet. Unwine makes one when you first press Play.")
                } else {
                    ForEach(r.addedBottles) { entry($0) }
                }
            }

            part("Steam games that use Unwine") {
                if r.steamBottles.isEmpty {
                    hint("No Steam game has a Windows bottle from Unwine yet. Steam makes one when a game first starts.")
                } else {
                    ForEach(r.steamBottles) { entry($0) }
                    hint("Each is the game's Windows bottle. The game itself stays in your Steam library.")
                }
            }

            part("Shader caches") {
                ForEach(r.shaders) { entry($0) }
                let shaderBytes = r.shaders.map(\.bytes).reduce(0, +)
                if shaderBytes > 0 {
                    HStack(spacing: 10) {
                        Text("Saved shaders make the next start of a game quicker. To clear one game's, open it and use Fix things.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Clear all…") { confirmShaders = true }.buttonStyle(QuietButtonStyle())
                            .disabled(model.engineSwitchBlocker != nil)
                            .help(model.engineSwitchBlocker ?? "Asks first. Then each game builds its shaders again at its next start.")
                    }
                } else {
                    hint("No shaders saved yet. They build the first time you play.")
                }
            }

            part("Logs") {
                entry(r.logs)
                if !r.oldLogs.isEmpty {
                    Button("Delete logs of removed games (\(DiskUse.text(r.oldLogBytes)))") { Task { await model.deleteRemovedGameLogs() } }
                        .buttonStyle(QuietButtonStyle())
                        .help("Deletes the logs of games that are no longer in your library")
                }
            }

            part("Left behind by removed games") {
                if r.orphans.isEmpty {
                    hint("Nothing is left behind.")
                } else {
                    ForEach(r.orphans) { o in
                        entry(StorageReport.Entry(id: o.id, title: o.title, note: orphanNote(o), bytes: o.bytes, folder: o.folder))
                    }
                    Button("Move to Trash…") { confirmTrash = true }.buttonStyle(QuietButtonStyle())
                        .help("Asks first. You can take them back out of the Trash until you empty it.")
                }
            }

            Text("Sizes are \u{201C}up to\u{201D} sizes. Engines, bottles and Unwine's Game Mode apps share disk space with copies of the same files (APFS clones), and each copy counts in full. So the real use can be lower.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .confirmationDialog("Move \(r.orphans.count == 1 ? "this bottle" : "these \(r.orphans.count) bottles") to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashOrphanBottles() } }
        } message: {
            Text("No game in Steam or Unwine uses \(r.orphans.count == 1 ? "it" : "them") now: \(r.orphans.map(\.title).joined(separator: ", ")). Together they hold \(DiskUse.text(r.orphans.map(\.bytes).reduce(0, +))). Saves that a game kept inside its bottle go to the Trash too. Steam Cloud saves stay in the cloud.")
        }
        .confirmationDialog("Clear all saved shaders?", isPresented: $confirmShaders) {
            Button("Clear all", role: .destructive) { Task { await model.clearAllShaderCaches() } }
        } message: {
            Text("Unwine deletes \(DiskUse.text(r.shaders.map(\.bytes).reduce(0, +))) of saved shaders. Each game builds its shaders again at its next start, so that start is slower one time. DXMT and D3DMetal share their folders with other Wine apps on this Mac. Games in those apps build their shaders again too.")
        }
        .confirmationDialog("Delete the older GPTK copies?", isPresented: $confirmGPTK) {
            Button("Delete", role: .destructive) { Task { await model.deleteOldGPTK() } }
        } message: {
            Text("Your games use \(r.gptk.first?.title ?? "the newest GPTK"). Unwine deletes \(r.gptk.dropFirst().map(\.title).joined(separator: ", ")) (\(DiskUse.text(r.gptk.dropFirst().map(\.bytes).reduce(0, +)))). To use one again, add it again from Apple's file.")
        }
    }

    private var downloadBusy: Bool {
        model.isSettingUp || model.isCheckingUpdates || model.appUpdater.isBusy || model.engineDownload != nil
    }

    private func orphanNote(_ o: StorageReport.Orphan) -> String {
        switch o.owner {
        case .steam: return "Steam kept this Windows bottle after the game was uninstalled"
        case .added: return "This Windows bottle stayed after its game left Unwine"
        }
    }

    private func entry(_ e: StorageReport.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 12)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                if let note = e.note { Text(note).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 8)
            Text(DiskUse.text(e.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.text)
            if let folder = e.folder {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Show in Finder")
            }
        }
    }

    private func part<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.glow.opacity(0.9))
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
}

/// "Clear shader cache" on a game's page, with the size of what the game saved.
struct ShaderCacheRow: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    @State private var found: (folders: [URL], bytes: Int64)?    // nil while Unwine measures
    @State private var confirming = false
    @State private var clearing = false
    @State private var cleared: String?

    var body: some View {
        HStack(spacing: 8) {
            if clearing {
                UnwineMark(progress: nil, size: 18)
                Text("Clearing the saved shaders…").font(.system(size: 11)).foregroundStyle(Palette.glow)
            } else if let found {
                if found.bytes > 0 {
                    let blocker = model.shaderClearBlocker(for: game)
                    Button("Clear shader cache (\(DiskUse.text(found.bytes)))…") { confirming = true }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(blocker != nil)
                        .help(blocker ?? "Deletes the shaders saved for this game. Use it when the game stops starting, or draws wrong after an update.")
                } else {
                    Text(cleared ?? "No shaders saved yet. They build the first time you play.")
                        .font(.system(size: 11)).foregroundStyle(cleared == nil ? Palette.muted : Palette.glow)
                }
            } else {
                Shimmer().frame(width: 190, height: 30).clipShape(Capsule())
                Text("Measuring the saved shaders…").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .task(id: game.id) { await measure() }
        .confirmationDialog("Clear the saved shaders of \(game.name)?", isPresented: $confirming) {
            Button("Clear shader cache", role: .destructive) { Task { await clear() } }
        } message: {
            Text("Unwine deletes \(DiskUse.text(found?.bytes ?? 0)) of shaders that the graphics layers saved for this game. The next start builds them again, so that start is slower one time. Apple's notes for GPTK give this as the fix when a game stops starting.")
        }
    }

    private func measure() async {
        let game = self.game, mainExe = model.analysis(for: game)?.mainExe
        found = await Task.detached(priority: .utility) { () -> (folders: [URL], bytes: Int64) in
            let folders = ShaderCache.folders(for: game, mainExe: mainExe)
            return (folders, folders.map(DiskUse.size(of:)).reduce(0, +))
        }.value
    }

    private func clear() async {
        guard let found, !clearing else { return }
        clearing = true
        let freed = await model.clearShaderCache(found.folders, of: game)
        clearing = false
        guard let freed else { return }     // the game started meanwhile: the banner says so
        cleared = "Cleared \(DiskUse.text(freed)) of shaders. The next start builds them again."
        self.found = nil
        await measure()
    }
}
