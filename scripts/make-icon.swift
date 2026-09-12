// Renders the BatSign app icon (1024×1024): App Store-grade minimalism —
// deep space background, one precisely lit bat mark, no clutter.
// Runs on macOS CI via `swift scripts/make-icon.swift`.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let scale: CGFloat = 2 // supersample for smooth edges
let w = CGFloat(size) * scale

guard let ctx = CGContext(data: nil, width: Int(w), height: Int(w), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("icon: cannot create context")
}
ctx.scaleBy(x: scale, y: scale)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// Background: quiet vertical wash, near-black to graphite.
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [CGColor(red: 0.055, green: 0.063, blue: 0.094, alpha: 1),
                             CGColor(red: 0.031, green: 0.035, blue: 0.055, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

// Focused light behind the mark: small, controlled, premium.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [CGColor(red: 1.0, green: 0.74, blue: 0.16, alpha: 0.42),
                               CGColor(red: 1.0, green: 0.74, blue: 0.16, alpha: 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 340, options: [])

// Bat mark: left wing authored, right wing mirrored exactly.
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 1024 - y) }

func batPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: pt(449, 318))              // left ear tip
    p.addLine(to: pt(512, 356))           // head notch
    p.addLine(to: pt(575, 318))           // right ear tip
    p.addCurve(to: pt(598, 402), control1: pt(590, 344), control2: pt(598, 372))
    p.addCurve(to: pt(912, 350), control1: pt(700, 336), control2: pt(816, 312))
    p.addCurve(to: pt(788, 570), control1: pt(836, 448), control2: pt(826, 516))
    p.addCurve(to: pt(624, 530), control1: pt(726, 522), control2: pt(676, 480))
    p.addCurve(to: pt(556, 470), control1: pt(576, 566), control2: pt(564, 516))
    p.addCurve(to: pt(468, 470), control1: pt(532, 500), control2: pt(492, 500))
    p.addCurve(to: pt(400, 530), control1: pt(460, 516), control2: pt(448, 566))
    p.addCurve(to: pt(236, 570), control1: pt(348, 480), control2: pt(298, 522))
    p.addCurve(to: pt(112, 350), control1: pt(198, 516), control2: pt(188, 448))
    p.addCurve(to: pt(426, 402), control1: pt(208, 312), control2: pt(324, 336))
    p.addCurve(to: pt(449, 318), control1: pt(426, 372), control2: pt(434, 344))
    p.closeSubpath()
    return p
}

// Warm shadow lifts the mark off the glass.
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

let glyph = batPath()
ctx.addPath(glyph)
ctx.clip()
let glyphGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(red: 1.0, green: 0.83, blue: 0.35, alpha: 1),   // top light
                                    CGColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 1)] as CFArray,
                           locations: [0, 1])!
ctx.drawLinearGradient(glyphGrad, start: pt(0, 560), end: pt(0, 300), options: [])
ctx.restoreGState()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Hairline top light on the mark for a machined edge.
ctx.saveGState()
ctx.addPath(glyph)
ctx.clip()
ctx.setStrokeColor(CGColor(red: 1, green: 0.92, blue: 0.7, alpha: 0.35))
ctx.setLineWidth(2.5)
ctx.strokePath()
ctx.restoreGState()

let rendered = ctx.makeImage()!

// Downscale the 2× supersample to exactly 1024×1024.
guard let finalCtx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("icon: cannot create final context")
}
finalCtx.interpolationQuality = .high
finalCtx.draw(rendered, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let finalImage = finalCtx.makeImage()!

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("BatSign/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let dest = iconset.appendingPathComponent("icon_1024.png")
let imageDest = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(imageDest, finalImage, nil)
guard CGImageDestinationFinalize(imageDest) else { fatalError("icon: failed to write PNG") }

let contents = """
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("icon: wrote \(dest.path)")
