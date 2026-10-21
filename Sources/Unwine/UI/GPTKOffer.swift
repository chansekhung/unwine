import SwiftUI
import UniformTypeIdentifiers

/// The next step on a game page when D3DMetal would run the game but GPTK is not added: get the
/// file from Apple, then add it here. The import shows its progress in place. Once GPTK is in, the
/// advice names D3DMetal and this goes away.
struct GPTKOffer: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    private var adding: Bool { model.steps[.gptk]?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Add GPTK 4…") { picking = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(adding)
                    .help(adding ? "GPTK is being added. Wait for it to finish."
                                 : "Pick the GPTK file you downloaded from Apple. Unwine checks Apple's signature, then copies D3DMetal.")
                Button("Get GPTK from Apple") { NSWorkspace.shared.open(D3DMetalStore.appleDownloadPage) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Opens Apple's download page. Sign in with your Apple ID, then download the Game Porting Toolkit.")
            }
            if case .running(let progress, let words) = model.steps[.gptk] {
                HStack(spacing: 10) {
                    UnwineMark(progress: nil, size: 20)
                    PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
                }
                ProgressTrack(progress: progress)
            } else if case .failed(let why) = model.steps[.gptk] {
                Text(why).font(.system(size: 11)).foregroundStyle(Palette.warn).textSelection(.enabled)
            } else {
                Text("Apple gives GPTK only to your own Apple ID, so Unwine cannot download it for you. When you add it, this game uses D3DMetal the next time it starts.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]) { result in
            if case .success(let url) = result { Task { await model.importGPTK(url) } }
        }
        .fileDialogDefaultDirectory(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
    }
}
