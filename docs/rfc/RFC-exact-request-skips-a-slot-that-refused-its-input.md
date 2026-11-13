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

이슈 #51559 의 설계다. 코드 줄 번호는 main `fe02caf20e0a` 기준이다. 인용한 줄은 main `1157fd7b7b96` 에서도 같다. L1 을 다루는 §2.1·§2.2·§2.5·§2.6·§3.1·§3.2·§3.5 는 예외다. 그 절이 인용한 일곱 파일의 줄은 L1 을 넣기 전인 main `55d2bb205b11` 기준이다. `lane_addon_exact.ml`, `server_lane_addon_exact.ml`, `exact_lane_failure.ml`, `keeper_exact_walk_receipt.ml`, `keeper_librarian_admission_parts.ml`, `keeper_memory_execution_availability.ml`, `lane-addon-host-requests.ts` 다.

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
| L2 | 실행 증거가 요청 본문을 담지 않는다. 요청은 `request_id` 와 `digest` 로 가리킨다 | 바뀜 | 필요 |
| L3 | 요청 본문을 요청 기록 밖에 한 번만 저장한다 | 바뀜 | 필요 |

L1 과 L2 는 이 문서에서 구현할 수 있을 만큼 정한다(§3.2, §3.3). L2 는 L3 없이 설치한다(§9 D3). L3 은 방향과 풀어야 할 것만 정한다(§3.4). L3 을 할지는 L2 를 설치한 뒤 잰 값으로 정한다. 하기로 하면 그 절을 채워 다시 리뷰받는다.

L1 은 #51649 로 병합됐다. 화면 문구는 #51650 이 고쳤다. §1.1 은 그 병합 직전에 잰 값이다. L1 이 덮지 않는 되풀이 하나를 거기서 찾았다(§3.5, §9 D5).

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

### 1.1 L1 병합 직전, 설치 전에 잰 것 (2026-11-12 09:38~09:50Z)

측정은 09:50Z 에 끝났고 L1(#51649)은 09:53:48Z 에 병합됐다. 그때 운영 서버의 build 에는 L1 이 없었다. 저장소에서 칸 이름, 타입 이름, 개수, 바이트만 읽었다. slot 은 runtime 계열로만 적는다.

| 항목 | 값 |
|---|---|
| 열린 `classification` 요청의 attempt | 287 |
| 그 요청의 실행 증거로 보이는 파일 | 1,032,619,534 바이트. `host-results` 706개 합의 78.5% (계산값) |
| 그 파일을 뺀 exact 증거 | 파일 137개, 증거 1,549개 |
| 그 증거들의 `request` 칸 합 | 275.9 MB |
| 그 증거들의 나머지 칸 합 | 5.4 MB |
| 본문을 뺀 증거 하나 | 평균 약 3.5 KB (5.4 MB ÷ 1,549, 계산값). 칸별 중앙값을 더하면 약 1.4 KB |
| 본문이 아닌 칸의 최댓값 | 답을 담은 `outcome` 100 KB |
| 요청 기록 | 142개. 열린 것(final 없음) 10, 끝난 것 132 |

큰 파일이 그 요청의 증거라는 것은 key 로 확인하지 않았다. 수정 시각이 요청 기록과 같이 움직이고, 바이트를 attempt 수로 나눈 값이 요청 크기와 비슷하다.

열린 10개 가운데 6개는 Librarian 요청이다(`admission` 2, `durable` 4). 요청마다 19~22번 실행됐다. 본문은 118,523~391,718자다. 실행의 모양은 여섯 모두 같다.

- HTTP slot 다섯 중 셋이 기다린다. 실행 세 번에서는 둘만 기다렸다.
- 나머지 둘을 부른다. tinker 계열이 400, claude 계열이 400 으로 답한다. receipt 에는 둘 다 `Provider_refused { http_status = 400; refusal = Invalid_request }` 다. 여섯 요청에 기록된 호출은 계열마다 123번이다.
- CLI slot 둘은 기다린다. 요청은 `provider_unavailable` 로 열려 있다.
- 한 요청 안에서 slot 마다 receipt 의 `attempts[].plan` 과 `attempts[].body` 는 실행 내내 값이 하나다.

두 400 의 응답 문장을 사람이 읽었다. masc 는 이 문장을 읽지 않는다.

| slot | 문장의 뜻 | 저장된 증거 전체에서 |
|---|---|---|
| tinker 계열 | prompt 와 `max_tokens` 의 합이 context window(65,536)를 넘는다 | 294번. 모두 prompt 만으로 window 를 넘는다. 가장 작은 prompt 가 68,417 token 이다 |
| claude 계열 | 사용자가 정한 지출 한도에 닿았다. 풀리는 날짜가 문장에 있다 | 298번. #49686 과 같은 원인이다 |

tinker 계열의 400 에는 오류 코드가 없다. 그래서 `Invalid_request` 가 된다. L1 은 `Invalid_request` 를 건너뛰지 않는다(§3.2). 코드대로면 이 여섯은 L1 이 설치된 뒤에도 host event 마다 두 slot 을 다시 부른다. 설치 뒤의 값은 아직 재지 않았다.

tinker 문장의 `max_tokens` 자리에는 283번이 1000000000, 11번이 4096 이다. Librarian lane 은 output 한도를 선언하지 않았다. 그 경우 요청은 그 칸을 싣지 않는다(`backend_openai_request.ml:238-263`). 1000000000 은 provider 의 기본값으로 보인다. wire 본문은 보지 않았다.

### 1.2 L1 설치 뒤에 잰 것 (2026-11-12 10:42~12:56Z)

서버는 10:32:06Z 에 L1 이 든 build `778e441d5df1` 로 다시 떴다. 읽는 방식은 §1.1 과 같다.

- 열린 `classification` 요청의 attempt 292 는 다시 뜬 뒤의 첫 실행이다. 기다림 표가 비어 있어 HTTP slot 둘을 불렀다(429 `Rate_limited`, 400 `Context_overflow`).
- attempt 293~295 는 `every_slot_held` 다. provider 를 부르지 않았다. 그 요청의 증거 파일은 1,055,315,219 바이트에서 늘지 않았다.
- 그 요청은 실행마다 그 파일을 통째로 읽는다. 원본을 이어 가는 `Submit.resume` 도 그 파일을 통째로 읽는다(§2.3). 그 요청의 원본은 workspace-curator 의 것이다.
- exact 요청 기록은 134개다. 열린 것이 7개다.
- 그 요청의 attempt 는 10:51Z 에 295, 11:30Z 에 300, 12:06Z 에 305, 12:56Z 에 312 다. 증거 파일은 같은 크기다.
- 11:30Z 에 열린 요청은 8개다. Librarian 요청은 넷이다(`admission` 2, `durable` 2). attempt 가 19, 23 인 둘은 다시 뜬 뒤 58분 동안 실행되지 않았다. 증거 파일은 8,088,287 바이트와 13,156,450 바이트다.
- 11:30Z 에 소비자 원본(`tool-request-owners`)은 709개다. request id 가 exact 요청 id 와 같은 것은 92개다(`admission` 58, `classification` 17, `durable` 4, 그 밖 13). 나머지 exact 기록 42개의 원본은 세지 못했다.

12:04:31~12:29:31Z 에 서버 프로세스의 CPU 시간과 RSS 를 1초마다 읽었다(표본 1,492개). 그 요청의 기록과 증거 파일의 수정 시각을 같이 봤다. 스크립트는 시각과 수만 찍었다.

- 기록은 12:06:16Z, 12:07:26Z, 12:28:57Z 에 바뀌었다. 증거 파일은 바뀌지 않았다. 세 실행 모두 provider 를 부르지 않았다(§2.3).
- 기록이 바뀌기 전 180초부터 뒤 30초까지의 RSS 최댓값은 18,767 MB, 19,537 MB, 20,291 MB 다.
- 실행과 떨어진 표본의 RSS 는 중앙값 15,723 MB, 최댓값 17,839 MB 다. 세 실행의 최댓값은 모두 이보다 크다. 중앙값과의 차는 3.0~4.6 GB 다(계산값).
- 기록이 바뀌기 전 60초의 CPU 시간은 97.4초, 111.4초, 72.4초다. 실행과 떨어진 60초 구간은 중앙값 64.1초, p90 100.3초, 최댓값 115.5초다. CPU 로는 실행을 가르지 못했다.
- RSS 가 오른 원인은 가르지 않았다. 같은 구간의 다른 일과 나누어 보지 않았다.

12:53:00Z 와 12:56:08Z 에 저장소를 다시 셌다.

| 항목 | 값 |
|---|---|
| exact 요청 기록 | 145개. 열린 것 8 |
| 열린 `classification` 기록 | 3,891,857 바이트. 요청 3,779,582 바이트, attempt 312개 112,073 바이트 |
| 증거 파일 | 140개. 모두 자기 기록이 있다. 기록 없는 증거는 0 |
| slot 관측 파일 | 382개 |
| `host-results` 의 디렉터리 | 증거 4, 관측 3. 그 밖의 디렉터리와 파일은 없다 |
| 같은 request id 의 소비자 원본이 있는 기록 | 87개. 그 가운데 증거가 있는 것 86 |
| 소비자 원본(`tool-request-owners`) | 697개 |

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

그래서 provider 호출 수는 (host event 수) × (열린 요청 수) × (요청마다 걸을 slot 수)다. host event 는 그 요청과 무관한 일로도 난다. L1 은 셋째 항만 줄인다. host event 가 열린 요청을 다시 걷는 것은 지나갈 수 있는 실패를 다시 시도하는 유일한 길이기도 하다. 시간으로 깨우지 않기 때문이다.

### 2.3 실행 증거

`run` 은 provider 를 부른 실행마다 증거를 남긴다. 거절된 호출(`Call_refused`)도 남긴다(`lane_addon_exact.ml:1142-1145`, `:1171-1174`).

- 증거 하나(`proof_to_json`, `:668-674`)는 `request` 칸에 요청 전체를 담는다. `digest` 칸도 따로 있다.
- 한 요청의 증거는 파일 하나(`executions` 목록)에 모인다(`proofs_to_json`, `:715-718`).
- `retain_proof`(`:826-848`)는 파일 전체를 읽어 모든 증거를 decode 하고, 하나를 보태 전체를 쓰고, 다시 읽어 견준다.
- `run` 은 시작할 때도 전체를 읽는다(`bound_proofs`, `:1039-1040`).

거절된 호출 한 번에 증거 파일을 세 번 읽고 한 번 쓴다. n번째 실행의 쓰기는 n × (요청 크기)다.

host 실행 밖에서도 그 파일을 읽는다. 소비자는 보낸 원본을 `Lane_addon_submit_once.resume` 으로 이어 간다. 원본이 보내는 중이면 resume 은 `recover_retained` 를 부른다(`lane_addon_submit_once.ml:89-96`, `:212-213`). 같은 요청을 잡은 쪽이 없으면 `recover_retained` 는 요청 기록과 증거 파일을 통째로 읽고 decode 한다(`lane_addon_exact.ml:941-959`). 잡은 쪽이 있으면 기록만 읽는다(`:940`). 이 길을 쓰는 원본은 Librarian 의 admission(`keeper_librarian_admission_dispatch.ml:92`)과 History Memory(`keeper_librarian_durable_owner.ml:191`), Floor step(`keeper_librarian_floor_step_owner.ml:86`), workspace-curator(`server_workspace_memory_addon.ml:109`)다.

#51461 에 다른 세션이 운영 서버에서 잰 할당 프로파일이 있다. build `da59fca791b3` 에서 45초 동안 쟀고, 직접 재지 않았다. `proof_to_json` 안의 `digest` 가 할당의 16.5%(9.42 GB)였다. 부른 쪽은 `bound_proofs` 약 53%, `recover_retained` 약 47% 였다. 그 build 는 증거마다 digest 를 다시 냈다. #51463 부터 main 은 연산마다 digest 를 한 번 내서 넘긴다(`lane_addon_exact.ml:627-632`, `:1016`). #51463 을 넣은 build 의 할당 표에는 그 줄이 없다(#51461 의 댓글, 다른 세션이 쟀다). 증거마다 요청을 다시 글로 써서 견주는 일(`decode_proof`, `:707-710`)은 main 에도 있다.

증거의 `request` 칸을 읽는 곳은 셋이다.

- `decode_proof`: 저장된 증거를 호출자의 요청으로 다시 만든 것과 견준다(`:707-710`).
- `proof_request_id`: `executions[0].request` 로 digest 를 다시 계산해 파일 이름과 견준다(`:756-769`). 시작 때의 sweep 이 쓴다(`server_unowned_exact_sweep.ml:91-114`).
- `scripts/tinker/librarian/check_validator_on_store.py:299-317`: `request.output` 과 `request_id` 를 읽는다.

셋 다 요청이 어느 것인지 확인하는 데만 쓴다. 본문 내용을 쓰는 곳은 없다. Librarian 이 나눈 part 는 증거의 발췌를 저장한다(`keeper_librarian_admission_parts.ml:267-269`). 발췌에 `request` 칸은 없다.

### 2.4 요청 기록

기록(`record`, `:451-456`)은 `{digest; request; attempts; final}` 이다. 거절된 호출 한 번에 두 번 쓴다. `Started` 를 보태 쓰고(`:1110-1115`), 호출이 끝나면 그 자리를 `Deferred` 로 바꿔 쓴다(`:1187-1192`). 쓸 때마다 요청 본문이 같이 나간다.

증거는 attempt 의 위치에 묶인다. ordinal n 의 증거는 `attempts` 의 n번째 항목과 맞아야 한다(`proof_matches_attempt`, `:775-792`). 그래서 attempt 를 지우거나 합치면 증거가 다른 attempt 에 묶인다. 서버는 attempt n 의 `Started` 를 기록에 쓴 뒤에만 증거 n 을 쓴다(`:1168-1174`).

### 2.5 walk receipt 가 이미 가진 것

증거의 `receipt`(`lib/keeper/keeper_exact_walk_receipt.ml`)는 slot 별 결과를 타입으로 담는다.

- `http.declared` 는 걸은 slot 의 `{candidate_id; catalog_generation; catalog_evidence; target}` 이다. `target` 은 `Exact_output.target_identity_fingerprint` 다.
- `excluded_http` 는 걷지 않은 slot 의 id 목록이다. 지금은 기다리는 slot 이 들어간다.
- slot 의 실패(`failed`)는 `Rejected { visit; disposition; detail }`(로컬 거절)이거나 `Execution_failed { visit; cause; raw_sha }` 다.
- `cause` 는 `api_observation`(`keeper_exact_walk_failure.ml:107`)이다. provider 의 거절은 `Provider_refused { http_status; refusal }` 이고 `refusal` 은 닫힌 타입이다.

receipt 는 보낸 요청마다 `attempts[]` 에 `plan` 과 `body` 를 담는다(`keeper_exact_walk_receipt.ml:101-102`). `body` 는 wire 본문의 sha256 이다. `plan` 은 본문 sha, catalog generation, target identity fingerprint, codec, timeout 둘을 합친 해시다(`packages/agent_core/lib/llm_provider/exact_output_ready_admission.ml:372-382`). catalog generation 은 catalog 의 모든 target 을 합친 값이다(`exact_output_resolver.ml:938-943`). 무관한 target 하나가 바뀌어도 `plan` 이 달라진다.

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
- **C6.** 실행 증거를 읽고 보태는 비용은 요청 크기에 비례하지 않는다.
- **C7.** 요청 본문은 한 번 저장한다.

C1 은 시간으로 상태를 죽이지 않는다(헌법 `no_wall_clock_death`). 근거는 일어난 거절이다.

C1 이 맞는 이유는 `ending` 이다. 기다리는 slot 이 있으면 걷기는 입력 거절로 끝나지 않는다(§2.1). 그동안 거절한 slot 을 다시 불러서 달라질 수 있는 결과는 "이번에는 답한다" 하나다. 본문은 digest 로 고정이다. target 과 schema 가 같으면 보내는 요청에서 달라질 수 있는 것은 lane 의 `max_output_tokens` 와 `thinking` 이다. 이 둘은 fingerprint 뒤에 lane 이 덧씌운다(`lib/runtime/runtime_exact_output_registry.ml:683-696`, `exact_output_resolver.ml:968-976`). receipt 에 그 값은 없다. 보낸 wire 본문의 sha 는 있다(`attempts[].body`, §2.5). 그것과 견주려면 걷기 전에 slot 마다 본문을 직렬화해야 한다. L1 은 견주지 않는다. 운영자가 그 둘을 바꿔도 기다림이 끝날 때까지 그 slot 은 건너뛰어진다(§9 D1 의 대가, §8).

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

### 3.3 L2 — 실행 증거

**규칙.** 증거는 요청 본문을 담지 않는다. 요청은 `request_id` 와 `digest` 로 가리킨다. 한 요청의 증거가 파일 하나에 모이는 것, 그 파일의 자리와 이름은 바꾸지 않는다.

**근거.** §1.1 의 파일 137개에서 `request` 칸이 275.9 MB 이고 나머지 칸이 5.4 MB 다. `request` 칸을 빼면 그 파일들의 98% 가 사라진다(계산값). 파일 하나는 평균 약 39 KB 가 된다(5.4 MB ÷ 137, 계산값). 요청 하나의 증거는 평균 11.3개다(1,549 ÷ 137). §1.2 의 큰 파일은 증거별로 세지 않았다. 같은 평균이면 약 1 MB 다(attempt 292 × 3.5 KB, 계산값). 그 파일은 host 실행과 원본 resume 이 통째로 읽는다(§2.3). 그 요청이 실행될 때 서버 RSS 가 올랐다(§1.2).

**증거의 `request` 칸을 읽는 곳.** §2.3 의 셋이다. 소비자는 요청을 자기 원본에서 다시 만들어 공개 read 함수에 넘기고 `{outcome; receipt}` 를 받는다(`lane_addon_exact.mli:206-209`).

**증거 하나의 모양(`proof_to_json`, `:668-674`).** `request` 칸을 뺀다. 남는 칸은 `version`, `kind`, `store_root`, `declaration_id`, `request_id`, `digest`, `schema`, `attempt_ordinal`, `outcome`, `receipt` 다. `version` 은 2 다. 실행을 묶는 바깥 모양(`proofs_to_json`, `:715-718`)은 바꾸지 않는다.

**읽기(`decode_proof`).** 호출자의 요청으로 증거를 다시 만들어 저장된 것과 견주는 방식은 같다. 다시 만든 값에는 호출자 요청의 `request_id` 와 `digest` 가 들어간다. `digest` 는 요청 전체를 글로 쓴 것의 sha256 이다(`:91`). 다른 요청의 증거는 `digest` 가 달라 거절된다. 그 밖에 decode 가 요청에서 쓰는 칸은 `schema` 다(`:273-283`, `:683-686`).

C6 은 증거 파일을 읽고 쓰는 몫에 대한 것이다. 요청 기록을 읽고 쓰는 몫은 L2 뒤에도 요청 크기에 비례한다. 그 몫은 §3.4 에 적었고 L3 이 다룬다.

**digest 의 타입.** L2 뒤에 증거와 요청을 잇는 것은 `request_id` 와 `digest` 둘뿐이다. 증거 함수는 digest 를 문자열 인자(`~digest`)로 받는다(`:627-632`). 진입점은 넘겨받은 요청에서 digest 를 낸다(`:855`, `:878`, `:909`, `:947`, `:1016`). 그래서 L2 는 이 층 없이도 맞게 돈다. 다만 다른 요청의 digest 를 넘겨도 타입이 막지 않는다. main 에서는 증거를 다시 만들어 본문까지 견주는 비교가 그 실수를 잡는다(`:707-710`). L2 는 그 본문을 없앤다. 그 뒤에는 파일 이름(`proof_key`, `:630-632`), 다시 만든 증거, 저장된 `digest` 가 모두 같은 틀린 값을 쓴다. `bind_proofs` 는 attempt 와 증거의 결과만 견준다(`:775-798`). 다른 요청의 증거가 묶여도 드러나지 않는다.

그래서 L2a 는 요청과 그 digest 를 한 값으로 묶는다.

- 그 값은 `lane_addon_exact.ml` 안의 하위 모듈이 요청에서만 만든다. 하위 모듈 밖에서는 요청과 다른 digest 를 짝지을 수 없다.
- 이 값과 만드는 함수는 `.mli` 로 내보내지 않는다. `.mli` 가 내보내는 증거 함수는 sweep 이 쓰는 `proof_directory` 와 `proof_request_id` 둘이다(`lane_addon_exact.mli:349`, `:352`). 증거를 읽고 쓰는 함수는 모두 그 파일 안에 있다. 그래서 `.mli` 에 `private` 를 붙여서는 아무것도 막지 못한다.
- 보장은 "호출자의 요청에 증거나 기록을 묶는 읽기와 쓰기는 모두 그 값을 받는다"이다.
- 증거 파일 이름은 `request_id` 와 `digest` 두 문자열로 이름을 내는 함수 하나가 낸다. `proof_key` 와 sweep 의 `proof_request_id` 가 같이 쓴다. sweep 은 호출자의 요청에 아무것도 묶지 않으니 이 값을 만들지 않는다. L2a 의 sweep 은 파일 안 요청 본문에서 두 문자열을 낸다. 파일의 `request_id`·`digest` 칸에서 읽는 일은 본문을 빼는 L2b-3 이 한다.
- 연산마다 한 번 만들어 넘긴다. #51463 과 같다. `read_latest_slot_observations` 는 같은 값으로 읽고 관측의 증거를 다시 만든다(`:909` 를 대신한다). `recover_retained` 는 요청을 잡기 전에 만들어 `observe_retained_classified` 와 증거 읽기에 넘긴다. digest 는 처음 견주거나, 증거 파일 이름을 내거나, 새 기록에 적을 때 만든다. 그 전에 멈춘 읽기는 digest 를 내지 않는다. 기록이 없는 `observe_retained` 처럼 digest 가 필요 없는 길이 그렇다.
- `bound_record` 는 요청 본문을 견준 뒤 `record.digest` 를 그 값의 digest 와 견준다. digest 를 두 번 내는 줄(`:505-506`)은 지운다. 요청은 `request_of_json` 만 만들고, schema 를 canonical 로 둔다(`:76`, `lane_addon_exact.mli:33-41`). 파일 안에서도 `Request` 하위 모듈이 그 레코드를 private 로 두어, 그 함수 밖에서는 요청을 만들 수 없다. 그래서 본문이 같은 두 요청은 digest 도 같다. `record.digest` 를 한 번만 견줘도 거절하는 기록이 같다.
- 저장된 요청으로 기록을 묶는 곳은 저장된 요청으로 값을 만든다. `run` 의 `:1030` 과 `check_retained_record` 의 `:580` 이다. `run` 은 그 뒤 기록의 digest 를 호출자의 값의 digest 와 견준다(`:1034`). 저장된 기록이 깨졌으면 호출자의 요청과 상관없이 `Error` 로 끝난다.
- slot 관측은 바꾸지 않는다. 관측은 digest 가 아니라 증거 JSON 의 sha 로 증거에 묶인다(`lane_addon_exact_observation.ml:13-16`).
- 요청을 decode 만 하는 길은 이 값을 만들지 않는다. 요청이 digest 를 들고 다니는 안은 그 길에도 digest 값을 치르게 해서 #51463 이 고르지 않았다(#51461 의 첫 댓글).

덤으로 요청의 digest 를 내는 횟수가 준다. digest 한 번은 요청 전체를 글로 써서 해시한다(`:91`). `read_latest_original_execution` 은 한 번 읽을 때 digest 를 세 번 낸다(`:878`, `:505-506`). `read_latest_slot_observations` 는 네 번, `recover_retained` 는 다섯 번까지다. L2a 뒤에는 연산마다 많아야 한 번이다. 저장된 요청으로 기록을 묶는 `run` 만 두 번이다. #51461 의 첫 댓글이 남은 일로 적은 `bound_record` 의 두 번도 없어진다. slot 관측의 identity 는 digest 가 아니라 증거 JSON 을 해시한다(`lane_addon_exact_observation.ml:13-16`). 그 JSON 에는 L2b-3 전까지 요청 전체가 들어 있다. 저장 모양과 동작은 같다. L2 의 아래 층으로 둔다(§7).

**정수 칸.** 바깥 `version`, `attempt_ordinal`, receipt 의 `version` 은 canonical 로 바꾸기 전의 JSON 에서 정수여야 한다. canonical 은 정수로 떨어지는 float 를 정수로 바꾼다. receipt 가 version 2 인 증거는 main 도 원래 JSON 에서 바깥 `version` 과 `attempt_ordinal` 이 정수인지 본다(`:694-699`). receipt 가 version 1 인 증거에서는 main 의 읽기가 세 곳에서 float 를 받는다.

- receipt version 1 을 canonical 뒤의 값에서 decode 하는 갈래(`:704`)
- ordinal 을 canonical 뒤의 값에서 읽는 곳(`:740-743`)
- 다시 만든 증거와 canonical 로 견주는 곳(`:707-710`)

L2 의 읽기는 원래 JSON 에서 바깥 `version` 이 정수 2 인지, `attempt_ordinal` 이 정수인지 본다. receipt 는 원래 JSON 에서 decode 하고 version 2 만 받는다. version 1 receipt 를 만드는 곳은 `keeper_librarian_runtime.ml:899` 하나다. 그 receipt 는 메모리에서만 쓰이고 증거에 들어가지 않는다. 증거를 쓰는 곳은 `make_v2` 를 쓴다(`server_lane_addon_exact.ml:215`). 그 뒤의 canonical 비교는 남는다. 정수 검사가 float 를 먼저 거절하니, 비교는 칸의 이름과 값만 가른다.

`test_v1_and_v2_original_proofs_remain_distinct`(`test/test_lane_addon_exact.ml:543-606`)는 version 1 receipt 를 증거에 담는 시험이다. L2 에서 지운다. 그 안의 float 거절 단언(`:597-605`)은 version 2 증거만 쓰는 시험으로 옮긴다. 바깥 `version` 은 `Float 2.0` 으로 바꿔 거절을 본다.

**쓰기(`retain_proof`, `:826-848`).** 순서는 같다. 파일을 읽어 그 요청의 증거를 모두 decode 하고, 하나를 보태 파일을 쓰고, 다시 읽어 견준다. 쓰는 바이트는 (그 요청의 증거 수) × (본문 없는 증거 하나)다. 요청 크기는 들어가지 않는다(C6).

증거 수에 비례하는 몫은 남는다. 거절된 호출 한 번은 증거 n개를 세 번 읽고 n+1개를 한 번 쓴다. 호출이 쌓이면 합은 n² 에 비례한다. n 은 그 요청에 증거를 남긴 호출의 수다. provider 에 보내지 않고 끝난 호출도 증거를 남긴다(`:1165-1174`, `lane_addon_exact.mli:441-442`). 증거는 ordinal 로 attempt 에 묶이고, attempt 는 합치지 않는다(§2.4). #50762 도 줄을 합치거나 개수에 상한을 두는 방법을 증상만 누른다고 보았다. 그래서 n 을 줄이는 길은 호출을 줄이는 것뿐이다. 그 호출은 L1 과 §9 D4·D5 가 다룬다. n² 의 몫을 맡은 곳은 아직 없다.

**sweep(`proof_request_id`).** 첫 증거의 `request_id` 와 `digest` 칸으로 파일 이름을 다시 계산해 견준다. 파일 이름은 그 둘로 정해진다(`proof_key`, `:630-632`). version 1 증거에도 두 칸이 있다. 그래서 L2 의 sweep 도 version 1 증거의 이름을 확인하고, 원본이 살아 있지 않은 것을 지운다(`server_unowned_exact_sweep.ml:140-163`). sweep 의 나머지는 바꾸지 않는다.

**slot 관측.** 관측 파일의 이름에는 증거의 sha 가 들어간다(`lane_addon_exact_observation.ml:13-16`). L2 는 증거의 모양을 바꾸니 그 sha 도 바뀐다. 관측 코드는 바꾸지 않는다. version 1 증거에 묶인 관측 파일은 L2 의 읽기가 열지 않는다. 관측이 없으면 읽는 쪽은 `None` 을 받는다(`lane_addon_exact_observation.mli:1-4`, `:8-10`).

**preflight.** #49587 의 규칙을 따른다. 각 검사는 그 기록을 읽는 쪽의 decode 를 쓴다. 그래야 hard cut 이 설치를 멈춘다. 설치 뒤 첫 pass 에서 소비자가 멈추지 않는다(`bin/deployment_preflight_helper.ml:823-825`).

1. `Exact_requests` scan(`lane_addon_store_preflight.ml:289-293`)은 `run` 의 읽기를 쓴다. 기록과, 기록이 가리키는 증거 파일을 같이 decode 한다(`bound_proofs`, `lane_addon_exact.ml:800-803`). main 의 scan 은 기록만 본다(`check_retained_record`, `:572-582`).
2. 읽는 순서는 기록, 증거 파일, 기록이다. 첫 기록에서 `declaration_id`, 요청, `digest` 를 얻는다. 증거는 두 번째로 읽은 기록에 묶는다. 서버는 attempt n 을 기록에 쓴 뒤에만 증거 n 을 쓰고, attempt 를 지우지 않는다(§2.4). 그래서 증거 뒤에 읽은 기록은 그 증거의 attempt 를 모두 갖는다. 기록을 한 번만 먼저 읽으면, 그사이 서버가 보탠 증거 n+1 이 짝 없는 증거가 된다. 그러면 멀쩡한 기록을 거절한다(`proof_matches_attempt`, `:775-777`). 두 번째로 읽은 기록도 첫 기록에서 얻은 요청과 digest 로 `bound_record` 와 `validate_record` 를 통과해야 한다. preflight 는 서버가 도는 동안에도 돈다(`lane_addon_store_preflight.mli:13-15`). 두 번째 읽기에서 기록이 없으면 지운 기록으로 본다. 기록을 읽는 규칙과 같다(`lane_addon_store_preflight.ml:129-147`).
3. 파일은 preflight 가 경로로 읽는다. store 의 load 함수는 파일과 디렉터리를 fsync 한다(`lane_addon_store.ml:659`, `:1163-1165`). preflight 는 아무것도 sync 하지 않는다(`lane_addon_store_preflight.mli:13-15`). 그래서 `check_retained_record` 는 기록과 증거 파일의 JSON 을 받는 순수 함수가 된다. `Lane_addon_exact` 는 기록 JSON 에서 그 키와 증거 파일의 경로를 내는 함수를 내보낸다(`Retained_key.of_record`, `Retained_key.proof_path`). 이 decode 는 store 의 root 에 달려 있다. 증거와 관측에는 그것을 쓴 store 의 root 가 들어 있다(`proof_to_json`, `:670`; `lane_addon_exact_observation.ml:9`). decode 는 그 칸을 견준다(`:707-710`; `lane_addon_exact_observation.ml:30-35`). 서버는 `Workspace_root.resolve_current` 로 root 를 정한다. 이 함수는 경로를 정규화한 뒤 `realpath` 로 symlink 까지 푼다(`lib/config/workspace_root.ml:44-54`). 서버는 그 root 로 시작한다(`lib/server/server_base_path_guard.ml:9`, `:18-20`; `bin/main_eio.ml:420-442`). preflight 는 받은 값을 그대로 쓴다(`lane_addon_store_preflight.ml:280`). 그래서 helper 가 scan 전에 같은 함수로 root 를 정한다. scan 은 그 root 로 store 를 서버처럼 `Lane_addon_store.create` 로 만든다. scan 의 인자는 base path 다. 설치 스크립트는 이미 그 함수가 낸 root 를 넘긴다(`bin/deployment_preflight_helper.ml:1290-1296`, `scripts/install-local-build.sh:217`, `:285`). 그래도 root 가 다른 경우는 작업 공간 디렉터리를 옮기거나 복원했을 때다(`lane_addon_exact.mli:322-324`). 그때는 그 증거와 관측을 지울 것으로 찍지 않는다. 증거의 decode(`decode_proof`)는 root 가 다른 경우에도 오류 문자열 하나만 돌려준다. 관측의 `request_id` 읽기(`Lane_addon_exact_observation.request_id`)도 같다. 그래서 검사는 두 파일을 decode 하기 전에 파일이 적은 `store_root` 를 검사의 root 와 견준다. 그 칸은 그 파일의 모양을 정한 모듈이 읽는다(`Lane_addon_exact.proof_store_roots`, `Lane_addon_exact_observation.store_root`). root 가 다른 증거나 관측을 만나면 검사는 두 root 를 적고 끝난다. 그 파일이 다른 store 에서 왔는지, 검사의 root 가 틀렸는지 가를 수 없어서다.
4. 기록을 거절하면 `fresh state` 줄에 셋을 찍는다. 기록 파일, 증거 파일, 그 요청의 slot 관측 파일이다. 검사는 기록을 decode 하기 전에 그 JSON 의 `declaration_id`, `request_id`, `digest` 문자열을 읽는다(`Retained_key.of_record`). 증거 파일과 관측 파일은 이 문자열로 찾는다. 그 문자열로 낸 기록 경로가 그 파일의 경로와 같을 때만 그렇게 한다. decode 에 성공하는 기록도 이 확인을 거친다. `run` 은 호출자가 준 두 값으로 낸 경로에서 기록을 읽고, 기록에 적힌 두 값과 견준다. 기록 파일의 디렉터리는 `declaration_id` 의 digest, 이름은 `request_id` 의 digest 다(`lane_addon_store.ml:332-335`). action receipt 의 검사와 같은 확인이다(`check_action`, `lane_addon_store_preflight.ml:211-222`). 경로가 다르면 그 기록 파일만 찍는다. 그러지 않으면 다른 요청을 가리키는 기록 하나가 멀쩡한 요청의 증거를 지울 목록에 올린다. 증거를 잃은 요청의 시작 표시는 `Outcome_unknown` 으로 남는다(`lane_addon_exact.mli:436-437`). 관측 파일은 declaration 마다 관측 디렉터리를 한 번 decode 해서 `request_id` 로 고른다. sweep 과 같은 읽기(`Lane_addon_exact_observation.request_id`, `server_unowned_exact_sweep.ml:95-100`)를 쓴다. decode 하지 못한 관측 파일은 그 파일을 찍는다. sweep 은 그런 파일 하나에 그 실행 전체를 멈춘다(`:96-100`, `:211-218`). main 은 거절의 `delete` 를 기록 경로만으로 만든다(`lane_addon_store_preflight.ml:133-147`, `:170`, `:290`). exact 검사는 지울 경로를 기록의 키로 정한다. 그래서 지울 경로를 미리 받는 다른 scan 의 읽기(`read_entries`) 대신 따로 돈다. L2b-1 은 main 의 `read_record` 에서 파일 하나를 읽고 해석하고 그사이 지워졌는지 보는 부분을 `read_file` 로, `scan_grouped` 에서 그룹 디렉터리를 도는 부분을 `scan_groups` 로 나눈다. exact 검사와 다른 scan 이 그 둘을 같이 쓴다.
5. Librarian 검사는 exact 요청을 가리키는 원본마다, exact 검사의 `fresh state` 줄을 지운 뒤 남을 exact 파일로 그 원본의 소비자가 멈추는지 본다. exact 검사가 거절할 기록은 그 증거와 같이 없는 것으로 본다. 기록과 증거는 2·3 과 같이 경로로 읽는다. 소비자의 읽기는 단계마다 다르다(§5 의 단계 표). final 이 없는 단계는 거절하지 않는다. Captured 와 Admission_wait 의 소비자는 exact 파일을 읽지 않는다. Dispatch_pending 의 소비자는 기록과 증거가 없거나 기록이 열려 있으면 worker 에 묻는다. 기록 없이 증거만 남으면 멈추지만, 그 증거는 exact 검사가 이름 없는 증거로 찍는다. final 을 가진 단계는 소비자처럼 final 을 얻고(`decode_final`) 확인한다(`confirm_final`). 접수 원본은 `keeper_librarian_admission_capture.ml` 의 `confirm_final` 을, history 원본과 floor 원본은 `keeper_librarian_original_final.ml` 의 `confirm_final` 을 따른다. 두 함수의 경우 나누기는 같다. 먼저 기록으로 경우를 나눈다(`observe_retained`). 기록이 없으면 worker 가 host 전에 거절한 final 만 통과한다(`refused_before_host`). 기록이 없는 다른 final 과 열린 기록은 거절한다. 끝난 기록은 기록이 전한 final 과 원본의 final 을 견준다. 증거는 final 이 `Call_final` 일 때만 읽는다(`read_latest_original_execution`). partition 과 supersession root part 는 원본 실행의 최신 증거를 직접 읽는다. 최신 증거가 없으면 멈추고, 있으면 `confirm_final` 로 확인한다. gate 는 부모 실행의 final 을 다시 확인하니 부모를 따른다. 확인이 실패하는 원본은 거절하고 그 owner 의 scope 를 모두 찍는다. admission owner 는 실행, parts, partitions, gate, closure 다(`keeper_librarian_admission_closure.ml:25-28`). history owner 와 floor owner 는 실행과 gate 다. scope 마다 그 digest 를 이름으로 한 디렉터리 셋을 찍는다. owner 기록(`tool-request-owners`), 요청 본문(`tool-request-bodies`), 정산된 원본(`tool-request-owners-settled`)이다. 이 build 가 읽지 않는 scope 를 지울 때 적는 세 디렉터리와 같다(`bin/deployment_preflight_helper.ml:845-847`). history owner 의 scope 는 fence 와 resolution 디렉터리도 찍는다. 그 둘의 이름도 scope 의 digest 로 정해진다(`lane_addon_store.ml:762-763`, `:805-806`). 검사를 두는 자리, 따르는 규칙, 읽는 입력은 아래에 적는다.

5 가 필요한 이유는 §5 의 소비자 표다. final 을 가진 Librarian 원본은 exact 기록과 증거가 없으면 멈춘다. worker 가 host 전에 거절한 final 만 예외다. version 1 증거가 남아도 멈춘다. 그래서 4 만으로는 설치 뒤 첫 pass 에서 그 원본이 멈춘다. owner 의 scope 를 모두 찍는 이유는 partition 과 gate 다. partition 은 크기 증거를 낸 실행 원본의 id 와, 그 실행의 최신 증거 발췌를 갖는다(`keeper_librarian_admission_parts.ml:267-269`). validator 는 parts 와 partitions 의 모양만 본다(`keeper_librarian_store_preflight.ml:66-73`). 가이드도 이 검사가 Memory parts discovery 를 돌리지 않는다고 적는다(`docs/guides/DURABLE-STORE-HARD-CUT.md` 의 Lane Add-on tool request owners 절). 그래서 실행 원본만 지우면 다시 돈 검사가 통과한다. 설치 뒤에는 `discover` 가 pass 마다 "Original parent execution is missing" 으로 멈춘다(`keeper_librarian_admission_parts.ml:228`, `:609-616`). gate 는 부모가 없으면 다음 검사에서야 거절된다(`keeper_librarian_store_preflight.ml:85-105`). 한 번에 다 찍어야 검사 한 번에 끝난다. workspace-curator 원본은 기록이 없으면 worker 에 묻고 이어 간다. 그래서 curator 의 validator 는 바꾸지 않는다.

**Librarian 검사의 자리.** 이 검사는 `Keeper_librarian_store_preflight.validator` 와 따로 둔다. L2b-2 는 런타임 동작을 바꾸지 않는다. validator 는 런타임에서도 돈다. `recover_closure` 가 closure 를 정산하기 전에 validator 로 그 closure 를 확인한다(`keeper_librarian_admission_owner.ml`). exact 기록과 증거는 런타임도 이미 읽는다. `discover` 는 실행 원본마다 `Commit.validate` 를 부르고, 그 함수는 판정을 가진 단계와 실행 단계 거절에서 `confirm_final` 을 부른다(`keeper_librarian_admission_commit.ml`). `run_queue` 는 큐의 pass 마다 `discover` 를 부르고, closure 복구는 Captured 단계에서만 부른다. validator 에 exact 읽기를 넣으면 `discover` 를 부르지 않는 Closing·Closed 단계의 closure 복구에 새 실패 지점이 생긴다.

검사는 Tool owners scan 안에서 돈다. 그래서 L2b-1 의 `read_file` 로 읽고, 읽는 사이 지워진 파일을 지운 것으로 보는 규칙(2)을 같이 쓴다. helper 는 Librarian 원본을 scan 의 `payload_validator` 자리에서만 확인한다(`validate_tool_request`). 그래서 `payload_validator` 에 exact 기록과 증거를 읽는 포트를 더하고, 거절 결과에 지울 경로 목록을 싣는다. main 의 거절은 그 기록의 scope 디렉터리만 찍는다. 이 타입이 바뀌면 validator 를 그 자리에 바로 넘기는 시험이 같이 바뀐다(`test_keeper_librarian_durable_execution.ml`, `test_keeper_librarian_addon_owner.ml`).

**root 가 다르면 멈춘다.** 검사는 증거를 decode 하기 전에 exact 검사처럼 `store_root` 를 견준다(3). 다르면 두 root 를 적고 Tool owners scan 을 멈춘다. 지울 줄은 찍지 않는다. root 가 다른 증거의 decode 는 오류 문자열 하나로 실패한다. 견주지 않으면 그 원본을 읽지 못한 것으로 보고 owner 의 scope 를 찍는다. helper 는 scan 마다 끝나는 대로 결과를 찍는다(`bin/deployment_preflight_helper.ml` 의 `on_result`). 그래서 exact scan 만 멈추면 Tool owners scan 의 지울 줄은 그대로 나온다.

**규칙은 하나다.** final 을 확인하는 경우 나누기는 두 벌이다. 접수는 `keeper_librarian_admission_capture.ml` 에, history 와 floor 는 `keeper_librarian_original_final.ml` 에 있다. L2b-2 는 그 경우 나누기를 `Keeper_librarian_original_final` 의 순수 함수 둘로 둔다. 그 모듈은 configured declaration 의 exact 요청을 묻는 원본 모두의 host 증거를 맡는다(`keeper_librarian_original_final.mli`). 첫째는 기록을 본 결과(`Retained_absent`, `Retained_open`, `Retained_terminal`)와 final 로 판정하거나, 최신 증거가 있어야 한다고 답한다. 증거가 있어야 하는 경우는 끝난 기록이 전한 final 이 원본의 final 과 같고 그 final 이 `Call_final` 일 때뿐이다. 둘째는 최신 증거로 판정한다. 두 `confirm_final` 은 첫째가 증거를 요구할 때만 증거를 읽는다. 그래서 증거를 읽는 때가 바뀌지 않는다. 판정은 거절 이유를 variant 로 돌려주고, 두 `confirm_final` 은 이유마다 자기 오류 문구를 붙인다. final 을 얻는 `decode_final` 은 한 벌이다(`keeper_librarian_original_final.ml`). strict decode 가 실패하면 끝난 기록의 Answered terminal 에서 final 을 되찾고 확인한다. L2b-2 는 그 경우 나누기도 같은 모듈의 순수 함수로 두고, `decode_final` 과 검사가 같이 부른다. 그래서 런타임 동작은 같다. 다른 소비자는 이 규칙을 쓰지 않는다. workspace-curator 원본은 기록이 없으면 worker 에 묻는다(§5).

**입력은 소비자와 같다.** 요청과 schema 는 소비자가 원본에서 요청을 만드는 함수로 얻는다. 접수, history, floor 모두 `request` 를 내보낸다. declaration 은 원본의 installation id 를 decode 해 얻는다(`Lane_addon_tool_request_owner.installation_of_id`). 기록에 저장된 요청으로 묶는 `check_retained_record` 는 exact 검사가 그 기록을 거절할지 정할 때만 쓰고, 확인에는 쓰지 않는다. 그 함수는 final 의 모양만 본다(`~schema:None`). 그래서 capture 와 요청이나 schema 가 다른 기록을 통과시킨다. `Lane_addon_exact` 는 `observe_retained` 와 `read_latest_original_execution` 이 store 에서 읽어 내는 값을, 경로로 읽은 기록과 증거의 JSON 에서 내는 순수 함수를 내보낸다. 거절은 exact 기록과 증거 때문에 소비자가 멈추는 경우만이다. manual installation 원본은 exact 기록을 찾을 declaration 이 없다. 그래서 이 검사가 거절하지 않는다. live owner 는 확인하지 않는다(`keeper_librarian_store_preflight.mli`).

version 1 증거를 아는 코드는 두지 않는다. version 1 증거는 정수 검사에서 거절된다. 바깥 `version` 이 2 가 아니다. preflight 는 그것을 "지금 reader 가 읽지 못하는 파일"로 본다.

**기록 없는 증거.** 기록 없는 증거가 생기는 길을 다섯 봤다.

- 서버가 증거를 쓸 때: attempt n 을 기록에 쓴 뒤에만 쓴다(§2.4). 기록 없는 증거를 만들지 않는다.
- sweep: 관측, 증거, 기록 순서로 지우고 처음 실패에서 멈춘다(`server_unowned_exact_sweep.ml:166-205`). 증거만 남는 일은 없다.
- main 의 preflight 가 거절한 exact 기록: `fresh state` 줄이 기록만 찍는다(`record_alone`, `lane_addon_store_preflight.ml:170`, `:290`). 그 줄대로 지우면 증거가 남는다. L2 는 증거도 찍어 이 길을 닫는다(4).
- JSON 으로 읽히지 않는 기록: 그 안의 `request_id` 와 `digest` 를 몰라 증거의 경로를 낼 수 없다(`lane_addon_store_preflight.ml:135-142`). 서버는 기록을 atomic rename 으로 쓴다(`lane_addon_store.ml:53-56`, `:323-326`). 그래서 서버가 이런 기록을 만들지는 않는다.
- 운영자가 `fresh state` 줄의 일부만 지울 때(§5).

그래서 preflight 는 증거 디렉터리를 이름으로도 본다. 읽은 기록의 `declaration_id` 로 증거 디렉터리를 안다. 그 디렉터리의 `.json` 이름 가운데 어느 기록의 `request_id` 와 `digest` 로도 나오지 않는 것을 찍는다(`proof_key`, `:630-632`). 파일은 열지 않고 목록만 본다. 순서는 2 와 같다. 기록 목록, 증거 디렉터리 목록, 기록 목록 순서로 보고, 두 번째 목록에 새로 보인 기록은 읽어서 이름을 낸다. 서버는 기록을 쓴 뒤에 증거를 쓴다. 그래서 증거 목록 뒤에 본 기록 목록에는 그 증거의 기록이 있다. 찍기 직전에 그 파일이 아직 있는지 본다. 검사 도중에 서버가 시작하면 시작 sweep 이 증거를 먼저, 기록을 나중에 지운다(`server_unowned_exact_sweep.ml:166-205`). 이미 지운 파일은 찍지 않는다. 이 방법으로도 찾지 못하는 것은 기록이 하나도 읽히지 않는 declaration 의 증거다. 증거 디렉터리의 이름이 `declaration_id` 로 정해져서다. 그 증거는 살아 있는 원본이 없으면 시작 sweep 이 지운다. Lane 설정에 있는 Librarian 과 workspace-memory package 의 declaration 만 그렇다(`server_unowned_exact_sweep.ml:48-50`, `:140-163`, `:211-212`, `:223-232`). 설정에서 빠진 declaration 의 증거는 남는다. 그 증거를 읽는 lane 도 없다.

12:53:00Z 의 저장소에 기록 없는 증거는 없다(§1.2).

**tinker 스크립트.** `check_validator_on_store.py:299-317` 은 증거의 `request.output` 으로 admission 요청을 고른다. L2 뒤에는 증거의 `request_id` 로 요청 기록(`exact-requests`)을 찾아 그 기록의 `request.output` 을 읽는다. L3 은 기록에서 `request` 칸을 뺀다. 그래서 §3.4 의 읽는 곳 목록에 이 스크립트를 넣었다.

**Fresh state 항목.** L2 의 PR 은 `changelog.d` 에 `Fresh state required` 항목을 둔다(`docs/guides/DURABLE-STORE-HARD-CUT.md`). 읽지 않는 것과 지울 것(§5)을 적는다. 읽지 않는 것은 version 1 증거와 그 증거에 묶인 slot 관측이다. 지울 경로는 preflight 의 `fresh state` 줄이 찍는다. 그 항목은 순서를 적는다. 서버를 멈추고, 검사하고, 찍힌 경로를 지우고, 설치하고, 서버를 시작한다. 첫 검사가 통과해도 그렇다(가이드의 1단계). 설치 스크립트는 옛 서버가 도는 동안 검사하고(`scripts/install-local-build.sh:153`, `:285`), 서버를 다시 띄우지 않는다(`:463`). L2 는 증거의 자리와 이름을 바꾸지 않는다. 그래서 옛 서버는 `masc restart` 전까지 증거를 남기는 호출마다 version 1 증거를 같은 자리에 쓴다(`lane_addon_exact.ml:1165-1174`). 증거가 없던 workspace 도 검사를 통과한 뒤에 새 서버가 읽지 못하는 증거를 가질 수 있다.

구현 전에 잴 것:

- 증거가 수십 개일 때와 수백 개일 때 읽기 한 번의 시간. 증거를 다 읽는 것은 L1 의 fold 와 attempt 묶기가 요구한다(§8).
- 설치 시점에 preflight 가 거절할 exact 기록의 수와, Librarian 검사가 찍을 Librarian owner 의 수(§5).
- validate-stores 의 최대 RSS. 검사는 §1.2 의 1.05 GB 증거 파일을 `run` 처럼 parse 하고 canonical 로 바꾼다.

2026-11-13 00:2x~00:3xZ 에 첫째와 셋째, 둘째 가운데 exact 기록의 수를 쟀다. Librarian owner 의 수는 재지 않았다. 라이브 저장소는 읽기만 했다.

증거에서 `request` 칸을 뺀 v2 모양 파일을 만들어 읽기 한 번의 CPU 시간을 쟀다. 증거 하나당 시간은 증거 수가 늘면 조금 는다. 증거 10개에서 866개로 가면 중앙값 크기는 0.035 ms 에서 0.051 ms 로, 90 백분위 크기는 0.22 ms 에서 0.26 ms 로 는다(아래 표의 계산값). 잰 것은 parse, canonical, 비교다. outcome 과 receipt 의 decode, 파일 읽기는 재지 않았다.

- 증거 하나의 모양은 라이브 증거 1,696개에서 골랐다. `request` 칸을 뺀 크기가 중앙값(1,515 바이트)인 것과 90 백분위(8,617 바이트)인 것이다. 문자열 값은 같은 길이의 다른 글자로 바꿨다.
- 읽기는 `load_proofs` 를 본떴다. parse, 링크의 canonical, 증거마다 canonical 두 번, 다시 만든 링크의 canonical, 비교다. canonical 은 `lane_addon_json.ml` 의 함수를 그대로 옮겼다.
- masc 밖의 독립 OCaml 5.5.2 프로그램이고, 프로세스 하나에서 일곱 번 잰 중앙값이다.
- 그때 기계의 load average 는 461 이었다(CPU 16개). 그래서 wall 시간이 수십 배 흔들렸고, 프로세스 CPU 시간을 적는다.

| 증거 수 | 중앙값 크기 | 90 백분위 크기 |
|---|---|---|
| 10 | 0.35 ms | 2.2 ms |
| 30 | 1.4 ms | 7.0 ms |
| 100 | 4.8 ms | 24.9 ms |
| 300 | 15.4 ms | 76.2 ms |
| 866 | 44.2 ms | 226 ms |

거절된 호출 한 번은 이 읽기를 세 번 한다(§3.3 의 쓰기). 30 MB 이하의 증거 파일 471개 가운데 증거가 50개를 넘는 파일은 둘이다(866개, 223개). 둘 다 끝난 요청이다. 30 MB 를 넘는 파일은 §1.2 의 그 파일 하나다. 그 파일은 증거별로 세지 않았다(attempt 292).

설치 때 거절할 exact 기록은 00:32:17Z 에 472개다. 기록 477개 가운데 증거 파일을 가진 것이다. 그 가운데 열린 기록은 6개다. 증거는 모두 version 1 이라 L2 를 설치할 때 모두 거절된다. Librarian owner 의 수는 L2b-2 의 Librarian 검사가 설치 때 센다. 13:33:53Z 의 값은 §5 에 있다.

§1.2 의 1,055,315,219 바이트 파일을 위 프로그램으로 한 번 parse 하고 canonical 로 바꿨다. CPU 8.4 초(user 7.6, sys 0.8), wall 56.2 초가 걸렸고, 최대 RSS 는 2,990,342,144 바이트였다. L2 를 설치할 때 검사는 이 파일을 한 번 parse 하고, 링크 전체를 canonical 로 바꾼 뒤 첫 증거에서 거절한다(`decode_proofs`). L2b-3 의 decode 는 증거마다 바깥 `version` 을 다른 칸보다 먼저 본다. main 의 decode 는 schema 와 outcome 을 본 뒤에 version 을 본다.

### 3.4 L3 — 요청 기록 (방향)

- 요청 본문은 digest 를 이름으로 한 파일에 한 번 저장한다. `save_tool_request_body`(`lane_addon_store.ml:870`)와 같은 방식이다.
- 요청 기록은 `{digest; attempts; final}` 이다.
- `run` 은 호출자가 넘긴 요청에서 digest 를 계산해 기록과 견준다. 본문 파일은 요청을 다시 읽어야 하는 곳만 연다.

기록의 `request` 칸을 읽는 곳:

- `bound_record`(`lane_addon_exact.ml:495-509`)와 `run`(`:1026-1031`): 호출자의 요청, digest 와 견준다.
- `check_retained_record`(`:572-582`): preflight 가 기록만으로 요청을 다시 만든다. L2 뒤에는 그 요청으로 증거도 decode 한다(§3.3).
- `scripts/tinker/librarian/exact_store.py`: E-real snapshot 이 기록에서 요청과 답을 읽는다.
- `scripts/tinker/librarian/check_validator_on_store.py`: L2 뒤에 admission 요청을 고를 때 기록의 `request.output` 을 읽는다(§3.3).

구현 전에 정할 것:

- 본문 파일을 두는 디렉터리. sweep 은 declaration 디렉터리에서 `.json` 이 아닌 이름을 만나면 멈춘다(`server_unowned_exact_sweep.ml:54-75`).
- 본문 파일을 지우는 곳과 읽는 곳. 요청 기록이 지워질 때 본문이 남지 않아야 한다.
- preflight 가 증거를 decode 할 때 쓸 요청. `decode_proof` 는 요청의 `request_id` 와 `schema` 를 쓴다(§3.3).
- E-real snapshot 이 요청 본문을 읽을 곳.

attempt 목록은 한 파일에 둔다. 항목 하나는 수백 바이트다. 목록의 길이는 #50762 에서 다룬다.

L2 를 설치하면 요청 본문은 디스크에 한 벌만 남는다. 요청 기록 안이다. L3 이 줄이는 것은 기록을 읽고 쓸 때마다 함께 오가는 본문이다. §1.2 의 열린 `classification` 기록은 3,891,857 바이트다. 그 가운데 요청이 3,779,582 바이트, attempt 312개가 112,073 바이트다(12:56:08Z). 기다리는 slot 만 있는 실행은 기록을 한 번 읽고 한 번 쓴다(§3.2 6). 증거를 남긴 실행은 기록을 두 번 쓴다. 시작 표시(`:1110-1115`)와 끝(`:1187-1192`)이다. 새 기록의 첫 실행은 부르기 전에 한 번 더 쓴다(`:1132-1134`). 기록을 읽을 때마다 `bound_record` 는 요청 본문을 canonical 로 네 번 지난다. 요청이 든 기록 전체로 두 번(`:496`, `:498-499`), 요청만 두 번이다(`:503-504`). digest 두 번(`:505-506`)은 L2a 가 없앤다(§3.3). resume 도 `bound_record` 를 부른다(`:956`, `:976`). L2 를 설치한 뒤, 열린 요청 하나가 실행과 resume 마다 기록을 읽고 쓰는 횟수, 바이트, 시간을 잰다. 그 값으로 L3 을 할지 정한다(§9 D3).

### 3.5 하지 않는 것

- slot 을 시간이나 횟수로 쉬게 하지 않는다.
- 같은 model 을 쓰는 다른 slot 의 거절로 미루어 판단하지 않는다. slot 마다 자기 답을 받는다.
- `detail` 글에서 slot 이름이나 거절 종류를 읽지 않는다.
- 깨우는 장치를 더하지 않는다. host event 는 지금의 다섯 그대로다.
- attempt 를 지우거나 합치지 않는다.
- receipt 에 칸을 더하지 않는다. 로컬 거절을 가르려면 칸이 필요하고, 그것은 저장 모양을 바꾸는 일이다.
- 기다리는 slot 없이 열려 있는 요청은 건너뛰지 않는다. 다른 slot 이 시각 없는 429, 5xx, 인증 거절로 실패하는 경우다. 그 slot 의 결과는 걷기 전에 알 수 없다. 덮으려면 걷기가 "지나갈 수 있는 실패가 나오면 거절한 slot 앞에서 멈춘다"를 알아야 한다(§9 D4).
- `Invalid_request` 로 거절한 slot 은 상태 코드가 400 이어도 건너뛰지 않는다. §1.1 의 두 400 은 종류가 다르다. tinker 계열의 것은 본문으로 정해진다. claude 계열의 것은 계정의 상태로 정해지고 본문과 무관하게 풀린다. receipt 의 타입도 상태 코드도 둘을 가르지 못한다. 가르지 못한 채 건너뛰면 계정의 400 이 풀려도 그 slot 은 기다리는 HTTP slot 이 하나도 없는 host event 까지 불리지 않는다. 기다림은 요청별 값이 아니다. candidate 와 quota scope 별 표에 있고(`lib/runtime/runtime_candidate_standing.ml:96-133`), 그 slot 을 쓰는 다른 호출의 결과가 그 표를 바꾼다. 그런 host event 는 기다리는 HTTP slot 이 모두 풀린 뒤에야 온다. 다른 호출이 거절될 때마다 기다림이 새로 생긴다. 그래서 풀리는 시각이 엇갈린 slot 이 여럿이면 그 host event 가 오는 때에 상한이 없다(§8, §9 D5).
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

L2 는 증거의 모양을 바꾸고 L3 은 기록의 모양을 바꾼다. 옛 모양을 읽는 코드는 만들지 않는다(헌법 `legacy_residue`, `docs/guides/DURABLE-STORE-HARD-CUT.md`). L1 은 hard cut 이 없다.

**L2 뒤에 version 1 증거 파일이 남으면.** 그 파일을 읽는 함수만 실패한다.

| 함수 | 그 파일을 읽는 때 | 결과 |
|---|---|---|
| `run` | 시작할 때(`lane_addon_exact.ml:1039-1040`) | 오류. 요청은 끝나지도 다시 보내지지도 않는다 |
| `read_latest_original_execution` | 기록이 있든 없든(`:879-888`) | 오류. 이것을 부르는 Librarian 의 다섯 곳이 멈춘다(아래 표). `read_original_execution` 도 같은 읽기다. `lib/` 에서 부르는 곳은 없다 |
| `read_latest_slot_observations` | 위 함수로 읽을 때(`:904-913`) | 오류. Candle 과 curator 는 경고를 남기고 `None` 으로 간다 |
| `recover_retained` | 같은 요청을 잡은 쪽이 없을 때(`:941-959`) | `Recovery_invalid`. resume 이 그 원본을 거절한다(`lane_addon_submit_once.ml:97-102`) |
| `observe_retained`, 잡은 쪽이 있을 때의 `recover_retained` | 읽지 않는다. 기록만 본다(`:604-620`, `:940`) | 영향 없다 |
| `proof_request_id`(sweep) | `request_id` 와 `digest` 칸만 읽는다 | 영향 없다(§3.3) |

preflight 가 설치 전에 그런 기록과 Librarian 원본을 거절한다(§3.3).

**L2 를 설치할 때 지우는 것.** preflight 의 `fresh state` 줄이 경로를 찍는다.

| 지울 것 | 찍는 검사 | 지운 뒤 |
|---|---|---|
| 증거 파일이 있는 exact 요청 기록, 그 증거 파일, 그 요청의 slot 관측 파일 | `Exact_requests` scan(§3.3 의 4) | 그 요청의 원본은 `Retained_absent` 를 본다(`lane_addon_exact.ml:950-953`). 소비자별 결과는 아래 표다 |
| 그 기록을 가리키는, final 을 가진 Librarian 실행 원본의 owner 가 가진 scope 전부. scope 마다 owner 기록, 요청 본문, 정산된 원본의 디렉터리. history owner 의 scope 는 fence 와 resolution 디렉터리도 | Librarian 검사(§3.3 의 5) | 그 owner 의 접수, parts, gate, history 작업이 사라진다. 다시 만들어지는지는 확인하지 않았다(§10) |

12:53:00Z 에 증거 파일이 있는 기록은 140개다. 그 가운데 같은 request id 의 소비자 원본이 있는 것은 86개다(§1.2). 13:33:53Z 에 Librarian 쪽을 다시 셌다. 증거 파일이 있는 기록은 152개다. 그 기록을 가리키는 Librarian owner 는 admission 5, history 5 다. floor owner 는 없다. admission owner 다섯은 모두 parts(파일 55)와 gate(파일 79)를 가진다. partitions 는 없고, closure 디렉터리가 하나 있다(파일 없음). history owner 다섯은 gate, fence, resolution 이 없다. 같은 기록을 가리키는 다른 원본 기록은 candle-appraisals 13개, workspace-curator 17개다.

**exact 기록과 증거가 없을 때, 소비자별로.**

| 소비자 | 읽는 곳 | 결과 |
|---|---|---|
| Librarian | `observe_retained` 와 `read_latest_original_execution`. 접수(`keeper_librarian_admission_capture.ml:372`, `:389`), 크기 검사(`keeper_librarian_admission_parts.ml:243`), history·floor final(`keeper_librarian_original_final.ml:22-78`), history 정리(`keeper_librarian_history_resolution.ml:73-78`). 원본 resume(§2.3) | 접수 원본은 "Original admission host terminal is absent" 로 멈춘다(`keeper_librarian_admission_capture.ml:382`). history 원본과 floor 원본은 "Original history host terminal is absent" 로 멈춘다(`keeper_librarian_original_final.ml:56`). worker 가 host 전에 거절한 final 은 두 곳 모두 예외다. 크기 검사는 "Original latest execution proof is incomplete" 로 멈춘다(`keeper_librarian_admission_parts.ml:247`). 나눈 part 는 다시 보낸 요청의 receipt 가 발췌와 달라 "Original subdivision proof changed" 로 멈춘다(`:600`) |
| workspace-curator | 원본 resume(§2.3). 끝날 때 slot 관측(`server_workspace_memory_addon.ml:591-601`) | resume 은 `Retained_absent` 를 보고 worker 에 묻는다(`lane_addon_submit_once.ml:214-218`). slot 관측은 경고 없이 `None` 이다 |
| Candle appraiser | slot 관측(`server_candle_appraiser.ml:218-227`) | 경고 없이 `None` 이다 |
| operator quiz | host 쪽에서 증거를 읽는 곳을 찾지 못했다 | |

**Librarian 원본의 단계별 exact 읽기.** origin/main 2ed0170118fd 를 읽어 적었다. 접수, history, floor 실행 원본은 같은 단계를 쓴다(`lane_addon_request_progress.ml`). floor 는 Captured, Admission_wait, Dispatch_pending, Judged, 실행 단계 Rejected 만 쓴다(`keeper_librarian_floor_step_owner.ml`).

| 단계 | 소비자 | exact 읽기 | 기록과 증거가 없으면 |
|---|---|---|---|
| Captured, Admission_wait | `Lane_addon_submit_once` 의 `resume`. 접수와 history 의 검증은 이 단계를 통과시킨다(`keeper_librarian_admission_commit.ml`, `keeper_librarian_durable_commit.ml`) | 없다 | worker 에 묻는다 |
| Dispatch_pending | `resume` 의 `recover_retained`(`lane_addon_exact.ml`) | 기록과 모든 증거. 끝난 기록이면 final 을 확인한다 | worker 에 묻는다. 기록이 열려 있어도 묻는다. 기록 없이 증거만 있으면 멈춘다 |
| Judged, Committing, Commit_unknown, Finished, Conflicted | 접수 `Commit.validate`, history `original_answer`, floor `terminal` | `decode_final`, `confirm_final` | 멈춘다 |
| Rejected(실행 단계) | 접수 `Commit.validate`, history `validate_with`, floor `resume` | 저장된 final 로 `confirm_final` | `Request_body_refused` 만 통과하고 나머지는 멈춘다 |
| Rejected(dispatch 전), Subdividing, Subdivided | 접수와 history 의 검증 | exact 를 읽기 전에 오류로 끝난다 | 해당 없음 |

- partition 과 supersession root part 는 원본 실행의 최신 증거를 직접 읽는다(`keeper_librarian_admission_parts.ml` 의 `check_size`, `terminal_witness`). 최신 증거가 없으면 멈추고, 있으면 `confirm_final` 로 확인한다. payload 에 둔 증거 발췌(attempt, receipt, final)를 새로 읽은 값과 견준다.
- gate 는 복원할 때마다 부모 실행의 `decode_final` 과 `confirm_final` 을 부른다(`keeper_librarian_original_gate.ml`).
- closure 는 Captured 단계에서만 `discover` 로 위 읽기를 한다. Closing 과 Closed 는 읽지 않는다.
- fence 가 있는 history 원본은 검증과 resume 에서 빠져 exact 파일을 읽지 않는다. resolution intent 는 기록과 증거가 둘 다 없어야 fence 로 간다(`no_host_result`).
- 소비자는 exact 파일을 읽기 전에 살아 있는 owner(작업 공간, Memory epoch, queue generation)를 다시 본다. 파일만 읽는 검사는 이것을 따라 하지 않는다.

final 을 가진 Librarian 원본은 version 1 증거가 남아도 멈추고, 기록과 증거를 지워도 멈춘다. 그래서 그 원본의 owner 가 가진 scope 를 같이 지운다. Dispatch_pending 원본은 version 1 증거가 남으면 멈추고, 기록과 증거를 지우면 worker 에 묻는다. 그래서 exact 파일만 지운다. history 정리(`no_host_result`)는 기록과 증거가 없으면 그 원본에 host 결과가 없다고 판단한다(`keeper_librarian_history_resolution.ml:65-81`).

**운영자가 `fresh state` 줄의 일부만 지우면** 다시 돈 검사가 남은 것을 찍는다. exact 기록과 증거만 지우고 Librarian scope 를 남기면, Librarian 검사가 그 원본의 소비자처럼 판단한다(§3.3 의 5). 기록이 없어 소비자가 멈출 원본은 거절하고 그 owner 의 scope 를 다시 찍는다. 증거만 남기면 이름으로 찾아 찍는다(§3.3). 찍힌 줄을 다 지우는 것은 다른 fresh state 줄과 같이 운영자의 몫이다(가이드의 2·3단계).

**preflight 가 잡지 못하는 것.**

- 기록이 하나도 읽히지 않는 declaration 의 증거(§3.3). 12:53:00Z 에는 기록 없는 증거가 없다.
- 검사를 통과한 뒤 옛 서버가 쓴 version 1 증거. 설치 스크립트는 서버를 다시 띄우지 않아서, 옛 서버는 `masc restart` 전까지 쓴다(`scripts/install-local-build.sh:463`). Fresh state 항목이 순서를 적는다. 멈춤, 검사, 지움, 설치, 시작이다(§3.3). 검사가 서버가 멈췄는지 확인하지는 않는다. 부팅 때 막는 안은 §8 에 적었다.

**L3 을 설치할 때**는 exact 요청 기록 전부가 대상이다. 기록의 모양이 바뀌어 `check_retained_record` 가 모두 거절한다. 같은 규칙으로, 거절한 기록마다 그 증거 파일과 slot 관측 파일, 그 기록을 가리키는 Librarian 실행 원본의 owner 가 가진 scope 를 같이 지운다. L2 의 preflight 가 그 줄을 찍는다.

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
| L2b-3 | 증거를 남긴 파일에 `request` 칸이 없다. 파일의 크기가 요청 본문의 크기에 따라 늘지 않는다 | 는다 |
| L2b-3 | 다른 요청으로 읽으면 거절한다. `digest` 가 다르다 | 본문 비교로 거절 |
| L2b-3 | version 1 증거 파일은 읽기를 거절한다 | 읽는다 |
| L2b-3 | 바깥 `version`, `attempt_ordinal`, receipt `version` 가운데 하나가 정수로 떨어지는 float(`2.0`)면 거절한다 | receipt version 1 이면 읽는다 |
| L2b-3 | receipt version 1 이 든 증거는 거절한다 | 읽는다 |
| L2b-3 | sweep 은 증거의 `request_id` 와 `digest` 로 파일 이름을 확인한다. 다른 이름 아래에 있으면 멈춘다 | 본문으로 확인 |
| L2b-3 | preflight 는 version 1 증거가 있는 기록을 거절하고 기록, 증거, 그 요청의 slot 관측 파일의 경로를 찍는다 | 증거를 읽지 않는다 |
| L2b-1 | preflight 가 첫 기록을 읽은 뒤 attempt 와 증거가 보태져도 그 기록을 거절하지 않는다. 그 사이에 `after_read` 로 보탠다(`lane_addon_store_preflight.ml:133-138`) | 해당 없음 |
| L2b-1 | 증거 디렉터리에 어느 기록으로도 나오지 않는 이름이 있으면 그 파일을 찍는다. 검사가 기록 목록을 본 뒤 서버가 쓴 기록과 증거는 찍지 않는다. 찍기 전에 사라진 파일도 찍지 않는다 | 해당 없음 |
| L2b-1 | decode 하지 못한 slot 관측 파일을 찍는다 | 찍지 않는다 |
| L2b-1 | 기록의 경로가 그 JSON 의 `declaration_id`·`request_id` 로 낸 경로와 다르면, decode 할 수 있어도 그 기록 파일만 찍는다 | decode 할 수 있으면 통과한다. 하지 못하면 기록 파일만 찍는다 |
| L2b-1 | `--base-path` 를 `<ws>/.masc/`, `<ws>/./`, `<ws>` 를 가리키는 symlink 로 주어도 `<ws>` 로 돈 서버의 증거를 읽는다 | `<ws>/.masc/` 면 `<ws>/.masc/.masc` 를 훑고 통과한다. 나머지 둘은 맞는 디렉터리를 훑는다(`lib/core/common.ml:99-100`). 기록만 읽어 root 를 견주지 않는다 |
| L2b-1 | 증거나 slot 관측의 `store_root` 가 검사의 root 와 다르면 지울 줄을 찍지 않고 두 root 를 적고 끝난다 | 해당 없음 |
| L2b-2 | final 을 가진 접수 원본의 exact 기록이 없으면 Librarian 검사가 그 원본을 거절하고 그 owner 의 scope 를 모두 찍는다. worker 가 host 전에 거절한 final 은 통과한다 | 통과한다 |
| L2b-2 | Dispatch_pending 원본은 exact 기록과 증거가 없거나 exact 검사가 그 기록을 거절해도, Librarian 검사가 거절하지 않는다 | 같다 |
| L2b-2 | strict decode 가 실패한 판정은 끝난 기록의 Answered terminal 에서 final 을 되찾아 확인한다. 같으면 통과한다 | 같다 |
| L2b-2 | 기록 없이 증거만 남은 `Request_body_refused` 원본은 통과한다. 그 증거는 exact 검사가 찍는다 | 같다 |
| L2b-2 | 증거의 `store_root` 가 검사의 root 와 다르면 Librarian 검사도 두 root 를 적고 멈추고, owner 의 scope 를 찍지 않는다 | 해당 없음 |
| L2b-3 | Librarian 검사는 version 1 증거를 가리키는, final 을 가진 실행 원본을 거절하고 그 owner 의 scope 를 모두 찍는다. Dispatch_pending 원본은 거절하지 않는다 | 통과한다 |
| L2b-3 | partition 의 실행 원본이 version 1 증거를 가리키면, 검사 한 번이 그 owner 의 실행, parts, partitions, gate, closure 를 찍는다. 찍힌 것을 지우면 다시 돈 검사가 통과한다 | 통과한다 |
| L3 | attempt 를 보탤 때 요청 본문 파일을 다시 쓰지 않는다 | 다시 쓴다 |

## 7. 층

| 층 | 내용 | 파일 |
|---|---|---|
| L1a | receipt 하나에서 slot 별로 불렀는지와 입력 크기 거절인지를 읽는 함수와 시험 | `keeper_exact_walk_receipt.ml`·`.mli` |
| L1b | `run` 이 증거에서 목록을 모아 runner 에 넘긴다. runner 가 기다리는 slot 이 있을 때 건너뛴다 | `lane_addon_exact.ml`·`.mli`, `server_lane_addon_exact.ml`, TUI·dashboard 글 |
| L2a | 요청과 그 digest 를 묶은 값. `lane_addon_exact.ml` 안의 하위 모듈로 두고 내보내지 않는다. 요청 레코드도 파일 안에서 private 로 둔다. 호출자의 요청에 증거나 기록을 묶는 읽기와 쓰기가 그 값을 받는다. 저장 모양과 동작은 같다(#51751) | `lane_addon_exact.ml` |
| L2b-1 | preflight 의 exact 검사가 `run` 과 같은 decode 로 기록, 증거 파일, 기록 순서로 읽는다. 거절한 기록의 `fresh state` 줄에 증거 파일과 그 요청의 slot 관측 파일을 같이 찍는다. 이름으로 찾는 기록 없는 증거, decode 하지 못한 slot 관측, 증거와 관측의 `store_root` 비교, 서버와 같은 함수로 정하는 store root | `lane_addon_exact.ml`·`.mli`, `lane_addon_store_preflight.ml`·`.mli`(`:39` 의 `Exact_record` 설명 포함), `lane_addon_exact_observation.ml`·`.mli`, `bin/deployment_preflight_helper.ml`, `docs/guides/DURABLE-STORE-HARD-CUT.md`, `test/test_lane_addon_exact.ml`, `test/test_deployment_store_directories.ml`, `changelog.d` |
| L2b-2 | Librarian 검사가 원본마다 exact 검사의 fresh state 뒤에 남을 exact 기록과 증거를 그 원본의 소비자와 같은 단계별 규칙과 입력으로 읽는다(§5 의 단계 표). 소비자가 멈출 원본은 거절하고 그 owner 의 scope 를 모두 찍는다. 증거의 root 가 다르면 멈춘다. 접수의 final 확인 규칙을 history 와 floor 가 쓰는 `Keeper_librarian_original_final` 의 순수 함수 둘로 모으고, `decode_final` 의 경우 나누기도 순수 함수로 둔다. `payload_validator` 에 exact 포트와 거절의 지울 경로를 더한다. validator 는 바꾸지 않아 런타임 동작은 같다 | `keeper_librarian_store_preflight.ml`·`.mli`, `keeper_librarian_admission_capture.ml`, `keeper_librarian_original_final.ml`·`.mli`, `lane_addon_exact.ml`·`.mli`, `lane_addon_store_preflight.ml`·`.mli`, `bin/deployment_preflight_helper.ml`, `docs/guides/DURABLE-STORE-HARD-CUT.md`, `test/test_keeper_librarian_addon_owner.ml`, `test/test_keeper_librarian_durable_execution.ml`, `changelog.d` |
| L2b-3 | 증거에서 `request` 칸을 뺀다. 바깥 `version` 을 먼저 보는 decode 와 정수 검사, version 2 receipt 만 읽는 `Keeper_exact_walk_receipt.of_json`, 파일의 `request_id`·`digest` 칸으로 하는 sweep 의 이름 확인, version 1 을 거절하는 preflight 와 Librarian 검사의 시험, tinker 스크립트, Fresh state 항목 | `lane_addon_exact.ml`, `keeper_exact_walk_receipt.ml`·`.mli`, `scripts/tinker/librarian/check_validator_on_store.py`, `test/test_lane_addon_exact.ml`, `test/test_lane_addon_exact_runner.ml`, `test/test_keeper_librarian_addon_owner.ml`, `test/test_lane_addon_host_cycle.ml`(`:18`), `test/test_workspace_curator_addon_commit.ml`(`:262`), `changelog.d` |
| L3 | 요청 본문을 기록 밖으로 | `lane_addon_exact.ml`, `lane_addon_store.ml`, preflight |

L1a 는 부르는 곳이 L1b 다. 둘을 한 스택으로 올린다.

L2a 는 L2b 의 아래 층이다. 혼자 병합돼도 동작은 같다(#51751). L2b 의 세 층은 한 스택으로 올린다. 스택은 맨 위 PR 로 한 번에 병합되니, 쓰는 쪽, 읽는 쪽, sweep, preflight 가 같은 모양으로 들어간다. L2b-1 과 L2b-2 는 version 1 증거로도 맞게 돈다. 두 검사는 그 기록을 읽는 쪽의 decode 를 쓴다(§3.3 의 preflight). 그래서 L2b-3 이 decode 를 바꾸면 검사도 같이 바뀐다. §6 에서 version 1 을 거절하는 행은 L2b-3 의 decode 가 들어와야 통과하니 L2b-3 의 시험이다. preflight 의 행은 `test_lane_addon_exact.ml` 의 deploy preflight 묶음에 둔다. 그 묶음은 기록과 증거를 `run` 으로 쓴다. Librarian 검사의 행은 `test_keeper_librarian_addon_owner.ml` 에 둔다. 증거가 version 2 receipt 만 담으면 `Keeper_exact_walk_receipt.of_json` 의 version 1 갈래를 lib 에서 부르는 곳이 없다. L2b-3 이 그 갈래를 지운다. version 1 receipt 를 만드는 `make` 는 `keeper_librarian_runtime.ml` 이 메모리에서 쓰니 남는다. `test_lane_addon_host_cycle.ml:18` 과 `test_workspace_curator_addon_commit.ml:262` 는 version 1 receipt(`Receipt.make`)를 runner 결과로 돌려준다. `run` 이 그 receipt 를 증거에 담으니 L2b-3 에서 `make_v2` 로 바꾼다.

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
| 증거를 attempt 마다 파일 하나로 둔다. 요청마다 디렉터리 하나 | 쓰기는 증거 하나로 준다. 읽기는 줄지 않고 n개를 다 읽는다. `run` 은 걷기 전에 모든 증거를 attempt 에 묶는다(`bind_proofs`, `:797-798`). L1 은 slot 마다 그 slot 을 부른 가장 최근 증거를 찾는다(`size_refused_slots`, `:809-824`). 상태가 는다. 빈 디렉터리와 쓰다 만 파일만 든 디렉터리가 생긴다. sweep 은 declaration 디렉터리에서 `.json` 이 아닌 이름을 만나면 멈춘다(`server_unowned_exact_sweep.ml:54-75`). sweep, preflight, 관측의 읽기가 모두 바뀐다. L2 뒤의 쓰기는 호출당 n × 3.5 KB 다(계산값). n 은 그 요청의 호출 수다(§3.3) |
| 증거를 attempt 마다 파일 하나로 둔다. 한 디렉터리에 두고 이름에 ordinal 을 넣는다 | 요청 기록 없이는 어떤 ordinal 이 있는지 알 수 없다. 기록이 없는데 증거가 있으면 세 읽기가 오류로 멈춘다(`lane_addon_exact.ml:858-861`, `:881-884`, `:951-954`). 이름에 ordinal 을 넣으면 그 읽기들이 증거를 찾지 못하고 없다고 읽는다. 기록을 잃어도 증거는 숨지 않는다는 성질(`:712-714`)을 잃는다. 디렉터리를 통째로 훑으면 읽기 한 번이 그 declaration 의 지난 요청 수에 비례한다 |
| 증거를 요청마다 append-only 파일로 둔다 | 쓰기는 증거 하나로 준다. 읽기는 줄지 않는다(위 줄). 쓰다 끊긴 꼬리를 다루는 규칙은 `Fs_compat` 에 있다(`fs_compat.mli:1436`, `:1729`, `:1833`). 그 규칙을 쓰는 읽기 길이 이 저장소에 새로 생긴다. 파일이 JSON 하나에서 줄 단위로 바뀌어 sweep 과 preflight 의 읽기도 바뀐다. 남는 몫은 n 에 비례한다 |
| 최신 증거 하나만 읽는다 | `.mli` 의 약속(모든 증거를 견준 뒤 돌려준다)을 바꾼다. L1 은 slot 마다 그 slot 을 부른 가장 최근 증거를 찾는다. 최신 증거가 그 slot 을 모르면 앞 증거를 봐야 한다(`size_refused_slots`, `:809-824`) |
| 거절한 exact 기록의 `fresh state` 줄에, 같은 request id 의 소비자 원본 scope 를 모두 같이 찍는다 | 검사 한 곳에서 끝난다. 대신 기록이 없어도 이어 가는 원본까지 지운다(workspace-curator, §5). 원본을 지울지는 그 소비자의 읽기가 정한다(#49587). 그래서 Librarian 검사가 찍는다(§3.3 의 5) |
| preflight 가 `host-results` 의 파일을 모두 열어 version 1 증거를 찍는다 | 이름 목록으로 찾는 것(§3.3)보다 더 잡는 것은 기록이 하나도 읽히지 않는 declaration 의 증거다. 대신 증거 파일을 기록 쪽 읽기와 따로 한 번 더 연다. §1.2 의 1.05 GB 파일도 두 번 parse 한다. 디렉터리마다 무엇의 파일인지도 열어서 가려야 한다 |
| 이 build 의 검사를 base-path lease 아래에서 돌려, 서버가 멈춘 뒤에만 통과하게 한다(`bin/deployment_preflight_helper.ml:360-365`) | 모든 설치가 서버를 멈춰야 돈다. 검사는 옛 서버가 도는 동안 돌도록 돼 있다(`lane_addon_store_preflight.mli:13-15`, `scripts/install-local-build.sh:153`). 이 cut 하나의 조건을 모든 설치에 건다 |
| 이 cut 을 부팅 때 막는다. 증거 store 를 부팅이 읽고 거절하는 store 로 바꿔, version 1 증거가 있으면 새 서버가 시작하지 않게 한다(`scripts/install-local-build.sh:277-283`) | 부팅마다 증거를 모두 parse 해야 한다. 시작 sweep 이 읽는 증거는 2026-11-06 에 약 2.7 GB 였다. 그래서 sweep 은 준비를 붙잡지 않도록 worker domain 에서 읽는다(`server_runtime_startup_maintenance.ml:180-182`). 부팅 검사는 준비 전에 끝나야 한다 |
| version 2 증거에서 `store_root` 를 뺀다 | 증거의 identity 에 Store root 가 든다는 것은 `.mli` 가 적은 약속이다. 작업 공간 디렉터리를 옮기면 그 증거는 어긋난 identity 가 되고 읽기가 `Error` 를 돌려준다(`lane_addon_exact.mli:322-324`). L2 는 그 약속을 바꾸지 않는다. 관측 파일의 `request_id` 읽기도 root 를 견준다(`lane_addon_exact_observation.ml:30-35`) |
| 건너뛴 slot 의 지난 거절을 새 receipt 에 옮겨 담는다 | receipt 에 칸이 는다. 저장 모양이 바뀌고 읽는 쪽을 같이 고쳐야 한다. 기다리는 동안만 건너뛰면 필요 없다 |
| `Invalid_request` 와 로컬 거절도 건너뛴다 | 본문만으로 정해지지 않는 거절이 섞여 있다(§2.1). 로컬 거절은 receipt 에서 타입으로 가를 수 없다(§2.5) |
| 상태 코드 400 의 `Invalid_request` 만 건너뛴다 | 400 안에도 계정의 상태로 난 거절이 있다(§1.1 의 지출 한도). 그 slot 을 다시 부르는 때가 다른 slot 의 기다림으로 정해지고 상한이 없다(§3.5). 400 을 고를 근거는 잰 표본뿐이다. 같은 분류의 422 를 뺄 이유가 없다(`retry.ml:370-371`). RFC 9110 15.5.1 은 400 을 다시 보내지 말라고 적지 않는다(2026-11-12 확인, https://www.rfc-editor.org/rfc/rfc9110.html, 신뢰도 High) |
| provider 의 400 문장을 읽어 context window 초과와 지출 한도를 가른다 | 문자열 분류기다. provider 가 문장을 바꾸면 조용히 틀린다 |
| slot 이 같은지를 receipt 의 `attempts[].plan` 으로 본다 | `plan` 은 catalog generation 을 담는다(§2.5). 무관한 target 하나가 바뀌면 열린 요청 전부가 거절했던 slot 에 본문을 한 번씩 다시 보낸다. L1 의 비교는 그 경우 건너뛴다 |
| slot 이 같은지를 target fingerprint 와 `attempts[].body` 로 본다 | lane 의 `max_output_tokens`·`thinking` 이 wire 본문을 바꾸면 그 slot 을 바로 다시 부르게 된다(§9 D1 의 대가 일부). 대신 host event 마다, 거절 증거가 있는 slot 마다 본문을 걷기 전에 직렬화한다. 측정한 요청은 2,173,367자다. 운영자가 그 값을 바꾸고 기다린 일은 잰 적이 없다. 필요가 재어지면 다시 연다 |

## 9. 사용자 결정

| | 결정 | 추천 | 계약 | 대가 |
|---|---|---|---|---|
| D1 | slot 이 같은지 무엇으로 보나 | slot id, target fingerprint, 보내는 schema | C2 | 셋이 덮지 않는 것이 바뀌어도 그 slot 은 기다림이 끝날 때에야 다시 불린다. lane 의 `max_output_tokens`·`thinking`, credential 값, provider 가 같은 target 에서 올린 한도, gateway 의 본문 한도가 그렇다. 측정한 경우 그 기다림은 나흘이다. 바로 부르게 하려면 운영자가 기다리는 slot 을 lane 에서 빼거나 target 을 바꾼다. lane 의 두 값까지 견주려면 증거에 칸을 더해야 한다(저장 모양 변경) |
| D2 | L1 에서 `Every_slot_held` 의 뜻을 넓히나, variant 를 더하나 | 뜻을 넓힌다 | §3.2 6번 | TUI·dashboard 의 "모든 slot 이 기다림" 글을 "부를 slot 이 없고 기다리는 slot 이 있음"으로 고친다. 기다리는 slot 과 건너뛴 slot 을 화면에서 가르지 않는다. 건너뛴 slot 은 그 요청의 지난 증거에서만 보인다 |
| D3 | L2 와 L3 을 한 번에 설치하나, 따로 하나 | L2 를 먼저 혼자 설치한다. L3 은 L2 를 설치한 뒤 기록을 읽고 쓰는 비용을 재고 정한다(§3.4) | §5 | L3 이 필요해지면 hard cut 이 한 번 더 있다. 그때 exact 요청 기록 전부와 그 증거, 거기 묶인 Librarian owner 의 scope 를 다시 지운다(§5). 그 사이 다시 쌓인 Librarian 상태도 지워져 다시 처리해야 한다. 13:33:53Z 에 그 묶음은 admission owner 다섯(parts 파일 55, gate 파일 79)과 history owner 다섯이다(§5). 한 번에 하면 L3 의 넷(§3.4)을 정할 때까지 L2 가 늦다. 그동안 §1.2 의 요청은 실행마다 1,055,315,219 바이트의 증거 파일을 읽는다. 원본 resume 도 그 파일을 읽는다(§2.3). 잰 세 실행에서 서버 RSS 가 3.0~4.6 GB 올랐다(§1.2). L3 이 그 요청의 실행 한 번에 덜어 주는 것은 기록을 읽고 쓸 때의 요청 몫이다. 한 번에 3,779,582 바이트다. 읽기는 한 번, 쓰기는 한 번에서 세 번이다. 읽을 때마다 요청 본문을 canonical 로 네 번 지난다(§3.4) |
| D4 | 기다리는 slot 없이 열려 있는 요청도 건너뛰게 넓히나 | 지금은 넓히지 않는다. L1 뒤에 남은 되풀이를 재고 정한다 | §3.5 | 다른 slot 이 시각 없는 429, 5xx, 인증 거절로 실패하는 동안에는 큰 본문이 host event 마다 다시 나간다 |
| D5 | L1 이 덮지 않는 400 의 되풀이(§1.1)를 어떻게 하나 | 건너뛰기를 넓히지 않는다. claude 계열의 지출 한도 400 은 #49686 에서 정한다 | §3.5 | tinker 계열처럼 오류 코드 없이 본문을 거절하는 slot 은, 다른 slot 이 기다리는 동안 host event 마다 같은 본문을 한 번씩 받는다. 잰 경우 요청 여섯에 slot 둘이다. 호출마다 증거가 하나 는다. L2 뒤에도 거절된 호출 한 번은 그 요청의 증거 n개를 세 번 읽고 n+1개를 쓴다(§3.3). 증거 하나는 평균 약 3.5 KB 다(§1.1, 계산값). L2 는 증거 쪽에서 요청 크기를 떼어 낸다. 호출마다 기록을 두 번(새 기록의 첫 호출은 세 번) 저장하는 몫에는 요청 크기가 남는다(§3.4) |

2026-11-12 에 사용자가 D3 과 D5 를 추천대로 골랐다. L2 를 먼저 혼자 설치하고, L3 은 L2 를 설치한 뒤 잰 값으로 정한다. 건너뛰기는 400 으로 넓히지 않는다.

2026-11-13 에 사용자가 L2b 를 세 층 스택(§7)으로 올리기로 골랐다. 한 PR 에 14개 파일을 고치면, 설치 때 지울 것을 정하는 preflight 의 결함을 리뷰가 놓치기 쉽다. 구현 전에 §3.3 의 측정 가운데 Librarian owner 의 수를 뺀 것을 쟀다.

## 10. 확인하지 않은 것

- 서버가 다시 뜬 뒤 기다림 표가 남는지. 비는 쪽으로 §4 를 적었다.
- 운영자가 고친 lane 이 재시작 없이 `resolve` 에 닿는지.
- `Retry.InputCapacity` 를 만드는 곳. `classify_error` 가 만들지 않는다는 것만 읽었다.
- operator quiz 가 열린 요청의 증거를 읽는지. 파일 이름 검색으로만 봤다.
- `host-results` 를 읽는 저장소 밖의 도구가 있는지. 찾은 것은 tinker 스크립트 하나다. 그 스크립트는 끝나지 않은 실행의 receipt 도 읽는다. L1 뒤에는 그 실행이 줄어든다.
- §1.1 의 1.03 GB 파일은 증거별로 세지 않았다. 통째로 읽어야 해서 뺐다.
- 기다리는 slot 없이 400 으로 끝난 요청이 있는지. claude 계열의 지출 한도 400 은 그 경우 `Input_refused` 로 끝날 수 있다(#49686). 끝난 기록에서 찾지 않았다.
- operator quiz 와 Candle appraiser 의 exact 요청 기록과 증거를 지우는 곳. 시작 sweep 은 Lane 설정에 있는 Librarian 과 workspace-memory package 의 declaration 만 본다(`server_unowned_exact_sweep.ml:48-50`, `:211-212`). 다른 곳에서 지우는지 찾지 못했다.
- Candle 과 operator quiz 가, 기록을 지운 요청을 다시 보내는지.
- Librarian owner 의 scope 를 지우면 무엇이 다시 만들어지지 않는지. 지울 owner 의 수는 §5 에 셌다.
- admission owner 에 parts 만 있고 partitions 가 없을 때, 실행 원본만 지우면 `discover` 가 멈추는지. partition 과 gate 의 경우만 따라갔다(§3.3 의 5). 13:33:53Z 의 admission owner 다섯이 이 경우다.
- 같은 request id 의 소비자 원본이 없는 exact 기록 58개(145 − 87, §1.2)가 누구의 것인지. 끝난 원본의 기록이면, Lane 설정에 있는 Librarian 과 workspace-memory package 의 것은 다음 시작 sweep 이 지운다.
- 원본 resume 이 §1.2 의 파일을 읽는 횟수. resume 을 부르는 때를 따라가지 않았다.
- §1.2 의 RSS 증가가 그 파일을 읽고 decode 해서인지.
- 증거 파일 하나를 읽고 decode 하는 시간과, store 의 load 가 하는 fsync 의 비용.
- §5 의 단계 표는 origin/main 2ed0170118fd 의 코드를 읽어 적었다. 시험으로 확인하지 않은 것은 셋이다. worker(`addons/exact_worker.py`)가 Captured·Admission_wait 원본의 exact 기록을 남기는지, fence 뒤에 그 원본의 exact 기록이 생기는지, 기록 없는 `Request_body_refused` 접수 원본이 partition 크기 증거를 기다리며 Waiting 으로 남는지다(`keeper_librarian_admission_parts.ml` 의 `confirmed_execution`).
- §1.1 의 Librarian 요청 여섯 가운데 넷이 11:30Z 에 열린 목록에 없는 이유. 끝났는지 지워졌는지 보지 않았다.
- 열린 요청 가운데 한 번 실행되고 멈춘 셋(`lane_unconfigured` 둘, `provider_unavailable` 하나)이 왜 열려 있는지. 열하루 넘게 바뀌지 않았다.

확인한 것: `target_identity_fingerprint`(`packages/agent_core/lib/llm_provider/exact_output_resolver.ml:865-897`)는 target ref, provider id 와 종류, model id, base url, 요청 경로, credential 의 종류, thinking, reasoning effort, timeout 둘, `max_concurrent_requests`, codec, 선언한 header, capability projection 을 덮는다. credential 의 값과 lane 이 덧씌우는 `max_output_tokens`·`thinking` 은 덮지 않는다.
