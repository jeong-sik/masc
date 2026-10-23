# Selected piano-roll timing and dynamics

Scope: #45253 → #45254, Native Stack #45255, initial base
`aa0fea67e03a1fc8d40b4d5844ec8be836a82566`. The sequencer goal remains active.

The phrase/original-MIDI editors already supported selection, copy/paste,
revoicing, full-track quantization and single-note dynamics. This adds selected
attack quantization and selected absolute/relative dynamics so a phrase fragment
can be varied without changing other notes or tracks.

- `:quantize-notes GRID` rounds selected starts to the nearest native tick grid;
  ties go forward. Durations, attack velocities and release forms are retained.
  The selection anchor follows the same grid for later clipboard edits.
- `:velocity-notes VALUE` sets selected attack velocities.
- `:velocity-add-notes DELTA` changes their dynamics by a relative amount.
  Every resulting attack must be 1–127; invalid results refuse the complete edit.
- Shared phrase/source batch validators enforce source routing, pairings,
  overlaps and document boundaries. Each command is one undoable transaction.
  PPQ documents use beats; SMPTE documents use frames, retaining original ticks.
  The commands do not rewrite raw UMP or notation.

## Direct verification

Node focused suites: `selected-note-transforms`, `note-selection`,
`sequencer-editor`, `midi-source-editor`: **25/25 PASS**, zero skipped/cancelled.
They exercise phrase/PPQ/SMPTE edits, actual point notes, original clock,
release forms/velocities, other channels/tracks/controllers, selection/history,
transactional port/collision/invalid-value refusal, project save/reopen and
actual MIDI serialization/reimport. Initial source-clock fixture assertion used
a nonexistent document field; corrected to the decoded performance timing,
then all cases passed. Node syntax and `git diff --check` also pass.

Actual source terminal proof used a private tmux server and the real
`viewer.mjs --project` piano roll. Its saved two-track phrase contained a
voice-led Dm7/G7/Cmaj7 progression (12 notes) and two Bass notes. Commands were
entered through the terminal: `track 2`, `select-all`, `quantize-notes 0.25`,
`velocity-add-notes -10`, `save`, `export .../edited.mid`.

Independent saved-data reads confirmed:

| Bass note | Source tick | Length | Attack velocity |
| --- | ---: | ---: | ---: |
| C2 | 240 | 480 | 90 |
| G2 | 1200 | 480 | 100 |

The harmony track still contains its 12 notes. Exported MIDI independently
contains the same Bass ticks/pitches/velocities. Project SHA256:
`645dd7eb9ba5dc5d3c5baf9d7cbe842458e8ae4299f0a2370aa37e7e690d4a74`.
MIDI SHA256:
`2082d1d67fa6170c437a501ddf5f74fb0f48d1eaaa2be590c1a04fabc0a60d74`.

The editor was closed with `q`; its dedicated tmux server/session no longer
exists. No input recording or audio playback was opened. Raw test log, manual
terminal capture, saved project, MIDI and verification JSON are in the local
`masc-music-selected-evidence-20261023` temporary evidence directory.

This is real source auxiliary-TUI execution, not installed helper/OCaml-parent
integration, audible playback, external device verification, full regression,
server installation or completion of the broader sequencer goal. Independent
exact-head source review and guarded GitHub approvals remain separate evidence.
