import AppKit

/// Turns a CursorGeometry.CanvasCursorKind into an NSCursor. Tool-crosshair
/// cursors (crosshair + the tool's toolbar SF Symbol as a badge) are drawn
/// once and cached per symbol; everything else maps to system cursors.
@MainActor
final class ToolCursorFactory {
    private var toolCursors: [String: NSCursor] = [:]

    func cursor(for kind: CursorGeometry.CanvasCursorKind) -> NSCursor {
        switch kind {
        case .standardArrow: .arrow
        case .iBeam: .iBeam
        case .move: .openHand
        case .moving: .closedHand
        // The system crosshair, not the pointing hand: the HIG reserves that
        // for links, and re-placing an arrow tip is the same precise-point job
        // the arrow tool's own crosshair does.
        case .arrowHandle: .crosshair
        case .resize(let handle):
            NSCursor.frameResize(
                position: CursorGeometry.resizePosition(for: handle), directions: .all
            )
        case .toolCrosshair(let tool):
            toolCrosshairCursor(for: tool)
        }
    }

    private func toolCrosshairCursor(for tool: EditorTool) -> NSCursor {
        // The badge must match the toolbar icon exactly, so the symbol comes
        // from the same tool specs the toolbar is built from.
        guard let spec = EditorWindowController.toolSpec(for: tool) else { return .crosshair }
        if let cached = toolCursors[spec.symbol] { return cached }
        let image = Self.crosshairImage(symbol: spec.symbol, label: spec.label)
        let cursor = NSCursor(
            image: image, hotSpot: NSPoint(x: Self.size / 2, y: Self.size / 2)
        )
        toolCursors[spec.symbol] = cursor
        return cursor
    }

    // MARK: - Drawing

    private static let size: CGFloat = 32
    private static let crossArm: CGFloat = 6
    /// Badge center relative to the hotspot: right of and below the crosshair.
    private static let badgeOffset = CGVector(dx: 9, dy: -9)
    private static let badgePointSize: CGFloat = 11

    private static func crosshairImage(symbol: String, label: String) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let center = CGPoint(x: size / 2, y: size / 2)
            drawCross(at: center)
            drawBadge(
                symbol: symbol, label: label,
                at: CGPoint(x: center.x + badgeOffset.dx, y: center.y + badgeOffset.dy)
            )
            return true
        }
    }

    /// Precision crosshair readable on any background: a white 3 pt stroke
    /// under a black 1 pt stroke.
    private static func drawCross(at center: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x - crossArm, y: center.y))
        path.line(to: CGPoint(x: center.x + crossArm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - crossArm))
        path.line(to: CGPoint(x: center.x, y: center.y + crossArm))
        path.lineCapStyle = .round
        NSColor.white.setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The tool symbol in black over white outline copies plus a soft shadow,
    /// so the badge stays legible on both light and dark screenshot content.
    private static func drawBadge(symbol: String, label: String, at center: CGPoint) {
        guard let white = badgeGlyph(symbol: symbol, label: label, color: .white),
              let black = badgeGlyph(symbol: symbol, label: label, color: .black) else { return }
        let rect = CGRect(
            x: center.x - white.size.width / 2,
            y: center.y - white.size.height / 2,
            width: white.size.width,
            height: white.size.height
        )

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.set()
        white.draw(in: rect)
        NSGraphicsContext.current?.restoreGraphicsState()

        for dx: CGFloat in [-1, 0, 1] {
            for dy: CGFloat in [-1, 0, 1] where dx != 0 || dy != 0 {
                white.draw(in: rect.offsetBy(dx: dx, dy: dy))
            }
        }
        black.draw(in: rect)
    }

    private static func badgeGlyph(symbol: String, label: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: badgePointSize, weight: .bold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
    }
}
