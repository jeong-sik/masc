# Private Add-on operator controls

Packages may advertise exactly one `lane_operator` MCP tool. Its input schema
is discovered atomically with the original worker connection. It cannot appear
in `world.tools.export` or as the package's action tool. No package boolean or
second service owner is required.

`POST /api/v1/lane-addons/operator` is the only host ingress. It requires the
token-bound `CanAdmin` permission and an operator credential. Explicit browser
origins must match the served origin; reflected CORS and dev-origin widening are
absent. Native clients may omit Origin. Every response, including startup,
authentication, quota and body-reader errors, uses a fixed private error body
and `Cache-Control: no-store`.

The closed request envelope is either:

```json
{"instance_id":"original","expected_incarnation":"original","mode":"describe"}
```

or:

```json
{"instance_id":"original","expected_incarnation":"original","mode":"invoke","arguments":{"action":"view","arguments":{}}}
```

Describe returns `schema` or null. Invoke uses the original generative connection
owner and rechecks fresh enabled declaration authority after acquiring the
worker's RPC mutex. It holds no global lifecycle mutex during that check or the
RPC. A replacement worker is never adopted. MCP error/transport failure is an
unknown outcome; it revokes the original connection and retires that worker.
There is no automatic mutation retry.

The private call bypasses model exports, tool hooks/finalizers, `on_result`,
action receipts and retained observation output. Error text from the worker or
SDK is erased at this boundary. Packages must also keep private material out of
their public exports, observations, stderr and process arguments. This is an
authorization/data-flow boundary, not isolation from other processes with the
same operating-system UID.

## Dashboard view contract

The generic connection panel reads `action=view, arguments={}` and expects a
private structured object:

```json
{
  "title":"Account",
  "message":"Connect your account.",
  "actions":[{"id":"connect","label":"Connect","arguments":{},"fields":[],"opens_window":true}]
}
```

Each field has `name`, `label` and `secret` (boolean). All field values and
prefilled action arguments are strings. `secret=true` masks operator input.
`opens_window` is optional and requests a popup from the operator gesture. An
optional `open_url` may be HTTPS without userinfo, or the exact
`onepassword://grant-brokered-access` authority with an optional query and no userinfo,
port, path or fragment. It is consumed only in that popup. Other app schemes
and destinations are refused. Views stay in component memory and are discarded on workspace,
incarnation or dashboard credential changes.

Opening an app requests navigation; it does not prove the operating system
opened the app or that the person approved anything. The 1Password package
offers separate operation-pinned opened and approved acknowledgements. Its
approval link is redeliverable without creating another access request. These
controls never place the link in Ask, observations or model tool results.

An optional `callback` has `action`, `field`, prefilled `arguments` and `state`.
`GET /addons/oauth/callback` is a static page with no external resources, a
script hash CSP, no-store and no-referrer. It captures query plus fragment in
memory and posts only to its original same-origin opener. It keeps the original
URL and window until the panel acknowledges a matching backend receipt. The
panel admits only its exact original popup, path, origin and OAuth state, binds
the original connection ID, then sends the return to the authenticated private POST.
The package validates the exact configured destination and its durable pending
transaction again. The GET itself neither authenticates nor exchanges a code.
Deployment access logs for the registered callback must omit query strings.

An optional private `callback_receipt` has a closed `kind` (`captured` or
`declined`) and the original `connection_id`. `captured` confirms that the
original key reached validated protected storage with confirmed publication;
it does not prove that the code exchange or account connection succeeded.
Busy, unavailable or unconfirmed storage produces no capture receipt. A
`declined` receipt comes from the protected record that commits cancellation
and that original callback's state/connection together. Only a validated
`access_denied` redelivery with the same state and connection can confirm the
stored reference's durability and replay it, without rewriting the record or
calling the provider. Generic inspection, ordinary cancellation and malformed
or mismatched returns do not produce a declined receipt. A new connection
attempt replaces the original receipt; losing the original popup/component
authority remains a separate recovery boundary.

The original page accepts pending identity and receipt messages only from its
original opener and origin, matching state and connection ID. Only then does
it clear query/fragment from history, confirm clearing to that opener and close.
Absent, malformed or another connection's receipt cannot clear it. The panel
and original page retain an unconfirmed return for explicit same-request retry;
they never automatically retry a mutation or retarget it to a new attempt.
Confirmation of backend capture releases dispatch ownership even if the old
page has closed or its cleared notification is lost. Later operator windows do
not require that notification; this does not claim the old page cleared its URL
and does not close a navigated page on its behalf. A cancel or another mutation
that removes/replaces the original pending identity leaves a queued return
unconfirmed for explicit original-request retry, rather than automatically
dispatching it after that mutation completes.
The manual secret callback form follows the same ownership/receipt rule and
retains its input on failure, without inventing a popup acknowledgement.

Unmount, workspace or credential replacement discards component-owned private
state and resend authority. An already navigated original popup is left open
with its unconfirmed return; only a still-blank popup may be closed without a
receipt. A replacement opener/component cannot adopt it automatically. Losing
that original authority still requires explicit recovery. Keyless reconnect,
account-pinned key recovery and remote revocation remain separate package work;
no old account's key may be borrowed for a different connection.

## Evidence boundary

Focused dashboard tests exercise original-popup/state/workspace/credential
admission, private response decoding, explicit original-return retry and receipt
fencing. A literal script extracted from the actual OCaml route and the actual
Dashboard component exchange synthetic window messages using actual Python
Worker/Connector receipt packets from an owned temporary store and fake provider.
This crosses an explicit replayed HTTP-response port, not a running HTTP/MCP
host, browser process or native protected-store backend. The route was parsed;
there was no local Dune/full build or full OCaml typecheck. This source does not
prove an installed private route, real account, full Keeper or recovery result.
