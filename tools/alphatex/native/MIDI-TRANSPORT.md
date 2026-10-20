# Native project MIDI output

`music-midi destinations` lists CoreMIDI destination unique IDs and names.
`music-midi play --file TIMELINE_JSON --destination UID [--loop]` sends the
editable project's MIDI 1.0 projection to exactly that destination. There is no
default MIDI output or replacement on error. The endpoint reference and unique
ID must both remain selected; removal/offline notifications stop the session.
The `protocol: 1` result describes the emitted stream, not the destination's
maximum hardware protocol capability.

The timeline is produced by `projectMidiTimeline` from the same `sequenceEvents`
used by MIDI file export and SoundFont synthesis. Schema version 1 has a finite
positive duration in seconds and ordered events with seconds, channel and a
closed event kind: program, control, on or off. Volume (CC7) and pan (CC10) are
the controls in the current editable project. Notes and loop boundaries are
already clipped by the project. Unknown event kinds/controllers fail explicitly.
This projection is not a Standard MIDI File or UMP importer and must not be used
to strip unsupported data from one. Expression-preserving MIDI import/editing,
additional channel controls, percussion tracks and MIDI 2.0 output remain work.

Playback uses a serial queue and a deadline timer independent of terminal draws.
Only already-due messages enter CoreMIDI, with an immediate timestamp. There is
no shared endpoint flush and no queued future messages to survive a pause or
seek. This is host-deadline MIDI scheduling, not sample-locked audio/MIDI or an
external MIDI clock. The state event's `maximumLateness` reports observed timer
lateness; it never stops playback by a latency threshold. After suspension,
completed loop cycles are skipped before sending pending events. Within a cycle,
fully expired note intervals are omitted; notes still held at the observed phase
are reconstructed with the latest program and controls. Cleanup and sends remain
elapsed time against the same sampled host-clock anchor, rather than delaying
the loop epoch by their processing time. Pause and status also observe the current
loop phase when their command arrives before an overdue timer callback.

Stdin accepts the same JSONL pause/resume/seek/status/stop commands as the
[WAV transport](TRANSPORT.md). Pause sends note-offs for keys this player started.
Resume reconstructs programs, volume/pan and notes held at the current position;
their original note-offs still occur at the scheduled end. Seeking while paused
remains silent. Seeking to duration stops a one-shot and selects zero in a loop.
The target boundary is included before restoration, so seeking exactly to a
note-off does not reattack that ended note. A note beginning at the same boundary
is started once.
An external instrument restarts its note envelope when a held note is resumed.
No channel-wide all-notes-off/reset or global MIDI flush is sent. MIDI 1.0 key
identity belongs to channel and pitch, so unrelated simultaneous playing on the
same channel/pitch does not have a separate voice identifier.

Stdout state events retain kind, currentTime, duration and loop and use a MIDI
device identity:

```json
{"kind":"playing","currentTime":0.5,"duration":2,"loop":false,"maximumLateness":0.001,"device":{"kind":"midi","id":"1234","name":"Instrument","protocol":1}}
```

Stop, stdin EOF, signals and failures cancel the timer, release owned held keys,
dispose the output port/client and exit. Unavailable devices or failed sends
produce an explicit error and nonzero exit; a removed physical device cannot
receive cleanup note-offs. A stopped acknowledgement is not process closure.
A key is owned before its Note On is sent, because a failed send can still
reach the instrument. A note-off that fails keeps its key owned, so the final
cleanup sends it again; successful note-offs are not repeated.
The JS wrapper retains the owned process until its pipes and process close.

The runtime reads the entire event timeline; limits are the JSON/memory and
UInt64 host-clock representation. There is no arbitrary phrase duration limit.

CoreMIDI contracts: [MIDISend](https://developer.apple.com/documentation/coremidi/midisend(_:_:_:)),
[MIDI destinations](https://developer.apple.com/documentation/coremidi/midigetdestination(_:)).
The implementation uses the installed SDK's `CoreMIDI/MIDIServices.h` packet,
port, notification and unique-ID contracts.

The client is created on the main run loop. Destination selection, port ownership,
notification admission and playback then belong to the serial transport queue.
Notifications before preparation completes do not inspect partial resources;
preparation and start each verify the selected endpoint.

`node tools/alphatex/native/test-midi-transport.mjs` compiles source-derived Swift
scenarios with controlled clock/send effects. It checks late-cycle and late-note
decisions, seek boundaries, send-time phase accounting and preparation admission.
It does not register CoreMIDI clients, enumerate devices or send hardware MIDI;
actual endpoint timing and delivery require a separate runtime probe.

## Captured playback on MIDI1 destinations

Captured playback retains its raw UMP recording and original clock. At preparation,
the output owner pins the destination's native protocol. Native MIDI2 destinations
receive the original words. Native MIDI1 destinations accept validated MIDI1 channel,
system and SysEx7 messages, plus MIDI2 note, pressure, ordinary controller, pitch and
program messages whose values are exact images of the UMP specification's canonical
MIDI1 upscaling. Bank-valid program messages expand to an ordered bank MSB, bank LSB
and program batch at the original deadline. No timestamp or saved asset is rewritten.

High-resolution values outside that exact image, note attributes, per-note/compound
state, mixed channel dialects and independent groups on one MIDI1 output are refused
before playback. One admitted group projects to physical group zero; hybrid and live
reservations use that physical address. Finite trims and loops profile only reachable
restoration and selected raw effects. Fully expired voices and unreachable suffixes
do not require conversion. Seek/chase retains its separate source-state refusals.

The binding ACK retains `protocol: 2` as the captured owner family and reports the
actual pinned `nativeProtocol: 1` or `2` separately. JavaScript validates both and
rejects protocol changes during ownership. Backing reservation claims carry the
native protocol when captured groups depend on it; live admission and forwarding
revalidate that descriptor. Live input remains native MIDI2 only because its future
message compatibility cannot be profiled in advance.

`node tools/alphatex/native/test-midi1-output.mjs` checks the exact inverse domain
and delivery through owned private CoreMIDI MIDI1/MIDI2 endpoints. It does not prove
physical hardware, acoustic output or the visible Ghostty UI.

## Live UMP input backend

`music-midi-live --plan LIVE_MIDI_JSON` opens selected CoreMIDI sources and
forwards their delivered UMP messages to explicitly selected native MIDI 2.0
destinations. The arrangement TUI starts this helper and derives reservations from the
actual prepared backing plan using native playback parsers. Its plan requires an explicit `reserved`
array, including `[]` for a standalone owner:

```json
{
  "schemaVersion": 1,
  "routes": [
    {"source": "1234", "destination": "5678", "scope": {"kind": "channels", "channels": [{"group": 0, "channel": 0}]}}
  ],
  "reserved": [{"destination": "5678", "scope": {"kind": "channels", "channels": [{"group": 0, "channel": 1}]}}]
}
```

UIDs are exact signed decimal CoreMIDI unique IDs. Groups and channels are
zero-based values from 0 through 15. A `channels` scope forwards only MIDI 1.0
or MIDI 2.0 channel voice messages in the selected group/channel pairs. System,
SysEx and other message types are filtered in this mode. `{"kind":"endpoint"}`
forwards all complete delivered message types, including opaque words, and owns
the whole destination. No route rewrites a message's group or channel.

Overlapping destination scopes across routes or against declared reservations
are rejected before resources open. Disjoint channels can share a destination.
The TUI obtains backing claims with `music-midi-live reservations --file PLAN
--format FORMAT`, using the same MIDI region and UMP prefix ownership as playback.
It retains the private plan during inspection and playback, closes an old live
owner before a replacement, and admits the new live/backing combination only
after the native live owner validates these claims. Standalone callers must
supply their own authoritative reservations; the helper is not a process-global
lease service. A destination must report protocol 2. Input delivery requests protocol
2, so CoreMIDI may convert a source into that delivery protocol. Preservation
here refers to the complete delivered UMP words, not the original physical wire
representation or an unnegotiated end-to-end MIDI 2.0 instrument connection.

The callback copies variable-sized packets, including packets larger than 64
words. It performs no device discovery, file/JSON I/O, sends or musical-state
updates. The main lifecycle orders timestamps, retains stable admission order
for equal timestamps, validates complete message framing and sends only due
messages. Future timestamps remain local; they are never queued in CoreMIDI.
The explicit resource bound is 65,536 pending words (256 KiB of raw payload),
including callback handoffs and future timestamps. Exhaustion fails and stops
forwarding with an error; it never hides dropped messages or imposes a cumulative
performance duration/event budget.

Stdout JSONL publishes `monitoring` only after selected resources are validated.
It includes `deliveryProtocol`, source/destination/scope bindings,
`forwardedMessages`, `filteredMessages` and `pendingWords`. Message counters are
decimal strings. Stdin accepts `{"kind":"status"}` and `{"kind":"stop"}`.
EOF, SIGINT, SIGTERM, SIGHUP, malformed commands, selected endpoint removal,
identity/state/property failure and send errors stop this owner. There is no
replacement device. Stop closes admission, waits for admitted callback handoffs,
cancels future deadlines and releases acquired keys, pedals and partial SysEx
through the existing UMP output owner before publishing `stopped`. A cleanup
failure produces an error, `success:false` and nonzero exit; a removed instrument
cannot receive its cleanup. The caller must await process/pipes closure as well
as the final acknowledgement.

`node tools/alphatex/native/test-live-midi.mjs` exercises production decisions
with controlled property/send effects, without registering devices. Actual
selected-source/destination delivery, physical instruments, synth/audio output,
measured roundtrip latency and visible TUI use require separate evidence.


`node tools/alphatex/native/test-live-midi-reservations.mjs` runs the real
read-only reservations command against source-derived plans. It checks trimmed
MIDI and UMP prefix ownership, physical port remapping/group/channel union,
hybrid collisions and malformed/hidden backing data without opening a device.
