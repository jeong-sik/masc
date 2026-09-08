---
title: Browser Lane Guide
description: Connect Firefox or Zen, read and interact with pages, and use the Browser Lane TUI.
---

MASC has two browser sources:

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

## Setup: live

Install a built OCaml native host on the browser's machine. `--binary` here names
**masc-browser-host**, not the Firefox or Zen executable. `--base-path` is the
workspace containing `.masc`, not the `.masc` directory itself.

```bash
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace \
  --server http://127.0.0.1:8935
```

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

Start geckodriver on loopback:

```bash
geckodriver --host 127.0.0.1 --port 4444
```

Set the following in the resolved configuration directory's `runtime.toml`, then
restart MASC:

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
# Optional: select an installed Firefox or Zen executable.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

`webdriver_url` must be a loopback HTTP origin. `binary` must be an absolute path
and requires `webdriver_url`. When omitted, geckodriver discovers the browser;
set it explicitly to select Firefox or Zen. Changing it does not select a live
connection. Automation opens headless by default.

## Keeper and MCP tools

Keeper-facing names use CamelCase; the MCP registration names use `masc_browser_*`.

| Keeper tool | MCP name | Source and behavior |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | Both: list tabs and discover the live connection identity |
| `BrowserRead` | `masc_browser_read` | Both: text, visible elements, or a viewport PNG |
| `BrowserInteract` | `masc_browser_interact` | Both: click, fill, or scroll one explicit tab |
| `BrowserSession` | `masc_browser_session` | Automation: open, close, or check the session |
| `BrowserGoto` | `masc_browser_goto` | Automation: navigate to an HTTP(S) URL |
| `BrowserAct` | `masc_browser_act` | Automation: open/close tabs, click, fill, press, select, scroll, back, forward, or reload |

After discovery, pass the observed `clientId` and `tabId` to live reads and
interactions. A `clientId` is required when several live browsers are connected;
omit it for automation.

`BrowserRead` defaults to `mode="text"`, `format="text"`, and 50,000 Unicode code
points; `maxChars` can rise to 100,000. Inspect `truncated` in the result.
`mode="elements"` returns up to 200 visible controls with labels and observed CSS
selectors. `format="image"` requires an explicit `tabId`; Keeper calls return a
durable artifact handle for image analysis. Text and element reads describe the
current rendered page, not every hidden or virtualized item.

Use observed selectors for `BrowserInteract` click/fill and `BrowserAct` element
actions; a selector must match exactly one element. For `BrowserInteract`, pass
`expectedUrl` from the last read to reject intervening navigation. Fill emits page
events and does not itself press Enter or submit. Read or capture the page after
an action, including an error, before deciding whether to retry.

## TUI reader

Press `Ctrl-^` (Ctrl-Shift-6), use `:` → `go Browser Lane`, or press `B` from
Connectors. The reader starts on live. Use `b` to choose Firefox or Zen, move with
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
