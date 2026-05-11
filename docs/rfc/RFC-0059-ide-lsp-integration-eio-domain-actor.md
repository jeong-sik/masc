# RFC-0059 — IDE LSP Integration + Eio Domain/Actor Parallelism

Status: Phase 1 Complete · Phase 2 PR-5 + PR-6 Complete (PR #14517 Actor mailbox, PR #14520 Domain pool, both merged 2026-05-11) — remaining work: PR-7 review of `Dashboard_cache` internals (see §10 Tier A Integration row T6)
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-10 · Updated 2026-05-11 (Phase 2 PR-5/PR-6 landed, status promoted)
Supersedes: —
Related: `lib/server/server_ide_lsp_proxy.ml`, `lib/ide/ide_annotations.ml` (functional), RFC-0056 (sub-library extraction pattern), PR #14488 (Phase 1), PR #14502 (Tier A perf quick wins), PR #14505 (Tier A simplify follow-up), PR #14517 (Phase 2 PR-5 Actor mailbox), PR #14520 (Phase 2 PR-6 Domain pool)

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

### 1.2 Keeper execution is single-fiber (Phase 2 — PR-5 + PR-6 Complete, see PR #14517 / #14520)

91K LOC across 421 files in `lib/keeper/`. Verified state on `origin/main` at `662cf59f7d` (2026-05-11):

- **Heartbeat tick loop**: `lib/keeper/keeper_heartbeat_loop.ml:1568` `run_heartbeat_loop` defines `let rec loop ()` at line 1626. Single-fiber recursive, calls `Eio_guard.fair_yield ()` before each cycle (line 1633) — cooperative scheduling only, no Domain partition.
- **Supervisor fork**: `lib/keeper/keeper_supervisor.ml:262` does `Eio.Fiber.fork ~sw:ctx.sw (fun () -> ...; Keeper_keepalive.run_heartbeat_loop ...)` per keeper. All N keepers share `ctx.sw` and therefore the single Domain.
- **Domain count in codebase**: `rg "Domain.spawn|Domain_manager|Eio.Domain_manager" lib/ bin/` returns 0 hits. Confirmed: `Domain.recommended_domain_count` is also unreferenced.

For N concurrent keepers (prod: 16–36, target: 64+), each heartbeat tick competes for the same Domain's scheduler. Agent SDK calls (HTTP round-trips 2–30s) block the fiber and only `Eio_guard.fair_yield` cedes — but yield only redistributes within the same Domain.

Hardware budget on the target M3 Max: `Domain.recommended_domain_count () = 16` (verified at session time, 2026-05-11). At 64 keepers, even ideal Domain partitioning maps 4 keepers to a Domain, so HTTP-bound work still benefits significantly: 64 simultaneous in-flight HTTP calls vs the current single-Domain ceiling where the Eio scheduler holds them all in one OS thread.

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

Current pattern (`lib/keeper/keeper_heartbeat_loop.ml:1568-1840`):
```
let run_heartbeat_loop ~proactive_warmup_sec ctx m stop ~wakeup =
  ...
  let rec loop () =
    if Atomic.get stop then ()
    else (
      Eio_guard.fair_yield ();
      ...                       (* presence, snapshot, board, turn, recurring stages *)
      loop ())
  in loop ()
```

State that today lives as closure-captured `ref`s (`turn_running`, `consecutive_failures`, `timing_ring`, `last_meta_mtime`, etc.) becomes the actor's explicit state record. The `Eio_guard.fair_yield ()` at line 1633 stays — it remains useful inside a Domain to cede to peer keepers on the same Domain.

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
- Keeper state is explicit, not closure-captured `ref`s scattered across the 1.8k-line loop body.
- Messages are typed (no hidden state mutations through `Atomic.t` + `ref` interleaving)
- `Domain_pool.submit` dispatches to parallel Domain
- Crash recovery: supervisor restarts actor from last state

Scope: modify `lib/keeper/keeper_heartbeat_loop.ml`, `lib/keeper/keeper_supervisor.ml` (the `Eio.Fiber.fork ~sw:ctx.sw` at line 262 becomes `Domain_pool.submit pool ...`), `lib/keeper/keeper_registry.ml`. Keeper *logic* unchanged — only the execution wrapper.

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
| `lib/keeper/keeper_heartbeat_loop.ml` (1835 LOC) | -150/+300 | Actor loop wrapper for `run_heartbeat_loop` |
| `lib/keeper/keeper_supervisor.ml` (2476 LOC) | -50/+100 | Replace `Eio.Fiber.fork ~sw:ctx.sw` per keeper with `Domain_pool.submit` (line 262) |
| `lib/keeper/keeper_registry.ml` | -30/+60 | Cross-Domain registry access (Mutex hand-off or RCU snapshot) |
| `lib/repo_manager/repo_sync.ml` | -20/+50 | Eio.Path + Eio.Process |
| `lib/fs_compat/fs_compat.ml` | +30 | Domain-local fd cache (PR #14502 T5 left a single-domain-only cache; multi-domain rollout requires `Domain.DLS` per-domain hashtable) |
| `lib/dune` | +4 | New modules |

**Total Phase 1**: 522 LOC new, 177 LOC modified across 5 files (COMPLETE).
**Total Phase 2 (estimate)**: ~530 LOC new, ~200 LOC modified across 7 files (not started).

## 9. Decision

Phase 1 merged to `main` as 3 new modules + proxy rewiring. This RFC document is updated to reflect Phase 1 as complete retrospective.

Phase 2 (Eio Domain/Actor) verification — completed 2026-05-11 against `origin/main` `662cf59f7d`:

1. **Tick loop pattern vs RFC §3.2 pseudocode**: actual file is `lib/keeper/keeper_heartbeat_loop.ml` (NOT `keeper_heartbeat.ml`), 1835 LOC. `run_heartbeat_loop` at line 1568 builds closure-captured state (`turn_running`, `consecutive_failures`, `timing_ring`, `last_meta_mtime`, `last_successful_heartbeat_ts`, `last_heartbeat_cycle_ts`, plus a persistent `Agent_sdk.Context.t`) and runs `let rec loop ()` at line 1626. The body cycles through presence → snapshot → board → turn → recurring stages with `Eio_guard.fair_yield ()` at line 1633. RFC §3.2 pseudocode is structurally accurate but the actual state surface is wider than `state` — the actor migration must thread these refs through the actor's explicit state record.

2. **`keeper_supervisor.ml` post-PR-#14491 state**: PR #14491 (`a2e34b63d4`) wired OAS telemetry into provider health, livelock gate, and supervisor — but did NOT change the per-keeper fork pattern. `lib/keeper/keeper_supervisor.ml:262` still uses `Eio.Fiber.fork ~sw:ctx.sw (fun () -> ... Keeper_keepalive.run_heartbeat_loop ...)`. The supervisor now does additional bookkeeping (watchdog `last_failure_reason` inspection at lines 290-307, dispatch-event routing at 320-329) but the fundamental "one fiber per keeper, all on the same Domain" structure is unchanged. PR-7 must keep the watchdog signal contract while replacing the `fork ~sw` with `Domain_pool.submit pool`.

3. **`Domain.recommended_domain_count` on target hardware**: M3 Max → 16. Verified at session time. At 64 keepers and a Domain-pool of 16, even-distribution gives 4 keepers per Domain. HTTP-bound work scales linearly because Eio fibers within a Domain still cooperatively yield during `Eio.Time.with_timeout` on the HTTP socket.

4. **Keeper HTTP call concurrency measurement**: deferred to PR-6 acceptance test. Current single-Domain ceiling: all 64 keepers' HTTP round-trips share one OS thread's epoll loop. Expected Domain-pool ceiling: 16 OS threads' epoll loops → roughly 16× the syscall parallelism for blocking I/O work. The measurement target is wall-clock for a synthetic 64-keeper batch where each issues one 5-second HTTP call: single-Domain baseline ≈ 5s × ⌈64 / `connect_concurrency`⌉, Domain-pool target ≈ 5s × ⌈64 / (16 × `connect_concurrency_per_domain`)⌉. The harness in `benchmarks/benchmark.sh` is parameterizable for this — extension is part of PR-6's success criteria.

## 10. Tier A Integration (PR #14502, PR #14505)

The Tier A perf quick wins merged 2026-05-10 (commits `196e7bb6a8`, `3ec105f6fb`) made several decisions that interact with Phase 2's Domain split:

| Tier A change | Phase 2 implication |
|---|---|
| `lib/keeper/keeper_turn_slot.ml` `holder_table` → `Holder_map.t Atomic.t` (T3) | Already lock-free for reads. Cross-Domain `Atomic.get` is safe (atomic loads on the persistent map). Writers serialize via `holder_mutex` (Eio.Mutex) — at multi-Domain rollout this becomes a Stdlib.Mutex (Eio.Mutex is single-Domain). |
| `lib/sse.ml` `session_disconnect_hooks : (unit -> unit) SMap.t Atomic.t` (T1) | Same story — `Atomic.get` is cross-Domain safe; writers go through `Lockfree_atomic.update_with_commit` which uses `Atomic.compare_and_set`. No change needed. |
| `lib/fs_compat/fs_compat.ml` `Append_fd_cache` LRU (T5) | **Single-domain assumption baked in** (Stdlib.Mutex protecting one Hashtbl.t). At multi-Domain rollout this must become per-Domain via `Domain.DLS.t`. The Tier A docstring already calls this out as a TODO. |
| `lib/server/server_dashboard_http_core.ml` parameterized cache (T6) | Uses `Dashboard_cache.get_or_compute_with_timeout` which already has its own concurrency model (fibers, single-Domain). Phase 2 may need an audit of `Dashboard_cache` internals — out of scope for PR-5/6 but flagged for PR-7 review. |
| `lib/sse.ml` `?on_disconnect` argument added by PR #14505 to close register/set_disconnect_hook race | Cross-Domain unaffected (atomic registry under the hood). |

The `Append_fd_cache` is the only Tier A piece that breaks cleanly at multi-Domain. PR-7 file inventory adds `lib/fs_compat/fs_compat.ml +30 LOC` for the per-Domain cache rewrite.
