# RFC-0261 — gRPC LSP failed-initialize FD/process teardown

- Status: Draft
- Date: 2026-06-19
- Related: issue #21546 (fd-leak audit), RFC-0137 (FD pressure host-external triggers), `keeper_fd_pressure.ml` (FD admission gate)

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

`MASC_GRPC_ENABLED` defaults to `true` (`env_config_snapshot.ml:83`), so the path is live by
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

- `Eio.Process.signal proc.proc Sys.sigterm` — kills the child. Killing it closes the child's
  pipe write ends, so the stderr-drain fiber (which reads the un-exposed `stderr_r`) reaches EOF
  and exits.
- `Eio.Flow.close proc.stdin_w` and `Eio.Flow.close proc.stdout_r` — release the two FDs we hold.
  Closing `stdout_r` makes `Lsp_process_manager.read_message` raise, so the response-reader fiber
  (`lsp_message_router.ml:179-201`) exits on its next read.

All three operations are non-blocking, so `shutdown` is safe to call while `ensure_proc` holds
`lsp_spawn_mutex`. Each is best-effort; `Eio.Cancel.Cancelled` is re-raised so cancellation still
propagates (structured concurrency).

This relies on Eio's structured concurrency: a fiber blocked on a read of a pipe exits when that
pipe is closed (or its peer dies), so closing the proc's resources cascades to fiber teardown
without an explicit per-fiber cancel.

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

## Verification

- `dune build --root . @lib/server/check` passes (type + `.mli` conformance).
- `test_lsp_process_manager` spawns a real child process with held pipes, calls `shutdown`
  twice, and asserts the child exits while the held `stdin_w` and `stdout_r` resources are closed.
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
