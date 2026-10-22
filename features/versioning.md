# Versioning & release channels

## What it is

Snappy is versioned with **SemVer** (`MAJOR.MINOR.PATCH`), starting at **1.1.0**
(Tefa's call, 2026-10-11). The **git tag `v<version>` is the single source of
truth** — nothing in the repo hardcodes a version number. Since 2026-10-22
releases ship on three **channels**:

| Channel | Tag | Cut from | Homebrew cask | GitHub Release |
| --- | --- | --- | --- | --- |
| **beta** | `vX.Y.0-beta.N` (N ≥ 1, no leading zeros) | `main` | `snappy@beta` | pre-release |
| **stable** | `vX.Y.0` | `main` — the exact commit of the last beta | `snappy` (+ `snappy@beta` if newer) | latest |
| **patch** | `vX.Y.Z` (Z > 0) | `release/X.Y` | `snappy` (+ `snappy@beta` if newer) | latest only if it is the highest stable |

The pre-release identifier is always `beta.N`; tags are always **annotated**.

## How the version flows into the build

```
git tag -a v1.5.0-beta.2 ──► scripts/version.sh (sourced) ──► bundle.sh ──► Info.plist
                                highest tag at HEAD, else          │          CFBundleShortVersionString  1.5.0
                                git describe --tags                │          CFBundleVersion             212 (commit count)
                                git rev-list --count HEAD          │          SnappyBuildDescription      1.5.0-beta.2
                                                                   ├──► verify-bundle.sh asserts the three keys
                                                                   ├──► install.sh prints "Installing Snappy <description> — branch @ commit"
                                                                   └──► menu bar footer: AppVersion.menuTitle
```

| Build state | `SnappyBuildDescription` |
| --- | --- |
| exactly on tag `v1.1.0`, clean | `1.1.0` |
| exactly on tag `v1.5.0-beta.2` | `1.5.0-beta.2` |
| 7 commits after the tag | `1.1.0-7-gabc1234` |
| …with uncommitted changes | `1.1.0-7-gabc1234-dirty` |
| no reachable tag (shallow clone, tarball) | `0.0.0-<hash>` — the build never fails over a missing tag |

- **Several tags on one commit** (a stable is promoted on the last beta's
  commit): `version.sh` picks the **highest tag at HEAD** by
  `versionsort.suffix=-`, so `v1.5.0` wins over `v1.5.0-beta.3`, and a stray
  lightweight or older tag can never win. Without a tag at HEAD it falls back to
  `git describe` as before.
- `CFBundleShortVersionString` only accepts dotted numbers, so `SNAPPY_VERSION`
  stays numeric (`1.5.0`) even for a beta; the full string (with `-beta.N`)
  lives in `SnappyBuildDescription`. Branch names are deliberately **not** in
  the string — `install.sh` already prints the branch.
- The menu bar menu ends with a disabled **"Snappy 1.5.0-beta.2"** line above
  Quit (`AppVersion`, PURE and tested). Unbundled (`swift run`): "Snappy
  (unbundled build)".

## Bump rules

| Bump | When | Examples |
| --- | --- | --- |
| **MAJOR** | breaking change to something Tefa depends on | a shortcut remap, a settings reset, a raised minimum macOS |
| **MINOR** | new user-visible feature | a tool, a capture mode, a Settings pane |
| **PATCH** | bug fix, polish pass, internal change | |

New features ride a beta train of the next MINOR (or MAJOR); PATCH releases
are back-ported fixes on a release branch.

## Branch model (trunk + lazy release branches)

```
main  ──●──●──●──[v1.5.0-beta.1]──●──[v1.5.0-beta.2]──[v1.5.0]──●──●──[v1.6.0-beta.1]──●
                                                         │
release/1.5 (created lazily)                             └──●(pick of fix)──[v1.5.1]
```

- **All work lands on `main` first** (feature branch → merge, as today).
- **`release/X.Y`** is created **lazily**, from the highest stable tag `vX.Y.*`,
  only when a patch is needed. It is deleted once the next stable ships — its
  tags stay.
- **Back-port** = `git cherry-pick -x -m 1 <merge-sha>`, one commit per fix,
  each carrying the trailer `(cherry picked from commit <sha>)`. Release
  branches never get direct work and never merge back into `main`; their tags
  are therefore not reachable from `main`.
- **Support policy:** only the latest stable line, plus its predecessor while a
  beta train is open.

## Commands

| Command | What it does |
| --- | --- |
| `./scripts/release.sh beta [minor\|major] ["headline"]` | Open train (latest beta whose `X.Y.Z` has no stable yet) → next `beta.N`; otherwise start a new train from the latest stable (default `minor` bump) → `beta.1`. While a train is open, `minor`/`major` must name that same train (else refused — start another with an explicit `X.Y.0-beta.1`). `beta patch` is refused: betas are `X.Y.0` only; a fix for a shipped line goes through `backport.sh` + `patch` |
| `./scripts/release.sh stable ["headline"]` | Promote the open train: `vX.Y.0` on the commit of its last beta |
| `./scripts/release.sh patch ["headline"]` | Next `Z` on the current `release/X.Y`; when not on a `release/*` branch, the single `release/*` on origin (refused if there are several or none) |
| `./scripts/release.sh <version> ["headline"]` | Explicit version (`1.5.1`, `1.6.0-beta.1`), validated by the same rules (must be exactly the next number) |
| `./scripts/release.sh --resume <version> [--dry-run]` | Finish a release whose tag is already on origin (see recovery below) |
| `./scripts/backport.sh <X.Y> <merge-sha>... [--push]` | Create `release/X.Y` from the highest stable `vX.Y.*` if missing (pushed with `-u` only with `--push`), cherry-pick each merge (must be an ancestor of `origin/main`) in a temp worktree, run the tests. No tag, no publish — ready for `release.sh patch`. Conflicts abort cleanly with instructions |
| `./scripts/update-tap.sh <version> <sha256>` | Render and push the cask(s) in the tap (called by `release.sh`; usable by hand). First pushes its own pending `Snappy <version>` commits left by a failed push; only reports success once `origin/main` carries the casks |
| `./scripts/update-tap.sh --plan <version>` | Print which casks would change; touches nothing |
| `/bin/bash scripts/test-release.sh` | Sandbox suite for all release scripts (throwaway repos, `gh`/`brew` shims, no network); `KEEP=1` keeps the sandbox |

The optional **headline** (2nd argument) is prepended to the generated notes on
every channel. `release.sh` flags: **`--dry-run`** (everything except
push/publish/tap — it still tests, builds and makes a local tag, deleted at
exit; no y/N prompt), **`--yes`** (required without a TTY; on a TTY it asks
y/N), **`--resume <version>`** (continue a release whose tag is on origin; with
`--dry-run` it is strictly read-only and only prints what it would do).
Environment overrides:

| Variable | Effect |
| --- | --- |
| `SNAPPY_RELEASE_ALLOW_UNBETAED=1` | allow a stable whose commit is not the last beta's |
| `SNAPPY_RELEASE_SKIP_BUILD=1` | stub the build/zip (script tests only) — the tests still run |
| `SNAPPY_RELEASE_TEST_CMD` | replace the test gate `./scripts/test.sh` (sandbox tests) |
| `SNAPPY_RELEASE_REPO` | GitHub repo for every `gh` call and the release/compare links (default `tefa-m/snappy`) |
| `SNAPPY_TAP_DIR` | tap checkout for `update-tap.sh` (default `<repo>/../homebrew-snappy`) |

## Release flow (order of operations)

1. **Plan + confirm.** Prints version, channel, branch, base tag, commit, notes
   preview and what will be pushed / published / tap-updated.
2. **Rules.**
   - beta: from `origin/main`; `N` = previous + 1; `X.Y.Z` must exceed the latest stable.
   - stable `X.Y.0`: from `origin/main`; HEAD must equal the latest beta's commit.
   - patch `X.Y.Z`: from `origin/release/X.Y`; the previous tag of the line must
     exist and be an ancestor.
3. **Provenance gate** (every release, every remote `release/*`): each non-merge
   commit in `<base stable tag>..release/X.Y` must carry a
   `(cherry picked from commit <40-hex>)` trailer whose sha is an ancestor of
   `origin/main`. Otherwise it fails and lists the commits — a direct hotfix
   must be forward-ported to `main` first.
4. **Temp worktree** of `origin/<branch>` (detached) — never the user's
   checkout, so untracked files and local edits cannot leak into a release.
5. **Tests** (`scripts/test.sh`).
6. **Local annotated tag** (message = release notes).
7. **`scripts/package.sh`** — universal arm64+x86_64 build (one `swift build`
   per arch, merged with `lipo`; Command Line Tools have no xcbuild), ad-hoc
   signed, zipped with `ditto`. Asserts `SnappyBuildDescription` == the version
   exactly (no `-dirty`, no commit suffix).
8. **`git push --atomic origin <branch> <tag>`** — the point of no return.
9. **`gh release create --draft`** with `Snappy-<version>.zip`.
10. **Download the asset back, verify its SHA-256.**
11. **Publish:** `gh release edit --draft=false`; `--prerelease` for betas;
    `--latest` only if it is the highest stable, else `--latest=false`.
12. **Update the tap** (`update-tap.sh`).

### Failure and recovery

| Fails at | State | Recovery |
| --- | --- | --- |
| 1–7 (before the push) | nothing remote; the local tag is deleted by a trap | fix the cause, rerun |
| 8 push | atomic: branch and tag both pushed or neither | fix (e.g. fetch, auth), rerun |
| 9–11 (draft / verify / publish) | tag on the remote, release missing or still a draft | `release.sh --resume <version>` (the script prints the exact commands) — reruns the provenance gate; publishes a draft asset only if its SHA-256 matches the one recorded in the draft notes (mismatch → stop; delete the asset and resume); a missing asset is rebuilt, its SHA-256 written into the notes, and the upload re-verified |
| 12 tap | release published, cask stale | `update-tap.sh <version> <sha256>` or `--resume <version>` (tap repair only, no gate) |
| a bug found **after** publish | public | **never retag** — ship the next number (`beta.N+1`, `X.Y.Z+1`) |

## Release notes

Composed locally from git (no PRs needed); `CHANGELOG.md` does not exist —
`git tag -n99` and the GitHub Releases show the notes, per-feature history stays
in the feature docs.

| Channel | Body |
| --- | --- |
| beta | `git log --first-parent --format='- %s'` since the previous tag of the train (`beta.1`: since the latest stable) |
| stable `X.Y.0` | the same list since the latest **stable** tag reachable — so it **bundles all betas**; merges already shipped in a patch move from "Changes" to an "Already shipped in patch releases" section as `- <subject> (also in X.Y.Z)`; a "Pre-releases" section linking each beta |
| patch | subjects of the picked commits since the previous patch/stable tag |

Every channel may start with the headline. Footer on all: compare link
`https://github.com/tefa-m/snappy/compare/<prev>...<tag>`, the install command
of the channel, the zip's SHA-256, and for betas "Pre-release, may be unstable".

## Homebrew casks

The tap **`tefa-m/homebrew-snappy`** holds two casks, rendered by
`update-tap.sh` from `scripts/templates/snappy.rb.tmpl` and
`snappy@beta.rb.tmpl`:

| Cask | Install | Gets | livecheck |
| --- | --- | --- | --- |
| `snappy` | `brew install --cask tefa-m/snappy/snappy` | stable + patch | `github_latest` |
| `snappy@beta` | `brew install --cask tefa-m/snappy/snappy@beta` | betas **and** stables/patches newer than both casks | `github_releases` incl. pre-releases, skipping drafts |

- Update rule (against the casks before the run): `snappy` changes iff the new
  version is stable **and** newer than its current version; `snappy@beta`
  changes — or is created if missing — iff the new version is newer than its
  current version (if any) **and** than the stable cask (or there is no stable
  cask). So an older-line patch moves neither, a stale beta cask never drops
  below stable, and a newer stable moves both. Comparison: SemVer core
  numerically, stable > beta, `beta.N` numerically.
- Both casks `conflicts_with` each other, share the app and the `zap` stanza
  (`com.tefa.snappy`), `depends_on macos: :tahoe`, and strip
  `com.apple.quarantine` in `postflight`.
- **Tap trust:** users always run the **fully-qualified** name
  (`tefa-m/snappy/…`), which taps the repo on first use; there is no separate
  `brew tap` step to document.
- **Switching channels:** `brew uninstall --cask snappy@beta` then
  `brew install --cask tefa-m/snappy/snappy` (and vice versa). Settings live in
  `UserDefaults` and survive.
- `update-tap.sh` needs a clean tap checkout on `main` (it pulls `--ff-only`
  first), runs `brew style`, commits, pushes, then `brew audit --cask --strict`
  (warning only). It never touches the brew-managed clone under `/opt/homebrew`.

## Safeguards

| Safeguard | Protects against |
| --- | --- |
| Provenance gate | a fix that exists only on a release branch and would vanish in the next stable |
| stable == last beta commit | shipping a stable nobody ran as a beta (override: `SNAPPY_RELEASE_ALLOW_UNBETAED=1`) |
| Annotated tags only | lightweight tags that `describe`/notes would treat differently |
| `git -c versionsort.suffix=- tag --sort=-v:refname --list 'v[0-9]*'` | wrong order of pre-releases — plain `sort -V` ranks `1.5.0-beta.1` **above** `1.5.0` on macOS |
| "stable-only" describe: `--match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*'` | a beta tag being taken as the base of a stable |
| Temp worktree + exact-version assert | releasing local edits or a `-dirty` build |
| `--dry-run`, plan + y/N, `--yes` for non-TTY | accidental releases |

GitHub immutable releases and tag rulesets are configured on the repo separately
(not by the scripts).

## Caveats

- **Ad-hoc signing:** every update has a new signature, so macOS asks for
  Screen Recording again after each `brew upgrade` (beta users see this more
  often).
- **Official `homebrew/cask`** requires notarization (Developer ID) — Snappy
  stays in its own tap.
- **`CFBundleVersion` on release branches:** it is the commit count, so a patch
  from `release/1.5` can carry a **lower** build number than a beta from
  `main`. Nothing in Snappy or Homebrew compares it; don't rely on it across
  branches.
- Scripts target macOS `/bin/bash` 3.2 and use only git, gh, brew, shasum and ditto.

## Worked example: fix stable while betas run

`v1.5.0` is out, `v1.6.0-beta.2` is on `main`, and a capture bug hits 1.5 users.

```sh
# 1. fix on main as usual: feature branch → merge (say merge sha abc1234)
# 2. back-port: creates release/1.5 from v1.5.0, picks the merge, runs tests
./scripts/backport.sh 1.5 abc1234 --push
# 3. ship the patch from origin/release/1.5
./scripts/release.sh patch            # → v1.5.1, latest, snappy cask bumped
# 4. the betas pick it up on the next train step
./scripts/release.sh beta             # → v1.6.0-beta.3 (contains the fix via main)
```

When `v1.6.0` ships, its notes mark the fix "(also in 1.5.1)", and
`release/1.5` can be deleted.

## Design decisions

- **2026-10-11 (grilling):** tag-derived version (no `VERSION` file);
  `CFBundleVersion` = commit count (monotonic, deterministic); `v1.1.0` tagged
  on the commit that introduces versioning.
- **2026-10-22 — release channels** (Tefa: "go" on the defaults): trunk-based
  with lazy `release/X.Y` instead of a long-lived `develop`/`beta` branch, so
  betas and stables are the same commits and nothing needs merging back; fixes
  always go `main` first and are cherry-picked with `-x` so the provenance gate
  can prove it; stable is promoted on the last beta's commit (no rebuild of
  untested code); two casks (`snappy`, `snappy@beta`) instead of a version
  switch inside one; notes from git so no PR workflow is required; releases
  build in a temp worktree so the user's checkout never matters.

## History

- **2026-10-22** — Release channels: beta/stable/patch, `release/X.Y` +
  `backport.sh`, provenance gate, temp-worktree builds, `--dry-run/--yes/--resume`,
  composed notes, `update-tap.sh` with `snappy` + `snappy@beta` casks;
  `version.sh` picks the highest tag at HEAD.
  Review fixes: `--resume --dry-run` is read-only; resume reruns the provenance
  gate and verifies the draft asset against the SHA-256 in its notes;
  `update-tap.sh` pushes a pending commit from a failed push and verifies
  `origin/main`; `snappy@beta` never moves below the stable cask.
- **2026-10-22** — Binary releases: `package.sh`, GitHub Release in `release.sh`, Homebrew cask in `tefa-m/homebrew-snappy`.
- **2026-10-11** — Introduced: `scripts/version.sh`, `release.sh`, bundle/verify/
  install wiring, `AppVersion` + menu footer, tests. Plist was hardcoded `0.1.0`/`1` before.

## Manual checklist

- [ ] `./scripts/release.sh beta --dry-run` prints the plan, builds, tests, pushes nothing
- [ ] `./scripts/release.sh beta` publishes `vX.Y.0-beta.1` as a GitHub **pre-release**; `snappy@beta` cask bumped, `snappy` untouched
- [ ] `brew install --cask tefa-m/snappy/snappy@beta` installs; menu footer reads "Snappy X.Y.0-beta.1"
- [ ] `./scripts/release.sh stable` refuses when `main` moved past the last beta; succeeds on it; release marked **latest**; both casks bumped
- [ ] After the stable, the menu footer of a fresh build on that commit reads "Snappy X.Y.0" (not `-beta.N`)
- [ ] `brew install --cask tefa-m/snappy/snappy` on a clean Mac installs and launches; `brew upgrade --cask snappy` picks up the next release
- [ ] Switching: `brew uninstall --cask snappy@beta` → `brew install --cask tefa-m/snappy/snappy` keeps settings
- [ ] `backport.sh` + `release.sh patch` ships `vX.Y.Z` from `release/X.Y`; `--latest=false` when a newer stable exists
- [ ] A direct (non-picked) commit on a `release/*` branch makes every release fail the provenance gate
- [ ] Interrupting after the push and running `--resume <version>` finishes the release
- [ ] `--resume <version> --dry-run` on a pending release changes nothing (no draft, publish or tap commit)
- [ ] A build with uncommitted changes shows `-dirty`
