---
rfc: "0081"
title: "OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline"
status: Draft
created: 2026-05-14
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0046", "0049", "0063"]
implementation_prs: [15137]
---

# RFC-0081 — OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline

- **Status**: Draft
- **Author**: vincent (yousleepwhen)
- **Created**: 2026-05-14
- **Related**: RFC-0046 (keeper detail FSM Hub SSOT — same UI surface), RFC-0049 (surface telemetry foundation), RFC-0063 (telemetry feedback loop — same consumer fiber), **RFC-OAS-019** (upstream stream lifecycle aggregation in `agent_sdk`)
- **Supersedes**: closed PR #15128 (RFC-0073) — same operator-facing goal but mis-located the emission source inside masc-mcp; RFC-0081 carves the work into the correct boundary (developer: `agent_sdk` for emission via RFC-OAS-019, masc-mcp for envelope context and pivot UI here)

## 0. Summary

Two operator-facing defects in masc-mcp's telemetry view of OAS streams are addressed here. Per-chunk noise — the third defect originally bundled in the closed RFC-0073 — is the upstream `agent_sdk` repo's emission surface and is now scoped under **RFC-OAS-019** in `~/me/workspace/yousleepwhen/oas`.

1. **Envelope context null** — every `oas:telemetry_event` record written to `.masc/oas-events/YYYY-MM/DD.jsonl` (the durable OAS-event store; see `lib/telemetry_unified.ml:105` and `lib/cascade/cascade_event_bridge.ml:1086`) has `agent_name`, `task_id`, `turn` as `null`. Operators cannot answer "which keeper, which turn, which goal produced this record?" from the raw jsonl alone.

2. **Pivot impossibility** — there is no `(keeper_name | goal_id) → ordered events` query path. `tool_agent_timeline` (6-source merger) is keyed on `agent_name` only; `telemetry_unified` exposes no keeper/goal filter; the dashboard `keeper-detail-state.ts` mounts a trajectory slot but the backend it talks to has no turn-grouped event endpoint. Goal detail has no timeline tab.

This RFC fixes both at the **read boundary**, not the write boundary. The relay code in `cascade_event_bridge.ml` is unchanged. Three rounds of design (fiber-local binding → shared Hashtbl → read-time join) plus three rounds of grep verification settled on read-time as the structural fit: agent_sdk's `event_envelope` does not carry a turn-level identifier (per-event `fresh_id ()` defaults at `oas/lib/event_envelope.ml:55-57`), so any write-time stamping mechanism would race or fail. The fix instead extends `keeper_runtime_manifest` with three timestamp/id fields and lets `telemetry_unified` perform a time-overlap join at API read time. The user-visible artifacts (pivot UI, pivot API) deliver the same stamped events; only the inside of the system is simpler.

The emission-side change (per-chunk noise) is RFC-OAS-019's responsibility.

## 1. Cross-repo boundary (why this RFC exists separately)

`agent_sdk` is consumed via opam pin `git+https://github.com/jeong-sik/oas.git#<sha>` (`dune-project` line 44: `(agent_sdk (>= 0.193.10))`). The `Streaming_chunk_n` payload variant lives in `lib/llm_provider/telemetry_event.ml:20-24` of the `oas` repo, not in masc-mcp. masc-mcp receives `Event_bus.Custom("telemetry_event", json)` payloads via the upstream SDK, filters them in `keeper_telemetry_consumer.ml` (counter-only, no deserialization), and relays them to a dated JSONL store at `lib/cascade/cascade_event_bridge.ml:1086` under `.masc/oas-events/<YYYY-MM>/<DD>.jsonl`. (Earlier drafts of this RFC referenced `lib/telemetry_eio.ml:114` for this surface; that path is the *agent_event* surface, `.masc/telemetry/`, with a different typed event set — corrected here after grep verification.)

| Concern | Owner repo | RFC |
|---|---|---|
| Per-chunk emission → lifecycle summary | `oas` (`agent_sdk`) | **RFC-OAS-019** |
| Turn boundary index in `keeper_runtime_manifest` | `masc-mcp` | This RFC §4.2 |
| Read-time join (oas-events ⨝ manifest) | `masc-mcp` | This RFC §4.1, §4.3 |
| Pivot API + UI | `masc-mcp` | This RFC §4.3–4.4 |

Mixing the two would break the SDK Independence Gate that `oas` enforces on Ready (per `~/me/memory/reference_oas_pr_policy_vs_masc_mcp.md`). This RFC names no `oas` internal identifiers in `lib/`; it only consumes the public `Telemetry_event` variants as published by `agent_sdk` ≥ 0.194.0 (RFC-OAS-019's target version).

## 2. Goal

1. **Turn boundary index** — extend `keeper_runtime_manifest` rows with `turn_started_at`, `turn_ended_at`, and `correlation_id_first`. Forward-only; pre-deploy rows stay un-indexed.
2. **Read-time join** — `telemetry_unified` joins `.masc/oas-events/` rows to manifest turns by time-overlap, with `correlation_id` prefix as a tie-breaker. The result is *stamped* records carrying `keeper_name`, `keeper_turn_id`, `agent_name`, `task_id`, `goal_id` — assembled at the API boundary rather than baked into jsonl.
3. **Pivot API** — `GET /api/v1/keeper/:name/timeline` and `GET /api/v1/goal/:id/timeline` return events grouped by `keeper_turn_id`, reusing the existing `tool_agent_timeline` 6-source merger plus the new join.
4. **Pivot UI** — single `keeper-timeline.ts` component renders the API output as either a vertical collapsible list (turn → events) or a horizontal `vis-timeline` swimlane, switched by a `layoutMode` signal.

## 3. Non-goals

- Modify `cascade_event_bridge.ml` or anything else on the write side. The relay path remains unchanged.
- Re-emit, throttle, or deduplicate any upstream `oas:telemetry_event` payload. The bus contents are RFC-OAS-019's responsibility. masc-mcp consumes whatever the SDK publishes.
- Stamp envelope fields directly into `.masc/oas-events/` jsonl. Three rounds of grep verification showed write-time stamping does not fit OAS event-envelope semantics; the read-time join is the structural fix.
- Rewrite the dashboard timeline framework. `vis-timeline` is already loaded by `fsm-hub-timeline-panels.ts` — reuse, don't replace.
- Add a new aggregation engine. Extend `tool_agent_timeline` 6-source merger by adding key branches; do not duplicate the merger.

## 4. Design

### 4.1 Envelope reconciliation at read time

After three rounds of grep verification this RFC settled on a *read-time join* rather than write-time stamping. The earlier two drafts of §4.1 (closed PR #15128 RFC-0073: fiber-local binding; this PR's first revision: explicit shared map) both failed against OAS event-envelope semantics:

| Round | Mechanism | Blocked because |
|---|---|---|
| 1 | `Eio.Fiber.with_binding` lookup in `wrap_event` | relay runs in a *background fiber* (`cascade_event_bridge.ml:1082` `start_impl`), so keeper-turn-local bindings do not propagate to it |
| 2 | Shared `Keeper_context` Hashtbl keyed on `oas_run_id`, registered at keeper turn start | OAS `event_envelope.ml:55-57` defaults `correlation_id` and `run_id` to `fresh_id ()` *per event*; agent_sdk does not guarantee a turn-level identifier in published envelopes. A keeper-side `register oas_run_id` has no stable id to register under |
| 3 (chosen) | Read-time join — no write-side change | works without assuming a propagated id; relies only on data that already exists in `keeper_runtime_manifest` and the OAS-event `ts_unix` |

`lib/cascade/cascade_event_bridge.ml` is **unchanged**. `.masc/oas-events/<YYYY-MM>/<DD>.jsonl` continues to be written with `agent_name`/`task_id`/`turn` null when the OAS publisher did not supply them. Stamping happens at read time, not write time.

At read time, `lib/telemetry_unified.ml` and `lib/tool_agent_timeline.ml` join each `.masc/oas-events/` row to the turn that owns it. The join is in two stages:

1. **Time-overlap match** (primary). The row's `ts_unix` is checked against `keeper_runtime_manifest` (§4.2) turn windows `[turn_started_at, turn_ended_at]`. Each row belongs to the unique turn whose window contains its `ts_unix`. If no window contains the row (pre-deploy data, ungoverned bus events), the row is grouped under a sentinel `"unscoped"` bucket.
2. **Id-prefix match** (fallback, optional). When multiple turns overlap the same wall-clock instant (concurrent keepers), the manifest also records `correlation_id_first` — the first OAS envelope id observed *during* the turn. Rows whose `correlation_id` shares the same provider-side prefix (an `evt-<pid>-<us_hex>-<n>` pattern, see `oas/lib/event_envelope.ml:24`) can be disambiguated by matching the prefix. This is a refinement; time-overlap alone resolves the common case.

The result is the same envelope shape an in-jsonl stamp would produce, but assembled at the API boundary:

```ocaml
type stamped_event =
  { (* ...all original envelope/payload fields... *)
    keeper_name : string option       (* filled from manifest *)
  ; keeper_turn_id : int option        (* filled from manifest *)
  ; agent_name : string option         (* coalesce: original-or-manifest *)
  ; task_id : string option
  ; goal_id : string option
  }
```

`lib/keeper/keeper_telemetry_consumer.ml` keeps its current "deliberately do not deserialize" stance — it remains a counter-only path.

**Why this works for the operator UX**: the user-visible artifact is the *pivot UI* (§4.4) and the *pivot API* (§4.3). A consumer reading either of those sees stamped events regardless of whether the stamp was baked into jsonl or assembled at the read boundary. Raw `.masc/oas-events/` inspection (`jq` on jsonl) loses keeper context, but that path is for debugging and a one-line `bash` helper can apply the same join when needed.

### 4.2 Turn index for read-time join

`lib/keeper/keeper_runtime_manifest.ml` already records per-turn rows at `dated_jsonl_today_path` (line 324). Phase 1 augments those rows with the four fields the read-time join needs, *all already known at turn end*:

| Field | Source | Use |
|---|---|---|
| `turn_started_at` (float, unix s) | `Time_compat.now ()` at turn entry | lower bound of the window |
| `turn_ended_at` (float, unix s) | `Time_compat.now ()` at turn finalize | upper bound; written on success, abort, or timeout |
| `correlation_id_first` (string option) | first OAS envelope `correlation_id` observed during the turn (recorded via `cascade_event_bridge` log hook or `Agent_sdk.Event_bus` callback) | disambiguator when multiple keepers overlap |
| `task_id` / `goal_id` / `agent_name` | already on the manifest row | join's output payload |

No new file family is created — the manifest is the lookup table. This is a deliberate retraction from the second draft, which proposed a parallel `.masc/run-index/` file. The manifest already carries `keeper_name`, `keeper_turn_id`, and `task_id` (per `keeper_runtime_manifest.ml:204` `runtime_manifest_context`); adding two timestamps and one optional id is `~3 LoC` of struct extension plus a write-time `Time_compat.now ()` at the finalize site.

Forward-only. Manifest rows that lack the new fields (pre-deploy) are treated as before-index by the join and contribute rows to the `"unscoped"` bucket only. Schema validator: a new `scripts/procedural-memory/validate-run-index.sh` extension validates the additional fields on rows written after the Phase 1 deploy.

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

- when `keeper_name` is set, scan `keeper_runtime_manifest` (§4.2) for matching turns, then merge the 6 sources keyed on those turn ids. `.masc/oas-events/` rows are joined to turns by the time-overlap algorithm in §4.1 (each row's `ts_unix` falls inside a `[turn_started_at, turn_ended_at]` window).
- when `goal_id` is set, scan the manifest for turns with matching `goal_id`, then same merger + time-overlap join.
- when `group_by = `Turn`, the merger output is post-grouped by `keeper_turn_id` with a chronological header per group. Rows that did not match any turn window go to a `"unscoped"` sentinel group at the tail.

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

- New routes, manifest field extension (`turn_started_at`, `turn_ended_at`, `correlation_id_first`), new envelope fields: all additive. No new file family — §4.2 retracted the parallel `.masc/run-index/` design in favor of manifest-only indexing. Existing consumers that ignore unknown fields continue to work.

### 5.2 Coupling to RFC-OAS-019

If RFC-OAS-019 ships before RFC-0081, the pivot UI shows the typed `Streaming_summary` records grouped by turn — best case.

If RFC-0081 ships first, the pivot UI groups raw `Streaming_chunk_n` records (still hundreds per attempt). The grouping is correct but each turn balloons. This is operationally usable (filter by `payload[0] == "Streaming_summary"` once RFC-OAS-019 lands) and not a regression versus today.

If RFC-0081 ships and RFC-OAS-019 stalls, masc-mcp does *not* take on receive-side aggregation as a workaround. CLAUDE.md §Workaround Rejection Bar §1 (telemetry-as-fix). Wait for upstream.

### 5.3 Cross-RFC interlock

| RFC | Interaction |
|---|---|
| RFC-OAS-019 (oas) | Upstream emission shape. Pivot UI gains clarity once `Streaming_summary` is emitted, but RFC-0081 does not block on RFC-OAS-019 merge. |
| RFC-0046 (masc-mcp) | Same `keeper-detail-state.ts` slot layout. Sync with RFC-0046 author before Phase 2 frontend merge: timeline above/below FsmHub. |
| RFC-0063 (masc-mcp) | Same consumer fiber. RFC-0063's drain-yield contract is preserved without modification — read-time join is on the API path, not the consumer fiber. |
| RFC-0049 (masc-mcp) | Surface telemetry foundation; the manifest-field extension is a foundation-layer additive change. |

## 6. Verification

### Gate 1 — Turn index extension (Phase 1)

1. `keeper_runtime_manifest` rows written after the Phase 1 deploy carry `turn_started_at`, `turn_ended_at`, and `correlation_id_first`. Verify with `jq 'select(.turn_started_at == null)' <manifest.jsonl> | wc -l` returning 0 for new rows.
2. `bash scripts/procedural-memory/validate-run-index.sh <manifest.jsonl>` exits 0.
3. RFC-0063 boot-hang regression unchanged: server boot reaches `phase=ready` within 5s; CPU < 20% at idle.

### Gate 2 — Pivot API (Phase 2 backend)

1. `curl localhost:8935/api/v1/keeper/<name>/timeline?since=1h | jq -e '.groups | length > 0'`.
2. `curl localhost:8935/api/v1/goal/<id>/timeline | jq '.groups[0].events[0].kind'` returns a known event kind.
3. Time-overlap join: a synthetic `keeper_runtime_manifest` row with a known `[turn_started_at, turn_ended_at]` window plus 5 `.masc/oas-events/` rows whose `ts_unix` fall inside the window produce a `groups` array of length 1 with 5 events under the expected `keeper_turn_id`.
4. Unscoped bucket: a `.masc/oas-events/` row outside any turn window is returned under the `"unscoped"` sentinel group, not silently dropped.

### Gate 3 — Pivot UI (Phase 2 frontend)

1. Dashboard keeper-detail: `layoutMode` toggle round-trip between `vertical` and `horizontal` preserves the visible event set.
2. Goal-detail: new Timeline tab renders the same `keeper_turn_id` group for goals attached to a test turn.
3. Lighthouse: no useEffect introduced (TS lint catches via existing rule, if present).

## 7. Rollout

| Phase | PR scope | Gate |
|---|---|---|
| 0 | This RFC | review + merge |
| 1 | `keeper_runtime_manifest` row extension (3 new fields) + schema validator extension | Gate 1 |
| 2a | Pivot API (`telemetry_unified.mli` filter, `tool_agent_timeline.ml` time-overlap join, 2 routes) | Gate 2 |
| 2b | Pivot UI (`keeper-timeline.ts`, mounts) | Gate 3 |

Phase 1's footprint is now tiny — three optional fields on an existing record. Phase 2a carries the bulk of the read-time join logic. Phase 2b is the user-visible payoff.

Each PR remains Draft until its gate passes. PR body cites this RFC by number and section.

## 8. Risks & alternatives

### 8.1 Risk — time-overlap precision under concurrent keepers

Multiple keepers can have overlapping `[turn_started_at, turn_ended_at]` windows. A bus event whose `ts_unix` falls inside two windows simultaneously is ambiguous on time-overlap alone. Mitigation: §4.1 step 2 (id-prefix match) uses `correlation_id_first` to disambiguate. If the row's `correlation_id` does not match any concurrent turn's prefix it stays in the `"unscoped"` bucket — visible but unattributed. The fleet-wide rate of `"unscoped"` rows is observable via the pivot API and is the operational signal for when this approximation degrades.

### 8.2 Risk — unscoped bucket from pre-deploy data and ungoverned publishers

Manifest rows written before Phase 1 deploy lack the three new fields and contribute every overlapping bus event to `"unscoped"`. OAS publishers outside any keeper turn (boot-time, background fibers, agent_sdk's own retries) emit bus events with no owning turn at all. Both feed the `"unscoped"` bucket. This is *visible*, not silent — the UI surfaces the bucket with a count.

### 8.3 Risk — manifest row size growth

Three additional fields per row: `turn_started_at: float`, `turn_ended_at: float option`, `correlation_id_first: string option`. ~80 bytes per row, ~negligible vs the existing row payload. Not a concern at any plausible keeper count.

### 8.4 Alternative — fiber-local binding (rejected after grep)

Tried first. The oas-events relay is a *background fiber* (`cascade_event_bridge.ml:1082` `Eio.Fiber.fork ~sw` inside `start_impl`) subscribed to the OAS bus. `Eio.Fiber.with_binding` propagates only down the same fiber stack, so the relay never sees a binding installed in a keeper turn fiber.

### 8.5 Alternative — explicit shared map keyed on `oas_run_id` (rejected after grep)

Tried second. OAS `event_envelope.ml:55-57` defaults `correlation_id` and `run_id` to `fresh_id ()` *per event*. agent_sdk does not guarantee a turn-level identifier in published envelopes, so a keeper-side `register oas_run_id` has no stable id to register under. The keeper would have to scan published envelopes after emission to *learn* the id, which is exactly the read-time join — at which point the write-side machinery (Hashtbl + mutex + cleanup fiber) is pure overhead.

### 8.6 Alternative — derive turn by scanning every read without an index

Rejected on cost. Every read query would walk `keeper_runtime_manifest` for the entire date range to resolve which turn owns each bus event. The manifest itself is the index (after the §4.2 field extension); O(turns) lookups per query window rather than O(events × turns).

### 8.7 Alternative — push aggregation to the dashboard read layer

Rejected. The current dashboard `useEffect`-free pattern relies on `useQuery` over typed API responses. Pushing grouping into the frontend forces every consumer (CLI, future scripts, ad-hoc queries) to re-implement the grouping logic. Backend grouping is the SSOT.

### 8.8 Alternative — modify agent_sdk to carry a `keeper_owned_run_id` in the envelope

Deferred. The OAS publishers do not currently surface an external `client_correlation_id` field on `event_envelope.t`. Adding it would let masc-mcp pass a stable turn id at `Agent.run` invocation and re-enable write-time stamping. That is a separate OAS-side RFC and a coordination problem; the read-time join works without it. If the manifest-field approach proves insufficient over time, this alternative is the upgrade path — not the entry path.

## 9. Open items

- Sync with RFC-0046 author on `keeper-detail-state.ts` slot layout (timeline above/below FsmHub) before Phase 2b.
- Decide whether `Timeline` tab in `goal-tree.ts` is the only mount or if a "fleet timeline" view is wanted later (defer).
- Confirm the wiring point where `cascade_event_bridge` (or `keeper_telemetry_consumer`) can observe the first OAS envelope `correlation_id` per keeper turn so it can be persisted into `keeper_runtime_manifest` at finalize. If neither path can attribute "first correlation_id seen during turn X" without a back-channel from the relay to the keeper, the `correlation_id_first` field is dropped and §4.1 step 2 (id-prefix disambiguation) is dropped with it — time-overlap remains the sole join.
- If `"unscoped"` bucket size becomes a real operator pain (visible from the pivot API's `unscoped_count`), evaluate §8.8 (agent_sdk envelope extension) as the upgrade path.
