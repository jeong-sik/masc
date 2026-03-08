# Benchmark Runbook

이 문서는 `single-agent baseline`과 `CPv2 swarm`을 같은 workload에 걸어 비교할 때 쓰는 운영 레시피다.

대상 workload 예:

- 최신 AI 연구/공식 발표/리뷰 수집
- normalize / verify / curate / rank / audit 파이프라인

## 기준 원칙

- canonical orchestration path는 `CPv2 direct`
- legacy `masc_swarm_*`는 benchmark 기본 경로가 아님
- supervisor/team-session은 별도 모드
- 사실 메타데이터 truth는 source metadata + rules
- LLM은 summary/tagging/audit 보조만 담당

## 실험 구조

### Baseline

- 한 에이전트가 fetch 이후 normalize/verify/curate/rank/audit를 순차 실행

### Swarm

- company
  - benchmark 전체 총괄
- platoon
  - lane 단위: `research`, `official`, `reviews`
- squad
  - stage 단위: `normalize`, `verify`, `curate`, `rank`, `audit`
- agent
  - 실제 worker

## 준비 순서

1. Room / Task hygiene 완료
   - `masc_set_room`
   - `masc_join`
   - `masc_claim`
   - `masc_plan_set_task`
   - `masc_heartbeat`
2. unit hierarchy 생성
   - `masc_unit_define`
3. benchmark operation 시작
   - `masc_operation_start`
4. scheduler reconcile
   - `masc_dispatch_tick`

## 첫 smoke는 12-worker live harness로 한다

실제 외부 소스를 긁기 전에 deterministic fixture로 orchestration부터 증명한다.

```bash
LLAMA_PRESET=qwen35-hot ~/me/scripts/llama-server.sh restart
scripts/harness_agent_swarm_live.sh
```

이 harness는:

- worker 12명 이상이 실제로 join/claim/current_task/heartbeat/done/final marker를 남기는지 확인한다
- `CPv2 swarm` read model과 dashboard가 그 사실을 올바르게 표현하는지 함께 검증한다
- 외부 네트워크 fetch 없이 synthetic fixture만 사용한다

기대 체크리스트:

- peak hot slots >= 10
- detachment materialized
- joined workers = expected workers
- current task bound = expected workers
- fresh heartbeats = expected workers
- completed workers = expected workers
- final markers seen = expected workers

주의:

- `masc_claim`만으로는 충분하지 않다. 각 worker는 `masc_set_current_task`를 호출해야 한다.
- `masc_dispatch_tick`을 안 돌리면 detachment가 생기지 않는다.
- `hot 10+`는 orchestration proof와 별개다. `llama.cpp /slots` 샘플이 없으면 pass로 보지 않는다.
- worker가 완료 후 leave해도 completed task ownership과 final marker가 있으면 swarm read model은 복원 가능해야 한다.

## 최소 unit 예시

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "company-radar",
    "kind": "company",
    "label": "AI Research Radar Company",
    "leader_id": "codex"
  }
}
```

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "platoon-research",
    "kind": "platoon",
    "label": "Research Platoon",
    "parent_unit_id": "company-radar",
    "leader_id": "codex",
    "policy": {
      "autonomy_level": "L4_Autonomous"
    }
  }
}
```

```json
{
  "tool": "masc_unit_define",
  "arguments": {
    "unit_id": "squad-verify",
    "kind": "squad",
    "label": "Verify Squad",
    "parent_unit_id": "platoon-research",
    "leader_id": "ollama-worker-1",
    "roster": ["ollama-worker-1", "ollama-worker-2"]
  }
}
```

## operation 예시

```json
{
  "method": "POST",
  "path": "/api/v1/command-plane/operations",
  "headers": {
    "x-masc-agent-name": "codex"
  },
  "body": {
    "assigned_unit_id": "squad-verify",
    "objective": "Verify and quarantine new research items",
    "autonomy_level": "L4_Autonomous",
    "policy_class": "guarded",
    "budget_class": "standard"
  }
}
```

예상 확인 포인트:

- `masc_observe_operations`에 operation이 보임
- `trace_id`가 발급됨
- actor header를 생략하면 operation `created_by`가 `dashboard`로 떨어질 수 있음

## detachment materialization

```json
{
  "tool": "masc_dispatch_tick",
  "arguments": {
    "operation_id": "op-..."
  }
}
```

바로 이어서:

- `masc_detachment_list`
- `masc_detachment_status`
- `masc_observe_alerts`
- `masc_observe_traces`

## approval / rebalance

cross-platoon rebalance나 strict action은 바로 적용되지 않을 수 있다.

```json
{
  "tool": "masc_dispatch_rebalance",
  "arguments": {
    "operation_id": "op-...",
    "target_unit_id": "squad-verify-alt"
  }
}
```

이때 가능한 응답:

```json
{
  "status": "pending_approval",
  "decision_id": "decision-..."
}
```

그 다음 순서:

1. `masc_policy_status`
2. `masc_policy_approve` 또는 `masc_policy_deny`
3. `masc_dispatch_tick`

## 체크포인트와 종료

```json
{
  "tool": "masc_operation_checkpoint",
  "arguments": {
    "operation_id": "op-...",
    "checkpoint_ref": "bench-run-2026-03-07T13:00Z",
    "note": "normalized 48 items, 3 quarantined"
  }
}
```

```json
{
  "tool": "masc_operation_finalize",
  "arguments": {
    "operation_id": "op-...",
    "note": "benchmark run completed"
  }
}
```

## 무엇을 비교하나

- end-to-end latency
- stage latency
- provenance coverage
- stale detection rate
- quarantine precision/recall
- alert frequency
- approval queue frequency
- recovery time after injected failure

## 대시보드에서 반드시 봐야 하는 것

- `Operations`
  - active op 수
  - detachment materialization 여부
- `Topology`
  - company/platoon/squad tree
  - leader / roster / utilization
- `Alerts`
  - stalled detachment
  - quiet leader
  - over-capacity unit
- `Trace`
  - checkpoint
  - dispatch
  - policy
  - failover
- `Control`
  - pending approval
  - freeze / kill-switch

## 실패 패턴

- operation만 있고 detachment가 없음
  - `masc_dispatch_tick`
- detachment heartbeat_deadline이 만료됨
  - `masc_dispatch_tick`
  - 필요 시 `masc_policy_status`
- task를 claim했는데 logs가 current task를 못 찾음
  - `masc_plan_set_task`
- agent가 사라진 것처럼 보임
  - `masc_heartbeat`

## 관련 문서

- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
