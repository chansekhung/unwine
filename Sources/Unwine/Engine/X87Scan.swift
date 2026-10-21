import Foundation

/// How a 32-bit game does its decimal-number math, read from its own code: with the old x87 unit,
/// or with SSE. Faster x87 math (x87sidecar) speeds up only the x87 part, and while it runs Rosetta's
/// ahead-of-time cache is off, so the whole game is translated on the fly. A game that does most of
/// its math with SSE gets slower: on 21 Oct 2026 Left 4 Dead 2 (2.5% x87, 5.1% SSE) ran 65-80 fps
/// with it and 70-90 fps without. Age of Mythology has almost no x87 (0.6%).
struct MathMix: Codable, Equatable, Sendable {
    var instructions = 0        // instructions read in the game's code
    var x87 = 0                 // x87 instructions (opcodes D8-DF)
    var sse = 0                 // SSE decimal-number instructions (0F 10-17, 28-2F, 50-5F, C2, C6)
    var files = 0               // program files read
    var skipped = 0             // program files that were not readable code (encrypted or packed)
    var dotNet = false          // the game's program is .NET: no file holds the code that runs

    var x87Percent: Double { instructions > 0 ? 100 * Double(x87) / Double(instructions) : 0 }
    var ssePercent: Double { instructions > 0 ? 100 * Double(sse) / Double(instructions) : 0 }

    enum Verdict: Equatable { case helps, little, none, unknown }

    /// `helps`: x87 is the game's main decimal math (at least twice its SSE, and at least 1.5% of all
    /// instructions). `little`: it has some x87, but under 1.5% of its instructions or less than twice
    /// its SSE. `none`: almost no x87.
    var verdict: Verdict {
        guard instructions >= 10_000 else { return .unknown }
        if x87Percent < 1 { return .none }
        return x87 >= 2 * sse && x87Percent >= 1.5 ? .helps : .little
    }

    /// One sentence for the game page: the numbers, then what they mean for Faster x87 math.
    var advice: String {
        let read = skipped == 0 ? "Unwine read this game's code"
            : "Unwine read this game's code, except \(skipped == 1 ? "1 encrypted file" : "\(skipped) encrypted files")"
        let numbers = read + ": \(Self.percent(x87Percent)) of it is x87 math and \(Self.percent(ssePercent)) is SSE math."
        switch verdict {
        case .helps:
            return numbers + " x87 is its main math, so Faster x87 math can make it much faster."
        case .little:
            let why = sse > x87 ? "SSE does most of its math"
                : x87Percent < 1.5 ? "x87 is only a small part of its code"
                : "x87 is not clearly its main math"
            return numbers + " \(why), so Faster x87 math does not help much. Rosetta's fast cache is off while it runs, so the game can get slower."
        case .none:
            return numbers + " It has almost no x87 math, so Faster x87 math only costs speed: Rosetta's fast cache is off while it runs."
        case .unknown:
            if dotNet {
                return "This game is .NET code. The game compiles it while it runs, so Unwine cannot read its math first. Unwine cannot say if Faster x87 math helps."
            }
            return skipped > 0 && files == 0
                ? "Unwine could not read this game's program (it is encrypted), so it cannot say if Faster x87 math helps."
                : "Unwine found too little of this game's code to say if Faster x87 math helps."
        }
    }

    private static func percent(_ v: Double) -> String { String(format: v < 10 ? "%.1f%%" : "%.0f%%", v) }
}

enum X87Scan {
    /// Reads the code of these 32-bit program files, in order, until `limit` bytes. 64-bit files and
    /// files that are not Windows programs count as nothing.
    static func scan(_ files: [URL], limit: Int = 48 << 20) -> MathMix {
        // .NET code is IL, which the runtime compiles while the game runs: no file holds its x86 math.
        if let program = files.first, PEInspector.isDotNet(program) { return MathMix(dotNet: true) }
        var mix = MathMix()
        var left = limit
        var readBytes = 0, programSkippedBytes = 0
        for (index, url) in files.enumerated() where left > 0 {
            guard let blocks = PEInspector.code32(url, limit: left), !blocks.isEmpty else { continue }
            var file = Count()
            var bytes = 0
            for block in blocks { count(block, into: &file); left -= block.count; bytes += block.count }
            // Encrypted or packed code (Steam's DRM wrapper, for one) reads as random instructions,
            // and random bytes look like about 3% x87. Real game code almost never uses port I/O or hlt.
            guard file.instructions > 0, Double(file.odd) / Double(file.instructions) < 0.01 else {
                mix.skipped += 1
                if index == 0 { programSkippedBytes = bytes }
                continue
            }
            readBytes += bytes
            mix.instructions += file.instructions
            mix.x87 += file.x87
            mix.sse += file.sse
            mix.files += 1
        }
        // An encrypted program with more code than the DLLs that were read: those DLLs are bought-in
        // libraries (sound, animation), not the game, so they do not speak for it. Left 4 Dead 2's
        // program is a small launcher and its game code is in DLLs, so it keeps its result.
        if programSkippedBytes > readBytes { return MathMix(skipped: mix.skipped) }
        return mix
    }

    struct Count {
        var instructions = 0, x87 = 0, sse = 0
        var odd = 0                 // in/out, ins/outs, hlt, into, int1, salc: signs of data, not code
    }

    /// Walks one block of 32-bit x86 code from its start, one instruction at a time, the way a
    /// disassembler does (a linear sweep). Bytes between functions can put a few instructions out of
    /// step; the sweep falls back into step within a few bytes, so the shares stay right.
    static func count(_ code: [UInt8], into c: inout Count) {
        code.withUnsafeBufferPointer { p in
            let n = p.count
            var i = 0
            while i < n {
                var opsize16 = false, addr16 = false
                var prefixes = 0
                prefix: while i < n && prefixes < 14 {
                    switch p[i] {
                    case 0x66: opsize16 = true
                    case 0x67: addr16 = true
                    case 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65: break
                    default: break prefix
                    }
                    i += 1; prefixes += 1
                }
                guard i < n else { break }
                let op = p[i]; i += 1
                let iz = opsize16 ? 2 : 4
                var modrm = false, imm = 0
                var isX87 = false, isSSE = false, isOdd = false
                if op == 0x0F {
                    guard i < n else { break }
                    let op2 = p[i]; i += 1
                    if op2 == 0x38 { i += 1; modrm = true }
                    else if op2 == 0x3A { i += 1; modrm = true; imm = 1 }
                    else { (modrm, imm) = twoByte(op2, iz: iz); isSSE = sseFloat(op2) }
                } else if (op == 0xC4 || op == 0xC5 || op == 0x62), i < n, p[i] & 0xC0 == 0xC0 {
                    // VEX (AVX) and EVEX (AVX-512): in 32-bit code these bytes mean LES, LDS and BOUND
                    // unless the next byte looks like a register-only ModRM.
                    var map = 1
                    if op == 0xC5 { i += 1 }
                    else if op == 0xC4 { guard i + 1 < n else { break }; map = Int(p[i] & 0x1F); i += 2 }
                    else { guard i + 2 < n else { break }; map = Int(p[i] & 0x03); i += 3 }
                    guard i < n else { break }
                    let op2 = p[i]; i += 1
                    modrm = !(map == 1 && op2 == 0x77)          // VZEROUPPER and VZEROALL have none
                    if map == 3 { imm = 1 } else if map == 1 { imm = twoByte(op2, iz: iz).imm; isSSE = sseFloat(op2) }
                } else {
                    (modrm, imm) = oneByte(op, iz: iz, address: addr16 ? 2 : 4)
                    isX87 = op >= 0xD8 && op <= 0xDF
                    switch op {
                    case 0x6C...0x6F, 0xCE, 0xD6, 0xE4...0xE7, 0xEC...0xEF, 0xF1, 0xF4: isOdd = true
                    default: break
                    }
                }
                if modrm {
                    guard i < n else { break }
                    let m = p[i]; i += 1
                    let mod = m >> 6, rm = m & 7
                    if (op == 0xF6 || op == 0xF7) && (m >> 3) & 7 <= 1 { imm = op == 0xF6 ? 1 : iz }   // TEST r/m, imm
                    if mod != 3 {
                        if addr16 {
                            if mod == 1 { i += 1 } else if mod == 2 || (mod == 0 && rm == 6) { i += 2 }
                        } else {
                            if rm == 4 {
                                guard i < n else { break }
                                let base = p[i] & 7; i += 1
                                if mod == 0 && base == 5 { i += 4 }
                            }
                            if mod == 1 { i += 1 } else if mod == 2 || (mod == 0 && rm == 5) { i += 4 }
                        }
                    }
                }
                i += imm
                guard i <= n else { break }
                c.instructions += 1
                if isX87 { c.x87 += 1 } else if isSSE { c.sse += 1 } else if isOdd { c.odd += 1 }
            }
        }
    }

    /// One-byte opcodes: whether a ModRM byte follows, and how many immediate bytes.
    private static func oneByte(_ op: UInt8, iz: Int, address: Int) -> (modrm: Bool, imm: Int) {
        switch op {
        case 0x00...0x03, 0x08...0x0B, 0x10...0x13, 0x18...0x1B, 0x20...0x23, 0x28...0x2B, 0x30...0x33, 0x38...0x3B: return (true, 0)
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C: return (false, 1)
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D: return (false, iz)
        case 0x62, 0x63: return (true, 0)
        case 0x68: return (false, iz)
        case 0x69: return (true, iz)
        case 0x6A: return (false, 1)
        case 0x6B: return (true, 1)
        case 0x70...0x7F: return (false, 1)
        case 0x80, 0x82, 0x83: return (true, 1)
        case 0x81: return (true, iz)
        case 0x84...0x8F: return (true, 0)
        case 0x9A: return (false, iz + 2)
        case 0xA0...0xA3: return (false, address)
        case 0xA8: return (false, 1)
        case 0xA9: return (false, iz)
        case 0xB0...0xB7: return (false, 1)
        case 0xB8...0xBF: return (false, iz)
        case 0xC0, 0xC1: return (true, 1)
        case 0xC2, 0xCA: return (false, 2)
        case 0xC4, 0xC5: return (true, 0)
        case 0xC6: return (true, 1)
        case 0xC7: return (true, iz)
        case 0xC8: return (false, 3)
        case 0xCD: return (false, 1)
        case 0xD0...0xD3: return (true, 0)
        case 0xD4, 0xD5: return (false, 1)
        case 0xD8...0xDF: return (true, 0)
        case 0xE0...0xE7: return (false, 1)
        case 0xE8, 0xE9: return (false, iz)
        case 0xEA: return (false, iz + 2)
        case 0xEB: return (false, 1)
        case 0xF6, 0xF7, 0xFE, 0xFF: return (true, 0)
        default: return (false, 0)
        }
    }

    /// Two-byte opcodes (after 0F): whether a ModRM byte follows, and how many immediate bytes.
    private static func twoByte(_ op: UInt8, iz: Int) -> (modrm: Bool, imm: Int) {
        switch op {
        case 0x05...0x09, 0x0B, 0x0E, 0x30...0x37, 0x77, 0xA0...0xA2, 0xA8...0xAA, 0xC8...0xCF: return (false, 0)
        case 0x0F: return (true, 1)                                     // 3DNow!: its opcode comes last
        case 0x70...0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4...0xC6: return (true, 1)
        case 0x80...0x8F: return (false, iz)                            // Jcc rel32
        default: return (true, 0)
        }
    }

    /// SSE decimal-number instructions: moves, math, compares and conversions of floats and doubles.
    private static func sseFloat(_ op: UInt8) -> Bool {
        switch op {
        case 0x10...0x17, 0x28...0x2F, 0x50...0x5F, 0xC2, 0xC6: return true
        default: return false
        }
    }
}
