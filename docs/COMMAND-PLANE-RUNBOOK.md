# Command Plane Runbook

`masc-mcp`의 canonical usage SSOT.

이 문서는 `어떤 MCP tool을 어떤 순서로 써야 하는가`를 정리한다. 벤치마크/스웜/장기 지휘는 `CPv2 direct`가 기본 경로고, supervisor/team-session은 별도 경로다.

## 개념 맵

- `room`
  - 조율 범위. `masc_set_room`은 worktree가 아니라 repo-root room semantics로 수렴한다.
- `task`
  - backlog item. `masc_claim`은 backlog 소유권만 바꾸고, 세션 `current_task`는 자동으로 안 잡힌다.
- `operation`
  - Command Plane V2의 관리 단위. 벤치마크/스웜 실행은 여기서 시작한다.
- `detachment`
  - scheduler가 materialize한 실행 단위. liveness, runtime binding, heartbeat를 여기서 본다.
- `policy decision`
  - strict action 승인 큐. cross-platoon move, freeze, kill-switch 같은 작업이 여기에 멈춘다.
- `trace`
  - operation/checkpoint/dispatch/policy lineage.

## Golden Path 1. Room / Task Hygiene

일반 작업이든 benchmark든 먼저 이 순서를 맞춘다.

1. `masc_set_room`
   - repo root를 room으로 잡는다.
   - worktree 경로를 줘도 room은 repo-root 기준으로 동작한다.
2. `masc_join`
   - agent identity와 capabilities를 room에 등록한다.
3. `masc_status`
   - room 상태와 agent roster를 확인한다.
4. `masc_claim`
   - 작업을 claim한다. backlog가 비어 있으면 먼저 `masc_add_task`.
5. `masc_plan_set_task`
   - 세션 `current_task`를 claim한 task로 맞춘다.
6. `masc_heartbeat`
   - 긴 작업 전/중에 liveness를 갱신한다.

### 왜 이렇게 하나

- `claim != current_task`
- `join != heartbeat`
- `worktree != room`

이 셋을 헷갈리면 dashboard와 실제 room state가 어긋난다.

### 최소 MCP 예시

```json
{
  "tool": "masc_join",
  "arguments": {
    "agent_name": "codex",
    "capabilities": ["ocaml", "dashboard", "documentation"]
  }
}
```

예상 응답 핵심 필드:

```json
{
  "agent": "codex-...",
  "status": "joined"
}
```

```json
{
  "tool": "masc_plan_set_task",
  "arguments": {
    "task_id": "task-058"
  }
}
```

예상 상태 변화:

- `masc_plan_get_task`가 `task-058` 반환
- dashboard에서 claimed task와 current_task가 같은 값으로 보임

## Golden Path 2. CPv2 Benchmark / Swarm

이 경로가 benchmark와 swarm의 canonical path다.

1. `masc_unit_define`
   - company/platoon/squad/agent hierarchy를 만든다.
2. `masc_operation_start`
   - benchmark operation을 시작한다.
3. `masc_dispatch_tick`
   - scheduler를 한 번 돌려 detachment를 만든다.
4. `masc_detachment_list` / `masc_detachment_status`
   - runtime materialization, heartbeat deadline, progress를 확인한다.
5. `masc_observe_topology` / `masc_observe_operations` / `masc_observe_alerts` / `masc_observe_traces`
   - 상태와 이상 징후를 읽는다.
6. `masc_policy_status`
   - strict action이 pending approval인지 본다.
7. `masc_policy_approve` or `masc_policy_deny`
   - 승인이 필요한 move/freeze/kill-switch를 처리한다.
8. `masc_operation_checkpoint`
   - durable resume pointer를 남긴다.
9. `masc_operation_finalize`
   - 정상 종료 시 operation을 completed로 닫는다.

### 최소 HTTP 예시

```http
POST /api/v1/command-plane/operations
x-masc-agent-name: codex
Content-Type: application/json

{
  "assigned_unit_id": "squad-research-normalize",
  "objective": "Normalize and verify latest AI research items",
  "autonomy_level": "L4_Autonomous",
  "policy_class": "guarded"
}
```

예상 응답 핵심 필드:

```json
{
  "status": "ok",
  "result": {
    "operation_id": "op-...",
    "trace_id": "trace-...",
    "status": "active"
  }
}
```

주의:

- HTTP mutating call에서 `x-masc-agent` 또는 `x-masc-agent-name`, 혹은 `agent_name` query를 안 주면 actor가 `dashboard`로 기록된다.
- trace / operation `created_by` attribution이 중요하면 header를 반드시 붙인다.

그 다음 바로:

```http
POST /api/v1/command-plane/dispatch/tick
Content-Type: application/json

{
  "operation_id": "op-..."
}
```

예상 상태 변화:

- `masc_detachment_list`에 detachment가 생김
- dashboard `Operations`에서 detachment card가 보임

## Golden Path 3. Supervisor Session

이건 benchmark canonical path가 아니다. supervised implementation path다.

1. `masc_operator_snapshot`
2. `masc_operator_action`
3. `masc_operator_confirm`
4. 필요 시 `masc_team_session_events`

언제 쓰나:

- human/supervisor가 intervention loop를 돌릴 때
- team-session을 guided하게 운영할 때

언제 안 쓰나:

- CPv2 benchmark
- direct swarm orchestration

## Which Tool Now?

- room이 안 잡혔다: `masc_set_room`
- agent가 roster에 없다: `masc_join`
- task는 claimed인데 current_task가 없다: `masc_plan_set_task`
- agent가 stale/zombie처럼 보인다: `masc_heartbeat`
- managed unit가 없다: `masc_unit_define`
- operation이 없다: `masc_operation_start`
- active op는 있는데 detachment가 없다: `masc_dispatch_tick`
- strict action이 멈춰 있다: `masc_policy_status` -> `masc_policy_approve` or `masc_policy_deny`
- detachment가 stalled다: `masc_dispatch_tick`, 필요 시 `masc_policy_status`

## 자주 틀리는 포인트

### 1. worktree를 room으로 착각

증상:
- worktree path로 `masc_set_room` 했는데 기존 room state가 그대로 보임

정리:
- room은 repo root 기준이다
- worktree는 code isolation일 뿐이다

### 2. claim만 하면 current_task가 잡힐 거라 생각

증상:
- task는 claimed
- 그런데 planning/log tools가 task를 못 찾음

정리:
- `masc_claim` 다음에 반드시 `masc_plan_set_task`

### 3. heartbeat 없이 오래 작업

증상:
- 실제로는 살아 있는데 stale/zombie처럼 보임

정리:
- long-running step 전/중에 `masc_heartbeat`

### 4. operation start 후 detachment가 안 생김

증상:
- operation은 보이는데 runtime이 없음

정리:
- `masc_dispatch_tick`을 아직 안 돌렸거나
- target unit가 blocked/frozen/approval pending 상태일 수 있음

## 관련 문서

- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- [QUICKSTART.md](./QUICKSTART.md)
