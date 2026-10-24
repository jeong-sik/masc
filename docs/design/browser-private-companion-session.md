# Browser companion session ownership

The 1Password docking goal is tracked in [#45736](https://github.com/jeong-sik/masc/issues/45736).
A credential companion must run inside the existing Browser Add-on's original
Chromium session. Opening another CDP connection outside the page-operation
serializer would allow a capture to observe a form while autofill is running.

`Browser_stagehand_backend.capture_private_session` captures a process-local
opaque pin to one backend and its exact `opened` resource. It never starts or
reopens a browser. `execute_private` sends trusted work to that backend's owner
fiber and acquires the same whole-verb slot as all Stagehand page observations,
captures and input. The callback gets the original owned session and the exact
CDP page target from the existing MASC tab table. A stale pin cannot follow a
replacement session, even if the caller supplies a new session's tab id.

Holding the page slot alone is insufficient after a public caller was
cancelled: Stagehand can still be processing an abandoned call. The required
`private_ready` callback uses `Session.quiescent` in production to require an
attached live transport and an idle Stagehand call state. Capture and callback
entry both check this. An abandoned public call is refused without a new effect
or an invented browser shutdown; confirmed settlement can permit the original
pin again.

A receiver that may have started ordinary input before throwing leaves a
distinct `Unsettled_delivery` call state. Later calls receive the typed
`Delivery_unsettled` refusal. Late messages or elapsed time do not establish
settlement; the original browser's explicit owned close remains available.
This state cannot masquerade as idle or as a cancelled call with a pending
reply. A confirmed refusal before delivery keeps the normal idle behavior.

The private callback must return only after its extension operation is settled.
Every callback error or unexpected exception becomes a fixed unknown outcome.
Cancellation after callback entry sets `Private_unsettled` on the original
session before the shared page slot is returned. Page/companion work and implicit
open/reuse are then refused; status and explicit owned shutdown remain usable.
There is no deadline, retry or current-session fallback on this private path.

Work is also bound to the original session's stopped promise. Explicit close
can terminate a session while its private callback is awaiting an independent
broker. Once that browser has stopped, the callback is cancelled and its cleanup
joined before the page slot is returned. A late cleanup never fences a newly
opened successor. An adapter must be cancellable and its cleanup must not wait
for a reply from the already terminated browser.

Private values do not pass through a `Browser_lane.answer`, public tool result,
action receipt or observation. CDP JSON parsing, command send and WebSocket
errors use fixed messages at their first boundary, since connection-ended
reasons also reach public lifecycle status and operator logs. The private Unix
service likewise discards parser fragments and unexpected exception text.
Adapters must also erase raw CDP command-rejection and provider error text.

## Next integration boundaries

This API is a source foundation; it does not yet load 1Password or export login.
The remaining implementation must:

1. Route a dedicated private Browser owner/wire operation to this exact pin.
   Ordinary browser ingress and exported tools must not accept that private
   transport command.
2. Use an independent private broker for the Python connector. Existing model
   request/result ports retain their payloads and cannot carry tokens or
   approval links. Nested calls on the connector's same MCP connection would
   deadlock behind the exported call's mutex and the Python request loop.
3. Bind connector connection UUID, provider owner, Browser owner, original
   session/target and host principal to each login operation. Public continuation
   records carry only safe operation identity and status.
4. Resolve the extension's numeric Chrome tab id separately from MASC's tab id
   and the CDP target id. The original Stagehand extension has debugger
   permission; Chrome's [getTargets contract](https://developer.chrome.com/docs/extensions/reference/api/debugger#method-getTargets)
   exposes a target id and an optional numeric tab id. That exact mapping is a
   candidate for the adapter, still requiring implementation and live proof.
   No first-match, active-tab or ambiguous URL fallback is permitted.
5. Run initialization/agentic mode, request/approval/status and fill through the
   original verified CDP transport. Keep approval URLs in private operator
   controls. Verify website authentication after fill, then resume the original
   Keeper task. Fill completion alone does not prove website sign-in.

## Verification scope

Focused source fixtures cover original session/tab binding, observation
exclusion, unknown/cancel fencing, queued cancellation, active close/reopen with
cleanup join, and abandoned public-call readiness. CDP/private Unix fixtures
exercise secret-bearing error inputs at the first decoder/transport boundary.
This external coding session ran parse-only checks and independent source
review, not Dune, an OCaml typecheck or these OCaml fixtures. It did not replace
the installed worker or perform a real 1Password login.
