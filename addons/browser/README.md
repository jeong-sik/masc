# Browser workers

The browser source has its package here: `ego/`, with the id `browser-ego`.
The package runs `masc-browser-addon-worker` as a native Add-on for the
source its `lane.toml` names in `browser_backend`. The server finds the worker
on its PATH, and `masc-native-addon-launcher` beside the masc executable or on
its PATH.
The host supplies the private socket, incarnation and message bound; package
bindings cannot choose them. Native execution uses a foreground process group
and durable resource claims. It is not a container sandbox.

`scripts/install-local-build.sh` builds and installs the two programs with
masc, into the same prefix (`~/.local/bin` by default; `--prefix DIR` chooses
another). Ensure the server process receives that prefix on its actual `PATH`,
including when started by a service manager. `--skip-build --build-dir DIR`
requires both executable inputs alongside the ordinary installer inputs;
missing or non-executable inputs are refused before installed programs or guest
shims change. `--no-browser-addon` leaves the two programs out and the
workspace's Add-ons as they are; without them no browser route works. The
release installer, `scripts/install.sh`, installs both programs from the same
release into its prefix beside masc. It does not declare the Add-on; a
`browser-lane-setup` run does, as below.

masc carries these packages. After installing, `install-local-build.sh` runs
`masc browser-lane-setup --mode addon` for the workspace, and every other
`browser-lane-setup` mode does the same, when `runtime.toml` has
`[browser.live.ego]` or the run writes it. The source is declared once its
table is written.

- It writes each package to `<base-path>/.masc/packages/browser-<source>/`. An
  upgraded masc rewrites the files there, so the declaration does not change.
- When the workspace has no declaration of a source, it creates
  `browser-<source>.toml` in the Lane directory
  (`<base-path>/.masc/config/lane-addons/`, or the one under
  `MASC_CONFIG_DIR`). An existing declaration is left as it is; setup reports
  it, and names the `manifest_path` line to use when it points at another copy.
  Ego installations may name independent Spaces in `binding.space`; setup retains
  the workspace-default declaration instead of replacing a Goal installation.

Setup attaches nothing. The server attaches the declared Add-ons when it starts
and on its maintenance pass. Set `enabled = false` in a declaration to keep
that source detached. `browser-lane-setup --no-addon` makes a mode other than
`addon` leave the packages and the declarations as they are.

Distinct Ego installations are routed by their observed client and native
Space identities.

An Ego installation can select its own Space without changing the workspace's
`[browser.live.ego]` table:

```toml
id = "browser-ego-own-goal"
run_id = "own-goal"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser-ego/lane.toml"

[binding]
sources = []
space = "unique-own-goal-space"
```

`space` is a nonblank native name to create/resume, or a nonnegative
JavaScript-safe integer to resume that exact existing Space. Numeric text is a
name. Omission uses the existing workspace Space; an invalid explicit value
never falls back. The host still chooses the configured Ego executable. This
setting participates in the installation revision and grants no claim, adoption
or takeover of a user-owned Space. Declaration save and manual attach validate
it before worker allocation.

Discover the resulting live clients and retain the exact client UUID/Space.
Distinct Spaces on distinct workers remain visible; an automatic ambiguous
choice is refused. A UUID advertised by multiple controllers, or two controllers
of the same native Space ID, is refused before Page dispatch. Space IDs are
interpreted inside the single Ego native runtime this workspace serves; separate
Ego runtimes need a distinct namespace before they can share this registry.

`masc_browser_session action=bind_goal` can select an already observed Space for
an existing Goal. It is selection metadata, not an ACL or a provisioning receipt.
Keeper initial automatic discovery uses its current Task's Goal; later calls
retain the selected lane/client. A reconnect may change the client UUID but must
resolve the same installation and numeric Space. Replacement installations do
not inherit a binding silently. Task completion requires a confirmed native
`finish_space` receipt for only the owned Space before detaching that installation;
retirement alone preserves an active Space, and an unknown finish is never replayed.

An unreadable or unready live-source publisher can hide another controller of
the same native Space. Until every live publisher's identity is observed, Ego
commands and Goal pins are refused before dispatch, including exact-client and
stored Goal routes. Cached
`browser_document` reads preserve the same unknown-identity refusal.
The host rechecks topology after snapshot I/O; this admission observation does
not provide an atomic native-Space lease against later lifecycle changes.

The worker exports `browser_command` to its host only. A browser service's
exports are not public tools, so Keeper tool lists and MCP `tools/list` leave
them out and several browser installations may export the same name. The host
supplies verified caller context through the private control port. The package
selects `validate_input` and `validate_output`; an installation can override
`tool_hooks`, including `[]` to disable these optional checks. Identity,
incarnation, browser selection and command decoding remain mandatory.

The host chooses the browser from the worker's snapshot and then calls the
worker's `browser_command` with that `lane`, and for live its `clientId`; the
worker runs only that route and states no identity of its own. The public
command shape that host callers send (the dashboard endpoint below) contains a
`command` with `verb` and `args`, plus optional `lane` and `clientId`. An
unbound command lets the host select an available browser automatically;
tab/document work repeats the returned selection. `page.read` with
`includeHtml = true` reads document source. The bundled browser skill describes
guarded input and partial-result handling.

An initial `tabs.list` command may supply `requiredActions`, using
the operation names from the browser capability catalog. The host's automatic
selection considers those capabilities; explicit connections are checked before
dispatch too. An explicit `lane = "live"` tab creation requires the observed `clientId`.

`Browser_addon_tools` prepares the existing public browser aliases for this host
path, retaining contextual/scene/screenshot projections, capability receipts,
caller attribution and producer effect metadata. Public core/Keeper dispatchers
use this adapter. Screenshot retention and Vision handles belong to the served
Workspace. The ego worker uses host-mediated upload and download brokers,
independently of the optional validation hooks; the other sources have none.

The worker publishes connection observations through MCP. Its separate private
socket lets browser commands wait while other connections are in use. Runtime reads its running observation through that private channel,
independently of a waiting MCP command. Service handles name one original connection and cannot
follow a replacement installation. Detach confirms both process settlement and
socket cleanup before releasing that incarnation. Interrupted startup recovery
reads the socket allocation intent from the original native reservation.

In Dashboard → Lane Add-ons, browser connection rows show each connection's
browser, transport and Ego Space ID/name, plus pending requests and the last
recorded result per caller. Caller labels such as `keeper/<name>` come from the
host's verified request context. The aggregate worker row can have no actor
while individual requests have different callers. Missing caller information
stays unrecorded rather than being assigned to a Keeper.

These readings describe the row's observation time. Retained workers and queued
or running requests are labelled accordingly; Refresh reads newer observations.
The readings do not report native Space ownership or window visibility, and a
returned operation alone does not establish login success. Browser handoff
remains a separate action.

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

`masc browser-lane-setup --mode addon` writes these declarations; the
[TOML guide](../../docs/guides/lane-addon-toml.md) describes every key. To
choose hooks, add them to the `browser-<source>.toml` setup wrote; setup never
rewrites an existing declaration:

```toml
id = "browser-ego"
enabled = true
run_id = "browser-ego"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser-ego/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

[binding]
sources = []
```

Backend settings are captured at attachment from the loaded `runtime.toml`. A
source whose table is missing does not start, and its package row says so.
`runtime.toml` says how a source starts, never whether it runs: that is its
declaration's top-level `enabled`.
Restart after changing runtime settings, then detach/reattach an existing
installation. Declaration edits reconcile at startup and on the maintenance
pulse. Check desired/applied revisions, phase and configuration issues; saving
TOML does not establish readiness. Disable an installation with its top-level
`enabled = false` and verify detachment before reusing its resources.

Retirement fences input before joining the cleanup of the worker's own
source. Concurrent or repeated retire requests observe the same
cleanup result; an error prevents a successful retirement receipt. Confirmed
settlement releases the private allocation while persistent profile contents
and stable claims are preserved. Interrupted issued input stays uncertain and is
never replayed.

Input/output middleware validates tool contracts without calling an LLM. A
browser package declares no Exact Output and no operator asks; the manifest
refuses either, so the worker opens no host request port and holds no model
configuration, credentials or provider route.

The host passes an explicit operational environment to the browser launcher,
worker and its children: process paths and temporary directories,
locale, desktop display/session settings, font configuration and certificate
paths. Other host environment entries, including provider API keys, are omitted.
Allowed values are preserved; `HOME` is not rewritten. Browser configuration
still comes from the private admission. This prevents unnecessary environment
inheritance; the native worker runs as the same OS user and is not a sandbox
against reading that user's files.

Scripted protocol cases and installed browser behavior are separate evidence scopes. New production changes require
their own recorded verification; a historical passing run does not prove the
current installed runtime. Follow the
[lifecycle evidence](../../docs/design/browser-addon-lifecycle.md#completion-evidence)
and [issue #44150](https://github.com/jeong-sik/masc/issues/44150).

An Ego answer reports `inputReadiness: release_uncertain` when an
input-holding command ended without the SDK declaring its release. Later input
on the same connection runs; the value is an observation. Original
gesture cleanup, visible UI and login completion are separate observations.
