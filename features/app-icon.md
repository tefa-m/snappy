# App Icon

## What it is

Snappy's visual identity: a macOS squircle app icon (white "S" on a near-black
rounded rect) plus a monochrome template "S" glyph in the menu bar. Fully
generated from one committed source image — no asset catalogs, no Xcode.

## Pipeline

```
assets/snappy-dynamic-s.png          source of truth (2048×2048, black S on white)
  └─ scripts/generate-icons.sh      (wraps swift scripts/generate-icons.swift + iconutil)
       └─ assets/generated/
            AppIcon.icns            dark variant — SHIPPED default
            AppIcon-light.icns      light variant — kept for future use
            MenuBarIcon.png / @2x   18/36 px black+alpha template glyph
            *.iconset/              intermediates (gitignored)
```

- **Generated artifacts are committed** so `scripts/bundle.sh` stays a pure copy
  step (copies the `.icns` + menu PNGs into `Contents/Resources/`, plist has
  `CFBundleIconFile = AppIcon`). Finder, Get Info, NSAlert, and TCC dialogs pick
  the icon up automatically — zero code.
- **Regenerate only when the source image changes** (`./scripts/generate-icons.sh`).
  `bundle.sh` guards against forgetting: if `assets/snappy-dynamic-s.png` is newer
  than `assets/generated/AppIcon.icns` it prints a warning to stderr and builds
  anyway (non-fatal — the committed artifacts are always usable).
- Menu bar: `StatusItemController.menuBarImage()` loads `MenuBarIcon@2x.png`
  from the bundle (`size 18×18`, `isTemplate = true` → adapts to light/dark/
  highlighted menu bar); falls back to the `camera.viewfinder` SF Symbol when
  running unbundled via `swift run` (same bundle-guard pattern as `UserNotifier`).

## Design decisions

- **Dark variant is the default** (Tefa, plan decision 2026-07-19); the light
  variant is generated and committed alongside for future switching.
- Apple icon grid: 832×832 rounded rect centered on a 1024 canvas, corner
  radius ≈ 186 (`CGPath(roundedRect:)` — squircle approximation), subtle
  vertical gradient on the dark variant; S at 62% of shape width.
- The S is extracted from the source as a **luminance→alpha mask** (dark
  strokes → opaque), tight-cropped, so it can be recolored (white on dark,
  black on light, black template for the menu bar).
- Menu bar glyph: square canvas, ~10% padding, aspect-fit — rendered at 18 and
  36 px (`@2x`).
- CLT-only build → single `.icns`, no asset catalog, no automatic
  light/dark/tinted icon switching (that requires Xcode's `.appiconset`).

## Quirks

- **Plist changed → bundle re-signed** on every `bundle.sh` run; the "Snappy
  Dev" identity keeps the TCC grant valid (see ARCHITECTURE signing quirk).
- Finder caches icons — after rebuilding, `touch dist/Snappy.app` (or relaunch
  Finder) if the old/generic icon still shows.
- If the S ever looks muddy at 16/32 px, boost alpha gamma for the small sizes
  in `generate-icons.swift` (checked 2026-07-19: readable as generated).

## History

- **2026-07-19** — Post-MVP M-B: icon pipeline created (source moved from
  `inbox/` to `assets/`), dark `.icns` shipped as default, template menu bar
  glyph replaces the `camera.viewfinder` symbol, `verify-bundle.sh` checks the
  icon artifacts.

- **2026-10-08** — HIG design review (`docs/design-reviews/shell.md`, #11), review-only, no
  artifacts regenerated. Deferred (Low, modernization): a layered Icon Composer icon, which would
  get system dark/clear/tinted appearances — the flat `.icns` is allowed but has none; how macOS 26
  renders it was not inspected (checklist below); compiling a `.icon` needs `actool` (Xcode); the menu bar S measures 14 × 12 pt inside its
  18 pt image in a 22 pt status bar and could grow once compared visually with neighbouring extras.

## Manual checklist — HIG design pass (2026-10-08, unverified)

- [ ] Finder (icon + Get Info) and any Snappy alert: does macOS 26 draw the
      icon inside a grey system plate (legacy-icon treatment)? Note the answer in this doc
- [ ] Menu bar S next to Wi-Fi / Control Center: visually similar weight and height? (L3)

## Manual verification checklist

- [ ] Menu bar shows the S glyph, correct in light mode, dark mode, and while
      highlighted (menu open)
- [ ] Finder shows the dark squircle for `dist/Snappy.app` (icon + Get Info;
      `touch dist/Snappy.app` if cached)
- [ ] An NSAlert (e.g. Screen Recording denial alert) shows the icon
- [ ] `swift run` (unbundled) falls back to the `camera.viewfinder` symbol
- [ ] 16/32 px renders inspected — S readable, not muddy
