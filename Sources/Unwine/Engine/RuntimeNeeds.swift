import Foundation

/// A Microsoft runtime a Windows app can need: one installer, for one CPU width.
enum RuntimeID: String, Codable, CaseIterable, Sendable {
    case vc14x64, vc14x86                       // Visual C++ 2015 to 2026: one runtime, updated in place
    case vc2013x64, vc2013x86
    case vc2012x64, vc2012x86
    case vc2010x64, vc2010x86
    case vc2008x64, vc2008x86
    case vc2005x64, vc2005x86
    case netfx48                                // .NET Framework 4.8 (both widths in one installer)
    case desktop6x64, desktop6x86               // .NET 6 and 7: out of support, their last builds stay pinned
    case desktop7x64, desktop7x86
    case desktop8x64, desktop8x86               // .NET 8 Desktop Runtime (WinForms and WPF on modern .NET)
    case desktop9x64, desktop9x86
    case desktop10x64, desktop10x86
    case webview2                               // Microsoft Edge WebView2, a web page inside an app

    /// The Visual C++ runtime that a DLL name belongs to, for programs of `is64` width. Exact release
    /// names only: a Debug build's DLLs (msvcp140d.dll) come with no runtime (see `isDebugLibrary`).
    static func visualC(for dll: String, is64: Bool) -> RuntimeID? {
        let n = dll.lowercased()
        guard n.hasSuffix(".dll") else { return nil }
        let stem = String(n.dropLast(4))
        func years(_ v: String) -> [String] { ["msvcr\(v)", "msvcp\(v)", "mfc\(v)", "mfc\(v)u", "mfcm\(v)", "mfcm\(v)u", "vcomp\(v)"] }
        let families: [(names: [String], x64: RuntimeID, x86: RuntimeID)] = [
            (["vcruntime140", "vcruntime140_1", "vcruntime140_threads", "msvcp140", "msvcp140_1", "msvcp140_2",
              "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "concrt140", "vcomp140", "vcamp140",
              "mfc140", "mfc140u", "mfcm140", "mfcm140u", "vccorlib140"], .vc14x64, .vc14x86),
            (years("120"), .vc2013x64, .vc2013x86),
            (years("110"), .vc2012x64, .vc2012x86),
            (years("100"), .vc2010x64, .vc2010x86),
            (years("90"), .vc2008x64, .vc2008x86),
            (years("80") + ["vcomp"], .vc2005x64, .vc2005x86),      // vcomp.dll has no year in its name
        ]
        guard let f = families.first(where: { $0.names.contains(stem) }) else { return nil }
        return is64 ? f.x64 : f.x86
    }

    /// A Debug build's Visual C++ library (vcruntime140d.dll, msvcp140d_atomic_wait.dll, ucrtbased.dll).
    /// Only Visual Studio has these: no Microsoft runtime installs them.
    static func isDebugLibrary(_ dll: String) -> Bool {
        let stem = String(dll.lowercased().dropLast(dll.lowercased().hasSuffix(".dll") ? 4 : 0))
        if stem == "ucrtbased" { return true }
        return ["vcruntime140d", "vcruntime140_1d", "msvcp140d", "concrt140d", "vcomp140d", "mfc140d", "mfc140ud",
                "msvcr120d", "msvcp120d", "msvcr110d", "msvcp110d", "msvcr100d", "msvcp100d", "msvcr90d", "msvcp90d"]
            .contains { stem == $0 || stem.hasPrefix($0 + "_") }
    }

    static func desktop(major: Int, is64: Bool) -> RuntimeID? {
        switch major {
        case 6: return is64 ? .desktop6x64 : .desktop6x86
        case 7: return is64 ? .desktop7x64 : .desktop7x86
        case 8: return is64 ? .desktop8x64 : .desktop8x86
        case 9: return is64 ? .desktop9x64 : .desktop9x86
        case 10: return is64 ? .desktop10x64 : .desktop10x86
        default: return nil
        }
    }
}

/// One runtime an app needs, and why Unwine thinks so.
struct RuntimeNeed: Codable, Equatable, Sendable {
    var runtime: RuntimeID
    /// What Unwine found, said for the app page: "FEMM uses MFC, which Wine does not have".
    var reason: String
    /// True when the app cannot start without it. False when Wine's own stand-in may do.
    var required: Bool
}

/// Reads an app's files and says which Microsoft runtimes it needs. A DLL the app ships next to its
/// program is its own copy, so it needs no runtime for it. Wine has its own Visual C++ libraries,
/// so those count only when the app uses a function Wine's copy lacks. Wine has no MFC (Microsoft's
/// window library for C++ apps), no .NET 8 and no WebView2, so those always count.
enum RuntimeNeeds {
    /// `builtin` answers with the path of Wine's own copy of a DLL for a width, if Wine has one.
    static func read(exe: URL, builtin: (String, Bool) -> URL?) -> [RuntimeNeed] {
        let fm = FileManager.default
        let folder = exe.deletingLastPathComponent()
        let local = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        guard let info = PEInspector.inspect(exe) else { return [] }
        let is64 = info.is64Bit
        var needs: [RuntimeNeed] = []
        func add(_ need: RuntimeNeed) {
            if let i = needs.firstIndex(where: { $0.runtime == need.runtime }) {
                if need.required && !needs[i].required { needs[i] = need }
            } else {
                needs.append(need)
            }
        }

        // The program and the DLLs beside it: an app keeps much of its code in its own DLLs. Only the
        // ones that use a Visual C++ DLL the folder does not ship can add a need. In name order, so each
        // look gives the same answer.
        var binaries: [(url: URL, is64: Bool, imports: Set<String>)] = [(exe, is64, info.imports)]
        for file in local.sorted() where file.hasSuffix(".dll") && binaries.count < 500 {
            let url = folder.appendingPathComponent(file)
            guard let i = PEInspector.inspect(url),
                  i.imports.contains(where: { RuntimeID.visualC(for: $0, is64: i.is64Bit) != nil && !local.contains($0) }) else { continue }
            binaries.append((url, i.is64Bit, i.imports))
        }
        // Wine's export lists, read once per DLL and width.
        var wineExports: [String: Set<String>] = [:]
        for binary in binaries {
            let runtimeDLLs = binary.imports.filter { RuntimeID.visualC(for: $0, is64: binary.is64) != nil && !local.contains($0) }
            guard !runtimeDLLs.isEmpty else { continue }
            let used = PEInspector.importedFunctions(binary.url, from: runtimeDLLs)
            for dll in runtimeDLLs.sorted() {
                guard let runtime = RuntimeID.visualC(for: dll, is64: binary.is64) else { continue }
                let who = binary.url.lastPathComponent
                if dll.hasPrefix("mfc") {
                    add(RuntimeNeed(runtime: runtime, reason: "\(who) uses MFC (\(dll)), which Wine does not have.", required: true))
                    continue
                }
                guard let copy = builtin(dll, binary.is64) else {
                    add(RuntimeNeed(runtime: runtime, reason: "\(who) uses \(dll), which Wine does not have.", required: true))
                    continue
                }
                // Wine's copy is there. It counts only when it lacks a function the app takes from it.
                let key = "\(dll)-\(binary.is64)"
                let exports = wineExports[key] ?? (PEInspector.exportedNames(copy) ?? [])
                wineExports[key] = exports
                let missing = (used[dll] ?? []).subtracting(exports)
                if !missing.isEmpty {
                    add(RuntimeNeed(runtime: runtime, reason: "\(who) uses \(missing.count) \(missing.count == 1 ? "part" : "parts") of \(dll) that Wine's own copy does not have.", required: true))
                }
            }
        }

        // .NET: modern .NET says its runtime in <program>.runtimeconfig.json, or inside the program
        // when it is a single file (SDR# is). An app that ships its runtime (self-contained) lists it
        // under includedFrameworks and needs nothing.
        if let options = runtimeOptions(exe) {
            for asked in frameworkMajors(options) {
                let major = resolvedMajor(asked, options: options)
                if let runtime = RuntimeID.desktop(major: major, is64: is64) {
                    let rolled = major == asked ? "" : " It may use .NET \(major) too."
                    add(RuntimeNeed(runtime: runtime, reason: "\(exe.lastPathComponent) is built for .NET \(asked).\(rolled)", required: true))
                }
            }
        } else if let clr = PEInspector.dotNetRuntime(exe), clr.hasPrefix("v4.") {
            // .NET Framework 4: Wine Mono, Wine's own .NET, runs many of these. WPF windows are its weak part.
            let wpf = !PEInspector.fileMentions(exe, anyOf: ["PresentationFramework"]).isEmpty
            add(RuntimeNeed(runtime: .netfx48,
                            reason: wpf ? "\(exe.lastPathComponent) is a .NET Framework app with WPF windows. Wine's own .NET draws those poorly."
                                        : "\(exe.lastPathComponent) is a .NET Framework app. Wine's own .NET runs many of these. If it fails, use Microsoft's.",
                            required: wpf))
        }

        // WebView2: the app shows web pages with Microsoft Edge's engine.
        if local.contains("webview2loader.dll") || info.imports.contains("webview2loader.dll") {
            add(RuntimeNeed(runtime: .webview2, reason: "\(exe.lastPathComponent) shows web pages with Microsoft Edge WebView2.", required: true))
        }
        let order = RuntimeID.allCases
        return needs.sorted { order.firstIndex(of: $0.runtime)! < order.firstIndex(of: $1.runtime)! }
    }

    /// What the program needs that no runtime Unwine offers gives it, said for the app page: a Debug
    /// build's libraries, or a .NET version Unwine has no pinned installer for. Empty when there is none.
    static func unoffered(exe: URL) -> [String] {
        guard let info = PEInspector.inspect(exe) else { return [] }
        let folder = exe.deletingLastPathComponent()
        let local = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        var out: [String] = []
        // Only the program's own imports count: a debug plugin beside it may never load.
        let debug = info.imports.filter { RuntimeID.isDebugLibrary($0) && !local.contains($0) }.sorted()
        if let first = debug.first {
            out.append("\(exe.lastPathComponent) is a Debug build. It needs Visual Studio's debug libraries (\(first)), which no Microsoft runtime installs. Ask its maker for a Release build.")
        }
        for major in dotNetMajors(exe) where RuntimeID.desktop(major: major, is64: info.is64Bit) == nil {
            out.append("\(exe.lastPathComponent) is built for .NET \(major), which Unwine cannot install yet.")
        }
        return out
    }

    /// The .NET majors a modern .NET program asks for, after its roll-forward rule.
    static func dotNetMajors(_ exe: URL) -> [Int] {
        guard let options = runtimeOptions(exe) else { return [] }
        return frameworkMajors(options).map { resolvedMajor($0, options: options) }
    }

    /// The "runtimeOptions" of a modern .NET program that uses a shared runtime: from
    /// <program>.runtimeconfig.json, or from inside a single-file program (SDR# is one). Nil for a
    /// program that ships its runtime (includedFrameworks) or is no modern .NET program.
    static func runtimeOptions(_ exe: URL) -> [String: Any]? {
        let config = exe.deletingLastPathComponent().appendingPathComponent("\(exe.deletingPathExtension().lastPathComponent).runtimeconfig.json")
        guard let data = (try? Data(contentsOf: config)) ?? (PEInspector.dotNetRuntime(exe) == nil ? embeddedConfig(exe) : nil),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = json["runtimeOptions"] as? [String: Any], options["includedFrameworks"] == nil else { return nil }
        return options
    }

    /// The majors of the Desktop or base runtime the options ask for. The Desktop Runtime holds both;
    /// ASP.NET apps are servers, not Windows apps.
    static func frameworkMajors(_ options: [String: Any]) -> [Int] {
        var frameworks = (options["frameworks"] as? [[String: Any]]) ?? []
        if let one = options["framework"] as? [String: Any] { frameworks.append(one) }
        let majors = frameworks.compactMap { f -> Int? in
            guard let name = f["name"] as? String, name == "Microsoft.WindowsDesktop.App" || name == "Microsoft.NETCore.App",
                  let version = f["version"] as? String else { return nil }
            return Int(version.split(separator: ".").first ?? "")
        }
        return Array(Set(majors)).sorted()
    }

    /// The major a program runs on: its own, or with rollForward "Major" or "LatestMajor", the lowest
    /// newer one Unwine has pinned, when its own is not pinned.
    static func resolvedMajor(_ major: Int, options: [String: Any]) -> Int {
        let roll = (options["rollForward"] as? String)?.lowercased()
        guard roll == "major" || roll == "latestmajor", RuntimeID.desktop(major: major, is64: true) == nil else { return major }
        return (major...20).first { RuntimeID.desktop(major: $0, is64: true) != nil } ?? major
    }

    /// The runtimeconfig.json that a single-file .NET program carries inside itself: the JSON object
    /// around its "runtimeOptions" key. Reads at most the first 64 MB.
    static func embeddedConfig(_ exe: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? handle.close() }
        let key = Data("\"runtimeOptions\"".utf8)
        let chunk = 4 << 20, overlap = 4096
        var offset: UInt64 = 0
        while offset < 64 << 20 {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: chunk + overlap), !data.isEmpty else { return nil }
            if let hit = data.range(of: key) {
                // Back to the "{" that opens the object, then forward to the "}" that closes it.
                guard let open = data[..<hit.lowerBound].lastIndex(of: UInt8(ascii: "{")),
                      hit.lowerBound - open < 64 else { return nil }
                var depth = 0
                for i in open..<min(data.endIndex, open + 16_384) {
                    if data[i] == UInt8(ascii: "{") { depth += 1 }
                    if data[i] == UInt8(ascii: "}") { depth -= 1; if depth == 0 { return data[open...i] } }
                }
                return nil
            }
            if data.count < chunk + overlap { return nil }
            offset += UInt64(chunk)
        }
        return nil
    }
}
