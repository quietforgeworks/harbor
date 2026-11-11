import AppKit

enum HarborBrand {
    static func menuImage(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.withAlphaComponent(connected ? 1 : 0.5).setStroke()

            // Open inner ends keep the interlocking links clear at menu-bar size.
            let links = NSBezierPath()
            links.move(to: NSPoint(x: -1, y: 2.5))
            links.line(to: NSPoint(x: -4, y: 2.5))
            links.curve(to: NSPoint(x: -4, y: -2.5),
                        controlPoint1: NSPoint(x: -7.33, y: 2.5),
                        controlPoint2: NSPoint(x: -7.33, y: -2.5))
            links.line(to: NSPoint(x: -1, y: -2.5))
            links.move(to: NSPoint(x: 1, y: 2.5))
            links.line(to: NSPoint(x: 4, y: 2.5))
            links.curve(to: NSPoint(x: 4, y: -2.5),
                        controlPoint1: NSPoint(x: 7.33, y: 2.5),
                        controlPoint2: NSPoint(x: 7.33, y: -2.5))
            links.line(to: NSPoint(x: 1, y: -2.5))
            links.move(to: NSPoint(x: -2, y: 0))
            links.line(to: NSPoint(x: 2, y: 0))

            let diagonal = CGFloat(2).squareRoot() / 2
            let placement = AffineTransform(m11: diagonal, m12: diagonal,
                                            m21: -diagonal, m22: diagonal,
                                            tX: 9, tY: 9)
            links.transform(using: placement)
            links.lineWidth = 1.8
            links.lineCapStyle = .round
            links.lineJoinStyle = .round
            links.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = connected ? "Harbor connected" : "Harbor disconnected"
        return image
    }
}
