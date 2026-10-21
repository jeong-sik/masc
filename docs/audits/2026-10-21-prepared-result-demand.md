# Prepared continuation demand retains original result identity

Source As-Is/To-Be for an ordinary PR, not a measured latency result. The
server's owned-job completion observer discarded its original private record.
The shared prepared drain retained only a Boolean demand and every pass re-read
all pending continuations' result dependencies. This unit carries original typed
result hints through the actual producer callback, drain and journal selection.

| Boundary | Before | After |
| --- | --- | --- |
| Owned result notification | Record discarded; generic demand | Original canonical workspace, Keeper and typed job ID |
| Demand before a read | Shared unscoped pass | Immutable list of original result hints sharing one pass |
| New demand during discovery/observer | Fresh full pass | Fresh corresponding scope; maintenance promotes to full |
| Pending marker/authority checks | All original markers | Same full scan and original authority/retirement checks |
| Result readiness | Re-read every canonical wait | Re-read all dependencies of selected waits |
| Nonselected result dependencies | Probed as part of generic notification | Not probed; explicit `unselected`, full maintenance later |
| Lost continuation with no result binding | Original recovery | Conservatively included in either scope |
| Selected original intake | Fresh authority checks and lazy declarations | Same; hint is never result proof or effect permission |

`result_notification` is an immutable hint containing canonical base path,
Keeper and `Owned_job` or `Composition_result` identity. Exact coordinates and the
entire typed original dependency must match. It contains no stored candidate,
result or admission permit. The actual owned-job callback constructs it from the
original private Store.record after durable result/notification publication.
That delivery, wake and ACK ordering is unchanged. Composition hints are also
accepted by the shared API and actual resource scenarios; this unit does not
add a new hook to every composition terminal producer. Existing maintenance
continues complete recovery, including parent results without a direct hint.

A drain consumes only the pending scope captured before that pass. Further
notifications survive in the next scope while I/O/intake/observation yields.
Maintenance replaces pending hints with `All_pending`; counts never choose the
scope. Duplicate notifications remain in that temporary list and share a pass;
a private immutable set indexes exact workspace/Keeper/dependency keys once per
pass for matching. Its ordering never drives marker traversal or grants result
authority. No new global cache, durable reverse index, timer, arbitrary cap or heuristic. Failure,
raised/interrupted discovery and observer failure retain the existing cleanup
and durable recovery policy. Cancellation does not fabricate a returned pass.

Journal selection occurs only after the original marker, journal/source,
artifacts, canonical terminal and sealed waiting-continuation validation. Every
selected continuation then runs the unchanged complete readiness read and later
fresh intake admission, including original Task/Skill/resource checks. Existing
terminal-bound retirement is unchanged. Errors encountered before selection and
all selected-dependency errors stay visible. Unselected dependency failures are
not discovered by that notification pass; they remain for complete maintenance.
A hint is not allowed to turn an unread result into ready, waiting or success.

Existing Started records now identify all-pending versus result-notification
scope. Existing Settled records include inspected/ready/waiting/unselected/
retired/failure observations. Formatting stays in the existing lazy routine
thunk and emitted row frequency is unchanged. These counts are observations,
not limits, Task progress, admission success or physical worker-exit evidence.
The public discovery observer still receives the same typed `(unit,error)`
return. Logs gain fields/formatting work and result reports retain an additional
integer; no log wording, layout, snapshot, invocation-count or PTY tests added.

One additional authored end-to-end resource scenario starts a distinct second
job, rejects unrelated job/root/Keeper hints and an early hint, then resumes the
original named child and prepared parent from usable original outputs. It checks
the unrelated owner's real bytes and original job source/output authority.
Existing original-evidence hold/repair scenarios now supply the original job
hint. The existing real discovery-directory failure/partial-marker/observer
failure case supplies job and composition hints while maintenance still promotes
full recovery. These use real fixture paths/journals, public handlers and a
synthetic persisted Docker protocol peer; none was executed. They do not prove
real Docker isolation, physical overlap, actual scan savings or native TUI input.

Let M be canonical live waits, N notification rows in the consumed scope, D each
wait's sealed dependencies, and S the selected waits (plus dependency-free Lost
recovery). Before, result readiness was re-read for M waits per returned generic
pass. After, it is requested for S; all original marker/candidate scans still
happen. A private per-pass set folds N hints into K distinct exact typed keys,
with comparison work proportional to N log(K+1), followed by up to D log(K+1) lookup
work per candidate (typed key comparisons also have their own field costs).
Duplicate hints retain their temporary demand rows and construction work while
sharing an index key. Selected readiness still validates/reads every dependency.
`All_pending` creates no hint index and performs no hint matching. Declaration reads remain lazy per pass, only on eligible intake.
No runtime M/S, host I/O totals, worker queue delay, median/p95 or speedup is
measured. Failed/cancelled/interrupted/not-started/unfinished matched cohorts
remain in the original goal's required actual Before/After denominator.

Only six changed OCaml files passed parsing: two interfaces first, then journal,
wake, bootstrap and resource scenario. No type/warning/link/build/test/CI/native/
controller/model/PTY/TUI paint/input/runtime check. Exact source preservation and
direct-dependency evidence are separate from current-head independent review,
whole-stack approval and merge. All six original goal axes remain incomplete.
