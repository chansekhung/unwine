import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an added program says about itself.
struct ExeIdentity: Sendable {
    var productName: String?
    var steamAppID: Int?
    var hasIcon: Bool
}

/// The icon inside a Windows program, made into a PNG for the library and into an .icns for the
/// game's Game Mode app, so the Dock and Command-Tab show the game.
enum ExeIcon {
    /// Reads the program's ProductName, the steam_appid.txt next to it and its biggest icon picture.
    /// The icon goes to `iconFile` as a PNG; a program without one removes an older PNG there. Nil
    /// when the program file is gone.
    static func identity(of exe: URL, iconFile: URL) -> ExeIdentity? {
        guard FileManager.default.fileExists(atPath: exe.path) else { return nil }
        let resources = PEInspector.resources(exe)
        var found = ExeIdentity(productName: GameTitles.product(from: resources?.productNames ?? []),
                                steamAppID: LocalGames.steamAppID(nextTo: exe), hasIcon: false)
        if let png = png(from: resources?.icons ?? []) {
            _ = try? Paths.ensure(iconFile.deletingLastPathComponent())
            found.hasIcon = (try? png.write(to: iconFile, options: .atomic)) != nil
        } else {
            try? FileManager.default.removeItem(at: iconFile)
        }
        ArtCache.forget(iconFile)
        return found
    }

    /// The biggest picture as PNG data: the most pixels, then the most colours. A picture Unwine
    /// cannot read gives way to the next one.
    static func png(from pictures: [PEInspector.IconPicture]) -> Data? {
        let ordered = pictures.sorted {
            ($0.width * $0.height, $0.bitCount, $0.isPNG ? 1 : 0) > ($1.width * $1.height, $1.bitCount, $1.isPNG ? 1 : 0)
        }
        for picture in ordered {
            if picture.isPNG {
                let data = Data(picture.data)
                if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil {
                    return data
                }
            } else if let image = bitmap(picture.data), let data = pngData(image) {
                return data
            }
        }
        return nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Windows icon bitmaps

    /// Decodes an icon bitmap (a DIB): 32-bit colours with their own transparency, or 24-, 8-, 4- or
    /// 1-bit colours with the 1-bit mask after them that marks the see-through pixels. Rows are
    /// stored bottom first. Every read is checked, so a damaged picture gives nil.
    static func bitmap(_ b: [UInt8]) -> CGImage? {
        guard let headerSize = le32(b, 0), headerSize >= 40, headerSize <= 256, let width = le32(b, 4), let rawHeight = le32(b, 8),
              let bits = le16(b, 14), let compression = le32(b, 16) else { return nil }
        let signedHeight = Int(Int32(truncatingIfNeeded: rawHeight))
        let height = abs(signedHeight) / 2          // the height counts the colours and the mask
        let bottomUp = signedHeight > 0
        guard width > 0, width <= 1024, height > 0, height <= 1024, [1, 4, 8, 24, 32].contains(bits),
              compression == 0 || (compression == 3 && bits == 32) else { return nil }
        let used = le32(b, 32) ?? 0
        let colors = bits <= 8 ? (used > 0 && used <= 1 << bits ? used : 1 << bits) : 0
        // BI_BITFIELDS keeps three colour masks after a 40-byte header. Icons use the standard ones.
        let palette = headerSize + (compression == 3 && headerSize == 40 ? 12 : 0)
        let pixels = palette + colors * 4
        let rowBytes = (width * bits + 31) / 32 * 4
        let maskStride = (width + 31) / 32 * 4
        let mask = pixels + rowBytes * height
        guard mask <= b.count else { return nil }
        let hasMask = mask + maskStride * height <= b.count

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var anyAlpha = false
        for y in 0..<height {
            let row = pixels + (bottomUp ? height - 1 - y : y) * rowBytes
            for x in 0..<width {
                let o = (y * width + x) * 4
                switch bits {
                case 32:
                    let p = row + x * 4
                    rgba[o] = b[p + 2]; rgba[o + 1] = b[p + 1]; rgba[o + 2] = b[p]; rgba[o + 3] = b[p + 3]
                    if b[p + 3] != 0 { anyAlpha = true }
                case 24:
                    let p = row + x * 3
                    rgba[o] = b[p + 2]; rgba[o + 1] = b[p + 1]; rgba[o + 2] = b[p]; rgba[o + 3] = 255
                default:
                    let index: Int
                    switch bits {
                    case 8: index = Int(b[row + x])
                    case 4: index = Int(b[row + x / 2] >> (x % 2 == 0 ? 4 : 0)) & 0x0F
                    default: index = Int(b[row + x / 8] >> (7 - x % 8)) & 1
                    }
                    let p = palette + index * 4
                    guard index < colors, p + 2 < b.count else { continue }
                    rgba[o] = b[p + 2]; rgba[o + 1] = b[p + 1]; rgba[o + 2] = b[p]; rgba[o + 3] = 255
                }
            }
        }
        // The mask decides what is see-through, unless the colours carry their own transparency.
        if !(bits == 32 && anyAlpha) {
            if bits == 32 { for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 } }
            if hasMask {
                for y in 0..<height {
                    let row = mask + (bottomUp ? height - 1 - y : y) * maskStride
                    for x in 0..<width where b[row + x / 8] >> (7 - x % 8) & 1 == 1 {
                        rgba[(y * width + x) * 4 + 3] = 0
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    // MARK: Mac icon

    /// Makes an .icns from the PNG with iconutil, in every size macOS asks for. The picture sits a
    /// little inside its square, like a Mac app's icon, so the Dock does not show it larger than the
    /// others. A small picture is enlarged in whole pixels, so it stays sharp.
    static func writeICNS(from png: URL, to icns: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let fm = FileManager.default
        let set = icns.deletingLastPathComponent().appendingPathComponent(".icon-\(UUID().uuidString).iconset", isDirectory: true)
        defer { try? fm.removeItem(at: set) }
        do {
            try Paths.ensure(set)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    guard let data = square(image, side: points * scale).flatMap(pngData) else { return false }
                    try data.write(to: set.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
                }
            }
        } catch {
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", icns.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && fm.fileExists(atPath: icns.path)
    }

    private static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inner = Double(side) * 0.82
        let fit = min(inner / Double(image.width), inner / Double(image.height))
        // Whole pixels: each pixel of a small picture becomes a sharp square of equal size.
        let scale = fit >= 2 ? fit.rounded(.down) : fit
        context.interpolationQuality = fit >= 2 ? .none : .high
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.draw(image, in: CGRect(x: ((Double(side) - w) / 2).rounded(.down), y: ((Double(side) - h) / 2).rounded(.down),
                                       width: w, height: h))
        return context.makeImage()
    }
}
