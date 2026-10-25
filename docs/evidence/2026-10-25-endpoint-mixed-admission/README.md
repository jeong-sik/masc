# Mixed endpoint admission conformance

Source baseline: main `3cce9a517b25863c00b48cfb3dd79b994ebc1044`.
Issue: #25910. Only tests, registration, evidence and changelog change.
No production endpoint/capacity policy is added or changed.

## Current production boundary

Provider_admission keys a declared allowance by exact kind, URL and credential
identity. An undeclared max is direct dispatch, including when another config
on that identity published an allowance. Ordinary Complete, outer exact flow
and an HTTP Fusion seat reach this shared boundary. The exact inner wire config
clears its max to avoid nested admission; testing a bare low-level exact plan
would bypass the intended public flow boundary.

Existing unit tests exercise the scheduler and a Complete custom transport.
They do not establish simultaneous ordinary/exact/Fusion HTTP behavior. This
new feature fixture uses real local TCP peers and public production entrypoints.
It does not use an official CLI seat as a substitute for HTTP admission.

## Scenarios defined

1. Runtime declares max=1 for account A. Its first ordinary request is held
   by the peer. Actual exact (a different model) and Fusion requests queue;
   a third queued exact request is cancelled before HTTP. Another endpoint
   and another credential complete while A is still held. Releasing the peer
   lets all three producer routes complete with peak one for the primary
   account. Each route then receives actual HTTP429 and succeeds on a fresh
   call; local permit and queue snapshots return to zero.
2. Runtime declares no allowance. Exact and Fusion complete while the first
   ordinary HTTP request remains held. No admission scheduler is created;
   another endpoint still progresses. This proves the explicit None contract
   rather than treating an undeclared endpoint as having an inferred limit.

Barriers use promises and observed queue/request state, with no fixed sleeps
or elapsed-time pass criteria. Exact's required transport deadline is explicitly
120 seconds; it is not the synchronization or asserted performance boundary.
The peer speaks Chat JSON or SSE according to the actual request and echoes
its requested model. OpenAI-compatible generation is the selected protocol;
this fixture does not certify other codecs' count-token traffic.

## Source review and evidence limits

Adversarial review caught two fixture errors before execution: ordinary Complete
returns Http_client.http_error (not provider Error.t), and the public exact flow
requires an explicit body deadline. Both were corrected. The fixture writer's
Result is checked. The candidate uses current-main public interfaces, including
the then-required resolver IO argument; it has no compatibility adapter.

The new OCaml file parses, and whitespace checks pass. No local Dune, typecheck
or test execution was run. Focused execution will be requested after publication.
Source fixture definitions are not successful conformance evidence.

Full #25910 acceptance remains distinct: provider-reported capacity/probe health,
the historical live operator4/reported2 condition, wait/watchdog separation,
whole-tool-turn permit ownership, active cancellation/body-timeout coverage,
live mixed fleet behavior and deployment are not proved by these two cases.
No new Fusion/per-lane cap or numeric runtime gate is introduced.
