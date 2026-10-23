# Shared track/selection quantization

Initial base: `daf068a282b6821d25a37021a08a09866aea1524`.
Integration base: `74599ac1496197c9cd6d95e9dcfeae5c1bfc53e6`, including the
merged authored decimal/fraction timing parser from #45264–#45265.
Native stack #45282: #45280 -> #45281.

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

After whole-stack integration with the merged timing parser, ten focused suites
passed **62/62**, zero failed/skipped/cancelled. The six suites above are joined
by exact-position, step-controls, phrase-arrangement and installed-music-bundle.
A new cross-boundary regression verifies both whole-track and select-all paths:
authored phrase onset8.3 with grid1/3 exports [8000,320,91]; imported PPQ1001
onset130 with grid1/7 exports [143,100,91]. Both retain one-step undo.

## Copied installation modules

The explicit installer manifest omitted `tick-units.mjs` from the prior timing
change. Adding this helper and `note-quantize.mjs` changes both the actual copied
files and the content fingerprint. Before marking a revision installed or
publishing its launcher, the existing preflight now imports the copied sequencer,
arrangement and music-workbench entry points as absolute file URLs.

The focused bundle test physically copies every manifest file into a fresh
temporary directory, with only third-party packages supplied from node_modules.
It imports those copied entry points in a fresh Node process and exercises
fractional note quantization. Before the manifest fix it failed with the missing
tick-units module; after it passed. Removing either helper separately makes
the copied import fail with ERR_MODULE_NOT_FOUND, without checkout fallback.
`sh -n scripts/install-alphatex.sh` also passed. This is copied-module execution,
not a complete installer, Swift/native helper build or launcher publication run.

## Actual source TUI edit and exported state

Before restacking, top head `18f361704bf637c86602141c41f2e1e4652c22fa`
ran in a separate temporary source viewer. Typed `:quantize 0.25` refused the
reproduced same-key collision. Saving and exporting then retained the original
notes and byte-identical MIDI. Retrying `:quantize 0.125`, undoing, redoing,
saving and exporting produced [125,100,80] and [375,300,80], independently
read from both saved JSON and reimported MIDI.

Input/refused MIDI SHA256:
`07c0450bcb087876f5c71542fbd4a7472dab82dd3b04293c73b29bda0870d615`.
Safe exported MIDI SHA256:
`b0ac7a7cde1e6deb90f42680bf99647edaae7a4461ecca71fa716430d6cc4a3c`.
Evidence is under `/private/tmp/masc-music-quantize-evidence-20261023`:
`manual/verification.json`, saved projects/MIDI and terminal captures;
`bundle-before.log`, `bundle-after.log`, `integrated-tests.log`.
The private viewer was closed. No live session or MIDI/audio route was changed.

These are focused source/behavior checks. They do not establish a full product
build, installed OCaml-parent integration, physical MIDI/audio behavior or the
complete sequencer destination. No local Dune or CI watch/dispatch was run.
The actual TUI journey predates restacking; the 62-case integrated execution
verifies the final combined source rather than retroactively relabeling that
earlier journey as final-head TUI execution. The installed application has not
been replaced and physical-device behavior remains unverified.
