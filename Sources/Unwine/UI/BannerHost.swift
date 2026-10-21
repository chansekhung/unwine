import SwiftUI

/// The banner under a window's header. Its colour says what kind of message it is, its button takes
/// the next step, and an info message hides by itself once people had time to read it.
struct BannerHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            BannerStrip(notice: notice) { model.hideBanner(notice.id) }
        }
    }
}

/// The banner for call sites that pass its text (Settings). It shows the model's banner, with its
/// kind and button, when the text is the same.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    let text: String
    let close: () -> Void

    var body: some View {
        BannerStrip(notice: model.notice.flatMap { $0.text == text ? $0 : nil } ?? Banner(text: text, kind: Banner.kind(of: text)),
                    close: close)
    }
}

struct BannerStrip: View {
    let notice: Banner
    let close: () -> Void
    @State private var hovering = false
    @MainActor private static var announced: UUID?

    private var color: Color {
        switch notice.kind {
        case .info: return Palette.accent
        case .success: return Palette.ok
        case .problem: return Palette.error
        }
    }

    private var icon: String {
        switch notice.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(notice.kind == .info ? Palette.glow : color)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let action = notice.action {
                Button(action.title) {
                    action.run()
                    close()
                }
                .buttonStyle(BannerButtonStyle())
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("Hide this message")
                .accessibilityLabel("Hide this message")
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(color.opacity(notice.kind == .info ? 0.25 : 0.2))
        .onHover { hovering = $0 }
        .task(id: notice.id) { await hideWhenRead() }
    }

    /// VoiceOver reads a new banner once. An info banner then hides once people could read it: the
    /// time counts only while an Unwine window shows and the pointer is not on the banner.
    private func hideWhenRead() async {
        if Self.announced != notice.id {
            Self.announced = notice.id
            AccessibilityNotification.Announcement(notice.text).post()
        }
        guard notice.kind == .info else { return }
        var seen = 0.0
        while seen < notice.readingTime {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if AppVisibility.shared.visible && !hovering { seen += 0.5 }
        }
        close()
    }
}

private struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(Palette.night)
            .background(Capsule().fill(Palette.text.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
