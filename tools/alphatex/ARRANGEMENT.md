# MIDI/audio region arrangements

The terminal arrangement editor opens with `masc-alphatex --arrange`, the score
view's `a` key, or `--project song.json` for a saved arrangement. It arranges
retained WAV/MIDI sources independently of the phrase piano roll. WAV regions have
a streamed multi-voice transport, and MIDI regions have an expressive source-state
transport. The [shared clock](ARRANGEMENT-CLOCK.md) plays mixed WAV/MIDI lanes through one
native owner. Overdub integration remains subsequent work; source and phrase
editors retain their separate transports.

## Terminal workflow

After simultaneous audio/MIDI recording, use `:capture-midi [ASSET]` on the
captured take. It selects a new **whole-take MIDI1 variant**; `:edit-midi` opens
it for note/expression editing, `:harmony` and `:revoice`. Return with `q`, then
Enter places the edited asset independently. The original WAV, UMP, host-clock
regions, loop takes and audio/MIDI placement corrections remain unchanged.
Undo removes the derived asset, and save-as carries the raw take and variant.

The variant uses the current arrangement tempo/meter, with nearest 960 PPQ ticks
computed from the same integer microseconds-per-quarter stored in its SMF tempo.
Initial silence uses the complete capture span, including MIDI before the
recording request. Source/group pairs receive separate tracks and numbered
MIDI ports; channels retain their original numbers. Track names identify the
input and group. Bind those ports explicitly for external playback; independent
ports do not collapse into one synth or destination. Recorded bank/program,
controllers, pressure, bend and release velocities remain in the variant.
SysEx7 fragments keep their individual times; system messages use SMF escapes.

This is an explicit MIDI1 projection: MIDI2 channel values lose precision,
sub-tick times round, and transport utility UMP stays only in the raw take.
MIDI2 zero-velocity Note On remains an attack. Per-note/registered expression,
note attributes, compound MIDI2 controllers and unsupported UMP refuse the
conversion rather than being silently omitted. Mixed MIDI1/MIDI2 state on one
source/group/channel, incomplete SysEx and ambiguous or unclosed notes also
refuse it. No synthetic note-off or missing device state is invented. The SMF
retains derivation metadata with source-part hashes, original clock, route map
and projection policy. It does not inherit the audio recording's sound, trim,
take selection or placement correction. Trim/place the new MIDI explicitly.

Import files with `:import-wave /path/take.wav` or `:import-midi /path/song.mid`.
Use `:import-practice /path/take` for a completed raw MIDI practice recording.
With `:output AUDIO_UID`, Space realizes that source through its captured VST
preset. An explicit `:midi-source` override sends its original UMP externally
instead. Derived audio keeps the original host-clock cuts and repeat periods;
source files and saved project identity remain unchanged.
`:practice-backing [ASSET]` restores the take's captured phrase as a new editable
MIDI library asset. Its originally played track is muted; all notes, other track
mute/solo decisions, controls, tempo, meter, loop range and frozen VST sound are
retained. Enter places it at the cursor and `:edit-midi` opens it for chord or
voicing experiments. Undo removes the imported variant without changing the take.
The original full phrase is restored, including notes outside its retained loop;
use `:region` with original MIDI ticks to place a loop excerpt explicitly.
This is an editable musical backing, not recorded monitor PCM or automatic
alignment to the take's host clock. Pass slicing and alignment remain separate.
Use `:practice-midi [ASSET]` to derive what you played as a new expressive MIDI
source. `:edit-midi` opens that selected variant for note/expression edits,
`:harmony` analysis and `:revoice` experiments; Enter places it independently.
This derives the **whole take**, including its initial silence, even when an
original pass region is selected. Existing raw sources, pass cuts and clips
remain unchanged; undo removes the new import. Use source MIDI ticks to trim
the variant explicitly. Its captured VST sound and initial volume/pan are kept.

The variant uses the monitoring path's declared MIDI1 projection onto the
captured live channel. MIDI2 values become MIDI1 values, bank/program changes
remain excluded under the captured preset, and unsupported attributes fail
explicitly. Host times become nearest 960 PPQ ticks using the captured tempo
rounded to SMF microseconds per quarter note. Equal-tick events keep their
original time/order; very short notes can become point notes. The ending is
at least one tick, with generated note/pedal releases at the source boundary.
This is an editing projection; original UMP precision and fractional pass cuts
remain available on the raw take. Long SMF event gaps use empty sequencer
metadata to preserve their time across the 28-bit delta boundary; these padding
events do not produce wire messages or change tempo.
Paths retain internal spaces and are literal paths, without shell expansion.
The imported asset is selected in the library. Enter places its complete source
at the cursor, using the current compatible lane or adding a new one.
`a` cycles library assets; Tab cycles lanes; Up/Down cycles regions on that lane.
Left/Right moves the cursor and Shift+Left/Right moves the selected region by
the grid. `:grid 0.25` sets a quarter-beat grid.

```text
:place asset-1 4                 full source at quarter-note beat 4
:place asset-2 8 2               format-2 pattern 2 at beat 8
:region asset-1 4 1200 4800 2     asset, beat, source offset/extent, repeat
:region asset-2 8 0 2002 1 2      optional final format-2 pattern
:trim 2400 4800                  native source offset and extent
:move 8
:repeat 4
:duplicate 16
:lane-add wave Bass
:lane-add midi Keys
:lane 2
:region-lane 2
:asset asset-1
:select region-1
:save-as /path/song.json
```

Source offsets/extents use whole WAV frames, original SMF ticks or decimal
host-tick strings for raw practice recordings; project
positions use quarter-note beats. Pattern numbers in commands start at 1.
Trim rejects an out-of-bounds range rather than rounding or shortening it.
For practice boundaries between whole host ticks, use
`:practice-region ASSET BEAT OFFSET EXTENT DIVISOR [REPEAT]` or select a practice
region and use `:trim-fraction OFFSET EXTENT DIVISOR`. Offset and extent are
decimal integer numerators in original host ticks divided by the positive
integer divisor. For example, `:trim-fraction 1 4 2` selects `[1/2, 5/2)` host
ticks from the source origin. Normal `:trim` explicitly returns to whole ticks.
These exact cuts survive move, duplicate, undo and save/reopen. They reach both
external original-UMP playback and the captured VST's source-audio clock;
repeats and common loops retain the fractional period without accumulating a
rounded copy length. Packet timestamps/words remain unchanged. Update the
installed AlphaTex/native companion together. Select original practice passes
using the retained output clock:

```
:practice-passes asset-1
:cursor 8
:practice-pass 3 asset-1
:practice-pass 4 asset-1
```

The first command selects that source and reports its available original pass-number range. Selecting a
pass places its MIDI at the cursor; if the selected region uses that source, it
replaces that region's source cut while keeping its position and repeats. Undo
restores the previous performance. Duplicate a region first to retain several
passes for comparison. The status distinguishes a partial first/final pass.
Each boundary comes from the frozen backing's absolute output-frame rounding,
then the retained render frame/host anchor. Original cycle numbers survive a
late anchor; a final incomplete cycle ends at the consumed frame horizon.
This is nominal clock alignment, not physical latency or drift compensation.
The source keeps its original speed and captured tempo; project tempo changes
placement, so choose matching musical positions when combining its backing.
`x`/Delete removes a region, `d` duplicates at the cursor, `m`/`o` toggles lane
mute/solo, and `u`/`y` undoes/redoes document edits. `:lane-remove` retains sources.
`:title`, `:tempo`, `:meter`, `:lane-name` and `:region-name` edit their named fields.
`s` saves; `q`/Escape saves and returns; `?` or `:help` lists commands.

Import and save IO run in an owned worker. Accepted commands remain ordered;
closing refuses new input, cancels an in-progress import, waits for cleanup and
drains already accepted editor decisions. An import finishing after close cannot
replace the document. Save-as materializes WAVs, captured takes and raw practice sources retained by undo/redo history as
well as the current document, so a later redo does not depend on the old folder.
An uncertain/failed save is not automatically retried at the same path on close;
edits are retained at a fresh recovery location. If source corruption prevents
portable recovery, `draft.json` and `sources.json` explicitly retain the edited
document and its original source location without claiming copied assets.

A document contains immutable source assets, typed audio/MIDI lanes and regions.
Regions identify their source and lane, a project position in quarter-note ticks,
a source-native offset/extent and a repeat count. Move, trim, repeat, duplicate
and remove operations change regions without altering sources. Removing a lane
removes its regions but retains its source library. Undo/redo can retain complete
immutable document revisions as the phrase editor does.

Project positions use 960 ticks per quarter and the explicit project tempo.
WAV source offsets/extents use whole sample frames at that source's rate. MIDI
source offsets/extents use the retained SMF pattern's original ticks and tempo
map or SMPTE clock. Format-2 patterns remain explicit zero-based choices in the
core API. Regions run at native speed; changing project tempo moves their project
positions without stretching their contents. `arrangementClipTime` and
`arrangementSchedule` derive explicitly named second values while retaining the
original tick/frame authorities. A schedule keeps repeats compressed and allows
overlapping regions without inventing independent MIDI channel state.

This source/region distinction follows [Ardour's regions](https://manual.ardour.org/working-with-regions/)
and [region properties](https://manual.ardour.org/editing/editing-regions-and-selections/region-properties/).
[Warped audio](https://www.ableton.com/en/manual/audio-clips-tempo-and-warping/) is a
separate timing operation. This model performs no implicit WAV resampling,
stretching, source-tempo rewrite or note-only conversion of expressive MIDI.

## Storage and import

MIDI assets embed the original source document, including original file bytes
and event overlays. WAV import streams a private copy into a project-owned
`assets/<sha256>.wav` file. It retains the complete WAV container, encoding,
sample rate, channels and native frame count. Asset labels do not become paths.
Original WAV files are never linked or edited. Re-imported identical WAV bytes
can share stored content with distinct asset labels/identities.

A copied WAV must pass the existing structural RIFF/WAVE reader before
publication. Publication uses an exclusive hard link of the private copy, which
has its own inode and is made read-only; an existing content-addressed pathname
is verified and never overwritten. A directory or file symlink at the asset
boundary is refused. Import cancellation removes only its owned partial copy.
Streaming copy, content hashing and RIFF metadata reads all observe the caller's
signal. Cancellation at a metadata read stops subsequent chunk reads and closes
the opened source before returning.
A fully published but unreferenced content file can remain after cancellation
or a later project save conflict. Source files are not deleted automatically.

`loadArrangement` verifies every WAV content hash and metadata, including unused
library assets. `saveArrangement` uses the shared project revision/inode
publication protocol. Save-as explicitly takes `sourceRoot`, verifies the original
assets and copies them to the destination project's content store before
publishing JSON. Project-relative source paths survive moving the complete
project directory. A missing or changed asset is an error, not an empty track.
WAV verification is a read-time observation; future playback must own its opened
sources, not treat a returned pathname as an immutable operating-system handle.

Older schema-1 captured assets omitted `midiTime`. Reopen reconstructs only that
missing field from verified project-owned capture files before strict document
validation. All four file hashes, raw packet bounds and manifest/clock provenance
must agree; malformed existing bounds remain errors. Reopen leaves the stored
JSON untouched and retains its original revision for conflict-safe saving. The
next explicit save writes the verified bounds, including null bounds for a
WAV-only take.

The shared musical-document entrypoint routes arrangement documents to their
editor before acquiring phrase-editor terminal, worker or rendering resources.
WAV assets are verified before the arrangement editor acquires raw terminal mode.
Use the arrangement wrappers when working with referenced files: generic JSON
shape validation does not establish that external assets are present. Existing
phrase MIDI export explicitly refuses arrangement documents until a clip-state
export plan is connected.

## Integration contract

MIDI regions reuse the supported source channel-state reconstruction boundary,
retain original source clocks/ports and diagnose physical destination/channel
ownership conflicts before opening outputs. WAV regions use native-rate
conversion/mixing with frame bounds, selected-output ownership and streaming.
The combined route uses the native shared host-clock epoch and paired lifecycle;
this does not establish sample-perfect or acoustic alignment.

Capture import must retain WAV plus original UMP and capture-clock provenance;
exported note-only SMF is insufficient for a simultaneous recorded take. The
import helpers accept WAV, SMF/RMID and complete native captured takes.
[Captured sources](CAPTURED-SOURCES.md) preserve all four original take files and
open their waveform/MIDI viewer. Captured WAV+UMP region playback, recording into
an existing project, overdubs and VST routing remain unfinished integrations.


## WAV arrangement transport

Space plays, pauses or resumes the audible WAV lanes. `:stop` stops the owned
player; `:seek 8` seeks to quarter-note beat 8, including when paused. `:output UID`
selects an explicit CoreAudio output and stops the previous route. Command-line
`--output UID` is forwarded through both new and saved arrangement entrypoints.
Mixed audible WAV/MIDI lanes use `:mixed-output AUDIO_UID` followed by
`:midi-output MIDI_UID` or `:midi-port ASSET PORT MIDI_UID` for every source port.
`--output AUDIO_UID --midi-output MIDI_UID` selects both when opening a new or
saved arrangement. A mixed route also supports solo/mute audition of either
source kind. `:output AUDIO_UID` explicitly returns to audio-only selection.
An explicitly selected MIDI output
never silently switches to the default audio device; select :output explicitly
to change to audio playback.

Preparation runs in the IO worker. It verifies and copies only audible sources
into private read-only files, preserving compressed region repetition counts and
whole source frames. Stop cancels that preparation request; late results cannot
launch a player. Editing the document stops its previous playback revision;
cursor and selection changes leave it playing. Closing waits for the owned
worker, player process and private playback files before restoring the terminal.

The native AVAudioEngine uses one AVAudioPlayerNode per region, native source
formats and mixer rate conversion. All nodes use a common host timestamp, with
one output render quantum reserved per synchronous node start and one for the
next output cycle. A missed start deadline or refill deadline fails explicitly.
Two reusable streaming buffers and a scratch buffer per voice use 64 KiB per
channel rounded up to the output render quantum; small repeated periods can
also be cached within that same bound. Decode storage depends on voice/channel
count, not source length or repeat count. Short AVAudioFile reads are consumed
incrementally. Finite repetitions are filled inside stream buffers rather than
creating a callback per repetition. The last buffer completes at dataPlayedBack.

Pause freezes the observed output render clock and stops scheduled voices;
resume and seek reconstruct the WAV read positions under the same native owner.
The selected output remains pinned by UID; output removal, configuration failure,
source IO failure and malformed commands stop with failure. This path does not
claim audio/MIDI sample alignment, external clock, physical-device latency,
monitoring, whole-arrangement looping, VST routing or overdub recording.
The scheduling contract follows [Apple AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).


## Expressive MIDI arrangement transport

Space plays, pauses and resumes audible MIDI lanes. Select an exact destination
with :midi-output ID for single-port sources, or bind each retained source port
with :midi-port asset-1 PORT ID. Bindings are per asset and session; format-2
regions retain their explicit pattern. :output switches to audio and clears MIDI
selections. In a mixed route, selecting MIDI preserves its audio output; in a
MIDI-only route it clears the previous audio route. :stop and :seek BEAT have the
same ownership semantics as WAV playback.

Native preparation decodes each retained source once. One region cursor retains
its start, native source offset/extent and finite repeat count. Source tempo maps
and SMPTE clocks determine native elapsed time; arrangement tempo only places
region starts. Trims have an inclusive start and exclusive end, except that a
full-source endpoint retains its original final messages. Exact-boundary events
keep their wire order, including zero-length notes and note-off release velocity.
Positive source spans are required for this repeating transport.

Each schema-3 region carries `startNanoseconds` (the project start from region
ticks and the binary64 tempo) and `periodNanoseconds` (the source span from the
SMF tempo map or SMPTE rate) as exact decimal fractions. Both are required.
Copy `k` begins at `ceil(start + k * period)` whole nanoseconds; that one value
is the previous copy's end, the validated region end, the ownership comparison
and the run-time hand-over. `sourceStart`/`sourceEnd` remain the source's own
binary64 event-selection keys, and `startSeconds` only displays the exact start.
A copy's events stay between its edges: one whose binary64 offset rounds onto the
closing edge is sent and released before another owner begins at that instant.
Seeking onto an edge starts that copy. A region whose last edge passes the
64-bit host nanosecond clock, or whose copies last under one nanosecond, is
refused.

Trim, repeat, resume and seek restore supported channel state using the
[SOURCE-STATE contract](SOURCE-STATE.md). A new owner must establish previously
changed fields before sounding keys: a program change after a note at the same
source time cannot provide that note's initial program. Unknown baselines and
opaque system/SysEx or unsupported parameter state fail explicitly. The original
full-source audition remains available separately. Envelopes retrigger.

A physical destination/channel has one active region owner, including its prefix
state. Overlapping ownership is rejected before sending; different channels may
play concurrently on one destination. Region-end cleanup releases only that
owner's keys and pedals. Failed releases retain ownership for final cleanup;
successful releases are not repeated. No all-notes-off broadcast is synthesized.
The source destinations remain pinned and selected removal stops the owner.

When the scheduler misses complete repetitions, it skips never-started expired
copies arithmetically and restores the current phase. It drains at most one
already active copy before releasing it, preserving that copy's pending releases.
Seek also jumps directly to the current copy. Storage and missed-copy processing
do not grow with the finite repeat count. This phase policy differs from the
original full-source audition's complete ordered-stream delivery. Maximum
observed lateness is reported; sample-clock timing and physical latency are not
claimed. Whole-arrangement looping, MIDI2/UMP, VST,
monitoring and recording/overdub remain unfinished integrations.

## Phrase and harmony experiments

Use `:arrange` in the phrase editor after creating notes, `:chord` or
`:progression`. It opens the current audible phrase at beat zero in an
arrangement. The full editable draft is retained with the generated MIDI, so
mute/solo and voicing decisions can be revisited. The backing's tempo and meter
start from the phrase. Closing the arrangement returns to the unchanged parent
draft and its undo history.

Inside an arrangement:

```text
phrase
edit-midi asset-1
edit-midi asset-2 2
cursor 8
place asset-3 8
```

`:phrase` creates a new editable experiment. `:edit-midi` chooses an asset (the
selected asset when omitted) and optionally an SMF2 pattern number. Generated
assets open their phrase draft; original SMF assets open the expressive source
editor. After edits and `q`, a new asset and the edited pattern are selected for
placement with Enter. Explicit `:place` still names an SMF2 pattern when needed.
Existing sources and clips remain unchanged. Parent undo removes that import as
one transaction; redo restores it. Editing without changes adds no asset.

Generated phrase drafts are inline in portable arrangement JSON and verified
against their MIDI export on save/reopen/playback preparation. A separate saved
child draft under `phrases/` is useful on its own but is not needed to reopen the
arrangement. Select placement and independent output channels when layering
variants: copying an experiment does not change its MIDI channel ownership.

## Compare a recorded practice take through a SoundFont

After `:import-practice PATH`, use `:practice-soundfont asset-1 [SF2_PATH]` to
capture a FluidSynth font for that original raw performance. Select an audio
output, then place/trim/repeat the take as usual. `:practice-sound-original
asset-1` restores its captured VST or SoundFont. Undo/redo and save/reopen retain these choices;
the original context, packets and capture receipt are never rewritten.

The declared monitor MIDI1 projection and original host clock remain in use,
including the captured track's initial program, volume and pan. Raw bank/program
messages are retained in the original take but not replayed by this projection.
Explicit external MIDI routing overrides the local audition sound. Newly
recorded bound SoundFont practice takes use their captured font
by default. Live input and practice recording are described in the engine guide. See
[bound SoundFont audition](README.md#bound-fluidsynth-soundfont-audition) for
library, engine, control-block timing and cancellation behavior.
