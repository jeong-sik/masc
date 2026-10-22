# Retention pruning

Startup and the periodic maintenance pass call the same
`Server_runtime_startup_maintenance.prune_jsonl_at_resolved_window` entrypoint.
The operator window still comes from the existing environment, runtime TOML and
default resolution. Dated stores keep their declarations in
`Dated_jsonl.Store`: operator windows, fixed windows, store-owned settings and
permanent retention remain distinct. Flat stores keep their existing filename
and mtime rules, including numeric `.jsonl.N` rotation siblings.

The pass resolves the configured **BasePath** through the existing physical
path resolver. This supports configured workspace links and system aliases such
as `/tmp` and `/var`. It then binds the runtime-root entry, normally `.masc`,
without following it. It never calls `realpath` on a runtime descendant to
authorize pruning. Every subsequent directory component is opened relative to
its held parent with `openat(O_DIRECTORY | O_NOFOLLOW)`; names are read from
that descriptor. A linked child is skipped. A linked runtime root is refused.
Directory opening and enumeration failures propagate to the maintenance caller.
A single leaf's inspection or deletion failure instead reports its path and
errno, leaves the entry for a later pass, and does not count it as removed.
Later entries and stores continue applying their retention policies. Diagnostic
paths describe the admitted spelling and never authorize a filesystem operation.

Date-split, keeper-scoped and generation-scoped locations follow the existing
closed store geometry through those handles. Location strings remain lock keys
and diagnostic labels. The existing per-store Eio mutex stays on its fiber;
the filesystem facade offloads blocking operations individually. Pruning never
reopens a selected location through its pathname. The same capability also
protects individual `Dated_jsonl.prune` calls.

Only regular entries qualify. `fstatat(AT_SYMLINK_NOFOLLOW)` checks the entry
and `unlinkat` removes its name relative to the held parent. A link target is
never opened or deleted. If an ancestor name is renamed and replaced with a
link after binding, the held directory still owns the operation. Handles expire
on normal completion, exception and cancellation, before their fd can be reused.

This is **per-pass physical identity**, not a boot-pinned root lease. Replacing
the root with a different real directory before admission remains a separate
ownership question. POSIX also provides no atomic inode/mtime-conditional
unlink: a concurrent leaf replacement may remove that replacement entry inside
the owned parent. The operation still cannot follow a replacement link to its
target. File-removal counts do not claim fsync or power-loss durability.

The initial bounded verification executes the complete new descriptor and
calendar owners, their real C primitives, the exact filesystem facade in Eio,
and cancellation. The full `Fs_compat`, `Dated_jsonl_store`, `Dated_jsonl` and
server owners and their integrated regression fixtures are authored/source
checked but were **not compiled or executed** in that verification: shared
dependency artifacts were unavailable, and no SDK/Dune dependency rebuild was
performed. The ordinary source review, CI, installed runtime and periodic timer
execution remain separate evidence layers.

This repair addresses the startup/periodic age-prune members of
[#25863](https://github.com/jeong-sik/masc/issues/25863). PID/listener takeover,
checkpoint ownership and boot-pinned root continuity remain separate members of
that umbrella; this pruning change does not establish their completion.

## Exact lane payload startup observation

Exact lane payload retention is a separate owner from the dated-store age prune
above. Its existing registry keeps the latest completed runs per lane plus active
runs, then sweeps payload names only after a replay that reached EOF with zero
malformed rows. The read-only diagnostic is:

```text
GET /api/v1/dashboard/exact-lane-run-retention
```

It uses the existing token-bound **Admin** permission and GET read quota. As with
other workspace-bound reads, supply exactly one `expected_base_path` and one
`expected_masc_root` query value to bind the response to the intended workspace.
Matched admission carries `x-masc-workspace-read: matched-v1`; foreign roots return
409 and malformed/partial/repeated preconditions return 400 before the handler.
Omitting the pair retains the existing unbound-read behavior. Authentication,
quota accounting and workspace admission remain middleware effects; the handler
reads only the registry's immutable startup observation. It does no filesystem
access, replay, payload loading, cleanup or lease acquisition. It does not change
`GET /api/v1/dashboard/exact-lane-runs` or its strict list schema.

`scope` is `process_startup`. `replay` uses the existing typed result:
`not_replayed`, `log_absent`, or `replayed` with `lines_read`, `malformed_lines`,
`dropped_running` and `reached_end`. `dropped_running` is the core replay counter,
not a count of exact runs settled on restart. A running exact run may instead be
retained with the existing server-restart terminal result.

`payload_sweep.status` distinguishes:

| Status | Meaning |
| --- | --- |
| `not_attempted` | Constructed with `create`, without a startup sweep. |
| `replay_not_trusted` | Existing replay gate did not authorize a sweep. |
| `root_absent` | The payload-root lookup observed `ENOENT`. |
| `root_unavailable` | Root lookup/listing failed; inspect the existing Keeper warning. |
| `completed` | Every listed root entry was visited without an observed failure. |
| `partial_failure` | At least one listed root entry failed; earlier successful effects remain counted. |

Only the last two states carry counts. `examined_root_entries` is the visited
root-listing length. `unlinked_entries` counts successful `Sys.remove` calls,
including symlinks and other non-directory entries, **not regular files or
bytes**. `removed_run_directories` counts successful `Unix.rmdir` calls separately.
`failed_root_entries` counts a failed root entry once even if successful unlinks
preceded its failure. Other entries continue. These counts describe syscall
acknowledgements, not fsync/power-loss durability or physical space reclaimed.
An empty listed root completes with zero counts; an absent root does not invent a
zero-removal receipt. Root lookup/listing and later removals are not an atomic
filesystem snapshot and retain the existing path-based sweep authority.

`compaction.status` is always `unobserved`: EOF and sweep completion do not prove
compaction succeeded. `failure_log` identifies the original Keeper warning
prefix/templates rather than retaining an unbounded failure/path list. Query it
alongside the server's health identity when attributing a process observation.
After startup, new runs, evictions and filesystem changes do not update this
snapshot. It cannot classify today's retained/eligible/unknown bytes, establish
that all payloads are readable, or authorize an online deletion. No new retention
policy or cleanup command is provided.

Source/parser checks and authored fixture coverage are recorded in
[the startup observation evidence](../evidence/2026-10-22-exact-run-startup-observation/README.md).
Native tests, authenticated HTTP integration and installed behavior are separate
validation layers and were not executed during this implementation.
