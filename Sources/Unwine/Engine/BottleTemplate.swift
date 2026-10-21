import Foundation

/// One ready Windows bottle per engine, made once with wineboot and given the font stand-ins. A new
/// added game's bottle, and a fresh one, is an APFS clone of it (`cp -c -R`): about 0.3 s and 1 MB of
/// disk, where wineboot takes about 25 s and 340 MB for every game. NotProton seeds Steam Play bottles
/// the same way. A new engine gets a new template, because Wine updates a bottle made by another one.
enum BottleTemplate {
    /// Bump when the way the template is made changes, so older templates are made again.
    static let format = 1

    static var folder: URL { LocalGames.root.appendingPathComponent("BottleTemplates", isDirectory: true) }
    static func home(_ engine: InstalledEngine) -> URL { folder.appendingPathComponent(engine.folder, isDirectory: true) }

    private static let log = LogFile("bottle-template.log")

    private struct Record: Codable, Equatable {
        var engineFolder: String
        var format: Int
    }

    /// The template's bottle when it is complete for this engine, else nil.
    static func ready(_ engine: InstalledEngine) -> URL? {
        let home = home(engine)
        let pfx = home.appendingPathComponent("pfx", isDirectory: true)
        guard let data = try? Data(contentsOf: home.appendingPathComponent("template.json")),
              (try? JSONDecoder().decode(Record.self, from: data)) == Record(engineFolder: engine.folder, format: format),
              complete(pfx) else { return nil }
        return pfx
    }

    /// A bottle with its registry and both halves of Windows. A bottle cut short has no 32-bit half,
    /// and its 32-bit programs then quit at once.
    static func complete(_ pfx: URL) -> Bool {
        let fm = FileManager.default
        let windows = pfx.appendingPathComponent("drive_c/windows", isDirectory: true)
        return fm.fileExists(atPath: pfx.appendingPathComponent("system.reg").path)
            && fm.fileExists(atPath: windows.appendingPathComponent("system32/kernel32.dll").path)
            && fm.fileExists(atPath: windows.appendingPathComponent("syswow64/kernel32.dll").path)
    }

    /// Makes this engine's template with the settings of new games (the default profile, as for
    /// NotProton's own template), then removes the templates of other engines. It is made in a
    /// staging folder, so a cut-short build is never used.
    static func build(engine: InstalledEngine) async throws -> URL {
        let fm = FileManager.default
        try Paths.ensure(folder)
        // Builds that a quit Unwine left half done. Only one build runs at a time.
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(".stage-") && !OnlineSteam.serverIsAlive(item.appendingPathComponent("pfx", isDirectory: true)) {
            try? fm.removeItem(at: item)
        }
        let stage = folder.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        let pfx = stage.appendingPathComponent("pfx", isDirectory: true)
        try Paths.ensure(stage)
        defer { try? fm.removeItem(at: stage) }
        // Without Faster x87 math: macOS must not ask for the password while Unwine makes a bottle.
        let env = LocalGames.withoutX87(LocalGames.environment(engine: engine, prefix: pfx, profile: Profiles.file(for: nil)))
        let started = Date()
        log.line("Making the bottle template for \(engine.wineVersion)")
        do {
            try await Shell.run(engine.wine, ["wineboot", "--init"], env: env, log: log)
            try await Shell.run(engine.wineserver, ["-w"], env: env, log: log, check: false)
        } catch {
            _ = try? await Shell.run(engine.wineserver, ["-k"], env: env, log: log, check: false)
            throw LocalGamesError.bottle("Wine stopped while it made the bottle template.")
        }
        guard complete(pfx) else { throw LocalGamesError.bottle("Wine made no complete bottle template.") }
        BottleFonts.ensure(prefix: pfx)
        try JSONEncoder().encode(Record(engineFolder: engine.folder, format: format))
            .write(to: stage.appendingPathComponent("template.json"), options: .atomic)
        let home = home(engine)
        if fm.fileExists(atPath: home.path) { try fm.removeItem(at: home) }
        try fm.moveItem(at: stage, to: home)
        prune(keep: engine.folder)
        log.line(String(format: "The bottle template is ready (%.0f s)", Date().timeIntervalSince(started)))
        return home.appendingPathComponent("pfx", isDirectory: true)
    }

    /// Copies the template to `pfx` as APFS clones. The copy goes to a staging name first, so a
    /// cut-short copy never looks like a bottle. Throws when the copy is not a complete bottle.
    static func clone(_ template: URL, to pfx: URL, log: LogFile) async throws {
        let fm = FileManager.default
        let parent = pfx.deletingLastPathComponent()
        // Copies an earlier Unwine left half done.
        for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(".pfx-") { try? fm.removeItem(at: item) }
        let stage = parent.appendingPathComponent(".pfx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let started = Date()
        try await Shell.run(URL(fileURLWithPath: "/bin/cp"), ["-c", "-R", template.path, stage.path], log: log)
        guard complete(stage) else { throw LocalGamesError.bottle("The copy of the bottle template is not complete.") }
        try fm.moveItem(at: stage, to: pfx)
        log.line(String(format: "Made the bottle from Unwine's template in %.1f s", Date().timeIntervalSince(started)))
    }

    /// Removes the templates of every other engine: after an engine change they only take space. A
    /// template holds no saves: games only ever run in clones of it. A build in progress is left alone.
    static func prune(keep: String) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent != keep && !item.lastPathComponent.hasPrefix(".") {
            guard !OnlineSteam.serverIsAlive(item.appendingPathComponent("pfx", isDirectory: true)) else { continue }
            try? fm.removeItem(at: item)
        }
    }
}
