# Reject cancelled recovery scopes before reserving original workers

Source baseline: `240191a2444b898a303f0ec266e4f9a3552304cc` (#43837).
Scope: automatic owned-job completion and Composition continuation pulses.
No recovery/controller/test/model/TUI or timing trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Cancelled but unfinished switch in protected cleanup | `fork` can return without launching its callback | Explicit switch check before discovery |
| Original job/run reservation after discovery yields | Active slot set before `fork` checks switch state | Recheck immediately before each new reservation |
| Declined fork with no callback | Active slot has no finalizer to release it | Rejected scope cannot create that reservation |
| Subsequent healthy scope on same controller | Falsely active original can be skipped indefinitely | Original pending marker remains eligible for normal recovery |
| Journal, original Task and effect authority | Exact canonical evidence and per-owner validation | Same canonical evidence and validation |
| Runtime/UI/latency | Unverified | Unverified |

Installed Eio `core/fiber.ml` checks the switch's domain, then enters the callback
only while its cancellation context is on. A cancelled but unfinished switch can
therefore return from `fork` without an exception or callback. Both old pulse
implementations inserted an active job/run before this call, removed it only in
the callback's finalizer or a thrown exception, and could retain a false active
slot when invoked from protected cleanup. `Cancel.protect` does not reactivate
the supplied switch. A finished switch already throws; that case alone would
not demonstrate the silent-decline bug.

Checks now precede discovery and every reservation. The latter closes the gap
where discovery yielded after entry validation. These are single-domain Eio
controllers, with no yield between reservation validation and local reservation/
fork. Cancellation propagates as cancellation, not a storage/journal error or
successful pulse. No canonical owner is replaced, no active/held state is broadly
reset, and no timer, timeout, parallelism cap or configuration knob is added.

Source quantification: an invalid pulse could reserve eligible original jobs/runs
without workers; the rejected entry now creates zero such slots. This is a state
transition comparison, not a measured Loading delay or throughput result.

Two existing compound scenarios now attempt real canonical recovery on a cancelled
unfinished switch under protected cleanup. The same controller subsequently uses
a healthy scope: the original job retains its journal and independent completion
delivery while another backend is blocked; original continuations retain both
Task-bound waits and fresh declaration behavior. Assertions inspect canonical
evidence and lifecycle outcomes, not helper calls or UI layout/wording/row order.
The scenarios are authored and unexecuted. They do not isolate cancellation that
occurs inside discovery or establish actual scheduling/latency behavior. Parsing
proves syntax only; typing, scenario/runtime/input/paint and useful work remain
unverified.

Resource tracing found shared Domain_pool I/O policy and the Process_eio spawn
guard. The installed Fd_accountant guard observes usage/errors rather than proving
an end-to-end process concurrency ceiling. Structured reconcile and automatic
pulse scheduling differ. This layer does not resolve that separate fanout question
or claim it caused the reported live Loading behavior.
