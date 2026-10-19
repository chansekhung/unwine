import AppKit
import Foundation

/// Keeps Decant.app itself up to date from a GitHub releases page.
///
/// The source repo is the `DecantUpdateRepo` key in Info.plist ("owner/name"). With no repo set,
/// app self-update stays off; the engine and graphics layers still update on their own.
@MainActor
@Observable
final class AppUpdater {
    enum Status: Equatable {
        case off
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double?)
        case readyToInstall(String)
        case failed(String)
    }

    var status: Status
    private(set) var lastChecked: Date?
    private var staged: URL?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let repo: String? = {
        let r = (Bundle.main.object(forInfoDictionaryKey: "DecantUpdateRepo") as? String)?.trimmingCharacters(in: .whitespaces)
        return (r?.contains("/") == true) ? r : nil
    }()

    init() { status = repo == nil ? .off : .idle }

    /// Checks, downloads and stages a newer build. Installing waits for the user's click,
    /// so a game is never closed under them.
    func checkAndStage() async {
        guard let repo else { status = .off; return }
        if case .downloading = status { return }
        if case .readyToInstall = status, staged != nil { return }   // already waiting for the click
        // The swap needs a writable folder (not a DMG, not App Translocation).
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path),
              !Bundle.main.bundlePath.contains("/AppTranslocation/"), !Bundle.main.bundlePath.hasPrefix("/Volumes/") else {
            status = .failed("Move Decant to Applications to get updates.")
            return
        }
        status = .checking
        do {
            let releases = try await GitHub.releases(repo, limit: 5)
            lastChecked = Date()
            guard let newest = releases.first(where: { !$0.prerelease }),
                  LooseVersion(newest.tag_name) > LooseVersion(currentVersion),
                  let dmg = newest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                status = .upToDate
                return
            }
            status = .downloading(0)
            let file = try await Downloader.fetch(
                dmg.browser_download_url,
                to: Paths.downloads.appendingPathComponent("Decant-\(newest.tag_name).dmg"),
                expectedBytes: dmg.size, sha256: dmg.sha256
            ) { p in Task { @MainActor in self.status = .downloading(p) } }
            let app = try await Self.extractApp(fromDMG: file)
            let v = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard LooseVersion(v) > LooseVersion(currentVersion) else {
                try? FileManager.default.removeItem(at: app)
                status = .failed("The update file is not newer than this Decant.")
                return
            }
            staged = app
            status = .readyToInstall(newest.tag_name)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Swaps the app bundle and relaunches. A tiny helper script waits for us to quit first.
    func installAndRelaunch() {
        guard let staged else { return }
        let q = Runner.shellQuote
        let current = q(Bundle.main.bundleURL.path)
        let old = q(Bundle.main.bundleURL.path + ".old")
        let new = q(staged.path)
        let pid = ProcessInfo.processInfo.processIdentifier
        // Swap with rollback: if the new copy cannot move in, the old one goes back.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(old)
        if mv \(current) \(old); then
          if mv \(new) \(current); then rm -rf \(old); else mv \(old) \(current); fi
        fi
        xattr -dr com.apple.quarantine \(current) 2>/dev/null
        open \(current)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func extractApp(fromDMG dmg: URL) async throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("decant-update-\(UUID().uuidString)")
        try Paths.ensure(mount)
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                            ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            Task.detached { try? await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"], check: false) }
        }
        let src = mount.appendingPathComponent("Decant.app")
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw NSError(domain: "Decant", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update file has no Decant.app inside."])
        }
        // Stage next to the running app so the final move is on the same disk.
        let dest = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".Decant-update.app")
        try? FileManager.default.removeItem(at: dest)
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), [src.path, dest.path])
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", dest.path])
        return dest
    }
}
