# Snappy — Feature Map

Index of all implemented features. Each entry points to a doc in `features/` with the full description, design decisions, history log, and manual verification checklist. Read the feature doc before modifying, extending, or debugging that feature; read [`ARCHITECTURE.md`](ARCHITECTURE.md) before any change.

| Feature doc | What it covers |
| ----------- | -------------- |
| [`features/app-shell.md`](../features/app-shell.md) | Menu bar app skeleton (LSUIElement), SPM-only build (`bundle.sh`), optional "Snappy Dev" signing & TCC survival, deployment, the per-change verification gate & testing strategy |
| [`features/capture.md`](../features/capture.md) | Area / window / fullscreen capture via ScreenCaptureKit; **frozen-screen area selection** (captures open menus & tooltips), overlay windows, coordinate math (`CaptureGeometry`), TCC denial handling |
| [`features/preview-panel.md`](../features/preview-panel.md) | ⇧⌘4 / ⇧⌘3 global hot keys (Carbon) + post-capture floating panel with Edit · Copy · Save · OCR · Pin; Save naming/folder |
| [`features/pin.md`](../features/pin.md) | Always-on-top pinned screenshots: drag, scroll-zoom, corner resize, subtle hover transparency + hover toolbar (Close·Edit·Copy), pin-from-editor, edit-from-pin |
| [`features/ocr.md`](../features/ocr.md) | Offline Vision OCR (EN+DE) → clipboard + notification banner |
| [`features/editor.md`](../features/editor.md) | Annotation editor foundation: document/undo model, canvas≡export rendering, unified toolbar, rectangle/oval highlight tools |
| [`features/arrow-tool.md`](../features/arrow-tool.md) | Tapered, rounded-edge arrow tool; bendable via scalar-bow curve with endpoint + bend handles |
| [`features/annotations.md`](../features/annotations.md) | Remaining tools: text, line, freehand pen, blur/pixelate, counter badges, crop |
| [`features/shortcuts-ux.md`](../features/shortcuts-ux.md) | Standing shortcuts-first rule + the full keyboard-binding table (update when adding actions); Caps Lock-proof modifier handling (`ShortcutKeys`); **remappable global hot keys** (⇧⌘4/⇧⌘3/⌃⌥D/⌃⌥P — Settings recorders, live rebind, `GlobalHotKeys`) |
| [`features/app-icon.md`](../features/app-icon.md) | Generated app icon (dark squircle `.icns`) + menu bar template glyph; `generate-icons.sh` pipeline from `assets/snappy-dynamic-s.png` |
| [`features/tool-cursor.md`](../features/tool-cursor.md) | Tool-aware editor cursor: crosshair + toolbar-symbol badge per tool, select-tool hover cursors (move/resize/handle), tool-name flash, disable setting |
| [`features/canvas-expansion.md`](../features/canvas-expansion.md) | Auto-expanding canvas: derived negative-origin canvas rect, single-uniform-color adaptive background (perimeter clustering), expansion embedded in Copy/Save/Pin/reopen, padding setting |
| [`features/versioning.md`](../features/versioning.md) | SemVer from git tags: `version.sh` → plist (`CFBundleShortVersionString`, `CFBundleVersion`, `SnappyBuildDescription`), menu bar version footer, release channels **beta / stable / patch** (`release.sh`, temp-worktree build, provenance gate, `--dry-run/--yes/--resume`), lazy `release/X.Y` + `backport.sh`, release notes grouped by `type: summary` subjects (+ opt-in `scripts/hooks/commit-msg` for `main`), `snappy` / `snappy@beta` casks via `update-tap.sh`, bump rules |
| [`features/recording.md`](../features/recording.md) | Screen video recording (MP4 H.264, no audio) with live annotations: ⇧⌘4 → drag → R (or "Record Area…"), live Setup rect with S/W window snapping (keys or the toolbar's Area/Window buttons) and Accessibility-based window parts, countdown, draw/interact modes (⌃⌥D), ink composited into the video, Magic Pen fading ink (⌃⌥P), persistent recording windows (Retake/⌘S/⇧⌘C, Reopen Last Recording) with an **export-size slider** (100/75/50/25 %, `[` `]`, re-encoded Save/Copy, size estimate, Settings default), menu bar ● + elapsed time, Settings → Recording |

## Status

Every feature above is implemented and covered by the automated gate (`swift build` with 0 warnings + `./scripts/test.sh`). Each feature doc ends with a manual checklist; checklists marked **pending** have not yet been walked through on screen since their last change — most notably the HIG design pass and Tahoe Glass look (2026-10-08), recording v1/v2 (2026-10-09/11), Magic Pen (2026-10-15), pins-in-captures (2026-10-14), remappable hot keys, the toolbar Area / Window buttons and the recording export size (2026-10-20). Treat those areas as less battle-tested.

## Reading the history logs

The feature docs keep a dated history log, written while the app was built. A few conventions in it:

- **Tefa** is the author. "Tefa's feedback / decision" marks a product call made by the author after trying the app.
- The app was developed with AI coding agents. **Leader** (the coordinating agent), **Sol** (an independent reviewer agent), dev / merger / E2E roles, task IDs (T0–T7, V1–V3, M-A…M-F) and Q-numbers (questions from design interviews) come from that workflow.
- Logs mention internal plans and review reports (`docs/RECORDING_PLAN.md`, `docs/design-reviews/`, `docs/recording-reviews/`, `docs/magic-pen-reports/`, `archive/`). Those working documents are **not part of this repository**; the decisions they produced are recorded in the feature docs themselves.
- Test counts in the logs ("204 tests") are snapshots of that day.
