#!/bin/zsh
# Builds Keel.app (app + root helper) from the Swift package into dist.noindex/Keel.app.
#   scripts/build-app.sh [debug|release]
#
# Environment (all optional):
#   KEEL_VERSION        CFBundleShortVersionString. Default: latest vX.Y.Z tag reachable from HEAD,
#                       else the value in Resources/Info.plist.
#   KEEL_BUILD          CFBundleVersion. Default: number of commits reachable from HEAD.
#   KEEL_SIGN_IDENTITY  Unset or "-": ad-hoc signature (fine for this Mac; the helper daemon is
#                       unavailable and privileged batches use the administrator prompt instead).
#                       "auto": the first "Developer ID Application" identity in the keychain.
#                       Otherwise a name or SHA-1: hardened runtime + secure timestamp.
#                       Distributable builds go through scripts/release.sh, which also notarizes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) print -u2 "usage: scripts/build-app.sh [debug|release]"; exit 64 ;; esac

# 1. Compile (arm64 only: Keel targets Apple Silicon).
LOG="$(mktemp -t keel-build)"
print "Compiling ($CONFIG, arm64)…"
if ! swift build -c "$CONFIG" --arch arm64 >"$LOG" 2>&1; then
  grep -E 'error:' "$LOG" | sort -u | head -40 || tail -40 "$LOG"
  keel_die "swift build failed (full log: $LOG)"
fi
grep -E 'Build complete|warning: unre' "$LOG" || true
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
for exe in Keel KeelHelper; do
  [ -x "$BIN/$exe" ] || keel_die "$BIN/$exe is missing"
  archs="$(lipo -archs "$BIN/$exe")"
  [ "$archs" = arm64 ] || keel_die "$exe is built for '$archs', expected arm64"
done

# 2. Assemble the bundle. The daemon plist must sit at Contents/Library/LaunchDaemons for
#    SMAppService.daemon(plistName:); its BundleProgram is relative to the bundle root.
APP="dist.noindex/Keel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Keel" "$APP/Contents/MacOS/Keel"
cp "$BIN/KeelHelper" "$APP/Contents/MacOS/KeelHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "Resources/$KEEL_HELPER_PLIST" "$APP/Contents/Library/LaunchDaemons/$KEEL_HELPER_PLIST"
[ -f Resources/Keel.icns ] && cp Resources/Keel.icns "$APP/Contents/Resources/Keel.icns"
print -n 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Version strings (only the copy in the bundle is edited; Resources/Info.plist stays as is).
PB=/usr/libexec/PlistBuddy
VERSION="${KEEL_VERSION:-$(keel_latest_tag_version)}"
[ -z "$VERSION" ] && VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="${KEEL_BUILD:-$(keel_default_build)}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || keel_die "version '$VERSION' must look like 1.2.3"
[[ "$BUILD" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || keel_die "build number '$BUILD' must be numeric"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/$KEEL_HELPER_PLIST"

# 4. Sign: helper first, then the app.
ID="${KEEL_SIGN_IDENTITY:--}"
[ "$ID" = auto ] && ID="$(keel_detect_identity)"
[ -z "$ID" ] && keel_die "KEEL_SIGN_IDENTITY=auto but no 'Developer ID Application' identity is in the keychain"
if [ "$ID" = "-" ]; then
  xattr -cr "$APP"
  codesign --force --sign - --identifier "$KEEL_HELPER_ID" "$APP/Contents/MacOS/KeelHelper"
  codesign --force --sign - "$APP"
  print "Built $APP $VERSION ($BUILD), $CONFIG, ad-hoc signed"
else
  keel_sign_bundle "$APP" "$ID" Resources/Keel.entitlements
  codesign --verify --deep --strict --verbose=2 "$APP"
  NAME="$(keel_identity_name "$ID")"
  print "Built $APP $VERSION ($BUILD), $CONFIG, signed: ${NAME:-$ID}"
fi
