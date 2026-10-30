# Exact-run startup observation

Goal: `goal-retention-accounting-20261022` (one observation gap, not Goal completion).

The exact-run registry preserves its existing typed replay result and its startup
payload-sweep result as one immutable construction-time observation. Reading it
performs no filesystem access, replay, payload loading, cleanup, or live census.
Subsequent registrations/completions do not refresh this observation.

The existing cleanup gate remains unchanged: only replay EOF with zero malformed
rows authorizes the existing sweep. Completed history remains bounded per lane by
the existing policy; this change adds no retention policy or online eligibility.
Compaction success is not observed. A clean replay is not a compaction receipt.

Sweep states distinguish not attempted, replay refused, root lookup absent
(`ENOENT`), root lookup/listing unavailable, and a visited listing. A non-directory
root is unavailable. Permission errors previously hidden by `Sys.file_exists`
are now observed and use the existing warning. A listing can race with filesystem
changes; the snapshot is neither an atomic filesystem inventory nor an assurance
that a later payload is retained or eligible for removal.

Counts describe actual successful operations, not bytes or estimated reclaim:

- `examined_root_entries`: entries in the root listing visited by the sweep.
- `unlinked_entries`: successful leaf unlink calls, including symlinks or other
  non-directory entries; not a regular-file count.
- `removed_run_directories`: successful empty-directory removal calls, separately.
- `failed_root_entries`: root entries whose sweep failed, once per entry.
  Successful unlinks before a later failure remain counted. Other root entries
  continue to be visited. The result is partial when this count is nonzero.

Warnings retain their original `exact_lane_run_registry:` text in the Keeper log:
`could not remove payload files of <run_id>`, `could not sweep payload entry
<name> under <root>`, or `could not list payload entries under <root>`. The
observation retains counts, not an unbounded list of paths or errors. Cancellation
is re-raised and prevents a completed registry from being returned; it is not
converted into a cleanup result. Live eviction still logs removal failures and
continues without rewriting the startup snapshot.

Validation performed: OCaml parsing of the modified ML/MLI and test source, and
`git diff --check`. Native fixtures cover clean removal/count units, absent and
unavailable roots, partial failure, immutable observations, and refusal after
malformed/torn replay. These fixture sources have **not been executed**. Parsing
is not type/linkage proof. No local Dune, runtime cleanup, lease, deployment,
restart, live diagnostic request, or filesystem inventory was performed here.

The subsequent payload-boundary layer replaces pathname deletion with the
existing no-follow directory capability, and adds `Sweep_scope_failed` to
preserve a completed traversal's counts if root-scope settlement fails. That
failure is separate from failed root-entry counts. The original first-layer
source checks are not execution evidence for the later protection layer; see
[its separate evidence](../2026-10-22-exact-payload-nofollow/README.md).
