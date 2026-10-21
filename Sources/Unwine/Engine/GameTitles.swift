import Foundation

/// Game names: a program's ProductName made fit to show, folder names that say nothing about the
/// game in them, and the keys that find a game in Highball by its title.
enum GameTitles {
    // MARK: Names

    /// The first ProductName that names a game, tidied. Names of engines, installers and Windows
    /// itself do not count, and neither does a name with no letters or a name too long for a tile.
    static func product(from names: [String]) -> String? {
        for raw in names {
            let name = tidy(raw)
            guard name.count >= 2, name.count <= 80, name.contains(where: \.isLetter), !isGenericProduct(name) else { continue }
            return name
        }
        return nil
    }

    /// Without ™, ® and ©, and with each run of spaces, tabs or line breaks made one space.
    static func tidy(_ text: String) -> String {
        let marks: Set<Character> = ["\u{2122}", "\u{00AE}", "\u{00A9}", "\u{2120}"]
        return text.filter { !marks.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// ProductNames that name the tool a program was made with, not the game.
    private static let genericProducts: Set<String> = [
        "game", "games", "launcher", "game launcher", "application", "app", "program", "client", "game client", "player",
        "unity", "unityplayer", "unity player", "unreal", "ue4", "ue4game", "ue5", "ue5game", "bootstrappackagedgame",
        "godot engine", "gamemaker", "electron", "chromium", "node.js", "nw.js", "java", "python", "qt", "wine", "steam",
        "steamworks", "rpg maker", "rpg maker mv", "rpg maker mz", "rpg maker vx ace", "adobe air", "flash player",
        "win32", "win64", "x64", "x86", "shipping", "release", "debug",
    ]

    /// Words that only installers, runtimes and Windows' own programs put in their ProductName, and
    /// the text a programming template leaves there ("TODO: <Product name>").
    private static let toolWords = ["operating system", "visual c++", ".net framework", "directx", "redistributable",
                                    "runtime", "bootstrap", "inno setup", "nullsoft", "installshield", "install",
                                    "setup", "uninst", "unreal engine", "crash report", "todo", "product name", "<", ">"]

    static func isGenericProduct(_ name: String) -> Bool {
        let lower = name.lowercased()
        return genericProducts.contains(lower) || toolWords.contains(where: lower.contains)
    }

    /// Folder names that hold many things, or say only what kind of file is inside.
    private static let genericFolders: Set<String> = [
        "bin", "bin32", "bin64", "x64", "x86", "win32", "win64", "binaries", "game", "games", "release", "retail",
        "shipping", "debug", "system", "data", "downloads", "desktop", "documents", "applications", "app", "apps",
        "application", "program", "programs", "program files", "program files (x86)", "drive c", "drive_c", "c",
        "pfx", "compatdata", "steamapps", "common", "client", "pc", "windows", "win", "launcher", "content", "files",
        "install", "installer", "setup", "new folder", "untitled folder", "folder", "steam", "steam library", "gog",
        "gog games", "gog galaxy", "epic games", "my games", "temp", "tmp", "build", "builds", "dist", "output", "out",
        "portable", "unwine", "wine", "bottles", "localgames", "volumes", "users", "shared", "public",
    ]

    /// True for a folder name that says nothing about the game in it: "Game", "Downloads",
    /// "Program Files (x86)", only digits, or a long code of letters and digits.
    static func isGeneric(_ name: String) -> Bool {
        let lower = tidy(name).lowercased()
        if lower.isEmpty || genericFolders.contains(lower) || !lower.contains(where: \.isLetter) { return true }
        // "3f2a9c0e7b..." or a UUID: a code, not a name.
        let hex = lower.filter { $0.isHexDigit }.count
        return lower.count >= 16 && !lower.contains(" ") && hex >= lower.count - 4
    }

    // MARK: Keys for Highball

    /// A title cut down to what tells games apart: letters and digits only, in lower case, without
    /// accents, ™ or ®, without "The" at the start, and with Roman numbers as digits. So "The Witcher® 3",
    /// "Witcher 3" and "WITCHER III" give one key, and a folder named "HalfLife2" gives the key of
    /// "Half-Life 2". Nil for a title too short to tell anything.
    static func key(_ title: String) -> String? {
        memo.value(title) { compact(words(title)) }
    }

    /// Looser keys for one title, for the same game under a shorter name: without its "(...)" label
    /// ("Elite Dangerous (Odyssey)" gives the key of "Elite Dangerous"), and the part before a
    /// subtitle when that part holds a number ("The Witcher 3: Wild Hunt" gives the key of
    /// "Witcher 3"). A short name that can be another game gives no key: a name with no number,
    /// like "Star Wars", is shared by too many games; a year or a list in the label tells two games
    /// apart ("Prey (2017)", "Call of Duty (MW/Warzone)"); and a remaster's short name is the
    /// original game, a different program ("Diablo II: Resurrected").
    static func looseKeys(_ title: String) -> [String] {
        let whole = key(title)
        var keys: [String] = []
        var bare = title
        var tellsApart = false
        while let label = bare.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) {
            if bare[label].contains(where: { ($0.isASCII && $0.isNumber) || $0 == "/" }) { tellsApart = true }
            bare.removeSubrange(label)
        }
        if !tellsApart, bare != title, let k = key(bare), k != whole { keys.append(k) }
        if let cut = title.range(of: #":|\s[-\u{2013}\u{2014}]\s"#, options: .regularExpression) {
            let head = words(String(title[..<cut.lowerBound]))
            let tail = words(String(title[cut.upperBound...]))
            if head.count >= 2, head.contains(where: { $0.allSatisfy(\.isNumber) }), !tail.contains(where: rereleaseWords.contains),
               let k = compact(head), k != whole, !keys.contains(k) { keys.append(k) }
        }
        return keys
    }

    /// Words a remaster or a new edition puts in its subtitle.
    private static let rereleaseWords: Set<String> = ["remaster", "remastered", "resurrected", "definitive", "enhanced", "special",
                                                     "anniversary", "reforged", "redux", "remake", "retold", "hd"]

    /// The title's words, ready to compare.
    private static func words(_ title: String) -> [String] {
        // ² becomes 2 and full-width letters plain ones; apostrophes go, so "Assassin's" is one word.
        let plain = tidy(title).precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        // Split CamelCase and runs of letters and digits: "RomanceOfTheThreeKingdomsXIV", "Left4Dead2".
        let chars = Array(plain)
        var spaced = ""
        for (i, c) in chars.enumerated() {
            if i > 0 {
                let p = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if (p.isLowercase && c.isUppercase) || (p.isLetter && c.isNumber) || (p.isNumber && c.isLetter)
                    || (p.isUppercase && c.isUppercase && next.isLowercase) { spaced.append(" ") }
            }
            spaced.append(c)
        }
        let folded = spaced.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "&", with: " and ")
        var result = folded.split { !($0.isLetter || $0.isNumber) }.map { word in roman(String(word)).map(String.init) ?? String(word) }
        if result.count > 1, result[0] == "the" { result.removeFirst() }
        return result
    }

    private static func compact(_ words: [String]) -> String? {
        let key = words.joined()
        // Two signs are enough in Chinese, Japanese or Korean; in Latin letters, three.
        return key.count >= 3 || (key.count == 2 && key.contains(where: { !$0.isASCII })) ? key : nil
    }

    /// "ii" to "xxxix" as a number, in their usual spelling only. "i" stays a word ("I Am Bread").
    private static func roman(_ word: String) -> Int? {
        guard word.count <= 6, word != "i", !word.isEmpty, word.allSatisfy({ "ivx".contains($0) }) else { return nil }
        let value: [Character: Int] = ["i": 1, "v": 5, "x": 10]
        var total = 0, highest = 0
        for c in word.reversed() {
            let v = value[c] ?? 0
            if v < highest { total -= v } else { total += v; highest = v }
        }
        guard (2...39).contains(total) else { return nil }
        let ones = ["", "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix"][total % 10]
        return String(repeating: "x", count: total / 10) + ones == word ? total : nil
    }

    /// Keys are asked for on every redraw of an added game's advice, so each title is worked out once.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: String?] = [:]

        func value(_ title: String, _ make: () -> String?) -> String? {
            lock.lock()
            if let known = keys[title] { lock.unlock(); return known }
            lock.unlock()
            let made = make()
            lock.lock(); defer { lock.unlock() }
            if keys.count >= 4_000 { keys.removeAll() }
            keys.updateValue(made, forKey: title)
            return made
        }
    }

    private static let memo = Memo()
}

extension LocalGames {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents

    /// The name of the folder that names the game: the folder the user picked, else the program's
    /// own folder, going up past generic ones ("bin", "Game", "Program Files"). Nil when only generic
    /// folders, the home folder or a drive's own folder are left.
    static func folderName(for exe: URL, picked folder: URL? = nil) -> String? {
        if let folder, let name = telling(folder.standardizedFileURL) { return name }
        var dir = exe.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<5 {
            if neverNamesGame(dir) { return nil }
            if let name = telling(dir) { return name }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A folder's name when it can name a game.
    private static func telling(_ dir: URL) -> String? {
        guard !neverNamesGame(dir) else { return nil }
        let name = dir.lastPathComponent.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return GameTitles.isGeneric(name) ? nil : name
    }

    /// True for folders that never name a game: the home folder, the folders above it, and the top
    /// folder of the Mac or of a drive.
    private static func neverNamesGame(_ dir: URL) -> Bool {
        let parts = dir.pathComponents
        if parts.count <= home.count && Array(home.prefix(parts.count)) == parts { return true }
        return parts.count < 2 || (parts.count <= 3 && parts[1] == "Volumes")
    }

    /// The name a newly added program gets: the name of its game's folder. When every folder says
    /// nothing about the game ("Game", "Downloads"), the program's own ProductName, else its file name.
    static func defaultName(for exe: URL, picked folder: URL?) -> String {
        if let name = folderName(for: exe, picked: folder) { return name }
        if let product = GameTitles.product(from: PEInspector.resources(exe, icons: false)?.productNames ?? []) { return product }
        let base = exe.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? exe.lastPathComponent : base
    }

    /// The Steam app id in a steam_appid.txt next to the program. Steam games keep this file for
    /// their developers, and copies of the games often keep it too.
    static func steamAppID(nextTo exe: URL) -> Int? {
        let file = exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard let id = Int(String(text.prefix { $0.isASCII && $0.isNumber })), id > 0, id < idBase else { return nil }
        return id
    }
}
