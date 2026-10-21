# Native captured UMP experiments

In an arrangement, `:edit-ump [ASSET]` opens a captured performance's MIDI2
attacks. This edits a separate overlay on the verified original packets. It does
not convert notes, velocities or clocks into MIDI1/960 PPQ. Original WAV, UMP,
packet boundaries, source/group/channel identities and timestamp-origin flags
remain stored under their original hashes.

Select an attack with Up/Down or its displayed `PACKET:WORD` identity. Packet
indices and word offsets start at zero and belong to the original MIDI part.
`:scope SOURCE GROUP CHANNEL` selects that scope's first MIDI2 attack; groups and
channels use 1–16. MIDI1 messages, controllers, SysEx, flex/stream and unknown
messages remain source data; this first editor lists MIDI2 NoteOn messages.

```
pitch-absolute 60.5
velocity 0
revoice Cmaj7 drop2 4 0
harmony
undo
redo
reset-note
play
export /existing/parent/new-native-take
```

`pitch-absolute` is an explicit per-attack absolute-pitch override. It sets
Attribute 3 Pitch7.9, accepting exact MIDI-note units in 1/512-semitone increments
from 0 through 127.998046875. It keeps Note Index fixed, so original NoteOff,
poly pressure, per-note controllers/bend and management continue addressing the
same indices. It does not retarget or guess their ownership. Existing Attribute 3
fractional pitch is retained unless explicitly changed. Manufacturer/Profile or
unknown attributes cannot be overwritten by this command. `velocity` changes
the full 16-bit attack value 0–65535, preserving the attribute and release bytes.
MIDI2 velocity zero remains an attack. `reset-note` removes both edits for the
selected attack; the original message is restored.

`:revoice SYMBOL MODE [OCTAVE [INVERSION]]` changes the exact-onset group sharing
the selected attack's source, group and channel. Voices sort by their current
Attribute 3 pitch or original key index, then original packet/message order.
The chosen close/drop2/rootless voicing must match the group count. This applies
explicit absolute pitches in one undo revision without changing timing, indices
or dynamics. It does not infer arpeggio groups, held pedal voices or release
pairing. An unsafe attribute in any voice refuses the whole edit.

`:harmony` reports onset candidates. Original unattributed keys are labelled
key-index candidates: MTS, per-note tuning, bends and vendor/Profile semantics
are not resolved into an acoustic pitch model. Attribute 3 groups use their
absolute values. Fractional pitches and opaque attributes remain visible without
rounding into a 12-tone chord label. Chord candidates are not harmonic verdicts.

Space or `:play` opens the existing captured-session viewer on the same edited
packets. Choose native MIDI2 destinations there; source-specific bindings from
the arrangement are retained. The WAV is the unchanged original performance,
not pitch-shifted audio. The session's Space starts/stops audition and q returns
to the UMP editor. Existing native state reconstruction and destination ownership
rules still apply; a refused seek or opaque state does not destroy the draft.
Preparation remains cancellable, and a borrowed viewer/native owner closes
before the editor or arrangement resumes.

q returns a changed overlay as a new capture asset in one arrangement undo
revision. Ctrl+C or an external session abort discards the child result. No edits
means no extra asset. Existing source assets and regions remain unchanged.
Use `:place NEW_ASSET BEAT` to place it independently, or `:open-take` to audition.
Use `:split-take` to compare a MIDI component against the original audio. Existing
save/save-as copies the raw parts and retains the overlay for portable reopen;
reopening the variant editor reads the original packets and applies the overlay
once. Playback preparation validates the original parts and edit targets before
materializing an owned edited snapshot for standalone or arrangement transport.

`:export NEW_DIRECTORY` refuses an existing target. It writes the edited UMP
JSONL, original WAV/audio blocks/session clock, original MIDI JSONL and
`ump-source.json` with original hashes, overlay and edited-MIDI hash. The packet
times stay integer host ticks; no clip-tempo conversion occurs. A failed or
cancelled unsealed export removes only its newly owned target. This bundle is
an archival/native-take export; importing its edited session as a take treats
those edited packets as a new source, rather than reconstructing editor history.
The saved arrangement is the portable editable document. The captured viewer's
separate MIDI2 Clip export still declares its 1000 PPQ quantization.

This first native editor does not yet add time/structure edits, per-note
controller editing, raw practice-take editing or MIDI2 Clip import. These remain
part of the sequencer objective tracked by #44748. Focused source/worker/controller
and native-protocol checks do not establish installed Ghostty or physical-device
behavior.

Protocol: [MMA/AMEI UMP 1.1.2](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf),
§7.4.2, §7.4.14–7.4.15.3 and Appendix C. Attribute 3 makes Note Number an index;
absolute pitch overrides previous tuning for that attack only. The persisted
`ump` overlay has schemaVersion 1, original `midiSha256` and unique note edits
with original `packet`/`word` plus optional unsigned 16-bit `pitch`/`velocity`.
