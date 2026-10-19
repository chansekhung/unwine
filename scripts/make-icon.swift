// Draws the Decant app icon (a glass decanter with a play mark) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Work in a top-left coordinate space.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                          CGFloat(hex & 0xff) / 255, a])!
}

// Squircle tile on Apple's 824pt grid (100pt margin).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1A0710)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x5A1430), rgb(0x2A0818), rgb(0x12040B)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft top glow.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFD9A8, 0.22), rgb(0xFFD9A8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 230), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 230), endRadius: 520, options: [])
ctx.restoreGState()

// Decanter silhouette: lip, neck, round bulb.
let glass = CGMutablePath()
glass.move(to: CGPoint(x: 452, y: 236))            // lip left
glass.addLine(to: CGPoint(x: 572, y: 236))         // lip right
glass.addQuadCurve(to: CGPoint(x: 552, y: 270), control: CGPoint(x: 576, y: 262))
glass.addLine(to: CGPoint(x: 552, y: 420))         // neck right
glass.addCurve(to: CGPoint(x: 742, y: 640), control1: CGPoint(x: 552, y: 470), control2: CGPoint(x: 742, y: 500))
glass.addCurve(to: CGPoint(x: 512, y: 812), control1: CGPoint(x: 742, y: 760), control2: CGPoint(x: 640, y: 812))
glass.addCurve(to: CGPoint(x: 282, y: 640), control1: CGPoint(x: 384, y: 812), control2: CGPoint(x: 282, y: 760))
glass.addCurve(to: CGPoint(x: 472, y: 420), control1: CGPoint(x: 282, y: 500), control2: CGPoint(x: 472, y: 470))
glass.addLine(to: CGPoint(x: 472, y: 270))         // neck left
glass.addQuadCurve(to: CGPoint(x: 452, y: 236), control: CGPoint(x: 448, y: 262))
glass.closeSubpath()

// Glass body.
ctx.saveGState()
ctx.addPath(glass); ctx.clip()
let glassFill = CGGradient(colorsSpace: cs, colors: [rgb(0xFFF4E6, 0.30), rgb(0xFFF4E6, 0.10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glassFill, start: CGPoint(x: 282, y: 236), end: CGPoint(x: 742, y: 812), options: [])
// Wine, with a gentle wave on top.
let wine = CGMutablePath()
wine.move(to: CGPoint(x: 240, y: 600))
wine.addCurve(to: CGPoint(x: 512, y: 596), control1: CGPoint(x: 330, y: 572), control2: CGPoint(x: 420, y: 622))
wine.addCurve(to: CGPoint(x: 790, y: 590), control1: CGPoint(x: 604, y: 570), control2: CGPoint(x: 700, y: 616))
wine.addLine(to: CGPoint(x: 790, y: 860)); wine.addLine(to: CGPoint(x: 240, y: 860)); wine.closeSubpath()
ctx.addPath(wine); ctx.clip()
let wineFill = CGGradient(colorsSpace: cs, colors: [rgb(0xE0355F), rgb(0x8E0F33)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wineFill, start: CGPoint(x: 512, y: 590), end: CGPoint(x: 512, y: 812), options: [])
ctx.restoreGState()

// Glass outline.
ctx.addPath(glass)
ctx.setStrokeColor(rgb(0xFFE7C7, 0.92)); ctx.setLineWidth(16); ctx.setLineJoin(.round)
ctx.strokePath()

// Play mark floating in the wine.
let play = CGMutablePath()
play.move(to: CGPoint(x: 482, y: 648))
play.addLine(to: CGPoint(x: 566, y: 700))
play.addLine(to: CGPoint(x: 482, y: 752))
play.closeSubpath()
ctx.addPath(play); ctx.setFillColor(rgb(0xFFF4E6)); ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(0xFFF4E6)); ctx.setLineWidth(18)
ctx.drawPath(using: .fillStroke)

// Highlight sweep on the bulb.
let shine = CGMutablePath()
shine.addArc(center: CGPoint(x: 512, y: 640), radius: 190, startAngle: .pi * 1.08, endAngle: .pi * 1.32, clockwise: false)
ctx.addPath(shine); ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(14); ctx.setLineCap(.round)
ctx.strokePath()

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
