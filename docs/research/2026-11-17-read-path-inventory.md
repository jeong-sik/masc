# 서버가 읽는 파일 전수 검사 — 무엇을, 누가 부를 때, 어느 domain 에서 읽나

- 날짜: 2026-11-17
- 기준 코드: origin/main `0542d471eedf5`
- 운영 데이터: `/Users/dancer/me/.masc`(base path `/Users/dancer/me`), 2026-11-17 22~23시(KST) 측정
- 운영 서버: 22:19:59 KST 재시작본(pid 50800), `OCAMLRUNPARAM`·`MASC_SERVING_DOMAIN_ENABLED` 없음
- 근거 묶음: [docs/evidence/read-path-inventory-20261117](../evidence/read-path-inventory-20261117/README.md)
- 관련 문서: [RFC-0474](../rfc/RFC-0474-gc-stop-budget.md) L4, [RFC-0204](../rfc/RFC-0204-dashboard-serving-isolation.md), [RFC-0477](../rfc/RFC-0477-keepers-screen-reads-typed-changes-not-polls.md), [HTTP serving domain RFC](../rfc/RFC-http-transport-runs-on-its-own-domain-and-each-route-names-where-it-runs.md)

## 요약

- 화면이 느린 까닭은 큰 파일 하나가 아니다. 화면 하나를 그릴 때마다 서버가 Keeper 수만큼 작은 파일을 다시 읽는다.
- 같은 Keeper 행을 주기 루프 셋이 캐시 없이 따로 다시 계산하고, 16칸짜리 세마포어 하나를 나눠 쓴다. 재시작 뒤 34분 동안 300 ms 를 넘긴 Keeper 행이 35번 몰려 왔다. 한 번에 25행(중앙값)이다.
- 코드에서 파일 내용을 읽는 곳은 608곳이다. 299곳은 Eio fiber 에서 부르면 domain 이 하나뿐인 `Systhread_host` 로 간다. 241곳은 부른 domain 을 그대로 막는다.
- 고칠 방향은 "요청 때 파일에서 다시 계산"을 "쓸 때 메모리 projection 을 고침"으로 바꾸는 것이다. 이 문서는 근거만 모은다. 설계는 다음 RFC 에서 한다.

## 1. 왜 다시 셌나

2026-11-17 21:27~21:39 KST 에 TUI Keeper 상세 화면이 `Pool.request: timeout after 10.0s` 로 실패했다. 같은 때 `/health` 도 평균 6.2 s 걸렸다. 요청 자체의 일은 거의 없었다. `child-content-journals`·`native-task-journals` 디렉터리가 비어 있었다.

22:20 에 서버를 다시 띄운 뒤에도 느렸다. TUI 로그(1초 넘는 요청만 남김, `masc-tui-28494.log`)에서:

| 요청 | 걸린 시간 | 서버가 읽는 것(5절) |
|---|---|---|
| `GET /api/v1/tui/preferences` | 4,289 ms (22:30:58) | 내용 읽기 3곳 |
| `GET /api/v1/keepers/turns` | 1,011~3,081 ms, 16번 | 내용 읽기 13곳, Keeper 마다 event queue WAL |
| `GET /api/v1/gate/keepers` | 1초 넘음 3번 | 내용 읽기 14곳 |

`tui/preferences` 는 파일 하나를 통째로 읽고(`tui_preference.ml:400`) 설정을 읽는다. 읽는 양에 비해 4초는 길다. 기다린 시간으로 보이지만 이 요청 하나로는 가를 수 없다. TUI 를 띄운 직후의 첫 요청이었다.

## 2. 어떻게 셌나

스크립트 셋으로 셌다. 모두 근거 묶음에 있다.

1. `data_families.py`: 운영 상태 디렉터리의 모든 파일을 `lstat` 한다. 내용은 열지 않는다. 경로의 날짜·id·Keeper 이름을 자리표시자로 바꿔 저장소(store)와 파일 묶음(family)별로 개수·크기·24시간 안에 바뀐 양을 센다.
2. `code_read_sites.py`: `lib/`·`bin/` 의 `.ml` 3,293개에서 주석과 문자열을 지운 뒤 읽기 함수 호출을 모두 찾는다. 함수마다 "어디서 막히나"(mech)를 구현을 읽고 붙였다.
3. `route_reach.py`: 이름으로 이은 호출 그래프(binding 65,417개, 참조 152,250개)를 만든다. HTTP route 362개, `Keeper_agent_run.run_turn`, 주기 루프 7개에서 깊이 30까지 따라가 닿는 읽기를 센다.

한계:

- 그래프의 선은 "참조"다. 함수를 값으로 넘겨도 선이 생긴다. 그래서 "닿는다"는 "읽을 수도 있다"는 위 한계다. 캐시가 있어 실제로는 안 읽는 경우를 모른다.
- 한 갈래만 도는 `match` 디스패치도 모든 갈래로 이어진다. `/gate/keepers` 는 `Keeper_tool_surface.dispatch` 로 도구 하나(`masc_keeper_list`)만 부른다(`server_routes_http_routes_channel_gate.ml:567-569`). 그래프는 dispatch 의 모든 갈래를 따라가 202곳을 센다. 실제로 도는 갈래만 진입점으로 다시 세면 14곳이다(5절). 다른 focus route 의 최단 경로에는 dispatch 가 없다.
- record 필드나 closure 를 거친 호출은 놓친다. operator snapshot 루프는 그래프에서 내용 읽기 1곳에만 닿는다. 실제로는 Keeper 마다 trust·audit·meta 를 읽는다(6절). 이 구간은 런타임 로그로 메웠다.
- 요청 빈도는 TUI 로그와 서버 로그에 남은 것만 안다. 두 로그 모두 느린 것만 남긴다.

## 3. 운영 데이터

상태 디렉터리를 2026-11-17 23:07~23:17 KST 에 훑었다(9분 39초, `data-stores.tsv`).

- 파일 3,907,594개, 224,657 MB 다. Keeper 디렉터리는 699개다(지금 Keeper 는 31개).
- 24시간 안에 바뀐 파일은 119,709개, 13,675 MB 다.

큰 저장소는 턴·도구 쪽이다.

| 저장소 | 파일 | MB | 24시간 안에 바뀐 파일 |
|---|---:|---:|---:|
| `official-clients` | 253,581 | 95,370 | 364 |
| `tool_blobs` | 3,037,038 | 23,331 | 75,551 |
| `lane-addons` | 42,218 | 18,519 | 3,077 |
| `keeper_turn_events` | 23,322 | 18,135 | 1,453 |
| `keeper_chat_events` | 4,890 | 7,513 | 461 |
| `tool_calls` | 628 | 6,759 | 42 |
| `exact-lane-run-payloads-v7` | 10,585 | 5,667 | 2,303 |
| `keepers/<keeper>/request-executions` | 89,352 | 5,558 | 5,198 |

화면이 Keeper 마다 읽는 파일은 작다. 가장 큰 파일도 10 MB 아래이고, 화면은 그 끝만 읽는다.

| 파일 | 파일 | MB | 가장 큰 파일 MB | 화면이 읽는 양 |
|---|---:|---:|---:|---|
| Keeper meta `keepers/<name>.json` | 31 | 0.06 | 0.01 | 통째로 |
| 결정 기록 `keepers/<name>.decisions.jsonl` | 34 | 140.0 | 9.85 | 끝 40 KB·20줄(trust) |
| status metrics `keepers/<keeper>/metrics/<ym>/<dd>.jsonl` | 738 | 366.2 | 2.78 | 끝 120행(audit) |
| execution receipt `keepers/<keeper>/execution-receipts/<ym>/<dd>.jsonl` | 731 | 255.6 | 4.92 | 끝(`Dated_jsonl`) |
| TurnRecord `keepers/<keeper>/turn-records/<ym>/<dd>.jsonl` | 137 | 51.6 | 4.21 | 마지막 1행(context) |
| event queue `keepers/<keeper>/event-queue-v19.json` | 29 | 0.55 | 0.24 | 통째로(`/keepers/turns`) |
| event queue WAL `keepers/<keeper>/event-queue-transitions-v11.jsonl` | 28 | 0.00 | 0.00 | 통째로(`/keepers/turns`) |
| `schedules.json` | 1 | 11.15 | 11.15 | 버전 캐시 뒤(5절) |

결정 기록은 10 MB 에서 `.1` 로 돌린다. 돌린 파일 25개(250 MB)는 화면이 읽지 않는다.

## 4. 코드가 파일을 읽는 방식

읽기 호출 2,383곳을 모양과 막히는 곳으로 나눴다.

| 무엇 | 곳 | 막히는 곳 |
|---|---:|---|
| 파일 내용 읽기 | 608 | `Systhread_host` 299, 부른 domain 241, 읽기 풀 46, eio 22 |
| 디렉터리 목록 | 203 | 부른 domain 176, `Systhread_host` 21, eio 6 |
| stat·존재 확인 | 1,336 | 부른 domain 1,202, eio 70, `Systhread_host` 64 |
| 열기만(읽기는 따로 셈) | 152 | 부른 domain |
| SQLite 호출 | 84 | 부른 domain |

막히는 곳의 뜻:

- `Systhread_host`: `Fs_compat` 읽기 함수다(`fs_compat_base_io.ml:351`, `fs_compat_jsonl_read.ml:69`). Eio fiber 에서 부르면 `Systhread_host.run` 으로 넘어간다. 그 domain 은 하나다(`lib/fs_compat/systhread_host.ml:1`). 매뉴얼 5.5 §5.1 대로 한 domain 에서는 systhread 하나만 OCaml 코드를 돌린다. 그래서 읽은 바이트를 문자열로 옮기는 일은 한 줄로 선다.
- 부른 domain: Stdlib 채널, `Unix.read`, `Sys.readdir`, `Unix.stat`, SQLite 다. 부른 fiber 가 아니라 그 domain 의 모든 fiber 가 기다린다. main domain 에서 부르면 HTTP 도 기다린다.
- 읽기 풀: `Dated_jsonl` 이다. `Domain_pool_ref.submit_io_or_inline`(weight 0.05) 안에서 Stdlib 채널로 읽고 파싱한다(`dated_jsonl.ml:573`). RFC-0474 L4 가 짚은 대로, 받아 둔 다른 job 도 그동안 멈춘다.
- eio: eio_posix 는 open·stat·readdir 를 systhread 로 보내지만 일반 파일 read 는 부른 domain 에서 한다.

## 5. 무엇이 읽기를 부르나

내용 읽기 608곳을 닿는 진입점으로 나눴다(깊이 30).

| 닿는 진입점 | 곳 |
|---|---:|
| route 만 | 114 |
| route + Keeper turn | 184 |
| route + Keeper turn + 주기 루프 | 50 |
| route + 주기 루프 | 15 |
| Keeper turn 만 | 7 |
| 주기 루프만 | 2 |
| 어느 것도 아님(기동, MCP 도구, 다른 루프, 못 이은 호출) | 236 |

TUI 가 다시 읽는 route:

| route | 닿는 내용 읽기 | 눈에 띄는 것 |
|---|---:|---|
| `GET /api/v1/gate/keepers` | 14 | Keeper meta·profile, status metrics 끝 읽기(`Dated_jsonl`), execution receipt(읽기 풀), 설정 파일. 관리자 요청이면 Keeper 마다 현재 관측을 더 읽는다(`with_current_gate_keeper_observations`) |
| `PREFIX_GET /api/v1/keepers/` | 98 | Keeper 상세 하위 경로 전체(hints 포함)가 한 route 에 묶여 있다 |
| `GET /api/v1/dashboard/health-line` | 21 | Keeper meta, status metrics, 설정 파일 |
| `GET /api/v1/keepers/turns` | 13 | Keeper 마다 event queue 읽기(`fs_compat_private_jsonl_read.ml`, 깊이 12~14). `schedules.json`(11 MB)도 닿지만 버전 캐시 뒤에 있다. 쓰는 쪽이 해석본을 남겨서(`schedule_store.ml:575`) 요청은 보통 `stat` 한 번이다 |
| `GET /api/v1/dashboard/scheduled-automation` | 5 | 설정 파일 |
| `GET /api/v1/tui/preferences` | 3 | `tui_preference.ml:400` 파일 하나와 환경 설정 |
| `GET /api/v1/dashboard/logs` | 0 | 메모리 ring(`Ring.recent`)에서 읽는다 |

`/gate/keepers` 의 14곳은 `Keeper_tool_surface.handle_keeper_list` 와 `Dashboard_projection_cache.with_current_gate_keeper_observations` 를 진입점으로 다시 센 수다(`gate-keepers-keeper-list-branch.tsv`). dispatch 의 모든 갈래를 따라가면 202곳이다.

`/dashboard/logs` 는 이미 메모리에서 답한다. 다른 화면이 갈 모양의 예다.

주기 루프(`Proactive_refresh`)는 9곳에서 돈다. 셋이 Keeper 행 전체(`include_keepers:true`)를 다시 계산한다.

| 루프 | Keeper 행을 만드는 곳 | 읽기 방식 |
|---|---|---|
| operator snapshot (`server_dashboard_http_core_snapshot_refresh.ml:56`) | `Dashboard_projection_cache.operator_snapshot_observation` | `Current`(`dashboard_projection_cache.ml:348`) |
| execution (`server_dashboard_http_execution_surfaces.ml:1577`) | `Dashboard_execution.render_observation`(`dashboard_execution.ml:750`) | `Current`(`dashboard_execution.ml:952`) |
| mission (`server_dashboard_http_core_mission.ml:81`) | `Dashboard_briefing.build_projection`(`dashboard_briefing.ml:226`) | `Current`(`dashboard_briefing.ml:426`) |

주기는 `MASC_OPERATOR_REFRESH_INTERVAL_S`(기본 60 s)이고, 바뀐 것이 오면 더 일찍 돈다. 보는 사람이 없어도 돈다. 셋 다 `Current` 로 읽어서 `Dashboard_cache`(trust·audit 10 s, `operator_control_snapshot_trust.ml:53-56`, `operator_control_snapshot_tool_audit.ml:150-157`)를 건너뛰고 매번 파일을 읽는다. 건너뛰는 것은 일부러다. 10초 캐시 창 안에 들어온 커밋도 봐야 해서다(`operator_control_snapshot_tool_audit.ml:155-156` 주석). 그래서 TTL 을 늘려서는 못 고친다. operator snapshot 은 함수를 담은 ref(`operator_snapshot_json_ref`)를 거쳐 불려서 정적 그래프에서 끊겼다. TUI 의 `/api/v1/operator` 는 `include_keepers=0` 이라 이 계산을 부르지 않는다(`bin/masc_tui_http.ml:2837`).

## 6. 런타임에서 본 것

`Operator_control_snapshot.keepers_json` 은 Keeper 하나의 일이 300 ms 를 넘을 때만 sub-op 로그를 남긴다(`operator_control_snapshot.ml:192`). 그래서 아래는 느린 행만 센 값이다.

- 22:22:00~22:56:33(34분): 느린 Keeper 행 867개가 35번에 몰려 왔다.
- 몰림 간격은 대개 30 s 나 60 s 다. 한 번에 1~61행(중앙값 25)이다. 31을 넘는 몰림은 루프 둘 이상이 같은 때 Keeper 31개를 읽었다는 뜻이다.
- 느린 행의 sub-op 중앙값: trust 186 ms, audit 164 ms, meta 23 ms.
  - trust 는 결정 기록 끝 40 KB·20줄을 읽고 JSON 으로 푼다(`Keeper_runtime_trust_snapshot.latest_decision_json`).
  - audit 는 metrics 끝 120행과 최근 audit 를 읽는다(`operator_control_snapshot_tool_audit.ml:16`).
- 세마포어(Keeper 16개 동시, `operator_control_snapshot.ml:33-38`) 대기: wait 나 work 가 500 ms 를 넘긴 547행에서 wait 중앙값 593 ms, p90 4.5 s 다.
- 이 세마포어는 모듈에 하나다(`operator_control_snapshot.ml:41`). 주기 루프 셋과 요청이 같은 16칸을 나눠 쓴다. 두 루프가 겹치면 Keeper 62행이 16칸 앞에 줄을 선다.

작은 끝 읽기 하나가 수백 ms 걸린다. 21:29 사건 때 같은 기준(300 ms 넘는 행)으로 잰 값(trust 평균 662 ms, audit 375 ms)과 모양이 같다. 일보다 기다림이 길어 보인다. 읽기 한 번의 시간을 따로 재기 전에는 확정하지 않는다.

측정하지 않은 것: 읽기 한 번의 실제 시간 분포(runtime events 를 안 잡았다), 오늘 GC 수치(`/health?full=1` 을 이 세션에서 읽지 않았다).

## 7. 해석

1. 화면 데이터를 "요청 때 파일에서 다시 계산"한다. 화면 하나가 Keeper 수 × 저장소 수만큼 왕복한다. Keeper 가 31개라 왕복이 31배로 는다.
2. 같은 계산을 여럿이 따로 한다. 주기 루프 셋이 Keeper 행을 따로 만들고, 셋 다 `Current` 로 읽어 캐시를 건너뛴다.
3. 읽기 절반이 domain 하나로 몰린다. 내용 읽기 608곳 중 299곳이 `Systhread_host` 를 거친다. 주기 루프와 TUI 요청이 같은 줄에 선다.
4. 부른 domain 을 막는 호출이 많다. 내용 읽기 241곳, stat 1,202곳, SQLite 84곳이다. main domain 에서 돌면 HTTP 응답도 같이 멈춘다.
5. 큰 데이터는 화면이 아니라 턴 쪽에 있다(3절). 화면 경로는 크기보다 횟수가 문제다.

## 8. 고칠 방향(제안, 결정 아님)

다음 RFC 에서 설계한다. 지금 보이는 순서는 이렇다.

1. Keeper 행 projection: trust 요약, tool audit 요약, turn 상태, meta 를 쓰는 쪽이 고친다. 읽는 쪽은 `Atomic.get` 한 번이다. 주기 루프는 새 값이 필요하고(5절), 캐시는 새 값을 못 준다. 새것이면서 싸려면 읽을 때가 아니라 쓸 때 고쳐야 한다. 코드에 이미 이 모양이 하나 있다. `Keeper_turn_pulse` 는 기동 때 결정 기록으로 한 번 채우고(`server_bootstrap_maintenance.ml:741`), 턴이 끝날 때 `record` 로 고치고(`keeper_heartbeat_loop_cycle.ml:121`), 화면은 `get` 으로 읽는다(`keeper_tool_surface_ops.ml:438`). 주기 루프 셋과 `/gate/keepers`, `/keepers/turns`, `/dashboard/health-line` 이 같은 값을 본다.
2. 주기 루프는 projection 이 바뀔 때만 보낸다. 바뀐 Keeper 행만 SSE 에 싣는다. TUI 는 알림을 받고 다시 GET 하지 않는다.
3. 남는 파일 읽기는 막히는 곳을 바로잡는다. `Systhread_host` 를 syscall 만 하게 하는 일은 풀 RFC(다른 세션 담당)에서 한다.
4. 그 뒤 읽기 route 를 serving domain 으로 옮긴다. projection 이 `Atomic` 이면 domain 사이에서 안전하다. TSan(`5.5.2-tsan` switch)으로 확인한다.

성공 기준 후보: 재시작 뒤 같은 34분 창에서 느린 Keeper 행 0, TUI 1초 넘는 요청 0, 주기 루프의 파일 읽기 횟수가 Keeper 수와 무관.

## 9. 다음

- RFC: Keeper 행 projection. 생산자 → 저장 → 소비자 → 호출 진입점을 먼저 확인한다.
- 정적 그래프가 놓친 구간(operator snapshot compute, record·functor 경유 호출)을 runtime events 로 잰다.
- `PREFIX_GET /api/v1/keepers/` 를 하위 경로별로 나눠 센다.
