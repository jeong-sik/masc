# MIDI source state on pause, resume and seek

In the imported MIDI editor, Space pauses/resumes the same owned native sender,
:seek POSITION moves using the source's quarter-note tick axis (or its displayed
SMPTE frame axis), and :stop releases the owned keys/pedals and ends playback.
A paused seek remains silent until resume. Source files retain their original
bytes and editing/export overlays; reconstruction does not rewrite the source
into the phrase note schema.

The sender folds the ordered original wire prefix at the destination position.
Bank select, program and ordinary controller/RPN writes retain their original
order. A write that a later write of the same field replaces is not resent,
unless a Program Change applied its bank or a Data Entry its parameter
selection, so a long controller or pitch bend stream restores as its final
value. Relative Data Increment/Decrement steps are resent with the absolute
values they adjust, because devices step different components. Absolute RPN components remain separate, so a source using only Data
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

Each sounding note retains the program and bank selected when its Note On was
sent, including notes retained by sustain or sostenuto. When that patch differs
from the channel's current patch, seek/resume sends the note's bank selects and
Program Change before its Note On. After the channel's notes, it restores the
current patch, then any bank selection that followed the current Program Change,
so later source messages play under the current patch. Bank selectors take
effect for this comparison at Program Change; a pending bank selection alone
does not change a held note's patch.

Some of those earlier patches are unknown. A note attacked before its channel's
first Program Change used the device's initial program. A bank register that the
source had not yet set at a Program Change held the device's initial value,
which is lost once the source sets that register. When a held note needs such a
patch, seek/resume reports an error before replay instead of guessing it.

The current patch can be unknown the same way. Seek/resume re-sends the current
Program Change, with no bank select for a register the source had not set before
it, so the device applies whatever that register holds. If playback never sent
the register, that is still the initial value and the same patch returns. If
playback has sent a bank select for it since, the device holds that later bank,
and seek/resume reports an error before replay instead of guessing the initial
bank. This holds with or without a sounding note. A later bank select that
playback has not reached yet does not cause the error.

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
