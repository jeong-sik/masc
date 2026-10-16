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
Other file inspection and deletion failures propagate to the maintenance caller.

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
