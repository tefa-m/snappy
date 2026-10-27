# Capture — Area, Window, Fullscreen

## What it is

The capture engine (milestone M1, priority P1): all three capture modes produce pixel-correct `CGImage`s via ScreenCaptureKit.

- **Fullscreen:** ⇧⌘3 or the menu item → snapshot the display under the mouse via `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)` (macOS 26 API; `SCScreenshotConfiguration` with `dynamicRange = .sdr`, output via `SCScreenshotOutput.sdrImage`). Never activates, so the frontmost app keeps focus and its transient UI survives into the shot
- **Window:** enumerate `SCShareableContent.windows`, hover-highlight the window under the cursor in an overlay (screen dimmed, window accent-tinted, two-tone edge, app-name chip), capture the selected `SCWindow`
- **Area:** ⇧⌘4 or the menu item → **freeze every display first**, then show one opaque overlay panel per screen (level `.screenSaver`) painting that display's snapshot, crosshair cursor. Drag-to-select tints only the selected region, outlines it with a two-tone edge (white + black @ 0.6, ≥ 3:1 on any backdrop) and shows a live size chip — all drawn from the crop's own pixel rect, so what you see is exactly what is captured; Esc cancels. On mouse-up the selection is cropped straight out of the snapshot — no second trip to ScreenCaptureKit and no compositor sleep
- Multi-display aware: one overlay per frozen display; a selection spans only one display (v1)
- TCC denial (`SCShareableContent` throws) → alert deep-linking to System Settings, and **no overlay appears**

All coordinate math lives in pure, unit-tested `CaptureGeometry` (rect normalization, point→pixel with backing scale, snapshot crop rects, clamping, multi-display mapping). See `docs/ARCHITECTURE.md` for the coordinate-system and overlay-activation invariants — they fixed real bugs; do not regress them.

## Why the screen freezes

Pressing ⇧⌘4 used to destroy exactly the UI most worth screenshotting: another app's right-click menu, an open menu-bar menu, a hovering tooltip. Two causes, both now fixed:

1. Snappy activated itself before the overlay appeared, and activating makes the frontmost app resign — which tears down its `NSMenu` tracking loop and cancels tooltips.
2. The screenshot was taken ~100 ms *after* the overlay closed, so even a surviving menu would have been long gone.

So the pixels are now captured **before** activation, and the selection happens on that still image. Activating afterwards still dismisses the foreign menu — which is both necessary (its modal tracking loop would otherwise swallow the first click, regardless of window level) and harmless (it is already in the snapshot, and the user still sees it on the backdrop).

Trade-off, by design: the screen no longer updates live under the overlay. A video keeps playing in reality but the capture shows the frame from the moment the shortcut fired — which is the point.

## Why it does not *feel* frozen

A still image of an unchanged screen is pixel-identical to the live screen — you cannot tell the difference unless something is animating. What gives a freeze away is not the freeze; it is everything around it. Three things did, and all three are gone:

1. **The fade.** Making the overlay an `NSPanel` (for `.nonactivatingPanel`) silently bought AppKit's inferred `.utilityWindow` animation, which fades the window in *and* out — the frozen screen appeared to pulse on when the shortcut fired and pulse off when the selection finished. `animationBehavior = .none` fixes it; the backdrop now appears and disappears in one frame.
2. **The grey wash.** The overlay used to dim the entire screen at 25% black the moment it appeared — the loudest "something just happened" signal in the flow. Now nothing is painted until the drag starts, and then only the *selection* is tinted (black @ 0.12). Everything outside it stays exactly as it was.
3. **Dead time.** The overlay cannot appear before the snapshot exists (see the rejection below), so the only lever is making the snapshot fast: `SCShareableContent` is kept warm rather than re-fetched on nearly every capture, which removes 50–150 ms from the hot path.

The mouse pointer is not part of the snapshot (`showsCursor = false`), so there is no frozen second cursor next to the live crosshair.

Snappy's own preview panel and editor are excluded from the snapshot, so the backdrop shows what is *behind* them and the capture matches the backdrop pixel-for-pixel. **Open pins are kept in the snapshot** (2026-10-14, see the log) so a screenshot can include a pinned one.

## Log

- **2026-07-17/18** — M1 done incl. manual checklist. Temporary pre-panel behavior (copy straight to clipboard) removed when the preview panel landed
- **2026-07-18** — Overlay UX fixes: `acceptsFirstMouse` so the first click starts the drag immediately, always-active tracking areas for the crosshair cursor, `NSApp.activate()` called synchronously during the menu interaction (cooperative activation), plus a local Esc key monitor so Esc reliably cancels
- **2026-10-14** — **Pins stay in captures** (Tefa: a pinned screenshot vanished while taking another with ⇧⌘4). Cause: self-exclusion by application hid every Snappy window, pins included, from the frozen snapshot. Fix: `exceptingWindows` = open pins (`PinWindowRegistry`), one fresh `SCShareableContent` fetch only when a pin is newer than the warm cache; applies to ⇧⌘4, ⇧⌘3 and area recording. The panel/editor/menu stay excluded. Hover toolbar of a pin under the cursor is part of the pin window, so it can appear in the shot. Manual checklist item added, pending
- **2026-07-19** — macOS 26 retarget: `SCStreamConfiguration` + `captureImage` → `SCScreenshotConfiguration` + `captureScreenshot` (macOS 26 API). Same `sourceRect` semantics (points, display-local, top-left) and explicit pixel `width`/`height`; explicitly `dynamicRange = .sdr`, `guard output.sdrImage` → new `CaptureError.noImage` (generic alert path). Deliberately NOT using `captureScreenshot(rect:)` — it takes no content filter, so Snappy's own windows couldn't be excluded. HDR (`.bothSDRAndHDR`) is a possible future option
- **2026-08-25** — **Frozen-screen capture** (Tefa: transient UI vanished on ⇧⌘4). Root cause was the double `NSApp.activate()` (`CaptureCoordinator.captureArea` + `AreaSelectionController.begin`) plus the post-overlay ScreenCaptureKit shot. Fix: snapshot every display before activating, show it as an opaque overlay backdrop, crop locally. Consequences: **overlay invariant #1 deliberately inverted** for area capture (activation moved after an `await`), so the overlay became an `NSPanel` with `.nonactivatingPanel` + `hidesOnDeactivate = false` — Esc no longer depends on activation — plus one deferred re-activation retry; `fill(using: .copy)` punch-out replaced by dimming *bands* (over an opaque backdrop, `.copy` erases rather than reveals); self-exclusion moved from a window list to `excludingApplications` (a window list goes stale the moment a pin opens); `SCShareableContent` cached (30 s, primed after a capture, never at launch — that would move the TCC prompt to login); `SCScreenshotConfiguration.sourceRect` retired; `CGImage.cropping(to:)` found to share the parent buffer, so `CaptureEngine.crop` re-renders to detach (otherwise every pin retains a whole ~30–80 MB display snapshot). Also: ⇧⌘3 for fullscreen and a `CaptureTrigger` so only the menu path waits for Snappy's own menu to fade. `HotKeyCenter` had to be rewritten first — its handler ignored the `EventHotKeyID`, so a second hot key would have routed both to whichever registered last
- **2026-08-25** — Rejected while designing the freeze: caching `SCShareableContent` at launch (moves the TCC prompt to login); `CGDisplayCreateImage` (deprecated, and it cannot exclude our own windows); freezing the display under the mouse first and the rest in the background (the others would then be frozen *after* activation, breaking the feature on secondary displays); a global keyDown monitor or `CGEventTap` for Esc (both need Accessibility); a `freezeScreenDuringSelection` setting (two drawing paths for no benefit — Tefa chose always-on)

- **2026-08-26** — **Selection tint + warm cache + no fade** (Tefa: "Snappy grays a bit the frozen screen which I don't like", and it felt slow). Landed in two passes. First pass: drawing reduced to a 0.12 black tint *inside* the selection — nothing before the drag, nothing outside it (`CaptureGeometry.dimmingRects` and its 6 tests deleted); `SCShareableContent` kept warm via debounced `NSWorkspace` app-activate/launch/terminate re-priming (lifetime 30 s → 5 min as a safety net only), gated behind a new `hasCompletedFirstCapture` setting so nothing can move the TCC prompt to login. Second pass, after Tefa tested: **`animationBehavior = .none`** on the overlay panel — the "heartbeat" he saw at both ends of a capture was AppKit's inferred `.utilityWindow` fade, which arrived unnoticed when the overlay went from `NSWindow` to `NSPanel` on 2026-08-25. Also: `finish(with:)` now orders each overlay out *before* releasing its backdrop image, so emptying a still-visible window's layer cannot composite a bare frame
- **2026-08-26** — **Rejected, tested, do not retry: putting the selection overlay up *before* the freeze.** Shipped briefly as a two-phase overlay (transparent panels + crosshair immediately, frozen backdrop swapped in ~80 ms later) to kill the dead time between ⇧⌘4 and the crosshair. It broke the feature: ordering full-screen panels front and calling `makeKey()` cancels a foreign `NSMenu`'s tracking loop, so the menu was gone before the snapshot — and because phase 1 was transparent, the screen was live while it happened, so Tefa *watched* the Apple menu vanish. Confirmed by the control experiment: ⇧⌘3 (atomic — nothing on screen before its snapshot) captures the Apple menu correctly, while the two-phase ⇧⌘4 did not. Instant crosshair feedback before the freeze is therefore unavailable: it needs a window, and a window costs the menu. With it went `pendingSelection`, the display-id panel matching, `FrozenScreen.displayID`, the cancellable `freezeTask` and its generation counter — all of which existed only to serve phase 1
- **2026-08-26** — Also rejected: dimming the area *outside* the selection (Tefa chose an inside tint — it leaves the rest of the screen untouched, which is the whole illusion); a settings toggle for the tint (one drawing path is the point); touching `PreviewPanel`'s own fade (it is an `NSPanel` on `main` too, predates this work, and was not what Tefa reported)
- **2026-10-08** — Review pass: **capture sessions can no longer overlap** (`captureSessionActive`; `captureWindow` reserves `windowPickInFlight` synchronously before its fetch and re-checks after; `captureFullscreen` beeps and bails during an area/window session instead of opening a preview under the selection overlay) — activation ordering untouched. **Shareable-content cache**: a generation counter makes a warm-up that was in flight during a display change drop its result, and `usableCachedContent` now also requires each `SCDisplay`'s width/height to match its `NSScreen` frame (a resolution change keeps the display ID). `CaptureEngine.crop` returns the snapshot as-is for a whole-snapshot selection (no 30–80 MB copy). Window-pick highlight updates only when the hovered window changes.

- **2026-10-08** — **HIG design pass** (`apple-design` skill; review in `docs/design-reviews/overlays.md`, rating *Good*). Measured, not eyeballed: the area overlay's 1 pt white border was **1.00:1 on white** content and the window picker's accent stroke was under 3:1 on 89 % of sampled backdrops. Both overlays now share **one two-tone edge** (1 pt white against the target + 1 pt black @ 0.6 outside it; worst case 3.44:1 over the whole sRGB cube, locked by a test); the picker keeps the accent as its 20 % tint. The area overlay now draws **what the crop will take** (`CaptureGeometry.capturedSelection` — the crop's own rounded/clamped pixel rect mapped back to points): crisp snapshot-pixel edges, a rounded (not truncated) readout, nothing drawn for a click. Chip placement moved into pure, tested `OverlayGeometry` (the window chip centres on the on-screen part of the window and is clamped — it used to clip off-screen); drawing shared in `OverlayChrome`. VoiceOver: window titles "Capture Area"/"Capture Window", view labels + help naming Escape. Crop, activation, freeze and bindings untouched. **Deferred:** loupe / arrow-key nudge; system ⇧⌘4 modifiers (Space/Shift/Option); Q-to-cancel (both binding changes → leader, `features/shortcuts-ux.md`); readout unit points vs pixels; chip placement opposite the drag; window title in the chip; Increase Contrast scrim; one chip style. 227 tests, 0 warnings
- **2026-10-08** — **Reviewer round on the HIG pass** (independent Sol review + a leader note from d-pin; responses in the review doc). Changes: **Q cancels both overlays** like Esc (bare Q only, via `OverlayKeys` → `ShortcutKeys.isBareKey`) — Tefa's standing "Q or Esc closes any transient window" rule, now also applied to the overlays; **edge sides touching the screen edge fold inward** instead of being clipped (a screen-edge selection or maximised window used to lose that side); the readout keeps **half points** ("150.5 × 99.5") so it really matches the crop; chip scrims go **opaque under Reduce Transparency**; and the area overlay's tracking area was split, because `.activeAlways` is "Not supported for NSTrackingCursorUpdate" (NSTrackingArea.h — found by d-pin), so `cursorUpdate(with:)` now lives on its own `.activeInKeyWindow` area (`OverlayTracking`). The doc's Full Keyboard Access claim was retracted: Esc/Q cancel, but neither overlay can be *completed* by keyboard — that is now a follow-up for audit #12. 235 tests, 0 warnings
- **2026-10-24** — **Review finding F3** (`fix/capture-take-integrity`): ⇧⌘3 (or a window capture's post-pick 100 ms wait + screenshot) followed by ⇧⌘4 before it returned put the preview panel over the frozen selection overlay, taking key. One rule now, in the PURE `CaptureActivity.dropsCaptureResult(superseded:)`: **starting an area selection or a window pick supersedes every capture result not yet delivered** (`PendingCaptures.supersedeAll`, the same moment it closes a panel already up) — its panel or error is dropped, over the overlay or after it; no result presents while an interactive session is open or starting. Requests begun later (the pick's own screenshot, a later ⇧⌘3) are unaffected; a superseded request still holds the recording gate until it finishes. Rejected: beeping on ⇧⌘4 while a capture is pending (blocks the user for a result they are replacing anyway). Tests: `CaptureActivityTests`, `CaptureResultSupersedingTests` (⇧⌘3→⇧⌘4 and window capture→⇧⌘4, landing during and after the selection).
- **2026-10-23** — Review fix F6: the area overlay restored no cursor when it finished, so the crosshair it sets could outlive the overlays (until something else set a cursor). `finish(with:)` now sets the arrow on completion and on cancel, like the pin does on mouse-up.
- **2026-10-27** — Refactor (no behaviour change): ⇧⌘4 / ⇧⌘3 are registered by `GlobalHotKeys.installCaptureKeys` (still routed by `CaptureHotKeyRoute`) instead of `AppDelegate` touching `HotKeyCenter` — see [shortcuts-ux.md](shortcuts-ux.md).

## Manual checklist — review fixes (2026-10-23, pending)

- [ ] ⇧⌘4, drag an area → the pointer is the arrow again as soon as the overlay is gone (over the preview panel and over other apps); ⇧⌘4 then Esc / Q → arrow too

## Manual checklist — frozen capture (2026-08-25, unverified)

**Prerequisite:** System Settings → Keyboard → Keyboard Shortcuts → Screenshots — **both** ⇧⌘3 and ⇧⌘4 disabled.

*The point of the change*
- [ ] Right-click a file in Finder, then ⇧⌘4 **without moving the mouse** → the context menu is on the frozen backdrop; drag over it → the capture contains the menu
- [ ] Open a menu-bar menu (Safari → File), ⇧⌘4 → the open menu **and** the highlighted title are captured
- [ ] Open the **Apple menu** (top-left), ⇧⌘4 → the menu is still on screen (on the backdrop) and lands in the capture — this is the one that regressed
- [ ] ⇧⌘3 with the Apple menu open still captures it (the atomic control case — must not regress)
- [ ] Open a system menu-bar extra (Wi-Fi / Control Center), ⇧⌘4 → same
- [ ] Hover a toolbar button until its tooltip appears, ⇧⌘4 without moving the mouse → tooltip captured (if not, see the `flagsChanged` note in the ARCHITECTURE quirks table before assuming a bug here)
- [ ] A nested submenu is captured expanded
- [ ] With a context menu open, the **first** click starts the drag — none lost to the menu
- [ ] ⇧⌘3 with a foreign context menu open → fullscreen shot contains it, and the frontmost app keeps focus

*Snappy's own UI*
- [ ] Menu → "Capture Area…": Snappy's own menu is not in the backdrop or the capture
- [ ] Menu → "Capture Entire Screen": same
- [ ] With a preview panel / editor open, ⇧⌘4 → absent from the backdrop, and the capture matches the backdrop pixel-for-pixel
- [ ] With a pin open (also one pinned *just now*), ⇧⌘4 → the pin stays visible on the backdrop (no vanish), drag over it → the capture contains the pin; same for ⇧⌘3 and for an area recording; with no pin open nothing changes

*No animation (2026-08-26)*
- [ ] ⇧⌘4 → the frozen backdrop appears **instantly**: no fade-in, no pulse
- [ ] Complete a selection → the overlay disappears with no fade-out and no flash
- [ ] Esc → same, no fade-out
- [ ] Two displays: neither overlay fades at either end

*Smoothness (2026-08-26)*
- [ ] Delay between ⇧⌘4 and the overlay is acceptable with the cache warm — press it a second time right after the first to compare warm vs. cold
- [ ] Nothing on screen darkens until the drag starts; only the selection is tinted, the rest stays untouched
- [ ] First launch of the day: the first ⇧⌘4 is as fast as the tenth (cache warming)

*Geometry*
- [ ] Two displays: both backdrops are 1:1 (straddle a window across the boundary first and compare edges)
- [ ] Selection on the secondary display captures the right region at the right size
- [ ] Mixed DPI (retina + 1× external): pixel dimensions = points × that display's scale, no soft/resampled backdrop on either
- [ ] Notched display: the backdrop's menu bar lines up exactly with the real one
- [ ] Negative-origin arrangement (secondary left of / above the primary)
- [ ] Corner-to-corner selection over a whole display ≈ a ⇧⌘3 shot of that display
- [ ] Selections at `(0,0)` and the bottom-right corner; drag past every edge → clamped, no crash
- [ ] Crosshair / 1-pt white border / size label look as before; the selection shows crisp frozen pixels under a faint tint
- [ ] The mouse pointer is not in the capture

*Activation & cancel*
- [ ] ⇧⌘4 while another app is frontmost, then Esc without clicking → overlays vanish, no capture (this is the non-activating panel's key status)
- [ ] Esc mid-drag cancels; Esc after moving the cursor to a second display cancels
- [ ] Rapid double ⇧⌘4 → exactly one overlay session
- [ ] The preview panel appears **instantly** on mouse-up (the old ~100 ms pause is gone)
- [ ] No perceptible lag between ⇧⌘4 and the overlay, with ~30 windows open across 2 displays

*Hot keys*
- [ ] ⇧⌘4 does area and ⇧⌘3 does fullscreen — never each other's (proves `EventHotKeyID` routing)
- [ ] The menu shows ⇧⌘4 and ⇧⌘3 next to the right items, and clicking either item still works
- [ ] "Capture Window" from the menu is unchanged

*Environment*
- [ ] `tccutil reset ScreenCapture com.tefa.snappy` → deny → ⇧⌘4 shows the permission alert with **no overlay and no backdrop** (this is the `hasCompletedFirstCapture` gate — reset it with `defaults delete com.tefa.snappy hasCompletedFirstCapture`); the System Settings link works; grant + relaunch → capture works
- [ ] Unplug the external display, ⇧⌘4 → overlays match the current screens only (cache invalidation); plug back in → both frozen
- [ ] Memory returns to baseline after Esc and after a completed capture; pinning a small crop does **not** grow RSS by a full display image
- [ ] Video playing → the capture shows the key-press frame, not the drag-end frame

## Manual checklist — ✅ verified (2026-07-18)

- [x] Fullscreen capture matches the screen; pixel size = points × backing scale
- [x] Window capture: hovered window highlighted, capture shows only that window
- [x] Area capture: dimming + crosshair + live size label; capture matches the selection exactly
- [x] Esc cancels each mode with no capture and no leftover overlays
- [x] Area capture works on an external display
- [x] Permission denied → alert with a working System Settings link

## Manual checklist — review pass (2026-10-08, unverified)

- [ ] ⇧⌘3 while the ⇧⌘4 selection is up → beep, nothing else happens; Esc still cancels the selection
- [ ] Menu → Capture Window, then ⇧⌘4 before the picker appears → only one session ends up on screen
- [ ] Change the display's scaled resolution right after switching apps, then ⇧⌘4 → overlay and result match the new resolution
- [ ] Drag-select the entire display → panel appears normally (no extra copy)
- [ ] Window pick: moving the mouse within one window doesn't flicker/redraw the highlight

## Manual checklist — HIG design pass (2026-10-08, unverified)

Review: `docs/design-reviews/overlays.md`. Nothing here could be eyeballed by the agent — these are the things Tefa must look at.

*Area selection — the edge*
- [ ] Drag over a **white** document (TextEdit/Pages in light mode) → the selection's outline is clearly visible (white line inside, darker line outside)
- [ ] Drag over a **black** terminal / dark-mode window → still clearly visible
- [ ] Drag over a mid-grey or busy photo → still visible; the edge looks like one crisp 2 pt cut line, not a heavy box
- [ ] The edge is crisp (no soft, half-pixel antialiasing) on Retina **and** on a 1× external display
- [ ] Before the drag nothing is painted (unchanged); the inside tint is as faint as before
- [ ] A plain click without dragging draws nothing — no tiny square, no "0 × 0"

*Area selection — the size chip*
- [ ] The chip's numbers match the pasted image's size in points (e.g. paste into Preview → Tools → Adjust Size, or pixels ÷ 2 on Retina)
- [ ] Selection along the bottom screen edge → the chip tucks inside the selection, fully on screen
- [ ] Tiny selection at the left screen edge → the chip stays fully on screen
- [ ] Digits don't jitter while dragging

*Window pick*
- [ ] The hovered window still shows the accent tint, now outlined with the same white + dark edge as area selection; outline readable on a light **and** a dark desktop
- [ ] A window hanging half off the left/right screen edge → app-name chip fully on screen, centred on the visible part
- [ ] A window straddling two displays → each display shows its chip fully on screen
- [ ] A maximised window → chip sits at the top of the screen, readable
- [ ] Change System Settings → Appearance → Accent colour (e.g. to Pink) → the window tint follows it

*VoiceOver (⌘F5)*
- [ ] ⇧⌘4 with VoiceOver on → it announces "Capture Area" / "Area selection" and the help mentions Escape or Q; Esc still cancels. This is **orientation only**: neither overlay can be completed by keyboard / VoiceOver yet (follow-up for audit #12)
- [ ] Menu → Capture Window with VoiceOver on → "Capture Window" / "Window picker"

*Regression*
- [ ] Select from the very left/bottom screen edge, and corner-to-corner over a whole display → every side still shows its edge (sides at the screen edge are drawn just inside); the capture still covers the full selection
- [ ] Window pick on a **maximised** window → all four edges visible just inside the screen
- [ ] Odd-pixel selection on Retina → the chip shows a half point (e.g. "150.5 × 99.5"); even selections show whole numbers
- [ ] **Q** cancels the area overlay (before and during a drag, and after moving to a second display) and the window picker, like Esc; ⌘Q / ⌥Q do not
- [ ] System Settings → Accessibility → Display → **Reduce Transparency** on → chips are opaque dark grey; off → translucent as before. Also with Increase Contrast on, and both together
- [ ] The crosshair is shown from the first frame of ⇧⌘4 and stays while moving across displays, with and without Snappy being the active app (tracking-area split)
- [ ] Captures are pixel-identical to before for the same drag (the crop path did not change); frozen menus still captured; no fade at either end

## Manual checklist — superseded capture results, F3 (2026-10-24, unverified)

The pure tests rebuild `CaptureActivity`/`PendingCaptures` transitions only; these check the coordinator's real wiring (`supersedeAll` calls, request tokens passed through to `handle`).

- [ ] ⇧⌘3, then ⇧⌘4 at once (before the fullscreen preview appears) → the frozen selection overlay stays key: no preview panel over it while it is open, and none after a quick drag either — only the area capture's own panel appears
- [ ] Same, but cancel the selection with Esc → no fullscreen preview pops up afterwards
- [ ] Menu → Capture Window, click a window, then ⇧⌘4 right away (within the post-pick wait) → no window-capture panel over the selection or after it
- [ ] ⇧⌘3, then Menu → Capture Window at once → no fullscreen panel over the window picker or after the pick; only the picked window's panel appears
- [ ] A superseded capture that fails (e.g. close the picked window during the post-pick wait, then ⇧⌘4) → no error alert over the overlay or after it
- [ ] After each case above: ⇧⌘3, ⇧⌘4 and a window capture each show their panel normally, and an area recording starts and stops normally (the superseded request released the recording gate)
- [ ] Two ⇧⌘3 in a row (no area/window session) → behaves as before the fix (non-interactive captures never supersede each other)
