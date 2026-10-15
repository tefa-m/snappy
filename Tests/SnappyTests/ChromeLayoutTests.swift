import CoreGraphics
import Testing

@testable import Snappy

@Suite("ChromeLayout")
struct ChromeLayoutTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// The display minus a 24 pt menu bar and a 70 pt Dock.
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 806)
    private let toolbarSize = CGSize(width: 560, height: 36)

    // MARK: - Border

    private let rightDisplay = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    /// The ring's inner edge is the target exactly: no border segment lies
    /// inside the recorded rect.
    private func expectRingHugs(_ target: CGRect, _ geometry: ChromeLayout.BorderGeometry) {
        #expect(geometry.inner == target)
        #expect(geometry.outer == target.insetBy(dx: -ChromeLayout.borderThickness, dy: -ChromeLayout.borderThickness))
    }

    @Test("The border sits outside the target: band + hairline on every side, one window")
    func borderOutside() {
        let target = CGRect(x: 200, y: 300, width: 400, height: 250)
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: true, screenFrames: [display])
        #expect(ChromeLayout.borderThickness == 4)
        expectRingHugs(target, border)
        #expect(border.windowFrames == [border.outer])
    }

    @Test("Area at the display's physical edge: those sides fold inward, the ring stays on screen")
    func borderFoldsAtPhysicalEdge() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: true, screenFrames: [display])
        #expect(border.outer == CGRect(x: 0, y: 0, width: 304, height: 204))
        #expect(border.inner.minX == 4) // the band lies inside the area on the folded sides
        #expect(border.inner.maxX == 300) // and outside it elsewhere
        #expect(border.windowFrames == [border.outer])
        let full = ChromeLayout.border(around: display, foldsAtScreenEdges: true, screenFrames: [display])
        #expect(full.outer == display)
        #expect(full.windowFrames == [display])
    }

    @Test("Area at an edge shared with another display: no fold, the band shows on the neighbour")
    func borderSpillsOntoNeighbour() {
        let target = CGRect(x: 1140, y: 100, width: 300, height: 200) // right edge at x = 1440
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: true, screenFrames: [display, rightDisplay])
        expectRingHugs(target, border)
        #expect(border.windowFrames == [
            CGRect(x: 1136, y: 96, width: 304, height: 208),
            CGRect(x: 1440, y: 96, width: 4, height: 208),
        ])
    }

    @Test("Window spanning two displays: one ring around the whole window, cut into one window per display")
    func borderSpansDisplays() {
        // The review's case: adjacent screens meeting at x = 1440.
        let target = CGRect(x: 1400, y: 100, width: 400, height: 300)
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: false, screenFrames: [display, rightDisplay])
        expectRingHugs(target, border)
        #expect(border.windowFrames == [
            CGRect(x: 1396, y: 96, width: 44, height: 308),
            CGRect(x: 1440, y: 96, width: 364, height: 308),
        ])
        // The windows exactly tile the ring's frame — no edge is redrawn at the cut.
        #expect(border.windowFrames.reduce(CGRect.null) { $0.union($1) } == border.outer)
    }

    @Test("Window partly off screen: never folds — the off-screen edge just isn't shown")
    func borderPartlyOffScreen() {
        let target = CGRect(x: 1300, y: 500, width: 400, height: 300) // past the right edge, no neighbour
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: false, screenFrames: [display])
        expectRingHugs(target, border)
        #expect(border.windowFrames == [CGRect(x: 1296, y: 496, width: 144, height: 308)])
    }

    @Test("Window entirely off screen: the ring keeps its geometry, no window shows it")
    func borderOffScreen() {
        let target = CGRect(x: 4000, y: 100, width: 300, height: 200)
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: false, screenFrames: [display])
        expectRingHugs(target, border)
        #expect(border.windowFrames.isEmpty)
    }

    @Test("Works on a display left of and below the primary (negative origin)")
    func borderNegativeOrigin() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let target = CGRect(x: -1920, y: 100, width: 500, height: 400)
        let border = ChromeLayout.border(around: target, foldsAtScreenEdges: true, screenFrames: [left, display])
        #expect(border.outer.minX == -1920) // physical left edge: folded
        #expect(border.outer.maxX == -1420 + ChromeLayout.borderThickness)
        #expect(border.windowFrames == [border.outer])
    }

    // MARK: - Toolbar

    @Test("The toolbar sits centred under the border, one gap below it")
    func toolbarBelow() {
        let target = CGRect(x: 400, y: 400, width: 600, height: 300)
        let frame = ChromeLayout.toolbarFrame(size: toolbarSize, target: target, visibleFrame: visible)
        #expect(frame.size == toolbarSize)
        #expect(frame.midX == target.midX)
        #expect(frame.maxY == target.minY - ChromeLayout.borderThickness - ChromeLayout.toolbarGap)
    }

    @Test("No room below (the Dock): above the border")
    func toolbarAbove() {
        let target = CGRect(x: 400, y: 90, width: 600, height: 300)
        let frame = ChromeLayout.toolbarFrame(size: toolbarSize, target: target, visibleFrame: visible)
        #expect(frame.minY == target.maxY + ChromeLayout.borderThickness + ChromeLayout.toolbarGap)
        #expect(frame.midX == target.midX)
    }

    @Test("No room above or below: inside the target along its bottom, still on screen")
    func toolbarInside() {
        let frame = ChromeLayout.toolbarFrame(size: toolbarSize, target: display, visibleFrame: visible)
        #expect(visible.contains(frame))
        #expect(frame.minY == visible.minY) // target.minY + gap = 8 is under the Dock → clamped
        let tall = CGRect(x: 100, y: 80, width: 800, height: 790)
        let inside = ChromeLayout.toolbarFrame(size: toolbarSize, target: tall, visibleFrame: visible)
        #expect(inside.minY == tall.minY + ChromeLayout.toolbarGap)
        #expect(tall.contains(inside))
    }

    @Test("Clamped into the visible frame at the left and right edges")
    func toolbarClampedHorizontally() {
        let left = CGRect(x: 0, y: 400, width: 100, height: 100)
        #expect(ChromeLayout.toolbarFrame(size: toolbarSize, target: left, visibleFrame: visible).minX == 0)
        let right = CGRect(x: 1400, y: 400, width: 40, height: 100)
        #expect(ChromeLayout.toolbarFrame(size: toolbarSize, target: right, visibleFrame: visible).maxX == 1440)
    }

    @Test("Wider than the display: starts at its left edge")
    func toolbarWiderThanDisplay() {
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 600)
        let frame = ChromeLayout.toolbarFrame(
            size: toolbarSize, target: CGRect(x: 100, y: 300, width: 100, height: 100), visibleFrame: narrow
        )
        #expect(frame.minX == 0)
    }

    @Test("Every placement stays inside the visible frame")
    func toolbarAlwaysVisible() {
        let targets = [
            CGRect(x: 0, y: 0, width: 50, height: 50),
            CGRect(x: 1390, y: 850, width: 50, height: 50),
            CGRect(x: 700, y: 870, width: 20, height: 30),
            CGRect(x: 10, y: 70, width: 1420, height: 806),
            display,
        ]
        for target in targets {
            let frame = ChromeLayout.toolbarFrame(size: toolbarSize, target: target, visibleFrame: visible)
            #expect(visible.contains(frame), "toolbar \(frame) for \(target)")
        }
    }

    // MARK: - Countdown

    @Test("The disc is 120 pt and centred on a roomy target")
    func countdownFull() {
        let target = CGRect(x: 100, y: 100, width: 800, height: 500)
        let disc = ChromeLayout.countdownDiscFrame(in: target)
        #expect(disc.size == CGSize(width: 120, height: 120))
        #expect(disc.midX == target.midX)
        #expect(disc.midY == target.midY)
        #expect(ChromeLayout.countdownFontSize(diameter: disc.width) == 66)
    }

    @Test("It shrinks to 80 % of a small target's shorter side, never below 56 pt")
    func countdownShrinks() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 100)
        #expect(ChromeLayout.countdownDiscFrame(in: small).width == 80)
        let tiny = CGRect(x: 0, y: 0, width: 30, height: 30)
        let disc = ChromeLayout.countdownDiscFrame(in: tiny)
        #expect(disc.width == ChromeLayout.countdownMinimumDiameter)
        #expect(disc.midX == tiny.midX)
    }

    // MARK: - Display

    @Test("The chrome's screen is the one the target overlaps most")
    func screenByOverlap() {
        let screens = [display, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(ChromeLayout.screenIndex(for: CGRect(x: 100, y: 100, width: 50, height: 50), screenFrames: screens) == 0)
        // A window dragged mostly onto the second display follows it.
        #expect(ChromeLayout.screenIndex(for: CGRect(x: 1400, y: 100, width: 400, height: 50), screenFrames: screens) == 1)
    }

    @Test("Off every screen: the nearest one; no screens: nil")
    func screenFallbacks() {
        let screens = [display, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(ChromeLayout.screenIndex(for: CGRect(x: 4000, y: 0, width: 10, height: 10), screenFrames: screens) == 1)
        #expect(ChromeLayout.screenIndex(for: .zero, screenFrames: []) == nil)
    }
}
