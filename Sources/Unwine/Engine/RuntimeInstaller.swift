import Foundation

/// Installs a Microsoft runtime into one app's Windows bottle: Microsoft's own installer, from
/// Microsoft's server, checked against its pinned SHA-256, run silently with the app's own settings.
/// The installer files are Microsoft's; Unwine only downloads, checks and starts them.
enum RuntimeInstaller {
    enum Phase: Sendable, Equatable {
        case downloading(Double?)       // 0...1 when the size is known
        case checking                   // the SHA-256 check
        case installing                 // Microsoft's installer runs in the bottle
        case finishing                  // Wine saves the bottle; Unwine sets which DLLs load
    }

    enum Failure: LocalizedError {
        case installer(String, Int32)
        case notThere(String)
        case monoStays

        var errorDescription: String? {
            switch self {
            case .installer(let name, let code):
                return "Microsoft's installer for \(name) stopped with code \(RuntimeInstaller.windowsCode(code)). The app's log has its output."
            case .notThere(let name):
                return "Microsoft's installer for \(name) ended, but its files are not in the bottle. The app's log has its output."
            case .monoStays:
                return "Unwine could not take Wine Mono out of the bottle, so Microsoft's installer would install nothing. The app's log has the details."
            }
        }
    }

    /// The installers wait here while they download. One file serves every bottle; it goes once installed.
    static var folder: URL { Paths.downloads.appendingPathComponent("Runtimes", isDirectory: true) }

    /// Installer exit codes that mean it worked: done, done but Windows wants a restart (Wine needs
    /// none), and "this version or a newer one is there already". A Mac program's exit status keeps
    /// only the low byte of Windows' code, so 3010, 1641 and 1638 arrive as 194, 105 and 102.
    private static let fine: Set<Int32> = [0, 3010 & 0xFF, 1641 & 0xFF, 1638 & 0xFF]

    /// The Windows code an exit status most likely stands for, for the log and the message.
    static func windowsCode(_ status: Int32) -> String {
        let known: [Int32: Int32] = [194: 3010, 105: 1641, 102: 1638, 67: 1603, 66: 1602]
        return known[status].map { "\($0)" } ?? "\(status)"
    }

    /// Downloads, checks and runs the installer in the closed bottle `prefix`, then makes Wine load
    /// the runtime's own DLLs before Wine's stand-ins. `env` is the app's environment (without Faster
    /// x87 math). Throws when the download, the check or the installer fails.
    static func install(_ runtime: WindowsRuntime, prefix: URL, engine: InstalledEngine, env: [String: String],
                        log: LogFile, phase: @escaping @Sendable (Phase) -> Void) async throws {
        try Paths.ensure(folder)
        let file = folder.appendingPathComponent(runtime.fileName)
        log.line("Downloading \(runtime.title) \(runtime.version) from \(runtime.url.host ?? "Microsoft")")
        phase(.downloading(nil))
        _ = try await Downloader.fetch(runtime.url, to: file, expectedBytes: runtime.bytes, sha256: runtime.sha256) { p in
            phase(p.map { .downloading($0) } ?? .checking)
        }
        log.line("The download matches its SHA-256 (\(runtime.sha256.prefix(12))…)")

        phase(.installing)
        // .NET Framework 4.8 is part of Windows 10, so its installer installs nothing when Wine says
        // "Windows 10". Wine says "Windows 7" while it runs, then what it said before.
        var windows: String?
        if runtime.id == .netfx48 {
            // Nor does it install over Wine Mono, Wine's own stand-in: Microsoft's installer reads it as 4.8.1.
            await removeWineMono(prefix: prefix, engine: engine, env: env, log: log)
            guard !reportsNetFramework(prefix) else {
                log.line("Wine Mono's .NET 4.8.1 entry is still in the bottle after its removal")
                throw Failure.monoStays
            }
            windows = windowsVersion(prefix)
            _ = try? await Shell.run(engine.wine, ["winecfg", "/v", "win7"], env: env, log: log, check: false)
        }
        log.line("Installing \(runtime.title) in \(prefix.deletingLastPathComponent().lastPathComponent)")
        let result = try await Shell.run(engine.wine, [file.path] + runtime.arguments, env: env,
                                         cwd: file.deletingLastPathComponent(), log: log, check: false)
        if let windows { _ = try? await Shell.run(engine.wine, ["winecfg", "/v", windows], env: env, log: log, check: false) }
        // The installer can leave helpers behind for a moment. The bottle's server ends with the last one.
        _ = try? await Shell.run(engine.wineserver, ["-w"], env: env, log: log, check: false)
        log.line("\(runtime.title): the installer ended with code \(windowsCode(result.status))")
        // An unknown code that left the runtime's files in place still gets its DLL settings: else the
        // page would show it as installed while Wine kept using its own copies.
        guard fine.contains(result.status) || RuntimeState.hasFiles(runtime.id, prefix: prefix) else {
            throw Failure.installer(runtime.title, result.status)
        }

        phase(.finishing)
        if !runtime.dlls.isEmpty {
            let entries = runtime.dlls.map {
                BottleRegistry.Entry(key: #"Software\Wine\DllOverrides"#, name: $0, value: .string("native,builtin"))
            }
            if await BottleRegistry.write(entries, prefix: prefix, engine: engine, msync: env["WINEMSYNC"], log: log) == .failed {
                log.line("Warning: Wine may still use its own copies of \(runtime.dlls.joined(separator: ", "))")
            }
        }
        guard RuntimeState.isInstalled(runtime.id, prefix: prefix) else { throw Failure.notThere(runtime.title) }
        RuntimeState.record(runtime.id, prefix: prefix)
        try? FileManager.default.removeItem(at: file)
        log.line("\(runtime.title) is installed")
    }

    /// Takes Wine Mono's Windows part out of a bottle, with Wine's own uninstaller. While it is there,
    /// Microsoft's installer reads Wine Mono's registry entry as .NET 4.8.1 and installs nothing.
    private static func removeWineMono(prefix: URL, engine: InstalledEngine, env: [String: String], log: LogFile) async {
        for id in wineMonoEntries(prefix) {
            log.line("Removing Wine Mono (\(id)) before .NET Framework goes in")
            _ = try? await Shell.run(engine.wine, ["uninstaller", "--remove", id], env: env, log: log, check: false)
        }
        _ = try? await Shell.run(engine.wineserver, ["-w"], env: env, log: log, check: false)
    }

    /// The Windows version Wine reports in a closed bottle, as winecfg names it. Windows 10 when unsure.
    static func windowsVersion(_ prefix: URL) -> String {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8),
              let key = text.range(of: #"[Software\\Microsoft\\Windows NT\\CurrentVersion]"#) else { return "win10" }
        let block = text[key.upperBound...].prefix { $0 != "[" }
        func value(_ name: String) -> String? {
            guard let r = block.range(of: "\"\(name)\"=\"") else { return nil }
            return String(block[r.upperBound...].prefix { $0 != "\"" })
        }
        // Windows 10 and 11 still say "6.3" in CurrentVersion, so the build number decides.
        switch Int(value("CurrentBuild") ?? "") ?? 19045 {
        case 22_000...: return "win11"
        case 10_240...: return "win10"
        case 9600...: return "win81"
        case 9200...: return "win8"
        default: return "win7"
        }
    }

    /// The uninstall entries ({GUID}) whose name starts with "Wine Mono", read from the closed bottle's
    /// registry. Wine Mono's support package is a 32-bit installer, so a 64-bit bottle lists it under
    /// Wow6432Node; both places are read.
    static func wineMonoEntries(_ prefix: URL) -> [String] {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return [] }
        var found: [String] = []
        for head in [#"[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"#,
                     #"[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"#] {
            var at = text.startIndex
            while let key = text.range(of: head, range: at..<text.endIndex) {
                at = key.upperBound
                guard let close = text[at...].firstIndex(of: "]") else { break }
                let id = String(text[at..<close])
                let block = text[close...].prefix { $0 != "[" }
                if id.hasPrefix("{"), block.contains("\"DisplayName\"=\"Wine Mono"), !found.contains(id) { found.append(id) }
            }
        }
        return found
    }

    /// The closed bottle's registry says a .NET Framework 4.x is there (Wine Mono writes this too).
    static func reportsNetFramework(_ prefix: URL) -> Bool {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return false }
        for head in [#"[Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full]"#,
                     #"[Software\\Wow6432Node\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full]"#] {
            guard let key = text.range(of: head) else { continue }
            if text[key.upperBound...].prefix(while: { $0 != "[" }).contains("\"Release\"=") { return true }
        }
        return false
    }
}

/// Which runtimes a bottle holds. Unwine keeps a list in the bottle, and also looks at the files, so a
/// runtime the app's own installer put in counts too.
enum RuntimeState {
    private static func listFile(_ prefix: URL) -> URL { prefix.appendingPathComponent(".unwine-runtimes") }

    static func recorded(_ prefix: URL) -> Set<RuntimeID> {
        guard let text = try? String(contentsOf: listFile(prefix), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { RuntimeID(rawValue: String($0)) })
    }

    static func record(_ id: RuntimeID, prefix: URL) {
        let all = recorded(prefix).union([id]).map(\.rawValue).sorted()
        try? (all.joined(separator: "\n") + "\n").write(to: listFile(prefix), atomically: true, encoding: .utf8)
    }

    /// True when the runtime is ready in the bottle: its files are there, and for Visual C++, the bottle
    /// tells Wine to load Microsoft's DLLs first. Without that, Wine's own copies win over Microsoft's in
    /// system32 (an app's own setup puts the files in but not the setting). Reads a few folders and
    /// user.reg, so call it off the main thread.
    static func isInstalled(_ id: RuntimeID, prefix: URL) -> Bool {
        guard hasFiles(id, prefix: prefix) else { return false }
        return !id.rawValue.hasPrefix("vc") || nativeFirst(WindowsRuntime.pinned(id).dlls, prefix: prefix)
    }

    /// The bottle's DllOverrides name each DLL with a native-first value ("native,builtin", "n,b", "native").
    static func nativeFirst(_ dlls: [String], prefix: URL) -> Bool {
        guard !dlls.isEmpty else { return true }
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) else { return false }
        let saved = BottleRegistry.saved(#"Software\Wine\DllOverrides"#, in: text)
        let values = Dictionary(saved.map { ($0.key.lowercased(), $0.value.lowercased()) }, uniquingKeysWith: { a, _ in a })
        return dlls.allSatisfy { values[$0.lowercased()]?.hasPrefix("\"n") == true }
    }

    /// True when the runtime's files are in the bottle.
    static func hasFiles(_ id: RuntimeID, prefix: URL) -> Bool {
        let fm = FileManager.default
        let c = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let system64 = c.appendingPathComponent("windows/system32", isDirectory: true)
        let system32 = c.appendingPathComponent("windows/syswow64", isDirectory: true)
        // MFC comes only with Microsoft's runtime: Wine has no copy of it, so its file is a sure sign.
        func mfc(_ name: String, x64: Bool) -> Bool { fm.fileExists(atPath: (x64 ? system64 : system32).appendingPathComponent(name).path) }
        // 2005 and 2008 keep their files in WinSxS, in folders named for the runtime.
        func sxs(_ part: String) -> Bool {
            let dir = c.appendingPathComponent("windows/winsxs", isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.lowercased().contains(part) }
        }
        func dotnet(_ major: Int, x64: Bool) -> Bool {
            let dir = c.appendingPathComponent("\(x64 ? "Program Files" : "Program Files (x86)")/dotnet/shared/Microsoft.WindowsDesktop.App", isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasPrefix("\(major).") }
        }
        switch id {
        case .vc14x64: return mfc("mfc140u.dll", x64: true)
        case .vc14x86: return mfc("mfc140u.dll", x64: false)
        case .vc2013x64: return mfc("mfc120u.dll", x64: true)
        case .vc2013x86: return mfc("mfc120u.dll", x64: false)
        case .vc2012x64: return mfc("mfc110u.dll", x64: true)
        case .vc2012x86: return mfc("mfc110u.dll", x64: false)
        case .vc2010x64: return mfc("mfc100u.dll", x64: true)
        case .vc2010x86: return mfc("mfc100u.dll", x64: false)
        case .vc2008x64: return sxs("amd64_microsoft.vc90.mfc_")
        case .vc2008x86: return sxs("x86_microsoft.vc90.mfc_")
        case .vc2005x64: return sxs("amd64_microsoft.vc80.mfc_")
        case .vc2005x86: return sxs("x86_microsoft.vc80.mfc_")
        case .netfx48:
            // Wine Mono writes .NET 4.8.1's registry entry too, so only Microsoft's own runtime file counts.
            // Wine Mono has no clr.dll.
            let framework = c.appendingPathComponent("windows/Microsoft.NET", isDirectory: true)
            return fm.fileExists(atPath: framework.appendingPathComponent("Framework64/v4.0.30319/clr.dll").path)
                && fm.fileExists(atPath: framework.appendingPathComponent("Framework/v4.0.30319/clr.dll").path)
        case .desktop6x64: return dotnet(6, x64: true)
        case .desktop6x86: return dotnet(6, x64: false)
        case .desktop7x64: return dotnet(7, x64: true)
        case .desktop7x86: return dotnet(7, x64: false)
        case .desktop8x64: return dotnet(8, x64: true)
        case .desktop8x86: return dotnet(8, x64: false)
        case .desktop9x64: return dotnet(9, x64: true)
        case .desktop9x86: return dotnet(9, x64: false)
        case .desktop10x64: return dotnet(10, x64: true)
        case .desktop10x86: return dotnet(10, x64: false)
        case .webview2:
            let dir = c.appendingPathComponent("Program Files (x86)/Microsoft/EdgeWebView/Application", isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains {
                fm.fileExists(atPath: dir.appendingPathComponent("\($0)/msedgewebview2.exe").path)
            }
        }
    }
}
