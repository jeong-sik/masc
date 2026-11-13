(* RFC-0482 §3.2: while the workspace's server runs, it is the one writer of
   runtime.toml. A command that edits the file asks the server for the text it
   reads, edits that text, and saves it back with the revision it read, so the
   server commits, publishes and announces it like any other save. When no
   process holds the workspace's lease, the command writes the file itself:
   then there is no other writer and no reader to tell. A command never writes
   the file while a process holds the lease. *)

module Upgrade = Server_upgrade_preparation

type server =
  { owner : Upgrade.single_user_server
  ; origin : string
  ; headers : (string * string) list
  }

type target =
  | Running_server of server
  | No_server

type saved =
  | Unchanged
  | Saved of { path : string }

let raw_path = "/api/v1/runtime/config/raw"
let voice_setup_path = "/api/v1/voice/setup"

(* HIGH-RISK-UNREVIEWED: which process gets the operator bearer, and whether
   the command may write runtime.toml itself, is what the kernel says of the
   lease of [base_path]. Only the server of a single user that the kernel
   names as lease owner and announcer of [port] gets a [Running_server]. The
   file is written locally only when nothing holds the lease; any other owner
   stops the command. The port is read without credentials only for
   [/health/ready]. *)
let find ~clock ~base_path ~port ~agent =
  let root = (Host_config.host ()).base_path_lease_root in
  match Upgrade.owner_without_making root ~base_path ~port with
  | Ok Upgrade.Unowned -> Ok No_server
  | Error unread ->
    Error
      (Printf.sprintf "The owner of %s could not be checked (%s). Nothing was saved." base_path
         (Server_startup_takeover.owner_capture_error_to_string unread))
  | Ok (Upgrade.Single_user_server_here owner) ->
    let origin = Masc_network_defaults.masc_http_loopback_origin ~port in
    (match
       Masc_http_client.get_sync ~clock ~timeout_sec:Masc_http_client.default_request_timeout_sec
         ~url:(origin ^ Server_health_paths.readiness) ~headers:[] ()
     with
     | Ok (200, (_ : string)) ->
       (match Auth_login.read_persisted_http_token ~base_path ~agent_name:agent with
        | None ->
          Error "The workspace server is running, and this command saves through it. Sign in first (masc login)."
        | Some token ->
          Ok
            (Running_server
               { owner
               ; origin
               ; headers =
                   [ "authorization", "Bearer " ^ token
                   ; "x-masc-agent", agent
                   ; "content-type", "application/json"
                   ]
               }))
     | Ok ((_ : int), (_ : string)) -> Error "The workspace server is starting. Run this again when it is ready."
     | Error (_ : string) ->
       Error
         (Printf.sprintf
            "The server of %s (pid %d) announces port %d and does not answer there. Run this again \
             when it does. Nothing was saved."
            base_path (Upgrade.single_user_server_pid owner) port))
  | Ok
      (( Upgrade.Single_user_server_elsewhere _ | Upgrade.Owner_unannounced _
       | Upgrade.Account_server_here _ | Upgrade.Account_server_elsewhere _ ) as owner) ->
    Error
      (Upgrade.owner_sentence ~lease_dir:(Upgrade.lease_directory root ~base_path) ~base_path ~port
         owner
       ^ " Nothing was saved.")

(* HIGH-RISK-UNREVIEWED: every send of the bearer asks the kernel again, right
   before it, whether it still names the server [find] found. A command that
   sends several requests, or sends after a long edit, sends nothing more to a
   process that took the port or the lease meanwhile. *)
let checked server ~refused send =
  match Upgrade.confirm server.owner with
  | Ok () -> send ()
  | Error departure ->
    refused (Upgrade.departure_sentence server.owner departure ^ " Nothing more was sent to it.")

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
  checked server ~refused:Result.error @@ fun () ->
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
    checked server ~refused:(fun message -> Error (Not_stored message)) @@ fun () ->
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

let answer_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

let voice_answer_unread what = Error ("The server's voice setup answer has no readable " ^ what ^ ".")

let voice_source json =
  match answer_field "source" json with
  | None | Some `Null -> Ok None
  | Some source ->
    (match answer_field "kind" source with
     | Some (`String "runtime_toml") -> Ok None
     | Some (`String "standalone_json") ->
       (match answer_field "path" source with
        | Some (`String path) -> Ok (Some path)
        | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
          voice_answer_unread "voice_config.json path")
     | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
       voice_answer_unread "source")

let speaking_endpoint entry =
  match answer_field "id" entry with
  | Some (`String id) ->
    (match answer_field "kind" entry with
     | Some (`String kind) -> Ok (id, Voice_config.endpoint_kind_of_name kind)
     | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
       voice_answer_unread "speaking endpoint kind")
  | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
    voice_answer_unread "speaking endpoint id"

let voice_speaking json =
  match answer_field "tts" json with
  | None | Some `Null -> Ok []
  | Some tts ->
    (match answer_field "endpoints" tts with
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
  checked server ~refused:Result.error @@ fun () ->
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
    match answer_field "revision" json with
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
  checked server ~refused:Result.error @@ fun () ->
  let body = Yojson.Safe.to_string (Voice_wizard.request_json ~revision changes) in
  match
    Masc_http_client.post_sync ~clock ~url:(server.origin ^ voice_setup_path) ~headers:server.headers ~body ()
  with
  | Error detail ->
    Error ("The server's answer to the setup did not arrive, so whether it was stored is unknown: " ^ detail)
  | Ok (200, _) -> Ok ()
  | Ok (status, body) -> Error (error_of_body ~status body)

let answer_string what name json =
  match answer_field name json with
  | Some (`String value) -> Ok value
  | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
    Error (Printf.sprintf "%s has no readable %s" what name)

let lock_warning_of_answer row =
  match answer_field "code" row, answer_field "detail" row with
  | Some (`String "runtime_config_lock_release_unconfirmed"), Some (`String detail) ->
    Ok (Runtime.Config_lock_release_unconfirmed detail)
  | (None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)),
    (None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)) ->
    Error "a lock warning this command does not know"

(* The server's commit receipt in its answer to a text save, as the setup
   batch reports it. *)
let commit_record_of_answer body =
  let open Result.Syntax in
  let* json =
    match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error detail -> Error ("the answer is not JSON: " ^ detail)
  in
  let* commit =
    match answer_field "commit" json with
    | Some (`Assoc _ as commit) -> Ok commit
    | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
      Error "the answer carries no commit"
  in
  let* source_revision = answer_string "the commit" "source_revision" commit in
  let* order = answer_string "the commit" "order" commit in
  let* durability =
    match answer_string "the commit" "durability" commit with
    | Ok "durable" -> Ok Runtime.Durable
    | Ok "unconfirmed" ->
      let* detail = answer_string "the commit" "durability_detail" commit in
      Ok (Runtime.Durability_unconfirmed { detail })
    | Ok other -> Error ("the commit names an unknown durability " ^ other)
    | Error reason -> Error reason
  in
  let* lock_warnings =
    match answer_field "warnings" commit with
    | Some (`List rows) ->
      List.fold_right
        (fun row acc ->
           let* rest = acc in
           let* warning = lock_warning_of_answer row in
           Ok (warning :: rest))
        rows (Ok [])
    | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
      Error "the commit lists no lock warnings"
  in
  Ok { Runtime_setup_batch.source_revision; order; durability; lock_warnings }

(* The server validates the whole file, commits it and writes its audit before
   it answers, so the batch waits longer than a plain read. A save that lands
   after this is reported as unobserved, never as refused. *)
let setup_publication_timeout_sec = 60.0

(* The commit of a setup batch decided against the running server's text:
   the validated text saved over [source], the text the batch started from.
   It is saved even when it equals [source], as the local commit would be, so
   the receipt is the server's. *)
let publish_setup_text ~clock server (source : source) ~text =
  (* Nothing was sent when the kernel names another process: a refusal. *)
  checked server ~refused:(fun message -> Error (Runtime_setup_batch.Commit_refused message)) @@ fun () ->
  let request =
    Yojson.Safe.to_string
      (`Assoc
         [ "source_text", `String text
         ; "expected_source_revision", `String source.revision
         ; "expected_source_path", `String source.path
         ])
  in
  match
    Masc_http_client.post_sync ~clock ~timeout_sec:setup_publication_timeout_sec
      ~url:(server.origin ^ raw_path) ~headers:server.headers ~body:request ()
  with
  | Error detail -> Error (Runtime_setup_batch.Commit_unobserved detail)
  | Ok (409, _) -> Error Runtime_setup_batch.Changed_configuration
  | Ok (200, body) ->
    Result.map_error
      (fun reason ->
        Runtime_setup_batch.Commit_unobserved ("the server answered 200 and " ^ reason))
      (commit_record_of_answer body)
  (* The server answers its save after committing, so a server error may
     follow a save that landed. *)
  | Ok (status, body) when status >= 500 ->
    Error (Runtime_setup_batch.Commit_unobserved (error_of_body ~status body))
  | Ok (status, body) -> Error (Runtime_setup_batch.Commit_refused (error_of_body ~status body))

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
