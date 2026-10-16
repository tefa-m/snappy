# Snappy

A personal macOS utility, shared as source under MIT: area / window / full-screen
capture, on-device OCR, an annotation editor, pinned screenshots, and screen
recording with live annotations. It lives in the menu bar (no Dock icon) and
uses only Apple system frameworks — no third-party dependencies. There are no
prebuilt downloads; you build it yourself.

## Features

- **Capture:** ⇧⌘4 area (the screen is frozen first, so open menus and tooltips
  can be captured), ⇧⌘3 full screen, window capture from the menu bar.
- **Preview panel** after each capture: Edit · Copy · Save · OCR · Pin, and R to
  record that area.
- **OCR:** text recognition (English + German) with Apple's Vision framework,
  copied straight to the clipboard.
- **Editor:** rectangle, oval, arrow, line, pen, text, counter badges, blur,
  pixelate, crop; the canvas grows when annotations go past the edge.
- **Pins:** always-on-top screenshots you can move, zoom and resize.
- **Recording:** MP4 (H.264, no audio) of an area or window, with live ink and a
  fading "Magic Pen" drawn into the video.

Most capture, editing and recording actions have keyboard shortcuts, shown in
their tooltips.

## Requirements

macOS 26 (Tahoe) or newer and Swift 6.3 or newer. The Xcode **Command Line
Tools** are enough (`xcode-select --install`); full Xcode is not needed.

## Build and run

```sh
git clone https://github.com/tefaa89/snappy.git && cd snappy
swift build                 # debug build
./scripts/test.sh           # test suite (wraps `swift test` for Command Line Tools)
```

Then **either** try it without installing **or** install it:

```sh
./scripts/bundle.sh && open dist/Snappy.app   # A: release build → dist/Snappy.app (signed, see below)
./scripts/install.sh                          # B: bundle, verify, copy into /Applications
```

`install.sh` updates an existing Snappy in `~/Applications` or `/Applications`
(default `/Applications`). It only replaces a `Snappy.app` whose bundle identifier
is `com.tefa.snappy`, and stops before touching the installed app if that
`Snappy.app` is a symlink or a `Snappy.app.old` from an earlier failed run is
still there (check it first: it may be your last working copy). If Snappy runs
from the folder being updated, the script sends it a plain SIGTERM, which skips
Snappy's own quit handling (quit it yourself first while recording), and
reopens it afterwards. If it doesn't exit within 5 seconds, or the process list
can't be read, the script stops and asks you to quit Snappy yourself. It uses
`sudo` only if the folder isn't writable, deletes `dist/Snappy.app` afterwards,
and asks for confirmation when you're not on a clean `main`.

The version comes from the nearest `v*.*.*` git tag (`scripts/version.sh`); a
download without git history builds as `0.0.0`.

## First run & permissions

1. **Free up ⇧⌘4 and ⇧⌘3.** macOS uses them for its own screenshots and gets
   them first. Turn them off in System Settings → Keyboard → Keyboard Shortcuts…
   → Screenshots. Until then, use the menu bar icon (Capture Area…, Capture
   Window…, Capture Entire Screen).
2. **Screen Recording.** A fresh install waits for your first capture before
   asking. Allow Snappy in System Settings → Privacy & Security → Screen &
   System Audio Recording; macOS may ask you to quit and reopen the app. If
   access is missing, Snappy shows an alert with a link to that page. macOS may
   also ask from time to time whether Snappy should keep its access.
3. **Notifications** (optional) — asked the first time Snappy shows a banner,
   normally after an OCR. The "Text Copied" banner shows up to the first 80
   characters of the recognized text; if that is sensitive, turn previews off
   for Snappy in System Settings → Notifications.
4. **Accessibility** (optional) — asked once, the first time you snap a
   recording to a window (S/W). It lets Snappy pick parts of a window (a
   browser's page area, a pane). To read them, it may switch Chromium/Electron
   apps into their accessibility mode while you pick. Without it, Snappy falls
   back to whole windows.

### Signing and lost permissions

`bundle.sh` signs ad hoc by default (`codesign -s -`). macOS ties an ad-hoc
app's permissions to that exact binary, so **a rebuilt app can lose its Screen
Recording grant**: the switch in System Settings may still look on while
captures fail. A stable local signing identity is meant to avoid repeated
grants; it is optional and set up once per Mac:

```sh
./scripts/setup-signing.sh
```

It creates a self-signed code-signing certificate called "Snappy Dev" in your
login keychain and marks it trusted for code signing (you'll be asked for your
password, and on the first build to allow `codesign` access). `bundle.sh` then
signs with it. macOS or a management profile may still ask for approval.

To remove it again — **untested by the project**; the chain stops at the first
failing step:

```sh
pem=$(mktemp) &&
  security find-certificate -c "Snappy Dev" -p > "$pem" &&
  security remove-trusted-cert "$pem" &&
  security delete-identity -c "Snappy Dev" &&   # deletes the certificate and its key
  echo "Removed." || echo "Stopped: a step failed, see the message above."
rm -f "$pem"
```

On a Mac managed by an MDM profile, an administrator may have to allow Screen
Recording and Accessibility.

## Privacy and data

- **No network code.** The app contains no networking or analytics code, and
  OCR runs on the device. The app is not sandboxed, so this is a property of
  the source code, not something macOS enforces — read the code if you need
  certainty.
- **Where data goes:**

  | What | Where |
  | --- | --- |
  | Saved screenshots | `~/Desktop` by default (configurable) |
  | Copy / OCR results | the system clipboard |
  | Recording takes | `~/Library/Caches/com.tefa.snappy/Recordings/` — the latest take stays there (for "Reopen Last Recording", across relaunches and after Save) until a newer one replaces it |
  | A copied, unsaved recording | a file in the temporary folder, replaced on the next Copy |
  | Settings | `defaults read com.tefa.snappy` |

- **There is no secure redaction tool.** Blur and pixelate make text hard to
  read, but the result still derives from the original pixels, and filled
  shapes are translucent. For passwords or other secrets, crop the sensitive
  area out and check the exported image before sharing it.

## Uninstall

Quit Snappy and delete `Snappy.app`. Optional clean-up: `defaults delete com.tefa.snappy`,
`rm -rf ~/Library/Caches/com.tefa.snappy`, `tccutil reset ScreenCapture com.tefa.snappy`,
`tccutil reset Accessibility com.tefa.snappy`, and the signing removal steps above.

## Distribution status

Source only. Builds are ad-hoc or self-signed, without hardened runtime or
notarization. A copied or downloaded build may be blocked by Gatekeeper;
building on the Mac you use it on is the supported workflow.

## Project docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — modules, capture flow, and the invariants that keep it working
- [`docs/FEATURE_MAP.md`](docs/FEATURE_MAP.md) — index of the per-feature docs in `features/`

Development checks are `swift build` (no warnings) and `./scripts/test.sh`; the
tests need a normal logged-in macOS session (they use Vision, CoreImage and
AppKit) and can hang in sandboxed or headless environments. Snappy was developed
with the help of AI coding agents; the history logs in the docs mention them
(see the feature map).

## License

[MIT](LICENSE) © 2026 Mostafa Abdelkhalek. Not affiliated with Apple.
macOS, ScreenCaptureKit and SF Symbols are Apple's.
