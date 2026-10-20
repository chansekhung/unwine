// Draws Unwine's app icon: a corkscrew coil that unwinds into a straight line and ends in a play
// button, on a deep blue tile. Run: swift scripts/make-icon.swift Resources/AppIcon.png [size]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "Resources/AppIcon.png"
let size: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 1024) : 1024
let s = size / 1024                                   // every number below is on a 1024 grid

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)                              // top-left origin, y down, like a design tool

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// MARK: Tile (macOS icon grid: 824 pt body inside the 1024 canvas)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()                                       // soft drop shadow under the tile
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000814, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x081A44)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// Deep blue body: bright cobalt at the top-left falling to midnight at the bottom-right.
ctx.drawLinearGradient(gradient([(0, rgb(0x2C66F5)), (0.5, rgb(0x113796)), (1, rgb(0x040C29))]),
                       start: CGPoint(x: 160, y: 110), end: CGPoint(x: 880, y: 930), options: [])
// A cool glow behind the coil, so the glyph sits in light.
ctx.drawRadialGradient(gradient([(0, rgb(0x5FD4FF, 0.42)), (1, rgb(0x5FD4FF, 0))]),
                       startCenter: CGPoint(x: 470, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 520), endRadius: 430, options: [])
// Glass sheen across the top third.
ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.22)), (1, rgb(0xFFFFFF, 0))]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// Hairline rim so the tile reads on dark and light docks.
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(3); ctx.strokePath()

// MARK: Coil -> line -> play

// The coil is a helix seen a little from the side, so each turn draws a loop. Its radius shrinks
// to zero as it moves right: the spring stretches out ("unwinds") into a straight line that runs
// into a play button. Back strands are drawn first and darker, front strands last and bright.
let x0: CGFloat = 214, x1: CGFloat = 604, midY: CGFloat = 532
let turns: CGFloat = 3.25
let steps = 1400
struct Sample { var p: CGPoint; var front: Bool }
var samples: [Sample] = []
for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps)
    // Even corkscrew loops for the first half, then a smooth taper to a straight line.
    let taper: CGFloat = t < 0.48 ? 1 : (t > 0.84 ? 0 : 0.5 * (1 + cos(.pi * (t - 0.48) / 0.36)))
    let amp = 142 * (1 - 0.22 * t) * taper
    let phase = 2 * .pi * turns * t - .pi / 2
    let lean = 0.5 * amp * cos(phase)                  // the side view: x swings back, drawing loops
    samples.append(Sample(p: CGPoint(x: x0 + (x1 - x0) * t + lean, y: midY + amp * sin(phase)),
                          front: cos(phase) >= 0 || amp < 1))
}

// Split into runs of front and back strand, each one continuous path.
func runs(front: Bool) -> CGPath {
    let path = CGMutablePath()
    var open = false
    for (i, s) in samples.enumerated() {
        if s.front == front {
            if !open { path.move(to: i > 0 ? samples[i - 1].p : s.p); open = true }
            path.addLine(to: s.p)
        } else if open {
            path.addLine(to: s.p); open = false
        }
    }
    return path
}

func strokeFilled(_ path: CGPath, width: CGFloat, _ fill: () -> Void) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    fill()
    ctx.restoreGState()
}

let back = runs(front: false), front = runs(front: true)

// Back strands: deep cobalt, in shadow behind the front ones.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: rgb(0x000A2E, 0.5))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
strokeFilled(back, width: 50) {
    ctx.drawLinearGradient(gradient([(0, rgb(0x2F5FD8)), (1, rgb(0x4C86F0))]),
                           start: CGPoint(x: x0, y: midY - 170), end: CGPoint(x: x1, y: midY + 170), options: [])
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// Front strands: ice cyan on the coil, warming to white along the straight line. One layer, one glow.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: rgb(0x7EDCFF, 0.75))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
strokeFilled(front, width: 58) {
    ctx.drawLinearGradient(gradient([(0, rgb(0x7CD9FF)), (0.55, rgb(0xC4EDFF)), (1, rgb(0xFFFFFF))]),
                           start: CGPoint(x: x0 - 60, y: midY), end: CGPoint(x: x1 + 40, y: midY), options: [])
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// A thin specular line along the top of the front strands, for a glassy finish.
ctx.saveGState()
ctx.translateBy(x: 0, y: -11)
strokeFilled(front, width: 12) {
    ctx.setFillColor(rgb(0xFFFFFF, 0.55)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
}
ctx.restoreGState()

// Play button where the line ends: a rounded triangle pointing right.
let tipX: CGFloat = 824
let h: CGFloat = 270, w: CGFloat = 236
let p1 = CGPoint(x: tipX - w, y: midY - h / 2), p2 = CGPoint(x: tipX - w, y: midY + h / 2), p3 = CGPoint(x: tipX, y: midY)
let tri = CGMutablePath()
tri.move(to: CGPoint(x: (p1.x + p3.x) / 2, y: (p1.y + p3.y) / 2))
tri.addArc(tangent1End: p3, tangent2End: p2, radius: 38)
tri.addArc(tangent1End: p2, tangent2End: p1, radius: 38)
tri.addArc(tangent1End: p1, tangent2End: p3, radius: 38)
tri.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 44, color: rgb(0x8FE4FF, 0.8))
ctx.addPath(tri); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tri); ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF)), (0.6, rgb(0xEAF6FF)), (1, rgb(0xB9E3FF))]),
                       start: CGPoint(x: p1.x, y: p1.y), end: CGPoint(x: p3.x, y: p2.y), options: [])
ctx.restoreGState()

// MARK: Write

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) at \(Int(size)) px")
