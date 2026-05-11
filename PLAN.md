# MASC Multi-Keeper Hardening & Verification Plan

## Current Status (as of 2026-05-11)
- PRs #14507–#14519 merged
- Dashboard multi-transport abstraction layer implemented (#14497, #14500)
- SSE consumer hardcoding removed in branch `fix/dashboard-sse-transport-hardcoding` (merged #14526)
- `keeper_invariant.mli` + `keeper_invariant.ml` committed (#14527)
- `feat/keeper-invariant-tests-and-wiring` in progress (PR #14532)

## Remaining Work

### Phase 1: Dashboard/Transports
- [x] Implement multi-transport abstraction (SSE, HTTP streamable, WebSocket, gRPC)
- [x] Remove hardcoded EventSource from `dashboard/src/sse.ts`
- [ ] Wire gRPC consumer for LSP results
- [ ] Add Go WebSocket server support

### Phase 2: Keeper Invariants
- [x] Commit `keeper_invariant.mli`
- [x] Commit `keeper_invariant.ml` + tests
- [x] Add test module for sandbox isolation, credential isolation, tool monotonicity
- [x] Wire `sandbox_isolation` check into `keeper_exec_fs.ml` before writes

### Phase 3: Sandbox Hardening
- [x] Add `turn_id` to Docker container labels in `keeper_turn_sandbox_runtime.ml`
- [x] Verify container removal on cleanup failure
- [ ] Fail-fast on missing required mounts

### Phase 4: Tool Selection
- [x] Move hardcoded alias table from `keeper_tool_alias.ml` to config
- [ ] Add passive-streak metric for tool selection validation

### Phase 5: IDE/Dashboard Integration
- [ ] Integrate `.masc-ide` persistence (`ide_meta_sync.ml`)
- [ ] Wire goal/task/board with keeper tool results
- [ ] IDE right-side memory component

### Phase 6: Logging/Observability
- [ ] Per-keeper log sampling
- [ ] Ensure warnings/errors are not swallowed

### Phase 7: Math Verification
- [ ] Formalize `keeper_invariant.ml` tests
- [ ] Wire into FSM guards
