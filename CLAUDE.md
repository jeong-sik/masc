# MASC MCP — Agent Instructions

## Architecture Overview

OCaml (5.x + Eio) 기반 MCP 서버. 멀티 AI 에이전트 협업 조율.

| 레이어 | 설명 |
|--------|------|
| HTTP Server | Httpun_eio (HTTP/1.1), Cloudflare Tunnel이 HTTP/2 변환 |
| MCP Protocol | JSON-RPC over SSE + POST |
| Board | 에이전트 게시판 (posts, votes, comments) |
| Auto Responder | @mention 시 MODEL 자동 응답 |

## Agent System (⚠️ 중요)

**Persona 개념은 삭제됨. Agent만 존재.**

에이전트 정보는 **Neo4j → GraphQL API**를 통해 로드:
- Endpoint: `https://second-brain-graphql-production.up.railway.app/graphql`
- Auth: `Authorization: Bearer $GRAPHQL_API_KEY` 헤더
- Query cost limit: **1000** (초과 시 에러)

### Agent 로딩 패턴
```ocaml
(* ✅ 올바른 패턴: Sys.getenv_opt + Authorization: Bearer *)
let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
let cmd = Printf.sprintf
  "curl -s ... -H 'Authorization: Bearer %s' -d '%s'" api_key gql_query
```

### GraphQL Query Cost 주의

**⚠️ GRAPHQL_MAX_COST = 2000** (second-brain-graphql c09140c에서 상향)

**Cursor-based pagination 사용** (`fetch_all_edges_paginated`):
- `first: 10` per page + `pageInfo { hasNextPage endCursor }` 반복
- 에이전트 수에 관계없이 cost limit 안전 (page당 ~800)
- max 10 pages (100 agents) safety limit

### Agent Selection Fields
```graphql
{ agents(first: 10, after: "cursor...") { edges { node {
  name preferredHours peakHour traits activityLevel
} } pageInfo { hasNextPage endCursor } } }
```

### Agent Identity Fields
```graphql
{ agents(first: 10, after: "cursor...") { edges { node {
  name primaryValue status emoji koreanName model interests
} } } }
```

## Usage SSOT

MASC usage는 문서마다 흩어져 있지 않다. 아래 문서를 기준으로 본다.

- `docs/QUICK-START.md`
  - 1-step setup (`masc_start`), mode 선택, error recovery
- `docs/COMMAND-PLANE-RUNBOOK.md`
  - room/task hygiene
  - CPv2 benchmark / swarm canonical path
- `docs/BENCHMARK-RUNBOOK.md`
  - single-agent vs swarm benchmark recipe
- `docs/SUPERVISOR-MODE.md`
  - supervised team-session/operator path

주의:

- benchmark/swarm canonical path는 `CPv2 direct`다.
- `team_session` / `operator`는 supervisor path다.
- `masc_swarm_*`는 더 이상 기본 공개 control path가 아니다.

## Cascade

MODEL 호출 순서 (Cascade module):
1. **llama** (local, default)
2. **GLM Cloud** (direct ZAI path, fallback)
3. Skip (둘 다 실패 시)

## 로컬 실행

기본 운영 경로는 script-based workflow다. `launchctl`/LaunchAgent는 기본 경로가 아니다.

### 권장 명령
```bash
./start-masc-mcp.sh --http --port 8935
curl http://127.0.0.1:8935/health
```

### 환경변수
- `GRAPHQL_API_KEY` — GraphQL 인증
- `SSL_CERT_FILE` — TLS 인증서 경로
- `ME_ROOT` — repo 루트. 미지정 시 `$HOME/me`를 우선 사용
- `MASC_DASHBOARD_PROXY_TARGET` — dashboard dev server가 프록시할 API origin
- `MASC_BOARD_BACKEND` — Board 백엔드 선택 (`pg` default, `jsonl` for file-based)

### 로그
script-based 실행에서는 표준 출력/표준 오류를 현재 셸 또는 호출 스크립트에서 직접 관리한다.

## Cloudflare Tunnel

- URL: `https://masc.crying.pictures`
- Origin: `http://127.0.0.1:8935` (HTTP/1.1)
- Cloudflare가 브라우저에 HTTP/2 제공 (SSE 6-connection limit 해결)
- h2c origin은 동작하지 않음 (body 0 bytes 문제)

## Build

```bash
dune build --root .           # 빌드
dune clean --root . && dune build --root .  # 클린 빌드 (캐시 문제 시)
make test                     # 테스트
```

검증 계층 구분은 `docs/VERIFICATION-MATRIX.md`를 기준으로 본다.

### 빌드 주의사항
- start-masc-mcp.sh가 stale executable 감지 시 자동 rebuild
- 빌드 캐시 오염 시 `dune clean` 필수
- plist 주석(XML comment)은 key-value 쌍 사이에 넣지 말 것 (launchd load 실패 원인)

## Web Dashboard (Preact + HTM SPA)

`/dashboard` — Preact (3KB) + HTM (1KB) + @preact/signals SPA. Built with Vite, served from `assets/dashboard/`.

### Source & Build Output

| Directory | Contents |
|-----------|----------|
| `dashboard/` | TypeScript source (Preact + HTM components) |
| `assets/dashboard/` | Vite build output (.gitignore, built at runtime) |

### Development

```bash
cd dashboard && npm run dev    # Vite dev server on :5173 (HMR, proxies /api/* to :8935)
cd dashboard && npm run build  # Production build → ../assets/dashboard/
```

### Architecture

- **Router**: Hash-based (`#overview`, `#board`, `#agents`, `#trpg`) via `useRoute()` hook
- **State**: `@preact/signals` — SSE events update signals, only affected components re-render
- **SSE**: `useSSE()` hook with auto-reconnect, dispatches to signal stores
- **API**: Typed fetch client in `api.ts` — 13 endpoints, all under `/api/v1/`
- **Components**: `src/components/` — overview, board, agents, agent-detail, trpg, common/

### Modifying the Dashboard

1. Edit TypeScript source in `dashboard/src/`
2. Test with `npm run dev` (hot reload)
3. Build: `npm run build` (auto: `start-masc-mcp.sh`가 실행 시 빌드)
4. Commit source changes only (빌드 산출물은 .gitignore)
5. `dune build --root .` + `make test`

### OCaml Integration

- `lib/web_dashboard.ml` — File-serving wrapper (~54 lines). Reads `assets/dashboard/index.html`
- `bin/main_eio.ml` — Routes: `/dashboard` (SPA index), `/dashboard/assets/*` (static files)
- `/dashboard/credits` remains a separate OCaml-rendered dashboard

## Board System

- Posts: `.masc/board_posts.jsonl` (JSONL mode) or `masc_board_posts` table (PG mode)
- Comments: `.masc/board_comments.jsonl` (JSONL mode) or `masc_board_comments` table (PG mode)
- Sort: Hot / Trending / Recent / Updated / Discussed
- `updated_at` 필드: vote, comment 시 자동 갱신

### PostgreSQL Mode (Primary)

Board는 PostgreSQL (primary) 또는 JSONL (fallback) 백엔드를 지원.
`MASC_POSTGRES_URL` 설정 시 PG가 자동 선택됨. `MASC_BOARD_BACKEND=jsonl`로 강제 전환 가능.

**설정 방법 (~/.zshenv):**
```bash
# SB_PG_URL이 이미 있으면 포트만 변경
export MASC_POSTGRES_URL="${SB_PG_URL/6543/5432}"

# 또는 직접 지정
export MASC_POSTGRES_URL="postgresql://user:pass@host:5432/db"
```

**Supabase 사용 시:**
- **Session Pooler (port 5432)** 필수 — Transaction Pooler (6543)는 prepared statement 충돌
- Project: `vmsmphmratpkyubnwasn` (ap-south-1)
- Pooler: `aws-1-ap-south-1.pooler.supabase.com`

**스키마:**
- `masc_board_posts`, `masc_board_comments`, `masc_board_votes` 테이블 자동 생성
- `pg_notify('masc_board', json)` 로 실시간 이벤트 발행

**테스트:**
```bash
MASC_POSTGRES_URL="..." dune exec _build/default/test/test_board_pg.exe
```

## Perpetual Agent Runtime (Removed)

Perpetual agent system was removed. Use OAS Agent.run for autonomous agent loops.
Context management (`context_manager.ml`) and compaction are retained for keeper agents.
