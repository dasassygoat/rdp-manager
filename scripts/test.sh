#!/bin/bash
# Runs the unit tests. Pass -v to print the whole xcodebuild log instead of a summary.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d RDPManager.xcodeproj ] || xcodegen generate

LOG="$(mktemp -t rdpmanager-tests)"
if xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath build/DerivedData test >"$LOG" 2>&1; then
  if [ "${1:-}" = "-v" ]; then cat "$LOG"; else
    grep -E "^Test Suite .* (passed|failed)|Executed |^\*\* TEST" "$LOG"
  fi
  rm -f "$LOG"
else
  grep -E "error:|failed \(|^\*\* TEST" "$LOG" | head -40 || true
  if [ -n "${CI:-}" ]; then
    echo "--- full log ---"
    cat "$LOG"
  else
    echo "full log: $LOG" >&2
  fi
  exit 1
fi
