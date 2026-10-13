# Releasing Keel

A release is a Developer ID–signed, notarized and stapled `Keel.app` inside a signed, notarized and stapled
`Keel-X.Y.Z.dmg`, published as a GitHub release with its SHA-256 and notes. `scripts/release.sh` does all of it.

## One-time setup

1. **Developer ID certificate.** The keychain must hold a *Developer ID Application* identity for team
   `KLB57Y57PP`. Check (public data only):

   ```bash
   security find-identity -v -p codesigning
   # … "Developer ID Application: Mohd Mahmodi (KLB57Y57PP)"
   ```

2. **Notary credentials.** Create an app-specific password at <https://account.apple.com> › Sign-In and Security ›
   App-Specific Passwords, then store it in a keychain profile named `keel-notary`:

   ```bash
   xcrun notarytool store-credentials keel-notary --apple-id <your Apple ID email> --team-id KLB57Y57PP
   ```

   notarytool asks for the app-specific password and validates it with Apple. Another profile name works too:
   set `KEEL_NOTARY_PROFILE=<name>` when releasing.

3. **GitHub CLI** (only for `--publish`): `brew install gh && gh auth login`.

4. **The repository must be public** for downloads and the in-app update check to work. The app reads
   `https://api.github.com/repos/<KeelUpdateRepo>/releases/latest` anonymously; for a private repository that
   returns 404 and the app shows "No releases". The repository is set by `KeelUpdateRepo` in `Resources/Info.plist`.

## Per release

```bash
git switch main && git pull                 # release from a clean, up-to-date main
scripts/release.sh 1.2.0 --dry-run          # rehearse: builds, makes an unsigned DMG, prints every signing step
scripts/release.sh 1.2.0 --preflight        # checks identity, notary profile, tools and git state only
scripts/release.sh 1.2.0                    # build, sign, notarize, staple, DMG, checksum, notes
scripts/release.sh 1.2.0 --publish          # same, then tag v1.2.0, push the tag and create the GitHub release
```

`--publish` is the only step that uploads anything. Without it, the script prints the `git tag`, `git push` and
`gh release create` commands so you can review the artifacts first and publish by hand.

What the script does, in order:

| Step | Commands | Dry run |
|---|---|---|
| Preflight | tool check, clean tree (`KEEL_ALLOW_DIRTY=1` to override), identity auto-detect (`KEEL_SIGN_IDENTITY` to override), `notarytool history --keychain-profile` | identity read, profile check printed |
| Build | `scripts/build-app.sh release` with `KEEL_VERSION`/`KEEL_BUILD`, then `scripts/verify-bundle.sh` | runs |
| Sign | `codesign --options runtime --timestamp` on `Contents/MacOS/KeelHelper` (identifier `com.mohdmahmodi.keel.helper`), then on the app with `Resources/Keel.entitlements`; `codesign --verify --deep --strict`; `verify-bundle.sh --distribution` | printed |
| Notarize app | `ditto -c -k` → `notarytool submit --wait`, fail with the notary log unless *Accepted*; `stapler staple`; `spctl --assess --type execute` | printed |
| DMG | Keel.app plus an `/Applications` link, `hdiutil create -format UDZO`, `hdiutil verify` | runs (unsigned) |
| Sign and notarize DMG | `codesign --timestamp`, `notarytool submit --wait`, `stapler staple`, `spctl --assess --type open --context context:primary-signature` | printed |
| Checksum and notes | `shasum -a 256`, `release-notes.md` from `git log` since the previous `v*` tag | runs |
| Publish (opt-in) | `git tag -a vX.Y.Z`, `git push origin vX.Y.Z`, `gh release create … --verify-tag` | printed |

Output goes to `dist.noindex/release/X.Y.Z/` (`X.Y.Z-dry-run/` for a dry run):
`Keel-X.Y.Z.dmg`, `Keel-X.Y.Z.dmg.sha256`, `release-notes.md`. Edit the notes before publishing if you like;
the first lines of the notes are what the app shows next to the Download button.

Version numbers: `X.Y.Z` becomes `CFBundleShortVersionString` and the tag `vX.Y.Z`. `CFBundleVersion` is the commit
count of `HEAD` (override with `KEEL_BUILD`). Only the copy inside the built bundle is stamped;
`Resources/Info.plist` is not edited. The update check compares the tag of the latest GitHub release with the
installed `CFBundleShortVersionString` using semantic-version rules, and ignores drafts and pre-releases.

### When something fails

- **"profile … was not found"**: run the `store-credentials` command above, or set `KEEL_NOTARY_PROFILE`.
- **Notarization status Invalid**: the script prints Apple's log. Typical causes are a missing hardened runtime or
  timestamp on one binary, or a `get-task-allow` entitlement; `scripts/verify-bundle.sh --distribution` checks these.
- **`spctl` rejects the app**: run `xcrun stapler validate dist.noindex/Keel.app` and
  `codesign -dvv --verbose=4 dist.noindex/Keel.app`.
- **Helper does not register on a test Mac**: check `Contents/Library/LaunchDaemons/com.mohdmahmodi.keel.helper.plist`
  is present (`scripts/verify-bundle.sh`), and that `BundleProgram` is `Contents/MacOS/KeelHelper`. The helper only
  serves XPC when it and the app carry the same Team ID.

## Verify a download

Anyone can check a release before opening it:

```bash
cd ~/Downloads
shasum -a 256 Keel-1.2.0.dmg
# compare with Keel-1.2.0.dmg.sha256 on the release page

spctl --assess --type open --context context:primary-signature -vv Keel-1.2.0.dmg
# Keel-1.2.0.dmg: accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Mohd Mahmodi (KLB57Y57PP)
```

After copying the app to Applications:

```bash
spctl --assess --type execute -vv /Applications/Keel.app
# /Applications/Keel.app: accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Mohd Mahmodi (KLB57Y57PP)

codesign --verify --deep --strict --verbose=2 /Applications/Keel.app
codesign -dvv /Applications/Keel.app/Contents/MacOS/KeelHelper 2>&1 | grep -E 'Identifier|TeamIdentifier'
# Identifier=com.mohdmahmodi.keel.helper
# TeamIdentifier=KLB57Y57PP
```

## Website

The site in `docs/site/` is deployed by Cloudflare Pages from `main` (root directory `docs/site`, no build
command). After a release that changes tweaks or the UI, refresh its data and images:

```bash
swift build
scripts/site-data.py                                  # docs/site/tweaks.json from the app's catalog
.build/debug/Keel --snapshots /tmp/keel-shots --tweak dock-autohide-instant
scripts/site-images.py /tmp/keel-shots                # WebP screenshots and the Open Graph image
```

The snapshot run opens a window for a minute and waits for the cleanup scan to finish before capturing.
`site-images.py` needs Pillow (`pip3 install pillow`).
