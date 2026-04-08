# Swarm Delivery Runbook

이 문서는 `MASC` 자체를 구현 substrate로 써서 기능 슬라이스를 계획하고 구현할 때의 표준 순서를 정리한다.

핵심 원칙:

- 구현 swarm의 SSOT는 `Team Session + Supervisor Mode`
- managed-operation benchmark lane은 별도 compat path다
- model 선택은 항상 explicit
- 기본 운영 형태는 supervised swarm

관련 문서:

- managed-operation benchmark / compat lane: [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- supervised implementation loop: [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- remote operator surface: [REMOTE-MCP-OPERATOR.md](./REMOTE-MCP-OPERATOR.md)
- provider/runtime/auth matrix: [PROVIDER-ADAPTER-RUNBOOK.md](./PROVIDER-ADAPTER-RUNBOOK.md)

## When To Use This

이 경로를 기본으로 잡는다:

- 새 기능 슬라이스를 `MASC` swarm으로 실제 구현할 때
- planner / implementer / supervisor를 분리해서 운영할 때
- report / proof / review evidence까지 남겨야 할 때

이 경로를 기본으로 잡지 않는다:

- managed-operation benchmark 자체를 실험할 때
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

1. `masc_start`
   - repo-root namespace semantics를 먼저 맞춘다.
   - `task_title` 없이 호출하면 onboarding만 하고 task 쪽은 건드리지 않는다.
2. `masc_status`
   - supervisor identity와 namespace 상태를 확인한다.
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

local fallback review helper:

```bash
./scripts/review/local-review.sh --base origin/main --head HEAD --format markdown
```

이 helper는 `.masc/review-cache/local-review/` 아래에 결과 cache를 남기고,
동일 diff에 대한 concurrent review 요청은 single-flight로 합치며,
stale pending reviewer PID가 있으면 정리한 뒤 다시 시작한다.
기본 프롬프트는 fresh-context diff-only reviewer로 동작하므로,
티켓/회의 맥락 없이도 structural risk를 따로 잡는 fallback gate로 본다.

`pr-review-pipeline` canonical path도 clean-context structural stage를 포함한다.
즉 review stack은 다음 3층으로 본다:

- context-aware multi-check review
- cross-model review evidence
- fresh-context structural pass

## Autoresearch Wrapper

Karpathy-style raw `masc_autoresearch_*` loop는 그대로 유지하되, supervised swarm path로 진입할 때는 `masc_autoresearch_swarm_start`를 우선 사용한다.

- raw loop 생성
- best-effort `research_pipeline/normalize` managed operation 생성
- linked `team session` 시작
- `research-driver` / `research-auditor` planned worker seed 기록
- 이후 operator/digest/session status에서 `linked_autoresearch` block으로 상태 확인

기본 호출 shape:

```json
{
  "goal": "Improve retrieval answer quality",
  "metric_fn": "./scripts/eval_retrieval.sh",
  "target_file": "lib/retrieval_ranker.ml",
  "program_note": "Prefer small, measurable edits. Keep latency neutral."
}
```

이 경로는 raw git ratchet을 없애지 않는다. 대신 operator-visible session/proof surface를 얹어서 연구 루프가 “있는데 안 보이는” 상태를 줄이는 것이 목적이다.

## Harness

기본 bootstrap harness:

```bash
LLAMA_SERVER_URL="${OAS_LOCAL_LLM_URL}" \
LLAMA_SWARM_MODEL=<exact-model-id-from-masc_llama_models> \
HTTP_TIMEOUT_SEC=120 \
./scripts/harness_swarm_delivery.sh
```

local64 shard-pool smoke:

```bash
LLAMA_SWARM_MODEL=<exact-model-id-from-masc_llama_models> \
LOCAL64_POOL_TARGET_SHARDS=6 \
./scripts/harness_team_session_local64_smoke.sh
```

주의:

- `local64`는 achieved fact가 아니라 target runtime profile 이름이다.
- 실제 proof 판단은 `configured_capacity`, `actual_slots`, `peak_hot_slots`를 분리해서 본다.
- runtime viability는 harness 내부의 direct HTTP probe가 아니라 `masc_runtime_verify` 결과를 기준으로 읽는다.

`scripts/llama-runtime-pool.sh print-env`는 OAS discovery가 읽는 `LLM_ENDPOINTS` 값을 출력한다.

모델/양자화별 ceiling 비교는 matrix harness로 돌린다:

```bash
LOCAL64_MODEL_MATRIX_FILE=./scripts/harness/local64-model-matrix.example.json \
./scripts/harness_local64_model_matrix.sh
```

각 run은 별도 seed port / MCP port / artifact 디렉토리를 사용하므로, 기존 primary seed를 건드리지 않고도 `q8`, `1bit`, 다른 GGUF를 순차 비교할 수 있다.

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

- `worker_class`
- `worker_size`
- `spawn_selection_note=<leader note>`

local64 worker batch는 추가로 다음 메타데이터를 권장한다:

- `worker_class`
- `capsule_mode`
- `runtime_pool="local64"`

## Acceptance

이 경로를 성공으로 보는 최소 기준:

- spawned worker가 own `masc_team_session_step(turn_kind="note", message="...")`를 남긴다
- `masc_operator_digest`가 session health를 읽는다
- supervisor action이 기록되거나, no-intervention policy가 출력에 명시된다
- `masc_team_session_report` / `masc_team_session_prove` artifact가 생성된다
- draft PR과 cross-model review evidence가 남는다

## Notes

- 이 문서는 implementation substrate SSOT다.
- managed-operation benchmark lane은 별도 compat path로 유지된다.
- worker 품질은 orchestration뿐 아니라 model/runtime 상태에도 크게 좌우된다.
