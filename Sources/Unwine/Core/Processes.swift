import Darwin

/// Running processes, read straight from the kernel. The refresh loop used to start two pgrep
/// processes every 4 seconds (over 40,000 a day) only to ask these questions.
enum Processes {
    /// True when a process with this short name runs (the name `ps -c` and `pgrep -x` match).
    static func anyNamed(_ name: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: 64)
        return pids().contains { proc_name($0, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == name }
    }

    /// True when a process runs a file with this name, wherever the file is. Unlike `pgrep -f`, a
    /// process that only mentions the name in its arguments does not count.
    static func anyRunning(file: String) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids().contains { pid in
            proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).split(separator: "/").last.map(String.init) == file
        }
    }

    private static func pids() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).filter { $0 > 0 }
    }
}
