import SwiftUI

/// "Faster x87 math" in a 32-bit game's Speed section: the switch and its note, the question before
/// the first download, the wait while x87sidecar downloads and checks Rosetta, and what the game's last
/// session said about it. The game's logs are read once, when its page opens.
struct X87Switch: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    @State private var asking = false
    @State private var session = X87Session()

    var body: some View {
        let s = model.settings(for: game.id)
        let task = model.x87Task
        let busy = task?.status.isRunning == true
        let blocker = model.x87Blocker
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Faster x87 math (experimental)", isOn: Binding(get: { s.x87 }, set: { turn($0) }))
                .disabled(busy || (!s.x87 && blocker != nil))
                .help(help(s, busy: busy, blocker: blocker))
            if case .running(let progress, let words)? = task?.status {
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 20)
                    PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                }
                ProgressTrack(progress: progress)
            } else if let task, task.gameID == game.id || (task.gameID == nil && s.x87), case .failed(let why) = task.status {
                Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Try again") { Task { await model.enableX87(for: game.id, again: true) } }.buttonStyle(QuietButtonStyle())
                        .help(s.x87 ? "Gets x87sidecar again if it is missing, then checks it with Rosetta"
                                    : "Gets x87sidecar again if it is missing, checks it with Rosetta, then turns this on")
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([model.log.url]) }.buttonStyle(QuietButtonStyle())
                        .help("Shows Unwine's log in Finder")
                }
            }
            state(s, busy: busy, blocker: blocker)
        }
        .confirmationDialog("Turn on Faster x87 math?", isPresented: $asking) {
            Button("Download and turn on") { Task { await model.enableX87(for: game.id) } }
        } message: {
            Text("Old 32-bit games do a lot of x87 math, and Rosetta runs it slowly. x87sidecar makes this math much faster. It is a free program by other people (MIT licence), from github.com/athei/x87sidecar. Unwine downloads it one time (\(X87Sidecar.sizeText)) and checks it with your Mac's Rosetta.\n\nThe first time a game starts with it after you log in, macOS asks for your password to allow Developer Tools. x87sidecar uses 64-bit math, not the 80-bit math of old PCs, so a few games can glitch. If a game glitches, turn the switch off. x87sidecar stays off for every other game.")
        }
        .task(id: game.id) { session = await model.x87Session(for: game.id) }
    }

    /// The switch's note: what it does, or why it does nothing now, with the next step.
    @ViewBuilder
    private func state(_ s: GameSettings, busy: Bool, blocker: String?) -> some View {
        if !s.x87 {
            note(blocker ?? offNote, warn: blocker != nil)
            if blocker == nil {
                Button("About x87sidecar") { NSWorkspace.shared.open(X87Sidecar.page) }
                    .buttonStyle(.link).font(.system(size: 11)).help(X87Sidecar.page.absoluteString)
            }
        } else if let blocker {
            note(blocker + " Until then, this game runs without it.", warn: true)
        } else if !X87Sidecar.isInstalled {
            note("x87sidecar \(X87Sidecar.version) is not on this Mac, so this game runs without it.", warn: true)
            Button("Download x87sidecar (\(X87Sidecar.sizeText))") { Task { await model.enableX87(for: game.id) } }
                .buttonStyle(QuietButtonStyle()).disabled(busy)
                .help(busy ? "Unwine is getting x87sidecar ready. Wait a moment." : "Downloads x87sidecar from GitHub and checks it with Rosetta")
        } else if model.stored.x87Probe?.isCurrent != true {
            if !busy {
                note("x87sidecar has not checked the Rosetta in this macOS yet, so this game runs without it for now.", warn: true)
                Button("Check now") { Task { await model.enableX87(for: game.id) } }.buttonStyle(QuietButtonStyle())
                    .help("Runs x87sidecar's check of Rosetta. It takes a few seconds.")
            }
        } else {
            note(onNote, warn: false)
            if let p = model.stored.x87Probe {
                Text("Checked: x87sidecar \(p.sidecarVersion) supports the Rosetta in macOS \(p.macOSVersion).")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
        if s.x87 && model.x87Ready {
            if s.x87PreciseFaults {
                note("This game once stopped because of an x87 fault. So Unwine now starts it with precise x87 faults (X87_PRECISE_FAULTS=1). They prevent that stop.", warn: false)
            }
            if let reason = session.notAttached {
                NoticeRow(color: Palette.warn, icon: "exclamationmark.triangle", text: notAttachedNote(reason)) {
                    if let log = session.log {
                        Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }.buttonStyle(QuietButtonStyle())
                            .help("Shows the game's log in Finder. It has x87sidecar's whole message.")
                    }
                }
            }
        }
    }

    private var offNote: String {
        "Old 32-bit games do a lot of x87 math (how old PCs calculate with decimal numbers), and Rosetta runs it slowly. x87sidecar, a free program by other people, makes this math much faster. It uses less exact math, so a few games can glitch. "
            + (X87Sidecar.isInstalled ? "It runs only in the games where you turn it on." : "Unwine asks first. Then it downloads x87sidecar (\(X87Sidecar.sizeText)).")
    }

    private let onNote = "x87sidecar makes this game's x87 math much faster. The first time a game starts with it after you log in, macOS asks for your password to allow Developer Tools. Allow it, or the game runs without it. If the game glitches or crashes, turn this off."

    private func notAttachedNote(_ reason: String) -> String {
        "Last time, x87sidecar did not attach, so the game ran without faster x87 math. "
            + (reason.isEmpty ? "It gave no reason." : "It said: \(reason)\(reason.hasSuffix("…") ? "" : ".")")
            + " If macOS asks for your password, allow it."
    }

    private func help(_ s: GameSettings, busy: Bool, blocker: String?) -> String {
        if busy { return "Unwine is getting x87sidecar ready. Wait a moment." }
        if s.x87 { return "Turns x87sidecar off for this game" }
        if let blocker { return blocker }
        return X87Sidecar.isInstalled ? "Turns x87sidecar on for this game only"
                                      : "Asks first. Then Unwine downloads x87sidecar (\(X87Sidecar.sizeText)) and checks it."
    }

    private func turn(_ on: Bool) {
        if !on { model.disableX87(for: game.id) }
        else if X87Sidecar.isInstalled { Task { await model.enableX87(for: game.id) } }
        else { asking = true }       // the first time: say what it is before anything downloads
    }

    private func note(_ text: String, warn: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warn ? Palette.warn : Palette.muted).padding(.bottom, 4)
    }
}
