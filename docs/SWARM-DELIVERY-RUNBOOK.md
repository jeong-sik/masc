# Swarm Delivery Runbook

이 문서는 `MASC` 자체를 구현 substrate로 써서 기능 슬라이스를 계획하고 구현할 때의 표준 순서를 정리한다.

핵심 원칙:

- 구현 swarm의 SSOT는 `Team Session + Supervisor Mode`
- canonical benchmark/swarm path는 여전히 `CPv2 direct`
- model 선택은 항상 explicit
- 기본 운영 형태는 supervised swarm

관련 문서:

- canonical benchmark / swarm: [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- supervised implementation loop: [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- remote operator surface: [REMOTE-MCP-OPERATOR.md](./REMOTE-MCP-OPERATOR.md)

## When To Use This

이 경로를 기본으로 잡는다:

- 새 기능 슬라이스를 `MASC` swarm으로 실제 구현할 때
- planner / implementer / supervisor를 분리해서 운영할 때
- report / proof / review evidence까지 남겨야 할 때

이 경로를 기본으로 잡지 않는다:

- canonical CPv2 benchmark 자체를 실험할 때
- 완전 무인 autonomous swarm을 바로 검증할 때

## Default Delivery Topology

기본 역할:

- `supervisor`
  - `/mcp/operator`
  - 상태 읽기, 개입, confirm만 담당
- `planner`
  - `/mcp`
  - 작업 분해와 acceptance criteria 작성
- `implementer-a`
  - `/mcp`
  - runtime / backend / API
- `implementer-b`
  - `/mcp`
  - docs / tests / harness

기본 model policy:

1. `masc_llama_models`
2. explicit model 선택
3. session note에 선택 근거 기록
4. 같은 note를 `spawn_selection_note`로 각 worker에 전달

## Golden Path

1. `masc_set_room`
   - repo-root room semantics를 먼저 맞춘다.
2. `masc_join`
   - supervisor identity를 room에 등록한다.
3. `masc_llama_models`
   - local `llama.cpp` inventory를 읽는다.
4. explicit model 선택
   - `LLAMA_SWARM_MODEL=<exact-id>`
5. `masc_team_session_start`
   - 목표와 orchestration policy를 가진 session을 시작한다.
6. `masc_team_session_step`
   - `turn_kind="note"`로 model selection rationale을 남긴다.
7. `masc_team_session_step(spawn_batch=...)`
   - planner / implementers를 한 번에 기동한다.
8. `masc_operator_snapshot(view="summary")`
9. `masc_operator_digest`
   - health, attention, recommended actions를 읽는다.
10. `masc_operator_action`
    - 필요한 개입을 preview 또는 immediate로 넣는다.
11. `masc_operator_confirm`
    - disruptive action이면 confirm으로 실행한다.
12. `masc_team_session_report`
13. `masc_team_session_prove`
14. draft PR + cross-model review evidence

## Harness

기본 bootstrap harness:

```bash
LLAMA_SERVER_URL=http://127.0.0.1:8085 \
LLAMA_SWARM_MODEL=<exact-model-id-from-masc_llama_models> \
HTTP_TIMEOUT_SEC=120 \
./scripts/harness_swarm_delivery.sh
```

기본 출력:

- `session_id`
- `llama_swarm_model`
- `swarm_intervention_mode`
- `spawned_worker_roles`
- `spawned_runtime_actors`
- `proof_json_path`
- `proof_md_path`

### Optional Inputs

- `SWARM_SESSION_GOAL`
  - 기본 `TEAM_GOAL` override
- `SWARM_INTERVENTION_MODE`
  - `default` | `none`
- `SWARM_WORKER_BATCH_JSON`
  - worker batch를 JSON으로 직접 넘긴다
- `SWARM_WORKER_BATCH_FILE`
  - JSON 파일 경로로 worker batch를 넘긴다

`SWARM_WORKER_BATCH_JSON` / `SWARM_WORKER_BATCH_FILE` shape:

```json
[
  {
    "spawn_role": "planner",
    "spawn_prompt": "Inspect the session and leave one planning turn."
  },
  {
    "spawn_role": "implementer-a",
    "spawn_prompt": "Inspect the session and leave one implementation turn.",
    "spawn_timeout_seconds": 120
  }
]
```

harness는 각 item에 다음을 자동으로 덧붙인다:

- `spawn_agent="llama"`
- `spawn_model=LLAMA_SWARM_MODEL`
- `spawn_selection_note=<leader note>`

## Acceptance

이 경로를 성공으로 보는 최소 기준:

- spawned worker가 own `masc_team_session_step(turn_kind="note", message="...")`를 남긴다
- `masc_operator_digest`가 session health를 읽는다
- supervisor action이 기록되거나, no-intervention policy가 출력에 명시된다
- `masc_team_session_report` / `masc_team_session_prove` artifact가 생성된다
- draft PR과 cross-model review evidence가 남는다

## Notes

- 이 문서는 implementation substrate SSOT다.
- benchmark canonical path는 여전히 `CPv2 direct`다.
- worker 품질은 orchestration뿐 아니라 model/runtime 상태에도 크게 좌우된다.
