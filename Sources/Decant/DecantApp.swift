import SwiftUI

@main
struct DecantApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Decant") {
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
                Button("Check for Updates…") { Task { await model.checkForUpdates() } }
                    .disabled(!model.showsLibrary || model.isCheckingUpdates)
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

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
    }
}
