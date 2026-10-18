# TUI music laboratory

The requested destination is a sequencer in the TUI: write and change phrases,
experiment with chords and voicings, arrange multiple MIDI/audio tracks, and
practice with connected MIDI instruments and audio interfaces. A recording viewer
alone does not satisfy that destination. The existing simultaneous capture work is
tracked in #43677; source/group/channel UMP and WAV remain the original take.

The next implementation stack introduces an editable musical document and a
piano-roll terminal editor. Quarter-note ticks (960 PPQ) are the editing authority;
wall clock conversion happens in transport. Each MIDI track owns a channel and
program, with notes, velocity, mute and solo. Same-key overlaps on one channel are
rejected transactionally because ordinary MIDI note-offs cannot identify voices.
Undo/redo retains complete document revisions. Saving refuses an externally changed
file; save-as retains edits without replacing it. Standard MIDI export and SoundFont
preview consume the same schedule, including clipped notes spanning loop boundaries.

Chord recognition presents Tonal's candidate list for notes sounding at the cursor,
including inversions; a candidate is not a harmonic certainty. Close and drop-2
voicings use Tonal's chord intervals. Rootless voicings use its left-hand dictionary
and its top-note voice-leading selection for chord progressions. Unsupported chords
and registers are explicit errors, not fallback substitutions.

This stack is one step toward the full destination. Further work remains:

- Retain editable arrangements of MIDI clips and WAV regions with repeat/offset,
  recording into existing projects and overdubs; retain raw expression provenance.
- MIDI import and MIDI 2.0 editing/export without losing controllers, expression,
  program/tempo changes, SysEx or original source identity.
- MIDI destination and audio device selection, external clock and live scheduling;
  sample-continuous loop playback and low-latency monitoring/recording.
- Connect the independently developed VST instrument/preset host (#43684) to project
  playback without changing the selected instrument on an error.
- Piano-roll selections, copy/paste, step/live recording, automation, per-track levels,
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
