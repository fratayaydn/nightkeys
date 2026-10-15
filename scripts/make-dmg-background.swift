// Draws the background of the NightKeys disk image window: a soft light gradient with an arrow from the app
// icon to the Applications folder, the usual drag-to-install layout.
// Usage: swift scripts/make-dmg-background.swift <output-dir>
// Writes background.png (640x400) and background@2x.png (1280x800); make-dmg.sh combines them into one TIFF.
import AppKit

let width = 640.0, height = 400.0
let appX = 160.0, applicationsX = 480.0, iconY = 190.0   // icon centers, top-left origin (same as make-dmg.sh)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: Double, to path: String) {
    let w = Int(width * scale), h = Int(height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0xFAFBFE), color(0xE8EBF4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow between the two icons (128 pt wide), vertically centered on them.
    let y = height - iconY
    let startX = appX + 64 + 30, endX = applicationsX - 64 - 30
    ctx.setStrokeColor(color(0x8C94B0))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addLine(to: CGPoint(x: endX, y: y))
    ctx.move(to: CGPoint(x: endX - 16, y: y + 16))
    ctx.addLine(to: CGPoint(x: endX, y: y))
    ctx.addLine(to: CGPoint(x: endX - 16, y: y - 16))
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)   // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: "\(outDir)/background.png")
render(scale: 2, to: "\(outDir)/background@2x.png")
