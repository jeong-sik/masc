#!/bin/sh
# Install the official-engine terminal viewer separately from the OCaml build.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--prefix" ]; then
    printf '%s\n' 'usage: scripts/install-alphatex.sh [--prefix /path/to/bin]' >&2
    exit 2
  fi
  prefix=$2
fi
command -v node >/dev/null 2>&1 || { printf '%s\n' 'Node.js 22 or newer is required' >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { printf '%s\n' 'pnpm is required to install the locked viewer dependencies' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)'
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
runtime_files='package.json pnpm-lock.yaml engine.mjs audio.mjs diagnostics.mjs worker.mjs terminal.mjs viewer.mjs capture.mjs session-data.mjs capture-time.mjs captured-source.mjs captured-source-files.mjs capture-playback.mjs music-session.mjs wave-file.mjs sequencer-project.mjs arrangement.mjs arrangement-files.mjs arrangement-editor.mjs arrangement-worker.mjs arrangement-tui.mjs arrangement-playback.mjs sequencer-files.mjs sequencer-audio.mjs sequencer-midi.mjs midi-source.mjs midi-source-editor.mjs midi-source-playback.mjs sequencer-editor.mjs sequencer-worker.mjs sequencer-tui.mjs playback.mjs native/MusicSession.swift native/MusicTransport.swift native/MidiTransport.swift native/WaveArrangement.swift native/CaptureAudioClock.swift native/UmpTransport.swift native/UmpOutput.swift native/UmpRegions.swift native/HybridMidiTransport.swift native/UmpState.swift native/Info.plist vst.mjs instruments.mjs'
revision=$(node --input-type=module - "$repo_root/tools/alphatex" $runtime_files <<'FINGERPRINT'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
const hash = createHash('sha256')
for (const name of process.argv.slice(3)) {
  hash.update(name).update('\0').update(readFileSync(join(process.argv[2], name))).update('\0')
}
console.log(hash.digest('hex'))
FINGERPRINT
)
support_dir="$prefix/../share/masc/alphatex/$revision"
if [ ! -f "$support_dir/.installed" ]; then
  mkdir -p "$support_dir"
  mkdir -p "$support_dir/native"
  for file in $runtime_files; do
    install -m 644 "$repo_root/tools/alphatex/$file" "$support_dir/$file"
  done
  pnpm --dir "$support_dir" install --prod --frozen-lockfile
  # Prove the native backend can load before changing an installed launcher.
  node --input-type=module -e '
    import { pathToFileURL } from "node:url";
    import { resolve } from "node:path";
    const engine = await import(pathToFileURL(resolve(process.argv[1], "engine.mjs")));
    engine.renderScore(":4 0.6", {page: 0});
  ' "$support_dir"
  touch "$support_dir/.installed"
fi
# Capture uses the system CoreAudio/CoreMIDI drivers. Keep its binary in the
# immutable runtime so updating a launcher cannot replace a running recorder.
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-native" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    native_binary=$(mktemp "$support_dir/.music-native.XXXXXX")
    trap 'rm -f "$native_binary"' EXIT HUP INT TERM
    xcrun swiftc -O "$support_dir/native/MusicSession.swift" -o "$native_binary" \
      -framework AVFoundation -framework CoreAudio -framework CoreMIDI -framework AudioToolbox \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$support_dir/native/Info.plist"
    chmod 755 "$native_binary"
    mv -f "$native_binary" "$support_dir/music-native"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'Audio/MIDI capture requires the Xcode command-line tools; score viewing remains available.' >&2
  fi
fi
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-transport" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    transport_binary=$(mktemp "$support_dir/.music-transport.XXXXXX")
    trap 'rm -f "$transport_binary"' EXIT HUP INT TERM
    xcrun swiftc -O "$support_dir/native/MusicTransport.swift" -o "$transport_binary" \
      -framework AVFoundation -framework CoreAudio
    chmod 755 "$transport_binary"
    mv -f "$transport_binary" "$support_dir/music-transport"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'Native sequencer playback requires the Xcode command-line tools.' >&2
  fi
fi
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-midi" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    midi_binary=$(mktemp "$support_dir/.music-midi.XXXXXX")
    trap 'rm -f "$midi_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -O "$support_dir/native/MidiTransport.swift" -o "$midi_binary" -framework CoreMIDI
    chmod 755 "$midi_binary"
    mv -f "$midi_binary" "$support_dir/music-midi"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'MIDI output requires the Xcode command-line tools.' >&2
  fi
fi
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-arrangement" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    arrangement_binary=$(mktemp "$support_dir/.music-arrangement.XXXXXX")
    trap 'rm -f "$arrangement_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -D MIDI_LIBRARY -O "$support_dir/native/WaveArrangement.swift" "$support_dir/native/CaptureAudioClock.swift" "$support_dir/native/MidiTransport.swift" "$support_dir/native/UmpTransport.swift" "$support_dir/native/UmpOutput.swift" "$support_dir/native/UmpRegions.swift" "$support_dir/native/HybridMidiTransport.swift" "$support_dir/native/UmpState.swift" -o "$arrangement_binary" \
      -framework AVFoundation -framework CoreAudio -framework CoreMIDI
    chmod 755 "$arrangement_binary"
    mv -f "$arrangement_binary" "$support_dir/music-arrangement"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'WAV arrangement playback requires the Xcode command-line tools.' >&2
  fi
fi
# The relative layout is shared by every prefix; no checkout or workspace path
# is embedded in the launcher and the installed viewer survives worktree removal.
launcher=$(mktemp "$prefix/.masc-alphatex.XXXXXX")
trap 'rm -f "$launcher"' EXIT HUP INT TERM
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER
printf 'exec node "$bin_dir/../share/masc/alphatex/%s/viewer.mjs" "$@"\n' "$revision" >> "$launcher"
chmod 755 "$launcher"
mv -f "$launcher" "$prefix/masc-alphatex"
"$prefix/masc-alphatex" --help
