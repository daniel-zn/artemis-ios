#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# UI tests with screenshots (ArtemisUITests): every screen with the demo PCs, upright and in
# landscape, at the default and the largest accessibility text size, in light and dark mode;
# then a stream start and exit, the remote desktop's touch controls against the demo desktop
# (DesktopTests: each gesture and the input events it sends), waking a PC and the Mac app's PC and
# app actions (ComputerTests), a controller as the mouse (ControllerTests), the on-screen controller
# and the connected screen's layout (OnScreenGamepadTests), and the app icon on the home screen.
#
#   SIM=<udid> Scripts/ui-tests.sh            (or the booted Simulator)
#   APPEARANCES="dark" Scripts/ui-tests.sh    one appearance only
#   ONLY=testStreamStartsAndReturns Scripts/ui-tests.sh
#   ONLY=HomeScreenIconTests Scripts/ui-tests.sh   the app icon on the home screen
#   ONLY=DesktopTests Scripts/ui-tests.sh          the touch controls (or DesktopTests/testGesturesUpright)
#   ONLY=ComputerTests Scripts/ui-tests.sh         waking (tap and menu), rename, Get Info, connect automatically
#   ONLY=ControllerTests Scripts/ui-tests.sh       a controller as the mouse
#   ONLY=OnScreenGamepadTests Scripts/ui-tests.sh  the on-screen controller, the trackpad and bar layout
#   LIVE_HOST=<name>@<address> ONLY=LiveHostTests Scripts/ui-tests.sh   a real host: it shows up and
#                                             opens (games, or a PIN that the test cancels)
#   UI_TESTS=ScreenshotTests/testStreamStartsAndReturns,DesktopTests Scripts/ui-tests.sh
#                                             exactly these (Class or Class/test, comma-separated;
#                                             integrate's selection): fails if one of them didn't run
#
# Screenshots: build/ui-tests/shots/<appearance>-<orientation>-<text size>-<n>-<screen>.png.
# Logs: build/ui-tests/<appearance>.log. Exit code: the first failing xcodebuild's.
set -euo pipefail
# The "Artemis Build" Simulator belongs to the sim-artemis line: a run outside its turn (by hand)
# takes the turn first, so it never shares the Simulator with integrate's ui check or another run.
# Inside the turn (integrate's check, `turn run sim-artemis`), MERCURIUS_TURNS names it already.
if [[ ",${MERCURIUS_TURNS:-}," != *",sim-artemis,"* ]] && command -v mercurius-agent >/dev/null; then
  exec mercurius-agent turn run sim-artemis --reason "Artemis UI tests" -- "$0" "$@"
fi
cd "$(dirname "$0")/.."

# UI_TESTS: the selected tests, each Class or Class/test of ArtemisUITests
SELECTED=()
if [[ -n "${UI_TESTS:-}" ]]; then
  [[ -z "${ONLY:-}" ]] || { echo "set ONLY or UI_TESTS, not both" >&2; exit 2; }
  IFS=',' read -ra SELECTED <<< "$UI_TESTS"
  [[ ${#SELECTED[@]} -gt 0 ]] || { echo "UI_TESTS: no tests in '$UI_TESTS'" >&2; exit 2; }
  for t in "${SELECTED[@]}"; do
    [[ "$t" =~ ^[A-Za-z0-9_]+(/test[A-Za-z0-9_]+)?$ && -f "ArtemisUITests/${t%%/*}.swift" ]] \
      && { [[ "$t" != */* ]] || grep -qE "func ${t#*/}\(" "ArtemisUITests/${t%%/*}.swift"; } \
      || { echo "UI_TESTS: no such test: $t" >&2; exit 2; }
  done
fi

SIM="${SIM:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
[[ -n "$SIM" ]] || { echo "no booted Simulator (set SIM=<udid>)" >&2; exit 2; }
OUT="$PWD/build/ui-tests"
DD="${DERIVED_DATA:-$OUT/dd}"
rm -rf "$OUT/shots" && mkdir -p "$OUT/shots"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
# A new or erased Simulator shows the keyboard's one-time "slide to type" intro over the key row
xcrun simctl spawn "$SIM" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
# A help link opened in an earlier run would leave a "◀ Safari" in the status bar
xcrun simctl terminate "$SIM" com.apple.mobilesafari 2>/dev/null || true

xcodebuild build-for-testing -project Moonlight.xcodeproj -scheme ArtemisUITests -scmProvider system \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD" > "$OUT/build.log" 2>&1 \
  || { grep -E "error:" "$OUT/build.log" | head -20; exit 1; }

# Every selected test ran (passed, failed or skipped) in this appearance's log; a whole class ran
# every test it declares.
check_selected() {
  local log="$1" t class n declared missing=0
  for t in "${SELECTED[@]}"; do
    class="${t%%/*}"
    if [[ "$t" == */* ]]; then
      grep -qE "Test Case '-\[ArtemisUITests\.$class ${t#*/}\]' (passed|failed|skipped)" "$log" \
        || { echo "NOT RUN: $t"; missing=1; }
    else
      declared=$(grep -cE '^[[:space:]]*func test[A-Za-z0-9_]*\(' "ArtemisUITests/$class.swift")
      n=$(grep -oE "Test Case '-\[ArtemisUITests\.$class test[A-Za-z0-9_]+\]' (passed|failed|skipped)" "$log" | sort -u | wc -l | tr -d ' ')
      [[ $n -ge $declared && $n -gt 0 ]] || { echo "NOT RUN: $t ($n of its $declared tests ran)"; missing=1; }
    fi
  done
  return $missing
}

ORIGINAL="$(xcrun simctl ui "$SIM" appearance)"
trap 'xcrun simctl ui "$SIM" appearance "$ORIGINAL" >/dev/null 2>&1 || true' EXIT
status=0
for appearance in ${APPEARANCES:-light dark}; do
  xcrun simctl ui "$SIM" appearance "$appearance"
  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    ONLY_ARGS=(); for t in "${SELECTED[@]}"; do ONLY_ARGS+=(-only-testing:"ArtemisUITests/$t"); done
  else case "${ONLY:-}" in
    *Tests*) ONLY_ARGS=(-only-testing:"ArtemisUITests/$ONLY") ;;
    "") ONLY_ARGS=(-only-testing:ArtemisUITests/ScreenshotTests -only-testing:ArtemisUITests/DesktopTests
                   -only-testing:ArtemisUITests/ComputerTests -only-testing:ArtemisUITests/ControllerTests
                   -only-testing:ArtemisUITests/OnScreenGamepadTests -only-testing:ArtemisUITests/HomeScreenIconTests) ;;
    *) ONLY_ARGS=(-only-testing:"ArtemisUITests/ScreenshotTests/$ONLY") ;;
  esac; fi
  TEST_RUNNER_ARTEMIS_APPEARANCE="$appearance" TEST_RUNNER_ARTEMIS_SHOT_DIR="$OUT/shots" \
  TEST_RUNNER_ARTEMIS_LIVE_HOST="${LIVE_HOST:-}" \
    xcodebuild test-without-building -project Moonlight.xcodeproj -scheme ArtemisUITests \
      -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD" -collect-test-diagnostics never \
      "${ONLY_ARGS[@]}" > "$OUT/$appearance.log" 2>&1 || { rc=$?; [[ $status == 0 ]] && status=$rc; }
  echo "== $appearance"
  grep -E "error:|Test Case .*(passed|failed|skipped)|\*\* TEST" "$OUT/$appearance.log" | sed 's/^.*error: //' | tail -60
  if [[ ${#SELECTED[@]} -gt 0 ]] && ! check_selected "$OUT/$appearance.log"; then
    [[ $status == 0 ]] && status=1
  fi
done
echo "$(ls "$OUT/shots" | wc -l | tr -d ' ') screenshots in $OUT/shots"
exit $status
