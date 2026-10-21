import SwiftUI

/// Asks before an .exe that the Steam library already has becomes an added game: Steam's copy
/// stays up to date and keeps its Steam Cloud saves, so it is the one to play.
struct SteamCopyDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Opens a game's page in Unwine.
    let open: (SteamGame) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(model.steamCopyAsk?.title ?? "",
                                   isPresented: Binding(get: { model.steamCopyAsk != nil }, set: { if !$0 { model.steamCopyAsk = nil } }),
                                   presenting: model.steamCopyAsk) { ask in
            if let game = ask.game {
                Button("Open \(game.name)") {
                    model.steamCopyAsk = nil
                    // After this question has closed, so the page can show.
                    Task { @MainActor in open(game) }
                }
            }
            Button("Add anyway") {
                model.steamCopyAsk = nil
                model.addLocalGame(exe: ask.exe, folder: ask.folder, anyway: true)
            }
            Button("Cancel", role: .cancel) { model.steamCopyAsk = nil }
        } message: { ask in
            Text(ask.message)
        }
    }
}
