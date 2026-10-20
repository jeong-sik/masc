# Browser worker

This package runs `masc-browser-addon-worker` as a native Add-on. The installed
worker and `masc-native-addon-launcher` must be available on the server's PATH.
The host supplies the private socket, incarnation and message bound; package
bindings cannot choose them. Native execution uses a foreground process group
and durable resource claims. It is not a container sandbox.

The worker exports `browser_command` through ordinary Add-on discovery. The host
supplies verified caller context through the private control port. The package
selects `validate_input` and `validate_output`; an installation can override
`tool_hooks`, including `[]` to disable these optional checks. Identity,
incarnation, browser selection and command decoding remain mandatory.

Input arguments contain a `command` with `verb` and `args`, plus optional `lane`
and `clientId`. An unbound command can select an available browser automatically;
tab/document work repeats the returned selection. `page.read` with
`includeHtml = true` reads document source. The bundled browser skill describes
guarded input and partial-result handling.

Initial `tabs.list` or `session.open` commands may supply `requiredActions`, using
the operation names from the browser capability catalog. Automatic selection
considers those capabilities; explicit connections are checked before dispatch
too. An explicit `lane = "live"` tab creation requires the observed `clientId`.

`Browser_addon_tools` prepares the existing public browser aliases for this host
path, retaining contextual/scene/screenshot projections, capability receipts,
caller attribution and producer effect metadata. Public core/Keeper dispatchers
use this adapter. Screenshot retention and Vision handles belong to the served
Workspace; download and upload ownership still require a transfer broker.

The worker publishes connection observations through MCP. Its separate private
socket lets browser commands wait while client polls and results use other
connections. Runtime reads its running observation through that private channel,
independently of a waiting MCP command. Service handles name one original connection and cannot
follow a replacement installation. Detach confirms both process settlement and
socket cleanup before releasing that incarnation. Interrupted startup recovery
reads the socket allocation intent from the original native reservation.

Authenticated native-host HTTP routes forward polls, results and disconnects to
this Add-on. They use the served workspace's lane token, even when the process
environment points elsewhere. A new client can register only when one browser
Add-on is available. Its ID and full identity are durably bound to that original
worker under `<base-path>/.masc/browser-lane/registrations/`. Existing IDs are
never assigned to a replacement. A temporary observation failure returns
unavailable and requests an observation refresh; confirmed retirement tells the
host to open a fresh connection. There is no built-in queue fallback.

The authenticated `POST /api/v1/dashboard/browser-lane/command` endpoint accepts
the same `browser_command` arguments. It requires the existing Dashboard admin
permission and uses the authorized actor, rather than an identity in the body.
For example, its JSON body can be:

```json
{"command":{"verb":"tabs.list","args":{}}}
```

The HTTP response's `data` is the original MCP tool result. Check its `isError`,
`structuredContent` and `_meta` before further input; an accepted HTTP request
does not mean the browser operation succeeded. This endpoint accesses shared
installations only and uses their selected input/output hooks. A workflow that
holds a host handle retains its original service and exported-tool generation;
it cannot follow a replacement.

The existing Dashboard browser `clients`, `read`, `scene`, `screenshot`,
`interact`, `session` and `goto` routes used by the TUI also use this host path.
Read routes keep their read permission; input routes require the authorized admin
actor. The inventory comes from the retained worker. A page read pins the
connection chosen during tab discovery, and a tab-bound read requires its
original lane/client ID before discovery. Scene, navigation and screenshot
identity guards remain active. Returned connection identity comes from the
worker's admitted target, independently of page-supplied fields. Partial or
unknown outcomes preserve the original receipt and effect metadata without
repeating the input. These source changes do not establish an installed TUI or
an actual browser run.

Install a declaration using the active configuration directory described in the
[TOML guide](../../docs/guides/lane-addon-toml.md), pointing `manifest_path` at
this package's actual absolute path or a path relative to that declaration:

```toml
id = "browser"
run_id = "browser-work"
manifest_path = "/absolute/path/to/masc/addons/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

[binding]
sources = []
```

The installed native host and browser extension/BiDi peer still need the same
workspace token. When automation is configured, the worker starts its owned
Gecko driver with a private profile and download directory. Detach confirms
driver and descendant settlement before releasing that allocation. Stagehand
Chrome ownership and built-in live browser startup remain to be moved. This is
not yet a complete operator-browser replacement.

Input/output middleware validates tool contracts without calling an LLM. LLM
Exact Output is selected separately through a package's declared outputs and an
installation's `exact_outputs` override. For selected outputs, the host supplies
an immutable private model configuration. Worker requests use concurrent private
socket ports, so a command waiting for a model does not block its result. An
event wait wakes the shared Exact Output runner without periodic polling.
Cancelling the original command withdraws its request and cancels that Exact
scope; detach fences all pending model work. No input is replayed.

Before waking the original waiter, the worker retains a receipt under the host's
Add-on store, outside the disposable browser allocation. This records model
result receipt, not browser action completion. Identical duplicate deliveries
are acknowledged and conflicting results are refused. The worker has no model
credentials or provider route resolution.

The bundled package has no declared model outputs or browser model consumer yet.
This queue does not establish `page.locate` or Stagehand model support. Actual
browser/model execution evidence also remains. Follow this work in
[issue #44150](https://github.com/jeong-sik/masc/issues/44150).
