import Foundation

/// Turns Steam Play on in the user's own Mac Steam, and only when the user asks. Mac Steam carries
/// Valve's Steam Play code but no switch for it. NotProton's open add-on (GPL-3.0) turns it on from
/// inside Steam. That takes three changes to Steam.app: the add-on in Contents/MacOS, an
/// LSEnvironment entry in Info.plist that makes Steam load it, and a new signature for this Mac,
/// because the change breaks Valve's. Before the first change Unwine keeps a copy of Valve's
/// Steam.app, and Undo puts that copy back.
enum SteamPlaySwitch {
    /// The copy of Valve's Steam.app from before the first change.
    static var backup: URL { Paths.support.appendingPathComponent("Backups/Steam.app.original", isDirectory: true) }

    private static let loadKey = "DYLD_INSERT_LIBRARIES"
    // NotProton's setup sets this too: SDL then skips the Mac's own Apple device (vendor 05ac,
    // product 0004), which it would otherwise list as a game controller.
    private static let controllerKey = "SDL_JOYSTICK_BLACKLIST_DEVICES"
    private static let controllerValue = "0x05ac/0x0004"

    enum AddOn: Equatable, Sendable {
        case missing        // Steam.app does not load the add-on
        case current        // it loads the add-on of Unwine's newest Steam Play kit
        case behind         // it loads an older add-on than the kit has
    }

    enum SwitchError: LocalizedError, Equatable {
        case noSteam, noAddOn, steamRunning, blocked, failed(String)

        var errorDescription: String? {
            switch self {
            case .noSteam: return "Steam is not in the Applications folder."
            case .noAddOn: return "Unwine has not downloaded the Steam Play files yet. Run setup again."
            case .steamRunning: return "Steam must be closed for this."
            case .blocked:
                return "macOS stopped Unwine from changing Steam. Open System Settings › Privacy & Security › App Management, turn on Unwine, and try again."
            case .failed(let why): return why
            }
        }
    }

    static func addOnPath(_ app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/notproton.dylib") }
    private static func plistPath(_ app: URL) -> URL { app.appendingPathComponent("Contents/Info.plist") }

    /// Steam.app loads the add-on: the file is there and Info.plist names it.
    static func isOn(app: URL = SteamPlayPaths.steamApp) -> Bool {
        let dylib = addOnPath(app)
        guard FileManager.default.fileExists(atPath: dylib.path), let env = environment(of: app) else { return false }
        return env[loadKey] as? String == dylib.path
    }

    /// Whether Steam.app loads the add-on, and whether it is the kit's. The refresh loop asks every
    /// few seconds, so the two checksums are kept until either file changes.
    static func addOnState(kitAddOn: URL?, app: URL = SteamPlayPaths.steamApp) -> AddOn {
        guard isOn(app: app) else { return .missing }
        guard let kitAddOn else { return .current }
        let files = [addOnPath(app), kitAddOn]
        let stamps = files.map { url -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\(url.path) \((a?[.size] as? NSNumber)?.intValue ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cache, c.stamps == stamps { return c.state }
        let same = (try? Downloader.sha256(of: files[0])) == (try? Downloader.sha256(of: files[1]))
        let state: AddOn = same ? .current : .behind
        cache = (stamps, state)
        return state
    }
    private static let cacheLock = NSLock()
    private static var cache: (stamps: String, state: AddOn)?

    /// Puts `addOn` into Steam.app and makes Steam load it. Steam must be closed. Safe to repeat:
    /// it also updates an older add-on.
    static func enable(addOn: URL, app: URL = SteamPlayPaths.steamApp, backupTo: URL = backup, log: LogFile?) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/steam_osx").path) else { throw SwitchError.noSteam }
        guard fm.fileExists(atPath: addOn.path) else { throw SwitchError.noAddOn }
        guard app != SteamPlayPaths.steamApp || !MacSteam.isRunning else { throw SwitchError.steamRunning }
        // Only a Steam.app that still has Valve's signature is worth keeping: Undo puts it back as it was.
        if !fm.fileExists(atPath: backupTo.path), await hasDeveloperSignature(app) {
            try Paths.ensure(backupTo.deletingLastPathComponent())
            try await run("/usr/bin/ditto", [app.path, backupTo.path], log: log)
            log?.line("Steam Play: kept a copy of Valve's Steam.app at \(backupTo.path)")
        }
        let target = addOnPath(app)
        do {
            let stage = target.deletingLastPathComponent().appendingPathComponent(".notproton-\(UUID().uuidString).dylib")
            try fm.copyItem(at: addOn, to: stage)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: stage, to: target)
            try editEnvironment(of: app) { env in
                env[loadKey] = target.path
                env[controllerKey] = controllerValue
            }
        } catch {
            throw isPermission(error) ? SwitchError.blocked : SwitchError.failed("Unwine could not change Steam.app: \(error.localizedDescription)")
        }
        try await sign(app, log: log)
        log?.line("Steam Play: Steam.app loads the add-on from \(target.path)")
    }

    /// Undo: puts Valve's Steam.app back from the copy. Without a copy, it takes the add-on out and
    /// signs Steam again for this Mac (a Steam download from Valve brings Valve's signature back).
    static func disable(app: URL = SteamPlayPaths.steamApp, backupFrom: URL = backup, log: LogFile?) async throws {
        let fm = FileManager.default
        guard app != SteamPlayPaths.steamApp || !MacSteam.isRunning else { throw SwitchError.steamRunning }
        if fm.fileExists(atPath: backupFrom.appendingPathComponent("Contents/MacOS/steam_osx").path) {
            let aside = app.deletingLastPathComponent().appendingPathComponent(".Steam-\(UUID().uuidString).app")
            do { try fm.moveItem(at: app, to: aside) } catch {
                throw isPermission(error) ? SwitchError.blocked : SwitchError.failed("Unwine could not move Steam.app: \(error.localizedDescription)")
            }
            do {
                try await run("/usr/bin/ditto", [backupFrom.path, app.path], log: log)
            } catch {
                try? fm.removeItem(at: app)
                try? fm.moveItem(at: aside, to: app)
                throw error
            }
            try? fm.removeItem(at: aside)
            try? fm.removeItem(at: backupFrom)
            log?.line("Steam Play: Valve's Steam.app is back")
        } else {
            do {
                if fm.fileExists(atPath: addOnPath(app).path) { try fm.removeItem(at: addOnPath(app)) }
                try editEnvironment(of: app) { env in
                    env[loadKey] = nil
                    env[controllerKey] = nil
                }
            } catch {
                throw isPermission(error) ? SwitchError.blocked : SwitchError.failed("Unwine could not change Steam.app: \(error.localizedDescription)")
            }
            try await sign(app, log: log, addOn: false)
            log?.line("Steam Play: add-on taken out of Steam.app (no copy of Valve's Steam.app to put back)")
        }
        _ = try? await Shell.run(lsregister, ["-f", app.path], log: log, check: false)
    }

    // MARK: Steps

    private static func environment(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistPath(app)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["LSEnvironment"] as? [String: Any] ?? [:]
    }

    /// Changes LSEnvironment in Info.plist and writes it back in its own format (XML or binary).
    private static func editEnvironment(of app: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = plistPath(app)
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw SwitchError.failed("Steam's Info.plist could not be read.")
        }
        var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        change(&env)
        plist["LSEnvironment"] = env.isEmpty ? nil : env
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url, options: .atomic)
    }

    /// Signs the add-on, Steam's program and the app for this Mac (ad hoc), then checks the result.
    /// Extended attributes go first: codesign refuses files that carry them.
    private static func sign(_ app: URL, log: LogFile?, addOn: Bool = true) async throws {
        try await run("/usr/bin/xattr", ["-cr", app.path], log: log)
        var parts = [app.appendingPathComponent("Contents/MacOS/steam_osx").path, app.path]
        if addOn { parts.insert(addOnPath(app).path, at: 0) }
        for part in parts { try await run("/usr/bin/codesign", ["-f", "-s", "-", part], log: log) }
        try await run("/usr/bin/codesign", ["-v", "--strict", app.path], log: log)
        _ = try? await Shell.run(lsregister, ["-f", app.path], log: log, check: false)
    }

    /// True for a Developer ID signature, such as Valve's. False for an ad hoc one (signed on a Mac).
    private static func hasDeveloperSignature(_ app: URL) async -> Bool {
        guard let r = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-dv", app.path], check: false) else { return false }
        return r.output.contains("TeamIdentifier=") && !r.output.contains("TeamIdentifier=not set")
    }

    private static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    /// Runs a tool. "Operation not permitted" from macOS means App Management stopped the change.
    private static func run(_ tool: String, _ args: [String], log: LogFile?) async throws {
        do {
            try await Shell.run(URL(fileURLWithPath: tool), args, log: log)
        } catch ShellError.failed(_, _, let output) where output.contains("Operation not permitted") || output.contains("Permission denied") {
            throw SwitchError.blocked
        }
    }

    private static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(under) }
        return false
    }
}
