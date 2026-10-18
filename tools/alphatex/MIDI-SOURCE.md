# Editable MIDI source assets

A MIDI file is a source asset, not a conversion into the phrase document's reduced
note schema. `midi-source.mjs` keeps its original bytes as canonical base64 plus
source-event edits and inserted channel messages. Source IDs address a track and
its original event index; opaque chunks and events retain their provenance. A JSON
save/reopen preserves this document. Persist the source asset, not a derived piano
roll or floating-point schedule.

`importMidiSource(bytes)` accepts structurally complete SMF 0/1/2 and RIFF RMID.
It retains header extensions, unknown chunks, all meta payloads, channel expression,
programs, SysEx F0 packets and F7 continuation/escape payloads. Unedited export is
byte-for-byte original. Edited export rewrites only touched MTrk chunks, retaining
other SMF chunks and RIFF siblings verbatim; VLQ and running-status encoding inside
a touched track may change. Its end marker extends when an edited note extends
past the old end. Invalid lengths/status/VLQ/end markers are rejected; the parser
does not repair an input file into different music.

`midiSourcePattern(source, {pattern})` produces the ordered original-resolution
performance and note-key intervals. SMF 1 merges tracks by tick, then original
track/event order. SMF 2 requires explicit pattern selection when several tracks
are present; those independent patterns never become simultaneous tracks. PPQ
time integrates every tempo event, retaining exact integer source ticks. SMPTE
24/25/30 and -29 (30000/1001 frames/second) use their fixed clock independently of
tempo events. MIDI ports remain numbered source routing identities, not physical
destination UIDs. No routing is silently combined or chosen here.

Paired notes retain both on/off event IDs, source track/port/channel, velocity,
integer start/duration and derived seconds. Note-offs may live on another SMF 1
track. Note-on velocity zero remains that encoding on edited export; release
velocity on a true note-off is retained. Simultaneous equal channel/pitch voices
have no voice identifier in MIDI 1.0: projections pair FIFO and explicitly diagnose
overlaps, unmatched offs and unclosed ons. They do not add missing offs or claim a
unique voice interpretation. Zero-length notes remain valid source events.

`editMidiSourceNote` changes pitch, velocity, start/duration or removes a paired
note transactionally. `editMidiSourceNotes` applies a batch and can insert paired
channel notes into a selected source track. Edits change only the selected source messages; controllers,
pressure, pitch bend, program/tempo maps, metadata and SysEx remain intact. A
source-event gap that cannot fit SMF's four-byte delta rejects the edit instead of
inserting a new semantic event. Accepted changes retain their original on/off IDs
and source port. Moving either message across a MIDI Port change is rejected;
there is no implicit route edit. Inserted notes use the active source port at
their start and must retain it through their off. Edits that change FIFO pairing,
including cross-track zero-length edits whose off sorts before the on, are
rejected transactionally. Existing overlap diagnostics remain visible rather
than making an imported performance invalid. `midiSourceHarmony` returns Tonal candidates for
note-key intervals at a second position, with optional channel/pattern selection.
It does not extend key intervals through sustain/sostenuto or infer pedal voices.

This module supplies the source-asset core for import/edit/export and arrangement
integration. Its tests do not establish a delivered import screen or full MIDI
support. The source editor connects note experiments and explicit-output one-shot
MIDI audition. Event/expression editing, clip arrangement, overdub and UMP/MIDI 2.0
source assets require further integration.
See [the sequencer design](../../docs/design/tui/MUSIC-SEQUENCER.md).

References: [MIDI Association SMF reference index](https://midi.org/standard-midi-files-specification),
[JZZ SMF API](https://jazz-soft.net/doc/JZZ/midifile.html) and its pinned 1.9.9
parser/serializer provide independent cross-checks. Focused fixtures check actual bytes and musical decisions,
including a large vendor payload and preservation through note edits; they do not
prove every vendor's device behavior.

## Ordered source audition

The source editor projects a separate schema-2 MIDI timeline. It retains all
channel messages and F0/F7 payloads, original equal-time ordering, PPQ tempo-map
seconds or SMPTE rational time, and explicit port-to-destination bindings.
Meta events remain source data and drive timing/routing; they are not sent as
wire status FF. Format-2 patterns remain an explicit selection. No phrase-schema
reduction or SoundFont approximation occurs in this path.

The native wire decoder expands running status inside F7 escapes, completes
partial short messages at their completion time, passes real-time bytes in order,
and retains SysEx fragment timing. Incomplete/undefined wire streams are refused
before opening endpoints while the source document remains editable/exportable.
Native transmission packetizes long SysEx using the [CoreMIDI packet-list API's
65536-byte boundary](https://developer.apple.com/documentation/coremidi/midipacketlistadd(_:_:_:_:_:_:)), including ABI header offsets and checked additions.
F0/F7 interpretation follows the [Standard MIDI Files specification](https://midi.org/standard-midi-files-specification).

Audition plays once from the start and supports status/stop. Pause, resume, seek
and looping are explicitly unavailable for source timelines. A late wake sends
every due source message in order, including zero-length notes and note-off
release velocity; this is semantic-stream preservation, not sample-clock timing.
Stop sends owned key-offs and enabled hold-pedal releases. Opaque vendor SysEx
state, shared-channel external notes, physical-device latency, MIDI 2.0 and
external clock synchronization are not claimed.
