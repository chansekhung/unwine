import SwiftUI

/// The game page's "Launch options and mods": the added game's own launch options, extra NAME=value
/// settings, DLL overrides for mod loaders and the game's language. Switches and the picker apply at
/// once. Typed text waits for Save (or Return), and is saved when the page closes.
struct LaunchOptionsEditor: View {
    @Environment(AppModel.self) private var model
    let game: SteamGame
    /// The game whose settings a launcher runs with: its extra settings, DLLs and language rule here.
    let followed: LocalGameRecord?

    @State private var arguments = ""
    @State private var extra = ""
    @State private var otherDLLs = ""

    private var isLocal: Bool { game.localExe != nil }
    private var saved: LaunchOptions { model.launchOptions(for: game.id) }
    private var knownDLLs: [String] { LaunchOptions.modLoaderDLLs.map(\.name) }
    private var savedOthers: [String] { saved.dllOverrides.filter { !knownDLLs.contains($0) } }

    private var dirty: Bool {
        (isLocal && arguments != saved.arguments)
            || (followed == nil && (extra != saved.extraSettings || LaunchOptions.dllNames(in: otherDLLs).names != savedOthers))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLocal { argumentsField }
            if let followed {
                note("Extra settings, DLL overrides and the game language come from \(followed.name), because the game that this \(role) opens gets them. Open \(followed.name) to change them.", warn: false)
            } else {
                extraSettingsField
                dllOverrides
                languagePicker
                if !isLocal {
                    note("Steam's own Launch Options work too, but Wine gets only these names from them: \(LaunchOptions.steamPassesNames). Extra settings here reach every name, because Unwine's Steam tool reads this game's settings each time a program starts. When a name is in both places, Unwine's value wins. DLL overrides from both places add up.", warn: false)
                }
            }
            saveRow
        }
        .onAppear(perform: load)
        .onChange(of: game.id) { load() }
        .onDisappear { if dirty { save() } }
    }

    private var role: String { game.localExe.flatMap(LocalGames.role(of:))?.lowercased() ?? "program" }

    // MARK: Launch options

    private var argumentsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Launch options")
            TextField("", text: $arguments, prompt: Text("For example -windowed -skipintro"))
                .modifier(FieldLook())
                .onSubmit(save)
                .help("What follows the program's name when it starts, as in a Windows shortcut")
            if let words = LaunchOptions.words(arguments) {
                note(words.isEmpty
                     ? "Options go after the program's name, as in a Windows shortcut. Put an option with spaces in quotes."
                     : "The game starts with \(words.count == 1 ? "1 option" : "\(words.count) options"): \(words.joined(separator: "  ")).",
                     warn: false)
            } else {
                note("A quote is not closed. Close it, or the game does not start.", warn: true)
            }
        }
    }

    // MARK: Extra settings

    private var extraSettingsField: some View {
        let parsed = LaunchOptions.settings(in: extra)
        return VStack(alignment: .leading, spacing: 6) {
            heading("Extra settings")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $extra)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                if extra.isEmpty {
                    Text("DXVK_HUD=fps").foregroundStyle(Palette.muted.opacity(0.6))
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .modifier(FieldLook())
            if parsed.problems.isEmpty {
                note("One NAME=value on each line, for example DXVK_HUD=fps. Every program in the game's bottle gets them, and a name here wins over Unwine's own value. A WINEDLLOVERRIDES line adds to the DLL overrides.", warn: false)
            } else {
                ForEach(parsed.problems, id: \.line) { p in
                    note("Line \(p.line) is not used. \(p.text)", warn: true)
                }
            }
        }
    }

    // MARK: DLL overrides

    private var dllOverrides: some View {
        let rejected = LaunchOptions.dllNames(in: otherDLLs).rejected
        return VStack(alignment: .leading, spacing: 6) {
            heading("DLL overrides for mods")
            HStack(spacing: 14) {
                ForEach(LaunchOptions.modLoaderDLLs, id: \.name) { dll in
                    Toggle(dll.name, isOn: dllBinding(dll.name))
                        .toggleStyle(.checkbox)
                        .help("\(dll.name).dll: \(dll.use)")
                }
            }
            .font(.system(size: 12))
            TextField("", text: $otherDLLs, prompt: Text("Other DLL names, for example xinput1_3"))
                .modifier(FieldLook())
                .onSubmit(save)
            if rejected.isEmpty {
                note("Tick the DLL that your mod loader puts next to the game. Wine then loads that file first, and its own copy only when the game folder has none.", warn: false)
            } else {
                note("These are not DLL names, so Unwine does not use them: \(rejected.joined(separator: ", ")).", warn: true)
            }
        }
    }

    private func dllBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { saved.dllOverrides.contains(name) },
                set: { on in
                    model.setLaunchOptions(game.id) { o in
                        o.dllOverrides.removeAll { $0 == name }
                        if on { o.dllOverrides.insert(name, at: 0) }
                    }
                })
    }

    // MARK: Game language

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Game language", selection: Binding(get: { saved.language },
                                                       set: { v in model.setLaunchOptions(game.id) { $0.language = v } })) {
                ForEach(GameLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let page = saved.language.codePage, saved.language != .automatic {
                note("The game sees Windows in \(saved.language.title). Old games that are not Unicode then show their text with code page \(page). If the text still looks broken, pick another language.", warn: false)
            } else {
                note(isLocal ? "Automatic: the game sees Windows in English (United States). Pick the game's own language when its text looks broken or comes in the wrong language."
                             : "Automatic: Steam Play uses the language of your Mac, and Online mode uses English. Pick the game's own language when its text looks broken or comes in the wrong language.",
                     warn: false)
            }
        }
    }

    // MARK: Saving

    @ViewBuilder private var saveRow: some View {
        if dirty {
            HStack(spacing: 8) {
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle())
                    .help("Saves what you typed. It applies the next time the game starts.")
                Button("Undo changes", action: load).buttonStyle(QuietButtonStyle())
                    .help("Goes back to what is saved")
                Text("Not saved yet.").font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
        } else {
            note("These apply the next time the game starts. Reset settings does not change them.", warn: false)
        }
    }

    private func load() {
        let o = model.launchOptions(for: game.id)
        arguments = o.arguments
        extra = o.extraSettings
        otherDLLs = o.dllOverrides.filter { !knownDLLs.contains($0) }.joined(separator: ", ")
    }

    private func save() {
        let typed = LaunchOptions.dllNames(in: otherDLLs).names
        let known = knownDLLs, isLocal = isLocal, followed = followed
        let arguments = arguments, extra = extra
        model.setLaunchOptions(game.id) { o in
            if isLocal { o.arguments = arguments }
            if followed == nil {
                o.extraSettings = extra
                // A mod loader's DLL typed in the field ticks its box.
                let ticked = o.dllOverrides.filter { known.contains($0) }
                o.dllOverrides = ticked + typed.filter { known.contains($0) && !ticked.contains($0) } + typed.filter { !known.contains($0) }
            }
        }
        load()
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).padding(.top, 2)
    }

    private func note(_ text: String, warn: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warn ? Palette.warn : Palette.muted).padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A text field drawn like the rest of the game page: a quiet rounded box with monospaced text.
private struct FieldLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.stroke))
    }
}
