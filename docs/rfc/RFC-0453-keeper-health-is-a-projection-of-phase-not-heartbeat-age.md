---
rfc: "0453"
title: "keeper health 는 phase 의 투영이지 heartbeat 나이가 아니다"
status: Accepted
created: 2026-09-15
revised: 2026-09-15
author: claude
related: ["0380", "0089"]
---

# RFC-0453 — keeper health 는 phase 의 투영이지 heartbeat 나이가 아니다

- Status: **Accepted (2026-09-15).** 결정은 §0 과 §3. 구현 PR 과 결과는 §6.
- 한 줄: metrics 원장(ledger)의 `record_kind=heartbeat` 줄 나이를 읽어 keeper 를 `stale` 로 판정하던 코드를 서버·TUI·대시보드에서 전부 지운다. keeper health 는 `healthy | idle | failing | offline` 네 값이 되고, phase 와 턴 이력만으로 정해진다.

## 0. 결정 요약

- `keeper_health` = `KH_healthy | KH_idle | KH_failing | KH_offline`. `KH_stale`, `KH_degraded`, `KH_zombie` 는 지운다.
- 도출식은 하나다. keepalive 가 안 돌면(`can_execute_turn phase = false`) `offline`, phase 가 `Failing` 이면 `failing`, `Running` 인데 턴 기록이 없으면(`total_turns = 0 && proactive count = 0`) `idle`, 나머지 `Running` 은 `healthy`.
- `failing` 을 따로 두는 이유: `can_execute_turn` 은 `Running` 과 `Failing` 에서 모두 참이다. 그래서 값이 셋일 때는 턴이 실패하고 있는 keeper 도 `healthy` 로 읽혔고, 2026-09-15 TUI 채팅 헤더가 턴 4번 연속 실패한 msx-retro-mania 에 `● healthy` 와 phase `failing` 을 한 줄에 그렸다. `failing` 의 다음 행동은 `probe`(최근 오류부터 읽기)다. Failing 은 턴이 실패한다는 사실만 말하고, 재시작으로 고쳐지는지는 말하지 않는다. 깨끗한 턴이 나오면 phase 가 Running 으로 돌아가고, 실패 한도를 넘으면 Crashed 가 되어 supervisor 가 재시작한다. `recoverable` 은 참이라서, 오류를 읽은 운영자는 `keeper_recover` 로 재시작할 수 있다.
- heartbeat 원장 줄을 쓰는 코드(`write_heartbeat_snapshot`)와 SSE `keeper_heartbeat` 이벤트는 남긴다. 지우는 것은 그 줄의 **나이를 읽어 판정하는 코드**뿐이다.
- wire 에서 `last_heartbeat`, `last_heartbeat_age_s`, `heartbeat_observation_error`, `heartbeat_stale_after_s` 를 지운다. 호환 코드는 만들지 않는다(hard cut).
- 지운 동작의 회귀 테스트는 지운다. 남는 기능 테스트는 네 값 기준으로 고친다.

## 1. 문제

### 1.1 정상 keeper 의 기본 상태가 `stale` 이었다

`keeper_health_state` 는 keeper 의 metrics 원장에서 가장 최근 `record_kind=heartbeat` 줄을 읽고, 그 나이가 `keepalive_interval_s + 60s`(기본 360s)를 넘으면 `KH_stale` 을 냈다. 이 줄은 keepalive 루프가 **턴을 끝낸 뒤** 한 번 쓴다. 턴이 6분 넘게 걸리면 keeper 가 일하는 도중에 `stale` 이 된다.

실측(2026-09-15 06:55Z 기준 직전 24시간, 운영 workspace 의 `.masc`(`MASC_BASE_PATH`), 살아 있는 keeper 13개). 방법: 각 keeper 의 heartbeat 줄을 시간순으로 놓고, 이웃한 두 줄 사이 간격에서 360초를 넘긴 부분을 모두 더해 24시간으로 나눴다. 05:08Z 에 같은 방법으로 잰 값도 keeper 별로 ±3%p 안에 있었다.

| keeper | heartbeat 줄 수 | 360s 넘긴 간격 | `stale` 로 읽힌 비율 | 가장 긴 간격 |
|---|---:|---:|---:|---:|
| analyst | 163 | 122 | 35.2% | 30.6분 |
| code-reviewer | 54 | 43 | 79.4% | 543.5분 |
| critic | 147 | 121 | 40.8% | 24.7분 |
| edgar.a.poe | 147 | 121 | 40.6% | 20.4분 |
| geek-scout | 143 | 121 | 42.0% | 21.0분 |
| goo-yang-bong | 102 | 91 | 58.8% | 76.5분 |
| jazz-developer | 149 | 117 | 40.5% | 29.4분 |
| kidsnote-slack-context-collector | 150 | 125 | 39.4% | 18.1분 |
| lane-smith | 152 | 123 | 38.8% | 21.7분 |
| msx-retro-mania | 90 | 65 | 65.0% | 324.3분 |
| polisher | 43 | 39 | 83.2% | 380.1분 |
| pr-updater | 138 | 105 | 45.1% | 26.5분 |
| rondo | 112 | 100 | 55.0% | 47.2분 |

13개 전부가 하루의 1/3 에서 5/6 을 `stale` 로 보냈다. 신호가 아니라 잡음이다.

### 1.2 잡음이 판정으로 흘러갔다

`KH_stale` 은 화면에서 끝나지 않았다.

- `next_action_path = Recover`, `recoverable = true` → 운영자 `keeper_recover`(down/up) 권고.
- `status = inactive`(surface status).
- 대시보드 status-tray 경고 수, `masc_keeper_list` 도구 행(LLM keeper 가 읽는다).
- 대시보드는 같은 판정을 세 벌 더 갖고 있었다(`staleKeepers`, `deriveHeartbeatProjection`, `keeperNeedsDiagnosticAttention.hbStale`). SSE heartbeat 가 없으면 `last_turn_ago_s` 로까지 내려가 판정했다.

자동으로 `Recover` 를 실행하는 코드는 없다(권고 문구에 "Do not self-restart." 명시). 유일한 실행 경로는 사람이 누르는 `keeper_recover` 뿐이다. 그래서 지금까지 사고로 이어지진 않았지만, 사람과 LLM 이 읽는 화면이 하루의 절반을 틀리게 말하고 있었다.

### 1.3 constitution 위반

- `no_wall_clock_death`: 시간 경과만으로 상태를 죽인다.
- `magic_number`: 360초 비교로 흐름(권고·상태)을 제어한다.

### 1.4 같은 함수의 나머지 두 값은 죽은 코드였다

- `KH_zombie`: `?fiber_health` 인자를 넘기는 프로덕션 호출자가 0개라 도달 불가.
- `KH_degraded`: 생성자가 없고 문자열 파서에만 있었다.
- 대시보드 `KeeperHealthState` union 에 `zombie` 가 없었던 것이 그 방증이다.

## 2. 살아 있음을 답하는 실제 권위

heartbeat 나이 판정이 없어도 아래가 이미 답한다. 나이 판정은 이들 중 어느 것도 대체하지 않고 단독으로 틀린 답을 냈다.

| 질문 | 권위 | 근거 |
|---|---|---|
| keepalive 가 돌고 있는가 | phase FSM (`Running`/`Failing` 만 턴 실행) | `lib/keeper_registry/keeper_state_machine.ml`, `Failing` 은 `Heartbeat_failed`/`Turn_failed` 증거로만 진입 |
| fiber 가 살아 있는가 | `fiber_health_of` (registry entry 의 done promise) | `lib/keeper_registry/keeper_registry.ml` |
| 지금 턴 중인가 | `is_live = current_turn_observation <> None` | registry |
| 턴이 멈췄는가 | attempt watchdog (15초 폴링, **진행 신호** 기준, 취소 + typed Timeout + provider 로테이션) | `keeper_turn_driver_try_provider.ml` |
| crash 뒤 재시작 | supervisor `sweep_and_recover` (promise/phase 만 읽음) | supervisor |
| fleet 정지 알림 | Grafana `masc-fleet-heartbeat-stall` (성공 카운터 증가량) | 원장 줄 나이를 보지 않는다 |

## 3. 지우는 것 / 남기는 것

| 지운다 | 남긴다 |
|---|---|
| `KH_stale`, `KH_degraded`, `KH_zombie`, `Fiber_dead`, `Auto_restart` | `KH_healthy`, `KH_idle`, `KH_failing`, `KH_offline` |
| `keeper_heartbeat_stale_after_s`, `heartbeat_transport_jitter_s` | `keeper_keepalive_interval_s`, `keeper_snapshot_interval_s` (설정값 표시) |
| `Keeper_heartbeat_persisted_snapshot` 모듈 | `write_heartbeat_snapshot` (원장 줄 쓰기, stage_timing 등 telemetry) |
| wire 키 `last_heartbeat`, `last_heartbeat_age_s`, `heartbeat_observation_error`, `heartbeat_stale_after_s` | `last_activity_at`, `last_turn_ago_s`, `updated_at` |
| TUI 마크 `?`/`‡` 와 그 범례 | `●`/`!`(failing)/`·`/`×`/`○`(paused)/`-`(unread) |
| 대시보드 `staleKeepers`, `keeperHeartbeats`, `deriveHeartbeatProjection`, `hbStale`, `keeperFreshnessTs`, `isHeartbeatAlive`, `heartbeatEtaSeconds` | SSE `keeper_heartbeat` 표시 소비자(저널, 라이브 타임라인, transport-health) |

"마지막 heartbeat" 라는 이름 자체가 오해의 뿌리였다. 실제 뜻은 "루프가 마지막으로 한 바퀴를 끝낸 시각" 이다. 표시가 필요하면 이미 있는 `last_activity_at`/`last_turn_ago_s` 를 쓴다.

## 4. 대시보드 `keeperDisplayStatus`

같은 병이 하나 더 있었다. `lib/keeper-runtime-display.ts` 의 `keeperDisplayStatus` 는 heartbeat 나이로 살아 있음을 정한 뒤에야 phase 를 봤다. phase 가 `Running` 인데 heartbeat 가 늦으면 `stopped`/`unbooted` 로 그렸다. phase 우선으로 다시 쓴다. phase 가 `Offline` 이 아니면 lifecycle status 를 그대로 쓰고, 그 뒤에만 `turn_count` 로 `unbooted`/`stopped` 를 가른다.

## 5. RFC-0380 과의 관계

`server_dashboard_http_composite_claims.ml` 의 `stale_long_enough = now - latest >= 600.0` → `needs_attention` → `keeper_recover` 권고는 같은 병, 다른 장기다. 그런데 RFC-0380(Draft) §5 가 이 600s idle 경보와 `last_progress_at` 기준 hang 경보를 acceptance 로 명시한다. 지우려면 RFC-0380 개정이 먼저다. 이 RFC 는 손대지 않고 여기 적어 둔다.

## 6. PR 체크리스트

순서는 대시보드가 먼저다. 서버가 먼저 나가면 대시보드가 `heartbeat_stale_after_s` 부재를 120초 fallback 으로, `last_heartbeat` 부재를 `last_turn_ago_s` 로 메워 판정이 더 나빠진다.

두 PR 은 연달아 병합한다. 사이 구간에서는 서버가 아직 내는 `health_state=stale` 을 대시보드 파서(`normalizeKeeperDiagnostic`)가 어휘 밖 값으로 버려, 그 keeper 의 diagnostic 칩(summary·quiet_reason·keepalive_running)이 비어 보인다. 틀린 권고를 그리는 것보다 빈 칸이 낫다고 보고 호환 코드는 두지 않는다. 릴리즈는 같은 커밋의 서버와 대시보드 자산을 함께 빌드하므로(`release.yml`), 이 구간은 두 병합 사이의 main 을 직접 빌드해 띄우는 경우에만 보인다.

- [x] **PR-B** #36548 대시보드: heartbeat 판정 3벌 제거, `KeeperHealthState` 세 값, `keeperDisplayStatus` phase 우선. 검증: `pnpm typecheck`, `pnpm lint`, `pnpm test`(CI 는 대시보드 테스트를 돌리지 않는다).
- [x] **PR-A1** #36549 (컴파일 복구 #36561, 테스트 수정 #36574) 서버 + TUI: `keeper_health` 세 값, persisted snapshot 모듈·wire 키 삭제, TUI 마크, 테스트, 이 RFC.
- [x] **PR-A2** #36550 (A1 위): `Surface_inactive`, `klc_inactive` 삭제 (`keeper_surface_status` 가 더는 만들지 않는다).
- [ ] **PR-B2** 하지 않는다. 대시보드에서 `'inactive'` 를 읽는 자리(`keeper-store-normalize.ts`, `lib/unified-status.ts`, `runtime-counts.ts`, `lib/keeper-operational-state.ts`, `lib/keeper-classifiers.ts`)는 agent 상태 어휘(`AgentStatus` 의 `inactive`, `resolveUnifiedStatus(keeperStatus ?? agentStatus)`)와 같이 쓰인다. keeper 전용 죽은 분기가 따로 없어서, 지우면 agent 표시만 흔들린다.
- [x] **PR-C1** #36590: continuity 축 정리. 세 값 위에서 `continuity_state` 는 `keepalive_running` 과 "기동 뒤 60초 안인가"(`keepalive_recovery_window_s`) 만 말했다. `health_state=offline` 은 keepalive 가 안 도는 경우와 같아서 `recovering` 으로 가는 다른 길은 없었다. 그 60초 판정과 `recovering`/`not_running` 요약 문구 덮어쓰기, wire `continuity_state`, 대시보드 칩·라벨을 지운다. 요약은 `keeper_diagnostic_summary` 하나만 남는다. `keepalive_started_at` 사실 필드(`masc_keeper_audit`)는 남긴다.
- [x] **PR-C2** #36584: `lib/workspace/heartbeat.ml`(MCP 시절 타이머 표, `start` 를 부르는 프로덕션 코드 0, `stop_by_agent` 는 늘 0 반환)과 `heartbeats_stopped` 필드. 이 모듈을 부르는 테스트가 5개 파일이라 따로 낸다.
- [x] **PR-D** #36577 (컴파일 복구 #36589) TUI Activity pane: chunk 를 keeper 턴으로 묶는다. agent-core `turn` 은 provider 호출 순번이라 keeper 턴 하나가 호출 수만큼 `unsettled` 줄로 쪼개졌다. `run_id` 는 키로 못 쓴다 — `Sink_degraded` 면 이벤트마다 새 `evt-…` 가 찍히고, provider 로테이션마다 갈린다. 서버 브리지가 프레임에 keeper 턴을 찍는 안도 버렸다 — `Keeper_event_bridge` 는 서버 부트에서 bus 를 비동기로 비우므로 relay 시점의 registry `current_turn_observation` 이 이미 다음 턴이거나 비어 있을 수 있다. 대신 서버가 LLM 호출마다 이미 내는 `keeper_turn_observation`(`name`, 세션 `turn`, `total_turns`)을 TUI 가 디코드해 keeper 별 (세션 순번 → keeper 턴 = `total_turns + 1`) 표를 만들고, agent-core 프레임과 `keeper_tool_call` 의 세션 `turn` 을 그 표로 keeper 턴에 붙인다. `total_turns + 1` 은 registry 의 `turn_id` 정의이자 settle 의 번호다(둘 다 settle 이 올리기 전의 `meta.runtime.usage.total_turns` 를 읽는다). observation 이 아직 없는 호출(응답 전)은 keeper 가 턴을 하나씩만 돌리므로 열린 keeper 턴에 붙고, observation 이 전혀 없는 피드는 세션 순번으로만 묶인다. claude_code 같은 CLI 레인은 keeper 턴 하나를 provider 호출 하나로 돌린다. 도구 프레임이 모두 먼저 오고 observation 은 턴 끝에 settle 과 함께 오므로, 레인 keeper 의 진행 중인 줄은 끝날 때까지 `turn ?` 이다(2026-09-15 라이브 캡처 두 번에서 critic·rondo·edgar.a.poe 의 도구 호출이 전부 observation 앞에 왔다). 세션이 체크포인트 없이 새로 만들어지면 순번이 0 부터 다시 시작해 같은 순번이 두 번 관찰되므로, 멤버는 피드 위치가 가장 가까운 observation 을 쓴다. 호출 프레임이 자기 observation 보다 다른 세션의 같은 순번 observation 에 더 가까우면 그 세션의 턴에 붙는다. 긴 레인 턴의 앞쪽 프레임, 오래 도는 도구의 return, relay 가 붙잡았던 프레임이 그런 경우다. observation 은 Everything 에서만 보이지만 fold 가 읽으므로, ring 을 자를 때 action 예산을 같이 써서 번호를 붙일 호출과 도착 순서대로 함께 잘린다. quiet 예산(stream 프레임·heartbeat 와 함께 200칸)에 두면 호출보다 먼저 잘려 한 턴이 다시 `turn ?` 줄로 갈라지고, 호출보다 오래 남으면 체크포인트 없이 새로 만든 세션이 같은 순번에 이르렀을 때 진행 중인 호출을 옛 턴 번호로 연다. Activity 의 어느 scope 에서도 `turn N` 은 keeper 턴 번호다. 세션 순번은 줄에 그리지 않고 이벤트 증거 화면에 `Agent session turn` 으로만 보인다. 서버 코드는 바꾸지 않는다.

## 7. 후속 (이번 범위 밖)

- `keeper_turn_record_source_health` 의 "stale"/`freshness_slo_exceeded`: turn-record 저장소 freshness 라벨(대시보드 telemetry 패널). 판정이 아니라 라벨이지만 같은 계산이라 함께 검토.
- `classify_keeper_quiet_reason` 의 `Starting_up`(keeper 나이 ≤ 120s): wall-clock 분류. 결과가 표시(`Probe` 제안)뿐이라 보류.
- 실패로 끝난 keeper 턴을 알리는 타입 있는 이벤트. settle(`keeper_turn_complete`)은 성공한 턴에만 나간다. 실패 쪽 신호는 provider 시도마다 오는 `agent_core:agent_failed` 와, running 에서 failing 으로 바뀔 때만 오는 `keeper_phase_changed`(`event` 가 `"turn_failed(1)"` 같은 문자열)뿐이다. 그래서 실패한 턴 줄은 Activity 와 `[Recent]` 에서 `unsettled` 로 남는다. 2026-09-15 라이브에서 연속 실패 1~6회인 keeper 다섯 개(analyst, geek-scout, lane-smith, msx-retro-mania, pr-updater)가 이렇게 보였다.
- 순번 없는 `keeper_tool_call`(runtime MCP 경로, `lib/mcp_server_eio_call_tool.ml`)을 내는 keeper 는 첫 settle 뒤 매 턴의 호출이 바로 앞 턴 줄에 붙는다. 순번 없는 멤버는 이미 settle 된 최신 chunk 에도 붙기 때문이다.
- metrics 원장 `record_kind: heartbeat` → `cycle` 로 이름 변경(데이터 스키마 hard cut). 이름이 오해의 뿌리지만 이번 PR 에는 넣지 않는다.
- 서버가 `keeper_tool_call` 과 `keeper_turn_observation` 에 keeper 턴 번호를 싣는다. agent-core 도구 처리기(`keeper_tools_agent_core_handler_*.ml`)는 `keeper_turn_id` 를 받지 않으므로, `keeper_tool_call` 에 싣으려면 그 값을 처리기까지 넘겨야 한다. PR-D 는 세션 순번과 `keeper_turn_observation` 으로 keeper 턴을 찾는다. 세션이 새로 만들어져 순번이 0부터 다시 시작하면, 옛 세션의 같은 순번 observation 이 ring 에 남아 있는 동안 진행 중인 호출이 옛 턴 줄에 붙을 수 있다. CLI 레인 keeper 는 observation 이 턴 끝에만 오므로, 이 후속 전에는 진행 중인 턴 내내 번호가 없다. observation hook(`make_hooks`)은 `keeper_turn_id` 를 인자로 받으면서도 도구마다 registry 사본으로 바뀌는 `meta_ref` 의 `total_turns` 를 보낸다. 턴 도중 그 값을 바꾸는 writer 는 없지만 타입이 막는 약속은 아니다.

## 8. 건드리지 않는 것

keepalive 루프(`keeper_heartbeat_loop.ml`), in-turn pulse, `Workspace.heartbeat` presence, phase FSM, `fiber_health_of`, heartbeat 원장 줄 쓰기, SSE `keeper_heartbeat` 이벤트, `keeper_keepalive_interval_s`/`keeper_snapshot_interval_s` 설정 표시, 운영 workspace 의 런타임 데이터. TLA+ specs 에는 keeper health 규칙이 없다(`KeeperHeartbeat.tla` 는 stale 을 모델링하지 않는다).
