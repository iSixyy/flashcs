#!/usr/bin/env bash
# Runs the harness under wine on a virtual display (Linux). Needs: wine64, xvfb, openbox,
# xcompmgr and AutoHotkey v1.1 (AutoHotkeyU64.exe). On Windows, just generate the scenes
# with Python and run: AutoHotkeyU64.exe /ErrorStdOut tests\harness.ahk 180
set -euo pipefail
cd "$(dirname "$0")"
AHK="${AHK:-AutoHotkeyU64.exe}"
SOAK="${1:-60}"
WINE="${WINE:-wine64}"
python3 gen_scenes.py img
export DISPLAY="${DISPLAY:-:99}"
if ! xdpyinfo >/dev/null 2>&1; then Xvfb "$DISPLAY" -screen 0 1920x1080x24 & sleep 1; fi
pgrep -x openbox >/dev/null || { openbox & sleep 1; }   # without a WM wine stalls ~2 s per window hide
pgrep -x xcompmgr >/dev/null || { xcompmgr & sleep 1; } # real alpha blending of the overlay
"$WINE" "$AHK" /ErrorStdOut /iLib NUL ../FlashBangColorChanger.ahk   # load-time syntax check
rm -f results.txt
"$WINE" "$AHK" /ErrorStdOut harness.ahk "$SOAK" native || true
cat results.txt
grep -q "0 failed" results.txt
