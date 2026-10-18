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

The project stores a typed capture asset with four SHA-256 identities, the
complete decoded manifest and the minimum/maximum original MIDI host timestamps.
Audio uses `assets/<sha256>.wav`; the other parts use
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

## Place and edit a paired region

`:place asset-1 4` places a complete captured take at quarter-note beat 4, on a
capture lane that retains WAV and MIDI together. `:place` places the selected
capture; Enter still opens its original source viewer. Use seconds to choose a
source window:

```text
:capture-region asset-1 4 0.5 2 3
:trim-time 0.75 1.5
:repeat 4
:duplicate 16
```

The first command places the two seconds starting at source second 0.5 at beat 4,
repeated three times. Move, duplicate, remove, rename, mute/solo, undo/redo and
Save As work as for other regions. Repeats remain one compressed record. Project
tempo moves beat positions without stretching source audio or MIDI.

Source second zero is the earliest of requested capture start, first audio and
first MIDI, including MIDI pre-roll. Captured `offset`/`extent` persist as decimal
integer host-tick strings; `:region ASSET BEAT OFFSET EXTENT [REPEAT]` and `:trim`
also accept these exact native units. Decimal seconds are rounded inward to
host ticks. Original timestamps and frame counts never pass through a floating
point clock origin. This retains the two time representations described by
[Apple's AVAudioTime documentation](https://developer.apple.com/documentation/avfaudio/avaudiotime).

Regions select MIDI timestamps in `[start, end)`. A complete-source bound includes
one host tick after the final MIDI packet and rounds the WAV end upward, so the
final event and all complete audio frames fit. Audio intersects the chosen
interval by rounding its first frame upward and its end frame downward; only
whole frames fully inside the cut are admitted. A subframe interval can contain
MIDI with no audio frames. Audio start offsets retain the original first-audio
delay. First/last MIDI times are verified against raw source packets during
import, reopen, Save As and source-view preparation.

## Paired region playback

Space prepares captured and ordinary WAV lanes together through the IO worker.
Choose `:midi-output MIDI_UID` and `:mixed-output AUDIO_UID`; an individual input
can override that destination with `:midi-source ASSET SOURCE_ID MIDI_UID`.
See [paired region transport](CAPTURE-UMP-REGIONS.md) for exact cuts, repeats,
clock-only captures, physical ownership and reconstruction limits. The player
owns all four copied source parts until its native process closes. `:play-audio`
remains an explicit WAV-only audition, and `:open-take` opens paired full-source
playback. Audible standalone SMF plus captured UMP composition currently returns
an explicit diagnostic. Monitoring, overdubbing and latency compensation remain
subsequent work; original WAV/UMP bytes and existing WAV/SMF routes are retained.
