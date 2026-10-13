#!/bin/zsh
# Builds the disk image: Keel.app, an Applications link and a "drag Keel into Applications" window.
#   scripts/make-dmg.sh <Keel.app> <output.dmg> "<volume name>"
# The window layout is set through Finder. If Finder automation isn't allowed, the image is still
# built, with Finder's default layout.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
[ $# -eq 3 ] || keel_die "usage: scripts/make-dmg.sh <Keel.app> <output.dmg> <volume name>"
APP="$1"; DMG="$2"; VOL="$3"
[ -d "$APP" ] || keel_die "$APP not found"
[ -f Resources/dmg-background.tiff ] || keel_die "Resources/dmg-background.tiff missing (scripts/make-dmg-background.py)"

STAGE="$(mktemp -d -t keel-dmg)"
RW="$STAGE.rw.dmg"
MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach -quiet -force "$MNT" 2>/dev/null; rm -rf "$STAGE" "$RW"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/Keel.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[ -d "$MNT" ] || keel_die "could not mount $RW"

# Window: 600x380 content (plus the title bar), icons centered on the background's arrow.
if ! osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
  tell disk "$(basename "$MNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 528}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Keel.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    -- Keep hidden items out of view for people who show hidden files in Finder.
    repeat with n in {".background", ".fseventsd", ".DS_Store", ".Trashes"}
      try
        set position of item n of container window to {800, 600}
      end try
    end repeat
    update without registering applications
    delay 1
    close
    open
    delay 2
    close
  end tell
end tell
EOF
then
  keel_warn "could not lay out the disk image window (allow Terminal to control Finder); using the default layout"
fi
chflags hidden "$MNT/.background" 2>/dev/null || true
# Finder writes the layout to .DS_Store asynchronously.
for _ in {1..20}; do [ -f "$MNT/.DS_Store" ] && break; sleep 0.5; done
[ -f "$MNT/.DS_Store" ] || keel_warn "Finder did not save the window layout"
sync
hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -quiet -force "$MNT"; }
MNT=""
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
print "Built $DMG"
