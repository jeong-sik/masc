---
rfc: "provider-declared-backpressure"
title: "공급자가 밀어내면 그 엔드포인트의 허가 수를 줄인다"
status: Draft
created: 2026-09-17
updated: 2026-09-17
author: vincent
related: ["provider-path-rest"]
---

# RFC: 공급자가 밀어내면 그 엔드포인트의 허가 수를 줄인다 (provider-declared-backpressure)

## 0. 요약

Z.ai coding plan 은 동시 요청 수의 상한을 공개하지 않고 형편에 따라 바꾼다. 넘으면 HTTP 429, 코드 1302, 문구 "Rate limit reached for requests" 로 거절한다. 2026-09-16 하루 glm-5.3-flash 턴 946건 중 331건(35%)이 이 거절로 끝났다. masc 는 이 엔드포인트에 동시 4건까지 보내도록 선언돼 있고(`max-concurrent = 4`), 거절을 받으면 그 경로를 60초 쉬게 한 뒤 다시 같은 4건으로 돌아간다. 공급자가 "줄여라" 고 말한 다음에도 masc 가 보내는 동시 수는 줄지 않는다.

제안: 엔드포인트 단위 허가(`Provider_admission`)의 **유효 허가 수**를 공급자의 거절에 맞춰 내리고, 거절 없이 이어지는 성공에 맞춰 선언값까지 되돌린다. 선언값은 천장으로 남는다. 새 대기·재시도·게이트는 없다. 이미 있는 60초 경로 휴식(RFC-provider-path-rest)은 그대로 둔다.

## 1. 실측 (2026-09-16 UTC, 서버 1c5645873e → eee8f6aee8)

근거 파일과 재현 스크립트는 `docs/design/prefix-cache-first-round-20260917.md` 와 같다(`scripts/analysis/prefix-cache-first-round.py`, `docs/evidence/prefix-cache-first-round-20260917.json`).

### 1.1 얼마나 거절되나

| 항목 | 값 |
|---|---:|
| glm-5.3-flash 로 끝난 턴(receipts) | 946 |
| 그중 `api_error_rate_limited` | 331 (35%) |
| 거절 문구 | 145/145 "Rate limit reached for requests" |
| keeper 이름이 붙은 개별 429 사건(시스템 로그, 중복 제거) | 158 |
| 한 분에 3건 이상 몰린 분 | 9 |
| 하루 glm 요청(costs, 완료분) | 2,198 |
| 5시간 창별 요청 | 913 / 549 / 580 / 154 |

### 1.2 무엇이 아닌가

- **credit 소진이 아니다.** 5시간 credit 이 떨어지면 1316("Usage limit reached for the past 5 hours"), 주간이면 1310, 다른 창이면 1308 이 온다. 09-14~17 나흘 시스템 로그에 이 문구는 0건이고, 429 문구 3,695줄은 전부 1302 의 것이다(문구는 공급자 본문에서 그대로 온다. `Retry.RateLimited { message }`). 시간축도 같은 말을 한다. 09-16 에 429 가 난 179분 중 146분에는 같은 분 안에 glm 완료가 있고, 완료 없이 429 만 이어진 가장 긴 구간은 2분이다. credit 벽이면 다음 회전까지 완료가 끊긴다.
- **masc 가 선언보다 많이 보낸 것이 아니다.** 허가는 엔드포인트 identity(kind, base_url, key)마다 하나라 keeper 든 시스템 경로든 같은 4칸을 나눠 쓴다. 완료 요청으로 복원한 동시 건수는 429 시점 중앙값 1, 최대 3 이었다. 다만 429 로 끝난 요청 자체는 costs 에 없어 이 복원은 아래로 치우친다.
- **요청 빈도만의 문제도 아니다.** 429 직전 60초의 완료 요청 수는 중앙값 1 로, 성공한 요청 직전(5)보다 적다. 공급자가 줄일 때는 우리 요청 대부분이 실패해 완료분이 비기 때문이다. 이 지표로는 동시성과 빈도를 가를 수 없다.

### 1.3 공급자가 말하는 것

- [docs.z.ai/api-reference/api-code](https://docs.z.ai/api-reference/api-code) (2026-09-16 확인): 1302 = "Rate limit reached for requests", HTTP 429, 조치 "요청 빈도·동시성을 줄여라". 1305 = 일시 과부하, 1308/1310 = 사용량 한도.
- [docs.z.ai/devpack/usage-policy](https://docs.z.ai/devpack/usage-policy) (검색 결과 요약, Medium): 동시성 한도는 플랜에 묶이고 자원 형편에 따라 **동적으로** 조정된다. Max > Pro > Lite. 숫자는 공개하지 않는다.
- [docs.z.ai/devpack/overview](https://docs.z.ai/devpack/overview) (2026-09-17 확인): 5시간 credit 은 요청 수가 아니라 (입력 토큰×배수 + 캐시 입력×배수 + 출력×배수)/10,000 이고, 소비한 시점에서 5시간 뒤 되돌아온다. Lite 2,000 / Pro 12,000 / Max 28,000. 주간은 10,000 / 60,000 / 140,000.
- [docs.z.ai/devpack/notice/event-glm-5.3-flash](https://docs.z.ai/devpack/notice/event-glm-5.3-flash) (2026-09-17 확인): 9/3~9/20 매일 23:00~09:00 SGT(15:00~01:00 UTC) glm-5.3-flash 이벤트, 다른 에이전트는 quota 2배. 09-16 의 429 비율은 이 창 안 11%(161/1,421), 밖 6%(120/2,038). 이벤트 시간에 공급자가 더 붐빈다는 해석은 추정이고 이 RFC 는 그 위에 서지 않는다.
- Retry-After: 오늘 로그에서 retry_after 값이 붙은 거절은 claude_code 의 주간 한도뿐이다. glm 1302 에는 없었다.

### 1.4 지금 masc 가 하는 것

| 단계 | 어디 | 동작 |
|---|---|---|
| 보내기 전 | `Provider_admission.with_admission` | 엔드포인트마다 선언된 `max-concurrent` 칸을 FIFO 로 나눠 준다. 선언이 없으면 제한 없음. |
| 429 를 받으면 | `Keeper_runtime_failure_route` → `Runtime_lane_preference.note_rate_limit` | 그 런타임 후보에 "밀려났다" 를 적는다(프로세스 공용). |
| 다음 턴 | `Keeper_turn_driver.path_rest` | Retry-After 가 없으면 60초(`rate_limit_backoff_floor_sec`) 쉬고, 레인은 다음 후보로 걷는다. |
| 성공하면 | `note_candidate_success` | 표시를 지운다. 60초 뒤 첫 성공 하나가 표시를 지우면 기다리던 keeper 들이 한꺼번에 들어간다. 한 분에 429 가 3건 이상 몰린 분이 9번 있었다. |

허가 수는 어느 단계에서도 바뀌지 않는다. 공급자가 "줄여라" 고 한 뒤에도 4칸이다.

### 1.5 부하는 어디서 오나

| keeper | 하루 glm 요청 | 턴당 요청 중앙값 / p90 |
|---|---:|---|
| msx-retro-mania | 445 | 37 / 211 |
| polisher | 288 | 6 / 14 |
| goo-yang-bong | 278 | 5 / 78 |
| analyst | 175 | 6 / 29 |

msx-retro-mania 의 211회 턴은 22분 동안 `masc_msx_press` 를 414번 부른 게임 플레이다. 버그가 아니라 그 keeper 의 일이고, glm 트래픽의 20% 다. 이 RFC 는 부하를 줄이지 않는다. 부하가 한도를 넘었을 때 공급자의 말대로 동시 수를 줄이는 것만 한다.

## 2. 제안

### 2.1 규칙

엔드포인트 identity 마다 `declared`(선언값)와 `effective`(유효값) 두 수를 둔다. 처음엔 같다.

| 사건 | 유효값 |
|---|---|
| 그 엔드포인트가 429 를 Retry-After 없이 돌려줌 (`Retry.RateLimited`, `Error.RateLimit`) | `max 1 (effective / 2)` |
| 그 엔드포인트가 429 를 Retry-After 와 함께 돌려줌 | 바꾸지 않는다. 공급자가 시간을 말했으니 경로 휴식이 그 시간을 지킨다. |
| 계정 한도(`HardQuota`, `PaymentRequired`) | 바꾸지 않는다. 동시성 문제가 아니다. |
| 거절 없이 성공이 `recovery_successes`(기본 8)번 이어짐 | `min declared (effective + 1)` |
| 선언값이 바뀜(설정 재적용) | `effective = min effective declared` |

절반 내리고 하나씩 올리는 것은 TCP 의 AIMD 다. 상한을 모르는 상대에게 맞춰 가는 방법으로 이보다 검증된 것이 없다. 8은 시작값이고, 실측 뒤 바꾼다(§5).

### 2.2 어디에 사는가

- `packages/agent_core/lib/llm_provider/slot_scheduler.{ml,mli}`: `max_slots` 를 바꿀 수 있게 한다(`set_capacity`). 줄일 때 이미 든 요청은 내보내지 않는다. 빈 칸이 생길 때만 대기자를 들인다.
- `packages/agent_core/lib/llm_provider/provider_admission.{ml,mli}`: `note_throttled ~config` / `note_completed ~config`. 상태는 지금의 registry entry 에 `effective` 와 `successes_since_throttle` 를 더한다. `snapshot_for` 가 `declared` 와 `effective` 를 함께 준다.
- 신호를 주는 곳: `prepared_completion_request.ml` / `complete.ml` 에서 허가 아래 왕복이 끝난 자리. HTTP 결과가 `RateLimited`(retry_after 없음)면 `note_throttled`, 정상 응답이면 `note_completed`. 그 외는 아무것도 하지 않는다.
- 로그 한 줄: 유효값이 바뀔 때만 `provider_admission_effective_changed` (kind, base_url 정리본, declared, effective, 이유).

### 2.3 선언 우선 원칙과의 관계

`Provider_admission.mli` 는 "AGENT_CORE 는 한도를 고르지 않는다, 소비자가 선언한다" 고 적는다. 이 RFC 는 그 원칙을 바꾸지 않는다. 선언값은 천장이고 masc 는 그 위로 올라가지 않는다. 내려가는 것은 masc 의 추측이 아니라 공급자의 거절이다. 공급자가 요청마다 "지금은 더 못 받는다" 고 말했는데 같은 수를 계속 보내는 것이 원칙에 맞는 일이 아니다.

## 3. 하지 않는 것

- 새 대기·재시도·게이트를 만들지 않는다. 429 뒤 경로 휴식 60초와 레인 걷기는 그대로다.
- 시간 기반 냉각을 넣지 않는다. 유효값은 성공으로만 오른다.
- 공급자 이름으로 분기하지 않는다. 신호는 typed 오류(`RateLimited`)와 헤더 유무다.
- 부하를 줄이지 않는다(msx 의 211회 턴, recall 크기). 별개다.
- Retry-After 가 있는 거절은 손대지 않는다. 그 시간은 이미 지켜진다.

## 4. 검증

단위 테스트(`test_provider_admission.ml` 확장):
1. 429(헤더 없음) 한 번에 4 → 2, 두 번에 → 1, 세 번째도 1.
2. 성공 8번 뒤 1 → 2, 다시 8번 뒤 → 3, 선언값 4 를 넘지 않는다. 사이에 429 가 오면 세던 수는 0 으로.
3. 429 에 Retry-After 가 있으면 유효값 불변.
4. HardQuota 는 유효값 불변.
5. 유효값이 줄어도 이미 허가받은 요청은 그대로 끝난다. 대기자는 빈 칸이 생길 때만 들어간다.
6. 선언값이 2 로 재적용되면 유효값도 2 이하.

라이브(같은 계정, 같은 keeper 구성, 하루):
- `turn_ends_by_selected_model` 의 glm `api_error_rate_limited` 비율. 지금 35%.
- 시스템 로그의 개별 429 사건 수. 지금 158/일.
- glm 완료 턴 수가 줄지 않는지(허가를 줄여서 처리량을 잃으면 실패다). 지금 428/일.
- `snapshot_for` 의 유효값 궤적. 하루 중 어디에 머무는지가 곧 공급자의 진짜 한도다.

## 5. 순서

| 단계 | 내용 | 판정 |
|---|---|---|
| 0 | 설정만: glm-coding 바인딩 `max-concurrent = 4 → 2`, `POST /api/v1/runtime/config/raw` 로 즉시 적용 | 하루 뒤 429 비율과 완료 턴 수. 2 에서 429 가 거의 사라지고 완료가 줄지 않으면 한도는 2~3 이다. |
| 1 | 이 RFC 의 코드 (agent_core 3파일 + 테스트) | §4 단위 테스트, 그 뒤 하루 라이브 |
| 2 | `recovery_successes` 를 실측으로 정한다 | 유효값 궤적이 선언값과 한도 사이에서 톱니를 그리면 값을 키운다 |

0 단계는 코드 없이 오늘 밤 할 수 있다. 1 단계는 0 단계의 결과와 무관하게 필요하다. 한도가 동적이라 어떤 고정값도 내일은 틀린다.

## 6. 위험

- 유효값이 1 까지 내려가면 그 엔드포인트의 처리량이 1/4 이 된다. 그러나 지금은 4칸 중 대부분이 429 로 죽으니 실제 처리량은 그보다 낮다. 회복은 성공 8번마다 한 칸이다.
- 시스템 경로(librarian, judge, board attention)와 keeper 턴이 같은 엔드포인트를 쓰므로 함께 줄어든다. 의도한 바다. 한 계정의 한도는 하나다.
- 다른 프로세스(`sb glm-text`, 다른 세션)가 같은 키를 쓰면 masc 가 보지 못한 동시 요청이 있다. 유효값은 그만큼 더 낮게 안정된다. 그것이 맞는 답이다.
