# Preserve original Task display preparation across unchanged reads

Follows #44029. The actual Tools original Task body cadence retains its admitted
GET and fresh read ticket. This unit reuses only an exactly equal immutable Task
payload, so a fresh unchanged observation can keep an already pending or ready
body preparation. No HTTP request, read authority or freshness result is cached
by this change.

## As-Is / To-Be

| Boundary | Before | Source behavior after this unit |
| --- | --- | --- |
| Fresh body response | `task_of_yojson_with_diagnostics` constructs a new Task record on each successful decode. Display input equality requires physical Task identity. Even equal Task facts invalidate prepared input. | The request captures the same original source's last immutable detail. After validating and decoding a new response, full typed Task equality runs on the shared CPU path. Equal payloads reuse the previous Task object. |
| Equality | ID/status-only matching would miss body, contract, handoff, execution links and Skill changes. | Generated equality covers the complete Task and nested closed domain types, including exact immutable Skill references through their existing equality. No second field projection, text heuristic or hash-only shortcut is added. |
| Source metadata | Task content and canonical Goal/diagnostics arrive in one body response. | Only the Task object can be reused. Canonical Goal and diagnostics always come from the new response. Existing Goal input equality and direct diagnostic rendering retain their roles. |
| Ownership | Fresh read and document preparation have independent physical owners. | The prior payload is captured before dispatch, not looked up by a worker later. Current workspace/read epoch, original request/context/run/Task and fetched ticket still govern completion. Reused payload is no read or effect authority. |
| Failure/change | Failed source reads retain previous observations; changed input retires prior display owners. | These remain separate. Validation/decode failure does not become a cached success. Any typed Task difference produces the new Task, and source/width/Goal changes remain subject to the original preparation guards. |

## Authored resource evidence

The existing real first-loss Composition/resource scenario now continues through
an actual fresh original Task body producer read while its display preparation
is pending. Its completion stays admissible when the freshly decoded typed facts
are equal. The same authoritative backlog then changes the original description
without changing its Task/status/run; the next actual body read starts a new
preparation and the existing cross-consumer late-reply scenario follows that new
owner. These are stored-state/decision and resource-boundary checks, not display,
wording, row-order, snapshot, PTY, helper-mirror or invocation-count tests. They
are authored and **unexecuted**.

## Before/After limits

The source removes unnecessary display-input replacement for equal original Task
observations. It keeps network/JSON/typed decode work and adds full typed equality
on the CPU worker. Comparison cost scales with Task content; nothing here proves
that total CPU, Loading, input response, paint or useful Task progress is faster.
The Work/world Task allocation path remains a separate consumer to inspect.

Only OCaml parsing and whitespace/source inspection are performed. No local
build/typecheck/tests, CI dispatch/watch, native/model/PTY/controller/coordinator/
report run, install/restart, runtime prompt/config write or own merge. Generated
code has not been typechecked or executed in this unit.

All six original axes remain active. Future matched actual cohorts must include
GET, decode, typed comparison, independent display preparation and diagnostic
costs, with failed, cancelled, interrupted and unfinished attempts retained.
Source approval, whole-stack approval, merge, installation and live evidence
remain distinct.
