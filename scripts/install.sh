#!/bin/bash
# Builds Snappy.app and installs it over the existing installation.
#
# Install location is DISCOVERED, never guessed: whichever of ~/Applications
# and /Applications already holds a Snappy.app is updated in place (both, if
# both do — a stale second copy is worse than a redundant update). With no
# installation found, /Applications is the default.
#
# Snappy is a menu bar app, so a running instance is quit before its bundle is
# replaced and relaunched afterwards.
#
# The freshly built dist/Snappy.app is a staging artifact: once it has been
# copied into place it is deleted, so the only Snappy.app left on disk is the
# installed one and `open dist/Snappy.app` can never launch a stale build.
#
# It builds whatever is checked out, so it first says which commit that is and
# asks before installing anything but a clean `main` — a mid-integration branch
# once left a stub build installed (2026-10-09). Without a terminal to ask on,
# it refuses; SNAPPY_INSTALL_ANY_BRANCH=1 skips the question.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="dist/Snappy.app"

# --- what is being installed? ---------------------------------------------
if git rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH=$(git branch --show-current)
    source scripts/version.sh
    echo "Installing Snappy $SNAPPY_DESCRIPTION — ${BRANCH:-detached HEAD} @ $(git log -1 --format='%h (%s)')"
    PROBLEMS=()
    [ "$BRANCH" = main ] || PROBLEMS+=("you're on ${BRANCH:-a detached HEAD}, not main")
    [ -z "$(git status --porcelain)" ] || PROBLEMS+=("the working tree has uncommitted changes")
    if [ ${#PROBLEMS[@]} -gt 0 ] && [ "${SNAPPY_INSTALL_ANY_BRANCH:-}" != 1 ]; then
        for problem in "${PROBLEMS[@]}"; do echo "WARNING: $problem." >&2; done
        if [ ! -t 0 ]; then
            echo "Refusing to install without confirmation (set SNAPPY_INSTALL_ANY_BRANCH=1 to override)." >&2
            exit 1
        fi
        read -r -p "Install anyway? [y/N] " answer || answer=""
        case $answer in
            [yY]*) ;;
            *) echo "Not installed."; exit 1 ;;
        esac
    fi
fi

./scripts/bundle.sh
./scripts/verify-bundle.sh "$SRC"

# --- where is Snappy installed? -------------------------------------------
TARGETS=()
for dir in "$HOME/Applications" /Applications; do
    [ -d "$dir/Snappy.app" ] && TARGETS+=("$dir")
done

case ${#TARGETS[@]} in
    0) TARGETS=(/Applications)
       echo "No existing installation — installing to /Applications." ;;
    1) echo "Existing installation found in ${TARGETS[0]} — updating it there." ;;
    *) echo "WARNING: Snappy.app exists in BOTH ${TARGETS[*]} — updating both." >&2
       echo "         Remove one to avoid launching a stale copy." >&2 ;;
esac

# --- quit a running instance ----------------------------------------------
RELAUNCH=false
if pgrep -x Snappy >/dev/null; then
    RELAUNCH=true
    echo "Quitting running Snappy…"
    osascript -e 'quit app "Snappy"' 2>/dev/null || true
    for _ in $(seq 20); do
        pgrep -x Snappy >/dev/null || break
        sleep 0.25
    done
    if pgrep -x Snappy >/dev/null; then
        echo "  did not quit gracefully — terminating." >&2
        pkill -x Snappy || true
        sleep 1
    fi
fi

# --- install ---------------------------------------------------------------
# Escalates only when the destination directory is not writable. (Not an array
# of prefix words: bash 3.2 + `set -u` chokes on expanding an empty array.)
NEED_SUDO=false
run() { if $NEED_SUDO; then sudo "$@"; else "$@"; fi; }

for dir in "${TARGETS[@]}"; do
    dest="$dir/Snappy.app"
    if [ -w "$dir" ]; then
        NEED_SUDO=false
    else
        NEED_SUDO=true
        echo "$dir is not writable — using sudo (you may be prompted)."
    fi
    # Stage next to the destination (same filesystem → the final mv is atomic)
    # and swap only once the copy is verified: a failed ditto (disk full,
    # cancelled sudo prompt) must never leave the user without an app.
    staged="$dest.new"
    run rm -rf "$staged"
    # ditto (not cp) so the code signature and extended attributes survive.
    if ! run ditto "$SRC" "$staged" || ! ./scripts/verify-bundle.sh "$staged"; then
        run rm -rf "$staged"
        echo "ERROR: copying to $staged failed — the existing $dest was left untouched." >&2
        exit 1
    fi
    run rm -rf "$dest"
    run mv "$staged" "$dest"
    run touch "$dest"   # nudge Finder's icon cache
    echo "Installed $dest"
done

# --- clean up the staged build --------------------------------------------
rm -rf "$SRC"
echo "Removed $SRC (staging copy)"

# --- relaunch --------------------------------------------------------------
if $RELAUNCH; then
    open "${TARGETS[0]}/Snappy.app"
    echo "Relaunched ${TARGETS[0]}/Snappy.app"
else
    echo "Not previously running — launch with: open ${TARGETS[0]}/Snappy.app"
fi
