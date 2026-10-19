# macOS audio and MIDI capture

`MusicSession.swift` uses the system CoreAudio and CoreMIDI drivers. It records
all channels of the selected audio input and selected MIDI sources concurrently.
The input is identified by its persistent CoreAudio UID, MIDI sources by their
CoreMIDI unique IDs. It does not change the system default input or output.

Build the standalone helper with the Xcode command-line tools:

```sh
xcrun swiftc -parse-as-library -O MusicSession.swift -o music-native \
  -framework AVFoundation -framework CoreAudio -framework CoreMIDI -framework AudioToolbox \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./music-native devices
./music-native record --input DEVICE_UID --midi all --directory NEW_TAKE_DIRECTORY
```

`--midi` accepts `all`, `none`, or a source ID from device discovery. Recording
starts only with the explicit `record` command. Write `stop` followed by a
newline to stdin, close stdin, or send SIGINT/SIGTERM/SIGHUP to finalize. macOS
microphone permission applies to input capture; it is not required for discovery.
The executable embeds its microphone purpose string from `Info.plist` for macOS
authorization. No microphone authorization database or terminal app is modified.

Each take owns a new directory. Existing directories are refused. The directory
contains float32 PCM `audio.wav`, per-block channel min/max peaks and original
host/sample timestamps in `audio-blocks.jsonl`, full UMP words and timestamps in
`midi.ump.jsonl`, and an atomic final `session.json` manifest. A failed take keeps
its evidence. Only a successfully finalized take has state `recorded` and exit 0.

Stdout is JSON Lines: `recording` declares sample rate, channels, input, MIDI
sources and the mach clock mapping before `audio`/`midi` events. `stopped`
contains the final manifest; `error` reports a failure. CoreAudio and CoreMIDI
share mach host ticks. Convert the difference from `requestedStart` using
`numer/denom` nanoseconds per tick. No wall-clock delivery time is substituted.
When a MIDI packet lacks a timestamp, `timestampOrigin: received` explicitly
identifies its observed callback time. The audio host timestamp describes the
block's first sample; the WAV frame offset is separate from device sample time.

CoreMIDI converts incoming MIDI 1.0 to UMP protocol 2.0. The helper retains every
UMP word, including controllers, SysEx and MIDI 2.0 expression. A bounded audio
buffer pool and MIDI queue fail the take on saturation instead of dropping data.
Input format/sample continuity, device liveness, engine configuration and MIDI
source removal are monitored. This prevents a stopped or truncated input from
being finalized as an uninterrupted successful take.

Input monitoring is described in [INPUT-MONITORING.md](../INPUT-MONITORING.md).
The capture helper currently provides no audio mixing, MIDI output, clock
synchronization to external equipment, or latency compensation.
BlackHole loopback and an isolated virtual MIDI source have exercised simultaneous
48 kHz stereo capture. Physical USB interfaces and keyboards need separate device
verification; discovery alone does not establish capture on a specific device.
