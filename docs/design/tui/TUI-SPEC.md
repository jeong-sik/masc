---
status: draft
last_verified: 2026-06-26
code_refs:
  - bin/masc_tui.ml
  - bin/masc_tui_types.ml
  - bin/masc_tui_render.ml
  - bin/masc_tui_loader.ml
  - docs/TUI-GUIDE.md
  - docs/design/tui/TUI-ROADMAP.md
---

# MASC TUI Spec & Design Draft

> 본 문서는 `docs/design/tui/TUI-ROADMAP.md`의 P0 범위 중 현재 PR에서 런타임에 노출하는 surface를 정의한다.
> 현재는 초안(draft)이며, 사용자/운영자 검토를 거쳐 구체화한다.

## 1. 개요 및 목표

### 1.1 목표

MASC TUI를 Dashboard V2 surface 기준으로 확장하여, 웹 대시보드 없이도 핵심 운영 시나리오를 터미널에서 수행할 수 있게 한다.

### 1.2 In-Scope

- 현재 PR에서 노출하는 뷰: Overview, Keepers, Board, Approvals, Planning
- 후속 로드맵: Monitoring, Command/Operations, Workspace, Lab, Logs
- 읽기 위주의 데이터 노출 + 제한된 쓰기 (approval confirm/deny, operator action, keeper message — 기존 유지)
- ANSI 터미널 기반 UI, 별도 UI 라이브러리 미사용

### 1.3 Out-of-Scope

- `fusion`, `code > ide-shell`, `lab > performance`, rich HTML/Markdown 렌더링
- 설정 변경 UI (`settings`는 읽기 전용 조회만 선택적 검토)
- 그래프, 차트, 이미지, 코드 diff 시각화

## 2. 아키텍처 개요

```
+------------------+
|   TUI Main Loop  |  bin/masc_tui.ml
|  (input/render)  |
+--------+---------+
         |
+--------v---------+      +---------------------+
|  View Dispatcher |----->|  Surface Renderers  |  bin/masc_tui_render.ml (확장)
|  (surface enum)  |      |  - overview         |
+------------------+      |  - keepers          |
         |                |  - board            |
+--------v---------+      |  - approvals        |
|   State Store    |      |  - planning         |
|  (signals-like)  |      +---------------------+
+------------------+
         |
+--------v---------+
|   Data Loader    |
|  (FS + HTTP API) |
+------------------+
```

### 2.1 확장된 view enum (제안)

```ocaml
type surface =
  | Overview
  | Keepers of keeper_mode
  | Board
  | Approvals
  | Planning
```

기존 `view_mode` (Dashboard | Keeper_list | Keeper_detail | Keeper_logs | Keeper_message)은 keepers surface 내부 상태로 재편된다.

### 2.2 데이터 로더 전략

| 소스 | 우선순위 | 사용 시나리오 |
|---|---|---|
| `.masc/` 파일시스템 | 기본 (serverless) | agent, task, keeper, board JSONL 등 정적/준정적 데이터 |
| HTTP `/api/v1/dashboard/*` | 서버 실행 시 | overview, monitoring, approvals, operator action 등 |
| HTTP `/api/v1/*` | 필요 시 | board, keepers, tasks 등 |

로더는 HTTP API 실패/미가용 시 파일시스템 폴백을 시도할 수 있다.

## 3. 데이터 소스

### 3.1 파일시스템 (기존 유지 + 확장)

| 데이터 | 경로 |
|---|---|
| agents | `.masc/agents/*.json` |
| tasks | `.masc/tasks/*.json` |
| keepers | `.masc/keepers/*.json` |
| keeper metrics | `.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl` |
| board posts | `.masc/board_posts.jsonl` |
| board comments | `.masc/board_comments.jsonl` |
| board votes | `.masc/board_votes.jsonl` |
| board sub-boards | `.masc/board_sub_boards.jsonl` |
| Gate decisions | `.masc/gates/decisions/YYYY-MM/DD.jsonl` |
| system logs | `.masc/logs/*.log` (또는 stdout redirect) |

### 3.2 HTTP API (신규 통합)

| 엔드포인트 | 용도 |
|---|---|
| `GET /api/v1/dashboard/shell` | Overview snapshot |
| `GET /api/v1/dashboard/briefing` | Mission briefing |
| `GET /api/v1/dashboard/briefing/sections` | Briefing sections |
| `GET /api/v1/dashboard/namespace-truth` | Agents namespace truth |
| `GET /api/v1/dashboard/telemetry/summary` | Fleet-health |
| `GET /api/v1/dashboard/transport-health` | Transport health |
| `GET /api/v1/dashboard/planning` | Goal tree |
| `GET /api/v1/dashboard/tools` | Tool inventory |
| `GET /api/v1/dashboard/harness-health` | Harness health |
| `GET /api/v1/dashboard/logs` | System logs |
| `GET /api/v1/board` | Board posts |
| `GET /api/v1/board/:postId` | Post detail |
| `GET /api/v1/verification/requests` | Verification queue |
| `GET /api/v1/verification/summary` | Verification summary |
| `GET /api/v1/operator/digest` | Operator digest |
| `POST /api/v1/operator/confirm` | Confirm approval |
| `POST /api/v1/operator/action` | Operator action |
| `GET /api/v1/gate/connectors` | Connector status |
| `GET /api/v1/mdal/loops` | Schedule loops |

## 4. 뷰/화면 설계

### 4.1 Overview Surface

```
┌─────────────────────────────────────────────────────────────┐
│ MASC TUI  Overview  [connected]  12:03:45                   │
├─────────────────────────────────────────────────────────────┤
│ Briefing                                                    │
│   • 3 keepers active, 1 stuck (>15m)                        │
│   • 2 tasks in progress, 1 awaiting verification            │
│   • 1 pending HITL approval                                 │
├─────────────────────────────────────────────────────────────┤
│ Attention                      │ Recent Events              │
│ [CRIT] keeper alpha stuck      │ 12:02 task-42 claimed      │
│ [WARN] context >80% on beta    │ 11:58 approval pending     │
├─────────────────────────────────────────────────────────────┤
│ Tab: next  r: refresh  q: quit                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Future Monitoring Surface

- `agents`: keeper roster + composite phase + last seen
- `fleet-health`: tool call health (total/failures/timeouts/failure_rate/p95)
- `runtime`: runtime lane health, cost view
- `observatory`: activity graph 요약 (텍스트)
- `transport-health`: transport discovery/listening 상태

### 4.3 Keepers Surface (기존 유지 + 강화)

- List: name, generation, runtime lane, composite phase, goal
- Detail: identity, live context, runtime lane, runtime stats, behavior, timestamps
- Logs: metrics JSONL tail
- Message: chat stream

강화: 24h bucket 요약, tool call 카운트, composite phase (`Stable <- paused`)

### 4.4 Board Surface

```
┌─────────────────────────────────────────────────────────────┐
│ Board  (hot)  12 posts                                       │
├─────────────────────────────────────────────────────────────┤
│ > [insight]  p-a1b2  alice   How to reduce Eio yield?   +5  │
│   [question] p-c3d4  bob     TUI keybinding convention?   +2  │
├─────────────────────────────────────────────────────────────┤
│ [Enter] read  [n] new post  [s] sort  [h] hearth filter      │
└─────────────────────────────────────────────────────────────┘
```

- 목록: sort (hot/trending/recent/discussed), hearth filter
- 읽기: post + comments tree
- 제한적 쓰기: vote (up/down) — 향후 고려

### 4.5 Approvals Surface

```
┌─────────────────────────────────────────────────────────────┐
│ Approvals  (2 pending)                                       │
├─────────────────────────────────────────────────────────────┤
│ > keeper alpha requests tool_call: shell_exec               │
│   reason: run tests for PR #12345                           │
│   [y] confirm  [n] deny  [d] details                        │
└─────────────────────────────────────────────────────────────┘
```

### 4.6 Planning Surface

- Goal tree (fold/unfold): phase badge 기준
- Task kanban-ish list
- Verification requests

### 4.7 Future Lab Surface

- Tools: registered MCP tool 목록 + server
- Harness: safety harness health snapshot
- Keeper Memory Health: per-keeper fact store size, GC stats

### 4.8 Future Logs Surface

- System logs tail (파일 또는 `/api/v1/dashboard/logs`)
- Keeper logs는 keepers surface 내부에 유지

## 5. 네비게이션 및 키바인딩

### 5.1 Global Navigation

| 키 | 동작 |
|---|---|
| `Tab` | 다음 surface (overview -> keepers -> approvals -> board -> planning) |
| `q` | TUI 종료 |
| `r` | 강제 새로고침 |
| `?` | 키 도움말 overlay |
| `Esc` | 뒤로가기 / overlay 닫기 |

### 5.2 List View 공통

| 키 | 동작 |
|---|---|
| `j` / `k` | 아래/위 |
| `g` / `G` | 처음/끝 |
| `Enter` | 상세 |
| `/` | 검색/필터 |

### 5.3 Board-specific

| 키 | 동작 |
|---|---|
| `n` | 새 post (향후) |
| `v` | upvote |
| `s` | sort cycle |
| `h` | hearth filter |

### 5.4 Approvals-specific

| 키 | 동작 |
|---|---|
| `y` | confirm |
| `n` | deny |
| `d` | details |

## 6. 상태 모델

```ocaml
type tui_state = {
  (* common *)
  surface: surface;
  connection_status: string;
  last_refresh: float;
  refresh_interval: float;
  messages: string list; (* toast-like status messages *)

  (* per-surface caches *)
  overview: overview_snapshot option;
  board_posts: board_post list;
  board_selected_post: Post_id.t option;
  approvals: approval_item list;
  planning: goal_tree option;

  (* keepers (기존) *)
  keepers: keeper list;
  keeper_cursor: int;
  keeper_detail_view: keeper_detail_mode;
  log_entries: log_entry list;
  log_scroll: int;
  msg_input: Buffer.t;
  msg_history: msg_entry list;
  ...
}
```

## 7. 단계별 구현 계획

### Phase 0: Foundation

1. `view_mode`를 `surface` 기반 enum으로 리팩토링
2. render dispatch를 surface 기반으로 확장
3. HTTP API 클라이언트 추가 (`masc_tui_http.ml`)
4. 파일시스템/HTTP dual data loader 추상화

### Phase 1: P0 Surfaces

1. Overview surface
2. Board list/read
3. Approvals queue + confirm/deny
4. Planning (goal tree)

### Phase 2: P1 Monitoring

1. Monitoring > agents (keeper roster enhancement)
2. Monitoring > fleet-health
3. Monitoring > runtime
4. Monitoring > transport-health
5. Logs surface

### Phase 3: P2 Workspace & Lab

1. Workspace > work (task board)
2. Workspace > verification
3. Workspace > repositories
4. Lab > tools
5. Lab > harness
6. Lab > keeper-memory-health

### Phase 4: Keeper Parity Polish

1. Keeper detail 24h bucket / tool stats
2. Keeper composite phase
3. Multi-line message input (optional)

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| HTTP API 의존 시 서버 미실행으로 기능 제한 | 파일시스템 폴백 + `connection_status` 명시 |
| 터미널 크기 제한으로 정보 밀도 과다 | fold/unfold, scroll, section collapse 지원 |
| 쓰기 작업(confirm/action) 실수 | confirm dialog (`y` 두 번 누르기 등) 추가 |
| ANSI 호환성 문제 | `NO_COLOR` 환경 변수 존중, plain-text fallback |
| 복잡한 Dashboard JSON 파싱 부담 | light 모드 도입, 필요한 필드만 decode |

## 9. Open Questions

- P0 surface 중 **첫 번째 prototype**으로 어떤 것을 선택할 것인가?
- WebSocket/SSE 실시간 업데이트를 TUI에서 수용할 것인가, 아니면 폴링만 할 것인가?
- TUI에서의 **인증 흐름**: `ensureDevToken`을 어떻게 처리할 것인가?
- 쓰기 작업의 **권한/안전성**: operator action/confirm은 누구나 가능한가?
- Overview의 briefing은 `/api/v1/dashboard/briefing/sections`(LLM 생성)을 사용할 것인가, 아니면 light 요약만 할 것인가?
