# Appendix C: Implementation Status Report

> Generated: 2026-03-23 | Baseline: v2.138.0
> Method: 코드 존재 + 테스트 존재 + 텔레메트리/상태파일 실사용 증거로 판정

---

## Status Legend

| 등급 | 의미 | 기준 |
|------|------|------|
| IMPL | 완전 구현 | 코드 + 테스트 + 실사용 증거 |
| CODE | 코드만 존재 | 빌드되지만 테스트 없거나 실사용 0 |
| STUB | 스텁/미완성 | TODO/placeholder |
| MISS | 미구현 | 스펙에 기술되었으나 코드 없음 |

---

## 1. Summary

| 서브시스템 | 스펙 | IMPL | CODE | STUB | MISS | 비율 | 핵심 판정 |
|-----------|------|------|------|------|------|------|---------|
| Room Coordination | 03 | 24 | 0 | 0 | 0 | 100% | 전 기능 운용 |
| Chain Engine | 04 | - | - | - | - | **Frozen** | 0 production calls, OAS superseded |
| Keeper Agent | 05 | 24 | 1 | 0 | 0 | 96% | tech debt(meta 100필드) 외 완전 |
| Command Plane | 06 | 38 | 2 | 0 | 0 | 95% | Intent 도구 사용 빈도 낮음 |
| Team Session | 07 | 30 | 3 | 0 | 0 | 90% | Auto 모드는 OAS 위임, lossy projection |
| Council/Governance | 08 | 28 | 0 | 0 | 0 | 100% | 거버넌스 24+ 호출 |
| Server/Transport | 09 | 18 | 5 | 0 | 0 | 78% | HTTP/1.1 canonical + gRPC/WS/WebRTC local harness verified |
| Dashboard | 10 | 15 | 1 | 0 | 0 | 94% | MDAL surface만 미약 |
| Board | 11 | 16 | 1 | 0 | 0 | 94% | Board Listener polling만 CODE |
| Memory Systems | 12 | 44 | 0 | 0 | 0 | 100% | 4 시스템 전부 운용 |
| OAS Integration | 13 | 42 | 0 | 0 | 0 | 100% | 단방향 경계 완벽 준수 |
| Configuration | 14 | 68 | 0 | 0 | 0 | 100% | 80+ env var, 22 카테고리 |
| Testing | 15 | 92 | 6 | 0 | 0 | 94% | env-gated 6건만 CODE |
| **TOTAL** | | **436** | **22** | **0** | **0** | **95.2%** | |

**MISS: 0 | STUB: 0 | IMPL 비율: 95.2%**

---

## 2. CODE (빌드됨, 미사용) 항목 총정리

"코드는 있지만 쓰이지 않는 것"이 진짜 관심 대상이다.

| 항목 | 서브시스템 | LOC | 판정 근거 |
|------|----------|-----|---------|
| **Chain Engine 전체** | 04 | 17K | chain_run_start 0건, orchestration_kind=chain_dsl 0건 |
| **HTTP/2 (h2c)** | 09 | 740 | opt-in 경로, canonical 기본값은 아님 |
| **SSE rate limit guard** | 09 | ~50 | 모든 threshold 기본값 0 (비활성) |
| **Board Listener (polling)** | 11 | ~100 | pg_notify 수신 코드, SSE relay 미확인 |
| **Intent 도구 4종** | 06 | ~200 | 정의됨, 벤치마크에서 미사용 |
| **Keeper OAS Memory.t 일부** | 05 | ~100 | Long_term 백엔드 연결 부분적 |
| **Team Session lossy projection** | 07 | ~50 | 47→12 필드 축소, 의도적 gap |
| **env-gated 테스트 6종** | 15 | ~300 | PG/network/viewer 테스트, CI에서 실행 안 됨 |
| **MDAL dashboard surface** | 10 | ~50 | 최소한의 노출 |

**합계: ~20K LOC의 CODE** (Chain 17K가 대부분)

---

## 3. Per-Subsystem Detail

### 03-Room Coordination (100% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| State Machines | Task FSM (Pending→Claimed→InProgress→Done) | IMPL | room_task.ml + telemetry |
| Heartbeat | Smart heartbeat (Emit/Skip_busy/Skip_idle) | IMPL | heartbeat_smart.ml + telemetry 1K+ |
| Zombie Detection | 300s general, 3600s keeper threshold | IMPL | resilience.ml + GC 증거 |
| GC Pipeline | 5-phase (detect→transition→release→delete→update) | IMPL | room_gc.ml 491 LOC |
| WALPH | Retired — loop, state, tools all removed | REMOVED | — |
| Mention Routing | @mention parsing, stateless/stateful/broadcast | IMPL | mention.ml |
| Worktree | Git worktree create/remove per agent | IMPL | room_worktree.ml |
| Multi-Room | Room registry, slugification | IMPL | room_multi.ml + room_rooms.ml |
| Portal | A2A bidirectional task exchange | IMPL | room_portal.ml |
| Checkpoint | Snapshot capture/restore | IMPL | room_checkpoint.ml |
| Tempo | Pacing control (Normal/Slow/Fast/Paused) | IMPL | room_tempo.ml |
| MCP Tools | 8 tool suites, ~45 tools | IMPL | telemetry 145+ calls |

### 05-Keeper Agent (96% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| Unified Turn | Observe→BuildPrompt→AgentRun→ToolExec→Checkpoint | IMPL | keeper_unified_turn.ml, 31 calls |
| Supervisor | Init→Alive→Zombie→Dead with backoff | IMPL | keeper_supervisor.ml |
| Deliberation | 9 triage triggers, budget check, execute | IMPL | keeper_deliberation.ml 589 LOC |
| Memory Bank | JSONL, soul_profile priority, compaction | IMPL | keeper_memory_bank.ml |
| Verifier | cost_guard + risk_guard + Verifier_oas | IMPL | keeper_verifier.ml 589 LOC |
| Eval Harness | Scenario→graders→score | IMPL | eval_harness.ml |
| Anti-Fake | Test quality scoring | IMPL | anti_fake.ml |
| Hooks | Autonomy level gating (l3/l4/l5) | IMPL | keeper_hooks_oas.ml |
| Proactive | Quality gate + similarity + 3-retry fallback | IMPL | keeper_prompt.ml |
| Self-Model Drift | will/needs/desires gradual mutation | IMPL | keeper_prompt.ml |
| TOML Config | config/keepers/*.toml | IMPL | keeper_toml_loader.ml |
| OAS Memory.t Bridge | 5-tier mapping (부분적) | CODE | memory_oas_bridge.ml (Long_term 불완전) |

### 06-Command Plane (95% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| Unit Hierarchy | Company→Platoon→Squad→Agent_unit | IMPL | cp_types.ml + units.json |
| Operation Lifecycle | Planned→Active→Paused→Completed | IMPL | cp_lifecycle.ml + 100+ operations |
| Search Fabric V1 | 10-dimension Bayesian scoring | IMPL | cp_search_fabric.ml 622 LOC |
| Snapshot System | 6-section mtime cache | IMPL | cp_snapshot_core.ml 758 LOC |
| Cleanup Pipeline | 5-stage cascading GC | IMPL | cp_cleanup.ml 266 LOC |
| Orchestra | Node/edge/signal graph synthesis | IMPL | command_plane_orchestra.ml 798 LOC |
| Policy Decisions | Pending→Approved/Denied/Expired | IMPL | cp_lifecycle_policy.ml 838 LOC |
| Event Trace | Append-only events.jsonl | IMPL | 58KB, 1000+ entries |
| Intent Tools | create/status/update/forecast | CODE | 정의됨, 벤치마크 미사용 |

### 07-Team Session (90% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| 47-field Session Record | Identity+Config+Runtime+Timestamps+Proof | IMPL | team_session_types.ml 697 LOC |
| 3 Orchestration Modes | Manual/Assist/Auto | IMPL | Engine handles all 3 |
| OAS Bridge | session→swarm_config, worker→agent_entry | IMPL | team_session_oas_bridge.ml 414 LOC |
| Swarm Runner | Load→convert→callbacks→run→apply | IMPL | team_session_swarm_runner.ml |
| Report/Proof | Markdown/JSON, Standard/Strong | IMPL | team_session_report_proof.ml 419 LOC |
| Tool Surface | 9 handler modules, 4.5K LOC | IMPL | God file 분할 완료 |
| Lossy Projection | 47→12 fields to OAS Collaboration.t | CODE | 의도적 gap |

### 08-Council/Governance (100% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| Debate Module | Structured debates, SSJ turn-taking | IMPL | council/debate.ml |
| Consensus | In-memory + file write-through | IMPL | council/consensus.ml |
| Router (MoE) | Agent selection, 90/10 cost target | IMPL | council/router.ml |
| Governance V2 | Petition→Case→Ruling legal metaphor | IMPL | governance_v2.ml, 24+ calls |
| Governance Pipeline | 4 risk levels, pre-hook | IMPL | governance_pipeline.ml |
| Operator Control | Snapshot, digest, action, judgment | IMPL | operator_control.ml 26K |
| Loop Guard | 3-layer defense | IMPL | loop_guard.ml |

### 09-Server/Transport (65% IMPL)

| Transport | Status | Evidence |
|-----------|--------|----------|
| HTTP/1.1 (httpun-eio) | **IMPL** | Canonical, 매일 사용 |
| stdio (Claude Code) | **IMPL** | Claude Code MCP 통합 |
| MCP JSON-RPC | **IMPL** | 전체 프로토콜 준수 |
| SSE Event Streaming | **IMPL** | 매일 브로드캐스트 |
| Auth/RBAC | **IMPL** | Bearer token + 3 role |
| HTTP/2 (h2c) | **CODE** | 740 LOC, opt-in only, canonical 아님 |
| WebSocket | **IMPL** | standalone `/ws` discovery + WS frame harness 통과 |
| gRPC | **IMPL** | Health/Reflection/Subscribe bridge harness 통과 |
| WebRTC | **IMPL** | local signaling + peer establishment harness 통과, live interop은 `verify_webrtc_live_env.sh` / workflow dispatch로 env-gated |
| SSE Rate Limit | **CODE** | 기본값 0 (비활성) |

### 10-Dashboard (94% IMPL)

핵심 기능 전부 IMPL: Cache SWR(Eio.Mutex), 23 HTTP endpoints, Governance/Execution/Mission/Proof surfaces, Keeper metrics, Preact SPA.
MDAL surface만 CODE (최소한의 노출).

### 11-Board (94% IMPL)

핵심 기능 전부 IMPL: Parse-Don't-Validate ID, JSONL+PG dual backend, 5 sort algorithms, Thompson Sampling 9 call sites, pg_notify 4 event types, Karma/Flair.
Board Listener polling만 CODE.

### 12-Memory Systems (100% IMPL)

4개 시스템 전부 운용: Keeper Memory Bank(JSONL+compaction), Institution(episodic/semantic/procedural), Procedural Memory(crystallization), Context Budget(4 phases).
OAS Memory Bridge 5-tier 매핑 완전. Hebbian Learning(synapse model) 운용.

### 13-OAS Integration (100% IMPL)

단방향 경계(MASC→OAS) 14개 모듈에서 완벽 준수.
Oas_worker, Cascade config, Verifier, Event bus(13 types), Context compaction(4 strategies) 전부 운용.

### 14-Configuration (100% IMPL)

7-layer 설정 계층, 80+ env var, 22 카테고리, 8 mode presets, 3-layer filter, cascade.json hot-reload 전부 운용.

### 15-Testing (94% IMPL)

313 hermetic tests + 6 bench + 100 coverage supplements.
3-tier verification(hermetic/env-gated/manual), eval_gate(Swiss Cheese 4-layer), eval_harness, anti_fake, trajectory 전부 운용.
env-gated 6종(PG/network/viewer)만 CODE.

---

## 4. Key Findings

### 건강한 서브시스템 (100% IMPL)
- Room, Memory, OAS, Config, Council — 코드+테스트+실사용 모두 확인

### CODE 집중 영역 (빌드됨, 미사용)
1. **Chain Engine** (17K LOC) → **Frozen** 판정, OAS superseded
2. **대체 트랜스포트 4종** (2.2K LOC) → HTTP/1.1이 canonical, H2만 opt-in, gRPC/WS/WebRTC는 local harness 기준 IMPL
3. **Intent 도구** → 정의됨, 벤치마크 미사용

### 아키텍처 의사결정 필요
1. Chain Engine 장기 방향 (현재 Frozen)
2. live ICE/TURN/browser interop proof를 어떤 env-gated lane으로 운영할지
3. Team Session lossy projection(47→12) 해소 방법

---

## 5. Recommendations

| 우선순위 | 항목 | 근거 |
|---------|------|------|
| 1 | Server: SSE rate limit 활성화 | 현재 모든 threshold 0 (보안 gap) |
| 2 | Keeper: OAS Memory.t Long_term 백엔드 완성 | IMPL 96%→100% |
| 3 | Team Session: lossy projection 해소 | 47→12 필드 축소가 OAS 측 정보 손실 유발 |
| 4 | Chain Engine: Adapter+Mermaid 유틸리티 추출 후 본체 archive | 17K LOC 유지비 제거 |
| 5 | Transport: live ICE/TURN/browser interop 증빙 lane 추가 | local smoke는 확보됐고 internet-grade 증빙만 env-gated로 남음 |
