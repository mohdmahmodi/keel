#!/bin/zsh
# Shared helpers for build-app.sh, release.sh and verify-bundle.sh. Source it; do not run it.

KEEL_APP_ID="com.mohdmahmodi.keel"
KEEL_HELPER_ID="com.mohdmahmodi.keel.helper"
KEEL_HELPER_PLIST="com.mohdmahmodi.keel.helper.plist"
KEEL_TEAM_DEFAULT="KLB57Y57PP"

keel_die()  { print -u2 -r -- "error: $*"; exit 1; }
keel_warn() { print -u2 -r -- "warning: $*"; }

# Prints the SHA-1 of the first valid "Developer ID Application" identity in the keychain,
# preferring one for $KEEL_TEAM_ID (default KLB57Y57PP). Prints nothing if there is none.
# Only reads public certificate data; never touches the private key.
keel_detect_identity() {
  local team="${KEEL_TEAM_ID:-$KEEL_TEAM_DEFAULT}" ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' || true)"
  [ -z "$ids" ] && return 0
  print -r -- "$ids" | grep -F "($team)\"" | awk '{print $2; exit}' | grep . \
    || print -r -- "$ids" | awk '{print $2; exit}'
}

# Human-readable name for an identity given as SHA-1 or name.
keel_identity_name() {
  local id="$1"
  security find-identity -v -p codesigning 2>/dev/null | grep -F "$id" | sed -n 's/.*"\(.*\)"/\1/p' | head -1
}

# Team ID from "… (TEAMID)" or from the keychain entry for a SHA-1.
keel_identity_team() {
  local name; name="$(keel_identity_name "$1")"; [ -z "$name" ] && name="$1"
  print -r -- "$name" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p'
}

# Default build number: commits reachable from HEAD (monotonic on the main branch).
keel_default_build() { git rev-list --count HEAD 2>/dev/null || print 1; }

# Latest vX.Y.Z tag reachable from HEAD, without the "v". Empty if none.
keel_latest_tag_version() {
  git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null | sed 's/^v//' || true
}

# Signs helper first, then the app (no --deep: every nested Mach-O is signed explicitly).
#   keel_sign_bundle <Keel.app> <identity> <entitlements>
keel_sign_bundle() {
  local app="$1" id="$2" ent="$3"
  xattr -cr "$app"
  codesign --force --options runtime --timestamp --sign "$id" --identifier "$KEEL_HELPER_ID" "$app/Contents/MacOS/KeelHelper"
  codesign --force --options runtime --timestamp --sign "$id" --entitlements "$ent" "$app"
}
