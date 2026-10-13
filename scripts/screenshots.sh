#!/bin/zsh
# Launches Keel on each page, waits for data, captures the window with screencapture -l.
set -u
cd "$(dirname "$0")/.."
mkdir -p screenshots
pkill -x Keel 2>/dev/null; sleep 1
for spec in "overview:overview" "tweaks:tweaks --tweak gpu-wired-limit" "cleanup:cleanup" "benchmark:benchmark" "activity:activity" "settings:settings"; do
  name="${spec%%:*}"; args="${spec#*:}"
  (dist.noindex/Keel.app/Contents/MacOS/Keel --page ${=args} >/dev/null 2>&1 &)
  if [ "$name" = cleanup ]; then sleep 75; else sleep ${WAIT:-14}; fi
  wid=$(swift - <<'SW'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Keel" && ((w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 300 { print(w[kCGWindowNumber as String] as! Int); break }
SW
)
  if [ -n "$wid" ]; then screencapture -x -l "$wid" "screenshots/$name.png" && echo "captured $name (window $wid)"; else echo "no window for $name"; fi
  pkill -x Keel; sleep 2
done
