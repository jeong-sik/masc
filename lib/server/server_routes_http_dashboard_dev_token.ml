(** Dashboard dev-token issuance and role-aware rotation.

    Rotation is a resumable transaction:
    journal -> credential revocation -> Admin credential -> public raw token
    -> journal removal. A failure after the journal write leaves the exact raw
    token available for an idempotent retry. *)

let ( let* ) = Result.bind

let dashboard_dev_actor_name = "dashboard"

(* The loopback dev-token is the local operator's own session. The endpoint
   answers exact loopback Hosts only and is absent under strict-auth, and any
   process on this machine can already read [.masc/auth/*.token] — a Worker
   ceiling here was friction, not a boundary: admin-gated dashboard surfaces
   refused the bootstrapped session while a hand-pasted admin bearer died on
   the next role-aware rotation. Remote and OAuth dashboard authentication
   are unaffected. *)
let dashboard_dev_role = Masc_domain.Admin

type dashboard_dev_token =
  { raw : string
  ; actor : string
  ; role : Masc_domain.agent_role
  }

type request_error =
  | Non_loopback_request_host of string
  | Token_operation_failed of token_error

and token_error =
  | Token_file_read_failed of { path : string; detail : string }
  | Credential_lookup_failed of Masc_domain.masc_error
  | Rotation_journal_read_failed of { path : string; detail : string }
  | Rotation_journal_invalid of { path : string }
  | Rotation_journal_write_failed of { path : string; detail : string }
  | Credential_revocation_failed of { agent_name : string; detail : string }
  | Credential_rotation_failed of Masc_domain.masc_error
  | Token_file_write_failed of { path : string; detail : string }
  | Rotation_finalize_failed of { path : string; detail : string }

let dashboard_dev_token raw =
  { raw; actor = dashboard_dev_actor_name; role = dashboard_dev_role }
;;

let token_error_code = function
  | Token_file_read_failed _ -> "dashboard_dev_token_read_failed"
  | Credential_lookup_failed _ -> "dashboard_dev_token_credential_lookup_failed"
  | Rotation_journal_read_failed _ -> "dashboard_dev_token_rotation_read_failed"
  | Rotation_journal_invalid _ -> "dashboard_dev_token_rotation_invalid"
  | Rotation_journal_write_failed _ -> "dashboard_dev_token_rotation_write_failed"
  | Credential_revocation_failed _ ->
    "dashboard_dev_token_credential_revocation_failed"
  | Credential_rotation_failed _ -> "dashboard_dev_token_credential_rotation_failed"
  | Token_file_write_failed _ -> "dashboard_dev_token_write_failed"
  | Rotation_finalize_failed _ -> "dashboard_dev_token_rotation_finalize_failed"
;;

let token_error_to_string = function
  | Token_file_read_failed { path; detail } ->
    Printf.sprintf "read dashboard dev-token %s: %s" path detail
  | Credential_lookup_failed error ->
    Printf.sprintf
      "classify dashboard dev-token credential: %s"
      (Masc_domain.masc_error_to_string error)
  | Rotation_journal_read_failed { path; detail } ->
    Printf.sprintf "read dashboard dev-token rotation journal %s: %s" path detail
  | Rotation_journal_invalid { path } ->
    Printf.sprintf
      "dashboard dev-token rotation journal %s is invalid; refusing to mint a replacement"
      path
  | Rotation_journal_write_failed { path; detail } ->
    Printf.sprintf "write dashboard dev-token rotation journal %s: %s" path detail
  | Credential_revocation_failed { agent_name; detail } ->
    Printf.sprintf "revoke dashboard credential %S: %s" agent_name detail
  | Credential_rotation_failed error ->
    Printf.sprintf
      "persist dashboard credential: %s"
      (Masc_domain.masc_error_to_string error)
  | Token_file_write_failed { path; detail } ->
    Printf.sprintf "persist dashboard dev-token %s: %s" path detail
  | Rotation_finalize_failed { path; detail } ->
    Printf.sprintf "finalize dashboard dev-token rotation %s: %s" path detail
;;

let request_error_status : request_error -> Httpun.Status.t = function
  | Non_loopback_request_host _ -> `Forbidden
  | Token_operation_failed _ -> `Internal_server_error
;;

let request_error_code = function
  | Non_loopback_request_host _ -> "dashboard_dev_token_host_non_loopback"
  | Token_operation_failed error -> token_error_code error
;;

let request_error_to_string = function
  | Non_loopback_request_host host ->
    Printf.sprintf
      "dashboard dev-token request Host %S is not an exact loopback host"
      host
  | Token_operation_failed error -> token_error_to_string error
;;

let dashboard_dev_token_path base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "auth")
    "dashboard.token"
;;

let dashboard_dev_token_pending_path base_path =
  dashboard_dev_token_path base_path ^ ".pending"
;;

type dashboard_dev_token_candidate =
  | Reusable of string
  | Rotate

let default_dashboard_dev_token_load path = Fs_compat.load_file path

let default_dashboard_dev_token_write path raw =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path raw
;;

let dashboard_dev_token_mu = Cross_context_mutex.create ()

let classify_dashboard_dev_token_candidate ~base_path raw =
  let trimmed = String.trim raw in
  if String.equal trimmed ""
  then Ok Rotate
  else
    match Auth.find_credential_by_token base_path ~token:trimmed with
    | Ok credential
      when String.equal credential.agent_name dashboard_dev_actor_name
           && credential.role = dashboard_dev_role ->
      Ok (Reusable trimmed)
    | Ok _ -> Ok Rotate
    | Error
        (Masc_domain.Auth
           (Masc_domain.Auth_error.InvalidToken _
           | Masc_domain.Auth_error.TokenExpired _
           | Masc_domain.Auth_error.Unauthorized _)) ->
      Ok Rotate
    | Error error -> Error (Credential_lookup_failed error)
;;

let read_dashboard_dev_token ~load ~base_path =
  let path = dashboard_dev_token_path base_path in
  try
    if not (Fs_compat.file_exists path)
    then Ok Rotate
    else
      classify_dashboard_dev_token_candidate
        ~base_path
        (load path)
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error ->
    Error
      (Token_file_read_failed
         { path; detail = Printexc.to_string error })
;;

let read_rotation_journal ~load ~base_path =
  let path = dashboard_dev_token_pending_path base_path in
  try
    if not (Fs_compat.file_exists path)
    then Ok None
    else (
      let raw = String.trim (load path) in
      if Auth.is_generated_token_shape raw
      then Ok (Some raw)
      else Error (Rotation_journal_invalid { path }))
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error ->
    Error
      (Rotation_journal_read_failed
         { path; detail = Printexc.to_string error })
;;

let write_private_atomic ~write path raw =
  try
    match write path raw with
    | Ok () -> Ok ()
    | Error detail -> Error detail
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error -> Error (Printexc.to_string error)
;;

let remove_rotation_journal path =
  try
    Eio_guard.run_in_systhread ~label:"dev-token-remove" (fun () -> Sys.remove path);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error -> Error (Printexc.to_string error)
;;

let revoke_dashboard_credential base_path =
  try
    Auth.delete_credential base_path dashboard_dev_actor_name;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error ->
    Error
      (Credential_revocation_failed
         { agent_name = dashboard_dev_actor_name
         ; detail = Printexc.to_string error
         })
;;

let resume_rotation ~write ~base_path raw =
  let pending_path = dashboard_dev_token_pending_path base_path in
  let token_path = dashboard_dev_token_path base_path in
  let* () = revoke_dashboard_credential base_path in
  let* _credential =
    Auth.save_raw_token_credential
      base_path
      ~agent_name:dashboard_dev_actor_name
      ~role:dashboard_dev_role
      ~raw_token:raw
    |> Result.map_error (fun error -> Credential_rotation_failed error)
  in
  let* () =
    write_private_atomic ~write token_path raw
    |> Result.map_error (fun detail -> Token_file_write_failed { path = token_path; detail })
  in
  let* () =
    remove_rotation_journal pending_path
    |> Result.map_error (fun detail ->
      Rotation_finalize_failed { path = pending_path; detail })
  in
  Ok (dashboard_dev_token raw)
;;

let begin_rotation ~write ~base_path =
  let raw = Auth.generate_token () in
  let pending_path = dashboard_dev_token_pending_path base_path in
  let* () =
    write_private_atomic ~write pending_path raw
    |> Result.map_error (fun detail ->
      Rotation_journal_write_failed { path = pending_path; detail })
  in
  resume_rotation ~write ~base_path raw
;;

let ensure_dashboard_dev_token_unlocked ~load ~write base_path =
  let* pending = read_rotation_journal ~load ~base_path in
  match pending with
  | Some raw -> resume_rotation ~write ~base_path raw
  | None ->
    let* candidate = read_dashboard_dev_token ~load ~base_path in
    (match candidate with
     | Reusable raw -> Ok (dashboard_dev_token raw)
     | Rotate -> begin_rotation ~write ~base_path)
;;

let ensure_dashboard_dev_token
      ?(load = default_dashboard_dev_token_load)
      ?(write = default_dashboard_dev_token_write)
      base_path
  =
  Cross_context_mutex.with_durable_lock dashboard_dev_token_mu (fun () ->
    ensure_dashboard_dev_token_unlocked ~load ~write base_path)
;;

let ensure_dashboard_dev_token_for_authority ~request_authority ~base_path =
  let host = Server_request_authority.host request_authority in
  if not (Server_auth.is_loopback_host host)
  then Error (Non_loopback_request_host host)
  else
    Result.map_error
      (fun error -> Token_operation_failed error)
      (ensure_dashboard_dev_token base_path)
;;
