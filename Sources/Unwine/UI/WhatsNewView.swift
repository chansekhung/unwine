import SwiftUI

/// "What's new": what each Unwine version changed, in plain words, newest first. It opens from the
/// app menu and from Settings, and by itself once after Unwine updates (`AppModel.whatsNewWaiting`).
struct WhatsNewView: View {
    static let windowID = "whats-new"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var noted = false
    @State private var seenBefore: String?

    private let entries = Changelog.entries

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                UnwineMark(progress: 1, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What's new").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20)

            if entries.isEmpty {
                missing
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(entries) { entry($0) }
                        if let url = repoURL("releases") {
                            Button("All releases and downloads on GitHub") { NSWorkspace.shared.open(url) }
                                .buttonStyle(QuietButtonStyle())
                                .help(url.absoluteString)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 660)
        .background(AppBackground())
        .onAppear(perform: noteSeen)
        .onChange(of: model.loaded) { noteSeen() }
    }

    private var current: String { model.appUpdater.currentVersion }

    /// The last version the user had seen before this window opened. Versions after it are new to them.
    private var since: String? { noted ? seenBefore : model.stored.lastSeenVersion }

    private func isNew(_ version: String) -> Bool {
        guard let since else { return false }
        return LooseVersion(version) > LooseVersion(since) && LooseVersion(version) <= LooseVersion(current)
    }

    private var subtitle: String {
        isNew(current) ? "Unwine is now \(current). Here is what changed." : "You have Unwine \(current). The newest changes are at the top."
    }

    /// Keeps what the user had seen, then marks this version as seen. It waits for Unwine's saved
    /// state, because a save before that would replace it.
    private func noteSeen() {
        guard model.loaded, !noted else { return }
        seenBefore = model.stored.lastSeenVersion
        noted = true
        model.markWhatsNewSeen()
    }

    private func entry(_ e: ChangelogEntry) -> some View {
        let mine = e.version == current
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Unwine \(e.version)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                if mine {
                    StatusPill(text: "Your version", color: Palette.ok)
                } else if isNew(e.version) {
                    StatusPill(text: "New to you", color: Palette.glow)
                }
                Spacer()
                Text(e.date?.formatted(date: .long, time: .omitted) ?? "Not released yet")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ForEach(e.note, id: \.self) { line in
                Text(markdown(line)).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(e.items.enumerated()), id: \.offset) { _, item in
                    point("•", item.text, size: 13)
                    ForEach(Array(item.sub.enumerated()), id: \.offset) { _, sub in
                        point("◦", sub, size: 12).padding(.leading, 16)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(mine ? Palette.accent.opacity(0.7) : Palette.stroke))
    }

    private func point(_ mark: String, _ text: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).foregroundStyle(Palette.glow)
            Text(markdown(text)).foregroundStyle(Palette.text.opacity(size < 13 ? 0.85 : 1))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: size))
    }

    /// Without its CHANGELOG.md (a copy not built by scripts/build.sh), the list is still on GitHub.
    private var missing: some View {
        let url = repoURL("blob/main/CHANGELOG.md")
        return NoticeCard(icon: "doc.text.magnifyingglass", color: Palette.warn, title: "The change list is not in this copy of Unwine",
                          text: url == nil ? "Build Unwine with scripts/build.sh. It puts the list into the app." : "The same list is on GitHub.") {
            if let url {
                Button("Open the list on GitHub") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func repoURL(_ path: String) -> URL? {
        model.appUpdater.repo.flatMap { URL(string: "https://github.com/\($0)/\(path)") }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The app menu's way into "What's new". It is a view, so that it can read the openWindow action.
struct WhatsNewMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's New in Unwine") { openWindow(id: WhatsNewView.windowID) }
    }
}

// MARK: - When "What's new" opens by itself

extension AppModel {
    /// True when "What's new" should open by itself: this Unwine is newer than the last one whose notes
    /// the user saw, setup is done, and Unwine has looked at what runs. It waits while a game, an added
    /// game or Windows Steam runs, so it never covers a game.
    var whatsNewWaiting: Bool {
        guard showsLibrary, steamChecked, let seen = stored.lastSeenVersion,
              LooseVersion(appUpdater.currentVersion) > LooseVersion(seen) else { return false }
        return !gameRunning && localRunning.isEmpty && localStarting.isEmpty && !online.inUse && !onlineBusy
    }

    func markWhatsNewSeen() {
        guard loaded, stored.lastSeenVersion != appUpdater.currentVersion else { return }
        stored.lastSeenVersion = appUpdater.currentVersion
        save()
    }

    /// Runs when the library shows. A fresh install starts at this version with no window, so its first
    /// "What's new" comes with its first update. After a move back to an older Unwine, the same happens.
    func settleWhatsNew() {
        if let seen = stored.lastSeenVersion, LooseVersion(seen) <= LooseVersion(appUpdater.currentVersion) { return }
        markWhatsNewSeen()
    }
}
