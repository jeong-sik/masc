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

- TUI 와 대시보드 읽기가 느려지는 일이 원인 작업만 바꿔 되풀이됐다. 풀을 거치는 읽기는 배경 작업과 같이 쓰는 executor 풀에서 차례를 기다렸다.
- Eio 의 executor 풀은 대기열이 FIFO 하나다. worker 는 부하가 1.0 미만이면 job 의 weight 와 상관없이 다음 job 을 가져간다. 우선순위는 없다.
- 읽기 요청(HTTP GET/HEAD)이 풀에 넣는 일은 읽기 전용 풀에서 돌게 한다. 호출 지점을 고치지 않는다. 요청 입구에서 fiber 에 표시를 남기고, 풀 제출 함수가 그 표시를 보고 풀을 고른다.
- 프로세스 전체 domain 수를 코어 수 안으로 줄인다. 지금은 16코어에서 domain 31개가 돈다.
- Librarian 수정(#46244) 뒤에는 풀을 거치지 않는 경로도 p99 1~5초였고, main domain 이 systhread 와 runtime lock 을 다투는 시간이 더 컸다. 그래서 풀 대기 계측을 먼저 넣고, 풀 분리는 그 값을 보고 진행한다. main domain 쪽은 RFC-main-domain-scheduler-latency 가 다룬다.
- 목표: Keeper 300명이 동시에 일할 때 읽기 API p99 100 ms, timeout 0. 이 RFC 하나로는 네 경로 중 둘(`keepers/turns`, `keepers/asks`)이 목표에 닿지 않는다.

## 1. 문제

근거: [측정 기록](../evidence/2026-10-27-read-pool-contention/README.md). Keeper 42명.

### 1.1 서버 밖에서 잰 지연

수정 전 서버(`9377c7f3025`, Librarian 재검증이 돌던 때)에서 같은 순간 두 요청을 번갈아 20번 불렀다.

| 요청 | 지나는 곳 | 최소 | 최대 |
|---|---|---:|---:|
| `GET /api/v1/gate/keepers?detailed=false&limit=1` | 공유 풀 | 4 ms | 527 ms |
| `GET /health` | main domain | 1.2 ms | 85 ms |

수정 후 서버(`d0c79a5d83a`, Librarian 수정 #46244 포함)를 `scripts/harness/perf/response_latency_probe.py` 로 쟀다. 11:06:54~11:20:08 KST, 경로마다 200번, 2초 간격, 요청 하나 30초 제한이다. 아래는 Librarian 의 끝난 기록 정리가 끝난 11:10 이후 153번이다.

| 경로 | 지나는 곳 | p50 | p95 | p99 | 최대 |
|---|---|---:|---:|---:|---:|
| `GET /api/v1/gate/keepers?detailed=true` | 공유 풀 | 165 ms | 4,591 ms | 8,518 ms | 15,437 ms |
| `GET /api/v1/operator` | 공유 풀 | 68 ms | 2,623 ms | 5,663 ms | 6,078 ms |
| `GET /api/v1/keepers/asks` | main domain | 38 ms | 1,438 ms | 5,401 ms | 10,921 ms |
| `GET /api/v1/keepers/turns` | main domain | 5 ms | 572 ms | 1,287 ms | 7,612 ms |
| `GET /health` | main domain | 8 ms | 896 ms | 3,301 ms | 4,076 ms |

`/health` 의 `server-timing` 으로 나누면 핸들러 시간은 p99 385 ms, 핸들러 밖에서 기다린 시간은 p99 2,192 ms 다. main domain 이 요청을 바로 받지 못했다.

같은 서버를 6초 sample 했다(`sample-after-fix-thread-kinds.txt`).

- 풀 worker domain 29개는 샘플의 85% 를 `poll` 에서 쉬었다. 이 6초 동안 공유 풀은 포화되지 않았다.
- main 스레드는 21% 를 자기 domain 의 runtime lock 을 다시 잡으려고 기다렸다(`caml_thread_leave_blocking_section`).
- systhread 345개가 잡혔고 대부분 6초보다 짧게 살았다. OCaml 을 돌린 systhread 의 masc 프레임 상위는 `Workspace_memory_ledger`, `Workspace_memory_request`, `Lane_addon_store` 였다. systhread 는 자기를 만든 domain 과 runtime lock 을 나눠 쓴다. CPU 작업을 systhread 로 넘겨도 그 domain 에서 빠지지 않는다.

Librarian 수정 뒤에는 공유 풀보다 main domain 의 lock 다툼이 더 크게 보인다. 6초 sample 이 몰려서 오는 풀 포화를 놓쳤을 수 있어서, 풀 대기 계측(3.6절)을 먼저 넣고 두 원인의 몫을 나눠 잰다(6절).

### 1.2 TUI 가 겪은 지연

TUI 로그(02:29~10:59 KST, 수정 전 서버의 수명)에서 1초를 넘긴 요청이다. TUI 의 elapsed 에는 TUI 그리기 루프를 기다린 시간이 들어 있다(`bin/masc_tui_http.ml` 첫 주석). 서버 지연이 아니라 사용자가 겪은 지연으로 읽는다.

| 경로 | 1초 넘음 | 10초 넘음 | 풀을 거치나 |
|---|---:|---:|---|
| `GET /api/v1/gate/keepers` | 2,522 | 243 | 거친다(`run_dashboard_compute`) |
| `GET /api/v1/keepers/turns` | 581 | 20 | 안 거친다. main domain 에서 Keeper 마다 `owners_mu` 를 읽기로 잡는다 |
| `GET /api/v1/operator` | 670 | 13 | 거친다 |
| `GET /api/v1/keepers/asks` | 498 | 6 | 안 거친다 |
| `GET /health` | 190 | 5 | 안 거친다 |

풀을 거치는 `gate/keepers` 가 다른 경로보다 10배 넘게 자주 10초를 넘겼다. 풀을 거치지 않는 경로도 느렸던 때가 있다. 이것은 TUI 쪽 대기와 main domain 의 다른 대기가 섞인 값이라 이 RFC 하나로 다 설명되지 않는다(4절).

### 1.3 같은 증상이 원인만 바꿔 되풀이됐다

| 날짜 | 풀을 막은 배경 작업 | 고친 곳 |
|---|---|---|
| 2026-10-07 | memory search 의 SQLite FTS5 순위 계산 | #41431 |
| 2026-10-16 | ask 답변 회수가 Keeper 원장을 통째로 다시 읽음 | #43307 |
| 2026-10-20 | continuity 체크포인트 접두 검증을 두 번 함 (#44249) | #44250 |
| 2026-10-26 | Librarian 이 끝난 history 기록까지 매번 다시 검증 | #46242~#46244 |

원인 작업을 고칠 때마다 다음 무거운 배경 작업이 같은 자리를 막았다. 배경 작업의 비용은 계속 줄여야 한다. 하지만 읽기가 배경 작업 뒤에 줄을 서는 구조는 그것만으로 바뀌지 않는다.

## 2. 지금 코드에서 읽기가 기다리는 이유

### 2.1 풀이 하나다

`Server_runtime_bootstrap` 이 `Domain_pool.create` 로 풀 하나를 만들고 `Domain_pool_ref` 와 `Executor_pool_ref` 가 둘 다 그 풀을 가리키게 한다(`install_domain_pool_references`).

- 읽기: `Server_dashboard_http_runtime_support.run_dashboard_compute` 가 `Executor_pool_ref.submit_or_inline` 을 weight 1.0 으로 부른다. `gate/keepers` 의 `respond_keeper_tool_json` 도 이 함수를 거친다.
- 배경 작업: Librarian, 원장 색인, 유지보수 작업이 `Domain_pool_ref.submit_io_or_inline`(weight 0.05)·`submit_cpu_or_inline`(1.0)으로 같은 풀에 들어간다. Librarian 의 history 검증은 JSON 파싱과 sha256 이 대부분인 CPU 작업인데 `io` 로 들어간다(`keeper_librarian_durable_execution.ml`).

풀이 포화돼도 읽기는 main domain 에서 대신 돌지 않는다. `submit_or_inline` 은 풀이 없거나, Eio fiber 밖이거나, 이미 풀 안일 때만 그 자리에서 실행한다.

### 2.2 Eio worker 는 우선순위 없이 다음 job 을 가져간다

저장소가 고정한 Eio 1.3(`masc.opam.locked`)의 `executor_pool.ml` `run_worker` 다.

```ocaml
let rec loop () =
  while !capacity >= max_capacity do Condition.await_no_mutex condition done;
  match Sync.take queue with
  | Ok (Pack { fn; w; weight }) ->
    capacity := !capacity + weight;
    Fiber.fork ~sw (fun () -> ... fn () ...);
```

- 대기열은 `Sync.t` 하나다. 먼저 들어온 job 이 먼저 나간다.
- worker 는 부하가 1.0 미만이면 다음 job 을 가져간다. 그 job 의 weight 가 남은 여유보다 커도 가져간다. weight 0.05 는 domain 하나에 최대 20개까지 겹친다.
- 14개 worker 가 모두 부하 1.0 이상이면 아무도 job 을 가져가지 않는다. 읽기는 그동안 대기열에서 기다린다.
- 가져간 job 은 그 domain 의 fiber 가 되어 바로 시작한다. 한 번 멈춘 뒤에는 같은 domain 의 다른 fiber 들이 각자 멈출 때까지 다시 돌지 못한다. Librarian 처럼 Eio 를 거치지 않고 CPU 만 쓰는 fiber 는 끝날 때까지 멈추지 않는다.

수정 전 서버 sample 에서 JSON 파싱(`caml_lex_engine`) 샘플의 76% 가 풀 worker domain 스레드에, 24% 가 systhread 에 있었다. main 스레드에는 거의 없었다. sha256 은 93% 가 worker domain 이었다. masc 프레임 상위는 `Lane_addon_tool_request_owner`, `Lane_addon_store`, `Keeper_librarian_original_gate` 였다.

### 2.3 HTTP 경로가 풀에 들어가는 곳이 많다

`origin/main` `76735b8794b` 기준이다.

- `run_dashboard_compute` 를 실제로 부르는 곳: 11곳.
- `lib/server` 에서 `Domain_pool_ref.submit_*_or_inline`·`Executor_pool_ref.submit_*` 를 바로 부르는 줄: 31개 파일 87줄(주석 줄 몇 개 포함).
- `lib` 전체: 254줄(io 174, cpu 62, executor 18). `let io = Domain_pool_ref.submit_io_or_inline` 같은 별칭 정의가 7곳 더 있다.

호출 지점마다 "이건 읽기니 다른 풀로"를 고치면 87곳을 따로 고친다. 새 핸들러가 생길 때마다 같은 실수가 다시 들어온다.

### 2.4 domain 이 코어보다 많다

수정 전 서버는 16코어에서 domain 31개를 돌렸다.

| domain | 수 | 만드는 곳 |
|---|---:|---|
| main | 1 | `main_eio.ml` |
| 공유 풀 | 14 | `Domain_pool.create`. `Domain.recommended_domain_count () - 2`, `MASC_EXECUTOR_DOMAIN_COUNT` 로 바꿀 수 있다 |
| agent_core codec 풀 | 14 | `packages/agent_core/lib/execution_runtime.ml` `create`. 부팅이 공유 풀과 같은 수를 넘긴다 |
| snapshot codec | 1 | `Keeper_event_queue_snapshot_codec` |
| 출처 미확인 | 1 | sample 의 domain 스레드는 30개인데 부팅 로그로 설명되는 것은 29개다 |

OCaml 5.5 매뉴얼([Parallel programming](https://ocaml.org/manual/5.5/parallelism.html))은 이렇게 적는다.

- "It is recommended that programs do not spawn more domains than the number of available cores."
- "When a domain exhausts its minor heap arena, it calls for a stop-the-world collection of the minor heaps."

수정 후 서버의 `/health` `gc.minor_collections` 는 10.8초 동안 초당 약 12번 늘었다. 그때마다 모든 domain 이 선다. 코어보다 domain 이 많으면 OS 가 재운 domain 하나를 나머지가 기다린다. `lib/core/domain_pool.ml` 주석의 2026-09-05 측정은 할당하는 domain 이 4개일 때 조용한 작업의 p99 가 169 µs, 14개일 때 11 ms 였다. domain 을 늘리는 것은 답이 아니다.

## 3. 설계

### 3.1 lane: 이 fiber 가 누구를 위해 일하는가

```ocaml
(* lib/core/pool_lane.ml *)
type request  (* 요청 하나. 요청이 끝났는지를 Atomic 으로 들고 있다 *)

type t =
  | Read of request  (* HTTP GET/HEAD 요청에 답하는 중 *)
  | Background       (* 그 밖의 모든 일 *)

val with_read : (unit -> 'a) -> 'a
val with_background : (unit -> 'a) -> 'a
val current : unit -> [ `Read | `Background ]
```

- lane 은 Eio fiber key 에 둔다. 표시가 없으면 `Background` 다. `Executor_pool_ref` 의 `worker_marker` 와 같은 방식이다.
- Eio 에서 fork 한 fiber 는 부모의 fiber key 를 물려받는다. 그래서 요청 중에 fork 한 fiber 도 `Read` 를 본다.
- `with_read` 는 끝날 때(예외 포함) 그 요청을 끝난 것으로 표시한다. `current ()` 는 끝난 요청의 `Read` 를 `Background` 로 돌려준다. 요청보다 오래 사는 fiber(웹소켓 heartbeat, 요청이 시작한 stale 캐시 재계산 등)는 요청이 끝나는 순간부터 배경 풀을 쓴다. 이런 fork 를 손으로 목록에 올릴 필요가 없다.

### 3.2 표시는 요청 입구에서 한다

HTTP 요청은 `Server_bootstrap_http` 에서 핸들러로 넘어간다. HTTP/1 은 `serve`·`serve_auto` 가 `request_handler` 를, HTTP/2 는 `serve_h2` 가 위임하는 `serve_h2_connection` 이 `h2_request_handler` 를 요청마다 부른다. gRPC listener 도 같은 곳으로 들어온다(POST 라 `Background`). 이 모듈에 helper 하나를 두고 세 곳이 그 helper 로 핸들러를 부른다. helper 는 method 가 GET 이나 HEAD 면 `Pool_lane.with_read` 로 감싼다.

`Http_server_eio.Router.dispatch` 에 두지 않는다. HTTP/2 는 `Server_h2_gateway` 가 직접 경로를 나눠 그 함수를 거치지 않는다.

POST·PUT·DELETE 와 `/mcp` 도구 호출은 `Background` 그대로다. 무거운 쓰기와 도구 실행이 읽기 풀을 차지하지 않게 한다. httpun 이 핸들러가 돌아간 뒤 부르는 콜백(본문 읽기, 스트리밍)은 이미 끝난 요청이라 `Background` 다.

### 3.3 풀 선택은 제출 함수 네 곳에서 한다

`Domain_pool_ref.submit_io_or_inline`, `submit_cpu_or_inline`, `Executor_pool_ref.submit_or_inline`, `submit_strict` 가 `Pool_lane.current ()` 를 읽고 읽기 풀이나 배경 풀을 고른다. `lib` 에서 공유 풀에 일을 넣는 길은 이 넷뿐이다. 87곳의 호출 지점과 별칭은 바꾸지 않는다.

풀 job 안에서는 이렇게 된다.

- Eio 풀 job 은 제출한 fiber 의 fiber key 를 물려받지 않는다. job 안에서 `current ()` 는 `Background` 다.
- `_or_inline` 세 함수는 이미 풀 안이면(`in_worker_context`) 그 자리에서 실행한다. 읽기 풀 job 안에서 부른 제출은 읽기 풀 domain 에 남는다.
- `submit_strict` 는 그 자리 실행이 없다. 풀 job 안에서 부르면 배경 풀로 간다. 지금 호출자는 msx POST 경로, `Server_schedule_consumers`, `Keeper_event_queue_recovery` 로 모두 `Background` 다.

읽기 풀이 설치되지 않은 환경(테스트, 단독 도구)에서는 읽기 lane 도 배경 풀을 쓴다. 운영 서버는 부팅에서 두 풀을 함께 설치하고 `/health` 의 `scheduler` 에 두 풀의 domain 수를 싣는다.

### 3.4 읽기가 배경 계산을 기다리지 않게 한다

`Dashboard_cache` 는 값이 없고 다른 fiber 가 계산 중이면 0.25초 간격으로 확인하며 기다린다(`dashboard_cache.ml` `Wait`). 그 계산을 배경 refresh 루프가 시작했다면 읽기는 결국 배경 풀을 기다린다. 풀 job 안에서 기다리면 그동안 worker 자리도 차지한다.

- `Dashboard_cache` 의 계산은 누가 시작했든 `Read` lane 으로 돈다. 캐시는 읽기에 답하려고 있는 것이다. 감싸는 곳은 `Dashboard_cache` 한 곳이다.
- 다른 fiber 의 계산을 기다리는 일은 풀 job 밖, 요청 fiber 에서 한다. L4 에서 `run_dashboard_compute` 안에서 캐시를 기다리는 경로를 모두 찾아, 풀에 넣는 범위를 계산 부분으로 좁힌다.

### 3.5 domain 예산

프로세스 전체를 `Domain.recommended_domain_count ()`(이 장비 16) 안에 넣는다.

| domain | 지금 | 바꾼 뒤 |
|---|---:|---:|
| main | 1 | 1 |
| snapshot codec | 1 | 1 |
| 읽기 풀 | 0 | 2 |
| 배경 풀 | 14 | 나머지 |
| agent_core codec 풀 | 14 | L2 측정으로 정한다 |

- 읽기 풀은 코어가 8개 이상이면 2, 그보다 적으면 1이다. 기다리지 않을 때 읽기 핸들러는 수 ms 안에 끝난다(1.1절 `limit=1` 최소 4 ms).
- 배경 풀은 `max 1 (recommended - 2 - 읽기 - codec)` 이다. `MASC_EXECUTOR_DOMAIN_COUNT` 는 지금처럼 배경 풀 크기를 정한다. 읽기 풀과 codec 풀 크기는 따로 정한다.
- agent_core codec 풀은 배경 풀과 합치지 않는다. 지금 `run_cpu` 는 호출자가 취소되면 worker 를 기다리지 않고 `Caller_cancelled`·`Runtime_released` 를 원자 변수로 알린다. masc 의 `Executor_pool_submission.submit` 은 worker 를 취소하고 `Cancel.protect` 아래에서 끝나기를 기다린다. 합치면 이 의미가 바뀌고, Keeper 실행 기록 쓰기(`writer_gate` 를 잡은 채 하는 비교)가 배경 FIFO 뒤에 선다. 크기만 예산 안으로 줄인다. L2 에서 codec 풀의 사용량(`Execution_runtime.stats`)을 `/health` 에 싣고 그 값으로 정한다.
- 출처를 모르는 domain 1개는 L3 에서 찾는다.

### 3.6 풀 대기 시간을 잰다

지금은 제출부터 worker 가 시작할 때까지를 재는 곳이 없다. `Executor_pool_submission.submit` 에서 그 시간을 lane 별 고정 구간 히스토그램(Atomic 카운터)에 넣고 `/health` 에 싣는다. 이 계측만으로 고쳐지는 것은 없다. 고친 뒤 효과와 남은 대기를 나눠 보려는 것이다.

## 4. 하지 않는 것

- Keeper fiber(keepalive, 턴 실행)를 다른 domain 으로 옮기는 일. 이 RFC 는 이미 풀에 제출되던 함수가 어느 풀에서 도느냐만 바꾼다.
- main domain 에서 생기는 대기. `keepers/turns`·`keepers/asks`·`/health` 는 풀을 거치지 않는다. 1.1절 수정 후 측정에서 이 경로들의 p99 는 1.3~5.4초로 목표를 넘었고, main 스레드는 21% 를 runtime lock 대기로 보냈다. systhread 안에서 OCaml 을 돌리는 클로저는 [RFC-main-domain-scheduler-latency](RFC-main-domain-scheduler-latency.md) §7.2 가 이미 "옮겨야 한다"고 정했다. 그쪽에서 다룬다. `keepers/turns` 가 Keeper 마다 잡는 `owners_mu`, HTTP accept 를 별도 domain 으로 옮기는 `MASC_SERVING_DOMAIN_ENABLED`(기본 false)도 그쪽 판단이다. goal 의 네 경로 중 둘은 이 RFC 만으로 목표에 닿지 않는다.
- 읽기 하나가 쓰는 메모리와 시간을 묶는 일. [RFC-0372](RFC-0372-request-scoped-resource-budget.md) 가 다룬다.
- 배경 작업 각각의 비용 줄이기와 weight 재분류.
- 클라이언트 timeout 늘리기, 요청 수 제한, 동시 실행 상한. 증상만 가린다.
- POST·`/mcp` 도구 호출의 지연.

## 5. 검증

### 5.1 풀 격리 시험

배경 풀의 모든 worker 에 weight 1.0 job 을 넣고, 각 job 이 아직 풀리지 않은 promise 를 기다리게 한다. 그 상태에서 `Read` lane 으로 job 하나를 제출한다. 그 job 은 시작하자마자 `started` promise 를 푼다. 시험은 `started` 와 10초 sleep 중 먼저 끝나는 쪽을 보고, 그다음 배경 job 들을 푼다.

- 지금 코드: 읽기 job 을 받을 worker 가 없어 sleep 이 먼저 끝난다. 시험은 실패한다. 멈춘 채 끝나지 않는 것이 아니라 10초 뒤 실패로 끝난다.
- 바뀐 코드: 읽기 job 이 읽기 풀에서 바로 시작한다.

시간에 기대는 부분은 옛 코드가 실패하는 길에만 있다. 바뀐 코드가 이 시험에서 지려면 비어 있는 읽기 풀이 10초 동안 job 을 시작하지 못해야 한다.

### 5.2 lane 시험

- GET 핸들러 안의 `Domain_pool_ref.submit_io_or_inline` 은 읽기 풀에서, POST 핸들러 안의 같은 호출은 배경 풀에서 실행된다.
- 표시 없는 fiber 는 `Background` 다.
- `with_read` 안에서 fork 한 fiber 는 요청 중에는 `Read`, `with_read` 가 끝난 뒤에는 `Background` 를 본다. 예외로 끝나도 같다.
- `Dashboard_cache` 계산은 배경 fiber 가 시작해도 읽기 풀에서 돈다.

### 5.3 수용 측정

goal `goal-read-api-p99-300-keepers-20261027` 의 판정 표다. 행마다 측정한 main 커밋, Keeper 수, 배경 부하 조건, 경로별 요청 수·p50·p99·timeout 수와 원문 측정 파일 링크를 적는다.

- 대상 경로: `GET /api/v1/gate/keepers?detailed=true`, `/api/v1/keepers/turns`, `/api/v1/operator`, `/api/v1/keepers/asks`.
- 300명 조건: `scripts/harness/perf/keeper_scale_session.py --keepers 300` 으로 띄운 격리 서버에서, Keeper 300명이 모두 요청을 들고 있는 구간 동안 `scripts/harness/perf/response_latency_probe.py` 로 위 경로를 잰다.
- 라이브 조건: 배포 뒤 운영 서버에서 같은 탐침을 1시간 돌린다.

| 측정 시각 | 서버 커밋 | Keeper | 배경 부하 | 경로별 결과 | 원문 |
|---|---|---:|---|---|---|
| 2026-10-27 09~10시 KST | `9377c7f3025` (바꾸기 전, Librarian 수정 전) | 42 | 운영, Librarian 재검증 중 | p99 미측정. 서버 밖 탐침 `gate/keepers?limit=1` 4~527 ms. TUI 기준 `gate/keepers` 1초 넘음 2,522건 중 10초 넘음 243건 | [기록](../evidence/2026-10-27-read-pool-contention/README.md) |
| 2026-10-27 11:10~11:20 KST | `d0c79a5d83a` (Librarian 수정 후, 풀 분리 전) | 42 | 운영 | 153번씩. `gate/keepers` p50 165 / p99 8,518 / timeout 0, `keepers/turns` 5 / 1,287 / 0, `operator` 68 / 5,663 / 0, `keepers/asks` 38 / 5,401 / 0 (ms, 30초 제한) | [원문](../evidence/2026-10-27-read-pool-contention/probe-after-fix-d0c79a5.json) |

완료 조건: 300명 행에서 네 경로 모두 p99 ≤ 100 ms, timeout 0. 그때 status 를 Implemented 로 바꾼다.

### 5.4 300명에서 따로 고칠 것

`GET /api/v1/gate/keepers` 는 `keeper_list_max_limit = 200` 으로 잘린다(`lib/server/server_routes_http_routes_channel_gate.ml`). 응답에는 `total` 과 `truncated` 가 있지만 TUI decoder(`Tui_decode.decode_keeper_runtime_list`)가 읽지 않는다. 300명이면 TUI 명단에서 100명이 표시 없이 빠진다. #46328 에서 다룬다.

## 6. 단계

각 층은 stacked PR 하나다.

| 층 | 내용 | 시험 |
|---|---|---|
| L1 | 이 RFC 와 측정 기록 | — |
| L2 | `Pool_lane` 표시(풀 선택은 그대로), `Server_bootstrap_http` 의 GET/HEAD 표시(HTTP/1·HTTP/2), lane 별 풀 대기 히스토그램, codec 풀 사용량을 `/health` 에 싣기 | 5.2 의 표시 시험, 히스토그램 구간 경계 |
| L3 | 읽기 풀 생성과 domain 예산, 제출 함수 네 개의 풀 선택, 출처 모를 domain 찾기 | 5.1, 5.2 의 풀 선택 시험 |
| L4 | `Dashboard_cache` 계산의 lane, 캐시 대기를 풀 job 밖으로 | 5.2 의 캐시 시험 |
| L5 | codec 풀 크기를 L2 값으로 정하기 | 예산 합이 코어 수 이하 |
| L6 | 수용 측정 기록, status 갱신 | 5.3 |

계측(L2)을 맨 앞에 둔다. 1.1절 수정 후 측정에서 공유 풀은 6초 sample 동안 쉬고 있었고, main domain 의 lock 대기가 더 컸다. L2 로 운영 서버의 풀 대기를 한 시간 재서, 읽기의 풀 대기 p99 가 목표(100 ms)를 넘을 때 L3 이후를 진행한다. 넘지 않으면 L3 이후는 보류하고 main domain 쪽을 먼저 고친다.

## 7. 위험

- **읽기끼리 기다린다.** 무거운 GET 이 읽기 풀 2개를 다 쓰면 가벼운 GET 이 기다린다. L2 계측으로 본다. 읽기 하나가 저장소 크기만큼 커지는 경우는 RFC-0372 로 고친다. domain 을 늘려서 덮지 않는다.
- **포기된 요청이 자리를 잡고 있다.** HTTP/1 핸들러는 연결의 읽기 루프를 막고 돈다. 클라이언트가 timeout 으로 떠나도 서버 job 은 취소되지 않고 읽기 풀 자리를 끝까지 쓴다. 지금도 같은 일이 공유 풀에서 일어난다. 취소는 RFC-0372 의 요청 단위 기한과 같이 다룬다.
- **배경 작업과 같은 lock.** 읽기 핸들러가 배경 작업이 쥔 store lock 을 기다리면 풀을 나눠도 느리다. 이때는 풀 대기는 짧고 핸들러 시간이 길게 나온다. L2 계측으로 구분한다.
- **배경 처리량.** 배경 풀이 줄어든다. 지금은 domain 30개가 16코어를 나눠 쓰고 있어서 실제로 쓰는 코어 수는 줄지 않을 것으로 본다. Librarian pass 시간(`durable Librarian inventory validated: ... elapsed_ms=`)을 배포 전후로 비교한다.
