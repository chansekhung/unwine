import CryptoKit
import Foundation

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
        request.setValue("Decant", forHTTPHeaderField: "User-Agent")
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
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Double?) -> Void)?
    private var destination: URL!
    private var expectedBytes: Int64 = 0

    static func fetch(_ url: URL, to destination: URL, expectedBytes: Int64 = 0, sha256: String? = nil,
                      progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let d = Downloader()
        let file = try await d.run(url, to: destination, expectedBytes: expectedBytes, progress: progress)
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

    private func run(_ url: URL, to destination: URL, expectedBytes: Int64,
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
        request.setValue("Decant", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        onProgress?(total > 0 ? Double(totalBytesWritten) / Double(total) : nil)
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
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let continuation else { return }
        let ns = error as NSError
        continuation.resume(throwing: ns.code == NSURLErrorNotConnectedToInternet ? DownloadError.offline : error)
        self.continuation = nil
    }
}
