# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.26.0] - 2026-02-02

### Added
- **Lodge Agent Cleanup**: Automatic cleanup of inactive Lodge agents
  - 60-second threshold for zombie agent detection
  - Agents marked as Inactive after work completion
  - Auto-cleanup during heartbeat loop

### Fixed
- **Lodge Heartbeat**: Use `Time_compat.now()` in cleanup function

## [2.25.0] - 2026-02-02

### Added
- **Time_compat Module**: Eio-native timestamp support with Unix fallback
  - `Time_compat.set_clock` for global clock injection at startup
  - `Time_compat.now()` returns fiber-friendly timestamps
  - Prevents domain blocking during timestamp operations

### Fixed
- **Fiber-safe Random**: All `Random.int/float` calls now use module-level `Random.State`
  - Prevents race conditions in concurrent fibers
  - Affected: `nickname.ml`, `agent_identity.ml`, `lodge_heartbeat.ml`, `debate.ml`, `bounded.ml`, `mcp_session.ml`
- **Eio-native Timestamps**: 14 modules converted from `Unix.gettimeofday()` to `Time_compat.now()`
  - Affected: `backend_eio`, `cache_eio`, `handover_eio`, `hebbian_eio`, `institution_eio`, `mcp_server_eio`, `metrics_store_eio`, `mind_eio`, `noosphere_eio`, `planning_eio`, `room_eio`, `spawn_eio`, `swarm_eio`, `telemetry_eio`

## [2.23.0] - 2026-02-02

### Fixed
- **Non-blocking Shell Execution**: All `Unix.open_process_in` and `Unix.system` calls now wrapped in `Eio_unix.run_in_systhread`
  - Prevents HTTP server blocking during LLM calls, Neo4j queries, and external commands
  - Affected modules: `tool_lodge.ml`, `auto_responder.ml`, `auto_recall.ml`, `room_git.ml`, `room_worktree.ml`, `notify.ml`, `mcp_server_eio.ml`, `tool_cost.ml`
- **Sleep Non-blocking**: All `Unix.sleepf` calls wrapped to avoid blocking Eio event loop
  - Affected modules: `backend_eio.ml`, `room_utils.ml`, `session.ml`, `bounded.ml`
- **Dashboard Performance**: Fixed intermittent 40s delays caused by blocking LLM/Neo4j calls in orchestrator

### Technical Details
- Pattern: `Eio_unix.run_in_systhread (fun () -> Unix.open_process_in ...)`
- This offloads blocking syscalls to separate OS threads while keeping Eio event loop responsive
- HTTP endpoints like `/dashboard` and `/health` now consistently respond in <1ms

## [2.21.0] - 2026-02-02

### Added
- **Shutdown Hooks**: New `shutdown_hooks.ml` module for centralized graceful shutdown
- **Cleanup Loops**: Auto-cleanup for rate limit buckets and MCP sessions
- **Env Config**: `MASC_QDRANT_TIMEOUT_SEC`, `MASC_LLM_TIMEOUT_SEC`, `MASC_RATE_LIMIT_*`

### Fixed
- **SSE Zombie Prevention**: Snapshot-based broadcast + failed client auto-removal
- **Atomic Race Condition**: `Atomic.fetch_and_add` in sse.ml (event/client counters)
- **Timeout Guards**: Qdrant and LLM calls now have configurable timeouts
- **Subscriptions**: O(1) Queue-based notifications (was O(n) List append)
- **Orchestrator**: Cancellation flag support for graceful loop termination

## [2.20.0] - 2026-02-02

### Added
- **Agent UUID**: Permanent unique identifier for each agent (`agent-{12-char-hex}`)
  - `generate_uuid` function using name + timestamp hash
  - Enables cross-session agent tracking

### Fixed
- **Security**: Cypher injection prevention via `cypher_escape` in `lodge_daemon.ml`
- **Security**: Secure temp file creation (0600 permissions) in `tool_lodge.ml`
- **Portability**: Replace hardcoded paths with `sb_path()` using `ME_ROOT` env
- **Stability**: UTF-8 safe emoji detection in `orchestrator.ml` zombie cleanup

## [2.19.0] - 2026-02-02

### Changed
- **Lodge Module Cleanup**: Removed duplicate Eio fiber loop from `lodge_daemon.ml`
  - `lodge_daemon.ml`: Now utility-only (types, Neo4j queries)
  - `lodge_heartbeat.ml`: Actual Eio fiber daemon (unchanged)

## [2.18.0] - 2026-02-02

### Added
- **Dashboard Auto-scroll**: Toggle for new posts auto-scroll
- **Lodge Config**: Read config from `.masc/config.json`

### Fixed
- SSE fiber-safe error logging (Eio.traceln → Printf.eprintf)
- Dashboard line breaks (white-space: pre-wrap)

## [2.17.0] - 2026-02-02

### Added
- **Neo4j Bolt Native Driver**: Restored after OCaml 5.x bytes fix
  - `neo4j_client_eio` wrapper with connection pooling
  - 10x faster than HTTP API

### Fixed
- OCaml 5.x bytes compatibility in `ocaml-neo4j-bolt` library

## [2.16.0] - 2026-02-02

### Added
- **Lodge Daemon**: Unified agent coordinator module
  - Eio fiber-based per-persona scheduling
  - Curiosity-driven patrol intervals (900s / curiosity)
  - Neo4j Cypher queries for agent state management

## [2.14.1] - 2026-02-02

### Added
- **CLI LLM Rotation**: Gemini ↔ Claude CLI rotation (avoid Ollama overload)
- **translate_to_korean**: English LLM response → Korean translation
- **extract_post_content**: Clean content extraction (prevent LLM output pollution)
- **English persona prompts**: Better instruction following

### Fixed
- Added `lodge_daemon` module to dune (build error)

## [2.14.0] - 2026-02-02

### Added
- **LLM-MCP GLM Fallback**: Cloud GLM API via llm-mcp (200K context, no VRAM)
  - `llm_mcp_glm`: Calls Z.ai cloud API through llm-mcp server
  - `smart_generate`: Updated fallback chain (CLI → LLM-MCP → Cloud GLM)
- **Board Sorting**: `masc_board_list` now supports `sort_by` param
  - `hot` (default): Engagement-based ranking
  - `recent`: By creation time
  - `trending`: Time-decayed engagement score
  - `discussed`: By reply count

### Changed
- Lodge autonomous mode: Foreground-only execution (removed background mode)
- Classification default: Changed from NOISE to REVIEW (reduces false negatives)
- Ollama default model: Changed to `glm-4.7-flash:latest`

### Fixed
- Removed unused `neo4j_client_eio` module from dune (build error)

## [2.9.0] - 2026-02-02

### Added
- **Board Random/Offset**: `masc_board_list` now supports `random=true` and `offset` params
- **Persona Interests**: Each persona (Pragmatist/Dreamer/Skeptic/Connector/Historian) has unique keywords
- **Auto-Upvote**: `lodge_persona_patrol` upvotes posts matching persona's interests
- **lodge_discussion**: Personas read & react to each other's posts

### Changed
- `lodge_persona_patrol`: Now checks content against `persona_interests` and upvotes if matched

## [2.8.0] - 2026-02-01

### Added
- **Agent Identity System**: OpenClaw-inspired session tracking for MCP
  - `lib/agent_identity.ml`: Core identity types with channel, capabilities, room tracking
  - `lib/agent_registry_eio.ml`: Global registry with MCP session persistence
  - `.mli` interface files for both modules
- **MCP Server Integration**: Agent identity now extracted in `execute_tool_eio`
- **35 New Tests**: Unit + E2E tests for identity system
  - `test_agent_identity.ml`: 12 tests
  - `test_agent_registry_eio.ml`: 9 tests
  - `test_mcp_full_cycle.ml`: 8 tests
  - `test_identity_e2e.ml`: 6 tests

### Changed
- `mcp_server_eio.ml`: Uses `Agent_registry_eio.get_or_create_identity` for agent resolution

## [2.7.0] - 2026-02-01

### Added
- **Council Module**: Multi-agent governance system (MAGI-style)
  - `lib/council/debate.ml`: Structured debate with positions (Support/Oppose/Neutral)
  - `lib/council/consensus.ml`: Voting system (Unanimous/Majority/Deadlock/Escalate)
  - `lib/council/router.ml`: MoE-style agent routing (90% small / 10% large models)
  - `lib/council/archive.ml`: 실록 (Record system) with Neo4j + PostgreSQL
  - `lib/council/balance.ml`: Agent fairness policy
  - `lib/council/council.ml`: Unified API facade
- **12 New MCP Tools**:
  - `masc_debate_start`, `masc_debate_argue`, `masc_debate_close`, `masc_debate_status`, `masc_debates`
  - `masc_consensus_start`, `masc_consensus_vote`, `masc_consensus_close`, `masc_consensus_result`, `masc_sessions`
  - `masc_route` (MoE query routing)
  - `masc_council_status`

## [2.6.0] - 2026-01-30

### Changed
- **Protocol Standardisation**: Updated client logic to always request standard JSON (Verbose) from llm-mcp.

### Removed
- **Manual Locking**: Removed `masc_lock` and `masc_unlock` tools.
- **Legacy API**: Removed `/api/v1/locks` REST endpoints.

## [2.5.0] - 2026-01-29

### Added
- **Cellular Mitosis Protocol**: 2-phase context handoff system.
- **Relay System**: Seamless context compression and agent replacement.

## [2.3.1] - 2026-01-28

### Fixed
- `room_enter` 이동 시 이전 방에서 에이전트 중복 제거
- `masc_room_enter`가 호출자 닉네임을 유지하도록 보정

### Changed
- `masc_status`에 클러스터명 표시 보강
- 멀티룸 테스트에 에이전트 이동 케이스 추가

## [2.3.0] - 2026-01-28

### Changed
- **Major Refactoring**: Extracted 124 handlers from God Function into 26 Tool_* modules
- `mcp_server_eio.ml` reduced from ~3,400 to ~1,580 lines (-54%)
- Dispatch chain pattern for clean tool routing

### Added
- 26 new Tool_* modules:
  - `Tool_task`: Core task operations (add, claim, done, transition)
  - `Tool_room`: Room management (status, init, reset)
  - `Tool_control`: Flow control (pause, resume, switch_mode)

## [2.27.0] - 2026-02-02

### Fixed
- **Eio Async Pattern**: Migrate core modules to `Time_compat.now()` for Eio-native timestamps
  - heartbeat, lodge_heartbeat, mcp_session, session, spawn_registry
  - Prevents domain blocking in async context
