# Pin — Floating Screenshot Windows

## What it is

Part of milestone M2: pinning a capture keeps it in an always-on-top borderless window at 1:1, exactly over the captured area (top-left aligned via the anchor rect that travels with every capture result). Multiple pins coexist independently.

- **Move:** drag anywhere (`window.performDrag(with:)` — not `isMovableByWindowBackground`, so the corner stays reserved)
- **Resize:** scroll wheel zooms anchored on the cursor; bottom-right 16 pt corner drag resizes aspect-locked (pure `PinGeometry`); the pointer turns into the system diagonal-resize pointer over that corner (`NSCursor.frameResize`)
- **Hover (Post-MVP M-C):** alpha animates to a subtle **0.9** while the cursor is over the pin (was 0.4 — too aggressive), restores on exit — stays **1.0 under Reduce Transparency** (`PinHover`); simultaneously a compact **Liquid Glass toolbar** (`NSGlassEffectView`, cornerRadius 10 — same chrome as the preview panel) fades in (0.15 s) in the pin's **top-left corner** (8 pt inset). Buttons are borderless **`.toolbar`-style, 28 × 28 pt, 4 pt apart** inside 4 pt of glass (toolbar 100 × 36 pt); actions, symbols, tooltips and keys come from the pure `PinAction` enum:
  - **Close** — red macOS-style control (`xmark.circle.fill`, white × on red via `SymbolConfiguration(paletteColors:)`), tooltip "Close this pin (Q)"
  - **Edit** — `pencil.tip.crop.circle`, tooltip "Annotate in the editor (E)" — closes the pin and reopens its image in the annotation editor (routes through the coordinator, same path as the panel's Edit)
  - **Copy** — `document.on.document`, tooltip "Copy image to clipboard (C)" — full image to the pasteboard, **pin stays open**
  - Buttons accept the first click while Snappy is inactive (`acceptsFirstMouse`); the single `.inVisibleRect` tracking area covers pin **and** toolbar, so moving the pointer onto the toolbar keeps it visible
  - The toolbar hides entirely (`isHidden`, so it can't be clicked invisibly) when the pin is too small to hold it in **either** dimension (`PinGeometry.toolbarFits`: pin < 116 × 52 pt), rechecked on every resize
- **Context menu (secondary click or Control-click):** Edit · Copy | Close (`PinAction.contextMenuGroups`, no shortcuts shown), the mouse route to the actions on pins too small for the toolbar
- **Close:** double-click (anywhere but the resize corner — a double-click there resizes, `PinGeometry.mouseDownAction`), Esc, or Q
- **Keyboard:** **E** edit, **C** copy (bare keys via `ShortcutKeys.isBareKey`) — the pin must be the key window, so click it first (by design)
- **Pin from the editor** (⌘P / toolbar): flattens the annotated image, pins it centered over the editor via the coordinator's shared `pin(image:scale:frame:)`, and closes the editor — a "done" action like Copy

## Design notes

- The pin **retains its `CGImage` and backing scale** (previously only `layer.contents` held the image) so Edit and Copy have real data to work with; `onEdit`/`onCopy` closures are injected by the coordinator like `onClose`.
- Edit → editor → ⌘P re-pins the (possibly re-annotated) image — round-tripping works by construction.

## Log

- **2026-07-18** — Implemented with M2; `performDrag` + 16 pt corner-resize zone; zoom/resize math pure and unit-tested
- **2026-07-18** — Q closes pins like Esc (shortcuts-first rule)
- **2026-07-18** — Pin action added to the editor toolbar (⌘P), M6 UX round
- **2026-07-19** — Post-MVP M-C: hover alpha 0.4 → 0.9 (subtle), Liquid Glass hover toolbar (Close·Edit·Copy) top-left, pin retains image+scale, Edit reopens the editor via the coordinator, E/C keyboard shortcuts
- **2026-10-08** — HIG design pass (review, rated *Critical issues* → *Good* after fixes): toolbar buttons were 16–17.5 pt image buttons 2 pt apart (below the 20 pt HIG minimum) on a glass that had collapsed to 61.5 × 10 pt with the icons spilling out (horizontal `NSStackView` ignores its top/bottom insets) → `.toolbar` 28 × 28 pt, 4 pt apart, explicit 36 pt height; verb-phrase tooltips + name-only VoiceOver labels via `PinAction` (Edit/Copy wording shared with the panel); toolbar fit checks height too and a non-fitting toolbar is `isHidden` (alpha 0 alone left an invisible clickable Close); diagonal-resize pointer on the corner; Reduce Transparency keeps hovered pins opaque. Deferred: key-pin indicator (Tefa), Actual Size / zoom hints (needs a binding), resize grip. Red close kept (Tefa's spec)
- **2026-10-14** — Pins are no longer hidden from screenshots: open pins register in `PinWindowRegistry` and are the exception to Snappy's self-exclusion, so ⇧⌘4/⇧⌘3/area recording can capture them (details: `features/capture.md`)
- **2026-10-08** — Sol reviewer round (all 4 points accepted): context menu Edit · Copy | Close (also Control-click) restores mouse access on pins too small for the bigger toolbar; a separate `.activeInActiveApp` `.cursorUpdate` tracking area re-asserts the resize pointer (`.cursorUpdate` is unsupported with `.activeAlways`); the resize-corner hit test excludes points outside the pin; the M1 citation was corrected
- **2026-10-08** — Review pass: zoom/resize floor is fixed at creation (`min(80, initial width)`) instead of the current width, so a pin narrower than 80 pt can be zoomed back to its original size; pin Copy passes the capture scale (Retina DPI on the pasteboard image).
- **2026-10-23** — Review fix F11: a double-click on the bottom-right resize corner closed the pin (the double-click test ran before the corner test), so a quick second grab of the corner destroyed it. The corner now wins (`PinGeometry.mouseDownAction`, tested); a double-click anywhere else still closes.

## Manual checklist — review fixes (2026-10-23, pending)

- [ ] Double-click the bottom-right resize corner of a pin → the pin stays open (the second press starts a resize); double-click anywhere else → the pin closes

## Manual checklist — HIG design pass (2026-10-08, unverified)

- [ ] Hover a pin over a **light** and a **dark** screenshot: the glass toolbar fully encloses all three icons (no icon edge sticking out of the glass), icons are comfortable to click, gaps between them look even
- [ ] Toolbar buttons show **no border at rest** and a **highlight on hover**; Close is still the red disc with a white ×
- [ ] Tooltips read "Close this pin (Q)", "Annotate in the editor (E)", "Copy image to clipboard (C)"
- [ ] A wide, short pin (one line of text, < 52 pt tall) shows **no** toolbar; clicking its top-left corner moves the pin and never closes it
- [ ] A narrow pin (< 116 pt wide) shows no toolbar; a pin ≥ 116 × 52 pt shows it
- [ ] Pointer over the bottom-right corner turns into the diagonal-resize pointer and back to the arrow elsewhere — check both **before** clicking any pin (Snappy inactive — may stay an arrow; note it) and after clicking one
- [ ] Corner drag-resize, scroll-zoom, drag-move, double-click / Esc / Q close, E / C — unchanged
- [ ] System Settings → Accessibility → Display → **Reduce transparency** on: hovering a pin no longer fades it (toolbar still appears)
- [ ] VoiceOver on: toolbar buttons announce "Close", "Edit", "Copy" (no "(Q)")
- [ ] Secondary click (and Control-click) on a pin, **including a small 100 × 100 pt and a short one-line pin**: menu shows Edit, Copy, separator, Close with icons and no shortcuts; each item works (Edit closes the pin and opens the editor, Copy keeps it open)
- [ ] With Snappy **inactive** (click another app first): the very first right-click on a pin opens the menu, and the first left-click on a toolbar button runs it
- [ ] Resize pointer survives: pointer enters the corner directly, the toolbar fades in, a resize is in progress, Snappy activates/deactivates — never reset to the arrow while over the corner
- [ ] Clamp-and-release: drag the corner past the maximum width and release outside the pin, and the pointer is the arrow, not the resize pointer

## Manual checklist — M2 base ✅ verified (Tefa, 2026-07-19)

- [x] Pin: always on top, draggable, scroll-zoom + corner-drag resize, semi-transparent on hover, closes on double-click and Esc (and Q)
- [x] Two pins open at once behave independently

(Editor-Pin behavior was already verified with the M6 checklist, 2026-07-18.)

## Manual checklist — M-C hover toolbar ✅ verified (Tefa, 2026-07-19)

- [x] Hover fade is subtle (0.9) — screenshot content stays clearly readable
- [x] Toolbar fades in on hover, stays visible while the pointer moves onto it, fades out when the pointer leaves both
- [x] Close removes the pin
- [x] Copy puts a PNG on the pasteboard and the pin stays open
- [x] Edit opens the editor at the correct size and closes the pin; re-pin after editing works
- [x] A tiny pin (narrower than the toolbar) hides the toolbar
- [x] Toolbar usable on both light and dark screenshots
- [x] E / C / Q work after clicking the pin
- [x] Two pins behave independently (each has its own toolbar)
