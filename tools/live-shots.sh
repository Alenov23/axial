#!/bin/bash
# Continuously captures every settings pane of the running Axial window into
# $OUT (default: ../shots) for the live HTML preview. Ctrl-C to stop.
OUT="${1:-$(cd "$(dirname "$0")/../.." && pwd)/shots}"
TAB="${AXIALTAB:-$HOME/Library/Caches/axial-build/axialtab}"
mkdir -p "$OUT"
names=(live mapping tuning buttons profiles test service)
window() {
  swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]
for w in l where (w["kCGWindowOwnerName"] as? String) == "Axial" && ((w["kCGWindowBounds"] as? [String:Any])?["Width"] as? Double ?? 0) > 500 { print(w["kCGWindowNumber"]!); break }' 2>/dev/null
}
WID=$(window)
while true; do
  [ -z "$WID" ] && { sleep 2; WID=$(window); continue; }
  for i in "${!names[@]}"; do
    "$TAB" "$i"; sleep 1.2
    screencapture -x -o -l "$WID" "$OUT/tmp-${names[$i]}.png" 2>/dev/null && mv -f "$OUT/tmp-${names[$i]}.png" "$OUT/${names[$i]}.png" || WID=$(window)
    date +%s > "$OUT/stamp.txt"
  done
  "$TAB" "${SHOTS_REST_TAB:-0}"; sleep "${SHOTS_INTERVAL:-4}"
done
