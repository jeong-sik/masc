# RFC-0062 — Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class (Reverse-Engineered Initial Draft)

**Status**: Draft (initial draft written *after* Phase 0–4c-1 already merged — see §10 Documentation Backfill)
**Author**: Agent (Claude Opus 4.7) — backfilling from merged PRs
**Date**: 2026-05-11
**Supersedes**: —
**Related**: PR #14437 (Phase 0), PR #14464 (Phase 1), PR #14482 (Phase 2), PR #14486 (Phase 3), PR #14528 (Phase 4c-1). CLAUDE.md §"워크어라운드 거부 기준" #2 (string/substring classifier).

---

## 1. Problem

Two adjacent silent-failure surfaces shared a root cause — strings used where typed sum types were available.

### 1.1 Agent SDK error → keeper `blocker_class` stamp gap

`keeper_status_bridge.ml :: blocker_class_of_sdk_error` had a `_ -> None` catch-all that silently dropped 9 `Agent_sdk.Error.Agent` constructors (`MaxTurnsExceeded`, `TokenBudgetExceeded`, `CostBudgetExceeded`, `UnrecognizedStopReason`, `IdleDetected`, `ToolRetryExhausted`, `GuardrailViolation`, `TripwireViolation`, `ExitConditionMet`). Result: `last_blocker_class = null` while the surface text *was* stamped — dashboards and Prometheus showed zero counts for these classes even though they were occurring.

### 1.2 Tool dispatch return: `(bool * string)` with substring classifier

`Tool_*.dispatch` returned `(bool * string) option`. Retryability was decided by `is_retryable_message`, a 9-pattern substring classifier (`mcp_server_eio_call_tool.ml`). Failure semantics (transient vs policy vs runtime vs workflow rejection) were inferable only by parsing the message string at the call site. New error phrases produced silent reclassification.

Both fall under CLAUDE.md §"워크어라운드 거부 기준" #2: string/substring 분류기가 closed sum type을 대체하고 있던 자리.

## 2. Non-Goals

- gRPC wire format changes (legacy `(ok, message)` projection retained at the bridge for compat — see §4.3).
- Caller-facing tool name catalog reform (out of scope; RFC-0057 territory).
- Cross-process error propagation typing (still `Agent_sdk.Error.t` JSON-encoded over MCP).

## 3. Design

### 3.1 `blocker_class` — typed `Sdk_*` variants (Phase 0, #14437)

```ocaml
(* lib/keeper/keeper_meta_contract.ml *)
type blocker_class =
  | …existing variants…
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_tool_retry_exhausted
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
```

`blocker_class_of_sdk_error` switches from `_ -> None` to **explicit per-variant match** over `Agent_sdk.Error.Agent` constructors. A newly added SDK variant now produces a compile error rather than silent drop.

### 3.2 `tool_failure_class` — closed sum type (Phase 1, #14464)

```ocaml
(* lib/tool_result.ml *)
type tool_failure_class =
  | Transient_error      (* retry-eligible: timeout, connection, rate-limit *)
  | Policy_rejection     (* permission, guardrail, validation reject *)
  | Runtime_failure      (* internal exception, unexpected error path *)
  | Workflow_rejection   (* HITL reject, gate refusal *)

val classify_from_exception     : exn -> tool_failure_class option
val classify_from_dispatch_failure : message:string -> tool_failure_class
val is_retryable                : tool_failure_class -> bool
val log_level_of_failure_class  : tool_failure_class -> [ `Warn | `Error ]
```

`classify_from_exception` matches on exception **constructors** (typed). `classify_from_dispatch_failure` is the Phase 1 SSOT for the legacy string surface — it will be eliminated as Phase 4 finishes (§5).

### 3.3 `Tool_result.t` — structured record (Phase 1→3)

```ocaml
type t = {
  success         : bool;
  message         : string;       (* operator-facing prose *)
  legacy_message  : string;       (* projection for (bool * string) gRPC bridge *)
  failure_class   : tool_failure_class option;
  (* + lazily-added fields as Phase 4 handlers migrate *)
}
```

Phase 2 (#14482): 50+ `Tool_*.dispatch` signatures migrated from `(bool * string) option` to `Tool_result.t option`. Callers use field access (`result.success` / `result.failure_class`).

Phase 3 (#14486): `execute_tool_eio` and `dispatch_by_tag` return `Tool_result.t` **directly**. The `tuple_of_tool_result` reverse adapter at the dispatch boundary is removed. `call_tool_with_readonly_retry` and the gRPC bridge in `server_runtime_bootstrap` destructure fields.

### 3.4 Boundary projection

The gRPC bridge still emits `(ok, message)` to outside clients. The projection lives in `server_runtime_bootstrap` and reads `result.success` + `result.legacy_message`. This keeps the wire format stable while internal flow is fully typed.

## 4. Why these are *fixes*, not workarounds

Under CLAUDE.md §"워크어라운드 거부 기준" the temptation here would be:

- ❌ "Add more substrings to `is_retryable_message`" — workaround signature #2 (string classifier reinforcement).
- ❌ "Count unmapped SDK errors with a Prometheus counter" — workaround signature #1 (telemetry-as-fix).
- ❌ "Add `_ -> Some Unknown_blocker` so dashboards see *something*" — workaround signature: permissive default.

This RFC chooses the structural fix: **closed sum types + exhaustive match**. New SDK error variants and new failure classes now require a compile-time edit in a single SSOT module, and the compiler enumerates every caller that must adapt.

## 5. Phase Rollout (status as of 2026-05-11)

| Phase | Scope | PR | Status |
|-------|-------|-----|--------|
| **0** | Typed `Sdk_*` `blocker_class` variants + exhaustive `blocker_class_of_sdk_error` | #14437 | Merged |
| **1** | `tool_failure_class` closed sum + `Tool_result.t` record + 9 string patterns purged | #14464 | Merged |
| **2** | 50+ `Tool_*.dispatch` signatures → `Tool_result.t option` (Big Bang) | #14482 | Merged |
| **3** | `execute_tool_eio` / `dispatch_by_tag` return `Tool_result.t` directly; remove `tuple_of_tool_result` reverse adapter | #14486 | Merged |
| **4c-1** | 8 core tool handlers (`tool_args`, `tool_code`, `tool_code_write`, `tool_control`, `tool_library`, `tool_plan`, `tool_run`, `tool_task`, `tool_worktree`) + keeper dispatch handlers migrated | #14528 | Merged |
| **4c-2** | `wrap_result` removal in `tool_operator`, `tool_misc` + sub-modules, `tool_autoresearch`, `tool_agent_timeline`, `tool_inline_dispatch` | — | TBD |
| **4d** | Standalone handlers (`progress`, `session`, `subscriptions`, `tool_deep_review`, `tool_bridge`); delete `Tool_result.wrap`, `Tool_result.to_legacy_compat`, `Coord_types.tool_result` | — | TBD |

## 6. Test Strategy

- Phase 0: exhaustive match closes new-variant gap at compile time. No regression test needed for the catch-all.
- Phase 1: existing 48 tests continued passing after string-pattern purge.
- Phase 2/3: `dune build @check` + GitHub Actions full build + test acceptance.
- Phase 4: per-module migration verified by handler-level tests; integration via `test_mcp_server_eio.ml`, `test_mcp_tool_matrix_cases.ml`.

## 7. Observability

Dashboards and Prometheus exporters that already consumed `last_blocker_class` automatically gained visibility into the 9 previously-dropped SDK variants once Phase 0 landed. No new counter or label was introduced — the structural fix made existing telemetry correct (the inverse of workaround signature #1, which would have added new counters without fixing the underlying drop).

## 8. Risks

- **Wire format compat**: legacy `(ok, message)` projection remains at the gRPC bridge. If an external consumer parsed the prose `message`, semantics are unchanged (string content identical). The structural improvement is internal.
- **Phase 4 incomplete**: `wrap_result` / `to_legacy_compat` / `Coord_types.tool_result` still exist for un-migrated handlers. Their deletion is gated on 4c-2 + 4d.
- **TLA+ bug model**: not yet authored. Phase 0 catch-all replacement is invariant-violation evidence by construction (compile-time exhaustive match), so an explicit TLA+ spec was not blocking. Could be authored as a closeout artifact.

## 9. Open Questions

1. Should `tool_failure_class` gain a 5th variant for **infrastructure failure** (e.g., `Tool_result` produced from a Cloud Run cold start, dispatcher unavailable)? Today this maps to `Runtime_failure`. Phase 4 may surface enough cases to justify a split.
2. Should `legacy_message` be retired once external consumers are typed? Currently it is the only path the gRPC bridge uses; retiring it requires a wire-format RFC.
3. Phase 4d removal list contains `Coord_types.tool_result` — that type may have external structural-typing depending. Confirm via cross-repo grep before deletion.

## 10. Documentation Backfill

This RFC was authored *after* Phase 0–4c-1 already merged into `main`. The merged PRs cited the RFC number but the canonical `docs/rfc/RFC-0062-*.md` was never created. This document is a reverse-engineered initial draft from the merged PR bodies; it must be reviewed by the original author of Phase 0 (the PRs were authored across multiple sessions and the original design intent is to be confirmed).

This is itself a process gap worth recording — RFC numbers should not be cited in PR titles until the RFC document is in `docs/rfc/`. Tracking this gap is the subject of a follow-up issue (filed against the workflow-pr instructions / pre-push hook).

## 11. References

- CLAUDE.md §"AI 코드 생성 안티패턴" #2 Unknown → Permissive Default
- CLAUDE.md §"워크어라운드 거부 기준" #2 String/Substring 분류기 보강
- RFC-0042 (closed sum type for keeper turn terminal code) — analogous structural fix in a sibling subsystem
- `lib/keeper/keeper_meta_contract.ml`, `lib/tool_result.ml`, `lib/keeper/keeper_status_bridge.ml`
