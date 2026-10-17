---
status: reference
---

# 01. System Overview

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)
> Status: Draft
> Last Updated: 2026-10-17

---

## 1. Problem Statement

여러 AI 에이전트(Claude Code, Codex, Antigravity, 로컬 LLM 등)가 동일 코드베이스에서 동시에 작업할 때, 다음 문제가 발생한다:

1. **충돌**: 두 에이전트가 같은 파일을 동시에 수정하면 git conflict가 발생하고, 한쪽 작업이 소실된다.
2. **중복**: 동일한 CI 실패를 여러 에이전트가 독립적으로 수정 시도하면, 중복 PR이 생성된다.
3. **맥락 단절**: 에이전트 A가 만든 변경사항을 에이전트 B가 인지하지 못하면, 잘못된 가정 위에 작업이 쌓인다.
4. **생명주기 불투명**: 어떤 에이전트가 어떤 task를 잡고 있는지, heartbeat가 끊긴 에이전트는 무엇인지 파악할 수단이 없다.
5. **오케스트레이션 부재**: 큰 작업을 여러 에이전트에게 분배하고, 진행 상황을 추적하고, 실패 시 재배정하는 메커니즘이 없다.

MASC는 이 문제들을 MCP(Model Context Protocol) 서버로 해결한다. AI IDE/CLI가 MCP 클라이언트로 연결하면, Workspace에 참여하고, Task를 claim/complete하고, Broadcast로 상태를 공유하고, Heartbeat로 생존을 증명한다.

## 2. Non-Goals

MASC가 명시적으로 **하지 않는 것**:

| Non-Goal | 근거 |
|----------|------|
| Production multi-tenant SaaS | 단일 머신, localhost-trust 모델. 인증/격리/과금 미구현. |
| 범용 오케스트레이션 프레임워크 (Temporal/Airflow 대체) | 대상은 AI 에이전트 협업에 한정. DAG 스케줄링, 재시도 정책, 워커 풀 관리는 범위 밖. |
| 모델 추론 서버 | LLM 호출은 `runtime.toml`과 `packages/agent_core`를 통해 외부 프로바이더(OpenAI, Anthropic, Google/Antigravity, GLM, Kimi, Ollama, llama-server) 및 공식 클라이언트 레인(Claude Code, Codex, Antigravity, Muse Code)으로 위임. 자체 GPU 추론 없음. |
| agent core Agent SDK 대체 | MASC는 `packages/agent_core`에 의존한다. Agent 실행 루프(run, checkpoint, context reduction)는 `agent_core` 책임. MASC는 workspace collaboration 및 Keeper 제품 계층. |
| 범용 채팅/메시징 시스템 | Broadcast와 Board는 에이전트 간 조율 목적. 사람 간 커뮤니케이션 도구가 아님. |

## 3. Deployment Model

```
┌─────────────────────────────────────────────────┐
│                  Single Machine                  │
│                                                  │
│  ┌─────────────┐  ┌──────────┐  ┌─────────────┐  │
│  │ Claude Code │  │ Codex    │  │ Antigravity │  │
│  │ CLI         │  │ CLI      │  │ IDE / CLI   │  │
│  └──────┬──────┘  └────┬─────┘  └──────┬──────┘  │
│         │ MCP          │ MCP           │ MCP     │
│         └──────────────┼───────────────┘         │
│                        │                         │
│              ┌─────────▼────────┐                │
│              │   MASC (:8935)   │                │
│              └─────────┬────────┘                │
│                        │                         │
│              ┌─────────▼────────┐                │
│              │ <base>/.masc/    │                │
│              │ single-root FS   │                │
│              └──────────────────┘                │
└─────────────────────────────────────────────────┘
         │
         │ Cloudflare Tunnel
         ▼
   masc.crying.pictures (remote access)
```

- **Trust model**: localhost 전제. 인증이 활성화된 환경에서는 `.masc/auth/` 자격증명과 역할별 권한(`Worker`/`Admin`/`Player`)을 검사한다.
- **Persistence**: runtime workspace collaboration state는 `<base-path>/.masc/` 단일 루트(`Common.masc_dirname`) 아래 JSONL/JSON 파일시스템을 source of truth로 사용한다 (구 `.masc/clusters/<name>/` 및 `MASC_CLUSTER_NAME` 다중 클러스터 디렉터리는 폐지됨, #43188).
- **Remote access**: Cloudflare Tunnel을 통해 원격 브라우저에서 dashboard 접근 가능. Origin은 HTTP/1.1, Cloudflare가 브라우저에 HTTP/2를 제공.
- **단일 인스턴스**: MASC 서버는 한 workspace base path에 대해 단일 인스턴스로 실행. 수평 확장 미지원.

## 4. Technology Stack

| 영역 | 기술 | 비고 |
|------|------|------|
| Runtime | OCaml 5.x + Eio | Effect-based cooperative concurrency. Stdlib.Mutex 사용 금지 (EDEADLK). |
| HTTP/1.1 | httpun-eio | 기본 transport. Cloudflare Tunnel 호환. |
| HTTP/2 | h2-eio (h2c) | 기본값 `MASC_USE_H2=auto` (H1/H2 자동 감지; `h2_only`는 H2 전용, `0`/`false`/`h1_only`는 H1 전용). |
| TLS | mirage-crypto + tls-eio | 인증서: `SSL_CERT_FILE` 환경변수. |
| JSON | yojson | JSON 파싱/생성. `Yojson.Safe.t` 표준 사용. |
| SQLite | sqlite3 | 로컬 경량 저장 (일부 모듈). |
| Protocol | MCP JSON-RPC | `tools/call`, `tools/list` over SSE + POST (`/mcp`, `/mcp/operator`, `/mcp/managed`, `/mcp/play`). |
| gRPC | grpc-direct (h2-eio) | Agent-to-Agent 통신. proto 정의: `proto/`. |
| AI | `agent_core` (`packages/agent_core`) | Finite `Agent.run`, typed providers, tools, resource-bound wave scheduler, reasoning, multimodal values. |
| Inference | Multi-Provider Runtime (`lib/runtime_model/`, `lib/runtime/`) | `runtime.toml`에 선언된 HTTP API 바인딩 및 공식 CLI 레인(Claude Code, Codex, Antigravity, Muse Code) 순서대로 failover; 할당량 소진 프로바이더는 후보 순서 뒤로 감우선순위화(#43375). |
| Build | dune 3.13+ | `dune-project` 기반. opam package: `masc`. |
| Coverage | bisect_ppx | `BISECT_FILE` 환경변수 필수. |
| Dashboard | Preact + HTM + Vite | TypeScript SPA. `dashboard/` 소스, `assets/dashboard/` 빌드 산출물. |

## 5. Library Structure

MASC는 최상위 public library(`masc`)와 `lib/` 아래의 도메인별 내부 sub-library들(`masc_types`, `masc_workspace`, `masc_keeper`, `masc_server`, `masc_dashboard`, `masc_board`, `masc_runtime` 등), 그리고 인-리포지토리 패키지 `packages/agent_core`로 구성된다.

### 주요 기능별 디렉토리

| Directory | 역할 |
|-----------|------|
| `packages/agent_core/` | 에이전트 실행 루프(`Agent.run`), 프로바이더 어댑터(`Llm_provider`), 도구 스케줄러, 훅, 체크포인트 |
| `lib/keeper/` | Keeper 자율 에이전트 엔진, 장기 실행 레인, 메모리/스킬/합성/격리 잡 도구 |
| `lib/server/` | MCP server, HTTP/1.1 & HTTP/2 transport, SSE, REST 라우트 |
| `lib/dashboard/` | Dashboard 투영, API payload 조립 |
| `lib/workspace/` | Workspace 상태, Task/Backlog 생명주기, 검증 스토어, 단일 루트 `.masc/` 파일시스템 |
| `lib/runtime/`, `lib/runtime_model/` | `runtime.toml` 파서, 프로바이더·레인 바인딩, exact-output 레인 레지스트리 |
| `lib/board/`, `lib/board_types/` | Board 게시물·댓글·투표·SubBoard·첨부 |
| `lib/goal/`, `lib/candle*/` | Goal phase 상태 기계, 측정값, Candle 원장 및 정산 |
| `lib/lane_addon/`, `lib/msx_lane/`, `lib/dos_lane/`, `lib/browser_lane/` | Lane Add-on 호스트, MSX/DOS 공유 머신 레인, Browser 레인 |
| `lib/operator/` | Operator 제어 및 관측 표면 |
| `lib/server/masc_grpc_server.ml`, `lib/server/masc_grpc_service.ml` | gRPC transport (`MascCoord` 서비스) |
| `lib/voice/` | Voice/TTS 브리지 |
| `lib/` (root 및 기타 하위 디렉터리) | Tool dispatch, types, Memory OS, Wiki, Schedule, Fusion 등 |

## 6. Executable Inventory

공개 실행 파일 (`bin/dune`의 `public_name` 기준 20종):

| Executable | Public Name | Entry Point | 역할 |
|------------|-------------|-------------|------|
| `main_eio` | `masc` | `bin/main_eio.ml` | HTTP 서버 및 CLI(`web-search-setup`, `browser-lane-setup` 등). httpun-eio(HTTP/1.1) 및 h2-eio(HTTP/2). Dashboard 서빙, SSE, MCP JSON-RPC, gRPC, REST API. |
| `main_stdio_eio` | `masc-stdio` | `bin/main_stdio_eio.ml` | Stdio 기반 MCP 서버. Claude Code 등 `--mcp` 모드 연동. |
| `masc_cost` | `masc-cost` | `bin/masc_cost.ml` | Token 사용량 집계, 비용 계산 CLI. |
| `masc_trace` | `masc-trace` | `bin/masc_trace.ml` | 실행 트레이스 조회 및 분석 CLI. |
| `masc_tui` | `masc-tui` | `bin/masc_tui.ml` | Terminal UI. Keeper 채팅·상태·보드·머신·설정 인터페이스. |
| `fusion_run` | `masc-fusion-run` | `bin/fusion_run.ml` | 독립 Fusion 패널/심판 실행 CLI. |
| `masc_checkpoint_purge` | `masc-checkpoint-purge` | `bin/masc_checkpoint_purge.ml` | 체크포인트 정리 유틸리티. |
| `masc_exec_shim` | `masc-exec-shim` | `bin/masc_exec_shim.ml` | Keeper 명령 실행 격리 심(shim). |
| `masc_exec_ssh_bootstrap` | `masc-exec-ssh-bootstrap` | `bin/masc_exec_ssh_bootstrap.ml` | `remote_ssh` 샌드박스 부트스트랩 헬퍼. |
| `keeper_capability_probe_cli` | `masc-keeper-capability-probe` | `bin/keeper_capability_probe_cli.ml` | Keeper 런타임 역량 프로브. |
| `masc_lane_cli_probe` | `masc-lane-cli-probe` | `bin/masc_lane_cli_probe.ml` | 공식 CLI 레인 가용성 프로브. |
| `deployment_preflight_helper` | `masc-deployment-preflight-helper` | `bin/deployment_preflight_helper.ml` | 배포 사전 점검 헬퍼. |
| `masc_browser_host` | `masc-browser-host` | `bin/masc_browser_host.ml` | WebDriver BiDi 및 브라우저 호스트 브리지. |
| `masc_reliable_change_g1_check` | `masc-reliable-change-g1-check` | `bin/masc_reliable_change_g1_check.ml` | Reliable Change G1 검증기. |
| `masc_http_probe` | `masc-http-probe` | `bin/masc_http_probe.ml` | HTTP 엔드포인트 상태 프로브. |
| `masc_librarian_replay` | `masc-librarian-replay` | `bin/masc_librarian_replay.ml` | Librarian 메모리 재생 검증기. |
| `masc_librarian_continuity` | `masc-librarian-continuity` | `bin/masc_librarian_continuity.ml` | Librarian 연속성 검증기. |
| `masc_librarian_preflight_eval` | `masc-librarian-preflight-eval` | `bin/masc_librarian_preflight_eval.ml` | Librarian 사전 평가 실행기. |
| `masc_msx_addon_worker` | `masc-msx-addon-worker` | `bin/masc_msx_addon_worker.ml` | MSX 공유 머신 Add-on worker. |
| `masc_dos_addon_worker` | `masc-dos-addon-worker` | `bin/masc_dos_addon_worker.ml` | DOS 공유 머신 Add-on worker. |

내부용 실행 파일 (`public_name` 없음, 빌드 산출물로 직접 실행, 5종):

| Executable | Entry Point | 역할 |
|------------|-------------|------|
| `public_tool_manifest` | `bin/public_tool_manifest.ml` | Tool manifest 생성 |
| `keeper_store_layout_manifest` | `bin/keeper_store_layout_manifest.ml` | Keeper 런타임 저장소 레이아웃 manifest 생성 |
| `gen_board_tool_registry` | `bin/gen_board_tool_registry.ml` | Board 도구 레지스트리 미러 코드 생성 |
| `stagehand_model_probe` | `bin/stagehand_model_probe.ml` | Stagehand 모델 프로브 |
| `masc_tui_keys_doc_cli` | `bin/masc_tui_keys_doc_cli.ml` | TUI 키바인딩 문서 생성/검증 CLI |

## 7. Canonical Front Door and Internal Supporting Substrates

MASC의 현재 canonical front door는 3가지다.

### 7.1 Repo Workspace

가장 기본적인 경로. project scope, task backlog, worktree, heartbeat를 다룬다.

- **대상**: repo-local coding workspace collaboration
- **핵심 도구**: `masc_start`, `masc_status`, `masc_transition`, `masc_plan_set_task`, `masc_heartbeat`
- **설명**: 여러 에이전트가 같은 repo에서 충돌 없이 일하도록 namespace/task/worktree truth를 유지한다.

### 7.2 Keeper Runtime

장기 실행과 연속성을 위한 경로.

- **대상**: keeper lifecycle, long-running execution, agent core-backed autonomy
- **핵심 도구**: `masc_keeper_up`, `masc_keeper_delegate`, `masc_keeper_status`, `masc_keeper_down`
- **설명**: keeper는 agent core `Agent.run` 기반으로 실행된다. 자세한 turn lifecycle은 [`04-turn-lifecycle.md`](./04-turn-lifecycle.md)를 참조.

### 7.3 Dashboard and Operator Read Visibility

운영 상태를 읽고 개입 포인트를 파악하는 read-mostly 경로.

- **대상**: dashboard monitoring, operator digest/action, project snapshot
- **핵심 코드**: `lib/dashboard/`, `lib/server/server_dashboard_http*.ml`, `dashboard/`, `lib/operator/`
- **핵심 surface**: `/api/v1/dashboard/*`, `/api/v1/operator*`, `/api/v1/activity/*`
- **설명**: write-heavy orchestration을 새 front door로 약속하지 않고, 운영자가 현재 runtime truth를 읽고 제한된 개입을 하는 surface다.

## 8. External Integrations

| Service | Location | Protocol | 용도 | 비고 |
|---------|----------|----------|------|------|
| `agent_core` (`packages/agent_core`) | In-process (OCaml library) | Function call | Finite `Agent.run`, typed providers, tools, reasoning, multimodal values | MASC는 Keeper lifecycle과 durable product operation을 소유한다. |
| Cloudflare Tunnel | `masc.crying.pictures` | HTTP -> HTTPS | 원격 dashboard 접근 | Origin HTTP/1.1. Cloudflare가 HTTP/2 변환. |
| Local LLM Runtime (`ollama`, `llama-server`) | configured local endpoint | OpenAI-compatible / Ollama API | 로컬 LLM 추론 및 Standalone exact-output 레인 | `runtime.toml` `[providers.*]` 바인딩. |
| Cloud LLM Providers & Official CLI Lanes | OpenAI, Anthropic, Google/Antigravity, GLM (Z.AI), Kimi, Ollama Cloud | HTTPS / Official CLI subprocess | Keeper turn, Fusion, Verifier/Judge/Librarian 추론 | `[providers.<id>.credentials]` 및 공식 CLI 레인(`claude_code`, `codex_cli`, `antigravity`, `muse_code`). |

## 9. Invariants (System-Level)

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-SYS-001 | Sub-library 의존성은 단방향이다. masc_workspace -> masc_types는 허용되지만, masc_types -> masc_workspace은 금지. | dune dependency graph (`dune describe`). |
| INV-SYS-002 | Eio context 내에서 Stdlib.Mutex를 사용하지 않는다. Eio.Mutex만 허용. | AST structural test + `rg 'Stdlib.Mutex'`. |
| INV-SYS-003 | MCP tool dispatch는 match 패턴을 사용한다. dict/map 라우팅 금지. | Code review. |
| INV-SYS-004 | 모든 외부 LLM 호출은 Runtime를 경유한다. 직접 HTTP 호출 금지. | `rg` for direct curl/HTTP calls to LLM endpoints. |
| INV-SYS-005 | MASC는 모델명을 MASC 레벨에 노출하지 않는다. Runtime가 추상화. | Code review, log audit. |
| INV-SYS-006 | Agent lifecycle (run, checkpoint, context reduction)은 agent core Agent SDK에 위임한다. MASC에서 재구현 금지. | Architecture review. |

## 10. Open Questions

| ID | 질문 | 관련 코드 | 상태 |
|----|------|----------|------|
| OQ-SYS-001 | Sub-library 경계를 어디까지 세분화할 것인가? | `lib/keeper/`, `lib/server/` | Open |
| OQ-SYS-002 | HTTP/2 h2c를 기본 transport로 전환할 시점은? Cloudflare Tunnel이 cleartext h2를 지원하지 않는 제약. | `bin/main_eio.ml` | Open |
| OQ-SYS-003 | MASC와 `packages/agent_core` 사이의 장기 경계는 어떻게 유지할 것인가? | `packages/agent_core/`, `lib/keeper/` | Open |
| OQ-SYS-004 | Multi-protocol transport(SSE/gRPC/WebSocket) 중 어디를 canonical으로 수렴할 것인가? | `lib/grpc/`, `lib/server/` | Open |
