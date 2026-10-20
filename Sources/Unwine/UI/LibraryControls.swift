import SwiftUI

/// The way an arrow key moves the keyboard focus between tiles.
enum TileMove { case left, right, up, down }

/// A key typed on a tile that changes the library's search.
enum TileKey { case text(String), deleteLast, clear }

/// One of the library's filters. The count says how many games it shows now.
struct FilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 { Text("\(count)").foregroundStyle(selected ? Palette.text.opacity(0.8) : Palette.muted) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Palette.accent.opacity(0.85) : Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(selected ? Palette.accent : Palette.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the library shows before its first look at Steam lands: tiles that shimmer where the games
/// are about to show, never a false "No Windows games yet".
struct LibrarySkeleton: View {
    @Environment(AppModel.self) private var model
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                UnwineMark(progress: nil, size: 20)
                PhaseWords(words: model.steamMissing ? ["Looking for your games…"] : ["Reading your Steam library…", "Looking for Windows games…"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            .padding(.horizontal, 24).padding(.top, 14)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            Shimmer().aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Shimmer().frame(width: 110, height: 11).clipShape(Capsule())
                            Shimmer().frame(width: 70, height: 9).clipShape(Capsule())
                        }
                    }
                }
                .padding(24)
            }
            .scrollDisabled(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Looking for your games")
    }
}

/// Shows over the library while a game's folder or .exe is dragged over it.
struct DropHint: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.night.opacity(0.82))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            VStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.folder").font(.system(size: 34)).foregroundStyle(Palette.glow)
                Text("Drop to add this game").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.text)
                Text("A game's folder or its .exe. It runs without Steam.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}
