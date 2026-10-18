# MIDI/audio region arrangements

`arrangement.mjs` and `arrangement-files.mjs` supply the document and storage
boundary for arranging sources. The terminal clip editor, arrangement playback
and overdub integration are subsequent work; the current source/phrase editors
and their transports remain separate. This core does not claim a delivered
arrangement screen or simultaneous audio/MIDI transport.

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

The shared musical-document save/load decoder accepts the arrangement schema.
Opening one in the current phrase/source editor is explicitly refused before
terminal raw mode, workers or temporary rendering resources are acquired.
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
