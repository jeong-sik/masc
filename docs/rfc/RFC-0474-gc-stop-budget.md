---
rfc: "0474"
title: "GC 정지를 줄인다: domain 예산 하나, 런타임을 놓는 해시, 다시 검증하지 않는 원본"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: vincent
related: ["0204", "main-domain-scheduler-latency", "0239", "46390"]
---

# RFC-0474 — GC 정지를 줄인다

## 0. 요약

TUI 의 `Pool.request: timeout`(10초)이 계속 난다. 2026-10-27 에 runtime events 로 재 보니, 서버 domain 들은 GC 가 실제로 일한 시간보다 다른 domain 을 기다린 시간이 16~26배 길었다.

원인은 셋이다. 셋 다 OCaml 매뉴얼, Eio 문서, OCaml 5.5 런타임 소스로 확인했다.

1. domain 이 코어보다 많다. 서버는 16코어에서 domain 31개를 띄웠다. 그중 agent_core 실행 풀 14개는 거의 놀았는데, GC 정지마다 장벽에 가장 늦게 왔다.
2. digestif 의 문자열 해시는 런타임을 놓지 않는다. 큰 본문을 해시하는 동안 다른 모든 domain 이 GC 장벽에서 기다린다.
3. 같은 원본을 계속 다시 검증한다. Librarian 이 원본 요청 본문을 읽을 때마다 해시·파싱·정규화·재직렬화를 처음부터 한다. 이 큰 문자열이 major heap 에 바로 쌓이고, 쌓일 때마다 모든 domain 에 major slice 를 시킨다.

이 RFC 는 네 층으로 고친다. 층마다 같은 계기(§8)로 전후를 잰다.

| 층 | 내용 | 성공 기준 |
|---|---|---|
| L1 | domain 예산 하나: 프로그램 전체 domain 수를 `Domain.recommended_domain_count () - 1` 이하로 묶는다 | 링 수(domain 수)가 15 이하. 놀던 domain 이 늦게 온 STW 비율이 절반 이하 |
| L2 | 런타임을 놓는 해시: sha256 을 core 함수 하나로 모으고, 큰 입력은 런타임을 놓는 경로로 보낸다. 직접 `Digestif.SHA256` 호출을 막는 검사를 둔다 | `Digestif.SHA256` 직접 참조 0. CPU 표본의 `sha256_do_chunk` 몫이 절반 이하. `stw_api_barrier` p99 가 절반 이하 |
| L3 | 원본을 다시 검증하지 않는다: digest 로 이름 붙은 본문은 처음 읽을 때 한 번만 검증한다 | memprof major 에서 `request_of_body` 몫이 5% 이하. 1초 넘게 양보하지 않는 `addon-original-request-read` fiber 가 0 |
| L4 | Executor weight 를 job 이 실제로 하는 일에 맞춘다: 파싱·해시를 하는 job 은 맨 바깥 제출에서 CPU weight 로 넣고, I/O 만 기다리는 job 에 남은 블로킹 호출은 systhread 로 옮긴다 | 같은 domain 수에서 `pool_wait.background` wait·run p90 이 RFC-0204 L3 직후보다 낮다 |

## 1. 2026-09-05 RFC 이후 무엇이 바뀌었나

[RFC-main-domain-scheduler-latency](RFC-main-domain-scheduler-latency.md) 는 같은 링 버퍼로 GC 를 재고 "100 ms 넘는 지연은 GC 로 만들 수 없다"고 결론 냈다. 그때 domain 하나가 GC 에 쓴 시간은 1.4% 였다. 지금은 그 결론이 맞지 않는다.

| | 2026-09-05(15 domain) | 2026-10-27, 31 domain | 2026-10-27, 15 domain |
|---|---|---|---|
| 초당 할당 | 77~200 MB | 약 1.2 GB | 약 1.2 GB |
| `stw_handler` 합, 60초당 | 5.8 s | 40.8 s | 22.1~30.2 s |
| `minor_leave_barrier` 합, 60초당 | 4.4 s | 28.4 s | 11.9~24.5 s |

바뀐 것은 둘이다. 초당 할당이 6~15배 늘었다(§3.5). agent_core 실행 풀이 생겨 domain 수가 두 배가 됐다(§3.1).

## 2. 문서와 런타임 소스가 말하는 것

모두 2026-10-27 에 읽었다. 버전은 OCaml 5.5.1, eio 1.3, digestif 1.3.0 이다.

**domain 수**
- OCaml 매뉴얼 [Parallel programming](https://ocaml.org/manual/5.4/parallelism.html): "It is recommended that programs do not spawn more domains than the number of available cores." 같은 문서: "When a domain exhausts its minor heap arena, it calls for a stop-the-world collection of the minor heaps."
- Eio `Executor_pool` 문서: "The total number of domains should not exceed `Domain.recommended_domain_count` or the number of cores on your system. Additionally, consider reducing this number by 1 if your original domain will be performing CPU intensive work". 같은 문서는 풀을 보통 프로그램에 하나 만든다고 한다.
- 런타임 `runtime/domain.c`(5.5) `stw_wait_for_running`: "The STW leader issues interrupts to all domains, then they all arrive into this barrier, with the last one releasing it". 같은 파일: domain 은 STW 요청에 "poll points" 와 blocking section 의 "backup thread" 로만 응한다.
- 이 Mac 의 `Domain.recommended_domain_count ()` 는 16 이다. 5.5 소스에서 이 값은 온라인 CPU 수다. 효율 코어 4개를 포함하고, 다른 프로세스의 부하는 보지 않는다.
- 보조 자료(포럼·블로그, 공식 문서 아님):
  - [discuss.ocaml.org #11233](https://discuss.ocaml.org/t/parallel-performance-of-an-ocaml-program-ocaml-5-0-0-vs-4-13-1/11233)(5.0). gasche: "the OS may deschedule one of the domains, and everyone will be blocked for two/three orders of magnitude longer". kayceesrk: "we are not testing under over-committed environments". 이 호스트는 load 20~150 이다.
  - T. Leonard, [Performance 2](https://roscidus.com/blog/blog/2024/07/22/performance-2/)(5.2): "An idle domain requires a syscall to wake it, and often causes all the other domains to sleep waiting for it."

**weight**
- Eio `Executor_pool` 문서: weight 는 "the anticipated proportion of a CPU core used by the job". 예시: "given an IO-bound job that averages 2% of a CPU core, pass `~weight:0.02`". "Each domain worker starts new jobs until the total `~weight` of its running jobs reaches 1.0".
- masc 의 I/O 제출(`Domain_pool_ref.submit_io_or_inline`)은 weight 0.05 라서 worker 하나가 이런 job 을 20개까지 받는다. CPU 제출(`submit_cpu_or_inline`)과 `Executor_pool_ref.submit_or_inline` 은 1.0 이다. 바깥 job 안에서 다시 제출하면 바깥 job 의 weight 로 바로 돈다(`dashboard_cache.ml` 의 `produce` 는 1.0).

**C 코드와 해시**
- 매뉴얼 [Interfacing C](https://ocaml.org/manual/5.4/intfc.html) §12.2: "If a C primitive runs for a long time or performs potentially blocking input-output operations, it can explicitly release the domain lock". 같은 문서 §5.3: `caml_process_pending_actions` 를 "regularly at safe points inside long-running non-blocking C code" 부르라고 권한다.
- digestif 1.3.0 소스(`src-c/native/stubs.c`, `src-c/digestif_native.ml`): `digest_string`·`feed_string` 은 `[@@noalloc]` 인 `caml_digestif_sha256_st_update` 를 버퍼 전체에 한 번 부른다. 이 함수는 런타임을 놓지 않는다. bigstring 경로(`_ba_update`)는 `caml_enter_blocking_section` 으로 감싼다.
- masc 는 이미 한 곳에서 이 문제를 겪었다. `lib/keeper_checkpoint_ref/keeper_checkpoint_ref.ml` 주석: 13~109 MB checkpoint 를 한 번에 해시하는 동안 다른 domain 이 minor GC 장벽에서 기다렸다. 그 파일만 1 MB 씩 잘라 넣는다. 나머지 `Digestif.SHA256` 직접 참조는 351곳(lib·packages)이다.

**큰 할당**
- 런타임 `runtime/memory.c`(5.5) `alloc_shr`: major heap 에 바로 할당한 양이 `minor_heap_wsz / 5` 를 넘으면 `caml_request_major_slice(1)` 을 부른다. `runtime/domain.c` `caml_poll_gc_work` 가 이 요청을 `caml_try_run_on_all_domains_async(&stw_global_major_slice, …)` 로 모든 domain 에 돌린다.
- `Max_young_wosize` 는 256 워드라서 2 KB 를 넘는 블록은 major heap 으로 바로 간다. minor heap 이 4M 워드(32 MB)면 문턱은 domain 하나당 약 6.4 MB 다.

## 3. 오늘 잰 것

서버는 `387655e5165` 다. 측정 방법은 §8 에 있다.

### 3.1 domain 31개의 구성

| 만드는 곳 | 수 |
|---|---|
| 메인 | 1 |
| `Domain_pool`(`lib/core/domain_pool.ml`, 기본값 `recommended_domain_count - 2`) | 14 |
| agent_core `Execution_runtime`(`packages/agent_core/lib/execution_runtime.ml:87`, `Server_runtime_bootstrap` 이 `Domain_pool.domain_count` 를 그대로 넘김) | 14 |
| `Systhread_host` | 1 |
| `Keeper_event_queue_snapshot_codec`(`domain_count:1`) | 1 |

`Execution_runtime.mli` 는 "The caller … selects [domain_count] from its single host resource policy" 라고 적는다. 지금 서버는 같은 값을 두 풀에 따로 주어서 예산을 두 배로 썼다.

### 3.2 domain 수 A/B — 같은 빌드, 60초 창

`MASC_EXECUTOR_DOMAIN_COUNT=6` 으로 재기동하면 두 풀이 6개씩 쓰고 전체는 15개다.

| | 31 domain(19:39, load 26) | 15 domain(19:48, load 25) |
|---|---|---|
| STW minor 횟수 | 11.1/s | 10.7/s |
| 장벽 대기 합(`minor_leave_barrier`+`stw_api_barrier`+`interrupt_remote`) | 43.0 s | 24.3 s |
| `stw_handler` 합 | 40.8 s | 22.1 s |
| 실제 minor 작업(`minor`) | 1.5 s | 1.5 s |
| `pool_wait` read 평균 wait / run | 18.3 / 44.3 ms | 27.5 / 6.8 ms |
| `pool_wait` background 평균 wait / run | 47.5 / 89.7 ms | 53.7 / 57.9 ms |
| p90 / p99, `gate/keepers?detailed=true` | 5.8 / 2,738 ms | 19.4 / 231 ms |
| p90 / p99, `operator` | 18.3 / 870 ms | 30.6 / 1,967 ms |

장벽 대기는 44% 줄고 job 실행은 빨라졌다. 대신 worker 가 14에서 6으로 줄어 p90 이 늘었다. L1 은 같은 15개 안에서 공유 풀에 10개를 준다(RFC-0204 L3 의 읽기 풀이 들어가면 8개). L4 는 CPU job 이 한 domain 에 몰리지 않게 한다.

### 3.3 장벽에 가장 늦게 온 domain

`rtev_watch` 60초(21:52, 15 domain). STW 12,975번 중 7,929번(61%)은 domain 14가 가장 늦게 왔다. domain 9~14 는 같은 창에서 fiber 실행이 0.0% 인 domain 이다. 수로 보아 agent_core 실행 풀 6개다(추정: domain 번호와 풀의 대응은 생성 순서로만 맞췄다). 쉬던 domain 이 `Condition.wait` 에서 깨어나는 동안 다른 domain 이 모두 기다린다. Leonard 블로그의 설명과 같다.

### 3.4 풀에서 오래 도는 일

`rtev_fibers` 60초(같은 창). domain 2~7(masc 풀) 은 17~33% 바빴다. 양보하지 않고 가장 오래 돈 실행 상위 40개는 모두 이 domain 들에 있다. 그중 25개는 `addon-original-request-read` 를 앞이나 뒤에 두고, 나머지는 같은 domain 의 `fstat` 사이 실행이다. 가장 긴 것은 4.58초(`addon-original-request-read` → `fstat`)이고, 1초 넘는 21개 중 10개가 `addon-original-request-read` 를 낀다. worker 하나가 이런 일을 하는 동안 그 worker 는 읽기 요청을 받지 못한다.

### 3.5 큰 문자열은 어디서 오나

memprof(`/api/v1/diagnostics/memprof`, 부팅 뒤 10분). 할당 757 GB, major 493 GB 중 95% 가 바로 major 로 간 큰 할당이다.

| major 몫 | 할당하는 곳 | 부르는 곳 |
|---|---|---|
| 13.7% | `Lane_addon_tool_request_owner.request_of_body` | `Keeper_librarian_original_gate.read_chain_with` |
| 5.7% | `Lane_addon_store.record_bytes` | 본문 읽기 |
| 4.6% | `request_of_body` | systhread |
| 3.8% | `request_of_body` | `original_gate.root_preparation_with` |
| 2.8% | `request_of_body` | `durable_commit.publish_with` |
| 2.0% | `request_of_body` | `original_gate.validate_root_preparation` |
| 2.0% | `request_of_body` | `original_gate.restore_size_evidence` |
| 1.5% | `Keeper_chat_store.provenance_of_line` | `append_lines_once` |

`request_of_body` 는 본문을 읽을 때마다 sha256 전체, `Yojson.Safe.from_string`, `Lane_addon_action.canonical`, `Yojson.Safe.to_string` 후 바이트 비교를 한다. 원본은 digest 로 이름 붙은 바뀌지 않는 데이터인데, 한 pass 안에서 여섯 경로가 같은 본문에 이 일을 각자 다시 한다. macOS `sample` 의 CPU leaf 도 같은 말을 한다: `sha256_do_chunk` 18%, `caml_lex_engine` 17%, `Yojson.Safe.write_string_body` 9%.

#46394 의 bench 로는 이미 읽은 대화가 1 MB 일 때 Librarian pass 하나가 1.51 GB 를 할당한다.

### 3.6 운영자가 보는 증상

같은 TUI 하나(`masc-tui-58664`)의 `Pool.request: timeout` 횟수다.

| 서버 | TUI 가 돈 시간 | timeout | 시간당 |
|---|---|---|---|
| 31 domain(19:36~19:41) | 5분 | 3 | 36 |
| 15 domain(19:46~20:17) | 31분 | 1 | 1.9 |

31 domain 쪽은 5분이고 TUI 가 막 켜진 뒤라 배수는 믿기 어렵다. 방향은 분명하다.

## 4. 설계

### L1 — domain 예산 하나

- `Domain_pool` 은 프로그램 전체 예산 `budget = Domain.recommended_domain_count () - 1` 을 정한다. 1을 빼는 것은 메인 domain 이 CPU 일을 하기 때문이다(Eio 문서).
- 고정 domain(메인, `Systhread_host`, `Keeper_event_queue_snapshot_codec`)을 빼고 남은 수를 풀들이 나눈다. agent_core 실행 풀은 masc 가 이미 가진 예산에서 받는다. 같은 수를 따로 주지 않는다.
- agent_core 실행 풀은 2개짜리 별도 풀로 둔다(#46462). 6개일 때 60초 동안 fiber 를 하나도 돌리지 않았다(§3.3). 합치지 않는 이유는 RFC-0204 §3.5 에 있다. 취소 의미가 다르다.
- RFC-0204 L3 의 HTTP 읽기 풀(#46374)도 이 예산의 한 줄이다. 2개를 공유 풀 몫에서 뗀다. 16코어에서는 고정 3 + codec 2 + 읽기 2 + 공유 8 = 15 다. 자리가 모자라면 codec 이 먼저 1로, 그다음 읽기 풀이 1로 줄어, 공유 풀이 2개를 지킨다. 같은 운영 창에서 배경 작업은 worker 를 평균 1.6개, 읽기는 0.11개 썼다.
- `MASC_EXECUTOR_DOMAIN_COUNT` 는 masc 풀 크기를 정하는 값으로 남기고, 예산을 넘는 값은 부팅 때 거부한다. 지금 운영 중인 `=6` 은 L1 이 들어가면 필요 없다.

### L2 — 런타임을 놓는 해시

- `lib/core` 에 sha256 모듈 하나를 둔다. 문자열 입력은 정해진 크기로 잘라 `feed_string` 에 넣는다. 조각 사이에 OCaml 로 돌아오므로 STW 대기는 조각 하나 길이를 넘지 않는다. 파일과 큰 버퍼는 bigstring 으로 읽어 `feed_bigstring` 에 넣는다. 이 경로는 런타임을 놓는다.
- 조각 크기는 잰 값으로 64 KiB 로 정한다. 2026-10-27 이 Mac(M3 Max)에서 digestif 1.3.0 sha256 은 문자열·bigstring 경로 모두 약 280 MB/s 였다. 한 번에 해시하는 시간은 64 KiB 0.24 ms, 256 KiB 0.99 ms, 1 MiB 3.7 ms, 16 MiB 59 ms 다. `keeper_checkpoint_ref` 주석의 13~109 MB checkpoint 를 한 번에 해시하면 46~390 ms 이고, 이는 §3.2 창의 `stw_api_barrier` 최대값(302~392 ms)과 같은 크기다. 지금의 1 MiB 조각도 정지 하나에 3.7 ms 를 남긴다. 64 KiB 면 0.24 ms 다.
- 같은 digest 를 내는 더 빠른 구현(ARMv8 SHA 명령을 쓰는 것)으로 바꾸면 CPU 표본의 18% 자체가 줄어든다. 이것은 모듈 하나로 모은 뒤 그 안에서만 바꿀 수 있으므로 L2 다음 일로 둔다. digest 값이 같으므로 저장 형식은 바뀌지 않는다.
- 351곳을 한 PR 에서 이 모듈로 옮긴다. `keeper_checkpoint_ref` 의 자르기도 이 모듈로 합친다.
- `Digestif.SHA256` 을 이 모듈 밖에서 부르면 실패하는 소스 검사를 둔다. 한 곳씩 고치면 같은 문제가 다시 생긴다.

### L3 — 원본을 다시 검증하지 않는다

- Librarian 원본 쪽은 RFC #46390 과 그 구현 #46394(L2, 다시 확인할 때 digest 비교)·#46397(L3, 읽은 범위만 한 번)이 맡는다. 이 RFC 는 그 순서를 따른다.
- #46394 는 `durable_commit`·`durable_owner` 쪽 다섯 곳을 바꾼다. `original_gate` 의 네 경로(§3.5, 합 21.5%)는 바꾸지 않는다. #46397 이 들어간 뒤에도 이 넷이 남으면, 같은 원칙으로 고친다. 기록은 pass 마다 `Inventory` 로 한 번 읽고, 다시 확인할 때는 digest 를 비교한다.
- Librarian 밖에서는 둘을 고친다.
  - `Keeper_chat_store.append_lines_once` 는 줄을 붙일 때마다 `Fs_compat.update_private_file_durable_locked_result` 로 파일 전체를 읽고, 모든 줄을 파싱해 provenance 색인을 만든다. 이 경로가 쓰는 것은 새 줄 묶음(`Some payload`)뿐이라 파일 끝에 붙는다. 그래서 마지막으로 색인한 위치 뒤만 읽으면 된다. 같은 파일을 다시 쓰는 다른 writer 가 있는지는 L3 PR 에서 모든 writer 를 읽고 정한다. 끝부분만 읽는 `update_private_file_tail_durable_locked_result ~max_bytes` 가 이미 있다.
  - `Keeper_approval.Audit.read_recent` 는 최신 줄부터 읽다가 n개를 찾으면 멈춘다. 그러나 keeper 이름으로 거를 때는 그 Keeper 의 줄이 n개 모일 때까지 다른 Keeper 의 줄도 모두 JSON 으로 디코드한다. 대시보드 Keeper 화면(`dashboard_http_keeper.ml:278`)이 부른다. memprof major 몫은 2.1% 다. Keeper 로 먼저 거른 뒤에 디코드한다.

### L4 — Executor weight 를 일에 맞춘다

2026-10-27 감사(코드 읽기, 공유 풀 제출 약 251곳): 순수 CPU 58곳, Eio·systhread I/O 39곳, domain 을 멈추는 블로킹 호출 55곳, CPU 와 블로킹이 섞인 곳 33곳, 끝까지 따라가지 못한 곳 61곳이다. 블로킹 55곳의 대부분은 `submit_io_or_inline`(0.05)으로 들어가거나, 1.0 인 `Dashboard_cache` job 안에서 돈다.

- weight 0.05 인 job 이 블로킹 호출을 하면 그 domain 에 함께 받아 둔 job 이 모두 멈춘다. 예: `Dated_jsonl.off_fiber`(`dated_jsonl.ml:555`)는 `submit_io_or_inline` 으로 넣고, 그 안에서 Stdlib 채널로 `seek_in`·`really_input` 을 한 뒤 스캔과 파싱을 한다. 주석도 "the reads are blocking syscalls, the scan and the parse are CPU work" 라고 적는다. `Fs_compat.read_slice`(`fs_compat.ml:2039`)도 호출 domain 에서 `open_in_bin` 한다.
- eio_posix(`lib_eio_posix/low_level.ml`)는 openat·fstat·readdir·mkdir·unlink·rename 을 systhread(`in_worker_thread`)로 보내지만, 일반 파일 read 는 호출 domain 에서 `Unix.read` 로 바로 한다. 같은 파일 머리 주석이 이것이 "will block the whole domain" 할 수 있다고 적는다.
- Eio `Executor_pool` 문서는 weight 를 "job 이 쓸 것으로 보는 CPU 코어 몫"이라 하고, worker 는 돌고 있는 job 의 weight 합이 1.0 이 될 때까지 새 job 을 시작한다고 적는다. 소스(`executor_pool.ml` `run_worker`)를 보면 worker 는 job 을 fork 하고, 그 job 이 Eio 효과에서 멈출 때 다음 job 을 가져간다. 그래서 weight 는 job 이 멈추는 순간에만 의미가 있다. Stdlib 채널 읽기처럼 Eio 효과가 없는 블로킹은 job 을 멈추지 않으므로 그동안 새 job 도 받지 않는다.
- 이것 때문에 블로킹 읽기를 systhread 로 옮기는 것만으로는 0.05 job 이 나빠진다. systhread 에서 기다리는 동안 job 이 멈추고, 그 domain 이 job 을 더 받는다. 읽기가 끝나면 받아 둔 job 들의 파싱이 그 domain 하나에서 차례로 돈다. `Fs_compat.file_exists` 처럼 `Eio.Path.stat` 를 거치는 호출도 같은 지점을 만든다.
- 바깥 job 안에서 부른 제출은 그 자리에서 돈다(`in_worker_context`). 그래서 weight 는 맨 바깥 제출이 정한다. `Dated_jsonl.off_fiber` 하나를 1.0 으로 바꿔도, 그것을 0.05 job 안에서 부르는 `keeper_api` 다섯 곳은 0.05 로 남는다. 몇 곳만 고치면 같은 문제가 다시 생긴다.
- 그래서 할 일은 둘이고, 순서가 있다.
  1. 파싱·해시를 하는 job 은 맨 바깥 제출에서 `submit_cpu_or_inline`(1.0)으로 넣는다. 감사 표의 (c)·(d) 중 읽은 뒤 파싱하는 곳(`Dated_jsonl` 을 부르는 job, `read_slice`·`fold_appended_lines` 뒤 파싱하는 job)이 대상이다.
  2. 그 뒤에도 I/O 만 기다리는 job 에 남은 블로킹 읽기·`fsync`·인라인 SQLite 는 systhread 로 옮긴다. 이 job 들만 weight 0.05 가 맞다.
- 읽기 풀(RFC-0204 L3)이 먼저 들어간다. 그 뒤에는 공유 풀의 weight 가 배경 작업끼리의 대기에만 영향을 준다. 그래서 L4 의 성공 기준은 `pool_wait.background` 로 잰다.

#### L4a — 읽기 풀이 차서 생긴 대기를 먼저 잰다

읽기 풀을 배포한 뒤(2026-10-27 17:20Z, `95e4e1d`) 읽기 대기 p99 는 1~2초 구간에서 200~500 ms 구간으로 내려왔다. RFC-0204 의 목표(100 ms)보다는 아직 높다.

- 같은 60초 창(18:37Z)에서 읽기 175건이 돈 시간의 합은 12.25초였다. 같은 창에서 읽기 풀 domain 둘이 fiber 를 돌린 시간은 2.16초였다. 읽기 worker 는 거의 놀았는데 읽기가 기다렸다.
- 가설: 읽기 계산은 대부분 `Executor_pool_ref.submit_or_inline` 의 기본 weight 1.0 으로 들어간다(`Dashboard_cache`, `run_dashboard_compute`). Eio worker 는 받아 둔 job 의 weight 합이 1.0 이 되면, 그 job 이 기다리고 있어도 새 job 을 받지 않는다. 그래서 1.0 읽기 두 개가 I/O 를 기다리면 domain 이 놀아도 다음 읽기가 줄을 선다.
- 가설만으로 weight 를 바꾸지 않는다. 독립 리뷰(#46483)가 짚었듯 0.18 은 읽기 lane 전체(0.05 로 들어가는 `submit_io_or_inline` 35곳 포함)를 잰 값이다. 기본값이 바뀌는 job 은 `dashboard_snapshot.ml` 이 "CPU-heavy" 라 부르는 계산이다. 낮은 weight 를 주면 위에 적은 대로 멈춘 job 의 domain 에 job 이 더 쌓인다. 같은 domain 의 systhread 가 쓴 CPU 는 fiber 시간에 잡히지 않는다.
- 그래서 먼저 잰다. `Pool_wait` 가 lane 마다 진행 중인 job 의 weight 합(Eio 와 같은 백만분의 1 단위)을 들고, 제출 순간의 값으로 대기를 0·1·2·3 이상 worker 몫으로 나눠 센다. 실행 시간은 선언한 weight 가 0.5 미만(0.05 I/O job)인지 이상(CPU job 과 1.0 기본값)인지로 나눠 센다.
- 판정: 배포 뒤 한 시간 동안 읽기 풀(worker 2)의 대기를 본다.
  - 2 worker 이상 진행 중일 때 들어온 읽기가 긴 대기의 대부분이면 가설이 맞다. 그때는 1.0 job 의 실행 시간과 읽기 domain 의 fiber 시간을 같은 창에서 비교해 weight 를 정한다.
  - 자리가 있을 때 들어온 읽기도 길게 기다리면 capacity 가 아닌 다른 원인이다(STW, domain 깨우기, systhread 가 잡은 domain lock).

#### L4a 결과 (2026-10-28 01:26~02:27Z, `448409b`)

읽기 2,406건을, 제출 순간 진행 중이던 weight 로 나눴다.

| 진행 중이던 몫 | 건수 | 평균 대기 | 100 ms 넘는 대기 |
|---|---|---|---|
| 0 worker | 1,551 | 0.8 ms | 4 |
| 1 worker | 717 | 17 ms | 17 |
| 2 worker 이상 | 138 | 2,221 ms | 80 |

- 100 ms 넘는 대기 101건 가운데 80건(79%)이 읽기 풀(worker 2)이 다 찼을 때 들어왔다. 가설이 맞다.
- 선언 weight 0.5 이상인 읽기 job 1,663건의 실행 시간 평균은 260 ms 다. 0.5 미만 743건은 65 ms 다.
- 이 창의 load 는 18~66 이었다. 다른 PR 의 빌드가 겹쳤다. 장벽 대기(minor_leave 19.0 s, stw_api 11.1 s / 60 s)와 TUI timeout 29건은 이 load 때문에 부풀었으므로, 전후 비교에 쓰지 않는다.
- eio_posix 는 경로를 여는 `openat` 과 경로를 묻는 `fstatat` 을 systhread 로 보낸다(`lib_eio_posix/low_level.ml` 23·361·467행). 그동안 job 은 promise 를 기다리며 weight 를 쥐고 있다. 2026-10-27 의 rtev_fibers 창에서도 읽기 domain 의 fiber 는 `Promise.await` 에서 멈췄다.

#### L4b — 읽기 lane 에서 weight 를 정하는 곳을 하나로

읽기 lane 에 들어가는 제출을 모두 따라가 봤다(2026-10-28, main `6d83e98`).

- `Dashboard_cache` 는 miss 와 만료된 항목의 계산을 `Executor_pool_ref.submit_or_inline` 으로 넣는다(`dashboard_cache.ml` 534·585행). weight 는 기본값 1.0 이다. 이런 계산 약 30곳이 GET 에서 읽기 lane 을 탄다. 대부분 파일 I/O 를 한다.
- 계산 쪽은 대개 안에서 `Domain_pool_ref.submit_io_or_inline`(0.05)을 부른다. `lib/dashboard`·`lib/server` 에 76곳이다. 예: `/dashboard/gate`(`server_dashboard_http.ml` 189~191행).
- 바깥 job 안의 제출은 그 자리에서 돈다(`executor_pool_ref.ml` 125행). 그래서 계산 쪽의 0.05 선언은 아무 말 없이 무시되고 1.0 이 남는다. weight 를 고르는 곳이 두 층인데, 바깥 층은 계산이 무엇을 하는지 모른다.
- 그 밖에 GET 에서 1.0 으로 직접 넣는 무거운 읽기가 있다. 79~231 MB 저장소를 거꾸로 훑는 provider-input(`keeper_api` 900행), job 전체가 systhread 호출 하나인 `/ide/events`(`keeper_tool_call_index.ml` 102행), verification 목록, backlog 읽기다.
- 기다리는 요청이 없는 갱신 fork 하나가 읽기 lane 으로 갔다(`server_routes_http_routes_provider_runs.ml` 181행). 같은 모양의 다른 fork 여섯 곳은 `Pool_lane.with_background` 를 쓴다. #46543 이 고친다.

설계:

1. weight 는 일을 아는 쪽이 한 번만 정한다. `Dashboard_cache.get_or_compute*` 와 `run_dashboard_compute` 는 계산을 받을 때 그 일이 무엇인지 닫힌 타입으로 같이 받는다. 예를 들어 `type work = Cpu of (unit -> 'a) | Io of (unit -> 'a)` 같은 모양이다. 캐시는 그 선언대로 한 번 제출한다.
2. 계산 안의 중복 제출(위 76곳 가운데 캐시 계산 안에 있는 것)은 지운다. 선언이 한 곳에만 남는다. 호출부가 선언을 빠뜨리면 컴파일이 실패한다. 계산 쪽 숫자 weight 를 남겨 두는 대안은 두 층이 다시 어긋날 수 있어 받지 않는다.
3. 무엇을 `Io` 로 선언할지는 L4 의 경고를 따른다. 0.05 job 안에서 Stdlib 채널로 크게 읽고 파싱하면, 그 domain 에 받아 둔 job 이 모두 멈춘다. 그래서 큰 읽기와 파싱이 섞인 계산(provider-input, verification 목록, backlog)은 `Cpu` 로 선언하거나, 읽기와 파싱을 나눈다. 나누는 쪽은 그다음 단계다.
4. 숫자 weight(0.2 같은 값)는 쓰지 않는다. L4a 의 판정대로, 읽기 job 이 무엇을 하는지 선언하게 하는 것이 먼저다.

검증:

- 단위: 캐시가 선언대로 제출하는지 본다. `Io` 계산 둘이 하나뿐인 worker 에 같이 들어가고, `Cpu` 계산 둘은 줄을 서는지 `Pool_wait` 의 진행 중 weight 로 확인한다.
- 운영: 배포 뒤 한 시간 동안 읽기 lane 의 `wait_by_in_flight_workers` 를 L4a 와 같은 방법으로 본다. 2 worker 이상에서 들어온 긴 대기가 줄어야 한다. load 가 L4a 창과 비슷한 창끼리만 비교한다.

## 5. 순서

1. L1 — 코드가 작고, A/B 로 효과를 이미 봤다.
2. L2 — 기계적이지만 범위가 넓다. #46394 가 `lane_addon_tool_request_owner.ml` 을 바꾸므로, 그 파일의 해시 줄은 #46394 가 들어간 뒤 그 위에서 바꾼다.
3. L3 — #46394·#46397 배포 뒤 다시 재고, 남은 경로만 고친다.
4. RFC-0204 L3(#46374) — 읽기 풀. L1 예산 위에 쌓는다. 2026-10-27 운영 서버 2분 창에서 읽기 대기 p99 가 1초를 넘어 RFC-0204 §6 의 조건(100 ms)을 넘었다.
5. L4 — 읽기 풀 뒤에 배경 풀의 대기를 다시 재고, 맨 바깥 제출부터 고친다.
6. L4b — 읽기 lane 의 캐시 계산이 일의 종류를 타입으로 선언하게 한다. #46543(갱신 fork 의 lane)은 이것과 따로 먼저 들어간다.

## 6. 하지 않는 것

- minor heap 크기는 바꾸지 않는다. 2026-09-05 RFC 의 실험 1에서 16배로 키워도 STW minor 횟수가 그대로였다.
- `space_overhead` 는 이 RFC 에서 바꾸지 않는다. masc 는 100 이고 OCaml 5.5 기본값은 120 이다(Gc 문서). 바꾸려면 L3 이후 live heap 을 다시 재고 따로 정한다.
- GC 정지를 숨기는 timeout 늘리기나 재시도는 하지 않는다.

## 7. 위험

- L1 로 worker 가 줄면 L4 전까지 p90 이 늘어난다(§3.2).
- L2 의 bigstring 경로는 C 힙에 버퍼를 만든다. 큰 파일을 통째로 bigstring 에 올리면 메모리만 옮겨 간다. 파일은 정해진 크기로 나눠 읽는다.
- domain 번호와 풀의 대응(§3.3)은 추정이다. L1 PR 은 각 풀이 만든 domain 을 로그로 남겨 이 대응을 확인한다.

## 8. 측정 방법

- GC 구간과 늦게 온 domain: `dune exec tools/rtev_trace/rtev_watch.exe -- <dir> <pid> 60`. fiber 실행: `rtev_fibers.exe` 같은 인자. 링은 `.masc/runtime/events/<pid>.events` 다.
- 풀 대기: `/health` `scheduler.pool_wait` 를 측정 앞뒤로 찍어 뺀다.
- 경로별 지연: 경로 다섯 개를 각 100번 순서대로 부른다. 같은 load 대에서 비교한다.
- 큰 할당: memprof 를 한 번 읽어 비우고 30초 뒤 다시 읽어 `major` 표를 본다.
- 증상: TUI 로그의 `Pool.request: timeout` 을 TUI 하나 기준 시간당으로 센다.
- 이 호스트는 다른 세션의 빌드로 load 가 20~240 을 오간다. 전후 비교는 load 가 비슷한 창끼리만 한다.
