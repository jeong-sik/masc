---
status: delivered
last_verified: 2026-08-23
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

## 현재 상태 (2026-08-23)

**P0~P2 15개 항목이 모두 구현되었습니다.** P3 5개는 아래 4절에서 TUI에 맞지 않는다고
판단해 제외한 것들이며, 그 판단은 유지합니다.

`bin/masc_tui_render.ml`이 그리는 화면은 다음과 같습니다.

| 화면 | 로드맵 |
|---|---|
| Overview (attention + events + tasks + task detail) | P0 #1 #2 #5, P2 #11 |
| Keepers (list / detail / logs / message) | P0, P1 #7 #8 |
| Approvals | P0 #3 |
| Board (list / read / compose) | P0 #4 |
| Planning (list / detail) | P0 #5 |
| Verification | P2 #12 |
| Harness | P2 #15 |
| Repositories | P2 #13 |
| Connectors | P1 #10 |
| Tools | P2 #14 |
| System Logs | P1 #9 |

Runtime/transport 상태(P1 #6)는 별도 화면이 아니라 Overview 헤더에 실려 있습니다.
Fleet 상태(P1 #7)는 키퍼 목록이 담을 수 없는 값을 그 화면 안에 붙이는 방식으로 들어갔습니다.

화면을 추가할 때 손대야 하는 자리는 타입(`masc_tui_types.ml`의 `surface`와
`surface_needs`), 로더, 렌더 dispatch, 그리고 키 처리입니다. `surface_needs`는
화면마다 필요한 데이터를 한 record로 선언하므로, 새 화면은 컴파일러가 그 record를
채우게 만듭니다.

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
| `workspace` | `board`, `sub-boards` (hidden) | board surface와 중복 |
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

> 원래의 우선순위 구분입니다. P0~P2는 모두 구현되었고, 어디에 들어갔는지를 표에
> 적어 두었습니다. P3는 구현하지 않기로 한 항목입니다.

### P0 — Core Operator Path

| # | 기능 | 어디에 |
|---|---|---|
| 1 | **Overview / Mission Briefing 뷰** | Overview |
| 2 | **Attention / 알림 패널** | Overview 상단 |
| 3 | **Approvals Queue + Confirm/Deny** | Approvals |
| 4 | **Board List/Read** | Board (compose 포함) |
| 5 | **Goal/Planning Tree** | Planning (list / detail) |

### P1 — Monitoring & Keeper Parity

| # | 기능 | 어디에 |
|---|---|---|
| 6 | **Monitoring > Runtime** | Overview 헤더의 transport 요약 |
| 7 | **Monitoring > Fleet Health** | Keepers 목록 안의 fleet 상태 |
| 8 | **Keeper Detail 강화** | Keeper Detail의 "Last 24h" |
| 9 | **System Logs** | System Logs |
| 10 | **Connector Status** | Connectors |

### P2 — Workspace & Lab

| # | 기능 | 어디에 |
|---|---|---|
| 11 | **Task/Work Board 상세** | Overview의 task detail |
| 12 | **Verification Requests** | Verification |
| 13 | **Repository List** | Repositories |
| 14 | **Tool Inventory** | Tools |
| 15 | **Harness Health** | Harness |

### P3 — 구현하지 않음

| # | 기능 | 근거 |
|---|---|---|
| 16 | **Schedule 상세 제어** | schedule은 조회 위주로 축소 |
| 17 | **Sub-Board** | board surface와 중복되거나 운영 빈도 낮음 |
| 18 | **Settings 변경** | 읽기 전용 조회만; 변경은 웹 대시보드 권장 |
| 19 | **Fusion / Code / Performance / Memory 그래프** | TUI 부적합 |
| 20 | **Copilot Dock / Command Palette / Tweaks Panel** | TUI에서 equivalently 지원 불필요 |

## 5. 그때의 미결 질문, 지금의 답

- **쓰기 작업은 어디까지 허용하나** — keeper 메시지, board 작성, approval confirm/deny,
  keeper lifecycle 조작, 그리고 도구 실행 승인(y/n)까지 됩니다. 읽기 전용이 아닙니다.
- **실시간 수신인가 폴링인가** — 둘 다입니다. keeper 채팅은 SSE 를 청크 단위로 읽어
  도구 호출과 답변을 turn 이 도는 동안 그리고, 나머지 화면은 폴링합니다.
- **파일시스템인가 HTTP인가** — 둘 다입니다. keeper 명부와 로그는 `.masc/` 에서 직접 읽고,
  대시보드 계열 화면은 HTTP 로 읽습니다.
- **인증** — `MASC_TOKEN` 이 있으면 Bearer 로 보냅니다 (`masc_tui_http.ml`의 `auth_headers`).
