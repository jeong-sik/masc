# Phrase playback and colour usability

A real saved phrase reproduced `synthesizer produced a non-finite sample` when
AlphaSynth used the configured FluidR3_GM SF2. The same phrase rendered with
the bundled font, and the same configured font rendered through the existing
explicit FluidSynth path as finite, nonzero, unclipped PCM. This change makes
that compatible engine directly selectable. It does not repair AlphaSynth's DSP
or replace a chosen instrument when rendering fails.

The instrument menu distinguishes FluidSynth and AlphaSynth; source MIDI offers
its supported FluidSynth route. `f` explicitly chooses the configured SF2 with
FluidSynth and previews it. `Space` plays/pauses, `0` restarts the playback range,
and `.` stops. Pitch classes have distinct terminal-palette colours, selection
is yellow, the playhead is green and the cursor is magenta; the transport row
stays visible. All pitch, timing, dynamics and original audio data remain intact.

Two review failures were reproduced and repaired: nested selection admission
could start a late preview after stop, and harmony inspection swallowed direct
transport keys. Selection now begins inside the admitted task; existing owner
cancellation blocks late adoption, and transport dispatch precedes harmony keys.
Focused tests exercise requests, saved decisions, stale results and shutdown,
without asserting terminal text or layout. The first added controller fixture
needed to close its own mock picker before invoking its selection callback and
to consume its own preparation promise; those harness failures were corrected
before the final test result and are not described as product failures.

An actual private auxiliary TUI selected FluidSynth, started a native output
child pinned to BlackHole, paused, restarted, stopped, played again, stopped and
saved the private copy with exit 0. Native children disappeared after stop. The
saved engine changed as requested, the notes remained identical and the user's
original project stayed byte-identical. This is output-graph/process and source
TUI evidence, not received PCM, acoustic or physical-interface proof. A local
preview renders the captured ANSI; it is not a Ghostty screen capture. The
private musical content and raw logs are excluded from this public evidence.

[receipt.json](receipt.json) records hashes, counts and remaining limits. The
full sequencer/MIDI objective remains active.

After whole-stack rebase onto main containing the native UMP event-group work,
the combined twelve-file focused selection passed 92/92. All phrase product
files remained byte-identical; the new main's three UMP/tick modules entered the
combined runtime. The actual private TUI journey was repeated with that new
runtime and exit 0. The official auxiliary installer then published the same
revision to the default launcher; every copied source and seven unchanged native
helpers was hash-compared. The previously observed music PID was absent at installation readback; the
operator can open Music to use this update. A running view keeps the immutable
runtime with which it started. This
installation is from the unmerged source candidate; it is not a main merge or a
claim that the operator's own Ghostty session was observed running the update.
