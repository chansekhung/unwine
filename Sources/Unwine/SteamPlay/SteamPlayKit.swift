import Foundation

/// Where Mac Steam's Steam Play pieces live. The Steam add-on (from NotProton, GPL-3.0) reads
/// these exact paths, so they keep NotProton's names.
enum SteamPlayPaths {
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let support = applicationSupport.appendingPathComponent("notproton", isDirectory: true)
    static var bridge: URL { support.appendingPathComponent("bridge", isDirectory: true) }
    static var runners: URL { support.appendingPathComponent("runners", isDirectory: true) }
    static var signatures: URL { support.appendingPathComponent("signatures/macos.arm64", isDirectory: true) }
    static var fonts: URL { support.appendingPathComponent("fonts", isDirectory: true) }
    static var toolList: URL { support.appendingPathComponent("tools") }
    static var addOnLog: URL { support.appendingPathComponent("notproton.log") }
    static var launchers: URL { support.appendingPathComponent("launchers", isDirectory: true) }

    static let steamApp = URL(fileURLWithPath: "/Applications/Steam.app")
    static var steamAddOn: URL { steamApp.appendingPathComponent("Contents/MacOS/notproton.dylib") }
    static let steamData = applicationSupport.appendingPathComponent("Steam", isDirectory: true)
    static var compatTools: URL { steamData.appendingPathComponent("compatibilitytools.d", isDirectory: true) }
    static var configVDF: URL { steamData.appendingPathComponent("config/config.vdf") }
    static var steamLogs: URL { steamData.appendingPathComponent("logs", isDirectory: true) }

    /// Unwine's own cache of the add-on kit, kept so Steam Play can be switched back on offline.
    static var kit: URL { Paths.support.appendingPathComponent("SteamPlay", isDirectory: true) }
}

/// A pinned NotProton release. Unwine uses only its open payload (Steam add-on, bridge, helpers),
/// never its app and never CrossOver.
struct SteamPlayKitRelease: Codable, Equatable, Sendable {
    var version: String
    var url: URL
    var size: Int64
    var sha256: String?

    static let pinned = SteamPlayKitRelease(
        version: "1.2.0",
        url: URL(string: "https://github.com/NotProtonNot/NotProton/releases/download/v1.2.0/NotProton.zip")!,
        size: 73_206_745,
        sha256: "c077473daae9a049a51dd039a2908c7c061f630d58628a74ac4e8a9f6e5b2e09"
    )

    static let repo = "NotProtonNot/NotProton"
}

/// Valve's own Windows Steam client files that the bridge copies into each game's bottle.
/// Pinned to the same package versions NotProton verified.
enum ValvePackages {
    static let bases = ["https://client-update.akamai.steamstatic.com",
                        "https://steamcdn-a.akamaihd.net/client",
                        "https://media.steampowered.com/client"]

    struct Package { let key: String; let name: String; let sha256: String }
    static let packages = [
        Package(key: "linux", name: "bins_misc_ubuntu12.zip.3f92810725ee673827371a0470cd4f8c7ea8cfae",
                sha256: "026b984726c728bbf81ae3ba16623bcd96e2bf837a859c235acf0ee279d940fd"),
        Package(key: "win64", name: "bins_win64.zip.36f5d9202e79ab2aa3e3c5902e84bbd799d31fc0",
                sha256: "93f5b6bea0267fd85dc8cc823fdab5c5fb55d7f3a1deab0598acefef0e133bce"),
    ]

    struct File { let dest: String; let package: String; let path: String; let sha256: String }
    static let files = [
        File(dest: "legacycompat/Steam.dll", package: "linux", path: "legacycompat/Steam.dll",
             sha256: "b2000e57123e99bbbe26aaec40cfaf09a4df93959c5148f0db571ed2e3401102"),
        File(dest: "legacycompat/SteamService.exe", package: "linux", path: "legacycompat/SteamService.exe",
             sha256: "a12c6c9ed617bf7c804227cb494666487c9d185daf61940af498980f6937387e"),
        File(dest: "legacycompat/iscriptevaluator.exe", package: "linux", path: "legacycompat/iscriptevaluator.exe",
             sha256: "bafaae73e3763522917d34681b77120c29bef7dd3801c34e8cc8d5e92a78eeeb"),
        File(dest: "legacycompat/steamclient.dll", package: "linux", path: "legacycompat/steamclient.dll",
             sha256: "e9e961c914a418b6a3c597822bdc920bdea62c842ff42de23dc306331da563f8"),
        File(dest: "legacycompat/steamclient64.dll", package: "linux", path: "steamclient64.dll",
             sha256: "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee"),
        File(dest: "legacycompat/GameOverlayRenderer64.dll", package: "linux", path: "GameOverlayRenderer64.dll",
             sha256: "59057f983ae6f02b7eb2495bf65e0430129dd81dff8d9628c764bd1a07e23fee"),
        File(dest: "steamclient.dll", package: "linux", path: "legacycompat/steamclient.dll",
             sha256: "e9e961c914a418b6a3c597822bdc920bdea62c842ff42de23dc306331da563f8"),
        File(dest: "steamclient64.dll", package: "linux", path: "steamclient64.dll",
             sha256: "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee"),
        File(dest: "tier0_s64.dll", package: "win64", path: "tier0_s64.dll",
             sha256: "30f7bb8d9b86006852493c26124ba253bd9e7ffd40a8b3c7254f86a9032c3be3"),
        File(dest: "vstdlib_s64.dll", package: "win64", path: "vstdlib_s64.dll",
             sha256: "99efb4c2ad47f90c803b5ee0bd6424916b28facb9fa2568845b1b1f58a36062a"),
    ]

    static var totalBytes: Int64 { 37_703_386 + 63_700_191 }
}

enum SteamPlayError: LocalizedError {
    case badKit(String)

    var errorDescription: String? {
        switch self {
        case .badKit(let why): return "The Steam Play kit is incomplete: \(why)"
        }
    }
}

/// Downloads and stages everything Steam Play needs except the engine itself.
enum SteamPlayKit {
    /// Files of the payload the Steam side uses, relative to NotProton's payload folder.
    static let payloadFiles = ["notproton.dylib", "overlay-shim.dylib", "iconmaker", "appinfo"]
    static let bridgeMap: [(from: String, to: [String])] = [
        ("bridge/steam.exe", ["steam.exe"]),
        ("bridge/x86_64-windows-lsteamclient.dll", ["lsteamclient.dll", "x86_64-windows/lsteamclient.dll"]),
        ("bridge/x86_64-unix-lsteamclient.so", ["lsteamclient.so", "x86_64-unix/lsteamclient.so"]),
        ("bridge/aarch64-unix-lsteamclient.so", ["aarch64-unix/lsteamclient.so"]),
        ("bridge/i386-windows-lsteamclient.dll", ["i386-windows/lsteamclient.dll"]),
    ]

    static func kitFolder(_ release: SteamPlayKitRelease) -> URL {
        SteamPlayPaths.kit.appendingPathComponent("kit-\(release.version)", isDirectory: true)
    }

    static func isDownloaded(_ release: SteamPlayKitRelease) -> Bool {
        let k = kitFolder(release)
        return (payloadFiles + ["valve/steamclient64.dll"]).allSatisfy {
            FileManager.default.fileExists(atPath: k.appendingPathComponent($0).path)
        }
    }

    /// Step 1: fetch the kit (NotProton payload + Valve's Windows Steam files) into Unwine's cache.
    static func download(_ release: SteamPlayKitRelease, log: LogFile,
                         progress: @escaping @Sendable (Double?) -> Void) async throws {
        if isDownloaded(release) { progress(1); return }
        try Paths.ensure(Paths.downloads)
        let total = Double(release.size + ValvePackages.totalBytes)
        let zip = Paths.downloads.appendingPathComponent("NotProton-\(release.version).zip")
        if (try? Downloader.sha256(of: zip)) != release.sha256 || release.sha256 == nil {
            _ = try await Downloader.fetch(release.url, to: zip, expectedBytes: release.size, sha256: release.sha256) { p in
                progress(p.map { $0 * Double(release.size) / total })
            }
        }
        var done = Double(release.size)
        var valveZips: [String: URL] = [:]
        for pkg in ValvePackages.packages {
            let file = Paths.downloads.appendingPathComponent(pkg.name)
            if (try? Downloader.sha256(of: file)) != pkg.sha256 {
                var lastError: Error?
                for base in ValvePackages.bases {
                    do {
                        let start = done
                        _ = try await Downloader.fetch(URL(string: "\(base)/\(pkg.name)")!, to: file, sha256: pkg.sha256) { p in
                            progress(p.map { (start + $0 * Double(ValvePackages.totalBytes) / 2) / total })
                        }
                        lastError = nil
                        break
                    } catch { lastError = error; log.line("Valve mirror \(base) failed: \(error.localizedDescription)") }
                }
                if let lastError { throw lastError }
            }
            done += Double(ValvePackages.totalBytes) / 2
            valveZips[pkg.key] = file
        }
        progress(nil)

        let stage = SteamPlayPaths.kit.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensure(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, stage.appendingPathComponent("np").path], log: log)
        let payload = stage.appendingPathComponent("np/NotProton.app/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload")
        guard FileManager.default.fileExists(atPath: payload.appendingPathComponent("notproton.dylib").path) else {
            throw SteamPlayError.badKit("no payload in NotProton \(release.version)")
        }

        let out = stage.appendingPathComponent("kit", isDirectory: true)
        try Paths.ensure(out)
        for name in payloadFiles + ["signatures", "fonts", "bridge"] {
            try FileManager.default.copyItem(at: payload.appendingPathComponent(name), to: out.appendingPathComponent(name))
        }
        let valve = out.appendingPathComponent("valve", isDirectory: true)
        try Paths.ensure(valve.appendingPathComponent("legacycompat"))
        for (key, zipFile) in valveZips {
            let dir = stage.appendingPathComponent("valve-\(key)")
            try Paths.ensure(dir)
            // Valve's zips also carry names with backslashes; we only read the plain ones below.
            try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", "-o", zipFile.path, "-d", dir.path], log: log, check: false)
        }
        for f in ValvePackages.files {
            let src = stage.appendingPathComponent("valve-\(f.package)/\(f.path)")
            let dst = valve.appendingPathComponent(f.dest)
            guard (try? Downloader.sha256(of: src)) == f.sha256 else { throw SteamPlayError.badKit("Valve file \(f.dest) did not match") }
            try FileManager.default.copyItem(at: src, to: dst)
        }
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", out.path], check: false)
        let final = kitFolder(release)
        try? FileManager.default.removeItem(at: final)
        try Paths.ensure(SteamPlayPaths.kit)
        try FileManager.default.moveItem(at: out, to: final)
        log.line("Steam Play kit \(release.version) ready")
    }

    /// The kit version whose files are in the shared folder now (written by Unwine or NotProton).
    static func stagedVersion() -> String? {
        (try? String(contentsOf: SteamPlayPaths.support.appendingPathComponent("dylib.version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Step 2: copy the kit into the folders the Steam add-on reads. Safe to repeat.
    /// Never replaces newer files (for example from a newer NotProton the user installed).
    static func stage(_ release: SteamPlayKitRelease, log: LogFile) throws {
        let fm = FileManager.default
        let kit = kitFolder(release)
        let support = SteamPlayPaths.support
        if let current = stagedVersion(), LooseVersion(current) > LooseVersion(release.version),
           fm.fileExists(atPath: SteamPlayPaths.bridge.appendingPathComponent("x86_64-unix/lsteamclient.so").path) {
            log.line("Steam Play files \(current) are newer than kit \(release.version); leaving them")
            return
        }
        for dir in [support, SteamPlayPaths.bridge, SteamPlayPaths.signatures, SteamPlayPaths.fonts, SteamPlayPaths.runners] {
            try Paths.ensure(dir)
        }
        func replace(_ src: URL, _ dst: URL) throws {
            try Paths.ensure(dst.deletingLastPathComponent())
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        for name in ["overlay-shim.dylib", "iconmaker", "appinfo"] {
            try replace(kit.appendingPathComponent(name), support.appendingPathComponent(name))
        }
        for file in (try? fm.contentsOfDirectory(at: kit.appendingPathComponent("signatures/macos.arm64"), includingPropertiesForKeys: nil)) ?? [] {
            try replace(file, SteamPlayPaths.signatures.appendingPathComponent(file.lastPathComponent))
        }
        try? fm.removeItem(at: SteamPlayPaths.fonts)
        try fm.copyItem(at: kit.appendingPathComponent("fonts"), to: SteamPlayPaths.fonts)
        for entry in bridgeMap {
            for to in entry.to {
                try replace(kit.appendingPathComponent(entry.from), SteamPlayPaths.bridge.appendingPathComponent(to))
            }
        }
        for f in ValvePackages.files {
            try replace(kit.appendingPathComponent("valve/\(f.dest)"), SteamPlayPaths.bridge.appendingPathComponent(f.dest))
        }
        try (release.version + "\n").write(to: support.appendingPathComponent("dylib.version"), atomically: true, encoding: .utf8)
        log.line("Steam Play files staged from kit \(release.version)")
    }

    /// Deletes cached kits other than `keep`.
    static func prune(keep: SteamPlayKitRelease) {
        for item in (try? FileManager.default.contentsOfDirectory(at: SteamPlayPaths.kit, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("kit-") && item.lastPathComponent != kitFolder(keep).lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// The newest NotProton release on GitHub, for the updater.
    static func latestRelease() async throws -> SteamPlayKitRelease? {
        let releases = try await GitHub.releases(SteamPlayKitRelease.repo, limit: 5)
        guard let r = releases.first(where: { !$0.prerelease }),
              let zip = r.assets.first(where: { $0.name == "NotProton.zip" }) else { return nil }
        return SteamPlayKitRelease(version: r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                                   url: zip.browser_download_url, size: zip.size, sha256: zip.sha256)
    }
}
