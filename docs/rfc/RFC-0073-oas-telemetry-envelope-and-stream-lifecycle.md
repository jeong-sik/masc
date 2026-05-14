---
rfc: "0073"
title: "OAS Telemetry Envelope Context & Stream Lifecycle Aggregation"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0046", "0049", "0063"]
implementation_prs: []
---

# RFC-0073 — OAS Telemetry Envelope Context & Stream Lifecycle Aggregation

- **Status**: Draft
- **Author**: vincent (yousleepwhen)
- **Created**: 2026-05-14
- **Related**: RFC-0046 (keeper detail FSM Hub SSOT — same UI surface), RFC-0063 (telemetry feedback loop — same OAS path, complementary), RFC-0049 (surface telemetry foundation), RFC-OAS-011 (cdal_runtime telemetry adjacency)

## 1. Problem

Two operator-facing defects in `.masc/telemetry/YYYY-MM/DD.jsonl` make `oas:telemetry_event` records hard to read and impossible to pivot by keeper or goal.

### 1.1 Per-chunk noise

A single cascade attempt produces **one telemetry_event line per streaming chunk** (observed `chunk_index: 314` on a single attempt). The payload carries only `provider`, `model`, `chunk_index`, `inter_chunk_ms`:

```json
{
  "type": "oas:telemetry_event",
  "ts_unix": 1778718322.440422,
  "correlation_id": "172e8-651bc21c3b8e5-b76",
  "run_id": "172e8-651bc21c3b8e5-b77",
  "agent_name": null, "task_id": null, "turn": null,
  "payload": ["Streaming_chunk_n",
              {"provider":"openai_compat","model":"glm-5.1",
               "chunk_index":314,"inter_chunk_ms":0.134}]
}
```

These records were intended for prometheus histogram observations (`metric_cascade_inter_chunk_seconds`), but the JSONL sink writes every one of them verbatim, producing hundreds of indistinguishable lines per attempt and burying everything else.

### 1.2 Envelope context null

In the same record `agent_name`, `task_id`, and `turn` are `null`. `keeper_telemetry_consumer.ml` deliberately skips deserialization of the `Custom("telemetry_event", json)` payload (counter-only path), so the envelope fields that *should* identify the originating keeper turn never get stamped. Operators cannot answer: "which keeper, which turn, which goal emitted this stream?"

### 1.3 Pivot impossibility

There is no `(keeper_name | goal_id) → ordered events` query path. `tool_agent_timeline` is a 6-source merger keyed only on `agent_name`; `telemetry_unified` exposes no `keeper_name` / `goal_id` filter. The dashboard `keeper-detail-state.ts` mounts a trajectory-timeline but the backend it talks to has no turn-grouped event endpoint. Goal detail (`goals/goal-tree.ts`) has no timeline tab at all.

## 2. Goal

1. **Sink separation** — JSONL sink emits *typed lifecycle summaries*, not per-chunk records. Prometheus histogram path keeps per-chunk observations unchanged.
2. **Envelope stamping** — every `oas:telemetry_event` written while a keeper turn is on the fiber stack carries `keeper_name`, `keeper_turn_id`, `agent_name`, `task_id`, `goal_id`, `oas_run_id`.
3. **Pivot API** — `GET /api/v1/keeper/:name/timeline` and `GET /api/v1/goal/:id/timeline` return events grouped by keeper turn, reusing the existing 6-source merger.
4. **Pivot UI** — a single `keeper-timeline.ts` component renders the API output as either a vertical collapsible list (turn → events) or a horizontal `vis-timeline` swimlane (one lane per turn), switched by a `layoutMode` signal.

## 3. Non-goals

- Rewriting the cascade FSM (`cascade_attempt_liveness.ml`). Chunk kind taxonomy stays.
- Changing prometheus metrics. `metric_cascade_inter_chunk_seconds` continues to receive every chunk's `inter_chunk_ms`.
- Adding a new aggregation framework. The existing `tool_agent_timeline` 6-source merger is extended, not replaced.
- Promoting fiber-local context to a general OCaml/Eio idiom outside the keeper subsystem. Scope is the `lib/keeper/` ↔ `lib/telemetry_eio.ml` boundary.

## 4. Design

### 4.1 Stream lifecycle summary (Track A)

`cascade_attempt_liveness_observer.ml` already calls `record_ttft`/`record_inter_chunk` per chunk and has a `finalize()` exit. The per-chunk OAS `Custom("telemetry_event", …)` emission is **removed**. `finalize()` emits one new payload variant:

```ocaml
| Stream_summary of {
    provider          : string;
    model             : string;
    chunk_count       : int;
    kind_breakdown    : { thinking : int; answer : int;
                          tool_call_start : int; tool_call_arg_delta : int;
                          tool_call_complete : int;
                          substrate : int; heartbeat : int; done_ : int };
    ttft_ms           : float option;
    total_ms          : float;
    inter_chunk_ms_p50 : float;
    inter_chunk_ms_p95 : float;
    inter_chunk_ms_max : float;
    terminal          : [ `Done | `Cancelled | `Error of string ];
  }
```

Prometheus observations continue at the per-chunk hook (unchanged code path); the OAS emit at that hook is the only thing deleted.

**Why a typed record, not a string-keyed map**: CLAUDE.md §software-development §1 (scattered hardcoded defaults) and §2 (unknown→permissive default). A record forces every new kind to surface in `kind_breakdown` at compile time.

### 4.2 Envelope context propagation (Track B)

A fiber-local binding `Keeper_context.current : context option ref` is installed at keeper turn start in `keeper_agent_run.ml`:

```ocaml
let with_turn_context ~keeper_name ~keeper_turn_id ~agent_name
                     ~task_id ~goal_id ~oas_run_id fn =
  let ctx = { keeper_name; keeper_turn_id; agent_name; task_id;
              goal_id; oas_run_id } in
  Eio.Fiber.with_binding Keeper_context.current_key ctx fn
```

`telemetry_eio.ml` emit functions read the binding and stamp the envelope. Absent binding → fields stay `null` (additive, no regression).

A reverse index file is appended at turn end:

```
.masc/run-index/<YYYY-MM>/<DD>.jsonl
  { "oas_run_id": "...", "keeper_turn_id": 42, "keeper_name": "qa_king",
    "goal_id": "...", "started_at": ..., "ended_at": ... }
```

`keeper_runtime_manifest.ml` already appends per-turn; the new write is one extra line in the same finalize path. The index is the bridge for old records (pre-stamping) and for cross-run pivots.

### 4.3 Pivot timeline API (Track C, backend)

`telemetry_unified.mli` gains optional filters:

```ocaml
val read :
  ?keeper_name:string -> ?goal_id:string ->
  ?since:Ptime.t -> ?until:Ptime.t ->
  ?group_by:[ `Turn | `Flat ] ->
  store -> grouped_result
```

`tool_agent_timeline.ml` adds keeper/goal branches using the run-index for `oas_run_id → keeper_turn_id` lookup. Two new HTTP routes mirror the `dashboard_cascade.ml` pattern.

### 4.4 Pivot timeline UI (Track C, frontend)

A single component `keeper-timeline.ts` exposes a `layoutMode: 'vertical' | 'horizontal'` signal:

- `vertical`: turn header (collapsible) → child events (tool_call, stream_summary, board_post) sorted by `ts`.
- `horizontal`: `vis-timeline` (already a dashboard dependency via `fsm-hub-timeline-panels.ts`), one lane per turn, events as items.

Mounted in `keeper-detail-state.ts` (replaces the existing trajectory-timeline slot) and `goals/goal-tree.ts` detail tab. Data fetch via `useQuery`/`useSuspenseQuery` (no `useEffect`, per CLAUDE.md §react).

## 5. Migration & compatibility

### 5.1 Removed surface (breaking)

- `oas:telemetry_event` payload variant `Streaming_chunk_n` in `.masc/telemetry/*.jsonl` **disappears** at Track A merge.
- Consumer sweep (must run before Track A merge): `rg 'Streaming_chunk_n' tools/ scripts/ dashboard/src/` to enumerate parsers that need a one-line ignore/skip.
- Prometheus consumers are unaffected (histogram label set unchanged).

### 5.2 Additive surface

- New variant `Stream_summary` (Track A).
- New envelope fields populated (Track B; null-tolerant readers unchanged).
- New routes `/api/v1/keeper/:name/timeline`, `/api/v1/goal/:id/timeline` (Track C).
- New file family `.masc/run-index/<YYYY-MM>/<DD>.jsonl` (Track B).

### 5.3 Cross-RFC interlock

| RFC | Interaction |
|---|---|
| RFC-0046 | Same UI surface (keeper-detail). RFC-0046's FsmHub SSOT mount and RFC-0073's `keeper-timeline.ts` mount sit side-by-side in `keeper-detail-state.ts`. Track C PR cites RFC-0046 layout before adding the timeline slot. |
| RFC-0063 | Same OAS path. RFC-0063 codifies the *drain-yield contract* for telemetry consumers; RFC-0073 changes *what is emitted into that drain*. Track A merge re-runs the boot-hang regression test from RFC-0063 §2 since `Stream_summary` is lower-volume than per-chunk and shifts drain cadence. |
| RFC-0049 | Surface telemetry foundation; RFC-0073's typed `Stream_summary` is a foundation-layer addition. |
| RFC-OAS-011 | `cdal_runtime` sits adjacent; verify `lib/cdal_runtime/dune` does not need a new `libraries` entry when `Stream_summary` variant is added to `telemetry_eio`. |

## 6. Verification gates

Each phase merges independently only if its gate passes.

### Gate A (Stream lifecycle, Track A)

1. `dune exec test/test_cascade_attempt_liveness_observer.exe` — `finalize()` emits exactly one `Stream_summary`, `sum(kind_breakdown.*) = chunk_count`.
2. Live keeper turn: `jq 'select(.payload[0] == "Streaming_chunk_n")' .masc/telemetry/<…>.jsonl | wc -l` returns `0`.
3. Same turn: `curl :9090/metrics | grep masc_cascade_inter_chunk_seconds_count` increment matches chunk_count (histogram retained).
4. RFC-0063 boot-hang regression: server boot reaches `phase=ready` within 5s under cooperative scheduling.

### Gate B (Envelope context, Track B)

1. `jq 'select(.turn == null or .keeper_name == null) | length' .masc/telemetry/<…>.jsonl` < 10% of total records on a post-deploy day (allow 10% for pre-binding emission paths).
2. `.masc/run-index/<YYYY-MM>/<DD>.jsonl`: one line per `keeper_turn_id` (no duplicates, no gaps relative to `keeper_runtime_manifest`).
3. Schema validator: `bash scripts/procedural-memory/validate-run-index.sh .masc/run-index/<…>.jsonl` exits 0.

### Gate C (Pivot API+UI, Track C)

1. `curl localhost:8935/api/v1/keeper/<name>/timeline?since=1h | jq '.groups | length' > 0`.
2. `curl localhost:8935/api/v1/goal/<id>/timeline | jq '.groups[0].events[0].kind'` returns a known event kind.
3. Dashboard keeper-detail: `layoutMode` toggle round-trip between `vertical` and `horizontal` preserves visible events.
4. Goal-detail: new timeline tab renders the same group for goals attached to the test turn.

## 7. Rollout

| Phase | PR scope | Gate |
|---|---|---|
| 0 | This RFC | review + merge |
| 1 | Track A (cascade observer + telemetry_eio variant + tests) | Gate A |
| 2 | Track B (fiber-local context + run-index + schema validator) | Gate B |
| 3 | Track C-backend (telemetry_unified filters + tool_agent_timeline branches + 2 routes) | Gate C #1, #2 |
| 4 | Track C-frontend (keeper-timeline.ts + mounts) | Gate C #3, #4 |

Each PR remains Draft until its gate passes. PR body cites this RFC by number and section.

## 8. Risks & alternatives

### 8.1 Risk — fiber-local binding leakage

If `Keeper_context` is read in a fiber spawned outside `with_turn_context`, the read returns `None` (safe — fields stay null). Risk is *over-population* via inherited binding into long-lived fibers (e.g., a background sampler). Mitigation: `Eio.Fiber.with_binding` is lexically scoped; the binding does not propagate to fibers spawned outside the scope. Track B PR adds a test that spawns a sibling fiber and asserts `Keeper_context.current = None`.

### 8.2 Alternative — keep per-chunk records, add summary alongside

Rejected. CLAUDE.md §workaround rejection bar §1 (telemetry-as-fix): adding the summary without removing the noise turns the summary into *just another counter the operator must filter past*. Sink separation (JSONL = typed summary, prometheus = raw histogram) is the structural fix.

### 8.3 Alternative — global registry for keeper context

Rejected. Global mutable state is exactly the kind of dict/map routing CLAUDE.md §software-development §AI 코드 생성 안티패턴 #3 (boundary violation) calls out. Fiber-local binding is the OCaml/Eio idiom for request-scoped context.

### 8.4 Risk — RFC-0046 and RFC-0073 race on keeper-detail layout

Both RFCs add UI to `keeper-detail-state.ts`. Mitigation: Track C-frontend PR is blocked until RFC-0046 either (a) merges its FsmHub mount, or (b) explicitly cedes the timeline slot. Cross-link in this RFC §5.3.

## 9. Open items

- RFC-0046 owner sync on `keeper-detail-state.ts` slot layout (timeline above/below FsmHub).
- Whether `Stream_summary` should also carry `cost_usd_estimate` (depends on cascade cost accounting RFC status — defer).
- Whether `.masc/run-index/` should be backfilled from existing `keeper_runtime_manifest` files at deploy time, or only forward-only (forward-only proposed, backfill is a follow-up).
