# Keep the current Keeper turn inside its original workspace read

Source comparison base: `aa81421aa05235234b7a1fb0418f1bc781ebd377`
(#43852). Covers the current-turn poll and its pure row interpretation. Existing
Owner-slot identity, exact interrupt/control tokens, preparation identity and
per-Keeper control generations remain authoritative.

## As-Is / To-Be

The current-turn poll already uses the common JSON reader, but its callback in
`Masc_tui_async_read` carries no expected-workspace binding. A workspace-wrapped
completion alone cannot establish which root actually answered an earlier GET
at the same endpoint. Row interpretation also runs directly on the calling Eio
fiber after common JSON parsing.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Current-turn callback | JSON GET without its expected workspace | Captured local owner guard and expected-root binding through actual GET |
| Admission implementation | Inline in the five-call shared launcher | One `capture_workspace_json_read` callback reused by that launcher and existing Async_read |
| Existing async lifecycle | Source attribution, Fork_guard and on_not_run | Same launcher/lifecycle; no extra fork or second health GET |
| Server/conditional receipt | Available only when bound | Current-turn GET now uses existing root precondition and exact 2xx/304 receipt |
| Typed rows | Calling Eio fiber | Pure JSON-to-row interpretation through shared CPU path |
| UI ownership | Workspace envelope and captured per-Keeper control generations | Same envelope/filter, inflight/error/last-good state and control tokens |

The callback captures authority, read epoch, expected identity and endpoint
synchronously before launch. Its local guard runs on the existing Eio child;
the actual bound path is prepared before HTTP crosses to the IO domain. It
returns a source failure if ownership has retired or the endpoint/known identity
changed. A server replacement after that check still has to admit the exact
expected roots. There is no unbound fallback. HTTP/credentials/cache remain
caller-owned; `decode_keeper_turns` consumes only immutable JSON on the shared
CPU path. The worker does not read/change UI control generations, inflight state,
workspace authority or selected preparation.

The existing Async_read source labels failures once, clears an armed inflight
flag when launch did not run, and rethrows cancellation. Its root-switch/Fork_guard
policy is unchanged. General request/effect preflight, shared identity refresh,
the five preceding admitted dispatches and the main's per-Keeper row/control
admission rules are unchanged. Failed polls retain their last known rows and a
failure. A read receipt is an observation, not permission to interrupt/replay.

## Source quantification and observability

Nominal current-turn GETs remain **1 → 1**. The improvement is connecting one
previously unbound poll to the existing request/response/cache proof, and moving
one pure typed row traversal to the established CPU scheduling boundary. The
shared owner/binding callback now supports both existing launchers without
duplicating the admission policy. Row traversal complexity and data are unchanged.
No measured CPU/Loading/input/paint/throughput gain is claimed; pool absence,
non-Eio and already-worker inline behavior remains the established policy.

`keeper.turns.decode_wait` observes pool admission through interpretation and
returned scheduling, not pure CPU duration or UI paint. No polling interval,
deadline, row cap, retry/cache knob, background request or autonomy constraint
is introduced. This is not proof that every TUI read now carries workspace proof.

## Compound scenario and Before/After boundary

An **unexecuted** scenario extends `test_keeper_turns_route` using actual metadata
stores/Owner registry, an admitted maintenance child holding the real turn slot,
its Owner-bound preparation writer and the actual turns handler. The request
passes the production workspace-read guard and server connection writer; the
response is decoded with the HTTP client parser, common JSON/cache reader and
current-turn decoder. The existing Async_read launcher delivers its result.
There are no fabricated turn rows or stop/control tokens in the scenario.

While original A remains in preparation, B at the same endpoint has an actual
idle Owner under the same Keeper name. An A-bound poll refuses B rather than
accepting its idle row; the original Owner slot remains unchanged. Returning to
A recovers the same interrupt/control observations and original preparation
lineage. Only releasing the actual child produces the idle transition. All HTTP
bytes here travel through in-process connection fixtures; no socket/network,
private main launcher/guard factory, UI row application or CPU scheduling run is
claimed. Main envelope and per-Keeper control-generation filters are inspected
in source, not replaced with a test mirror. The router and full public-read
authentication/startup wrapper are not exercised by this fixture.

Only OCaml parsing, source/interface inspection, diff and changelog checks are
performed. Typing, tests, CI, native/model/PTY/report execution, installation and
visible screen proof remain separate and unperformed. No layout, wording,
row-order, snapshot, helper-mirror or invocation-count test is added.

A matched runtime comparison must retain the original Keeper/turn/control
generation, workspace, cache state and request order, including failed,
cancelled, interrupted and unfinished polls. Separate transport/decode/UI
admission from input, paint and useful task effects. The full original
Ask-to-Task-to-useful-work objective remains unverified by this source unit.
