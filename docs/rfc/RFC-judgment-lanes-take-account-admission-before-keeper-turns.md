---
rfc: "judgment-lanes-take-account-admission-before-keeper-turns"
title: "판정 레인은 계정 허가를 Keeper 턴보다 먼저 받는다"
status: Draft
created: 2026-10-06
updated: 2026-10-06
author: vincent + claude
supersedes: []
superseded_by: null
related: ["exact-output-lanes-bypass-the-shared-provider-concurrency-cap", "provider-declared-backpressure"]
implementation_prs: []
---

# 판정 레인은 계정 허가를 Keeper 턴보다 먼저 받는다

## 0. 요약

verifier 판정 한 건은 7~15분, 길면 29분 걸린다. 도구를 실행하는 시간은 5초 남짓이다.
나머지는 모델 호출 사이의 간격이고, 그 대부분은 계정 허가를 기다리는 시간으로 보인다.

glm-coding 계정의 허가는 4칸이고 하루 대부분 차 있다.
`Slot_scheduler` 는 도착 순서대로만 칸을 준다. 그래서 판정 레인은 glm 호출의 약 95%를 차지하는 Keeper 턴과 같은 줄에 선다.

이 RFC 는 줄을 두 개로 나눈다.

- 칸이 비면 판정 줄에 먼저 준다.
- 두 줄이 모두 기다리면, 판정 줄이 연달아 받을 수 있는 횟수에 한도를 둔다. 그래서 Keeper 턴도 정해진 몫은 받는다.

칸 수, 계정 단위 키, 대기 마감, 취소 처리는 지금 그대로 둔다.

## 1. 측정 (2026-10-06)

스크립트와 결과는 `docs/evidence/judgment-lane-admission-20261006/` 에 있다.

### 1.1 verifier 한 건의 시간

`verification-runs.jsonl`, 2026-10-06 14:00 KST 까지 24시간, 188건(승인 100, 거절 82).

| 판정 런타임 | 건수 | 전체 p50 | 도구 시간 p50 | 첫 도구까지 p50 | 모델 단계 p50 | 단계 간격 p50 / p90 |
|---|---:|---:|---:|---:|---:|---:|
| `glm-coding.glm-5.3-flash` | 65 | 651초 | 3.6초 | 183초 | 3 | 110초 / 243초 |
| `claude_code.claude-sonnet-5-5-medium` | 117 | 921초 | 5.7초 | 231초 | 5 | 109초 / 267초 |
| `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` | 2 | 1479초 | 6.9초 | 135초 | 10 | 145초 / 235초 |

도구는 시간을 거의 쓰지 않는다. 한 건의 시간은 "모델 단계 수 × 단계 간격"으로 거의 설명된다.

### 1.2 glm-coding 계정의 허가는 차 있다

`agent-core-events/2026-10/06.jsonl` 의 glm 스트리밍 호출을 셌다.
`Streaming_first_chunk.requested_at` 은 허가를 받은 뒤 찍힌다. `Complete.complete_stream` 이 dispatch 를 `Provider_admission` 안에서 실행하기 때문이다.

- 요청 2,969건 중 **91%** 가 다른 Keeper 턴의 스트림이 끝난 뒤 0.3초 안에 나갔다. 앞 칸이 비자마자 줄 선 요청이 들어간 모양이다.
- 같은 셈을 요청 시각만 3초 밀어서 하면 3%다. 이 값이 우연히 맞아떨어질 확률의 기준이다.
- 같은 Keeper 가 자기 응답을 받자마자 다음 요청을 보낸 경우는 0%다.
- 10~13시(KST)에는 4칸이 다 찬 시간이 62~71%였다. 스트리밍 호출만 보고 센 값이라 실제보다 낮다.
- 같은 시간대 glm 호출 한 번의 길이는 p50 10~31초다.

verifier 의 단계 간격 p50 110초와 호출 길이 p50 10~31초를 비교하면, 한 단계의 상당 부분이 허가 대기다.
verifier 호출은 임시 base path 에서 돌아서 이벤트에서 따로 골라낼 수 없었다. 그래서 이 비율은 직접 잰 값이 아니라 추정이다.

같은 칸으로 판정 하나를 받는 `board_attention_exact` 도 시간대별 p50 이 66~243초였다. 작은 호출 하나에 걸린 시간이다.

### 1.3 칸을 늘릴 수 없다

- 계정은 Z.AI Max 요금제다(운영자, 2026-09-25).
- 공식 정책(<https://docs.z.ai/devpack/usage-policy>, 2026-10-06 확인)은 등급별 상한이 자원 상황에 따라 바뀐다고만 하고 숫자를 주지 않는다.
- 지금도 Z.AI 가 `1302 Rate limit reached for requests` 로 거절한다. 시스템 로그에서 glm-coding 거절 줄은 10-02 55, 10-03 77, 10-04 92, 10-05 237줄이다(같은 사건이 여러 줄일 수 있다).
- 토큰은 문제가 아니다. 5시간 창 사용량은 1~31%였다(`provider_usage_history`).

칸을 늘리면 거절이 늘 뿐이다. 남은 방법은 정해진 칸을 누구에게 먼저 주느냐다.

### 1.4 누가 줄을 쓰나

#39879(2026-09-29) 이후 exact 레인도 같은 계정 허가를 거친다. 그래서 RFC-exact-output-lanes-bypass-the-shared-provider-concurrency-cap §2.3 의 우회는 지금 없다.

2026-10-06 14:00 KST 까지 24시간, §1.1 과 같은 창이다.

| 호출하는 쪽 | glm-coding 호출 수 | 근거 |
|---|---:|---|
| Keeper 턴 | 10,545 | `costs/2026-10/05.jsonl`·`06.jsonl` 에서 `runtime_id` 가 `glm-coding.` 으로 시작하는 줄 |
| verifier | 약 265 | 65건 × (첫 호출 + 단계 간격 200개) |
| board attention | 273 | `exact-lane-runs-v6.jsonl` 의 glm 슬롯 완료 |
| hitl auto judge | 0 | 같은 파일 |

판정 레인은 glm 호출의 약 5%다. verifier 호출은 임시 base path 에서 돌아서 `costs` 에 없다. 그래서 두 줄은 겹치지 않는다.

## 2. 지금 구조

- `Provider_admission.key_of_config` 는 `(provider kind, base_url, API 키)` 로 허가를 묶는다. 모델 단위가 아니라 계정 단위다. `glm-5.3-flash`·`glm-5-3`·`glm-5-2`·`glm-5-1` 이 4칸 하나를 같이 쓴다.
- `Slot_scheduler` 는 도착 순서대로만 칸을 주는 FIFO 하나다(`slot_scheduler.mli`: "Capacity is the only scheduling constraint").
- exact 레인은 `with_admission_and_work_for ~timeout_s` 로 허가를 받는다(`exact_output_flow_admission.ml`). 대기 시간과 작업 시간이 같은 예산(`exact-body-timeout-s`)에서 빠진다. 줄이 길면 늦어질 뿐 아니라 모델이 일할 시간도 줄어든다.
- verifier 는 Keeper 턴 경로(`Keeper_turn_driver`, `Tool_verdict`)로 돈다. 그 provider 설정은 `Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config` 를 거친다.

## 3. 제안

### 3.1 허가 등급 두 개

agent_core 에 닫힌 타입을 하나 둔다.

```ocaml
(* Provider_admission *)
type admission_class = Priority | Standard
```

`Provider_config.t` 에 `admission_class` 를 더한다. 기본값은 `Standard` 다. 지금 모든 호출이 같은 줄에 서 있으므로, 기본값을 두면 이 변경 전과 같은 순서가 된다.
문자열 분류나 레인 이름 비교는 쓰지 않는다. 등급은 호출하는 코드가 타입으로 정한다.

masc 에서 `Priority` 를 다는 곳:

| 레인 | 다는 위치 | 이유 |
|---|---|---|
| verifier | `anti_rationalization_reviewer_provider_config` | Task 완료가 이 판정을 기다린다 |
| hitl auto judge | exact flow 시작(`Exact_output.start_flow`) | 운영자 확인 흐름이 이 판정을 기다린다 |
| board attention | exact flow 시작(`Exact_output.start_flow`) | Keeper 가 무엇을 볼지가 이 판정으로 정해진다 |

어느 레인이 `Priority` 인지는 `Standalone_lane.admission_class` 한 곳에서 정한다. verifier 설정과, exact flow 를 여는 masc 코드 여섯 곳이 모두 이 함수로 등급을 받는다. 레인이 새로 생기면 이 함수의 match 가 컴파일되지 않는다. `Exact_output.start_flow` 는 등급을 필수 인자로 받아서, 등급 없이 flow 를 여는 코드도 컴파일되지 않는다.

librarian 은 `Standard` 로 둔다. 기억 정리는 다른 일을 막지 않고, 요청 하나가 67~136KB 로 크다. 우선 칸을 큰 요청이 오래 쥐면 판정 레인이 다시 기다린다.

### 3.2 칸을 나눠 주는 규칙

칸이 하나 비면 다음 순서로 정한다.

1. 한쪽 줄만 기다리면 그 줄의 맨 앞에 준다.
2. 두 줄이 모두 기다리면 `Priority` 줄의 맨 앞에 준다.
3. 다만 `Standard` 가 기다리는 동안 `Priority` 가 연달아 `priority_run_limit` 번 받았으면, 이번에는 `Standard` 맨 앞에 준다.

같은 줄 안에서는 지금처럼 도착 순서를 지킨다.
`priority_run_limit` 은 계정(provider) 단위로 `runtime.toml` 에 둔다. 코드 상수로 두지 않는다.

```toml
[providers.glm-coding]
admission-priority-run-limit = 3
```

이 한도는 그 provider 에서 `max-concurrent` 를 선언한 binding 에만 붙는다. 칸 수가 없는 binding 은 허가 절차 밖에서 돌므로 한도도 받지 않는다. 칸 수를 선언한 binding 이 하나도 없거나, 공식 클라이언트(claude_code, codex 등) provider 에 이 키를 두면 아무 요청도 이 한도를 쓰지 않는다. 그런 설정은 읽을 때 provider 를 짚어 거절한다.

3이면 두 줄이 모두 기다릴 때 `Standard` 가 칸의 4분의 1 이상을 받는다. 지금 판정 레인은 호출의 약 5%라서, 평소에는 한도에 닿지 않는다.

### 3.3 그대로 두는 것

- 칸 수와 계정 단위 키.
- 기다리던 쪽이 취소되거나 마감이 지나면 줄에서 빠진다. 칸을 받은 순간과 겹치면 칸은 그쪽 것이다(`slot_scheduler.mli` 의 취소 규칙).
- exact 레인의 대기·작업 공통 예산.
- RFC-provider-declared-backpressure 가 제안하는 "거절을 받으면 칸 수를 줄인다"와는 따로 동작한다. 그 RFC 는 칸이 몇 개인지를, 이 RFC 는 빈 칸을 누구에게 주는지를 다룬다.

### 3.4 기대 효과 (추정)

- 판정 레인의 대기는 "다음 칸이 빌 때까지"로 줄어든다. 4칸이 호출 p50 10~31초로 돌면 몇 초 수준이다. verifier 한 단계는 대략 호출 길이만큼으로 줄어들 것으로 본다.
- Keeper 턴은 판정 레인 호출만큼(약 5%) 더 기다린다.

이 숫자는 §1 데이터로 낸 추정이다. 실제 값은 §4 측정으로 확인한다.

## 4. 검증

### 4.1 결정적 테스트 (agent_core)

`Slot_scheduler` 는 시계와 네트워크 없이 시험할 수 있다.

- 두 줄이 다 기다릴 때 `Priority` 가 먼저 받는다.
- 같은 줄 안에서는 도착 순서를 지킨다.
- `Priority` 가 `priority_run_limit` 번 연달아 받으면 다음은 `Standard` 다.
- 무작위 도착·해제·취소·마감 순서에서 다음 불변식을 확인한다. 동시에 쥔 칸은 `max_slots` 이하이고, 칸이 새지 않는다. 맨 앞에서 기다리는 `Standard` 는 `priority_run_limit` 번보다 많이 밀리지 않는다.
- 변이 확인: 규칙 3을 지우면 마지막 불변식 테스트가 실패해야 한다.

### 4.2 masc 연결 테스트

- verifier, hitl auto judge, board attention 의 provider 설정이 `Priority` 이고, Keeper 턴과 librarian 이 `Standard` 인지 확인한다.
- `admission-priority-run-limit` 이 1보다 작거나, 그 provider 에 `max-concurrent` 를 선언한 binding 이 없거나, 공식 클라이언트 provider 이면 설정을 읽을 때 거절한다. 키가 없으면 그 계정은 도착 순서 한 줄이다.

### 4.3 운영 측정

등급별 대기 시간을 기록해야 효과를 잴 수 있다. 허가를 받을 때 등급과 기다린 시간을 `agent-core-events` 에 남긴다.
이 기록은 효과를 확인하는 수단이고, 이것만으로 고쳐지는 것은 없다.

배포 전후로 같은 스크립트를 돌려 비교한다.

| 항목 | 지금 | 목표 |
|---|---|---|
| verifier 단계 간격 p50 (glm) | 110초 | 40초 이하 |
| `Priority` 허가 대기 p50 (4칸이 찬 시간대) | 재지 못함 | 10초 이하 |
| `Standard` 허가 대기 증가 | 재지 못함 | 10% 이하 |

## 5. 고려한 다른 방법

| 방법 | 버린 이유 |
|---|---|
| 칸 수를 늘린다 | Z.AI 가 지금도 1302 로 거절한다(§1.3) |
| verifier 만 다른 계정(Kimi)으로 옮긴다 | 칸은 따로 생기지만 판정 모델이 바뀌고, 다른 판정 레인은 그대로 기다린다. 운영자가 2026-10-06 에 이 RFC 방향을 골랐다 |
| 판정 레인용 칸을 하나 예약한다 | 판정 레인이 호출의 5%라 예약 칸이 대부분 논다. Keeper 턴이 쓸 수 있는 칸이 4개에서 3개로 줄어든다 |
| 무조건 판정 레인 먼저 | board attention 이 몰리면 Keeper 턴이 계속 밀릴 수 있다 |
| 오래 기다린 요청의 등급을 올린다(시간 기준) | 스케줄러에 시계와 시간 상수가 들어가 테스트가 시계에 묶인다. 횟수 한도는 같은 효과를 결정적으로 낸다 |

## 6. 범위 밖

- **claude_code verifier 의 15분.** 117건 중 111건이 913초 근처에서 판정을 냈다. 조회 도구는 p50 868초까지 불렸다. `[turn] provider_call_deadline_sec = 900` 과 숫자가 맞지만 무엇이 판정을 재촉하는지 코드에서 찾지 못했다. 이 계정은 glm 허가와 무관하므로 따로 조사한다.
- **ollama_cloud 계정.** 허가가 2칸이고 Keeper 와 librarian 이 같이 쓴다. librarian 의 `timeout:wall_clock` 실패(24시간 762건)에는 180초 예산 안의 허가 대기가 섞였을 수 있다. 확인 필요. 이 RFC 의 등급은 계정이 아니라 레인에 붙으므로 같은 규칙이 그대로 적용된다.
- **RFC-exact-output-lanes-bypass-the-shared-provider-concurrency-cap 의 상태 정리.** 그 RFC 의 우회는 #39879 로 닫혔다. 상태 갱신은 그 RFC 쪽 일이다.

## 7. 단계

1. agent_core: `Slot_scheduler` 두 줄과 연속 한도, `Provider_admission`·`Provider_config` 의 등급, §4.1 테스트.
2. masc: 세 판정 레인에 `Priority`, `admission-priority-run-limit` 읽기와 seed 설정, §4.2 테스트.
3. 등급별 대기 기록(§4.3).
4. 배포 뒤 하루 측정하고 §4.3 표를 채운다.

## 8. 열린 질문

- `priority_run_limit` 기본값 3이 맞는가. seed 에는 3을 두고, 라이브는 운영자가 정한다.
- board attention 이 Jev 를 거친 뒤에도 몰리면(2026-10-01 이후 분당 110~470건 판정 중 LLM 으로 가는 몫) 한도에 자주 닿을 수 있다. 1단계 측정에서 한도에 닿은 횟수를 같이 본다.
