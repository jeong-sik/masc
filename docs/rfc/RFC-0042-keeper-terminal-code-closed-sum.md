# RFC-0042: Closed sum type for keeper turn terminal code

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-08
- **Number**: jeong-sik/masc-mcp 의 RFC 번호는 PR Draft 시점에 점유되는 패턴이라
  본 RFC 번호 `0042` 는 잠정. PR #13918 (RFC-0039), PR #14157 (RFC-0041) 가 같은 시점
  Draft 점유 중이며 본 번호도 maintainer 가 머지 시점 재배정 가능.
- **Related**:
  - RFC-0018 (compile-time receipt enforcement at `run_turn` boundary, **MERGED** PR #12256)
  - PR #11717 (4/28, regression alert counter for unmapped operator_disposition, Cycle 51)
  - PR #13301 (5/5, completion_contract_violation:* prefix hand-add)
  - PR #13433 (5/5, decision terminal telemetry)
  - `instructions/MANIFEST.md`: "OCaml 같은 경우 이런 String 나열보다는 Variant 같은
    합타입으로 코드레벨에서 명확한 제어가 가능"
- **Drives**: Make `Keeper_turn_terminal.t.code` a closed sum type so that adding a
  new terminal-reason variant becomes a compile-time obligation, eliminating the
  recurring "string-prefix hand-add" hot-fix pattern.
- **Complements (does not supersede)**: RFC-0018 enforces *receipt presence* at the
  boundary; this RFC enforces *receipt content* (terminal code) at the type level.

## 1. Problem

### 1.1 Symptom — recurring fix on the same axis

A 24-hour log sample (2026-05-08, basepath `~/me/.masc/logs/system_log_2026-05-08.jsonl`)
contains 42 WARN of the form:

```
operator_disposition: unmapped (outcome=error cascade_outcome=not_dispatched
  terminal_reason=turn_livelock:stuck_age_exceeded ...)
```

The `unmapped` counter (`Prometheus.metric_keeper_receipt_unmapped_disposition`) was
introduced by PR #11717 (Cycle 51) on 2026-04-28 as a regression alert, not as a
fix. Since then, the recurring pattern is:

| Date | PR | Action |
|------|-----|--------|
| 2026-04-28 | #11717 | Add unmapped counter (regression alert) |
| 2026-05-05 | #13301 | Hand-add `String.starts_with ~prefix:"completion_contract_violation:"` mapping |
| 2026-05-05 | #13433 | Expose decision terminal telemetry |
| 2026-05-08 | (open) | `turn_livelock:stuck_age_exceeded` still un-mapped (this RFC) |

A new terminal-reason variant lands somewhere → reader (`stale_terminal_disposition_for_receipt`
or its peers) does not match → unmapped counter increments → on-call adds a new
`String.starts_with ~prefix` branch → cycle repeats.

The first-order fix (add another prefix) is a string-level patch. The structural
defect is a layer below.

### 1.2 Root cause — typed/string boundary leak

Three observations from `lib/keeper/`:

1. **Typed source exists**: `Keeper_registry.failure_reason` is a closed sum type with
   nine constructors (`Provider_runtime_error`, `Tool_required_unsatisfied`,
   `Oas_timeout_budget_loop`, `Stale_turn_timeout`, `Stale_fleet_batch`,
   `Heartbeat_consecutive_failures`, `Turn_consecutive_failures`,
   `Ambiguous_partial_commit`, `Fiber_unresolved`, `Exception of _`).

2. **Boundary flattens to string**: `Keeper_execution_receipt.stale_terminal_reason_code`
   (lib/keeper/keeper_execution_receipt.ml:718) maps each typed constructor to a
   string code:
   ```ocaml
   let stale_terminal_reason_code = function
     | Some (Keeper_registry.Provider_runtime_error { code; _ }) -> code
     | Some (Keeper_registry.Stale_turn_timeout _) -> "stale_turn_timeout"
     | ...
   ```
   The type information is thrown away at this single line.

3. **Receipt field is `string`**: `Keeper_turn_terminal.t.code : string`
   (lib/keeper/keeper_turn_terminal.mli:9-15) — the structured surface declared
   "structured" by its file header is a record-of-strings. `severity` is the only
   typed field.

4. **Free-form emit sites bypass the typed source**: 8 sites currently stamp
   `terminal_reason_code` as a string literal independent of `failure_reason`:

   | File | Line(s) | Source |
   |------|---------|--------|
   | `lib/keeper/keeper_unified_turn.ml` | 65, 216, 464, 506 | turn-orchestration emits |
   | `lib/dashboard/dashboard_http_keeper.ml` | 2107, 2208 | dashboard re-stamps |
   | `lib/keeper/keeper_unified_metrics.ml` | 737 | metrics extracts |
   | `lib/keeper/keeper_agent_run.ml` | 1280 | run-loop emit |

   Each is free to mint a new prefix (`turn_livelock:...`, `completion_contract_violation:...`)
   without any check that a downstream reader recognises it.

Result: type discipline is *partially present* (typed `failure_reason`) but *not enforced
at the boundary* (string `terminal_reason_code`). The compiler cannot help when a new
variant is added — the canonical place to learn "did all readers update?" is post-deploy
WARN logs.

### 1.3 Why "add another prefix" is the wrong fix

- Adding `String.starts_with ~prefix:"turn_livelock:"` to a single reader leaves the
  same defect open for the next variant.
- Each fix is local to one reader (e.g. PR #13301 fixed `operator_disposition` but
  not `progress_class_of_terminal_reason_code` in `keeper_passive_loop_detector.ml:34`).
- The cost of these fixes is *recurring* (3 in one week), not amortised.
- Memory record `feedback_self_audit_grep_only_false_positive_trap.md` describes the
  same family of failure: string-level verification misses cases that types catch.

## 2. Goals & non-goals

### Goals

| # | Goal |
|---|------|
| G1 | Add a new terminal-reason variant becomes a compile error in every reader, not a runtime WARN. |
| G2 | Existing JSON wire format (`receipt.terminal_reason_code: string`) remains backward-compatible during a single release window. |
| G3 | Telemetry consumers (`bin/masc-trace`, dashboard) keep reading the wire format unchanged. |
| G4 | RFC-0018's receipt-presence guarantee is preserved (this RFC adds *receipt content* typing on top). |

### Non-goals

| # | Non-goal |
|---|---------|
| NG1 | Replacing `Keeper_registry.failure_reason` (already typed; only the boundary is fixed). |
| NG2 | Reformatting the JSON wire (only the OCaml `code` field type changes; `to_json` still emits a string). |
| NG3 | Solving `lib/prometheus.ml` godfile or other recurring-fix axes (out of scope; separate RFC). |

## 3. Design

### 3.1 New module — `Keeper_turn_terminal_code`

```ocaml
(* lib/keeper/keeper_turn_terminal_code.mli *)

(** Closed sum type for the terminal code carried by
    [Keeper_turn_terminal.t]. Adding a new variant here is a compile
    obligation for every match site — see [match_obligations] in
    docs/rfc/RFC-0042 for the full reader inventory. *)

type livelock_kind =
  | Stuck_age_exceeded
  | Tool_required_unsatisfied
  | Idle_no_progress

type stale_kind =
  | In_turn_hung
  | Idle_turn
  | Noop_failure_loop

type contract_subclause =
  | Require_tool_use
  | Tool_surface_mismatch
  | No_tool_capable_provider
  | Other of string  (** for forward compatibility; see §5.2 *)

type provider_kind =
  | Runtime_error of string
  | Authentication_failed
  | Quota_exhausted

type t =
  | Healthy
  | Cancelled
  | Skipped
  | Turn_livelock of livelock_kind
  | Stale_turn_timeout of stale_kind
  | Provider_runtime_error of provider_kind
  | Completion_contract_violation of contract_subclause
  | Tool_required_unsatisfied of contract_subclause
  | Oas_timeout_budget
  | Stale_fleet_batch
  | Heartbeat_failures
  | Turn_failures
  | Ambiguous_partial_commit
  | Fiber_unresolved
  | Exception_unhandled of { kind : string }

val to_wire : t -> string
(** One-way serialiser. The wire string is stable across releases.
    Format: top-level constructor in snake_case, sub-kind appended
    with ":" — e.g. [Turn_livelock Stuck_age_exceeded] →
    "turn_livelock:stuck_age_exceeded". *)

val of_wire : string -> t option
(** Lossy reverse for migration. Returns [None] for unknown wire codes
    so the caller can decide between [Other] fallback and
    Prometheus-counter-and-fail. Removed in §5.4. *)

val of_failure_reason : Keeper_registry.failure_reason -> t
(** Single canonical bridge from the existing typed source. Replaces
    [Keeper_execution_receipt.stale_terminal_reason_code] on its
    callers. *)
```

### 3.2 Field swap in `Keeper_turn_terminal.t`

```ocaml
(* Before *)
type t =
  { code : string
  ; ... }

(* After *)
type t =
  { code : Keeper_turn_terminal_code.t
  ; ... }

val to_json : t -> Yojson.Safe.t
(** Wire format unchanged: emits [Keeper_turn_terminal_code.to_wire t.code]
    as the JSON [code] string. *)
```

The `to_json` / `of_json` round-trip preserves the wire format, so dashboard, trace
viewers, and external consumers see no change.

### 3.3 Boundary discipline

| Boundary | Before | After |
|----------|--------|-------|
| `failure_reason` → receipt | `stale_terminal_reason_code` flattens to string | `Keeper_turn_terminal_code.of_failure_reason` produces typed `t` |
| `Agent_sdk.Error.sdk_error` → receipt | `agent_error_terminal_reason_code: ... -> string` | Same shape, returns typed `t`; renamed `agent_error_terminal_code` |
| Free-form emit (8 sites in `keeper_unified_turn.ml`, `dashboard_http_keeper.ml`, `keeper_agent_run.ml`) | `let code = "turn_livelock:" ^ kind` | `let code = Keeper_turn_terminal_code.Turn_livelock kind`; new variant requires a code-search-friendly name |
| Reader (3+ sites) | `String.starts_with ~prefix:"turn_livelock:" code` | `match code with Turn_livelock _ -> ...` (compiler-exhaustive) |

The 8 emit sites are the cost surface: each must be touched once. After the conversion
no future site can emit a new prefix without first declaring a constructor.

## 4. Migration plan (4 PRs)

| PR | Title | Files (estimate) | LOC | Compile? | Wire stable? |
|----|-------|------------------|-----|----------|--------------|
| **PR-1** | introduce `Keeper_turn_terminal_code` (inert) | new .ml/.mli + 1 test | ~250 | ✅ | yes (no callers) |
| **PR-2** | convert typed bridges (`stale_*`, `agent_error_*`) to return new type | 4 files | ~150 | ✅ | yes |
| **PR-3** | swap `Keeper_turn_terminal.t.code` field type; update emit sites | 8 emit + .mli | ~250 | ✅ | yes (`to_json` adapter) |
| **PR-4** | convert reader sites to `match`; deprecate `of_wire` for new variants; drop `String.starts_with` | 3 readers | ~100 | ✅ | yes |

**Total estimate**: 12-15 files, ~700-800 LOC, four compilable steps. Each step ships
independently; mid-sequence revert is safe.

### 4.1 Test plan

- **PR-1**: round-trip property test (`to_wire ∘ of_wire ≡ Some` for every typed
  constructor; `of_wire wire = None` for "garbage").
- **PR-2**: golden-file test that
  `Keeper_execution_receipt.stale_terminal_reason_code` produces identical wire
  strings for every `failure_reason` variant after the swap.
- **PR-3**: emit-site coverage test — for each of the 8 sites, assert the emitted
  receipt's `terminal_reason_code` JSON value is unchanged from main.
- **PR-4**: invariant test — `Prometheus.metric_keeper_receipt_unmapped_disposition`
  cannot increment for any constructor of `Keeper_turn_terminal_code.t` (mechanically
  verifiable via match exhaustiveness; not a runtime test).

## 5. Trade-offs & open questions

### 5.1 Wire-format `Other of string` escape hatch

`contract_subclause.Other of string` (and similar) gives forward compatibility for
data inflowing from older receipts. It is a *deserialisation* concession; *new
emits* should always pick a named constructor.

The risk is the escape hatch becoming a permanent string-prefix backdoor. Mitigation:
PR-4 lints `_ (Other _)` constructions in emit sites and fails the build.

### 5.2 Cost of variant explosion

Closed sums grow. If every prefix sub-kind (`stuck_age_exceeded`, `tool_required_unsatisfied`,
…) becomes a constructor, the type can have ~25 variants. This is the *price of the
guarantee*: the compiler can now tell every reader exactly which cases exist. The
existing string codes in `stale_terminal_reason_code` already enumerate ~15 of these,
so the variant count is roughly the same as the de-facto state.

### 5.3 Interaction with RFC-0018

RFC-0018 makes `run_turn` 's OK arm carry a `Keeper_execution_receipt.t`. RFC-0042
makes the `terminal_reason_code` *inside that receipt* typed. They are stacked
guarantees:

```
RFC-0018:  run_turn → Result<Keeper_turn_outcome.t, _>
                         └── carries Keeper_execution_receipt.t  (presence)
RFC-0042:                          └── carries Keeper_turn_terminal_code.t  (content)
```

Neither blocks the other. RFC-0042 PR-1 can land without any RFC-0018 work in
flight (RFC-0018 is `MERGED` as docs; its implementation track is separate).

### 5.4 `of_wire` retirement

`of_wire : string -> t option` exists only for migration. Issue tracker entry on
PR-4 schedules its removal one release after PR-4 lands. Removal is mechanical:
delete the function and its callers.

### 5.5 What this RFC explicitly does not do

- Does not split `lib/prometheus.ml` (godfile). That is a separate axis with a
  user-rejected workaround (see PR #14166 closure note); RFC there will be
  metric-ownership distribution, not file-split.
- Does not reorganise the dashboard surface that consumes `terminal_reason_code`.
- Does not change the `Prometheus.metric_keeper_receipt_unmapped_disposition`
  counter; it remains as a regression alert. After PR-4 it is expected to read 0
  forever, but keeping it costs nothing.

## 6. Decision

This RFC is filed as Draft. PR-1 (`Keeper_turn_terminal_code` introduction, inert)
can land independently of approval here — it is a new file with no callers and
costs nothing to revert. The remaining PRs (PR-2–PR-4) require:

1. Confirmation that `Keeper_registry.failure_reason` is the canonical typed
   source (no parallel `failure_reason` definitions).
2. Confirmation that the 8 emit sites are the complete inventory (one final
   `rg 'terminal_reason_code\\s*=' lib/` sweep on the PR-3 base).
3. Maintainer green-light on RFC number assignment (current `0042` is provisional —
   PR #13918 holds `0039`, PR #14157 holds `0041`).

## 7. References

- `lib/keeper/keeper_turn_terminal.mli:9-15` — current `code: string`
- `lib/keeper/keeper_execution_receipt.ml:718-734` — `stale_terminal_reason_code`
- `lib/keeper/keeper_execution_receipt.ml:327-329` — string-prefix reader site
- `lib/keeper/keeper_passive_loop_detector.ml:34` — second string-prefix reader
- `lib/keeper/keeper_unified_turn.ml:{65,216,464,506}` — 4 emit sites
- `lib/dashboard/dashboard_http_keeper.ml:{2107,2208}` — 2 emit sites
- `lib/keeper/keeper_unified_metrics.ml:737` — metric extract
- `lib/keeper/keeper_agent_run.ml:1280` — run-loop emit
- PR #11717 (regression counter), PR #13301 (prefix hand-add), PR #13433 (telemetry)
- RFC-0018 (`docs/rfc/RFC-0018-terminal-outcome-boundary.md`, MERGED)
- `instructions/MANIFEST.md` (OCaml variant principle)
