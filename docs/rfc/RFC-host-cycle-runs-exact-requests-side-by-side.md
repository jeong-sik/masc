---
rfc: "host-cycle-runs-exact-requests-side-by-side"
title: "host cycle 은 한 설치의 exact 요청을 정해진 수만큼 함께 실행한다"
status: Draft
created: 2026-11-11
updated: 2026-11-11
author: claude
supersedes: []
superseded_by: null
related: ["operator-quiz-lane", "0500", "librarian-history-unknown-resolution", "exact-outcome-unknown-names-its-cause"]
---

# host cycle 은 한 설치의 exact 요청을 정해진 수만큼 함께 실행한다

이슈 #51199 의 설계 문서다. 코드 위치는 main `8574837d0b24` 기준이다.

## 0. 요약

2026-11-10 22Z 에 Librarian 이 끝내는 history 요청이 시간당 77건에서 5~10건으로 떨어졌다.
2026-11-11 03:07Z 에는 Keeper 25명이 끝나지 않은 history 요청을 하나씩 들고 기다렸다.

원인은 둘이 겹친 것이다.

- lane 의 첫 slot 이 요청을 받지 않게 됐고, 요청이 다음 slot 의 계정으로 넘어갔다. 그 계정에서는 요청 하나가 평균 478초 걸린다(§1.4).
- host cycle 은 한 설치의 요청을 하나씩 실행한다. 요청 하나의 시간이 그대로 처리량이 된다.

이 RFC 는 둘째를 다룬다.

- 설치 선언에 `max_exact_in_flight` 키를 둔다. host cycle 은 그 설치의 `exact_output` 요청을 그 수만큼 함께 실행한다.
- 키가 없으면 1이다. 1이면 실행 순서가 지금과 같다(§3.3).
- instance 의 cycle 은 겹치지 않는다. 요청은 cycle 마다 한 번만 시도한다. host 는 대기 목록을 두지 않는다. 이 셋은 그대로다.

수를 올리기 전에 있어야 하는 것이 셋이다(§6).

- 첫 생성 요청의 허가를 기다리다 끊긴 요청이 결과 미확인으로 끝나지 않아야 한다. #51250 을 #51269 가 고친다.
- instance 가 물러날 때 시작 표시가 있는 요청은 `cut` 으로 끝난다. Librarian 은 `cut` 원본에서 멈추고, 그 원본을 푸는 길이 코드에 없다(§2.5). 함께 실행하는 수만큼 한 번에 멈추는 Keeper 가 늘어난다.
- 한 설치가 한 계정에서 쥐는 허가는 `max_exact_in_flight` 를 넘지 않는다. 운영자는 이 수를 그 계정의 `max-concurrent` 와 견줘 정한다(§2.4).

대가는 §5 에 적는다. 그 가운데 하나는 반영 순서다. 함께 실행하면 같은 Keeper 의 admission 결과가 먼저 반영되어, 돌던 history 결과가 버려지는 경우가 는다.

첫째 원인은 이 RFC 가 풀지 않는다. slot 순서를 고치는 운영자 설정이다(§6).

## 1. 측정 (2026-11-11)

읽기만 하는 script 로 셌다. provider 이름은 계열만 적는다.

### 1.1 처리량과 허가

`agent-core-events/2026-11/10.jsonl`(8,468개)과 `11.jsonl`(05:20Z 까지 2,330개)의 `masc:provider_admission:waited` 이벤트다.
Librarian 요청은 Background 등급으로 허가를 받는다(`lib/server/server_lane_addon_exact.ml` 의 `authorize_request`).

| UTC 시 | 끝낸 history 요청 | Background 허가, opencode 계열 (대기 중앙값) | Background 허가, glm-coding 계열 (대기 중앙값) |
|---|---:|---|---|
| 11-10 21Z | 77 | 62번 (7초) | 5번 (25초) |
| 11-10 22Z | 5 | 0번 | 40번 (179초) |
| 11-10 23Z | 8 | 0번 | 33번 (229초) |
| 11-11 00Z | 8 | 0번 | 38번 (191초) |
| 11-11 01Z | 7 | 0번 | 18번 (166초) |
| 11-11 02Z | 9 | 0번 | 30번 (108초) |
| 11-11 03Z | 5 | 0번 | 25번 (112초) |
| 11-11 04Z | 10 | 0번 | 30번 (152초) |

- `keeper-librarian` 의 `durable`·`admission` lane 은 slot 순서가 opencode, glm-coding, tinker, ollama, claude 계열이다.
- 22Z 부터 opencode 계열로 나간 Background 허가가 0번이다. 서버 로그에는 opencode.ai 의 HTTP 429 가 일곱 번 있다(11-10 23Z 1번, 11-11 00Z 2번, 02Z 1번, 03Z 1번, 04Z 2번).
- 11-11 04:40Z 에 서버가 다시 떴다. 그 뒤 05:20Z 까지도 opencode 계열로 나간 허가는 0번이다.
- glm-coding 계정은 `max-concurrent = 4` 다. 실행 중인 runtime.toml 에는 `admission-priority-run-limit` 이 없다. 그래서 등급과 상관없이 도착 순서로 허가한다.
- 11-11 00Z~03Z 의 glm-coding 대기 중앙값은 standard 128초(368번), priority 130초(78번), background 144초(97번)다.
- 같은 창에서 ollama 계열의 standard 대기 중앙값은 2초다(695번).
- Background 등급은 Keeper 쪽 Librarian runtime 도 쓴다(`Standalone_lane.admission_class`, `lib/keeper/keeper_librarian_runtime.ml`). 위 Background 허가에는 그 요청도 섞여 있다.

### 1.2 기다리는 Keeper

`system_log_2026-11-11` 의 `durable Librarian inventory validated` 줄에서 Keeper 마다 마지막 줄을 읽었다(03:07Z).

- 오늘 inventory 를 확인한 Keeper 는 29명이다.
- 그 가운데 25명이 끝나지 않은 original 을 하나씩 갖고 있다. 둘 이상 가진 Keeper 는 없다.
- 05:19Z 에 다시 읽으면 29명 가운데 23명이다.
- 시간당 5~10건이면 맨 뒤 Keeper 는 2.5~5시간을 기다린다.

07:01Z 에 끝나지 않은 original 25개의 진행 기록을 읽었다.

- 접수되어 차례를 기다리는 것이 15개다. worker 가 접수를 거절한 것(`capacity_wait`)이 8개다. `worker_absent` 로 멈춘 것이 2개다.
- worker 의 대기 목록은 frame 한도(2.1)에 닿아 있다. 25개 가운데 23개가 한 번 이상 거절됐다.
- 기다리는 23개 가운데 거절이 가장 많은 것은 220번이다. 접수까지 가장 오래 걸린 것은 6시간 56분이다. 같은 때 3~6분 만에 접수된 것도 있다(#51280).

### 1.3 요청의 크기

host 가 보관한 exact 요청 기록 가운데 24시간 안에 쓰인 `durable` 10건의 프롬프트는 중앙값이 139,640자다.
11-11 02:4xZ 에 실행 중이던 요청 하나는 212,534자였고 10분째 끝나지 않았다.

### 1.4 요청 하나의 시간

창은 11-11 01:55Z~04:16Z 다. 방법은 #51250 에 있다.

- 끝난 요청 18개 가운데 15개의 시작 시각을 허가 대기 이벤트와 맞췄다.
- 15개의 실행 시간 합은 7,165초다. 요청 하나에 평균 478초다. 시간당 7.5건이고 1.1 의 5~10건과 맞는다.
- 그 가운데 허가 대기가 1,667초(23.3%)다. 나머지 5,498초는 허가를 받은 뒤의 시간이다. 요청 하나에 평균 367초다.

### 1.5 끊긴 요청

- 11-11 04:45Z 에 설치 5개에 남아 있는 host 기록 가운데 `outcome_unknown` 은 4개다. 원인은 모두 `interrupted` 다. `cut` 과 `raised` 는 0개다.
- 11-08~11-11 의 system log 에서 worker 가 스스로 끝났다는 줄은 3개다. 모두 11-08 의 operator-quiz 다. keeper-librarian 은 0개다.

### 1.6 재지 못한 것

- opencode slot 이 쉬는 중인지. 허가 0번과 429 일곱 줄로 미뤄 본 것이다.
- instance 가 물러난(detach, 선언 변경) 횟수. 세지 않았다.
- 요청별 시간을 직접 적은 기록. host 의 요청 기록에는 시각이 없다. 1.4 는 앞 기록의 저장 시각으로 미뤄 본 값이다. §8 의 L0 가 시도마다 한 줄을 적는다.
- worker 가 대기 요청 하나를 몇 바이트로 재는지. 1.2 의 거절 횟수는 Keeper 쪽 기록에서 셌다.
- history 결과가 기준 변경으로 버려지는 횟수(2.3). 세지 않았다.
- admission 요청 하나의 시간, 한 Keeper 가 history 요청과 admission 요청을 함께 들고 있는 빈도.

## 2. 지금 구조

### 2.1 host cycle 은 요청을 하나씩 실행한다

계약은 `RFC-operator-quiz-lane.md` §4.4 다.

> Cycles of one instance never overlap.
> For each request in order: deliver a final result the host already holds, or try the work once and deliver its result if it is final.
> It is tried at most once per cycle, so it cannot keep a cycle running.
> The host keeps no list of pending requests.

코드는 `lib/lane_addon/lane_addon_runtime.ml` 의 `run_host_cycle`(1148행)이다.

- `pass`(1304행)가 worker 의 요청 목록을 받는다.
- `each`(1309행)가 목록을 앞에서부터 하나씩 처리한다. `exact_output` 이면 provider 호출이 끝날 때까지 다음 요청으로 가지 않는다.
- 전달이 하나라도 있었으면 `pass` 를 다시 한다(1345행). 전달이 없는 목록에서 cycle 이 끝난다.
- `host_status` 는 cycle 이 끝날 때만 쓴다(1347행).
- `pass` 는 대기 요청 전체를 응답 frame 하나로 받는다. worker 는 대기 요청 전체가 frame(`max_reply_bytes`, keeper-librarian 은 4,194,304 B)에 들어갈 때만 새 요청을 받는다. 넘으면 `capacity_wait` 를 돌려주고, 그 요청은 Keeper 쪽에서 기다린다(`addons/exact_worker.py`). 거절된 요청 사이에는 순서가 없다. 자리가 났을 때 들어맞는 요청이 접수된다(#51280).

instance 마다 fiber 하나가 action, host cycle, observation 을 차례로 돈다(같은 파일의 `loop`). cycle 이 도는 동안 그 instance 의 action 과 observation 도 기다린다. 요청이 끊이지 않으면 cycle 은 끝나지 않는다.

`keeper-librarian` 설치 하나가 모든 Keeper 의 Librarian 요청을 받는다. 그래서 느린 요청 하나가 다른 Keeper 의 요청과 다른 output 의 요청까지 막는다.

### 2.2 요청끼리 나누는 상태는 없다

- `Lane_addon_exact.run`(`lane_addon_exact.ml` 884행)은 요청 id 로 자리를 잡고(`claim`, 805행) 그 요청의 기록만 읽고 쓴다. 같은 id 가 이미 실행 중이면 `Attempt_in_progress` 를 돌려준다(888행).
- worker 와 주고받는 호출은 `Eio.Mutex` 로 한 번에 하나씩 나간다(`lane_addon_worker_protocol.ml`). fiber 여럿이 결과를 전달해도 순서대로 나간다.
- cycle 안의 표(`delivered`, `tried`, `waiting`)는 cycle 지역 값이다.

### 2.3 host 는 keeper-librarian 요청의 순서를 지켜 줄 필요가 없다

- 요청의 내용과 기준은 요청을 만들 때 정해진다. host 가 언제 실행해도 요청은 같다.
- 반영은 Keeper 마다 Memory lane 이 하나씩 한다(`keeper_memory_lane.mli`: "work is serialized within a keeper and runs independently across keepers").
  - history 반영은 요청을 만들 때의 기준(Memory revision 과 facts)을 지금 Memory 와 견준다. 다르면 `Basis_superseded` 로 거절한다(`keeper_librarian_durable_commit.ml` 의 `expected_basis`). 그 결과는 반영되지 않고, Librarian 은 다음 source 선택을 기다린다(`Basis_changed`).
  - admission 반영은 기준을 견주지 않는다. 쓰려는 목적지가 Memory 에 없을 때만 거절한다(`keeper_librarian_admission_commit.ml`).
- 지금도 실행 순서는 도착 순서가 아니다. worker 는 대기 기록을 이름 순서로 내놓고, 이름은 요청 id 의 sha256 이다(`addons/exact_worker.py`). 같은 Keeper 의 `durable` 요청과 `admission` 요청 사이에 정해진 순서가 없다. 이름 순서에서 admission 요청이 앞이면 지금도 그 결과가 먼저 반영될 수 있다.
- 같은 종류 안에서는 요청을 만드는 쪽이 하나씩 만든다.
  - history: Keeper 하나에 끝나지 않은 original 은 하나다. 둘이면 오류다(`keeper_librarian_durable_execution.ml` 의 "multiple unfinished original frontiers"). 1.2 의 측정도 Keeper 마다 하나다.
  - admission: 풀리지 않은 frontier 가 있으면 다음 꼬리를 실행하지 않는다(`keeper_librarian_admission_owner.ml` 547행).
  - floor step: step 은 앞 step 들이 낸 사실을 입력에 싣는다(`keeper_librarian_floor_step_request.mli`). 그래서 앞 답을 받은 뒤에 생긴다.

host 가 순서를 지켜 줄 필요는 없다. 다만 함께 실행하면 어느 결과가 먼저 반영되는지가 달라진다. 그 대가는 §5 에 적는다.

다른 package(candle-appraiser, operator-quiz, workspace-curator, hitl-auto-judge)의 요청이 서로 순서에 기대는지는 보지 않았다. 그 설치는 키가 없으면 지금처럼 하나씩 실행한다.

### 2.4 provider 쪽 상한은 따로 있다

| 무엇 | 어디에 선언하나 | 하는 일 |
|---|---|---|
| `max-concurrent` | binding 표(`[<provider>.<model>]`) | endpoint identity 마다 나가 있는 요청을 센다. 넘으면 기다린다 |
| `admission-priority-run-limit` | provider 표 | 그 provider 에서 `max-concurrent` 를 선언한 binding 의 허가 순서를 정한다 |

- `max-concurrent` 선언이 없는 binding 은 허가 없이 바로 나간다(`exact_output.ml` 1260행).
- 빈 자리가 있고 기다리는 요청이 없으면 어느 등급이든 바로 허가를 받는다(`slot_scheduler.ml` 의 `request_slot`). 등급마다 쥘 수 있는 자리 수는 없다.
- 한도는 기다리는 요청 사이의 순서만 정한다. 앞 등급이 기다리는 동안 Background 는 앞 등급 허가 `limit` 번마다 한 번 허가를 받는다(`next_queue`). 한도가 없으면 줄이 하나다.
- body deadline 이 있는 slot 에서는 허가 대기와 실행이 한 시간 한도를 같이 쓴다(`exact_output.ml` 1262~1273행의 `with_admission_and_work_for`). 허가를 받기 전에 한도가 지나면 그 slot 은 timeout 으로 끝나고 다음 slot 으로 간다.
- 입력 token 을 재는 요청도 같은 허가를 받는다(`exact_output_flow_admission.ml`). 그래서 slot 하나에서 허가 줄에 두 번 설 수 있다. 재는 요청이 쥔 허가는 그 요청이 끝나면 놓는다.
- CLI slot 은 HTTP slot 이 모두 지나간 뒤에 official client 프로세스로 실행한다(`server_lane_addon_exact.ml`). 프로세스 수를 묶는 `Runtime_cli_spawn_gate` 는 antigravity runtime 만 쓴다.
- 쉬는 slot 은 뒤로 미룬다. 증거는 호출이 시작할 때 읽고 flow 가 끝날 때 적는다(`Runtime_exact_lane_backpressure` 의 `order` 와 `observe`).

지금 한 설치가 한 계정에서 쥐는 허가는 하나다. host cycle 이 하나씩 실행하기 때문이다.

### 2.5 끊긴 요청

- `run` 은 provider 호출에 들어가기 전에 시작 표시(`Started`)를 저장한다(983행). 허가 대기는 그 뒤, 호출 안에서 일어난다.
- #51250 을 고치는 #51269 는 이 표시를 첫 생성 요청을 보내기 직전에 저장한다. HTTP slot 에서는 허가를 받은 뒤이고 전송 앞이다. CLI slot 에서는 official client 를 띄우기 직전이다. 입력 token 을 재는 요청은 표시를 쓰지 않는다. 아래에서 "시작 표시가 있다"는 이 뜻이다.
- 표시가 쓰이기 전에 끊긴 요청은 기록에 시도가 남지 않아서 다음에 다시 실행된다. 표시가 쓰인 뒤에 끊기면 요청이 나가기 전이어도 표시가 남는다.
- 호출이 끊기면 기록에 시작 표시만 남는다. 그 요청이 다시 나오면 host 는 `outcome_unknown` 으로 끝내고 다시 부르지 않는다. 원인 이름은 `RFC-exact-outcome-unknown-names-its-cause.md` 가 정했다.

| 끊긴 경우 | 원인 | history 원본 | admission part |
|---|---|---|---|
| 서버가 멈췄다 다시 떴다 | `interrupted` | 정리하고 같은 범위를 새 요청으로 다시 준비한다 | 정리하고 같은 part 를 다시 판정한다 |
| 서버가 도는 동안 호출이 취소됐다 | `cut` | 끝나지 않은 것으로 남는다. pass 마다 같은 원본을 다시 잡는다 | 기다림으로 남는다 |
| 호출이 예외를 던졌다 | `raised` | `cut` 과 같다 | `cut` 과 같다 |

- `interrupted` 를 다시 준비하는 계약은 `RFC-0500` 이다. 코드는 `keeper_librarian_durable_commit.ml` 246~251행과 `keeper_librarian_admission_owner.ml` 의 `settle_interrupted` 다.
- floor step 은 원인과 상관없이 기다림으로 남는다(`keeper_librarian_floor_step_owner.ml` 의 `refused`).
- 서버가 도는 동안 호출이 취소되는 길은 둘이다.
  - instance 가 물러나면 실행 중인 호출을 취소한다(`retire_admission`, `lane_addon_runtime.ml` 211행).
  - Keeper 를 purge 하면 그 Keeper 의 실행 중인 호출만 취소한다. instance 는 그대로 돈다(`keeper_memory_lane.ml` 의 `External_effect_purge`).
- `retire_admission` 을 부르는 곳은 여섯이다. worker 가 스스로 끝남, 상태 저장 실패, detach, effect 결과 미확인 셋이다. 여섯 곳 모두 owner domain 에서 돈다.
- reconcile 은 선언의 revision 이 바뀌었거나 `enabled` 가 꺼지면 detach 를 부른다(4491~4520행). worker 가 스스로 끝난 instance 도 다음 reconcile 이 물리고, 같은 프로세스가 새 instance 를 붙인다(worker 의 `await_exit` 를 기다리는 자리의 주석).
- `cut`·`raised` 원본을 푸는 길은 코드에 없다. `Cut` 을 가르는 곳은 위 두 파일과 `keeper_librarian_durable_owner.ml`, `workspace_memory_execution_capture.ml` 이다. 네 곳 모두 `Raised` 를 같은 갈래에 두고, 어느 곳도 그 원본을 정리하지 않는다. Curator 도 `cut`·`raised` 에서 막힌다.
- `RFC-librarian-history-unknown-resolution.md`(#50828)는 host 기록이 없는 원본을 다룬다. host 기록이 `outcome_unknown` 으로 끝난 원본은 그 문서의 대상이 아니다.

지금은 instance 가 한 번 물러날 때 끊기는 호출이 최대 하나다.

### 2.6 선언의 revision 이 바뀐 뒤

- Librarian 요청은 만들 때의 목적지를 싣는다. 설치 id, package id, tool, 선언의 revision 이다(`lane_addon_runtime.ml` 2343행).
- host 는 요청을 보내기 전에 그 revision 을 지금 선언의 revision 과 견준다(`authorize_captured_exact_dispatch`, 612행). 다르면 `run` 이 `Error` 를 돌려주고, host cycle 은 그 요청에 `Exact_record_failed` 를 남긴다. 그 요청은 cycle 마다 같은 오류로 남는다.
- Keeper 쪽도 같은 비교로 다시 보내기를 거절한다(`keeper_librarian_durable_edge.ml` 과 `keeper_librarian_admission_dispatch.ml` 의 `confirm_destination`).
- revision 은 `id`, `run_id`, `manifest_path`, package, binding 으로 만든다(`lane_addon_config.ml` 의 `decode`). 선언의 `tool_hooks` 와 `exact_outputs` 는 package 에 들어간다.
- keeper-librarian 의 binding 은 빈 `sources` 만 받는다(`addons/keeper-librarian/lane.toml` 의 `binding_schema`). 그래서 이 설치의 revision 은 `run_id` 나 package 가 바뀔 때 바뀐다.
- `enabled` 는 revision 밖이다. 설치를 껐다 켜면 revision 이 같은 새 instance 가 붙는다.

Keeper 쪽은 그 원본을 새 revision 으로 다시 준비하지 않는다(#51278).

- 다음 pass 는 worker 를 부르기 전에 같은 비교에서 거절한다. worker 에 상태를 묻는 호출도 그 비교를 먼저 거친다(`keeper_librarian_durable_owner.ml` 의 `call`).
- 끝나지 않은 원본이 있는 Keeper 는 새 범위를 고르지 않는다(`keeper_librarian_durable_execution.ml` 479행). 그 Keeper 의 durable Librarian 은 선언을 예전 값으로 되돌릴 때까지 멈춘다.
- 1.2 의 상태에서 package 를 올리면 기다리던 23명이 그렇게 멈춘다.

## 3. 설계

### 3.1 계약

`RFC-operator-quiz-lane.md` §4.4 "One cycle" 의 2번과 3번을 이렇게 바꾼다.

> 2. For each request in order: deliver a final result the host already holds, or try the work once and deliver its result if it is final.
>    - An `exact_output` request runs beside the walk. The walk goes on to the next request only while fewer than the installation's `max_exact_in_flight` exact requests are running. With 1 the walk waits for each one.
>    - An `ask` is recorded once per request id. Its result is delivered only when the operator has answered it or the package has withdrawn it.
>    - A request whose attempt was not final stays undelivered until the next trigger. It is tried at most once per cycle, so it cannot keep a cycle running.
> 3. When every request of the listing has ended, list again. The cycle ends when a listing produces no delivery.

그대로 두는 것:

- instance 의 cycle 은 겹치지 않는다.
- 요청은 cycle 마다 한 번만 시도한다.
- host 는 대기 목록을 두지 않는다. cycle 지역 표만 쓴다.
- cycle 을 여는 사건. 타이머는 없다.
- 요청 id·digest 규칙, 결과 보관, `relisted_delivered_request`.
- `exact_output` 이 아닌 요청은 걷는 자리에서 처리한다.

### 3.2 수는 설치 선언에 둔다

```toml
# <config-root>/lane-addons/keeper-librarian.toml
id = "keeper-librarian"
run_id = "..."
manifest_path = "..."
max_exact_in_flight = 3

[binding]
```

- 1 이상의 정수다. 0 이하와 정수가 아닌 값은 그 선언의 parse 오류다.
- 키가 없으면 1이다.
- 코드에 상한을 두지 않는다.
- 선언의 revision 에 넣지 않는다. revision 은 worker 의 입력(`id`, `run_id`, `manifest_path`, package, binding)만 이름한다(`lane_addon_config.ml` 의 `decode`). 이 수를 바꿔도 worker 는 다시 뜨지 않고, 대기 중인 요청도 2.6 의 검사에 걸리지 않는다.
- 수는 instance 가 들고 있다. 닿는 길은 둘이다.
  - 새 instance 를 붙일 때 선언의 수를 넘긴다(`attach_entry`).
  - reconcile 은 revision 이 같은 선언의 수를 살아 있는 instance 에 옮긴다(4515행의 갈래).
- reconcile 이 그 선언을 적용하지 못하는 동안에는 수가 옮겨지지 않는다. 읽지 못한 보관 기록이 있거나 연결 검증이 실패한 경우다. 그동안 instance 는 앞의 수로 돈다.
- host cycle 은 pass 를 시작할 때 수를 읽는다. 도는 pass 는 시작할 때의 수로 끝난다.
- 선언 없이 붙인 instance(manual attach)는 1이다.
- 이 키를 모르는 빌드는 그 선언을 `unknown declaration field` 로 거절한다. 그래서 키는 그 선언 파일을 읽는 서버가 모두 L1 이상일 때 선언하고, 되돌릴 때는 키부터 지운다.

`max-concurrent` 와는 세는 것이 다르다.

| | `max-concurrent` | `max_exact_in_flight` |
|---|---|---|
| 자리 | runtime.toml 의 binding 표 | 설치 선언 |
| 세는 것 | 한 계정에 나가 있는 요청 (Keeper 턴 포함) | 한 설치에서 host 가 실행 중인 exact 요청 |
| 넘으면 | 허가를 기다린다 | 걷기가 다음 요청으로 가지 않는다 |
| 묶는 것 | provider 의 동시 요청 | 이 설치가 한 계정에서 쥐는 허가, instance 가 물러날 때 끊기는 호출, CLI slot 에 뜨는 프로세스 |

실행 중인 요청 하나는 한 번에 허가 하나만 쥔다. 그래서 한 설치가 한 계정에서 쥐는 허가는 `max_exact_in_flight` 를 넘지 않는다.

lane 표(output 마다)가 아니라 설치 선언에 두는 이유는 §7 에 적는다.

### 3.3 한 pass

```text
pass ():
  목록 ← worker 의 대기 요청 (순서 유지)
  목록을 순서대로 걷는다:
    이미 전달한 id 가 다시 나오면 걷기를 멈춘다 (Relisted_delivered_request)
    이번 cycle 에 시도한 id 는 건너뛴다
    exact_output 이 아니면 그 자리에서 처리한다
    exact_output 이면 fiber 하나로 시작한다
    실행 중인 exact 요청이 max_exact_in_flight 개면 하나가 끝날 때까지 기다린다
  실행 중인 요청이 모두 끝날 때까지 기다린다
  걷기를 멈춘 오류가 있으면 cycle 을 그 오류로 끝낸다
  전달이 하나라도 있었으면 pass () 를 다시 한다
```

- 수가 1이면 걷기는 exact 요청 하나를 시작하고 그 요청이 끝날 때까지 기다린다. 뒤에 오는 요청은 종류와 상관없이 그 뒤에 처리된다. 지금의 `each` 와 순서가 같다.
- fiber 하나가 하는 일은 지금의 `try_request` → 전달이다. 보관된 final 이 있으면 provider 를 부르지 않고 전달한다.
- 요청 하나의 실패(`Exact_record_failed`, `Ask_record_failed`, `Result_delivery_failed`)는 값으로 돌려준다. 다른 요청은 계속 간다. `host_status.issue` 에는 목록 순서로 첫 실패를 남긴다. `waiting` 과 `exact_waiting` 도 목록 순서로 적는다.
- cycle 을 끝내는 오류는 다섯이다(`Listing_failed`, `Listing_refused`, `Relisted_delivered_request`, `No_exact_runner`, `No_web_search_runner`). 앞 둘은 실행 중인 요청이 없을 때 난다. 나머지는 걷는 중에 날 수 있다. 그때 걷기는 새 요청을 시작하지 않고, 실행 중인 요청이 끝나 전달된 뒤에 cycle 을 끝낸다. 실행 중인 호출을 이 오류로 끊지 않는다.
- cycle 지역 표는 같은 domain 의 fiber 들이 effect 사이에서만 고친다. 잠금을 더하지 않는다.

### 3.4 취소

- 호출마다 지금처럼 `Eio.Cancel.sub` 하나를 둔다(1180~1185행). 전달은 그 밖에 있다.
- instance 는 실행 중인 호출의 취소 함수를 요청 id 로 모아 둔다. 지금의 `cancel_exact`(하나)를 이 표가 대신한다.
- 표에서 지우는 일은 지금처럼 그 sub 안의 finally 에서 한다. 끝난 context 를 취소하면 Eio 가 `Invalid_argument` 를 던지기 때문이다.
- instance 가 물러나면(`retire_admission`) 표의 호출을 모두 취소한다. 취소 하나가 예외를 던져도 나머지를 계속 취소하고, 받은 예외는 끝에 한 번 다시 던진다. 호출 하나에 일어나는 일은 지금과 같다.
- 취소된 호출 가운데 시작 표시가 있는 것은 `cut` 이 된다. 앞 slot 에 생성 요청을 보낸 적이 있으면 뒤 slot 의 허가 줄에서 끊겨도 표시가 있다.
- 시작 표시가 없는 요청은 기록이 그대로 남는다. 첫 생성 요청의 허가를 기다리던 요청이 여기에 든다. revision 이 같은 instance 가 다시 붙으면 그 요청을 다시 실행한다. revision 이 바뀌었으면 2.6 대로 보내지 않는다.
- Keeper purge 가 취소하는 호출(2.5)은 이 표를 거치지 않는다. 지금과 같다.

### 3.5 예외

- `Lane_addon_exact.run` 은 `call` 이 던진 예외를 `outcome_unknown`(`raised`)으로 적고 값으로 돌려준다(988~995행). provider 실패가 아닌 예외도 여기로 온다. CLI slot 에서 보내기 직전의 권한 검사가 거절되면 `Dispatch_authority_refused` 를 던지고, 그 요청은 `raised` 로 끝난다(`server_lane_addon_exact.ml`). 보내기 전에 난 예외는 #51268 이 다룬다.
- `run` 의 그 밖의 자리(`authorize_request`, `with_execution`, `before_dispatch`, `runner`, 기록 저장)가 던진 예외는 `run` 밖으로 나온다. 걷기가 그 자리에서 처리하는 요청과 전달 코드가 던진 예외도 같다. 지금은 이 예외가 instance 를 Failed 로 만든다. 지금은 그때 실행 중인 provider 호출이 없다.
- fiber 여럿이 한 scope 에 있으면 한 fiber 의 예외가 옆 호출을 취소한다. 취소된 호출 가운데 시작 표시가 있는 것은 `cut` 이 된다.
- 그래서 exact fiber 의 예외와 걷기 자신의 예외를 모두 잡아 둔다. 걷기는 새 요청을 시작하지 않는다. 실행 중인 호출이 끝나 전달된 뒤에 처음 잡은 예외를 다시 던진다. instance 가 Failed 가 되는 것은 지금과 같다.
- 취소(`Eio.Cancel.Cancelled`)와 `Host_cycle_stopped` 는 잡지 않는다. `Host_cycle_stopped` 는 instance 가 물러날 때만 난다(`stopping` 을 켜는 곳은 `retire_admission` 하나다). 그때는 3.4 가 실행 중인 호출을 이미 취소했다. 전달 중이던 옆 fiber 도 취소되고 worker 연결이 끊긴다. instance 가 물러나는 중이라 결과는 지금과 같다.
- scope 밖으로 서로 다른 예외 둘이 나가면 Eio 는 `Eio.Exn.Multiple` 로 묶는다. 지금의 `with Host_cycle_stopped`(1346행)는 그것을 받지 못한다. 걷기는 fiber 의 끝을 값으로 모으고, scope 밖으로는 예외 하나만 내보낸다.
- 예외 하나를 고르는 규칙은 이렇다. 잡아 둔 예외가 있으면 그 뒤에 난 `Host_cycle_stopped` 는 버리고, 실행 중인 호출이 끝난 뒤 잡아 둔 예외를 던진다. `Host_cycle_stopped` 가 먼저 나가는 중이면 취소된 호출이 던진 것은 버린다. 어느 쪽이든 instance 는 물러나거나 Failed 가 되고, 실행 중인 호출은 3.4 가 취소한다.

### 3.6 host 가 적는 것

- 시도가 끝날 때 로그 한 줄을 적는다. 설치 id, output, 결과 종류, 걸린 ms, 시작할 때 함께 실행 중이던 수를 싣는다. 요청 본문은 싣지 않는다.
- 이 줄로 시간당 처리량, 요청별 시간, 겹쳐 실행된 구간을 센다.
- 이 줄에 없는 값은 이미 있는 기록에서 센다. 계정의 허가 대기는 `masc:provider_admission:waited` 이벤트다. 기준 변경으로 버려진 history 결과는 Keeper 쪽 원본 기록의 `Commit_conflicted` 사건이다.
- `host_status` 는 그대로 둔다. 도는 cycle 을 화면에 보여 주는 일은 이 RFC 의 범위가 아니다(§9).

### 3.7 코드가 놓이는 자리

- `lane_addon_runtime.ml` 은 4,785줄이다. 걷기와 자리 세기는 새 모듈(`lane_addon_host_walk.ml`)에 둔다. `run_host_cycle` 의 `each` 가 그 모듈을 부른다.
- 키는 `lane_addon_config.ml` 의 `decode` 가 읽는다. 허용 필드 목록(124행)에 하나를 더한다.
- 수는 instance 에 둔다. `attach_entry` 가 인자로 받고, reconcile 의 "revision 이 같다" 갈래(4515행)가 선언의 수로 맞춘다.
- 선언의 필드를 나열하는 다른 자리는 그대로 둔다. 새 선언의 틀(`bin/masc_tui_lane_declaration.ml`, `dashboard/src/lib/lane-declaration-sessions.ts`)과 설치기(`bin/masc_tui_lane_installer.ml`, `dashboard/src/lib/lane-package-installation-session.ts`)는 키 없이 선언을 만든다. 키가 없으면 1이다. 운영자는 선언 원문을 고쳐 키를 넣는다.

## 4. 틱으로 따라가 보기

`max_exact_in_flight = 3` 인 keeper-librarian 설치다. 목록은 worker 의 이름 순서다.

### 4.1 여러 Keeper 의 요청

| 틱 | 일 |
|---|---|
| N | 목록 = h1(Keeper a), h2(b), a1(c), h3(d), h4(e). 걷기가 h1·h2·a1 을 시작하고 h3 앞에서 기다린다 |
| N+1 | a1 이 끝나 전달된다. `Exact_result_delivered` 가 Keeper c 의 Librarian 을 깨운다. 걷기가 h3 을 시작하고 h4 앞에서 기다린다 |
| N+2 | Keeper c 가 다음 요청 a2 를 worker 에 낸다. a2 는 이번 목록에 없다 |
| N+3 | h2 가 끝나 전달된다. 걷기가 h4 를 시작한다. 목록 끝이다 |
| N+4 | h1·h3·h4 가 끝난다. 전달이 있었으니 다시 list 한다. 목록 = a2, … |
| N+M | 전달할 것이 없는 목록이 오면 cycle 이 끝나고 observation 이 한 번 돈다 |

- h1·h2·h3·h4 는 Keeper 가 달라서 서로 순서가 없다.
- 같은 Keeper 의 `durable` 요청과 `admission` 요청이 함께 실행될 수 있다. 반영은 그 Keeper 의 Memory lane 에서 하나씩 일어나고, 먼저 끝난 쪽이 먼저 반영된다(2.3). 그 대가는 §5 에 있다.
- Keeper 가 다른 Keeper 에게 일을 넘겨도 Librarian 요청은 Keeper 마다 따로 생긴다. host 의 실행 순서와 상관없다.
- a2 는 N+4 까지 기다린다. 목록 사이에서는 그 pass 의 가장 느린 요청을 기다린다(§5).

### 4.2 첫 slot 이 쉬기 시작한다

| 틱 | 일 |
|---|---|
| N | h1·h2·h3 이 같은 때 증거를 읽는다. 셋 다 slot S1 부터 간다 |
| N+1 | S1 이 429 를 준다. 셋이 각자 거절을 받고 S2 로 넘어간다. 증거는 flow 가 끝날 때 적힌다 |
| N+2 | h4 는 증거를 읽고 S2 부터 간다 |

지금은 쉬기 시작할 때 거절이 한 번이다. 이 설계에서는 최대 `max_exact_in_flight` 번이다.

### 4.3 context window 가 다른 slot

- h1(큰 프롬프트)이 S2 에서 입력 거절을 받는다. 넘어갈 수 있는 실패라서 S3 으로 간다(`exact_output_flow.ml` 의 `execute_candidates`).
- h2(작은 프롬프트)는 S2 에서 끝난다.
- 걷기가 끝나면 `ending`(`server_lane_addon_exact.ml` 29행)이 지나온 slot 의 실패를 본다. 다음 사건에 통과할 수 있는 실패(transient, 인증, 설정)가 하나라도 있으면 final 이 아니다. 없고 입력 거절이 있으면 `input_refused` 다.
- 요청마다 slot 을 따로 걷는다. 한 요청이 넘어가도 다른 요청은 영향을 받지 않는다.

### 4.4 HTTP slot 이 모두 지나가고 CLI slot 으로

- h1·h2·h3 이 모두 CLI slot 까지 오면 official client 프로세스가 셋 뜬다.
- antigravity 가 아닌 CLI runtime 에서 이 수를 묶는 것은 `max_exact_in_flight` 뿐이다.

### 4.5 서버가 내려간다

| 틱 | 일 |
|---|---|
| N+k | h1·h2 는 생성 요청을 보낸 뒤다. h3 은 첫 생성 요청의 허가를 기다린다. 서버가 내려간다 |
| 다음 시작 | h1·h2 는 `interrupted` 로 끝난다. Librarian 이 두 원본을 정리하고 같은 범위를 새 요청으로 다시 준비한다. h3 은 시작 표시가 없어서 그대로 다시 실행된다(#51269) |

- 멈추는 Keeper 는 없다. 대가는 provider 를 다시 부르는 요청이다. 지금은 재시작 한 번에 최대 하나, 이 설계에서는 최대 `max_exact_in_flight` 개다.
- floor step 요청은 `interrupted` 에서도 기다림으로 남는다(2.5).

### 4.6 instance 가 물러난다

revision 이 같은 채 물러나는 경우다. 운영자가 설치를 껐다 켠다.

| 틱 | 일 |
|---|---|
| N+k | h1·h2 는 생성 요청을 보낸 뒤다. h3 은 첫 생성 요청의 허가를 기다린다. 운영자가 선언을 `enabled = false` 로 저장한다 |
| 다음 reconcile | instance 가 물러난다. 세 호출이 취소된다 |
| 운영자가 다시 켠다 | revision 이 같은 새 instance 가 붙는다. worker 의 상태는 설치 id 와 package id 로 남아 있어서 같은 요청을 다시 낸다 |
| 새 instance 의 cycle | h1·h2 는 같은 프로세스가 남긴 시작 표시라서 `cut` 으로 끝난다. h3 은 그대로 다시 실행된다 |
| 그 뒤 | Keeper a·b 의 history 원본이 끝나지 않은 것으로 남는다. 푸는 길이 없다(2.5) |

- Detach 한 뒤 다시 붙인 경우와 worker 가 스스로 끝난 경우도 이 표와 같다.
- 지금은 한 번 물러날 때 `cut` 이 최대 하나, 이 설계에서는 최대 `max_exact_in_flight` 개다.

revision 이 바뀌어 물러나는 경우다. 운영자가 package 를 올리거나 `run_id` 를 바꾼다.

| 틱 | 일 |
|---|---|
| N+k | 호출 셋의 상태는 위와 같다. 운영자가 선언의 `manifest_path` 를 새 package 로 바꾼다 |
| 다음 reconcile | revision 이 달라서 instance 가 물러난다. 세 호출이 취소된다. 그 뒤의 reconcile 이 새 instance 를 붙인다 |
| 새 instance 의 cycle | h1·h2 는 `cut` 으로 끝난다. host 는 시작 표시를 권한 검사보다 먼저 본다. h3 과 목록의 나머지는 보내기 전 검사에서 거절되고 `Exact_record_failed` 로 남는다(2.6) |
| 그 뒤 | cycle 마다 같은 오류가 남는다. Keeper 쪽도 pass 마다 같은 비교에서 거절한다. 그 Keeper 의 durable Librarian 은 선언을 되돌릴 때까지 멈춘다(2.6) |

- 이 경우 시작 표시가 없는 요청에 일어나는 일은 지금과 같다. 이 설계가 바꾸는 것은 `cut` 의 수다.

### 4.7 설정이 바뀐다

- pass 도중 `max_exact_in_flight` 를 3에서 1로 낮춘다. 실행 중인 셋은 끝까지 간다. 다음 pass 부터 하나씩 간다.
- lane 의 slot 을 바꾼다. lane publication 변경 사건으로 cycle 이 한 번 더 돈다. 실행 중인 호출은 시작할 때 읽은 slot 목록으로 끝난다(`server_lane_addon_exact.ml` 의 `runner_with`).
- 설치 선언의 내용(`run_id`, `manifest_path`, package, binding)이 바뀌면 4.6 의 둘째 표다.
- 선언 파일의 경로만 바뀌면 instance 는 그대로다. 그 사이에 끝난 요청은 전달 직전의 authority 비교에서 걸린다(`deliver_arguments`, 1281행). frame 에 들어가는 결과는 exact 기록에 남아 있어서 다음 cycle 이 전달한다. frame 을 넘는 결과는 앞의 authority 로 link 가 먼저 저장되고, 다음 cycle 의 `restore` 가 그 link 를 거절한다(`lane_addon_host_delivery.ml`). 지금과 같다.

## 5. 이 설계가 푸는 것과 못 푸는 것

푸는 것:

- 한 목록 안에서 느린 요청 하나가 다른 Keeper 의 요청을 막는 일. 자리가 `max_exact_in_flight` 개라서 느린 요청이 그 수만큼 겹쳐야 막힌다.
- 한 목록 안에서 `durable` 요청이 `admission` 요청을 막는 일. 같은 조건이다.

못 푸는 것:

- 목록 사이의 기다림. pass 는 실행 중인 요청이 모두 끝난 뒤에 다시 list 한다. pass 도중에 생긴 요청은 그 pass 의 가장 느린 요청이 끝날 때까지 기다린다. 요청 하나의 시간 한도는 slot 마다 `exact-body-timeout-s` 이고, 요청은 다음 slot 으로 이어 갈 수 있다.
- cycle 의 길이. 요청이 끊이지 않으면 cycle 은 지금처럼 끝나지 않고, 그 instance 의 action 과 observation 은 기다린다.
- 포화된 계정. 계정이 내는 총량은 그대로다. 이 설치가 허가를 더 쥐는 만큼 Keeper 턴이 기다린다.
- 쉬는 slot 다음이 느린 계정인 경우. lane 은 그 slot 에서 허가를 기다리고, body deadline 이 지나야 다음 slot 으로 간다. 뒤 slot 이 비어 있어도 먼저 가지 않는다(1.1 의 ollama 계열).
- worker 대기 목록의 상한과 접수 순서. 대기 요청 전체가 frame 하나에 들어가야 하는 것은 그대로다(2.1). 함께 실행하면 목록에서 요청이 더 빨리 빠질 뿐이다. 접수가 온 순서가 아닌 것도 그대로다(#51280).
- 끝나지 않은 원본의 본문을 pass 마다 다시 검증하는 비용(#51281). 원본이 기다리는 시간이 줄면 같이 준다.

대가:

- instance 가 한 번 물러날 때 `cut` 으로 끝나는 요청이 `max_exact_in_flight` 개까지 는다(4.6). 그 수만큼 Keeper 의 history 나 admission 이 멈춘다.
- 같은 Keeper 의 history 요청과 admission 요청이 한 목록에 있으면 함께 실행되고, 먼저 끝난 쪽이 먼저 반영된다. admission 결과가 먼저 반영되어 Memory 가 바뀌면 돌던 history 결과는 `Basis_superseded` 로 버려진다(2.3). 지금은 history 호출이 도는 동안 그 Keeper 의 admission 호출이 시작하지 못한다. 버려지는 것은 provider 호출 하나와 그 시간이다. 1.4 의 평균으로 478초다. 얼마나 자주 일어나는지는 재지 못했다(1.6).
- 재시작 한 번에 provider 를 다시 부르는 요청이 그 수까지 는다(4.5).
- slot 이 쉬기 시작할 때 거절이 그 수까지 는다(4.2).
- CLI slot 까지 가면 official client 프로세스가 그 수만큼 뜬다(4.4).
- 한 계정에서 이 설치가 쥐는 허가가 하나에서 그 수까지 는다. `admission-priority-run-limit` 은 기다리는 요청의 순서만 정하고 쥐는 수는 묶지 않는다(2.4). 기다리는 Keeper 턴이 없을 때 이 설치가 빈 자리를 모두 쥘 수 있고, 그 뒤에 온 Keeper 턴은 그 가운데 하나가 끝날 때까지 기다린다.
- 허가 줄에 서 있는 요청이 늘면 줄에서 body deadline 을 다 쓰고 다음 slot 으로 넘어가는 요청도 는다(2.4).

## 6. 켜는 순서

1. 운영자가 설정을 본다. 코드 변경이 아니고, 이번 일에는 이것이 가장 빠르다.
   - `durable` lane 의 slot 순서를 본다. 쉬는 slot 다음에 느린 계정이 온다(1.1).
   - 포화된 계정의 provider 표에 `admission-priority-run-limit` 을 선언한다. 저장소 기본 `config/runtime.toml` 은 3이다.
2. #51269 를 병합한다(#51250). 첫 생성 요청의 허가를 기다리다 끊긴 요청이 결과 미확인으로 끝나지 않는다.
3. L0 를 배포한다. 시도마다 로그 한 줄이 남는다. 동작은 그대로다.
4. L1, L2 를 배포한다. 키를 선언한 설치가 없으니 동작은 그대로다.
5. `cut`·`raised` 원본을 푸는 길이 생긴다. 이 RFC 는 그 길을 설계하지 않는다(§7 의 마지막 두 줄).
6. keeper-librarian 설치의 `max_exact_in_flight` 를 올린다. 올리는 수는 그 설치의 lane 이 거치는 계정 가운데 `max-concurrent` 가 가장 작은 것보다 작게 둔다. 같거나 크면 이 설치 혼자 그 계정의 자리를 모두 쥘 수 있다.
7. 올리기 전과 뒤를 견준다. 볼 값은 넷이다.
   - 시간당 끝낸 요청. L0 의 줄에서 센다.
   - 요청별 시간. L0 의 줄에서 센다.
   - 같은 계정의 standard 대기 중앙값. `masc:provider_admission:waited` 이벤트에서 센다.
   - 기준 변경으로 버려진 history 결과. Keeper 쪽 원본 기록의 `Commit_conflicted` 사건에서 센다.

이 순서의 어느 단계도 keeper-librarian package 를 올리지 않는다. L0~L2 는 host 쪽 변경이고, `max_exact_in_flight` 는 revision 밖이다(3.2). 원본이 기다리는 동안 package 를 올리면 그 원본들이 막힌다(2.6).

5번 없이 6번을 하면 instance 가 물러날 때마다 멈추는 Keeper 가 는다. 1.5 의 기록으로는 `cut` 이 0개이고 keeper-librarian worker 가 스스로 끝난 적이 없다. 그래서 5번을 건너뛰는 선택도 있다. 그 선택의 대가는 4.6 의 첫째 표다.

## 7. 대안

| 대안 | 버린 이유 |
|---|---|
| slot 순서만 바꾼다 | 이번 일에는 가장 빠르다. 구조는 그대로라 첫 slot 이 다시 쉬면 같은 일이 난다. §6 의 1번에 넣었다 |
| lane 표(output 마다)에 수를 둔다 | 수가 모두 1이어도 output 이 다르면 요청이 함께 실행된다. 키가 없을 때의 동작이 지금과 달라진다. 한 계정에서 쥐는 허가는 lane 마다의 수를 더한 값이 된다 |
| 수를 두지 않고 `max-concurrent` 에 맡긴다 | 목록 전체가 허가 줄에 선다. 줄에서 body deadline 을 다 쓴 요청이 다음 slot 으로 넘어간다. `max-concurrent` 선언이 없는 binding 과 CLI slot 에는 상한이 없다 |
| 허가 쪽에 등급별 자리 수를 둔다 | Background 가 쥐는 자리를 계정에서 묶는다. Keeper 쪽 Librarian runtime 까지 같이 묶인다. host cycle 이 하나씩 실행하는 것은 그대로다. 이 RFC 의 대가(쥐는 허가)를 줄이는 보완이고 따로 다룬다 |
| 자리가 날 때마다 다시 list 한다 | 목록 사이의 기다림이 없어진다. 실행 중인 요청이 새 목록에 다시 나오니 건너뛰는 표가 하나 더 필요하다. cycle 이 끝나는 조건이 "전달 없는 목록"에서 "전달 없는 목록이고 실행 중인 것도 없다"로 바뀐다. list 마다 대기 요청 전체를 다시 받는다(2.1). L0 의 줄로 목록 사이의 기다림을 잰 뒤에 정한다 |
| 허용량이 찬 slot 에서 기다리지 않고 다음 slot 으로 간다 | slot 순서의 뜻이 "선호"에서 "지금 빈 것 가운데 선호"로 바뀐다. 품질과 비용이 다른 slot 으로 넘어간다. 따로 다룬다 |
| Keeper 마다 설치를 따로 둔다 | worker 컨테이너가 Keeper 수만큼 는다. 계정 용량은 그대로다 |
| 같은 Keeper 의 요청은 함께 실행하지 않는다 | history 결과가 버려지는 대가(§5)를 지금 수준에 묶는다. host 는 요청의 주인을 모른다. `authorize_request` 가 주인을 돌려주게 넓혀야 한다. 이름 순서에서 admission 요청이 앞이면 지금처럼 먼저 반영된다. §6 의 7번으로 버려지는 수를 잰 뒤에 정한다 |
| instance 가 물러날 때 시작 표시가 있는 호출은 끊지 않고 끝까지 받는다 | `cut` 이 거의 생기지 않는다. 결과는 host 에 보관되고 다음 instance 가 전달한다. instance 의 수명과 호출의 수명이 갈라져서 detach 와 선언 변경의 뜻이 바뀐다. 따로 다룬다 |
| `cut` 원본을 운영자가 허가해 푼다 | `RFC-librarian-history-unknown-resolution.md` 의 대상을 host 기록이 `outcome_unknown` 으로 끝난 원본으로 넓히는 일이다. 그 문서의 범위다 |

## 8. 구현 층

| 층 | 내용 | 동작 변화 |
|---|---|---|
| 선행 | #51269(#51250): 시작 표시를 첫 생성 요청 직전에 저장한다 | 첫 생성 요청의 허가를 기다리다 끊긴 요청이 다시 실행된다 |
| L0 | exact 시도가 끝날 때 로그 한 줄 (3.6) | 없음 |
| L1 | 설치 선언의 `max_exact_in_flight` 를 parse 한다 (3.2) | 없음. 이 키를 모르는 빌드는 그 선언을 거절한다 |
| L2 | attach 와 reconcile 이 수를 instance 에 옮긴다 (3.2). `lane_addon_host_walk.ml`, 호출별 취소 표, 예외 규칙 (3.3~3.5) | 키를 2 이상으로 선언한 설치만 |
| 문서 | `RFC-operator-quiz-lane.md` §4.4, `docs/guides/lane-addon-toml.md` 의 설치 필드와 "한 주기" 문단, `docs/guides/keeper-memory-execution.md` 의 keeper-librarian 선언 안내 | — |

시험은 L2 에 붙인다. 부르는 곳이 없는 L1 에는 parse 시험만 둔다.

- 수가 1이면 요청의 시작·전달 순서가 지금과 같다. `exact_output` 이 아닌 요청이 섞인 목록으로 확인한다.
- 수가 n 이면 함께 실행 중인 수가 n 을 넘지 않는다.
- 요청 하나의 실패가 다른 요청을 끊지 않는다.
- 걷는 중에 cycle 을 끝내는 오류가 나도 실행 중인 호출은 끝까지 가고 전달된다.
- fiber 의 예외는 실행 중인 호출이 끝난 뒤에 다시 던져진다.
- exact 요청이 도는 동안 걷기가 그 자리에서 처리하는 요청이 예외를 던져도 실행 중인 호출은 끝까지 가고 전달된다.
- instance 가 물러나면 실행 중인 호출이 모두 취소된다.

## 9. 확인하지 못한 것

- official client 가 호출마다 프로세스 하나를 띄우는지. `keeper_lane_cli_oneshot.ml` 이 `Fusion_official_client.run_with_images` 를 부르는 데까지만 봤다.
- 다계정에서 설치 선언이 계정 서버마다 따로인지. 따로라면 `max_exact_in_flight` 도 서버마다 따로다. `Provider_admission` 은 endpoint identity 로 세니 계정이 다르면 허가도 따로다.
- admission 반영이 Memory 의 revision 이나 facts 를 매번 바꾸는지. 바꾸지 않는 반영은 history 결과를 버리게 하지 않는다.
- 이 키를 모르는 빌드가 다시 떴을 때 그 설치가 붙지 않는지. 거절 문자열까지만 봤다.
- 선언의 필드를 나열하는 자리(3.7)가 전부인지.
- 걷기가 그 자리에서 처리하는 요청이 실제로 어떤 예외를 던지는지.
- CLI slot 의 권한 검사 거절(3.5)이 instance 가 물러나는 중에 `raised` 를 남기는 경합.
- 다른 package 의 요청이 서로 순서에 기대는지(2.3).
- floor step 이 `Pending` 으로 남은 뒤 다음 pass 가 하는 일.
- 도는 cycle 의 실행 중 요청을 Lane Add-ons 화면에 보여 줄지. L0 의 줄로 먼저 잰 뒤에 정한다.
