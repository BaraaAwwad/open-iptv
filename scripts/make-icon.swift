// Renders the app icon: a glowing TV glyph on a black squircle. Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "OpenIPTV/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, centered, continuous corners.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    path.addClip()
    // Faint top sheen on the black.
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.0, alpha: 1)])!.draw(in: body, angle: -90)

    // Colored glow behind the glyph.
    let glow = NSGradient(colors: [NSColor(red: 0.30, green: 0.45, blue: 1.0, alpha: 0.55), NSColor(red: 0.6, green: 0.2, blue: 1, alpha: 0)])!
    glow.draw(fromCenter: CGPoint(x: s / 2, y: s * 0.47), radius: 0, toCenter: CGPoint(x: s / 2, y: s * 0.47), radius: s * 0.42, options: [])

    // The glyph, filled with a blue → violet gradient.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let size = symbol.size
    let rect = CGRect(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.01, width: size.width, height: size.height)
    let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    ctx.saveGState()
    ctx.clip(to: rect, mask: mask)
    NSGradient(colors: [NSColor(red: 0.45, green: 0.75, blue: 1, alpha: 1), NSColor(red: 0.55, green: 0.35, blue: 1, alpha: 1)])!
        .draw(in: rect, angle: -90)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(pt * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
