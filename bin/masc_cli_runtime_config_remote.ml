(* RFC-0482 §3.2: while the workspace's server runs, it is the one writer of
   runtime.toml. A command that edits the file asks the server for the text it
   reads, edits that text, and saves it back with the revision it read, so the
   server commits, publishes and announces it like any other save. With no
   server answering, the command writes the file itself, as it did before:
   then there is no other writer and no reader to tell. *)

type server = { origin : string; headers : (string * string) list }

type target =
  | Running_server of server
  | No_server

type saved =
  | Unchanged
  | Saved of { path : string }

let health_path = "/health?full=1"
let raw_path = "/api/v1/runtime/config/raw"

(* This workspace's server answers on the port and is ready: it is the
   writer. This workspace's server is still starting, or answers without a
   sign-in to present: the command stops, because writing the file under a
   running server would bypass it. Nothing answers, or the port answers for
   another workspace or for something that is not a masc server: this
   workspace's server is not there, and the command is the writer. *)
let find ~clock ~base_path ~port ~agent =
  let origin = Printf.sprintf "http://127.0.0.1:%d" port in
  match Masc_http_client.get_sync ~clock ~url:(origin ^ health_path) ~headers:[] () with
  | Error _ -> Ok No_server
  | Ok (200, health) ->
    (match Masc_cli_setup.health_state ~base_path health with
     (* [health_state] resolves the answered path, which on another machine's
        layout or a removed workspace does not exist here. *)
     | exception (Masc_cli_setup.Setup_error _ | Unix.Unix_error _) -> Ok No_server
     | false -> Error "The workspace server is starting. Run this again when it is ready."
     | true ->
       (match Auth_login.read_persisted_http_token ~base_path ~agent_name:agent with
        | None ->
          Error "The workspace server is running, and this command saves through it. Sign in first (masc login)."
        | Some token ->
          Ok
            (Running_server
               { origin
               ; headers =
                   [ "authorization", "Bearer " ^ token
                   ; "x-masc-agent", agent
                   ; "content-type", "application/json"
                   ]
               })))
  | Ok ((_ : int), _) -> Ok No_server

let string_field json name =
  match Yojson.Safe.Util.member name json with
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (Printf.sprintf "The server's runtime.toml answer has no %s." name)

let error_of_body ~status body =
  match Yojson.Safe.from_string body with
  | json ->
    (match Yojson.Safe.Util.member "error" json with
     | `String message -> Printf.sprintf "The server refused the save (HTTP %d): %s" status message
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
       Printf.sprintf "The server refused the save (HTTP %d)." status)
  | exception Yojson.Json_error _ -> Printf.sprintf "The server refused the save (HTTP %d)." status

(* The runtime.toml text the server reads, with the revision and path it read
   it at. *)
type source = { text : string; revision : string; path : string }

let fetch ~clock server =
  let open Result.Syntax in
  let* status, body =
    Result.map_error
      (fun detail -> "The workspace server did not answer runtime.toml: " ^ detail)
      (Masc_http_client.get_sync ~clock ~url:(server.origin ^ raw_path) ~headers:server.headers ())
  in
  let* json =
    if status = 200 then
      match Yojson.Safe.from_string body with
      | json -> Ok json
      | exception Yojson.Json_error detail -> Error ("The server's runtime.toml answer is not JSON: " ^ detail)
    else Error (error_of_body ~status body)
  in
  let* text = string_field json "source_text" in
  let* revision = string_field json "source_revision" in
  let* path = string_field json "path" in
  Ok { text; revision; path }

(* Save [edited] over [source] with the revision and path it was read at. A
   save that finds the file changed since is refused by the server (409); the
   command says so rather than retrying a stale edit. *)
let store ~clock server source ~edited =
  if String.equal edited source.text then Ok Unchanged
  else
    let request =
      Yojson.Safe.to_string
        (`Assoc
           [ "source_text", `String edited
           ; "expected_source_revision", `String source.revision
           ; "expected_source_path", `String source.path
           ])
    in
    match
      Masc_http_client.post_sync ~clock ~url:(server.origin ^ raw_path) ~headers:server.headers ~body:request ()
    with
    | Error detail ->
      Error ("The save was sent, and the server's answer did not arrive, so whether it was stored is unknown: " ^ detail)
    | Ok (200, _) -> Ok (Saved { path = source.path })
    | Ok (409, _) -> Error "runtime.toml changed on the server while this command ran. Nothing was saved; run it again."
    | Ok (status, body) -> Error (error_of_body ~status body)

let save ~clock server ~edit =
  let open Result.Syntax in
  let* source = fetch ~clock server in
  let* edited = edit source.text in
  store ~clock server source ~edited

(* The Eio context the HTTP client needs, for a command that otherwise runs
   without one. *)
let with_client f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () -> f ~clock:(Eio.Stdenv.clock env))))
