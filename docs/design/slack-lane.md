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
Its durable pagination checkpoints are described in
[slack-poll-checkpoints.md](slack-poll-checkpoints.md). That collection path
remains independent of the Browser integration.

To use only Firefox reads, set this in the resolved configuration directory's
`runtime.toml`, then restart MASC:

```toml
[slack]
enabled = false
```

This master switch disables the API connector: Socket Mode, outbound bot REST
calls, and the bound-channel collector even if `poll_enabled = true`. Inherited
`SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN` cannot override it. The connector status
explains that it is disabled. Credentials are not deleted. Firefox Browser Lane
and the separate OAuth identity configuration do not consult this setting.

Missing `enabled` preserves the existing enabled behavior; `true` enables it.
Non-boolean values, malformed TOML, or an unreadable existing configuration file
disable the API connector with a configuration error. Changes apply at startup;
this is not a hot disconnect switch. Other runtime configuration validators can
still reject the entire startup for malformed `runtime.toml`; this policy does
not make an invalid server configuration bootable.

Native automation uses stock Firefox through OCaml WebDriver; see
[native-firefox-lane.md](native-firefox-lane.md). It has an isolated profile,
so Slack authentication in the operator's browser belongs to the `live` lane.
