#!/bin/zsh
# Builds, signs, notarizes and packages a Keel release.
#
#   scripts/release.sh <version> [--dry-run] [--preflight] [--publish]
#
#   <version>     X.Y.Z, becomes CFBundleShortVersionString and the tag vX.Y.Z.
#   --dry-run     Builds and assembles an ad-hoc bundle, makes an unsigned DMG, checksums and notes,
#                 and prints (without running) every signing, notarization, stapling, Gatekeeper and
#                 publishing command. Uses no private key and contacts no Apple service.
#   --preflight   Only checks tools, signing identity, notary profile and the git tree, then exits.
#   --publish     After a successful release: creates and pushes tag vX.Y.Z and runs
#                 `gh release create`. Off by default; nothing is uploaded without it.
#
# Environment:
#   KEEL_SIGN_IDENTITY    Developer ID identity (name or SHA-1). Default: auto-detected from the keychain.
#   KEEL_TEAM_ID          Expected team (default KLB57Y57PP).
#   KEEL_NOTARY_PROFILE   notarytool keychain profile (default keel-notary). One-time setup:
#                           xcrun notarytool store-credentials keel-notary --apple-id <id> --team-id KLB57Y57PP
#   KEEL_BUILD            CFBundleVersion (default: commit count of HEAD).
#   KEEL_ALLOW_DIRTY=1    Allow a release from a working tree with uncommitted changes.
#
# Output: dist.noindex/release/<version>/ (dry run: <version>-dry-run/)
#   Keel-<version>.dmg, Keel-<version>.dmg.sha256, release-notes.md
set -euo pipefail
SELF="${0:A}"
cd "${SELF:h}/.."
source scripts/common.sh

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; exit 64; }

VERSION=""; DRY=0; PUBLISH=0; PREFLIGHT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --publish) PUBLISH=1 ;;
    --preflight) PREFLIGHT=1 ;;
    -h|--help) usage ;;
    -*) keel_die "unknown option $a (see --help)" ;;
    *) [ -z "$VERSION" ] || keel_die "version given twice"; VERSION="$a" ;;
  esac
done
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || keel_die "version must be X.Y.Z (got '$VERSION')"

PROFILE="${KEEL_NOTARY_PROFILE:-keel-notary}"
TEAM="${KEEL_TEAM_ID:-$KEEL_TEAM_DEFAULT}"
TAG="v$VERSION"
BUILD="${KEEL_BUILD:-$(keel_default_build)}"
APP="dist.noindex/Keel.app"
OUT="dist.noindex/release/$VERSION"; (( DRY )) && OUT="$OUT-dry-run"
DMG="$OUT/Keel-$VERSION.dmg"
NOTES="$OUT/release-notes.md"
ENT="Resources/Keel.entitlements"

# ---- output helpers -----------------------------------------------------------------------------
STEP=0
step() { STEP=$((STEP + 1)); print -P "\n%B==> $STEP. $*%b"; }
show() { print -r -- "    \$ ${(j: :)${(q-)@}}"; }
# Local, harmless steps: always executed (also in --dry-run).
do_() { show "$@"; "$@"; }
# Signing / notarization / Gatekeeper / publishing: printed only in --dry-run.
run() { if (( DRY )); then print -r -- "    [dry-run] ${(j: :)${(q-)@}}"; else show "$@"; "$@"; fi; }

notary_help() {
  cat >&2 <<EOF

The notarytool keychain profile "$PROFILE" was not found or could not authenticate.
Create it once (you will be asked for an app-specific password from https://account.apple.com
> Sign-In and Security > App-Specific Passwords):

    xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID email> --team-id $TEAM

Then run this script again. Use KEEL_NOTARY_PROFILE=<name> to use a different profile.
EOF
  exit 1
}

# notarize <file>: submits, waits, and fails with Apple's log unless the status is Accepted.
notarize() {
  local file="$1" json id st
  if (( DRY )); then
    print -r -- "    [dry-run] xcrun notarytool submit ${(q-)file} --keychain-profile ${(q-)PROFILE} --wait --output-format json"
    print -r -- "    [dry-run]   (fails with: xcrun notarytool log <id> --keychain-profile $PROFILE, unless status is Accepted)"
    return 0
  fi
  show xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json
  json="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json)" || {
    print -u2 -r -- "$json"; keel_die "notarytool submit failed for $file"; }
  id="$(print -r -- "$json" | plutil -extract id raw -o - - 2>/dev/null || true)"
  st="$(print -r -- "$json" | plutil -extract status raw -o - - 2>/dev/null || true)"
  print "    submission $id: $st"
  if [ "$st" != Accepted ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    keel_die "notarization of $file ended with status '${st:-unknown}'"
  fi
}

# ---- 1. preflight -------------------------------------------------------------------------------
step "Preflight ($TAG, build $BUILD$( (( DRY )) && print ', dry run'))"
[ "$(uname -m)" = arm64 ] || keel_warn "building on $(uname -m); the release is arm64 only"
for t in swift codesign hdiutil spctl shasum ditto git plutil; do command -v "$t" >/dev/null || keel_die "$t not found"; done
xcrun --find notarytool >/dev/null 2>&1 || keel_die "xcrun notarytool not found (install Xcode or the Command Line Tools)"
xcrun --find stapler >/dev/null 2>&1 || keel_die "xcrun stapler not found (install Xcode or the Command Line Tools)"
print "    tools: ok"

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  if (( DRY )) || [ "${KEEL_ALLOW_DIRTY:-0}" = 1 ]; then keel_warn "working tree has uncommitted changes"
  else keel_die "working tree has uncommitted changes; commit them or set KEEL_ALLOW_DIRTY=1"; fi
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ] || keel_warn "tag $TAG exists and points at a different commit"
fi
print "    git: $(git rev-parse --short HEAD) on $(git branch --show-current 2>/dev/null || print detached)"

ID="${KEEL_SIGN_IDENTITY:-}"
[ "$ID" = auto ] && ID=""
[ -z "$ID" ] && ID="$(keel_detect_identity)"
if [ -z "$ID" ] || [ "$ID" = "-" ]; then
  if (( DRY )); then ID="Developer ID Application: <name> ($TEAM)"; keel_warn "no Developer ID identity found; using a placeholder for the dry run"
  else keel_die "no 'Developer ID Application' identity in the keychain. Install it from Xcode > Settings > Accounts or set KEEL_SIGN_IDENTITY."; fi
fi
ID_NAME="$(keel_identity_name "$ID")"; ID_NAME="${ID_NAME:-$ID}"
ID_TEAM="$(keel_identity_team "$ID")"
print "    identity: $ID_NAME"
[ -z "$ID_TEAM" ] || [ "$ID_TEAM" = "$TEAM" ] || keel_die "identity team $ID_TEAM does not match KEEL_TEAM_ID $TEAM"

if (( DRY )); then
  print -r -- "    [dry-run] xcrun notarytool history --keychain-profile ${(q-)PROFILE}   (checks the notary profile)"
else
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || notary_help
  print "    notary profile: $PROFILE ok"
fi
if (( PUBLISH )); then
  command -v gh >/dev/null || keel_die "--publish needs the GitHub CLI (brew install gh)"
  (( DRY )) || gh auth status >/dev/null 2>&1 || keel_die "--publish needs 'gh auth login' first"
fi
(( PREFLIGHT )) && { print "\nPreflight passed."; exit 0; }

# ---- 2. build and assemble ----------------------------------------------------------------------
step "Build and assemble $APP (arm64, release)"
do_ env KEEL_VERSION="$VERSION" KEEL_BUILD="$BUILD" KEEL_SIGN_IDENTITY=- scripts/build-app.sh release
do_ scripts/verify-bundle.sh "$APP" --version "$VERSION"

# ---- 3. sign ------------------------------------------------------------------------------------
step "Sign with Developer ID (helper first, then app; hardened runtime, secure timestamp)"
run xattr -cr "$APP"
run codesign --force --options runtime --timestamp --sign "$ID" --identifier "$KEEL_HELPER_ID" "$APP/Contents/MacOS/KeelHelper"
run codesign --force --options runtime --timestamp --sign "$ID" --entitlements "$ENT" "$APP"
run codesign --verify --deep --strict --verbose=2 "$APP"
run scripts/verify-bundle.sh "$APP" --distribution --version "$VERSION"

# ---- 4. notarize and staple the app -------------------------------------------------------------
step "Notarize and staple the app"
mkdir -p "$OUT"
ZIP="$OUT/Keel-$VERSION-notarize.zip"
run ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
notarize "$ZIP"
run rm -f "$ZIP"
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl --assess --type execute -vv "$APP"

# ---- 5. DMG -------------------------------------------------------------------------------------
step "Build the DMG (Keel.app + Applications link)"
STAGE="$(mktemp -d -t keel-dmg)"
do_ ditto "$APP" "$STAGE/Keel.app"
do_ ln -s /Applications "$STAGE/Applications"
do_ rm -f "$DMG"
do_ hdiutil create -quiet -volname "Keel $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGE"
do_ hdiutil verify -quiet "$DMG"

step "Sign, notarize and staple the DMG"
run codesign --force --timestamp --sign "$ID" "$DMG"
run codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG"
run xcrun stapler staple "$DMG"
run xcrun stapler validate "$DMG"
run spctl --assess --type open --context context:primary-signature -vv "$DMG"

# ---- 6. checksum and notes ----------------------------------------------------------------------
step "Checksum and release notes"
( cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256" )
SHA="$(cut -d' ' -f1 "$DMG.sha256")"
print "    $SHA  ${DMG:t}"

PREV="$(git tag --list 'v[0-9]*' --sort=-v:refname --merged HEAD | grep -vx "$TAG" | head -1 || true)"
RANGE="${PREV:+$PREV..}HEAD"
CHANGES="$(git log --no-merges --pretty='- %s' "$RANGE" | grep -v -i -E '^- (wip|fixup!|squash!)' || true)"
[ -z "$CHANGES" ] && CHANGES="- No changes recorded."
REPO="$(/usr/libexec/PlistBuddy -c 'Print :KeelUpdateRepo' Resources/Info.plist 2>/dev/null || print mohdmahmodi/keel)"
cat > "$NOTES" <<EOF
## Keel $VERSION

Requires an Apple Silicon Mac with macOS 15 or later. Download **Keel-$VERSION.dmg**, open it and drag Keel to Applications.

### Changes${PREV:+ since $PREV}

$CHANGES

### Verify the download

\`\`\`
shasum -a 256 ~/Downloads/Keel-$VERSION.dmg
# expected: $SHA
spctl --assess --type open --context context:primary-signature -vv ~/Downloads/Keel-$VERSION.dmg
# expected: accepted, source=Notarized Developer ID, origin=Developer ID Application: … ($TEAM)
\`\`\`
EOF
[ -n "$PREV" ] && print "\nFull comparison: https://github.com/$REPO/compare/$PREV...$TAG" >> "$NOTES"
print "    wrote $NOTES"

# ---- 7. publish (opt-in) ------------------------------------------------------------------------
GH_CMD=(gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO" --title "Keel $VERSION" --notes-file "$NOTES" --verify-tag)
if (( PUBLISH )); then
  step "Publish $TAG to GitHub"
  if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then run git tag -a "$TAG" -m "Keel $VERSION"; fi
  run git push origin "$TAG"
  run "${GH_CMD[@]}"
else
  step "Not published (pass --publish to upload)"
  print "    To publish this build by hand:"
  show git tag -a "$TAG" -m "Keel $VERSION"
  show git push origin "$TAG"
  show "${GH_CMD[@]}"
fi

print -P "\n%BDone.%b $( (( DRY )) && print 'Dry run: nothing was signed, notarized or uploaded. ')Artifacts in $OUT/"
ls -l "$OUT"
