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

/// "Turn on Steam Play": says first what changes in Steam.app, then does it with its phase words.
/// When macOS stopped the change, the next step is App Management in System Settings.
struct TurnOnSteamPlayButton: View {
    @Environment(AppModel.self) private var model
    var title = "Turn on Steam Play"
    var primary = true
    @State private var asking = false

    var body: some View {
        HStack(spacing: 8) {
            if let words = model.steamPlaySwitchWords {
                UnwineMark(progress: nil, size: 18)
                PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
            } else {
                if primary { button.buttonStyle(PrimaryButtonStyle()) } else { button.buttonStyle(QuietButtonStyle()) }
                if model.steamPlaySwitchBlocked {
                    Button("Open App Management") { NSWorkspace.shared.open(Self.appManagement) }.buttonStyle(QuietButtonStyle())
                        .help("Opens System Settings › Privacy & Security › App Management. Turn on Unwine there, then try again.")
                }
            }
        }
        .confirmationDialog("\(title) in Steam?", isPresented: $asking) {
            Button(title) { Task { await model.turnOnSteamPlay() } }
        } message: {
            Text(Self.explanation)
        }
    }

    private var button: some View {
        Button(title) { asking = true }
            .disabled(model.steamPlaySwitchBlocker != nil)
            .help(model.steamPlaySwitchBlocker ?? "Shows what changes in Steam.app first. Nothing changes before you agree.")
    }

    static let appManagement = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    static let explanation = """
        Mac Steam has no Steam Play switch. Unwine adds NotProton's open Steam Play add-on to Steam.app. Then Steam lists Unwine as a compatibility tool.

        What changes: Unwine copies the add-on into Steam.app, tells Steam to load it, and signs Steam again for this Mac. First, Unwine keeps a copy of Valve's Steam.app. Undo in Settings puts it back.

        Steam closes and opens again. Valve's terms do not allow changes to Steam. Valve has not acted against this add-on, but it can. If you do not want this, use Online mode instead.

        macOS can ask you to let Unwine change other apps.
        """
}

/// Undo for the Steam Play switch: Valve's Steam.app comes back from Unwine's copy.
struct UndoSteamPlayButton: View {
    @Environment(AppModel.self) private var model
    @State private var asking = false

    var body: some View {
        Button("Undo Steam Play") { asking = true }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.steamPlaySwitchBlocker != nil)
            .help(model.steamPlaySwitchBlocker ?? "Puts back Steam.app as Valve made it. Asks first.")
            .confirmationDialog("Undo Steam Play?", isPresented: $asking) {
                Button("Undo Steam Play", role: .destructive) { Task { await model.undoSteamPlay() } }
            } message: {
                Text(FileManager.default.fileExists(atPath: SteamPlaySwitch.backup.path)
                     ? "Steam closes. Unwine puts back its copy of Valve's Steam.app. Steam games then no longer start through Unwine. Your games and Steam's settings stay."
                     : "Steam closes. Unwine takes the add-on out of Steam.app. Unwine has no copy of Valve's Steam.app, so Steam keeps the signature for this Mac until you download Steam again from Valve. Your games and Steam's settings stay.")
            }
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
