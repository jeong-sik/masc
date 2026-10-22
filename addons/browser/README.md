# Browser worker

This package runs `masc-browser-addon-worker` as a native Add-on. The server
finds the worker on its PATH, and `masc-native-addon-launcher` and
`masc-browser-process-owner` beside the masc executable or on its PATH.
The host supplies the private socket, incarnation and message bound; package
bindings cannot choose them. Native execution uses a foreground process group
and durable resource claims. It is not a container sandbox.

`scripts/install-local-build.sh` builds and installs the three programs with
masc, into the same prefix (`~/.local/bin` by default; `--prefix DIR` chooses
another). Ensure the server process receives that prefix on its actual `PATH`,
including when started by a service manager. `--skip-build --build-dir DIR`
requires all three executable inputs alongside the ordinary installer inputs;
missing or non-executable inputs are refused before installed programs or guest
shims change. The release download installer does not supply these programs.

masc carries this package. After installing, the script runs
`masc browser-lane-setup --mode addon` for the workspace, and every other
`browser-lane-setup` mode does the same:

- It writes the package to `<base-path>/.masc/packages/browser/`. An upgraded
  masc rewrites the files there, so the declaration does not change.
- When the workspace has no declaration of this package, it creates
  `browser.toml` in the Lane directory (`<base-path>/.masc/config/lane-addons/`,
  or the one under `MASC_CONFIG_DIR`). An existing declaration of the package is
  left as it is; setup reports it, and names the `manifest_path` line to use
  when it points at another copy. Two declarations of the package are refused,
  because the server would attach both and refuse every host poll as ambiguous.

Setup attaches nothing. The server attaches the declared Add-on when it starts
and on its maintenance pass. Set `enabled = false` in the declaration to keep
it detached.

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
Workspace. Owned Gecko uploads and downloads use host-mediated transfer
brokers independently of the optional validation hooks and model consumers.

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

`masc browser-lane-setup --mode addon` writes this declaration; the
[TOML guide](../../docs/guides/lane-addon-toml.md) describes every key. To
choose hooks or model outputs, add them to the `browser.toml` setup wrote;
setup never rewrites an existing declaration:

```toml
id = "browser"
enabled = true
run_id = "browser"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]
exact_outputs = ["locate", "stagehand"]

[binding]
sources = []
```

The installed external native host and browser extension/BiDi peer use the
workspace token. The worker itself can own configured automation, Stagehand
Chrome, and live Firefox BiDi backends independently. It starts its Gecko driver
with a private profile/download directory; Chrome sessions use a private or
explicit persistent profile. A configured live Firefox starts during worker
attachment, on its dedicated existing owner-only profile. Its reported profile
and process ID must match the original process owner. A busy port is refused;
no external Firefox is adopted. See the [Firefox setup guide](../../docs/design/browser-bidi-live-host.md).

Backend settings are captured at attachment from the loaded `runtime.toml`.
Restart after changing runtime settings, then detach/reattach an existing
installation. Declaration edits reconcile at startup and on the maintenance
pulse. Check desired/applied revisions, phase and configuration issues; saving
TOML does not establish readiness. Disable an installation with its top-level
`enabled = false` and verify detachment before reusing its resources.

Retirement fences input before joining the original live, automation and
Stagehand cleanups. Concurrent or repeated retire requests observe the same
cleanup result; an error prevents a successful retirement receipt. Confirmed
settlement releases the private allocation while persistent profile contents
and stable claims are preserved. External extension/manual browsers remain
operator-owned. Interrupted issued input stays uncertain and is never replayed.

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

The host passes an explicit operational environment to the browser launcher,
worker and its browser/driver children: process paths and temporary directories,
locale, desktop display/session settings, font configuration and certificate
paths. Other host environment entries, including provider API keys, are omitted.
Allowed values are preserved; `HOME` is not rewritten. Browser configuration
still comes from the private admission. This prevents unnecessary environment
inheritance; the native worker runs as the same OS user and is not a sandbox
against reading that user's files.

A package can explicitly grant `request_schema = true` for a selected model
output. The model requirement then uses the original canonical request schema;
the package baseline remains mandatory. The shared broker and worker receipt
check required object keys, visited primitive types and `anyOf` before accepting
the result. The consuming SDK owns complete validation of its schema dialect;
this partial guard is not a full JSON Schema validator. Baseline and grant are
both pinned to the worker incarnation. The bundled fixed `locate` output does
not grant request schemas.

The package's `stagehand` output grants request schemas and declares an open
structured-object baseline. `Browser_addon_stagehand_model.for_owner` constructs
the actual Stagehand session model callback only for that selected contract.
It routes text/structured protocol requests through the original owner queue
and the host's shared Exact Output runner, then returns Stagehand's existing
structured answer format and reported usage. The result itself is not wrapped.
User/assistant roles and text-block order remain; blocks within one turn join
with two newlines. Image/tool blocks, text/tool generations and supplied
temperature/stop options are refused before model queue admission. Caller
cancellation withdraws the waiter; retirement wakes it; uncertain results return
an error without an automatic retry. Captured-protocol/loopback-provider
scenarios and isolated owned Chrome scenarios cover this callback. See the exact source and execution scope in the
[lifecycle evidence](../../docs/design/browser-addon-lifecycle.md#completion-evidence);
these checks do not establish deployment or provider response quality.

The bundled package declares the fixed `locate` output and connects it to owned
Gecko `page.locate`. Configure an existing model slot for the installation's
`runtime.addon_exact_lanes.<installation-id>.locate` route using the
[TOML guide](../../docs/guides/lane-addon-toml.md). Package defaults select this
output; installation `exact_outputs = []` disables it independently of tool
validation hooks. Inventory `locate` observes the selected consumer, not provider
readiness. A missing/off/unavailable route remains pending under the existing
Exact Output policy until an authority event or original-command cancellation.

For the public alias, use `BrowserInstruct` with `action = "observe"`, the
observed `lane = "automation"` and `tabId`, and an optional instruction. Every
BrowserInstruct action requires the observed owned lane; act/extract still
require Stagehand. A bound tab cannot move to another browser.

The model selects node IDs from a typed scene; it supplies no selectors, code,
coordinates or input actions. The driver reads the same tab again and refuses
changed documents, URLs, missing nodes or changed observed meaning. Returned
geometry and node observations come from this fresh read. The model's explanation
is separate inference, and a match grants no permission to click. A truncated
scene never establishes that all matching elements were found. The original
command or detach owns model waiting; the quick browser transport clock does
not abandon its request.

Scripted protocol cases, actual isolated Chrome/BiDi/Gecko cases and installed
browser behavior are separate evidence scopes. New production changes require
their own recorded verification; a historical passing run does not prove the
current installed runtime. Follow the
[lifecycle evidence](../../docs/design/browser-addon-lifecycle.md#completion-evidence)
and [issue #44150](https://github.com/jeong-sik/masc/issues/44150).
