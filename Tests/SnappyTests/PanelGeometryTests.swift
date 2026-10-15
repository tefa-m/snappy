import CoreGraphics
import Testing
@testable import Snappy

@Suite struct PanelGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let panelSize = CGSize(width: 300, height: 200)
    private let gap: CGFloat = 8

    private func panelFrame(anchor: CGRect) -> CGRect {
        let origin = PanelGeometry.panelOrigin(
            panelSize: panelSize,
            anchorRect: anchor,
            screenFrame: screen,
            gap: gap
        )
        return CGRect(origin: origin, size: panelSize)
    }

    @Test func sitsBelowAnchorRightAligned() {
        let anchor = CGRect(x: 400, y: 400, width: 200, height: 150)
        let frame = panelFrame(anchor: anchor)
        #expect(frame.maxX == anchor.maxX)
        #expect(frame.maxY == anchor.minY - gap)
    }

    @Test func flipsAboveWhenNoRoomBelow() {
        let anchor = CGRect(x: 400, y: 0, width: 200, height: 100)
        let frame = panelFrame(anchor: anchor)
        #expect(frame.minY == anchor.maxY + gap)
        #expect(screen.contains(frame))
    }

    @Test func staysOnScreenForAnchorsAtEveryEdgeAndCorner() {
        let anchors = [
            CGRect(x: 0, y: 0, width: 100, height: 100),        // bottom-left
            CGRect(x: 900, y: 0, width: 100, height: 100),      // bottom-right
            CGRect(x: 0, y: 700, width: 100, height: 100),      // top-left
            CGRect(x: 900, y: 700, width: 100, height: 100),    // top-right
            CGRect(x: 450, y: 0, width: 100, height: 100),      // bottom edge
            CGRect(x: 450, y: 700, width: 100, height: 100),    // top edge
            CGRect(x: 0, y: 350, width: 100, height: 100),      // left edge
            CGRect(x: 900, y: 350, width: 100, height: 100),    // right edge
        ]
        for anchor in anchors {
            let frame = panelFrame(anchor: anchor)
            #expect(screen.contains(frame), "panel \(frame) escapes screen for anchor \(anchor)")
        }
    }

    @Test func fullScreenAnchorStillYieldsOnScreenPanel() {
        let frame = panelFrame(anchor: screen)
        #expect(screen.contains(frame))
    }

    @Test func screenWithNonZeroOriginIsRespected() {
        // External display left of the primary.
        let external = CGRect(x: -1200, y: 100, width: 1200, height: 900)
        let anchor = CGRect(x: -1190, y: 110, width: 50, height: 50)
        let origin = PanelGeometry.panelOrigin(
            panelSize: panelSize,
            anchorRect: anchor,
            screenFrame: external,
            gap: gap
        )
        #expect(external.contains(CGRect(origin: origin, size: panelSize)))
    }
}
