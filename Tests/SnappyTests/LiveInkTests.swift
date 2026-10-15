import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite("LiveInk model")
struct LiveInkTests {
    private static let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
    private static let area = RecordingTarget.area(globalRect: rect, displayID: 1)
    private static let window = RecordingTarget.window(windowID: 42, frame: rect, displayID: 1)
    private static let style = InkStyle(color: .blue, width: .thin, fading: false)
    private static let fadingStyle = InkStyle(color: .blue, width: .thin, fading: true)

    private func model(_ target: RecordingTarget = area, fadeDelay: TimeInterval = 3) -> LiveInk {
        var ink = LiveInk(fadeDelay: fadeDelay)
        ink.setTarget(target)
        return ink
    }

    /// Draws one finished stroke from `from` to `to` (global points).
    private func draw(
        _ ink: inout LiveInk, _ tool: InkTool = .box, from: CGPoint = CGPoint(x: 150, y: 150),
        to: CGPoint = CGPoint(x: 250, y: 220), style: InkStyle = style, capturing: Bool = false, at time: TimeInterval = 0
    ) {
        ink.beginStroke(tool: tool, at: from, style: style, isCapturing: capturing)
        ink.extendStroke(to: to)
        ink.endStroke(at: time)
    }

    // MARK: - Fading

    @Test func fadeCurveHoldsForTheDelayThenFadesOut() {
        #expect(LiveInk.fadeAlpha(age: 0, delay: 3) == 1)
        #expect(LiveInk.fadeAlpha(age: 3, delay: 3) == 1)
        #expect(abs(LiveInk.fadeAlpha(age: 3 + LiveInk.fadeDuration / 2, delay: 3) - 0.5) < 0.0001)
        #expect(LiveInk.fadeAlpha(age: 3 + LiveInk.fadeDuration, delay: 3) == 0)
        #expect(LiveInk.fadeAlpha(age: 60, delay: 3) == 0)
        // A clock that runs a little behind (frame decorated before commit) is opaque.
        #expect(LiveInk.fadeAlpha(age: -1, delay: 3) == 1)
    }

    @Test func onlyRecordedStrokesWithFadingOnFade() throws {
        var ink = model()
        draw(&ink, style: Self.fadingStyle, capturing: false)  // setup: permanent even with fading on
        draw(&ink, style: Self.style, capturing: true)         // recorded, fading off
        draw(&ink, style: Self.fadingStyle, capturing: true)   // recorded, fading on
        #expect(ink.strokes.map(\.isSetup) == [true, false, false])
        #expect(ink.strokes.map(\.fades) == [false, false, true])
        let later: TimeInterval = 100
        #expect(ink.strokes.map { ink.alpha(of: $0, at: later) } == [1, 1, 0])
    }

    @Test func fadeCountsFromMouseUpNotMouseDown() throws {
        var ink = model(fadeDelay: 1)
        ink.beginStroke(tool: .pen, at: CGPoint(x: 150, y: 150), style: Self.fadingStyle, isCapturing: true)
        ink.extendStroke(to: CGPoint(x: 200, y: 200))
        ink.endStroke(at: 10)
        let stroke = try #require(ink.strokes.first)
        #expect(stroke.createdAt == 10)
        #expect(ink.alpha(of: stroke, at: 10.9) == 1)
    }

    @Test func pendingFadesAndPruningDropExpiredStrokesFromTheHistory() {
        var ink = model(fadeDelay: 1)
        draw(&ink, capturing: false, at: 0)                          // permanent
        draw(&ink, style: Self.fadingStyle, capturing: true, at: 0)  // fades
        #expect(ink.nextFadeRedraw(at: 0.25) == 0.75) // sleeps through the hold
        #expect(ink.nextFadeRedraw(at: 1.2) == 0)     // fading: every frame
        #expect(ink.nextFadeRedraw(at: 9) == 0) // expired, not yet pruned: tick now
        let prunedEarly = ink.pruneExpired(at: 1.2)
        #expect(!prunedEarly) // still visible
        let result1 = ink.pruneExpired(at: 2)
        #expect(result1)
        #expect(ink.strokes.count == 1)
        #expect(ink.nextFadeRedraw(at: 2) == nil)
        // The faded stroke's step is gone: one undo removes the permanent stroke.
        let result2 = ink.undo(at: 0)
        #expect(result2)
        #expect(ink.strokes.isEmpty)
        #expect(!ink.canUndo)
    }

    @Test func anExpiredStrokeOnlyInTheRedoStackIsDropped() {
        var ink = model(fadeDelay: 1)
        draw(&ink, style: Self.fadingStyle, capturing: true, at: 0)
        let undone = ink.undo(at: 0.5)
        #expect(undone)
        #expect(ink.canRedo)
        // It would have faded by now: redo has nothing visible to bring back.
        let redone = ink.redo(at: 5)
        #expect(!redone)
        #expect(ink.strokes.isEmpty)
        #expect(!ink.canRedo)
        #expect(!ink.canUndo)
    }

    /// Rev-T3 round 1 #1: a fading stroke cleared before it faded must not
    /// come back as an invisible undo step after the fade timer stopped.
    @Test func anExpiredStrokeOnlyInTheUndoHistoryIsDroppedAfterAClear() {
        var ink = model(fadeDelay: 1)
        draw(&ink, style: Self.fadingStyle, capturing: true, at: 0)  // A, fades
        let cleared = ink.clear(at: 0.5)
        #expect(cleared)
        #expect(ink.nextFadeRedraw(at: 0.5) == nil) // the timer stops: A is only in history
        draw(&ink, .oval, style: Self.style, capturing: true, at: 1) // B, permanent

        let first = ink.undo(at: 5)  // removes B
        #expect(first)
        #expect(ink.strokes.isEmpty)
        let second = ink.undo(at: 5) // would restore only the expired A
        #expect(!second)
        #expect(ink.strokes.isEmpty)
        #expect(!ink.canUndo)
        // Redo still brings B back.
        let redone = ink.redo(at: 5)
        #expect(redone)
        #expect(ink.strokes.map(\.tool) == [.oval])
    }

    @Test func pruningReportsAHistoryOnlyChange() {
        var ink = model(fadeDelay: 1)
        draw(&ink, style: Self.fadingStyle, capturing: true, at: 0)
        ink.clear(at: 0.5)
        let pruned = ink.pruneExpired(at: 5)
        #expect(pruned)
        #expect(!ink.canUndo)
        let again = ink.pruneExpired(at: 6)
        #expect(!again)
    }

    // MARK: - Drawing

    @Test func penThinsPointsCloserThanTheSampleDistance() throws {
        var ink = model()
        ink.beginStroke(tool: .pen, at: CGPoint(x: 150, y: 150), style: Self.style, isCapturing: false)
        ink.extendStroke(to: CGPoint(x: 150.5, y: 150))  // too close: dropped
        ink.extendStroke(to: CGPoint(x: 160, y: 150))
        ink.extendStroke(to: CGPoint(x: 170, y: 155))
        #expect(ink.draft?.points.count == 3)
        let result6 = ink.endStroke(at: 0)
        #expect(result6)
        #expect(ink.strokes.first?.points.count == 3)
    }

    @Test func twoPointToolsKeepStartAndCurrentEnd() {
        var ink = model()
        ink.beginStroke(tool: .arrow, at: CGPoint(x: 150, y: 150), style: Self.style, isCapturing: false)
        ink.extendStroke(to: CGPoint(x: 160, y: 160))
        ink.extendStroke(to: CGPoint(x: 300, y: 250))
        #expect(ink.draft?.points == [CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250)])
    }

    @Test func aClickWithoutADragDrawsNothing() {
        var ink = model()
        ink.beginStroke(tool: .box, at: CGPoint(x: 150, y: 150), style: Self.style, isCapturing: false)
        let result7 = ink.endStroke(at: 0)
        #expect(!result7)
        // A flat box (no height) is not a drawing either.
        draw(&ink, .box, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 151))
        #expect(ink.strokes.isEmpty)
        #expect(ink.draft == nil)
        #expect(!ink.canUndo)
    }

    @Test func strokeTakesStyleAtMouseDown() throws {
        var ink = model()
        draw(&ink, style: InkStyle(color: .green, width: .thick, fading: false))
        let stroke = try #require(ink.strokes.first)
        #expect(stroke.color == .green)
        #expect(stroke.width == .thick)
    }

    // MARK: - Undo / redo / clear

    @Test func undoRedoAndClearAreOneStepEach() {
        var ink = model()
        draw(&ink, .box)
        draw(&ink, .oval)
        #expect(ink.strokes.map(\.tool) == [.box, .oval])
        let result8 = ink.undo(at: 0)
        #expect(result8)
        #expect(ink.strokes.map(\.tool) == [.box])
        let result9 = ink.redo(at: 0)
        #expect(result9)
        #expect(ink.strokes.map(\.tool) == [.box, .oval])

        let result10 = ink.clear(at: 0)

        #expect(result10)
        #expect(ink.strokes.isEmpty)
        let clearedAgain = ink.clear(at: 0)
        #expect(!clearedAgain) // nothing left: no extra undo step
        let result11 = ink.undo(at: 0)
        #expect(result11)
        #expect(ink.strokes.map(\.tool) == [.box, .oval])
    }

    @Test func clearRemovesSetupAndRecordedStrokesAlike() {
        var ink = model()
        draw(&ink, capturing: false)
        draw(&ink, capturing: true)
        ink.clear(at: 0)
        #expect(ink.strokes.isEmpty)
    }

    @Test func aNewStrokeDropsTheRedoHistory() {
        var ink = model()
        draw(&ink, .box)
        ink.undo(at: 0)
        draw(&ink, .arrow)
        let result12 = ink.redo(at: 0)
        #expect(!result12)
        #expect(ink.strokes.map(\.tool) == [.arrow])
    }

    @Test func undoWithNothingToUndoIsANoOp() {
        var ink = model()
        let result13 = ink.undo(at: 0)
        #expect(!result13)
        let result14 = ink.redo(at: 0)
        #expect(!result14)
    }

    // MARK: - Clipping

    @Test func strokesOutsideTheTargetAreHiddenNotDeleted() {
        var ink = model()
        draw(&ink, .box, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 200, y: 200))
        #expect(ink.scene.renderItems(time: 0, targetFrame: Self.rect).count == 1)

        // The rect moves away: hidden, still in the model.
        let elsewhere = CGRect(x: 600, y: 600, width: 200, height: 200)
        ink.setTarget(.area(globalRect: elsewhere, displayID: 1))
        #expect(ink.scene.renderItems(time: 0, targetFrame: elsewhere).isEmpty)
        #expect(ink.strokes.count == 1)

        // Back over it: visible again, at the same screen position (Q16).
        ink.setTarget(Self.area)
        let items = ink.scene.renderItems(time: 0, targetFrame: Self.rect)
        #expect(items.map(\.annotation.boundingRect) == [CGRect(x: 150, y: 150, width: 50, height: 50)])
    }

    @Test func aStrokePartlyInsideTheTargetIsKept() {
        var ink = model()
        draw(&ink, .box, from: CGPoint(x: 450, y: 350), to: CGPoint(x: 700, y: 700))
        #expect(ink.scene.renderItems(time: 0, targetFrame: Self.rect).count == 1)
    }

    // MARK: - Anchoring

    @Test func areaStrokesAreScreenAnchored() throws {
        var ink = model(Self.area)
        draw(&ink, .arrow, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 250))
        #expect(ink.strokes.first?.anchor == .screen)
        #expect(ink.strokes.first?.points == [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 250)])
    }

    @Test func windowStrokesFollowTheWindow() throws {
        var ink = model(Self.window)
        draw(&ink, .arrow, from: CGPoint(x: 150, y: 350), to: CGPoint(x: 250, y: 250))
        let stroke = try #require(ink.strokes.first)
        #expect(stroke.anchor == .window(42))
        // Offsets from the window's top-left (minX 100, maxY 400).
        #expect(stroke.points == [CGPoint(x: 50, y: -50), CGPoint(x: 150, y: -150)])

        // The window moves (T2 → coordinator → session.target).
        let moved = Self.rect.offsetBy(dx: 300, dy: -40)
        ink.setTarget(Self.window.withFrame(moved))
        let arrow = try #require(ink.scene.renderItems(time: 0, targetFrame: moved).first?.annotation)
        guard case .arrow(let resolved) = arrow else { Issue.record("not an arrow"); return }
        #expect(resolved.tail == CGPoint(x: 450, y: 310))
        #expect(resolved.head == CGPoint(x: 550, y: 210))
    }

    @Test func aResizeKeepsWindowStrokesAtTheTopLeft() throws {
        var ink = model(Self.window)
        draw(&ink, .box, from: CGPoint(x: 110, y: 390), to: CGPoint(x: 130, y: 370))
        // Bottom-right corner dragged: origin moves down, top-left stays.
        let resized = CGRect(x: 100, y: 0, width: 600, height: 400)
        ink.setTarget(Self.window.withFrame(resized))
        let item = try #require(ink.scene.renderItems(time: 0, targetFrame: resized).first)
        #expect(item.annotation.boundingRect == CGRect(x: 110, y: 370, width: 20, height: 20))
    }

    @Test func theFramesTargetFrameWinsForTheTargetWindow() throws {
        // The compositor gets each video frame's own window frame, which may be
        // newer than the model's.
        var ink = model(Self.window)
        draw(&ink, .box, from: CGPoint(x: 110, y: 390), to: CGPoint(x: 130, y: 370))
        let newer = Self.rect.offsetBy(dx: 10, dy: 0)
        let item = try #require(ink.scene.renderItems(time: 0, targetFrame: newer).first)
        #expect(item.annotation.boundingRect == CGRect(x: 120, y: 370, width: 20, height: 20))
    }

    @Test func windowStrokesStayAtTheWindowsLastFrameWhenTheTargetChanges() throws {
        var ink = model(Self.window)
        draw(&ink, .box, from: CGPoint(x: 110, y: 390), to: CGPoint(x: 130, y: 370))
        // S-snap to an area elsewhere on the display, overlapping the old window.
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        ink.setTarget(.area(globalRect: area, displayID: 1))
        #expect(ink.currentAnchor == .screen)
        let item = try #require(ink.scene.renderItems(time: 0, targetFrame: area).first)
        #expect(item.annotation.boundingRect == CGRect(x: 110, y: 370, width: 20, height: 20))
    }

    @Test func strokesForAnUnknownWindowAreSkipped() {
        let stroke = InkStroke(
            id: UUID(), tool: .box, points: [.zero, CGPoint(x: 10, y: -10)], color: .red, width: .thin,
            anchor: .window(7), isSetup: true, fades: false, createdAt: 0
        )
        let scene = InkScene(strokes: [stroke], windowFrames: [:], targetWindowID: nil, fadeDelay: 3)
        #expect(scene.renderItems(time: 0, targetFrame: Self.rect).isEmpty)
    }

    // MARK: - Rendering input

    @Test func toolsMapToTheEditorsAnnotations() throws {
        func annotation(_ tool: InkTool) -> Annotation? {
            let stroke = InkStroke(
                id: UUID(), tool: tool, points: [], color: .yellow, width: .medium,
                anchor: .screen, isSetup: true, fades: false, createdAt: 0
            )
            return InkScene.annotation(for: stroke, points: [CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10)])
        }
        guard case .freehand(let pen) = annotation(.pen) else { Issue.record("pen"); return }
        #expect(pen.style.strokeWidth == InkWidth.medium.points)
        #expect(pen.style.strokeColor == InkColorPreset.yellow.color)
        guard case .freehand(let highlighter) = annotation(.highlighter) else { Issue.record("highlighter"); return }
        #expect(highlighter.style.strokeWidth == InkWidth.thick.points) // always thick
        guard case .arrow(let arrow) = annotation(.arrow) else { Issue.record("arrow"); return }
        #expect(arrow.tail == CGPoint(x: 30, y: 40) && arrow.head == CGPoint(x: 10, y: 10) && arrow.kind == .arrow)
        guard case .shape(let oval) = annotation(.oval) else { Issue.record("oval"); return }
        #expect(oval.kind == .oval && oval.rect == CGRect(x: 10, y: 10, width: 20, height: 30))
        guard case .shape(let box) = annotation(.box) else { Issue.record("box"); return }
        #expect(box.kind == .rectangle && !box.style.hasFill)
        let empty = InkStroke(
            id: UUID(), tool: .pen, points: [], color: .red, width: .thin, anchor: .screen, isSetup: true, fades: false
        )
        #expect(InkScene.annotation(for: empty, points: []) == nil)
    }

    @Test func highlighterIsFortyPercentAndFadesMultiply() throws {
        var ink = model(fadeDelay: 1)
        draw(&ink, .highlighter, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 150),
             style: Self.fadingStyle, capturing: true, at: 0)
        let opaque = try #require(ink.scene.renderItems(time: 0.5, targetFrame: Self.rect).first)
        #expect(abs(opaque.alpha - 0.4) < 0.0001)
        let halfway = try #require(ink.scene.renderItems(time: 1 + LiveInk.fadeDuration / 2, targetFrame: Self.rect).first)
        #expect(abs(halfway.alpha - 0.2) < 0.0001)
        #expect(ink.scene.renderItems(time: 5, targetFrame: Self.rect).isEmpty)
    }

    // MARK: - Magic Pen

    private func drawMagicPen(
        _ ink: inout LiveInk, points: [CGPoint] = [CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 180), CGPoint(x: 260, y: 160)],
        style: InkStyle = InkStyle(color: .blue, width: .thin, fading: false, magicPenWidth: .medium), at time: TimeInterval = 0
    ) {
        ink.beginMagicPenStroke(at: points[0], style: style)
        for point in points.dropFirst() { ink.extendStroke(to: point) }
        ink.endStroke(at: time)
    }

    @Test func magicPenStrokesAlwaysFadeAndAreNeverSetupInk() throws {
        var ink = model()
        // Fading is off in the style — Magic Pen ink fades anyway.
        drawMagicPen(&ink)
        let stroke = try #require(ink.strokes.first)
        #expect(stroke.isMagicPen && stroke.fades && !stroke.isSetup)
        #expect(stroke.tool == .pen)
        #expect(stroke.width == .medium) // the Magic Pen width, not the line width (thin)
        #expect(ink.setupSnapshot.strokes.isEmpty, "never restored by Retake")
    }

    @Test func magicPenFadesWithTheSettingsDelayThenOverPointSixSeconds() throws {
        var ink = model(fadeDelay: 2)
        drawMagicPen(&ink, at: 10)
        let stroke = try #require(ink.strokes.first)
        #expect(ink.alpha(of: stroke, at: 12) == 1)
        #expect(abs(ink.alpha(of: stroke, at: 12 + LiveInk.fadeDuration / 2) - 0.5) < 0.0001)
        #expect(ink.alpha(of: stroke, at: 12 + LiveInk.fadeDuration) < 1e-9)
        #expect(ink.alpha(of: stroke, at: 13) == 0)
        #expect(ink.nextFadeRedraw(at: 10) == 2)
        let pruned = ink.pruneExpired(at: 13)
        #expect(pruned)
        #expect(ink.strokes.isEmpty)
    }

    @Test func magicPenIsEightyFivePercentInItsOwnColourWidthAndHalo() throws {
        var ink = model(fadeDelay: 1)
        drawMagicPen(&ink, style: InkStyle(color: .green, width: .thin, fading: false, magicPenWidth: .thick))
        let item = try #require(ink.scene.renderItems(time: 0.5, targetFrame: Self.rect).first)
        #expect(abs(item.alpha - MagicPenLook.alpha) < 0.0001)
        #expect(MagicPenLook.alpha == 0.85)
        guard case .freehand(let stroke) = item.annotation else { Issue.record("freehand"); return }
        #expect(stroke.style.strokeColor == MagicPenLook.color)
        #expect(stroke.style.strokeWidth == InkWidth.thick.magicPenPoints)
        guard case .freehand(let halo)? = item.underlay else { Issue.record("halo"); return }
        #expect(halo.points == stroke.points)
        #expect(halo.style.strokeWidth == stroke.style.strokeWidth + MagicPenLook.haloExtraWidth)
        #expect(halo.style.strokeColor.alpha < 0.5)
        #expect(item.paintedBounds.contains(item.annotation.expandedBounds))
        let halfway = try #require(ink.scene.renderItems(time: 1 + LiveInk.fadeDuration / 2, targetFrame: Self.rect).first)
        #expect(abs(halfway.alpha - MagicPenLook.alpha / 2) < 0.0001)
    }

    @Test func magicPenWidthsAreBolderThanTheNormalPen() {
        for width in InkWidth.allCases {
            #expect(width.magicPenPoints > width.points, "\(width)")
        }
        #expect(InkWidth.thin.magicPenPoints < InkWidth.medium.magicPenPoints)
        #expect(InkWidth.medium.magicPenPoints < InkWidth.thick.magicPenPoints)
    }

    @Test func magicPenThinsPointsALittleMoreThanThePen() throws {
        var ink = model()
        let style = InkStyle(color: .red, width: .medium, fading: false)
        ink.beginMagicPenStroke(at: CGPoint(x: 150, y: 150), style: style)
        ink.extendStroke(to: CGPoint(x: 152.5, y: 150)) // < 3 pt: dropped
        ink.extendStroke(to: CGPoint(x: 154, y: 150))   // 4 pt: kept
        ink.endStroke(at: 0)
        #expect(try #require(ink.strokes.first).points.count == 2)
        #expect(MagicPenLook.minSampleDistance > LiveInk.minSampleDistance)
    }

    @Test func otherStrokesHaveNoUnderlay() throws {
        var ink = model()
        draw(&ink, .pen, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220), capturing: true)
        let item = try #require(ink.scene.renderItems(time: 0, targetFrame: Self.rect).first)
        #expect(item.underlay == nil)
        #expect(item.paintedBounds == item.annotation.expandedBounds)
    }

    @Test func magicPenUndoRedoAndClearWork() {
        var ink = model()
        drawMagicPen(&ink)
        drawMagicPen(&ink)
        let undone = ink.undo(at: 0)
        #expect(undone && ink.strokes.count == 1)
        let redone = ink.redo(at: 0)
        #expect(redone && ink.strokes.count == 2)
        let cleared = ink.clear(at: 0)
        #expect(cleared && ink.strokes.isEmpty)
    }

    @Test func magicPenStrokesAnchorToTheWindowLikeOtherInk() throws {
        var ink = model(Self.window)
        drawMagicPen(&ink)
        #expect(try #require(ink.strokes.first).anchor == .window(42))
    }

    @Test func theSceneIncludesTheDraftOnTop() {
        var ink = model()
        draw(&ink, .box)
        ink.beginStroke(tool: .oval, at: CGPoint(x: 160, y: 160), style: Self.style, isCapturing: true)
        ink.extendStroke(to: CGPoint(x: 220, y: 220))
        #expect(ink.scene.strokes.map(\.tool) == [.box, .oval])
        #expect(ink.strokes.count == 1)
        ink.cancelStroke()
        #expect(ink.scene.strokes.map(\.tool) == [.box])
    }

    // MARK: - Retake

    @Test func setupSnapshotHoldsOnlySetupStrokes() {
        var ink = model()
        draw(&ink, .box, capturing: false)
        ink.captureDidBegin()
        draw(&ink, .arrow, capturing: true)
        #expect(ink.setupSnapshot.strokes.map(\.tool) == [.box])
    }

    @Test func setupSnapshotIsFrozenWhenCaptureBegins() {
        var ink = model()
        draw(&ink, .box, capturing: false)
        draw(&ink, .oval, capturing: false)
        ink.captureDidBegin()
        ink.clear(at: 0) // ⌫ while recording
        ink.captureDidBegin() // only the first call counts
        #expect(ink.setupSnapshot.strokes.map(\.tool) == [.box, .oval])
    }

    @Test func setupSnapshotWithoutCaptureIsTheCurrentSetupInk() {
        var ink = model()
        draw(&ink, .box)
        draw(&ink, .oval)
        ink.undo(at: 0)
        #expect(ink.setupSnapshot.strokes.map(\.tool) == [.box])
    }

    @Test func restoringASnapshotBringsBackStrokesAndWindowFrames() throws {
        var ink = model(Self.window)
        draw(&ink, .box, from: CGPoint(x: 110, y: 390), to: CGPoint(x: 130, y: 370))
        let snapshot = ink.setupSnapshot
        #expect(snapshot.windowFrames == [42: Self.rect])

        // Retake: a new session, the snapshot handed back as the opaque protocol.
        let opaque: any LiveInkSetupSnapshot = snapshot
        var restored = LiveInk(fadeDelay: 3, restoring: opaque as? InkSetupSnapshot)
        #expect(restored.strokes == snapshot.strokes)
        #expect(!restored.canUndo) // a fresh history
        restored.setTarget(.area(globalRect: Self.rect, displayID: 1))
        let item = try #require(restored.scene.renderItems(time: 0, targetFrame: Self.rect).first)
        #expect(item.annotation.boundingRect == CGRect(x: 110, y: 370, width: 20, height: 20))
    }

    // MARK: - Focus policy

    @Test func onlyAToolOrTheMagicPenTakesTheMouse() {
        #expect(LiveInkFocus.takesMouse(.tool(.pen)))
        #expect(LiveInkFocus.takesMouse(.magicPen))
        #expect(!LiveInkFocus.takesMouse(.pointer))
        #expect(!LiveInkFocus.takesMouse(.interact))
    }

    @Test func drawModeTakesTheKeyboardAndInteractGivesItBack() {
        typealias F = LiveInkFocus
        #expect(F.change(from: .recording(.interact), to: .recording(.draw(.pen))) == .take)
        #expect(F.change(from: .countdown(remaining: 1), to: .recording(.draw(.pen))) == .take)
        #expect(F.change(from: .recording(.draw(.pen)), to: .recording(.draw(.arrow))) == .keep)
        #expect(F.change(from: .recording(.draw(.pen)), to: .recording(.interact)) == .resign)
        #expect(F.change(from: .countdown(remaining: 1), to: .recording(.interact)) == .resign)
        #expect(F.change(from: .recording(.draw(.pen)), to: .stopping) == .resign)
        #expect(F.change(from: nil, to: .setup(.pointer)) == .keep)
        #expect(F.change(from: .setup(.pointer), to: .setup(.tool(.box))) == .keep)
        #expect(F.change(from: .setup(.pointer), to: .countdown(remaining: 3)) == .keep)
    }

    @Test func magicPenTakesTheKeyboardLikeDrawModeAndKeepsItBetweenThem() {
        typealias F = LiveInkFocus
        let magic = RecordingPhase.recording(.magicPen(resume: nil))
        #expect(F.change(from: .recording(.interact), to: magic) == .take)
        #expect(F.change(from: .recording(.draw(.pen)), to: .recording(.magicPen(resume: .pen))) == .keep)
        #expect(F.change(from: .recording(.magicPen(resume: .pen)), to: .recording(.draw(.pen))) == .keep)
        #expect(F.change(from: magic, to: .recording(.interact)) == .resign)
        #expect(F.change(from: magic, to: .stopping) == .resign)
        #expect(F.change(from: magic, to: .cancelled) == .resign)
    }
}
