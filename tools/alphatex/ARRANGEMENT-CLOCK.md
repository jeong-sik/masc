# Native MIDI/WAV arrangement clock

`music-arrangement` can own WAV voices and expressive MIDI regions in one native
process. This is the native contract for the terminal's forthcoming mixed-lane
route. The arrangement editor still uses its separate WAV and MIDI transports;
Space on mixed audible lanes does not yet use this contract.

## Plan and ownership

The existing `play --file plan.json [--output CoreAudio-UID]` command accepts:

- schema 1, `kind: "wave-arrangement"`: WAV assets and regions;
- schema 2, `kind: "mixed-arrangement"`: the same WAV assets and regions plus
  `midi`, a schema-3 MIDI region timeline with explicit destination bindings.

The outer duration is the latest WAV or MIDI region end; the embedded MIDI
timeline duration must equal it. WAV source frames, sample rates, content hashes
and compressed repeat counts retain the [WAV contract](ARRANGEMENT.md).
The embedded timeline retains the [source-state contract](SOURCE-STATE.md),
original expressive messages, release velocities, source clocks and port routes.
Conflicting physical MIDI channel owners remain admission errors. Source files
and MIDI destinations are validated before playback begins.

One owner controls start, pause, seek, resume, stop and failures. A selected
output or MIDI destination failure stops both parts. Neither part's earlier
natural completion truncates the other. MIDI resources remain owned until the
combined owner stops. Cleanup releases only MIDI keys/pedals it owns; a cleanup
failure makes the final result unsuccessful.

## Common epoch

All lifecycle decisions and the embedded MIDI timer use the main dispatch queue.
The audio engine schedules its voices at a future mach host timestamp with the
existing render-quantum/presentation-latency lead. `AudioConvertHostTimeToNanos`
converts that timestamp for the MIDI timer. Admission and staging send no MIDI
restoration; the first timer at the common epoch restores the requested source
state. A missed start deadline fails rather than assigning a fresh MIDI epoch.
A delayed first callback skips expired region copies while preserving the
original boundary event order for copies that remain live.

Pause takes the audio transport's position and stages MIDI at that same value.
A paused seek stages both without starting voices or sounding MIDI keys. Resume
chooses a new common epoch and reconstructs the supported MIDI state. Unknown
source baselines and unsupported state reconstruction fail explicitly.

Mixed snapshots report `clock` with the mach host `anchor`, its converted
`midiAnchorNanoseconds`, project base `position`, `midiPosition`, output
`renderQuantum`, `sampleRate` and `presentationLatency`. The timestamp fields
are decimal strings to avoid JSON integer precision loss. Audio render position
and a MIDI callback's wall-clock observation can differ by device buffering and
scheduler delay; these fields do not establish sample-accurate alignment.

Apple's CoreAudio HostTime.h defines host-tick/nanosecond conversion, AVAudioTime.h
identifies hostTime as mach_absolute_time, and CoreMIDI MIDIServices.h defines
MIDITimeStamp in that host-clock domain. Dispatch's default clock uses the same
mach clock. These contracts establish a shared epoch, not a hard real-time MIDI
or acoustic latency guarantee.

## Focused verification

```sh
node tools/alphatex/native/test-midi-transport.mjs
node tools/alphatex/native/test-arrangement-clock.mjs
```

These compile production scheduling/lifecycle methods with synthetic clock,
endpoint and audio effects. They verify decisions without opening devices.
Actual native verification must separately observe loopback PCM and MIDI
callbacks, including both possible completion orders, paired controls and
selected-route failure. Loopback and virtual endpoints do not establish a
physical interface, instrument response or visible terminal behavior.
