# Annotation Editor — Foundation & Highlight Tools

## What it is

Milestone M4 (priority P4): the panel's Edit action opens a real annotation editor. This doc covers the editor foundation and the first tools (rectangle/oval highlights); the [arrow](arrow-tool.md) and the [remaining tools](annotations.md) build on it.

- **Document model:** `Annotation` is an **enum** (value semantics → whole-value undo snapshots, `==` in tests); document = image + `[Annotation]`. Annotations live in **image-pixel, bottom-left coordinates** and stay editable vectors — flattened only on export
- **Canvas:** custom `NSView` that draws the base image plus annotations through the same `AnnotationRenderer` code path as export, so the canvas is pixel-identical to Copy/Save output
- **Editing:** select / move / resize (8 handles), Delete removes; `UndoManager` with `groupsByEvent = false` and one explicit group per mutation — **one undo step per user gesture** (drags mutate a canvas-local draft, commit once on mouse-up)
- **Tools:** rectangle and oval — drag to draw; stroke color/width controls, optional translucent fill. Rectangles render with slightly rounded corners (`rectangleCornerRadius` = 2× strokeWidth, clamped)
- **Export:** flatten → Copy (pasteboard) and Save (same naming/folder as the panel). Copy (⇧⌘C, plain ⌘C works too) **closes the editor** — it's the "done" action
- **Window chrome (Tahoe Glass):** ONE unified header — hidden title (still "Shot W × H" for VoiceOver / Mission Control) + `NSToolbar` (`.unified`, 36×36 pt items) sharing the titlebar with the traffic lights; the canvas runs **under** the Liquid Glass toolbar (full-size content view, transparent titlebar) and the capture is fitted below it, above a passive glass status capsule ("Shot W × H · 100%"). Backdrop: soft light wash in Light mode, graphite in Dark mode, with a drop shadow under the capture. Toolbar is **one item per action** (never a monolithic segmented control) with native "…" overflow; groups Undo·Redo | Select·Arrow·Text·Rectangle·Blur·Counter + rest | color/width/fill | Save·Pin·**Copy** (prominent, accent-tinted, trailing); `minSize` 700 pt wide keeps the primary groups visible, editors open ≥ 960 pt wide (screen permitting) so nothing starts in the overflow menu. Tooltips: "<verb phrase> (KEY)", e.g. "Draw an arrow from tail to head (A)"
- **Keyboard:** tool shortcuts V/R/O (select/rectangle/oval; full list in [shortcuts-ux.md](shortcuts-ux.md)); ⌘Z/⇧⌘Z undo/redo; Q closes; Esc deselects first, then closes

See `docs/ARCHITECTURE.md` → "Annotation editor" for the full invariant list (single y-flip rule, draft-commit pattern, toolbar rules, first-responder handling).

## Log

- **2026-07-18** — M4 implemented; automated gate green (hit-testing, move/resize math, undo sequences, export pixel tests)
- **2026-07-18** — UX round 1: SF Symbol icon buttons + "Action (SHORTCUT)" tooltips; tool shortcuts V/R/O/A (T reserved for the text tool); ⇧⌘C copy-and-close; rounded rectangle corners
- **2026-07-18** — UX round 2: unified titlebar toolbar (no second bar); Q-to-close, Esc deselect-then-close
- **2026-07-18** — UX round 3 (with M6): per-action toolbar items with native overflow + visibility priorities; Pin in the editor (⌘P); smaller/smoother 12 pt medium-weight symbols
- **2026-10-08** — Review pass: **multiple editors can coexist** — the coordinator keeps an `editors` array (like `pins`), each controller is its window's delegate and releases itself on every close path (Copy, Pin, Q, Esc, traffic light); previously opening a second editor dropped the first (zombie window or lost work) and a closed editor was never released. Every export (toolbar and keys) commits a pending text label first. Style controls re-sync on undo/redo and fall back to the creation style when nothing is selected. Copy/Save pass the capture scale so PNG/TIFF carry Retina DPI (144 dpi for 2×). Save never overwrites a same-second file (` (2)`, ` (3)`).
- **2026-10-08** — HIG design pass on the window & toolbar (apple-design skill; review in `docs/design-reviews/editor-chrome.md`, rating **Needs work → fixed**). Measured on macOS 26 with off-screen AppKit probes: toolbar items were 24 pt tall and 24.5–34.5 pt wide (`.unifiedCompact`), the colour well 36 × 20 pt, and at the 700 pt opening width the whole style group plus Undo/Redo started in the overflow menu as stateless labels. Now: `.unified` toolbar (36 × 36 pt items, bar 40 → 52 pt); editors open ≥ 960 pt wide (everything fits from 940 pt); colour well `.minimal` (swatch + system colour popover), Size pop-up and Fill toggle with `.toolbar` bezels (no bezel boxes on the glass); explicit overflow-menu forms Color… / Size ▸ (checkmarked) / Fill (checkmarked), and overflowed Undo/Redo disable when there is nothing to undo; tooltips "<verb phrase> (KEY)" (`ToolSpec.help`, `EditorAction.toolTip`, Save names the folder); Fill icon `paintbrush` → `square.lefthalf.filled`; window title "Snappy — Editor" → "Shot W × H"; VoiceOver labels on colour well + Size; Copy/Save/Pin failure alerts are sheets instead of app-modal; the controls now start from the model's red #FF3B30 instead of `.systemRed` (#FF383C/#FF4245), which the first width change used to bake into the next annotation (found by the canvas review). 215 tests, 0 warnings. Deferred (needs Tefa): a real menu bar while editing, export group to the trailing edge with a prominent Copy, ≤ 3 toolbar groups, sub-10 pt text/badge digits at the 1–2 pt steps (needs a model change). After the independent review: the title follows crop/undo/redo, and the Save tooltip re-reads the folder whenever the editor becomes key. Shortcuts for Color/Size/Fill were proposed (F, [ / ], K) but not added, because bindings are frozen in this pass.

- **2026-10-08** — **Tahoe Glass** design direction (Tefa's pick from five explored looks, light + dark): canvas under the glass toolbar (`.fullSizeContentView`, `titlebarAppearsTransparent`), capture fitted to the unobscured `contentLayoutRect` minus the status band (`AnnotationGeometry.fitArea`, tested); toolbar regrouped Undo·Redo | tools | style | Save·Pin·Copy with Copy `.prominent` at the trailing edge (resolves the "Copy trailing + prominent" decision in `DESIGN_REVIEW.md`; the HIG "≤ 3 groups" item stays open — Color/Size/Fill and the prominent Copy each still get their own glass platter); bottom glass status capsule with title + zoom (`EditorStatus`, tested); appearance-dynamic backdrop wash + clipped drop shadow replacing `underPageBackgroundColor`. Behaviour, bindings and export unchanged.

- **2026-10-09** — Tefa looked at Tahoe Glass on screen and approved it ("Looks good"); merged to `main`. The individual checklist items below have not been ticked off yet

## Manual checklist — Tahoe Glass (2026-10-08, unverified)

- [ ] Light mode: toolbar groups float as glass over a light canvas wash; the capture sits below the toolbar with a soft shadow and is never hidden under it on open
- [ ] Dark mode (System Settings → Appearance → Dark, editor open): canvas turns graphite live, glass and status capsule follow, the shadow still separates the capture
- [ ] Toolbar order: Undo·Redo after the traffic lights, tools, Color/Size/Fill, then Save·Pin and an accent-tinted Copy at the far right
- [ ] Small capture → editor opens ~960 pt wide with **no** "»" overflow chevron (re-measure `fullToolbarWidth` if Copy's prominent platter pushes something out)
- [ ] Status capsule reads "Shot W × H · NN%"; the % changes when you resize the window, crop, or draw past the image edge
- [ ] Drawing still works right down to the bottom edge, through the status capsule; dragging an annotation up under the toolbar works and it shows through the glass
- [ ] Window still drags by the empty toolbar area; traffic lights work
- [ ] A window capture with transparent rounded corners shows no dark rectangle behind the corners

## Manual checklist — ✅ verified (Tefa, 2026-07-19)

- [x] Draw, select, move, resize, and delete both rectangle and oval
- [x] Rectangles have slightly rounded corners
- [x] Stroke color/width changes apply to the selected shape
- [x] Undo/redo via ⌘Z / ⇧⌘Z works through a full editing session
- [x] Copy and Save export an image visually identical to the canvas
- [x] Toolbar controls are icons with tooltips "Action (SHORTCUT)"; V/R/O/A switch tools and sync the picker
- [x] ⇧⌘C copies and then closes the editor window
- [x] Editor has ONE header (unified titlebar, no second bar)
- [x] Q closes the editor; Esc deselects first, then closes when nothing is selected

## Manual checklist — review pass (2026-10-08, unverified)

- [ ] Open an editor, annotate, then capture again and Edit → both editors stay alive and usable; closing one doesn't affect the other
- [ ] Copy / Pin / Q / Esc / traffic light each close the editor and free it (no stale window after repeated edits)
- [ ] Save twice in the same second → two files (`… (2).png`), none overwritten
- [ ] A 2× Save pasted/opened in Preview shows the on-screen size (144 dpi), same for editor Copy → paste in Keynote/Pages

## Manual checklist — HIG design pass (2026-10-08, unverified)

Visual checks — nobody has seen these on screen yet:

- [ ] Toolbar looks right in the taller `.unified` bar (52 pt instead of 40 pt): items are 36 × 36 pt, 12 pt symbols still crisp and not lost in the bigger buttons. If it feels too tall, `window.toolbarStyle = .unifiedCompact` is the one-line revert (items go back to 24 pt)
- [ ] Edit a **small** capture → the editor opens ~960 pt wide and **every** item is visible (no "»" overflow chevron); a capture wider than the screen still fits the screen
- [ ] Colour well is a swatch + chevron (no bezel box); clicking it opens the system colour popover; picking a colour recolours the selected annotation / the next one; the popover's "Show Colors…" panel works too
- [ ] Size pop-up and Fill toggle have no bezel box on the glass; Fill shows a clear highlighted background when ON and the `square.lefthalf.filled` icon reads as "fill"
- [ ] Narrow the window to 700 pt → open the "»" menu: **Color…** opens the Colors panel and recolours; **Size ▸** shows a checkmark on the current width and changing it applies; **Fill** shows a checkmark when on and toggles; **Undo/Redo** are disabled when there is nothing to undo
- [ ] Hover every toolbar item → tooltip reads "<what it does> (KEY)", e.g. "Draw an arrow from tail to head (A)", "Copy and close (⇧⌘C)", "Save PNG to Desktop (⌘S)"
- [ ] In **dark** mode: draw a rectangle, change only the width, draw another → both reds are identical (#FF3B30), and the well shows that red from the start
- [ ] Light **and** dark appearance: style controls and selected tool highlight readable on the glass
- [ ] VoiceOver (⌘F5) on the toolbar: colour well reads "Color", pop-up reads "Size, 3 pt"; the window reads "Shot W × H", not "Snappy — Editor"
- [ ] Crop → the window title (VoiceOver / Mission Control) shows the cropped size; undo and redo restore and re-apply it
- [ ] With an editor open, change the save folder in Settings, return to the editor → the Save tooltip names the new folder, and Save writes there
- [ ] Mission Control / App Exposé with two editors open → their titles differ when the captures differ in size
- [ ] A failing Save (e.g. save folder made read-only) shows the error as a **sheet** on the editor; pins and other editors stay usable meanwhile
- [ ] Green traffic-light button: full screen works, the toolbar stays usable, Esc/Q still close

