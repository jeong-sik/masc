# Date-sharded Keeper metric retention

Base: #41096 at `c1aae1d3ad6822bd5a59fbe86da9c98ad7a47c9e`.

The existing auxiliary JSONL rotation settings do not govern the date-sharded
turn/heartbeat metrics store. The new typed registry setting
`metrics.store_max_bytes` defaults to zero (retain all). Its value is captured
once when a Keeper's cached store opens; TOML changes require restart.

Turn and heartbeat producers call one `append_keeper_metrics` operation.
Its storage owner derives a half-target file size from the captured total
byte target, leaving space for a completed segment alongside the current one.
Dated_jsonl handles rotation and oldest-first completed-file pruning. Existing metric readers
use the same cached store and continue reading retained segments. The new
setting is independent of auxiliary log backup counts.

A positive target removes whole completed files after a new row is appended.
The current row survives even when it alone exceeds the target. Cleanup is
best effort under existing filesystem-error behavior; this is not a hard
filesystem quota or a promised number of retained records. Explicit append
refusals raise Sys_error and reach the existing metrics failure handling.

## Executed checks

- All 16 registered storage scenarios pass: eight each under real Stdlib and
  Eio filesystem paths. Tests cover unlimited defaults, continued writes after
  rotation, old-day pruning, a smaller target on reopen, oversized rows,
  per-Keeper/auxiliary-store isolation, append refusal and I/O recovery.
  The complete current Dated_jsonl and new storage-owner modules were compiled,
  with cached lower dependencies. No filesystem behavior is mocked.
- Four native boot-to-storage probes pass with the real Keeper_runtime_config
  loader and registry: unset keeps all, TOML affects actual rotation/readback,
  process env overrides TOML, and negative TOML is rejected.
- Eleven changed OCaml files pass parser checks. The broader Keeper typecheck
  attempt (before the segment-size refinement) stops at a cached Workspace/Fs_compat interface mismatch inherited
  from the parent's added filesystem API. Earlier scratch attempts first
  exposed that missing API; rebuilding its immediate interfaces reaches the
  same stale-cache boundary. Do not treat this as a complete caller typecheck.

`check-dated-metrics.py CHECKOUT CACHE_CHECKOUT` runs the storage suite with an
existing OCaml 5.5.1 cache and prints a scratch directory. Pass that directory
as the third argument to `check-dated-metrics-boot.py`. The second probe opens
the storage owner from the real setting reader; it does not execute the whole
Keeper factory. Source hashes, raw results and the generated setting schema
are included.

## Remaining evidence

The registered public factory/TOML regression is authored and parsed, not
executed. Full Keeper caller typechecking, the whole runtime-TOML suite,
independent current-head review and deployed behavior remain unverified.
No local Dune/full build, CI, production-file mutation, restart or deployment
was performed. Independent review agents were unavailable due to usage limits.
