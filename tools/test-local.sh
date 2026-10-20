#!/usr/bin/env bash
# Runs the tests on your own Mac – no GitHub minutes.
#
#   tools/test-local.sh            # core tests + virtual Kobra S1 + UI tests in the iPhone simulator
#   tools/test-local.sh --quick    # only the core tests (about 1 minute)
#
# Needs Xcode (with an iPhone simulator), Homebrew and python3 (ships with Xcode).
# Screenshots of the UI tests end up in build/screenshots.
# The virtual Snapmaker U1 needs Linux; its tests stay in the (cheap) Linux job on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

quick=false
[ "${1:-}" = "--quick" ] && quick=true

sim_pid=""
cleanup() { [ -n "$sim_pid" ] && kill "$sim_pid" 2>/dev/null || true; }
trap cleanup EXIT

echo "▶︎ Virtueller Kobra S1 wird gestartet …"
python3 tools/virtualprinters/kobra_s1_sim.py --speed 30 --duration 1800 > build-kobra-sim.log 2>&1 &
sim_pid=$!
for _ in $(seq 1 20); do curl -sf --noproxy '*' http://127.0.0.1:18910/info >/dev/null && break; sleep 1; done

echo "▶︎ Kern-Tests (Slicer, G-Code, Drucker-Protokolle, Kobra-LAN gegen den virtuellen Drucker) …"
(cd Packages/MakerSliceCore && KOBRA_HOST=127.0.0.1 swift test 2>&1 | grep -E "error:|failed|Executed .* tests" | tail -5)

if $quick; then
  echo "✔︎ Kern-Tests fertig."
  exit 0
fi

echo "▶︎ Xcode-Projekt erzeugen …"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen >/dev/null

device=$(xcrun simctl list devices available | grep -E "iPhone 1[5-9]( Pro)? \(" | head -1 | sed -E 's/^ *(iPhone[^(]*) \(.*/\1/' | xargs)
echo "▶︎ UI-Tests im Simulator „$device“ (ca. 8 Minuten) …"
rm -rf build/UITests.xcresult build/screenshots
mkdir -p build
set +e
xcodebuild test -project MakerSlice.xcodeproj -scheme MakerSlice \
  -destination "platform=iOS Simulator,name=$device" \
  -resultBundlePath build/UITests.xcresult CODE_SIGNING_ALLOWED=NO > build/uitests.log 2>&1
status=$?
set -e
grep -E "Test Case .*(passed|failed)|error:" build/uitests.log | sed 's/^.*Test Case/Test Case/' | head -30
xcrun xcresulttool export attachments --path build/UITests.xcresult --output-path build/screenshots >/dev/null 2>&1 || true
echo "Screenshots: build/screenshots (Namen in manifest.json)"
[ $status -eq 0 ] && echo "✔︎ Alle Tests bestanden." || echo "✘ UI-Tests fehlgeschlagen – Details in build/uitests.log"
exit $status
