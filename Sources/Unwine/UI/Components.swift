import SwiftUI
import AppKit

// MARK: - Palette

enum Palette {
    static let accent = Color(red: 0.184, green: 0.420, blue: 1.0)      // #2F6BFF electric cobalt
    static let accentDeep = Color(red: 0.086, green: 0.227, blue: 0.620) // #163A9E
    static let text = Color(red: 0.945, green: 0.965, blue: 1.0)        // #F1F6FF
    static let glow = Color(red: 0.624, green: 0.894, blue: 1.0)        // #9FE4FF ice cyan
    static let night = Color(red: 0.016, green: 0.039, blue: 0.110)     // #040A1C
    static let deep = Color(red: 0.039, green: 0.102, blue: 0.251)      // #0A1A40
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)
    static let muted = Color.white.opacity(0.62)
    static let ok = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.38)
    static let error = Color(red: 1.0, green: 0.42, blue: 0.47)      // warm coral: reads as a fault on the blue
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.deep, Palette.night], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.accent.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Unwine mark (the wait indicator)

/// The app icon's coil: a corkscrew that unwinds into a straight line, in icon coordinates
/// (x 150...600, y 360...700 on the 1024 grid), scaled into the rect.
struct CoilShape: Shape {
    static let box = CGRect(x: 150, y: 360, width: 690, height: 344)

    func path(in r: CGRect) -> Path {
        let s = min(r.width / Self.box.width, r.height / Self.box.height)
        let ox = r.midX - Self.box.midX * s, oy = r.midY - Self.box.midY * s
        var path = Path()
        let steps = 260
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let taper: CGFloat = t < 0.48 ? 1 : (t > 0.84 ? 0 : 0.5 * (1 + cos(.pi * (t - 0.48) / 0.36)))
            let amp = 142 * (1 - 0.22 * t) * taper
            let phase = 2 * .pi * 3.25 * t - .pi / 2
            let x = 214 + 390 * t + 0.5 * amp * cos(phase), y = 532 + amp * sin(phase)
            let pt = CGPoint(x: ox + x * s, y: oy + y * s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

/// The play button the coil runs into, in the same coordinates as `CoilShape`.
struct PlayTip: Shape {
    func path(in r: CGRect) -> Path {
        let box = CoilShape.box
        let s = min(r.width / box.width, r.height / box.height)
        let ox = r.midX - box.midX * s, oy = r.midY - box.midY * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        let a = p(588, 397), b = p(588, 667), c = p(824, 532)
        path.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        path.addArc(tangent1End: c, tangent2End: b, radius: 38 * s)
        path.addArc(tangent1End: b, tangent2End: a, radius: 38 * s)
        path.addArc(tangent1End: a, tangent2End: c, radius: 38 * s)
        path.closeSubpath()
        return path
    }
}

/// The coil unwinds as work moves on: known progress lights the coil from the left, and the play
/// button lights up at the end. Unknown progress sends a light along the coil while the play button
/// breathes, so waiting never looks frozen.
struct UnwineMark: View {
    var progress: Double?
    var size: CGFloat = 88

    var body: some View {
        Group {
            // Known progress only redraws when it changes. Only the "working" light needs a clock.
            if let progress {
                mark(progress: progress, t: 0)
            } else {
                TimelineView(Motion.schedule) { timeline in mark(progress: nil, t: timeline.date.timeIntervalSinceReferenceDate) }
            }
        }
        .accessibilityLabel(progress.map { "Progress \(Int($0 * 100)) percent" } ?? "Working")
    }

    private func mark(progress: Double?, t: Double) -> some View {
        let line = max(2, size / 14)
        let lit = LinearGradient(colors: [Palette.glow, .white], startPoint: .leading, endPoint: .trailing)
        return ZStack {
            CoilShape().stroke(Palette.glow.opacity(0.16), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            if let progress {
                CoilShape().trim(from: 0, to: max(0.02, progress))
                    .stroke(lit, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .animation(.easeInOut(duration: 0.4), value: progress)
                PlayTip().fill(Color.white.opacity(0.25 + 0.75 * progress))
            } else {
                let head = (t * 0.45).truncatingRemainder(dividingBy: 1.25)
                CoilShape().trim(from: max(0, head - 0.25), to: min(1, head))
                    .stroke(lit, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                PlayTip().fill(Color.white.opacity(0.55 + 0.35 * (0.5 + 0.5 * sin(t * 2.4))))
            }
        }
        .shadow(color: Palette.glow.opacity(0.55), radius: size / 14)
        .frame(width: size, height: size * 0.62)
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
                        .fill(LinearGradient(colors: [Palette.accent, Palette.glow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
                        .animation(.easeOut(duration: 0.35), value: progress)
                } else {
                    TimelineView(Motion.schedule) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let w = geo.size.width * 0.28
                        let x = (t.truncatingRemainder(dividingBy: 1.6) / 1.6) * (geo.size.width + w) - w
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, Palette.accent, Palette.glow, .clear], startPoint: .leading, endPoint: .trailing))
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

// MARK: - Motion that stops when nobody sees it

/// Tracks whether any Unwine window can be seen. Endless animations pause while Unwine is hidden or
/// covered (for example by a full-screen game), so they cost the game nothing.
@MainActor @Observable
final class AppVisibility {
    static let shared = AppVisibility()
    private(set) var visible = true

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppVisibility.shared.visible = NSApp.occlusionState.contains(.visible) }
        }
    }
}

enum Motion {
    /// 30 frames a second is smooth enough for a loading light, and paused while no window shows.
    @MainActor static var schedule: AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 30, paused: !AppVisibility.shared.visible)
    }
}

// MARK: - Skeleton shimmer for art that is still loading

struct Shimmer: View {
    var body: some View {
        TimelineView(Motion.schedule) { tl in
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
            .background(Capsule().fill(enabled ? Palette.text : Palette.text.opacity(0.35)))
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
            .foregroundStyle(enabled ? Palette.text : Palette.muted)
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
                        TimelineView(Motion.schedule) { tl in
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
