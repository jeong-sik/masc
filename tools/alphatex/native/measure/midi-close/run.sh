#!/usr/bin/env bash
# Build and run the #45224 close-ordering measurement (measurement branch only).
# Usage: bash run.sh <output-directory> <label> [extra harness flags...]
# Writes <label>.json and <label>.txt. Only private virtual CoreMIDI
# destinations created by the harness receive messages.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
native="$(cd "$here/../.." && pwd)"
out="${1:?output directory}"
label="${2:?label}"
shift 2
mkdir -p "$out"
binary="$out/midi-close-measure"
if [[ ! -x "$binary" ]]; then
  xcrun swiftc -parse-as-library -D MIDI_LIBRARY \
    "$native/MidiTransport.swift" "$native/UmpTransport.swift" \
    "$native/UmpOutput.swift" "$native/UmpState.swift" \
    "$here/MidiCloseMeasure.swift" -o "$binary" -framework CoreMIDI
fi
"$binary" --json "$out/$label.json" "$@" | tee "$out/$label.txt"
