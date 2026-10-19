import SwiftUI

// MARK: - Palette

enum Palette {
    static let wine = Color(red: 0.878, green: 0.208, blue: 0.373)      // #E0355F
    static let wineDeep = Color(red: 0.557, green: 0.059, blue: 0.200)  // #8E0F33
    static let cream = Color(red: 1.0, green: 0.957, blue: 0.902)       // #FFF4E6
    static let gold = Color(red: 1.0, green: 0.906, blue: 0.780)        // #FFE7C7
    static let night = Color(red: 0.071, green: 0.016, blue: 0.043)     // #12040B
    static let plum = Color(red: 0.165, green: 0.031, blue: 0.094)      // #2A0818
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)
    static let muted = Color.white.opacity(0.62)
    static let ok = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.38)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.plum, Palette.night], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.wine.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Decanter mark (the "breathing" wait indicator)

/// The decanter outline from the app icon, in a 0...1 unit square.
struct DecanterShape: Shape {
    func path(in r: CGRect) -> Path {
        // Icon coordinates span x 282...742, y 236...812 (460 x 576).
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let s = min(r.width / 460, r.height / 576)
            let ox = r.midX - 230 * s, oy = r.midY - 288 * s
            return CGPoint(x: ox + (x - 282) * s, y: oy + (y - 236) * s)
        }
        var path = Path()
        path.move(to: p(452, 236))
        path.addLine(to: p(572, 236))
        path.addQuadCurve(to: p(552, 270), control: p(576, 262))
        path.addLine(to: p(552, 420))
        path.addCurve(to: p(742, 640), control1: p(552, 470), control2: p(742, 500))
        path.addCurve(to: p(512, 812), control1: p(742, 760), control2: p(640, 812))
        path.addCurve(to: p(282, 640), control1: p(384, 812), control2: p(282, 760))
        path.addCurve(to: p(472, 420), control1: p(282, 500), control2: p(472, 470))
        path.addLine(to: p(472, 270))
        path.addQuadCurve(to: p(452, 236), control: p(448, 262))
        path.closeSubpath()
        return path
    }
}

/// Decanter that fills with wine. `progress == nil` means "working, length unknown":
/// the wine gently sloshes and the glass breathes, so waiting never looks frozen.
struct DecanterMark: View {
    var progress: Double?
    var size: CGFloat = 88

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = progress == nil ? 1 + 0.035 * sin(t * 2.2) : 1
            let level = progress.map { 0.12 + 0.80 * $0 } ?? (0.42 + 0.06 * sin(t * 1.3))
            ZStack {
                DecanterShape().fill(Palette.cream.opacity(0.10))
                WaveFill(level: level, phase: t * 2.6)
                    .fill(LinearGradient(colors: [Palette.wine, Palette.wineDeep], startPoint: .top, endPoint: .bottom))
                    .mask(DecanterShape())
                DecanterShape().stroke(Palette.gold.opacity(0.9), style: StrokeStyle(lineWidth: max(2, size / 34), lineJoin: .round))
            }
            .frame(width: size * 0.8, height: size)
            .scaleEffect(breathe)
            .animation(.easeInOut(duration: 0.4), value: progress)
        }
        .accessibilityLabel(progress.map { "Progress \(Int($0 * 100)) percent" } ?? "Working")
    }
}

/// A liquid body with a sine-wave surface. `level` is 0 (empty) ... 1 (full).
struct WaveFill: Shape {
    var level: Double
    var phase: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        let surface = r.maxY - r.height * level
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        let steps = 24
        for i in 0...steps {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(steps)
            let y = surface + sin(Double(i) / Double(steps) * .pi * 2 + phase) * r.height * 0.018
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Progress track

/// Known progress shows a filling bar; unknown progress shows a travelling highlight.
struct ProgressTrack: View {
    var progress: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let progress {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.wine, Palette.gold], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
                        .animation(.easeOut(duration: 0.35), value: progress)
                } else {
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let w = geo.size.width * 0.28
                        let x = (t.truncatingRemainder(dividingBy: 1.6) / 1.6) * (geo.size.width + w) - w
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, Palette.wine, Palette.gold, .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w)
                            .offset(x: x)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Rotating phase words

/// Cycles through short status lines so long waits keep telling you something.
struct PhaseWords: View {
    let words: [String]
    var interval: Double = 2.6

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { tl in
            let i = words.isEmpty ? 0 : Int(tl.date.timeIntervalSinceReferenceDate / interval) % words.count
            Text(words.isEmpty ? "" : words[i])
                .id(i)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.35), value: i)
        }
    }
}

// MARK: - Skeleton shimmer for art that is still loading

struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let x = (t.truncatingRemainder(dividingBy: 1.4) / 1.4) * geo.size.width * 2 - geo.size.width
                ZStack {
                    Palette.card
                    LinearGradient(colors: [.clear, Color.white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width)
                        .offset(x: x)
                }
            }
        }
    }
}

// MARK: - Buttons and pills

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(Palette.night)
            .background(Capsule().fill(enabled ? Palette.cream : Palette.cream.opacity(0.35)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(enabled ? Palette.cream : Palette.muted)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(Palette.stroke))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay {
                    if pulsing {
                        TimelineView(.animation) { tl in
                            let s = 1 + (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4) * 1.6
                            Circle().stroke(color.opacity(2 - s), lineWidth: 1.5).scaleEffect(s)
                        }
                    }
                }
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().stroke(Palette.stroke))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.stroke))
    }
}
