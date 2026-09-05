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
