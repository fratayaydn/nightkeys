// Draws the icon of the mounted NightKeys disk image: a white external drive with the app icon on its top face.
// Usage: swift scripts/make-volume-icon.swift <output-dir>
// Writes VolumeIcon.icns and VolumeIcon-preview.png. Reads Resources/AppIcon.icns.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns")!
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

// A closed polygon whose corners are rounded with the matching radius.
func roundedPolygon(_ points: [CGPoint], _ radii: [CGFloat]) -> CGPath {
    let p = CGMutablePath()
    let n = points.count
    p.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
    for i in 0..<n {
        p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radii[i])
    }
    p.closeSubpath()
    return p
}

// Drawn on a 1024 canvas, origin bottom-left. The drive is one solid body seen slightly from above: the top face
// narrows toward the back, the sides drop straight down along the front face.
let edgeY: CGFloat = 360   // where the top face meets the front face

func drawDrive(_ ctx: CGContext) {
    let body = roundedPolygon([CGPoint(x: 140, y: 930), CGPoint(x: 884, y: 930), CGPoint(x: 936, y: edgeY),
                               CGPoint(x: 936, y: 110), CGPoint(x: 88, y: 110), CGPoint(x: 88, y: edgeY)],
                              [64, 64, 40, 64, 64, 40])

    // Soft shadow under the drive.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0xD9DCE2))
    ctx.fillPath()
    ctx.restoreGState()

    // Top face: white, lit from above.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.clip(to: CGRect(x: 0, y: edgeY, width: 1024, height: 1024))
    ctx.drawLinearGradient(gradient(0xFFFFFF, 0xE9EBF0), start: CGPoint(x: 0, y: 930), end: CGPoint(x: 0, y: edgeY),
                           options: [])
    ctx.restoreGState()

    // Front face: darker silver, in shade.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: edgeY))
    ctx.drawLinearGradient(gradient(0xC3C8D1, 0x989EAA), start: CGPoint(x: 0, y: edgeY), end: CGPoint(x: 0, y: 110),
                           options: [])
    // Edge between the faces: a bright highlight on the front's top, a thin shade under it.
    ctx.setFillColor(color(0xFFFFFF, 0.85))
    ctx.fill(CGRect(x: 0, y: edgeY - 5, width: 1024, height: 5))
    ctx.setFillColor(color(0x7E8592, 0.35))
    ctx.fill(CGRect(x: 0, y: edgeY - 8, width: 1024, height: 3))
    ctx.restoreGState()

    // Slot on the front.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 230, y: 200, width: 564, height: 22), cornerWidth: 11,
                       cornerHeight: 11, transform: nil))
    ctx.setFillColor(color(0x3A3F48))
    ctx.fillPath()
    ctx.setFillColor(color(0xFFFFFF, 0.45))
    ctx.fill(CGRect(x: 240, y: 194, width: 544, height: 4))

    // Inset label panel, parallel to the top face's edges.
    let panel = roundedPolygon([CGPoint(x: 190, y: 885), CGPoint(x: 834, y: 885), CGPoint(x: 870, y: 410),
                                CGPoint(x: 154, y: 410)], [40, 40, 40, 40])
    ctx.addPath(panel)
    ctx.setFillColor(color(0xF5F6F8))
    ctx.fillPath()
    ctx.addPath(panel)
    ctx.setStrokeColor(color(0xC8CCD4))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // App icon on the panel.
    let iconRect = CGRect(x: 512 - 220, y: 648 - 220, width: 440, height: 440)
    var proposed = iconRect
    if let cg = appIcon.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        ctx.draw(cg, in: iconRect)
    }
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawDrive(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let iconset = "\(outDir)/VolumeIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), "\(iconset)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
writePNG(render(1024), "\(outDir)/VolumeIcon-preview.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/VolumeIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
