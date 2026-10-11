// Renders the ExcuseMe app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: ~10% inset, continuous-ish rounded square.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(red: 1.00, green: 0.44, blue: 0.33, alpha: 1),
        NSColor(red: 0.85, green: 0.20, blue: 0.47, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Speech bubble.
    let bw = rect.width * 0.58, bh = rect.height * 0.42
    let bubble = NSRect(x: rect.midX - bw / 2, y: rect.midY - bh / 2 + rect.height * 0.04, width: bw, height: bh)
    let path = NSBezierPath(roundedRect: bubble, xRadius: bh * 0.42, yRadius: bh * 0.42)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubble.minX + bw * 0.22, y: bubble.minY + 2))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.12, y: bubble.minY - bh * 0.32))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.42, y: bubble.minY + 2))
    tail.close()
    NSColor.white.setFill()
    path.fill()
    tail.fill()

    // Waveform bars inside the bubble.
    let heights: [CGFloat] = [0.28, 0.55, 0.85, 0.55, 0.28]
    let barW = bw * 0.075, gap = bw * 0.06
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = bubble.midX - total / 2
    NSColor(red: 0.88, green: 0.25, blue: 0.43, alpha: 1).setFill()
    for h in heights {
        let barH = bh * 0.7 * h
        NSBezierPath(roundedRect: NSRect(x: x, y: bubble.midY - barH / 2, width: barW, height: barH),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
