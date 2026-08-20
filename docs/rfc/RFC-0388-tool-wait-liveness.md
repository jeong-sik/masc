---
rfc: "0388"
title: "awaiting_tool 대기의 liveness — 취소 도달과 시간 기반 만료"
status: Draft
created: 2026-08-21
updated: 2026-08-21
author: claude
supersedes: []
superseded_by: null
related: ["0361"]
implementation_prs: []
---

# RFC-0388: awaiting_tool 대기의 liveness

## 0. Summary

턴이 `awaiting_tool` 로 들어가면 **빠져나올 수단이 하나도 없다.** 도구 결과가 오지 않는 경우
시간이 지나도, 운영자가 개입해도 그 상태에서 나오지 못한다. 이 RFC 는 그 두 구멍을 닫는 최소
설계와, 그에 필요한 결정 항목을 정리한다.

관측된 결과는 keeper 하나가 영구히 멈추고, 그 keeper 의 이벤트 큐가 상한 없이 자라는 것이다
(masc#29071: 51h/52건 → 84h/86건).

## 1. 관측 (2026-08-21)

`taskmaster` 가 재시작 후 첫 턴에서 `awaiting_tool` 에 진입한 뒤:

```
00:35:22  streaming -> awaiting_tool   (StreamYieldsTool)
01:40:07  전이 0건, 63분+ 경과
          이벤트 큐 pending 86 -> 87 (유입은 계속, 소비 0)
```

같은 시간대 다른 keeper 는 정상 완주한다 (`turn completed` 다수, GLM-5-Turbo / Codex).
`awaiting_tool` 진입 횟수는 analyst 4회(전부 통과), taskmaster 1회(미복귀).

## 2. 문제 분해 — 구멍이 둘이다

### 2.1 시간 기반 만료가 없다

```
lib/turn_fsm/turn_fsm.ml:290   Streaming            -> Awaiting_tool_result
lib/turn_fsm/turn_fsm.ml:292   Awaiting_tool_result -> Streaming      <- 유일한 탈출
```

`Streaming` 복귀는 pending-tool count 감소로만 일어난다
(`keeper_unified_turn_event_bus.ml:85`). 시간 축 전이가 없다.

명세도 같은 모양이다. `specs/keeper-turn-fsm/KeeperTurnFSM.tla` 의 `Fairness`:

```tla
/\ WF_vars(ProviderResponded \/ ProviderTimeout)   \* provider: 탈출구 명시
/\ SF_vars(StreamComplete)
/\ WF_vars(ToolReturned)                           \* tool: 반환을 공리로 가정
```

`WF_vars(ToolReturned)` 는 "도구는 결국 반환한다" 를 **가정**한다. 그래서 TLC 는 liveness 를
통과한다 — 모델 안에서 이 hang 은 표현되지 않는다. provider 쪽에는 `ProviderTimeout` 이라는
대칭이 이미 있다.

**그리고 이 상황을 위한 이름은 이미 있다.** `stale_turn_timeout` 이 variant, 문자열 계약,
blocker 분류, trust snapshot 매핑까지 갖춰져 있는데 **생산자가 없다**:

```
rg -n "Stale_turn_timeout" lib/ bin/ --glob '*.ml'
  keeper_meta_contract.ml:105/146/167        정의 · 변환
  keeper_status_bridge_blocker.ml:108/132    분류
  keeper_runtime_trust_snapshot.ml:86        매핑
  (설정하는 코드 없음)
```

`Keeper_registry` 에 코호트 없음, `keeper_heartbeat_loop` 에 턴 나이 비교 없음, env
`MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC` 는 코드에서 읽히지 않음(죽은 설정).

### 2.2 취소가 도달하지 못한다 (그리고 성공으로 보고된다)

```
POST /api/v1/keepers/turn/interrupt  {"name":"taskmaster"}
  -> {"cancelled":true,"turn_id":27647}
01:38:15  [Keeper] keeper_turn_interrupt: keeper=taskmaster turn_id=27647
```

신호 발신과 로그까지는 설계대로다. 그러나 이후 FSM 전이 0건, pending 미감소.
`Keeper_registry.interrupt_current_turn` 의 `` `Cancelled `` 는 **신호를 보냈다**는 뜻인데
API 응답의 `cancelled: true` 는 **턴이 종료됐다**로 읽힌다.

08-20 의 `execution-receipts/2026-08/20.jsonl` 마지막 항목이 `outcome=receipt_cancelled`
인데 그때도 pending 이 빠지지 않은 것으로 보아, 같은 일이 이미 있었다.

### 2.3 둘의 관계

| 수단 | 현재 |
|---|---|
| 도구 결과 도착 | 오지 않는 경우가 있다 (본 사례) |
| 시간 기반 만료 | **없음** (2.1) |
| 운영자 interrupt | **도달하지 못하고 성공으로 보고** (2.2) |
| 서버 재시작 | 재기동 후 같은 지점에서 재현 |

**2.2 가 선행이다.** 타임아웃을 넣어도 만료 처리가 취소 경로를 타면 같은 자리에서 막힌다.

## 3. 설계 대안

### A. 큐 쪽에서 끊는다 (기각)

턴 완료와 무관하게 pending 을 ack 하거나 주기적으로 비운다.

- 증상(백로그 숫자)은 사라진다
- **hang 은 그대로**고, 그 keeper 는 계속 죽어 있다
- 이벤트가 처리되지 않은 채 사라지므로 durable truth 손상

워크어라운드 거부 기준의 "symptom 억제" 에 해당한다. 채택하지 않는다.

### B. 도구 실행에 타임아웃을 두고 만료 시 턴을 종료한다 (권고)

`ProviderResponded \/ ProviderTimeout` 과 대칭으로 `ToolReturned \/ ToolTimeout` 을 둔다.
만료 시 이미 존재하는 `stale_turn_timeout` blocker 를 설정하고 턴을 종료 상태로 보낸다.

- **새 상태를 만들지 않는다.** 죽은 표면을 살리는 쪽이라 MASC 구현 경계와 충돌하지 않는다
- 턴이 종료되므로 `terminalize_pending_turn_completed_result` 에 도달해 pending 이 빠진다
- 정체가 "무한" 에서 "느림 + 실패 기록" 으로 바뀐다

### C. 취소 경로를 취소 가능하게 만든다 (B 의 선행 조건)

만료든 운영자 개입이든 결국 실행 중인 fiber 를 멈춰야 한다. 취소가 도달하지 못하는 구간이
있으면 B 도 무력하다. 이 저장소에는 `Eio.Mutex.use_rw ~protect:true` 가 취소를 차단하는
함정 이력이 있어, 도구 실행 경로에 취소 불가 구간이 있는지 확인이 필요하다.

동시에 **응답이 사실을 말하게** 한다: 신호 발신과 턴 종료를 구분해 보고한다.

## 4. 권고

**C → B 순서로 진행한다.**

1. 도구 실행 경로의 취소 도달 가능성 확인 및 수정 (masc#29229)
2. `interrupt` 응답이 발신과 종료를 구분하도록 정정
3. `ToolTimeout` 배선 + `stale_turn_timeout` 설정 (masc#29230)
4. `KeeperTurnFSM.tla` 에 `ToolTimeout` 액션 추가, buggy 모델로 검증
   (clean spec 은 liveness 통과, `NextBuggy` 는 위반해야 유효)

## 5. 결정이 필요한 항목

이 RFC 가 정하지 않고 남기는 것들이다.

| # | 항목 | 제약 |
|---|---|---|
| D1 | `ToolTimeout` 값 | **하한은 45분** — masc#29052 에 45분 정상 장기 턴 사례가 있다. 짧게 잡으면 정상 턴을 죽인다. 관측된 hang 은 63분+ 이므로 그 사이 또는 그 이상 |
| D2 | 만료 기록 형식 | `outcome=receipt_cancelled` 선례에 맞출지, 별도 `receipt_timed_out` 을 둘지 |
| D3 | `interrupt` 응답 스키마 | `cancelled` 의미를 바꿀지(계약 변경), 필드를 추가할지(하위 호환). 대시보드 소비자 확인 필요 |
| D4 | 만료된 도구 호출의 처리 | 결과를 버릴지, 늦게 도착하면 무시할지 |

D1 은 이 RFC 의 핵심이다. **값을 정하지 않으면 구현이 위험해진다** — 정상 45분 턴을 죽이는
것이 현재 증상보다 나쁠 수 있다.

## 6. 검증

- **TLA+**: `ToolTimeout` 을 추가한 clean spec 이 liveness 를 통과하고, 그것을 제거한
  `NextBuggy` 가 위반해야 한다. 양쪽이 다 통과하면 invariant 가 약한 것이다
- **런타임**: 도구가 응답하지 않는 상황을 만들고 D1 값 이후 턴이 종료 상태로 가는지,
  그리고 해당 keeper 의 이벤트 큐 pending 이 감소하는지
- **회귀**: 45분급 정상 장기 턴이 만료되지 않는지 (masc#29052 사례 재현)

## 7. 범위 밖

- 도구 자체가 왜 응답하지 않는지. 관측된 표본은 `antigravity_subscription.gemini-3-6-flash-high`
  하나뿐이고, 완주하는 쪽은 GLM-5-Turbo / Codex 다. 런타임 차이가 유력하지만 표본 1개로
  단정하지 않는다. 이 RFC 는 **어떤 런타임이든 응답하지 않을 수 있다**는 전제에서 liveness 를
  보장하는 것이 목적이다
- 이벤트 큐의 배달 정책. masc#29071 의 원인은 pause 였고 별개 사안이다

## 8. 관련

- masc#29071 — 큐 정체 조사 (원인: pause, 확정)
- masc#29229 — interrupt 가 신호 발신을 취소 성공으로 보고
- masc#29230 — `awaiting_tool` 탈출구 부재, `stale_turn_timeout` 미배선
- masc#29052 — 45분 정상 장기 턴 사례 (D1 하한 근거)
