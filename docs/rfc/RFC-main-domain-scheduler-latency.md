---
rfc: "main-domain-scheduler-latency"
title: "Main domain scheduler latency: measure it, then remove what makes it wait"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
related: ["0204", "0239", "0302"]
---

# RFC — 메인 도메인이 기다리는 시간을 재고, 기다리게 만드는 것을 없앤다

## 0. 요약

TUI 와 대시보드가 느린 이유는 메인 Eio 도메인이 자기 일을 못 하고 기다리기 때문이다. 2026-09-05 실측(`docs/research/2026-09-05-main-domain-scheduler-latency-research-r1.md`)에서 메인 스레드 시간의 72% 가 blocking syscall 뒤의 도메인 락 재획득 대기였고, `/health` 는 p90 3.4초, 최대 9.6초였다. 호스트는 load 80~300 이었다.

이 RFC 는 다섯 단계다. 단계마다 같은 계기로 전후를 잰다.

| 단계 | 내용 | 성공 기준 (같은 호스트, 같은 계기) |
|---|---|---|
| 0 | 메인 도메인 lag 프로브 + GC 카운터를 `/health` 에 싣고 하네스로 읽는다 | 배포 후 `.scheduler` 가 채워진다. 기준선이 기록된다 |
| 0b | 힙 루트 진단: 등록된 루트별 `Obj.reachable_words` | live 2.5GB 의 상위 3 보유자를 이름으로 안다 |
| 1 | 부팅 창: TUI 는 `startup.state_ready` 전엔 surface 를 안 부르고 "server booting" 을 보인다. 레지스트리 재생 상한을 소비자 크기로 내린다 | 재기동 뒤 TUI 에 10초 타임아웃이 0건. 포트 열림→ready 가 절반 이하 |
| 2 | 메인 도메인 위생: keeper fiber 가 부르는 `Dated_jsonl` 스캔·`Stdlib.input`·`fsync` 를 domain pool 또는 Eio 경로로 옮긴다. `run_in_systhread` 는 닫힌 syscall 집합만 받는 타입 경계로 바꾼다 | 프로브 p99 가 절반 이하, 1초 이상 stall 이 분당 0 |
| 3 | 서빙 도메인 분리(RFC-0204 Phase 3): wait-free 읽기 경로를 별도 도메인에서 서빙, 상태를 만지는 핸들러는 메인 도메인 큐로 전달 | 메인 도메인이 멈춰도 `/health` 와 스냅샷 읽기는 p99 50ms 이하 |
| 4 | 할당과 live 줄이기: exact-lane projection 은 요약만 상주, 본문은 디스크에서 읽는다. 체크포인트는 messages 본문 대신 blob 참조 | live 힙 절반 이하, major GC 분당 횟수 절반 이하 |

## 1. 문제

측정값은 연구 문서에 있다. 여기서는 구조만 적는다.

1. HTTP accept, 모든 연결 fiber, SSE, 5개 refresh loop, 12개 keeper loop 가 한 도메인 위에 있다. 이 도메인의 스레드가 blocking section 을 나올 때마다 도메인 락을 다시 잡아야 하고, 그 락은 같은 도메인의 systhread 나 STW 를 대신하는 backup thread 가 잡고 있을 수 있다. 초당 약 15,000회 syscall 이면 그 대기가 곧 지연이다.
2. 워커 도메인 14개는 한가하다. 무거운 일은 이미 pool 로 넘어가 있다. 그런데도 메인이 느린 이유가 1번이다.
3. live 힙 2.5GB 는 모든 major 마킹의 분모다. 할당은 13~20MB 체크포인트 인코딩, 대시보드 프로젝션(시간당 약 4GB), 키퍼 턴 본문(185~299KB)이 만든다.
4. 부팅 때 425MB 레지스트리 로그를 메인 fiber 가 전부 파싱한다. 포트는 그 전에 열린다.
5. 서버는 하루 8~19번 재시작된다. 매번 1~4가 다시 일어난다.

## 2. 왜 이 순서인가

- 0 이 먼저다. 지금까지의 성능 작업(RFC-0204, 0302, #31993)은 관찰로 시작했고 배포 뒤 다시 잴 계기가 없었다. `sample` 은 OCaml 5 fiber 스택을 못 풀어 leaf 만 준다. 프로브는 메인 도메인이 ready fiber 를 얼마나 늦게 돌리는지 직접 잰다. 이것이 TUI 가 겪는 숫자다.
- 0b 가 없으면 4 는 추측이다. `Gc.quick_stat` 의 live 는 총량만 준다.
- 1 은 코드가 작고 위험이 낮으며 "붙자마자 끊김" 을 바로 없앤다.
- 2 는 1번 구조를 직접 줄인다. `run_in_systhread` 60곳을 손으로 한 곳씩 고치는 것은 N-of-M 패치다. 대신 임의 클로저를 받는 `Eio_guard.run_in_systhread` 를 없애고, `fsync`·`fchmod`·`stat`·`readdir`·`rename`·`realpath`·파일 읽기/쓰기 같은 닫힌 집합만 systhread 로 가게 타입으로 막는다. 컴파일러가 모든 호출 지점을 열거한다.
- 3 은 RFC-0204 가 이미 실현 가능하다고 판단한 하이브리드 경로다. Eio 의 Promise·Stream 은 도메인 간 안전하다.
- 4 는 가장 크지만 0b 결과를 봐야 한다.

## 3. Phase 0 설계 (이 PR)

- `Scheduler_lag` (lib/core): 100ms 주기로 monotonic 클록에서 자고, 늦게 깬 만큼을 600칸 링에 기록한다. 링은 슬롯마다 `Atomic.t` 다. 요약은 nearest-rank p50/p95/p99/max/mean 과 1초 이상 stall 수.
- 프로브는 `mark_owner_state_ready` 직후 메인 도메인에서 fork 한다. 부팅 재생은 정상 상태 lag 로 세지 않는다. 프로브 안의 예외는 프로브만 멈추고 `stopped_reason` 으로 보고한다. 서버 switch 를 취소하지 않는다.
- `/health` `.gc` 에 `minor_collections`·`major_collections`·`forced_major_collections`·`minor_words`·`promoted_words`·`major_words`·`space_overhead` 를 더한다. 전부 누적값이라 두 번 읽으면 비율이 나온다. `Gc.quick_stat` 그대로다.
- `/health` `.scheduler` 는 `probe` 상태, `interval_ms`, `window_s`, `stall_threshold_ms`, `samples`, 백분위, `stalls`, `pool_domains` 를 싣는다.
- `scripts/harness/perf/scheduler_lag_probe.sh` 는 실행 중인 서버에 붙어 `/health` 지연 백분위, `.scheduler`, 두 번 읽은 `.gc` 의 비율을 찍는다. 문턱값은 없다. 기준선이 먼저다.

## 4. 수용 기준

- Phase 0: 배포 뒤 `scheduler_lag_probe.sh` 출력 두 벌(부팅 직후 2분, 안정 후)을 이 RFC 에 붙인다. 그 값이 Phase 1~4 의 기준선이다.

### 4.1 기준선 — 2026-09-05 18:03 KST, build `dd6c9861c0`, 재기동 직후

Phase 0·0b·1 이 머지된 빌드. 호스트는 오후의 load 80~300 상태가 아니라 평상 부하였다(별도 측정 없음, 같은 날 저녁).

| 읽기 | 부팅 직후(ready 후 36초) | 안정 후(ready 후 약 6분) |
|---|---|---|
| `/health` p50 / p90 / max (30회) | 27ms / 288ms / 1,833ms | 2ms / 50ms / 109ms |
| 프로브 p50 / p95 / p99 / max | 1.5ms / 263ms / 556ms / 973ms | 1.6ms / 100ms / 191ms / 312ms |
| 프로브 mean / 1초 이상 stall | 50.6ms / 0 | 15.8ms / 0 |
| minor / major (분당) | 4,087 / 12.0 | 3,451 / 17.8 |
| 할당 / 승격 (MB/s) | 304 / 24.8 | 425 / 31.9 |
| heap / live (MB) | 2,558 / 2,457 | 2,845 / 2,673 |

이 부팅의 창: 포트 열림 09:03:05Z → `Domain_pool created` 09:03:17Z → keeper loop 시작·프로브 시작 09:03:41Z (36초). ready 3초 전에 읽은 `/health` 가 이미 heap 2,663MB / live 2,649MB 였다. **live 2.6GB 는 keeper 가 돌기 전에 부팅이 만든다.**

### 4.2 힙 루트 — 같은 빌드, ready 후 약 2분, 걷기 281ms

| 루트 | reachable |
|---|---|
| `exact_lane_runs` | 545.2 MB |
| `activity_graph_caches` | 44.6 MB |
| `board_attention_partition_caches` | 20.4 MB |
| `keeper_owner_pools` | 3.8 MB |
| `dashboard_snapshot` | 3.2 MB |
| `verification_runs` / `keeper_registry` / `telemetry_trajectory_summaries` | 0.9 / 0.8 / 0.1 MB |
| `goal_verification_runs` / `fusion_runs` / `sse_clients` | 0 |

등록 루트 합계 619MB, live 2,529MB. **약 1.9GB 는 등록된 루트에 없다.** keeper owner 가 3.8MB 인 것은 Agent Core 상태가 owner 가 아니라 keeper run fiber 의 지역 값으로 산다는 뜻이고, 그건 루트로 등록할 수 없다. 그래서 다음 계기는 루트 등록이 아니라 `Gc.Memprof` 로 할당 지점별 잔존량을 통계적으로 재는 것이다(Phase 0c).

### 4.3 이 기준선이 바꾸는 것

- 안정 후 메인 도메인 lag p99 191ms, stall 0. 오후의 3~10초 정지는 호스트 포화와 재시작 churn 이 만든 것이었고, 평상 부하에서는 GC 압력이 남는다.
- 할당 425MB/s 와 major 17.8/분은 15개 도메인이 3.4초마다 2.67GB 를 마킹한다는 뜻이다. Phase 4 의 표적은 exact-lane 545MB(요약만 상주, 본문은 run_id 로 디스크에서)와 Memprof 가 가리킬 할당 상위 지점이다.
- Phase 2(systhread 경계)는 stall 0 인 지금 기준선으로는 순서를 뒤로 미룬다. 프로브가 stall 을 보이면 다시 앞으로.
- 이후 단계는 위 표의 기준을 같은 스크립트로 증명한다. 호스트 load 를 함께 적는다. load 가 다르면 비교하지 않는다.

## 5. 하지 않는 것

- 타임아웃을 늘리거나 갱신 주기를 줄여 라벨만 바꾸는 것. 증상 억제다.
- 로그를 줄이거나 dedup 하는 것. 로그는 원인이 아니다(시간당 8,800줄).
- `Gc.set` 값을 측정 없이 올리는 것. 0 의 카운터로 minor/major 비율을 본 뒤에 결정한다.
- keeper 본문을 워커 도메인으로 옮기는 것. RFC-0059 가 affinity 문제로 철회했고, 그 전제(소유권 모델, RFC-0239)가 아직 없다.

## 6. 위험

- 프로브 fiber 는 100ms 마다 깨는 fiber 하나다. 비용은 sleep 하나와 float 하나 쓰기다.
- `/health` 응답이 필드 11개 늘어난다. 읽는 쪽(TUI `Tui_decode.decode_server_identity`)은 모르는 필드를 무시한다.
- 링을 다른 도메인에서 읽으면 한 슬롯이 덮어쓰기 중일 수 있다. 값은 옛것 아니면 새것이다. 진단 용도로 충분하다.

## 7. Phase 2 재고 조사 — systhread 로 가는 클로저 (2026-09-05, HEAD `ba554f5cc7`)

`Eio_unix.run_in_systhread` 와 `Eio_guard.run_in_systhread` 호출 55곳을 읽었다. OCaml 5.5 매뉴얼 §5.1 대로 한 도메인에서는 systhread 하나만 OCaml 코드를 돌리므로, systhread 안에서 OCaml 로직이 도는 시간만큼 메인 스케줄러는 서 있다.

### 7.1 그대로 두어도 되는 것 — 닫힌 syscall 집합의 후보

| 호출 | 자리 |
|---|---|
| `fsync` / `fchmod` on fd | `fs_compat.ml:1901`, `capability_recovery_obligation.ml:1426,1457,2190`, `atomic_write.ml:803,817,833,893`, `capability_head.ml:330,340`, `keeper_tool_filesystem_runtime.ml:1087` |
| `stat` / `fstat` / `lstat` / `realpath` | `fs_compat.ml:1091,1102,1175`, `capability_exact_read.ml:157`, `keeper_checkpoint_store.ml:379`, `server_runtime_bootstrap.ml:844`, `server_dashboard_http_delete_actions.ml:60` |
| `read` / `write` on fd | `capability_exact_read.ml:170`, `blocking_write.ml:13` |
| `openat` | `capability_exact_read.ml:147` |
| `mkdir` / `rename` / `remove` / `rmdir` / `unlink` / `chmod` / `readdir` / `file_exists` | `server_skill_editor.ml:546,569,757`, `server_routes_http_dashboard_dev_token.ml:194`, `server_dashboard_http_delete_actions.ml:114`, `keeper_owner_registry.ml:142`, `auth_credential_base.ml:58-64` |

이 집합이 Phase 2 의 `Blocking_syscall.t` 생성자 목록이다. 각 생성자는 인자와 반환 타입이 정해진 순수 C 호출이다.

### 7.2 systhread 안에서 OCaml 로직이 도는 것 — 옮겨야 한다

| 클로저 | 자리 | 무엇이 도는가 |
|---|---|---|
| `load_owned_regular_file_{with_snapshot,prefix,range}_blocking` | `fs_compat.ml:942,996,1052` | 파일 전체를 문자열로 읽는 루프 |
| `Keeper_fs.save_atomic` 본문 | `keeper_fs.ml:321` | temp 열기·쓰기·rename 을 잇는 제어 흐름 |
| durable directory chain 준비 | `keeper_fs_durable_directory.ml:359,485,534` | stat 걷기와 fsync 순서 결정 |
| `Fs_compat.cleanup_atomic_orphans` | `fusion_delivery_obligation.ml:477`, `keeper_msg_async.ml:1845` | readdir + unlink 루프 |
| `remove_tree_blocking` | `keeper_shutdown_finalize.ml:464`, `fs_compat.ml:1168` | 재귀 삭제 |
| `Keeper_wire_capture.prune_expired` | `server_runtime_bootstrap.ml:1182` | readdir + 판정 + unlink |
| `Store.store` / `Store.load` | `keeper_vision_tool.ml:123,126` | 바이트 쓰기/읽기 |
| `detect_system_fd_snapshot_now` | `keeper_fd_pressure.ml:266` | 시스템 fd 스냅샷 |

### 7.3 임의 클로저를 받는 래퍼 — Phase 2 가 지우는 것

`run_blocking_private_file_transaction` (`fs_compat.ml:1946`), `Keeper_board_attention_partition.run_blocking` (`:833`), `Skill_catalog_snapshot_service.run_blocking` (`:78`), `Backend.run_blocking_file_op` (`:223`), `Mcp_server_eio_resource.run_blocking_resource_io` (`:31`), `Keeper_owner` 의 systhread 래퍼 (`:440`), `Server_routes_http_routes_workspace` (`:374`, `Effect.Unhandled` 면 인라인으로 되돌리는 분기까지 있다), `Server_skill_editor` (`:630`), `Keeper_fs.run_in_systhread_cancel_checked` (`:238`), `Keeper_checkpoint_store` 의 `read` (`:465`), 그리고 `Eio_guard.run_in_systhread` 자체.

이 래퍼들은 `unit -> 'a` 를 받으므로 무엇이든 systhread 로 들어간다. Phase 2 는 이 시그니처를 `'a Blocking_syscall.t -> 'a` 로 바꾼다. 그러면 7.2 의 클로저는 컴파일되지 않고, 호출자는 syscall 만 넘기고 나머지 로직은 fiber 나 domain pool 에서 돌리게 된다. 55곳을 손으로 한 곳씩 고치는 대신 컴파일러가 전부를 열거한다.

### 7.4 이 조사가 말하지 않는 것

7.2 의 클로저가 실제로 락을 얼마나 오래 쥐는지는 여기 없다. Phase 0 의 프로브가 배포되면 `stalls` 와 p99 로 먼저 보고, 그 다음에 7.3 의 래퍼를 없앤다.

## 8. Phase 4 표적 — Memprof 실측 (2026-09-05 19:15 KST, build `c94f057edc`)

Phase 0c 가 머지된 빌드를 재기동하고 2분 뒤와 6분 뒤에 `GET /api/v1/diagnostics/memprof` 를 읽었다. 비율 1e-5, 두 읽기 사이 4분에 누적 할당 63.6GB → 169.6GB, 즉 **약 440MB/s**. live 추정 2.9GB → 2.8GB. 같은 시각 `/health` 는 minor 4,935/분, major 23.9/분, 할당 606MB/s(부팅 직후 창), live 3.1GB 였다.

### 8.1 스테디 상태 할당 상위 (두 읽기의 차)

| 할당 지점 (masc 호출자) | 4분간 | 뜻 |
|---|---|---|
| 사이트 표 상한 초과 묶음 | 8.5GB | 표가 2만 개에 차서 귀속 못 함 (§8.4) |
| `Keeper_checkpoint_store.load_canonical_bytes_strict` (read + read_fd) | 5.2GB | keeper 턴마다 13~20MB 체크포인트를 디스크에서 다시 읽는다 |
| `Fs_compat.update_private_file_durable_locked_with_io` → `read_fd_chunks` | 1.8GB | board-attention 원장을 통째로 읽는다 |
| `Keeper_board_attention_candidate.parse_rows` → `Yojson.Safe.from_string` | 1.4GB | 그 원장의 행 1,137개를 매번 다시 파싱한다 |
| `Fs_compat.load_file_opt` ← `rewrite_private_file_durable_locked_result` | 1.3GB | 같은 원장을 다시 쓰기 위해 또 읽는다 |
| `Yojson.Safe.to_string` + `write_string` | 2.7GB | 체크포인트·원장 재직렬화 |
| `Yojson.Safe.from_string` (입력 복사) + 렉서 | 3.1GB | `Lexing.from_string` 은 입력 전체를 복사한다 |

턴은 분당 약 12회(시스템 로그 10:15~10:22Z). 턴 하나가 체크포인트를 읽고(15MB → 문자열 2벌) 파싱하고(`Yojson.Safe.t`) 직렬화해 쓴다. `keeper_owner_pools` 가 3.8MB 인 이유가 이것이다. Agent Core 상태는 메모리에 살지 않고 매 턴 디스크에서 다시 태어난다.

### 8.2 board-attention 원장

`.masc/board_attention_candidates/` 는 키퍼당 파일 하나, 합계 9,376행 124MB, 가장 큰 파일 25.5MB 에 1,137행, 행 평균 15.4KB, 최대 772KB. 행의 거의 전부가 `judgment_request` 다(100KB 넘는 행 484개). `update_ledger_many` 는 갱신마다 파일 전체를 읽고, 행마다 파싱하고, 최신 행만 남겨 다시 직렬화하고, 통째로 다시 쓴다(주석 "Compact on write"). 갱신은 분당 약 20회(로그의 `board_attention` 행). 즉 분당 약 500MB 를 읽고 파싱하고 다시 쓴다.

### 8.3 부팅 전용 비용

`Keeper_approval_queue.install_persistence_internal.replay` 가 `Dated_jsonl.iter_all_entries_result` 로 모든 월·일 파일을 줄 단위로 읽어 파싱한다. 첫 읽기(부팅 2분)에서 5.3GB, 두 번째 읽기의 차에는 없다. 부팅 창(11~61초)의 한 몫이다.

### 8.4 계기 자체의 한계

- 사이트 키가 호출 스택 16프레임이라 클로저·fiber 경로마다 키가 갈려 2만 개 상한에 닿았고 8.5GB 가 묶음으로 갔다. 키는 masc 프레임(`lib/`·`bin/`)만으로 만들어야 한다.
- `Obj.reachable_words` 는 대기 fiber 의 스택을 세지 않는다(#33290). 체크포인트가 fiber 지역값이라는 §4.2 의 추정과 8.1 의 실측이 맞물린다.

### 8.5 Phase 4 설계 — 순서대로

**P4a. board-attention 원장을 다시 쓰지 않는다.** — #33312 로 들어갔다. 원장은 `Fs_compat` 의 private JSONL 커서 프로토콜(파티션 저장소가 쓰는 것)로 옮겼다. `Keeper_board_attention_candidate` 가 경로마다 "id 별 최신 행" 상태를 프로세스 안에 들고, 읽기는 커서 뒤의 바이트만 읽고, 쓰기는 바뀐 행만 그 커서에 append 한다. 디코드된 행이 살아 있는 후보의 2배를 넘거나 디코드 실패 행이 있으면 다음 쓰기가 최신 집합으로 다시 쓴다(`needs_compaction`). 파일 형식은 그대로다. 설계와 다른 점: 상태는 파티션 캐시가 아니라 후보 원장 모듈에 있다(파일이 다르다). 그리고 temp+rename 계열(`rewrite_private_file_durable_locked_result`)은 같은 경로에서 커서 계열과 섞을 수 없어 읽기·쓰기·압축 셋 다 커서 계열이다. 두 번째 단계(`judgment_request` 를 blob 으로)는 그대로 운영자 결정으로 남는다.

**P4b. 체크포인트를 매 턴 다시 파싱하지 않는다.** — 1단계가 #33319 다. 저장소가 canonical 경로마다 요약(`session_id`·`turn_count`·메시지 수)과 그 값을 읽은 파일의 identity(device·inode·size·mtime)를 들고, 저장 워터마크(`known_watermark`)와 하트비트 메시지 수(`canonical_message_count`)는 identity 가 같으면 파일을 읽지 않는다. 8.1 의 `load_canonical_bytes_strict` 5.2GB/4분은 이 워터마크 재읽기였고, 하트비트는 keepalive 마다 13~20MB 를 정수 하나 때문에 읽고 있었다. 설계와 다른 점: 체크포인트 값 전체는 캐시하지 않는다. 코덱 왕복(`to_json` → `of_json`)이 값을 그대로 돌려준다는 증명이 없고, keeper 당 20MB 값을 한 벌 더 들면 major GC 가 도는 live heap 이 그만큼 는다. 2단계(턴 시작 로드가 마지막으로 쓴 값을 재사용)는 실제 체크포인트로 왕복 동일성을 시험으로 증명한 뒤에 간다. CAS 경로(`save_agent_core_if_source`)는 sha256 비교에 바이트가 필요해 이번엔 그대로다. 재측정에서 남으면 요약에 ref 를 얹는다.

**P4c. exact-lane 본문은 디스크에.** 목록 API 는 이미 요약만 보낸다(`routes_dashboard.ml:1459`). 상주하는 `run` 은 입력·출력 본문(`Exact_input` 의 payload, `Completed.output`) 을 통째로 들고 있고, 그것도 두 벌이다(`Store` 항목과 `projection`). 계획: 본문은 `Tool_blob_store.put_durable` 로 content-addressed 저장하고 행에는 sha256 참조만 남긴다. 저장소 버전은 v5 → v6 하드컷이다(v4 → v5 선례처럼 새 바이너리는 v5 를 열지 않는다; 완료된 실행 이력은 컷 시점에 비워진다). `list_runs`·요약 직렬화는 참조만 들고, 상세(`run_detail_json` → `get` + `Tool_blob_store.fetch`)에서만 본문을 읽는다. 삭제는 새로 만들지 않는다. `Tool_blob_maintenance` 가 이미 참조를 아는 2단계 청소(observe → 이전 후보 삭제)를 닫힌 소비자 루트 목록(`durable_consumer_basenames`: gate·keepers·keeper_chat·messages·tool_calls·traces·wire-capture)에 대해 돌리고, 계약은 "참조를 남기는 새 소비자는 같은 변경에서 이 목록에 등록한다"이다. 실행 저장소 파일은 지금 `<masc_dir>/exact-lane-runs-v5.jsonl` 로 루트에 있어 어느 루트에도 안 들어간다. 그래서 v6 는 새 디렉터리 루트 아래에 두고 그 basename 을 목록에 넣는 것이 P4c 첫 PR 의 절반이다(나머지 절반이 `put_durable` 참조와 v6 코덱). 기대: live −545MB.

**P4d. Memprof 키를 masc 프레임으로.** 8.4 의 한계 제거. 이 RFC 의 다음 PR.

**P4e. 승인 큐 스냅샷을 다시 쓰지 않는다.** `gate/pending.json` 은 23 MB(deliveries 4,937건, pending 0, 중앙값 4.4 KB·최대 106 KB)인데, `persist_pending_entry_unlocked`·`persist_exact_attempt_entry_unlocked` 가 승인 항목 하나가 바뀔 때마다 `Yojson.Safe.pretty_to_string` 으로 통째로 다시 쓴다. 두 번째 재기동의 4분 창에서 12.4 GB, 이 창의 가장 큰 단일 묶음이다. P4a 와 같은 부류이고 같은 처방이다: 항목 단위 append 로그 + 프로세스 안 상태, 압축은 비율로. 그 전에 제품 판단 하나 — deliveries 는 replay·grant 소비·remember 규칙을 위해 남는데, 지워지는 경로가 하나(`SMap.remove`, :3567)뿐이라 끝없이 자란다. 감사 원장(`audit-approvals/`, 75 MB dated)이 따로 있으니 deliveries 는 projection 이고 retention 을 가질 수 있는지 확인한다.

P4e 설계. 상태는 이미 프로세스 안에 있다(`pending`·`deliveries` 가 `Atomic` SMap 이고 부팅의 `install_persistence` 가 한 번 읽는다). 변경마다 스냅샷을 통째로 쓰는 것이 유일한 비용이므로, 바뀐 항목 하나를 `pending.log.jsonl` 에 append 한다(`Fs_compat` 커서 계열, P4a 와 같은 잠금 한 계열). 행은 `pending_upsert`·`pending_remove`·`delivery_upsert`·`delivery_remove`·`next_sequence` 다섯 종류이고 재생은 멱등이다(id 로 add/remove, sequence 는 max). 부팅은 스냅샷 + 로그 재생. 로그 행이 (pending + deliveries) 의 2배를 넘으면 스냅샷을 다시 쓰고(compact `to_string`, pretty 아님) 로그를 커서에서 비운다. 스냅샷을 먼저 쓰고 로그를 비우므로 그 사이에 죽어도 재생이 멱등이라 상태가 같다. 스냅샷 버전은 9 → 10 으로 올린다. 로더가 다른 버전을 "reset runtime state before restarting" 으로 거부하는 기존 경로가 곧 하드컷이고, 로그를 모르는 옛 바이너리가 v10 을 열어 해결된 승인을 다시 pending 으로 보이는 일을 막는다. 컷 시점 비용: pending 은 지금 0, deliveries 4,937건은 사라진다 — 잃는 것은 소비 안 된 grant(키퍼가 다시 승인을 청한다, fail-closed 방향)와 replay 결과 표시뿐이고 remember 규칙은 `always-allowed.json` 에 따로 있다. 결정 둘: 컷을 받아들일지, deliveries 에 retention 을 둘지(감사 원장이 따로 있으니 projection 으로 볼 여지가 있다). 기대: 이 창 기준 −12 GB/4분, 스냅샷 크기가 10배 커져도 변경당 비용은 항목 하나.

각 단계는 같은 하네스로 전후를 잰다. P4a 뒤 할당 −20% 이상, P4b 뒤 −25% 이상, P4c 뒤 live −500MB 이상이 기대치이고, 못 미치면 그 단계는 되돌린다.

### 8.6 상태와 재측정 (2026-09-05)

| 단계 | PR | 상태 |
|---|---|---|
| P4d Memprof 키 | #33305 | merged |
| P4a 원장 append | #33312 | merged |
| P4b 요약 캐시 | #33319 | merged |
| P4c 본문 디스크 | — | 설계만 (8.5) |

#### 재측정 — 11:10Z 재기동, 세 PR 이 든 빌드

부팅: 11:08:30Z 포트 응답(ready 아님) → 11:10:15Z 이전 ready. 측정 토큰은 `~/me/.masc/auth/admin.token`(환경의 `MASC_OPERATOR_TOKEN` 은 401).

| 읽기 | ready+36초 | ready+6분 |
|---|---|---|
| `/health` p50 / p90 / max | 17 / 88 / 388 ms | 2 / 49 / 561 ms |
| lag p50 / p95 / p99 / max | 3.3 / 106 / 411 / 762 ms | 1.2 / 66 / 163 / 291 ms, stall 0 |
| alloc (10초 창) | 460 MB/s | 804 MB/s |
| major/분 | 11.9 | 5.9 |
| heap / live | 2,898 / 2,797 MB | 4,182 / 3,933 MB |

memprof, ready+3분 → +7분(240초): 누적 150.5 → 353.9 GB = **848 MB/s**(기준선 440). sites 8,031 → 11,962(상한 50,000; 기준선은 20,001 로 상한 초과). dropped 0. 같은 5분의 `/health` 차: alloc 678 MB/s, promoted 45 MB/s, minor 5,978/분, major 13.8/분(기준선 17.8).

작업량은 같지 않다. 시스템 로그 `agent_core:agent_started` 가 이 4분에 27건, 기준선 창(10:17~10:21Z)에 20건. 턴당 할당은 7.5 GB 대 5.3 GB. 원격 lane 키퍼 둘(lane-smith·rondo)이 이 창에서 가장 시끄러웠다.

**P4a·P4b 의 표적은 사라졌다.** `update_ledger_many`·`rewrite_private_file_durable_locked_result`·`read_fd_chunks`·`parse_rows`·`load_canonical_bytes_strict` 어느 것도 상위 30 에 없다. 30위가 부팅 포함 누적 1.63 GB 이므로 각각 전체 1.6 GB 미만이고, 전에는 4분에 5.2 GB·4.5 GB 였다. 이 창의 상위(4분 차, masc 호출자):

| 할당 지점 | 4분간 | 뜻 |
|---|---|---|
| `Agent_core.Checkpoint_codec.content_block_of_json_strict` ← `Llm_provider.try_parse_json` | 8.2 GB | 턴 시작마다 체크포인트를 디코드한다 |
| masc 프레임 없음(`<unknown>` 7.6, Eio sched 4.8, `Format.make_formatter` 3.9, Buffer 2.7) | 19 GB | 라이브러리 프레임이 16 프레임 창을 다 쓴다 → #33332 |
| `Yojson.Safe.write_string` 계열 (Buffer.resize) | 11 GB | 체크포인트 저장 + 측정용 직렬화 |
| `Keeper_turn_driver_try_provider.measure_message_bytes` (+ `project_with_drop` 경유) | 5.0 GB | 메시지 바이트를 재려고 턴마다 다시 직렬화. 메모는 턴 안에서만 산다 |
| `Keeper_remote_path.consume` ← `flush_stream` | 4.5 GB | 바이트마다 `String.sub` — 2차식 → #33329 |
| `Fs_compat.with_io` (Cstruct create + copy_to_string) | 3.8 GB | 턴 시작 체크포인트 읽기 (20 MB × 2) |
| `Keeper_event_queue_persistence.read_json_if_present` ← `load_state_unlocked_with_primary_detail` | 3.3 GB | 이벤트 큐 스냅샷을 통째로 다시 읽는다 |
| `Dated_jsonl.iter_all_entries_result` ← `Keeper_reaction_ledger` (:1160, :1223) | 2.1 GB | 반응 원장을 월·일 파일 전부 다시 훑는다 |

live 3.59 → 4.06 GB(4분에 +0.47 GB). 힙 루트: `exact_lane_runs` 564 MB(불변), `keeper_owner_pools` 67 → 74 MB(기준선 3.8 MB), `board_attention_partition_caches` 21 MB, `activity_graph_caches` 49 MB. live 표 상위: `try_parse_json` 0.42 GB, `Run_registry_core.parse_event_line` 0.32 GB(= exact-lane), `Checkpoint_codec.of_string` 0.22 GB, `Keeper_board_attention_candidate.parse_rows` 0.14 + 0.12 GB(P4a 가 상주시킨 최신 집합, 4분간 변화 0).

#### 판정

- 8.5 의 "P4a 뒤 −20%, P4b 뒤 −25%" 는 같은 작업량을 가정한 기대치였고, 이 창으로는 판정할 수 없다. 사이트 단위 효과는 확인됐고 되돌릴 근거는 없다.
- 총량은 줄지 않았다. 나머지가 크고, 그 가운데 가장 큰 덩어리는 **턴 시작 재로드**다: 디코드 8.2 + 읽기 3.8 + 측정용 재직렬화 5.0 = 17 GB/4분. 메시지 레코드가 턴마다 디스크에서 다시 태어나므로 물리 동일성 메모도 턴을 넘겨 살 수 없다. P4b 2단계(마지막으로 쓴 값을 identity 가 같으면 재사용)가 이 셋을 한꺼번에 없앤다. 그 전제인 코덱 왕복 동일성은 실제 체크포인트로 시험한다.
- 그다음: remote-path 2차식(#33329), 이벤트 큐 스냅샷 재읽기(3.3 GB — `snapshot_result` 가 registry 에 없는 키퍼마다·`durable_state_result` 가 매번 파일을 읽는다), 반응 원장 전체 스캔(2.1 GB), 귀속 안 된 19 GB(#33332 뒤 다시 읽는다).
- live 가 기준선보다 1.2 GB 크고 4분에 0.47 GB 늘었지만, 세 번째 읽기(+7분 → +20분, 801초)에서 4.06 → 3.64 GB 로 내려왔다. 누수가 아니라 그 4분의 버스트다. 같은 13분의 할당은 453 MB/s 로 기준선 수준이고, 이 창의 상위는 `try_parse_json` 17.7 GB, masc 프레임 없음 20 GB, Yojson 쓰기 24 GB, `Dated_jsonl.recent_entry_of_line` 7.8 GB, 이벤트 큐 스냅샷 7.1 GB 순이다. `Keeper_remote_path.consume` 은 원격 lane 이 조용해지자 상위에서 빠졌다. 즉 4분 창의 848 MB/s 는 원격 lane 두 키퍼의 버스트였고, 스테디는 기준선과 같은 자리에서 조성만 바뀌었다.
- 계기 한계 하나 더: `sites` 가 8,031 → 11,962 → 16,814 로 3분에 약 1천씩 는다. 이대로면 두 시간 안에 50,000 상한에 닿아 overflow 묶음이 다시 생긴다. 키 6 프레임 안에서 무엇이 갈리는지(Eio 프레임·클로저 줄 번호)는 보고서가 상위 30 만 주어 지금은 못 본다. 다음 읽기에서 `sites` 와 overflow 를 먼저 보고, 갈리면 키에서 Eio 프레임도 빼는 것을 검토한다.


#### 두 번째 재기동 — 11:47Z, #33329(remote-path 커서)·#33332(48 프레임) 포함

ready 11:49:07Z 이전. memprof A(ready+3분) → B(+7분), 239초: **428 MB/s**, live 3.92 → 3.03 GB, sites 9,826 → 12,066(4분에 +2.2k, 계속 는다), dropped 0. 하네스 ready+7분: `/health` p50 2 ms·max 143 ms, lag p50 1.6 / p95 94 / p99 165 / max 420 ms, stall 0, minor 4,375/분, major 6.0/분, promoted 26 MB/s, live 2,967 MB. 이 4분의 `agent_core:agent_started` 13건.

| 할당 지점 (48 프레임) | 4분간 |
|---|---|
| `Keeper_approval_queue.persist_snapshot_{exact,with_sequence}_unlocked` 6행 합 | 12.4 GB |
| Eio 프레임이 키를 다 차지한 행 | 6.5 GB |
| 체크포인트 디코드 `content_block_of_json` 3.5 + `validate_checkpoint_json` 1.8 | 5.3 GB |
| `measure_message_bytes` 2.5 + 1.4, `serialized_bytes ← apply_post_turn_lifecycle` 1.8 | 5.7 GB |
| `Keeper_reaction_ledger` 전체 스캔 | 2.5 GB |
| 이벤트 큐 스냅샷 재읽기 | 2.4 GB |

`Keeper_remote_path.consume` 은 상위에서 사라졌다(#33329; 원격 lane 이 조용했을 가능성은 남는다). `keeper_owner_pools` 는 2 MB 로 돌아왔다 — 앞 재기동의 67 MB 는 P4a 가 아니라 그때의 키퍼 상태였다. Eio 프레임 문제는 #33339(키 skip 목록에 Eio 접두어).

#### 세 번째 재기동 — 12:08Z, #33339(키에서 Eio 프레임 제외) 포함

memprof A(ready+3분) → B(+7분), 240초: 584 MB/s(이 4분에 `agent_started` 24건), live 3.40 → 3.32 GB, sites 8,313 → 11,679 — Eio 프레임을 빼도 4분에 +3.4k 이므로 사이트 증가의 원인은 다른 데 있다(클로저 줄 번호로 보이나 상위 30 만으로는 못 본다). 하네스 ready+7분: lag p99 320 ms, minor 9,603/분, major 23.8/분(그 10초 창은 바빴다). 상위: 승인 큐 스냅샷 재작성 6행 합 13.8 GB, 체크포인트 디코드 7.1 GB, `measure_message_bytes` 5.6 + 2.9 GB, 반응 원장 스캔 2.5 GB. **P4e 는 #33349** 로 열었다: 델타 append + generation + 비율 압축 + v10. 재기동 전에 `gate/pending.json`·`replay-results.json` 을 지워야 한다(안 지우면 저장소가 unsupported version 으로 unavailable). 소비된 grant 의 tombstone 은 크래시 뒤 재실행을 막는 durable truth 라("consumption tombstone remains explicit" 시험이 못박는다) retention 은 이 PR 의 범위 밖이고, 나이 제한은 별도 결정이다.

#### 네 번째 재기동 — 12:31Z, #33347(exact-lane projection 에서 본문 제거) 포함

힙 루트 ready+3분: `exact_lane_runs` **530 MB**(전 564 → 559 → 530). #33347 은 projection 의 `run` 사본에서 `input`·`output` 을 `Null` 로 바꿨지만 `Run_registry_core` 의 `Store.entry` 는 `registration`(입력)과 `Completed.output` 을 그대로 든다. projection 의 본문은 코어 항목과 같은 값을 물리적으로 공유했으므로 `Obj.reachable_words` 는 이미 한 번만 세고 있었고, 사라진 것은 `run` 레코드 자체(약 30 MB)뿐이다. **P4c 의 −545 MB 는 아직 남았다.** 본문을 메모리에서 빼려면 코어 항목이 본문 대신 참조(8.5 의 `Tool_blob_store` 참조 + v6 컷)를 들어야 한다. 상세 조회가 JSONL 줄에서 `"id":"<run_id>"` 부분 문자열로 행을 찾는 것도 같은 PR 에서 정본 디코더로 바꿔야 한다.

memprof A → B(240초): **1,103 MB/s** — 이 4분에 `agent_started` 58건(앞 창들의 2~4배)이라 턴당으로는 4.6 GB(앞 창 5.3~7.9). live 3.86 → 4.00 GB, sites 9,994 → 13,877. 하네스 ready+7분: lag p99 315 ms, max 2.36 s, stall 2(바쁜 창). 상위(4분 차): 체크포인트 디코드 8.9 GB, `measure_message_bytes` 6.7 + 3.6 GB, 승인 큐 스냅샷 재작성 6.1 + 3.9 + 3.4 GB(#33349 표적), **`Keeper_event_queue_persistence.save_state_unlocked` 3.6 GB**(이벤트 큐 상태 파일을 변경마다 통째로 쓴다 — P4a·P4e 와 같은 부류, 다음 표적), **`Tool_misc_web_fetch.extract_title` 3.3 GB**(가져온 HTML 전체를 제목 하나 때문에 훑는다).

#### 다섯 번째 재기동 — 12:49Z, #33349(P4e) 포함, 승인 저장소 v10 으로 새로 시작

첫 재기동(12:41Z)은 v9 `pending.json` 을 지우지 않아 저장소가 "version 9 is unsupported" 로 unavailable 이었고 승인이 8분간 막혔다. 두 파일을 `_archive/gate-v9-20260905/` 로 옮기고 다시 올렸다. 하드컷 PR 의 재기동 절차는 PR 본문만으로 전달되지 않는다 — 병합 직후 운영자에게 다시 말해야 한다.

memprof A(ready+3분) → B(+7분), 240초: **162 MB/s**(`agent_started` 29건, 턴당 1.3 GB; 앞 창들 4.6~7.9 GB). live 2.83 → 2.90 GB, sites 5,085 → 6,951. 하네스 ready+7분: lag p50 1.2 / p95 31 / p99 98 / max 281 ms, stall 0, minor 1,702/분, major 0/분(10초 창), promoted 9.7 MB/s. **승인 큐 스냅샷 재작성 행은 상위 30 에서 사라졌다**(델타 0). 로그는 2행(해결 하나: pending_remove + delivery_upsert), 스냅샷은 v10 generation 4(항목이 몇 개뿐이라 비율 압축이 자주 돈다). 남은 상위(4분 차): `measure_message_bytes` 2.2 + 1.2 GB, `Keeper_run_tools_setup.gate_history_slice` 2.2 GB(턴 준비마다 gate 이력 슬라이스), 체크포인트 디코드 1.9 GB, `Keeper_tool_call_log.read_recent` 1.1 GB, 비밀 문자열 redaction 스캔 1.0 + 0.85 GB. 작업 조성이 다르므로 절대값 비교는 턴당으로만 한다.

#### 발견: 워커 도메인 14개는 내내 2 MiB minor heap 으로 돌았다

`bin/main_eio.ml` 의 `setup_gc` 는 메인 도메인에서 `Gc.set { minor_heap_size = 4M words }` 를 부른다. OCaml 5.4 런타임 소스로 확인한 사실: `caml_gc_set` 은 `Caml_state->minor_heap_wsz` — 호출한 도메인의 것 — 만 바꾸고, 새 도메인은 `domain_create(caml_params->init_minor_heap_wsz, …)` 로 만들어져 `OCAMLRUNPARAM` 의 `s` 값(기본 256k words = 2 MiB)을 받는다(`runtime/gc_ctrl.c`, `runtime/domain.c`, 2026-09-05 확인). 그래서 `Executor_pool` 의 도메인 14개는 2 MiB 로 돌았고, #33351 이 `/health` 를 전용 서빙 도메인으로 옮기자 `.gc.minor_heap_size` 가 32 MiB 에서 2 MiB 로 바뀌어 드러났다(다섯 번째 재기동). OCaml 5 의 minor 수집은 모든 도메인이 함께 멈추므로, 한 도메인이 2 MiB 를 채울 때마다 15개가 선다 — 분당 3,000~9,600회의 출처다.

#### GC 파라미터 실험 (8.5 의 "카운터를 본 뒤 결정")

두 단계. 첫째는 설정 오류의 교정이라 변수 하나만 바꾼다: `OCAMLRUNPARAM='s=4M,o=100'` 로 재기동해 모든 도메인이 코드가 의도했던 32 MiB 를 받게 한다(`o=100` 은 부트스트랩이 `OCAMLRUNPARAM` 이 있으면 적용하지 않는 space_overhead 100 을 그대로 두기 위함). 기대: minor/분이 1/10 이하, lag p99 감소. 둘째는 튜닝: `s=32M,o=200`(도메인당 256 MiB, 15개면 3.8 GB; space_overhead 200 으로 major 절반). 코드 쪽 후속: 도메인마다 `Gc.set` 을 부르는 초기화(서빙 도메인 클로저 첫 줄, 풀은 weight 1.0 작업 `domain_count` 개를 latch 로 묶어 도메인마다 하나씩) 를 기본값으로 넣어 환경 변수 없이도 맞게 한다.
### 8.7 GC 실험 1 과 링 버퍼 실측 — main 도메인을 붙잡는 것은 GC 가 아니라 턴 조립이다 (2026-09-05 13:00Z~13:27Z)

#### GC 실험 1 — 변화 없음

`OCAMLRUNPARAM='s=4M,o=100'` 으로 재기동했다(13:01:56Z, build `9d6cac6551`). 이 빌드는 서빙 도메인을 따로 사이징하지 않는데 `/health` 가 32 MB 를 읽었으므로 환경변수가 새 도메인에 적용됐다. 같은 하네스 두 번:

| | 다섯 번째 재기동(P4e, 워커 2 MB) | 실험 1(모든 도메인 32 MB) |
|---|---|---|
| ready+36초: lag p99 / minor/min / alloc | 111 ms / 1,571 / 247 MB/s | 117 ms / 1,790 / 144 MB/s |
| ready+7분: lag p99 / minor/min / alloc | 98 ms / 1,702 / 139 MB/s | 144 ms / 1,782 / 202 MB/s |
| memprof A→B 4분 | 162 MB/s, 턴당 1.3 GB | 160 MB/s, major 직행 43%, live 3.08→3.04 GB |

minor heap 을 16배 키워도 STW minor 횟수가 같다. 힙이 차서 도는 것이 아니다. 실험 2(`s=32M,o=200`)는 하지 않는다 — 같은 이유로 움직일 것이 없다. #33360 이 같은 사이징을 코드로 넣었고(제출 경로마다 도메인 진입 시 한 번, 서빙 도메인 포함) 그것으로 충분하다.

#### OCaml 5.5.0 런타임 원문으로 확인한 것

- `/health` 의 `minor_collections` 는 `caml_minor_collections_count` 이고 STW 의 setup 콜백에서 STW 당 한 번 오른다(`runtime/minor_gc.c` `caml_empty_minor_heap_setup`). 하네스의 minor/min 은 STW 횟수 그대로다.
- 2 KB 를 넘는 블록은 major heap 으로 바로 가고, 도메인당 그 양이 minor heap 의 1/5 를 넘을 때마다 전역 major 슬라이스를 요청한다(`runtime/memory.c` `caml_alloc_shr`). 이것은 모든 도메인이 참여하는 STW 구간이다(`runtime/domain.c` `stw_global_major_slice`). 할당의 43% 가 major 직행이라 이 STW 가 minor STW 만큼 잦다(아래 90초 창: STW 리더 704회 중 minor 325회).
- 256 워드보다 큰 배열을 젊은 블록으로 채우면(`Array.make`·`Array.of_list`·`Array.init`) 그 자리에서 minor GC 를 강제한다(`runtime/array.c` `caml_uniform_array_make`, 카운터 `EV_C_FORCE_MINOR_MAKE_VECT`). remembered set 임계도 같다(`runtime/minor_gc.c` `realloc_generic_table`).
- masc 코드에는 `Gc.stat`·`Gc.full_major`·`Gc.compact`·`Domain.spawn` 이 없다. `/health` 는 `Gc.quick_stat` 이다.

#### 링 버퍼 실측

masc 는 runtime events 를 기본으로 켠다(`Masc_runtime_events.start_listener`, `MASC_RUNTIME_EVENTS` 기본 true). 링은 서버 cwd 의 `<pid>.events` 다. stdlib `runtime_events` 와 `eio.runtime_events` 만으로 소비 프로그램 둘을 만들어 붙였다(`tools/rtev_trace/`, #33377). 하나는 GC 구간·카운터와 "STW 에 마지막으로 도착한 도메인", 다른 하나는 도메인별 fiber 의 연속 실행 시간과 그 앞뒤 suspend 이유다. Eio 는 링이 켜져 있으면 fiber 전환과 suspend 를 그대로 내보낸다.

90초 창(13:23:26Z~, build `718a0df327`, 같은 창에서 하네스: lag p99 68 ms·max 321 ms, minor/min 66, major/min 6, alloc 77 MB/s):

| GC 구간(15 도메인 합) | 횟수 | 합계 | 평균 | p99 | 최대 |
|---|---|---|---|---|---|
| `stw_handler` | 9,856 | 8.7 s | 0.9 ms | 9.4 ms | 19 ms |
| `minor_leave_barrier` | 4,875 | 6.6 s | 1.3 ms | 9.3 ms | 12.5 ms |
| `major`(슬라이스) | 9,817 | 2.3 s | 0.24 ms | 5.4 ms | 30 ms |
| `stw_api_barrier`(리더가 기다린 시간) | 5,055 | 1.9 s | 0.38 ms | 4.3 ms | 14.5 ms |

도메인 하나가 GC 에 쓴 시간은 90초 중 1.3초(1.4%)이고 한 번의 멈춤은 최대 30 ms 다. STW 에 마지막으로 도착한 도메인의 지연은 최대 10 ms. 목록의 맨 위에 오는 `domain_condition_wait`(최대 340 ms)는 GC 가 아니라 systhread 의 `Condition.wait` 다(`runtime/sync.c`). 100 ms 를 넘는 lag 는 GC 로 만들 수 없다.

같은 창의 fiber 실행:

| 도메인 | fiber 실행 | 점유 | ≥10 ms | ≥50 ms | ≥100 ms | 최대 |
|---|---|---|---|---|---|---|
| 0(main) | 129,692 | 11.2% | 121 | 48 | 23 | 229 ms |
| 1~14(pool) | 1.8k~8.2k | 0.7~3.6% | 6~15 | 1~9 | 1~7 | 1,114 ms |

main 도메인에서 가장 긴 실행 여섯 개는 전부 turn 스팬 안의 fiber 가 168~229 ms 계산한 뒤 `openat` 으로 멈춘 것이고, 그 안의 GC 는 17~52 ms 다. 그 fiber 는 직전에 `Fiber.yield` 로 물러났던 것이라(Eio 의 빈 suspend 이유가 그것이다) 턴 코드는 양보를 하긴 하지만 양보 사이에 200 ms 를 계산한다. 다음은 `fstat` 뒤 최대 141 ms 계산하고 다시 `fstat`(파일을 stat 하고 읽어 파싱하는 루프). pool 도메인의 1초짜리 실행은 `Executor_pool` 작업 하나가 통째로 도는 것이라 main 의 lag 와 무관하다.

같은 프로세스의 main 스레드를 macOS `sample` 로 20초(1 ms 간격, 15,706 샘플) 찍었다. 71% 는 `Iomux.Poll.poll`(유휴). 나머지에서 포함 시간이 큰 함수(전체 샘플 대비, 같은 줄의 함수들은 서로 중첩된다):

| 함수 | 비율 |
|---|---|
| `Keeper_world_observation_inputs.tasks_with_identities` | 3.0% |
| `Yojson.Safe.write_string_body` 2.9%, `__ocaml_lex_finish_string_rec` 2.6%, `iter2_aux` 1.5%, `read_json` 1.1% | 직렬화·파싱 |
| `Bytes.sub` | 2.6% |
| `Llm_provider.Utf8_sanitize.is_clean` 1.8%, `sanitize` 1.3%, `Inference_utils.sanitize_content_blocks_utf8` 0.7%, `sanitize_message_utf8` 0.4%, `Bytes.get_utf_8_uchar` 0.9% | 히스토리 UTF-8 검사 |
| `Re.Compile.loop` 1.7%, `make_match_str` 1.7% | 정규식 매칭 |
| `Keeper_context_core_message_json.message_to_json` 1.5%, `content_block_to_history_json` 1.2%, `content_blocks_to_json` 1.1%, `Api_common.content_block_to_json_with` 1.2% | 히스토리를 JSON 으로 |
| `Keeper_run_tools_setup`(gate history) | 1.5% |
| `Otel_runtime_observables.go` | 0.9% |

memprof 상위(`try_parse_json`·`measure_message_bytes`·`gate_history_slice`·`Buffer.resize`·`secret_patterns`)와 같은 자리다. 결론: **main 도메인의 p99 는 턴 조립 — 히스토리 전체의 JSON 재직렬화·UTF-8 재검사·정규식·gate history — 이 main 도메인 위에서 한 번에 200 ms 씩 도는 것**이고, GC 파라미터로는 움직이지 않는다.

#### 다음 — P4g. 턴 조립을 main 도메인에서 내린다

둘을 같이 한다. 둘 다 히스토리가 지금보다 몇 배 커져도 main 의 lag 가 그만큼 늘지 않게 하는 쪽이다.

1. **직렬화와 sanitize 는 메시지가 히스토리에 들어올 때 한 번만.** 지금은 매 턴 전체 히스토리를 다시 JSON 으로 만들고 다시 UTF-8 검사한다. 메시지 레코드에 직렬화 결과를 붙여 두면 턴은 새 메시지 것만 만든다(P4b 2단계의 코덱 왕복 증명이 선행). sanitize 는 쓰기 시점에 한다. 읽을 때마다 검사하는 것은 경계 강제가 아니다.
2. **턴 조립(요청 본문·redaction·gate history)을 `Domain_pool` 로.** 턴 fiber 는 promise 를 기다리고 main 은 다른 fiber 를 돈다. HTTP 라우트가 `Domain_pool_ref` 로 이미 하는 방식이다. 넘기는 값은 불변 레코드와 문자열이어야 한다(#33353 의 도메인 간 mutex 규칙).

`Fiber.yield` 를 더 자주 넣는 것은 하지 않는다. 계산량은 그대로이고 양보 지점을 손으로 고르는 것이라 히스토리가 커지면 다시 늘어난다.

판정은 같은 90초 창의 fiber 추적으로 한다: main 도메인의 ≥100 ms 실행 23 → 0, ≥50 ms 48 → 한 자리, 하네스 p99 100 ms 대 → 20 ms 아래.

### 8.8 P4g 진행 — 턴 조립을 main 도메인에서 내리는 조각들 (2026-09-05 13:40Z~)

#### P4g 기준선 (pid 69198, build `59dad55196`, ready+3분, 90초, 부하 높은 창)

| 항목 | 값 |
|---|---|
| 하네스 lag p99 / max | 153 ms / 552 ms |
| 할당 / STW minor / major | 617 MB/s / 561/min / 11.9/min |
| main 도메인 fiber 실행 / 점유 | 103,918 / 12.6% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 |
| main 의 최대 실행 | 954 ms (`fstat` → 계산 → `fstat`, 안의 GC 151 ms, 부모 스위치 이름 `both`) |

954 ms 짜리는 턴 스팬 밖이고 파일을 stat 하고 읽어 파싱하는 루프 부류다. 어느 코드인지는 아직 못 잡았다(fiber 추적기가 생성 지점을 모른다 — 다음 도구 개선: 생성한 fiber 의 사슬과 이름 있는 스위치를 함께 적는다). 같은 프로세스의 30초 스택 샘플(바쁜 17%)은 8.7 과 같은 상위였다.

#### 한 메시지가 턴마다 몇 번 직렬화되는가 (코드 추적)

| 어디서 | 몇 번 | 대상 | 도메인 |
|---|---|---|---|
| gate 증거 조각 `Keeper_run_tools_setup.gate_history_slice` | tool call 의 gate 마다 | **히스토리 전체** | main |
| 바이트 예산 측정 `measure_message_bytes` | 턴 1회(attempt 메모) | 히스토리 전체 | pool (`offload_model_input_cpu`) |
| provider 요청 본문 `Prepared_completion_request.admit_serialized_body` → `serialize_final_http_request_unadmitted` | **요청마다(턴당 62~83)** | 창 안 메시지 전체 | main (agent_core 에 pool 없음) |
| reasoning 투영 `Complete_common.transmitted_history` | 요청마다 | 히스토리 전체 | main |
| 턴 종료 `serialized_bytes`(post-turn·상태 상세·tool memory) | 턴 1회 + 조회마다 | system prompt + 히스토리 전체 | main |
| provider input 스냅샷 `Keeper_provider_input_snapshot.write_best_effort` | 턴 1회 | 창 안 메시지 전체를 직렬화 + SHA-256 | main |
| 히스토리 append `persist_message` | 새 메시지마다 | 새 메시지(두 번 sanitize) | main |
| 체크포인트 인코드 | 턴 중 저장마다 | 전체 | pool (`offload_checkpoint_cpu`) |

`message_to_json` 은 부를 때마다 `sanitize_message_utf8` 을 먼저 돌리고, `message_of_json`(체크포인트 재로드)도 돌린다. `sanitize` 는 깨끗하면 같은 값을 그대로 돌려주므로 비용은 검사 스캔이다.

#### 조각

- **P4g-0 (#33384)**: gate 증거 조각이 히스토리 전체가 아니라 예산 창만 직렬화한다. 고르는 결과는 같다.
- **P4g-1 (#33387)**: `serialize_context`·`serialized_bytes` 삭제. `checkpoint_bytes` 는 저장소가 아는 파일 크기(P4b 요약 identity)이고 `int option` 이다. 뜻이 "디스크의 canonical 체크포인트 크기"로 바뀐다.
- **P4g-2 — provider 요청 본문 직렬화를 실행기로.** agent 레코드에 `pre_dispatch_serialization_observer` 와 같은 자리로 `serialization_executor : { run : 'a. (unit -> 'a) -> 'a } option` 을 두고, `pipeline_stage_route` 의 `admit_request_body` 두 자리(동기·스트리밍)를 그것으로 감싼다. masc 는 `Domain_pool_ref.submit_cpu_or_inline` 을 넘긴다. 감싸는 부분은 `serialize_final_http_request_unadmitted` 와 admission 뿐이고, 입력(`config`·`messages`·`tools`)은 불변 값이다. 안에서 `Reasoning_history_projection.observe` 가 `Diag.info` 로 로그를 내는데 그 싱크는 `Stdlib.Mutex` 라 다른 도메인에서도 된다. `request_wire_observer` 는 그 뒤 main 에서 부른다. `Eio_context.with_turn_switch` 는 fiber-local 이라 pool 로 전파되지 않지만 이 경로는 읽지 않는다(agent_core 는 그것을 모른다). 요청마다 히스토리 크기에 비례해 main 을 붙잡던 가장 큰 덩어리가 이것이다.
- **P4g-3 — provider input 스냅샷의 직렬화와 해시를 pool 로.** `store_artifact` 가 `message_to_json |> to_string` 과 `Digestif.SHA256` 을 메시지마다 돌린다(C 해시는 실행 중 양보가 없다). 순수한 부분(payload·sha 목록)을 `Domain_pool_ref.submit_cpu_or_inline` 으로 먼저 계산하고, 재사용 조회와 `put_durable`(파일 I/O)·append 는 main 에 남긴다.
- **P4g-4 — `Keeper_world_observation_inputs.tasks_with_identities`.** 관찰마다 백로그 전체의 task id 를 `Task_id.of_string` 으로 다시 파싱한다(main 스레드 2~3%). 백로그 스냅샷에 revision 이 있으므로 같은 revision 이면 앞 결과를 쓴다.
- **그 뒤**: 메시지가 히스토리에 들어올 때 한 번 sanitize 하고 그 사실을 타입으로 들고 가면(`message_to_json`·`message_of_json` 의 매번 sanitize 제거), 남는 것은 요청마다 창을 다시 인코딩하는 것뿐이다. 그것은 메시지 단위 직렬화 조각을 attempt 안에서 물리 동일성으로 메모해 이어 붙이는 일이고 agent_core 의 백엔드 직렬화기 설계라 별도 RFC 절이 필요하다.

각 조각 뒤 판정은 8.7 의 도구로 같은 창을 잰다.

#### P4g-0·1 뒤 (pid 12826, build `c6be119966`, ready+3분, 90초, 14:24Z)

| 항목 | 기준선(P4g 전) | P4g-0·1 뒤 |
|---|---|---|
| 하네스 lag p99 / max | 153 ms / 552 ms | 68 ms / 417 ms |
| main 도메인 점유 | 12.6% | 20.6% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 244 / 138 / **8** |
| main 의 최대 실행 | 954 ms | **133 ms** |
| 할당 / STW minor / major | 617 MB/s / 561/min / 11.9/min | 205 MB/s / 263/min / 0/min |

두 창은 부하가 다르다(점유 12.6% → 20.6%, 할당은 반대로 617 → 205 MB/s). 그래서 p99 의 차이는 참고치이고, 읽을 것은 **긴 꼬리**다: 100 ms 를 넘는 실행이 19 → 8 로, 최대가 954 → 133 ms 로 줄었다. 50 ms 대 실행이 는 것은 요청마다 창을 다시 직렬화하는 P4g-2 가 아직 안 들어간 상태에서 부하가 늘어난 결과로 본다. main 의 상위 10 실행에 이제 main 도메인 것이 없다(전부 pool 도메인의 `Executor_pool` 작업과 private JSONL 읽기 루프). 같은 빌드에 다른 세션의 #33394(RFC-0423, exact-lane run 본문을 보여줄 때 읽는다 — 이 RFC 의 P4c 에 해당)도 들어 있다.

열린 조각: P4g-2 #33395(직렬화 실행기, CI 초록), P4g-4 #33397(task 식별자 메모).

#### P4g-2·4 뒤 (pid 72105, #33395·#33397 포함, ready+3분, 90초, 14:38Z)

| 항목 | 기준선(P4g 전) | P4g-0·1 뒤 | P4g-2·4 뒤 |
|---|---|---|---|
| 하네스 lag p99 / max | 153 ms / 552 ms | 68 ms / 417 ms | **15.8 ms / 33.9 ms** |
| main 도메인 점유 | 12.6% | 20.6% | 4.0% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 244 / 138 / 8 | 46 / 4 / **0** |
| main 의 최대 실행 | 954 ms | 133 ms | **57 ms** |
| 할당 / STW minor / major | 617 MB/s / 561/min / 11.9/min | 205 MB/s / 263/min / 0/min | 29.7 MB/s / 24/min / 0/min |

이 창은 앞 둘보다 조용하다(할당 29.7 MB/s, 점유 4.0%). 그래서 p99 는 부하가 오른 창에서 다시 재야 하고, 남는 판정 근거는 꼬리의 모양이다: 100 ms 를 넘는 실행이 없고, 50 ms 를 넘는 것이 4개, 최대가 57 ms 다. main 의 10 ms 이상 실행 46개 중 33개가 `openat` 뒤 최대 57 ms 계산하고 양보하는 한 부류다(파일을 열어 읽고 파싱하는 루프, 아직 귀속 안 됨 — #33403 의 생성 사슬로 잡는다). pool 도메인의 긴 실행은 여전히 `Executor_pool` 작업 하나(최대 511 ms)와 private JSONL 읽기 루프(최대 255 ms)이고 main 의 lag 와 무관하다.

P4g-3(#33401, 스냅샷의 직렬화·해시를 pool 로)은 이 창 뒤에 병합됐고 아직 라이브가 아니다. P4g 의 코드 조각 0~4 는 전부 main 에 있다.

#### 전체 P4g 라이브 (pid 35053, #33401 포함, ready+3.7분, 90초, 14:52Z)

| 항목 | 기준선 | P4g-0·1 | P4g-2·4(조용한 창) | 전체 P4g |
|---|---|---|---|---|
| 하네스 lag p99 / max | 153 / 552 ms | 68 / 417 ms | 15.8 / 33.9 ms | 70.8 / 409 ms |
| main 도메인 점유 | 12.6% | 20.6% | 4.0% | 15.6% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 244 / 138 / 8 | 46 / 4 / 0 | 191 / 106 / 11 |
| main 의 최대 실행 | 954 ms | 133 ms | 57 ms | 427 ms |
| 할당 / STW minor / major | 617 MB/s / 561 / 11.9 | 205 / 263 / 0 | 29.7 / 24 / 0 | 62 / 48 / 0 |

부하가 다시 오른 창에서 꼬리가 돌아왔다. 다만 **부류가 바뀌었다**. 기준선의 긴 실행은 turn 스팬 안에서 `Fiber.yield` 뒤 `openat` 으로 끝나는 턴 조립이었고, 이 창의 긴 실행은 turn 스팬 밖(깊이 0)의 오래 사는 fiber 가 `fstat`·`openat` 사이에서 계산하는 것이다: `openat -> switch` 79회 합 5.0초(최대 141 ms), `fstat -> fstat` 16회(최대 427 ms), `fstat -> Mutex.lock` 3회(최대 156 ms). 같은 창의 main 스레드 40초 샘플(바쁜 13.3%)에서 masc 쪽 상위는 `Dated_jsonl.loop` 4.0% + `load_tail_lines_from_channel` 3.4% + 나머지 `Dated_jsonl` 3%(합 약 10%), `Fs_compat_internal.Atomic_write.save_file_atomic_with_parent_sync` 2.7% + `fsync_path_with` 0.4%, `Keeper_chat_store.parse_line`·`load_all` 0.9%, `Keeper_memory_os_current.read_journal_tail_*` 0.9%, `Keeper_ask_store.load_events` 0.4%, `Keeper_wire_capture.redact_json_strings` 0.3% 이고, 그 아래 공통 프레임은 Yojson 렉서와 `Re` 매칭이다.

P4g 가 겨냥한 턴 조립은 main 에서 사라졌다. 남은 것은 **날짜별 JSONL 저장소의 꼬리 읽기(`in_channel` 로 열어 줄마다 파싱)와 fsync 를 동반한 원자 쓰기가 main 도메인 위에서 도는 것**이고, 이것은 7절의 Phase 2(§7.2 `load_owned_regular_file_*_blocking`·`save_atomic`·durable directory chain)가 가리킨 바로 그 자리다.

두 번째 표본(pid 38197, 같은 서버 코드, ready+3.4분, 90초, 15:02Z, 할당 344 MB/s·점유 9.2%): 하네스 p99 51.6 ms·max 215 ms, main 의 ≥10/≥50/≥100 ms 실행 130/33/8, 최대 141 ms. 긴 실행의 부류는 같다 — turn 스팬 밖에서 `openat -> switch` 24회(합 1.7초, 최대 109 ms), `fstat -> fstat` 10회(합 0.9초, 최대 141 ms), `fstat -> openat` 35회. 이 창의 40초 샘플은 조용했고(바쁜 3.7%) masc 쪽 상위는 `save_file_atomic_with_parent_sync` 2.9%, `Keeper_checkpoint_store`, `Keeper_toml_parser.parse_toml`, `Keeper_ask_store.load_events` 였다. 두 창 모두에서 turn 스팬 안의 100 ms 초과 실행은 0 이다.

#### 다음 — P4h. Dated_jsonl 꼬리 읽기와 원자 쓰기를 main 에서 내린다

- `Dated_jsonl.load_tail_lines_from_channel` 의 호출자는 `telemetry_unified`·`tool_usage_log`·`keeper_transition_audit`·`keeper_status_detail`·`keeper_tool_call_log`·approval `audit`·`eval_calibration`·`audit_log`·chat store·provider input 스냅샷의 dedup 이다. 파일을 열어 꼬리를 읽고 줄마다 JSON 을 파싱한다. 읽기(syscall)는 systhread 로, 파싱은 pool 로, 결과만 fiber 로 돌아온다. 호출자가 원하는 것은 "최근 N 개" 이므로 P4a 처럼 파일마다 커서를 두고 새 줄만 읽는 것이 근본 해결이다.
- `Fs_compat_internal.Atomic_write.save_file_atomic_with_parent_sync` 는 temp 쓰기·fsync·rename·부모 fsync 를 main fiber 에서 한다. §7.3 의 `Blocking_syscall.t` 로 syscall 만 넘긴다.
- 판정: 같은 창에서 main 의 `openat -> switch`·`fstat -> fstat` 부류 합계(이번 창 6.4초/90초)와 ≥100 ms 실행 11 → 0.

#### P4h-0 뒤 (pid 77804, #33416 포함, 15:35Z~15:38Z, 기동 15:31:09Z)

하네스와 스택 샘플 1은 ready+4분(15:35Z), fiber 추적·GC 추적·스택 샘플 2는 그 직후 90초(15:36:44Z~15:38:14Z)다. 도구 경로를 잘못 불러 첫 추적이 비어서 두 창으로 나뉘었다.

| 항목 | 기준선 | 전체 P4g(1) | 전체 P4g(2) | P4h-0 |
|---|---|---|---|---|
| 하네스 lag p99 / max | 153 / 552 ms | 70.8 / 409 ms | 51.6 / 215 ms | 84.0 / 324 ms |
| main 도메인 점유 | 12.6% | 15.6% | 9.2% | 9.2% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 191 / 106 / 11 | 130 / 33 / 8 | 84 / 31 / **4** |
| main 의 최대 실행 | 954 ms | 427 ms | 141 ms | 200 ms |
| 할당 / STW minor / major | 617 MB/s / 561 / 11.9 | 62 / 48 / 0 | 344 / — / — | 121 / 107 / 6.0 |

옮긴 일은 pool 도메인에 그대로 보인다: 도메인 1~14 에 100~1,229 ms 짜리 단일 작업(`(first run) -> exit`, 날짜별 JSONL 읽기)과 `fs-compat-private-jsonl-read` 246~299 ms 가 찍힌다. main 에 남은 100 ms 넘는 실행은 넷이다 — `Promise.await -> fstat` 200 ms(그중 GC 34.9 ms), `sleep -> sleep` 170 ms, `openat -> switch` 143 ms.

스택 샘플 1(40초, main 스레드 busy 4,977/32,062 = 15.5%)에서 `Dated_jsonl` 은 상위 30 프레임에서 사라졌다(직전 창에서 busy 의 약 10%). 남은 큰 덩어리는 전부 커널 대기다.

| 프레임 | 샘플(1 ms) | 내용 |
|---|---|---|
| `Atomic_write.save_file_atomic_with_parent_sync` | 490 | 486 이 `rename` syscall 한 번 |
| `Eio_posix.Low_level` spawn | 250 | `fork()` 안 `_malloc_fork_parent` 141, 2 GB 힙의 malloc zone 잠금 |
| `Eio_posix.Low_level` writev | 221 | 파일 쓰기 201 이 커널 |

샘플 2(15:36:44Z)는 busy 6.7% 로 조용했고 상위는 `Otel_runtime_observables` 139, Yojson 문자열 쓰기 124 다.

P4h-1 #33421(뒤로 읽는 스캔 `find_latest_entry_result`·`collect_matching` 을 청크마다 pool 작업 하나로, 호출자 필터는 fiber) 은 이 창 뒤에 병합됐고 아직 라이브가 아니다.

#### P4h-2 — 원자 교체의 커밋 syscall 을 systhread 로 (#33426)

`fs_compat` 은 `Domain_pool_ref` 를 볼 수 없다. `masc_core` 가 `fs_compat` 에 의존하고 `Eio_guard` 가 `Fs_compat` 을 쓴다. 그래서 pool 대신 같은 파일이 이미 디렉터리 fsync 에 쓰는 `Eio_unix.run_in_systhread` 를 쓴다. `save_file_atomic_with_parent_sync` 의 페이로드 fsync·rename·부모 fsync 세 syscall 이 fiber 안에서는 systhread 작업 하나로 돌고, Eio 밖에서는 inline 이다. Eio 컨텍스트 판별은 `Fs_compat.execution_context` 에서 `fs_compat_internal.Execution_context` 로 내려가 `Atomic_write` 가 쓴다. 실패 단계와 취소 보고는 그대로다. eio 의 thread pool 이 작업 스레드의 예외를 그 백트레이스와 함께 fiber 에서 다시 던진다(`eio/unix/thread_pool.ml:73,134`). 임시 파일 생성과 `Eio.Path.save` 는 fiber 에 남는다.

남은 표적 하나는 pool 로도 systhread 로도 못 내린다. `Eio.Process.spawn` 은 eio_posix 가 `fork()` 로 구현하고 자식 실행 전 부모의 malloc zone 을 전부 잠근다. 힙이 2 GB 인 지금 한 번에 141 ms 다. switch 와 proc_mgr 가 부르는 fiber 의 도메인에 묶여 있어 다른 도메인으로 옮길 수 없다. 턴당 스폰 횟수를 줄이거나 스폰 전용 보조 프로세스를 두는 것이 방향이고, 별도 절이 필요하다.

#### P4h-1 뒤, 무거운 창 (pid 61274, 커밋 75e904a8c2 = P4h-0·1 라이브, 15:55:13Z ready+4분, 90초)

| 항목 | 기준선 | 전체 P4g(1) | P4h-0 | P4h-1(무거운 창) |
|---|---|---|---|---|
| 하네스 lag p99 / max | 153 / 552 ms | 70.8 / 409 ms | 84.0 / 324 ms | **234.7 / 848 ms** |
| main 도메인 점유 | 12.6% | 15.6% | 9.2% | 20.2% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 191 / 106 / 11 | 84 / 31 / 4 | 233 / 66 / **24** |
| main 의 최대 실행 | 954 ms | 427 ms | 200 ms | 512 ms |
| 할당 / STW minor / major | 617 MB/s / 561 / 11.9 | 62 / 48 / 0 | 121 / 107 / 6.0 | 106 / 107 / 5.9 |

이 창은 재기동 4분 뒤 keeper 들이 첫 턴을 도는 때다. 꼬리의 부류가 P4g 이전으로 돌아갔다. 가장 긴 실행 여섯(512·448·431·429·412·387 ms)이 전부 **turn 스팬 깊이 2** 의 한 fiber(cc#68)이고 `openat`·`fstat` 으로 끝난다. 스택 샘플 40초(main 스레드 busy 10,034/31,971 = 31.4%)는 그 안에서 무엇이 도는지 말한다.

| 프레임 | 샘플(1 ms) | 내용 |
|---|---|---|
| `Re.Compile.loop` + `Re.Compile.make_match_str` | 1,793 + 1,766 | 정규식 컴파일과 첫 매칭의 DFA 채우기 — busy 의 **35%** |
| `Yojson` 읽기·쓰기 | 약 1,000 | 턴 조립 |
| `Filename.try_name` | 211 | `Filename.temp_file` 의 O_EXCL 열기 |

귀속된 정규식 프레임은 전부 `Secret_patterns.redact_text` ← `Keeper_chat_store.redact_message` / `redact_approval_lifecycle` 와 `Keeper_secret_redaction.snapshot_with_additional_secret_files` 다. 코드는 `keeper_secret_redaction.ml` 의 `List.map (fun value -> Re.compile (Re.str value)) values`: 스냅샷을 만들 때마다 비밀 파일을 전부 읽고 값마다 컴파일한다. 부르는 곳은 채팅 기록 로드(`Keeper_chat_store.redaction_for`, 로드마다), 커넥터 수신, 스트림 투영·재생, 대시보드 채팅 조작이다. 새 `Re.re` 는 DFA 표가 비어 있어 `replace_string` 이 첫 사용 때 다시 채우므로 컴파일과 매칭 둘 다 매번 처음부터다.

같은 창의 pool 도메인에는 2.4~6.9초짜리 단일 작업(도메인 14: 6,863 ms) 이 있다. 날짜별 JSONL 의 큰 day 파일 읽기다. main 에서 내린 일이 pool 을 채우는 것이라 다음은 "새 줄만" 읽는 커서(§8.8 P4h 계획) 차례다.

#### P4h-4 — 비밀 값 스냅샷을 소스 스탬프로 메모 (#33436)

순회를 열거와 읽기로 나눈다. 열거는 매번 하고(정규 파일마다 `lstat`), 파일의 (device, inode, size, mtime) 이 같은 인자로 메모된 것과 하나도 다르지 않으면 메모된 스냅샷을 돌려준다. 메모는 `Domain.DLS` 로 도메인별이다. 컴파일된 `Re.re` 는 매칭 중 DFA 표를 바꾸므로 도메인 간에 공유하면 안 된다. 값 추출 규칙과 `dedupe` 정렬은 그대로라 결과가 같다.

P4h-3 #33429(OTel 저장소 순회를 pool 로) 는 15:57Z 에 병합됐고 P4h-2 와 함께 아직 라이브가 아니다.

#### P4h-0~3 라이브, 깨끗한 창 (pid 96654, 커밋 a25083442b, 16:14:16Z ready+6.6분, 90초)

| 항목 | 기준선 | 전체 P4g(1) | P4h-0 | P4h-1(무거운 창) | P4h-0~3 |
|---|---|---|---|---|---|
| 하네스 lag p99 / max | 153 / 552 ms | 70.8 / 409 ms | 84.0 / 324 ms | 234.7 / 848 ms | **15.8 / 37.4 ms** |
| main 도메인 점유 | 12.6% | 15.6% | 9.2% | 20.2% | 6.7% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 109 / 37 / 19 | 191 / 106 / 11 | 84 / 31 / 4 | 233 / 66 / 24 | 106 / 11 / **0** |
| main 의 최대 실행 | 954 ms | 427 ms | 200 ms | 512 ms | **74 ms** |
| 할당 / STW minor / major | 617 MB/s / 561 / 11.9 | 62 / 48 / 0 | 121 / 107 / 6.0 | 106 / 107 / 5.9 | 162 / 197 / 6.0 |

할당 162 MB/s 로 조용한 창이 아닌데 main 에 100 ms 를 넘는 실행이 없다. 남은 최장 실행은 turn 스팬 안(깊이 2·4)의 74·72·71·70·69 ms 다. 스택 샘플(main 스레드 busy 3.6%)의 상위 30 에 `rename`, `Otel_runtime_observables`, `Dated_jsonl`, `Re.Compile` 이 없다. 정규식은 이 창에 채팅 로드가 없어 안 보인 것이고 P4h-4 는 아직 라이브가 아니다.

같은 서버의 앞선 창(16:09:32Z, ready+2분, 래퍼 프로세스가 잠깐 겹침): 하네스 p99 56.9 ms·max 1,180 ms, main 점유 7.0%, ≥100 ms 실행 0, 최대 91.8 ms, 샘플의 `Re.Compile` 517/2,407 busy(21%).

pool 도메인의 긴 작업은 이 창에서 최대 475 ms 다. 무거운 창의 2.4~6.9초 작업은 대시보드 telemetry 조회(`Telemetry_unified.bounded_entries_for_window`, RFC-0372 의 요청당 상한 안에서 하루 80~200 MB 의 `tool_calls`·`agent-core-events` 를 읽음)였고 keeper 턴 경로가 아니다. `Eio.Executor_pool` 은 큐 하나에서 도메인이 남은 용량만큼 작업을 가져가고, io 작업의 무게가 0.05 라 한 도메인이 io 작업 20개를 fiber 로 함께 든다. 읽기 작업은 양보하지 않으므로 6.9초짜리 하나가 같은 도메인의 나머지 19개를 그만큼 세운다. keeper 턴의 읽기도 이제 같은 pool 에 서므로 "새 줄만" 읽는 커서(P4h 계획)가 그 다음이다.

#### 옮길 수 없는 대기 — 프로세스 스폰의 `fork()`

`Eio.Process.spawn` 은 eio 1.3 의 `lib_eio_posix/eio_posix_stubs.c:412` 에서 `fork()` 로 자식을 만든다. macOS 의 libmalloc 은 fork 직전 부모의 모든 malloc zone 을 잠그는데(`_malloc_fork_parent` → `_xzm_foreach_lock`), 힙이 1~2 GB 인 이 프로세스에서 그 잠금이 한 번에 약 141 ms 다. 스택 샘플 40초당 스폰 안의 시간은 250·167·32·17 ms 로 도구 실행량에 비례한다. 스폰이 가장 많은 곳은 `keeper_sandbox_microvm`, `exec_dispatch`, `keeper_turn_sandbox_runtime` 이다.

이 대기는 pool 로도 systhread 로도 못 내린다. `Eio.Process.spawn` 이 받는 switch 와 proc_mgr 가 부르는 fiber 의 도메인에 묶여 있다. 남는 방향은 셋이고 각각 별도 RFC 감이다.

| 방향 | 내용 | 비용 |
|---|---|---|
| `posix_spawn` 스텁 | masc 소유 C 스텁으로 `posix_spawn(2)` 를 부르는 process backend. macOS 의 `posix_spawn` 은 시스템 콜이라 atfork 핸들러와 zone 잠금이 없다 | C 스텁·fd 상속·cwd·env 처리·취소 계약을 새로 만듦 |
| 스폰 보조 프로세스 | 힙이 작은 보조 프로세스가 스폰만 맡고 파이프로 fd 를 넘김 | 프로토콜·수명 관리·fd 전달 |
| 턴당 스폰 축소 | 같은 턴에서 반복되는 `git`·셸 호출을 묶음 | 도구 계약 변경 |

#### P4h-4 라이브 (pid 27910, 커밋 f91917f5e2 = P4h-0~4, 16:23:41Z 기동)

두 창을 잡았다. 부팅 직후 창(16:26:39Z, ready+3분)은 첫 턴들이 몰리는 때이고, 표준 창(16:28:10Z, ready+4.5분)은 호스트 부하 평균이 140 이던 때다(agy 97%, masc 89%, conmon 83%, fseventsd 78%, watchman 35%).

| 항목 | P4h-1(무거운 창) | P4h-0~3(깨끗한 창) | P4h-4 부팅 직후 | P4h-4 표준(호스트 과부하) |
|---|---|---|---|---|
| 하네스 lag p99 / max | 234.7 / 848 ms | 15.8 / 37.4 ms | **31.0 / 39.9 ms** | 66.5 / 147.8 ms |
| main 도메인 점유 | 20.2% | 6.7% | 14.4% | 28.0% |
| main 의 ≥10 / ≥50 / ≥100 ms 실행 | 233 / 66 / 24 | 106 / 11 / 0 | 218 / 38 / **0** | 428 / 114 / 17 |
| main 의 최대 실행 | 512 ms | 74 ms | **87 ms** | 219 ms |
| 할당 / STW minor / major | 106 MB/s / 107 / 5.9 | 162 / 197 / 6.0 | 193 / 173 / 6.0 | 198 / 165 / 5.9 |
| 샘플의 `Re.Compile` | 3,559 / 10,034 busy | — | **126** / 2,071 | 278 / 3,538 |

부팅 직후 창이 P4h-4 의 판정이다. 같은 부류의 창(첫 턴들, 점유 14~20%)에서 정규식 컴파일이 3,559 에서 126 샘플로 줄고, 100 ms 를 넘는 실행이 24 에서 0 이 됐다.

표준 창의 17회는 코드 부류로 읽을 수 없다. GC 추적의 `stw_handler` p99 72 ms·max 136 ms, `minor_leave_barrier` max 120 ms 는 OS 가 도메인을 선점해 STW 장벽에 늦게 도착한 것이고, 그 대기가 main 의 실행 안에 GC 시간으로 잡힌다. 호스트가 과포화되면 15 도메인 프로세스의 STW 는 가장 늦은 도메인을 기다린다. 이건 코드가 아니라 호스트의 문제다.

두 창 모두에서 main 의 10 ms 이상 실행 중 가장 큰 묶음은 `openat -> switch` 다(부팅 직후 131회 5,864 ms, 표준 82회 5,638 ms, 최대 87·178 ms). 이 부류는 P4g 이후 모든 창에 있었고 정체는 다음과 같다.

#### `openat -> switch` 의 정체 — 턴마다 읽는 35 MB 체크포인트 (P4h-5, #33453)

`Fs_compat.load_file` 의 Eio 경로는 `Eio.Path.load` 다. `with_open_in`(worker 스레드의 `openat`, 그래서 재개 사유가 `openat`) 안에서 파일을 fiber 위에서 끝까지 복사하고 `Switch.run` 이 닫히며 끝난다(종료 사유 `switch`). keeper 의 정본 체크포인트 `traces/<trace>/<trace>.json` 은 13~35 MB 이고 턴마다 이 경로로 읽혔다. 디코드는 이미 pool 에 있었지만 바이트 복사는 아니었다. 같은 디렉터리의 history 스냅샷 `agent-core-snapshot-*.json` 은 한 시간에 117개·1,350 MB 가 쓰였다. 쓰기는 `Keeper_fs.save_bytes_durable_atomic_core` 가 이미 `Eio_guard.run_in_systhread` 안에서 한다.

P4h-5 는 두 읽기(정본·history)를 `Fs_compat.load_owned_regular_file ~ownership_root:(dirname session_dir)` 로 바꾼다. 쓰는 쪽과 같은 소유 경계이고, Eio 파일시스템이 있으면 systhread 에서 읽는다. 심볼릭 링크와 바뀐 부모 체인은 `Io_error` 로 거절한다(전에는 따라갔다). 더 깊은 고침은 체크포인트 크기 자체다 — 35 MB 를 턴마다 읽고 쓰는 구조(§8.6 의 P4c, exact-lane 본문을 blob 참조로).
