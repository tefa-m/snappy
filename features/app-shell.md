# App Shell — Menu Bar App, Build & Signing

## What it is

The application skeleton (originally milestone M0): a menu-bar-only AppKit app with no Dock icon (`LSUIElement`), built entirely with SPM + scripts — **no Xcode required**, only Command Line Tools.

- Menu bar menu: **Capture Area… · Capture Window… · Capture Entire Screen · Settings… · Quit Snappy** (built from the pure `StatusMenuCommand`; SF Symbols on the capture group + Settings)
- Settings window ("Snappy Settings", single pane): save folder as an editable pop-up path control, the two global shortcuts + *Open Keyboard Settings*, the editor's tool-icon checkbox, canvas padding (stepper + number field). Handles ⌘W and ⌘X/C/V/A itself — there is no main menu to route them. Button, checkbox and stepper use `.large` (≥ 28 pt leader decision); the number field and path control have no large variant
- Alerts and banners: every string comes from the pure `UserFacingText` — never `String(describing: error)`
- `scripts/bundle.sh`: `swift build -c release` → assemble `dist/Snappy.app/Contents/{MacOS,Resources}` → write `Info.plist` (`LSUIElement = true`, `NSScreenCaptureUsageDescription`, bundle id `com.tefa.snappy`, `LSMinimumSystemVersion = 26.0`) → codesign
- `scripts/setup-signing.sh` (once per machine): creates the stable self-signed **"Snappy Dev"** identity so TCC grants survive rebuilds; `bundle.sh` prefers it over ad-hoc
- `scripts/test.sh`: wraps `swift test` with the `-F`/`-rpath` flags `Testing.framework` needs on a CLT-only machine (plain `swift test` fails)
- `scripts/verify-bundle.sh`: smoke-checks bundle structure, `Info.plist` keys, and `codesign --verify`

Key APIs: `NSApplication`, `NSStatusBar.system.statusItem`, `NSApp.setActivationPolicy(.accessory)`.

## Deployment

Primary path is building on the target machine: Command Line Tools + `git clone` + `./scripts/setup-signing.sh` (once) + `./scripts/bundle.sh` — avoids Gatekeeper quarantine. Copying a built `.app` between machines works but may need `xattr -d com.apple.quarantine`.

## Verification gate (every change, all features)

1. `swift build` succeeds with no new warnings
2. `./scripts/test.sh` fully green
3. `./scripts/bundle.sh` produces a signed `.app`; `./scripts/verify-bundle.sh` passes
4. The affected feature's manual checklist (in its feature doc) is walked through in the built app
5. No third-party dependency and no network API introduced

Testing strategy: **Swift Testing** only (XCTest doesn't exist under CLT). UI-heavy behavior can't be unit-tested without Xcode, so all geometry/model/text logic is extracted into pure, UI-free types covered by `swift test`; the UI itself is covered by the manual checklists.

## Log

- **2026-07-17** — M0 done. CLT quirk discovered: `Testing.framework` ships outside the default search paths → `scripts/test.sh` created
- **2026-07-18** — App named **Snappy** (module `Snappy`, bundle id `com.tefa.snappy`, `dist/Snappy.app`); repo folder is `snappy`
- **2026-07-19** — macOS 26 retarget: swift-tools-version 6.0 → 6.2 (minimum that offers `.macOS(.v26)`), `platforms: [.macOS(.v26)]`, `LSMinimumSystemVersion = 26.0` in bundle.sh + verify-bundle.sh. Zero `#available` gates existed, so no code cleanup was needed
- **2026-07-18** — Ad-hoc signing broke Screen Recording after a rebuild (TCC pins ad-hoc grants to the binary's cdhash; the System Settings toggle looks ON but capture is denied). Fix: `setup-signing.sh` + "Snappy Dev" identity; done on this machine, capture re-verified. Script gotcha: must use `/usr/bin/openssl` (LibreSSL) and import PEM directly — Homebrew OpenSSL 3's PKCS#12 output is rejected by `security import`
- **2026-10-08** — Review pass: `install.sh` stages the new bundle as `Snappy.app.new` next to the destination, verifies it, and only then swaps it in — a failed `ditto` (disk full, cancelled sudo) no longer leaves the machine without an app. `generate-icons.swift`'s alpha-mask context now owns its backing store (output byte-identical to the committed menu bar PNGs); the pixel-sampling test helper keeps its context inside the buffer borrow. Swift tests: 204.
- **2026-10-08** — HIG design pass (shell review, `docs/design-reviews/shell.md`): menu labels get ellipses where a selection follows (Capture Area…, Capture Window…), "Capture Fullscreen" → "Capture Entire Screen" (Apple's own term), SF Symbols on the capture group + Settings — all from the pure `StatusMenuCommand`. Settings: the small stepper (17 × 22 pt, below the 20 pt minimum) → regular stepper + number field (`CanvasPaddingInput`); raw path label → editable pop-up `NSPathControl`; shortcut hint split into bindings read from `SettingsStore` (`HotKeyCombo.displayString`) + an *Open Keyboard Settings* button; clearer labels and help text; ⌘W/⌘X/C/V/A handled by the window (`SettingsKeyCommand`); centred once. Alerts and banners route through the pure `UserFacingText`. Key bindings unchanged. Swift tests: 223.
- **2026-10-09** — Recording T0: the status menu gained a recording group — **Record Area…** (`record.circle`) and **Reopen Last Recording** (`play.rectangle`, disabled via `validateMenuItem` while there is no take or a session runs) — between the captures and Settings ([recording.md](recording.md))
- **2026-10-08** — Reviewer follow-up (Sol review, response in `docs/design-reviews/shell.md`): padding input clamps before `Int` conversion (`1e100` used to trap); the path control accepts folders only (`allowedTypes` + `SaveFolderValidation` — a dropped PNG used to become the save folder); `.large` button/checkbox/stepper. Swift tests: 226.

## Manual checklist — HIG design pass (2026-10-08, unverified)

Review: [`docs/design-reviews/shell.md`](../docs/design-reviews/shell.md). Nothing below was looked at — no app launch was possible during the pass.

**Menu bar menu**
- [ ] Items read **Capture Area… · Capture Window… · Capture Entire Screen · Settings… · Quit Snappy**, with separators before Settings and Quit
- [ ] Symbols (dashed rectangle, window, display, gear) show on the first four items, align cleanly, and the Quit row's text lines up with the rest
- [ ] Shortcuts still display as ⇧⌘4, ⇧⌘3, ⌘, and ⌘Q; every item still does what it did

**Settings window**
- [ ] Layout: labels trailing-aligned with colons; groups (folder | shortcuts | editor | padding) visibly separated; hint text wraps under its control, nothing clipped, light and dark
- [ ] Save folder pop-up shows the folder icon + name; its menu lists parent folders and **Choose…**; Choose… only allows folders and the choice persists (Save writes there)
- [ ] Picking a parent folder from the pop-up menu switches the save folder to it
- [ ] Dropping a folder from Finder onto the pop-up accepts it; dropping a PNG (or a web link) is refused — or beeps and snaps back — and Save still works afterwards
- [ ] The *Open Keyboard Settings* button, the checkbox and the stepper look like native large controls (28 pt button), not stretched
- [ ] Shortcuts row shows "⇧⌘4  Capture Area" and "⇧⌘3  Capture Entire Screen"; **Open Keyboard Settings** opens System Settings › Keyboard
- [ ] Checkbox reads "Show tool icon next to the pointer" and still toggles the editor cursor badge
- [ ] Padding: stepper steps by 4; typing 30 + Return stores 30; typing 250 → 100; typing "abc" snaps back; the editor uses the new value
- [ ] ⌘A / ⌘C / ⌘V work in the padding field; ⌘W closes the window
- [ ] Closing and reopening keeps the window where it was left (centred only the first time)
- [ ] VoiceOver reads the stepper and field as "Canvas padding" and the pop-up as "Save screenshots to"

## Manual checklist — ✅ verified

- [x] `./scripts/bundle.sh` completes without errors
- [x] App launches; icon appears in the menu bar; **no** Dock icon
- [x] All menu items visible; Quit exits cleanly
