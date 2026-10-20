# Global Shortcut & Preview Panel

## What it is

Milestone M2's core (priority P2): **⇧⌘4** from anywhere triggers area capture, then a small borderless floating panel appears near the captured area with an image preview and the actions **Edit · Copy · Save · OCR · Pin** (in that order).

- **Hot keys:** Carbon `RegisterEventHotKey` wrapped in `HotKeyCenter` — **⇧⌘4** → area capture, **⇧⌘3** → fullscreen capture; both combos stored in `UserDefaults` under separate keys and **remappable in Settings** since 2026-10-20 ([shortcuts-ux.md](shortcuts-ux.md) › Remappable global hot keys). They deliberately override the system's own ⇧⌘4 / ⇧⌘3, which must be disabled in *System Settings → Keyboard → Keyboard Shortcuts → Screenshots*. One center owns both bindings and routes them by `EventHotKeyID` (see `docs/ARCHITECTURE.md` — a second center would send both hot keys to whichever registered last)
- **Panel:** non-activating borderless `NSPanel` (`.nonactivatingPanel`, level `.floating`) — takes key status without stealing the frontmost app's focus. Content sits in a Liquid Glass `NSGlassEffectView` (macOS 26, `cornerRadius = 10`). Placement clamped to screen edges (pure `PanelGeometry`). Esc/Q/click-away dismiss; every action auto-dismisses the panel
- **Actions:** borderless toolbar-style icon buttons (SF Symbols, 32×28 pt, 8 pt apart) with verb-phrase tooltips ending in the key, e.g. "Save PNG to Desktop (S)"; single keys **E/C/S/O/P** trigger them. Copy writes PNG+TIFF to the pasteboard; Save writes `Shot yyyy-MM-dd 'at' HH.mm.ss.png` (pure `ScreenshotNamer`) to the configured folder (default `~/Desktop`, changeable in Settings); Edit opens the [editor](editor.md); OCR and Pin have their own feature docs

See `docs/ARCHITECTURE.md` for the panel invariants (dual click-away monitors, non-activating key status, anchor-rect travel).

## Log

- **2026-07-17** — Decision: nothing happens automatically post-capture; the panel decides. Default shortcut ⇧⌘4, overriding the system binding
- **2026-07-18** — M2 implemented; automated gate green. Signing/TCC fixed (see [app-shell](app-shell.md)); basic area-capture→panel flow confirmed working. First Save to ~/Desktop may trigger a "Files and Folders" TCC prompt
- **2026-07-18** — UX round: all actions became icon buttons with "Action (KEY)" tooltips; single-key shortcuts E/C/S/O/P; Q dismisses like Esc
- **2026-07-19** — Manual checklist verified by Tefa (implies the system's ⇧⌘4 is now disabled on this machine — required for the hot key to fire)
- **2026-07-19** — macOS 26 retarget: the panel's `NSVisualEffectView` (.popover material + layer corner radius) replaced by Liquid Glass `NSGlassEffectView` (`cornerRadius = 10`, stack as `contentView` with explicit edge constraints — glass does not auto-size to its content). Purely visual; monitors/dismissal untouched
- **2026-08-25** — Second global hot key **⇧⌘3 → fullscreen capture** (`SettingsStore.fullscreenHotKey`). `HotKeyCenter` rewritten to own every binding: its handler previously ignored the `EventHotKeyID`, and since `InstallEventHandler` targets the process-wide dispatcher, a second center would have routed *both* hot keys to whichever registered last. Fullscreen still never activates, so the frontmost app keeps focus — see [capture.md](capture.md) for the frozen-capture work this was part of
- **2026-10-08** — Review pass: Copy and Save pass the capture scale (PNG/TIFF DPI = 72 × scale); Save is non-overwriting (temp file + exclusive `link(2)`, ` (2)`/` (3)` suffix on a same-second collision; any non-`EEXIST` link failure, e.g. FAT/exFAT/SMB, falls back to `FileManager.moveItem`, which also refuses to overwrite) and creates the destination folder if it was deleted; `HotKeyCenter.register` no longer leaks a Carbon hot key when called twice for an action and unregisters everything in an `isolated deinit`; the Settings shortcut hint now mentions ⇧⌘3 as well as ⇧⌘4.

- **2026-10-08** — HIG design pass (apple-design skill review): buttons went from small `.rounded` push buttons (31–33 × 20 pt, 2 pt apart — at the HIG minimum) to borderless `.toolbar` buttons pinned to 32 × 28 pt with 8 pt spacing, so no bezel boxes sit on the glass; Edit icon `pencil` → `pencil.tip.crop.circle` (in Apple's standard icons `pencil` means Rename), Copy `doc.on.doc` → `document.on.document` (also in pin + editor toolbars); tooltips lead with what the action does and keep the "(KEY)" suffix, Save naming the destination folder (`PreviewAction.toolTip(saveFolderName:)`, unit-tested)

- **2026-10-08** — Tahoe Glass: concentric corners — glass radius 10 → 18 pt, preview image rounded to 8 pt (18 − 10 pt inset, continuous curve). Light/dark come from the glass itself

- **2026-10-09** — Recording T0: a sixth action **Record** (`record.circle`, "Record this area (R)", key **R**) after Pin, handing the captured area to recording Setup ([recording.md](recording.md)); the five screenshot actions are unchanged. ⇧⌘4 is now context-sensitive (`CaptureHotKeyRoute`): it stops a recording and is ignored during the rest of a recording session

- **2026-10-09** — Fix: the 10 pt horizontal inset was missing (a vertical `NSStackView` with `.centerX` alignment drops its left/right `edgeInsets`), so the preview touched the glass's left and right edges and the concentric corners didn't hold there. The inset now comes from a container around the stack, like the recording preview panel. Measured headlessly: panel 320 → 340 pt wide for a 320 pt preview, image at x = 10 (was 0)

## Manual checklist — Tahoe Glass (2026-10-08, unverified)

- [ ] Panel corners look rounder (18 pt) and the preview's 8 pt corners run parallel to them, in light and dark mode

## Manual checklist — HIG design pass (2026-10-08, visuals verified by Tefa)

- [x] Buttons show no border at rest, highlight on hover, and are comfortable to click
- [x] Panel looks right over light and dark desktops, in light and dark mode
- [ ] Tooltips read e.g. "Annotate in the editor (E)"; Save names the configured folder
- [ ] E/C/S/O/P, Esc, Q and click-away still behave as before

## Manual checklist — ✅ verified (Tefa, 2026-07-19)

- [x] ⇧⌘4 triggers area capture while another app is frontmost, without stealing its focus
- [x] Panel appears near the selection with preview + Edit/Copy/Save/OCR/Pin in that order
- [x] Buttons are icons with tooltips "Action (KEY)"; E/C/S/O/P trigger the matching actions
- [x] Q dismisses the panel and closes pins, same as Esc
- [x] Copy: paste works in Preview and in a rich-text editor
- [x] Save: PNG lands in the configured folder with the timestamped name
- [x] Esc and click-away dismiss the panel; actions auto-dismiss it (except Pin)
- [x] Pin items — see [pin.md](pin.md)

- **2026-10-20** — Both capture hot keys are remappable in Settings (click-to-record field + Reset each, applied at once, no restart) — see [shortcuts-ux.md](shortcuts-ux.md); the menu items show the configured combos

## Manual checklist — ⇧⌘3 (2026-08-25, unverified)

- [ ] ⇧⌘3 captures the display under the mouse and opens the panel, without stealing the frontmost app's focus
- [ ] ⇧⌘4 and ⇧⌘3 never trigger each other's action
