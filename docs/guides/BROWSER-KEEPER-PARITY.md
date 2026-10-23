# Keeper browser parity and workflow validation

Tracking: [#45556](https://github.com/jeong-sik/masc/issues/45556).
The question is whether a Keeper can complete the same UI workflows a person
can, across the requested browser connections. A tool existing, a request being
accepted, a primitive succeeding and a completed user workflow are separate
claims. This document defines the evidence to collect; it is not a support
certification or a new Keeper runtime gate.

## Source baseline and bounded evidence

The source snapshot below is main `376e0f1abdd03163f7af4b4791c24ad46dd043f0`
on 2026-10-23. Consult `lib/browser_capabilities.ml` and the selected connection's
actual capabilities again before a run. Later commits can change this table.
Source inclusion does not establish the installed binary or an active connection.

| Area | Source or execution evidence at this boundary | Still needed |
|---|---|---|
| Semantic observation/action | Main includes ego snapshot ref/role/text click/fill from #45541 and explicit-client handoff/takeover from #45542. Other transports do not thereby gain AX snapshot targets. | Keeper discovers targets from its own observation and completes the same task; stale target, URL change and operator interruption recovery. |
| Common form selection | #45593 adds multi-select replacement/clear; extracted production JS passed 11 actual-DOM scenarios each in Firefox and ego. | Typed host/Add-on path and installed Keeper execution. This is DOM selection with synthetic events. |
| Frames | Catalog serves explicit frame reads and selector interactions through live BiDi/owned Gecko; ego, extension and owned Chromium lack the equivalent framePath contract. | Cross-origin and dynamic-frame workflows, truthful unsupported outcomes, semantic targeting and navigation recovery. |
| Files and dialogs | Catalog and in-flight PRs differ by transport. The ego downloads/upload stack and dialog work must be inspected at current heads rather than inferred from older merged feature branches. | Actual artifact bytes, persisted upload/download results and observed dialog outcomes through the selected transport. |
| Visual control | Scene supplies DOM geometry, not proof of paint order or occlusion. Screenshot artifacts require a pixel-reading/analysis step. | Covered targets, canvas/rich editor and pointer/focus behavior with independent visible and application state evidence. |
| Several browsers | Client identity and capability selection are explicit parts of the contract. An observed logged-in browser is not interchangeable with a new owned session. | Concurrent connections, same tab IDs in different clients, reconnect, focus changes and cancellation without effects in the wrong browser. |
| Tool calling performance | Primitive timings and an older narrow Keeper success exist. They do not measure current broad goal-only workflows. | Per-browser autonomous completion, round trips, model/tool latency, errors, recovery and comparable human runs. |

The initial assessment at source/runtime `68ec8fb2c52545c68600928524dcc12945e55ee7`
predates the main inclusion of #45541/#45542. Keep that historical snapshot
separate from this source update. No deployment claim follows from the update.

## Execute the same work, then inspect the result

Give the Keeper a user goal and the allowed site/data scope. Do not hand it a
CSS selector, AX ref, action sequence or the expected answer. Set up deterministic
fixtures with independently readable application results; use real authorized
sites separately and name that scope. Give the person the same user goal and
starting state for comparison.

| Workflow | Result to inspect independently |
|---|---|
| Find and complete a form with conditional fields and multi-select | Persisted submitted values, including cleared selections and validation errors; receipt alone is insufficient. |
| Open a dynamic menu, hover controls, nested scrolling and modal | Actual destination or application state; keyboard focus and no action behind an overlay. |
| Edit a cross-origin/dynamic iframe form | The correct frame's saved data and no change in a similarly named outer control. |
| Upload then download a generated result | Correct authorized input, final artifact bytes and application association; file existence alone is insufficient. |
| Drag/drop, rich editor or canvas task | Application model/output plus a separately read screenshot where appearance matters. |
| Work in two browser clients with overlapping tab IDs | Correct results in both clients and no unintended cross-client effects. |
| Interrupt, reconnect or hand off during a workflow | Actual owner/page after recovery and no duplicated submissions or silent session replacement. |

Run supported workflows through each requested transport. Preserve unsupported
cases in coverage instead of removing them from the denominator. Record
implementation gaps, missing execution evidence, environment failures and
unavailable external sites separately. Do not switch a logged-in connection to
another browser to conceal missing support. Reobserve the same client/tab after
an uncertain effect before deciding how to continue.

For ego, use one task space throughout a goal, including errors and recovery;
reuse its page aliases. Record its observed identity with the run evidence rather
than hardcoding a local space number into the general guide. If the original
space disappears, preserve the failed lookup and ask the operator before creating
a successor; record that authorized exception and the new identity. Do not finish
the space until this whole goal ends. A separate goal uses a separate owned space.
Never take over another goal's or a person's space to obtain a cleaner result.

## Record cost, success and recovery

For every attempted workflow retain:

- Source and installed binary SHA, browser/version/transport, model/provider,
  effective runtime identity, client/tab and ego space identity where applicable.
- User goal, start state, run identity, requested coverage and human comparator.
- Tool arguments/results, model decisions, retries/reobservations, partial or
  unknown effects and recovery decisions. Preserve failed attempts.
- Start/end times, overall elapsed time, model versus tool time, call count,
  payload/token cost when available and the independently inspected final state.
- Outcome: completed, wrong effect, incomplete, unsupported, environment failure
  or unmeasured; include the evidence that distinguishes it.

Report completion and wrong-effect rates with sample counts and denominators,
latency distributions only where the sample supports them, and recovery cost
separately. Compare the same tasks and starting states with the person's runs.
Do not label a few primitive timings as p95 or human-level tool performance.
No arbitrary turn/time/token limit is introduced by this measurement procedure.

## Completion boundary

The broad goal remains open while a requested workflow has an implementation
gap or lacks independent Keeper execution evidence. A source review PASS, a
merged PR, CI success, an accepted review request or a direct browser fixture
does not close it. Summaries must state the measured browser/workflow coverage,
remaining gaps and installed-runtime scope before judging support sufficiency.
