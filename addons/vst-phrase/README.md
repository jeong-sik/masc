# Native MIDI phrase observation

The native score companion selects and loads the user's VST3 instruments,
renders the selected score tracks to MIDI and WAV, and starts the local audio
player. This worker reads its latest `snapshot.json` through the generic
`snapshot_file` input. VST binaries, licenses and editors stay on the audio host.
The container has no audio device, native VST runtime or network access.

Install the helpers with `scripts/install-vst-host.sh` and
`scripts/install-alphatex.sh`. In the TUI, open `/score`, press Space or `i`,
select a VST, then select its default state or a saved `.vstpreset`. Press `e`
in the preset menu to open the instrument's own factory browser and close its
window to save that complete sound. `l` repeats, Space pauses/resumes, `s` stops.

Use the installation declaration in
`docs/examples/lane-addons/vst-phrase.toml` after replacing its snapshot path.
On macOS the default is `~/Library/Application Support/masc/vst/snapshot.json`;
elsewhere it is `$XDG_STATE_HOME/masc/vst/snapshot.json` (default
`~/.local/state/masc/vst/snapshot.json`). `--state-dir` overrides the companion's
directory. Point the installation at the same path explicitly.

The output preserves instrument/preset selection, exact MIDI/WAV hashes, retained
file references, failure detail and source coordinates. Coverage describes the
supplied latest state, not a complete history. Playback events identify the
local player process; they do not measure device audibility. A render failure is
a known state, not a successful silent render. This observer has no action tool:
local playback does not create a `masc_lane_act` receipt.

In the phrase editor, `:wave PATH` also updates this snapshot for a selected VST.
`exported` means the WAV was copied to the requested destination; its evidence
references that file and the retained MIDI with their render hashes.
`export_failed` retains the requested destination and error without claiming a
published WAV. An export does not start or acknowledge an audio player.

Build the image through the repository's permitted Lane image CI and retain its
exact source SHA and image ID separately from the stdio tests. The manifest alone
does not establish an installed or running worker. No Steinberg or other vendor
binary, factory preset, license or sample library is redistributed.
