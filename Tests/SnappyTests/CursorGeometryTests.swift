import AppKit
import Testing

@testable import Snappy

@Suite("CursorGeometry")
struct CursorGeometryTests {
    private static let drawingTools: [EditorTool] = [
        .shape(.rectangle), .shape(.oval), .arrow, .line,
        .freehand, .effect(.blur), .effect(.pixelate), .counter, .crop,
    ]

    @Test("Drawing tools get their tool crosshair, text gets the I-beam")
    func toolKindMatrix() {
        for tool in Self.drawingTools {
            #expect(
                CursorGeometry.cursor(tool: tool, isInsideCanvas: true, enabled: true, hover: .none)
                    == .toolCrosshair(tool)
            )
        }
        #expect(
            CursorGeometry.cursor(tool: .text, isInsideCanvas: true, enabled: true, hover: .none)
                == .iBeam
        )
        #expect(
            CursorGeometry.cursor(tool: .select, isInsideCanvas: true, enabled: true, hover: .none)
                == .standardArrow
        )
    }

    @Test("Disabled setting forces the standard arrow for every tool and hover")
    func disabledIsAlwaysStandard() {
        for tool in Self.drawingTools + [.select, .text] {
            #expect(
                CursorGeometry.cursor(tool: tool, isInsideCanvas: true, enabled: false, hover: .none)
                    == .standardArrow
            )
        }
        #expect(
            CursorGeometry.cursor(
                tool: .select, isInsideCanvas: true, enabled: false, hover: .annotation
            ) == .standardArrow
        )
    }

    @Test("Outside the canvas the cursor is always the standard arrow")
    func outsideIsStandard() {
        for tool in Self.drawingTools + [.select, .text] {
            #expect(
                CursorGeometry.cursor(tool: tool, isInsideCanvas: false, enabled: true, hover: .none)
                    == .standardArrow
            )
        }
    }

    @Test("Select-tool hover upgrades: move, directional resize, hand on arrow handles")
    func hoverUpgrades() {
        #expect(
            CursorGeometry.cursor(
                tool: .select, isInsideCanvas: true, enabled: true, hover: .annotation
            ) == .move
        )
        #expect(
            CursorGeometry.cursor(
                tool: .select, isInsideCanvas: true, enabled: true, hover: .resizeHandle(.minXminY)
            ) == .resize(.minXminY)
        )
        #expect(
            CursorGeometry.cursor(
                tool: .select, isInsideCanvas: true, enabled: true, hover: .arrowHandle
            ) == .arrowHandle
        )
    }

    @Test("Hover is ignored for drawing tools")
    func hoverIgnoredForDrawingTools() {
        #expect(
            CursorGeometry.cursor(
                tool: .arrow, isInsideCanvas: true, enabled: true, hover: .annotation
            ) == .toolCrosshair(.arrow)
        )
        #expect(
            CursorGeometry.cursor(
                tool: .text, isInsideCanvas: true, enabled: true, hover: .resizeHandle(.midXmaxY)
            ) == .iBeam
        )
    }

    @Test("Resize handles map to frame-resize positions (y grows up: minY = bottom)")
    func handleAxisMapping() {
        let expected: [(AnnotationGeometry.ResizeHandle, NSCursor.FrameResizePosition)] = [
            (.minXminY, .bottomLeft),
            (.minXmidY, .left),
            (.minXmaxY, .topLeft),
            (.midXminY, .bottom),
            (.midXmaxY, .top),
            (.maxXminY, .bottomRight),
            (.maxXmidY, .right),
            (.maxXmaxY, .topRight),
        ]
        for (handle, position) in expected {
            #expect(CursorGeometry.resizePosition(for: handle) == position)
        }
    }

    @Test("Pressing on a body closes the hand; other cursors keep their shape")
    func pressedCursor() {
        #expect(CursorGeometry.pressed(.move) == .moving)
        #expect(CursorGeometry.pressed(.resize(.maxXmaxY)) == .resize(.maxXmaxY))
        #expect(CursorGeometry.pressed(.arrowHandle) == .arrowHandle)
        #expect(CursorGeometry.pressed(.toolCrosshair(.arrow)) == .toolCrosshair(.arrow))
        #expect(CursorGeometry.pressed(.standardArrow) == .standardArrow)
    }
}
