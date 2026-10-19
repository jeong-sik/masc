# Original async request details in the Tools TUI

Relates #42799 and follows #43969 / #43979. This source unit connects the
existing exact status producer to actual selection, retrieval, read ownership,
and rendering. It does not complete the six-axis objective or claim observed
UI behavior.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Request identity | The active-list decoder retains the request ID and target Keeper, losing the original submitter required for exact lookup. | The decoder retains all three identities. `J/K` selects and `Enter` reads that exact source; no current Keeper fallback. |
| Terminal request | The Tools pane displays active inventory only. | A selected target survives disappearance from the active list. `o` accepts the exact original submitter, request ID and target Keeper in the existing editor flow, including requests never selected in the list. No terminal-history enumeration is added. |
| State meaning | Physical active phase and runtime ownership are visible. | The detail renders typed physical outcomes, released dependency waits and original failure reasons separately from the original logical run/Task, owner generation, journal version, observation time and terminal decision. |
| Partial failure | A failed list read hides the previous active rows; no detail source exists. | The previous list remains visible with its failure. Failed exact reads retain their previous physical snapshot. Logical unavailability retains an earlier logical value only for the same original source/context and labels it as earlier evidence. Authoritative absence clears the logical value. |
| Read ownership | No exact-detail read exists. | The existing workspace-admitted launcher owns HTTP work and the shared decode path owns CPU work. Original target, read authority and opaque fetched ticket must still match at settlement. Explicit replacement cancels only its own prior job; leaving the pane retires that observation. Workspace withdrawal clears source selection and retained data. |
| Automatic retrieval | Tools cadence reloads its inventory/catalog/active-list sources. | While detail is open, cadence reads the selected exact request and shares its in-flight read. Explicit `r` supersedes that read. This changes retrieval scope; it is not a measured latency improvement. |

## Producer to consumer

`Server_async_request_observability.project_request` already supplies
`masc.async-request-status/v1` through the operator/workspace-admitted HTTP
endpoint. `Masc_tui_http.fetch_async_request_detail` encodes the original
submitter/request query, and `Tui_decode_async_request` validates the echoed
submitter, physical request and target Keeper before returning typed data.
It also validates the original Composition run/Task and resolution owner.
The actual physical failure wire state is `error` with `ok=false`; it is kept
distinct from `done` with `ok=true`.

`Masc_tui_types` owns the selected source and fetched lifecycle. The root
event loop opens/refreshes/closes the detail, handles the captured reply, and
dispatches only exact-detail retrieval on its open-pane cadence. The Tools
renderer consumes that same fetched state. It does not pretty-print arbitrary
result payloads on each draw. Request/Task/status observations grant no effect,
replay, Task completion or delivery authority.

## Authored scenarios and evidence boundary

The new unexecuted resource/protocol scenario submits a real asynchronous
request whose submitter differs from its target. Its worker mutates an original
private resource, then pauses while the actual server projection, strict client
decoder and read-ownership transitions are exercised. Both physical success and
physical failure cases are authored. The scenario includes retired/replacement
reads, retained physical/logical observations under partial failure, terminal
row disappearance, same-ID source withdrawal, wrong-owner rejection and retained
resource bytes. The existing first-loss Composition resource scenarios also
consume the actual projection/decoder after explicit logical resolution and keep
physical Lost separate from the original Task and operator decision.

These scenarios are **authored, unexecuted**. The existing renderer-test input
fixture receives only the now-required original submitter; no renderer assertions
change. No layout, wording, row-order, snapshot, PTY, invocation-count or
helper-mirror tests are added.

Validation is OCaml parsing and whitespace inspection only. Build, typecheck,
tests, CI dispatch/watch, native/model/PTY/controller/coordinator/report runs,
installation, restart, live prompt/configuration writes and own merge are
excluded. No visible frame, usable-input time, paint latency, runtime usefulness,
speedup or matched actual Before/After is claimed.

The original Ask to Task/useful-work chain, preparation attribution/frozen
discovery reuse, ordinary/nested/dynamic/effectful Composition resource
continuity, held-job/shared-backend continuity, cold-start/TUI visibility, and
matched actual cohorts remain active. Failed, cancelled, interrupted and
unfinished samples must remain in future matched measurement denominators.
