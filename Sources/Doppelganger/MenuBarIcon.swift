import AppKit

/// Two overlapping folders, the app icon's picture in one colour for the menu bar.
enum MenuBarIcon {
    enum Badge: String {
        case reconnecting = "arrow.triangle.2.circlepath.circle.fill"
        case offline = "xmark.circle.fill"
        case error = "exclamationmark.circle.fill"
        case setup = "questionmark.circle.fill"
    }

    private static let size = NSSize(width: 22, height: 17)
    private static let folderSize = NSSize(width: 12, height: 9.5)
    private static let rear = NSPoint(x: 7.5, y: 6)
    private static let front = NSPoint(x: 1.5, y: 1.5)
    private static let badgeCentre = NSPoint(x: 16.5, y: 4.25)
    private static let gap: CGFloat = 1.5

    static func image(filled: Bool, badge: Badge? = nil, description: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            paint(folder(at: rear), filled: filled)
            erase(folder(at: front))
            paint(folder(at: front), filled: filled)
            if let badge { draw(badge) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func paint(_ path: NSBezierPath, filled: Bool) {
        if filled {
            path.fill()
        } else {
            path.lineWidth = 1.25
            path.stroke()
        }
    }

    /// Clears the shape and a margin around it, so what it overlaps stays separate.
    private static func erase(_ path: NSBezierPath) {
        let context = NSGraphicsContext.current!
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        path.fill()
        path.lineWidth = gap * 2
        path.stroke()
        context.restoreGraphicsState()
    }

    private static func draw(_ badge: Badge) {
        let (x, y) = (badgeCentre.x, badgeCentre.y)
        erase(NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)))
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: badge.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height))
    }

    private static func folder(at origin: NSPoint) -> NSBezierPath {
        let (x, y, w, h) = (origin.x, origin.y, folderSize.width, folderSize.height)
        let radius: CGFloat = 1.5
        let tabHeight: CGFloat = 1.75
        let tabWidth: CGFloat = 4.75
        let shoulder = y + h - tabHeight

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + radius, y: y))
        path.line(to: NSPoint(x: x + w - radius, y: y))
        path.appendArc(from: NSPoint(x: x + w, y: y), to: NSPoint(x: x + w, y: y + radius), radius: radius)
        path.line(to: NSPoint(x: x + w, y: shoulder - radius))
        path.appendArc(from: NSPoint(x: x + w, y: shoulder), to: NSPoint(x: x + w - radius, y: shoulder), radius: radius)
        path.line(to: NSPoint(x: x + tabWidth + tabHeight, y: shoulder))
        path.line(to: NSPoint(x: x + tabWidth, y: y + h))
        path.line(to: NSPoint(x: x + radius, y: y + h))
        path.appendArc(from: NSPoint(x: x, y: y + h), to: NSPoint(x: x, y: y + h - radius), radius: radius)
        path.line(to: NSPoint(x: x, y: y + radius))
        path.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + radius, y: y), radius: radius)
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
