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
optional `open_url` may be HTTPS without userinfo; it is consumed only in that
popup. Views stay in component memory and are discarded on workspace,
incarnation or dashboard credential changes.

An optional `callback` has `action`, `field`, prefilled `arguments` and `state`.
`GET /addons/oauth/callback` is a static page with no external resources, a
script hash CSP, no-store and no-referrer. It captures query plus fragment in
memory, immediately removes them from browser history and posts only to its
same-origin opener. The panel admits only its exact original popup, path,
origin and OAuth state, then sends the return to the authenticated private POST.
The package validates the exact configured destination and its durable pending
transaction again. The GET itself neither authenticates nor exchanges a code.
Deployment access logs for the registered callback must omit query strings.

If the original popup/opener is lost, no callback is replayed or sent to a
replacement. Inspect the connection and explicitly cancel that pending attempt
before starting again. Provider/extension approval links and remote disconnect
are separate package operations, not implied by this OAuth connection panel.

## Evidence boundary

Focused dashboard tests exercise original-popup/state/workspace/credential
admission and a single private transport attempt. Protocol and request-envelope
tests are present for independent source review; this external coding session
did not run Dune or an OCaml typecheck. The live development status installation
predates these host changes. This source does not prove an installed private
route or a successful provider connection.
