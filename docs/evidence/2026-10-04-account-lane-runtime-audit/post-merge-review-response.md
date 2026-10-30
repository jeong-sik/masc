# Account and runtime review follow-up after stack merge

On 2026-10-04, another session merged all ten PRs in native stack #41118.
The final original PR #41117 merged at `eb93753606eb6c2f8bf01fd1c691ef3fbebbc1d7`;
its tree is byte-identical to the previously published response leaf
`4cac6dd98a07e7ffc74b45d225f827b3075c6eaf`. No merge request was sent by this
response session. The external merges do not certify the unpublished fixes below.

These fixes were replayed in six bounded changes on main
`142d84ff74f580d7d34f296083a2b53cfe7e2098`. The integrated source before this
evidence-only commit is `ec98956508f3565ac04ff2e413cb7d8e6003cc23`.

| Change | Review findings handled | Result |
| --- | --- | --- |
| Model effort | #41106: 4176673798 | Explicit effort replaces uncontrolled reasoning on the selected model; Copy leaves the source model unchanged. |
| Setup eligibility | #41107: 4176515303, 4176515305 | CLI provider reuse requires non-interactive execution. Product aliases resolve existing operator accounts; the latter was already fixed and now has an additional regression. |
| Login receipts | #41108: 4176680194; #41117: 4176515007 | Saving survives panel closure and consumes the actual reply before activation. Removal has a separate phase. Existing disabled accounts cannot reauthenticate; supported fresh-account templates still create a separate home without enabling the original connection. |
| Usage history | #41109: 4176516143, 4176516146, 4176667759 | Successful empty reports stay distinct from missing/zero use. Per-source replacement precedes daily selection, preserving other sources. Dashboard usage cards require a supported producer or declared HTTP reader. |
| Runtime metrics | #41113: 4176611015, 4176671914, 4176671918, 4176671923 | Yielded non-error outcomes retain their meaning; four metrics projections propagate read failure so caches retain last-good values; unrenderable timestamps are rejected; retained rotated logs are included. The pure canonical filename parser moves to the existing core library to avoid a dependency cycle. |
| Quota scope visibility | #41116: 4176607862, 4176680232, 4176680240; #41117: 4176607194 | Scope IDs are labeled as credential/quota correlation rather than authenticated account identity. Setup, Runtime and Usage share one ID function preserving history IDs. Response-local correlation survives unavailable Usage joins, and an 80-column Lane table retains its Lane column. |

## Executed checks

On the integrated source SHA above:

- Seven dashboard suites: **104 tests passed**; full dashboard `tsc --noEmit` passed.
- Changed OCaml sources: **39 implementations and 15 interfaces** parsed with
  OCaml 5.5.1. **Five Python files** passed AST parsing. Diff whitespace passed.
- Source integration review checked the preserved contracts, records, direct
  callers, library dependencies and conflict resolutions. Metrics files are
  byte-identical to the independently reviewed corrected unit; quota/UI files
  match the composed reviewed units. The source reviews are not GitHub approvals.

Earlier focused executions, separately scoped:

- Model effort: seven assertions using the exact production edit branch with
  real Toml_line_editor and Otoml, not the full form/parser workflow.
- Setup: 42 assertions using the complete production setup-spec implementation
  and interface plus production normalization excerpts; infrastructure types and
  registry are stubbed. Actual HTTP dispatch was not executed.
- Login: one disabled/unsupported key-path scenario and 13 pending-save recovery
  assertions using production state-machine and dispatcher excerpts; HTTP effects
  are stubbed. Actual server/TUI end-to-end execution was not performed.
- Metrics: six native TUI projection tests; moved filename authority compiled
  against the actual core interface dependencies and strict warning flags.
  Producer/rotation/cache regressions were authored but not executed.
- Scope display: seven native focused tests across geometry, scope identity and
  upper picker/Context labels; these use production excerpts and real table/text
  helpers, not the complete linked TUI.

The independent metrics review caught two test formatter type mismatches;
follow-up `301f4524e9d053d11a3189e0c4fb9da9af4e724c` repaired them before replay.

No local Dune/full build, rebuilt native server/TUI, PTY run, browser E2E,
deployment or live configuration change was performed. The shared native build
cache was unavailable. Prior manual CI runs on the original stack are historical
and do not certify these follow-up heads. A new minimal manual check is dispatched
and recorded separately for the published follow-up leaf.

The original stack is merged. These additional fixes require their own current-head
independent guarded reviews before any subsequent merge; approval cannot be inferred
from the original stack's merged state or these focused checks.
