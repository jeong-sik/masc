# TUI music laboratory

The requested destination is a sequencer in the TUI: write and change phrases,
experiment with chords and voicings, arrange multiple MIDI/audio tracks, and
practice with connected MIDI instruments and audio interfaces. A recording viewer
alone does not satisfy that destination. The existing simultaneous capture work is
tracked in #43677; source/group/channel UMP and WAV remain the original take.

The next implementation stack introduces an editable musical document and a
piano-roll terminal editor. Quarter-note ticks (960 PPQ) are the editing authority;
wall clock conversion happens in transport. Each MIDI track owns a channel and
program, with notes, velocity, mute, solo, level and pan. MIDI CC7/CC10 controls
are shared by export and synthesis. Out-of-range PCM samples are counted before
conversion so dense mixes can be adjusted instead of hiding clipping.
Same-key overlaps on one channel are
rejected transactionally because ordinary MIDI note-offs cannot identify voices.
Undo/redo retains complete document revisions. Saving refuses an externally changed
file; save-as retains edits without replacing it. Standard MIDI export and SoundFont
preview consume the same schedule, including clipped notes spanning loop boundaries.

Each save first writes and syncs a private local candidate and a separate publication
inode in a sibling `.song.json.save-*` directory. Updating an existing project moves its current inode
to that directory's `previous.json`, checks the claimed bytes against the loaded
revision, then publishes the publication inode with an exclusive hard link. The
retained `local.json` is a separate inode, so writes through the live project path
cannot alter it. An unrelated
editor recreating the project pathname wins that pathname; saving reports a
conflict and the retained local/claimed paths. A rejected update restores the
claimed inode only when the project pathname is still empty. Successful saves
also retain these files: another editor can still write through an older open file
descriptor, and that inode must remain recoverable. These directories are retained
history, not temporary files to remove automatically. A crash during the claim can
leave the project pathname absent; recover from its sibling history. The lock only
coordinates this application's writers and does not lock unrelated editors.

Chord recognition presents Tonal's candidate list for notes sounding at the cursor,
including inversions; a candidate is not a harmonic certainty. Close and drop-2
voicings use Tonal's chord intervals. Rootless voicings use its left-hand dictionary
and its top-note voice-leading selection for chord progressions. Unsupported chords
and registers are explicit errors, not fallback substitutions.

Native WAV preview uses AVAudioEngine/PlayerNode buffers with pause, seek and
looping, pinned to a CoreAudio output. External MIDI preview uses a separately
owned CoreMIDI sender and pins a destination by unique ID. It projects the same
notes/programs/CC7/CC10 schedule directly without rendering audio. The sender
releases only its held keys, chases current notes after seeking/resuming, and
never flushes a shared endpoint or sends global all-notes-off. Envelopes retrigger
when chased. Its host deadline queue is not an external MIDI clock or a sample
locked audio/MIDI engine. Virtual destination and loopback observations are
narrower than physical hardware and visible Ghostty proof.

This stack is one step toward the full destination. Further work remains:

- Retain editable arrangements of MIDI clips and WAV regions with repeat/offset,
  recording into existing projects and overdubs; retain raw expression provenance.
- Connect the MIDI source-asset editor to full-message audition and arrangements,
  then support MIDI 2.0 source assets and expression/event editing. Source import
  and note edit/export preserve controllers, program/tempo maps, SysEx and original
  bytes; this is not yet an imported-performance playback path.
- External MIDI clock and a shared sample clock for live scheduling, audio/MIDI
  arrangement playback, and low-latency monitoring/recording.
- Connect the independently developed VST instrument/preset host (#43684) to project
  playback without changing the selected instrument on an error.
- Piano-roll selections, copy/paste, step/live recording, automation,
  flexible tempo/meter maps, metronome/count-in and practice feedback.
- Verify real MIDI and audio hardware and the actual Ghostty UI. Loopback/virtual
  sources, PCM files and terminal controller evidence prove narrower behaviors.

Keep these as explicit remaining work until each full scenario has evidence. A
passing project test, source approval, installed helper and visible UI are separate
claims. This feature does not need a local OCaml/Dune build.

Library contracts: [Tonal chord](https://github.com/tonaljs/tonal/tree/main/packages/chord),
[voicing](https://github.com/tonaljs/tonal/tree/main/packages/voicing),
[voice leading](https://github.com/tonaljs/tonal/tree/main/packages/voice-leading),
and [JZZ MIDI files](https://jazz-soft.net/doc/JZZ/midifile.html).

## Imported-performance audition boundary

The next transport connection must consume the source performance's complete
ordered message stream, not `sequenceEvents` from the phrase schema. Its seconds
come from the retained PPQ tempo map or SMPTE clock. Meta events remain in the
source/export; channel data and F0/F7 wire fragments keep their ordering and
original port identity.

Source ports need explicit destination bindings. A file with several numbered
ports must not collapse them into one selected output. The owned native sender
must account for held notes and stateful controllers, including pedal releases,
through pause, seek, route changes, failures and shutdown. F7 escape data may
contain wire messages, so key ownership cannot assume that every source event
is a pre-decoded three-byte note. Large SysEx needs packetization under CoreMIDI's
actual packet representation, without an arbitrary vendor-message size cap.

Controller/program/bank/RPN state and opaque SysEx have different replay effects.
A seek/resume implementation must define what it restores and report unsupported
state reconstruction; silently using the phrase sender's volume/pan chase would
lose the source performance. Source audition does not establish MIDI clock sync,
audio/MIDI sample alignment, hardware latency or physical-device behavior.
