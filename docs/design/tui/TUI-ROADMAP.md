---
status: draft
last_verified: 2026-06-26
code_refs:
  - bin/masc_tui.ml
  - bin/masc_tui_types.ml
  - bin/masc_tui_render.ml
  - bin/masc_tui_loader.ml
  - docs/TUI-GUIDE.md
  - dashboard/src/config/navigation.ts
  - docs/spec/10-dashboard.md
---

# MASC TUI Roadmap (Dashboard-aligned)

> 목표: Web Dashboard V2의 surface/section을 기준으로 MASC TUI에 필요한 기능을 파악하고, 기존 TUI 구현 대비 **Keep / Drop / Add / Change**를 결정한다.
> 범위: 문서 기획 단계. 본 문서는 우선순위와 방향을 제시하며, 구현 코드는 포함하지 않는다.

## Current PR Implementation Scope

현재 PR은 P0 operator path 중 런타임에 실제 구현된 surface만 노출한다: Overview, Keepers, Board, Approvals, Planning.
Monitoring, Command/Operations, Workspace 세부 화면, Lab, Logs는 이 문서의 로드맵 항목으로 남기며 production 탭 순환이나 render dispatch에는 placeholder로 노출하지 않는다.

## 1. 현재 TUI 상태 요약

`bin/masc_tui*.ml`과 `docs/TUI-GUIDE.md`를 기준으로 TUI는 이미 다음 뷰를 구현하고 있다.

| 뷰 | 상태 | 데이터 소스 |
|---|---|---|
| Dashboard (agents + events + tasks) | 구현됨 | `.masc/agents/`, `.masc/tasks/`, 이벤트 버퍼 |
| Keeper List | 구현됨 | `.masc/keepers/*.json` |
| Keeper Detail | 구현됨 | keeper metadata + live metrics |
| Keeper Logs | 구현됨 | `<keeper>/metrics/YYYY-MM/DD.jsonl` |
| Keeper Message | 구현됨 | `POST /api/v1/keepers/chat/stream` |

즉, TUI는 Dashboard V2의 `keepers` surface와 일부 `monitoring > agents` 기능을 이미 커버하고 있다. 나머지 surface/section을 대상으로 확장 로드맵을 세운다.

## 2. 기준: Dashboard V2 Surfaces

`dashboard/src/config/navigation.ts`의 canonical surface/section을 기준으로 한다.

| Surface | Section | TUI 적합도 노트 |
|---|---|---|
| `overview` | (single) | 요약/브리핑은 텍스트로 가능 |
| `monitoring` | `agents`, `fleet-health`, `runtime`, `observatory` | 테이블/텍스트로 가능 |
| `monitoring` | `transport-health`, `feature-health` (hidden) | 진단용 텍스트로 가능 |
| `keepers` | (single) | 이미 구현됨 |
| `board` | (single) | 게시글 목록/읽기는 텍스트로 가능 |
| `schedule` | (single) | 텍스트 목록으로 가능 |
| `approvals` | (single) | HITL queue는 리스트로 가능 |
| `fusion` | (single) | rich panel/judge deliberation → **TUI 부적합** |
| `command` | `operations` | operator action/confirm은 가능 |
| `connectors` | `connector-status` | 상태 리스트로 가능 |
| `workspace` | `work`, `planning`, `repositories`, `verification` | 가능 |
| `workspace` | `board`, `sub-boards`, `moderation` (hidden) | board surface와 중복 |
| `lab` | `tools`, `harness`, `performance`, `memory-subsystems`, `keeper-memory-health` | 부분 가능 |
| `code` | `ide-shell` | **TUI에 부적합** |
| `settings` | 다수 | 부분 가능 |
| `logs` | (single) | system logs 추가 가능 |

## 3. 기능 결정

### 3.1 Keep (현재 유지)

| 기능 | 이유 |
|---|---|
| Dashboard 모드 (agents/events/tasks) | 기존 진입점 유지 |
| Keeper List / Detail / Logs / Message | 이미 안정적으로 동작, 핵심 TUI 사용 시나리오 |
| 2초 주기 수동/자동 새로고침 | 단순하고 신뢰할 수 있는 refresh 모델 |
| ANSI 박스 기반 렌더링 | 별도 라이브러리 의존성 없음 (`unix`, `yojson`만 사용) |

### 3.2 Drop (TUI에서 제외 또는 deferred)

| 기능 | 이유 |
|---|---|
| `fusion` surface 전체 | panel/judge deliberation은 터미널에서 해석/표현 비용이 크고, 웹 대시보드가 적합 |
| `code > ide-shell` | 코드 리뷰/IDE 셸은 TUI가 아닌 웹/데스크톱 IDE의 영역 |
| `lab > performance` | FPS meter, VirtualList, content-visibility 등은 웹 렌더링 전용 개념 |
| `lab > memory-subsystems`의 그래프 시각화 | Hebbian synapse 그래프 등은 텍스트로 표현이 어려움 |
| `settings`의 prompt/fusion/policy/lifecycle 등 대부분 | 복잡한 폼 기반 설정은 웹 대시보드가 적합; TUI에서는 읽기 전용 노출만 검토 |
| rich HTML/Markdown 렌더링 | TUI는 plain-text 위주로 축소 |

### 3.3 Add (신규 추가)

| 기능 | 대시보드 근거 | TUI 형태 |
|---|---|---|
| **Overview / Mission Briefing** | `overview`, `/api/v1/dashboard/briefing` | 요약 텍스트 패널 |
| **Board List / Read** | `board`, `/api/v1/board` | 게시글 목록 + 본문 뷰어 |
| **Sub-Board List** | `workspace > sub-boards` | 목록 |
| **Approvals Queue** | `approvals`, `/api/v1/operator/confirm` | HITL 대기 목록 + confirm/deny |
| **Command / Operations** | `command > operations`, `/api/v1/operator/action` | operator action 목록 + 실행 |
| **Schedule List** | `schedule`, `/api/v1/mdal/loops` | 예약/loop 목록 |
| **System Logs** | `logs`, `/api/v1/dashboard/logs` | 로그 tail |
| **Connector Status** | `connectors > connector-status`, `/api/v1/gate/connectors` | connector 상태 테이블 |
| **Goal/Planning Tree** | `workspace > planning`, `/api/v1/dashboard/planning` | 트리 뷰 (fold/unfold) |
| **Task/Work Board** | `workspace > work`, `/api/v1/tasks` | task 보드 |
| **Verification Requests** | `workspace > verification`, `/api/v1/verification/requests` | 검증 요청 목록 |
| **Repository List** | `workspace > repositories` | 저장소 목록 |
| **Tool Inventory** | `lab > tools`, `/api/v1/dashboard/tools` | tool 목록/검색 |
| **Harness Health** | `lab > harness`, `/api/v1/dashboard/harness-health` | 상태 요약 |
| **Keeper Memory Health** | `lab > keeper-memory-health` | per-keeper fact store 크기/통계 |
| **Transport Health** | `monitoring > transport-health`, `/api/v1/dashboard/transport-health` | transport 상태 요약 |

### 3.4 Change (변경/강화)

| 기능 | 현재 | 변경 방향 |
|---|---|---|
| Dashboard 모드 | agents/events/tasks 3패널 | overview 브리핑 섹션 추가, attention item 요약 추가 |
| Keeper Detail | 단일 keeper 메트릭 | 24h bucket 요약, tool call 카운트 추가 (dashboard keeper metrics parity) |
| Keeper List | 단순 리스트 | FSM composite phase 노출 (`Stable <- paused` 등 collapsed_from) |
| 메시지 입력 | 기본 라인 입력 | multi-line 입력 고려 (향후), `/` prefix 명령어 확장 고려 |
| 데이터 소스 | 파일시스템 위주 | HTTP API 우선 모드 추가 (server required 시 API fallback) |
| 키바인딩 | 고정 | surface별 context-sensitive 키 체계로 확장 |

## 4. 우선순위

> P0: 다음 구현 집중 대상. P1: 중기. P2: 후기. P3: experimental/deferred.

### P0 — Core Operator Path

| # | 기능 | 근거 |
|---|---|---|
| 1 | **Overview / Mission Briefing 뷰** | 운영자가 가장 먼저 보는 요약. TUI도 동일 진입점 제공 |
| 2 | **Attention / 알림 패널** | 운영자 개입이 필요한 항목( stuck agent, blocked lane 등)을 TUI에서도 노출 |
| 3 | **Approvals Queue + Confirm/Deny** | HITL approval은 대시보드 없이도 빠르게 처리해야 함 |
| 4 | **Board List/Read** | 비동기 커뮤니케이션의 핵심. keeper/agent 메시지 흐름 파악 |
| 5 | **Goal/Planning Tree** | 현재 task 상태 파악. `workspace > work/planning`과 parity |

### P1 — Monitoring & Keeper Parity

| # | 기능 | 근거 |
|---|---|---|
| 6 | **Monitoring > Runtime** | runtime lane health, transport health |
| 7 | **Monitoring > Fleet Health (tool monitor)** | tool call health, governance signals |
| 8 | **Keeper Detail 강화** | 24h bucket, tool stats, composite phase |
| 9 | **System Logs** | `logs` surface parity |
| 10 | **Connector Status** | sidecar 상태 모니터링 |

### P2 — Workspace & Lab

| # | 기능 | 근거 |
|---|---|---|
| 11 | **Task/Work Board 상세** | task claim/assign, 우선순위 |
| 12 | **Verification Requests** | cross-agent verification |
| 13 | **Repository List** | multi-repo cockpit |
| 14 | **Tool Inventory** | registered MCP tools |
| 15 | **Harness Health** | safety harness snapshot |

### P3 — Deferred / Experimental

| # | 기능 | 근거 |
|---|---|---|
| 16 | **Schedule 상세 제어** | schedule은 조회 위주로 축소 |
| 17 | **Sub-Board / Moderation** | board surface와 중복되거나 운영 빈도 낮음 |
| 18 | **Settings 변경** | 읽기 전용 조회만; 변경은 웹 대시보드 권장 |
| 19 | **Fusion / Code / Performance / Memory 그래프** | TUI 부적합 |
| 20 | **Copilot Dock / Command Palette / Tweaks Panel** | TUI에서 equivalently 지원 불필요 |

## 5. 제안된 다음 단계

1. `TUI-SPEC.md` 초안 작성 — 화면 흐름, 데이터 모델, 키바인딩, 단계별 구현 계획 정의
2. P0 기능 중 하나(예: Overview 또는 Board)를 prototype으로 구현
3. 기존 `masc_tui.ml`의 view 모드 enum과 render dispatch를 surface 기반으로 확장하는 설계 검토
4. Dashboard HTTP API(`/api/v1/dashboard/*`)를 TUI 데이터 소스로 통합하는 방안 확정
5. 사용자/운영자 피드백 수집 후 P1 범위 조정

## 6. Open Questions

- TUI에서의 **쓰기 작업**(confirm/action/post/comment/vote) 허용 범위는? 현재는 keeper message만 쓰기가 가능.
- WebSocket/SSE 이벤트를 TUI에서 실시간 수신할 것인가, 아니면 폴링만 유지할 것인가?
- TUI의 **기본 런칭 모드**: 파일시스템 스냅샷(서버 불필요) vs HTTP API(서버 필요). 두 모드를 모두 지원?
- 인증/토큰은 dev-token (`/api/v1/dev-token`)을 어떻게 처리할 것인가?
