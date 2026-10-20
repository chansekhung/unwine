import SwiftUI

@main
struct UnwineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Unwine") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
                .task { model.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            // A menu item cannot show a tooltip, so one that is off says why in its own title.
            CommandGroup(after: .appInfo) {
                WhatsNewMenuItem()
                Button(model.isCheckingUpdates ? "Checking for Updates…" : untilSetUp("Check for Updates…")) {
                    Task { await model.checkForUpdatesFromMenu() }
                }
                .disabled(!model.showsLibrary || model.isCheckingUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button(untilSetUp("Settings…")) { model.openSettings() }
                    .keyboardShortcut(",")
                    .disabled(!model.showsLibrary)
            }
            CommandGroup(replacing: .newItem) {
                Button(untilSetUp("Add Game…")) { model.requestAddGame() }
                    .keyboardShortcut("o")
                    .disabled(!model.showsLibrary)
            }
            CommandGroup(replacing: .textEditing) {
                Button(model.showsLibrary && model.windowsGames.isEmpty ? "Find… (no games yet)" : untilSetUp("Find…")) { model.requestFind() }
                    .keyboardShortcut("f")
                    .disabled(!model.showsLibrary || model.windowsGames.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { model.reportProblem() }
                Button("Show Logs") { model.showLogsFolder() }
                Divider()
                Button("Unwine on GitHub") { model.openProjectPage() }
            }
        }

        Window("What's New in Unwine", id: WhatsNewView.windowID) {
            WhatsNewView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 660)
        .restorationBehavior(.disabled)     // opens once after an update, not again at every start
    }

    private func untilSetUp(_ title: String) -> String { model.showsLibrary ? title : "\(title) (finish setup first)" }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            AppBackground()
            if !model.booted {
                // Until Unwine has read its saved state, it cannot know which screen is right.
                UnwineMark(progress: nil, size: 92)
                    .accessibilityLabel("Unwine is starting")
                    .transition(.opacity)
            } else if model.showsLibrary {
                LibraryView()
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.showsLibrary)
        .animation(.easeInOut(duration: 0.3), value: model.booted)
        // After an update, "What's new" opens once by itself; AppModel.whatsNewWaiting says when.
        .onChange(of: model.showsLibrary, initial: true) { _, shows in
            if shows {
                model.settleWhatsNew()
                model.flushPendingOpens()
            }
        }
        .onChange(of: model.whatsNewWaiting, initial: true) { _, waiting in if waiting { openWindow(id: WhatsNewView.windowID) } }
        // An .exe opened with Unwine comes to this window, not to a new one.
        .onOpenURL { OpenedFiles.receive([$0]) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}
