---
rfc: 0069
title: "Awareness Channel Split"
status: Active
created: 2026-04-29
updated: 2026-05-12
author: yousleepwhen
supersedes: []
superseded_by: null
related: [0017]
implementation_prs: [12129]
---

# RFC-0069 — Awareness Channel Split

> **Renumber note (2026-05-12)**: Originally filed as "RFC PR-1.7" without
> a sequential RFC number (2026-04-29, pre-dating the RFC-XXXX numbering
> convention adopted in May 2026). Assigned RFC-0069 to fit the standard
> registry. File path changed: `docs/rfc/awareness-channel-split.md` →
> `docs/rfc/RFC-0069-awareness-channel-split.md`.

- Status: PR-1.7a **DONE** (server-side, #12129); PR-1.7b / PR-1.7c outstanding
- Author: 부모 에이전트 위임 작업 (yousleepwhen)
- Created: 2026-04-29
- Last revised: 2026-04-30 — postmortem after PR-1.7a server-side landed
- Implementation: PR-1.7a server-side merged as #12129 (Add live presence SSE channel) on 2026-04-30. PR-1.7b (dashboard cutover) and PR-1.7c (broadcast cleanup) pending.
- Related: 외부 전략 문서 [L833-L837] awareness 채널 분리 권고
- Scope guard: 본 PR은 spec 문서만. `lib/`, `dashboard/src/`, `dune` 변경 0.

> **Implementation note (2026-04-30 postmortem)**: the design adopted in
> #12129 differs from the original RFC sec 3.1 권장(대안 2 별도 endpoint) in
> two ways. (a) L1 Coord pubsub split was **dropped** — heartbeats never
> flowed through L1 in the first place (sec 1.1 footnote already noted
> this), so adding a `presence:<project>:default` channel had no source
> traffic to carry. (b) L2 SSE split was implemented as **대안 1 (variant +
> parameterized broadcast_impl)** with a parallel sibling-module attempt
> (#12125 `Sse_presence`) closed via cleanup PR #12144 after audit confirmed
> the variant approach met all RFC constraints (`~buffer:false`,
> `~notify_external:false`, `~event_type:"presence"`, `Presence_only`
> target) without duplicating registry state. The route stayed on a
> separate HTTP endpoint (`/events/presence`) per the original sec 3.1
> 대안 2 recommendation.
>
> Net effect: the *behavioral* spec below holds. Section 3.1 (alternative
> selection), 3.2 (publisher mapping), and 4.1 (server-side impact) have
> been refreshed to match #12129. Section 4.4 stage 1 is **complete**.

---

## 0. 용어 (Terms)

본 문서는 "broadcast"라는 단어가 두 개의 서로 다른 레이어를 가리키는 사실을
먼저 분리한다. 두 레이어는 독립적이며, 채널 분리 RFC는 둘 다를 함께 다룬다.

| 레이어 | 식별자 | 위치 | 소비자 |
|--------|--------|------|--------|
| L1: Coord pubsub 채널 | `broadcast:<project>:default` (string key) | `lib/coord/coord_broadcast.ml:58-59` | `Backend_types.Pubsub_mem` 구독자 (현재 in-process), 잔존 메시지는 `messages_dir/*.json` |
| L2: SSE wire event_type | `masc:broadcast`, `keeper_heartbeat` 등 | `lib/sse.ml`, `lib/oas_event_bridge.ml:350-365` | dashboard `dashboard/src/sse-store.ts:121-143` |

L1은 "메시지를 어디에 publish 하느냐"의 채널 이름. L2는 "SSE에 어떤
`event_type` 문자열로 흘려보내느냐"이다. dashboard의 부하는 L2 쪽이 우세하지만
publisher 분리는 L1 + L2 양쪽에서 일관성을 맞춰야 한다.

---

## 1. 현재 상태 (As-Is)

### 1.1 L1 Coord 단일 채널

`lib/coord/coord_broadcast.ml:58-89` — 단일 채널 정의 + publish:

```ocaml
let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

let broadcast ?trace_context config ~from_agent ~content =
  ...
  let msg = {
    seq;
    from_agent = safe_agent;
    msg_type = "broadcast";
    content = safe_content;
    mention;
    timestamp = now_iso ();
    trace_context;
  } in
  ...
  (match backend_publish config ~channel:(broadcast_channel config)
      ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
   | Ok _ -> ()
   | Error (Backend_types.BackendNotSupported msg) when ... -> ...
   | Error e -> Log.Misc.error "broadcast publish failed: %s" ...);
```

이 함수의 caller (검색 결과 `rg -n "broadcast " lib/coord/`, 본 RFC 작성 1일 후 `coord_task` 모듈이 `coord_task.ml` + `coord_task_create.ml`로 분리 + `coord_lifecycle` 추가 호출 발생):

| 호출자 | 파일:라인 | 메시지 종류 |
|--------|----------|-------------|
| `coord_task.claim_task` | `coord_task.ml:853` | `📋 Claimed <task_id>` 등 (claim/transition 알림) |
| `coord_task_create.batch_add_tasks` | `coord_task_create.ml:229` | `✅ Added N tasks: <summary>` (배치 task 추가) |
| `coord_lifecycle.rejoin` | `coord_lifecycle.ml:108` | `👋 <agent> rejoined the namespace` |
| `coord_lifecycle.join` | `coord_lifecycle.ml:172` | `👋 <agent> joined the namespace` |
| `coord_lifecycle.leave` | `coord_lifecycle.ml:237` | `👋 <agent> left the namespace` |
| 사용자 채팅/멘션 | `tool_inline_dispatch_comm.ml:37` 경유 | 일반 broadcast (멘션 포함) |

확인된 사실: **`coord_gc.ml:17` `heartbeat` 함수는 broadcast 채널에 publish하지 않는다.**
heartbeat는 `agent_file`의 `last_seen`만 갱신한다. heartbeat가 채널 트래픽을 만드는
지점은 L2 (SSE)뿐이다.

### 1.2 L2 SSE 단일 stream

`lib/sse.mli:16-19` — 단일 stream 안에서 `broadcast_target` 분기만 존재:

```ocaml
type broadcast_target =
  | All
  | Observers
  | Coordinators
```

dashboard 소비자는 단일 SSE 연결을 열고 `event_type` 문자열로 fan-out한다.
heartbeat 이벤트 publisher (`lib/keeper/keeper_heartbeat_snapshot.ml:395-402` — full snapshot heartbeat. RFC 작성 1일 후 `keeper_keepalive.ml`이 `keeper_heartbeat_snapshot.ml` + `keeper_heartbeat_loop.ml`로 분리됨):

```ocaml
Sse.broadcast
  (`Assoc
      [ "type", `String "keeper_heartbeat"
      ; "name", `String meta_current.name
      ; "generation", `Int meta_current.runtime.generation
      ; "context_ratio", `Float context_ratio_v
      ; "ts_unix", `Float now_ts
      ])
```

dashboard route table (`dashboard/src/sse-store.ts:121-143`):

```ts
const SIMPLE_ROUTES: Record<string, SimpleRoute> = {
  'masc/agent_joined':  { target: 'execution' },
  'masc/agent_left':    { target: 'execution' },
  'masc/broadcast':     { target: 'execution' },
  keeper_handoff:       { target: 'execution' },
  keeper_compaction:    { target: 'execution' },
  keeper_phase_changed: { target: 'execution' },
  'masc/board_post':    { target: 'board' },
  ...
}
```

heartbeat 전용 처리는 `dashboard/src/sse-store.ts:479-482`:

```ts
if (event.type === 'keeper_heartbeat') {
  handleKeeperHeartbeat(event)
  return true
}
```

### 1.3 SSE wire 이벤트별 publisher (정리)

| event_type (wire) | 빈도 | 직접 publisher | 사용처 |
|-------------------|------|---------------|--------|
| `keeper_heartbeat` (full snapshot) | keeper × keepalive 주기 (~5s) | `keeper_heartbeat_snapshot.ml:395` `Sse.broadcast` | dashboard heartbeat tick, status |
| `keeper_heartbeat` (in-turn pulse, `phase: "turn_running"`, `in_turn: true`) | keeper × in-turn pulse 주기 (`in_turn_liveness_pulse_interval_sec`, 별도 cadence) | `keeper_heartbeat_loop.ml:253` `Sse.broadcast` | dashboard liveness during long turns |
| `masc:broadcast` (구 `masc.broadcast`) | 사용자 broadcast/claim/task 알림 | `oas_event_bridge.ml` relay (`. → :`) | live feed, execution 패널 |
| `masc:keeper:lifecycle` | keeper 시작/재시작/사망 (수 분 ~ 시간 단위) | `oas_events.publish_keeper_lifecycle` (`keeper_keepalive.ml:426-448`) | operator 알림 |
| `masc:keeper:snapshot` | heartbeat tick과 동일 주기 | `oas_events.publish_keeper_snapshot` (`keeper_heartbeat_snapshot.ml:409`) | dashboard 카드 |
| `keeper_composite_changed` | composite FSM 전이 시 | `keeper_registry.ml:454` `Sse.broadcast` | dashboard composite tick |
| `masc:keeper:dead` | keeper 사망 감지 시 | `oas_events.publish_keeper_dead` (`keeper_supervisor.ml:935`) | operator 즉시 알림 |
| `masc:board_post`, `post_created`, `comment_added` | 게시글 활동 시 | `lib/server/server_bootstrap_loops.ml` board hook | board 패널 |
| `task_*` (prefix) | task 상태 전이 시 | `oas_events.publish_task_transition` | execution 패널 |
| `activity_*` (prefix) | activity graph emit 시 | `Coord_hooks.activity_emit_fn` | activity 그래프 |

heartbeat-tick 등가물은 **3줄**: `keeper_heartbeat` (full snapshot) + `keeper_heartbeat` (in-turn pulse) + `masc:keeper:snapshot`.
full snapshot tick은 keeper 1개당 ~5s 주기. in-turn pulse는 turn 진행 중에만 별도 cadence로 발생 (검증 필요 — 실제 주기는
`Env_config.Keeper.keepalive_interval_seconds` + `in_turn_liveness_pulse_interval_sec`).

> 참고: `lib/oas_events.ml:30-46`의 `publish_broadcast` / `publish_heartbeat` 두 함수는
> 현재 `test/test_oas_integration.ml`에서만 호출된다 (`rg "publish_heartbeat|publish_broadcast"` 결과).
> 실 production heartbeat는 `Sse.broadcast` 직접 호출 + `publish_keeper_snapshot` 경로다.

---

## 2. 문제 (Why)

### 2.1 정량 추정 (12 keeper 운영 기준)

사용자 답변에 따라 **목표 운영 규모는 12+ keeper** (외부 전략 문서의 50 keeper
가정이 아님). 12 × 5s keepalive = **2.4 hb/s**. 세 이벤트 (full snapshot heartbeat
+ in-turn pulse heartbeat + `masc:keeper:snapshot`)이 모두 발생하면 keeper × 진행 turn 비율과
in-turn pulse cadence에 따라 **~4.8-7.2 evt/s** (lower bound: 모든 keeper idle, in-turn pulse 0;
upper bound: 모든 keeper turn 진행 중)가 SSE awareness 잡음으로 흐른다.

사용자 활동 (broadcast/claim/board) 추정 — 정상 운영 시:

| 활동 | 예상 빈도 (추정) |
|------|-----------------|
| 사용자 broadcast (채팅/멘션) | 1-10건/분 = 0.02-0.17/s |
| task claim | 1-5건/분 = 0.02-0.08/s |
| board post/comment | 1건/분 = 0.02/s |
| 합계 | ~0.05-0.30/s **(추정, 검증 필요)** |

heartbeat:user-activity 비율 ≈ 16:1 ~ 96:1. **heartbeat가 awareness 트래픽의
약 94-99% 차지** (추정, 실측 baseline은 PR-0.2 이후 갱신 필요).

분리 후 가정:

- `broadcast` 채널: 사용자 활동만 → `~0.05-0.30 evt/s`
- `presence` 채널: heartbeat + snapshot → `~4.8 evt/s` (debounce 전)
- presence debounce 200ms batching 적용 시 → `~5 evt/s` 입력이 1 batch/200ms = **5 evt/s 그대로 또는 합쳐서 ~2-3 batch/s** (12 keeper 동시 tick 시 최대 1 batch에 집계)

### 2.2 현재 구조의 비용

1. **dashboard SSE consumer**: 모든 이벤트가 동일 stream에 흐르므로 `event_type` 문자열 매칭 후 라우팅.
   `sse-store.ts:121-490` 라인의 if/SIMPLE_ROUTES 조회가 매 tick마다 실행된다.
2. **SSE buffer pressure**: `lib/sse.ml`의 `event_buffer`가 단일 ring으로 모든 이벤트를 보존.
   heartbeat가 다수 차지하면 user-activity 이벤트의 `Last-Event-Id` 재구독 시 retention이 짧아진다.
3. **debounce 부재**: presence-class 이벤트는 본질적으로 burst 가능 (12 keeper가 동일 phase boundary에서
   동시 tick) — 현재는 batching 없이 그대로 fan-out.
4. **filtering 어려움**: `LiveFilterKind = 'broadcast' | 'tasks' | 'keepers' | 'system'` (`live-store.ts:14`).
   '실제 사용자 broadcast만 보고 싶다'는 필터가 'keeper heartbeat'을 함께 끄는 효과를 낸다.

### 2.3 ROI 갱신 (12 keeper, 외부 문서 -90% → 본 RFC 추정)

외부 문서 [L833-L837]의 -90% 수치는 50 keeper 가정. 본 RFC는 12 keeper 기준으로
조정한다.

| 지표 | 현재 (단일 채널) | 분리 후 (`broadcast` 채널만 기준) | 절감 |
|------|------------------|-----------------------------------|------|
| broadcast 채널 evt/s | ~5.0 (heartbeat 포함) | ~0.05-0.30 (사용자 활동만) | **~94-99% 감소** |
| dashboard '실제 활동' filter 정확도 | heartbeat 누설 | clean | 정성적 개선 |
| awareness debounce 적용 가능성 | 없음 | presence 채널 한정 가능 | 신규 옵션 |

**(검증 필요)** 위 수치는 12 keeper × 5s × 2 event/tick 추정. 실측 baseline은
PR-0.2 (perf baseline) 머지 후 `prometheus.metric_sse_broadcast_events`로 갱신.

---

## 3. 새 설계 (To-Be)

### 3.1 새 채널 도입 (As-Implemented in #12129)

#### L1 Coord 레이어 — **변경 없음**

원안은 `presence:<project>:default` pubsub 채널을 신설했으나,
구현 단계에서 L1 트래픽 audit 결과 heartbeat-class 이벤트는 L1 coord pubsub로
publish되지 않음을 (재)확인했다 (sec 1.1 footnote 참조 — `coord_gc.ml:17`
heartbeat 함수는 `agent_file.last_seen`만 갱신하지 channel publish 없음).
따라서 L1 split은 source traffic이 0이어서 무의미. `coord_broadcast.ml`
`broadcast_channel`은 그대로 유지된다.

#### L2 SSE 레이어 — variant + parameterized `broadcast_impl`

dashboard 클라이언트는 두 개의 SSE 연결을 유지:

```text
GET /mcp                     (유지, MCP transport observer/coordinator stream)
GET /events/presence         (신설, presence-class events 전담; #12129)
```

**채택된 디자인 = 대안 1 + 대안 2 hybrid**. SSE registry는 단일 (`Sse.clients`)을
유지하되 `session_kind`에 `Presence` variant를 추가하고, `broadcast_target`에
`Presence_only` variant를 추가하며, `broadcast_impl`을 3개 옵션 플래그로
파라미터화한다:

```ocaml
(* lib/sse.ml 발췌 — #12129 *)
type session_kind = Observer | Coordinator | Presence
type broadcast_target = All | Observers | Coordinators | Presence_only

let broadcast_impl ?(buffer = true) ?(notify_external = true)
    ?(event_type = "message") target json = ...

let broadcast_presence json =
  broadcast_impl ~buffer:false ~notify_external:false
    ~event_type:"presence" Presence_only json
```

3개 플래그가 RFC 의도를 정확히 만족한다:

| RFC sec 2.2 우려 | 대응 |
|---|---|
| 2.2.1 dashboard SSE consumer 라우팅 부담 | `Presence_only` 필터 + 별도 endpoint로 main stream 부담 0 |
| 2.2.2 `Sse.event_buffer` retention 단축 | `~buffer:false` — presence 이벤트는 ring buffer에 들어가지 않음 |
| 2.2 외부 consumer 호환성 (sec 4.3) | `~notify_external:false` — gRPC `subscribe_external` / ws_standalone에 presence 프레임 누설 없음 |
| 2.2.3 debounce 적용 가능성 | presence-class만 별도 wrapper에서 batch 가능 (구현 계류) |

HTTP endpoint는 별도 (`/events/presence`)로 분리되어 dashboard가 페이지 가시성에 따라
독립 EventSource 관리 가능 (대안 2 의도). registry storage는 통합되어 있어
중복 코드 없음 (대안 1 의도). 두 selection은 trade-off가 아니라 직교한다.

> **Why not separate `Sse_presence` module?** PR-1.7a-1-α (#12125) 시도가 별도
> 모듈로 200+ LOC 추가했으나, 위 4 우려 모두 단일 모듈 + 3 flag로 동일하게
> 충족됨이 audit (#12144 cleanup body) 에서 확인되어 #12144로 제거됨. 별도 모듈은
> (a) 분리된 Last-Event-Id 시퀀스 + replay, (b) per-channel `max_clients` 분리,
> (c) lifecycle 분리 모두 *진짜* 필요할 때만 escalate한다 — 본 RFC scope에서는
> 셋 중 어느 것도 hard requirement가 아니었다.

### 3.2 publisher 분리 표

| 메시지 종류 | 현재 wire `event_type` | 현재 채널 | 새 채널 | 비고 |
|------------|------------------------|----------|--------|------|
| heartbeat tick (full snapshot) | `keeper_heartbeat` | broadcast | **presence** | ✓ `keeper_heartbeat_snapshot.ml:404-405` dual emit (`Sse.broadcast json; Sse.broadcast_presence json`) — #12129 |
| heartbeat in-turn pulse | `keeper_heartbeat` (`in_turn: true`) | broadcast | **presence** | ✓ `keeper_heartbeat_loop.ml:263-264` dual emit — #12129 |
| keeper snapshot | `masc:keeper:snapshot` | broadcast | **presence** | dual emit via `oas_event_bridge.ml` relay 변경 — #12129 |
| keeper composite changed | `keeper_composite_changed` | broadcast | **presence** | ✓ `keeper_registry.ml:459-460` dual emit — #12129 |
| task claim 알림 | (`coord_broadcast.broadcast` → `masc:broadcast`) | broadcast | broadcast (유지) | |
| task add/batch 알림 | `masc:broadcast` | broadcast | broadcast (유지) | |
| 사용자 채팅 / 멘션 | `masc:broadcast` (mention 필드 포함) | broadcast | broadcast (유지) | |
| activity event | `activity` (+ `activity_*` prefix) | broadcast | broadcast (유지) | activity graph는 사용자 활동 |
| keeper lifecycle | `masc:keeper:lifecycle` | broadcast | broadcast (유지) | 빈도 낮음 (수 분 ~ 시간), 사용자 시인성 필요 |
| keeper dead | `masc:keeper:dead` | broadcast | broadcast (유지) | 사용자 즉시 알림 필요 |
| board post / comment | `post_created`, `comment_added`, ... | broadcast | broadcast (유지) | |
| task_* prefix | `task_*` | broadcast | broadcast (유지) | |

원칙: **"사람이 결정/반응할 이벤트는 broadcast, 단순 살아있음 신호는 presence"**.
keeper lifecycle은 빈도가 낮고 인간 의사결정 트리거이므로 broadcast 유지.
keeper snapshot/heartbeat은 dashboard 카드의 `last_seen` 갱신용 → presence.

### 3.3 debounce / batching (presence 채널만)

- 50-200ms debounce window (200ms 기본)
- batch shape: `{ "type": "presence_batch", "ts_unix": ..., "items": [ {keeper_heartbeat...}, ... ] }`
- broadcast 채널은 **debounce 적용 금지** (사용자 활동은 즉시 보여야 함)
- 200ms 선택 근거: 12 keeper × 5s tick → 한 phase에 동시 발생할 확률이 있고, 200ms 안에
  전부 수렴 가능 (검증 필요 — 실제 분산은 PR-0.2 baseline에서 측정)

### 3.4 backward compatibility wire

`oas_event_bridge.ml:348-366`의 점→콜론 변환 (`masc.heartbeat` → `masc:heartbeat`)은 유지.
신규 endpoint도 동일 변환을 적용한다. wire 이름 자체는 바꾸지 않는다 (호환성 우선).

---

## 4. 호환성 / 마이그레이션

### 4.1 server-side 영향 (As-Implemented in #12129)

| 컴포넌트 | 변경 | 위험 (실측) |
|---------|------|------|
| `coord_broadcast.ml` | **변경 없음** (L1 split 불필요로 판명, 본 RFC 헤더 postmortem 참조) | — |
| `keeper_heartbeat_snapshot.ml:404-405` (full snapshot) + `keeper_heartbeat_loop.ml:263-264` (in-turn pulse) + `keeper_registry.ml:459-460` (composite_changed) | 기존 `Sse.broadcast` 호출 옆에 `Sse.broadcast_presence` 추가 (dual emit). 기존 호출 무변경. | 낮음 — additive 3곳, 호환성 wire-breaking 0 |
| `oas_event_bridge.ml` | `masc.heartbeat` / `masc.keeper.snapshot` relay 시 `~target:Presence_only` 분기 추가 | 낮음 — additive relay |
| `lib/sse.ml/.mli` | `session_kind` variant `Presence` 신설 + `broadcast_target` variant `Presence_only` 신설 + `broadcast_impl` 옵션 플래그 (`?buffer`, `?notify_external`, `?event_type`) + `broadcast_presence` wrapper | 낮음 — type 확장 (additive). 기존 caller 무영향 |
| `server_mcp_transport_http_agui.ml/.mli` | `handle_presence_events` (`GET /events/presence`) handler 신설. `Sse.register ~kind:Sse.Presence`로 등록. replay 없음 (`buffer:false` 일관) | 중간 — 신규 SSE endpoint, auth 통과 검증 필요 |
| `server_routes_http_routes_frontend.ml:96` | `Http.Router.get "/events/presence" handle_presence_events` | 낮음 — additive 1줄 |
| `server_auth.ml/.mli` | presence endpoint를 auth scope에 등록 | 낮음 — config 추가 |
| `lib/transport_metrics.ml` | `sse_sessions{kind=presence}` Prometheus label 추가 | 낮음 — metric label 확장 |
| `lib/sse_presence.ml/.mli` (PR-1.7a-1-α 시도, #12125) | sibling-module 별도 registry 시도 → audit 후 dead code 판명, #12144로 제거 | — (정정 완료) |

### 4.2 client-side 영향

| 컴포넌트 | 변경 | 위험 |
|---------|------|------|
| `dashboard/src/sse-store.ts` | `EventSource('/events/presence')` 추가 + 별도 routing | 중간 — 두 stream 통합 시점 동기화 |
| `dashboard/src/types/sse.ts` | `EventType`에서 heartbeat류만 presence stream으로 분리 | 낮음 |
| 외부 SSE consumer | `/events/broadcast`만 보던 외부 도구는 heartbeat을 못 받게 됨 | **고위험 (검증 필요)** — 아래 4.3 |

### 4.3 외부 consumer 호환성 (가장 큰 위험)

dashboard 외에 SSE를 직접 소비하는 클라이언트가 있는지 확인 필요:

- gRPC gateway (`lib/grpc/masc_grpc_service.ml:511` `Sse.subscribe_external`): `Sse.broadcast` 호출을 gRPC Event로 변환.
  분리 후 두 채널을 모두 fan-out하도록 갱신 필요. **(검증 필요)** gRPC stream은 단일이므로
  presence/broadcast 양쪽을 통합 stream으로 보낼지 분리할지 결정 필요.
- WebSocket cutover (`dashboard-ws-cutover.ts`): 단일 stream 가정. 분리 시 동일 패턴 필요.
- `subscribe_external` (`lib/sse.mli:84`) 콜백: 외부 가입자가 모든 이벤트를 받으므로
  분리 후 채널 필터를 노출해야 함. **(검증 필요)** 현재 가입자 목록 audit 필요.

**롤백 안전망**: 분리 PR (PR-1.7a) 머지 직후에도 `/events/broadcast`는 기존 wire와
동일하게 유지되며 heartbeat 만 빠진다. 외부 consumer가 heartbeat에 강결합되어 있다면
PR-1.7a를 revert하면 즉시 원상복구.

### 4.4 단계적 마이그레이션 plan

1. **단계 1 (server-side, additive)** — ✓ **COMPLETE (#12129, 2026-04-30)**:
   `Sse.Presence` session_kind + `Sse.broadcast_presence` helper + `/events/presence`
   endpoint 추가. 기존 broadcast 채널에서도 heartbeat을 **계속** 발행 (dual emit).
   기존 consumer 무영향.
2. **단계 2 (client cutover)** — pending: dashboard가 `/events/presence` 구독 시작. broadcast stream 의
   heartbeat 처리는 유지 (양쪽 다 받지만 dedup).
3. **단계 3 (broadcast cleanup, deprecation period 후)** — pending: broadcast 채널에서 heartbeat 발행
   중단. **wire breaking change** (외부 consumer 공지 필수, 특히 sec 4.3의 3 unfiltered
   subscriber: `server_ws_standalone.ml:44`, `server_mcp_transport_ws.ml:821`,
   `masc_grpc_service.ml:511`).

각 단계는 별도 PR (PR-1.7a / PR-1.7b / PR-1.7c).

---

## 5. 검증

### 5.1 정량 검증

- **Before/after evt/s 비교**: PR-0.2 baseline (`metric_sse_broadcast_events`)을
  분리 PR 머지 전후로 24h 비교. broadcast 채널 -90% 이상이면 가설 확인 (12 keeper 기준).
- **buffer retention**: `Sse.event_buffer` 의 oldest event age 측정. 분리 후
  broadcast 쪽 retention이 길어져야 함.
- **dashboard CPU**: dashboard tab의 main-thread CPU 사용률 (heartbeat 처리 분리 효과).
  Chrome DevTools Performance 측정 (검증 필요).

### 5.2 회귀 테스트

- `test/test_oas_integration.ml` 의 `publish_heartbeat` / `publish_broadcast` 테스트가
  새 채널 라우팅을 확인하도록 업데이트 (별도 PR).
- dashboard `sse-store.test.ts`에서 두 stream 동시 구독 시 dedup 동작 단위 테스트.
- E2E (Playwright): 12 keeper 시뮬레이션 + dashboard에서 실제 사용자 broadcast 1건이
  heartbeat 사이에 노출되는지.

### 5.3 long-haul 검증

- 24h 운영 후:
  - presence 채널만 ~4-5 evt/s, broadcast ~0.1-0.3 evt/s 인지 확인
  - dashboard 사용자가 'broadcast filter'로 heartbeat 잡음 0인지 확인
  - keeper 사망 lifecycle 이벤트가 broadcast 채널에 정상 도달하는지 확인

---

## 6. 위험 / 롤백

### 6.1 위험 매트릭스

| 위험 | 영향 | 대응 |
|------|------|------|
| 외부 SSE consumer 호환성 (4.3) | **고** | dual emit 단계로 deprecation period 확보. 외부 consumer audit 선행. |
| dashboard race (heartbeat가 broadcast보다 늦게 도달) | 중 | 두 stream 사이 ordering guarantee 없음 — dashboard가 timestamp 기반 정렬. presence는 `last_seen` 갱신만 담당하므로 순서 손실 영향 작음. |
| presence batching debounce가 keeper death 감지를 지연 | 중 | death detection은 `cleanup_zombies` (`coord_gc.ml:39`) 가 별도로 처리. heartbeat ack는 presence 채널에 의존하지 않음. |
| gRPC gateway / WebSocket cutover 호환성 | 중 | 같은 단계화 적용. (검증 필요) gRPC가 단일 channel만 노출한다면 server 단에서 union 후 송신. |
| L1 Coord pubsub 가입자 (`backend_subscribe`)가 heartbeat 기대 | 저 | 현재 가입자는 in-process. `rg "backend_subscribe"`로 audit. |

### 6.2 롤백 시나리오

- **PR-1.7a 직후 문제**: `/events/presence` endpoint 비활성화 + heartbeat을 broadcast로
  되돌리는 1-line revert. dashboard는 fallback으로 broadcast 만 본다.
- **PR-1.7c (cleanup) 후 외부 issue**: PR-1.7c revert 시 즉시 dual emit 복원.
- **단일 채널 완전 복원**: 위 RFC 자체를 revert하고 `coord_broadcast.broadcast_channel`을
  유일 channel로 사용 (현재 상태).

---

## 7. 구현 plan (별도 PR)

| PR | 범위 | 위험 | 상태 |
|----|------|------|------|
| **PR-1.7a** | server-side 추가: `Sse.Presence` session_kind + `Sse.broadcast_presence` (parameterized `broadcast_impl`) + `/events/presence` endpoint + dual emit at 3 sites (`keeper_heartbeat_snapshot:404`, `keeper_heartbeat_loop:263`, `keeper_registry:459`) + `oas_event_bridge` relay 분기 + presence transport_metrics label | 낮음 — additive, 기존 consumer 무영향 | ✓ **DONE — #12129** (2026-04-30) |
| **PR-1.7b** | dashboard client: `/events/presence` 구독 + dedup, presence stream filter UI | 중 — 두 stream 동기화 | pending |
| **PR-1.7c** | broadcast 채널에서 heartbeat 발행 제거 (deprecation period ≥14d 후). 사전 audit: `Sse.subscribe_external` 가입자 3곳 (gRPC `subscribe`, ws_standalone, transport_ws) 이 heartbeat에 의존하는지 확인 후 진행 | **고 — wire breaking change** | pending |

각 PR은 단독으로 revert 가능. 본 spec PR은 위 3개 PR 머지 전 사전 합의용.

### 7.1 closed sub-tracks (postmortem 참조)

- **PR-1.7a-0** (#12115, 머지): RFC `file:line` ref drift refresh — `keeper_keepalive.ml`이 `keeper_heartbeat_snapshot.ml` + `keeper_heartbeat_loop.ml`로 리팩토링되며 발생한 doc-vs-code drift를 정리.
- **PR-1.7a-1-α** (#12125 → #12144, 제거): sibling `Sse_presence` module 시도. variant 디자인 (#12129)이 superset-absorb한 후 dead code로 판명되어 정리.

---

## 8. Open Questions (검증 필요)

1. **(부분 해결, PR-1.7c 검증 영역)** gRPC gateway (`masc_grpc_service.ml:511` `Sse.subscribe_external`) 가입자 union 처리:
   - PR-1.7a (#12129)는 `~notify_external:false`로 presence 프레임이 gRPC stream에 누설되지 않게 처리.
   - 따라서 PR-1.7a 머지로 gRPC 가입자는 *기존과 동일하게* heartbeat을 broadcast 경로에서 받는다. 호환성 0 영향.
   - PR-1.7c (broadcast cleanup) 시 gRPC 가입자가 heartbeat 의존하는지 audit 필요. 같은 audit이 sec 4.3의 3 가입자 전체에 적용된다.
2. **(부분 해결, sub-agent audit 2026-04-30 결과)** `Sse.subscribe_external` 가입자 목록:
   - 3 가입자 모두 unfiltered (이벤트 type 분기 없음) — `server_ws_standalone.ml:44`, `server_mcp_transport_ws.ml:821`, `masc_grpc_service.ml:511`. 셋 다 `Sse.broadcast` callback으로 수신.
   - PR-1.7c 시점 이들이 heartbeat 의존하는지 확정 audit 필요.
3. presence debounce window: 200ms vs 50ms vs 500ms — 12 keeper 기준 dashboard UX 측정 필요. PR-1.7b dashboard cutover 시점에 결정.
4. **(해결)** `/events/presence` 인증: PR-1.7a (#12129)에서 broadcast 와 동일 auth scope 적용 (server_auth.ml/.mli 확장).
5. **(해결, not applicable)** `Last-Event-Id` 재구독 시 두 channel 간 인덱스 분리: presence는 `~buffer:false`로 ring buffer에 들어가지 않으므로 *어떠한 replay도 발생하지 않음*. 재접속 시 future 프레임만 수신. 별도 sequence index 불필요.

---

## 9. 작업 영역 / 변경 없음 항목

본 spec 문서의 두 차례 갱신 history:

- **2026-04-29** (최초 spec, #11986): RFC 신규 작성. 코드 변경 0.
- **2026-04-30 PR-1.7a-0** (#12115): `keeper_keepalive.ml` 리팩토링 후 file:line ref drift 일괄 정리.
- **2026-04-30 본 갱신**: PR-1.7a (#12129) 머지 후 spec sec 3.1, 3.2, 4.1, 4.4, 7, 8 정합. 본 변경도 코드 변경 0 (문서만).

다음 트랙은 **PR-1.7b (dashboard cutover)** 부터 시작.
