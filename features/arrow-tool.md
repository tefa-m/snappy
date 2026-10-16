# Arrow Tool

## What it is

Milestone M5 (priority P5), beefed up and made bendable in Post-MVP M-D: arrows in the editor. Drag spawns the arrow — mouse-down = tail, the head follows the cursor live via the canvas draft (one undo step on mouse-up).

- Rendered as ONE filled **tapered** polygon (Tefa's explicit "ergonomic" request): thin tail → shaft thickening to **2.0× strokeWidth visible width at the head end** → filled arrowhead (head length **6.0×** strokeWidth, barb half-width 0.45× head length, capped at 45% of the arrow so short arrows shrink proportionally)
- **Rounded edges:** the polygon is stroked with a same-color round-join/round-cap stroke of 0.3× strokeWidth; the polygon half-widths are tuned with that outset subtracted — change them together or visible widths drift
- **Bendable (M-D):** the bend is a scalar **`bow`** — the signed perpendicular offset of the curve midpoint from the chord midpoint (image px). The quadratic Bézier control point is `M + 2·bow·n̂`, so the on-curve midpoint sits exactly `bow` off the chord and `bow == 0` is literally straight. Because the bow is chord-relative (not a stored control point), **endpoint drags preserve the bend** and `offset(by:)` needs no extra work. Clamped to ±0.75× chord length (`withBow`)
- **Curved rendering:** the spine follows the flattened curve (32 segments, arc-length taper); the arrowhead sits on the **end tangent**, so the tip always points where the curve arrives. `bow == 0` short-circuits to the exact straight 7-point polygon (bit-identical to M5)
- Selection shows **three handles**: two round white endpoint handles plus a visually distinct **accent-filled bend handle** at the curve midpoint. Bend drags project the cursor onto the chord normal only (1 degree of freedom) and **snap to perfectly straight** below 4 image px (`ArrowGeometry.snappedBow`); lines have no bend handle
- `Annotation.withRect` is a documented no-op for arrows; whole-arrow moves clamp via the bounding rect (which includes the bulge — analytic quad-Bézier extrema)
- The fill checkbox does not apply to arrows
- All math in pure `ArrowGeometry` + `ArrowAnnotation` helpers, unit-tested (polygon quadrants/taper/scaling, curve midpoint/end-tangent/bounding-rect, bow projection/snap/clamp, curved + straight hit-testing, three-way handle hits, renderer pixel tests straight + curved)

Straight **lines** reuse `ArrowAnnotation` with `kind: .line` and never set `bow` — see [annotations.md](annotations.md).

## Design notes

- **Why a scalar bow, not a control point:** a stored control point would need remapping on every endpoint drag and makes "straight" a floating-point coincidence; the scalar keeps straightness exact (`bow == 0`), survives endpoint edits, and gives the bend drag a guaranteed return-to-straight (the projection is 1-DOF).
- Visible width arithmetic at the head end: polygon 2 × 0.85 + rounding stroke 0.3 = **2.0 × strokeWidth** (was 1.5× before M-D).

## Log

- **2026-07-18** — M5 implemented; two UX feedback rounds applied: shaft thickened toward the head (1.5× at the head end, bumped from 1× after "thicker towards the end"), rounded edges/corners (tail tip, barbs, apex)
- **2026-07-19** — Post-MVP M-D: bigger head (4.5→6.0× length, 0.4→0.45 barb ratio), thicker head-end shaft (visible 1.5→2.0× strokeWidth), scalar-`bow` curve model with third bend handle, snap-to-straight zone, head on the end tangent

- **2026-10-08** — HIG design pass ([review](../docs/design-reviews/editor-canvas.md)): handle hit region 14 → **20 pt** (HIG macOS minimum; visible handles stay 8 pt, overlaps resolve to the nearest handle) — after the Sol review, the outer 7–10 pt ring applies only off the annotation's body, so a short arrow can still be moved by its shaft; the pointer over endpoint and bend handles is the **crosshair** instead of the pointing hand (the HIG's link pointer). Arrow shape unchanged — it is the editor's signature.

## Manual checklist — M5 base ✅ verified (Tefa, 2026-07-18)

- [x] Arrows draw smoothly in every direction, arrowhead points at the head
- [x] Drag spawns at the mouse-down point (tail), head follows the cursor live
- [x] Shaft visibly tapered: thin tail, thickening toward the head
- [x] Edges and corners rounded, not sharp
- [x] Short arrows look proportionate (head shrinks, never swallows the shaft)
- [x] Endpoint handles individually adjustable
- [x] Undo/redo and export behave exactly like the highlight shapes

## Manual checklist — M-D improved arrow (pending Tefa's confirmation)

- [ ] Default arrow visibly beefier than before (bigger head, thicker toward the head)
- [ ] Selected arrow shows three handles; the bend handle is visually distinct
- [ ] Dragging the bend handle curves the arrow smoothly; the head follows the end tangent
- [ ] Dragging the bend back to the chord snaps the arrow perfectly straight
- [ ] Endpoint drags keep the bend; whole-arrow moves keep the shape
- [ ] Undo is one step per gesture (bend drag, endpoint drag, move)
- [ ] Lines are unaffected (two handles, no bend, straight stroke)
- [ ] Export (Copy/Save/Pin) matches the canvas for curved arrows

## Manual checklist — HIG design pass (2026-10-08, unverified)

- [ ] Endpoint and bend handles are easy to grab from a few points away; on a short arrow the nearest handle wins
- [ ] Hovering an arrow/line handle (Select tool) shows the crosshair, not a pointing hand
- [ ] Rect handles of a small rectangle (~30 pt) still resize the intended corner/edge
- [ ] A short arrow (~25 pt) can be moved by dragging its shaft midway between the handles; hover there shows the open hand
