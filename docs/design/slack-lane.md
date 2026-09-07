# Slack Lane

Slack is a read-only WebApp view over Browser Lane. The operator opens a
logged-in Slack tab in Firefox with the MASC extension, then selects Slack
in the TUI. The same authenticated Browser Lane endpoint filters tabs by
parsed HTTPS Slack URL (`/client/...` or `/archives/...`) and reads the selected
tab's visible text. It does not extract cookies or reuse session tokens.

`POST /api/v1/dashboard/browser-lane/read` accepts:

```json
{"lane":"live","app":"slack","tabId":12}
```

`tabId` is optional: an active matching tab wins, then the first matching tab.
A missing Slack tab returns an empty list and `page:null`; a disconnected
browser or failed read returns an error. A selected tab that closes or leaves
Slack is refused rather than replaced by another tab. The snapshot includes
source, URL, title, character count, truncation and measured request latency.

The view is the text currently rendered in Firefox. Slack virtualizes history:
this is not an exhaustive archive, unread count or thread API. No message is
sent. More WebApps can add an explicit app variant and URI classifier to the
same Browser surface without creating another browser transport.

The optional existing REST collector (`server_slack_poll_lane`) is independent
of this browser view. It uses the configured bot token, bound channels and
`[slack] poll_enabled`; its buffer is not represented as browser observations.
Its pagination-loss finding remains separate from the Browser integration.

Native automation uses stock Firefox through OCaml WebDriver; see
[native-firefox-lane.md](native-firefox-lane.md). It has an isolated profile,
so Slack authentication in the operator's browser belongs to the `live` lane.
