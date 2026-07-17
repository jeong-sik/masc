---
rfc: "shared-admission-primitive-knob-binding-policy"
title: "Shared typed admission primitive + knob-binding policy"
status: Superseded
created: 2026-07-17
updated: 2026-07-17
author: vincent
supersedes: []
superseded_by: "oas-recursive-execution-masc-integration"
related: ["0153", "0158", "0206", "0225", "0334", "masc-oas-bridge-total-llm-dispatch-boundary", "oas-recursive-execution-masc-integration"]
implementation_prs: []
---

# RFC-shared-admission-primitive-knob-binding-policy — Shared typed admission primitive + knob-binding policy

> **Superseded 2026-07-17.** Its evidence inventory remains historical input,
> but the proposed budget/concurrency substring registry, MASC-side provider
> admission, `Skip_if_full` durable-work path, and flag-based dual rollout are
> not target contracts. `RFC-oas-recursive-execution-masc-integration` §0.1
> replaces them with typed owner declarations, OAS-owned provider admission,
> and per-owner durable queue conservation. A future resource-only primitive
> must be justified by a concrete owner and cannot become a behavioral budget.

## 0. Summary

Every MASC lane that needs to bound "how many of X may run at once" has
independently invented its own idiom. Exactly one lane — the HITL claim-set
— is bounded by construction. Everywhere else, the bound is either absent,
computed but discarded, or read by nobody. This RFC extracts the HITL shape
into one shared, typed admission primitive and makes "a knob binds to a
running admission instance, or the parser rejects it" a normative,
CI-checkable rule. It does not introduce pre-dispatch denial or a Keeper
pause policy (§5).

## 1. Problem (evidence)

### 1.1 Three incompatible bound idioms, one of them alive

Re-verified in this checkout (`workspace/yousleepwhen/masc`, `main` at the
time of writing) rather than assumed from the source analysis report:

1. **Atomic claim-set, construction-bounded.** `lib/keeper/keeper_gate.ml:283-294`
   (`claim_auto_judge`) CAS-loops an `Auto_judge_ids.t Atomic.t` and refuses
   the claim once `Auto_judge_ids.cardinal active >=
   Hitl_summary_worker.max_concurrency ()`. `max_concurrency` itself
   (`lib/keeper/hitl_summary_worker.ml:44-61`) recomputes
   `min(configured, runtime_binding.max_concurrent)` on every call — the
   bound is live-read, not captured once at boot. This is the only lane in
   the codebase where "at most N concurrent" is a type-level guarantee
   rather than a comment.
2. **Per-keeper capacity slot, bypassed at the sub-call layer.** The
   `[ollama.gemma] max-concurrent=1` binding
   (`config/runtime.toml:968,971`) is read by exactly one consumer —
   `hitl_summary_worker.ml:56` via `runtime.Runtime.binding.max_concurrent`.
   Every other runtime binding in the seed TOML
   (`ollama_cloud_native.minimax-m3-native-structured`,
   `ollama_cloud.ollama-cloud-devstral-2-123b`, `deepseek.deepseek-v4-pro`)
   carries no `max-concurrent` value, and even where a value is threaded
   into a `Runtime_candidate.t` (`lib/keeper/keeper_turn_driver.ml:541`,
   `Runtime_candidate.of_provider_config ~max_concurrent`), the only reader
   of `Runtime_candidate.max_concurrent` in `lib/` is the dashboard JSON
   projection (`lib/server/server_dashboard_http_runtime_info.ml:1665`) —
   display, not enforcement. Provider-side enforcement is tracked
   separately at oas#2641 (open, "admit concurrent dispatches per endpoint
   identity") and is a dependency, not something this RFC re-implements
   (see RFC-masc-oas-bridge-total-llm-dispatch-boundary §4).
3. **Parsed-and-discarded config knobs.** See §1.2 — validated at load time,
   consulted nowhere at dispatch time.

### 1.2 Dead knob inventory (re-verified 2026-07-17, corrected against the
source analysis report)

The source material for this RFC was
`~/me/reports/masc-nondeterministic-lane-analysis-2026-07-17.html` §9. Every
row below was independently re-checked with `rg` against the current
checkout; three rows changed disposition since the report was generated
(the codebase moved under the report within the same day — see the notes).

| # | knob | location | verified disposition |
|---|---|---|---|
| 1 | `[fusion] max_concurrent_panels` | `runtime.toml` → fusion policy | **STALE CLAIM — already deleted.** `rg 'max_concurrent_panels' lib/ config/` = 0 hits. Removed today by `refactor(fusion): remove provider panel cap (#24961)` / `remove zombie concurrency settings (#24968)` / `delete dead concurrency authority (#24972)`, all merged to `main` 2026-07-17 12:25–13:45, hours before this draft. No migration action — cite as the precedent this RFC's policy formalizes (deletion, not a lingering parse-and-ignore). |
| 2 | `[fusion] max_concurrent_judges` | 〃 | **STALE CLAIM — already deleted**, same three commits as #1. The report's "double-dead: list-length override + callee `let _ =` discard" description no longer applies; the field itself is gone, not merely discarded. `rg "let _ =" lib/fusion/*.ml` today finds exactly one unrelated site (`fusion_orchestrator_judge_wave.ml:48`, discarding `preset, judge_web_tools, already_timed_out` — a different knob, out of scope here). |
| 3 | `[fusion.gate] per_hour_budget=20` + 3 keys (`panel_timeout_s`/`judge_timeout_s`/`max_tool_calls_per_panel`) | 〃 | **Confirmed dead, pre-existing.** `rg` across `lib/` and `config/` = 0 hits for all four keys. Parser already rejects them (per report, PR #22051, unrelated to today's fusion churn). Already conforms to this RFC's §3 policy option (b) — no action needed. |
| 4 | `[fusion] min_answered` quorum | 〃 | **Confirmed live dead knob.** `lib/fusion_core/fusion_config.ml` parses, range-validates (`Validated_preset.of_preset`), and serializes (`fusion_config_json.ml:48`) `min_answered`. `rg 'min_answered' lib/fusion/*.ml` = **0 hits** — the orchestrator that actually decides whether to invoke the judge never reads it. Needs migration (§4). |
| 5 | `[reactive].concurrency=4` / `[autonomous].concurrency=4` / `semaphore_wait_timeout_sec` | "live config" per report | **COULD NOT VERIFY.** `rg` for `semaphore_wait_timeout` (any casing) across the entire checkout = 0 hits. No `[reactive]`/`[autonomous]` TOML table with a `concurrency` key exists in `config/runtime.toml`, and no OCaml parser references such a table. The only `reactive`/`autonomous` identifiers found are keeper lifecycle-lane labels (`keeper_lifecycle_gate.ml`, `keeper_turn_admission.ml`'s `Autonomous`/`Chat` lanes — RFC-0225), unrelated to a concurrency knob. This may live only in the untracked deployment-local `.masc/config/runtime.toml` (the report itself notes that file is "untracked and absent in this checkout" for other findings). **Not included in the migration table below pending confirmation against the live deployment config** — do not act on this row without re-verifying against `.masc/config/runtime.toml` directly. |
| 6 | provider `max-concurrent` (e.g. `flash=2`) | `runtime.toml` bindings | **Confirmed.** Enforced only for the lane that reads it (HITL, gemma bindings). Every other binding's `max-concurrent` is either absent or unread. Depends on oas#2641 (open) for provider-side enforcement; masc-side declaration wiring is this RFC + RFC-masc-oas-bridge-total-llm-dispatch-boundary's job. |
| 7 | `MASC_HTTP_MAX_CONNECTIONS` | env | **Confirmed dead in the h1/auto path, live-but-differently-named in h2.** `lib/http_server_eio.ml:14,24` constructs the field from the env var (default 512) and never reads it again in that module — dead. `lib/http_server_h2.ml:19,283` has a same-named field (default 128) that **is** wired, but only as `Eio.Net.listen`'s `~backlog`, not a live-connection cap — two independent config records sharing an env-var name and a superficially similar field name, not one shared knob. |
| 8 | `MASC_KEEPER_DOMAIN_POOL_ENABLED` | env | **Confirmed dead by the code's own doc comment.** `lib/config/env_config_keeper_supervisor.ml:5-11`: *"The supervisor still reads this for observability, but keepalive fibers remain on the owning Eio domain… routing the whole body through `Domain_pool.submit_io` is not domain-safe."* Read (`keeper_supervisor_launch.ml:92`), logged, never changes dispatch. Adjacent to masc#20681. |
| 9 | Compaction ratio/message/token gates | keeper meta, all keepers | **Out of this RFC's scope — T1 territory (masc#25051, open, in progress in this session).** No evaluation point; compaction is overflow-reactive only. Cited for completeness, not migrated here. |
| 10 | `[ollama.gemma] max-concurrent=1` (librarian path) | `runtime.toml` | **Out of this RFC's scope — T2 territory (masc#25052, open, in progress in this session).** Sub-call path bypasses the binding. Cited for completeness. |
| 11 | `MASC_KEEPER_MEMORY_LLM_SUMMARY` | env | **Confirmed 0 production callers.** The only consumer chain (`keeper_memory_bank.ml:194` → `consolidate_memory_notes` → `compact_memory_bank_if_needed`) is called exclusively from `test/test_keeper_memory_bank_compaction_errors.ml`; `rg 'compact_memory_bank_if_needed' .` outside `test/` = 0. A pure test-only code gate today. |
| 12 | goal-loop OODA worker rebroadcast | dashboard SSE | **Not independently re-verified beyond the report.** `lib/server/server_dashboard_http_goal_loop_broadcast.ml:1-4` confirms the worker is an out-of-process Python component the OCaml side only relays; liveness-checking that out-of-process worker is outside what `rg` over this repo can confirm. Included per report, flagged as lower-confidence. |
| 13 | `Verifier_oas.verify` / `Keeper_adversarial_review` | `lib/` | **Confirmed dead lane.** `rg 'Verifier_oas'` outside `test/test_verifier_oas_bridge.ml` and comments = 0. `keeper_adversarial_review.ml:54` duplicates the verdict-parsing pattern instead of calling it — two implementations of the same boundary, one with zero callers. |
| 14 | Runtime-manifest journal retention | opt-in knob | **Confirmed.** `lib/keeper/keeper_runtime_manifest_housekeeping.ml:12-14`: opt-in via `MASC_RUNTIME_MANIFEST_RETENTION_DAYS`, `None` default = unbounded growth unless an operator explicitly sets it. |

Two items in the report's original 14 (fusion `max_concurrent_panels` /
`max_concurrent_judges`) were resolved by deletion in the ~2 hours before
this draft was written — evidence that "delete the dead knob" is already an
accepted remedy in this codebase; this RFC generalizes when to delete versus
wire.

## 2. Non-goals

- **No pre-dispatch denial.** This RFC does not add a gate that refuses a
  Keeper turn, board post, or LLM call before it is attempted. Every
  admission instance defined here bounds *concurrency of in-flight work*,
  never *eligibility* of a request. This is the same boundary RFC-0153
  ("Withdraw runtime tier admission") and RFC-0158 ("Withdraw MASC
  retry-admission denial") drew, and this RFC does not reopen either: RFC-0153
  withdrew a **capacity-tier / pre-dispatch refusal** model; RFC-0158
  withdrew **retry-budget-based call refusal**. Waiting for a claim-set slot
  under `Wait_fifo` (§3) is queueing, not denial — the caller's request is
  never rejected, only delayed until capacity exists, exactly like the HITL
  exemplar today. A request that waits still runs; RFC-0153/0158 forbade
  requests that are refused outright.
- **No Keeper pause policy.** Nothing here can stop, cooldown, or degrade a
  Keeper lane. Admission instances bound *lanes of LLM/board work*
  (judge fan-out, panel/judge concurrency, compaction summarizer slots),
  never a Keeper's own turn eligibility (that boundary belongs to
  `Keeper_turn_admission`, RFC-0225, which this RFC does not modify).
- Not a scheduler: no priority, no preemption, no deadline propagation.
  Claim order is arrival order (`Wait_fifo`) or immediate refusal
  (`Skip_if_full`); nothing more.
- Not a replacement for oas#2641 (provider-side admission). This RFC
  produces the masc-side instance a binding attaches to; the provider
  transport enforcement is oas's job.

## 3. Design

### 3.1 Extracted module

New leaf library, following the existing standalone-primitive convention
(`lib/cancel_safe/`, `lib/bounded_event_dedupe/`, `lib/fd_accountant/` — each
a single-module library with `(wrapped false)` and a narrow dependency
list): `lib/admission/admission.ml` / `.mli`, public name `masc.admission`,
depending only on `eio` (for `Eio.Condition`).

```ocaml
(** Admission — shared typed claim-set primitive (RFC-shared-admission-primitive-knob-binding-policy).
    Generalizes the HITL claim-set exemplar
    (keeper_gate.ml:283-294 claim_auto_judge / hitl_summary_worker.ml:44-61
    max_concurrency) so every concurrency-bounded lane binds to one
    implementation instead of hand-rolling a CAS loop. Bounds concurrency of
    in-flight work only; never denies a request outright (RFC-shared-admission-primitive-knob-binding-policy §2). *)

type wait_policy =
  | Skip_if_full
    (** Returns [None] immediately when at capacity or [id] is already
        claimed. Matches the board-attention/failure-judge shape: the
        producer re-forks later rather than blocking the calling fiber. *)
  | Wait_fifo
    (** Blocks the calling fiber on an [Eio.Condition] until a slot frees,
        admitted in FIFO arrival order. Matches the HITL durable-queue
        shape. [Eio.Cancel.Cancelled] while waiting is always re-raised,
        never swallowed — the wait never becomes a silent drop. *)

module type Id = sig
  type t
  val compare : t -> t -> int
  val to_string : t -> string (** observation/snapshot only, never used for
                                    equality or ordering *)
end

module Make (Id : Id) : sig
  type t

  val create : max_concurrent:(unit -> int) -> t
  (** [max_concurrent] is re-read on every claim attempt, not captured once
      — mirrors [Hitl_summary_worker.max_concurrency]'s live
      [min(configured, runtime_binding)] recompute, so a runtime-binding
      change takes effect without restarting the admission instance. *)

  val claim : t -> policy:wait_policy -> Id.t -> (unit -> unit) option
  (** [Skip_if_full]: [None] if full or [id] already claimed; [Some release]
      on success. [Wait_fifo]: never returns [None] — either admitted
      ([Some release]) or the wait raises [Eio.Cancel.Cancelled]. The
      caller MUST invoke [release] exactly once, normally via
      [Fun.protect] / [Eio.Switch.on_release], mirroring the lease-return
      discipline of RFC-0338's lock registry. *)

  val snapshot : t -> Id.t list
  (** Wait-free read of currently-claimed identities for dashboards. Never
      blocks behind an in-flight claim/release — reuses the immutable-map
      snapshot pattern RFC-0338 established for the persistence lock
      registry. *)
end
```

`Id.compare`/`to_string` are a functor parameter, not `Stdlib.compare` —
avoids the polymorphic-compare foot-gun on non-comparable payloads (closures,
`Eio.Mutex.t`, etc. that might otherwise leak into an identity type).

### 3.2 Relationship to `Keeper_turn_admission` (RFC-0225)

`Keeper_turn_admission` is a *different* arity: one slot per `(base_path,
keeper_name)` key, mutual exclusion (cardinality 1 per key, unbounded
distinct keys). `Admission.Make` is a *global* cardinality-N claim-set over
one key space (e.g. all in-flight board-attention judgments across all
keepers, capped at a single N). They compose — a lane can be gated by both
(per-keeper single-flight *and* a fleet-wide cap) — but this RFC does not
fold one into the other. `Keeper_turn_admission` is unmodified.

### 3.3 Snapshot / dashboard integration

`snapshot` gives the dashboard read path the same shape HITL's
`Keeper_approval_queue` already exposes (pending/claimed counts), so lanes
migrated onto `Admission.Make` get dashboard visibility for free instead of
each lane inventing its own counter.

## 4. Knob-binding policy (normative)

Every concurrency or budget knob introduced from this RFC onward — and every
existing one migrated per §5 — **MUST** satisfy exactly one of:

**(a) Bound.** The knob's value is read by `Admission.Make(...).create
~max_concurrent` (or an equivalent, explicitly-documented live consumer) at
the point the subsystem boots. If the subsystem the knob claims to govern
does not exist yet at boot time, boot fails loudly (a typed
`Unbound_admission_knob` error at the config-validation boundary) rather than
silently accepting an inert value — the "parsed but unread" class of bug
this RFC exists to close.

**(b) Rejected.** The config parser refuses an unknown key outright (as
`[fusion.gate] per_hour_budget` etc. already do per §1.2 row 3). A knob that
is neither consumed nor rejected is, by definition, the anti-pattern.

### 4.1 CI-checkable enforcement

Proposed check (new script, `scripts/lint/admission-knob-binding-check.sh`,
modeled on the existing `pr-rfc-check.sh` / lint-script convention): build a
registry of declared concurrency/budget-shaped config keys (TOML tables
matching `max_concurrent*`, `*_concurrency`, `*_budget`, `max-concurrent`,
by static grep over `config/runtime.toml` + parser `Otoml.find*` call sites)
and diff it against the set of keys with a confirmed `Admission.Make`
consumer (traced via a doc-comment convention: every `Admission.Make.create`
call site carries a `(* knob: <toml-path> *)` comment the script greps for).
Any key in the declared set with no matching consumer comment and no
explicit rejection test fails CI. This is a structural diff, not a new
heuristic classifier — it does not decide *whether* a knob should exist,
only whether the declared/consumed sets agree.

## 5. Migration table

| knob | disposition | target |
|---|---|---|
| `[fusion] max_concurrent_panels` | already deleted (§1.2 #1) | none — cite as precedent |
| `[fusion] max_concurrent_judges` | already deleted (§1.2 #2) | none — cite as precedent |
| `[fusion.gate] per_hour_budget` + 3 keys | already rejected by parser (§1.2 #3) | none |
| `[fusion] min_answered` | wire | fusion orchestrator's judge-invocation decision point (`lib/fusion/`) reads `Validated_preset.min_answered` and skips the judge call below threshold, OR delete the field if the product decision is "always judge regardless of quorum" |
| `[reactive]/[autonomous] concurrency` | **unresolved — could not locate in code (§1.2 #5)** | confirm against live `.masc/config/runtime.toml` before any action; do not delete or wire blind |
| provider `max-concurrent` (non-HITL bindings) | wire | RFC-masc-oas-bridge-total-llm-dispatch-boundary §4 — bridge attaches an `Admission.Make` instance per lane, sized from the binding, pending oas#2641 for provider-side enforcement |
| `MASC_HTTP_MAX_CONNECTIONS` (h1/auto) | wire or delete | either wire into a real connection-cap in `http_server_eio.ml`, or delete the field and its env var (keep `MASC_TCP_LISTEN_BACKLOG`, which is live) |
| `MASC_KEEPER_DOMAIN_POOL_ENABLED` | delete | flag is read-for-observability-only by the code's own admission; either wire `Domain_pool.submit_io` for a domain-safe subset of the keepalive body, or delete the flag — masc#20681 |
| Compaction ratio/message/token gates | out of scope | T1, masc#25051 |
| `[ollama.gemma] max-concurrent=1` librarian bypass | out of scope | T2, masc#25052 |
| `MASC_KEEPER_MEMORY_LLM_SUMMARY` | wire or delete | T2 territory (masc#25052) — 0 production callers today; either wire `compact_memory_bank_if_needed` into a live consolidation path or delete the flag and the dead code behind it |
| goal-loop OODA rebroadcast | not migrated here | lower-confidence claim (§1.2 #12), needs its own investigation of the Python worker's liveness contract |
| `Verifier_oas.verify` / `Keeper_adversarial_review` | delete or wire | RFC-masc-oas-bridge-total-llm-dispatch-boundary §3 — collapse to one verdict-boundary implementation, consumed through the bridge, or delete `Verifier_oas` outright |
| Runtime-manifest journal retention | flip default or gate | change `MASC_RUNTIME_MANIFEST_RETENTION_DAYS` from opt-in-`None` to an explicit bounded default, or add the proactive gate the report's compaction-starvation finding (S3) already motivates |

## 6. Acceptance

- `lib/admission/` exists, `(wrapped false)`, depends only on `eio`; unit
  tests cover `Skip_if_full` refusal at capacity, `Wait_fifo` FIFO admission
  order under contention (deterministic via `Eio.Condition` + a barrier, not
  sleep-based timing), cancellation while waiting (re-raises, releases no
  phantom slot), and `snapshot` never blocking behind a held claim.
- HITL's `claim_auto_judge`/`Auto_judge_ids` migrated onto
  `Admission.Make` with no behavior change (regression: existing HITL tests
  green, `max_concurrency` semantics unchanged).
- `scripts/lint/admission-knob-binding-check.sh` exists and is wired into
  CI; running it against current `main` at merge time reports zero
  unresolved knobs from the §5 "wire or delete" rows (each has landed one
  way or the other, or is explicitly waived with a dated follow-up issue).
- The one item this RFC could not verify (`[reactive]/[autonomous]
  concurrency`, §1.2 #5) is resolved to either "confirmed absent, remove
  from any future audit" or "confirmed present in live deployment config,
  added to §5" before this RFC moves to Active.

## 7. Blast radius

| change | sites | risk | rollback |
|---|---|---|---|
| New `lib/admission/` library | 0 existing callers (new code) | low | delete the library |
| HITL migrated onto `Admission.Make` | `keeper_gate.ml` (claim/release call sites), `hitl_summary_worker.ml` (`max_concurrency`) | 중 — core approval-queue path | keep `Auto_judge_ids`/CAS loop behind a flag one release |
| Provider `max-concurrent` wiring (non-HITL) | RFC-masc-oas-bridge-total-llm-dispatch-boundary's bridge callers | 중 — first real concurrency cap on previously-unbounded lanes (board attention, failure judge); could introduce backpressure where none existed | ship with `Skip_if_full` first (matches today's unbounded-but-also-uncapped behavior more closely than `Wait_fifo`), promote to `Wait_fifo` in a follow-up once queue depth is observed |
| CI knob-binding check | new script only | low | script is advisory (warn) before it is required (fail) |

## 8. Workaround-rejection self-check (CLAUDE.md)

- Not telemetry-as-fix: the CI check (§4.1) enforces that a knob either
  binds or is rejected; it does not merely count unbound knobs.
- Not a string classifier: `Admission.Make` is a functored, typed module;
  the CI check's key registry is a structural TOML/parser diff, not a
  substring vocabulary that grows over time.
- Not N-of-M: §5's migration table lists every knob found; no row is
  deferred as "will finish the rest in a follow-up PR" without an owner (T1
  masc#25051, T2 masc#25052, or this RFC's own §5 rows).
- Root fix, not symptom suppression: the failure mode being closed is
  "operator believes a knob has effect; it does not" — the fix is either
  giving it effect or removing it, never adding an alarm that it has no
  effect.
