import AppKit
import Carbon.HIToolbox

/// PURE geometry of the recording Setup overlay (T1) — unit-tested; the overlay
/// view only draws what this returns and turns mouse/keys into these calls.
///
/// Everything is in **AppKit global** points (like `RecordingTarget`), and
/// `display` is the target display's frame (`NSScreen.frame`): one display per
/// recording (Q11), so every rect produced here lies inside it and is at least
/// `minSize`. Unlike the editor's handles, a Setup handle never flips the rect
/// across its opposite edge — it stops `minSize` short of it.
enum SetupGeometry {
    /// The eight handles; the editor's naming (min/mid/max X × Y), so its
    /// frame-resize cursor mapping (`CursorGeometry.resizePosition`) applies.
    typealias Handle = AnnotationGeometry.ResizeHandle

    /// Smallest recordable rect. The window picker ignores windows below 40 pt
    /// for the same reason: smaller is a misclick, not a recording.
    static let minSize = CGSize(width: 40, height: 40)

    // MARK: - Clamping

    /// `rect` made at least `minSize`, at most the display, and moved (never
    /// shrunk) until it lies inside the display.
    static func clamped(_ rect: CGRect, to display: CGRect, minSize: CGSize = minSize) -> CGRect {
        let rect = rect.standardized
        let size = CGSize(
            width: min(max(rect.width, minSize.width), display.width),
            height: min(max(rect.height, minSize.height), display.height)
        )
        return CGRect(origin: inside(rect.origin, size: size, display: display), size: size)
    }

    /// `rect` offset by `delta`, stopping at the display's edges (size kept).
    static func moved(_ rect: CGRect, by delta: CGVector, within display: CGRect) -> CGRect {
        let origin = CGPoint(x: rect.minX + delta.dx, y: rect.minY + delta.dy)
        return CGRect(origin: inside(origin, size: rect.size, display: display), size: rect.size)
    }

    /// The origin that keeps a rect of `size` inside `display` (leading /
    /// bottom edge wins when it is larger).
    private static func inside(_ origin: CGPoint, size: CGSize, display: CGRect) -> CGPoint {
        CGPoint(
            x: max(min(origin.x, display.maxX - size.width), display.minX),
            y: max(min(origin.y, display.maxY - size.height), display.minY)
        )
    }

    // MARK: - Arrow keys: nudge and keyboard resize

    static let arrowStep: CGFloat = 1
    static let shiftArrowStep: CGFloat = 10

    /// What an arrow key asks for. Both carry the step as a vector (AppKit y
    /// grows up, so ↑ is +y).
    enum ArrowEdit: Equatable {
        /// Arrow: move the rect.
        case nudge(CGVector)
        /// ⌥-arrow: move the right (→ ←) or top (↑ ↓) edge — the keyboard
        /// route to resizing (Design decision, shortcuts-first rule).
        case resize(CGVector)
    }

    /// Arrow = nudge, ⌥-arrow = resize; 1 pt, 10 pt with ⇧. Nil for any other
    /// key or with ⌘/⌃. Arrow keys carry `.numericPad` and `.function` in
    /// their flags, which is why this can't use `ShortcutKeys.isBareKey`.
    static func arrowEdit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ArrowEdit? {
        var flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let resizes = flags.contains(.option)
        flags.remove(.option)
        guard flags.isEmpty || flags == .shift else { return nil }
        let step = flags == .shift ? shiftArrowStep : arrowStep
        let delta: CGVector
        switch Int(keyCode) {
        case kVK_LeftArrow: delta = CGVector(dx: -step, dy: 0)
        case kVK_RightArrow: delta = CGVector(dx: step, dy: 0)
        case kVK_DownArrow: delta = CGVector(dx: 0, dy: -step)
        case kVK_UpArrow: delta = CGVector(dx: 0, dy: step)
        default: return nil
        }
        return resizes ? .resize(delta) : .nudge(delta)
    }

    /// `rect` after an arrow edit: a nudge moves it (stopping at the display
    /// edges); a resize moves the right/top edge like dragging the top-right
    /// handle, with the same display and min-size limits.
    static func applying(
        _ edit: ArrowEdit, to rect: CGRect, within display: CGRect, minSize: CGSize = minSize
    ) -> CGRect {
        switch edit {
        case .nudge(let delta):
            moved(rect, by: delta, within: display)
        case .resize(let delta):
            resized(rect, dragging: .maxXmaxY, by: delta, within: display, minSize: minSize)
        }
    }

    // MARK: - Scroll = resize around the centre (Q5/Q21 a)

    /// One scroll event's scale factor — the pins' scroll-zoom sensitivity
    /// (`PinGeometry.zoomFactor`), so scrolling feels the same everywhere.
    static func scrollFactor(deltaY: CGFloat) -> CGFloat {
        PinGeometry.zoomFactor(forScrollDeltaY: deltaY)
    }

    /// `rect` scaled by `factor` around its centre with aspect `aspect`
    /// (width ÷ height) kept, in whole points. The width is held between what
    /// `minSize` and the display allow *at that aspect*, so neither the min
    /// size nor the display edge ever distorts it; the centre only moves when
    /// the grown rect would cross the display edge. Pass the aspect the scroll
    /// gesture started with: re-deriving it from the rounded rect each event
    /// would let it drift.
    static func scrollResized(
        _ rect: CGRect, factor: CGFloat, aspect: CGFloat? = nil,
        within display: CGRect, minSize: CGSize = minSize
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0, factor > 0 else { return rect }
        let aspect = aspect.flatMap { $0 > 0 ? $0 : nil } ?? rect.width / rect.height
        let lowest = max(minSize.width, minSize.height * aspect)
        let highest = min(display.width, display.height * aspect)
        // An aspect so extreme that no width satisfies both: leave it alone.
        guard lowest <= highest else { return rect }
        // Never let a scroll in one direction move the size the other way
        // (a rect already outside the range just stays where it is).
        let width = min(max(rect.width * factor, min(lowest, rect.width)), max(highest, rect.width)).rounded()
        let height = min((width / aspect).rounded(), display.height)
        let scaled = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return CGRect(origin: inside(scaled.origin, size: scaled.size, display: display), size: scaled.size)
    }

    // MARK: - Hit testing

    /// Drawn handle size, and the two hit radii (the editor's): the 7 pt core
    /// always grabs the handle; the 10 pt ring (20 pt target, the HIG macOS
    /// minimum) only outside the rect, so a small rect keeps a body to move.
    static let handleDrawSize: CGFloat = 8
    static let handleCoreHitRadius: CGFloat = 7
    static let handleHitRadius: CGFloat = 10

    enum Hit: Equatable {
        case handle(Handle)
        /// Inside the rect: drag moves it.
        case inside
        /// Outside: drag selects a new free rect.
        case outside
    }

    /// `handles: false` (a locked W target, which draws none) classifies by
    /// containment alone, so a press just outside never lands on an
    /// invisible handle instead of starting a new rect.
    static func hit(at point: CGPoint, rect: CGRect, handles: Bool = true) -> Hit {
        let isInside = rect.contains(point)
        guard handles else { return isInside ? .inside : .outside }
        let handle = AnnotationGeometry.arbitrateHandle(
            core: AnnotationGeometry.handleHit(at: point, rect: rect, radius: handleCoreHitRadius),
            full: AnnotationGeometry.handleHit(at: point, rect: rect, radius: handleHitRadius),
            pointIsOnABody: isInside
        )
        if let handle { return .handle(handle) }
        return isInside ? .inside : .outside
    }

    /// The squares to draw, one per handle, centred on the rect's edges.
    static func handleRects(for rect: CGRect) -> [CGRect] {
        Handle.allCases.map { handle in
            let p = AnnotationGeometry.handlePoint(handle, in: rect)
            return CGRect(
                x: p.x - handleDrawSize / 2, y: p.y - handleDrawSize / 2,
                width: handleDrawSize, height: handleDrawSize
            )
        }
    }

    // MARK: - Handle resize

    /// `rect` with the edges `handle` controls moved by `delta`. Each moving
    /// edge stops at the display edge and `minSize` short of its opposite edge
    /// (no flipping); the edges it doesn't control never move.
    static func resized(
        _ rect: CGRect, dragging handle: Handle, by delta: CGVector,
        within display: CGRect, minSize: CGSize = minSize
    ) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        if handle.movesMinX {
            minX = bounded(minX + delta.dx, low: display.minX, high: maxX - minSize.width, edge: display.minX)
        }
        if handle.movesMaxX {
            maxX = bounded(maxX + delta.dx, low: minX + minSize.width, high: display.maxX, edge: display.maxX)
        }
        if handle.movesMinY {
            minY = bounded(minY + delta.dy, low: display.minY, high: maxY - minSize.height, edge: display.minY)
        }
        if handle.movesMaxY {
            maxY = bounded(maxY + delta.dy, low: minY + minSize.height, high: display.maxY, edge: display.maxY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `value` clamped to `low...high`; when the range is empty (a rect already
    /// below `minSize` against the display edge) the display `edge` wins.
    private static func bounded(_ value: CGFloat, low: CGFloat, high: CGFloat, edge: CGFloat) -> CGFloat {
        guard low <= high else { return edge }
        return min(max(value, low), high)
    }

    // MARK: - Drag outside = new free rect

    /// How far the mouse must travel before a press outside becomes a new
    /// rect — a plain click outside keeps the current one.
    static let reselectThreshold: CGFloat = 3

    /// The rect spanned from `anchor` (mouse-down) to `current`, both clamped
    /// to the display. Below `minSize` it grows away from the anchor in the
    /// drag's direction, then moves back inside the display. Nil while the
    /// drag is still under `reselectThreshold`.
    static func reselected(
        anchor: CGPoint, current: CGPoint, within display: CGRect, minSize: CGSize = minSize
    ) -> CGRect? {
        let a = CaptureGeometry.clamp(anchor, to: display)
        let c = CaptureGeometry.clamp(current, to: display)
        guard max(abs(c.x - a.x), abs(c.y - a.y)) >= reselectThreshold else { return nil }
        var minX = min(a.x, c.x), maxX = max(a.x, c.x)
        var minY = min(a.y, c.y), maxY = max(a.y, c.y)
        if maxX - minX < minSize.width {
            if c.x >= a.x { maxX = a.x + minSize.width } else { minX = a.x - minSize.width }
        }
        if maxY - minY < minSize.height {
            if c.y >= a.y { maxY = a.y + minSize.height } else { minY = a.y - minSize.height }
        }
        return clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: display, minSize: minSize)
    }

    // MARK: - Pointer gestures

    /// One mouse drag in Pointer mode, from mouse-down to mouse-up. Every
    /// step is computed from the gesture's start, never accumulated.
    enum Gesture: Equatable {
        case move(from: CGRect, start: CGPoint)
        case resize(Handle, from: CGRect, start: CGPoint)
        case reselect(anchor: CGPoint)
    }

    /// The gesture a press at `point` starts. `editable` is false for a window
    /// target (W): its rect is the window's, so only a new free rect can
    /// replace it — no handles, no move.
    static func gesture(at point: CGPoint, rect: CGRect, editable: Bool) -> Gesture? {
        switch hit(at: point, rect: rect, handles: editable) {
        case .handle(let handle): editable ? .resize(handle, from: rect, start: point) : nil
        case .inside: editable ? .move(from: rect, start: point) : nil
        case .outside: .reselect(anchor: point)
        }
    }

    /// The rect `gesture` produces with the mouse at `point`; nil while a
    /// re-select is under its threshold.
    static func rect(
        for gesture: Gesture, at point: CGPoint, within display: CGRect, minSize: CGSize = minSize
    ) -> CGRect? {
        switch gesture {
        case .move(let from, let start):
            moved(from, by: CGVector(dx: point.x - start.x, dy: point.y - start.y), within: display)
        case .resize(let handle, let from, let start):
            resized(
                from, dragging: handle, by: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                within: display, minSize: minSize
            )
        case .reselect(let anchor):
            reselected(anchor: anchor, current: point, within: display, minSize: minSize)
        }
    }

    // MARK: - Size chip

    /// "W × H" in whole points (the readout the screenshot overlay uses,
    /// without its half-point precision: Setup rects are whole points).
    static func sizeReadout(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// Inset of the size chip from the rect's top-left corner — clear of the
    /// corner handle.
    static let sizeChipInset: CGFloat = 10

    /// Frame of the size chip: **inside** the rect's top-left corner, so it
    /// never meets the amber border or the toolbar (T4), which sit outside the
    /// rect. A rect too small to hold it gets it just above its top-left
    /// corner instead. Always fully inside `bounds`. Same coordinate space for
    /// all three rects (the overlay view's).
    static func sizeChipFrame(textSize: CGSize, rect: CGRect, bounds: CGRect) -> CGRect {
        let padding = OverlayGeometry.sizeChipPadding
        let size = CGSize(width: textSize.width + 2 * padding, height: textSize.height + 2 * padding)
        let fits = size.width + 2 * sizeChipInset <= rect.width && size.height + 2 * sizeChipInset <= rect.height
        let origin = fits
            ? CGPoint(x: rect.minX + sizeChipInset, y: rect.maxY - sizeChipInset - size.height)
            : CGPoint(x: rect.minX, y: rect.maxY + sizeChipInset)
        return OverlayGeometry.clamped(CGRect(origin: origin, size: size), into: bounds)
    }

    // MARK: - Dimming

    /// Opacity of the black dimming outside the rect (Setup and snapping).
    /// The amber border (T4) carries the rect's edge; the dimming only says
    /// "not recorded", so it stays light enough to read what's outside. With
    /// Increase Contrast the step from rect to dimming reaches 3:1 even on a
    /// white screen (HIG accessibility › Vision: offer a
    /// higher-contrast scheme when Increase Contrast is on).
    static func dimmingAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 0.45 : 0.3
    }

    /// Opacity of the handles' dark outline: the overlay edge's shade, opaque
    /// with Increase Contrast.
    static func handleOutlineAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 1 : OverlayGeometry.edgeShadeAlpha
    }

    /// The part of `target` the overlay leaves undimmed, in the overlay's own
    /// space (`display` origin at 0,0). Nil when the target is off this
    /// display (a window target that moved away).
    static func localRect(of target: CGRect, display: CGRect) -> CGRect? {
        let visible = target.intersection(display)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return visible.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    // MARK: - Display and target rules

    /// The target display: frame and ID always travel together, so a
    /// fallback screen never carries a disconnected display's ID.
    struct Display: Equatable, Sendable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    /// The display a Setup for `target` lives on: its own when attached;
    /// otherwise (unplugged mid-Setup) the one showing most of the target,
    /// else the first (the primary). Nil only without any screen.
    static func display(for target: RecordingTarget, among screens: [Display]) -> Display? {
        if let own = screens.first(where: { $0.id == target.displayID }) { return own }
        let overlap = { (screen: Display) -> CGFloat in
            let shared = screen.frame.intersection(target.frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        return screens.first
    }

    /// What the session's target should be, given what only the overlay
    /// knows (the resolved display, the hovered window) — nil for "no
    /// opinion". The overlay reports it when it differs:
    /// - Setup, area target: on the display, at least `minSize`, with that
    ///   display's ID. Covers a tiny screenshot rect handed over by R, a
    ///   Retake or fallback area off the display, and a display that changed
    ///   or vanished.
    /// - Setup, window target (W): locked — its rect is the window's.
    /// - Snapping: the hovered window — or the picked `part` of it — as the
    ///   current kind (S area / W window or window part — so switching S ↔ W
    ///   over a window converts it); nothing hovered: the target from before
    ///   snapping.
    /// - Countdown on: nil — the rect is final.
    static func desiredTarget(
        for session: RecordingSession, hovered: SnapWindow?, part: SnapPart? = nil, display: Display
    ) -> RecordingTarget? {
        switch session.phase {
        case .setup:
            guard !session.target.isWindow else { return nil }
            return .area(globalRect: clamped(session.target.frame, to: display.frame), displayID: display.id)
        case .snapping(let kind, let previous, _):
            guard let hovered else { return previous }
            return WindowSnapCandidates.target(
                for: hovered, part: part, kind: kind, screenFrame: display.frame, displayID: display.id
            )
        case .countdown, .recording, .stopping, .finished, .cancelled:
            return nil
        }
    }
}
