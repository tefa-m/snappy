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
| Global | **⇧⌘4** | Area capture (requires the system's ⇧⌘4 to be disabled); during a recording session: stops a recording, ignored otherwise (`CaptureHotKeyRoute`) |
| Global | **⇧⌘3** | Fullscreen capture (requires the system's ⇧⌘3 to be disabled) |
| Preview panel | **R** | Record this area (opens recording Setup with the same rect) |
| Recording Setup | **R** · **S / W** · **V P H A O B** · **F** · **⌫** · **1–5** · **[ ]** · **⌘Z / ⇧⌘Z** · **Esc / Q** | Record · snap to window area / window · Pointer, Pen, Highlighter, Arrow, Oval, Box · fading ink · clear · colour · width · undo/redo · step back (tool → Pointer → cancel) |
| Recording Setup (Pointer, area target) | **arrows** (⇧ = 10 pt) · **⌥-arrows** (⇧⌥ = 10 pt) · **scroll** | Nudge the rect 1 pt · resize from the keyboard: **→ ←** right edge, **↑ ↓** top edge · resize around the centre (aspect kept). Not on a W target, which is locked (`SetupGeometry.arrowEdit`) |
| Recording snap mode | **S / W** · **Return / keypad Enter** (or click) · **↑ / ↓** (or scroll) · **Esc / Q** | The same key again goes back to the previous rect (= Esc), the other key switches mode · confirm the hovered window or part · widen / narrow the window part one level (moving the pointer goes back to the automatic pick) · back to the previous rect |
| Recording countdown | **Esc / Q** | Back to Setup |
| Recording, draw mode | tool, style and content keys as in Setup (no R/S/W) · **V / Esc / Q** | Draw · back to interact mode |
| Recording, Magic Pen mode | as draw mode, but **[ / ]** = Magic Pen thickness and **F** does nothing · **⌃⌥P / Esc / Q** · **V** · **⌃⌥D** | Draw fading Magic Pen ink · back to where you came from (interact or the draw tool) · interact · normal draw mode |
| Recording, interact mode | — | **Every** key belongs to the recorded app; no letter ever reaches Snappy (Q15) |
| Recording | **⇧⌘4** · **⌃⌥D** (session-only, configurable in Settings; must include ⌃ or ⌥) · **⌃⌥P** (session-only, configurable, same rules, never equal to ⌃⌥D) · click the menu bar **● 0:42** · **right-/⌃-/⌥-click** it | Stop · toggle draw/interact (if another app owns the combo, a banner says so and the toolbar toggle remains) · toggle the Magic Pen (likewise: banner, the wand button remains) · stop · Magic Pen thickness menu + Stop |
| Recording window | **Space** · **R** · **⌘S** · **⇧⌘C** (plain ⌘C works too) · **Esc / Q / ⌘W** | Play/pause · Retake (closes) · Save (stays open) · Copy and close · Close without a prompt (plain C/S do nothing) |
| Settings → Draw mode / Magic Pen recorders | click or **Space** · combo · **Esc** · **Tab** | Start recording a shortcut · set it (⌃ or ⌥ required, letters/digits only; each refuses the other's combo) · cancel · move on |

Note: the app has no main menu (`LSUIElement`), so ⌘-shortcuts are handled in the canvas's `performKeyEquivalent` — see `docs/ARCHITECTURE.md`.

## Caps Lock is ignored everywhere

Single-letter shortcuts check their modifiers via `ShortcutKeys.isBareKey` (`Sources/Snappy/App/ShortcutKeys.swift`), which strips `.shift` **and** `.capsLock` from the device-independent mask. Caps Lock is a latched state that sits in `NSEvent.modifierFlags` while enabled — treating it as a held modifier silently killed every single-letter shortcut. Character comparisons are always `.lowercased()`, so shortcuts behave identically with Caps Lock on or off. Any future "no modifiers held" check must use this helper, never inline flag math.

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
