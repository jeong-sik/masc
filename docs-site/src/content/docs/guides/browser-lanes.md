---
title: Browser Lane Guide
description: Connect the owned Firefox or ego lite as a browser Addon, select validation hooks, and use the Browser Lane TUI.
---

Each browser source is its own Lane Addon package with its own worker:
`browser-firefox` and `browser-ego`. A worker runs only its source, so a failure
of one source ends only that worker. Select the input/output validation hooks
per installation. Browser names and connection transports describe
capabilities; they are not separate installation systems.

- **live** has two sources. `browser-firefox` starts a dedicated Firefox with
  its own BiDi peer and profile. `browser-ego` serves an ego lite task space
  with the cookies of your ego lite profile. Native hover and drag require a
  connection that serves them.

For an unbound request, automatic selection considers the available browsers
and required actions. Keep the returned browser identity for tab/document work;
a bound tab or explicit connection does not fall back to a different browser.
Check the reported capability inventory rather than assuming every transport
supports every action. Safari is not a backend in this package.

## Install the browser Addons

`scripts/install-local-build.sh` installs `masc-browser-addon-worker`,
`masc-native-addon-launcher` and `masc-browser-process-owner` beside masc, then
runs `masc browser-lane-setup --mode addon` for the workspace. The `bidi` and
`ego` modes do the same step for the sources the workspace runs: firefox and
ego when `runtime.toml` has their table or the run writes it. For each, it
writes the package masc carries to
`<base-path>/.masc/packages/browser-<source>/` and, when the workspace has no
declaration of that source, saves `lane-addons/browser-<source>.toml` in the
active config root. An existing declaration is left as it is. Keep the install
prefix on the server's PATH. `--no-browser-addon` (installer) and `--no-addon`
(setup) leave the Addons out; without them no browser route works.

To choose hooks, add them to the declaration setup wrote; setup never rewrites
an existing declaration:

```toml
id = "browser-ego"
enabled = true
run_id = "browser-ego"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser-ego/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

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

Omitting the array uses the package default. These are named middleware;
arbitrary executable hooks are not loaded. With the array empty, caller
authorization, worker incarnation, wire decoding, document/viewport binding,
artifact ownership, and cleanup checks still apply. A browser package declares
no model outputs, so a browser worker holds no model configuration.

Backend settings below are loaded from the resolved `runtime.toml` at server
startup and captured when an installation attaches. They say how a source
starts, never whether it runs: a source whose table is missing does not start,
and its package row says so. Restart after changing those settings, and
detach/reattach an existing installation to capture them. Installation
declaration edits are reconciled at startup and on the existing maintenance
pulse. Saving TOML is not an attachment receipt: inspect `desired_revision`,
`applied_revision`, `phase`, and configuration issues. Dashboard Refresh reads
that state rather than forcing reconciliation.

To stop a source, set the top-level `enabled = false` in its declaration, from
the TUI's package row or the TOML file, and verify detachment and cleanup. Only
that source's worker stops. Removing a declaration takes effect after a
complete config scan. The worker fences input before joining its original owned
resources; unconfirmed cleanup remains a failure. A replacement has a fresh
incarnation and connection IDs. Persistent profile contents are preserved.

## Setup: the owned Firefox

`--base-path` is the workspace containing `.masc`, not the `.masc` directory
itself.

```bash
masc browser-lane-setup --mode bidi --base-path /path/to/workspace
```

This prepares `[browser.live.bidi]` and the dedicated profile. Explicit
`--firefox`, `--profile`, and `--port` replace their keys; omitted keys retain
their values. Follow the [Firefox BiDi guide](../browser-bidi/) to attach and
verify the managed connection.

## Setup: ego lite

```bash
masc browser-lane-setup --mode ego --base-path /path/to/workspace
```

This finds `ego-browser`, checks that it answers, and writes `[browser.live.ego]`
with the task space name (`--ego-space`, `masc-keepers` by default). Restart the
server afterwards. Keepers act only on the pages that space opens, with the
cookies of your ego lite profile.

Each running connection reports its browser identity and a `clientId` UUID. One
live connection can be selected automatically; with several, choose the desired
UUID. Tab IDs belong to a connection and can overlap between browsers. A stale
UUID is refused instead of selecting another browser. Reconnecting creates a new
UUID, so discover and select it again.

## Keeper and MCP tools

Keeper-facing names use CamelCase; the MCP registration names use `masc_browser_*`.

| Keeper tool | MCP name | Source and behavior |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | List tabs and discover the live connection identity |
| `BrowserRead` | `masc_browser_read` | Text, visible elements, scene or regions, or a viewport PNG. Document source (`mode = "html"`, explicit tab, `html: null` when the reply would pass 1 MiB). Frames and dialogs on BiDi; snapshots and downloads on ego |
| `BrowserInteract` | `masc_browser_interact` | Click, fill, scroll and other input in one explicit tab; native hover/drag/keyboard depend on transport capabilities |
| `BrowserSession` | `masc_browser_session` | Bind an observed ego Space to a Goal, or read that binding |
| `BrowserGoto` | `masc_browser_goto` | Navigate a tab the connection opened to an HTTP(S) URL |
| `BrowserAct` | `masc_browser_act` | Tab, window, history, dialog and upload actions; ego Space handoff |

After discovery, pass the observed `clientId` and `tabId` to live reads and
interactions. A `clientId` is required when several live browsers are connected.

`BrowserRead` defaults to `mode="text"`, `format="text"`, and 50,000 Unicode code
points; `maxChars` can rise to 100,000. Inspect `truncated` in the result.
`mode="elements"` returns visible controls with labels and observed CSS
selectors, subject to response bounds; inspect truncation and scope when needed.
`format="image"` requires an explicit `tabId`; Keeper calls return a
durable artifact handle for image analysis. Text and element reads describe the
current rendered page, not every hidden or virtualized item.

Use observed selectors for `BrowserInteract` page input such as click/fill;
a selector must match exactly one element. For `BrowserInteract`, pass
`expectedUrl` from the last read to reject intervening navigation. Fill emits page
events and does not itself press Enter or submit. Read or capture the page after
an action, including an error, before deciding whether to retry.
On BiDi and ego, guarded semantic clicks use native pointer input. Fill and
native typing are distinct actions. Check transport capabilities and read the
page after input to verify the application effect.

## TUI reader

Press `Ctrl-^` (Ctrl-Shift-6), use `:` → `go Browser Lane`, or press `B` from
Connectors. The reader starts with **Automatic** selection. Press `b` to choose
Automatic or an observed connection. Move with `j`/`k`, confirm with Enter,
refresh the chooser with `r`, and return with Esc. Reads and captures keep the
selected connection; a disconnected selection requires an explicit new choice.

| Key | Action |
| --- | --- |
| `b` | Choose Automatic or a connected browser by its actual identity |
| `A` | Show transport limits in the browser picker |
| `[` / `]` | Previous / next tab and read its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover and refresh |
| `Ctrl-O` | Preview the selected tab's PNG; Esc or q returns |
| `Ctrl-^` / Esc / Left | Hide the reader and return |

PNG previews require terminal image support; otherwise the reader explains the
limitation. A preview is not sent to a Keeper. TUI keys provide reading and
capture; use the tools above for other interactions. The
[TUI browser guide](https://github.com/jeong-sik/masc/blob/main/docs/guides/tui-browser-lanes.md)
lists every key.

Hiding preserves the selected tab, text scroll, and unsent chat draft in this TUI
session. Entering Browser ends continuous voice mode and discards pending voice
capture, including a transcript awaiting delivery.
