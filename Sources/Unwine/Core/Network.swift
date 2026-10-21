import CryptoKit
import Foundation
import Network

// MARK: - GitHub releases

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let size: Int64
        /// "sha256:<hex>" — GitHub publishes this for release assets.
        let digest: String?

        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst(7))
        }
    }

    let tag_name: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]
}

enum GitHub {
    static func releases(_ repo: String, limit: Int = 10) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(limit)")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Unwine", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1, url)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data).filter { !$0.draft }
    }
}

// MARK: - Version compare

/// Compares dotted versions like "11.0", "v1.2.10", "25.1.1". Non-digits are ignored.
struct LooseVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init(_ raw: String) {
        description = raw
        parts = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func < (a: LooseVersion, b: LooseVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: LooseVersion, b: LooseVersion) -> Bool { !(a < b) && !(b < a) }
}

// MARK: - Downloads with progress + checksum

enum DownloadError: LocalizedError {
    case http(Int, URL)
    case checksum(expected: String, got: String)
    case offline

    var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "The server said \(code) for \(url.lastPathComponent)."
        case .checksum: return "The download was damaged (checksum did not match). Try again."
        case .offline: return "No internet connection."
        }
    }
}

/// Downloads one file, reports progress, and verifies a SHA-256 when one is known.
///
/// A download cut off part way (the network dropped, or the Mac went to sleep) goes on from where it
/// stopped. URLSession's resume data stays next to the file as "<name>.resume", so the next try, also
/// after Unwine restarts, fetches only the rest.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Double?) -> Void)?
    private var destination: URL!
    private var expectedBytes: Int64 = 0
    private var reported: (time: TimeInterval, value: Double?)?

    static func fetch(_ url: URL, to destination: URL, expectedBytes: Int64 = 0, sha256: String? = nil,
                      progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        // Idle sleep would cut a long download off, and App Nap would slow it while no window shows.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Downloading \(destination.lastPathComponent)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let file = try await download(url, to: destination, expectedBytes: expectedBytes, progress: progress)
        if let sha256 {
            progress(nil)
            let got = try await Task.detached(priority: .utility) { try Self.sha256(of: file) }.value
            guard got.caseInsensitiveCompare(sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: file)
                throw DownloadError.checksum(expected: sha256, got: got)
            }
        }
        return file
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Waits before each new try after a dropped connection. Each try goes on from the last one.
    private static let retryWaits: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]

    private static func download(_ url: URL, to destination: URL, expectedBytes: Int64,
                                 progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        var resume = ResumeRecord.load(for: destination, url: url)
        var tries = 0
        var startedOver = false
        while true {
            do {
                let file = try await Downloader().run(url, to: destination, resumeData: resume,
                                                      expectedBytes: expectedBytes, progress: progress)
                ResumeRecord.remove(for: destination)
                return file
            } catch {
                let ns = error as NSError
                if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resume = data
                    ResumeRecord.save(data, url: url, for: destination)
                } else if resume != nil, !isDrop(ns), !startedOver, !Task.isCancelled {
                    // The saved part did not fit (the file changed on the server, or the part is gone): start over once.
                    ResumeRecord.remove(for: destination)
                    resume = nil
                    startedOver = true
                    continue
                }
                // Nothing came yet: fail fast, so the UI can offer Try again. A cut-off download tries again.
                guard resume != nil, isDrop(ns), tries < retryWaits.count, !Task.isCancelled else {
                    throw ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet ? DownloadError.offline : error
                }
                try await Task.sleep(for: retryWaits[tries])
                tries += 1
            }
        }
    }

    /// Errors after which the same download can go on: the network went away or was too slow.
    private static func isDrop(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                                             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                                             NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(error.code)
    }

    private func run(_ url: URL, to destination: URL, resumeData: Data?, expectedBytes: Int64,
                     progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onProgress = progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.waitsForConnectivity = false   // fail fast offline; the UI offers Try again
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Unwine", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                (resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let value: Double? = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil
        let now = ProcessInfo.processInfo.systemUptime
        // At most every 100 ms and every 0.5 %: the bar still moves smoothly, and the UI redraws about
        // 10 times a second instead of once for each piece of data that arrives.
        if let last = reported {
            guard now - last.time >= 0.1 else { return }
            switch (value, last.value) {
            case let (v?, l?) where v - l < 0.005: return
            case (nil, nil): return               // an unknown size is said once
            default: break
            }
        }
        reported = (now, value)
        onProgress?(value)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: DownloadError.http(http.statusCode, downloadTask.originalRequest?.url ?? location))
            continuation = nil
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            if reported?.value != 1 { onProgress?(1) }
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let continuation else { return }
        continuation.resume(throwing: error)    // `download` reads the resume data from it
        self.continuation = nil
    }
}

/// What URLSession needs to go on with a cut-off download, kept next to the file it is for.
/// The part already downloaded stays in macOS's temporary folder, which macOS cleans after some days.
private struct ResumeRecord: Codable {
    var url: String
    var data: Data

    static func file(for destination: URL) -> URL { destination.appendingPathExtension("resume") }

    /// The saved data, only when it belongs to this address (a mirror's data never resumes another).
    static func load(for destination: URL, url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: file(for: destination)),
              let record = try? JSONDecoder().decode(ResumeRecord.self, from: raw), record.url == url.absoluteString else { return nil }
        return record.data
    }

    static func save(_ data: Data, url: URL, for destination: URL) {
        guard let raw = try? JSONEncoder().encode(ResumeRecord(url: url.absoluteString, data: data)) else { return }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? raw.write(to: file(for: destination), options: .atomic)
    }

    static func remove(for destination: URL) { try? FileManager.default.removeItem(at: file(for: destination)) }
}

// MARK: - Network path

/// What kind of network the Mac is on now. A big download that Unwine starts by itself waits on a
/// metered connection (a phone hotspot) and in Low Data Mode. macOS tells Unwine when it changes.
@MainActor
final class NetworkPath {
    static let shared = NetworkPath()

    private(set) var isExpensive = false     // a phone hotspot or another metered connection
    private(set) var isConstrained = false   // Low Data Mode is on
    private var handlers: [@MainActor () -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor in NetworkPath.shared.update(expensive: expensive, constrained: constrained) }
        }
        monitor.start(queue: DispatchQueue(label: "unwine.network-path", qos: .utility))
    }

    /// Runs `handler` on the main actor each time the network becomes metered or stops being so.
    func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

    private func update(expensive: Bool, constrained: Bool) {
        guard expensive != isExpensive || constrained != isConstrained else { return }
        isExpensive = expensive
        isConstrained = constrained
        for h in handlers { h() }
    }
}
