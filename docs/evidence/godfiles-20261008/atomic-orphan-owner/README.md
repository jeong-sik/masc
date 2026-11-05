# Atomic orphan ownership, 2026-10-08

`Atomic_write` owned publication and a separate boot-time orphan inventory with
hard-link preservation. The sweep never needs the publication machinery: it
shares only the atomic-temp filename grammar and the existing owned-path checker.
It now lives in `Atomic_orphan_cleanup`, a blocking effect owner that returns
all decisions and failures. `Atomic_temp_name` owns the pure prefix/suffix
predicate consumed by both writer entrypoints, the sweep, and the public matcher.
The existing public `Fs_compat` interface binds directly to those owners; the old
internal `Atomic_write` orphan API is removed without forwarding aliases.

The entire cleanup block matches its parent after replacing only the matcher
call; [extraction.json](extraction.json) records the comparison and base SHA.
`Atomic_write.ml` falls from 3,327 to 2,773 lines. The extraction does not constitute
an audit of its remaining capability publication/reconciliation and ordinary
replacement responsibilities. `Fs_compat`'s other bridges remain pending too.
The campaign retains all initial 171 candidates.

## Preservation and ownership

The sweep still scans exactly the owned base directory. It rejects symbolic-link
ancestors and orphan-shaped non-regular entries, deletes empty regular orphans,
and preserves non-empty evidence without overwriting collisions under
`.recovered/root/`. Inode checks, hard-link/unlink ordering, fsync calls, typed
failure accumulation and cancellation handling are unchanged. No telemetry or
lifecycle policy is moved into the leaf.

The caller must own stable path identities and quiesce matching temp writers.
Portable Unix path operations cannot atomically protect against replacement of
intermediate ancestors. This extraction does not strengthen that precondition.
Keeper and Fusion already call the public sweep from their systhread boundaries;
those owners and their metric/report consumption are unchanged.

## Executed checks

The operator authorized narrow local checks. [checks.json](checks.json) records
commands and terminal exit codes.

| Changed interface | Actual consumer and verification | Result |
| --- | --- | --- |
| Orphan types, sweep, formatter, public matcher | `Fs_compat` API through `test_fs_atomic_orphan_sweep_10130` | 11 existing cases passed; [sweep.log](sweep.log) |
| Shared writer filename grammar | ordinary and streamed `Fs_compat` atomic writes, temp-channel acquisition through the `save_file_atomic` group of `test_fs_compat` | 14 existing cases passed; [write.log](write.log) |
| Internal module graph and public type manifests | focused build of those two executables | Exit 0; [build.log](build.log), empty successful build output |

The sweep cases cover empty deletion, evidence preservation, unrelated files,
idempotence, mixed inventory, both symlink boundaries, non-regular entries,
collision preservation, and retained source after recovery-directory failure.
The writer cases exercise strict before/after-rename failures, cancellation,
streaming callback failure, execution outside the fiber, raw-byte preservation,
and the actual temp-writer/public-matcher pairing. Filtered skipped cases are not
included in the 25 executed cases. No new implementation-mirroring tests were added.

The checks use isolated temporary directories. Production Keeper/Fusion startup,
real process-kill recovery, power-loss durability, full CI and deployed runtime
behavior are unverified by this slice.
