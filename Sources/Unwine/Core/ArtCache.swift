import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where game pictures live, and the caches that keep the library from reading or downloading one
/// twice: decoded pictures in memory, and Steam's CDN art on disk.
enum ArtCache {
    /// Pictures for added games: each program's icon (<id>.png) and the covers people chose.
    static var covers: URL { Paths.support.appendingPathComponent("Covers", isDirectory: true) }
    /// Copies of Steam's CDN art, for games that Steam has not cached itself.
    static var steamCopies: URL { Paths.support.appendingPathComponent("Cache/Art", isDirectory: true) }

    static func iconFile(_ id: Int) -> URL { covers.appendingPathComponent("\(id).png") }
    static func coverFile(_ name: String) -> URL { covers.appendingPathComponent(name) }

    // MARK: Memory

    /// Decoded pictures, so a tile that scrolls back into view shows at once. NSCache lets them go
    /// when macOS needs the memory.
    private static let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private static func steamKey(_ appID: Int, _ kind: SteamLibrary.ArtKind) -> String { "steam:\(appID):\(kind.rawValue)" }
    private static func fileKey(_ file: URL) -> String { "file:\(file.path)" }

    private static func remember(_ image: CGImage, _ key: String) {
        memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    /// Steam art already decoded this run.
    static func remembered(steamAppID appID: Int, _ kind: SteamLibrary.ArtKind) -> CGImage? {
        memory.object(forKey: steamKey(appID, kind) as NSString)
    }

    /// Drops a file's decoded picture, after the file changed.
    static func forget(_ file: URL) { memory.removeObject(forKey: fileKey(file) as NSString) }

    // MARK: Added games

    /// An added game's cover or icon. Nil when the file is gone or is not a picture.
    static func picture(at file: URL) async -> CGImage? {
        let key = fileKey(file)
        if let known = memory.object(forKey: key as NSString) { return known }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            return decode(source, maxPixels: SteamLibrary.ArtKind.hero.maxPixels)
        }.value
        if let image { remember(image, key) }
        return image
    }

    /// Copies a picture the user picked into Covers, at most 2048 pixels on its long side. A picture
    /// with see-through parts stays a PNG; any other becomes a JPEG. Returns the new file's name, or
    /// nil when macOS cannot read the file as a picture.
    static func importCover(from source: URL, for id: Int, into folder: URL = covers) throws -> String? {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = decode(reader, maxPixels: 2048) else { return nil }
        let seeThrough: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        guard let data = seeThrough ? ExeIcon.pngData(image) : jpeg(image, quality: 0.9) else { return nil }
        let name = "\(id)-cover-\(UUID().uuidString.prefix(8).lowercased()).\(seeThrough ? "png" : "jpg")"
        try Paths.ensure(folder)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// Removes the pictures of added games that are gone, and covers that were replaced. Files from
    /// the last ten minutes stay: one can be a cover that is being saved right now.
    static func removeLeftovers(keeping records: [LocalGameRecord], in folder: URL = covers) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let ids = Set(records.map(\.id))
        let chosen = Set(records.compactMap(\.cover))
        for file in files {
            let name = file.lastPathComponent
            guard let id = Int(String(name.prefix { $0.isASCII && $0.isNumber })) else { continue }
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(changed) > 600 else { continue }
            if !ids.contains(id) || (name.contains("-cover-") && !chosen.contains(name)) { try? fm.removeItem(at: file) }
        }
    }

    // MARK: Steam games

    /// A Steam game's art: Steam's own cache (it works offline and follows Steam's art changes), then
    /// Unwine's copy of the CDN art, then the CDN. Nil when none has it now. After each failed
    /// download Unwine waits longer before it asks the CDN again.
    static func steamPicture(_ appID: Int, _ kind: SteamLibrary.ArtKind) async -> CGImage? {
        let key = steamKey(appID, kind)
        if let known = memory.object(forKey: key as NSString) { return known }
        let image = await loads.run(key) { await loadSteam(appID, kind) }
        if let image { remember(image, key) }
        return image
    }

    /// True when the last download of this art failed. The tile then shows its placeholder at once.
    static func hasFailed(_ appID: Int, _ kind: SteamLibrary.ArtKind) -> Bool { failures.hasFailed(steamKey(appID, kind)) }

    /// A copy older than this is downloaded again when the CDN answers; until then it still shows.
    private static let maxAge: TimeInterval = 30 * 86_400

    private static func loadSteam(_ appID: Int, _ kind: SteamLibrary.ArtKind) async -> CGImage? {
        let size = kind.maxPixels
        if let file = SteamLibrary.cachedArt(kind, appID: appID), let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = decode(source, maxPixels: size) { return image }
        let copy = steamCopies.appendingPathComponent("\(appID)-\(kind.rawValue).jpg")
        var old: CGImage?
        if let source = CGImageSourceCreateWithURL(copy as CFURL, nil), let image = decode(source, maxPixels: size) {
            let changed = (try? copy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(changed) < maxAge { return image }
            old = image
        }
        let key = steamKey(appID, kind)
        guard failures.mayTry(key) else {
            if old == nil { failures.waiting(key) }
            return old
        }
        for url in SteamLibrary.remoteArt(kind, appID: appID) {
            let answer: (data: Data, response: URLResponse)
            do {
                answer = try await session.data(from: url)
            } catch {
                failures.noConnection(key)      // the other addresses fail the same way
                return old
            }
            guard (answer.response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(answer.data as CFData, nil), let image = decode(source, maxPixels: size) else { continue }
            failures.succeeded(key)
            save(image, to: copy)
            return image
        }
        failures.notThere(key)
        return old
    }

    /// Unwine keeps its own copies, so the session needs no URL cache.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false   // fail fast offline; the next refresh tries again
        return URLSession(configuration: config)
    }()

    /// A JPEG at the size the library draws, so the folder stays small.
    private static func save(_ image: CGImage, to file: URL) {
        guard let data = jpeg(image, quality: 0.85), (try? Paths.ensure(file.deletingLastPathComponent())) != nil,
              (try? data.write(to: file, options: .atomic)) != nil else { return }
        // Look at the folder's size on the first save of a run, then on every 20th.
        if writes.next() % 20 == 1 { prune() }
    }

    private static let largest = 80 * 1024 * 1024
    private static let keep = 60 * 1024 * 1024

    /// Above 80 MB, the copies used least recently go until 60 MB are left.
    private static func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: steamCopies, includingPropertiesForKeys: keys) else { return }
        var items = files.map { url -> (url: URL, size: Int, used: Date) in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, v?.fileSize ?? 0, v?.contentAccessDate ?? v?.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.size }
        guard total > largest else { return }
        items.sort { $0.used < $1.used }
        for item in items where total > keep {
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }

    // MARK: Pictures

    /// Decodes a picture at most `maxPixels` on its long side, straight from the file, so a big
    /// image is never decoded at full size. Small pictures keep their own size.
    static func decode(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Bookkeeping

    /// Failed downloads. Without a connection, all pictures together try once every 30 seconds;
    /// the first answer from the CDN lets every failed tile try again at the next refresh. Art the
    /// CDN does not have waits longer after each try: 30 seconds, then 1, 2 and 4 minutes, and so on
    /// up to an hour.
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var missing: [String: (count: Int, at: Date)] = [:]
        private var failed = Set<String>()
        private var offline = false
        private var lastOfflineTry = Date.distantPast

        func mayTry(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let last = missing[key], Date().timeIntervalSince(last.at) < min(3600, 30 * pow(2, Double(min(last.count, 8) - 1))) {
                return false
            }
            guard offline else { return true }
            guard Date().timeIntervalSince(lastOfflineTry) >= 30 else { return false }
            lastOfflineTry = Date()     // this caller is the one try; the others wait
            return true
        }

        /// Not tried now (offline, or the CDN lacked it a moment ago): the tile shows its placeholder.
        func waiting(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            failed.insert(key)
        }

        func noConnection(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            offline = true
            lastOfflineTry = Date()
            failed.insert(key)
        }

        func notThere(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            offline = false
            missing[key] = ((missing[key]?.count ?? 0) + 1, Date())
            failed.insert(key)
        }

        func succeeded(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            offline = false
            missing[key] = nil
            failed.remove(key)
        }

        func hasFailed(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failed.contains(key)
        }
    }

    private static let failures = Failures()

    /// One load per picture at a time: a tile and the game page that ask together share it, and a
    /// tile that leaves the screen does not stop it.
    private actor Loads {
        private var running: [String: Task<CGImage?, Never>] = [:]

        func run(_ key: String, _ work: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
            if let task = running[key] { return await task.value }
            let task = Task.detached(priority: .utility) { await work() }
            running[key] = task
            let value = await task.value
            running[key] = nil
            return value
        }
    }

    private static let loads = Loads()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private static let writes = Counter()
}

extension SteamLibrary.ArtKind {
    /// The most pixels the library draws this art at on a Retina screen: a tile is at most 190
    /// points wide and 285 high (570 pixels), the game page's header 560 points wide.
    var maxPixels: Int {
        switch self {
        case .capsule: return 600
        case .hero: return 1600
        case .header: return 920
        }
    }
}

/// What the library's pictures watch, besides the game itself.
@MainActor @Observable
final class ArtState {
    static let shared = ArtState()

    /// Counts the Steam refreshes that landed. A tile whose art failed tries again when it changes.
    private(set) var refreshes = 0
    /// Added programs whose name and icon Unwine is reading now.
    var reading = Set<Int>()
    /// Added games whose new cover Unwine is preparing now.
    var preparing = Set<Int>()

    func refreshLanded() { refreshes &+= 1 }
}
