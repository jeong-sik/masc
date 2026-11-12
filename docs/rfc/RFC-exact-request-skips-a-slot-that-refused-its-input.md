---
rfc: "exact-request-skips-a-slot-that-refused-its-input"
title: "exact 요청은 자기 입력을 거절한 slot 을 다시 부르지 않고, 실행 증거는 요청 본문을 다시 담지 않는다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["exact-lane-waits-for-a-stated-reset", "exact-lane-walks-one-slot-list", "operator-quiz-lane", "host-cycle-runs-exact-requests-side-by-side"]
---

# exact 요청은 자기 입력을 거절한 slot 을 다시 부르지 않고, 실행 증거는 요청 본문을 다시 담지 않는다

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
| L1 | 이 요청의 입력을 거절한 slot 을 이 요청으로 다시 부르지 않는다 | 그대로 | 없음 |
| L2 | 실행 증거가 요청 본문 대신 digest 를 담는다. 증거는 attempt 마다 파일 하나다 | 바뀜 | 필요 |
| L3 | 요청 본문을 요청 기록 밖에 한 번만 저장한다 | 바뀜 | 필요 (L2 와 같이) |

L1 은 측정한 되풀이를 첫 실행 다음부터 멈춘다. L2·L3 은 남는 쓰기를 요청 크기와 무관하게 만든다. attempt 목록이 trigger 마다 늘어나는 것은 #50762 가 다룬다. 이 RFC 는 그 목록의 길이를 줄이지 않는다.

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

입력 거절은 `Exact_lane_failure.refusal`(`lib/server/exact_lane_failure.ml:31-40`)이 정한다. `Request_body_refused`, `Invalid_request`, `Context_overflow`, `Input_capacity` 넷이다.

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

증거의 `receipt`(`lib/keeper/keeper_exact_walk_receipt.ml:7-40`)는 slot 별 결과를 타입으로 담는다.

- `http.declared` 는 걸은 slot 의 `{candidate_id; catalog_generation; catalog_evidence; target}` 이다. `target` 은 `Exact_output.target_identity_fingerprint` 다.
- `http.advances[].failed` 와 `terminal` 은 `Execution_failed { visit = { candidate_id; … }; cause }` 다. `cause` 가 `Provider_refused { refusal = Context_overflow | … }` 다.

"어느 slot 이 이 요청을 어떤 이유로 거절했는가"는 이미 저장돼 있다. 읽는 함수가 없을 뿐이다. `failure_evidence` 와 `exhausted_input_refusals` 는 걷기 전체를 합친 값만 돌려준다.

## 3. 설계

### 3.1 계약

- **C1.** 한 요청에서, 그 요청의 입력을 거절한 slot 은 그 요청으로 다시 불리지 않는다.
- **C2.** slot 이 같은지는 slot id 와 target fingerprint 로 본다. 운영자가 그 slot 의 target 을 바꾸면 다른 slot 이다.
- **C3.** 거절의 근거는 그 요청의 보관된 실행 증거다. 메모리의 표나 글에서 읽어 내지 않는다.
- **C4.** 어느 slot 도 lane 목록에서 지우지 않는다. C1 은 요청 하나와 slot 하나 사이의 사실이다. 다른 요청은 그 slot 을 그대로 부른다.
- **C5.** 실행 증거를 하나 보태는 비용은 지난 실행 수와 요청 크기에 비례하지 않는다.
- **C6.** 요청 본문은 한 번 저장한다.

C1 은 시간으로 상태를 죽이지 않는다(헌법 `no_wall_clock_death`). 근거는 일어난 거절이다. 요청 본문은 digest 로 고정이고 target 도 고정이니, 같은 쌍은 같은 답을 한다.

### 3.2 L1 — 입력을 거절한 slot 을 건너뛴다

1. `Keeper_exact_walk_receipt` 에 읽는 함수를 하나 더한다. receipt 의 `declared`, `advances`, `terminal` 에서 `(binding, 입력 거절 종류)` 목록을 낸다. 입력 거절인지는 지금의 `Exact_lane_failure` 분류를 그대로 쓴다. 새 분류를 만들지 않는다.
2. `run` 은 이미 읽은 증거(`bound_proofs`)에서 그 목록을 모아 runner 에 넘긴다. `runner` 타입에 인자가 하나 는다.
3. runner 는 걸을 slot 에서 그 목록의 slot 을 뺀다. 견주는 값은 `candidate_id` 와 `target` 이다. 뺀 slot 은 보관된 종류 그대로 `Input_refused` 실패로 적는다. 그래서 `ending` 의 판단은 그 slot 을 불렀을 때와 같다.
4. 뺀 slot 은 receipt 의 `excluded_http` 에 들어간다. 기다리는 slot 과 같은 자리다. "이 걷기에서 입력을 받지 않았다"는 뜻이 같다. 왜 뺐는지는 앞 attempt 의 증거에 있다.
5. 걸을 slot 이 없고 기다리는 slot 이 있으면 runner 는 `Every_slot_held { until }` 을 돌려준다. 호출도 시작 표시도 증거도 없다. `until` 은 기다리는 slot 의 가장 이른 시각이다.
6. 걸을 slot 도 기다리는 slot 도 없으면 모든 slot 이 이 입력을 거절한 것이다. 호출은 아무것도 보내지 않고 `Call_ended (Input_refused …)` 로 끝난다. 증거는 지금처럼 남는다.

`Every_slot_held` 의 뜻이 "이 요청을 받을 수 있는 slot 이 모두 기다린다"로 넓어진다. `.mli` 의 설명을 고친다. variant 는 더하지 않는다.

L1 은 저장 모양을 바꾸지 않는다. receipt 의 version 과 칸이 그대로다.

L1 은 HTTP slot 만 다룬다. CLI slot 의 실패(`cli.failures`)에도 `runtime_id` 와 원인이 타입으로 있다. CLI 의 입력 거절을 같은 규칙에 넣는 일은 그 원인 타입을 확인한 뒤 따로 정한다(§9 D4).

### 3.3 L2 — 실행 증거

- 증거는 `request` 칸을 갖지 않는다. `digest`, `request_id`, `declaration_id` 가 요청을 가리킨다.
- 증거는 attempt 마다 파일 하나다. key 는 `[request_id, digest, attempt_ordinal]` 이다. 한 번 쓰고, 같은 key 에 다른 내용을 쓰면 거절한다. `Lane_addon_exact_observation` 이 이미 쓰는 모양이다(`lane_addon_exact_observation.ml:3-12`).
- 가장 최근 증거는 attempt 수로 이름을 만들어 읽는다. 목록을 훑지 않는다.
- `decode_proof` 는 호출자의 요청에서 digest 를 계산해 증거의 `digest` 와 견준다.
- sweep 의 `proof_request_id` 는 증거의 `request_id` 와 `digest` 칸으로 파일 이름을 확인한다.

증거 디렉터리는 지금처럼 `.json` 파일만 둔다. sweep 은 그 디렉터리에 다른 종류의 항목이 있으면 전체를 멈춘다(`server_unowned_exact_sweep.ml:54-75`).

### 3.4 L3 — 요청 기록

- 요청 본문은 digest 를 이름으로 한 파일에 한 번 저장한다. `save_tool_request_body`(`lane_addon_store.ml:870`)와 같은 방식이다.
- 요청 기록은 `{digest; attempts; final}` 이다.
- `run` 은 호출자가 넘긴 요청에서 digest 를 계산해 기록과 견준다. 본문 파일은 요청을 다시 읽어야 하는 곳만 연다.

attempt 목록은 그대로 한 파일이다. 항목 하나는 수백 바이트다. 목록의 길이는 #50762 에서 다룬다.

### 3.5 하지 않는 것

- slot 을 시간이나 횟수로 쉬게 하지 않는다.
- 같은 model 을 쓰는 다른 slot 의 거절로 미루어 판단하지 않는다. slot 마다 자기 답을 한 번 받는다.
- `detail` 글에서 slot 이름이나 거절 종류를 읽지 않는다.
- 깨우는 장치를 더하지 않는다. host event 는 지금의 다섯 그대로다.
- attempt 를 지우거나 합치지 않는다.

## 4. 순서

slot A 는 요청보다 context window 가 작다. slot B 는 계정 한도로 기다린다. C 는 CLI slot 이다.

| 틱 | 지금 | L1 뒤 |
|---|---|---|
| N | A 를 부른다. 입력 거절. B 는 기다린다. 요청은 열려 있다. 증거 1 | 같다 |
| N+1 | host event. A 를 다시 부른다. 같은 거절. 증거 2 | A 를 건너뛴다. 걸을 slot 이 없고 B 가 기다리니 `Every_slot_held`. 호출도 증거도 없다 |
| N+M | B 의 시각까지 같다. 실행마다 증거 파일이 요청 크기만큼 는다 | 같다. 실행마다 요청 기록에 `Deferred` 한 줄이 는다 |
| B 의 시각 뒤 | A 와 B 를 부른다 | B 만 부른다. B 가 답하면 끝. B 도 입력을 거절하면 `Input_refused` 로 끝 |
| 서버 재시작 뒤 | 기다림 표가 비어 A, B 를 다 부른다 | 거절은 증거에서 읽으니 A 는 건너뛴다. B 는 부르고, 한도 거절이면 다시 기다린다 |
| 운영자가 A 의 target 을 바꾼 뒤 | A 를 부른다 | fingerprint 가 달라 A 를 부른다 |
| 운영자가 B 를 lane 에서 뺀 뒤 | A 를 부르고 `Input_refused` 로 끝 | 아무도 부르지 않고 `Input_refused` 로 끝 |

- **context window 가 다른 failover.** A 가 거절하고 B 가 `rate_limited` (시각 없음)면, 다음 실행은 B 만 부른다. 큰 본문을 A 로 다시 보내지 않는다.
- **HTTP 다음 CLI.** HTTP slot 이 모두 건너뛰어지거나 실패하면 CLI slot 을 지금처럼 걷는다. C 는 L1 에서 건너뛰지 않는다.
- **계정이 다른 같은 model.** slot 이 다르면 각자 한 번씩 답한다. 미루어 판단하지 않는다(§3.5).
- **여러 Keeper 가 한 설치를 쓸 때.** 끝나지 않는 요청이 실행 자리를 쓰는 시간이 호출 없는 한 번의 읽기로 준다. 다른 Keeper 의 요청이 기다리는 시간이 준다(#51199).
- **입력을 나누는 쪽.** workspace-curator 와 Librarian 은 `Input_refused` 로 끝난 요청을 더 작게 나눠 다시 보낸다. L1 은 그 끝을 앞당기지 않는다. B 가 답할 수 있는 동안은 지금처럼 기다린다.

## 5. hard cut (L2·L3)

L2 와 L3 은 증거와 기록의 모양을 바꾼다. 옛 모양을 읽는 코드는 만들지 않는다(헌법 `legacy_residue`). `check_retained_record` 는 옛 기록을 거절한다(`lane_addon_exact.mli:289-291`).

설치할 때 지우는 것: `lane-addons/exact-requests`, `lane-addons/host-results` 의 exact 증거와 slot 관측, 그리고 그 요청을 원본으로 든 소비자 쪽 기록이다. 소비자는 Librarian(접수 part, durable 원본), workspace-curator, Candle appraiser, operator quiz 다.

2026-11-12T06:39Z 의 요청 기록은 열린 것 6개, 끝난 것 134개였다. 지울 소비자 쪽 기록의 수는 세지 않았다. L2·L3 을 시작하기 전에 센다.

L1 은 hard cut 이 없다.

## 6. 시험

단언은 부른 횟수로 쓴다. 고치기 전 동작에서 실패해야 한다.

| 층 | 시험 | 고치기 전 |
|---|---|---|
| L1 | A 가 입력을 거절하고 B 가 기다리는 요청을 두 번 실행하면 A 는 한 번 불린다 | 두 번 |
| L1 | 두 번째 실행은 `Every_slot_held` 이고 증거가 늘지 않는다 | `provider_unavailable`, 증거 둘 |
| L1 | A 의 target fingerprint 가 바뀌면 A 를 다시 부른다 | 해당 없음 |
| L1 | B 가 lane 에서 빠지면 아무도 부르지 않고 `Input_refused` 로 끝난다 | A 를 부른다 |
| L1 | A 가 `rate_limited` 로 거절한 요청은 다음 실행에서 A 를 다시 부른다 | 같다 (그대로여야 한다) |
| L2 | 증거를 n개 남긴 뒤 하나를 더 남길 때 쓰는 바이트가 n 과 요청 크기에 따라 늘지 않는다 | 는다 |
| L2 | 다른 요청의 digest 를 든 증거는 거절한다 | 본문 비교로 거절 |
| L3 | attempt 를 보탤 때 요청 본문 파일을 다시 쓰지 않는다 | 다시 쓴다 |

## 7. 층

| 층 | 내용 | 파일 |
|---|---|---|
| L1a | receipt 에서 slot 별 입력 거절을 읽는 함수와 시험 | `keeper_exact_walk_receipt.ml`·`.mli` |
| L1b | `run` 이 증거에서 목록을 모아 runner 에 넘긴다. runner 가 건너뛴다 | `lane_addon_exact.ml`·`.mli`, `server_lane_addon_exact.ml` |
| L2 | attempt 마다 증거 파일 하나, `request` 칸 없음 | `lane_addon_exact.ml`, `lane_addon_exact_observation.ml`, `server_unowned_exact_sweep.ml`, tinker 스크립트 |
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

## 9. 사용자 결정

| | 결정 | 추천 | 계약 | 대가 |
|---|---|---|---|---|
| D1 | slot 이 같은지 무엇으로 보나 | slot id 와 target fingerprint | C2 | provider 가 같은 target 의 window 를 넓혀도 그 요청은 그 slot 을 다시 부르지 않는다. 요청은 다른 slot 으로 끝나거나 운영자가 target 을 바꿔야 한다 |
| D2 | L1 에서 `Every_slot_held` 의 뜻을 넓히나, variant 를 더하나 | 뜻을 넓힌다 | §3.2 5번 | TUI 의 "모든 slot 이 기다림" 글이 "받을 수 있는 slot 이 모두 기다림"을 뜻하게 된다 |
| D3 | L2·L3 의 hard cut 을 하나, 언제 하나 | L1 을 먼저 넣고 측정한 뒤, L2·L3 을 한 번의 hard cut 으로 | §5 | 설치할 때 열린 exact 요청과 그 소비자 쪽 기록을 지운다 |
| D4 | CLI slot 의 입력 거절도 건너뛰나 | L1 뒤에 원인 타입을 확인하고 정한다 | §3.2 | 그때까지 CLI slot 은 입력을 거절해도 다시 불린다 |

## 10. 확인하지 않은 것

- `Exact_output.target_identity_fingerprint` 가 무엇을 덮는지(model, endpoint, 계정). D1 을 정하기 전에 읽는다.
- `host-results` 를 읽는 저장소 밖의 도구가 있는지. 찾은 것은 tinker 스크립트 하나다.
- L1 뒤에도 `run` 은 시작할 때 증거 파일을 읽는다. 이미 커진 요청은 L2 전까지 실행마다 그 파일을 읽는다.
