---
title: 읽기 요청은 배경 작업과 다른 풀에서 처리한다
rfc: 0204
status: Draft
created: 2026-05-29
updated: 2026-10-27
author: jeong-sik (with Claude Opus 5.5)
related:
  - RFC-main-domain-scheduler-latency — main domain 이 기다리는 시간
  - RFC-librarian-history-settles-finished-originals — 이번 지연의 가장 큰 배경 작업
  - RFC-0372 request-scoped-resource-budget — 읽기 하나가 쓰는 양을 묶는다
goal: goal-read-api-p99-300-keepers-20261027
---

# RFC-0204 — 읽기 요청은 배경 작업과 다른 풀에서 처리한다

## 0. 요약

- TUI 와 대시보드의 읽기 요청이 10초 timeout 을 낸다. 원인 작업은 매번 달랐지만 기다린 곳은 늘 같다. 배경 작업과 같이 쓰는 executor 풀 하나다.
- Eio 의 executor 풀은 대기열이 FIFO 하나다. worker 는 job 의 weight 를 보고 고르지 않는다. 그래서 읽기 요청은 앞에 쌓인 배경 작업이 끝나야 실행된다.
- 읽기 요청(HTTP GET)은 전용 풀에서 돌게 한다. 호출 지점을 고치지 않고, 요청이 들어오는 입구에서 fiber 에 표시를 남기고 제출 함수가 그 표시를 보고 풀을 고른다.
- 프로세스 전체 domain 수를 코어 수 안으로 줄인다. 지금은 16코어에서 domain 31개가 돈다.
- 목표: Keeper 300명이 동시에 일할 때 읽기 API p99 100 ms, timeout 0.

## 1. 문제

### 1.1 측정 (2026-10-27)

근거: [측정 기록](../evidence/2026-10-27-read-pool-contention/README.md). 서버 바이너리 `9377c7f3025`, Keeper 42명.

| 경로 | 1초 넘은 요청 | 10초 timeout |
|---|---:|---:|
| `GET /api/v1/gate/keepers` | 2,821 | 267 |
| `GET /api/v1/keepers/turns` | 646 | 19 |
| `GET /api/v1/dashboard/scheduled-automation` | 978 | 17 |
| `GET /api/v1/operator` | 746 | 14 |
| `GET /api/v1/keepers/asks` | 562 | 7 |
| `GET /health` | 234 | 4 |

집계 창은 TUI 로그 01:34~10:29 KST 이다. `gate/keepers` 는 시간대 평균이 2.9~5.1초였고, 최대 45초까지 걸렸다.

같은 순간에 두 요청을 번갈아 불렀다.

- `gate/keepers?detailed=false&limit=1`: 0.49~5.2초. 풀을 거친다.
- `/health`: 1.5~11 ms. main domain 에서 바로 답한다.

가벼운 요청도 풀을 거치면 느렸다. 핸들러가 무거워서가 아니라, 실행 차례를 기다렸다.

### 1.2 같은 증상이 원인만 바꿔 되풀이됐다

| 날짜 | 풀을 막은 배경 작업 | 고친 곳 |
|---|---|---|
| 2026-10-07 | memory search 의 SQLite FTS5 순위 계산 | #41431 |
| 2026-10-16 | ask 답변 회수가 Keeper 원장을 통째로 다시 읽음 | #43307 |
| 2026-10-20 | continuity 체크포인트 접두 검증을 두 번 함 (#44249) | #44250 |
| 2026-10-26 | Librarian 이 끝난 history 기록까지 매번 다시 검증 | #46242~#46244 |

원인 작업을 고칠 때마다 다음 무거운 배경 작업이 같은 자리를 막았다. 배경 작업의 비용을 줄이는 일은 계속해야 한다. 하지만 그것만으로는 읽기 지연을 막을 수 없다. 읽기가 배경 작업 뒤에 줄을 서는 구조가 그대로 남기 때문이다.

## 2. 지금 코드에서 읽기가 기다리는 이유

### 2.1 풀이 하나다

`Server_runtime_bootstrap` 이 `Domain_pool.create` 로 풀 하나를 만들고, `Domain_pool_ref` 와 `Executor_pool_ref` 둘 다 그 풀을 가리키게 한다(`install_domain_pool_references`).

- 읽기: `Server_dashboard_http_runtime_support.run_dashboard_compute` 가 `Executor_pool_ref.submit_or_inline` 을 weight 1.0 으로 부른다. `gate/keepers` 의 `respond_keeper_tool_json` 도 이 함수를 거친다.
- 배경 작업: Librarian, 원장 색인, 유지보수 작업이 `Domain_pool_ref.submit_io_or_inline`(weight 0.05) 와 `submit_cpu_or_inline`(1.0) 로 같은 풀에 들어간다.

풀이 포화돼도 읽기는 main domain 에서 대신 돌지 않는다. `submit_or_inline` 은 풀이 없거나, Eio fiber 밖이거나, 이미 풀 안일 때만 그 자리에서 실행한다. 그 밖에는 풀에 넣고 끝날 때까지 기다린다.

### 2.2 Eio worker 는 weight 를 보고 job 을 고르지 않는다

저장소가 고정한 Eio 1.3(`masc.opam.locked`)의 `executor_pool.ml` `run_worker` 는 이렇게 동작한다.

```ocaml
let rec loop () =
  while !capacity >= max_capacity do Condition.await_no_mutex condition done;
  match Sync.take queue with
  | Ok (Pack { fn; w; weight }) ->
    capacity := !capacity + weight;
    Fiber.fork ~sw (fun () -> ... fn () ...);
```

- 대기열은 `Sync.t` 하나다. 우선순위가 없다.
- worker 는 부하가 1.0 미만이기만 하면 다음 job 을 가져간다. 그 job 의 weight 가 남은 여유보다 커도 가져간다.
- 가져간 job 은 그 domain 의 fiber 가 된다. 같은 domain 의 다른 fiber 가 양보하지 않으면 실행되지 않는다.

Librarian 의 history 검증은 JSON 파싱과 sha256 이 대부분인 CPU 작업인데 `submit_io_or_inline`(0.05)으로 들어간다. 그래서 domain 하나에 이런 job 이 최대 20개까지 겹친다. weight 1.0 인 읽기가 그런 domain 에 배정되면 앞의 job 들이 끝날 때까지 실행되지 못한다.

2026-10-27 sample 에서 masc 프레임 상위 4개는 `Lane_addon_tool_request_owner`, `Lane_addon_store`, `Keeper_librarian_original_gate`, `Keeper_librarian_durable_commit` 이었다. memprof 할당의 약 90% 가 같은 계열이었다.

### 2.3 HTTP 경로가 풀에 들어가는 곳이 많다

`origin/main` `76735b8794b` 기준으로 센 값이다.

- `run_dashboard_compute` 호출: 15곳.
- `lib/server` 에서 `Domain_pool_ref.submit_*_or_inline`·`Executor_pool_ref.submit_*` 를 바로 부르는 곳: 31개 파일, 87곳.
- `lib` 전체 직접 호출: 254곳(io 174, cpu 62, executor 18). `let io = Domain_pool_ref.submit_io_or_inline` 같은 별칭이 50곳 더 있다.

호출 지점마다 "이건 읽기니 다른 풀로"를 고치면 87곳을 따로 고치게 된다. 새 핸들러가 생길 때마다 같은 실수가 다시 들어온다.

### 2.4 domain 이 코어보다 많다

라이브 서버는 16코어에서 domain 31개를 돌린다.

| domain | 수 | 만드는 곳 |
|---|---:|---|
| main | 1 | `main_eio.ml` |
| 공유 풀 | 14 | `Domain_pool.create`, `Domain.recommended_domain_count () - 2` |
| agent_core codec 풀 | 14 | `packages/agent_core/lib/execution_runtime.ml` `create`, 공유 풀과 같은 수를 받는다 |
| snapshot codec | 1 | `Keeper_event_queue_snapshot_codec` |
| 출처 미확인 | 1 | sample 에는 `domain_thread_func` 스레드가 30개인데 부팅 로그로 설명되는 것은 29개다 |

OCaml 5.5 매뉴얼([Parallel programming](https://ocaml.org/manual/5.5/parallelism.html))은 이렇게 적는다.

- "It is recommended that programs do not spawn more domains than the number of available cores."
- "When a domain exhausts its minor heap arena, it calls for a stop-the-world collection of the minor heaps."

minor 수집은 모든 domain 을 세운다. 코어보다 domain 이 많으면 OS 가 재운 domain 하나가 깨어날 때까지 나머지가 기다린다. `lib/core/domain_pool.ml` 주석의 2026-09-05 측정은 할당하는 domain 이 4개일 때 조용한 작업의 p99 가 169 µs, 14개일 때 11 ms 였다. domain 을 더 늘리는 것은 답이 아니다.

## 3. 설계

### 3.1 lane: 이 fiber 가 누구를 위해 일하는가

```ocaml
(* lib/core/pool_lane.ml *)
type t =
  | Read        (* HTTP GET/HEAD 요청에 답하는 중 *)
  | Background  (* 그 밖의 모든 일 *)
```

- lane 은 Eio fiber key 에 둔다. 표시가 없으면 `Background` 다.
- `Executor_pool_ref` 의 `worker_marker` 와 같은 방식이다. fiber 에 묶이고, 그 fiber 가 fork 한 fiber 로 이어진다.

### 3.2 표시는 요청 입구 한 곳에서 한다

HTTP 요청은 `Server_bootstrap_http` 에서 핸들러로 넘어간다. HTTP/1 은 `serve`·`serve_auto` 가 `request_handler` 를, HTTP/2 는 `serve_h2_connection` 이 `h2_request_handler` 를 요청마다 부른다. 이 모듈에 helper 하나를 두고 세 곳 모두 그 helper 로 부른다. helper 는 요청 method 가 GET 이나 HEAD 면 `Pool_lane.with_read` 로 감싼다.

`Http_server_eio.Router.dispatch` 에 두지 않는 이유가 있다. HTTP/2 는 `Server_h2_gateway` 가 직접 경로를 나눠 그 함수를 거치지 않는다. 거기에 두면 HTTP/2 요청이 빠진다.

httpun 이 나중에 부르는 콜백(요청 본문을 읽는 콜백 등)은 이 감싸기 밖에서 돈다. 본문을 읽는 요청은 POST 라 원래 `Background` 다.

POST·PUT·DELETE 와 `/mcp` 도구 호출은 `Background` 그대로 둔다. 무거운 쓰기와 도구 실행이 읽기 풀을 차지하지 않게 하려는 것이다. 이 RFC 의 목표는 읽기 지연이다.

### 3.3 풀 선택은 제출 함수 두 곳에서 한다

- `Domain_pool_ref.submit_io_or_inline`, `submit_cpu_or_inline`
- `Executor_pool_ref.submit_or_inline`, `submit_strict`

이 네 함수가 `Pool_lane.current ()` 를 읽고 읽기 풀이나 배경 풀을 고른다. 87곳의 호출 지점은 바꾸지 않는다. 별칭으로 부르는 곳도 같은 함수를 거치므로 따라온다.

풀 안에서 다시 제출하면 지금처럼 그 자리에서 실행한다(`in_worker_context`). 읽기 풀의 job 이 안에서 부른 제출도 읽기 풀 domain 에 남는다.

### 3.4 domain 예산

프로세스 전체를 `Domain.recommended_domain_count ()` 안에 넣는다. 이 장비에서는 16이다.

| domain | 지금 | 바꾼 뒤 |
|---|---:|---:|
| main | 1 | 1 |
| snapshot codec | 1 | 1 |
| 읽기 풀 | 0 | 2 |
| 배경 풀 | 14 | 12 |
| agent_core codec 풀 | 14 | 0 (배경 풀을 같이 쓴다) |
| 합계 | 30 + 미확인 1 | 16 |

- 읽기 풀은 2로 시작한다. 읽기 핸들러는 기다리지 않으면 수 ms 안에 끝난다(1.1절의 탐침에서 `limit=1` 요청이 4 ms). 수용 측정에서 모자라면 숫자를 바꾼다. 새 환경 변수는 만들지 않는다.
- agent_core 가 자기 풀을 만들지 않고, masc 가 넘긴 제출 함수를 쓰게 한다(의존 방향은 그대로다. agent_core 는 masc 를 모른다). 같은 풀을 쓰면 masc 풀 job 안에서 codec 작업을 부를 때 worker 가 서로를 기다릴 수 있다. masc 의 `submit_cpu_or_inline` 은 이미 풀 안이면 그 자리에서 실행하므로, 그 함수를 넘기면 이 교착이 생기지 않는다.

### 3.5 풀 대기 시간을 잰다

지금은 "제출부터 worker 가 시작할 때까지"를 재는 곳이 없다. 1.1절도 대조 실험으로만 추정했다.

`Executor_pool_submission.submit` 에서 제출 시각과 worker 진입 시각의 차를 lane 별 고정 구간 히스토그램(Atomic 카운터)에 넣고 `/health` 에 싣는다. 측정을 위한 계측이며, 이것만으로 고쳐지는 것은 없다.

### 3.6 요청이 끝난 뒤에도 남는 fiber

읽기 요청에서 fork 한 fiber 는 `Read` 를 물려받는다. stale 값을 먼저 주고 뒤에서 다시 계산하는 캐시 같은 경우다. 그 계산도 읽기를 위한 일이라 읽기 풀에서 돌아도 된다.

요청보다 오래 사는 배경 루프를 GET 핸들러가 시작하는 곳이 있으면 `Pool_lane.with_background` 로 감싼다. 구현 층에서 GET 핸들러가 서버 수명 switch 에 fork 하는 곳을 전부 찾아 목록으로 남긴다.

## 4. 하지 않는 것

- Keeper fiber(keepalive, 턴 실행)를 다른 domain 으로 옮기는 일. 이 RFC 가 바꾸는 것은 이미 풀에 제출되던 함수가 어느 풀에서 도느냐뿐이다. Keeper switch 와 fiber 는 main domain 에 그대로 있다.
- 읽기 하나가 쓰는 메모리와 시간을 묶는 일. [RFC-0372](RFC-0372-request-scoped-resource-budget.md) 가 다룬다. 풀을 나눠도 큰 읽기는 여전히 크다.
- 배경 작업 각각의 비용 줄이기. Librarian 은 #46242~#46244, 나머지는 따로 진행한다.
- weight 재분류(CPU 작업을 io 로 넣는 문제). 읽기를 분리하면 이 문제는 배경 풀 안의 순서 문제로 좁아진다. 따로 다룬다.
- HTTP accept 를 별도 domain 으로 옮기는 일. `MASC_SERVING_DOMAIN_ENABLED`(기본 false)로 이미 있다. 1.1절에서 main domain 의 `/health` 는 빨랐다. 지금의 병목이 아니다.
- 클라이언트 timeout 늘리기, 요청 수 제한, 동시 실행 상한. 증상만 가린다.
- POST·`/mcp` 도구 호출의 지연. 이 RFC 의 목표 밖이다.

## 5. 검증

### 5.1 풀 격리 시험 (결정적)

배경 풀의 모든 worker 에 weight 1.0 job 을 넣고, 각 job 이 아직 풀리지 않은 promise 를 기다리게 한다. 그 상태에서 `Read` lane 으로 제출한 job 이 promise 를 풀기 전에 끝나는지 순서로 단언한다.

- 지금 코드: 읽기 job 이 받아 줄 worker 가 없다. 시험 fiber 가 일정 시간 뒤 promise 를 풀면, 읽기 job 은 그 뒤에 끝나 단언이 실패한다. 멈춰서 끝나지 않는 것이 아니라 실패로 끝난다.
- 바뀐 코드: 읽기 job 이 읽기 풀에서 먼저 끝난다.

### 5.2 lane 표시 시험

- GET 핸들러 안의 `Domain_pool_ref.submit_io_or_inline` 이 읽기 풀에서 실행된다.
- POST 핸들러 안의 같은 호출은 배경 풀에서 실행된다.
- 표시 없는 fiber 는 `Background` 다.

### 5.3 수용 측정

goal `goal-read-api-p99-300-keepers-20261027` 의 판정 표다. 행마다 측정한 main 커밋, Keeper 수, 배경 부하 조건, 경로별 요청 수·p50·p99·timeout 수, 원문 측정 파일 링크를 적는다.

- 대상 경로: `GET /api/v1/gate/keepers?detailed=true`, `/api/v1/keepers/turns`, `/api/v1/operator`, `/api/v1/keepers/asks`.
- 300명 조건: `scripts/harness/perf/keeper_scale_session.py --keepers 300` 으로 띄운 격리 서버에, Keeper 300명이 모두 요청을 들고 있는 구간 동안 `scripts/harness/perf/response_latency_probe.py` 로 위 경로를 잰다.
- 라이브 조건: 배포 뒤 운영 서버에서 같은 탐침을 1시간 돌린다.

| 측정 시각 | main 커밋 | Keeper | 배경 부하 | 경로별 p50 / p99 / timeout | 원문 |
|---|---|---:|---|---|---|
| 2026-10-27 | `9377c7f3025` (바꾸기 전) | 42 | 운영, Librarian 재검증 중 | p99 미측정. `gate/keepers` 1초 초과 2,821건 중 timeout 267건 | [기록](../evidence/2026-10-27-read-pool-contention/README.md) |

완료 조건: 300명 행에서 네 경로 모두 p99 ≤ 100 ms, timeout 0. 그때 status 를 Implemented 로 바꾼다.

### 5.4 300명에서 따로 고칠 것

`GET /api/v1/gate/keepers` 는 `keeper_list_max_limit = 200` 으로 잘린다(`lib/server/server_routes_http_routes_channel_gate.ml`). 응답에 `truncated` 가 있어 조용히 틀리지는 않는다. 하지만 300명이면 TUI 명단에 100명이 빠진다. 이 RFC 의 풀 분리와는 별개로 이슈를 연다.

## 6. 단계

각 층은 stacked PR 하나다.

| 층 | 내용 | 시험 |
|---|---|---|
| L1 | 이 RFC 와 측정 기록 | — |
| L2 | `Pool_lane`, 읽기 풀 생성, 제출 함수 네 개의 풀 선택, domain 예산(배경 12 + 읽기 2) | 5.1, 5.2 의 표시 없는 fiber |
| L3 | `Server_bootstrap_http` 에서 GET/HEAD 표시(HTTP/1·HTTP/2), 요청보다 오래 사는 fork 목록과 `with_background` | 5.2 |
| L4 | 풀 대기 시간 히스토그램을 `/health` 에 싣기 | 히스토그램 구간 경계 |
| L5 | agent_core codec 풀을 배경 풀과 합치기 | codec 작업이 masc 풀 job 안에서 불려도 끝나는지 |
| L6 | 수용 측정 기록, status 갱신 | 5.3 |

## 7. 위험

- **읽기끼리 기다린다.** 무거운 GET(큰 대시보드 묶음)이 읽기 풀 2개를 다 쓰면 가벼운 GET 이 기다린다. L4 계측으로 본다. 읽기 하나가 저장소 크기만큼 커지는 경우는 RFC-0372 로 고친다. domain 을 늘려서 덮지 않는다.
- **배경 작업과 같은 lock.** 읽기 핸들러가 배경 작업이 쥔 store lock 을 기다리면 풀을 나눠도 느리다. 이때는 풀 대기는 짧고 핸들러 시간이 길게 나온다. L4 계측으로 구분한다.
- **배경 처리량.** 배경 풀이 14에서 12로 줄고 codec 작업도 같이 쓴다. 지금은 domain 30개가 16코어를 나눠 쓰고 있어서, 실제로 쓰는 코어 수는 줄지 않을 것으로 본다. Librarian pass 시간(`durable Librarian inventory validated: ... elapsed_ms=`)을 배포 전후로 비교한다.
- **lane 이 잘못 물려진다.** 3.6절. L3 의 목록이 빠지면 배경 루프가 읽기 풀에서 돈다. L4 계측에서 읽기 풀이 오래 차 있으면 이 경우를 의심한다.
