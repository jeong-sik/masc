# Existing-runtime protocol probe

`probe_live.mjs` checks an already running MASC with temporary client sessions.
It does not boot/restart the server, invoke tools, broadcast messages or schedule
Keeper work. Use Node 26 or later (the WebSocket client needs custom Origin
headers). Supply the existing operator token through an environment variable;
never paste credentials into command arguments or evidence files.

```sh
node scripts/harness/transport/probe_live.mjs \
  --base-url http://127.0.0.1:8935 \
  --token-env MCP_TOKEN --output /tmp/masc-transports.json
```

The probe checks HTTP MCP initialize/initialized, ping and tools/list; WS
same-origin upgrade, authenticated dashboard hello and dashboard ping; and a
session-bound observer SSE stream receiving an actual data event or heartbeat.
The SSE result names which was observed. It also sends an HTTP ping while SSE
is open, deletes its own temporary MCP sessions, and checks that all observations
belong to the same runtime instance. JSON and SSE MCP responses are both accepted
as required by the [MCP transport contract](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

An absent credential is reported as a failed check, rather than transport
success. A transport pass proves these observed exchanges only: full-health
warnings, Keeper progress, long-running stream stability, reconnect/replay and
visible Dashboard/TUI behavior require their own evidence. Socket/fetch deadlines
bound this diagnostic, not Keeper runtime execution.
