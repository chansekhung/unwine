import Foundation

/// Font stand-ins for Windows-only fonts, so text a game draws with them does not come out blank.
/// The Mac already has the stand-ins (Palatino, Times New Roman). Age of Mythology's launcher, for
/// one, draws its button labels in Palatino Linotype, which no Wine bottle has.
enum BottleFonts {
    /// Windows font name -> fonts Wine tries instead, in order.
    static let replacements: [(windows: String, mac: [String])] = [
        ("Palatino Linotype", ["Palatino", "Times New Roman"]),
        ("Book Antiqua", ["Palatino", "Times New Roman"]),
    ]

    private static let section = #"[Software\\Wine\\Fonts\\Replacements]"#

    /// Adds the stand-ins to a closed bottle's user.reg, keeping any the user or a game set. Edits the
    /// text file directly (no Wine process), and only while the bottle's server is not running,
    /// because Wine writes user.reg back when its server quits. Returns true when the file changed.
    @discardableResult
    static func ensure(prefix: URL) -> Bool {
        let file = prefix.appendingPathComponent("user.reg")
        guard var text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let missing = replacements.filter { !text.contains("\n\"\($0.windows)\"=") }
        guard !missing.isEmpty else { return false }
        let lines = missing.map { r -> String in
            // REG_MULTI_SZ in Wine's text format: str(7), names separated and ended by \0.
            "\"\(r.windows)\"=str(7):\"" + r.mac.map { $0 + "\\0" }.joined() + "\""
        }
        if let range = text.range(of: section) {
            // Into the existing section, right after its header line.
            let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            text.insert(contentsOf: "\n" + lines.joined(separator: "\n"), at: lineEnd)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n\(section) \(Int(Date().timeIntervalSince1970))\n" + lines.joined(separator: "\n") + "\n"
        }
        // Checked again right before the write: a game may have started meanwhile.
        guard !OnlineSteam.serverIsAlive(prefix) else { return false }
        do { try text.write(to: file, atomically: true, encoding: .utf8) } catch { return false }
        return true
    }
}
