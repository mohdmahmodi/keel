#!/bin/zsh
# Tests "Move to Applications" without touching /Applications.
# Gatekeeper won't run an unnotarized build that carries a download flag, so the translocated case
# (a quarantined app opened from a downloaded disk image) is only covered by testing a notarized release.
# Builds the release app, packs it into a disk image like scripts/release.sh does, opens Keel from the
# mounted image and from a plain folder, and checks that it was copied, the image was ejected, and the
# leftovers went to the Trash. The test copies land in a temporary folder that is removed afterwards.
#   scripts/test-install.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

WORK="$(mktemp -d -t keel-install-test)"
APPS="$WORK/Applications"; mkdir -p "$APPS" "$WORK/stage" "$WORK/Downloads"
fail=0
ok()  { print -P "%F{green}✓%f $1"; }
bad() { print -P "%F{red}✗ $1%f"; fail=1; }
MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach -quiet "$MNT" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

wait_for_exit() { # pid
  for _ in {1..100}; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  kill "$1" 2>/dev/null; return 1
}

print "Building the release app…"
scripts/build-app.sh release >/dev/null || keel_die "build failed"
ditto dist.noindex/Keel.app "$WORK/stage/Keel.app"
ln -s /Applications "$WORK/stage/Applications"
DMG="$WORK/Downloads/Keel-test.dmg"
hdiutil create -quiet -volname "Keel test" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG" || keel_die "hdiutil create failed"

# 1. From the disk image
MNT="$(hdiutil attach -nobrowse "$DMG" 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[ -d "$MNT/Keel.app" ] || keel_die "attach failed"
ok "disk image mounted at $MNT"
KEEL_MOVE_TEST_DIR="$APPS" "$MNT/Keel.app/Contents/MacOS/Keel" >/dev/null 2>"$WORK/err1" &
wait_for_exit $! || bad "Keel did not quit after moving (disk image)"
sleep 2
[ -d "$APPS/Keel.app" ] && ok "copied from the disk image" || bad "not copied from the disk image: $(cat "$WORK/err1")"
codesign --verify --deep --strict "$APPS/Keel.app" 2>/dev/null && ok "copy passes codesign --verify" || bad "copy fails codesign --verify"
hdiutil info | grep -q "$DMG" && bad "disk image still attached" || ok "disk image ejected"
[ -e "$DMG" ] && bad "disk image not moved to the Trash" || ok "disk image moved to the Trash"

# 2. From a folder, replacing the copy made above
ditto dist.noindex/Keel.app "$WORK/Downloads/Keel.app"
before="$(stat -f %i "$APPS/Keel.app")"
sleep 1
KEEL_MOVE_TEST_DIR="$APPS" "$WORK/Downloads/Keel.app/Contents/MacOS/Keel" >/dev/null 2>"$WORK/err2" &
wait_for_exit $! || bad "Keel did not quit after moving (folder)"
sleep 1
[ -d "$APPS/Keel.app" ] && [ "$(stat -f %i "$APPS/Keel.app")" != "$before" ] && ok "replaced the existing copy" || bad "existing copy not replaced: $(cat "$WORK/err2")"
[ -e "$WORK/Downloads/Keel.app" ] && bad "original not moved to the Trash" || ok "original moved to the Trash"

# 3. Location checks
out="$("$APPS/Keel.app/Contents/MacOS/Keel" --move-check)"
print -r -- "$out" | grep -q "in Apps      false" && ok "--move-check reports the location" || bad "--move-check output: $out"
out="$(dist.noindex/Keel.app/Contents/MacOS/Keel --move-check)"
print -r -- "$out" | grep -q "would offer  false" && ok "development builds are not offered a move" || bad "dev build would be offered a move"

(( fail )) && { print -P "%F{red}install test failed%f"; exit 1; }
print -P "%F{green}install test passed%f (test copies were moved to the Trash: Keel-test.dmg, Keel.app)"
