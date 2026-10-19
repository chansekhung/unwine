import Foundation

/// One downloadable engine: a Sikarugir Wine build plus the matching runtime "Template"
/// (GStreamer, MoltenVK, SDL, and the DXMT / DXVK / D9VK graphics layers).
struct EngineRelease: Codable, Equatable, Sendable {
    var id: String              // e.g. "WS12WineSikarugir11.0_1"
    var engineURL: URL
    var engineSHA256: String?
    var engineSize: Int64
    var runtimeID: String       // e.g. "Template-1.0.24"
    var runtimeURL: URL
    var runtimeSHA256: String?
    var runtimeSize: Int64

    var key: String { "\(id)+\(runtimeID)" }
    var totalBytes: Int64 { engineSize + runtimeSize }

    /// Tested on an M4 Pro with macOS 27.0.1 on 2026-10-19: Windows Steam renders and signs in.
    static let pinned = EngineRelease(
        id: "WS12WineSikarugir11.0_1",
        engineURL: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz")!,
        engineSHA256: "67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e",
        engineSize: 167_322_744,
        runtimeID: "Template-1.0.24",
        runtimeURL: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz")!,
        runtimeSHA256: "4b5f89eeb9ef139936bdfad33d9b420b05ea4597cb7d63376674f7a8e171321c",
        runtimeSize: 96_198_448
    )
}

/// What Decant learned about an installed engine by looking inside it.
struct InstalledEngine: Codable, Equatable, Sendable {
    var release: EngineRelease
    var folder: String                  // folder name under Paths.engines
    var wineVersion: String             // "wine sikarugir 11.0 (revision 1)"
    var markerEnv: [String: String]     // e.g. ["SikarugirAppWine11": "1"]; Wine exits silently without it
    var rendererVars: [String]          // WINEDLLPATH_DXMT, ... the engine understands
    var supportsMsync: Bool
    var installedAt: Date

    var root: URL { Paths.engines.appendingPathComponent(folder, isDirectory: true) }
    var wineDir: URL { root.appendingPathComponent("wine", isDirectory: true) }
    var wine: URL { wineDir.appendingPathComponent("bin/wine") }
    var wineserver: URL { wineDir.appendingPathComponent("bin/wineserver") }
    var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    var frameworks: URL { runtime.appendingPathComponent("Frameworks", isDirectory: true) }
    var rendererRoot: URL { runtime.appendingPathComponent("SharedSupport/renderer", isDirectory: true) }
    func renderer(_ name: String) -> URL { rendererRoot.appendingPathComponent("\(name)/wine", isDirectory: true) }

    func supports(_ variable: String) -> Bool { rendererVars.contains(variable) }
}

enum EngineError: LocalizedError {
    case broken(String)
    case rosettaMissing

    var errorDescription: String? {
        switch self {
        case .broken(let why): return "The engine is incomplete: \(why)"
        case .rosettaMissing: return "Rosetta is not installed. Decant needs it to run Windows games."
        }
    }
}

/// Downloads, unpacks, checks and records engines.
enum EngineStore {
    static let recordName = "engine.json"

    /// Apple's D3DMetal must come from the user's own Apple download, so we never unpack
    /// the copy that ships inside the Template, nor its closed launcher apps.
    static let runtimeExcludes = ["*/renderer/d3dmetal", "*/renderer/d3dmetal/*", "*/renderer/apple_gptk",
                                  "*/Contents/MacOS/*", "*/Configure.app", "*/Configure.app/*",
                                  "*/drive_c", "*/drive_c/*"]

    static func installed() -> [InstalledEngine] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: Paths.engines, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(recordName)) else { return nil }
            return try? JSONDecoder.decant.decode(InstalledEngine.self, from: data)
        }
        .filter { FileManager.default.isExecutableFile(atPath: $0.wine.path) }
        .sorted { $0.installedAt > $1.installedAt }
    }

    enum Step: Equatable {
        case downloading(Double?)   // 0...1 over both files
        case unpacking
        case checking
    }

    /// Full install. Re-uses verified archives already in Downloads.
    static func install(_ release: EngineRelease, log: LogFile,
                        progress: @escaping @Sendable (Step) -> Void) async throws -> InstalledEngine {
        try Paths.ensure(Paths.downloads)
        try Paths.ensure(Paths.engines)

        let engineFile = Paths.downloads.appendingPathComponent(release.engineURL.lastPathComponent)
        let runtimeFile = Paths.downloads.appendingPathComponent(release.runtimeURL.lastPathComponent)
        let total = Double(release.totalBytes)
        let engineShare = Double(release.engineSize) / max(total, 1)

        progress(.downloading(0))
        try await fetchIfNeeded(release.engineURL, to: engineFile, size: release.engineSize, sha: release.engineSHA256, log: log) { p in
            progress(.downloading(p.map { $0 * engineShare }))
        }
        try await fetchIfNeeded(release.runtimeURL, to: runtimeFile, size: release.runtimeSize, sha: release.runtimeSHA256, log: log) { p in
            progress(.downloading(p.map { engineShare + $0 * (1 - engineShare) }))
        }

        progress(.unpacking)
        let folder = release.key.replacingOccurrences(of: "/", with: "-")
        let final = Paths.engines.appendingPathComponent(folder, isDirectory: true)
        let stage = Paths.engines.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensure(stage.appendingPathComponent("e"))
        try Paths.ensure(stage.appendingPathComponent("t"))
        defer { try? FileManager.default.removeItem(at: stage) }

        try await untar(engineFile, into: stage.appendingPathComponent("e"), excludes: [], log: log)
        try await untar(runtimeFile, into: stage.appendingPathComponent("t"), excludes: runtimeExcludes, log: log)

        let wineSrc = try singleChild(of: stage.appendingPathComponent("e"))              // wswine.bundle
        let templateApp = try singleChild(of: stage.appendingPathComponent("t"))          // Template-x.app
        let assembled = stage.appendingPathComponent("assembled", isDirectory: true)
        try Paths.ensure(assembled)
        try FileManager.default.moveItem(at: wineSrc, to: assembled.appendingPathComponent("wine"))
        try FileManager.default.moveItem(at: templateApp.appendingPathComponent("Contents"), to: assembled.appendingPathComponent("runtime"))
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", assembled.path], check: false)

        progress(.checking)
        var engine = try probe(root: assembled, release: release, folder: folder)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: assembled, to: final)
        engine.installedAt = Date()

        // Smoke test: the loader must start and report its version.
        let env = WineEnvironment.base(engine: engine, prefix: Paths.support.appendingPathComponent("probe-prefix"))
        let result = try await Shell.run(engine.wine, ["--version"], env: env, log: log, check: false)
        guard result.status == 0, result.output.lowercased().contains("wine") else {
            try? FileManager.default.removeItem(at: final)
            if result.output.contains("Bad CPU type") { throw EngineError.rosettaMissing }
            throw EngineError.broken("wine --version failed (\(result.status)).")
        }
        let data = try JSONEncoder.decant.encode(engine)
        try data.write(to: final.appendingPathComponent(recordName))
        log.line("Engine ready: \(engine.wineVersion) [\(engine.rendererVars.joined(separator: ","))]")
        return engine
    }

    /// Reads the engine's own files to learn the switches it needs. Nothing is hardcoded
    /// that a future engine revision could rename without us noticing.
    static func probe(root: URL, release: EngineRelease, folder: String) throws -> InstalledEngine {
        let fm = FileManager.default
        let wineDir = root.appendingPathComponent("wine")
        for required in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/kernel32.dll"] {
            guard fm.fileExists(atPath: wineDir.appendingPathComponent(required).path) else { throw EngineError.broken("missing \(required)") }
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("runtime/SharedSupport/renderer/dxmt/wine").path) else {
            throw EngineError.broken("missing the DXMT graphics layer")
        }
        let ntdll = try Data(contentsOf: wineDir.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"))
        let strings = asciiStrings(in: ntdll, minLength: 8)

        var marker: [String: String] = [:]
        for s in strings where s.hasPrefix("SikarugirAppWine") && s.count <= 24 && s.dropFirst(16).allSatisfy(\.isNumber) {
            marker[s] = "1"
        }
        let rendererVars = Set(strings.filter { $0.hasPrefix("WINEDLLPATH_") && $0.allSatisfy { $0.isUppercase || $0 == "_" || $0.isNumber } })
        let version = (try? String(contentsOf: wineDir.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? release.id

        return InstalledEngine(release: release, folder: folder, wineVersion: version, markerEnv: marker,
                               rendererVars: rendererVars.sorted(), supportsMsync: strings.contains("WINEMSYNC"),
                               installedAt: Date())
    }

    // MARK: Helpers

    private static func fetchIfNeeded(_ url: URL, to file: URL, size: Int64, sha: String?, log: LogFile,
                                      progress: @escaping @Sendable (Double?) -> Void) async throws {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), (attrs[.size] as? Int64) == size {
            if let sha, (try? await Task.detached { try Downloader.sha256(of: file) }.value) == sha {
                log.line("Using cached \(file.lastPathComponent)")
                progress(1)
                return
            }
        }
        log.line("Downloading \(url.absoluteString)")
        _ = try await Downloader.fetch(url, to: file, expectedBytes: size, sha256: sha, progress: progress)
    }

    private static func untar(_ archive: URL, into dir: URL, excludes: [String], log: LogFile) async throws {
        // Refuse archives that try to write outside the target folder.
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path], keep: 64_000_000)
        for line in listing.output.split(separator: "\n") where line.hasPrefix("/") || line.contains("../") {
            throw EngineError.broken("unsafe path in archive: \(line)")
        }
        var args = ["-xf", archive.path, "-C", dir.path, "--no-xattrs", "--no-mac-metadata"]
        for pattern in excludes { args += ["--exclude", pattern] }
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), args, log: log)
    }

    private static func singleChild(of dir: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard items.count == 1 else { throw EngineError.broken("unexpected archive layout in \(dir.lastPathComponent)") }
        return items[0]
    }

    /// Printable ASCII runs, like `strings`.
    static func asciiStrings(in data: Data, minLength: Int) -> Set<String> {
        var out = Set<String>()
        var current = [UInt8]()
        current.reserveCapacity(64)
        for byte in data {
            if byte >= 0x20 && byte < 0x7F {
                current.append(byte)
            } else {
                if current.count >= minLength, let s = String(bytes: current, encoding: .ascii) { out.insert(s) }
                current.removeAll(keepingCapacity: true)
            }
        }
        return out
    }

    /// Deletes engines whose folder is not in `keep` (pass the current and the previous one).
    static func prune(keep: [String]) {
        for engine in installed() where !keep.contains(engine.folder) {
            try? FileManager.default.removeItem(at: engine.root)
        }
    }

    /// Removes half-finished staging folders left by a quit or crash during an install.
    static func cleanStaging() {
        let fm = FileManager.default
        for dir in [Paths.engines, Paths.layers, SteamPlayPaths.kit, SteamPlayPaths.runners] {
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where [".staging-", ".stage-", ".import-", ".swap-"].contains(where: item.lastPathComponent.hasPrefix) {
                try? fm.removeItem(at: item)
            }
        }
    }
}

extension JSONEncoder {
    static let decant: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let decant: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
