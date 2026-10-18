# alphaTex in the terminal

The full score view uses the pinned official alphaTab 1.8.4 importer,
alphaSkia 3.5.147 engraver, MIDI generator and AlphaSynth synthesizer. MASC does not translate
notation into its own reduced score model. Bravura is loaded explicitly for
music glyphs; alphaTab's own Skia backend draws the terminal's PNG. Only the
selected system is rasterized in the interactive view, preserving official
fragment positions without allocating a whole-song image.

Install Node.js 22+ and pnpm, then run `scripts/install-alphatex.sh` from the
repository. This installs `masc-alphatex` beside the MASC commands and its
runtime files under the adjacent `share/masc/alphatex/<source digest>` directory.
Installation validates the native backend before atomically replacing the
launcher; an existing score view retains its own immutable runtime. The helper
must be on the TUI's PATH. For development, run `pnpm install --frozen-lockfile`
here and put this directory on PATH; `masc-alphatex` is the launcher.

In Keeper chat, `/score` opens the latest closed `alphatex` or `atex` fence in
the loaded conversation. `/score 2` opens the preceding score. This freezes
the source before transferring terminal ownership and returns to the same
conversation on exit. No source is sent to a browser or external service.

The full view currently requires a terminal supporting Kitty graphics with
measured cell dimensions: Ghostty, Kitty or WezTerm. The chat's ASCII preview
remains available on other terminals. In the score view:

- Up/Down or j/k scroll; PageUp/PageDown move a viewport and continue across
  systems; `[`/`]` select a system; Home/End jump to the start/end of the score.
- +/- change notation size; `t` cycles all tracks and individual tracks.
- Left/Right select a frozen score from the current conversation snapshot.
- Space opens instrument selection before rendering the selected tracks, then
  pauses/resumes playback. `i` stops the current phrase and opens the picker.
- Select a VST3 candidate to verify it is an instrument, then choose its default
  sound or a saved `.vstpreset`. `/` searches, Enter selects, Escape cancels.
  The second line always names the live choice (`Retrologue · Warm Pad`, or
  `Retrologue · default state`); the picker marks that row with `●`, so the
  cursor (`›`) and the sounding instrument never read alike. The footer lists
  only the keys the open menu answers: `Enter:play` and `e`/`p` appear in the
  preset menu, `Enter:select` in the plug-in list.
  In the preset menu, `e` opens the instrument's native editor and sound browser;
  close that window to save the complete sound. `p` accepts a preset file path.
- `l` toggles repeat, using the same rendered audio for each repetition.
- `r` opens audio/MIDI input selection and the recording timeline on macOS.
- `v` shows the source and complete official diagnostics; `s` stops playback;
  `q` or Escape returns to the conversation.

Install `scripts/install-vst-host.sh` with Python 3.12+ to use installed VST3
instruments. The host runs natively so vendor libraries and licensing stay on
the user's machine. The picker remembers the exact instrument and preset.
Loading, licensing, rendering and silent-output failures are reported without
substituting another instrument. Cubase-bundled instruments such as Retrologue
and HALion Sonic appear when installed; usable sounds still depend on the user's
installed content and license. Native factory sounds are selected in their own
editor, rather than inferred from plug-in parameters.

For VST playback, the official engine generates MIDI, including track selection,
repeat order, effects and tempo events. The native host retains note timing and
expression, excluding MIDI bank/program messages so the explicitly selected VST
sound remains authoritative. This does not synchronize a plug-in's internal
arpeggiator or effect transport. See `tools/vst/README.md` for the render contract.

The explicit SoundFont entry synthesizes a private temporary PCM WAV by the official engine,
including its repeat order, instrument changes and note effects. It uses
the existing `[tui] midi_soundfont` when configured, otherwise the alphaTab
package's Sonivox SoundFont. Playback uses afplay, ffplay, aplay or SoX play
from PATH, in that order. A player failure is reported in the view. Playback
stops when the view closes. VST renders and their exact MIDI inputs remain in
the native state directory with SHA-256 metadata for later comparison; temporary
playback files are removed. There is no synchronized playback cursor yet.
Track selection isolates sounding parts while preserving the full score's
pickup/grace timing, repeats and tempo. Parts explicitly sharing a MIDI channel
(such as percussion on channel 9) retain the official shared channel program,
volume and controller state; solo does not create independent MIDI channels.

Native preferences, presets, retained renders and `snapshot.json` default to
`~/Library/Application Support/masc/vst` on macOS, or
`${XDG_STATE_HOME:-~/.local/state}/masc/vst` elsewhere. `--state-dir` overrides this
host-local directory. The `vst-phrase` Lane observer can consume that exact snapshot
through a separately configured `snapshot_file` source. It retains local process
events and render evidence; it does not establish device audibility, a complete
playback history, or a Lane action receipt.

Malformed alphaTex remains malformed: diagnostics and the original source
are retained. In particular, `\staff {score tabs}` uses **tabs**, not `tab`.
Support is defined by this pinned engine version, including its own limits
and defects; a passing fixture set is not proof of every possible notation.

To validate or export a file without a terminal:

```sh
node viewer.mjs example.atex --check
node viewer.mjs example.atex --render score.png --audio score.wav
pnpm test
```

Exports refuse to overwrite an existing file. Rendering and synthesis in the
interactive view run on workers. Only the active generation may replace the
score or start audio, and workers stop before temporary files are removed.

## Recording audio and MIDI

On macOS, the installer compiles a CoreAudio/CoreMIDI companion using the Xcode
command-line tools. In a score view press `r`, or run `masc-alphatex --record`.
Device discovery does not capture audio. Choose the audio input with `i` and
the MIDI sources with `m`, then press `r` to begin a new take. `s` stops and saves;
leaving the view also waits for file finalization. Recording never starts merely
because the score view opens. The input may be a connected audio interface,
built-in microphone, aggregate device or loopback device exposed by CoreAudio.

The take folder is displayed before recording. Its default is `music-sessions`
under the process's working directory; `--session-root /path/to/folder` chooses
another location. Every take has its own directory and no saved take is replaced.
`--input DEVICE_UID` and `--midi all|none|SOURCE_ID` preselect inputs from
`--devices`; the recording still requires pressing `r`.
WAV channel waveforms and MIDI source/group/channel tracks share the native host
clock. Waveforms show captured block extrema, not an editable sample waveform.
Use arrows to scroll tracks or time, +/- to zoom, and `f` to follow incoming data.
Space plays/stops the saved WAV through the system default output. It does not
play the captured MIDI tracks. Open an existing take with:

```sh
masc-alphatex --devices
masc-alphatex --session /path/to/take-directory
```

Press `e` after saving to export one MIDI 2.0 Clip per input source. UMP group and
channel data, 16-bit velocity and 32-bit controllers remain intact. Clip times
are quantized to 1000 ticks per quarter note; original timestamps and every UMP
word remain in `midi.ump.jsonl`. Clip-owned timing/start/end utility messages are
not duplicated in the export. Capture failures remain visible and retain their
files. See the [native protocol](native/README.md) for clock and failure semantics.

This recording view captures simultaneous tracks in a take. Overdubbing,
multi-take arrangement/mixing, MIDI playback/output, input monitoring, output
device selection and practice scoring are not implemented here. The existing
score playback remains available when returning to the score view.

alphaTab is MPL-2.0, Bravura is OFL-1.1, alphaSkia is BSD-3-Clause. Their notices ship
with the locked dependencies. The Sonivox license is in alphaTab's
`dist/soundfont/LICENSE` and must remain with a redistributed installation.
JZZ and JZZ MIDI SMF are MIT-licensed; their notices ship with the pinned packages.
# Phrase sequencer

From `/score`, press **p** to open the piano-roll editor. It also opens directly
with `masc-alphatex --sequence`; reopen a saved document with `--project song.json`.
Projects save under `./music-projects` by default (`--project-root` changes this).
An existing recording remains a separate take; the editor's **r** opens the capture
screen and returns to the same phrase. It does not yet overdub into the project.

Move the cursor with arrows; Enter inserts or removes a note. Shift+arrows moves
the selected note. `[`/`]` changes its length, `+`/`-` changes velocity, and `g`
cycles the musical grid. Tab changes track, `n` adds one, `m` mutes it and `o`
solos it. `u`/`y` undo/redo. On macOS, Space starts, pauses or resumes a preview of
the audible tracks with the bundled SoundFont; `:stop` ends playback. `l` toggles
repetition of the loop region inside one native AVAudioEngine/PlayerNode. `:seek 4` moves to
quarter-note beat 4. Select an audio output with `--output UID` or `:output UID`;
`--devices` lists CoreAudio device identities. An explicit output is pinned and
read back, and unavailable outputs fail without substituting another device.
The decoded WAV must fit the native PCM buffer resources. See the
[transport protocol](native/TRANSPORT.md) for lifecycle and resource limits.
For external MIDI, use `--midi-output=ID` or `:midi-output ID`; `--devices` lists
CoreMIDI destinations separately from recording sources. Use the equals form
for signed IDs, for example `--midi-output=-1234`. Space, pause/resume,
seek and looping then send the project's notes, programs, level and pan directly
to that pinned destination without synthesizing a WAV. Missing or removed ports
fail without switching devices. Pausing and closing release this transport's
held keys; resuming recreates notes still sounding at the target position.
Resumed envelopes retrigger. `:audio` returns to the previous audio output,
and `:output UID` selects an audio route. Changing routes waits for the previous
player to release its keys. See the [MIDI protocol](native/MIDI-TRANSPORT.md).
This is MIDI 1.0 project playback; MIDI import, arbitrary expression and external
clock synchronization remain separate work. `s` saves,
and q/Esc saves edits before returning. If the original file
changed externally, closing retains edits in a private recovery document and prints
its path rather than replacing the changed file.

Press `:` for commands and `?` for help. Beat numbers start at zero and use quarter
notes. For example:

```
progression 0 4 rootless Dm7 G7 Cmaj7
track-add Electric bass
program 33
level 80
note D2 0 4 110
note G2 4 4 105
note C2 8 4 100
loop 0 12
export /path/phrase.mid
save-as /path/experiment.json
```

`chord Cmaj7 0 4 drop2 4 0` inserts a four-beat voicing; modes are close, drop2
and rootless, followed by octave and inversion. Tonal supplies chord candidates,
intervals and the rootless dictionary. Candidates at the cursor include bass and
inversions but do not assert a unique harmonic interpretation. `transpose -12`,
`quantize 0.25` and `duplicate 8` operate on the selected track transactionally.
`tempo 120`, `length 32` and `meter 3 4` set project timing. MIDI/WAV export refuses
existing files. `level 100` and `pan 64` set the selected track's MIDI volume and
pan (0–127; pan 64 is center). Dense mixes can clip; lower track levels when the
preview/export reports clipped samples. The broader destination and remaining work are recorded in
[the sequencer design](../../docs/design/tui/MUSIC-SEQUENCER.md).


## MIDI source experiments

Open an existing SMF or RIFF RMID without changing it:

```sh
masc-alphatex --midi-file performance.mid
masc-alphatex --midi-file patterns.mid --midi-pattern 2
```

The source editor retains original file bytes and source-event edits. Note pitch,
velocity, timing, transpose/quantize/duplicate, chords/progressions and undo/redo
operate on original-resolution ticks. `s` and closing save a new JSON document;
`--project experiment.json` reopens it. `:export edited.mid` writes a MIDI file
retaining expression, program/tempo maps, metadata, SysEx and opaque chunks. An
unedited export is byte-for-byte original. A moved note keeps its source port and
note-off identity; edits that would change them are refused.

PPQ files use quarter-note beats; SMPTE files use frames. The grid uses whole source
ticks, and a requested position that cannot resolve to those ticks is rejected.
Format-2 files with several independent patterns require `:pattern N` or an explicit
`--midi-pattern N`. `:channel 1–16` chooses an insertion/selection channel in a
multi-channel track; `:select event-ID` chooses a specific paired note. Chord labels
use note-key intervals and do not infer sustain-pedal voice durations. Shared-key
ambiguity and unmatched input events remain in the original source.

Source audition sends the complete ordered MIDI wire stream to explicitly selected
outputs as described below. Controller/tempo editing and source WAV synthesis
remain unfinished. Existing phrase-project MIDI/WAV transport
continues to work. See [MIDI source semantics](MIDI-SOURCE.md) for retained data,
source-event identities and timing behavior.

### Imported performance audition

Use `--midi-file song.mid --midi-output=ID` (or `:midi-output ID` in the
source editor), then Space to play the selected pattern from its beginning.
Space pauses/resumes; `:stop` releases its held keys and enabled hold pedals.
`--devices` lists exact MIDI output IDs. An imported source with several
MIDI ports requires `:midi-port PORT ID` for each used port; distinct source ports
must bind distinct destinations. Bindings are session selections, not musical
edits saved into the original performance.

Source audition sends ordered MIDI 1.0 channel expression and F0/F7 wire data
using the source tempo map or SMPTE clock. It plays once from the beginning.
Pause/resume and seek restore supported channel state; unknown initial values
and opaque device effects report errors as described in [Source state](SOURCE-STATE.md).
Source looping and source WAV/VST synthesis remain unfinished. Existing
phrase projects retain their pause/resume/seek/loop and SoundFont routes. Stop
closes an in-flight SysEx stream, releases each owned held key and disables hold
controllers 64/66/69 that this source enabled. It never broadcasts all-notes-off.
Use destinations/channels owned for this audition: pedal state is shared by a
MIDI channel, and opaque vendor SysEx can have device-specific side effects that
cannot be reversed generically. Playback does not synthesize MIDI clock.

Open the [arrangement editor](ARRANGEMENT.md) with the score view's `a` key or
`masc-alphatex --arrange`. Import WAV/MIDI sources, then place, trim, repeat,
duplicate and remove regions without changing originals. `--project song.json`
reopens an arrangement; save-as carries its WAV files, including sources retained
by undo/redo. WAV lanes stream overlapping regions; MIDI lanes retain expressive
source playback with trims, finite repeats, pause/resume, beat seek and explicit
asset/port outputs. Mixed WAV/MIDI regions use the [shared native clock](ARRANGEMENT-CLOCK.md).
[Captured takes](CAPTURED-SOURCES.md) attach their original WAV, raw UMP and clock
files with `:import-take DIRECTORY`; Enter opens their waveform/MIDI viewer.
Captured-take region playback and overdubs remain unfinished.

Saved captures also have [paired original WAV/UMP playback](CAPTURE-PLAYBACK.md).
Select MIDI and audio outputs in the take viewer; original MIDI 2.0 words and
capture timing survive full-source audition. Native playback also pauses/resumes
with `p` and seeks audio and supported UMP state together with `:seek SECONDS`.
Captured-region placement and arrangement overdub remain subsequent work.
