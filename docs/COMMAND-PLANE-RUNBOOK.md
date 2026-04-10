# Command Plane Runbook

`masc-mcp`의 usage SSOT.

이 문서는 `어떤 MCP tool을 어떤 순서로 써야 하는가`를 정리한다. 기본 delivery 경로는 namespace/task hygiene와 supervisor-driven supervised execution이고, managed operation은 benchmark/compatibility용 보조 경로다.

merged 기준 전체 구조 요약은 [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)를 본다.

## 개념 맵

- `namespace`
  - 조율 범위. tool 이름은 아직 `room`을 쓰지만 현재 구현은 project root 아래 `.masc/`의 single default namespace로 수렴한다.
- `task`
  - backlog item. `masc_transition(action="claim")`은 backlog 소유권만 바꾸고 planning `current_task`는 자동으로 안 잡힌다. `masc_claim_next`는 current builds에서 planning `current_task`를 함께 맞춘다.
- `operation`
  - managed-operation compatibility lane의 관리 단위. default delivery path는 아니다.
- `session`
  - historical supervised implementation execution unit. current codebase treats this as removed and uses command-plane operations/detachments instead.
- `detachment`
  - scheduler가 materialize한 실행 단위. liveness, runtime binding, heartbeat를 여기서 본다.
- `policy decision`
  - strict action 승인 큐. cross-platoon move, freeze, kill-switch 같은 작업이 여기에 멈춘다.
- `trace`
  - operation/checkpoint/dispatch/policy lineage.

## Golden Path 1. Namespace / Task Hygiene

일반 작업이든 benchmark든 먼저 이 순서를 맞춘다.

Quick path: `masc_start(path="/repo", task_title="My task")` — 1번을 처리하고, `task_title`이 있으면 task create/claim/bind까지는 옵션으로 도와줄 수 있다.

Step-by-step:

1. `masc_start`
   - project root를 coordination root로 잡고 default namespace join까지 처리한다.
   - `task_title` 없이 호출하면 onboarding만 하고 task claim 단계는 건너뛴다.
   - worktree 경로를 줘도 runtime namespace는 project-root 기준 default namespace로 수렴한다.
2. `masc_status`
   - namespace 상태와 agent roster를 확인한다.
3. `masc_transition(action="claim")` 또는 `masc_claim_next`
   - 작업을 claim한다. backlog가 비어 있으면 먼저 `masc_add_task`.
4. 필요 시 `masc_plan_set_task`
   - claim path가 planning `current_task`를 자동으로 맞추지 않았다면 세션 `current_task`를 claim한 task로 맞춘다.
5. `masc_heartbeat`
   - 긴 작업 전/중에 liveness를 갱신한다.

### 왜 이렇게 하나

- `masc_transition(action="claim") != current_task`
- `masc_claim_next -> current_task` (current builds)
- `join != heartbeat`
- `worktree != namespace`

이 셋을 헷갈리면 dashboard와 실제 coordination state가 어긋난다.

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

## Auxiliary Lane 2. Managed Operation / Benchmark Compatibility

이 경로는 benchmark topology proof와 command-plane compatibility coverage를 위한 보조 경로다. 기본 구현 경로로 취급하지 않는다.

transport truth를 빠르게 분리하고 싶으면 먼저 `./benchmarks/quick-bench.sh` 또는 `./benchmarks/benchmark.sh`를 쓴다.
이 두 스크립트는 반드시 `initialize -> notifications/initialized -> Mcp-Session-Id 재사용` 순서를 포함하고, `mcp_session_init`과 runtime lane을 분리해서 기록한다.
`benchmark.sh`는 warmup 제외와 직전 결과 diff까지 같이 남겨서 before/after 비교용 front door로 쓸 수 있다.

기본 운영 가정:

- `masc_operation_start` 기본 workload는 `coding_task`다.
- `generic`은 deprecated alias로 받아들이되 내부에서는 `coding_task`로 정규화한다.
- search strategy 기본값은 `best_first_v1`이고, `legacy`는 explicit opt-out이다.
- `coding_task` stage는 `decompose -> inspect -> implement -> verify -> review`를 canonical graph로 본다.

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

### Repo Synthesis

repo-synthesis는 `masc_autoresearch_cycle` 내부에서 cycle system을 통해 dispatch된다.
별도 front-door tool은 retired 되었다 (config.ml retired list 참조).

- read path:
  - dashboard는 `/api/v1/dashboard/repo-synthesis`와 proof/report artifact를 읽는 read-only surface
- raw escape hatch:
  - 이후 세부 조율은 `masc_dispatch_tick`, `masc_operator_digest`, command-plane truth surfaces로 내려간다.

### 첫 번째 concrete example: 12-worker live harness

가장 먼저 검증할 예시는 research-radar가 아니라 `synthetic live harness`다.

실행 순서:

1. 로컬 OpenAI-compatible runtime endpoint를 준비하고 `LLAMA_SERVER_URL` 또는 `OAS_LOCAL_LLM_URL`로 노출한다.
2. `anthropic-proxy` 또는 호환 local provider를 `127.0.0.1:3034`에 둔다.
3. repo root에서 아래를 실행한다.

```bash
scripts/harness_agent_swarm_live.sh
```

권장 시작 명령:

```bash
LLAMA_PRESET=qwen35-hot ~/me/scripts/llama-server.sh restart
```

hot runtime contract:

- `qwen35-hot`는 `ctx=262144`를 유지한다.
- bootstrap 단계의 외부 health check는 `/health`를 볼 수 있지만, proof/artifact 판단은 `masc_runtime_verify`만 사용한다.
- slot 수나 ctx가 기대치보다 낮으면 자동 downgrade 없이 바로 실패한다.

기본 프로파일:

- 12 workers
- lanes: `official`, `research`, `reviews`
- roles: `discover`, `verify`, `summarize`, `audit`
- topology: `company -> platoon -> squad`
- operation target: single managed squad

성공 기준:

- `peak_hot_slots >= 10`
- `joined_workers = 12`
- `current_task_bound = 12`
- `fresh_heartbeats = 12`
- `completed_workers = 12`
- `final_markers_seen = 12`
- `provider_reachable = true`
- `actual_slots >= expected_slots`
- `actual_ctx = expected_ctx = 262144`
- `summary.pass = true`

확인 위치:

- `masc_observe_swarm(run_id=<RUN_ID>, operation_id=<OP_ID>)`
- HTTP projection `GET /api/v1/command-plane/swarm?...` 는 read-model surface로 남아 있지만 canonical harness path는 아니다.
- dashboard `Command Plane -> swarm`

runtime contract 확인:

- `masc_runtime_verify(expected_model=<MODEL>, expected_slots=12, expected_ctx=262144)`
- blocker code는 `provider_unreachable`, `provider_model_mismatch`, `slot_count_insufficient`, `ctx_mismatch` 중 하나로 고정된다.

runtime blocker 예시:

- `provider_unreachable`
- `provider_model_mismatch`
- `slot_count_insufficient`
- `ctx_mismatch`

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

## Golden Path 3. Supervised Execution

이건 현재 기본 delivery path다. managed-operation benchmark lane과 분리해서 설명한다.

실제 기능 개발을 `MASC` swarm으로 굴릴 때의 delivery 표준은 별도 문서를 본다:

- [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)

1. `masc_operator_snapshot`
2. `masc_operator_digest`
   - namespace/session 상태를 operator-friendly하게 요약한다.
   - command-plane search/microarch signal은 여기서 먼저 읽고, 더 자세한 정보가 필요할 때만 full command-plane surface로 내려간다.
3. `masc_operator_action`
4. `masc_operator_confirm`
5. 필요 시 `masc_team_session_events`

언제 쓰나:

- human/supervisor가 intervention loop를 돌릴 때
- supervised execution session을 guided하게 운영할 때

언제 안 쓰나:

- managed-operation benchmark proof만 필요한 경우
- detachments/policy queue만 따로 검증하려는 경우

## Session Runtime Compat Lane

hot-swarm live harness와 별도로, `./scripts/harness_team_session_local64_smoke.sh`와 `./scripts/harness_supervisor_team_session.sh`는 current `masc_team_session_*` tool family와 OAS runtime bridge를 검증하는 supporting lane이다.

핵심 차이:

- managed-operation live harness
  - deterministic fixture
  - runtime-assisted claim/current_task/done
  - managed-operation swarm proof와 dashboard truthfulness 검증이 목적
- session runtime compat lane
  - `masc_team_session_start` / `masc_team_session_step(spawn_batch=...)`를 사용한다
  - `team_session_swarm_runner.ml`가 OAS swarm 실행을 담당한다
  - session/proof/operator surface 검증이 목적이다

주의:

- session runtime compat lane은 managed-operation live harness의 대체가 아니다
- managed-operation operation/detachment/current_task truth를 검증하려면 live harness/read model 쪽을 본다
- task claim/current_task binding 자체를 검증하려면 `./scripts/harness_agent_swarm_live.sh`를 사용한다

## Which Tool Now?

- project namespace가 안 잡혔다: `masc_start`
- agent가 roster에 없다: `masc_join`
- task는 claimed인데 current_task가 없다: `masc_plan_set_task`
- agent가 stale/zombie처럼 보인다: `masc_heartbeat`
- managed unit가 없다: `masc_unit_define`
- operation이 없다: `masc_operation_start`
- active op는 있는데 detachment가 없다: `masc_dispatch_tick`
- strict action이 멈춰 있다: `masc_policy_status` -> `masc_policy_approve` or `masc_policy_deny`
- detachment가 stalled다: `masc_dispatch_tick`, 필요 시 `masc_policy_status`

## 자주 틀리는 포인트

### 1. worktree를 namespace로 착각

증상:
- worktree path로 `masc_start` 또는 `masc_set_room` 했는데 기존 coordination state가 그대로 보임

정리:
- runtime namespace는 project root 기준 default 하나다
- worktree는 code isolation일 뿐이다

### 2. claim만 하면 current_task가 잡힐 거라 생각

증상:
- task는 claimed
- 그런데 planning/log tools가 task를 못 찾음

정리:
- `masc_transition(action="claim")` 다음에는 `masc_plan_set_task`
- `masc_claim_next`는 current builds에서 auto-bind 되지만, 상태가 비어 있으면 `masc_plan_set_task`로 바로 맞춘다

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

### 5. worker가 이미 leave 했는데 swarm 화면에서 빠져 보임

정리:
- live presence는 없어도 된다
- completed task ownership + final marker가 기록돼 있으면 joined/task-bound로 복원된다
- 그래서 harness 완료 후 `live_workers`보다 `joined_workers/current_task_bound/final_markers_seen`이 더 중요하다

## 관련 문서

- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- [QUICKSTART.md](./QUICKSTART.md)
