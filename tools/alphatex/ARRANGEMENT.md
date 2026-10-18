# MIDI/audio region arrangements

The terminal arrangement editor opens with `masc-alphatex --arrange`, the score
view's `a` key, or `--project song.json` for a saved arrangement. It arranges
retained WAV/MIDI sources independently of the phrase piano roll. Arrangement
playback and overdub integration remain subsequent work; the current source and
phrase editors retain their separate transports.

## Terminal workflow

Import files with `:import-wave /path/take.wav` or `:import-midi /path/song.mid`.
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

Source offsets/extents use whole WAV frames or original MIDI ticks; project
positions use quarter-note beats. Pattern numbers in commands start at 1.
Trim rejects an out-of-bounds range rather than rounding or shortening it.
`x`/Delete removes a region, `d` duplicates at the cursor, `m`/`o` toggles lane
mute/solo, and `u`/`y` undoes/redoes document edits. `:lane-remove` retains sources.
`:title`, `:tempo`, `:meter`, `:lane-name` and `:region-name` edit their named fields.
`s` saves; `q`/Escape saves and returns; `?` or `:help` lists commands.

Import and save IO run in an owned worker. Accepted commands remain ordered;
closing refuses new input, cancels an in-progress import, waits for cleanup and
drains already accepted editor decisions. An import finishing after close cannot
replace the document. Save-as materializes WAVs retained by undo/redo history as
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

The shared musical-document entrypoint routes arrangement documents to their
editor before acquiring phrase-editor terminal, worker or rendering resources.
WAV assets are verified before the arrangement editor acquires raw terminal mode.
Use the arrangement wrappers when working with referenced files: generic JSON
shape validation does not establish that external assets are present. Existing
phrase MIDI export explicitly refuses arrangement documents until a clip-state
export plan is connected.

## Integration contract

A trimmed MIDI region needs note/controller/SysEx state reconstruction at its
source start. The one-shot source audition sender is not that reconstruction
engine. Arrangement playback must preserve region/source ports, diagnose shared
channel conflicts, and own note/pedal cleanup before claiming arbitrary MIDI
region playback. Audio regions need native-rate conversion/mixing with frame
bounds, selected-output ownership and long-arrangement streaming. A persisted
region arrangement alone proves none of those transport scenarios.

Capture import must retain WAV plus original UMP and capture-clock provenance;
exported note-only SMF is insufficient for a simultaneous recorded take. The
current import helpers accept WAV and SMF/RMID files; capture attachment,
recording into an existing project, overdubs, VST routing and shared clock
alignment remain unfinished integrations.
