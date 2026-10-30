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

An extension worker's loss resolves an original-session fence signal. Already
running public and private work is cancelled and its cleanup joined before the
serializer returns. Public calls check admission before and after every runtime
call and again before publishing a result. A synchronous callback or one that
returns while handling cancellation cannot publish a capture or successful private
result after that fence. The signal belongs to the original opened resource;
late cleanup and stale worker events cannot fence a successor.

Private values do not pass through a `Browser_lane.answer`, public tool result,
action receipt or observation. CDP JSON parsing, command send and WebSocket
errors use fixed messages at their first boundary, since connection-ended
reasons also reach public lifecycle status and operator logs. The private Unix
service likewise discards parser fragments and unexpected exception text.
Adapters must also erase raw CDP command-rejection and provider error text.

## Private extension transport

`Browser_extension_protocol` describes prepare/invoke/release with a one-use
operation UUID. The dedicated `Extension`/`Extension_reply` Unix wire operation
is attached once to the same owned Chrome backend. Admission is released before
waiting; retirement removes that callback before resource teardown. Ordinary
browser service ingress refuses this operation. It has no model tool schema,
model-request queue, durable payload or public result hook.

The adapter loads a trusted installed extension directory through the original
CDP transport, checks its exact extension ID and attaches only that extension's
single service worker. Target discovery is event-driven. Worker detach/loss fences
the original session instead of selecting another worker. Prepare retains the
page slot until trusted package setup returns exactly `{ready:true}`. The
1Password setup program waits for initialization and enables agentic mode for
the whole browser before observations can resume.

Every invocation resolves the original CDP page target through
`chrome.debugger.getTargets()` in the original Stagehand extension worker. That
extension's verified manifest already grants debugger permission. The exact target
must have one numeric Chrome tab ID and the same HTTPS URL observed through CDP.
There is no cast from MASC tab ID, active-tab lookup or URL-match fallback.

The private 1Password package programs implement request/status/fill with a
closed argument set and safe error projections. Grants match their requested
entry ID. Before request/fill they recheck the exact numeric tab's URL and the
requested HTTPS origin. Fill returns only `fill_submitted`; any failure after
provider entry throws a fixed error so the backend fences the original session.
Website authentication is a separate observation after confirmed fill settlement.

## Next integration boundaries

This is source implementation; no host built from this layer is installed and no
1Password extension/account was exercised. The remaining implementation must:

1. Wire the [independent private broker](lane-addon-companion-broker.md) into
   the original provider's runtime/private call context. Its host socket and
   Python transport are source implementation; the runtime factory remains open.
   Existing model request/result ports retain their payloads and cannot carry
   tokens or approval links. Nested calls on the connector's same MCP connection
   would deadlock behind the exported call's mutex and Python request loop.
2. Bind connector connection UUID, provider owner, Browser owner, original
   session/target and host principal to each login operation. Public continuation
   records carry only safe operation identity and status.
3. Connect the package's programs and request/approval/status/fill lifecycle to
   the private transport. Keep approval URLs in private operator
   controls. Verify website authentication after fill, then resume the original
   Keeper task. Fill completion alone does not prove website sign-in.

## Verification scope

Focused source fixtures cover original session/tab binding, observation
exclusion, unknown/cancel fencing, queued cancellation, active close/reopen with
cleanup join, and abandoned public-call readiness. CDP/private Unix fixtures
exercise secret-bearing error inputs at the first decoder/transport boundary.
Additional source fixtures cover exact extension-worker attachment, one-use
operation binding, in-flight worker loss, cancellation-ignoring callbacks, owner
retirement, indefinite private wait and distinct reply kinds. Eight Node tests
execute the actual package programs with fake extension APIs and passed.
This external coding session ran parse-only checks and independent source
review, not Dune, an OCaml typecheck or these OCaml fixtures. It did not replace
the installed worker or perform a real 1Password login.

Primary contracts: Chrome [debugger target mapping](https://developer.chrome.com/docs/extensions/reference/api/debugger#method-getTargets),
CDP [extension loading](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/)
and [Browserbase's 1Password integration](https://docs.browserbase.com/integrations/1password/agentic-autofill).
