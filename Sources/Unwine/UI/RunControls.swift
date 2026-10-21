import SwiftUI

/// Restart Steam, wherever Unwine offers it. While a restart (or a game's switch to Unwine) runs,
/// every copy of the button is off and says why, and words beside it say where the restart is.
struct RestartSteamButton: View {
    @Environment(AppModel.self) private var model
    var primary = true

    var body: some View {
        HStack(spacing: 8) {
            if primary {
                button.buttonStyle(PrimaryButtonStyle())
            } else {
                button.buttonStyle(QuietButtonStyle())
            }
            if let words = model.steamRestartWords {
                UnwineMark(progress: nil, size: 18)
                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
        }
    }

    private var button: some View {
        Button("Restart Steam") { Task { await model.restartSteam() } }
            .disabled(model.restartSteamBlocker != nil)
            .help(model.restartSteamBlocker ?? "Steam closes and opens again. Unwine waits until Steam Play is ready.")
    }
}

/// The tile's mark for a game that runs now. It is not a button: the tooltip names where Quit game is.
struct RunningBadge: View {
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.ok).frame(width: 7, height: 7)
            Text("Running").font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .help(help)
    }
}

/// A game closed, and Windows Steam stays open: it uses battery in the background and keeps Mac Steam
/// closed. This asks to quit it, as a card in the library or as a row on a game's page.
struct OnlineQuitOffer: View {
    @Environment(AppModel.self) private var model
    var card = true

    var body: some View {
        if let closed = model.onlineQuitOffer, model.online.running, !model.onlineBusy {
            let title = "Quit Windows Steam now?"
            let text = (closed.isEmpty ? "The game closed." : "\(closed) closed.") + " Windows Steam is still open and uses battery."
                + (model.willReopenMacSteam ? " Mac Steam comes back." : " Then you can open Mac Steam again.")
            if card {
                NoticeCard(icon: "globe", color: Palette.glow, title: title, text: text) { buttons }
            } else {
                NoticeRow(color: Palette.glow, icon: "globe", text: "\(title) \(text)") { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Quit") { Task { await model.stopOnline() } }.buttonStyle(PrimaryButtonStyle())
            .help("Closes Windows Steam. Steam Cloud saves sync first.")
        Button("Keep open") { model.onlineQuitOffer = nil }.buttonStyle(QuietButtonStyle())
            .help("Windows Steam stays open. Unwine asks again after your next game.")
    }
}

/// A game rebuilt its picture again and again in its latest online session. That happens when it draws
/// at the screen's full pixel size while Windows Steam's bottle runs without High Resolution Mode: the
/// sizes never match.
struct PictureRebuildTip: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        if let count = model.onlineRebuilds[game.id], count > 50, !model.stored.onlineHighResolution {
            NoticeRow(color: Palette.warn, icon: "arrow.triangle.2.circlepath",
                      text: "In its latest online session, \(game.name) rebuilt its picture \(count) times. That costs speed and battery. Turn on High Resolution Mode, or set the game to \(pointSize) in its own video settings.") {
                Button("Turn on") {
                    model.setOnlineHighResolution(true)
                    model.banner = "High Resolution Mode is on. It applies the next time Windows Steam starts."
                }
                .buttonStyle(QuietButtonStyle())
                    .help("Turns on High Resolution Mode for Windows Steam. It applies the next time Windows Steam starts.")
            }
        }
    }

    /// The size Windows Steam's bottle draws at without High Resolution Mode: the screen's size in points.
    private var pointSize: String {
        guard let screen = NSScreen.main else { return "half your screen size" }
        return "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }
}
