# Changelog

## [Unreleased]

### Added
- `MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST` env knob for runtime cascade narrowing (CSV of provider kinds - `ollama`, `glm`, etc.). Flows through `Env_config_keeper.KeeperCascade.provider_allowlist` -> `Keeper_agent_run.run_turn` -> OAS `Cascade_config.apply_provider_filter`. Unset => full cascade, no behavior change. (#6478)
- `Config_dir_resolver.log_resolution` info log emitted once at server startup. When `MASC_CONFIG_DIR` silently shadows a `<base_path>/.masc/config` overlay, the log line appends a hint so operators don't lose time debugging an overlay that is being ignored. (#6478)
- `test_cascade_config_validity` alcotest suite - runs every committed `config/cascade.json` profile through OAS `parse_model_string_exn`, hard-fails on unknown providers / invalid specs, soft-passes on "provider unavailable" (missing API key). Profile names are discovered from the JSON, not hardcoded. Includes a meta-guard that feeds a synthetic unknown-provider entry to prove the happy-path assertion is not vacuous. (#6478)
- `scripts/sync-version-truth.sh` - dry-run-by-default helper that keeps `dune-project`, `masc_mcp.opam`, and `ROADMAP.md` "Current package version" in sync. Uses `dune-project` as the single source of truth; regenerates opam via `dune build`; updates ROADMAP with an anchored sed. `--apply` required to write; `check-version-truth.sh` post-verify runs automatically. (#6478)

## [0.5.3] - 2026-04-11

### Added
- Expose llm_provider_http_status via Prometheus counter (#6514)

### Changed
- Extract shared tool permission map from auth (#6501)
- Rename type result to tool_result across all tool modules (#6482)
- Bump OAS pin to v0.120.0 (#6510)
- Replace tautological assertions with observable post-conditions in keeper-registry tests (#6506)
- Prune retired front doors (#6520)
- Remove unused delete_posts_by_predicate (#6509)
- Remove 13 dead dashboard exports (#6493)

### Fixed
- Keeper: gate auto-clear of manual reconcile behind age threshold (#6497)
- Keeper: should_run_turn now consults manual_reconcile_pending (#6518)
- Keeper: SSOT playground paths, drop hardcoded masc-mcp and container root (#6468)
- Keeper: convert parse_keeper_identity from failwith to Result (#6479)
- Keeper FSM runtime integration (#6451)
- Goal-janitor: surface write_meta Error instead of ignoring (#6513)
- Board: log vote/vote_comment errors instead of silent drop (#6463)
- Backend: detect partial writes in atomic_increment and atomic_update (#6480)
- Transport: surface WS and WebRTC send failures in server bootstrap (#6517)
- Eio: wrap oas_sse_bridge + rate_limit cleanup fibers with exception loggers (#6519)
- Dashboard: restore control surface routing (#6490, #6523)
- Dashboard: standardize error display to CSS variable color scheme (#6494)
- Dashboard: standardize time display to relativeTime/TimeAgo (#6491)
- Dashboard: improve accessibility for buttons and form labels (#6496)
- Dashboard: preserve board scroll position on refresh (#6461)
- Dashboard: rename harness rail labels to match actual state (#6521)
- Dashboard: align navigation descriptions with actual UI (#6526)
- Worktree: use config base_path for worktree root (#6449)
- Playground: docker_playground_cwd double-slash escape (#6522)

### Security
- Remove tracked localhost TLS key from repository (#6487)

### Performance
- Memoize expensive derived state in fleet and agent-roster dashboard (#6492)

## [0.5.2] - 2026-04-11

### Changed
- Eliminate vendor hardcoding outside provider_adapter boundary (#6495)
- Root cause fixes for JSONL parsing, keeper_github repo, preset validation (#6457)

### Fixed
- Restore loopback cross-port relaxation in auth (#6504)
- Delegate context budget to OAS pipeline (#6488)

## [0.5.1] - 2026-04-11

### Changed
- FSM apply_event returns `Applied | Ignored` transition type — detect invalid events (#6481)
- Replace stringly-typed gate field with variant type (#6454)

### Fixed
- Restore keeper reset surface and typed tool expectations (#6477)
- Use glm-coding (Coding Plan) before glm (pay-per-use) in cascade (#6475)
- Align 4 tests with post-#6433 main state (#6460)

## [0.5.0] - 2026-04-11

### Added
- Typed_tool_masc + State_product + TLA+ orthogonal FSM verification (#6321)
- Trust Observatory dashboard — raw signals (Phase C0) (#6359)
- B-SIM Monte Carlo verification — 4 gates pass (#6352)
- Per-decision trifecta evaluation (Phase B3) (#6346)
- Guard → Thompson bridge (Phase B1) (#6307)
- TLA+ KeeperDecisionPipeline — Phase B0 gate (#6277)
- Shared gate client + Telegram/CLI connectors (#6367)
- iMessage channel connector (#6329)
- Docker playground for keeper_bash (#6338)
- Decision Pipeline FSM diagram in keeper detail dashboard (#6405)
- masc_keeper_reset command for stale runtime state (#6428)
- rate_limit.mli — hide bucket internals behind abstract type (#6431)
- coding_first cascade profile — glm-5.1 first for PR-capable keepers (#6430)
- Voice tools for sangsu (ElevenLabs Roger) (#6247)
- Keeper Failing → recovery minimum shards + .masc/ whitelist (Phase B2) (#6325)

### Changed
- Restructure keeper.world.md and keeper.capabilities.md (#6298)
- Substitute keeper_name into world/capabilities prompts (#6316)
- Expand decision log error_category: 5 → 7 categories (#6316)
- Wire OAS Tool_retry_policy + post_tool_use_failure hook (#6324)
- Per-keeper error prevention hints in TOML instructions (#6298)
- Broadcast PoC uses Tool_schema_gen combinators (#6427)
- Remove params_to_input_schema duplicate — use OAS shared utility (#6418)
- Draining invariant doc fix to match TLA+ (#6403)
- Rename team_session → execution_session (#6364)
- Remove remaining team session surfaces (#6363)
- OAS pin bumped to v0.119.1 (#6446)
- Allow localhost cross-port browser mutations for dev dashboard (#6459)

### Fixed
- Keeper turn timeout 300s → 1200s default (env var override removed) (#6371)
- Auto-recover reconcile-safe tools on server parse errors (#6370)
- Feature flag registry: MASC_KEEPER_DOCKER_PLAYGROUND (#6365)
- Voice config empty session endpoints (#6357)
- Keeper sidecar suffix check for dotted names (#6408)
- Worktree basepath config resolution (#6449)
- Keeper autonomous stall — raise turn budget, classify shell read-only (#6371)
- 50 additional bug fixes across keeper, dashboard, and infrastructure

## [0.3.0] - 2026-04-09

### Added
- Startup TOML cross-validation for tool registration (#6093)
- Keeper cascade config API + dashboard selector + TOML hot-reload (#6100)
- MASC store diagnosis cards in telemetry view (#6105)
- OAS runtime diagnosis surfaces (#6061)
- Prompt fingerprint telemetry (#6075)
- Keeper PR history tracking + active worktree listing in dashboard (#6083)
- Keeper playground state cache + dashboard panel (#6060)
- Dashboard OAS worker observability enrichment (#6071)
- Fleet telemetry panel improvements (#6104)
- Governance HITL approvals dashboard (#6098)
- Keeper TOML→JSON config SSOT resync — 20 fields (#6110)

### Changed
- **Breaking**: Renamed `keeper_shell_readonly` to `keeper_shell` across all configs, prompts, and registry (#6095)
- Centralized keeper entrypoint alias resolution (#6096)
- Simplified dashboard command surface (#6058)
- Simplified monitoring agents runtime view (#6103)
- Simplified playground status with stdlib `List.take` (#6097)
- Tool spec handler_binding required variant for type-safe dispatch (#6073)
- OAS pin bump to 120710a with Uncertain.t (#6114)
- Hardened OAS ownership boundaries (#6101)
- OAS pin SSOT and doctor checks relaxation (#6113)

### Fixed
- Discord keeper session isolation per room (#6094)
- Keeper post-commit timeout classification (#6102)
- Worker model_id hardcoded "turn-exhausted" in MaxTurnsExceeded response (#6087)
- Dashboard error prefix stripping before JSON categorization (#6057)
- Removed fake no-op Dashboard_cache.set_clock/set_sw (#6081, #6074)
- Dead OAS proof bridge panels removed from telemetry view (#6106)
- Sangsu keeper switched to local_only cascade (#6088)
- CI semantic version comparison in OAS pin check (#6111)

## [0.2.0] - 2026-04-09

### Changed
- Release SemVer restarts at `0.y.z` to reflect that `masc-mcp` is still pre-1.0.
- Release-train automation now compares tags within the active major series, so frozen legacy `v2.*` tags do not block the new `0.x` line.
- Front-door docs, release policy, and issue templates now point at `v0.2.0` as the active package version.
- The reset starts at `0.2.0` because historical `v0.1.0` and `v0.1.1` tags already exist in the repo.

### Deprecated
- New `v2.*` release tags. Historical `v2.87.0` through `v2.263.0` remain immutable legacy references.

## [2.263.0] - 2026-04-09

### Added
- OAS exit_condition plumbing — boring gate exits Agent.run early after 8+ idle turns (#5988)
- Configurable boring exit threshold via Runtime_params (#5997)
- Tool schemas for autonomy pipeline: keeper_pr_submit, keeper_preflight_check, keeper_pr_review_* (#5996)
- Keeper read-only tool classification with Tool_dispatch mirroring (#5983)
- Retry-safe tool metadata — board tools registered with Mod_inline + idempotent flags (#5973)
- Self-repo --base-path guard — rejects runtime state in source repo (#5992)

### Changed
- Adaptive OAS timeout — context-based (180s + 1.5s/1K tokens), max_turns 200→5 (#5987)
- GLM cascade simplified — removed redundant glm:glm-5-turbo, OAS glm:auto handles expansion (#5985)
- Time constants extracted to Masc_time_constants SSOT module (#5993)
- Network defaults centralized — SearXNG, OTel, allowed_origins (#5994)
- Output cap and min context constants deduplicated (#5995)

### Fixed
- Dashboard null-status crash — assoc_member wrapper tolerates null nested JSON (#5985)
- Keeper ambiguous-partial-commit reclassification for read-only tools (#5983, #5973)
- OAS cascade model timeout derived from keeper OAS budget (#5985)
- Cheolsu keeper set to ollama-only for slot queuing test (#5986)
- TLA+ spec: separated timeout from fairness, use Filename.concat (#5979)
- Version truth sync across ROADMAP, SPEC-INDEX, PRODUCT-OPERATING-PLAN (#5982)
- OAS pin updated to 0.117.0 (#5981)

## [2.262.0] - 2026-04-09

### Added
- Genuine HITL approval pipeline — Eio.Promise fiber suspension, MCP approval tools (#5907 Phase 1, #5955)
- Graduated boring-turn guard — 5-level tool_choice escalation to cut idle token waste (#5968)
- OAS pin drift doctor — local switch validation in Makefile build/test targets (#5958)
- Spawn stderr capture + cloexec pipes — child process observability and hang prevention (#5960)
- Approval audit log — persistent JSONL records for pending/resolved/expired events (#5969)
- Git clone sandboxing in keeper_shell (#5930)

### Fixed
- Ollama thinking mode disabled for keepers — unblocked all keeper timeouts (#5948)
- ToolResult.json field drift — aligned with OAS 0.116.1 (#5948)
- Hardcoded port 8085 removal — env-driven LLM endpoint discovery (#5962)
- Keeper name and MCP prefix boundary resolution (#5967)
- Dashboard null-agent patch guard (#5971)
- GLM-5-turbo cascade fallback for outage resilience (#5956)
- Read path validation with bounded suffix resolution and symlink escape prevention (#5930)
- Approval queue fiber cancellation cleanup — no orphan entries (#5955)

### Changed
- Named constants for model context thresholds (64k/200k) replacing magic numbers (#5969)
- Governance risk patterns documented in-code for mandatory review (#5969)

## [2.261.0] - 2026-04-08

### Added
- Per-keeper provider filter via `allowed_providers` config (#5831)
- Preset-aware task routing — keepers only claim tasks matching their preset (#5820)
- 11-state keeper phase diagram in dashboard (#5829)
- Excuse patterns editor UI with server-side validation (#5818)
- Output validation stats in tool-quality dashboard (#5832)
- Dashboard SSE `keeper_tool_skipped` event + centralized thresholds (#5824)
- Deterministic tool output validation (Samchon-style schema constraints) (#5821)
- Analyst persona (verification-driven) (#5850)

### Fixed
- Comprehensive Eio.Cancel.Cancelled guard sweep — 72 files, 129 patterns (#5842)
- Cancelled guard rollback for 3 cleanup sites (fd close before re-raise) (#5848)
- AllowList pruning WARN + agent JSON race condition (atomic write) (#5840)
- Defensive lowercase + warn log in filter_by_providers (#5846)
- Policy preset name validation at load time (#5787)
- Cluster-aware telemetry read path (#5828)
- Chevron discoverability (opacity-40 default) (#5837)

### Changed
- Board_listener removed — filesystem-first, PG relay redundant (#5809)
- Heuristic metadata matching replaced with deterministic Tool_dispatch sets (#5830)
- DRY `lower_string_list_opt` helper for allowed_providers parsing (#5844)
- Transport status reports canonical HTTP protocol (#5833)

### Docs
- Gate-Connector Protocol RFC: fail-closed, shorter URL TTL, replay protection (#5805)

## [2.260.0] - 2026-04-08

### Fixed
- Eio.Cancel.Cancelled re-raised instead of swallowed in bridge, dashboard, and metrics modules (#5810)
- truncate_tool_output now enforces hard cap on total output length (#5814)
- autonomous_turn_limit default set to 1 for single-slot servers (#5806)
- Yojson.Json_error catch narrowed in dashboard tool-quality (#5812)
- Branch-switch guard hardened with tab tokenization, global git options, and precise mutation detection (#5813)
- useEffect void prefix for floating promise lint (#5816)

### Changed
- Board votes now use stable post content hash instead of monotonic counter (#5817)
- K2K preset routing refined with forbidden_tools and improved score penalty (#5819)
- Deterministic read-only boundary enforcement for shell/gh tools (#5822)
 
