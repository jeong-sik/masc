---
rfc: "0480"
title: "TUI 는 2초마다 다시 읽지 않고, 서버가 바뀌었다고 알릴 때 읽는다"
status: Draft
created: 2026-11-02
updated: 2026-11-02
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0477", "0461", "observe-by-waking-not-polling"]
---

# RFC-0480 — TUI 는 서버가 알릴 때 읽는다

## 0. 요약

TUI 메인 루프는 `--refresh`(기본 2초)마다 화면에 필요한 데이터를 다시 읽는다. SSE 로 받는 것은 네 가지뿐이다.

- 관찰자 피드 `GET /mcp?sse_kind=observer`
- 키퍼 목록의 fleet `GET /api/v1/stream/fleet` (RFC-0477)
- Terminal 탭의 Execute 출력 `GET /api/v1/dashboard/execute-output/<keeper>`
- 채팅 응답 `POST /api/v1/keepers/chat/stream`

서버는 상태가 바뀌면 이미 관찰자 피드로 알린다. TUI 는 그중 채팅, 대기열, fusion, 실행 스냅샷 알림에만 반응한다. 나머지 알림은 Acting 피드에 줄만 남기고, 같은 데이터를 2초마다 다시 읽는다. 게시판 알림은 `type` 이 없는 JSON-RPC 라서 TUI 가 읽지도 못한다(§1.2).

이 RFC 는 TUI 의 주기 읽기를 모두 없앤다. 결정은 다섯 가지다.

1. 서버는 데이터가 바뀔 때 알린다. 알림을 받은 TUI 는 그 화면이 쓰는 정본 경로를 다시 읽는다. `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md` 의 읽기 모델 규칙("SSE 는 신선도를 전하는 길이지 정본 읽기 모델이 아니다")을 그대로 따른다.
2. 키퍼 수만큼 커지는 목록(키퍼 행)은 RFC-0477 처럼 바뀐 값을 타입 이벤트로 받는다. 알림마다 전체 목록을 다시 읽으면 키퍼 300명에서 감당하지 못한다(RFC-0477 §2).
3. 관찰자 피드가 새로 열리거나, 끊긴 사이의 이벤트를 다 이어받지 못했으면 보이는 화면을 한 번 다시 읽는다. 주기 읽기를 지우기 전에 이것부터 넣는다(§3.3).
4. 측정값(지연, 사용량, 비용, 런타임 지표)에는 "바뀌었다"는 사건이 없다. 서버가 `transport_health_snapshot` 을 이미 갱신 루프에서 보내듯, 측정값도 서버가 값을 만들 때 알린다. TUI 에는 타이머를 두지 않는다.
5. 마지막 층에서 메인 루프의 주기 읽기와 `--refresh` 옵션을 지운다. 폴링으로 돌아가는 길은 남기지 않는다. 피드가 끊기면 끊겼다고 보이고, 다시 이어지면 3 의 재읽기로 맞춘다.

## 1. 지금 상태 (main `48879d16f48`, 2026-11-02 직독)

### 1.1 주기 읽기

2초 루프는 `bin/masc_tui.ml` 메인 루프의 `refresh_interval_ns` 비교 블록이다. 한 번 돌 때마다 이렇게 읽는다.

- `launch_local_workspace_read`: 파일 시스템이라 HTTP 가 아니다.
- `open_observer_if_due`, `open_fleet_stream_if_due`: 스트림이 닫혀 있을 때만 연다. 폴링이 아니다.
- `start_http_refresh ~intent:Cadence`: 아래 묶음 읽기.
  - 항상: `GET /health`, `GET /api/v1/dashboard/briefing`, `GET /api/v1/operator?view=summary`, `GET /api/v1/keepers/asks`, `GET /api/v1/lane-addons/asks`
  - 화면 대부분(`needs_keeper_roster`): `GET /api/v1/gate/keepers?detailed=true`
  - `needs_*` 플래그별: 게시판, planning, goals, system logs, transport health, runtime, 비용, 사용량 기록, 계정 이메일
- `launch_tick_side_reads`: `GET /api/v1/keepers/turns` 와 일정(agenda)을 매번 읽는다. 채팅 화면이면 history, native tasks, child content, 채팅 일정도 읽는다.
- `state.view` 별 읽기: Keeper 상세 Info·Secrets(`/api/v1/keepers/composite`), Keeper_calls, 열린 게시글, Verification, Lanes, Clients, Harness, Fusion, Memory, Repositories, Connectors, Runtime, Tools, Config, Schedules, Lane Add-ons

2초 루프 밖에도 타이머가 있다.

- 0.3초: MSX·DOS 관전. `GET /api/v1/lane-addons/live` 와 `POST /api/v1/msx/tick` 을 쓴다.
- 2초: play room `POST /api/v1/play/room`

일부러 주기 읽기에서 뺀 것도 있다. Changes 탭(`file-changes` 는 수 초 걸린다), Resources, Terminal 탭(Execute 스트림이 대신한다)이다.

### 1.2 서버가 이미 알리는데 TUI 가 무시하고 다시 읽는 것

| 알림 | 보내는 곳 | TUI 반응 | 대신 하는 주기 읽기 |
|---|---|---|---|
| `keeper_composite_changed` | `lib/keeper/keeper_registry_broadcast.ml` | 피드 줄만 | Keeper 상세 Info·Secrets, Lanes 화면. 키퍼 한 명을 그리면서 전체 키퍼의 `GET /api/v1/keepers/composite` 를 읽는다 |
| `keeper_tool_call` | `lib/mcp_server_eio_call_tool.ml` 외 | 피드 줄. 상세 Changes 탭만 다시 읽는다 | Keeper_calls 화면 `GET /api/v1/keepers/<k>/tool-calls?limit=100` |
| `keeper_heartbeat`, `keeper_phase_changed`, `keeper_turn_complete` | `keeper_heartbeat_snapshot.ml`, `keeper_registry.ml`, `keeper_hooks_agent_core.ml` | 피드 줄만 | `/api/v1/gate/keepers?detailed=true`, `/api/v1/keepers/turns` 를 매번 |
| `approval:pending`, `approval:summary_updated`, `approval:resolved` | `lib/keeper/keeper_approval_queue_projection.ml` | 피드 줄만 | `/api/v1/dashboard/gate`, `/api/v1/keepers/tool-approvals` |
| `gate_mode_changed`, `gate_keeper_mode_changed` 외 | `lib/server/server_routes_http_routes_dashboard.ml` | 피드 줄만 | 같은 gate 읽기 |
| `notifications/board` (JSON-RPC) | `Board_dispatch.set_board_sse_hook` 설치부, `lib/server/server_bootstrap_loops.ml` | 읽지 못한다. `type` 이 없어 `Undecodable "event carries no type"` 이 된다 | 게시판 목록, 열린 글 |
| `masc/board_post`, `board_comment`, `masc/board_delete` | `lib/mcp_tool_runtime_board.ml` | 피드 줄만 | 같은 게시판 읽기 |
| `internal_agent_runs_changed` | `lib/internal_agent_runs_event.ml` 의 이름, 서버 bootstrap | 피드 줄만 | Verification `GET /api/v1/verification/requests`. 같은 저장소의 변화인지는 확인하지 못했다 |
| `operator_snapshot` | `lib/server/server_dashboard_http_execution_surfaces.ml` | 무시 | `GET /api/v1/operator?view=summary` 를 매번 |
| `transport_health_snapshot` | 같은 파일 | 무시 | Metrics 화면 `GET /api/v1/dashboard/transport-health` |

`notifications/board` 는 `lib/board/board_dispatch.ml` 의 `emit_board_sse_event` 에서 나간다. 글 작성, 댓글, 투표가 이 길을 탄다. 수정, 스레드 변경, 고정, 닫기, 다시 열기, 삭제는 알림 없이 `board_write_hook` 으로 서버 캐시만 지운다(같은 파일의 주석). TUI 가 게시판 알림을 읽게 되더라도, 이 쓰기들은 서버에 알림을 먼저 더해야 화면에 반영된다.

### 1.3 알림과 주기 읽기를 둘 다 하는 것

- `keeper_chat_appended` 가 오면 history 를 다시 읽는다. `launch_tick_side_reads` 도 2초마다 같은 history 를 다시 읽는다.
- `fusion_run_status` 가 오면 fusion 을 다시 읽는다. Fusion 화면도 2초마다 다시 읽는다.
- Execute 출력은 Terminal 탭에서 SSE 로 받는다. Keeper_logs 화면은 같은 출력을 `GET /api/v1/dashboard/execute-output-snapshot/<k>` 로 2초마다 읽는다.

### 1.4 서버가 알리지 않는 데이터

briefing, asks, 일정(agenda·Schedules), async requests, Lane Add-ons, repositories, keeper memory health, harness health, clients, connectors, runtime config 원문, runtime probe·resolved·metrics, keeper costs, provider usage history, account emails, planning, goals, system logs, native tasks·child content hints, OAuth attempt status, MSX·DOS 관전 프레임, play room.

이 데이터는 서버에 알림을 먼저 만들어야 한다.

### 1.5 피드가 다시 열릴 때

`Observer_opened` 는 대기열, 로컬 작업, fusion 만 다시 읽는다. 그 밖의 데이터는 끊긴 동안 바뀐 것을 2초 루프가 메꿔 왔다. 주기 읽기를 지우면 이 구멍이 그대로 남는다.

## 2. 고르지 않은 길

| 안 | 이유 |
|---|---|
| 2초를 늘린다 | 반영만 늦어지고 구조는 같다 |
| 알림 payload 를 정본으로 쓴다 | 스냅샷 알림은 수 MB 까지 간다(`bin/masc_tui_observer.mli`). 읽기 모델 규칙과도 어긋난다 |
| 모든 화면을 RFC-0477 처럼 타입 스트림으로 바꾼다 | 화면마다 서버 허브, 코덱, pump 가 필요하다. 크기가 키퍼 수에 비례하지 않는 화면에서는 비용만 크다 |
| 알림이 없는 화면은 폴링으로 남긴다 | 읽는 길이 둘로 남는다. 어느 화면이 어느 길을 쓰는지 계속 따로 기억해야 한다 |
| 피드가 끊기면 폴링으로 돌아간다 | 두 길을 계속 유지해야 한다. RFC-0477 과 같이 hard cut 한다 |

## 3. 설계

### 3.1 두 가지 길

**알림 → 다시 읽기.** 화면이 한 대상(키퍼 하나, 글 하나)이나 작은 목록을 그릴 때 쓴다.

- 알림에 대상 이름이 있으면, 그 대상을 그리고 있을 때만 읽는다.
- 한 배치(관찰자 리더가 한 번에 넘긴 프레임들) 안에서 같은 읽기는 한 번만 한다. 지금 `Observer_received` 가 채팅과 fusion 에 쓰는 방식이다.
- 읽기는 지금처럼 같은 종류를 하나씩만 보낸다(single-flight). 읽는 중에 알림이 또 오면, 끝난 뒤 한 번 더 읽는다.

**타입 변화 스트림.** 키퍼 수만큼 커지는 데이터에 쓴다. 키퍼 행(`/api/v1/gate/keepers?detailed=true`, `/api/v1/keepers/turns`)은 RFC-0477 의 L5 "키퍼 행 주제"로 옮긴다. RFC-0477 §8 이 열어 둔 "fleet 다음 주제" 결정은 키퍼 행으로 한다. 가장 많은 화면이 매번 읽는 데이터이기 때문이다.

### 3.2 반응할 알림은 생성자로 읽는다

TUI 가 새로 반응할 알림은 `Masc_tui_observer.event` 의 생성자로 더한다. 반응하는 곳은 `Observer_received` 의 exhaustive match 다. 알림을 더하면 컴파일러가 반응하는 곳을 요구한다.

RFC-0461 의 `Push_kind` 는 아직 코드에 없다. 이 RFC 는 그것을 기다리지 않는다. TUI 가 읽어야 하는 종류만 생성자로 둔다. `notifications/board` 는 JSON-RPC `method` 로 구분하고, `params.type`(`post_created`, `comment_added` 등)을 경계에서 닫힌 타입으로 바꾼다. 모르는 값은 `Undecodable` 이다.

### 3.3 끊김과 다시 열림

`Observer_opened` 에서 이어받기 결과가 아래와 같으면 보이는 화면 전체를 `start_http_refresh ~intent:Revalidate` 로 한 번 읽는다.

- `Fresh`, `Reset _`, `Resumed_after_gap _`
- 서버가 이어받기를 지원하지 않는다(`handshake = None`)

`Resumed` 는 끊긴 사이의 이벤트를 모두 이어받은 것이라 다시 읽지 않는다. `relay_subscription_loss` 는 지금처럼 넓게 다시 읽는다.

피드가 끊긴 동안 화면은 마지막 값을 그대로 보이고, 끊긴 시각을 함께 보인다. 지금 쓰는 관찰자 상태 표시를 그대로 쓴다.

### 3.4 서버 알림이 없는 데이터

층마다 서버에서 그 데이터를 쓰는 곳(저장 함수)을 모두 찾아 알림을 낸다. TUI 는 그 알림을 받아 다시 읽는다. 측정값은 서버의 기존 갱신 루프가 값을 만들 때 알린다.

층의 통과 조건은 "쓰는 곳을 다 찾았다"이다. producer → store → consumer → 호출자 진입점을 따라 적는다. 쓰는 곳 하나라도 알림이 빠지면, 그 데이터는 화면에서 멈춘다. 지금은 2초 읽기가 이 빈틈을 가려 왔다.

### 3.5 메인 루프

마지막 층에서 지우는 것은 세 가지다.

- `refresh_interval_ns` 비교 블록
- `--refresh` 옵션
- 쓰는 곳이 남지 않은 `Cadence`, `Snapshot_read.Poll` 의도

0.3초 관전 루프도 프레임 스트림으로 바뀐 층에서 지운다.

## 4. 층

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | 리뷰 |
| L1 | §3.3 다시 열릴 때 다시 읽기 | 이어받기 결과마다 `Revalidate` 요청이 나가는지, `Resumed` 에서는 안 나가는지 |
| L2 | 둘 다 하던 읽기 정리. 채팅 history 와 Fusion 의 2초 읽기를 지운다 | `keeper_chat_appended`·`fusion_run_status` 를 내는 곳이 모든 쓰기를 덮는지. fusion 실행이 처음 생길 때도 알리는지 |
| L3 | `keeper_composite_changed` → Keeper 상세는 그 키퍼만 `/api/v1/keepers/<k>/composite` 로 읽는다. Lanes 는 전체를 읽는다. `keeper_tool_call` → Keeper_calls. 해당 2초 분기를 지운다 | 알림 하나 → 요청 하나(이름이 맞을 때만) |
| L4 | 게시판. 서버는 `board_write_hook` 만 타던 쓰기(수정, 스레드 변경, 고정, 닫기, 다시 열기, 삭제)도 알린다. TUI 는 `notifications/board` 를 읽고 목록과 열린 글을 다시 읽는다. 2초 분기를 지운다 | 위와 같다. 쓰기 종류마다 알림이 나가는지 |
| L5 | 승인·gate 알림 → gate, tool-approvals. `operator_snapshot` → operator 요약 | 위와 같다 |
| L6 | Keeper_logs 의 Execute 출력도 SSE 로 받는다. snapshot 읽기를 지운다. 웹 대시보드도 그 경로를 쓰지 않으면 서버 경로도 지운다 | 화면 증거 |
| L7 | 키퍼 행 스트림(RFC-0477 L5). roster·turns 읽기를 지운다 | RFC-0477 과 같은 방식 |
| L8~ | §1.4 데이터마다 서버 알림과 TUI 반응. 데이터 하나가 층 하나다 | 쓰는 곳 전수 목록 |
| Lz | §3.5 메인 루프 정리 | 2초 블록과 `--refresh` 가 없는지 |

L1 이 들어가기 전에는 어떤 2초 분기도 지우지 않는다.

## 5. 죽은 코드

**이 작업이 죽이는 것.** 층마다 지우는 2초 분기, 쓰는 곳이 없어진 `Cadence`·`Poll` 의도, 0.3초 관전 루프다. 각 층이 같은 PR 에서 지운다. 흔적 주석은 남기지 않는다.

**이미 죽어 있는 것.** 이 RFC 와 별개 스택에서 지운다.

- TUI 모듈(`bin/masc_tui*.mli`)이 내보내는 값 중 bin·lib·test 어디서도 이름이 나오지 않는 값이 18개다.
- 시험만 부르는 값이 33개다.

센 방법은 이렇다. 내보낸 최상위 `val` 의 이름이 자기 모듈 파일 밖의 bin·lib·test 에 한 번도 나오지 않는 것만 셌다. 이름이 흔한 값(`failure_to_string` 등)은 다른 곳에 같은 이름이 있어서 빠졌다. 실제로는 더 있을 수 있다.

## 6. 검증

- TUI 시험은 보낸 요청과 저장한 상태만 본다(constitution `build_and_ci`). 화면 문구 시험은 만들지 않는다.
- 층마다 시험 두 가지를 둔다. 알림 하나가 요청 하나를 만드는지, 그리고 2초 tick 이 그 요청을 더는 내지 않는지다.
- 실제 화면에서는 키퍼 40명 workspace 의 TUI 로그에서 `tui_surface_read_started` 수를 층 전후로 센다. 증거는 `docs/evidence/` 아래에 둔다.

## 7. 트레이드오프와 한계

- 알림이 빠진 쓰기 경로가 있으면 그 화면이 멈춘다. 지금은 2초 읽기가 이 빈틈을 가린다. 그래서 층마다 쓰는 곳을 전수로 확인해야 한다.
- 알림이 아주 잦은 데이터는 알림 → 다시 읽기가 폴링보다 요청이 많을 수 있다. 예를 들어 `keeper_composite_changed` 는 레지스트리 dispatch 마다 나간다. 대상 이름으로 거르고 single-flight 로 줄인다. 그래도 많으면 그 데이터는 타입 스트림(§3.1)으로 옮긴다. 층마다 측정해서 정한다.
- 알림이 없는 옛 서버에 새 TUI 를 붙이면, 해당 데이터는 화면을 열 때 한 번만 읽는다.
- 관찰자 피드 하나에 많은 화면이 기댄다. 피드가 끊기면 대부분의 화면이 마지막 값에서 멈춘다. 끊긴 표시와 다시 열릴 때의 재읽기로 이를 드러낸다.

## 8. 결정이 필요한 것

1. RFC-0477 §8 의 "fleet 다음 주제": 이 RFC 는 키퍼 행으로 정했다. 바꾸려면 알려 달라.
