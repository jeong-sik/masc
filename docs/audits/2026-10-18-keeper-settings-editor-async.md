# Keeper settings editor: owned asynchronous preparation

## Source scope

Baseline: `4a181f1eecd7a06a14487c435a2780ff9fb25e6a` (#43662). A Keeper
settings edit previously ran workspace identity read, config snapshot read and
identity reread inside its `e` key handler. The event loop could not process
another key or redraw while waiting for that chain. This layer moves those
same readonly preparations to an owned observation job and hands the frozen
snapshot to the original guarded editor/write flow at a later loop boundary.

## As-Is / To-Be

| Boundary | Baseline | This source |
| --- | --- | --- |
| `e` before editor | Waits for two identity probes and one config read | Records an edit intent and starts owned asynchronous preparation |
| HTTP waits in that key handler | Three logical HTTP reads on its successful path | Zero; the same reads run in the observation job |
| Editor-ready snapshot | Opens inline after the read chain | One later handoff, with the same Keeper, surface, tab, workspace and read authority |
| Repeated `e` | Each invocation reaches the synchronous chain | Pending and ready-to-open intent share the existing request; failed read permits explicit retry |
| Navigation / another input owner | Unavailable during the inline read | Cancels preparation and clears its private snapshot/intent |
| Queued input / paste / terminal sequence | Cannot be handled while the read blocks | Processed before a ready snapshot can take the terminal at the handoff decision |
| Status | No dedicated persistent preparation state | Footer names reading, failed or ready-to-edit state |
| Observability | Inline read chain and eventual editor outcome | Started, read-completed, admitted, editor-handoff and cancellation records share source key and request id |

These are source-derived dependency and ownership changes. HTTP work is not
reduced; time until the editor itself becomes ready is not claimed to shrink.
The change permits normal frame/input work while preparation waits. Cold boot
first input, actual key responsiveness, painted UI, network/executor concurrency
and all wall-clock improvements remain unmeasured.

## Ownership and resource boundaries

The existing fetched-state primitive supplies request generations, pending
sharing, result admission and explicit failure. An edit intent additionally
captures Keeper, list/detail surface, detail tab where applicable, canonical
base path and runtime root, workspace authority, read-authority token and an
owner token for cancellation cleanup. A completed snapshot cannot consume a
newer intent. Old worker cleanup can remove only its own cancellation owner.

The reader uses the existing workspace check sequence before and after the
snapshot read. Eio observation scope owns cancellation on authority withdrawal;
explicit focus withdrawal races the read with a cancellation promise. The
common HTTP and CPU submission paths retain responsibility for actual cleanup.
A cancellation signal is not proof that the worker has already stopped. No
automatic retry, extra timer, numeric work cap or alternate result registry is
introduced. Pure editor-stem projection uses the common response-decode worker
policy rather than building the form on the key path.

A snapshot is handed off only once, on its original visible Keeper/list-or-detail
scope, with no text/modal owner and no already queued key, interrupted paste,
active paste tail or incomplete terminal sequence at that decision. Navigation,
Esc and workspace/read-authority withdrawal retire it. Availability is rechecked
after ordinary input as well as before opening. This source check does not prove
a terminal timing race under actual input; no PTY scenario is added or run.

The frozen config JSON supplies both editor text and `patch_of_edit`'s original
revision. The later workspace recheck, config POST, CAS/conflict handling,
refusal reopening and existing receipts remain in the editor flow. External
editor execution and post-editor save remain synchronous. No runtime file,
Keeper configuration or server process is changed by implementing this layer.

## Evidence and remaining work

Two authored, unexecuted state scenarios cover shared pending/ready intent,
queued-input deferral, one handoff, actual patch generation from the original
revision, failed-read explicit retry, late result rejection, selection/tab/surface
and canonical runtime-root changes, other input focus, workspace read withdrawal
and old cleanup versus successor cancellation ownership. The state suite declares
a direct Keeper-config projection dependency. These cases do not execute the
actual network job, editor, input loop or cancellation cleanup.

Parser-only checks and whitespace/changelog validation do not prove typing,
executable state transitions, actual network cancellation, terminal continuity
or latency. No local Dune/typecheck/test run, CI dispatch/watch, native/model run,
installation/restart, independent approval or merge is included.

`tui_keeper_settings_read` joins request start, read completion, state admission,
editor handoff and cancelled/superseded attempts with monotonic clocks. Its
structured records contain source keys and outcomes, excluding config values,
instructions, draft text and error details. Missing handoff/terminal records must
remain unfinished samples in a later matched cohort; none are timing successes.
Handoff records are not proof that the external editor painted successfully.

The broader goal stays open: remaining inline form writes and other preparation
paths, cold-start first usable input, remaining exact Task/Skill/Tool preparation
reuse, original Ask-to-useful-work continuity, resource-owned Composition and
matched Before/After with failed/interrupted/cancelled/unfinished samples.
