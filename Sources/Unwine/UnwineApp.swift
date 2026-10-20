import SwiftUI

@main
struct UnwineApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Unwine") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                WhatsNewMenuItem()
                Button("Check for Updates…") { Task { await model.checkForUpdates() } }
                    .disabled(!model.showsLibrary || model.isCheckingUpdates)
            }
            CommandGroup(replacing: .newItem) {}
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
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            AppBackground()
            if model.showsLibrary {
                LibraryView()
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.showsLibrary)
        // After an update, "What's new" opens once by itself; AppModel.whatsNewWaiting says when.
        .onChange(of: model.showsLibrary, initial: true) { _, shows in if shows { model.settleWhatsNew() } }
        .onChange(of: model.whatsNewWaiting, initial: true) { _, waiting in if waiting { openWindow(id: WhatsNewView.windowID) } }
    }
}
