# Native WAV transport protocol

`music-transport play --file WAV [--output DEVICE_UID] [--loop]` starts one
macOS `AVAudioEngine` and `AVAudioPlayerNode`. The WAV is decoded into one
Float32 PCM buffer. `--loop` schedules that buffer with the native `.loops`
option, so repeated boundaries require no decoder restart, process restart or
main-queue callback. After seeking, a queued tail buffer is followed immediately
by the full repeating buffer. Non-looping playback terminates from the node
`dataPlayedBack` completion, fenced by scheduling generation after seeking.

The whole decoded file must fit `AVAudioPCMBuffer` resource constraints, including
its UInt32 frame-capacity API. Allocation or incomplete decoding fails explicitly.
There is no additional phrase-length limit, timeout or automatic fallback.

The selected output must exist and expose output channels. An explicit UID is
never substituted. Without `--output`, the current default output is resolved
once at startup. Both paths set the output node audio unit
with `setDeviceID` and verify the device ID and UID before and after starting
playback. The system default is never changed. The output remains pinned for
this transport session, including while paused.
Device removal, loss of output streams, or a mismatched engine device fails the
session; the transport never follows another output as a recovery action.

The process accepts UTF-8 JSON objects, one per stdin line:

```json
{"kind":"pause"}
{"kind":"resume"}
{"kind":"seek","seconds":0.5}
{"kind":"status"}
{"kind":"stop"}
```

Pause/resume are idempotent. Seek accepts finite seconds between zero and the
file duration. Seeking to the endpoint finishes a non-looping session; in a loop
it selects zero. Seeking while paused stays paused. `status` reports the actual
player position; it neither advances a synthetic clock nor changes playback.
Malformed commands, invalid seek positions and decode/play failures stop with
an explicit error and a nonzero process exit.

Stdout contains only newline JSON events. Each state event has this shape:

```json
{"kind":"playing","currentTime":0.5,"duration":2.0,"device":{"id":"DEVICE_UID","name":"Output name","outputs":2},"loop":true}
```

The kind is `playing`, `paused`, or `stopped`. State events acknowledge startup,
each command and termination. A stopped event adds `reason` and `success`.
Current time derives from the node
`playerTime(forNodeTime: lastRenderTime)` sample position and decoded sample rate,
modulo the PCM frame length for looping. Pause retains the captured position.
These events do not
establish hardware sample continuity or provide an output-latency measurement.
They are not periodic: clients can request `status` for a fresh position.

Errors emit `{"kind":"error","message":"..."}` followed by `stopped` when a
transport has been created, then exit nonzero. Startup argument/device/file
errors can occur before a transport exists and emit only `error`. Diagnostics
also go to stderr. A broken stdout pipe stops playback and exits nonzero; it
cannot acknowledge failure over the closed pipe. SIGPIPE is ignored so writes
throw and teardown runs.

`stop`, stdin EOF, SIGINT, SIGTERM and SIGHUP finalize the owned player and
listeners. Natural completion uses the node playback completion and exits. All
player operations, device notifications, command application, completion and
teardown run on the main lifecycle. Clients must await process closure before
releasing the WAV or restoring a terminal that owns this transport.

The native looping and sample-timeline contracts are declared in the macOS SDK's
`AVFAudio/AVAudioPlayerNode.h`; output routing uses `AudioUnit/AUAudioUnit.h`.
`AVAudioEngineConfigurationChange` and CoreAudio property listeners detect a lost
selected route or a stopped engine; they terminate instead of changing devices.
