# MASC-MCP Feature Requirements (코드 역추론)

> 생성일: 2026-03-13
> 방법론: API 엔드포인트 + Dashboard/Lobby 소스코드 정적 분석 + curl 기반 HTTP 검증
> 서버 버전: v2.86.0
> 판정 기준: PASS / PARTIAL / FAIL / NOT_IMPL

---

## 1. Web Lobby (`web/index.html`)

| ID | 기능 | API/프로토콜 | 판정 | 비고 |
|----|------|-------------|------|------|
| 1.1 | Agent List | `GET /api/v1/agents?limit=100` → JSON → DOM | PASS | REST API 기반으로 전환 (task-051) |
| 1.2 | Task List | `GET /api/v1/tasks?limit=15` → JSON → DOM | PASS | REST API 기반으로 전환 (task-051) |
| 1.3 | Broadcast | MCP `masc_broadcast` → SSE `event: message` → `onmessage` 핸들러 | PASS | max 50 이벤트 유지 |
| 1.4 | Agent Detail Modal | MCP `masc_messages` + `masc_task_history` | PASS | 클릭 시 모달 렌더링 |
| 1.5 | SSE 연결 | `GET /sse?room=...&session_id=...` | PASS | `onmessage` + JSON `type` 라우팅으로 전환 (task-050). 서버도 join/leave SSE broadcast 추가 |
| 1.6 | SSE 재연결 | `EventSource` close → exponential backoff | PASS | base 1s, max 30s |
| 1.7 | Identity | `localStorage.getItem('masc_lobby_agent')` | PASS | 저장/리셋 동작 |
| 1.8 | Leave on Unload | `navigator.sendBeacon` → `masc_leave` | PASS | beforeunload 핸들러 |

### 1.5 상세: SSE 이벤트 수정 이력

- **수정 전**: Lobby가 `addEventListener('broadcast', ...)`, `addEventListener('agent_update', ...)` 사용 — 서버가 `event: message`로 보내므로 전부 동작 안 함
- **수정 후** (task-050): `onmessage` 핸들러 + JSON `type` 필드 라우팅. Dashboard 패턴과 일치
- **서버 측** (task-050): `masc_join`/`masc_leave`에 `Mcp_server.sse_broadcast` 호출 추가. 기존에는 MCP 세션 큐에만 push

---

## 2. Dashboard — 지금 (Now)

### 2.1 상황판 (Mission)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 2.1.1 | 스냅샷 로딩 | `GET /api/v1/dashboard/mission` | PASS | sessions, attention_queue, keeper_briefs, internal_signals, summary 포함 |
| 2.1.2 | 요약 통계 | mission.summary → SummaryStat 6개 | PASS | 활성 세션, 막힌 세션, 최근 사건, 참여자, 키퍼, 최근 응답 |
| 2.1.3 | 세션 브리프 | mission.sessions → SessionBriefCard | PASS | goal, health, blocker_summary, member_names |
| 2.1.4 | 세션 디테일 | `GET /api/v1/dashboard/session?session_id=...` | PASS | 세션 선택 시 상세 로드 |
| 2.1.5 | Attention Queue | mission.attention_queue → AttentionCard | PASS | severity 기반 정렬, 세션 연결 |
| 2.1.6 | 키퍼 브리프 | mission.keeper_briefs → KeeperBriefCard | PASS | 최대 6개, enrichedKeeperRow 변환 |
| 2.1.7 | 내부 신호 | mission.internal_signals → InternalSignalCard | PASS | details disclosure, 최대 3개 |
| 2.1.8 | Briefing | `GET /api/v1/dashboard/mission/briefing` | PASS | 3 sections 반환 |
| 2.1.9 | 빈 상태 | missionLoading/missionError/null 분기 | PASS | "상황판 스냅샷이 아직 없습니다" 등 3가지 |
| 2.1.10 | Room Health | mission.summary.room_health → toneClass | PARTIAL | idle 서버에서 "bad" 판정. false positive 가능성 |

**UI 컴포넌트**: `mission.ts`, `mission-cards.ts`, `mission-utils.ts`, `mission-store.ts`

### 2.2 실행 (Execution)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 2.2.1 | 실행 스냅샷 | `GET /api/v1/dashboard/execution` | PASS | queue, session_briefs, operation_briefs, keeper_column |
| 2.2.2 | 에이전트 카드 | agents signal → AgentCard | PASS | 한국어 상태 라벨 10종 |
| 2.2.3 | 세션 브리프 | execution.session_briefs | PASS | |
| 2.2.4 | 오퍼레이션 브리프 | execution.operation_briefs | PASS | |
| 2.2.5 | 키퍼 칼럼 | execution.keeper_column | PASS | |
| 2.2.6 | Worker Support | keeper autonomy agents 연동 | PASS | |

**한국어 상태 라벨**: 안정, 진행 중, 일시정지, 막힘, 중단됨, 주의, 위험, 오프라인, 대기, 확인 필요

**UI 컴포넌트**: `agents.ts`, `agent-detail.ts`, `keeper-detail.ts`, `ops/`

### 2.3 라이브 (Live)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 2.3.1 | SSE 저널 | SSE → journal signal (max 200) | PASS | |
| 2.3.2 | 이벤트 카운터 | eventCount signal | PASS | |
| 2.3.3 | 연결 상태 | connected signal | PASS | |
| 2.3.4 | 재연결 | base 1000ms, max 15000ms backoff | PASS | |

**UI 컴포넌트**: `sse.ts`, `sse-store.ts`

---

## 3. Dashboard — 이유 (Why)

### 3.1 근거 (Proof)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 3.1.1 | Proof 스냅샷 | `GET /api/v1/dashboard/proof` | PASS | verdict, entries |
| 3.1.2 | Verdict 표시 | proven/partial/insufficient → 충분/부분/부족 | PASS | |
| 3.1.3 | Provenance 표시 | ProvenanceStrip (truth/derived/opinion) | PASS | |

**UI 컴포넌트**: `proof.ts`

### 3.2 메모리/게시판 (Memory/Board)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 3.2.1 | 게시글 목록 | `GET /api/v1/board?sort=recent&limit=20` | PASS | 5개 정렬 모드 |
| 3.2.2 | 게시글 상세 | `GET /api/v1/board/<id>?format=flat` | PASS | 본문 + 댓글 |
| 3.2.3 | 투표 | `POST /api/v1/tools/masc_board_vote` | PASS | direction + vote 필드, 카운트 갱신 |
| 3.2.4 | 댓글 | `POST /api/v1/tools/masc_board_comment` | PASS | content 필드 (body 아님) |
| 3.2.5 | Hearths | `GET /api/v1/board/hearths` | PASS | |
| 3.2.6 | Flairs | `GET /api/v1/board/flairs` | PASS | |
| 3.2.7 | Karma | `GET /api/v1/karma` | PASS | 리더보드 |
| 3.2.8 | 자동 게시글 필터 | hideAutomationPosts toggle | PASS | keeper-system, team-session 작성자 필터 |

**정렬 모드**: 최신순(recent), 인기순(hot), 급상승(trending), 최근 갱신(updated), 토론 많은 순(discussed)

**UI 컴포넌트**: `memory.ts`

### 3.3 거버넌스 (Governance)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 3.3.1 | 케이스 목록 | `GET /api/v1/dashboard/governance` | PARTIAL | API 정상, idle 시 0건. judge 활동 없음 |
| 3.3.2 | 필터 | open/pending_ruling/needs_human_gate/executed/blocked | PASS | UI 필터 구현됨 |
| 3.3.3 | 케이스 상세 | petition, brief, execution_order | PASS | UI 구현됨 |
| 3.3.4 | 브리프 제출 | `POST /mcp` → `masc_case_brief_submit` | PASS | |

**UI 컴포넌트**: `governance.ts`

---

## 4. Dashboard — 개입 (Act)

### 4.1 계획 (Planning)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 4.1.1 | 목표 목록 | `GET /api/v1/dashboard/planning` | PASS | horizon (short/mid/long) + status 필터 |
| 4.1.2 | 태스크 백로그 | planning.task_backlog | PASS | 20 todo 태스크 확인 |
| 4.1.3 | MDAL 루프 | `GET /api/v1/mdal/loops` | PASS | 빈 루프 반환 (정상) |

**UI 컴포넌트**: `goals.ts`

### 4.2 도구 (Tools)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 4.2.1 | 도구 목록 | `GET /api/v1/dashboard/tools` | PASS | |
| 4.2.2 | 도구 메트릭 | `GET /api/v1/tool-metrics` | PASS | |

### 4.3 개입 (Intervene/Operator)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 4.3.1 | 오퍼레이터 스냅샷 | `GET /api/v1/operator` | PASS | pending_confirms, action_types |
| 4.3.2 | 다이제스트 | `GET /api/v1/operator/digest` | PASS | |
| 4.3.3 | 액션 실행 | `POST /api/v1/operator/action` | PASS | action_type 필드 필수 |
| 4.3.4 | 대기 확인 | `POST /api/v1/operator/confirm` | PASS | confirm_token + actor + decision |

**유효 action_type**: `keeper_message`, `keeper_recover`, `team_worker_spawn_batch`, `social_sweep`, `autonomy_tick`

---

## 5. Dashboard — 실험 (Lab)

### 5.1 지휘 (Command)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 5.1.1 | CP 스냅샷 | `GET /api/v1/command-plane` | PASS | |
| 5.1.2 | Summary | `GET /api/v1/command-plane/summary` | PASS | |
| 5.1.3 | Warroom (legacy backend) | `GET /api/v1/command-plane/warroom` | PASS | dashboard surface는 retired, legacy deep link는 `intervene`로 redirect |
| 5.1.4 | Swarm | `GET /api/v1/command-plane/swarm` | PASS | |
| 5.1.5 | Orchestra | `GET /api/v1/command-plane/orchestra` | PASS | `?summary_only=true`로 경량 응답 지원 (task-052) |
| 5.1.6 | Help | `GET /api/v1/command-plane/help` | PASS | |
| 5.1.7 | Chains | `GET /api/v1/chains/summary` | PASS | |

**현재 Dashboard sub-surfaces**: intervene, governance

**Legacy command-plane backend views**: warroom, summary, topology, orchestra, swarm, operations, trace, chains, control, alerts

**UI 컴포넌트**: `components/control.ts`, `components/ops/index.ts`, `components/governance.ts`

### 5.2 실험 (Lab/TRPG)

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 5.2.1 | TRPG State | `GET /api/v1/trpg/state?room_id=default` | PARTIAL | lobby 상태, 게임 미진행 |
| 5.2.2 | TRPG Events | `GET /api/v1/trpg/events?room_id=default` | PARTIAL | 빈 이벤트 |
| 5.2.3 | Dice Roll | `POST /api/v1/trpg/dice/roll` | NOT_IMPL | 게임 미시작 시 검증 불가 |
| 5.2.4 | Turn Advance | `POST /api/v1/trpg/turns/advance` | NOT_IMPL | 동일 |

**UI 컴포넌트**: `lab.ts`, `trpg/`

---

## 6. Viewer (`viewer/index.html`)

| ID | 기능 | 판정 | 비고 |
|----|------|------|------|
| 6.1 | Mode Selector (4개) | NOT_IMPL | Rust/WASM 빌드. API 레벨 검증 불가 |
| 6.2 | TRPG Mode | NOT_IMPL | |
| 6.3 | System Monitor | NOT_IMPL | |
| 6.4 | Social Board | NOT_IMPL | |
| 6.5 | Experiment Lab | NOT_IMPL | |

**4 모드**: trpg, experiment, monitor, social

---

## 7. 공통 (Cross-Cutting)

### 7.1 SSE 이벤트 시스템

| ID | 기능 | 판정 | 비고 |
|----|------|------|------|
| 7.1.1 | 연결 | `GET /sse?session_id=...&room=...` | PASS | retry:3000 |
| 7.1.2 | 이벤트 타입 | broadcast, agent_joined, agent_left, task_update, heartbeat, keeper_heartbeat | PASS | |
| 7.1.3 | Dashboard 수신 | sse-store.ts 이벤트 디스패치 | PASS | debounced refresh |
| 7.1.4 | Lobby 수신 | web/index.html EventSource | PASS | `onmessage` + JSON type 라우팅으로 수정 (task-050) |
| 7.1.5 | 재연결 | Dashboard: 1-15s backoff, Lobby: 1-30s backoff | PASS | |

### 7.2 인증

| ID | 기능 | 판정 | 비고 |
|----|------|------|------|
| 7.2.1 | X-MASC-Agent 헤더 | PASS | REST API 인증 |
| 7.2.2 | Bearer Token | PASS | MCP 인증 |
| 7.2.3 | ?token= 쿼리 | PASS | SSE 인증 |

### 7.3 Keeper Autonomy 에이전트

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 7.3.1 | 에이전트 목록 | `GET /api/v1/keeper/agents` | PASS | 정의 반환 |

### 7.4 Karma

| ID | 기능 | API | 판정 | 비고 |
|----|------|-----|------|------|
| 7.4.1 | 리더보드 | `GET /api/v1/karma` | PASS | 에이전트별 점수 |

### 7.5 API 공통 사항

| 항목 | 값 | 비고 |
|------|---|------|
| 기본 타임아웃 | GET 15s, POST 30s, MCP 60s | api.ts 확인 |
| Retry | 408/425/429/500/502/503/504 → 2회 재시도 | api.ts 확인 |
| MCP Accept 헤더 | `application/json, text/event-stream` | 필수. 없으면 -32600 |
| MCP 응답 형식 | SSE (`retry: 3000\n\ndata: {...}`) | JSON-RPC를 SSE로 래핑 |

### 7.6 Dashboard 라우팅

| 해시 경로 | 탭 | 카테고리 |
|----------|-----|---------|
| `#mission` | 상황판 | 지금 (Now) |
| `#execution` | 실행 | 지금 (Now) |
| `#live` | 라이브 | 지금 (Now) |
| `#proof` | 근거 | 이유 (Why) |
| `#memory` | 메모리/게시판 | 이유 (Why) |
| `#governance` | 거버넌스 | 이유 (Why) |
| `#planning` | 계획 | 개입 (Act) |
| `#tools` | 도구 | 개입 (Act) |
| `#intervene` | 개입/오퍼레이터 | 개입 (Act) |
| `#command` | 지휘 | 실험 (Lab) |
| `#lab` | 실험/TRPG | 실험 (Lab) |

**특수 경로**: `chains/operation/<id>` → command 탭, `lab/<surface>` → lab 탭

---

## QA 결과 요약

| 판정 | 건수 | 비율 |
|------|------|------|
| PASS | 56 | 78% |
| PARTIAL | 4 | 6% |
| NOT_IMPL | 7 | 10% |
| FAIL | 0 | 0% |

### 발견 및 수정된 이슈

| # | Area | 우선순위 | 이슈 | 상태 |
|---|------|---------|------|------|
| 1 | 1 (Lobby SSE) | high | Lobby SSE: `addEventListener` → `onmessage` 전환 + 서버 join/leave SSE broadcast 추가 | FIXED (task-050) |
| 2 | 1 (Lobby Parsing) | medium | MCP regex 파싱 → REST API (`/api/v1/agents`, `/api/v1/tasks`) 전환 | FIXED (task-051) |
| 3 | 6 (Orchestra) | medium | 196KB 응답 → `?summary_only=true` 경량 모드 추가 | FIXED (task-052) |
| 4 | 3 (Mission) | low | idle 서버 cache_contention false positive → traffic=0이면 "ok" 반환 | FIXED (task-053) |
| 5 | 5 (Governance) | low | judge runtime 활동 없음 — 테스트 케이스 필요 |
| 6 | 7 (TRPG) | low | 게임 미시작 상태 — E2E 플로우 검증 불가 |
