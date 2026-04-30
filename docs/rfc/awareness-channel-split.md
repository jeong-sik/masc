# RFC PR-1.7 — Awareness Channel Split (Spec)

- Status: Spec (코드 변경 0)
- Author: 부모 에이전트 위임 작업 (yousleepwhen)
- Created: 2026-04-29
- Implementation: 별도 PR (PR-1.7a/b/c) — 본 문서 머지 후 별도 트랙
- Related: 외부 전략 문서 [L833-L837] awareness 채널 분리 권고
- Scope guard: 본 PR은 spec 문서만. `lib/`, `dashboard/src/`, `dune` 변경 0.

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

### 3.1 새 채널 도입

#### L1 Coord 레이어

```text
broadcast:<project>:default   (유지, 사용자 활동 전용)
presence:<project>:default    (신설, awareness 전용)
```

#### L2 SSE 레이어

dashboard 클라이언트가 두 개의 SSE 연결을 유지하는 모델.

```text
GET /events/broadcast        (유지, heartbeat류 제거)
GET /events/presence         (신설, heartbeat류 전담)
```

대안 1: 단일 SSE 연결 + `Sse.broadcast_to (Channel "presence")` 같은 새 target
variant 추가. 구현은 더 가볍지만 client 측 fan-out 코드는 그대로 남는다.

대안 2 (권장): **별도 HTTP endpoint**. SSE 연결을 둘로 나누면 브라우저는 두 개의
독립 EventSource를 관리하며, presence 연결은 user 페이지 가시성에 따라 끊을 수
있다. 본 RFC는 대안 2를 채택한다 (검증 필요 — 브라우저 max EventSource 한도
6/host는 단일 dashboard 1 사용자에 영향 없음).

### 3.2 publisher 분리 표

| 메시지 종류 | 현재 wire `event_type` | 현재 채널 | 새 채널 | 비고 |
|------------|------------------------|----------|--------|------|
| heartbeat tick (full snapshot) | `keeper_heartbeat` | broadcast | **presence** | `keeper_heartbeat_snapshot.ml:395` `Sse.broadcast` → `Sse.broadcast_to (Presence)` 또는 `presence`-tag |
| heartbeat in-turn pulse | `keeper_heartbeat` (`in_turn: true`) | broadcast | **presence** | `keeper_heartbeat_loop.ml:253` `Sse.broadcast` → `Sse.broadcast_to (Presence)` |
| keeper snapshot | `masc:keeper:snapshot` | broadcast | **presence** | `oas_events.publish_keeper_snapshot` (`keeper_heartbeat_snapshot.ml:409`) 경로의 SSE bridge dispatch tag만 변경 |
| keeper composite changed | `keeper_composite_changed` | broadcast | **presence** | `keeper_registry.ml:454` composite tick은 heartbeat-등가 |
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

### 4.1 server-side 영향

| 컴포넌트 | 변경 | 위험 |
|---------|------|------|
| `coord_broadcast.ml` | `broadcast_channel`은 그대로. presence 채널 헬퍼 추가 (`presence_channel`). | 낮음 — additive |
| `keeper_heartbeat_snapshot.ml:395` (full snapshot) + `keeper_heartbeat_loop.ml:253` (in-turn pulse) + `keeper_registry.ml:454` (composite_changed) | `Sse.broadcast` → `Sse.broadcast_to Presence` 또는 새 dispatch helper | 중간 — 호출부 3곳, **(검증 필요)** snapshot publish 경로의 SSE relay 태그도 같이 |
| `oas_event_bridge.ml` | `masc.heartbeat`/`masc.keeper.snapshot` 등을 presence target으로 라우팅 | 중간 — relay logic 수정 |
| `lib/sse.ml` | `broadcast_target` variant에 `Presence`/`PresenceObservers` 같은 신규 추가 또는 별 set 분리 | 낮음 — type 확장 |
| HTTP routes | `/events/presence` GET handler 추가 (`server_routes_http_*` 안에서 SSE 연결 등록 분기) | 중간 — `Sse.register` 의 `kind` 확장 또는 별도 registry |

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

1. **단계 1 (server-side, additive)**: `presence` 채널과 `/events/presence` endpoint를
   *추가*. 기존 broadcast 채널에서도 heartbeat을 **계속** 발행 (dual emit). 기존 consumer 무영향.
2. **단계 2 (client cutover)**: dashboard가 `/events/presence` 구독 시작. broadcast stream 의
   heartbeat 처리는 유지 (양쪽 다 받지만 dedup).
3. **단계 3 (broadcast cleanup, deprecation period 후)**: broadcast 채널에서 heartbeat 발행
   중단. wire breaking change (외부 consumer 공지 필수).

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

| PR | 범위 | 위험 |
|----|------|------|
| **PR-1.7a** | server-side 추가: `presence_channel` 헬퍼, `/events/presence` route, `Sse.broadcast_to Presence`, dual emit (broadcast + presence 동시) | 낮음 — additive, 기존 consumer 무영향 |
| **PR-1.7b** | dashboard client: `/events/presence` 구독 + dedup, presence stream filter UI | 중 — 두 stream 동기화 |
| **PR-1.7c** | broadcast 채널에서 heartbeat 발행 제거 (deprecation period 14d 후) | **고 — wire breaking change** |

각 PR은 단독으로 revert 가능. 본 spec PR은 위 3개 PR 머지 전 사전 합의용.

---

## 8. Open Questions (검증 필요)

1. gRPC gateway (`masc_grpc_service.ml:511` `Sse.subscribe_external`)가 분리된 두 stream을 어떻게 union 할 것인가?
2. `Sse.subscribe_external` 가입자 목록 — 외부 사용자가 heartbeat 의존하는가?
3. presence debounce window: 200ms vs 50ms vs 500ms — 12 keeper 기준 dashboard UX 측정 필요.
4. `/events/presence` 인증 — broadcast 와 동일한 auth scope 충분한지.
5. `Last-Event-Id` 재구독 시 두 channel 간 인덱스 분리 (각 channel 독립 sequence).

---

## 9. 작업 영역 / 변경 없음 항목

본 PR (spec)에서 변경하는 것: `docs/rfc/awareness-channel-split.md` (신규)
변경하지 않는 것: `lib/`, `dashboard/src/`, `dune`, `test/`. 코드 변경 0.

다음 트랙은 PR-1.7a부터 시작.
