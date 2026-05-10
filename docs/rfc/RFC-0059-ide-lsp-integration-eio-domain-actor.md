# RFC-0059 — IDE LSP Integration + Eio Domain/Actor Parallelism

Status: Phase 1 Complete · Phase 2 Draft
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-10 · Updated 2026-05-11
Supersedes: —
Related: `lib/server/server_ide_lsp_proxy.ml`, `lib/ide/ide_annotations.ml` (functional), RFC-0056 (sub-library extraction pattern)

## 1. Problem

### 1.1 IDE LSP Proxy — Phase 1 Complete

Phase 1 (LSP Proxy) is fully implemented on `main`. Three new modules + proxy rewiring landed:

| Module | LOC | Status |
|---|---|---|
| `lsp_process_manager.ml` | 201 | `Eio.Process.spawn`, Content-Length framing, structured cleanup |
| `lsp_message_router.ml` | 201 | Promise-based JSON-RPC routing, ID remapping, notification passthrough |
| `lsp_overlay_provider.ml` | 120 | CodeLens/inlayHint/diagnostic overlay from MASC annotations |
| `server_ide_lsp_proxy.ml` | 531 | Rewired from stub to real implementation, 0 `(* TODO *)` markers |

LSP method dispatch coverage:

| Method | Handler | MASC Overlay |
|---|---|---|
| `initialize` | Server-side capabilities response | — |
| `initialized` | No-op ack | — |
| `shutdown` | `Null` response | — |
| `exit` | Disconnect | — |
| `textDocument/codeLens` | LSP forward + MASC merge | Decision/Question/Bookmark |
| `textDocument/inlayHint` | LSP forward + MASC merge | goal_id/task_id bindings |
| `textDocument/diagnostic` | LSP forward + MASC merge | Question → Information severity |
| `textDocument/did*` | Notification forward to LSP | — |
| Other `textDocument/*` | Generic forward to LSP | — |

Not yet forwarded: `documentSymbol`, `hover`, `definition`, `references`, `completion`, `documentHighlight`, `foldingRange`, `selectionRange`, `documentLink`, `colorPresentation`, `formatting`, `rangeFormatting`, `onTypeFormatting`, `rename`, `prepareRename`, `codeAction`, `codeLens/resolve`.

### 1.2 Keeper execution is single-fiber (Phase 2 — Not Yet Started)

91K LOC across 421 files in `lib/keeper/`. Heartbeat loops run as sequential Eio fibers. `Domain.spawn` appears 0 times in the entire codebase. For N concurrent keepers (prod: 16–36), each heartbeat tick competes for the same Domain's scheduler. Agent SDK calls (HTTP round-trips 2–30s) block the fiber without yielding the Domain to other compute-bound work.

OCaml 5.x `Domain.spawn` + `Eio.Promise` enables true parallelism across cores. The Eio scheduler already manages fibers; Domains add the parallel axis.

## 2. Non-goals

- **Not a frontend RFC.** CodeMirror / Monaco integration is out of scope. This RFC covers the server-side LSP bridge and actor infrastructure.
- **Not multi-process architecture.** LSP servers are child processes (`Eio.Process`), not distributed nodes.
- **Not a full Eio migration.** Existing synchronous I/O in `repo_store.ml` and `repo_sync.ml` migrates only where the actor model requires it (Phase 2 PR-8).
- **Not a keeper rewrite.** Phase 2 PR-7 migrates the heartbeat *loop* to actor-style, not the keeper logic itself.

## 3. Proposal

### 3.1 Phase 1: LSP Proxy — COMPLETE

All 4 PRs implemented on `main`. Actual LOC vs estimates:

| PR | Estimate | Actual | Delta |
|---|---|---|---|
| PR-1 Process Manager | ~200 | 201 | ±1 |
| PR-2 Message Router | ~300 | 201 | -33% |
| PR-3 Overlay Provider | ~150 | 120 | -20% |
| PR-4 Proxy Rewiring | -200/+100 | +177 | in range |

Design retained from original proposal:

**PR-1: LSP Process Manager** (201 LOC)

New module: `lib/server/lsp_process_manager.ml`

```
type lsp_process = {
  lang_id : string;
  process : Eio.Process.t;
  stdin : Eio.Flow.sink;
  stdout : Eio.Flow.source;
  stderr : Eio.Flow.source;
}
```

Responsibilities:
- Spawn LSP server via `Eio.Process.spawn ~stdin:(`Pipe stdin) ~stdout:(`Pipe stdout)`
- `Content-Length` header parsing on stdout (LSP standard framing)
- `Eio.Switch.on_release` for structured cleanup on disconnect or error
- Per-language registry: `lsp_command_for_lang` already exists, wire to actual spawn
- Timeout on process startup: `Eio.Time.timeout` with 10s limit

Contract:
- Input: `lang_id`, `workspace_root`
- Output: `(lsp_process, [ `Command_not_found | `Startup_timeout | `Process_error of string ]) result`
- Lifecycle: created on `textDocument/didOpen`, killed on WebSocket disconnect

**PR-2: LSP Message Router** (~300 LOC new)

New module: `lib/server/lsp_message_router.ml`

Responsibilities:
- Bidirectional JSON-RPC message routing between WebSocket client and LSP process
- Request ID mapping: client IDs (arbitrary) → server IDs (sequential per process)
- Response demultiplexing: match response `id` back to pending request
- Notification passthrough: `textDocument/didChange`, `textDocument/didSave` forwarded as-is
- Error handling: LSP process crash → structured error response to client

Design:
- `pending_requests : (int, (Yojson.Safe.t, string) result Eio.Promise.t) Hashtbl.t`
- Client sends request → router allocates new server ID, creates Promise, writes to LSP stdin
- LSP stdout reader fiber resolves Promises on response
- WebSocket writer fiber awaits Promise, maps server ID back to client ID

**PR-3: MASC Overlay Provider** (~150 LOC new)

New module: `lib/server/lsp_overlay_provider.ml`

Wire the existing functional `Ide_annotations` to the LSP proxy:

- `codeLens` response: read annotations for file, inject `Keeper: <summary>` entries
- `inlayHint` response: show goal/task bindings as inline hints
- `diagnostic` response: merge LSP diagnostics with MASC-specific warnings
- Cache annotations per file with invalidation on `textDocument/didSave`

Replaces the current `load_annotations_for_file` stub that returns `empty_overlay`.

**PR-4: WebSocket Wiring** (~100 LOC modify)

Modify `server_ide_lsp_proxy.ml`:
- Replace `message_loop` with calls to `Lsp_message_router`
- Replace `create_lsp_server` with `Lsp_process_manager.spawn`
- Replace `inject_masc_codelens` with `Lsp_overlay_provider.codeLens`
- Keep the `add_routes` function signature unchanged (no caller changes outside this file)

### 3.2 Phase 2: Eio Domain/Actor (4 PRs)

**PR-5: Actor Primitives** (~200 LOC new)

New modules: `lib/core/actor_mailbox.ml`, `lib/core/actor_types.ml`

```
type 'msg mailbox = 'msg Eio.Stream.t

type 'msg actor = {
  name : string;
  inbox : 'msg mailbox;
  state : 'state ref;
}
```

Pattern from Eio docs: `Eio.Stream.create ~max_len:64` for bounded mailbox. Actor loop:
```
let rec loop actor =
  match Eio.Stream.take actor.inbox with
  | Msg msg -> process msg; loop actor
  | Stop -> cleanup actor
```

Supervisor: `Eio.Switch` wrapping multiple actor fibers. On actor crash → restart with last known state.

**PR-6: Domain Pool** (~150 LOC new)

New module: `lib/core/domain_pool.ml`

```
type pool = {
  domains : Eio.Domain_manager.t list;
  switch : Eio.Switch.t;
}
```

- `create ~n` spawns N Domains via `Eio.Domain_manager.run`
- `submit pool f` dispatches work to least-loaded Domain
- Result via `Eio.Promise`
- Graceful shutdown: `Eio.Switch.stop` signals all Domains

Constraint: OCaml Domains are not lightweight threads — pool size bounded by `Domain.recommended_domain_count ~gc:{ GC.get () with space_overhead = 200 }` (typically 2–12 on Apple Silicon). Keeper count (16–36) > Domain count → multiple keepers share Domains via fibers.

**PR-7: Keeper Actor Migration** (~500 LOC modify)

Migrate keeper heartbeat loop to actor model:

Current pattern (`keeper_heartbeat.ml`):
```
let rec tick keeper state =
  let* action = decide keeper state in
  exec keeper action;
  Eio.Time.sleep delay;
  tick keeper state
```

Actor pattern:
```
let actor_handler keeper inbox =
  let rec loop state =
    match Eio.Stream.take inbox with
    | `Tick -> let* state' = tick keeper state in loop state'
    | `Goal_update g -> loop { state with goals = g :: state.goals }
    | `Shutdown -> ()
  in loop initial_state
```

Benefits:
- Keeper state is explicit, not mutable ref scattered across modules
- Messages are typed (no hidden state mutations)
- `Domain_pool.submit` dispatches to parallel Domain
- Crash recovery: supervisor restarts actor from last state

Scope: modify `keeper_heartbeat.ml`, `keeper_supervisor.ml`, `keeper_registry.ml`. Keeper *logic* unchanged — only the execution wrapper.

**PR-8: Repo Sync Async** (~100 LOC modify)

Migrate `repo_sync.ml` from synchronous to Eio-based:

- Replace `Sys.file_exists` with `Eio.Path.stat`
- Replace `Unix.open_process_in` (git commands) with `Eio.Process.spawn`
- `sync_all` runs repos in parallel via `Eio.Fiber.fork_all`
- `repo_store.ml` file I/O migrates to `Eio.File` only where called from actor context

## 4. Dependency Graph

```
Phase 1 (LSP):                    Phase 2 (Actor):
  PR-1 (Process Manager)
    ↓                               PR-5 (Actor Primitives)
  PR-2 (Message Router)               ↓
    ↓                               PR-6 (Domain Pool)
  PR-3 (Overlay Provider)             ↓
    ↓                               PR-7 (Keeper Actor)
  PR-4 (WebSocket Wiring)             ↓
                                    PR-8 (Repo Sync Async)
```

Phase 1 and Phase 2 are independent. Either can land first. PRs within each phase are sequential (each builds on the prior).

## 5. Performance

LSP JSON-RPC traffic for a single developer session:
- `textDocument/completion`: ~10 req/sec during active typing
- `textDocument/diagnostics`: ~2 req/sec on save
- `textDocument/codeLens`: ~1 req/sec on open/scroll
- Total: <20 messages/sec

Eio fiber overhead: ~1μs per context switch. 20 msg/sec = 0.002% of a single core. The LSP proxy is I/O-bound, not compute-bound. `Domain.spawn` is unnecessary for the proxy itself — single Domain with fibers handles this trivially.

Domain/Actor for keepers: the win is parallelism of agent SDK HTTP calls (2–30s round-trips), not message throughput. N keepers on M Domains means N HTTP calls can be in-flight simultaneously across cores.

## 6. Risks

| Risk | Mitigation |
|---|---|
| LSP process crashes mid-session | `Eio.Switch.on_release` cleanup + reconnect with re-initialize |
| Keeper actor state serialization format change | Phase 2 PR-7 keeps existing JSON state format, wraps in actor |
| Domain pool starvation | Bounded mailbox (`max_len:64`) + backpressure on `Eio.Stream.take` |
| `Eio.Process` not available for all platforms | Fallback to `Unix.open_process_in` behind `Eio.Process` availability check |
| RFC-0058 number collision precedent | This RFC verified unique in `docs/rfc/` before writing |

## 7. Success Criteria

### Phase 1 — COMPLETE
- [x] `server_ide_lsp_proxy.ml` has 0 `(* TODO *)` markers
- [x] LSP initialize → codeLens → diagnostic → shutdown cycle implemented in `dispatch_message`
- [x] Annotation overlay appears on codeLens for files with `.masc-ide/annotations/` data
- [x] No `Obj.magic` in new code
- [x] `dune build @check` green

### Phase 2 — Not Started
- [ ] Keeper heartbeat runs as actor in tests (unit test with mock mailbox)
- [ ] Domain pool test: N tasks submitted, all resolve, pool shuts down cleanly
- [ ] `dune runtest` for new Phase 2 modules passes

## 8. File Inventory

### Phase 1 (new) — COMPLETE
| File | Est. LOC | Actual LOC | Description |
|---|---|---|---|
| `lib/server/lsp_process_manager.ml(i)` | 200+40 | 201 | LSP process lifecycle |
| `lib/server/lsp_message_router.ml(i)` | 300+60 | 201 | JSON-RPC routing |
| `lib/server/lsp_overlay_provider.ml(i)` | 150+30 | 120 | MASC annotation → LSP |

### Phase 1 (modify) — COMPLETE
| File | Est. Δ | Actual Δ | Description |
|---|---|---|---|
| `lib/server/server_ide_lsp_proxy.ml` | -200/+100 | 354→531 (+177) | Stub → real wiring |
| `lib/dune` | +3 | +3 | New modules |

### Phase 2 (new)
| File | LOC | Description |
|---|---|---|
| `lib/core/actor_mailbox.ml(i)` | 80+20 | Bounded Stream-based mailbox |
| `lib/core/actor_types.ml(i)` | 60+15 | Actor record type |
| `lib/core/actor_supervisor.ml(i)` | 60+15 | Switch-based supervisor |
| `lib/core/domain_pool.ml(i)` | 150+30 | Domain spawn + Promise dispatch |

### Phase 2 (modify)
| File | LOC Δ | Description |
|---|---|---|
| `lib/keeper/keeper_heartbeat.ml` | -100/+200 | Actor loop wrapper |
| `lib/keeper/keeper_supervisor.ml` | -50/+80 | Actor supervision |
| `lib/keeper/keeper_registry.ml` | -30/+60 | Actor registry |
| `lib/repo_manager/repo_sync.ml` | -20/+50 | Eio.Path + Eio.Process |
| `lib/dune` | +4 | New modules |

**Total Phase 1**: 522 LOC new, 177 LOC modified across 5 files (COMPLETE).
**Total Phase 2 (estimate)**: ~530 LOC new, ~200 LOC modified across 7 files (not started).

## 9. Decision

Phase 1 merged to `main` as 3 new modules + proxy rewiring. This RFC document is updated to reflect Phase 1 as complete retrospective.

Phase 2 (Eio Domain/Actor) remains Draft. Before Phase 2 RFC is finalized, the following verification is required:
1. `keeper_heartbeat.ml` actual tick loop pattern vs RFC §3.2 pseudocode
2. `keeper_supervisor.ml` post-PR-#14491 state
3. `Domain.recommended_domain_count` on target hardware
4. Keeper HTTP call concurrency measurement — fiber-only vs Domain parallelism benefit
