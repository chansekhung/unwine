import Foundation

/// Reads Windows .exe/.dll headers to learn what a game needs:
/// its CPU width and which graphics APIs it links against.
enum PEInspector {
    struct Info {
        var is64Bit: Bool
        /// Lower-cased DLL names from the import and delay-import tables.
        var imports: Set<String>
    }

    static func inspect(_ url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Headers + import tables live near the front; 8 MB covers real games while bounding memory.
        guard let data = try? handle.read(upToCount: 8 * 1024 * 1024), data.count > 0x40 else { return nil }
        return parse(data, fileURL: url)
    }

    private static func parse(_ d: Data, fileURL: URL) -> Info? {
        func u16(_ o: Int) -> Int? { o + 2 <= d.count ? Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= d.count else { return nil }
            let b = d.startIndex + o
            return Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16 | Int(d[b + 3]) << 24
        }

        guard u16(0) == 0x5A4D, let peOff = u32(0x3C), u32(peOff) == 0x0000_4550 else { return nil } // "MZ", "PE\0\0"
        let coff = peOff + 4
        guard let machine = u16(coff), let sectionCount = u16(coff + 2), let optSize = u16(coff + 16) else { return nil }
        let opt = coff + 20
        guard let magic = u16(opt) else { return nil }
        let isPE32Plus = magic == 0x20B
        let is64 = machine == 0x8664 || machine == 0xAA64 || isPE32Plus

        let dirBase = opt + (isPE32Plus ? 112 : 96)
        let rvaCountOff = opt + (isPE32Plus ? 108 : 92)
        let dirCount = u32(rvaCountOff) ?? 0

        struct Section { let va: Int; let vsize: Int; let raw: Int; let rawSize: Int }
        var sections: [Section] = []
        let secTable = opt + optSize
        for s in 0..<min(sectionCount, 96) {
            let o = secTable + s * 40
            guard let vs = u32(o + 8), let va = u32(o + 12), let rs = u32(o + 16), let rp = u32(o + 20) else { break }
            sections.append(Section(va: va, vsize: max(vs, rs), raw: rp, rawSize: rs))
        }
        func fileOffset(_ rva: Int) -> Int? {
            for s in sections where rva >= s.va && rva < s.va + s.vsize {
                let off = rva - s.va + s.raw
                return off < d.count ? off : nil
            }
            return nil
        }
        func cString(at rva: Int) -> String? {
            guard let start = fileOffset(rva) else { return nil }
            var end = start
            while end < d.count, end - start < 256, d[d.startIndex + end] != 0 { end += 1 }
            return String(data: d.subdata(in: (d.startIndex + start)..<(d.startIndex + end)), encoding: .ascii)
        }

        var imports = Set<String>()
        // Directory 1: import table (20-byte descriptors, name RVA at +12).
        if dirCount > 1, let rva = u32(dirBase + 8), rva != 0, var o = fileOffset(rva) {
            for _ in 0..<512 {
                guard let nameRVA = u32(o + 12), let thunk = u32(o + 16) else { break }
                if nameRVA == 0 && thunk == 0 { break }
                if let name = cString(at: nameRVA) { imports.insert(name.lowercased()) }
                o += 20
            }
        }
        // Directory 13: delay-load imports (32-byte descriptors, name RVA at +4).
        if dirCount > 13, let rva = u32(dirBase + 13 * 8), rva != 0, var o = fileOffset(rva) {
            for _ in 0..<512 {
                guard let attrs = u32(o), let nameRVA = u32(o + 4) else { break }
                if nameRVA == 0 { break }
                // Old-style descriptors (attrs bit 0 clear) hold VAs, not RVAs; skip those.
                if attrs & 1 == 1, let name = cString(at: nameRVA) { imports.insert(name.lowercased()) }
                o += 32
            }
        }
        return Info(is64Bit: is64, imports: imports)
    }

    /// True if the file mentions `needle` as plain ASCII anywhere in its first 32 MB.
    /// Engines like Unreal load their renderer with LoadLibrary, so imports alone miss it.
    static func fileMentions(_ url: URL, anyOf needles: [String]) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 32 * 1024 * 1024) else { return [] }
        try? handle.close()
        var found = Set<String>()
        for needle in needles {
            for variant in [needle.lowercased(), needle.uppercased(), needle.capitalized] {
                if data.range(of: Data(variant.utf8)) != nil { found.insert(needle.lowercased()); break }
            }
        }
        return found
    }
}
