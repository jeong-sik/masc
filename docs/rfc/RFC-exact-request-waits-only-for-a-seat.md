---
rfc: "exact-request-waits-only-for-a-seat"
title: "Exact 요청은 자리만 기다린다"
status: Draft
created: 2026-11-18
updated: 2026-11-18
author: claude
supersedes: []
superseded_by: null
related: ["host-cycle-runs-exact-requests-side-by-side", "operator-quiz-lane", "exact-lane-waits-for-a-stated-reset", "server-carries-its-exact-worker-packages"]
---

# Exact 요청은 자리만 기다린다

코드 위치는 main `676d9cbeb7d11` 기준이다. 이 RFC 가 병합되고 구현되면 이슈 #52981 이 닫힌다.

## 0. 요약

2026-11-18 운영에서 Librarian 요청은 대부분 GLM slot 에서 답을 받았다.
GLM 계정의 자리 8개는 Keeper 턴과 같이 쓴다.
그 자리가 다 차면 Librarian 요청은 GLM 앞에서 최대 1,200초를 기다린다.
그동안 뒤 slot 인 tinker 와 Ollama 의 자리는 비어 있을 수 있다.

Librarian 이 느린 까닭은 셋이다.

- 요청은 꽉 찬 slot 앞에서 기다린다. 자리가 빈 뒤 slot 으로 가지 않는다(§1.2).
- host 는 운영자가 고른 수(`max_exact_in_flight`)만큼만 요청을 같이 돌린다(§1.4).
- host 는 요청을 바퀴(pass) 단위로 돌린다. 바퀴는 그 안에서 가장 늦은 요청이 끝나야 닫힌다(§1.3).

이 RFC 는 규칙 하나를 세운다.

> Exact 요청은 자리만 기다린다. host 가 고른 수를 기다리지 않고, 다른 요청이 끝나기를 기다리지 않는다.

자리는 binding 이 `max-concurrent` 로 선언한 수다. 한 계정이 한 번에 받는 요청 수를 뜻한다.

이 규칙에서 바뀌는 것이 셋이다.

1. 요청은 slot 을 선언 순서대로 걷다가, 자리가 찬 slot 은 지나친다. 남은 slot 이 모두 차 있으면 그 줄들에 같이 서서 먼저 비는 자리를 받는다. 본문 시간은 생성 요청을 보낼 때부터 센다(§3.1).
2. Exact lane 이 갈 수 있는 slot 은 모두 자리를 선언하고 센다. official client(CLI)도 센다. Keeper 턴과 같이 쓰는 provider 는 Keeper 턴이 먼저 자리를 받게 선언한다(§3.2).
3. host 는 수를 세지 않는다. 목록의 요청을 모두 시작한다. 요청 하나가 전달되거나 새 요청이 들어오면 바로 목록을 다시 읽는다. `max_exact_in_flight` 는 지운다(§3.3).

그러면 Librarian 이 같이 돌리는 요청 수는 Keeper 수를 따라간다.
Librarian 은 Keeper 와 종류(admission, durable)마다 끝나지 않은 원본을 하나만 둔다.
그래서 목록에 있는 요청 수가 곧 일이 남은 Keeper 수다. Librarian 쪽에는 동시 실행 상한이 없다.

바꾸지 않는 것:

- slot 순서, 쉬는 slot 처리(`Runtime_exact_lane_backpressure`), 실패하면 다음 slot 으로 가는 규칙
- CLI slot 은 HTTP slot 이 모두 실패하거나 쉬거나 지나쳐졌을 때만 쓴다. 입력 크기로 거절된 slot 도 실패로 센다. 지금과 같다
- 걷기 영수증의 형식. 지나친 slot 은 거절 사유 `Seats_full` 하나를 더해 적는다
- 원본 규칙, 시작 표시(`Started`)를 쓰는 때
- 한 instance 의 cycle 은 겹치지 않는다. 요청은 cycle 마다 한 번만 시도한다

대가는 §5 에 적는다.

## 1. 지금 일어나는 일 (2026-11-18)

읽기만 하는 script 로 셌다. 기록 내용은 싣지 않는다. 시각은 KST 다.

### 1.1 답한 slot

Librarian lane 의 HTTP slot 은 다섯, CLI slot 은 둘이다. 두 output(admission, durable)이 같은 목록을 쓴다.

11-18 에 답을 받은 Librarian 요청 344개가 마지막에 쓴 slot 이다(요청 기록의 `final.slot`).

| slot | 답 |
|---|---|
| GLM | 217 |
| tinker | 121 |
| Ollama | 6 |

- 목록의 첫 slot 은 월 한도가 다 차서 쉬는 중이다. 다섯째 slot 은 사용 한도로 400 을 돌려준다.
- GLM 은 대부분의 시간대에 시간당 20~27개를 답했다.
- 04시대에 GLM 이 막힌 동안 tinker 혼자 한 시간에 101개를 답했다.
- 판단 하나는 2.6~14.5분이 걸렸다.

### 1.2 꽉 찬 첫 slot 앞에서 기다린다

`Exact_output` 은 slot 을 앞에서부터 하나씩 걷는다(`packages/agent_core/lib/llm_provider/exact_output.ml` 1322~1372행).

- binding 이 `max-concurrent` 를 선언했으면 그 계정의 허가를 기다린다(`Provider_admission.with_admission_until`).
- `body_timeout_s` 가 있으면 허가를 기다리기 전에 `deadline_at = now + body_timeout_s` 를 잡는다(1326행). 기다림과 생성이 한 한도를 같이 쓴다. Librarian lane 의 `exact-body-timeout-s` 는 1,200초다.
- 허가를 못 받은 채 한도가 지나면 `Permit_wait_expired` 로 그 slot 을 끝내고 다음 slot 으로 간다.
- 늦게 허가를 받으면 남은 시간만 생성에 쓴다. 남은 시간 안에 못 끝내면 만든 출력을 버린다(#52981, 11-17 에 GLM 호출 4개·생성 2,580초).
- 다음 slot 에 빈 자리가 있는지는 보지 않는다.

Librarian 은 `Background` 등급으로 줄을 선다(`lib/server/server_lane_addon_exact.ml` 359행).
등급이 순서를 정하는 것은 provider 가 `admission-priority-run-limit` 를 선언했을 때뿐이다. 선언이 없으면 등급과 상관없이 줄이 하나다(`slot_scheduler.ml` 105~110행).
운영 runtime.toml 에는 이 키를 선언한 provider 가 없다. 그래서 GLM 에서 Librarian 과 Keeper 턴은 먼저 선 순서대로 자리를 받는다.

허가 대기는 사건으로 저장된다. 가득 찬 계정을 만난 요청마다 `masc.provider_admission.waited` 가 `agent-core-events` 에 한 줄씩 쓰인다(`lib/provider_admission_events.mli` 1~8행).

- 11-10~11-18 에 70,536건이다.
- glm-coding 에서 Librarian(`Background`) 요청 2,762건이 기다린 뒤 자리를 받았다. 대기 p90 은 458초다.
- 같은 계정에서 Keeper 턴 요청 84건은 자리를 받지 못하고 만료됐다. 51건이 11-17 에 몰렸다.

slot 별 시도 기록으로 본 것은 이렇다.

- 11-18 에 답을 받은 시도 84개 가운데 22개를 기록이 쓰인 시각으로 slot 과 맞췄다.
- tinker 가 답한 12개는 시작부터 끝까지 중앙값 118초가 걸렸다. 그 가운데 1개는 1,218초였다.
- CLI slot 이 답한 1개는 1,764초였다.
- 이 둘은 앞 slot 에서 1,200초를 쓴 뒤 뒤 slot 이 답했다. 허가를 기다린 것인지 생성이 잘린 것인지는 기록이 가르지 않는다.

### 1.3 바퀴가 가장 늦은 요청을 기다린다

host cycle 은 worker 의 요청 목록을 바퀴로 돈다(`lib/lane_addon/lane_addon_runtime.ml` 1457행 `pass`).

- 바퀴는 목록의 exact 요청을 fiber 로 시작한다(`lib/lane_addon/lane_addon_host_walk.ml` 51~55행).
- 목록 끝(빈 page)에 닿으면 돌고 있는 요청이 모두 끝날 때까지 기다린다(82행).
- 전달이 있었으면 그 뒤에 목록을 다시 읽는다(`lane_addon_runtime.ml` 1491행).
- cycle 도중에 Keeper 가 새 요청을 넣으면 `wake_host` 는 cycle 을 하나 더 예약할 뿐이다(601~606행). 도는 cycle 은 그 요청을 보지 않는다.

Librarian 의 다음 요청은 앞 요청의 결과가 반영된 뒤에 생긴다.
그래서 먼저 끝난 Keeper 의 다음 요청은 그 바퀴의 가장 늦은 요청이 끝난 뒤에야 시작된다.

13:40:21 부터 몇 초 사이에 요청 18개가 시작됐다.

- 3개는 2초 안에 결과 미확인으로 끝났다.
- 10개는 57~145초에 답했다.
- 1개는 87초에 provider 오류로 끝났다.
- 4개는 160초째에도 돌다가 13:43:03 에 서버가 멈추면서 끊겼다.

답한 10개의 Keeper 에게 다음 요청이 있어도, 남은 넷이 끝나기 전에는 시작되지 않는다.

### 1.4 수를 사람이 고른다

- `max_exact_in_flight` 는 설치 선언의 키다(`lib/lane_addon/lane_addon_config.ml` 162~166행). 없으면 1이다.
- 운영 값은 11-12 까지 1, 11-17 에 3, 11-18 13:12 에 31 이 됐다.
- 31 로 올린 뒤 31분 동안 시도 34개가 끝났고 21개가 답했다. 시작할 때 같이 돌던 수는 최대 17이었다.
- 이 수는 provider 를 지키지 않는다. provider 쪽 상한은 binding 의 `max-concurrent` 다(같은 RFC §2.4).
- 그래서 운영자는 근거 없이 수를 고른다. 작으면 Keeper 끼리 서로를 기다린다. 크면 CLI slot 에 그만큼 프로세스가 뜬다(§1.5).

### 1.5 CLI slot 은 자리를 세지 않는다

- binding parser 는 모든 binding 에서 `max-concurrent` 를 읽는다(`lib/runtime/runtime_toml_bindings.ml` 106~117행).
- official client binding 에서는 이 값을 쓰는 곳이 없다.
  - Keeper 턴은 official client 실행을 만들 때 이 값을 넘기지 않는다(`lib/runtime/runtime_adapter.ml` 1221~1232행). HTTP 실행만 넘긴다(923행).
  - Exact 의 CLI slot 은 허가 없이 프로세스를 띄운다(`lib/keeper/keeper_lane_cli_oneshot.ml` 400~436행 `run_gated`).
- 그래서 official client binding 에 적은 `max-concurrent` 는 오류 없이 무시된다.
- `admission-priority-run-limit` 는 official client provider 에서 거절된다. 까닭은 "runs as an official client outside account admission" 이다(`lib/runtime/runtime_toml.ml` 605~613행).
- 프로세스 수를 묶는 `Runtime_cli_spawn_gate`(8개)는 Antigravity 실행만 감싼다(`runtime_antigravity.ml` 1138행). Exact 의 Antigravity CLI 실행도 여기에 든다.
- 운영 runtime.toml 에서 `max-concurrent` 를 적은 official client binding 은 없다.

## 2. 규칙

> Exact 요청은 자리만 기다린다. host 가 고른 수를 기다리지 않고, 다른 요청이 끝나기를 기다리지 않는다.

- 자리는 binding 이 `max-concurrent` 로 선언한 수다. HTTP 는 endpoint identity(종류, base URL, API key)마다, official client 는 provider(계정)마다 센다.
- host 의 수가 없어지면 Exact 요청을 묶는 것은 자리뿐이다. CLI binding 은 `max-concurrent` 를 선언한다. HTTP binding 은 선언하지 않으면 provider 의 429 가 묶는다(§3.2).
- Keeper 턴은 허가를 한도 안에서 기다린다(`complete.ml` 316행·693행). 줄에서 뒤로 밀리면 허가 시간 초과로 실패한다(§1.2 의 84건).
- `admission-priority-run-limit` 는 이것을 막아 주지 않는다. 한도는 준 자리 수를 세고, 자리를 쥔 시간은 세지 않는다(`slot_scheduler.mli` 20~29행).
  - GLM 에서 Librarian 호출 하나는 Keeper 턴 호출보다 자리를 약 14배 오래 쥔다(413초 대 29.5초).
  - 그래서 이 비보다 작은 한도는 선언이 없을 때보다 Keeper 턴을 오래 기다리게 한다.
  - 7일 재생(모형)에서 한도 1 이면 900초 넘게 기다린 GLM Keeper 턴 호출이 1,228건이다. 선언이 없으면 0건이다. 이 값은 tinker 4자리가 든 lane 에서 모든 slot 을 GLM 속도로 둔 것이다.
  - Keeper 턴과 계정을 나누지 않는 slot(tinker)이 lane 에 없으면 선언이 없어도 Keeper 턴이 기다린다. 같은 재생에서 GLM 8 + ollama 4 lane 은 900초 넘게 기다린 Keeper 턴 호출이 GLM 283건, ollama 1,189건이다.
  - 이 RFC 는 이 키를 요구하지 않는다. 선언과 값은 운영자가 계정마다 잰 시간 비를 보고 정한다.
- 쉬는 slot 은 provider 가 밝힌 때까지 부르지 않는다. 지금과 같다.
- HTTP slot 과 CLI slot 은 층이 다르다. CLI slot 은 HTTP slot 이 모두 실패하거나 쉬거나 지나쳐졌을 때만 쓴다. HTTP 자리가 꽉 찬 것만으로는 CLI 로 가지 않는다.
  - HTTP 자리는 앞 요청의 본문 한도 안에 빈다. CLI 는 프로세스를 띄우고, 구독 한도를 Keeper 턴과 나눠 쓴다.

## 3. 설계

### 3.1 slot 고르기

```text
walk(slots):   # 선언 순서. 쉬는 slot 과 크기로 거절된 slot 은 빠진다 (지금과 같다)
  i ← 첫 slot
  while i 가 있다:
    j ← i 부터 뒤로, 기다리지 않고 자리를 받을 수 있는 첫 slot
    if j 가 없다:
      i 부터 끝까지 모든 slot 의 줄에 같이 선다
      j ← 처음 자리를 준 slot
    i 부터 j 앞까지는 「자리가 차서 지나침」으로 적는다
    j 에서 입력 재기와 생성을 그 자리 하나로 한다
      재기와 생성은 각자 요청에 실린 본문 한도를 쓴다. 한도는 요청을 보낼 때부터 센다
    답이면 끝
    실패면 i ← j 다음
```

- 「기다리지 않고 받을 수 있다」는 빈 자리가 있고, 그 계정의 줄에 앞선 요청이 없다는 뜻이다. 줄에 선 요청을 앞지르지 않는다.
- 지나친 slot 은 그 요청에서 다시 보지 않는다. 실패한 slot 과 같다. 그래서 방문은 지금처럼 선언 순서대로 하나씩 간다.
  - 걷기 영수증은 방문 i 가 선언된 i 번째 후보이고, 실패 다음 방문이 바로 다음 번호이기를 요구한다(`lib/keeper/keeper_exact_walk_receipt.ml` 250~273행). 원본은 영수증을 저장하고 다시 읽는다(451~458행). 순서를 바꾸면 저장된 원본을 읽을 수 없다.
  - 지나침은 거절 사유 `Seats_full` 로 적는다. `Exact_output.candidate_rejection_disposition` 과 `Keeper_exact_walk_failure.local_rejection` 에 variant 하나를 더한다. 영수증 version 은 그대로다.
- 걷기 전부터 쉬던 slot 은 지금처럼 걷기에서 빠지고, 호출자가 `Runtime_exact_lane_backpressure.order` 로 안다. 기다리는 사이 쉬기 시작한 slot 이 자리를 주면 그 slot 을 부른다. Agent-Core 는 쉼을 모른다. 그 slot 이 거절하면 지금처럼 다음 slot 으로 간다. 받는 순간 쉼을 다시 보는 일은 §9 에 남긴다.
- `Seats_full` 은 provider 가 새로 한 말이 아니다. backpressure 는 이것으로 slot 을 쉬게 하지 않는다.
- 줄에 선 채 취소되면 걷기는 결과를 돌려주지 않는다. 취소는 Eio 취소로 나간다. 지금과 같다.
- 여러 줄에 같이 서는 일은 scheduler 를 고치지 않고 `Provider_admission.take_first_seat` 의 경주로 한다(#52995).
  - 계정마다 보통의 대기자 하나를 세우고 `Eio.Fiber.any` 로 기다린다. 먼저 자리를 받은 대기자가 `Atomic.compare_and_set` 으로 이긴다.
  - 늦게 자리를 받은 대기자는 그 자리를 바로 돌려주고 취소를 기다린다. 그래서 `Fiber.any` 가 뒤 결과를 버려도 자리가 새지 않는다. 그 사이 돌려준 자리는 그 계정 줄의 다음 요청에게 간다.
  - 두 계정이 거의 같이 비면 먼저 깨어난 쪽이 이긴다. 선언 순서로 고르지 않는다.
  - 받은 자리는 slot j 의 단계가 끝날 때까지 들고 간다. 걷기가 j 에 닿기 전에 끝나면 걷기가 돌려준다.
- 줄에서 나오는 길은 둘이다. 자리를 받거나 취소된다. 따로 고른 대기 한도는 두지 않는다. 자리를 쥔 요청이 끝나면 자리는 빈다(§9).
- 입력을 재는 요청과 생성 요청이 같은 자리를 쓴다. 지금은 한 slot 에서 줄을 두 번 선다(`exact_output_flow_admission.ml` 286~324행).
- 자리 대기를 함께 재던 바깥 한도는 없어진다. 재기와 생성 요청은 각자 본문 한도를 싣고 가므로, 한도가 보낼 때부터 센다.
- Exact flow 의 `Permit_wait_expired`, `Permit_granted_as_deadline_passed` 와 `*_admission_timed_out` 생성자는 지운다. Keeper 턴의 `complete.ml`·`prepared_completion_request.ml` 는 `Provider_admission` 의 같은 이름 값을 계속 쓴다.
- 시작 표시는 지금처럼 첫 생성 요청을 보내기 직전에 쓴다. 줄에서 취소된 요청에는 표시가 없다.
- CLI 층 안에서도 같은 규칙으로 고른다. 자리는 §3.2 가 센다.

이 걷기는 `execute_flow_once` 를 쓰는 다른 Exact 소비자에도 같이 걸린다. `hitl_summary_worker`, `keeper_board_attention_exact_flow`, `keeper_librarian_runtime`, `server_lane_addon_exact` 다.

### 3.2 자리를 선언하고 센다

HTTP slot 의 자리:

- `max-concurrent` 를 선언하지 않은 HTTP binding 은 masc 가 자리를 세지 않는다는 뜻이다. 지금과 같다. 걷기는 그 slot 을 늘 빈 것으로 본다. 넘치면 provider 가 429 로 거절하고, backpressure 가 그 slot 을 쉬게 한다.
- 그래서 HTTP slot 에는 선언을 요구하지 않는다. 운영 runtime.toml 의 Exact lane HTTP slot 은 2026-11-18 에 모두 `max-concurrent` 를 선언했다(GLM 8, OpenRouter 2, 나머지 4).
- setup 은 계정의 자리 수를 모른다. 요구하면 새로 설치한 서버의 Exact lane 이 비게 된다.

CLI slot 의 자리(CLI 층에서 요구한다. 없으면 로드 오류다):

- Exact lane(`addon_exact_lanes`, `exact_output_lanes`)의 `cli_slots` 가 가리키는 binding 은 `max-concurrent` 를 선언한다. official client 하나는 이 기계에서 뜨는 프로세스다. 넘쳐도 멈춰 주는 provider 가 없다.

Keeper 턴과 같이 쓰는 provider:

- 로드 요구를 두지 않는다. `admission-priority-run-limit` 는 준 자리 수만 세므로, 값이 작으면 선언이 없을 때보다 Keeper 턴이 더 기다린다(§2).

official client 의 자리:

- official client binding 이 `max-concurrent` 를 선언하면 그 provider(계정)의 실행이 모두 자리를 센다. Exact 의 CLI slot 과 Keeper 턴이 같이 센다.
- 한 계정의 binding 들이 서로 다른 값을 적으면 로드 오류다. HTTP 의 `allowances_of_configs` 와 같은 규칙이다.
- official client provider 도 `admission-priority-run-limit` 를 선언할 수 있다. 그 provider 의 binding 하나 이상이 `max-concurrent` 를 선언했을 때다. HTTP provider 와 같은 규칙이다.
- Keeper 턴의 watchdog 은 자리를 기다리는 동안을 멈춤으로 세지 않는다. HTTP 허가 대기와 같은 신호(`permit_wait`)를 official client 의 자리 대기에도 쓴다(`keeper_turn_driver_try_provider.ml` 855~862행).

설정을 만드는 쪽:

- setup 과 lane 편집기는 CLI slot 을 쓸 수 있다(`lib/runtime/runtime.ml` 3360~3373행, `lib/runtime/runtime_lane_edit.ml` 275~277행). 그 binding 의 자리 수를 누가 정하는지는 CLI 층에서 정한다(§9).
- `cli_slots` 를 선언하는 시험 fixture(약 18개 파일)도 CLI 층에서 고친다.

### 3.3 host 는 수를 세지 않는다

`RFC-operator-quiz-lane.md` §4.4 "One cycle" 의 2번과 3번을 이렇게 바꾼다.

> 2. For each request in order: deliver a final result the host already holds, or try the work once and deliver its result if it is final.
>    - An `exact_output` request runs beside the walk. The walk starts every `exact_output` request it lists.
>    - An `ask` is recorded once per request id. Its result is delivered only when the operator has answered it or the package has withdrawn it.
>    - A request whose attempt was not final stays undelivered until the next trigger. It is tried at most once per cycle, so it cannot keep a cycle running.
> 3. A listing leaves out the requests this cycle has started. List again when a request ends with a delivery or a host event arrives, without waiting for the requests still running. The cycle ends when no request is running and nothing was delivered and no host event arrived since the last listing.

```text
cycle():
  loop:
    목록을 읽는다. host 는 이번 cycle 에 시작한 id 를 넘기고, worker 는 그것을 빼고 내놓는다
    걷는다 (지금처럼 page 단위)
      전달한 id 가 나오면 걷기를 멈춘다 (Relisted_delivered_request)
      exact_output 이 아니면 그 자리에서 처리한다
      exact_output 이면 fiber 하나로 시작한다
    기다린다:
      마지막 목록 뒤로 전달이나 host 사건이 있었다 → 다시 loop
      돌던 요청이 없다 → cycle 끝
  걷기를 멈춘 오류가 있으면 새 요청을 시작하지 않고, 돌던 요청이 끝난 뒤 그 오류로 끝낸다
```

- host 사건은 지금 `wake_host` 를 부르는 일이다. Keeper 가 새 요청을 넣는 도구 호출(`lane_addon_runtime.ml` 2605행)과 lane 설정 바뀜이 여기에 든다. cycle 도중이면 cycle 을 하나 더 예약하지 않고 그 cycle 이 목록을 다시 읽는다.
- 목록에서 이번 cycle 에 시작한 id 를 빼므로, 돌고 있는 요청은 목록에 나오지 않는다. 그러니 전달한 id 가 목록에 나오면 worker 가 약속을 어긴 것이다. 지금처럼 멈춘다.
- 이 빼기는 worker 목록 약속을 바꾼다(`addons/exact_worker.py` 486~503행). 그래서 `exact_protocol` 을 올린다. 서버가 싣는 package 는 같은 판에서 같이 오른다.
  - 빼지 않으면 다시 읽을 때마다 돌고 있는 요청의 본문까지 worker 연결 하나로 다시 받는다. Librarian 요청 62개면 한 번에 수십 MB 다.
- 같이 도는 요청 수는 목록이 정한다. 목록의 요청은 host 원본이 있어야 실행된다(`Lane_addon_exact.execution_authority`). 원본이 없는 요청은 `Not_allowed` 로 끝난다.
- Librarian 은 Keeper·종류마다 끝나지 않은 원본을 하나만 둔다(`keeper_librarian_durable_execution.ml` 596행·696~707행, `keeper_librarian_admission_owner.ml` 621~625행). 그래서 같이 도는 요청은 Keeper 수의 두 배를 넘지 않는다. 운영 Keeper 31명이면 62개다.
- 요청 본문은 하나에 4 MiB(`max_reply_bytes`)를 넘지 않는다. 62개면 248 MiB 다.
- provider 에 나가는 요청 수는 §3.1·§3.2 의 자리가 묶는다.
- 취소 표와 예외 규칙(같은 RFC §3.4·§3.5)은 그대로다.

지우는 것(hard cut):

- 설치 선언의 `max_exact_in_flight` 키. 이 키가 있는 선언은 `unknown declaration field` 로 거절된다.
- `Lane_addon_config.exact_in_flight`, `one_exact_at_a_time`, instance 의 `max_exact_in_flight` 칸, `Lane_addon_host_walk.walk` 의 `max_in_flight` 인자.
- 이 키를 설명하는 문서 문장(§6).

운영 선언에서 이 키를 쓰는 곳은 `keeper-librarian.toml` 하나다. 그 줄은 새 빌드로 재시작하기 직전, 서버가 멈춘 동안 지운다. 서버가 도는 동안 지우면 옛 빌드가 다음 maintenance pulse 에 키 없는 선언을 읽고 1로 돈다.

### 3.4 Librarian 재설계와의 관계

Librarian 을 host cycle 밖으로 옮기는 재설계가 따로 진행 중이다.

- 옮기기 전까지 Librarian 은 §3.3 의 host cycle 로 돈다.
- 옮긴 뒤에도 Librarian 의 질문은 §3.1 의 걷기로 자리를 잡는다. Librarian 쪽에는 동시 실행 상한이 없다. Keeper 마다 질문이 하나라서 같이 도는 질문은 Keeper 수를 넘지 않는다.
- §3.3 은 다른 Lane Add-on(curator, candle, lesson, quiz, hitl-auto-judge)에 남는다.

## 4. 틱으로 따라가 보기

Librarian lane 의 HTTP slot 이 선언 순서로 A(자리 8, Keeper 턴과 같이 씀), B(자리 4), C(자리 4)라고 하자.

### 4.1 A 가 꽉 찼다

- A 의 자리 8개를 Keeper 턴이 쥐고 있다. B 에는 빈 자리가 있다.
- 요청은 A 를 `Seats_full` 로 지나치고 B 의 자리를 받는다.
- B 가 실패하면 C 로 간다. A 는 그 사이 비어도 다시 보지 않는다.

### 4.2 셋 다 꽉 찼다

- 요청은 A, B, C 의 줄에 같이 선다.
- 200초 뒤 C 의 자리 하나가 빈다. C 줄의 대기자가 이긴다. A, B 줄의 대기자는 취소되어 줄에서 나온다.
- 영수증에는 A·B 가 `Seats_full`, C 가 방문으로 적힌다.
- A 와 C 가 거의 같이 비면 먼저 깨어난 대기자가 이긴다. 진 쪽은 받은 자리를 바로 돌려주고, 그 자리는 그 줄의 다음 요청에게 간다.

### 4.3 기다리는 사이 B 가 쉬기 시작한다

- 다른 요청이 B 에서 429 와 재개 시각을 받았다. B 는 그 시각까지 쉰다.
- 이 요청이 B 의 자리를 먼저 받으면 B 를 부른다. B 가 다시 429 로 거절하면 C 로 간다. C 는 그 사이 줄에서 나왔으므로 다시 선다.
- 받는 순간 쉼을 보고 B 를 지나치는 일은 이 RFC 의 걷기 층에 없다. Agent-Core 는 쉼을 모르고, 쉼은 masc 의 backpressure 가 안다(§9).

### 4.4 HTTP 가 모두 막혔다

- A, B, C 가 모두 실패하거나 쉬면 CLI 층으로 간다. CLI 층에서도 같은 규칙으로 자리를 고른다.
- CLI 자리가 모두 차 있으면 그 줄에 선다. 프로세스는 자리 수보다 많이 뜨지 않는다.

### 4.5 Keeper 31명의 요청이 한꺼번에 있다

- 목록에 요청이 40개 있다. host 는 40개를 모두 시작한다.
- 빈 자리만큼 바로 받는다. 나머지는 줄에 선다.
- Keeper K 의 요청이 답하고 전달된다. host 는 바로 목록을 다시 읽는다. K 의 다음 요청은 결과가 반영된 뒤 도구 호출로 들어온다. 그 호출이 host 사건이라 host 는 목록을 다시 읽고 그 요청을 시작한다. 다른 39개가 끝나기를 기다리지 않는다.

### 4.6 줄에 선 채 instance 가 물러난다

- host 가 그 호출을 취소한다. 요청은 모든 줄에서 나온다.
- 보낸 것이 없어 시작 표시가 없다. revision 이 같은 instance 가 다시 붙으면 그 요청을 다시 실행한다.

## 5. 대가

- 뒤 slot 이 지금보다 많이 불린다. tinker 처럼 쓴 만큼 돈을 내는 slot 은 비용이 는다. 비싼 slot 은 운영자가 뒤로 옮기거나 목록에서 뺀다.
- 지나친 slot 은 그 요청에서 다시 보지 않는다. 뒤 slot 이 실패한 사이 앞 slot 이 비어도 쓰지 않는다. 영수증 형식을 지키는 값이다(§8).
- 한 요청이 여러 줄에 같이 서므로, 계정마다 보이는 줄 길이가 실제로 기다리는 요청 수보다 길다. 자리 화면을 읽는 쪽은 이것을 알아야 한다.
- Exact lane 의 CLI binding 이 `max-concurrent` 를 선언하지 않으면 L3 부터 runtime.toml 이 로드되지 않는다.
- 매번 실패하는 slot 은 자리가 늘 비어 있어서 걷기가 그리로 간다. 앞 slot 이 꽉 찬 요청은 줄에 서지 않고, 그 slot 에서 1초 만에 실패한 뒤 CLI 층으로 간다.
  - 11-18 운영 Librarian lane 의 마지막 HTTP slot 이 그렇다. 모든 호출에 사용량 한도를 맨 400 으로 답했다.
  - 맨 400 은 slot 탓인지 요청 탓인지 말해 주지 않는다. 그래서 masc 는 이 slot 을 쉬게 하지 않는다. 이런 slot 은 운영자가 lane 에서 뺀다(§7).
- 선언 없는 HTTP slot 은 걷기가 늘 빈 것으로 본다. 그 slot 이 앞에 있으면 넘친 요청은 provider 의 429 를 받은 뒤에야 다음 slot 으로 간다.
- official client binding 에 `max-concurrent` 를 적으면 그 계정의 Keeper 턴도 자리를 기다린다. 지금은 그 값이 무시된다.
- `Seats_full` variant 를 모르는 옛 빌드는 새 영수증을 읽지 못한다. 빌드를 되돌리면 그 사이 생긴 원본을 읽지 못한다.
- cycle 이 오래 열린다. 요청이 끊이지 않거나, 요청이 자리를 오래 기다리면 cycle 이 닫히지 않는다. 그동안 그 instance 의 action 과 observation 은 기다린다. quiz 의 예약된 `compose` action 도 여기에 든다. keeper-librarian 은 source 가 없어 observation 이 비어 있다.
- 결과가 final 이 아니었던 요청은 다음 cycle 에 다시 시도한다. cycle 이 오래 열리면 그만큼 늦게 다시 시도된다. 지금과 같은 성질이다.
- instance 가 물러날 때 끊기는 호출이 많아진다. 시작 표시가 있는 호출(자리를 쥔 것, 앞 slot 에서 보낸 뒤 뒤 slot 줄에 선 것)은 `cut` 이 된다. `cut` 원본은 선언 교체로만 풀린다(`keeper_librarian_admission_owner.ml` 288~291행, `keeper_librarian_durable_owner.ml` 440~446행). 지금은 31개, 이 RFC 뒤에는 목록 수(62개)까지다. §7 의 L4 조건 (b) 가 이것을 다룬다.

## 6. 바뀌는 계약과 문서

- `docs/rfc/RFC-operator-quiz-lane.md` §4.4 (§3.3 의 문장)
- `docs/guides/lane-addon-toml.md` 38행·454행, `docs/guides/keeper-memory-execution.md` 223행
- `packages/agent_core/lib/llm_provider/provider_admission.mli` 의 `with_admission_until` 설명, `slot_scheduler.mli`
- `lib/runtime/runtime_toml_bindings.ml` 의 `max-concurrent` 주석, `lib/runtime/runtime_toml.ml` 의 official client 거절 문구
- worker 목록 약속(`exact_protocol`)을 적은 문서

## 7. 구현 층

native stack 으로 올린다. 층마다 Draft PR 이다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | 자리 API: `Slot_scheduler.try_acquire`·`acquire_held`·`release`, `Provider_admission.take_first_seat`·`release_seat` (#52995) | 빈 첫 계정 즉시. 선언 없는 계정 즉시. 모두 꽉 참 → 모든 줄에 서고 처음 받은 자리를 쥠. 뒤에 받은 자리는 돌려줌. 취소 → 줄에 남는 것·새는 자리 없음. 두 번 돌려줘도 한 번 |
| L2 | §3.1 걷기(Agent-Core 와 Exact 소비자 넷), `Seats_full`, 재기·생성이 자리 하나, 바깥 한도 삭제, Exact flow 의 `*_admission_timed_out` 삭제. `Context_overflow` 같은 결과 타입은 건드리지 않는다 | 시험: A 꽉 참·B 빔 → B 만 보냄, A 는 `Seats_full`, A 시도 없음. 모두 꽉 참 → 먼저 빈 B 에서 보냄. 혼자인 slot 이 본문 한도의 두 배를 기다려도 답한다(#52981). 영수증 검사 통과 |
| L3 | §3.2 CLI 자리와 그 로드 요구, official client run limit 거절 완화, watchdog 의 자리 대기, `cli_slots` fixture | CLI 층에서 자리 수를 넘는 프로세스가 뜨지 않는 시험. 선언 없는 CLI slot 거절. 자리를 기다리는 Keeper 턴을 watchdog 이 멈춤으로 세지 않는 시험 |
| L4 | §3.3 host 가 수를 세지 않음, 다시 읽는 조건, 목록 빼기와 `exact_protocol`, 키 삭제 | host walk 시험: 전달 하나 뒤 나머지를 기다리지 않고 다시 읽는다. cycle 도중 host 사건이 다시 읽게 한다. 마지막 요청이 전달 없이 끝나면 cycle 이 끝난다. 돌고 있는 id 는 목록에 없다. 키가 있는 선언은 거절 |
| L5 | §6 문서 | 문서 안의 `max_exact_in_flight` 가 0개 |

순서의 까닭:

- L1·L2 가 먼저다. 지금 `max_exact_in_flight` 31 이 동시 요청을 막고 있어서, 걷기만 들어가도 줄이 늘지 않는다. 꽉 찬 첫 slot 앞의 기다림과 #52981 은 이 두 층으로 없어진다.
- L4 를 L2 보다 먼저 내면 늘어난 요청이 꽉 찬 첫 slot 앞에 줄만 선다.
- L4 를 L3 보다 먼저 내면 HTTP slot 이 모두 막힐 때 목록 수만큼 CLI 프로세스가 뜬다.

L4 를 내기 전에 확인할 것 둘:

- (a) curator, candle, lesson, quiz, hitl-auto-judge 의 요청이 같은 목록 안에서 순서에 기대는지 package 마다 확인하고 결과를 PR 에 적는다. 이 package 들은 키가 없어서 지금 하나씩 돈다. lesson 은 장면 요청이 서로 기대지 않는다(`RFC-operator-lesson-lane.md` §4.3).
- (b) `cut` 원본이 선언 교체 없이 풀린다. Librarian 재설계의 전환 층이 먼저 들어가 원본이 없어지거나, `cut` 을 `interrupted` 처럼 정리하는 수리가 먼저 들어간다.

배포 때 운영자가 할 일:

- L1 은 운영자가 할 일이 없다.
- L2 를 설치하기 전: Exact lane 에서 모든 호출이 실패하는 slot 을 뺀다(§5). 11-18 Librarian lane 에서는 마지막 HTTP slot 이다.
- L3 을 설치하기 전: Exact lane 이 가리키는 CLI binding 에 `max-concurrent` 를 적는다(Librarian·candle lane 포함).
- L4 를 설치하기 전: 서버를 멈춘 뒤 `keeper-librarian.toml` 의 `max_exact_in_flight` 줄을 지운다.
- 세 층의 changelog 에 이 일을 `Upgrade notes` 로 적는다.

## 8. 대안

| 대안 | 고르지 않은 까닭 |
|---|---|
| 수를 두고, 값을 Keeper 수로 자동으로 맞춘다 | 여전히 host 가 센 수다. 바퀴가 가장 늦은 요청을 기다리는 일은 그대로다. host 가 Keeper 를 알아야 한다 |
| host 가 「Keeper 마다 하나」를 센다 | host 요청에는 만든 Keeper 가 없다(`Lane_addon_exact.request`). Librarian 원본 규칙이 이미 그것을 지킨다 |
| 지나친 slot 을 나중에 다시 본다(방문 순서를 바꾼다) | 영수증이 선언 순서 방문을 요구한다. 영수증을 바꾸면 저장된 원본을 읽지 못해 원본 저장소를 새로 시작해야 한다 |
| HTTP 자리가 꽉 차면 CLI 로도 넘긴다 | CLI 는 프로세스와 구독 한도를 쓴다. HTTP 자리는 본문 한도 안에 빈다. §2 |
| 기다림에 따로 한도를 둔다 | 고른 수다. 여러 줄에 같이 서면 기다림은 처음 비는 자리에서 끝난다 |
| 꽉 찬 slot 을 지금처럼 기다리고 본문 한도만 허가 뒤로 옮긴다(#52981 만 고침) | 잘린 생성은 사라진다. 꽉 찬 첫 slot 앞의 기다림은 남는다 |

## 9. 확인하지 못한 것

- L2 배포 전후의 자리 대기. `masc.provider_admission.waited` 사건(§1.2)과 영수증의 `Seats_full` 수로 잰다. L2 뒤에는 한 요청이 여러 줄에 서므로, 사건 수는 요청 수가 아니라 줄 수다.
- 기다리는 사이 쉬기 시작한 slot. L2 는 그 slot 이 자리를 주면 부르고, 거절을 받은 뒤 다음으로 간다. 받는 순간 쉼을 보고 지나치려면 masc 의 backpressure 를 걷기에 넘겨야 한다. 그 값이 provider 호출 하나를 아끼는지 재고 정한다.
- setup 과 lane 편집기가 CLI slot 의 자리 수를 어디서 얻는지. L3 에서 정한다.
- 자리를 쥔 호출이 모두 한도 안에 끝나는지. Exact 호출은 본문 한도가 있다. `body_timeout_s` 가 없는 HTTP binding 과 Keeper 턴의 호출이 자리를 얼마나 오래 쥐는지는 재지 않았다. 자리가 오래 비지 않으면 줄의 요청은 그동안 기다린다.
- durable output 의 floor step 요청도 Keeper 마다 하나인지. history 와 admission 은 확인했다.
- §7 L4 조건 (a) 의 package 별 결과.
