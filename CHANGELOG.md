# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.68.0] - 2026-02-16

### Added
- **TRPG Actor Lease Protocol** — Actor spawn/claim/release lifecycle with lease management (#173)
- **Social Board Interactions** — Vote and comment support for Viewer Lodge Social Board (#172)
- **GLM Cloud Load Balancer** — Multi-model load balancer pool for GLM Cloud LLM provider (#170)
- **TRPG Fast Keeper Cascade** — Fast keeper routing with new game flow bootstrap (#169)
- **TRPG Dashboard Actions** — Guide dashboard with next-action flow for session management (#166)
- **TRPG Unique Keeper Routing** — Enforce unique keeper routing and session visibility (#165)
- **Viewer Oil Painting Assets** — Regenerated assets with oil painting aesthetic (#164)

### Changed
- **Result Types Migration** — Replace `failwith` with `Result` types for safer error handling (#163)
- **TRPG/Viewer UX** — Fast keeper routing, clean session lifecycle, debug toggle (#171)

### Fixed
- LLM client now distinguishes curl timeout (exit 28) from empty API response, with connection-refused detection (#174)
- Viewer narrative stream rendered as text-only to prevent HTML injection (#168)
- Viewer TRPG DOM panel bindings restored after refactor (#167)
- TRPG round-run UX hardened with language flow improvements (#162)
- Viewer trunk build restored by fixing ui module and wasm feature flags

## [2.67.0] - 2026-02-16

### Added
- **Pulse Tick Engine** — Generic heartbeat abstraction for timer-based subsystems
  - `pulse.ml`: Core engine using `Eio.Stream` for nudge signaling, `Eio.Promise` for graceful shutdown
  - `Pulse.Consumer` module type: First-class modules with `name`, `should_act`, `on_beat` callbacks
  - Rhythm types: Fixed interval, quiet hours support, interval clamping (min/max bounds)
  - Lifecycle: `Perpetual` (auto-restart on error) or `Oneshot`
  - 20+ tests covering quiet hours, nudge coalescing, consumer error isolation

### Changed
- **Orchestrator → Pulse migration**: Replaced ad-hoc timer loop with dual Pulse engines (orchestrator 300s, zombie cleanup 60s)
- **Lodge → Pulse migration**: Main tick loop now uses Pulse with configurable rhythm
- **Guardian → Pulse migration**: All 3 timer loops (spawn, retire, health check) consolidated to Pulse

### Fixed
- TRPG round run unblocked by handling MCP SSE responses with proper timeout propagation

## [2.66.0] - 2026-02-14

### Added
- **TRPG Dashboard MCP**: Bootstrap endpoint for TRPG session management with CORS header deduplication
- **Viewer Lodge Social Board**: HTTP polling-based social feed with posts, votes, comments
- **Viewer Weather/Mood Overlay**: Atmospheric effects system with prop notifications
- **TRPG Scenario System**: 4 scenario templates, world presets, session bootstrap with presets + interventions

### Fixed
- CORS headers for TRPG API responses
- Viewer NO_COLOR normalization for trunk runner

## [2.65.0] - 2026-02-13

### Added
- Keeper dashboard: expose bounded `metrics_series` time-series (context ratio/tokens + handoff markers) via `/api/v1/dashboard`.
- Web dashboard: show keeper context sparkline + handoff threshold + ETA-to-handoff (turns).

### Changed
- Keeper "handoff-soon" indicator now respects per-keeper `handoff_threshold` (warns at 95% of threshold).

## [2.64.0] - 2026-02-13

### Added
- Keeper prompt customization: `masc_keeper_up` / `masc_keeper_msg` now accept `instructions` (persisted) and `new_instructions` (update).

### Changed
- Compaction prefers structured continuity snapshots (`[STATE] ... [/STATE]`) and emits summaries as assistant messages (prevents Claude system prompt pollution).
- Succession hydration preserves the previous system prompt (keeper/perpetual constitution + custom instructions) across handoffs.
- Keeper + Perpetual default system prompts include a continuity constitution and a stable `[STATE]` template for compaction/handoff.

### Fixed
- Keeper auto-handoff now stamps the successor DNA with the new `trace_id` and next `generation` before hydration/checkpointing.

## [2.61.0] - 2026-02-06

### Added
- **Perpetual Agent Runtime** — Infinite context system for 24h+ autonomous agent operation
  - `llm_client.ml`: Vendor-agnostic LLM caller (Ollama, Claude, Gemini, GLM Cloud, OpenRouter) with cascade fallback
  - `context_manager.ml`: 3-tier memory (working → session → semantic) with 4 compaction strategies
  - `verifier.ml`: Low-cost model action verification (PASS/WARN/FAIL)
  - `succession.ml`: Cross-model DNA extraction, hydration, and generation tracking
  - `perpetual_loop.ml`: Autonomous loop (think → act → observe → verify → compact → heartbeat → loop/handoff)
  - `tool_perpetual.ml`: 4 MCP tools (`masc_perpetual_start`, `masc_perpetual_status`, `masc_perpetual_stop`, `masc_perpetual_inject`)
  - `bin/perpetual_cli.exe`: Standalone CLI for running agents outside MCP
  - 3-threshold context management: compact (50%), prepare (70%), handoff (85%)
  - Idle detection with configurable max consecutive idle turns
  - 92 tests

## [2.60.0] - 2026-02-06

### Added
- **AG-UI Protocol Bridge** (`ag_ui.ml`): CopilotKit AG-UI event translation layer
  - 14 event types (lifecycle, text, tool, state, custom)
  - MASC→AG-UI event mapping for all core event types
  - `/ag-ui/events` SSE endpoint with room filtering and missed-event replay
  - 18 tests
- **Context Router** (`context_router.ml`): Pre-retrieval decision gate for selective RAG
  - 3-tier routing: Skip (no retrieval), Light (reduced budget), Full (all sources)
  - 5 query intent types: Conversational, Task_command, Status_check, Knowledge_query, Coordination
  - State-aware broadcast overlap check (60% keyword threshold)
  - 25 tests
- **Capability Match** (`capability_match.ml`): Task-Agent compatibility scoring
  - Scoring: `trait_overlap * 0.4 + interest_overlap * 0.4 + capability_match * 0.2`
  - Keyword extraction with stop-word filtering and substring matching
  - `rank_agents_for_task`, `rank_tasks_for_agent`, `best_agent_for_task`, `suggest_task_for_agent`
  - JSON serialization for agent profiles and match scores
  - 24 tests
- **AGENTS.md**: Agent capability declaration file (OpenAI→AAIF standard)
- **Lodge Memory GC** (`lodge_memory_gc.ml`): Stale memory cleanup (AgeMem pattern)
- **Library Bridge** (`library_bridge.ml`): Lodge Heartbeat ↔ Library auto-recording

### Changed
- **A2A v0.3 Agent Card**: Added `A2A-Version` HTTP header to `/.well-known/agent-card.json`
- **HTTP Server**: `Response.json` now accepts `~extra_headers` parameter
- **Lodge Cascade**: Added routing strategy support (cost_optimized, latency_optimized, quality_first)
- **Task Metrics**: `masc_done` records completion time for ProceduralPattern trustScore feedback

## [2.59.0] - 2026-02-06

### Added
- **Agent Knowledge Library**: Personal knowledge base at `~/me/docs/library/`
  - `masc_library_list`, `masc_library_read`, `masc_library_add`, `masc_library_search`
  - YAML frontmatter with confidence scores
  - Candidates promotion flow (`masc_library_promote`)

### Changed
- **Remove llm-mcp dependency** (#78): Direct API calls replace llm-mcp proxy
  - `Llm_direct.dispatch` for Z.ai GLM, Ollama, Claude CLI
  - `llm_client_eio.ml` deprecated (kept for backward compatibility)
  - `Endpoints.llm_mcp_url` deprecated, scheduled for v3.0 removal

## [2.58.0] - 2026-02-05

### Added
- **Gardener Agent**: Self-Organizing Agent Ecosystem Manager
  - Homeostatic balance (min=5, target=15, max=30 agents)
  - Gap signal processing for spawn decisions
  - Retirement management with grace periods
  - Circuit breaker, daily budgets, cooldowns
  - 7 MCP tools: `masc_gardener_health`, `masc_gardener_config`, `masc_gardener_propose_spawn`, etc.
  - 62 tests covering all safety mechanisms

## [2.57.0] - 2026-02-05

### Added
- **A2A Worker Pattern**: Delegated LLM calls for Soul + Body architecture
  - `MASC_DELEGATE_LLM=true` emits `heartbeat_task` events
  - Workers subscribe and invoke local LLM (Ollama)

## [2.56.3] - 2026-02-05

### Fixed
- **Lodge GraphQL**: Add curl fallback for Railway DNS issues
- **Task Backend**: Integrate Task_dispatch with PostgreSQL backend

## [2.56.2] - 2026-02-05

### Fixed
- **SSE Client Leak**: Prevent client count leak on connection close

## [2.56.1] - 2026-02-05

### Changed
- **Error Standardization**: Comprehensive error types across modules
- **Lodge GraphQL**: Configurable URL for Railway internal networking
- **Lodge HTTPS**: Conditional HTTPS connector for HTTP URLs

## [2.55.3] - 2026-02-05

### Fixed
- **Agent State Persistence**: Fix HTTP state loss on Railway (PostgreSQL mode)
  - `is_pg_backend` helper to detect PostgresNative backend
  - `join`: persist agent to `masc_kv` table for PostgreSQL mode
  - `leave`: delete from `masc_kv` for PostgreSQL mode
  - `is_agent_joined`: check `masc_kv` first for PostgreSQL mode
  - FileSystem/Memory backends unchanged (no test breakage)
- **Lodge Cache Filter**: Remove chicken-egg bug in agent loading

## [2.55.2] - 2026-02-05

### Fixed
- **Lodge Initialization**: Defer agent loading until Eio net is initialized
  - Fixes "Eio net not initialized" error on Railway deployment
  - `load_agents_config()` → explicit `Tool_lodge.init()` called after `set_net`

## [2.55.1] - 2026-02-05

### Fixed
- **Railway Deploy**: Use shell to expand PORT env variable
- **cohttp-eio**: Pin to < 6.2 for API compatibility

### Added
- **PostgreSQL Backend**: Default board backend with pg_notify
- **Board Listener**: pg_notify → SSE bridge for real-time updates

## [2.55.0] - 2026-02-05

### Added
- **Lodge Emergent Identity v2.0**: Agent identity emerges from reaction history
  - Trait Fade: Static traits fade to 0% after 50 reactions
  - Confidence Calibration: Track predicted vs actual outcomes
  - Temporal Decay: 10-day half-life for reaction weights
  - Dynamic Thresholds: Adjust based on calibration error
  - Cosine Similarity: Affinity-aware agent comparison (replaces Jaccard)
  - Theory of Mind: Predict other agents' reactions (`lodge_tom.ml`)
- **fs_compat module**: Eio-native filesystem I/O with Unix fallback
  - `Fs_compat.load_file`, `save_file`, `append_file`
  - `Fs_compat.load_jsonl`, `append_jsonl` (JSONL helpers)

### Changed
- **lodge_reaction.ml**: Migrated from blocking Unix I/O to Eio-native
  - `Unix.gettimeofday` → `Time_compat.now`
  - `open_in`/`open_out` → `Fs_compat.*`

### Documentation
- `docs/lodge-identity-v2/ARCHITECTURE.md`
- `docs/lodge-identity-v2/RESEARCH.md`
- `docs/lodge-identity-v2/ROADMAP.md`

## [2.48.0] - 2026-02-03

### Added
- **Agent Trace**: Prompt tuning visibility — trace LLM calls with inputs/outputs
- **Thompson Sampling**: Bandit-based agent selection for Lodge heartbeat
  - Exploit/explore balance via Beta distribution
  - Stats persist per cluster (`base_path/lodge_agent_stats.json`)
- **Permanent Posts**: `ttl=0` creates posts that never expire
  - Sweeper skips `expires_at = 0.0` entries
  - `max_posts` (10,000) limit still enforced

### Changed
- **Process Execution**: `run_argv_with_status` for structured command execution
  - Unix fallback for test environment compatibility
- **Dashboard Activity Tab**: Parse agent activity lines with visual styling
  - `hideSystemPosts` default: true (less noise)

### Fixed
- **Heartbeat Context**: Inject current date + knowledge cutoff to prevent temporal confusion
- **Lodge Stats Path**: Use cluster `base_path` instead of hardcoded path

## [2.47.0] - 2026-02-03

### Added
- **Library Resource**: `masc://library` for curated first-party knowledge
  - YAML frontmatter parsing (title, source, verified_by, date, tags)
  - Index: `masc://library` (markdown) / `masc://library.json` (JSON)
  - Topic: `masc://library/{topic}` for individual documents
  - Location: `~/me/docs/library/*.md`
  - Seed document: `ocaml-eio-patterns.md`

## [2.45.0] - 2026-02-03

### Changed
- **Eio-native process execution**: Replace `run_in_systhread` / `run_in_systhread_with_status` with `Process_eio.run` / `run_with_status` using global `proc_mgr`/`clock` refs
  - `lodge_heartbeat`, `tool_lodge`, `auto_responder`, `lodge_memory`, `llm_direct` migrated
  - Sleep calls in `tool_lodge` migrated from `Eio_unix.run_in_systhread (Unix.sleepf)` to `Eio.Time.sleep`
  - Removed: `read_fd_with_timeout`, `reap_child`, `run_in_systhread`, `run_in_systhread_with_status` (~90 lines)
  - `Process_eio.init ~proc_mgr ~clock` called from `main_eio.ml` at startup

### Fixed
- **Lodge Memory**: Migrate from raw Cypher to GraphQL API
- **Board persistence**: Add `updated_at` to `post_to_yojson` (was missing, caused data loss on rewrite)
- **Board helpers**: Extract `append_post`/`append_comment` from inline JSON construction (DRY)
- **Deferred flush dedup**: `deferred_flush_fn := flush_dirty` instead of duplicating logic
- **I/O error logging**: `Sys_error _ -> ()` → `Printf.eprintf "[Board] ..."` (5 call sites)
- **Shuffle bias**: Replace `List.sort (fun _ _ -> Random.int 3 - 1)` with random-key sort
- **Limit validation**: Clamp `limit` param to `[1, 100]` in `handle_post_list`/`handle_search`
- **Search pool**: Load `max limit 100` posts for search filtering

## [2.35.0] - 2026-02-03

### Fixed
- **CLAUDE.md Auth Pattern**: `X-API-Key` → `Authorization: Bearer` (코드와 문서 동기화)
- **UTF-8 Truncation**: `utf8_truncate` 함수 추가 — 한국어 3바이트 문자 중간 절단 방지
- **LLM Cascade**: Ollama(qwen3 thinking mode 버그) → GLM-4.7 Cloud로 교체
- **Response Parser**: `ACTION:` 키워드를 줄 시작뿐 아니라 어디서든 탐색
- **GraphQL Auth**: 셸 `source ~/.zshenv` 의존 제거 → `Sys.getenv_opt` 직접 사용
- **Buffer Truncation**: `run_shell_line` 버퍼 500→4000, 개행 보존

### Changed
- **Terminology**: `persona` → `agent` 전체 코드베이스 리네이밍 (20개 파일)
- **Banned Words**: 15개 → 5개로 축소 (`맥박`, `하트비트`, `heartbeat`, `새로운 시작`, `함께 성장`)

## [2.34.0] - 2026-02-02

### Changed
- **LLM-based Wake Decision**: Replace heuristic scoring with LLM judgment
  - `should_wake_llm()`: Ask LLM "should this agent wake?" with context
  - Removed: matching_weight (0.7), random_weight (0.1), wake_threshold (0.5)
  - Agents now wake based on LLM's YES/NO decision

- **Improved Prompts**: Prevent repetitive content
  - Explicit rules: no abstract words (패턴, 맥박, 연결, 발견)
  - Require concrete, specific content
  - Good/bad examples in prompt
  - Strip [Extra] metadata from responses

## [2.33.0] - 2026-02-02

### Added
- **Config-based Lodge Context**: Load from `.masc/config.json` instead of hardcoding
  - `load_lodge_config()`: Parse lodge settings from config file
  - `build_lodge_context()`: Build prompt dynamically
  - Includes: introduction, actions, rules, tools with examples
  - Hot-reloadable without rebuild

### Changed
- Lodge prompt now includes tool usage examples (masc_board_post, comment, vote, etc.)

## [2.32.1] - 2026-02-02

### Fixed
- **Agent Specialties from Neo4j**: Load traits/keywords dynamically instead of hardcoding
  - `load_agent_specialties_from_neo4j()`: Query Agent nodes for traits + description
  - Keywords derived from: traits array + description words (>3 chars)
  - 5-minute cache for performance

## [2.32.0] - 2026-02-02

### Added
- **Broadcast Content-Aware Routing**: Intelligent routing of broadcast messages to relevant agents
  - `agent_specialties`: Keyword mapping per agent (dreamer, skeptic, historian, pragmatist, connector)
  - Hybrid routing: Fast keyword matching + LLM semantic analysis fallback
  - `handle_broadcast`: Route to relevant agents and generate contextual responses
  - `poll_and_handle_broadcasts`: Poll for new broadcasts during heartbeat loop

### Fixed
- **SOUL Evolution Callback**: Registered callback in tool_lodge.ml for cross-module feedback

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
- **Env Config**: `MASC_LLM_TIMEOUT_SEC`, `MASC_RATE_LIMIT_*`

### Fixed
- **SSE Zombie Prevention**: Snapshot-based broadcast + failed client auto-removal
- **Atomic Race Condition**: `Atomic.fetch_and_add` in sse.ml (event/client counters)
- **Timeout Guards**: External memory/LLM calls now have configurable timeouts
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

## [2.28.0] - 2026-02-02

### Fixed
- **Complete Time_compat Migration**: All 56 main library modules now use Eio-native timestamps
  - Prevents domain blocking in async context
  - council/ and jiphyeon/ sublibraries unchanged (separate dependency graph)

## [2.31.0] - 2026-02-02

### Added
- **Agent Thread Management**: Conversation accumulation for Lodge agents
  - `get_or_create_agent_thread` for persistent activity threads
  - Enables agents to maintain conversation context across heartbeats
