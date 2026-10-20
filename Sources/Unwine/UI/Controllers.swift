import GameController
import SwiftUI

/// The game controllers macOS sees now. macOS says when one connects or goes away, so nothing
/// polls. It starts the first time a game's page shows the row.
@MainActor @Observable
final class Controllers {
    static let shared = Controllers()
    private(set) var names: [String] = []

    private init() {
        read()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Controllers.shared.read() }
            }
        }
    }

    private func read() {
        names = GCController.controllers().map { $0.vendorName ?? "Controller" }
    }
}

/// The game page's controller row: how many controllers are connected, and what works best.
struct ControllerRow: View {
    let steamGame: Bool
    private var pads: Controllers { Controllers.shared }

    var body: some View {
        let names = pads.names
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(names.isEmpty ? Palette.muted : Palette.glow)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(names)).font(.system(size: 13, weight: .semibold))
                Text(tip(connected: !names.isEmpty)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if names.isEmpty {
                Button("Bluetooth settings") { open("com.apple.BluetoothSettings") }.buttonStyle(QuietButtonStyle())
                    .help("Opens Bluetooth in System Settings, to connect a controller")
            } else {
                Button("Controller settings") { open("com.apple.Game-Controller-Settings.extension") }.buttonStyle(QuietButtonStyle())
                    .help("Opens Game Controllers in System Settings, to test buttons or change them")
            }
        }
    }

    private func title(_ names: [String]) -> String {
        switch names.count {
        case 0: return "No controller connected"
        case 1: return "1 controller connected: \(names[0])"
        default: return "\(names.count) controllers connected: \(names.joined(separator: ", "))"
        }
    }

    private func tip(connected: Bool) -> String {
        var text = "Windows games that use XInput (the Windows controller system) work best with an Xbox or a PlayStation controller."
        if steamGame { text += " Steam's own controller settings also apply to Steam games." }
        if !connected { text += " Connect the controller before you start the game." }
        return text
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
