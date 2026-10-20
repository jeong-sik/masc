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

In the phrase and source editors, `:loop START END` selects a range and enables
repetition for the next playback. Selecting another range retires the old
preparation/player before it can publish a replacement. `l` toggles repetition
without erasing that range. Phrase ranges are saved in the document; source
ranges belong to the editing session and leave the original performance/export
unchanged. The arrangement editor retains its own saved playback-loop selection.

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

Opening a phrase or imported MIDI positions the cursor at the earliest note in
its first nonempty track, so a bass or high-register part is visible immediately.
Empty documents keep the C4 insertion position. Choosing an independent MIDI
pattern positions at that pattern's own first note. Later edits and undo/redo
retain the user's valid position; overlapping notes on different channels still require
an explicit channel or event selection. Opening a document does not change it.

Chord recognition presents Tonal's candidate list for notes sounding at the cursor,
including inversions; a candidate is not a harmonic certainty. Close and drop-2
voicings use Tonal's chord intervals. Rootless voicings use its left-hand dictionary
and its top-note voice-leading selection for chord progressions. Unsupported chords
and registers are explicit errors, not fallback substitutions.

`:revoice SYMBOL MODE [OCTAVE [INVERSION]]` changes existing sounding voices in
the chosen track at the cursor, low to high, with one undo revision. It preserves
note identities, onset/length and velocity rather than replacing a rhythmic phrase
with a block chord. The requested voicing must have the same voice count.
Imported MIDI uses the same decision in source ticks and preserves paired
note-off identity and release velocity; explicit channel or note selection resolves
multiple channels/ports. Other expression events retain their original keys and
bytes, so polyphonic pressure is not retargeted by this note edit. Analysis remains
candidate-based and uses key durations, not inferred pedal-extended sound.

The harmonic timeline runs in the owned sequencer worker. It sweeps exact
note-on/off boundaries, retains shared-key overlap counts and rests, and represents
zero-duration source notes as points. Mix analysis uses audible phrase tracks or
the chosen MIDI pattern; track analysis additionally uses the source channel
selection. Original PPQ/SMPTE positions remain the analysis authority. Choosing a
row returns to that tick for further edits; analysis itself never changes the
musical document. Context changes cancel obsolete work, close joins the worker,
and complete candidate data can be exported without overwriting an existing file.

Piano-roll note selections belong to one track/pattern/channel and contain exact
note IDs, with a copy anchor in native ticks. Range selection admits note onsets,
not clipped tails; select-all includes point notes. Session-private clipboard
snapshots preserve rhythm/dynamics and source NoteOff wire form/release velocity.
Paste and group moves validate one whole candidate before a single undo revision;
source port and note-off pairing checks remain authoritative. Non-note events stay
in place. Context/history transitions clear selections while retaining independent
clipboard contents. TUI commands and forwarded shortcuts share these decisions;
admitted clipboard edits drain through close before saving.

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
- Extend full-message source state reconstruction into arrangement playback and
  looping, with port/channel ownership; support MIDI 2.0
  source assets and expression/event editing. Source import and note edit/export
  retain controllers, program/tempo maps, SysEx and original bytes.
- External MIDI clock and a shared sample clock for live scheduling, audio/MIDI
  arrangement playback, and low-latency monitoring/recording.
- Connect the independently developed VST instrument/preset host (#43684) to project
  playback without changing the selected instrument on an error.
- Step/live recording, automation,
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

### Source audition delivery

Imported source performances now have an ordered external MIDI 1.0 audition
path: explicit source-port bindings, full channel expression, F0/F7 wire decode,
tempo/SMPTE scheduling and held-key/hold-pedal stop cleanup. Source pause/resume
and seek now reconstruct retained channel state: ordered bank/program/controller
and supported RPN data, current notes, sustain/sostenuto membership and original
release wire forms. Seek uses source tick/tempo-map or SMPTE timing. Unknown
initial values and opaque device state fail explicitly; this is partial source
reconstruction, with its boundaries documented in tools/alphatex/SOURCE-STATE.md.
Source looping, VST routing, overdubs, shared clock and
practice workflows remain separate unfinished units.

### Arrangement document boundary

The arrangement core retains separate source assets, typed MIDI/audio lanes and
regions with project positions, source-native offsets/extents and repeat counts.
MIDI assets preserve their complete source documents. WAV assets are copied into
project-owned content-addressed files; save-as materializes verified source files
alongside the new JSON document. Region edits and lane removal retain sources.
The terminal arrangement view now consumes this boundary through `--arrange`,
the score view's `a` key and typed saved-document routing. It supports source
import, region placement/editing, undo/redo and revision-protected save/reopen.
IO runs in an owned worker and closes only after cancellation/cleanup and admitted
editor decisions drain. Save-as materializes sources retained by edit history.
WAV lanes now have streamed multi-voice playback with Space pause/resume, beat seek,
explicit output selection and private source snapshots. MIDI lanes now reuse
source-state reconstruction for trimmed/repeated regions and beat seek, with
explicit asset/port outputs and physical destination/channel ownership admission.
Finite repeat counts remain compressed; missed complete copies skip to the
current phase. Mixed WAV/MIDI shared-clock playback and overdub remain unfinished.
See [the core contract](../../../tools/alphatex/ARRANGEMENT.md).

### Imported time-signature maps

Imported SMF sources expose `:meters`, with Up/Down selection, Shift+Left/Right movement,
Enter editing and Delete removal. `:meter NUM DEN [AT [CLOCKS NOTATED32NDS]]` inserts or
changes a time signature at the cursor or an explicit source position. `:meter-event ID`,
`:meter-value NUM DEN [CLOCKS NOTATED32NDS]`, `:meter-move AT` and `:meter-remove`
address a selected event. A numerator/denominator edit preserves both auxiliary fields;
a new event defaults to 24 MIDI clocks per click and eight notated 32nds per MIDI quarter.
`+`/`-` change the numerator. Shared undo/redo includes the complete source document.

The active signature follows the source cursor. Positions remain quarter-note beats for
PPQ and frames for SMPTE, without changing note timestamps, tempo integration or playback
seconds. This edits SMF metadata; it does not add bar-based navigation or a metronome.
Format 0/1 insertion uses the conductor track; format 2 requires explicit pattern selection.
Several signatures at one tick require explicit event selection. Original unknown or
unrecognized metadata stays opaque, and untouched tracks/containers retain their bytes.
The exported four-byte layout follows [JZZ's SMF time-signature contract](https://www.jazz-soft.net/doc/JZZ/jzzmidi.html).
Arrangement handoff uses the same recognized, last-at-tick-zero signature as the editor.
Its metadata admits every exact SMF denominator power; explicit practice/count-in still
uses its existing native clock admission and may reject a meter outside that range.
