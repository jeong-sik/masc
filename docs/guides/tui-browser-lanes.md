# Browser Lane in the TUI

Open `:` → `go Browser Lane`, or press `B` from Connectors. Browser starts with
live Firefox and lists its open tabs. Select any page by title and URL; websites
have no dedicated views or filters. The reader occupies the full content width
and shows the source in its context row. Keeper panels and the composer return
when leaving the reader.

Press `Ctrl-^` (Ctrl-Shift-6) to show or hide Browser. Hiding returns to the
previous surface and restores its search and composer focus. The selected tab,
scroll and unsent chat draft survive the toggle within this TUI session.

Entering Browser ends continuous voice mode and discards any capture in flight,
including a transcript awaiting delivery. An existing Keeper draft is preserved.

| Key | Action |
| --- | --- |
| `l` / `a` | Live / automation Firefox |
| `[` / `]` | Previous / next tab and read its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover tabs and refresh the page |
| `Ctrl-O` | Preview a PNG screenshot of the selected tab; any key returns |
| `g` | Enter a URL in automation; Enter opens it, Esc cancels |
| `o` / `x` | Open / close the automation session |
| Ctrl-^ / Esc / Left | Hide the reader and return to the previous surface |

Browser belongs to Config. Its title shows the source and latest HTTP request
status. Coordinator connectivity and workspace warnings are labeled separately.
Reads show latency, tab count, selected title, URL, character count and truncation.
A failed or pending refresh retains content labeled as a previous read. Switching
source clears that content; generation-stamped replies reject earlier requests.
Reads happen on entry, source or tab selection, navigation, and explicit refresh.

The URL editor accepts bracketed paste, Unicode backspace and Ctrl-U. Typing
belongs to the editor and cannot trigger Browser commands or the Keeper composer.
Navigation controls only the isolated automation session; live Firefox is read-only.

Requests use the authenticated TUI HTTP client. Reading allows 45 seconds for
the tab-list and page-read phases; automation startup and navigation allow 65.
Requests run in switch-owned Eio daemon fibers and return through the TUI mailbox.

`Ctrl-O` captures the explicitly selected tab through the authenticated screenshot
endpoint. The preview keeps the source, tab, text position, and URL draft; any new
input cancels a pending preview. A closed tab produces a visible failure rather
than capturing a different active tab. Use `r` to rediscover available tabs.
The image is not staged or sent to a Keeper. PNG preview uses the terminal's
existing image support; unsupported terminals receive an explanation in Browser.

See [setup and Keeper usage](../design/browser-lane-examples.md).

## Verification

`test/test_browser_surface.ml` covers page selection, empty browsers and failures.
`test/test_tui_browser_lane.ml` covers decoding, source changes, stale replies and
retained evidence. Related TUI tests cover URL input and multiline text projection.
`scripts/capture-browser-proof.py` captures a public page and automation session
recovery on a scratch runtime. Use a binary built from the changed source;
historical captures are not evidence of the current UI.

### Native browser selection

Live Browser Lane discovers the server's active native connections on entry and
`r`. A single fresh connection is selected automatically. With several connections,
choose Firefox or Zen using `b`, `j/k`, and Enter. The chooser displays the backend's
browser identity and each connection UUID; the reader header names the selected
browser. `r` inside the chooser reloads connections, and Esc returns to the reader.

Each live read and Ctrl-O screenshot pins that connection UUID. Switching browsers
clears the previous tab, text, and scroll before reading the new browser. A missing
selected connection opens the chooser without silently rebinding to another browser,
even when only one remains or both browsers use the same tab number. Select a
connection explicitly to recover. Automation retains its separate Firefox session.

Validation: the production pure Browser state module was interpreted against 14
fixtures, including equal tab IDs across clients, stale discovery, disconnected pins,
and screenshot ownership. PTY scenarios cover two-client choice and explicit recovery;
they run in the existing browser-screenshot CI test alias. No local Dune build was run.
