---
title: Browser Lane Guide
description: Connect Firefox or Zen or the Stagehand Chromium as an Addon, select validation and model hooks, and use the Browser Lane TUI.
---

The browser Lane Addon owns the worker and its configured browser backends.
Install it once, then select the input/output validation hooks and model
consumers for that installation independently. Browser names and connection
transports describe capabilities; they are not separate installation systems.

- **live** connects an existing Firefox or Zen through its WebExtension, or
  starts a dedicated Firefox through the Addon-owned BiDi backend. Existing
  extension tabs keep their logins; managed Firefox uses its dedicated profile.
  Native hover and drag require a compatible connection such as BiDi.
- **automation** uses the worker's OCaml WebDriver client and geckodriver for an
  isolated Gecko session. The Addon owns the driver, browser, and private profile.
- **stagehand** uses an Addon-owned Chromium and the Stagehand extension over
  CDP. It supports native interactions and optional sentence/model operations.
  A configured persistent profile keeps logins; otherwise a private profile is
  created for the owned session.

For an unbound request, automatic selection considers the available browsers
and required actions. Keep the returned browser identity for tab/document work;
a bound tab or explicit connection does not fall back to a different browser.
Check the reported capability inventory rather than assuming every transport
supports every action. Safari is not a backend in this package.

## Install the browser Addon

Prepare the installed `masc-browser-addon-worker`, `masc-native-addon-launcher`,
and `masc-browser-process-owner` executables on the server's PATH. Use the
bundled package manifest at its actual location. In the active config root's
`lane-addons/browser-work.toml`, save:

```toml
id = "browser-work"
run_id = "browser-work"
manifest_path = "/absolute/path/to/masc/addons/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]
exact_outputs = ["locate", "stagehand"]

[binding]
sources = []
```

The default directory is `<base-path>/.masc/config/lane-addons/`; an existing
`MASC_CONFIG_DIR` override selects another config root. Dashboard **TOML
configuration** shows the actual directory; **New TOML / Edit TOML** edits the
same declarations. `manifest_path` is absolute or relative to the declaration
file, not the shell's working directory. Installation ID, worker incarnation,
and browser `clientId` are separate identities.

| Independent option | Meaning |
| --- | --- |
| `tool_hooks = ["validate_input"]` | Validate tool input before dispatch |
| `tool_hooks = ["validate_output"]` | Validate the final successful structured reply after artifact mediation |
| `tool_hooks = ["validate_input", "validate_output"]` | Enable both tool checks |
| `tool_hooks = []` | Disable the optional tool checks |
| `exact_outputs = ["locate"]` | Select the Gecko scene-node model consumer |
| `exact_outputs = ["stagehand"]` | Select the Chromium structured model consumer |
| `exact_outputs = ["locate", "stagehand"]` | Select both model consumers |
| `exact_outputs = []` | Disable both model consumers |

Omitting either array uses that package default. These are named middleware
and declared model outputs; arbitrary executable hooks are not loaded. With
both arrays empty, caller authorization, worker incarnation, wire decoding,
document/viewport binding, artifact ownership, and cleanup checks still apply.
Non-model actions remain available where the backend supports them.

Selecting an output does not configure a model provider. Configure existing
model slots separately in `runtime.toml` under
`runtime.addon_exact_lanes.browser-work.locate` and/or
`runtime.addon_exact_lanes.browser-work.stagehand`. Model availability and
consumer inventory are separate observations. A missing or unavailable route
uses the shared Exact Output waiting/cancellation policy; it does not authorize
a different browser or input replay.

Backend settings below are loaded from the resolved `runtime.toml` at server
startup and captured when an installation attaches. Restart after changing
those settings, and detach/reattach an existing installation to capture them.
Installation declaration edits are reconciled at startup and on the existing
maintenance pulse. Saving TOML is not an attachment receipt: inspect
`desired_revision`, `applied_revision`, `phase`, and configuration issues.
Dashboard Refresh reads that state rather than forcing reconciliation.

To stop this installation, set its top-level `enabled = false` and verify
detachment and cleanup. Removing its declaration takes effect after a complete
config scan. The worker fences input before joining its original owned
resources; unconfirmed cleanup remains a failure. A replacement has a fresh
incarnation and connection IDs. External extension/manual browsers retain
operator ownership. Persistent profile contents are preserved.

## Setup: live

Install the OCaml native host and the extension on the browser's machine.
`--base-path` is the workspace containing `.masc`, not the `.masc` directory
itself. The host is the `masc-browser-host` installed beside `masc`; `--binary`
names another one, and is never the Firefox or Zen executable.

```bash
masc browser-lane-setup --mode extension --base-path /path/to/workspace
```

The launcher records no server address: the host reads the port from the
workspace's `.masc/config/connection.toml`. After a failed poll it reads that
file again and moves to the port it names only when the current server no
longer answers and the new port does, so a server restarted on another port is
found without reinstalling.

For a dedicated Firefox without the extension, configure the Addon-owned BiDi backend:

```bash
masc browser-lane-setup --mode bidi --base-path /path/to/workspace
```

This prepares `[browser.live.bidi]` and the dedicated profile. Explicit
`--firefox`, `--profile`, and `--port` replace their keys; omitted keys retain
their values. Follow the [Firefox BiDi guide](../browser-bidi/) to attach and
verify the managed connection. `--mode host` installs the standalone host and
launcher for an external connection; it does not attach an Addon or start a browser.

The `--mode extension` command supports macOS and Linux and registers a
Mozilla native-messaging manifest. `--manifest-dir` selects a different manifest directory when needed.
It also writes the extension to `<base-path>/.masc/browser-lane/extension/`. In
Firefox or Zen, open `about:debugging` → **Load Temporary Add-on** and select
`manifest.json` there. Temporary loading ends when that browser exits.

Each running connection reports its browser identity and a `clientId` UUID. One
live connection can be selected automatically; with several, choose the desired
UUID. Tab IDs belong to a connection and can overlap between browsers. A stale
UUID is refused instead of selecting another browser. Reconnecting creates a new
UUID, so discover and select it again.

## Setup: automation

To inspect or install the host browser binaries first, run `masc prerequisite-actions firefox` and `masc prerequisite-actions geckodriver`. Then `masc browser-lane-setup --mode automation` writes the `[browser.automation]` configuration for you. It names the
`geckodriver` that `PATH` finds first, when it answers `--version` (`--geckodriver` names
another; `--browser` writes `binary`), keeps values that are already there, and
installs no host or extension. Or set the geckodriver executable in the resolved
configuration directory's `runtime.toml` yourself, then restart MASC:

```toml
[browser.automation]
geckodriver = "/absolute/path/to/geckodriver"
# Optional: select an installed Firefox or Zen executable.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

The attached worker starts geckodriver on a free loopback port and joins its
owned resources on detach, so there is no driver to run or port to choose.
`geckodriver` must be an absolute path. `binary` must be an absolute path and
requires `geckodriver`. When omitted, geckodriver discovers the browser; set it
explicitly to select Firefox or Zen. Changing it does not select a live
connection. Automation opens headless by default.

## Setup: stagehand

Install the pinned Stagehand extension into the workspace. The script checks
the npm package against the registry's integrity hash and prints the lines for
`runtime.toml`:

```bash
bash connectors/browser/install-stagehand-extension.sh --base-path /path/to/workspace
```

Add them under `[browser.stagehand]` with a Chromium-family executable, then
restart MASC:

```toml
[browser.stagehand]
chrome = "/absolute/path/to/chrome"
extension = "/absolute/path/printed/by/the/installer"
# Optional: a profile you own, kept between sessions (for logins).
# profile = "/absolute/path/to/profile"
```

All configured paths are absolute. The worker loads the extension over CDP
with `Extensions.loadUnpacked`; the chosen Chromium build must support that
method. The debugging port listens on loopback. With `profile`, use an existing
owner-only directory owned by the MASC account; its contents are preserved.
Without it, the worker creates a private session profile.

`BrowserSession lane="stagehand" action="open"` opens or reuses that worker's
session. Native input does not require a model. `BrowserInstruct` uses the
independently selected `stagehand` consumer and installation-specific Exact
Output route described above. A disabled consumer is refused; a selected one
still needs a configured, available model route.

Session close and Addon detach join the original resources. A failed or lost
session keeps its end reason; rediscover the current session and tabs before
continuing. Coordinate use before closing a shared session. An input with an
uncertain result must not be repeated just because the connection changed.

## Keeper and MCP tools

Keeper-facing names use CamelCase; the MCP registration names use `masc_browser_*`.

| Keeper tool | MCP name | Source and behavior |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | All three: list tabs and discover the live connection identity |
| `BrowserRead` | `masc_browser_read` | All three: text, visible elements, scene or regions, or a viewport PNG. Frames, dialogs and downloads: automation |
| `BrowserInteract` | `masc_browser_interact` | Click, fill, scroll and other input in one explicit tab; native hover/drag/keyboard and zoom depend on transport capabilities |
| `BrowserSession` | `masc_browser_session` | Automation or stagehand: open, close, or check the session |
| `BrowserGoto` | `masc_browser_goto` | Automation or stagehand: navigate to an HTTP(S) URL |
| `BrowserAct` | `masc_browser_act` | Automation: tab, form and history actions; Stagehand: tab/history actions; live BiDi: open_tab |
| `BrowserInstruct` | `masc_browser_instruct` | Selected Stagehand consumer: act/observe/extract; selected Gecko locate consumer: observe |

After discovery, pass the observed `clientId` and `tabId` to live reads and
interactions. A `clientId` is required when several live browsers are connected;
omit it for automation.

`BrowserRead` defaults to `mode="text"`, `format="text"`, and 50,000 Unicode code
points; `maxChars` can rise to 100,000. Inspect `truncated` in the result.
`mode="elements"` returns visible controls with labels and observed CSS
selectors, subject to response bounds; inspect truncation and scope when needed.
`format="image"` requires an explicit `tabId`; Keeper calls return a
durable artifact handle for image analysis. Text and element reads describe the
current rendered page, not every hidden or virtualized item.

`BrowserInstruct` takes `action` (`act`, `observe` or `extract`), an
`instruction` sentence (required for act and extract), a `tabId` from
`BrowserTabs lane="stagehand"`, and for extract an optional `schema`: JSON
Schema text for the data to return. It returns Stagehand's `data` and
`metadata`. The selected Gecko `locate` consumer instead serves
`BrowserInstruct action="observe" lane="automation"` on an observed tab.
An act can change the page, so verify the result with Stagehand
`observe` or `extract`; a failed act may have acted. `observe` and `extract`
only read.

Use observed selectors for `BrowserInteract` click/fill and `BrowserAct` element
actions; a selector must match exactly one element. For `BrowserInteract`, pass
`expectedUrl` from the last read to reject intervening navigation. Fill emits page
events and does not itself press Enter or submit. Read or capture the page after
an action, including an error, before deciding whether to retry.
On BiDi and owned WebDriver, guarded semantic clicks use native pointer input;
Stagehand uses its native click method. The WebExtension uses DOM click. Fill
and native typing are distinct actions. Check transport capabilities and read
the page after input to verify the application effect.

## TUI reader

Press `Ctrl-^` (Ctrl-Shift-6), use `:` → `go Browser Lane`, or press `B` from
Connectors. The reader starts with **Automatic** selection. Press `b` to choose
Automatic, a separate **Work browser**, or an observed connection with existing
logins. Move with `j`/`k`, confirm with Enter, refresh the chooser with `r`, and
return with Esc. Reads and captures keep the selected connection; a disconnected
selection requires an explicit new choice.

To open a separate work session, press `o`, then `g` and enter a URL. To use an
existing login, choose that connection with `b` and select one of its observed
tabs. Press `A` to expose the advanced backend choices when a specific transport
is needed. The `l`/`a`/`c` shortcuts are available only in advanced mode.

| Key | Action |
| --- | --- |
| `b` | Choose Automatic, Work browser, or an observed connection |
| `A` | Open the chooser with advanced backend choices |
| `l` / `a` / `c` | Advanced mode only: live / automation / Stagehand |
| `h` | Open the selected Keeper's browser observation history (`[`/`]` switches saved pages, `y` copies receipt/artifact ref) |
| `[` / `]` | Previous / next tab and read its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover and refresh |
| `Ctrl-O` | Preview the selected tab's PNG; any key returns |
| `g` | Enter a URL for an owned work session; Enter navigates, Esc cancels |
| `o` / `x` | Open a work session / close the selected owned work session |
| `Ctrl-^` / Esc / Left | Hide the reader and return |

PNG previews require terminal image support; otherwise the reader explains the
limitation. A preview is not sent to a Keeper. TUI keys provide reading,
capture and work-session navigation; use the tools above for other interactions.
Coordinate use before closing a shared work session.

Hiding preserves the selected tab, text scroll, and unsent chat draft in this TUI
session. Entering Browser ends continuous voice mode and discards pending voice
capture, including a transcript awaiting delivery.
