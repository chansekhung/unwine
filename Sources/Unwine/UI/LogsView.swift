import AppKit
import SwiftUI

/// The Logs sheet: the last part of a game's logs and of Unwine's own, with ways to copy a log, show
/// it in Finder and report a problem. It opens from a game's Show logs, from Settings, from a banner's
/// Show logs and from Help > Show Logs.
struct LogsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: Int?
    /// What Done does instead of closing the sheet: from a banner, it brings back the game's page or
    /// Settings that the logs took the place of.
    let done: (() -> Void)?
    @State private var selected: String?    // a LogSource id
    @State private var text: String?        // nil while the log loads
    @State private var exists = true
    @State private var note: String?

    /// `log` is the LogSource the sheet opens on; without it (or when that log is not there), the first.
    init(gameID: Int?, log: String? = nil, done: (() -> Void)? = nil) {
        self.gameID = gameID
        self.done = done
        _selected = State(initialValue: log)
    }

    private var sources: [LogSource] { model.logSources(for: gameID) }
    private var source: LogSource? { sources.first { $0.id == selected } ?? sources.first }
    private var gameName: String? { gameID.flatMap { id in model.games.first { $0.id == id }?.name } }
    private var hasText: Bool { exists && !(text ?? "").isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Logs").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.text)
                    Text(gameName.map { "\($0), and what Unwine did" } ?? "What Unwine and Steam Play wrote down")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { if let done { done() } else { dismiss() } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20)

            HStack(spacing: 8) {
                if sources.count > 1 {
                    Picker("Log", selection: Binding(get: { source?.id ?? "" }, set: { selected = $0 })) {
                        ForEach(sources) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Spacer()
                Button("Copy") { copy(text ?? "", note: "The log is copied.") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!hasText).help(hasText ? "Copies the part of the log that shows here" : "There is nothing to copy yet")
                Button("Show in Finder") { if let s = source { NSWorkspace.shared.activateFileViewerSelecting([s.url]) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!exists).help(exists ? "Shows the whole log file in Finder" : "There is no log file yet")
            }
            .padding(.horizontal, 20)

            logArea
                .padding(.horizontal, 20).padding(.vertical, 12)

            HStack(spacing: 8) {
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Palette.glow).lineLimit(2)
                }
                Spacer()
                Button("Copy details for a bug report") {
                    copy(report, note: "The details are copied. Paste them into your bug report.")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(text == nil).help(text == nil ? "Unwine is still reading the log" : "Copies Unwine's version, your Mac, the engine, this game's settings and the last 200 lines of this log")
                Button("Report a problem") {
                    copy(report, note: "The details are copied. Paste them into the new issue on GitHub.")
                    NSWorkspace.shared.open(model.reportProblemURL)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(text == nil).help(text == nil ? "Unwine is still reading the log" : "Copies the details, then opens a new issue for Unwine on GitHub")
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .frame(width: 680, height: 580)
        .background(AppBackground())
        .task(id: source?.id) { await load() }
    }

    @ViewBuilder private var logArea: some View {
        if let text, hasText {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
        } else if text != nil {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(Palette.glow)
                Text(exists ? "This log is empty" : "No log yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Text(source?.empty ?? "").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        } else {
            // A long log takes a moment to read: a designed wait, never an empty box.
            VStack(spacing: 12) {
                UnwineMark(progress: nil, size: 44)
                PhaseWords(words: ["Reading the log…", "Going to its newest lines…"])
                    .font(.system(size: 12)).foregroundStyle(Palette.glow)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        }
    }

    private var report: String {
        model.bugReport(gameID: gameID, logTitle: source?.title ?? "Unwine", logText: hasText ? text ?? "" : "")
    }

    private func load() async {
        guard let source else { return }
        text = nil
        note = nil
        let url = source.url
        let (found, content) = await Task.detached(priority: .userInitiated) {
            (FileManager.default.fileExists(atPath: url.path), LogFile.tail(of: url, bytes: 64_000))
        }.value
        exists = found
        text = content
    }

    private func copy(_ value: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        self.note = note
    }
}

/// A game page's "Show logs", and its other Show log buttons: the Logs sheet over the page, so Done
/// leaves the page where it was. `game` nil shows Unwine's own logs; `log` is the LogSource to open on.
struct ShowLogsButton: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame?
    var log: String? = nil
    var title = "Show logs"
    var help = "Shows this game's logs and Unwine's own, and copies them for a bug report"
    @State private var showing = false

    var body: some View {
        Button(title) { showing = true }
            .buttonStyle(QuietButtonStyle())
            .help(help)
            .sheet(isPresented: $showing) { LogsView(gameID: game?.id, log: log).environment(model) }
    }
}

/// Settings' Logs group.
struct LogsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    @State private var note: String?

    var body: some View {
        Text("Unwine writes down what it does. Each game has its own log too: open the game, then press Show logs in Fix things.")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        HStack(spacing: 8) {
            Button("Show Unwine's log") { showing = true }.buttonStyle(QuietButtonStyle())
                .help("Shows the last part of Unwine's log, Windows Steam's and Steam Play's")
            Button("Show the logs folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs]) }.buttonStyle(QuietButtonStyle())
                .help("Shows every log file in Finder")
        }
        .sheet(isPresented: $showing) { LogsView(gameID: nil).environment(model) }
        HStack(spacing: 8) {
            Button("Copy details for a bug report") { Task { await copyReport(open: false) } }.buttonStyle(QuietButtonStyle())
                .help("Copies Unwine's version, your Mac, the engine and the last 200 lines of Unwine's log")
            Button("Report a problem") { Task { await copyReport(open: true) } }.buttonStyle(QuietButtonStyle())
                .help("Copies the details, then opens a new issue for Unwine on GitHub")
        }
        if let note { Text(note).font(.system(size: 11)).foregroundStyle(Palette.glow) }
    }

    private func copyReport(open: Bool) async {
        let log = model.log
        let tail = await Task.detached(priority: .userInitiated) { log.tail() }.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.bugReport(gameID: nil, logTitle: "Unwine", logText: tail), forType: .string)
        note = open ? "The details are copied. Paste them into the new issue on GitHub." : "The details are copied. Paste them into your bug report."
        if open { NSWorkspace.shared.open(model.reportProblemURL) }
    }
}
