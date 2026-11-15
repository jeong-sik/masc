---
rfc: "0484"
title: "운영자가 손써야 하는 일은 TUI 꼬리말과 대시보드에 뜬다"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "0482", "provider-path-rest", "librarian-absorb-gate"]
---

# RFC-0484 — 운영자가 손써야 하는 일은 TUI 꼬리말과 대시보드에 뜬다

## 0. 요약

- 2026-11-04 vincent 가 이 방향으로 바로 시작하자고 정했다. §5 의 열린 질문은 해당 층에서 정한다.

- 11-04 에 운영자만 풀 수 있는 문제가 두 번 생겼고, 둘 다 로그에만 남았다.
  - TypeSafe 크레딧이 06:45:51Z 에 떨어졌다. HTTP 402 가 6시간 3분 이어졌고, 충전한 12:48:55Z 에야 풀렸다.
  - Ollama 주간 한도가 00:24Z 에 찼다. Ollama 하나에만 묶인 Keeper 3명은 깨어날 때마다 실패했다. 07:20Z~07:24Z 에 레인을 바꾸고서야 멈췄다.
- MASC 에는 운영자 경보 묶음이 이미 있다. `/health?full=1` 의 `operator_action_required` 와 `operator_action_reasons` 다.
- 비어 있는 곳이 두 군데다.
  - 이 묶음은 외부 판정 서버(TypeSafe)의 거절도, 한도 때문에 못 움직이는 Keeper 도 모른다.
  - TUI 는 이 묶음을 읽지 않는다. 12:59:23Z 에도 `operator_action_required=true` 였지만, TUI 가 읽는 일반 `/health` 에는 이 값이 없다.
- 이 RFC 는 경보 묶음에 두 사실을 더하고, 그 묶음을 TUI 꼬리말에 띄운다. 새 경보 저장소나 확인(ack) 절차는 만들지 않는다.

## 1. 지금

### 1.1 운영자 경보 묶음

- `Server_health_rollup.operator_summary` 가 캐시된 health 섹션의 `status` 를 모아 `overall_status` 를 정한다. 섹션이 `operator_action_reasons` 를 내면 `operator_action_required=true` 가 된다.
- 12:59:23Z 의 실제 값은 `overall_status=warning`, `operator_action_reasons=["keeper_reaction_ledger:reaction_ledger_pending_stimulus","keeper_event_queue:unclassified_backlog=164"]` 였다.
- 이 값은 `/health?full=1` 에만 있다. 일반 `/health` 에는 없다.

### 1.2 TUI

- TUI 는 일반 `/health` 만 읽는다(`bin/masc_tui_http.ml`, `bin/masc_tui.ml`).
- 모든 화면 꼬리말이 `Masc_tui_footer.status_item` 을 함께 쓴다. worktree 빌드로 뜬 서버(`Server_worktree_binary`), 빌드 불일치 같은 사실이 여기에 뜬다. 운영자 경보는 이 목록에 없다.

### 1.3 대시보드

- `dashboard/src` 는 `operator_action_required` 를 Keeper·실행 단위로 정리한다(`store-normalizers.ts`, `keeper-store-normalize.ts`).
- 서버 전체 경보 묶음을 화면 위에 띄우는지는 확인하지 못했다(§5-2).

### 1.4 TypeSafe 판정 서버

- 판정 호출은 `Typesafeai_client.evaluate` 를 지난다. Board attention, absorb gate, Librarian preflight·context review·continuity report, memory recall, workspace memory selection 이 이 함수를 쓴다.
- 실패는 닫힌 타입이다. `refusal = Transport_failure of string | Http_response_failure of { status : int; … }`.
- 서버는 최근 결과를 어디에도 남기지 않는다. 로그 한 줄이 전부다.
- 11-04 에 미친 영향:
  - Jev 가 판정하지 못하자 Board 판정이 `board_attention_exact` 의 첫 슬롯(GLM)으로 넘어갔다. 06:45Z 앞뒤 4시간을 비교하면 15건에서 534건이 됐다.
  - GLM 계정은 시간당 처리량이 거의 고정이라, 그만큼 GLM 을 쓰는 Keeper 턴이 느려졌다.
  - Librarian 기억 반영 41건이 보류됐다.

### 1.5 provider 한도와 Keeper 대기

- 한도 창은 runtime 마다 있다(`Runtime_quota_window`). `/api/v1/runtime/resolved` 는 이것을 `quota_exhausted`·`quota_resets_at` 로 보여 주고, TUI Overview 는 사용률 막대로 보여 준다.
- 레인을 걸을 때 한도가 찬 후보는 뒤로 간다. 모든 후보가 차 있으면 Keeper 는 가장 이른 해제 시각까지 기다린다. 로그에는 `the next dispatch waits 409166s for …` 만 남는다.
- `keeper_waiting_inventory` 는 기다리는 이유를 `waiting_source` 로 나눈다. 큐 대기, HITL, 일정 등이 있다. 한도 때문에 기다리는 경우는 이 타입에 없다. 그래서 11-04 에 4.7일을 기다려야 하던 Keeper 도 이 섹션으로는 나타낼 방법이 없었다.

## 2. 문제

- 1.4 와 1.5 는 코드로 고칠 일이 아니다. 운영자가 손써야 한다. 크레딧 충전, 키 교체, 레인 바꾸기 같은 일이다.
- 운영자가 모르면 아무도 고치지 못한다. 11-04 에는 로그를 직접 뒤지기 전까지 6시간 동안 아무도 몰랐다.
- 그래서 이 경보는 고장을 덮는 장치가 아니다. 고칠 수 있는 사람에게 닿는 길이다. 코드가 고쳐야 할 실패를 세기만 하는 것과는 다르다. 그런 실패는 이 RFC 범위가 아니다.

## 3. 고른 길

### 3.1 기다림 사유에 "후보가 모두 한도 소진" 을 더한다

- `waiting_source` 에 `Runtime_quota_spent` 를 더한다. Keeper 배정(레인 또는 runtime 하나)의 모든 후보가 한도 창이 찬 상태라는 뜻이다.
- 판정에는 이미 있는 상태만 쓴다. 배정, 레인 후보, `Runtime_quota_window` 를 읽는다. 새 저장소는 없다.
- 이런 경우는 들어가지 않는다. 저절로 풀리기 때문이다.
  - 한 후보라도 열려 있는 경우
  - 429 로 잠깐 쉬는 경우
  - 실패 표시(failed attempt)만 있는 경우
- 행에는 가장 이른 해제 시각과 차 있는 runtime 들을 담는다.
- health 투영은 이런 Keeper 가 있으면 `operator_action_reasons` 에 `keeper_waiting_inventory:runtime_quota_spent=<수>` 를 낸다. 대시보드용 행에는 Keeper 이름과 해제 시각이 들어간다.
- 서버가 띄우지 않은 Keeper 는 세지 않는다. 돌지 않는 Keeper 는 실패하지 않는다(§5-4).

### 3.2 `typesafeai` 섹션: 판정 서버의 최근 결과

- 서버는 판정 서버(destination)마다 최근 결과 하나를 프로세스 메모리에 둔다. 담는 값은 셋이다.
  - 마지막으로 답한 시각
  - 지금 이어지는 거절이 시작된 시각
  - 마지막 거절의 종류
- 거절 종류는 `refusal` 에서 바로 나오는 닫힌 타입이다.
  - `Payment_required`: 402
  - `Credential_refused`: 401, 403
  - `Rate_limited`: 429
  - `Server_error`: 5xx
  - `Request_refused`: 그 밖의 4xx
  - `Transport`: 응답을 받지 못함
- 섹션 등급은 둘 중 하나다. 설정된 모든 destination 의 마지막 결과가 거절이면 `degraded`, 아니면 `ok` 다.
- `operator_action_reasons` 에는 `Payment_required` 와 `Credential_refused` 만 넣는다. 예: `typesafeai:payment_required since=2026-11-04T06:45:51Z`.
- 나머지 종류는 `status_reasons` 에만 넣는다. 판정 서버 쪽의 일시적 문제라 운영자가 할 일이 없다.
- 이 기록은 저장하지 않는다. 재시작하면 비고, 다음 판정 호출에서 다시 채워진다. 11-04 에는 판정 호출이 시간당 수백 건이었다.
- 이 섹션은 아무것도 막지 않는다. 판정 경로는 지금과 똑같이 움직인다.

### 3.3 TUI 꼬리말

- 일반 `/health` 에 캐시된 경보 필드 셋을 같이 싣는다. `overall_status`, `operator_action_required`, `operator_action_reasons` 다. 이미 캐시된 값이라 새로 계산하지 않는다.
- 이 필드 셋은 서버 상태를 읽을 수 있는 요청이 받는 `/health` 본문에만 있다. credential 없는 요청이 strict 서버에서 받는 공개 probe 에는 없다. TUI 는 자기 credential 로 읽는다.
- `Masc_tui_footer.status_item` 에 `Operator_action of string list` 를 더한다. `operator_action_required=true` 일 때만 나온다.
- 꼬리말에는 이유의 수와 첫 이유를 보여 준다.

### 3.4 고르지 않은 길

- 새 경보 저장소와 확인(ack) 버튼: 경보 묶음이 이미 있다. 확인 상태는 새로 저장할 사실이 되고, 확인한다고 문제가 풀리지도 않는다.
- 로그 줄에서 경보 만들기: 문자열로 가르는 일이라 하지 않는다.
- Slack·휴대폰 알림: 이번 범위가 아니다. 같은 경보 묶음을 읽는 다른 소비자로 나중에 붙일 수 있다.
- 두 번째 판정 서버(OpenRouter `systemone`)만 넣기: 함께 쓸 수 있는 설정이다. 그래도 모든 서버가 거절하는 경우가 남으니 경보는 필요하다.

## 4. 층

| 층 | 내용 | 확인 |
|---|---|---|
| L1 | `waiting_source` 의 `Runtime_quota_spent` 와 health 투영 | 모든 후보가 찬 Keeper 는 이유 한 줄, 한 후보라도 열려 있으면 없음, 429 쉼은 없음 |
| L2 | `typesafeai` 섹션: destination 별 최근 결과와 등급 | 402 는 `payment_required` 이유, 답하면 사라짐, 503 은 `status_reasons` 에만 |
| L3 | 일반 `/health` 의 경보 필드 셋, TUI 꼬리말 `Operator_action` | `operator_action_required=true` 일 때만 꼬리말에 뜸 |
| L4 | 대시보드가 서버 경보 묶음을 띄우지 않으면 상단 띠 | §5-2 를 확인한 뒤 정함 |

## 5. 열린 질문

1. TUI 가 일반 `/health` 를 얼마나 자주 읽는가. 연결할 때만 읽는다면, 경보 묶음이 바뀔 때 서버가 알려야 한다(RFC-0480 방식).
2. 대시보드가 서버 경보 묶음을 이미 띄우는가. 띄운다면 L1·L2 만으로 대시보드에는 보인다.
3. 경보 이유는 지금 `keeper_event_queue:unclassified_backlog=164` 같은 기계용 문자열이다. TUI 에 그대로 둘지, 사람이 읽을 문장을 따로 둘지 정해야 한다.
4. 서버가 띄우지 않은 Keeper(11-04 의 `kidsnote-job-manager`)도 한도 소진을 알려야 하는가.
