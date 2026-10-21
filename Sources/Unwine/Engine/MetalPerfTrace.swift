import Darwin
import Foundation

/// macOS 27 records the frame times of every Metal layer all the time, with no setting and no
/// environment variable, and `/usr/bin/metalperftrace` reads them back. Games in Wine show up as
/// processes named "wine", so Unwine finds a game's numbers by the process ids it saw in its bottle.
enum MetalPerfTrace {
    static let tool = URL(fileURLWithPath: "/usr/bin/metalperftrace")
    static let isMacOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    /// Older macOS keeps no such record, so Unwine shows no session numbers there.
    static let isAvailable = isMacOS27 && FileManager.default.isExecutableFile(atPath: tool.path)

    /// What one process put on the screen, summed over its Metal layers. Only frames that reached
    /// the screen count, as in Apple's own overview: while a game's window is hidden, macOS marks its
    /// frames "skipped", and those say nothing about how the game looked.
    struct Frames: Sendable {
        var glassMs = 0.0, glassFrames = 0.0    // time between frames on the screen, and how many
        var gpuMs = 0.0, gpuFrames = 0.0        // GPU time of those frames
        var shaderSeconds = 0.0                 // time spent building new shaders

        var seconds: Double { glassMs / 1000 }
        var fps: Double { glassMs > 0 ? 1000 * glassFrames / glassMs : 0 }
        var gpuPerFrame: Double { gpuFrames > 0 ? gpuMs / gpuFrames : 0 }
    }

    /// The frames of each of these processes between two dates. Nil when the tool fails or prints
    /// something Unwine cannot read; the reason goes to `log` in one line.
    static func frames(of pids: Set<pid_t>, from start: Date, to end: Date, log: LogFile) async -> [pid_t: Frames]? {
        guard !pids.isEmpty else { return [:] }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("unwine-metalperftrace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        // The record holds every app's frames, so it stays in a temporary folder that goes away at once.
        // Dates in the future are refused, and very long sessions keep their last six hours.
        let to = min(end, Date()).addingTimeInterval(-1)
        let from = max(start.addingTimeInterval(-10), to.addingTimeInterval(-6 * 3600))
        guard await run(["collect", "--start", "@\(Int(from.timeIntervalSince1970))", "--end", "@\(Int(to.timeIntervalSince1970))", dir.path]) else {
            log.line("Session numbers: metalperftrace collect failed, so this session has none")
            return nil
        }
        let traces = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "atrc" }
        let predicate = "pid IN {" + pids.sorted().map(String.init).joined(separator: ", ") + "}"
        var result: [pid_t: Frames] = [:]
        for trace in traces {
            let json = trace.appendingPathExtension("json")
            guard await run(["overview", "--json", "--predicate", predicate, trace.path], output: json),
                  let data = try? Data(contentsOf: json) else {
                log.line("Session numbers: metalperftrace overview failed, so this session has none")
                return nil
            }
            guard let processes = try? JSONDecoder().decode([Entry].self, from: data) else {
                // A stretch with no Metal frames at all comes back as {"error": "No session found"}.
                if String(decoding: data.prefix(300), as: UTF8.self).contains("No session found") { continue }
                log.line("Session numbers: metalperftrace printed something Unwine cannot read (\(data.count) bytes)")
                return nil
            }
            // The filter picks layers, but every process stays listed, so pick the processes too.
            for p in processes {
                guard let pid = pid_t(exactly: p.pid), pids.contains(pid) else { continue }
                for layer in p.layers ?? [] { result[pid, default: Frames()].add(layer.stats) }
            }
        }
        return result
    }

    /// Runs the tool, with what it prints in `output` (an overview runs to megabytes, too much for a
    /// pipe buffer). Gives up after two minutes.
    private static func run(_ args: [String], output: URL? = nil) async -> Bool {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        var file: FileHandle?
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            file = try? FileHandle(forWritingTo: output)
            guard file != nil else { return false }
        }
        process.standardOutput = file ?? FileHandle.nullDevice
        defer { try? file?.close() }
        let status: Int32? = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(returning: nil)
                return
            }
            let stuck = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { if stuck.isRunning { stuck.terminate() } }
        }
        return status == 0
    }

    // MARK: The overview's JSON

    // Only the keys Unwine reads. Every value but the process id is optional, so a key a later macOS
    // drops or renames costs that number, not the whole session.
    fileprivate struct Entry: Decodable {
        let pid: Int
        let layers: [Layer]?
        enum CodingKeys: String, CodingKey { case pid = "PID", layers = "Layers" }
    }

    fileprivate struct Layer: Decodable {
        let stats: Session?
        enum CodingKeys: String, CodingKey { case stats = "Total Session Stats" }
    }

    fileprivate struct Session: Decodable {
        let onGlass: Timing?
        let presented: Presented?
        enum CodingKeys: String, CodingKey { case onGlass = "Frame-On-Glass Interval Stats", presented = "Presented Frame Stats" }
    }

    fileprivate struct Presented: Decodable {
        let gpu: Timing?
        let shaders: Shaders?
        enum CodingKeys: String, CodingKey { case gpu = "On-GPU Walltime Stats", shaders = "Shader Compiler" }
    }

    fileprivate struct Timing: Decodable {
        let total: Double?
        let count: Double?
        enum CodingKeys: String, CodingKey { case total = "Total (ms)", count = "Count" }
    }

    fileprivate struct Shaders: Decodable {
        let seconds: Double?
        enum CodingKeys: String, CodingKey { case seconds = "Total Shader Compilation Time" }
    }
}

extension MetalPerfTrace.Frames {
    fileprivate mutating func add(_ s: MetalPerfTrace.Session?) {
        guard let s else { return }
        glassMs += s.onGlass?.total ?? 0
        glassFrames += s.onGlass?.count ?? 0
        gpuMs += s.presented?.gpu?.total ?? 0
        gpuFrames += s.presented?.gpu?.count ?? 0
        shaderSeconds += s.presented?.shaders?.seconds ?? 0
    }
}

/// Wine processes, read straight from the kernel: which bottle each one runs in, and what program.
enum WineProcesses {
    struct Info: Sendable {
        let prefix: String      // the bottle (WINEPREFIX), tidied
        let program: String?    // the .exe it runs, as Wine was given it: a Mac path or C:\...
        let started: Date
    }

    struct Sample: Sendable {
        var alive = Set<pid_t>()            // every Wine process now
        var read: [pid_t: Info?] = [:]      // the ones not known before; nil when not in a bottle
    }

    /// Every process whose file starts with "wine": the loader and its server, and the Steam Play
    /// runner's copies of both (wine.decant-real, wineserver.decant-real). Only processes not in
    /// `known` are read, so each is read once. Well under a millisecond with no Wine running.
    static func sample(known: Set<pid_t>) -> Sample {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 64)
        var sample = Sample()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name).hasPrefix("wine") else { continue }
            sample.alive.insert(pid)
            if !known.contains(pid) { sample.read.updateValue(info(pid), forKey: pid) }
        }
        return sample
    }

    /// A bottle path in one spelling, for comparing. A Mac disk ignores case, and Steam has spelled
    /// its folder both "SteamApps" and "steamapps".
    static func tidy(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path.lowercased() }

    private static func info(_ pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        // argc, the executable's path, padding, then the arguments and the environment, each ending in NUL.
        // Wine writes the Windows program over its argv[0] ("C:\windows\system32\services.exe") and
        // fills the rest of the old arguments with NULs, so padding can sit before the environment too.
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        func string() -> String {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buffer[start..<min(i, size)], as: UTF8.self)
        }
        func skipPadding() { while i < size, buffer[i] == 0 { i += 1 } }
        _ = string()
        skipPadding()
        var arguments: [String] = []
        while arguments.count < argc, i < size { arguments.append(string()) }
        skipPadding()
        var prefix: String?
        while i < size, buffer[i] != 0 {
            let entry = string()
            if entry.hasPrefix("WINEPREFIX=") { prefix = String(entry.dropFirst("WINEPREFIX=".count)) }
        }
        guard let prefix, !prefix.isEmpty else { return nil }
        let program = arguments.lazy.compactMap { arg in arg.range(of: ".exe", options: .caseInsensitive).map { String(arg[..<$0.upperBound]) } }.first
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize
            ? Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000) : Date()
        return Info(prefix: tidy(prefix), program: program, started: started)
    }
}
