---
rfc: "0130"
title: "Fleet Capacity Supervisor"
status: Draft
created: 2026-05-18
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0026", "0064", "0088", "0124"]
implementation_prs: []
---

# RFC-0130: Fleet Capacity Supervisor

## 1. Problem

`/health` exposes `reaction_capacity_shortfall_count`, `reaction_capacity_below_target`, and `keeper_fleet_safety.status=degraded` (PR #16050, 2026-05-18, closing issue #16047). The fields are computed correctly. No code path consumes them.

`rg "reaction_capacity_shortfall_count|reaction_capacity_below_target" lib/keeper/ lib/coord/` returns zero hits. The shortfall signal terminates at the HTTP runtime JSON emitter and the dashboard chip. Operators must visually notice the chip and run `masc_keeper_up` manually to restore capacity.

Existing admission code (`Keeper_fd_pressure.admission_decision`, `Keeper_disk_pressure`, `keeper_tool_resolution.ml` RFC-0080 chain) is all **deny-side**: it blocks launch/turn admission when low resources are detected. None of it spawns to a target.

Capacity-related RFCs in the ledger:

| RFC | Scope | Status |
|-----|-------|--------|
| RFC-0026 work-conserving-keeper-admission | Admission queue ordering | Retired, no documented successor |
| RFC-0064 capacity-probe-adapter | Provider HTTP receptivity probe | Draft, no implementation |
| RFC-0124 keeper-admission-denial-boundary | Typed denial reasons surfaced in runtime JSON | Draft, no implementation |
| RFC-0088 (umbrella) | Counter-as-Fix rejection bar | Active |

The deny side is being modeled. The spawn-to-target side is not. The 2026-05-18 live runtime (`/health` reported `degraded`, 3 running / 13 target, `operator_action_required=false`) demonstrates the gap end-to-end.

`software-development.md` §"워크어라운드 거부 기준" §3-1 (Telemetry-as-Fix) classifies the current shape as a workaround. RFC-0088 requires the umbrella record. This RFC closes the loop the umbrella demands.

## 2. Decision

Introduce a `Fleet_capacity_supervisor` that converts the typed shortfall signal into a typed spawn decision.

The decision is **closed and total**. No fallback to "log and continue". Probe-unknown is fail-closed at the admission boundary (matches RFC-0124 §2.2).

### 2.1 Surface

```ocaml
(* lib/keeper/keeper_fleet_capacity_supervisor.mli *)

type observation =
  { running_keeper_fiber_count : int
  ; target_reaction_capacity_count : int
  ; minimum_running_fibers : int
  ; reaction_capacity_shortfall_count : int
  ; admission_blocked_count : int      (* from RFC-0124 typed denial *)
  ; now : float
  }

type spawn_request =
  { reason : Spawn_reason.t            (* closed sum, see §3.1 *)
  ; suggested_keeper_names : string list  (* from autoboot/persona registry *)
  }

type decision =
  | Spawn of spawn_request
  | Backpressure of Backpressure_reason.t
  | Noop of Noop_reason.t

val tick : observation -> decision
(** Pure function. No I/O. Deterministic given the observation. *)

val execute :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  base_path:string ->
  decision ->
  Result.t
(** Side-effecting wrapper. Translates [Spawn] into [Masc_keeper_up.run]
    calls, [Backpressure] into a typed reject for the admission queue,
    [Noop] into a single observability event. *)
```

### 2.2 Why pure `tick` + `execute` split

`tick` is the testable core. `execute` is the boundary. Mirrors the pattern from RFC-0107 `Jsonl_atomic` (pure typing + IO boundary) and the keeper supervisor `Three_valued_admission` block.

The split makes property tests cheap: feed a generated `observation`, assert `decision` invariants (e.g. `running >= target ⇒ Noop`, `shortfall > 0 ∧ admission_blocked = 0 ⇒ Spawn`).

## 3. Design

### 3.1 Closed reason variants

```ocaml
module Spawn_reason = struct
  type t =
    | Below_target_reaction_capacity   (* shortfall > 0 *)
    | Below_minimum_running_fibers     (* margin breach *)
    | Recovery_from_cold_start         (* autoboot completion *)
end

module Backpressure_reason = struct
  type t =
    | Admission_queue_saturated        (* RFC-0124 denial_count exceeds cap *)
    | Disk_pressure_active
    | Fd_pressure_active
end

module Noop_reason = struct
  type t =
    | Capacity_at_target
    | Capacity_above_target           (* over-provisioned, no scale-down in v1 *)
    | Already_recently_acted          (* cooldown not over *)
end
```

All variants are closed sums. Adding a new reason is a compiler error at every match site, satisfying workaround-rejection §2 (no string classifier).

### 3.2 Wiring

```
Server_routes_http_runtime.compute_keeper_fleet_safety
  └ produces typed `observation`            (already computed today, just typed)
       │
       ▼
Fleet_capacity_supervisor.tick               (new)
       │
       ▼
Fleet_capacity_supervisor.execute
   ├── Spawn → Masc_keeper_up.run sw env ~base_path ~names
   ├── Backpressure → Coord.publish_backpressure ~reason
   └── Noop → Lifecycle event only
```

The supervisor runs as a single Eio fiber at startup (via `Switch.run` + `Switch.on_release`), ticking every `fleet_capacity_supervisor_tick_seconds` (default 30s, clamped to ≥10s).

### 3.3 Cooldown invariant

`Already_recently_acted` is the only stateful Noop reason. Cooldown duration is `min(probe_interval × 2, 120s)`. The cooldown timestamp is per-`Spawn_reason`, not global, so a disk-pressure backpressure does not delay a fresh below-target spawn after the pressure clears.

### 3.4 What this does NOT do

| Out of scope (this RFC) | Reason |
|---|---|
| Scale-down / keeper retirement | Memory `keeper_active_goal_ids_empty_no_auto_repair` lessons unresolved; separate RFC |
| Cross-machine fleet aggregation | Cluster mode is separate concern (`MASC_CLUSTER_NAME`) |
| LLM provider capacity (RFC-0064) | Provider HTTP probe is upstream; supervisor consumes its result as a boolean gate |
| Auto-pause recovery on cold start | Already handled by #16016 (still open) |

## 4. Phases

### PR-1 (this PR — RFC body only)
- RFC frontmatter, body, README index update, ledger increment.
- No code.

### PR-2 (pure core, behavior-flagged off)
- `keeper_fleet_capacity_supervisor.ml` + `.mli` with `tick` only.
- Property tests for all 9 reason permutations.
- No wiring. `execute` returns `Noop Capacity_at_target` regardless.
- Flag: `MASC_FLEET_CAPACITY_SUPERVISOR_TICK_ENABLED` defaults to `false`.

### PR-3 (wire to /health output)
- `Server_routes_http_runtime` calls `tick` and surfaces the decision in JSON under `keeper_fleet_safety.supervisor_decision` (read-only; no side effect).
- Test: synthetic 3/13 observation → JSON contains `"supervisor_decision":{"variant":"spawn","reason":"below_target_reaction_capacity"}`.

### PR-4 (execute, flagged on)
- Implement `execute` calling `Masc_keeper_up.run` for `Spawn`.
- Property test: 3 running / 13 target → after one tick + execute, 13 running.
- Flag default flips to `true`. Old behavior preserved behind `MASC_FLEET_CAPACITY_SUPERVISOR_TICK_ENABLED=false`.

### PR-5 (closeout)
- Frontmatter `status: Implemented`, `implementation_prs: [PR-2#, PR-3#, PR-4#]`.
- Update README index.
- Close issue #16168.

## 5. Test plan

Property tests in `test/test_fleet_capacity_supervisor.ml`:

```
property: ∀ obs. obs.running >= obs.target ⇒ tick obs ∈ Noop _

property: ∀ obs. obs.shortfall > 0 ∧ ¬disk_pressure ∧ ¬fd_pressure
              ⇒ tick obs ∈ Spawn _

property: ∀ obs. obs.admission_blocked > admission_cap
              ⇒ tick obs ∈ Backpressure Admission_queue_saturated

property: ∀ obs. tick obs is total (no exception, all cases covered)
```

Integration test in `test/test_server_runtime_fleet_supervisor.ml`:

```
synthesize observation { running=3; target=13; ... };
let json = Server_routes_http_runtime.runtime_json () in
assert (json has "supervisor_decision.variant == spawn");
assert (json has "supervisor_decision.reason == below_target_reaction_capacity");
assert (json has "supervisor_decision.suggested_keeper_names = [...]");
```

E2E (manual, PR-4):

```
1. Start masc server with autoboot 13-keeper config.
2. Kill 10 keepers (simulating outage).
3. Within 60s (2 ticks), observe `masc_keeper_up` is invoked for each missing name.
4. /health flips to status=ok.
```

## 6. Why now

PR #16050 (2026-05-18 09:00 KST) shipped the visibility layer. Issue #16168 records the workaround rejection. AI agents reading `lib/server/server_routes_http_runtime.ml` see the shortfall-counter pattern as precedent. Without this RFC's control loop landing, future PRs in the keeper-supervision area will copy the visibility-only pattern, satisfying #16168 by *adding more counters* rather than spawning. The pattern compounds.

Memory rule `feedback_hardcoding_and_legacy_zero_tolerance` + workaround-rejection §1 (Counter-as-Fix) make landing the closing PR a hard requirement, not a backlog item.

## 7. Related

- RFC-0026 (retired, work-conserving admission queue ordering) — different ordering concern; supervised at consumption side
- RFC-0064 (Draft, provider HTTP receptivity) — upstream of this RFC; supervisor gates Spawn on provider availability
- RFC-0088 (Active, Counter-as-Fix rejection umbrella) — supervisor is the closing pair for #16050 telemetry
- RFC-0124 (Draft, keeper admission denial typed boundary) — feeds `admission_blocked_count` observation field
- Issue #16047 (closed by #16050) — symptom report
- Issue #16168 (open) — workaround record this RFC discharges
- PR #16050 — telemetry layer
- `~/me/instructions/software-development.md` §워크어라운드 거부 기준
