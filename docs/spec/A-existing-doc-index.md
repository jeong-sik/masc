# Appendix A: Existing Documentation Index

> masc-mcp 프로젝트 내 모든 문서 파일의 상태와 신규 spec 체계와의 관계를 정리한다.
> 기준일: 2026-03-23, v2.138.0

## Status 정의

| Status | 의미 |
|--------|------|
| Canonical | 해당 주제의 현재 권위 문서. 유지 관리 대상 |
| Superseded | docs/spec/ 파일이 대체. 참조용으로만 유지 |
| Reference | 역사적 가치 있으나 적극적으로 유지하지 않음 |
| Archive | docs/archive/로 이동 대상 |
| Orphaned | 목적이나 독자가 불분명. 삭제 또는 통합 대상 |

---

## Root-level Documents

| File | Lines | Status | Replacement | Summary |
|------|-------|--------|-------------|---------|
| `README.md` | 50+ | Canonical | -- | 프로젝트 소개, 빠른 시작, 빌드/테스트 안내 |
| `CLAUDE.md` | 200+ | Canonical | -- | Agent 전용 지침 (아키텍처, 빌드, 환경변수, Board, Dashboard) |
| `CHANGELOG.md` | 60+ | Canonical | -- | 릴리스별 변경 이력. v2.87.0부터 현재까지 |
| `ROADMAP.md` | 77 | Canonical | `B-migration-targets.md` 보완 | 단기/중기/장기 계획 SSOT |
| `CONTRIBUTING.md` | 50+ | Canonical | -- | 빌드 절차, 코드 스타일, 프로젝트 구조 |

---

## Canonical Documents (유지 관리 대상)

| File | Lines | Spec 연관 | Summary |
|------|-------|-----------|---------|
| `docs/COMMAND-PLANE-RUNBOOK.md` | -- | `06-command-plane.md` | CPv2 운영 순서, benchmark/swarm canonical path |
| `docs/BENCHMARK-RUNBOOK.md` | -- | `06-command-plane.md` | single-agent vs swarm benchmark recipe |
| `docs/SUPERVISOR-MODE.md` | -- | `07-team-session.md` | supervised team-session/operator 경로 |
| `docs/QUICK-START.md` | 47 | -- | 1-step setup, mode 선택, error recovery |
| `docs/COMMON-PITFALLS.md` | 81 | -- | PR 제출 전 반복 실수 체크리스트 |
| `docs/VERIFICATION-MATRIX.md` | 99 | `09-server-transport.md` | 검증 계층 분류 SSOT (hermetic/env-dependent/manual) |
| `docs/PERFORMANCE-SLO.md` | 42 | `09-server-transport.md` | 로컬/단일 머신 기준 체감 지연 목표 |
| `docs/MODE-SYSTEM.md` | 361 | `01-system-overview.md` | Serena-style tool filtering, core/standard/full profile |
| `docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md` | 199 | `B-migration-targets.md` | Tier 분류, 분할 계획, 복잡도 근본 원인 |
| `docs/VERSIONED-ROADMAP.md` | 60+ | -- | 버전 규칙, intake/triage 프로세스 |
| `docs/CAPABILITY-REGISTRY-SSOT.md` | 88 | `01-system-overview.md` | MCP tool vs internal capability 분류 |
| `docs/OAS-MASC-BOUNDARY.md` | 55 | `01-system-overview.md` | OAS/MASC 역할 경계 원칙 |
| `docs/OAS-MIGRATION-NEXT-STEPS.md` | 103 | `B-migration-targets.md` | OAS 마이그레이션 다음 단계 |
| `docs/OAS-UTILIZATION-AUDIT.md` | 86 | `B-migration-targets.md` | OAS 활용도 점수 (55/100) |
| `docs/PROVIDER-ADAPTER-RUNBOOK.md` | 85 | `04-chain-engine.md` | provider/runtime/auth 분리 SSOT |
| `docs/PROMPT-REGISTRY.md` | 38 | -- | prompt 코드 소재 색인 |
| `docs/MCP-TEMPLATE.md` | 29 | -- | ~/.mcp.json 설정 템플릿 |
| `docs/REMOTE-MCP-OPERATOR.md` | 157 | `09-server-transport.md` | /mcp/operator 원격 MCP surface |
| `docs/WORKER-SHELL-CONSTRAINTS.md` | 46 | `07-team-session.md` | spawn worker 셸 실행 제약 |
| `docs/IMMORTAL-SERVER-ROADMAP.md` | 187 | `09-server-transport.md` | 고가용성 서버 로드맵 (Phase 1-3) |

---

## Superseded Documents (docs/spec/ 파일이 대체)

| File | Lines | Replaced by | Summary |
|------|-------|-------------|---------|
| `docs/SPEC.md` | 518 | `docs/spec/01-system-overview.md` | 과거 전체 specification 스냅샷. 자체 경고 헤더 있음 |
| `docs/GLOSSARY.md` | 215 | `docs/spec/00-glossary.md` | v1.0.0 용어집. spec glossary가 확장 대체 |
| `docs/MERGED-ARCHITECTURE-SSOT.md` | 145 | `docs/spec/01-system-overview.md` | merged 아키텍처 요약. spec overview가 포괄 |
| `docs/SWARM-ARCHITECTURE.md` | 48 | `docs/spec/04-chain-engine.md` | Swarm 2-layer 구분. chain spec에 통합 |
| `docs/TEAM-SESSION-ARCHITECTURE.md` | 68 | `docs/spec/07-team-session.md` | Team session 오케스트레이션. spec에 통합 |
| `docs/TEAM-SESSION.md` | 271 | `docs/spec/07-team-session.md` | Team session 사용 가이드. spec에 통합 |
| `docs/DASHBOARD-INTEGRATION.md` | 87 | `docs/spec/10-dashboard.md` | Dashboard 통합 spec. dashboard spec에 통합 |
| `docs/MCP-SURFACE-AUDIT.md` | 196 | `docs/spec/01-system-overview.md` | MCP surface 감사. system overview에 반영 |
| `docs/PRODUCT-REVIEW.md` | 58 | `docs/spec/01-system-overview.md` | 제품 리뷰 (보안/API 계약). spec에 반영 |

---

## Reference Documents (역사적 가치, 비관리)

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/MASC-V2-DESIGN.md` | 364 | Git-native 멀티 에이전트 조율 초기 설계 | v2 설계 비전 문서 |
| `docs/HOLONIC-ARCHITECTURE.md` | 131 | Holonic 아키텍처 탐구 | 개념 문서, 구현에 부분 반영 |
| `docs/CELLULAR-AGENT.md` | 163 | Context handoff 패턴 | Legacy name "Cellular Agent" |
| `docs/MITOSIS.md` | 250 | 2-phase handoff flow | Legacy 용어 mitosis/DNA |
| `docs/ADR-001-MITOSIS-VS-COMPACTION.md` | 159 | Mitosis vs Compaction 결정 | ADR (Accepted) |
| `docs/THOUGHTROOM-ARCHITECTURE.md` | 454 | ThoughtRoom 개념 문서 | 미검증 상태 명시 |
| `docs/MULTI-ROOM-DESIGN.md` | 251 | Multi-room 호환성 노트 | Historical/internal |
| `docs/MDAL.md` | 111 | Metric-Driven Agent Loop | 기능 설명 문서 |
| `docs/INTERRUPT-DESIGN.md` | 153 | Human-in-the-loop 설계안 | LangGraph 패턴 참조 |
| `docs/JIPHYEONJEON-DESIGN.md` | 264 | AI 의회 시스템 설계 | 집현전 컨셉 |
| `docs/RESEARCH-BASED-IMPROVEMENTS.md` | 519 | 논문/연구 기반 개선 제안 | 초기 연구 정리 |
| `docs/RESEARCH-GAPS-CONCURRENCY.md` | 164 | 동시성/지식 전파 연구 갭 | 연구 노트 |
| `docs/SKEPTIC-PATTERNS.md` | 201 | Skeptic 리뷰 패턴 | 리뷰 가이드 |
| `docs/SPAWN-PERSISTENCE-DESIGN.md` | 222 | Spawn 영속성/복구 설계 | OpenClaw 패턴 참조 |
| `docs/METRICS-GENERATIONAL-IMPROVEMENT.md` | 240 | 세대별 개선 메트릭 증거 | 실험 기록 |
| `docs/CONTENT-DECAY-RESEARCH.md` | 129 | Content decay 연구 계획 | 연구 노트 |
| `docs/SEARCH-FABRIC-V1.md` | 106 | Search Fabric v1 설계 | public swarm API 대안 |
| `docs/RESIDENT-OPERATOR-JUDGE-DECISION-MEMO.md` | 335 | Resident/Operator/Judge 결정 메모 | 방향 제안 |
| `docs/EXECUTION-SCOPE-AND-WORKER-AUTONOMY-ANALYSIS.md` | 303 | 실행 범위/worker 자율성 분석 | 분석 문서 |
| `docs/HANDLE-STEP-DECOMPOSITION.md` | 120 | handle_step 분해 설계 | tool_team_session 리팩토링 |
| `docs/SANGSU-POLICY-V2-REPORT.md` | 196 | Sangsu 정책 v2 실험 보고 | 에이전트 실험 기록 |
| `docs/WEBRTC-COMPARISON.md` | 75 | WebRTC 구현 비교 | 참고 자료 |

---

## Reference: Keeper/Agent/Lodge

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/KEEPER-USER-MANUAL.md` | 643 | Keeper 사용자 매뉴얼 | Canonical이나 v2.138 기준 갱신 필요 |
| `docs/KEEPER-CONTINUITY-VALIDATION.md` | 160 | Keeper 연속성 검증 하네스 | Operator 검증용 |
| `docs/KEEPER-SOCIAL-EXPERIMENT-DESIGN.md` | 118 | Keeper 사회 실험 설계 | 미실행 |
| `docs/AGENT-MEMORY-SYSTEM.md` | 811 | Agent 메모리 시스템 설계 | Design phase 명시 |
| `docs/AGENT-TRUTH-AUDIT.md` | 71 | Agent truth 감사 계약 | Active contract |
| `docs/LODGE-ACTION-STATS.md` | 32 | Lodge action 통계 | 간략 문서 |

---

## Reference: TRPG/Game

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/GAME-VIEW-PROTOCOL.md` | 254 | Game view 프로토콜 초안 | Draft v0.1 |
| `docs/TRPG-DEVELOPMENT-PLAN.md` | 109 | TRPG 개발 계획 | MVP -> v0.1 |
| `docs/TRPG-EXPERIMENT-PLAYBOOK.md` | 118 | TRPG 사회 실험 템플릿 | MVP |
| `docs/TRPG-KEEPER-SPECTATOR-QUICKSTART.md` | 112 | TRPG 관전자 퀵스타트 | 운영 가이드 |
| `docs/TRPG-MVP-BLUEPRINT.md` | 172 | TRPG MVP 청사진 | Draft |
| `docs/TRPG-OPS-MANUAL.md` | 104 | TRPG 운영 매뉴얼 | v1 |
| `docs/TRPG-TURN-OBSERVABILITY-CHECKLIST.md` | 41 | TRPG 턴 관측 체크리스트 | 7-step |

---

## Reference: Transport/Protocol

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/TRANSPORT-VERIFICATION-CHECKLIST.md` | 401 | Transport 검증 체크리스트 | 포괄적 |
| `docs/DTLS-RFC6347-COMPLIANCE.md` | 243 | DTLS RFC 6347 커버리지 | Code inspection |
| `docs/RFC-COMPLIANCE-REVIEW.md` | 207 | WebRTC RFC 커버리지 리뷰 | Code inspection |
| `docs/WEBHOOK-RECEIVER-DESIGN.md` | 443 | Webhook receiver 설계 | 미구현 |

---

## Reference: OAS Migration

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/OAS-MIGRATION-AUDIT.md` | 79 | Model_client -> OAS 감사 | 감사 완료, 마이그레이션 보류 |
| `docs/OAS-PHASE1-EXPLORATION-SUMMARY.md` | 348 | OAS Phase 1 탐구 요약 | Lwt 부재 발견 |

---

## Reference: Dashboard

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/DASHBOARD-EXECUTION-VALIDATION.md` | 43 | Execution surface 검증 | Fixture mode |
| `docs/DASHBOARD-MISSION-VALIDATION.md` | 57 | Mission 검증 2층 구조 | 운영 절차 |
| `docs/DASHBOARD-WIDGET-AUDIT-2026-03-12.md` | 55 | Widget 감사 | 시점 스냅샷 |
| `docs/MASC-SOCIETY-AND-DASHBOARD-AUDIT.md` | 243 | Society + Dashboard 감사 | 분석 문서 |

---

## Design Documents (활성 설계)

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/design/LLM-JUDGE-DESIGN.md` | 311 | LLM Judge dashboard 개입 추천 | Issue #1870 |
| `docs/design/oas-masc-state-boundary.md` | 278 | OAS/MASC 상태 경계 | Issue #1736 |
| `docs/lodge-identity-v2/ARCHITECTURE.md` | 192 | Lodge identity v2 아키텍처 | 설계 완료, 구현 미착수 |
| `docs/lodge-identity-v2/RESEARCH.md` | 144 | Lodge identity 연구 참고 | 논문 목록 |
| `docs/lodge-identity-v2/ROADMAP.md` | 325 | Lodge identity v2 구현 로드맵 | Tier 1-3 |

---

## Research

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/research/LLM-REQUEST-SCHEDULER-SURVEY.md` | 103 | LLM 요청 스케줄러 서베이 | OAS 설계 참고 |

---

## QA

| File | Lines | Topic | Notes |
|------|-------|-------|-------|
| `docs/qa/REQUIREMENTS-REVERSE-ENGINEERED.md` | 279 | 코드 역추론 요구사항 | 역공학 spec |

---

## Archive (docs/archive/)

이미 docs/archive/에 이동 완료된 문서.

| File | Lines | 아카이브 사유 |
|------|-------|--------------|
| `docs/archive/IDEAS-2026-01.md` | -- | 9/11 완료, 2건 stale |
| `docs/archive/IMPROVEMENT-BACKLOG-MITOSIS.md` | -- | 25/25 완료 |
| `docs/archive/EVOLUTION-PLAN-FIGMA-MCP.md` | -- | 다른 repo 대상, 미착수 |
| `docs/archive/RELEASE-ROADMAP-v287.md` | -- | v2.87.0 완료 |
| `docs/archive/IMPROVEMENT-PLAN-2026-01.md` | -- | VERSIONED-ROADMAP이 대체 |

---

## Release Feedback (docs/release-feedback/)

| File | Topic |
|------|-------|
| `docs/release-feedback/v2.88.0-live-2026-03-14/README.md` | v2.88.0 피드백 요약 |
| `docs/release-feedback/v2.88.0-live-2026-03-14/cs-playbook.md` | CS 플레이북 |
| `docs/release-feedback/v2.88.0-live-2026-03-14/next-version-feedback.md` | 다음 버전 피드백 |
| `docs/release-feedback/v2.88.0-live-2026-03-14/user-report.md` | 사용자 보고 |
| `docs/release-feedback/v2.88.0-live-2026-03-14/version-truth-audit.md` | 버전 진실성 감사 |

---

## Orphaned (Archive 이동 후보)

| File | Lines | 사유 |
|------|-------|------|
| `docs/QUICKSTART.md` | 83 | `QUICK-START.md`와 중복. 서버 시작에 집중하나 README와도 겹침 |
| `docs/SETUP.md` | 82 | `QUICK-START.md`, `README.md`, `CONTRIBUTING.md`와 역할 중복 |
| `docs/INSTALL-CHECKLIST.md` | 24 | 설치 후 확인 체크리스트. `QUICK-START.md`에 통합 가능 |
| `docs/INTEGRATED-BENCHMARK-RUNBOOK.md` | -- | `BENCHMARK-RUNBOOK.md`와 목적 중복 |
| `docs/SWARM-DELIVERY-RUNBOOK.md` | 215 | 기능 슬라이스 구현 순서. 일반 워크플로 문서 |

---

## 통계 요약

| Category | Count | Total lines (approx) |
|----------|-------|---------------------|
| Root-level | 5 | ~450 |
| Canonical | 19 | ~2,800 |
| Superseded | 9 | ~1,700 |
| Reference | 42 | ~9,200 |
| Design (active) | 5 | ~1,250 |
| Research | 1 | ~100 |
| QA | 1 | ~280 |
| Archive (done) | 5 | -- |
| Release Feedback | 5 | -- |
| Orphaned | 5 | ~400 |
| **Total** | **97** | **~16,200** |

97개 문서 중 Canonical 24개(root 포함), Superseded 9개, Reference 42개.
문서의 43%가 Reference 상태로 적극적 유지 관리 대상이 아니다.
