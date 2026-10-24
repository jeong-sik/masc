# Saved settings UI: candidate observations

The web prompt registry previously had assembly-stage filters named presets,
but no saved-snapshot API consumer. It now offers real saved settings: list,
inspect, save under a new name and explicitly confirm a restore. The stage filter
keeps its separate purpose. Unrecorded settings are summarized in a collapsed
list; unavailable lanes and surface failures remain visible.

Both web and TUI consume preserved-setting and skipped-lane diagnostics. The TUI
result introduces partial application when a surface failed or a lane was skipped.
Keeper instructions are described as taking effect at the next up/turn.

## Executed checks

- 31 focused web API/action/ownership tests pass; an independent reviewer also
  ran all 31. They cover request bodies, create-only saves, exact workspace and
  credential ownership, navigation with a pending or uncertain operation, late
  restore completion while editing another prompt, and contradictory receipts.
- Changed-file ESLint passes. Whole Dashboard typecheck has the same two existing
  `keeper-stream.test.ts` errors as the base; changed-file diagnostics are zero.
- Candidate TUI decoder and result modules compiled and linked separately with
  existing dependencies; all four focused decoder/decision cases pass. This is
  not a full TUI build or visible terminal proof.
- Native source hashes for all 13 tested files match the rebased UI layer.

## Visible and persisted behavior

The actual component was opened in Ego Lite against a loopback adapter invoking
the compiled OCaml candidate. The adapter reads and writes isolated copies of
actual operator snapshots. The fixture declares a client ownership scope; it
does not prove production authentication, execution publication or full Settings
integration.

[New save](new-saved.png) shows a newly saved snapshot selected after persisted
reread and matching the copied current settings. [Partial restore](partial-restore.png)
shows an actual older save restoring 28 Keeper instructions, preserving unrecorded
settings and reporting one unavailable lane. Runtime routing is explicitly failed
because a historical assignment is absent from the current catalog; no replacement
model was invented. The report is marked as needing attention, not fully restored.
A second older snapshot separately restored 29 instructions with zero skips.

A duplicate create returned HTTP 409. All 40 existing files of that newly saved
snapshot stayed byte-identical. All 63 original operator preset files also stayed
unchanged. Measurements are in `measurements.json`.

These screenshots are candidate component observations with real copied-data
persistence. They are not an installed Dashboard/TUI update or a live preset
restore. The installed Dashboard observed at the start also had a source-commit
mismatch with its server, so its appearance cannot certify these source changes.
