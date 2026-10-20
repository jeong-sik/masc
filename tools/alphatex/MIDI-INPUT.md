# Source-only MIDI input

The native `music-midi-input --source UID` companion and
`openMidiInput({ source, onPacket, signal })` read one explicitly selected
CoreMIDI source. The installer ships them beside the other music companions.
They open an input port, with no audio stream or MIDI destination.

The piano roll uses this boundary through `:step-input SOURCE_UID` and
`:step-stop`; see [keyboard step entry](README.md#midi-keyboard-step-entry).
Existing audio/MIDI takes and live output forwarding keep
their own owners. Their audio-input and output-route requirements do not apply
to this source-only reader.

## Data and admission

`source` is the exact signed Int32 UID string from device discovery. Startup
resolves it to a source endpoint, checks its identity/offline state, creates an
owned client/input port and connects that endpoint. Destination IDs are refused.
Removal or identity failure terminates input with an error. It never chooses a
replacement device by name or automatically opens another source.

The `ready` promise resolves to:

```json
{"kind":"midi-input","schemaVersion":1,"protocol":2,"source":{"id":"10","name":"Keyboard"},"clock":{"kind":"mach-host-time","numer":125,"denom":3}}
```

The port requests MIDI protocol 2. CoreMIDI converts source protocols as needed;
this does not assert that a connected keyboard speaks native MIDI 2. Every
CoreMIDI-delivered UMP word is retained, including messages other than notes.
CoreMIDI can repacketize a source event list. Original source packet boundaries
are not the API's identity; delivered packet ordering, message words and host
timestamps are. The reader never sorts or quantizes the incoming messages.

Each `onPacket(event, { signal })` receives:

```json
{"kind":"midi","source":"10","protocol":2,"ordinal":"0","hostTime":"9007199254740993","timestampOrigin":"packet","words":[1133853699,2415993669]}
```

Ordinals and UInt64 host ticks are decimal strings, so values above JavaScript's
safe integer range remain exact. `timestampOrigin=received` means the source
packet had timestamp zero and the callback sampled the host clock instead.
The startup clock's timebase is authoritative for converting host ticks.
`unpackMidi` validates whole UMP messages before the consumer is invoked.
No note/channel filter or lossy MIDI1 projection is applied here.

The native callback copies words and reserves their payload while holding its
admission lock for the whole event list, so concurrent callbacks cannot
interleave its packets; it does not serialize JSON or run the editor. Main-thread
handoffs retain that reservation. The helper exposes one packet at a time and
waits for `{kind:"ack",ordinal:"0"}` before exposing the next. JavaScript sends
that acknowledgement only after the consumer's returned promise settles.
Do not await input completion from inside its own packet consumer.

Outstanding callback, handoff, queue and consumer packets share a 65,536-word
(256 KiB of UMP payload) backlog. It bounds live payload, not session duration,
number of notes or total data ever received. Capacity is reusable after each
acknowledgement. Overflow closes admission and reports failure; it does not
quietly drop input and report a successful take. JSON/transport overhead is
additional to that payload bound. Upstream device/OS data never delivered to
this port cannot be counted or certified by this reader.

## Stop and ownership

`stop()` is idempotent. It closes new callback admission and disposes the owned
port/client, then drains every already admitted packet, including handoffs that
were queued when stop arrived. Stdin remains open for the acknowledgements.
A successful final event has:

```json
{"kind":"stopped","source":"10","success":true,"admittedPackets":"1","acknowledgedPackets":"1","discardedPackets":"0","pendingWords":0,"error":null}
```

`admittedPackets` counts packets accepted by this owner, not every packet emitted
by the physical device. Normal completion requires all admitted packets to be
acknowledged, no discarded packets, zero pending words, a valid final event and
successful child closure. Resource-disposal errors are failures.

External abort, source loss, malformed input, an unacknowledged second packet,
consumer failure or child failure rejects completion. An internal AbortSignal
informs an admitted consumer so it can release its own work. Completion joins
that consumer settlement and the native child closure; killing the child alone
is not settlement of an editor operation. The native abort path reports any
admitted/discarded backlog rather than claiming a normal drain. A failed stdout
can prevent delivery of that final event, in which case child closure still
makes the JavaScript owner reject. CLI stdin EOF is an abort because the owner
has lost its acknowledgement channel.

## Focused verification

```sh
node --test tools/alphatex/test/midi-input.test.mjs
node tools/alphatex/native/test-midi-input.mjs
```

The JavaScript tests use an owned JSON-lines child and inspect actual packet
consumer/acknowledgement/cancellation decisions. The native harness compiles this
helper, creates private virtual CoreMIDI sources and checks the real
source/helper/JavaScript path: selected source, wrong-object refusal, complete
multi-packet word/timestamp fidelity, pending-consumer stop, removal and closure.
A separate build of the same native owner exercises callback/handoff overflow,
reusable capacity, queued-input drain and invalid protocol with controlled
callback entry. No physical MIDI or audio device is required or verified.

Apple's primary API contracts:
[MIDIInputPortCreateWithProtocol](https://developer.apple.com/documentation/coremidi/midiinputportcreatewithprotocol(_:_:_:_:_:)),
[MIDIEventPacket](https://developer.apple.com/documentation/coremidi/midieventpacket),
[MIDIReceivedEventList](https://developer.apple.com/documentation/coremidi/midireceivedeventlist(_:_:)).
