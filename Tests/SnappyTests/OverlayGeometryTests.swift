import AppKit
import Testing
@testable import Snappy

@Suite struct OverlayGeometryTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - Selection edge

    @Test func edgeLinesSitSideBySideJustOutsideTheTarget() {
        let target = CGRect(x: 100, y: 100, width: 50, height: 40)
        let rects = OverlayGeometry.edgeStrokeRects(around: target, within: Self.screen)
        let width = OverlayGeometry.edgeLineWidth
        // Paths run through the middle of each line: the inner line covers
        // [0, w] outside the target, the outer one [w, 2w].
        #expect(rects.inner == target.insetBy(dx: -width / 2, dy: -width / 2))
        #expect(rects.outer == target.insetBy(dx: -1.5 * width, dy: -1.5 * width))
    }

    /// Edges against the screen edge fold inward instead of being clipped:
    /// same order (white against the target, shade outermost), all on screen.
    @Test func edgeFoldsInwardWhereTheTargetTouchesTheScreenEdge() {
        let width = OverlayGeometry.edgeLineWidth
        // Flush with the left and bottom screen edges.
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        let rects = OverlayGeometry.edgeStrokeRects(around: target, within: Self.screen)
        // Left/bottom: outer line covers [0, w], inner [w, 2w] — inside the target.
        #expect(rects.outer.minX == width / 2)
        #expect(rects.inner.minX == 1.5 * width)
        #expect(rects.outer.minY == width / 2)
        // Right/top: still outside, unchanged.
        #expect(rects.inner.maxX == target.maxX + width / 2)
        #expect(rects.outer.maxY == target.maxY + 1.5 * width)
        #expect(Self.screen.contains(rects.outer.insetBy(dx: -width / 2, dy: -width / 2)))
    }

    @Test func wholeDisplayTargetKeepsAllFourSidesOnScreen() {
        let width = OverlayGeometry.edgeLineWidth
        let rects = OverlayGeometry.edgeStrokeRects(around: Self.screen, within: Self.screen)
        // The outer stroke's outside edge is the screen's perimeter.
        #expect(rects.outer.insetBy(dx: -width / 2, dy: -width / 2) == Self.screen)
        #expect(rects.inner == Self.screen.insetBy(dx: 1.5 * width, dy: 1.5 * width))
    }

    /// The point of the two-tone edge: against any *uniform* sRGB backdrop,
    /// the white line or the shade line reaches 3:1 (WCAG non-text contrast).
    /// Sampled over the sRGB cube, plus the window picker's 25 % dimming on
    /// top. A calculation for flat colour, not a claim about busy content.
    @Test(arguments: [0.0, 0.25])
    func twoToneEdgeReachesThreeToOneOnAnyBackdrop(dimming: Double) {
        let shade = Double(OverlayGeometry.edgeShadeAlpha)
        var worst = Double.infinity
        let steps = 16
        for r in 0...steps {
            for g in 0...steps {
                for b in 0...steps {
                    let raw = [r, g, b].map { Double($0) / Double(steps) }
                    let backdrop = raw.map { $0 * (1 - dimming) }
                    let shadeLine = backdrop.map { $0 * (1 - shade) }
                    let best = max(
                        Contrast.ratio([1, 1, 1], backdrop),
                        Contrast.ratio(shadeLine, backdrop)
                    )
                    worst = min(worst, best)
                }
            }
        }
        #expect(worst >= 3)
    }

    @Test func aLoneWhiteLineVanishesOnWhite() {
        // Regression guard for the old 1 pt white border: 1:1 on white.
        #expect(Contrast.ratio([1, 1, 1], [1, 1, 1]) == 1)
    }

    // MARK: - Size readout

    @Test func readoutIsInPointsOfTheCapturedPixels() {
        #expect(OverlayGeometry.sizeReadout(capturedPixels: CGSize(width: 600, height: 400), scale: 2) == "300 × 200")
        #expect(OverlayGeometry.sizeReadout(capturedPixels: CGSize(width: 600, height: 400), scale: 1) == "600 × 400")
    }

    @Test func readoutKeepsHalfPointsOfOddPixelCounts() {
        // 301 × 199 px at 2× is 150.5 × 99.5 pt; the old Int() said 150 × 99.
        #expect(OverlayGeometry.sizeReadout(capturedPixels: CGSize(width: 301, height: 199), scale: 2) == "150.5 × 99.5")
    }

    @Test func readoutAbsorbsADerivedScaleAHairOffTwo() {
        // SCK rounding can make the derived scale 1.9997; no "299.9549…".
        #expect(OverlayGeometry.sizeReadout(capturedPixels: CGSize(width: 600, height: 400), scale: 1.9997) == "300 × 200")
    }

    // MARK: - Chip fill

    @Test func chipScrimIsOpaqueUnderReduceTransparency() {
        #expect(OverlayGeometry.chipFill(reduceTransparency: true).alpha == 1)
        #expect(OverlayGeometry.chipFill(reduceTransparency: false).alpha == 0.7)
        // The opaque grey keeps the translucent scrim's worst-case 8.5:1.
        let grey = Double(OverlayGeometry.chipFill(reduceTransparency: true).white)
        #expect(Contrast.ratio([1, 1, 1], [grey, grey, grey]) >= 8.5)
    }

    // MARK: - Cancel keys

    @Test func escAndBareQCancel() {
        #expect(OverlayKeys.isCancel(keyCode: 53, characters: "\u{1B}", flags: []))
        #expect(OverlayKeys.isCancel(keyCode: 12, characters: "q", flags: []))
        #expect(OverlayKeys.isCancel(keyCode: 12, characters: "Q", flags: [.shift]))
        #expect(OverlayKeys.isCancel(keyCode: 12, characters: "q", flags: [.capsLock]))
    }

    @Test func pinsAndThePreviewPanelCloseOnTheSameKeys() {
        // Pins and the preview panel close via `OverlayKeys.isCancel`; the
        // pin's advertised close key must stay the Q it matches.
        #expect(PinAction.close.shortcutKey == "q")
        #expect(PinAction.close.toolTip.hasSuffix("(Q)"))
    }

    // MARK: - Tracking areas

    @Test func noTrackingAreaCombinesActiveAlwaysWithCursorUpdate() {
        // NSTrackingArea.h: .activeAlways is "Not supported for NSTrackingCursorUpdate".
        for options in [OverlayTracking.pointer, OverlayTracking.cursor] {
            #expect(!(options.contains(.activeAlways) && options.contains(.cursorUpdate)))
        }
    }

    @Test func pointerTrackingWorksWithoutActivationAndCursorTrackingUpdatesTheCursor() {
        #expect(OverlayTracking.pointer.isSuperset(of: [.activeAlways, .mouseMoved]))
        #expect(OverlayTracking.cursor.isSuperset(of: [.activeInKeyWindow, .cursorUpdate]))
    }

    @Test func modifiedQAndOtherKeysDoNotCancel() {
        #expect(!OverlayKeys.isCancel(keyCode: 12, characters: "q", flags: [.command]))
        #expect(!OverlayKeys.isCancel(keyCode: 12, characters: "q", flags: [.option]))
        #expect(!OverlayKeys.isCancel(keyCode: 12, characters: "q", flags: [.control]))
        #expect(!OverlayKeys.isCancel(keyCode: 12, characters: "Q", flags: [.command, .shift]))
        #expect(!OverlayKeys.isCancel(keyCode: 0, characters: "a", flags: []))
    }

    @Test func readoutSurvivesAZeroScale() {
        #expect(OverlayGeometry.sizeReadout(capturedPixels: CGSize(width: 10, height: 10), scale: 0) == "0 × 0")
    }

    // MARK: - Size chip

    private static let chipText = CGSize(width: 60, height: 14)

    @Test func sizeChipSitsBelowTheSelectionRightAligned() {
        let selection = CGRect(x: 200, y: 300, width: 300, height: 200)
        let chip = OverlayGeometry.sizeChipFrame(textSize: Self.chipText, selection: selection, bounds: Self.screen)
        let padding = OverlayGeometry.sizeChipPadding
        #expect(chip.size == CGSize(width: 60 + 2 * padding, height: 14 + 2 * padding))
        #expect(chip.maxX == selection.maxX)
        // Clear of the two-tone edge (2 pt) plus the gap.
        #expect(chip.maxY == selection.minY - 2 * OverlayGeometry.edgeLineWidth - OverlayGeometry.sizeChipGap)
    }

    @Test func sizeChipTucksInsideWhenThereIsNoRoomBelow() {
        let selection = CGRect(x: 200, y: 10, width: 300, height: 200)
        let chip = OverlayGeometry.sizeChipFrame(textSize: Self.chipText, selection: selection, bounds: Self.screen)
        #expect(chip.minY == selection.minY)
        #expect(Self.screen.contains(chip))
    }

    @Test func sizeChipStaysOnScreenForATinySelectionAtTheLeftEdge() {
        let selection = CGRect(x: 0, y: 0, width: 5, height: 5)
        let chip = OverlayGeometry.sizeChipFrame(textSize: Self.chipText, selection: selection, bounds: Self.screen)
        #expect(chip.minX == 0)
        #expect(Self.screen.contains(chip))
    }

    // MARK: - Title chip

    @Test func titleChipIsCentredAboveTheWindow() throws {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let chip = try #require(OverlayGeometry.titleChipFrame(textSize: Self.chipText, window: window, bounds: Self.screen))
        #expect(chip.midX == window.midX)
        #expect(chip.minY == window.maxY + 2 * OverlayGeometry.edgeLineWidth + OverlayGeometry.titleChipGap)
    }

    @Test func titleChipDropsOverAMaximisedWindowsTop() throws {
        let window = Self.screen
        let chip = try #require(OverlayGeometry.titleChipFrame(textSize: Self.chipText, window: window, bounds: Self.screen))
        #expect(chip.maxY == Self.screen.maxY)
        #expect(Self.screen.contains(chip))
    }

    @Test func titleChipCentresOnTheVisiblePartOfAWindowHangingOffScreen() throws {
        // A window half off the left edge: the old code centred the chip on
        // the whole window, i.e. on x = 0, half clipped.
        let window = CGRect(x: -200, y: 100, width: 400, height: 300)
        let chip = try #require(OverlayGeometry.titleChipFrame(textSize: Self.chipText, window: window, bounds: Self.screen))
        #expect(chip.midX == 100)
        #expect(Self.screen.contains(chip))
    }

    @Test func titleChipIsClampedAtTheRightEdge() throws {
        let window = CGRect(x: 990, y: 100, width: 400, height: 300)
        let chip = try #require(OverlayGeometry.titleChipFrame(textSize: Self.chipText, window: window, bounds: Self.screen))
        #expect(chip.maxX == Self.screen.maxX)
    }

    @Test func noTitleChipForAWindowOnAnotherScreen() {
        let window = CGRect(x: 2000, y: 100, width: 400, height: 300)
        #expect(OverlayGeometry.titleChipFrame(textSize: Self.chipText, window: window, bounds: Self.screen) == nil)
    }

    @Test func clampingPinsAnOversizedFrameToTheBottomLeading() {
        let frame = CGRect(x: 50, y: 50, width: 2000, height: 2000)
        #expect(OverlayGeometry.clamped(frame, into: Self.screen).origin == .zero)
    }
}

/// WCAG 2 relative luminance and contrast ratio for sRGB components in 0…1.
private enum Contrast {
    static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ a: [Double], _ b: [Double]) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
