import SwiftUI

/// Engine notices for Settings' Updates group: the download of a new engine with its progress, a
/// download that waits for power or a normal network, and a new engine that waits because one of
/// Unwine's fixes does not fit it.
struct EngineUpdateNotices: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUse = false

    var body: some View {
        if let step = model.engineDownload {
            HStack(spacing: 10) {
                UnwineMark(progress: progress(step), size: 20)
                PhaseWords(words: words(step)).font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ProgressTrack(progress: progress(step))
        }
        if let waiting = model.stored.deferredEngine, model.engineDownload == nil {
            HStack(spacing: 10) {
                Text("New engine ready to download (\(DiskUse.text(waiting.totalBytes))).\(model.updateDeferralReason.map { " \($0), so Unwine waits." } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(Palette.glow)
                Spacer()
                Button("Update now") { Task { await model.downloadDeferredEngine() } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isCheckingUpdates || model.engineSwitching != nil)
                    .help(model.isCheckingUpdates ? "Unwine is checking for updates now. Wait for it to finish."
                          : model.engineSwitching != nil ? "Unwine is switching engines now."
                          : "Downloads the new engine now. Unwine switches to it when no game runs.")
            }
        }
        if let held = model.stored.heldEngine, let engine = model.heldEngineInstalled {
            Text(PatchStatus.heldNote(engine, missing: held.missing))
                .font(.system(size: 11)).foregroundStyle(Palette.warn)
            HStack(spacing: 8) {
                Button("Use it anyway…") { confirmUse = true }.buttonStyle(QuietButtonStyle())
                    .disabled(model.engineSwitchBlocker != nil)
                    .help(model.engineSwitchBlocker ?? "Asks first. Then Unwine switches without the fix.")
                Button("Delete it") { Task { await model.deleteHeldEngine() } }.buttonStyle(QuietButtonStyle())
                    .disabled(model.engineSwitching != nil)
                    .help(model.engineSwitching != nil ? "Unwine is switching engines now." : "Deletes the new engine. Updates then do not get it again.")
            }
            .confirmationDialog("Switch to the new engine without the fix?", isPresented: $confirmUse) {
                Button("Switch anyway", role: .destructive) { Task { await model.useHeldEngine() } }
            } message: {
                Text("\(PatchStatus.fixPhrase(held.missing)) \(held.missing.count == 1 ? "is" : "are") then off. Games that need \(held.missing.count == 1 ? "it" : "them") can freeze or close again. You can go back to your current engine in Engine rollback.")
            }
        }
    }

    private func progress(_ step: EngineStore.Step) -> Double? {
        if case .downloading(let p) = step { return p }
        return nil
    }

    private func words(_ step: EngineStore.Step) -> [String] {
        switch step {
        case .downloading: return ["Downloading the new engine…", "Wine 11 with DXMT, DXVK and KosmicKrisp", "A cut-off download goes on where it stopped"]
        case .unpacking: return ["Unpacking the new engine…", "Leaving Apple's files out"]
        case .checking: return ["Test-starting Wine…"]
        }
    }
}

/// Settings' Engine rollback group: go back to the engine from before the last change.
struct EngineRollbackSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let words = model.engineSwitching {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ProgressTrack(progress: nil)
        }
        if let previous = model.previousEngineInstalled, let current = model.engine {
            SettingsFactRow("Previous engine", previous.label)
            Text("Unwine keeps the engine you had before the last change. If a game broke after an engine update, go back to it. Games use it the next time they start.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            // Two engines can share a Wine version; then the runtime tells them apart.
            let name = previous.wineVersion == current.wineVersion ? previous.label : previous.wineVersion
            Button(previous.installedAt > current.installedAt ? "Use \(name) again" : "Go back to \(name)") {
                Task { await model.goBackToPreviousEngine() }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.engineSwitchBlocker != nil)
            .help(model.engineSwitchBlocker ?? "Unwine builds its Steam tool on that engine. This takes about a minute.")
        } else {
            SettingsFactRow("Previous engine", "None")
            Text("There is no older engine to go back to. After the next engine update, Unwine keeps the old one here.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

/// Settings' Unwine fixes group: which of Unwine's own fixes the engine in use has, and why one is off.
struct UnwineFixesSection: View {
    @Environment(AppModel.self) private var model
    @State private var fixes: [UnwineFix]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .task(id: model.engine?.folder) { await load() }
    }

    @ViewBuilder private var content: some View {
        if model.engine == nil {
            SettingsFactRow("Unwine's fixes", "None yet")
            Text("Finish setup first. Unwine adds its fixes when it installs the engine.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        } else if let fixes {
            SettingsFactRow("Unwine's fixes", "\(fixes.filter(\.on).count) of \(fixes.count) on")
            ForEach(fixes) { fix in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: fix.on ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(fix.on ? Palette.ok : Palette.warn).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(fix.kind.title): \(fix.on ? "on" : "off")").font(.system(size: 12, weight: .medium))
                        Text(fix.why).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Text("Unwine changes copies of the engine's files, never the files themselves. Before it moves to a new engine, it checks that these fixes fit that engine.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        } else {
            // Reading the reasons takes a moment (checksums of a few files).
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                Text("Checking Unwine's fixes…").font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            ForEach(0..<4, id: \.self) { _ in
                Shimmer().frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func load() async {
        guard let engine = model.engine else { fixes = nil; return }
        fixes = nil
        fixes = await Task.detached(priority: .utility) { PatchStatus.fixes(engine: engine, explain: true) }.value
    }
}

/// Settings' Compatibility data group: Highball's list of tested games, how old it is, and Refresh now.
struct CompatibilityDataSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.highballLoads     // redraws when a new list arrives
        let count = HighballDB.gameCount
        let date = HighballDB.updatedAt
        SettingsFactRow("Compatibility data", count > 0 ? "\(count) games, updated \(day(date))" : "Not downloaded yet")
        Text("Unwine's advice uses Highball's free list of games tested on Apple silicon. Unwine gets the whole list, so nobody learns which games you have.")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        if count > 0, let date, Date().timeIntervalSince(date) > 7 * 86_400 {
            Text("This list is more than a week old: Unwine could not get a newer one. Check the internet connection, then press Refresh now.")
                .font(.system(size: 11)).foregroundStyle(Palette.warn)
        }
        HStack(spacing: 10) {
            Button(model.highballRefreshing ? "Refreshing…" : "Refresh now") { Task { await model.refreshCompatibilityData() } }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.highballRefreshing)
                .help(model.highballRefreshing ? "Unwine is asking Highball for its list now." : "Asks Highball for its newest list. When nothing changed, nothing downloads.")
            if model.highballRefreshing { ProgressTrack(progress: nil).frame(width: 120) }
        }
        if let note = model.highballNote, !model.highballRefreshing {
            Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func day(_ date: Date?) -> String {
        guard let date else { return "never" }
        if Calendar.current.isDateInToday(date) { return "today" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
