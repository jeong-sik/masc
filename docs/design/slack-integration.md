# Slack API connector

`masc_slack_read` reads the API collector buffer, not browser tabs. With
`channel_id` it returns collected messages newest first; without it, a
per-channel summary. This in-memory buffer is neither full history nor an
on-demand thread API.

The optional existing REST collector (`server_slack_poll_lane`) runs independently
of Browser Lane. It uses the configured bot token, bound channels and
`[slack] poll_enabled`; its buffer is not represented as browser observations.
Its durable pagination checkpoints are described in
[slack-poll-checkpoints.md](slack-poll-checkpoints.md). 

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
