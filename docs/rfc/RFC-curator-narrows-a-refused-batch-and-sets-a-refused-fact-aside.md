---
rfc: "curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside"
title: "큐레이터는 거절된 묶음을 좁혀 다시 묻고, 한 건까지 좁혀도 모든 slot 이 거절한 fact 는 옆에 세워 두고 나머지를 계속 분류한다"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: claude
supersedes: []
superseded_by: null
related: ["exact-lane-walks-one-slot-list", "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"]
---

# 큐레이터는 거절된 묶음을 좁혀 다시 묻고, 한 건까지 좁혀도 모든 slot 이 거절한 fact 는 옆에 세워 두고 나머지를 계속 분류한다

이슈 #53982 의 「정할 것」 3번과 4번의 설계다. 코드 줄 번호는 main `35243f9b2043` 기준이다. 「큐레이터」는 World Memory 큐레이터(`lib/server/server_workspace_memory_curator.ml`, 아래 「큐레이터 파일」)를 가리킨다. 이 문서는 코드를 바꾸지 않는다.

## 0. 요약

큐레이터는 모든 Keeper 의 밀린 fact 를 한 묶음으로 lane 에 묻는다. 그 묶음이 크기 사실 없이 거절되면 줄이지 않고 60초 뒤 같은 묶음을 다시 보낸다. 그동안 어느 Keeper 의 fact 도 분류되지 않는다.

이 RFC 는 규칙 여섯으로 고친다.

1. 두 건 이상인 묶음은 어느 slot 이든 그 요청을 거절했거나, 못 쓰는 답을 냈거나, 보낸 뒤 기한을 넘겼으면 반으로 좁혀 다시 묻는다. 크기 사실이 있든 없든 같다.
2. 모든 slot 이 말이 없었으면 좁히지 않는다. 60초 깨우기에 같은 묶음을 다시 묻는다.
3. 한 건까지 좁혔을 때 lane 의 모든 slot 이 그 한 건 요청을 거절했으면 그 fact 는 옆에 선다. 나머지 fact 는 계속 분류한다. 못 쓰는 답, 기한 초과, 말 없음은 거절이 아니다. 그런 slot 에는 60초 깨우기마다 한 건으로 다시 묻는다.
4. 선 fact 는 lane 세대가 바뀌거나, 서버가 다시 뜨거나, fact 가 바뀌거나, prompt 가 바뀔 때 다시 묻는다. 타이머는 없다.
5. 선 fact, 좁힌 자리, 좁힌 크기는 메모리에만 둔다. 원장에 새 칸을 만들지 않는다.
6. slot 이 한 일은 Librarian 이 쓰는 표 하나에서 읽는다. lane 이 없는 까닭과 pass 가 끝난 모양은 닫힌 합 타입으로 내고, 운영자는 읽기 전용 projection 으로 본다.

저장 모양은 바뀌지 않는다. hard cut 이 없다.

## 1. 문제

### 1.1 현상 셋

- **A. 크기 사실 없는 거절에서 묶음이 줄지 않는다.** HTTP 400·422 는 크기를 말하지 않는다. 큐레이터는 타입으로 크기를 말한 거절과 출력 한도에서만 묶음을 좁힌다.
- **B. 묶음 하나의 실패가 모든 Keeper 를 세운다.** 묶음은 Keeper 를 가리지 않고 밀린 fact 전부에서 만든다. fact 는 순서가 없는 집합인데도, 맨 앞 묶음이 실패하면 뒤의 fact 는 물어보지도 않는다.
- **C. 같은 요청을 60초마다 다시 보낸다.** 실패한 pass 는 아무것도 남기지 않는다. 유지보수 tick 이 큐레이터를 깨우고, 큐레이터는 같은 묶음을 다시 만든다.

### 1.2 근거

| 사실 | 자리 |
|---|---|
| 밀린 fact 는 `reconciliation.new_facts` 전부에서 메모리의 `indivisible_facts` 만 뺀 것이다 | 큐레이터 파일 502~509행 |
| 묶음은 `Request.prepare ~size ~frame:max_int` 로 만든다. `Fill_frame` 은 frame 에 들어가는 동안 두 배씩 늘려 전부를 담는다 | 큐레이터 파일 536~545행, `lib/workspace_memory/workspace_memory_request.ml` 326~338행 |
| 좁히는 조건은 `capacity_refused` 하나다. 이름 붙은 입력 용량 거절이거나, 분류 단계에서 HTTP slot 의 답이 출력 한도에서 잘렸을 때 참이다 | 큐레이터 파일 159~168행, 81~123행 |
| 입력 용량 쪽은 지나친 slot 의 evidence 를 OR 로 접은 값에서 읽는다. slot 하나가 이름 붙은 용량 거절을 했고 못 쓰는 답을 낸 slot 이 없으면 참이다. 말이 없던 slot 은 세지 않는다 | `lib/exact_lane_slots.ml` 180~192행, `lib/keeper/keeper_exact_walk_failure.ml` 37행, 49행의 `combine` |
| HTTP 400·422 는 `Unknown_invalid_request` 로 분류되고 `Invalid_request` 가 된다 | `packages/agent_core/lib/llm_provider/retry.ml` 330~331행, `exact_output.ml` 882~888행 |
| `Invalid_request` 는 `historical_size` 로 읽힌다. `named_input_capacity` 가 거짓이라 `capacity_refused` 가 거짓이다 | `lib/keeper/keeper_exact_walk_failure.ml` 213행, 37행, 76행 |
| 그 밖의 실패는 `Transient_retry` 나 `Failed` 로 끝난다 | 큐레이터 파일 601~607행 |
| 두 결과 모두 `on_observation_failure` 를 부르고, owner 의 `observation_retry` 가 켜진다 | 큐레이터 파일 727~733행, 942~949행 |
| 유지보수 tick 은 60초다. tick 마다 `retry_pending_observations` 가 `observation_retry` 를 보고 owner 를 깨운다 | `lib/server/server_bootstrap_maintenance.ml` 14행·923행·928~931행, 큐레이터 파일 817~830행 |
| 한 건이 용량으로 거절되면 그 fact 를 `indivisible_facts` 에 넣고 error 로그를 남긴다 | 큐레이터 파일 590~600행 |
| 좁혀서 성공한 크기는 `classification_size <- Up_to n` 으로 적는다. 좁힌 까닭을 가리지 않는다 | 큐레이터 파일 560~563행 |
| `indivisible_facts` 와 `classification_size` 는 owner 의 메모리 칸이다. lane 세대가 바뀌거나 prompt override 가 바뀌면 비운다 | 큐레이터 파일 446~448행, 520~525행, 806~812행 |
| lane 이 없거나 꺼져 있으면 debug 로그 한 줄을 남기고 `Idle` 로 끝난다 | 큐레이터 파일 517~519행, 658~660행 |
| briefing 은 한 항목이 용량으로 거절되면 `Failed` 로 끝난다. 60초 뒤 같은 요청을 다시 보낸다 | 큐레이터 파일 705~709행 |
| briefing 은 출력 한도에서 좁히지 않는다(`allow_output_limit_split:false`). 그 결과는 `Failed` 다 | 큐레이터 파일 671행, 159~168행 |

`Request.narrow` 는 고른 행의 오래된 절반을 남긴다(`List.length batch.rows / 2`, `workspace_memory_request.ml` 354~364행). 행 하나는 fact 하나와 그 이웃이다. 이웃은 자르지 않는다. 주석은 이것이 실제 provider 거절 뒤에 행을 통째로 반씩 나누는 일이고(「Finite whole-row bisection follows an actual provider refusal.」) byte 나 token 추정이 아니라고 적는다. 이 RFC 는 절반이라는 값을 그대로 쓴다. 크기 사실이 없을 때 반씩 나누기는 아무 크기도 가정하지 않고 답하는 묶음을 찾는 길이다. 다른 비율은 근거 없는 숫자다.

### 1.3 운영에서 본 것과 못 본 것

- 이슈 #53982 본문(2026-11-21 01:35 KST): 분류 안 된 fact 2,515건, claim 글 3,324,616 B, Keeper 31. 2026-11-20 12:51 KST 배포 뒤 pass 75번에 분류 0, briefing 0.
- PR #54063 본문의 실측: 한 provider 는 창을 넘는 입력을 HTTP 400 으로 거절하고, 본문에 타입 있는 칸이 없다. 현상 A 가 이 모양에서 생긴다. 이 문서를 쓰며 다시 재지는 않았다.
- 운영 설정에 이 lane 의 표가 없어 큐레이터는 지금 묻지 않는다. 그래서 1.1 의 현상은 코드에서 읽은 것이다. 운영에서 관측한 것이 아니다.

## 2. 목표와 비목표

**목표**

- G1. 묶음 하나가 같은 까닭으로 계속 실패해도 다른 fact 의 분류가 이어진다. Keeper 하나의 fact 가 다른 Keeper 를 세우지 않는다.
- G2. 어느 slot 에도 그 slot 이 이미 「아니오」라고 답한 요청을 같은 lane 세대에서 다시 보내지 않는다. 같은 요청은 같은 fact 들을 묻는 요청이다(§4.3).
- G3. 운영자가 큐레이터가 묻지 않는 까닭, 선 fact 의 수와 까닭을 화면에서 읽는다.

**비목표**

- 원장(`ledger.json`)과 briefing 저장 모양을 바꾸지 않는다.
- provider 의 오류 글에서 크기를 읽어 내지 않는다. 타입 없는 400 은 크기 사실 없는 거절로 남는다.
- 한 건 요청이 이웃 때문에 클 때 이웃을 줄여 묻는 것은 다루지 않는다(§11).
- `Request.narrow` 의 단위를 건수에서 byte 로 바꾸지 않는다.
- Keeper 마다 묶음을 따로 만들지 않는다. fact 단위로 가르면 Keeper 단위로 가를 까닭이 없다(§4.2 대안).
- Librarian 의 쓰는 쪽 규칙은 바꾸지 않는다. Librarian 이 폭을 줄이고 바닥을 판정하는 정책도 바꾸지 않는다.
- 다른 Exact lane 의 실패 읽기를 옮기지 않는다(§11).

## 3. 전제

- 큐레이터는 자기 lane `workspace_memory_curator` 만 읽는다(#54088). 그 표가 없으면 모델에 묻지 않는다.
- 다계정 엔진은 큐레이터를 띄우지 않는다(#54193, `lib/server/server_runtime_bootstrap.ml` 1579~1589행).
- fact 는 집합이다. 분류 순서는 원장의 진실에 들지 않는다. `Ledger.reconcile` 이 주는 「오래된 것부터」는 묶음을 만드는 순서일 뿐이다.
- 원장에 disposition 이 없는 fact 는 다음 `reconcile` 에서 다시 `new_facts` 에 든다. 그래서 fact 를 옆에 세워도 잃는 것이 없다.
- `Excluded` disposition 은 모델이 내린 결정이다(`workspace_memory_ledger.mli` 40~43행). lane 의 거절을 여기에 적지 않는다. 적으면 실패가 상태를 조용히 진행시킨다.

## 4. 결정

### 4.1 Q1. 어떤 결과에서 묶음을 좁히는가

걷기가 답 없이 끝나면 지나친 slot 마다 한 가지로 읽는다. 읽는 표는 Librarian 이 쓰는 표 하나다(§4.7). 타입 있는 원인만 읽는다. 글은 읽지 않는다.

| slot 이 한 일 | 표의 값 | 뜻 | 보기 |
|---|---|---|---|
| 크기 거절 | `Refused (Sized _)` | 이 요청이 이 slot 에 안 들어간다고 타입으로 말했다 | HTTP 413, provider 의 overflow 타입, 로컬 용량 판정, 출력 한도 |
| 크기 사실 없는 거절 | `Refused Unsized` | 이 요청을 거절했고 크기는 말하지 않았다 | HTTP 400·422, refusal·content filter 로 끝난 답 |
| 못 쓰는 답 | `Silent (Unusable _)` | 본문이 왔고 lane 이 쓸 수 없다 | JSON 이 아님, decode 거절, 출력 없음, 출력 여럿 |
| 기한 초과 | `Silent` 의 새 갈래(§4.7) | 보낸 뒤 기한 안에 답이 안 왔다 | first token·wall clock·HTTP operation·body 기한 |
| 말 없음 | `Silent` 의 나머지 | 이 요청에 대해 알려 준 것이 없다 | 429, overload, 5xx, 한도, 인증·결제, 404, 전송 실패, 부르지 않음, 선언대로 쓸 수 없음 |

표는 slot 이 이 요청에 한 일만 말한다. 좁힐지, 세울지는 lane 이 정한다. 아래는 큐레이터가 정하는 것이다. Librarian 이 정한 것은 바뀌지 않는다.

**대안**

| 안 | 두 건 이상인 묶음을 좁히는 때 | 장점 | 단점 |
|---|---|---|---|
| a. 지금 그대로 | 크기 거절 | 바꿀 것이 없다 | 현상 A·B·C 가 그대로다 |
| b. 거절이면 좁힌다 | 크기 거절, 크기 사실 없는 거절 | Librarian 이 폭을 줄이는 때와 같다 | 못 쓰는 답과 기한 초과는 같은 묶음을 60초마다 다시 보낸다. 2,515건을 한 번에 물어 decode 가 매번 거절하면 현상 C 가 남는다 |
| c. 거절, 못 쓰는 답, 기한 초과면 좁힌다 | 위 표의 앞 넷 | 다음 요청이 앞 요청과 다르다. 같은 묶음을 되풀이하는 길이 말 없음 하나만 남는다 | 느린 provider 를 만나면 한 건까지 내려간다. 호출이 늘어난다 |
| d. 답이 없으면 늘 좁힌다 | 다섯 모두 | 규칙이 하나다 | provider 가 쉬는 동안 pass 하나가 실패하는 호출을 `2N − 1` 번 낸다 |

**권고: c.** 좁히기는 잃는 것이 없는 움직임이다. 작은 묶음의 답은 큰 묶음의 답과 똑같이 원장에 들어간다. 그래서 약한 근거로도 좁혀도 된다.

- **못 쓰는 답에서 좁히는 까닭.** 「작은 묶음이 더 잘 답한다」가 아니다. 그 말은 재지 않았다. 같은 묶음을 다시 보내는 것 말고 할 수 있는 다른 움직임이 좁히기뿐이다.
- **기한 초과에서 좁히는 까닭.** 기한은 이 요청이 걸린 시간에 대한 사실이다. 분류의 답은 고른 fact 마다 결정을 싣는다(`workspace_memory_request.mli` 의 `selected_ids`). 그래서 출력 길이는 묶음 크기를 따라간다. 큰 묶음이 매번 기한에 걸리는데 좁히지 않으면 모든 Keeper 가 선다(현상 B). 옛 읽기도 이 기한을 범위 크기의 근거로 읽는다(`keeper_exact_walk_failure.ml` 196~197행). Librarian 은 말 없음으로 읽고 폭을 줄이지 않는다. 표는 같고 그 뒤에 하는 일이 다르다. 설계 리뷰가 정한다(§10 D2).
- **말 없음에서 좁히지 않는 까닭.** 전송 실패, 429, overload, 5xx, 한도, 인증·결제, 부르지 않음은 요청에 대해 알려 준 것이 없다. 좁혀도 같은 말 없음을 만난다. 장애 중에 좁히면 pass 하나가 실패하는 호출을 `2N − 1` 번 낸다.

좁히는 조건은 「어느 slot 이든」이다. slot 하나가 거절하고 나머지가 말이 없어도 좁힌다. 거절한 slot 에 같은 묶음을 다시 보내지 않으려는 것이다(G2).

**좁힌 크기를 기억하는 규칙.** `classification_size <- Up_to n` 은 크기 거절로만 좁혀 내려온 pass 에서 적는다. 좁히는 동안 크기 사실 아닌 까닭이 한 번이라도 끼면 적지 않는다. 지금은 까닭을 가리지 않고 적는다. 그대로 두고 규칙 1을 넣으면, 내용 때문에 거절된 fact 하나가 그 lane 세대의 모든 묶음을 한두 건으로 줄인다.

**거절된 묶음의 나머지 절반.** 오래된 절반을 다룬 뒤에는 새 절반만으로 묶음을 다시 만든다. 새 원장으로 만든다. 지금처럼 남은 fact 전부로 다시 만들면, 모든 요청을 거절하는 lane 에서 묻기가 대략 `N log N` 번으로 늘어난다. 절반씩 다루면 `2N − 1` 번이다(§4.2).

**좁힌 자리를 기억하는 규칙.** 좁혀서 나온 절반들은 그 lane 세대 동안 owner 의 메모리에 남는다. 말 없음으로 멈춘 절반은 다음 60초 깨우기에 그 절반 그대로 다시 묻는다. 좁히기 전의 묶음으로 되돌려 합치지 않는다. 합치면 그 묶음을 거절한 slot 이 같은 묶음을 다시 받는다(G2). 그사이 새로 온 fact 는 새 묶음이 된다. 좁힌 적이 없는 묶음은 여기에 들지 않는다. 60초 깨우기에 그사이 온 fact 와 합쳐 다시 만든다.

### 4.2 Q2. 한 건까지 좁힌 fact 는 언제, 어디에 서는가

**선다는 것의 조건.** 한 건 요청을 lane 이 선언한 모든 slot 이 거절했으면 그 fact 는 선다. 거절은 크기 거절과 크기 사실 없는 거절이다. 그 밖의 결과는 fact 를 세우지 않는다.

- 못 쓰는 답은 요청에 대한 「아니오」가 아니다. 모델의 답은 표본마다 달라질 수 있다. 못 쓰는 답 한 번으로 세우면 운 나쁜 표본 하나가 그 fact 를 재시작이나 lane 변경까지 묶는다.
- 기한 초과와 말 없음도 요청을 받지 않겠다는 말이 아니다.
- Librarian 의 표도 못 쓰는 답을 말 없음 쪽에 둔다(`Silent (Unusable _)`).

**말하지 않은 slot.** 한 건 요청을 거절하지 않았고 받아들인 답도 내지 않은 slot 이다. 못 쓰는 답, 기한 초과, 말 없음을 낸 slot 이 여기에 든다. 말하지 않은 slot 이 하나라도 있으면 fact 는 서지 않는다.

**바닥 기억.** 한 건까지 내려온 fact 마다 그 요청을 거절한 slot 을 메모리에 적는다. 열쇠는 `fact_ref` 와 slot id 다.

- 거절한 slot 에는 그 fact 를 다시 묻지 않는다. `Exact_lane_slots.walk` 는 slot 목록을 받으니 거절하지 않은 slot 만 넘긴다.
- 선언한 slot 이 모두 거절했으면 그 fact 는 선 것이다. 「선 목록」을 따로 두지 않는다. 바닥 기억에서 계산한다.
- 말하지 않은 slot 이 남은 fact 는 60초 깨우기마다 그 slot 에만 한 건으로 다시 묻는다. 간격은 고정 tick 이고 횟수 상한은 없다. 헌법의 Task 재시도와 같은 모양이다.
- 말하지 않은 slot 의 마지막 결과도 같이 든다. 판정에는 쓰지 않는다. projection 이 보여 준다.
- `indivisible_facts` 는 이 기억으로 바뀐다.

지금 코드는 세우는 조건이 다르다. 지나친 slot 가운데 하나가 이름 붙은 용량 거절을 했고 못 쓰는 답을 낸 slot 이 없으면 그 fact 를 세운다. 출력 한도에서 잘린 slot 이 하나 있어도 세운다(§1.2). 말이 없던 slot 은 세지 않는다. 새 규칙은 선언한 slot 을 모두 본다.

**치르는 값.** 답이 매번 못 쓰는 답인 fact 가 K 건이면 60초 깨우기마다 그 slot 에 K 번 묻는다. lane 이 모든 요청에 못 쓰는 답을 내면 K 는 밀린 fact 전부다. 끝내는 것은 그 slot 의 답이나 거절, 그리고 §4.3 의 계기다. projection 은 말하지 않은 slot 을 기다리는 fact 수와 그 slot 의 마지막 결과를 보여 준다(§4.6). 못 쓰는 답도 세울지는 운영자가 정한다(§10 D6).

**늘 실패하는 slot.** lane 에 인증이나 결제로 늘 실패하는 slot 이 있으면 그 slot 은 늘 말하지 않은 slot 이다. 다른 slot 이 모두 거절한 fact 도 서지 못하고 깨우기마다 그 slot 에 한 번씩 간다. 그런 slot 은 운영자가 선언에서 뺀다. Librarian RFC §18.1 이 Librarian lane 에 둔 요구와 같다.

**Librarian 과 견줌.** 표를 읽는 것은 같다. 둘 다 거절만 그 slot 의 판정으로 읽고, 못 쓰는 답과 말 없음에는 다시 묻는다(`lib/librarian/librarian_bottom.mli`). 다른 점은 하나다. Librarian 은 턴 기록을 순서대로 읽는다. 맨 앞 항목을 세우면 그 Keeper 의 읽기가 멈춘다. 그래서 크기 사실 없는 거절도 기억하지 않고 pulse 마다 다시 물으며 경보 E4 를 켠다. 큐레이터의 fact 는 순서가 없다. 거절된 fact 를 세우고 지나가도 아무것도 멈추지 않는다. 그래서 큐레이터는 크기 사실 없는 거절도 적고 다시 묻지 않는다.

**어디에 두는가.**

| 안 | 둘 자리 | 장점 | 단점 |
|---|---|---|---|
| a. 메모리의 닫힌 합 + projection | owner 의 메모리 | 새 저장 상태가 없다. lane 값에 딸린 사실이 디스크에 남지 않는다 | 서버가 다시 뜨면 선 fact 를 한 번씩 다시 묻는다 |
| b. 원장의 disposition | `ledger.json` | 재시작 뒤에도 안 묻는다 | 원장 모양이 바뀐다(hard cut). 「이 lane 값이 거절했다」는 lane 이 바뀌면 틀린 말이 되니 lane 세대도 같이 저장해야 한다. 큐레이터의 해석 원장에 실행 실패가 섞인다 |
| c. 원장 옆의 파일 | 새 파일 | 원장은 그대로다 | 새 저장 상태와 그 decode·검사·preflight 가 생긴다. b 의 lane 세대 문제는 같다 |

**권고: a.** 저장하지 않아도 진실이 손상되지 않는다. 선 fact 는 Keeper 의 저장소에 그대로 있고 원장에는 disposition 이 없다. 재시작이 치르는 값은 호출이다.

**모든 요청을 거절하는 lane.** lane 이 내용과 무관하게 모든 요청을 거절하면(예: 선언한 schema 를 provider 가 받지 않음) fact 는 하나씩 선다. `N` 건에 묻기 `2N − 1` 번이 한 번 든다. 묻기 하나는 slot 마다 한 번 부른다. 그 뒤에는 lane 세대가 바뀔 때까지 묻지 않는다. 새 fact 는 건마다 한 번 묻고 선다. 운영자는 projection 에서 「이 lane 세대에서 분류 0, 선 fact N」을 읽는다.

한도를 맨 400 으로 알리는 provider 도 같은 모양을 만든다. 표는 그 400 을 크기 사실 없는 거절로 읽는다(Librarian RFC §7.2). 한도가 풀려도 선 fact 는 그대로 서 있다. 푸는 길은 §4.3 의 계기뿐이다. 운영자의 「다시 묻기」(§10 D3)가 그래서 필요하다.

- 대안: fact 몇 개가 잇달아 거절되면 lane 전체를 세운다. 채택하지 않는다. 「몇 개」는 근거 없는 숫자이고, 틀리면 lane 하나의 판단이 모든 Keeper 를 세운다.
- 대안: Keeper 마다 묶음을 따로 만든다. 채택하지 않는다. 나쁜 fact 는 여전히 자기 Keeper 의 다른 fact 를 세우므로 좁히기와 세우기가 그대로 필요하다. fact 단위로 가르면 Keeper 단위는 더 얻는 것이 없다.

### 4.3 Q3. 선 fact 는 언제 다시 묻는가

| 안 | 다시 묻는 때 | 평가 |
|---|---|---|
| a. 일어난 일로만 | lane 세대 변경, 재시작, fact 변경, prompt 변경, 운영자 요청 | 같은 요청을 같은 lane 값에 다시 보낼 근거가 생긴 때만 묻는다 |
| b. 타이머·backoff | 시간이 지나면 | 헌법 `no_wall_clock_death` 와 맞지 않는다. 시간은 거절의 까닭을 바꾸지 않는다 |
| c. 횟수 | N 번 실패하면 버린다 | 헌법 `magic_number` 가 금지한다. 횟수는 중단의 근거가 아니다 |

**권고: a.** 각 계기는 이미 코드에 있다.

- lane 세대 변경: `Registry.catalog_generation_fingerprint` 가 바뀌면 지금도 메모리를 비운다(큐레이터 파일 520~525행). lane 변경 알림을 구독한다(`Registry.subscribe_lane_changes`).
- 재시작: 메모리라서 비어 있다.
- fact 변경: claim 이 바뀌면 `claim_sha256` 이 달라 다른 `fact_ref` 다. 바닥 기억과 좁힌 자리는 pass 마다 지금의 `new_facts` 에 든 것만 남긴다.
- prompt 변경: `request` 가 지금도 메모리를 비우고 깨운다(큐레이터 파일 800~815행).
- 운영자 요청: 지금은 운영자가 직접 부르는 길이 없다. `request` 를 부르는 곳은 prompt override 하나다(`lib/server/server_prompt_override_mutation.ml` 49행). 길을 낼지는 §10 D3 이다.

이웃이나 원장만 바뀐 것은 계기가 아니다. 한 건 요청의 글은 이웃과 원장에 따라 달라지지만, 원장은 분류가 들어갈 때마다 바뀐다. 요청 글의 digest 를 열쇠로 삼으면 commit 마다 선 fact 를 전부 다시 묻는다. 그래서 같은 요청은 같은 fact 들을 묻는 요청으로 본다.

### 4.4 Q4. 60초 깨우기는 무엇에만 남는가

| pass 가 끝난 모양 | 다음에 깨우는 것 |
|---|---|
| 밀린 fact 가 모두 분류됐거나 서 있다 | Keeper Memory commit 알림, lane 변경, prompt 변경. 60초 깨우기는 없다 |
| lane 이 말이 없다(묶음에 모든 slot 이 말 없음, 또는 바닥의 fact 가 말하지 않은 slot 을 기다림) | 60초 깨우기 |
| registry 교체 중 | 60초 깨우기 |
| 저장소·원장·log 를 읽거나 쓰지 못했다 | 60초 깨우기 |
| lane 표가 없거나 꺼져 있다 | lane 변경 알림 |

거절은 60초 깨우기를 켜지 않는다. pass 안에서 좁히거나 세워서 끝낸다. 묶음의 못 쓰는 답과 기한 초과도 pass 안에서 좁힌다. 한 건의 못 쓰는 답과 기한 초과는 60초 깨우기를 켠다(§4.2).

기다리던 것을 다시 묻는 일은 60초 깨우기가 깨운 pass 에서만 한다. 기다리던 것은 말 없음으로 멈춘 묶음과 말하지 않은 slot 을 기다리는 fact 다. commit 알림이 깨운 pass 는 새 fact 만 다룬다. 그래야 다시 묻는 간격이 고정 tick 이다. pass 는 새 fact 의 묶음을 먼저 다루고 기다리던 것을 뒤에 묻는다. 기다리는 fact 가 많아도 새 fact 가 그 뒤에 줄 서지 않는다.

간격은 지금의 고정 tick 그대로다. backoff 를 넣지 않는다. 헌법의 Task 재시도가 같은 모양이다(「횟수 상한은 없다. 간격은 고정 maintenance pulse 간격」). provider 가 다시 받는 시각을 밝힌 slot 은 걷기가 부르지 않고 지나간다(`Exact_lane_walk` 의 `Held`). 모든 slot 이 그렇게 쉬는 동안의 깨우기는 provider 를 부르지 않는다.

### 4.5 Q5. briefing 단계도 같은 규칙인가

좁히는 규칙은 같다. 바닥은 다르다.

- **좁히기.** §4.1 c 를 그대로 쓴다. 출력 한도만 다르다. briefing 의 답은 요약 하나라서 항목을 줄여도 답이 짧아진다는 보장이 없다. 지금처럼 출력 한도에서는 좁히지 않는다.
- **바닥.** 한 항목까지 좁혔을 때 모든 slot 이 그 요청을 거절했으면 그 항목이 선다. briefing 은 그 항목 뒤에서 기다린다. 마지막으로 완성한 briefing 은 그대로 읽힌다. 말하지 않은 slot 이 있으면 서지 않고 60초 깨우기마다 그 slot 에만 다시 묻는다(§4.2).
- **출력 한도.** 모든 slot 이 출력 한도에서 잘렸으면 그 pass 가 선다. 다시 묻는 계기는 §4.3 과 같다. 출력 몫은 lane 선언에 있으니 선언이 바뀌면 세대가 바뀐다.
- **기억.** 선 항목은 메모리에 source id 와 lane 세대로 적는다. 다른 claim 이 더해져 pass 가 새로 만들어져도 맨 앞이 같은 항목이면 묻지 않고 선다.

| 안 | 바닥에서 | 평가 |
|---|---|---|
| a. 항목이 서고 briefing 이 기다린다 | 앞 완성본을 계속 보여 준다 | briefing 의 뜻이 바뀌지 않는다. 그 항목이 풀릴 때까지 briefing 이 낡는다 |
| b. 그 항목을 빼고 완성한다 | 빠진 것이 있는 briefing 을 낸다 | briefing 이 「모든 claim 과 conflict 의 종합」이 아니게 된다. 빠졌다는 표시를 답과 읽는 쪽에 더해야 한다 |

**권고: a.** b 는 briefing 의 계약을 바꾼다(§10 D4). briefing 이 서도 분류는 서지 않는다. `run_pass` 는 두 단계를 따로 돌린다(큐레이터 파일 721~740행).

### 4.6 Q6. lane 없음과 pass 결과를 typed 값으로 내고 보이는 법

지금 `domain_step_outcome` 은 `Progressed | Idle | Transient_retry | Failed of string` 이다(큐레이터 파일 452~456행). lane 이 없는 까닭은 `Lane_disabled of string` 으로 글이 된다(29~34행, 38~62행). registry 는 그 까닭을 타입으로 준다(`Registry.publication_error`, `Registry.lane_resolution_error`). 큐레이터가 글로 바꿔 버린다.

**바꾸는 것.** 단계가 끝난 모양을 닫힌 합으로 낸다. 이름은 층 PR 에서 정한다. 담는 것은 이렇다.

```ocaml
type lane_standing =
  | Not_published of Registry.publication_error
  | Not_resolved of Registry.lane_resolution_error  (* 표 없음, 꺼짐, 받아들인 slot 없음 *)
  | Replacement_in_progress

type step_end =
  | Nothing_pending
  | Not_asked of lane_standing
  | Drained        (* 밀린 것이 모두 분류됐거나 서 있다 *)
  | Lane_silent    (* 말 없음으로 멈춘 묶음이나 말하지 않은 slot 을 기다린다 *)
  | Host_failed of host_step * string  (* 어느 단계인지는 타입, 글은 보여 주기만 한다 *)
```

owner 는 가장 최근 `step_end` 와 바닥 기억을 메모리에 든다. 저장하지 않는다.

**보이는 법.**

| 운영자가 알고 싶은 것 | 어디서 오는가 |
|---|---|
| 밀린 fact 수 | 지금도 있다. World Memory inventory 의 `ordinary_absence` 가 저장소와 원장에서 계산한다(`lib/workspace_memory/workspace_memory_ledger_view.ml` 147~165행) |
| lane 이 선언됐는지 | 지금도 있다. Lanes projection 이 `Configured`·`Disabled`·`Unconfigured`·`Registry_unavailable` 로 낸다(`lib/server/server_standalone_lane_projection.mli`) |
| 큐레이터가 왜 안 묻는지 | 새로 낸다. owner 의 `step_end` |
| 선 fact 수와 slot 별 거절 종류 | 새로 낸다. 바닥 기억에서 계산한다 |
| 말하지 않은 slot 을 기다리는 fact 수와 그 slot 의 마지막 결과 | 새로 낸다. 바닥 기억에서 계산한다 |

- 새 projection 은 서버 route 가 만든다. owner 는 `lib/server` 에 있어서 `lib/workspace_memory` 가 읽을 수 없다. inventory 를 내는 route(`lib/server/server_routes_http_routes_dashboard.ml` 715행)가 owner 의 읽기를 옆에 붙인다.
- 싣는 것은 수와 `fact_ref`(Keeper id, 경로, hash)다. claim 글은 싣지 않는다.
- TUI 의 World 줄(`bin/masc_tui_render_memory.ml` 917행 근처)이 읽는다. TUI 는 칸이 정확히 맞지 않는 응답을 거절하니 서버와 TUI 를 한 PR 에서 바꾼다.

**대안: 로그 수준만 올린다.** 채택하지 않는다. 이슈가 적은 대로 보이게만 하고 고치지 않는 일이다. 이 RFC 에서 projection 은 고친 동작(§4.1~§4.5)의 상태를 읽는 창이다. 동작을 대신하지 않는다.

### 4.7 Q7. slot 결과를 무엇에서 읽는가

**표는 하나로 쓴다.** 「400 이 무슨 뜻인가」를 정하는 표가 둘이면 SSOT 위반이다. Librarian 이 그 표를 이미 갖고 있다. 큐레이터는 그 표를 lane 중립 모듈로 옮겨 같이 읽는다.

표를 읽는 것과 그 뒤에 하는 일은 가른다. 표는 slot 이 이 요청에 한 일만 말한다. 좁힐지, 세울지는 lane 이 정한다. Librarian 의 정책은 바뀌지 않는다.

**지금 있는 읽기 둘.**

- `Keeper_exact_walk_failure`. 「범위가 너무 컸는가」를 묻는 bool 칸들이다. 큐레이터가 지금 읽는다(`Exact_lane_slots.failure_evidence`, `lib/exact_lane_slots.mli` 119행, `.ml` 143~192행).
- Librarian 의 slot 결과 표. `lib/librarian/librarian_slot_outcome.mli` 의 타입, `lib/librarian/librarian_slot_visit.ml` 의 `classify`, 생성자마다 한 행인 `test/fixtures/librarian_slot_outcome/table.tsv` 다.

아래 행에서 둘이 갈린다.

| 원인 | `Keeper_exact_walk_failure` 의 읽기 | Librarian 표의 값(`librarian_slot_visit.ml`) | 큐레이터가 읽는 갈래 |
|---|---|---|---|
| HTTP 400·422 (`Invalid_request`) | `historical_size`. 이름 붙은 용량은 아니다(213행) | `Refused Unsized`(51행) | 크기 사실 없는 거절 |
| 다른 상태 코드(`Unclassified_status`) | `Invalid_request` 로 접는다(97행) | `Silent Unavailable`(53~54행) | 말 없음 |
| refusal·content filter 로 끝난 빈 답 | `size_independent`(205~206행) | `Refused Unsized`(59·67행) | 크기 사실 없는 거절 |
| first token·wall clock·HTTP operation·body 기한 | `historical_size`(196~197행) | `Silent Lost`(91행) | 기한 초과. 표를 가른다(아래) |
| 출력 없음·여럿·text 아님 | `historical_size`(218행) | `Silent (Unusable _)`(101·105~106행) | 못 쓰는 답 |
| JSON 아님, lane 의 decode 거절 | `invalid_output`(219행, `exact_lane_slots.ml` 144~145행) | `Silent (Unusable _)`(105~106·197~198행) | 못 쓰는 답 |
| masc 의 serving 판정(`Input_capacity`) | 이름 붙은 용량(211행) | `Silent Unavailable`(53~54행) | 말 없음. 지금은 좁히고, 표로 읽으면 좁히지 않는다(§11) |

옛 읽기로는 바닥(§4.2)을 판정할 수 없다. 400 과 기한이 같은 칸(`historical_size`)에 들어 있다.

**대안**

| 안 | 자리 | 장점 | 단점 |
|---|---|---|---|
| a. `Keeper_exact_walk_failure` 에 읽기를 하나 더한다 | Exact 걷기의 실패 읽기가 모인 모듈 | Librarian 모듈을 건드리지 않는다 | 「400 이 무슨 뜻인가」를 정하는 표가 둘이 된다. 한쪽만 고치면 뜻이 어긋난다 |
| b. Librarian 의 모듈을 그대로 부른다 | `Librarian_slot_visit.classify` | 표가 하나다 | 타입이 Librarian 의 거절 타입에 묶여 있다. 큐레이터가 만들 수 없는 값이다 |
| c. Librarian 의 표를 lane 중립 모듈로 옮기고 둘 다 읽는다 | 걷기(`Exact_lane_slots`) 옆 | 표가 하나다. 400 의 뜻이 두 lane 에서 같다 | Librarian 모듈을 고친다. Librarian 재설계가 진행 중이다 |

**권고: c.** a 는 하지 않는다. 뜻을 정하는 표가 둘이 된다.

**옮기는 모양.** 모듈 이름과 자리는 L1 에서 정한다. 후보는 `lib/exact_lane_slot_outcome.ml` 이다. 걷기(`lib/exact_lane_slots.ml`)와 같은 자리다. 타입은 lane 이 정하는 거절 타입을 인자로 받는다.

```ocaml
type size_fact = Input_too_large | Output_over_reserve | Window_reached
type refusal = Sized of size_fact | Unsized
type 'rejection silence =
  | Not_called
  | Unavailable
  | Busy
  | Overdue                  (* 새 갈래. 보낸 뒤 기한을 넘겼다 *)
  | Lost                     (* 전송 실패, 타입이 설명 못 하는 실패 *)
  | Unusable of 'rejection   (* lane 의 거절 타입 *)
type 'rejection unanswered = Refused of refusal | Silent of 'rejection silence
type 'rejection t = Slot_answered | Unanswered of 'rejection unanswered
```

- **타입.** `Librarian_slot_outcome`(mli 47줄)에서 Librarian 의 것은 37행의 `Unusable of Librarian_answer.rejection` 한 곳이다. 나머지 생성자는 lane 을 가리지 않는다.
- **분류.** `Librarian_slot_visit` 의 방문 타입과 `classify` 가 같이 간다(`librarian_slot_visit.ml` 1~202행). provider 거절(48~55행), stop reason(57~69행), 실행 오류(93~107행), client 별 오류(109~188행)를 읽는 함수가 모두 여기 있다. 방문 타입에서 Librarian 의 것은 `Answer_rejected`(8행)와 `Cli_answer_rejected`(12행)가 싣는 거절이다. 같은 인자로 바뀐다.
- **걷기 결과를 방문으로 옮기는 함수.** `librarian_ask.ml` 207~258행의 `slot_visit` 이다. 큐레이터도 같은 걷기(`Exact_lane_slots.walk`)를 쓴다. lane 마다 이 함수를 따로 쓰면 표의 앞 절반이 둘이 된다. 같이 옮긴다.
- **lane 이 건네는 값 둘.** `classify` 는 비었거나 잘린 본문을 `Unusable Empty_or_partial` 로(61·69·83·101·175행), JSON 이 아닌 본문을 `Unusable Not_json` 으로(82·106·185행) 낸다. 둘은 `Librarian_answer.rejection` 의 생성자다(`librarian_answer.mli` 57~61행). 중립 함수는 lane 의 거절 값을 만들 수 없다. 후보는 lane 이 그 두 값을 건네는 것이다. Librarian 의 타입과 표의 행이 그대로 남는다. 중립 타입이 두 갈래를 자기 이름으로 갖는 길도 있다. 그러면 Librarian 의 타입과 표의 행이 바뀐다. L1 에서 정한다.
- **Librarian 은 다시 내보낸다.** `Librarian_slot_outcome` 과 `Librarian_slot_visit` 은 `Librarian_answer.rejection` 을 넣어 같은 이름으로 다시 내보낸다. 그 타입을 읽는 Librarian 모듈 여섯(`librarian_ask`, `librarian_bottom`, `librarian_last`, `librarian_machine`, `librarian_read_result`, `librarian_room_result`)은 이름을 그대로 쓴다.

**`Lost` 를 둘로 가른다.** 지금 `Lost` 는 전송 실패, body 기한, 타입이 설명 못 하는 실패를 함께 싣는다(`librarian_slot_outcome.mli` 36행). 보낸 뒤 기한을 넘긴 것을 새 갈래로 떼어 낸다. 위 타입의 `Overdue` 다. 이름은 L1 에서 정한다.

- `http_error` 는 `TimeoutError _` 를 `Silent Lost` 로 낸다(91행). phase 를 읽지 않는다. first token, wall clock, HTTP operation, 두 body 기한이 모두 이 한 줄이다.
- phase 는 타입 있는 칸이다(`http_client.mli` 92~110행). 다섯 phase(`First_token`, `Wall_clock`, `Http_operation`, `Non_streaming_body`, `Stream_body`)를 새 갈래로 낸다. 옛 읽기가 범위 크기의 근거로 읽는 다섯이다. 나머지 여섯은 `Lost` 로 남는다. 옛 읽기도 같은 자리에서 가른다(`keeper_exact_walk_failure.ml` 196행과 199행).
- `execution` 의 `Response_body_deadline_exceeded` 도 새 갈래로 낸다(107행).
- 표 fixture 의 행이 그만큼 갈린다. `TimeoutError` 한 행(56행)이 phase 로 두 행이 되고, `Response_body_deadline_exceeded` 행(17행)의 값이 바뀐다. 표에는 타입 있는 칸으로 가른 행이 이미 있다(`case` 열).
- Librarian 은 두 갈래를 모두 말 없음으로 읽는다. 판단은 그대로다. 로그와 health 응답의 낱말이 하나 는다(`librarian_machine.ml` 388~398행의 `unanswered_token`).
- `provider_refusal` 의 `Timeout`(55행)과 client 별 `Timeout _`(133·148·156·166행)을 어느 쪽에 둘지는 L1 에서 생성자별로 정한다(§11).

**`Keeper_exact_walk_failure` 는 남는다. 새 판정의 근거는 아니다.**

- Librarian RFC(`RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line.md`) 1954행: 이 타입은 Exact 걷기가 쓰고, 「그 걷기와 그것을 쓰는 HITL 요약은 이 RFC 가 고치지 않는다. 새 Librarian 은 이 타입을 쓰지 않고 §7.2 의 slot 결과를 쓴다.」
- 같은 문서 2013행의 표: `keeper_exact_walk_failure`, `keeper_exact_walk_receipt`, `exact_lane_failure` 는 「이름만 따라 바꾼다」.
- exact-lane RFC §3.4: lane 마다 다른 실패 해석은 걷기의 방문 목록을 읽는다.
- 그래서 이 타입은 walk receipt 의 저장 태그와 HITL 요약이 읽는 옛 읽기로 남는다. 큐레이터는 L3 과 L4 뒤로 이것을 읽지 않는다.
- `Exact_lane_slots.failure_evidence` 를 lib 에서 부르는 곳은 큐레이터 하나다(큐레이터 파일 161행). 시험 하나가 더 부른다(`test/test_exact_lane_slots.ml` 74행). L4 뒤에는 부르는 곳이 없으니 그 함수와 시험을 지운다.
- `keeper_exact_walk_failure.ml` 82행과 177행의 주석은 「this algebra is removed at the Librarian cut」이라고 적는다. 낡은 말이다. L1 에서 고친다(§9).

**폭과 바닥 모듈은 같이 쓰지 않는다.** 표는 같이 쓰고 정책 모듈은 lane 마다 둔다.

- `Librarian_bottom` 은 `Librarian_memory_lane.slot_key` 와 `Librarian_question_id.t` 로 사실을 적고, `fold` 는 `Librarian_memory_lane.t` 를 받는다. 큐레이터의 lane 은 `Runtime_exact_output_registry.resolved_lane` 이다. 판정도 다르다(§4.2).
- `Librarian_width` 는 단위와 항목 두 층이고 `passed` 가 `Librarian_log.within` 을 읽는다. 큐레이터의 묶음은 fact 의 한 층이다.

규칙의 모양은 같다. 거절된 범위 안에서 반으로 묻고, 바닥에서는 slot 별 사실을 접는다. 모델도 같은 모양으로 쓴다(§8).

## 5. 결과 × 다음 행동

분류 단계다. 「지금」은 main `35243f9b2043`, 「제안」은 §4 의 권고다. 「묶음」은 두 건 이상이다.

| 걷기의 끝 | 지금 | 제안 |
|---|---|---|
| 답을 받아들였다 | commit. 좁혀서 성공했으면 크기를 적는다 | commit. 크기는 크기 거절로만 좁혔을 때 적는다 |
| 묶음, 크기 거절을 낸 slot 이 있다(출력 한도 포함) | 반으로 좁힌다. 입력 용량 거절은 못 쓰는 답을 낸 slot 이 없을 때만 좁힌다 | 반으로 좁힌다 |
| 묶음, 크기 사실 없는 거절을 낸 slot 이 있다 | `Failed`. 60초 뒤 같은 묶음 | 반으로 좁힌다. 크기는 적지 않는다 |
| 묶음, 못 쓰는 답을 낸 slot 이 있다 | `Failed`. 60초 뒤 같은 묶음 | 위와 같다 |
| 묶음, 보낸 뒤 기한을 넘긴 slot 이 있다 | `Failed`. 60초 뒤 같은 묶음 | 위와 같다 |
| 묶음, 모든 slot 이 말 없음 | 모두 쉬면 `Transient_retry`, 아니면 `Failed`. 60초 뒤 같은 묶음 | 좁히지 않는다. 60초 깨우기에 같은 묶음. 아무것도 세우지 않는다 |
| 한 건, 선언한 slot 이 모두 거절했다 | 입력 용량 거절이나 출력 한도가 하나라도 있으면 선다. 없으면 `Failed`, 60초 뒤 같은 한 건 | 선다. 나머지를 계속 분류한다 |
| 한 건, 말하지 않은 slot 이 있다(못 쓰는 답, 기한 초과, 말 없음) | 출력 한도가 있거나, 입력 용량 거절이 있고 못 쓰는 답이 없으면 선다. 아니면 `Failed` 나 `Transient_retry`, 60초 뒤 모든 slot 에 다시 | 서지 않는다. 60초 깨우기에 말하지 않은 slot 에만 한 건으로 다시 묻는다 |
| lane 표 없음·꺼짐 | debug 로그, `Idle` | `Not_asked` 를 타입으로 낸다. lane 변경이 깨운다 |
| registry 교체 중 | debug 로그, `Transient_retry` | `Not_asked Replacement_in_progress`. 60초 깨우기 |
| 저장소·원장·log 실패 | `Failed`, error 로그, 60초 | `Host_failed`. 60초 깨우기 그대로 |

briefing 단계에서 다른 행이다.

| 걷기의 끝 | 지금 | 제안 |
|---|---|---|
| 한 항목, 선언한 slot 이 모두 거절했다 | 용량 거절이면 `Failed`, 60초 뒤 같은 요청 | 그 항목이 선다. briefing 은 기다린다. 앞 완성본은 그대로다 |
| 출력 한도 | `Failed`, 60초 뒤 같은 요청 | 좁히지 않는다. 모든 slot 이 그랬으면 pass 가 선다 |

## 6. 원칙 대조

| 원칙 | 이 RFC |
|---|---|
| 새 저장 상태·필드·Gate 는 진실이 손상될 때만 | 저장 모양이 그대로다. 바닥 기억, 좁힌 자리, `step_end` 는 메모리다. 없어져도 진실은 그대로이고 호출만 다시 든다 |
| SSOT | slot 이 한 일의 뜻을 정하는 표는 하나다. Librarian 과 큐레이터가 같이 읽는다. 표 뒤의 정책만 lane 마다 다르다 |
| `no_wall_clock_death` | 선 fact 를 시간으로 풀지 않는다. 일어난 일로만 다시 묻는다 |
| `magic_number`, cap·cooldown | 재시도 횟수, 잇단 실패 수, backoff 가 없다. 말하지 않은 slot 에 다시 묻는 간격은 고정 tick 이고 횟수 상한이 없다. 절반은 반씩 나눠 찾는 값이고 지금 코드의 값이다 |
| `closed_sum_over_string`, 문자열 분류기 | slot 이 한 일과 pass 의 끝은 닫힌 합이다. provider 의 글과 `detail` 글을 읽어 가르지 않는다 |
| catch-all | 표는 wildcard 없는 match 이고 생성자마다 한 행이다 |
| dedup | 같은 요청을 걸러 내지 않는다. 같은 요청을 만들지 않는다. 거절한 slot 을 목록에서 빼고 걷는다 |
| `failure_keeps_evidence` | 거절은 fact 를 소비하지 않는다. 원장에 disposition 을 적지 않고 `Excluded` 로 바꾸지 않는다 |
| 가시성은 projection | 운영자가 보는 값은 owner 의 메모리와 저장소·원장에서 계산한다. authority 로 저장하지 않는다 |
| 하드 게이팅은 기본이 아니다 | lane 전체를 세우는 문을 만들지 않는다. fact 하나가 서는 것은 그 fact 의 일이다 |
| 텔레메트리로 고친 척 | 로그 수준을 올리는 안을 버렸다. projection 은 고친 동작의 상태를 읽는다 |

## 7. 선행 사례

모두 공식 문서에서 2026-11-21T02:54:53Z 에 직접 받아 확인했다.

- **AWS Lambda event source mapping, `BisectBatchOnFunctionError`.** 「If the function returns an error, split the batch in two and retry.」 기본값은 false 다. 개발자 안내서는 이 설정이 「splits a failed batch into two smaller batches, isolating bad records and avoiding timeouts」라고 적고, 기본 설정에서는 「a bad record can block processing on the affected shard for up to one week」라고 적는다. 현상 B 와 같은 모양이고, 처방도 묶음을 반으로 나누는 것이다.
  - https://docs.aws.amazon.com/lambda/latest/api/API_CreateEventSourceMapping.html
  - https://docs.aws.amazon.com/lambda/latest/dg/kinesis-on-failure-destination.html
- **같은 문서, `MaximumRetryAttempts` 와 `MaximumRecordAgeInSeconds`.** 「Discard records after the specified number of retries.」, 「Discard records older than the specified age.」 둘 다 기본값은 무한(-1)이다. 이 RFC 는 횟수와 나이로 버리지 않는다(§4.3). 「모든 slot 이 거절했다」는 타입 있는 사실로 세운다.
- **같은 문서, on-failure destination (`DestinationConfig` 의 `OnFailure`).** 「Send discarded records to an Amazon SQS queue, Amazon SNS topic, Kafka topic, or Amazon S3 bucket.」 실패한 것을 버리지 않고 옆에 둔다는 생각이 같다. 큐레이터는 따로 옮길 곳이 필요 없다. fact 는 Keeper 의 저장소에 그대로 있다.
- **Amazon SQS dead-letter queue, `maxReceiveCount`.** 「the number of times a consumer can receive a message from a source queue before it is moved to a dead-letter queue」. 횟수로 옮기는 방식이다. 이 RFC 는 횟수를 쓰지 않는다.
  - https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html

Lambda 가 나눈 두 묶음을 어떤 순서로 다시 부르는지는 확인하지 않았다.

## 8. 시험과 모델

### 8.1 모델

작은 TLA+ 모델을 둔다. 값어치가 있다고 본다. 규칙이 서로 얽힌다. fact 가 도착하고, lane 세대가 바뀌고, 60초 깨우기가 오고, slot 마다 답이 다르다. 큐레이터에는 지금 모델이 없다(`specs/bug-models/`). Librarian 은 같은 규칙의 모델(`LibrarianWidth.tla`, `LibrarianBottom.tla`)을 갖고 있다.

- 상수: fact 셋, slot 둘. slot 마다 「이 fact 가 든 묶음을 거절한다」, 「이 크기를 넘으면 크기로 거절한다」, 「못 쓰는 답을 낸다」, 「말이 없다」를 정하는 함수.
- 변수: 분류된 fact, 바닥 기억, 좁힌 자리, 기억한 크기, lane 세대, 보낸 요청의 기록(slot, 묶음, 세대).
- 정상 `Next` 가 지키는 invariant 와, 그것을 깨는 `BugAction`:

| invariant | BugAction |
|---|---|
| 한 세대에서 slot 은 자기가 거절한 묶음을 다시 받지 않는다. 한 건도 묶음이다 | 거절된 묶음을 그대로 다시 보낸다(지금의 60초 재전송) |
| pass 는 밀린 fact 가 모두 분류됐거나, 섰거나, 말하지 않은 slot 을 기다릴 때만 끝난다 | 거절을 받고 나머지를 묻지 않은 채 끝난다(지금의 `Failed`) |
| 선 fact 는 그 세대의 모든 slot 이 한 건 요청을 거절한 fact 다 | 못 쓰는 답이나 말 없음에 fact 를 세운다 |
| 기억한 크기는 크기 거절로만 바뀐다 | 크기 사실 없는 거절 뒤의 성공에서 크기를 적는다 |
| 세대가 바뀌면 바닥 기억과 좁힌 자리가 비어 있다 | 세대가 바뀐 뒤에도 선 fact 를 안 묻는다 |

정상 cfg 와 buggy cfg 를 모두 돌린다. `specs/INDEX.md` 는 커밋된 생성 파일이라 모델 PR 에서 다시 만든다.

### 8.2 가짜 provider 시험

기능을 시험한다. `test/test_workspace_memory_curator_lane.ml` 의 가짜 HTTP provider 는 받은 POST 를 센다. 판정은 원장과 그 수로 한다.

| 장면 | 보이는 것 |
|---|---|
| Keeper 셋의 fact 가운데 하나가 든 요청마다 400 | 다른 fact 는 같은 pass 에서 분류된다. 그 fact 는 선다. 60초 깨우기를 돌려도 POST 가 늘지 않는다 |
| 모든 요청에 400 | 모든 fact 가 선다. slot 하나인 lane 에서 POST 는 `2N − 1` 번이다. 깨우기와 다른 Keeper 의 commit 뒤에도 선 fact 는 다시 안 묻는다 |
| 모든 요청에 429 | 아무것도 서지 않는다. 깨우기마다 같은 묶음이 한 번 간다 |
| 400 으로 좁힌 두 절반이 모두 429 | 깨우기에 두 절반이 따로 간다. 처음 묶음은 다시 가지 않는다 |
| slot 둘, 앞은 400, 뒤는 429 였다가 답함 | 한 건이 된 fact 는 서지 않는다. 깨우기에 뒤 slot 만 받는다. 답이 오면 분류된다 |
| 한 건의 답이 매번 JSON 이 아님 | 그 fact 는 서지 않는다. 깨우기마다 그 slot 에 한 번 간다. 다른 fact 는 같은 pass 에서 분류된다 |
| 큰 묶음이 body 기한을 넘기고 작은 묶음에 답함 | 반으로 좁혀 분류된다. 다음 묶음이 기억한 크기 없이 간다 |
| 크기로 거절하다 작은 묶음에 답함 | 지금과 같다. 다음 묶음이 기억한 크기로 간다 |
| 400 으로 좁힌 뒤 성공 | 다음 묶음이 기억한 크기 없이 간다 |
| lane 세대 변경 | 선 fact 를 다시 묻는다 |
| briefing 한 항목에 400 | 앞 완성본이 그대로 읽힌다. 분류는 이어진다. 깨우기에 POST 가 늘지 않는다 |
| lane 표 없음 | projection 이 표 없음을 타입으로 낸다 |

## 9. 층

| 층 | 바뀌는 것 | 확인 |
|---|---|---|
| L1 | Librarian 의 slot 결과 타입, 방문 타입과 `classify`, 걷기 결과를 방문으로 옮기는 함수를 lane 중립 모듈로 옮긴다. `Lost` 를 둘로 가른다. 표 fixture 의 행이 갈린다. Librarian 모듈은 자기 거절 타입을 넣어 같은 이름으로 다시 내보낸다. `keeper_exact_walk_failure.ml` 82·177행 주석 고침 | type-check. 표 시험이 모든 생성자를 지난다. Librarian 의 시험이 그대로 통과한다 |
| L2 | TLA+ 모델과 cfg 들 | 정상 cfg 통과, buggy cfg 마다 invariant 위반 |
| L3 | 분류 단계: 표에서 읽기, 좁히는 조건, 나머지 절반, 좁힌 자리와 크기 기억, 바닥 기억, 깨우는 조건, `step_end` | §8.2 의 분류 장면 |
| L4 | briefing 단계: 표에서 읽기, 좁히는 조건, 선 항목, 출력 한도. 부르는 곳이 없어진 `Exact_lane_slots.failure_evidence` 와 그 시험을 지운다 | §8.2 의 briefing 장면 |
| L5 | projection: 서버 route, TUI 의 World 줄, 응답 schema 이름 | TUI 시험(실제 실행 파일이 응답을 읽는다) |
| L6 | 운영자의 「다시 묻기」(§10 D3 이 하기로 하면) | 요청 뒤 선 fact 가 다시 간다 |

- L1 은 큐레이터와 Librarian 의 판단을 바꾸지 않는다. Librarian 의 로그와 health 응답에 낱말이 하나 는다. 혼자 병합해도 된다. L3 이 큐레이터에서 처음 부른다.
- L1 은 Librarian 모듈 넷을 고친다. `librarian_slot_outcome`, `librarian_slot_visit`, `librarian_ask`(함수 하나가 나간다), `librarian_machine`(`unanswered_token` 에 갈래 하나)이다. Librarian 을 맡은 쪽의 리뷰를 받는다.
- Librarian 의 남은 층(경보 E4, L7 의 남은 조각)은 앞의 두 모듈을 고치지 않는다. 2026-11-21 에 열린 PR 가운데 두 모듈을 고치는 것도 없다. `librarian_machine` 은 그 층들도 고치니 순서를 맞춘다.
- L3 과 L4 는 같은 파일을 고치니 순서대로 올린다.
- 로컬 빌드는 하지 않는다. PR 의 type-check 와, 가지에 dispatch 한 대상 시험으로 확인한다.

**L1 의 주석 두 줄.** 82행은 저장 태그(`provider_cause`)가 `Exact_output.provider_refusal` 과 다른 까닭을, 177행은 창에서 멈춘 빈 답에 저장 생성자를 더하지 않는 까닭을 「이 algebra 는 컷에서 없어진다」로 든다. 그 까닭은 이제 틀렸다. 바꿀 말의 후보는 둘이다.

- a. 「저장 태그는 walk receipt 를 읽는 쪽이 가르는 만큼만 가른다. 더 가늘게 읽는 lane 은 slot 결과 표를 읽는다.」 저장 생성자를 늘리지 않는다. 표는 저장 태그가 아니라 원인에서 읽으니 이 말과 맞는다.
- b. 저장 생성자를 늘린다(`Unclassified_status` 등). 저장된 행의 모양이 달라진다.

권고는 a 다. 저장 모양을 바꿀 까닭이 없다.

## 10. 정할 것

| | 무엇 | 권고 | 누가 |
|---|---|---|---|
| D1 | slot 이 한 일을 읽는 표를 Librarian 의 표 하나로 쓸지(§4.7 c), 큐레이터 쪽에 하나 더 둘지(a) | c. 뜻을 정하는 표가 둘이면 SSOT 위반이다. Librarian 의 정책은 바뀌지 않는다. L1 이 Librarian 모듈을 고치니 Librarian 을 맡은 쪽의 리뷰가 필요하다(§9) | 설계 리뷰 |
| D2 | 보낸 뒤 기한을 넘긴 묶음을 좁힐지, 말 없음처럼 그대로 다시 물을지 | 좁힌다. 기한은 이 요청이 걸린 시간에 대한 사실이다. 좁히지 않으면 큰 묶음 하나가 모든 Keeper 를 세운다. 세우지는 않는다 | 설계 리뷰 |
| D3 | 운영자가 선 fact 를 다시 묻게 하는 길을 낼지 | 낸다(L6). 없으면 재시작이나 lane 선언 변경이 유일한 길이다. 한도를 400 으로 알리는 provider 에서는 한도가 풀려도 fact 가 서 있다(§4.2) | 운영자 |
| D4 | briefing 이 선 항목을 빼고 완성해도 되는지 | 안 한다. briefing 의 계약이 바뀐다 | 운영자 |
| D5 | 재시작마다 선 fact 를 한 번씩 다시 묻는 값을 받아들일지 | 받아들인다. lane 을 켠 뒤 재 보고, 크면 §4.2 의 c 를 다시 본다 | 운영자 |
| D6 | 한 건 요청의 못 쓰는 답도 그 slot 의 판정으로 쳐서 fact 를 세울지 | 세우지 않는다. 세우면 호출은 늘지 않는다. 대신 운 나쁜 표본 하나가 그 fact 를 재시작이나 lane 변경까지 묶는다 | 운영자 |

## 11. 확인하지 못한 것

- 운영에서 이 lane 을 켠 적이 없다. 거절의 종류와 횟수, 한 묶음의 크기, 비용을 모른다.
- 못 쓰는 답이 같은 fact 에 되풀이되는 비율을 모른다. D6 을 정하려면 이 값이 필요하다.
- 다른 Exact lane(verifier, HITL, board attention, candle)의 실패 읽기를 slot 결과 표로 옮기는 일은 이 RFC 밖이다. 그 lane 들이 지금 무엇을 읽는지 보지 않았다.
- `provider_refusal` 의 `Timeout` 은 HTTP status 에서 온 값이고 phase 를 싣지 않는다(`exact_output.ml` 903행). client 넷의 `Timeout _` 은 payload 를 읽지 않았다. 기한 초과와 `Lost` 가운데 어디에 둘지는 L1 에서 정한다.
- `Input_capacity` 가 큐레이터의 걷기에서 나오는지 보지 않았다. 나온다면 지금 좁히던 것을 표로 읽은 뒤에는 좁히지 않는다.
- health 응답의 outcome 낱말을 닫힌 집합으로 읽는 쪽이 있는지 다 찾지 않았다. L1 에서 찾는다.
- 가짜 HTTP provider 가 refusal 로 끝난 빈 답과 기한 초과를 만들 수 있는지 보지 않았다.
- 한 건 요청이 큰 까닭이 이웃(최대 Keeper 수 − 1)인 경우를 재지 않았다. 그 경우 fact 는 크기 거절로 선다. 이웃을 줄여 묻는 것은 이 RFC 밖이다.
- 모든 slot 이 쉬는 동안에도 깨우기마다 저장소를 읽고 묶음을 만든다. 그 값을 재지 않았다.
- inventory 응답을 TUI 말고 누가 읽는지 다 찾지 않았다. L5 에서 찾는다.
- 「작은 묶음일수록 decode 가 통과한다」는 재지 않았다. §4.1 은 그 말에 기대지 않는다.
