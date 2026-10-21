import SwiftUI

/// "Last session" on a game's page: how the game ran the last time, as macOS 27 measured it, and one
/// tip from the numbers. Older macOS records no frame times, so the row does not show there.
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame

    var body: some View {
        let summary = model.stored.sessions[game.id]
        let measuring = model.sessionWatch.measuring.contains(game.id)
        // Unwine sees a game only when it runs through Unwine: an added game always does, a Steam game when
        // Steam is set to use Unwine (runsThroughUnwine, the game page's rule). Otherwise the page offers
        // "Use Unwine", and that is the next click, not Play.
        let measurable = game.state == .installed && (game.localExe != nil || model.runsThroughUnwine(game))
        // A launcher's page sends the user to its game's page for speed settings, so the numbers live there.
        if MetalPerfTrace.isAvailable, model.settingsSource(for: game) == nil, summary != nil || measuring || measurable {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "speedometer").font(.system(size: 13)).foregroundStyle(Palette.glow).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    if measuring {
                        HStack(spacing: 8) {
                            UnwineMark(progress: nil, size: 20)
                            PhaseWords(words: ["Reading how \(game.name) ran…", "macOS keeps the frame times of every game", "Adding up the numbers…"])
                                .font(.system(size: 12)).foregroundStyle(Palette.glow)
                        }
                    } else if let s = summary {
                        Text("Last session: \(s.line)").font(.system(size: 13, weight: .semibold))
                            .help(explanation(s))
                        if let tip = s.tip(now: model.settings(for: game.id), canSharpen: model.canSharpen(game),
                                           takesCap: model.takesFrameCap(game)) {
                            Text(tip).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    } else {
                        Text("Last session: nothing measured yet").font(.system(size: 13, weight: .semibold))
                        Text("Press Play and play for a minute or more. When the game closes, its frame rate and GPU time show here.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.text)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.stroke))
        }
    }

    private func explanation(_ s: SessionSummary) -> String {
        let minutes = max(1, Int((s.seconds / 60).rounded()))
        return "macOS measured \(minutes) minute\(minutes == 1 ? "" : "s") of play on the screen. The game closed \(s.ended.formatted(date: .abbreviated, time: .shortened)). "
            + "fps: frames on the screen each second. GPU: the time the graphics chip needs for one frame. Shaders: the time the game used to build new shaders."
    }
}
