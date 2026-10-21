import AppKit

/// Wine's Mac display choices for one game's bottle (HKEY_CURRENT_USER\Software\Wine\Mac Driver, and
/// the DPI in Control Panel\Desktop), from the game's Display section. Wine reads them for the whole
/// bottle when a process starts, so programs that share a bottle share them; a launcher's come from its game.
struct MacDriverValues: Equatable, Sendable {
    /// Wine's Retina mode. Nil leaves it alone: in Steam Play, NotProton sets RetinaMode at every start,
    /// from NOTPROTON_RETINA in Steam's launch options.
    var retinaMode: Bool?
    /// Windows text at 192 DPI (LogPixels), which Online mode's High Resolution Mode sets with Retina mode.
    /// Without it, Windows text in Retina mode comes out half its size.
    var highDPI = false
    var fillScreen = false
    var commandIsCtrl = false

    init(retinaMode: Bool?, highDPI: Bool, fillScreen: Bool, commandIsCtrl: Bool) {
        self.retinaMode = retinaMode
        self.highDPI = highDPI
        self.fillScreen = fillScreen
        self.commandIsCtrl = commandIsCtrl
    }

    /// One game's values. An added game's Retina mode is Unwine's to set. A Steam game's comes from
    /// Steam's launch options, and Unwine adds the 192 DPI that goes with it.
    init(settings s: GameSettings, appID: Int) {
        let local = LocalGames.isLocal(appID)
        self.init(retinaMode: local ? s.retina : nil, highDPI: local ? s.retina : SteamLaunchOptions.hasRetina(appID),
                  fillScreen: s.fillScreen, commandIsCtrl: s.commandIsCtrl)
    }

    static let macDriverKey = #"Software\Wine\Mac Driver"#
    static let desktopKey = #"Control Panel\Desktop"#

    /// The registry values, under Wine's own names. The Mac driver values must be strings, never DWORDs.
    var entries: [BottleRegistry.Entry] {
        func flag(_ name: String, _ on: Bool) -> BottleRegistry.Entry {
            BottleRegistry.Entry(key: Self.macDriverKey, name: name, value: .string(on ? "y" : "n"))
        }
        var out: [BottleRegistry.Entry] = []
        if let retinaMode { out.append(flag("RetinaMode", retinaMode)) }
        out.append(BottleRegistry.Entry(key: Self.desktopKey, name: "LogPixels", value: .dword(highDPI ? 192 : 96)))
        out.append(flag("CaptureDisplaysForFullscreen", fillScreen))
        out.append(flag("LeftCommandIsCtrl", commandIsCtrl))
        out.append(flag("RightCommandIsCtrl", commandIsCtrl))
        // Wine's Command keys are Alt by default. With both as Ctrl, a game gets an Alt key only when
        // the Option keys act as Alt (Wine's Mac driver logs the same advice).
        out.append(flag("LeftOptionIsAlt", commandIsCtrl))
        out.append(flag("RightOptionIsAlt", commandIsCtrl))
        return out
    }

    /// Wine's own defaults: a bottle Unwine never wrote to needs nothing for these.
    var isWineDefault: Bool { retinaMode != true && !highDPI && !fillScreen && !commandIsCtrl }

    /// "RetinaMode=y LogPixels=192 CaptureDisplaysForFullscreen=n ...", for the profile and the bottle's record.
    var line: String {
        entries.map { e -> String in
            switch e.value {
            case .string(let s): return "\(e.name)=\(s)"
            case .dword(let n): return "\(e.name)=\(n)"
            }
        }.joined(separator: " ")
    }

    init?(line: String) {
        var items: [String: String] = [:]
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { items[pair[0]] = pair[1] }
        }
        guard let fill = items["CaptureDisplaysForFullscreen"], let command = items["LeftCommandIsCtrl"] else { return nil }
        self.init(retinaMode: items["RetinaMode"].map { $0 == "y" }, highDPI: items["LogPixels"] == "192",
                  fillScreen: fill == "y", commandIsCtrl: command == "y")
    }

    /// The profile's comment line that carries these values to BottlePrep. Wine never reads it.
    static let profilePrefix = "# Mac display, written into the closed bottle before the game starts: "
    var profileLine: String { Self.profilePrefix + line }

    static func fromProfile(_ text: String) -> MacDriverValues? {
        for l in text.split(whereSeparator: \.isNewline) where l.hasPrefix(profilePrefix) {
            return MacDriverValues(line: String(l.dropFirst(profilePrefix.count)))
        }
        return nil
    }

    /// What Unwine last wrote into the bottle, kept inside it, so a fresh bottle starts with no record.
    static func recordFile(_ prefix: URL) -> URL { prefix.appendingPathComponent(".unwine-display") }

    static func recorded(in prefix: URL) -> MacDriverValues? {
        (try? String(contentsOf: recordFile(prefix), encoding: .utf8))
            .flatMap { MacDriverValues(line: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// True when the bottle does not hold these values yet. A bottle Unwine never wrote to holds Wine's defaults.
    func differs(from prefix: URL) -> Bool {
        guard let done = Self.recorded(in: prefix) else { return !isWineDefault }
        return done != self
    }
}

/// Steam Play's Retina mode lives in Steam's launch options for the game: NotProton's run script reads
/// NOTPROTON_RETINA there, and removes RetinaMode from the bottle at every start without it.
enum SteamLaunchOptions {
    static let retinaWord = "NOTPROTON_RETINA=1"

    /// True when Steam's saved launch options for the game set NOTPROTON_RETINA=1 before %command%
    /// (after it, Steam hands the text to the game instead).
    static func hasRetina(_ appID: Int) -> Bool {
        guard let options = options(for: appID), let command = options.range(of: "%command%") else { return false }
        return options[..<command.lowerBound].split(separator: " ").contains(Substring(retinaWord))
    }

    /// The whole line for the game's launch options box. It keeps what the box holds now: Steam hands
    /// options written without %command% to the game, so those go after it.
    static func retinaLine(for appID: Int) -> String {
        let now = (options(for: appID) ?? "").trimmingCharacters(in: .whitespaces)
        if now.contains("%command%") { return "\(retinaWord) \(now)" }
        return now.isEmpty ? "\(retinaWord) %command%" : "\(retinaWord) %command% \(now)"
    }

    static func copyRetinaLine(for appID: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(retinaLine(for: appID), forType: .string)
    }

    /// Steam's saved launch options for a game, from the newest userdata/<account>/config/localconfig.vdf.
    /// Steam saves that file from time to time, so a line pasted a moment ago can show up later.
    static func options(for appID: Int) -> String? {
        let fm = FileManager.default
        let userdata = SteamPlayPaths.steamData.appendingPathComponent("userdata", isDirectory: true)
        let files = ((try? fm.contentsOfDirectory(atPath: userdata.path)) ?? []).map {
            userdata.appendingPathComponent("\($0)/config/localconfig.vdf")
        }
        let dated = files.compactMap { url -> (url: URL, date: Date)? in
            ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date).map { (url, $0) }
        }
        guard let newest = dated.max(by: { $0.date < $1.date }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Parsed again only when Steam saved the file (about 70 KB).
        if cache?.url != newest.url || cache?.date != newest.date {
            var options: [Int: String] = [:]
            for (key, app) in VDF.parse(contentsOf: newest.url)?["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]?.entries ?? [] {
                if let id = Int(key), let text = app["LaunchOptions"]?.string { options[id] = text }
            }
            cache = (newest.url, newest.date, options)
        }
        return cache?.options[appID]
    }

    private static let lock = NSLock()
    private static var cache: (url: URL, date: Date, options: [Int: String])?
}
