#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The shared clipboard with Apollo (Artemis/Clipboard/ClipboardSyncState.swift and
# ClipboardSync.swift), built for the Mac with ArtemisClipboardTests/ and run: what is read, sent
# and written when, against a stand-in PC and pasteboard. No Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -O -o "$out/clipboard-tests" Artemis/Clipboard/ClipboardSyncState.swift Artemis/Clipboard/ClipboardSync.swift ArtemisClipboardTests/*.swift
"$out/clipboard-tests"
