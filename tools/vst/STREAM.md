# Continuous VST synthesis protocol

`masc-vst-host --stream` exchanges newline-delimited JSON on stdin/stdout.
Native diagnostics, including direct plug-in writes, go to stderr. The child
loads one selected VST3 instrument on its main thread. It has no audio device,
MIDI endpoint, transport timer, speculative render queue or session duration cap.

The first command is `open`:

```json
{"kind":"open","schemaVersion":1,"sampleRate":44100,"plugin_path":"/path/to/Synth.vst3","plugin_name":null,"instrument":{"identifier":"selected-id","version":"selected-version"},"preset":{"data":"base64 project preset bytes","sha256":"project preset SHA256"}}
```

The selected identity/version and preset bytes are mandatory. The SHA256 and
canonical base64 are checked before loading the preset. The host loads a private
copy and removes it before replying. A label's original preset path is never
read. Identity/version mismatch, content/library/license failure or a crashed
plug-in fails this operation; no alternative instrument is selected.

`ready` returns `schemaVersion:1`, `sampleRate`, `channels:2`, the actual
`instrument` description, and `preset_sha256`. The consumer verifies these
before requesting a block:

```json
{"kind":"render","id":1,"frames":256,"messages":[{"frame":0,"bytes":[144,60,100]}]}
```

IDs start at 1 and increase by 1. `frames` is a positive integer through 2^24,
the contiguous sample-index range of the pinned Pedalboard Float32 API. Rates
and sample positions that cannot be encoded exactly by that API are refused.
`messages` is an ordered list of complete MIDI1 messages with nondecreasing
sample offsets `0 <= frame < frames`. Boundary events belong at frame 0 of the
next block. All input is validated before synthesis so a malformed later message
cannot partly apply an earlier message. Bank selects (CC0/32) and program changes
are excluded, as in offline rendering, because the project preset owns timbre.
Other supported MIDI1 messages, including controller/pressure/bend expression,
retain their order. This protocol does not reinterpret raw MIDI2/UMP as MIDI1.

The response is `{"kind":"block","id":1,"frames":256,"pcm":"base64"}`.
PCM is exactly `frames * 2 * 4` bytes of interleaved left/right, little-endian,
finite Float32 audio. Silence is valid: a continuously loaded instrument may be
waiting for a note. Only the first block resets processing state. Held notes,
pedals and release tails can continue through later blocks.

The JavaScript `openVstStream` owner in `tools/alphatex/vst-stream.mjs` allows one
outstanding render. The output consumer requests another only when it has
capacity, providing backpressure without a growing queue. Each block promise
returns a Buffer of PCM. The ready identity is owned independently of later
caller mutations. The module is shipped by `scripts/install-alphatex.sh`;
`scripts/install-vst-host.sh` fingerprints and ships the updated native host.

`{"kind":"stop"}` ends admission after earlier commands. The host resets its
owned instrument and replies `{"kind":"stopped","frames":"total"}`. The
decimal string counts all returned frames without JSON integer precision loss.
The JavaScript completion settles only after actual process closure and a valid
total; a final reply alone is not completion. The owner must still join completion
after cancellation or failure. EOF without stop, malformed input/replies, invalid
PCM, a missing final reply or nonzero exit fails. `cancel()` or AbortSignal retires
the child; neither cleanup nor reset changes any external MIDI device.

This is a live-synthesis prerequisite. Connecting one MIDI input owner and a
selected audio output, measuring underruns/latency and actual TUI monitoring are
subsequent work. Offline WAV rendering remains a separate operation.

References: [Pedalboard instrument processing](https://spotify.github.io/pedalboard/reference/pedalboard.html)
and [Ardour monitoring signal flow](https://manual.ardour.org/recording/monitoring/monitor-signal-flow/).
