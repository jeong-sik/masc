---
rfc: "keeper-row-facts-are-kept-in-memory-by-their-writers"
title: "Keeper 행이 보여 주는 사실은 쓰는 곳이 메모리에도 고치고, 읽는 쪽은 그 사실 때문에 파일을 열지 않는다"
status: Draft
created: 2026-11-17
updated: 2026-11-18
author: vincent + claude
related: ["0477", "0474", "0204", "http-transport-runs-on-its-own-domain-and-each-route-names-where-it-runs"]
---

# RFC — Keeper 행이 보여 주는 사실은 쓰는 곳이 메모리에도 고친다

## 0. 요약

주기 루프 셋이 Keeper 31개의 행을 따로 다시 만든다. 행 하나마다 meta 파일과 Keeper 기록 다섯 묶음의 끝을 다시 읽고, 날짜 파일을 목록으로 훑고 stat 한다. 2026-11-17 22:22~22:56(34분)에 300 ms 를 넘긴 Keeper 행이 867개 쌓였다. 근거는 연구 노트 `docs/research/2026-11-17-read-path-inventory.md`(PR #52888)에 있다.

이 RFC 는 규칙 하나를 세운다.

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 그 사실 때문에 파일을 열지 않는다.

결정은 여섯 가지다.

1. 메모리에 두는 값은 행이 실제로 쓰는 값만이다(§1.1). 결정 기록의 마지막 행, 도구 호출 원장의 마지막 16줄, 최근 execution receipt, 최근 TurnRecord, metrics 끝 120행과 가장 최근 Turn tool audit 행이다. meta 는 Owner 가 이미 메모리에 든 값에서 얻는다. 파일에 쓰는 필드만 쓴다(§3.1).
2. 값마다 세대 번호를 붙인다. 파일을 바꾸는 쪽은 바꾼 뒤 그 저장소의 값마다 세대를 올린다. 쓰는 쪽은 파일을 바꾸기 전에 본 값에서 새 값을 만든다. 그 사이 다른 쪽이 값을 바꿨거나, 새 값을 읽는 쪽과 똑같이 만들 수 없으면 값을 비운다(§3.3).
3. 빈 값은 읽는 쪽이 파일로 채운다. 채울 때는 어떤 잠금도 잡지 않는다. 읽기 전에 본 값이 그대로일 때만 compare-and-set 으로 넣는다. 읽기가 실패하면 넣지 않는다(§3.4). 그래서 저장소 잠금을 쥔 채 풀 작업을 기다리는 일이 없다.
4. 메모리 값은 디스크에 저장하지 않는 파생 값이다. 값은 읽는 쪽이 파일에서 보는 줄을 그 자리 그대로 든다. 차분 시험과 TLA+ 로 "파일을 바꾸는 중인 쪽이 없으면 메모리 값은 파일에서 다시 계산한 값과 같다"를 지킨다(§5).
5. 쓰는 함수가 먼저 지킬 것이 둘 있다. 실패한 쓰기는 나중에 파일에 닿지 않는다. 쓰기는 줄 처음에서 시작한다. 지금은 둘 다 어긴다(§1.4, #52980, #52974). 이 수리(§4 의 W, PR #52991)가 L2 보다 먼저다. W 는 같은 함수를 부르는 다른 저장소의 쓰기도 같이 바꾼다(§1.4).
6. 다 옮기면 이 값들을 읽는 행 helper 의 Current/Reuse 구분과 그 helper 몫의 캐시를 지운다. 같은 캐시를 쓰는 다른 화면을 먼저 옮긴다. Keeper 세마포어는 남은 행 일을 잰 뒤 정한다(§4 L4).

보이는 동작은 바꾸지 않는다. 행이 보여 주는 값은 지금 파일에서 읽는 값과 같다. meta 의 설정 필드도 지금 값 그대로다. 그 값이 TOML 과 다른 문제는 따로 적었다(§1.1, #53007). 서버가 도는 동안 밖에서 파일을 고치거나 지운 때만 다르다(§3.1, §7).

고치지 않는 것: `Systhread_host` 와 풀(다른 RFC), `schedules.json` 쓰기, 서버 밖에서도 고치는 profile TOML, 승인 audit 와 quarantine 원장(§8.1), Keeper 행을 SSE 로 나르는 일(RFC-0477), serving domain.

## 1. 지금 상태 (origin/main `e5ac5ffae90b1`)

### 1.1 Keeper 행 하나가 읽는 것

`Operator_control_snapshot.keepers_json` 은 `snapshot_read` 한 곳에서만 불린다(`operator_control_snapshot.ml:709`). 행 하나는 이렇게 만든다.

| 묶음 | 실제로 쓰는 값 | 어디서 | 이미 메모리에 있나 |
|---|---|---|---|
| meta | Keeper meta 통째 | `Keeper_meta_store.read_meta` | 있다. Owner 가 커밋 뒤 `Atomic` 에 둔다(`keeper_owner.ml:957`). 행은 그 값을 안 읽는다 |
| phase·진단 | registry | `Keeper_registry.get_phase`. 행 하나에서 여러 번 부른다 | 있다 |
| 승인 대기 | 승인 큐 | `keeper_approval_queue_rules.ml:35` 의 `Atomic` map | 있다 |
| trust | 결정 기록의 마지막 object 행 | `latest_decision_json`(`keeper_runtime_trust_snapshot.ml:320-366`). 끝 40,000바이트·20줄 창에서 가장 새 object 행을 찾는다 | 없다 |
| trust | 이 Keeper 의 최근 도구 호출 | `Keeper_tool_call_log.read_latest ~keeper_name`(`keeper_tool_call_log.ml:1558-1587`). workspace 원장의 마지막 16줄에서 이 Keeper 의 최신 행을 찾고, 없으면 `None` | 없다 |
| trust | 최근 receipt, 승인 audit, workspace 의 대기 승인 | `keeper_runtime_trust_snapshot.ml:686-729`. 승인 audit 는 `:689-692` | receipt·audit 는 없다 |
| tool audit | metrics 끝 120행, 저장소 전체에서 가장 최근 Turn 행 | `operator_control_snapshot_tool_audit.ml:14-38`, `keeper_status_metrics.ml:191-275`. heartbeat 행이 많아 Turn 행은 120행 밖에 있을 수 있다 | 일부. `Tool_audit_cache` 가 있지만 읽을 때마다 날짜 파일을 모두 stat 한다(`dated_jsonl.ml:1609-1618`) |
| 최근 활동 | metrics 끝 5행 | `operator_control_snapshot.ml:427-435` | 없다 |
| context | 최근 TurnRecord 1행 | `keeper_context_observation_projection.ml:73-117` | 없다 |
| blocker | registry 와 최근 receipt | `Keeper_status_bridge.runtime_blocker_fields_json` | receipt 는 없다 |

행이 읽는 meta 는 파일을 decode 한 값이다. Owner 가 메모리에 든 값과 같지 않다.

- decoder 는 설정 필드 열한 개를 읽지 않고 자리 채움 값을 둔다(`keeper_meta_json_parse.ml:240-292`). `sandbox_profile` 은 `Docker`, `network_mode` 는 `Network_inherit`, `activation_mode` 는 `Autonomous` 다. encoder 도 그 필드를 쓰지 않는다(`keeper_meta_json.ml:10-55`).
- Owner 의 메모리 값에는 TOML 값이 들어 있다. `Update_profile` 이 넣는다(`keeper_owner_reducer.ml:404-425`).
- 행은 자리 채움 값을 그대로 내보낸다. `activation_mode` 가 그렇다(`operator_control_snapshot.ml:412`). receipt 가 없는 Keeper 의 trust 는 sandbox 종류와 network mode 를 meta 에서 가져온다(`keeper_runtime_trust_snapshot.ml:504-516`). 이 값이 TOML 과 다른 것은 #53007 에 적었다.

최근 receipt 를 읽는 함수는 둘이고 뜻이 다르다. `latest_json` 은 가장 새 줄 하나를 읽는다(`keeper_execution_receipt.ml:584-589`). `read_latest_receipt` 는 깨진 줄을 건너뛰며 끝에서부터 훑는다(`:769-779`). trust 는 앞의 것을 쓰고 blocker 는 뒤의 것을 쓴다(`keeper_runtime_trust_snapshot.ml:389`, `keeper_status_bridge.ml:126`).

행 하나에서 registry phase 와 receipt 를 여러 번 읽는다. quarantine inventory 는 snapshot 하나에 한 번 읽는다(`operator_control_snapshot.ml:668-689`). 승인 audit 와 quarantine 원장은 이 RFC 밖이다.

응답마다 더하는 관측도 있다. `with_current_keeper_observations` 는 응답 하나에 candle ledger 를 한 번 읽고, Keeper 마다 meta 파일을 한 번 더 읽는다(board address, `dashboard_projection_cache.ml:113-135`, `keeper_board_address.ml:14-24`). 이 읽기는 system thread 에서 돈다(`dashboard_projection_cache.ml:127-134`).

`/gate/keepers?detailed=true` 는 다른 몸체(`masc_keeper_list`, `server_routes_http_routes_channel_gate.ml:567-569`)로 Keeper 행을 만든다. 그 행도 meta 와 최근 receipt 를 읽는다(연구 노트 5절).

### 1.2 누가 행을 만드나

| 부르는 곳 | 읽기 방식 | 풀 작업인가 | 언제 |
|---|---|---|---|
| operator snapshot 루프 | Current | 그렇다 | 바뀐 것이 올 때. 두 번 사이를 `MASC_OPERATOR_REFRESH_INTERVAL_S`(기본 60초) 이상 띄운다 |
| execution 루프 | Current | 그렇다 | 같다. 간격 60초(`server_dashboard_http_execution_surfaces.ml:1576`) |
| mission 루프 | Current | 그렇다 | 같다. 간격 120초(`server_dashboard_http_core_mission.ml:80`) |
| `GET /api/v1/dashboard/execution` | Reuse(`dashboard_execution.ml:980`) | 그렇다 | 요청 |
| MCP 도구 `masc_operator_snapshot` | Reuse | 아니다. `snapshot_json` 을 바로 부른다(`operator_tool.ml:275`) | 도구 호출 |
| `GET /api/v1/dashboard/briefing/sections` | Reuse | 그렇다 | 요청 |

루프는 정해진 주기로 돌지 않는다. 처음 한 번 읽은 뒤에는 바뀐 것이 오거나, 지난 읽기가 돌려준 기한이 되면 읽는다(`proactive_refresh.mli:90-92`, `:108-125`). 간격은 바뀐 것 때문에 읽는 두 번 사이의 최소 시간이다(`:37-41`). Keeper 가 바쁘면 바뀐 것이 늘 와서 간격마다 한 번씩 돈다. 보는 사람이 없어도 돈다.

Current 는 10초 캐시(trust `operator_control_snapshot_trust.ml:5`, audit `operator_control_snapshot_tool_audit.ml:157`)를 일부러 건너뛴다. 10초 안에 들어온 커밋도 봐야 해서다(`operator_control_snapshot_tool_audit.ml:155-156`). 루프와 요청은 16칸 세마포어 하나를 나눠 쓴다(`operator_control_snapshot.ml:41`).

풀 작업 안에서 `Dated_jsonl` 끝 읽기는 그 자리에서 돈다. 풀 밖 Eio fiber 에서 부르면 풀에 IO 작업을 내고 기다린다(`dated_jsonl.ml:582`, `domain_pool_ref.ml:45-51`).

### 1.3 이미 있는 두 모양

메모리 값을 쓰는 곳에서 고치는 모양:

| 무엇 | 쓰는 곳 | 읽는 곳 |
|---|---|---|
| Owner meta projection | 커밋 뒤 `Atomic.set`(`keeper_owner.ml:957`) | `Keeper_owner_projection.lookup`(`keeper_owner_projection.ml:31-36`). 잠금 없이 `Atomic` map 을 읽는다. `/keepers/turns` 는 `Keeper_owner_registry.get` 으로 같은 값을 쓴다(`server_keeper_waiting_inventory.ml:1270-1273`) |
| `Keeper_turn_pulse` | 기동 때 결정 기록으로 채우고(`server_bootstrap_maintenance.ml:741`), 턴이 끝나면 `record`(`keeper_heartbeat_loop_cycle.ml:123`) | `get`(`keeper_tool_surface_ops.ml:438`) |
| 승인 큐 | 바꾸는 함수가 저장 잠금 안에서 `Atomic` map 을 바꾼다(`keeper_approval_queue_rules.ml:35`) | 메모리만 읽는다 |

읽을 때 바뀐 만큼만 다시 읽는 모양:

| 무엇 | 읽을 때마다 하는 일 |
|---|---|
| `Dated_jsonl.count_entries` | 날짜 파일을 모두 목록으로 얻고 stat 한다. 늘어난 바이트만 읽는다 |
| `Tool_audit_cache` | 위 행 수를 세고, 늘어난 행만 읽는다 |
| 승인 audit `Audit_recent_index`(RFC-0474 L4f) | 지난 읽기 뒤 바뀐 만큼 먼저 따라간다 |
| `File_version_cache`(`schedules.json`) | stat 한 번. 쓰는 쪽이 해석본을 남긴다(`schedule_store.ml:575`) |

두 번째 모양은 서버 밖에서 고친 파일도 본다. 그 대신 읽을 때마다 목록과 stat 이 남는다. `dated_jsonl.ml:1614-1617` 은 TTL 캐시를 지운 이유를 "바깥 쓰기를 숨긴다"고 적었다.

### 1.4 쓰는 곳과 지우는 곳

| 사실 | 쓰는 함수 | 부르는 곳 | 잠금 |
|---|---|---|---|
| 결정 기록 | `Keeper_types_support.append_decision_record`(`keeper_types_support.ml:292-295`). 크기가 차면 `.1` 로 돌린다(`:250-283`). 쓰는 줄은 `utf8_repair_string` 을 거친다(`:285-288`) | 4곳. 넘기는 JSON 모양이 저마다 다르다 | 돌리기는 잠금이 없다. 쓰기는 system thread 안에서 경로마다 둔 OS mutex(`Stdlib.Mutex`)를 잡는다(`fs_compat_base_io.ml:274-279`, `:309-314`). system thread 가 끝나면 fiber 가 취소됐는지 본다(`:349-353`) |
| 도구 호출 원장 | `Keeper_tool_call_log.log_call` → `Dated_jsonl.append_rotating`(`keeper_tool_call_log.ml:639-645`). commit 이 필요 없는 행은 비동기 큐로 가고, 큐가 차면 버린다(`:761-805`) | 6곳 | workspace 에 저장소 하나다(`:473-474`). 모든 Keeper 가 같은 잠금을 쓴다. `max_bytes` 가 없어 append 뒤 prune 이 돌지 않는다(`:486`) |
| execution receipt | `Keeper_execution_receipt.append` → `Dated_jsonl.append`(`keeper_execution_receipt.ml:554`) | 2곳 | 저장소 잠금(`dated_jsonl.ml:884`). `open_store` 는 같은 디렉터리에 같은 mutex 를 준다(`:156-171`) |
| TurnRecord | `Keeper_turn_record_writer.write` → `Dated_jsonl.append`(`keeper_turn_record_writer.ml:71`) | 1곳 | 같다 |
| metrics | `Keeper_types_support.append_keeper_metrics`(`keeper_types_support.ml:48`) | 2곳 | 같다 |
| meta | Owner 커밋이 메모리의 meta 를 통째로 쓴다(`keeper_meta_store.ml:726-729`) | Owner 하나 | Owner |

`Dated_jsonl` 은 저장소 잠금 안에서 [줄 쓰기 → `on_committed` → append 뒤 prune] 순서로 돈다(`dated_jsonl.ml:884-888`, `:1787-1789`). 도구 호출 원장의 `on_committed` 는 화면을 깨우는 알림(`notify_written`)을 보낸다(`keeper_tool_call_log.ml:640-644`).

쓰기가 실패했을 때의 지금 동작이 둘 있다. 둘 다 `append_file_unix` 하나의 일이다(`fs_compat_base_io.ml:309-314`). 결정 기록과 `Dated_jsonl` 저장소가 모두 이 함수로 쓴다. 이 RFC 의 저장소만 쓰는 함수가 아니다. `Fs_compat.append_jsonl` 과 `append_file` 을 부르는 곳이 모두 여기로 온다. task metrics, activity graph, workspace memory log, cost 기록이 그렇다.

- 실패한 쓰기의 바이트가 나중에 파일에 닿는다. 이 함수는 캐시된 채널에 `output_string` 과 `flush` 를 부른다. 예외가 나도 채널은 캐시에 남는다(`lib/fs_compat/fd_cache.ml:78-98`). OCaml 런타임은 쓰기가 실패해도 채널 버퍼를 버리지 않는다. `EBADF`·`EPIPE`·`ECONNRESET` 일 때만 버린다(5.5.2 `runtime/io.c` 의 `flush_partial`). 남은 바이트는 같은 파일의 다음 쓰기 앞에 붙어 들어간다. 다음 쓰기가 없어도 채널을 닫을 때 들어간다. 채널은 캐시에서 밀려날 때, 회전할 때, 프로세스가 끝날 때 닫힌다(`lib/fs_compat/fd_cache.ml:27-44`, `dated_jsonl.ml:1775`). 독립 실험으로 네 경우를 확인했다(#52980).
- 끊긴 줄 뒤에 다음 줄이 붙는다. 쓰는 함수는 파일 끝이 줄바꿈인지 보지 않는다(`fs_compat_private_file_update.ml:766-783`, `keeper_types_support.ml:285-288`). 읽는 쪽은 붙은 줄을 깨진 줄로 본다(`dated_jsonl.ml:689-694`). 쓰다가 프로세스가 죽은 뒤에 생긴다(#52974).

끊긴 끝을 다루는 약속이 이미 하나 있다. durable private JSONL 계열(`append_private_jsonl_durable_*`)이다. 이 계열은 마지막 줄바꿈 뒤 바이트를 행으로 보지 않는다. 그래서 쓰는 쪽이 그 바이트를 잘라 낸다(`fs_compat_private_jsonl_write.ml:260-284`, #37117, #52943). 이 RFC 의 저장소는 그 계열이 아니다. 여기 reader 는 줄바꿈 없는 마지막 줄도 읽는다(`dated_jsonl.ml:334`, `:1392`). 결정 기록은 그 줄이 object 로 읽히면 행으로 쓴다(`keeper_runtime_trust_snapshot.ml:352-361`). 잘라 내면 화면이 이미 보인 행이 사라질 수 있다. 그래서 W 는 자르지 않는다. 끊긴 조각을 한 줄로 따로 두고 그 뒤에 쓴다.

지우는 곳:

- 날짜 파일 prune: 기동 때(`server_runtime_startup_maintenance.ml:73`)와 24시간마다(`server_bootstrap_maintenance.ml:936-947`). `on_pruned` 는 저장소 잠금을 푼 뒤, 하나라도 지웠을 때만 돈다(`dated_jsonl.ml:2175-2179`). prune 이 도중에 예외로 끝나면 돌지 않는다.
- append 뒤 바이트 prune: `on_committed` 다음에 같은 잠금 안에서 돈다. metrics 저장소에는 `max_bytes` 가 있다(`keeper_metrics_storage.ml:6-11`). 설정 `metrics.store_max_bytes` 의 기본값은 0 이라 지금은 돌지 않는다.
- 대시보드 purge(`server_dashboard_http_delete_actions.ml:672`, `:805`)와 runtime 디렉터리 지우기(`:865-870`). 뒤의 것은 receipt, TurnRecord, metrics 를 지운다(`:350-355`). 둘 다 저장소 잠금을 잡지 않는다. metrics 저장소만 지우기 전에 writer 와 캐시를 닫는다(`server_dashboard_http_delete_actions.ml:802-810`, `dated_jsonl.ml:1544-1550`). runtime 디렉터리 지우기는 닫지 않고, 지운 뒤 디렉터리 캐시만 비운다(`:868-870`). 지워진 경로는 다음 쓰기가 다시 연다(`lib/fs_compat/fd_cache.mli`).

서버 밖에서 이 RFC 의 저장소에 쓰는 곳은 없다. `masc-stdio` 와 HTTP 런타임은 base path lease 를 같이 잡는다(`main_stdio_eio.ml:54`, `main_eio.ml:273`). `seed_telemetry_store.py` 는 자기 `--root` 에만 쓴다. 다만 `scripts/migrate-keeper-meta-sandbox.sh` 는 meta 파일을 고친다. 스크립트 머리에는 서버를 멈추라는 말이 없다. 서버가 돌 때 고치면 Owner 의 다음 커밋이 메모리 값으로 파일을 덮는다. 지금도 그렇다.

W 가 고치는 함수로 범위를 넓히면 사정이 다르다. cost 기록은 서버와 CLI 가 같은 파일에 덧붙인다(`keeper_hooks_agent_core_cost_events.ml:447-451`, `bin/masc_cost.ml:63-70`). 둘은 다른 process 다. 그래서 W 는 다른 process 가 같이 쓰는 파일에서도 남의 줄을 지우지 않아야 한다(§4).

### 1.5 측정

연구 노트 1절·6절의 숫자다. 서버 로그는 Keeper 하나의 일이 300 ms 를 넘을 때만 sub-op 를 남기고, 세마포어 대기나 일이 500 ms 를 넘을 때만 wait 를 남긴다.

- 22:22~22:56: 300 ms 넘는 Keeper 행 867개, 35번 몰림, 몰림 하나에 중앙값 25행.
- 느린 행의 sub-op 중앙값: trust 186 ms, audit 164 ms, meta 23 ms.
- 세마포어 대기: wait 나 work 가 500 ms 를 넘긴 547행에서 중앙값 593 ms, p90 4.5 s.
- 같은 창의 TUI 1초 넘는 요청: `/keepers/turns` 15번(1,011~3,081 ms), `/gate/keepers` 3번, `/dashboard/health-line` 1번.

## 2. 규칙에서 나오는 것

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 그 사실 때문에 파일을 열지 않는다.

1. 값 하나는 (저장소, 사실) 하나다. 칸은 저장소의 정체로 찾는다. 글자로 만든 key 를 따로 두지 않는다. 표기가 다른 두 글자가 같은 저장소에 칸을 둘 만들 수 있어서다. `Dated_jsonl` 은 디렉터리마다 mutex 하나를 주는 등록부를 이미 둔다(`dated_jsonl.ml:137-154`). 그 저장소의 칸 묶음을 같은 항목에 둔다. 그래서 같은 잠금을 쓰는 쪽은 같은 칸을 본다. 결정 기록은 파일 하나라 그 등록부가 없다. 그 칸은 쓰기가 경로 mutex 를 고르는 정규화 경로로 찾는다.
2. 칸 하나는 `{ generation; slot }` 을 담은 `Atomic` 하나다. `slot` 은 `Unfilled` 거나 값을 든 `Filled` 다. 칸을 바꿀 때는 늘 새 record 를 만들고 세대를 올린다.
3. 불변식: 파일을 바꾸는 중인 쪽이 없으면, `Filled` 의 값은 그 칸의 읽기(§3.4)가 파일에서 다시 계산한 값과 같다. 그 읽기는 실패를 결과로 돌려준다. 읽기가 실패하는 동안에는 불변식이 아무것도 주장하지 않는다. `Unfilled` 도 아무것도 주장하지 않는다.
4. 파일을 바꾸는 쪽은 모두 파일을 바꾼 뒤에 그 저장소의 칸을 맞춘다. 쓰기와 그 안의 회전, prune, purge, 디렉터리 지우기가 그렇다.
   - 쓰기는 파일을 바꾸기 전에 그 저장소의 칸을 모두 읽어 둔다. 쓴 뒤 칸마다 읽어 둔 값에서 새 값을 만든다. 칸이 그대로면 compare-and-set 으로 넣는다. 칸이 바뀌었으면 칸을 비운다.
   - 쓰기가 새 값을 읽는 쪽과 똑같이 만들 수 없으면 칸을 비운다(§3.3).
   - 쓴 행이 어떤 칸의 값을 바꾸지 않아도 그 칸을 건너뛰지 않는다. 같은 값으로 세대를 올린다. `Unfilled` 도 세대를 올린다. 그 쓰기와 겹친 채우기가 쓰기 전의 파일로 계산한 값을 넣지 못하게 하려는 것이다.
   - 지우는 쪽은 끝나는 모든 경로에서 그 저장소의 칸을 모두 비운다. 몇 개를 지웠는지, 성공했는지 보지 않는다.
5. 쓰는 쪽은 `Unfilled` 를 채우지 않는다. 쓰는 쪽은 자기 행만 알아서 목록 전체를 만들 수 없다.
6. 쓰기가 실패하거나, 됐는지 모르거나, 칸을 고치기 전에 취소되면 그 저장소의 칸을 모두 비운다. 쓰지 않은 것이 확실하면(큐가 차서 버림, append guard 가 건너뜀) 칸을 그대로 둔다. 파일이 그대로라서다.
7. 채우는 쪽은 잠금을 잡지 않는다. 파일을 읽기 바로 전에 칸을 읽고, 파일에서 값을 계산하고, 칸이 그대로일 때만 compare-and-set 으로 넣는다. 읽기가 실패하면 넣지 않는다. 실패를 빈 값으로 바꾸는 reader 로는 채우지 않는다.
8. 이 RFC 가 더하는 코드는 저장소 잠금 안에서 기다리지 않는다. 잠금 안에서 더하는 일은 `Atomic` 연산과 새 값 계산뿐이다. `Dated_jsonl` 은 지금도 저장소 잠금을 쥔 채 system thread 의 쓰기를 기다린다(`dated_jsonl.ml:884-886`). 그 동작은 그대로다.
9. 메모리 값은 디스크에 저장하지 않는다. 권위는 파일이다.
10. 서버 밖에서도 고치는 파일(profile TOML)은 이 규칙에 넣지 않는다. 지금처럼 내용 키 캐시로 읽는다.
11. 쓰는 함수의 전제가 둘 있다. 성공한 쓰기는 줄 처음에서 시작해 넘긴 줄을 통째로 더한다. 실패한 쓰기는 호출이 끝난 뒤 파일에 닿지 않는다. 지금은 둘 다 어긴다(§1.4). §4 의 W 가 이 전제를 세운다. 실패한 쓰기가 이미 넣은 바이트는 W 가 되돌린다. 되돌리지 못하면 줄바꿈 없는 조각으로 남는다. 다음 쓰기는 그 조각 뒤에 붙지 않는다.

규칙 4·7 이 불변식을 지키는 까닭은 이렇다. 채우는 쪽이 넣은 값은 그 뒤에 끝나는 변경이 늘 덮는다. 변경은 파일을 바꾼 뒤 칸을 바꾸기 때문이다. 채우는 쪽이 칸을 읽은 뒤 끝난 변경이 있으면 칸이 이미 바뀌어서 채우는 쪽의 compare-and-set 이 실패한다. 값을 바꾸지 않는 쓰기도 세대를 올리므로 예외가 없다. 쓰는 쪽은 파일을 바꾸기 전에 칸을 읽어 둔다. 그 사이 채우는 쪽이 넣은 값에는 쓴 행이 이미 들어 있을 수 있다. 쓰는 쪽은 읽어 둔 칸에서 새 값을 만들므로 그 행을 한 번 더 더하지 않는다. 이 논리는 규칙 11 에 기댄다. 쓴 뒤의 파일은 읽어 둔 값의 파일에 쓴 줄 하나를 더한 것이어야 한다. 끊긴 줄 뒤에 붙은 줄이나 뒤늦게 들어온 바이트는 이 전제를 깬다. 실패한 쓰기가 남긴 조각은 이 전제를 깨지 않는다. 그 쓰기는 칸을 비우고(규칙 6), 조각은 다음 채우기가 깨진 줄 하나로 읽는다.

## 3. 설계

### 3.1 meta 는 Owner 를 읽는다

`keepers_json`, board address, `masc_keeper_list` 는 meta 파일을 열기 전에 `Keeper_owner_projection.lookup` 을 본다. 이 함수는 잠금 없이 `Atomic` map 을 읽는다(`keeper_owner_projection.ml:31-36`). 그래서 system thread 에서 도는 board address 에서도 부를 수 있다. Owner 는 커밋할 때 메모리의 meta 를 파일에 통째로 쓰고, 쓰기가 성공했을 때만 메모리 값을 바꾼다(`keeper_owner.ml:936-957`). 새로 저장하는 상태는 없다.

행은 Owner 값을 그대로 쓰지 않는다. Owner 값의 설정 필드에는 TOML 값이 있고, 파일을 읽은 값에는 자리 채움 값이 있다(§1.1). 그대로 쓰면 `activation_mode` 와 trust 의 sandbox 값이 지금과 달라진다.

행은 Owner 값을 파일과 같은 길로 한 번 돌린 값을 쓴다. 파일에 쓰는 encoder(`meta_to_json`, `keeper_meta_store.ml:34-35`)로 바꾸고, 파일을 읽는 함수의 '글자 → meta' 부분(`:192-250`)으로 되읽는다. 둘 다 메모리에서 한다. Owner 가 쓴 파일이 바로 그 encoder 의 출력이다. 그러니 이 값은 그 파일을 읽은 값과 같다.

자리 채움 값을 따로 적은 함수는 만들지 않는다. 그런 함수는 decoder 가 바뀌면 어긋난다. 변환은 행 하나에 한 번이고 meta 크기에 비례한다. L1 에서 그 시간을 재서 PR 에 적는다.

| `lookup` 결과 | 행 |
|---|---|
| `Owner_projection { meta = Some m; _ }` 이고 Owner 의 meta 쓰기가 모두 끝까지 됐다 | `m` 을 위 변환에 거친 값으로 만든다. 파일을 열지 않는다 |
| `Owner_projection { meta = Some _; _ }` 인데 meta 쓰기 하나가 됐는지 모르게 끝났다 | 지금처럼 파일을 읽는다 |
| `Owner_projection { meta = None; _ }`, `Owner_absent` | 지금처럼 파일을 읽는다. 결과도 지금과 같다(없으면 `Keeper_gone`, 못 읽으면 `Keeper_unread`, `operator_control_snapshot.ml:210-216`) |

Owner 가 없는 Keeper 는 지금 동작 그대로다. 기동 때 meta 를 못 읽었거나, 이름이 맞지 않거나, Owner 가 시작하지 못한 Keeper 가 그렇다(`keeper_owner_registry.ml:112-134`, `:410-421`). 새 unread 이유는 만들지 않는다. TUI decoder 는 이유를 닫힌 목록으로 읽는다(`keeper_snapshot_unread.ml:44-47`).

Owner 의 meta 가 파일과 어긋난 채 남는 때가 둘 있다.

- `store.replace` 가 예외로 끝난다. Owner 는 행에 알리고 예외를 다시 던진다(`keeper_owner.ml:893-902`, `:930-934`). 그 Owner 는 그 뒤로 답하지 않는다(`:3317-3319`).
- `store.replace` 가 `Error` 로 끝난다. Owner 는 metadata 저장소를 막고, 재시작할 때까지 meta 커밋을 모두 거절한다(`:864-876`, `:2247-2254`).

두 경우 모두 파일은 이미 바뀌었을 수 있고(`:871-872`), Owner 의 메모리 값은 옛 값이다. 다음 커밋이 없어서 그 차이는 재시작까지 간다. 그래서 행은 그때 Owner 값을 쓰지 않고 지금처럼 파일을 읽는다. L1 은 Owner 가 "meta 쓰기가 됐는지 모르게 끝났다"를 `Atomic` 으로 내놓게 한다. Owner 는 행에 알리기 전에 그 값을 먼저 적는다. 알림을 받고 읽는 행이 옛 값을 보지 않게 하려는 것이다.

서버가 도는 동안 밖에서 meta 파일을 고치면 보이는 값이 지금과 달라진다(`scripts/migrate-keeper-meta-sandbox.sh`, §1.4). 지금 행은 Owner 의 다음 커밋 전까지 고친 파일 값을 보인다. L1 뒤에는 처음부터 Owner 값을 보인다. 고친 파일 값은 어느 쪽이든 Owner 의 다음 커밋이 덮는다.

### 3.2 새 모듈 `Keeper_row_facts`

모양 예시다. 이름은 구현 때 정한다.

```ocaml
type 'a slot =
  | Unfilled
  | Filled of 'a

(* 칸 하나. 바꿀 때마다 새 record 를 만든다. *)
type 'a cell = { generation : int; slot : 'a slot }

type latest =
  | No_row
  | Row of Yojson.Safe.t
  | Unparsed_row of string   (* 파일의 마지막 줄이 JSON 이 아니다 *)

(* 목록 값의 한 줄. 깨진 줄도 창 안의 자리를 지킨다. *)
type line =
  | Parsed_line of Yojson.Safe.t
  | Unparsed_line of string

(* 날짜 파일 저장소의 값. newest_day 는 이 값이 본 가장 새 날짜 파일이다. *)
type 'a dated = { value : 'a; newest_day : day option }

(* 저장소 하나의 칸 묶음. 저장소 종류마다 타입이 하나다. *)
type receipt_cells = { receipt : latest dated cell Atomic.t }
type turn_record_cells = { turn_record : latest dated cell Atomic.t }
type metrics_cells =
  { metrics_recent : line list dated cell Atomic.t  (* metrics 끝 120줄 *)
  ; turn_audit : latest dated cell Atomic.t         (* 저장소 전체에서 가장 최근 Turn tool audit 행 *)
  }
type tool_call_cells = { tool_calls : line list dated cell Atomic.t }  (* 원장의 마지막 16줄 *)
type decision_cells = { decision : latest cell Atomic.t }  (* 결정 기록의 마지막 object 행 *)

(* Dated_jsonl 이 등록부 항목에 묶음을 둔다. 없으면 make 로 만들어 넣는다.
   key 는 Stdlib 의 Type.Id 다. Dated_jsonl 은 묶음의 타입을 모른다. *)
val cells : Dated_jsonl.t -> 'cells Type.Id.t -> make:(unit -> 'cells) -> 'cells
```

- 칸 묶음은 저장소 등록부 항목에 둔다(규칙 1). 처음 찾을 때 등록부 잠금 안에서 묶음을 통째로 만든다. 이미 있으면 있는 묶음을 쓴다. 있는 묶음을 새것으로 바꿔 끼우지 않는다. `Keeper_owner_projection.install` 처럼 덮어쓰면(`keeper_owner_projection.ml:15-19`) 쓰는 쪽과 읽는 쪽이 서로 다른 칸을 본다.
- 쓰는 쪽도 쓰기 전에 묶음을 찾거나 만든다. 그래서 쓰는 도중에 그 저장소의 칸이 새로 생기지 않는다.
- 등록부 key 는 상대 경로와 끝의 `/` 만 맞춘다(`dated_jsonl.ml:137-144`). symlink 나 `..` 로 다르게 적은 경로는 지금도 잠금이 따로다. 칸은 잠금과 똑같이 나뉜다. 지금보다 나빠지지 않는다.
- `Type.Id` 는 OCaml 5.5.2 에 있다(작은 프로그램으로 확인). 아래 층 라이브러리가 Keeper 타입을 몰라도 타입이 지켜진다.
- 값은 디스크에 쓴 줄을 읽는 쪽과 같은 parser 로 해석한 JSON 이다. 결정 기록 4곳, 도구 호출 6곳, metrics 2곳이 넘기는 모양이 저마다 달라서 행 타입으로 묶지 않는다(`keeper_tool_memory_runtime.ml:1332`, `keeper_unified_metrics_decision.ml:401` 등). 읽는 쪽은 지금 쓰는 decoder 를 그대로 쓴다. 그래서 `Undecodable_turn_record` 같은 구분도 지금처럼 나온다(`keeper_context_observation_projection.ml:92-101`). `Unparsed_row` 는 그 상태도 칸에 담으려고 둔다.
- 목록 값(도구 호출 16줄, metrics 120줄)은 읽는 쪽이 세는 줄을 자리 그대로 든다. 두 reader 는 빈 줄이 아닌 줄을 세고, 깨진 줄은 그 뒤에 건너뛴다(`keeper_tool_call_log.ml:1572-1586`, `operator_control_snapshot_tool_audit.ml:14-38`, `operator_control_snapshot_tool_names.ml:41-56`). 그래서 깨진 줄도 `Unparsed_line` 으로 든다. 깨진 줄을 빼고 들면 다음 쓰기 뒤에 창에서 빠지는 줄이 파일과 달라진다.
- 채우다 파일을 못 읽으면 값을 넣지 않는다(§3.4). 행은 그때 지금의 reader 가 내는 값을 그대로 낸다. 오류를 돌려주던 reader 는 오류를 내고(`Turn_record_read_failed` 등), 빈 값을 내던 reader 는 빈 값을 낸다. 다음 읽기가 다시 채운다.
- reader 의 답이 칸의 값으로 정해지지 않는 때에는 지금의 읽기를 그대로 부른다. 최근 receipt 가 그렇다. 칸은 마지막 줄을 든다. 마지막 줄이 깨져 있으면(`Unparsed_row`) 깨진 줄을 건너뛰는 `read_latest_receipt` 의 답은 칸으로 알 수 없다(§1.1). 그때 그 reader 는 지금처럼 파일을 훑는다.
- `newest_day` 는 채우는 쪽이 본 가장 새 날짜 파일이다. 읽는 쪽은 날짜 파일을 새것부터 읽는다(`dated_jsonl.ml:1338-1367`). 엄격한 끝 읽기는 줄마다 원본 경로를 같이 돌려준다(`dated_jsonl.mli:312-318`). 날짜는 그 경로에서 얻는다. 줄이 없거나 `turn_audit` 처럼 줄 하나만 고르는 읽기는 날짜 파일 목록 읽기(`:283-287`)에서 얻는다. 결정 기록은 파일이 하나라 이 값이 없다.
- 행 수(16, 120)와 결정 기록의 창(40,000바이트·20줄)은 지금 읽는 쪽이 쓰는 수다. 읽는 쪽 상수를 이 모듈로 옮겨 한 곳에 둔다.
- 도구 호출은 workspace 원장의 마지막 16줄을 그대로 든다. Keeper 의 최근 호출은 그 16줄에서 찾는다. 지금 `read_latest ~keeper_name` 과 같은 뜻이다. 16줄 밖으로 밀려난 Keeper 는 지금처럼 `None` 이다.

### 3.3 쓰는 쪽

쓰는 쪽은 그 저장소의 칸을 모두 읽어 둔 뒤 파일을 바꾸고, 그다음 칸마다 맞춘다. 칸을 바꾸는 일은 `Atomic` 연산뿐이다.

```ocaml
(* 잠금이 있으면 그 안에서, 파일을 바꾸기 전에. 그 저장소의 칸마다 *)
let before = Atomic.get cell in
(* ... 파일 쓰기. 예외·취소면 그 저장소의 칸을 모두 비우고 다시 던진다 ... *)
match step before.slot written with
| Some slot ->
  let after = { generation = before.generation + 1; slot } in
  if not (Atomic.compare_and_set cell before after) then forget cell
| None -> forget cell
(* written: 디스크에 쓴 줄을 해석한 값과, 그 줄이 간 날짜 파일
   step:
   Unfilled -> Some Unfilled
   Filled v ->
     새 값을 읽는 쪽과 똑같이 만들 수 있으면 Some (Filled 새 값).
     쓴 행이 이 칸의 값을 바꾸지 않으면 새 값은 v 다.
     만들 수 없으면 None *)
(* forget: 칸을 { generation + 1; Unfilled } 로 바꿀 때까지 compare-and-set 을 되풀이 *)
```

- `Dated_jsonl` 저장소(도구 호출, receipt, TurnRecord, metrics): 저장소 잠금을 잡은 뒤, 쓰기 전에 그 저장소의 칸을 읽는다. 줄을 쓴 직후에 칸을 맞춘다. L2 는 `Dated_jsonl` 의 append 에 "잠금 안, 쓰기 전" hook 을 더한다. 칸을 맞추는 일은 `on_committed` 자리에서 한다.
- 도구 호출 원장은 `on_committed` 안에서 `committed := true` 다음, 알림(`notify_written`) 앞에 칸을 맞춘다(`keeper_tool_call_log.ml:640-644`). 줄이 디스크에 있다는 표시가 먼저라서, 칸을 맞추다 예외가 나도 drain 이 그 행을 다시 쓰지 않는다(`:729-738`). 알림을 받고 읽는 쪽은 새 값을 본다.
- 크기 회전은 쓰기 안에서 일어난다(`dated_jsonl.ml:1746-1790`). 회전해도 읽는 쪽이 보는 줄의 순서는 같으므로 새 값을 만들 수 있다. 다만 채우는 쪽은 파일 목록을 얻은 뒤 이름으로 파일을 연다(`dated_jsonl.ml:1310-1336`). 그 사이 회전이 끼면 옛 목록으로 읽는다. 쓰기가 `Unfilled` 의 세대도 올리므로 그런 채우기는 들어가지 못한다. 지금의 Turn tool audit 캐시는 훑기 전후의 행 수를 견줘 같은 일을 막는다(`keeper_status_metrics.ml:246-248`, `:259-261`).
- append 뒤 바이트 prune(metrics 에 `max_bytes` 를 켠 때)은 `on_committed` 다음에 파일을 지운다. `prune_to_max_bytes_unlocked` 는 지운 파일 수를 돌려준다(`dated_jsonl.ml:831-850`). 지금 부르는 쪽은 그 수를 버린다(`:865-870`). 하나라도 지웠거나 prune 이 예외로 끝나면 그 저장소의 칸을 모두 비운다.
- 쓰기는 지금 시각의 날짜 파일로 간다(`dated_jsonl.ml:885`, `:1748`). 읽는 쪽은 날짜 파일을 새것부터 읽는다. 시계가 뒤로 가서 지난 날짜 파일에 쓰면 그 행은 읽는 쪽에게 가장 새 행이 아니다. 그래서 쓴 날짜 파일이 값이 본 가장 새 날짜 파일(`newest_day`)보다 앞이면 칸을 비운다. 아니면 새 값의 `newest_day` 를 쓴 날짜 파일로 둔다.
- 결정 기록: 돌리기에는 잠금이 없고, 쓰기의 잠금은 system thread 안의 OS mutex 다(§1.4). 이 RFC 는 잠금을 더하지 않는다. 쓰는 쪽은 돌리기 전에 칸을 읽고, 쓰기가 끝난 뒤 칸을 맞춘다. 같은 Keeper 의 결정 기록을 두 곳이 같이 쓰면 늦게 온 compare-and-set 이 실패해 칸이 비워진다. 그래도 불변식은 지켜진다.
- 결정 기록의 새 값은 디스크에 쓴 줄(`utf8_repair_string` 을 거친 줄)로 만든다. 줄바꿈까지 쳐서 읽는 쪽 창의 절반(20,000바이트) 이하이고 JSON object 인 줄만 `Row` 로 넣는다. 아니면 칸을 비운다.
  - 읽는 쪽은 마지막 40,000바이트를 한 번에 읽는다. 창이 파일 처음보다 뒤에서 시작하면 남은 줄 가운데 첫 줄을 버린다(`keeper_memory_recall.ml:37-42`, `:75-78`). 그래서 창에 마지막 줄 앞의 내용이 없으면 마지막 줄도 버려진다. 줄이 창의 절반 이하면 앞 줄의 끝이 늘 창에 들어온다.
  - 로그를 돌린 직후에는 새 파일에 쓴 줄 하나만 있다. 창이 파일 처음에서 시작하므로 첫 줄을 버리지 않고, 쓴 줄이 그대로 값이다. 읽는 쪽은 `.1` 로 옮긴 파일을 지금도 읽지 않는다.
  - object 가 아닌 줄은 건너뛰고 앞 줄을 찾는다(`keeper_runtime_trust_snapshot.ml:336-366`). 그 결과는 쓴 줄 하나로 알 수 없다.
- metrics 쓰기는 칸 둘을 맞춘다. `metrics_recent` 에는 쓴 줄을 더하고, 120줄을 넘는 앞 줄을 뺀다. `turn_audit` 은 쓴 행이 Turn tool audit 행이면 그 행으로 바꾸고, 아니면 같은 값으로 세대만 올린다. 행이 Turn tool audit 인지는 읽는 쪽과 같은 `parse_snapshot` 으로 본다(`keeper_status_metrics.ml:205-239`). heartbeat 가 이어져도 `Filled` 인 `turn_audit` 은 비워지지 않는다.
- 쓰기가 예외로 끝나면 그 저장소의 칸을 모두 비우고 예외를 다시 던진다. 취소도 예외로 온다. 칸을 맞추는 코드가 예외를 던져도 같다.
- system thread 에 맡긴 쓰기가 도는 동안 부른 fiber 는 깨어나지 않는다. 풀 밖 fiber 는 host 에 일을 넘기고 취소되지 않는 `await` 로 기다린다(`lib/fs_compat/systhread_host.ml:37-48`, `:193-198`). 풀 작업이거나 host 가 없으면 `Eio_unix.run_in_systhread` 로 간다(`:174-178`). Eio 의 thread pool 도 넘긴 일에 취소를 걸지 않는다(Eio `unix/thread_pool.ml` 의 `submit`). 넘기기 전에 이미 취소됐으면 쓰기는 시작하지 않고 `Cancelled` 가 온다(`:180`). 쓰기가 일어나지 않았는데 칸을 비우는 것은 조심이 지나칠 뿐 틀리지 않는다.
- 규칙 11 이 서면 실패한 쓰기의 바이트는 나중에 파일에 닿지 않는다. 그래서 칸을 비운 뒤에 채운 값이 그 바이트 때문에 틀리는 일이 없다. 지금은 그 바이트가 다음 쓰기나 채널 닫기에 실려 들어간다(§1.4). 닫기는 어느 칸의 순서도 따르지 않는 변경이라 칸으로는 막을 수 없다.
- `Fs_compat.append_file` 은 줄을 쓴 뒤에 취소를 확인한다(`fs_compat_base_io.ml:349-353`). 그래서 줄은 썼는데 칸은 못 고친 채 취소될 수 있다. 쓰는 쪽은 칸을 고치기 전에 끝나는 모든 경로에서 칸을 비운다.
- `Dated_jsonl.append` 는 append guard 가 막으면 조용히 건너뛴다. `append_notifying_commit` 은 그때 `Append_guard_skipped` 를 던진다(`dated_jsonl.ml:892-905`). 건너뛴 쓰기는 파일을 안 바꾸므로 칸을 그대로 둔다. 부르는 쪽의 동작도 지금과 같게 둔다.

### 3.4 채우는 쪽과 비우는 쪽

- 칸이 `Unfilled` 면 읽는 쪽이 채운다. 파일을 읽기 바로 전에 칸을 읽고, 그 칸의 읽기(아래 표)로 값을 계산한다. 칸이 그대로일 때만 compare-and-set 으로 세대를 올린 `Filled` 를 넣는다. compare-and-set 이 실패하면 계산한 값을 이번 행에만 쓰고 칸에는 넣지 않는다.
- 칸의 읽기는 실패를 결과로 돌려준다. `Error` 면 칸에 아무것도 넣지 않는다. 지금 행이 쓰는 reader 여럿은 실패를 빈 값으로 바꾼다.
  - 결정 기록 reader 는 tail 읽기의 `Error` 를 빈 목록으로 바꾼다(`keeper_runtime_trust_snapshot.ml:326-334`).
  - `Dated_jsonl` 의 목록 읽기는 `Sys_error` 에 빈 목록을 낸다(`dated_jsonl.ml:179-186`). 끝 읽기(`:1338-1370`)와 도구 호출 reader(`keeper_tool_call_log.ml:1558-1587`)가 그 목록을 쓴다.
  - descriptor 가 바닥나 달 하나가 빈 것으로 읽힌 일이 실제로 있었다(`dated_jsonl.ml:1023-1026`).

  그런 reader 로 채우면 '행 없음'이 값으로 굳는다. 다음 쓰기가 올 때까지 화면이 그 값을 보인다.
- 그래서 칸마다 읽기를 하나로 정한다. 채우기와 시험의 oracle 이 같은 함수를 쓴다.

  | 칸 | 칸의 읽기 | 비고 |
  |---|---|---|
  | `decision` | 새 `latest_decision_result` | tail 읽기의 `Error` 를 그대로 돌려준다. 파일이 없다는 답은 `ENOENT` 일 때만 낸다. 지금의 `latest_decision_json` 은 이 함수의 `Error` 를 `None` 으로 바꾼 것이 된다 |
  | `tool_calls` | `Dated_jsonl.read_recent_lines_result`(`dated_jsonl.mli:312`) | 이미 있다. 깨진 줄도 한 줄로 센다 |
  | `receipt`, `turn_record` | 같은 함수로 한 줄 | TurnRecord reader 는 지금도 실패를 돌려준다(`keeper_context_observation_projection.ml:73-117`) |
  | `metrics_recent` | 같은 함수로 120줄 | 최근 활동 5줄도 이 값에서 얻는다(`operator_control_snapshot.ml:427-435`) |
  | `turn_audit` | `find_latest_entry_result store parse_snapshot`(`keeper_status_metrics.ml:255`) | 지금 `Tool_audit_cache` 의 첫 채우기가 쓰는 읽기다 |

- 엄격한 읽기는 `YYYY-MM/DD.jsonl` 모양의 일반 파일만 받는다. symlink 나 다른 모양은 `Error` 다(`dated_jsonl.mli:267-273`). 그런 저장소의 칸은 채워지지 않고, 행은 지금 reader 로 읽는다. 보이는 값은 그대로다.
- 칸으로 만든 행 값은 지금 reader 가 파일에서 만든 값과 같아야 한다. 칸의 읽기가 `Ok` 인 모든 상태에서 그렇다. 차분 시험이 이것을 본다(§5).
- 채우는 쪽은 저장소 잠금을 잡지 않는다. 지금의 끝 읽기는 풀 밖에서 부르면 풀에 IO 작업을 내고 기다린다(§1.2). 잠금을 쥔 채 그 작업을 기다리면, 같은 잠금을 기다리는 행 계산이 풀을 다 차지했을 때 아무도 진행하지 못한다(§6.6).
- 풀 밖에서 채울 때는 칸 읽기와 파일 읽기를 풀 작업 하나에 넣는다. 칸을 먼저 읽고 풀 자리를 기다리면, 기다리는 동안 들어온 쓰기 하나가 그 채우기를 버리게 만든다. 도구 호출 원장은 모든 Keeper 가 쓴다. 그래서 바쁠 때 그 칸이 빈 채로 남고, 행마다 파일을 읽게 된다.
- 채우기는 칸 하나에 재시작 뒤 한 번, 비운 뒤 한 번이다. 여러 행이 같은 칸을 동시에 채울 수 있다. 그중 하나만 들어가고, 나머지는 파일을 한 번 더 읽은 셈이 된다.
- 가장 최근 Turn tool audit 행을 채울 때는 metrics 저장소를 끝에서부터 거꾸로 훑는다(`keeper_status_metrics.ml:254-258`). 지금 `Tool_audit_cache` 의 첫 채우기와 같은 일이다. 잠금을 쥐지 않으므로 heartbeat 쓰기를 막지 않는다. 훑는 동안 그 Keeper 의 metrics 쓰기가 끼면 그 채우기는 들어가지 않고, 다음 읽기가 다시 채운다. 채워진 뒤에는 Turn 행 쓰기만 값을 바꾼다. 이 칸은 쓰기가 실패했거나 지우는 쪽이 돈 뒤에만 다시 훑는다.
- 비우기: 지우는 쪽은 끝나는 모든 경로에서 그 저장소의 칸을 모두 비운다. 저장소 잠금은 필요 없다. 지우는 도중에 파일을 읽은 채우기는 compare-and-set 에서 실패하거나, 넣더라도 뒤따르는 비우기에 덮인다.
  - 지운 수나 결과를 보지 않는 까닭이 있다. 날짜 파일 prune 은 달마다 지우고, 다음 달을 열다가 예외로 끝날 수 있다(`dated_jsonl_retention.ml:5-22`, `retention_directory.ml:45-49`). 지금 `on_pruned` 는 그때 불리지 않는다(§1.4). 대시보드 purge 는 앞의 것을 지운 뒤 첫 `Error` 에서 멈춘다(`server_dashboard_http_delete_actions.ml:705-707`, `:744-746`).
  - 기동 때와 24시간 prune 은 같은 함수를 탄다. 저장소마다 잠금을 푼 뒤 비운다(`server_runtime_startup_maintenance.ml:50-62`, `dated_jsonl.ml:2165-2181`). 도구 호출 원장의 prune(`Root.Tool_calls`)은 그 workspace 의 칸을 비운다.
  - 대시보드 purge 와 runtime 디렉터리 지우기는 그 Keeper 의 칸을 모두 비운다. 어느 파일까지 지웠는지 보지 않는다.

### 3.5 행과 루프에서 바뀌는 것

- trust, tool audit, 최근 활동, context, blocker 와 `masc_keeper_list` 의 receipt 는 `Keeper_row_facts` 를 읽는다.
- 행 하나에서 registry 와 승인 큐를 한 번씩만 읽는다. receipt 칸도 한 번만 읽고, 두 reader 가 그 값을 같이 쓴다.
- 이 값들을 읽는 행 helper 에서는 `read_policy` 의 뜻이 없어진다. 쓰는 중이 아니면 메모리 값이 파일과 같아서다. 그 helper 의 Current/Reuse 구분을 지운다. quarantine inventory(`operator_control_snapshot.ml:674-689`), snapshot 캐시(`:789-793`), briefing, execution 의 `read_policy` 는 그대로 둔다.
- `Tool_audit_cache` 는 briefing(`dashboard_briefing_assembly.ml:38`)과 Keeper 상세(`keeper_status_detail.ml:592`)도 쓴다. L3 에서 두 곳을 같은 칸으로 옮긴 뒤 캐시를 지운다.
- 10초 trust 캐시(`operator:keeper-runtime-trust:compact:v1:*`)는 승인 audit 와 workspace 대기 승인 목록 읽기도 덮는다(`keeper_runtime_trust_snapshot.ml:689-702`). 이 RFC 는 그 둘을 옮기지 않는다. 그래서 §8.1 이 정해질 때까지 캐시는 그 둘 몫으로 남긴다.
- `dt_profile` 은 값이 들어가지 않는다(`operator_control_snapshot.ml:187`). 같이 지운다.

## 4. 층

층마다 부르는 길이 이어진 채로 들어간다. 부르는 곳이 없는 층은 만들지 않는다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | meta 를 Owner projection 에서 얻는다. 파일과 같은 encoder·decoder 를 거친다(§3.1). `keepers_json`, board address, `masc_keeper_list`. Owner 는 됐는지 모르게 끝난 meta 쓰기를 `Atomic` 으로 내놓는다 | 같은 Keeper 에서 파일 meta 로 만든 행과 Owner meta 로 만든 행이 같다. 설정 필드가 자리 채움 값과 다른 TOML 을 가진 Keeper 를 넣는다. Owner 가 없는 Keeper 는 지금과 같은 결과가 나온다. meta 쓰기가 `Error` 나 예외로 끝난 Keeper 의 행은 파일 값을 보인다. 운영: 느린 행 로그의 `meta` 가 0 ms 다 |
| W | 쓰는 함수 수리(#52980, #52974). PR #52991 하나다. 캐시는 버퍼 없는 descriptor 를 든다. 줄 쓰기는 파일의 마지막 바이트를 읽고, 줄 중간이면 줄바꿈부터 쓴다. 실패한 쓰기가 넣은 바이트는 파일 길이가 '쓰기 전 길이 + 쓴 바이트'일 때만 잘라 낸다(규칙 11) | #52980 의 네 경우가 시험이 된다. 실패한 쓰기 뒤에 다음 쓰기는 자기 줄만 더한다. descriptor 를 닫아도 아무것도 더하지 않는다. 끝이 끊긴 파일에 쓰면 끊긴 조각이 따로 한 줄이 된다. 다른 descriptor 가 도중에 덧붙인 줄은 지워지지 않는다. 실제 커널 실패(파일 크기 한도)와 FIFO 도 시험에 있다 |
| L2 | `Keeper_row_facts` 와 값 넷(결정 기록 마지막 행, 도구 호출 16줄, 최근 receipt, 최근 TurnRecord). `Dated_jsonl` 의 쓰기 전 hook 과 등록부 항목의 칸 묶음. 결정 기록 tail 의 결과 읽기(§3.4). 지우는 쪽이 끝나는 모든 경로의 비우기. 읽는 쪽 trust·context·blocker·`masc_keeper_list` | 차분 시험, 동시 시험, 칸 정체 시험, 잠금을 쥔 채 채우는 시험, 파일을 지운 뒤 두 번째 읽기 시험, 취소 시험, 지우다 실패하는 시험, `step` 단위 시험, TLA+ 정상·버그 cfg(§5). 운영: 느린 행 로그의 `trust` 가 0 ms 근처다. 채우기 시도 수와 들어간 수를 적는다 |
| L3 | metrics 끝 120행 칸과 가장 최근 Turn tool audit 행 칸. 읽는 쪽 tool audit·최근 활동·briefing·Keeper 상세. 그 뒤 `Tool_audit_cache` 를 지운다 | 차분 시험(`max_bytes` 를 켠 회전과 prune 포함), heartbeat 시험. 운영: 느린 행 로그의 `audit` 가 0 ms 근처다 |
| L4 | 지우기: 행 helper 의 Current/Reuse 구분, 행 몫의 audit 10초 캐시, `dt_profile`, 행 안의 중복 읽기. 그 뒤 남은 행 일(승인 audit, quarantine 원장)을 잰다 | 지운 이름을 `rg` 로 찾으면 0. 남은 행 일의 sub-op 를 로그로 센다 |

L1 과 W 는 서로 기대지 않는다. L2 는 W 가 병합된 뒤에 시작한다. W 없이 칸을 두면 실패한 쓰기 하나가 칸을 파일과 어긋나게 한다(§3.3).

W 는 `append_file_unix` 를 부르는 모든 곳에 걸린다(§1.4). 그 가운데 cost 기록은 서버와 CLI 가 같이 쓴다. W 는 파일 잠금을 잡지 않는다. 그래서 다른 process 와는 틈이 둘 남는다.

- 마지막 바이트를 읽고 쓰기 전에 남이 끊긴 줄을 남기면, 내 줄이 거기에 붙는다.
- 길이를 보고 자르기 전에 남이 덧붙이면, 그 줄이 같이 잘린다.

둘 다 system call 두 개 사이다. 이 틈 밖에서는 남의 덧붙임이 파일 길이로 보여서 자르지 않는다. 이 RFC 의 저장소는 쓰는 process 가 하나라 이 틈이 없다. 틈을 없애려면 파일 잠금이 필요하고, 쓰기마다 system call 이 둘 더 든다. cost 기록에서 잰 근거가 없어 이 RFC 는 넣지 않는다.

`_keeper_sem` 과 `MASC_KEEPER_SNAPSHOT_CONCURRENCY` 는 L4 의 측정 뒤 정한다. 행마다 승인 audit 일이 남아 있는 동안 세마포어를 지우면 그 일이 한꺼번에 몰린다.

## 5. 검증

**차분 시험.** 실제 쓰기 함수(`append_decision_record`, `log_call`, receipt `append`, TurnRecord `write`, `append_keeper_metrics`)와 돌리기, prune, purge, runtime 디렉터리 지우기, 채우기를 무작위 순서로 부른다. 한 걸음마다 두 가지를 본다. 첫째, `Filled` 값이 그 칸의 읽기(§3.4 의 표)로 파일에서 다시 계산한 값과 같다. 둘째, 칸으로 만든 행 값이 지금의 reader 가 파일에서 만든 값과 같다. reader 는 `latest_decision_json`, `read_latest ~keeper_name`, receipt 의 두 reader, TurnRecord 최근 읽기, tool audit 읽기, 최근 활동이다. 칸의 읽기가 `Error` 인 걸음에서는 칸이 채워지지 않았는지만 본다. 시험마다 base path 를 새로 만들어서 `reset_for_tests` 를 쓰지 않는다. 넣는 입력은 이렇다.

- 결정 기록 줄 길이: 창의 절반 근처와 창 크기 근처.
- object 가 아닌 줄, 목록 창 가운데의 깨진 줄, 끝이 줄 중간에서 끊긴 파일.
- 크기 회전: metrics 는 `max_bytes` 를 켠다. 도구 호출 원장은 16 MB 에서 돈다(`keeper_tool_call_log.ml:630`). 그 크기를 채우는 대신, 같은 hook 을 단 `append_rotating` 을 작은 크기로 부른다.
- 실패하는 쓰기(W 의 시험과 같은 방법)와, 몇 개를 지운 뒤 실패하는 prune·purge.
- 읽기가 실패하는 저장소: 목록을 얻을 수 없는 달 디렉터리, 읽을 수 없는 날짜 파일, symlink 로 된 날짜 파일. 채우기가 값을 넣지 않아야 한다.
- 마지막 줄이 깨진 receipt 저장소. 두 reader 의 답이 갈리는 경우다.

**동시 시험.** domain 둘이 같은 저장소에 N 줄씩 쓰는 동안 셋째 domain 이 채우기와 비우기를 되풀이한다. 끝나면 `Filled` 값이 파일에서 다시 계산한 값과 같다. 목록 값에 같은 행이 두 번 들어가지 않는다. 크기 회전을 켠 채로도 돌린다.

**칸 정체 시험.** 같은 저장소를 다른 표기(상대 경로, 끝의 `/`)로 두 번 연다. 두 handle 이 같은 칸 묶음을 받아야 한다. 한쪽으로 쓰고 다른 쪽으로 읽어 차분 시험을 한 번 돌린다.

**잠금을 쥔 채 채우는 시험.** 시험이 저장소 잠금을 잡은 채로 빈 칸을 채우게 한다. 채우기가 끝나야 한다. 채우는 쪽이 잠금을 기다리면 이 시험은 멈춘다.

**파일을 열지 않는다는 시험.** 값을 채운 뒤 그 파일을 지우고 행을 다시 만든다. 두 번째 행이 첫 번째와 같으면 읽는 쪽이 파일을 열지 않은 것이다. 이 시험은 §7 의 한계(서버가 돌 때 손으로 지운 파일은 재시작까지 안 보인다)도 그대로 보여 준다.

**취소 시험.** 쓰기가 줄을 쓴 뒤 칸을 고치기 전에 취소되게 한다. 칸이 비워져 있어야 한다.

**지우다 실패하는 시험.** prune 과 purge 가 파일을 몇 개 지운 뒤 실패하게 한다. 그 저장소의 칸이 비워져 있어야 한다.

**heartbeat 시험.** `turn_audit` 이 `Filled` 인 동안 heartbeat 행을 계속 쓴다. 칸이 비워지지 않고 값이 그대로다. 그 사이 Turn 행을 쓰면 값이 그 행으로 바뀐다.

**`step` 단위 시험.** `step` 은 읽어 둔 값, 쓴 줄, 쓴 날짜 파일만 받는 순수 함수다. 표로 넣어 결과를 본다. 지난 날짜 파일에 쓴 줄, 창의 절반을 넘는 결정 기록 줄, Turn 이 아닌 metrics 행, 깨진 줄이 든 목록이 들어간다.

**TLA+.** `KeeperRowFacts.tla` 에 쓰는 쪽 둘, 채우는 쪽 하나, 지우는 쪽(prune·purge) 하나를 둔다. 저장소는 파일의 열이다(지금 쓰는 파일과 회전으로 닫힌 파일). 파일은 줄의 열이고, 줄에는 종류가 있다(Turn, 그 밖, 깨진 줄). 가장 새 파일의 마지막 줄은 줄바꿈 없이 끝날 수 있다. 그 줄은 온전한 행일 수도, 깨진 조각일 수도 있다. 칸은 `{ generation, slot }` 이고, 사실은 끝 K 줄(K = 2)과 가장 최근 Turn 행 둘이다.

- 쓰는 쪽의 칸 읽기, 회전, 파일 쓰기, 칸 맞추기, 실패, 취소는 따로 떨어진 걸음이다. 쓰기는 규칙 11 대로 움직인다. 끝이 끊긴 파일에는 줄바꿈부터 쓴다. 실패하면 파일을 그대로 두거나 끊긴 조각만 남긴다.
- 채우는 쪽의 칸 읽기, 파일 목록 얻기, 파일을 하나씩 열어 읽기, compare-and-set 도 따로 떨어진 걸음이다. 목록을 얻은 뒤 회전이 끼면 옛 이름으로 연다. 읽기는 실패할 수 있다. 실패한 읽기는 빈 파일을 읽은 것처럼 보인다. 채우는 쪽은 실패를 알고 넣지 않는다.
- 지우는 쪽은 오래된 파일부터 몇 개를 지우거나 모두 지운다. 도중에 실패해 멈출 수 있다.

칸은 저장소 하나에만 걸리므로 모델은 저장소 하나로 충분하다. 여러 저장소를 지우는 일은 저장소마다 지우고 비우는 일을 잇달아 하는 것이다. 불변식은 "파일을 바꾸는 중인 쪽이 없고 칸이 `Filled` 면, 값은 파일에서 계산한 값과 같다"이다. `Next` 는 §2 의 규칙대로 움직이고 불변식을 지킨다. `BugAction` 후보는 열둘이다.

- (a) 채우는 쪽이 compare-and-set 없이 그냥 넣는다.
- (b) 쓰는 쪽이 `Unfilled` 에 자기 행을 넣는다.
- (c) 쓰는 쪽이 파일을 바꾼 뒤에 칸을 읽고, compare-and-set 이 실패하면 다시 읽어 행을 더한다.
- (d) 지우는 쪽이 파일을 지운 뒤 칸을 비우지 않는다.
- (e) 지우는 쪽이 도중에 실패하면 칸을 비우지 않는다.
- (f) 실패하거나 취소된 쓰기가 칸을 비우지 않는다.
- (g) 값을 바꾸지 않는 쓰기가 `Unfilled` 칸의 세대를 올리지 않는다.
- (h) 쓰는 쪽이 끊긴 줄 뒤에 줄바꿈 없이 이어 쓴다. 지금 동작이다(#52974).
- (i) 실패한 쓰기의 바이트가 다음 쓰기 앞에 붙거나, 쓰는 쪽 없이 파일에 들어간다. 지금 동작이다(#52980).
- (j) 목록 칸이 깨진 줄을 빼고 든다.
- (k) 쓰는 쪽이 compare-and-set 에 실패한 뒤 칸을 비우지 않고 자기가 만든 값을 넣는다.
- (l) 채우는 쪽이 실패한 읽기를 빈 값으로 넣는다.

`NextBuggy == Next \/ BugAction` 은 후보마다 불변식을 어겨야 한다. 버그 cfg 가 통과하는 후보가 있으면 모델이 그 경우를 그리지 못한 것이다. 후보를 빼지 않고 모델을 고친다. 후보마다 어기는 사실이 다르다. (b)는 끝 K 줄에서만 어기고, (g)는 가장 최근 Turn 행에서만 어긴다. 버그 cfg 는 후보마다 두 사실의 불변식을 모두 확인한다. 정상 cfg 와 버그 cfg 를 둘 다 돌린다. 풀 용량 때문에 멈추는 일(§6.6)은 안전 불변식으로 잡히지 않는다. 그래서 "잠금을 쥔 채 채우는 시험"이 대신 지킨다. 시계가 뒤로 간 쓰기는 모델에 넣지 않고 `step` 단위 시험으로 본다.

**운영 측정.** 재시작 뒤 34분 창에서 센다. 창 안의 TurnRecord 쓰기 수를 같이 적어 Keeper 활동량이 비슷한 창끼리 비교한다.

| 무엇 | 지금 | 목표 |
|---|---|---|
| 느린 행 로그의 sub-op 중앙값 trust·audit·meta | 186·164·23 ms | L1~L3 뒤 0 ms 근처 |
| 300 ms 넘는 Keeper 행 | 867 | 준다. 승인 audit·quarantine·candle 이 남아 0 을 목표로 두지 않는다 |
| Keeper 화면 TUI 요청의 1초 넘음 | `/keepers/turns` 15, `/gate/keepers` 3, `/dashboard/health-line` 1 | 관찰만 한다. 이 요청들은 다른 원인도 있어 이 RFC 의 결과로 세지 않는다 |
| 채우기 시도 수와 들어간 수 | 없다 | L2·L3 에서 센다. 들어간 비율을 PR 에 적는다 |

세마포어 대기의 p90(4.5 s)은 wait 나 work 가 500 ms 를 넘긴 행만 센 값이다. 같은 기준으로만 비교한다.

**증거.** 헌법 `<evidence>` 대로 층마다 PR 에 로그(바뀌기 전후 느린 행 sub-op), 측정, Keeper 화면(TUI 와 대시보드) 캡처를 붙인다.

## 6. 고르지 않은 길

1. **TTL 을 늘린다.** Current 는 10초 안의 커밋도 봐야 한다. TTL 은 그 커밋을 숨긴다.
2. **루프 셋을 하나로 합친다.** 일은 1/3 로 줄지만 행 하나가 여전히 파일을 읽는다. health-line·gate/keepers 요청 경로는 그대로다.
3. **보는 사람이 있을 때만 루프를 돌린다.** 볼 때 비용이 그대로 돌아오고, 요청이 루프를 기다린다.
4. **읽는 쪽 증분 캐시를 더 만든다.** 읽을 때마다 목록과 stat 이 남는다. 서버 밖에서 쓰는 파일에는 맞는 모양이다. 여기 저장소들은 쓰는 곳이 모두 서버 안이다.
5. **SQLite 로 옮긴다.** 저장소 모양을 바꾸는 하드컷이다. 읽기는 여전히 부른 fiber 를 막는다.
6. **저장소 잠금 안에서 채운다.** 이 RFC 의 지난 안이다. 두 가지로 깨진다.
   - 끝 읽기는 풀 밖에서 부르면 풀에 IO 작업을 내고 기다린다(`dated_jsonl.ml:582`, `domain_pool_ref.ml:45-51`). MCP `masc_operator_snapshot` 처럼 풀 밖에서 행을 만드는 쪽이 도구 호출 원장의 잠금을 쥐고 그 작업을 기다리는데, 같은 잠금을 기다리는 행 계산(weight 1.0)이 풀을 다 차지하면 아무도 진행하지 못한다. 그동안 모든 Keeper 의 도구 호출 기록도 멈춘다.
   - 결정 기록의 잠금은 system thread 안에서만 쓰는 OS mutex 다(`fs_compat_base_io.ml:274-279`). fiber 가 그 mutex 를 쥔 채 멈추면 같은 domain 의 다음 사용자가 `Mutex.lock` 에서 실패한다(#52360).
7. **세대 번호를 쓴 뒤에 읽는다.** 쓰는 쪽이 파일을 바꾼 뒤에 칸을 읽으면, 그 사이 채우는 쪽이 넣은 값(쓴 행이 이미 들어 있는 값)에 같은 행을 또 더한다. 이 RFC 는 쓰기 전에 읽는다.
8. **칸이 파일 끝 상태를 든다.** 이 RFC 의 지난 개정이다. 값을 계산할 때 파일 끝이 줄 중간이었는지를 칸에 같이 두고, 그때는 쓰는 쪽이 칸을 비운다. 끊긴 줄 뒤에 이어 쓰는 동작(#52974)을 칸이 대신 견디는 모양이다. 두 곳에서 틀린다.
   - 값을 바꾸지 않는 쓰기가 칸을 건드리지 않으면, 줄바꿈만 빠진 온전한 마지막 행 뒤에 그 쓰기가 붙어 값이 바뀐다.
   - 빈 칸에는 파일 끝 상태가 없다. 끊긴 줄을 읽고 있던 채우기가 그 쓰기 뒤에 값을 넣는다.

   실패한 쓰기의 바이트가 나중에 들어오는 문제(#52980)는 칸으로 견딜 수 없어서 쓰는 함수를 어차피 고친다. 같은 수리가 쓰기를 줄 처음에서 시작하게 한다. 그러면 칸은 파일 끝 상태를 들 까닭이 없다.

## 7. 대가와 한계

- 메모리: Keeper 마다 결정 기록 1행, receipt 1행, TurnRecord 1행, metrics 121행이고, workspace 마다 도구 호출 16행이다. 행 크기는 재지 않았다. L3 에서 Keeper 하나의 metrics 값 크기(`Obj.reachable_words`)를 재서 PR 에 적는다.
- 쓰는 쪽이 조금 길어진다. 그 저장소의 칸마다 칸 읽기 한 번과 compare-and-set 한 번이 늘어난다. 잠금 안에서 늘어나는 일은 이 `Atomic` 연산과 새 값 계산뿐이다. 파일 일이나 기다림은 늘지 않는다.
- 쓰는 쪽은 쓴 줄을 읽는 쪽 parser 로 한 번 해석한다. 줄 크기에 비례하는 일이다. L2 에서 도구 호출 줄의 크기와 해석 시간을 재서 PR 에 적는다.
- 파일을 바꾸는 중에는 칸이 파일과 잠깐 다를 수 있다. 줄은 썼고 칸은 아직 안 맞춘 사이가 그렇다. 결정 기록을 두 곳이 같이 쓰면, 먼저 쓴 쪽이 칸을 먼저 맞춰 칸이 앞 행을 잠깐 보일 수 있다. 늦게 온 쪽이 칸을 비운다. 불변식은 바꾸는 쪽이 없을 때만 말한다.
- 쓰기가 실패하면 그 저장소의 칸이 모두 비워지고, 다음 읽기가 파일을 읽는다.
- 쓰기와 채우기가 겹치면 그 채우기는 들어가지 않고, 다음 읽기가 파일을 읽는다. 재시작 직후 첫 읽기도 파일을 읽는다. 같은 칸을 여러 행이 동시에 채우면 파일 읽기가 겹친다.
- 쓰기가 잦은 저장소에서는 채우기가 compare-and-set 에서 여러 번 질 수 있다. 진 채우기도 그 행에는 맞는 값을 쓴다. 다만 다음 행이 파일을 다시 읽는다. L2·L3 운영 측정에서 채우기 시도 수와 들어간 수를 센다(§5).
- 24시간 prune 이 돌면 지운 것이 없어도 그 저장소의 칸이 비워진다. 칸마다 하루에 한 번 파일을 다시 읽는다.
- W 는 이 RFC 밖의 쓰기 동작을 바꾼다. 지금은 실패한 쓰기가 남긴 바이트가 다음 쓰기 때 끊긴 줄을 채워 주기도 한다(#52980). W 뒤에는 실패한 쓰기를 되돌린다. 되돌리지 못하는 때가 둘 있다. 자르기가 실패했거나, 그 사이 다른 쪽이 파일을 바꿨다. 그때는 바이트가 끊긴 조각으로 남고 오류가 그렇게 말한다. `docs/JSONL-CONTRACT-INVENTORY.md` 의 약속도 그렇게 바뀐다.
- W 뒤에는 일반 파일을 읽기·쓰기로 연다. 쓸 수만 있고 읽을 수 없는 파일에는 덧붙이지 못한다. FIFO 같은 대상은 전처럼 쓰기 전용으로 열고 그대로 쓴다.
- W 뒤에는 줄을 쓸 때마다 파일의 마지막 바이트를 읽는다. 호출 셋(`lseek` 둘, `read` 하나)이 늘어난다. macOS 에서 200바이트 줄 10만 번을 21회 쟀다(load average 30). 최솟값으로 보면 쓰기 하나가 3.7~4.1 µs 에서 5.0~5.7 µs 가 된다. 파일 끝을 메모리에 기억하면 이 비용이 없다. 다만 다른 descriptor 가 파일을 같은 크기로 다시 쓰면 기억이 틀린다. 그래서 고르지 않았다.
- 서버가 도는 동안 이 저장소를 손으로 지우면, 메모리 값은 재시작까지 옛 행을 보인다. 헌법 `runtime_data` 의 "지우고 새로 한다"는 멈추고 지우고 다시 띄우는 것이고, 이 RFC 는 그 순서를 그대로 지원한다. 서버가 돌 때는 대시보드 purge 로 지운다. purge 는 칸을 비운다.
- 다른 코드가 이 저장소를 열어 바로 쓸 수 있다. `Dated_jsonl.open_store`·`append` 와 `Store.keeper` 는 공개다(`dated_jsonl.mli:72`, `:99`, `dated_jsonl_store.mli:76`). 그러면 메모리 값이 틀린다. 차분 시험은 이름 붙인 쓰는 함수만 부른다. §8.4 가 이 구멍을 다룬다.
- 칸은 지우지 않는다. 한 번 만든 묶음은 process 가 끝날 때까지 남는다. 수의 상한은 그동안 연 저장소 수다. Keeper 하나에 넷(결정 기록, receipt, TurnRecord, metrics), workspace 하나에 하나다. purge 한 Keeper 의 칸은 `Unfilled` 로 남는다.
- reader 가 읽을 때마다 남기던 보고가 준다. 깨진 줄이나 읽기 오류를 세는 곳은 지금 행을 만들 때마다 같은 줄을 다시 센다. 칸에서 읽으면 채울 때만 센다. L2 에서 그 수를 쓰는 화면과 알림을 찾아 PR 에 적는다.
- meta 의 설정 필드는 지금처럼 자리 채움 값으로 보인다(§3.1, #53007). 이 RFC 는 그 값을 고치지 않는다.
- 이 RFC 는 이 값들 밖의 읽기를 줄이지 않는다.

## 8. 정할 것

1. **승인 audit 와 quarantine 원장을 이 스택에 넣을지.** 권장: L2·L3 뒤에 잰 뒤 정한다. 승인 audit 에는 이미 증분 색인(RFC-0474 L4f)이 있어서 남은 비용이 목록 읽기뿐일 수 있다.
2. **Keeper 행을 SSE 로 나르는 일.** RFC-0477 §3.6 의 행 topic 은 `/gate/keepers?detailed=true`, 곧 `masc_keeper_list` 다. 이 RFC 는 L1·L2 에서 `masc_keeper_list` 도 같은 값(meta, 최근 receipt)을 읽게 한다. 권장: 이 RFC 는 값을 만들고, RFC-0477 이 나른다.
3. **이름 목록.** `keepers_json` 은 이름을 meta 파일 목록에서 얻는다. 권장: L1 에서는 그대로 두고 meta 값만 Owner 에서 읽는다. 이름 목록을 Owner registry 로 옮기는 일은 L4 뒤에 잰다.
4. **쓰기 권한을 타입으로 나눌지.** 지금은 아무 코드나 이 저장소에 쓸 수 있다. 권장: 저장소마다 그 층이 들어갈 때, 읽는 쪽에는 읽기 전용 handle 만 주고 쓰기 handle 은 쓰는 모듈만 갖게 한다. 대가: metrics 를 읽는 곳(`server_dashboard_http_keeper_api.ml:72`, `dashboard_http_keeper_feeds.ml:194`, `keeper_status_detail.ml:460`, `bin/masc_tui_metrics_tail.ml:170-173`)과 receipt·TurnRecord 를 읽는 곳을 고친다. 하지 않으면 "쓰는 곳이 하나"라는 전제를 리뷰로만 지킨다.
5. **서버가 돌 때 손으로 지우는 일.** 권장: §7 대로 받아들이고 운영 문서에 적는다. 막는 장치는 더하지 않는다.
6. **행의 설정 필드를 TOML 값으로 보일지(#53007).** 권장: 이 RFC 에서는 값을 그대로 둔다. 보이는 값이 바뀌는 수리라 따로 근거를 붙여 고친다. 그때는 §3.1 의 변환 자리에서 TOML 값을 덮어쓰면 된다(`effective_meta_of_profile_defaults`). 대가: 그때까지 `activation_mode` 는 틀린 값을 계속 보인다.
