---
rfc: "0076"
title: "Tool Readiness Notification Channel — Typed Event Ledger Surface"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0020", "0029", "0033", "0048", "0049", "0073", "0074"]
implementation_prs: []
---

# Tool Readiness Notification Channel — Typed Event Ledger Surface

## 1. Context

Dashboard 우상단 알림 영역 (`4 events / 60s` 표시, MASC COCKPIT 헤더) 은 *fleet-wide* 신호만 surface 한다. 특정 keeper 의 *도구 가용성 변화* (sandbox 부착/탈착, credential 만료, config drift) 는 silent. sangsu 의 `keeper_pr_create` 가 turn 도중 GitHub token 만료로 blocked 전환되어도 사용자는 turn 실패 텔레메트리에서야 인지한다.

RFC-0073 이 *현재 상태* 의 snapshot 을 노출한다면, 이 RFC 는 *상태 전이* 를 stream 한다.

## 2. Problem

- readiness 상태 변화가 ledger 에 *typed event* 로 기록되지 않는다.
- dashboard 알림 채널이 keeper-specific 이벤트를 필터링/표시할 surface 가 없다.
- 같은 readiness change 의 반복 발화 (예: 매 turn 마다 같은 missing credential) 가 noise 로 알림 영역을 침범할 위험.

이전 사고 (MEMORY `feedback_keeper_hallucinated_audit_cascade`) 의 *fact suppression* 회피 — 우리는 *display* 만 dedup, *fact* 는 모두 보존.

## 3. Proposal — `Tool_readiness_changed` Event Variant + WS Push

### 3.1 Event Variant

```ocaml
(* lib/events/keeper_event.ml — 기존 type 에 추가 *)
type event = ...
  | Tool_readiness_changed of {
      keeper: string;
      tool: Tool_name.t;
      from_state: Tool_capability.readiness_state;  (* RFC-0073 *)
      to_state: Tool_capability.readiness_state;
      at: Eio.Time.Instant.t;
      occurrence_count: int;  (* 같은 (keeper, tool, to_state) 5분 윈도우 내 N번째 *)
    }
  | ...
```

상태 비교 함수 `Tool_capability.readiness_state_equal` 로 `from_state ≠ to_state` 인 경우만 emit.

### 3.2 Emission 지점

- RFC-0073 의 probe 가 매 turn 시작 시점에 호출 — 직전 snapshot 과 diff 해서 change 만 emit.
- RFC-0074 의 `attach` 성공/실패 — boot 시점에 emit.
- credential 만료 이벤트 (RFC-0019 의 future work) — 만료 검출 시 emit.

### 3.3 WebSocket 채널

기존 `/api/v1/events/stream` (server_dashboard_ws_*.ml) 에 `keeper-readiness` topic 신설. payload schema:

```json
{
  "topic": "keeper-readiness",
  "event": {
    "keeper": "sangsu",
    "tool": "keeper_pr_create",
    "from_state": "Ready",
    "to_state": {
      "kind": "Blocked",
      "reason_kind": "Credential_missing",
      "reason_detail": "Github_token expired"
    },
    "at": "2026-05-14T03:15:42Z",
    "occurrence_count": 1
  }
}
```

### 3.4 Dashboard Component

`dashboard/src/components/notification-stream/` 에 `ToolReadinessAlert` 컴포넌트 추가. 메시지 포맷:
- `Ready → Blocked`: "sangsu: keeper_pr_create blocked (missing Github_token)" — warning tier
- `Blocked → Ready`: "sangsu: keeper_bash ready (sandbox attached)" — info tier
- `occurrence_count > 1`: 메시지 우측에 `(×N within 5m)` 첨부, 알림 *개수* 는 1 만 증가

### 3.5 Display Dedup vs Fact Suppression

`occurrence_count` 가 1 초과인 event 도 ledger 에는 *모두 append*. dashboard 만 5분 윈도우 내 같은 (keeper, tool, to_state) 를 1 줄로 합쳐 보여준다. 이는 *display 최적화* 이며 fact 손실 아님.

## 4. Code Changes

| 파일 | 변경 종류 | 추정 LOC |
|---|---|---|
| `lib/events/keeper_event.ml` | 신규 event variant 1개 | ~25 |
| `lib/keeper/keeper_run_tools.ml` | probe 결과 diff + emit | ~40 |
| `lib/server/server_dashboard_ws_keeper_readiness.ml` | 신규 topic handler | ~80 |
| `dashboard/src/components/notification-stream/ToolReadinessAlert.tsx` | 신규 | ~120 |
| `dashboard/src/api/ws/topics.ts` | topic 1 등록 | ~10 |
| `test/test_keeper_readiness_event.ml` | diff/emit 단위 | ~70 |

## 5. Phases

| Phase | 범위 | 머지 조건 |
|---|---|---|
| 0 | event variant + diff 함수 — emission 없이 컴파일 가드만 | dune build |
| 1 | `Keeper_run_tools` 의 probe diff + emit 통합 | 단위 테스트 통과 |
| 2 | WS topic handler + schema 문서화 | snapshot test |
| 3 | dashboard FE 컴포넌트 + 5분 dedup 윈도우 | local sangsu 시연 |

## 6. Verification

- (a) `dune build` 통과 — keeper_event 새 variant 가 ledger consumer 의 exhaustive match 강제.
- (b) `dune exec test/test_keeper_readiness_event.exe` — diff 함수가 동일 state 에 emit 안 함 / 다른 state 에 emit 함.
- (c) Local sangsu 환경에서 sandbox factory 부착/탈착을 운영자 명령으로 토글 → dashboard 알림 영역에 transition 표시.
- (d) 같은 transition 5분 내 5회 발생 시 ledger 에 5건, dashboard 에 1건 (×5 within 5m) 표시.

## 7. Workaround Rejection Self-Check

- ❌ string `reason: string` field — typed `readiness_reason` variant 사용 (RFC-0073 의 typed 강제 유지)
- ❌ ledger WARN dedup 1h — display 만 5분 dedup, fact ledger 는 모두 보존
- ❌ "fallback to free-text" reason — variant 가 exhaustive
- ❌ counter-as-fix — `occurrence_count` 는 *displayable summary* 이지 fact substitute 아님
- ✅ structural: 결정 결과가 typed event 로 ledger 의 1급 객체

## 8. Related RFCs

- RFC-0020 Keeper heartbeat — Event Layer / Policy Layer separation — 같은 event ledger surface
- RFC-0029 Dashboard Fiber-Batched Aggregation — WS 채널 capacity
- RFC-0033 Worktree Status SSE Channel — 같은 streaming 전례
- RFC-0048 Dashboard Information Architecture Phase 2 — notification 영역 owner
- RFC-0049 Dashboard Surface Telemetry Foundation — telemetry channel 의 일반화
- RFC-0073 Tool Readiness Probe — readiness_state 의 source of truth
- RFC-0074 Sandbox & Credential Auto-provision — `attach` 성공/실패 emission 의 origin
