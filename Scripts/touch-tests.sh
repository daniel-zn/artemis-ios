#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The remote desktop's touch interpreter (Artemis/Desktop/TouchInterpreter.swift), built for the
# Mac with ArtemisTouchTests/ and run: real fingers' timing for two-finger scrolling (staggered
# landings and lifts, a lift's roll back). No Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -O -o "$out/touch-tests" Artemis/Desktop/TouchInterpreter.swift ArtemisTouchTests/*.swift
"$out/touch-tests"
