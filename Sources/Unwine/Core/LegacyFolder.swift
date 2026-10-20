import AppKit
import Foundation

/// Unwine used to be called Decant. These steps carry an existing install over once: the data
/// folder (engine, GPTK, settings) and the app's own name in Applications.
enum LegacyFolder {
    /// Moves the old data folder to the new name, so nothing has to download again. It waits while
    /// any Wine program runs: a game started earlier keeps loading engine files by their old path.
    static func migrate(from old: URL, to new: URL) -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return new }
        // Also wait while Decant 1.0.0 itself runs: it still reads and writes the old folder.
        guard !wineRunning(), NSRunningApplication.runningApplications(withBundleIdentifier: "app.decant.Decant").isEmpty else { return old }
        do {
            try fm.moveItem(at: old, to: new)
            fixScripts(in: new.appendingPathComponent("SteamPlay", isDirectory: true), from: old, to: new)
            return new
        } catch {
            return old
        }
    }

    /// The Steam Play helper scripts name the data folder by its full path.
    private static func fixScripts(in folder: URL, from old: URL, to new: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["sh", "command"].contains(file.pathExtension) {
            // They name it either by full path or as $HOME/Library/Application Support/Decant.
            let oldTail = "Application Support/" + old.lastPathComponent, newTail = "Application Support/" + new.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(oldTail) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            try? text.replacingOccurrences(of: oldTail, with: newTail).write(to: file, atomically: true, encoding: .utf8)
            if let mode = attrs?[.posixPermissions] { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        }
    }

    private static func wineRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "wineserver"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// An update from Decant 1.0.0 lands in /Applications/Decant.app, hidden, because the DMG hides
    /// that copy. Rename it to Unwine.app, show it again and start from there. When an Unwine.app is
    /// already there, keep the newer of the two. Returns true when this copy quits, so the caller
    /// stops starting up.
    @MainActor
    static func renameAppIfNeeded() -> Bool {
        let app = Bundle.main.bundleURL
        guard app.lastPathComponent == "Decant.app" else { return false }
        let folder = app.deletingLastPathComponent()
        let target = folder.appendingPathComponent("Unwine.app")
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: folder.path) else { show(app); return false }

        if fm.fileExists(atPath: target.path) {
            let other = Bundle(url: target)
            let version = { (b: Bundle?) in LooseVersion(b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") }
            // Something else named Unwine.app, or a copy that is open right now: leave it alone.
            let otherIsOpen = NSRunningApplication.runningApplications(withBundleIdentifier: other?.bundleIdentifier ?? "")
                .contains { $0 != .current && $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
            guard other?.bundleIdentifier == Bundle.main.bundleIdentifier, !otherIsOpen else { show(app); return false }
            if version(other) >= version(.main) {
                // The Unwine.app there is as new or newer: use it, and put this copy in the Trash.
                show(target)
                guard (try? fm.trashItem(at: app, resultingItemURL: nil)) != nil else { show(app); return false }
                relaunch(target)
                return true
            }
            // The Unwine.app there is older: it goes to the Trash, and this copy takes its name.
            guard (try? fm.trashItem(at: target, resultingItemURL: nil)) != nil else { show(app); return false }
        }
        do { try fm.moveItem(at: app, to: target) } catch { show(app); return false }
        show(target)
        relaunch(target)
        return true
    }

    /// Clears the hidden flag (and Finder's invisible bit), so the app shows in Finder and Launchpad.
    private static func show(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isHidden = false
        try? url.setResourceValues(values)
    }

    @MainActor
    private static func relaunch(_ app: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", app.path]
        try? open.run()
        NSApp.terminate(nil)
    }
}
