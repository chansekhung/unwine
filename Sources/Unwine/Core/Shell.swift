import Foundation

/// Appends text to a log file from any thread.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "unwine.log")
    private var handle: FileHandle?
    private var written = 0     // bytes in the current file; read and changed only on `queue`

    /// A log that reaches this size moves to "<name>.1" (the one before it goes) and starts again,
    /// also while a game writes to it. The last part before the move stays readable for a bug report.
    static let rotateAt = 10_000_000

    init(_ name: String) {
        url = Paths.logs.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size >= Self.rotateAt {
            rotate()
        } else {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            written = size
        }
    }

    func write(_ text: String) {
        let data = Data(text.utf8)
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.write(contentsOf: data)
            self.written += data.count
            if self.written >= Self.rotateAt { self.rotate() }
        }
    }

    func line(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        write("[\(stamp)] \(text)\n")
    }

    /// The log before the newest one, kept when the log moved on at `rotateAt`.
    static func previous(of url: URL) -> URL { url.appendingPathExtension("1") }

    /// Keeps the full log as "<name>.1" and starts an empty one. Runs in `init` or on `queue`.
    private func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil
        let old = Self.previous(of: url)
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        written = 0
    }

    /// Last `bytes` of the log, for the in-app viewer.
    func tail(_ bytes: Int = 64_000) -> String { Self.tail(of: url, bytes: bytes) }

    /// Last `bytes` of any log file, whole lines only. Just after the log moved on, the end of the
    /// one before it comes first, so the newest lines are never missing. Empty when there is no file.
    static func tail(of url: URL, bytes: Int = 64_000) -> String {
        func read(_ file: URL, _ count: Int) -> Data {
            guard count > 0, let h = try? FileHandle(forReadingFrom: file) else { return Data() }
            defer { try? h.close() }
            let end = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: end > UInt64(count) ? end - UInt64(count) : 0)
            return (try? h.readToEnd()) ?? Data()
        }
        let newest = read(url, bytes)
        let data = newest.count < bytes ? read(previous(of: url), bytes - newest.count) + newest : newest
        var text = String(decoding: data, as: UTF8.self)
        // A cut in the middle of a line would start with half a line.
        if data.count >= bytes, let cut = text.firstIndex(of: "\n") { text = String(text[text.index(after: cut)...]) }
        return text
    }
}

enum ShellError: LocalizedError {
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let output):
            let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "\(command) stopped with code \(status).\n\(tail)"
        }
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    /// Tools that copy or unpack many files. They run at utility priority, so a game that runs at the
    /// same time keeps the fast cores, and the work goes to the cores that use less power.
    static let bulkTools: Set<String> = ["tar", "cp", "ditto", "hdiutil", "unzip"]

    /// Runs a tool to completion without blocking the main thread.
    /// Output is mirrored to `log` and the last 64 KB is returned.
    @discardableResult
    static func run(_ exe: URL, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil,
                    log: LogFile? = nil, check: Bool = true, keep: Int = 64_000) async throws -> Result {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = cwd }
        if bulkTools.contains(exe.lastPathComponent) { process.qualityOfService = .utility }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer(limit: keep)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            // End of file: a handler left in place is called again and again with no data (a busy loop).
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            buffer.append(data)
            log?.write(String(decoding: data, as: UTF8.self))
        }

        log?.line("$ \(exe.lastPathComponent) \(args.joined(separator: " "))")
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            buffer.append(rest)
            log?.write(String(decoding: rest, as: UTF8.self))
        }
        let result = Result(status: status, output: buffer.string)
        if check && status != 0 {
            throw ShellError.failed(command: exe.lastPathComponent, status: status, output: result.output)
        }
        return result
    }

    /// Starts a long-running tool (like Steam) and returns at once. Output goes to `log`.
    static func spawn(_ exe: URL, _ args: [String], env: [String: String], cwd: URL? = nil,
                      log: LogFile, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        // The handler holds the pipe: programs the process started (a Wine session's services) keep
        // writing after it ends, and their lines reach the log until the last of them closes the pipe.
        pipe.fileHandleForReading.readabilityHandler = { [pipe] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; _ = pipe; return }
            log.write(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { p in onExit?(p.terminationStatus) }
        log.line("$ \(exe.lastPathComponent) \(args.joined(separator: " "))")
        try process.run()
        return process
    }

    private final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > limit * 2 { data = data.suffix(limit) }
        }

        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data.suffix(limit), as: UTF8.self)
        }
    }
}
