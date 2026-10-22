import AppKit
import SwiftUI

/// The wait for an app started from its Mac app (Launchpad, the Dock, Finder). Unwine stays behind
/// then, so a small panel at the top of the screen shows the app's name and what Unwine does now, and
/// the start never looks stuck. The panel does not take the keyboard. It goes when the app's window
/// shows or the start ends; on a problem, Unwine comes forward with the reason.
@MainActor
enum StartPanel {
    private static var panels: [Int: NSPanel] = [:]
    private static let width: CGFloat = 400

    static func show(_ game: SteamGame, model: AppModel) {
        guard panels[game.id] == nil else { return }
        let host = NSHostingView(rootView: StartPanelView(game: game).environment(model))
        let height = max(80, host.fittingSize.height)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - width / 2, y: screen.maxY - height - 14))
        }
        panel.orderFrontRegardless()
        panels[game.id] = panel
    }

    static func hide(_ id: Int) {
        panels.removeValue(forKey: id)?.orderOut(nil)
    }
}

private struct StartPanelView: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let step = model.localStarting[game.id] ?? "Getting \(game.name) ready…"
        HStack(spacing: 14) {
            UnwineMark(progress: nil, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Opening \(game.name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                // A question from macOS stays in view until it is answered; other steps take turns.
                PhaseWords(words: step.hasPrefix("macOS asks") ? [step] : [step, "Windows apps start slowly on a Mac", "Its window opens soon"])
                    .font(.system(size: 11)).foregroundStyle(Palette.glow)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 30, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            Button("Show") { model.bringUnwineForward(to: game) }
                .buttonStyle(QuietButtonStyle())
                .help("Opens the app's page in Unwine. The app keeps starting.")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Palette.deep, Palette.night], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.stroke))
        )
        .accessibilityElement(children: .combine)
    }
}
