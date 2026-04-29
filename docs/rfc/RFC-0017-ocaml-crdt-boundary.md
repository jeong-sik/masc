# RFC 0017 — OCaml↔CRDT Boundary

> Status: **Draft**
> Author: Vincent (jeong-sik)
> Created: 2026-04-29
> Replaces / supersedes: none
> Relates to:
>   - `docs/rfc/awareness-channel-split.md` (RFC PR-1.7 spec, 2026-04-29) — **prerequisite**, §12 참조
>   - `feature/ds-v2-impl-agent-presence` HEAD `97cf00206f` "feat(headless): AgentPresenceManager + Preact adapter" (commit msg가 "RFC 0008"이라 인용하나 실제 RFC 0008은 credential-provider — 본 commit의 RFC 번호는 unassigned). headless-core/agent-presence.ts(310 LOC) + headless-preact/use-agent-presence.ts(55 LOC) 추가 — Track B B-2와 영역 superset.
>   - RFC 0010 CollaborationCursor (draft, location TBD), RFC 0011 InlineSuggestion (draft), RFC 0012 Mid-turn progress probe (draft, `docs/rfc/0012-*` 존재), RFC 0013 Cockpit→Production (draft)
> Source 자료: 외부 분석 보고서(`multiagent-ide-deep-analysis.md`, 2026-04-29) Track A R4 + Track C 3.1 + Track B 종합
> RFC 번호 점유 (2026-04-29 race-check 기준):
>   - main 머지 완료: 0001~0009, 0012, awareness-channel-split (PR-1.7)
>   - open PR 점유: 0014 (#12007 ds-v2 TreeView), 0016 (#12018 ds-v2 Toolbar)
>   - draft 인용 (location TBD): 0010 CollaborationCursor, 0011 InlineSuggestion, 0013 Cockpit→Production
>   - 본 문서가 **0017** 점유. 0010/0011/0013/0015 가능성은 별도 race-check 후 결정 가능.

---

## 1. Problem Statement

masc-mcp는 OCaml 5 + Eio 백엔드에 12-state Keeper FSM SSOT(`lib/keeper/keeper_state_machine.mli:21-37`)와 25개 TLA+ specs(`specs/keeper-state-machine/`)로 *결정론적 authoritative coordination*을 운영한다. 외부 분석 보고서(`multiagent-ide-deep-analysis.md`)와 4개 sub-agent 분석은 이 위에 **CRDT(Yjs/Loro)를 추가하라**고 권고한다 — 이때 두 동시성 모델이 한 도메인에서 만나면 다음 위험이 발생한다:

1. **Dual-write inconsistency**: OCaml CAS(`masc_transition(expected_version)`)와 Y.Map LWW가 동일 데이터를 양방향 쓰면, OCaml에서는 거부된 transition이 CRDT에서는 수용 → server state ↔ client view drift.
2. **TLA+ invariant 침식**: `KeeperCompositeLifecycle.tla`이 검증하는 KSM/KTC/KDP/KMC/KCL joint invariant는 OCaml semantics 전제. Yjs Map이 같은 상태를 표현하면 spec 외부 mutation이 invariant 위반 가능.
3. **Fail-closed → Fail-open 회귀**: OCaml은 unknown enum/missing field에 fail-closed (memory: `feedback_keeper_runtime_fail_closed_for_unknown_permissive_default`). Yjs LWW는 fail-open (마지막 쓴 클라이언트가 이긴다) — 보안 invariant가 약화될 수 있다.
4. **proto 7-RPC 계약 변경 위험**: `proto/masc_coordination.proto:14-39`의 7 RPC는 안정 계약. CRDT projection을 새 RPC로 추가하면 grpc-direct(Experimental) 부하 증가 + 모든 client 재빌드.

따라서 *어떤 데이터가 어느 layer에 살고, 어느 방향으로만 흐르는가*를 명시적으로 정의해야 다음 PR(Q-P1-2 OCaml relay, Q-P1-5 yjs-projection, Q-P2-1 TODO Claim dual-protocol)이 안전하게 진행된다.

---

## 2. Decision

**계층 분리 (Layered Authority Model)**

```
+------------------------------------------+
| L0: Authoritative State (OCaml + Eio)    |  ← single writer
|   - Keeper FSM (12 state)                |     enforced by
|   - TLA+ specs (25)                      |     OCaml exhaustive match
|   - masc_transition CAS                  |
|   - Heartbeat / Turn cycle               |
|   - OAS budget / Role budget             |
+------------------------------------------+
              | broadcast (one-way, server-authored)
              v
+------------------------------------------+
| L1: Projection Layer (Y.Doc)             |  ← read-only on client
|   - Y.Map(/dashboard/keepers/<id>)       |     server is sole source
|   - Y.Map(/dashboard/turn-queue)         |
|   - Y.Array(/dashboard/activity-log)     |
+------------------------------------------+
              ^
              | overlay (transient, client-only)
              |
+------------------------------------------+
| L2: Ephemeral Overlay (Y.Doc Awareness)  |  ← multi-writer, lossy
|   - cursor / selection                   |
|   - "who is looking at X"                |
|   - draft-staging notes (per-client)     |
+------------------------------------------+
```

**핵심 원칙**:

| # | 원칙 | 결과 |
|---|---|---|
| 1 | OCaml = single authoritative writer for L0/L1 | client Y.Map writes는 거부(또는 무시) |
| 2 | L1 read flows **server → client**, never the other way | `lib/observability/yjs_projector.ml` 단방향 encoder |
| 3 | L2(Awareness)만 client → client multi-writer 허용 | UI 협업 cursor 등 transient |
| 4 | L0 transition은 기존 RPC(masc_transition CAS)로만 | proto contract 불변 |
| 5 | TLA+ spec은 L0에만 적용. L1/L2는 검증 대상에서 제외 | spec 재작성 비용 0 |
| 6 | unknown 입력은 fail-closed (no permissive default) | memory 룰 유지 |

---

## 3. Data Layer Mapping

| 데이터 | Layer | 쓰기 권한 | 충돌 해결 | TLA+ 적용 |
|---|---|---|---|---|
| Keeper 12-state | L0 | OCaml only | CAS expected_version | KeeperStateMachine, KeeperCompositeLifecycle |
| Heartbeat tick | L0 → L1 broadcast | OCaml | n/a (서버 결정론) | KeeperHeartbeat |
| Turn queue | L0 → L1 broadcast | OCaml | n/a | KeeperTurnCycle |
| TODO claim (NEW) | L0 (CAS) + L1 (mirror) | OCaml CAS | server-wins | TODOClaimProtocol.tla (신규) |
| OAS budget / Role budget | L0 only | OCaml | server | RoleBudget.tla (신규) |
| Activity log | L0 → L1 append-only | OCaml | n/a | (검증 대상 외) |
| Cursor / selection | L2 only | client multi | LWW (lossy OK) | (검증 대상 외) |
| Cmd-K command palette state | L2 only (per-client) | client | n/a | (검증 대상 외) |
| Code editor content (CodeMirror) | L1 (read-only viewer) initially → L0 if write enabled | server (Phase 1) | server CAS | TBD Phase 2 |

---

## 4. Wire Format (Phase 1)

### 4.1 L0 → L1 broadcast

OCaml은 기존 status WebSocket(port 8937, `dashboard-ws.ts`) 위에 **새 토픽 `yjs:projection:*`** 을 추가한다. message format:

```
{
  "topic": "yjs:projection:keepers",
  "doc_id": "/dashboard/keepers",
  "update_b64": "<base64 Y.Map update binary>"
}
```

또는 별도 endpoint `/yjs/<doc-id>` 신설 (Q-P1-2). 결정은 후속 RFC.

### 4.2 L2 awareness

별도 토픽 `yjs:awareness:*`. 30Hz coalescing은 client-side(Track B B-2). server는 fan-out only:

```
{
  "topic": "yjs:awareness:room-1",
  "client_id": "<u32>",
  "state_b64": "<base64 awareness encoded>"
}
```

### 4.3 클라이언트 쓰기 거부

클라이언트가 L1 doc에 직접 쓰면 server는 broadcast하지 않는다(silently discard) 또는 명시적 reject 메시지. 이는 *fail-closed에 가까운 default*; 잘못된 client implementation을 빨리 드러내려면 explicit reject 권고.

---

## 5. TLA+ 호환성 분석

| spec | L0 적용성 | L1/L2 영향 | 비고 |
|---|---|---|---|
| KeeperStateMachine.tla | ✓ | none (read-only mirror) | 변경 없음 |
| KeeperHeartbeat.tla | ✓ | none | 변경 없음 |
| KeeperCompositeLifecycle.tla | ✓ (joint invariant) | none | 변경 없음 |
| KeeperTurnCycle.tla | ✓ | none | view에서 시각화만 |
| KeeperOASAdvanced.tla | ✓ (server-only) | n/a | runtime 동작 spec |
| **TODOClaimProtocol.tla (신규)** | ✓ at-most-one-winner | L1 mirror가 L0 결과만 반영하는 invariant | Q-P2-1 prerequisite |
| **RoleBudget.tla (신규)** | ✓ token bucket | none | Q-P0-7 prerequisite |
| **CRDT_Projection.tla (신규)** | n/a | L1이 L0의 monotonic projection임을 검증 | 선택적 |

**spec 재작성 비용**: 0 (기존 spec은 변경 없음, 신규 spec 3건은 RFC와 별개로 추가).

---

## 6. Migration Plan (Phase 1 → Phase 2)

| Step | 목표 | 변경 영역 | 검증 |
|---|---|---|---|
| 1 | RFC 0017 머지 (이 문서) | docs only | RFC review |
| 2 | Q-P1-2 OCaml `/yjs/<doc>` opaque dumb relay | `lib/yjs_relay/` 신규 | 두 브라우저 sync 수동 |
| 3 | Q-P1-5 yjs-projection-foundation (server → Y.Map encode) | `lib/observability/yjs_projector.{ml,mli}` | dashboard에서 12 keeper state 동기 표시 |
| 4 | Q-P1-1 CodeMirror 6 readonly viewer | dashboard frontend | keeper sandbox 파일 표시 |
| 5 | Q-P2-1 TODO Claim dual-protocol | `lib/keeper/keeper_todo_claim.*` + `proto/masc_coordination.proto`(stream Subscribe Event variant 추가, 새 RPC 회피) | TODOClaimProtocol.tla 100 case property test |
| 6 | (Phase 2) yrs sidecar 도입 검토 (서버측 CRDT 부하 시) | 별도 RFC | k6 부하 테스트 |
| 7 | (Phase 2) Yjs → Loro 마이그레이션 평가 | 별도 RFC | Loro EphemeralStore 마이크로벤치 |

---

## 7. Alternatives Considered

| 대안 | 평가 | 거부 이유 |
|---|---|---|
| **Full CRDT (server-less)**: OCaml backend 제거, P2P 전용 | 구현 난이도 ↑↑, TLA+ specs 폐기 | 기존 25 spec 자산 손실. 12 keeper 환경에서 ROI 부정 |
| **Bidirectional dual-write**: client/server 양쪽 모두 L0/L1 쓰기 | 자연스러워 보임 | dual-write 일관성은 분산 시스템 hard problem; CAP에서 partition 시 split-brain |
| **Pure server, no CRDT**: 기존 그대로, dashboard도 일반 WS | 가장 단순 | 12+ cursor multi-agent UI/UX 제약. Track B/D의 가치 없음 |
| **CRDT only for L2 (cursor)**, L0/L1은 자체 protocol | 단순 | L1 broadcast가 자체 protocol이면 차후 cross-tab sync 등 추가 비용 |

**선택**: Layered Authority Model (위 §2). 기존 자산 보존 + CRDT의 client UX 이점 + dual-write 회피.

---

## 8. Open Questions

| # | 질문 | 결정 시점 |
|---|---|---|
| Q-1 | `/yjs/<doc>` 별도 endpoint vs 기존 WS multiplex | Q-P1-2 PR 시 |
| Q-2 | OCaml에서 y-protocols 자체 구현 vs Hocuspocus(Node.js) sidecar vs yrs(Rust) | Phase 2 trigger 충족 시 |
| Q-3 | Awareness 30 Hz coalescing이 12 keeper × 60 Hz cursor 폭발 → 720 msg/s. throttle 정책 | Q-P1-4 진행 중 (Track A Open Q2) |
| Q-4 | client 쓰기 silent discard vs explicit reject | Q-P1-2 PR 시 |
| Q-5 | RFC 0010 (CollaborationCursor)와의 정합성 — 별도 RFC인지, 본 RFC 0017의 L2에서 흡수인지 | 0010 author와 sync 필요 |
| Q-6 | RFC 0008 (AgentPresenceManager)이 L1인지 L2인지 분류 | 0008 head ref `feature/ds-v2-impl-agent-presence` 검토 후 |
| Q-7 | proto contract 변경 회피 — stream Subscribe에 새 Event variant만 추가할 수 있는가 | grpc-direct 호환성 검증 필요 |
| Q-8 | L1 doc 크기 상한 + GC 정책 (Track A R2: Yjs 10M tombstone 4GB 스파이크) | Phase 2 |

---

## 9. Risks

1. **다른 RFC와의 정합 비용**: 진행 중 RFC 0008/0010이 본 RFC와 다른 가정에 서 있으면 통합 비용 발생. → 이 draft를 owner들에게 review 요청 후 정합.
2. **L1 broadcast 부하**: 12 keeper × every state change = N msg/s broadcast. throttle/batch 필요. → Q-P1-7 k6 부하 테스트.
3. **client 쓰기 거부의 사용자 경험**: keeper coordination에서 사람이 dashboard에서 "claim"하는 인터랙션은? L0 RPC로 직접 호출 (REST/gRPC) — Y.Map write 아니라.
4. **silent discard vs explicit reject**: silent는 디버깅 어려움, explicit은 메시지 정의 추가 → §4.3 결정 필요.

---

## 10. Acceptance Criteria

이 RFC가 Approved 되려면:
- [ ] `feature/ds-v2-impl-agent-presence` HEAD `97cf00206f` author 리뷰 — Track B B-2 (Awareness store)와 superset 통합 검증. **주의**: 해당 commit msg "RFC 0008"은 잘못된 RFC 인용 (실제 0008은 credential-provider). 본 commit이 가리키는 실제 spec 번호 결정 필요.
- [ ] RFC 0010 CollaborationCursor draft author 리뷰 (location 확인 필요 — `docs/rfc/0010-*` 부재, ds-v2-impl-agent-presence 브랜치 내부 또는 별도 위치)
- [ ] **awareness-channel-split.md (PR-1.7 spec)와 §12 정합성 확인** — 두 RFC sequential 머지 순서 합의
- [ ] §3 데이터 layer mapping 표가 ds-v2 token 작업과 충돌 없음 확인
- [ ] §6 migration step 2-3이 Q-P1-2/Q-P1-5 PR로 분해 가능한 수준 detail
- [ ] proto contract 변경 회피 (Q-7) 확인 — grpc-direct 팀(또는 maintainer) consult
- [ ] Phase 2 trigger 정량화 (Q-2): 어떤 metric이 sidecar/yrs 도입을 정당화하는가
- [ ] §12 layer naming 충돌(broadcast L1/L2 vs authority L0/L1/L2) 별칭 합의

---

## 11. Implementation Surface (delta from current)

```
lib/observability/yjs_projector.{ml,mli}       NEW (~200 LOC)
lib/yjs_relay/{yjs_relay,dune}.{ml,mli}        NEW (~180 LOC)
specs/keeper-state-machine/TODOClaimProtocol.tla  NEW (~80 LOC)
specs/keeper-state-machine/RoleBudget.tla      NEW (~60 LOC)
proto/masc_coordination.proto                  변경: Subscribe stream Event variant 추가 (RPC 시그니처 불변)
dashboard/src/yjs/{provider,awareness,index}.ts  NEW (~120 LOC, Q-P0-2)
dashboard/src/yjs/{tab-leader,shared-ws}.ts    NEW (~140 LOC, Q-P1-3)
dashboard/src/components/code-viewer/{cm-yjs,CodeViewer}.ts/tsx  NEW (~150 LOC, Q-P1-1)
docs/rfc/0014-ocaml-crdt-boundary.md           이 문서 (final 머지 위치)
```

**총 신규 코드 ~1,030 LOC + 1 proto 변경 (additive)** — 6 PR로 분해 (§6).

---

## 12. awareness-channel-split.md 와의 정합성

masc-mcp 저장소에 이미 `docs/rfc/awareness-channel-split.md` ("RFC PR-1.7 — Awareness Channel Split (Spec)", Status: Spec, 2026-04-29) 가 존재한다. 본 RFC 0017가 *그 위에 얹는 형태*로 통합되어야 한다.

### 12.1 두 RFC의 abstraction layer 비교

| 측면 | awareness-channel-split (PR-1.7) | RFC 0017 (이 문서) |
|---|---|---|
| 목적 | 기존 단일 broadcast 채널 → 다중 채널 분리 | 새 CRDT layer (Y.Doc projection + awareness) 추가 |
| Layer 정의 | L1 = `lib/coord/coord_broadcast.ml:58-59` pubsub key (`broadcast:<project>:default`) / L2 = `lib/sse.ml` SSE event_type (`masc:broadcast`, `keeper_heartbeat` 등) | "Authority" = OCaml authoritative state (L0) / "Projection" = Y.Doc read-only mirror (L1) / "Ephemeral" = Y.Doc Awareness (L2) |
| 코드 변경 | Spec only (PR-1.7 본 문서). 후속 PR-1.7a/b/c가 구현 | Spec only (이 문서). 후속 Q-P1-2/Q-P1-5/Q-P2-1이 구현 |
| 충돌 | 없음 — 별 abstraction | 없음 — 별 abstraction |

### 12.2 layer naming 충돌 + 별칭

같은 RFC pack(`docs/rfc/`) 안에서 "L1/L2" 표기가 두 RFC에 모두 등장 → 혼동 위험. 본 RFC 0017는 §2/§3 표기를 다음 우선순위로 사용:

- 1순위 (canonical): **Authority** / **Projection** / **Ephemeral** layer
- 2순위 (보조): **L0** / **L1** / **L2**

이때 awareness-channel-split의 L1/L2는 *broadcast layer naming*으로 그대로 보존하며, 인용 시 명시 prefix("broadcast L1", "broadcast L2") 사용.

### 12.3 prerequisite 관계

awareness-channel-split는 RFC 0017의 *prerequisite*. 근거:
- 단일 broadcast 채널(`broadcast:<project>:default`)에 yjs:projection:keepers, yjs:awareness:room-1, keeper_heartbeat가 모두 흐르면 *throttle/QoS 분리 불가*. 12+ keeper × 30 Hz coalescing이 다른 메시지 fan-out과 경쟁.
- awareness-channel-split이 분리한 다중 채널 위에 yjs:projection:*, yjs:awareness:* 토픽을 별도 채널로 매핑 가능.

### 12.4 통합 머지 순서 (sequential)

| Step | RFC | 상태 |
|---|---|---|
| 1 | awareness-channel-split (PR-1.7 spec) | already in main (`docs/rfc/awareness-channel-split.md`) |
| 2 | PR-1.7a/b/c implementation (broadcast 채널 분리 코드) | 별도 트랙, 우리 PR queue 외부 |
| 3 | RFC 0017 (이 문서) spec 머지 | 본 cycle 진행 |
| 4 | Q-P1-2 OCaml `/yjs/<doc>` opaque dumb relay | RFC 0017 머지 후 + step 2 완료 후 |
| 5 | Q-P1-5 yjs-projection-foundation | step 4 후 |

대안 검토:
- (a) RFC 0017를 awareness-channel-split의 후속 phase로 통합 → 한 RFC가 너무 커짐, 거부
- (b) 두 RFC 병렬 spec 머지 + 코드 phase 통합 → 채택
- (c) RFC 0017에서 awareness-channel-split와 무관하게 단일 채널 사용 가정 → throttle 비용 ↑, 거부

### 12.5 awareness-channel-split의 "L2 SSE" vs RFC 0017 "Ephemeral Awareness"

awareness-channel-split의 broadcast L2(SSE)는 *서버 → 클라이언트 push 메커니즘*. RFC 0017의 Ephemeral(L2)는 *Y.Doc awareness CRDT 데이터 구조*. 두 개념은 *직교*: yjs awareness 메시지가 awareness-channel-split의 분리된 SSE 채널 한 개를 통해 *흘러갈* 수 있다. 즉:

```
awareness-channel-split L2 SSE channel "yjs:awareness"
  └── carries Yjs awareness binary frames (RFC 0017 Ephemeral layer state)
```

또는 별도 WebSocket endpoint(`/yjs/awareness/<room>`)를 신설할 수도. Q-1(§8)에서 결정.

---

*작성: 2026-04-29*
