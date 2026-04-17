(** HTTP routes for sidecar lifecycle.

    Provides [/api/v1/sidecar/{start,stop,status}] endpoints that shell
    out to [sidecars/<id>-bot/run.sh]. The wrapper is the single source
    of truth for how a sidecar is started, signalled, and inspected —
    this module only thin-wraps it for HTTP consumers (i.e. the
    dashboard's connectors surface).

    Design baseline: docs/SIDECAR-LIFECYCLE-API-RFC.md.

    Uses query-string [?name=<id>] (matching the existing channel_gate
    routes such as [/api/v1/gate/connector/bind?name=<connector>])
    rather than path params, so we don't introduce a second routing
    convention.

    @since v0.10.0 *)

open Server_auth

module Http = Http_server_eio

(** Whitelist of sidecars the backend will spawn or signal. Anything else
    short-circuits at the request boundary so [Sys.command] is never reached
    for an attacker-controlled id. *)
let known_ids = [ "discord"; "imessage"; "slack"; "telegram" ]

(** Pure whitelist check; exposed so unit tests can confirm shell-meta and
    path traversal in [name=] are rejected before any [Sys.command] /
    [Process_eio] is reached. *)
let validate_name = function
  | None -> Error "missing 'name' query parameter"
  | Some n when List.mem n known_ids -> Ok n
  | Some n -> Error (Printf.sprintf "unknown sidecar id: %s" n)

let parse_name request =
  validate_name (Server_utils.query_param request "name")

let base_path () =
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some p when String.length (String.trim p) > 0 -> String.trim p
  | _ -> Sys.getcwd ()

let script_path id =
  Filename.concat (base_path ()) (Printf.sprintf "sidecars/%s-bot/run.sh" id)

let sidecar_dir id =
  Filename.concat (base_path ()) (Printf.sprintf "sidecars/%s-bot" id)

let status_file id =
  Filename.concat (base_path ()) (Printf.sprintf ".gate/runtime/%s/status.json" id)

let today_yyyymmdd () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d%02d%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

(** Today's log file path. Wrapper writes to this exact filename:
    [LOG_DIR/<id>-sidecar-YYYYMMDD.log] (see sidecars/<id>-bot/run.sh).
    If the operator started the sidecar yesterday and never rolled the
    process, today's file may not exist yet — handled by the caller. *)
let today_log_file id =
  Filename.concat (base_path ())
    (Printf.sprintf ".masc/logs/%s-sidecar-%s.log" id (today_yyyymmdd ()))

(** Clamp the [?lines=N] query param to [1, 1000]. Pure so unit tests
    can pin the upper bound without a request mock. *)
let clamp_lines = function
  | None -> 200
  | Some n -> max 1 (min 1000 n)

let respond_json request reqd ~status body =
  respond_json_with_cors ~status request reqd (Yojson.Safe.to_string body)

let bad_request request reqd msg =
  respond_json request reqd ~status:`Bad_request
    (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])

let read_status_json id =
  let path = status_file id in
  if Sys.file_exists path then
    let body = In_channel.with_open_text path In_channel.input_all in
    let parsed = try Some (Yojson.Safe.from_string body) with _ -> None in
    `Assoc [
      ("ok", `Bool true);
      ("available", `Bool true);
      ("status", Option.value parsed ~default:`Null);
    ]
  else
    `Assoc [
      ("ok", `Bool true);
      ("available", `Bool false);
    ]

let handle_status _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id -> respond_json request reqd ~status:`OK (read_status_json id)

let handle_stop _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let (_status, stdout) =
        Process_eio.run_argv_with_status ~timeout_sec:5.0
          [ script_path id; "stop" ]
      in
      let trimmed = String.trim stdout in
      let signaled_marker =
        Printf.sprintf "Sent SIGTERM to %s-bot processes." id
      in
      let signaled =
        let needle_len = String.length signaled_marker in
        let rec contains i =
          if i + needle_len > String.length trimmed then false
          else if String.equal (String.sub trimmed i needle_len) signaled_marker then true
          else contains (i + 1)
        in
        contains 0
      in
      respond_json request reqd ~status:`OK
        (`Assoc [
           ("ok", `Bool true);
           ("signaled", `Bool signaled);
           ("note", `String trimmed);
         ])

let handle_logs _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let lines =
        clamp_lines (Server_utils.query_param request "lines"
                     |> Option.map int_of_string_opt
                     |> Option.join)
      in
      let path = today_log_file id in
      if not (Sys.file_exists path) then
        respond_json request reqd ~status:`OK
          (`Assoc [
             ("ok", `Bool true);
             ("log_path", `String path);
             ("available", `Bool false);
             ("lines", `List []);
           ])
      else
        let (_status, stdout) =
          Process_eio.run_argv_with_status ~timeout_sec:5.0
            [ "tail"; "-n"; string_of_int lines; path ]
        in
        let line_list =
          String.split_on_char '\n' stdout
          |> List.filter (fun l -> not (String.equal l ""))
          |> List.map (fun l -> `String l)
        in
        respond_json request reqd ~status:`OK
          (`Assoc [
             ("ok", `Bool true);
             ("log_path", `String path);
             ("available", `Bool true);
             ("lines", `List line_list);
           ])

(** Per-process schema cache. The Pydantic [BotConfig.model_json_schema]
    output only changes when sidecar source changes, which requires a
    backend restart in practice (we don't hot-reload Python). So a
    per-id cache keyed by id is safe for the lifetime of this process. *)
let schema_cache : (string, string) Hashtbl.t = Hashtbl.create 8

(** Reset the cache; only used by tests. *)
let reset_schema_cache () = Hashtbl.reset schema_cache

(** Pick a Python interpreter for a given sidecar id.

    Discord-bot uses [uv] (project has pyproject.toml + uv.lock). The
    other 3 ship a hand-managed [.venv/]. We prefer the venv path when
    it exists because it sidesteps a [uv] dependency on the host running
    the backend. *)
let python_argv_for id =
  let venv_python = Filename.concat (sidecar_dir id) ".venv/bin/python" in
  if Sys.file_exists venv_python then
    [ venv_python; "-m"; "src.schema_dump" ]
  else
    [ "uv"; "run"; "--directory"; sidecar_dir id; "python"; "-m"; "src.schema_dump" ]

let fetch_schema id =
  match Hashtbl.find_opt schema_cache id with
  | Some cached -> Ok cached
  | None ->
      let argv = python_argv_for id in
      let cwd = sidecar_dir id in
      let (status, stdout) =
        Process_eio.run_argv_with_status ~timeout_sec:10.0 ~cwd argv
      in
      (match status with
       | Unix.WEXITED 0 ->
           let trimmed = String.trim stdout in
           Hashtbl.replace schema_cache id trimmed;
           Ok trimmed
       | _ ->
           Error "schema_dump failed; ensure the sidecar's Python deps are installed (run `./run.sh start` once or `uv sync`)")

let handle_schema _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      (match fetch_schema id with
       | Error msg ->
           respond_json request reqd ~status:`Service_unavailable
             (`Assoc [
                ("ok", `Bool false);
                ("error", `String msg);
              ])
       | Ok json_str ->
           (match Yojson.Safe.from_string json_str with
            | parsed ->
                respond_json request reqd ~status:`OK
                  (`Assoc [
                     ("ok", `Bool true);
                     ("id", `String id);
                     ("schema", parsed);
                   ])
            | exception _ ->
                respond_json request reqd ~status:`Internal_server_error
                  (`Assoc [
                     ("ok", `Bool false);
                     ("error", `String "schema_dump returned invalid JSON");
                   ])))

let handle_start _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      (* Detach: run via setsid + nohup so the sidecar survives backend
         restart. Only [script_path id] is interpolated, and [id] is
         already whitelisted, so [Filename.quote] gives a closed-shell
         injection surface. *)
      let cmd =
        Printf.sprintf
          "setsid nohup %s start </dev/null >/dev/null 2>&1 &"
          (Filename.quote (script_path id))
      in
      let _ = Sys.command cmd in
      respond_json request reqd ~status:`Accepted
        (`Assoc [
           ("ok", `Bool true);
           ("id", `String id);
           ("note", `String "sidecar spawn requested; poll /api/v1/sidecar/status?name=...");
         ])

(** Register sidecar lifecycle routes on the router. *)
let add_routes ~sw:_ ~clock:_ router =
  router
  |> Http.Router.get "/api/v1/sidecar/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_status state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/sidecar/logs" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_logs state request reqd
       ) request reqd)

  (* Schema is field-shape metadata, not values, so it's safe under
     public_read — the dashboard form needs it during cold-start
     onboarding (before any auth tokens are configured). *)
  |> Http.Router.get "/api/v1/sidecar/schema" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_schema state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/sidecar/start" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_start state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/sidecar/stop" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_stop state request reqd
       ) request reqd)
