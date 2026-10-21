import Darwin
import Foundation

/// Faster x87 math. x87sidecar (github.com/athei/x87sidecar, MIT licence, Copyright (c) 2025
/// Lifeisawful, later work by athei) hooks Apple's Rosetta, so x87 floating-point code runs much
/// faster. Old 32-bit games use a lot of it. x87sidecar does that math in 64-bit doubles, not in 80-bit
/// numbers, so a few programs behave differently: it is a switch per game, off at the start.
///
/// The engine's ntdll.so (Sikarugir Wine 11.0) has the older hook: when Wine starts its loader, it
/// runs the program in ROSETTA_X87_PATH instead, with the loader's path and Wine's own arguments. It
/// has no x87sidecar handshake (no X87_SIDECAR_BOOTSTRAP), so the plain build would refuse to attach.
/// The "entitled" build attaches by itself (macOS asks once per login session to allow it Developer
/// Tools access).
///
/// For a 32-bit program the hook first names a 32-bit loader (lib/wine/i386-unix/wine). This engine
/// has none: it runs 32-bit programs inside the 64-bit loader (WoW64). Without x87sidecar, Wine's
/// start of that missing file fails and Wine takes the 64-bit loader. With it, x87sidecar starts
/// instead, cannot start the missing file, and the program ends with status 1. WINEARCH=wow64 makes
/// Wine skip the 32-bit loader, so x87sidecar gets the 64-bit one.
///
/// Wine uses the hook only when it starts a loader: for each process a game starts, but not for the
/// game's first process, whose loader does not start itself again. So whoever starts the game starts
/// x87sidecar too: Unwine for an added game (LocalGames), the runner's loader wrapper for a Steam game
/// (Runner.startX87). That wrapper is a shell script, and x87sidecar cannot attach to a script, so it
/// also keeps ROSETTA_X87_PATH from Wine. Measured on 21 Oct 2026 (macOS 27.0.1, x87sidecar 1.9.0): a
/// 32-bit "hello", a DXMT window and a 32-bit program that starts another all ran, both ways, and an
/// x87 loop took 0.57 s, not 16 s.
///
/// x87sidecar does that math in 64-bit doubles. At the 53-bit precision Windows programs run at, the
/// loop gave the same result to the last digit. A program that asks for 64-bit precision (the
/// mingw default) gets slightly different results: that is why it is a switch per game.
enum X87Sidecar {
    static let version = "1.9.0"
    static let url = URL(string: "https://github.com/athei/x87sidecar/releases/download/v1.9.0/x87sidecar_entitled.tar.xz")!
    static let size: Int64 = 181_208
    static let sha256 = "4eed9abeeb06a75daed3935980bf849554ab964c6fe2489a5be2efb846711704"
    static let page = URL(string: "https://github.com/athei/x87sidecar")!
    static let program = "x87sidecar_entitled"

    static var tools: URL { Paths.support.appendingPathComponent("Tools", isDirectory: true) }
    static var folder: URL { tools.appendingPathComponent("x87sidecar-\(version)", isDirectory: true) }
    static var binary: URL { folder.appendingPathComponent(program) }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }
    static var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// x87sidecar prints a banner with this on stderr when it cannot hook Rosetta. The game then runs without it.
    static let notRunningMarker = "RUNNING WITHOUT X87 ACCELERATION"
    /// The last words of a game that needs exact x87 faults (X87_PRECISE_FAULTS=1).
    static let faultMarker = "unexpectedly need to EmulateForward on a synchronous exception"

    /// The macOS build, such as "25A354". It changes with each macOS update, and so can Rosetta.
    static let macOSBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: Profile

    /// The profile lines for Faster x87 math (see `Profiles.render`). `AppModel.profileSettings` already
    /// turned `x87` off where it cannot work: a 64-bit game, no passing check on this macOS, no hook.
    /// WINEARCH=wow64 makes Wine give x87sidecar the 64-bit loader, which runs 32-bit programs on this
    /// engine (see above). Wine reads it nowhere else in a bottle that exists.
    static func exports(_ s: GameSettings) -> [(String, String)] {
        guard s.x87, isInstalled else { return [] }
        return [("ROSETTA_X87_PATH", binary.path), ("WINEARCH", "wow64")] + (s.x87PreciseFaults ? [("X87_PRECISE_FAULTS", "1")] : [])
    }

    /// Every name `exports` can set. Making a bottle runs without them (LocalGames.withoutX87).
    static let variables: Set<String> = ["ROSETTA_X87_PATH", "WINEARCH", "X87_PRECISE_FAULTS"]

    /// True when this engine's Wine has the x87 hook (ROSETTA_X87_PATH in its ntdll.so) and runs 32-bit
    /// programs in its 64-bit loader only (no lib/wine/i386-unix/wine). Only there does WINEARCH=wow64
    /// change nothing but the loader x87sidecar gets. Read once per engine.
    @MainActor static func engineHasHook(_ engine: InstalledEngine) -> Bool {
        if let known = hooks[engine.folder] { return known }
        let lib = engine.wineDir.appendingPathComponent("lib/wine", isDirectory: true)
        let ntdll = lib.appendingPathComponent("x86_64-unix/ntdll.so")
        let found = (try? Data(contentsOf: ntdll, options: .alwaysMapped))?.range(of: Data("ROSETTA_X87_PATH\0".utf8)) != nil
            && !FileManager.default.fileExists(atPath: lib.appendingPathComponent("i386-unix/wine").path)
        hooks[engine.folder] = found
        return found
    }

    @MainActor private static var hooks: [String: Bool] = [:]

    // MARK: Install and check

    enum Phase: Sendable {
        case downloading(Double?)       // nil: the download is in, and its SHA-256 is being checked
        case unpacking
    }

    /// Downloads the pinned release, checks its SHA-256 and unpacks its one program into `folder`.
    static func install(log: LogFile, phase: @escaping @Sendable (Phase) -> Void) async throws {
        let fm = FileManager.default
        try Paths.ensure(tools)
        // A quit during an earlier install leaves its stage behind, and an older pinned version is never used again.
        for item in (try? fm.contentsOfDirectory(at: tools, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            if name.hasPrefix(".x87sidecar-stage-") || (name.hasPrefix("x87sidecar-") && name != folder.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
        }
        let stage = tools.appendingPathComponent(".x87sidecar-stage-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensure(stage)
        defer { try? fm.removeItem(at: stage) }

        log.line("Downloading \(url.absoluteString)")
        phase(.downloading(0))
        let archive = try await Downloader.fetch(url, to: stage.appendingPathComponent(url.lastPathComponent),
                                                 expectedBytes: size, sha256: sha256) { phase(.downloading($0)) }
        phase(.unpacking)
        // The checksum pins the archive. Its paths are still checked: nothing may land outside the stage.
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let entries = try await Shell.run(tar, ["-tf", archive.path]).output.split(whereSeparator: \.isNewline)
        guard !entries.contains(where: { $0.hasPrefix("/") || $0.contains("../") }),
              entries.contains(where: { $0.split(separator: "/").last.map(String.init) == program }) else { throw X87SidecarError.layout }
        let unpacked = try Paths.ensure(stage.appendingPathComponent("unpacked", isDirectory: true))
        try await Shell.run(tar, ["-xf", archive.path, "-C", unpacked.path, "--no-xattrs", "--no-mac-metadata"], log: log)
        guard let file = unpackedProgram(in: unpacked) else { throw X87SidecarError.layout }
        // Downloads can carry macOS's quarantine mark, and Wine starts this program for each 32-bit process.
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", file.path], check: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try? fm.removeItem(at: folder)
        try Paths.ensure(folder)
        try fm.moveItem(at: file, to: binary)
        log.line("x87sidecar \(version) is in \(folder.path)")
    }

    /// The program in the unpacked archive, at any depth. Only a plain file counts, never a link.
    private static func unpackedProgram(in dir: URL) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return nil }
        for case let url as URL in walk where url.lastPathComponent == program {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true && v?.isSymbolicLink != true { return url }
        }
        return nil
    }

    /// Runs `x87sidecar_entitled --probe`. Exit 0 means it supports the Rosetta on this Mac.
    static func probe(log: LogFile) async throws -> X87Probe {
        let result: Run
        do {
            result = try await run(binary, ["--probe"], timeout: 60)
        } catch {
            // A copy that cannot start is no use: the next try downloads a fresh one.
            try? FileManager.default.removeItem(at: folder)
            throw X87SidecarError.couldNotStart(error.localizedDescription)
        }
        if result.timedOut { throw X87SidecarError.timedOut }
        let said = lastLine(of: result.output)
        // A stop by a signal is no answer about Rosetta: macOS, or a crash, stopped the program.
        if result.signaled {
            log.line("x87sidecar --probe stopped with signal \(result.status)\(said.isEmpty ? "" : ": \(said)")")
            try? FileManager.default.removeItem(at: folder)
            throw X87SidecarError.couldNotStart("macOS stopped it")
        }
        log.line("x87sidecar --probe on macOS \(macOSVersion) (\(macOSBuild)) ended with status \(result.status)\(said.isEmpty ? "" : ": \(said)")")
        return X87Probe(passed: result.status == 0, macOSBuild: macOSBuild, macOSVersion: macOSVersion,
                        sidecarVersion: version, said: said, checkedAt: Date())
    }

    private struct Run {
        var status: Int32
        var signaled: Bool
        var output: String
        var timedOut: Bool
    }

    /// Runs a short program to its end, off the main thread. Stops it after `timeout` seconds.
    private static func run(_ exe: URL, _ args: [String], timeout: Double) async throws -> Run {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let out = Collected()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { out.add(data) }
        }
        let box = ProcessBox(process)
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard box.process.isRunning else { return }
                out.timedOut = true
                box.process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { out.add(rest) }
        return Run(status: status, signaled: process.terminationReason == .uncaughtSignal, output: out.text, timedOut: out.timedOut)
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var stopped = false

        func add(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > 128_000 { data = data.suffix(64_000) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data.suffix(64_000), as: UTF8.self) }
        var timedOut: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stopped }
            set { lock.lock(); stopped = newValue; lock.unlock() }
        }
    }

    /// What went wrong while Unwine got x87sidecar ready, in plain words, with the next step.
    static func explain(_ error: Error) -> String {
        if let e = error as? DownloadError {
            switch e {
            case .offline: return "This Mac is not online. Connect to the internet, then try again."
            case .http(let code, _): return "GitHub did not send x87sidecar (error \(code)). Try again later. If it fails again, an Unwine update can fix it."
            case .checksum: return "The download did not match x87sidecar \(version), so Unwine did not use it. Try again."
            }
        }
        if let e = error as? X87SidecarError { return e.localizedDescription }
        return "Unwine could not get x87sidecar ready: \(error.localizedDescription) Try again."
    }

    // MARK: What the last session said

    /// What x87sidecar said in a game's last session, from the end of its run and Wine logs, newest
    /// first. `games` are the game and the launchers that start it with its settings: what the game
    /// prints lands in the log of the program that started it. Only the last `bytes` of each file are
    /// read, so this stays cheap.
    static func lastSession(of games: [SteamGame], bytes: Int) -> X87Session {
        var session = X87Session()
        // An added game's log and a Steam game's run log hold many sessions: only the part after the
        // last start counts. A Steam game's Wine log starts fresh at each start.
        var logs: [(url: URL, date: Date, start: String)] = []
        for game in games {
            let start = game.localExe.map { "Starting \($0.path) from " } ?? "=== notproton run "
            for url in [game.runLog, game.wineLog] {
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                logs.append((url, date, start))
            }
        }
        for log in logs.sorted(by: { $0.date > $1.date }) {
            guard var text = tail(log.url, bytes: bytes), !text.isEmpty else { continue }
            if let r = text.range(of: log.start, options: .backwards) { text = String(text[r.lowerBound...]) }
            if text.range(of: faultMarker, options: .caseInsensitive) != nil { session.hitFault = true }
            if session.notAttached == nil, let why = reason(in: text) {
                session.notAttached = why
                session.log = log.url
            }
        }
        return session
    }

    /// The last `bytes` of a file as text, or nil when there is no file.
    private static func tail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Why x87sidecar could not hook Rosetta, from the last banner it printed in `text`: nil when there
    /// is no banner, "" when the banner gives no reason. Words after the marker on its own line come
    /// first, then the banner's lines below and above it. A line that names a cause wins.
    static func reason(in text: String) -> String? {
        guard let hit = text.range(of: notRunningMarker, options: [.backwards, .caseInsensitive]) else { return nil }
        // Split on any line end: "\r\n" is one Character, so splitting on "\n" alone would miss it.
        let below = text[hit.upperBound...].prefix(4_000).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let above = text[..<hit.lowerBound].suffix(2_000).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var near: [Substring] = [below.first ?? ""]
        near += bannerLines(below.dropFirst().prefix(10))
        near += bannerLines(above.dropLast().suffix(5).reversed())      // the last one is the marker's own line
        let lines = near.map(clean).filter { $0.filter(\.isLetter).count >= 3 && $0.range(of: notRunningMarker, options: .caseInsensitive) == nil }
        let causes = ["because", "reason", "fail", "denied", "not ", "unsupported", "cannot", "can't", "could not", "unable",
                      "error", "missing", "permission", "refused", "unknown"]
        let pick = lines.first(where: { l in causes.contains { l.lowercased().contains($0) } }) ?? lines.first ?? ""
        return pick.count > 180 ? String(pick.prefix(180)) + "…" : pick
    }

    /// The lines of a banner in reading order away from the marker. Stops at Wine's own output or after
    /// two blank lines.
    private static func bannerLines<S: Sequence>(_ lines: S) -> [Substring] where S.Element == Substring {
        var out: [Substring] = []
        var blanks = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { blanks += 1; if blanks == 2 { break }; continue }
            if isWineOutput(t) { break }
            out.append(line)
        }
        return out
    }

    /// A line Wine printed itself, such as "0024:err:module:import_dll ...".
    private static func isWineOutput(_ line: String) -> Bool {
        let parts = line.split(separator: ":", maxSplits: 2)
        return parts.count == 3 && parts[0].count <= 8 && parts[0].allSatisfy(\.isHexDigit)
            && ["err", "fixme", "warn", "trace"].contains(String(parts[1]))
    }

    /// The last line of a program's output that says something, at a readable length.
    static func lastLine(of output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).map(clean).last { $0.filter(\.isLetter).count >= 3 } ?? ""
        return line.count > 180 ? String(line.prefix(180)) + "…" : line
    }

    /// A banner line without its frame (=, *, #, ! and the like) and without a lead-in such as
    /// "x87sidecar:" or "Reason:".
    private static func clean(_ line: Substring) -> String {
        let lead = CharacterSet(charactersIn: "=*#!|-_~<>[({:;,.").union(.whitespacesAndNewlines)
        let end = CharacterSet(charactersIn: "=*#!|-_~<>:;,.").union(.whitespacesAndNewlines)
        var t = line.trimmingCharacters(in: lead).trimmingCharacters(in: end)
        for _ in 0..<3 {
            let lower = t.lowercased()
            guard let word = ["x87sidecar_entitled", "x87sidecar", "reason", "error", "warning", "why"].first(where: {
                lower.hasPrefix($0) && !(lower.dropFirst($0.count).first?.isLetter ?? false)
            }) else { break }
            t = String(t.dropFirst(word.count)).trimmingCharacters(in: lead).trimmingCharacters(in: end)
        }
        // A bracket opened in the trimmed frame leaves its partner behind.
        for (open, close) in [("(", ")"), ("[", "]")] {
            while t.hasSuffix(close), t.filter({ String($0) == close }).count > t.filter({ String($0) == open }).count { t.removeLast() }
        }
        return t
    }
}

/// What `x87sidecar_entitled --probe` said, and on which macOS. A macOS update can bring a new Rosetta,
/// so the answer counts only for the build it was given on, and only for this x87sidecar.
struct X87Probe: Codable, Equatable, Sendable {
    var passed: Bool
    var macOSBuild: String              // "25A354"
    var macOSVersion: String            // "26.0.1", for the game's page
    var sidecarVersion: String
    var said: String                    // x87sidecar's last line of output
    var checkedAt: Date

    var isCurrent: Bool { macOSBuild == X87Sidecar.macOSBuild && sidecarVersion == X87Sidecar.version }
}

/// What a game's last session says about Faster x87 math.
struct X87Session: Equatable, Sendable {
    var notAttached: String?            // x87sidecar's reason when it ran without acceleration ("" when it gave none)
    var log: URL?                       // the log that says so
    var hitFault = false                // the game stopped on an x87 fault that needs X87_PRECISE_FAULTS=1
}

/// x87sidecar being downloaded or checked, or why that failed. `gameID` is the game whose page started
/// it; nil when Unwine checks again by itself after a macOS update.
struct X87Task: Equatable {
    var gameID: Int?
    var status: StepStatus
}

enum X87SidecarError: LocalizedError {
    case layout
    case couldNotStart(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .layout: return "The download did not hold x87sidecar's program, so Unwine did not use it. An Unwine update can fix this."
        case .couldNotStart(let why): return "x87sidecar did not start (\(why)). Try again: Unwine then downloads a fresh copy."
        case .timedOut: return "x87sidecar's check did not finish in a minute. Try again."
        }
    }
}

// MARK: - Faster x87 math in the app model

extension AppModel {
    /// Faster x87 math can work on this Mac now: x87sidecar is here, it passed its check on this macOS
    /// build, and the engine's Wine has the x87 hook.
    var x87Ready: Bool {
        guard let engine, X87Sidecar.isInstalled, let probe = stored.x87Probe, probe.isCurrent, probe.passed else { return false }
        return X87Sidecar.engineHasHook(engine)
    }

    /// Why Faster x87 math cannot work on this Mac now, with the next step, or nil when it can
    /// (x87sidecar may still need a download or a check first).
    var x87Blocker: String? {
        guard let engine else { return "Finish Unwine's setup first." }
        if !X87Sidecar.engineHasHook(engine) {
            return "Unwine's engine has no x87 hook that Unwine can use (the part of Wine that starts x87sidecar), so x87sidecar cannot attach to games. An Unwine update can fix this."
        }
        if let p = stored.x87Probe, p.isCurrent, !p.passed {
            return "x87sidecar \(p.sidecarVersion) does not support the Rosetta in macOS \(p.macOSVersion) yet."
                + (p.said.isEmpty ? "" : " It said: \(p.said)\(p.said.hasSuffix("…") ? "" : ".")")
                + " An Unwine update with a newer x87sidecar can fix this."
        }
        return nil
    }

    /// The settings a game's profile is written from: the user's, with Faster x87 math only where it
    /// can work (a 32-bit game, and `x87Ready`). A game whose last session stopped on an x87 fault
    /// gets precise x87 faults from then on: without them it stops at the same place again.
    func profileSettings(for id: Int) -> GameSettings {
        var s = settings(for: id)
        guard s.x87 else { return s }
        // A macOS update can bring a new Rosetta. x87sidecar checks it again, once; until it passes,
        // the game starts without it.
        if X87Sidecar.isInstalled, stored.x87Probe?.isCurrent != true, !x87Rechecked {
            x87Rechecked = true
            Task { await recheckX87() }
        }
        // A Steam Play runner from an older Unwine, still in use, would stop the game (Runner.startsX87).
        guard stored.analyses[id]?.is64Bit == false, x87Ready, Runner.startsX87 else { s.x87 = false; return s }
        if !s.x87PreciseFaults, X87Sidecar.lastSession(of: x87Games(for: id), bytes: 64_000).hitFault, noteX87Fault(id) {
            s.x87PreciseFaults = true
        }
        return s
    }

    /// Turns Faster x87 math on for one game. Gets x87sidecar first when it is missing, and runs its
    /// check of Rosetta when none ran on this macOS build (or always, with `again`). When the check
    /// fails or the engine has no x87 hook, the switch stays as it was and the game's page says why.
    /// The page asks before the first download.
    func enableX87(for id: Int, again: Bool = false) async {
        guard x87Task?.status.isRunning != true else { return }
        guard await prepareX87(for: id, again: again), let engine, X87Sidecar.engineHasHook(engine) else { return }
        if settings(for: id).x87 { writeProfile(for: id) } else { update(id) { $0.x87 = true } }
    }

    /// Turns Faster x87 math off for one game. A failed try to get x87sidecar for it goes too.
    func disableX87(for id: Int) {
        update(id) { $0.x87 = false }
        if x87Task?.gameID == id, x87Task?.status.isRunning == false { x87Task = nil }
    }

    /// What the game's last session says about Faster x87 math, read from the end of its logs, off the
    /// main thread. A stop on an x87 fault turns on precise x87 faults for the next start.
    func x87Session(for id: Int) async -> X87Session {
        let logs = x87Games(for: id)
        let session = await Task.detached(priority: .utility) { X87Sidecar.lastSession(of: logs, bytes: 64_000) }.value
        if session.hitFault, noteX87Fault(id) { writeProfile(for: id) }
        return session
    }

    /// The game, and the added launchers that start it with its settings.
    private func x87Games(for id: Int) -> [SteamGame] {
        games.filter { $0.id == id || settingsSource(for: $0)?.id == id }
    }

    /// Remembers that a game needs precise x87 faults. True when that is new.
    private func noteX87Fault(_ id: Int) -> Bool {
        guard stored.games[id]?.x87 == true, stored.games[id]?.x87PreciseFaults == false else { return false }
        stored.games[id]?.x87PreciseFaults = true
        save()
        let name = games.first { $0.id == id }?.name ?? "Game \(id)"
        log.line("\(name) stopped on an x87 fault, so it starts with X87_PRECISE_FAULTS=1 from now on")
        return true
    }

    /// Gets x87sidecar ready: downloads it when it is missing, then runs its check of Rosetta when none
    /// ran on this macOS build (or always, with `again`). `x87Task` shows each step and keeps the
    /// reason when a step fails. True when the check passed.
    private func prepareX87(for id: Int?, again: Bool,
                            checking: [String] = ["Checking x87sidecar with this Mac's Rosetta…", "This takes a few seconds"]) async -> Bool {
        do {
            if !X87Sidecar.isInstalled {
                let steps = [["Downloading x87sidecar (\(X87Sidecar.sizeText))…"], ["Checking the download…"], ["Unpacking x87sidecar…"]]
                x87Task = X87Task(gameID: id, status: .running(0, steps[0]))
                try await X87Sidecar.install(log: log) { phase in
                    Task { @MainActor in
                        // Progress can arrive late: a step never goes back.
                        guard case .running(_, let shown)? = self.x87Task?.status, let at = steps.firstIndex(of: shown) else { return }
                        let (step, progress): (Int, Double?) = switch phase {
                        case .downloading(let p?): (0, p)
                        case .downloading(nil): (1, nil)
                        case .unpacking: (2, nil)
                        }
                        if step >= at { self.x87Task?.status = .running(progress, steps[step]) }
                    }
                }
            }
            if again || stored.x87Probe?.isCurrent != true {
                x87Task = X87Task(gameID: id, status: .running(nil, checking))
                stored.x87Probe = try await X87Sidecar.probe(log: log)
                save()
            }
            x87Task = nil
            return stored.x87Probe?.passed == true
        } catch {
            x87Task = X87Task(gameID: id, status: .failed(X87Sidecar.explain(error)))
            log.line("x87sidecar setup failed: \(error)")
            return false
        }
    }

    /// x87sidecar's check of Rosetta again, after a macOS update. It never downloads anything. The
    /// games that use Faster x87 math get their profiles written again with the answer.
    private func recheckX87() async {
        guard X87Sidecar.isInstalled, x87Task?.status.isRunning != true else { return }
        _ = await prepareX87(for: nil, again: false, checking: ["macOS changed, so Unwine checks x87sidecar again…", "This takes a few seconds"])
        for (id, s) in stored.games where s.x87 { writeProfile(for: id) }
    }
}
