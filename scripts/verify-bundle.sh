#!/bin/zsh
# Checks that a built Keel.app has the layout SMAppService and Gatekeeper expect.
#   scripts/verify-bundle.sh [path/to/Keel.app] [--distribution] [--version X.Y.Z]
# --distribution additionally requires a Developer ID signature with hardened runtime, a secure
# timestamp and the expected team on both the app and the helper. Read-only: signs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

APP="dist.noindex/Keel.app"; DIST=0; WANT_VERSION=""
while (( $# )); do
  case "$1" in
    --distribution) DIST=1 ;;
    --version) shift; WANT_VERSION="${1:-}" ;;
    -*) keel_die "unknown option $1" ;;
    *) APP="$1" ;;
  esac
  shift
done
[ -d "$APP" ] || keel_die "$APP does not exist (run scripts/build-app.sh first)"

FAILS=0
ok()   { print -r -- "  ok    $*"; }
bad()  { print -r -- "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
pval() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

INFO="$APP/Contents/Info.plist"
DAEMON="$APP/Contents/Library/LaunchDaemons/$KEEL_HELPER_PLIST"
MAIN="$APP/Contents/MacOS/Keel"
HELPER="$APP/Contents/MacOS/KeelHelper"

print "Bundle: $APP"
check "Info.plist is valid"                     plutil -lint -s "$INFO"
[ "$(pval "$INFO" CFBundleIdentifier)" = "$KEEL_APP_ID" ] && ok "CFBundleIdentifier $KEEL_APP_ID" || bad "CFBundleIdentifier is '$(pval "$INFO" CFBundleIdentifier)'"
[ "$(pval "$INFO" CFBundleExecutable)" = Keel ] && ok "CFBundleExecutable Keel" || bad "CFBundleExecutable"
[ "$(pval "$INFO" LSMinimumSystemVersion)" = 15.0 ] && ok "LSMinimumSystemVersion 15.0" || bad "LSMinimumSystemVersion is '$(pval "$INFO" LSMinimumSystemVersion)'"
[ "$(pval "$INFO" 'LSArchitecturePriority:0')" = arm64 ] && ok "LSArchitecturePriority arm64" || bad "LSArchitecturePriority"
SV="$(pval "$INFO" CFBundleShortVersionString)"; BV="$(pval "$INFO" CFBundleVersion)"
[[ "$SV" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] && ok "CFBundleShortVersionString $SV" || bad "CFBundleShortVersionString '$SV'"
[[ "$BV" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] && ok "CFBundleVersion $BV" || bad "CFBundleVersion '$BV'"
[ -z "$WANT_VERSION" ] || { [ "$SV" = "$WANT_VERSION" ] && ok "version matches $WANT_VERSION" || bad "version $SV != $WANT_VERSION"; }
[ -n "$(pval "$INFO" NSAppleEventsUsageDescription)" ] && ok "NSAppleEventsUsageDescription" || bad "NSAppleEventsUsageDescription missing"
[ -n "$(pval "$INFO" NSHumanReadableCopyright)" ] && ok "NSHumanReadableCopyright" || bad "NSHumanReadableCopyright missing"
[[ "$(pval "$INFO" KeelUpdateRepo)" =~ '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' ]] && ok "KeelUpdateRepo $(pval "$INFO" KeelUpdateRepo)" || bad "KeelUpdateRepo missing or malformed"
check "Resources/Keel.icns present"            test -f "$APP/Contents/Resources/Keel.icns"

print "Helper daemon (SMAppService.daemon(plistName: \"$KEEL_HELPER_PLIST\"))"
check "plist at Contents/Library/LaunchDaemons" test -f "$DAEMON"
check "daemon plist is valid"                   plutil -lint -s "$DAEMON"
[ "$(pval "$DAEMON" Label)" = "$KEEL_HELPER_ID" ] && ok "Label $KEEL_HELPER_ID" || bad "Label is '$(pval "$DAEMON" Label)'"
BP="$(pval "$DAEMON" BundleProgram)"
[ "$BP" = Contents/MacOS/KeelHelper ] && ok "BundleProgram $BP" || bad "BundleProgram is '$BP'"
check "BundleProgram exists and is executable"  test -x "$APP/$BP"
[ "$(pval "$DAEMON" "MachServices:$KEEL_HELPER_ID")" = true ] && ok "MachServices $KEEL_HELPER_ID" || bad "MachServices entry missing"
[ "$(pval "$DAEMON" 'AssociatedBundleIdentifiers:0')" = "$KEEL_APP_ID" ] && ok "AssociatedBundleIdentifiers $KEEL_APP_ID" || bad "AssociatedBundleIdentifiers"

print "Binaries"
for exe in "$MAIN" "$HELPER"; do
  n="${exe:t}"
  [ "$(lipo -archs "$exe" 2>/dev/null)" = arm64 ] && ok "$n is arm64 only" || bad "$n architectures: $(lipo -archs "$exe" 2>/dev/null)"
  minos="$(otool -l "$exe" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
  [ "$minos" = 15.0 ] && ok "$n minos $minos" || bad "$n minos '$minos' (expected 15.0)"
done

print "Code signature"
sig() { codesign -dvv "$1" 2>&1; }
HS="$(sig "$HELPER")"; AS="$(sig "$APP")"
print -r -- "$HS" | grep -qx "Identifier=$KEEL_HELPER_ID" && ok "helper identifier $KEEL_HELPER_ID" || bad "helper identifier: $(print -r -- "$HS" | sed -n 's/^Identifier=//p')"
print -r -- "$AS" | grep -qx "Identifier=$KEEL_APP_ID" && ok "app identifier $KEEL_APP_ID" || bad "app identifier: $(print -r -- "$AS" | sed -n 's/^Identifier=//p')"
check "codesign --verify --deep --strict"       codesign --verify --deep --strict "$APP"
if (( DIST )); then
  TEAM="${KEEL_TEAM_ID:-$KEEL_TEAM_DEFAULT}"
  for pair in "helper:$HS" "app:$AS"; do
    n="${pair%%:*}"; s="${pair#*:}"
    print -r -- "$s" | grep -q '^Authority=Developer ID Application:' && ok "$n Developer ID" || bad "$n is not signed with Developer ID"
    print -r -- "$s" | grep -qx "TeamIdentifier=$TEAM" && ok "$n team $TEAM" || bad "$n team: $(print -r -- "$s" | sed -n 's/^TeamIdentifier=//p')"
    print -r -- "$s" | grep -q '^CodeDirectory.*flags=.*runtime' && ok "$n hardened runtime" || bad "$n has no hardened runtime"
    print -r -- "$s" | grep -q '^Timestamp=' && ok "$n secure timestamp" || bad "$n has no secure timestamp"
  done
  ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  print -r -- "$ENTS" | grep -q 'get-task-allow' && bad "app has get-task-allow (notarization rejects it)" || ok "no get-task-allow"
  print -r -- "$ENTS" | grep -q 'com.apple.security.automation.apple-events' && ok "apple-events entitlement" || bad "apple-events entitlement missing"
fi

if (( FAILS )); then print "\n$FAILS check(s) failed"; exit 1; fi
print "\nAll checks passed"
