import SwiftUI

/// A short label in the corner of a game's tile, for something to know before opening its page.
/// A tile shows only the most important one. Its reason is the tooltip and what VoiceOver reads.
struct TileBadge: Comparable {
    /// From the most to the least important. Running comes from the game's run state (RunState) and a
    /// missing program file from the added games, both in `badges(for:)`. A start or a quit in Mac Steam
    /// or an added game's bottle shows its words at the bottom of the tile instead, so `starting` is for
    /// a start whose words show elsewhere: a game Unwine starts in Windows Steam (the Online mode card).
    enum Kind: Int {
        case starting, running, missingFile, needsRuntime, blocked, otherTool, onlineMode
    }

    let kind: Kind
    let text: String
    let icon: String
    let reason: String
    var needsAttention = true       // the game shows under "Needs attention"

    var color: Color {
        switch kind {
        case .starting, .onlineMode: return Palette.glow
        case .running: return Palette.ok
        case .missingFile, .needsRuntime, .otherTool: return Palette.warn
        case .blocked: return Palette.error
        }
    }

    static func < (a: TileBadge, b: TileBadge) -> Bool { a.kind.rawValue < b.kind.rawValue }
}

extension AppModel {
    /// What the advisor and Steam already know about a game, as tile badges, the most important first.
    func badges(for game: SteamGame) -> [TileBadge] {
        var list: [TileBadge] = []
        if onlineStarting == game.id {
            list.append(TileBadge(kind: .starting, text: "Starting", icon: "hourglass",
                                  reason: "\(game.name) is starting in Windows Steam. The card at the top of the library shows each step.",
                                  needsAttention: false))
        }
        if runState(of: game) == .running {
            // Not a button: the reason names where Quit game is. Steam games and added games have it in both places.
            list.append(TileBadge(kind: .running, text: "Running", icon: "play.fill",
                                  reason: "\(game.name) is running. To quit it, right-click it or open its page.",
                                  needsAttention: false))
        }
        if let exe = game.localExe, !FileManager.default.fileExists(atPath: exe.path) {
            list.append(TileBadge(kind: .missingFile, text: "File missing", icon: "questionmark.folder",
                                  reason: "Unwine cannot find \(exe.lastPathComponent). If the \(noun(game)) moved, or its drive is not connected, right-click it and choose Locate…. Its bottle and saves stay."))
        }
        let missing = missingRuntimes(game).filter(\.required)
        if let need = missing.first(where: { WindowsRuntime.pinned($0.runtime).works }) {
            let title = WindowsRuntime.pinned(need.runtime).title
            list.append(TileBadge(kind: .needsRuntime, text: "Needs runtime", icon: "shippingbox",
                                  reason: "\(game.name) needs \(title) to start. Open its page and press Install. It comes from Microsoft."))
        } else if let reason = runtimeChecks[game.id]?.unoffered.first, isApp(game) {
            list.append(TileBadge(kind: .needsRuntime, text: "May not start", icon: "shippingbox",
                                  reason: reason, needsAttention: false))
        } else if let need = missing.first {
            // Nothing to install: Wine cannot show this part yet. Said once, not as a thing to fix.
            let title = WindowsRuntime.pinned(need.runtime).title
            list.append(TileBadge(kind: .needsRuntime, text: "Partly works", icon: "shippingbox",
                                  reason: "\(game.name) uses \(title), which does not work in Wine yet (WineHQ bug 58921). The app may open, but the parts that use it can stay empty.",
                                  needsAttention: false))
        }
        if game.localExe == nil, let tool = mappings[game.id], tool != Runner.toolName {
            list.append(TileBadge(kind: .otherTool, text: "Not using Unwine", icon: "hand.point.right.fill",
                                  reason: "Steam runs this game with another tool (\(tool)), so Unwine's settings do nothing. Its page can switch it to Unwine."))
        }
        switch advice(for: game).online {
        case .publisherBlocked:
            list.append(TileBadge(kind: .blocked, text: "Blocked", icon: "nosign",
                                  reason: "The publisher blocks this game on macOS, so it does not run here."))
        case .blocked(let names):
            list.append(TileBadge(kind: .blocked, text: "Blocked", icon: "shield.lefthalf.filled",
                                  reason: "Uses \(names.joined(separator: ", ")). Online play with this anti-cheat does not work on a Mac. Offline modes may work."))
        case .needsOnlineMode(let anticheat) where game.localExe == nil:
            let ready = online.installed && online.signedIn
            list.append(TileBadge(kind: .onlineMode, text: "Online mode", icon: "globe",
                                  reason: "Uses \(anticheat). Online servers accept it only through Online mode. Single player works with Play."
                                    + (ready ? "" : " Its page sets up Online mode."),
                                  needsAttention: !ready))
        default:
            break
        }
        return list.sorted()
    }
}

struct TileBadgeView: View {
    let badge: TileBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.icon).font(.system(size: 9, weight: .bold))
            Text(badge.text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Palette.night)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(badge.color))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .help(badge.reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(badge.text): \(badge.reason)")
    }
}
