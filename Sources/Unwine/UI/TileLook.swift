import SwiftUI

/// A game without a picture: its own colour, with its program's icon or its initials. `wide` is the
/// game page's header; otherwise a library tile.
struct ArtPlaceholder: View {
    let title: String
    let wide: Bool
    let icon: NSImage?

    var body: some View {
        let look = TileLook(title)
        ZStack {
            LinearGradient(colors: look.colors, startPoint: wide ? .leading : .top, endPoint: wide ? .trailing : .bottom)
            if let icon {
                GeometryReader { geo in
                    // An icon shows at most at its own size in points, and a tiny one at 48 points.
                    let pixels = max(1, icon.size.width)
                    let side = min(min(geo.size.width, geo.size.height) * (wide ? 0.55 : 0.5), max(48, pixels))
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(side / pixels >= 1.5 ? .none : .high)     // a small icon stays sharp
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: side / 10, y: side / 24)
                        .position(x: geo.size.width / 2, y: geo.size.height * (wide ? 0.4 : 0.45))
                }
            } else {
                Text(look.initials)
                    .font(.system(size: wide ? 44 : 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 12)
            }
        }
        .accessibilityHidden(true)      // the tile's name, below it, says which game it is
    }
}

/// How a game without a picture looks: a colour of its own, from its name, and its initials. The
/// same name always gives the same colour, and a launcher gets its game's colour.
struct TileLook {
    let colors: [Color]
    let initials: String

    init(_ title: String) {
        let base = Self.base(title)
        let hue = Self.hues[Int(Self.hash(base.lowercased()) % UInt64(Self.hues.count))]
        colors = [Color(hue: hue, saturation: 0.58, brightness: 0.50),
                  Color(hue: (hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.70, brightness: 0.19)]
        initials = Self.initials(base)
    }

    /// Hues that stay clear and calm at the tile's brightness: blues, violets, reds, amber, green, teal.
    private static let hues: [Double] = [0.60, 0.67, 0.75, 0.84, 0.93, 0.02, 0.08, 0.33, 0.45, 0.52]

    /// FNV-1a. Swift's own hash changes at every launch, so it cannot pick a colour that stays.
    private static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// The name without " · Launcher" or a "(...)" at the end, which Unwine adds to tell programs apart.
    private static func base(_ title: String) -> String {
        var t = title.components(separatedBy: " \u{00B7} ").first ?? title
        if t.hasSuffix(")"), let open = t.range(of: " (", options: .backwards) { t = String(t[..<open.lowerBound]) }
        return t.isEmpty ? title : t
    }

    private static let smallWords: Set<String> = ["of", "the", "and", "a", "an", "to", "in", "on", "for", "at", "by", "with",
                                                 "or", "from", "de", "la", "le", "les", "el", "der", "die", "das", "du", "von"]

    /// Up to three initials of the words that count: "Romance of the Three Kingdoms" gives "RTK",
    /// "Left 4 Dead 2" gives "L4D" and "Half-Life 2" gives "HL2". A short number counts whole; a
    /// Roman sequel number at the end does not count ("Final Fantasy VII" gives "FF"). A name in
    /// Chinese, Japanese or Korean, which has no spaces, gives its first two signs.
    static func initials(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let words = clean.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var kept = words.filter { !smallWords.contains($0.lowercased()) }
        if kept.isEmpty { kept = words }
        guard let first = kept.first else { return "?" }
        if kept.count == 1, let c = first.unicodeScalars.first, isEastAsian(c) { return String(first.prefix(2)) }
        var out = ""
        for (index, word) in kept.enumerated() {
            if word.allSatisfy(\.isNumber) {
                if out.count + word.count <= 3 { out += word }
                continue
            }
            if index > 0, index == kept.count - 1, isRoman(word) { continue }
            if out.count < 3, let c = word.first { out.append(c) }
        }
        return out.isEmpty ? String(first.prefix(1)).uppercased() : out.uppercased()
    }

    private static func isRoman(_ word: String) -> Bool {
        word.count <= 6 && word.uppercased().allSatisfy { "IVX".contains($0) }
    }

    private static func isEastAsian(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
