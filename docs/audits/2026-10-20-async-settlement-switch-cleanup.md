# Closed request registration after terminal notification cancellation

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Physical request scope | Closed before terminal publication | Same boundary |
| Durable terminal success | Removes runtime pending/transition reservation before notification | Same authority and order |
| Post-worker notification raises cancellation | Skips the following switch-table removal | Finally retires the closed registration and propagates cancellation |
| Cleanup mutex acquisition | Can be cancelled while waiting despite `use_rw ~protect:true` | Entire acquisition and table removal are protected |
| Original result and abort callback | Completed worker owns its result | No reclassification as aborted or failed |

The confirmed defect is retained bookkeeping after exceptional post-worker
settlement. No executing-lane hold by a completion notification was established:
the request switch already closed, and successful durable publication already
removed its runtime row. Cleanup stays after publication/notification in the
successful path. Moving it earlier could change operator cancellation against a
still-Running record. This change adds no async notification service, timer,
retry, worker or reconstructed request.

The finalizer performs only the existing mutex/table bookkeeping. Protection
now covers contention while acquiring that mutex, adding a cancellation mask
and potentially waiting for the lock during shutdown. It does not repair an
already poisoned mutex or claim that the finalizer cannot raise. Storage,
callback, canonical terminal and physical release boundaries remain distinct.
Ordinary projection exceptions remain observed/isolated; structural cancellation
still propagates. No latency reduction, earlier physical release or useful Task
progress is inferred from the missing-registration fix.

An authored, unexecuted compound scenario uses real durable async submission and
an actual request switch. A promise gate allows acceptance before completion.
The request releases its scope; its terminal callback fails/checks the owning
background switch. After that scope joins, the scenario checks structural
cancellation, physical release before notification, no abort reclassification,
the original canonical Done body and all ownership fields, exact durable
settlement identity and empty physical switch registration. It introduces no
fake request operations, invocation counter, polling or timer. This occupancy
assertion covers resource retirement alongside original protocol/result truth.

Three changed OCaml files receive parsing-only checks. No typing, warnings,
linking, build/test execution, CI, native/model/PTY run, installation, restart,
live write, independent approval or merge is established.

All six goal axes remain open. Matched actual Before/After must retain successful,
failed, cancelled, interrupted, not-started and unfinished samples; distinguish
physical release, terminal commit, notification, registration retirement and
original Task progress. This source correction is no runtime measurement.
