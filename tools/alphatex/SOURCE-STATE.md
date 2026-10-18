# MIDI source state on pause, resume and seek

In the imported MIDI editor, Space pauses/resumes the same owned native sender,
:seek POSITION moves using the source's quarter-note tick axis (or its displayed
SMPTE frame axis), and :stop releases the owned keys/pedals and ends playback.
A paused seek remains silent until resume. Source files retain their original
bytes and editing/export overlays; reconstruction does not rewrite the source
into the phrase note schema.

The sender folds the ordered original wire prefix at the destination position.
Bank select, program and ordinary controller/RPN writes retain their original
order. Absolute RPN components remain separate, so a source using only Data
Entry MSB can resume without an invented LSB; relative writes require their full
absolute baseline. Channel and polyphonic pressures are restored. Sources retain
ports and explicit destination bindings. A split short message retains its
running/pending decoder state across a seek.

Sustain and sostenuto have separate ownership. Reconstructed keys captured when
sostenuto rose are sent before the pedal is restored; keys pressed later follow.
Already released sustaining notes are re-created and released using their
original NoteOff or zero-velocity NoteOn wire form. The envelopes retrigger:
this reconstructs MIDI message state, not oscillator phase or an audio sample
position. Pause first consumes all due source messages, including zero-length
notes, then releases only owned keys and active hold pedals. Final shutdown,
destination removal and failed sends retain the existing cleanup rules.

A seek cannot recover an external device value that was never specified in the
source prefix. Previously changed fields must have a known value at the target;
otherwise the sender reports failure and performs cleanup. It does not keep a
later volume/program/parameter value while claiming the earlier state was restored.
The sender does not query the external instrument for its pre-playback state.

Opaque SysEx/system effects, device-specific NRPN data, Hold 2, high-resolution
velocity-prefix state, unsupported/incomplete RPN state and channel-mode changes
still require more reconstruction support. Their original ordered messages
continue to play from the source beginning. A reconstruction crossing such state
reports an error rather than replaying arbitrary device commands or ignoring
their effect. Source looping is still explicitly unavailable.

Reset All Controllers follows the explicitly defined MIDI RP-015 reset fields;
bank/program, volume/pan, effect/sound controllers and registered parameter data
remain distinct from resettable controller state. Devices with documented
departures from the recommended practice need their own device profile and
hardware evidence.

This is the reconstruction boundary for future trimmed/repeated MIDI regions.
It does not yet schedule MIDI arrangement regions, arbitrate overlapping shared
channels, align MIDI to WAV on a shared sample clock, play MIDI2 source assets,
connect VST instruments, or record overdubs.

Primary contracts: [MIDI control/RPN assignments](https://midi.org/midi-1-0-control-change-messages),
[RP-015 Reset All Controllers](https://midi.org/response-to-reset-all-controllers)
and [MIDI 1.0 addenda](https://midi.org/midi-1-0-addenda).
