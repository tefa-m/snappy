# Snappy — Project Instructions

## Mission

**Snappy** is a personal, fully offline macOS screenshot tool: screen capture,
OCR, annotations, screenshot pinning and screen recording with live
annotations. It is self-built so it can run on locked-down machines without any
third-party software, and it is shared as source under the MIT license, and each
release also ships an ad-hoc-signed universal `.app` zip on GitHub Releases,
installable via the `tefa-m/snappy` Homebrew cask (build-it-yourself stays supported).

## Required Reading — Before Any Implementation

- **`docs/ARCHITECTURE.md` MUST always be loaded before implementing** — it holds the module map, capture flow, and hard-won invariants (coordinate systems, overlay activation rules, toolchain quirks). **Update it in the same change whenever the architecture shifts.**
- **`docs/FEATURE_MAP.md` — lazy-load whenever feature context is needed** (before implementing, extending or debugging a feature). It is a concise index of every implemented feature; load the individual feature doc (`features/*.md`) it points to for the full description, design decisions, history log and manual checklist. Keep the map and the feature docs updated in the same change that touches a feature.

## Goals & Scope

| Area | What it does |
| ---- | ------------ |
| Capture | Area (⇧⌘4, screen frozen first), full screen (⇧⌘3), window capture from the menu bar |
| Preview panel | Small borderless floating panel after each capture: **Edit, Copy, Save, OCR, Pin** (and **R** to record the area) |
| OCR | English + German text recognition, copied straight to the clipboard |
| Editor | Model-backed vector annotations: rectangle, oval, arrow, line, pen, text, counter badges, blur/pixelate, crop |
| Pins | Always-on-top, draggable, resizable screenshots |
| Recording | MP4 (H.264, no audio) of an area or window with live ink and a fading "Magic Pen" |

### Out of scope

- Any online feature — the app is **offline only** (no network code, no network entitlements)
- Third-party libraries — **Apple system frameworks only**
- Any platform other than macOS

## Tech Stack

| Item             | Choice |
| ---------------- | ------ |
| Platform         | macOS 26+ (Tahoe or newer) |
| Language         | Swift 6 (swift-tools-version 6.3) |
| UI framework     | AppKit (menu bar app, `LSUIElement` — no Dock icon); Liquid Glass (`NSGlassEffectView`) for panel chrome |
| Capture          | ScreenCaptureKit (`SCScreenshotManager.captureScreenshot`, `SCScreenshotConfiguration`, `SCShareableContent`) |
| OCR              | Vision (async `RecognizeTextRequest`), English + German, fully offline |
| Global shortcut  | Carbon `RegisterEventHotKey` |
| Image effects    | CoreImage (blur/pixelate) |
| Build system     | Swift Package Manager + `scripts/bundle.sh` (assembles and signs the `.app`) — **no Xcode required**, only Command Line Tools |
| Distribution     | Source (build locally) **or** the GitHub Release zip (universal, ad-hoc signed, not notarized) via the `tefa-m/homebrew-snappy` cask |
| Dependencies     | None (zero third-party libraries) |

## Development Workflow

| Task            | Command |
| --------------- | ------- |
| Build           | `swift build` |
| Build `.app`    | `./scripts/bundle.sh` (build → assemble bundle → codesign) |
| Install/update  | `./scripts/install.sh` (shows the branch @ commit it builds and asks before installing anything but a clean `main`; replaces the installed app and relaunches it) |
| Run             | `open dist/Snappy.app` (or `swift run` for quick iteration) |
| Release         | `./scripts/release.sh <MAJOR.MINOR.PATCH> ["notes"]` (clean `main` + green gate → annotated tag `v<version>` + push + GitHub Release with the zip from `scripts/package.sh`; then bump the cask in `tefa-m/homebrew-snappy`; version comes from the tag — bump rules in `features/versioning.md`) |
| Test            | `./scripts/test.sh` (wraps `swift test` — required with Command Line Tools only, where Testing.framework needs explicit search paths) |

Tests use **Swift Testing**, not XCTest. Keep the build at 0 warnings and the suite green.

## Conventions & Preferences

- **System frameworks only** — never add a third-party dependency
- **No network code** of any kind; the app must work fully offline
- Prefer **AppKit** for overlay windows, panels and the annotation canvas (SwiftUI only where it clearly simplifies things)
- Annotation shapes are **model-backed vectors** (selectable, editable, undoable via `NSUndoManager`) — flattened only on export
- Settings live in `UserDefaults`
- Save writes timestamped PNGs (e.g. `Shot 2026-07-17 at 14.32.05.png`) to a configurable folder, default `~/Desktop`, and never overwrites
- Pinned screenshots: always-on-top borderless window, draggable, resizable (scroll-zoom / corner-drag), semi-transparent on hover, closed with Esc, Q, or double-click
- **Shortcuts first:** every action ships with a keyboard shortcut advertised in its tooltip; Q or Esc closes any transient window. Tooltips read `<verb phrase> (KEY)`
- **Design direction:** native Liquid Glass ("Tahoe Glass") in light and dark mode; controls ≥ 28 pt; no bezel boxes on Liquid Glass
- **Nothing of Snappy's may reach the screen before the area-capture snapshot** — even a transparent window dismisses the open menu being captured (see `features/capture.md`)

## Runtime Notes

- Screen Recording (TCC) permission is required; Accessibility is requested once for recording's window-part picking.
- The ⇧⌘4 / ⇧⌘3 hot keys only take effect after the system's own ⇧⌘4 / ⇧⌘3 are disabled (System Settings → Keyboard → Keyboard Shortcuts → Screenshots).
- Use `scripts/setup-signing.sh` once per machine to create a stable self-signed identity so TCC grants survive rebuilds (details: signing quirk in `docs/ARCHITECTURE.md`).

## Reference Material

- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Apple Vision text recognition: https://developer.apple.com/documentation/vision/recognizing_text_in_images

## Private notes

Machine- and person-specific context (employer constraints, decision log, agent workflow, pending checklists) lives in `CLAUDE.local.md`, which is git-ignored. If it exists, read it too.
