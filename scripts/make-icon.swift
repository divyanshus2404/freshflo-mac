// Renders the Freshflo app icon into an .iconset folder. Same mark as the website:
// a deep spruce rounded square with four spearmint voice bars.
// Usage: swift scripts/make-icon.swift <output.iconset>   or   swift scripts/make-icon.swift <file.png> <size>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: ~10% inset, rounded square.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Soft drop shadow like system icons.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.05, green: 0.14, blue: 0.13, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.09, green: 0.23, blue: 0.21, alpha: 1),
        NSColor(red: 0.03, green: 0.10, blue: 0.09, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Thin top highlight for a glassy edge.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Four voice bars, same proportions as the site logo (32-unit grid: x 9/14/19/24, heights 6/14/8/3).
    let unit = rect.width / 32
    let bars: [(x: CGFloat, h: CGFloat)] = [(9, 6), (14, 14), (19, 8), (24, 3)]
    let barW = unit * 3.2
    let mint = NSColor(red: 0.21, green: 0.84, blue: 0.65, alpha: 1)
    let glow = NSShadow()
    glow.shadowColor = mint.withAlphaComponent(0.55)
    glow.shadowBlurRadius = s * 0.035
    glow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    for bar in bars {
        let h = bar.h * unit + barW
        let r = NSRect(x: rect.minX + bar.x * unit - barW / 2, y: rect.midY - h / 2, width: barW, height: h)
        NSGradient(colors: [mint, NSColor(red: 0.47, green: 0.93, blue: 0.78, alpha: 1)])!
            .draw(in: NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2), angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 2, let size = Int(CommandLine.arguments[2]) {
    try render(size).write(to: out)
} else {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
