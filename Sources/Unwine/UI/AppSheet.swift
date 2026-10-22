import SwiftUI
import UniformTypeIdentifiers

/// The page of a Windows app (not a game): what it needs, sharp text and Mac keys, the files it opens,
/// its own Mac app in Launchpad, and the bottle tools. Game settings (frame caps, Apple extras) are left
/// out; the graphics layer shows only for an app that draws with DirectX, OpenGL or Vulkan.
struct AppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: Int
    @State private var confirmReset = false
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
                Text("This app is not in Unwine any more.").foregroundStyle(Palette.text)
                Button("Close") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            .padding(40)
        }
    }

    private func content(_ game: SteamGame) -> some View {
        let running = model.localRunning.contains(game.id)
        let step = model.localStarting[game.id]
        let analysis = model.analysis(for: game)
        let followed = model.settingsSource(for: game)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GameArt(appID: game.id, kind: .hero, title: game.name)
                    .frame(height: 150).clipped()
                LinearGradient(colors: [.clear, Palette.night.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.text)
                        Text(facts(game, analysis)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if model.runtimeJob(inBottleOf: game) != nil {
                        // The installer runs in the bottle: Quit would cut it short, so Open waits instead.
                        Button { } label: { Label("Open", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(true)
                            .help("A runtime is installing in this app's bottle. Open works when it is done.")
                    } else if running {
                        Button { Task { await model.quitApp(game) } } label: { Label("Quit app", systemImage: "stop.fill") }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(step != nil)
                            .help(step ?? "Asks the app to quit, as the Dock's Quit does. If it has work you did not save, it asks you first.")
                    } else {
                        Button { model.play(game) } label: { Label("Open", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(step != nil)
                            .help(step ?? "Opens the app")
                    }
                }
                .padding(18)
            }
            // Pinned under the header, outside the scroll, so the result of a button at the bottom shows.
            BannerHost()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let words = model.runState(of: game).waitWords {
                        HStack(spacing: 10) {
                            UnwineMark(progress: nil, size: 22)
                            PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                        }
                    }
                    notices(game)
                    section("What it needs") { RuntimeSection(game: game) }
                    section("Display and keys") { displayControls(game) }
                    section("Files it opens") { FileTypesControl(game: game) }
                    section("Launchpad and Dock") { MacAppControl(game: game) }
                    if let api = analysis?.api, api != .unknown {
                        // A CAD view or a 3D preview: the layer that draws it matters, as for games.
                        section("Graphics") { graphics(game, api: api) }
                    }
                    section("Launch options") { LaunchOptionsEditor(game: game, followed: followed) }
                    section("Fix things") { fixThings(game) }
                }
                .padding(20)
                .toggleStyle(.switch)
                .tint(Palette.accent)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Palette.night)
        }
        .frame(width: 560, height: 680)
        .background(AppBackground())
        // Each visit looks again: an installer may have added runtimes or file types meanwhile.
        .task(id: game.id) {
            await model.checkRuntimes(game)
            await model.readRegisteredFileTypes(game)
            if model.macAppPlaces[game.id] == nil, model.macAppOn(game) { model.refreshMacApp(for: game.id) }
        }
        .confirmationDialog("Start this app with a fresh Windows bottle?", isPresented: $confirmReset) {
            Button("Move bottle to Trash", role: .destructive) { model.resetBottle(game) }
        } message: {
            Text("The app's own files stay. Settings it kept inside its bottle, and runtimes Unwine installed there, go to the Trash with it. Unwine makes a new bottle the next time the app opens.")
        }
        .confirmationDialog("Remove \(game.name) from Unwine?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeLocalGame(game); dismiss() }
        } message: {
            Text(model.removeNote(for: game) + " Its Mac app leaves Launchpad.")
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

    // MARK: Parts

    @ViewBuilder
    private func notices(_ game: SteamGame) -> some View {
        if let exe = game.localExe, !FileManager.default.fileExists(atPath: exe.path) {
            NoticeRow(color: Palette.warn, icon: "questionmark.folder",
                      text: "Unwine cannot find \(exe.lastPathComponent) in \(exe.deletingLastPathComponent().path). If the app moved, or its drive is not connected, point Unwine at it again. Its bottle stays.") {
                Button("Locate…") { locating = true }.buttonStyle(QuietButtonStyle())
                    .help("Pick the app's program where it is now")
            }
        }
        if let found = model.installedPrograms[game.id], !found.isEmpty {
            NoticeRow(color: Palette.ok, icon: "shippingbox",
                      text: "The installer put \(found.count == 1 ? "a new program" : "\(found.count) new programs") in this Windows bottle. Pick the one to open. This entry then opens it, in the same bottle.") {
                Button("Pick the installed program") { installedList = found; pickingInstalled = true }.buttonStyle(PrimaryButtonStyle())
                    .help("Shows the new programs, the likeliest first")
                Button { model.installedPrograms[game.id] = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Keep the installer as this entry")
            }
        }
        if game.bottleIncomplete {
            NoticeRow(color: Palette.warn, icon: "wrench.and.screwdriver",
                      text: "This app's Windows bottle is incomplete: its 32-bit part is missing, so 32-bit programs quit at once. A fresh bottle fixes it.") {
                Button("Fresh bottle…") { confirmReset = true }.buttonStyle(QuietButtonStyle())
                    .disabled(model.bottleBusyReason(game) != nil)
                    .help(model.bottleBusyReason(game) ?? "Moves this app's Windows bottle to the Trash. A new one comes the next time it opens.")
            }
        }
    }

    @ViewBuilder
    private func displayControls(_ game: SteamGame) -> some View {
        let s = model.settings(for: game.id)
        Toggle("Sharp text on Retina screens", isOn: binding(game.id, \.retina))
        hint(s.retina
             ? "On: the app draws with every pixel of your screen, so text and lines are sharp. This works in apps made for high-resolution screens; older apps look the same either way. If a window opens small, make it bigger once: the app remembers it."
             : "Off: the app draws at half the pixels and macOS enlarges it, so text looks soft.")
        Toggle("Mac keys (⌘C, ⌘V, ⌘S)", isOn: binding(game.id, \.commandIsCtrl))
        hint(s.commandIsCtrl
             ? "On: the Command keys act as Ctrl, so ⌘C copies, ⌘V pastes and ⌘S saves, as in Mac apps. The Option keys act as Alt."
             : "Off: use the Ctrl key as on Windows. The Command keys act as Alt.")
        hint("Copy and paste work between this app and your Mac, text in any language too. In the app's Open and Save windows, Desktop, Documents and Downloads are your Mac's own folders, and drive Z: is your whole Mac. These settings apply the next time the app opens.")
    }

    @ViewBuilder
    private func graphics(_ game: SteamGame, api: GraphicsAPI) -> some View {
        let s = model.settings(for: game.id)
        let resolved = model.resolvedRenderer(for: game)
        Picker("Graphics layer", selection: binding(game.id, \.renderer)) {
            ForEach(Renderer.allCases) { r in
                Text(r == .auto ? "Automatic (\(model.advice(for: game).renderer.short))" : r.title).tag(r)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        hint("This app draws with \(api.label), so a layer turns that into Metal for your Mac. \(s.renderer == .auto ? "Automatic picks \(resolved.title)." : s.renderer.blurb) If its drawing area stays empty or black, try another layer.")
    }

    @ViewBuilder
    private func fixThings(_ game: SteamGame) -> some View {
        let busy = model.bottleBusyReason(game)
        HStack(spacing: 8) {
            Button("Reset settings") { model.resetSettings(game.id) }.buttonStyle(QuietButtonStyle())
                .help("Back to Unwine's defaults for apps: sharp text and Mac keys on")
            Button("Fresh Windows bottle…") { confirmReset = true }.buttonStyle(QuietButtonStyle())
                .disabled(model.bottleBusyReason(game) != nil)
                .help(model.bottleBusyReason(game) ?? "Moves this app's Windows bottle to the Trash. Unwine makes a new one the next time it opens.")
            ShowLogsButton(game: game, help: "Shows this app's log and Unwine's own, and copies them for a bug report")
        }
        DetailedLogsControl(game: game)
        HStack(spacing: 8) {
            Button("Rename…") { newName = game.name; renaming = true }.buttonStyle(QuietButtonStyle())
                .help("Change the name Unwine, Launchpad and the Dock show for this app")
            Button("Change program…") { model.changeLocalProgram(game) }.buttonStyle(QuietButtonStyle())
                .disabled(busy != nil)
                .help(busy ?? "Points this entry at another .exe, such as the program that an installer put in the bottle. The bottle stays.")
            Button("Move to Games") { model.setKind(.game, for: game); dismiss() }.buttonStyle(QuietButtonStyle())
                .help("For a game that Unwine took for an app. Its page then has the game settings.")
            Button("Remove from Unwine…") { confirmRemove = true }.buttonStyle(QuietButtonStyle())
                .disabled(busy != nil)
                .help(busy ?? "Asks first. The app's own files stay where they are.")
        }
        coverButtons(game)
        let blocker = model.bottleBlocker(game)
        HStack(spacing: 8) {
            Button("Run a program in this bottle…") { model.pickProgramForBottle(game) }.buttonStyle(QuietButtonStyle())
                .disabled(blocker != nil)
                .help(blocker ?? "Runs an .exe, .msi, .bat or .cmd file inside this app's bottle, such as an add-on's installer or a patch")
            Menu {
                ForEach(WineTool.allCases) { tool in
                    Button(tool.title) { Task { await model.runInBottle(game, .tool(tool)) } }
                }
            } label: { Text("Wine tools") }
                .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize()
                .disabled(blocker != nil)
                .help(blocker ?? "Wine settings, the registry editor, the task manager and the uninstaller, for this app's bottle")
        }
        HStack(spacing: 8) {
            Button("Show bottle (C: drive)") { model.showBottleDrive(game) }.buttonStyle(QuietButtonStyle())
                .disabled(!model.bottleExists(game))
                .help(model.bottleExists(game) ? "Opens the bottle's C: drive in Finder. Apps keep their settings in its users folder."
                      : "Open the app once first. Unwine makes its Windows bottle then.")
            Button("Show app files") { model.showGameFiles(game) }.buttonStyle(QuietButtonStyle())
                .help("Shows the app's program in Finder")
        }
        if let step = model.bottleToolStarting[game.id] {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: [step, "Windows programs start slowly on a Mac", "Its window opens soon"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
        }
        Text("Settings apply the next time the app opens.").font(.system(size: 11)).foregroundStyle(Palette.muted)
    }

    @ViewBuilder
    private func coverButtons(_ game: SteamGame) -> some View {
        let copying = ArtState.shared.preparing.contains(game.id)
        HStack(spacing: 8) {
            Button("Choose cover…") { model.chooseCover(for: game) }.buttonStyle(QuietButtonStyle())
                .disabled(copying)
                .help(copying ? "Unwine is copying the picture you picked. Wait a moment." : "Pick a picture for this app's tile. A tall picture fits the tile best.")
            if model.hasCover(game.id) {
                Button("Reset cover") { model.resetCover(for: game) }.buttonStyle(QuietButtonStyle())
                    .disabled(copying)
                    .help(copying ? "Unwine is copying the picture you picked. Wait a moment." : "Removes your picture. The tile shows the app's icon again.")
            }
            if copying {
                UnwineMark(progress: nil, size: 18)
                PhaseWords(words: ["Copying the picture…", "Saving it in Unwine's folder…"]).font(.system(size: 11)).foregroundStyle(Palette.glow)
            }
        }
    }

    private func facts(_ game: SteamGame, _ a: GameAnalysis?) -> String {
        var parts = ["Windows app"]
        if let a { parts.append(a.is64Bit ? "64-bit" : "32-bit") }
        if let date = game.lastPlayed { parts.append("Last opened \(PlayedWords.ago(date))") } else { parts.append("Not opened yet") }
        return parts.joined(separator: " · ")
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

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.bottom, 4)
    }
}

// MARK: - What it needs

/// The Microsoft runtimes an app needs, each with its state and a one-click install, plus a menu for
/// the others. The install shows each step: the download with its size, the SHA-256 check, Microsoft's
/// installer, and the finish.
struct RuntimeSection: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let check = model.runtimeChecks[game.id]
        let job = model.runtimeJobs[game.id]
        let blocker = model.runtimeBlocker(game)
        VStack(alignment: .leading, spacing: 10) {
            if let check {
                if check.needs.isEmpty && check.unoffered.isEmpty {
                    Text("Unwine read the app's files and found nothing more it needs. Wine has the rest.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                // Needs no runtime Unwine offers can meet: said plainly, with no button that cannot help.
                ForEach(check.unoffered, id: \.self) { text in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
                        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(check.needs, id: \.runtime) { need in
                    row(need, installed: check.installed.contains(need.runtime), job: job, blocker: blocker)
                }
                if let job, !check.needs.contains(where: { $0.runtime == job.runtime }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WindowsRuntime.pinned(job.runtime).title).font(.system(size: 12, weight: .semibold))
                        progress(job)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 20)
                    PhaseWords(words: ["Reading the app's files…", "Looking for the Microsoft parts it uses…"])
                        .font(.system(size: 12)).foregroundStyle(Palette.glow)
                }
            }
            moreMenu(installed: check?.installed ?? [], blocker: blocker)
            Text("Runtimes come from Microsoft's own servers. Unwine checks each download against its fixed SHA-256 code, then installs it in this app's Windows bottle only. Other apps and games are not touched.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func row(_ need: RuntimeNeed, installed: Bool, job: RuntimeJob?, blocker: String?) -> some View {
        let runtime = WindowsRuntime.pinned(need.runtime)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : need.required ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(installed ? Palette.ok : need.required ? Palette.warn : Palette.glow)
            VStack(alignment: .leading, spacing: 3) {
                Text(runtime.title).font(.system(size: 12, weight: .semibold))
                Text(installed ? "Installed in this app's bottle." : need.reason + (need.required ? "" : " Optional."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let job, job.runtime == need.runtime { progress(job) }
            }
            Spacer(minLength: 8)
            if installed {
                EmptyView()
            } else if !runtime.works {
                Text("Not in Wine yet").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warn)
                    .help("\(runtime.title) installs, but Wine cannot show it yet (WineHQ bug 58921). The app may open without the parts that need it.")
            } else if job?.runtime != need.runtime {
                let why = blocker ?? model.runtimeBusy(need.runtime, for: game)
                let button = Button("Install") { Task { await model.installRuntime(need.runtime, for: game) } }
                    .disabled(why != nil)
                    .help(why ?? "Downloads \(runtime.megabytes) MB from Microsoft and installs it in this app's bottle. About \(runtime.minutes) min.")
                if need.required { button.buttonStyle(PrimaryButtonStyle()) } else { button.buttonStyle(QuietButtonStyle()) }
            }
        }
    }

    @ViewBuilder
    private func progress(_ job: RuntimeJob) -> some View {
        let runtime = WindowsRuntime.pinned(job.runtime)
        if let step = job.bottleStep {
            ProgressTrack(progress: nil, height: 4)
            PhaseWords(words: [step, "Windows is set up once, then the download starts"])
                .font(.system(size: 11)).foregroundStyle(Palette.glow)
        } else {
        switch job.phase {
        case .downloading(let p):
            ProgressTrack(progress: p, height: 4)
            Text(p.map { "Downloading from Microsoft… \(Int($0 * 100))% of \(runtime.megabytes) MB" } ?? "Downloading from Microsoft…")
                .font(.system(size: 11)).foregroundStyle(Palette.glow)
        case .checking:
            ProgressTrack(progress: nil, height: 4)
            Text("Checking the download against its SHA-256 code…").font(.system(size: 11)).foregroundStyle(Palette.glow)
        case .installing:
            ProgressTrack(progress: nil, height: 4)
            PhaseWords(words: ["Microsoft's installer runs in the app's Windows bottle…",
                               "This takes about \(runtime.minutes) min",
                               "Windows installers are slow on a Mac"])
                .font(.system(size: 11)).foregroundStyle(Palette.glow)
        case .finishing:
            ProgressTrack(progress: nil, height: 4)
            Text("Finishing: Wine saves the bottle…").font(.system(size: 11)).foregroundStyle(Palette.glow)
        }
        }
    }

    /// Every runtime that works in Wine, for an app whose needs Unwine cannot see (it loads them later).
    private func moreMenu(installed: Set<RuntimeID>, blocker: String?) -> some View {
        let works = WindowsRuntime.catalog.filter(\.works)
        let groups: [(String, [WindowsRuntime])] = [
            ("Visual C++", works.filter { $0.id.rawValue.hasPrefix("vc") }),
            (".NET", works.filter { !$0.id.rawValue.hasPrefix("vc") }),
        ]
        return Menu {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { runtime in
                        // A menu item cannot show a tooltip, so a blocked one says why in its title.
                        let have = installed.contains(runtime.id)
                        let elsewhere = model.runtimeBusy(runtime.id, for: game) != nil
                        Button(have ? "\(runtime.title) (installed)"
                               : elsewhere ? "\(runtime.title) (installing for another app)"
                               : "\(runtime.title) · \(runtime.megabytes) MB") {
                            Task { await model.installRuntime(runtime.id, for: game) }
                        }
                        .disabled(have || elsewhere)
                    }
                }
            }
        } label: { Text("Install another runtime") }
            .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize()
            .disabled(blocker != nil)
            .help(blocker ?? "For an app that asks for a Microsoft runtime Unwine did not see in its files. Each comes from Microsoft.")
    }
}

// MARK: - Files it opens

/// The file types the app's Mac app opens from Finder: the ones the app registered in its bottle, and
/// the ones the user adds here.
struct FileTypesControl: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    @State private var newType = ""
    @State private var problem: String?

    var body: some View {
        let on = model.macAppOn(game)
        let types = model.fileTypes(of: game)
        let registered = model.registeredTypes(of: game)
        VStack(alignment: .leading, spacing: 8) {
            if !on {
                Text("Finder opens files through the app's own Mac app. Turn it on under Launchpad and Dock first.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if types.isEmpty {
                Text("No file types yet. Add the ending of the files this app opens, such as fem or dxf.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                FlowRow(types) { ext in
                    HStack(spacing: 4) {
                        Text(".\(ext)").font(.system(size: 12, weight: .medium))
                        if registered.contains(ext) {
                            Image(systemName: "checkmark.seal").font(.system(size: 10)).foregroundStyle(Palette.ok)
                                .help("The app registered this type in its Windows bottle")
                        }
                        Button { model.removeFileType(ext, for: game) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(Palette.muted)
                            .help(registered.contains(ext)
                                  ? "Stops opening .\(ext) files with this app. Type it below to add it back."
                                  : "Stops opening .\(ext) files with this app")
                            .accessibilityLabel("Remove .\(ext)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }
            HStack(spacing: 8) {
                TextField("Add a type, such as dxf", text: $newType)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(QuietButtonStyle())
                    .disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(!on ? "Turn on Show in Launchpad, Spotlight and the Dock first"
                          : newType.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a file ending first" : "Lets Finder open these files with this app")
            }
            .disabled(!on)
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Palette.warn) }
            Text(types.isEmpty
                 ? "Then double-click such a file in Finder, and it opens in this app."
                 : "Double-click a \(types.prefix(2).map { ".\($0)" }.joined(separator: " or ")) file in Finder, and it opens in \(game.name). For a type that a Mac app opens too, right-click the file and choose Open With › \(game.name).")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func add() {
        problem = model.addFileType(newType, for: game)
        if problem == nil { newType = "" }
    }
}

/// Small chips that wrap onto the next line when a row is full.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
                x = 0
            }
            rows[rows.count - 1].items.append((index, x))
            x += size.width + spacing
            rows[rows.count - 1].width = x - spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Launchpad and Dock

/// The switch for the app's own Mac app in ~/Applications/Unwine Apps, where it is, and what the Dock does.
struct MacAppControl: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let on = model.macAppOn(game)
        let place = model.macAppPlaces[game.id]
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show in Launchpad, Spotlight and the Dock", isOn: Binding(get: { on }, set: { model.setMacApp($0, for: game) }))
            if on, let place {
                HStack(spacing: 8) {
                    Text("Applications › Unwine Apps › \(place.deletingPathExtension().lastPathComponent)")
                        .font(.system(size: 12)).foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([place]) }.buttonStyle(QuietButtonStyle())
                        .help("Shows the app's Mac app in Finder. Drag it to the Dock to keep it there.")
                }
                Text("Open it like any Mac app: from Launchpad, Spotlight or the Dock. Unwine starts \(game.name) with these settings. While \(game.name) runs, the Dock shows a second icon for it: that is the running app. To keep it in the Dock, drag the Mac app there, not the running icon.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else if on, model.macAppFailed.contains(game.id) {
                HStack(spacing: 8) {
                    Text("Unwine could not make the Mac app. The app's log says why.")
                        .font(.system(size: 12)).foregroundStyle(Palette.warn)
                    Spacer(minLength: 8)
                    Button("Try again") { model.refreshMacApp(for: game.id) }.buttonStyle(QuietButtonStyle())
                        .help("Makes the Mac app again in Applications › Unwine Apps")
                    ShowLogsButton(game: game, title: "Show log", help: "Shows this app's log, which says why the Mac app failed")
                }
            } else if on {
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 18)
                    PhaseWords(words: ["Making the Mac app…", "Copying the icon…"]).font(.system(size: 11)).foregroundStyle(Palette.glow)
                }
            } else {
                Text("Off: open \(game.name) from Unwine. Files cannot open in it from Finder.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}
