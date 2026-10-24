# Saved Prompt Presets: read and restore intent

The installed list API returned zero readable presets and two unreadable ones.
Both actual saved snapshots omitted lane request settings that their writer did
not capture. After distinguishing that omission from explicit null, a second
failure became visible: both snapshots contain a lane unavailable in the current
runtime. Rejecting that lane rejected the entire saved snapshot.

The candidate keeps both distinctions explicit. Unrecorded request settings
preserve current declarations; recorded null clears a declaration; recorded
values restore it. Unavailable lanes retain their saved content for inspection
and re-saving, are excluded from runtime writes, and appear in `skipped_lanes`.
The preview and restore report also list `preserved_lane_settings`. Settings
comparison follows the same restore intent and still compares every supported
lane. Neither read nor restore rewrites the original preset files.

## Measured scope

`core-measurements.json` records the source base and changed source hashes. A
native focused probe compiles the changed module as `Candidate_preset` and links
existing dependency artifacts; the tracked test file is used with only its
module alias changed. All 34 behavioral cases pass, including actual persisted
restore, autosave, explicit removal, missing-setting preservation, supported
settings comparison, an unavailable lane causing no runtime write, and atomic
create-only publication with one winner under concurrent same-name writers.
The separate `POST /api/v1/presets/create` cannot silently replace a preset
created after the UI listed names; the existing overwrite/autosave path retains
its meaning. The final focused run links preserved dependency artifacts from
checkout `90269c9233e34ab22940a4e8d5ca386033916d8c`; the compiler checked imported
interfaces. The changed HTTP route also passed a separate typecheck with only
the candidate preset module shadowed. This is not a whole-current-tree build.

The same compiled candidate read isolated copies of both operator snapshots:
readable presets rose from 0 to 2, unreadable fell from 2 to 0. Each preview
reports its unrecorded settings and unavailable lane. An actual copied-data restore applied 29 Keeper instructions with no instruction
skips, while Runtime application reported an unavailable historical assignment
rather than selecting another model. One unavailable lane was reported as skipped.
The original 63 files were
hashed before copying and remain byte-identical. Private instructions and raw
operator snapshots are not published here.

This is focused candidate execution with copied operator data. It is not a
whole-server or TUI build, an installed binary update, or a live preset restore.
Web interaction evidence is recorded separately on the UI layer. An unavailable
lane or invalid current routing must remain visible as partial application;
loading a saved preset does not promise that every historical route still exists.
