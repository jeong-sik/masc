---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/
  - dune-project
  - lib/sdk_version.ml
---

# Appendix C: Implementation Status Report

> Generated: 2026-03-23 | Updated: 2026-04-08 (sweep) | Baseline: v2.138.0
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
| Chain Engine | 04 | - | - | - | - | **REMOVED** | 소스 삭제됨, OAS superseded |
| Keeper Agent | 05 | 25 | 0 | 0 | 0 | 100% | Memory.t Long_term JSONL-only 완료 (v2.140.0) |
| Command Plane | 06 | 40 | 0 | 0 | 0 | 100% | Intent 도구 4종 MCP 등록 완료 |
| Team Session | 07 | 31 | 2 | 0 | 0 | 94% | Auto 모드는 OAS 위임, projection 해소 |
| Governance | 08 | 28 | 0 | 0 | 0 | 100% | 거버넌스 pipeline + dashboard surface 유지 |
| Server/Transport | 09 | 19 | 4 | 0 | 0 | 83% | SSE rate limit 활성화, HTTP/2 h2c는 opt-in CODE |
| Dashboard | 10 | 15 | 0 | 0 | 0 | 100% | MDAL 개념 제거 (REMOVED) |
| Board | 11 | 16 | 0 | 0 | 0 | 100% | Board Listener REMOVED (PG relay, filesystem-first에서 불필요) |
| Memory Systems | 12 | 44 | 0 | 0 | 0 | 100% | 4 시스템 전부 운용 |
| OAS Integration | 13 | 42 | 0 | 0 | 0 | 100% | 단방향 경계 완벽 준수 |
| Configuration | 14 | 68 | 0 | 0 | 0 | 100% | 80+ env var, 22 카테고리 |
| Testing | 15 | 98 | 0 | 0 | 0 | 100% | env-gated 6종 CI 활성화 확인 (MASC_E2E_TESTS=true) |
| **TOTAL** | | **450** | **7** | **0** | **0** | **98.5%** | |

**MISS: 0 | STUB: 0 | IMPL 비율: 98.5%**

---

## 2. CODE (빌드됨, 미사용) 항목 총정리

"코드는 있지만 쓰이지 않는 것"이 진짜 관심 대상이다.

| 항목 | 서브시스템 | LOC | 판정 근거 |
|------|----------|-----|---------|
| ~~Chain Engine 전체~~ | 04 | 17K | **→ REMOVED** (소스 삭제됨, lib/에 chain 파일 없음) |
| **HTTP/2 (h2c)** | 09 | 740 | opt-in 경로, canonical 기본값은 아님 |
| ~~SSE rate limit guard~~ | 09 | ~50 | **→ IMPL** (기본값 활성화: 1s cooldown, 60s/10 window) |
| ~~Board Listener (polling)~~ | 11 | ~100 | **→ REMOVED** (PG relay, filesystem-first에서 불필요. Board_dispatch가 SSE 직접 발사) |
| ~~Intent 도구 4종~~ | 06 | ~200 | **→ IMPL** (MCP tool registry 등록 + dispatch 완료) |
| ~~Keeper OAS Memory.t 일부~~ | 05 | ~100 | **→ IMPL** (v2.140.0 filesystem-first 전환으로 완료) |
| Team Session lossy projection | 07 | ~50 | `worker_specs` + prompt context만 유지하며 `collaboration_context`는 제거 개념으로 둠 |
| ~~env-gated 테스트~~ | 15 | ~300 | **→ IMPL** (6종 전부 MASC_E2E_TESTS=true로 CI 실행 중. PG 의존 없음 — 서버 바이너리 의존) |
| ~~MDAL dashboard surface~~ | 10 | ~50 | **→ REMOVED** (개념 폐기) |

**합계: CODE ~740 LOC** (h2c만 잔여. Chain 제거, Board Listener 제거)

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
| Verifier | cost_guard + risk_guard + Verifier_oas | IMPL | keeper_verifier.ml 589 LOC |
| Eval Harness | Scenario→graders→score | IMPL | eval_harness.ml |
| Anti-Fake | Test quality scoring | IMPL | anti_fake.ml |
| Hooks | Autonomy level gating (l3/l4/l5) | IMPL | keeper_hooks_oas.ml |
| Proactive | Quality gate + similarity + 3-retry fallback | IMPL | keeper_prompt.ml |
| Self-Model Drift | will/needs/desires compaction | IMPL | keeper_config.ml |
| TOML Config | config/keepers/*.toml | IMPL | keeper_toml_loader.ml |
| OAS Memory.t Bridge | 5-tier JSONL-only mapping | IMPL | memory_oas_bridge.ml (v2.140.0 filesystem-first 완료) |

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
| Intent Tools | create/status/update/forecast | IMPL | MCP tool registry 등록 + dispatch 연결 완료 |

### 07-Team Session (94% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| 47-field Session Record | Identity+Config+Runtime+Timestamps+Proof | IMPL | team_session_types.ml 697 LOC |
| 3 Orchestration Modes | Manual/Assist/Auto | IMPL | Engine handles all 3 |
| OAS Bridge | session→swarm_config, worker→agent_entry | IMPL | team_session_oas_bridge.ml 414 LOC |
| Swarm Runner | Load→convert→callbacks→run→apply | IMPL | team_session_swarm_runner.ml |
| Report/Proof | Markdown/JSON, Standard/Strong | IMPL | team_session_report_proof.ml 419 LOC |
| Tool Surface | 9 handler modules, 4.5K LOC | IMPL | God file 분할 완료 |
| Session Bridge Fidelity | `worker_specs` projection + prompt context, no `collaboration_context` | Architectural | fidelity gap remains by design |

### 08-Governance (100% IMPL)

| Section | Feature | Status | Evidence |
|---------|---------|--------|----------|
| Governance Surface | Empty compatibility payloads, no case tracking | IMPL | dashboard/dashboard_governance.ml |
| Governance Pipeline | 4 risk levels, pre-hook | IMPL | governance_pipeline.ml |
| Governance Registry | Runtime level resolution and policy mapping | IMPL | governance_registry.ml |
| Operator Control | Snapshot, digest, action, judgment | IMPL | operator_control.ml 26K |
| Governance Judge | Dashboard judgment loop | IMPL | dashboard/dashboard_governance_judge.ml |

### 09-Server/Transport (83% IMPL)

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
| SSE Rate Limit | **IMPL** | 기본값 활성화 (1s cooldown, 60s/10 window) |

### 10-Dashboard (100% IMPL)

핵심 기능 전부 IMPL: Cache SWR(Eio.Mutex), 23 HTTP endpoints, Governance/Execution/Mission/Proof surfaces, Keeper metrics, Preact SPA.
MDAL 개념 폐기 (REMOVED).

### 11-Board (100% IMPL)

핵심 기능 전부 IMPL: Parse-Don't-Validate ID, JSONL+PG dual backend, 5 sort algorithms, Thompson Sampling 9 call sites, pg_notify 4 event types, Karma/Flair.
Board Listener 제거됨 (PG relay, filesystem-first에서 Board_dispatch가 SSE 직접 발사).

### 12-Memory Systems (100% IMPL)

4개 시스템 전부 운용: Keeper Memory Bank(JSONL+compaction), Institution(episodic/semantic/procedural), Procedural Memory(crystallization), Context Budget(4 phases).
OAS Memory Bridge 5-tier 매핑 완전. Hebbian Learning(synapse model) 운용.

### 13-OAS Integration (100% IMPL)

단방향 경계(MASC→OAS) 14개 모듈에서 완벽 준수.
Oas_worker, Cascade config, Verifier, Event bus(13 types), Context compaction(4 strategies) 전부 운용.

### 14-Configuration (100% IMPL)

7-layer 설정 계층, 80+ env var, 22 카테고리, 8 mode presets, 3-layer filter, cascade.json hot-reload 전부 운용.

### 15-Testing (100% IMPL)

313 hermetic tests + 6 bench + 100 coverage supplements.
3-tier verification(hermetic/env-gated/manual), eval_gate(Swiss Cheese 4-layer), eval_harness, anti_fake, trajectory 전부 운용.
env-gated 6종은 CI에서 MASC_E2E_TESTS=true로 실행 확인.

---

## 4. Key Findings

### 건강한 서브시스템 (100% IMPL)
- Room, Memory, OAS, Config, Governance — 코드+테스트+실사용 모두 확인

### CODE 잔여 (1개, 740 LOC)
1. **HTTP/2 h2c** (740 LOC) → opt-in 경로, HTTP/1.1이 canonical. 벤치마크 후 전환 판단 필요

### 완료된 항목
- ~~Chain Engine~~ → 소스 삭제됨 (REMOVED)
- ~~Intent 도구~~ → MCP 등록 완료 (IMPL)
- ~~env-gated 테스트~~ → CI에서 전부 실행 중 (IMPL)
- ~~Board Listener~~ → 제거됨 (PG relay, Board_dispatch가 SSE 직접 발사)

### 아키텍처 의사결정 필요
1. live ICE/TURN/browser interop proof를 어떤 env-gated lane으로 운영할지

---

## 5. Recommendations

| 우선순위 | 항목 | 근거 |
|---------|------|------|
| ~~1~~ | ~~Server: SSE rate limit 활성화~~ | **완료** (기본값 1s/60s-10 활성화) |
| ~~2~~ | ~~Keeper: OAS Memory.t Long_term 백엔드 완성~~ | **완료** (v2.140.0 filesystem-first 전환) |
| 2 | Team Session: bridge fidelity 재설계 여부 결정 | `collaboration_context` 제거 상태에서 `worker_specs` / prompt context만으로 충분한지 판단 필요 |
| ~~1~~ | ~~Board Listener: filesystem-first 재설계~~ | **완료** (제거됨 — Board_dispatch가 SSE 직접 발사, PG relay 불필요) |
| 1 | Transport: HTTP/2 h2c 벤치마크 | opt-in→canonical 전환 판단 근거 |
| 3 | Transport: live ICE/TURN/browser interop 증빙 lane | local smoke 확보됨, internet-grade만 남음 |
