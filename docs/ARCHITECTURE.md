# Snappy — Architecture

> **Maintenance contract:** this file MUST be read before implementing any change,
> and MUST be updated in the same change whenever the architecture shifts
> (new module, new flow, new invariant, changed responsibility).
>
> Dated notes below name the author (Tefa), the AI-agent workflow (Leader, Sol, task IDs) and internal review documents that are not in this repository — see [`FEATURE_MAP.md` › Reading the history logs](FEATURE_MAP.md#reading-the-history-logs).

## Overview

Snappy is a menu-bar-only AppKit app (no Dock icon), built with SPM only — no
Xcode project. Swift 6 language mode with strict concurrency: **all UI code is
`@MainActor`**; logic that must be unit-testable lives in pure, UI-free types.

## Module map

```
Sources/Snappy/
  App/
    SnappyApp.swift              @main entry — sets delegate, runs NSApplication
    AppDelegate.swift            .accessory activation policy; owns StatusItemController
    ShortcutKeys.swift           PURE modifier-flag logic (isBareKey ignores
                                 Shift + Caps Lock) — unit-tested; ALL "no
                                 modifiers held" checks go through it
    StatusItemController.swift   NSStatusItem + menu (bundled template "S"
                                 glyph, SF Symbol fallback when unbundled);
                                 menu built from PURE StatusMenuCommand
                                 (titles/symbols/keys — tested); forwards to
                                 CaptureCoordinator / RecordingCoordinator
                                 (Record Area…, Reopen Last Recording —
                                 validated: disabled without a take);
                                 while recording the item is a red ● + the
                                 elapsed time ("● 0:42", monospaced digits,
                                 once per second from the toolbar timer's
                                 start; PURE RecordingStatusGlyph — tested):
                                 menu removed, a click stops — a right-/⌃-/⌥-
                                 click (PURE RecordingStatusClick) pops up
                                 RecordingStatusMenu (Magic Pen thickness +
                                 Stop); the normal menu's "Magic Pen
                                 Thickness" submenu is PURE
                                 MagicPenThicknessMenu — all tested; drives a
                                 StatusItemHosting on a StatusItemTicker
                                 (seams for the lifecycle tests)
    AppVersion.swift             PURE version text for the menu footer from
                                 Info.plist (`SnappyBuildDescription`) — tested;
                                 the plist is written by bundle.sh from the git
                                 tag, never hardcoded (features/versioning.md)
    UserFacingText.swift         PURE copy for every alert + banner — tested;
                                 errors never reach a person as
                                 String(describing:)
    UserNotifier.swift           UNUserNotificationCenter banners (falls back to
                                 NSLog when unbundled — see quirks); caller-chosen
                                 identifier (same id = replace), optional beep +
                                 VoiceOver announcement when the banner can't
                                 be delivered
  Capture/
    CaptureCoordinator.swift     Orchestrates the capture flows end to end; owns the
                                 overlay controllers; trigger-aware (hot key vs menu);
                                 crops the frozen snapshot; handles results and errors;
                                 hands Record / "Record Area…" (same frozen drag, no
                                 panel) to RecordingCoordinator with a display-clamped
                                 RecordingTarget; shows recording alerts
    CaptureEngine.swift          Thin ScreenCaptureKit wrapper (SCScreenshotManager);
                                 FrozenScreen + per-display freeze snapshots,
                                 warm-kept SCShareableContent cache, detaching crop;
                                 maps TCC denial to CaptureError.permissionDenied
    CaptureGeometry.swift        PURE coordinate math (see invariants) — fully unit-tested
    PinInclusion.swift           PinWindowRegistry (open pins' window IDs) + PURE
                                 PinInclusion.needsFreshContent — pins are the one
                                 Snappy window kept in captures — tested
    Clipboard.swift              PNG+TIFF pasteboard writing; BitmapRep (rep.size =
                                 pixels ÷ capture scale → Retina DPI metadata)
  Overlay/
    AreaSelectionController.swift  Area drag-select overlay — frozen-snapshot backdrop on
                                   non-activating panels (panel + views in same file)
    WindowPickController.swift     Window hover-pick overlay (window + view in same file)
    OverlayGeometry.swift          PURE overlay chrome layout: two-tone edge rects,
                                   size readout, size/title chip frames + clamp — tested
    OverlayChrome.swift            AppKit drawing of that chrome, shared by both overlays
    OverlayKeys.swift              PURE cancel-key test (Esc or bare Q) — tested
    OverlayTracking.swift          PURE tracking-area option sets (see invariant 3) — tested
  HotKey/
    HotKeyCombo.swift            PURE combo model (keyCode + Carbon modifiers) with
                                 UserDefaults round-trip — unit-tested
    HotKeyCenter.swift           Carbon RegisterEventHotKey wrapper — ONE center owning
                                 every binding, routed by EventHotKeyID
                                 (⇧⌘4 → area, ⇧⌘3 → fullscreen, ⌃⌥D → draw
                                 mode, ⌃⌥P → Magic Pen — both session-only
                                 via `unregister`);
                                 `register` returns false when the system
                                 refuses a combo, and `isRegistered` means a
                                 live Carbon hot key — tested; a refused
                                 registration is kept (unbound, combo
                                 stored) for `retry`/`retryUnbound`;
                                 `replace` acquires the new combo before
                                 releasing the old (no rollback), the same
                                 combo again retries, `isAvailable` probes a
                                 combo (`.availabilityProbe`, released at
                                 once), `setSuspended` releases every ref
                                 while a Settings recorder waits and a
                                 failed resume keeps the registration
                                 (`unboundActions`) — tested;
                                 PURE `CaptureHotKeyRoute` makes ⇧⌘4
                                 context-sensitive (no session → capture ·
                                 recording → stop · rest of a session →
                                 ignored) — tested
    GlobalHotKeys.swift          The four remappable hot keys' live side:
                                 `set`/`reset` validate (another Snappy hot
                                 key's combo refused), bind (capture keys via
                                 `replace`; session keys via the coordinator
                                 mid-session, else `isAvailable`) and only
                                 then save + `onChange` (menu, Stop tooltips,
                                 Settings fields; also on a layout change);
                                 the stored combo again = retry; `isLive` /
                                 `onStatusChange` for the fields' "taken"
                                 line; `HotKeyRebinding` seam — tested with
                                 a fake
    KeyLegend.swift              A key code's label on the current keyboard
                                 layout (TIS + UCKeyTranslate, main thread
                                 only, cached until the layout changes),
                                 PURE US fallback + typed-character rule —
                                 tested
  Panel/
    PanelGeometry.swift          PURE panel placement/clamping math — unit-tested
    PreviewPanelController.swift Post-capture floating panel (Edit·Copy·Save·OCR·Pin·
                                 Record — R hands the area to recording Setup)
  Pin/
    PinGeometry.swift            PURE zoom/corner-resize math, resize-corner
                                 hit test, toolbar fit — unit-tested
    PinAction.swift              PURE toolbar actions (title/symbol/key/tooltip)
                                 + hover alpha (Reduce Transparency) — tested
    PinWindowController.swift    Always-on-top pinned screenshot windows +
                                 Liquid Glass hover toolbar (Close·Edit·Copy)
  OCR/
    TextAssembler.swift          PURE observation→text joining + notification
                                 preview — unit-tested
    TextRecognizer.swift         Vision wrapper (async RecognizeTextRequest,
                                 EN+DE, accurate, offline)
  Editor/
    AnnotationModel.swift        PURE value model: AnnotationColor/AnnotationStyle,
                                 ShapeAnnotation, ArrowAnnotation (arrow|line),
                                 TextAnnotation, FreehandAnnotation,
                                 EffectAnnotation (blur|pixelate),
                                 CounterAnnotation, Annotation enum
    AnnotationGeometry.swift     PURE editor geometry: aspect-fit + view↔image
                                 conversion (contentRect variants for the
                                 expanding canvas; imageSize wrappers kept),
                                 hit-testing, handle/resize/move math — tested
    CanvasGeometry.swift         PURE derived canvas rect (M-F): image bounds
                                 expanded per-side to contain annotations +
                                 padding; may be negative-origin — unit-tested
    CanvasBackground.swift       PURE adaptive background: perimeter-window
                                 clustering → ONE uniform fill color
                                 (no edge smear). Rasterises only
                                 the four perimeter bands; consumers fill with
                                 `fillColor.cgColor` directly — tested
    ArrowGeometry.swift          PURE arrow math: tapered outline polygon
                                 (straight + bowed quad-Bézier), bow projection/
                                 snap, shaft hit-testing, handle hits — unit-tested
    TextGeometry.swift           PURE CoreText metrics + CTLine construction
                                 (system UI font); font size derived from
                                 strokeWidth — unit-tested
    FreehandGeometry.swift       PURE pen math: point thinning, midpoint-quad
                                 smoothing, polyline hit-testing — unit-tested
    CounterGeometry.swift        PURE badge math: radius from strokeWidth,
                                 order-derived numbering, disc hits — unit-tested
    EffectRenderer.swift         CoreImage blur/pixelate of base-image regions
                                 (offline, strength from image AND region size) +
                                 EffectCache (bounded LRU, keyed by base-image
                                 identity/kind/region)
    AnnotationRenderer.swift     PURE CG drawing + export flattening; single
                                 code path for canvas and export — unit-tested
    AnnotationDocument.swift     Editor model: image + [Annotation], undoable
                                 mutations incl. crop via UndoManager — unit-tested
    CursorGeometry.swift         PURE tool-aware-cursor decision (tool ×
                                 hover × enabled → cursor kind) + resize
                                 handle→FrameResizePosition mapping — unit-tested
    ToolCursorFactory.swift      Cached NSCursor construction: crosshair +
                                 toolbar-symbol badge images, system cursors
                                 for move/resize/handles
    AnnotationCanvasView.swift   Canvas NSView: draw/select/move/resize/delete,
                                 draft-during-drag, in-place text editing,
                                 crop gesture, keyboard handling, tool-aware
                                 cursor (tracking area + mouseMoved)
    EditorStatus.swift           PURE status-capsule text ("Shot W × H · 100%")
                                 + zoom percent — unit-tested
    EditorWindowController.swift Editor window (Tahoe Glass): glass toolbar
                                 (Undo/Redo, tool picker, color, width, fill,
                                 Save/Pin, prominent Copy) over the canvas +
                                 bottom status capsule;
                                 NSWindowDelegate → `onClose` releases it;
                                 PURE `EditorAction` + `ToolSpec` tooltip text
                                 and `windowTitle` — unit-tested
  Settings/
    SettingsStore.swift          UserDefaults-backed settings (save folder, hot key,
                                 recording options, the window-parts
                                 "Accessibility prompted once" flag)
    SettingsFormatting.swift     PURE settings helpers — tested:
                                 HotKeyCombo.displayString(keyName:) /
                                 menuKeyEquivalent(keyName:), the one
                                 ⌘/⌃/⌥ recorder rule, SettingsKeyCommand
                                 (⌘W/X/C/V/A), SaveFolderValidation (only an
                                 existing local directory — the path control
                                 accepts drops), CanvasPaddingInput,
                                 RecordingSettingsText, ReservedHotKey,
                                 HotKeyRecorderInput (shortcut recorders:
                                 one rule for all four — at least one of
                                 ⌘/⌃/⌥ — letters/digits, Snappy's own hot
                                 keys refused, `.unavailable` when the
                                 system refuses), SnappyHotKey (the four
                                 remappable hot keys: names, defaults,
                                 actions, each reserves the other three),
                                 HotKeyBindings (all four combos; conflict,
                                 resetRejection), menuKeyEquivalent,
                                 SettingsPaneFit (clamp + scroll
                                 when the pane is taller than the screen)
    SettingsWindowController.swift  Single-pane "Snappy Settings": pop-up path
                                 control, Capture area / Capture screen
                                 shortcut fields + Open Keyboard Settings,
                                 cursor checkbox, padding stepper + field,
                                 Recording section (RecordingSettingsSection,
                                 tab-ready, incl. the Window parts
                                 Accessibility status row + Open System
                                 Settings…) + HotKeyField (recorder + Reset +
                                 feedback hint, through GlobalHotKeys) +
                                 HotKeyRecorderButton; the pane
                                 is a scroll view's document; private
                                 SettingsWindow routes ⌘-shortcuts and hands
                                 key equivalents to a recording recorder first
  Capture/ScreenshotSaver.swift  ScreenshotNamer (PURE filename format + same-second
                                 index suffix — unit-tested) + non-overwriting PNG writer;
                                 generic placeWithoutOverwriting(named:) (the PNG path
                                 delegates to it, byte-identical) and
                                 copyWithoutOverwriting (recording Save: copies, the
                                 source is never touched) — tested

Tests/SnappyTests/               Swift Testing (NOT XCTest — CLT has no XCTest)
scripts/                         bundle.sh · install.sh · test.sh ·
                                 verify-bundle.sh · version.sh (sourced: git
                                 tag → version vars) · release.sh (tag + push) ·
                                 generate-icons.sh/.swift (icon pipeline)
assets/                          snappy-dynamic-s.png (icon source of truth) +
                                 generated/ (committed .icns + menu bar PNGs —
                                 regenerate only when the source changes)
```

```
Sources/Snappy/Recording/        Screen recording with live annotations
                                 (features/recording.md; invariants below)
  Foundation (T0)
    RecordingTarget.swift        PURE .area(globalRect, displayID) |
                                 .window(windowID, frame, displayID) |
                                 .windowPart(WindowPartTarget, displayID)
                                 (v2: window + window frame + part rect +
                                 name + live AX handle; `withFrame` = the
                                 part, `withWindowFrame` carries it along,
                                 `refreshedForRetake` (Q41), `wholeWindow`),
                                 AppKit global; display clamp — tested
    RecordingSession.swift       PURE state machine: setup(pointer|tool) ·
                                 snapping(kind, previous, returnTo) ·
                                 countdown · recording(interact|draw(tool)|
                                 magicPen(resume: tool?)) ·
                                 stopping · finished | cancelled; commands,
                                 events, outcome — every transition tested
    RecordingKeyMap.swift        PURE (phase, keyCode, chars, mods) → command;
                                 snapping: same S/W key → stepBack, the other
                                 switches, Return/keypad Enter → confirm (v2);
                                 Magic Pen = draw layer, [ ] → its
                                 thickness, F → nil; interact mode →
                                 always nil — tested
    RecordingSettings.swift      Every Settings → Recording option + defaults
                                 (SettingsStore keys/accessors) — tested
    RecordingTempStore.swift     ~/Library/Caches/com.tefa.snappy/Recordings/
                                 (prepareNewTake deletes nothing; prune/discard)
                                 + PURE RecordingTakeLedger (v2 take lifetime:
                                 open windows + the latest are kept) — tested
    RecordingContracts.swift     Ink vocabulary (InkTool/ColorPreset/Width/Style/
                                 Command, InkMode.magicPen, MagicPenLook —
                                 colour/alpha/halo/thinning, InkWidth
                                 .magicPenPoints), window levels, FrameDecorating
                                 (capture queue), the five component protocols,
                                 RecordingComponents factory
    RecordingCoordinator.swift   Owns ONE session; every input → RecordingEvent →
                                 session → push to pieces + side effects
                                 (countdown, pipeline, recording windows —
                                 owned in an array, take ledger — ⌃⌥D through
                                 SessionHotKeyRegistering + a banner when it's
                                 refused, focus hand-back, onCaptureStart for
                                 the menu bar clock; ⌃⌥P likewise, never the
                                 ⌃⌥D combo; setMagicPenWidth — persisted,
                                 pushed live); talks to the pieces only
                                 through the protocols;
                                 `RecordingComponents.current` builds the real
                                 ones (tests inject fakes)
  Setup overlay & snapping (T1)
    RecordingSetupOverlay.swift  Live non-activating panel on the target display
                                 (dimming, 8 handles, size chip, move/nudge/
                                 ⌥-arrow/scroll resize, drag-outside re-select);
                                 its key monitor maps Setup keys for every
                                 recording window; UI-free SetupTargetSync
                                 reports its own target corrections AFTER the
                                 coordinator's broadcast — tested
    SetupGeometry.swift          PURE clamp/min size (40 pt), move, nudge,
                                 ⌥-arrow resize, scroll resize, handle hit/
                                 resize, re-select, chip, display resolution —
                                 tested
    WindowSnapPicker.swift       S/W hover over windows on the target display:
                                 fresh SCShareableContent per snap visit;
                                 PURE WindowSnapCandidates (window or part →
                                 S area / W window / W windowPart) — tested
  Window parts (v2, V2)
    WindowPart.swift             PURE part picker: AX chain → levels (window
                                 first, then meaningful parts), automatic
                                 pick (edge band / title bar = window), ↑/↓/
                                 scroll override, names + chip, glide math;
                                 async latest-wins WindowPartTree seam;
                                 WindowPartElement (the live handle: an
                                 opaque Sendable token, async frame) —
                                 tested with fake trees
    WindowPartAccessibility.swift  WindowPartAXEngine — an actor on its own
                                 serial queue that owns every AXUIElement and
                                 all AX messaging (app-scoped hit test, cached
                                 walk, whole-query budget, per-visit
                                 quarantine, one handle per element, frame
                                 reads with backoff, tree switch + per-process
                                 restore ownership + retries); WindowPartAXTree
                                 (main-actor front: values in, values out);
                                 WindowPartAXMessaging seam (live:
                                 WindowPartLiveAX, timeout on every element;
                                 fake in tests); WindowPartAccess (trust,
                                 prompt once, session hooks); PURE
                                 WindowPartPermission / WindowPartAppKind /
                                 WindowPartSwitchLedger /
                                 WindowPartPendingRestores — tested
  Capture pipeline (T2)
    RecordingPipeline.swift      SCStream (Snappy excluded by app | desktop-
                                 independent window, cropped to a W + part's
                                 part by a live sourceRect) → FrameWriter
                                 actor on the capture queue → CoreImage copy
                                 + decorator → AVAssetWriter H.264 MP4; idle
                                 re-append; part poll ~10 Hz →
                                 PartCropUpdater (one updateConfiguration
                                 at a time, SCK behind a seam) — tested;
                                 PURE PipelineFailureGate; FrameCompositor
                                 seams
    PartCrop.swift               PURE W + part (v2 V3): PartCropGeometry
                                 (AppKit ↔ window-local top-left, sourceRect
                                 clamp + pixel grid + even sides),
                                 PartCropTracker (poll samples → crop),
                                 DecorationTarget (what a frame shows +
                                 the window ink anchors to),
                                 PartCropTimeline + FrameDecorationState
                                 (each frame's own crop; held mid-switch)
                                 — tested
    OutputGeometry.swift         PURE even video size (≤ 4096 px/side), area
                                 sourceRect, letterbox, content rect, bitrate,
                                 colour tags, FrameClock (slot grid: ≤ one
                                 frame per slot, captured vs idle) — tested
    WindowTracker.swift          W-mode window frame changes + "really gone"
                                 detection (30 Hz CGWindowList poll); PURE
                                 WindowTrackingState — tested
  Live ink (T3)
    LiveInk.swift                PURE ink model (strokes, setup vs recorded,
                                 fades, anchors, undo/redo/clear, pruning,
                                 setup snapshot, Magic Pen strokes) +
                                 immutable InkScene (render items with an
                                 optional underlay — the Magic Pen halo) +
                                 LiveInkFocus — tested
    RecordingCompositor.swift    InkRenderer (THE ink drawing path, via
                                 AnnotationRenderer) + RecordingCompositor:
                                 FrameDecorating (scene behind a lock) — tested
    LiveInkView.swift            On-screen ink canvas (same InkRenderer)
    LiveInkPanel.swift           LiveInkHosting: non-activating panel over the
                                 target at the ink level; key only in draw mode
  Chrome (T4)
    RecordingChrome.swift        RecordingChromeHosting: border panels (one per
                                 display segment), toolbar panel, countdown
                                 panel — never key, click-through except the
                                 toolbar; timer
    RecordingToolbar.swift       Glass toolbar view (incl. the Magic Pen wand
                                 toggle and the Area / Window snap buttons —
                                 phase-aware click mapping `command(phase:)`,
                                 a repeat click steps back) + PURE RecordingToolbarItem /
                                 RecordingToolbarState (enabled ⇔ the session
                                 would act) / RecordingTimerText (toolbar
                                 00:42, menu bar 0:42) — tested
    ChromeLayout.swift           PURE border ring, toolbar below → above →
                                 inside, countdown disc — tested
    CountdownView.swift          Glass countdown disc + PURE CountdownSequence
  Recording window (v2 V1; replaced the T5 preview panel)
    RecordingWindowController.swift  RecordingWindowHosting: one persistent
                                 titled Tahoe Glass window per take — player
                                 canvas (AVPlayerView, autoplay, AVPlayerLooper
                                 loop, muted) under a unified glass toolbar
                                 Retake · Save · prominent Copy + status
                                 capsule "W × H · 0:42 · [export-size slider]
                                 50 % · ≤ 4.6 MB" (takes the mouse);
                                 re-encode jobs with progress on the pressed
                                 button; RecordingWindow (window-level keys)
    RecordingWindowLayout.swift  PURE initial size, player fit, cascade origin;
                                 RecordingWindowStatus ("Recording W × H"
                                 title) — tested
    RecordingWindowAction.swift  PURE Space · R · ⌘S · ⇧⌘C/⌘C · [ ] ·
                                 Esc/Q/⌘W — tested
    RecordingExport.swift        Staged Save (hard link), Copy clone, pasteboard;
                                 RecordingSavedFiles (where each take was
                                 saved, per take AND export stop) + PURE
                                 RecordingExportSource (take · saved ·
                                 encoded · needsEncode) + RecordingExportCache
                                 (one re-encode per window, temp dir) — tested
    RecordingExportSize.swift    PURE ExportScale (25/50/75/100 % stops,
                                 [ ] stepping), ExportSizing (even-rounded
                                 output size, "≤" bound = OutputGeometry
                                 bitrate × max(duration, 1 s) × 1.5 + MP4
                                 overhead, read rounded up; fps snap),
                                 ExportSizeText (capsule readouts) — tested
    RecordingTranscoder.swift    Nonisolated AVAssetReader → AVAssetWriter
                                 re-encode at a smaller stop (writer scales,
                                 OutputGeometry.videoSettings, no audio),
                                 cancellable, partial file removed — tested
                                 on a synthetic take
    RecordingNamer.swift         PURE "Recording … .mp4" + " (2)" — tested
```

## Capture flow

```
⇧⌘4 (HotKeyCenter → captureArea(.hotKey)) or menu item (.menu)
  → [.menu only] 250 ms status-menu fade
  → CaptureEngine.snapshotAllScreens()  ← BEFORE anything of ours is on screen:
      an open context menu / menu-bar menu / tooltip is still there and lands in
      the pixels. No window, no makeKey, no activation may precede this
  → overlays orderFrontRegardless()  ← opaque backdrops cover the live screen
  → NSApp.activate()  ← only now; it dismisses that menu, which is fine — the
      menu is already frozen, and the user still sees it on the backdrop
  → drag on the frozen backdrop, or Esc cancels
  → CaptureGeometry.imagePixelRect → CaptureEngine.crop  (synchronous)
  → PreviewPanelController …

⇧⌘3 (→ captureFullscreen(.hotKey)) or menu item (.menu)
  → [.menu only] 250 ms fade → CaptureEngine.snapshot(of: screenUnderMouse)
  → PreviewPanelController …   (never activates — the panel is non-activating)

menu item → captureWindow   (unchanged: activates synchronously, then picks)
  → CaptureEngine (SCShareableContent → SCScreenshotManager) → CGImage

  → PreviewPanelController near the capture (anchor rect + screen travel
    with the result) — actions:
          Edit → EditorWindowController (annotation editor: rectangle/oval
                 highlights, arrows, lines, freehand pen, text labels,
                 blur/pixelate, counter badges, crop; select/move/resize/
                 delete, undo, Copy/Save)
          Copy → Clipboard.copy (PNG + TIFF, DPI = 72 × capture scale)
          Save → ScreenshotSaver → timestamped PNG in SettingsStore.saveDirectory
                 (never overwrites: temp file + exclusive link(2), ` (2)`, ` (3)`
                 on a same-second collision, falling back to moveItem on volumes
                 without hard links; creates the folder if missing)
          OCR  → TextRecognizer (Vision, EN+DE) → Clipboard.copy(text) +
                 UserNotifier banner ("Text Copied" preview / "No Text Found";
                 clipboard untouched when empty; one shared id, so each
                 result replaces the last; No Text Found beeps if undeliverable)
          Pin  → PinWindowController at the capture's position, 1:1
        Every action dismisses the panel; Esc / click-away dismiss without action.
```

## Recording flow

```
⇧⌘4 → drag (frozen, unchanged) → preview panel → R ─┐    menu "Record Area…" → frozen drag ─┐
                                                     ▼                                      ▼
  CaptureCoordinator → RecordingCoordinator.beginSession(target clamped to its display,
                       userApp = the app that was frontmost before any Snappy window)
  SETUP      overlay (setup level, key) + ink (ink level) + chrome (chrome level); ⌃⌥D registered
             S/W or toolbar Area/Window → snapping (WindowSnapPicker + WindowPartModel: window or part
             under the pointer; same key / the lit button back, other switches, click / Return confirms;
             first entry without Accessibility → the one-time prompt) · R → countdown (1 s ticks)
             · Esc / Cancel → cancelled
  RECORDING  RecordingTempStore.prepareNewTake (a new URL; deletes nothing)
             → pipeline.start(target, settings, ink.frameDecorator, url)
             overlay ordered out → activateUserApp (yield + activate): keys belong to the user's app
             ⌃⌥D / toolbar ↔ draw mode (ink panel key, Snappy NOT activated)
             ⌃⌥P / toolbar wand ↔ Magic Pen (same panel mechanism; back to interact or the draw tool)
             W target: pipeline.onWindowFrameChange → .targetChanged → ink + chrome follow
             W + part: SCK crops the window stream (window-local sourceRect); the part's visible AX
             frame is polled ~10 Hz → a new crop → updateConfiguration (one at a time, PartCropUpdater)
             + onPartFrameChange → .targetChanged
  STOP       ⇧⌘4 · toolbar ■ · menu bar ● · window really gone → stopping → activateSnappy()
             (inside the stop's interaction) → pipeline.stop() → finished(url) → every piece closed, ⌃⌥D unregistered,
             pipeline.endTracking() → AX tree switches restored (posted to the AX executor — the main thread
             never waits for it)
             → ledger.finished(url) + prune (unkept takes deleted) → a new RecordingWindowController,
             shown synchronously (frontmost, focus; the take's size/duration update it later, never focus)
  WINDOW     one per take, persistent, several coexist · Retake → (closes it) beginSession(same
             target, setup-ink snapshot, ink style), then the target is looked up again (Q41: the part's
             live frame, its whole window if gone, the window where it is now) · ⌘S copies to the Save folder (stays open) ·
             ⇧⌘C file URL + close · Q/Esc/⌘W/traffic light close → ledger.closed (take deleted
             unless it is the latest) · menu "Reopen Last Recording" fronts its open window
```

`AppDelegate` owns the `CaptureCoordinator`, the `StatusItemController`, and the
`HotKeyCenter`; the coordinator owns the preview panel, the pin collection, and
the **editor collection** (`editors`, like `pins`). The `RecordingCoordinator`
owns the **recording windows** the same way (`windows`, released in each
window's `onClose`, a run-loop turn after the close).

**Editor ownership.** An `EditorWindowController` is its window's only strong
owner (`isReleasedWhenClosed = false`; toolbar targets and document/canvas
callbacks are weak), so the coordinator keeps *every* open editor in an array —
a single `editor` slot silently killed the first session when a second opened.
The controller is its window's delegate and fires `onClose` from
`windowWillClose` (hopped one run-loop turn, because Copy/Pin close the window
from the controller's own methods), which is the one place the coordinator
releases it: Copy, Pin, Q, Esc and the traffic light all end up there. Closing
also clears `EffectRenderer`'s shared cache, which holds the base image alive.

**Capture and recording sessions never overlap.** Both gates come from the PURE
`CaptureActivity` (tested): the screenshot entry points use `blocksCapture` (the
pre-recording set plus a busy recording — running *or draining*), and
`RecordingCoordinator.canBeginSession` uses `blocksRecording`, which also waits
for a fullscreen capture or the post-pick window screenshot to deliver, so no
screenshot panel can land over recording Setup. Those two are tracked **one
token per request** (`PendingCaptures`, tested), never a per-kind Boolean: the
screenshot gates let a second ⇧⌘3 or window capture start while the first is
pending, and a Boolean would be cleared by the first completion. A late capture result while a
recording is busy is dropped (`dropsCaptureResult`). Inside the recording
coordinator every callback and async result is scoped to its session id, and a
cancelled/failed session keeps the coordinator busy until its pipeline's single
`stop()` has returned (the "draining" state) — see `RecordingCoordinator`.
The coordinator holds the active overlay
controller strongly and nils it in the completion callback. `captureSessionActive`
(`areaCaptureInFlight || areaSelection || windowPickInFlight || windowPick`)
gates every entry point: `captureArea` and `captureWindow` bail, `captureFullscreen`
bails with a beep (a preview opened under the `.screenSaver` selection overlay
would be invisible and would steal its key status). The two in-flight flags are
set *synchronously*, before the first `await`, because the overlay/picker only
exists once the freeze / content fetch returns — without them a double ⇧⌘4
starts two freezes and a ⇧⌘4 during a pending window fetch races it. This changes
no activation ordering.

## Invariants — do not regress

### Coordinate systems (the #1 source of bugs)

- **AppKit global**: origin bottom-left of primary display, y grows up
  (`NSScreen.frame`, `NSEvent.mouseLocation`, `NSWindow.convertToScreen`).
- **CoreGraphics / ScreenCaptureKit global**: origin top-left of primary
  display, y grows down (`SCWindow.frame`).
- **Frozen display snapshot**: a full-display `CGImage`. `CGImage.cropping(to:)`
  reads its rect in the image's own space — origin **top-left**, y **down** —
  which is exactly what `displayLocalRect(fromAppKitGlobal:screenFrame:)` already
  produces, so the area path contains **no second y-flip anywhere**.
  `CaptureGeometry.imagePixelRect(fromAppKitGlobal:screenFrame:scale:imagePixelSize:)`
  is that conversion × backing scale, with the four edges rounded independently
  (adjacent selections tile without seams) and the result **clamped to the
  image's pixel bounds**. The clamp is not cosmetic: a one-pixel overshoot at a
  screen edge makes `cropping(to:)` return nil.
- **`SCScreenshotConfiguration.sourceRect` is no longer used** — cropping a
  frozen snapshot replaced it. Captures always request a whole display or a
  whole window.
- ALL conversions go through `CaptureGeometry` (pure, tested). Never do inline
  coordinate math in UI code.
- Pixel output size = point size × `NSScreen.backingScaleFactor`, set via
  `SCScreenshotConfiguration.width/height`. Downstream (preview panel, pins) uses
  the image's **derived** scale from `FrozenScreen`, not the screen's backing
  scale — SCK's rounding can put them a step apart.

### Overlay windows (activation & events — fixed after real bugs, keep all of these)

Both overlay kinds are one borderless window **per screen** covering the screen's
frame, level `.screenSaver`, `collectionBehavior [.canJoinAllSpaces,
.fullScreenAuxiliary]`, `isReleasedWhenClosed = false`. **They are no longer the
same kind of window:** the area overlay is an `NSPanel` with `[.borderless,
.nonactivatingPanel]`, opaque, drawing a frozen snapshot; the window-pick overlay
is still a transparent `NSWindow`.

1. **Activation is granted, never assumed.** macOS activation is cooperative:
   `NSApp.activate()` only succeeds while the app still holds an activation grant
   from a user interaction.
   - **Window pick** activates *synchronously* inside the interaction, before its
     `await SCShareableContent`. Nothing may move that call later.
   - **Area capture deliberately activates AFTER an `await`.** That inversion is
     the whole point of frozen capture: activating first destroys the very
     context menu, menu-bar menu or tooltip the user is trying to capture. Three
     things make it safe and must stay together: (a) the awaited work is one
     usually-cache-served `SCShareableContent` lookup plus the display
     screenshots — tens of ms, well inside the grant window; (b) the overlay is a
     `.nonactivatingPanel` that takes key status via `makeKey()` **without** app
     activation, so Esc works even when activation is declined; (c) one deferred
     `!NSApp.isActive` retry 150 ms later.
   - **Order the overlays front BEFORE activating.** The opaque backdrops are
     then already covering the screen when the foreign menu is dismissed, so the
     dismissal is invisible. Activate-then-show flashes the live, menu-less screen.
   - **Nothing of ours may reach the screen before the freeze.** Not a window,
     not `makeKey()`, not a transparent one. Ordering a full-screen panel front
     and making it key cancels a foreign `NSMenu`'s tracking loop, so the menu is
     already gone when the snapshot is taken — the exact bug the freeze exists to
     prevent. Proven: ⇧⌘3 (atomic) captures the Apple menu correctly; a ⇧⌘4 that
     showed an overlay first did not. An "instant crosshair" pre-phase was built
     and reverted for this reason; a crosshair needs a window, and a window costs
     the menu. The only lever left on perceived latency is the warm
     `SCShareableContent` cache.
   - `NSApp.activate()` is still **required** for area capture: an open foreign
     `NSMenu` runs a modal tracking run loop that swallows mouse *and* key events
     regardless of window level (`.screenSaver` 1000 vs menu ~101). Only
     deactivating the owning app ends that tracking.
2. Views override `acceptsFirstMouse` → first click starts the drag (no
   "click to focus first").
3. Views use an `.activeAlways` `NSTrackingArea` (`.mouseMoved`,
   `.inVisibleRect` — `OverlayTracking.pointer`) so hover works before the
   window is key and while the app is inactive; the overlay under the mouse
   re-`makeKey`s itself on mouse-moved so Esc follows the cursor across
   displays, and re-sets the crosshair there. **Never add `.cursorUpdate` to an
   `.activeAlways` area** — NSTrackingArea.h: `.activeAlways` is "Not supported
   for NSTrackingCursorUpdate" (found by d-pin, 2026-10-08; the area overlay
   had exactly that combination). In the **area overlay**, cursor updates get a
   separate `.activeInKeyWindow` area (`OverlayTracking.cursor`); the window
   picker only uses the pointer area and has no cursor-update path.
4. Window overrides `canBecomeKey = true` (borderless windows refuse key status
   by default); the overlay under the mouse gets `makeKey`. The area panel also
   needs **`hidesOnDeactivate = false`** — `NSPanel` defaults to `true`, which
   would make the overlay vanish the instant focus moves — and
   `becomesKeyOnlyIfNeeded = false`.
   - It also needs **`animationBehavior = .none`**. `.default` makes AppKit infer
     `.utilityWindow` for an `NSPanel`, which fades the window in *and* out; over
     a full-screen frozen backdrop that reads as the screen pulsing on and off at
     both ends of a capture. `NSWindow` infers no animation, which is why this
     only appeared when the area overlay became a panel. Any future overlay
     `NSPanel` must set it.
5. Esc (`keyCode 53`) cancels via the view's `keyDown` **plus** a local
   `NSEvent.addLocalMonitorForEvents(.keyDown)` fallback in the controller
   (removed in `finish`). Inspect `NSEvent` **outside** `MainActor.assumeIsolated`
   — `NSEvent` is explicitly non-Sendable. Note what that monitor is *not*: a
   local monitor only sees events already routed to our app, so it covers "the
   wrong overlay is key", **not** "the app is not active" — that case is covered
   by the non-activating panel.
6. `finish(with:)` is idempotent (`finished` flag), orders each overlay out and
   **then** releases its backdrop image (`layer.contents = nil`) — emptying the
   layer of a window still on screen can composite a frame of bare background —
   removes the monitor, then calls the completion exactly once.
7. **The overlay paints nothing until the drag starts, and then only *inside*
   the selection** (`selectionTint`, black @ 0.12, plain source-over). Two rules
   hang off that and both were bugs once: never punch transparency with
   `fill(using: .copy)` — over the opaque frozen backdrop it erases the snapshot
   rather than revealing anything — and never dim the surroundings. A screen that
   greys the instant the overlay appears announces the freeze; leaving it
   untouched is what makes the still image read as the live screen. (This
   replaced full-screen dimming *and* the `CaptureGeometry.dimmingRects` bands
   that replaced the `.copy` punch-out; both are gone.)
   - **The overlay draws what the crop will take, not the raw drag rect**:
     `CaptureGeometry.capturedSelection` runs the drag through the crop's own
     `imagePixelRect` and maps the rounded, clamped pixel edges back to points,
     so the tint, edge and size readout sit on snapshot-pixel edges and an empty
     capture draws nothing. `onSelect` still receives the raw rect — the crop
     path is unchanged.
   - **One selection edge for both overlays** (`OverlayChrome.strokeEdge`): 1 pt
     white against the target + 1 pt black @ `OverlayGeometry.edgeShadeAlpha`
     (0.6) outside it — ≥ 3:1 against any *uniform* sRGB backdrop (a test-locked
     calculation, not a promise about busy content). Sides touching the
     overlay's bounds (screen-edge selection, maximised window) fold inward
     instead of clipping away. A single white or
     accent line drops to 1:1 on white / on blue. Fixed white/black is
     deliberate: the chrome sits on screenshot pixels, not app chrome. Chip
     placement lives in `OverlayGeometry` (pure, clamped) — no layout maths in
     the views.
8. **The backdrop view is the content view; the selection view is its subview.**
   A layer-backed view's `draw(_:)` output *replaces* `layer.contents`, and a
   sublayer would composite *above* the tint — so the image cannot live on the
   selection view. It also keeps the full-display image in a compositor layer
   that never redraws: `mouseDragged` invalidates the whole selection view, and
   re-blitting 20 MP per drag event would be unusable.

### Capturing

- **Exclude Snappy by application, not by window list**:
  `SCContentFilter(display:excludingApplications:exceptingWindows:)` with our own
  `SCRunningApplication`. A window list is a snapshot of one moment; a pin,
  panel, editor or status-bar menu opened after the (cached) content fetch would
  not be in it and would be baked into the capture. `SCRunningApplication`
  identity survives that churn. The per-window PID filter remains only as a cold-
  start fallback for when we have no on-screen windows yet. Window-pick
  candidates still filter by PID plus `windowLayer == 0` and `isOnScreen`.
- **`SCShareableContent` is cached and kept warm.** Fetching it costs 50–150 ms,
  and for area capture that cost sits between the hot key and the freeze — the
  window in which macOS still grants cooperative activation. Served only when our
  PID is present and every current `NSScreen` maps to a listed display **whose
  width/height equal the screen's frame size** (a resolution / "More Space"
  change keeps the display ID but the snapshot is requested at the cached
  `SCDisplay`'s size); dropped outright on `didChangeScreenParametersNotification`.
  - **Generation counter.** Invalidation bumps `cacheGeneration`; a fetch remembers
    the value before it awaits and only caches if it is unchanged afterwards, so a
    warm-up already in flight when the display changed cannot re-install
    pre-change displays.
  - The 5-minute lifetime is a **safety net, not the mechanism**. Freshness comes
    from re-priming on `NSWorkspace` app activate / launch / terminate —
    debounced (`reprimeThreshold`, and one warm-up in flight at a time) so a
    burst of app switches is not a burst of SCK round-trips.
  - Long-lived caching is safe **only because self-exclusion is
    application-based**: the area path reads nothing out of the content but
    `displays` and our own `SCRunningApplication`, both validated on read. A
    window-list-based exclusion would bake our own panels into the shot. Window
    *pick* mode therefore still fetches fresh — it genuinely needs the list.
  - Priming is a **no-op until `hasCompletedFirstCapture`** (set by
    `noteCaptureSucceeded()` the first time SCK actually returns pixels).
    Unconditional priming — at launch or on an app switch — would move the Screen
    Recording prompt to login, before the user asked for anything.
- **Area capture no longer sleeps.** The 100 ms compositor wait existed because
  the shot was taken after the overlays closed; the freeze happens before any
  overlay exists. The 100 ms wait remains for window capture, and the 250 ms
  menu-fade wait remains for `.menu`-triggered captures (Snappy's own menu).
- **`CGImage.cropping(to:)` shares the parent's buffer.** A small selection would
  pin the whole ~30–80 MB display snapshot in memory for as long as the crop
  lives — and it lives in the preview panel, then possibly a pin, indefinitely.
  `CaptureEngine.crop` re-renders into a fresh, tightly packed context
  (preserving the source's colour space and bit depth) to detach it — except when
  the selection is the whole snapshot, which pins nothing extra and is returned
  as-is (no 30–80 MB copy).
- `NSScreen` ↔ `SCDisplay` matched via
  `deviceDescription["NSScreenNumber"]` == `SCDisplay.displayID`
  (`CaptureEngine.displayID(for:)`); a screen with no matching display is skipped,
  and an empty result throws `.noMatchingDisplay`.
- `SCShareableContent` windows are ordered front-to-back — first hit wins for
  hover picking. `WindowPickController.updateHighlight()` returns early while the
  hovered window ID is unchanged, so a mouse move over the same window doesn't
  invalidate every full-screen overlay.

### Frozen-screen area capture

- The snapshots are taken **before** activation and **all-or-nothing** across
  displays: a failure on any display propagates rather than leaving a mix of
  frozen and unfrozen overlays, so the selection overlay has exactly one drawing
  path. A freeze that throws shows **no overlay at all** — there is deliberately
  no live-transparent fallback, and the permission alert is never behind a
  full-screen panel.
- **One overlay per frozen screen, never per `NSScreen`.** Every overlay must
  have a backdrop and the set must match what was captured — which is free here,
  because the panels are built from the snapshots.
- `FrozenScreen` carries the screen's AppKit-global frame **at freeze time**. The
  overlay size, the backdrop's 1:1 point mapping and the crop math all use that
  frame, never a re-read `screen.frame`, so they cannot disagree mid-selection.
- The backdrop is `layer.contents` with `contentsGravity = .resize`,
  `contentsScale` = the snapshot's derived scale, and `.nearest` filtering. Layer
  bounds (points) × `contentsScale` == image pixels, so `.resize` is a straight
  blit. `viewDidChangeBackingProperties()` must re-assert `contentsScale` —
  AppKit resets it to the window's backing scale on its own schedule.
- Per-display snapshots run as **main-actor `Task`s awaited in order**, not a
  `withThrowingTaskGroup`: `SCContentFilter` is neither `Sendable` nor
  region-transferable, so it cannot cross an isolation boundary (Swift 6 rejects
  `sending` here). The round-trips still overlap — each `await` inside SCK
  releases the main actor for the others.
- Snappy's own panel/editor/overlays/menus are excluded from the snapshot, so
  the backdrop shows what is *behind* them and the capture matches the backdrop
  pixel-for-pixel. **Open pins are the one exception** (2026-10-14): they are the
  user's own content, so a capture can include one. Pins register their
  `windowNumber` in `PinWindowRegistry` (Capture/PinInclusion.swift) while open;
  the filter is `excludingApplications: [ownApp], exceptingWindows: pins`. SCK
  can only except windows it lists, so `CaptureEngine.contentKeepingPins`
  refetches `SCShareableContent` once when an open pin is missing from the warm
  cache (pure `PinInclusion.needsFreshContent`) — only while pins exist. The
  same applies to ⇧⌘3 and to area-target recording (a pin opened *during* a
  recording is not picked up; the filter is fixed at start). Windows pinned
  by `captureWindow` are unaffected (`desktopIndependentWindow`).

### Preview panel & pins (M2)

- The preview panel's glass uses **concentric corners** (Tahoe Glass): glass
  radius 18 pt, preview image radius 8 pt (= 18 − the 10 pt inset), continuous
  curve. The 10 pt inset comes from an **inset container** around the content
  stack, never from `stack.edgeInsets`: a vertical `NSStackView` with
  `.centerX` alignment drops its left/right edge insets (the image sat flush
  against the glass until 2026-10-09).
- The preview panel is an `NSPanel` with `[.borderless, .nonactivatingPanel]`,
  level `.floating` — it takes key status via `makeKey()` **without activating
  the app** so the frontmost app keeps focus; `hidesOnDeactivate = false`.
- Panel actions are **borderless `.toolbar`-style icon buttons (SF Symbols)**,
  pinned to 32×28 pt (`.toolbar` ignores `controlSize`; HIG default macOS
  control size is 28 pt) with 8 pt spacing — no bezel boxes stacked on the
  glass. Tooltips keep the app-wide "… (KEY)" suffix but lead with a verb
  phrase instead of the button name (`PreviewAction.toolTip(saveFolderName:)`,
  e.g. "Save PNG to Desktop (S)"). Because the panel is key, the single letters E/C/S/O/P
  trigger Edit/Copy/Save/OCR/Pin from the keyboard (handled in the panel's
  `keyDown`, next to Esc). **Q dismisses like Esc** — panel and pin windows
  both (shortcuts-first rule — see the shortcuts feature doc via
  `docs/FEATURE_MAP.md`).
- Click-away dismissal needs **two** monitors: a global mouse-down monitor
  (clicks in other apps — global monitors never see our own events) plus a
  local one filtered on `event.window !== panel`. Both removed on close;
  `close()` is idempotent (`closed` flag). Inspect `NSEvent` outside
  `MainActor.assumeIsolated` (non-Sendable).
- All panel placement math is in `PanelGeometry`, all pin zoom/resize math in
  `PinGeometry` — pure and unit-tested; never inline geometry in UI code.
- Anchor rect (AppKit global) + screen travel with every capture result; Pin
  re-uses them to appear exactly over the captured area (top-left aligned).
- Pins use `window.performDrag(with:)` for moving (not
  `isMovableByWindowBackground`) so the bottom-right 16 pt corner can be
  reserved for aspect-locked resizing; scroll-zoom anchors on the cursor.
- Pins **retain their `CGImage` + backing scale** (not just `layer.contents`)
  and get `onEdit`/`onCopy` closures injected by the coordinator alongside
  `onClose`. The hover toolbar (Liquid Glass `NSGlassEffectView`, top-left) has
  Close·Edit·Copy: Copy keeps the pin open; **Edit closes the pin and routes
  through the coordinator's `openEditor(image:scale:)`** — the same path as the
  panel's Edit, so editor → ⌘P re-pins correctly. One `.inVisibleRect` tracking
  area (+ `.mouseMoved` for the corner's diagonal-resize pointer) covers pin +
  toolbar (no enter/exit churn); a **second** `.activeInActiveApp`
  `.cursorUpdate` area feeds `cursorUpdate(with:)` — `.cursorUpdate` is not
  supported with `.activeAlways` (`NSTrackingArea.h`). A secondary-click /
  Control-click context menu (Edit · Copy | Close) is the mouse route on pins
  too small for the toolbar. Toolbar buttons follow the panel's convention
  — borderless `.toolbar` style, **28 × 28 pt**, 4 pt apart — with their
  symbol/tooltip/key from `PinAction`. **The glass's stack needs an explicit
  height:** a horizontal `NSStackView` ignores its top/bottom `edgeInsets` and
  the glass collapsed to 10 pt. The toolbar is `isHidden` (not just alpha 0 —
  alpha-0 views still hit-test) when `PinGeometry.toolbarFits` fails in either
  dimension. Hover alpha is 0.9 (subtle), 1.0 under Reduce Transparency. Pin
  keys E/C (bare, `ShortcutKeys.isBareKey`) require the pin to be key — click
  it first.
- The Carbon hot keys (`RegisterEventHotKey`) swallow ⇧⌘4 and ⇧⌘3 system-wide;
  the menu items' key equivalents are display-only. `HotKeyCenter`'s C callback
  gets `self` via `Unmanaged` userData and hops onto the main actor with
  `MainActor.assumeIsolated` (hot-key events dispatch on the main thread).
- **One `HotKeyCenter` owns every binding.** `InstallEventHandler` targets the
  process-wide dispatcher, so a second center installs a second handler on the
  same target; Carbon calls the most recently installed one first and stops as
  soon as it returns `noErr`. Two centers would silently route *both* hot keys to
  whichever registered last. Hence: one handler, and the event's `EventHotKeyID`
  (read with `GetEventParameter`, `kEventParamDirectObject`) selects the action.
  `HotKeyAction` ids are stable and must never be reused or reordered; the
  signature is a `nonisolated static let` because the C callback cannot touch a
  `@MainActor`-isolated static. `register` unregisters an action's existing
  Carbon ref first, and an `isolated deinit` unregisters every ref and removes
  the handler (which holds an unretained pointer to the center).
- **Remapping goes through `GlobalHotKeys`, never straight to `SettingsStore`**
  (2026-10-20). A combo is saved only after it was bound: `replace` acquires
  the new combo **before** releasing the old one (Carbon allows two refs under
  one `EventHotKeyID`), so a refusal leaves the old binding untouched and
  there is no rollback that could itself fail; session keys are rebound by
  `RecordingCoordinator.rebindSessionHotKey` mid-session (or probed with
  `isAvailable` outside one), so the store never holds a combo that doesn't
  work and a refusal leaves the old one live. The availability probe uses its
  own `HotKeyAction.availabilityProbe` id (never left registered) — still the
  one center and handler. While a Settings recorder waits for a key the center
  is **suspended** (every Carbon ref released, registrations kept): otherwise
  Carbon would swallow ⇧⌘4 and start a capture instead of the recorder
  refusing it. An accepted combo is bound **while still suspended** — a
  suspended `replace` / `retry` is the real bind — and only then do the rest
  resume, so the answer is never a guess. **Recording always ends**, however
  the window goes: `SettingsWindow` cancels it in `close()` (which keeps the
  first responder and never calls `resignFirstResponder`), `resignKey()`, on
  `NSApplication.didResignActiveNotification`, with `windowWillClose` as a
  backstop — otherwise every hot key would stay paused for the session.
  **A registration is never silently dropped:** one the system refuses (at
  launch, or on resume because another app took the combo during the pause)
  keeps its combo, unbound (`HotKeyCenter.unboundActions`); Settings shows
  "That shortcut is already taken — <name> is off …" under the field
  (`GlobalHotKeys.isLive`), Reset stays enabled, and it is retried when
  Settings becomes key, when the app becomes active, and when the same combo
  is recorded again. Every place that names a hot key reads the live combo
  (menu key equivalents in `validateMenuItem`, the recording ● menu's Stop,
  the ●'s tooltip — set on entering recording and updated by `onChange` —,
  the toolbar's Stop tooltip via `setStopShortcut`, the Settings fields).
- **Hot key labels follow the keyboard layout; key codes don't.** A
  `HotKeyCombo` stores the virtual key code (the physical key — what Carbon
  binds and what the recorder receives as `NSEvent.keyCode`). Its label comes
  from `KeyLegend`: the current input source's layout via `UCKeyTranslate`
  (unshifted, then shifted for AZERTY digits; ASCII letters/digits only, else
  the US name — as macOS does on non-Latin layouts). The TIS API aborts off
  the main thread, so only the main thread reads it (elsewhere: US). On
  `kTISNotifySelectedKeyboardInputSourceChanged` the AppDelegate clears the
  cache and `GlobalHotKeys.keyboardLayoutDidChange` re-announces all four
  combos, so Settings, the ● tooltip and the toolbar re-label.

### Annotation editor (M4–M6)

- Annotations live in **image-pixel coordinates, origin bottom-left** (CG
  convention), rects always standardized. The canvas view is unflipped, so
  there is not a single y-flip anywhere in the editor **except one**:
  `AnnotationDocument.crop` converts to `CGImage.cropping`'s top-left rect —
  that flip lives there and nowhere else. Style lengths (strokeWidth) are
  image pixels too; the UI converts pt × capture scale.
- **Auto-expanding canvas (Post-MVP M-F): the canvas rect is DERIVED, may have
  a negative origin, and holds NO undo state.** The base image always sits at
  image-space `(0, 0)`; `CanvasGeometry.canvasRect` = image bounds expanded
  per-side to contain every annotation's `expandedBounds` (painted extent) plus
  `SettingsStore.canvasPadding × scale`, growing *and* shrinking as a pure
  function of the annotations. **Growth is capped** per side at
  `max(image width, image height, 4096)` px (`CanvasGeometry.maxExpansion`) so
  repeatedly dragging an annotation outward can't grow the canvas — and the
  export bitmap — without bound. Annotations are NOT re-based on expansion (that
  would mutate every annotation per tick). Exactly **two** places consume the
  canvas origin: view↔image conversion (`AnnotationGeometry` `contentRect:`
  variants — the `imageSize:` ones are zero-origin wrappers) and export
  translation. The canvas view computes its live rect from `layoutAnnotations()`
  (document + draft → live expansion; **includes the label being edited**, which
  is only hidden from *painting* via `renderedAnnotations()` — otherwise editing
  an out-of-image label would shrink and refit the canvas under its text field)
  under a **gesture ratchet** (during a drag
  the effective rect = `union(rectAtMouseDown, liveRect)`, grow-only, released
  on mouse-up) to kill fit-scale oscillation. **The on-screen transform is also
  frozen for the duration of a drag** (`gestureViewTransform`: image→view scale
  + image-origin position captured at mouse-down): while dragging, the base
  image keeps its size/position and the canvas grows *around* it (extending past
  the window, clipped), then the view re-fits the final canvas once on mouse-up.
  Without this freeze the view zoomed out live as the canvas grew, and because
  the mouse→image mapping uses that same shrinking scale, each drag step mapped
  further out — a feedback loop that made expansion accelerate away and shrink
  the original image to nothing. Newly exposed area is filled by
  `CanvasBackground` with **one uniform color** detected from the screenshot
  perimeter (dominant-cluster of low-variance, corner-weighted windows —
  the earlier per-edge smear was rejected after manual testing;
  cached per image, invalidated on crop). Detection rasterises **only the four
  perimeter bands** (cropped out of the image), never the whole bitmap, and
  export samples the background only when the canvas actually grew. Crop stays
  clamped to `imageBounds`; all other tools are unclamped. Details:
  `features/canvas-expansion.md`.
- **Per-draw / per-event layout snapshot** (`layoutSnapshot`): `canvasRect` and
  `fittedFrame` are expensive (a map over all annotations, CoreText measuring
  for labels) and every conversion helper reads both. `draw`, `mouseDown` (after
  its text commit), `mouseDragged` and the cursor refresh therefore compute the
  `(canvas, frame)` pair once, store it for the duration of that one call, and
  clear it on return. It is **never** a persistent cache — nothing can go stale
  across a document, draft, bounds or settings change — and it computes through
  the same ratchet / frozen transform. `mouseUp` does not snapshot (it mutates
  the document mid-handler). `TextGeometry.font(ofSize:)` caches `CTFont`s
  behind a lock.
- The canvas draws annotations by scaling the CGContext and calling
  `AnnotationRenderer` — the **same code path as export**, so the canvas is
  pixel-identical to what Copy/Save produce. Never draw annotations with
  separate view-space code. **Export = `flatten(image:annotations:canvasRect:
  background:)`**: an output context sized to `canvasRect`, the background
  filled full-res, image space translated by `−canvasRect.origin`, then the
  base image at `imageBounds` and the annotations — so Copy/Save/Pin embed any
  canvas expansion (a pinned expanded shot reopened for editing carries it baked
  in). The old `flatten(image:annotations:)` is a wrapper (canvasRect = image
  bounds, no background) → byte-identical to the pre-M-F path. The uniform
  background is a plain `setFillColor` + `fill` in both the canvas and `flatten`
  (no intermediate bitmap; the colour stays sRGB-tagged). `flatten`'s output
  context uses the **base image's colour space** when it is an RGB one a bitmap
  context supports (a Display P3 capture stays P3 through the editor), else sRGB.
- **Every export commits first.** A label still being typed lives only in the
  overlay `NSTextField`; `EditorWindowController.flattenedImage()` (the single
  path for Copy/Save/Pin, toolbar and keys) calls the idempotent
  `canvas.commitPendingEdits()` before reading the document. A style change while
  typing (`apply(style:)`) updates the live field and is applied to the label on
  commit. The field is positioned by `layoutTextField()` from an image-space
  anchor, so it also follows window resizes.
- **Style controls always describe something.** With a selection they mirror its
  *current* value (re-synced on every document change, so undo/redo of a restyle
  updates them); with none, they show `canvas.currentStyle` — what the next
  annotation will use. That includes the initial state: the controls are
  synced from the creation style at init, never seeded with their own values
  (`.systemRed` once leaked an appearance-dependent red into annotations).
- `Annotation` is an **enum, not a protocol**: value semantics make whole-value
  snapshots the undo currency and let tests compare states with `==`. New
  tools (M5/M6) add cases.
- **One undo step per user gesture**: `AnnotationDocument` uses
  `groupsByEvent = false` and wraps each mutation in an explicit undo group,
  so undo behaves identically in the app and in run-loop-less tests. Drags
  mutate a canvas-local *draft* and commit a single `replace(id:with:)` on
  mouse-up — never call document mutations per mouse-dragged event.
  **Undo/redo shows its result:** when a step brings back or changes exactly
  one annotation (`AnnotationDiff.soleChangedID`), the canvas selects it
  (`documentDidChange`, checked via `undoManager.isUndoing/isRedoing`; never
  while a label is being typed). A step that swaps the image (crop) or
  touches none or several annotations **clears** the selection
  (`AnnotationDiff.selectionAfterUndo`) — a crop offsets every annotation,
  so a lone survivor is not "the result".
- **Selection handles: one hit-test for hover and mouse-down**
  (`selectionHandle(at:)`): a 7 pt core always grabs the handle; the 10 pt
  ring (20 pt target, HIG macOS minimum) only where the point is not on an
  annotation body (`AnnotationGeometry.arbitrateHandle`), so small
  selections keep a body to move.
- The editor has **one unified header**: the window is
  `titleVisibility = .hidden` with an `NSToolbar` (`.unified` since the
  2026-10-08 HIG pass — 52 pt bar, 36×36 pt system items; `.unifiedCompact`
  gave 24 pt items, below the HIG 28 pt default), so the traffic lights and all
  controls share the titlebar. Never add a second bar below the titlebar.
- **Tahoe Glass (2026-10-08): the canvas runs under the glass toolbar.** The
  window has `.fullSizeContentView` + `titlebarAppearsTransparent`, and its
  contentView is a plain container holding the canvas (filling it) plus one
  passive Liquid Glass **status capsule** at the bottom centre
  ("Shot W × H · 100%", `EditorStatus`; `hitTest` returns nil so drawing works
  underneath). The canvas therefore **fits the capture into
  `AnnotationGeometry.fitArea`** — `window.contentLayoutRect` converted to view
  space (the unobscured area below the toolbar) minus `bottomInset` (the
  capsule band) — never into raw `bounds`; both the live fit and the drag's
  frozen transform use it. The backdrop is drawn over the full bounds: an
  appearance-dynamic vertical wash (light `#F7F8FB→#E3E6EC`, dark
  `#2A2B2F→#1B1C1F`) plus a shadow cast by the fitted frame **but clipped to
  outside it** (even-odd clip, no transparency layer — so transparent window
  corners never show a dark rect and drags stay cheap). The zoom readout
  refreshes on document change and on `onViewportChange` (canvas resize). The hidden title is still read by
  VoiceOver and Mission Control, so it names the capture (`windowTitle`,
  "Shot 1440 × 900"), never the app, and is recomputed on every document
  change (crop). The Save tooltip is re-rendered on `windowDidBecomeKey`, so
  it names the folder Save will actually write to.
- **Toolbar = one item per action, never a monolithic segmented control**
  (Tefa's 2026-07-18 feedback — a segmented control can't overflow and
  crowded everything out). Buttons are image-based `NSToolbarItem`s
  (`isBordered = true`, small smooth symbols via
  `NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)`), so
  NSToolbar's native "…" overflow menu absorbs what doesn't fit (items stay
  clickable there, labeled) and returns items when the window grows. Groups
  in order (Tahoe Glass, 2026-10-08): **Undo·Redo** | primary tools
  **Select·Arrow·Text·Rectangle·Blur·Counter** + remaining tools
  Oval·Line·Pen·Pixelate·Crop | color/width/fill | **Save·Pin·Copy** at the
  trailing edge, Copy with `NSToolbarItem.style = .prominent` (accent-tinted,
  on its own platter — the HIG's "done" position).
  `visibilityPriority` keeps the export group + primary tools visible
  (.high) while the rest overflow first; undo/redo are .low (they have key
  equivalents). Tool items are **selectable** (`toolbarSelectableItemIdentifiers`
  radio behavior); keyboard tool switches sync `selectedItemIdentifier`.
  Undo/redo enablement runs through `NSToolbarItemValidation` +
  `validateVisibleItems()` on document change. `minSize` (700 pt wide)
  guarantees the primary groups are visible; the **initial** width floor is
  `fullToolbarWidth` (960 pt, clamped to the screen — measured: everything fits
  from 940 pt), so no item starts in the overflow menu (HIG). Re-measure it
  when items are added or restyled.
- **Style controls are custom-view items** (`NSColorWell` `.minimal`,
  `NSPopUpButton` and the fill toggle with `.toolbar` bezels — no bezel boxes,
  no `controlSize` pins: NSToolbar sizes view items itself). Each one needs an
  explicit `menuFormRepresentation` (Color… / Size ▸ / Fill), because AppKit's
  default for a view item is a stateless label; the menu forms drive the same
  controls and `validateMenuItem` mirrors their state (and disables an
  overflowed Undo/Redo). On macOS 26 every custom-view item gets **its own
  glass platter** (an `NSToolbarItemGroup` does not merge them) — only
  image-based items share one.
- **Editor alerts are sheets** (`beginSheetModal(for: window)`), never
  `runModal()`, which froze every pin and every other editor.
- **Pin from the editor** (⌘P, toolbar Pin): flattens like Copy, hands the
  image + a frame centered over the editor window to the coordinator's
  shared `pin(image:frame:)`, then closes the editor — Pin and Copy are the
  "done" actions.
- The app has no main menu (`LSUIElement`), so ⌘Z/⇧⌘Z/⌘C/⇧⌘C/⌘S are handled in
  the canvas's `performKeyEquivalent`; Delete/Esc/Q plus the single-letter
  tool shortcuts **V/R/O/A/L/P/T/N/B/X/C** (select/rectangle/oval/arrow/line/
  pen/text/counter/blur/pixelate/crop) in `keyDown`. While an in-place text
  field is active, `performKeyEquivalent` defers everything to the field
  editor. Tool switches and window-close flow canvas → controller
  via `EditorCanvasCommand` (`selectTool` / `close`) so the toolbar picker
  stays in sync. **Q closes the editor; Esc deselects first and closes when
  nothing is selected.** The canvas must be first responder — the controller
  restores that after toolbar clicks.
- Toolbar controls are **icon buttons (SF Symbols) with tooltips** in the
  app-wide form "<verb phrase> (SHORTCUT)", sentence case, never just the
  control's name (e.g. "Draw an arrow from tail to head (A)", "Copy and close
  (⇧⌘C)"); the text lives in `ToolSpec.help` / `EditorAction.toolTip`, both
  unit-tested. The advertised Copy shortcut is **⇧⌘C** (plain ⌘C also works),
  and **Copy closes the editor window** — it's the "done" action (Tefa's
  feedback).
- Rectangles render with **slightly rounded corners**:
  `AnnotationGeometry.rectangleCornerRadius` (2 × strokeWidth, clamped to a
  quarter of the smaller side). Hit-testing stays rect-based — the tolerance
  band covers the rounding.
- **Arrows (M5, curved in Post-MVP M-D)** are tail→head endpoint pairs plus a
  scalar **`bow`** (image pixels), rendered as ONE filled tapered polygon via
  `ArrowGeometry.polygon` — thin at the tail, thickening to 2.0 × strokeWidth
  *visible* width at the head end (polygon 2 × 0.85 + rounding stroke 0.3),
  flaring into the filled arrowhead (deliberate "ergonomic" look; `hasFill`
  does not apply). **Edges are rounded** by stroking the polygon with a
  same-color round-join/round-cap stroke of `ArrowGeometry.edgeRounding`
  (0.3 × strokeWidth); the polygon's half-widths are tuned with that outset
  already subtracted — change them together or the visible widths drift.
  **The bend is the scalar `bow`** — signed perpendicular offset of the curve
  midpoint from the chord midpoint (quad-Bézier control point `M + 2·bow·n̂`),
  NOT a stored control point: endpoint drags preserve the bend, `bow == 0` is
  literally straight (the polygon short-circuits to the exact 7-point M5
  construction), and the arrowhead sits on the curve's **end tangent**.
  Drawing spawns the arrow at the mouse-down point (tail) and drags the head.
  A selected arrow shows **three handles**: two round endpoint handles plus a
  distinct accent-filled bend handle at the curve midpoint (lines: two, no
  bend); endpoint drags set the endpoint from the cursor position directly,
  bend drags project onto the chord normal only (1 DOF) and snap to `bow = 0`
  under 4 image px (`ArrowGeometry.snappedBow`). `Annotation.withRect` is a
  documented no-op for arrows — rect-resizing does not apply; whole-arrow
  moves clamp via the bounding rect (analytic curve extrema, contains the
  bulge) so the shape never distorts.
- **Tool-aware cursor (Post-MVP M-E): exactly one system owns the pointer.**
  With `SettingsStore.toolAwareCursorEnabled` (default ON) the canvas's
  tracking area + `mouseMoved` set the cursor (pure decision in
  `CursorGeometry`, cached cursors from `ToolCursorFactory`, `set()` only on
  kind change) and `resetCursorRects` registers **nothing**; with the setting
  OFF, cursor rects provide the plain crosshair/I-beam behavior. Registering
  both causes flicker — never mix them. AppKit re-decides the pointer on its
  own (toolbar redraws, subview changes, rect invalidations) and lands on the
  arrow when no rects are registered, so the canvas MUST participate via a
  `.cursorUpdate` tracking area: `cursorUpdate(with:)` re-asserts the correct
  cursor unconditionally (super only when the feature is OFF). Never call
  `invalidateCursorRects` while the feature is ON (real bugs, found via
  keyboard tool switching). No cursor recompute during drags or
  while the in-place text field is active — the one exception is the
  pressed state set at mouse-down (`CursorGeometry.pressed`: open hand →
  closed hand for a move), and mouse-up always re-decides the cursor; the setting is read per mouseMoved
  (no notification plumbing). The badge symbol/label come from
  `EditorWindowController.toolSpec(for:)` so cursor and toolbar can't drift.
  Details: `features/tool-cursor.md`.
- **M6 tools** — hard-won rules:
  - `Annotation.withRect` resizes **shapes and effect regions only**; text/
    freehand/counter sizes derive from content + style, arrows/lines from
    endpoints. All types implement `offset(by:)` (unclamped) — `moved` clamps
    via the bounding rect, crop remaps with it.
  - **strokeWidth is the single size knob**: text font size
    (`TextGeometry.fontSize` = 6×, floor 8) and counter badge radius
    (`CounterGeometry.radius` = 3×, floor 8) derive from it, so the width
    popup controls them and no extra model state exists.
  - **Counter numbers are NOT stored** — they derive from the badge's order
    among counter annotations (`CounterGeometry.numbers`), so delete
    renumbers and undo restores numbering for free. Never store a number.
  - **Lines reuse `ArrowAnnotation`** with `kind: .line` (plain round-cap
    stroke, no polygon) — same endpoint handles, drag mechanics, and model.
  - **Blur/pixelate need the base image**: `AnnotationRenderer.draw` takes
    `base:` (defaulted nil = effects skipped); canvas and flatten pass the
    document image. CoreImage shares the model's bottom-left convention, so
    effect rects map to CI extents **without flipping**; effect strength
    derives from the image size **and the region's short side**
    (`EffectRenderer.blurRadius/pixelScale(imageSize:region:)`; the 40/64 px
    caps limit only the region term, not the total), not from style. Blur and
    pixelate **obscure, they don't redact** — the output is still derived from
    the source pixels, and no general guarantee is made. The region term exists
    because image size alone let Vision OCR read the text back on small
    captures (design review `docs/design-reviews/editor-canvas.md` C1);
    `EffectRedactionTests` re-runs the measured cases — don't weaken the
    formula without it staying green. Guaranteed redaction would need an
    opaque fill tool (deferred, Tefa's call). Results are
    memoised in `EffectCache` (≤16 entries / 192 MB, LRU, keyed by base-image
    identity + kind + integral region; entries hold the base image so the
    identity can't be recycled), shared by canvas and export, and cleared when
    the document image changes (crop / undo-crop) and when an editor closes.
  - **Text editing** is an `NSTextField` overlay on the canvas (system UI
    font — the same family `TextGeometry` measures/renders, so WYSIWYG).
    Enter/click-away commit (one undo step; emptied existing label = remove),
    Esc cancels via `doCommandBy cancelOperation`. The label being edited is
    hidden from rendering meanwhile. Text is single-line.
  - **Crop is a document mutation** (`crop(to:)` → undoable image +
    annotations swap in one step); the canvas only draws the dimmed draft
    rect and commits on mouse-up, then switches to the select tool.
    **Annotations whose `expandedBounds` don't intersect the crop are dropped**
    (the canvas is derived from annotation bounds, so keeping them would
    re-expand it over the area just cropped away); partially overlapping ones
    are kept intact and may extend the canvas slightly. Undo restores the image
    and every dropped annotation from the `setContents` snapshot.

### Recording (2026-10-09)

Moved here from `features/recording.md` at integration (T7); the per-task
reasoning lives in `docs/recording-reviews/t*.dev.md`.

- **Exclude Snappy by application, as screenshots do.** Area targets use
  `SCContentFilter(display:excludingApplications:[Snappy]:exceptingWindows:[])`
  + `sourceRect`; if our `SCRunningApplication` is missing from the (cached)
  content, refetch once, then fail with a readable error — **never** fall back
  to a window-list exclusion (it would bake later-opened panels into the
  video). Window targets use `SCContentFilter(desktopIndependentWindow:)`.
  Annotations reach the video **only through the compositor**; the border,
  toolbar, dimming and countdown never do.
- **One ink drawing path.** `InkRenderer` (→ editor `AnnotationRenderer`,
  read-only use of `Editor/**`) draws both `LiveInkView` and every video frame,
  both mapped with `FrameDecoratingGeometry.transform` — never draw ink with
  separate view-space code (canvas ≡ export, test-locked to ≤ 2/255).
- **The decorator is UI-free and outlives the panel.** `RecordingCompositor`
  reads only the immutable `InkScene` swapped in under an
  `OSAllocatedUnfairLock`, never blocks on the main actor, and keeps drawing
  its last scene after `close()` until the pipeline's `stop()` has returned
  (the coordinator retains it for the drain).
- **H.264 needs even pixel sizes, at most 4096 px per side** (the M2 Max
  hardware encoder refuses 4098 × 2304): rounded/capped in `OutputGeometry`,
  never in the pipeline. The video size is fixed at start; a resized W window
  — or a W + part's part of another size — is letterboxed.
- **Idle frames.** SCK sends nothing while the screen is static, so the
  pipeline re-appends the last frame (re-decorated) on a fixed `FrameClock`
  cadence — otherwise fading ink and fresh strokes would not reach the video
  until something else changed. The writer session starts at the first frame
  and ends at Stop (one interval after the last good frame on a failure).
- **A fixed slot grid: never above the frame rate** (`FrameClock`, T7
  review round 2). Slot k is at `t0 + k / fps`, `t0` = the first frame (the
  writer session's start); every frame — captured, idle or closing — is
  stamped on a slot, and every append takes a slot **after** the last one,
  so no second of video can hold more than `fps` frames, whatever SCK's
  cadence, latency or timer jitter (property tests over 1 000 seeded runs
  + the review's probe lock this). An unfilled slot holds the previous
  frame (VFR). SCK stamps a frame with its *display* time, a few ms before
  it arrives, so the sources meet on the grid: a captured frame claims the
  first slot at or after its display time (`displayTolerance`); if that slot
  is filled it is **not appended** but kept as the next slot's content. An
  idle frame takes the **next** slot once its wait is over — while SCK
  delivered within the last second (`captureMemory`) it waits
  `captureGrace` = 0.4 interval past the slot, so a real frame within normal
  latency wins (deliberately not ½: the timer ticks every half interval and a
  grid-aligned timer would sit on that boundary); once SCK is quiet, T2's
  jitter-proof cadence (`earlyTolerance`) applies. Only a tick more than 1½
  intervals late (a stalled timer) resynchronises to the latest due slot —
  never per-tick floors, which skip a slot when the wait changes. Static
  stretches are filled at exactly the frame rate. History: round 0 recorded
  ~18 % near-duplicate pairs 1–2 ms apart (75–81 fps at 60); round 1's
  relative ¾-interval rule still let sparse captures reach 68.5 fps.
- **Keystrokes belong to the user's app while recording.** On every
  transition **into** `.recording(.interact)` — record start and each draw →
  interact — and nowhere else, the coordinator yields activation
  (`NSApp.yieldActivation(to:)`) to the app that was frontmost when the
  session began and activates it. In interact mode the ink panel is
  `ignoresMouseEvents` and no Snappy window is key. *Verified live (T7): the
  user's app is frontmost and active right after record start and after
  draw → interact, with no Snappy key window.*
- **Magic Pen (2026-10-15, leader decisions — Tefa to confirm) is a
  recording mode, not a second ink engine.** `RecordingMode.magicPen(resume:)`
  sits next to interact/draw: ⌃⌥P / the toolbar wand turn it on from either
  (remembering the draw tool), ⌃⌥P / Esc / Q return there, V → interact,
  ⌃⌥D → normal draw mode. The panel, focus and key rules are draw mode's
  (`RecordingMode.isDrawing`; `LiveInkFocus` keeps key status between draw
  mode and the Magic Pen, so switching never hands the keyboard back or
  flickers it). Its strokes are `InkStroke.isMagicPen` pen strokes: **always
  fading** (Settings' delay + 0.6 s), never setup ink, own width
  (`InkStyle.magicPenWidth`, `InkWidth.magicPenPoints`) and look
  (`MagicPenLook`). The halo is an `InkRenderItem.underlay` drawn in the
  **same transparency layer** as the stroke by `InkRenderer` — never a CG
  shadow (shadow blur is in device space, so screen and video would
  differ). The thickness is a *setting* (`SettingsStore.recordingMagicPenWidth`)
  that also changes live: `RecordingCoordinator.setMagicPenWidth` (menu bar
  **and Settings** — the Settings pop-up never writes the store itself, or a
  running session would keep the old width) and the `magicPen*` ink commands
  ([ ], the toolbar Width menu while on) persist it and push the style;
  every actual change is reported through `onMagicPenWidthChange`, which
  `StatusItemController` forwards to an open Settings window. A Retake takes
  the current setting, not the take's. ⌃⌥P follows the ⌃⌥D hot-key rules below and is **never
  registered when it equals the draw-mode combo** (banner instead). The menu
  bar ● keeps "a plain click stops"; only right-/⌃-/⌥-clicks open its menu.
- **Draw mode takes the keyboard without activating Snappy** (Leader
  decision; replaces the original "draw mode activates Snappy"). The ink
  panel is a non-activating panel that `makeKey()`s on entering draw mode and
  drops key status (order out + straight back in) on leaving it, so pins or
  editors never jump over the user's app. *Verified live (T7): with the ink
  panel key, the user's app keeps the menu bar and stays active.* If a future
  macOS stops routing keys to it, activate Snappy in `LiveInkPanel`'s `.take`.
- **Exactly one key → command path per phase**, always `RecordingKeyMap`
  against the last phase given: Setup / snapping / countdown → the Setup
  overlay (its local monitor also maps keys that land on the ink or chrome
  windows); draw mode and Magic Pen → the ink panel; interact → the
  user's app (the map returns nil). Chrome windows never become key (`canBecomeKey = false`).
- **Window levels: setup < ink < chrome** (`RecordingWindowLevel`: `.statusBar`,
  +1, +2), above floating panels and the Dock, below pop-up menus and the
  `.screenSaver` area-capture overlay. Every **session** window (Setup
  overlay, ink, chrome) is a `.nonactivatingPanel` with `animationBehavior =
  .none`, `hidesOnDeactivate = false`, on all Spaces
  (`RecordingIntegrationTests`). The finished-take **recording window** (v2)
  is a normal titled `NSWindow` at the normal level — see *Recording windows (v2 V1)*
  below.
- **The Setup overlay is live, not frozen** — the frozen-screen rules apply
  only to the ⇧⌘4 drag. It normalises an incoming area target (on its display,
  ≥ 40 pt). **A component never reports from inside `apply`:** the overlay's
  own corrections (normalisation, S ↔ W over a hovered window, a display
  change) go through `SetupTargetSync` and arrive after the coordinator's
  broadcast — a synchronous report re-enters the broadcast and leaves the
  other pieces on the old target. **A W target is locked in Setup** (no
  handles, move or resize; drag outside or S/W replaces it — Leader decision).
  The snap list is fetched fresh per snap visit; SCK → AppKit only through
  `CaptureGeometry`.
- **⇧⌘4 is context-sensitive** (`CaptureHotKeyRoute`: no session → capture ·
  recording → stop · rest of a session → ignored). The draw-mode toggle
  (⌃⌥D by default) is registered through the single `HotKeyCenter` **only
  while a session is active**. Like every Snappy hot key its combo needs at
  least one of ⌘/⌃/⌥ (Creator decision 2026-10-20, replacing the 2026-10-09
  ⌃/⌥-only rule — so ⌘D / ⌘P are allowed; a ⌘ combo is swallowed system-wide
  for the session, which is the person's call). **A registration the
  system refuses** (another app owns the combo) is never silent: the
  coordinator posts a banner (`UserFacingText.drawModeHotKeyUnavailable`,
  beep + VoiceOver if banners are off), the chrome is told
  (`setDrawModeShortcut(nil)`) so no tooltip advertises a dead shortcut, and
  the toolbar's draw toggle still works. `HotKeyCenter.register` reports the
  result; `isRegistered` reflects a live Carbon ref. The capture hot key's
  combo is configurable: Stop's tooltip names it (`setStopShortcut`), and a
  Settings change of any hot key applies to a running session at once.
- **One session at a time, scoped and drained.** Capture and recording block
  each other (`CaptureActivity`). Every recording callback and async result
  carries its session id; a cancelled or failed session orders its windows
  out at once but keeps the coordinator busy until its pipeline's **single**
  `stop()` returns, so a new take can never delete a file still being written.
- **Take lifetime (v2, Q30/Q43) is the PURE `RecordingTakeLedger`'s call,
  nobody else's.** Each recording window owns its take; the latest finished
  take is kept for "Reopen Last Recording" even with its window closed.
  Deletion happens in exactly three places: a window's `onClose` (its take,
  unless the ledger still keeps it — the latest, or another window shows it),
  `takeFinished` (`prune(keeping: ledger.kept)`: the previous latest whose
  window is closed, plus leftovers of an earlier run of the app), and a
  cancelled/failed run's own partial file. **`prepareNewTake` deletes
  nothing**, so a new recording never touches a take whose window is open, and
  a cancelled or failed recording leaves the latest reopenable. Windows are
  *counted* per take, because a window still closing (its `onClose` lands a
  turn later) and a reopened one can overlap. The ledger's `latest` is seeded
  from the newest take on disk at launch. The take being written is never in
  the ledger, so a window closing mid-recording can't touch it. Save **stages
  a hard link synchronously** before it yields, then copies (never moves) into
  the Save folder, so a take released meanwhile still saves; a missing take is
  refused, never fabricated. Copy pastes the saved file, else a `Recording …
  .mp4` clone in the temp dir (it outlives the take); if the clone fails the
  window stays open — the take itself is never put on the pasteboard. **Where
  a take was saved belongs to the take, not its window**
  (`RecordingSavedFiles`, owned by the coordinator, shared with every window
  through `RecordingWindowContext`, trimmed to `ledger.kept`): a reopened
  window's Copy pastes the saved file, and a Save that finishes after its
  window closed is still recorded (fix round 1).
- **Export size never touches the take (2026-10-20).** The status capsule's
  slider (`ExportScale`, 100/75/50/25 %, opening at Settings' *Default
  export size*, never written back) only changes what Save/Copy export. At
  **100 %** the old path runs unchanged (staged link / clone — bit-identical,
  no re-encode). At a **smaller stop** `RecordingTranscoder` re-encodes the
  take into the window's `RecordingExportCache` folder (system temp,
  `com.tefa.snappy/Exports/<uuid>/`, one file — the latest stop — removed
  when the window closes), then Save stages *that* file and Copy clones it;
  `RecordingSavedFiles` keys saves by stop, so Copy reuses a saved file only
  at the stop it was saved at (`RecordingExportSource`). A failed or
  cancelled re-encode exports **nothing** — never the full-size take; a
  failure shows "Export failed" inline in the capsule (a cancel just restores
  the readout). One re-encode at a time
  (another Save/Copy beeps); **Q / Esc / ⌘W during it cancel only the
  re-encode**, the traffic light closes the window and cancels it. The
  re-encode keeps the stop it was started at even if the slider moves. Output
  sides are rounded to the nearest even pixel; the frame rate is the take's
  (nominal, snapped to 30/60), the bitrate `OutputGeometry.bitrate` for the
  new size at the *current* Settings quality (a take doesn't record its own).
  **The "≤" readout is a real bound** (`ExportSizing.estimatedBytes`, review
  r1): the target bitrate is only the encoder's *average* — detailed content
  overshoots it, and a lone key frame costs the same for one frame or thirty —
  so the bound budgets ≥ 1 s at 1.5× the target plus MP4 overhead and is
  formatted rounded up. `RecordingTranscoder` caps every 1 s window at the
  target (`kVTCompressionPropertyKey_DataRateLimits`), checks the written
  file against that same bound, redoes an over-bound encode up to twice at a
  leaner rate and otherwise fails (`.tooLarge` → "Export failed") — it never
  keeps a file larger than the readout promised. It also ends the writer
  session at the take's own track end, so a one-frame (or held last) frame
  keeps its length. The real file size replaces the bound once a re-encode or
  Save exists at the stop. The capsule stays inside the window (≥ 10 pt
  margins); when it can't fit, the `W × H · m:ss` readout detaches first
  (`NSStackView` visibility priority) so the slider and size stay whole.
- **Recording windows (v2 V1).** Normal titled windows (`isReleasedWhenClosed
  = false`, in Mission Control, not ⌘-Tab — LSUIElement), the editor's Tahoe
  Glass layout: `.fullSizeContentView` + transparent titlebar + `.unified`
  toolbar, the player fitted into `contentLayoutRect` above the status band
  (`AnnotationGeometry.fitArea`, read-only use of `Editor/`), the editor's
  backdrop wash. They outlive sessions: `beginSession` no longer closes them.
  Retake only *asks* (`onRetake`); the coordinator closes the window when Setup
  can start and beeps otherwise (a session busy), leaving it open. Reopen
  fronts the latest take's open window and never opens a second copy. Two
  toolbar identifiers (with / without Retake), because windows that share an
  `NSToolbar` identifier sync their items.
- **Recording windows take focus only at the end of their session (fix round
  1).** Since they outlive sessions, nothing closes a stale one when a new
  recording or screenshot capture starts (the old panel's pending
  presentation died with `beginSession`'s `close`). So:
  - `show()` puts the window on screen and asks for focus **synchronously**,
    inside `end` — sized from the recorded area. The take's real size and
    duration (AVFoundation, async) only update title, capsule, player aspect
    and — if the person hasn't moved or resized it yet — the window's size.
    **The load never activates or makes key.**
  - The stop's own interaction asks for activation (`activateSnappy`, on the
    transition into `.stopping`, before `pipeline.stop()`), so the grant from
    ⇧⌘4 / ■ / ● is used while it is fresh (window-pick pattern, overlay
    invariant 1).
  - `NSApp.activate()` may land late or never (`NSApplication.h`). The window
    is then ordered front regardless, retries once after 150 ms, and becomes
    key if Snappy becomes active within 1 s — **both only while
    `RecordingWindowContext.mayTakeFocus` holds** (no recording session busy,
    no screenshot capture in flight). An unrelated activation later (⇧⌘4) can
    never make it key.
  - **W-window auto-stop (Tefa, 2026-10-11 — final, option (a)):** it has no
    user interaction, so macOS may decline every request; the window then
    comes to the front but **is not key until clicked**. Only the ⇧⌘4 / ■ / ●
    stops get focus. The recording window stays a normal titled window — no
    `.nonactivatingPanel` and no key catcher (options (b)/(c) rejected; see
    `docs/recording-reviews/v2-v1.dev.md` › Fix round 1, finding 2).
- **W window lifecycle (Tefa, 2026-10-09 — final):** auto-stop only when the
  window is really gone (absent from the full window list, or its process
  gone). Minimised / another Space / hidden app **keeps recording until the
  person stops it** (⇧⌘4, toolbar ■, the menu bar ●) — the last frame + ink
  are re-appended, and the recording resumes when the window returns.
  `WindowTrackingState.offScreenEndsRecording` stays `false`.
- **The menu bar shows the recording** (Tefa, 2026-10-09): a red ● plus the
  elapsed time, `● 0:42` / `● 1:02:03`, monospaced digits, updated on every
  whole second from the instant the toolbar timer starts
  (`RecordingCoordinator.onCaptureStart`, same main-actor turn as
  `captureDidStart`, same `ContinuousClock` formula); VoiceOver reads
  "Recording, 0:42, click to stop"; a click stops. It is the indicator that
  stays visible when the recorded window — and with it the border and
  toolbar — is off screen. (A status item can still be hidden by macOS
  under the notch on a crowded menu bar; that placement is the system's.)
- **Mid-recording failure (Tefa, 2026-10-09 — final): the take is
  discarded** and the error alert shows — `RecordingCoordinator.failedTakeHandling`
  = `.discard`. (The pipeline could salvage: a stream failure leaves a file
  `stop()` still finalises.)
- **Window-anchored ink** is anchored to the window's top-left at draw time
  and follows it. The window frame comes from `WindowTracker`, which polls on
  the main actor at 30 Hz; `RecordingPipeline` stores each change in the
  writer's `OSAllocatedUnfairLock` (a `DecorationTarget`), and every composed
  frame reads the **latest tracked frame** from that lock — composition never
  awaits the main actor, but a frame can lag a moving window by up to one
  poll (~33 ms). The decorator gets **two frames**: `targetFrame` (what the
  frame shows — mapped onto `outputRect`, ink outside it clipped) and
  `windowFrame` (what window anchors resolve against); they differ only for
  W + part.
- Chrome: the border ring sits **outside** the rect (3 pt band + 1 pt
  hairline), one border panel per display it reaches, folding inward only
  for an area at a physical screen edge. `.toolbar` buttons outside an
  `NSToolbar` need `showsBorderOnlyWhileMouseInside = true`, or every button
  gets a bezel box on the glass.
- Recording window: keys are intercepted at window level (`sendEvent` /
  `performKeyEquivalent`, `RecordingWindow`) so the `AVPlayerView` can't eat
  them — Space is play/pause even on a focused toolbar button, and `[` / `]`
  step the export size even on the focused slider. The status capsule is
  **not** click-through any more (the slider needs the mouse); it is 36 pt
  tall (`statusCapsuleHeight`) and `statusBand` grew to match.
- **Window parts (v2, task V2, 2026-10-11).** S/W pick a part of the
  hovered window through Accessibility (`features/recording.md` › Window
  parts). The rules that must hold:
  - **Hit-test inside the hovered app, never system-wide.** The Setup
    overlay covers the display, so `AXUIElementCopyElementAtPosition` on the
    system-wide element finds Snappy. `WindowPartAXTree` hit-tests the
    hovered window's *application* element and accepts the chain only if it
    ends in that window (frame within 2 pt) — another window of the app on
    top gives whole-window only.
  - **AX never runs on the main thread** (fix round 2, 2026-10-11). All
    AX messaging and every `AXUIElement` live in `WindowPartAXEngine`, an
    actor whose executor is its own `DispatchSerialQueue`. The main actor
    hands it plain values (`WindowPartQuery`: visit, sequence, pid, point,
    window frame, display height) and gets plain values back on the main
    queue (`WindowPartQueryResult`: the chain with opaque
    `WindowPartElement` handles, "switched"). `AXUIElement` isn't Sendable:
    never let one out of the engine — the handle is an id into the engine's
    table, released when the last handle goes. Session hooks and queries are
    **posted** (`post`, one FIFO queue: a session's end is handled before the
    next session's first query); the only main-thread wait is the graceful
    quit, at most `WindowPartAccess.quitWait` (1 s).
  - **Hover is asynchronous and latest-wins.** `WindowPartModel` shows a
    new window as a whole window at once (CG window list, no AX) and keeps
    the pick within a window until the answer for the **latest** pointer
    position arrives (`onChange`); an older answer is dropped, and the
    engine skips a query a newer one superseded
    (`WindowPartQueryTicket`, an atomic shared by both sides). **Latest-wins
    covers picks only**: an older answer that switched a tree on still
    schedules the post-switch recheck (the newer query reuses the empty
    chain and can't switch again). A click or Return confirms the pick on
    screen.
  - **Still bounded, for the executor's throughput** (every app's queries
    share it): `WindowPartLiveAX` sets 0.25 s on each element right before
    messaging it (hit element, every parent, retained parts, a restore's
    application object). One query — hit test, the walk *or* the cached
    chain, and the tree switch read/write — has a **soft** 0.5 s deadline
    (`WindowPartAXEngine.queryBudget`), checked after every call (also
    between the switch read and write): past it no further call starts, so
    a query lasts at most the budget plus the one call in flight (≤ 0.75 s).
    A call the app can't complete at any stage, or a query over budget,
    makes the app whole-window for the rest of the snap visit. A retained
    part's frame read backs off 1 → 8 s after a stalled read; a restore
    batch stops after 0.5 s (`restoreBudget`) and the rest waits for the
    retry — **least recently tried first** (a failed record moves behind
    the ones not reached), so hung apps can't starve responsive ones. The chain is reused while the deepest
    element under the pointer is unchanged (the tree-switch check still
    runs on a cached chain). Measured live (Brave, Claude, Finder,
    ChatGPT): ~25 ms for the first query to an app, then 0.1–2 ms per
    pointer move.
  - **The recording polls through the same executor** (V3).
    `WindowPartElement.currentFrame()` is `async` and returns a value
    (AppKit global, nil = keep the last rect, Q37); a hung app costs the
    poll nothing but a nil (and the engine's 1 → 8 s back-off). It returns
    the part's **visible** frame — its own clipped by every live ancestor
    up to the window (`WindowPartSelection.visibleFrame`, the picker's
    rule), one round trip per level within `queryBudget` — so a table
    taller than its scroll view records what the picker showed, not the
    window around it (V3 fix round 1). The read is **enqueued on the
    executor before `currentFrame()` first suspends**, in the caller's
    isolation (`isolation: isolated (any Actor)? = #isolation`): from the
    main actor it is in program order with the session hooks, never behind
    a hop. And the engine answers it **only between `sessionBegan` and
    `sessionEnded`** (`isInSession`; every session posts both): no read,
    no adoption outside a session.
  - **A browser's page is one part; an app whose UI *is* web content is
    looked into.** Inside a web area only ARIA landmarks and container roles
    count, and only when the app is Electron (`Electron Framework.framework`)
    or the web area fills the window — else a page's own `main`/`region`
    landmarks would replace "Web page".
  - **One handle per element per visit** (`WindowPartElement`, compared by
    identity): the same part under a moving pointer is the same target, so
    hovering doesn't re-broadcast. The handle is Sendable and reads the live
    visible frame through the engine (`await currentFrame()`, nil when gone)
    — what V3 polls; its element outlives the visit while a target holds it.
  - **Tree switch (Q40): Chromium / Electron only, once per app per
    session, only when the tree under the pointer is empty, only after the
    current value was *read* as off (a failed or odd read changes nothing),
    recorded when the set succeeded or timed out — and restored at every
    session end and on quit** (`RecordingCoordinator` →
    `windowParts.sessionEnded()`; `AppDelegate.applicationWillTerminate` →
    `applicationWillTerminate()`). **Restores are ownership records per
    process** (pid + bundle id + launch date, the earliest original value):
    one the app doesn't answer stays owed (`WindowPartPendingRestores`) and
    is retried 2 → 60 s until it lands or that process is gone — **unless a
    later session uses the process** (a pointer query on it, a W + part
    target at `sessionBegan` — Retake included — or a retained part's frame
    read, which only runs inside a session): that session adopts the record and the restore waits for *its*
    end, so an old retry never switches the tree off under it.
    *Known limitation:* an Electron build that doesn't answer *reading*
    `AXManualAccessibility` is never switched (whole windows there) —
    modern Electron implements the getter.
    *Verified live:* a fresh Chromium (Brave) exposes no web tree and
    refuses `AXEnhancedUserInterface` (`kAXErrorNotImplemented`, no tree
    after 6 s; `AXManualAccessibility` likewise), but its page area is still
    pickable through the native `AXScrollArea` around the web contents.
  - **Permission (Q39):** `WindowPartAccess.snapModeEntered` prompts once
    (`SettingsStore.recordingAccessibilityPrompted`), only when untrusted and
    only from the bundled `.app` (an unbundled run would prompt for the
    terminal). The session that prompted stays whole-window to its end;
    otherwise trust is read per snap visit. Without it the picker has no
    tree and S/W are v1 exactly.
- **W + part — the window's stream cropped live (v2, task V3, 2026-10-11;
  Q37, Q41, Q42).**
  - **ScreenCaptureKit crops, not the compositor.** `SCStreamConfiguration
    .sourceRect` works on a `desktopIndependentWindow` filter, in
    **window-local points, origin top-left**, and `updateConfiguration`
    moves it live — verified on macOS 26 with a throwaway probe (quadrant
    window: each crop showed exactly its quadrant, updates took 20–35 ms per
    call). Chosen over cropping a whole-window buffer in `FrameCompositor`
    because the part stays at native resolution however the window grows,
    SCK delivers only the part's pixels, and the existing contentRect
    letterbox path handles a part of another size unchanged (SCK scales it
    into the fixed buffer at the top-left and reports `contentRect`). The
    price: a frame doesn't say which crop it has, so frames presented
    while SCK switches are held back (below).
  - **The crop is window-local**, so a moving window needs no update and
    ink + content move together exactly (`DecorationTarget.part` derives
    the part's global frame from the same tracked window frame the ink
    uses). The coordinator mirrors this: `withWindowFrame` keeps the
    part's offset from the window's top-left.
  - **Always clamped to the window** (`PartCropGeometry.sourceRect`): SCK
    clips a source rect reaching outside the window and *stretches* the
    rest into the frame (measured), which would put the ink off. Edges on
    the pixel grid, even pixel sides, so a part of its starting size is
    recorded 1:1 with no bar; nothing left inside → the whole window. A
    window that shrinks re-clamps at once; grown back, the part's own rect
    returns (`PartCropTracker` keeps it unclamped).
  - **The part's frame is polled ~10 Hz** (`RecordingPipeline.partPollInterval`)
    through its `WindowPartElement` — the part's **visible** frame, clipped
    by its live ancestors like the pick (see above) — **sequentially** (the
    next read only after the last answered). A sample counts only when the window server
    reports the window **on screen at the same frame before and after the
    AX read** — otherwise a window being dragged reads as the part moving
    and the crop jitters; dropped samples cost nothing, the window-local
    crop rides along. Off screen: not even read; the recording holds its
    last frame like W. Nil (part gone, navigated, app not answering) or an
    empty frame → **last rect kept** (Q37).
  - **One crop update in flight at a time** (`PartCropUpdater`, SCK behind
    a seam); the newest wanted crop goes when it returns. The chrome
    (`onPartFrameChange` → `.targetChanged`, border + toolbar + ink panel)
    follows a request at once; a **failed** update puts the chrome back on
    the crop SCK still records and asks again 1 s later (the poll calls
    `want` every ~100 ms).
  - **Each frame is decorated with the crop it was presented under**
    (`PartCropTimeline`, V3 fix round 1). SCK takes a new `sourceRect`
    during `updateConfiguration` (*measured: never before the call, a few
    ms before it returns*), and a frame doesn't say which crop it has. So
    every change is a span of presentation time: requested (stamped right
    before the call) → applied (stamped **on SCK's completion callback**,
    not after a main-actor hop). A frame presented before the request,
    less one frame interval, has the old crop; one presented after the
    completion the new one; one in between is **held** — not appended,
    the last frame of a known crop stays in the video — never drawn with
    a guessed crop. `lastFrame` (idle re-appends, the closing frame) keeps
    its own crop. This holds whatever order frames reach the writer in (a
    backlog behind a slow composition) and however busy the main actor is.
    *The one assumption left:* a held frame with nothing after it settles
    as the **new** crop once the update has returned and two frame
    intervals passed — SCK sends a frame for a crop it has taken, and with
    a still window that frame is the last one of the span (measured: a
    still window's new crop does reach the video). Only if SCK took a crop
    without sending a frame for it *and* the last frame of the span was
    still the old crop would that frame show old content under the new
    crop's ink, until the next frame. A failed update drops its span (held
    frames are the old crop's).
  - **Video size fixed at start** = the crop's pixels; a part of another
    size is scaled to fit and letterboxed (`usesContentRect`, like a
    resized W window).
  - **Ink stays window-anchored, hidden outside the part** (Q42): the ink
    panel covers the **part** (not its window), `LiveInkView` and the
    compositor clip to it and resolve window anchors against `windowFrame`
    — so on screen and in the video a stroke outside the part is hidden,
    not deleted, and comes back when the part covers it again.
  - **No AX read after the session's restores** (V3 fix round 1 made this
    hold, not just the order on the main actor). A read after the restore
    would adopt an owed restore into a finished session, which then only
    the next session's end or the quit would retry. Three layers:
    `end()` detaches the run (→ `pipeline.endTracking()`: tracker, part
    poll and crop updates stopped, and a start still awaiting SCK won't
    begin them when it resumes) **before** `windowParts.sessionEnded()`,
    also when a cancelled run's `stop()` only comes later (draining);
    every read is enqueued on the AX executor in main-actor order (so one
    requested before the end runs before it); and the engine refuses any
    read outside a session. Retake's look-up is a stored task, cancelled
    at the end and checked **before** its read as well as after.
  - **Retake (Q41)** opens Setup on the take's target at once, then looks
    it up inside the new session (so the AX read is that session's use of
    the app): `refreshedForRetake` — the part at its live frame (clipped
    to the window) in the window where it is now; **gone → the whole
    window**; window closed → its region as an area (as Setup does); a part
    without an element keeps its last rect; S + part is an area and keeps
    its last screen rect. A plain W target is moved to where its window is
    now. Dropped once the person has changed the target or left Setup.
  - **Setup doesn't follow** (as for W): the part is tracked from the
    record start; the Setup dimming, border and toolbar show the picked
    rect.
- **Measured (T7, live, 2026-10-09):** full-display area 1800 × 1169 pt @ 2×
  → 3600 × 2338 px at 60 fps, a 60 Hz-animating app on screen, ink drawn in
  draw mode throughout (three runs): **no dropped stretches** — 0–7 isolated
  one-frame gaps per 10 s (≤ 1.2 %), never two in a row — and Snappy at
  66–70 % of one core. The ink is in the video at the drawn position; border,
  toolbar and dimming are not. **After review round 1's clock** (two runs):
  no near-duplicates left (no gap under ¾ interval apart from the closing
  frame), 57–59 fps average at the 60 fps setting, ~60 % of one core. The
  remaining 25 ms gaps are slots in which SCK had no new content (a 60
  Hz-timer animation beating against the 120 Hz ProMotion vsync); the frame
  shown is held for them — before the fix an idle copy filled them and the
  real frame followed 8 ms later. The round-2 slot grid has **not** been
  re-measured live yet (its ceiling is by construction and test-locked).

### Concurrency

- Everything UI is `@MainActor`; `CaptureEngine` is `@MainActor` too so SCK
  results never cross an isolation boundary. Its two `nonisolated` members are
  deliberate and pure-CoreGraphics: `crop` (unit-tested headlessly) and the
  hot-key signature constant's counterpart in `HotKeyCenter`.
- **Parallel display snapshots do not use a task group.** `SCContentFilter` is
  non-Sendable and Swift 6's region analysis rejects `sending` it into
  `addTask`, so the freeze creates main-actor `Task`s and awaits them in order;
  the SCK round-trips still overlap because each `await` releases the actor.
  Do not "fix" this with `@unchecked Sendable`.
- **Recording pipeline isolation.** `FrameWriter` is an actor whose executor
  is the capture queue (`DispatchSerialQueue`); SCK delivers samples on that
  queue and they enter via `assumeIsolated`. The single, commented
  `nonisolated(unsafe)` covers SCK's sample hand-over (`CMSampleBuffer` /
  `CVPixelBuffer` are non-Sendable); no `@unchecked Sendable`. The decorator
  is the only thing called on that queue from the main actor's side.
- Menu actions spawn `Task { ... }` for async work; completion callbacks run on
  the main actor.
- OCR needs no isolation gymnastics: the async Swift Vision API
  (`RecognizeTextRequest.perform(on:)`) runs recognition off-main internally,
  and `CGImage` is `Sendable` in the macOS 26 SDK — so `TextRecognizer` is a
  plain nonisolated enum and accurate-mode Vision never blocks the UI.
- Swift 6.2's `defaultIsolation(MainActor.self)` was considered for the macOS
  26 retarget and **rejected**: half the codebase is deliberately
  isolation-free pure helpers exercised synchronously from tests; flipping the
  default would just move the annotations (`nonisolated` on the pure layer)
  without removing any.

## Platform & toolchain quirks

| Quirk | Consequence |
|-------|-------------|
| CLT-only machine (no Xcode) | Bundle assembled by `scripts/bundle.sh`; `Testing.framework` needs explicit `-F`/`-rpath` flags → always test via `scripts/test.sh`; **XCTest is unavailable** — Swift Testing only |
| Screen Recording TCC | Tied to bundle id `com.tefa.snappy`; renaming/re-identifying the app re-prompts. First `SCShareableContent` call triggers the prompt; denial throws `SCStreamError.userDeclined` → alert deep-links `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Cooperative activation | See overlay invariant #1. Area capture now activates **after** the freeze `await` — deliberately, since activating first destroys the transient UI being captured. Correctness no longer depends on it: the overlay is a `.nonactivatingPanel` that takes key status without activation, plus one deferred retry. Activation remains needed to end a foreign `NSMenu`'s modal tracking loop. Recheck "Esc while another app is frontmost" after OS updates |
| Hot keys during foreign menu tracking | Both hot keys must fire while another app's `NSMenu` holds its tracking loop — the whole frozen-capture feature depends on it. If a future macOS starves `RegisterEventHotKey` there, the only alternative is a `CGEventTap` (Accessibility permission). Separately: `RegisterEventHotKey` swallows the ⇧⌘4 keystroke, but the ⇧/⌘ `flagsChanged` events still reach the frontmost app and can dismiss a **tooltip** before the hot key fires — nothing in the freeze design can fix that; isolate it by temporarily binding a modifier-free combo |
| Accessibility TCC (window parts) | A second permission besides Screen Recording, tied to the app's signature like it (the "Snappy Dev" identity keeps it across rebuilds); on an MDM-managed Mac an administrator may have to allow it. Prompted once from the first S/W snap mode (`WindowPartAccess`); Settings → Recording shows the status. A terminal-launched `swift test` inherits the terminal's grant |
| Desktop folder TCC | First Save to ~/Desktop can trigger the "Files and Folders" permission prompt (separate from Screen Recording) |
| `LSUIElement = true` | No Dock icon; `.accessory` policy is also set at runtime for `swift run` |
| No main menu | AppKit routes ⌘W and ⌘X/⌘C/⌘V/⌘A through the main menu, so **any window Snappy shows must handle them itself** (Settings: `SettingsWindow` + `SettingsKeyCommand` handles ⌘W and ⌘X/C/V/A; the editor's canvas `performKeyEquivalent` handles ⌘C/⌘S/⌘P/⌘Z but **not ⌘W yet** — the editor closes with Q/Esc or the close button; the recording window handles ⌘S/⌘C/⇧⌘C/⌘W in its window's `performKeyEquivalent`; the ink view handles ⌘Z/⇧⌘Z; a Settings shortcut recorder gets every key equivalent first while it records). The status menu's key equivalents only work while it is open |
| User-facing copy | Alert and banner strings live in `UserFacingText` (HIG: alert titles are full sentences, banner titles title-style). An unknown error contributes a description only when one was *written* (`LocalizedError.errorDescription`, `NSLocalizedDescriptionKey`, or a Cocoa error) — an Apple domain alone still synthesizes "(… error -3812.)" |
| UserNotifications needs a bundle | `UNUserNotificationCenter.current()` **crashes** in an unbundled process (`swift run`) — `UserNotifier` guards on `Bundle.main.bundleIdentifier` and falls back to `NSLog`. Banners for the frontmost app are suppressed by default, so `UserNotifier` is the center's delegate and returns `.banner` from `willPresent`. Permission is requested on first post (first OCR) |
| Version is derived, never hardcoded | `scripts/version.sh` (sourced by `bundle.sh`, `verify-bundle.sh`, `install.sh`) derives the version from `git describe` on `v*.*.*` tags: `CFBundleShortVersionString` = tag number only, `CFBundleVersion` = commit count, `SnappyBuildDescription` = full string (`1.1.0-7-gabc1234-dirty`). No tag → `0.0.0-<hash>`, never a build failure. Releases only via `scripts/release.sh`. Details: `features/versioning.md` |
| App icon is generated, not hand-made | `assets/generated/` artifacts are committed; `bundle.sh` only copies them (+ `CFBundleIconFile`). Re-run `scripts/generate-icons.sh` ONLY when `assets/snappy-dynamic-s.png` changes — `bundle.sh` warns (non-fatally) when the source PNG is newer than `AppIcon.icns`. Finder caches icons (`touch dist/Snappy.app` after rebuilds). Details: `features/app-icon.md` |
| Signing & TCC (the #1 permission trap) | Ad-hoc signing (`codesign -s -`) pins TCC grants to the exact binary hash (cdhash) — **every rebuild silently invalidates Screen Recording**; System Settings still shows the toggle ON but capture throws `.userDeclined`. Fix: `scripts/setup-signing.sh` (once per machine) creates a self-signed "Snappy Dev" identity; `bundle.sh` prefers it, making the grant certificate-based and rebuild-proof. After switching identities: `tccutil reset ScreenCapture com.tefa.snappy`, relaunch, re-grant once. Build on the target machine; copied bundles may need `xattr -d com.apple.quarantine` |

## Verification gate (every change)

`swift build` (no new warnings) → `./scripts/test.sh` → `./scripts/bundle.sh` →
`./scripts/verify-bundle.sh` → manual checklist of the affected feature (its
doc in `features/`, indexed by `docs/FEATURE_MAP.md`). New pure logic gets
Swift Testing coverage; UI behavior goes on the feature's manual checklist.
