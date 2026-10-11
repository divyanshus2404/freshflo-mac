import AppKit

/// The Freshflo mark (a messy voice line settling into one clean stroke and a period), drawn from the same
/// geometry as the brand master in Freshflo-Website/brand/icon.svg.
enum BrandMark {
    /// Template image for the menu bar, so macOS tints it for light and dark menu bars.
    static let menuBarImage: NSImage? = {
        let size = NSSize(width: 24, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            // Source geometry spans x 190…817, y 384…636 in the 1024 icon grid.
            let scale = rect.width / 640
            let transform = NSAffineTransform()
            transform.translateX(by: -184 * scale, yBy: rect.midY - 510 * scale)
            transform.scale(by: scale)

            let line = NSBezierPath()
            line.move(to: NSPoint(x: 210, y: 512))
            for (x, y) in [(248.0, 404.0), (290, 616), (332, 446), (370, 564), (400, 498)] { line.line(to: NSPoint(x: x, y: y)) }
            line.curve(to: NSPoint(x: 514, y: 458), controlPoint1: NSPoint(x: 424, y: 444), controlPoint2: NSPoint(x: 476, y: 404))
            line.curve(to: NSPoint(x: 612, y: 588), controlPoint1: NSPoint(x: 550, y: 506), controlPoint2: NSPoint(x: 562, y: 588))
            line.curve(to: NSPoint(x: 714, y: 512), controlPoint1: NSPoint(x: 654, y: 588), controlPoint2: NSPoint(x: 670, y: 512))
            line.lineWidth = 44
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.transform(using: transform as AffineTransform)
            line.lineWidth = 44 * scale

            let dot = NSBezierPath(ovalIn: NSRect(x: 786 - 34, y: 512 - 34, width: 68, height: 68))
            dot.transform(using: transform as AffineTransform)

            NSColor.black.set()
            line.stroke()
            dot.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Freshflo"
        return image
    }()
}
