# Native MIDI2 Clip experiments

Open a MIDI2 Clip with `masc-alphatex --midi-file performance.midi2`, or use
`:midi PATH` from the music library. Its `SMF2CLIP` envelope selects the native
editor; renaming the file does not convert it to SMF. `s` saves a new JSON
document in the project folder. `--project PATH` and the library reopen it.
`q`/Esc saves and returns; Ctrl+C discards the unsaved draft. A failed save keeps
the editor open. Existing JSON paths use the same revision-checked save and
retained candidates as phrase projects.

Up/Down selects an event; Tab cycles notes, per-note expression and all messages.
Colors distinguish groups, selection and failures. IDs are byte offsets in the
immutable original file, so selecting an event still works after moving it.
The all-message view includes configuration and opaque setup packets.

| Command | Effect |
| --- | --- |
| `:select ID` | Select an original event |
| `:pitch-absolute 60.5` | Explicit Pitch7.9 override for the selected NoteOn |
| `:velocity 65535` | Native 16-bit attack velocity, including zero |
| `:value32 4294967295` | Native per-note controller, pitch bend or poly pressure |
| `:time 2002` | Exact nonnegative musical tick in the sequence |
| `:select-events ID...` | Explicit group, including releases/expression when intended |
| `:shift-events-ticks -1001` | Move the group atomically |
| `:stretch-events 3/2 [ANCHOR_TICKS]` | Scale exact group distances; fractional ticks are refused |
| `:revoice Cmaj7 drop2 4 0` | Change the exact onset in this group/channel |
| `:harmony` | Onset candidates; fractional/opaque pitch remains distinct |
| `:tempo-value 50000000` | Selected Set Tempo, unsigned units of 10ns/quarter |
| `:meter-value 4 2 8` | Selected meter's three native byte codes |
| `:reset-words` / `:reset-time` | Restore selected source fields or musical position |
| `:reset-event-times` | Restore only the explicitly grouped positions |
| `u` / `y` | Undo/Redo a whole revision |
| `:save-as NEW_JSON` | Save without replacing an existing pathname |
| `:export NEW_MIDI2` | Stream a native Clip without replacing an existing file |

Pitch overrides retain Note Index and per-note addresses. Manufacturer/Profile
attributes cannot be overwritten by an absolute-pitch edit. Revoicing retains
timing and dynamics, and must match the exact onset's voice count. Releases and
expression never follow an attack implicitly: select the events you intend to
move together. Raw expression words retain all 32 bits.

The document retains original bytes, SHA256 and authored edits separately.
Unedited export is byte identical. Value-only export patches the original
framing; moving sequence events rewrites its delta framing in original PPQ,
retaining setup delays and stable equal-tick order. Longer gaps stream mandated
NOOP separators. Moving inward retains the original tail; moving past it extends
the end. Cancellation/failure removes the private partial export.

Clock calculations accumulate integer tempo/tick products with the original PPQ
as denominator. Missing tempo stays unresolved until a caller supplies one.
No 120 BPM, 960 PPQ or MIDI1 conversion is invented. Unknown/nonstandard meter
codes remain raw source data. Untimed SysEx setup is retained opaquely; import
does not perform a MIDI-CI/Profile negotiation with a device.

## Native MIDI2 audition

Press `o` to choose an output, or open with `--midi-output=ID`. MIDI1-only
destinations are identified in the chooser and refused for native Clip playback.
Sound comes from the selected MIDI2 receiver. Space starts, pauses or resumes;
`.` stops and releases owned notes/pedals. `0` retires the current child and
restarts its admitted immutable full-Clip plan, including configuration delays.
Changing an output or editing the document stops the old owner before another
plan can open an output.

`:play`, `:pause`, `:resume` and `:stop` expose the same controls.
`:seek-event [ID]` seeks the current or named source event in a playing/paused
snapshot, using its exact native nanoseconds. A paused seek stays silent.
Reconstruction preserves raw note attributes, release dynamics and expression
order; missing source state or already-reached opaque device state can refuse
a pause/seek without changing the current playback. Future tempo/meter messages
cannot stand in for missing state at a backward cut.

If elapsed source ticks have no initial tempo, `:initial-tempo 50000000` supplies
an explicit session value in 10ns/quarter (120BPM). `:initial-tempo` clears it.
This fills only unresolved time before a source tempo declaration and does not
change the saved document. No default tempo is inserted.

The native owner first acquires and reports its selected protocol/device/source
and exact setup/duration. Only after the parent verifies those against the
admitted plan does it send Start. Cancelling before that admission sends no
source messages. Source times remain rational until their absolute deadlines
are rounded up once; metadata and sequence time are added before rounding.
Stop/close waits for the child and releases its notes, pedals, port and client.

Profile setup needing MIDI-CI negotiation and embedded JR clocks are explicit
playback refusals. Native Clip looping, local audio synthesis, arrangement
placement and physical MIDI2 endpoint verification remain follow-up work in
[#45643](https://github.com/jeong-sik/masc/issues/45643). The editor plays a Clip
directly; it does not fabricate a recorded session or WAV to reuse capture
playback. Phrase, SMF and recorded UMP workflows retain their own transports.

Format references: [MIDI Association Clip specification](https://midi.org/midi-clip-file-specification-smf-midi-2-0)
and [UMP 1.1.2](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf).
