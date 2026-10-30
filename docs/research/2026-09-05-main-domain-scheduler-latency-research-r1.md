# 메인 도메인 지연 — 라이브 실측과 원인 모델 (r1)

측정일 2026-09-05 16:39–17:20 KST, base-path `/Users/dancer/me`, 서버 PID 19654(07:41Z 부팅) 와 73696(08:00Z 부팅), HEAD `ba554f5cc7`, 호스트 M3 Max 16코어 128GB.

## 요약

- TUI 가 `reconnecting...` 만 보이는 이유는 셋이 겹친 것이다. 서버가 하루 8~19번 재시작되고, 포트가 열린 뒤 최대 61초 동안 부팅 중이며, 살아 있는 동안에도 메인 도메인이 3~10초씩 멈춘다. 호스트 자체는 load 80~300 으로 포화 상태다.
- 메인 스레드는 CPU 를 쓰느라 바쁜 게 아니라 **기다린다**. 3초 샘플에서 메인 스레드 시간의 72% 가 blocking section 을 나온 뒤 도메인 런타임 락을 다시 잡는 대기(`caml_thread_leave_blocking_section → pthread_cond_wait`)였다. 실제 OCaml 코드 실행은 20% 였다.
- 힙은 2.7~5.5GB 를 오가고 live 는 2.5GB 다. 가장 유력한 단일 보유자는 exact-lane 레지스트리의 in-memory projection(6,000행, 디스크 텍스트 142MB, 행당 24KB)이다. 정확한 값은 측정 전이다.
- 이 문서는 수정 제안이 아니라 측정 기록이다. 수정은 `docs/rfc/RFC-main-domain-scheduler-latency.md` 가 단계별로 정한다.

## 1. TUI 증상의 정체

| 관찰 | 값 |
|---|---|
| `Reconnecting` 라벨 조건 | `start_http_refresh` 가 Connected/Degraded 에서 갱신을 시작하면 무조건 (`bin/masc_tui.ml:7341`) |
| `Connected` 복귀 조건 | 모든 surface 가 성공 (`refresh_status`, 하나라도 실패면 Degraded) |
| 기본 갱신 주기 | 2.0초 (`bin/masc_tui.ml:746`) |
| 요청 타임아웃 | 10초 (`bin/masc_tui_http.ml:4`) |

응답이 2초를 넘기면 화면은 거의 항상 reconnecting 이다. 소켓이 끊긴 게 아니다.

## 2. 재시작과 부팅 창

| 항목 | 값 |
|---|---|
| 오늘 부팅 | 8회 (04:14, 05:52, 06:33, 06:43, 07:04, 07:17, 07:40, 08:00 UTC) |
| 어제 부팅 | 19회 |
| 종료 사유 | `Received SIGINT ... sender is external (user/pkill/system)` |
| 깨끗한 종료 기록 없는 부팅 | 8회 중 3회 |
| main ff-pull | 16:29~16:57 KST 사이 5회, 바이너리 17:00:57 재빌드 직후 재기동 |
| 포트 열림 → `Domain_pool created` | 61s / 14s / 11s (07:04 / 07:40 / 08:00 부팅) |

포트가 먼저 열리므로 TUI 는 붙고, 부팅 중 요청이 10초 타임아웃에 걸려 떨어진다. 부팅 시간의 큰 몫은 `exact-lane-runs-v5.jsonl` 재생이다(§5).

## 3. 살아 있는 동안의 메인 도메인

`/health` 를 1초 간격 30회:

| p50 | p90 | max |
|---|---|---|
| 0.00s | 3.38s | 9.62s |

`sample 19654 3` (1,535 샘플, 메인 스레드):

| 메인 스레드가 있던 곳 | 샘플 | 비고 |
|---|---|---|
| `writev` 뒤 락 재획득 대기 | 315 | HTTP/SSE 쓰기 |
| `Stdlib.input` 뒤 락 재획득 대기 | 139 | 동기 파일 읽기 |
| `readv` 뒤 락 재획득 대기 | 116 | |
| `open` 뒤 락 재획득 대기 | 86 | |
| `Dated_jsonl.list_subdirs` → `readdir` | 84 | 디렉터리 스캔 |
| `waitpid` | 79 | 자식 프로세스 |
| `close` | 69 | |
| `connect` | 69 | 아웃바운드 HTTP |
| `Dated_jsonl.file_size` → `stat` | 65 | |
| `spawn` (fork) | 55 | 5GB 프로세스의 fork |
| `Atomic_write` → `fsync` | 45 | |
| `Sys.file_exists` | 43 | |

합계 약 1,100 / 1,535 = 72% 가 blocking syscall 과 그 뒤의 락 재획득이다. 프로세스 전체 leaf 상위는 `caml_lex_engine`(Yojson 파싱) 549, GC marking+sweep 약 580, `Yojson write` 202, UTF-8 정리, sha256/md5 순이다.

`ps -M` 기준 메인 스레드 88%, 두 번째 스레드 10.7%, 나머지는 3% 이하. 워커 도메인은 한가하다.

락을 잡고 있는 상대는 둘 중 하나다. 같은 도메인의 systhread(`Eio_unix.run_in_systhread`, 저장소에 약 60곳)와, stop-the-world GC 동안 도메인을 대신하는 backup thread. 샘플 파일에는 `stw` 프레임 196줄, `caml_try_run_on_all_domains` 60줄이 있다. 둘의 비중은 아직 나누지 못했다. RFC Phase 0 의 프로브가 그걸 가른다.

## 4. 대시보드 계산

시스템 로그 07:00–08:00Z:

| 항목 | n | 평균 | 최대 |
|---|---|---|---|
| `[snapshot_json] total` | 83 | 13.6s | 103s |
| `[snapshot_json] keepers_json` | 71 | 8.8s | 46s |
| `[snapshot_json] board_attention_quarantines` | 56 | 6.6s | 34.8s |
| `heavy refresh` shell | 20 | 15.3s, 78MB alloc | 139s |
| `heavy refresh` tools | 13 | 14.8s, 67MB alloc | 20s |
| `heavy refresh` shell_light (ttl 0) | 14 | 9.9s | 31s |
| `heavy refresh` activity_events_default | 3 | 5.3s, 392MB alloc | |

`Dashboard_snapshot.refresh_loop` 은 2초 주기 fiber 이고 `shell_light` 는 ttl 0 이라 매 주기 다시 계산한다. 계산 자체는 executor pool 로 넘어가지만, 할당은 모든 도메인의 STW 를 부르고 마킹 비용은 live 힙 크기에 비례한다.

## 5. 쓰기와 재생

| 항목 | 값 |
|---|---|
| `.masc` 아래 1분간 갱신된 파일 | 175개, 합계 863MB |
| agent-core 스냅샷 | 10분에 84개, 820MB (개당 13~20MB, `messages` 가 16.5MB) |
| 스냅샷 보관 | 세션당 12개, 총 2,076개, `traces/` 11GB |
| `exact-lane-runs-v5.jsonl` | 425MB, 12,322행, 초당 23KB 증가 |
| 부팅 재생 후 보관 | 6,000행(레인당 2,000), 텍스트 142MB, 행당 평균 24KB, 최대 262KB |
| 손상 행 | 0 (`deployment_preflight_helper cut-run-registries` 보고) |

`Keeper_checkpoint_store` 의 주석은 체크포인트를 0.7~1.4MB 로 적어 두었다. 지금은 10~20배다. 레지스트리 주석의 "재생 약 416ms" 도 행이 24KB 로 커지기 전 값이다.

## 6. 호스트

| 프로세스 | CPU | 비고 |
|---|---|---|
| fseventsd | 95% | `.masc` 쓰기가 만드는 파일 이벤트 |
| masc 서버 | 85~194% | RSS 2.7~5.5GB, swap 12.7/14GB 사용 중 |
| com.apple.Virtualization | 75% | keeper VM 4대 + qemu 2대, 서버 재기동마다 재생성 |
| watchman | 43% | RSS 5.4GB, 클라이언트 0, 4일째, 루트 `~/me` |
| agy | 56% | 사용자 터미널의 자식 |

load average 80~300, 커널 시간 45%. 서버 밖의 일이지만 락 재획득 대기 시간을 직접 늘린다.

## 7. 외부 근거

- OCaml 5.5 매뉴얼 §5.1: "Only one systhread at a time is allowed to run OCaml code on a particular domain." §3: minor heap 이 차면 stop-the-world 로 모든 도메인이 함께 minor GC 를 한다. <https://ocaml.org/manual/5.5/parallelism.html> (2026-09-05 확인)
- Eio README: `Domain_manager` 로 CPU 작업을 다른 도메인에서, `Executor_pool` 이 권장 경로, `Eio_unix.run_in_systhread` 는 blocking 호출을 "도메인 전체를 막지 않고" 돌리는 용도. Promise·Stream·Mutex 는 도메인 간 안전. <https://github.com/ocaml-multicore/eio> (2026-09-05 확인)
- `Gc.quick_stat` 은 마지막 minor/major 종료 시점의 값이며 힙을 걷지 않는다. `Gc.stat` 은 full major collection 을 일으킨다. <https://ocaml.org/manual/5.5/api/Gc.html> (2026-09-05 확인)
- 저장소 선행 문서: RFC-0204(대시보드 서빙 격리, 단일 메인 도메인 진단), RFC-0239(동시성 소유권), RFC-0302(keeper 메모리 I/O off-main), 2026-08-31 health-ready 경계 연구.

## 8. 아직 모르는 것

- 3~10초 정지 구간에서 메인 도메인을 잡는 정확한 호출자. macOS `sample` 이 OCaml 5 의 fiber 스택을 못 풀어 leaf 만 보인다.
- 락 재획득 대기 중 systhread 몫과 STW 몫의 비율.
- live 2.5GB 의 구성. exact-lane projection 추정치는 텍스트 크기에서 유도한 것이다.
