#!/bin/sh
# Install the official-engine terminal viewer separately from the OCaml build.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
python=python3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || exit 2; prefix=$2; shift 2 ;;
    --python) [ "$#" -ge 2 ] || exit 2; python=$2; shift 2 ;;
    *) printf '%s\n' 'usage: scripts/install-alphatex.sh [--prefix /path/to/bin] [--python python3]' >&2; exit 2 ;;
  esac
done
command -v node >/dev/null 2>&1 || { printf '%s\n' 'Node.js 22 or newer is required' >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { printf '%s\n' 'pnpm is required to install the locked viewer dependencies' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)'
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
runtime_files='ump-source.mjs ump-editor.mjs ump-tui.mjs capture-midi.mjs synth-stream.mjs soundfont-stream.mjs soundfont_stream.py soundfont.mjs soundfont_host.py ump-region-midi.mjs practice-midi.mjs practice-passes.mjs practice-sound.mjs practice-source.mjs practice-source-files.mjs practice-take.mjs render-midi-clock.mjs phrase-backing.mjs step-monitor-session.mjs step-monitor-worker.mjs step-monitor.mjs pcm-output.mjs native/PcmRing.swift native/PcmOutput.swift vst-stream.mjs vst-host.mjs vst-session.mjs midi-source-picker.mjs step-input.mjs midi-input.mjs native/MidiInput.swift arrangement-sound.mjs source-audio-clock.mjs native/SourceAudioClock.swift exact-time.mjs project-sound.mjs project-sound-files.mjs score-handoff.mjs native/WaveLoopClock.swift arrangement-loop.mjs midi-expression.mjs music-library-info.mjs music-library-worker.mjs music-workbench.mjs phrase-arrangement.mjs arrangement-practice.mjs native/PulseAudioClock.swift native/PulseLoopClock.swift recording-correction.mjs calibration-profile.mjs calibration-files.mjs capture-placement.mjs audio-calibration.mjs live-midi.mjs package.json pnpm-lock.yaml engine.mjs audio.mjs diagnostics.mjs worker.mjs terminal.mjs viewer.mjs capture.mjs session-data.mjs capture-time.mjs captured-source.mjs captured-source-files.mjs capture-playback.mjs music-session.mjs wave-file.mjs sequencer-project.mjs arrangement.mjs arrangement-files.mjs arrangement-editor.mjs arrangement-worker.mjs arrangement-tui.mjs arrangement-playback.mjs arrangement-recording.mjs sequencer-files.mjs sequencer-audio.mjs sequencer-midi.mjs midi-source.mjs midi-source-editor.mjs note-selection.mjs midi-source-playback.mjs sequencer-editor.mjs sequencer-vst.mjs sequencer-worker.mjs sequencer-tui.mjs playback.mjs native/MusicSession.swift native/MusicTransport.swift native/MidiTransport.swift native/WaveArrangement.swift native/CaptureAudioClock.swift native/UmpTransport.swift native/UmpOutput.swift native/UmpRegions.swift native/HybridMidiTransport.swift native/UmpLoopTransport.swift native/UmpState.swift native/Info.plist native/UmpLiveInput.swift native/LiveMidiMain.swift native/LiveMidiReservations.swift vst.mjs instruments.mjs status-reader.mjs arrangement-vst.mjs native/MidiRenderProjection.swift arrangement-export.mjs arrangement-midi-export.mjs'
# The VST host is part of this runtime, so its source and lock enter the revision.
vst_files='../vst/host.py ../vst/requirements.lock'
revision=$(node --input-type=module - "$repo_root/tools/alphatex" $runtime_files $vst_files <<'FINGERPRINT'
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
    xcrun swiftc -parse-as-library -O "$support_dir/native/MusicSession.swift" -o "$native_binary" \
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
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-pcm-output" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    pcm_output_binary=$(mktemp "$support_dir/.music-pcm-output.XXXXXX")
    trap 'rm -f "$pcm_output_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -O "$support_dir/native/PcmRing.swift" "$support_dir/native/PcmOutput.swift" -o "$pcm_output_binary" \
      -framework AVFoundation -framework CoreAudio
    chmod 755 "$pcm_output_binary"
    mv -f "$pcm_output_binary" "$support_dir/music-pcm-output"
    trap - EXIT HUP INT TERM
  fi
fi
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-midi" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    midi_binary=$(mktemp "$support_dir/.music-midi.XXXXXX")
    trap 'rm -f "$midi_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -O "$support_dir/native/MidiTransport.swift" "$support_dir/native/MidiRenderProjection.swift" -o "$midi_binary" -framework CoreMIDI
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
    xcrun swiftc -parse-as-library -D MIDI_LIBRARY -O "$support_dir/native/WaveArrangement.swift" "$support_dir/native/WaveLoopClock.swift" "$support_dir/native/SourceAudioClock.swift" "$support_dir/native/CaptureAudioClock.swift" "$support_dir/native/PulseAudioClock.swift" "$support_dir/native/PulseLoopClock.swift" "$support_dir/native/MidiTransport.swift" "$support_dir/native/UmpTransport.swift" "$support_dir/native/UmpOutput.swift" "$support_dir/native/UmpRegions.swift" "$support_dir/native/HybridMidiTransport.swift" "$support_dir/native/UmpLoopTransport.swift" "$support_dir/native/UmpState.swift" -o "$arrangement_binary" \
      -framework AVFoundation -framework CoreAudio -framework CoreMIDI
    chmod 755 "$arrangement_binary"
    mv -f "$arrangement_binary" "$support_dir/music-arrangement"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'WAV arrangement playback requires the Xcode command-line tools.' >&2
  fi
fi
if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-midi-input" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    input_binary=$(mktemp "$support_dir/.music-midi-input.XXXXXX")
    trap 'rm -f "$input_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -O "$support_dir/native/MidiInput.swift" -o "$input_binary" -framework CoreMIDI
    chmod 755 "$input_binary"
    mv -f "$input_binary" "$support_dir/music-midi-input"
    trap - EXIT HUP INT TERM
  fi
fi

if [ "$(uname -s)" = Darwin ] && [ ! -x "$support_dir/music-midi-live" ]; then
  if xcrun --find swiftc >/dev/null 2>&1; then
    live_binary=$(mktemp "$support_dir/.music-midi-live.XXXXXX")
    trap 'rm -f "$live_binary"' EXIT HUP INT TERM
    xcrun swiftc -parse-as-library -D MIDI_LIBRARY -O "$support_dir/native/MidiTransport.swift" "$support_dir/native/UmpTransport.swift" "$support_dir/native/UmpOutput.swift" "$support_dir/native/UmpState.swift" "$support_dir/native/UmpLiveInput.swift" "$support_dir/native/UmpRegions.swift" "$support_dir/native/HybridMidiTransport.swift" "$support_dir/native/UmpLoopTransport.swift" "$support_dir/native/CaptureAudioClock.swift" "$support_dir/native/WaveLoopClock.swift" "$support_dir/native/SourceAudioClock.swift" "$support_dir/native/PulseAudioClock.swift" "$support_dir/native/PulseLoopClock.swift" "$support_dir/native/LiveMidiReservations.swift" "$support_dir/native/LiveMidiMain.swift" -o "$live_binary" -framework CoreMIDI
    chmod 755 "$live_binary"
    mv -f "$live_binary" "$support_dir/music-midi-live"
    trap - EXIT HUP INT TERM
  else
    printf '%s\n' 'Live MIDI input requires the Xcode command-line tools.' >&2
  fi
fi
# The VST host lives inside this runtime: viewers start vst/host beside their
# own modules, so a viewer never speaks to a host from another revision. The
# Python environment depends only on the lock and is shared between runtimes.
# A failure here leaves the viewer installed with SoundFont playback, and the
# next run retries. Each step is checked: set -e does not apply inside the
# || list below.
vst_discovers() {
  # Discovery does not load every installed plug-in or open its editor.
  printf '%s\n' '{"operation":"candidates"}' | "$1" > /dev/null
}
install_vst_host() {
  if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    printf '%s\n' "VST instruments require Python 3.12 or newer ($python); SoundFont playback remains available." >&2
    return 0
  fi
  lock_digest=$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$repo_root/tools/vst/requirements.lock") || return 1
  environment="$prefix/../share/masc/vst-env/$lock_digest"
  # A finished environment is reused only while its interpreter still imports
  # the locked packages; an interpreter upgrade or removal rebuilds it.
  if [ ! -f "$environment/.installed" ] || ! "$environment/bin/python" -c 'import mido, numpy, pedalboard' 2>/dev/null; then
    rm -f "$environment/.installed"
    "$python" -m venv --clear "$environment" || return 1
    if command -v uv >/dev/null 2>&1; then
      uv pip install --python "$environment/bin/python" --require-hashes -r "$repo_root/tools/vst/requirements.lock" || return 1
    else
      "$environment/bin/python" -m pip install --require-hashes -r "$repo_root/tools/vst/requirements.lock" || return 1
    fi
    touch "$environment/.installed" || return 1
  fi
  mkdir -p "$support_dir/vst" || return 1
  install -m 644 "$repo_root/tools/vst/host.py" "$support_dir/vst/host.py" || return 1
  vst_launcher=$(mktemp "$support_dir/vst/.host.XXXXXX") || return 1
  # An interrupted discovery or install removes the unfinished launcher.
  trap 'rm -f "$vst_launcher"' EXIT HUP INT TERM
  if {
    printf '%s\n' '#!/bin/sh' 'set -eu' 'vst_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)'
    printf 'exec "$vst_dir/../../../vst-env/%s/bin/python" "$vst_dir/host.py" "$@"\n' "$lock_digest"
  } > "$vst_launcher" && chmod 755 "$vst_launcher" && vst_discovers "$vst_launcher" \
      && mv -f "$vst_launcher" "$support_dir/vst/host"; then
    trap - EXIT HUP INT TERM
    return 0
  fi
  rm -f "$vst_launcher"
  trap - EXIT HUP INT TERM
  return 1
}
if ! { [ -x "$support_dir/vst/host" ] && vst_discovers "$support_dir/vst/host" 2>/dev/null; }; then
  install_vst_host || printf '%s\n' 'The VST host was not installed; SoundFont playback remains available. Rerun this script to retry.' >&2
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
