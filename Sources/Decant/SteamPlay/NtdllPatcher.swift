import Foundation

/// A byte-exact recipe that turns one known clean ntdll.dll into its Steam-bridge copy.
struct NtdllRecipe: Sendable {
    struct Write: Sendable {
        let offset: Int
        let hex: String
    }

    let arch: String            // "x86_64-windows" or "i386-windows"
    let cleanSHA256: String
    let patchedSHA256: String
    let patchedSize: Int
    let writes: [Write]
}

enum NtdllPatchError: LocalizedError {
    case unknownBuild(String)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownBuild(let arch):
            return "This engine's \(arch) Wine core is a build Decant has no Steam bridge patch for yet. A Decant update will add it."
        case .verifyFailed(let arch):
            return "Patching the \(arch) Wine core did not give the expected result, so Decant left it alone."
        }
    }
}

enum NtdllPatcher {
    static func recipe(arch: String, cleanSHA256: String) -> NtdllRecipe? {
        NtdllRecipes.all.first { $0.arch == arch && $0.cleanSHA256 == cleanSHA256 }
    }

    /// True when every arch of this engine has a recipe, i.e. the Steam bridge can be built for it.
    static func supports(wineLib: URL) -> Bool {
        for arch in ["x86_64-windows", "i386-windows"] {
            let file = wineLib.appendingPathComponent("\(arch)/ntdll.dll")
            guard let sha = try? Downloader.sha256(of: file) else { return false }
            if recipe(arch: arch, cleanSHA256: sha) == nil && NtdllRecipes.all.first(where: { $0.arch == arch && $0.patchedSHA256 == sha }) == nil {
                return false
            }
        }
        return true
    }

    /// Patches `file` in place. Already-patched files are left as they are.
    static func patch(_ file: URL, arch: String) throws {
        let sha = try Downloader.sha256(of: file)
        if NtdllRecipes.all.contains(where: { $0.arch == arch && $0.patchedSHA256 == sha }) { return }
        guard let recipe = recipe(arch: arch, cleanSHA256: sha) else { throw NtdllPatchError.unknownBuild(arch) }

        var data = try Data(contentsOf: file)
        if data.count < recipe.patchedSize {
            data.append(Data(count: recipe.patchedSize - data.count))
        }
        for write in recipe.writes {
            guard let bytes = Data(hexString: write.hex), write.offset + bytes.count <= data.count else {
                throw NtdllPatchError.verifyFailed(arch)
            }
            data.replaceSubrange(write.offset..<(write.offset + bytes.count), with: bytes)
        }
        let tmp = file.appendingPathExtension("decant-tmp")
        try data.write(to: tmp)
        guard (try? Downloader.sha256(of: tmp)) == recipe.patchedSHA256 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NtdllPatchError.verifyFailed(arch)
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let b = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self.init(bytes)
    }
}
