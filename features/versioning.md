# Versioning

## What it is

Snappy is versioned with **SemVer** (`MAJOR.MINOR.PATCH`), starting at **1.1.0**
(Tefa's call, 2026-10-11). The **git tag `v<version>` is the single source of
truth** — nothing in the repo hardcodes a version number.

## How it flows

```
git tag v1.1.0 ──► scripts/version.sh (sourced) ──► bundle.sh  ──► Info.plist
                       git describe --tags               │            CFBundleShortVersionString  1.1.0
                       git rev-list --count HEAD         │            CFBundleVersion             136 (commit count)
                                                         │            SnappyBuildDescription      1.1.0-7-gabc1234-dirty
                                                         ├──► verify-bundle.sh asserts the three keys
                                                         ├──► install.sh prints "Installing Snappy <description> — branch @ commit"
                                                         └──► menu bar footer: AppVersion.menuTitle
```

| Build state | `SnappyBuildDescription` |
| --- | --- |
| exactly on tag `v1.1.0`, clean | `1.1.0` |
| 7 commits after the tag | `1.1.0-7-gabc1234` |
| …with uncommitted changes | `1.1.0-7-gabc1234-dirty` |
| no reachable tag (shallow clone, tarball) | `0.0.0-<hash>` — the build never fails over a missing tag |

`CFBundleShortVersionString` only accepts dotted numbers, so it holds the tag
number alone (`1.1.0`); the full string lives in the custom key
`SnappyBuildDescription`. Branch names are deliberately **not** in the string —
`install.sh` already prints the branch, and a branch build shows extra commits.

The menu bar menu ends with a disabled **"Snappy 1.1.0-7-gabc1234"** line above
Quit (`AppVersion`, PURE and tested). Unbundled (`swift run`) it reads
"Snappy (unbundled build)".

## Bump rules

| Bump | When | Examples |
| --- | --- | --- |
| **MAJOR** | breaking change to something Tefa depends on | a shortcut remap, a settings reset, a raised minimum macOS |
| **MINOR** | new user-visible feature | a tool, a capture mode, a Settings pane |
| **PATCH** | bug fix, polish pass, internal change | |

## Releasing

`./scripts/release.sh <version> ["notes"]` — refuses unless on a clean `main`
equal to `origin/main`, the version is strictly newer than the last tag with
commits since it, and `./scripts/test.sh` is green. Then it creates the
annotated tag (message = release notes, default: the commit subjects since the
last tag) and pushes `main` + the tag. **No `CHANGELOG.md`** — `git tag -n99`
shows the notes; per-feature history stays in the feature docs.

## Design decisions (grilling, 2026-10-11)

- Tag-derived (not a `VERSION` file) so there is nothing to keep in sync.
- `CFBundleVersion` = commit count: monotonic and deterministic.
- `v1.1.0` is tagged by `release.sh` on the commit that introduces versioning
  (the tag then contains the code that reports it), not on the earlier
  recording-v2 merge log.

## History

- **2026-10-11** — Introduced: `scripts/version.sh`, `release.sh`, bundle/verify/
  install wiring, `AppVersion` + menu footer, tests. Plist was hardcoded `0.1.0`/`1` before.

## Manual checklist

- [ ] `./scripts/release.sh 1.1.0` from clean `main` creates and pushes `v1.1.0`
- [ ] After install, the menu footer reads "Snappy 1.1.0" (exactly on the tag)
- [ ] A build with uncommitted changes shows `-dirty`
