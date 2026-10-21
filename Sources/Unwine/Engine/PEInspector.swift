import Foundation

/// Reads Windows .exe/.dll headers to learn what a game needs:
/// its CPU width and which graphics APIs it links against.
///
/// Files are read with seeks and never loaded whole. A real game's .exe can be 200 MB, and the
/// compiler puts its import tables after the code, far from the start of the file.
enum PEInspector {
    struct Info {
        var is64Bit: Bool
        /// Lower-cased DLL names from the import and delay-import tables.
        var imports: Set<String>
    }

    static func inspect(_ url: URL) -> Info? {
        guard let file = RandomAccessFile(url), let image = Image(file) else { return nil }
        return Info(is64Bit: image.is64Bit, imports: image.imports(in: file))
    }

    /// What a program says about itself in its resources: its name and its icon.
    struct Resources {
        /// ProductName from each language of the version info, English first. Empty when it has none.
        var productNames: [String] = []
        /// FileDescription, in the language of the first product name.
        var fileDescription: String?
        /// Every picture of the program's own icon: the first icon group, the one Windows Explorer shows.
        var icons: [IconPicture] = []
    }

    /// One picture of an icon, as the file holds it: a PNG file, or a Windows bitmap (a DIB, with its
    /// transparency mask after the colours).
    struct IconPicture {
        let width: Int
        let height: Int
        let bitCount: Int
        let isPNG: Bool
        let data: [UInt8]
    }

    /// Reads the version info and, with `icons`, the program's own icon. Nil when the file is not a
    /// Windows program or holds no resources. Reads only the small blocks it needs, so a 200 MB .exe
    /// costs a few reads.
    static func resources(_ url: URL, icons wantIcons: Bool = true) -> Resources? {
        guard let file = RandomAccessFile(url), let image = Image(file), image.directories.count > 2 else { return nil }
        let entry = image.directories[2]
        guard entry.rva != 0, entry.size > 0, let base = image.fileOffset(ofRVA: entry.rva, fileSize: file.size) else { return nil }
        let tree = ResourceTree(file: file, image: image, base: base)
        let types = tree.entries(at: 0)
        func type(_ id: Int) -> ResourceTree.Entry? { types.first { $0.id == id && $0.isDirectory } }

        var result = Resources()
        if let version = type(16), let bytes = tree.firstData(under: version, limit: 256 * 1024) {
            (result.productNames, result.fileDescription) = VersionInfo.read(bytes)
        }
        // Explorer shows the first icon group, so that is the program's own icon.
        if wantIcons, let groups = type(14), let pictures = type(3),
           let group = tree.entries(at: groups.offset).first,
           let directory = tree.firstData(under: group, limit: 64 * 1024) {
            result.icons = iconPictures(directory, pictures: tree.entries(at: pictures.offset), tree: tree)
        }
        return result
    }

    /// The pictures an icon group lists. Each is an RT_ICON resource, found by its number.
    private static func iconPictures(_ group: [UInt8], pictures: [ResourceTree.Entry], tree: ResourceTree) -> [IconPicture] {
        guard le16(group, 0) == 0, le16(group, 2) == 1, let count = le16(group, 4) else { return [] }
        var result: [IconPicture] = []
        var budget = 16 * 1024 * 1024
        for index in 0..<min(count, 64) {
            let o = 6 + index * 14
            guard o + 14 <= group.count, let listedBits = le16(group, o + 6), let id = le16(group, o + 12) else { break }
            guard let entry = pictures.first(where: { $0.id == id }),
                  let data = tree.firstData(under: entry, limit: min(budget, 8 * 1024 * 1024)) else { continue }
            budget -= data.count
            // The group says 0 for 256 pixels; the picture itself knows its real size. A damaged
            // picture can claim any size, so sizes stop at 65536 and width times height cannot overflow.
            let listed = (w: group[o] == 0 ? 256 : Int(group[o]), h: group[o + 1] == 0 ? 256 : Int(group[o + 1]))
            let cap = 1 << 16
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                let w = be32(data, 16) ?? listed.w, h = be32(data, 20) ?? listed.h
                result.append(IconPicture(width: min(w, cap), height: min(h, cap), bitCount: 32, isPNG: true, data: data))
            } else if let w = le32(data, 4), let h2 = le32(data, 8), let bits = le16(data, 14) {
                // A DIB's height counts the colours and the mask, so it is twice the picture's height.
                let h = abs(Int(Int32(truncatingIfNeeded: h2))) / 2
                result.append(IconPicture(width: min(w, cap), height: min(h > 0 ? h : listed.h, cap),
                                          bitCount: bits > 0 ? bits : listedBits, isPNG: false, data: data))
            }
            if budget <= 0 { break }
        }
        return result
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }

    /// The resource directory: a tree of type, then name or number, then language, then the data.
    /// Every offset in it counts from the start of the tree.
    private struct ResourceTree {
        struct Entry {
            let id: Int?            // nil for an entry with a name instead of a number
            let offset: Int
            let isDirectory: Bool
        }

        let file: RandomAccessFile
        let image: Image
        let base: Int

        /// The entries of the directory at `offset`. Named entries come first, as in the file.
        func entries(at offset: Int) -> [Entry] {
            guard offset >= 0, let head = file.read(16, at: base + offset), head.count == 16,
                  let named = PEInspector.le16(head, 12), let numbered = PEInspector.le16(head, 14) else { return [] }
            let count = min(named + numbered, 2048)
            guard count > 0, let table = file.read(count * 8, at: base + offset + 16) else { return [] }
            var result: [Entry] = []
            for index in 0..<min(count, table.count / 8) {
                guard let name = PEInspector.le32(table, index * 8), let target = PEInspector.le32(table, index * 8 + 4) else { break }
                result.append(Entry(id: name & 0x8000_0000 != 0 ? nil : name & 0xFFFF,
                                    offset: target & 0x7FFF_FFFF, isDirectory: target & 0x8000_0000 != 0))
            }
            return result
        }

        /// The first piece of data under `entry`, down through the name and language levels. The
        /// depth limit keeps a damaged file that loops back on itself from looping here.
        func firstData(under entry: Entry, limit: Int, depth: Int = 0) -> [UInt8]? {
            guard entry.isDirectory else { return data(at: entry.offset, limit: limit) }
            guard depth < 3 else { return nil }
            for child in entries(at: entry.offset) {
                if let found = firstData(under: child, limit: limit, depth: depth + 1) { return found }
            }
            return nil
        }

        /// A data entry holds the RVA and the size of the bytes. Nil when they are larger than `limit`.
        private func data(at offset: Int, limit: Int) -> [UInt8]? {
            guard let entry = file.read(16, at: base + offset), let rva = PEInspector.le32(entry, 0),
                  let size = PEInspector.le32(entry, 4), size > 0, size <= limit,
                  let at = image.fileOffset(ofRVA: rva, fileSize: file.size),
                  let bytes = file.read(size, at: at), bytes.count == size else { return nil }
            return bytes
        }
    }

    /// VS_VERSION_INFO: blocks of (length, value length, type, UTF-16 key, value, child blocks), each
    /// part on a 4-byte boundary. Its StringFileInfo holds one table of names per language.
    private enum VersionInfo {
        struct Block {
            let start: Int
            let end: Int
            let key: String
            let valueStart: Int
            let childStart: Int
        }

        static func read(_ b: [UInt8]) -> (products: [String], description: String?) {
            guard let root = block(b, at: 0, end: b.count), root.key == "VS_VERSION_INFO" else { return ([], nil) }
            var tables: [(language: Int, strings: [String: String])] = []
            for info in children(b, of: root) where info.key == "StringFileInfo" {
                for table in children(b, of: info) {
                    var strings: [String: String] = [:]
                    for item in children(b, of: table) where item.key == "ProductName" || item.key == "FileDescription" {
                        if let text = text(b, item), !text.isEmpty { strings[item.key] = text }
                    }
                    tables.append((Int(table.key.prefix(4), radix: 16) ?? 0, strings))
                }
            }
            // US English first, then any English, then the order of the file.
            func rank(_ language: Int) -> Int { language == 0x0409 ? 0 : (language & 0x3FF == 0x09 ? 1 : 2) }
            let ordered = tables.enumerated().sorted { (rank($0.element.language), $0.offset) < (rank($1.element.language), $1.offset) }.map(\.element)
            var products: [String] = []
            for table in ordered { if let p = table.strings["ProductName"], !products.contains(p) { products.append(p) } }
            let description = ordered.first { $0.strings["ProductName"] != nil }?.strings["FileDescription"]
                ?? ordered.lazy.compactMap { $0.strings["FileDescription"] }.first
            return (products, description)
        }

        private static func align(_ o: Int) -> Int { (o + 3) & ~3 }

        static func block(_ b: [UInt8], at start: Int, end limit: Int) -> Block? {
            guard let length = PEInspector.le16(b, start), length >= 6, let valueLength = PEInspector.le16(b, start + 2),
                  let type = PEInspector.le16(b, start + 4) else { return nil }
            let end = min(start + length, limit)
            var o = start + 6
            var units: [UInt16] = []
            while o + 2 <= end, units.count < 64, let unit = PEInspector.le16(b, o) {
                o += 2
                if unit == 0 { break }
                units.append(UInt16(unit))
            }
            let valueStart = align(o)
            // Text values count UTF-16 units, binary ones bytes.
            let childStart = align(valueStart + (type == 1 ? valueLength * 2 : valueLength))
            return Block(start: start, end: end, key: String(decoding: units, as: UTF16.self), valueStart: valueStart, childStart: childStart)
        }

        static func children(_ b: [UInt8], of parent: Block) -> [Block] {
            var result: [Block] = []
            var o = parent.childStart
            while o + 6 <= parent.end, result.count < 256, let child = block(b, at: o, end: parent.end) {
                result.append(child)
                o = align(child.end)
            }
            return result
        }

        /// A string value: UTF-16 up to its NUL. Some tools count its length in bytes, others in
        /// units, so the NUL and the block's end decide.
        static func text(_ b: [UInt8], _ item: Block) -> String? {
            var units: [UInt16] = []
            var o = item.valueStart
            while o + 2 <= item.end, units.count < 512, let unit = PEInspector.le16(b, o), unit != 0 {
                units.append(UInt16(unit))
                o += 2
            }
            let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return text.isEmpty ? nil : text
        }
    }

    /// Which of `needles` the file mentions as plain ASCII text, in any letter case.
    /// Engines like Unreal load their renderer with LoadLibrary, so imports alone miss it.
    /// Reads in overlapping chunks, so a name that straddles two chunks is still found.
    static func fileMentions(_ url: URL, anyOf needles: [String]) -> Set<String> {
        guard let file = RandomAccessFile(url) else { return [] }
        var finder = NeedleFinder(needles)
        guard !finder.isEmpty else { return [] }
        for range in scanRanges(in: file) {
            var at = range.lowerBound
            while at < range.upperBound, !finder.foundAll {
                guard let chunk = file.read(min(chunkSize + finder.overlap, range.upperBound - at), at: at) else { break }
                finder.scan(chunk)
                at += chunkSize
            }
            if finder.foundAll { break }
        }
        return finder.found
    }

    // MARK: Text scan

    private static let chunkSize = 4 * 1024 * 1024
    /// The most bytes one file is scanned for text. It covers every real game executable (the biggest
    /// are about 250 MB) and keeps a strange file from tying up the analysis.
    private static let scanCap = 256 * 1024 * 1024

    /// The whole file when it fits under the cap. Otherwise the data sections come first, because
    /// that is where a program keeps the text it passes to LoadLibrary, then the start of the file.
    private static func scanRanges(in file: RandomAccessFile) -> [Range<Int>] {
        guard file.size > scanCap else { return file.size > 0 ? [0..<file.size] : [] }
        var budget = scanCap
        var ranges: [Range<Int>] = []
        if let image = Image(file) {
            for section in image.sections where !section.isCode && section.rawSize > 0 {
                let end = min(section.rawOffset + section.rawSize, file.size)
                guard section.rawOffset >= 0, section.rawOffset < end else { continue }
                let take = min(end - section.rawOffset, budget)
                ranges.append(section.rawOffset..<section.rawOffset + take)
                budget -= take
                if budget == 0 { break }
            }
        }
        if budget > 0 { ranges.append(0..<min(budget, file.size)) }
        return ranges
    }

    /// Finds several ASCII names at once, ignoring letter case, in one pass over each chunk.
    private struct NeedleFinder {
        private let names: [String]
        private let patterns: [[UInt8]]      // lower-case ASCII
        private let firstBytes: [Bool]       // 256 flags: the pattern's first letter, in either case
        private var seen: [Bool]
        let overlap: Int

        init(_ needles: [String]) {
            var names: [String] = []
            var patterns: [[UInt8]] = []
            for needle in needles {
                let lower = needle.lowercased()
                let bytes = Array(lower.utf8)
                // Plain ASCII only: that is what a DLL name is, and it keeps the byte compare exact.
                guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }), !names.contains(lower) else { continue }
                names.append(lower)
                patterns.append(bytes)
            }
            self.names = names
            self.patterns = patterns
            var first = [Bool](repeating: false, count: 256)
            for pattern in patterns {
                first[Int(pattern[0])] = true
                first[Int(Self.upper(pattern[0]))] = true
            }
            firstBytes = first
            seen = [Bool](repeating: false, count: names.count)
            overlap = max(0, (patterns.map(\.count).max() ?? 1) - 1)
        }

        var isEmpty: Bool { names.isEmpty }
        var foundAll: Bool { !seen.contains(false) }
        var found: Set<String> { Set(zip(names, seen).filter { $0.1 }.map { $0.0 }) }

        private static func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }
        private static func upper(_ b: UInt8) -> UInt8 { b >= 0x61 && b <= 0x7A ? b - 0x20 : b }

        mutating func scan(_ data: [UInt8]) {
            let patterns = self.patterns, firstBytes = self.firstBytes
            var seen = self.seen
            data.withUnsafeBufferPointer { bytes in
                let count = bytes.count
                var i = 0
                while i < count {
                    if firstBytes[Int(bytes[i])] {
                        for (index, pattern) in patterns.enumerated() where !seen[index] && i + pattern.count <= count {
                            var j = 0
                            while j < pattern.count, Self.lower(bytes[i + j]) == pattern[j] { j += 1 }
                            if j == pattern.count { seen[index] = true }
                        }
                    }
                    i += 1
                }
            }
            self.seen = seen
        }
    }

    // MARK: File access

    /// A file read at any offset. Every read is checked, so a damaged or half-written file gives
    /// nil, never a crash.
    private final class RandomAccessFile {
        let size: Int
        private let handle: FileHandle

        init?(_ url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
            self.handle = handle
            size = Int(clamping: end)
        }

        deinit { try? handle.close() }

        /// Up to `count` bytes at `offset`. Nil when nothing can be read there.
        func read(_ count: Int, at offset: Int) -> [UInt8]? {
            guard count > 0, offset >= 0, offset < size,
                  (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: min(count, size - offset)), !data.isEmpty else { return nil }
            return [UInt8](data)
        }
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    // MARK: Headers

    /// The parts of a PE header Unwine needs: CPU width, the section table and the data directories.
    private struct Image {
        struct Section {
            let virtualAddress: Int
            let virtualSize: Int
            let rawOffset: Int
            let rawSize: Int
            let flags: Int

            /// Holds code, or can be run. Strings for LoadLibrary live in the other sections.
            var isCode: Bool { flags & 0x2000_0020 != 0 }
        }

        let is64Bit: Bool
        let sections: [Section]
        let sizeOfHeaders: Int
        /// (RVA, size) per data directory the file declares, up to 16.
        let directories: [(rva: Int, size: Int)]

        init?(_ file: RandomAccessFile) {
            // "MZ", then the offset of "PE\0\0".
            guard let dos = file.read(0x40, at: 0), PEInspector.le16(dos, 0) == 0x5A4D,
                  let peOffset = PEInspector.le32(dos, 0x3C), peOffset > 0,
                  let head = file.read(24, at: peOffset), PEInspector.le32(head, 0) == 0x0000_4550,
                  let machine = PEInspector.le16(head, 4), let sectionCount = PEInspector.le16(head, 6),
                  let optionalSize = PEInspector.le16(head, 20) else { return nil }
            let tableCount = min(sectionCount, 96)
            guard let tail = file.read(optionalSize + tableCount * 40, at: peOffset + 24),
                  let magic = PEInspector.le16(tail, 0) else { return nil }
            let isPE32Plus = magic == 0x20B
            is64Bit = machine == 0x8664 || machine == 0xAA64 || isPE32Plus
            sizeOfHeaders = PEInspector.le32(tail, 60) ?? 0

            var directories: [(rva: Int, size: Int)] = []
            let directoryBase = isPE32Plus ? 112 : 96
            let declared = min(PEInspector.le32(tail, isPE32Plus ? 108 : 92) ?? 0, 16)
            for index in 0..<declared {
                let at = directoryBase + index * 8
                // The directories must sit inside the optional header, not run into the section table.
                guard at + 8 <= optionalSize, let rva = PEInspector.le32(tail, at), let size = PEInspector.le32(tail, at + 4) else { break }
                directories.append((rva, size))
            }
            self.directories = directories

            var sections: [Section] = []
            for index in 0..<tableCount {
                let o = optionalSize + index * 40
                guard let virtualSize = PEInspector.le32(tail, o + 8), let virtualAddress = PEInspector.le32(tail, o + 12),
                      let rawSize = PEInspector.le32(tail, o + 16), let rawOffset = PEInspector.le32(tail, o + 20),
                      let flags = PEInspector.le32(tail, o + 36) else { break }
                sections.append(Section(virtualAddress: virtualAddress, virtualSize: max(virtualSize, rawSize),
                                        rawOffset: rawOffset, rawSize: rawSize, flags: flags))
            }
            self.sections = sections
        }

        /// Where an address inside the loaded image sits in the file. Nil for memory that is only
        /// zero-filled when loaded, and for addresses the file does not cover.
        func fileOffset(ofRVA rva: Int, fileSize: Int) -> Int? {
            for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress + s.virtualSize {
                let into = rva - s.virtualAddress
                guard into < s.rawSize else { return nil }
                let offset = s.rawOffset + into
                return offset < fileSize ? offset : nil
            }
            // The headers are loaded as one block at the start of the image.
            return rva >= 0 && rva < sizeOfHeaders && rva < fileSize ? rva : nil
        }

        func imports(in file: RandomAccessFile) -> Set<String> {
            var names = Set<String>()
            let strings = StringReader(file)

            // Directory 1: import table (20-byte descriptors, name RVA at +12).
            if directories.count > 1, let table = descriptors(directory: 1, size: 20, in: file) {
                for index in 0..<min(512, table.count / 20) {
                    let o = index * 20
                    guard let nameRVA = PEInspector.le32(table, o + 12), let thunk = PEInspector.le32(table, o + 16) else { break }
                    if nameRVA == 0 && thunk == 0 { break }
                    if let name = string(atRVA: nameRVA, in: file, using: strings) { names.insert(name) }
                }
            }
            // Directory 13: delay-load imports (32-byte descriptors, name RVA at +4).
            if directories.count > 13, let table = descriptors(directory: 13, size: 32, in: file) {
                for index in 0..<min(512, table.count / 32) {
                    let o = index * 32
                    guard let attributes = PEInspector.le32(table, o), let nameRVA = PEInspector.le32(table, o + 4) else { break }
                    if nameRVA == 0 { break }
                    // Old-style descriptors (attributes bit 0 clear) hold VAs, not RVAs; skip those.
                    if attributes & 1 == 1, let name = string(atRVA: nameRVA, in: file, using: strings) { names.insert(name) }
                }
            }
            return names
        }

        /// The first 512 descriptors of a directory, read in one go.
        private func descriptors(directory index: Int, size: Int, in file: RandomAccessFile) -> [UInt8]? {
            let entry = directories[index]
            guard entry.rva != 0, let offset = fileOffset(ofRVA: entry.rva, fileSize: file.size) else { return nil }
            return file.read(512 * size, at: offset)
        }

        private func string(atRVA rva: Int, in file: RandomAccessFile, using strings: StringReader) -> String? {
            guard let offset = fileOffset(ofRVA: rva, fileSize: file.size), let text = strings.read(at: offset), !text.isEmpty else { return nil }
            return text.lowercased()
        }
    }

    /// Reads short NUL-ended names. The DLL names of an import table sit together, so one read
    /// of a few KB serves most of them.
    private final class StringReader {
        private let file: RandomAccessFile
        private var start = 0
        private var window: [UInt8] = []

        init(_ file: RandomAccessFile) { self.file = file }

        func read(at offset: Int) -> String? {
            let maxLength = 256
            let covered = offset >= start && offset + maxLength <= start + window.count
            if !covered, !(offset >= start && start + window.count >= file.size) {
                guard let fresh = file.read(4096, at: offset) else { return nil }
                start = offset
                window = fresh
            }
            let from = offset - start
            guard from >= 0, from < window.count else { return nil }
            var end = from
            while end < window.count, end - from < maxLength, window[end] != 0 { end += 1 }
            return String(bytes: window[from..<end], encoding: .ascii)
        }
    }
}
