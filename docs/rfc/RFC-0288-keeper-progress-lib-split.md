# RFC-0288: Extract progress-classification into its own library for a single substantive-evidence owner

- Status: Draft
- Date: 2026-06-23
- Author: jeong-sik
- Related: RFC-0239 (no-progress loop detector), PR #22127 (outcome-aware detector), PR #22155 (D1 producer fix)

## Background

RFC-0239 made the no-progress loop detector outcome-aware: it reads
`tool_call_detail.typed_outcome` and demotes a typed `Error`/`No_progress` from
evidence (PR #22127). PR #22155 closed the producer-side gap (`keeper_task_done`
now emits a typed `Error` on rejection/failure).

This left two definitions of "substantive tool evidence":

1. **Detector** (`keeper_unified_turn_success.ml`): outcome-aware —
   `is_execution_progress_tool_name name && not (typed_outcome_is_nonprogress outcome)`.
2. **Metrics** (`keeper_unified_metrics_support.ml:has_substantive_tool_calls`):
   name-only — `List.exists is_execution_progress_tool_name`.

The two share the base predicate
`Keeper_tool_progress.is_execution_progress_tool_name`; the only divergence is
the outcome gate. PR #22127's own comment calls this out ("Mirrors
`KUM.has_substantive_tool_calls`" — a drift reservation).

## Problem

Collapsing the two into a single owner is blocked by the library layout:

- `Keeper_tool_progress` lives in the **masc** library (`lib/keeper`).
- `Keeper_tool_outcome` lives in a **separate** library `masc.keeper_metrics`
  (`lib/keeper_metrics`, `(wrapped false)`).
- The dependency edge is `masc -> masc.keeper_metrics` (handlers in `lib/keeper`
  already construct `Keeper_tool_outcome.t`).

A single public `is_substantive_evidence : string * Keeper_tool_outcome.t option
-> bool` cannot live in either library without breaking the build:

- In `masc` (`Keeper_tool_progress`): exposing `Keeper_tool_outcome.t` in a
  public `.mli` triggers `make inconsistent assumptions over interface` across
  every test executable that links `masc.cmxa` (reproduced during PR #22155
  preparation; root cause is the wrapped-library public-interface boundary).
- In `masc.keeper_metrics`: it would need `is_execution_progress_tool_name`,
  whose dependency closure (`classify_tool_progress` -> `Keeper_tool_name`,
  `Keeper_tool_resolution`, ...) is in `masc` -> a cycle.

## Proposal

Extract the **progress-classification layer** into a new low-level library that
both `masc` and `masc.keeper_metrics` can depend on, breaking the cycle and
giving `is_substantive_evidence` a single owner.

Proposed library: `masc.keeper_progress` (new, `(wrapped false)` to match
`masc.keeper_metrics`).

Modules to move into `masc.keeper_progress`:
- `Keeper_tool_progress` (`tool_progress_class`, `classify_tool_progress`,
  `is_execution_progress_tool_name`, `is_claim_context_tool_name`,
  `is_passive_status_tool_name`, `claim_context_tool_names`,
  `completion_tool_names`, `turn_effect`).
- Its dependencies that must travel with it: `Keeper_tool_name`,
  `Keeper_tool_resolution` (and the minimal closure they require).

Once the cycle is broken, `Keeper_tool_outcome` gains `is_nonprogress` (already
drafted) and `Keeper_tool_progress` gains:

```ocaml
val is_substantive_evidence : string * Keeper_tool_outcome.t option -> bool
```

Both consumers delegate:
- detector (`keeper_unified_turn_success`): `is_substantive_evidence (name, outcome)`.
- metrics (`keeper_unified_metrics_support`):
  `List.exists (fun n -> is_substantive_evidence (n, None)) tools` — `(n, None)`
  keeps the legacy name-only behavior exactly, because
  `is_nonprogress None = false`.

## Why not the smaller option

A lib-change-free version — expose only `Keeper_tool_outcome.is_nonprogress` and
have each consumer inline `is_execution_progress_tool_name && not is_nonprogress`
— removes the outcome-gate drift but leaves the one-line combination duplicated.
Given the audit history (two near-miss divergences), the team opted for the
structural fix (single owner) rather than relying on a comment to keep two
one-liners in sync.

## Migration

1. Create `lib/keeper_progress/` + dune stanza; move the modules; update
   `masc` and `masc.keeper_metrics` `libraries` to depend on it.
2. Add `Keeper_tool_outcome.is_nonprogress` and
   `Keeper_tool_progress.is_substantive_evidence`.
3. Rewire detector and metrics to delegate.
4. Tests: prove metrics `(name, None)` path is observationally identical to the
   prior name-only `List.exists is_execution_progress_tool_name`; keep PR
   #22127's 19 detector cases green.

## Risks

- Moving `Keeper_tool_name`/`Keeper_tool_resolution` is a wide-reaching import
  rewrite. Mitigation: codemod + a build that fails closed on any stale
  reference.
- `masc.keeper_metrics` is `(wrapped false)`; the new lib must match so module
  names do not gain an unexpected prefix.
- This is a structural refactor with no intended behavior change; the proof of
  "behavior unchanged" is the metrics equivalence test + green detector suite.

## Open questions

- Exact module closure for `Keeper_tool_name`/`Keeper_tool_resolution` (do they
  pull in OAS/registry state that should stay in `masc`?).
- Whether `turn_effect` / `empty_queue_reason` travel with the classification
  layer or stay in `masc` (they are detector-FSM concerns, not classification).

## Status note

This RFC captures the design reached while preparing the SSOT follow-up to PR
#22127. `Keeper_tool_outcome.is_nonprogress` (the same-library piece) is already
drafted in this branch; the library extraction itself is deferred until this RFC
is reviewed.
