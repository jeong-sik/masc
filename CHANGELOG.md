# Changelog


## [2.90.0] - 2026-03-16

### Security
- **Cypher Injection Eradication** — all `agent_neo4j.ml` queries use parameterized Cypher (`$param` syntax) with `cypher_query` type
- **Password Fail-Fast** — `neo4j_client_eio` returns `Error` on missing `NEO4J_PASSWORD` instead of defaulting to `"password"`

### Added
- `Agent_neo4j.cypher_query` type with `to_bolt_params`, `to_http_payload`, `to_shell_cmd`
- `Json_util.require_string/int/float/bool` — `(value, string) result`-returning JSON helpers
- `Progress.Tracker.assert_wired` — detects initialization ordering bugs at startup
- `Env_config_runtime.Timeout` submodule (gcloud_auth, anthropic_api, openai_compat, llm_grace, graphql_query, keeper_status)
- `Env_config_runtime.Llm_defaults` submodule (default_max_tokens, sse_retry_ms, log_truncation_len)
- `Env_config_runtime.Neo4j/Voice/Mlx/Custom_llm/Network` submodules
- 20 adversarial tests for Cypher escaping and parameter isolation

### Changed
- `mcp_server_eio` walph context: `lazy` + `failwith` replaced with explicit `Result` type
- `voice_bridge_eio`: 6 hardcoded URIs replaced with centralized `Voice.default_host/port`
- `llm_client`: endpoint URLs and timeouts now env-configurable
- `thread_persist`: `is_localhost` expanded to full 127.0.0.0/8 coverage

### Fixed
- `llm_client`: silenced exceptions now logged to stderr
- `escape_cypher_string`: handles backslash, unicode escape, null bytes (previously missed backslash)

## [2.89.0] - 2026-03-14

### Added
- **OAS Direct Evidence Adoption** — local team-mode workers now materialize OAS `Direct_evidence` bundles per worker run, including lifecycle snapshots, worker summaries, and conformance output for `verify_trace`
- **Team-Mode Solid Win Surface** — worker-run snapshots, status summaries, and dashboard proof projection now carry validated final text, failure reason, and session conformance for completed team-mode workers

### Changed
- **Agent SDK Floor** — `masc-mcp` now requires `agent_sdk >= 0.21.0`
- **Team Worker Evidence SSOT** — `masc_team_session_verify_trace` now prefers OAS direct-evidence sessions and only falls back to legacy raw-trace lookup for older worker runs
- **Dashboard Worker Evidence** — validated worker evidence is projected from OAS-backed worker summaries while preserving MASC-specific mode/wait/execution overlays

## [2.88.0] - 2026-03-14

### Added
- **Worker Readiness Surface** — team-session status now distinguishes pending vs ready local workers and exposes recent worker-run summaries with requested class/size and resolved runtime/model metadata
- **User-facing Delegate Guidance** — follow-up delegation to accepted-but-not-ready workers now returns an explicit readiness error instead of a generic missing-container failure

### Changed
- **Agent SDK Floor** — `masc-mcp` now requires `agent_sdk >= 0.19.0`
- **Runtime Transparency** — dashboard proof and worker-run snapshots surface resolved runtime/model plus routing reason for local worker runs
- **Shell UX Contract** — `shell_exec` metacharacter rejection now directs users toward `workdir` + single-command usage

### Fixed
- **False Fallback Pressure** — in-flight worker actors now count toward session activity so team health and fallback-task logic no longer falsely signal idle failure while workers are running

## [2.87.0] - 2026-03-13

### Added
- **Observability Truth on Main** — execution and dashboard truth surfaces now expose the mainline observability-truth lane, including lodge truth compatibility follow-up (#968, #974)

### Changed
- **Managed-Agent Surface Cleanup** — split managed-agent/public MCP boundaries and pruned dead hidden tool surfaces from the mainline surface set (#960, #976)
- **Governance HTTP Read-only** — governance and council HTTP compatibility surfaces were narrowed to the current read-only model (#965)
- **Upgrade Note Required** — integrations relying on hidden/deprecated tool surfaces or legacy governance HTTP semantics should read the `v2.87.0` release note before upgrading

### Fixed
- **H2 Tool Auth Alignment** — H2 write routes now use tool-level auth instead of coarse broadcast permissions (#966)
- **Baseline Compatibility** — restored team-session and auth compatibility on the current baseline, including legacy task alias task-op classification (#967, #970)
- **Sentinel Board Noise** — routine board patrol posts are suppressed to reduce unnecessary baseline chatter (#971)

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.85.0] - 2026-03-12

### Added
- **Safe Keeper Tooling** — resident keepers now expose keeper-safe voice and readonly shell tooling plus an internal tool catalog surface (#826)
- **Audit Telemetry Phase 1** — core collaboration events now emit audit logging for traceability (#833)
- **Room-wide Orchestra Map** — dashboard adds an orchestra overview surface and backing command-plane read model (#834)
- **Tool Registry P4** — tool-registry metadata and dispatch surfaces are expanded through the phase-4 enhancement set (#830)
- **Truth-only Gardener Status** — gardener runtime now exposes a truth-only status surface for downstream consumers (#829)

### Changed
- **Keeper Facade Follow-up** — keeper split follow-up shrinks the facade and tightens module boundaries after the core runtime split (#827)
- **Direct Mention Detection** — keeper mention observation now uses shared exact-mention handling instead of hardcoded direct-mention assumptions (#835)

### Fixed
- Gardener structured-post tests now guard empty content with a non-empty generated title fixture (#836)

## [2.84.0] - 2026-03-12

### Added
- **OAS-backed Agent Control Contract** — internal agent-control export now publishes `/api/v1/openapi.json` with canonical MCP operation metadata and current Agent SDK aliases
- **Resident Judgment Overlay** — operator snapshot includes resident judgment and dashboard surfacing (#811)
- **Admin Snapshot Surface** — admin-level snapshot and update tools for keeper inspection (#814)
- **Local Voice Playback** — internal local voice playback selection for browser-based voice (#816)
- **Gardener Backlog Triage** — gardener starts backlog triage sessions on worker pressure signals (#812)

### Changed
- **Generated Agent SDK Control Tools** — swarm-facing MASC control tools are now generated from shared contract metadata instead of hand-written wrappers
- **Truthful Transport Mapping** — `tool_to_endpoint` now falls back to `/mcp` when no real REST route exists instead of advertising fake paths
- **Keeper Core Module Split** — split keeper core modules for independent lifecycle management (#810)
- **Default Model Alias** — LLM layer uses default model alias for simplified configuration (#813, #815)
- **Dashboard Proof Surface** — humanized proof surface in dashboard (#806)
- **Global Local Output Budget** — llama runtime enforces global local output budget (#818)

### Fixed
- Pending confirmations are now actor-aware in operator flow (#809)
- Admin surface auth and keeper wiring follow-up (#817)
- Lodge falls back to `LLAMA_DEFAULT_MODEL` when worker model is unset (#808)
- Removed runtime dependencies from keeper tests (#807)

## [2.83.0] - 2026-03-11

### Added
- **Gardener Signal Observation** — full signal-based observation with LLM-primary decision making for spawn/retire (#773)
- **CP Workload Templates** — `masc_operation_start` accepts workload templates and attached team sessions (#769)
- **Voice Tools** — expose public voice tools for browser-based voice interaction (#775)
- **Dashboard Tool Audit** — raw tool audit view in agent and keeper detail pages (#776)
- **Dashboard Build Identity** — expose backend build identity (version, commit, uptime) in dashboard (#780, #787)
- **Keeper Offline Policy** — learned offline policy substrate for keeper agents (#781)
- **Sangsu Policy V2** — keeper policy v2 substrate with refined decision rules (#788)
- **Operator Run Resolution** — swarm run resolution actions for operator control (#783, #789)

### Changed
- **Cascade Phase 3** — distributed-pattern modules (`auto_chain`, `walph`) migrated to `Lodge_cascade.call` (#772)
- **Cascade Phase 4** — `auto_responder` LLM calls migrated to `Lodge_cascade.call` (#779)
- **WebRTC Deduplication** — removed duplicated WebRTC code in favor of `ocaml-webrtc` library (#778)
- **Ollama Runtime Removal** — removed Ollama runtime path, LLM calls go through `Lodge_cascade` only (#785)
- **Dashboard Utils Extraction** — deduplicated 5 utility functions from 12 files into `Dashboard_utils` module (#791)
- **Transport Deps Injection** — Eio context passed via deps record instead of global singleton (#793)
- **Keeper Resident Split** — split resident keepers from persistent agents for independent lifecycle (#799)
- **Dashboard Assets Rebuild** — rebuild stale assets and remove dead batch endpoint code (#798)

### Fixed
- Mission briefing async refresh UX with loading states and error recovery (#774)
- GC archive logic now includes cancelled team-sessions (#777)
- Team-session `stop_session` directly finalizes instead of deferring to runtime loop (#784, #786)
- Prevent crash when `LLAMA_DEFAULT_MODEL` unset after Ollama removal (#795)
- Align migration message test assertions with production code (#794)

## [2.82.0] - 2026-03-11

### Changed
- **Server State Record Threading** — `net` threaded through `server_state` record, removing global references (P3a) (#768)
- **Lodge Cascade Unification** — 8 call sites migrated to `Lodge_cascade.call` for consistent LLM dispatch (#766)
- **Mission Briefing Determinism** — briefing generation no longer depends on non-deterministic inputs (#764)
- **Execution Surface** — session-first diagnostics with actor parameter passthrough (#757)

### Fixed
- Gardener provenance derived from actual decision path instead of config flag (#765)
- Execution uses passed `actor` parameter instead of hardcoded `"dashboard"` (#770)

## [2.81.1] - 2026-03-11

### Added
- **Workload Templates for CPv2** — `masc_operation_start` now accepts `workload_template` (`coding_team`, `research_team`, `ops_governance_team`) and normalizes default workload/stage pairs.
- **Attached Team Sessions** — `masc_team_session_start(operation_id=...)` can bind a team session to a managed CPv2 operation and exposes `command_plane.operation_id` / `operation_path` in session status.
- **AI Front Door Docs** — added `llms.txt` and `llms-full.txt`, and surfaced them from the command-plane help/readme entrypoints.

### Changed
- `/api/v1/command-plane/help` now includes workload templates and an attached-team-session golden path for the managed execution spine.

### Fixed
- Board test isolation: `ref(lazy)` singleton pattern prevents test JSONL data from polluting production board path (#759)
- Thread-safe resettable singleton via `Lazy.force` atomic CAS + `ref` wrapping for test reset
- `MASC_BASE_PATH` temp directory isolation in `test_board_dispatch` and `test_tool_board_coverage`
- Attached team session validation now rejects duplicate operation attachment based on the nested operation card shape rather than a broken top-level lookup.
## [2.80.0] - 2026-03-11

### Added
- **Swarm State Persistence (Gap B+C)** — `checkpoint_of_yojson`, `event_entry_of_yojson`, `load_latest_checkpoint`, `read_recent_events`; recovery events now carry checkpoint state and recent event history (#751)
- **Karpathy Autoresearch Phase 2.5** — real autonomous experiment loop with expanded runtime control (#736)

### Changed
- LLM runtime calls consolidated behind `Llm_client` abstraction (#741, #745, #746)
- Contract truth and shared runtime context restored across dashboard/server flows (#743)
- `tool_keeper.ml` and `tool_trpg.ml` split into smaller focused modules (#744)
- Runtime singleton state collapsed into shared context (#749)
- Dashboard oversized components split (Phase D) (#747)
- Dashboard Side Rail normalized to Korean with `refreshForTab` helper (#750)

### Fixed
- Orphan sessions now transition to `Interrupted` on restart instead of lingering in stale state (#739)
- Mission briefing runtime hardened against failure and drift during live refresh (#742)

### Removed
- Legacy public `masc_swarm_*` MCP tools removed; canonical swarm path remains CPv2, `team_session`, `operator`, and `masc_swarm_live_run` (#748)

## [2.79.0] - 2026-03-11

### Added
- **Mission Briefing Interactive UI** — full panel with LLM cascade reorder, async SWR (#734, #720, #701)
- **Live Monitor Tab** — 3-panel real-time swarm/agent view (#688)
- **Command War Room** — centralized operator console (#681)
- **Board Gardener Keeper** — force task ops + zombie cascade (#666)
- **Sentinel Default Resident** — LLM judgment layer for board/task/keeper consumers (#699, #709)
- **Intent-Backed Predictive Control** — CPv2 intent forecast + correction loop (#668)
- **Swarm Live Run** — `masc_swarm_live_run` MCP tool for inline benchmark (#689)
- **64-Agent Structural Gaps** — checkpoint, goal loop, MDAL swarm (#693)
- **Tool Registry Call Counters** — in-memory counters + `/tools/list` mode filter (#692)
- **Karpathy Autoresearch** — autonomous experiment loop (#717)
- **GC Keeper Extensions** — orphan cleanup + team session archiving (#723)
- **Mode Tool-Category Mapping** — rewrite for effective mode filtering (#721)
- **Swarm Role-Based Tuning** — per-role temperature and max_tokens in agent_spec (#719)
- **Keeper Continuity Validation** — harness-level keeper handoff checks (#715)
- **LLM-Based Semantic Scoring** — capability-match upgrade (#674)
- **Dashboard Semantic Layer Registry** — typed layer abstraction (#667)
- **Dashboard Visibility and Board Hygiene** — scoped visibility + board cleanup (#690)
- **Swarm Session Visibility** — dashboard swarm session panel (#698)
- **Heuristic LLM Scoring** — heuristic modules enhanced with LLM layer (#687)

### Changed
- **Command Plane Decomposition** — `command_plane_v2.ml` (6791 lines) split into 7 focused modules (#672)
- **Dashboard Operator Console** — full rewrite with progressive disclosure + triage-first UX (#675, #676)
- **Dashboard God Module Decomposition** — CSS/command/TRPG/Ops modules extracted (#704)
- **Normalize Helpers** consolidated into `common/normalize.ts` shared module (#727)
- Dashboard components consolidated, dead code removed (#722)
- Planning tab hierarchy inverted — tasks first, empty features collapsed (#712)
- Sentinel heuristic fallback removed in favor of LLM-driven consumers (#714)
- Ollama implicit fallback bias removed — explicit provider selection (#694)
- Silent error cleanup and code hygiene across modules (#700)
- Dashboard and workspace runtime config encapsulated (#673)

### Fixed
- Mission room actions and participants preserved across navigation (#737)
- Memory tab: post-filter + cursor-based pagination corrected (#735)
- Keeper internal notes hidden from execution view (#733)
- Hidden tools bypass mode filter resolved (#724)
- Planning/swarm contracts tightened (#718)
- Swarm proof path aligned with canonical harness (#711)
- Ollama and OpenRouter added to `resolve_provider` (#713)
- Keeper continuity cleanup hardened (#716)
- CI-failing tests aligned with actual code (#710)
- P0 exception narrowing and module extraction (#665)
- Eio.Mutex for fiber-safe SSE client registry (#683)
- Agent.create calls adapted to options-record API (#682)
- `json_int_opt` for LLM token parse failures (#707)
- Agent SDK aligned with latest pinned version (#708)
- Dashboard visibility semantics tightened (#697)
- Managed lane kept visible for live alerts (#671)
- Stale managed trace residue ignored in swarm status (#670)
- Intent forecast review regressions addressed (#669)
- Dashboard operator semantics restored (#679)
- Missing CSS classes for scroll targets added (#677)
- `masc_swarm_live_run` registered in tool catalog and mode (#703)
- Repo dashboard assets preferred over cwd assets (#702)

### Testing
- Mode end-to-end tool count validation per preset (#725)

## [2.78.0] - 2026-03-10

### Added
- **Mission Dashboard Flow** — dashboard mission panel with visual workflow (#656)
- **Proof Criteria Unit Tests** — shared harness framework for team session proofs (#655)
- **Room Strategy Toggles** — room-level strategy and speculation controls (#634)
- **Provider-Native Runtime Registry** — adapter layer for LLM runtime selection (#629, #631)
- **Swarm RISC ISA** — Phase 1-4 instruction set, pipeline, MESI cache, OoO execution, speculative execution with MCTS (#593, #608)
- **Command Plane v2** — absorbed native chain plane into MASC with search fabric (#597, #594)
- **Local64 Runtime Pool** — 64-worker runtime with smoke harness (#586)
- **Hierarchical Controller Stack** — 35/27/9 tier team session controllers (#616)
- **Integrated Benchmark Wrapper** — unified benchmark harness (#607)
- **Graphical Swarm Panel** — dashboard swarm visualizations (#623)

### Changed
- Coding-task search brain set as CPv2 default (#658)
- Operator digest now surfaces command-plane signals (#635)
- Dashboard monitoring aligned with portable env defaults (#642)
- Runtime LLM cascade helpers unified (#640)
- Tool args extraction refactored, eliminating ~120 duplicate helpers (#621)
- Non-tool JSON helpers delegated to Safe_ops (#622)

### Fixed
- **Server-side join dedup guard** in Room.join prevents duplicate agent entries (#654)
- **Eio.Mutex** around global network/clock refs prevents parallel crash (#652)
- Keeper prompt and lodge heartbeat stabilized (#651)
- `Unix.select` replaced with `Eio.Time.sleep` in token generation (#650)
- Dashboard: navigation labels and descriptions normalized (#660)
- Dashboard: Korean labels restored, bilingual UX, a11y polish (#648, #649, #632)
- Dashboard: repeated `joinRoom()` on ControlDock remount prevented (#638)
- Dashboard: captured identity for leaveRoom cleanup (#641)
- Lodge crash paths replaced with `Result.error` returns (#643, #645)
- Dead code and stubs replaced with explicit errors (#646)
- Protocol placeholders replaced with real implementations (#644)
- Hot swarm lifecycle stabilized (#626)
- Local64 mixed smoke stabilized (#625)
- Railway deploy runtime contract hardened (#659)

### Security
- Tracked launchd secrets removed (#636)
- Credential exposure removed from public repo (#620)

### Testing
- Hermetic contract harness CI gate added (#661)
- ~545 vacuous assertions removed across 63 test files (#647)

## [2.77.0] - 2026-03-03

### Added
- MCP `/health` metadata now exposes release/protocol/transport version layers.
- Team session artifacts (`report.json`, `proof.json`) now include `schema_version`.

### Changed
- Streamable Accept policy is unified across HTTP/1 and HTTP/2 `POST /mcp` routes.
- `start-masc-mcp.sh` startup hints now document streamable Accept and legacy fallback env.
- Release helper now aligns with current SSOT (`dune-project`) and changelog-first workflow.

### Deprecated
- Legacy SSE transport endpoints `/sse` and `/messages` are now marked deprecated via response headers.

### Fixed
- Release Makefile target now points to the Eio binary path (`_build/default/bin/main_eio.exe`).

## [2.76.0] - 2026-03-02

### Added
- **TRPG Spectator Workflow Redesign** — dashboard flow updated for keeper-observer gameplay (#484)
- **Walph Stability Phase 1** — error isolation, state visibility, and loop guard hardening (#483)

### Changed
- Viewer preflight row construction standardized with explicit constructor path (#485)
- Library TODO debt reduced with three P2/P3 follow-up cleanups (#491)

### Refactored
- Wrapped bare `ignore()` patterns with `try/with` + logging guards across lib modules (#488)

## [2.75.0] - 2026-03-02

### Added
- **Notification Harness** — 3 MCP tools for in-turn event polling (#472)
  - `masc_notification_count` — pending count (lightweight)
  - `masc_check_notifications` — peek without consuming
  - `masc_consume_notifications` — pop and return (TOCTOU-safe)
- Session queue cap (1000 events) with oldest-drop policy
- Broadcast events pushed to notification queues (polling-only agent support)
- **TRPG Actor Streamlining** — simplified actor creation with profile fields (#478)
- **Transport Error Classification** — pre-JSON-RPC error detection for proxy/CDN HTML pages (#473)
- **Preflight Accessibility** — ARIA attributes and keyboard navigation for new-game wizard (#473)
- **Board/Council Contracts** — repaired execution IA and dashboard typing (#475)

### Changed
- Dashboard context ratio and input event typing tightened (#471)

### Fixed
- TOCTOU race in consume handler (single lock block)
- Timestamp consistency: `Time_compat.now()` for all event timestamps
- Silent None drop in session registry bridge (stderr warning added)
- Infinite comment re-fetch loop in dashboard board view (#476)
- TRPG round observability: emit resolved and dice events in `round_run`

### Refactored
- `PreflightRow` struct replacing opaque 4-tuple, `is_html_body()` DRY extraction, config-derived URL hint (#477)

### Dependencies
- `actions/upload-artifact` v4 → v7 (#468)
- `actions/download-artifact` v4 → v8 (#469)

## [2.74.0] - 2026-02-24

### Added
- **Keeper Autonomy Engine** — Karpathy Autonomy Slider (L1-L5) for keeper agents with goal-driven autonomous action (#450)
- **Generator-Verifier Loop** — Capable model generates action plan, cheap model verifies before execution (#450)
- **Execution Engine** — Approved plans auto-execute via LLM cascade + sandboxed tool_loop with Eval Gate (#450)
- **L2 Board Suggestions** — L2_Suggestive keepers post goal-based suggestions to Board automatically (#450)
- **Keeper MCP Tools** — `masc_keeper_autonomy`, `masc_keeper_goals`, `masc_keeper_trajectory`, `masc_keeper_eval` (#450)
- **Goals Dashboard Tab** — Horizon-grouped goals with priority/status filters and progress tracking (#450)
- **Keeper Autonomy Meter** — L1-L5 gauge, self-model viewer, goal progress in keeper detail view (#450)
- **SSE Autonomy Events** — `keeper_autonomy_start/complete` events for real-time dashboard updates (#450)

## [2.72.0] - 2026-02-23

### Added
- **ElevenLabs Direct TTS** — Voice bridge integrates ElevenLabs text-to-speech for TRPG narration (#434)
- **Narrative Intelligence** — Inventory tracking, relationship graphs, deduplication, and JSON recovery for TRPG sessions (#410)
- **Code Navigation Tools** — LSP-style code navigation (go-to-definition, find-references) for MASC agents (#7dd0720), with E2E test harness (#66e7330)
- **TRPG Combat Events** — Wire combat events to HP mutation with stub handler scaffolding (#411)
- **NPC Bestiary and Difficulty Curve** — NPC archetype skill system with difficulty scaling (#402)
- **Keeper Bootstrap and Alert Fanout** — Bootstrap scan detects stale keepers and fans out alerts (#383)
- **Keeper SSE Events** — Emit SSE events for heartbeat, guardrail, compaction, and handoff lifecycle (#382)
- **Keeper Monitoring Dashboard** — Health alerts, metrics endpoint, and context sparklines (#375, #373)
- **ElevenLabs TTS Proxy Endpoint** — `/tts/proxy` route for streaming TTS audio in TRPG sessions (#387)
- **Eio.Semaphore Concurrency Limiter** — Rate-limit LLM cascade calls via Eio semaphore (#395)
- **200k+ GLM Spawn Cascade Policy** — Enforce minimum context window for GLM agent spawns (#388)
- **TRPG Mid-Join Hard Gate** — Contribution-ledger and join-window gating for mid-session joins (#413)
- **TRPG Structured Actions** — AI-driven decisive game endings via structured action schema (#414, #408)
- **TRPG Traits/Skills Dashboard** — Surface trait and skill semantics in dashboard and party cards (#400, #386)
- **Canonical Combat and Session Outcome Events** — Emit structured combat/outcome events from TRPG engine (#335), visualize in viewer (#334)
- **Keeper-Actor Occupancy Flow** — Viewer displays keeper-actor mapping with release controls (#333)
- **Viewer Visual Depth** — Condition dots, combat FX, area labels, MP bars, scene indicator, archetype colors (#409, #372)
- **Viewer Agent Round Flow Track** — Runtime panel shows per-agent round progression (#346)
- **Viewer DM Narration Voice** — DM voice playback during active TRPG sessions (#354)
- **Viewer Trait Lore and Skill Descriptions** — Inline lore tooltips for TRPG traits (#359)
- **Viewer Party-Card Quick Pick** — One-click actor join from party cards (#358)
- **Dashboard Enriched Keeper and Agent Detail Pages** — Expanded keeper overview cards and agent detail (#394, #378)
- **Dashboard SPA Routes and Sticky Shell** — Restore SPA navigation with redesigned persistent shell (#340)
- **Dashboard Control Dock and Council** — Restore council functionality in dashboard (#343)
- **Viewer Bevy Improvements P3-P7** — Bevy viewer rendering improvements (#399)
- **Quick-Win Tests for Heartbeat and SSE** — Unit test coverage for heartbeat and SSE modules (#407)

### Changed
- **Supabase DB Migration** — Migrate `RAILWAY_PG_URL` to `SUPABASE_DB_URL` for board and state storage (#421)
- **Dashboard Compact API Mode** — Default to compact payloads, trim keeper response size (#376)
- **Viewer Room Hub Unification** — Consolidate room hub implementation, resolve unused warnings (#380)
- **Viewer Strict Clippy Debt** — Clear all strict clippy warnings in runtime/dom modules (#385)
- **Viewer Current Game Lane Separation** — Separate active game UI from lobby, stabilize bootstrap UX (#339, #337)
- **README Update** — Align README with current implementation state (#374)

### Fixed
- **Viewer TRPG Top-Bar Layout** — Resolve top-bar and ops-hud layout overlap (#436)
- **Tools/Call Parsing** — Harden MCP tools/call JSON parsing and not-initialized error handling (#432, #427)
- **MASC Init Error Messages** — Return user-facing error on uninitialized MASC access (#424)
- **TRPG Round-Run Recovery** — Harden round-run recovery, expose run diagnostics (#420)
- **TRPG Short-Circuit on Session End** — Stop round_run processing after session termination (#431)
- **TRPG Dead Assignment Pressure** — Keep rounds alive with dead assignments and round pressure (#430)
- **TRPG DM Voice Routing** — Route DM voice preview through proxy when TTS is configured (#419)
- **TRPG Stale Round-Runner DOM** — Prevent stale state from locking viewer UI (#418)
- **TRPG Lobby Phase Contribution Gate** — Bypass contribution gate during lobby phase in HTTP route (#423)
- **TRPG AI Game Endings** — Enable end-to-end AI-driven game completion (#405)
- **TRPG Bevy Portraits and DnD5 Guidance** — Fix portrait rendering and trait/skill guidance (#403)
- **TRPG Fallback Narration** — Diversify DM fallback replies from 2 to 16 templates (#398), reduce repetition (#429)
- **TRPG Session-Scoped Outcome Gate** — Scope outcome gate to current session only (#397)
- **TRPG Origin-Relative TTS URL** — Use origin-relative path for default TTS proxy URL (#396)
- **TRPG Fallback Round Liveliness** — Improve fallback HP dynamics and round activity (#392)
- **TRPG Phase-as-Status Fallback** — Use phase as status fallback for DM voice playback (#390)
- **TRPG Local Fallback Round Progression** — Add local fallback when keepers are unavailable (#389)
- **TRPG Inactive Keeper Preflight** — Treat inactive keepers as boot-required in preflight checks (#384)
- **TRPG Keeper Stall Loop** — Break keeper stall caused by missing skill routing (#381)
- **TRPG Idle Gate for Auto-Round** — Add idle gate to auto-round loop, disable local_fallback (#401)
- **TRPG Keeper Unavailable Sampling** — Per-turn cap on keeper.unavailable sampling (#357)
- **TRPG Prompt-Echo Recovery** — Recover prompt-echo replies, avoid forced claim gating (#365)
- **TRPG Room-Scoped Round Control** — Stabilize room-scoped round control and session UI (#341)
- **TRPG Room Controls and Hub Layering** — Fix hub layering and session history reset (#338)
- **Start Script Port Check** — Fail fast on occupied MCP port before build (#422)
- **Keeper Bootstrap Stale Skip** — Skip stale keepers during bootstrap scan (#425)
- **Keeper Bootstrap Warmup Throttle** — Throttle bootstrapped keeper proactive warmup (#426)
- **Keeper Bootstrap Scan Dedup** — Avoid repeated bootstrap scans per process (#428)
- **Keeper Proactive Tool-Loop** — Enable proactive tool-loop actions for keepers (#368)
- **Keeper Tool Routing** — Add executable bash/github/fs tool routing (#370)
- **Keeper Remove-Meta Default** — Change `remove_meta` default to false in `keeper_down` (#393)
- **Perpetual CLI Eio Runtime** — Add Eio runtime to standalone perpetual CLI (#417)
- **GLM Chdir Race** — Fix chdir race condition, add structured logging and pool tests (#404)
- **MCP Status Path Timeout** — Harden status path for timeout-prone MCP calls (#379)
- **Dashboard Asset Routes** — Ensure dashboard asset routes take priority over generic prefix (#345)
- **Dashboard Background and TRPG SPA** — Restore background asset, stabilize TRPG SPA UX (#344)
- **Dashboard SPA Boot Lock** — Prevent SPA boot lock with wasm fallback (#336)
- **Dashboard Ops Workflow Parity** — Restore SPA parity for ops workflows (#363)
- **Viewer Round Loop Speed** — Speed up round loop, relax claim gating (#367)
- **Viewer DM Voice Playback Lifecycle** — Stabilize DM voice playback start/stop (#360)
- **Viewer Auto-Round Recovery** — Recover auto-round plan from claimed actor (#364)
- **Viewer Narrative Empty-State** — Show guidance when narrative panel is empty (#362)
- **Viewer Layout on Stop/Resume** — Prevent layout break on stop/resume status changes (#361)
- **Viewer Auto-Run Stall Reasons** — Surface stall reasons in runtime panel (#356)
- **Viewer Hybrid TRPG State** — Handle hybrid state payload for turn sync (#355)
- **Viewer Railway Upstream Override** — Allow Railway TRPG upstream override (#349)
- **Viewer Stale Loading State** — Reduce stale loading state, stabilize side controls (#353)
- **Viewer Ghost Room Focus** — Remove ghost room focus, simplify default TRPG layout (#351)
- **Viewer Runtime MASC Upstream Override** — Support runtime MASC upstream override (#352)
- **Viewer TRPG Runtime and Narrative Flow** — Unstick runtime, restore narrative flow (#350)
- **Viewer Turn Phase Mapping** — Map server turn phases correctly (#347)
- **CI Test Registration** — Add test registration for `code_navigation_eio` (#89b96ca)
- **E2E JSON Pattern Matching** — Fix `json_get_list` type mismatch in E2E tests (#dbd6fad)
- **Viewer Manual Keeper Mapping UX** — Improve manual keeper mapping usability (#342)

## [2.70.0] - 2026-02-19

### Added
- **Preact + HTM SPA Dashboard** — Replace OCaml string-literal HTML with a client-side Preact + HTM single-page app (#278)
- **Local Viewer E2E Checklist Runner** — Harness tool for running viewer end-to-end validation locally (#271)
- **Ops HUD** — Viewer quick-start round diagnostics and operational heads-up display (#264)
- **Entropy-based Preset Selection** — TRPG preset picker uses entropy scoring; viewer focus hash sync (#259)
- **Goal Phase 1 Tools** — Goal dispatch runtime and phase-1 goal MCP tools (#261)
- **New-Game Preflight Diagnostics Panel** — Viewer panel showing precondition checks before game start (#256)
- **TRPG Round Controls and New-Game Bootstrap** — Stabilized round control flow and initial game setup (#249)
- **TRPG Phase Tracking and Staleness Detection** — `dnd5e-lite` phase state machine with stale-turn detection (#251)
- **Mitosis P2-4 odoc Documentation** — API documentation for mitosis modules (#246)

### Changed
- **web_dashboard.ml decomposed into 4 modules** — Extracted dashboard logic into separate compilation units (#275)
- **Viewer God Module decomposed** — `mode.rs` split into 4 files; quality audit applied (#266)
- **Makefile CI worktree support** — `make ci` now works from git worktrees (#276)
- **Viewer Korean user-facing labels** — Developer jargon replaced with Korean UI strings (#247)
- **TRPG round-run stabilization** — Keeper gating, claim enforcement, reply sanitation (#245)
- **Room lifecycle and timeout observability** — Timeout handling for viewer and TRPG rooms (#244)

### Fixed
- Harness smoke runs isolated with auto-generated room IDs (#280)
- Viewer manual and auto round execution serialized to prevent race conditions (#279)
- Viewer round gate and keeper selection UX (#277)
- MCP RPC response parsing hardened against malformed envelopes (#274)
- Council decision SSE events emitted from game-view decisions (#272)
- SSE storm E2E test skipped when bind is not permitted (#270)
- MCP message envelopes unwrapped for MASC viewer panels (#269)
- Emoji replaced with ASCII in Bevy UI text rendering (#268)
- Non-TRPG SSE modes routed to `/sse` endpoint (#267)
- Viewer bootstraps new-game data for inactive rooms (#263)
- Auto-round gating and keeper bootstrap enforced in viewer (#262)
- Game-view precondition session ID isolated in harness (#258)
- All 25 clippy warnings resolved in viewer (#260)
- Coverage push for `json_util`, `safe_ops`, `resilience`; `is_benign_error` bug fixed (#257)
- 52 semantic merge conflicts in viewer resolved (#255)
- Viewer build errors: mod reconnect, overlay mut, missing func (#255 follow-up)
- 53 wasm32 compilation errors resolved (#254)
- Broken symbols restored after viewer cleanup refactor (#252)
- Board search scans all posts instead of limited subset (#253)
- Production cleanup: dedup `html_escape`/`sanitize_text`, zero warnings, XSS audit (#250)
- 19 dead code warnings removed from viewer (#248)
- Viewer compilation errors in `action_panel` and `http` modules (#244 follow-up)
- Viewer `cfg` gates added to wasm32-only functions (#273)

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
