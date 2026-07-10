# RFC-0261 — gRPC LSP failed-initialize FD/process teardown

- Status: Retired
- Date: 2026-06-19
- Related: issue #21546 (fd-leak audit), RFC-0137 (FD pressure host-external triggers), `keeper_fd_pressure.ml` (FD admission gate)

The unconsumed gRPC `LspCall` surface was removed. The authenticated
`/api/v1/ide/lsp` WebSocket route is the IDE LSP transport SSOT, so none of the
implementation described below remains live code.

## Problem

The gRPC LSP proxy (`lib/server/masc_grpc_server.ml`, `lib/server/lsp_process_manager.ml`)
leaks a child process, its three pipe FDs, and its reader fibers on every failed LSP
`initialize`.

`ensure_proc` resolves a language server lazily:

1. On cache miss it calls `Lsp_process_manager.spawn ~sw:lsp_sw`, where
   `lsp_sw = sw` is the **server-lifetime** switch (`masc_grpc_server.ml:480`). `spawn` binds
   `stdin_w`, `stdout_r`, `stderr_r` (3 pipe FDs), the spawned `proc`, and the stderr-drain
   fiber to that switch (`lsp_process_manager.ml:174-216`).
2. It forks the response-reader fibers on the same switch via
   `Lsp_message_router.start_response_reader ~sw:lsp_sw`.
3. It sends `initialize` under a 10s timeout.
4. The proc is registered in the cache (`Hashtbl.replace lsp_processes`) **only on the success
   path** (`masc_grpc_server.ml:535`).

The three failure branches — `Eio.Time.Timeout`, an `Error` initialize result, and any other
exception (`masc_grpc_server.ml:537-543`) — return `Error` **without** tearing down the
already-spawned proc and **without** caching it. Because the proc's resources are bound to the
server switch, the only release point is server shutdown. Because the cache was not populated,
the next `LspCall` for the same language misses again and spawns a fresh process. Each failed
init therefore adds 1 child + 3 pipe FDs + 2 reader fibers, climbing monotonically and bounded
only by call frequency.

### Why it matters under fleet load

At the time of this retired RFC, `MASC_GRPC_ENABLED` defaulted to `true`, so the path was live by
default. The trigger requires an LSP server binary on `PATH` whose `initialize` does not complete
within 10s (e.g. `ocamllsp` on a large repo, easier to hit under 16-keeper CPU/IO contention) or
errors. A keeper or IDE proxy issuing repeated `LspCall` for a flaky language server re-spawns on
every call. The accumulated FDs feed the `keeper_fd_pressure` admission gate
(`projected_fds > soft_limit`), which converts the leak into a fleet-wide turn block rather than a
localized failure — "retries amplify the outage" as `keeper_fd_pressure.ml` already documents.

## Design

Add a non-blocking teardown to `Lsp_process_manager` and call it on all three init-failure
branches.

### `Lsp_process_manager.shutdown`

```
val shutdown : lsp_process -> unit
```

- `Eio.Flow.close proc.stdin_w`, `Eio.Flow.close proc.stdout_r`, and
  `Eio.Flow.close proc.stderr_r` — release all three pipe FDs the record holds. `stderr_r` is
  exposed on the `lsp_process` record specifically so it can be closed here: a fiber reaching EOF
  exits but does **not** release its FD, so without this close the stderr-drain fiber's `stderr_r`
  stays bound to the server-lifetime switch until shutdown (leaking 1 FD per failed init even
  though the fiber has exited). Closing `stdout_r` also makes `Lsp_process_manager.read_message`
  raise, so the response-reader fiber (`lsp_message_router.ml:179-201`) exits on its next read;
  closing `stderr_r` ends the stderr-drain fiber's read.
- `Eio.Process.signal proc.proc Sys.sigterm` — signals the child to stop.

All operations are non-blocking, so `shutdown` is safe to call while `ensure_proc` holds
`lsp_spawn_mutex`. Each is best-effort and logs at debug on failure; `Eio.Cancel.Cancelled` is
re-raised so cancellation still propagates (structured concurrency).

Closing the proc's own resources is what releases the FDs; fiber teardown is a downstream
consequence (a fiber blocked on a read exits when that pipe is closed), not the release mechanism.
The earlier assumption that signalling the child would let EOF reclaim `stderr_r` was wrong — EOF
ends the fiber but leaves the FD on the switch.

### Call sites (`masc_grpc_server.ml` `ensure_proc`)

`Lsp_process_manager.shutdown proc` is invoked before returning `Error` on each of:
the `Error msg` initialize result, the `Eio.Time.Timeout` branch, and the catch-all `exn` branch.

The WebSocket IDE LSP proxy (`server_ide_lsp_proxy.ml`) uses the same
`Lsp_process_manager.spawn` + initialize-on-cache-miss pattern. Its switch is connection-scoped
rather than server-scoped, but repeated failed init attempts on a long-lived IDE connection have
the same per-attempt child/pipe leak shape. It uses the same shutdown helper on its failed
initialize result and timeout branches.

## Alternatives considered

1. **Per-proc child switch.** Spawn each LSP proc under its own `Switch.run` held open by a fiber
   forked on `lsp_sw`, returning a stop handle; release the child switch on init failure. This is
   structurally cleaner (no reliance on close-cascades-to-fibers) but is a larger change to the
   `spawn` signature and the router, and adds promise/fork lifetime surface. Deferred as possible
   future hardening; the targeted teardown fixes the leak with a much smaller review surface.
2. **Cache the failed proc and reuse it.** Rejected: a proc that failed `initialize` is not usable
   and would serve broken responses.
3. **Reap the child synchronously in `shutdown`.** `shutdown` only signals (SIGTERM) the child; it
   does not `Eio.Process.await` it, because `await` blocks and `shutdown` runs under the spawn
   mutex. The child is reaped when the server-lifetime switch is released (`Eio.Process.spawn ~sw`
   awaits the child in `on_release`). Between a failed init and server shutdown one zombie PID
   accumulates per failed init — lighter than the FD leak (a zombie holds a slot in the PID table,
   not an FD that feeds the `keeper_fd_pressure` gate) and fully resolved by Alternative 1's
   per-proc switch, which can `await` off the spawn-mutex path. Deferred as a follow-up to the
   per-proc-switch hardening.

## Verification

- `dune build --root . @lib/server/check` passes (type + `.mli` conformance).
- `test_lsp_process_manager` spawns a real child process with held pipes, keeps the parent write
  ends of the reader pipes open, calls `shutdown` twice (idempotent), and asserts the child exits
  while all three held resources (`stdin_w`, `stdout_r`, `stderr_r`) are closed. Keeping the writer
  ends open isolates the *close* from the killed child's EOF — with a live writer a reader only
  becomes unreadable when `shutdown` closes it, so a missing close blocks the read and trips the
  timeout assertion.
- Manual reasoning: the three failure branches now tear the proc down at the failure point;
  the success path is unchanged.
- Not covered: an end-to-end fake LSP server that fails `initialize` on demand. The lower-level
  shutdown test covers the teardown primitive; the FD-count assertion (`/dev/fd` before/after N
  failed inits) is still the right shape once an LSP fixture exists.

## Rollout

- Single PR: `shutdown` + the three call sites + this RFC. No config flag; the teardown is always
  correct.
- No behavior change on the success path. On the failure path the only observable difference is
  that the child process is signalled and its FDs are released immediately instead of at shutdown.
