# Bind detail-history reads through request admission and cache reuse

Source comparison base: `fddf8855a201306cdf3b529dbe7112913628237e`
(#43845). This unit covers Goal timeline, Task history and Keeper Calls reads,
including the retained-browser list that reuses the Keeper Calls consumer.
It does not establish the cause of the reported live Loading screen or measure
input, paint, preparation or useful-work latency.

This records the admission layer at #43848. The subsequent source change in
`2026-10-19-tui-history-single-admitted-read.md` removes these histories' separate
identity preflight while retaining actual GET admission and completion ownership.

## As-Is / To-Be

Task/Goal history launchers already use workspace-owned request completion and
an endpoint identity probe. Keeper Calls uses a raw daemon and workspace-wrapped
completion. Retained-browser list reload also uses that consumer from a raw
daemon. All three HTTP consumers still use raw `http_get`: their actual GET
does not carry the expected workspace pair or validate the server's admission
receipt. A probe cannot bind a later GET when the same endpoint changes roots.
The normal world collector already has this protocol through `get_json_decoded`.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Three detail-history GET consumers | Raw GET after caller-specific checks | Common JSON reader; expected base/root and server receipt |
| Task/Goal dispatch | Common launcher with endpoint probe | Same owner plus original-identity binding around actual read |
| Keeper Calls dispatch | Raw daemon with scoped completion | Common launcher, endpoint probe, cancellation registration and binding |
| Retained-browser list reload | Keeper Calls consumer in another raw daemon | Same common history launcher and binding; original browser generation retained |
| Parallel collectors | Existing world-collector fiber-local binding | Same shared implementation used by detail reads; no global mutable identity |
| Conditional reuse | These three consumers do not use common ETag cache | Same cache as JSON reads, address includes expected roots; receipt required on 304 |
| Failed/missing/duplicate/wrong receipt | Not examined by raw consumers | Refused before decoded body publication or cached-value reuse |
| Existing world collector | Private HTTP binding/receipt implementation | Same implementation extracted into `Masc_tui_workspace_read`, no second policy |

The dispatch helper captures the original expected identity and endpoint before
forking. It keeps the shared endpoint check, cancellation and workspace completion
envelope. Missing identity produces a read failure, never an unbound fallback.
The three consumers retain their original query grammar, limits and typed
history decoders. Goal and Calls errors retain source attribution. Common JSON
parsing now uses the existing response-decode worker path; the callback still
owns HTTP credentials, cache changes and applying the decoded observation.
The four dispatch call sites use the bound helper. Opening an individual retained
artifact still uses the existing exact-content reader; this unit does not change
that separate non-JSON transport or claim workspace receipt coverage for it.

The extracted module prepares the concrete path on the calling fiber, before
the transport crosses an IO boundary. It rejects a changed endpoint and existing
precondition fields, and keeps the existing canonical root and Health-identity
checks. Request-precondition reads require exactly one matching server receipt
on 2xx and 304 before touching successful JSON/cache reuse. Refusal statuses
continue to the HTTP error decoder. A refused response leaves no new successful
observation; it cannot replace the previously admitted cached body. Read proof
does not authorize effects or replay. Item generation and workspace authority
continue to decide whether a returned result can update the screen.

## Source quantification and evidence

Three detail-history consumers move from the raw path to the existing workspace
admission/JSON/cache path. Two raw daemon list-dispatch paths move to the existing
common request lifecycle. This is a source inventory and protocol invariant, not a
measured failure rate, HTTP reduction, Loading duration or throughput gain.
Keeper Calls and retained-browser list reload now perform the common preflight
identity check; fewer HTTP calls are not promised. No timer, timeout, retry policy,
cap or configuration knob is
added. Server admission semantics and its existing wire receipt are reused.

An **unexecuted** compound scenario in
`test_server_auth_dashboard_actor_resolution` uses the production server
precondition validator, extracted client JSON/cache reader and Task-history
decoder. Controlled response frames preserve the same Task/actor and distinct
original handoff context through A-to-B replacement at one endpoint, including
identical ETags, initial B-304 refusal, admitted B reuse, unadmitted 200/304
refusals, recovery and wrong-endpoint refusal. It also forks an A-bound child,
leaves the parent binding, then overlaps B at a separate endpoint and verifies
each original decoded context. It checks protocol/data continuity, not invocation
counts, layout, wording, row order, snapshots or PTY output.

Those frames are protocol input: the scenario does not run real HTTP, the
production history route/store, the main-loop launcher or transport/CPU workers.
Existing `test_http_server_eio` source separately covers server receipt emission
through JSON/conditional responders; it is not executed or promoted to wire proof
here. All three consumers and four actual dispatch connections are inspected in source.

Only OCaml parsing, source/interface inspection, diff and changelog checks are
performed. Typing, executed scenarios, CI, installation and visible UI proof
remain separate. Matched Before/After must freeze the original workspace and
item, endpoint replacement, cache state, outcomes and request ordering; retain
failed, cancelled, interrupted and unfinished reads. Keep dispatch, transport,
decode, application, visible paint and useful task effects as separate clocks.
No measured speedup, observed live leak or verified Loading repair is claimed.
