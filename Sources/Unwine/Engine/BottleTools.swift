import Darwin
import Foundation

/// Wine's own Windows tools, which every engine ships.
enum WineTool: String, CaseIterable, Identifiable, Sendable {
    case settings, registry, tasks, uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Wine settings"
        case .registry: return "Registry editor"
        case .tasks: return "Task manager"
        case .uninstall: return "Uninstall programs"
        }
    }

    var command: String {
        switch self {
        case .settings: return "winecfg"
        case .registry: return "regedit"
        case .tasks: return "taskmgr"
        case .uninstall: return "uninstaller"
        }
    }
}

/// Something to run in a game's Windows bottle: a file the user picked, or one of Wine's tools.
enum BottleProgram: Sendable {
    case file(URL)
    case tool(WineTool)
    /// A program with arguments: an app that runs already, asked to open more files.
    case open(URL, [String])

    var title: String {
        switch self {
        case .file(let url), .open(let url, _): return url.lastPathComponent
        case .tool(let tool): return tool.title
        }
    }

    /// Wine's arguments. An .msi goes through msiexec and a .bat or .cmd through cmd, as Windows opens
    /// them. Those two read a path that starts with / as an option, so they get the Windows path.
    var arguments: [String] {
        switch self {
        case .tool(let tool):
            return [tool.command]
        case .open(let url, let arguments):
            return [url.path] + arguments
        case .file(let url):
            switch url.pathExtension.lowercased() {
            case "msi": return ["msiexec", "/i", BottleTools.windowsPath(url)]
            case "bat", "cmd": return ["cmd", "/c", BottleTools.windowsPath(url)]
            default: return [url.path]
            }
        }
    }

    /// The folder the program starts in: its own, so it finds the files next to it.
    var folder: URL? {
        switch self {
        case .file(let url), .open(let url, _): return url.deletingLastPathComponent()
        case .tool: return nil
        }
    }
}

enum BottleTools {
    struct Launch {
        let loader: URL
        let env: [String: String]
    }

    /// How to start a program in a game's bottle so that it joins the game's Wine: Unwine's engine (the
    /// Steam tool is a clone of it, with the same data files, so Wine does not update a Steam Play
    /// bottle for it), the game's own profile, and the running server's msync setting (Wine refuses
    /// a process whose setting differs).
    static func launch(engine: InstalledEngine, prefix: URL, profile: URL) -> Launch {
        var env = LocalGames.environment(engine: engine, prefix: prefix, profile: profile)
        if let live = serverMsync(prefix) { env["WINEMSYNC"] = live }
        return Launch(loader: engine.wine, env: env)
    }

    /// The Windows path of a Mac file. Wine shows the Mac's whole disk as drive Z:.
    static func windowsPath(_ url: URL) -> String { "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\") }

    /// The CPU time each process has used so far, in seconds. A game that loads without a window
    /// uses a lot of it; a leftover helper uses almost none.
    static func cpuSeconds(_ pids: [pid_t]) -> [pid_t: Double] {
        // The kernel counts in Mach time units, which are not nanoseconds on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1e9
        var out: [pid_t: Double] = [:]
        for pid in pids {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            out[pid] = Double(info.pti_total_user + info.pti_total_system) * scale
        }
        return out
    }

    /// The WINEMSYNC value the bottle's running server started with, read from its environment. Nil
    /// when the bottle is closed.
    static func serverMsync(_ pfx: URL) -> String? {
        guard let pid = serverPID(pfx), let env = environment(of: pid) else { return nil }
        let value = env.first { $0.hasPrefix("WINEMSYNC=") }?.dropFirst("WINEMSYNC=".count)
        return value == nil || value == "0" ? "0" : "1"
    }

    /// The bottle's wineserver: the process that holds the lock OnlineSteam.serverIsAlive asks about.
    /// The same steps as OnlineSteam's own, which only reads its own bottle.
    private static func serverPID(_ pfx: URL) -> pid_t? {
        var st = stat()
        guard stat(pfx.path, &st) == 0 else { return nil }
        let dir = String(format: "/tmp/.wine-%d/server-%llx-%llx", getuid(), UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        let fd = open(dir + "/lock", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }

    /// A process's environment, from the kernel. Nil for another user's process.
    private static func environment(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        // argc, the executable's path, NUL padding, the arguments, then the environment.
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        func string() -> String {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buffer[start..<min(i, size)], as: UTF8.self)
        }
        _ = string()
        while i < size, buffer[i] == 0 { i += 1 }
        for _ in 0..<argc where i < size { _ = string() }
        var env: [String] = []
        while i < size, buffer[i] != 0 { env.append(string()) }
        return env
    }
}
