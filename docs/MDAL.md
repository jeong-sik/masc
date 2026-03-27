# MDAL

MDAL (Metric-Driven Agent Loop)은 측정 가능한 수치 하나를 기준으로 반복을 관리하는 도구입니다. 핵심 역할은 다음 네 가지입니다.

1. 시작 시 baseline metric을 측정한다.
2. 각 iteration에서 작업 결과를 기록한다.
3. iteration 뒤 metric을 다시 측정해 delta를 계산한다.
4. 목표 달성, stagnation, 시간/횟수 제한으로 종료를 판단한다.

## 언제 써야 하나

- 단일 수치로 성공을 판단할 수 있을 때
- 같은 metric을 iteration마다 다시 측정할 수 있을 때
- `coverage >= 80`, `errors <= 0`, `score >= 0.90`, `ssim >= 0.95` 같은 형태로 목표를 쓸 수 있을 때

## 언제 쓰면 안 되나

- "코드를 더 깔끔하게"
- "아키텍처를 더 좋게"
- "리뷰 품질을 올려"
- "문서를 더 읽기 좋게"

위처럼 deterministic metric 없이 질적 판단만 필요한 일은 MDAL 대상이 아닙니다. 그런 작업은 일반 작업 분해, review, verifier, 사람 판단으로 다루는 편이 맞습니다.

## 중요한 계약

- MDAL의 판단 근거는 `metric_fn`이 출력한 수치와 hard limit뿐입니다.
- strict MDAL은 public manual fallback이 없습니다. 각 iteration은 worker 실행, auditable tool evidence, metric 재측정을 모두 통과해야 기록됩니다.
- `heuristics`는 worker prompt 힌트일 뿐이며 종료 판단 로직에 쓰이지 않습니다.
- built-in profile(`ssim`, `coverage`, `lint`, `review`, `docs`)은 threshold와 기본 정책만 제공합니다.
- built-in profile은 신뢰 가능한 기본 `metric_fn`을 내장하지 않습니다. 이 워크스페이스에서는 `metric_fn`을 명시해야 합니다.
- custom `goal`의 path는 단일 측정값의 라벨입니다. `metric >= 0.90`, `score >= 0.90`, `errors <= 0`처럼 쓸 수 있지만 실제로는 같은 단일 scalar를 비교합니다.
- `tools_allow`, `tools_deny`는 runtime-enforced auditable tool policy입니다. 허용 도구가 비면 loop 생성 자체가 거부됩니다.
- loop 상태 SSOT는 현재 MASC backend입니다. filesystem이면 `.masc/mdal/*.json`, postgres면 backend KV에 저장됩니다.
- Supabase를 쓰면 transaction pooler(`*.pooler.supabase.com:6543`)를 우선 사용한다. MASC는 Caqti request를 `oneshot`으로 내려 prepared statement 충돌을 피한다. legacy session pooler(`:5432`)가 잡혀 있어도 같은 host의 transaction URL이 함께 있으면 `:6543`를 우선 선택한다.
- persisted `running` loop는 서버 재시작 뒤 첫 로드 시 `interrupted`로 정규화됩니다.
- Board와 SSE는 관측용 기록입니다. 상태 저장의 SSOT가 아닙니다.
- strict v1의 evidence 범위는 auditable tools first입니다. 코드 변경이 필요하면 worker가 `masc_spawn`으로 구현 agent를 호출하는 방식이 기본 경로입니다.

## Strict Worker 경계

- `masc_mdal_start`는 loop를 생성하고 baseline을 측정합니다.
- `masc_mdal_iterate`는 strict worker만 실행합니다. 수동 `changes`/`failed_attempts`/`next_suggestion` 입력은 거부됩니다.
- worker는 최소 1개의 auditable tool을 실제로 사용해야 합니다. evidence가 없으면 loop는 `interrupted` + `worker_evidence_missing`으로 끝납니다.
- `masc_mdal_status`는 persisted state를 읽고, 재시작된 loop는 `interrupted`로 보여줍니다.
- `masc_mdal_stop`은 loop를 중단하고 최종 요약을 남깁니다.
- `completed`, `stopped`, `error` 상태는 다시 iterate할 수 없습니다. 재개 가능한 상태는 `running`과 `interrupted`뿐입니다.

## 좋은 예 / 나쁜 예

### 좋은 예

- 테스트 커버리지를 72%에서 80%까지 올리기
- evaluator score를 0.81에서 0.90까지 올리기
- 렌더와 reference 이미지의 SSIM을 0.95까지 맞추기
- lint error count를 12에서 0으로 줄이기

### 나쁜 예

- "전반적으로 더 나은 코드로 리팩터링"
- "UI를 좀 더 세련되게"
- "문서를 더 친절하게"
- "리뷰 품질을 올리기"

이런 작업은 metric authoring이 먼저입니다. metric 없이 MDAL부터 시작하면 선택만 복잡해지고 loop 판단은 빈약해집니다.

## 권장 사용법

### Custom metric

```json
{
  "profile": "custom",
  "metric_fn": "python3 scripts/score.py",
  "goal": "metric >= 0.90",
  "target": "Evaluator score >= 0.90",
  "max_iterations": 8
}
```

### Built-in policy preset with explicit metric

```json
{
  "profile": "coverage",
  "metric_fn": "./scripts/coverage_percent.sh",
  "target": "Test coverage >= 80%"
}
```

## 응답에서 봐야 할 필드

- `assessment`: `improved`, `flat`, `regressed`
- `assessment_basis`: 항상 `measured_delta`
- `iteration_mode`: 항상 `strict_worker`
- `strict_mode`: strict MDAL loop 여부
- `worker_engine`: 현재는 `api_tool_loop`
- `worker_model`: strict worker에 사용된 model label
- `latest_tool_call_count`, `latest_tool_names`, `session_id`, `evidence_status`: 최신 hard evidence 요약
- `execution_mode`: 현재 strict loop는 `worker_spawn`
- `durability`: `persistent_backend` 또는 `memory_only`
- `persistence_backend`: `filesystem`, `postgres`, `memory`
- `recoverable`: 현재 상태에서 iterate 재개 가능한지 여부
- `stop_reason`, `error_message`: terminal/interrupted 상태의 기계 판독용 이유

## 현재 의도적으로 하지 않는 것

- metric을 추정하는 fake built-in command 제공
- heuristic만으로 stop/continue 결정
- Board 기록을 loop 복구용 저장소로 사용
- server restart 후 loop를 몰래 `running`으로 복구
