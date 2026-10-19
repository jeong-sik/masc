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
