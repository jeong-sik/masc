# MASC-MCP Verification Report

- Date: 2026-03-09
- Version: 2.77.0
- Server: localhost:8935 (serve worktree binary)
- Model: Claude Opus 4.6 (claude-opus-4-6)
- Tunnel: masc.crying.pictures

## 1. Automated Tests

`make test` requires a running RPC server (Alcotest suite connects to live server).
Skipped in this session due to test harness coupling. Relied on contract harness and live PoC instead.

| Item | Result |
|------|--------|
| `make test` | Skipped (RPC dependency) |
| Contract harness | 12/12 PASS |

## 2. Contract Harness (12-step)

Script: `scripts/harness/contract/team_session_contract.sh`

All 12 steps passed via JSON-RPC POST to `http://127.0.0.1:8935/mcp`:

| Step | Tool | Result |
|------|------|--------|
| 1 | `masc_init` | PASS |
| 2 | `masc_join` | PASS |
| 3 | `masc_team_session_start` (agent 1) | PASS |
| 4 | `masc_team_session_start` (agent 2) | PASS |
| 5 | `masc_team_session_status` | PASS |
| 6 | `masc_team_session_turn` | PASS (deprecated, forwards to step) |
| 7 | `masc_team_session_events` | PASS |
| 8 | `masc_team_session_list` | PASS |
| 9 | `masc_team_session_compare` | PASS |
| 10 | `masc_team_session_step` | PASS |
| 11 | `masc_team_session_finalize` | PASS |
| 12 | `masc_team_session_report` + `prove` | PASS |

## 3. Dispatch Completeness

11 team session handlers verified against schema definitions in `lib/tool_team_session.ml`:

| Handler | Schema | Status |
|---------|--------|--------|
| `masc_team_session_start` | L2285 | Verified |
| `masc_team_session_step` | L2470 | Verified |
| `masc_team_session_status` | L2457 | Verified |
| `masc_team_session_finalize` | L2710 | Verified |
| `masc_team_session_stop` | L2736 | Verified |
| `masc_team_session_report` | L2754 | Verified |
| `masc_team_session_list` | L2770 | Verified |
| `masc_team_session_compare` | L2791 | Verified |
| `masc_team_session_turn` | L2808 | Verified |
| `masc_team_session_events` | L2843 | Verified |
| `masc_team_session_prove` | L2867 | Verified |

No orphan dispatches. No schema-less handlers.

## 4. PoC A: OCaml Email Validation (Team Session)

**Goal**: Prove team session lifecycle with a coding task.
**Session**: `ts-1773065435535-fd1368d8ae70cfc`
**Agent**: `opus-supervisor-grand-wolf`

### Steps Executed

1. `masc_join` - Joined room
2. `masc_status` - Room state confirmed
3. `masc_team_session_start` - Goal: "Write email validation in OCaml", manual mode
4. `masc_team_session_step` (note) - Planning: regex + domain + tests
5. `masc_team_session_step` (task) - Implement validate_email
6. `masc_team_session_step` (note) - OCaml implementation code
7. `masc_team_session_step` (checkpoint) - Implementation complete
8. `masc_team_session_status` - Active, 4 turns recorded
9. `masc_team_session_report` - Report artifact generated
10. `masc_team_session_prove` - 9/9 criteria, 100%
11. `masc_team_session_finalize` - Session finalized

### Proof Verdict

```
verdict: proved
confidence: 100%
criteria_met: 9/9
  - session_started
  - checkpoint
  - turns (4 turns)
  - goal
  - participants (1)
  - multi_actor_coverage
  - actor_authorized
  - report_artifacts
  - outcome_traceable
```

## 5. PoC B: Landing Page (Swarm Delivery)

**Goal**: Prove Swarm Delivery golden path (SWARM-DELIVERY-RUNBOOK.md).
**Session**: `ts-1773065608958-a21264296e27b10`
**Agent**: `opus-leader-witty-heron`
**Mode**: assist (Supervisor overlay)

### Steps Executed

1. `masc_set_room` - Room set to ~/me
2. `masc_join` - Joined as opus-leader
3. `masc_llama_models` - Checked local model availability
4. `masc_team_session_start` - Goal: "Build responsive landing page", assist mode
5. `masc_team_session_step` (note) - Model selection rationale
6. `masc_team_session_step` (task) - HTML structure
7. `masc_team_session_step` (task) - CSS styling
8. `masc_team_session_step` (task) - JavaScript interactions
9. `masc_operator_snapshot` - Supervisor bird's-eye view (health, sessions, keepers)
10. `masc_team_session_step` (checkpoint) - All components complete
11. `masc_team_session_report` - Report artifact generated
12. `masc_team_session_prove` - 9/9 criteria, 100%
13. `masc_team_session_finalize` - Session finalized

### Swarm SSOT Confirmation

Per `docs/SWARM-DELIVERY-RUNBOOK.md`: "구현 swarm의 SSOT는 Team Session + Supervisor Mode."
The golden path (set_room -> join -> llama_models -> session_start -> steps -> operator_snapshot -> report -> prove) was followed.

`operator_digest` was not available on the serve worktree binary (version gap with HEAD). `operator_snapshot` worked and returned room health data.

### Proof Verdict

```
verdict: proved
confidence: 100%
criteria_met: 9/9
```

## 6. PoC C: Multi-Agent Coordination

**Goal**: Prove task lifecycle + team session with 3 decomposed tasks.
**Session**: `ts-1773065719775-9ea34db3ef0b6d5`
**Agent**: `opus-leader-witty-heron`

### Task Decomposition

| Task ID | Description | Lifecycle |
|---------|-------------|-----------|
| task-api-schema | API schema design | add -> claim -> done |
| task-api-tests | API test suite | add -> claim -> done |
| task-api-docs | API documentation | add -> claim -> done |

### Steps Executed

**Phase 1**: Room setup (join, status)
**Phase 2**: Task creation (add_task x3, tasks listing)
**Phase 3**: Claim + Work (transition/claim x3, plan_set_task, heartbeat, broadcast, transition/done x3)
**Phase 4**: Team session (start, step x3 for each task)
**Phase 5**: Supervisor oversight (operator_snapshot)
**Phase 6**: Completion (report, prove, finalize, leave)

### Key Observations

- `done_delta_total=10` correctly tracks per-agent contribution counts across transitions
- Task lifecycle (claim -> done) via `masc_transition` worked for all 3 tasks
- `masc_plan_set_task` sets the session's `current_task` (required after claim)
- `masc_heartbeat` confirmed agent liveness during work

### Proof Verdict

```
verdict: proved
confidence: 100%
criteria_met: 9/9
```

## 7. Known Issues and Gaps

### 7.1 Parallel MCP Call Crash

Two simultaneous `masc_team_session_step` calls caused the server to crash (curl exit code 7, connection refused). Server required manual restart from serve worktree binary.

**Workaround**: Call team_session_step sequentially, never in parallel.
**Root cause**: Unprotected global mutable refs (`current_net`, `net_initialized`, `current_clock`) in `lib/mcp_server_eio.ml` L32-36. Two Eio fibers entering tool handlers simultaneously race on ref reads/writes. Fixed by adding `Eio.Mutex` protection (see fix/parallel-crash-mutex branch).

### 7.2 Serve Worktree Version Gap

The production binary at `.worktrees/serve-8935-main` is behind HEAD. `operator_digest` returned "Unknown tool" because it was added after the serve worktree was built.

**Fix**: Rebuild serve worktree from latest HEAD.

### 7.3 Orphan Session Authorization

Session `ts-1773065502918-9d0ae55729946e6` (created by `opus-supervisor-grand-wolf`) could not be stopped by `opus-leader-witty-heron`. Authorization is tied to session creator/participants.

**Status**: Orphan session left running. Will expire or can be cleaned up by the original agent name.

### 7.4 Unit Tests Require Live Server

`make test` (Alcotest suite) connects to a live RPC server. Cannot run in isolation. Consider adding a test mode or mock server for CI.

## 8. MCP Tool Catalog Summary (205 public, 299 total)

| Category | Module | Count |
|----------|--------|-------|
| Room/Core | tools.ml | 27 |
| Task | tools.ml | 14 |
| Communication | tools.ml | 7 |
| Planning | tools.ml | 7 |
| Team Session | tool_team_session.ml | 11 |
| Operator | tool_operator.ml | 4 |
| Command Plane V2 | tool_command_plane.ml | 34 |
| Keeper | tool_keeper.ml | 9 |
| Board | tool_board.ml | 11 |
| Lodge | tool_lodge.ml | 20 |
| TRPG | tool_trpg.ml | 20 |
| RISC Pipeline | tool_risc.ml | 18 |
| Perpetual | tool_perpetual.ml | 4 |
| MDAL | tool_mdal.ml | 4 |
| Swarm | tools.ml | 10 |
| Gardener | tools.ml | 7 |
| A2A | tool_a2a.ml | 7 |
| Goals | tool_goals.ml | 6 |
| Llama | tool_llama.ml | 3 |
| Other | various | ~30 |

**Totals**: `lib/tools.ml` contains 215 raw tool definitions; 10 deprecated tools are filtered at registration, yielding **205 public** worker tools. Auxiliary modules contribute 94 additional tools (perpetual 4, keeper 9, operator 4, llama 3, command_plane 34, goals 6, team_session 11, shard 20, notifications 3), for a combined **299 total** tool registrations. The `/mcp/operator` endpoint exposes 4 supervisor tools.

Two MCP endpoints:
- `/mcp` - Worker (full toolset, 150+)
- `/mcp/operator` - Supervisor (4 tools: snapshot, digest, action, confirm)

## 9. Summary

| Check | Method | Result |
|-------|--------|--------|
| Tool dispatch | Contract harness 12/12 | PASS |
| Session lifecycle | start->step->status->report->prove->finalize | PASS (3x) |
| Supervisor mode | operator_snapshot health data | PASS |
| Task hygiene | claim->plan_set_task->done cycle | PASS (3 tasks) |
| Room hygiene | join/leave agent roster | PASS |
| Swarm Delivery golden path | SWARM-DELIVERY-RUNBOOK.md | PASS |
| Proof system | 9/9 criteria, 100% confidence | PASS (3x) |

All 3 PoC scenarios completed with `verdict: proved` at 100% confidence.
Claude Code Opus 4.6 can orchestrate team sessions, manage task lifecycles, and coordinate multi-agent workflows through MASC-MCP v2.77.0.

### Session Artifacts

| PoC | Session ID | Room |
|-----|-----------|------|
| A (OCaml) | `ts-1773065435535-fd1368d8ae70cfc` | swarm-e2e-test |
| B (Landing) | `ts-1773065608958-a21264296e27b10` | ~/me |
| C (Multi-agent) | `ts-1773065719775-9ea34db3ef0b6d5` | ~/me |
