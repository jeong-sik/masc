# Bind selected preparation to its actual workspace read

Source comparison base: `6ad646ee264d16ba4fdf610b68e212ef5cdb8d07`
(#43849). Covers the on-demand selected preparation detail. The existing target
already owns journal identity/revision, exact Turn_ref and direct operation link;
those are preserved, not diagnosed as missing.

## As-Is / To-Be

The selected preparation launcher still performs a separate identity GET. Its
HTTP consumer then uses raw `http_get` and a system-thread decode wrapper.
That actual GET bypasses the common expected-root query, server admission
receipt and conditional JSON reader. Matching execution IDs inside a payload
do not prove that it came from the originally requested workspace.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Selected preparation dispatch | Identity preflight, then raw detail GET | Local captured-owner checks, then workspace-admitted JSON GET |
| Actual read | Raw HTTP, status/body | Existing expected roots, exact server receipt and root-keyed ETag cache |
| Query | Exact Keeper/trace/turn from abstract target | Same query and target, retained through URI workspace binding |
| JSON interpretation | Inside system-thread wrapper | Existing common JSON CPU path |
| Report interpretation | Inside system-thread wrapper | Pure typed decode in common CPU path, original target retained |
| HTTP/cache/workspace owner | Caller HTTP plus separate decoding | Actual HTTP, credentials, binding, receipts and cache remain on caller |
| Selection/revision, operation, turn, report/clock/partial diagnostics | Existing exact target and decoder | Same contract and request capability; no new fallback or guess |
| Four admitted history callers | History-named wrapper | Renamed `launch_workspace_json_read`, same behavior, no old alias |

The shared wrapper captures authority, read epoch, identity and endpoint before
forking. It checks those local owners before sending. The actual server GET
validates the expected workspace pair, and the client requires a single exact
receipt on 2xx/304 before publishing JSON or returning kept JSON. Missing or
foreign identity is a failure, not an unbound read. This does not bypass general
request/effect preflight or the shared before/after refresh identity probes.

The CPU callback receives the already parsed JSON and the existing immutable
target fields used by `Details.decode`; it does not inspect/change the journal,
selection or request owner. Existing report membership, duplicate/unsupported/
invalid diagnostics, original operation linkage and recorded failure outcomes
are retained. Late CPU completion cannot acquire a successor's request capability.
`keeper.preparation.decode_wait` labels pool admission through returned decoding,
not pure CPU time, key/paint latency or useful task progress. No retry, deadline,
row cap, cache knob or new background request is introduced.

## Source quantification

For this selected detail request, nominal explicit GETs change from **identity
GET + detail GET (2) to admitted detail GET (1)**. One more raw HTTP consumer and
one actual dispatch are connected; the shared wrapper now serves preparation
plus the four preceding history dispatches. This is source call-path cost, not
an executed invocation-count check or measured 50% speedup. Authentication,
connection, store work, CPU pool wait/decode, cache generations, shared refresh,
UI admission and paint remain separate. No claim is made that the live Loading
cause has been identified or that all TUI GETs now have workspace proof.

## Compound evidence and Before/After boundary

An authored, **unexecuted** scenario extends the existing
`test_tui_preparation_details.with_source` feature fixture: durable preparation
writer, actual backend runtime-trace projection, client workspace/JSON/cache
pipeline, exact target decode and actual selected read owner. A second workspace
deliberately writes valid evidence under the same Keeper/turn/operation IDs;
its different report proves target identity alone cannot establish workspace.
The original admitted read preserves its original report and failure. Missing
receipt on 304 settles the selected read as failure; an admitted 304 restores
the original body under a fresh owner. A switched backend refuses the original
workspace query, and return to the original workspace recovers its report.
Retired completion capabilities cannot settle the new selection.

The request/query, admission validator, durable store projection, JSON cache and
target/owner functions are production code. Conditional responses and receipt
lists are controlled protocol frames. This is not actual HTTP wire/middleware
emission, private main-launcher, CPU scheduling, global refresh or terminal proof.
Existing interruption/failure/partial-report scenarios remain in source. No
layout, wording, row-order, snapshot, PTY, helper-mirror or invocation-count test
is added. Only OCaml parsing, source/interface review, diff and changelog checks
are performed; typing, tests, CI, install/restart and live observations remain
unperformed.

Matched runtime comparison must freeze original workspace, target, journal
revision, report IDs, cache and credentials, and retain failed/cancelled/
interrupted/unfinished attempts. Keep transport/decode/application, input/paint
and original Ask-to-Task-to-useful-work clocks separate. Source changes and an
authored scenario do not prove completion of the full goal.
