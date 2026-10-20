# Native VST phrase host

This companion runs one VST3 job in a separate native Python process. It uses
Pedalboard 0.9.26 for plug-in discovery/loading/audio rendering and Mido 1.3.3
for SMF track merging and tempo changes. It does not open an audio device.
The caller owns the child, cancellation, output directory and WAV playback.

For continuous keyboard synthesis, `host.py --stream` keeps one project-bound
instrument loaded across request-driven PCM blocks. It still opens no audio
device. The consumer supplies the audio clock, MIDI sample offsets and output
capacity; this is the synthesis layer for live audition, not a completed TUI
monitoring feature. See [stream protocol](STREAM.md).

This is the native rendering component of the MIDI phrase Lane. It is not a
new MASC container runtime, and its direct local commands are not
`masc_lane_act` receipts. A container cannot load a macOS VST binary. The TUI
executes the companion locally; retained results can enter the generic Lane
through the existing `snapshot_file` contract.

For a normal installation, run `scripts/install-vst-host.sh` from the repository
root. `--python` selects a Python 3.12+ interpreter and `--prefix` selects the
commands directory. Dependencies and native code are kept in an immutable
adjacent `share/masc/vst/<source digest>` runtime; the launcher is replaced only
after discovery succeeds. The installed `masc-vst-host` reads the same jobs as
the development command below.

For development, install the hashed dependency lock in an isolated Python 3.12+
environment, then send one JSON job:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r requirements.lock
printf '%s\n' '{"operation":"candidates"}' | .venv/bin/python host.py
```

`candidates` lists the VST3 bundles found by the platform's Pedalboard/JUCE
discovery. These are candidates, not verified instruments. `inspect` takes
`plugin_path` and an optional `plugin_name`. Multi-plugin bundles return their
actual names for explicit selection. A loaded audio effect is refused as a
MIDI instrument.

`edit` takes the same plug-in identity, an optional existing `preset_path`, and
an `output_path` for a new `.vstpreset`. Only this explicit operation opens the
plug-in's native editor. Closing the editor captures its complete current preset
for subsequent renders. This also supports instruments whose sample browser and
factory sounds are available only inside their own editor. Saved presets are
local user data and are never included in package distribution.

`snapshot` takes the same identity and optional `preset_path`. It captures the
actual loaded state, including the default sound, without opening an editor.
Its result contains `instrument` and `preset: {data, sha256}` with base64 preset
bytes. Phrase documents own these bytes, rather than depending on the original
file. Bound playback materializes a private preset, supplies
`expected_instrument: {identifier, version}` to `render`, checks its returned
input hash, and removes the private preset after the native child closes.
An installed identity/version mismatch fails before synthesis.

`render` takes `plugin_path`, optional `plugin_name`, `midi_path`, `output_path`,
optional `preset_path` (a `.vstpreset`), `sample_rate` (default 44100) and
`tail_seconds` (default 1, an audible release tail rather than a job timeout).
For example:

```json
{"operation":"render","plugin_path":"/path/to/Synth.vst3","midi_path":"phrase.mid","output_path":"phrase.wav"}
```

The selected VST preset controls timbre. Soundfont bank-select and program-change
events are excluded from the rendering timeline so the source's GM program
cannot silently replace that preset. Notes, tempo changes, controller expression
and pitch bend retain their original timing. MIDI type 2 is refused because its
tracks have independent timelines. No soundfont fallback occurs on plug-in,
preset, sample-library or license failure. Silent output is reported as an
error, not successful playback.

WAV synthesis streams stereo audio in one-second blocks; phrase length has no
synthetic limit. Only a complete non-silent render is published, and an existing
destination is never overwritten. The result includes WAV, MIDI, preset and plug-in
state hashes, the reported plug-in identity/version, sample rate, frame count,
peak and output path. These identify a render, not proof that a device played it.
Native plug-in diagnostics remain on stderr, outside the JSON reply channel.

Run the MIDI and process-boundary tests with the same environment:

```sh
.venv/bin/python -m unittest discover -s . -p 'test_*.py' -v
```

Actual installed plug-ins require their own compatible native binaries, sample
libraries and licenses. Discovery or an instrument flag does not establish
audible rendering. Vendor plug-ins can crash their child process; callers must
report a failed job and retain the selected instrument instead of substituting
another one.

References: [Pedalboard API](https://spotify.github.io/pedalboard/reference/pedalboard.html),
[Mido MIDI files](https://mido.readthedocs.io/en/stable/files/midi.html).
Pedalboard is GPL-3.0; Mido is MIT. Installation must retain their distributed
license notices. No vendor plug-in, preset or sample data is redistributed here.
