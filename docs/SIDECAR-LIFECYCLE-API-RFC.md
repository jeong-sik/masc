# Sidecar Lifecycle API — RFC

Status: **Implemented** (`lib/server/server_routes_http_routes_sidecar.ml`).
Scope: backend HTTP endpoints + dashboard wiring so the operator can
start/stop/inspect/configure a sidecar from the connectors surface instead of
copy-pasting `./run.sh` snippets into a terminal.

Related work:
- `feature/sidecar-run-sh` — every bridge ships `./run.sh
  [start|stop|tail|status]`.
- `feature/dash-connectors-toplevel` — UI surface and native lifecycle controls.

## Endpoints

```
POST  /api/v1/sidecar/start?name=<id>    →  202 Accepted, fire-and-forget
POST  /api/v1/sidecar/stop?name=<id>     →  200 OK, sync (run.sh stop is fast)
GET   /api/v1/sidecar/status?name=<id>   →  200 OK, returns status.json + diagnostics
GET   /api/v1/sidecar/logs?name=<id>     →  200 OK, last N lines (?lines=N, default 200)
GET   /api/v1/sidecar/schema?name=<id>   →  200 OK, JSON Schema for sidecar config
GET   /api/v1/sidecar/config?name=<id>   →  200 OK, current sidecar config values
POST  /api/v1/sidecar/config?name=<id>   →  200 OK, atomically writes config.toml (0600)
```

`?name=<id>` ∈ `{telegram}` for external sidecar lifecycle control (`known_ids = ["telegram"]`). Discord (`Server_discord_in_process_gateway`), Slack
(`Server_slack_in_process_gateway`) and iMessage
(`Server_imessage_in_process_gateway`) run in-process and are not external sidecar process ids;
`?name=imessage` returns 404 (#30531). Unknown ids return
`400 Bad Request {"ok":false,"error":"unknown sidecar id"}`.

Auth model (mirroring `Server_routes_http_routes_channel_gate`):

| Verb       | Helper                               | Why                          |
|------------|--------------------------------------|------------------------------|
| GET status | `with_public_read`                   | read-only, dashboard polls   |
| GET schema | `with_public_read`                   | read-only schema descriptor  |
| GET logs   | `with_tool_auth ~tool_name:"sidecar"`| log content can be sensitive |
| GET config | `with_tool_auth ~tool_name:"sidecar"`| config values                |
| POST config| `with_tool_auth ~tool_name:"sidecar"`| writes sidecar config.toml   |
| POST start | `with_tool_auth ~tool_name:"sidecar"`| spawns a process             |
| POST stop  | `with_tool_auth ~tool_name:"sidecar"`| signals processes            |

## Response shapes

**start** (202):
```json
{ "ok": true, "log_path": ".../telegram-sidecar-20260418.log",
  "status_path": ".../status.json" }
```

**stop** (200):
```json
{ "ok": true, "signaled": true }
{ "ok": true, "signaled": false, "note": "telegram-bot not running." }
```

**status** (200):
```json
{ "ok": true, "available": true,
  "status": { /* contents of .gate/runtime/<id>/status.json */ } }
{ "ok": true, "available": false }
```

**logs** (200):
```json
{ "ok": true, "log_path": "...", "lines": [ "2026-... starting...", ... ] }
```

## Implementation (`lib/server/server_routes_http_routes_sidecar.ml`)

Routes are registered on `Http.Router` using `?name=<id>` query parameters:

```ocaml
let add_routes ~sw ~clock router =
  router
  |> Http.Router.get "/api/v1/sidecar/status" ...
  |> Http.Router.get "/api/v1/sidecar/logs" ...
  |> Http.Router.get "/api/v1/sidecar/schema" ...
  |> Http.Router.post "/api/v1/sidecar/start" ...
  |> Http.Router.post "/api/v1/sidecar/stop" ...
  |> Http.Router.get "/api/v1/sidecar/config" ...
  |> Http.Router.post "/api/v1/sidecar/config" ...
```

Wired in `lib/server/server_routes_http.ml`:

```ocaml
|> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
|> Server_routes_http_routes_sidecar.add_routes ~sw ~clock
```

## Security checklist

1. **Path injection**: `id` is validated against `known_ids` before
   any filesystem path is built. No string interpolation into a shell.
2. **Shell injection**: stop/status use `Process_eio.run_argv_with_status`
   (argv-based, no shell). start uses `Sys.command` only because `setsid
   nohup … &` requires a shell, and the only interpolated value is
   `Filename.quote (script_path id)` where `script_path` derives from the
   already-whitelisted `id`.
3. **Auth scope**: spawn/signal/config verbs require `with_tool_auth` (Bearer
   token); read-only status/schema use `with_public_read` to keep the dashboard
   fetch loop simple. Logs go through `with_tool_auth` because a tail
   may include user message bodies.
4. **Timeout**: `~timeout_sec:5.0` on stop+status — the wrapper itself
   exits quickly. start is fire-and-forget, no timeout needed.
5. **Resource clamp**: `?lines=N` capped server-side at 1000 to bound
   memory.

## Production note

`Sys.command "setsid nohup … &"` makes the sidecar survive the backend
process, but it's still spawned by an interactive operator. For
production deployments, launchd plists (macOS) or systemd units (Linux)
remain appropriate when process supervision outside the dev server is desired.

## Test plan (next PR)

- Unit: pure helpers (`parse_id_from_path`, `script_path`, whitelist).
- Integration: HTTP round-trip with a fake sidecar `run.sh` echoing
  expected lines. Asserts status=200/202/400, response shape, and
  that an unknown id never reaches `Sys.command`.
- Negative: shell-meta in `:id` (e.g. `;ls`) returns 400 without
  invoking any subprocess. Tested by stubbing `Sys.command` and
  asserting it's never called for non-whitelisted ids.
