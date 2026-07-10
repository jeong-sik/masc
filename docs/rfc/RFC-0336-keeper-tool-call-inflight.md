# RFC-0336 — Keeper Tool-Call In-Flight Observation (G4 of the autonomous-background goal matrix)

- Status: Draft
- Date: 2026-07-10
- Scope: `lib/keeper` · `lib/server_keeper_waiting_inventory` · `lib/mcp_server_eio_execute`
- Depends on: G1–G3 of the keeper-autonomous-background goal matrix (merged; `lib/server_keeper_background.ml`)
- Supersedes: none. Phase 2 of the matrix; G5 (per-target poll) stays out of scope.

## Problem (audited)

The Phase 1 keeper-background surface (`lib/server_keeper_background.ml`, merged) projects
per-keeper **loop liveness** and **recurring** work, and reuses `Server_keeper_waiting_inventory`
for bg/fusion/HITL **deferred** work. What it cannot show is the most operator-relevant
autonomous signal: **which tool a keeper is running right now, since when, and whether it is
overrunning a deadline.**

Two audited facts make this a real gap, not a display polish:

1. **The `keeper_tool_call` SSE stream is completion-only.**
   `Keeper_tools_oas_handler_telemetry.broadcast_keeper_tool_call_event`
   (`lib/keeper/keeper_tools_oas_handler_telemetry.ml:65`) emits
   `{type:"keeper_tool_call"; duration_ms; success; …}` — i.e. it fires **after** the tool
   returns. There is no start-without-end signal, so an observer consuming this stream can
   never reconstruct "in-flight"; it can only see "just finished." An operator watching a
   keeper stuck on a slow tool sees nothing until the tool returns (or never, if it hangs).

2. **The typed tool-orchestration state machine exists but is dormant.**
   `lib/tool_orchestration/tool_event.mli:29` defines a full append-only lifecycle
   (`Job_scheduled → Job_started → Job_progress → Job_succeeded | Job_failed | Job_cancelled`)
   and `lib/tool_orchestration/tool_job.mli:18` carries `keeper_id`, `deadline_ms`,
   `resource_keys`, `approval`. But `rg "Tool_batch\.|Tool_event\.|Tool_job\." lib/` outside
   `tool_orchestration/` itself returns **zero** production callers. Keepers execute tools
   through `Mcp_server_eio_execute` (e.g. `lib/mcp_server_eio_execute.ml:351`), not through
   `Tool_batch`. So the "correct source set" the matrix names is defined but unwired.

Net: there is today no honest, per-tool-call in-flight observation. The dashboard would have
to either fabricate it (forbidden — matrix §5) or omit it (current state).

## Boundary and principles

1. **Observe real in-flight state; never fabricate.** No `bg_task` relabelled as a tool call,
   no ETA invented. (Matrix §5 workaround-rejection line; CLAUDE.md "워크어라운드 거부 기준".)
2. **ETA is honest.** A deadline exists only when the caller supplied one
   (`Tool_job.deadline_ms`, or an equivalent knob on the dispatch path). Without it the row
   carries `eta = None`, rendered "—". `started_at` + `deadline_ms` is the only ETA source.
3. **Additive, in-memory, no persistence.** In-flight state is ephemeral; it is not ledgered.
   The durable `tool_event` ledger stays a separate concern (Phase B).
4. **Surface through the existing read-model.** A new `Tool_call_inflight` variant on
   `Server_keeper_waiting_inventory.waiting_source` — same discipline G1–G3 used (reuse the
   join, do not build a parallel projection).
5. **Do not rewire all keeper tool execution through `Tool_batch` in this RFC.** That is a
   large blast-radius change with its own locking/approval/replay semantics; it is Phase B and
   gets its own RFC. This RFC delivers the observable layer with the minimum wiring that tells
   the truth.

## Proposal

Two layers: a **live registry** that owns the truth, and a **read-model join** that surfaces
it. Phase A (this RFC) wires the registry directly at the dispatch boundary; Phase B (later)
makes `tool_orchestration` the registry's upstream.

### Phase A — live registry fed at the dispatch boundary

**New module `lib/keeper/keeper_tool_inflight.{ml,mli}`** — an in-memory, per-keeper registry
of in-flight tool calls:

```
type entry = {
  keeper_name : string;
  tool_name   : string;
  job_id      : string;          (* correlates to keeper_tool_call completion *)
  started_at  : float;           (* unix seconds *)
  deadline_at : float option;    (* started_at + deadline_ms/1000, only if a deadline was supplied *)
}
val register   : keeper_name:string -> tool_name:string -> ?deadline_ms:int -> job_id:string -> unit -> entry
val unregister : job_id:string -> unit
val list       : keeper_name:string -> entry list
val all        : unit -> (string * entry list) list   (* keyed by keeper_name, for the read-model *)
```

- Concurrency: `Eio.Mutex.use_rw ~protect:true` around the internal table (in-process runtime;
  no cross-process need — each keeper lane is one process).
- `job_id` is generated at dispatch entry (UUID) and threaded into the existing
  `keeper_tool_call` completion event as `extra_fields` so start/end correlate. This is the
  only change to the SSE path — it gains a `job_id` field, still fires at completion.

**Wiring at the dispatch boundary** (`lib/mcp_server_eio_execute.ml`, the keeper tool-execution
entry; exact line pinned in implementation): wrap execution in `Fun.protect` —

```
let entry = Keeper_tool_inflight.register ~keeper_name ~tool_name ~job_id ?deadline_ms () in
Fun.protect
  ~finally:(fun () -> Keeper_tool_inflight.unregister ~job_id ())
  (fun () -> …existing execution…)
```

This makes the registry authoritative for "what is running now": an entry exists exactly
between dispatch entry and exit, under all outcomes (success, error, cancel). No SSE ordering
assumptions, no loss window.

### Read-model join — `Tool_call_inflight`

Extend `lib/server_keeper_waiting_inventory.ml`:

- `waiting_source += Tool_call_inflight` (and `source_to_string`, `all_waiting_sources`).
- The inventory builder adds one `waiting_row` per `Keeper_tool_inflight.entry`, with:
  `source = Tool_call_inflight`; `waiting_on = tool_name`; `since = Some started_at`;
  `due_at = deadline_at`; `next_action = "awaiting tool result"`; `detail = {job_id}`.
- Rows with no deadline carry `due_at = None` (rendered "—"); no ETA is computed.

### Why not feed the registry from the SSE stream (the matrix's suggestion)

The matrix floated "keeper_tool_call SSE → live registry." Rejected after audit: that stream
is completion-only, so it can close entries but cannot open them. A start-event would have to
be invented anyway, and SSE is a lossy broadcast (not a transactional source). The dispatch
boundary already has exact entry/exit knowledge; using it directly is simpler and truthful.
The SSE stream still gains `job_id` for correlation/debugging, but it is not the registry's
source of truth.

## Phase B (out of scope here — future RFC)

Route keeper tool execution through `Tool_batch` so the registry's upstream is the
`tool_event` state machine: `Job_progress` payloads, `approval = Pending` (awaiting
gate), resource-key lock contention, and replay. This makes `tool_orchestration` the single
"correct source set" the matrix names and unlocks per-job progress (not just start/end).
It is a structural change to `keeper_run_tools` / `Mcp_server_eio_execute` and needs its own
design (locking semantics, approval gating, evidence/replay interaction). Phase A's
`Keeper_tool_inflight` registry is shaped so Phase B swaps its upstream without changing the
read-model contract.

## Non-goals

- G5 per-target poll observation (board/git/LSP/connector) — separate Phase 3, "question
  first" per the matrix.
- Fabricating ETA, relabelling `bg_task`/shell jobs as tool calls, or any telemetry-as-fix.
- Persisting in-flight state to disk (it is ephemeral by definition).
- Rewiring all tool execution through `Tool_batch` (Phase B).
- Cross-process aggregation (each keeper lane is a process; the dashboard already fans out per
  keeper).

## Verification

- **OCaml** `test/test_keeper_tool_inflight.ml`: register/unregister/list; `Fun.protect`
  unregisters on exception; ETA present iff `deadline_ms` supplied; concurrent
  register/unregister under the mutex.
- **OCaml** `test/test_server_keeper_waiting_inventory.ml` (extend): `Tool_call_inflight`
  rows produced from the registry; `due_at = None` when no deadline; per-keeper grouping.
- **No dashboard panel is added in Phase A.** Consistent with the matrix's G1 adversarial
  note (ship the observation, hold the surface until the source is live and exercised): the
  rows are available on the existing inventory surface; a dedicated inflight panel waits for
  Phase B's richer state to justify its own real estate. (If the operator wants it sooner, a
  thin panel mirroring `KeeperBackgroundPanel` is a one-commit follow-up, not blocked.)
- `dune build` green; build verification on CI.

## Rollback

Purely additive: one new module, one new enum variant (+ its string/list entries), and a
`Fun.protect` wrapper at one dispatch site. Revert = remove the wrapper + the variant + the
module. No data migration (in-memory only), no schema change to the v1 keeper-background
projection (in-flight rides on `waiting_inventory`, which already has its schema).
