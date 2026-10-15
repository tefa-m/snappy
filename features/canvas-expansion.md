# Auto-Expanding Canvas

## What it is

Post-MVP M-F (spec: Feature 3). Annotations may be drawn, moved, resized, or bent **partially or completely outside** the captured screenshot; the document canvas grows to contain them, filling the newly exposed area with **one clean, uniform background color** detected from the screenshot's perimeter (Shottr-style). No separate "resize canvas" command — expansion happens live during every editing gesture, and the expanded pixels are included in Copy / Save / Pin / reopen-for-edit.

## Design

- **Fully derived canvas rect** (`CanvasGeometry.canvasRect`): `union(imageBounds, each annotation's expandedBounds)`, extended only on the sides that actually overflow, plus configurable `padding` on those sides, rounded out (`.integral`). No stored canvas state and **nothing in undo** — the rect is a pure function of the current annotations, so it grows *and* shrinks automatically (delete/move-back → it contracts). Interior annotations never grow it.
- **Image stays at `(0, 0)`; the canvas rect may have a negative origin.** Re-basing (shifting the image so the canvas origin stays at 0) was rejected: it would mutate every annotation on each expansion tick, breaking the "nothing in undo" and draft-then-commit invariants. Exactly **two** places consume the offset — view↔image conversion (`AnnotationGeometry` `contentRect:` variants) and export translation (`AnnotationRenderer.flatten(…canvasRect:…)`).
- **`Annotation.expandedBounds`** feeds the union: `boundingRect` inflated by the annotation's *visible* half-width so painted pixels never clip — `strokeWidth/2` for stroked shapes/lines/freehand, `ArrowGeometry.maxHalfWidth` (the full arrowhead flare) for arrows, plain `boundingRect` for text / counter / effect (they already report painted bounds).
- **Adaptive background** (`CanvasBackground`, built once per image, cached on the document, invalidated on crop) — **one uniform color, not an edge gradient**. The first design extended each edge pixel outward at its own coordinate; on a real screenshot that smeared every color variation, wood grain, and dark divider into long horizontal/vertical bands (Tefa's 2026-07-19 manual test). Shottr instead fills with a single clean color that matches the surrounding background. Detection (`init?(image:)` → `detectFill`, pure):
  - Slide small windows along a shallow perimeter band (≤8 px deep, ~24 windows/edge, both bands per axis). Each window contributes its **mean color** weighted by **uniformity** `1/(1 + 250·variance)` (textures / text / borders / dividers are high-variance → crushed), by **pixel count** (large continuous regions), and a **corner boost** ×2 (the outer 15 % of each edge — corners are most likely background).
  - **Cluster** the window means into coarse RGB bins (step 1/12) and accumulate weight, so colors recurring across multiple edges pile up; take the heaviest bin's weighted mean, then **one mean-shift step** (average all windows within RGB-distance 0.12 of it) so a color straddling a bin boundary isn't split. This is dominant-color clustering, **not** a naive border average.
  - **Fallbacks:** no window reads as clean background → the single most-uniform window; else the plain perimeter mean; else neutral white.
  - The fill is uniform, so consumers (canvas `draw`, `AnnotationRenderer.flatten`) paint it with `fillColor.cgColor` (sRGB-tagged) via a plain `fill` — no intermediate bitmap. Only the four ≤8 px perimeter bands are rasterised for detection. No manual user-override color yet (deferred — auto-detect only, Tefa 2026-07-19).
- **Gesture-scoped ratchet** kills scale oscillation: while a drag is in progress the effective canvas rect is `union(rectAtMouseDown, liveDerivedRect)` — it only **grows** mid-gesture and shrinks back on mouse-up (the floor is released). Without it, growing the canvas shrinks the fit scale, which could feed back into a jitter loop.
- **Frozen gesture transform** (`gestureViewTransform`): the ratchet alone kept the canvas growing monotonically but the view still **re-fit live**, and since the mouse→image mapping uses that shrinking scale, each drag step mapped further out — a feedback loop that made a small overshoot past the edge *accelerate* the expansion and shrink the original image away (Tefa's 2026-07-19 manual test: "grows way too fast, can't see the original image"). Fix: capture the image→view **scale + image-origin position at mouse-down** and hold them for the whole drag, so `fittedFrame` keeps the base image fixed and lets the canvas grow *around* it (past the window, clipped). The mouse→image map is then a constant affine transform → the annotation and canvas track actual mouse travel **1:1** with no acceleration. Released on mouse-up → the view re-fits the final canvas once.
- **Crop stays image-space**: the crop tool clamps its rect to `imageBounds` (no cropping into generated background — out of scope). All other tools drop the old image-bounds clamps on move/resize/draw.

## Key files

- `Editor/CanvasGeometry.swift` — PURE derived-rect math.
- `Editor/CanvasBackground.swift` — PURE perimeter-clustering → one uniform `fillColor` (band-only sampling).
- `Editor/AnnotationGeometry.swift` — `contentRect:` conversion variants (imageSize wrappers preserved).
- `Editor/AnnotationRenderer.swift` — `flatten(image:annotations:canvasRect:background:)` overload (old signature = wrapper).
- `Editor/AnnotationDocument.swift` — `canvasRect(padding:)` + cached `canvasBackground`.
- `Editor/AnnotationCanvasView.swift` — live `canvasRect` (ratcheted), rewritten `draw`, unclamped conversions.
- `Settings/*` — `SettingsStore.canvasPadding` (points, default 16) + settings stepper (0–100).

## Log

- **2026-07-19** — Implemented. Derived negative-origin canvas rect; `expandedBounds` + `ArrowGeometry.maxHalfWidth`; `CanvasBackground` edge-derived fill with seam-free corner blending; canvas-rect `flatten` overload (Copy/Save/Pin/reopen all embed the expansion); gesture ratchet; padding setting. Automated gate green (157 tests: `CanvasGeometryTests`, `CanvasBackgroundTests`, `ExpandedBoundsTests`, negative-origin conversion + expanded-flatten cases). Manual checklist pending Tefa.
- **2026-07-19** — **Frozen gesture transform** added after manual test: reaching an edge made the canvas expand runaway-fast (live re-fit fed the mouse→image scale back into itself), shrinking the original image to nothing. Now the on-screen scale + image anchor freeze at mouse-down and the canvas grows around a fixed image (1:1 with mouse travel), re-fitting once on release. Gate green (158 tests; UI behavior on the manual checklist).
- **2026-07-19** — **Manual checklist confirmed by Tefa** — all rows pass (live per-side growth + padding, shrink-back, single clean uniform background on solid/gradient/wood-grain/busy shots incl. corners, all annotation types outside the image, half-outside blur clips to image, crop stays image-bounded, Copy/Save/Pin/reopen pixel-identical, no boundary jitter, 1:1 grow-around-image with re-fit on release). M-F done; Post-MVP Round 1 complete.
- **2026-07-19** — **Adaptive-background reworked after manual test.** The edge-derived per-position fill smeared edge pixels into horizontal/vertical bands (turned wood grain / color variation / dark dividers into streaks). Replaced with **single-uniform-color detection** (perimeter windows → uniformity·size·corner weighting → dominant-cluster + one mean-shift step; graceful fallbacks) matching Shottr; `render` is now a solid fill. `CanvasBackground` public surface trimmed to `fillColor` + memberwise `init(imageBounds:fill:)` (four-edge init/arrays gone); consumers unchanged (still call `render`). `CanvasBackgroundTests` rewritten (uniform-fill, dominant-over-detail, split-image-picks-one-clean-color, solid-fill readback). Manual user-override color deferred (auto-detect only). Gate green (158 tests).
- **2026-10-08** — Review pass: background detection rasterises **only the four perimeter bands** (was the whole image: ~60 MB + a colour-converting blit for 5K, mid-drag); export only samples the background when the canvas actually grew; the uniform fill is a direct `setFillColor`+`fill` in canvas and export (`render(canvasRect:maxDimension:)` and `color(at:)` removed — no intermediate bitmap, half the peak export memory); growth capped at `max(image w, h, 4096)` px per side; the canvas rect now derives from the layout set (includes the label being edited), so editing an out-of-image label doesn't refit the canvas; a per-draw/per-event layout snapshot replaces 10–20 recomputations; crop drops wholly-outside annotations (see [annotations.md](annotations.md)); export keeps the base image's colour space (Display P3) instead of forcing sRGB.

## Manual checklist — ✅ confirmed (Tefa, 2026-07-19)

- [x] Drag an arrow off each edge (left / right / top / bottom) → canvas grows live with padding on **only** that side; the window doesn't resize (content re-fits)
- [x] Undo / delete / move-back → canvas shrinks again
- [x] Background is a single clean uniform color (no streaks/bands, no smeared edge pixels) on solid, gradient, wood-grain, and busy screenshots; it matches the surrounding background (e.g. white canvas → white fill), including all four sides and corners
- [x] Every annotation type works outside the image (shape, arrow, line, text, freehand, counter)
- [x] A blur/pixelate region half-outside affects only the image part
- [x] Crop is still confined to the image bounds
- [x] Copy / Save / Pin produce an image pixel-identical to the expanded canvas; a pinned expanded shot re-opened for editing shows the expansion baked in
- [x] No jitter at the image boundary while dragging in and out; padding setting (0–100) changes the gap
- [x] Dragging past an edge grows the canvas smoothly at mouse speed — the original image stays full-size/visible during the drag (grows *around* it), and the view re-fits once on release (no runaway acceleration)

## Manual checklist — review pass (2026-10-08, unverified)

- [ ] Dragging an annotation outward on a 5K capture has no first-frame hitch (background no longer rasterises the full image)
- [ ] Repeatedly dragging an annotation far outward stops growing at the cap (≈ one image-length / 4096 px per side) instead of ballooning; Copy still succeeds
- [ ] Expanded Copy/Save/Pin looks identical to before (flat fill, same colour as the canvas)
- [ ] A Display P3 (built-in display) capture keeps its colours through editor Copy vs panel Copy
