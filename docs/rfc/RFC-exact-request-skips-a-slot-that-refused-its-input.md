---
rfc: "exact-request-skips-a-slot-that-refused-its-input"
title: "exact 요청은 기다리는 slot 이 있는 동안 자기 입력을 거절한 slot 을 다시 부르지 않고, 실행 증거는 요청 본문을 다시 담지 않는다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["exact-lane-waits-for-a-stated-reset", "exact-lane-walks-one-slot-list", "operator-quiz-lane", "host-cycle-runs-exact-requests-side-by-side"]
---

# exact 요청은 기다리는 slot 이 있는 동안 자기 입력을 거절한 slot 을 다시 부르지 않고, 실행 증거는 요청 본문을 다시 담지 않는다

이슈 #51559 의 설계다. 코드 줄 번호는 main `55d2bb205b11` 기준이다.

## 0. 요약

Lane Add-on exact 요청 하나가 끝나지 않고 242번 실행됐다. 실행할 때마다 같은 slot 이 같은 입력을 같은 이유로 거절했다. 그 요청의 실행 증거 파일은 915 MB 가 됐다.

원인은 셋이다.

1. 걷기는 앞 실행을 읽지 않는다. 이 요청의 입력을 거절한 slot 을 host event 마다 다시 부른다.
2. 실행 증거 하나가 요청 본문 전체를 담는다. 증거를 하나 보탤 때 지난 증거 전부를 읽고 다시 쓴다.
3. 요청 기록이 요청 본문과 attempt 목록을 한 파일에 둔다. attempt 한 줄을 보탤 때 본문까지 다시 쓴다.

이 RFC 는 세 층으로 고친다.

| 층 | 바꾸는 것 | 저장 모양 | hard cut |
|---|---|---|---|
| L1 | 기다리는 slot 이 있는 동안, 이 요청의 입력 크기를 거절한 slot 을 이 요청으로 다시 부르지 않는다 | 그대로 | 없음 |
| L2 | 실행 증거가 요청 본문 대신 digest 를 담는다. 증거는 attempt 마다 파일 하나다 | 바뀜 | 필요 |
| L3 | 요청 본문을 요청 기록 밖에 한 번만 저장한다 | 바뀜 | 필요 (L2 와 같이) |

L1 은 이 문서에서 구현할 수 있을 만큼 정한다. L2·L3 은 방향과 풀어야 할 것만 정한다(§3.3, §3.4). 구현 전에 그 절을 채워 다시 리뷰받는다.

측정한 240번 가운데 219번은 다른 slot 이 기다리는 중이었다. L1 은 그 경우의 되풀이를 멈춘다. 기다리는 slot 없이 열려 있는 요청의 되풀이는 덮지 않는다(§3.5, §9 D4). L1 뒤에도 실행마다 요청 기록과 증거를 읽고 `Deferred` 한 줄을 쓴다. L2·L3 은 그 읽기와 쓰기를 요청 크기와 무관하게 만든다. attempt 목록이 trigger 마다 늘어나는 것은 #50762 가 다룬다. 이 RFC 는 그 목록의 길이를 줄이지 않는다.

## 1. 측정 (2026-11-12, 라이브 저장소를 읽기만 함)

출처는 `lane-addons/exact-requests` 의 요청 기록, `lane-addons/host-results` 의 실행 증거 파일, system log 의 `Lane Add-on exact attempt ended` 줄이다. 개수와 크기는 스크립트로 셌다.

| 항목 | 값 | 시각(UTC) |
|---|---|---|
| 열린 `classification` 요청의 메시지 | 1개, 2,173,367자 | 06:52 |
| 요청 기록 파일 | 3.87 MB | 06:39 |
| attempt 수 | 241 → 244 → 246 | 06:39 → 06:52 → 06:56 |
| 실행 증거 파일 | 915 MB (실행 242개) → 930 MB | 06:45 → 06:56 |
| 실행 증거 하나의 크기(중앙값) | 6.1 MB | 06:45 |
| 서버 재시작 뒤 102분 동안의 실행 | 22번, 한 번에 27~224초, 합 1,663초 | 04:55~06:37 |

attempt 240개를 slot 별로 센 결과다. slot 은 runtime 계열로만 적는다.

| slot | 결과 | 횟수 |
|---|---|---|
| glm 계열 | 불렀고 `context_overflow` 로 거절 | 240 |
| opencode 계열 | 안 불렀다. provider 가 말한 시각(`2026-11-16T00:00Z` 근처)까지 기다린다 | 219 |
| opencode 계열 | 불렀고 `rate_limited` 로 거절 | 21 |

재지 못한 것: 한 번의 27~224초 가운데 증거 파일을 읽고 쓴 몫, 그동안 서버의 다른 fiber 가 멈췄는지, 241번이 며칠에 걸친 것인지(attempt 에 시각이 없다).

같은 저장소에 `provider_unavailable` attempt 865개 뒤에 끝난 기록과 223개 뒤에 끝난 기록이 있다.

## 2. 지금 구조

### 2.1 걷기의 끝

`ending`(`lib/server/server_lane_addon_exact.ml:29-58`)은 slot 별 실패를 모아 호출의 끝을 정한다.

- 다시 지나갈 수 있는 실패(`Transient`, `Auth_refused`, `Configuration_refused`)가 하나라도 있으면 `Call_refused` 다. 요청은 열린 채로 남는다.
- 그런 실패가 없고 입력 거절이 있으면 `Call_ended (Input_refused …)` 다. 요청이 끝난다.

기다리는 slot 은 부르지 않고 `Transient` 실패로 적는다(`:190-195`). RFC-exact-lane-waits-for-a-stated-reset R5 가 정한 동작이다. 그래서 부른 slot 이 모두 입력을 거절해도, 기다리는 slot 이 하나 있으면 요청은 열려 있다. 기다리는 slot 이 그 입력을 받을 수도 있으니 맞는 판단이다.

기다리는 slot 이 하나라도 있으면 걷기는 입력 거절로 끝날 수 없다. 답을 받아 끝나거나 `Call_refused` 로 열려 있다. L1 은 이 성질 위에 선다.

입력 거절은 세 곳에서 나온다. provider 의 거절(`Exact_lane_failure.refusal`, `lib/server/exact_lane_failure.ml:31-40`), 보낸 뒤의 실패(`completion`, `:68`), 보내기 전 로컬 거절(`candidate`, `:84-89`)이다. 종류는 `Request_body`, `Invalid_request`, `Context_overflow`, `Input_capacity` 넷이다.

넷이 같은 성질은 아니다.

- `Invalid_request` 는 본문만으로 정해지지 않는다. HTTP 400·422 와, 따로 분류되지 않은 상태 코드(408·409·425 등)가 모두 이 종류가 된다(`packages/agent_core/lib/llm_provider/retry.ml:370-389`).
- 로컬 거절의 `Input_capacity` 는 둘로 갈린다. window 초과와 용량 거절은 입력 거절이다. 토큰 측정이 필요하거나 용량 증거가 낡은 경우는 `Transient` 다(`exact_lane_failure.ml:85-89`).

### 2.2 열린 요청을 다시 실행하는 것

host cycle 은 `wake_host` 가 불릴 때 돈다(`lib/lane_addon/lane_addon_runtime.ml:589`). 부르는 곳은 다섯이다: worker 초기화, 설치의 lane 이 바뀐 registry 발행, 끝난 action receipt, worker tool 의 응답, 운영자의 답. 시간으로 깨우지 않는다.

cycle 은 열린 요청마다 `Lane_addon_exact.run` 을 부른다. `run` 은 기록이 열려 있으면 runner 를 다시 부른다(`lane_addon_exact.ml:1078-1106`). runner 는 부를 때마다 slot 순서를 새로 계산한다(`server_lane_addon_exact.ml:294`). 앞 실행의 결과는 어디에서도 읽지 않는다.

모든 slot 이 기다리면 runner 는 호출을 만들지 않고 `Every_slot_held { until }` 을 돌려준다(`:277-299`). 그 판단은 slot 이 지금 기다리는지만 본다.

### 2.3 실행 증거

`run` 은 provider 를 부른 실행마다 증거를 남긴다. 거절된 호출(`Call_refused`)도 남긴다(`lane_addon_exact.ml:1143-1151`).

- 증거 하나(`proof_to_json`, `:667-673`)는 `request` 칸에 요청 전체를 담는다. `digest` 칸도 따로 있다.
- 한 요청의 증거는 파일 하나(`executions` 목록)에 모인다(`proofs_to_json`, `:714-717`).
- `retain_proof`(`:804-826`)는 파일 전체를 읽어 모든 증거를 decode 하고, 하나를 보태 전체를 쓰고, 다시 읽어 견준다.
- `run` 은 시작할 때도 전체를 읽는다(`bound_proofs`, `:1017-1018`).

거절된 호출 한 번에 증거 파일을 세 번 읽고 한 번 쓴다. n번째 실행의 쓰기는 n × (요청 크기)다.

증거의 `request` 를 읽는 곳은 셋이다.

- `decode_proof`: 저장된 증거를 호출자의 요청으로 다시 만든 것과 견준다(`:706-709`).
- `proof_request_id`: `executions[0].request` 로 digest 를 다시 계산해 파일 이름과 견준다(`:755-768`). 시작 때의 sweep(`server_unowned_exact_sweep.ml:91-114`)이 쓴다.
- `scripts/tinker/librarian/check_validator_on_store.py:301-314`: `request.output` 과 `request_id` 를 읽는다.

셋 다 요청의 정체를 확인한다. 본문의 내용을 쓰는 곳은 없다.

### 2.4 요청 기록

기록(`record`, `:450-455`)은 `{digest; request; attempts; final}` 이다. 거절된 호출 한 번에 두 번 쓴다(`Started` `:1091`, 그 자리를 바꾸는 `Deferred` `:1168`). 쓸 때마다 요청 본문이 같이 나간다.

증거는 attempt 의 위치에 묶인다. ordinal n 의 증거는 `attempts` 의 n번째 항목과 맞아야 한다(`proof_matches_attempt`, `:774-791`). 그래서 attempt 를 지우거나 합치면 증거가 다른 attempt 에 묶인다.

### 2.5 walk receipt 가 이미 가진 것

증거의 `receipt`(`lib/keeper/keeper_exact_walk_receipt.ml`)는 slot 별 결과를 타입으로 담는다.

- `http.declared` 는 걸은 slot 의 `{candidate_id; catalog_generation; catalog_evidence; target}` 이다. `target` 은 `Exact_output.target_identity_fingerprint` 다.
- `excluded_http` 는 걷지 않은 slot 의 id 목록이다. 지금은 기다리는 slot 이 들어간다.
- slot 의 실패(`failed`)는 `Rejected { visit; disposition; detail }`(로컬 거절)이거나 `Execution_failed { visit; cause; raw_sha }` 다.
- `cause` 는 `api_observation`(`keeper_exact_walk_failure.ml:107`)이다. provider 의 거절은 `Provider_refused { http_status; refusal }` 이고 `refusal` 은 닫힌 타입이다.

receipt 쪽에는 관측 하나를 가르는 함수가 이미 있다. `of_api_observation`(`keeper_exact_walk_failure.ml:165-176`)은 provider 의 거절 `Context_overflow`, `Input_capacity`, `Request_body_refused` 셋을 "provider 가 입력 크기를 거절함"으로 가른다. 보낸 뒤의 실패 둘(`Context_overflow_failure`, window 에서 멈춘 빈 답 `Empty_completion Context_window_exceeded`)도 같은 갈래다(`:153-156`). `Invalid_request` 와 `Timeout` 은 그 갈래가 아니다.

그 갈래의 출처는 이렇다.

- `Context_overflow` 는 provider 의 오류 코드나 window 에서 멈춘 빈 답에서 온다. receipt 는 둘을 가르지 않는다.
- `Request_body_refused` 는 HTTP 413 이다. 상태 코드만으로 정한다(`retry.ml:372-380`). base url 앞의 gateway 도 낼 수 있다.
- provider 의 `Input_capacity` 는 `Retry.InputCapacity` 에서 온다(`exact_output.ml:863`). 응답을 가르는 `classify_error`(`retry.ml:355-390`)는 그 값을 만들지 않는다.
- window 에서 멈춘 빈 답은 걷기 쪽에서는 `Output_unusable` 이다(`exact_lane_failure.ml:63-67`). 두 쪽의 갈래가 이 한 경우에 다르다.

Librarian 의 `check_size` 는 합친 값의 `refuses_input_capacity` 를 본다(`keeper_librarian_admission_parts.ml:252`). 로컬 거절도 그 조건을 채운다.

receipt 가 담지 못하는 것도 있다. 로컬 거절의 `disposition` 은 `Input_capacity _` 의 네 경우를 `Local_input_capacity` 하나로 합친다(`keeper_exact_walk_failure.ml:204-205`). 입력 거절인 둘과 `Transient` 인 둘을 receipt 에서 타입으로 가를 수 없다.

"어느 slot 이 이 요청의 입력 크기를 거절했는가"는 provider 를 부른 실패에 한해 이미 저장돼 있다. slot 별로 읽는 함수가 없을 뿐이다. `failure_evidence` 와 `exhausted_input_refusals` 는 걷기 전체를 합친 값만 돌려준다.

### 2.6 끝난 요청의 증거를 읽는 쪽

소비자는 끝난 요청의 가장 최근 증거 하나를 읽는다.

- Librarian 의 `check_size` 는 `Input_refused` 로 끝난 요청의 receipt 에서 입력 크기 거절을 찾는다. 없으면 나누기를 거절한다(`keeper_librarian_admission_parts.ml:246-259`).
- workspace-curator 의 `narrow` 는 끝의 종류만 읽고 묶음을 반으로 나눈다.

그래서 `Input_refused` 로 끝나는 걷기는 그 거절을 자기 receipt 에 담아야 한다. 아무 slot 도 부르지 않은 걷기는 요청을 끝낼 수 없다는 `ending` 의 주석(`server_lane_addon_exact.ml:31-33`)과 같은 요구다.

## 3. 설계

### 3.1 계약

- **C1.** 한 요청에서, 기다리는 slot 이 있는 동안, 그 요청의 입력 크기를 거절한 slot 은 그 요청으로 다시 불리지 않는다.
- **C2.** slot 이 같은지는 slot id, target fingerprint, 보내는 schema 로 본다. 셋 중 하나가 바뀌면 다시 부른다.
- **C3.** 거절의 근거는 그 요청의 보관된 실행 증거다. 그 slot 을 부른 가장 최근 증거가 정한다. 메모리의 표나 글에서 읽어 내지 않는다.
- **C4.** 어느 slot 도 lane 목록에서 지우지 않는다. C1 은 요청 하나와 slot 하나 사이의 사실이다. 다른 요청은 그 slot 을 그대로 부른다.
- **C5.** L1 은 답 없이 끝나는 걷기를 바꾸지 않는다. `Input_refused` 로 끝나는 걷기는 지금과 같은 slot 을 부르고 같은 receipt 를 남긴다. 답으로 끝나는 걷기의 receipt 에는 건너뛴 slot 이 `excluded_http` 로 남을 수 있다.
- **C6.** 실행 증거를 하나 보태는 비용은 지난 실행 수와 요청 크기에 비례하지 않는다.
- **C7.** 요청 본문은 한 번 저장한다.

C1 은 시간으로 상태를 죽이지 않는다(헌법 `no_wall_clock_death`). 근거는 일어난 거절이다.

C1 이 맞는 이유는 `ending` 이다. 기다리는 slot 이 있으면 걷기는 입력 거절로 끝나지 않는다(§2.1). 그동안 거절한 slot 을 다시 불러서 달라질 수 있는 결과는 "이번에는 답한다" 하나다. 본문은 digest 로 고정이다. target 과 schema 가 같으면 보내는 요청에서 달라질 수 있는 것은 lane 의 `max_output_tokens` 와 `thinking` 이다. 이 둘은 fingerprint 뒤에 lane 이 덧씌운다(`lib/runtime/runtime_exact_output_registry.ml:683-696`, `exact_output_resolver.ml:968-976`). 증거에도 receipt 에도 값이 없어서 견줄 수 없다. 운영자가 그 둘을 바꿔도 기다림이 끝날 때까지 그 slot 은 건너뛰어진다(§9 D1 의 대가).

C5 는 §2.6 에서 나온다. 기다리는 slot 이 없으면 아무것도 건너뛰지 않는다. 그래서 `Input_refused` 로 끝나는 걷기의 receipt 는 지금처럼 모든 slot 의 거절을 담는다.

### 3.2 L1 — 기다리는 slot 이 있는 동안 건너뛴다

**건너뛰는 거절.** `of_api_observation` 이 "provider 가 입력 크기를 거절함"으로 가르는 관측만이다(§2.5). 새 분류를 만들지 않는다.

| 거절 | 건너뛰나 | 이유 |
|---|---|---|
| provider 의 `Context_overflow`, `Input_capacity`, `Request_body_refused` | 건너뛴다 | 본문 크기와 target 으로 정해진다 |
| 보낸 뒤의 `Context_overflow_failure`, window 에서 멈춘 빈 답 | 건너뛴다 | 같은 갈래다 |
| provider 의 `Invalid_request` | 다시 부른다 | 408·409·425 같은 상태 코드가 섞여 있다 |
| 로컬 거절(`Rejected`), 보내지 않은 실패(`sent=false`) | 다시 부른다 | provider 의 답이 아니다. 로컬 거절은 receipt 가 종류를 합쳐 담는다 |
| 그 밖의 실패 | 다시 부른다 | 지금과 같다 |

**증거 하나에서 slot 하나를 읽는 법.** 결과는 셋 중 하나다.

| 결과 | receipt 의 모양 |
|---|---|
| 입력 크기 거절 | slot 의 binding 이 있고, 보낸 요청의 실패가 위 갈래다 |
| 다른 답 | 보낸 요청이 답했거나 다른 실패로 끝났다 |
| 알 수 없음 | slot 이 `excluded_http` 에 있다. slot 이 receipt 에 없다. `declared_http` 에는 있는데 binding 이 없다(HTTP 흐름이 시작되지 않음). 걷기가 그 slot 앞에서 멈췄다. 방문했는데 결과가 없다. 로컬 거절이다. 보내지 않은 실패다 |

"알 수 없음"이면 그 앞 증거를 본다. provider 가 이 본문에 한 가장 최근 답이 정한다. 읽는 함수는 `advances` 와 `terminal` 의 실패를 모두 본다. `terminal_failure` 가 빼는 `Locally_stopped (Before_advance _)` 안의 실패도 본다(`keeper_exact_walk_receipt.ml:148-150`).

**순서.**

1. `Keeper_exact_walk_receipt` 에 위 표대로 읽는 함수를 하나 더한다. 가르는 일은 `of_api_observation` 이 한다.
2. `run` 은 이미 읽은 증거(`bound_proofs`)를 최근 것부터 본다. slot 마다 "알 수 없음"이 아닌 첫 증거가 정한다. 그 증거가 입력 크기 거절이고 증거의 `schema` 가 이번에 보낼 schema 와 같으면 `(candidate_id, target)` 을 목록에 넣는다. schema 는 runner 를 부르기 전에 있다(`lane_addon_exact.ml:1054-1056`). 증거의 schema 는 canonical 이니 이번 것도 `Lane_addon_action.canonical` 을 거쳐 견준다. canonical 로 만들지 못하면 목록에 넣지 않는다. 목록을 runner 에 넘긴다. `runner` 타입에 인자가 하나 는다.
3. 빼는 자리는 `runner_with` 의 `order` 와 `every_slot_held` 사이다(`server_lane_addon_exact.ml:294-295`). `ordered.held_http` 가 비어 있지 않을 때만 `lane.selected_slots` 에서 `candidate_id` 와 `target` 이 같은 slot 을 뺀다. 뺀 `ordered` 를 `every_slot_held` 와 `call` 에 같이 넘긴다. `call` 안에서 빼면 `every_slot_held` 가 그 slot 을 걸을 slot 으로 세어, 실행마다 시작 표시와 증거가 남는다.
4. 기다리는 slot 은 `selected_slots` 에 없으니 목록에 있어도 빠지지 않는다. 기다리는 slot 으로만 다뤄진다.
5. `call` 은 실제로 뺀 slot 의 id 를 받아 receipt 의 `declared_http` 와 `excluded_http` 끝에 붙인다. 기다리는 slot 과 같은 자리다. 빼지 않은 slot 을 붙이면 `make_v2` 가 거절한다(`keeper_exact_walk_receipt.ml:188-199`). 실패 목록에는 적지 않는다. 기다리는 slot 의 `Transient` 가 요청을 열어 둔다.
6. 걸을 HTTP slot 도 CLI slot 도 없으면 `every_slot_held` 가 지금 코드 그대로 `Some until` 을 돌려준다. runner 는 `Every_slot_held { until }` 이다. 시작 표시도 증거도 없다. `run` 은 `Deferred` 한 줄을 보태 요청 기록을 다시 쓴다(`lane_addon_exact.ml:1103-1106`).
7. 걸을 HTTP slot 이 없고 CLI slot 이 있으면 `execute_http` 는 `Http_exhausted` 를 돌려주고(`server_lane_addon_exact.ml:79-80`) CLI slot 을 걷는다.

`run` 이 증거를 읽지 못하면 지금처럼 runner 를 부르지 않는다.

`Every_slot_held` 의 뜻이 "부를 slot 이 없고 기다리는 slot 이 있다"로 넓어진다. 그 뜻을 적은 곳을 고친다: `lane_addon_exact.mli`, `server_lane_addon_exact.mli:26`, `keeper_memory_execution_availability.ml:125-127` 의 주석, TUI 글, dashboard 글(`dashboard/src/components/lane-addon-host-requests.ts:18`). variant 는 더하지 않는다(§9 D2).

L1 은 저장 모양을 바꾸지 않는다. receipt 의 version 과 칸이 그대로다.

### 3.3 L2 — 실행 증거 (방향)

- 증거는 `request` 칸을 갖지 않는다. `digest`, `request_id`, `declaration_id` 가 요청을 가리킨다.
- 증거는 attempt 마다 파일 하나다. 한 번 쓰고, 같은 key 에 다른 내용을 쓰면 거절한다. slot 관측 companion 이 이미 쓰는 방식이다(`lane_addon_exact_observation.ml`, key 는 `[request_id, attempt_ordinal, proof_sha256]`).
- `decode_proof` 는 호출자의 요청에서 digest 를 계산해 증거의 `digest` 와 견준다.
- sweep 의 `proof_request_id` 는 증거의 `request_id` 와 `digest` 칸으로 파일 이름을 확인한다.
- tinker 스크립트는 `request.output` 으로 증거를 거른다. output 이름은 요청 기록에서 읽게 고친다.

구현 전에 정할 것:

- L1 은 "그 slot 을 부른 가장 최근 증거"를 찾는다. 파일이 나뉘면 최근 증거부터 거슬러 읽는다. 그 slot 이 `excluded_http` 에 있는 증거는 넘어간다. 읽는 파일 수는 그 slot 을 건너뛰고 다른 slot 을 부른 걷기의 수다. 아무도 부르지 않은 걷기는 증거가 없으니 측정한 경우에는 하나다.
- 지금 `.mli` 는 `bind_proofs` 가 한 요청의 증거 전체를 attempt 목록과 견준다고 약속한다. 증거를 보탤 때 전체를 읽지 않으려면 그 약속을 어디로 옮길지 정한다. ordinal 이 늘기만 하고 앞자리에 끼워 넣지 못한다는 검사도 같이다.
- preflight 는 요청 기록만 본다. 옛 모양 증거가 남아 있으면 시작 때의 sweep 이 전체를 멈춘다. preflight 가 증거 모양도 보게 한다.
- 증거 디렉터리는 `.json` 파일만 둔다. sweep 은 다른 종류의 항목이 있으면 전체를 멈춘다(`server_unowned_exact_sweep.ml:54-75`).
- 본문을 뺀 증거 하나의 크기는 재지 않았다. 지금 중앙값 6.1 MB 에서 요청 기록 3.87 MB 를 뺀 나머지가 무엇인지 L2 전에 센다.

### 3.4 L3 — 요청 기록 (방향)

- 요청 본문은 digest 를 이름으로 한 파일에 한 번 저장한다. `save_tool_request_body`(`lane_addon_store.ml:870`)와 같은 방식이다.
- 요청 기록은 `{digest; attempts; final}` 이다.
- `run` 은 호출자가 넘긴 요청에서 digest 를 계산해 기록과 견준다. 본문 파일은 요청을 다시 읽어야 하는 곳만 연다.

구현 전에 정할 것:

- 본문 파일을 두는 디렉터리. sweep 은 `exact-requests` 의 낯선 이름을 지우고, 하위 디렉터리가 있으면 멈춘다.
- 본문 파일을 지우는 곳과 읽는 곳. 요청 기록이 지워질 때 본문이 남지 않아야 한다.

attempt 목록은 그대로 한 파일이다. 항목 하나는 수백 바이트다. 목록의 길이는 #50762 에서 다룬다.

### 3.5 하지 않는 것

- slot 을 시간이나 횟수로 쉬게 하지 않는다.
- 같은 model 을 쓰는 다른 slot 의 거절로 미루어 판단하지 않는다. slot 마다 자기 답을 받는다.
- `detail` 글에서 slot 이름이나 거절 종류를 읽지 않는다.
- 깨우는 장치를 더하지 않는다. host event 는 지금의 다섯 그대로다.
- attempt 를 지우거나 합치지 않는다.
- receipt 에 칸을 더하지 않는다. 로컬 거절을 가르려면 칸이 필요하고, 그것은 저장 모양을 바꾸는 일이다.
- 기다리는 slot 없이 열려 있는 요청은 건너뛰지 않는다. 다른 slot 이 시각 없는 429, 5xx, 인증 거절로 실패하는 경우다. 그 slot 의 결과는 걷기 전에 알 수 없다. 덮으려면 걷기가 "지나갈 수 있는 실패가 나오면 거절한 slot 앞에서 멈춘다"를 알아야 한다(§9 D4).
- CLI slot 은 건너뛰지 않는다. 기다리는 CLI slot 도 "기다리는 slot" 으로 세지 않는다. 기다리는 HTTP slot 은 걷기 전에 `Transient` 로 적힌다(`server_lane_addon_exact.ml:190-195`). 기다리는 CLI slot 은 CLI 걷기에 닿아야 적힌다(`keeper_lane_cli_oneshot.ml:479-484`). HTTP 걷기가 `Http_stopped` 로 끝나면 CLI 걷기에 닿지 않는다(`server_lane_addon_exact.ml:224`). 그래서 A 가 거절하고 CLI slot 만 기다리는 lane 의 되풀이는 덮지 않는다.

## 4. 순서

slot A 는 요청보다 context window 가 작다. slot B 는 계정 한도로 기다린다. 둘 다 HTTP slot 이다.

| 틱 | 지금 | L1 뒤 |
|---|---|---|
| N | A 를 부른다. 입력 크기 거절. B 는 기다린다. 요청은 열려 있다. 증거 1 | 같다 |
| N+1 | host event. A 를 다시 부른다. 같은 거절. 증거 2 | B 가 기다리니 A 를 건너뛴다. 부를 slot 이 없어 `Every_slot_held`. 호출도 증거도 없다 |
| N+M | B 의 시각까지 같다. 실행마다 증거 파일이 요청 크기만큼 는다 | 같다. 실행마다 요청 기록과 증거를 읽고, `Deferred` 한 줄을 보태 요청 기록을 다시 쓴다 |
| B 의 시각 뒤 | A 와 B 를 부른다 | 같다. 기다리는 slot 이 없으니 건너뛰지 않는다 |
| …B 가 답한다 | 끝 | 같다 |
| …B 도 입력을 거절한다 | `Input_refused` 로 끝. receipt 에 A, B 의 거절 | 같다 |
| …B 가 새 시각을 말한다 | 다음 실행부터 A 를 다시 부른다 | 다음 실행부터 A 를 건너뛴다 |
| 서버 재시작 뒤 기다림 표가 비었다 | A, B 를 부른다 | 같다. B 가 다시 시각을 말하면 그다음부터 A 를 건너뛴다 |
| 운영자가 A 의 target 을 바꾼 뒤 | A 를 부른다 | fingerprint 가 달라 A 를 부른다 |
| 운영자가 B 를 lane 에서 뺀 뒤 | A 를 부르고 `Input_refused` 로 끝 | 같다. receipt 에 A 의 거절이 있다 |

기다림 한 번마다 A 를 부르는 횟수가 "host event 수"에서 "한 번"으로 준다.

- **context window 가 다른 failover.** A 가 거절하고 B 가 시각 없는 `rate_limited` 면 B 는 기다리는 slot 이 아니다. 다음 실행은 지금처럼 A 와 B 를 부른다. L1 이 덮지 않는 경우다(§3.5).
- **CLI Official Client → API Client → Official Client.** HTTP slot 을 다 걸은 뒤 CLI slot 을 걷는 순서는 그대로다. HTTP slot 하나가 기다리고 다른 HTTP slot 이 입력을 거절했으면, 다음 실행은 CLI slot 만 걷는다. CLI slot 이 답하면 요청이 끝나고, 그 receipt 에 건너뛴 slot 이 `excluded_http` 로 남는다.
- **운영자가 lane 의 `max_output_tokens` 나 `thinking` 을 바꿀 때.** slot id, fingerprint, schema 가 그대로라 L1 은 같은 slot 으로 본다. 기다림이 끝날 때까지 그 slot 을 건너뛴다. 바로 다시 부르게 하려면 기다리는 slot 을 lane 에서 빼거나 그 slot 의 target 을 바꾼다.
- **계정이 다른 같은 model.** slot 이 다르면 각자 답한다. 미루어 판단하지 않는다.
- **다계정에서 계정을 바꿀 때.** fingerprint 는 credential 의 종류만 담고 값은 담지 않는다. 같은 slot id 에서 키만 바꾸면 L1 은 같은 slot 으로 본다. 그 요청은 기다림이 끝날 때 그 slot 을 다시 부른다.
- **여러 Keeper 가 한 설치를 쓸 때.** 끝나지 않는 요청이 실행 자리를 쓰는 시간에서 provider 호출과 증거 쓰기가 빠진다. 요청 기록과 증거를 읽는 시간, 요청 기록을 쓰는 시간은 남는다. 다른 Keeper 의 요청이 기다리는 시간이 그만큼 준다(#51199).
- **입력을 나누는 쪽.** `Input_refused` 는 기다리는 HTTP slot 이 없을 때만 나온다. 그때는 건너뛰지 않으니 workspace-curator 와 Librarian 이 읽는 receipt 가 지금과 같다(C5).
- **건너뛴 slot 이 이제는 답할 수 있을 때.** provider 가 같은 target 의 한도를 올린 경우다. 그 답은 기다림이 끝날 때까지 늦는다. 틀린 끝은 생기지 않는다.

## 5. hard cut (L2·L3)

L2 와 L3 은 증거와 기록의 모양을 바꾼다. 옛 모양을 읽는 코드는 만들지 않는다(헌법 `legacy_residue`). `check_retained_record` 는 옛 기록을 거절한다(`lane_addon_exact.mli:289-291`).

설치할 때 지우는 것: `lane-addons/exact-requests`, `lane-addons/host-results` 의 exact 증거와 slot 관측, 그리고 그 요청을 원본으로 든 소비자 쪽 기록이다. 소비자는 Librarian(접수 part, durable 원본), workspace-curator, Candle appraiser, operator quiz 다.

2026-11-12T06:39Z 의 요청 기록은 열린 것 6개, 끝난 것 134개였다. 지울 소비자 쪽 기록의 수는 세지 않았다. L2·L3 을 시작하기 전에 센다.

L1 은 hard cut 이 없다.

## 6. 시험

단언은 부른 횟수와 receipt 로 쓴다. "고치기 전" 칸이 다른 행은 고치기 전 동작에서 실패해야 한다.

| 층 | 시험 | 고치기 전 |
|---|---|---|
| L1 | A 가 입력 크기를 거절하고 B 가 기다리는 요청을 두 번 실행하면 A 는 한 번 불린다 | 두 번 |
| L1 | 두 번째 실행은 `Every_slot_held` 이고 증거가 늘지 않는다 | `provider_unavailable`, 증거 둘 |
| L1 | B 의 기다림이 끝나면 A 와 B 를 둘 다 부른다. 둘 다 입력을 거절하면 `Input_refused` 로 끝나고 receipt 에 두 거절이 있다 | 같다 (그대로여야 한다) |
| L1 | A 의 target fingerprint 가 바뀌면 B 가 기다려도 A 를 부른다 | 해당 없음 |
| L1 | package schema 가 바뀌면 B 가 기다려도 A 를 부른다 | 해당 없음 |
| L1 | A 를 부른 가장 최근 증거가 `rate_limited` 면 A 를 부른다 | 같다 |
| L1 | A 가 `Invalid_request` 로 거절한 요청은 B 가 기다려도 A 를 다시 부른다 | 같다 |
| L1 | A 가 기다리면서 입력 거절 증거도 있으면 기다리는 slot 으로만 적는다. 예외가 나지 않는다 | 해당 없음 |
| L1 | A 를 부른 증거 뒤에 A 가 로컬 거절된 증거가 있으면 앞 증거가 정한다 | 해당 없음 |
| L1 | B 가 기다리고 A 를 건너뛴 걷기에서 CLI slot 이 답하면 요청이 끝나고 receipt 의 `excluded_http` 에 A, B 가 있다 | A 를 부른다 |
| L2 | 증거를 n개 남긴 뒤 하나를 더 남길 때 쓰는 바이트가 n 과 요청 크기에 따라 늘지 않는다 | 는다 |
| L2 | 다른 요청의 digest 를 든 증거는 거절한다 | 본문 비교로 거절 |
| L3 | attempt 를 보탤 때 요청 본문 파일을 다시 쓰지 않는다 | 다시 쓴다 |

## 7. 층

| 층 | 내용 | 파일 |
|---|---|---|
| L1a | receipt 하나에서 slot 별로 불렀는지와 입력 크기 거절인지를 읽는 함수와 시험 | `keeper_exact_walk_receipt.ml`·`.mli` |
| L1b | `run` 이 증거에서 목록을 모아 runner 에 넘긴다. runner 가 기다리는 slot 이 있을 때 건너뛴다 | `lane_addon_exact.ml`·`.mli`, `server_lane_addon_exact.ml`, TUI·dashboard 글 |
| L2 | attempt 마다 증거 파일 하나, `request` 칸 없음 | `lane_addon_exact.ml`, `lane_addon_exact_observation.ml`, `server_unowned_exact_sweep.ml`, preflight, tinker 스크립트 |
| L3 | 요청 본문을 기록 밖으로 | `lane_addon_exact.ml`, `lane_addon_store.ml`, preflight |

L1a 는 부르는 곳이 L1b 다. 둘을 한 스택으로 올린다.

## 8. 대안

| 대안 | 고르지 않은 이유 |
|---|---|
| 걷기의 끝을 바꿔, 부른 slot 이 모두 입력을 거절하면 기다리는 slot 이 있어도 요청을 닫는다 | 기다리는 slot 이 받을 수 있는 입력까지 버린다. RFC-exact-lane-waits-for-a-stated-reset R5 를 뒤집는다 |
| 열린 요청을 시각 전에는 다시 실행하지 않도록 기록에 시각을 둔다 | 새 상태다. 기다림은 runner 가 부를 때마다 다시 판단하게 돼 있다. 재시작 뒤에는 표가 비니 저장한 시각이 틀릴 수 있다 |
| 거절한 slot 을 메모리 표에 둔다 | 재시작하면 사라져 다시 부른다. 증거가 이미 디스크에 있다 |
| 실행 횟수에 상한을 둔다 | 근거 없는 수다. 지나갈 수 있는 요청을 죽인다 |
| L2 만 한다 | 증거는 작아지지만 같은 slot 을 계속 부른다. 큰 본문을 provider 로 계속 보낸다 |
| 거절된 호출의 증거를 남기지 않는다 | 헌법 `failure_keeps_evidence` 에 어긋난다. L1 의 근거도 사라진다 |
| 기다리는 slot 이 없어도 건너뛰고, 모든 slot 이 거절했으면 아무도 부르지 않고 `Input_refused` 로 끝낸다 | 끝난 요청의 receipt 에 거절이 없다. Librarian 의 `check_size` 가 나누기를 거절하고 그 part 가 멈춘다(§2.6) |
| 건너뛴 slot 의 지난 거절을 새 receipt 에 옮겨 담는다 | receipt 에 칸이 는다. 저장 모양이 바뀌고 읽는 쪽을 같이 고쳐야 한다. 기다리는 동안만 건너뛰면 필요 없다 |
| `Invalid_request` 와 로컬 거절도 건너뛴다 | 본문만으로 정해지지 않는 거절이 섞여 있다(§2.1). 로컬 거절은 receipt 에서 타입으로 가를 수 없다(§2.5) |

## 9. 사용자 결정

| | 결정 | 추천 | 계약 | 대가 |
|---|---|---|---|---|
| D1 | slot 이 같은지 무엇으로 보나 | slot id, target fingerprint, 보내는 schema | C2 | 셋이 덮지 않는 것이 바뀌어도 그 slot 은 기다림이 끝날 때에야 다시 불린다. lane 의 `max_output_tokens`·`thinking`, credential 값, provider 가 같은 target 에서 올린 한도, gateway 의 본문 한도가 그렇다. 측정한 경우 그 기다림은 나흘이다. 바로 부르게 하려면 운영자가 기다리는 slot 을 lane 에서 빼거나 target 을 바꾼다. lane 의 두 값까지 견주려면 증거에 칸을 더해야 한다(저장 모양 변경) |
| D2 | L1 에서 `Every_slot_held` 의 뜻을 넓히나, variant 를 더하나 | 뜻을 넓힌다 | §3.2 6번 | TUI·dashboard 의 "모든 slot 이 기다림" 글을 "부를 slot 이 없고 기다리는 slot 이 있음"으로 고친다. 기다리는 slot 과 건너뛴 slot 을 화면에서 가르지 않는다. 건너뛴 slot 은 그 요청의 지난 증거에서만 보인다 |
| D3 | L2·L3 의 hard cut 을 하나, 언제 하나 | L1 을 먼저 넣고 잰 뒤, §3.3·§3.4 를 채워 L2·L3 을 한 번의 hard cut 으로 | §5 | 설치할 때 열린 exact 요청과 그 소비자 쪽 기록을 지운다 |
| D4 | 기다리는 slot 없이 열려 있는 요청도 건너뛰게 넓히나 | 지금은 넓히지 않는다. L1 뒤에 남은 되풀이를 재고 정한다 | §3.5 | 다른 slot 이 시각 없는 429, 5xx, 인증 거절로 실패하는 동안에는 큰 본문이 host event 마다 다시 나간다 |

## 10. 확인하지 않은 것

- 서버가 다시 뜬 뒤 기다림 표가 남는지. 비는 쪽으로 §4 를 적었다.
- 운영자가 고친 lane 이 재시작 없이 `resolve` 에 닿는지.
- `Retry.InputCapacity` 를 만드는 곳. `classify_error` 가 만들지 않는다는 것만 읽었다.
- operator quiz 가 열린 요청의 증거를 읽는지. 파일 이름 검색으로만 봤다.
- `host-results` 를 읽는 저장소 밖의 도구가 있는지. 찾은 것은 tinker 스크립트 하나다. 그 스크립트는 끝나지 않은 실행의 receipt 도 읽는다. L1 뒤에는 그 실행이 줄어든다.
- L1 뒤에도 `run` 은 시작할 때 증거 파일을 읽는다. 이미 커진 요청은 L2 전까지 실행마다 그 파일을 읽는다.

확인한 것: `target_identity_fingerprint`(`packages/agent_core/lib/llm_provider/exact_output_resolver.ml:865-897`)는 target ref, provider id 와 종류, model id, base url, 요청 경로, credential 의 종류, thinking, reasoning effort, timeout 둘, `max_concurrent_requests`, codec, 선언한 header, capability projection 을 덮는다. credential 의 값과 lane 이 덧씌우는 `max_output_tokens`·`thinking` 은 덮지 않는다.
