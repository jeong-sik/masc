---
rfc: "0081"
title: "OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0046", "0049", "0063"]
implementation_prs: []
---

# RFC-0081 — OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline

- **Status**: Draft
- **Author**: vincent (yousleepwhen)
- **Created**: 2026-05-14
- **Related**: RFC-0046 (keeper detail FSM Hub SSOT — same UI surface), RFC-0049 (surface telemetry foundation), RFC-0063 (telemetry feedback loop — same consumer fiber), **RFC-OAS-019** (upstream stream lifecycle aggregation in `agent_sdk`)
- **Supersedes**: closed PR #15128 (RFC-0073) — same operator-facing goal but mis-located the emission source inside masc-mcp; RFC-0081 carves the work into the correct boundary (developer: `agent_sdk` for emission via RFC-OAS-019, masc-mcp for envelope context and pivot UI here)

## 0. Summary

Two operator-facing defects in masc-mcp's telemetry view of OAS streams are addressed here. Per-chunk noise — the third defect originally bundled in the closed RFC-0073 — is the upstream `agent_sdk` repo's emission surface and is now scoped under **RFC-OAS-019** in `~/me/workspace/yousleepwhen/oas`.

1. **Envelope context null** — every `oas:telemetry_event` record written to `.masc/telemetry/YYYY-MM/DD.jsonl` has `agent_name`, `task_id`, `turn` as `null`. The receive path (`lib/keeper/keeper_telemetry_consumer.ml`) deliberately skips deserialization, and no other site stamps the envelope. Operators cannot answer "which keeper, which turn, which goal produced this record?"

2. **Pivot impossibility** — there is no `(keeper_name | goal_id) → ordered events` query path. `tool_agent_timeline` (6-source merger) is keyed on `agent_name` only; `telemetry_unified` exposes no keeper/goal filter; the dashboard `keeper-detail-state.ts` mounts a trajectory slot but the backend it talks to has no turn-grouped event endpoint. Goal detail has no timeline tab.

This RFC scopes the receive-side and pivot-side fix. The emission-side change is RFC-OAS-019's responsibility.

## 1. Cross-repo boundary (why this RFC exists separately)

`agent_sdk` is consumed via opam pin `git+https://github.com/jeong-sik/oas.git#<sha>` (`dune-project` line 44: `(agent_sdk (>= 0.193.10))`). The `Streaming_chunk_n` payload variant lives in `lib/llm_provider/telemetry_event.ml:20-24` of the `oas` repo, not in masc-mcp. masc-mcp receives `Event_bus.Custom("telemetry_event", json)` payloads via the upstream SDK, filters them in `keeper_telemetry_consumer.ml`, and forwards to a dated JSONL store at `lib/telemetry_eio.ml:114`.

| Concern | Owner repo | RFC |
|---|---|---|
| Per-chunk emission → lifecycle summary | `oas` (`agent_sdk`) | **RFC-OAS-019** |
| Envelope context stamping at receive | `masc-mcp` | This RFC §3 |
| Persisted run-index for cross-record pivot | `masc-mcp` | This RFC §4 |
| Pivot API + UI | `masc-mcp` | This RFC §5 |

Mixing the two would break the SDK Independence Gate that `oas` enforces on Ready (per `~/me/memory/reference_oas_pr_policy_vs_masc_mcp.md`). This RFC names no `oas` internal identifiers in `lib/`; it only consumes the public `Telemetry_event` variants as published by `agent_sdk` ≥ 0.194.0 (RFC-OAS-019's target version).

## 2. Goal

1. **Envelope stamping** — every `oas:telemetry_event` written while a keeper turn is on the fiber stack carries `keeper_name`, `keeper_turn_id`, `agent_name`, `task_id`, `goal_id`, `oas_run_id`. Records emitted outside a keeper turn keep null fields (additive — no regression for pre-existing consumers).
2. **Run-index reverse map** — `.masc/run-index/YYYY-MM/DD.jsonl` written one line per keeper turn, indexed by `oas_run_id → (keeper_turn_id, keeper_name, goal_id, started_at, ended_at)`. Bridges pre-stamping records and cross-run pivots.
3. **Pivot API** — `GET /api/v1/keeper/:name/timeline` and `GET /api/v1/goal/:id/timeline` return events grouped by `keeper_turn_id`, reusing the existing `tool_agent_timeline` 6-source merger.
4. **Pivot UI** — single `keeper-timeline.ts` component renders the API output as either a vertical collapsible list (turn → events) or a horizontal `vis-timeline` swimlane, switched by a `layoutMode` signal.

## 3. Non-goals

- Re-emit, throttle, or deduplicate any upstream `oas:telemetry_event` payload. The bus contents are RFC-OAS-019's responsibility. masc-mcp consumes whatever the SDK publishes.
- Promote `Eio.Fiber.with_binding` as a general OCaml/Eio idiom outside the keeper subsystem. Scope is `lib/keeper/` ↔ `lib/telemetry_eio.ml`.
- Rewrite the dashboard timeline framework. `vis-timeline` is already loaded by `fsm-hub-timeline-panels.ts` — reuse, don't replace.
- Add a new aggregation engine. Extend `tool_agent_timeline` 6-source merger by adding key branches; do not duplicate the merger.

## 4. Design

### 4.1 Envelope context propagation (receive side)

A fiber-local binding is installed at keeper turn start in `lib/keeper/keeper_agent_run.ml` (currently line 205-217 where the turn begins):

```ocaml
module Keeper_context = struct
  type t =
    { keeper_name : string
    ; keeper_turn_id : int
    ; agent_name : string option
    ; task_id : string option
    ; goal_id : string option
    ; oas_run_id : string option
    }

  let current_key : t Eio.Fiber.key = Eio.Fiber.create_key ()
end

let with_turn_context ~ctx fn =
  Eio.Fiber.with_binding Keeper_context.current_key ctx fn
```

`lib/telemetry_eio.ml` emit functions read the binding and stamp the envelope:

```ocaml
let stamp_envelope ~base_envelope =
  match Eio.Fiber.get Keeper_context.current_key with
  | None -> base_envelope
  | Some ctx ->
      { base_envelope with
        keeper_name   = Some ctx.keeper_name
      ; keeper_turn_id = Some ctx.keeper_turn_id
      ; agent_name    = base_envelope.agent_name |> coalesce ctx.agent_name
      ; task_id       = base_envelope.task_id    |> coalesce ctx.task_id
      ; goal_id       = base_envelope.goal_id    |> coalesce ctx.goal_id
      ; oas_run_id    = base_envelope.oas_run_id |> coalesce ctx.oas_run_id }
```

`coalesce` prefers the existing value if present (some payloads carry their own `agent_name`); the binding fills only the missing fields.

`lib/keeper/keeper_telemetry_consumer.ml` keeps its current "deliberately do not deserialize" stance for the payload body — only the envelope is stamped via the binding side. The consumer code itself does not change.

### 4.2 Run-index reverse map

`lib/keeper/keeper_runtime_manifest.ml` already appends per-turn at `dated_jsonl_today_path` (line 324). One additional line per turn is appended to a parallel file `.masc/run-index/<YYYY-MM>/<DD>.jsonl`:

```json
{ "oas_run_id": "172e8-651bc21c3b8e5-b77"
, "keeper_turn_id": 42
, "keeper_name": "qa_king"
, "goal_id": "...|null"
, "started_at": 1778718322.440422
, "ended_at":   1778718398.119003
}
```

Forward-only. Existing records before deploy stay un-indexed and are accepted as a known gap by the pivot API (returns "before-index" sentinel for unmatched `oas_run_id`).

Schema validator: `scripts/procedural-memory/validate-run-index.sh` follows the existing `validate-evidence-record.sh` pattern — `jq`-based required-field check, run in CI per PR that touches `lib/keeper/keeper_runtime_manifest.ml`.

### 4.3 Pivot API

`lib/telemetry_unified.mli` gains:

```ocaml
val read :
  ?keeper_name : string ->
  ?goal_id : string ->
  ?since : Ptime.t ->
  ?until : Ptime.t ->
  ?group_by : [ `Turn | `Flat ] ->
  store -> grouped_result
```

`lib/tool_agent_timeline.ml` adds branches:

- when `keeper_name` is set, scan `.masc/run-index/` for matching `keeper_turn_id`s, then merge the 6 sources keyed on those turn ids.
- when `goal_id` is set, scan run-index for matching `goal_id`, then same merger.
- when `group_by = `Turn`, the merger output is post-grouped by `keeper_turn_id` with a chronological header per group.

Two HTTP routes mirror the `lib/dashboard_cascade.ml` shape:

- `lib/dashboard_keeper_timeline.ml` → `GET /api/v1/keeper/:name/timeline`
- `lib/dashboard_goal_timeline.ml` → `GET /api/v1/goal/:id/timeline`

Query params: `?since=<rfc3339>`, `?until=<rfc3339>`, `?group_by=turn|flat`. Default `group_by=turn`.

### 4.4 Pivot UI

A single component `dashboard/src/components/keeper-timeline.ts`:

- props: `{ source: { kind: 'keeper'; name: string } | { kind: 'goal'; id: string }; since?: Date; until?: Date }`.
- internal signal `layoutMode: 'vertical' | 'horizontal'`. Default: `vertical`.
- Data fetch via `useQuery` (no `useEffect`, per CLAUDE.md §react).
- `vertical` rendering: turn header (collapsible) → chronological child events (tool_call, stream_summary, board_post). Reuses the visual pattern of `agent-detail-timeline.ts`.
- `horizontal` rendering: `vis-timeline` (already a dashboard dep via `fsm-hub-timeline-panels.ts`), one lane per `keeper_turn_id`, each event as an item on its lane.

Mount points:

- `dashboard/src/components/keeper-detail-state.ts`: replace the existing trajectory-timeline slot.
- `dashboard/src/components/goals/goal-tree.ts`: add a new "Timeline" tab in the detail panel.

## 5. Migration

### 5.1 Additive surface

- New routes, new file family `.masc/run-index/`, new envelope fields: all additive. Existing consumers that ignore unknown fields continue to work.

### 5.2 Coupling to RFC-OAS-019

If RFC-OAS-019 ships before RFC-0081, the pivot UI shows the typed `Streaming_summary` records grouped by turn — best case.

If RFC-0081 ships first, the pivot UI groups raw `Streaming_chunk_n` records (still hundreds per attempt). The grouping is correct but each turn balloons. This is operationally usable (filter by `payload[0] == "Streaming_summary"` once RFC-OAS-019 lands) and not a regression versus today.

If RFC-0081 ships and RFC-OAS-019 stalls, masc-mcp does *not* take on receive-side aggregation as a workaround. CLAUDE.md §Workaround Rejection Bar §1 (telemetry-as-fix). Wait for upstream.

### 5.3 Cross-RFC interlock

| RFC | Interaction |
|---|---|
| RFC-OAS-019 (oas) | Upstream emission shape. Pivot UI gains clarity once `Streaming_summary` is emitted, but RFC-0081 does not block on RFC-OAS-019 merge. |
| RFC-0046 (masc-mcp) | Same `keeper-detail-state.ts` slot layout. Sync with RFC-0046 author before Phase 2 frontend merge: timeline above/below FsmHub. |
| RFC-0063 (masc-mcp) | Same consumer fiber. RFC-0063's drain-yield contract is preserved; envelope stamping is a stateless per-record operation that does not change drain cadence. |
| RFC-0049 (masc-mcp) | Surface telemetry foundation; envelope stamping is a foundation-layer addition. |

## 6. Verification

### Gate 1 — Envelope context (Phase 1)

1. `jq 'select(.turn == null or .keeper_name == null) | length' .masc/telemetry/<…>.jsonl` < 10% of total records on a post-deploy day (10% allows for pre-binding emission paths and known boundary cases).
2. `.masc/run-index/<YYYY-MM>/<DD>.jsonl`: one line per `keeper_turn_id` from `keeper_runtime_manifest`. No duplicates, no gaps in `keeper_turn_id` sequence.
3. `bash scripts/procedural-memory/validate-run-index.sh .masc/run-index/<…>.jsonl` exits 0.
4. RFC-0063 boot-hang regression unchanged: server boot reaches `phase=ready` within 5s; CPU < 20% at idle.

### Gate 2 — Pivot API (Phase 2 backend)

1. `curl localhost:8935/api/v1/keeper/<name>/timeline?since=1h | jq '.groups | length' > 0`.
2. `curl localhost:8935/api/v1/goal/<id>/timeline | jq '.groups[0].events[0].kind'` returns a known event kind.
3. Unmatched `oas_run_id` returns a `"before-index"` group marker rather than silently dropping events.

### Gate 3 — Pivot UI (Phase 2 frontend)

1. Dashboard keeper-detail: `layoutMode` toggle round-trip between `vertical` and `horizontal` preserves the visible event set.
2. Goal-detail: new Timeline tab renders the same `keeper_turn_id` group for goals attached to a test turn.
3. Lighthouse: no useEffect introduced (TS lint catches via existing rule, if present).

## 7. Rollout

| Phase | PR scope | Gate |
|---|---|---|
| 0 | This RFC | review + merge |
| 1 | Envelope context + run-index + schema validator | Gate 1 |
| 2a | Pivot API (`telemetry_unified.mli` filter, `tool_agent_timeline.ml` branches, 2 routes) | Gate 2 |
| 2b | Pivot UI (`keeper-timeline.ts`, mounts) | Gate 3 |

Each PR remains Draft until its gate passes. PR body cites this RFC by number and section.

## 8. Risks & alternatives

### 8.1 Risk — fiber-local binding leakage into sibling fibers

`Eio.Fiber.with_binding` is lexically scoped; sibling fibers spawned *outside* the scope inherit `None`. Risk is *inherited binding into background fibers spawned inside the turn scope* (e.g., a long-lived sampler that outlives the turn). Mitigation: §6 Gate 1 #1 tolerates 10% null records; sampler fibers must explicitly clear context via `Eio.Fiber.with_binding ... None` if they outlive turn semantics. Test for this in Phase 1.

### 8.2 Risk — run-index growth

One line per keeper turn. Estimated at ~10 KB/day per active keeper, ~MB/month per fleet of 16 keepers. Negligible at masc-mcp scale; revisit if keeper count grows 10×.

### 8.3 Alternative — global mutable registry for keeper context

Rejected. Global mutable state is the exact dict/map global registry CLAUDE.md §AI 코드 생성 안티패턴 §3 (boundary violation) calls out. Fiber-local binding is the OCaml/Eio idiom for request-scoped context.

### 8.4 Alternative — derive turn from `oas_run_id` at read time without an index

Rejected on cost. Every read query would have to scan `keeper_runtime_manifest` files across the date range to resolve `oas_run_id → keeper_turn_id`. Index lookup is O(1) per record; scan is O(records × turns). Index is the structural fix.

### 8.5 Alternative — push aggregation to dashboard read layer

Rejected. The current dashboard `useEffect`-free pattern relies on `useQuery` over typed API responses. Pushing grouping into the frontend forces every consumer (CLI, future scripts, ad-hoc queries) to re-implement the grouping logic. Backend grouping is the SSOT.

## 9. Open items

- Sync with RFC-0046 author on `keeper-detail-state.ts` slot layout (timeline above/below FsmHub) before Phase 2b.
- Decide whether `Timeline` tab in `goal-tree.ts` is the only mount or if a "fleet timeline" view is wanted later (defer).
- Backfill policy for `.masc/run-index/` (forward-only proposed; backfill from existing manifest files is a follow-up if operators ask).
