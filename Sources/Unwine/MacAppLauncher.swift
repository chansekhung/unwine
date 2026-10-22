import AppKit

/// A Windows app's own Mac app runs this. It takes the files Finder hands it and asks Unwine to start
/// the app with them ("unwine://open?program=<id>&file=<path>"). It stays open until the app's window
/// shows, so macOS lets that window come to the front. Unwine shows the wait in a small panel, and on a
/// problem comes forward with the reason and ends this launcher.
enum MacAppLauncher {
    static var programID: Int? { Bundle.main.object(forInfoDictionaryKey: MacApps.programKey) as? Int }

    static var isLauncher: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("app.unwine.launch.") == true && programID != nil
    }

    @MainActor
    static func run() {
        let app = NSApplication.shared
        let delegate = LauncherDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var files: [URL] = []
    private var sent = false
    private var started = Date()

    /// Finder hands the files in an Apple Event right after the start, or later while the app starts.
    func application(_ application: NSApplication, open urls: [URL]) {
        files += urls.filter(\.isFileURL)
        if sent { send() }
    }

    /// A second click while it waits sends the request again, so the click is never lost.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        started = Date()
        send()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        started = Date()
        // A moment for Finder's files to arrive, so they go with the first request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.send(); self?.watch() }
    }

    private func send() {
        guard let id = MacAppLauncher.programID else { NSApp.terminate(nil); return }
        // The app runs already: this launcher is in front, so it hands the front to the app at once.
        bringRunningAppForward(id)
        var request = URLComponents()
        request.scheme = "unwine"
        request.host = "open"
        let key = Bundle.main.object(forInfoDictionaryKey: MacApps.secretKey) as? String ?? ""
        request.queryItems = [URLQueryItem(name: "program", value: String(id)), URLQueryItem(name: "key", value: key)]
            + files.map { URLQueryItem(name: "file", value: $0.path) }
        files = []
        sent = true
        guard let url = request.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false        // Unwine comes forward by itself only when something goes wrong
        let stored = (Bundle.main.object(forInfoDictionaryKey: MacApps.unwineKey) as? String).map { URL(fileURLWithPath: $0) }
        // An Unwine that runs already gets the request, so a copy at another place never starts beside
        // it: two would write the same library file.
        let unwineID = stored.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "app.unwine.Unwine"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: unwineID).filter { !$0.isTerminated }
        if !running.isEmpty, !running.contains(where: { $0.bundleURL.map(Self.opensLinks) == true }) {
            let alert = NSAlert()
            alert.messageText = "Another Unwine is open"
            alert.informativeText = "This app needs Unwine 1.0.6 or later. Quit the Unwine that is open, then open this app again."
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let unwine = running.first(where: { $0.bundleURL.map(Self.opensLinks) == true })?.bundleURL ?? stored
        // macOS lets an app come to the front only when the app in front lets it. The user clicked this
        // Mac app, so it passes that on: to the Windows app for its window, and to Unwine for a problem.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "app.unwine.game.\(id)")
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: unwineID)
        if let unwine, FileManager.default.fileExists(atPath: unwine.path) {
            NSWorkspace.shared.open([url], withApplicationAt: unwine, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
        } else {
            NSWorkspace.shared.open(url)    // Unwine moved: Launch Services finds it by its unwine:// links
        }
    }

    /// Only the app in front may hand the front over: the launcher is that app, so it does it, before it quits.
    private func bringRunningAppForward(_ id: Int) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "app.unwine.game.\(id)" && $0.activationPolicy == .regular
        }) else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current, options: [])
    }

    /// The Unwine at this place opens unwine:// links (1.0.6 and later).
    private static func opensLinks(_ app: URL) -> Bool {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("unwine") == true }
    }

    /// Quits once the Windows app shows a window (its Dock icon takes over), after at most two minutes.
    private func watch() {
        guard let id = MacAppLauncher.programID else { return }
        let runner = "app.unwine.game.\(id)"
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let shown = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == runner && $0.activationPolicy == .regular }
                if shown || Date().timeIntervalSince(self?.started ?? .distantPast) > 120 {
                    timer.invalidate()
                    if shown { self?.bringRunningAppForward(id) }
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
