---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/dashboard/
  - lib/dashboard.ml
  - dashboard/
---

# Dashboard

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Dashboard |
| Maps to | `lib/dashboard/dashboard_*.ml`, `lib/server/server_dashboard_http*.ml`, `lib/web_dashboard.ml`, `lib/credits_dashboard.ml`, `dashboard/` |
| Dependencies | 09-server-transport, 05-keeper-agent, Room, Operator_control, Team_session_store, Governance Pipeline |
| Modules (OCaml) | 39 (.ml + .mli) |
| LOC (OCaml) | ~13K |
| Modules (Frontend) | ~210 TypeScript + ~15 CSS |
| LOC (Frontend) | ~36K TypeScript + ~3.8K CSS |

## 1. Purpose

MASC 상태를 실시간으로 시각화하는 웹 대시보드.
OCaml 서버가 JSON API를 제공하고, Preact SPA가 SSE로 실시간 업데이트를 수신한다.

핵심 역할:
- Room, Session, Keeper, Agent의 상태를 하나의 운영 콘솔로 통합
- 운영자 개입이 필요한 항목(Attention)을 자동 분류하고 우선순위를 부여
- Governance 심의 흐름, Proof 증거, historical compatibility 상태를 읽기 전용으로 구분해 표시
- Keeper 메트릭 시계열, 도구 호출 건강도, MDAL 루프 진행을 시각화

### 1.1. Current v1 Shell Contract

현재 canonical Dashboard v1 shell은 다음 top-level tab으로 고정된다.

- `overview`
- `monitoring`
- `command`
- `connectors`
- `workspace`
- `lab`
- `logs`

탭별 canonical section inventory:

- `overview`
  - `#overview`
- `monitoring`
  - `#monitoring?section=journey`
  - `#monitoring?section=observatory`
  - `#monitoring?section=agents`
  - `#monitoring?section=runtime`
  - `#monitoring?section=fleet-health`
  - `#monitoring?section=memory-subsystems`
  - `#monitoring?section=attribution`
- `command`
  - `#command?section=operations`
- `connectors`
  - `#connectors?section=connector-status`
  - `#connectors?section=connector-discord`
  - `#connectors?section=connector-imessage`
  - `#connectors?section=connector-slack`
  - `#connectors?section=connector-telegram`
- `workspace`
  - `#workspace?section=board`
  - `#workspace?section=planning`
  - `#workspace?section=verification`
- `lab`
  - `#lab?section=tools`
  - `#lab?section=autoresearch`
  - `#lab?section=harness`
- `logs`
  - `#logs`

## 2. Architecture

```
Browser (Preact SPA)
  |
  |-- SSE (/sse) ---> OCaml HTTP Server (Httpun_eio)
  |-- REST (/api/v1/*) ---> OCaml HTTP Handler (server_dashboard_http.ml)
  |
  +-- Vite build --> assets/dashboard/ --> web_dashboard.ml (static file serving)

OCaml Backend:
  server_dashboard_http.ml (facade)
    |-- server_dashboard_http_core.ml (Executor_pool offload, batch API)
    |-- server_dashboard_http_runtime_info.ml (runtime/config resolution, tools)
    |-- server_dashboard_http_execution_surfaces.ml (execution/transport cache + refresh)
    |-- server_dashboard_http_namespace_truth_support.ml (shared namespace-truth assembly)
    |-- server_dashboard_http_namespace_truth.ml (namespace-truth read model + SSE snapshot)
    |-- dashboard_http_monitoring.ml  (tool health, board/governance monitors)
    |-- dashboard_http_keeper.ml      (keeper dashboard rendering)
    |   |-- dashboard_http_keeper_detail.ml (metrics window computation)
    |   |-- dashboard_http_keeper_metrics.ml (types, 24h bucket stats)
    |-- dashboard_http_mdal.ml        (MDAL loop rendering)
    |-- dashboard_http_helpers.ml     (env parsing, JSON utilities)
    |
    |-- dashboard_execution.ml        (Execution surface)
    |   |-- dashboard_execution_helpers.ml
    |   |-- dashboard_execution_builders.ml
    |   |-- dashboard_execution_sessions.ml
    |   |-- dashboard_execution_fixture.ml
    |
    |-- dashboard_mission.ml          (Mission surface)
    |   |-- dashboard_mission_assembly.ml
    |   |-- dashboard_mission_agents.ml
    |   |-- dashboard_mission_briefing.ml
    |
    |-- dashboard_governance.ml       (Governance surface)
    |-- dashboard_governance_judge.ml (Judge operator loop)
    |-- dashboard_operator_judge.ml   (Operator judge)
    |
    |-- dashboard_proof.ml            (Proof surface)
    |   |-- dashboard_proof_events.ml
    |   |-- dashboard_proof_actors.ml
    |   |-- dashboard_proof_verdict.ml
    |   |-- dashboard_proof_helpers.ml
    |
    |-- dashboard_cache.ml            (SWR cache with Eio.Mutex)
    |-- dashboard_labels.ml           (Pure state-to-text translation)
    |-- dashboard_semantics.ml        ("Why" layer -- surface/panel/metric registry)
    |-- dashboard_attention.ml        (Attention item detection)
    |-- dashboard_agent_relations.ml  (GraphQL proxy for agent relations)
    |-- dashboard_utils.ml            (ISO timestamp, text normalization)
    |-- dashboard_provider_runs.ml    (Provider run tracking)
    |
    |-- credits_dashboard.ml          (Standalone OCaml-rendered HTML dashboard)
    |-- web_dashboard.ml              (Static file serving wrapper)
```

## 3. Backend Subsystems

### 3.1. Cache Layer (`dashboard_cache.ml`, `dashboard_cache.mli`)

**364 LOC.** 시간 기반 메모이제이션과 stale-while-revalidate 패턴을 구현한다.

#### 핵심 타입

```ocaml
type entry = {
  value : Yojson.Safe.t;
  expires_at : float;    (* fresh 유효기간 *)
  stale_until : float;   (* stale grace 기간 *)
}

type slot =
  | Ready of entry
  | Computing of { cond : Eio.Condition.t; started_at : float; stale : Yojson.Safe.t option }
```

#### 동작 모드 3가지

| 조건 | 동작 |
|------|------|
| `now < expires_at` (Fresh) | 즉시 반환 |
| `expires_at <= now < stale_until` (Stale) | stale 값 즉시 반환 + background fiber로 재계산 |
| `now >= stale_until` 또는 미존재 | 블로킹 계산 후 반환 |

#### 설계 결정

- **stale_factor = 10.0**: Eio cooperative scheduling에서 compute-heavy endpoint의 wall-clock 시간이 길어지므로, stale window를 TTL의 10배로 설정하여 즉시 응답 비율을 높인다.
- **max_wait_sec = 130.0**: 가장 긴 endpoint 타임아웃(120s, /execution)보다 길게 설정하여 계산 중인 slot을 중간에 evict하지 않는다.
- **per-key locking**: 단일 `Eio.Mutex`가 `Hashtbl` 접근만 보호하고, `compute` 함수는 lock 밖에서 실행된다. 서로 다른 key에 대한 nested `get_or_compute`가 deadlock 없이 동작한다.
- **poll-retry vs Condition.await**: `Condition.await`는 `protect:true` 내부에서 Eio cancellation이 비활성화되어 영구 블로킹 위험이 있다. 대신 0.5s 간격 poll loop를 mutex 밖에서 실행하여 cancellation을 유지한다.
- **cooldown after timeout eviction**: Computing slot이 `max_wait_sec`를 초과하면, 즉시 새 compute를 시작하지 않고 15초 cooldown Ready entry를 삽입하여 thrashing을 방지한다.
- **ownership token**: 각 compute는 자신의 `cond`를 소유권 토큰으로 사용한다. write-back 전 physical equality(`==`)로 slot이 교체되지 않았는지 확인하여, evict된 fiber가 후속 slot을 덮어쓰는 것을 방지한다.

#### API Surface

| 함수 | 용도 |
|------|------|
| `enable_eio ?clock ()` | Eio.Mutex 활성화. `Eio_main.run` 내부에서 1회 호출 |
| `set_sw sw` | Background revalidation fiber용 switch 등록 |
| `get_or_compute key ~ttl f` | 캐시 조회 또는 계산 |
| `get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec f` | 타임아웃 포함 계산 |
| `invalidate key` | 단일 entry 제거 |
| `invalidate_all ()` | 전체 entry 제거 (mutation 후 사용) |
| `stats ()` | `{entries, fresh, stale, computing, expired}` JSON 반환 |

### 3.2. Labels Layer (`dashboard_labels.ml`)

**171 LOC.** 순수 함수. IO 없음. raw 상태를 운영자가 읽을 수 있는 텍스트로 변환한다.

- **Agent status 번역**: `Active` + 15분 이상 미활동 = `"STUCK"`, 5분 이상 = `"quiet"`, `Listening` = `"idle"`, `Inactive` = `"offline"`
- **Agent 분류**: `classify_agent` -> `Working | Stuck | Idle | Offline` (downstream capacity 로직에서 Offline을 available로 취급하지 않기 위해 Idle과 분리)
- **Lane status 번역**: phase + motion_state 조합을 한 줄 문장으로 변환
- **Flag code 번역**: `"pending_manual_confirmation"` -> `"Waiting for your approval"` 등
- **Health verdict**: lane summary 목록에서 stalled/blocked lane 수를 세어 한 줄 건강 요약 생성

공유 타입 정의:
```ocaml
type swarm_lane_summary = { label; present; phase; motion_state; age; current_step; hard_flags }
type room_snapshot = { room_id; is_current; agents; tasks; messages; locks }
```

### 3.3. Semantics Layer (`dashboard_semantics.ml`)

**726 LOC.** 대시보드의 "왜" 레이어. 각 surface, panel, metric에 대해 `purpose`, `problem_solved`, `when_active`, `agent_role`, `ecosystem_function`을 선언적으로 등록한다.

주의: 이 registry는 내부 문서화/테스트용 historical naming(`mission`, `execution`, `proof`, `intervene` 등)을 여전히 포함한다. current Dashboard v1 shell의 navigation SSOT는 `dashboard/src/config/navigation.ts` 와 `lib/dashboard/dashboard_surface_readiness.ml` 이다.

12개 surface를 정의한다:

| Surface ID | Label | Panel 수 |
|------------|-------|---------|
| `side_rail` | 사이드 레일 | 3 |
| `home` | Home | 7 |
| `mission` | 미션 | 14 |
| `intervene` | Intervene | 7 |
| `proof` | Proof | 7 |
| `command` | Command | 10 |
| `execution` | Execution | 6 |
| `memory` | Memory | 1 |
| `governance` | Governance | 8 |
| `activity_graph` | Activity Graph | 4 |
| `planning` | Planning | 4 |
| `lab` | Lab | 3 |

Dashboard semantics registry는 내부 문서화/테스트용으로 유지되며, 프론트엔드는 더 이상 `/api/v1/dashboard/semantics`를 읽지 않는다.

### 3.4. Attention Detection (`dashboard_attention.ml`)

**212 LOC.** 순수 함수. Room snapshot을 스캔하여 운영자 개입이 필요한 항목을 분류한다.

```ocaml
type severity = Critical | Warning | Info

type attention_item = {
  severity : severity;
  category : string;      (* "stuck_agent", "blocked_lane", etc. *)
  summary : string;       (* 사람이 읽을 수 있는 한 줄 설명 *)
  suggested_tool : string; (* MCP 도구 이름 *)
}
```

탐지 규칙 예시:
- **stuck_agent**: `Active|Busy` 상태인데 `last_seen`이 15분(900s) 이상 전 -> `Critical`
- severity 순서(`Critical > Warning > Info`)로 정렬하여 반환

### 3.5. Governance Surface (`dashboard_governance.ml`)

현재 `dashboard_governance.ml`은 빈 호환성 payload를 반환하는 compatibility stub이다. Governance case tracking은 retire되었고, 대시보드 endpoint는 0 요약치와 empty list를 반환한다.

주요 함수:
- `dashboard_json`: governance summary + judge 상태의 빈 호환 응답
- `cases_json`: 빈 case 목록 (pagination 유지)
- `case_detail_json`: 단일 case 조회 시 not-found 응답
- `factual_snapshot_json`: judge 입력용 빈 팩트 스냅샷

### 3.6. Governance Judge (`dashboard_governance_judge.ml`)

**400 LOC.** 주기적으로 governance factual snapshot을 LLM에 보내고 judgment를 생성하는 daemon fiber.

- `start`: `Eio.Fiber.fork_daemon`으로 시작. `MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC` (기본 60초) 간격으로 반복
- `refresh_once`: `Oas_worker.run_named_with_masc_tools`로 `"governance_judge"` cascade 호출 -> judgment 파싱 -> `Dated_jsonl` store에 append
- **date-split store**: `.masc/governance/judgments/YYYY-MM/DD.jsonl` (legacy 단일 파일 fallback 지원)
- `compute_judgments`: factual JSON을 prompt로 변환하고 LLM 호출. 결과에서 item별 judgment를 파싱하여 반환
- **allowed_tool whitelist**: recommended_action의 resolved_tool은 5개 도구만 허용 (`masc_governance_status`, `masc_execution_orders`, `masc_execute_dry_run`, `masc_execute`, `masc_operator_confirm`)
- 상태: per-base_path mutable state (`judge_online`, `refreshing`, `generated_at`, `model_used`, `last_error`)

### 3.7. Execution Surface (`dashboard_execution.ml` + 하위 모듈)

**~2,020 LOC (4 sub-modules 포함).** 운영 중인 session, operation, worker, keeper의 실행 상태를 종합한다.

`.mli` 시그니처:
```ocaml
val json :
  ?actor:string -> ?fixture:string -> ?light:bool ->
  config:Room.config -> sw:Eio.Switch.t -> clock:'a Eio.Time.clock ->
  proc_mgr:_ option -> unit -> Yojson.Safe.t
```

#### Sub-modules

| 모듈 | LOC | 역할 |
|------|-----|------|
| `dashboard_execution_helpers.ml` | 475 | `session_context`, `operation_context`, `queue_context` 등 타입 정의 + JSON 필드 접근 헬퍼 |
| `dashboard_execution_builders.ml` | 473 | `build_session_contexts`, `build_operation_contexts`, `build_execution_queue`, `build_worker_support_briefs`, `build_continuity_briefs` |
| `dashboard_execution_sessions.ml` | 420 | `Team_session_store` 기반 session card 구축 |
| `dashboard_execution_fixture.ml` | 513 | 테스트 fixture (`execution_smoke`) |
| `dashboard_execution.ml` | 306 | 최상위 orchestration: session 로드 -> snapshot -> digest -> queue/worker/continuity 빌드 |

#### 렌더링 흐름

1. `since_unix` 24h cutoff으로 session 필터링 (최대 100개)
2. `Operator_control.snapshot_json`으로 전체 room snapshot 구성
3. (full mode) `Operator_control.digest_json`에서 session_cards 추출
4. session/operation/execution_queue/worker/continuity context 구축
5. 크기 제한 적용: sessions max 15, operations max 20 (active만), queue max 10, tasks max 50

#### 성능 보호

- **render_timeout_s = 30.0**: `Eio.Time.with_timeout`으로 감싸서 PG 연결 실패 시 무한 대기 방지 (실제 11,018s hang 발생 기록)
- **Eio.Fiber.yield()**: CPU-bound 구간 사이에 명시적 yield 삽입하여 SSE/health-check fiber가 진행할 수 있게 보장
- **light mode**: 기본 모드. messages 직렬화를 생략하여 ~143KB 절감

### 3.8. Mission Surface (`dashboard_mission.ml` + 하위 모듈)

**~1,975 LOC (3 sub-modules 포함).** Room 인시던트와 다음 액션을 위한 트리아지 우선 랜딩 뷰.

`.mli` 시그니처:
```ocaml
val json :
  ?actor:string -> config:Room.config -> sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock -> proc_mgr:_ option -> unit -> Yojson.Safe.t
```

| 모듈 | LOC | 역할 |
|------|-----|------|
| `dashboard_mission_assembly.ml` | 486 | `session_context`, `attention_context` 타입 + session assembly 로직 |
| `dashboard_mission_agents.ml` | 403 | agent card 구축 (agent pulse, session-agent mapping) |
| `dashboard_mission_briefing.ml` | 316 | mission briefing 생성 (LLM 기반 요약 + metadata gap 감지) |

`dashboard_mission_briefing.mli`는 테스트용 `For_test` sig를 노출한다:
- `compact_session_json`, `compact_keeper_json`, `compact_agent_json`: briefing 입력 압축
- `relevant_sessions_for_briefing`: 현재 room의 active session 필터링
- `collect_metadata_gaps`: session/keeper/agent의 metadata 누락 감지
- `build_briefing_sections`: 요약 텍스트 + section JSON 빌드

### 3.9. Proof Surface (`dashboard_proof.ml` + 하위 모듈)

**~748 LOC (4 sub-modules 포함).** 협업 증거, actor 기여, 관리 backing artifact를 하나의 읽기 전용 surface로 통합한다.

`.mli` 시그니처:
```ocaml
val json :
  ?actor:string -> ?session_id:string -> ?operation_id:string ->
  config:Room.config -> unit -> Yojson.Safe.t
```

| 모듈 | LOC | 역할 |
|------|-----|------|
| `dashboard_proof_helpers.ml` | 84 | 공유 헬퍼 |
| `dashboard_proof_events.ml` | 115 | 이벤트 파싱 |
| `dashboard_proof_actors.ml` | 283 | actor 기여 분석 |
| `dashboard_proof_verdict.ml` | 266 | verdict, timeline, session summary |

proof 문서가 존재하지 않으면 `Team_session_report_proof.generate_proof`로 자동 생성한다.

### 3.10. Keeper Metrics & Detail (`dashboard_http_keeper*.ml`)

**~1,801 LOC (3 모듈).** Keeper별 메트릭 시계열, 24h bucket 통계, 대화 이력, 메모리 뱅크, 진단 요약을 렌더링한다.

| 모듈 | LOC | 역할 |
|------|-----|------|
| `dashboard_http_keeper_metrics.ml` | 420 | `keeper_gen_window_stats` 타입, model/tool count table, UTF-8 safe prefix |
| `dashboard_http_keeper_detail.ml` | 775 | metrics window computation: handoff/compaction/fallback/tool_call/drift/goal_alignment/memory 카운터 추출 |
| `dashboard_http_keeper.ml` | 606 | `keepers_dashboard_json` 최상위 함수. Eio.Fiber.all로 keeper별 I/O를 병렬 실행 |

`keepers_dashboard_json` 흐름:
1. `Keeper_types.keeper_names`로 keeper 이름 목록 취득
2. keeper별로 `Eio.Fiber.all`로 병렬 I/O (metadata + metrics read)
3. `Dated_jsonl.read_recent_lines`로 metrics 로드 (compact: 120줄, full: 500줄 cap)
4. generation별 stats 집계 (`keeper_gen_window_stats`)
5. 24h bucket 통계, 시계열 series, 대화 이력 fragment 등 JSON 구성

### 3.11. Agent Relations (`dashboard_agent_relations.ml`)

**100 LOC.** GraphQL 프록시. Second Brain GraphQL 서버에서 `COLLABORATED_WITH` 네트워크와 `TRUSTS` 관계를 fetch하여 대시보드 JSON으로 변환한다.

2개의 GraphQL 쿼리:
- `agentCollaborationNetworkByName`: name/collaborations/lastCollab
- `agent > relations`: type/category/confidence/participants

### 3.12. Monitoring (`dashboard_http_monitoring.ml`)

**268 LOC.** 도구 호출 건강도, Board 모니터, Governance 모니터를 제공한다.

- `tool_call_health_json`: 설정 가능한 window (기본 1시간) 내 tool_call 이벤트에서 total/failures/timeouts/failure_rate/p95_duration_ms 계산
- `board_monitoring_json`: Board 계약 건강도
- `governance_monitoring_json`: Governance 피드 건강도

### 3.13. Credits Dashboard (`credits_dashboard.ml`)

**529 LOC.** 별도의 OCaml 렌더링 HTML 대시보드. `/dashboard/credits` 경로에서 서빙된다.

`~/me/data/state/credits.json`을 읽어서 AI 서비스 사용량을 시각화한다 (Claude Max, ChatGPT Pro, ElevenLabs, RunPod, Railway, Anthropic API 등).

SPA가 아닌 OCaml에서 직접 HTML을 생성하여 반환하는 독립 페이지이며, JSON API (`/api/v1/credits`)도 함께 제공한다.

### 3.14. Static File Serving (`web_dashboard.ml`)

**58 LOC.** SPA index.html과 static asset을 서빙하는 래퍼.

- `assets_root()`: `MASC_ASSETS_ROOT` -> `MASC_ASSETS_DIR` -> `exe_dir/assets` -> `cwd/assets` 순서로 탐색
- `index_path()`: `{assets_root}/dashboard/index.html`
- `html()`: index.html 로드 (파일 없으면 빌드 안내 fallback HTML)
- `etag()`: mtime 기반 ETag 생성 (12자 hex)
- `is_safe_asset_relative_path`: path traversal 방어 (`.`, `..`, `\`, `\0` 거부)

### 3.15. HTTP Endpoint Orchestration (`server_dashboard_http*.ml`)

**~1,176 LOC (2 모듈).**

#### Executor Pool Offload (`server_dashboard_http_core.ml`)

CPU-heavy 대시보드 계산을 `Eio.Executor_pool`에 위임하여 main Eio domain의 MCP tool call이 starve되지 않게 한다.

```ocaml
val run_dashboard_compute :
  sw:_ -> clock:_ -> config:Room.config ->
  (config:Room.config -> sw:Eio.Switch.t -> 'a) -> 'a
```

PostgresNative 백엔드의 경우 domain-local Caqti pool을 생성한다 (main domain의 pool은 Switch capture로 인해 domain-bound).

#### Proactive Refresh (`start_execution_refresh_loop`)

Execution endpoint는 proactive refresh loop로 60초 간격 사전 계산하여 `_execution_json_ref`에 저장한다.
기본 요청(파라미터 없는 light mode)은 캐시된 값을 0ms에 반환한다.
파라미터가 있는 요청(fixture/actor/full)만 on-demand SWR cache를 사용한다.

#### Dashboard timeout wrapper

```ocaml
val with_dashboard_timeout : clock:_ -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
```
30초 타임아웃. 초과 시 `{"error":"timeout","partial":true,...}` 반환.

## 4. Frontend Architecture

### 4.1. Technology Stack

| 항목 | 기술 |
|------|------|
| UI Framework | Preact (~3KB) + HTM (~1KB) |
| State | @preact/signals (reactive, fine-grained re-render) |
| Build | Vite + @preact/preset-vite |
| CSS | Tailwind CSS (@tailwindcss/vite plugin) |
| Test | Vitest |
| Language | TypeScript |

### 4.2. Directory Structure

```
dashboard/
  src/
    main.ts                    -- Entry point
    app.ts                     -- Root component
    router.ts                  -- Hash-based routing
    sse.ts                     -- SSE hook (auto-reconnect, signal dispatch)
    store.ts                   -- Centralized signal store
    api.ts                     -- API barrel re-export
    api/
      core.ts                  -- HTTP infra, auth, generic fetchers
      dashboard.ts             -- Dashboard projection fetchers
      board.ts                 -- Board API
      keeper.ts                -- Keeper API (streaming chat)
      mcp.ts                   -- MCP tool proxy
      trpg.ts                  -- TRPG API
      actions.ts               -- Operator actions, activity graph
    types.ts                   -- Type barrel re-export
    types/
      core.ts                  -- Agent, Task, Message, Keeper, BoardPost, ...
      dashboard-execution.ts   -- Execution response types
      dashboard-mission.ts     -- Mission response types
      command-plane.ts         -- Historical compatibility types
      governance.ts            -- Governance types
      oas.ts                   -- OAS types
      sse.ts                   -- SSE event types
      trpg.ts                  -- TRPG types
    components/
      dashboard-shell.ts       -- Top-level shell (side rail + content)
      overview/                -- Overview surface (7 components)
      status.ts                -- Monitoring shell (journey / observatory / agents / runtime / fleet-health / memory-subsystems / attribution)
      control.ts               -- Command shell (`operations`)
      connector-status.ts      -- Connectors surface
      work.ts                  -- Workspace shell (board / planning / verification)
      lab.ts                   -- Lab shell (tools / autoresearch / harness)
      keeper-*.ts              -- Keeper detail (8 components)
      agent-*.ts               -- Agent views (8 components)
      live/                    -- Live activity (3 components)
      goals/                   -- Planning surface (5 components)
      ops/                     -- Operations sub-view internals (7 components)
      lab*.ts                  -- Lab surface (2 components)
      tools/                   -- Tool inventory (5 components)
      common/                  -- Shared primitives (30+ components)
    normalizers/               -- Swarm data normalizers (7 modules)
    *-store.ts, *-signals.ts   -- Domain signal stores
    *-normalizers.ts           -- Data normalization
    styles/                    -- CSS files (15)
    config/
      navigation.ts            -- Dashboard surface/tab definitions
      avatar-palettes.ts       -- Avatar visual config
    lib/                       -- Utility modules (format-time, truncate, ...)
  index.html
  vite.config.ts
  tsconfig.json
  vitest.config.ts
  package.json
```

### 4.3. Routing

Hash-based routing (`#overview`, `#monitoring?section=journey`, `#command?section=operations`, `#connectors?section=connector-status`, ...).

```typescript
const DEFAULT_ROUTE: RouteState = { tab: 'overview', params: {}, postId: null }
```

라우팅 흐름:
1. `location.hash`에서 path + query params 파싱
2. segment 정규화 (`/dashboard/` prefix 제거)
3. canonical tab ID 해석 (`VALID_TABS` 확인)
4. 현재 canonical tab/section은 `navigation.ts` 의 `DASHBOARD_SURFACES` / `DASHBOARD_SECTION_ITEMS` 가 결정한다
5. Legacy section redirect는 `SECTION_REDIRECTS` 가 담당한다
6. 대표 redirect:
   - `sessions -> agents`
   - `activity -> observatory`
   - `telemetry|fleet|tool-quality|governance -> fleet-health` (+ `view`)
   - `intervene|governance|inspector -> operations`
   - `workspace.goals -> workspace.planning`
7. `command?section=operations&view=connectors` 는 top-level `connectors` surface로 canonical redirect 된다

### 4.4. SSE Integration

`sse.ts`의 `useSSE()` hook:
- exponential backoff 재연결 (base 1s, max 15s)
- session ID 생성 (`sessionStorage`)
- signal 기반 이벤트 dispatch (`connected`, `eventCount`, `lastEvent`, `journal`)
- `reconnectCount`, `lastDisconnectedAt` 추적

SSE 이벤트 -> signal store 업데이트 -> 해당 signal을 구독하는 component만 re-render.

Journal: 최대 200개 항목 보관. agent/text/kind/timestamp.

### 4.5. State Management

`@preact/signals` 기반 centralized store (`store.ts`):
- SSE 이벤트와 API 응답이 signal을 업데이트
- `computed` signal로 파생 상태 계산
- component는 signal을 직접 참조하여 fine-grained re-render

도메인별 store 분리:
- `store.ts`: 공통 (agents, tasks, messages, keepers, ...)
- `mission-store.ts`, `mission-signals.ts`: overview briefing + shared mission snapshot
- `namespace-truth-store.ts`: journey / agents / shared namespace truth
- `observatory-store.ts`: observatory graph filters + state
- `command-store.ts`: operations surface
- `keeper-state.ts`, `keeper-store-normalize.ts`: Keeper detail
- `live-store.ts`: Live activity
- `sse-store.ts`: SSE 상태
- `operator-store.ts`: Operator actions/digest
- `pending-confirm.ts`: Pending confirmations

### 4.6. Build Pipeline

```bash
cd dashboard && pnpm run dev    # Vite dev server :5173 (HMR)
cd dashboard && pnpm run build  # Production build -> ../assets/dashboard/
```

Vite 설정:
- `base: '/dashboard/'` (SPA base path)
- `outDir: '../assets/dashboard'` (OCaml 서버가 서빙하는 위치)
- `manualChunks: { vendor: ['preact', 'preact/hooks', 'htm', '@preact/signals'] }`
- Dev proxy: `MASC_DASHBOARD_PROXY_TARGET` -> `/api/*`, `/sse/*` 프록시
- 무토큰 loopback mutation은 기본적으로 `http://localhost:5173`, `http://127.0.0.1:5173`, `http://[::1]:5173`만 허용. 다른 dev origin/port를 쓰면 서버 프로세스에 `MASC_HTTP_DEV_MUTATION_ORIGINS`를 설정

## 5. HTTP API Endpoints

프론트엔드가 호출하는 Backend API 목록:

### Dashboard Projections

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/dashboard/shell` | GET | Overview / runtime shell snapshot |
| `/api/v1/dashboard/namespace-truth` | GET | Journey / agents namespace truth |
| `/api/v1/dashboard/telemetry/summary` | GET | Fleet-health summary read model |
| `/api/v1/dashboard/memory-subsystems` | GET | Memory subsystem health |
| `/api/v1/dashboard/transport-health` | GET | Runtime transport health |
| `/api/v1/dashboard/board` | GET | Workspace board |
| `/api/v1/dashboard/planning` | GET | Planning surface |
| `/api/v1/dashboard/tools` | GET | Tool inventory + usage |
| `/api/v1/dashboard/surface-readiness` | GET | Surface exposure/readiness audit |
| `/api/v1/dashboard/harness-health` | GET | Harness rail health snapshot |
| `/api/v1/dashboard/logs` | GET | System logs |
| `/api/v1/dashboard/repo-synthesis` | GET | Repo synthesis benchmark read model |

Current Dashboard v1 shell also consumes adjacent read models outside the
dashboard prefix:

- `/api/v1/activity/graph`
- `/api/v1/attribution/summary`
- `/api/v1/operator/digest`
- `/api/v1/gate/connectors`
- `/api/v1/verification/requests`
- `/api/v1/verification/summary`
- `/api/v1/autoresearch/loops`

### Resource APIs

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/agents?limit=N` | GET | Agent 목록 |
| `/api/v1/tasks` | GET | Task 목록 |
| `/api/v1/messages` | GET | Message 목록 |
| `/api/v1/agent-activity?hours=N` | GET | Agent 활동 이력 |
| `/api/v1/agent-timeline?agent_name=X` | GET | Agent 타임라인 |
| `/api/v1/agent-relations?agent_name=X` | GET | Agent 관계 (GraphQL proxy) |
| `/api/v1/tool-metrics` | GET | Tool 사용 메트릭 |
| `/api/v1/karma` | GET | Karma 조회 |
| `/api/v1/activity/graph` | GET | Activity graph |
| `/api/v1/attribution/summary` | GET | Attribution gate summary |
| `/api/v1/gate/connectors` | GET | Connectors surface descriptor + live status |
| `/api/v1/verification/requests` | GET | Workspace > 검증 read model |
| `/api/v1/verification/summary` | GET | Verification status bucket summary |
| `/api/v1/autoresearch/loops` | GET | Lab > autoresearch loop list |
| `/api/v1/credits` | GET | Credits JSON |

### Managed Execution and Historical Compatibility Note

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/dashboard/execution` | GET | Historical execution projection (current v1 nav의 primary surface는 아님) |
| `/api/v1/dashboard/mission` | GET | Historical mission projection |
| `/api/v1/dashboard/session?session_id=X` | GET | Mission session detail |
| `/api/v1/dashboard/mission/briefing` | GET | Mission briefing (LLM 생성) |
| `/api/v1/dashboard/proof?session_id=X` | GET | Historical proof projection |
| `/api/v1/dashboard/governance` | GET | Historical governance projection |
| `/api/v1/dashboard/config` | GET | Config introspection snapshot |
| `/api/v1/dashboard/feature-health` | GET | Feature flag health snapshot |
| `/api/v1/chains/summary` | GET | Chain summary |
| `/api/v1/chains/runs/:runId` | GET | Chain run detail |

`/api/v1/command-plane/*` HTTP compatibility lane is retired. Current servers answer those paths with a removed-surface response instead of a live read/write contract.

### Governance

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/governance/params` | GET | Governance runtime parameters |

### Keeper

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/keepers/:name/config` | GET | Keeper config 조회 |
| `/api/v1/keepers/:name/config` | POST | Keeper config 수정 (PATCH semantic) |
| `/api/v1/keepers/chat/stream` | POST | Keeper streaming chat |

`/api/v1/keepers/:name/config` 수정 경로는 기존 keeper만 대상으로 하며, `masc_keeper_up`과 같은 durable 필드 계약을 따른다. `new_*`, `require_existing`, `presence_keepalive*` 같은 legacy field는 허용하지 않는다.

### Operator

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/operator` | GET | Operator snapshot |
| `/api/v1/operator/digest` | GET | Operator digest |
| `/api/v1/operator/action` | POST | Operator action 실행 |
| `/api/v1/operator/confirm` | POST | Pending confirmation 확인 |

### Board

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/board` | GET | Board post 목록 |
| `/api/v1/board/:postId` | GET | Board post detail |
| `/api/v1/board/hearths` | GET | Hearth 목록 |
| `/api/v1/board/flairs` | GET | Flair 목록 |

### MDAL

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/mdal/loops` | GET | MDAL 루프 목록 |

### TRPG

| Endpoint | Method | 용도 |
|----------|--------|------|
| `/api/v1/trpg/events` | GET | TRPG 이벤트 |
| `/api/v1/trpg/state` | GET | TRPG 상태 |

### SSE

| Endpoint | 용도 |
|----------|------|
| `/sse` | Server-Sent Events 스트림 |

### Static Files

| Route | 용도 |
|-------|------|
| `/dashboard` | SPA index.html |
| `/dashboard/assets/*` | Static assets (JS, CSS, images) |
| `/dashboard/credits` | Credits HTML 페이지 (OCaml 렌더링) |

## 6. Configuration

### Environment Variables

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `MASC_ASSETS_ROOT` / `MASC_ASSETS_DIR` | `{exe_dir}/assets` | Static asset 루트 |
| `MASC_DASHBOARD_PROXY_TARGET` | (필수, dev only) | Vite dev server API proxy 대상 |
| `MASC_HTTP_DEV_MUTATION_ORIGINS` | `http://localhost:5173,http://127.0.0.1:5173,http://[::1]:5173` | 무토큰 loopback cross-port mutation을 허용할 dev origin 목록 (comma-separated) |
| `MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED` | `true` | Governance judge daemon 활성화 |
| `MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC` | `60` | Judge 갱신 간격 (최소 15s) |
| `MASC_DASHBOARD_TOOL_CALL_WINDOW_HOURS` | `1.0` | Tool call health window (0.1~168h) |
| `MASC_DASHBOARD_INCLUDE_GOALS` | `false` | Keeper dashboard에 goal 포함 여부 |
| `MASC_KEEPER_HISTORY_FRAGMENT_FILTER` | `true` | Keeper 이력 fragment 필터 활성화 |
| `MASC_DASHBOARD_PROACTIVE_FALLBACK_WARN` | `0.20` | Proactive fallback 경고 임계값 |
| `MASC_DASHBOARD_PROACTIVE_FALLBACK_BAD` | `0.40` | Proactive fallback 위험 임계값 |
| `MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN` | `0.90` | Proactive similarity 경고 임계값 |
| `MASC_DASHBOARD_PROACTIVE_SIMILARITY_BAD` | `0.97` | Proactive similarity 위험 임계값 |
| `MASC_DASHBOARD_ALERT_TOAST_COOLDOWN_SEC` | `300` | Alert toast 재표시 쿨다운 (10~3600s) |

## 7. Invariants

**INV-DASH-001 (Cache SWR)**
`get_or_compute`의 stale-while-revalidate 경로에서 background recompute가 실패하면, stale 값을 복원한다. 에러 JSON으로 덮어쓰지 않는다.

**INV-DASH-002 (Cache ownership)**
`compute` 완료 후 write-back 전에 slot의 `cond`를 physical equality(`==`)로 확인한다. slot이 evict/교체된 경우 write-back을 건너뛴다.

**INV-DASH-003 (Cache mutex scope)**
`Eio.Mutex`는 `Hashtbl` 접근만 보호한다. `compute` 함수는 lock 밖에서 실행되어 서로 다른 key의 nested call이 deadlock 없이 동작한다.

**INV-DASH-004 (Cooldown after eviction)**
Computing slot이 `max_wait_sec`(130s) 초과로 evict되면, 즉시 새 compute를 시작하지 않고 15s cooldown Ready entry를 삽입한다.

**INV-DASH-005 (Render timeout)**
Execution surface 렌더링은 30s 타임아웃으로 보호된다. 초과 시 에러 JSON 반환. PG 연결 실패로 인한 무한 대기를 방지한다.

**INV-DASH-006 (Execution proactive refresh)**
기본 execution 요청(파라미터 없음)은 proactive refresh loop의 캐시 값을 반환한다. 60초 간격으로 사전 계산된다. on-demand 계산은 파라미터가 있는 요청에만 적용된다.

**INV-DASH-007 (Cooperative yield)**
CPU-bound 대시보드 렌더링 구간 사이에 `Eio.Fiber.yield()`를 삽입하여 SSE, health-check 등 다른 fiber가 진행할 수 있게 한다.

**INV-DASH-008 (Executor pool offload)**
CPU-heavy 대시보드 계산은 `Eio.Executor_pool`에 위임한다. PostgresNative 백엔드에서는 domain-local Caqti pool을 생성한다. pool 사용 불가 시 inline fallback.

**INV-DASH-009 (Labels purity)**
`dashboard_labels.ml`은 순수 함수만 포함한다. IO, 부수 효과, 외부 의존성이 없다.

**INV-DASH-010 (Path traversal prevention)**
`is_safe_asset_relative_path`가 `..`, `.`, `\`, null byte를 포함하는 경로를 거부한다.

**INV-DASH-011 (Governance judge allowed tools)**
Judge가 추천하는 `resolved_tool`은 5개 도구 whitelist에서만 허용된다. 목록 외 도구는 `None`으로 대체된다.

**INV-DASH-012 (Keeper parallel I/O)**
`keepers_dashboard_json`은 `Eio.Fiber.all`로 keeper별 metadata + metrics I/O를 병렬 실행한다. 직렬 실행 대비 keeper 수에 비례하여 지연 시간이 감소한다.

**INV-DASH-013 (Metrics cap)**
Keeper metrics는 compact mode에서 120줄, full mode에서 500줄로 cap한다. 이전 12,000줄 설정은 5 keeper 동시 운영 시 60K+ 줄 로드로 성능 저하를 유발했다.

**INV-DASH-014 (SSE auto-reconnect)**
프론트엔드 SSE hook은 연결 끊김 시 exponential backoff(1s~15s)로 자동 재연결한다. reconnect 횟수와 마지막 disconnect 시각을 signal로 추적한다.

**INV-DASH-015 (Session time filter)**
Execution과 Mission surface는 24시간 cutoff으로 session을 필터링한다. 모든 historical session을 로드하지 않고, `since_unix`로 filesystem 수준에서 사전 필터링한다.

## 8. References

| 문서 | 경로 |
|------|------|
| Dashboard quick links | `README.md` |
| Dashboard operator control ADR | `docs/ADR-002-DASHBOARD-OPERATOR-CONTROL-SURFACE.md` |
| Dashboard perf degradation | `memory/masc-dashboard-perf-degradation.md` |
| Dashboard FF-style design direction | `memory/project_masc-dashboard-ff-design-direction.md` |
| Keeper detail redesign | `memory/project_dashboard-keeper-detail-redesign.md` |
| Common pitfalls | `docs/COMMON-PITFALLS.md` |
| Tailwind-only constraint | `memory/feedback_tailwind-only-dashboard.md` |
| Eio proactive refresh pattern | `memory/feedback_eio-proactive-over-ondemand.md` |
