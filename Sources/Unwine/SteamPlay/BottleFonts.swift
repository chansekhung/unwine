import Foundation

/// Font stand-ins for Windows-only fonts, so text a game draws with them does not come out blank.
/// The Mac already has the stand-ins (Palatino, Times New Roman, PingFang, Hiragino). Age of
/// Mythology's launcher, for one, draws its button labels in Palatino Linotype, which no Wine
/// bottle has.
///
/// Chinese, Japanese and Korean text in dialogs and launchers came out as boxes: Wine's dialog
/// font (Tahoma) falls back to MS UI Gothic, SimSun, PMingLiU and Gulim, as Windows does, and no
/// bottle has those. Pointing them at the Mac's own fonts fixes every dialog font at once
/// (Romance of the Three Kingdoms XIV's tools); the other names give games that ask for a font by
/// name the matching style. Each list goes from the closest Mac font to ones every Mac has.
enum BottleFonts {
    /// Windows font name -> fonts Wine tries instead, in order.
    static let replacements: [(windows: String, mac: [String])] = {
        let japanese = ["Hiragino Sans W3", "Hiragino Sans GB W3", "Heiti TC"]
        let japaneseSerif = ["Hiragino Mincho ProN W3", "Hiragino Sans W3"]
        let simplified = ["PingFang SC", "Hiragino Sans GB W3", "Heiti SC"]
        let simplifiedSerif = ["Songti SC", "PingFang SC", "Heiti SC"]
        let traditional = ["PingFang TC", "Heiti TC", "LiSong Pro"]
        let korean = ["Apple SD Gothic Neo", "AppleGothic"]
        let koreanSerif = ["AppleMyungjo", "Apple SD Gothic Neo"]
        var list: [(String, [String])] = [
            ("Palatino Linotype", ["Palatino", "Times New Roman"]),
            ("Book Antiqua", ["Palatino", "Times New Roman"]),
            // The four that Wine's dialog fonts fall back to.
            ("MS UI Gothic", japanese), ("SimSun", simplifiedSerif), ("PMingLiU", traditional), ("Gulim", korean),
            ("KaiTi", ["Kaiti SC"] + simplified), ("FangSong", ["STFangsong"] + simplifiedSerif),
            ("DFKai-SB", ["Kaiti TC"] + traditional),
        ]
        list += ["MS Gothic", "MS PGothic", "Meiryo", "Meiryo UI", "Yu Gothic", "Yu Gothic UI"].map { ($0, japanese) }
        list += ["MS Mincho", "MS PMincho", "Yu Mincho"].map { ($0, japaneseSerif) }
        list += ["SimHei", "Microsoft YaHei", "Microsoft YaHei UI", "DengXian"].map { ($0, simplified) }
        list += ["NSimSun"].map { ($0, simplifiedSerif) }
        list += ["MingLiU", "MingLiU_HKSCS", "Microsoft JhengHei", "Microsoft JhengHei UI"].map { ($0, traditional) }
        list += ["Malgun Gothic", "Dotum", "DotumChe", "GulimChe"].map { ($0, korean) }
        list += ["Batang", "BatangChe", "Gungsuh"].map { ($0, koreanSerif) }
        return list.map { (windows: $0.0, mac: $0.1) }
    }()

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
