---
title: Browser Lane Guide
description: Read the operator's real Firefox (live lane) or a keeper-owned browser (automation lane) from masc — setup, tools, and the TUI reader.
---

A browser lane is one connected browser backend. masc has two:

- **live** — the operator's real Firefox through the browser-lane extension
  and its native-messaging host. It exists only while that Firefox runs with
  the extension loaded. Reads whatever tabs are open, as the operator sees
  them. Read-only by construction: the live lane exposes `tabs.list` and
  `page.read` and refuses navigation verbs.
- **automation** — a keeper-owned Playwright Firefox, separate from the
  operator's profile. Navigation (`page.goto`) and session open/close live
  here.

## Setup (live lane)

The server side ships with masc. Two pieces run on the operator's machine:

1. **Native messaging host** — install the built host into Firefox's
   NativeMessagingHosts directory:

   ```bash
   ./connectors/browser/install-host.sh --base-path <your .masc base>
   ```

2. **Extension** — load `connectors/browser/extension/` via
   `about:debugging` → *Load Temporary Add-on*. A temporary add-on unloads
   when Firefox exits; a persistent install needs a signed build.

With Firefox running, the host long-polls the masc server and the lane
reports `[connected]`.

## Keeper tools

| Tool | Lane | Reads |
| --- | --- | --- |
| `masc_browser_tabs` | live, automation | Open tabs: id, title, url, active |
| `masc_browser_read` | live, automation | One page's visible text (50k cap, `[TRUNCATED]` marker) |

Both are reads. A lane with no recent poll answers "not connected"
immediately — the operator's browser is not always on.

## The TUI reader

Open `:` → `go Browser Lane`, or press `B` from Connectors. The reader
starts on the live lane and lists its open tabs; `[`/`]` steps through tabs
and reads each page. `l`/`a` switches live/automation. In automation, `g`
enters a URL, `o`/`x` opens and closes the session, `Ctrl-O` previews a PNG
of the selected tab. `Ctrl-^` hides the reader; the selected tab, scroll and
unsent chat draft survive the toggle.

Entering Browser ends continuous voice mode and discards any capture in
flight, including a transcript awaiting delivery.

| Key | Action |
| --- | --- |
| `l` / `a` | Live / automation Firefox |
| `[` / `]` | Previous / next tab, reading its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover tabs and refresh the page |
| `Ctrl-O` | PNG preview of the selected tab |
| `g` | Enter a URL (automation); Enter opens, Esc cancels |
| `o` / `x` | Open / close the automation session |
| `Ctrl-^` / Esc / Left | Hide the reader, return to the previous surface |

## Reading with the operator's own session

The live lane is how a keeper reads a page the way the operator sees it —
including pages behind the operator's own login, with no app token, no API
credential, and no write path. If the page is open in Firefox, the lane can
read it; if it is not, it cannot, and nothing is opened on the operator's
behalf.
