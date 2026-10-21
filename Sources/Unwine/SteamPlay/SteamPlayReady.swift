import Foundation

/// When a Steam that Unwine restarted is ready again: Steam runs, and its Steam Play add-on has
/// written the last line of its start in its log. Read only, like the rest of `MacSteam`.
extension MacSteam {
    /// The add-on is in Steam.app, so a new Steam start writes to its log. Without it, nothing will.
    static var hasAddOn: Bool { FileManager.default.fileExists(atPath: SteamPlayPaths.steamAddOn.path) }

    /// The size of the add-on's log now. A Steam start after this writes its lines after it.
    static func addOnLogEnd() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: SteamPlayPaths.addOnLog.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// True once a Steam start after `offset` in the add-on's log got as far as the add-on goes: its
    /// hooks are ready, or it says why they cannot be (Steam updated past its signatures, say).
    /// Reads only the lines after `offset`. "Absent after", when Steam relaunches itself to update,
    /// is not an end: the relaunched Steam writes its own lines.
    static func addOnSettled(since offset: UInt64) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: SteamPlayPaths.addOnLog) else { return false }
        defer { try? file.close() }
        let end = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: end >= offset ? offset : 0)    // a shorter log was started over
        let text = String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
        // The add-on's own last lines for steamclient.dylib, as the add-on in Steam.app writes them.
        let last = ["install_thread: ready,", "installing nothing", "cannot load signature database",
                    "no hooks installed", "compat support is incomplete", "no __TEXT segment"]
        return text.split(whereSeparator: \.isNewline).contains { line in last.contains { line.contains($0) } }
    }
}
