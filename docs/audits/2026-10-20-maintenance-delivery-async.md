# Independent maintenance delivery drains

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Startup Goal effects | Join Goal audit/notification drain before Composition/job/Ask recovery | Reserve Goal worker, then continue |
| Periodic explicit mentions and Goal effects | Join both drains before independent recovery and cleanup | Reserve independent delivery-kind workers |
| Same delivery kind | Existing complete serial drain | Same drain and locks; coalesce pulses while active |
| Original workspace | Read current config for each invocation | Capture current config at reservation; active worker cannot retarget |
| Goal authority | Durable audit/notice, first recipient snapshot, exact transcript/recipient ACK | Original flush unchanged |
| Broadcast authority | Authoritative enumeration, message sequence, target predecessor barriers, exact row/ACK | Original reconciliation unchanged |

Goal delivery is informational recipient projection: it does not evaluate,
enqueue work or wake Keepers. Explicit mention recovery retains its separate
intake/wake behavior. Independent kinds may interleave their workspace writes;
the authoritative message store still assigns actual sequence. No internal
Goal notice/recipient or explicit-mention ordering is changed. Ordinary producer
flushes/reconciliation and their synchronous API semantics are unchanged.

One server-lifetime supervisor reserves a worker per kind under the existing
server switch. Workers yield before the original drain, retain their active
reservation through result observation/cancellation cleanup, and reread durable
work each round. A pulse while active is coalesced; later work or a new workspace
waits for a later pulse with its fresh config. No pending rows, earlier result or
current recipient are borrowed to authorize delivery. Cancelled/finished switches
are rejected before reservation/fork; failed scheduling releases its reservation.
Structural cancellation propagates; unexpected exceptions leave durable sources
for later recovery without fabricating a settled result. Shutdown can still join
protected physical I/O. Earlier transition projection, all discovery, per-kind
serial waits and shared CPU/I/O/lock pressure remain.

Three normal routine events record reservation, drain start and drain return.
Kind plus reservation monotonic clock links them; the reservation event carries
the original base path. The result observer also receives that original base
path explicitly. These process-local clocks do not compare across process
restarts. Drain return precedes existing result logging, observer and active
cleanup; a later interruption can therefore follow a settled event. Neither
settled nor an ACK proves worker exit, Keeper consumption or original Task work.
Routine suppression skips formatting/emission, not the new workers, state or
clocks. No question, answer, transcript or notification content is added to logs.

Costs include child fibers, two active flags, config capture, clock reads and
optional phase logging. Empty outboxes now also incur scheduling work. This
changes dependency joins; it establishes no physical parallelism, speedup or
usable-input latency. There is no new pool, timer, timeout, retry interval,
recipient cache or effect replay.

## Authored scenario, unexecuted

An actual Goal proof commits its pending notification while the host is absent.
An actual workspace message commits its explicit-mention outbox with the normal
host-unavailable outcome. Recovery uses the production Goal recipient backend
and production mention delivery implementation. Holding the real Goal delivery
lock, reserve both kinds and await the original mention transcript/authoritative
ACK while the Goal notice remains pending. Release the lock, join the Goal drain
and check exact original notice identity/content in its snapshotted transcripts.
Fresh rounds must preserve one original transcript per delivery and the original
Goal phase. This uses no replacement drain, helper invocation counter, polling,
timer or screen assertion. Repeated active pulses are exercised; the scenario
does not directly count live worker reservations.

Four changed OCaml files receive parsing-only checks. No type/warning/link/build
or test execution, CI, native/model/PTY/controller run, install/restart/live write,
independent source approval or merge is established. Workspace-switch refusal,
cross-process lock stalls, cancellation cleanup, source ordering under concurrent
producers and actual server-loop overlap remain unexecuted.

All six original axes remain open: original Ask/Task useful work; exact preparation
and frozen discovery reuse; ordinary/nested/dynamic/effectful Composition;
held-job/shared-backend continuation; cold usable input and TUI readability/
visibility; matched actual Before/After. Matched cohorts must retain failures,
cancelled/interrupted/refused/not-started/unfinished samples and include new
scheduling/observer/cleanup costs. Source joins are no elapsed-time measurement.
