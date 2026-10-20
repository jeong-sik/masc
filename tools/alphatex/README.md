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

The continuous VST synthesis and [device-clocked PCM output](native/PCM-OUTPUT.md)
layers support live-audition integration. The PCM companion requires macOS15+
and Swift6. It uses the selected output's sample rate and hardware buffer size,
pins that device, and reports underrun rather than silently queuing late audio.
These layers do not yet enable live keyboard monitoring in the piano-roll UI.
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

## MIDI keyboard step entry

In the piano roll, `:step-input` opens a MIDI source picker. Choose with Up/Down
and Enter; `r` refreshes, Esc/q cancels. Refresh retains the selected UID; if it
disappears, choose again explicitly. Discovery opens no audio, capture or output
route. `:step-input SOURCE_UID` still arms a known UID directly. Set the cursor
and track before arming; source documents also need a selected pattern and an unambiguous
channel (`:channel 1–16`). Press keys together, then release all of them: the
chord is inserted in one undoable edit and the cursor advances by note length.
This works in phrase tracks and original-tick PPQ/SMPTE MIDI source tracks.

`:step-stop` drains admitted input; leaving the piano roll also joins input before
the final save. An incomplete held chord is discarded. Manual cursor/track/
channel/project edits stop input, so held notes cannot move into a new
context. Use `:step-input` again after changing context. Stop step entry before
playback, recording, instrument selection or opening the arrangement.

Input groups/channels distinguish held keys and are mapped to the chosen target
track/channel. MIDI2 velocity is explicitly reduced to seven bits; zero-velocity
MIDI2 attacks become the quietest supported note, while MIDI1 note-on-zero is a
release. Source notes retain projected release velocities. Sustain/controllers,
expression and SysEx do not alter step notes. MIDI2 note attributes and repeated
voices that would overlap the same target key fail explicitly. This mode has no
live audio/MIDI echo. Use the recorder for timed playing and raw MIDI2 capture.

`:step-length VALUE` changes only the next input length, without editing an
existing note or adding undo history. `:step-rest [VALUE]` advances the cursor
without making notes; its default is the current input length (the grid step for
source point notes). Both controls work between chords while input is armed;
release all keys first. A manual `:step-stop` begins draining and refuses further
step controls until it completes. Already queued controls remain owned at view
close, before the final save.

Values are exact nonnegative decimals or integer fractions in quarter-note beats,
or frames for SMPTE sources: `:step-length 1/3` is a triplet at phrase PPQ960;
`:step-length 1.5` is a dotted quarter. Values must resolve to whole original
ticks; a PPQ1001 source accepts `1/7` (143 ticks) and refuses `1/2`. Phrase lengths
and rests must be positive; source length `0` creates a point note. `[`/`]` still
edit an existing note at the cursor and stop step input. At a phrase endpoint,
extend the document or move the cursor before starting another chord.

The installed source-only MIDI reader accepts one explicit CoreMIDI source
without an audio input or output route. It retains complete delivered UMP words
and integer host timestamps, acknowledges each asynchronous consumer decision,
and drains admitted input on normal stop.
See [source-only MIDI input](MIDI-INPUT.md) for the protocol, ownership and checks.

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
## Music library

`masc-alphatex --music` opens a plain terminal library for new phrases,
arrangements and audio/MIDI recordings. It also lists JSON projects under
`--project-root` and take directories under `--session-root`. Choose with arrows
and Enter; `q` returns from an editor to the library, then back to its caller.
Returning refreshes the library so a newly saved phrase can be continued.
Use `r` to refresh, `:open PATH` for a saved project, `:midi PATH` to import MIDI,
or `:session PATH` for an existing recorded take. Paths may contain spaces.
Missing library directories are empty; other source failures stay visible
alongside available entries. Closing waits for the active editor's cleanup.

Selecting a saved item reads its details in a separate worker. Phrase details
show the saved title, tempo, meter, duration and tracks; imported MIDI retains
independent pattern durations. Arrangement details describe the document and
its sources, without asserting that external assets can play. Take details
validate the capture files and retain a failed recording's reason. A damaged
item stays selectable with its read failure visible. Moving away cancels the
old inspection and waits for its worker to exit before reading the new item;
opening an editor and closing the library also join that cleanup.

The MASC entry is Dashboard **s** or chat `/music`. It supplies
`<base-path>/.masc/music/projects` and `<base-path>/.masc/music/sessions` as the
workspace library roots. The companion must be updated together with that entry.
This library and its editors do not need Kitty graphics or a score block.
Graphical notation still uses `/score` or the ordinary score-viewer entry.

# Phrase sequencer

From `/score`, press **p** to open the piano-roll editor. It also opens directly
with `masc-alphatex --sequence`; reopen a saved document with `--project song.json`.
The score's **p** and **a** keys carry the current score and selected track (or
all tracks) into MIDI editing and an arrangement respectively. The conversion
uses alphaTab's SMF1 performance, retaining its tempo map, channels and expression
alongside the original alphaTex and track selection. These are editable MIDI
experiments: edits do not rewrite the original notation, and SMF1 does not retain
all simultaneous per-note bend effects. Conversion errors remain errors instead
of opening an empty project. MIDI source audition needs an explicit MIDI output
or a verified VST instrument.
Projects save under `./music-projects` by default (`--project-root` changes this).
An existing recording remains a separate take; the editor's **r** opens the capture
screen and returns to the same phrase. It does not yet overdub into the project.

Move the cursor with arrows; Enter inserts or removes a note. Shift+arrows moves
the selected note. `[`/`]` changes its length, `+`/`-` changes velocity, and `g`
cycles the musical grid. Tab changes track, `n` adds one, `m` mutes it and `o`
solos it. `u`/`y` undo/redo. On macOS, the first audio Space opens the existing
instrument/preset picker. Choose a verified VST instrument or the explicit
SoundFont entry; **i** stops playback and reopens the picker. In the preset view,
**e** opens the native editor and **p** selects a preset file. The selected VST
preset owns the sound; MIDI program/bank messages do not replace it. Instrument,
sample-library or license failures remain visible without a SoundFont fallback.
Phrase and original MIDI documents save their selected sound. Choosing a VST
captures its actual default or loaded preset bytes and instrument identifier/version
without opening its editor. Save/reopen, undo/redo, Save As and phrase-to-backing
snapshots retain that state. Playback loads a private copy of those bytes; changing
or moving the original preset file does not change the saved sound. A different
installed instrument/version is refused. Plug-in binaries, sample libraries and
licenses still need to be installed separately. Project files containing user
presets are local musical documents; consider the preset license before sharing.
Backing MIDI assets retain this sound for reopening in the phrase editor. In an
arrangement, select `:output AUDIO_UID` to play stored VST sounds alongside WAV
backing, or `:mixed-output AUDIO_UID` when other sources use external MIDI.
Explicit `:midi-port ASSET PORT MIDI_UID` bindings override the stored sound for
that asset; `:midi-output MIDI_UID` sends all MIDI assets externally. Each source
and selected SMF2 pattern renders separately with its frozen preset. Original
tempo/SMPTE timing, source trims and repeat periods remain authoritative, including
loop practice and count-in. Stop or exit cancels rendering and waits for the
native process before removing its private files. Independent ports in one source
still require explicit MIDI outputs.
Subsequent Space starts, pauses or resumes the preview; `:stop` ends playback. `l` toggles
repetition of the loop region inside one native AVAudioEngine/PlayerNode. `:seek 4` moves to
quarter-note beat 4. Select an audio output with `--output UID` or `:output UID`;
`--devices` lists CoreAudio device identities. An explicit output is pinned and
read back, and unavailable outputs fail without substituting another device.
The decoded WAV must fit the native PCM buffer resources. See the
[transport protocol](native/TRANSPORT.md) for lifecycle and resource limits.
VST playback retains its performed MIDI, WAV and render hashes under `--state-dir`
(the same default as the score picker), and publishes the latest local state for
the Lane observer. Player acknowledgement is not proof of audible output or a
Lane action receipt. Loop rendering omits the release tail so repetition does
not insert an extra tail interval. Nonloop playback includes the instrument tail;
the musical playhead stays at the phrase end during that tail. `:wave PATH`
exports the currently selected audio instrument.

Imported single-port MIDI can use the same VST route, including the chosen SMF2
pattern and SMPTE timing. The original source document is retained; a synchronous
PPQ performance copy is rendered. Independent source ports require separate VST
instances, which are not connected yet; use their explicit MIDI output bindings.
Source clip looping still requires expression-state reconstruction. These
remaining routes are part of the broader music/TUI work.
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

For part of a phrase, `:select-notes START END [LOW HIGH]` selects complete notes
whose onsets lie in `[START, END)` and whose keys lie in the inclusive pitch range
(for example, `:select-notes 0 4 C3 B4`). It keeps their full lengths, including
tails beyond END. `:select-all` selects the current track/channel, including
zero-duration source notes. The piano roll marks selected notes and reports their
count. Cursor movement retains the selection; changing track, source channel,
pattern, entering an event view, or undo/redo clears it. Esc or `:clear-selection`
clears it before further single-note insertion.

`:copy-notes` snapshots the selection into this editor session's note clipboard.
`:cut-notes` copies and removes it in one document revision; `:delete-notes`
removes it. `:paste-notes [AT [SEMITONES]]` pastes at the cursor or explicit
position, optionally transposed, and selects the new notes. A range selection's
START anchors the copy, retaining leading silence; select-all anchors its first
onset. Pasting across tracks uses the target phrase track's instrument/channel.
`:move-notes OFFSET SEMITONES` moves all selected notes together. Every document
operation is one undo step; overlap, register, timing or route errors leave the
document and clipboard unchanged. The clipboard survives track/pattern changes
and undo/redo but is not saved in the musical document or shared with other editor
sessions or the operating system.

Ctrl+A selects all; Alt+C/X/V copies/cuts/pastes when the terminal forwards Alt as
Meta (the commands always work). Ctrl+C retains its exit action. Shift+arrows
move the selected group using original integer ticks; x/Delete removes the group.
Enter requires clearing a selection before toggling one cursor note. Length and
velocity keys still edit the single cursor note; `:transpose`, `:quantize` and
`:duplicate` still apply to the complete track.

Imported MIDI uses its original PPQ/SMPTE units for selection and paste positions.
Copies retain onset offsets, durations (including points), attack/release dynamics
and NoteOff versus zero-velocity NoteOn release form. Without an explicit target
`:channel`, source copies keep their channels; a selected channel remaps the
copied notes together. Source-port changes at either pasted endpoint are refused.
These commands select and copy **notes**: controller, pressure, program, tempo,
SysEx and other original events remain in place, including keyed poly-pressure.
Use the expression/tempo editor for those events. Copying notes does not claim to
reproduce pedal-extended sound or an instrument's state at a new position.

The note-versus-region distinction also appears in the
[Ardour note selection manual](https://manual.ardour.org/editing-and-arranging/edit-midi/note-selection/).
`tempo 120`, `length 32` and `meter 3 4` set project timing. MIDI/WAV export refuses
existing files. `level 100` and `pan 64` set the selected track's MIDI volume and
pan (0–127; pan 64 is center). Dense mixes can clip; lower track levels when the
preview/export reports clipped samples. The broader destination and remaining work are recorded in
[the sequencer design](../../docs/design/tui/MUSIC-SEQUENCER.md).

To compare voicings of existing notes, put the cursor inside the chord and use
`:revoice Cmaj7 drop2 4 0`: symbol, close/drop2/rootless, optional octave and
inversion. It changes the selected track's sounding voices from low to high,
retaining each note's identity, onset, duration and velocity. `u`/`y` compares
the before/after versions. Other tracks and notes outside the cursor stay intact.
The target must have the same number of voices; use `:chord` to compose a
different voice count. Overlaps and unsupported voicings leave the draft intact.

The same command edits imported MIDI in its source clock. Choose `:channel N`
when several channels sound, or `:select event-ID` to anchor a source port and
channel. Note-on/off pairs and release velocities survive export; tempo,
controllers and other expression messages retain their original bytes. In
particular, polyphonic pressure keeps its original key rather than being
reassigned to the new pitches. Chord candidates remain analysis of sounding
keys, not sustain-pedal voice durations or a unique harmonic interpretation.

`:harmony` or `:harmony mix` opens a worker-produced timeline of key-set changes,
including rests. Phrase mix analysis follows mute/solo; imported MIDI uses the
chosen pattern's tracks. `:harmony track` inspects the current track, including
a muted phrase track, and honors an imported MIDI channel selection. Different
source ports in that scope contribute their keys together. Positions retain
phrase beats or the original MIDI PPQ/SMPTE axis. Zero-duration source notes
appear as point events rather than being stretched into sounding intervals.

Up/Down selects an interval. Enter returns to the piano roll at its original
tick and lowest key, keeping the current track so `:revoice` can compare a
voicing there. Esc/q closes the analysis. Ordinary note-editing keys are owned
by this read-only list; commands remain available. Document, pattern, track or
channel changes cancel its result, and a late worker cannot reopen it. The
analysis uses exact key durations and Tonal candidates; it does not infer pedal
extension or resolve an ambiguous chord to one answer. No attack-window
threshold is used to group nearby notes. `:harmony-export PATH` writes all rows,
notes, candidates, scope and clock units as JSON, refusing an existing file.


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

Source audition can render a selected single-port performance through a VST or
send the complete ordered MIDI wire stream to explicit outputs as described below.
Choose a VST with `i`; `:wave PATH` exports its rendered performance. Source
SoundFont synthesis remains unfinished.
See [MIDI source semantics](MIDI-SOURCE.md) for retained data,
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
Source clip looping remains unfinished. The VST route instead pauses and seeks
within its rendered audio; its `:wave` export uses the selected source pattern.
Editable phrase projects retain their loop and SoundFont routes. Stop
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
Captured takes can be placed, trimmed in seconds, repeated and saved as paired
regions. `:play-audio` explicitly auditions the WAV portions on the captured
clock, including delayed starts, silent tails and compressed repeats; it sends
no MIDI. Ordinary Space playback uses [paired MIDI2/WAV regions](CAPTURE-UMP-REGIONS.md)
with selected audio/MIDI outputs and per-input `:midi-source` overrides.
[Hybrid arrangements](HYBRID-ARRANGEMENT.md) combine SMF, captured MIDI2 and WAV
under one clock. [Record audio and MIDI against backing](ARRANGEMENT-RECORDING.md)
with `:input UID`, `:record`, and `:record-stop`. Use `:monitor AUDIO_OUTPUT_UID`
for selected audio input monitoring, including monitored recording.
See [captured audio timing](CAPTURE-AUDIO-CLOCK.md).

Saved captures also have [paired original WAV/UMP playback](CAPTURE-PLAYBACK.md).
Select MIDI and audio outputs in the take viewer; original MIDI 2.0 words and
capture timing survive full-source audition. Native playback also pauses/resumes
with `p` and seeks audio and supported UMP state together with `:seek SECONDS`.
Captured regions also use the ordinary arrangement transport and recorded takes
can be attached while the backing epoch remains continuous.


In the arrangement editor, `:inputs` lists MIDI inputs and outputs as well as
audio interfaces. `:midi-monitor SOURCE_UID DEST_UID [GROUP CHANNEL ...]` enables
live MIDI input to the selected native MIDI 2.0 instrument. Groups and channels
in this command run from **1 to 16**; `:midi-monitor 1234 5678 1 2` forwards
channel voice messages in group 1/channel 2. Omit pairs to forward all complete
delivered messages. Channel scopes filter system/SysEx; recording independently
retains the whole original delivered UMP source. Input delivery requests protocol
2 and CoreMIDI may convert a source; no MIDI1 destination conversion is selected.

Repeat the command for additional source/destination routes. Repeating one pair
replaces its scope. `:midi-monitor remove SOURCE_UID DEST_UID` removes a pair;
`:midi-monitor off` closes every live route. Monitoring can run with stopped or
playing backing and simultaneous WAV/MIDI recording. Changing a live route does
not finalize the recorder. Backing and live routes must own disjoint physical
destination/group/channel state, including replayed source prefixes. Native
preflight uses the actual playback parsers, not track names; conflicting routes
fail before a new backing/live combination is admitted. Route replacement,
backing restart, source-view suspension and exit wait for owned live process
closure and scoped cleanup. A live route that fails to open drops only that
route; already-open live routes stay connected and are not closed and reopened.
See [native MIDI transport](native/MIDI-TRANSPORT.md) for protocol details.

### Audio loopback calibration candidates

In the arrangement view, stop playback and select an input with `:input AUDIO_UID`.
Connect the chosen output channel back to the chosen input channel, then run
`:calibrate OUTPUT_UID INPUT_CHANNEL OUTPUT_CHANNEL MAX_LAG_MS`, for example
`:calibrate BlackHole2ch_UID 1 1 250`. Channels start at 1; the positive final value
is the symmetric search span in milliseconds. The experiment sends two quiet
windowed chirps on that output channel, records the selected audio input without
software input monitoring or MIDI subscription, then compares the recorded
samples with the actual native playback host-clock anchor. Existing live routes
and input monitoring drain before measurement and resume afterward. Esc/q cancels
and returns after child/file cleanup. Other queued edits wait for measurement.

The unique `calibrations/` directory beside the arrangement contains the exact
reference WAV/plan, capture WAV/block timestamps, playback epoch and
`measurement.json`. It reports each pulse's signed residual, correlation/polarity,
input/output UIDs/sample rates, sample resolution and pulse disagreement. These
are **unapplied candidates**: unrelated input/noise may yield a weak or ambiguous
correlation. Inspect both matches and the saved audio; no threshold silently
accepts a candidate or changes recording placement. Silence, changed identities,
invalid clocks or cancellation cannot publish a successful result. Original audio
and host clocks are preserved; `:import-take .../calibrations/ID/capture` can open
the captured waveform through the existing take flow.

Residual means captured sample time minus scheduled playback sample time, so it
can be negative after the system's own presentation compensation. Device-reported
latency remains separate from this measurement. Virtual loopback validates the
measurement path; it does not prove physical/acoustic roundtrip, sub-sample
accuracy, MIDI latency or calibrated compensation. Explicit compensation and
clock-based practice/count-in remain subsequent work.

### Separate captured audio and MIDI placement

Select a paired captured region and run `:split-take`. One undoable edit keeps the
audio in its lane and adds a MIDI lane/region using the same original immutable
WAV, manifest and UMP source. Select either separated region and run
`:capture-offset SIGNED_MS`: positive values advance that component; negative
values delay it. For example `:capture-offset 15.25` advances only the selected
component by 15.25 ms. This is an explicit **manual** correction, not an adopted
calibration result. Repeat the command to replace the offset, or use `0` to clear
its timing effect. Undo/redo, duplicate, trim and portable save/load retain it.

The other component and original raw source remain unchanged. Playback clips at
project zero: complete negative copies are skipped arithmetically, the first
partial copy is cut inward on original host ticks, and remaining repetitions stay
compressed. Source material is retained in the asset. A delay can extend the
arrangement end; moving an entire component before zero can leave nothing to
play. Separated audio needs no MIDI route; separated MIDI opens no WAV voice.
The native plan explicitly marks separated components while original paired
clock/source checks remain strict. Source viewing still shows the original take.

Measured candidate adoption with compatible device/channel/sample-rate evidence,
recording-wide correction settings and native-clock practice/count-in remain
subsequent work. An audio loopback measurement must not silently shift paired
MIDI or be reused across unmeasured channels/devices.

### Captured input and output channels

For a separated audio component, `:capture-channel INPUT OUTPUT` sends just that
1-based original WAV input channel to the selected output channel. For example,
`:capture-channel 2 1` sends input 2 to output 1 and silences every other output
channel for that region. `:capture-channel all` restores original multi-channel
playback. The chosen physical output must have the requested channel; an invalid
route is refused before playback. MIDI remains a separate original component.

Duplicate an audio region to route additional source channels, then give each
region its own position/manual offset, lane, mute or solo setting. Routes survive
save/load and undo/redo without changing WAV samples, raw UMP or original clocks.
The complete source remains available when opening the take. Source and output
buffers retain their own channel counts, so mono input can target a stereo
output without duplicating the signal onto the other channel. This routing is
the per-channel prerequisite for measured calibration adoption; measurement
inspection/adoption and recording-wide calibration policy remain subsequent work.

### Inspect and adopt an audio calibration

Select a separated audio component, choose its `:capture-channel INPUT OUTPUT`
route, and select the measured playback output with `:mixed-output OUTPUT_UID`.
Use `:calibration-open /path/to/calibrations/EXPERIMENT` to inspect a saved
`:calibrate` experiment. The IO worker snapshots its seven evidence files,
regenerates the known reference and recomputes both matches from recorded PCM
and host clocks. Changed candidate numbers, reference data or captured bytes
are errors. Both signed residuals, correlations, spread and sample resolution
are shown before adoption; no confidence threshold or average is applied.

`:calibration-apply 1` or `:calibration-apply 2` explicitly replaces that audio
component's placement with the chosen pulse's exact signed residual. Positive
values advance audio; negative values delay it. This is one undoable edit and
never moves MIDI. The source input UID/rate, unmonitored capture and selected
input/output channels must match. Playback also requires the measured output
UID, sample rate and CoreAudio hardware buffer size. To choose different channels or a
manual value, use `:capture-offset 0` (or another manual offset) first.

The portable document embeds the original measurement record, inspected
clock/pulse summary and all evidence content hashes. Its hash and device/pulse
fields must still agree on reopen, with no external pathname dependency. SaveAs/reopen therefore
retain the adoption decision even if the original experiment is moved. Keep the
original experiment for full PCM reanalysis. A saved decision is historical
measurement evidence, not a promise that cable paths, input hardware settings or
monitoring configuration remain unchanged: remeasure after changing that setup.
This is explicit captured-component playback placement; recording correction
policy and count-in remain separate work. No audio measurement is reused as a
MIDI or acoustic latency guarantee.

### Choose correction for new arrangement recordings

Select `:input AUDIO_UID` and `:mixed-output OUTPUT_UID`, then choose a next-take
policy before starting playback and `:record`:

- `:record-correction none` retains paired audio/MIDI placement with no correction.
- `:record-correction manual MS IN_CH OUT_CH` selects an exact signed audio
  advance and one input/output channel route. Positive values advance audio.
- `:record-calibration DIRECTORY` verifies a retained experiment and displays
  both pulses. `:record-correction pulse 1` or `2` explicitly selects one measured
  residual and its channel route. This requires matching input/output devices
  and monitoring off. The actual backing output rate/buffer and opened capture
  input/channel/rate are checked again when recording starts.

The selection is an undoable project setting, saved with the arrangement. Input
or output changes require a matching selection or `none`; existing regions keep
their placements. Each recording freezes its own policy and fresh native playback
epoch. A request record beside the take directory preserves that choice before
inputs open; finalized take/alignment records retain it for recovery. Changing a
policy finalizes the current recording before adopting the next choice.

On successful attachment, a corrected take creates separate audio and MIDI
regions in one undoable transaction. Its existing inward-aligned recorded
interval receives the audio placement once; raw WAV, UMP, manifests and clocks
remain unchanged, and MIDI keeps its original alignment. The complete take stays
available for later trimming. Undo/redo and SaveAs/reopen preserve both the chosen
next-take setting and each take's historical decision. Reattaching an already
attached recorded asset is refused. This changes recorded-region placement;
monitoring latency, physical interface timing and MIDI input timing still require
separate measurement. Native-clock count-in and metronome are available as described below.


### Count-in and metronome

In the arrangement editor, `:practice 1 on` selects one count-in bar and a
metronome during backing playback. `:practice 2 off` counts two bars, then stops
the click while backing continues. `:practice 0 off` disables both. The setting
is undoable and survives saving/reopening. Each meter denominator is one click;
the first beat of every bar is accented. Tempo changes affect the next start.
MIDI-only arrangements also require `:mixed-output AUDIO_UID` for the click.

With practice enabled, `:record` from stopped starts backing and admits recording
after its native playing acknowledgement. Count-in audio and backing share the
native render clock. Musical position remains at zero during count-in; the
recording's acknowledged future downbeat trims only the placed region's pre-roll.
The complete recorded WAV/MIDI remains available. Pause/resume retains the
remaining count-in; `:seek BEAT` goes directly to that musical position. Stop and
a fresh play restart the count-in. Source notes, capture timestamps, offsets and
calibration settings remain unchanged. The shared playback horizon rounds outward
to contain exact MIDI ends; its final representable tail is silence. Physical input readiness still depends on
the selected device; a short count-in cannot guarantee a slow interface opens
before the downbeat.

### Move phrase experiments into backing

In the phrase editor, `:arrange` opens a backing arrangement with the current
phrase placed at beat zero. Its tempo, meter, audible MIDI and editable draft
travel together. `q` saves that arrangement and returns to the same phrase draft,
including its cursor and undo history. Later phrase edits create a new snapshot;
existing backing does not change silently.

The original MIDI editor also supports `:arrange`: its complete edited source,
tempo map, expression and MIDI port bindings travel with the region. Independent
SMF2 performances require an explicit `:pattern N`; only that performance is
placed, while the asset retains the whole original file. Score-derived sources
retain the original alphaTex and selected tracks through save and reopen.

In an arrangement, `:phrase` opens a new phrase laboratory. `:edit-midi ASSET`
opens a generated asset's editable phrase or an imported asset's original MIDI
editor. For an independent SMF2 pattern, use `:edit-midi ASSET PATTERN` (starting
at 1), or select a region that already names the pattern. On return after edits,
the arrangement receives a new MIDI asset in one undoable transaction. Existing
assets and regions keep their original data. Enter places the new asset and its
edited pattern at the cursor; choose another position or output when comparing variants that share
MIDI channels. No edits means no extra asset.

Generated assets store the complete editable phrase beside the existing MIDI
export. Save, reopen, editing and playback preparation verify that both agree.
Their child draft is also saved in `phrases/` beside the arrangement, and the
portable arrangement remains editable if that separate file is later moved.
Original MIDI variants preserve the full source document and expression events;
they are not reduced to generated phrase notes. Input monitoring and backing
owners close before another editor takes the keyboard; close/cancel cannot open
a late child or import a stale variant.

### Edit original MIDI expression

Open imported MIDI or use `:edit-midi` in an arrangement. `:events` switches
between notes and the expression list for the current track/channel. Up/Down
selects an event; Enter opens its value for editing; `+`/`-` changes that value;
Shift+Left/Right moves it by the current grid; `x`/Delete removes it. `u`/`y`
undoes/redoes document changes. The list includes event IDs, source positions,
ports and channels. `:event ID` selects an event directly.

```
channel 1
cc 74 99 0.25
bend 12345 0.5
program 33 0.5
pressure 64 0.5
poly-pressure C4 63 0.5
event-value 80
event-move 1
event-set cc 11 90
event-channel 2
event-remove
```

Insert commands accept an optional source position (the cursor when omitted).
Positions use beats for PPQ sources and frames for SMPTE sources, resolving to
whole source ticks. Select a channel before inserting into an ambiguous track.
Program, controller and pressure values use MIDI's 0–127 wire numbers; pitch bend
uses 0–16383 with center 8192, following the
[MIDI Association's channel message table](https://midi.org/expanded-midi-1-0-messages-list).

Each command edits one explicit event. Existing same-tick event order is retained;
new events follow existing events at the same tick. Bank selection, RPN/NRPN and
other controller sequences are not automatically combined or rewritten. Moving
an existing event across a source port change is refused. Notes, unrelated
patterns, SysEx and metadata remain in the original performance; export and
arrangement variants carry the selected edits alongside the original bytes.

When consecutive clips share an output/channel, the existing transport requires
explicit source-start values for channel fields changed by the preceding clip.
If an experiment moves or replaces its only initial controller/bend event, insert
the intended initial value at zero (for example, `:cc 1 0 0` or `:bend 8192 0`),
before its first note, or choose an independent output. Insertions follow existing
events at the same tick: when the first note is already at zero, edit an existing
initial event or explicitly order the inserted event before that note. An
unspecified initial state is refused rather than replaced with an assumed
instrument setting.

Use `:event-before first-note` to put the selected expression before the first
NoteOn at its exact source tick, track and channel. `:event-before EVENT_ID`
instead places it before a specific same-tick event, including another controller
or program message. This changes wire order without shifting source ticks, notes
or tempo. For example:

```
cc 1 0 0
event-before first-note
bend 8192 0
event-before first-note
```

Only expression events move. Notes, metadata and SysEx keep their mutual order;
an order that changes a source port is refused. `:event-order-reset` restores
natural order for the selected event's entire track/tick group. The stored group
is reconciled when events are inserted, retimed or removed, so there are no
dangling event anchors. Save/reopen, source export and arrangement variants retain
the explicit order; undo/redo restores the complete document revision.


### Imported MIDI tempo experiments

`:tempos` opens the selected performance's tempo map. Up/Down selects an event,
Enter edits its BPM, `+`/`-` changes it, Shift+Left/Right moves it by the current
grid, and `x` removes it. `:tempos` returns to the piano roll. Each row reports
its source ID, track, tick position, effective BPM and encoded microseconds per
quarter note. On SMPTE sources these events are metadata; frame timing stays fixed.

Use `:tempo BPM [AT]` to change the unique existing tempo event at that exact
position, or insert one if none exists. AT uses source beats (PPQ) or frames
(SMPTE), and defaults to the cursor. New tempo events go into the first track
for SMF0/1, or the explicitly selected SMF2 pattern. The map includes existing
tempo events on all tracks of the selected performance; original events keep
their source track. If several events share the tick, select an exact ID with
`:tempo-event ID` and use `:tempo-value BPM`, `:tempo-move AT` or `:tempo-remove`.
The last tempo event in source playback order at a tick governs the next span;
editing does not silently collapse simultaneous events.

```
tempos
tempo 90 0
tempo 120 4
tempo-event new:1
tempo-move 3
undo
```

BPM is rounded to the nearest positive 24-bit microsecond value; the map shows
the resulting effective BPM. Values outside that encoded range are refused.
Removing every tempo event restores SMF's implicit 120 BPM. Edits preserve note
ticks, release messages, expression order, MIDI ports, non-tempo metadata, SysEx,
opaque chunks and the immutable original bytes. PPQ playback seconds and backing
region duration follow the edited map. Undo/redo, source save/reopen, MIDI export
and portable immutable arrangement variants retain the map. General metadata
and external MIDI clock editing are separate features.

### Continuous arrangement range practice

`:loop START END` stores an enabled loop range in arrangement beats; `:loop off`
restores one-shot playback. These are immutable document edits with undo/redo and
portable save/reopen. Original WAV, SMF and mixed WAV/SMF arrangements can loop.
Captured audio loops through `:play-audio`, or normal
playback when only audio components are audible. Original host-clock gaps,
source trims, channel routing and fractional placement corrections remain intact.
Normal paired captured MIDI/WAV and hybrid SMF/captured arrangements also loop
on that same authored clock. Raw MIDI 1.0/2.0 UMP words, source host ticks,
finite source copies and exact placement remain intact. Only reached MIDI
channel state is reserved against live inputs; silent destinations are omitted.
Pause, seek, resume and stop retain the audio/MIDI owner and private source files
until its child closes. MIDI destinations must support native MIDI 2.0 for
captured UMP; reachable unsupported reconstruction state is refused explicitly.
`:practice BARS on|off` adds a one-shot count-in before the repeating backing and
optionally a metronome during it. WAV, SMF and captured sources keep their original
placements; the backing shares one future audio/MIDI start after the intro.
The click follows the original meter denominator and bar accents inside the
chosen range, including a partial bar. Pause/resume retains the remaining intro;
seeking goes directly to the backing, and seeking the range end wraps to its
start without another count-in. Stop/new play starts a fresh intro.
`:record` also works while looping. `:record-stop` retains every pass on a
separate take lane at its original loop position; only the last pass is selected.
The complete captured WAV/UMP is retained once. `:takes` lists the available passes;
`:take N|next|previous` switches their audio and MIDI together. Lane mute/solo
remain independent. Count-in material is excluded from the placed
passes, and audio correction is applied before determining their cycle cuts.

For example, `:loop 4 12` repeats that passage continuously on the selected audio
or MIDI output until stopped. It starts at beat 4. Pause/resume and `:seek BEAT` retain
one native owner; seek positions use original arrangement beats and must lie
inside the range, with its end wrapping to its start. Editing the range stops
the admitted playback before adopting the new document.

WAV playback retains original integer frame trims and finite clip repeats.
Each source-rate stream samples the authored loop phase on one rational beat
clock, including silence before/after its clip. The selected source frame is
the frame containing that phase (rounded down); half-open source ends remain
excluded. Cycle boundaries derive from absolute sample positions, so a
nonintegral period alternates its frame boundaries instead of accumulating a
rounded period. The same engine and two reusable buffers per voice continue
through every wrap. Storage is independent of session length and clip repeat
count, with an optional bounded cache for a short source period.

Without practice clicks, SMF-only preparation clips regions to one cycle without rewriting source files or
expanding repeated copies. A leading/trailing partial repeat and the compressed
whole copies keep original source seconds, release messages and port bindings.
Pieces are cut on the exact region grid, so adjacent pieces share one exact edge;
the native cycle may include a silent tail under one nanosecond from rounding
the last edge up, without widening source trims. A late callback skips unacquired attacks from an expired loop copy,
preserves owned key releases and expression history, and resumes at the current
cycle phase. Exactly due endpoint events retain their original order.
Native admission checks controller/bend/program/pressure baselines across the
last-to-first transition as well as between regions. An unspecified value is
refused instead of leaking the previous cycle's state or guessing a device
reset. Muted/solo lanes and assets outside the chosen range retain their source
data.

Mixed WAV/SMF playback retains the original absolute MIDI regions rather than
repeating the SMF-only projected trim envelope. Both engines use the WAV owner's
same authored rational cycle and common start epoch. MIDI host deadlines derive
from that epoch for every cycle, including after missed callbacks; neither owner
cold-restarts at wraps. Partial source cuts remain half-open, original source-end
messages survive, expired attacks are skipped and acquired releases stay owned.
Cross-cycle baseline admission uses only source state reachable within the
selected window, including prefixes needed to restore held notes. Pausing and
seeking stage both owners; either source/output failure stops the joint owner.
Captured sources, clicks, cycle-aware recording and physical timing evidence
remain separate work.
