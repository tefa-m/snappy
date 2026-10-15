# Annotations Suite — Text, Line, Pen, Blur/Pixelate, Counters, Crop

## What it is

Milestone M6 (priority P6): everyday-Shottr annotation parity in the editor. Tool shortcuts **L/P/T/N/B/X/C** (line/pen/text/counter/blur/pixelate/crop).

- **Line** — reuses `ArrowAnnotation` with `kind: .line` (plain round-cap stroke, no head); same endpoint handles and drag mechanics as [arrows](arrow-tool.md)
- **Freehand pen** — smoothed path from drag points (pure `FreehandGeometry`: point thinning, midpoint-quad smoothing, polyline hit-testing)
- **Text labels** — click to type in an overlay `NSTextField` (system UI font, WYSIWYG — the same family `TextGeometry` measures/renders). Enter/click-away commits (one undo step; emptied existing label = remove), Esc cancels, double-click (or T-click) re-edits. **Font size = 6 × strokeWidth** (floor 8), so the width popup doubles as the text-size control. Single-line
- **Counter badges** — auto-incrementing numbered circles; radius = 3 × strokeWidth (floor 8); **bold** digits at 1.2 × radius, white — or black when white would drop under 3:1 on a light fill (`AnnotationColor.badgeLabelColor`). Numbers are **derived from badge order, never stored** (`CounterGeometry.numbers`) → delete renumbers and undo restores numbering for free
- **Blur / pixelate regions** — rectangles whose content is rendered from the **base image** via CoreImage (`CIGaussianBlur` / `CIPixellate`, `EffectRenderer`); strength derives from the image size **and the region's short side** (the region term is capped at 40 px blur / 64 px blocks), which defeated Vision OCR in every measured case (`EffectRedactionTests`). This is **stronger obscuring, not guaranteed redaction**: the result still derives from the source pixels. CI shares the model's bottom-left convention — no flip. `AnnotationRenderer.draw` takes `base:`; effects are skipped without it
- **Crop** — a single undoable document mutation (`crop(to:)` swaps image + annotation offsets in one step); the gesture dims the outside like the capture overlay and switches to Select after committing. Its `CGImage.cropping` top-left conversion is the editor's **single y-flip**. Annotations wholly outside the new bounds are dropped (the canvas is derived from annotation bounds, so keeping them would re-expand it over the cropped-away area); partially overlapping ones are kept intact; undo brings everything back

Pure logic in `TextGeometry` / `FreehandGeometry` / `CounterGeometry` / `EffectRenderer` — all unit-tested (renumbering, crop remapping, smoothing stability, effect-region pixel samples). 108 tests green at M6 completion.

## Log

- **2026-07-18** — M6 implemented: full Shottr-style tool parity. T was reserved for the text tool since the M4 UX round
- **2026-07-18** — Toolbar UX round (see [editor.md](editor.md)): per-action items, native "…" overflow, Pin in the editor
- **2026-10-08** — Review pass: **crop now drops annotations wholly outside the crop** (`expandedBounds` ∩ crop = ∅; undo restores them) — the derived canvas used to re-expand over the cropped-away area, so "render clipped" was no longer true; partially overlapping ones are kept intact. Text: Copy/Save/Pin commit a label still being typed (`commitPendingEdits`); a style change mid-typing applies live and to the label on commit; the field follows window resizes; editing an out-of-image label no longer refits the canvas. Arrow endpoint drags re-clamp the bow. Blur/pixelate results are cached (`EffectCache`).

- **2026-10-08** — HIG design pass ([review](../docs/design-reviews/editor-canvas.md)): **blur/pixelate strength now also scales with the region** — Vision OCR read "Token 4821-7730" out of a blurred 13 pt line in a 700×90 px capture, and 24 pt text verbatim from both effects; with the region term, no readable OCR output in the 12 measured cases (11–48 pt at 2×, 13 pt at 1×; an obscuring improvement, not a redaction guarantee). Sol review follow-up: the two leaking cases are now a checked-in OCR test (`EffectRedactionTests`); 3+-digit badge numbers shrink to fit the disc; undo after a crop or a multi-annotation step clears the selection. **Counter digits** bold, 1.2 × radius (10.8 pt at the default), black on light fills (white on yellow was 1.5:1). Text/pen/counter selection outline is two-tone (accent dashes over white). Undo/redo selects the one annotation it changed. Deferred: text-label halo/pill style, badge ring, sub-10 pt sizes at the 1–2 pt steps (see the review's fix plan).

## Manual checklist — ✅ verified (Tefa, 2026-07-18)

- [x] Text labels: create, edit in place, change font size/color
- [x] Line, freehand, blur, pixelate, counter badges, crop each work end-to-end
- [x] Crop keeps existing annotations correctly positioned
- [x] Toolbar groups: Copy·Save·Pin first, then the six primary tools, then the rest; every action an individual small icon
- [x] Narrow window: extra tools collapse into the native "…" overflow and stay clickable; widening brings them back
- [x] Default/min window size shows the export group + six primary tools
- [x] Pin in the editor (toolbar or ⌘P) pins the annotated image centered over the editor and closes it
- [x] Realistic annotated bug-report screenshot produced with 5+ tools, exported, verified in Preview

## Manual checklist — review pass (2026-10-08, unverified)

- [ ] Type a label, then click toolbar Copy / Pin without pressing Enter → the label is in the result; same for Save
- [ ] Change colour/size while typing a label → the field updates live and the committed label uses it
- [ ] Place a label in the expanded margin, double-click it → the image does not jump; the field stays over the label; resize the window while editing → field follows
- [ ] Crop to one quadrant with annotations in the other quadrants → they are gone and the canvas stays tight; ⌘Z restores image and annotations; an annotation straddling the crop edge survives
- [ ] Shorten a strongly bent arrow by dragging an endpoint → the curve never folds back
- [ ] Select an annotation, restyle it, ⌘Z → the colour/size/fill controls show the restored value; press Esc → controls show the style the next shape will get

## Manual checklist — HIG design pass (2026-10-08, unverified)

- [ ] Blur a single line of text in a **small** capture (one text field / one line, ⇧⌘4) → unreadable; same with pixelate. Blur a large paragraph region → still looks like a blur, not a flat colour
- [ ] Pixelate on a big region in a mid-size capture is blockier than before — acceptable?
- [ ] Counter badges: numbers are bold and readable at the default size; pick yellow / green / white → numbers turn black and stay readable; red / blue / black → white
- [ ] Select a text label, a pen stroke and a badge on a **blue** and on a **dark** part of a capture → the dashed outline is visible on both
- [ ] Restyle an annotation (e.g. width 3 → 5), deselect, ⌘Z → the annotation is selected again and the width control shows 3; delete one, ⌘Z → it comes back selected; ⌘Z after a crop → nothing selected
- [ ] Place 100+ counter badges (or reuse one document): "100" sits inside its disc, slightly smaller than "99"
- [ ] Select a small blur region (~20 pt) and drag from its middle → it moves (doesn't resize); drag just outside a corner → it resizes
