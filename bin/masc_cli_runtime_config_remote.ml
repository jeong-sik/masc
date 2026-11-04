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
let voice_setup_path = "/api/v1/voice/setup"

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

type store_error =
  | Changed_on_server
  | Not_stored of string
  | Unanswered of string

let store_error_message = function
  | Changed_on_server ->
    "runtime.toml changed on the server while this command ran. Nothing was saved; run it again."
  | Not_stored message -> message
  | Unanswered detail ->
    "The server's answer to the save did not arrive, so whether it was stored is unknown: " ^ detail

(* Save [edited] over [source] with the revision and path it was read at. A
   save that finds the file changed since is refused by the server (409); the
   command says so rather than retrying a stale edit. *)
let store_source ~clock server source ~edited =
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
    | Error detail -> Error (Unanswered detail)
    | Ok (200, _) -> Ok (Saved { path = source.path })
    | Ok (409, _) -> Error Changed_on_server
    | Ok (status, body) -> Error (Not_stored (error_of_body ~status body))

let store ~clock server source ~edited =
  Result.map_error store_error_message (store_source ~clock server source ~edited)

let save ~clock server ~edit =
  let open Result.Syntax in
  let* source = fetch ~clock server in
  let* edited = edit source.text in
  store ~clock server source ~edited

(* What voice-local-setup decides its changes against: the revision of the
   configuration, the path of voice_config.json when that file is the active
   voice source, and the speaking endpoints by id and kind. A kind this binary
   does not name is [None]: it is still an endpoint the placement has to count. *)
type voice_ground =
  { revision : string
  ; standalone : string option
  ; speaking : (string * Voice_config.endpoint_kind option) list
  }

let voice_answer_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

let voice_answer_unread what = Error ("The server's voice setup answer has no readable " ^ what ^ ".")

let voice_source json =
  match voice_answer_field "source" json with
  | None | Some `Null -> Ok None
  | Some source ->
    (match voice_answer_field "kind" source with
     | Some (`String "runtime_toml") -> Ok None
     | Some (`String "standalone_json") ->
       (match voice_answer_field "path" source with
        | Some (`String path) -> Ok (Some path)
        | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
          voice_answer_unread "voice_config.json path")
     | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
       voice_answer_unread "source")

let speaking_endpoint entry =
  match voice_answer_field "id" entry with
  | Some (`String id) ->
    (match voice_answer_field "kind" entry with
     | Some (`String kind) -> Ok (id, Voice_config.endpoint_kind_of_name kind)
     | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
       voice_answer_unread "speaking endpoint kind")
  | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
    voice_answer_unread "speaking endpoint id"

let voice_speaking json =
  match voice_answer_field "tts" json with
  | None | Some `Null -> Ok []
  | Some tts ->
    (match voice_answer_field "endpoints" tts with
     | Some (`List entries) ->
       List.fold_right
         (fun entry acc ->
            let open Result.Syntax in
            let* rest = acc in
            let* endpoint = speaking_endpoint entry in
            Ok (endpoint :: rest))
         entries (Ok [])
     | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
       voice_answer_unread "speaking endpoints")

(* The ground as the running server holds it, read from its voice route: the
   server may resolve a different configuration file than this process
   would (MASC_CONFIG_DIR), and the changes are applied to the server's. *)
let fetch_voice_ground ~clock server =
  let open Result.Syntax in
  let* status, body =
    Result.map_error
      (fun detail -> "The workspace server did not answer its voice setup: " ^ detail)
      (Masc_http_client.get_sync ~clock ~url:(server.origin ^ voice_setup_path) ~headers:server.headers ())
  in
  let* json =
    if status = 200 then
      match Yojson.Safe.from_string body with
      | json -> Ok json
      | exception Yojson.Json_error detail -> Error ("The server's voice setup answer is not JSON: " ^ detail)
    else Error (error_of_body ~status body)
  in
  let* revision =
    match voice_answer_field "revision" json with
    | Some (`String revision) -> Ok revision
    | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
      voice_answer_unread "revision"
  in
  let* standalone = voice_source json in
  let* speaking = voice_speaking json in
  Ok { revision; standalone; speaking }

(* Voice setup goes to the server's voice route, not the text route: voice
   also reads voice_config.json, which the text route does not hold. The server
   applies [changes] under its lock against [revision], the revision they were
   decided on, and refuses (409) when the file moved since. *)
let apply_voice_setup ~clock server ~revision changes =
  let body = Yojson.Safe.to_string (Voice_wizard.request_json ~revision changes) in
  match
    Masc_http_client.post_sync ~clock ~url:(server.origin ^ voice_setup_path) ~headers:server.headers ~body ()
  with
  | Error detail ->
    Error ("The server's answer to the setup did not arrive, so whether it was stored is unknown: " ^ detail)
  | Ok (200, _) -> Ok ()
  | Ok (status, body) -> Error (error_of_body ~status body)

(* The running server as a table edit's store (browser-lane-setup): it reads
   the text the server holds and commits through the text route. The path is
   the one the server read when the store was made; it names the file in
   messages. *)
let table_store ~clock server =
  let open Result.Syntax in
  let* first = fetch ~clock server in
  let observation_of (source : source) = Runtime.config_observation ~path:source.path source.text in
  Ok
    { Masc.Runtime_table_edit.path = first.path
    ; observe =
        (fun () ->
          fetch ~clock server
          |> Result.map observation_of
          |> Result.map_error (fun reason -> Masc.Runtime_table_edit.Unreadable { path = first.path; reason }))
    ; commit =
        (fun ~revision ~edit ->
          match fetch ~clock server with
          | Error reason -> Error (Masc.Runtime_table_edit.Not_written reason)
          | Ok source ->
            if not (String.equal (Masc.Runtime_table_edit.revision_of_observation (observation_of source)) revision)
            then Error Masc.Runtime_table_edit.Changed_meanwhile
            else (
              match edit source.text with
              | Error error -> Error (Masc.Runtime_table_edit.Edit_refused error)
              | Ok edited ->
                (match store_source ~clock server source ~edited with
                 | Ok (Saved _ | Unchanged) -> Ok ()
                 | Error Changed_on_server -> Error Masc.Runtime_table_edit.Changed_meanwhile
                 | Error (Not_stored message) -> Error (Masc.Runtime_table_edit.Not_written message)
                 (* The answer was lost: what the server holds now says whether
                    the edit landed. *)
                 | Error (Unanswered detail) ->
                   let revision_of text =
                     Masc.Runtime_table_edit.revision_of_observation (observation_of { source with text })
                   in
                   (match fetch ~clock server with
                    | Ok now when String.equal (revision_of now.text) (revision_of edited) -> Ok ()
                    | Ok now when String.equal (revision_of now.text) (revision_of source.text) ->
                      Error (Masc.Runtime_table_edit.Not_written ("the server did not answer the save: " ^ detail))
                    | Ok (_ : source) ->
                      Error
                        (Masc.Runtime_table_edit.Outcome_unknown
                           ("the server did not answer the save, and runtime.toml has changed since: " ^ detail))
                    | Error reason ->
                      Error
                        (Masc.Runtime_table_edit.Outcome_unknown
                           ("the server did not answer the save, and could not be read again: " ^ reason))))))
    }

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
