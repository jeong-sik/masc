# Browser and Slack lanes in the TUI

Open the command palette with `:` and select `go Browser Lane` or `go Slack Lane`.
The views live inside Connectors. From the Connectors list, `B` and `S` open them.
Both start with the live Firefox source. Slack asks the server to filter matching
Slack tabs; it does not send Slack messages or change channel bindings.

| Key | Action |
| --- | --- |
| `B` / `S` | Browser / Slack, starting with live Firefox |
| `l` / `a` | Live / automation Firefox |
| `[` / `]` | Previous / next matching tab and read its page |
| `j` / `k`, arrows | Scroll page text |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Refresh tabs and page |
| `g` | Enter a URL in automation Firefox; Enter opens it, Esc cancels |
| `o` / `x` | Open / close the automation Firefox session while automation is selected |
| Esc / Left | Return to connector routing |

The title identifies the source. Successful reads show server latency, matching
tab count, selected tab, page URL, character count and truncation. A failed or
pending refresh labels retained content as a previous read. Source switches clear
that content; generation-stamped replies prevent an earlier request from
populating a later app or source. Reads happen on entry, tab selection and explicit
refresh, so a periodic TUI tick does not continually select Firefox tabs.

The URL editor accepts bracketed paste, Unicode backspace and Ctrl-U. Its typed
and pasted characters belong to the URL field, so letters cannot activate lane
commands or enter the Keeper composer. Navigation uses the automation session;
server URL validation errors remain visible on the lane view.

Requests use the existing authenticated TUI HTTP client. The read deadline is
45 seconds for the server's tab-list and page-read phases; automation session
startup allows 65 seconds. Both run in switch-owned Eio daemon fibers and deliver
results through the TUI mailbox. Cancellation is propagated to the switch.
See the [Eio fiber reference](https://ocaml.org/p/eio/1.0/doc/eio/Eio/Fiber/index.html).

## Verification boundary

`test/test_tui_browser_lane.ml` exercises tab selection, strict schema decoding,
late responses, source identity, failed-refresh retention and empty Slack tabs.
For this change its seven scenarios were executed using the OCaml interpreter
with the production pure module extracted verbatim. All changed OCaml files
passed parser checks. These checks do not establish full executable typechecking,
CI success, Firefox connectivity, or a rendered live TUI; deployment and live
capture must be measured separately.
