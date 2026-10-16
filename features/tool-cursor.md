# Tool-Aware Cursor

## What it is

The editor's pointer shows what a click will do: over the canvas, drawing tools
get a precision crosshair with the tool's toolbar SF Symbol as a small badge
beside it; the text tool gets an I-beam; the select tool upgrades by hover
(move hand over annotation bodies, directional resize cursors over rect
handles, crosshair over arrow/line handles, closed hand while moving).
Switching tools briefly
flashes the tool's name beside the cursor. A settings checkbox ("Show tool
icon next to the pointer", ON by default) disables the whole
feature and restores the plain crosshair/I-beam cursor rects.

## How it works

```
AnnotationCanvasView (tracking area, mouseMoved)
  └─ CursorGeometry.cursor(tool:isInsideCanvas:enabled:hover:)   PURE decision
       └─ CanvasCursorKind → ToolCursorFactory.cursor(for:)      cached NSCursors
```

- **`CursorGeometry`** (pure, unit-tested) is the single decision function:
  disabled or outside the fitted image → standard arrow; `.select` → arrow,
  upgraded by hover (`.annotation` → move, `.resizeHandle` → resize,
  `.arrowHandle` → crosshair); `.text` → I-beam; every other tool → its
  crosshair. It also owns the handle→`NSCursor.FrameResizePosition` mapping
  (unflipped coordinates: minY = bottom).
- **`ToolCursorFactory`** (@MainActor, cached per symbol) builds the crosshair
  cursors: 32×32 image, hotspot dead center (16,16), white-under-black cross,
  and the tool's toolbar symbol (~11 pt bold) at (+9,−9) with eight white
  outline copies plus a soft shadow — readable on light and dark content. The
  symbol/label come from `EditorWindowController.toolSpec(for:)` (the same
  `toolSpecs` the toolbar is built from), so the badge always matches the
  toolbar icon. Resize cursors use
  `NSCursor.frameResize(position:directions: .all)` (macOS 26 target — no
  fallback needed); move → `.openHand` (`.closedHand` while dragging), arrow/line handles → crosshair (no pointing hand anywhere in the editor since the 2026-10-08 design pass).
- **Canvas integration:** one `NSTrackingArea` (`.activeInKeyWindow,
  .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect`) added
  in `updateTrackingAreas()`. `mouseMoved`/`mouseEntered` recompute the kind and
  call `NSCursor.set()` **only when the kind changed**; `mouseExited` restores
  the arrow. Hover reuses the existing hit-test helpers in mouseDown priority
  order (selection handles win over annotation bodies). No recompute during
  drags (the cursor persists) or while the in-place text field is active.
- **One system owns the cursor:** while the setting is ON, `resetCursorRects`
  registers nothing — cursor rects and mouseMoved fighting over the pointer is
  what causes flicker. With the setting OFF, `resetCursorRects` provides
  exactly the pre-M-E behavior (crosshair/I-beam rects). The setting is read
  on every mouseMoved — no notification plumbing; toggling it mid-session
  takes effect on the next pointer move.
- **AppKit re-evaluates the cursor behind our back** — toolbar redraws
  (`selectedItemIdentifier` sync on keyboard tool switches), subview changes
  (the flash label), and rect invalidations all make the window re-decide the
  pointer, and with zero cursor rects registered it lands on the arrow *after*
  `refreshCursor` has set the crosshair; the kind cache then suppressed the
  corrective `set()` until the pointer left and re-entered the canvas. Two
  defenses, both required: the `tool` didSet only calls
  `invalidateCursorRects` when the feature is OFF, and the canvas
  **participates in re-evaluation via `.cursorUpdate`** —
  `cursorUpdate(with:)` drops the kind cache and re-asserts the correct
  cursor (super only when the feature is OFF, so the fallback rects keep
  working). Found via keyboard tool switching; toolbar clicks masked it
  because the pointer re-enters the canvas afterwards.
- **Tool-name flash:** on a real tool change (toolbar click or letter key)
  with the pointer over the image, a small dark HUD label with the tool name
  appears at (+14,−20) from the cursor, fades after 0.8 s (0.25 s fade, token
  invalidates the fade on rapid switches).

## Design decisions

- **Scope (Tefa, 2026-07-19):** the 11 existing tools only — no pan/zoom/
  color-picker/rotation cursors (those features don't exist in Snappy).
- Decision logic is a pure function so the full tool×hover×enabled matrix is
  unit-testable without events or windows (`CursorGeometryTests`).
- `SettingsStore.toolAwareCursorEnabled` defaults to **true** (nil-checked
  read, so absence of the key means ON).
- Diagonal resize cursors come from `NSCursor.frameResize` unconditionally —
  the old `.resizeLeftRight`/`.resizeUpDown` are to-be-deprecated in the
  macOS 26 SDK (plan decision after the macOS 26 retarget).

## History

- **2026-07-19** — Post-MVP M-E: initial implementation (CursorGeometry +
  ToolCursorFactory + canvas tracking area, tool-name flash HUD, settings
  checkbox with cursor-rects fallback).
- **2026-07-19** — Fix (Tefa's manual testing): keyboard tool switches left a
  stuck arrow cursor — the `tool` didSet invalidated cursor rects while the
  feature was ON; the invalidation is now gated on the setting being OFF.
- **2026-10-08** — HIG design pass (review): arrow/line handles show the system **crosshair** (was the pointing hand — the HIG's link pointer); **press feedback** — `CursorGeometry.pressed` closes the open hand while an annotation is moved, and mouse-up re-decides the cursor (it used to stay stale until the next mouse move); every real tool switch is **announced to VoiceOver** (the flash is visual only). Selection-handle hit radius 7 → 10 pt (20 pt target).
- **2026-07-19** — Fix 2 (still reproducible): other re-evaluation triggers
  (toolbar selection redraw, flash-label subview) reset the pointer the same
  way. The canvas now handles `.cursorUpdate` and re-asserts the cursor
  whenever AppKit re-decides it — immune to any invalidation source.

## Manual verification checklist

- [ ] Badge cursor per tool appears only over the fitted image, matches the
      toolbar icon, readable on white and black screenshot areas
- [ ] Select tool hover: move hand over an annotation body, all 8 directional
      resize cursors on a selected rect/oval/effect's handles, crosshair
      over a selected arrow/line's endpoint + bend handles
- [ ] I-beam for the text tool; text editing keeps a sane cursor
- [ ] Standard cursor over the toolbar, settings window, and other UI
- [ ] Tool switch via toolbar click AND letter key flashes the tool name, then
      keeps the icon; rapid switches don't stack labels
- [ ] Letter-key tool switch with the pointer resting over the image updates
      the cursor immediately and it stays correct **without moving the mouse**
      (regression check for the invalidateCursorRects bug)
- [ ] Settings checkbox OFF → exactly the pre-M-E behavior (plain crosshair/
      I-beam), no badge, no flash
- [ ] No cursor flicker while drawing/dragging; cursor persists during a drag

## Manual checklist — HIG design pass (2026-10-08, unverified)

- [ ] Select tool: hover a body → open hand; press and drag → closed hand; release → open hand (or arrow if the pointer left the body) without moving the mouse
- [ ] Draw a rectangle and release with the pointer on its new corner handle → the resize cursor appears without moving the mouse
- [ ] Hover a selected arrow's endpoint / bend handle → crosshair (no pointing hand anywhere in the editor)
- [ ] VoiceOver on (⌘F5): press A, R, T in the editor → VoiceOver speaks "Arrow", "Rectangle", "Text"

