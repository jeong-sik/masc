# Device-clocked live PCM output

`music-pcm-output [--output DEVICE_UID]` is the macOS15+/Swift6 output layer for
continuous synthesis. It pins the selected CoreAudio device without changing
the system default. Without an explicit UID, it resolves the default once and
then retains that identity. A removed/changed route fails; it does not switch
devices. The node consumes stereo Float32 audio at the output's actual sample
rate. The main mixer performs the selected device's channel conversion.

Startup emits NDJSON:

```json
{"kind":"ready","schemaVersion":1,"device":{"id":"UID","name":"Output"},"sampleRate":48000,"blockFrames":512,"prefillFrames":1024}
{"kind":"need","id":"1","frames":512,"startFrame":"0"}
```

The hardware buffer frame size determines each block. Two blocks prefill the
queue before starting the engine, providing double buffering. Queue storage
also accommodates the audio unit's maximum render quantum. The producer sends:

```json
{"kind":"block","id":"1","pcm":"base64 interleaved left/right little-endian Float32 bytes"}
```

The exact requested ID, canonical base64, complete stereo block and finite
samples are required. The control thread validates the entire block before
publishing it. IDs and cumulative frame positions are decimal strings, avoiding
JSON lifetime integer precision loss. The native UInt64 bound remains explicit.

One `AVAudioSourceNode` callback reads preallocated storage. It does no synthesis,
IPC, logging, allocation or locking. Single-producer/single-consumer release/acquire
indices publish/retire the samples. A dispatch data notification wakes the main
control lifecycle after consumption. That lifecycle requests the next block only
when capacity is available, with at most one outstanding demand. The output
device drives consumption; no JavaScript timer approximates its clock.

After prefill, `{"kind":"playing"}` confirms engine startup. Underrun fills
the missing callback frames with silence, records the fault and stops on the
control lifecycle with an explicit error. It does not silently stretch late
audio or accumulate an unbounded queue. Device UID, liveness, sample rate,
channel count, hardware quantum and engine state remain pinned and checked.
Configuration notifications and property listeners terminate a changed route.

`{"kind":"stop"}` retires the queue and stops the engine immediately. This is
live monitoring: queued future audio is discarded, rather than played after
stop. A final `stopped` event reports `success`, `admittedFrames`,
`renderedFrames`, `discardedFrames`, and `underrunFrames` as decimal strings.
Rendered means consumed by the source callback; it does not prove physical
speaker output or measure presentation latency. At a clean stop, rendered plus
discarded equals admitted, and underrun is zero. EOF without stop, signals,
bad input, route loss and underrun fail with a nonzero exit. Engine, listeners
and notification sources are retired before the final receipt.

`openPcmOutput` in `pcm-output.mjs` owns the native child and one asynchronous
`provideBlock({id,startFrame,frames,sampleRate,signal})` operation per demand. The
producer returns a Buffer. Ready metadata is copied so observer mutation cannot
retarget validation. Stop aborts the producer and discards late PCM. Failure
normalizes any cancellation reason while retaining its cause. Completion joins
both actual process closure and producer settlement, even when the producer
finishes after native closure. A successful final reply alone is insufficient.
Producers must observe their signal or otherwise settle their owned work.

The immutable alphaTex installer fingerprints both native sources and the JS
owner and builds the companion separately from Dune. Live VST callers combine
this layer with `openVstStream`, using the requested device sample rate. The TUI
and MIDI input are not connected by this layer; that integration follows.

Checks: compile/run `PcmRing.swift` with `test-pcm-ring.swift` for wrap, overflow,
finite transaction validation, underrun, concurrent stereo ordering and retirement.
`test/pcm-output.test.mjs` checks actual child protocol/producer ownership. Native
device and continuous VST probes are recorded separately from these checks.

Reference: [Apple AVAudioSourceNode callback contract](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode/init(renderblock:)).
