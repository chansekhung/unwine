import AppKit
import Foundation
import UniformTypeIdentifiers

/// Each Windows app's own small Mac app in ~/Applications/Unwine Apps, so it shows in Launchpad,
/// Spotlight and the Dock, and Finder can open files with it. The Mac app is a copy of Unwine's own
/// program (an APFS clone, no extra space) that starts as a launcher: it hands the app and its files
/// to Unwine, which starts the app with its settings, and it quits once the app's window shows.
///
/// While the Windows app runs, the Dock shows it as its own app (Game.app in its bottle folder). Wine
/// must run from that bundle, whose program is Wine's loader, so the launcher cannot be the running app.
enum MacApps {
    static var folder: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unwine Apps", isDirectory: true)
    }

    /// Info.plist keys that make a copy of Unwine a launcher, and say for which program.
    static let programKey = "UnwineProgram"
    static let unwineKey = "UnwineApp"
    /// A secret only Unwine and its Mac apps know. Any web page can open an unwine:// link, so Unwine
    /// starts an app only for a request that carries it.
    static let secretKey = "UnwineKey"
    private static let executable = "Launch"
    private static let iconName = "app.icns"

    static func bundleID(_ id: Int) -> String { "app.unwine.launch.\(id)" }

    /// The program a Mac app is for, read from its Info.plist each time. Bundle(url:) keeps the first
    /// Info.plist it read for a path, so a Mac app made again at that path would keep the old program.
    static func programID(_ app: URL) -> Int? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?[programKey] as? Int
    }

    /// Every Mac app in the folder with the program it is for. A half-made app (".stage-…") is not one.
    static func all() -> [(url: URL, id: Int)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in programID(url).map { (url, $0) } }
    }

    /// The program's Mac app, wherever the user put it in the folder, or nil.
    static func find(_ id: Int) -> URL? { all().first { $0.id == id }?.url }

    /// After a crash: half-made Mac apps go, and of two Mac apps for one program, the second goes to
    /// the Trash, so Launchpad shows each app once.
    static func tidy(log: LogFile) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(".stage-") {
            try? fm.removeItem(at: item)
        }
        var seen = Set<Int>()
        for app in all() where !seen.insert(app.id).inserted {
            register(app.url, remove: true)
            if (try? fm.trashItem(at: app.url, resultingItemURL: nil)) != nil { log.line("Moved the second Mac app \(app.url.lastPathComponent) to the Trash") }
        }
    }

    /// What the Mac app should hold. Unwine compares it with the Info.plist, so it rebuilds only on a change.
    struct Plan: Equatable {
        var id: Int
        var name: String
        var fileTypes: [String]
        var unwine: String          // Unwine.app's path, which the launcher hands the app to
        var program: String         // the size and date of Unwine's program, so a new Unwine renews the copy
        var icon: String            // the icon file's size and date, so a new icon renews the Mac app
        var key: String             // the secret the launcher sends with its request
    }

    /// The size and date of a file, as a short stamp. Empty when there is no file.
    static func stamp(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let size = a[.size] as? NSNumber,
              let date = a[.modificationDate] as? Date else { return "" }
        return "\(size.int64Value)-\(Int(date.timeIntervalSince1970))"
    }

    /// The Info.plist for a plan. Extensions no other Mac app opens get rank Owner, so a double-click
    /// in Finder opens them in the Windows app; for the others (.txt, .csv) the app is a choice in
    /// Open With, and Finder's "Change All…" can make it the default.
    static func info(_ plan: Plan, icon: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": bundleID(plan.id),
            "CFBundleName": plan.name,
            "CFBundleDisplayName": plan.name,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "UnwineProgramStamp": plan.program,
            "UnwineIconStamp": plan.icon,
            programKey: plan.id,
            unwineKey: plan.unwine,
            secretKey: plan.key,
        ]
        if icon { info["CFBundleIconFile"] = iconName }
        if !plan.fileTypes.isEmpty {
            // Another Windows app's Mac app does not count: only Mac apps that open the type do.
            let free = plan.fileTypes.filter { ext in
                guard let type = UTType(filenameExtension: ext), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return true }
                let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                return (info?["CFBundleIdentifier"] as? String)?.hasPrefix("app.unwine.launch.") == true
            }
            func entry(_ exts: [String], rank: String) -> [String: Any] {
                ["CFBundleTypeExtensions": exts, "CFBundleTypeName": "\(plan.name) file", "CFBundleTypeRole": "Editor", "LSHandlerRank": rank]
            }
            let taken = plan.fileTypes.filter { !free.contains($0) }
            info["CFBundleDocumentTypes"] = [free.isEmpty ? nil : entry(free, rank: "Owner"),
                                             taken.isEmpty ? nil : entry(taken, rank: "Alternate")].compactMap { $0 }
        }
        return info
    }

    /// The plan the Mac app at `url` was built from, read back from its Info.plist.
    static func builtPlan(_ url: URL) -> Plan? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let id = info[programKey] as? Int, let name = info["CFBundleName"] as? String,
              let unwine = info[unwineKey] as? String, let program = info["UnwineProgramStamp"] as? String,
              let key = info[secretKey] as? String else { return nil }
        let types = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        return Plan(id: id, name: name, fileTypes: types.sorted(), unwine: unwine, program: program,
                    icon: info["UnwineIconStamp"] as? String ?? "", key: key)
    }

    /// A file name for the app in the folder: its name without characters Finder cannot keep.
    private static func fileName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Windows app" : clean
    }

    /// Makes or renews the program's Mac app. `icon` is the PNG of the program's own icon. Returns the
    /// app's place, or nil when it could not be made (the log says why). A few files and one codesign
    /// run, so call it off the main thread.
    @discardableResult
    static func write(_ plan: Plan, icon: URL?, log: LogFile) -> URL? {
        let fm = FileManager.default
        let old = find(plan.id)
        if let old, builtPlan(old) == plan, fm.fileExists(atPath: old.appendingPathComponent("Contents/MacOS/\(executable)").path) { return old }
        guard let source = Bundle.main.executableURL else { return nil }
        do {
            try Paths.ensure(folder)
            let stage = folder.appendingPathComponent(".stage-\(UUID().uuidString).app", isDirectory: true)
            defer { try? fm.removeItem(at: stage) }
            let macOS = try Paths.ensure(stage.appendingPathComponent("Contents/MacOS", isDirectory: true))
            let resources = try Paths.ensure(stage.appendingPathComponent("Contents/Resources", isDirectory: true))
            let program = macOS.appendingPathComponent(executable)
            if clonefile(source.path, program.path, 0) != 0 { try fm.copyItem(at: source, to: program) }
            // A copy keeps the download's quarantine mark, which Gatekeeper would check again for each
            // Mac app under its new signature. Unwine itself was approved already.
            _ = removexattr(program.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            var hasIcon = false
            if let icon, fm.fileExists(atPath: icon.path) { hasIcon = ExeIcon.writeICNS(from: icon, to: resources.appendingPathComponent(iconName)) }
            let data = try PropertyListSerialization.data(fromPropertyList: info(plan, icon: hasIcon), format: .xml, options: 0)
            try data.write(to: stage.appendingPathComponent("Contents/Info.plist"))
            // A copy keeps Unwine's signature, which names Unwine's own Info.plist. macOS starts a
            // bundle only when its signature fits, so the Mac app is signed again for itself.
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", stage.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            if sign.terminationStatus != 0 { log.line("codesign could not sign the Mac app of \(plan.name) (code \(sign.terminationStatus))") }
            // The old app is this program's own (read again just now), so it goes without the Trash.
            if let old, programID(old) == plan.id { register(old, remove: true); try? fm.removeItem(at: old) }
            var target = folder.appendingPathComponent("\(fileName(plan.name)).app", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(fileName(plan.name)) \(n).app", isDirectory: true)
                n += 1
            }
            try fm.moveItem(at: stage, to: target)
            register(target, remove: false)
            log.line("Made the Mac app \(target.lastPathComponent)\(plan.fileTypes.isEmpty ? "" : " for ." + plan.fileTypes.joined(separator: ", ."))")
            return target
        } catch {
            log.line("Could not make the Mac app of \(plan.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Takes the program's Mac app away (to the Trash), so it leaves Launchpad and Open With.
    static func remove(_ id: Int, log: LogFile) {
        guard let app = find(id) else { return }
        register(app, remove: true)
        do { try FileManager.default.trashItem(at: app, resultingItemURL: nil); log.line("Moved the Mac app \(app.lastPathComponent) to the Trash") }
        catch { log.line("Could not move the Mac app \(app.lastPathComponent) to the Trash: \(error.localizedDescription)") }
    }

    /// Tells Launch Services about a new Mac app (its file types count at once) or one that goes.
    private static func register(_ app: URL, remove: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        p.arguments = [remove ? "-u" : "-f", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

/// The file types a Windows program registered in its bottle: the extensions whose "open" command
/// starts this program. Read from Wine's registry files, so the bottle must not be written meanwhile.
enum RegisteredFileTypes {
    /// Nil when neither registry file can be read (a bottle not made yet, or on a drive that is gone),
    /// so the types from the last read stay.
    static func read(prefix: URL, exe: URL) -> [String]? {
        let name = exe.lastPathComponent.lowercased()
        var progIDs: [String: String] = [:]     // ".fem" -> "FEMM.Document"
        var opens = Set<String>()               // ProgIDs (and ".ext" keys) whose open command runs the program
        var readAny = false
        for file in ["system.reg", "user.reg"] {
            guard let text = try? String(contentsOf: prefix.appendingPathComponent(file), encoding: .utf8) else { continue }
            readAny = true
            var key: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("[") {
                    // [Software\\Classes\\.fem] 1700000000
                    key = line.dropFirst().split(separator: "]").first.map { $0.replacingOccurrences(of: "\\\\", with: "\\") }
                    continue
                }
                guard let k = key, k.lowercased().hasPrefix(#"software\classes\"#), line.hasPrefix("@=\"") else { continue }
                let path = String(k.dropFirst(#"Software\Classes\"#.count))
                let value = String(line.dropFirst(3).dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
                if path.hasPrefix("."), !path.contains("\\") {
                    progIDs[path.lowercased()] = value
                } else if path.lowercased().hasSuffix(#"\shell\open\command"#), value.lowercased().contains("\\" + name) {
                    opens.insert(String(path.dropLast(#"\shell\open\command"#.count)).lowercased())
                }
            }
        }
        guard readAny else { return nil }
        let found = progIDs.filter { ext, prog in opens.contains(prog.lowercased()) || opens.contains(ext) }.keys
            .map { String($0.dropFirst()) }
            .filter { !$0.isEmpty && $0.count <= 12 && !["exe", "dll", "lnk", "bat", "cmd", "msi"].contains($0) }
        return Array(Set(found)).sorted()
    }
}
