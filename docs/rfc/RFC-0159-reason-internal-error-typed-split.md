---
rfc: "0159"
title: "Reason_internal_error typed split — close string-classifier catch-all"
status: Draft
created: 2026-05-21
updated: 2026-05-21
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0148", "0157", "0158"]
implementation_prs: []
---

# RFC-0159 — Reason_internal_error typed split

## §0 TL;DR

`lib/keeper/keeper_execution_receipt.ml:615-621` collapses *every* unmapped
internal failure into a single closed-sum arm:

```ocaml
else if
  String.equal terminal_reason "internal_error"
  ||
  match error_kind with
  | Some "internal" -> true
  | Some _ | None -> false
then Disp_pause_human, Reason_internal_error
```

Team KKK observation (24h window): **205 `Reason_internal_error` events
across 22+ distinct keepers**. The arm is a §2 string-classifier hot path
— `String.equal terminal_reason "internal_error"` plus a fallback over
`error_kind = Some "internal"`. Every uncaught exception, every
`None`-returning cascade classifier, every turn-budget overrun, and every
FSM precondition trip ends up indistinguishable downstream.

This RFC splits `Reason_internal_error` into four typed sub-variants —
`Reason_internal_exception`, `Reason_internal_classifier_unmapped`,
`Reason_internal_timeout`, `Reason_internal_invariant_violation` — each
preserving its provenance for debugging. The closed-sum extension forces
every emit site to commit to *which* internal failure it observed at the
moment of `Disp_pause_human` resolution.

Acceptance (Phase 4 + 24h sustained): plain `Reason_internal_error`
occurrence = 0. All 205/24h routed to one of the four sub-variants. New
prometheus label `reason_kind="internal_*"` makes the breakdown directly
inspectable.

## §1 Motivation

### 1.1 Team KKK quantitative observation

`Reason_internal_error` events / 24h:

| Signal | Count |
|---|---|
| Total `Reason_internal_error` emissions | 205 |
| Distinct keepers affected | ≥ 22 |
| Source breakdown | unknown (collapsed by catch-all) |

The "source breakdown unknown" line is exactly the failure mode this RFC
addresses. Operators see 205 pause-human events but cannot tell whether
the population is dominated by exceptions, by classifier gaps, by timeout
budget overruns, or by FSM invariant trips. Each of the four has a
*different* remediation:

- **exception**: stack trace + fix the throw site (or wrap in `Result.t`)
- **classifier unmapped**: extend classifier domain (RFC-0148 territory)
- **timeout**: budget tune or cascade rotation
- **invariant violation**: FSM bug; not a transient — needs code fix

Bundling them inflates the apparent severity of "internal" and starves
each individual root-cause investigation of evidence.

### 1.2 §2 string-classifier anti-pattern

Per `software-development.md` §2 (workaround signature 2):

> typed variant이 가능한 자리에 string match를 추가하거나 잠금.
> **신호**: "literal substring match", "starts_with ~prefix"

The site is a closed-sum sink driven by `String.equal terminal_reason
"internal_error"` plus `error_kind = Some "internal"`. The producer side
(whoever assigned `terminal_reason := "internal_error"` or
`error_kind := Some "internal"`) escapes type-checking entirely — any
upstream string typo silently routes to a *different* arm or to the
generic fallthrough.

### 1.3 Relation to RFC-0148 sunset and RFC-0158 split

RFC-0148 (2026-05-20) sunsetted the telemetry-as-fix pattern that *added*
a counter to make the catch-all visible. RFC-0158 (2026-05-21) split
`Oas_timeout_budget` along the same axis: one variant collapsing two
*semantically opposite* failures (server-slow vs didn't-try). RFC-0159
applies the identical pattern at a different boundary: four root causes
collapsed by a `String.equal` arm, four downstream remediations
foreclosed.

## §2 Non-goals

- **Not** changing the pause-human policy. Every sub-variant continues
  to map to `Disp_pause_human`. The disposition is identical; only the
  reason variant is widened.
- **Not** introducing a recovery path for internal exceptions. That is a
  separate RFC. Catching `Internal_exception` and resuming is out of
  scope here.
- **Not** reclassifying historic 205/24h backlog. Migration phase 1–4
  applies forward; logged events keep `Reason_internal_error` byte form
  on the wire until phase 3.
- **Not** introducing a separate `keeper_name` field at the receipt
  layer (it already exists; §4 only adds it to one structured log line).

## §3 Design

### 3.1 New closed-sum

Introduce `internal_error_reason` carried by each sub-variant:

```ocaml
type internal_error_reason = {
  source : string;       (* call site identifier, e.g. "keeper_turn:exec" *)
  detail : string option; (* exception name / classifier input / etc. *)
}

type operator_disposition_reason =
  | Reason_healthy
  | ...
  | Reason_internal_exception            of internal_error_reason
  | Reason_internal_classifier_unmapped  of internal_error_reason
  | Reason_internal_timeout              of internal_error_reason
  | Reason_internal_invariant_violation  of internal_error_reason
  | ...
```

`Reason_internal_error` is **removed** in phase 3; until then both old
and new co-exist via a deprecated alias to enable per-site migration.

### 3.2 Sub-variant semantics

| Variant | Trigger | `source` example | `detail` example |
|---|---|---|---|
| `Reason_internal_exception` | uncaught exception or `Eio.Cancel.Cancelled` not absorbed | `"keeper_turn:exec"` | `"Failure: bad_argv"` |
| `Reason_internal_classifier_unmapped` | cascade classifier returned `None` / `Other` | `"cascade.classify_attempt_outcome"` | `"unknown_error_kind"` |
| `Reason_internal_timeout` | turn / phase exceeded budget without dispatch | `"keeper_turn:budget"` | `"phase_budget=30s"` |
| `Reason_internal_invariant_violation` | FSM precondition or `assert false` | `"keeper_registry.validate_decision_transition"` | `"unknown_pair(Awaiting,Cancelling)"` |

### 3.3 Wire compatibility

`operator_disposition_reason_to_string` maps each sub-variant to a
distinct byte form:

```ocaml
| Reason_internal_exception _ -> "internal_exception"
| Reason_internal_classifier_unmapped _ -> "internal_classifier_unmapped"
| Reason_internal_timeout _ -> "internal_timeout"
| Reason_internal_invariant_violation _ -> "internal_invariant_violation"
```

Existing string "internal_error" is retired in phase 3. Downstream JSON /
prometheus readers must accept the four new forms before phase 3 ships.

### 3.4 No catch-all replacement

The current arm `String.equal terminal_reason "internal_error" || ...`
is replaced by direct typed emission at each call site. There is **no**
new `else` arm that classifies on `terminal_reason` string content. If
phase 4 acceptance fails (i.e. some 205/24h site still emits via the
generic path), the residue routes to `Reason_unmapped_cascade_state`
(existing fallthrough) and surfaces as a test failure, not a silent
re-collapse.

## §4 Observability

- **Prometheus**: new label `reason_kind` on the existing
  `keeper_disposition_total` counter, taking values
  `internal_exception | internal_classifier_unmapped | internal_timeout
  | internal_invariant_violation` (and the existing non-internal values).
- **Structured log**: at the call site that emits an
  `internal_error_reason`, the log line gains `keeper_name`
  (currently 94% `null` per RFC-0091 PR-2 evidence) and
  `internal_source` fields. No new dedicated log channel; piggyback on
  the existing receipt-emission log.
- **No new counter as fix**: per RFC-0088 §9, counter visibility is
  *supplementary*, not the fix. The fix is the typed split itself.

## §5 Workaround self-check (software-development.md 3 signatures)

1. **Telemetry-as-fix**: this RFC does add a prometheus label, but only
   *because* the typed split is the substrate. Without §3, the label
   would just be a string. With §3, the label is a projection of a
   closed-sum, which is the established fix pattern (cf. RFC-0155
   `system_log_category`).
2. **String classifier**: this RFC *removes* a `String.equal` arm. It
   does not add another. Phase 3 deletes the catch-all.
3. **N-of-M migration**: phase 2 migrates all emit sites in one PR per
   sub-variant family. The closed-sum extension makes the migration
   exhaustive (`match` fails to compile if a site is missed). No "PR-X
   only fixed K of N sites" admission is acceptable.

## §6 Migration

| Phase | Scope | Verification |
|---|---|---|
| 1. **Typed substrate** | Add `internal_error_reason` record + 4 sub-variants alongside the existing `Reason_internal_error`. `to_string` for sub-variants emits new byte forms. | `dune build`; unit test enumerates 4 byte forms. |
| 2. **Classify-then-emit** | At each known producer (`keeper_turn`, `keeper_registry` invariant sites, `cascade.classify_*`, budget-exceed paths) replace `terminal_reason := "internal_error"` with direct sub-variant construction. | Per-keeper unit test that synthetic input triggers the expected sub-variant. |
| 3. **Swap consumer arm** | Delete lines 615-621 (`String.equal ... "internal_error"` arm). Add explicit match on the four sub-variants. Retire `Reason_internal_error` (with breaking-change note). | `dune build` red on first uncovered call site; green once §2 phase covers all. |
| 4. **24h soak** | Observe prometheus `reason_kind` distribution. Confirm plain `internal_error` byte form count = 0. | Grafana panel + `rg "internal_error" log/` returns 0 for new emissions. |

Each phase is a separate PR. Phase 2 may need 2–3 PRs if producer sites
exceed one reviewer chunk; phase 3 must be one PR (single source of
truth for the catch-all removal).

## §7 Acceptance

**Hard gate** (phase 4 + 24h sustained, all required):

1. `keeper_disposition_total{reason="internal_error"}` rate = 0.
2. Sum of `keeper_disposition_total{reason_kind=~"internal_.*"}` ≈ 205/24h
   ± 20% (population conserved; sub-variants account for the previous
   collapsed count).
3. Each of the four sub-variants has ≥ 1 emission in 24h (i.e. none of
   the four is dead code; if any is, it indicates a misclassification
   either in §3.2 or in the actual producer mapping).
4. `rg 'String\.equal[[:space:]]+terminal_reason[[:space:]]+"internal_error"'
   lib/` returns 0 matches.

**Soft gate**: per-keeper distribution skew. If one keeper accounts for
> 60% of any single sub-variant, surface as an investigation pointer
(not a release blocker).

## §8 Risks

- **Classifier misroute in C-stub paths**: native FFI or external
  process boundary may raise exceptions that look like classifier gaps.
  Mitigation: §3.2 table treats *uncaught exception at OCaml boundary*
  as `Internal_exception` regardless of upstream provenance. The typed
  boundary unit test must include an FFI-raised case.
- **Phase 3 breaking change**: removing `Reason_internal_error` is a
  closed-sum API break. Mitigation: phase 1 keeps both; downstream JSON
  consumers (dashboard, OAS exporters) must ship readers for the four
  new forms in phase 1 PR (not deferred).
- **Producer-side typo**: a site that previously wrote
  `terminal_reason := "internal_error"` and now must pick a sub-variant
  may pick the wrong one. Mitigation: the closed-sum forces a choice,
  and the `source` field is checkable in code review. Unit tests at
  each producer assert source/sub-variant alignment.
- **Population drift during migration**: phase 2 partial coverage may
  show `Reason_internal_error` rate dropping while sub-variant rates
  rise asymmetrically, masking real change. Mitigation: phase 4
  acceptance check waits until phase 3 ships (plain form removed).

## §9 Open questions

- **Should `Internal_exception` carry the exception trace summary or
  only its name?** Trace summary is useful for triage but inflates log
  size and may leak internal paths. Proposal: name + arity only at the
  receipt layer; full trace lands in the structured log via existing
  `Eio.traceln` channel. Decide before phase 2 PR.
- **Should `Reason_internal_invariant_violation` route to
  `Disp_pause_human` or to a new `Disp_halt` disposition?** Invariant
  trips are *not* operator-resolvable; they are code bugs. Out of scope
  for this RFC, but flagged for a follow-up after phase 4 evidence.
- **Should the `source` field be a typed enum rather than a string?**
  Yes in principle; deferred to a follow-up RFC to keep this one
  focused on the catch-all split. Phase 1 accepts string `source` with
  a convention (`module.function` form), with the option to harden
  later.
