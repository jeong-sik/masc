# Exact payload cleanup: no-follow boundary

Goal: `goal-retention-accounting-20261022` (one confirmed deletion defect, not
completion of the retention-accounting Goal).

A separate parent-agent session ran a controlled native before fixture using
source `6475a2beb9d454be530baaf55430957dc4a5b9af`, executable SHA-256
`56f717348870a7e63485049515ab861d979ae5d74586a6bb0745570c7d9f6324`.
Its empty v6 registry and payload root contained an orphan directory link to an
entirely owned marker directory outside that workspace. Startup cleanup deleted
the 54-byte marker, then warned `could not remove payload files of orphan-link`
with `ENOTDIR` from `rmdir`. The marker was restored with its original SHA-256 and
that fixture server was stopped. No operational data was touched. The selected
receipt is [before-receipt.json](before-receipt.json); the original local receipt
is `/private/tmp/masc-exact-payload-symlink-observation-20261022/receipt.json`.
This PR writer inspected the receipt and sources, not the native experiment.

The current v7 source inherited the same dangerous chain: `Sys.is_directory`
followed a root-entry link, and `remove_files_in` enumerated/removes child names
through that path. Changing the generation name did not repair this boundary.
The first two observation layers deliberately did not claim that repair.

This layer reuses `Fs_compat.Retention_directory`: it opens every physical
component with `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, holds the root/run
parents across enumeration and unlink, and expires/closes borrowed handles on
exit. Only the already-admitted log parent is canonicalized to support workspace
aliases; the payload root and run directories are never granted authority by
`realpath`. A root link is unavailable rather than a successful empty sweep.
Root absence comes from the existing capability's missing-root result.

Two checked operations extend that existing module: direct `unlinkat(parent,
name,0)` and `unlinkat(parent,name,AT_REMOVEDIR)`. Only an actual successful call
returns true; `ENOENT` returns false, and other errors propagate. The old
best-effort age-prune APIs and consumers are unchanged. No file-type/mtime policy,
online eligibility or deletion command is added. The existing replay EOF/zero-
malformed gate, original retained digest names and warning templates remain.

Root-entry links and unreferenced leaf links can lose only their own name,
without traversing a target. Live eviction also binds run directories without
following links; a missing/non-directory run scope is not traversed. A failed
entry is counted once and prior successful effects remain. If traversal completes
but root-scope settlement raises, `Sweep_scope_failed` keeps those observed counts
and projects `scope_failure`, without counting a root-resource error as another
failed root entry. Scope cleanup keeps the callback's original exception and
backtrace when an I/O close failure coincides; the close failure is reported on
stderr. On a normal callback return, a close failure remains its original I/O
exception rather than `Fun.Finally_raised`, so the observing owner can distinguish
scope failure from entry failure. Cancellation is re-raised instead of producing
a sweep result. Simultaneous close-failure injection has not been executed.

This is per-pass descriptor confinement. It is not a boot identity lease,
atomic inode-conditional unlink, fsync/power-loss guarantee, or proof against all
uncooperative renames. A concurrent leaf/name replacement can change the entry
unlinked inside the held parent. A retained payload's read/validation contract is
separate from cleanup confinement.

Validation performed: changed ML/MLI/test parsing, C `-fsyntax-only`, whitespace
and direct dependency/consumer source inspection. Authored native fixture sources
cover root link refusal, orphan directory link, retained run-directory link and
unreferenced leaf link with actual owned marker-byte checks. Checked primitives
also cover acknowledged effects, repeated absence, a directory-unlink error and a
nonempty-rmdir error. Existing Eio cancellation fixtures now check the new APIs
reject an expired handle. Earlier clean/partial/refused-replay fixtures remain.

**No native after fixture, full typing/linkage, authenticated HTTP or installed
runtime validation was executed for this layer.** C syntax/parsing are not native
behavior proof; the real before result cannot be promoted into an after result.
No local Dune, operational lease, cleanup, deletion, deployment or restart was
performed by this implementation session.
