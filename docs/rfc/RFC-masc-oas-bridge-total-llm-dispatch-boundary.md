---
rfc: "masc-oas-bridge-total-llm-dispatch-boundary"
title: "Withdraw budget-and-slot authority from the MASC OAS bridge"
status: Withdrawn
created: 2026-07-17
updated: 2026-07-17
author: vincent
supersedes: []
superseded_by: "0000"
related: ["0159", "0206", "0338", "shared-admission-primitive-knob-binding-policy"]
implementation_prs: []
---

# RFC-masc-oas-bridge-total-llm-dispatch-boundary — Withdraw bridge admission authority

> **WITHDRAWN — DO NOT IMPLEMENT.** A small typed MASC→OAS projection boundary
> is valid; making it a mandatory `run_bounded` budget/slot authority is not.
> MASC must not duplicate OAS provider admission, impose implicit deadlines,
> or make one LLM lane wait behind an unrelated global/lane cap. Each caller
> owns only its typed product operation and immutable observation; configured
> LLM judgment and OAS own their respective semantic and provider boundaries.
> Historical analysis below is retained only until the stacked tombstone PR.

## 0. Summary

`Masc_oas_bridge.run_safe` is meant to be the one place MASC crosses into
the OAS Agent SDK. Today it is a well-typed wrapper (timeout/cancel/generic
exception → typed result, RFC-0159 Phase A) around **exactly the three
callers its own closed `caller` type names** — and nothing forces any other
LLM dispatch to go through it. Every other lane (board attention judge,
failure judge, the dead `Verifier_oas` lane, and — pending T1/T2 — the
compaction summarizer and memory-os librarian) calls the underlying OAS
wrapper directly and hand-rolls its own exception policy. This RFC makes
the bridge the sole, typed, budget-and-slot-aware boundary every LLM
dispatch must cross, with bypass structurally impossible rather than a
convention.

## 1. Problem

### 1.1 The bridge today (re-verified, `lib/masc_oas_bridge.ml`/`.mli`)

```ocaml
type caller =
  | Anti_rationalization
  | Fusion_judge
  | Fusion_panel

val run_safe
  :  caller:caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
```

`run_safe` classifies `Eio.Time.Timeout` → typed `Api (Timeout _)`,
re-raises `Eio.Cancel.Cancelled` with its backtrace (never swallowed), and
turns any other exception into `Keeper_internal_error.Internal_bridge_exception`
(explicitly cited in-code as "RFC-0159 Phase A"). Its own `.mli` docstring
is exact about what it does *not* do: *"without owning an execution
budget"* — no wall-clock deadline, no concurrency slot. `run_safe`'s three
callers match its three declared variants 1:1 (`rg
'Masc_oas_bridge\.run_safe' lib/`):

- `lib/fusion/fusion_judge.ml:200` → `Fusion_judge`
- `lib/fusion/fusion_panel.ml:107` → `Fusion_panel`
- `lib/workspace_metric_hooks.ml:429` → `Anti_rationalization` (the
  `masc_done` completion-review reviewer, `Task.Anti_rationalization.run_llm_reviewer_fn`)

There is no dangling/unused variant and no orphaned wrapped caller — the
bridge is fully wired for what it declares. The problem is what it does
**not** declare.

### 1.2 Confirmed bypass sites (direct calls to the underlying dispatch
wrapper, `Keeper_turn_driver_wrappers.run_named_with_masc_tools`, with no
`Masc_oas_bridge` in between)

1. **Board attention judge** — `lib/keeper/keeper_board_attention_candidate.ml`,
   function `run_judge` (`:877-933`), direct call at `:896-904`. Its own
   ad-hoc exception policy: every exception, typed or not, becomes
   `Provider_unavailable` (`:912-916`) — coarser than the bridge's
   three-way Timeout/Cancelled/Internal_bridge_exception split, and
   `Eio.Cancel.Cancelled` is manually re-raised inline rather than through
   the bridge's shared path (correctly, but redundantly re-implemented).
2. **Failure judge** — `lib/keeper/keeper_failure_judge.ml`, function `run`
   (`:98-121`), direct call at `:106-114`. Narrower still: only
   `Oas_error`/`Response_contract_error` are distinguished; no
   timeout/cancellation reclassification at all — it inherits whatever
   `Agent_sdk.Error.sdk_error` the SDK returns unmodified.
3. **`Verifier_oas.verify`** (dead lane, `lib/verifier_oas.ml:100-147`) —
   same direct-call shape, but `rg` finds zero production callers (only
   `test/test_verifier_oas_bridge.ml` and a comment in
   `keeper_adversarial_review.ml:54` that says it "mirrors" this module
   with its own duplicate implementation instead of calling it). Two
   implementations of the same verdict-parsing boundary, one entirely
   unreachable.

Additionally bypassing, confirmed by the **absence** of any
`Masc_oas_bridge` reference in the file (verified with `rg
'Masc_oas_bridge' <file>` = 0 hits each), but whose exact intermediate
dispatch call this RFC did not trace to a specific line within the scope of
this draft — flagged as lower-confidence, out of this RFC pair's direct
migration scope, and owned by the parallel T1/T2 work already in progress
in this session:

- `lib/keeper/hitl_summary_worker.ml` (Gate Auto Judge) — has its own
  admission control (the RFC-shared-admission-primitive-knob-binding-policy §1.1 exemplar) but no bridge-typed
  exception classification layered under it.
- `lib/keeper/keeper_librarian_runtime.ml` (memory-os librarian) — masc#25052.
- `lib/keeper/keeper_compaction_llm_summarizer.ml` (compaction summarizer)
  — masc#25051.

### 1.3 A claim from the source report this RFC could **not** verify

The source analysis (`~/me/reports/masc-nondeterministic-lane-analysis-2026-07-17.html`
§10) states `cross_verifier` (`deepseek.deepseek-v4-pro`) has a declared
`max-concurrent=2`, "선언만, 미강제" (declared only, unenforced). Re-checking
the checked-in seed config: `grep -n 'max-concurrent' config/runtime.toml`
returns exactly two matches, both `= 1`, both on the `[ollama.gemma4-*]`
bindings (`:968,971`). The `[deepseek.deepseek-v4-pro]` binding block
(`:212`) is **empty** — no `max-concurrent` key at all in this checkout.
The report's "=2" figure could not be located in code and may reflect a
live-deployment-only override in the untracked `.masc/config/runtime.toml`
(the report itself notes that file is absent from this checkout elsewhere).
**This RFC does not rely on the specific number 2** — the structural claim
that stands regardless (verified independently, §1.1) is that the bridge
owns no budget/slot for this caller at all, so whatever value is or is not
declared for this binding is unenforced by the bridge either way.

### 1.4 The `masc_done` completion-review path (P0, re-verified)

`workspace_metric_hooks.ml:377-449` installs
`Task.Anti_rationalization.run_llm_reviewer_fn`, which **is** wrapped in
`Masc_oas_bridge.run_safe ~caller:Anti_rationalization` (`:429`). It is
invoked from `lib/task/tool_task_handlers.ml:217`
(`Anti_rationalization.review ... ~sw:ctx.sw`), synchronously, inside the
task-completion tool-call's own handler context — the caller blocks on the
verdict before the task transition proceeds. Because the bridge wraps but
does not bound this call, the practical concurrency limit on completion
reviews is not a declared number but "however many task-done tool calls
happen to be in flight at once," bounded only incidentally by however many
agents are completing tasks concurrently. This is a live P0-class item, not
a hypothetical: it is the same class of failure the RFC-0338 lock registry
work and the RFC-0159 typed-exception work already targeted for other
boundaries; this is the one LLM-facing boundary that was wrapped for typing
but never bounded for concurrency.

### 1.5 A now-obsolete lane (verified during this draft, not assumed from the
report)

The source report's §7/§10 sections describe a fifth judge lane,
"operator judge" (`lib/dashboard/dashboard_operator_judge.ml`, wrapped in
`Masc_oas_bridge.run_safe(Operator_judge)`, 60s cadence). That file **no
longer exists**: `refactor(operator): detach periodic judgment authority
(#24829)` and its stacked commits (`#24830` delete the daemon, `#24831`
purge the timing knobs, `#24832` purge residues) merged to `main` at
2026-07-17 13:45 — hours before this draft, and after the source report was
generated. `rg -i 'operator_judge' lib/` = 0 hits; `Masc_oas_bridge.caller`
has no `Operator_judge` variant (confirmed, §1.1's full listing is
exhaustive). **This RFC does not include operator judge in its lane
inventory, dead-knob table, or migration plan** — the report's "5 judge
lanes, 3 bypass" framing is stale; the corrected count (§1.1–1.2) is: 3
callers fully wired to the bridge's 3 declared variants, 3 confirmed direct
bypasses, plus 3 lower-confidence bypasses under separate RFC-shared-admission-primitive-knob-binding-policy §5 /
T1 / T2 ownership.

## 2. Non-goals

- No pre-dispatch denial and no Keeper pause policy — identical boundary to
  RFC-shared-admission-primitive-knob-binding-policy §2 and to the still-withdrawn RFC-0153/RFC-0158. Binding a lane
  to a wall-clock budget or an `Admission.Make` slot (RFC-shared-admission-primitive-knob-binding-policy) changes when
  a call *times out* or *waits for a slot*; it never changes whether a call
  is *attempted*, and it never touches Keeper lifecycle (RFC-0341).
- Does not re-implement oas#2641 (provider-side per-endpoint admission).
  The bridge is where a masc-side declaration *attaches*; the provider
  transport enforcement is oas's.
- Does not change `Keeper_turn_admission` (RFC-0225) — the ordinary
  keeper-turn dispatch path (`Turn`, §3.1) is included in this RFC's typed
  lane vocabulary for completeness and future enforcement, but is
  deliberately the **last**, not first, lane migrated (§6) because it is the
  highest-traffic, highest-blast-radius call site in the codebase.
- Does not retroactively fix `Verifier_oas`'s dead-lane status by itself —
  RFC-shared-admission-primitive-knob-binding-policy §5 already lists it as delete-or-wire; this RFC's enforcement
  design (§4) is what makes "wire" mean something (a new caller variant) if
  that path is chosen instead of deletion.

## 3. Design

### 3.1 Typed lane identity (extends `Masc_oas_bridge.caller`)

```ocaml
type caller =
  | Turn                 (* ordinary keeper turn dispatch — last migrated, §6 *)
  | Board_attention_judge
  | Failure_judge
  | Hitl_summary
  | Librarian
  | Anti_rationalization  (* unchanged name; runtime.toml key is cross_verifier *)
  | Fusion_panel          (* unchanged *)
  | Fusion_judge          (* unchanged *)
  | Summarizer            (* compaction summarizer, T1 territory *)
```

**Deviation from the brief, made deliberately and flagged here:** the
originating brief listed one `structured_judge` lane. Code verification
(§1.2) shows board attention judge and failure judge are two distinct
modules with two distinct error types and two distinct call sites that
happen to share one `runtime.toml` binding key
(`Runtime.runtime_id_for_structured_judge`, `config/runtime.toml:26`). The
typed-lane axis (which module dispatches, for typed-error attribution and
per-lane admission) and the runtime-binding axis (which model serves the
call) are different things — RFC-0342 D3 draws exactly this distinction for
provider aliases. Collapsing both call sites into one `Structured_judge`
caller variant would erase the per-site error attribution the whole point
of extending the type is meant to buy. Both lanes may still share one
`Admission.Make` instance sized from the same `structured_judge` binding
(RFC-shared-admission-primitive-knob-binding-policy §3) if that is the desired concurrency shape — that is an
admission-instance decision, independent of the typed-lane decision.

`Anti_rationalization`/`Fusion_panel`/`Fusion_judge` are unchanged (existing
production code, no rename motivation).

### 3.2 Every lane binds an admission instance + a wall-clock budget

```ocaml
val run_bounded
  :  caller:caller
  -> admission:unit Admission.Make(String).t  (* or a caller-specific Id *)
  -> policy:Admission.wait_policy
  -> budget_s:float option  (* None = no MASC-owned deadline, same as today *)
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
```

`run_bounded` claims the admission slot (RFC-shared-admission-primitive-knob-binding-policy `Admission.Make.claim`)
before invoking the inner function and releases it (via `Fun.protect`,
covering the exception, `Cancelled`, and normal-return paths identically) no
matter how the inner call terminates, then delegates to `run_safe`'s
existing timeout/cancel/exception classification for the OAS boundary
itself. `run_safe` remains the unbounded low-level primitive (existing
callers are not forced to migrate to `run_bounded` in one PR — see §6); new
call sites are added exclusively via `run_bounded`.

`budget_s : float option` is explicit rather than a hidden default: `None`
preserves today's "MASC does not own a wall-clock budget" contract
(RFC-masc-oas-bridge-total-llm-dispatch-boundary does not silently introduce one); a lane may opt into a MASC-side
deadline only with an explicit value and an explicit reason in its call
site comment (mirroring the Magic-Number-avoidance convention already in
`software-development.md`).

### 3.3 Result-typed outcomes only across the boundary

Already partially true (`run_safe` never lets an exception escape
uncaught). This RFC extends the same discipline to callers: every
`run_bounded` caller's own wrapper function (`run_judge`,
`Keeper_failure_judge.run`, etc.) must itself return
`(_, typed_error) result` with no `try ... with exn -> ...` that collapses
distinct failure classes into one string, matching the precedent already
landed at masc#25043 (`fix(keeper): replace Board_unavailable exception
with typed disposition result`, merged, verified in `git log`) — that PR is
this RFC's proof that the codebase already accepts "replace an
exception-based boundary with a typed Result" as a mergeable, non-workaround
change.

### 3.4 Completion review: inline → typed async verdict worker

Today (§1.4): MCP tool-call fiber → synchronous `Anti_rationalization.review`
→ blocks on the LLM round-trip → task transition. Redesigned to the HITL
shape (`Keeper_approval_queue`/`hitl_summary_worker.ml`, the RFC-shared-admission-primitive-knob-binding-policy §1.1
exemplar):

```ocaml
type verdict_status =
  | Verdict_not_requested
  | Verdict_pending of { requested_at : float }
  | Verdict_available of Anti_rationalization.verdict
  | Verdict_failed of { reason : string; retryable : bool }
```

1. The `masc_done` tool handler writes a durable `Verdict_pending` record
   keyed by `task_id` (same durability class as `Keeper_approval_queue`,
   not a new persistence mechanism) and returns immediately — the task
   stays in the existing `Completion_verdict_unavailable`-shaped
   nonterminal state (already how the codebase handles
   `Evaluator_unavailable` today per `tool_task_handlers.ml`, so this is a
   widening of an existing state, not a new one).
2. A bounded worker (claims one `Admission.Make` slot per in-flight review,
   sized from the `cross_verifier` binding) dispatches through
   `Masc_oas_bridge.run_bounded ~caller:Anti_rationalization`, mirroring
   `hitl_summary_worker.ml`'s `spawn_claimed_auto_judge_entry` shape.
3. On completion, the worker writes `Verdict_available`/`Verdict_failed`
   and invokes the same `on_verdict`/SSE-broadcast callback
   (`tool_task_handlers.ml:202-212`) that exists today — the observable
   side effects (dashboard verdict event, task transition) are unchanged in
   shape, only in *when* they fire (async, on worker completion, not
   synchronously in the caller's fiber).
4. The task transition (`Completion_pass`/`Completion_reject`/
   `Completion_verdict_unavailable`) applies when the durable record
   resolves, exactly mirroring how HITL's `drain_auto_judges` resolves
   `Keeper_approval_queue` entries.

This removes the unbounded-concurrency MCP-fiber-blocking shape entirely:
the fleet-wide completion-review throughput becomes an explicit,
observable `Admission.Make` capacity instead of an emergent property of how
many `masc_done` calls happen to arrive at once.


## 4. Withdrawal cleanup

The removed rollout, acceptance, blast-radius, and workaround sections described
how to ship the withdrawn budget/slot authority. They have no surviving
implementation value. The remaining historical analysis is removed by the next
stacked tombstone leaf so no executable-looking proposal remains.
