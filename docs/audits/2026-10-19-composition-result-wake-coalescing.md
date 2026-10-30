# Coalesced original-result notifications for Composition recovery

Source baseline: `99ffcc08ffacaa1c33e96b8dccfe6df68d162c19` (#43835).
No job, test, model, controller, TUI or timing trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Each durable owned-job result callback | Direct full continuation discovery pulse | Request one controller-owned notification worker |
| Notifications before first discovery | Independent discovery per callback | One first read after yielding back to producers |
| Notifications while a read yields | Independent concurrent discovery pulses | One pending follow-up read; later arrivals remain demand for the next read |
| Result producer acknowledgement | Callback waits for direct discovery | Record demand; new notification worker yields before its discovery |
| Discovery/intake authority | Canonical journal and original owner/Task/node validation | Same authority on every fresh pulse |
| Maintenance and explicit recovery | Existing entrypoints | Same independent entrypoints |
| Timing, Task progress and effect success | Unmeasured/unverified | Unmeasured/unverified |

The existing owned-job callback runs after the original result and notification
are durable. It remains a lifecycle hint. A controller-local worker consumes
notifications already present before its read and preserves notifications that
arrive while that read yields. Errors still consume only that read's demand;
queued demand can request a subsequent read, while an error with no new demand
does not cause a retry loop. There is no timer, delay threshold, expiry, cached
discovery or replacement physical worker/job. Each pulse retains its existing fresh
declaration projection and per-intake metadata/Skill/original-authority checks.

With `K` notifications before the worker's first read, source scheduling requests
one discovery rather than `K`. A read with overlapping notifications requests
one fresh follow-up, which can receive more demand while it yields. This is not
a claim that an arbitrary ongoing stream always needs only two reads. Independent
maintenance can still overlap, and fast non-overlapping notifications can each
require a read. No runtime read count, ACK latency or useful-work speedup has
been measured. The process-local demand record/fiber/yield adds unmeasured cost.

Cancellation is re-raised. Cleanup clears only the same notification owner;
canonical durable discovery and future maintenance remain recovery sources.
Callers use the controller lifetime switch on its single Eio domain. This is
automatic result-driven Composition scheduling, distinct from operator resume
of a paused Keeper. Existing per-run active reservations, typed held evidence,
backend presence batches and exact durable owner/node CAS are unchanged.
Canonical ACK/cleanup retain execution phase, source and output references;
retiring completion discovery does not retire that original result evidence.

The switch is checked before reserving a notification worker: installed Eio's
`fork` can return without launching on a cancelled switch. One debug observation
after owned-slot retirement retains callback notifications, discovery starts,
settlements, errors, pending follow-up and drained/cancelled/raised/unfinished
boundary. Counts are logical calls, not distinct jobs or filesystem operations;
starts without settlement remain incomplete. A drained observation is not
physical worker exit, intake/effect success or paint proof. These counters never
control scheduling or effect admission, and no per-notification log is added.

The existing original-evidence repair scenario now enters through the same
notification scheduler, with pre-read duplicate hints and an intake-settlement
hint. It still uses canonical discovery, real original run/Task evidence,
unavailable run/Skill publication, repair and revalidation. Existing assertions
are retained; the scenario remains unexecuted. It is not a helper invocation,
wording/layout/row-order/snapshot/PTY test. It does not isolate a notification
arriving during filesystem discovery or prove cancellation timing. Parsing
establishes syntax only; typing, scenario continuity, runtime and timing remain
unverified.
