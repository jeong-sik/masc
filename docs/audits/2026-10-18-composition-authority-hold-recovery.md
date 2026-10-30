# Original Composition evidence recovery

Source baseline: `de61e0a66b8d135576221b98864d3d7bcf2bc4e0`.
Review base: `74383364ae996e7411d4c81510cc9c337864226e` (`main`).
The three changed OCaml source files are identical between that base and the
comparison baseline before this patch.
Scope: process-local continuation scheduling hints and pre-intake evidence repair.

| Boundary | Before | After |
| --- | --- | --- |
| Original run artifact unavailable before intake | A text callback holds the same request until explicit recovery or controller restart | Typed original-run hold; exact sealed run readability can request fresh original validation |
| Task Skill source unavailable before intake | Same-request hold suppresses later automatic intake even after a repaired publication | Typed failure retains its published snapshot revision; a different configured publication requests revalidation |
| Skill files restored without publication | Original authority remains unavailable | Still held; file restoration cannot replace the published projection |
| Worker/surface authority or unknown-effect failure | Explicit repair required | Typed explicit-recovery hold; neither run readability nor a Skill publication permits automatic retry |
| Unchanged hold | No repeated physical intake | Read-only evidence probe only for recoverable holds; no declaration preparation or physical intake until release |
| Released hold | Operator/restart can attempt original intake | Same original request/run/Task is revalidated through the existing admission and owner/node CAS |
| Diagnostics | Text hold reason plus a universal explicit-resume instruction | Typed waiting-original-run, waiting-Skill-publication or explicit-recovery state; evidence-change/revalidation is distinct from accepted work |

`Original_run_unavailable` is produced only by the pre-intake exact run-artifact
reader. Its probe uses the same integrity/owner/invocation binding and the common
I/O executor policy. It does not create an activation, worker or job.
`Task_skill_publication_unavailable` is produced only by original Task Skill
resolution before surface intake. Its recorded snapshot revision is a change
hint, not execution authority. The next intake reads current declarations,
metadata and publication and resolves the original Task references again.

Existing surface and worker hold callbacks become `Explicit_recovery_required`
at the maintenance boundary. These include journal/owner conflicts, original
child admission failures, frozen draft rejections and interrupted/unknown
execution. Their diagnostic strings never choose a recovery action. Changing
files or publishing Skills cannot release them automatically.

Each run reserves one intake/probe fiber until it settles or is cancelled.
Read-only probes run in that fiber rather than joining the maintenance pulse.
Unreleased probes do not force the pulse's shared declaration projection or
report a new intake result. Exact request changes discard only the process-local
hint; durable journal admission still determines execution. No retry timer,
timeout, TTL, numerical cap, replacement Task or automatic effect replay is added.

Two feature scenarios are authored and unexecuted. Both use the real named
producer, owned job, durable child/parent waits and original Task selection.
After canonical discovery, one detaches the exact original run artifact; the
other publishes a non-directory Skill source. The first real preflight must
report the typed hold. Unchanged evidence must start no further intake. Restoring
the exact run, or restoring the original Skill bytes and publishing the repaired
snapshot, must allow the same supervisor to revalidate the child and let its
original parent consume the result despite a different current Task. Both check
that recovery consumes saved results without another backend call. Existing
explicit-recovery scenarios retain their hold-until-recovery behavior.

Parser/source checks do not prove typing, scenario behavior, executor
cancellation, real Docker, installed/runtime/UI behavior or latency. No runtime
scenario was executed and no faster resumption is claimed. Matched comparison
must distinguish evidence restoration, publication, revalidation, worker
acceptance, canonical result and the parent's first useful work, retaining
failed/interrupted/cancelled/unfinished attempts and original identities.

Remaining scope includes original Ask-answer-to-Task progress, additional
demonstrated preparation duplication, remaining synchronous TUI editor actions,
full readability/visibility scenarios and matched runtime/painted-UI evidence.
