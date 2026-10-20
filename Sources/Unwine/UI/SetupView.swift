import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingGPTK = false

    private var current: SetupStep? {
        SetupStep.allCases.first { !(model.steps[$0]?.isDone ?? false) }
    }

    private var overallProgress: Double {
        let done = SetupStep.allCases.filter { model.steps[$0]?.isDone ?? false }.count
        return Double(done) / Double(SetupStep.allCases.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                VStack(spacing: 10) {
                    ForEach(SetupStep.allCases) { step in
                        StepRow(step: step, status: model.steps[step] ?? .pending, isCurrent: step == current) {
                            actions(for: step)
                        }
                    }
                }
                footer
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $pickingGPTK, allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]) { result in
            if case .success(let url) = result {
                Task {
                    await model.importGPTK(url)
                    if model.steps[.gptk]?.isDone == true { await model.runSetup() }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            UnwineMark(progress: model.isSettingUp ? nil : overallProgress, size: 92)
            Text("Set up Unwine")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("Windows games, right inside your Mac Steam. Free. About 430 MB to download, once.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isSettingUp {
            Text("You can keep using your Mac. Unwine tells you when it needs you.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        } else if !SetupStep.allCases.allSatisfy({ model.steps[$0]?.isDone ?? false }) {
            Button(SetupStep.allCases.contains { model.steps[$0] != .pending } ? "Continue setup" : "Start setup") {
                Task { await model.runSetup() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func actions(for step: SetupStep) -> some View {
        switch (step, model.steps[step] ?? .pending) {
        case (.mac, .needsUser(let why)) where why.contains("Rosetta"):
            Button("Install Rosetta") { Task { await model.installRosetta() } }.buttonStyle(PrimaryButtonStyle())
        case (.mac, .needsUser):
            Button("Get Steam") { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/about/")!) }
                .buttonStyle(PrimaryButtonStyle())
            Button("Check again") { Task { await model.runSetup() } }.buttonStyle(QuietButtonStyle())
        case (.gptk, .needsUser), (.gptk, .failed):
            Button("Get GPTK 4 from Apple") { NSWorkspace.shared.open(D3DMetalStore.appleDownloadPage) }
                .buttonStyle(QuietButtonStyle())
            Button("Find it in Downloads") { Task { if await model.findGPTKInDownloads() { await model.runSetup() } } }
                .buttonStyle(PrimaryButtonStyle())
            Button("Choose file…") { pickingGPTK = true }.buttonStyle(QuietButtonStyle())
            Button("Skip") { model.skipGPTK(); Task { await model.runSetup() } }.buttonStyle(QuietButtonStyle())
        case (.steam, .needsUser):
            if !model.steamRunning {
                Button("Open Steam") { MacSteam.start() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Restart Steam") { Task { await model.restartSteam() } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.gameRunning)
            }
            Button("Check again") { Task { await model.refreshSteam(); model.checkSteamConnection() } }.buttonStyle(QuietButtonStyle())
            Button("How Steam Play works") { NSWorkspace.shared.open(URL(string: "https://github.com/NotProtonNot/NotProton#readme")!) }
                .buttonStyle(QuietButtonStyle())
        case (_, .failed):
            Button("Try again") { Task { await model.runSetup() } }.buttonStyle(PrimaryButtonStyle())
            Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([model.log.url]) }.buttonStyle(QuietButtonStyle())
        default:
            EmptyView()
        }
    }
}

private struct StepRow<Actions: View>: View {
    let step: SetupStep
    let status: StepStatus
    let isCurrent: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(status == .pending && !isCurrent ? Palette.muted : Palette.text)
                detail
                if case .running(let progress, _) = status {
                    ProgressTrack(progress: progress).padding(.top, 2)
                }
                HStack(spacing: 8) { actions }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isCurrent ? Color.white.opacity(0.08) : Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isCurrent ? Palette.accent.opacity(0.5) : Palette.stroke))
        .animation(.easeOut(duration: 0.25), value: status)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Palette.ok)
        case .running:
            UnwineMark(progress: nil, size: 24)
        case .needsUser:
            Image(systemName: "hand.point.right.fill").font(.system(size: 17)).foregroundStyle(Palette.warn)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(Palette.error)
        case .pending:
            Circle().stroke(Palette.stroke, lineWidth: 2).frame(width: 18, height: 18)
        }
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case .pending:
            Text(step.blurb).font(.system(size: 12)).foregroundStyle(Palette.muted)
        case .running(_, let words):
            PhaseWords(words: words).font(.system(size: 12)).foregroundStyle(Palette.glow)
        case .done(let note):
            Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted)
        case .needsUser(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(Palette.warn)
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(Palette.text.opacity(0.85)).textSelection(.enabled)
        }
    }
}
