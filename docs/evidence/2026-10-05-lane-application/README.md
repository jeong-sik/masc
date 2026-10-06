# F8 backend application observations

This unit adds exact reconciled source identity and a typed application state to
operator declaration metadata. Inspect observes live and retained owners without
triggering worker work or reconciliation. Existing UI decoders ignore the new
fields; TUI/Web consumers and continuous observation remain follow-up work.

## Executed

- OCaml **5.5.0** (installed compiler), standalone compilation of the actual pure
  application module plus its feature scenarios in an owned temporary directory:
  **5 tests pass**. No mocked module or facade was substituted. Build and test
  output are retained. This is not the project's pinned 5.5.1 full build.
- Syntax parsing of the **11 changed OCaml files** as committed at
  `4e672fa75d584e128f81f3966b1bc78cb5a5ce5a`, with OCaml **5.5.1**
  `ocamlc -stop-after parsing`: all exit 0. `check-syntax.py <rev>` reads each
  blob with `git show`, hashes it and parses it; `syntax.json` is its output.
  This does not typecheck Runtime, Store, their direct consumers or the authored
  runtime tests.
- `git diff --check` is clean.

## Source-reviewed repair and authored checks

Independent review found that historical cleanup's terminal rename/unlink could
look complete before publication settled. Failed publication was log-only and
binding removal lacked parent sync. The repair keeps in-process owner metadata
through pending/failed publication and retries only publication after resource
cleanup succeeds. It syncs removal even after ENOENT, and syncs a captured cold
inventory before allowing `complete=true`. Cancellation leaves retryable state.

The expanded `test_lane_addon_reconcile.ml` exercises real Runtime/Store entrypoints
with a fake worker. It includes accepted-startup gating, no-live-owner cleanup,
held terminal file replacement or unlink, reported publication failure, direct
reconciliation retry without a second resource stop, and cold inventory sync.
These tests are **authored and syntax-parsed only**, not compiled or run. The
replacement branch performs a real successful save then injects uncertainty;
the unlink branch injects an actual directory-sync callback failure. These are
not physical power-loss tests, and direct reconciliation is not a Pulse run.

The old Config test used enabled=true as an unknown field, despite the earlier
activity feature accepting it. It now uses a genuinely unknown field.

## Limits

No local Dune build, full backend typecheck, native TUI/PTY, dashboard rendering,
worker/provider execution, CI, main integration or deployment was performed.
Pure tests and syntax checks cannot establish those outcomes. This is a reviewed
backend prerequisite, not completion of F8 or of the overall UX task.
