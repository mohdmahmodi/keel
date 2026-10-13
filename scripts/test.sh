#!/bin/zsh
# Keel's self-checks. Read-only except where noted.
#   scripts/test.sh            build + allow-list + engine + lint + hardware simulation
#   scripts/test.sh --live     also the live round trips, which apply and restore user-level
#                              tweaks on THIS Mac (Dock and Finder restart; everything is restored)
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=.build/debug/Keel
fail=0
step() { print -P "%B==> $1%b"; }
check() { # name, command…: runs, prints output, fails on FAIL/ERROR lines or a non-zero exit
  local name=$1; shift
  step "$name"
  local out; out="$("$@" 2>&1)"; local rc=$?
  print -r -- "$out" | tail -n 25
  if (( rc != 0 )) || print -r -- "$out" | grep -qE '^(FAIL|ERROR)|: FAIL|→ FAIL'; then print -P "%F{red}✗ $name%f"; fail=1; else print -P "%F{green}✓ $name%f"; fi
}

step "Build"
swift build 2>&1 | grep -E 'error:|Compiling|Build complete' | tail -3
[ -x "$BIN" ] || { print "build failed"; exit 1; }

check "Privileged-operation allow-list" "$BIN" --validate-ops
check "Engine (private preference domain)" "$BIN" --engine-test
check "Catalog lint" "$BIN" --lint
check "Hardware simulation" "$BIN" --simulate
TESTHOME="$(mktemp -d -t keel-cleanup-test)"
check "Cleanup delete paths (sandboxed fake home)" env KEEL_CLEANUP_TEST_HOME="$TESTHOME" "$BIN" --cleanup-selftest
rm -rf "$TESTHOME"
if [[ "${1:-}" == "--live" ]]; then
  check "Live: preference tweaks round trip" "$BIN" --selftest-defaults
  check "Live: custom tweaks round trip" "$BIN" --selftest-custom
  check "Live: launch agent round trip" "$BIN" --selftest-launchd
fi
(( fail == 0 )) && print -P "%F{green}All checks passed%f" || print -P "%F{red}Some checks failed%f"
exit $fail
