#!/bin/zsh
# Builds the release app and installs it to /Applications/Keel.app.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
pkill -x Keel 2>/dev/null || true
rm -rf /Applications/Keel.app
cp -R dist.noindex/Keel.app /Applications/Keel.app
echo "Installed /Applications/Keel.app — open it from Launchpad, Spotlight, or: open -a Keel"
