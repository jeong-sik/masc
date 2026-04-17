# Sidecar Lifecycle API — RFC

Status: **Draft** — design baseline for the next implementation PR.
Scope: backend HTTP endpoints + dashboard wiring so the operator can
start/stop/inspect a sidecar from the connectors surface instead of
copy-pasting `./run.sh` snippets into a terminal.

Related work shipped in this Phase 7 sweep:
- `feature/sidecar-run-sh` — every bridge now ships `./run.sh
  [start|stop|tail|status]`. The RFC depends on this wrapper as the
  shell-out target.
- `feature/dash-connectors-toplevel` — UI surface and copyable command
  cards already in place; this RFC turns those copy buttons into native
  POSTs.

## Endpoints

```
POST  /api/v1/sidecar/:id/start    →  202 Accepted, fire-and-forget
POST  /api/v1/sidecar/:id/stop     →  200 OK, sync (run.sh stop is fast)
GET   /api/v1/sidecar/:id/status   →  200 OK, returns status.json
GET   /api/v1/sidecar/:id/logs     →  200 OK, last N lines (?lines=N, default 200)
```

`:id` ∈ `{discord, imessage, slack, telegram}`. Anything else returns
`400 Bad Request {"ok":false,"error":"unknown sidecar id"}`.

Auth model (mirroring `Server_routes_http_routes_channel_gate`):

| Verb       | Helper                               | Why                          |
|------------|--------------------------------------|------------------------------|
| GET status | `with_public_read`                   | read-only, dashboard polls   |
| GET logs   | `with_tool_auth ~tool_name:"sidecar"`| log content can be sensitive |
| POST start | `with_tool_auth ~tool_name:"sidecar"`| spawns a process             |
| POST stop  | `with_tool_auth ~tool_name:"sidecar"`| signals processes            |

## Response shapes

**start** (202):
```json
{ "ok": true, "log_path": ".../discord-sidecar-20260418.log",
  "status_path": ".../status.json" }
```

**stop** (200):
```json
{ "ok": true, "signaled": true }
{ "ok": true, "signaled": false, "note": "discord-bot not running." }
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

## Implementation skeleton (OCaml, lib/server/)

New module `lib/server/server_routes_http_routes_sidecar.ml`:

```ocaml
open Server_auth
open Server_utils
module Http = Http_server_eio

let known_ids = ["discord"; "imessage"; "slack"; "telegram"]

let parse_id_from_path req =
  (* expect path /api/v1/sidecar/<id>/<action> *)
  ...

let script_path id =
  let base = Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:"." in
  Filename.concat base (Printf.sprintf "sidecars/%s-bot/run.sh" id)

let respond_json ~status reqd json = ...

let handle_status state request reqd =
  let id = parse_id_from_path request in
  if not (List.mem id known_ids) then
    respond_json ~status:`Bad_request reqd
      (`Assoc [("ok", `Bool false); ("error", `String "unknown sidecar id")])
  else
    let status_file = ... (* MASC_BASE_PATH/.gate/runtime/<id>/status.json *) in
    if Sys.file_exists status_file then
      let body = In_channel.with_open_text status_file In_channel.input_all in
      let parsed = try Some (Yojson.Safe.from_string body) with _ -> None in
      respond_json ~status:`OK reqd
        (`Assoc [("ok", `Bool true); ("available", `Bool true);
                 ("status", Option.value parsed ~default:`Null)])
    else
      respond_json ~status:`OK reqd
        (`Assoc [("ok", `Bool true); ("available", `Bool false)])

let handle_stop state request reqd =
  let id = parse_id_from_path request in
  ... whitelist check ...
  let (status, stdout) = Process_eio.run_argv_with_status
    ~timeout_sec:5.0
    [script_path id; "stop"]
  in
  let signaled = String.(equal (trim stdout |> trim_newlines)
                          (Printf.sprintf "Sent SIGTERM to %s-bot processes." id)) in
  respond_json ~status:`OK reqd
    (`Assoc [("ok", `Bool true); ("signaled", `Bool signaled);
             ("note", `String stdout)])

let handle_start state request reqd =
  let id = parse_id_from_path request in
  ... whitelist check ...
  (* Detach: run via setsid + nohup so the sidecar survives backend restart.
     The wrapper already tees to a dated log file, so we just fork+exit. *)
  let cmd = Printf.sprintf
    "setsid nohup %s start </dev/null >/dev/null 2>&1 &"
    (Filename.quote (script_path id))
  in
  let _ = Sys.command cmd in
  respond_json ~status:`Accepted reqd
    (`Assoc [("ok", `Bool true);
             ("log_path", `String (log_path_for id));
             ("status_path", `String (status_path_for id))])

let add_routes ~sw:_ ~clock:_ router =
  router
  |> Http.Router.get "/api/v1/sidecar/:id/status" (fun req reqd ->
       with_public_read (fun s _r r -> handle_status s req r) req reqd)
  |> Http.Router.get "/api/v1/sidecar/:id/logs" (fun req reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun s _r r -> handle_logs s req r) req reqd)
  |> Http.Router.post "/api/v1/sidecar/:id/start" (fun req reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun s _r r -> handle_start s req r) req reqd)
  |> Http.Router.post "/api/v1/sidecar/:id/stop" (fun req reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun s _r r -> handle_stop s req r) req reqd)
```

Wire it in `lib/server/server_routes_http.ml`:

```ocaml
|> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
|> Server_routes_http_routes_sidecar.add_routes ~sw ~clock
```

## Security checklist

1. **Path injection**: `:id` whitelisted against `known_ids` before
   any filesystem path is built. No string interpolation into a shell.
2. **Shell injection**: stop/status use `Process_eio.run_argv_with_status`
   (argv-based, no shell). start uses `Sys.command` only because `setsid
   nohup … &` requires a shell, and the only interpolated value is
   `Filename.quote (script_path id)` where `script_path` derives from the
   already-whitelisted `id`.
3. **Auth scope**: spawn/signal verbs require `with_tool_auth` (Bearer
   token); read-only status is `with_public_read` to keep the dashboard
   fetch loop simple. Logs go through `with_tool_auth` because a tail
   may include user message bodies.
4. **Timeout**: `~timeout_sec:5.0` on stop+status — the wrapper itself
   exits quickly. start is fire-and-forget, no timeout needed.
5. **Resource clamp**: `?lines=N` capped server-side at 1000 to bound
   memory.

## Production note

`Sys.command "setsid nohup … &"` makes the sidecar survive the backend
process, but it's still spawned by an interactive operator. For real
production deployments this RFC recommends launchd plists (macOS) or
systemd units (Linux) — backend can register/unregister those instead
of forking. That's out of scope for the v1 endpoint; v1 targets dev
boxes and lab environments.

## Open follow-ups (post-v1)

- `/api/v1/sidecar/:id/restart` (stop + wait + start). Could be
  client-side (sequential calls).
- `/api/v1/sidecar/:id/config` POST — TOML writer for the
  `${MASC_BASE_PATH}/.gate/runtime/<id>/config.toml` file the wrapper
  already loads. Mode 0600.
- `/api/v1/sidecar/:id/schema` GET — proxy to each sidecar's Pydantic
  `BotConfig.model_json_schema()` so the dashboard form is generated
  once, never drifts.

## Test plan (next PR)

- Unit: pure helpers (`parse_id_from_path`, `script_path`, whitelist).
- Integration: HTTP round-trip with a fake sidecar `run.sh` echoing
  expected lines. Asserts status=200/202/400, response shape, and
  that an unknown id never reaches `Sys.command`.
- Negative: shell-meta in `:id` (e.g. `;ls`) returns 400 without
  invoking any subprocess. Tested by stubbing `Sys.command` and
  asserting it's never called for non-whitelisted ids.
