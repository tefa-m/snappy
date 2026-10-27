# Snappy — Glossary

Terms used across the code, the docs and the feature notes. Keep this file in
sync when a term's meaning changes.

| Term | Meaning |
| ---- | ------- |
| **Hot key** | One of Snappy's four remappable global shortcuts (`SnappyHotKey`): Capture Area (⇧⌘4), Capture Entire Screen (⇧⌘3), Draw Mode (⌃⌥D) and Magic Pen (⌃⌥P). Registered through Carbon `RegisterEventHotKey` by `GlobalHotKeys`, the only owner of `HotKeyCenter`. In-session single-letter keys are *not* hot keys. |
| **Live** | The system accepted the hot key's combo and it is bound: a Carbon hot key backs it now. `GlobalHotKeys.isLive` deliberately also reports true for an absent registration (e.g. a session key outside a session), where `label(for:)` advertises the configured combo for the next session rather than a currently held registration. Only a live hot key is advertised (`GlobalHotKeys.label(for:)` returns nil otherwise); one that isn't keeps its stored combo and is retried. |
| **Session key** | Draw Mode or Magic Pen — a hot key registered only during a recording session (`GlobalHotKeys.beginSession` / `endSession`), so its combo reaches other apps the rest of the time. Outside a session a new combo is only probed for availability. |
