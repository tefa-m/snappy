# Shortcuts-First UX (Standing Rule)

## The rule (Tefa, 2026-07-18)

Every action and tool — in every current **and future** feature — ships with a convenient keyboard shortcut, advertised in its icon's tooltip as **"<verb phrase> (SHORTCUT)"** with uppercase letters — e.g. "Copy image to clipboard (C)" (HIG *Offering help*: say what the control does, don't repeat its name; app-wide since the 2026-10-08 design pass). New features must follow this pattern and update the table below.

**Q or Esc closes/dismisses any transient window** (editor, preview panel, pins, capture overlays, recording windows). In the editor, Esc deselects first, then closes when nothing is selected.

## Established bindings

| Context | Binding | Action |
| ------- | ------- | ------ |
| Preview panel | **E / C / S / O / P** | Edit / Copy / Save / OCR / Pin |
| Editor tools | **V / R / O / A / L / P / T / N / B / X / C** | Select / Rectangle / Oval / Arrow / Line / Pen / Text / Counter / Blur / Pixelate / Crop |
| Editor | **⇧⌘C** (plain ⌘C works too) | Copy + close the editor ("done" action) |
| Editor | **⌘S** | Save |
| Editor | **⌘P** | Pin the annotated image + close the editor |
| Editor | **⌘Z / ⇧⌘Z** | Undo / Redo |
| Pin (must be key — click it first) | **E / C** | Edit (closes the pin, opens the editor) / Copy (pin stays open) |
| Everywhere transient | **Q / Esc** | Close / dismiss (editor, panel, pins) |
| Area-selection & window-pick overlays | **Q / Esc** | Cancel the capture (`OverlayKeys`) |
| Settings window | **⌘W** · **⌘X / ⌘C / ⌘V / ⌘A** | Close · Cut / Copy / Paste / Select All in its text field (`SettingsKeyCommand` — no main menu supplies them) |
| Global | **⇧⌘4** (remappable) | Area capture (requires the system's ⇧⌘4 to be disabled); during a recording session: stops a recording, ignored otherwise (`CaptureHotKeyRoute`) |
| Global | **⇧⌘3** (remappable) | Fullscreen capture (requires the system's ⇧⌘3 to be disabled) |
| Preview panel | **R** | Record this area (opens recording Setup with the same rect) |
| Recording Setup | **R** · **S / W** · **V P H A O B** · **F** · **⌫** · **1–5** · **[ ]** · **⌘Z / ⇧⌘Z** · **Esc / Q** | Record · snap to window area / window · Pointer, Pen, Highlighter, Arrow, Oval, Box · fading ink · clear · colour · width · undo/redo · step back (tool → Pointer → cancel) |
| Recording Setup (Pointer, area target) | **arrows** (⇧ = 10 pt) · **⌥-arrows** (⇧⌥ = 10 pt) · **scroll** | Nudge the rect 1 pt · resize from the keyboard: **→ ←** right edge, **↑ ↓** top edge · resize around the centre (aspect kept). Not on a W target, which is locked (`SetupGeometry.arrowEdit`) |
| Recording snap mode | **S / W** · **Return / keypad Enter** (or click) · **↑ / ↓** (or scroll) · **Esc / Q** | The same key again goes back to the previous rect (= Esc), the other key switches mode · confirm the hovered window or part · widen / narrow the window part one level (moving the pointer goes back to the automatic pick) · back to the previous rect |
| Recording countdown | **Esc / Q** | Back to Setup |
| Recording, draw mode | tool, style and content keys as in Setup (no R/S/W) · **V / Esc / Q** | Draw · back to interact mode |
| Recording, Magic Pen mode | as draw mode, but **[ / ]** = Magic Pen thickness and **F** does nothing · **⌃⌥P / Esc / Q** · **V** · **⌃⌥D** | Draw fading Magic Pen ink · back to where you came from (interact or the draw tool) · interact · normal draw mode |
| Recording, interact mode | — | **Every** key belongs to the recorded app; no letter ever reaches Snappy (Q15) |
| Recording | **⇧⌘4** · **⌃⌥D** (session-only, configurable in Settings; needs ⌘, ⌃ or ⌥) · **⌃⌥P** (session-only, configurable, same rules, never equal to ⌃⌥D) · click the menu bar **● 0:42** · **right-/⌃-/⌥-click** it | Stop · toggle draw/interact (if another app owns the combo, a banner says so and the toolbar toggle remains) · toggle the Magic Pen (likewise: banner, the wand button remains) · stop · Magic Pen thickness menu + Stop |
| Recording window | **Space** · **R** · **⌘S** · **⇧⌘C** (plain ⌘C works too) · **Esc / Q / ⌘W** | Play/pause · Retake (closes) · Save (stays open) · Copy and close · Close without a prompt (plain C/S do nothing) |
| Settings → Draw mode / Magic Pen recorders | click or **Space** · combo · **Esc** · **Tab** | Start recording a shortcut · set it (⌘, ⌃ or ⌥ required, letters/digits only; each refuses the other's combo) · cancel · move on |

Note: the app has no main menu (`LSUIElement`), so ⌘-shortcuts are handled in the canvas's `performKeyEquivalent` — see `docs/ARCHITECTURE.md`.

## Caps Lock is ignored everywhere

Single-letter shortcuts check their modifiers via `ShortcutKeys.isBareKey` (`Sources/Snappy/App/ShortcutKeys.swift`), which strips `.shift` **and** `.capsLock` from the device-independent mask. Caps Lock is a latched state that sits in `NSEvent.modifierFlags` while enabled — treating it as a held modifier silently killed every single-letter shortcut. Character comparisons are always `.lowercased()`, so shortcuts behave identically with Caps Lock on or off. Any future "no modifiers held" check must use this helper, never inline flag math.

## Remappable global hot keys (2026-10-20)

Only Snappy's **four global hot keys** can be remapped — **Capture Area (⇧⌘4)**, **Capture Entire Screen (⇧⌘3)**, **Draw Mode (⌃⌥D)** and **Magic Pen (⌃⌥P)**. Every in-session single-letter key stays fixed (Tefa's decision).

- **UI:** Settings → *Capture area* / *Capture screen* rows (under the folder row) and *Draw mode* / *Magic Pen* rows in the Recording section: a click-to-record field (click or Space, press the combo; Esc cancels, Tab leaves) + **Reset** (restores the default; disabled at the default unless that default isn't working — then it retries). No unbinding. The "turn off the macOS screenshot shortcuts" hint and *Open Keyboard Settings* stay; a refusal replaces the hint under the field and is announced to VoiceOver.
- **Validation** (PURE, tested — `HotKeyRecorderInput`, `HotKeyBindings`): letters/digits only; **every hot key needs at least one of ⌘/⌃/⌥** (Creator decision 2026-10-20 — one rule for all four, so ⌘D / ⌘P are fine for Draw Mode / Magic Pen; the 2026-10-09 ⌃/⌥-only rule for the session keys is gone); a combo another Snappy hot key holds is refused by name ("⇧⌘4 is already Snappy’s Capture Area shortcut."), Reset too when another key holds the default.
- **Applies at once, no restart** (`GlobalHotKeys`): the combo is bound first and saved only if it took. If `RegisterEventHotKey` refuses it (macOS or another app owns it) the old shortcut stays bound and saved, and the field says exactly **"That shortcut is already taken"** (approved copy). The new combo is acquired before the old one is released, and a recorder's accepted combo is bound before the paused hot keys resume — so a failure never costs the old binding. Session keys outside a session are checked with an availability probe; during a session they are rebound live.
- **A combo taken while it wasn't held** (refused at launch, or grabbed by another app while a recorder had the hot keys paused) is never forgotten: the stored combo stays, Settings says "That shortcut is already taken — Capture Area is off until it’s free or you choose another.", and Snappy retries when Settings opens, when the app becomes active, and when you record the same combo (or press Reset on the default) again.
- **Labels follow the keyboard layout:** the stored key code is the physical key (what Carbon binds); its label is the current layout's (`KeyLegend` — on AZERTY the key labelled A reads "A", not "Q"), refreshed when the input source changes. Non-Latin layouts and keys without an ASCII letter/digit use the US names.
- **Everywhere reads the live combo:** status menu key equivalents (refreshed when the menu opens), the recording ● menu's Stop and the ●'s tooltip (set when recording starts, updated on a mid-session change), the recording toolbar's Stop tooltip (Capture Area combo — it stops a recording), Draw Mode / Magic Pen tooltips, the Settings fields. ⇧⌘4 → Stop follows the configured Capture Area combo. **Only a live combo is advertised:** while the Capture Area combo is registered but refused (at launch, or lost on a resume), the toolbar's Stop, the ●'s tooltip and the ● menu's Stop show no shortcut (`GlobalHotKeys.liveStopCombo`), and they pick it up again when a retry binds it (`onStatusChange`).
- While a recorder waits for a key, the hot keys are suspended so pressing a Snappy hot key reaches the recorder (and is refused) instead of firing. Closing Settings with the red close button, clicking into another app (Settings resigns key) or switching apps ends the recording and resumes them. **⌘W while a recorder is recording is captured as the new shortcut** (it is valid under the one rule — Creator decision 2026-10-20), not a close. Once the field has stopped recording, a ⌘W binding on Capture Area / Capture Screen is swallowed by Carbon like any other hot key (it triggers the capture, not a close), so close Settings with the red close button — or change the binding.

### Manual checklist — remappable hot keys (2026-10-20, pending)

- [ ] 👤 Settings shows four shortcut fields (Capture area, Capture screen, Draw mode, Magic Pen), each with Reset; the screenshot-shortcut hint and Open Keyboard Settings are still there
- [ ] 👤 Record ⌥⌘5 for Capture area: it captures at once (no restart), ⇧⌘4 no longer does; the menu shows ⌥⌘5 next to Capture Area…
- [ ] 👤 While recording a field, pressing ⇧⌘3 does **not** take a screenshot; the field says it is already Snappy's Capture Entire Screen shortcut
- [ ] 👤 Esc while recording keeps the old shortcut; ⇧5 alone is refused ("Include ⌘, ⌃ or ⌥…"); ⌘P for Magic Pen and ⌘D for Draw Mode are accepted
- [ ] 👤 A combo another app already holds as a global hot key (e.g. one bound in a second running app's settings) shows "That shortcut is already taken" and the old shortcut keeps working
- [ ] 👤 Click a field (Type Shortcut), then close Settings with the red button: ⇧⌘4 captures again at once; likewise after ⌘Tab away mid-recording
- [ ] 👤 Switch to a French (AZERTY) or German layout: the fields, menu and tooltips re-label (AZERTY ⇧⌘4 still reads ⇧⌘4; a combo on the key labelled A reads "A")
- [ ] 👤 With ⇧⌘4 still on in macOS, launch Snappy: Settings says Capture Area is taken; turn the macOS one off, reopen Settings → the line goes away and ⇧⌘4 works without a relaunch
- [ ] 👤 Reset restores ⇧⌘4 / ⇧⌘3 / ⌃⌥D / ⌃⌥P; Reset is refused (with the reason) when another key holds that default
- [ ] 👤 During a recording: change Draw Mode in Settings → the new combo toggles draw mode immediately, the toolbar tooltip names it; change Capture area → the new combo stops the recording and Stop's tooltip and the ● right-click menu name it
- [ ] 👤 Quit and relaunch: all four custom shortcuts persist and work

## History

- **2026-07-18** — Standing rule established; bindings table created.
- **2026-07-19** — Bug fix (Post-MVP M-A): Caps Lock no longer disables single-letter shortcuts (editor tools + Q, panel E/C/S/O/P). New `ShortcutKeys.isBareKey` helper, unit-tested; both former inline guards replaced.
- **2026-07-19** — Post-MVP M-C: pins gained E (edit) / C (copy), advertised in the hover-toolbar tooltips; bare-key checks via `ShortcutKeys.isBareKey`.
- **2026-08-25** — **⇧⌘3 → fullscreen capture**, closing the last gap in the standing rule (fullscreen and window capture were menu-only). It also makes fullscreen useful for transient UI: reaching it through the menu bar dismisses whatever menu or tooltip you wanted to capture. Window capture is still menu-only — it needs a hover-pick pass anyway, so a shortcut buys it nothing. Both global combos deliberately shadow the system screenshot shortcuts, which must be disabled in System Settings → Keyboard → Keyboard Shortcuts → Screenshots. `HotKeyCenter` now owns every binding and routes on `EventHotKeyID` — see `docs/ARCHITECTURE.md` for why a second center would silently break both.
- **2026-10-08** — HIG design pass (parallel reviews, `docs/design-reviews/`): tooltips switched to the verb-phrase form app-wide; **Q now cancels both capture overlays** (applying the standing rule — Esc already did); the Settings window handles **⌘W** and **⌘X/C/V/A** itself (LSUIElement app, no Edit menu). No existing binding changed.
- **2026-10-09** — Recording T0: preview-panel **R**, context-sensitive **⇧⌘4** and the session-only **⌃⌥D** (`HotKeyAction.toggleDrawMode = 3`, registered on session start, unregistered at its end) are wired; every recording key goes through the pure `RecordingKeyMap`. Setup/draw rows stay *planned* until their UI lands.
- **2026-10-09** — Recording bindings designed (marked *planned* above, see `features/recording.md`). Deliberate divergence: **B = Box** in the recording view while the snapshot editor keeps R = Rectangle, because R means Record there. No letter ever stops a recording (⇧⌘4 does), so typing in the recorded app is always safe.
- **2026-10-09** — Recording T7 (integration): every recording row is live (no longer *planned*). Added Setup **⌥-arrow** resize (→ ← right edge, ↑ ↓ top edge, 1 pt / ⇧⌥ 10 pt — Leader decision, shortcuts-first rule), arrow nudge and scroll resize, snap-mode and countdown rows, draw-mode **V/Esc/Q** back to interact, the recording preview's **⌘C** alias and **⌘W** close, and the Settings draw-mode recorder (must include ⌃ or ⌥ — Leader decision, a ⌘ combo would be swallowed system-wide for the session).
- **2026-10-09** — Recording T7 review round 1: while recording, the menu bar item is a red **● + elapsed time** (Tefa); clicking it stops, like ⇧⌘4 and the toolbar ■. A draw-mode combo another app already owns is reported with a banner and is no longer advertised in the toolbar tooltip.
- **2026-10-11** — Recording v2 V1: the recording preview panel became the persistent **recording window**. Same keys (Space · R · ⌘S · ⇧⌘C/⌘C · Esc/Q/⌘W); what changed is what stays: **⌘S keeps the window open**, Copy closes it (the editor's "done" action, tooltip "Copy video file and close (⇧⌘C)"), R closes it when Setup starts. The traffic light closes too, never with a prompt.
- **2026-10-15** — **Magic Pen** (leader decisions, Tefa to confirm — `features/recording.md` › Magic Pen): session-only **⌃⌥P** (`HotKeyAction.toggleMagicPen = 4`, configurable, ⌃ or ⌥ required, refused when equal to the draw-mode combo) toggles it from interact or draw mode; **⌃⌥P / Esc / Q** go back where you came from, **V** → interact, **⌃⌥D** → normal draw mode; **[ / ]** step the Magic Pen thickness there and **F** is off. Toolbar wand button "Draw fading ink (⌃⌥P)". Menu bar: a plain click on the recording ● still stops; right-/⌃-/⌥-click opens the thickness menu + Stop. No plain character turns it on or off.
- **2026-10-11** — Recording v2 (task V2): in S/W snap mode the **same key again steps back** (it used to confirm), **Return / keypad Enter** confirm like a click, and **↑ / ↓** (or scrolling) widen / narrow the window part under the pointer. VoiceOver help of the Setup overlay switches to the snap-mode wording.
- **2026-10-20** — **Remappable global hot keys** (Tefa-approved design, see the section above): the four global hot keys are click-to-record fields in Settings, applied live via `GlobalHotKeys` (bind first, save only on success, old combo kept on refusal), the center suspended while a recorder waits; menu, Stop tooltip and the ● menu read the live combos. Single-letter keys stay fixed.
- **2026-10-20** — Remap review fix round 1: closing/deactivating Settings mid-record resumes the hot keys; `replace` holds the new combo before releasing the old, a recorder binds before resuming, a refused or lost registration is kept and retried (also by re-recording the stored combo) with an inline "taken" line; **one ⌘/⌃/⌥ rule for all four** (Creator decision — ⌘D/⌘P allowed); refusal copy exactly "That shortcut is already taken" (Creator decision); the ● tooltip follows the Capture Area combo; labels follow the keyboard layout (`KeyLegend`).
