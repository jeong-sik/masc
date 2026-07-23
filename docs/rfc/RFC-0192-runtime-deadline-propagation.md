---
title: Runtime deadline propagation — retired admission-wait proposal
rfc: "0192"
status: Retired
created: 2026-05-27
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0153", "0182"]
closes: ["18845"]
implementation_prs: []
---

# RFC-0192 — Runtime deadline propagation

## Retirement decision (2026-07-13)

The proposed cumulative admission-wait budget is retired together with the
MASC-owned runtime admission queue.

The original RFC correctly identified that stacking per-provider waits can
multiply latency. Its proposed fix still encoded a MASC-owned admission budget
and threaded that policy through every runtime attempt. Once provider capacity,
retry, and throttling are returned to OAS, that deadline no longer has a valid
MASC boundary to govern.

Current contract:

- a Keeper turn may carry its own explicit wall-clock deadline;
- provider-attempt timeout/progress belongs to the provider/runtime boundary;
- MASC does not reserve part of the turn for a queue wait;
- no minimum-useful-run cliff or synthetic admission timeout is derived;
- actual provider and turn timeout results stay typed and observable.

`Runtime_deadline` remains a pure explicit value helper where a caller truly
owns a deadline. It must not infer a queue, capacity, risk, or retry policy.

## Historical context

Issue #18845 observed roughly 147 seconds across five provider attempts. The
Draft proposed a shared deadline so repeated 30-second waits could not add up.
That was preferable to stacking timers, but it preserved the wrong owner: MASC
was still deciding provider admission.

The 2026-07-13 boundary cleanup removed the admission queue, its wait-time
configuration, its timeout/rejection error types, and the blocker/retry
derivatives. This RFC is retained only as the decision record explaining why
those deadline-plumbing fields must not be reintroduced.

## Verification

- No runtime configuration or dashboard field represents admission wait.
- No internal error, blocker, retry reason, or telemetry series represents
  admission timeout/rejection.
- `Runtime_deadline` accepts only an explicit caller-owned duration/deadline.
- Provider and turn timeouts still cross typed error boundaries.

## References

- Issue #18845 — historical accumulated provider-wait observation.
- RFC-0088 — counter-as-fix umbrella.
- RFC-0153 — historical runtime backpressure design.
- RFC-0182 — runtime context plumbing.
