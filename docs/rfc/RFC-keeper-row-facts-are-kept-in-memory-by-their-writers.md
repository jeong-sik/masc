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

주기 루프 셋이 Keeper 31개의 행을 따로 다시 만든다. 행 하나마다 meta 파일과 Keeper 기록 다섯 묶음의 끝을 다시 읽고, 날짜 파일을 목록으로 훑고 stat 한다. 2026-11-17 22:22~22:56(34분)에 300 ms 를 넘긴 Keeper 행이 867개 쌓였다. 근거는 연구 노트(#52888)에 있다.

이 RFC 는 규칙 하나를 세운다.

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 그 사실 때문에 파일을 열지 않는다.

결정은 여섯 가지다.

1. 메모리에 두는 값은 행이 실제로 쓰는 값만이다(§1.1). 결정 기록의 마지막 행, 도구 호출 원장의 마지막 16줄, 가장 새 온전한 execution receipt, 최근 TurnRecord, metrics 끝 120행과 가장 최근 Turn tool audit 행이다. meta 는 Owner 가 이미 메모리에 든 값에서 얻는다. 파일에 쓰는 필드만 쓴다(§3.1).
2. 값마다 세대 번호를 붙인다. 파일을 바꾸는 쪽은 바꾼 뒤 그 저장소의 값마다 세대를 올린다. 쓰는 쪽은 파일을 바꾸기 전에 본 값에서 새 값을 만든다. 그 사이 다른 쪽이 값을 바꿨거나, 새 값을 읽는 쪽과 똑같이 만들 수 없으면 값을 비운다(§3.3).
3. 빈 값은 읽는 쪽이 파일로 채운다. 채울 때는 어떤 잠금도 잡지 않는다. 읽기 전에 본 값이 그대로일 때만 compare-and-set 으로 넣는다. 읽기가 실패하면 넣지 않는다(§3.4). 그래서 저장소 잠금을 쥔 채 풀 작업을 기다리는 일이 없다.
4. 메모리 값은 디스크에 저장하지 않는 파생 값이다. 값은 읽는 쪽이 파일에서 보는 줄을 그 자리 그대로 든다. 차분 시험과 TLA+ 로 "파일을 바꾸는 중인 쪽이 없으면 메모리 값은 파일에서 다시 계산한 값과 같다"를 지킨다(§5).
5. 칸은 쓰는 함수의 두 약속에 기댄다. 실패한 쓰기는 나중에 파일에 닿지 않는다. 쓰기는 줄 처음에서 시작한다. 둘 다 #52991 이 세웠다(§1.4, 규칙 11). 그 리뷰의 후속은 #53017 이다.
6. 다 옮기면 이 값들을 읽는 행 helper 의 Current/Reuse 구분과 그 helper 몫의 캐시를 지운다. 같은 캐시를 쓰는 다른 화면을 먼저 옮긴다. Keeper 세마포어는 남은 행 일을 잰 뒤 정한다(§4 L4).

보이는 동작은 바꾸지 않는다. 행이 보여 주는 값은 지금 파일에서 읽는 값과 같다. meta 의 설정 필드도 소비자마다 지금 값 그대로다(§3.1). `keepers_json` 의 그 값이 TOML 과 다른 문제는 따로 적었다(§1.1, #53007). 값이 지금과 달라지는 때는 §7 에 적었다.

- 서버가 도는 동안 밖에서 파일을 고치거나 지웠다.
- 파일 읽기가 실패하고 있다. 지금 행은 못 읽었다고 하거나 빈 값을 낸다. 옮긴 뒤에는 메모리 값을 보인다.
- 저장소에 점으로 시작하는 `.jsonl` 파일이 있다. 지금 reader 몇은 그 파일도 읽는다. 칸은 읽지 않는다(§3.4).

고치지 않는 것: `Systhread_host` 와 풀(다른 RFC), `schedules.json` 쓰기, 서버 밖에서도 고치는 profile TOML, 승인 audit 와 quarantine 원장(§8.1), Keeper 행을 SSE 로 나르는 일(RFC-0477), serving domain.

## 1. 지금 상태 (origin/main `e5ac5ffae90b1`)

줄 번호는 위 커밋의 것이다. 줄 쓰기 함수(`lib/fs_compat` 의 붙여 쓰기, `keeper_types_support.ml` 의 줄 쓰기)만 #52991 이 들어간 `06c0213bf4234` 의 것이다.

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

- decoder 는 설정 필드 열넷을 읽지 않고 자리 채움 값을 둔다(`keeper_meta_json_parse.ml:258-292`. `:240` 의 주석은 열하나라고 적었다). `sandbox_profile` 은 `Docker`, `network_mode` 는 `Network_inherit`, `activation_mode` 는 `Autonomous` 다. `id` 와 `usage.last_usage_reported_at` 도 읽지 않고 `None` 을 둔다(`keeper_meta_json_parse.ml:220`). encoder 도 그 필드들을 쓰지 않는다(`keeper_meta_json.ml:10-68`).
- Owner 의 메모리 값에는 TOML 값이 들어 있다. `Update_profile` 이 넣는다(`keeper_owner_reducer.ml:404-425`).
- `keepers_json` 의 행은 자리 채움 값을 그대로 내보낸다. `activation_mode` 가 그렇다(`operator_control_snapshot.ml:412`). receipt 가 없는 Keeper 의 trust 는 sandbox 종류와 network mode 를 meta 에서 가져온다(`keeper_runtime_trust_snapshot.ml:504-516`). 이 값이 TOML 과 다른 것은 #53007 에 적었다.
- `masc_keeper_list` 와 board address 는 다르다. 파일을 읽은 뒤 profile 을 덮는다(`keeper_tool_surface_ops.ml:343-348`, `keeper_board_address.ml:26-33`). 그래서 TOML 값을 보인다. 덮기는 TOML 이 적지 않은 key 에는 받은 값을 남긴다(`keeper_meta_contract.ml:287-291`). 지금 받는 값은 자리 채움 값이다.

최근 receipt 를 읽는 함수는 둘이다. 둘 다 가장 새 온전한 줄을 준다. `latest_json` 은 `read_recent store 1` 이고, 그 함수는 JSON 으로 읽힌 줄만 센다(`keeper_execution_receipt.ml:584-589`, `dated_jsonl.ml:949-953`). `read_latest_receipt` 는 깨진 줄을 건너뛰며 끝에서부터 훑는다(`keeper_execution_receipt.ml:769-779`). 그래서 마지막 줄이 끊겨 있어도 둘 다 그 앞의 receipt 를 준다. 둘이 갈리는 곳은 셋이다. 목록을 못 읽으면 앞의 것은 '없음'을, 뒤의 것은 오류를 낸다. 있는 날짜 파일을 열지 못하면 앞의 것은 `Sys_error` 를 던지고(`load_tail_rows_inline`), 뒤의 것은 오류를 낸다. 점으로 시작하는 `.jsonl` 은 앞의 것만 읽는다(§3.4). trust 와 `masc_keeper_list` 는 앞의 것을 쓰고 blocker 는 뒤의 것을 쓴다(`keeper_runtime_trust_snapshot.ml:388-389`, `keeper_tool_surface_ops.ml:470`, `keeper_status_bridge.ml:126`).

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

Current 는 10초 trust 캐시(`operator_control_snapshot_trust.ml:5`)를 일부러 건너뛴다. 10초 안에 들어온 커밋도 봐야 해서다. tool audit 읽기에는 캐시가 없다. 루프와 요청은 16칸 세마포어 하나를 나눠 쓴다(`operator_control_snapshot.ml:41`).

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
| 결정 기록 | `Keeper_types_support.append_decision_record`(`keeper_types_support.ml:292-295`). 크기가 차면 `.1` 로 돌린다(`:250-283`). 쓰는 줄은 `utf8_repair_string` 을 거친다(`:285-288`) | 4곳. 넘기는 JSON 모양이 저마다 다르다 | 돌리기는 잠금이 없다. 쓰기는 system thread 안에서 경로마다 둔 OS mutex(`Stdlib.Mutex`)를 잡는다(`fs_compat_base_io.ml:274-283`, `:315-341`). system thread 가 끝나면 fiber 가 취소됐는지 본다(`:393-397`) |
| 도구 호출 원장 | `Keeper_tool_call_log.log_call` → `Dated_jsonl.append_rotating`(`keeper_tool_call_log.ml:639-645`). commit 이 필요 없는 행은 비동기 큐로 가고, 큐가 차면 버린다(`:761-805`) | 6곳 | workspace 에 저장소 하나다(`:473-474`). 모든 Keeper 가 같은 잠금을 쓴다. `max_bytes` 가 없어 append 뒤 prune 이 돌지 않는다(`:486`) |
| execution receipt | `Keeper_execution_receipt.append` → `Dated_jsonl.append`(`keeper_execution_receipt.ml:554`) | 2곳 | 저장소 잠금(`dated_jsonl.ml:884`). `open_store` 는 같은 디렉터리에 같은 mutex 를 준다(`:156-171`) |
| TurnRecord | `Keeper_turn_record_writer.write` → `Dated_jsonl.append`(`keeper_turn_record_writer.ml:71`) | 1곳 | 같다 |
| metrics | `Keeper_types_support.append_keeper_metrics`(`keeper_types_support.ml:48`) | 2곳 | 같다 |
| meta | Owner 커밋이 메모리의 meta 를 통째로 쓴다(`keeper_meta_store.ml:726-729`) | Owner 하나 | Owner |

`Dated_jsonl` 은 저장소 잠금 안에서 [줄 쓰기 → `on_committed` → append 뒤 prune] 순서로 돈다(`dated_jsonl.ml:884-888`, `:1787-1789`). 도구 호출 원장의 `on_committed` 는 화면을 깨우는 알림(`notify_written`)을 보낸다(`keeper_tool_call_log.ml:640-644`).

줄 쓰기는 모두 `append_file_unix_with_io` 하나로 간다(`fs_compat_base_io.ml:315-341`). 결정 기록과 `Dated_jsonl` 저장소가 그렇고, 이 RFC 밖의 저장소도 그렇다. task metrics, activity graph, workspace memory log, cost 기록이 같은 함수를 쓴다. 이 함수는 두 가지를 지킨다(#52991, `lib/fs_compat/fd_append_whole.mli`).

- 실패한 쓰기는 호출이 끝난 뒤 파일에 닿지 않는다. 캐시는 버퍼 없는 descriptor 를 든다. 쓰다가 실패하면 이미 넣은 바이트를 잘라 낸다. 파일 길이가 '쓰기 전 길이 + 쓴 바이트'일 때만 자른다. 아니면 그대로 두고 오류가 그렇게 말한다.
- 줄은 줄 처음에서 시작한다. 쓰기 전에 파일의 마지막 바이트를 읽는다. 줄 중간이면 줄바꿈부터 쓴다. 끊긴 조각은 따로 한 줄로 남는다.

끊긴 끝을 다루는 약속이 이미 하나 있다. durable private JSONL 계열(`append_private_jsonl_durable_*`)이다. 이 계열은 마지막 줄바꿈 뒤 바이트를 행으로 보지 않는다. 그래서 쓰는 쪽이 그 바이트를 잘라 낸다(`fs_compat_private_jsonl_write.ml:260-284`, #37117, #52943). 이 RFC 의 저장소는 그 계열이 아니다. 여기 reader 는 줄바꿈 없는 마지막 줄도 읽는다(`dated_jsonl.ml:334`, `:1392`). 결정 기록은 그 줄이 object 로 읽히면 행으로 쓴다(`keeper_runtime_trust_snapshot.ml:352-361`). 잘라 내면 화면이 이미 보인 행이 사라질 수 있다. 그래서 줄 쓰기는 끊긴 조각을 자르지 않는다. 한 줄로 따로 두고 그 뒤에 쓴다.

지우는 곳:

- 날짜 파일 prune: 기동 때(`server_runtime_startup_maintenance.ml:73`)와 24시간마다(`server_bootstrap_maintenance.ml:936-947`). `on_pruned` 는 저장소 잠금을 푼 뒤, 하나라도 지웠을 때만 돈다(`dated_jsonl.ml:2175-2179`). prune 이 도중에 예외로 끝나면 돌지 않는다.
- append 뒤 바이트 prune: `on_committed` 다음에 같은 잠금 안에서 돈다. metrics 저장소에는 `max_bytes` 가 있다(`keeper_metrics_storage.ml:6-11`). 설정 `metrics.store_max_bytes` 의 기본값은 0 이라 지금은 돌지 않는다.
- 대시보드 purge(`server_dashboard_http_delete_actions.ml:672`, `:805`)와 runtime 디렉터리 지우기(`:865-870`). 뒤의 것은 receipt, TurnRecord, metrics 를 지운다(`:350-355`). 둘 다 저장소 잠금을 잡지 않는다. purge 는 지우기 전에 쓰는 descriptor 를 닫는다. Keeper root 의 로그 파일은 파일마다 닫고(`server_dashboard_http_delete_actions.ml:698-707`), metrics 저장소는 writer 와 캐시를 같이 닫는다(`:802-810`, `dated_jsonl.ml:1544-1550`). runtime 디렉터리 지우기는 닫지 않고, 지운 뒤 디렉터리 캐시만 비운다(`:868-870`). 지워진 경로는 다음 쓰기가 다시 연다(`lib/fs_compat/fd_cache.mli`).

저장소 디렉터리에 날짜 파일이 아닌 것이 있는 곳이 하나 있다. 도구 호출 원장 디렉터리에는 읽기 색인이 같이 있다. 이름은 `read-index.sqlite3` 와, SQLite 가 곁에 만드는 `-wal`·`-shm`·`-journal` 이다(`lib/core/common.ml:280-287`, `keeper_tool_call_index.ml:15-16`). 색인은 색인을 읽는 함수가 만든다(`keeper_tool_call_log.ml:1412-1430`). 운영 디렉터리에도 이 파일들이 있다(2026-11-18 에 이름 목록으로 확인). `Dated_jsonl` 의 두 목록 읽기는 이 이름을 다르게 다룬다. 기간 읽기는 낯선 이름을 건너뛴다(`dated_jsonl.ml:1426-1483`). 끝 읽기의 달 목록은 점으로 시작하지 않는 낯선 이름에서 `Error` 를 낸다(`:252-262`, `dated_jsonl_layout.ml:143-155`).

서버 밖에서 이 RFC 의 저장소에 쓰는 곳은 없다. `masc-stdio` 와 HTTP 런타임은 base path lease 를 같이 잡는다(`main_stdio_eio.ml:54`, `main_eio.ml:273`). `seed_telemetry_store.py` 는 자기 `--root` 에만 쓴다. 다만 `scripts/migrate-keeper-meta-sandbox.sh` 는 meta 파일을 고친다. 스크립트 머리에는 서버를 멈추라는 말이 없다. 서버가 돌 때 고치면 Owner 의 다음 커밋이 메모리 값으로 파일을 덮는다. 지금도 그렇다.

이 RFC 밖의 저장소는 사정이 다르다. cost 기록은 서버와 CLI 가 같은 파일에 덧붙인다(`keeper_hooks_agent_core_cost_events.ml:447-451`, `bin/masc_cost.ml:63-70`). 둘은 다른 process 다. 그래서 줄 쓰기는 길이가 맞을 때만 자른다. 다른 process 와 남는 틈은 §4 에 적었다.

### 1.5 측정

연구 노트 1절·6절의 숫자다. 서버 로그는 Keeper 하나의 일이 300 ms 를 넘을 때만 sub-op 를 남기고, 세마포어 대기나 일이 500 ms 를 넘을 때만 wait 를 남긴다.

- 22:22~22:56: 300 ms 넘는 Keeper 행 867개, 35번 몰림, 몰림 하나에 중앙값 25행.
- 느린 행의 sub-op 중앙값: trust 186 ms, audit 164 ms, meta 23 ms.
- 세마포어 대기: wait 나 work 가 500 ms 를 넘긴 547행에서 중앙값 593 ms, p90 4.5 s.
- 같은 창의 TUI 1초 넘는 요청: `/keepers/turns` 15번(1,011~3,081 ms), `/gate/keepers` 3번, `/dashboard/health-line` 1번.

## 2. 규칙에서 나오는 것

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 그 사실 때문에 파일을 열지 않는다.

1. 값 하나는 (저장소, 사실) 하나다. 칸은 저장소의 정체로 찾는다. 표기가 다른 두 경로가 같은 저장소에 칸을 둘 만들면 안 된다. 한쪽으로 쓴 줄이 다른 쪽 칸의 세대를 올리지 않아서, 그 칸이 옛 값으로 남는다. 그래서 저장소의 정체는 적은 글자가 아니라 file system 이 그 디렉터리를 부르는 이름으로 정한다(§3.2).
   - `Dated_jsonl` 은 디렉터리마다 mutex 하나를 주는 등록부를 이미 둔다(`dated_jsonl.ml:136-154`). 그 저장소의 칸을 같은 항목에 둔다. 그래서 같은 잠금을 쓰는 쪽은 같은 칸을 본다.
   - 결정 기록은 파일 하나라 그 등록부가 없다. 그 칸은 (root, Keeper 이름)으로 찾는다. 쓰는 4곳과 읽는 쪽이 모두 `(config, name)` 을 든다.
2. 칸 하나는 `{ generation; slot }` 을 담은 `Atomic` 하나다. `slot` 은 `Unfilled` 거나 값을 든 `Filled` 다. 칸을 바꿀 때는 늘 새 record 를 만들고 세대를 올린다.
3. 불변식: 파일을 바꾸는 중인 쪽이 없으면, `Filled` 의 값은 파일 내용에서 그 칸의 읽기(§3.4)대로 계산한 값과 같다. 읽기가 실패하는 동안에도 불변식은 파일 내용을 두고 말한다. 다만 그동안에는 시험이 확인할 길이 없다. `Unfilled` 는 아무것도 주장하지 않는다.
4. 파일을 바꾸는 쪽은 모두 파일을 바꾼 뒤에 그 저장소의 칸을 맞춘다. 쓰기와 그 안의 회전, prune, purge, 디렉터리 지우기가 그렇다.
   - 쓰기는 파일을 바꾸기 전에 그 저장소의 칸을 모두 읽어 둔다. 쓴 뒤 칸마다 읽어 둔 값에서 새 값을 만든다. 칸이 그대로면 compare-and-set 으로 넣는다. 칸이 바뀌었으면 칸을 비운다.
   - 쓰기가 새 값을 읽는 쪽과 똑같이 만들 수 없으면 칸을 비운다(§3.3).
   - 쓴 행이 어떤 칸의 값을 바꾸지 않아도 그 칸을 건너뛰지 않는다. 같은 값으로 세대를 올린다. `Unfilled` 도 세대를 올린다. 그 쓰기와 겹친 채우기가 쓰기 전의 파일로 계산한 값을 넣지 못하게 하려는 것이다.
   - 지우는 쪽은 끝나는 모든 경로에서 그 저장소의 칸을 모두 비운다. 몇 개를 지웠는지, 성공했는지 보지 않는다.
5. 쓰는 쪽은 `Unfilled` 를 채우지 않는다. 쓰는 쪽은 자기 행만 알아서 목록 전체를 만들 수 없다.
6. 쓰기가 실패하거나, 됐는지 모르거나, 칸을 고치기 전에 취소되면 그 저장소의 칸을 모두 비운다. 쓰지 않은 것이 확실하면(큐가 차서 버림, append guard 가 건너뜀, 크기 회전이 쓸 번호를 찾지 못해 `Skipped_rotation_exhausted` 를 돌려줌) 칸을 그대로 둔다. 파일이 그대로라서다.
7. 채우는 쪽은 잠금을 잡지 않는다. 파일을 읽기 바로 전에 칸을 읽고, 파일에서 값을 계산하고, 칸이 그대로일 때만 compare-and-set 으로 넣는다. 읽기가 실패하면 넣지 않는다. 실패를 빈 값으로 바꾸는 reader 로는 채우지 않는다.
8. 이 RFC 가 더하는 코드는 저장소 잠금 안에서 기다리지 않는다. 잠금 안에서 더하는 일은 `Atomic` 연산과 새 값 계산뿐이다. `Dated_jsonl` 은 지금도 저장소 잠금을 쥔 채 system thread 의 쓰기를 기다린다(`dated_jsonl.ml:884-886`). 그 동작은 그대로다.
9. 메모리 값은 디스크에 저장하지 않는다. 권위는 파일이다.
10. 서버 밖에서도 고치는 파일(profile TOML)은 이 규칙에 넣지 않는다. 지금처럼 내용 키 캐시로 읽는다.
11. 쓰는 함수의 전제가 둘 있다. 성공한 쓰기는 줄 처음에서 시작해 넘긴 줄을 통째로 더한다. 실패한 쓰기는 호출이 끝난 뒤 파일에 닿지 않는다. 줄 쓰기 함수가 둘 다 지킨다(§1.4). 실패한 쓰기가 이미 넣은 바이트는 그 함수가 되돌린다. 되돌리지 못하면 줄바꿈 없는 조각으로 남는다. 다음 쓰기는 그 조각 뒤에 붙지 않는다.

규칙 4·7 이 불변식을 지키는 까닭은 이렇다. 채우는 쪽이 넣은 값은 그 뒤에 끝나는 변경이 늘 덮는다. 변경은 파일을 바꾼 뒤 칸을 바꾸기 때문이다. 채우는 쪽이 칸을 읽은 뒤 끝난 변경이 있으면 칸이 이미 바뀌어서 채우는 쪽의 compare-and-set 이 실패한다. 값을 바꾸지 않는 쓰기도 세대를 올리므로 예외가 없다. 쓰는 쪽은 파일을 바꾸기 전에 칸을 읽어 둔다. 그 사이 채우는 쪽이 넣은 값에는 쓴 행이 이미 들어 있을 수 있다. 쓰는 쪽은 읽어 둔 칸에서 새 값을 만들므로 그 행을 한 번 더 더하지 않는다. 이 논리는 규칙 11 에 기댄다. 쓴 뒤의 파일은 읽어 둔 값의 파일에 쓴 줄 하나를 더한 것이어야 한다. 끊긴 줄 뒤에 붙은 줄이나 뒤늦게 들어온 바이트는 이 전제를 깬다. 실패한 쓰기가 남긴 조각은 이 전제를 깨지 않는다. 그 쓰기는 칸을 비우고(규칙 6), 조각은 다음 채우기가 깨진 줄 하나로 읽는다.

## 3. 설계

### 3.1 meta 는 Owner 를 읽는다

`keepers_json`, board address, `masc_keeper_list`, 그리고 snapshot 이 계속 떠 있어야 하는 Keeper 를 고르는 훑기는 meta 파일을 열기 전에 `Keeper_owner_projection.lookup` 을 본다. 이 함수는 잠금 없이 `Atomic` map 을 읽는다(`keeper_owner_projection.ml:31-36`). 그래서 system thread 에서 도는 board address 에서도 부를 수 있다. Owner 는 커밋할 때 메모리의 meta 를 파일에 통째로 쓰고, 쓰기가 성공했을 때만 메모리 값을 바꾼다(`keeper_owner.ml:936-957`). 새로 저장하는 상태는 없다.

네 소비자는 Owner 값을 그대로 쓰지 않는다. Owner 값의 설정 필드에는 TOML 값이 있고, 파일을 읽은 값에는 자리 채움 값이 있다(§1.1). 그대로 쓰면 `keepers_json` 의 `activation_mode` 와 trust 의 sandbox 값이 지금과 달라진다. profile 을 덮는 두 소비자도 달라진다. TOML 에서 key 를 뺀 뒤에는 덮기가 받은 값을 남긴다(§1.1). 그 값이 자리 채움 값이 아니라 Owner 가 든 옛 TOML 값이 된다.

네 소비자는 파일 읽기 한 걸음만 바꾼다. Owner 값을 파일과 같은 길로 한 번 돌린 값을 그 자리에 넣는다. 파일에 쓰는 encoder(`meta_to_json`, `keeper_meta_store.ml:34-35`)로 바꾸고, 파일을 읽는 함수의 '글자 → meta' 부분(`:192-250`)으로 되읽는다. 둘 다 메모리에서 한다. `Keeper_meta_store` 가 이 왕복을 함수 하나로 내놓는다. 그 뒤의 일은 그대로 둔다. profile 덮기도 지금 자리에서 지금처럼 돈다.

왕복한 값이 파일을 읽은 값과 같은 까닭은 때에 따라 다르다.

- Owner 가 meta 를 한 번이라도 쓴 뒤: 파일이 바로 그 encoder 의 출력이다. 왕복한 값은 그 파일을 읽은 값이다.
- Owner 가 아직 쓰지 않았다: Owner 는 기동 때 파일을 읽어 만들어진다(`keeper_owner_registry.ml:99-134`). 그 파일은 이 process 가 쓴 것이 아니다. 이때는 전제가 하나 필요하다. decoder 가 낸 값을 한 번 더 왕복해도 저장하는 필드가 그대로여야 한다. encoder 가 저장하는 필드를 모두 쓰고 decoder 가 그대로 되읽으면 성립한다. L1 이 이 전제를 시험으로 고정한다(§4).

자리 채움 값을 따로 적은 함수는 만들지 않는다. 그런 함수는 decoder 가 바뀌면 어긋난다. 변환은 행 하나에 한 번이고 meta 크기에 비례한다. L1 에서 그 시간을 재서 PR 에 적는다.

| `lookup` 결과 | 행 |
|---|---|
| `Owner_projection { meta = Some m; _ }` 이고 Owner 의 meta 쓰기가 모두 끝까지 됐다 | `m` 을 위 변환에 거친 값으로 만든다. 파일을 열지 않는다 |
| `Owner_projection { meta = Some _; _ }` 인데 meta 쓰기 하나가 됐는지 모르게 끝났다 | 지금처럼 파일을 읽는다 |
| `Owner_projection { meta = Some m; _ }` 인데 `m` 을 왕복한 글자를 decoder 가 거절한다 | 지금처럼 파일을 읽는다. Keeper 이름과 오류를 로그에 남긴다 |
| `Owner_projection { meta = None; _ }`, `Owner_absent` | 지금처럼 파일을 읽는다. 결과도 지금과 같다(없으면 `Keeper_gone`, 못 읽으면 `Keeper_unread`, `operator_control_snapshot.ml:210-216`) |

Owner 가 없는 Keeper 는 지금 동작 그대로다. 기동 때 meta 를 못 읽었거나, 이름이 맞지 않거나, Owner 가 시작하지 못한 Keeper 가 그렇다(`keeper_owner_registry.ml:112-134`, `:410-421`). 새 unread 이유는 만들지 않는다. TUI decoder 는 이유를 닫힌 목록으로 읽는다(`keeper_snapshot_unread.ml:44-47`).

Owner 의 meta 가 파일과 어긋난 채 남는 때가 둘 있다.

- `store.replace` 가 예외로 끝난다. Owner 는 행에 알리고 예외를 다시 던진다(`keeper_owner.ml:893-902`, `:930-934`). 그 Owner 는 그 뒤로 답하지 않는다(`:3317-3319`).
- `store.replace` 가 `Error` 로 끝난다. Owner 는 metadata 저장소를 막고, 재시작할 때까지 meta 커밋을 모두 거절한다(`:864-876`, `:2247-2254`).

두 경우 모두 파일은 이미 바뀌었을 수 있고(`:871-872`), Owner 의 메모리 값은 옛 값이다. 다음 커밋이 없어서 그 차이는 재시작까지 간다. 그래서 행은 그때 Owner 값을 쓰지 않고 지금처럼 파일을 읽는다. L1 은 Owner 가 "meta 쓰기가 됐는지 모르게 끝났다"를 `Atomic` 으로 내놓게 한다. Owner 는 행에 알리기 전에 그 값을 먼저 적는다. 알림을 받고 읽는 행이 옛 값을 보지 않게 하려는 것이다.

서버가 도는 동안 밖에서 meta 파일을 고치면 보이는 값이 지금과 달라진다(`scripts/migrate-keeper-meta-sandbox.sh`, §1.4). 지금 행은 Owner 의 다음 커밋 전까지 고친 파일 값을 보인다. L1 뒤에는 처음부터 Owner 값을 보인다. 고친 파일 값은 어느 쪽이든 Owner 의 다음 커밋이 덮는다.

snapshot 은 Keeper 행과 따로, 계속 떠 있어야 하는 Keeper 를 고르려고 설정된 Keeper 마다 저장된 meta 를 읽는다(`Keeper_meta_store.persistent_agent_names_with_unread`, #53113). 이 훑기도 행과 같은 읽기(`Keeper_stored_meta.read`)를 쓴다. `Keeper_meta_store` 는 `Keeper_stored_meta` 아래 모듈이라, 훑는 함수가 읽는 함수를 인자로 받는다(`~read_meta`). snapshot 의 행과 훑기는 같은 함수 하나(`stored_meta`)로 읽는다.

그래서 Owner 가 대신하는 Keeper 의 meta 파일을 서버 밖에서 읽을 수 없게 만들어도 snapshot 은 partial 이 되지 않는다. 전에는 이 훑기가 그 파일을 읽다 실패했고, snapshot 이 partial 이 되면서 그 Keeper 가 `persistent_agents` 에서 빠졌다. 행은 L1 부터 이미 Owner 값이었다. supervisor sweep 은 지금도 파일을 읽는다. 그 상태를 카운터(`masc_keeper_meta_read_failures_total`, `site="keepalive_read"`)와 WARN 으로 남기고, 그 Keeper 를 keepalive 에서 뺀다. snapshot 은 Owner 값대로 그 Keeper 를 계속 떠 있어야 하는 Keeper 로 보인다. 두 답이 갈라지는 것은 #53426 에 적었다.

옮기지 않은 읽기가 둘 있다.

- supervisor 의 keepalive reconcile(`keepalive_keeper_names`)은 지금처럼 meta 파일을 읽는다. supervisor sweep 이 끝날 때마다 돈다(`keeper_supervisor.ml` 의 `sweep_and_recover`). sweep 간격은 설정값이고 기본 30초다(`env_config_keeper_supervisor.ml`).
- 이 훑기는 Keeper TOML 을 읽는다. 설정된 이름을 찾을 때 Keeper 마다 한 번 읽는다. meta 가 있고 멈추지 않은 Keeper 는 autoboot 를 정할 때 한 번 더 읽는다. 풀이는 내용이 같으면 다시 하지 않는다(`keeper_types_profile_toml_io.ml` 의 `parsed_toml_cache`). TOML 은 서버 밖에서 고치는 파일이라 '쓰는 곳이 메모리에도 고친다'에 들지 않는다.

### 3.2 칸과 사실

부품은 넷이다. 칸 하나(`Fact_cell`, `lib/core`), 이름으로 찾는 등록부(`File_system_named`, `lib/core`), 저장소의 사실(`Dated_jsonl` 의 `fact`), 결정 기록 칸의 표(`Keeper_row_facts`)다.

```ocaml
(* lib/core/fact_cell.mli: 칸 하나. 바꿀 때마다 새 record 를 만들고 세대를 올린다. *)
type 'a slot =
  | Unfilled
  | Filled of 'a

type 'a seen   (* 한 순간의 칸: 세대와 slot *)
type 'a t      (* 'a seen 을 담은 Atomic *)

val see : 'a t -> 'a seen
val settle : 'a t -> 'a seen -> step:('a -> 'a option) -> unit   (* 쓰는 쪽, §3.3 *)
val forget : 'a t -> unit                                        (* 지우는 쪽 *)
val fill : 'a t -> read:(unit -> ('a, 'e) result) -> ('a, 'e) filled   (* 읽는 쪽, §3.4 *)

val keep_in_this_process : unit -> unit   (* 이 process 가 writer lease 를 쥐었다 *)
val kept_in_this_process : unit -> bool   (* 그 말을 했는가 *)

(* lib/dated_jsonl/dated_jsonl.mli: 저장소의 사실 하나.
   파일에서 값을 얻는 읽기와, 쓴 줄 하나로 값을 옮기는 step 을 같이 든다. *)
type 'a fact

val last_row : recent_entry option fact
(* 마지막 줄. JSON 이 아닌 줄도 한 줄이다(Malformed_json). *)

val newest_parsed_row : Yojson.Safe.t option fact
(* JSON 으로 읽히는 가장 새 줄. JSON 이 아닌 줄은 건너뛴다. *)

val last_rows : name:string -> count:int -> Yojson.Safe.t option list fact
(* 마지막 count 줄, 오래된 것부터. JSON 이 아닌 줄은 None 으로 자리를 지킨다.
   부를 때마다 새 사실이다. count 를 정한 곳에서 한 번 만들어 둔다. *)

val read_fact : t -> 'a fact -> ('a, read_error) Fact_cell.filled

val directories_removed : unit -> unit
(* 저장소 디렉터리를 이 모듈 밖에서 지웠다. 기억한 이름과 모든 칸을 비운다. *)
```

- 사실의 모양은 `Dated_jsonl` 이 정한다. 읽기와 `step` 이 한 모듈에 있어야 차분 시험이 둘을 같이 본다. `step` 을 위 층에 두면 읽는 함수가 바뀔 때 어긋난다. 층마다 모양이 는다.

  | 사실 | 값 | 층 |
  |---|---|---|
  | 최근 TurnRecord | 마지막 줄(`last_row`) | L2d-1 |
  | 가장 새 온전한 receipt | JSON 으로 읽히는 가장 새 줄(`newest_parsed_row`) | L2d-2 |
  | 도구 호출 | 원장의 마지막 16줄(`last_rows ~count`). 깨진 줄도 `None` 으로 자리를 지킨다 | L2d-3 |
  | 결정 기록 | 마지막 object 행. `Dated_jsonl` 저장소가 아니라서 `Keeper_row_facts` 의 표에 `Fact_cell` 을 둔다 | L2d-4 |
  | metrics | decoder 가 받는 가장 새 줄(Turn tool audit, `newest_selected`) | L3a |
  | metrics | 끝 120줄 | L3b |

- decoder 가 필요한 사실은 위 층이 decoder 를 넘겨 만든다. `Dated_jsonl` 은 Keeper 타입을 모른다.
- 칸의 값은 `{ value; newest }` 다. `newest` 는 그 값이 본 가장 새 날짜 파일이다(§3.3).
- 칸은 저장소 등록부 항목에 둔다(규칙 1). 항목은 (사실, 칸) 목록을 `Atomic` 하나에 든다. 사실 하나에 칸은 하나다. 읽는 쪽이 처음 물을 때 compare-and-set 으로 목록에 더한다. 진 쪽은 이긴 쪽의 칸을 쓴다. 있는 칸을 새것으로 바꿔 끼우지 않는다. `Keeper_owner_projection.install` 처럼 덮어쓰면(`keeper_owner_projection.ml:15-19`) 쓰는 쪽과 읽는 쪽이 서로 다른 칸을 본다.
- 날짜별 저장소의 칸은 읽는 쪽만 만든다. 쓰는 쪽과 지우는 쪽은 있는 칸만 돈다. prune 은 디스크의 Keeper 디렉터리마다 저장소를 연다(`prune_listed_stores_bound`). 여는 쪽마다 칸을 만들면 아무도 읽지 않는 디렉터리에도 칸이 생긴다. 결정 기록은 다르다. 쓰는 쪽도 기록의 이름으로 칸을 찾으므로, 쓸 때 빈 칸이 생긴다(`Keeper_row_facts.appending_decision`). 값은 채우지 않는다. 칸 수는 process 가 읽거나 쓴 기록 파일 수다.
- 칸은 저장소를 쓰는 process 만 든다. 칸을 고치는 것은 그 process 의 쓰기뿐이고, 다른 process 가 쓴 줄은 칸에 닿지 않는다. TUI 는 서버와 다른 process 인데 같은 함수로 TurnRecord 파일을 읽는다(`bin/masc_tui_context_state.ml` 의 `load`). 값을 들면 TUI 는 처음 읽은 줄을 끝까지 보인다.
  - 「이 process 가 혼자 쓴다」는 사실 둘로 이루어진다. 하나는 process 의 사실이다. 이 process 가 writer lease 를 쥐었는가. 다른 하나는 저장소의 사실이다. 이 저장소의 파일을 lease 를 쥔 process 만 바꾸는가. 둘 다 맞을 때만 `read_fact` 가 값을 든다.
  - process 의 사실은 process 가 말한다(`Fact_cell.keep_in_this_process`). 한 번 말하면 거두지 않는다. 저장소의 사실과 결정 기록의 행이 같은 말을 본다. lease 를 쥐고 Keeper 를 돌리는 실행 파일 둘이 lease 를 잡은 직후에 말한다(`Server_startup_takeover.keep_store_facts`). HTTP 서버(`bin/main_eio.ml`)와 stdio 런타임(`bin/main_stdio_eio.ml`)이다. 이 함수는 받은 lease 가 지금 이 process 가 쥔 lease 일 때만 말한다. 놓은 lease 로 부르면 `Lease_not_held` 를 돌려주고 아무 말도 하지 않는다.
  - 저장소의 사실은 저장소 목록이 말한다(`Dated_jsonl.Store.facts`). 저장소 종류마다 `Kept_by_the_lease_holder` 나 `Read_from_the_files` 를 적는다. 빠짐없이 적어야 컴파일된다. `Kept_by_the_lease_holder` 는 그 저장소에 쓰는 곳을 모두 따라가 본 뒤에만 적는다. 지금은 TurnRecord, execution receipt, 도구 호출 원장, Keeper metrics 다. cost 기록은 `masc-cost` 가 lease 없이 덧붙이므로(§1.4) `Read_from_the_files` 다. 따라가 보지 않은 저장소도 `Read_from_the_files` 다. 사실을 옮기는 층은 자기 저장소에 쓰는 곳을 따라가 보고 이 목록을 고친다.
  - 둘 중 하나라도 아니면 전처럼 매번 파일을 읽는다. 칸도 등록부 항목도 만들지 않는다.
  - `Fact_cell.keep_in_this_process` 자체는 누구나 부를 수 있다. `Fact_cell` 은 lease 를 모르고, 서버를 대신하는 시험 실행 파일도 이 함수를 부른다. lease 를 쥐지 않은 실행 파일이 부르면 #53145 의 결함이 돌아온다. 그래서 TUI 가 쓰는 진입점을 시험으로 고정한다(§5).
  - 읽는 호출처가 「든 값」과 「파일」 가운데 고르게 하지 않았다. 그러면 호출처마다 맞게 골라야 하고, 틀리면 빠르지만 틀린 값이 나온다. 지금 모양은 말하기를 잊으면 느릴 뿐이다.
- 그래서 쓰는 도중에 칸이 새로 생길 수 있다. 쓰는 쪽은 그 칸을 쓰기 전에 보지 못했다. 쓰기 전에 본 목록과 쓴 뒤의 목록이 다르면 그 저장소의 칸을 모두 비운다.
- 같은 디렉터리를 다르게 적는 길이 여럿이다. base path 는 별칭을 허락한다(`dated_jsonl_store.ml:168`, macOS 의 `/var`·`/tmp`). 저장소 위치의 Keeper 조각은 부르는 쪽이 준 글자다(`Store.keeper`). 쓰는 쪽과 읽는 쪽은 Keeper 이름으로 만들고, prune 은 디스크의 디렉터리 이름으로 만든다(`Store.fold_retention_directories`). 대소문자를 접는 file system(운영 장비의 APFS)에서는 `keepers/Alpha` 와 `keepers/alpha` 가 한 디렉터리다. 글자로 견주는 key 는 이들을 다른 저장소로 본다. 칸이 없을 때는 그래도 값이 맞았다. 줄 쓰기는 `realpath` 로 고른 경로 mutex 가 지키고(`fs_compat_base_io.ml:219-245`), 읽는 쪽은 파일을 읽어서다. 칸을 두면 달라진다. 한쪽으로 쓰거나 지운 줄이 다른 쪽 칸을 건드리지 않아서, 그 칸이 재시작까지 옛 값이다.
- 그래서 L2 는 등록부 key 를 file system 이 그 디렉터리를 부르는 이름으로 만든다(`File_system_named.name`). 이 규칙은 `lib/core` 의 `File_system_named` 에 있고, 저장소 등록부와 결정 기록 칸의 표가 같이 쓴다. 디렉터리가 있으면 경로 전체를 `realpath` 로 푼 이름이다. symlink 를 따라가고, 조각마다 디렉터리 항목의 이름이 온다. 그래서 두 글자가 같은 key 를 얻는 것과 한 디렉터리인 것이 같은 말이다. 대소문자를 접는지는 file system 이 답한다. 디렉터리가 아직 없으면 있는 가장 깊은 조상을 풀고 나머지 조각을 적은 글자대로 붙인다. 줄 쓰기가 경로 mutex 를 고르는 규칙과 같다.
- handle 은 등록부 항목을 들지 않는다. 쓰거나 지울 때마다 자기 저장소의 항목을 찾는다. Keeper 저장소의 handle 은 디렉터리 글자로 process 가 끝날 때까지 기억된다(`keeper_types_support.ml` 의 `*_store_cache`). 열 때 항목을 정하면, 디렉터리가 없을 때 연 handle 이 그 뒤에도 옛 글자의 항목을 쓴다.
- 있는 디렉터리의 이름은 적은 글자마다 한 번만 묻고 기억한다. 그 뒤의 쓰기와 읽기에는 파일 system call 이 없다. 없는 디렉터리는 기억하지 않고 쓸 때마다 다시 묻는다. 그 답은 디렉터리가 생기면 바뀔 수 있다. 첫 쓰기가 디렉터리를 만들므로 다시 묻는 것은 그때까지다. 쓰기가 디렉터리를 만들었으면 쓴 뒤에 이름을 다시 묻는다. 적은 글자가 `없는 조각/..` 을 지나면 만든 뒤의 이름이 달라진다. 항목이 달라졌으면 두 항목의 칸을 비운다.
- handle 을 얻는 일도 파일을 보지 않는다. Keeper 저장소의 위치(`Keeper_types_support.keeper_store_location`)와 결정 기록의 경로(`keeper_decision_log_path`)는 경로일 뿐이다. 전에는 이 함수들이 부를 때마다 Keepers 디렉터리가 있는지 확인했다. fiber 안에서 그 확인은 Eio `stat` 이고, worker thread 가 답하는 동안 fiber 는 차례를 내놓는다. 든 값을 읽는 쪽이 저장소를 열 때마다 이 값을 치렀다.
  - 저장소 밖에서 쟀다(load average 약 200, 확인 한 번의 최솟값/중앙값). `Fs_compat.file_exists` 는 49/83 µs, `Sys.file_exists` 는 2.8/3.6 µs 다. 옆에서 한 번에 1 ms 씩 도는 fiber 하나가 있으면 `Fs_compat.file_exists` 는 2.6/3.2 ms 가 된다. 기다리는 동안 다른 fiber 가 돌기 때문이다.
  - 든 값을 읽는 동안 옆 fiber 가 한 번도 돌지 않는 것을 시험으로 고정한다(`test_keeper_turn_tool_audit_kept`, `test_keeper_execution_receipt_kept`, `test_keeper_decision_row_kept`). 기다리는 호출이 하나라도 끼면 옆 fiber 가 돈다. 저장소 handle 을 거치는 두 시험(tool audit, receipt)은 서버처럼 Eio mutex guard 를 켜고 읽는다(`Eio_guard.enable`). 저장소 handle 은 `Eio.Mutex` 아래에서 얻고, 다른 domain 이 그 mutex 를 쥐고 있는 동안에는 기다린다. 시험은 그 경합을 만들지 않는다. 결정 기록 읽기는 저장소 handle 을 쓰지 않아서 guard 와 무관하다.
  - Keepers 디렉터리는 쓰기가 만든다. 날짜별 저장소의 append, 결정 기록을 쓰는 `Keeper_types_support.append_decision_record`, 그 밖의 낱개 JSONL 파일(feedback, TLA trace, runtime manifest)을 쓰는 `Keeper_types_support.append_jsonl_line` 이 모두 쓰는 job 안에서 만든다(`Fs_compat.append_jsonl_rows`). 부르는 쪽은 디렉터리를 먼저 만들지 않는다. 먼저 만들면 행을 쓸 때마다 fiber 에서 `stat` 을 한 번 한다.
- 기억은 디렉터리를 지운 쪽이 `Dated_jsonl.directories_removed` 로 지운다. 이 함수는 기억한 이름을 모두 지우고 모든 저장소의 칸을 비운다. 어느 디렉터리인지 받지 않는다. 받은 디렉터리만 지우면 그 디렉터리를 가리키던 다른 글자(symlink, 대소문자)가 옛 항목에 남는다. 지우는 일은 드물고, 비운 칸은 다음 읽기 한 번이 채운다. 지우기와 겹친 쓰기는 자기 줄이 어느 디렉터리로 갔는지 모른다. 그래서 쓴 뒤에 이름을 다시 묻고, 항목이 달라졌으면 두 항목의 칸을 비운다.
- 저장소 경로(`Store.dir`)는 부르는 쪽이 적은 글자 그대로 둔다. 경로 글자를 바꾸면 그 글자를 디스크에 적어 둔 곳이 어긋난다. 도구 호출 읽기 색인은 날짜 파일 경로를 cursor 의 key 로 둔다(`keeper_tool_call_index.ml:70-71`, `:1038-1040`). base path 에 symlink 가 낀 설치에서 글자가 바뀌면 색인이 모든 날짜 파일을 처음 보는 파일로 읽는다.
- 결정 기록 칸은 `Keeper_row_facts` 의 표에 둔다. key 는 결정 기록 파일을 file system 이 부르는 이름이다. 저장소 디렉터리와 같은 규칙으로 얻는다. 줄 쓰기의 경로 mutex 등록부에는 칸을 걸 수 없다. 그 등록부는 쓰는 쪽이 없으면 항목을 지우고(`fs_compat_base_io.ml:263-268`), 경로를 고를 때마다 `realpath` 를 돈다.
  - 표는 `File_system_named` 등록부 하나다. 항목이 곧 칸이다. 결정 기록은 사실이 하나라서 (사실, 칸) 목록이 없다. 쓰는 쪽과 읽는 쪽이 `keeper_decision_log_path` 로 만든 경로로 그때그때 칸을 찾는다.
  - 결정 기록에 쓰는 곳을 따라가 봤다. 줄을 더하고 파일을 돌리는 것은 `Keeper_types_support.append_decision_record` 하나다. Keeper 의 턴이 부른다. 파일을 지우는 것은 그 Keeper 의 purge 다. 턴과 purge 는 lease 를 쥔 process 에서만 돈다. 그래서 `Fact_cell.keep_in_this_process` 를 말한 process 만 행을 든다. 종류가 하나라 저장소 목록 같은 표는 두지 않았다.
  - 쓰는 쪽은 파일을 돌렸으면 기억한 이름을 지운다(`File_system_named.removed`). 돌리기는 파일을 다른 이름으로 옮기고, 다음 쓰기가 같은 이름의 새 파일을 만든다. 대소문자를 접는 file system 에서는 새 파일의 이름이 그 쓰기가 적은 글자를 따른다. 기록 경로가 symlink 이면 어느 file system 에서나 이름이 바뀐다. 돌리기가 링크를 옮기고 다음 쓰기가 일반 파일을 만들기 때문이다. 옛 이름을 기억한 채로 두면, 처음 보는 표기가 새 이름의 칸을 따로 얻는다. 돌렸다는 이유만으로 칸을 비우지는 않는다. 쓴 줄을 드는 규칙은 돌리지 않은 쓰기와 같다(줄 길이, object 인지, 다른 writer 와 겹쳤는지). 돌린 뒤 그 경로가 다른 이름의 파일이 됐으면 두 칸을 모두 비운다.
  - purge 는 `Keeper_row_facts.decision_records_removed` 를 부른다. 기억한 이름과 모든 결정 기록 칸을 비운다. `Dated_jsonl.directories_removed` 와 같은 자리에서, 끝나는 모든 경로에서 부른다.
- 지금 운영 경로에서 표기가 갈리는 곳은 찾지 못했다. 쓰는 쪽, prune, 도구 호출 `init` 이 모두 `config.base_path` 에 조각을 붙인다(`workspace_utils_paths_backend.ml:99`, `server_runtime_startup_maintenance.ml:66-67`, `keeper_tool_call_log.ml:473-478`). 이 규칙은 그 사실을 리뷰가 아니라 구조로 지키려는 것이다.
- 등록부에 항목을 남기지 않는 handle 은 `Dated_jsonl.Reader` 다. 운영에 한 곳 있고 읽기만 한다(`keeper_autonomous_turn_source.ml` 의 `read_store`). 추측한 이름마다 등록부 항목이 생기지 않게 하려는 것이다. 그 handle 에는 칸이 없고, 읽는 쪽은 파일을 읽는다. 쓰는 함수는 이 타입을 받지 않는다. 등록부 밖 handle 로 쓰면 칸이 틀리기 때문이다.
- `Type.Id` 는 OCaml 5.5.2 에 있다(작은 프로그램으로 확인). 사실마다 `Type.Id` 를 하나 든다. 항목의 목록은 타입이 다른 칸을 같이 들고, 찾을 때 `Type.Id.provably_equal` 로 타입을 되찾는다.
- 값은 디스크에 쓴 줄을 읽는 쪽과 같은 parser 로 해석한 JSON 이다. metrics 120줄만 글자로 든다(아래). 결정 기록 4곳, 도구 호출 6곳, metrics 2곳이 넘기는 모양이 저마다 달라서 행 타입으로 묶지 않는다(`keeper_tool_memory_runtime.ml:1332`, `keeper_unified_metrics_decision.ml:401` 등). 읽는 쪽은 지금 쓰는 decoder 를 그대로 쓴다. 그래서 `Undecodable_turn_record` 같은 구분도 지금처럼 나온다(`keeper_context_observation_projection.ml:92-101`). JSON 이 아닌 줄은 `Dated_jsonl.recent_entry` 의 `Malformed_json` 으로 든다. 그 상태도 칸에 담으려는 것이다.
- 목록 값(도구 호출 16줄, metrics 120줄)은 읽는 쪽이 세는 줄을 자리 그대로 든다. 두 reader 는 빈 줄이 아닌 줄을 세고, 깨진 줄은 그 뒤에 건너뛴다(`keeper_tool_call_log.ml:1572-1586`, `Keeper_status_metrics.newest_metrics_lines_result`, `operator_control_snapshot_tool_names.ml:41-56`). 그래서 깨진 줄도 자리를 차지한다. 깨진 줄을 빼고 들면 다음 쓰기 뒤에 창에서 빠지는 줄이 파일과 달라진다. 도구 호출 창의 줄은 JSON 이거나 `None`(JSON 이 아닌 줄)이다. `Malformed_json` 으로 들지 않는다. `Malformed_json` 은 그 줄이 든 날짜 파일의 경로를 담는데, 크기 rotation 은 창이 든 줄 아래에서 그 파일의 이름을 바꾼다. 처음에는 `Malformed_json` 으로 들었고, 400걸음 차분 시험이 22번째 걸음에서 든 경로와 파일의 경로가 다른 것을 잡았다. 창을 읽는 곳은 경로를 쓰지 않는다.
- metrics 120줄은 JSON 으로 풀지 않고 글자 그대로 든다(`Dated_jsonl.last_lines`). 합성한 2.8 kB 행 120개는 푼 JSON 으로 1,318,080 B, 글자로 336,000 B 였다(저장소 밖 측정). 읽는 쪽은 쓰는 줄만 푼다. 최근 도구 이름과 최근 활동은 전처럼 `Fs_compat` 의 JSONL parser 로, metrics 창은 `Dated_jsonl.parse_line` 으로 푼다. 최근 도구 이름은 이름 8개를 모으면 멈추고, 최근 활동은 끝 5줄만 본다. metrics 창은 120줄을 모두 풀고, 그 일은 요청의 pool job 안에서 한다.
- 채우다 파일을 못 읽으면 값을 넣지 않는다(§3.4). 행은 그때 지금의 reader 가 내는 값을 그대로 낸다. 오류를 돌려주던 reader 는 오류를 내고(`Turn_record_read_failed` 등), 빈 값을 내던 reader 는 빈 값을 낸다. 다음 읽기가 다시 채운다.
- receipt 칸은 가장 새 온전한 줄을 든다. 마지막 줄이 아니다. 두 reader 가 모두 깨진 줄을 건너뛰기 때문이다(§1.1). 그래서 두 reader 가 칸 하나에서 답을 얻는다. 엄격한 읽기가 실패하는 저장소만 `latest_json` 이 전처럼 너그럽게 다시 읽는다. 그 읽기는 점으로 시작하는 `.jsonl` 도 읽는다(§3.4). 쓰는 쪽은 JSON 을 쓰므로, 쓴 뒤의 값은 늘 쓴 그 줄이다. 쓴 줄이 JSON 으로 다시 읽히지 않으면 칸을 비운다.
- TurnRecord 칸은 마지막 줄을 든다. 그 reader 는 깨진 줄도 한 줄로 세고 `Undecodable_turn_record` 로 알린다(`keeper_context_observation_projection.ml:83-101`).
- `newest` 는 채우는 쪽이 본 가장 새 날짜 파일이다. 읽는 쪽은 날짜 파일을 새것부터 읽는다(`dated_jsonl.ml:1338-1367`). 엄격한 끝 읽기는 줄마다 원본 경로를 같이 돌려준다(`dated_jsonl.mli:312-318`). 날짜는 그 경로에서 얻는다. 줄이 없으면 `newest` 도 없다. `turn_audit`·`receipt` 처럼 줄 하나를 골라내는 읽기는 그 줄을 찾은 파일을 `newest` 로 둔다. 건너뛴 줄은 그 값에 아무것도 말하지 않는다. 그래서 값의 줄이 있는 파일이나 그 뒤 파일에 쓴 줄은, 사이의 파일에 무엇이 있든 가장 새 값이다. 골라낸 줄이 없으면 `newest` 가 없고, 다음에 쓴 줄이 곧 값이다. 고르지 않는 줄을 쓰면 값은 그대로고 `newest` 만 그 줄의 파일로 옮긴다. 엄격한 찾기도 그 줄을 지나치기 때문이다. 결정 기록은 파일이 하나라 이 값이 없다.
- 행 수(16, 120)와 결정 기록의 창(40,000바이트·20줄)은 지금 읽는 쪽이 쓰는 수다. 그 사실을 만드는 층이 읽는 쪽 상수를 사실 옆으로 옮겨 한 곳에 둔다. 120 은 `Keeper_status_metrics.recent_metrics_row_count` 다. 최근 도구 이름과 대시보드의 metrics 창이 같은 수를 따로 적고 있었다.
- 도구 호출은 workspace 원장의 마지막 16줄을 그대로 든다. Keeper 의 최근 호출은 그 16줄에서 찾는다. 지금 `read_latest ~keeper_name` 과 같은 뜻이다. 16줄 밖으로 밀려난 Keeper 는 지금처럼 `None` 이다.

### 3.3 쓰는 쪽

쓰는 쪽은 그 저장소의 칸을 모두 읽어 둔 뒤 파일을 바꾸고, 그다음 칸마다 맞춘다. 칸을 바꾸는 일은 `Atomic` 연산뿐이다.

```ocaml
(* 잠금이 있으면 그 안에서, 파일을 바꾸기 전에. 그 저장소의 칸마다 *)
let seen = Fact_cell.see cell in
(* ... 파일 쓰기. 예외·취소면 그 저장소의 칸을 모두 비우고 다시 던진다 ... *)
Fact_cell.settle cell seen ~step:(fun held -> fact.step held written)
(* written: 디스크에 쓴 줄을 해석한 값과, 그 줄이 간 날짜 파일
   step: 새 값을 읽는 쪽과 똑같이 만들 수 있으면 Some 새 값, 없으면 None.
         쓴 행이 이 칸의 값을 바꾸지 않으면 새 값은 받은 값이다.
   settle: Unfilled 는 Unfilled 로, Filled v 는 step v 로 옮긴다. 둘 다 세대를 올린다.
           칸이 seen 과 다르거나 step 이 None 이면 forget 한다.
   forget: 칸을 { generation + 1; Unfilled } 로 바꿀 때까지 compare-and-set 을 되풀이 *)
```

- `Dated_jsonl` 저장소(도구 호출, receipt, TurnRecord, metrics): 저장소 잠금을 잡은 뒤, 쓰기 전에 그 저장소의 칸을 읽는다. 줄을 쓴 직후에 칸을 맞춘다. 쓰는 함수 둘이 직접 한다. hook 이나 callback 은 없다. 쓰는 쪽 호출처는 바뀌지 않는다. receipt 와 TurnRecord 는 `append` 로 쓴다(`dated_jsonl.ml:872-893`). 도구 호출과 metrics 는 `append_rotating` 으로 쓴다(`:1746-1795`). 칸은 `on_committed` 를 부르기 전에 맞춘다.
- 쓴 줄을 읽는 쪽 parser 로 해석하는 일은 잠금 밖에서 한다. 줄은 쓰기 전에 정해지고, 해석은 잠금 상태에 기대지 않는다. 도구 호출 원장은 모든 Keeper 가 한 잠금을 쓴다. 그래서 잠금 안의 일을 줄인다. 쓰는 함수는 줄을 한 번만 만들고, 쓰기와 해석이 그 글자를 같이 쓴다. 그래서 줄 쓰기에 만든 글자를 그대로 받는 `Fs_compat.append_jsonl_rows` 를 둔다. 칸이 없는 저장소의 쓰기는 줄을 해석하지 않는다.
- 칸을 맞추는 일은 예외를 내지 않는다. `step` 이 던지면 그 저장소의 칸을 비우고 로그에 남긴다. 줄은 이미 디스크에 있어서다. 예외가 `on_committed` 앞에서 나가면 부른 쪽은 줄을 쓰지 못한 것으로 안다. 도구 호출 원장의 drain 은 그 행을 한 번 더 쓴다(`keeper_tool_call_log.ml` 의 `committed`). `Out_of_memory` 와 `Stack_overflow` 만 다시 던진다. 원장의 알림(`notify_written`)은 `on_committed` 안에 있다. 알림을 받고 읽는 쪽은 새 값을 본다.
- 크기 회전은 쓰기 안에서 일어난다(`dated_jsonl.ml:1746-1790`). 회전해도 읽는 쪽이 보는 줄의 순서는 같으므로 새 값을 만들 수 있다. 다만 채우는 쪽은 파일 목록을 얻은 뒤 이름으로 파일을 연다(`dated_jsonl.ml:1310-1336`). 그 사이 회전이 끼면 옛 목록으로 읽는다. 쓰기가 `Unfilled` 의 세대도 올리므로 그런 채우기는 들어가지 못한다.
- append 뒤 바이트 prune(metrics 에 `max_bytes` 를 켠 때)은 `on_committed` 다음에 파일을 지운다. `prune_to_max_bytes_unlocked` 는 지운 파일 수를 돌려준다(`dated_jsonl.ml:831-850`). 지금 부르는 쪽은 그 수를 버린다(`:865-870`). 하나라도 지웠거나 prune 이 예외로 끝나면 그 저장소의 칸을 모두 비운다.
- 쓰기는 지금 시각의 날짜 파일로 간다(`dated_jsonl.ml:885`, `:1748`). 읽는 쪽은 날짜 파일을 새것부터 읽는다. 시계가 뒤로 가서 지난 날짜 파일에 쓰면 그 행은 읽는 쪽에게 가장 새 행이 아니다. 그래서 쓴 날짜 파일이 값이 본 가장 새 날짜 파일(`newest`)보다 앞이면 칸을 비운다. 아니면 새 값의 `newest` 를 쓴 날짜 파일로 둔다. 같은 날 크기 회전으로 닫힌 파일(`18.2.jsonl`)은 지금 쓰는 파일(`18.jsonl`)보다 앞이다.
- 결정 기록: 돌리기에는 잠금이 없고, 쓰기의 잠금은 system thread 안의 OS mutex 다(§1.4). 이 RFC 는 잠금을 더하지 않는다. 쓰는 쪽은 돌리기 전에 칸을 읽고, 쓰기가 끝난 뒤 칸을 맞춘다. 같은 Keeper 의 결정 기록을 두 곳이 같이 쓰면 늦게 온 compare-and-set 이 실패해 칸이 비워진다. 그래도 불변식은 지켜진다.
- 결정 기록의 새 값은 디스크에 쓴 줄(`utf8_repair_string` 을 거친 줄)로 만든다. 줄바꿈까지 쳐서 읽는 쪽 창보다 한 바이트 이상 짧고(39,999바이트 이하) JSON object 인 줄만 `Row` 로 넣는다. 아니면 칸을 비운다.
  - 읽는 쪽은 마지막 40,000바이트를 한 번에 읽는다. 창이 파일 처음보다 뒤에서 시작하면 첫 줄바꿈까지의 조각을 버린다(`keeper_memory_recall.ml` 의 `tail_lines_of_fd`). 창이 그 조각을 잘랐을 수 있어서다. 빈 줄은 그 뒤에 걸러낸다. 그래서 마지막 줄 앞의 줄바꿈이 창에 들어오면 마지막 줄은 버려지지 않는다. 그 줄바꿈은 마지막 줄 바로 앞 바이트다. 줄이 줄바꿈까지 쳐서 창보다 한 바이트 짧으면 그 줄바꿈이 창의 첫 바이트다. 줄이 창과 같은 길이면 창이 그 줄의 첫 바이트에서 시작하고, 읽는 쪽은 그 줄을 잘린 조각으로 보고 버린다. 그 줄이 파일의 하나뿐인 줄이면 창이 파일 처음에서 시작해서 버리지 않는다. 쓰는 쪽은 파일에 무엇이 있었는지 보지 않고 길이만 본다.
  - 로그를 돌린 직후에는 새 파일에 쓴 줄 하나만 있다. 창이 파일 처음에서 시작하므로 첫 줄을 버리지 않고, 쓴 줄이 그대로 값이다. 읽는 쪽은 `.1` 로 옮긴 파일을 지금도 읽지 않는다.
  - object 가 아닌 줄은 건너뛰고 앞 줄을 찾는다(`keeper_runtime_trust_snapshot.ml:336-366`). 그 결과는 쓴 줄 하나로 알 수 없다.
- metrics 쓰기는 칸 둘을 맞춘다. `metrics_recent` 에는 쓴 줄을 더하고, 120줄을 넘는 앞 줄을 뺀다(L3b). `turn_audit` 은 쓴 행이 Turn tool audit 행이면 그 행으로 바꾸고, 아니면 같은 값으로 세대만 올린다(L3a). 행이 Turn tool audit 인지는 읽는 쪽과 같은 함수로 본다(`Keeper_status_metrics.tool_audit_of_metrics_row`). `Dated_jsonl.newest_selected` 가 그 함수 하나를 받아 읽기와 `step` 을 같이 만든다. heartbeat 가 이어져도 `Filled` 인 `turn_audit` 은 비워지지 않는다.
  - 고르는 함수는 저장소 디렉터리를 같이 받는다(`~base_dir`). 읽지 못하는 줄을 그 Keeper 의 metrics 디렉터리 이름으로 보고하려는 것이다. 보고는 파일을 훑을 때 한다. 쓴 줄은 방금 만든 JSON 이라 보고할 것이 없다.
- 쓰기가 예외로 끝나면 그 저장소의 칸을 모두 비우고 예외를 다시 던진다. 취소도 예외로 온다.
- system thread 에 맡긴 쓰기가 도는 동안 부른 fiber 는 깨어나지 않는다. 풀 밖 fiber 는 host 에 일을 넘기고 취소되지 않는 `await` 로 기다린다(`lib/fs_compat/systhread_host.ml:37-48`, `:193-198`). 풀 작업이거나 host 가 없으면 `Eio_unix.run_in_systhread` 로 간다(`:174-178`). Eio 의 thread pool 도 넘긴 일에 취소를 걸지 않는다(Eio `unix/thread_pool.ml` 의 `submit`). 넘기기 전에 이미 취소됐으면 쓰기는 시작하지 않고 `Cancelled` 가 온다(`lib/fs_compat/systhread_host.ml:180`). 쓰기가 일어나지 않았는데 칸을 비우는 것은 조심이 지나칠 뿐 틀리지 않는다.
- 실패한 쓰기의 바이트는 나중에 파일에 닿지 않는다(규칙 11). 그래서 칸을 비운 뒤에 채운 값이 그 바이트 때문에 틀리는 일이 없다. 뒤늦게 들어오는 바이트는 어느 칸의 순서도 따르지 않는 변경이다. 칸으로는 막을 수 없어서 쓰는 함수가 막는다.
- 줄 쓰기(`Fs_compat.append_lines`)는 줄을 쓴 뒤에 취소를 확인한다(`fs_compat_base_io.ml:393-397`). 그래서 줄은 썼는데 칸은 못 고친 채 취소될 수 있다. 쓰는 쪽은 칸을 고치기 전에 끝나는 모든 경로에서 칸을 비운다.
- `Dated_jsonl.append` 는 append guard 가 막으면 조용히 건너뛴다. `append_notifying_commit` 은 그때 `Append_guard_skipped` 를 던진다(`dated_jsonl.ml:892-905`). 건너뛴 쓰기는 파일을 안 바꾸므로 칸을 그대로 둔다. 부르는 쪽의 동작도 지금과 같게 둔다. `append_rotating` 이 쓸 회전 번호를 찾지 못하면 쓰지 않고 `Skipped_rotation_exhausted` 를 돌려준다. 그때도 칸을 그대로 둔다.

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
  | `tool_calls` | `Dated_jsonl.last_rows` 의 읽기. `read_recent_result` 와 같은 엄격한 읽기다 | 깨진 줄도 한 줄로 센다. 읽기 색인 파일은 곁 파일로 건너뛴다(아래) |
  | `receipt` | `find_latest_entry_result` 로 가장 새 온전한 줄(`dated_jsonl.mli:275`) | `read_latest_receipt` 가 지금 쓰는 읽기다(`keeper_execution_receipt.ml:769-779`) |
  | `turn_record` | `read_recent_result` 로 한 줄 | TurnRecord reader 는 지금도 실패를 돌려준다(`keeper_context_observation_projection.ml:73-117`) |
  | `metrics_recent` | 같은 함수로 120줄 | 최근 활동 5줄도 이 값의 끝에서 얻는다(`Keeper_status_metrics.recent_activity_lines`). 엄격한 읽기가 거부한 저장소는 전처럼 너그럽게 5줄을 읽는다. 새 날짜 파일부터 5줄이 찰 때까지 거슬러 열고, 못 열거나 읽다가 잘린 날짜 파일에서 예외를 낸다(`Sys_error`, `End_of_file`). 그 예외는 Keeper 행을 통째로 뺀다. 이 RFC 이전과 같다. 120줄을 다 읽으러 가면 엄격한 읽기가 거부한 그 파일까지 가므로 5줄만 묻는다 |
  | `turn_audit` | `find_latest_entry_result` 에 `tool_audit_of_metrics_row` 를 넘긴 엄격한 찾기 | `Dated_jsonl.newest_selected` 의 읽기다 |

- 엄격한 읽기는 `YYYY-MM/DD.jsonl` 모양의 일반 파일만 받는다. symlink 와 낯선 이름은 `Error` 다(`dated_jsonl.mli:267-273`). 그런 저장소의 칸은 채워지지 않고, 행은 지금 reader 로 읽는다. 보이는 값은 그대로다.
  - 칸이 채워진 뒤에 낯선 이름이 생기는 순서는 다르다. 칸은 쓴 행을 따라 옮겨 가고 디렉터리를 다시 보지 않는다. 그래서 든 process 는 계속 값을 답하고, 파일을 읽는 process 는 `Error` 를 낸다. 칸이 비는 때(재시작, prune, `directories_removed`)에 읽기가 그 저장소를 거부한다. 든 값은 쓴 행 그대로이므로 틀린 행을 보이지는 않는다.
  - 엄격한 목록은 점으로 시작하는 이름을 건너뛴다(`Dated_jsonl_layout.entry_is_foreign_to_layout`). 너그러운 목록은 `.jsonl` 로 끝나면 그런 이름도 읽는다. 최근 활동은 5줄을 너그럽게 읽었으므로, 달 디렉터리에 점으로 시작하는 `.jsonl` 파일이 있던 저장소에서는 보이는 줄이 달라진다. 이제 최근 도구 이름·metrics 창과 같은 줄을 본다.
- 도구 호출 원장 디렉터리에는 읽기 색인 파일이 있다(§1.4). 엄격한 목록이 그 이름을 낯선 이름으로 보면 `tool_calls` 칸은 운영에서 채워지지 않고, Keeper 31개가 행마다 원장을 다시 읽는다. 새로 만든 base path 에는 색인이 없어서, 색인 reader 를 부르지 않는 시험은 이 경우를 지나지 않는다. `test_keeper_tool_call_log_kept` 는 색인 reader 를 부른 디렉터리에서 칸이 채워지는 것을 본다.
  - 저장소 선언(`Dated_jsonl.Store`)이 그 디렉터리의 어떤 이름이 곁 파일인지 답한다. 도구 호출 원장의 답은 `Common.is_tool_call_read_index_file` 이다. 저장소 종류마다 답을 적는다. 종류가 늘면 컴파일러가 빠진 답을 잡는다.
  - 행이 읽는 나머지 저장소는 Keeper 저장소다. 거기에는 곁 파일이 없다. 운영 설치에서 달 디렉터리를 가진 디렉터리 990개를 이름만 훑었다(2026-11-18). 달 옆의 낯선 이름은 이 색인 파일 셋과 `activity-events` 의 `_seq` 뿐이다. 달 안의 낯선 이름은 `wire-capture` 에만 있다(`.err` 넷, `.txt` 넷, 같은 날 이름만 봄). 행은 그 저장소를 읽지 않는다.
  - `activity-events` 는 행이 읽지 않는다. 그 저장소를 읽는 task history 는 자기 목록에서 `_seq` 를 건너뛴다(`task_history_inventory.ml:8-11`, `:59`). 이 RFC 는 그 저장소의 답을 바꾸지 않는다.
  - 엄격한 목록은 곁 파일을 건너뛴다. 그 밖의 낯선 이름은 지금처럼 `Error` 다. blob 을 훑는 scanner 가 이미 같은 함수로 색인 파일을 건너뛴다(`lib/core/common.mli:202-210`, `tool_blob_maintenance.ml:1007`).
- 점으로 시작하는 이름은 엄격한 목록이 조용히 건너뛴다(`dated_jsonl.ml:255`, `dated_jsonl_layout.ml:143-155`). 이 layout 이 만들 수 없는 이름이라서다. 너그러운 목록은 `.jsonl` 로 끝나면 점으로 시작해도 읽는다(`dated_jsonl.ml:197-200`). 그래서 달 디렉터리에 `._18.jsonl` 같은 파일이 있으면, 엄격한 읽기는 `Ok` 인데 줄이 다르다.
  - 갈리는 reader 는 `latest_json`, `read_latest ~keeper_name`, 최근 활동 5줄이다. TurnRecord 와 tool audit 는 지금도 엄격해서 같다.
  - 이 RFC 는 엄격한 쪽을 따른다. 그 파일은 저장소가 쓴 것이 아니다. 운영 설치의 Keeper 저장소와 도구 호출 원장에는 지금 그런 파일이 없다(2026-11-18 에 `find` 로 확인). 값이 달라지는 경우로 §7 에 적는다.
- 칸으로 만든 행 값은 지금 reader 가 파일에서 만든 값과 같아야 한다. 칸의 읽기가 `Ok` 이고 점으로 시작하는 `.jsonl` 이 없는 모든 상태에서 그렇다. 차분 시험이 이것을 본다(§5).
- 채우는 쪽은 저장소 잠금을 잡지 않는다. 지금의 끝 읽기는 풀 밖에서 부르면 풀에 IO 작업을 내고 기다린다(§1.2). 잠금을 쥔 채 그 작업을 기다리면, 같은 잠금을 기다리는 행 계산이 풀을 다 차지했을 때 아무도 진행하지 못한다(§6.6).
- 풀 밖에서 채울 때는 칸 읽기와 파일 읽기를 풀 작업 하나에 넣는다. 칸을 먼저 읽고 풀 자리를 기다리면, 기다리는 동안 들어온 쓰기 하나가 그 채우기를 버리게 만든다. 도구 호출 원장은 모든 Keeper 가 쓴다. 그래서 바쁠 때 그 칸이 빈 채로 남고, 행마다 파일을 읽게 된다.
- 채우기는 칸 하나에 재시작 뒤 한 번, 비운 뒤 한 번이다. 여러 행이 같은 칸을 동시에 채울 수 있다. 그중 하나만 들어가고, 나머지는 파일을 한 번 더 읽은 셈이 된다.
- 가장 최근 Turn tool audit 행을 채울 때는 metrics 저장소를 끝에서부터 거꾸로 훑는다. 잠금을 쥐지 않으므로 heartbeat 쓰기를 막지 않는다. 훑는 동안 그 Keeper 의 metrics 쓰기가 끼면 그 채우기는 들어가지 않고, 다음 읽기가 다시 채운다. 채워진 뒤에는 Turn 행 쓰기만 값을 바꾼다. 이 칸은 쓰기가 실패했거나 지우는 쪽이 돈 뒤에만 다시 훑는다.
- 비우기: 지우는 쪽은 끝나는 모든 경로에서 그 저장소의 칸을 모두 비운다. 저장소 잠금은 필요 없다. 지우는 도중에 파일을 읽은 채우기는 compare-and-set 에서 실패하거나, 넣더라도 뒤따르는 비우기에 덮인다.
  - 지운 수나 결과를 보지 않는 까닭이 있다. 날짜 파일 prune 은 달마다 지우고, 다음 달을 열다가 예외로 끝날 수 있다(`dated_jsonl_retention.ml:5-22`, `retention_directory.ml:45-49`). 지금 `on_pruned` 는 그때 불리지 않는다(§1.4). 대시보드 purge 는 앞의 것을 지운 뒤 첫 `Error` 에서 멈춘다(`server_dashboard_http_delete_actions.ml:705-707`, `:744-746`).
  - 기동 때와 24시간 prune 은 같은 함수를 탄다. 저장소마다 잠금을 푼 뒤 비운다(`server_runtime_startup_maintenance.ml:50-62`, `dated_jsonl.ml:2165-2181`). 도구 호출 원장의 prune(`Root.Tool_calls`)은 그 workspace 의 칸을 비운다.
  - 대시보드 purge 와 runtime 디렉터리 지우기는 끝나는 모든 경로에서 `Dated_jsonl.directories_removed` 를 부른다. 모든 저장소의 칸을 비우고, 글자마다 기억한 디렉터리 이름(§3.2)을 모두 지운다. 어느 파일까지 지웠는지 보지 않는다. 같은 자리에 대소문자만 다른 이름으로 다시 만든 디렉터리를 옛 이름으로 찾지 않게 하려는 것이다.

### 3.5 행과 루프에서 바뀌는 것

- trust, tool audit, 최근 활동, context, blocker 와 `masc_keeper_list` 의 receipt 는 칸을 읽는다. `Dated_jsonl` 저장소는 `read_fact` 로, 결정 기록은 `Keeper_row_facts` 로 읽는다.
- 행 하나에서 registry 와 승인 큐를 한 번씩만 읽는다. receipt 칸도 한 번만 읽고, 두 reader 가 그 값을 같이 쓴다. metrics 120줄 칸도 행이 한 번 묻고, 그 답을 tool audit 와 최근 활동에 넘긴다(`~newest_lines`). 두 reader 는 스스로 묻지 않는다.
- 이 값들만 읽는 행 helper 에서는 `read_policy` 의 뜻이 없다. 쓰는 중이 아니면 메모리 값이 파일과 같아서다. tool audit helper(`Operator_control_snapshot_tool_audit.read`)는 `read_policy` 를 받지 않고, 자기 몫의 10초 캐시와 그 캐시를 채우던 pool job 이 없다. 그래서 그 캐시의 timeout 이 만들던 `timed_out` 상태도 없다. 칸이 든 값은 메모리에서 답한다. 칸이 비었으면 저장소의 job 하나로 파일을 읽어 채운다. 엄격한 읽기가 거부하는 저장소는 칸이 채워지지 않아서 부를 때마다 그 읽기를 한다. trust helper 는 아래 캐시 때문에 `read_policy` 를 받는다. quarantine inventory(`operator_control_snapshot.ml:674-689`), snapshot 캐시(`:789-793`), briefing, execution 의 `read_policy` 는 그대로 둔다.
- tool audit 는 Keeper 행, briefing(`dashboard_briefing_assembly.ml`), Keeper 상세(`keeper_status_detail.ml`)가 같은 함수(`latest_tool_audit_snapshot_from_files`)로 읽는다. 셋이 같은 칸을 읽는다(L3a).
- 10초 trust 캐시(`operator:keeper-runtime-trust:compact:v1:*`)는 승인 audit 와 workspace 대기 승인 목록 읽기도 덮는다(`keeper_runtime_trust_snapshot.ml:689-702`). 이 RFC 는 그 둘을 옮기지 않는다. 그래서 §8.1 이 정해질 때까지 캐시는 그 둘 몫으로 남긴다.

## 4. 층

층마다 부르는 길이 이어진 채로 들어간다. 부르는 곳이 없는 층은 만들지 않는다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | meta 를 Owner projection 에서 얻는다. 세 소비자(`keepers_json`, board address, `masc_keeper_list`)의 파일 읽기 자리만 왕복 함수로 바꾼다(§3.1). snapshot 의 훑기는 그 뒤에 같은 읽기로 옮겼다(#53113). Owner 는 됐는지 모르게 끝난 meta 쓰기를 `Atomic` 으로 내놓는다 | 소비자마다 파일 meta 로 만든 결과와 Owner meta 로 만든 결과가 같다. 넣는 Keeper 는 셋이다. 설정 필드가 자리 채움 값과 다른 TOML 을 가진 Keeper, 서버가 도는 동안 TOML 에서 key 를 뺀 Keeper, 기동 뒤 Owner 가 아직 meta 를 쓰지 않은 Keeper. 왕복 전제 시험: 만든 meta 와 시험 fixture 파일에서 decoder 가 낸 값을 한 번 더 왕복해도 같다. Owner 가 없는 Keeper 는 지금과 같은 결과가 나온다. meta 쓰기가 `Error` 나 예외로 끝난 Keeper 의 행은 파일 값을 보인다. 운영: 느린 행 로그의 `meta` 가 0 ms 다 |
| W | 줄 쓰기 함수가 규칙 11 을 지킨다. 병합됐다(#52991). 그 리뷰의 후속은 #53017 이다 | `test_fs_compat_fd_cache`, `test_fs_compat_append_jsonl_atomicity` |
| L2 | 먼저 깔 것이 셋이다. 저장소 선언의 곁 파일 이름(§3.4), file system 이 부르는 이름으로 만든 등록부 key(§3.2), 따로 만든 잠금 handle 의 읽기 전용 타입(§3.2). 그 위에 칸(`Fact_cell`)과 `Dated_jsonl` 의 사실, 값 넷(최근 TurnRecord, 가장 새 온전한 receipt, 도구 호출 16줄, 결정 기록 마지막 행)을 둔다. `Dated_jsonl` 의 쓰는 함수 둘이 등록부 항목의 칸을 맞춘다. 결정 기록 칸의 표(`Keeper_row_facts`). 결정 기록 tail 의 결과 읽기(§3.4). 지우는 쪽이 끝나는 모든 경로의 비우기. 읽는 쪽 trust·context·blocker·`masc_keeper_list` | 차분 시험, 동시 시험, 칸 정체 시험, 잠금을 쥔 채 채우는 시험, 파일을 지운 뒤 두 번째 읽기 시험, 취소 시험, 지우다 실패하는 시험, `step` 단위 시험, TLA+ 정상·버그 cfg(§5). 운영: 느린 행 로그의 `trust` 가 0 ms 근처다. 채우기 시도 수와 들어간 수를 칸마다 적는다. 어느 칸의 들어간 수가 늘 0 이면 그 칸은 채워지지 않는 것이다 |
| L3a | 가장 최근 Turn tool audit 행 칸(`Dated_jsonl.newest_selected`). metrics 저장소를 쓰는 곳을 따라가 보고 kept 로 적는다. 읽는 쪽은 Keeper 행·briefing·Keeper 상세의 tool audit 다. `Tool_audit_cache` 를 지운다 | 차분 시험(회전, 날짜 prune, 쓰기 뒤의 바이트 prune 포함), heartbeat 시험, purge 뒤 heartbeat 만 쓴 후계 시험 |
| L3b | metrics 끝 120행 칸(`Dated_jsonl.last_lines`). 읽는 쪽은 최근 도구 이름, 최근 활동, 대시보드의 metrics 창이다 | 차분 시험(400걸음, 바이트 한도 포함), `test_keeper_metrics_lines_kept`(파일 없이 읽기, 120줄 창, 거부된 저장소, 기다리지 않음). 운영: 느린 행 로그의 `audit` 가 0 ms 근처다 |
| L3c | `Dated_jsonl.latest_view` 를 지운다. L3a 뒤로 부르는 곳이 없다 | 지운 이름을 `rg` 로 찾으면 0 |
| L4 | 지우기: 행 helper 의 Current/Reuse 구분, 행 몫의 audit 10초 캐시, `dt_profile`, 행 안의 중복 읽기. 그 뒤 남은 행 일(승인 audit, quarantine 원장)을 잰다 | 지운 이름을 `rg` 로 찾으면 0. 남은 행 일의 sub-op 를 로그로 센다 |

L2 는 W 에 기댄다. 규칙 11 없이 칸을 두면 실패한 쓰기 하나가 칸을 파일과 어긋나게 한다(§3.3). L1 은 W 에 기대지 않는다.

줄 쓰기 함수는 이 RFC 밖의 저장소에도 걸린다(§1.4). 그 가운데 cost 기록은 서버와 CLI 가 같이 쓴다. 줄 쓰기는 파일 잠금을 잡지 않는다. 그래서 다른 process 와는 틈이 둘 남는다.

- 길이를 읽고 쓰기 전에 남이 끊긴 줄을 남기면, 내 줄이 거기에 붙는다. 마지막 바이트를 먼저 읽은 길이 자리에서 읽기 때문이다.
- 길이를 보고 자르기 전에 남이 덧붙이면, 그 줄이 같이 잘린다. 그 사이에 남이 자기 실패한 쓰기를 되돌리면, 자르기가 파일을 다시 늘리고 그 자리는 0 바이트가 된다.

앞의 틈은 길이 읽기부터 쓰기까지 system call 넷에 걸친다. 뒤의 틈은 둘 사이다. 이 틈 밖에서는 남의 덧붙임이 파일 길이로 보여서 자르지 않는다. 이 RFC 의 저장소는 쓰는 process 가 하나라 이 틈이 없다. 틈을 없애려면 파일 잠금이 필요하고, 쓰기마다 system call 이 둘 더 든다. cost 기록에서 잰 근거가 없어 이 RFC 는 넣지 않는다.

`_keeper_sem` 과 `MASC_KEEPER_SNAPSHOT_CONCURRENCY` 는 L4 의 측정 뒤 정한다. 행마다 승인 audit 일이 남아 있는 동안 세마포어를 지우면 그 일이 한꺼번에 몰린다.

## 5. 검증

**차분 시험.** 실제 쓰기 함수(`append_decision_record`, `log_call`, receipt `append`, TurnRecord `write`, `append_keeper_metrics`)와 돌리기, prune, purge, runtime 디렉터리 지우기, 채우기를 무작위 순서로 부른다. 한 걸음마다 두 가지를 본다. 첫째, `Filled` 값이 그 칸의 읽기(§3.4 의 표)로 파일에서 다시 계산한 값과 같다. 둘째, 칸으로 만든 행 값이 지금의 reader 가 파일에서 만든 값과 같다. reader 는 `latest_decision_json`, `read_latest ~keeper_name`, receipt 의 두 reader, TurnRecord 최근 읽기, tool audit 읽기, 최근 활동이다. tool audit 는 캐시를 비운 채 읽는다(§3.4). 도구 호출 원장은 색인 reader 를 한 번 부른 디렉터리로 돌린다. 색인 파일이 있어야 운영과 같다. 칸의 읽기가 `Error` 인 걸음에서는 칸이 채워지지 않았는지만 본다. 시험마다 base path 를 새로 만들어서 `reset_for_tests` 를 쓰지 않는다. 넣는 입력은 이렇다.

- 결정 기록 줄 길이: 창 크기 근처.
- object 가 아닌 줄, 목록 창 가운데의 깨진 줄, 끝이 줄 중간에서 끊긴 파일.
- 크기 회전: metrics 는 `max_bytes` 를 켠다. 도구 호출 원장은 16 MB 에서 돈다(`keeper_tool_call_log.ml:630`). 그 크기를 채우는 대신 `append_rotating` 을 작은 크기로 부른다.
- 실패하는 쓰기(W 의 시험과 같은 방법)와, 몇 개를 지운 뒤 실패하는 prune·purge.
- 읽기가 실패하는 저장소: 목록을 얻을 수 없는 달 디렉터리, 읽을 수 없는 날짜 파일, symlink 로 된 날짜 파일. 채우기가 값을 넣지 않아야 한다.
- 마지막 줄이 깨진 receipt 저장소. 두 reader 모두 그 앞의 receipt 를 내야 한다.
- 점으로 시작하는 `.jsonl` 이 있는 달 디렉터리. 칸으로 만든 값이 엄격한 읽기와 같아야 한다. 지금의 너그러운 reader 와는 다르다(§3.4).
- 읽기 색인 파일이 있는 도구 호출 원장 디렉터리. `tool_calls` 칸이 채워져야 한다. 선언에 없는 낯선 이름을 넣으면 채워지지 않아야 한다.

결정 기록의 차분 시험은 `test_keeper_decision_row_kept` 에 있다(L2d-4). 300걸음이다. 짧은 행, object 가 아닌 행, 창보다 한 바이트 짧은 행과 창과 같은 길이인 행, 창보다 긴 행, 돌리기, 손으로 쓴 깨진 줄과 끊긴 줄, 손으로 지운 파일이 섞인다. 손으로 바꾼 뒤에는 `decision_records_removed` 를 부른다. 같은 파일의 시험 열다섯이 따로 고정한다. 든 행은 파일 없이 읽힌다. 쓴 행이 든 행을 바꾼다. 돌린 뒤의 행도 든다. object 가 아닌 행과 창 길이 이상인 행은 들지 않는다. 실패한 쓰기와 못 읽은 파일은 아무것도 남기지 않는다. 두 표기가 한 칸에 닿는다. 표기 다섯(`.` 조각, 겹친 `/`, 상대 경로, 디렉터리 symlink, 대소문자)은 같은 파일일 때만 그 칸에 닿는다. 없는 파일로 가는 링크로 만든 기록은 두 칸을 비운다. 돌린 뒤와 실패한 쓰기 뒤에는 기억한 이름을 다시 묻는다. 다른 writer 에게 추월당한 writer 는 칸을 비운다. purge 가 든 행을 비우는 것은 `test_keeper_shutdown_official_client_purge` 가, 말하지 않은 process 가 매번 파일을 읽는 것은 `test_keeper_runtime_trust_snapshot` 이 본다.

- 로컬에서는 진짜 칸 모듈과 진짜 tail 읽기에 대역 writer 를 붙여 무작위 2000걸음을 씨앗 넷으로 돌렸다. 두 표기를 섞어 쓰고 읽었다. 든 행을 파일과 견준 것이 씨앗마다 2100번쯤이다. 변이 다섯(길이를 보지 않는다, 쓴 줄로 옮기지 않는다, 표기마다 칸을 둔다, 지움이 칸을 남긴다, 알 수 없는 줄에 '행 없음'을 든다)이 모두 14걸음 안에 걸렸다.
- 돌린 뒤 기억한 이름을 지우는 일은 기록 경로를 symlink 로 만들어 고정한다. 돌리기가 링크를 옮기고 다음 쓰기가 일반 파일을 만들므로, 어느 file system 에서나 경로의 이름이 바뀐다.

**동시 시험.** domain 둘이 같은 저장소에 N 줄씩 쓰는 동안 셋째 domain 이 채우기와 비우기를 되풀이한다. 끝나면 `Filled` 값이 파일에서 다시 계산한 값과 같다. 목록 값에 같은 행이 두 번 들어가지 않는다. 크기 회전을 켠 채로도 돌린다.

**칸 정체 시험.** 같은 저장소를 다른 표기로 두 번 연다. 표기는 다섯이다. 상대 경로, 끝의 `/`, base path 를 가리키는 symlink, root 아래 조각의 symlink, 대소문자만 다른 Keeper 이름. 두 handle 이 같은 칸을 받는 것은 두 글자가 한 디렉터리일 때뿐이어야 한다. 한 디렉터리인지는 device 와 inode 로 견준다. 대소문자 표기는 file system 에 따라 답이 다르고, 시험은 그 답을 따른다. 한쪽으로 쓰고 다른 쪽으로 읽어 차분 시험을 한 번 돌린다. 디렉터리가 없을 때 연 handle 이 디렉터리가 생긴 뒤 그 저장소의 칸을 받는지도 본다. 없는 조각을 지나는 표기(`없는 조각/..`)로 쓴 줄과, 지우기와 겹친 쓰기도 넣는다. 결정 기록 칸도 같은 표기들로 본다. `Reader` 는 칸을 받지 않아야 한다.

**잠금을 쥔 채 채우는 시험.** 시험이 저장소 잠금을 잡은 채로 빈 칸을 채우게 한다. 채우기가 끝나야 한다. 채우는 쪽이 잠금을 기다리면 이 시험은 멈춘다.

**쓰는 process 가 아니면 들지 않는다는 시험.** 쓰는 쪽이라고 말하지 않는 실행 파일(`test_dated_jsonl`)에서 `read_fact` 를 두 번 부르면 둘 다 파일을 읽은 답이다. 저장소를 거치지 않고 파일에 덧붙인 줄이 다음 답이다. 이 시험의 저장소는 값을 드는 종류(Keeper `Turn_records`)다. 파일에서 읽는 종류면 말하든 안 하든 답이 같아서 아무것도 막지 못한다. 처음부터 값을 들게 바꾼 변이는 이 시험에서 죽고, 말해도 들지 않게 바꾼 변이는 `test_dated_jsonl_kept_facts` 에서 죽는다.

- TUI 의 진입점도 본다. `test_tui_context_state` 는 TUI 가 링크하는 모듈을 그대로 링크하고, TUI 처럼 lease 를 쥐었다고 말하지 않는다. `Masc_tui_context_state.load` 를 부르고, 파일에 TurnRecord 한 줄을 덧붙이고, 다시 부른다. 두 번째 답이 덧붙인 줄이어야 한다.
- 다른 process 가 쓰는 저장소는 말한 process 에서도 들지 않는다. `test_dated_jsonl_kept_facts` 는 cost 기록 저장소에서 같은 순서를 돌린다. 값을 드는 저장소의 목록도 같은 시험이 고정한다. 목록에 저장소를 더하면 이 시험이 바뀐다.
- 놓은 lease 는 말하지 못한다(`test_server_startup_takeover`).
- 서버가 실제로 말하는지는 시험으로 고정하지 못했다. 말하는 줄은 `bin/main_eio.ml` 과 `bin/main_stdio_eio.ml` 에 있고 시험은 실행 파일을 링크하지 못한다. 그 줄이 빠지면 그 실행 파일은 매번 파일을 읽는다. stdio 런타임이 L3a 까지 그랬다. 값은 맞고 느려진다. `masc_dated_jsonl_fact_reads_total` 의 `read_not_kept` 가 늘어나는 것으로 보인다.

**파일을 열지 않는다는 시험.** 값을 채운 뒤 그 파일을 지우고 행을 다시 만든다. 두 번째 행이 첫 번째와 같으면 읽는 쪽이 파일을 열지 않은 것이다. 이 시험은 §7 의 한계(서버가 돌 때 손으로 지운 파일은 재시작까지 안 보인다)도 그대로 보여 준다.

**취소 시험.** 쓰기가 줄을 쓴 뒤 칸을 고치기 전에 취소되게 한다. 칸이 비워져 있어야 한다.

**지우다 실패하는 시험.** prune 과 purge 가 파일을 몇 개 지운 뒤 실패하게 한다. 그 저장소의 칸이 비워져 있어야 한다.

**heartbeat 시험.** `turn_audit` 이 `Filled` 인 동안 heartbeat 행을 계속 쓴다. 칸이 비워지지 않고 값이 그대로다. 그 사이 Turn 행을 쓰면 값이 그 행으로 바뀐다. 저장소 층에서는 `test_dated_jsonl_kept_facts` 의 「the newest row a selection selects」 다섯이 본다. 고른 행은 값이 되고, 지나친 행은 든 값을 그대로 둔다. 날짜 파일을 몰래 지워도 답이 같으니 파일을 열지 않은 것이다. 크기 회전 뒤에도 든다. 400걸음 무작위 시험도 이 사실을 걸음마다 엄격한 찾기와 견준다. Keeper 층에서는 `test_keeper_turn_tool_audit_kept` 가 실제 쓰는 함수(`append_keeper_metrics`)로 같은 것을 본다.

**`step` 단위 시험.** `step` 은 읽어 둔 값, 쓴 줄, 쓴 날짜 파일만 받는 순수 함수다. 표로 넣어 결과를 본다. 지난 날짜 파일에 쓴 줄, Turn 이 아닌 metrics 행, 깨진 줄이 든 목록이 들어간다.

**TLA+.** `KeeperRowFacts.tla` 에 쓰는 쪽 둘, 채우는 쪽 하나, 지우는 쪽(prune·purge) 하나를 둔다. 저장소는 파일의 열이다(지금 쓰는 파일과 회전으로 닫힌 파일). 파일은 줄의 열이고, 줄에는 종류가 있다(Turn, 그 밖, 깨진 줄). 가장 새 파일의 마지막 줄은 줄바꿈 없이 끝날 수 있다. 그 줄은 온전한 행일 수도, 깨진 조각일 수도 있다. 칸은 `{ generation, slot }` 이고, 사실은 끝 K 줄(K = 2)과 가장 최근 Turn 행 둘이다.

- 쓰는 쪽의 칸 읽기, 회전, 파일 쓰기, 칸 맞추기, 실패, 취소는 따로 떨어진 걸음이다. 쓰기는 규칙 11 대로 움직인다. 끝이 끊긴 파일에는 줄바꿈부터 쓴다. 실패하면 파일을 그대로 두거나 끊긴 조각만 남긴다.
- 채우는 쪽의 칸 읽기, 파일 목록 얻기, 파일을 하나씩 열어 읽기, compare-and-set 도 따로 떨어진 걸음이다. 목록을 얻은 뒤 회전이 끼면 옛 이름으로 연다. 읽기는 실패할 수 있다. 실패한 읽기는 빈 파일을 읽은 것처럼 보인다. 채우는 쪽은 실패를 알고 넣지 않는다. 실패는 읽기 한 번의 결과로 그린다. 저장소가 한동안 실패하는 상태로 그리고 그동안 불변식을 쉬게 하면 (l) 을 잡지 못한다. 불변식은 파일 내용을 두고 말하므로(규칙 3), 실패한 읽기를 넣은 그 걸음에서 어긋난다.
- 지우는 쪽은 오래된 파일부터 몇 개를 지우거나 모두 지운다. 도중에 실패해 멈출 수 있다. 지우기와 비우기는 따로 떨어진 걸음이다. prune 은 저장소 잠금 안에서 지우고, 잠금을 푼 뒤에 비운다. purge 는 잠금 없이 지운다. 지우는 쪽을 잠금 안의 한 걸음으로 그리면 (k) 를 잡지 못한다.
- 쓰는 쪽 둘은 cfg 둘로 돌린다. 저장소 잠금으로 안 섞이는 cfg 와 잠금이 없는 cfg(결정 기록)다. 잠금이 없으면 쓰기 순서와 compare-and-set 순서가 엇갈릴 수 있다. 잠금이 있는 cfg 는 쓰는 쪽 하나가 세 줄을 쓴다. 잠금 안의 두 쓰는 쪽은 차례로 쓰는 한 쪽과 같은 상태를 지난다. 쓰는 쪽 둘로도 한 번 돌려 확인했다.
- 칸은 채우는 쪽이 처음 볼 때 생긴다. 쓰는 쪽과 지우는 쪽은 있는 칸만 고친다. 쓰는 쪽은 칸을 읽을 때 칸이 있었는지를 같이 적어 둔다.

칸은 저장소 하나에만 걸리므로 모델은 저장소 하나로 충분하다. 여러 저장소를 지우는 일은 저장소마다 지우고 비우는 일을 잇달아 하는 것이다. 불변식은 "파일을 바꾸는 중인 쪽이 없고 칸이 `Filled` 면, 값은 파일에서 계산한 값과 같다"이다. `Next` 는 §2 의 규칙대로 움직이고 불변식을 지킨다. 버그 후보는 열넷이다. 후보마다 정상 걸음 하나를 바꾼 cfg 가 있다(`KeeperRowFacts-<이름>-buggy.cfg`).

- (a) 채우는 쪽이 compare-and-set 없이 그냥 넣는다.
- (b) 쓰는 쪽이 `Unfilled` 에 자기 행을 넣는다.
- (c) 쓰는 쪽이 파일을 바꾼 뒤에 칸을 읽고, compare-and-set 이 실패하면 다시 읽어 행을 더한다.
- (d) 지우는 쪽이 파일을 지운 뒤 칸을 비우지 않는다.
- (e) 지우는 쪽이 도중에 실패하면 칸을 비우지 않는다.
- (f) 실패하거나 취소된 쓰기가 칸을 비우지 않는다.
- (g) 값을 바꾸지 않는 쓰기가 `Unfilled` 칸의 세대를 올리지 않는다.
- (h) 쓰는 쪽이 끊긴 줄 뒤에 줄바꿈 없이 이어 쓴다(#52974 의 모양).
- (i) 실패한 쓰기의 바이트가 다음 쓰기 앞에 붙거나, 쓰는 쪽 없이 파일에 들어간다(#52980 의 모양).
- (j) 목록 칸이 깨진 줄을 빼고 든다.
- (k) 쓰는 쪽이 compare-and-set 에 실패한 뒤 칸을 비우지 않고 자기가 만든 값을 넣는다.
- (l) 채우는 쪽이 실패한 읽기를 빈 값으로 넣는다.
- (m) 쓰는 쪽이 쓰는 도중에 생긴 칸을 그대로 둔다.
- (n) 칸을 든 process 가 그 저장소를 혼자 쓰지 않는다. 다른 process 의 줄이 파일에 들어가고 아무도 칸을 돌지 않는다(#53145 의 모양). 정상 모델에는 process 가 하나뿐이다. 칸을 드는 쪽이 파일을 바꾸는 유일한 쪽이라는 것이 §3.2 의 두 사실이다.

버그 cfg 는 후보마다 불변식을 어겨야 한다. 버그 cfg 가 통과하는 후보가 있으면 모델이 그 경우를 그리지 못한 것이다. 후보를 빼지 않고 모델을 고친다. 후보마다 어기는 사실이 다르다. (b)는 끝 K 줄에서만 어기고, (g)는 가장 최근 Turn 행에서만 어긴다. (k) 는 두 경우에 어긴다. 지우는 쪽이 쓰는 쪽의 칸 읽기와 칸 맞추기 사이에 비우기를 끝낼 때와, 잠금 없는 쓰는 쪽 둘이 엇갈릴 때다. 읽어 둔 칸이 `Unfilled` 인 쓰는 쪽은 `Unfilled` 를 넣으므로, 채우는 쪽과 겹치는 것만으로는 어기지 못한다. 버그 cfg 는 후보마다 두 사실의 불변식을 모두 확인한다. 정상 cfg 와 버그 cfg 를 둘 다 돌린다. 풀 용량 때문에 멈추는 일(§6.6)은 안전 불변식으로 잡히지 않는다. 그래서 "잠금을 쥔 채 채우는 시험"이 대신 지킨다. 시계가 뒤로 간 쓰기는 모델에 넣지 않고 `step` 단위 시험으로 본다.

**운영 측정.** 재시작 뒤 34분 창에서 센다. 창 안의 TurnRecord 쓰기 수를 같이 적어 Keeper 활동량이 비슷한 창끼리 비교한다.

| 무엇 | 지금 | 목표 |
|---|---|---|
| 느린 행 로그의 sub-op 중앙값 trust·audit·meta | 186·164·23 ms | L1~L3 뒤 0 ms 근처 |
| 300 ms 넘는 Keeper 행 | 867 | 준다. 승인 audit·quarantine·candle 이 남아 0 을 목표로 두지 않는다 |
| Keeper 화면 TUI 요청의 1초 넘음 | `/keepers/turns` 15, `/gate/keepers` 3, `/dashboard/health-line` 1 | 관찰만 한다. 이 요청들은 다른 원인도 있어 이 RFC 의 결과로 세지 않는다 |
| 채우기 시도 수와 들어간 수 | 없다 | L2·L3 에서 칸마다 센다. 들어간 비율을 PR 에 적는다 |

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

   실패한 쓰기의 바이트가 나중에 들어오는 문제(#52980)는 칸으로 견딜 수 없다. 그래서 쓰는 함수를 고쳤다(#52991). 같은 수리가 쓰기를 줄 처음에서 시작하게 한다. 칸은 파일 끝 상태를 들 까닭이 없다.
9. **읽기 색인을 원장 디렉터리 밖으로 옮긴다.** 디렉터리에 날짜 파일만 남아서 선언이 필요 없다. 다만 설치마다 옛 색인 파일이 그 자리에 남는다. 그 파일을 지우는 코드는 migration 이다. 안 지우면 엄격한 목록이 계속 실패한다. 색인은 파생 값이라 그것 때문에 fresh state 를 요구할 까닭이 없다. 그래서 이름을 선언하는 쪽을 골랐다(§3.4).
10. **표기가 다른 경로를 그대로 둔다.** 운영에서 표기가 갈리는 곳은 지금 없다(§3.2). 하지만 갈리면 칸 하나가 재시작까지 옛 값을 보인다. 오류 없이 틀리는 실패라 리뷰로만 지키지 않는다.

## 7. 대가와 한계

- 메모리: Keeper 마다 결정 기록 1행, receipt 1행, TurnRecord 1행, metrics 121행이고, workspace 마다 도구 호출 16행이다. 행 크기는 재지 않았다. L3 에서 Keeper 하나의 metrics 값 크기(`Obj.reachable_words`)를 재서 PR 에 적는다.
- 쓰는 쪽이 조금 길어진다. 그 저장소의 칸마다 칸 읽기 한 번과 compare-and-set 한 번이 늘어난다. 잠금 안에서 늘어나는 일은 이 `Atomic` 연산과 새 값 계산뿐이다. 파일 일이나 기다림은 늘지 않는다.
- 쓰는 쪽은 쓴 줄을 읽는 쪽 parser 로 한 번 해석한다. 줄 크기에 비례하는 일이다. L2 에서 도구 호출 줄의 크기와 해석 시간을 재서 PR 에 적는다.
- 파일을 바꾸는 중에는 칸이 파일과 잠깐 다를 수 있다. 줄은 썼고 칸은 아직 안 맞춘 사이가 그렇다. 결정 기록을 두 곳이 같이 쓰면, 먼저 쓴 쪽이 칸을 먼저 맞춰 칸이 앞 행을 잠깐 보일 수 있다. 늦게 온 쪽이 칸을 비운다. 불변식은 바꾸는 쪽이 없을 때만 말한다.
- 쓰기가 실패하면 그 저장소의 칸이 모두 비워지고, 다음 읽기가 파일을 읽는다.
- 쓰기와 채우기가 겹치면 그 채우기는 들어가지 않고, 다음 읽기가 파일을 읽는다. 재시작 직후 첫 읽기도 파일을 읽는다. 같은 칸을 여러 행이 동시에 채우면 파일 읽기가 겹친다.
- 쓰기가 잦은 저장소에서는 채우기가 compare-and-set 에서 여러 번 질 수 있다. 진 채우기도 그 행에는 맞는 값을 쓴다. 다만 다음 행이 파일을 다시 읽는다. L2·L3 운영 측정에서 채우기 시도 수와 들어간 수를 센다(§5).
- 24시간 prune 이 돌면 지운 것이 없어도 그 저장소의 칸이 비워진다. 칸마다 하루에 한 번 파일을 다시 읽는다.
- Keeper 하나를 purge 하면 모든 저장소의 칸이 비워진다(§3.2). 칸마다 파일을 한 번 다시 읽는다.
- 없는 디렉터리의 이름은 기억하지 않는다(§3.2). 한 번도 쓰지 않은 저장소를 읽는 쪽은 읽을 때마다 `realpath` 로 조상을 찾는다.
- 줄 쓰기는 실패한 쓰기를 되돌린다. 되돌리지 못하는 때가 둘 있다. 자르기가 실패했거나, 파일 길이가 이 쓰기만 했을 때의 길이가 아니다. 그때는 바이트가 끊긴 조각으로 남고 오류가 그렇게 말한다(`docs/JSONL-CONTRACT-INVENTORY.md`).
- 줄 쓰기는 일반 파일을 읽기·쓰기로 연다. 쓸 수만 있고 읽을 수 없는 파일에는 덧붙이지 못한다. FIFO 같은 대상은 쓰기 전용으로 열고 그대로 쓴다.
- 줄 쓰기는 쓸 때마다 파일의 마지막 바이트를 읽는다. 호출 셋(`lseek` 둘, `read` 하나)이 든다. macOS 에서 200바이트 줄 10만 번을 21회 쟀다(load average 30). 최솟값으로 보면 쓰기 하나가 5.0~5.7 µs 다. 마지막 바이트를 읽지 않으면 3.7~4.1 µs 다. 파일 끝을 메모리에 기억하면 이 차이가 없다. 다만 다른 descriptor 가 파일을 같은 크기로 다시 쓰면 기억이 틀린다. 그래서 고르지 않았다.
- 값을 드는 것은 서버 process 뿐이다. TUI 가 파일에서 직접 읽는 context 는 이 RFC 로 빨라지지 않는다.
- 디렉터리가 없는 저장소를 읽은 값("줄 없음")도 든다. 그 뒤 디렉터리를 밖에서 통째로 옮겨 넣으면 그 저장소의 다음 쓰기나 재시작, purge 까지 "줄 없음"으로 보인다. 손으로 지우는 경우와 같은 부류다.
- 서버가 도는 동안 이 저장소를 손으로 지우면, 메모리 값은 그 저장소의 다음 쓰기나 재시작까지 옛 행을 보인다. 헌법 `runtime_data` 의 "지우고 새로 한다"는 멈추고 지우고 다시 띄우는 것이고, 이 RFC 는 그 순서를 그대로 지원한다. 서버가 돌 때는 대시보드 purge 로 지운다. purge 는 칸을 비운다.
- purge 는 파일을 다 지운 뒤에, 끝나는 모든 경로에서 칸을 비운다. 그 사이에는 지워지는 Keeper 의 든 값이 지워진 파일의 것이다. 그 Keeper 의 행은 이때 지워진 것과 아직 안 지워진 것이 섞여 있고, purge 가 끝나면 행이 없어진다. 그래서 저장소마다 따로 비우지 않는다.
- 다른 코드가 이 저장소를 열어 바로 쓸 수 있다. `Dated_jsonl.open_store`·`append` 와 `Store.keeper` 는 공개다(`dated_jsonl.mli:72`, `:99`, `dated_jsonl_store.mli:76`). 그러면 메모리 값이 틀린다. 차분 시험은 이름 붙인 쓰는 함수만 부른다. §8.4 가 이 구멍을 다룬다.
- 칸은 지우지 않는다. 한 번 만든 칸은 process 가 끝날 때까지 남는다. 수의 상한은 그동안 읽은 저장소 수다. Keeper 하나에 넷(결정 기록, receipt, TurnRecord, metrics), workspace 하나에 하나다. purge 한 Keeper 의 칸은 `Unfilled` 로 남는다.
- reader 가 읽을 때마다 남기던 보고가 준다. 깨진 줄이나 읽기 오류를 세는 곳은 지금 행을 만들 때마다 같은 줄을 다시 센다. 칸에서 읽으면 채울 때만 센다. L2 에서 그 수를 쓰는 화면과 알림을 찾아 PR 에 적는다.
- `keepers_json` 의 설정 필드는 지금처럼 자리 채움 값으로 보인다(§3.1, #53007). `masc_keeper_list` 와 board address 는 지금처럼 TOML 을 덮은 값을 보인다. 이 RFC 는 어느 쪽도 고치지 않는다.
- 파일 읽기가 실패하는 동안 행이 보이는 값이 달라진다. 지금은 meta 를 못 읽으면 `Keeper_unread` 고, 다른 묶음은 오류나 빈 값이다. 옮긴 뒤에는 Owner 와 칸이 든 값을 보인다. 마지막으로 쓰거나 읽은 내용이다.
- 점으로 시작하는 `.jsonl` 이 있는 저장소에서는 값이 달라진다(§3.4). 지금의 너그러운 reader 는 그 파일의 줄도 읽는다. 칸은 읽지 않는다.
- tool audit 의 read drop 보고(`surface=keeper_status_runtime_keeper_metrics`)는 metrics 저장소를 훑을 때 난다. 서버에서는 칸을 채울 때다.
- 있는 디렉터리의 이름은 적은 글자마다 처음 한 번만 묻는다(§3.2). 서버가 도는 동안 그 경로의 조각을 다른 곳을 가리키는 symlink 로 바꾸거나, 디렉터리를 지우고 대소문자만 다른 이름으로 다시 만들면, 기억한 이름이 옛 자리를 가리킨다. 손으로 파일을 지우는 경우와 같은 부류다. 서버가 Keeper 를 지울 때는 칸을 비우면서 그 기억도 지운다(§3.4).
- 도구 호출 원장 디렉터리에 선언하지 않은 곁 파일이 새로 생기면 `tool_calls` 칸이 채워지지 않는다. 행은 지금처럼 파일을 읽는다. 칸마다 세는 채우기 수가 그 상태를 보여 준다(§5).
- 결정 기록 행은 줄바꿈까지 39,999바이트 이하일 때만 든다(§3.3). 더 긴 행을 쓴 뒤에는 다음 읽기가 파일을 읽는다.
- metrics 줄 칸에는 바이트 상한이 없다. Keeper 마다 가장 새 120줄을 process 가 끝날 때까지 든다. metrics 행 하나의 크기에도 상한이 없다. 큰 행 하나는 그 뒤로 120줄이 쓰이면 칸에서 나간다. 운영 행의 크기는 재지 않았다.
- 결정 기록의 read drop counter(`surface=keeper_runtime_trust_decision_log`)는 서버에서 채울 때만 오른다. 지금은 행을 만들 때마다 같은 줄을 다시 센다. 저장소 안에 이 surface 를 읽는 화면이나 알림은 없다.
- 결정 기록의 경로를 볼 수조차 없을 때(지나는 디렉터리의 `EACCES`, `ENOTDIR`, `ELOOP`, `ENAMETOOLONG`) 읽는 쪽이 오류를 보고한다. 전에는 파일이 없는 것으로 보고 조용히 '행 없음'을 냈다. 파일은 있는데 열지 못하는 경우(권한 없는 파일)는 전에도 보고됐다. 행이 보이는 값은 모두 '행 없음'이다.
- 이 RFC 는 이 값들 밖의 읽기를 줄이지 않는다.

## 8. 정할 것

1. **승인 audit 와 quarantine 원장을 이 스택에 넣을지.** 권장: L2·L3 뒤에 잰 뒤 정한다. 승인 audit 에는 이미 증분 색인(RFC-0474 L4f)이 있어서 남은 비용이 목록 읽기뿐일 수 있다.
2. **Keeper 행을 SSE 로 나르는 일.** RFC-0477 §3.6 의 행 topic 은 `/gate/keepers?detailed=true`, 곧 `masc_keeper_list` 다. 이 RFC 는 L1·L2 에서 `masc_keeper_list` 도 같은 값(meta, 최근 receipt)을 읽게 한다. 권장: 이 RFC 는 값을 만들고, RFC-0477 이 나른다.
3. **이름 목록.** `keepers_json` 은 이름을 meta 파일 목록에서 얻는다. 권장: L1 에서는 그대로 두고 meta 값만 Owner 에서 읽는다. 이름 목록을 Owner registry 로 옮기는 일은 L4 뒤에 잰다.
4. **쓰기 권한을 타입으로 나눌지.** 지금은 아무 코드나 이 저장소에 쓸 수 있다. 권장: 저장소마다 그 층이 들어갈 때, 읽는 쪽에는 읽기 전용 handle 만 주고 쓰기 handle 은 쓰는 모듈만 갖게 한다. 대가: metrics 를 읽는 곳(`server_dashboard_http_keeper_api.ml:72`, `dashboard_http_keeper_feeds.ml:194`, `keeper_status_detail.ml:460`, `bin/masc_tui_metrics_tail.ml:170-173`)과 receipt·TurnRecord 를 읽는 곳을 고친다. 하지 않으면 "쓰는 곳이 하나"라는 전제를 리뷰로만 지킨다. 따로 만든 잠금으로 연 handle 은 이 결정과 상관없이 L2 에서 읽기 전용이 된다(§3.2).
5. **서버가 돌 때 손으로 지우는 일.** 권장: §7 대로 받아들이고 운영 문서에 적는다. 막는 장치는 더하지 않는다.
6. **행의 설정 필드를 TOML 값으로 보일지(#53007).** 권장: 이 RFC 에서는 값을 그대로 둔다. 보이는 값이 바뀌는 수리라 따로 근거를 붙여 고친다. 그때는 §3.1 의 변환 자리에서 TOML 값을 덮어쓰면 된다(`effective_meta_of_profile_defaults`). 대가: 그때까지 `activation_mode` 는 틀린 값을 계속 보인다.
