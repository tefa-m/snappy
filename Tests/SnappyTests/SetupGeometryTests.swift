import AppKit
import Carbon.HIToolbox
import Testing
@testable import Snappy

@Suite("SetupGeometry")
struct SetupGeometryTests {
    private static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// A secondary display right of the primary and higher up: nothing may
    /// assume a zero origin.
    private static let secondary = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
    private static let minimum = SetupGeometry.minSize

    // MARK: - Clamping

    @Test func clampLeavesARectInsideTheDisplayAlone() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(SetupGeometry.clamped(rect, to: Self.display) == rect)
    }

    @Test func clampMovesAnOverhangingRectBackWithoutShrinkingIt() {
        let rect = CGRect(x: 1300, y: -50, width: 300, height: 200)
        #expect(SetupGeometry.clamped(rect, to: Self.display) == CGRect(x: 1140, y: 0, width: 300, height: 200))
    }

    @Test func clampGrowsATinyRectToTheMinimumSize() {
        let rect = CGRect(x: 10, y: 10, width: 5, height: 100)
        #expect(SetupGeometry.clamped(rect, to: Self.display).size == CGSize(width: Self.minimum.width, height: 100))
    }

    @Test func clampShrinksARectLargerThanTheDisplayToTheDisplay() {
        let rect = CGRect(x: -100, y: -100, width: 3000, height: 2000)
        #expect(SetupGeometry.clamped(rect, to: Self.display) == Self.display)
    }

    @Test func clampStandardizesANegativeRect() {
        let rect = CGRect(x: 400, y: 300, width: -200, height: -100)
        #expect(SetupGeometry.clamped(rect, to: Self.display) == CGRect(x: 200, y: 200, width: 200, height: 100))
    }

    @Test func clampWorksOnASecondaryDisplay() {
        let rect = CGRect(x: 1400, y: 100, width: 300, height: 300)
        #expect(SetupGeometry.clamped(rect, to: Self.secondary) == CGRect(x: 1440, y: 200, width: 300, height: 300))
    }

    // MARK: - Move

    @Test func moveOffsetsTheRect() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(SetupGeometry.moved(rect, by: CGVector(dx: 25, dy: -40), within: Self.display)
            == CGRect(x: 125, y: 60, width: 300, height: 200))
    }

    @Test(arguments: [
        (CGVector(dx: -500, dy: 0), CGPoint(x: 0, y: 100)),
        (CGVector(dx: 5000, dy: 0), CGPoint(x: 1140, y: 100)),
        (CGVector(dx: 0, dy: -500), CGPoint(x: 100, y: 0)),
        (CGVector(dx: 0, dy: 5000), CGPoint(x: 100, y: 700)),
    ])
    func moveStopsAtEachDisplayEdge(delta: CGVector, origin: CGPoint) {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(SetupGeometry.moved(rect, by: delta, within: Self.display) == CGRect(origin: origin, size: rect.size))
    }

    @Test func moveStopsAtASecondaryDisplaysEdges() {
        let rect = CGRect(x: 1500, y: 300, width: 300, height: 200)
        let moved = SetupGeometry.moved(rect, by: CGVector(dx: -1000, dy: -1000), within: Self.secondary)
        #expect(moved.origin == CGPoint(x: 1440, y: 200))
    }

    // MARK: - Arrow keys: nudge and ⌥ resize

    private static let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func edit(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = []) -> SetupGeometry.ArrowEdit? {
        SetupGeometry.arrowEdit(keyCode: UInt16(keyCode), modifiers: modifiers.union(Self.arrowFlags))
    }

    private static let directions: [(Int, CGVector)] = [
        (kVK_LeftArrow, CGVector(dx: -1, dy: 0)),
        (kVK_RightArrow, CGVector(dx: 1, dy: 0)),
        (kVK_UpArrow, CGVector(dx: 0, dy: 1)),
        (kVK_DownArrow, CGVector(dx: 0, dy: -1)),
    ]

    @Test(arguments: directions)
    func arrowKeysNudgeOnePoint(keyCode: Int, delta: CGVector) {
        #expect(edit(keyCode) == .nudge(delta))
        // Without the arrow flags (synthetic events) too.
        #expect(SetupGeometry.arrowEdit(keyCode: UInt16(keyCode), modifiers: []) == .nudge(delta))
    }

    @Test(arguments: directions)
    func optionArrowsResizeOnePoint(keyCode: Int, delta: CGVector) {
        #expect(edit(keyCode, .option) == .resize(delta))
    }

    @Test func shiftMakesItTenPoints() {
        #expect(edit(kVK_LeftArrow, .shift) == .nudge(CGVector(dx: -10, dy: 0)))
        #expect(SetupGeometry.arrowEdit(keyCode: UInt16(kVK_UpArrow), modifiers: [.shift, .capsLock])
            == .nudge(CGVector(dx: 0, dy: 10)))
        #expect(edit(kVK_RightArrow, [.shift, .option]) == .resize(CGVector(dx: 10, dy: 0)))
        #expect(edit(kVK_DownArrow, [.shift, .option]) == .resize(CGVector(dx: 0, dy: -10)))
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.command, .control, [.shift, .command], [.option, .command], [.option, .control],
    ])
    func otherModifiersDoNothing(modifiers: NSEvent.ModifierFlags) {
        #expect(edit(kVK_LeftArrow, modifiers) == nil)
    }

    @Test func capsLockDoesNotBlockArrows() {
        #expect(edit(kVK_RightArrow, .capsLock) == .nudge(CGVector(dx: 1, dy: 0)))
        #expect(edit(kVK_RightArrow, [.capsLock, .option]) == .resize(CGVector(dx: 1, dy: 0)))
    }

    @Test func otherKeysAreNotArrowEdits() {
        #expect(SetupGeometry.arrowEdit(keyCode: UInt16(kVK_ANSI_R), modifiers: []) == nil)
        #expect(SetupGeometry.arrowEdit(keyCode: UInt16(kVK_Escape), modifiers: .option) == nil)
    }

    @Test func aNudgeMovesTheRectWithinTheDisplay() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(SetupGeometry.applying(.nudge(CGVector(dx: 10, dy: 0)), to: rect, within: Self.display)
            == rect.offsetBy(dx: 10, dy: 0))
        let atEdge = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(SetupGeometry.applying(.nudge(CGVector(dx: -1, dy: -10)), to: atEdge, within: Self.display) == atEdge)
    }

    /// ⌥→/⌥← move the right edge, ⌥↑/⌥↓ the top edge; left and bottom stay.
    @Test func optionArrowsMoveTheRightAndTopEdges() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 1, dy: 0)), to: rect, within: Self.display)
            == CGRect(x: 100, y: 100, width: 301, height: 200))
        #expect(SetupGeometry.applying(.resize(CGVector(dx: -10, dy: 0)), to: rect, within: Self.display)
            == CGRect(x: 100, y: 100, width: 290, height: 200))
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 0, dy: 10)), to: rect, within: Self.display)
            == CGRect(x: 100, y: 100, width: 300, height: 210))
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 0, dy: -1)), to: rect, within: Self.display)
            == CGRect(x: 100, y: 100, width: 300, height: 199))
    }

    @Test func keyboardResizeStopsAtTheMinimumAndTheDisplayEdge() {
        let small = CGRect(x: 100, y: 100, width: Self.minimum.width, height: Self.minimum.height)
        #expect(SetupGeometry.applying(.resize(CGVector(dx: -10, dy: 0)), to: small, within: Self.display) == small)
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 0, dy: -10)), to: small, within: Self.display) == small)
        let atEdge = CGRect(x: 1140, y: 700, width: 300, height: 200) // touches the right and top edges
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 10, dy: 0)), to: atEdge, within: Self.display) == atEdge)
        #expect(SetupGeometry.applying(.resize(CGVector(dx: 0, dy: 10)), to: atEdge, within: Self.display) == atEdge)
    }

    // MARK: - Scroll resize

    @Test func scrollingUpGrowsAndDownShrinks() {
        #expect(SetupGeometry.scrollFactor(deltaY: 4) > 1)
        #expect(SetupGeometry.scrollFactor(deltaY: -4) < 1)
        #expect(SetupGeometry.scrollFactor(deltaY: 0) == 1)
    }

    @Test func scrollResizesAroundTheCentreKeepingTheAspect() {
        let rect = CGRect(x: 400, y: 300, width: 400, height: 200)
        let grown = SetupGeometry.scrollResized(rect, factor: 1.5, within: Self.display)
        #expect(grown.size == CGSize(width: 600, height: 300))
        #expect(grown.midX == rect.midX)
        #expect(grown.midY == rect.midY)
        let shrunk = SetupGeometry.scrollResized(rect, factor: 0.5, within: Self.display)
        #expect(shrunk.size == CGSize(width: 200, height: 100))
        #expect(shrunk.midX == rect.midX)
        #expect(shrunk.midY == rect.midY)
    }

    @Test func scrollResultIsInWholePoints() {
        let rect = CGRect(x: 400, y: 300, width: 333, height: 211)
        let grown = SetupGeometry.scrollResized(rect, factor: 1.0137, within: Self.display)
        #expect(grown.width == grown.width.rounded())
        #expect(grown.height == grown.height.rounded())
    }

    /// The min size stops the shrink at the aspect-preserving minimum — the
    /// short side reaches it, the long side keeps the ratio.
    @Test func scrollShrinkStopsAtTheMinimumWithTheAspectKept() {
        let rect = CGRect(x: 400, y: 300, width: 400, height: 200)
        let shrunk = SetupGeometry.scrollResized(rect, factor: 0.01, within: Self.display)
        #expect(shrunk.size == CGSize(width: 2 * Self.minimum.height, height: Self.minimum.height))
    }

    @Test func scrollGrowStopsAtTheDisplayWithTheAspectKept() {
        let rect = CGRect(x: 400, y: 300, width: 400, height: 200) // 2:1, display is 1.6:1
        let grown = SetupGeometry.scrollResized(rect, factor: 100, within: Self.display)
        #expect(grown.size == CGSize(width: 1440, height: 720))
        #expect(Self.display.contains(grown))
    }

    /// Near an edge the centre moves only as far as needed to stay on the display.
    @Test func scrollGrowthNearAnEdgeShiftsBackInside() {
        let rect = CGRect(x: 1300, y: 800, width: 100, height: 80)
        let grown = SetupGeometry.scrollResized(rect, factor: 2, within: Self.display)
        #expect(grown.size == CGSize(width: 200, height: 160))
        #expect(grown.maxX == 1440)
        #expect(grown.maxY == 900)
    }

    /// Passing the gesture's aspect keeps it exact over many rounded steps.
    @Test func repeatedScrollingWithTheGestureAspectDoesNotDrift() {
        let start = CGRect(x: 300, y: 300, width: 457, height: 263)
        let aspect = start.width / start.height
        var rect = start
        for step in 0..<60 {
            let factor = SetupGeometry.scrollFactor(deltaY: step < 30 ? 3.7 : -3.7)
            rect = SetupGeometry.scrollResized(rect, factor: factor, aspect: aspect, within: Self.display)
            #expect(abs(rect.width / aspect - rect.height) <= 0.5)
        }
    }

    @Test func scrollNeverGrowsARectThatScrollsDown() {
        // Already below the minimum (e.g. an S-snapped sliver): scrolling down
        // leaves it alone instead of jumping to the minimum.
        let rect = CGRect(x: 100, y: 100, width: 30, height: 30)
        #expect(SetupGeometry.scrollResized(rect, factor: 0.9, within: Self.display).size == rect.size)
    }

    @Test func scrollLeavesAnImpossibleAspectAlone() {
        // 40 × 1 aspect on a 1440 × 900 display: no width satisfies both the
        // min height and the display width.
        let rect = CGRect(x: 0, y: 0, width: 1440, height: 36)
        #expect(SetupGeometry.scrollResized(rect, factor: 2, aspect: 40, within: Self.display) == rect)
    }

    @Test func scrollOnAnEmptyRectIsANoOp() {
        let rect = CGRect(x: 10, y: 10, width: 0, height: 0)
        #expect(SetupGeometry.scrollResized(rect, factor: 2, within: Self.display) == rect)
    }

    @Test func scrollWorksOnASecondaryDisplay() {
        let rect = CGRect(x: 1500, y: 250, width: 200, height: 100)
        let grown = SetupGeometry.scrollResized(rect, factor: 2, within: Self.secondary)
        #expect(grown.size == CGSize(width: 400, height: 200))
        #expect(Self.secondary.contains(grown))
    }

    // MARK: - Hit testing

    private static let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func everyHandleIsHitAtItsPoint() {
        for handle in SetupGeometry.Handle.allCases {
            let point = AnnotationGeometry.handlePoint(handle, in: Self.rect)
            #expect(SetupGeometry.hit(at: point, rect: Self.rect) == .handle(handle))
        }
    }

    @Test func theHandleRingCountsOnlyOutsideTheRect() {
        // Core (≤ 7 pt) always grabs the handle, inside or out.
        #expect(SetupGeometry.hit(at: CGPoint(x: 104, y: 104), rect: Self.rect) == .handle(.minXminY))
        // Ring (7–10 pt): a handle only outside the rect; inside it is body.
        #expect(SetupGeometry.hit(at: CGPoint(x: 109, y: 99), rect: Self.rect) == .handle(.minXminY))
        #expect(SetupGeometry.hit(at: CGPoint(x: 93, y: 93), rect: Self.rect) == .handle(.minXminY))
        #expect(SetupGeometry.hit(at: CGPoint(x: 109, y: 100), rect: Self.rect) == .inside)
        #expect(SetupGeometry.hit(at: CGPoint(x: 106.5, y: 106.5), rect: Self.rect) == .inside)
        // Beyond the ring.
        #expect(SetupGeometry.hit(at: CGPoint(x: 92, y: 92), rect: Self.rect) == .outside)
    }

    @Test func insideAndOutsideAwayFromHandles() {
        #expect(SetupGeometry.hit(at: CGPoint(x: 300, y: 250), rect: Self.rect) == .inside)
        #expect(SetupGeometry.hit(at: CGPoint(x: 50, y: 250), rect: Self.rect) == .outside)
        #expect(SetupGeometry.hit(at: CGPoint(x: 300, y: 450), rect: Self.rect) == .outside)
    }

    @Test func handleRectsAreCentredOnTheEightHandlePoints() {
        let rects = SetupGeometry.handleRects(for: Self.rect)
        #expect(rects.count == 8)
        for (rect, handle) in zip(rects, SetupGeometry.Handle.allCases) {
            let point = AnnotationGeometry.handlePoint(handle, in: Self.rect)
            #expect(rect.midX == point.x)
            #expect(rect.midY == point.y)
            #expect(rect.width == SetupGeometry.handleDrawSize)
        }
    }

    // MARK: - Handle resize

    @Test func eachHandleMovesOnlyItsOwnEdges() {
        let delta = CGVector(dx: 20, dy: 30)
        for handle in SetupGeometry.Handle.allCases {
            let r = SetupGeometry.resized(Self.rect, dragging: handle, by: delta, within: Self.display)
            #expect(r.minX == Self.rect.minX + (handle.movesMinX ? 20 : 0))
            #expect(r.maxX == Self.rect.maxX + (handle.movesMaxX ? 20 : 0))
            #expect(r.minY == Self.rect.minY + (handle.movesMinY ? 30 : 0))
            #expect(r.maxY == Self.rect.maxY + (handle.movesMaxY ? 30 : 0))
        }
    }

    @Test func resizeStopsAtTheMinimumSizeInsteadOfFlipping() {
        let left = SetupGeometry.resized(Self.rect, dragging: .minXmidY, by: CGVector(dx: 1000, dy: 0), within: Self.display)
        #expect(left == CGRect(x: Self.rect.maxX - Self.minimum.width, y: 100, width: Self.minimum.width, height: 300))
        let top = SetupGeometry.resized(Self.rect, dragging: .midXmaxY, by: CGVector(dx: 0, dy: -1000), within: Self.display)
        #expect(top == CGRect(x: 100, y: 100, width: 400, height: Self.minimum.height))
        let corner = SetupGeometry.resized(
            Self.rect, dragging: .maxXminY, by: CGVector(dx: -1000, dy: 1000), within: Self.display
        )
        #expect(corner == CGRect(x: 100, y: Self.rect.maxY - Self.minimum.height, width: Self.minimum.width, height: Self.minimum.height))
    }

    @Test func resizeStopsAtTheDisplayEdges() {
        let grown = SetupGeometry.resized(Self.rect, dragging: .minXminY, by: CGVector(dx: -1000, dy: -1000), within: Self.display)
        #expect(grown == CGRect(x: 0, y: 0, width: 500, height: 400))
        let other = SetupGeometry.resized(Self.rect, dragging: .maxXmaxY, by: CGVector(dx: 5000, dy: 5000), within: Self.display)
        #expect(other == CGRect(x: 100, y: 100, width: 1340, height: 800))
    }

    @Test func resizeOnASecondaryDisplayStopsAtItsEdges() {
        let rect = CGRect(x: 1600, y: 300, width: 200, height: 200)
        let r = SetupGeometry.resized(rect, dragging: .minXminY, by: CGVector(dx: -1000, dy: -1000), within: Self.secondary)
        #expect(r == CGRect(x: 1440, y: 200, width: 360, height: 300))
    }

    // MARK: - Re-select (drag outside)

    @Test func aClickWithoutADragKeepsTheRect() {
        #expect(SetupGeometry.reselected(anchor: CGPoint(x: 10, y: 10), current: CGPoint(x: 12, y: 11), within: Self.display) == nil)
    }

    @Test func dragOutsideSpansANewRectInAnyDirection() {
        let a = CGPoint(x: 600, y: 500)
        #expect(SetupGeometry.reselected(anchor: a, current: CGPoint(x: 900, y: 700), within: Self.display)
            == CGRect(x: 600, y: 500, width: 300, height: 200))
        #expect(SetupGeometry.reselected(anchor: a, current: CGPoint(x: 300, y: 200), within: Self.display)
            == CGRect(x: 300, y: 200, width: 300, height: 300))
    }

    @Test func aSmallDragGrowsToTheMinimumInTheDragsDirection() {
        let a = CGPoint(x: 600, y: 500)
        #expect(SetupGeometry.reselected(anchor: a, current: CGPoint(x: 610, y: 505), within: Self.display)
            == CGRect(x: 600, y: 500, width: Self.minimum.width, height: Self.minimum.height))
        #expect(SetupGeometry.reselected(anchor: a, current: CGPoint(x: 590, y: 495), within: Self.display)
            == CGRect(x: 600 - Self.minimum.width, y: 500 - Self.minimum.height, width: Self.minimum.width, height: Self.minimum.height))
    }

    @Test func reselectIsClampedToTheDisplay() {
        // Mouse beyond the display: the rect ends at its edge.
        #expect(SetupGeometry.reselected(anchor: CGPoint(x: 1300, y: 700), current: CGPoint(x: 2000, y: 1200), within: Self.display)
            == CGRect(x: 1300, y: 700, width: 140, height: 200))
        // A minimum-size rect started at the edge moves back inside.
        #expect(SetupGeometry.reselected(anchor: CGPoint(x: 1440, y: 900), current: CGPoint(x: 1430, y: 905), within: Self.display)
            == CGRect(x: 1400, y: 860, width: Self.minimum.width, height: Self.minimum.height))
    }

    // MARK: - Gestures

    @Test func aPressStartsTheGestureItsHitCallsFor() {
        let inside = CGPoint(x: 300, y: 250)
        let corner = CGPoint(x: 500, y: 400)
        let outside = CGPoint(x: 50, y: 50)
        #expect(SetupGeometry.gesture(at: inside, rect: Self.rect, editable: true) == .move(from: Self.rect, start: inside))
        #expect(SetupGeometry.gesture(at: corner, rect: Self.rect, editable: true)
            == .resize(.maxXmaxY, from: Self.rect, start: corner))
        #expect(SetupGeometry.gesture(at: outside, rect: Self.rect, editable: true) == .reselect(anchor: outside))
    }

    /// A window target (W) can only be replaced by a new free rect.
    @Test func aWindowTargetCanOnlyBeReselected() {
        let outside = CGPoint(x: 50, y: 50)
        #expect(SetupGeometry.gesture(at: CGPoint(x: 300, y: 250), rect: Self.rect, editable: false) == nil)
        // Just inside the top-right corner (no hidden handle there to grab).
        #expect(SetupGeometry.gesture(at: CGPoint(x: 499, y: 399), rect: Self.rect, editable: false) == nil)
        #expect(SetupGeometry.gesture(at: outside, rect: Self.rect, editable: false) == .reselect(anchor: outside))
    }

    @Test func gestureStepsAreComputedFromTheStart() {
        let start = CGPoint(x: 300, y: 250)
        let move = SetupGeometry.Gesture.move(from: Self.rect, start: start)
        #expect(SetupGeometry.rect(for: move, at: CGPoint(x: 310, y: 240), within: Self.display)
            == Self.rect.offsetBy(dx: 10, dy: -10))
        // Going back to the start restores the rect exactly (no accumulation).
        #expect(SetupGeometry.rect(for: move, at: start, within: Self.display) == Self.rect)

        let resize = SetupGeometry.Gesture.resize(.maxXmidY, from: Self.rect, start: CGPoint(x: 500, y: 250))
        #expect(SetupGeometry.rect(for: resize, at: CGPoint(x: 560, y: 999), within: Self.display)
            == CGRect(x: 100, y: 100, width: 460, height: 300))

        let reselect = SetupGeometry.Gesture.reselect(anchor: CGPoint(x: 600, y: 500))
        #expect(SetupGeometry.rect(for: reselect, at: CGPoint(x: 601, y: 501), within: Self.display) == nil)
        #expect(SetupGeometry.rect(for: reselect, at: CGPoint(x: 700, y: 600), within: Self.display)
            == CGRect(x: 600, y: 500, width: 100, height: 100))
    }

    /// Review round 1 #4: a locked W target draws no handles, so a press
    /// just outside it — even within a hidden handle's hit ring — starts a
    /// new rect, and one just inside does nothing.
    @Test func aLockedTargetHasNoHiddenHandles() {
        for handle in SetupGeometry.Handle.allCases {
            let p = AnnotationGeometry.handlePoint(handle, in: Self.rect)
            let outward = CGVector(
                dx: handle.movesMinX ? -5 : (handle.movesMaxX ? 5 : 0),
                dy: handle.movesMinY ? -5 : (handle.movesMaxY ? 5 : 0)
            )
            let outside = CGPoint(x: p.x + outward.dx, y: p.y + outward.dy)
            let inside = CGPoint(x: p.x - outward.dx, y: p.y - outward.dy)
            #expect(SetupGeometry.hit(at: outside, rect: Self.rect, handles: false) == .outside)
            #expect(SetupGeometry.gesture(at: outside, rect: Self.rect, editable: false) == .reselect(anchor: outside))
            #expect(SetupGeometry.hit(at: inside, rect: Self.rect, handles: false) == .inside)
            #expect(SetupGeometry.gesture(at: inside, rect: Self.rect, editable: false) == nil)
        }
        // The reviewer's probe point.
        let probe = CGPoint(x: 95, y: 100)
        #expect(SetupGeometry.gesture(at: probe, rect: Self.rect, editable: false) == .reselect(anchor: probe))
    }

    // MARK: - Display resolution (review round 1 #3)

    private static let primaryDisplay = SetupGeometry.Display(id: 1, frame: display)
    private static let secondaryDisplay = SetupGeometry.Display(id: 2, frame: secondary)

    @Test func theTargetsOwnDisplayWins() {
        let target = RecordingTarget.area(globalRect: CGRect(x: 100, y: 100, width: 200, height: 200), displayID: 2)
        #expect(SetupGeometry.display(for: target, among: [Self.primaryDisplay, Self.secondaryDisplay]) == Self.secondaryDisplay)
    }

    /// Display 3 was unplugged: the screen showing most of the target takes
    /// over — frame *and* ID, never the dead ID.
    @Test func aRemovedDisplayFallsBackToTheScreenShowingMostOfTheTarget() {
        let target = RecordingTarget.area(globalRect: CGRect(x: 1600, y: 300, width: 300, height: 300), displayID: 3)
        #expect(SetupGeometry.display(for: target, among: [Self.primaryDisplay, Self.secondaryDisplay]) == Self.secondaryDisplay)
        let offEverything = RecordingTarget.area(globalRect: CGRect(x: 9000, y: 0, width: 300, height: 300), displayID: 3)
        #expect(SetupGeometry.display(for: offEverything, among: [Self.primaryDisplay, Self.secondaryDisplay]) == Self.primaryDisplay)
        #expect(SetupGeometry.display(for: offEverything, among: []) == nil)
    }

    // MARK: - Desired target (review round 1 #1–#3)

    private func session(_ target: RecordingTarget) -> RecordingSession {
        RecordingSession(target: target, countdownSeconds: 0)
    }

    /// A 1 × 1 pt screenshot handed over by R becomes a minimum-size rect.
    @Test func aTinyIncomingAreaIsGrownToTheMinimum() {
        let tiny = RecordingTarget.area(globalRect: CGRect(x: 500, y: 500, width: 1, height: 1), displayID: 1)
        #expect(SetupGeometry.desiredTarget(for: session(tiny), hovered: nil, display: Self.primaryDisplay)
            == .area(globalRect: CGRect(x: 500, y: 500, width: Self.minimum.width, height: Self.minimum.height), displayID: 1))
    }

    @Test func anOverhangingIncomingAreaIsMovedOntoTheDisplay() {
        let overhang = RecordingTarget.area(globalRect: CGRect(x: 1300, y: 800, width: 300, height: 200), displayID: 1)
        #expect(SetupGeometry.desiredTarget(for: session(overhang), hovered: nil, display: Self.primaryDisplay)
            == .area(globalRect: CGRect(x: 1140, y: 700, width: 300, height: 200), displayID: 1))
    }

    @Test func aValidAreaIsLeftAsItIs() {
        let fine = RecordingTarget.area(globalRect: CGRect(x: 100, y: 100, width: 300, height: 200), displayID: 1)
        #expect(SetupGeometry.desiredTarget(for: session(fine), hovered: nil, display: Self.primaryDisplay) == fine)
    }

    @Test func anAreaOnAFallbackDisplayTakesThatDisplaysID() {
        let orphan = RecordingTarget.area(globalRect: CGRect(x: 1600, y: 300, width: 300, height: 300), displayID: 3)
        #expect(SetupGeometry.desiredTarget(for: session(orphan), hovered: nil, display: Self.secondaryDisplay)
            == .area(globalRect: orphan.frame, displayID: 2))
    }

    @Test func aWindowTargetIsLockedInSetup() {
        let window = RecordingTarget.window(windowID: 9, frame: CGRect(x: 1300, y: 800, width: 900, height: 600), displayID: 1)
        #expect(SetupGeometry.desiredTarget(for: session(window), hovered: nil, display: Self.primaryDisplay) == nil)
    }

    @Test func snappingFollowsTheHoveredWindowAsTheCurrentKind() {
        let start = RecordingTarget.area(globalRect: CGRect(x: 100, y: 100, width: 300, height: 200), displayID: 1)
        let window = SnapWindow(windowID: 9, frame: CGRect(x: 1300, y: 100, width: 400, height: 300), appName: "App")
        var s = session(start)
        s.handle(.command(.snap(.area)))
        #expect(SetupGeometry.desiredTarget(for: s, hovered: nil, display: Self.primaryDisplay) == start)
        #expect(SetupGeometry.desiredTarget(for: s, hovered: window, display: Self.primaryDisplay)
            == .area(globalRect: CGRect(x: 1300, y: 100, width: 140, height: 300), displayID: 1))
        s.handle(.command(.snap(.window)))
        #expect(SetupGeometry.desiredTarget(for: s, hovered: window, display: Self.primaryDisplay)
            == .window(windowID: 9, frame: window.frame, displayID: 1))
    }

    @Test func fromTheCountdownOnTheRectIsFinal() {
        let tiny = RecordingTarget.area(globalRect: CGRect(x: 500, y: 500, width: 1, height: 1), displayID: 1)
        var s = RecordingSession(target: tiny, countdownSeconds: 3)
        s.handle(.command(.record))
        #expect(SetupGeometry.desiredTarget(for: s, hovered: nil, display: Self.primaryDisplay) == nil)
        s.handle(.countdownTick); s.handle(.countdownTick); s.handle(.countdownTick)
        #expect(s.phase.isRecording)
        #expect(SetupGeometry.desiredTarget(for: s, hovered: nil, display: Self.primaryDisplay) == nil)
    }

    // MARK: - Size chip & readout

    @Test func sizeReadoutIsInWholePoints() {
        #expect(SetupGeometry.sizeReadout(CGSize(width: 800, height: 450)) == "800 × 450")
        #expect(SetupGeometry.sizeReadout(CGSize(width: 799.6, height: 450.4)) == "800 × 450")
    }

    private static let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let text = CGSize(width: 60, height: 14)

    private static var chipSize: CGSize {
        let padding = OverlayGeometry.sizeChipPadding
        return CGSize(width: text.width + 2 * padding, height: text.height + 2 * padding)
    }

    @Test func sizeChipSitsInsideTheTopLeftCorner() {
        let chip = SetupGeometry.sizeChipFrame(textSize: Self.text, rect: Self.rect, bounds: Self.bounds)
        let inset = SetupGeometry.sizeChipInset
        #expect(chip == CGRect(x: 100 + inset, y: 400 - inset - Self.chipSize.height,
                               width: Self.chipSize.width, height: Self.chipSize.height))
        #expect(Self.rect.contains(chip))
    }

    @Test func aRectTooSmallForTheChipGetsItAbove() {
        let small = CGRect(x: 100, y: 100, width: 50, height: 40)
        let chip = SetupGeometry.sizeChipFrame(textSize: Self.text, rect: small, bounds: Self.bounds)
        #expect(chip.minX == small.minX)
        #expect(chip.minY == small.maxY + SetupGeometry.sizeChipInset)
    }

    @Test func sizeChipStaysOnScreenAboveASmallRectAtTheTop() {
        let small = CGRect(x: 1400, y: 860, width: 40, height: 40)
        let chip = SetupGeometry.sizeChipFrame(textSize: Self.text, rect: small, bounds: Self.bounds)
        #expect(Self.bounds.contains(chip))
    }

    // MARK: - Contrast

    /// WCAG relative luminance of an sRGB grey.
    private static func luminance(_ grey: Double) -> Double {
        grey <= 0.04045 ? grey / 12.92 : pow((grey + 0.055) / 1.055, 2.4)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Increase Contrast: the undimmed rect vs the dimming reaches 3:1 even
    /// on a white screen (non-text contrast); the default dimming is lighter.
    @Test func increaseContrastDimmingReachesThreeToOneOnWhite() {
        let strong = 1 - Double(SetupGeometry.dimmingAlpha(increaseContrast: true))
        #expect(Self.contrast(1, strong) >= 3)
        #expect(SetupGeometry.dimmingAlpha(increaseContrast: false) < SetupGeometry.dimmingAlpha(increaseContrast: true))
    }

    /// The handles' outline carries them on white (≥ 3:1), and goes opaque
    /// with Increase Contrast.
    @Test func handleOutlineIsVisibleOnWhite() {
        let outline = 1 - Double(SetupGeometry.handleOutlineAlpha(increaseContrast: false))
        #expect(Self.contrast(1, outline) >= 3)
        #expect(SetupGeometry.handleOutlineAlpha(increaseContrast: true) == 1)
    }

    // MARK: - Local rect (view space)

    @Test func localRectIsRelativeToTheDisplay() {
        let target = CGRect(x: 1500, y: 300, width: 200, height: 100)
        #expect(SetupGeometry.localRect(of: target, display: Self.secondary) == CGRect(x: 60, y: 100, width: 200, height: 100))
    }

    @Test func localRectIsClippedToTheDisplayAndNilOffIt() {
        let window = CGRect(x: 1300, y: 100, width: 300, height: 200) // spans both displays
        #expect(SetupGeometry.localRect(of: window, display: Self.display) == CGRect(x: 1300, y: 100, width: 140, height: 200))
        #expect(SetupGeometry.localRect(of: CGRect(x: 5000, y: 0, width: 10, height: 10), display: Self.display) == nil)
    }
}
