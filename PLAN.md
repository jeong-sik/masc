# MASC Multi-Keeper Hardening & Verification Plan

## Current Status (as of 2026-05-11)
- PRs #14507-#14519, #14527, #14532, #14534, #14538 merged
- Dashboard multi-transport abstraction layer implemented (#14497, #14500)
- SSE consumer hardcoding removed in branch fix/dashboard-sse-transport-hardcoding (pending push)
- keeper_invariant.ml + .mli committed with stdlib rewrite, sandbox_roots, eq deriver, 14 tests (#14527, #14532, #14538)
- keeper_exec_fs.ml - sandbox_isolation guard before writes wired (#14532)
- keeper_turn_sandbox_runtime.ml / .mli - turn_id field + accessor + Docker label (#14532)
- keeper_sandbox_runtime.ml / .mli - optional turn_id Docker label (#14532)
- lib/config/env_config_keeper.ml / .mli - KeeperLogSampling module (#14532)
- lib/masc_log/log.ml - per-keeper log sampling via MASC_KEEPER_LOG_SAMPLE_RATE (#14532)
- test/test_keeper_invariant.ml - 14 alcotest tests (#14527, #14538)
- Sandbox container removal warning on cleanup failure (#14509)
- keeper_tool_alias 3-tier classification superseded by RFC-0064 (PR #14574): flat `route` table replaces aliases/oas_dual_register/hallucinated_builtins

## In-Flight PRs
- #14552 - feat(ide): wire Ide_meta_sync into keeper_exec_fs (Phase 5)
- #14555 - feat(keeper): add passive-streak metric for tool selection validation (Phase 4)
- #14557 - fix(keeper,dashboard,server): stop swallowing warnings/errors (Phase 6)
- #14564 - feat(keeper): wire goal/task/board with keeper tool results (Phase 5)
- #14565 - feat(ide): add memory tier panel to IDE right-side (Phase 5)
- #14573 - feat(grpc,lsp): add LspCall RPC to gRPC service (Phase 1)
- #14574 - refactor(keeper): RFC-0064 two-surface tool alias — drop 3-tier classification (Phase 4)

## Remaining Work

### Phase 1: Dashboard/Transports
- [x] Implement multi-transport abstraction (SSE, HTTP streamable, WebSocket, gRPC)
- [x] Remove hardcoded EventSource from dashboard/src/sse.ts
- [ ] Wire gRPC consumer for LSP results (in-flight: PR #14573)
- [ ] Add Go WebSocket server support (no Go code in repo; deferred)

### Phase 2: Keeper Invariants
- [x] Commit keeper_invariant.ml + .mli
- [x] Add test module for sandbox isolation, credential isolation, tool monotonicity
- [x] Wire sandbox_isolation check into keeper_exec_fs.ml before writes

### Phase 3: Sandbox Hardening
- [x] Add turn_id to Docker container labels in keeper_turn_sandbox_runtime.ml
- [x] Verify container removal on cleanup failure (warn logged + counter incremented)
- [x] Fail-fast on missing required mounts (via required_mount_result in host_config_provider.ml)

### Phase 4: Tool Selection
- [~] Move hardcoded alias table from keeper_tool_alias.ml to config — **superseded by RFC-0064 (PR #14574)** which replaces the 3-tier classification with a flat `route` table at the source. Config-relocation kept the same workaround pattern (N-of-M `oas_dual_register`, string-list `hallucinated_builtins`); RFC-0064 eliminates it structurally.
- [ ] Add passive-streak metric for tool selection validation (in-flight: PR #14555)

### Phase 5: IDE/Dashboard Integration
- [x] Integrate .masc-ide persistence (ide_meta_sync.ml) - wired in keeper_exec_fs.ml (PR #14552)
- [ ] Wire goal/task/board with keeper tool results (in-flight: PR #14564)
- [ ] IDE right-side memory component (in-flight: PR #14565)

### Phase 6: Logging/Observability
- [x] Add turn_id label to Docker containers
- [x] Per-keeper log sampling
- [ ] Ensure warnings/errors are not swallowed (in-flight: PR #14557)

### Phase 7: Math Verification
- [x] Formalize keeper_invariant.ml tests (14 tests)
- [x] Wire into FSM guards (sandbox isolation in exec_fs)

## Next Steps
1. Merge in-flight PRs after CI passes
2. Monitor ocamlformat-check on PRs that needed force-push
3. Go WebSocket server support deferred (no Go runtime in repo)
