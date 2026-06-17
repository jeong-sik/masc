## Summary

Adversarial audit remediation for the `masc:eio-concurrency-core` PR group.
This PR hardens OCaml 5 / Eio concurrency primitives in three core modules:
`eio_context`, `process_eio`, and `runtime`.

## Audit sources

- `masc/.worktrees/adversarial-review-20260616/reports/PRIORITY-ACTION-PLAN.md`
- `masc/.worktrees/adversarial-review-20260616/reports/concurrency-eio.md`
- `masc/.worktrees/adversarial-review-20260616/reports/resource-leaks.md`

## What changed

### `lib/eio_context/eio_context.ml`
- Made the HTTPS TLS connector cache domain-safe by replacing a plain global `ref` with an `Atomic.t` cell and a lock-free once-initialization pattern.
- Made `build_https_connector_result` fully exception-safe so `Domain_name.host_exn` / `Invalid_argument` are reported as `Error _` instead of escaping.

### `lib/process/process_eio.ml`
- Removed the process-wide `Sys.chdir` mutation in the Unix fallback path; `create_process_env` no longer mutates parent CWD.
- Added deterministic child reaping (`SIGTERM` → grace → `SIGKILL` → `await`) for all `spawn_and_drain_*` helpers on cancellation/timeout.
- Restructured `run_argv_pipeline_with_status_split` so that a timeout reaps every pipeline stage before returning.
- Added `clamp_timeout_sec` to reject `nan`, `infinity`, negative, or zero timeout values and fall back to `default_timeout_sec`.

### `lib/runtime/runtime.ml`
- Converted the runtime singleton refs (`default_runtime_ref`, `runtimes_ref`, `keeper_assignments_ref`) from plain `ref` to `Atomic.t`, fixing cross-domain visibility races on OCaml 5.

## Out of scope (separate Blocker PRs)

- `process_eio_detached.ml` `Unix.fork` replacement → `masc/process-eio-fork-cleanup`
- `bg_task.ml` per-process OS-thread reaper → `masc/bg-task-thread-watcher`
- Full Unix fallback removal → `masc/process-eio-unix-fallback-removal`
- `Runtime.get_default_runtime_id` return-type migration to `Result` → left for a follow-up because it touches ~15 unrelated call sites.

## Verification

Touched targets build successfully with `scripts/dune-local.sh`:

```bash
scripts/dune-local.sh build lib/eio_context/
scripts/dune-local.sh build lib/process/
scripts/dune-local.sh build lib/runtime/
```

See `PR-CHANGES.md` for the detailed change log and skipped-item rationale.
