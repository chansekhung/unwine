import Foundation

/// Unwine's compatibility tool as Mac Steam sees it: a "CrossOver-shaped" copy of the free engine
/// that NotProton's launch script can drive unchanged.
///
/// The script runs `CrossOver/lib/wine/x86_64-unix/wine` and `CrossOver/bin/wineserver`. In our
/// runner those are tiny wrappers that add the free engine's settings plus this game's Unwine
/// profile, then start the real Wine. Every Wine process passes through them, so a game's whole
/// bottle always agrees on settings like msync.
enum Runner {
    /// Steam stores per-game choices under this name, so it never changes across engine updates.
    static let toolName = "notproton-decant"
    static let toolDisplay = "Unwine (free: DXMT + GPTK 4)"

    /// NotProton's script records the build in each game's prefix and refuses a different one,
    /// so the build stays the same across engine updates. Wine upgrades prefixes by itself.
    static let build = "decant-1"

    /// Bump when the wrappers or engine.env change shape, so existing runners get rewritten.
    /// 7: a 32-bit game's DLLs no longer turn DEP off (only its .exe can).
    /// 8: quiet logs (Wine's at -all, DXVK's and DXMT's at warn) unless a game's Detailed logs or Steam's
    /// launch options ask for more; no WINEESYNC (this Wine has no esync).
    /// 9: wineboot, and the programs it starts, run without Faster x87 math.
    /// 10: the loader wrapper starts x87sidecar itself (`startX87`).
    static let format = 10

    /// A game's profile may turn on Faster x87 math only for a runner whose wrapper starts x87sidecar
    /// itself. An older wrapper gives Wine ROSETTA_X87_PATH, and x87sidecar then gets this shell script
    /// and stops the game. No runner yet counts as new: Unwine builds one before a Steam game starts.
    static var startsX87: Bool { (record()?.format ?? format) >= 10 }

    static var base: URL { SteamPlayPaths.runners.appendingPathComponent("crossover-\(build)", isDirectory: true) }
    static var root: URL { base.appendingPathComponent("CrossOver", isDirectory: true) }
    static var profiles: URL { Paths.support.appendingPathComponent("Profiles", isDirectory: true) }
    static var recordURL: URL { root.appendingPathComponent("decant/runner.json") }

    struct Record: Codable, Equatable {
        var engineFolder: String
        var format: Int
        var d3dmetalFolder: String?
        /// The data folder the wrappers and engine.env name. A runner written before the Decant
        /// folder moved to Unwine names the old one, so it no longer matches.
        var supportPath: String?
    }

    static func record() -> Record? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static var isBuilt: Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/wine.decant-real").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("decant/engine.env").path)
    }

    /// True when the runner was built from this engine, with the current file format, for the
    /// current data folder.
    static func matches(_ engine: InstalledEngine) -> Bool {
        guard isBuilt, let r = record() else { return false }
        return r.engineFolder == engine.folder && r.format == format && r.supportPath == Paths.support.path
    }

    /// Any game (or Wine helper) currently running through Unwine's runner: its wineserver runs the
    /// runner's own file, which no other program has.
    static func isInUse() -> Bool { Processes.anyRunning(file: "wineserver.decant-real") }

    /// Is this game's Windows bottle open right now? Wine keeps one server socket per prefix
    /// at /tmp/.wine-<uid>/server-<dev>-<inode>/socket.
    static func isPrefixRunning(_ pfx: URL) -> Bool {
        // The socket file outlives a killed server, so ask the server's lock instead.
        OnlineSteam.serverIsAlive(pfx)
    }

    /// Builds the runner for this engine in a staging folder, then swaps it in.
    /// Callers make sure no game is running (`isInUse()`).
    static func build(engine: InstalledEngine, d3dmetal: D3DMetalInstall?, log: LogFile) async throws {
        let fm = FileManager.default
        try Paths.ensure(SteamPlayPaths.runners)
        let stage = SteamPlayPaths.runners.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        let run = stage.appendingPathComponent("CrossOver", isDirectory: true)
        try Paths.ensure(run)
        defer { try? fm.removeItem(at: stage) }

        // APFS clones: a full copy costs almost no disk space.
        for part in ["bin", "lib", "share"] {
            try await Shell.run(URL(fileURLWithPath: "/bin/cp"), ["-c", "-R", engine.wineDir.appendingPathComponent(part).path, run.path], log: log)
        }
        let lib = run.appendingPathComponent("lib/wine", isDirectory: true)

        // The Steam bridge: patched Wine core plus Valve's lsteamclient port.
        for arch in ["x86_64-windows", "i386-windows"] {
            try NtdllPatcher.patch(lib.appendingPathComponent("\(arch)/ntdll.dll"), arch: arch)
        }
        RendererPatches.applyExeDecidesDEP(wineLib: lib, log: log)
        for (arch, name) in [("x86_64-windows", "lsteamclient.dll"), ("i386-windows", "lsteamclient.dll"), ("x86_64-unix", "lsteamclient.so")] {
            let src = SteamPlayPaths.bridge.appendingPathComponent("\(arch)/\(name)")
            guard fm.fileExists(atPath: src.path) else { throw SteamPlayError.badKit("bridge is missing \(arch)/\(name)") }
            let dst = lib.appendingPathComponent("\(arch)/\(name)")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        let unix = lib.appendingPathComponent("x86_64-unix", isDirectory: true)
        try fm.moveItem(at: unix.appendingPathComponent("wine"), to: unix.appendingPathComponent("wine.decant-real"))
        try fm.moveItem(at: run.appendingPathComponent("bin/wineserver"), to: run.appendingPathComponent("bin/wineserver.decant-real"))
        try writeGeneratedFiles(into: run, engine: engine, d3dmetal: d3dmetal)
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", run.path], check: false)

        // Swap: keep the old runner aside until the new one is in place.
        try Paths.ensure(base)
        let old = SteamPlayPaths.runners.appendingPathComponent(".swap-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
        do {
            try fm.moveItem(at: run, to: root)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: root) }
            throw error
        }
        try? fm.removeItem(at: old)
        try stageBridgeNtdll()
        try writeToolList()
        try Paths.ensure(profiles)
        log.line("Runner \(build) ready on \(engine.folder)")
    }

    /// Rewrites the wrappers, engine.env, the D3DMetal link and the record in place
    /// (after an Unwine update changes them, or GPTK is added). Cheap; no engine copy.
    static func refresh(engine: InstalledEngine, d3dmetal: D3DMetalInstall?) throws {
        try writeGeneratedFiles(into: root, engine: engine, d3dmetal: d3dmetal)
        // Before staging: NotProton compares the runner's ntdll with the staged copy.
        RendererPatches.applyExeDecidesDEP(wineLib: root.appendingPathComponent("lib/wine", isDirectory: true), log: nil)
        try stageBridgeNtdll()
        try writeToolList()
    }

    private static func writeGeneratedFiles(into run: URL, engine: InstalledEngine, d3dmetal: D3DMetalInstall?) throws {
        let fm = FileManager.default
        try Paths.ensure(run.appendingPathComponent("decant"))
        try engineEnv(engine).write(to: run.appendingPathComponent("decant/engine.env"), atomically: true, encoding: .utf8)
        let loader = run.appendingPathComponent("lib/wine/x86_64-unix/wine")
        let server = run.appendingPathComponent("bin/wineserver")
        try loaderWrapper(runner: root).write(to: loader, atomically: true, encoding: .utf8)
        try serverWrapper(runner: root).write(to: server, atomically: true, encoding: .utf8)
        for wrapper in [loader, server] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path) }

        // Apple's D3DMetal where CrossOver keeps it: the launch script then sets
        // CX_APPLEGPTK_LIBD3DSHARED_PATH, which also sets up Rosetta's fast thread state.
        let link = run.appendingPathComponent("lib64/apple_gptk")
        try? fm.removeItem(at: link)
        if let d3dmetal {
            try Paths.ensure(link.deletingLastPathComponent())
            try fm.createSymbolicLink(at: link, withDestinationURL: d3dmetal.root.appendingPathComponent("lib"))
        }
        let record = Record(engineFolder: engine.folder, format: format, d3dmetalFolder: d3dmetal?.folder,
                            supportPath: Paths.support.path)
        try JSONEncoder().encode(record).write(to: run.appendingPathComponent("decant/runner.json"), options: .atomic)
    }

    /// NotProton's script compares the runner's ntdll with this staged copy (it only logs on mismatch).
    private static func stageBridgeNtdll() throws {
        let fm = FileManager.default
        for arch in ["x86_64-windows", "i386-windows"] {
            let staged = SteamPlayPaths.bridge.appendingPathComponent("wine/\(build)/\(arch)/ntdll.dll")
            try Paths.ensure(staged.deletingLastPathComponent())
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: root.appendingPathComponent("lib/wine/\(arch)/ntdll.dll"), to: staged)
        }
    }

    /// Lists Unwine's tool for the Steam add-on (read at Steam start) and keeps the tool
    /// folder's own `build` file in step, so the next game launch uses this runner.
    static func writeToolList() throws {
        let line = "\(toolName)\t\(build)\trosetta\t\(toolDisplay)\n"
        var lines = ((try? String(contentsOf: SteamPlayPaths.toolList, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix(toolName + "\t") && !$0.isEmpty }
        lines.insert(String(line.dropLast()), at: 0)
        try (lines.joined(separator: "\n") + "\n").write(to: SteamPlayPaths.toolList, atomically: true, encoding: .utf8)
        let toolDir = SteamPlayPaths.compatTools.appendingPathComponent(toolName)
        if FileManager.default.fileExists(atPath: toolDir.path) {
            try (build + "\n").write(to: toolDir.appendingPathComponent("build"), atomically: true, encoding: .utf8)
        }
    }

    /// Removes runners from Unwine builds before the fixed build name.
    static func pruneOldRunners() {
        let items = (try? FileManager.default.contentsOfDirectory(at: SteamPlayPaths.runners, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("crossover-decant-") && item.lastPathComponent != "crossover-\(build)" {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Generated files

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func engineEnv(_ engine: InstalledEngine) -> String {
        let fw = engine.frameworks.path
        let vk = RendererPatches.vulkanICD(engine: engine)
        var lines = ["# Written by Unwine. The free engine's support libraries and Vulkan driver."]
        for (k, v) in engine.markerEnv.sorted(by: { $0.key < $1.key }) { lines.append("export \(k)=\(shellQuote(v))") }
        lines += [
            "export DYLD_FALLBACK_LIBRARY_PATH=\(shellQuote("\(fw):\(fw)/GStreamer.framework/Versions/1.0/lib:/usr/lib"))",
            "export DYLD_FALLBACK_FRAMEWORK_PATH=\(shellQuote(fw))",
            "export GST_PLUGIN_PATH=\(shellQuote("\(fw)/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"))",
            "export VK_DRIVER_FILES=\(shellQuote(vk.path))",
            "export VK_ICD_FILENAMES=\(shellQuote(vk.path))",
            // Quiet logs. A game's profile can ask for Detailed logs, and the wrappers keep a level
            // that Steam's launch options set.
            "export WINEDEBUG=\(shellQuote(WineEnvironment.quietDebug))",
            "export DXVK_LOG_LEVEL=\(shellQuote(WineEnvironment.quietLayerLog))",
            "export DXMT_LOG_LEVEL=\(shellQuote(WineEnvironment.quietLayerLog))",
            "DECANT_RENDERERS=\(shellQuote(engine.rendererRoot.path))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// NotProton's run script exports WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}", so the wrappers see
    /// this value when Steam's launch options set none. It is NotProton's default, not the user's choice.
    static let notProtonDebug = "err+all,fixme-all"

    /// Before engine.env: the log levels the game was started with. Steam passes the ones its launch
    /// options set (WINEDEBUG, DXVK_*, DXMT_*), and those win over Unwine's. NotProton's default does not count.
    static let keepAskedLogs = """
        asked_winedebug="${WINEDEBUG:-}" asked_dxvk_log="${DXVK_LOG_LEVEL:-}" asked_dxmt_log="${DXMT_LOG_LEVEL:-}"
        """

    /// After the profile: puts the asked levels back. A process the game starts gets the levels its
    /// parent ran with, so every process of the game agrees.
    static let restoreAskedLogs = """
        case "$asked_winedebug" in ''|\(shellQuote(notProtonDebug))) ;; *) export WINEDEBUG="$asked_winedebug" ;; esac
        [ -z "$asked_dxvk_log" ] || export DXVK_LOG_LEVEL="$asked_dxvk_log"
        [ -z "$asked_dxmt_log" ] || export DXMT_LOG_LEVEL="$asked_dxmt_log"
        """

    /// After the profile: making a bottle runs without Faster x87 math. NotProton runs `wine wineboot --init`
    /// to make a bottle (the template new games copy, or a game's own bottle), and x87sidecar would attach to
    /// wineboot and to the programs it starts: macOS could then ask for the password while only a bottle is
    /// made. Wine starts those programs through this wrapper too, with the game's profile, so a mark that
    /// they inherit keeps it off for them. The game starts from NotProton, without the mark.
    /// NotProton also runs `wine reg import` at every start; when the bottle is not there yet, Wine makes
    /// it from inside that reg.exe, so reg counts as making a bottle too.
    static let bootWithoutX87 = """
        case "${1:-}" in
          wineboot|wineboot.exe|*/wineboot|*/wineboot.exe|*'\\'wineboot|*'\\'wineboot.exe) DECANT_NO_X87=1 ;;
          reg|reg.exe|*/reg|*/reg.exe|*'\\'reg|*'\\'reg.exe) DECANT_NO_X87=1 ;;
        esac
        if [ -n "${DECANT_NO_X87:-}" ]; then
          unset -v ROSETTA_X87_PATH WINEARCH X87_PRECISE_FAULTS
          export DECANT_NO_X87
        fi
        """

    /// The wrapper's last step. With Faster x87 math, Wine would start x87sidecar with the loader it
    /// means to run next: this wrapper, a shell script. x87sidecar cannot attach to a script (sh then
    /// stops on a trap), so the wrapper starts x87sidecar itself, with the real loader, and Wine never
    /// sees ROSETTA_X87_PATH. Each process Wine starts comes back through the wrapper, which reads the
    /// profile and puts x87sidecar back. The real loader does not start itself again (its preloader is
    /// built in), so x87sidecar attaches once per process.
    static let startX87 = """
        if [ -n "${ROSETTA_X87_PATH:-}" ]; then
          x87="$ROSETTA_X87_PATH"
          unset -v ROSETTA_X87_PATH
          if [ -x "$x87" ]; then exec "$x87" "$real" "$@"; fi
        fi
        """

    static func profileSourcing() -> String {
        """
        profiles=\(shellQuote(profiles.path))
        app=""
        case "${STEAM_COMPAT_DATA_PATH:-}" in */compatdata/*) app="${STEAM_COMPAT_DATA_PATH##*/}" ;; esac
        if [ -n "$app" ] && [ -r "$profiles/$app.env" ]; then . "$profiles/$app.env"
        elif [ -r "$profiles/default.env" ]; then . "$profiles/default.env"
        fi
        """
    }

    static func loaderWrapper(runner: URL) -> String {
        """
        #!/bin/sh
        # Unwine: give every Wine process the free engine's settings and this game's profile, then run Wine.
        # NotProton hard-links this file into a per-game app bundle (for macOS Game Mode), so paths are absolute.
        DECANT_RUNNER=\(shellQuote(runner.path))
        \(keepAskedLogs)
        . "$DECANT_RUNNER/decant/engine.env"
        \(profileSourcing())
        \(restoreAskedLogs)
        \(bootWithoutX87)
        # /bin/sh drops DYLD_* on entry, so restore the Steam overlay the game launcher asked for.
        if [ -n "${NOTPROTON_GAME_CWD:-}" ] && [ -n "${STEAM_DYLD_INSERT_LIBRARIES:-}" ]; then
          if [ -n "${NOTPROTON_OVERLAY_SHIM:-}" ] && [ -f "$NOTPROTON_OVERLAY_SHIM" ]; then
            export DYLD_INSERT_LIBRARIES="$NOTPROTON_OVERLAY_SHIM:$STEAM_DYLD_INSERT_LIBRARIES"
          else
            export DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES"
          fi
        fi
        real_src="$DECANT_RUNNER/lib/wine/x86_64-unix/wine.decant-real"
        here="${0%/*}"
        real="$here/wine.decant-real"
        # Inside a per-game app bundle (made so macOS turns on Game Mode). macOS counts a process as
        # the game only when its executable is a real file inside the bundle, so the Wine loader is
        # cloned in. A clone, not a hard link: a hard-linked program can report its other path, and
        # then macOS no longer sees the game. Everything else stays a symlink: Wine finds its own
        # files through them. The bundle must also say it supports Game Mode. Both are fixed once
        # per bundle; later processes skip this quickly.
        if [ "$here" != "$DECANT_RUNNER/lib/wine/x86_64-unix" ]; then
          if [ -L "$real" ] || [ ! -e "$real" ]; then
            /bin/cp -c -p "$real_src" "$real.$$" 2>/dev/null && mv -f "$real.$$" "$real" || rm -f "$real.$$"
          fi
          plist="${here%/MacOS}/Info.plist"
          if [ -f "$plist" ] && ! /usr/bin/grep -q LSSupportsGameMode "$plist"; then
            /usr/bin/plutil -replace LSSupportsGameMode -bool YES "$plist" 2>/dev/null
            /usr/bin/plutil -replace GCSupportsGameMode -bool YES "$plist" 2>/dev/null
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${here%/Contents/MacOS}" >/dev/null 2>&1
          fi
        fi
        # Wine starts each process a game starts (the game behind a launcher, its helpers) from the
        # runner's loader, outside the game's bundle, so macOS never sees them as the game. When the
        # game was started from its bundle, WINELOADER still names it: run that bundle's copy.
        if [ "$here" = "$DECANT_RUNNER/lib/wine/x86_64-unix" ]; then
          case "${WINELOADER:-}" in
            */notproton/launchers/*.app/Contents/MacOS/wine)
              bundled="${WINELOADER%/*}/wine.decant-real"
              if [ -f "$bundled" ] && [ ! -L "$bundled" ] && [ -x "$bundled" ]; then real="$bundled"; fi ;;
          esac
        fi
        [ -x "$real" ] || real="$real_src"
        \(startX87)
        exec "$real" "$@"

        """
    }

    static func serverWrapper(runner: URL) -> String {
        """
        #!/bin/sh
        # Unwine: wineserver needs the engine's support libraries and the same sync mode as the game.
        DECANT_RUNNER=\(shellQuote(runner.path))
        \(keepAskedLogs)
        . "$DECANT_RUNNER/decant/engine.env"
        \(profileSourcing())
        \(restoreAskedLogs)
        exec "$DECANT_RUNNER/bin/wineserver.decant-real" "$@"

        """
    }
}
