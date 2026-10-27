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
- `with_read` 는 끝날 때(예외 포함) 그 요청을 끝난 것으로 표시한다. `current ()` 는 끝난 요청의 `Read` 를 `Background` 로 돌려준다. 요청보다 오래 사는 fiber(웹소켓 heartbeat 등)는 요청이 끝나는 순간부터 배경 풀을 쓴다. lane 은 풀에 제출하는 순간의 fiber 로 정한다. 요청이 기다리지 않는 일을 fork 하는 곳은 `with_background` 로 감싼다. GET 이 닿는 곳의 목록은 3.4 에 있다.

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

- 캐시 계산의 lane 은 그 값을 기다리는 쪽이 정한다. 캐시가 비어 읽기가 직접 계산하면(`Compute`) 그 계산은 `Read` 다. 읽기가 옛 값으로 바로 답하고 fork 하는 SWR 재계산은 기다리는 요청이 없으니 `Background` 다. 이 재계산은 계산 예산이 8~120초라, `Read` 로 두면 읽기 풀 1~2 domain 을 다 쓸 수 있다.
- GET 이 닿는 배경 갱신 fork 는 일곱 곳이고, 모두 fork 한 fiber 안을 `Pool_lane.with_background` 로 감싼다: `Dashboard_cache` SWR, `Operator_control_snapshot_cache` SWR, `Server_dashboard_http_namespace_truth` shell 갱신, `Server_dashboard_http_runtime_info` 의 git 갱신과 runtime probe 갱신, `Dashboard_briefing_sections` 비동기 갱신, `Runtime_provider_usage_read` 배경 읽기. fork 가 안 돼 그 자리에서 계산하는 경로는 호출자가 기다리므로 감싸지 않는다. 새 배경 갱신 fork 를 만들면 같이 감싼다. 빠뜨리면 그 일은 읽기 풀에서 돌고, `pool_wait.read.run` 의 긴 꼬리로 보인다.
- 남는 경우: 키가 아예 없을 때(부팅 직후, eviction, invalidate 뒤) 배경 fiber 가 시작한 계산을 읽기가 `Wait` 으로 기다리면, 읽기는 배경 풀의 계산을 기다린다. 옛 값이 있는 동안에는 생기지 않는다.
- 다른 fiber 의 계산을 풀 job 안에서 기다리지 않게 한다(L4b, 아래).

#### L4b: 줄 선 계산은 기다리는 job 이 맡는다

풀 job 무게는 1.0 이라, job 이 캐시를 기다리며 쉬는 동안 그 worker 는 다른 일을 받지 않는다. `run_dashboard_compute` 11곳 중 6곳과 캐시 계산 안의 중첩 조회 4갈래가 job 안에서 `Dashboard_cache` 를 조회한다(`docs/evidence/2026-10-27-read-pool-contention/cache-wait-in-pool-jobs.md`). 가장 나쁜 경우는 순서가 꼬이는 것이다. 요청 fiber 가 키의 owner 이고 계산을 같은 풀에 넣었는데, 그 풀의 worker 를 같은 키를 기다리는 job 이 쥐고 있다. 계산은 job 이 비켜야 시작하고, job 은 계산이 끝나야 비킨다. 기다림 timeout 까지 아무것도 안 된다. 같은 키를 HTTP/2 는 요청 fiber 에서, HTTP/1 은 job 안에서 조회하는 곳이 셋 있어 실제로 생길 수 있다.

호출 지점마다 조회를 job 밖으로 옮기지 않는다. 중첩이 4단(briefing → projection → operator snapshot → Keeper 마다의 키)이고, 같은 수정을 열 곳 넘게 따로 해야 한다. `Dashboard_cache` 한 곳에서 고친다.

- 옛 값이 없는 `Computing` 칸에 claim 과 결과 promise 를 둔다. claim 은 넷 중 하나다: 아무도 안 맡음, owner job 이 맡음, 기다리던 job 이 맡음, 버려짐(`Abandoned`). 계산 자체는 칸에 두지 않는다. 맡는 쪽은 자기 compute 를 돌린다. 같은 키는 같은 값을 만든다는 것이 캐시의 약속이다. 호출자마다 payload 준비 방식이 달라도 캐시는 지금도 먼저 계산한 쪽의 준비 방식으로 값을 두고, 다른 방식이 필요한 읽기는 그 자리에서 만든다(`force_cached_payload`). owner 의 계산을 대신 돌리면 owner 요청의 switch 같은 자원을 owner 가 취소된 뒤에도 쓰게 된다.
- 계산을 돌린 쪽이 결과를 owner 의 token 으로 칸에 쓰고 promise 를 푼다. owner job 이 돌렸든 기다리던 job 이 돌렸든 같다. 실패하면 칸을 지우고 promise 를 푼다: 계산이 예외를 내면 `Failed`, 취소되거나 자기 window 가 닫히면 `Released`.
- owner 는 자기 job 을 넣고, 그 job 과 결과 promise 를 함께 기다린다. job 은 시작할 때 claim 을 잡아야 계산하고, 못 잡으면 바로 끝나 worker 를 내놓는다. 결과가 먼저 정해지면 owner 는 바로 돌아오고, 아직 줄에 있던 job 은 시작 전에 취소된다.
- 풀 job 안의 조회가 `Wait` 를 만나고 claim 이 비어 있으면(owner 계산이 아직 줄에 있으면) 잡고, 자기 compute 를 이미 쥔 worker 에서 돌린다. 자리를 더 쓰지 않는다. 기다리던 job 들은 칸이 비면 지금처럼 직접 계산한다.
- claim 이 잡혀 있으면(계산이 도는 중이면) 지금처럼 기다린다. worker 를 쉬게 쥐는 시간은 그 계산 시간을 넘지 않는다. 요청 fiber 의 기다림은 worker 를 쓰지 않으므로 그대로 둔다.
- owner 가 받는 것: `Failed` 면 그 실패를 그대로 받는다. `Released` 면 실패하지 않고 키를 다시 조회한다. 다른 요청이 취소된 것 때문에 owner 가 실패하지 않게 하려는 것이다. 다시 조회해도 owner 의 window 는 새로 열리지 않는다. 한 조회의 window 는 처음 정한 마감 시각 하나이고, 다시 하는 시도는 남은 시간만 쓴다. 기다림 예산도 처음부터 센다.
- owner 의 window 가 닫히는 순간 결과가 `Published` 로 정해져 있으면, timeout 대신 그 값을 돌려준다. 두 일이 같은 scheduler 차례에 일어나면 Eio 는 이긴 쪽 값을 버리고 취소로 끝낸다.
- 맡는 job 은 무게 1.0 job 만이 아니다. IO 무게(0.05) job 안의 조회도 맡을 수 있고, 그러면 CPU 계산이 0.05 자리에서 돈다. owner 가 IO job 안에서 바로 계산하던 지금과 같은 성질이다.
- owner 가 먼저 포기하면(취소, window 닫힘) 아무도 맡지 않은 계산은 `Abandoned` 로 막고 칸을 지운다. 그 뒤에는 누구도 이 claim 을 잡지 못한다. 이미 맡은 계산은 맡은 쪽에 남긴다. 맡은 쪽이 끝나면 칸에 쓰므로, 다음 조회가 같은 키를 다시 계산하지 않는다. owner job 이 맡았다면 그 job 은 owner 와 함께 취소되고, 나가면서 칸을 지운다.
- 같은 키 계산은 한 epoch 에 한 번만 돈다. claim 은 한 번만 잡힌다.
- 맡기는 키 사이에 새 기다림을 만들지 않는다. 맡은 쪽은 그 키의 owner 가 돌렸을 계산을 돌리므로, 그 안에서 기다리는 키도 owner 가 기다렸을 키와 같다. 그래서 서로 기다리다 멈추지 않는 조건은 지금과 같다: 캐시 키의 의존이 고리가 없어야 한다. 조사한 중첩은 한 방향이다. 질의 키 → 화면 키(briefing·mission·mission_briefing·workspace·execution) → projection(snapshot·digest) → operator snapshot → Keeper 마다의 키. 맨 아래 키의 계산은 다른 캐시를 조회하지 않는다. 계산이 자기 키를 다시 조회하면 지금처럼 timeout 까지 멈춘다.
- Eio 밖(systhread 등)에서 만든 칸에는 claim 을 두지 않는다. 그 owner 는 promise 를 기다릴 수 없다.
- `Operator_control_snapshot_cache` 도 job 안에서 기다리지만 owner 가 계산을 풀에 넘기지 않고 자기 fiber 에서 바로 한다. 기다리는 job 은 도는 계산을 기다리므로 꼬이지 않는다. L4b 범위 밖이다.

검증: `specs/bug-models/DashboardCacheClaim.tla`. clean 모델(worker 1·2개)은 `NoInversion`, `AtMostOneRunner`, `ClaimHasRunner`, `ClaimantKeepsSlot` 와 liveness 둘(맡은 계산은 결국 Ok·Failed·Released 가 된다 `ClaimSettles`, 기다리는 owner 는 결국 돌아온다 `OwnerReturns`)을 지킨다. 버그 모델 넷은 각각 깬다: 기다리기만 함(L4b 전 코드) → `NoInversion`(그리고 `OwnerReturns`), owner job 이 claim 을 무시 → `AtMostOneRunner`, 맡은 쪽이 실패하고 결과를 안 풂 → `ClaimHasRunner`(그리고 `ClaimSettles`), 포기한 owner 가 맡긴 칸을 지움 → `ClaimantKeepsSlot`. 시험(`test/test_dashboard_cache_claim.ml`)은 worker 1~2개로 짠다: 줄 선 계산을 기다리던 job 이 맡음, owner 는 자기 job 이 줄에 있어도 결과가 나오면 돌아옴, 진 owner job 은 계산 안 함, 맡은 쪽 실패는 키를 비우고 owner 를 실패시킴, 맡은 쪽 취소는 owner 가 다시 조회해 계산함, 포기한 owner 는 맡은 쪽 칸을 남김, 맡은 쪽은 새 epoch 에 쓰지 않음, 풀 밖 조회는 맡지 않음, 도는 계산은 기다림, 아무도 안 맡았을 때 포기한 owner 는 키를 비움, 맡은 쪽 window 가 닫히면 owner 가 계산함, 다시 조회해도 owner window 안에서 끝남. 모델에 없는 것: window 와 결과가 같은 차례에 정해지는 경우, 다시 조회(새 epoch), owner 자신이 풀 job 인 경우, IO 무게 job.

### 3.5 domain 예산

프로세스 전체를 RFC-0474 L1 의 예산 `Domain.recommended_domain_count () - 1`(이 장비 15) 안에 넣는다. 크기를 정하는 곳은 `Domain_budget.plan` 하나다.

| domain | RFC-0474 L1 전 | L1 | L3(이 RFC) |
|---|---:|---:|---:|
| main | 1 | 1 | 1 |
| snapshot codec | 1 | 1 | 1 |
| system-thread host(#46342) | 1 | 1 | 1 |
| 읽기 풀 | 0 | 0 | 2 |
| 배경 풀 | 14 | 10 | 8 |
| agent_core codec 풀 | 14 | 2 | 2 |

- 읽기 풀 크기는 L2 를 운영 서버에 배포해 잰 값으로 정한다. 읽기가 기다리는 계산도 읽기 풀에서 돈다. 빈 캐시를 채우는 계산(3.4)이 그렇다. 그래서 크기는 부하 상태의 `pool_wait.read` 의 `run`(계산 길이)·`wait`·`abandoned` 분포와 동시에 들어오는 읽기 수로 정한다. 기다리지 않을 때의 핸들러 시간(1.1절 `limit=1` 최소 4 ms)은 근거가 되지 않는다. 목표가 재는 것은 기다릴 때의 읽기다(#46374 리뷰).
- 2026-10-27 14:16~14:18Z 운영 서버(배경 풀 6, load 15~21) 120초 창: 읽기 173건, 대기 평균 50.3 ms(p99 1~2초 구간), 실행 평균 73.8 ms, abandoned 0. 읽기가 쓰는 worker 는 평균 0.11개이고, M/M/c 로 보면 1개일 때 약 11%, 2개일 때 약 0.5% 가 기다린다. 실행 시간 꼬리가 길어(p99 2~5초) 어림값이다. 그래서 2개다.
- 배경 풀은 `max 1 (recommended - 1 - 고정 - 읽기 - codec)` 이다. 같은 창에서 배경 작업은 worker 를 평균 1.6개 썼다. 자리가 모자라면 codec 이 먼저 1로, 그다음 읽기 풀이 1로 줄어 배경 풀이 2개를 지킨다. `MASC_EXECUTOR_DOMAIN_COUNT` 는 지금처럼 배경 풀 크기를 정하고, 예산을 넘으면 부팅 때 거부한다.
- agent_core codec 풀은 배경 풀과 합치지 않는다. 지금 `run_cpu` 는 호출자가 취소되면 worker 를 기다리지 않고 `Caller_cancelled`·`Runtime_released` 를 원자 변수로 알린다. masc 의 `Executor_pool_submission.submit` 은 worker 를 취소하고 `Cancel.protect` 아래에서 끝나기를 기다린다. 합치면 이 의미가 바뀌고, Keeper 실행 기록 쓰기(`writer_gate` 를 잡은 채 하는 비교)가 배경 FIFO 뒤에 선다. 크기만 예산 안으로 줄인다. 지금 `Execution_runtime.stats` 는 호출 횟수(`pool_requested`, `reentrant_inline`, `caller_cancelled`)만 세서 크기를 정하기에 모자란다. L5 에서 제출부터 시작까지의 대기와 실행 시간을 재서 `/health` 에 싣고, 그 값으로 정한다.
- 출처를 모르는 domain 1개는 L3 에서 찾는다.
- system-thread host 는 #46342 가 더한 domain 이다. main domain 에서 부르던 Curator·Librarian 의 systhread 를 여기서 시작한다. lock 이 하나라 OCaml 로는 최대 한 코어를 쓴다. 10-27 15:25 운영 sample 에서 옮길 일이 이미 약 1.2 코어를 썼다(#46342 리뷰). 배포 뒤 이 domain 이 얼마나 바쁜지 runtime events 의 domain 번호로 같이 잰다. 배경 풀 크기 계산에는 아직 넣지 않았다. 그 계산은 L3 의 `shared_domain_count_beside_read` 가 한다.

### 3.6 풀 대기 시간을 잰다

지금은 제출부터 worker 가 시작할 때까지를 재는 곳이 없다. `Executor_pool_submission.submit` 에서 그 시간을 lane 별 고정 구간 히스토그램(Atomic 카운터)에 넣고 `/health` 에 싣는다. 이 계측만으로 고쳐지는 것은 없다. 고친 뒤 효과와 남은 대기를 나눠 보려는 것이다.

기다리다 취소된 제출(데드라인, HTTP/2 연결 끊김)은 lane 별 `abandoned` 히스토그램에 따로 센다. L3 진행 판단은 `wait` 와 `abandoned` 를 함께 본다.

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
- 읽기가 fork 한 `Dashboard_cache` SWR 재계산은 배경 풀에서 돈다. 캐시가 비어 읽기가 기다리는 계산은 읽기 풀에서 돈다.

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
| L2 | `Pool_lane` 표시(풀 선택은 그대로), `Server_bootstrap_http` 의 GET/HEAD 표시(HTTP/1·HTTP/2), lane 별 풀 대기·실행 히스토그램을 `/health` 에 싣기 | 5.2 의 표시 시험, 히스토그램 구간 경계 |
| L3 | 읽기 풀 생성과 domain 예산, 제출 함수 네 개의 풀 선택, 출처 모를 domain 찾기. L2·L4a·L4b 를 배포해 잰 뒤에 따로 머지한다 | 5.1, 5.2 의 풀 선택 시험 |
| L4a | 요청이 기다리지 않는 배경 갱신 fork 의 lane(3.4) | 5.2 의 캐시 시험 |
| L4b | 줄 선 캐시 계산을 기다리는 job 이 맡는다(3.4 L4b) | TLA+ claim 모델, 3.4 L4b 시험 넷 |
| L5 | codec 풀의 대기·실행 시간을 `/health` 에 싣고 그 값으로 크기 정하기 | 예산 합이 코어 수 이하 |
| L6 | 수용 측정 기록, status 갱신 | 5.3 |

L3 를 L4 보다 먼저 넣으면 안 된다. 읽기 풀은 1~2 domain 이다. 요청이 fork 한 SWR 재계산(계산 예산 8~120초)이 Read 로 그 domain 을 다 쓰면 다른 GET 이 그 뒤에 선다. 그 대기는 compute timeout 에 들어가 circuit 을 열 수 있다. 풀 job 안의 `Dashboard_cache` `Wait` 도 읽기 worker 를 붙잡는다. 앞의 것은 L4a(#46385), 뒤의 것은 L4b 가 고친다(#46374 독립 리뷰).

10-27 에 L3 를 스택에서 빼고 L1→L2→L4a→L4b 를 먼저 넣기로 했다. #46374 리뷰가 읽기 풀 크기의 근거가 없다고 짚었기 때문이다. 읽기가 기다리는 빈 캐시 계산 둘이 읽기 풀 2개를 잡으면 다른 읽기가 초 단위로 선다. L4a·L4b 는 L3 없이도 쓸모가 있다. L4a 는 읽기가 fork 한 배경 갱신을 `pool_wait` 의 background 로 세어 L2 의 read 값을 깨끗하게 한다. L4b 는 풀이 하나여도 job 이 자기 뒤에 줄 선 계산을 기다려 둘 다 멈추는 일을 푼다.

계측(L2)을 맨 앞에 둔다. 1.1절 수정 후 측정에서 공유 풀은 6초 sample 동안 쉬고 있었고, main domain 의 lock 대기가 더 컸다. L2 로 운영 서버의 풀 대기를 한 시간 재서, 읽기의 풀 대기 p99 가 목표(100 ms)를 넘을 때 L3 이후를 진행한다. 넘지 않으면 L3 이후는 보류하고 main domain 쪽을 먼저 고친다.

## 7. 위험

- **읽기끼리 기다린다.** 무거운 GET 이나 읽기가 기다리는 빈 캐시 계산이 읽기 풀을 다 쓰면 가벼운 GET 이 기다린다. L2 계측으로 본다. 읽기 하나가 저장소 크기만큼 커지는 경우는 RFC-0372 로 고친다. domain 을 늘려서 덮지 않는다.
- **포기된 요청이 자리를 잡고 있다.** HTTP/1 핸들러는 연결의 읽기 루프를 막고 돈다. 클라이언트가 timeout 으로 떠나도 서버 job 은 취소되지 않고 읽기 풀 자리를 끝까지 쓴다. 지금도 같은 일이 공유 풀에서 일어난다. 취소는 RFC-0372 의 요청 단위 기한과 같이 다룬다.
- **배경 작업과 같은 lock.** 읽기 핸들러가 배경 작업이 쥔 store lock 을 기다리면 풀을 나눠도 느리다. 이때는 풀 대기는 짧고 핸들러 시간이 길게 나온다. L2 계측으로 구분한다.
- **배경 갱신이 늦어진다.** L4a 뒤 SWR 재계산은 L3 로 줄어든 공유 풀에서 기다린다. `compute_under_timeout` 은 풀 대기 시간도 세므로, 공유 풀이 밀리면 재계산이 `Compute_timeout` 으로 끝나는 일이 는다. 그때 `Dashboard_cache` 는 옛 값을 TTL 의 6배(stale 3배 × backoff 2배) 동안 신선한 값으로 다시 쓴다. L3 전에도 같았지만 풀이 더 컸다. 배포 뒤 `pool_wait.background.wait` p99 를 재계산 예산과 비교한다.
- **배경 처리량.** 배경 풀이 줄어든다. 지금은 domain 30개가 16코어를 나눠 쓰고 있어서 실제로 쓰는 코어 수는 줄지 않을 것으로 본다. Librarian pass 시간(`durable Librarian inventory validated: ... elapsed_ms=`)을 배포 전후로 비교한다.
