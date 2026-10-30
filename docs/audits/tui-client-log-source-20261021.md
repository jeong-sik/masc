# TUI process-local Logs source integration

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Visible log source | Server dashboard HTTP only | `o` selects Server or This TUI in Logs/list/detail, with an explicit origin label |
| Local availability | Client ring/files and offline reader, no screen integration | Current process ring read on selection/filter and existing cadence without server authority |
| Source ownership | One snapshot/error/filter/navigation/detail state | Separate immutable pages for server/client; late server frames update only server |
| Sequence identity | One selected server sequence | Sequence detail is owned by its source page; source switches restore that page's own target |
| Workspace withdrawal | Clear the one server log page | Clear server data/navigation/detail, retain original server filter preferences and process-local page |
| Empty page | Server emits latest_seq null but decoder requires int | Required nullable field becomes option; no invented sequence or failed empty page |

`Masc_tui_system_logs` owns typed source selection, immutable per-source pages
and the explicit local read boundary. UI state owns the one model; there are no
compatibility fields or duplicate mutable copies. Listing, search, scrolling,
category, level, detail and footer use the selected source. Server HTTP captures
its own page's floor even while the client source is selected. Source selection
uses existing navigation refresh for the server and directly samples the local
ring; it does not add a duplicate independent server request.

The client adapter uses existing Ring entry encoding, actual bounds/rows and the
shared strict decoder. It preserves a missing returned latest sequence as None.
The field must still be present; null is not a missing-field fallback. Unknown
local severity is an explicit read error. Failure keeps that source's previous
snapshot/error diagnostic. Server result admission retains the existing original
workspace/read/ticket checks before applying to the server page. No client source
can authorize a server operation or read another process's ring.

The explicit origin is distinct from the original entry's typed emission source,
module and original provenance in details. The client page does not pretend to
be a server dashboard export or replay retained files from previous processes.
A local page can be observed while server identity/health is unavailable. Server
status is shown only on the server source; the client source identifies itself.

## Costs and proof limits

Local sampling performs a bounded memory-ring read, JSON envelope/entry encoding,
shared decode and source-page allocation on selection/filter and the existing
refresh cadence. There is no synchronous file history scan in input/draw, worker,
extra timer, retry, authority gate or new backend/configuration. Rendering/search
use the already applied snapshot. The old server page size is reused. Holding
two source pages and retained raw details costs memory; no CPU/latency or Loading
speedup has been measured. Source integration is not visible paint or input proof.

## Actual resource case extended, unexecuted

The existing actual canonical Ask/answer/Task/frame/decoder/retained-result/store
case now also reads the actual local Ring via the production adapter and actual
server dashboard JSON via the shared decoder. The pages share real sequence
values. A later actual server frame must update its server page without replacing
client data, filter or detail state. Switching back must retain server severity
and detail identity. A real empty Ring slice before sequence zero produces the
server's null latest sequence and must decode as an empty successful observation.
A controlled server error result and server retirement must preserve the client
page; retired server detail must not resolve a matching client sequence. Original
Task resources remain unchanged. Same-process protocol/resource integration does
not prove network concurrency, separate live processes or Main's visible key loop.

One existing actual resource case was extended, not executed. Existing decode/key
fixtures were adapted only to changed public types. No new wording/layout,
snapshot/PTY or helper invocation-count test was added. Interfaces were authored
first. Every touched direct Dune consumer declares the new source owner.

Only parsing and source/diff inspection apply. No local typecheck/build/test,
CI dispatch/watch, native/model/controller/audio/PTY run, install/restart, live
write, self approval or merge. Lower canonical native-stack identities and
historical ancestry/review issues are preserved. All six objective axes and
actual matched Before/After/visible UI proof remain open.
