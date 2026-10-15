import AppKit

/// Pure decision logic for the tool-aware editor cursor: which cursor the
/// canvas should show for a given tool, pointer location, and hover state.
/// The canvas computes the hover with its existing hit-testing helpers and
/// passes it in; turning a kind into an actual NSCursor is ToolCursorFactory's
/// job. Never decide cursors inline in UI code (see docs/ARCHITECTURE.md).
enum CursorGeometry {

    /// What the pointer should look like over the canvas.
    enum CanvasCursorKind: Equatable {
        /// System arrow — outside the image, cursor disabled, or idle select tool.
        case standardArrow
        /// Crosshair + tool badge for a drawing tool.
        case toolCrosshair(EditorTool)
        /// Select tool hovering an annotation body (drag moves it).
        case move
        /// An annotation body is being dragged — the pressed state of `move`.
        case moving
        /// Select tool hovering a rect resize handle.
        case resize(AnnotationGeometry.ResizeHandle)
        /// Select tool hovering an arrow/line endpoint or bend handle.
        case arrowHandle
        /// Text tool (and text editing).
        case iBeam
    }

    /// What the select tool's pointer is currently over, in mouseDown priority
    /// order (handles of the selection win over annotation bodies).
    enum Hover: Equatable {
        case none
        case annotation
        case resizeHandle(AnnotationGeometry.ResizeHandle)
        case arrowHandle
    }

    /// The single cursor decision. `hover` is only meaningful for the select
    /// tool — drawing tools show their crosshair regardless.
    static func cursor(
        tool: EditorTool, isInsideCanvas: Bool, enabled: Bool, hover: Hover
    ) -> CanvasCursorKind {
        guard enabled, isInsideCanvas else { return .standardArrow }
        switch tool {
        case .select:
            switch hover {
            case .none: return .standardArrow
            case .annotation: return .move
            case .resizeHandle(let handle): return .resize(handle)
            case .arrowHandle: return .arrowHandle
            }
        case .text:
            return .iBeam
        case .shape, .arrow, .line, .freehand, .effect, .counter, .crop:
            return .toolCrosshair(tool)
        }
    }

    /// The cursor while the mouse is held after pressing on `kind`: the open
    /// hand closes over a body being moved (HIG Pointers: open hand = "dragging
    /// … is possible", closed hand = dragging). Everything else keeps its
    /// shape for the whole drag.
    static func pressed(_ kind: CanvasCursorKind) -> CanvasCursorKind {
        kind == .move ? .moving : kind
    }

    /// Maps a rect resize handle to the frame-resize cursor position.
    /// Image/view coordinates are unflipped (y grows up), so minY is the
    /// bottom edge.
    static func resizePosition(
        for handle: AnnotationGeometry.ResizeHandle
    ) -> NSCursor.FrameResizePosition {
        switch handle {
        case .minXminY: .bottomLeft
        case .minXmidY: .left
        case .minXmaxY: .topLeft
        case .midXminY: .bottom
        case .midXmaxY: .top
        case .maxXminY: .bottomRight
        case .maxXmidY: .right
        case .maxXmaxY: .topRight
        }
    }
}
