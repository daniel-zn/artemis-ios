#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Resolves the Swift packages (OpenSSL) into a derived data folder, with a time limit, so a hang
# fails in minutes with its log instead of holding a build until its own timeout.
#
#   Scripts/resolve-packages.sh <scheme> <derived data path> <log file> [limit in seconds, default 600]
#
# The build that follows uses the same derived data path and finds the packages there.
# -packageAuthorizationProvider netrc: with the keychain (the default), downloading OpenSSL's binary
# artifact first looks up a github.com login there, which waits forever while the Mac is locked
# (once SwiftPM's artifact cache is gone). The packages are public: no login needed.
set -uo pipefail
cd "$(dirname "$0")/.."
SCHEME=$1 DD=$2 LOG=$3 LIMIT=${4:-600}
xcodebuild -resolvePackageDependencies -project Moonlight.xcodeproj -scheme "$SCHEME" -scmProvider system \
  -packageAuthorizationProvider netrc -derivedDataPath "$DD" > "$LOG" 2>&1 &
pid=$!
for ((i = 0; i < LIMIT; i++)); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
  pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
  echo "error: resolving the Swift packages hung over $LIMIT s; last lines of $LOG:" >&2
  tail -5 "$LOG" >&2
  exit 1
fi
wait "$pid" || { echo "error: resolving the Swift packages failed; last lines of $LOG:" >&2; tail -20 "$LOG" >&2; exit 1; }
