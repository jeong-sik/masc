(** Dashboard dev-token issuance and role-aware rotation.

    Rotation is a resumable four-step protocol:
    journal -> old credential revocation -> Worker credential -> raw token ->
    journal removal.
    A failure after the journal write leaves the exact raw token available for
    an idempotent retry, so the endpoint never responds to an indeterminate
    state by minting another credential. *)

let ( let* ) = Result.bind

let dashboard_dev_actor_name = "dashboard"

type error =
  | Request_host_rejected of Server_auth.request_host_rejection
  | Token_file_read_failed of { path : string; detail : string }
  | Credential_lookup_failed of Masc_domain.masc_error
  | Rotation_journal_read_failed of { path : string; detail : string }
  | Rotation_journal_invalid of { path : string }
  | Rotation_journal_write_failed of { path : string; detail : string }
  | Credential_revocation_failed of { agent_name : string; detail : string }
  | Credential_rotation_failed of Masc_domain.masc_error
  | Token_file_write_failed of { path : string; detail : string }
  | Rotation_finalize_failed of { path : string; detail : string }

let error_code = function
  | Request_host_rejected Server_auth.Missing_request_host ->
      "dashboard_dev_token_host_missing"
  | Request_host_rejected Server_auth.Malformed_request_host ->
      "dashboard_dev_token_host_malformed"
  | Request_host_rejected (Server_auth.Non_loopback_request_host _) ->
      "dashboard_dev_token_host_non_loopback"
  | Token_file_read_failed _ -> "dashboard_dev_token_read_failed"
  | Credential_lookup_failed _ -> "dashboard_dev_token_credential_lookup_failed"
  | Rotation_journal_read_failed _ -> "dashboard_dev_token_rotation_read_failed"
  | Rotation_journal_invalid _ -> "dashboard_dev_token_rotation_invalid"
  | Rotation_journal_write_failed _ -> "dashboard_dev_token_rotation_write_failed"
  | Credential_revocation_failed _ -> "dashboard_dev_token_credential_revocation_failed"
  | Credential_rotation_failed _ -> "dashboard_dev_token_credential_rotation_failed"
  | Token_file_write_failed _ -> "dashboard_dev_token_write_failed"
  | Rotation_finalize_failed _ -> "dashboard_dev_token_rotation_finalize_failed"

let error_to_string = function
  | Request_host_rejected Server_auth.Missing_request_host ->
      "dashboard dev-token request is missing the Host header"
  | Request_host_rejected Server_auth.Malformed_request_host ->
      "dashboard dev-token request has a malformed Host authority"
  | Request_host_rejected (Server_auth.Non_loopback_request_host host) ->
      Printf.sprintf
        "dashboard dev-token request Host %S is not an exact loopback host"
        host
  | Token_file_read_failed { path; detail } ->
      Printf.sprintf "read dashboard dev-token %s: %s" path detail
  | Credential_lookup_failed err ->
      Printf.sprintf
        "classify dashboard dev-token credential: %s"
        (Masc_domain.masc_error_to_string err)
  | Rotation_journal_read_failed { path; detail } ->
      Printf.sprintf "read dashboard dev-token rotation journal %s: %s" path detail
  | Rotation_journal_invalid { path } ->
      Printf.sprintf
        "dashboard dev-token rotation journal %s is invalid; refusing to mint a replacement"
        path
  | Rotation_journal_write_failed { path; detail } ->
      Printf.sprintf "write dashboard dev-token rotation journal %s: %s" path detail
  | Credential_revocation_failed { agent_name; detail } ->
      Printf.sprintf
        "revoke legacy dashboard credential %S: %s"
        agent_name detail
  | Credential_rotation_failed err ->
      Printf.sprintf
        "persist dashboard Worker credential: %s"
        (Masc_domain.masc_error_to_string err)
  | Token_file_write_failed { path; detail } ->
      Printf.sprintf "persist dashboard dev-token %s: %s" path detail
  | Rotation_finalize_failed { path; detail } ->
      Printf.sprintf "finalize dashboard dev-token rotation %s: %s" path detail

let dashboard_dev_token_path base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "auth")
    "dashboard.token"

let dashboard_dev_token_rotation_path base_path =
  dashboard_dev_token_path base_path ^ ".rotation"

type dashboard_dev_token_candidate =
  | Reusable of string
  | Rotate

let classify_dashboard_dev_token_candidate ~base_path raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    Ok Rotate
  else
    match Auth.find_credential_by_token base_path ~token:trimmed with
    | Ok credential
      when String.equal credential.agent_name dashboard_dev_actor_name
           && credential.role = Masc_domain.Worker ->
        Ok (Reusable trimmed)
    | Ok _ -> Ok Rotate
    | Error
        (Masc_domain.Auth
           (Masc_domain.Auth_error.InvalidToken _
           | Masc_domain.Auth_error.TokenExpired _
           | Masc_domain.Auth_error.Unauthorized _)) ->
        Ok Rotate
    | Error err -> Error (Credential_lookup_failed err)

let read_dashboard_dev_token ~base_path =
  let path = dashboard_dev_token_path base_path in
  try
    if not (Fs_compat.file_exists path) then
      Ok Rotate
    else
      classify_dashboard_dev_token_candidate
        ~base_path
        (Fs_compat.load_file path)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Token_file_read_failed
           { path; detail = Printexc.to_string exn })

let is_generated_token raw =
  String.length raw = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       raw

let read_rotation_journal ~base_path =
  let path = dashboard_dev_token_rotation_path base_path in
  try
    if not (Fs_compat.file_exists path) then
      Ok None
    else
      let raw = Fs_compat.load_file path |> String.trim in
      if is_generated_token raw then
        Ok (Some raw)
      else
        Error (Rotation_journal_invalid { path })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Rotation_journal_read_failed
           { path; detail = Printexc.to_string exn })

let write_private_atomic path content =
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic path content
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

let remove_rotation_journal path =
  try
    Eio_guard.run_in_systhread (fun () -> Sys.remove path);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

let revoke_dashboard_credential base_path =
  try
    Auth.delete_credential base_path dashboard_dev_actor_name;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Credential_revocation_failed
           { agent_name = dashboard_dev_actor_name
           ; detail = Printexc.to_string exn
           })

let resume_rotation ~base_path raw =
  let journal_path = dashboard_dev_token_rotation_path base_path in
  let token_path = dashboard_dev_token_path base_path in
  let* () = revoke_dashboard_credential base_path in
  let* _credential =
    Auth.save_raw_token_credential
      base_path
      ~agent_name:dashboard_dev_actor_name
      ~role:Masc_domain.Worker
      ~raw_token:raw
    |> Result.map_error (fun err -> Credential_rotation_failed err)
  in
  let* () =
    write_private_atomic token_path raw
    |> Result.map_error (fun detail -> Token_file_write_failed { path = token_path; detail })
  in
  let* () =
    remove_rotation_journal journal_path
    |> Result.map_error (fun detail ->
           Rotation_finalize_failed { path = journal_path; detail })
  in
  Ok raw

let begin_rotation ~base_path =
  let raw = Auth.generate_token () in
  let journal_path = dashboard_dev_token_rotation_path base_path in
  let* () =
    write_private_atomic journal_path raw
    |> Result.map_error (fun detail ->
           Rotation_journal_write_failed { path = journal_path; detail })
  in
  resume_rotation ~base_path raw

let ensure_dashboard_dev_token_unlocked base_path =
  let* pending = read_rotation_journal ~base_path in
  match pending with
  | Some raw -> resume_rotation ~base_path raw
  | None ->
      let* candidate = read_dashboard_dev_token ~base_path in
      (match candidate with
       | Reusable raw -> Ok raw
       | Rotate -> begin_rotation ~base_path)

let ensure_dashboard_dev_token ~mutex base_path =
  Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    ensure_dashboard_dev_token_unlocked base_path)

let ensure_dashboard_dev_token_for_request ~mutex ~request ~base_path =
  match Server_auth.admit_loopback_request_host request with
  | Error rejection -> Error (Request_host_rejected rejection)
  | Ok _ -> ensure_dashboard_dev_token ~mutex base_path
