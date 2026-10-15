import CoreGraphics
import Testing
@testable import Snappy

@Suite("Editor status capsule")
struct EditorStatusTests {
    @Test func zoomIsViewPointsPerImagePoint() {
        // 2× capture, 1200 px wide = 600 pt, shown 600 pt wide → 100 %.
        #expect(EditorStatus.zoomPercent(viewWidth: 600, canvasPixelWidth: 1200, scale: 2) == 100)
        // Shown at half size.
        #expect(EditorStatus.zoomPercent(viewWidth: 300, canvasPixelWidth: 1200, scale: 2) == 50)
        // Small capture upscaled to fit.
        #expect(EditorStatus.zoomPercent(viewWidth: 900, canvasPixelWidth: 400, scale: 1) == 225)
    }

    @Test func degenerateInputsReadAsOriginalSize() {
        #expect(EditorStatus.zoomPercent(viewWidth: 0, canvasPixelWidth: 1200, scale: 2) == 100)
        #expect(EditorStatus.zoomPercent(viewWidth: 600, canvasPixelWidth: 0, scale: 2) == 100)
        #expect(EditorStatus.zoomPercent(viewWidth: 600, canvasPixelWidth: 1200, scale: 0) == 100)
    }

    @Test func textJoinsTitleAndZoom() {
        #expect(EditorStatus.text(title: "Shot 1284 × 806", zoomPercent: 87) == "Shot 1284 × 806 · 87%")
    }
}
