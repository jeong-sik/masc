# 서버가 읽는 파일 전수 검사 — 무엇을, 누가 부를 때, 어느 domain 에서 읽나

- 날짜: 2026-11-17(적대적 리뷰 반영 2026-11-18)
- 기준 코드: origin/main `0542d471eedf5`
- 운영 데이터: `/Users/dancer/me/.masc`(base path `/Users/dancer/me`)
- 운영 서버: 22:19:59 KST 재시작본(pid 50800), `OCAMLRUNPARAM`·`MASC_SERVING_DOMAIN_ENABLED` 없음
- 근거 묶음: [docs/evidence/read-path-inventory-20261117](../evidence/read-path-inventory-20261117/README.md)
- 관련 문서: [RFC-0474](../rfc/RFC-0474-gc-stop-budget.md) L4, [RFC-0204](../rfc/RFC-0204-dashboard-serving-isolation.md), [RFC-0477](../rfc/RFC-0477-keepers-screen-reads-typed-changes-not-polls.md), [HTTP serving domain RFC](../rfc/RFC-http-transport-runs-on-its-own-domain-and-each-route-names-where-it-runs.md), Keeper 행 RFC(PR #52896)

## 요약

- 화면이 느린 까닭은 큰 파일 하나가 아니다. 화면과 주기 루프가 Keeper 수만큼 작은 파일을 다시 읽는다.
- 주기 루프 셋이 같은 Keeper 행을 `Current` 로 따로 다시 계산하고, 16칸 세마포어 하나를 같이 쓴다. 22:22~22:56(34분)에 300 ms 를 넘긴 Keeper 행 867개가 35번에 몰려 왔다.
- 이 계산은 풀 작업이다. 그래서 그 파일 읽기는 domain 하나뿐인 host 가 아니라, 계산을 맡은 풀 worker domain 에서 돈다. 계산 하나의 Keeper fiber(최대 16개)가 그 domain 하나를 나눠 쓴다.
- 코드에서 파일 내용을 읽는 곳은 554곳이다. 그중 `lib/` 의 호출 461곳은 `Systhread_host` 287곳, 부른 fiber 135곳, `Dated_jsonl` 끝 읽기 29곳, eio 10곳이다.
- 고칠 방향은 "요청 때 파일에서 다시 계산"을 "쓸 때 메모리 값을 고침"으로 바꾸는 것이다. 설계는 PR #52896 의 RFC 에서 한다.

## 1. 왜 다시 셌나

2026-11-17 21:27 KST 쯤 TUI Keeper 상세 화면이 `Pool.request: timeout after 10.0s` 로 실패했다. 21:27:00~21:39:59 에 300 ms 를 넘긴 Keeper 행은 1,281개였다(6절).

22:19:59 에 서버를 다시 띄운 뒤에도 느렸다. TUI 로그는 1초 넘는 요청만 남긴다(`masc-tui-28494.log`). 22:22:00~22:56:33 에 남은 요청이다.

| 요청 | 1초 넘은 횟수 | 걸린 시간 | 서버가 읽는 곳(5절) |
|---|---:|---|---|
| `GET /api/v1/keepers/turns` | 15 | 1,011~3,081 ms | 13 |
| `GET /api/v1/gate/keepers` | 3 | 1,042~2,059 ms | 15(실제 갈래) |
| `GET /api/v1/dashboard/scheduled-automation` | 3 | 1,262~5,903 ms | 5 |
| `GET /health` | 2 | 1,390~1,818 ms | 12 |
| `GET /api/v1/tui/preferences` | 1 | 4,289 ms | 3 |
| `GET /api/v1/dashboard/health-line` | 1 | 1,194 ms | 29(위 한계) |

`tui/preferences` 는 파일 하나를 통째로 읽고(`tui_preference.ml:400`) 설정을 읽는다. 4,289 ms 중 TUI 쪽 CPU 는 4 ms 였다. 거의 다 기다린 시간이다. 이 요청은 풀 작업이 아니어서 `Fs_compat` 읽기가 host domain 으로 간다(4절). 기다림이 그 줄 때문이었는지는 이 근거로 가를 수 없다.

## 2. 어떻게 셌나

스크립트 넷으로 셌다. 모두 근거 묶음에 있다.

1. `data_families.py`: 상태 디렉터리의 모든 파일을 `lstat` 한다. 내용은 열지 않는다. 경로의 날짜·id·Keeper 이름을 자리표시자로 바꿔 저장소와 파일 묶음별로 센다. Keeper 이름은 코드가 정한 `keepers/` 배치(`common.ml` 의 `keeper_runtime_store_dirname`)에서 찾는다. 이름이 남은 행이 있으면 아무것도 쓰지 않고 멈춘다.
2. `code_read_sites.py`: `lib/`·`bin/` 의 `.ml` 3,293개에서 주석과 문자열을 지운 뒤 읽기 함수 호출을 모두 찾는다. 한 줄에서 같은 함수를 두 번 불러도 한 곳으로 센다. 함수마다 막히는 방식(mech)을 구현을 읽고 붙였다.
3. `route_reach.py`: 이름으로 이은 호출 그래프(binding 65,417개, 참조 152,600개)를 만든다. HTTP route 429개, `Keeper_agent_run.run_turn`, 주기 루프 7개에서 깊이 30까지 따라가 닿는 읽기를 센다.
4. `log_numbers.py`: 서버 로그와 TUI 로그에서 1절·6절 숫자를 센다. 집계만 낸다.

한계:

- 그래프의 선은 "참조"다. 함수를 값으로 넘겨도 선이 생긴다. 그래서 "닿는다"는 "읽을 수도 있다"의 위 한계다. 캐시 때문에 실제로는 안 읽는 경우를 모른다.
- `match` 디스패치는 모든 갈래로 이어진다. `/gate/keepers` 는 `Keeper_tool_surface.dispatch` 로 도구 하나(`masc_keeper_list`)만 부른다(`server_routes_http_routes_channel_gate.ml:567-569`). 그래프는 모든 갈래를 따라가 202곳을 센다. 실제로 도는 갈래와 관리자 확인만 진입점으로 다시 세면 15곳이다.
- record 필드와 functor 를 거친 호출은 놓친다. ref 에 담긴 함수는 하나만 손으로 이었다. 주기 루프 셋이 부르는 `operator_snapshot_json_ref` 에는 `Operator_control.snapshot_read` 가 들어간다(`operator_tool.ml:438`).
- route 경로는 등록 인자에서 읽는다. 문자열 상수가 아닌 24곳은 이름으로 남겼다. 같은 경로를 두 파일이 등록하면 파일마다 나눴다(`/health`).
- 요청 빈도는 로그에 남은 것만 안다. 두 로그 모두 느린 것만 남긴다.

## 3. 운영 데이터

상태 디렉터리를 2026-11-18 10:26:59~10:35:59 KST 에 훑었다(`data-stores.tsv`). 파일 내용은 열지 않고 `lstat` 만 했다. 서버를 덜 방해하려고 디스크 우선순위를 낮춰(`nice -n 19 taskpolicy -d utility`) 돌렸다. 24시간은 훑기를 시작한 때부터 거꾸로 센다.

- 파일 4,057,631개, 229,574 MB 다.
- 24시간 안에 바뀐 파일은 246,844개, 17,153 MB 다.
- `keepers/` 아래 디렉터리는 공용 디렉터리(`tool_usage`·`.shutdown-operations`)를 빼고 724개다. meta 가 있는 Keeper 는 31개다. 나머지는 거의 다 작업 완료 심사가 남긴 `completion-review-<digest>` 디렉터리다(#52944).

큰 저장소는 턴·도구 쪽이다.

| 저장소 | 파일 | MB | 24시간 안에 바뀐 파일 |
|---|---:|---:|---:|
| `official-clients` | 253,658 | 95,432 | 345 |
| `tool_blobs` | 3,108,914 | 23,646 | 128,394 |
| `keeper_turn_events` | 25,183 | 20,478 | 2,908 |
| `lane-addons` | 66,583 | 18,811 | 27,300 |
| `keeper_chat_events` | 4,993 | 7,669 | 444 |
| `tool_calls` | 658 | 6,928 | 60 |
| `keepers/<keeper>/request-executions` | 95,448 | 5,963 | 9,860 |
| `exact-lane-run-payloads-v7` | 10,605 | 5,659 | 4,763 |

화면이 Keeper 마다 읽는 파일은 작다(`data-families-keeper-screen.tsv`).

| 파일 | 경로 | 파일 수 | MB | 가장 큰 파일 MB | 화면이 읽는 양 |
|---|---|---:|---:|---:|---|
| Keeper meta | `keepers/<keeper>.json` | 31 | 0.12 | 0.01 | 통째로 |
| 결정 기록 | `keepers/<keeper>.decisions.jsonl` | 34 | 144 | 9.21 | 끝 20줄·40 KB 에서 마지막 행(trust) |
| 결정 기록(돌린 것) | `keepers/<keeper>.decisions.jsonl.1` | 25 | 250 | 10.01 | 읽지 않음 |
| status metrics | `keepers/<keeper>/metrics/<ym>/<dd>.jsonl` | 757 | 382 | 4.01 | 끝 120행(audit) |
| execution receipt | `keepers/<keeper>/execution-receipts/<ym>/<dd>.jsonl` | 753 | 261 | 4.92 | 끝(`Dated_jsonl`) |
| TurnRecord | `keepers/<keeper>/turn-records/<ym>/<dd>.jsonl` | 159 | 66 | 4.21 | 마지막 1행(context) |
| event queue | `keepers/<keeper>/event-queue-v19.json` | 29 | 0.77 | 0.30 | 통째로(`/keepers/turns`) |
| event queue WAL | `keepers/<keeper>/event-queue-transitions-v11.jsonl` | 28 | 0.00 | 0.00 | 통째로(`/keepers/turns`) |
| `schedules.json` | `schedules.json` | 1 | 12 | 11.56 | 버전 캐시 뒤(5절) |

결정 기록·metrics·receipt·TurnRecord 는 끝만 읽는다. meta 와 event queue 는 통째로 읽지만 가장 큰 것도 1 MB 아래다. `schedules.json` 은 크지만 버전 캐시 뒤에 있다(5절). 결정 기록은 10 MB 에서 `.1` 로 돌린다(`keeper_types_support.ml:250-283`). 돌린 파일은 화면이 읽지 않는다. 결정 기록이 meta 보다 3개 많다. meta 가 없어진 이름의 기록이고, 화면은 meta 가 있는 이름만 읽는다.

## 4. 코드가 파일을 읽는 방식

파일을 읽거나 여는 호출은 2,264곳이다. 열기와 SQLite 에는 쓰기도 섞여 있다. `Unix.openfile` 114곳 중 36곳은 쓰기·만들기 플래그로 연다. 아래 표는 `lib/` 의 호출만 센 수다.

| 무엇 | `lib/` 호출 | 막히는 방식 |
|---|---:|---|
| 파일 내용 읽기 | 461 | `Systhread_host` 287, 부른 fiber 135, `Dated_jsonl` 끝 읽기 29, eio 10 |
| 디렉터리 목록 | 175 | 부른 fiber 154, `Systhread_host` 20, eio 1 |
| stat·존재 확인 | 1,069 | 부른 fiber 968, eio 91, `Systhread_host` 10 |
| 열기만(읽기는 따로 셈) | 104 | 부른 fiber |
| SQLite 호출 | 84 | 부른 fiber |

표에서 뺀 것이 둘이다.

- 래퍼 라이브러리(`lib/fs_compat`, `lib/dated_jsonl`, `lib/core/safe_ops.ml`) 안의 내용 읽기 34곳. 래퍼의 구현이라 그 래퍼를 부르는 곳에서 이미 셌다. 다만 목록에 없는 래퍼 함수(private jsonl 읽기)를 거친 읽기는 래퍼 안에서만 세진다.
- `bin/`(TUI·CLI)의 내용 읽기 59곳.

막히는 방식의 뜻:

- `Systhread_host`: `Fs_compat` 읽기 함수가 `Systhread_host.run` 으로 넘긴다. 어디서 도는지는 부른 쪽이 정한다(`lib/core/systhread_host.mli:24-34`).
  - 풀 작업이면 그 worker domain 의 system thread 에서 돈다(`lib/core/systhread_host.ml:16`, `lib/fs_compat/systhread_host.ml:177`). 풀 표시는 Eio fiber 값이라 fork 한 fiber 에도 따라간다.
  - 풀 표시가 없는 Eio fiber 면 domain 하나뿐인 host 로 간다.
  - system call 동안은 domain 을 놓는다. 읽은 바이트를 OCaml 값으로 옮기는 일은 그 domain 에서 한 번에 하나만 돈다(매뉴얼 5.5 §5.1).
- 부른 fiber: Stdlib 채널, `Unix`, `Sys`, SQLite, `Dated_jsonl` 범위 읽기(`iter_*`, `read_range`, `fold_*`)다. system call 동안 그 domain 의 다른 fiber 도 기다린다.
- `Dated_jsonl` 끝 읽기: `Domain_pool_ref.submit_io_or_inline` 을 지난다(`dated_jsonl.ml:573`). 풀 작업이 아니면 weight 0.05 풀 job 이 된다. 풀 작업 안에서는 그 자리에서 바로 읽는다(`domain_pool_ref.ml:47-55`). 주기 루프 안에서는 바로 읽는 쪽이다.
- eio: `Eio.Path` 와 fiber 안의 `Fs_compat.file_exists`(`Eio.Path.stat`, `fs_compat_owned_file.ml:22-31`)다. eio_posix 가 system call 을 부른 domain 의 system thread 로 보낸다.

## 5. 무엇이 읽기를 부르나

`lib/` 의 내용 읽기 461곳을 닿는 진입점으로 나눴다(깊이 30).

| 닿는 진입점 | 곳 |
|---|---:|
| route 만 | 116 |
| route + Keeper turn | 153 |
| route + Keeper turn + 주기 루프 | 32 |
| route + 주기 루프 | 19 |
| Keeper turn 만 | 7 |
| 어느 것도 아님(기동, MCP 도구, 다른 루프, 못 이은 호출) | 134 |

TUI 가 부르는 route 다. 수는 `lib/` 호출과 래퍼 안을 더한 것이다.

| route | 닿는 내용 읽기 | 눈에 띄는 것 |
|---|---:|---|
| `GET /api/v1/gate/keepers` | 실제 갈래 15(7 + 8) | Keeper meta·profile TOML, 최근 execution receipt, Candle 설정·ledger, 환경 설정, 관리자 확인의 auth 설정. 관리자 요청이면 Keeper 마다 현재 관측을 더 읽는다(`with_current_gate_keeper_observations`) |
| `PREFIX_GET /api/v1/keepers/` | 98(84 + 14) | Keeper 상세 하위 경로 전체가 route 하나에 묶여 있다 |
| `GET /api/v1/dashboard/health-line` | 29(20 + 9), 위 한계 | mission 루프가 메모리에 둔 결과로 답한다(`server_dashboard_http_core_mission.ml:109-112`, `157-161`). 요청마다 더하는 읽기는 Candle ledger 와 Keeper 마다 meta(board address)다. 결과가 아직 없을 때만 briefing 을 계산하고, 29곳은 그 경로까지 센 수다 |
| `GET /api/v1/operator` | 28(19 + 9) | TUI 는 `include_keepers=0` 으로 불러 Keeper 행 계산을 부르지 않는다(`bin/masc_tui_http.ml:2837`) |
| `GET /api/v1/keepers/turns` | 13(8 + 5) | Keeper 마다 event queue 읽기(private jsonl, 깊이 12~14). `schedules.json` 은 버전 캐시 뒤에 있다. 쓰는 쪽이 해석본을 남겨서(`schedule_store.ml:575`) 요청은 보통 존재 확인(`ensure_dirs`, `:268`, `:460`)과 버전 확인, stat 두 번이다 |
| `GET /health` | 12(9 + 3) | 계정 서버의 `/health` 와 나눠 셌다 |
| `GET /api/v1/dashboard/scheduled-automation` | 5(3 + 2) | 일정 원장(`read_json_doc_local`, `workspace_utils_ops.ml:200-203`) |
| `GET /api/v1/tui/preferences` | 3(2 + 1) | `tui_preference.ml:400` 파일 하나와 환경 설정 |
| `GET /api/v1/dashboard/logs/stream` | 0 | 메모리 ring(`Log.Ring`)에서 읽는다 |

어디서 도나:

- 주기 루프 셋과 `/gate/keepers` 는 `run_dashboard_compute` → `Pool_work.submit` 으로 풀 작업이 된다(`server_dashboard_http_runtime_support.ml:17-27`, `server_routes_http_routes_channel_gate.ml:471`).
- `/dashboard/health-line` 은 `Executor_pool_ref.submit_or_inline` 으로 풀 작업이 된다.
- `/keepers/turns` 의 Keeper 마다 일은 `Domain_pool_ref.submit_io_or_inline` 이다(`server_routes_http_keeper_control.ml:165`).
- `/tui/preferences` 는 풀 작업이 아니다. 나머지 route 는 확인하지 않았다.

`/dashboard/logs/stream` 은 이미 메모리에서 답한다. 다른 화면이 갈 모양의 예다.

주기 루프(`Proactive_refresh`)는 9곳에서 돈다. 그중 셋이 Keeper 행 전체(`include_keepers:true`)를 다시 계산한다. 셋 다 `Dashboard_projection_cache.operator_snapshot_observation` 을 부르고, 그 함수가 `operator_snapshot_json_ref` 로 `Operator_control.snapshot_read` 를 부른다.

| 루프 | Keeper 행을 부르는 곳 | `Current` 를 정하는 곳 | 간격 |
|---|---|---|---|
| operator snapshot(`server_dashboard_http_core_snapshot_refresh.ml:56`) | `operator_snapshot_observation` | `dashboard_projection_cache.ml:348` | `MASC_OPERATOR_REFRESH_INTERVAL_S`(기본 60 s) |
| execution(`server_dashboard_http_execution_surfaces.ml:1577`) | `dashboard_execution.ml:759-761` | `dashboard_execution.ml:952` | 60 s(`:1576`) |
| mission(`server_dashboard_http_core_mission.ml:81`) | `dashboard_briefing.ml:235-237` | `dashboard_briefing.ml:426` | 120 s(`:80`) |

루프는 정해진 주기로 돌지 않는다. 처음 한 번 읽은 뒤에는 바뀐 것이 올 때 읽는다(`proactive_refresh.mli:90-92`). 간격은 바뀐 것 때문에 읽는 두 번 사이의 최소 시간이자, 실패 뒤 다시 읽는 시간이다(`:37-41`). 관측이 기한을 주면 그때도 읽는다. Keeper 가 바쁘면 바뀐 것이 늘 와서 간격마다 한 번씩 돈다. 보는 사람이 없어도 돈다.

셋 다 `Current` 로 읽어서 `Dashboard_cache`(trust·audit 10 s, `operator_control_snapshot_trust.ml:53-56`, `operator_control_snapshot_tool_audit.ml:150-157`)를 건너뛰고 매번 파일을 읽는다. 일부러 건너뛴다. 10초 캐시 창 안에 들어온 커밋도 봐야 해서다(`operator_control_snapshot_tool_audit.ml:155-156` 주석). 그래서 TTL 을 늘려서는 못 고친다. MCP 도구 `masc_operator_snapshot` 처럼 `Reuse` 로 읽는 쪽도 캐시가 비면 같은 계산을 한다.

## 6. 런타임에서 본 것

`Operator_control_snapshot.keepers_json` 은 Keeper 하나의 일이 300 ms 를 넘을 때만 sub-op 로그를 남긴다(`operator_control_snapshot.ml:192`). 세마포어 대기나 일이 500 ms 를 넘으면 wait·work 로그를 남긴다(`:72`). 그래서 아래는 느린 행만 센 값이다. 숫자는 `log_numbers.py` 출력이다(`log-numbers.txt`).

22:22:00~22:56:33(34분):

- 느린 Keeper 행 867개가 35번 몰려 왔다. 몰림은 앞 줄과 5초 안에 찍힌 줄을 이은 것이다. 5~20초로 바꿔도 35번이다.
- 한 번에 1~61행(중앙값 25)이다. 31행을 넘은 몰림이 8번이다. Keeper 행 계산이 같은 때 둘 이상 돌았다는 뜻이다. 루프만이 아니라 캐시가 빈 `Reuse` 요청도 같은 계산을 한다.
- 몰림의 시작은 대개 28~32초나 60초 간격이다.
- 느린 행의 sub-op 중앙값: trust 186 ms, audit 164 ms, meta 23 ms(합계 400 ms).
  - trust 는 결정 기록 끝, 최근 도구 호출, 최근 receipt, 승인 audit, workspace 의 대기 승인을 읽는다(`keeper_runtime_trust_snapshot.ml:687-729`). 결정 기록 끝은 부른 fiber 에서 `Unix.read` 로 읽는다(`keeper_memory_recall.ml:31`, `60`).
  - audit 는 metrics 끝 120행과 최근 audit 를 읽는다(`operator_control_snapshot_tool_audit.ml:16`).
- wait 나 work 가 500 ms 를 넘긴 547행에서 세마포어 대기 중앙값은 593 ms, p90 은 4,510 ms 다.
- 세마포어는 모듈에 하나다(`operator_control_snapshot.ml:41`). 칸 수는 `MASC_KEEPER_SNAPSHOT_CONCURRENCY`(기본 16, 1~64, `:32-39`)다. 운영 서버의 값은 읽지 않았다. 주기 루프 셋과 요청이 같은 칸을 나눠 쓴다. 두 계산이 겹치면 Keeper 62행이 16칸 앞에 줄을 선다.

21:27:00~21:39:59(재시작 전, `masc-start-20261117T122217Z.log`): 느린 Keeper 행 1,281개, trust 중앙값 703 ms(평균 767 ms), audit 404 ms(평균 435 ms)다. 모양이 같다.

계산 하나의 Keeper fiber 는 풀 worker domain 하나에서 돈다(7절). 작은 끝 읽기 하나가 수백 ms 걸리는 것은 일보다 기다림으로 보인다. 읽기 한 번의 시간을 따로 재기 전에는 확정하지 않는다.

측정하지 않은 것: 읽기 한 번의 실제 시간(runtime events 를 안 잡았다), 오늘 GC 수치(`/health?full=1` 을 이 세션에서 읽지 않았다), 세마포어 칸 수의 운영 값.

## 7. 해석

1. 화면 데이터를 요청 때 파일에서 다시 계산한다. 화면 하나가 Keeper 수 × 저장소 수만큼 왕복한다. Keeper 가 31개라 왕복이 31배로 는다.
2. 같은 계산을 여럿이 따로 한다. 주기 루프 셋이 Keeper 행을 따로 만들고, 셋 다 `Current` 로 읽어 캐시를 건너뛴다.
3. 계산 하나는 풀 worker domain 하나에 몰린다. `keepers_json` 은 풀 작업 안에서 Keeper fiber 를 16개까지 fork 한다. 풀 표시가 따라가서 그 읽기도 모두 같은 domain 에서 돈다. 그 domain 에는 weight 0.05 로 들어온 다른 IO job 도 같이 앉는다. 결정 기록 끝 읽기와 `Dated_jsonl` 끝 읽기는 system call 을 그 자리에서 불러서, 그동안 그 domain 의 다른 fiber 도 멈춘다.
4. host domain 으로 가는 것은 풀 표시가 없는 fiber 의 `Fs_compat` 읽기뿐이다. 화면 경로에서는 `/tui/preferences` 가 그렇다.
5. 부른 fiber 를 막는 호출이 많다(`lib/` 의 내용 읽기 135곳, stat 968곳, SQLite 84곳). 그 fiber 가 HTTP 를 받는 domain 에 있으면 HTTP 응답도 같이 멈춘다.
6. 큰 데이터는 화면이 아니라 턴 쪽에 있다(3절). 화면 경로는 크기보다 횟수가 문제다.

## 8. 고칠 방향(제안, 결정 아님)

설계는 PR #52896 의 RFC 에서 한다. 지금 보이는 순서는 이렇다.

1. Keeper 행 사실은 쓰는 쪽이 메모리 값도 고친다. 읽는 쪽은 그 사실 때문에 파일을 열지 않는다. 주기 루프는 새 값이 필요하고(5절), 캐시는 새 값을 못 준다. 새것이면서 싸려면 읽을 때가 아니라 쓸 때 고쳐야 한다. 코드에 이미 이 모양이 있다. `Keeper_turn_pulse` 는 기동 때 결정 기록으로 한 번 채우고(`server_bootstrap_maintenance.ml:741`), 턴이 끝날 때 `record` 로 고치고(`keeper_heartbeat_loop_cycle.ml:121`), 화면은 `get` 으로 읽는다(`keeper_tool_surface_ops.ml:438`).
2. 주기 루프는 값이 바뀔 때만 보낸다. 바뀐 Keeper 행만 SSE 에 싣는다(RFC-0477).
3. 남는 파일 읽기는 막히는 곳을 바로잡는다. 풀 job weight 와 `Systhread_host` 는 풀 RFC(다른 세션 담당)에서 한다. 이 문서의 mech 칸은 부른 쪽이 풀 작업인지 모른다. 그 RFC 는 진입점별로 다시 본다.
4. 그 뒤 읽기 route 를 serving domain 으로 옮긴다. 메모리 값이 `Atomic` 이면 domain 사이에서 안전하다. TSan(`5.5.2-tsan` switch)으로 확인한다.

성공 기준 후보: 재시작 뒤 같은 34분 창에서 300 ms 넘는 Keeper 행 0, TUI 1초 넘는 Keeper 화면 요청 0.

## 9. 다음

- PR #52896 의 RFC: Keeper 행 사실을 쓰는 곳에서 메모리에 둔다.
- 정적 그래프가 놓친 구간(record·functor 경유 호출)과 읽기 한 번의 시간을 runtime events 로 잰다.
- `PREFIX_GET /api/v1/keepers/` 를 하위 경로별로 나눠 센다.
