---
rfc: "0127"
title: "Cascade Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0009", "0022", "0024", "0025", "0027", "0038", "0041", "0058", "0088"]
implementation_prs: []
---

# RFC-0127: Cascade Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance

## 1. Problem

### 1.1 Observed incident (2026-05-17 ~13:00–13:30 UTC)

The RunPod pod `ur1wah58zebjov` returned HTTP `502` for ~30 minutes after its
`llama-server` process aborted on `GGML_ASSERT(logits != nullptr) failed` at
`/workspace/llama.cpp/common/sampling.cpp:154` (a speculative-decoding sampler
corner-case introduced by upstream PR llama.cpp#22673). During that window the
masc-mcp fleet of 10 keepers all entered `fiber_unresolved` and the supervisor
log filled with:

```
registry: phase transition name=X old=running new=crashed event=fiber_terminated(fiber_unresolved)
```

with zero hint that the upstream root was a 502 from one specific provider.

The two gaps that combined to produce this incident are *both* visible from
`cascade.toml` itself, which already declares the desired end-state in
comments at `[providers.runpod_mtp.healthcheck]`:

> "Phase 1: 선언만. 실제 probe 동작은 Phase 3
> (`lib/cascade/provider_health.ml`) wiring 후."

This RFC closes both gaps as one umbrella because they share a single root —
cascade error semantics and observability.

### 1.2 Gap (A) — Cascade does not fast-fail on persistent 5xx

`cascade_attempt_fsm.ml:478` classifies `502` as `transient = true`:

```ocaml
let transient_http_status code =
  code = 408 || code = 409 || code = 425 || code = 429 || code >= 500
```

`cascade_fsm.ml:48-52` correctly signals `Try_next` to the next candidate when
a transient error occurs. However, the *candidate ordering itself* is fixed by
`[tier.strict_tool_candidates] members = [...]` in `cascade.toml` and never
reorders at runtime. Each keeper turn dispatches:

1. `runpod_mtp.qwen36-35b-a3b-mtp.keeper` → 502 → `Try_next`
2. `glm-coding.glm-5-1.keeper` → … (sometimes works, sometimes also transiently failing)
3. etc.

When step 1 takes nontrivial time (TCP retry, connection timeout), the turn's
*total* wall clock approaches the watchdog's `idle_turn(360s)` threshold even
if step 2/3 would have succeeded. Two consecutive `noop`-shaped failures from
the same provider trigger `noop_failure_loop(noop=4)`; six keepers stuck on the
same provider trigger `stale_fleet_batch(distinct_count=6)`. The supervisor
then forces `crashed`.

`lib/cascade/provider_health.ml` referenced by `cascade.toml` *does not
exist*. The `[providers.X.healthcheck]` blocks (`enabled`, `endpoint`,
`method`, `timeout_seconds`, `probe_interval_seconds`, `unhealthy_threshold`,
`recovery_threshold`) are parsed by `cascade_config.ml` into
`Provider_health_spec.t` but never acted upon at runtime — *config in,
behaviour 0*.

### 1.3 Gap (B) — Fiber termination drops `provider` and `http_status`

The cascade attempt machinery *captures* both fields at
`cascade_attempt_fsm.ml:493-496`:

```ocaml
| Llm_provider.Retry.ServerError { status; _ } ->
    Some (Provider_error.ServerError
            { code = status; transient = transient_http_status status })
```

These fields then traverse three lossy boundaries before reaching the operator:

1. `keeper_turn_cascade_budget.ml` (`pause_for_operator ~code ~detail` site,
   ~line 650): structured provider+status are squashed into a generic
   `code: string` like `"resilience_abort"` and a free-form `detail: string`
   passed through `short_resilience_detail`.
2. `keeper_supervisor.ml` (lines 325, 406, 531, 1521): the
   `failure_reason` enum carries a `Provider_runtime_error { code; detail }`
   variant, but `code` and `detail` are *both already strings* by this point
   — the structured `Provider_error.ServerError { code = int; transient = bool }`
   is no longer reachable.
3. `keeper_registry_types.ml` (~line 1180): `failure_reason_to_string` emits a
   single flat string into the `Fiber_terminated { outcome : string }` event,
   which `keeper_registry.ml:1792` logs as the user-visible message.

The operator sees `fiber_terminated(fiber_unresolved)` with no way to
correlate it to upstream identity. To diagnose 2026-05-17's outage we had to
manually `ssh` into the RunPod pod and `grep` `llama-server.log` for
`GGML_ASSERT` — a path that does not generalize.

Meanwhile, Prometheus already has the structured info: the metric
`masc_llm_provider_http_status_total` (lib/prometheus.ml) labels by
`provider` and `status_code`. The same labels SHOULD appear on the
fiber-termination signal so dashboards stay consistent.

## 2. Scope

In-scope:

- **(A)** Implement `lib/cascade/provider_health.ml` (Phase 3 wiring per the
  cascade.toml comment): an Eio fiber per `[providers.X.healthcheck enabled=true]`
  block, plus an in-band attempt-result feed; a per-provider health state used
  by the cascade to *skip* unhealthy candidates in the per-turn lineup.
- **(B)** Thread `provider_id : string option` and `http_status : int option`
  through `Fiber_terminated` → `failure_reason` → registry log. Add matching
  labels to the related Prometheus counters.
- A small umbrella of tests at each boundary and one end-to-end integration
  test.

Out-of-scope:

- Hot-reload of `cascade.toml` on config change (separate concern).
- Cross-provider request hedging (different design space).
- Modification of `transient_http_status` itself — the classification is
  correct; the *list reordering* is what's missing.
- Dashboard alerting routes (separate observability RFC).

## 3. Design

### 3.1 Phase split

| PR | Scope | Risk |
|---|---|---|
| **PR-1** | Provenance threading (Gap B) — no behaviour change. | Low |
| **PR-2** | `provider_health.ml` probe loop + cascade integration (Gap A). | Medium |
| **PR-3** | End-to-end integration test + dashboard panel. | Low |

PR-1 ships first because it is purely additive and lets us *observe* whatever
PR-2 changes. PR-2 reuses PR-1's structured error when feeding `record_attempt_result`.

### 3.2 PR-1 — Provenance threading

Five edit sites:

**(1) `lib/keeper/keeper_state_machine.ml`** — widen `Fiber_terminated`:

```ocaml
(* before *)
| Fiber_terminated of { outcome : string }

(* after *)
| Fiber_terminated of {
    outcome     : string;
    provider_id : string option;
    http_status : int option;
  }
```

All existing constructors receive `~provider_id:None ~http_status:None`. The
OCaml compiler enforces exhaustive update at every call site.

**(2) `lib/keeper/keeper_registry_types.ml`** — widen `Provider_runtime_error`:

```ocaml
| Provider_runtime_error of {
    code        : string;
    detail      : string;
    provider_id : string option;   (* NEW *)
    http_status : int option;      (* NEW *)
  }
```

**(3) `lib/keeper/keeper_turn_cascade_budget.ml` (~line 650)** —
where the cascade result is converted to a failure reason, *before* the
existing string-squash, extract the structured fields:

```ocaml
let provider_id, http_status =
  match last_provider_error with
  | Some (Provider_error.ServerError { code; _ }) -> Some provider, Some code
  | _ -> None, None
in
set_failure_reason
  (Provider_runtime_error
     { code = resilience_code; detail = short_resilience_detail detail;
       provider_id; http_status })
```

**(4) `lib/keeper/keeper_registry.ml:1792`** — log format:

```ocaml
let fmt_event = function
  | Fiber_terminated { outcome; provider_id = None; http_status = None } ->
      Printf.sprintf "fiber_terminated(%s)" outcome
  | Fiber_terminated { outcome; provider_id; http_status } ->
      let prov = Option.fold ~none:"" ~some:(Printf.sprintf " provider=%s") provider_id in
      let http = Option.fold ~none:"" ~some:(Printf.sprintf " http=%d") http_status in
      Printf.sprintf "fiber_terminated(%s%s%s)" outcome prov http
```

Result: a 502 from RunPod surfaces as
`fiber_terminated(fiber_unresolved provider=runpod_mtp http=502)`.

**(5) `lib/keeper/keeper_metrics.ml`** — verify
`metric_keeper_turn_error_after_tools` (or equivalent) accepts `provider_id`
and `http_status` labels with the same string form as
`masc_llm_provider_http_status_total`.

**Test:** `test/test_keeper_registry_provenance.ml` — Synthetic
`Provider_error.ServerError { code = 502; transient = true }` through the
conversion path; assert (a) the resulting `Fiber_terminated` has
`provider_id = Some "runpod_mtp"` and `http_status = Some 502`, and (b)
`fmt_event` produces a string containing both `provider=runpod_mtp` and
`http=502`.

### 3.3 PR-2 — Provider health probe loop

New module `lib/cascade/provider_health.ml` + `.mli`:

```ocaml
type health_state =
  | Healthy
  | Unhealthy of { since : float; consecutive_failures : int }

type t

val create : Coord.config -> t

val start_probe_fiber : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> unit
(** Spawn one fiber per [providers.X.healthcheck enabled=true] block. *)

val is_healthy : t -> provider_id:string -> bool

val record_attempt_result :
  t -> provider_id:string -> success:bool -> http_status:int option -> unit
(** Feed in-band per-turn results; affects state alongside probe results. *)

val snapshot : t -> (string * health_state) list
(** For dashboard / Prometheus gauge. *)
```

State machine:

- A provider starts `Healthy`.
- After `unhealthy_threshold` consecutive failures (probe failure OR in-band
  result with `success=false`), it becomes `Unhealthy { since = Time.now; ... }`.
- After `recovery_threshold` consecutive successes, it returns to `Healthy`.
- `record_attempt_result` counts toward both thresholds, so a single 502 from
  a real keeper turn counts immediately (not waiting for the next probe).

Wire-in:

- `lib/cascade/cascade_fsm.ml:48-52` — before selecting next candidate, filter
  the candidate list through `Provider_health.is_healthy`. If the filter
  produces an empty list, fall through to the original list (no deadlock).
- `lib/cascade/cascade_runtime.ml` (or whatever owns the cascade context per
  config) — own one `Provider_health.t` per cascade config.
- `lib/coord/coord_lifecycle.ml` (or the equivalent top-level
  `Eio.Switch.run` site) — call `start_probe_fiber` at startup, with the
  switch attached to the supervisor's lifetime.

**Test:** `test/test_provider_health.ml`:

- Mock HTTP server returning 502 → assert `is_healthy = false` within
  `unhealthy_threshold * probe_interval_seconds`.
- Mock server flipped to 200 → assert `is_healthy = true` within
  `recovery_threshold * probe_interval_seconds`.
- Pure-state test: `record_attempt_result ~success:false` N times where N >=
  `unhealthy_threshold` flips state without probe involvement.
- Cascade-list filter test: given a candidate list `[A; B; C]` and
  `is_healthy A = false`, the filtered list begins with `B`.

### 3.4 PR-3 — Integration test + dashboard panel

- `test/test_cascade_fast_fail_e2e.ml`: stub two providers (one returning 502,
  one returning 200), run a keeper turn, assert (a) the turn dispatches to
  the 200 provider, (b) the system log contains
  `fiber_terminated(... provider=<502-provider-id> http=502)` for any
  *discarded* first attempt, and (c) within `unhealthy_threshold` cycles the
  502 provider is filtered out entirely.
- Dashboard: add a `provider_health_state{provider=...}` gauge (1=Healthy,
  0=Unhealthy) and a `provider_unhealthy_seconds_total` counter. Reuse the
  existing `provider` label used by `masc_llm_provider_http_status_total`.

## 4. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `Fiber_terminated` variant widening cascades to many caller sites. | OCaml exhaustive-match compile guarantees no missed updates. Default `~provider_id:None ~http_status:None` for non-cascade paths preserves all current behaviour. |
| Probe fiber leaks across pod restart / supervisor crash. | `Eio.Switch.on_release` cleanup. Dedicated test in PR-2: tear down switch, assert fiber stopped. |
| Probe loop floods upstream during outage. | Minimum `probe_interval_seconds = 60` enforced at config-parse time (validated, with rejection of `<60`). Document in cascade.toml schema comments. |
| Filter empties candidate list, causing dead-cascade. | Empty-after-filter is the explicit *fall-through* case — original list is returned. Dashboard surfaces "all-unhealthy" state via the gauge so the operator sees the degraded condition. |
| `RFC-0125` 3-way collision pattern recurs and someone else takes 0126 mid-plan. | Ledger advanced to 0128; Draft PR opened immediately after this commit so the reservation becomes visible in `gh pr list --search RFC-0127`. |
| Phase-2 fiber blocks ALL cascade configs at config-parse failure of one provider. | Probe-spawn loop iterates per provider with try/with; a malformed `[healthcheck]` block disables only that provider's probe, not the supervisor. |

## 5. Implementation order

1. This RFC body + ledger advance (this PR).
2. PR-1 (provenance) merges.
3. PR-2 (probe loop) opens against current `main`.
4. PR-3 (integration test + dashboard) follows PR-2.
5. Closeout commit + RFC status `Draft → Implemented`.

## 6. Open questions

- **Q1**: Should `record_attempt_result` weight an in-band result more than a
  scheduled probe? Probe is lightweight `/v1/models GET`; in-band is real
  turn-shape traffic. Initial design weights them equally; revisit if false
  positives accumulate.
- **Q2**: Should `Unhealthy` providers be entirely skipped, or should the
  cascade attempt them last (so we still try them if the healthy set is
  exhausted)? Initial design: skip entirely; fall-through only when *all*
  candidates are unhealthy.

## 7. References

- `cascade.toml:432-468` — `[providers.runpod_mtp.healthcheck]` Phase 1
  declaration (comments reference Phase 3 wiring deferral)
- `lib/cascade/cascade_attempt_fsm.ml:478` — `transient_http_status`
- `lib/cascade/cascade_fsm.ml:48-52` — `Try_next` signal site
- `lib/keeper/keeper_registry.ml:1792` — phase-transition log emit
- `lib/prometheus.ml` — `masc_llm_provider_http_status_total` label semantics
- 2026-05-17 incident system log: `.masc/logs/system_log_2026-05-17.jsonl`
  (52 × `fiber_terminated(fiber_unresolved)` events)
- llama.cpp PR #22673 (speculative decoding draft-mtp — the upstream root of
  the 2026-05-17 502)
