# Captured WAV and MIDI sources

An arrangement can retain a complete native music-session take. In the arrangement
editor, use `:import-take /path/to/take`, then Enter or `:open-take` to open the
selected capture. `:open-take asset-1` selects an explicit imported capture.
Literal paths preserve internal spaces; shell expansion is not performed.

The take viewer shows the WAV waveform and MIDI source/group/channel tracks.
Space auditions its WAV; selecting a MIDI output enables [original paired WAV/UMP
playback](CAPTURE-PLAYBACK.md). `o` selects MIDI and `a` selects audio output. `e` exports one MIDI
2.0 Clip per source into a fresh directory under the project's `exports/` folder.
`q` or Escape returns to the arrangement. Starting another recording with `r`
writes a separate take under the project's `recordings/` folder; it does not
record against the arrangement or attach that new take automatically.

## Portable original material

Attachment copies all four original files, preserving their bytes:

| Native file | Content retained |
| --- | --- |
| `session.json` | Complete manifest, input/source identities and capture clock |
| `audio.wav` | Original WAV container and sample frames |
| `audio-blocks.jsonl` | Audio host times, device sample times, frame offsets and peaks |
| `midi.ump.jsonl` | Original UMP words, source identities, timestamps and timestamp origins |

The project stores a typed capture asset with four SHA-256 identities and the
complete decoded manifest. Audio uses `assets/<sha256>.wav`; the other parts use
`assets/<sha256>.capture`. Copies have independent inodes from the input files
and are made read-only. Original recording files are never changed. Identical
content may share one project-owned file. Failed or cancelled attachment removes
its private partial files; already published unreferenced content can remain.
There is no automatic source deletion.

Attachment validates the native manifest, contiguous audio frame coverage, WAV
format/frame count, MIDI packet count, declared MIDI sources and first audio host
time. It preserves the integer host clock and timebase instead of reconstructing
provenance from floating point display times or exported note-only MIDI.
A failed native take retains its failure state and original partial material when
that material is internally consistent.

Reopening verifies every part's hash and data, including unused library captures.
Save As copies captures retained by the current document and undo/redo history.
The complete project folder can move, and removing the original recording folder
does not remove its attached sources. Move the JSON and its `assets/` directory
together.

Opening a capture verifies and creates a separate private snapshot. The viewer
owns that snapshot through WAV playback, export and shutdown; it never writes
exports into project assets or temporary snapshot storage. Arrangement playback
finishes before the viewer borrows terminal input. Returning restores the parent
input owner. Root cancellation aborts the viewer and waits for its owned work
before deleting the snapshot and restoring the terminal.

## Remaining transport integration

A captured asset is currently a source-library attachment. Enter opens its take
viewer; `:place` explicitly refuses it. WAV+UMP region placement, MIDI 2.0 region
state reconstruction, monitoring, and overdubbing an
existing arrangement are subsequent work. Attaching a capture does not convert
its UMP to SMF or silently play only its WAV as an arrangement region. Existing
WAV/SMF region transports continue through their own explicit routes.
