import CoreGraphics
import Foundation

/// What Unwine suggests for one game: a graphics layer, two ready-made settings and plain tips.
struct Advice: Equatable, Sendable {
    /// A short, plain-English note about the game.
    struct Tip: Equatable, Sendable {
        enum Kind: String, Sendable {
            case info       // good to know
            case warning    // may stop the game or online play
            case fix        // what to try when a known problem shows up
        }

        let kind: Kind
        let text: String
        var link: URL? = nil
    }

    /// Whether online play can work, judged from the game's anti-cheat.
    enum OnlineVerdict: Equatable, Sendable {
        case fine                       // no anti-cheat found
        case needsOnlineMode(String)    // works only with Windows Steam inside Unwine; names the anti-cheat ("VAC")
        case blocked([String])          // Highball says this anti-cheat cannot work on a Mac; the names say which
        case publisherBlocked           // the publisher stops the game on macOS on purpose, offline too
        case unknown                    // anti-cheat that may or may not work, or nothing known about the game yet
    }

    var renderer: Renderer
    var rendererReason: String
    var performance: GameSettings       // the fastest this Mac can run it
    var battery: GameSettings           // cooler, and longer on battery
    var tips: [Tip]                     // warnings first, then fixes, then good-to-know
    var online: OnlineVerdict
    var source: String                  // who the advice comes from, for the UI to credit
    var needsGPTK = false               // D3DMetal would run this game, but GPTK is not added yet
}

typealias OnlineVerdict = Advice.OnlineVerdict

enum Advisor {
    private typealias Tip = Advice.Tip

    /// Games with Valve Anti-Cheat (VAC). VAC wants a real Windows Steam client, which only Online mode
    /// provides. Every id here showed "Valve Anti-Cheat enabled" (category 8) in the Steam store API
    /// (store.steampowered.com/api/appdetails) when checked on 20 October 2026. Highball's own VAC
    /// entries cover other games while its list is loaded.
    private static let valveVACApps: Set<Int> = [
        // GoldSrc: Counter-Strike, Team Fortress Classic, Day of Defeat, Deathmatch Classic, Opposing Force,
        // Ricochet, Half-Life, Condition Zero and its Deleted Scenes.
        10, 20, 30, 40, 50, 60, 70, 80, 100,
        // Source: Counter-Strike: Source, Day of Defeat: Source, Half-Life 2: Deathmatch, Half-Life Deathmatch:
        // Source, Team Fortress 2, Left 4 Dead and Left 4 Dead 2.
        240, 300, 320, 360, 440, 500, 550,
        // Dota 2 and Counter-Strike 2.
        570, 730,
        // Source and GoldSrc games from others: Garry's Mod, Insurgency, Synergy, Zombie Panic! Source,
        // No More Room in Hell, Sven Co-op, Dark Messiah of Might and Magic, Dino D-Day, Red Orchestra 2.
        4000, 222880, 17520, 17500, 224260, 225840, 2100, 70000, 35450,
        // Popular games with VAC: Natural Selection 2, Killing Floor 1 and 2, Unturned, DayZ, ARK: Survival
        // Evolved, Rust, Call of Duty: Modern Warfare 2 (2009) and Black Ops II.
        4920, 1250, 232090, 304930, 221100, 346110, 252490, 10180, 202970,
    ]

    /// Pure and cheap (well under a millisecond), so the UI can call it on every redraw.
    static func advise(appID: Int, name: String, analysis: GameAnalysis?, highball: HighballGame?,
                       hasD3DMetal: Bool, d3dmetalIsV4: Bool, screenPixels: CGSize) -> Advice {
        let title = name.isEmpty ? "This game" : name
        let api = analysis?.api ?? .unknown
        let is32Bit = analysis.map { !$0.is64Bit } ?? false
        let digest = highball.map { HighballNotes.digest(of: $0.notes) }
        let pick = pickRenderer(api: api, analysis: analysis, highball: highball, hasD3DMetal: hasD3DMetal)
        let renderer = pick.renderer
        let reason = pick.reason + caveats(highball: highball, digest: digest)

        var performance = GameSettings()
        performance.renderer = renderer
        performance.msync = true
        performance.advertiseAVX = true
        performance.metalHUD = false
        performance.metalFX = false
        performance.metal4 = true       // the default. Unwine exports it only for GPTK 4, so it does nothing without
        performance.fpsCap = nil

        // 60 fps divides 60 and 120 Hz screens and stays smooth for action games.
        let cap = 60
        // MetalFX reaches a game only through DLSS, and only D3DMetal and DXMT pass that on. On DXMT the
        // switch also makes the game see an NVIDIA card, which DXMT says not to leave on for every game,
        // so the battery set turns it on only when the game ships DLSS.
        let upscales = (api == .dx11 || api == .dx12) && (renderer == .d3dmetal || renderer == .dxmt)
            && analysis?.hasDLSS == true
        // DXMT and DXVK take a cap from Unwine. D3DMetal does from GPTK 4. WineD3D, older D3DMetal and
        // DirectX 12 on the DXVK layer (Wine's own DirectX 12 draws there, not DXVK) have nothing Unwine
        // can set, so the battery set leaves the cap off there.
        let canCap = renderer != .wined3d && !(renderer == .d3dmetal && !d3dmetalIsV4) && !(renderer == .dxvk && api == .dx12)
        var battery = performance
        battery.metalFX = upscales
        battery.fpsCap = canCap ? cap : nil
        // Ray tracing is the largest GPU cost in the games that use it, and Apple's default is on from M3.
        if renderer == .d3dmetal { battery.rayTracing = false }
        // DXMT's tessellation (extra triangles for fine surface detail) up to 16x, not 64x.
        if renderer == .dxmt && api == .dx11 { battery.maxTessFactor = 16 }

        let (online, onlineTips) = onlineAdvice(appID: appID, title: title, analysis: analysis, highball: highball)
        var tips = onlineTips
        for sentence in digest?.warnings ?? [] {
            tips.append(Tip(kind: .warning, text: "Highball notes: \(sentence)", link: highball?.url))
        }

        if let help = workshopTip(appID: appID) {
            tips.append(Tip(kind: .fix, text: help))
        }
        let half = halfScreen(screenPixels)
        // Advice, not rules: many 32-bit games run fine at full Retina size.
        if is32Bit {
            let lower = half.map { ", for example to \($0.w)x\($0.h)" } ?? ""
            tips.append(Tip(kind: .fix, text: "This is a 32-bit game, so it has less memory to work with. If it crashes at full Retina size or on big maps, lower the in-game resolution\(lower)."))
        }
        let withCap = battery.fpsCap.map { " with a \($0) fps cap" } ?? ""
        let sharpen = renderer == .dxmt && (api == .dx10 || api == .dx11) ? " MetalFX sharpening, in Apple extras, keeps it sharp." : ""
        if let half {
            tips.append(Tip(kind: .info, text: "To save battery, you can run at \(half.w)x\(half.h) (half your screen)\(withCap). That is a quarter of the pixels to draw.\(sharpen)"))
        } else {
            tips.append(Tip(kind: .info, text: "To save battery, you can run at half your screen's resolution\(withCap).\(sharpen)"))
        }
        if battery.fpsCap == nil {
            let why = renderer == .wined3d ? "Unwine has no frame cap for WineD3D."
                : renderer == .dxvk ? "Wine's own DirectX 12 part draws this game, and Unwine cannot cap it."
                : "Frame caps need GPTK 4. Yours is older, so Unwine cannot cap the frame rate with D3DMetal."
            tips.append(Tip(kind: .info, text: "\(why) If the game has its own frame limit, use that to save battery."))
        }
        if battery.metalFX {
            tips.append(Tip(kind: .info, text: "This game has DLSS. Best battery turns on MetalFX for DLSS. Set the game to DLSS to get the gain."))
        }
        if let summary = digest?.summary {
            tips.append(Tip(kind: .info, text: "Highball notes: \(summary)", link: highball?.url))
        }

        let base = analysis != nil ? "Unwine's file check" : "Unwine's default"
        let source = pick.fromHighball ? "Highball database (CC0)" : (highball != nil ? "\(base) and Highball database (CC0)" : base)
        return Advice(renderer: renderer, rendererReason: reason, performance: performance, battery: battery,
                      tips: inOrder(tips), online: online, source: source, needsGPTK: pick.needsGPTK)
    }

    /// Warnings first, then fixes, then good-to-know. Each group keeps the order it was added in.
    private static func inOrder(_ tips: [Tip]) -> [Tip] {
        func rank(_ kind: Tip.Kind) -> Int {
            switch kind {
            case .warning: return 0
            case .fix: return 1
            case .info: return 2
            }
        }
        return tips.enumerated().sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
    }

    /// Left 4 Dead 1 and 2 and Garry's Mod load Workshop add-ons, and a broken one is a common reason
    /// for a crash on a map. Other Source games have no such menu.
    private static func workshopTip(appID: Int) -> String? {
        switch appID {
        case 500, 550: return "If a campaign or map crashes while loading, try turning off Workshop add-ons in the game's Add-ons menu."
        case 4000: return "If a map crashes while loading, try turning off Workshop addons in the game's Addons menu."
        default: return nil
        }
    }

    // MARK: Renderer

    private struct Pick {
        var renderer: Renderer
        var reason: String
        var fromHighball: Bool
        var needsGPTK = false       // D3DMetal is the better layer, and only a GPTK import is missing
    }

    /// Highball's suggested layer wins, unless it is unusable here. Then the game's own files decide.
    private static func pickRenderer(api: GraphicsAPI, analysis: GameAnalysis?, highball: HighballGame?,
                                     hasD3DMetal: Bool) -> Pick {
        let byFiles = rendererFromFiles(api: api, analysis: analysis, hasD3DMetal: hasD3DMetal)
        guard let highball, !highball.status.isBlocked, let wanted = highball.renderer?.lowercased() else { return byFiles }

        // Only a tested entry says "tested". Highball's page recommends a layer even for games that fail.
        func said(_ layer: String, then more: String = "") -> String {
            let first = highball.status == .verifiedLocal ? "Highball tested this game on a real Mac with \(layer)."
                                                          : "Highball lists \(layer) for this game."
            return first + more
        }
        switch wanted {
        case "dxmt": return Pick(renderer: .dxmt, reason: said("DXMT"), fromHighball: true)
        case "dxvk": return Pick(renderer: .dxvk, reason: said("DXVK"), fromHighball: true)
        case "wined3d": return Pick(renderer: .wined3d, reason: said("WineD3D"), fromHighball: true)
        case "vkd3d":
            return Pick(renderer: .dxvk, reason: said("vkd3d (DirectX 12 over Vulkan)", then: " DXVK is Unwine's closest match."), fromHighball: true)
        case "d3dmetal":
            let is64 = analysis?.is64Bit ?? true
            if hasD3DMetal && is64 { return Pick(renderer: .d3dmetal, reason: said("D3DMetal"), fromHighball: true) }
            let why = is64 ? "Apple's Game Porting Toolkit is not added yet"
                           : "this game is 32-bit and D3DMetal runs 64-bit games only"
            return Pick(renderer: byFiles.renderer, reason: "Highball suggests D3DMetal, but \(why). Unwine uses \(byFiles.renderer.title) instead.",
                        fromHighball: false, needsGPTK: is64)
        default:
            return byFiles
        }
    }

    /// What to add after the reason when Highball's own result may not carry over: its notes say the
    /// game fails, or its test needed a recipe (extra setup) that Unwine does not apply.
    private static func caveats(highball: HighballGame?, digest: NoteDigest?) -> String {
        guard let highball else { return "" }
        var text = ""
        if digest?.opensWithFailure == true {
            text += " Highball's notes say the game does not start or crashes."
        }
        if highball.hasRecipe {
            text += " Highball also sets this game up with a recipe: extra steps that Unwine does not apply. Yours may behave differently."
        }
        return text
    }

    /// The same choice Unwine's Automatic makes, with the reason in words.
    private static func rendererFromFiles(api: GraphicsAPI, analysis: GameAnalysis?, hasD3DMetal: Bool) -> Pick {
        let renderer = Profiles.resolve(.auto, analysis: analysis, hasD3DMetal: hasD3DMetal)
        let reason: String
        var needsGPTK = false
        switch api {
        case .dx12:
            // DXVK has no DirectX 12. On its layer, Wine's own DirectX 12 part (vkd3d) draws over Vulkan.
            let fallback = "Wine's own DirectX 12 part tries to run it over Vulkan, because DXVK has no DirectX 12. The game may run slowly or not start."
            if renderer == .d3dmetal {
                reason = "DirectX 12 game. D3DMetal is Apple's layer for it."
            } else if analysis?.is64Bit == false {
                reason = "DirectX 12 game, but it is 32-bit, and D3DMetal runs 64-bit games only. \(fallback)"
            } else {
                reason = "DirectX 12 game. Apple's D3DMetal runs it best. It comes in GPTK 4, which is not added yet. Until then, \(fallback)"
                needsGPTK = true
            }
        case .dx11: reason = "DirectX 11 game. DXMT translates it straight to Metal."
        case .dx10: reason = "DirectX 10 game. DXMT handles DirectX 10 and 11."
        case .dx9: reason = "DirectX 9 game. The DXMT profile also carries DXVK's DirectX 9 layer, which runs it."
        case .dx8: reason = "DirectX 8 game. The DXMT profile also carries DXVK's DirectX 9 layer, the closest match."
        case .opengl: reason = "OpenGL game. Wine hands OpenGL to macOS directly, so WineD3D is enough."
        case .vulkan: reason = "Vulkan game. Vulkan goes straight to the KosmicKrisp driver, so no DirectX layer is needed."
        case .unknown:
            reason = analysis == nil
                ? "Unwine has not looked inside this game yet, so it starts with DXMT. That suits most games."
                : "Unwine could not tell which graphics API this game uses, so it starts with DXMT. That suits most games."
        }
        return Pick(renderer: renderer, reason: reason, fromHighball: false, needsGPTK: needsGPTK)
    }

    // MARK: Online play

    /// Highball's own call comes first, because it has seen the anti-cheat run (or fail). Names found
    /// only in the game's files never block a game: a file name cannot say whether this one runs on a
    /// Mac, so they give "may not work" and nothing stronger.
    private static func onlineAdvice(appID: Int, title: String, analysis: GameAnalysis?,
                                     highball: HighballGame?) -> (OnlineVerdict, [Tip]) {
        let link = highball?.url
        let highballNames = unique(highball?.anticheat?.names ?? [])
        let fileNames = unique(analysis?.antiCheat ?? [])
        let besidesVAC = highballNames.filter { !isVAC($0) }

        if highball?.status == .blockedPublisher {
            return (.publisherBlocked,
                    [Tip(kind: .warning, text: "The publisher stops \(title) from running on macOS. No compatibility layer changes that.", link: link)])
        }
        if highball?.status == .blockedAnticheat || highball?.anticheat?.macVerdict?.lowercased() == "blocked" {
            let names = [besidesVAC, highballNames, fileNames].first { !$0.isEmpty } ?? ["Anti-cheat"]
            return (.blocked(names),
                    [Tip(kind: .warning, text: "\(list(names)) cannot run on a Mac, so online play is blocked. No compatibility layer can change that.", link: link)])
        }
        // Valve's anti-cheat checks for a real Windows Steam client. Online mode runs one, as CrossOver does.
        if highballNames.contains(where: isVAC) || valveVACApps.contains(appID) {
            var tips = [Tip(kind: .warning, text: "Online play needs Online mode: Windows Steam inside Unwine, like CrossOver.")]
            if !besidesVAC.isEmpty {
                tips.append(Tip(kind: .warning, text: "\(title) also uses \(list(besidesVAC)). Online play may not work.", link: link))
            } else if !fileNames.isEmpty {
                tips.append(Tip(kind: .warning, text: "\(title) also has files from \(list(fileNames)). Online play may not work.", link: link))
            }
            return (.needsOnlineMode("VAC"), tips)
        }
        // Seen by Highball, but not a dead end: some of these work in their user-space form.
        if highball?.anticheat != nil {
            let names = highballNames.isEmpty ? fileNames : highballNames
            return (.unknown, [Tip(kind: .warning, text: "\(title) uses \(list(names)). Online play may not work.", link: link)])
        }
        if !fileNames.isEmpty {
            return (.unknown, [Tip(kind: .warning, text: "\(title) has files from \(list(fileNames)). Online play may not work.", link: link)])
        }
        return (analysis != nil || highball != nil ? .fine : .unknown, [])
    }

    private static func isVAC(_ name: String) -> Bool {
        ["vac", "valve anti-cheat"].contains(name.lowercased())
    }

    /// Drops repeats ("RICOCHET" and "Ricochet") and blanks, keeping the order.
    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// "A", "A and B", "A, B and C".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "anti-cheat"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    // MARK: Text

    /// Half the screen each way, e.g. 1512x982 for a 3024x1964 panel. Nil when the size is not known.
    private static func halfScreen(_ pixels: CGSize) -> (w: Int, h: Int)? {
        guard pixels.width >= 640, pixels.height >= 400 else { return nil }
        return (Int((pixels.width / 2).rounded()), Int((pixels.height / 2).rounded()))
    }
}

// MARK: - Highball notes

/// What Unwine takes from the free text of one Highball entry.
struct NoteDigest: Equatable, Sendable {
    /// The first one or two sentences that are not warnings, about 220 characters at most.
    var summary: String?
    /// Sentences that warn of a ban or say to keep the game offline, two at most, in the notes' own words.
    var warnings: [String]
    /// The notes open by saying the game does not start, crashes or is not playable.
    var opensWithFailure: Bool
}

enum HighballNotes {
    /// `read` for the Advisor, which runs on every redraw. The same few hundred notes come up over
    /// and over, so each is read once.
    static func digest(of notes: String) -> NoteDigest { memo.digest(for: notes) }

    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: NoteDigest] = [:]

        func digest(for notes: String) -> NoteDigest {
            lock.lock()
            let known = stored[notes]
            lock.unlock()
            if let known { return known }
            let made = HighballNotes.read(notes)
            lock.lock(); defer { lock.unlock() }
            if stored.count >= 2_000 { stored.removeAll() }     // the list has about 500 games
            stored[notes] = made
            return made
        }
    }

    private static let memo = Memo()

    static func read(_ notes: String, summaryLimit: Int = 220, warningLimit: Int = 300) -> NoteDigest {
        let all = sentences(notes)
        guard !all.isEmpty else { return NoteDigest(summary: nil, warnings: [], opensWithFailure: false) }
        let parsed = all.map(words(in:))

        // A risk sentence is shown as a warning of its own, so the summary leaves it out.
        var warnings: [String] = []
        var warned = Set<Int>()
        for (index, sentence) in all.enumerated() {
            guard let start = riskPhrase(in: parsed[index]) else { continue }
            warned.insert(index)
            if warnings.count < 2 { warnings.append(excerpt(sentence, aroundScalar: parsed[index].offsets[start], limit: warningLimit)) }
        }

        var summary = ""
        var taken = 0
        for (index, sentence) in all.enumerated() where !warned.contains(index) {
            let joined = summary.isEmpty ? sentence : summary + " " + sentence
            if taken > 0 && joined.count > summaryLimit { break }
            summary = joined
            taken += 1
            if taken == 2 { break }
        }
        if summary.count > summaryLimit {
            // One very long sentence: cut at a word boundary.
            let cut = summary.prefix(summaryLimit)
            let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            summary = trimmed.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) + "…"
        }

        let failing = parsed.prefix(2).contains { isFailureOpening($0.words) }
        return NoteDigest(summary: summary.isEmpty ? nil : summary, warnings: warnings, opensWithFailure: failing)
    }

    // MARK: Sentences

    /// Words that end in a period without ending the sentence.
    private static let abbreviations: Set<String> = ["e.g", "i.e", "vs", "cf", "approx", "ca", "dr", "mr", "mrs", "ms",
                                                     "jr", "sr", "st", "inc", "ltd", "co", "est", "fig"]

    /// Splits at a full stop, "!" or "?" that is followed by a space and then something that is not a
    /// lower-case letter, and that has no space before it. So ".NET", "v1.2", "4.8" and "e.g. DXVK"
    /// stay inside their sentence.
    static func sentences(_ notes: String) -> [String] {
        let s = flatten(notes)
        var result: [String] = []
        var start = 0
        var i = 0
        func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }
        while i < s.count {
            guard isTerminator(s[i]) else { i += 1; continue }
            // The whole run ("...", "?!") and any closing quote or bracket after it.
            var runEnd = i
            while runEnd + 1 < s.count, isTerminator(s[runEnd + 1]) { runEnd += 1 }
            var after = runEnd + 1
            while after < s.count, isCloser(s[after]) { after += 1 }
            guard after < s.count else { break }
            if s[after] == " ", endsSentence(s, sentenceStart: start, terminator: i, runEnd: runEnd, nextWord: after + 1) {
                result.append(text(start..<after))
                start = after + 1
                i = start
            } else {
                i = after
            }
        }
        if start < s.count { result.append(text(start..<s.count)) }
        return result
    }

    /// The text with every run of whitespace (spaces, tabs, line breaks) turned into one space.
    private static func flatten(_ text: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var gap = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isSpace = v < 0x80 ? (v == 0x20 || (v >= 0x09 && v <= 0x0D)) : scalar.properties.isWhitespace
            if isSpace { gap = !out.isEmpty; continue }
            if gap { out.append(" "); gap = false }
            out.append(scalar)
        }
        return out
    }

    private static func isTerminator(_ c: Unicode.Scalar) -> Bool { c == "." || c == "!" || c == "?" }

    private static func isCloser(_ c: Unicode.Scalar) -> Bool {
        c == ")" || c == "]" || c == "}" || c == "\"" || c == "'" || c == "\u{201D}" || c == "\u{2019}"
    }

    private static func endsSentence(_ s: [Unicode.Scalar], sentenceStart: Int, terminator i: Int, runEnd: Int, nextWord: Int) -> Bool {
        // Something must come before it, and not a space (" .NET" is a name, not an ending).
        guard i > sentenceStart, s[i - 1] != " " else { return false }
        // A lower-case letter next means the sentence goes on ("approx. 30 fps", "vs. dxmt").
        var next = nextWord
        while next < s.count, s[next] == " " { next += 1 }
        if next < s.count, Character(s[next]).isLowercase { return false }
        if s[i] == "." && runEnd == i {
            var from = i
            while from > sentenceStart, s[from - 1].properties.isAlphabetic || s[from - 1] == "." { from -= 1 }
            var word = ""
            word.unicodeScalars.append(contentsOf: s[from..<i])
            if abbreviations.contains(word.lowercased()) { return false }
        }
        return true
    }

    /// At most `limit` characters of a long sentence, around the scalar at `offset`, cut at spaces.
    private static func excerpt(_ sentence: String, aroundScalar offset: Int, limit: Int) -> String {
        let s = Array(sentence.unicodeScalars)
        guard s.count > limit else { return sentence }
        var to = min(s.count, max(0, offset - limit / 2) + limit)
        var from = max(0, to - limit)
        while from > 0, from < offset, s[from - 1] != " " { from += 1 }
        while to < s.count, to > offset, s[to] != " " { to -= 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[from..<to])
        let middle = String(view).trimmingCharacters(in: .whitespaces)
        return (from > 0 ? "…" : "") + middle + (to < s.count ? "…" : "")
    }

    // MARK: Words

    private struct Words {
        var words: [String] = []
        var clauseStart: [Int] = []     // the first word of each word's clause
        var offsets: [Int] = []         // where each word starts in the sentence, in unicode scalars
    }

    private static let clauseBreaks: Set<Unicode.Scalar> = [",", ";", ":", "(", ")", "[", "]", "\u{2014}", "\u{2013}"]
    private static let clauseWords: Set<String> = ["but", "however", "although", "though", "yet", "except", "while", "whereas"]

    /// Lower-case words, with where each clause starts. A comma, bracket, dash or a word like "but"
    /// starts a new clause, which is how far a "no" or "without" reaches.
    private static func words(in sentence: String) -> Words {
        var result = Words()
        var buffer: [UInt8] = []
        var wordStart = 0
        var clause = 0
        var index = 0
        func flush() {
            defer { buffer.removeAll(keepingCapacity: true) }
            // Quote marks around a word are not part of it.
            var from = 0, to = buffer.count
            while from < to, buffer[from] == 0x27 { from += 1 }
            while to > from, buffer[to - 1] == 0x27 { to -= 1 }
            guard from < to else { return }
            let word = String(decoding: buffer[from..<to], as: UTF8.self)
            if clauseWords.contains(word) { clause = result.words.count }
            result.words.append(word)
            result.clauseStart.append(clause)
            result.offsets.append(wordStart + from)
        }
        for scalar in sentence.unicodeScalars {
            let v = scalar.value
            var piece: UInt8?
            var other: String?
            if v < 0x80 {
                if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || v == 0x27 { piece = UInt8(v) }
                else if v >= 0x41 && v <= 0x5A { piece = UInt8(v + 0x20) }
            } else if v == 0x2019 {
                piece = 0x27
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                other = scalar.properties.lowercaseMapping
            }
            if piece != nil || other != nil {
                if buffer.isEmpty { wordStart = index }
                if let piece { buffer.append(piece) } else if let other { buffer.append(contentsOf: other.utf8) }
            } else {
                flush()
                if clauseBreaks.contains(scalar) { clause = result.words.count }
            }
            index += 1
        }
        flush()
        return result
    }

    // MARK: Risk

    private static let negators: Set<String> = ["no", "not", "never", "without", "neither", "nor", "none", "nobody", "nothing", "zero"]
    private static let banEndings: Set<String> = ["ban", "bans", "banned"]
    private static let kickHelpers: Set<String> = ["get", "gets", "got", "getting", "be", "being", "been", "was", "were", "is", "are"]
    private static let onlyOffline: Set<String> = ["works", "work", "runs", "run", "plays", "play", "playable", "safe"]

    /// Where the first phrase that warns of a ban or says to stay offline begins, as a word index.
    /// The phrases are whole words: "banner", "Bandai" and "kick in" never match. A "no", "not" or
    /// "without" just before one cancels it, so "no ban risk" is not a warning.
    private static func riskPhrase(in w: Words) -> Int? {
        let words = w.words
        let n = words.count
        func at(_ i: Int) -> String { i >= 0 && i < n ? words[i] : "" }
        for i in 0..<n {
            let word = words[i], next = at(i + 1), after = at(i + 2)
            var start: Int?
            switch word {
            case "softban", "softbans", "softbanned", "softbanning", "permaban", "permabans", "permabanned", "banned", "banning", "bans":
                start = i
            case "soft", "perma", "permanent", "temporary", "account":
                if banEndings.contains(next) { start = i }
            case "ban":
                if ["risk", "risks", "wave", "waves"].contains(next) { start = i }
            case "risk", "risks":
                if next == "of", after == "ban" || (["a", "an"].contains(after) && at(i + 3) == "ban") { start = i }
            case "kicked":
                if kickHelpers.contains(at(i - 1)) { start = i - 1 }
            case "kicks":
                if ["you", "players", "users", "accounts"].contains(next) { start = i }
            case "keep", "keeps", "keeping":
                if (1...4).contains(where: { at(i + $0) == "offline" && w.clauseStart[min(i + $0, n - 1)] == w.clauseStart[i] }) { start = i }
            case "stay", "stays", "staying":
                if next == "offline" { start = i }
            case "only":
                if next == "offline" || (onlyOffline.contains(next) && after == "offline") { start = i }
            case "offline":
                if next == "only" { start = i }
            default:
                break
            }
            if let start, !isNegated(w, at: start) { return start }
        }
        return nil
    }

    private static func isNegated(_ w: Words, at start: Int) -> Bool {
        var j = start - 1
        let floor = max(w.clauseStart[start], start - 5)
        while j >= floor {
            let word = w.words[j]
            // "cannot rule out a ban risk" is a warning, not a denial.
            if ["rule", "ruled", "ruling"].contains(word) { return false }
            if negators.contains(word) || word.hasSuffix("n't") { return true }
            j -= 1
        }
        return false
    }

    // MARK: Failure

    private static let startVerbs: Set<String> = ["start", "launch", "boot", "run", "work", "open", "load"]

    /// "Does not start.", "Crashes on launch.", "Unplayable ...": the sentence's own opening says the
    /// game fails. A later mention, or a fix ("crash on launch fixed"), does not count.
    private static func isFailureOpening(_ w: [String]) -> Bool {
        guard let first = w.first, !w.contains(where: { $0 == "fixed" || $0 == "resolved" }) else { return false }
        let second = w.count > 1 ? w[1] : "", third = w.count > 2 ? w[2] : ""
        switch first {
        case "does", "did", "will", "would": return second == "not" && startVerbs.contains(third)
        case "doesn't", "didn't", "won't", "wouldn't", "cannot", "can't": return startVerbs.contains(second)
        case "fails", "failed", "fail": return second == "to" && startVerbs.contains(third)
        case "crash", "crashes", "crashed", "crashing", "unplayable": return true
        default:
            // "Launches, not playable."
            let head = Array(w.prefix(4))
            return zip(head, head.dropFirst()).contains { $0 == "not" && $1 == "playable" }
        }
    }
}

// MARK: - This Mac

/// The Mac's chip as the kernel names it ("Apple M4 Pro"). Apple's ray tracing default follows it.
enum MacChip {
    static let name: String? = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.hasPrefix("Apple M") ? text : nil
    }()

    /// The chip's generation: 4 for an M4 Pro. Nil when the name does not say.
    static let generation: Int? = name.flatMap { Int($0.dropFirst("Apple M".count).prefix { $0.isNumber }) }

    /// D3DMetal turns DirectX ray tracing on by default from M3, the first chips with ray tracing in
    /// hardware, and off on M1 and M2 (Apple's GPTK Read Me).
    static var raysByDefault: Bool? { generation.map { $0 >= 3 } }
}
