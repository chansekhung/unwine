import SwiftUI

/// "New games start with", in Settings: the settings every game uses until one of its own changes
/// (`stored.defaults`). The graphics layer stays Automatic, so each game still gets its own layer.
struct NewGamesControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.stored.defaults
        VStack(alignment: .leading, spacing: 10) {
            Text("Games use these settings until you change one on the game's page. The graphics layer stays Automatic, so each game still gets the layer that suits it.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Picker("Start with", selection: Binding(get: { model.newGamesPreset }, set: { model.applyToNewGames($0) })) {
                ForEach(Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(presetText(d)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            FrameCapPicker(cap: Binding(get: { model.stored.defaults.fpsCap }, set: { v in model.updateDefaults { $0.fpsCap = v } }))
            Toggle("Save battery when unplugged", isOn: Binding(get: { model.stored.defaults.saveBatteryUnplugged },
                                                                 set: { v in model.updateDefaults { $0.saveBatteryUnplugged = v } }))
            Text(batteryText(d)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(countText).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func presetText(_ d: GameSettings) -> String {
        if model.newGamesPreset == .speed {
            return d.fpsCap.map { "Best speed: games run as fast as your Mac can draw them, up to your \($0) fps cap." }
                ?? "Best speed: no frame cap, so games run as fast as your Mac can draw them."
        }
        let cap = d.fpsCap.map { " Games start capped at \($0) fps." } ?? " There is no frame cap now. Pick one below."
        return "Best battery: ray tracing off with D3DMetal, and less tessellation (fine surface detail) with DXMT.\(cap) MetalFX for DLSS stays off. Turn it on for a game that has DLSS, on the game's page."
    }

    private func batteryText(_ d: GameSettings) -> String {
        guard d.saveBatteryUnplugged else { return "Off: games start with the same settings on battery and on power." }
        let hz = Profiles.screenHz
        let normal = BatteryOverlay(strict: false, screenHz: hz).cap, strict = BatteryOverlay(strict: true, screenHz: hz).cap
        return "On battery, a game without its own cap starts capped at \(normal) fps. In Low Power Mode or when your Mac is hot, the cap is \(strict) fps. 120 fps mode waits until you plug in. Plugged in, nothing changes. Unwine switches when you plug in or unplug, also for games you start in Steam. Keep Unwine open for that. Its window can be closed."
    }

    private var countText: String {
        switch model.gamesOnDefaults {
        case 0: return "No game in your library uses these now: each one has its own settings. Reset settings on a game's page to use these."
        case 1: return "1 game in your library uses these now."
        case let n: return "\(n) games in your library use these now."
        }
    }
}
