import SwiftUI

/// A short label in the corner of a game's tile, for something to know before opening its page.
/// A tile shows only the most important one. Its reason is the tooltip and what VoiceOver reads.
struct TileBadge: Comparable {
    /// From the most to the least important. Starting and running come from the Steam start work,
    /// a missing program file from the added-games work: each adds its badge in `badges(for:)`.
    enum Kind: Int {
        case starting, running, missingFile, blocked, otherTool, onlineMode
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
        case .missingFile, .otherTool: return Palette.warn
        case .blocked: return Palette.error
        }
    }

    static func < (a: TileBadge, b: TileBadge) -> Bool { a.kind.rawValue < b.kind.rawValue }
}

extension AppModel {
    /// What the advisor and Steam already know about a game, as tile badges, the most important first.
    func badges(for game: SteamGame) -> [TileBadge] {
        var list: [TileBadge] = []
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
