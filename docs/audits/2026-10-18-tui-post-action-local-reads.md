# Post-action local reads: source ownership and UI wait

Source baseline: `b0355fd6b04bab6686eaf51eea144f708e59752b` (#43622).
This unit changes source code; it does not establish installed behavior or speed.

## Before / after

| Trigger | Before | After |
| --- | --- | --- |
| Keeper creation accepted | Synchronous Keeper and Work directory scans | A fresh owned Keeper metadata job; no Work job caused by creation |
| Keeper lifecycle action returns | Both local scans on the UI callback | Independent fresh Keeper and Work jobs; separate HTTP roster refresh |
| Chat operation settles | Both local scans before queued-input continuation | Independent jobs; existing observed metadata and queued request identities remain held |
| Explicit refresh key | Both local scans before starting the HTTP refresh | Fresh source-owned jobs alongside HTTP refresh |
| Cadence during an active read | Share pending source ticket | Still share the pending ticket; no duplicate cadence worker |
| Late pre-action result | Synchronous refresh invalidates old tickets | Explicit refresh starts a new ticket and requests cancellation of the previous source worker; old results cannot spend the new ticket |
| Cancelled/failed cached read | Eio write helper poisons the source mutex when its callback raises | Release the lock, then re-raise the original exception/backtrace, permitting later reads |

All four former local-reload call sites stop calling the directory reader on the
UI/input callback. The synchronous `load_from_masc_dir` entry point is removed.
This is four changed source edges, not a measured count of runtime freezes.
Required data still needs reading; three triggers retain both reads as worker
jobs. Creation changes its directly requested jobs from Keeper + Work to Keeper.
The cadence/full HTTP collector can independently request Work.

`Snapshot_read.Poll` shares a pending read. `Refresh` starts a new source ticket,
without clearing last-observed rows, draft, queue or selection. Each worker has
its own cancellation token; an older worker's cleanup cannot clear a successor's
slot. Workspace suspension and local clear retire both request authority and
source cancellation owners. Source result admission retains workspace/base-path
checks and typed Keeper-versus-Work payload separation.

A same-workspace metadata observation remains available during revalidation.
This does not claim it is newer than the just-finished action. A newly created
Keeper is unavailable until its name is actually observed; its creation wait and
draft survive. On metadata admission, the existing handler resumes saved chat,
original Task handoff and pending input. Work completion cannot replay this wake.
A deletion request is acceptance; a later owned metadata read establishes absence
and the existing identity reconciliation leaves the removed detail safely.

The two cache mutexes protect incremental cache entries. Each cache update is a
complete entry replacement; a failed read can leave valid earlier entries but no
partially decoded value. The guarded callback returns its exception as data solely
to release the Eio write lock; the original exception and backtrace are re-raised
immediately afterwards, including cancellation. No failed reader is retried.
Installed Eio's `use_rw` source confirms its ordinary exception path poisons the
mutex. Runtime recovery remains untested in this unit.

## Evidence and limits

Changed OCaml files receive parser-only checks; whitespace and changelog checks
are separate. Four new state/resource scenarios are authored but unexecuted:
source-local supersession and old cleanup; created Keeper before Work; deletion
identity reconciliation; actual Eio cancellation and exception propagation with
a later reader using the same cache lock. Existing initial/source-owner fixtures
are adapted to an explicit read intent. No screen wording/layout/PTY tests.

Typing, scenario execution, real executor cleanup, installed/runtime behavior and
painted UI remain unverified. No CI or install is part of this unit. Shared pool,
cache-lock and mailbox contention plus added fibers/promises mean no total wait or
p95 improvement is inferred. The common pool-absent inline entry policy remains;
production launches install the pool. Other synchronous paths, including creation
HTTP and detail logs, are outside this directory-read change.

Frequent post-action refreshes supersede in-flight reads; no sustained-load
fairness claim is made. A follow-up should coalesce invalidation demand while
retaining post-action freshness and original source identity. Cache keys also
need exact base/path scope before multi-base-path use: the existing Keeper cache
keys by name and the archive cache matches size/mtime. These are remaining source
contracts, not measured failures in a fixed-base TUI.

## Measurement and full-goal continuation

A matched future authorized comparison should record action receipt, local source
dispatch, pool/cache wait, worker return, UI admission, first input availability
and paint separately. Keep failure, cancellation and unfinished attempts in the
cohort. Compare first-input and first-useful-tool p50/p95 plus full refresh time;
source-edge removal alone is not an elapsed-time saving.

Continue first-usable-input independence, exact Task/Skill/tool preparation reuse
and clear descriptions, nested/dynamic/effectful resource-owned Composition,
held-job shared backend batching, Ask-to-original-Task useful-work continuity,
and matched runtime/painted-UI Before/After. None of those goals is discharged by
this layer's source checks.
