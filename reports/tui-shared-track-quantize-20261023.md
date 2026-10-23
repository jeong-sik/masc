# Shared track/selection quantization

Initial base: `daf068a282b6821d25a37021a08a09866aea1524`.

Independent review of #45253 identified that `:quantize` still accepted new
same-key source overlaps while `:quantize-notes` refused them. A direct Node
editor/import probe reproduced it: PPQ1000 notes [start140,length100] and
[start360,length300] became [250,100] and [250,300] under track grid0.25.
The selected command refused the same input. No live runtime data was modified.

The first layer extracts the existing exact half-up rounding and original/new
overlap comparison into a pure module. Selection still owns its IDs and copy
anchor; callers retain their own validated edit transaction and routing checks.
The extraction passed the same four focused suites, **27/27**.

The second layer uses that same decision for complete phrase and imported-source
tracks. Source comparisons include the complete chosen performance, since source
tracks can share a port/channel/key. Only the current track is edited. Separate
SMF2 patterns and different ports/channels remain independent; pre-existing
source overlaps are still admitted. Note lengths, dynamics, original bytes and
release forms stay under existing validators and serialization.

Six directly related suites passed **45/45**, zero failed/skipped/cancelled:
track-quantize, selected-note-transforms, note-selection, sequencer,
sequencer-editor and midi-source-editor. They include actual source import and
export/reimport, point notes, same-track/cross-track collision refusal, PPQ and
SMPTE agreement with select-all, source route refusal, SMF2 independence,
unchanged controller/release bytes and undo/redo. Pure arithmetic additionally
checks MAX_SAFE tick9007199254740991 with grid3 yields9007199254740990 rather
than the unsafe float result9007199254740992.

These are focused source/behavior checks. They do not establish a full product
build, installed OCaml-parent integration, physical MIDI/audio behavior or the
complete sequencer destination. No local Dune or CI watch/dispatch was run.
The separate authored decimal/fraction parser is tracked in #45264–#45265;
it is not silently included by this stack's initial base.
