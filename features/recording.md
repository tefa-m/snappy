# Recording — Screen Video with Live Annotations

> **Status:** implemented and covered by automated tests; the manual on-screen checklists at the end
> of this doc are still pending. v1 (2026-10-09) records an area or a window with live ink; v2
> (2026-10-11) adds the persistent recording window, S/W snap keys and Accessibility-based window
> parts; the [Magic Pen](#magic-pen-2026-10-15) (2026-10-15) adds fading ink whose defaults still await
> the author's confirmation. Invariants: [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) › Recording.

## What it is

Record a region of the screen, or a single window, to an **MP4 (H.264)** video, and
draw on it **live** while recording (pen, highlighter, arrow, box, oval, optionally
fading ink). Recording starts from the screenshot flow: **⇧⌘4 → drag → R**. Stopping
opens a persistent **recording window** (v2 V1) where you replay, retake, copy or save the clip.

Out of scope: **camera, microphone**, any network feature, any third-party library.
Everything is built with Apple system frameworks only: ScreenCaptureKit (`SCStream`),
AVFoundation (`AVAssetWriter`), AVKit (`AVPlayerView`), CoreGraphics/CoreImage, AppKit.

**The snapshot editor is untouched.** Recording keys, tools (Box, Highlighter, fading
ink) and colours exist only in the recording view; the editor keeps R = Rectangle etc.

## Flow & states

```
⇧⌘4 → drag (frozen screen, unchanged) → screenshot preview panel
   │                                     └─ R  "Record this area"   (also menu bar: "Record Area…")
   ▼
SETUP  (live screen; rect shown with amber border, outside dimmed, glass toolbar)
   │  Pointer mode: drag inside = move · handles = resize · arrows nudge 1 pt (⇧ 10 pt)
   │                ⌥-arrows resize: → ← right edge, ↑ ↓ top edge, 1 pt (⇧⌥ 10 pt)
   │                scroll = resize around centre (aspect kept) · drag OUTSIDE = new free rect
   │  Tool picked (P/H/A/O/B): drag inside = draw a setup annotation (permanent)
   │  S → SNAP·AREA ─┐   hover highlights windows / window parts on the rect's display
   │  W → SNAP·WINDOW┘   click / Return / Enter = confirm · other key = switch mode
   │                      same key again or Esc = back to the previous rect/target
   │                      ↑/↓ or scroll = widen / narrow the window part
   │  R → COUNTDOWN (Settings: Off/1/2/3/5 s; Esc → back to SETUP)
   ▼
RECORDING  (red border, toolbar shows ■ + timer; menu bar = red ● + elapsed time, "● 0:42")
   │  Interact mode (default): overlay is click-through, ALL keys go to your app
   │  Draw mode (⌃⌥D or toolbar toggle): the ink panel takes mouse+keys (Snappy is
   │                not activated; your app keeps the menu bar); tool keys work
   │  Magic Pen (⌃⌥P or toolbar wand): like draw mode, but every stroke is fading
   │                Magic Pen ink; ⌃⌥P / Esc again → back to where you came from
   │  Stop: ⇧⌘4 · toolbar ■ · menu bar ●  — never a bare letter (R does nothing)
   │  W-mode window closes (or its app quits) → auto-stop; minimised / other
   │                Space / app hidden → keeps recording until you stop it
   ▼
RECORDING WINDOW  (session over; persistent, one per take — v2 V1)
      autoplay · loop · muted · scrub bar · Space play/pause
      R Retake · ⌘S Save (stays open) · ⇧⌘C Copy · Esc/Q/⌘W Close
```

> *v2 V2 (implemented 2026-10-11):* in snap mode the **same key again steps back** (like Esc)
> and only a **click or Return** confirms; S/W also pick **window parts**. See the v2 section.

Esc steps back one level everywhere: snap mode → previous rect · tool → Pointer ·
Pointer (Setup) → cancel the session. Esc while recording in interact mode belongs
to your app.

## Area targets (Q4/Q12/Q13)

| Target | Enter with | What is recorded |
| ------ | ---------- | ---------------- |
| **Free area** | drag outside the current rect (Setup, Pointer mode) | that screen region |
| **Window's area** | **S**, hover, click / Return | the screen region covering the window, so popups, menus, other windows on top and annotations are all included |
| **Window itself** | **W**, hover, click / Return | only that window (`SCContentFilter(desktopIndependentWindow:)`), followed when it moves or gets covered |

Window-itself mode:
- Border and toolbar **follow the window** as it moves.
- **Resize** mid-recording: the video size is fixed at start, and the content is **scaled to fit with letterboxing**.
- **Annotations are anchored to the window** (window coordinates), so they move with it.
- If the window **closes** (or its app quits), recording **auto-stops** and the recording window opens.
- If the window goes **off screen** (minimised, another Space, its app hidden), recording **keeps going until you stop it** (⇧⌘4, the toolbar ■ or the menu bar ●); the video holds the last frame with the ink and resumes when the window comes back. The menu bar's `● 0:42` shows that a recording is still running. *(Tefa, 2026-10-09 — final. Without Accessibility access the three cases look alike, and a wrongly stopped take is lost.)*

> *v2:* S and W also pick **window parts** (page area, tab strip, panes) through Accessibility: S + part records the part's fixed screen region (V2); W + part is cropped live from the window stream (V3) (Q34–Q42). Both implemented.

One display per recording (Q11): the rect is clamped to its display, and snapping only offers windows on that display. A window-itself target may later move to another display, which is fine because the filter is display-independent.

## Live annotations (Q6/Q14/Q16/Q25)

| Key | Tool / action | Note |
| --- | ------------- | ---- |
| **V** | Pointer (Setup) / back to interact (Recording) | |
| **P** | Pen (freehand) | |
| **H** | Highlighter | always thick, 40 % opacity |
| **A** | Arrow | reuses the tapered arrow look |
| **O** | Oval | |
| **B** | **Box** (rectangle) | recording view only; the editor keeps R = Rectangle |
| **F** | Fading ink on/off | |
| **⌫** | Clear all annotations | |
| **⌘Z / ⇧⌘Z** | Undo / redo stroke | |
| **1–5** | Colour presets | red, yellow, green, blue, white |
| **[ / ]** | Line width thin / medium / thick | in Magic Pen mode: the Magic Pen thickness |
| **⌃⌥P** | Magic Pen on / off (while recording) | fading ink with its own look — see [Magic Pen](#magic-pen-2026-10-15) |

- Tool letter keys work in **Setup** and in **draw mode while recording**. They never work in interact mode, so typing a URL or text in your app is always safe (Q15/Q23).
- **Setup annotations are permanent** (they never fade). **Fading ink** applies only to strokes drawn while recording: they fade out after the fade delay (Settings, default 3 s).
- **Changing the rect** after drawing (free re-select, S-snap) leaves annotations at their **screen position**. Anything outside the new rect is hidden but not deleted. In W mode, annotations live in window coordinates.
- **⌫** clears setup annotations and recorded strokes alike.
- **Annotations are in the video and composited by Snappy** (see Architecture). The border, toolbar, dimming and countdown never are.
- Click ripples come from ScreenCaptureKit's `showMouseClicks`, so they appear in the video.

### Deferred (documented on purpose, not in v1)

| Feature | Why deferred |
| ------- | ------------ |
| Text tool, counter badges | v1 keeps to the common live set |
| Cursor highlight / spotlight | nice-to-have (ScreenMark, ZoomShot have it) |
| Keystroke overlay | needs a global key monitor (Input Monitoring TCC) |
| **Live zoom** (ZoomIt-style, ⌥-scroll) | zoomed frame must be rendered into the video, a big job (Q21) |
| Pause / resume | P is the Pen; no clean binding (Q20) |
| System audio | possible later as a setting (`SCStreamConfiguration.capturesAudio`) (Q7) |
| GIF / HEVC export | MP4 H.264 covers Slack/Jira/Confluence (Q7) |
| Trim / Edit (E) in the recording preview | button hidden in v1 (Q17) |
| **Annotating a finished video** (whole-clip shapes, blur, timed annotations) | v2 keeps the recording window annotation-free; live ink covers annotations that change over time (Q29) |
| Hide desktop icons / Do Not Disturb while recording | no public DND API; icons need Finder defaults hacks (Q26) |
| Aspect-ratio presets in Setup | (Q5) |

## Recording chrome (Q9) — Tahoe Glass

- **Border**: thin **amber** in Setup, **red** while recording; drawn *outside* the rect.
- **Glass toolbar** just outside the rect (below, or above if no room), in the Tahoe Glass style of the editor toolbar (`NSGlassEffectView`, borderless `.toolbar` buttons ≥ 28 pt, verb-phrase tooltips "… (KEY)", light + dark):
  `● Record / ■ Stop · 00:00 timer | Area · Window | Pointer · Pen · Highlighter · Arrow · Oval · Box | colour · width · fading | Clear · draw/interact toggle · Magic Pen | Cancel`
- **Countdown**: a large numeral on a glass disc, centred in the rect.
- **Menu bar** (Tefa, 2026-10-09): while recording, the status item shows a **red ● plus the elapsed time** — `● 0:42`, `● 1:02:03` past an hour — in monospaced digits, ticking once per second from the same start as the toolbar timer; VoiceOver reads "Recording, 0:42, click to stop". A click stops the recording. It goes back to the normal "S" glyph when the session ends. It stays visible when the recorded window, its border and the toolbar are off screen.
- **Dimming**: outside the rect, in Setup only.

## Recording preview panel (Q8/Q17/Q18/Q19) — replaced by the recording window

> **Superseded by v2 and removed (V1, 2026-10-11):** the transient click-away panel is gone;
> stopping opens the persistent [recording window](#recording-window-q28q32-q43) instead.
> `RecordingPreviewPanel` / `RecordingPreviewAction` became `RecordingWindowController` /
> `RecordingWindowAction`.

What carried over unchanged into the window: the `AVPlayerView` (autoplay, loop, muted, scrub
bar); the keys Space · R · ⌘S · ⇧⌘C (⌘C) · Esc/Q/⌘W, with plain C / S doing nothing (Q24);
Retake back to **Setup with the same rect/target and the setup annotations restored**, recorded
strokes dropped (Q19); Save as `Recording 2026-10-09 at 14.32.05.mp4` named after the take's
recording time, never overwriting (` (2)`), staged through a hard link; Copy putting a file URL
on the pasteboard (a `Recording … .mp4` clone for an unsaved take, the saved file once saved).

What changed: Save **keeps the window open**; Copy and Retake close it; the take is no longer
deleted when the next recording *starts* (Q18) but when the ledger releases it (Q30 — see the
v2 section). "Reopen Last Recording" fronts the open window instead of re-presenting a panel.

## v2 — Recording window & window parts (designed 2026-10-11, implemented)

Settled with Tefa in a second grilling session. **Why:** the transient preview panel lost the
take from view on any click-away (the take survived in Caches, but only the menu bar's
"Reopen Last Recording" got it back), whereas the screenshot flow has a persistent editor.
Also, W could only pick whole windows, while other recorders can pick e.g. a browser's page
area with or without the tab strip.

### Recording window (Q28–Q32, Q43)

> *Implemented (V1, 2026-10-11 — `docs/recording-reviews/v2-v1.dev.md`); manual checklist pending.*

Stopping a recording (⇧⌘4 · toolbar ■ · menu bar ●, or W-window auto-stop) opens a
**persistent, normal titled window**, the same as the screenshot editor, and the transient
`RecordingPreviewPanel` goes away. The window survives click-away and app switches. Snappy
is `LSUIElement`, so it isn't in ⌘-Tab. You get back to it by clicking it or through Mission
Control, as with the editor.

- **Opens frontmost and takes focus** (deliberate end of the session), like the editor.
  **Except after a W-window auto-stop** (Tefa, 2026-10-11 — final, Q44): there is no user
  interaction, so macOS may decline Snappy's activation — the window comes to the front but
  is not key until clicked. The ⇧⌘4 / toolbar ■ / menu bar ● stops get focus. See
  `docs/recording-reviews/v2-v1.dev.md` › Fix round 1, finding 2.
- **Tahoe Glass** like the editor: the `AVPlayerView` (autoplay, loop, muted, scrub bar) is the
  canvas under a glass toolbar **Retake · Save · prominent Copy** (trailing), plus a glass status
  capsule `Recording W × H · 0:42` (since 2026-10-20: `W × H · 0:42 · [export-size slider] · size`,
  see *Export size*).
- **No video annotation** in this version (Q29). Live ink while recording covers annotations
  that change over time. Post-hoc whole-clip shapes (blur over a token, callouts) and timed
  annotations stay deferred.

| Key | Action | Window afterwards |
| --- | ------ | ----------------- |
| **Space** | Play / pause | stays open |
| **R** | Retake → Setup with the same target + setup annotations | closes |
| **⌘S** | Save `Recording … .mp4` (never overwrites, ` (2)`) | **stays open** |
| **⇧⌘C / ⌘C** | Copy the file to the pasteboard (the "done" action, as in the editor) | **closes** |
| **Q · Esc · ⌘W · traffic light** | Close, **no prompt** (Q32) — during an export re-encode Q / Esc / ⌘W cancel only the re-encode | closes |
| **[ / ]** | Smaller / larger export size (see *Export size* below) | stays open |

**Take lifetime (Q30):** each window **owns its take**. A new recording no longer deletes a
take whose window is still open, so **several recording windows can coexist** (like editors).
Closing a window deletes its take, **except the latest take**, which stays in Caches for
"Reopen Last Recording" until a newer take exists *and* its own window is closed.
**Reopen Last Recording** brings that take's window to the front if it's open, and never opens a
second copy (Q43).

### Export size (2026-10-20)

> *Implemented on `feature/export-size`; manual checklist pending.* All decisions agreed with Tefa
> before implementation.

The status capsule reads **`W × H · 0:42 · [slider] 50 % · ≤ 4.6 MB`**. The slider snaps to four
stops — **100 / 75 / 50 / 25 %** — and is also stepped with **`[`** (smaller) and **`]`** (larger);
tooltips "Change export size ([ ])", "Smaller export ([)", "Larger export (])". `W × H` is the
export's pixel size at the current stop; the window title keeps the take's own size.

- **Resolution only.** A stop scales both sides, rounded to the nearest **even** pixel; the frame
  rate stays the take's; the bitrate follows the recording rule (`OutputGeometry.bitrate`, bits per
  pixel at the current *Video quality*) for the new size. No other knob — no trim, audio, GIF or
  fit-to-size target.
- **Size readout.** At 100 % the take's real file size ("18.4 MB"). At a smaller stop an
  upper bound **"≤ X MB"** (target bitrate × at least 1 s × 1.5 headroom + MP4 overhead, rounded
  up), replaced by the real size as soon as a re-encode (or a Save) at that stop exists. The bound
  is **guaranteed**: the re-encode caps its rate and checks the file against it, retries leaner
  (twice at most) when over, and otherwise fails with "Export failed" — it never keeps a bigger file.
- **Narrow window.** The capsule stays inside the window; when it can't fit, the `W × H · 0:42`
  readout gives way first (the title still names the take's size) — slider, stop and size stay.
- **The take is never modified.** Save and Copy both export at the current stop. **100 %** is the
  old path, unchanged — no re-encode, bit-identical. A **smaller stop** re-encodes (AVAssetReader →
  AVAssetWriter, H.264 MP4, no audio) into a separate temp file, then Save writes it as
  `Recording … .mp4` (never overwriting) and Copy pastes a `Recording … .mp4` clone. The window keeps
  one re-encode (the latest stop) and deletes it when it closes.
- **Copy after Save** always matches the slider: a saved file is reused only when it was saved at
  the same stop, otherwise Copy re-encodes.
- **While encoding** the pressed button turns into a progress ring (VoiceOver reads "Exporting
  42 %", tooltip "Cancel export (Esc)"); the window stays usable (play, scrub, slider); another
  Save/Copy beeps. **Esc / Q / ⌘W cancel only the re-encode.** The re-encode keeps the stop it was
  started at. On failure the capsule shows **"Export failed"** in red until the stop changes or the
  next export starts — nothing is saved or copied, and it **never** falls back to the full-size file.
- **Settings → Recording › Default export size** (100 / 75 / 50 / 25 %, default **100 %**): every new
  recording window opens at it. Moving the slider is a per-take override and never writes back.
- The capsule is no longer click-through (the slider needs the mouse); it grew to 36 pt for the
  slider's 28 pt hit target.

### Snap mode keys (Q33)

> *Implemented (V2, 2026-10-11 — `docs/recording-reviews/v2-v2.dev.md`); manual checklist pending.*

| Key in S/W snap mode | v1 (today) | **v2** |
| -------------------- | ---------- | ------ |
| Same key again (S, S / W, W) | confirm | **back to the previous rect/target** (= Esc) |
| The other snap key | switch mode | switch mode (unchanged) |
| Click | confirm | confirm |
| **Return / keypad Enter** | nothing | **confirm** |
| Esc / Q | back | back (unchanged) |

Applies to **S and W alike**. Tooltips and the shortcuts table follow.

### Window parts (Q34–Q42)

> *Picker implemented (V2, 2026-10-11 — `docs/recording-reviews/v2-v2.dev.md`; Q34–Q36, Q38–Q40); part targets in recording implemented (V3, 2026-10-11 — `docs/recording-reviews/v2-v3.dev.md`; Q37, Q41, Q42). Manual checklists pending.*

S and W pick **parts of a window** (browser page area, tab strip + page, sidebar, editor
pane …) as well as whole windows, through the **Accessibility API** (`AXUIElement`).
ScreenCaptureKit only knows whole windows.

**Picking — automatic, following the pointer (Q35):**

| Pointer position | Selects |
| ---------------- | ------- |
| On the **title bar**, or within **~16 pt of the window's edge** | the whole window |
| Anywhere else | the **smallest meaningful part** under the pointer |

A *meaningful part* is a **container role** (web area, scroll area, split-view pane, tab group,
toolbar, sidebar/outline, table), **≥ ~120 × 80 pt**, and **clearly smaller than its parent**,
so nested near-identical boxes collapse into one. Buttons, text and links are never picked.
16 pt and 120 × 80 pt are tuning values, to be adjusted live against Chrome, Safari and VS Code.
**Override:** **↑ / ↓** (or scrolling) widens or narrows the pick by one level at the pointer,
and moving the pointer goes back to the automatic pick.

**Highlight (Q36):** it **glides** between rects (~0.12 s, instant with *Reduce Motion*) and
shows a chip with the part's name and size, e.g. `Web page · 1280 × 720`, `Window · Chrome`.

**What gets recorded:**

| Mode + part | Recorded | Notes |
| ----------- | -------- | ----- |
| **W + part** (Q37) | the window itself (`desktopIndependentWindow`), **cropped live to the part** | the part's frame is polled through AX (~10 Hz). A size change **letterboxes** (as a W window resize does today). If the part disappears (tab closed, navigated), the **last rect** is kept |
| **S + part** (Q38) | the part's **screen region**, fixed, including anything on top of it | same as S on a whole window, just a smaller rect |

- **Border and toolbar** follow the part's live rect. **Live ink stays anchored to the window**
  (as for W today), and ink outside the part is hidden, not deleted (Q42).
- **Off screen** (minimised, another Space, app hidden): same as W today, so it **keeps
  recording and holds the last frame** until stopped.
- **Retake (Q41)** restores the same part. If it's gone, W falls back to the **whole window**
  and S to the **last screen rect**.

**Permission (Q34/Q39):** Accessibility is a second TCC permission. On a Mac managed by an MDM
profile, an administrator may have to allow it.
- The **first time S/W snap mode is entered without access**, the macOS prompt is shown **once**
  (`AXIsProcessTrustedWithOptions`). That session carries on with whole windows, and Snappy
  never prompts automatically again.
- **Settings → Recording** gets a status row: *Window parts: ✅ Allowed* / *⚠️ Needs Accessibility
  — Open System Settings…*.
- **Without access** (or if IT blocks it), W/S work on whole windows exactly as in v1.
- The stable "Snappy Dev" signature keeps the grant across rebuilds.

**Apps that hide their tree (Q40):** Chromium browsers and Electron apps may expose no inner
parts until asked. If the tree under the pointer comes back empty, Snappy sets
`AXEnhancedUserInterface` (Chromium) / `AXManualAccessibility` (Electron) **on that app only**,
and **restores it when the recording session ends**. Side effects: a bit more CPU/RAM in that
app, and possibly odd window animations. *Whether Chrome actually needs this is verified during
implementation.* If an app still has no tree, it gets **whole window only** (`Window · AppName`)
with no error.

> **Known limitation (V2 fix round 2, 2026-10-11):** Snappy only switches a value it could
> *read* as off — a failed read may hide another assistive client's `true`, which the restore
> would then clear. An Electron build that implements only the *setter* of
> `AXManualAccessibility` is therefore never switched and gets whole windows. Modern Electron
> implements the getter too (`electron_application.mm`, v40), so this only affects old builds.

**Not changed:** AX is **not** used to tell a minimised window from a closed one (Q13 stays as is).

### Known follow-ups (v2)

From Sol's whole-feature E2E evaluation (`docs/recording-reviews/v2-e2e.report.md`, verdict
READY TO MERGE). All are minor and non-blocking, and none is fixed yet:

1. **Held-frame settling still assumes the new crop** (E2E finding 1): `Sources/Snappy/Recording/PartCrop.swift:225`,
   `Sources/Snappy/Recording/RecordingPipeline.swift:826`, `docs/ARCHITECTURE.md` › W + part
   crop timing. If an old-crop sample falls in the uncertain transition band and the new sample is
   delayed past the two-frame grace, settling assigns the requested crop to the held pixels, so
   the ink is briefly placed against the wrong crop. Fix: qualify the guarantee in the docs
   (late delivery counts too, not just no new frame) and test late new-frame delivery. A strict
   guarantee needs a verified per-frame crop signal.
2. **Held-only updates keep obsolete crop history** (E2E finding 2): `PartCrop.swift:300`, `:306`;
   `RecordingPipeline.swift:822`. A static window that only gives held frames never folds older
   transitions, so lookups under the decoration lock scan a growing history. It is released with
   the take. Fix: fold transitions strictly older than the received presentation times on the
   uncertain path too, and add a test for repeated held-only updates.
3. **Auto-stop "not key until clicked" describes what Tefa accepted, but the code doesn't enforce
   it** (E2E finding 4): `RecordingCoordinator.swift:379`, `RecordingWindowController.swift:200`.
   Every stop asks for activation, the auto-stop too, and every new window calls `takeFocus()`. So
   if activation succeeds (or Snappy is already active), the auto-stop window can still become
   key. Fix: either reword option (a) as "focus after an auto-stop isn't guaranteed (cooperative
   activation)", or, if a passive auto-stop is wanted, pass the stop origin to the window and only
   order it front for that route.

### Implementation outline (as planned)

1. **Recording window**: a `RecordingWindowController` (titled, Tahoe Glass, owned in an array
   like `editors`) replaces `RecordingPreviewPanel` behind `RecordingPreviewPresenting`.
   `RecordingTempStore` moves from "one take, deleted at the next start" to **per-window
   ownership + latest-take retention**. Reopen focuses the existing window.
2. **Snap keys**: `RecordingKeyMap` snapping layer (same key → `.stepBack`, Return/Enter → confirm) + tests.
3. **AX part picker**: a PURE part-selection model (edge band, role/size/parent-ratio filter,
   ↑/↓ depth override) over an injectable AX tree, unit-tested with fake trees; a live AX
   adapter (hit-test `AXUIElementCopyElementAtPosition`, frames, Chromium/Electron switch +
   restore); a gliding highlight + name chip in `WindowSnapPicker`/Setup overlay.
4. **Part targets**: `RecordingTarget` gains a part case (window + AX element + last rect). The W
   pipeline crops live (`sourceRect` on the window stream, verify), polled ~10 Hz, letterboxing
   on size change. S uses the fixed screen rect. Chrome follows the part; ink stays window-anchored.
5. **Permission**: one-time prompt on the first snap mode entry + the Settings → Recording status row.
6. **Docs**: `ARCHITECTURE.md` › Recording (window ownership, take lifetime, AX invariants),
   `shortcuts-ux.md`, this doc's checklist, `FEATURE_MAP.md`.

## Settings → Recording (Q10/Q27) — every option is adjustable

| Setting | Values | Default |
| ------- | ------ | ------- |
| Countdown | Off / 1 / 2 / 3 / 5 s | **3 s** |
| Frame rate | 30 / 60 fps | **60** |
| Show cursor | on/off | **on** |
| Click ripples | on/off | **on** |
| Fading ink on at start | on/off | **off** |
| Fade delay | 1–10 s | **3 s** |
| Default colour | the 5 presets | **red** |
| Default line width | thin / medium / thick | **medium** |
| Video quality | Standard / High (bitrate) | **High** |
| Default export size | 100 / 75 / 50 / 25 % — the stop a new recording window opens at (its slider overrides it per take, never writing back) | **100 %** |
| Draw-mode hot key | recorder field (applies live, also mid-session) | **⌃⌥D** |
| Magic Pen hot key | recorder field (⌘, ⌃ or ⌥ required; refuses ⌃⌥D / Snappy's hot keys; applies live) | **⌃⌥P** |
| Magic Pen thickness | Thin / Medium / Thick — **also in the menu bar**, applied live | **Medium** |

## Magic Pen (2026-10-15)

**Tefa's request:** "a magic pen for recording: annotate freely while recording, the ink fades
away after marking something. Smooth, easy to see, slightly transparent. Thickness adjustable
from the menu bar. A convenient shortcut that works while recording and uses no single plain
character." The clarifying questions were left open, so the defaults below were chosen during
implementation. **Every row of the decision table is a default that the author still has to confirm.**

### How it works

| | |
| - | - |
| **Turn on** | **⌃⌥P** (session-only global hot key, like ⌃⌥D) or the toolbar's **wand** button (`wand.and.stars`, "Draw fading ink (⌃⌥P)"), from interact **or** draw mode — no ⌃⌥D, P, F sequence |
| **While on** | the ink panel takes mouse + keys **without activating Snappy** (draw mode's mechanism); your app keeps the menu bar. Every stroke is a Magic Pen stroke |
| **Turn off** | **⌃⌥P again** or **Esc / Q** → back to **where you came from** (interact, or draw mode with the tool you had). **V** → always interact. **⌃⌥D** → normal draw mode (last tool). A tool key (P H A O B) → that tool in draw mode |
| **Look** | vivid red-orange **#FF451A**, **85 % opacity** (the highlighter stays 40 %), round caps/joins, midpoint-quad smoothing + light point thinning (3 pt; pen: 2 pt), a soft dark halo (2 pt each side, black @ 28 %) under the stroke so it stays visible on white. Drawn by `InkRenderer`, so the screen and the video are pixel-identical |
| **Fading** | **always** — independent of F and of "Fading ink" in Settings. Holds for the **Fade after** delay (Settings, default 3 s), then fades out over **0.6 s**. Never a Setup (permanent) annotation; Retake never restores it |
| **Thickness** | its own setting, separate from the line width: Thin **4 pt** · Medium **6 pt** (default) · Thick **10 pt**. Changed from the menu bar, Settings → Recording, **[ / ]** in Magic Pen mode, or the toolbar's Width menu while the Magic Pen is on; persisted, applied live to the **next** stroke |
| **Keys while on** | as draw mode: **⌫** clear, **⌘Z / ⇧⌘Z** undo/redo, **1–5** ink colour (the normal ink's — the Magic Pen keeps its colour), tool letters; **[ ]** = Magic Pen thickness; **F** does nothing. No key ever reaches your app while the ink panel is key, and no key needs to be a plain character to turn it on or off |
| **Stop** | unchanged: ⇧⌘4 · toolbar ■ · a plain click on the menu bar ● |

### Menu bar

- **Normal menu:** "Magic Pen Thickness ▸ Thin · Medium · Thick" (checkmark on the current one),
  in the recording group under "Reopen Last Recording". It's a setting, so it works without a
  recording too.
- **While recording:** a **plain click on the red ● still stops** (Tefa's 2026-10-09 decision,
  unchanged). A **right-click, ⌃-click or ⌥-click** opens a small menu: *Magic Pen Thickness*
  (Thin / Medium / Thick, checked) · *Stop Recording* (⇧⌘4). VoiceOver gets the same menu as a
  custom action ("Magic Pen Thickness") on the item. The ● tooltip reads "Stop recording (⇧⌘4)" — the configured Capture Area combo, updated live;
  Settings' Magic Pen hint names the right-click.
- Menu text comes from PURE types (`MagicPenThicknessMenu`, `RecordingStatusMenu`,
  `RecordingStatusClick`), tested like `StatusMenuCommand`.

### Settings → Recording

Two new rows under *Draw mode*: **Magic Pen:** shortcut recorder + Reset (same rules as the
draw-mode recorder: ⌘, ⌃ or ⌥ required — one rule for every hot key since 2026-10-20 —, letters/digits only; refuses ⇧⌘4/⇧⌘3 **and the draw-mode
shortcut**, which in turn refuses the Magic Pen's; Reset's tooltip reads "Reset the Magic Pen
shortcut to ⌃⌥P (Space)"), and **Magic Pen thickness:** pop-up with red-orange line samples; a
hint underneath. Unlike the other Recording rows the pop-up goes through the coordinator, as the
menu bar does, so a running session picks the new thickness up for its next stroke; an open
Settings window follows a change made from the menu bar, [ ] or the toolbar.

### Decision table (defaults, awaiting the author's confirmation)

| # | Decision | Alternatives not taken |
| - | -------- | ---------------------- |
| MP1 | **A toggle mode, not a new engine**: a third recording mode `magicPen(resume:)` next to interact/draw, on the existing ink panel, compositor and fade model | a separate tool in the picker (would need ⌃⌥D, P, F); a separate overlay |
| MP2 | **⌃⌥P**, session-only, configurable, must hold ⌘, ⌃ or ⌥ (*superseded 2026-10-20: was ⌃ or ⌥ only — one rule for all four hot keys, see `shortcuts-ux.md`*), refused if it equals ⌃⌥D or a Snappy hot key; refused by the system → banner + the toolbar button still works | a plain letter (would be typed into the user's app) |
| MP3 | **Turning off returns to where you came from** (interact or the draw tool); V → interact; ⌃⌥D → normal draw mode | always back to interact (the brief's wording) — kept for the common case, since entering from interact returns there |
| MP4 | **Always fades**, delay = Settings' *Fade after*, 0.6 s fade-out; never setup ink | its own delay setting |
| MP5 | **#FF451A @ 85 %**, soft dark halo, own thickness 4/6/10 pt (default Medium) | colour choice per preset (1–5 keep changing the normal ink) |
| MP6 | **Menu bar:** submenu in the normal menu; while recording, right-/⌃-/⌥-click opens Thickness + Stop, plain click still stops | a menu on every click (would break Tefa's "click stops") |
| MP7 | **[ ]** in Magic Pen mode and the toolbar's Width menu while it is on set the Magic Pen thickness; F is off there | [ ] changing the normal width (invisible while drawing Magic Pen ink) |

## Architecture

Implemented as planned; the module map (every file under `Sources/Snappy/Recording/`),
the recording flow and **all recording invariants** now live in
[`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) (*Module map* › Recording, *Recording flow*,
*Invariants* › Recording). They moved there at integration (T7). Change them there, in the
same change as the code.

## Decision log (grilling session, 2026-10-09)

| # | Decision |
|---|----------|
| Q1 | Entry: **R in the screenshot preview panel** + menu bar "Record Area…". Screenshot flow unchanged |
| Q2 | Bare letters only when Snappy has focus (Setup / draw mode); interact mode leaves every key to the app; ⇧⌘4 stops; ⌃⌥D toggles draw/interact |
| Q3 | Stop ends the session → preview panel with replay; Esc in Setup cancels; Esc in snap mode → previous rect |
| Q4/Q12 | Three targets: free area (drag outside), S = window's area, W = window itself |
| Q5 | Move, 8 handles, size chip, arrow-key nudge, **scroll = resize around centre** (Q21 a) |
| Q6 | v1 tools as above; deferred list documented |
| Q7 | MP4 H.264, no audio, no GIF in v1 |
| Q8/Q17 | Preview panel: R Retake, ⌘S Save, ⇧⌘C Copy, Space, Esc/Q; not auto-saved |
| Q9 | Border + glass toolbar + red menu bar indicator (● + elapsed time since 2026-10-09), Tahoe Glass style |
| Q10/Q27 | Every recording option adjustable in Settings (table above) |
| Q11 | One display per recording |
| Q13 | Window mode follows, letterboxes on resize, window-anchored ink, auto-stops on close (or app quit); **off screen (minimised / other Space / app hidden) keeps recording until you stop it** (Tefa, 2026-10-09 — final) |
| Q14/Q22 | Recording key map with **B = Box**; snapshot editor untouched |
| Q15/Q23 | No letter ever stops a recording; tool keys only in draw mode |
| Q16 | Setup annotations permanent; screen-anchored; hidden (not deleted) outside a new rect |
| Q18 | Close keeps the last take in Caches until the next recording → "Reopen Last Recording" |
| Q19 | Retake → Setup with same target + setup annotations |
| Q20 | No pause in v1 |
| Q24 | Copy/Save need modifiers in the recording panel; Retake is bare R |
| Q25 | Colour presets 1–5, widths [ ], highlighter fixed thick 40 % |
| Q26 | No DND / hide-icons in v1 |

### Leader decisions (during implementation; Tefa informed)

| Decision | Where |
| -------- | ----- |
| ~~**Draw-mode hot key must include ⌃ or ⌥**: plain ⌘ / ⇧⌘ combos are refused, because Carbon swallows the combo system-wide for the whole session (⌘C/⌘V would die in the recorded app)~~ — *superseded 2026-10-20: every hot key needs at least one of ⌘/⌃/⌥ (`shortcuts-ux.md`)* | T6, Settings recorder |
| **A W target is locked in Setup**: no handles, move or resize; drag outside or S/W replaces it | T1 |
| **⌥-arrow resizes the rect from the keyboard**: → ← right edge, ↑ ↓ top edge, 1 pt (⇧⌥ 10 pt) — shortcuts-first rule | T1 |
| **Fading ink**: fully visible for the fade delay (counted from mouse-up), then a **0.6 s** fade-out | T3 |
| **Draw mode takes keys via the non-activating ink panel, without activating Snappy** (the design originally said "draw mode activates Snappy"). Verified live in T7: the user's app keeps the menu bar and stays active | T3, T7 |
| **The Settings pane scrolls when it is taller than the screen's visible frame** (single pane kept; tabs are Tefa's call) | T6 |
| **W window off screen keeps recording; auto-stop only when it is really gone** (closed / app quit) — made final by Tefa, see below | T2 |
| **A mid-recording failure (disk full, writer error) discards the take** — made final by Tefa, see below | T0, T2 |

### Tefa's decisions (2026-10-09, final)

| # | Decision |
| - | -------- |
| 1 | **W window off screen** (minimised / another Space / app hidden) **keeps recording until Tefa stops it** (⇧⌘4 / toolbar ■ / menu bar ●). Only a **closed** window (or a terminated app) auto-stops. `WindowTrackingState.offScreenEndsRecording` stays `false` |
| 2 | **Recording indicator in the menu bar**: a red ● plus the elapsed time (`● 0:42`, `● 1:02:03`), once per second from the toolbar timer's start, monospaced digits, VoiceOver "Recording, 0:42, click to stop"; a click stops; back to the "S" glyph at session end |
| 3 | **Mid-recording failure → discard** the take and show the error alert (`RecordingCoordinator.failedTakeHandling = .discard`) |

## Decision log v2 (grilling session, 2026-10-11 — V1, V2 and V3 implemented)

| # | Decision |
|---|----------|
| Q28 | Stop opens a **persistent titled recording window** (editor-like); the transient preview panel is removed |
| Q29 | **No video annotation** for now (deferred, see table above) |
| Q30 | Each window **owns its take**; several windows coexist; closing deletes the take **unless it's the latest** (kept for Reopen) |
| Q31 | Window: player + toolbar Retake · Save · prominent Copy; Space · R (closes) · ⌘S (stays open) · ⇧⌘C/⌘C (closes) |
| Q32 | Q · Esc · ⌘W · traffic light close, **no prompt** |
| Q33 | Snap mode: **same key again = back** (= Esc), **click or Return/Enter confirms**, other snap key switches; S and W alike |
| Q34 | **Window parts via Accessibility**; denied/blocked → whole windows as in v1 |
| Q35 | Pointer-driven pick: title bar / ~16 pt edge band = whole window, else the smallest meaningful container part (≥ ~120 × 80 pt, clearly smaller than its parent); **↑/↓ or scroll** override one level |
| Q36 | Highlight **glides** (~0.12 s, Reduce Motion = instant) with a name + size chip |
| Q37 | **W + part** = window stream **cropped live** to the part (AX poll ~10 Hz), letterbox on size change, last rect if the part disappears |
| Q38 | **S + part** = the part's fixed screen region |
| Q39 | Accessibility prompt **once**, on the first S/W snap mode entry without access; Settings → Recording status row |
| Q40 | Chromium/Electron: set `AXEnhancedUserInterface` / `AXManualAccessibility` **only if the tree is empty**, on that app only, restored at session end |
| Q41 | Retake restores the same part; gone → whole window (W) / last rect (S) |
| Q42 | Border + toolbar follow the part; live ink stays window-anchored; ink outside the part hidden, not deleted |
| Q43 | Reopen Last Recording **fronts the existing window**, never a second copy |
| Q44 | Defaults: window opens frontmost with focus — **after a W-window auto-stop it comes to the front but is not key until clicked; ⇧⌘4 / toolbar ■ / menu bar ● stops get focus** (Tefa, 2026-10-11 — option (a)); part off screen keeps recording (holds last frame); no-tree app → whole window, no error; AX not used for minimised-vs-closed |

## Log

- **2026-10-09** — Designed in a grilling session with Tefa; split into parallel tasks (`docs/RECORDING_PLAN.md`). No code yet.
- **2026-10-09** — T0 foundation & contracts: pure `RecordingSession` / `RecordingKeyMap` / `RecordingTarget` / `RecordingSettings` / `RecordingTempStore`, the component protocols + stubs, `RecordingCoordinator`, Record (R) in the screenshot panel, menu "Record Area…" + "Reopen Last Recording", context-sensitive ⇧⌘4, session-only ⌃⌥D; flow runs on stubs. Interpretation (from the plan): **"Record Area…" runs the normal frozen ⇧⌘4 drag and goes straight into Setup with that rect** — no screenshot panel in between; the screenshot flow is unchanged. Implementation choices: an extra `stopping` phase (a second ⇧⌘4 while the file finalises is ignored); a toolbar tool picked in interact mode enters draw mode; a window target that closes *before* recording becomes its area; Cancel while recording discards the take; Retake keeps the ink style. Review round 1: callbacks and async results are scoped to their session; Cancel/failure orders the UI out at once but keeps recording **busy until the old pipeline's single `stop()` returns** (draining), so a new take can't delete a file still being written; reactivation happens on the transition into interact mode only; fullscreen and post-pick window captures block a new session (one token per pending request, round 2). A mid-recording failure still discards the take (Q1 open with Tefa — one constant, `failedTakeHandling`). Report: `docs/recording-reviews/t0.dev.md`
- **2026-10-09** — T1 Setup overlay & snapping: `RecordingSetupOverlay` (one transparent non-activating panel on the target display, overlay invariants 1–6, level `RecordingWindowLevel.setup`), PURE `SetupGeometry` (clamp, move, 1/10 pt nudge, scroll-resize around the centre with the gesture's aspect kept in whole points, 8-handle hit-test + resize that stops at the 40 pt min size instead of flipping, drag-outside re-select with a 3 pt click threshold, size chip, dimming) and `WindowSnapPicker` (fresh `SCShareableContent` per snap visit, own PID / layer ≠ 0 / off-screen / < 40 pt / other-display windows dropped, front-to-back first hit, SCK→AppKit via `CaptureGeometry`). Choices: size chip **inside** the rect's top-left (never collides with T4's border/toolbar outside it); round white handles; 30 % dimming (45 % + opaque handle outline with Increase Contrast); a **W target is locked** (no handles/move/scroll — drag outside or S/W replaces it); hovering no window while snapping shows the pre-snap rect and a click there does nothing; tool mode freezes the rect; Setup keys that land on another recording window (ink/chrome) are mapped by the overlay's monitor. **Leader decisions (Tefa informed):** the locked W target is confirmed; **⌥-arrow resizes from the keyboard** (→ ← right edge, ↑ ↓ top edge, 1 pt, ⇧⌥ 10 pt, same clamp/min size; shortcuts-first rule). Review round 1: the overlay normalises the incoming area target (on its display, ≥ 40 pt, that display's ID — a 1 × 1 screenshot → R gives 40 × 40) and converts S ↔ W over a hovered window; both are reported **after** the coordinator's broadcast (`SetupTargetSync`), never from inside `apply`; a removed display falls back with its own ID; a locked W target has no hidden handles. Report: `docs/recording-reviews/t1.dev.md`
- **2026-10-09** — T2 capture pipeline: `RecordingPipeline` (SCStream → capture-queue `FrameWriter` actor → CoreImage copy + decorator → AVAssetWriter H.264 MP4), idle re-append, `WindowTracker`, PURE `OutputGeometry` (even sizes, **4096 px/side hardware-encoder cap**, sourceRect, letterbox, bitrate, colour tags, `FrameClock`). Stream failures leave a salvageable file. Report: `docs/recording-reviews/t2.dev.md`
- **2026-10-09** — T2 review round 1 (**Leader decision**, pending Tefa): W-mode auto-stops only when the window is really gone (closed / app terminated); off screen (minimised, other Space, app hidden) it keeps recording — switch `WindowTrackingState.offScreenEndsRecording`. Area recordings never fall back to a window-list exclusion (refetch once, then a readable error). Failures during start are thrown by `start`; composition failures fail the take (still salvageable); idle frames keep the configured rate. Measured 0/300 dropped at 60 fps, 4096×2304. Report: `docs/recording-reviews/t2.dev.md`
- **2026-10-09** — T3 live ink: PURE `LiveInk` model (pen/highlighter/arrow/oval/box, setup strokes permanent, recorded strokes fade when fading is on, undo/redo/clear, expired strokes pruned from the history too, clipping = hidden not deleted, setup snapshot for Retake) + `InkScene` → editor `Annotation`s, drawn by one `InkRenderer` for the on-screen `LiveInkView` and the `RecordingCompositor` (scene behind an `OSAllocatedUnfairLock`, fades evaluated at each frame's host time, safe after `close()`), `LiveInkPanel: LiveInkHosting` (non-activating panel at `RecordingWindowLevel.ink`, click-through unless a tool is picked). Choices: a fading stroke stays fully visible for the fade delay (counted from mouse-up), then fades out over 0.6 s; strokes drawn while the target is a window are anchored to its top-left and follow it, strokes drawn on an area stay at their screen position (also after a later W snap); Retake restores the setup ink **as it was when recording started** (a ⌫ during the take doesn't lose it); draw mode takes key status **without activating Snappy** and gives it back on leaving draw mode; clicks without a drag draw nothing. Report: `docs/recording-reviews/t3.dev.md`
- **2026-10-09** — T4 recording chrome: `RecordingChrome` (border, glass toolbar, countdown disc, timer; three never-key `.nonactivatingPanel`s at `RecordingWindowLevel.chrome`), PURE `ChromeLayout` (border ring outside the rect, one panel per display it reaches, folding inward only for an area at a physical screen edge; toolbar below → above → inside, clamped to the visible frame; disc 120 pt, ≥ 56 pt), `RecordingToolbarItem` / `RecordingToolbarState` (a control is enabled exactly when the session would act on it — tested against `RecordingSession`), `RecordingTimerText`, `CountdownSequence`, and the menu bar red ■ (`RecordingStatusGlyph`; menu removed while recording, a click stops). `apple-design` pass: monochrome symbols with hover-only borders (no bezel boxes on the glass), selection = the on-state platter (not colour alone), Record/Stop the single coloured control, a 1 pt dark hairline outside the 3 pt band so amber stays ≥ 3:1 on white, no countdown animation + VoiceOver announcements. Decisions: Color/Width are menus (Width sends `[`/`]` steps), a tooltip advertises a key only in phases where pressing it does what the click does (Esc on Cancel only in Setup/Pointer; tool keys not in interact mode), the countdown/snapping toolbar kept only Cancel enabled *(historical: since 2026-10-20 Area and Window stay enabled while snapping — see the Area / Window toolbar buttons entry below)*. Report: `docs/recording-reviews/t4.dev.md`
- **2026-10-09** — T5 recording preview panel: `RecordingPreviewPanel` (implements `RecordingPreviewPresenting`; Tahoe Glass panel like the screenshot preview, `AVPlayerView` floating controls, autoplay, `AVQueuePlayer` + `AVPlayerLooper` loop, muted), PURE `RecordingPreviewAction` (Space · R · ⌘S · ⇧⌘C/⌘C · Esc/Q/⌘W; plain C/S do nothing), `RecordingNamer`, `RecordingPreviewLayout`, additive `ScreenshotSaver.copyWithoutOverwriting` (screenshot path unchanged). Choices: **every action dismisses the panel** (screenshot-panel convention; Reopen brings it back); Save copies the take, never moves it, and **names the file after the take's recording time** (its modification date), so a take reopened later keeps its own time; **Copy of an unsaved take pastes a `Recording … .mp4` clone** from the system temp dir instead of `Take-<id>.mp4` (the saved file once saved). Review round 1: Save **stages a private hard link of the take synchronously** before it yields, so a recording started during a slow export can't delete its source (round 2: and a missing take is refused, never fabricated as an empty file); Space is play/pause everywhere, focused button or not. Report: `docs/recording-reviews/t5.dev.md`
- **2026-10-09** — T6 Settings UI: a **Recording** section in Snappy Settings (separator + heading under the existing rows, one control per row of the Settings table, written straight to `SettingsStore`, read at the next session start). Countdown / Frame rate / Quality pop-ups; "Show in video" Pointer + Click ripples checkboxes; **Ink** row = colour pop-up (swatches) + width pop-up (line samples); Fading ink checkbox; Fade after = value + stepper 1–10 s; Draw mode = shortcut recorder (click, press the combo; Esc cancels, Tab leaves) + Reset (disabled at ⌃⌥D). PURE `HotKeyRecorderInput` / `RecordingSettingsText` / `ReservedHotKey` in `SettingsFormatting` (tested). Recorder accepts letters and digits only (`displayString` can't name other keys; HIG Keyboards) and refuses Snappy's own hot keys by name. **Leader decision (Tefa informed): the draw-mode shortcut must hold ⌃ or ⌥** — plain ⌘ / ⇧⌘ combos are refused ("Include ⌃ or ⌥ — ⌘ shortcuts belong to your apps."), because Carbon swallows the combo system-wide for the whole session and ⌘C/⌘V would stop working in the recorded app. The pane is ~780 pt tall with 28 pt checkboxes; it stays a single pane (tabs are Tefa's call), and **when it is taller than the screen's visible frame (e.g. 1280×800 with a bottom Dock) the window is clamped to that height and the pane scrolls** (Leader decision, review round 1; PURE `SettingsPaneFit`); nothing changes when it fits. The section is self-contained and can move into a tab as is. Report: `docs/recording-reviews/t6.dev.md`
- **2026-10-09** — T7 integration & verification: the stubs are gone; `RecordingComponents.current` (now in `RecordingCoordinator.swift`) builds the real Setup overlay, pipeline, live ink, chrome and preview panel. `UserFacingText.recordingSaveFailed` moved into `App/UserFacingText.swift`. The interact-mode hand-back now **yields activation** to the user's app before activating it (cooperative activation). New `RecordingIntegrationTests` run the real overlay + ink + chrome under the real coordinator: window levels setup < ink < chrome, every recording window a non-activating panel, chrome never key, click-through per mode, ink + border follow a moving W window, Retake brings back the setup ink but not the recorded strokes. **Live on this Mac** (throwaway harness, never committed): focus lands as designed — the user's app is frontmost after record start and after draw → interact, and **draw mode takes keys through the non-activating ink panel without activating Snappy** (the user's app keeps the menu bar), so the Leader's decision holds natively and no fallback activation was added; the ink is in the video at the drawn position, the chrome is not; 60 fps at 3600 × 2338 px with ink and a busy screen: no dropped stretches, 66–70 % of one core, ~18 % near-duplicate frames from the idle re-append (filed with the Leader as a T2 `FrameClock` follow-up). Invariants moved into `docs/ARCHITECTURE.md` (module map, recording flow, *Invariants › Recording*); Leader decisions recorded above; shortcuts table finalised. Report: `docs/recording-reviews/t7.dev.md`
- **2026-10-09** — T7 review round 1 + Tefa's decisions: **one frame per slot** — `FrameClock` gives a real SCK frame a ¼-interval grace over the idle re-append while SCK is delivering and skips a captured frame that would crowd the last one (it becomes the next slot's content), so takes no longer hold ~18 % near-duplicates (*round 2: the rate ceiling still failed for sparse captures — see the next line*); the idle cadence is unchanged (T2's tests green, new mixed-source tests at 30/60 fps); live: 57–59 fps at 60, no duplicates. **Draw-mode hot key refused** (another app owns it): banner, no dead shortcut in the toolbar tooltip (new `RecordingChromeHosting.setDrawModeShortcut`), toggle still works; `HotKeyCenter.register` returns the result and `isRegistered` means a live Carbon key. Key routing now tested through `NSApp.sendEvent` (Setup monitor vs ink view, draw mode, interact mode). **Tefa (final):** off-screen W window keeps recording until stopped; **menu bar shows a red ● + elapsed time** (`● 0:42`) while recording; a mid-recording failure discards the take. Report: `docs/recording-reviews/t7.dev.md`
- **2026-10-09** — T7 review round 2: **a fixed slot grid** in `FrameClock` — slot k = t0 + k / fps from the take's first frame; every frame (captured, idle, closing) is stamped on a slot and every append takes a later slot, so **no second of video can exceed the frame rate** by construction (the reviewer's probe — captures 1.75 intervals apart — gave 68.5 fps at 60 with the round-1 clock, now exactly 60). A real frame claims its slot within 0.4 interval of normal delivery latency (idle waits that long while SCK delivered in the last second); a stalled timer resyncs, never bursts; static stretches are filled at exactly the frame rate. Locked by property tests over 1 000 seeded random runs (capture rate, latency, jitter, tick rate) plus the reviewer's probe, mutation-checked. Menu bar indicator lifecycle now tested through `StatusItemController` (seams `StatusItemHosting` / `StatusItemTicker`): `● 0:00` at record, ticks, click stops, the "S" item returns after Stop / Cancel / failure / cancel-during-start, a second take starts at zero. **Leader decision:** after wave 1, T7 owns integration across `Recording/` and the shared hooks (`docs/RECORDING_PLAN.md`). Report: `docs/recording-reviews/t7.dev.md`

- **2026-10-11** — **v2 designed** (grilling session with Tefa, not implemented): persistent recording window replaces the click-away preview panel (per-window take ownership, latest take kept for Reopen); snap mode S/W same key = back, click/Return confirms; **window parts** (page area, tab strip, panes) picked by pointer through Accessibility, live-cropped for W, fixed region for S; Chromium/Electron tree switch only when needed. Video annotation deferred. Decisions Q28–Q44, section *v2* above.
- **2026-10-11** — v2 **V1 recording window**: `RecordingWindowController` (one persistent titled Tahoe Glass window per take — player canvas, unified glass toolbar Retake · Save · prominent Copy, status capsule `Recording 1280 × 720 · 0:42`, editor backdrop; owned in the coordinator's `windows` array, released in `onClose`) replaces `RecordingPreviewPanel`; PURE `RecordingTakeLedger` (windows counted per take + the latest) decides which takes stay, `prepareNewTake` deletes nothing; Reopen fronts an open window; Retake only asks, so a busy session beeps and keeps the window. Choices: the previous latest is released when a newer take **finishes** (a cancelled/failed recording keeps it reopenable); title/capsule show the video's **pixel** size; windows open centred on the recording's screen and cascade 24 pt; a failed Copy clone keeps the window open with an alert; Retake hidden after a relaunch. Report: `docs/recording-reviews/v2-v1.dev.md`
- **2026-10-11** — v2 V1 **review fix round 1**: the recording window opens **synchronously** at the end of its session (the take's size and duration update it later, never focus), the stop interaction itself asks for activation, and a late activation makes the window key only within 1 s and only while no newer recording or screenshot capture runs; where a take was saved now belongs to the take (`RecordingSavedFiles`), so Save → close → Reopen → Copy pastes the saved file. **Tefa (final, same day):** after a W-window auto-stop the window comes to the front but is not key until clicked (option (a)); the three user-driven stops get focus. Report: `docs/recording-reviews/v2-v1.dev.md` › Fix round 1
- **2026-10-11** — **V2 snap keys + window-part picker** (`rec2/v2-picker`, report `docs/recording-reviews/v2-v2.dev.md`): same snap key = back, Return/Enter confirm; PURE `WindowPartModel` over an injectable tree (edge band 16 pt / title bar 28 pt = whole window, smallest container part ≥ 120 × 80 pt at least 24 pt smaller than the level around it, browser pages atomic, Electron panes via landmarks, ↑/↓/scroll override); live `WindowPartAXTree` (app-scoped hit test; checked live against Brave, Claude, Finder, ChatGPT); gliding highlight + `Web page · 1280 × 720` chip; S + part = fixed rect, W + part = `RecordingTarget.windowPart` (recorded as the whole window until V3); prompt once + Settings → Recording status row; Chromium/Electron tree switch restored at session end and on quit, retried while the app doesn't answer (a fresh Chromium refuses it — its page area is picked from native views instead). Fix round 2: all AX messaging moved onto its own serial executor (`WindowPartAXEngine`) — hover is asynchronous and latest-wins, restores never block the main thread, owed restores are per-process ownership records that a later session using the app (Retake included) adopts.
- **2026-10-15** — **Magic Pen** (report `docs/magic-pen-reports/dev.md`): ⌃⌥P (session-only, configurable, `HotKeyAction.toggleMagicPen = 4`) toggles `RecordingMode.magicPen(resume:)` from interact or draw mode; ⌃⌥P / Esc return where it came from, V → interact, ⌃⌥D → normal draw mode. Strokes are `InkStroke.isMagicPen` pen strokes — always fading, never setup ink — drawn by `InkRenderer` with the `MagicPenLook` (#FF451A, 85 %, soft dark halo as an `InkRenderItem.underlay` in the same transparency layer, 3 pt thinning, 4/6/10 pt). Own thickness setting (`recordingMagicPenWidth`, default Medium) from the menu bar (normal menu submenu; right-/⌃-/⌥-click menu on the recording ● — a plain click still stops), Settings → Recording, [ ] and the toolbar Width menu while on — persisted and applied live. Toolbar wand toggle; key map layer; `LiveInkFocus` keeps the keyboard between draw mode and Magic Pen. All leader decisions, **Tefa to confirm** (MP1–MP7 above).
- **2026-10-15** — Magic Pen **review fix round** (Sol review `docs/magic-pen-reports/sol.md`, report `docs/magic-pen-reports/fix.md`): the Settings thickness pop-up now goes through `RecordingCoordinator.setMagicPenWidth` like the menu bar (it used to write only the store, so a running session kept drawing the old width and [ ] stepped from it); `onMagicPenWidthChange` refreshes an open Settings pop-up after a menu bar / [ ] / toolbar change. Reset tooltips follow `<verb phrase> (KEY)` ("Reset the Magic Pen shortcut to ⌃⌥P (Space)"). The toolbar's key ≡ click test compares content commands exactly and runs from all three widths.
- **2026-10-20** — **Remappable hot keys** ([shortcuts-ux.md](shortcuts-ux.md)): a Draw Mode / Magic Pen change in Settings now applies **during** a running session (`RecordingCoordinator.rebindSessionHotKey` → `HotKeyCenter.replace`; a refused combo keeps the old one and the field says "That shortcut is already taken"; a combo refused at session start is registered by a later successful change and then advertised). Stop's tooltip names the configured Capture Area combo (`RecordingChromeHosting.setStopShortcut`), live too; the ● menu's Stop item likewise.
- **2026-10-11** — **V3 part targets in recording** (`rec2/v3-part-targets`, report `docs/recording-reviews/v2-v3.dev.md`): W + part records the window's own stream **cropped by ScreenCaptureKit** — `sourceRect` on a `desktopIndependentWindow` filter is window-local (top-left, points) and `updateConfiguration` moves it live (verified with a probe; chosen over compositor cropping for native resolution and less data). PURE `PartCropGeometry` / `PartCropTracker` / `DecorationTarget` (`PartCrop.swift`): crop clamped to the window, pixel-snapped, even sides; the part's AX frame polled ~10 Hz through V2's handle and accepted only when the window held still around the read; nil = last rect kept; video size fixed at start, a part of another size letterboxed. Border, toolbar and ink panel follow the part (`onPartFrameChange`); ink stays window-anchored and is hidden outside the part (the decorator gets the part and its window separately); off screen holds like W; Retake opens on the part, then looks it up again (live frame, gone → whole window, closed window → its region; S + part keeps its rect); tracking ends before the session's AX restores. Live (throwaway harness, real pipeline, decoded MP4): every crop, the letterbox, a window move, a vanished part and a window resize as designed; before fix round 1, 5 of 8 crop changes had one frame with the ink still on the old crop. The V2 stopgap ("W + part records the whole window") is gone. **Fix round 1** (review: 2 major, 1 minor): the poll and Retake read the part's **visible** frame (clipped by its live ancestors, as the picker showed it — a table taller than its scroll view no longer widens the crop); frame reads are enqueued in main-actor order and answered only inside a session, and a Retake cancelled before its look-up never reads (an owed restore stays with its retry, Q40); each frame is decorated with the crop it was presented under — frames presented while SCK switches are held instead of guessed — and a failed crop update puts the border back on what is recorded and retries.
- **2026-10-21** — **Export size review r2** (0 blocker, 0 major, 1 minor) — known limitation, accepted by the Leader: when an export exceeds its bound and is retried leaner, the progress ring has already shown 100 % and stays there through the retries (`RecordingTranscoder` reports 1 before the size check).
- **2026-10-21** — **Export size review r1 fixes** (`feature/export-size`): (R2, major) the "≤"
  readout was the encoder's average target × duration, which detailed content beat (161 KB for
  "≤ 125 KB", one frame 24.6 KB for "≤ 5 KB") — now a real bound (≥ 1 s × 1.5× target + MP4
  overhead, rounded up) that the transcoder enforces (1 s data-rate cap, ≤ 2 leaner retries, else
  "Export failed"); (R3) a one-frame take's export doubled in length — the writer session now ends
  at the take's own end; (R1) the capsule is held inside the window and drops its dimensions ·
  duration readout first when too narrow. Tests: noise takes (1/2/30 frames) never exceed the
  capsule's bound, an unfittable bound fails with no output, exact durations for 1/2/7 frames,
  capsule labels unclipped at 440 pt and narrower.
- **2026-10-20** — **Export size** (`feature/export-size`, decisions agreed with Tefa): the recording window's status capsule gets a 4-stop slider (100/75/50/25 %, `[` / `]`) and a size readout (real size, or "≤" estimate at a smaller stop). Save and Copy export at the stop; 100 % is unchanged, smaller stops re-encode into a temp file first (`RecordingTranscoder`, AVAssetReader → AVAssetWriter, writer-side scaling) with a progress ring on the pressed button, Esc/Q/⌘W cancelling only the re-encode, inline "Export failed" and never a full-size fallback. `RecordingSavedFiles` is keyed per stop; PURE `ExportScale` / `ExportSizing` / `ExportSizeText` / `RecordingExportSource`; Settings → Recording › Default export size. Tests: pure math + a real re-encode of a synthetic take (half size, no audio, take bit-identical, cancel removes the partial file) + window flows (Save at 50 %, Copy reuse rule, Esc cancel, failure).
- **2026-10-20** — **Area / Window toolbar buttons** (`feat/toolbar-snap-buttons`): a new `[Area · Window]` group right after Record · timer (`rectangle.dashed` / `macwindow`, the same borderless on/off buttons as the tool picker). A click sends S / W's `.snap`; the active snap mode shows its on state, and a click on it steps back (`.stepBack` = Esc / Q / the same key again — "returns to where you were": restores the previous rect and the Setup mode or tool snapping started from, Pen after Pen, Pointer after Pointer; not always Pointer); the other one switches. Enabled in Setup and snap mode only — dimmed, never hidden, during the countdown and recording, so the capsule never changes width; Cancel stays enabled while snapping as before. Tooltips "Snap to a window's area (S)" / "Snap to a window (W)" (in snap mode the active one reads "Stop snapping and go back to the previous target"), the key shown only in Setup and snap mode. Tested against `RecordingSession` (enabled ⇔ the session acts) and with the real coordinator + chrome (`RecordingIntegrationTests.snapButtons`).
- **2026-10-23** — Review fix F7: the export-size readout (`ExportSizeText.bytes`) chooses KB / MB / GB and the one-decimal form on the **rounded** value, so 999 999 bytes read "1.0 MB" (was "1000 KB"), 99 999 999 "100 MB" (was "100.0 MB") and 999 999 999 "1.0 GB" (was "1000 MB"); the "≤" bound still never reads below its bytes. Boundary tests added.
- **2026-10-23** — Review fix F10: the Settings window is clamped into the visible frame **horizontally** as well (left edge kept if it fits, else slid back in; the left edge wins when wider), and the visible frame is the one of the screen the window overlaps most (also while closed), falling back to the main screen — a window left half off a display after a resolution change or display unplug now comes back fully on screen. PURE `SettingsPaneFit.placed` / `visibleFrame(for:screens:fallback:)`, tested.

## Manual checklist

Status after T7 (2026-10-09). ✅ = exercised by T7 on the real system (live harness on this
Mac driving the real coordinator and pieces, or the real-component integration tests);
👤 = needs Tefa (a physical pointer/keyboard, ⇧⌘4 — owned by the installed app, which T7 did
not quit — or a visual judgement). The E2E tester runs next.

- [ ] 👤 ⇧⌘4 → drag → **R**: the screenshot panel closes, and the same rect appears live with an amber border, dimmed outside, glass toolbar below
- [ ] 👤 "Record Area…" in the menu bar starts the same flow
- [ ] 👤 Setup: move, 8 handles, arrow nudge (⇧ = 10 pt), ⌥-arrow resizes the right/top edge (⇧⌥ = 10 pt), scroll resizes around centre, drag outside draws a new rect, size chip updates
- [ ] 👤 S: windows highlight on hover; click or Return/Enter confirms (S again steps back); the rect snaps to the window's frame; Esc restores the previous rect
- [ ] 👤 W: same, and the border follows the window when it's moved during recording — ✅ *follow verified with the real ink + chrome (integration test: a moved window frame moves the ink panel and the border ring); a real dragged window is 👤*
- [ ] 👤 W ↔ S switches the snap mode directly
- [x] ✅ Draw a box and an arrow in Setup, press R: countdown 3-2-1 (or the configured value / none), both annotations are in the video and never fade — *live: a Setup box drawn, R → 3 s countdown → the box is in the decoded video at its exact position (arrow and the countdown's look: 👤)*
- [ ] 👤 Esc during the countdown returns to Setup
- [ ] 👤 Recording: type into another app (including the letters R, S, P, Q): nothing in Snappy reacts — ✅ *live: after record start the user's app is frontmost and active, no Snappy window is key, the ink is click-through; physical typing 👤*
- [ ] 👤 ⌃⌥D: draw mode, pen/highlighter/arrow/oval/box all draw; 1–5 colours, [ ] widths, ⌘Z undo, ⌫ clear; ⌃⌥D again → typing reaches the app again — ✅ *live: draw mode makes the ink panel key **without** activating Snappy (the user's app keeps the menu bar), a `2` key event routed through AppKit switched the colour to yellow in the video, draw → interact hands focus back; the physical ⌃⌥D hot key and keyboard 👤*
- [ ] 👤 Fading ink (F): new strokes fade after the configured delay, in the video too
- [x] ✅ Border, toolbar, dimming and countdown are **not** in the video; cursor and click ripples are (per Settings) — *live: decoded frames show ink + cursor, no border/toolbar/dimming (click ripples need a real click: 👤)*
- [ ] 👤 Stop with ⇧⌘4, the toolbar ■, and the menu bar ●: each opens the preview panel — ✅ *`stop()` (the path all three use) opens the preview live*
- [ ] 👤 W mode: resize the window mid-recording, and the video letterboxes; close the window, and recording auto-stops; minimise it / switch Space / hide its app, and recording continues until you stop it (the menu bar ● keeps counting)
- [ ] 👤 Menu bar while recording: red ● + `0:00` ticking once per second in step with the toolbar timer, no jitter as digits change, `1:00:00` past an hour; VoiceOver reads "Recording, 0:42, click to stop"; a click stops; the "S" glyph and its menu return afterwards — ✅ *live: the item widens to show the time while recording (a second test instance landed under the notch on this crowded menu bar, so the look itself is 👤)*
- [ ] 👤 Draw-mode shortcut owned by another app (e.g. set ⌃⌥D elsewhere): a "Draw Mode Shortcut Unavailable" banner appears, the toolbar toggle's tooltip shows no shortcut, and the toggle still works — ✅ *integration tests with the real chrome; the banner itself 👤*
- [ ] 👤 Preview: autoplay, loop, muted, scrub, Space; ⌘S saves `Recording … .mp4` (second save in the same second → ` (2)`); ⇧⌘C then paste into Slack/Finder works; plain C / S do nothing
- [ ] 👤 R in the preview: back to Setup with the same rect/window and the setup annotations; recorded strokes gone — ✅ *integration test with the real ink: after Retake the setup stroke is drawn and the recorded one is not, same target*
- [ ] 👤 Esc closes the preview; menu bar "Reopen Last Recording" brings it back; after a new recording, the old take is gone
- [ ] 👤 Settings → Recording: every option changes behaviour on the next recording
- [ ] 👤 Light and dark mode: all chrome matches Tahoe Glass; tooltips read "<verb phrase> (KEY)"
- [ ] 👤 The rect can't cross onto a second display
- [x] ✅ 60 fps on a full-display rect with ink — *live: 3600 × 2338 px, 60 fps setting, a busy screen, ink drawn throughout: no dropped stretches, ~60–70 % of one core. After the review-round-1 `FrameClock` fix: no near-duplicate frames (57–59 fps average; the rest are slots in which the screen didn't change). The round-2 slot grid (never above the frame rate by construction) is not re-measured live yet: 👤 / E2E*


## Manual checklist — Magic Pen (2026-10-15, pending)

Needs Tefa (physical keyboard/pointer, the installed app, visual judgement). Automated: the
state machine, key map, ink model, renderer (screen ≡ video ≤ 2/255), menus, settings and the
real-pieces integration tests (`RecordingIntegrationTests` › Magic Pen).

- [ ] 👤 While recording in interact mode, **⌃⌥P** → the cursor becomes a crosshair over the area, your app keeps the menu bar; draw: the ink is red-orange, smooth, slightly see-through, with a faint dark edge; it stays for the fade delay (Settings, default 3 s), then fades out
- [ ] 👤 The same strokes are in the video, at the same place, looking the same, and fade the same way
- [ ] 👤 **⌃⌥P** again (or **Esc**) → typing reaches your app again; nothing Snappy-related reacts to letters
- [ ] 👤 From draw mode (⌃⌥D, pick Arrow) → ⌃⌥P → Magic Pen → ⌃⌥P → back to Arrow; V in Magic Pen → interact; ⌃⌥D in Magic Pen → normal pen
- [ ] 👤 In Magic Pen mode: **⌘Z / ⇧⌘Z** undo/redo, **⌫** clears, **[ / ]** change the thickness of the next stroke, F does nothing; no key ends up in your app
- [ ] 👤 Toolbar: the wand button lights while on (draw-mode toggle off, no tool selected), its tooltip reads "Draw fading ink (⌃⌥P)"; while on, the Width menu shows and sets the Magic Pen thickness
- [ ] 👤 Menu bar (not recording): "Magic Pen Thickness ▸" shows a checkmark on the current value; changing it changes Settings → Recording (also while Settings is open), and vice versa
- [ ] 👤 While recording in Magic Pen mode, change the thickness in an open Settings window: the next stroke uses it, and ] steps from it
- [ ] 👤 Menu bar while recording: a **plain click** on the red ● still **stops**; **right-click / ⌃-click / ⌥-click** opens Thin · Medium · Thick + Stop Recording; picking a thickness applies to the next stroke without leaving Magic Pen
- [ ] 👤 Settings → Recording: the Magic Pen recorder refuses ⌃⌥D ("… already Snappy’s Draw Mode shortcut") and accepts ⌘-only combos such as ⌘P (one rule for all four hot keys: at least one of ⌘/⌃/⌥ — 2026-10-20); the draw-mode recorder refuses ⌃⌥P; Reset works
- [ ] 👤 Set another app to own ⌃⌥P (or set the draw-mode shortcut to ⌃⌥P in an old build): a "Magic Pen Shortcut Unavailable" banner, the wand tooltip shows no shortcut, the button still works
- [ ] 👤 Retake after a Magic Pen take: no Magic Pen ink comes back (setup ink does)
- [ ] 👤 Light and dark content under the ink (white page, dark editor): the stroke is easy to see on both

## Manual checklist — v2 (V1: lines 1–3; V2: lines 4–6, 8, 10; V3: lines 7, 9, 11–12 — all implemented, pending)

- [ ] 👤 Stop a recording → a titled recording window opens frontmost; clicking another app leaves it open; it can be found again via Mission Control. With another app active: ⇧⌘4 / toolbar ■ / menu bar ● → the window is key (Space plays/pauses straight away); W-window auto-stop (close the recorded window) → front but not key until clicked (Q44, by design)
- [ ] 👤 ⌘S saves and keeps the window; ⇧⌘C copies and closes; R retakes; Q / Esc / ⌘W / traffic light close without a prompt
- [ ] 👤 Two recordings in a row: both windows open and both play; closing the older deletes its take; Reopen Last Recording fronts the newest window
- [ ] 👤 Snap mode: S, S and W, W step back; click and Return confirm; S ↔ W switches
- [ ] 👤 First S/W entry without Accessibility → macOS prompt once; denied → whole windows still work; Settings row shows the status
- [ ] 👤 Chrome / Safari / VS Code: edge or title bar = whole window, inside = page area / tab strip + page / pane; highlight glides; chip names the part; ↑/↓ widen/narrow
- [ ] 👤 W + page area: resize the window mid-recording → the video follows the page, letterboxed; close the tab → last rect kept
- [ ] 👤 S + part: a dropdown opening over the page is in the video
- [ ] 👤 Retake after a part recording restores the same part
- [ ] 👤 After the session the Chromium/Electron app's accessibility switch is back to its old value
- [ ] 👤 W + part: the red border and the toolbar sit on the part and follow it (move the window; open a browser sidebar so the page area shifts); ink drawn on the page stays on the page when the window moves, and ink outside the part is hidden (not lost — it comes back if the part grows over it) — ✅ *live harness: crop changes, letterbox, window move, part gone and window resize decoded from the video; the follow of real chrome by a real app's part is 👤*
- [ ] 👤 W + part: minimise the window / switch Space mid-recording → recording continues (holds the last frame) and resumes on the part when the window comes back

## Manual checklist — Area / Window toolbar buttons (2026-10-20, pending)

- [ ] 👤 Setup: the toolbar reads `● 00:00 | Area · Window | Pointer …`; both buttons hover-highlight like the tool buttons; light and dark mode match the rest of the capsule
- [ ] 👤 Click Area / Window: snap mode starts exactly as with S / W (windows highlight on hover); the button shows the on state; clicking the other one switches
- [ ] 👤 Click the active button: back to Setup with the previous rect (= Esc); click a window or Return still confirms
- [ ] 👤 Tooltips: "Snap to a window's area (S)" / "Snap to a window (W)" in Setup; the active one reads "Stop snapping and go back to the previous target (…)"
- [ ] 👤 Countdown and recording: both buttons dimmed, not clickable, no key in the tooltip; the toolbar keeps its width from Setup to recording

## Manual checklist — Export size (2026-10-20, pending)

- [ ] 👤 The capsule reads `W × H · m:ss · [slider] 100 % · 18.4 MB`; light and dark mode look like the rest of the window's glass; the slider snaps to 4 stops and is easy to hit
- [ ] 👤 Drag the slider / press `[` and `]`: W × H halves etc. (even numbers), the size switches to "≤ X MB"; `[` at 25 % and `]` at 100 % do nothing; tooltips read "Change export size ([ ])", "Smaller export ([)", "Larger export (])"
- [ ] 👤 At 100 %: ⌘S saves at once (no ring) and the file is byte-identical to before this feature; ⇧⌘C pastes the full-size file
- [ ] 👤 At 50 %: ⌘S shows a progress ring on Save, then a `Recording … .mp4` at half size appears in the Save folder (QuickTime: half resolution, no audio, plays smoothly); the capsule now shows its real size
- [ ] 👤 After that Save, ⇧⌘C at 50 % pastes the saved file (no second encode); move to 75 % and ⇧⌘C → re-encodes, pastes a 75 % file into Finder / Slack, window closes
- [ ] 👤 During a long re-encode: playback, scrubbing and the slider still work; another ⌘S/⇧⌘C beeps; Esc (and Q, ⌘W) cancels the re-encode only — window stays, nothing saved; the button gets its icon back
- [ ] 👤 Settings → Recording › Default export size = 50 %: the next recording window opens at 50 %; moving its slider doesn't change the Settings value
- [ ] 👤 VoiceOver: the slider reads "Export size, 50 %"; the busy button reads "Exporting NN %"
