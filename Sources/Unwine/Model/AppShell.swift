import AppKit
import Foundation

/// The sheet over the library. There is one at a time: a new one takes the place of the one that
/// shows, so ⌘, on a game's page goes straight to Settings.
enum LibrarySheet: Identifiable {
    case game(Int)
    case settings
    /// The program chooser. Without `programs` it looks through the folder itself, off the main thread.
    case chooser(folder: URL?, programs: [(url: URL, size: Int64)]?)

    var id: String {
        switch self {
        case .game(let id): return "game-\(id)"
        case .settings: return "settings"
        case .chooser(let folder, _): return "chooser-\(folder?.path ?? "")"
        }
    }
}

/// .exe files opened with Unwine from Finder (Open With, or a drop on the Dock icon). They can come
/// before the window shows, so they wait here until the model takes them.
@MainActor
enum OpenedFiles {
    static var handler: (([URL]) -> Void)?
    private static var waiting: [URL] = []
    private static var recent: [URL: Date] = [:]

    static func receive(_ urls: [URL]) {
        // macOS can give one file to the app delegate and to the window too: take it once.
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 3 }
        let fresh = urls.filter { recent[$0.standardizedFileURL] == nil }
        for url in fresh { recent[url.standardizedFileURL] = now }
        guard !fresh.isEmpty else { return }
        if let handler { handler(fresh) } else { waiting += fresh }
    }

    static func take() -> [URL] {
        defer { waiting = [] }
        return waiting
    }
}

/// Unwine's app delegate. It is only here for files that Finder opens with Unwine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { OpenedFiles.receive(urls) }
}

/// Facts about this Mac that no button in Unwine can change.
enum MacCheck {
    static var isAppleSilicon: Bool {
        var isArm = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.optional.arm64", &isArm, &size, nil, 0)
        return isArm == 1
    }

    static var needsNewerMacOS: Bool {
        !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    static func openSoftwareUpdate() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
    }
}

extension AppModel {
    /// Starts Unwine: reads the saved state and the installed parts, then the window shows the
    /// library or setup. Until then it shows only the breathing mark, never a wrong screen.
    func boot() {
        start()
        // start() stops early when Unwine renames itself and opens again: the mark keeps breathing.
        guard loaded, !booted else { return }
        booted = true
        OpenedFiles.handler = { [weak self] urls in self?.open(urls) }
        open(OpenedFiles.take())
        watchSetupSteps()
    }

    /// The first look at Steam and at the added games is done, so an empty library is really empty.
    var libraryLoaded: Bool { steamChecked }

    var steamMissing: Bool { !steamInstalled }
    static let steamMissingReason = "Steam is not installed. Get Steam to play Steam games."

    // MARK: Adding games from Finder

    /// Games opened with Unwine from Finder. While setup runs they wait, and setup says so.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if booted && showsLibrary { add(urls) } else { pendingOpens += urls.filter { !pendingOpens.contains($0) } }
    }

    /// Adds the games that waited for setup. RootView calls it when the library shows.
    func flushPendingOpens() {
        guard booted, showsLibrary, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens = []
        add(urls)
    }

    /// Adds games from the Add game picker, a drop on the window, Open With and the Dock icon. A folder
    /// shows its programs when it is not clear which one starts the game.
    func add(_ urls: [URL]) {
        var folders: [URL] = []
        for url in urls {
            guard url.isFileURL else {
                show("Unwine adds games from files on this Mac. Drop a game's folder or its .exe.", .problem)
                continue
            }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if url.pathExtension.lowercased() == "exe" && !isFolder {
                addLocalGame(exe: url)
            } else if isFolder && url.pathExtension.lowercased() != "app" {
                folders.append(url)
            } else {
                show("\(url.lastPathComponent) is not a Windows program. Unwine adds a game by its .exe file or by its folder.", .problem)
            }
        }
        if folders.count == 1 {
            // The chooser looks through the folder off the main thread, with a designed wait, and takes
            // a folder's only program without a question.
            librarySheet = .chooser(folder: folders[0], programs: nil)
        } else if !folders.isEmpty {
            Task { await addFolders(folders) }
        }
    }

    /// Several folders at once: a folder with one program is added, and the chooser asks about the
    /// first folder that is not clear. The folders are read off the main thread.
    private func addFolders(_ folders: [URL]) async {
        let found = await Task.detached(priority: .userInitiated) {
            folders.map { (folder: $0, programs: LocalGames.programs(in: $0)) }
        }.value
        var unclear: [(folder: URL, programs: [(url: URL, size: Int64)])] = []
        for (folder, programs) in found {
            if programs.isEmpty {
                show("No .exe file in \(folder.lastPathComponent). Pick the folder that holds the game's program.", .problem)
            } else if programs.count == 1 {
                addLocalGame(exe: programs[0].url, folder: folder)
            } else {
                unclear.append((folder, programs))
            }
        }
        guard let first = unclear.first else { return }
        librarySheet = .chooser(folder: first.folder, programs: first.programs)
        if unclear.count > 1 {
            show("Unwine asks about one folder at a time. Add \(unclear.dropFirst().map(\.folder.lastPathComponent).joined(separator: ", ")) again after this one.")
        }
    }

    // MARK: Menu bar and sheets

    func openSettings() { librarySheet = .settings }

    func openPage(_ game: SteamGame) { librarySheet = .game(game.id) }

    /// File > Add Game… (⌘O). The picker is a sheet too, so a page or Settings closes first.
    func requestAddGame() {
        afterSheetCloses { [weak self] in self?.pickingGame = true }
    }

    /// Edit > Find… (⌘F): puts the cursor in the library's search field.
    func requestFind() {
        afterSheetCloses { [weak self] in self?.findRequests += 1 }
    }

    private func afterSheetCloses(_ then: @escaping @MainActor () -> Void) {
        guard librarySheet != nil else { then(); return }
        librarySheet = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)     // the sheet's close animation
            then()
        }
    }

    /// Unwine's own project page. A build from a fork names its own repo in Info.plist.
    var projectPage: URL { URL(string: "https://github.com/\(appUpdater.repo ?? "chansekhung/unwine")")! }

    func reportProblem() { NSWorkspace.shared.open(projectPage.appendingPathComponent("issues/new")) }

    func openProjectPage() { NSWorkspace.shared.open(projectPage) }

    func showLogsFolder() {
        _ = try? Paths.ensure(Paths.logs)
        NSWorkspace.shared.open(Paths.logs)
    }

    /// Shows a game's logs in Finder. Before its first start there are none, so the Logs folder opens.
    func revealLogs(of game: SteamGame) {
        let files = [game.runLog, game.wineLog].filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty { showLogsFolder() } else { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    /// Shows one of Unwine's own logs in Finder, or the Logs folder when that log is not there yet.
    func revealLog(named name: String) {
        let file = Paths.logs.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { showLogsFolder() }
    }

    // MARK: Updates

    /// Why Unwine cannot install its own update now, or nil. Unwine closes to update, and the games it
    /// started itself (added games and Windows Steam) run under it.
    var updateBlocker: String? {
        if !localRunning.isEmpty || !localStarting.isEmpty { return "Quit your game first. Unwine closes while it updates." }
        if online.inUse || onlineBusy { return "Quit Windows Steam first. Unwine closes while it updates." }
        return nil
    }

    /// Check for Updates… in the app menu. Its result shows in a banner, because Settings, where the
    /// result shows otherwise, is closed.
    func checkForUpdatesFromMenu() async {
        menuUpdateCheck = true
        await checkForUpdates()
        menuUpdateCheck = false
        let upToDate = "Everything is up to date."
        let note = updateNote ?? upToDate
        switch appUpdater.status {
        case .readyToInstall(let v):
            let ready = "Unwine \(v) is ready to install."
            show(note == upToDate ? ready : "\(note) \(ready)", .success,
                 action: updateBlocker == nil ? .init("Install") { [weak self] in self?.appUpdater.installAndRelaunch() } : nil)
        case .failed:
            show(note, .problem)
        default:
            show(note, note.lowercased().contains("failed") ? .problem : note == upToDate ? .info : .success)
        }
    }

    // MARK: Playing from the keyboard

    /// Play from the keyboard (⌘Return) or VoiceOver. It does what the Play button does, and says
    /// why when the game cannot start now.
    func playIfReady(_ game: SteamGame) {
        if game.localExe != nil {
            guard localStarting[game.id] == nil else { return }
            if localRunning.contains(game.id) { show("\(game.name) is already running."); return }
            play(game)
            return
        }
        let inSteam = Banner.Action("Open in Steam") { [weak self] in self?.showInSteam(game.id) }
        switch game.state {
        case .installed: play(game)
        case .downloading: show("\(game.name) is still downloading in Steam. Play works when the download finishes.", action: inSteam)
        case .needsUpdate: show("\(game.name) needs an update in Steam first. Play works after the update.", .problem, action: inSteam)
        }
    }

    /// Steam's download list, from a tile that shows a download.
    func openSteamDownloads() {
        guard !macSteamBlocked else { show(Self.macSteamBlockedReason + " Mac Steam comes back after that.", .problem); return }
        MacSteam.open("steam://open/downloads")
    }

    // MARK: Setup

    /// Setup without Mac Steam, for games added by their .exe. Steam games work once Steam is installed.
    func useWithoutSteam() async {
        stored.withoutSteam = true
        save()
        await runSetup()
    }

    /// Bounces Unwine's Dock icon when a setup step starts to need the user while another app is in
    /// front, so a long download never waits unseen for a click.
    func watchSetupSteps() {
        let before = steps
        withObservationTracking { _ = steps } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let asks = SetupStep.allCases.contains { Self.wantsUser(self.steps[$0]) && !Self.wantsUser(before[$0]) }
                if asks, !self.showsLibrary, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                self.watchSetupSteps()
            }
        }
    }

    private static func wantsUser(_ status: StepStatus?) -> Bool {
        switch status {
        case .needsUser?, .failed?: return true
        default: return false
        }
    }
}
