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

1. 요청은 자리가 빈 slot 가운데 앞의 것을 쓴다. 빈 자리가 없으면 먼저 비는 자리를 쓴다. 본문 시간은 자리를 받은 때부터 센다(§3.1).
2. official client slot(CLI)도 binding 의 `max-concurrent` 로 자리를 센다(§3.2).
3. host 는 수를 세지 않는다. 목록의 요청을 모두 시작한다. 하나가 끝나면 바로 목록을 다시 읽는다. `max_exact_in_flight` 는 지운다(§3.3).

그러면 Librarian 이 같이 돌리는 요청 수는 Keeper 수를 따라간다.
Librarian 은 Keeper 와 종류(admission, durable)마다 끝나지 않은 원본을 하나만 둔다.
그래서 목록에 있는 요청 수가 곧 일이 남은 Keeper 수다.

바꾸지 않는 것:

- slot 순서, 쉬는 slot 처리(`Runtime_exact_lane_backpressure`), 실패하면 다음 slot 으로 가는 규칙
- CLI slot 은 HTTP slot 이 모두 실패하거나 쉴 때만 쓴다
- 요청 기록 형식, 원본 규칙, 시작 표시(`Started`)를 쓰는 때
- 한 instance 의 cycle 은 겹치지 않는다. 요청은 cycle 마다 한 번만 시도한다
- Keeper 턴이 HTTP 계정의 허가를 기다리는 방식

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
- 허가를 기다리기 전에 `deadline_at = now + body_timeout_s` 를 잡는다(1326행). 기다림과 생성이 한 한도를 같이 쓴다. Librarian lane 의 `exact-body-timeout-s` 는 1,200초다.
- 허가를 못 받은 채 한도가 지나면 `Permit_wait_expired` 로 그 slot 을 끝내고 다음 slot 으로 간다.
- 늦게 허가를 받으면 남은 시간만 생성에 쓴다. 남은 시간 안에 못 끝내면 만든 출력을 버린다(#52981, 11-17 에 GLM 호출 4개·생성 2,580초).
- 다음 slot 에 빈 자리가 있는지는 보지 않는다.

Librarian 은 `Background` 등급으로 줄을 선다(`lib/server/server_lane_addon_exact.ml` 359행). Keeper 턴이 GLM 을 쓰는 동안 Librarian 은 그 뒤에 선다.

허가 대기는 저장되지 않는다. 이벤트 `masc.provider_admission.waited` 는 화면으로만 나간다. 그래서 몇 개가 기다렸는지는 세지 못했다(§9). 간접 근거는 이렇다.

- 11-18 에 답을 받은 시도 84개 가운데 22개를 기록이 쓰인 시각으로 slot 과 맞췄다.
- tinker 가 답한 12개는 시작부터 끝까지 중앙값 118초가 걸렸다. 그 가운데 1개는 1,218초였다.
- CLI slot 이 답한 1개는 1,764초였다.
- 이 둘은 앞 slot 에서 1,200초를 쓴 뒤 뒤 slot 이 답했다. 허가를 기다린 것인지 생성이 잘린 것인지는 기록이 가르지 않는다.

### 1.3 바퀴가 가장 늦은 요청을 기다린다

host cycle 은 worker 의 요청 목록을 바퀴로 돈다(`lib/lane_addon/lane_addon_runtime.ml` 1457행 `pass`).

- 바퀴는 목록의 exact 요청을 fiber 로 시작한다(`lib/lane_addon/lane_addon_host_walk.ml` 54행).
- 목록을 다 걸으면 돌고 있는 요청이 모두 끝날 때까지 기다린다(82행).
- 전달이 있었으면 그 뒤에 목록을 다시 읽는다.

Librarian 의 다음 요청은 앞 요청의 결과가 반영된 뒤에 생긴다(`RFC-host-cycle-runs-exact-requests-side-by-side.md` §2.3).
바퀴는 목록 끝(빈 page)에 닿은 뒤로는 목록을 다시 읽지 않는다.
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
  - Keeper 턴은 official client 실행을 만들 때 이 값을 넘기지 않는다(`lib/runtime/runtime_adapter.ml` 1221행).
  - Exact 의 CLI slot 은 허가 없이 프로세스를 띄운다(`server_lane_addon_exact.ml` 234~247행, `lib/keeper/keeper_lane_cli_oneshot.ml` 475행).
- 그래서 official client binding 에 적은 `max-concurrent` 는 오류 없이 무시된다.
- `admission-priority-run-limit` 는 official client provider 에서 거절된다. 까닭은 "runs as an official client outside account admission" 이다(`lib/runtime/runtime_toml.ml` 605~613행).
- 프로세스 수를 묶는 `Runtime_cli_spawn_gate`(8개)는 Antigravity 턴만 쓴다.
- 운영 runtime.toml 에서 `max-concurrent` 를 적은 official client binding 은 없다.

## 2. 규칙

> Exact 요청은 자리만 기다린다. host 가 고른 수를 기다리지 않고, 다른 요청이 끝나기를 기다리지 않는다.

- 자리는 binding 이 `max-concurrent` 로 선언한 수다. HTTP 는 endpoint identity(종류, base URL, API key)마다, official client 는 provider(계정)마다 센다.
- `max-concurrent` 를 선언하지 않은 HTTP binding 은 자리를 세지 않는다. 지금과 같다.
- 쉬는 slot 은 provider 가 밝힌 때까지 부르지 않는다. 지금과 같다.
- HTTP slot 과 CLI slot 은 층이 다르다. CLI slot 은 HTTP slot 이 모두 실패하거나 쉴 때만 쓴다. HTTP 자리가 꽉 찬 것만으로는 CLI 로 가지 않는다.
  - HTTP 자리는 앞 요청의 본문 한도 안에 빈다. CLI 는 프로세스를 띄우고, 구독 한도를 Keeper 턴과 나눠 쓴다.

## 3. 설계

### 3.1 slot 고르기

```text
walk(slots):   # 쉬는 slot 과 크기로 거절된 slot 이 빠진 순서. 지금과 같다
  남은 ← slots
  while 남은 이 비어 있지 않다:
    자리 ← 남은 slot 가운데, 기다리지 않고 받을 수 있는 첫 자리
    if 자리가 없다:
      남은 모든 slot 의 줄에 같이 선다
      자리 ← 처음 받은 자리 (같은 때 둘 이상이면 앞 slot)
      나머지 줄에서 나온다 (받은 자리가 있으면 바로 돌려준다)
    그 slot 에서 입력 재기와 생성을 그 자리 하나로 한다
    본문 한도는 자리를 받은 때부터 센다
    답이면 끝
    실패면 남은 에서 그 slot 을 뺀다
```

- 「기다리지 않고 받을 수 있다」는 빈 자리가 있고, 그 계정의 줄에 앞선 요청이 없다는 뜻이다. 줄에 선 요청을 앞지르지 않는다.
- 자리를 세지 않는 slot 은 늘 받을 수 있는 slot 이다.
- 줄은 지금처럼 계정마다 하나다. 등급 순서(`admission-priority-run-limit`)도 그대로다. 한 요청이 여러 줄에 같이 설 뿐이다.
- 줄에서 나오는 길은 둘이다. 자리를 받거나 취소된다. 따로 고른 대기 한도는 두지 않는다. 자리를 쥔 요청이 끝나면 자리는 빈다(§9).
- 입력을 재는 요청과 생성 요청이 같은 자리를 쓴다. 지금은 한 slot 에서 줄을 두 번 선다(`exact_output_flow_admission.ml` 287~310행).
- `Permit_wait_expired` 와 `Permit_granted_as_deadline_passed` 는 지운다. 이 둘이 나올 길이 없어진다.
- 시작 표시는 지금처럼 첫 생성 요청을 보내기 직전에 쓴다. 줄에서 취소된 요청에는 표시가 없다.
- 여러 줄에 같이 서는 일은 `Provider_admission` 에 새 함수로 둔다. 각 줄의 대기는 `Slot_scheduler.with_permit` 이 취소돼도 자리를 새지 않게 지킨다. 새 함수는 그 대기 여럿 가운데 처음 끝난 것을 고른다.
- CLI 층 안에서도 같은 규칙으로 고른다. 자리는 §3.2 가 센다.

Keeper 턴의 HTTP 호출(`complete.ml`)은 이 RFC 가 바꾸지 않는다.

### 3.2 official client 의 자리

- official client binding 이 `max-concurrent` 를 선언하면 그 provider(계정)의 실행이 모두 자리를 센다. Exact 의 CLI slot 과 Keeper 턴이 같이 센다.
  - 한 계정의 binding 들이 서로 다른 값을 적으면 로드 오류다. HTTP 의 `allowances_of_configs` 와 같은 규칙이다.
- Exact lane 의 `cli_slots` 가 가리키는 binding 은 `max-concurrent` 를 선언해야 한다. 없으면 runtime.toml 로드 오류다.
  - HTTP 요청 하나는 연결 하나다. 넘치면 provider 가 429 로 멈춘다. official client 하나는 이 기계에서 뜨는 프로세스다. 넘쳐도 멈춰 주는 쪽이 없다.
  - host 의 수(§3.3)가 사라지면 CLI 실행을 묶는 것이 이 선언뿐이다.
- Keeper 턴만 쓰는 official client binding 은 선언하지 않아도 된다. Keeper 는 턴을 하나씩 돌린다.
- official client provider 도 `admission-priority-run-limit` 를 선언할 수 있다. 단 그 provider 의 binding 하나 이상이 `max-concurrent` 를 선언해야 한다. HTTP provider 와 같은 규칙이다. 그래야 Keeper 턴이 Librarian 보다 먼저 자리를 받는다.

### 3.3 host 는 수를 세지 않는다

`RFC-operator-quiz-lane.md` §4.4 "One cycle" 의 2번과 3번을 이렇게 바꾼다. `RFC-host-cycle-runs-exact-requests-side-by-side.md` §3.1~3.3 이 바꾼 문장을 다시 바꾼다.

> 2. For each request in order: deliver a final result the host already holds, or try the work once and deliver its result if it is final.
>    - An `exact_output` request runs beside the walk. The walk starts every `exact_output` request it lists.
>    - An `ask` is recorded once per request id. Its result is delivered only when the operator has answered it or the package has withdrawn it.
>    - A request whose attempt was not final stays undelivered until the next trigger. It is tried at most once per cycle, so it cannot keep a cycle running.
> 3. When a request ends with a delivery, list again without waiting for the requests still running. A listed request that is running or was tried in this cycle is not started again. The cycle ends when no request is running and the last listing started none.

```text
cycle():
  목록을 읽고 걷는다 (지금처럼 page 단위)
    이미 전달한 id 가 다시 나오면 걷기를 멈춘다 (Relisted_delivered_request)
    돌고 있거나 이번 cycle 에 시도한 id 는 건너뛴다
    exact_output 이 아니면 그 자리에서 처리한다
    exact_output 이면 fiber 하나로 시작한다
  다음 둘 가운데 먼저 오는 것을 기다린다
    돌던 요청 하나가 전달로 끝난다 → 목록을 다시 읽고 걷는다
    돌던 요청이 모두 끝났고 마지막 목록이 아무것도 시작하지 않았다 → cycle 끝
  걷기를 멈춘 오류가 있으면 새 요청을 시작하지 않고, 돌던 요청이 끝난 뒤 그 오류로 끝낸다
```

- 같이 도는 요청 수는 목록이 정한다. 목록의 요청은 host 원본이 있어야 실행된다(`Lane_addon_exact.execution_authority`). 원본이 없는 요청은 `Not_allowed` 로 끝난다.
- Librarian 은 Keeper·종류마다 끝나지 않은 원본을 하나만 둔다(같은 RFC §2.3). 그래서 같이 도는 요청은 Keeper 수의 두 배를 넘지 않는다. 운영 Keeper 31명이면 62개다.
- 요청 본문은 하나에 4 MiB(`max_reply_bytes`)를 넘지 않는다. 62개면 248 MiB 다.
- provider 에 나가는 요청 수는 §3.1·§3.2 의 자리가 묶는다.
- 걷기, 취소 표, 예외 규칙(같은 RFC §3.4·§3.5)은 그대로다. 걷기가 「돌던 요청이 모두 끝날 때」 대신 「하나가 전달로 끝날 때」 목록을 다시 읽는 것만 다르다.

지우는 것(hard cut):

- 설치 선언의 `max_exact_in_flight` 키. 이 키가 있는 선언은 `unknown declaration field` 로 거절된다.
- `Lane_addon_config.exact_in_flight`, `one_exact_at_a_time`, instance 의 `max_exact_in_flight` 칸, `Lane_addon_host_walk.walk` 의 `max_in_flight` 인자.
- 이 키를 설명하는 문서 문장(§6).

운영 선언에서 이 키를 쓰는 곳은 `keeper-librarian.toml` 하나다. 그 줄은 새 빌드로 재시작하기 직전, 서버가 멈춘 동안 지운다. 서버가 도는 동안 지우면 옛 빌드가 다음 maintenance pulse 에 키 없는 선언을 읽고 1로 돈다.

### 3.4 Librarian 재설계와의 관계

Librarian 을 host cycle 밖으로 옮기는 재설계가 따로 진행 중이다.

- 옮기기 전까지 Librarian 은 §3.3 의 host cycle 로 돈다.
- 옮긴 뒤에도 Librarian 의 질문은 §3.1 의 걷기로 자리를 잡는다. 따로 고른 동시 실행 수를 두지 않는다.
- §3.3 은 다른 Lane Add-on(curator, candle, lesson, quiz, hitl-auto-judge)에 남는다.

## 4. 틱으로 따라가 보기

Librarian lane 의 HTTP slot 이 A(자리 8, Keeper 턴과 같이 씀), B(자리 4), C(자리 4)라고 하자.

### 4.1 A 가 꽉 찼다

- A 의 자리 8개를 Keeper 턴이 쥐고 있다. B 에는 빈 자리가 있다.
- 요청은 A 를 기다리지 않고 B 의 자리를 받는다. 본문 한도 1,200초는 그때부터 센다.

### 4.2 셋 다 꽉 찼다

- 요청은 A, B, C 의 줄에 같이 선다.
- 200초 뒤 C 의 자리 하나가 빈다. 요청은 C 의 자리를 받고 A, B 의 줄에서 나온다.
- 같은 때 A 와 C 가 함께 비면 A 를 받고 C 의 자리를 바로 돌려준다.

### 4.3 B 가 400 을 돌려준다

- B 에서 실패하면 남은 slot 은 A, C 다. 같은 규칙으로 고른다.
- A, B, C 가 모두 실패하거나 쉬면 CLI 층으로 간다. CLI 층에서도 같은 규칙으로 자리를 고른다.

### 4.4 Keeper 31명의 요청이 한꺼번에 있다

- 목록에 요청이 40개 있다. host 는 40개를 모두 시작한다.
- 빈 자리만큼 바로 받는다. 나머지는 A, B, C 의 줄에 같이 선다.
- Keeper K 의 요청이 답하고 전달되면 host 는 바로 목록을 다시 읽는다. K 의 다음 요청이 목록에 있으면 그때 시작한다. 다른 39개가 끝나기를 기다리지 않는다.

### 4.5 줄에 선 채 instance 가 물러난다

- host 가 그 호출을 취소한다. 요청은 모든 줄에서 나온다.
- 보낸 것이 없어 시작 표시가 없다. revision 이 같은 instance 가 다시 붙으면 그 요청을 다시 실행한다.

## 5. 대가

- 뒤 slot 이 지금보다 많이 불린다. tinker 처럼 쓴 만큼 돈을 내는 slot 은 비용이 는다. 비싼 slot 은 운영자가 뒤로 옮기거나 목록에서 뺀다.
- 한 요청이 여러 줄에 같이 서므로, 계정마다 보이는 줄 길이가 실제로 기다리는 요청 수보다 길다. 자리 화면을 읽는 쪽은 이것을 알아야 한다.
- Exact lane 의 CLI slot 은 `max-concurrent` 를 선언해야 로드된다. 선언하기 전 runtime.toml 은 새 빌드에서 거절된다.
- official client binding 에 `max-concurrent` 를 적으면 그 계정의 Keeper 턴도 자리를 기다린다. 지금은 그 값이 무시된다.
- 요청이 끊이지 않으면 cycle 이 오래 열린다. 그동안 그 instance 의 action 과 observation 은 기다린다. 지금도 같은 성질이지만, 이제 더 자주 일어난다. keeper-librarian 은 source 가 없어 observation 이 비어 있다.
- 결과가 final 이 아니었던 요청은 다음 cycle 에 다시 시도한다. cycle 이 오래 열리면 그만큼 늦게 다시 시도된다. 지금과 같은 성질이다.

## 6. 바뀌는 계약과 문서

- `docs/rfc/RFC-operator-quiz-lane.md` §4.4 (§3.3 의 문장)
- `docs/rfc/RFC-host-cycle-runs-exact-requests-side-by-side.md` §3.1~3.3 (이 RFC 가 바꾼다는 한 줄)
- `docs/guides/lane-addon-toml.md` 38행·454행, `docs/guides/keeper-memory-execution.md` 223행
- `packages/agent_core/lib/llm_provider/provider_admission.mli` 의 `with_admission_until` 설명
- `lib/runtime/runtime_toml_bindings.ml` 의 `max-concurrent` 주석, `lib/runtime/runtime_toml.ml` 의 official client 거절 문구

## 7. 구현 층

native stack 으로 올린다. 층마다 Draft PR 이다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | §3.1 slot 고르기, 본문 한도를 자리 받은 때부터, `Permit_wait_*` 삭제 (Agent-Core) | mock clock 시험: A 꽉 참·B 빔 → B 즉시. 모두 꽉 참 → 먼저 빈 자리. 같은 때 → 앞 slot, 뒤 자리 반납. 실패 → 남은 slot. 재기·생성이 자리 하나. 취소 → 모든 줄에서 나옴, 새는 자리 없음 |
| L2 | §3.2 official client 자리, Exact lane `cli_slots` 선언 요구, run limit 거절 완화 | 로드 시험(선언 없음 거절, 값 불일치 거절). CLI 층에서 자리 수를 넘는 프로세스가 뜨지 않는 시험 |
| L3 | §3.3 host 가 수를 세지 않음, 바퀴 대신 「전달 하나마다 다시 읽기」, 키 삭제 | host walk 시험: 하나가 전달로 끝나면 나머지를 기다리지 않고 다시 읽는다. 돌던 id 는 다시 시작하지 않는다. 키가 있는 선언은 거절 |
| L4 | §6 문서 | 문서 안의 `max_exact_in_flight` 가 0개 |

순서의 까닭:

- L3 를 L1 보다 먼저 내면 늘어난 요청이 꽉 찬 첫 slot 앞에 줄만 선다.
- L3 를 L2 보다 먼저 내면 HTTP slot 이 모두 막힐 때 목록 수만큼 CLI 프로세스가 뜬다.

배포 때 운영자가 할 일:

- L2 를 설치하기 전: Librarian·candle lane 의 CLI binding 에 `max-concurrent` 를 적는다. 계정이 한 번에 받는 요청 수다.
- L3 를 설치하기 전: 서버를 멈춘 뒤 `keeper-librarian.toml` 의 `max_exact_in_flight` 줄을 지운다.
- 두 층의 changelog 에 이 일을 `Operator action required` 로 적는다.

## 8. 대안

| 대안 | 고르지 않은 까닭 |
|---|---|
| 수를 두고, 값을 Keeper 수로 자동으로 맞춘다 | 여전히 host 가 센 수다. 바퀴가 가장 늦은 요청을 기다리는 일은 그대로다. host 가 Keeper 를 알아야 한다 |
| host 가 「Keeper 마다 하나」를 센다 | host 요청에는 만든 Keeper 가 없다(`Lane_addon_exact.request`). Librarian 원본 규칙이 이미 그것을 지킨다 |
| HTTP 자리가 꽉 차면 CLI 로도 넘긴다 | CLI 는 프로세스와 구독 한도를 쓴다. HTTP 자리는 본문 한도 안에 빈다. §2 |
| 기다림에 따로 한도를 둔다 | 고른 수다. 여러 줄에 같이 서면 기다림은 처음 비는 자리에서 끝난다 |
| 꽉 찬 slot 을 지금처럼 기다리고 body 한도만 허가 뒤로 옮긴다(#52981 만 고침) | 잘린 생성은 사라진다. 꽉 찬 첫 slot 앞의 기다림은 남는다 |

## 9. 확인하지 못한 것

- 11-18 에 꽉 찬 slot 앞에서 기다린 요청 수. 허가 대기가 저장되지 않는다(§1.2). L1 은 Exact 시도가 끝날 때 남기는 로그 줄에 「자리를 기다린 시간」을 더한다. 배포 전후를 그 줄로 잰다.
- 자리를 쥔 호출이 모두 한도 안에 끝나는지. Exact 호출은 본문 한도가 있다. `body_timeout_s` 가 없는 HTTP binding 과 Keeper 턴의 호출이 자리를 얼마나 오래 쥐는지는 재지 않았다. 자리가 오래 비지 않으면 줄의 요청은 그동안 기다린다.
- candle, curator, lesson, quiz, hitl-auto-judge 의 요청이 같은 목록 안에서 순서에 기대는지. lesson 은 장면 요청이 서로 기대지 않는다(`RFC-operator-lesson-lane.md` §4.3). 나머지는 L3 전에 package 마다 확인한다.
