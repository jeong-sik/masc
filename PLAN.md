# MASC Multi-Keeper Hardening & Verification Plan

## Current Status (as of 2026-05-11)
- PRs #14507-#14519, #14527, #14532, #14534, #14538 merged
- Dashboard multi-transport abstraction layer implemented (#14497, #14500)
- SSE consumer hardcoding removed in branch fix/dashboard-sse-transport-hardcoding (pending push)
- keeper_invariant.ml + .mli committed with stdlib rewrite, sandbox_roots, eq deriver, 14 tests (#14527, #14532, #14538)
- keeper_exec_fs.ml - sandbox_isolation guard before writes wired (#14532)
- keeper_turn_sandbox_runtime.ml / .mli - turn_id field + accessor + Docker label (#14532)
- keeper_sandbox_runtime.ml / .mli - optional turn_id Docker label (#14532)
- keeper_tool_alias.ml - Env_config_keeper.KeeperToolAlias (#14532)
- lib/config/env_config_keeper.ml / .mli - KeeperToolAlias, KeeperLogSampling (#14532)
- lib/masc_log/log.ml - per-keeper log sampling via MASC_KEEPER_LOG_SAMPLE_RATE (#14532)
- test/test_keeper_invariant.ml - 14 alcotest tests (#14527, #14538)
- Sandbox container removal warning on cleanup failure (#14509)

## In-Flight PRs
- #14552 - feat(ide): wire Ide_meta_sync into keeper_exec_fs (Phase 5)
- #14555 - feat(keeper): add passive-streak metric for tool selection validation (Phase 4)
- #14557 - fix(keeper,dashboard,server): stop swallowing warnings/errors (Phase 6)
- #14564 - feat(keeper): wire goal/task/board with keeper tool results (Phase 5)
- #14565 - feat(ide): add memory tier panel to IDE right-side (Phase 5)
- #14567 - docs(plan): update PLAN.md with current status
- #14573 - feat(grpc,lsp): add LspCall RPC to gRPC service (Phase 1)

## Remaining Work

### Phase 1: Dashboard/Transports
- [x] Implement multi-transport abstraction (SSE, HTTP streamable, WebSocket, gRPC)
- [x] Remove hardcoded EventSource from dashboard/src/sse.ts
- [x] Wire gRPC consumer for LSP results (PR #14573)
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
- [x] Move hardcoded alias table from keeper_tool_alias.ml to config
- [x] Add passive-streak metric for tool selection validation (PR #14555)

### Phase 5: IDE/Dashboard Integration
- [x] Integrate .masc-ide persistence (ide_meta_sync.ml) - wired in keeper_exec_fs.ml (PR #14552)
- [x] Wire goal/task/board with keeper tool results (PR #14564)
- [x] IDE right-side memory component (PR #14565)

### Phase 6: Logging/Observability
- [x] Add turn_id label to Docker containers
- [x] Per-keeper log sampling
- [x] Ensure warnings/errors are not swallowed (PR #14557)

### Phase 7: Math Verification
- [x] Formalize keeper_invariant.ml tests (14 tests)
- [x] Wire into FSM guards (sandbox isolation in exec_fs)

## Next Steps
1. Merge in-flight PRs after CI passes
2. Monitor ocamlformat-check on PRs that needed force-push
3. Go WebSocket server support deferred (no Go runtime in repo)
