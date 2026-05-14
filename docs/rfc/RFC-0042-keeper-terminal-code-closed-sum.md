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

4. **Free-form emit / stamp sites bypass the typed source**: at least **18
   call sites** stamp a `terminal_reason_code` string or build a
   `Keeper_turn_terminal.t` from a free-form code, independent of
   `failure_reason`:

   | File | Line(s) | Pattern |
   |------|---------|---------|
   | `lib/keeper/keeper_unified_turn.ml` | 65, 216, 464, 506 | `let terminal_reason_code = ...` (turn orchestration) |
   | `lib/dashboard/dashboard_http_keeper.ml` | 2107, 2208 | dashboard re-stamps from receipt JSON |
   | `lib/keeper/keeper_unified_metrics.ml` | 734, 735, 737 | `Keeper_turn_terminal.of_legacy_error_text`, `of_code "unknown_error"`, `terminal_reason.code` extract |
   | `lib/keeper/keeper_agent_run.ml` | 1280 | run-loop terminal-reason emit |
   | `lib/keeper/keeper_agent_error.ml` | 77, 120 | `agent_error_terminal_reason_code : Agent_sdk.Error.sdk_error -> string` (typed → string flatten) |
   | `lib/keeper/keeper_runtime_trust_snapshot.ml` | 119, 152, 155, 158, 184 | `Keeper_turn_terminal.of_code ~source:"decision_log" \| "execution_receipt" \| "runtime_blocker" code` (5 stamp sites) |

   `lib/keeper/keeper_turn_terminal.ml:109` defines `of_legacy_error_text` —
   one of two `... -> Keeper_turn_terminal.t` constructors that take a
   free-form string (the other is `of_code`). PR-3 / PR-4 must touch every
   one of the call sites above; the inventory underestimate in this RFC's
   first draft was the source of an earlier "8 site" claim that the
   reviewer flagged.

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

The closed sum is intentionally **flat** (no nested sub-kind sums) at PR-1
to mirror the wire format that already exists in
`Keeper_execution_receipt.stale_terminal_reason_code`, so PR-2/3 can swap
calls one-for-one without changing what dashboards or `bin/masc-trace`
consumers see. Nested kinds (`Turn_livelock of livelock_kind`,
`Provider_kind` variants, etc.) are deliberately *deferred* — they are
candidate refinements once the flat type lands and emit/reader sites are
fully migrated; the intermediate shape would force PR-3 to invent a wire
encoding that does not exist today.

```ocaml
(* lib/keeper/keeper_turn_terminal_code.mli — actual signature filed in
   PR #14182 (PR-1) *)

type t =
  | Healthy
  | Stale_turn_timeout_idle
      (** Keeper_registry.Stale_turn_timeout (Idle_turn _) *)
  | Stale_turn_timeout_in_turn
      (** Keeper_registry.Stale_turn_timeout (In_turn_hung _) *)
  | Stale_turn_timeout_noop
      (** Keeper_registry.Stale_turn_timeout (Noop_failure_loop _) *)
  | Stale_termination_storm
  | Stale_fleet_batch
  | Oas_timeout_budget
  | Heartbeat_failures
  | Turn_failures
  | Provider_runtime_error of string
      (** payload = original Keeper_registry.Provider_runtime_error.code *)
  | Tool_required_unsatisfied of string
      (** payload = original Keeper_registry.Tool_required_unsatisfied.code *)
  | Ambiguous_partial_commit_post_commit_timeout
  | Ambiguous_partial_commit_post_commit_failure
  | Fiber_unresolved
  | Exception_unhandled of string
      (** payload = exception message *)

val to_wire : t -> string
(** Stable wire format, byte-for-byte compatible with strings emitted today
    by [Keeper_execution_receipt.stale_terminal_reason_code]. The two
    [Stale_turn_timeout_*] variants and the two [Ambiguous_partial_commit_*]
    variants intentionally collapse to a single wire string each
    (["stale_turn_timeout"], ["ambiguous_partial_commit"]) to preserve
    existing cohort keys. *)

val of_wire : string -> t option
(** Best-effort reverse. Returns [None] for unknown wire codes (so the
    caller cannot silently mis-classify a [Provider_runtime_error] code
    that happens to share a literal with another constructor). Lossy
    where the wire string lost the sub-class — see PR #14182's [.ml] for
    the canonical sub-class chosen for each lossy wire. Removed in §5.4. *)

val of_failure_reason : Keeper_registry.failure_reason -> t
(** Canonical bridge from [Keeper_registry.failure_reason] (11 constructors).
    Exhaustive: adding a new constructor in [Keeper_registry] is a compile
    error here. Replaces [Keeper_execution_receipt.stale_terminal_reason_code]
    in PR-2. *)
```

**Refinement opportunities deferred to follow-up RFCs (not PR-2/3/4)**:

| Idea | Why not now |
|------|-------------|
| `Turn_livelock of livelock_kind` (nested sum) | "turn_livelock:" prefix exists in current emits but not in `Keeper_registry.failure_reason`; introducing it requires defining the sub-kinds explicitly and updating every emit site at the same time as PR-3. Out of scope; track as RFC-XXXX-livelock-typed once the flat type lands. |
| `Provider_runtime_error of provider_kind` | Same: would require parsing today's free-form `code` strings into a closed sub-sum, which is a separate analysis pass over production traces. |
| `contract_subclause` enumeration | "completion_contract_violation:" sub-clauses are decided at the contract layer; should live in a contract-layer RFC, not in the terminal-code RFC. |

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

| PR | Title | Files | LOC (estimate) | Compile? | Wire stable? |
|----|-------|-------|----------------|----------|--------------|
| **PR-1** | introduce `Keeper_turn_terminal_code` (inert, flat sum) | 2 신규 (.ml/.mli) + 1 round-trip test | ~250 | ✅ | yes (no callers) |
| **PR-2** | typed bridge migration: `stale_terminal_reason_code` / `agent_error_terminal_reason_code` → return `Keeper_turn_terminal_code.t` | `keeper_execution_receipt.ml`, `keeper_agent_error.ml`, 그리고 직접 caller 들 | ~150 | ✅ | yes |
| **PR-3** | swap `Keeper_turn_terminal.t.code` field: `string` → `t`; update **all 18 emit/stamp sites** (cf. §1.2 expanded inventory) | `keeper_turn_terminal.{ml,mli}` + 18 emit/stamp sites + JSON adapter | ~400 | ✅ | yes (`to_json` adapter writes wire string) |
| **PR-4** | reader migration: 3+ readers (`keeper_execution_receipt.ml:327-329`, `keeper_passive_loop_detector.ml:34`, plus any new ones found in PR-3 base) `String.starts_with ~prefix` → exhaustive `match`; deprecate `of_wire` | 3+ readers + thin `of_wire` shim removal | ~150 | ✅ | yes |

**Total**: 18-20 files (revised upward from "12-15" — the original estimate
was anchored to the 8-site emit count corrected in §1.2), ~950 LOC across
four compilable steps. Each step ships independently; mid-sequence revert
is safe.

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

### 5.1 Wire-format escape hatch (deferred)

The original draft of this RFC proposed an `Other of string` constructor on
`contract_subclause` for forward compatibility with unknown wire codes.
Once the type was flattened (§3.1) the need disappeared: `of_wire` returning
`None` plays the same role at the deserialisation boundary, and there is no
sub-sum that needs an `Other` arm.

If a future RFC reintroduces nested sub-kinds (e.g. `Turn_livelock of
livelock_kind`), it will face this trade-off again — the escape hatch is
documented here so it is not rediscovered as an open question.

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
