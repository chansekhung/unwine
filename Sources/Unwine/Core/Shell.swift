import Foundation

/// Appends text to a log file from any thread.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "unwine.log")
    private var handle: FileHandle?

    init(_ name: String) {
        url = Paths.logs.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        // Keep logs small: start fresh once they pass 20 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 20_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ text: String) {
        let data = Data(text.utf8)
        queue.async { [weak self] in try? self?.handle?.write(contentsOf: data) }
    }

    func line(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        write("[\(stamp)] \(text)\n")
    }

    /// Last `bytes` of the log, for the in-app viewer.
    func tail(_ bytes: Int = 64_000) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer(limit: keep)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
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
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
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
