# Browser Lane

Browser Lane has two sources: `live`, the operator's Firefox/Zen
WebExtension; and `automation`, an isolated stock Firefox session controlled
by MASC's OCaml/Eio WebDriver client. See [native-firefox-lane.md](native-firefox-lane.md)
for the WebDriver endpoint configuration.

The live extension bridges typed tab reads, viewport capture and explicit-tab interaction commands through
native messaging. Its host polls `/browser-lane/poll` and returns results to
`/browser-lane/result`; these transport endpoints require the lane token.
They accept only `live`. Automation requires the configured in-process
WebDriver executor and reports `Lane_absent` when it is not installed.
Session management and navigation are refused on the live lane.

Keeper browser tools use the same source state. They reject backend failures,
malformed envelopes, absent lanes and timeouts instead of reporting success.
These are Keeper tools; their in-process descriptors are separate from public
MCP tool registration.

The operator surface is authenticated independently of the connector:

| Endpoint | Request | Permission |
|---|---|---|
| POST `/api/v1/dashboard/browser-lane/read` | `lane`, optional `tabId` | Read state |
| POST `/api/v1/dashboard/browser-lane/session` | `action`: open/close, optional `headless` | Operator admin token |
| POST `/api/v1/dashboard/browser-lane/goto` | absolute HTTP(S) `url` | Operator admin token |

Read replies contain `tabs`, the selected `page`, `source` and measured
`elapsed_ms`. The page contains `tabId`, `url`, `title`, `text`, `chars` and
`truncated`. Text is capped at 50,000 Unicode code points by the operator
surface. Each explicit read obtains a fresh page observation.

The TUI has one `go Browser Lane` entry (`B` from Connectors). It lists all
open tabs of the selected source; `[` / `]` select a tab and `r` refreshes.
The operator chooses pages by title and URL. Websites have no dedicated lanes
or app filters. Keeper tools use the same general browser capabilities.

See [Browser usage](browser-lane-examples.md) for reading logged-in work pages,
checking rendered application state, and gathering evidence across tabs.

## Browser controls

`BrowserInteract` operates on either `live` or `automation` with a required
`tabId`. Its closed actions are `click` (`selector`), `fill` (`selector`, `text`),
and `scroll` (`x`, `y`, relative CSS pixels). A selector must identify exactly
one visible element in the top document. Missing, ambiguous, disabled and
unsupported input targets return errors. No arbitrary script is accepted.

Use a selector known from page inspection: text reads do not yet provide a
DOM control inventory. Set `expectedUrl` to the URL from `BrowserRead` to refuse
an action if that tab navigated. The result includes `urlBefore`, `url`, and
scroll coordinates; read or capture again to verify what the website did.
Click uses the element's DOM click activation. Fill supports text inputs and
textareas through the native value setter plus input/change events; it never
sends Enter or calls submit. The website's own event handlers may react to
those events. Pointer gestures, cross-frame targets, and file uploads are
outside this tool's contract.

Interactions are ordered writes under the same tool permission policy as
`BrowserGoto`; live interaction uses the operator's logged-in tab. Session
creation, closure, and direct URL navigation remain automation-only.
