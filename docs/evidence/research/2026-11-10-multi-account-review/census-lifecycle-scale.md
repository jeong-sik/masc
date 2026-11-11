> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

기준 head: 85b8af5b0453 (worktree authz-d1-1-20261108) · 기록 시각: 2026-11-10 16:48 KST(07:48Z), 조사는 같은 날 이 시각 전 · 세는 방식: 코드에서 셈(rg + 파일 읽기), 서버에서 측정 안 함

# Census: Keeper lifecycle, scale, env, prompts

읽기만 했어요. 저장소 파일 수정, dune/opam 빌드, 상태를 바꾸는 git 명령, 운영 중인 서버의 runtime 디렉터리(`<base-path>/.masc`) 접근, 네트워크 호출은 하지 않았어요. 경로는 worktree 기준 상대 경로예요.

## 1. Keeper lifecycle

### 상태 타입 (closed sum)
- Keeper phase 8개: `Offline | Running | Failing | Draining | Paused | Stopped | Crashed | Restarting` — `lib/keeper_registry/keeper_state_machine_phase.mli:3`, 재수출 `lib/keeper_registry/keeper_state_machine_types.mli:1`
- 이벤트 13개(`Heartbeat_ok` … `Operator_clear_requested`) — `keeper_state_machine_types.mli:30`
- 전이표 `can_transition`: 모든 (from, to) 쌍을 나열 — `lib/keeper_registry/keeper_state_machine_types.ml:160-239`
- `apply_event` — `lib/keeper_registry/keeper_state_machine.ml:311`, `derive_phase` :31, `entry_actions_for` :139
- Turn phase 6개 + GADT witness — `lib/keeper_registry/keeper_registry_types_turn_phase.mli:5,21`
- Turn FSM 10상태(TLA parity 시험 있음) — `lib/turn_fsm/turn_fsm.mli:40`
- Decision stage — `lib/keeper_registry/keeper_registry_types_decision.mli:3`
- Lane outcome 6개(`Completed | Shutdown_before_start | Shutdown_requested | Shutdown_cancel_failed | Cancelled_by_parent | Failed`) — `lib/keeper/keeper_lane.mli:23`
- Lifecycle event — `lib/keeper_registry/keeper_lifecycle_events.mli:5,23`

명령:
```
rg -n '^type ' lib/keeper_registry/keeper_state_machine_types.mli lib/keeper_registry/keeper_registry_types_turn_phase.mli lib/keeper_registry/keeper_registry_types_decision.mli lib/keeper_registry/keeper_state_machine_phase.mli lib/keeper_registry/keeper_lifecycle_events.mli lib/turn_fsm/*.mli lib/runtime/runtime_attempt_fsm.mli
rg -n '^type outcome' -A10 lib/keeper/keeper_lane.mli
```

### 시작·정지·재시작
- 시작: `Keeper_keepalive.start_keepalive` — `lib/keeper/keeper_keepalive.ml:970`
  - owner domain이 아니면 owner domain으로 넘겨 실행 — :978-982
  - 등록 트랜잭션 `Keeper_keepalive_launch_transaction.run` — :1057
  - lane fork `Keeper_lane.fork_server_owned` — :1420 → `lib/keeper/keeper_lane.ml:252`
  - lane 안에서 gRPC heartbeat(:1432), board attention worker(:1438), egress proxy(:1443), heartbeat loop(:1452)
- 정지: `stop_keepalive` — `keeper_keepalive.ml:1512`, `stop_keepalive_and_await` — :1519
- 재시작: supervisor sweep Pulse `start_supervisor_sweep` — `lib/keeper/keeper_runtime.ml:745` → `Keeper_supervisor.sweep_and_recover` — `lib/keeper/keeper_supervisor.ml:121` → `launch_supervised_fiber` — `lib/keeper/keeper_supervisor_launch.ml:594`
- Autoboot: `fork_subsystem "keeper_autoboot"` — `lib/server/server_bootstrap_loops.ml:1938`, start_keepalive 호출 :2070, 실패분 retry loop :2132, supervisor sweep 시작 :2170

명령:
```
rg -n '^let (start|stop|restart|launch|spawn)[a-z_]*' lib/keeper/keeper_keepalive*.ml lib/keeper/keeper_supervisor_launch.ml lib/keeper/keeper_registry*.ml lib/keeper/keeper_process_switch*.ml
rg -n 'sweep_and_recover|supervisor_interval|sweep_interval|supervise_interval' lib bin --type ocaml
rg -n 'fork_subsystem "' lib/server/server_bootstrap_loops.ml
```

### 재시작 뒤 남는 것
- keeper meta: `.masc/keepers/<name>.json` — 경로 `lib/keeper/keeper_types_profile.ml:764`, 쓰기 `lib/keeper/keeper_meta_store.ml:34`(durable replace)
- keeper TOML: config 디렉터리 `keepers/<name>.toml`
- event queue: snapshot `event-queue-v19.json`, WAL `event-queue-transitions-v11.jsonl` — `lib/keeper_runtime/keeper_event_queue_schema.ml:34,40`, 경로 `keeper_event_queue_persistence.ml:129,133`
- chat: `.masc/keeper_chat/<name>.jsonl` — `lib/keeper/keeper_chat_store_paths.ml:4-10`
- tool usage: `keepers/tool_usage/<name>.json` — `lib/keeper/keeper_registry_tool_usage_persistence.ml:12-20`
- Keeper runtime store 12개(tool_usage, runtime-manifests, metrics, execution-receipts, turn-records, provider-inputs, memory-recall-artifacts, reaction-ledger, trajectories, crash-events, .shutdown-operations, .configuration-removals) — `lib/core/common.ml:109-150`
- `runtime_params.json` — `lib/core/runtime_params.ml:127`, boot에서 복원 `lib/server/server_runtime_bootstrap.ml:1121`

남지 않는 것:
- registry phase. `lib/keeper/keeper_registry_setup.ml:7-13` 주석(#26323): map은 매 boot `StringMap.empty`에서 시작하고 디스크에서 phase를 읽어 오는 곳이 없음.

### 상태 타입 위 catch-all
- Keeper phase 생성자 arm 뒤 10줄 안의 `| _ ->`: 5 files 매치, 전부 오탐(goal_phase 문자열 parse, lane_addon_action JSON 필드, keeper_status_runtime option, repo_manager_types, tui_decode_async_request).
- Turn phase·Turn FSM 생성자: 0.
- lifecycle 모듈의 `| _ ->` 17개: 전부 option/list/JSON/exception 대상. 예:
  - `keeper_state_machine_phase.ml:45` (`phase_of_string`)
  - `keeper_lifecycle_events.ml:66` (`event_of_string`)
  - `keeper_registry_types_turn_phase.ml:181` (예외 printer)
  - `keeper_operator_interrupt.ml:10` (예외 분류)
- 모든 variant를 나열한 곳: `keeper_runtime.ml:786-806`(TOML reconcile), `keeper_keepalive.ml:1002-1010`(stale entry 회수).

명령:
```
rg -U --pcre2 -c '\|\s*(?:Keeper_state_machine[A-Za-z_.]*\.)?(?:Running|Crashed|Restarting|Draining|Failing|Paused|Stopped|Offline)\b[^\n]*->[^\n]*\n(?:[^\n]*\n){0,10}?\s*\| _ ->' lib --type ocaml
rg -U --pcre2 -l '\|\s*(?:[A-Z][A-Za-z_]*\.)*(?:Turn_idle|Turn_prompting|Turn_routing|Turn_executing|Turn_finalizing|Turn_exhausted|Phase_gating|Runtime_routing|Awaiting_provider|Awaiting_tool_result|Completing)\b[^\n]*->[^\n]*\n(?:[^\n]*\n){0,10}?\s*\| _ ->' lib --type ocaml
rg -n '\| _ ->|\| _ when' lib/keeper_registry/ lib/turn_fsm/ lib/runtime/runtime_attempt_fsm.ml
rg -n '\| _ ->|\| _ when' lib/keeper/keeper_lane.ml lib/keeper/keeper_lifecycle_*.ml lib/keeper/keeper_supervisor*.ml lib/keeper/keeper_keepalive*.ml lib/keeper/keeper_heartbeat_loop*.ml lib/keeper/keeper_turn_fsm*.ml lib/keeper/keeper_turn_lifecycle.ml lib/keeper/keeper_runtime.ml lib/keeper/keeper_registry*.ml lib/keeper/keeper_shutdown*.ml
```

## 2. 프로세스 하나라는 전제

### base path 하나에 서버 하나
- `Unix.lockf F_TLOCK`. 파일 이름은 디렉터리 (st_dev, st_ino)의 SHA-256. 위치는 `<base>/<owner_lease_dirname>/masc-base-path-leases-v1-<uid>/`.
  - 디렉터리 정하기: `lib/server/server_startup_takeover.ml:225-262`
  - 획득: `acquire_base_path_lock_with` :934-1000
  - 프로세스 안 중복 확인: `Hashtbl base_path_leases` :187-193
- 획득하는 곳: `bin/main_eio.ml:267-311,378`. `lib/server/keeper_journal_preparation.ml:166,444,620`도 같은 잠금을 잡음.
- 같은 호스트 커널 잠금일 뿐이고 분산 lease는 없음. 다른 버전끼리의 배제는 운영자가 처리 — 주석 :962-967.

명령:
```
rg -n 'Unix\.lockf|flock|F_TLOCK|F_LOCK' lib bin --type ocaml
rg -n -i 'server.?lock|instance.?lock|base.?path.?lock|single.?(server|instance)|another server|already running|server_owner|owner_lock|pid.?file' lib/server lib/core lib/owner_process_identity lib/process bin/main_eio.ml --type ocaml
```

### module-level mutable 상태
지정 패턴(`P`): `^let [a-z_0-9]+ *(:[^=]*)?= *(ref |Atomic\.make|Hashtbl\.create|Mutex\.create|Eio\.Mutex\.create|Queue\.create|Weak\.)`

| 디렉터리 | P 줄 수(files) | 다음 줄 create(P2) | `Stdlib.*.create` 한 줄 | 합 |
|---|---|---|---|---|
| lib/keeper | 132 (87) | +35 | +47 | 214 |
| lib/runtime | 29 (17) | +5 | +3 | 37 |
| lib/server | 70 (42) | +17 | +21 | 108 |
| lib/core | 25 (9) | +3 | +2 | 30 |

- lib 전체 P: 599줄 / 298 files.
- lib/keeper_registry, lib/keeper_runtime은 별도 디렉터리라 위 표에 없음.

명령:
```
P='^let [a-z_0-9]+ *(:[^=]*)?= *(ref |Atomic\.make|Hashtbl\.create|Mutex\.create|Eio\.Mutex\.create|Queue\.create|Weak\.)'
rg -n "$P" lib/<dir> -g '*.ml' | wc -l ; rg -l "$P" lib/<dir> -g '*.ml' | wc -l
P2='^let [a-z_0-9]+ *(:[^=\n]*(\n[^=\n]*)?)?=[ \t]*\n[ \t]+(ref |Atomic\.make|Hashtbl\.create|Mutex\.create|Stdlib\.Mutex\.create|Eio\.Mutex\.create|Queue\.create|Weak\.)'
rg -U -c "$P2" lib/<dir> -g '*.ml'
rg -c '^let [a-z_0-9]+ *(:[^=]*)?= *Stdlib\.(Mutex|Hashtbl|Queue)\.create' lib/<dir> -g '*.ml'
```

### 살아 있는 handle을 쥔 registry
- `Keeper_registry_setup.registry` — Atomic StringMap — `lib/keeper/keeper_registry_setup.ml:13` (+ `running_count_atomic` :14)
- `Keeper_process_switch.switch` — `lib/keeper/keeper_process_switch.ml:6`
- `Keeper_owner_registry.pools` — `lib/keeper/keeper_owner_registry.ml:38`
- `supervisor_sweeps` (base path별 Pulse) — `lib/keeper/keeper_runtime.ml:724`
- microVM identity snapshots / lifecycle — `lib/keeper/keeper_turn_sandbox_runtime_registry.ml:30-40`
- run registries(Exact_lane, Verification, Goal_verification, Fusion) — `lib/run_registry_core/run_registry_core.ml:1103`, 설치 `lib/server/server_runtime_bootstrap.ml:812-844`
- MCP HTTP sessions — `lib/server/server_mcp_transport_http_session.ml:20`
- WS sessions — `lib/server/server_mcp_transport_ws.ml:127`
- SSE clients / external subscribers — `lib/sse.ml:198,835`
- browser lane clients — `lib/browser_lane/browser_lane.ml:772`
- `Process_eio.runtime_state` — `lib/process/process_eio.ml:24`
- `Backend_memory.shared_instances` — `lib/backend/backend_memory.ml:22`
- lane addon service 표(fleet/configuration) — `lib/lane_addon/lane_addon_runtime.ml:4571-4625`

명령:
```
rg -n '^let ([a-z_0-9]*(registry|sessions|handles|active|live|running|instances|workers|pools|procs|processes|subscribers|clients|connections|lanes)[a-z_0-9]*) *(:[^=]*)?=' lib -g '*.ml'
```

### 저장소 형태
- 전부 로컬 파일. 네트워크 DB 클라이언트 0.
- SQLite 12 모듈. 파일 이름: tool-metrics.sqlite3, read-index.sqlite3, chat-operations.sqlite3, checkpoint-operations.sqlite3, room.sqlite3, original/prepared/adopted.sqlite3(keeper journal), 세션별 native task·child content journal. 외부 iMessage chat.db는 읽기만.
- JSONL: 서로 다른 `.jsonl` 리터럴 92개 / 67 files. `Dated_jsonl.` 사용 85 files, `Jsonl_writer.` 16 files, durable append 57 files.
- JSON: 서로 다른 `.json` 리터럴 233개 / 166 files. 저장소가 아닌 리터럴도 섞인 상한값.
- meta와 queue snapshot은 durable replace로 통째로 다시 쓰고, WAL은 append. workspace backend는 path별 flock — `lib/backend/backend.ml:214`.

명령:
```
rg -l 'Sqlite3\.' lib -g '*.ml'
rg -o --no-filename '"[^"]*\.sqlite3?"' lib -g '*.ml' | sort -u
rg -o '"[^"]*\.jsonl"' lib -g '*.ml' | sort -u | wc -l ; rg -l '"[^"]*\.jsonl"' lib -g '*.ml' | wc -l
rg -o '"[^"]*\.json"' lib -g '*.ml' | sort -u | wc -l ; rg -l '"[^"]*\.json"' lib -g '*.ml' | wc -l
rg -l 'Dated_jsonl\.' lib -g '*.ml' | wc -l
```

## 3. Keeper 하나의 비용

### 쉬는 Keeper 하나의 fiber
- lane fiber 1개. 이 fiber가 heartbeat loop를 돌림 — `lib/keeper/keeper_lane.ml:252`, `lib/keeper/keeper_heartbeat_loop.ml:1613`
- board attention worker 1개 + stop watcher 1개(`Watched_work` → `Fiber.first`) — `lib/keeper/keeper_keepalive.ml:409-443`
  - 필요할 때 rearm fiber, 60s 뒤 — `lib/keeper/keeper_board_attention_worker.ml:2266-2279`
- 조건에 따라 추가:
  - egress listener + TCP socket: `Network_policy`일 때만 — `keeper_keepalive.ml:458-614`
  - gRPC heartbeat: transport=Grpc일 때만, 30s — `lib/server/keeper_grpc_heartbeat.ml:9,203-235`
  - 턴 중 liveness pulse: 5~30s로 clamp — `lib/keeper/keeper_heartbeat_loop_in_turn_pulse.ml:11-13,30`
- 쉬는 동안 3개. policy면 +1, gRPC면 +1, 턴 중이면 +1.

### 타이머
- `interruptible_sleep`가 0.5s 조각으로 Atomic 깃발을 확인 — `lib/keeper/keeper_keepalive_signal.ml:218-252`
  - 기본값 `MASC_KEEPER_SLEEP_CHUNK_SEC` 0.5 (0.1~10) — `lib/config/env_config_keeper.ml:601`
  - 쉬는 Keeper 하나가 초당 약 2번 깸. Keeper가 N개면 초당 약 2N번(코드에서 셈).
- heartbeat cadence 기본 300s — `lib/config/env_config_keeper.ml:576`

### 모든 Keeper를 도는 타이머
- supervisor sweep 30s(clamp 10~120) — `lib/config/env_config_keeper_supervisor.ml:7-9`, `lib/keeper/keeper_runtime.ml:745-855`
  - registry 전체를 8개씩 묶어 순회 — `lib/keeper/keeper_supervisor_types.ml:12`, `keeper_supervisor.ml:204`
  - Running Keeper마다 TOML 재파싱 — `keeper_runtime.ml:773-806` → `keeper_types_profile.ml:196`
- keeper volume maintenance 60s — `lib/server/server_keeper_volume_maintenance.ml:271-283`, `env_config_runtime_services.ml:73`
- keeper build cleanup 1h — `lib/server/server_keeper_build_maintenance.ml:184-197`, `lib/runtime_settings.ml:366`
- repository pulls 60s — `lib/server/server_repository_pulls.ml:746,832`
- operator snapshot refresh 60s(`MASC_OPERATOR_REFRESH_INTERVAL_S`) — `lib/server/server_dashboard_http_core_operator.ml:267`, Keeper snapshot semaphore 16 — `lib/operator/operator_control_snapshot.ml:32-41`
- discord presence 30s(Discord 켤 때만) — `lib/server/discord_presence_bridge.ml:16,49`
- `wakeup_keeper`는 wake마다 registry를 O(N) 순회 — `keeper_keepalive_signal.ml:273`
- `Keeper_registry.all` 호출 36곳 / 26 files

### 모든 Keeper가 지나는 잠금
- registry: Atomic 하나에 CAS로 씀. "single-domain Eio" 전제 — `keeper_registry_setup.ml:1,13`
- 모든 lane이 owner domain에서 돎 — `keeper_keepalive.ml:978-982`
- `mention_delivery_mutex` 하나가 mention 전달 전부를 직렬화 — `lib/workspace/workspace_broadcast.ml:590`, 사용 :792,:988,:1126
- `keeper_types_support.ml:20,66,88,106`: 전역 Eio.Mutex 4개. store handle 캐시 조회만 지킴. append는 path별 잠금 — `lib/dated_jsonl/dated_jsonl.ml:126`
- lifecycle audit ring mutex — `lib/keeper/keeper_lifecycle_audit.ml:26`. transition audit — `lib/keeper/keeper_transition_audit.ml:40`
- CLI spawn semaphore 8 — `lib/runtime/runtime_cli_spawn_gate.ml:3,10`. 쓰는 곳은 Antigravity 하나 — `lib/runtime/runtime_antigravity.ml:1104`
- 그 밖의 semaphore: `completion_authority_agent.ml:70`(4), `keeper_sandbox_remote.ml:199`(endpoint별 max_concurrent_sessions), `keeper_msg_async_locks.ml:201`(1)
- lib 전체 module-level mutex 219개

### Domain·thread pool
- 고정 3 = main 1 + `Systhread_host` 1(`lib/core/systhread_host.ml:1`) + event queue snapshot codec 1(`lib/keeper_runtime/keeper_event_queue_snapshot_codec.ml:8`) — `lib/server/server_runtime_bootstrap.ml:1159-1161`
- execution codec 2, read pool 2, shared pool은 나머지. 한도는 `recommended_domain_count - 1` — `lib/core/domain_budget.ml:22,29,34,37`
- override `MASC_EXECUTOR_DOMAIN_COUNT`. `Domain_pool` 기본 `recommended - 2` — `lib/core/domain_pool.ml:7`
- HTTP serving 전용 domain은 선택 — `server_runtime_bootstrap.ml:2211-2215`
- `run_in_systhread` 265곳

명령:
```
rg -n 'Fiber\.(fork|fork_daemon|both|all|first|any|fork_promise)|Pulse\.(create|run)|Eio\.Time\.sleep|Time\.with_timeout' lib/keeper/keeper_heartbeat_loop*.ml lib/keeper/keeper_board_attention_worker*.ml lib/keeper/keeper_turn_pulse.ml lib/keeper/keeper_lane*.ml
rg -n 'Eio\.Semaphore\.make|Semaphore\.make' lib -g '*.ml'
rg -n '^let [a-z_0-9]+ *(:[^=]*)?= *(Stdlib\.)?(Eio\.)?Mutex\.create|^let [a-z_0-9]+ *(:[^=]*)?= *Cross_context_mutex\.create' lib -g '*.ml'
rg -c 'Keeper_registry\.all\b' lib -g '*.ml'
rg -n -i 'max_concurrent|concurrent_turns|turn_slots|max_parallel|parallelism|pool_size|domain_count|recommended_domain_count|Domain\.spawn|Domain_manager|Executor_pool|domain_mgr' lib bin -g '*.ml'
rg -c 'run_in_systhread' lib -g '*.ml'
```

## 4. 부팅 때 무조건 시작하는 것(순서대로)

### bin/main_eio.ml
1. base path guard — :333
2. base path lease — :378
3. runtime events 준비 — :387
4. 로그(init, console sink, ring file sink, writer) — :421-454
5. retained checkpoint sweep — :463, checkpoint object sweep — :481
6. lane addon original body inventory — :501
7. settled archive sweep — :518
8. alloc profile — :537, Eio_guard·clock 설정 — :548-557, runtime events listener — :564
9. SIGTERM·SIGINT handler — :582-587
10. session switch, shutdown deadline watchdog — :591-606
11. `run_server` → `Server_runtime_bootstrap.run` — :714 / :79
12. `Eio_main.run` — :859

### lib/server/server_runtime_bootstrap.ml `run`
1. auth config·authz boot mode — :1673-1700
2. runtime context, gRPC transport·H2 모드 — :1702-1706
3. provider diag sink, dashboard bundle 확인 — :1709-1716
4. rate-limit cleanup loop — :1717
5. HTTPS 인증서 — :1722
6. owner init fiber — :1801. `initialize_owner_state_blocking` :737-1198:
   - config journal 복구 :801
   - run registry 4개 설치 :812-844
   - GC sampler 30s :868
   - flush fiber 3개(activity gauges, tool usage, trajectory) :877-912
   - queue snapshot codec :924
   - provider connection cache :959
   - owner registry :1059
   - keeper persistence 준비 :1103
   - Runtime_params 복원 :1121
   - crash drain :1123
   - domain pool :1173-1176
   - pending confirm expiry :1179
   - systhread host :1180
   - execution runtime :1181
7. activate — :1630-1664: gate persistence, MCP sessions, lazy restore_sessions, keeper persistence 확보 + `start_keeper_loops`. 이 안에서(`server_bootstrap_loops.ml:1540-2202`):
   - event bridge ×2, provider admission events, telemetry consumer
   - shutdown recovery, lifecycle listener, mention recovery, orphan observation, session cleanup
   - autoboot, supervisor sweep, discord presence
8. server state 게시 + ready 표시 — :1838-1848
9. auxiliary `run_all` — :1964:
   - scheduler lag probe, full health refresh, heap roots
   - owner lanes(`start_post_ready_owner_lanes` :1515): completion authority, goal verifier, candle payout, memory curator, startup maintenance 4개(jsonl prune, microVM guest sweep, unowned exact sweep, superseded lane census), `start_background_maintenance`(`server_bootstrap_maintenance.ml:400-1099`, 약 20개 루프)
   - Discord, Slack gateway, Slack poll, iMessage, Telegram
   - banner, gRPC listener, gRPC client, WS handler, transport providers
   - dashboard refresh 6개, shell prewarm
10. startup watchdog daemon — :2164
11. HTTP/HTTPS serve — :2185-2260

### 외부 프로그램
- microVM guest sweep: `container`/`msb`/`nerdctl`이 PATH에 없으면 건너뜀. 서버는 뜸 — `server_runtime_startup_maintenance.ml:133-171`
- keeper volume maintenance: microVM CLI(`Process_eio`) — `server_keeper_volume_maintenance.ml`
- repository pulls: git — `server_repository_pulls.ml`
- SearXNG 확인: docker — `lib/searxng_runtime_dependency.ml:38`
- Keeper sandbox(docker / container·msb·nerdctl / ssh)와 모델 CLI(claude, codex, gemini, antigravity), ollama: 부팅에서 검사 안 함. 서버는 뜨고 Keeper launch·turn에서 실패.
  - 부팅 이미지 승인은 카탈로그 파일만 읽음 — `keeper_runtime.ml:543`, `keeper_sandbox_image_resolver.ml:94`
- gateway(Discord, Slack, iMessage, Telegram): 꺼져 있으면 건너뜀. 실패하면 degraded 표시 — `server_runtime_bootstrap.ml:2127-2146`
- authority·verifier·curator: 모델 설정이 필요하면 준비될 때까지 기다림 — :1539-1543

명령:
```
rg -n '^let |^and ' lib/server/server_runtime_bootstrap.ml
awk 'NR>=737 && NR<=1200' lib/server/server_runtime_bootstrap.ml | rg -n 'boot_stage "|[A-Z][A-Za-z_]*\.(start|run|install|create|bootstrap|init|configure|launch|spawn|restore|claim|prepare|sync|resume|recover|reconcile)[a-z_]*|Fiber\.fork'
sed -n 330,884p bin/main_eio.ml | rg -n '[A-Z][A-Za-z_]*\.(start|install|run|init|configure|acquire|set|apply|load|prepare|bootstrap|register|tune|sample|enable)[a-z_]*|run_server|Fiber\.fork|Eio_main\.run'
sed -n 400,1104p lib/server/server_bootstrap_maintenance.ml | rg -n '^\s*(fork_[a-z_]+|[A-Z][A-Za-z_]*\.(start|spawn|run|install)[a-z_]*)'
for p in docker container git gh ssh ollama node claude codex gemini; do rg -l "\"$p\"" lib -g '*.ml' | wc -l; done
```

## 5. 환경 변수

### 이름 수
- 서로 다른 이름 약 284개. 리터럴 합집합 286개에서 잡음 2개(`git`, `GIT_`)를 뺀 값.
  - MASC_ 255개, MASC_ 아닌 것 29개
- 타입이 정해진 registry `Env_setting`(closed variant): 24개 — `lib/config/env_setting.ml`
- `masc_config` snapshot: 79개 — `lib/config/env_config_snapshot.ml`
- lib/config의 env_config*·env_setting 모듈: MASC_ 191개
- MASC_ 리터럴 중 위 config 모듈 밖에만 있는 것: 64개

### 직접 읽는 곳
- `Sys.getenv(_opt)` 121곳. lib/config 17, 밖 104:
  - bin 37, lib/server 12, lib 최상위 파일 10, lib/keeper 9, lib/core 8, lib/masc_log 3
  - workspace·process·fs_compat·dashboard_tla_specs 각 2, 그 밖 16개 디렉터리 각 1
- `Unix.getenv`/`Unix.environment` 47곳(keeper 13, runtime 8, 최상위 7, bin 6, …)
- config 밖에서 `Env_config_core.get_*`/`raw_value_opt` 61곳 / 40 files
- 모듈 안 `float_of_env_default` 같은 helper 10곳(예 `server_dashboard_http_core_operator.ml:267`, `operator_control_snapshot.ml:32`)

### 접두어별
- MASC_ 두 번째 토큰:
  - KEEPER 83(SANDBOX 9, MICROVM 7, MEMORY 6, VISION 5, BOOTSTRAP 4, SSH·METRICS·HITL·GENERATED·AUTONOMOUS·WIRE 각 3, 나머지 1~2)
  - DASHBOARD 17, WS 9, TUI 7, IMESSAGE 7, SSE 6, HTTP 6
  - WEB·RATE·OPERATOR·OAUTH·BOARD 각 5
  - TEST·SHUTDOWN·HOST·GRPC·BASE·AGENT 각 4
  - NOTIFY·H2·EXEC 각 3, 나머지 ≤2
- MASC_ 아닌 것: HOME, PATH, XDG_CONFIG_HOME, XDG_DATA_HOME, TERM, TERM_PROGRAM, COLORTERM, NO_COLOR, TMUX, TTY, EDITOR, VISUAL, SSH_CONNECTION, SSH_TTY, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, OLLAMA_CLOUD_API_KEY, OLLAMA_SERVER_URL, DISCORD_BOT_TOKEN, TELEGRAM_BOT_TOKEN, TYPESAFEAI_API_KEY, GIT_CONFIG_GLOBAL, OCAMLRUNPARAM, OCAML_RUNTIME_EVENTS_DIR, OCAML_RUNTIME_EVENTS_PRESERVE, DUNE_SOURCEROOT, MSX_ROMS, VOICE_AUDIO_TEST_TONE_TIMEOUT_SEC, VOICE_HTTP_REQUEST_TIMEOUT_SEC

### TOML 짝
- 방법: `lib/config/keeper_runtime_setting_registry.ml`의 `exposure` 태그(:28-31)를 셈.
  - 67행: `Toml_and_env` 7, `Toml_only` 35, `Env_only` 25 → runtime.toml 키가 있는 이름 42개
- `Runtime_params` 키 22개(`lib/runtime_settings.ml`): runtime.toml이 아니라 `.masc/runtime_params.json`에 저장. 이 중 7개는 기본값을 Env_config에서 가져옴.
- 한계: 다른 TOML 섹션(Runtime 카탈로그, Slack, voice, maintenance)은 env↔TOML 대응표가 없어 이름으로 맞출 수 없음.

명령:
```
rg -o --no-filename '"MASC_[A-Z0-9_]+"' lib bin -g '*.ml' | tr -d '"' | sort -u
rg -o --no-filename -U 'getenv(_opt)?\s+"[A-Za-z_][A-Za-z0-9_]*"' lib bin -g '*.ml'
rg -o --no-filename -U '(get_string|get_int|get_float|get_bool|get_bool_strict|get_int_clamped|get_float_clamped|get_int_nonneg|get_float_nonneg|get_port|get_retention_days|raw_value_opt|float_of_env_default|int_of_env_default)\b[^"\n]{0,80}"[A-Z][A-Z0-9_]+"' lib bin -g '*.ml'
rg -o --no-filename -U '(env_key|env_name|_env|_ENV|env_var|key)\s*(:\s*string\s*)?=\s*"[A-Z][A-Z0-9_]+"' lib bin -g '*.ml'
rg -c 'Sys\.getenv(_opt)?\b' lib bin -g '*.ml'
rg -c 'Unix\.getenv|Unix\.environment' lib bin -g '*.ml'
rg -c 'Env_config_core\.(get_[a-z_]+|raw_value_opt)' lib bin -g '*.ml' | rg -v '^lib/config/'
rg -c '~exposure:Env_only' lib/config/keeper_runtime_setting_registry.ml ; rg -c '~exposure:\(Toml_and_env' … ; rg -c '~exposure:\(Toml_only' …
rg -c '~key:"' lib/runtime_settings.ml
```

## 6. 프롬프트

### 파일
- `config/prompts`: 45 파일(md 44, txt 1), 196,587 B, 하위 디렉터리 없음
- `config/tools`: 217 파일(TOML 도구 정의). `config` 아래 TOML 전체 369개.
- 이름에 prompt/instruction이 든 `.ml`: 21개(lib). system_message: 0.
  - 예: keeper_unified_prompt.ml 2,059줄, prompt_registry.ml 1,344줄, prompt_preset.ml 1,266줄, prompt_names.ml 822줄
- `config/prompts`는 빌드 때 ocaml-crunch로 바이너리에 들어감 — `lib/embedded_config/dune`

### OCaml에 박힌 문자열 크기(방법 3가지)
1. `{|…|}` quoted string(`rg -U --pcre2 --json` + `jq`로 길이 셈)
   - 157개, 300자 넘는 것 51개, 230,421 B
   - 상위는 HTML/JS/shell/SQL이라 프롬프트가 아님: server_routes_http_routes_play_page.ml 60,218, browser_scene_script.ml 25,494, browser_ego_workflow.ml 21,392, browser_interaction.ml 20,650, browser_ego_peer.ml 14,337, browser_page_script.ml 10,381, browser_ego_raw_type.ml 9,966, verification_presentation_inspection_parser.ml 8,975, browser_ego_page_events.ml 8,264, keeper_sandbox_remote_checkouts.ml 8,150
2. `"…"` 300자 넘는 리터럴: 91개, 42,500 B
3. 산문 리터럴(40자 이상, 단어 6개 이상): 13,790개, 981,025 B, 1,670 files. 상위 15:
   - browser_ego_peer.ml 25,431
   - browser_capabilities.ml 19,671
   - keeper_chat_operation_store.ml 16,403
   - tui_decode.ml 11,094
   - lane_addon_runtime.ml 9,991
   - runtime/runtime.ml 6,734
   - sandbox_prerequisites.ml 6,617
   - server_runtime_bootstrap.ml 5,575
   - keeper_official_client_session_store.ml 5,432
   - server_bootstrap_loops.ml 4,849
   - keeper_librarian_original_gate.ml 4,552
   - keeper_memory_os_recall.ml 4,527
   - env_config_snapshot.ml 4,420
   - keeper_durable_store.ml 4,303
   - keeper_owner.ml 4,278
   - 대부분 오류·로그·도움말 문장이고 모델에게 가는 프롬프트는 아님.

### 모델에게 가는 문장이 코드에 박힌 곳
- 구절 휴리스틱("You are", "Respond with", "Return JSON", "Do not invent" 등) 3 files + `system = "…"` 리터럴 3곳:
  - `lib/runtime/runtime_verification.ml` (산문 38개, 3,045 B, 예 :412)
  - `lib/tool_local_runtime_probe.ml:384`
  - `lib/librarian_working_state_evaluation.ml:78,81`
  - `lib/librarian_production_evaluation.ml:192`
- 모델에게 보이는 설명문: `lib/verification_authority_tools.ml` 4,153 B, `lib/keeper/keeper_structured_output_schema.ml` 1,062 B. `~description:"…"` 24곳 / 7 files.

### config/prompts에서 읽는 모듈
- prompt 모듈은 산문이 적고 registry를 씀:
  - keeper_unified_prompt.ml: registry 참조 130, 산문 644 B
  - prompt_preset.ml: 13 / 528 B
  - prompt_defaults.ml: 23 / 130 B
  - keeper_prompt.ml: 15 / 181 B
  - mcp_prompt_surface.ml: 8 / 44 B
  - prompt_registry.ml: 945 B
- lib/prompt_registry 밖에서 `Prompt_registry.`/`Prompt_names.`를 쓰는 모듈: 71개

명령:
```
find config/prompts -type f | wc -l ; find config/prompts -type f -exec wc -c {} + | tail -1
find lib bin -name '*.ml' | rg -i 'prompt|instruction|system_message'
rg -U --pcre2 --json '\{([a-z_]*)\|[\s\S]*?\|\1\}' lib -g '*.ml' | jq -r 'select(.type=="match") | .data as $d | $d.submatches[] | [$d.path.text, $d.line_number, (.match.text|length)] | @tsv'
rg -U --pcre2 --json '"(?:[^"\\\n]|\\[\s\S]){300,}"' lib -g '*.ml' | jq …
rg -U --pcre2 --json '"(?:[^"\\\n]|\\[\s\S]){40,}"' lib -g '*.ml' | jq -r '… select((.match.text|split(" ")|length) >= 6) …'
rg -c --pcre2 '"[^"\n]*\b(You are|You must|Respond with|Reply with|Return (only )?(a |one )?JSON|Your (task|job|answer)|Answer with|Output (only|exactly)|Do not (call|use|invent|guess))\b' lib -g '*.ml'
rg -n --pcre2 '\b(system|system_prompt|instructions|prompt|user_prompt|wake_prompt)\s*=\s*"[^"]{40,}|~(system|system_prompt|instructions|prompt|user_prompt):\s*"[^"]{40,}' lib -g '*.ml'
rg -l 'Prompt_registry\.|Prompt_names\.' lib bin -g '*.ml' | rg -v 'lib/prompt_registry/' | wc -l
```

## 7. TOML

### 읽는 모듈
- Otoml parse를 쓰는 파일: 45개(TUI bin 6개 포함)
- runtime.toml 위치를 찾는 TUI 밖 파일: 37개. `Config_dir_resolver.runtime_toml_path_for_base_path` 26곳. 파일 이름 상수 `lib/config_dir_resolver/config_dir_resolver.ml:4`
- keeper TOML loader·parser(`lib/keeper_toml/`): 233곳 / 15 files
  - 가장 많은 곳: keeper_runtime_config.ml 76, tui_preference.ml 33, keeper_types_profile_toml_parser.ml 24
- Keeper profile snapshot 캐시는 매번 keepers/*.toml을 전부 읽은 뒤 내용으로 비교 — `lib/keeper/keeper_types_profile.ml:663-711`

### 타입 있는 레코드 하나를 boot에 발행하는가
- 아니요.
- runtime.toml의 Keeper 섹션: boot 한 번 `Keeper_runtime_config.load_and_apply`(`server_runtime_bootstrap.ml:416-424`)가 문자열 키 저장소 `Config_boot_overrides`(`lib/config/config_boot_overrides.mli:1-30`)에 넣음. getter가 쓸 때마다 env처럼 읽음.
  - 우선순위: process env > boot override > 기본값. file-owned 이름은 env를 건너뜀.
- 모델 카탈로그만 boot에 발행 — `publish_exact_output_catalog` :250, `Runtime.load_config_observation` `lib/runtime/runtime.ml:1764`

### 쓰는 곳에서 다시 읽음
- egress allowlist: 요청마다 — `keeper_keepalive.ml:497-530`
- keeper TOML: sweep마다 — `keeper_runtime.ml:773-806`
- Slack poll, repository pulls, voice config, connector trigger policy, maintenance TOML 설정 모듈도 각자 읽음(위 37 files)

### Reload 경로
- keeper TOML: supervisor sweep 약 30s — `keeper_runtime.ml:770-806`
- runtime.toml:
  - POST `/api/v1/runtime/config/raw` — `lib/server/server_routes_http_routes_runtime_config.ml:599`
  - POST `/api/v1/runtime/setup/resume` — 같은 파일 :590 → `Server_model_setup_resume.request`
- Runtime_params: POST `/api/v1/runtime/params/set`·`/clear` — `lib/server/server_routes_http_routes_activity.ml:1623,1683`
- Keeper 섹션 override(`load_and_apply`): 부르는 곳이 boot와 CLI 1곳(`bin/masc_cli_web_search_setup.ml:156`)뿐
  - registry `reload_class`: `Next_turn` 4개, 나머지는 기본 `Process_restart` — `keeper_runtime_setting_registry.ml:19-21,114`

명령:
```
rg -l '\b(Otoml|Toml)\.(Parser|of_string|from_string|parse)|Toml\.Parser\.from' lib bin -g '*.ml'
rg -l 'runtime_toml_path|runtime_toml_filename|Config_dir_resolver\.runtime_toml' lib bin -g '*.ml' | rg -v masc_tui
rg -o --no-filename '[A-Z][A-Za-z_]*\.(runtime_toml_path|runtime_config_path|config_path_for_base_path|resolve_runtime_toml)[a-z_]*' lib bin -g '*.ml' | sort | uniq -c
rg -c 'Keeper_toml_(loader|parser)\.' lib bin -g '*.ml' | rg -v 'lib/keeper_toml/'
rg -n 'load_and_apply|Config_boot_overrides\.set' lib -g '*.ml'
rg -n '"/api/v1/[a-z_/-]*runtime[a-z_/-]*"' lib/server -g '*.ml'
```

## 8. Keeper 도구 sandbox backend

- `sandbox_profile = Docker | Micro_vm | Remote_ssh` — `lib/config/keeper_sandbox_config.ml:7`, 재수출 `lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml:1`
  - host/local 실행 arm 없음
- 기본값 없음. TOML에 선언이 없으면 boot error — `lib/keeper/keeper_runtime.ml:350-370`(`sandbox_profile_required_boot_error`)
  - JSON parse의 `Docker`는 자리만 채우는 값이고 authority가 아님 — `lib/keeper/keeper_meta_json_parse.ml:336`
- microVM backend: `Apple_container | Microsandbox | Nerdctl_kata` — `lib/keeper/keeper_microvm_backend.mli:16`
  - `default_for_host`: macOS면 Apple_container, 아니면 None — `keeper_microvm_backend.ml:68-72`, 사용 `lib/keeper/keeper_meta_contract.ml:240`
- network: `Network_none | Network_inherit | Network_policy` — `keeper_types_profile_sandbox.ml:37`
  - profile별 기본: Docker → none, Micro_vm → none, Remote_ssh → inherit — :85-89
- backend 모듈: keeper_sandbox_docker*, keeper_sandbox_microvm*(15개), keeper_sandbox_remote*, keeper_sandbox_ssh
- 낡은 주석: `keeper_runtime.ml:359`가 가리키는 `Keeper_types_profile.default_sandbox_profile`는 정의가 0개

명령:
```
rg -n '^type [a-z_]+ =|^  \| [A-Z]' lib/keeper_types_profile_sandbox/*.ml
rg -n 'type sandbox_profile|type microvm_backend|^type t =' -A12 lib/config/keeper_sandbox_config.ml
rg -n '^type ' -A8 lib/keeper/keeper_microvm_backend.mli
rg -n 'default_sandbox_profile' lib -g '*.ml'
rg -n 'Keeper_microvm_backend\.(of_string|parse|default|select|resolve)[a-z_]*' lib -g '*.ml'
```

## 못 읽음 / 확인 못함
- `docs/constitution.xml`은 전체를 읽지 않았어요. 읽기만 하는 조사라 변경 계획이 없었어요.
- 4절 외부 프로그램은 일부만 코드로 확인했어요(microVM sweep, volume maintenance, repository pulls, SearXNG). 나머지는 모듈 이름과 호출 형태로 판단했어요.
- 1절 catch-all 검색은 arm 뒤 10줄만 봐요. 멀리 떨어진 arm은 놓칠 수 있어요.
- 5절 이름 수는 문자열 리터럴만 셌어요. 실행 중에 이어 붙인 이름은 빠졌고, 자식 프로세스에 넘기려고 쓰는 이름이 섞여 있을 수 있어요.
- 2절 JSON 리터럴 수는 상한값이에요(URL·응답 필드 이름 포함).
- 3절 fiber 수와 wakeup 수는 코드에서 셌어요. 서버에서 측정하지 않았어요. Keeper 하나의 메모리도 재지 않았어요.
- 6절은 프롬프트만 골라내는 분류기가 없어요. 상위 15는 산문 휴리스틱 기준이고 깔끔한 "프롬프트 크기 top 15"는 아니에요.
- 2절 표의 다음 줄 create(P2) 패턴과 `Stdlib.*` 패턴은 겹치지 않게 짰지만 손으로 대조하지는 않았어요.
