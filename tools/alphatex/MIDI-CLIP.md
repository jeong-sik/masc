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

Imported Clip playback, arrangement placement and physical MIDI2 endpoint
verification remain follow-up work in
[#45643](https://github.com/jeong-sik/masc/issues/45643). This editor does not
fabricate a recorded session or WAV to reuse capture playback. Existing phrase,
SMF audition and recorded UMP workflows keep their own transports.

Format references: [MIDI Association Clip specification](https://midi.org/midi-clip-file-specification-smf-midi-2-0)
and [UMP 1.1.2](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf).
