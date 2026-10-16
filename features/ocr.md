# OCR — Offline Text Recognition

## What it is

Milestone M3 (priority P3): the panel's OCR action recognizes text in the capture — fully offline — and copies it to the clipboard.

- Async Swift Vision API `RecognizeTextRequest` on the captured `CGImage`: `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, `recognitionLanguages = [Locale.Language]` for `en-US` + `de-DE`
- `try await request.perform(on: image)` — Vision runs recognition off-main internally, so accurate mode never blocks the UI and `TextRecognizer` needs no isolation annotations
- Observations joined top-to-bottom preserving line breaks, trailing whitespace trimmed (pure `TextAssembler`, unit-tested)
- Result → `NSPasteboard` + `UserNotifications` banner "Text Copied" with a short preview; "No Text Found" (clipboard untouched) when nothing was recognized — copy in the pure `UserFacingText`
- Every OCR banner shares one identifier, so a new result **replaces** the previous one (Notification Center holds at most one recognized text); with previews hidden, macOS shows only the title. When the banner can't be shown (notifications denied / set to None / unbundled), "No Text Found" plays the system alert sound and asks VoiceOver to announce it instead of staying silent (a visible HUD for a muted Mac is deferred)
- A recognition error shows an alert: "Snappy couldn't recognize text in the screenshot." + the system's reason when it is readable + "Try again…"
- A real offline Vision integration test renders EN/DE text (incl. ä/ö/ü/ß) into a `CGImage` and asserts the recognized string

## Log

- **2026-07-17** — Decision: OCR languages are English + German
- **2026-07-18** — M3 implemented. Gotcha: `UNUserNotificationCenter` **crashes unbundled** — `UserNotifier` falls back to `NSLog` under `swift run`; test banners with the built `.app`. First OCR triggers the notification-permission prompt
- **2026-07-19** — macOS 26 retarget: migrated `VNRecognizeTextRequest` → async `RecognizeTextRequest` (macOS 15+ Swift Vision API). Deleted the `ImageBox @unchecked Sendable` + `Task.detached` hop — the new API is async and CGImage is `Sendable` in the macOS 26 SDK. `observation.boundingBox.cgRect` keeps the normalized lower-left origin `TextAssembler` expects (integration test confirms line order)
- **2026-10-08** — HIG design pass (`docs/design-reviews/shell.md`): banners title-style ("Text Copied", "No Text Found"), one shared banner identifier (each result replaces the last), hidden-preview category shows the title only, a beep + VoiceOver announcement when "No Text Found" can't be shown, and the OCR error alert no longer shows `String(describing: error)`. Open product question for Tefa: keep showing the recognized text in the banner? (HIG: no confidential content in notifications)

## Manual checklist — HIG design pass (2026-10-08, unverified)

Review: `docs/design-reviews/shell.md` (#8 Alerts & notifications).

- [ ] OCR of text → banner title **Text Copied**, body is the one-line preview
- [ ] OCR twice → Notification Center shows only the latest OCR banner, not both
- [ ] OCR of an image without text → **No Text Found** / "The screenshot contains no recognizable text. The clipboard is unchanged."
- [ ] System Settings › Notifications › Snappy set to **None** (or notifications off) → OCR with no text plays the alert sound; OCR with text copies silently
- [ ] Same, with VoiceOver on → it announces "No Text Found. The screenshot contains no recognizable text. …"; with *Flash the screen when an alert sound occurs* on and sound muted → the screen flashes
- [ ] System Settings › Notifications › Show previews: **Never** → the banner shows "Text Copied" without the recognized text
- [ ] Save to a read-only folder (e.g. set the save folder to `/System`) → alert "Snappy couldn't save the screenshot to “System”." with the system's reason and the Settings hint — no raw path, no error dump
- [ ] Optional, re-prompts TCC: `tccutil reset ScreenCapture com.tefa.snappy`, deny, then ⇧⌘4 → "Snappy doesn't have permission to record the screen." naming *Screen & System Audio Recording*; **Open System Settings** opens that pane

## Manual checklist — ✅ verified (Tefa, 2026-07-18)

- [x] With Wi-Fi off: OCR of a real mixed EN/DE screenshot puts the correct text on the clipboard
- [x] "Text copied" notification appears with a preview
- [x] Capture with no text → "No text found" notification, clipboard untouched
