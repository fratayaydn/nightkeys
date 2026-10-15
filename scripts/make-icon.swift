// Draws the NightKeys app icon with Core Graphics and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
// A night-blue squircle with one large square keycap in the middle, backlit, with a crow as its key legend.
import AppKit

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)  // macOS icon grid: 824 pt body on a 1024 canvas
let radius: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Fills a crescent shaped as one path: the disc `disc` minus the same disc moved by `offset`, so the glow
/// follows the crescent's outline instead of being cut off at the bite.
func fillCrescent(_ ctx: CGContext, disc: CGRect, offset: CGSize, fill: CGColor, glow: CGColor, blur: CGFloat) {
    let r = disc.width / 2
    let c1 = CGPoint(x: disc.midX, y: disc.midY)
    let c2 = CGPoint(x: c1.x + offset.width, y: c1.y + offset.height)
    let d = hypot(offset.width, offset.height)
    let toBite = atan2(offset.height, offset.width)
    let half = acos(d / (2 * r))  // half-angle at each center between the line of centers and an intersection
    let path = CGMutablePath()
    // Outer edge: the far side of the main disc, from one intersection to the other.
    path.addArc(center: c1, radius: r, startAngle: toBite + half, endAngle: toBite - half + 2 * .pi, clockwise: false)
    // Inner edge: back along the bite circle, through the side facing the main disc.
    path.addArc(center: c2, radius: r, startAngle: toBite + .pi + half, endAngle: toBite + .pi - half, clockwise: true)
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: glow)
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

/// The crow is Font Awesome's "crow" icon (CC BY 4.0), see Resources/ThirdParty/README.md.
let crowSVG = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
                         .appendingPathComponent("Resources/ThirdParty/fontawesome-crow.svg"))!

func drawIcon(in ctx: CGContext) {
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the body, like system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x10132A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Night sky gradient.
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [color(0x2A2F6B), color(0x14173A), color(0x090B1C)] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // Backlight glow under the keycap.
    let keycap = CGRect(x: 232, y: 232, width: 560, height: 560)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xBFE3FF, 0.85), color(0x7FB8FF, 0.35), color(0x7FB8FF, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 470, options: [])

    // Keycap: dark body, lighter top face, glowing edge.
    let capPath = CGPath(roundedRect: keycap, cornerWidth: 96, cornerHeight: 96, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 44, color: color(0xA8D6FF, 1))
    ctx.addPath(capPath)
    ctx.setFillColor(color(0x232956))
    ctx.fillPath()
    ctx.restoreGState()
    let top = keycap.insetBy(dx: 46, dy: 46).offsetBy(dx: 0, dy: 16)
    let topPath = CGPath(roundedRect: top, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.addPath(topPath)
    ctx.clip()
    let face = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x4A52A0), color(0x323979)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(face, start: CGPoint(x: 512, y: top.maxY), end: CGPoint(x: 512, y: top.minY), options: [])
    ctx.restoreGState()

    // Key legend: a glowing crow, centered on the key's top face.
    let legendWidth: CGFloat = 385
    let legendHeight = legendWidth * crowSVG.size.height / crowSVG.size.width
    let legendRect = CGRect(x: top.midX - legendWidth / 2, y: top.midY - legendHeight / 2, width: legendWidth, height: legendHeight)
    let pixelScale = ctx.ctm.a  // render the vector shape at the output resolution
    var proposed = CGRect(origin: .zero, size: CGSize(width: legendWidth * pixelScale, height: legendHeight * pixelScale))
    let mask = crowSVG.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
    // A black silhouette with the backlight spreading out from its edges: a wide soft glow, then a tight bright rim.
    for (blur, glow) in [(CGFloat(70), color(0xA8D6FF, 1)), (CGFloat(34), color(0xBFE3FF, 1)), (CGFloat(14), color(0xF2F9FF, 1))] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: glow)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: legendRect, mask: mask)
        ctx.setFillColor(color(0x05060E))
        ctx.fill(legendRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: root.appendingPathComponent(".build/AppIcon-preview.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
