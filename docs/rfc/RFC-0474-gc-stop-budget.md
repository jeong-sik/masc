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

#### L4b 구현(#46573)에서 안 것

분류 규칙대로 하면 `Io` 는 git subprocess 를 기다리는 route 3곳뿐이고 나머지는 모두 `Cpu` 다. 그래서 L4b 는 구조를 바로잡지만 대기는 거의 줄이지 않는다. 대기를 줄일 일을 고르려면 어떤 job 이 worker 를 오래 잡는지 알아야 하는데, 지금은 그것을 알 수 없다.

- 2026-10-28 05:00Z 운영 서버(`2532ad1`, load 25)에서 60초 rtev fiber trace 를 떴다. 배경 worker domain 마다 `fstat` 뒤에 1~4.8초씩 쉬지 않고 CPU 를 쓰는 fiber run 이 있었다. 그중 약 30% 는 GC 다. 이 job 들은 label 이 없어(`cc#N(?)`) 어느 제출인지 모른다.
- 같은 서버에서 80분 동안 배경 lane 에 74,469건이 들어왔다. 그중 28,648건이 worker 3개 몫 이상 진행 중일 때 들어왔고, 그때 대기는 평균 170 ms, 최대 18초였다.
- macOS `sample` 로도 찾지 못했다. JSON lexing(20초에 약 3.7초)의 호출자가 `caml_callback_exn` 에서 끊긴다.
- `Pool_wait` 는 lane 단위로만 센다.

#### L4c — 풀 job 마다 이름

1. 풀에 제출하는 함수는 모두 `~name` 을 필수로 받는다: `Executor_pool_submission.submit`, `Domain_pool.submit*`, `Domain_pool_ref.submit_*_or_inline`, `Executor_pool_ref.submit_or_inline`·`submit_strict`, `Pool_work.cpu`·`io`, `run_dashboard_compute`. 빠뜨리면 컴파일이 실패한다.
2. 호출부는 `__FUNCTION__` 을 넘긴다. 이름을 새로 짓지 않으므로 이름과 코드가 어긋나지 않는다. 남의 계산을 받아 제출하는 helper(`run_dashboard_compute`)는 이름도 받아서 넘긴다.
3. `Dated_jsonl` 의 읽기는 여러 곳이 같이 쓰므로 함수 이름 대신 저장소로 부른다. `Dated_jsonl_store.location` 이 자기 저장소(닫힌 variant)를 들고, `pool_job_name` 이 `root/events`, `keeper/metrics` 같은 이름을 낸다. 키퍼 이름은 넣지 않는다. 키퍼 40명의 같은 저장소는 이름 하나다.
4. `Pool_wait` 는 lane·이름별로 들어간 수, 대기 합·최대, 실행 합·최대, 포기 수를 센다. 이름 표는 `Atomic` 안의 불변 `Map` 이다. 처음 보는 이름만 compare-and-set 으로 넣고, 그 뒤로는 읽기만 한다.
5. `/health` 의 `pool_wait.<lane>.by_name` 은 실행 합이 큰 20개를 보여 준다. TUI 마다 `/health` 를 자주 읽는데, 2026-10-28 에 13 KB 였고 한 줄이 약 180 바이트라 모든 이름을 싣지 않는다.
6. job 본문은 `Eio.Private.Trace.with_span name` 안에서 돈다. 그래서 rtev fiber trace 에도 이름이 label 로 나온다.

weight 와 어느 풀로 가는지는 바꾸지 않는다. 재는 것만 늘어난다.

검증:

- 단위: 이름 둘을 같은 lane 에 넣으면 따로 세고, 실행 합이 큰 쪽이 먼저 나온다. 포기한 제출은 그 이름의 포기 수만 올린다. 저장소 이름은 모두 다르고 키퍼 이름을 담지 않는다. mutant(이름별 실행 기록 제거)는 실행 시간 시험 하나만 실패한다.
- 운영: 배포 뒤 한 시간 `by_name` 을 앞뒤로 떠서 이름별 실행 합 순위를 낸다. 같은 창의 rtev trace 에서 긴 fiber run 의 label 을 본다. 그 순위로 다음 층(읽기와 파싱 나누기, 다시 읽지 않기, 배경 lane 으로 옮기기)의 대상을 고른다.

#### L4d — 시간 초과가 실제로 난 읽기부터

TUI 로그(`~/.masc/logs/masc-tui-*.log`)는 시간 초과가 난 요청의 경로를 남긴다(`http GET <path> took 10001 ms elapsed … Pool.request: timeout after 10.0s`). 2026-10-27~28 이틀에 1,750건, 28일 06:00 KST 이후에 126건이었다. 126건의 경로별 수:

| 경로 | 건수 | 혼자 재 본 응답(06:09Z, load 9) |
|---|---|---|
| `/api/v1/gate/keepers` | 35 | 0.11 s, 이어서 10 ms |
| `/api/v1/dashboard/goals` | 30 | 처음 9.3 s, 이어서 1 ms |
| `/api/v1/keepers/turns` | 25 | 0.09 s, 이어서 10 ms |
| `/api/v1/operator` | 11 | 0.2 s, 이어서 16 ms |

- 앞의 셋은 TUI 가 2초마다(`bin/masc_tui.ml` 의 `refresh` 기본값) 부르는 경로다. `gate/keepers`·`keepers/turns`·`operator` 는 혼자 재면 0.2초 안에 답한다. 이 셋은 원인이라기보다, 읽기 풀이 긴 job 에 막혔을 때 가장 자주 그 뒤에 서는 쪽으로 본다.
- `dashboard/goals` 는 다르다. 캐시 키가 goal projection generation 을 담는다(`goals_tree:<base>:<generation>`). goal 이나 측정 기록이 바뀌면 다음 읽기의 키가 비어 있고, 그 읽기가 읽기 lane 에서 tree 를 처음부터 계산한다. 그 한 번이 9.3초였다. TUI 제한은 10초다. 옛 generation 의 값은 다른 키라서 stale 로도 쓰이지 못한다.

설계:

1. `Dashboard_cache.seed_stale_from_if_missing key ~from ~stale_for` 를 둔다. `key` 가 비어 있고 `from` 에 내줄 수 있는 값이 있으면, 그 값을 `key` 아래 바로 stale 인 항목으로 넣는다. 다음 읽기는 그 값을 바로 받고, `key` 는 background 에서 채워진다. 준비된 바이트와 entity tag 를 그대로 옮기므로 다시 직렬화하거나 해시하지 않는다.
2. goals tree 는 `Server_dashboard_http.cached_goals_tree_payload` 한 곳에서 읽는다. 마지막으로 채운 키를 workspace 마다 기억하고, 새 generation 키가 비어 있으면 그 값을 넣어 둔다. HTTP/1 route 와 HTTP/2 gateway 가 모두 이 함수를 쓴다. HTTP/2 쪽은 그동안 캐시 없이 요청 fiber 에서 계산했다.
3. 쓰기 직후의 읽기는 직전 tree 를 받는다. 새 tree 는 계산이 끝난 뒤의 다음 읽기(TUI 로는 다음 2초 갱신)부터 보인다. 전에는 그 읽기가 계산이 끝날 때까지 기다리거나 시간 초과가 났다.

받지 않은 것:

- `gate/keepers`·`keepers/turns` 를 2초 캐시로 감싸는 안. 둘 다 혼자서는 빠르다. 그리고 `gate/keepers` 의 운영자 목록은 요청마다 현재 Candle revision 과 gate 관찰값을 붙인다는 계약이 있다(`test_keeper_portrait_http` "Gate operator revisions bypass shared metadata cache"). 캐시로 감싸면 그 시험이 실패했다. `keepers/turns` 는 대기 원천이 회복되면 다음 읽기에서 오류가 사라져야 한다(`test_keeper_turns_route`).

검증:

- 단위: 옮긴 값은 이전 페이지와 같은 JSON·entity tag 로 바로 나가고, 50 ms 걸리는 새 계산은 background 에서 채워진다. 이미 찬 키는 덮지 않고, 원본이 없으면 아무것도 넣지 않는다. mutant(옮긴 값을 fresh 로 넣기)는 background 채움 시험 하나만 실패한다.
- 운영: 배포 뒤 TUI 로그의 경로별 시간 초과 수를 위 표와 같은 방법으로 센다. `dashboard/goals` 가 줄어야 한다. L4c 의 `by_name` 으로 읽기 lane 에서 오래 도는 나머지 job 을 찾는다.

#### L4d 배포 뒤 (2026-10-28 07:51Z, `3f5585167ee`)

- 50분을 쟀다. 08:48Z 에 다른 배포로 서버가 다시 떠서 마지막 10분은 버렸다.
- TUI 시간 초과는 17:00~17:39 KST 에 22건이었다. `gate/keepers` 9, `keepers/turns` 6, `dashboard/goals` 2, `operator` 2. 시간대별 기준값이 0~91건이라 건수만으로는 판정하지 않는다.
- 읽기 lane 의 긴 대기(≥ 100 ms)는 구간마다 80~100%가 두 worker 가 모두 찼을 때 생겼다. 4.8~5.3초 기다린 `gate/keepers`·`keepers/turns` 가 같은 초에 함께 끝났다. TUI 는 그 사이 다른 요청을 정상으로 받았다.
- 두 worker 를 가장 오래 잡은 것은 goals tree 계산이었다. 부하가 걸리면 30초 계산 예산에 걸려 버려졌다(background 30,006 ms, 읽기 lane 30,256 ms). 그래서 07:58:21Z 에 만든 tree 가 12분 넘게 그대로 나갔다. L4d 는 직전 값을 바로 내주지만, 계산이 끝나지 못하면 직전 값이 바뀌지 않는다.

#### L4e — goals tree 는 goal 이 이름 붙인 Keeper 의 trust 만 읽는다

같은 데이터로 goals tree 의 구간별 시간을 쟀다(서버 밖 일회용 실행 파일, 2026-10-28 08:20Z, load 29~34). tree 는 7.46초였다. 그중 Keeper 40명의 `Keeper_runtime_trust_snapshot.snapshot_json` 이 7.31초였다. 나머지(goal·task·meta·receipt·검증 기록 읽기)는 다 합쳐 0.23초였다.

- `build_forest` 는 모든 Keeper 의 snapshot 을 먼저 계산해 목록으로 들고 있었다.
- 그런데 tree 가 snapshot 에서 읽는 값은 셋(`turn_id`, `latest_causal_event` 의 `ts`·`ts_unix`)뿐이다. 그것도 goal 의 task 를 맡은 Keeper 몫만 읽는다.
- 어느 goal 에도 이어지지 않은 21명이 5.27초였다. 이어진 19명은 2.03초였다. 가장 오래 걸린 셋(1.6·1.3·1.3초)은 모두 어느 goal 에도 이어지지 않았다.
- snapshot 캐시의 TTL 은 0.5초라 tree 한 번 안에서도 거의 맞지 않는다.

설계:

1. `build_context` 는 Keeper 이름으로 trust 를 묻는 함수(`runtime_trust_of`)를 들고 있다. 미리 계산한 목록은 없앤다.
2. `build_forest` 는 Keeper 마다 처음 물을 때만 snapshot 을 계산하고, 그 build 안에서는 기억한다. 값은 전과 같다.
3. `build_forest_with_trust_reader ~read_trust` 가 trust 를 읽는 함수를 이름으로 받는다. 같은 파일의 `..._with_pending_reader` 와 같은 모양이다. `build_forest` 는 실제 snapshot 을 넘긴다.

검증:

- 단위(`test_dashboard_goals_trust_reads`): Keeper 둘 가운데 한 명에게 두 goal 의 task 를 맡긴다. trust 는 그 Keeper 에 대해 한 번만 읽고, 다른 Keeper 는 읽지 않는다. 읽은 값이 node 의 `latest_keeper_ref`·`latest_turn_ref` 로 나간다. mutant 둘(모두 미리 읽기, 기억하지 않기)은 모두 실패한다.
- 실제 데이터: 옛 코드와 새 코드를 같은 데이터에 번갈아 3번씩 돌렸다(load 34~55). 최소 7.65초에서 2.55초로 줄었다. 중앙값(여섯 번 측정)은 약 9.2초에서 약 4.3초다. 시각 필드(`generated_at`, `stagnation_seconds`, `updated_at`)를 빼면 두 JSON 이 같다.
- 운영: 배포 뒤 `by_name` 에서 `cached_goals_tree_payload` 의 실행 시간과 30초 예산에 걸린 수를 본다. 서버가 내주는 tree 의 `generated_at` 이 TTL(60초) 안팎으로 갱신되는지 본다.

#### L4f — 승인 기록은 한 번만 읽는다

L4e 뒤로도 trust snapshot 은 Keeper 하나에 0.2~1.6초였다. snapshot 이 읽는 것을 하나씩 같은 데이터로 쟀다(2026-10-28 13:02Z, load 29~41). Keeper 40명 합으로 snapshot 이 6.85초였고, 그중 6.73초가 `Keeper_approval.Audit.read_recent ~keeper_name ~n:8` 이었다. 나머지(decision log·tool call·receipt·transition·대기 승인·blocker)는 다 합쳐 0.1초 아래였다.

- 승인 audit 저장소는 하루 파일 24개, 278,731줄, 131 MB 다.
- `read_recent` 는 최신 파일부터 거꾸로 모든 줄을 해석하며, 그 Keeper 의 줄 n개를 모을 때까지 읽는다.
- 오늘 기록이 없는 Keeper(`gayo-yoga-leader`, `hole-finder`, `rust-hwp-guy` 등)는 하루 6~10 MB 인 지난 파일을 여러 개 읽는다. 1~1.6초는 여기서 나온다.
- trust snapshot 은 goals tree, 운영자 trust 화면, goal detail 이 쓴다. 이 중 운영자 trust 계산(`compact_keeper_runtime_trust_json`)은 L4d 배포 뒤 40분 동안 background lane 실행 시간의 22.6%(884초)였다.

설계:

1. `Audit_recent_index` 가 저장소의 줄을 한 번씩만 해석한다. 읽기마다 먼저 지난 읽기 뒤에 바뀐 하루 파일만 다시 본다. 그래서 답은 그 읽기 시점의 저장소 내용이다. 파일마다 마지막으로 읽을 때의 `fstat` 결과를 기억해, `lstat` 이 같은 파일은 열지 않는다.
2. Keeper 마다, 그리고 저장소 전체로, 가장 새 줄 `read_recent_max_rows`(128, 지금 호출하는 곳 가운데 가장 큰 n)개를 위치와 함께 들고 있다. n 이 그보다 크면 거절한다.
3. 거꾸로 읽기가 거절하던 것을 위치로 기억한다. 못 읽은 달이 있으면 목록은 거꾸로 읽기처럼 거기서 멈춘다. 그 달과 더 오래된 달의 파일은 가려진 것이고, 끝까지 읽은 더 새 달에서 빠진 파일만 지워진 것이다. 깨진 JSON 줄과 Keeper 를 정확히 하나 이름 붙이지 않은 줄은 각각 가장 새 위치 하나다. 이번 읽기에서 못 읽은 월 목록이나 하루 파일도 그 위치로 기억한다. 읽기는 그 위치가 n번째로 고른 줄보다 새로우면(또는 n개를 못 채우면) 거절한다. 거꾸로 읽기가 그 줄에 닿는 경우와 정확히 같다.
4. 바뀐 파일은 첫 바이트부터 한 번 읽는다. 지난번에 해석한 바이트는 1 MiB 단위 digest 와 맞대기만 하고, 그 뒤의 온전한 줄만 해석한다. 맞대는 바이트와 해석하는 바이트가 같은 읽기에서 나오므로, index 가 든 줄은 언제나 digest 가 덮는 바이트에서 나온 줄이다. 읽는 도중에 다른 writer 가 써도 그렇다. digest 가 다르거나 파일이 짧아졌으면 처음부터 다시 만든다. 처음 안은 경계 앞 4 KB 만 비교했는데, 그 4 KB 를 그대로 두고 더 앞의 줄을 바꾼 재작성을 놓쳤다. 대신 줄이 붙을 때마다 그 하루 파일(4~10 MB)을 한 번 더 읽는다.
5. 보관 기간 정리는 가장 오래된 파일을 지운다. 남은 파일의 줄은 지워진 파일의 어떤 줄보다 새것이다. 그래서 들고 있는 줄에서 지워진 파일의 줄만 빼면, 남은 줄 가운데 가장 새 128개와 같다. 거절 위치도 같은 식으로 뺀다. 그래서 하루에 한 번 처음부터 다시 만들지 않는다. 더 오래된 파일을 남기고 가운데 파일이 지워졌을 때만 처음부터 다시 만든다. 128개 밖으로 밀려난 줄이 무엇이었는지 알 수 없기 때문이다.
6. 마지막 개행 뒤의 바이트는 거꾸로 읽기처럼 한 줄로 해석한다. 온전하면 답에 들고, 깨졌으면 거기에 닿는 읽기를 거절한다. index 에는 넣지 않고 파일 상태에 따로 둔다. 줄이 끝나면 다음 읽기가 그 자리부터 해석한다.
7. 함께 들어온 읽기는 갱신 하나를 나눠 쓴다. 저장소마다 칸 하나를 두고, 락은 칸을 보고 바꾸는 동안만 잡는다. 갱신은 락 밖에서 돈다. 읽기 하나는 도착부터 갱신까지 통째로 domain pool 의 일 하나다(이미 pool 일 안이면 그 자리에서). 그래서 갱신을 맡은 쪽은 늘 worker 를 쥐고 있다. pool 밖 fiber 가 갱신을 맡으면, 그 갱신 일이 worker 를 기다리는 동안 pool 일 안의 읽기들이 worker 를 쥔 채 그 갱신을 기다려 서로 멈춘다. 이미 돌고 있는 갱신은 늦게 온 읽기보다 먼저 파일을 봤을 수 있어서 그 읽기의 답이 될 수 없다. 그래서 늦게 온 읽기들은 다음 갱신 하나를 예약한다. 처음 온 읽기가 그것을 돌리고, 나머지는 promise 를 기다린다. 기다리는 읽기는 락에 막혀 domain 을 세우지 않고 fiber 만 멈춘다. 다만 pool 일 안에서 부른 읽기(trust snapshot 이 그렇다)는 기다리는 동안에도 그 일의 자리를 차지한다. 그래서 프로세스가 뜬 뒤 첫 만들기(실측 3.1초 load 26, 10~12초 load 75~90) 동안은 read lane 의 trust 계산이 그 자리를 잡고 기다린다. 이 비용은 프로세스마다 한 번이다. 갱신을 돌리던 fiber 가 취소되면 기다리던 읽기는 다시 줄을 선다. Eio 밖의 호출은 promise 를 기다릴 수 없어서, 갱신이 돌고 있으면 자기 사본을 갱신하고 공개하지 않는다.
8. `Dated_jsonl` 은 세 가지를 공개한다. 거꾸로 읽기가 쓰던 월·하루 파일 목록(같은 검증), 하루 파일 이름의 순서, 거꾸로 읽기와 같은 줄 해석(`entry_of_physical_line`)이다.

검증:

- 단위(`test_approval_audit_recent_index`): 시험 안에 옛 거꾸로 읽기를 그대로 두고 기준으로 삼는다. 단계마다 Keeper 다섯(없는 Keeper, 범위 없는 읽기 포함)과 n 다섯을 모두 맞댄다.
  - 한 저장소: 최신 파일에 붙이기, 옛 파일에 늦게 붙이기, 새 하루 파일, 가장 오래된 파일 지우기, 파일 다시 쓰기, 깨진 줄, Keeper 이름이 없는 줄
  - 지운 파일: 가장 오래된 파일(깨진 줄과 이름 없는 줄을 든 채), 가운데 파일, 모든 파일, 다시 생긴 파일. alpha 는 128줄보다 많아서 줄을 너무 많이 또는 너무 적게 빼면 드러난다.
  - 개행 없이 끝난 줄(온전한 줄, 이어서 끝난 줄, 깨진 줄, 깨진 줄이 나중에 완성됨)
  - 같은 inode 에서 다시 쓴 파일: 잘랐다가 더 길게 쓴 경우, 그리고 경계 앞 바이트를 그대로 두고 앞의 줄 하나만 바꿔 키운 경우. 바뀐 줄이 첫 1 MiB 블록에 있을 때와 마지막 블록의 4 KB 밖에 있을 때를 각각 본다.
  - 못 읽는 달: 오래된 달을 못 읽게 한 뒤 새 달의 파일을 지운다. 지운 파일의 줄이 남으면 안 된다.
  - 동시 읽기: domain 넷에서 fiber 열 개씩이 한꺼번에 읽는다. 처음 만들기, 그대로, 붙이기, 같은 inode 다시 쓰기, 새 하루 파일을 지나며 모든 읽기가 거꾸로 읽기와 같아야 한다.
  - 읽기 전에 붙은 줄: domain 하나가 줄을 하나씩 붙이고, 다른 domain 셋이 계속 읽는다. 읽기가 시작되기 전에 붙기를 마친 줄은 그 읽기의 답에 있어야 한다. 겹침에 기대지 않는 판도 있다. 다른 domain 이 30 MB 파일로 첫 만들기를 시작한 뒤 20 ms 에 한 줄을 붙이고 새 읽기를 시작한다. 그 읽기는 붙인 줄을 봐야 한다.
  - worker 하나짜리 pool: pool 일이 worker 를 쥔 동안 pool 밖 읽기가 들어오고, 그다음 pool 일이 읽는다. 30초 안에 둘 다 답해야 한다.

  mutant 열여섯은 모두 실패한다: 거절 무시, 크기 무시, 위치 무시, 지운 파일 무시, 못 읽은 달이 있으면 모든 파일을 가려진 것으로 보기, 지운 파일의 줄 남기기, 가운데 파일 삭제도 빼기만 하기, 지운 파일의 거절 남기기, Keeper 이름 없는 줄 무시, 끝 조각 무시, digest 비교 생략, 마지막 블록만 비교, 앞 블록만 비교, 돌고 있는 갱신의 답을 그대로 쓰기(다섯 번 모두), 갱신이 돌 때 공개된 index 를 그대로 쓰기, 갱신을 pool 밖에서 맡기.
  - 시험하지 못한 것: `lstat` 과 `open` 사이에 파일이 symbolic link 로 바뀌는 경우. `open` 이 연 파일의 inode·device 가 `lstat` 과 다르면 이번 읽기에서 그 파일을 거절한다.
- 실제 데이터: 처음 안에서 옛 코드와 새 코드를 번갈아 3번씩 돌렸다(load 55~72). Keeper 40명의 snapshot 합은 7.4~19.3초에서, index 가 있는 상태에서 8.9~364 ms 가 됐다. 이 안은 live 저장소 사본(126 MB, 하루 파일 24개)에서 `read_recent` 만 쟀다(2026-10-28 15:48Z~16:01Z, load 75~90).

  | 경우 | 시간 |
  |---|---|
  | 처음 만들기 | 10.5~11.9초 |
  | 바뀐 파일 없음 | 0.17~0.23 ms (부하가 튈 때 30 ms) |
  | 최신 파일(4.1 MB)에 한 줄 | 7~18 ms (한 번 170 ms) |
  | 가장 오래된 파일 지움 | 4 ms |

  부하 평균 26 에서 다시 재면(2026-10-28 18:05Z) 처음 만들기는 3.1초였고, 한 줄 붙은 뒤 읽기는 7~15 ms 였다. 하루 파일 23개(125 MB) 전부의 MD5 는 0.23초라, digest 는 처음 만들기의 7% 쯤이다.
- - 운영: 배포 뒤 `by_name` 에서 `compact_keeper_runtime_trust_json`·`compute_execution_trust_json`·`cached_goals_tree_payload` 의 실행 합과 `Keeper_approval__Audit.read_recent` 의 실행 시간을 본다.

#### L4g — 디렉터리 확인은 lock 을 쥔 채 멈추지 않는다

L4d 배포 뒤 읽기 lane 실행 시간의 50%가 `gate/keepers` 였다(2시간 반, job 3,546개, 평균 339 ms, 최대 44.7초). 같은 계산을 서버 밖에서 재면 한 번에 18~55 ms 다. 차이를 보려고 `rtev_fibers` 가 pool job 의 traced section 마다 실행 시간과 멈춘 이유별 시간, 그리고 Eio lock 의 대기·보유를 재게 했다(2026-10-28 14:07~14:34Z, load 40~77).

- `gate/keepers` 는 180초 동안 job 59개, wall 합 65.5초 가운데 실행이 3.05초(5%)였다. 대부분 한 Eio mutex 를 기다렸다.
- 그 mutex(object id 28) 하나를 180초 동안 기다린 시간 합이 1,020~2,972초였다. 기다린 쪽은 pool job 전부와 HTTP 응답 쓰기(`writev`), 연결 받기(`accept`)까지였다.
- 길게 쥔 쪽은 모두 쥐고 있는 동안 `fstat` 하나를 기다렸다(0.35~5.2초). 놓은 바로 뒤의 다음 작업은 `fstat` 이나 Keeper meta 파일(`<keeper>.json`) 읽기였다.
- 이 mutex 를 `Keeper_fs.dir_mu` 로 본다. Eio mutex 에는 이름이 없어 trace 만으로는 확정할 수 없다. 근거는 두 가지다. 쥔 채 `fstat` 에서 멈추고 놓은 뒤 Keeper meta 를 읽는 모양이 아래 코드와 같다. 그리고 기다린 job 이 모두 Keeper meta 를 읽는다. 배포 뒤 같은 trace 에서 이 대기가 사라지는지로 확인한다. `ensure_dir` 는 캐시에 있는 디렉터리도 `Fs_compat.file_exists`(eio_posix 의 `in_worker_thread "fstat"`)로 다시 확인했다. 그동안 프로세스 전체가 쓰는 mutex 를 쥐고 있었다. `keeper_meta_path` 는 Keeper meta 를 읽을 때마다 `.masc/keepers` 를 이렇게 보장한다.
- 이 확인은 원래 `Sys.file_exists` 였다. #6289 가 Eio 안의 막는 IO 를 없애려고 `Fs_compat.file_exists` 로 바꾸면서, 짧은 syscall 이 lock 을 쥔 채 멈추는 system thread 대기가 됐다.

설계:

1. 디렉터리 캐시를 없앤다. 캐시에 있는 경로도 매번 파일시스템에서 확인했으므로 캐시가 아끼는 것이 없었다. 확인과 `mkdir_p` 는 lock 없이 한다. 있는 디렉터리 하나에 드는 것은 `stat` 한 번으로 전과 같다.
2. 동작은 그대로다. 밖에서 지운 디렉터리는 다시 만든다. `mkdir_p` 는 이미 있는 디렉터리를 받아들이므로 같은 경로를 두 호출이 동시에 만들어도 된다. `invalidate_dir`·`clear_dir_cache` 는 이제 durable 디렉터리 기록(`Keeper_fs_durable_directory`)만 지운다.
3. `dir_mu` 를 예로 든 주석 넷에서 그 이름을 지운다. 지금 동작을 설명하는 두 곳(`dashboard_cache.ml`, `server_routes_http_routes_provider_runs.ml`)은 지금 있는 mutex(`Keeper_types_support.keeper_execution_receipt_store` 가 쥐는 것)를 예로 든다. 6월 사고를 적은 두 곳(`eio_guard.ml`, `test_executor_pool_eio_mutex.ml`)은 그 mutex 가 이제 없으므로 일반어로 적는다. 다른 mutex 이름을 넣으면 사고 기록이 틀려진다.

검증:

- 단위(`test_keeper_fs`): 바깥에서 지운 디렉터리를 다시 만든다. domain 넷이 같은 새 경로 여덟 개를 동시에 50번씩 보장해도 모든 호출이 경로를 돌려주고 디렉터리가 있다. mutant 둘(만들지 않기, 확인 없이 돌려주기)은 모두 실패한다. 캐시를 비우면 다시 확인하는지 보던 시험 둘(`invalidate`, `clear cache`)은 캐시가 없어져 지웠다. 같은 동작은 "밖에서 지운 디렉터리" 시험이 본다.
- bench: 실제 `.masc/keepers` 에 domain 8개 × fiber 4개가 16,000번 `ensure_dir` 를 불렀다. main 의 lock 경로를 그대로 옮긴 것과 번갈아 3번씩 돌렸다(2026-10-28 16:11Z, load 65~68).

  | | 전체 | p50 | p99 |
  |---|---|---|---|
  | main | 0.97~1.60초 | 1.4~2.1 ms | 6.3~17.6 ms |
  | L4g | 0.17~0.28초 | 0.19~0.35 ms | 0.9~2.4 ms |
- 운영: 배포 뒤 `rtev_fibers` 로 같은 창을 다시 떠서 가장 많이 기다린 lock 과 `gate/keepers` 의 실행 비율을 본다. `by_name` 에서 `respond_keeper_tool_json` 의 실행 평균과 읽기 lane 의 대기를 본다.

#### L4g 배포 뒤 (2026-10-29)

- TUI `Pool.request` timeout: 13:12~14:02(TUI 1개, 50분) 0건, 14:42~15:42(TUI 1개, 서버 재시작으로 7분 빔) 1건. L4d 직후 1시간 41건, L4e·L4f 1시간 13건과 조건이 다르다. TUI 수가 다르고, 아래 L4h 에서 보듯 시간대에 따라 tool-call 원장 크기가 다르다.
- 서버가 뜬 직후 `/api/v1/dashboard/goals` 가 약 80초 동안 답하지 않았다(14:42·15:06 두 번 다). `pool_wait.read.by_name` 에서 첫 goals 계산은 풀 대기 0.14 ms, 실행 78.8초였다. 같은 계산을 서버 밖에서 하면 처음 2.4초, 그다음 40~57 ms 다.

#### L4h — 새 프로세스도 이미 증명한 원장 앞부분을 다시 해시하지 않는다

16:12 에 뜬 서버에 처음 150초 동안 `rtev_fibers` 를 붙였다(이벤트 유실 0). `Keeper_tool_call_index.blocking` 25개가 wall 합 202초, 최대 26.2초였고 모두 `keeper tool-call read index`(색인의 system thread)를 기다렸다. 기동 3분 뒤 goals 첫 계산 2.5초도 실행은 0.43초이고 이 대기가 1.25초였다. goals tree·`gate/keepers`·keepers_json 이 쓰는 Keeper trust snapshot 이 최근 도구 호출을 이 색인에서 읽는다.

- 색인 읽기(`with_index`)는 프로세스 전체가 쓰는 `store_mu` 를 쥐고 1970년부터 오늘까지 원장 날짜 파일을 모두 따라잡는다. 파일의 stat 이 마지막으로 증명한 때와 다르면 continuity 를 믿기 전에 앞부분을 0바이트부터 SHA-256 체인으로 다시 해시한다(`prefix_matches`).
- "stat 이 같으면 증명을 건너뛴다" 는 지름길은 프로세스 메모리(`store.observations`)에만 있었다. 그래서 새 프로세스는 모든 파일을 다시 해시했다. 2026-10-29 원장은 25개 파일 4.7 GB, witness 는 한 코어에서 약 175 MB/s 다(47 MB 0.28초, 223 MB 1.25초, 312 MB 1.79초). 전부면 약 27초이고, 그동안 다른 색인 읽기는 `store_mu` 뒤에서 기다린다.

설계:

1. 읽기가 지름길 캐시에 stat 을 넣을 때, 같은 stat(dev·inode·size·mtime·ctime)과 그때의 continuity(generation·boundary·prefix digest)를 continuity 기록 옆 파일(`<hex>.observed`)에도 쓴다. 다음 프로세스는 파일이 정확히 그 stat 이고 continuity 가 정확히 그 값일 때만 증명을 건너뛴다. 프로세스 안 캐시가 기대는 증거와 같다. 앞부분을 바꾸는 쓰기는 ctime 을 바꾸고, ctime 을 되돌리는 호출은 없다. 같은 clock tick 안에 크기를 지키는 쓰기를 놓칠 수 있다는 한계도 프로세스 안 캐시와 같고 interface 에 적혀 있다.
2. 이 파일은 SQLite 색인처럼 파생물이다. fsync 없이 쓰고(`save_file_atomic_rename_only`), 모든 필드가 맞을 때만 믿는다. 없거나 찢어졌거나 낡았으면 지금처럼 앞부분을 다시 읽는다. 쓰다 실패해도 같다. mtime·ctime 은 hex float 로 적어 정확히 비교한다.
3. continuity 기록의 형식은 그대로다. 예전 기록을 읽는 코드가 없다. 배포 뒤 첫 프로세스만 지금처럼 전부 증명하고, 그때 이 파일들을 쓴다.
4. 원장 날짜 파일이 사라져 continuity 기록을 지울 때 이 파일을 먼저 지운다. 둘 사이에서 멈춰도 기록 없이 이 파일만 남지 않는다. 지우다 실패해도 읽기를 실패시키지 않는다. 그 경로의 다음 continuity 는 새 generation 이라 남은 파일이 다시 맞을 수 없다.
5. 이 파일은 SQLite cursor 가 그 continuity 의 boundary 에서 이어질 때만 본다. cursor 가 없으면 스캔이 어차피 앞부분을 처음부터 다시 읽으므로 건너뛸 것이 없다. 그리고 내용과 어긋난 기록을 다시 믿으면 `with_index` 의 "SQLite 를 버리고 다시 시도" 복구가 매번 같은 기록을 믿어 영영 실패한다(적대 리뷰에서 찾음).
6. 쓰기에 실패한 관찰은 프로세스 안 캐시에 "기록 안 됨" 으로 남겨 다음 읽기에서 다시 쓴다. 파일이 바뀌지 않는 지난 날짜 파일은 그렇지 않으면 그 프로세스가 끝날 때까지 기록되지 않는다.

예전 바이너리로 되돌리면 그 바이너리의 정리는 `.json` 만 지우므로 `.observed` 가 남을 수 있다. 사라진 generation 을 가리키므로 다시 맞지 않고, 개수는 그동안 사라진 날짜 파일 수를 넘지 않는다.

이 층이 줄이지 않는 것: 오늘 파일은 거의 모든 읽기 사이에 append 를 받는다. 그래서 읽기마다 오늘 파일 앞부분을 다시 해시한다(오후 47 MB 0.28초, 밤 300 MB 1.8초, 스캔 중 append 가 오면 두 번). 이것을 줄이려면 내용 증명 정책(RFC-0437)을 바꾸거나, 쓰는 쪽(`Dated_jsonl.append_notifying_commit`)이 자기가 붙인 줄을 증거로 남겨야 한다. 여러 저장소가 쓰는 `Dated_jsonl` 을 바꾸는 일이라 다음 층에서 따로 정한다.

검증:

- 단위(`test_keeper_tool_call_log` 95개, `test_keeper_tool_call_index_witness`·`_domain`, `test_keeper_tool_call_log_file_change_concurrent`): 모두 통과. mutant 둘이 모두 실패한다. 기록된 관찰을 stat 확인 없이 믿으면 같은 inode 재작성 시험 2개가 실패하고, continuity 를 지울 때 이 파일을 남기면 보존 기간 시험이 실패한다. 기록을 실제로 써서 건너뛰는지는 결과가 같아 단위 시험으로 가를 수 없다. 아래 bench 와 배포 뒤 trace 로 본다.
- bench: 실제 원장 최근 5일(1.2 GB)을 APFS clone 으로 복사해, 새 프로세스의 첫 읽기(`forget_for_ledger` 뒤 `recent_rows`)를 기록이 없을 때(main 과 같음)와 있을 때 번갈아 3번씩 쟀다.

  | | 1 | 2 | 3 |
  |---|---|---|---|
  | 기록 없음, 07:35Z load 23→114 | 23.6초 | 21.5초 | 13.4초 |
  | 기록 있음, 같은 때 | 0.115초 | 0.027초 | 0.022초 |
  | 기록 없음, 07:52Z load 17 (5번 반영 뒤) | 6.75초 | 6.68초 | 6.71초 |
  | 기록 있음, 같은 때 | 0.011초 | 0.019초 | 0.009초 |
- 운영: 배포 뒤 다음 기동에 `rtev_fibers` 를 처음부터 붙여 `Keeper_tool_call_index.blocking` 의 최대 wall 과 goals 첫 계산 시간을 본다.

#### L4h 배포 뒤 (2026-10-29, `9b8b566fdb4` 를 포함한 main)

기동마다 처음 150초에 `rtev_fibers` 를 붙이고 `/health` 의 `pool_wait.*.by_name` 을 읽었다. 기동 trace 는 이벤트를 28~42% 잃었으므로 합계는 `by_name` 을 함께 본다.

| 기동 | 관찰 기록 | `Keeper_tool_call_index.blocking` 최대 | 첫 150~180초 합 | goals 첫 계산 |
|---|---|---|---|---|
| 07:12Z, L4h 전 | 없음 | 26.2초 | 202~215초 | 6.1초(기동 3분 뒤). 06:06Z 기동 직후는 78.8초 |
| 08:48Z, L4h 첫 기동 | 0 → 25 | — | — | 30초(기동 직후, 색인 대기 30.2초) |
| 09:48Z | 25 | 2.3초 | 10.4초 | — |
| 09:53Z | 25 | 0.57초 | 5.1~5.5초 | 0.71초(기동 3분 뒤) |

첫 기동은 기록이 없어 예전처럼 전부 증명했고, 그때 날짜 파일 25개의 기록을 썼다. 그 뒤 기동부터 이 대기가 사라졌다.

#### L4 전체: TUI timeout 을 같은 조건으로 다시 잰 것

L4d 직후 41건(A)과 L4e·L4f 13건(C)은 TUI 수와 원장 크기가 달라 바로 견줄 수 없었다. 그래서 오래 떠 있던 TUI 만 두고, TUI 로그의 화면 읽기(`tui_surface_read_finished`) 수로 timeout(`Pool.request: timeout`) 을 나눴다. 원장 크기는 tool-call 날짜 파일이 UTC 로 나뉘므로 구간 시각의 줄 위치로 셌다.

| 구간 | 빌드 | 오래 떠 있던 TUI | 읽기 | timeout | 100번당 | 오늘 원장 | load |
|---|---|---|---|---|---|---|---|
| A 10-28 07:56~08:56Z | L4d | 2 | 1,667 | 25 | 1.5 | 51~60 MB | 40~77 |
| C 10-29 02:03~03:03Z | L4e·L4f | 3 | 2,144 | 13 | 0.61 | 6~17 MB | 15~30 |
| E 10-29 09:57~10:57Z | L4e~L4h | 2(59/60분) | 3,477 | 0 | 0 | 66~72 MB | 21→106 |
| E2 10-29 11:31~12:31Z | L4e~L4h | 2(60분) | 3,697 | 0 | 0 | 76~83 MB | 26→76 |

- A 의 41건 가운데 16건은 1분이 안 되게 떠 있던 TUI(다른 세션의 시험)에서 났다. 표는 그것을 뺐다. C 의 13건은 모두 한 TUI 의 7분 안에서 났다.
- E 는 서버 재시작 없이 한 프로세스(L4h 포함)로 1시간이었다. 같은 시간 5초마다 부른 네 경로(`gate/keepers`·`operator`·`dashboard/goals`·`keepers/turns`, 경로당 619번)는 실패와 10초 초과가 0이었다. p99 는 0.31~0.71초, 최대 2.65초였다.
- 읽기 3,477번에 0이면 rule of three 로 100번당 0.09 미만이다. E 는 A 보다 원장이 크고 load 가 비슷하거나 높았다.
- E2 는 같은 방법으로 한 번 더 잰 1시간이다. 서버 재시작으로 앞선 시도(11:12Z)를 버렸다. 이 시도는 다른 세션의 빌드(L4h 포함)였고, 한 프로세스로 끝까지 갔다. 원장은 E 보다 더 컸다. 네 경로 직접 호출(경로당 635번)은 p99 0.29~0.34초였다. 실패 4번은 모두 서버가 막 뜬 첫 호출의 503 이었다. 11:55:52Z 에 네 경로가 동시에 6.5~6.7초 걸린 순간이 한 번 있었다. 원인은 아직 보지 않았고, TUI 기준 10초 안이었다.
- E 와 E2 를 합치면 읽기 7,174번에 timeout 0, 100번당 0.042 미만이다. A 의 1.5 와 견주면 적어도 약 36배(1.5 ÷ 0.042 = 35.7) 낮다. 0.042 는 rule of three 상한이라 실제 비율은 이보다 클 수 있다.
- 원장 크기를 맞춘 L4d 대조: A 는 원장이 E·E2 보다 작았다. 그래서 L4d 가 돌던 10-28 에 원장이 같은 크기였던 1시간을 따로 셌다(09:21~10:21Z, 서버는 08:48Z~10:26Z 한 프로세스, 원장 66~93 MB). 이 시각의 빌드는 L4d 까지만 가질 수 있다. L4d(#46583)는 10-28 07:15Z, L4e·L4f 는 10-29 01:55Z 에 병합됐다. 오래 떠 있던 TUI 는 하나(60702)였다.

  | | 빌드 | 오늘 원장 | 읽기 | timeout | 100번당 |
  |---|---|---|---|---|---|
  | L4d, 10-28 09:21~10:21Z | L4d | 66~93 MB | 1,784 | 21 | 1.18 |
  | E + E2 | L4e~L4h | 66~83 MB | 7,174 | 0 | 0.042 미만 |

  양쪽 모두 TUI 로그에서 TUI 가 읽은 모든 경로의 `Pool.request: timeout` 을 셌다. 5초마다 부른 네 경로 직접 호출(E·E2 의 탐침)은 이 비교에 들어가지 않는다. 읽기가 서로 독립이라고 가정하면, L4d 비율이 그대로일 때 7,174번에 한 번도 안 날 확률은 1.3×10⁻³⁷ 이다. 같은 순간의 서버 정지가 여러 읽기를 함께 늦추므로 실제 읽기는 독립이 아니고, 이 확률은 차이가 우연이 아니라는 크기만 보여 준다. 원장 크기를 맞춰도 적어도 약 28배(1.18 ÷ 0.042) 낮다. 21건은 `gate/keeper-status` 5, `keepers/*/config` 4, `gate/keepers` 4, `keepers/turns` 3, `operator` 2, 그 밖 셋이 1건씩이다. load 는 이 시각 기록이 없어 맞추지 못했다.

오늘 원장 파일은 거의 모든 읽기 사이에 줄이 붙으므로 읽기마다 앞부분을 다시 해시한다(L4h 의 "이 층이 줄이지 않는 것"). 원장이 커지는 밤에 같은 방법으로 다시 쟀다. 서버는 10-29 15:28Z 에 뜬 한 프로세스(L4h 포함)였고, 오래 떠 있던 TUI 는 둘(93628, 62941)이었다.

| 구간(10-29~30 UTC) | 오늘 원장 | 읽기 | timeout |
|---|---|---|---|
| 16:40~17:00Z | 108→115 MB | 1,194 | 0 |
| 17:00~24:00Z, 시간마다 | 115→160 MB | 3,575~3,584 | 0 |
| 합 | 108~160 MB | 26,262 | 0 |

원장이 E·E2 의 두 배 가까이 커져도 timeout 이 없었다. 그래서 읽기마다 오늘 파일을 다시 해시하는 비용을 줄이는 층은 지금 만들지 않는다. 날짜 파일이 이보다 커지거나 timeout 이 다시 보이면 그때 다룬다.

#### L5 — 매시간 도는 chat journal 감사를 main domain 밖에서 한다 (#46816)

L4h 뒤에도 서버 전체가 몇 초씩 멈췄다. 10-29~30 밤, TUI 두 개가 같은 10초 안에 함께 2초 넘게 느려진 때가 7시간 20분에 6번 있었다(최대 5.3초). TUI timeout 기준(10초) 안이라 위 측정에는 걸리지 않았다.

- 10-30 01:29Z 에 `sample`(10초, 50 ms 간격)로 멈춤 하나를 잡았다. 그 10초 동안 `/health` 가 3.3초 걸렸다. main thread(`caml_main`)가 193개 표본 가운데 58개를 `stat` 시스템 콜 안에서 보냈다. 호출 경로는 `Keeper_chat_journal_audit.within_lookback` → `Unix.stat` 였다.
- 유지보수 루프(`server_bootstrap_maintenance.ml`)는 한 시간마다 `Keeper_chat_journal_audit.sweep` 을 main domain 에서 바로 돌렸다. sweep 은 Keeper 마다 `Sys.readdir`, journal 마다 `Unix.stat`(10-30 기준 50개 Keeper, 8,133개 파일, 5.1 GB)을 부르고, 고른 journal 과 그 Keeper 의 chat store 를 읽어 파싱한다. 모두 Eio 밖의 막는 호출이라 그동안 main domain 의 다른 fiber, HTTP 연결 받기까지 돌지 못했다.
- 타이머는 서버가 뜬 시각부터 한 시간마다 돈다. 잡은 멈춤(01:29Z)은 01:28Z sweep 과, 밤의 03:31 KST 멈춤은 03:28 KST sweep 과 맞는다. 밤의 다른 다섯 번은 이것으로 설명되지 않아 #46816 에 남긴다.

설계:

1. sweep 을 세 단계로 나눈다. 파일 고르기(디렉터리 읽기와 stat)와 고른 journal 의 읽기·비교는 공유 풀의 CPU job 으로 돌린다(`Domain_pool_ref.submit_cpu_or_inline`). 풀이 없거나 Eio 밖이거나 이미 풀 job 안이면 제자리에서 돈다.
2. `liveness`(chat operation registry 에 턴이 아직 도는지 묻기)는 두 job 사이에서 호출자의 domain 에서 부른다. registry 가 풀 worker 에서 불려도 안전하다는 근거를 찾지 못했기 때문이다. 답은 어느 쪽이든 그 순간의 읽기다. 끝난 operation 은 계속 끝난 상태이고, 도는 operation 은 다음 차례로 넘긴다.
3. `sweep` 의 interface 와 결과(순서, Keeper 마다 store 를 한 번만 읽기, 한 번 감사한 operation 다시 읽지 않기)는 그대로다.

검증:

- 단위(`test_keeper_chat_journal_audit`): 기존 sweep 시험은 풀 없이 그대로 통과한다. 새 시험은 1-worker 풀을 넣고 sweep 을 부른다. `liveness` 가 호출자의 domain 에서 한 번 불렸는지, 이 이름의 풀 job 이 정확히 두 개였는지 본다.
- 운영: 배포 뒤 같은 `sample` 감시로 매시간 sweep 시각에 main thread 가 `stat` 에 머무는지 보고, TUI 로그에서 두 TUI 가 함께 느려진 때를 다시 센다.

## 5. 순서

1. L1 — 코드가 작고, A/B 로 효과를 이미 봤다.
2. L2 — 기계적이지만 범위가 넓다. #46394 가 `lane_addon_tool_request_owner.ml` 을 바꾸므로, 그 파일의 해시 줄은 #46394 가 들어간 뒤 그 위에서 바꾼다.
3. L3 — #46394·#46397 배포 뒤 다시 재고, 남은 경로만 고친다.
4. RFC-0204 L3(#46374) — 읽기 풀. L1 예산 위에 쌓는다. 2026-10-27 운영 서버 2분 창에서 읽기 대기 p99 가 1초를 넘어 RFC-0204 §6 의 조건(100 ms)을 넘었다.
5. L4 — 읽기 풀 뒤에 배경 풀의 대기를 다시 재고, 맨 바깥 제출부터 고친다.
6. L4b — 읽기 lane 의 캐시 계산이 일의 종류를 타입으로 선언하게 한다. #46543(갱신 fork 의 lane)은 이것과 따로 먼저 들어간다.
7. L4c — 풀 job 마다 이름을 붙여 lane·이름별로 잰다. 그 순위로 다음 층을 고른다.
8. L4d — TUI 로그에서 시간 초과가 난 경로를 세고, 원인으로 확인된 goals tree 의 요청 경로 계산부터 없앤다.
9. L4e — goals tree 계산 자체를 줄인다. 시간의 97%가 쓰지 않는 Keeper 의 trust snapshot 이었다.
10. L4f — trust snapshot 시간의 98%였던 승인 기록 읽기를 한 번 읽는 index 로 바꾼다.
11. L4g — Keeper meta 를 읽을 때마다 프로세스 전체를 줄 세우던 디렉터리 확인 lock 을 없앤다.
12. L4h — 새 프로세스가 이미 증명된 tool-call 원장 날짜 파일 전부(4.7 GB)를 다시 해시하지 않게 한다. 읽기마다 오늘 파일을 다시 해시하는 비용은 다음 층에서 정한다.
13. L5 — 매시간 도는 chat journal 감사의 파일 훑기와 읽기를 main domain 밖 풀에서 한다(#46816).

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
