---
title: Browser Lane Guide
description: Connect Firefox or Zen or the Stagehand Chromium, read and interact with pages, and use the Browser Lane TUI.
---

MASC has three browser sources:

- **live** connects the operator's Firefox or Zen through the browser extension
  and OCaml native-messaging host. It uses that browser's existing tabs and login
  session. It supports text, element lists, viewport screenshots, and explicit-tab
  click, fill, and scroll. These interactions can change the page or trigger its
  handlers, including navigation.
- **automation** uses MASC's OCaml WebDriver client and geckodriver to manage a
  separate Gecko browser session. It starts with an isolated profile, without the
  operator's logins. Session open/close and direct URL navigation belong here.
  The server owns this session; coordinate its use before closing a session
  another task is using.
- **stagehand** is a Chromium the server starts with the
  [Stagehand](https://github.com/browserbase/stagehand) v4 extension loaded and
  reaches over the Chrome DevTools Protocol. A Keeper tells it in one sentence
  what to act on, observe or extract, and the Stagehand runtime chooses the
  elements. The model it asks is answered by MASC, through an exact-output
  lane. Like automation, the server owns the session and the browser starts
  with an empty profile unless one is configured.

## Setup: live

Install a built OCaml native host on the browser's machine. `--binary` here names
**masc-browser-host**, not the Firefox or Zen executable. `--base-path` is the
workspace containing `.masc`, not the `.masc` directory itself.

```bash
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace
```

The launcher records no server address: the host reads the port from the
workspace's `.masc/config/connection.toml`. After a failed poll it reads that
file again and moves to the port it names only when the current server no
longer answers and the new port does, so a server restarted on another port is
found without reinstalling.

The installer supports macOS and Linux and registers a Mozilla native-messaging
manifest. `--manifest-dir` selects a different manifest directory when needed.
In Firefox or Zen, open `about:debugging` → **Load Temporary Add-on** and select `connectors/browser/extension/manifest.json`. Temporary loading
ends when that browser exits.

Each running connection reports its browser identity and a `clientId` UUID. One
live connection can be selected automatically; with several, choose the desired
UUID. Tab IDs belong to a connection and can overlap between browsers. A stale
UUID is refused instead of selecting another browser. Reconnecting creates a new
UUID, so discover and select it again.

## Setup: automation

Set the geckodriver executable in the resolved configuration directory's
`runtime.toml`, then restart MASC:

```toml
[browser]
geckodriver = "/absolute/path/to/geckodriver"
# Optional: select an installed Firefox or Zen executable.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

MASC starts that geckodriver on a free loopback port and stops it when the
server stops, so there is no driver to run and no port to choose.
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

All three are absolute paths. MASC loads the extension over the debugging
connection (`Extensions.loadUnpacked`), which was verified with Chrome Canary
156 and Chrome for Testing 154; branded Chrome refuses `--load-extension` from version 137, and whether a
given build accepts the CDP load depends on the build. The debugging port
listens on loopback. The origin flag permits the extension's WebSocket Origin;
it does not exclude local clients that omit that header. Protect the host and
any configured login profile accordingly.

Without `profile`, each session starts from a server-owned profile that is emptied
first; a configured profile is kept. Either way the directory is owner-only.

The Stagehand runtime asks for a model through `llm.generate`. MASC answers it
with the `browser_stagehand_exact` exact-output lane in `runtime.toml`: its
slots are walked in order and a slot whose model takes no system prompt is
skipped. A lane that declares CLI slots is refused. The answer is checked to be one JSON value;
the extension checks its shape against its own schema.

The browser starts when `BrowserSession` opens with `lane="stagehand"` and
stops on close, when the session fails, or when the server stops. A Chromium a
crashed server left is stopped at the next start.

Stagehand has one server-shared session. `BrowserSession` with `action="open"`
can reuse an existing session; `reused: true` does not prove that its connection
is healthy. If a call reports a disconnected session, check `action="status"`
for `ended`. After confirming the session can be closed, call `action="close"`
then `action="open"`, and rediscover its tab IDs with `BrowserTabs`. Repeating
`open` alone can return `reused: true` for the disconnected session. Do not
repeat an act that may already have changed the page.

`status` does not report who opened or is using the session. Close it only when
the operator has confirmed it can be stopped or your task has an explicit
exclusive session; otherwise coordinate a handoff with other users.

## Keeper and MCP tools

Keeper-facing names use CamelCase; the MCP registration names use `masc_browser_*`.

| Keeper tool | MCP name | Source and behavior |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | All three: list tabs and discover the live connection identity |
| `BrowserRead` | `masc_browser_read` | All three: text, visible elements, scene or regions, or a viewport PNG. Frames, dialogs and downloads: automation |
| `BrowserInteract` | `masc_browser_interact` | Live and automation: click, fill, or scroll one explicit tab |
| `BrowserSession` | `masc_browser_session` | Automation or stagehand: open, close, or check the session |
| `BrowserGoto` | `masc_browser_goto` | Automation or stagehand: navigate to an HTTP(S) URL |
| `BrowserAct` | `masc_browser_act` | Automation: open/close tabs, click, fill, press, select, scroll, back, forward, or reload |
| `BrowserInstruct` | `masc_browser_instruct` | Stagehand: act on, observe, or extract from a tab with one sentence |

After discovery, pass the observed `clientId` and `tabId` to live reads and
interactions. A `clientId` is required when several live browsers are connected;
omit it for automation.

`BrowserRead` defaults to `mode="text"`, `format="text"`, and 50,000 Unicode code
points; `maxChars` can rise to 100,000. Inspect `truncated` in the result.
`mode="elements"` returns up to 200 visible controls with labels and observed CSS
selectors. `format="image"` requires an explicit `tabId`; Keeper calls return a
durable artifact handle for image analysis. Text and element reads describe the
current rendered page, not every hidden or virtualized item.

`BrowserInstruct` takes `action` (`act`, `observe` or `extract`), an
`instruction` sentence (required for act and extract), a `tabId` from
`BrowserTabs lane="stagehand"`, and for extract an optional `schema`: JSON
Schema text for the data to return. It returns Stagehand's `data` and
`metadata`. An act can change the page, so verify the result with Stagehand
`observe` or `extract`; a failed act may have acted. `observe` and `extract`
only read.

Use observed selectors for `BrowserInteract` click/fill and `BrowserAct` element
actions; a selector must match exactly one element. For `BrowserInteract`, pass
`expectedUrl` from the last read to reject intervening navigation. Fill emits page
events and does not itself press Enter or submit. Read or capture the page after
an action, including an error, before deciding whether to retry.

## TUI reader

Press `Ctrl-^` (Ctrl-Shift-6), use `:` → `go Browser Lane`, or press `B` from
Connectors. The reader shows the live and automation sources and starts on live. Use `b` to choose Firefox or Zen, move with
`j`/`k`, and confirm with Enter; `r` reloads the chooser and Esc returns. Reads and
screenshots pin the selected connection. A disconnected selection requires an
explicit new choice.

| Key | Action |
| --- | --- |
| `l` / `a` | Live / automation source |
| `b` | Choose a live browser connection |
| `[` / `]` | Previous / next tab and read its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover and refresh |
| `Ctrl-O` | Preview the selected tab's PNG; any key returns |
| `g` | Enter an automation URL; Enter navigates, Esc cancels |
| `o` / `x` | Open / close the automation session |
| `Ctrl-^` / Esc / Left | Hide the reader and return |

For an automation page, use `a`, then `o`, then `g` and a URL. PNG previews require
terminal image support; otherwise the reader explains the limitation. The preview
is not sent to a Keeper. TUI keys provide reading, capture, and automation session
navigation; element interaction is available through the tools above.

Hiding preserves the selected tab, text scroll, and unsent chat draft in this TUI
session. Entering Browser ends continuous voice mode and discards pending voice
capture, including a transcript awaiting delivery.
