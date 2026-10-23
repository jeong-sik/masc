# Native captured UMP experiments

In an arrangement, `:edit-ump [ASSET]` opens a captured performance's MIDI2
notes, recorded per-note expression and event times. This edits a separate overlay on the
verified original packets. It does not convert notes, velocities or clocks into MIDI1/960 PPQ. Original WAV, UMP,
packet boundaries, source/group/channel identities and timestamp-origin flags
remain stored under their original hashes.

Select an attack with Up/Down or its displayed `PACKET:WORD` identity. Packet
indices and word offsets start at zero and belong to the original MIDI part.
`:scope SOURCE GROUP CHANNEL` selects that scope's first event in the current
view; groups and channels use 1–16. MIDI1 messages, other controllers, SysEx,
flex/stream and unknown messages remain source data. The note view lists MIDI2 NoteOn messages. Tab or
`:expressions` opens registered/assignable per-note controllers, per-note pitch
bend and poly pressure; `:notes` returns to attacks. Expression-only takes open
directly in their expression view. `:scope` selects the first matching event in
the current view; `:select-expression PACKET:WORD` selects an exact original
expression message.

`:events` shows every original UMP message, including NoteOff, MIDI1, SysEx and
opaque messages. `:select-event PACKET:WORD` selects one exact original event.
Up/Down moves within this view. A take containing only other messages opens here.

```
pitch-absolute 60.5
velocity 0
revoice Cmaj7 drop2 4 0
harmony
expressions
value32 2147483648
reset-expression
notes
undo
redo
reset-note
play
export /existing/parent/new-native-take
```

`pitch-absolute` is an explicit per-attack absolute-pitch override. It sets
Attribute 3 Pitch7.9, accepting exact MIDI-note units in 1/512-semitone increments
from 0 through 127.998046875. It keeps Note Index fixed, so original NoteOff,
poly pressure, per-note controllers/bend and management continue addressing the
same indices. It does not retarget or guess their ownership. Existing Attribute 3
fractional pitch is retained unless explicitly changed. Manufacturer/Profile or
unknown attributes cannot be overwritten by this command. `velocity` changes
the full 16-bit attack value 0–65535, preserving the attribute and release bytes.
MIDI2 velocity zero remains an attack. `reset-note` removes both edits for the
selected attack; the original message is restored.

`:value32 INTEGER` changes the selected expression's complete unsigned 32-bit
data word, from 0 through 4294967295, using exact decimal notation. No MIDI1
scaling, normalization or controller-unit conversion is applied. The list shows
the original note index, controller number where present, and current raw value.
Per-note pitch bend is bipolar with center 2147483648; its sounding interval
still depends on the recorded sensitivity and device state. Registered and
assignable controller meanings are not inferred. In particular, the pitch
controller's Q7.25 word differs from NoteOn's Q7.9 attribute.

Expression value edits keep the first address word, source/group/channel, note index,
controller index, original message order, packet boundaries, integer host ticks
and timestamp-origin flags. They do not infer a unique attack owner, move a
controller to another note, or rewrite detach/reset management messages. A
target with invalid note or reserved address bits is refused; opaque source
messages remain unchanged. Controller numbers retain their original raw
addresses without assuming a device-specific meaning.
`:reset-expression` removes only that selected expression edit. Note edits and
expression edits retain each other, share undo/redo, and travel together through
the existing native playback, arrangement variant, portable save and raw export.
Note commands require the note view; expression-value commands require the
expression view, preventing edits to a hidden target.

## Native event time and explicit note length

In any view, `:time HOST_TICKS` sets the selected message's authored UInt64 host
time; `:shift-time SIGNED_TICKS` moves it by an exact integer offset. Use
`:reset-time` to restore its original timestamp. The list retains the original
packet/word ID and shows approximate source-relative seconds, with `*` for an
authored time. `:clock` inspects the selected event's exact current and original
source timestamps and the source origin. Time edits never
round through floating-point seconds or a PPQ projection. Even messages recorded
inside one packet can move independently. Derived packets contain complete UMP
messages in host-time order; equal times retain original presentation order.

In the note view, `:note-time OFF_ID START_HOST END_HOST` moves the selected
attack and the explicitly selected MIDI2 release in one undo revision.
`:duration-ticks OFF_ID TICKS` leaves the attack in place and sets that release
to a positive exact duration after it. The release must share the source,
group, channel and Note Index. Choose its original ID in the all-event view,
then return with `:select ATTACK_ID`. The editor does not infer which release
belongs to repeated attacks on one index; this is an explicit event edit,
not a claim about a receiver's voice allocation or acoustic note duration.
Controllers, per-note management, pedals and WAV audio do not follow an attack
automatically. Use their own event selections when an experiment calls for it.

Sources containing embedded JR or delta-clock utilities require an embedded
clock editor before host-time changes. These sources remain readable and keep
pitch/value edits; timing in other source streams remains editable. Rewriting
host times while retaining conflicting embedded timestamps is refused.

The `timing` overlay stores original identities and authored host times separately
from note/value patches. All three share history and preserve each other.
The original recording parts, manifest and MIDI bounds stay under their hashes.
An edited playback/export snapshot can split packets and marks changed times
`timestampOrigin: authored`, retaining `recordedHostTime` and
`recordedTimestampOrigin`. Reimporting that export as a new take keeps this
recorded provenance when another authored layer is applied.

Time editing preserves the original source clock span, extending it when events
move outside either edge. Moving a last release inward retains the original end
as silence; it does not shorten the take or move the WAV. The derived session
manifest has the edited packet count, an explicit `umpSourceSpan`, and an origin
matching that span. Standalone inspection/audition and arrangement placement
consume this same span. Export/import does not restore prior editor history;
save the arrangement for that.

## Edit in beats

The arrangement lends its current project tempo to the native UMP editor.
One beat is a quarter note, independent of the meter denominator. Inputs may
be decimal numbers or exact signed fractions, including triplets:

```
at-beats -1/3
shift-beats 1/6
note-beats 4:0 1/3 1
duration-beats 4:0 2/3
```

Positions use the same fixed original source zero as seconds. A shift is
relative to the selected event; a duration sets the explicitly chosen release
relative to the current attack. Other events and the WAV do not follow the
edited event. Beat commands require an arrangement tempo; there is no guessed
default or interpretation of captured Flex Data tempo or clip timing.

The editor snapshots the opening arrangement tempo. It uses the exact binary64
tempo already used by project scheduling, converts the authored beat rational
directly to source-clock ticks, then rounds once to nearest tick, with exact
half ties away from zero. It does not first round to PPQ or floating seconds.
Invalid fractions, zero denominators, nonpositive quantized durations and
UInt64 endpoint overflow are refused as whole immutable edits.

Separate endpoint input rounds each endpoint. Duration input rounds the length
and adds it to the current whole-tick attack, so the resulting release can differ
by one tick. For example at 137 BPM with 125/3 ns ticks, `1/3` and `2/3` beat
endpoints are 3,503,650 and 7,007,299 ticks; a `1/3` beat duration added to that
attack ends at 7,007,300 ticks. `:clock` exposes the exact stored time.

Only the resulting integer timing overlay is saved. Changing project tempo later
does not retime a captured variant or stretch its WAV. Reopening the editor uses
the new project tempo for future beat commands while preserving earlier edits.
The event list continues to show approximate source seconds.

## Edit in seconds

Use decimal source seconds when absolute host ticks are inconvenient:

```
at-seconds -.125
shift-seconds .025
note-seconds 4:0 .2 .6
duration-seconds 4:0 .4
clock
```

`:at-seconds S` positions the selected event relative to this asset's fixed
original source origin; `:shift-seconds S` moves it relative to its current
authored time. `:note-seconds OFF_ID START_S END_S` positions an explicit
attack/release pair, while `:duration-seconds OFF_ID S` sets the release relative
to the current attack. The same explicit release-address checks and atomic
history as host-tick commands apply. These commands do not infer tempo or beats.

The fixed zero includes the original take's pre-roll and declared source span.
It is not necessarily WAV frame zero or the current earliest authored event.
Moving an event before zero does not change the meaning of the next seconds
command. An exported derived session imported as a new take uses that new
asset's declared source origin; it does not restore the previous editor's
history or redefine an imported authored event as an original recording.

Decimal input is parsed as an integer rational and quantized once to the nearest
whole host-clock tick, with exact half ties away from zero. Positive durations
that round to zero ticks and results outside UInt64 host time are refused.
Signs and a leading decimal point are allowed; exponents, hexadecimal, infinity
and nonnumeric values are refused. No floating-point absolute timestamp is used
to make a time edit. Existing source-region start/end commands keep their own
inward rounding policy.

The event list's six decimal places are an approximate display, not the stored
precision. `:clock` is read-only and returns exact current host time, original
event time within this source, and fixed source zero. If this asset was imported
from an authored export, its original source-event time can itself be authored;
the earliest recorded timestamp provenance remains in the native packets and
original source bundle. Reset/undo and exports continue to use full native ticks.

`:revoice SYMBOL MODE [OCTAVE [INVERSION]]` changes the exact-onset group sharing
the selected attack's source, group and channel. Voices sort by their current
Attribute 3 pitch or original key index, then original packet/message order.
The chosen close/drop2/rootless voicing must match the group count. This applies
explicit absolute pitches in one undo revision without changing timing, indices
or dynamics. It does not infer arpeggio groups, held pedal voices or release
pairing. An unsafe attribute in any voice refuses the whole edit.

`:harmony` reports onset candidates. Original unattributed keys are labelled
key-index candidates: MTS, per-note tuning, bends and vendor/Profile semantics
are not resolved into an acoustic pitch model. Attribute 3 groups use their
absolute values. Fractional pitches and opaque attributes remain visible without
rounding into a 12-tone chord label. Chord candidates are not harmonic verdicts.

Space or `:play` opens the existing captured-session viewer on the same edited
packets. Choose native MIDI2 destinations there; source-specific bindings from
the arrangement are retained. The WAV is the unchanged original performance,
not pitch-shifted audio. The session's Space starts/stops audition and q returns
to the UMP editor. Existing native state reconstruction and destination ownership
rules still apply; a refused seek or opaque state does not destroy the draft.
Preparation remains cancellable, and a borrowed viewer/native owner closes
before the editor or arrangement resumes.

q returns a changed overlay as a new capture asset in one arrangement undo
revision. Ctrl+C or an external session abort discards the child result. No edits
means no extra asset. Existing source assets and regions remain unchanged.
If the Worker fails or final source verification refuses the edited result, the
validated opening packets still produce a separate editable draft in the same
unchanged parent project. The failure stays reported; normal save/playback still
verify current source files. Closing uses the parent's existing recovery path
when saving is unavailable, preserving the overlay and original source hashes.
Use `:place NEW_ASSET BEAT` to place it independently, or `:open-take` to audition.
Use `:split-take` to compare a MIDI component against the original audio. Existing
save/save-as copies the raw parts and retains the overlay for portable reopen;
reopening the variant editor reads the original packets and applies the overlay
once. Playback preparation validates the original parts and edit targets before
materializing an owned edited snapshot for standalone or arrangement transport.

`:export NEW_DIRECTORY` refuses an existing target. It writes the edited UMP
JSONL, original WAV/audio blocks, a session manifest, original MIDI JSONL and
`ump-source.json` with original hashes, overlay and edited-MIDI hash. The packet
times stay integer host ticks; no clip-tempo conversion occurs. Export streams
independent files to the chosen directory, including across volumes. A failed or
cancelled unsealed export removes only its newly owned target. This bundle is
an archival/native-take export; importing its edited session as a take treats
those edited packets as a new source, rather than reconstructing editor history.
The saved arrangement is the portable editable document. The captured viewer's
separate MIDI2 Clip export still declares its 1000 PPQ quantization.
Without time edits the session manifest remains the original bytes; with time
edits it describes the derived packet count/span. `ump-source.json` retains the
original manifest hash and clock, alongside the exact overlay.

This native editor does not yet add automatic voice pairing or grouped
controller-following edits, message insertion/removal, raw practice-take editing or MIDI2 Clip import. These remain
part of the sequencer objective tracked by #44748. Focused source/worker/controller
and native-protocol checks do not establish installed Ghostty or physical-device
behavior.

On macOS, run `node tools/alphatex/native/test-edited-ump-wire.mjs` from the
repository root to check edited capture packets through the actual Worker and
native source transport into private CoreMIDI MIDI2 destinations.
It compares per-source received words against explicit pitch/velocity/index/
controller/release values, observes both sources' active-note and pedal cleanup
on cancellation after their receive acknowledgements,
and emits a receipt with actual received words and retired owner state. It uses
the Swift compiler and CoreMIDI, without opening an existing instrument or
replacing the installed application. This is virtual-endpoint evidence; it does
not establish physical latency, audio/MIDI sample alignment or visible Ghostty.
Add `--time-edits` to exercise a split/reordered attack and a later release,
comparing exact authored tick deltas at the native scheduling boundary as well
as actual received words. This does not measure receive-callback timing accuracy.

Protocol: [MMA/AMEI UMP 1.1.2](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf),
§7.4.2–7.4.4, §7.4.12, §7.4.14–7.4.15.3 and Appendix C. Attribute 3 makes Note
Number an index; absolute pitch overrides previous tuning for that attack only. The persisted
`ump` overlay has schemaVersion 1, original `midiSha256` and unique note edits
with original `packet`/`word` plus optional unsigned 16-bit `pitch`/`velocity`.
Optional `expressions` edits use the same original identity with one unsigned
32-bit `value`; duplicate or cross-kind identities are refused.
Optional `timing` edits have original `packet`/`word` and exact decimal
`hostTime`. An event may have both a time edit and a note/value edit; duplicate
time identities are refused separately.


### Move a native phrase with its selected expression

The editor can group explicit original message identities without guessing
NoteOn/NoteOff pairing or which attack owns a per-note controller. For example:

```
select-events 0:0 0:2 2:0 3:0
shift-events-beats 1/3
stretch-events 3/2
undo
redo
reset-event-times
deselect-events
```

`:select-events ID...` replaces the group with distinct original packet:word
identities. Every original UMP message is eligible, including releases, MIDI1,
expression and opaque messages; choose the exact messages to move together.
The focused event and the explicit group are separate. Navigation, view changes,
value edits and Undo/Redo retain the group; it is session state, not saved music.
The header gives its size and `+` marks members. Empty or unknown selections
refuse without changing the document. `:deselect-events` clears the group.

`:shift-events-ticks INTEGER`, `:shift-events-seconds DECIMAL` and
`:shift-events-beats DECIMAL_OR_FRACTION` apply one common offset to every member.
Seconds and beats use the existing source-clock conversion and its nearest-tick
rounding; beats use the opening arrangement tempo. `:stretch-events RATIO
[ANCHOR_BEATS]` scales each member's current distance from the earliest selected
event, or an explicit source-zero project-beat anchor. Ratios accept exact
positive decimals or integer fractions. Every scaled distance must resolve to a
whole native tick; a nonintegral result is refused rather than rounded. Timestamp
math stays in BigInt, including above binary64's exact integer range.

Each group edit validates the complete overlay and makes one Undo revision.
A bad member, timestamp outside UInt64 or unsupported embedded JR/delta clock
refuses the entire decision. `:reset-event-times` restores only the selected
members' original timestamps in one revision, retaining other timing, pitch,
velocity and expression edits. Original words, source routes, equal-time order,
WAV and recorded provenance remain unchanged. Audition, returned arrangement
variants, portable save/reopen and native export use the existing timing overlay.
This is event-group retiming, not automatic musical ownership, live clock sync,
audio time stretching, native event insertion/deletion or MIDI2 Clip import.
