# Reactivate Connector status after a write without waiting for old names

Source comparison base: `43cf21a4ff14510e82874726fed872d9e5af69f3`
(#43887). This layer connects original request/demand retirement to the actual
structured observation job and its cleanup, rather than treating a UI slot
reset as a finished worker.

## As-Is / To-Be

The preceding layer delivered status before directory names. But a binding
write during `Names_pending` only queued a follow-up: `begin_read` shared the
active request until every old name chain finished. Thus the fresh status
needed to observe that write still waited behind obsolete metadata work.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Write during names | Queue until final directory result | Retire that request, request cancellation of its exact observation, admit fresh status |
| Write before status application | Queue until aggregate finishes | Coalesce before status; on status application retire old names and admit fresh status |
| Physical ownership | Read owner and unrelated generated registry token | Same original physical owner keys both request and observation job |
| Cancellation scope | Workspace/read withdrawal only | Also exact Connector observation retirement; other reads/effects untouched |
| Original cleanup | Registry owns worker until cleanup | Same invariant while fresh status may already be observed |
| Old result/start callback | Exact owner rejects retired result | Same rejection; retirement occurs before requesting cancellation |
| Last observation | Retained across withdrawal/failure | Retained while old cleanup and new read overlap |
| Failure of replacement | Held demand, no immediate retry | Same behavior; cancellation is not a successful read or retry trigger |

## Functional core and effect edge

The private immutable core distinguishes `Pending_status` (with coalesced later
write demand) from `Pending_names` (whose status was already received). That
avoids an impossible names phase carrying a queued-write flag: a write there
retires it immediately. `after_write` and `status_received` return typed
`No_retirement` or `Retire original_request` decisions. The edge first records
held demand, then requests original-job cancellation and admits the fresh read.
Repeated writes before status application share that status request; once it
arrives they require one fresh read, without waiting for its directory result.

The opaque request's existing owner is also its job key. There is no new request
counter, cache, timer, timeout, concurrency cap, retry knob or mutable handle map.
Same-workspace recovery, confirmed-root reset, start-failure release and failed
reread demand retention keep their prior boundaries. A failure before status
may still deliver the queued follow-up through the existing final-result path;
a cancelled names attempt is retired and cannot satisfy its replacement.

`Masc_tui_workspace_job` is the single source of the existing fork/registry
implementation, moved out of private Main so the actual boundary can be used
in a compound resource scenario. Main retains its existing function alias and
all existing callers. The default allocation, workspace and observation
registries, local cancellation exception, pre-dispatch withdrawal, synchronous
failure cleanup and actual-worker `finally` are retained. Only Connector
supplies a key; other calls still allocate their own fresh token.

The JSON/result launch wrappers pass that optional key through the same job.
`cancel_observation` searches only the observation registry with physical key
equality, never structural equality of unit refs and never the full effect
registry. Missing registration is a no-op, not proof of cleanup. Requesting
cancellation does not remove the entry; the original worker's `finally` does.
The new read uses the existing switch, HTTP/cache receipts, Eio children and
shared IO/CPU resources. An older pool worker's cancellation/cleanup contract
is unchanged; it is not re-executed on a cancellation or effect exception.

The new module interface is written first. New/renamed private control variants
and retirement decisions are internal OCaml data, not JSON/dashboard/TLA+
domain literals. No public endpoint, wire enum or configuration key changes.

## Quantitative Before / After limits

Without a write, nominal explicit GETs remain **P + 1 -> P + 1** and the read
still delivers original status followed by final names. During a write, both
attempts and every interrupted/cancelled page must be retained. The number of
old pages already attempted, how promptly cancellation reaches IO/CPU work,
and replacement pages depend on the actual interleaving. No fixed request
saving or speed percentage is asserted.

Before, fresh status eligibility followed old directory completion. After, it
follows the actual write receipt if status was already applied, or application
of the queued original status otherwise. Original cleanup remains separately
owned and is not a prerequisite for scheduling the fresh observation. Existing
resource contention, backend admission, cache/304 work, mailbox scheduling and
paint remain outside that source dependency claim. No runtime measurement or
separately painted frame is proven.

## Authored resource scenario, not executed

A fourth compound scenario uses the actual shared job module, Eio switch,
cancellation contexts/promises, open file descriptors and temporary persisted
Slack binding store. It covers both status delivery before a write and delayed
status delivery after a write:

1. The original worker opens a real resource, reads the real pre-write binding
   descriptor and blocks. Another observation and an effect job own separate
   real resources in the same switch.
2. Change the actual binding, obtain the production core's retirement decision,
   and request cancellation through its original physical job key. Hold the
   original worker in protected cleanup using a semaphore.
3. Check that its real descriptor is still open and its owner remains in the
   registry; unrelated read/effect resources and ownership remain present.
4. Start a fresh worker through the same production module and observe the
   actual post-write member while original cleanup remains held. Reject both
   old status and names against that fresh request; the fresh result settles
   without inventing another retry.
5. Release cleanup and leave the switch; only then require the old descriptor
   to be closed and its original registry owner gone.

The preceding operation-preserving names scenario still uses actual bindings,
decoding/projection and its exact conditional unbind target; its later write
now follows the successful enrichment. The new resource scenario covers writes
while original metadata is blocked, whose old result is now retired. Existing
demand/reconfirmation scenarios retain their scope with typed retirement output.

All scenarios are authored and **unexecuted**. Identity records and blocked
directory IO are controlled fixtures. Actual HTTP/cache, production loader
transport, executor pool workers, private Main routing, model, terminal and
paint are not executed. Parsing is not typing, compilation or behavior PASS.
No layout/wording/row-order/snapshot/PTY/helper-mirror/invocation-count tests
are added. Source transfer comparison is evidence about the inspected diff,
not a new source-pattern or invocation-count test.

Later matched Before/After must include original and replacement request/job
ownership, real write receipt and membership, status eligibility/application,
cancel request, actual cleanup, and every failed/cancelled/interrupted/unfinished
attempt. The full six-part Ask/Task, preparation, Composition, held/shared batch,
input/visibility and matched actual evidence goal remains open.
