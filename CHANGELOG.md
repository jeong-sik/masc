# Changelog

## [Unreleased]

## [2.262.0] - 2026-04-09

### Added
- Genuine HITL approval pipeline — Eio.Promise fiber suspension, MCP approval tools (#5907 Phase 1, #5955)
- Graduated boring-turn guard — 5-level tool_choice escalation to cut idle token waste (#5968)
- OAS pin drift doctor — local switch validation in Makefile build/test targets (#5958)
- Spawn stderr capture + cloexec pipes — child process observability and hang prevention (#5960)
- Approval audit log — persistent JSONL records for pending/resolved/expired events (#5969)
- Git clone sandboxing in keeper_shell_readonly (#5930)

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
