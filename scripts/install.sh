#!/bin/bash
# Builds Snappy.app and installs it over the existing installation.
#
# Install location is DISCOVERED, never guessed: whichever of ~/Applications
# and /Applications already holds this Snappy.app (bundle id com.tefa.snappy —
# another app that is merely called Snappy.app is left alone) is updated in
# place (both, if both do — a stale second copy is worse than a redundant
# update). With no installation found, /Applications is the default.
#
# Snappy is a menu bar app: if it runs from a bundle being replaced (this user's
# process, matched by its executable path), it is sent one SIGTERM and
# reopened afterwards. If it doesn't exit within 5 s, or the process list
# can't be read, nothing is installed and you're asked to quit it yourself.
# A symlinked Snappy.app, or a Snappy.app.old left by an earlier failed run,
# stops the install.
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

BUNDLE_ID=com.tefa.snappy

# Escalates only when the destination directory is not writable. (Not an array
# of prefix words: bash 3.2 + `set -u` chokes on expanding an empty array.)
NEED_SUDO=false
run() { if $NEED_SUDO; then sudo "$@"; else "$@"; fi; }

# True when the bundle at $1 is this app, judged by its bundle identifier.
is_snappy() {
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]
}

# The helpers below check every step themselves: they run under `if !` / `||`,
# where bash ignores `set -e`.

# Is PID $1 one of this user's processes running the Snappy executable of one
# of the bundles $2…? 0 = yes, 1 = no, 2 = `ps` can't tell (an error, or the
# process just exited). Paths are compared exactly as `ps` reports them;
# symlinks are not resolved, so a bundle reached through a symlinked folder
# is not matched.
is_target_pid() {
    local pid=$1 uid path app
    shift
    uid=$(ps -o uid= -p "$pid") || return 2
    path=$(ps -o comm= -p "$pid") || return 2
    [ "${uid// /}" = "$(id -u)" ] || return 1
    for app in "$@"; do
        if [ "$path" = "$app/Contents/MacOS/Snappy" ]; then return 0; fi
    done
    return 1
}

# This user's PIDs running the Snappy executable of one of the bundles given,
# one per line, each once. Returns 2 when the process list can't be read —
# that means "can't tell", never "not running".
snappy_pids() {
    local list pid status rc=0
    list=$(pgrep -x -U "$(id -u)" Snappy) || rc=$?
    [ "$rc" -le 1 ] || return 2           # pgrep: 1 = no match, more = error
    for pid in $list; do
        status=0
        is_target_pid "$pid" "$@" || status=$?
        case $status in
            0) echo "$pid" ;;
            1) ;;
            *) return 2 ;;
        esac
    done
}

# Ends the verified PIDs in $1 (from snappy_pids) running from the bundles
# $2…: each PID is re-checked right before it gets one plain SIGTERM — a PID
# that fails the re-check gets nothing — then waits up to 5 s. Nothing gets a
# second or stronger signal. 0 = no Snappy runs from those bundles any more,
# 1 = one still does, 2 = the process list can't be read.
stop_pids() {
    local pids=$1 pid left
    shift
    for pid in $pids; do
        if is_target_pid "$pid" "$@"; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    for _ in $(seq 20); do
        left=$(snappy_pids "$@") || return 2
        if [ -z "$left" ]; then return 0; fi
        sleep 0.25
    done
    return 1
}

# Puts the verified staged bundle $1 at $2, keeping the old app at $2.old
# until the new one is in place and moving exactly that one back if the swap
# fails. Refuses (status 3, nothing touched) when $2 is a symlink or $2.old
# exists: an earlier failed run may have left the only good copy there, and it
# is never deleted or overwritten here.
swap_in() {
    local staged=$1 dest=$2 old="$2.old" moved=false
    if [ -e "$old" ] || [ -L "$old" ]; then
        echo "ERROR: $old exists — it may be the last good copy from an earlier run." >&2
        echo "       Inspect it, move it back to $dest or delete it, then run install.sh again." >&2
        return 3
    fi
    if [ -L "$dest" ]; then
        echo "ERROR: $dest is a symlink — install.sh only replaces a real Snappy.app folder." >&2
        return 3
    fi
    if [ -e "$dest" ]; then
        run mv "$dest" "$old" || return 1
        moved=true
    fi
    if ! run mv "$staged" "$dest"; then
        if $moved; then
            if [ -e "$dest" ] || [ -L "$dest" ] || ! run mv "$old" "$dest"; then
                echo "ERROR: could not move the old app back — it is at $old." >&2
            fi
        fi
        return 1
    fi
    if $moved && ! run rm -rf "$old"; then
        echo "WARNING: installed, but the old copy at $old could not be removed." >&2
    fi
    return 0
}

# Test seam: `SNAPPY_INSTALL_FUNCTIONS_ONLY=1 source scripts/install.sh` only
# defines the helpers above — nothing is built, quit or installed.
if [ "${SNAPPY_INSTALL_FUNCTIONS_ONLY:-}" = 1 ]; then return 0; fi

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
    if [ -L "$dir/Snappy.app" ]; then
        echo "ERROR: $dir/Snappy.app is a symlink — install.sh only replaces a real Snappy.app folder." >&2
        exit 1
    fi
    [ -d "$dir/Snappy.app" ] || continue
    if is_snappy "$dir/Snappy.app"; then
        TARGETS+=("$dir")
    else
        echo "WARNING: $dir/Snappy.app is another app (not $BUNDLE_ID) — leaving it alone." >&2
    fi
done

case ${#TARGETS[@]} in
    0) if [ -e /Applications/Snappy.app ]; then
           echo "ERROR: /Applications/Snappy.app is another app — move it away or install by hand." >&2
           exit 1
       fi
       TARGETS=(/Applications)
       echo "No existing installation — installing to /Applications." ;;
    1) echo "Existing installation found in ${TARGETS[0]} — updating it there." ;;
    *) echo "WARNING: Snappy.app exists in BOTH ${TARGETS[*]} — updating both." >&2
       echo "         Remove one to avoid launching a stale copy." >&2 ;;
esac
# Leftovers of an earlier failed run are never cleaned up automatically.
for dir in "${TARGETS[@]}"; do
    if [ -e "$dir/Snappy.app.old" ] || [ -L "$dir/Snappy.app.old" ]; then
        echo "ERROR: $dir/Snappy.app.old exists — it may be the last good copy from an earlier run." >&2
        echo "       Inspect it, move it back to $dir/Snappy.app or delete it, then run install.sh again." >&2
        exit 1
    fi
done

# --- quit a running instance ----------------------------------------------
APPS=()
for dir in "${TARGETS[@]}"; do APPS+=("$dir/Snappy.app"); done
RELAUNCH=false
if ! running=$(snappy_pids "${APPS[@]}"); then
    echo "ERROR: can't read the process list to tell whether Snappy is running." >&2
    echo "       Quit Snappy yourself, then run install.sh again." >&2
    exit 1
fi
if [ -n "$running" ]; then
    RELAUNCH=true
    # A plain SIGTERM ends Snappy without its quit handling (an unsaved
    # recording is lost) — quit it yourself first if that matters.
    echo "Stopping running Snappy (PID $(echo $running))…"
    if ! stop_pids "$running" "${APPS[@]}"; then
        echo "ERROR: Snappy is still running, or its state can't be read." >&2
        echo "       Quit Snappy yourself, then run install.sh again." >&2
        exit 1
    fi
fi

# --- install ---------------------------------------------------------------
for dir in "${TARGETS[@]}"; do
    dest="$dir/Snappy.app"
    if [ -w "$dir" ]; then
        NEED_SUDO=false
    else
        NEED_SUDO=true
        echo "$dir is not writable — using sudo (you may be prompted)."
    fi
    # Stage next to the destination (same filesystem, so each mv is a rename)
    # and swap only once the copy is verified: a failed ditto (disk full,
    # cancelled sudo prompt) leaves the existing app untouched, and swap_in
    # keeps the old app until the new one is in place.
    staged="$dest.new"
    run rm -rf "$staged"
    # ditto (not cp) so the code signature and extended attributes survive.
    if ! run ditto "$SRC" "$staged" || ! ./scripts/verify-bundle.sh "$staged"; then
        run rm -rf "$staged"
        echo "ERROR: copying to $staged failed — the existing $dest was left untouched." >&2
        exit 1
    fi
    if ! swap_in "$staged" "$dest"; then
        echo "ERROR: $dest was not updated — check $dest and $dest.old." >&2
        exit 1
    fi
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
