# Remove the serial identity probe from workspace-admitted histories

Source comparison base: `99120744cb9b88c6b438bbb6e39daa23ff6d1ce8`
(#43848). Applies to Goal timeline, Task history, Keeper Calls and retained-browser
list reload. This is a source cost comparison, not a measured live Loading fix.

The preparation-admission follow-up in
`2026-10-19-tui-preparation-workspace-admission.md` renames this private history
wrapper to `launch_workspace_json_read` and reuses it for selected preparation.
The four history dispatches keep the same single admitted-read behavior.

## As-Is / To-Be

The preceding layer binds all four dispatch sites through three actual HTTP
consumers. Each history read still enters `launch_workspace_request`, whose
`check_workspace_request` waits for `load_server_identity` before the real GET.
That later GET already carries the expected workspace pair, and the server
validates it before dispatching the handler. The client requires the matching
receipt even on 304. The earlier health answer cannot bind that later request.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| History read chain | Identity GET, then admitted history GET | Local ownership check, then admitted history GET |
| Identity captured before fork | Expected identity and endpoint | Also capture workspace authority and read epoch |
| Before transport | Network probe plus existing checks | Reject retired authority/epoch, unconfirmed identity, changed endpoint or changed known workspace locally |
| Server admission | Expected base/root and receipt on 2xx/304 | Same server and client protocol; no unbound fallback |
| Refused actual GET | History error after preflight success | Direct source error; original last-good history remains stale |
| Global identity | Preflight could publish an independent unconfirmed observation | Existing shared refresh owns actual global identity observations |
| Effects and other request callers | Existing endpoint preflight | Same `launch_workspace_request` check and operation completion envelope |
| Cancellation / late completion | Workspace cancellation and original completion stamps | Same shared implementation, no new lifetime/retry policy |

`launch_workspace_result` factors only the existing cancellation, exception-to-
result conversion and original workspace completion envelope. General requests
still call `check_workspace_request` inside that boundary. History reads use a
separate named wrapper: they check captured local owners before sending and bind
the original expected roots through the actual JSON/cache reader. There is no
flag that lets general/effect callers bypass their preflight.

A history failure is not a health response. This read no longer changes global
connection/identity state by sending an extra health probe. The normal shared
refresh continues to confirm, suspend or replace that identity. Until it does,
a refused history stays a failed observation of its original workspace rather
than borrowing a successor's history or fabricating an empty result. Other
actions retain their own checks. If identity/read authority is retired while a
GET is pending, the original completion envelope still prevents applying it to
a successor. This is read admission, never effect/replay authorization.

## Source quantification

For each ordinary invocation of these four dispatch sites, the explicit reader
chain changes from **one identity GET plus one history GET to one history GET**:
serial identity probes **1 → 0**, nominal GETs **2 → 1**. For R such reads, the
explicit serial probe contribution changes from R to zero. Do not convert that
into a 50% latency claim: connection behavior, authentication refresh, transport,
server/store/JSON work, other shared refresh reads, concurrency and UI admission
are separate costs. Local guards still perform existing identity/path comparisons.
No invocation-count test, timer, cap, timeout, retry budget, cache knob or new
background request is introduced. User input and autonomy are not throttled.

## Evidence and Before/After boundary

The existing compound server-admission/client-cache scenario is extended with
actual Task-history begin/complete/withdraw state functions and its production
decoder. Original A history is accepted, a direct GET against successor B is
refused, and its current owner settles as stale A data with failure rather than
remaining in flight. An admitted B result is applied only after the old detail
history is withdrawn and a new owner begins. Late A completions cannot settle
or overwrite it. Receipt/cache refusals and inherited parallel reads continue
through the same scenario. It is authored and **unexecuted**; response frames are
controlled protocol input, not an actual server/wire or main-loop fixture.

The private launcher local guards, shared dispatch factor, unchanged general
request/effect preflight and all four call sites are inspected in source. The
scenario does not execute the main launcher, global health refresh, cancellation
scheduler or IO/CPU workers. Only OCaml parsing, diff and changelog checks are
performed. Typing, tests, CI, native TUI, model/PTY/report runs and installation
remain unperformed; no independent approval or visible screen is inferred.

A measured comparison must freeze original workspace/item, cache state, endpoint
replacement, request order and credentials. Retain failed, cancelled, interrupted
and unfinished reads. Separate dispatch, actual request/decoding/application,
global identity refresh, input, paint and useful task effects. The source-count
reduction is established by the changed call path; runtime speed and the full
Ask-to-Task-to-useful-work goal remain unverified.
