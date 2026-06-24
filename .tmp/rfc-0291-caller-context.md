# RFC-0291 caller context — closed SSE event-type sum

Grounding source: 5-lens workflow (wf_42c2aeb6-624, 2026-06-23) over
`origin/main` (`ad4b654f48`). Read with the Read tool / plain grep (rg masks
OCaml literals).

## Broadcast API (the surface being typed)
- `lib/sse.mli:101-104` — `broadcast` / `broadcast_to` / `broadcast_presence` /
  `send_to`, all `Yojson.Safe.t -> unit`, NO event-type arg.
- `lib/sse.ml:812-813` — private `broadcast_impl ?(event_type = "message")`; the
  wire `event:` line, NOT the routing key (every durable broadcast leaves it
  "message"; only `broadcast_presence` sets "presence" at `lib/sse.ml:909-911`).
- `lib/sse.ml:46-50` — `broadcast_target` (`All | Observers | Agent_streams |
  Presence_only`) is ALREADY a closed sum; only the `"type"` axis is stringly.
- Consumer routes on payload `"type"`: `server_mcp_transport_ws.ml:713-724`
  (`List.assoc_opt "type"` → `dashboard_slice_for_sse_type`).

## Fixed-literal `type`-keyed emit sites (closeable, ~30)
- `server_dashboard_http_namespace_truth.ml:350,358` — `project_snapshot`,
  `namespace_truth_snapshot` (alias pair, same payload).
- `server_dashboard_http_execution_surfaces.ml:130,134,700,745` —
  `operator_snapshot`, `operator_digest`, `execution_snapshot`,
  `transport_health_snapshot`.
- `server_dashboard_http_goal_loop_broadcast.ml:25,70,80` — `goal_loop_status`
  (RFC-0284, the stopgap-guarded one; trivially closeable).
- `keeper_chat_broadcast.ml:58` — `keeper_chat_appended`.
- `keeper_registry_broadcast.ml:16` — `keeper_composite_changed`.
- `keeper_registry.ml:676` — `keeper_phase_changed`.
- `keeper_heartbeat_snapshot.ml:451` + `keeper_heartbeat_loop_in_turn_pulse.ml:88`
  — `keeper_heartbeat` (2 emitters, same literal).
- `keeper_unified_metrics_broadcast.ml:22,60` — `keeper_compaction`,
  `keeper_handoff`.
- `keeper_guards.ml:139` — `keeper_tool_skipped`.
- `keeper_hooks_oas.ml:475` (const at `:236`) — `keeper_turn_complete`.
- `keeper_tools_oas_handler_telemetry.ml:17` + `mcp_server_eio_call_tool.ml:279`
  — `keeper_tool_call` (2 emitters).
- `keeper_approval_queue.ml:426,521` — `approval:pending`, `approval:resolved`.
- `fusion_sink.ml:260` — `fusion_run_status` (RFC-0266 §7).
- `server_routes_http_routes_activity.ml:800,872` — `governance_param_changed`
  (2 sites).
- `dashboard_yjs.ml:30` — `dashboard_yjs_update`.

## OAS bridge family — `keeper_event_bridge.ml` (open-world)
- `:153` — `wrap_event` prepends `"oas:"`.
- `:202-385` — 16 fixed native variants (`oas:agent_started` … `oas:slot_scheduler_observed`),
  1:1 with `Agent_sdk.Event_bus`.
- `:386-406` — `Custom(name,payload)` arm: `"oas:" ^ name`, dot→colon rewrite.
  DYNAMIC.
- `:430-477` — `match[@warning "-11"]` catch-all: `"oas:" ^ payload_kind`. The
  deliberate open-world escape kept for OAS pin-bumps (#10490/#10574/#10584).
- `:573` — `oas:relay_dropped` (fixed); `:513` consumes `masc:keeper:snapshot`.

## JSON-RPC `method`-keyed (out of scope, different wire shape)
- `server_bootstrap_loops.ml:451` — `notifications/board`.
- `mcp_server_eio_protocol.ml:88` — `notifications/tools/list_changed`.
- `progress.ml:63` — `notifications/progress` (indirect via `Progress.notify`).

## Indirect emits (missed by a `Sse.broadcast` grep)
- `tool_task_payloads.ml:153` → `Task.Handlers.sse_broadcast_fn` (wired
  `mcp_server.ml:532`) — `oas:masc:harness:verdict_recorded`.
- `tool_task_handlers.ml:471` → `push_event_to_sessions_fn` (wired
  `mcp_server.ml:533`) — `masc/task_claimed` (session-push channel).

## FE routes + parity gap
- `dashboard/src/sse-store.ts` — exact-match (`event.type === 'X'`) vs
  slice-bridge (`hydrateDashboardSlice` `case 'X'`).
- `dashboard/src/sse-event-type-parity.test.ts:62-63` — regex tracks ONLY
  exact-match; `:21-25` header names the keystone as "RFC-0004 increment".
- `dashboard/src/goal-loop-event-type-drift.test.ts` — the RFC-0284 stopgap
  (hand-written 3-literal guard for the slice-bridged `goal_loop_status`).

## Precedents
- `keeper_reaction_ledger.ml:6-40` — `stimulus_kind` REJECT-unknown
  (`of_string`→None); `:12-19,56-64` — `reaction_kind` TOTAL-with
  `Unknown_reaction of string`. Drift test `test_keeper_reaction_ledger.ml:386-441`.
- `keeper_lifecycle_events.mli:5-19` — closed `t` + `event_of_string`→option;
  consumer `server_dashboard_http_execution_surfaces.ml:416` no-catch-all match.
- ban-lint templates: `scripts/ci/check-enum-string-safety.sh` (diff-aware,
  `STR-OK` waiver, #9521), `scripts/stringly-boundary-ratchet.sh` (baseline
  ledger). RFC-0004 §A0.5/A3 specify the round-trip drift gate.
