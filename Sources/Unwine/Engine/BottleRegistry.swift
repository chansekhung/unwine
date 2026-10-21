import Foundation

/// A Wine bottle's own registry (HKEY_CURRENT_USER), written the way Online mode writes its bottle:
/// a .reg file next to the C: drive, imported with `regedit /S`, then a check of user.reg. Wine reads
/// these values when a process starts and saves user.reg when its server quits, so a write happens
/// only while the bottle is closed.
enum BottleRegistry {
    enum Value: Equatable, Sendable {
        case string(String)
        case dword(UInt32)

        /// The value as a .reg file and user.reg write it.
        var text: String {
            switch self {
            case .string(let s): return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            case .dword(let n): return "dword:" + String(format: "%08x", n)
            }
        }
    }

    /// One value under a key of HKEY_CURRENT_USER, such as `Software\Wine\Mac Driver`.
    struct Entry: Equatable, Sendable {
        let key: String
        let name: String
        let value: Value
    }

    /// The entries as a .reg file. Wine's regedit wants UTF-16 with a byte-order mark and CRLF line ends.
    static func regFile(_ entries: [Entry]) -> Data {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var keys: [String] = []
        for e in entries where !keys.contains(e.key) { keys.append(e.key) }
        for key in keys {
            lines.append("[HKEY_CURRENT_USER\\\(key)]")
            for e in entries where e.key == key { lines.append("\"\(e.name)\"=\(e.value.text)") }
            lines.append("")
        }
        return Data([0xFF, 0xFE]) + (lines.joined(separator: "\r\n").data(using: .utf16LittleEndian) ?? Data())
    }

    /// The values Wine saved under `key` in user.reg, as it writes them there ("\"y\"", "dword:000000c0").
    static func saved(_ key: String, in userReg: String) -> [String: String] {
        // user.reg names keys relative to HKEY_CURRENT_USER, with each backslash doubled, and puts a
        // time stamp after the closing bracket.
        let header = ("[" + key.replacingOccurrences(of: "\\", with: "\\\\") + "]").lowercased()
        var out: [String: String] = [:]
        var inKey = false
        for raw in userReg.split(whereSeparator: \.isNewline) {
            if raw.hasPrefix("[") { inKey = raw.lowercased().hasPrefix(header); continue }
            guard inKey, raw.hasPrefix("\""), let end = raw.range(of: "\"=") else { continue }
            out[String(raw[raw.index(after: raw.startIndex)..<end.lowerBound])] = String(raw[end.upperBound...])
        }
        return out
    }

    enum Outcome: Equatable {
        case written        // in user.reg now
        case unchecked      // imported, but Wine still runs in the bottle (a game started), so user.reg is not saved yet
        case busy           // the bottle was open: nothing written
        case failed
    }

    /// Imports `entries` into a closed bottle with the engine's regedit. `msync` is the game's own
    /// WINEMSYNC: if the game starts while regedit runs, it joins the same Wine server, and Wine
    /// refuses a process whose sync mode differs from the server's.
    static func write(_ entries: [Entry], prefix: URL, engine: InstalledEngine, msync: String?, log: LogFile) async -> Outcome {
        guard !entries.isEmpty else { return .written }
        guard !OnlineSteam.serverIsAlive(prefix) else { return .busy }
        // A file next to the bottle's C: drive keeps the path free of spaces.
        let name = "unwine-settings-\(UUID().uuidString.prefix(8)).reg"
        let file = prefix.appendingPathComponent("drive_c/\(name)")
        do { try regFile(entries).write(to: file) } catch {
            log.line("Could not write the bottle's settings file: \(error.localizedDescription)")
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: file) }
        var env = WineEnvironment.base(engine: engine, prefix: prefix)
        if let msync { env["WINEMSYNC"] = msync }
        let status = await run(engine.wine, ["regedit", "/S", "C:\\" + name], env: env, timeout: 120, log: log)
        guard status == 0 else {
            log.line("regedit stopped \(status.map { "with code \($0)" } ?? "after 2 minutes") in \(prefix.deletingLastPathComponent().lastPathComponent)")
            return .failed
        }
        // Wine saves user.reg as its server quits, a few seconds after the last program.
        let deadline = Date().addingTimeInterval(30)
        while OnlineSteam.serverIsAlive(prefix) && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        if OnlineSteam.serverIsAlive(prefix) { return .unchecked }
        let text = (try? Data(contentsOf: prefix.appendingPathComponent("user.reg"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for key in Set(entries.map(\.key)) {
            let have = saved(key, in: text)
            for e in entries where e.key == key && have[e.name]?.lowercased() != e.value.text.lowercased() {
                log.line("The bottle's user.reg has \(e.name)=\(have[e.name] ?? "nothing"), not \(e.value.text)")
                return .failed
            }
        }
        return .written
    }

    /// Runs a Wine program and returns its exit status, or nil when it did not start or ran past `timeout`
    /// seconds (it is then stopped). Wine's own output is dropped: with its logs quiet there is little.
    private static func run(_ exe: URL, _ args: [String], env: [String: String], timeout: Double, log: LogFile) async -> Int32? {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        log.line("$ \(exe.lastPathComponent) \(args.joined(separator: " "))")
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Int32?, Never>) in
            process.terminationHandler = { p in if once.claim() { done.resume(returning: p.terminationStatus) } }
            do { try process.run() } catch {
                if once.claim() { done.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { process.terminate(); done.resume(returning: nil) }
            }
        }
    }

    /// True for the first caller only, from any thread.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
