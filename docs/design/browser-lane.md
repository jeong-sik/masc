# Browser Lane

Browser Lane has two sources: `live`, the operator's read-only Firefox
WebExtension; and `automation`, an isolated stock Firefox session controlled
by MASC's OCaml/Eio WebDriver client. See [native-firefox-lane.md](native-firefox-lane.md)
for the WebDriver endpoint configuration.

The live extension bridges typed `tabs.list` and `page.read` commands through
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
| POST `/api/v1/dashboard/browser-lane/read` | `lane`, `app`, optional `tabId` | Read state |
| POST `/api/v1/dashboard/browser-lane/session` | `action`: open/close, optional `headless` | Operator admin token |
| POST `/api/v1/dashboard/browser-lane/goto` | absolute HTTP(S) `url` | Operator admin token |

Read replies contain `tabs`, the selected `page`, `source`, `app` and measured
`elapsed_ms`. The page contains `tabId`, `url`, `title`, `text`, `chars` and
`truncated`. Text is capped at 50,000 Unicode code points by the operator
surface. Each explicit read obtains a fresh page observation.

[Slack Lane](slack-lane.md) uses this Browser surface and selects Slack tabs by
parsed URL. Other WebApps can add an explicit adapter without another host
process or a second source of browser session ownership.
