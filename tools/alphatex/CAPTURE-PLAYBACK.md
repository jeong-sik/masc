# Original captured WAV and MIDI 2.0 playback

A saved take can audition its original WAV and UMP stream together. Open it with:

```sh
masc-alphatex --session /path/to/take --output AUDIO_UID --midi-output=MIDI_UID
```

In the take viewer, `o` cycles MIDI outputs (including WAV-only selection), and
`a` cycles audio outputs (including the system default). Space starts or stops
the complete take. `:midi-output MIDI_UID` sets a default MIDI route;
`:source INPUT_SOURCE_ID MIDI_UID` overrides one recorded input's route, and
`:output AUDIO_UID` chooses audio. Input IDs remain the recorded source identities,
not display names. A new default MIDI selection clears source overrides.
An arrangement's `:open-take` also passes its selected audio and default MIDI
outputs to this viewer. WAV-only audition with an explicit output uses the native
WAV owner; an output selection is never silently ignored by `afplay`.

## Source and clock authority

Preparation makes private copies of the original capture and validates them
before opening outputs. UMP packets retain original words, input identity,
host ticks and timestamp origin. The native scheduler splits only at complete
UMP message boundaries and sorts by original host time, preserving source order
at equal times. It does not convert MIDI 2.0 to note-only data or MIDI 1.0 bytes.
Original note attributes, release velocity, high-resolution controllers,
per-note expression, system data and SysEx remain in that complete stream.

Host times are unsigned integer strings. The clock subtracts integers before
converting a duration using the retained rational timebase. Playback starts at
the earliest of requested capture start, first WAV audio and captured MIDI,
preserving any MIDI pre-roll. The WAV starts at its original first-audio offset
and uses its original contiguous frames and sample rate. Original audio-block
timing remains retained source evidence; this does not compensate device drift,
input/output latency, or missing device-clock time between blocks.

One native owner schedules WAV and UMP against a shared future host-clock epoch.
A MIDI tail can outlast the WAV. Due messages are sent with `MIDISendEventList`
and protocol 2; no future CoreMIDI queue remains after stop. The selected endpoint
must retain its identity, be available and report native MIDI 2.0. This route
diagnoses a MIDI 1.0 endpoint instead of silently choosing lossy conversion.

Each captured source has an explicit destination. Channel messages may share a
destination when their group/channel ownership is disjoint. Group-wide system,
SysEx and Flex events require a single source in their output group; global or
unknown-scope UMP events require an independent endpoint. This prevents independent
inputs' original device state or exclusive streams from being merged accidentally.

Stopping or endpoint loss stops both source kinds. The MIDI owner releases only
its acquired keys, pedals and incomplete exclusive streams, retaining uncertain
send ownership through cleanup. It does not broadcast All Notes Off or attempt
to reverse arbitrary vendor commands. The view waits for the native child and
private files before returning terminal ownership.

## Remaining sequencer integration

Native take playback supports `p` to pause/resume, `:pause`, `:resume`, and
`:seek SECONDS` to move WAV and MIDI together. Space or `:stop` stops the take.
Select an audio or MIDI output to use this native route; default WAV-only `afplay`
audition continues to use Space for play/stop.

On resume or seek, reconstruction preserves original control order and restores
only keys still held or retained by sustain/sostenuto at the new position.
It retains original Note On attributes and releases, program/bank ordering,
channel controllers and pitch, per-note controllers/pitch/pressure, and ordered
per-note detach/reset. Relative registered/assignable parameters require an
absolute value in the source prefix. MIDI 1.0 channel-voice UMP words remain
MIDI 1.0 UMP words; no MIDI 2.0 expression is reduced to that dialect.

Previously changed fields need an explicit source baseline, including before a
surviving Note On that selected a patch or pitch. Unknown initial values are not
invented. Unsupported reconstruction stops both owners with a diagnostic; it
does not change the retained source. Opaque system/SysEx effects, channel-mode
changes, Hold 2, one-shot Portamento Control, MIDI 1.0 compound parameter controls and mixed message dialects
on one output channel currently require complete-source playback. Full-source
audition still emits every original message. Per-note management and CC121 are
handled according to the [UMP v1.1.2 specification](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf).

Staging sends no restored Note On before the shared future epoch. If its callback
is delayed, it reconstructs that current phase so expired keys stay silent.
Re-triggered live notes start a new instrument envelope; release tails, arbitrary
device internals and sample-perfect or acoustically seamless resume are not
reconstructed. [Captured regions](CAPTURE-UMP-REGIONS.md) also use the ordinary
arrangement play command with exact cuts and compressed repeats. Existing SMF
regions retain their separate implementation; SMF/UMP composition remains work.

Monitoring, overdubbing against the arrangement, latency compensation, external
MIDI clock, VST routing, practice/count-in and physical hardware verification
remain part of the full sequencer work. Native protocol tests, virtual receivers,
loopback PCM and visible/audible hardware behavior are separate evidence layers.
