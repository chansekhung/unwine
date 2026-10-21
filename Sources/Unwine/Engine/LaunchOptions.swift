import Foundation

/// The language a game sees as its Windows locale. Wine takes the system locale, and with it the code
/// page of old (non-Unicode) programs, from LC_CTYPE, and the user locale from LC_MESSAGES: LC_ALL
/// sets both. Without them it asks macOS (Steam Play), but added games and Online mode set English.
/// Wine hands the user locale on to Windows as WINEUSERLOCALE, so that is set to match. A Japanese
/// game that is not Unicode shows broken text until its bottle says Japanese.
enum GameLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, english, japanese, chineseSimplified, chineseTraditional, korean
    case german, french, spanish, italian, portuguese, polish, russian

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .chineseSimplified: return "Simplified Chinese"
        case .chineseTraditional: return "Traditional Chinese"
        case .korean: return "Korean"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese (Brazil)"
        case .polish: return "Polish"
        case .russian: return "Russian"
        }
    }

    /// The Windows locale name, for WINEUSERLOCALE. Nil keeps what Unwine did before.
    var windowsLocale: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .chineseSimplified: return "zh-CN"
        case .chineseTraditional: return "zh-TW"
        case .korean: return "ko-KR"
        case .german: return "de-DE"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .polish: return "pl-PL"
        case .russian: return "ru-RU"
        }
    }

    /// The Mac locale for LC_ALL and LANG (every one of them ships with macOS).
    var unixLocale: String? { windowsLocale.map { $0.replacingOccurrences(of: "-", with: "_") + ".UTF-8" } }

    /// The Windows code page that old programs get with this language.
    var codePage: Int? {
        switch self {
        case .automatic: return nil
        case .japanese: return 932
        case .chineseSimplified: return 936
        case .chineseTraditional: return 950
        case .korean: return 949
        case .polish: return 1250
        case .russian: return 1251
        default: return 1252
        }
    }
}

/// One game's launch options and mods. They live apart from GameSettings: a preset click and
/// "Reset settings" replace a game's GameSettings, and must not take a mod's DLL overrides or the
/// game's language with them.
struct LaunchOptions: Codable, Equatable, Sendable {
    var arguments = ""                  // added games: what follows the program's name, split like a shell
    var extraSettings = ""              // NAME=value lines for every program in the game's bottle
    var dllOverrides: [String] = []     // DLLs that load the game folder's copy first (mod loaders)
    var language: GameLanguage = .automatic

    var isEmpty: Bool { self == LaunchOptions() }

    /// The DLL names mod loaders use most. A loader copies its DLL next to the game under one of these
    /// names, and Wine must load that file before its own (native, then builtin).
    static let modLoaderDLLs: [(name: String, use: String)] = [
        ("dinput8", "Script hooks and many mod loaders"),
        ("version", "Ultimate ASI Loader and other loaders"),
        ("winmm", "Ultimate ASI Loader and audio mods"),
        ("dsound", "Ultimate ASI Loader and sound mods"),
        ("winhttp", "BepInEx for Unity games"),
    ]

    /// The names Wine gets from Steam's own Launch Options (NotProton's run script passes only these).
    static let steamPassesNames = "D3DM_*, DXMT_*, DXVK_*, MTL_*, ROSETTA_*, CX_GRAPHICS*, Steam*, WINEDLLOVERRIDES, WINEDEBUG, WINEMSYNC, WINEDLLPATH, WINEPREFIX, WINESERVER and PATH"
}

extension LaunchOptions {
    /// Every field decodes with a default, so options saved by an older Unwine keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaunchOptions()
        arguments = (try? c.decodeIfPresent(String.self, forKey: .arguments)) ?? d.arguments
        extraSettings = (try? c.decodeIfPresent(String.self, forKey: .extraSettings)) ?? d.extraSettings
        dllOverrides = (try? c.decodeIfPresent([String].self, forKey: .dllOverrides)) ?? d.dllOverrides
        language = (try? c.decodeIfPresent(GameLanguage.self, forKey: .language)) ?? d.language
    }
}

// MARK: Reading what the user typed

extension LaunchOptions {
    struct Setting: Equatable, Sendable {
        let key: String
        let value: String
    }

    struct Problem: Equatable, Sendable {
        let line: Int
        let text: String
    }

    /// The launch options as the separate words the game gets. Spaces split them, and quotes keep a
    /// word with spaces in one piece, as in a shell. A backslash stays a backslash: Windows paths are
    /// full of them. Nil when a quote is not closed.
    static func words(_ text: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { word.append(ch) }
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
                inWord = true
            case " ", "\t", "\n", "\r":
                if inWord { words.append(word); word = ""; inWord = false }
            default:
                word.append(ch)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }

    /// Names Unwine sets itself, and why it keeps them. A change would stop Wine from starting, or
    /// point it at another bottle. WINEDLLPATH holds Steam Play's Steam bridge: a new value would cut
    /// the game off from Steam.
    static func refusal(_ key: String) -> String? {
        if key.hasPrefix("DYLD_") { return "Unwine sets the DYLD_ names. Wine needs them to find its own parts." }
        switch key {
        case "WINEPREFIX": return "WINEPREFIX names the game's bottle. Unwine sets it."
        case "WINESERVER", "WINELOADER": return "\(key) points to Unwine's engine. Unwine sets it."
        case "PATH": return "Unwine sets PATH, so that Wine finds its own tools."
        case "WINEDLLPATH": return "WINEDLLPATH tells Wine where Steam's own DLLs are. Put a mod's DLL next to the game and use DLL overrides."
        default: return nil
        }
    }

    /// The NAME=value lines of `text` that Unwine can use, and why it skips the others. Blank lines and
    /// lines that start with # are notes. A leading "export " and one pair of quotes around the value
    /// are taken off, as a shell does. When a name shows twice, the last line wins, as in a shell.
    static func settings(in text: String) -> (settings: [Setting], problems: [Problem]) {
        var settings: [Setting] = []
        var problems: [Problem] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else {
                problems.append(Problem(line: i + 1, text: "Write it as NAME=value."))
                continue
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard let first = key.first, first.isASCII, first.isLetter || first == "_",
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                problems.append(Problem(line: i + 1, text: "A name has only letters, digits and _, and starts with a letter."))
                continue
            }
            if let why = refusal(key) {
                problems.append(Problem(line: i + 1, text: why))
                continue
            }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            settings.removeAll { $0.key == key }
            settings.append(Setting(key: key, value: value))
        }
        return (settings, problems)
    }

    /// DLL names from what the user typed ("xinput1_3, d3dx9_43.dll"), in lower case and without
    /// ".dll", and the words that are not DLL names.
    static func dllNames(in text: String) -> (names: [String], rejected: [String]) {
        var names: [String] = []
        var rejected: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            var name = part.lowercased()
            if name.hasSuffix(".dll") { name = String(name.dropLast(4)) }
            if !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }) {
                if !names.contains(name) { names.append(name) }
            } else {
                rejected.append(String(part))
            }
        }
        return (names, rejected)
    }

    /// `extra` (such as "winemenubuilder.exe=d") added to a WINEDLLOVERRIDES value, unless the value
    /// already names that DLL: then the user's own choice stays.
    static func overrides(_ value: String?, adding extra: String) -> String {
        // A profile adds its part after a ";", so a value can start with an empty entry.
        let value = (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        guard !value.isEmpty else { return extra }
        let dll = extra.split(separator: "=").first.map { $0.lowercased().replacingOccurrences(of: ".exe", with: "").replacingOccurrences(of: ".dll", with: "") } ?? extra
        return value.lowercased().contains(dll) ? value : value + ";" + extra
    }

    /// Text for inside "double quotes" in sh, where only \ " $ and ` are special.
    static func escapedForDoubleQuotes(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\\"$`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

// MARK: The game's profile

extension LaunchOptions {
    /// The profile lines for these options: the language first, then the DLL overrides, then the
    /// user's own lines, so a line the user wrote wins over Unwine's. DLL overrides add up instead.
    func profileLines() -> [String] {
        let q = Runner.shellQuote
        var out: [String] = []
        if let unix = language.unixLocale, let windows = language.windowsLocale {
            out += ["export LANG=\(q(unix))", "export LC_ALL=\(q(unix))", "export WINEUSERLOCALE=\(q(windows))"]
        }
        var settings = Self.settings(in: extraSettings).settings
        // The helper's DLLs and a WINEDLLOVERRIDES line the user wrote become one value.
        var overrides = dllOverrides.isEmpty ? "" : dllOverrides.joined(separator: ",") + "=n,b"
        if let i = settings.firstIndex(where: { $0.key == "WINEDLLOVERRIDES" }) {
            let own = settings.remove(at: i).value
            overrides = [overrides, own].filter { !$0.isEmpty }.joined(separator: ";")
        }
        // Added to the value that is there already: Steam Play's names the DLLs of its Steam bridge,
        // and a new value would cut the game off from Steam. Wine skips the empty entry when there
        // is none, and for a DLL that shows twice the last entry wins.
        if !overrides.isEmpty {
            out.append("export WINEDLLOVERRIDES=\"$WINEDLLOVERRIDES;\(Self.escapedForDoubleQuotes(overrides))\"")
        }
        for s in settings { out.append("export \(s.key)=\(q(s.value))") }
        if !out.isEmpty { out.insert("# Launch options and mods, from the game's page in Unwine.", at: 0) }
        return out
    }

    /// Profiles.render adds these lines to a game's profile. AppModel hands over every game's options
    /// whenever they change, and once at start before it writes the profiles.
    static func profileLines(for appID: Int?) -> [String] {
        guard let appID, let options = published.value[appID] else { return [] }
        return options.profileLines()
    }

    static func publish(_ all: [Int: LaunchOptions]) { published.value = all }

    private static let published = PublishedOptions()
}

/// The options Profiles.render reads, from any thread.
private final class PublishedOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [Int: LaunchOptions] = [:]

    var value: [Int: LaunchOptions] {
        get { lock.withLock { options } }
        set { lock.withLock { options = newValue } }
    }
}
