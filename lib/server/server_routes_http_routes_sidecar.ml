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

let status_file id =
  Filename.concat (base_path ()) (Printf.sprintf ".gate/runtime/%s/status.json" id)

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

  |> Http.Router.post "/api/v1/sidecar/start" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_start state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/sidecar/stop" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_stop state request reqd
       ) request reqd)
