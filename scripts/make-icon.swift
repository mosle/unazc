// Draws the app icon (a waveform that ends in a text caret) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
    ctx.restoreGState()
}

func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Draws on a 1024-unit canvas with y pointing down.
/// `scale` is pixels per unit; shadows ignore the CTM, so they need it explicitly.
func draw(_ ctx: CGContext, scale: CGFloat) {
    // Body with the macOS-style drop shadow.
    let body = roundRect(100, 100, 824, 824, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x0e1014))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, body, [rgb(0x23272f), rgb(0x0e1014)], from: CGPoint(x: 100, y: 100), to: CGPoint(x: 924, y: 924))

    // Waveform bars, centered on y = 512.
    let bars: [(x: CGFloat, h: CGFloat)] = [(236, 120), (336, 320), (436, 200), (536, 420)]
    let barPath = CGMutablePath()
    for bar in bars { barPath.addPath(roundRect(bar.x, 512 - bar.h / 2, 60, bar.h, 30)) }
    linear(ctx, barPath, [rgb(0x7fe0c4), rgb(0x3fb6d9)], from: CGPoint(x: 0, y: 302), to: CGPoint(x: 0, y: 722))

    // Text caret (I-beam).
    ctx.setFillColor(rgb(0xffffff))
    for rect in [roundRect(686, 262, 44, 500, 10), roundRect(650, 262, 116, 36, 10), roundRect(650, 726, 116, 36, 10)] {
        ctx.addPath(rect)
    }
    ctx.fillPath()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx, scale: scale)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
