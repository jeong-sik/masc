(** MASC Authentication & Authorization Module *)

open Masc_domain

(* ============================================ *)
(* Crypto utilities                             *)
(* ============================================ *)

(** Generated bearer-token shape authority. *)
let generated_token_bytes = 32

(** Generate a cryptographically random token (hex string). *)
let generate_token () =
  Random_id.hex ~bytes:generated_token_bytes
;;

let is_generated_token_shape raw =
  String.length raw = 2 * generated_token_bytes
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       raw
;;

(** SHA256 hash of a string using Digestif *)
let sha256_hash input = Digestif.SHA256.(digest_string input |> to_hex)

(** Timing-resistant equality delegated to Eqaf. Runtime depends on the public
    input lengths, not secret contents. Auth comparisons below operate on
    fixed-width SHA-256 hex digests. *)
let constant_time_string_equal = Eqaf.equal

(* ============================================ *)
(* Auth directory management                    *)
(* ============================================ *)

let auth_dir config = Common.auth_dir_from_base_path ~base_path:config
let agents_dir config = Common.agents_dir_from_base_path ~base_path:config
let workspace_secret_file config = Filename.concat (auth_dir config) "workspace_secret.hash"
let auth_config_file config = Filename.concat (auth_dir config) "config.json"
let initial_admin_file config = Filename.concat (auth_dir config) "initial_admin"

let internal_keeper_token_hash_file config =
  Filename.concat (auth_dir config) "internal_keeper.token.hash"
;;

let internal_keeper_token_env_key = "MASC_INTERNAL_MCP_TOKEN"

(* In-process holder for the internal keeper token (RFC-0371 B11). The env
   var stays as the cross-process surface (startup import, diagnostics),
   but in-process consumers read this typed value: before it existed, boot
   wrote the token with putenv and the tool-workspace credential check read
   it back with getenv on every call — the process using its own
   environment as a mutable in-memory channel. *)
let internal_keeper_token_holder : string option Atomic.t = Atomic.make None
let internal_keeper_token () = Atomic.get internal_keeper_token_holder
let run_blocking_io f = Eio_guard.run_in_systhread ~label:"auth-credential-io" f
let file_exists path = run_blocking_io (fun () -> Sys.file_exists path)
let write_text_file path content = Fs_compat.save_file path content
let chmod path perm = run_blocking_io (fun () -> Unix.chmod path perm)
let read_dir path = run_blocking_io (fun () -> Sys.readdir path)
let remove_file path = run_blocking_io (fun () -> Sys.remove path)

(* Shared file authority for config, raw bearers and canonical credential reads.
   Expected I/O errors become typed results; Eio cancellation propagates. *)
let credential_read_result f =
  try Ok (f ()) with
  | Sys_error detail -> Error (System (System_error.IoError detail))
  | Unix.Unix_error (error, operation, argument) ->
    Error (System (System_error.IoError
      (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
  | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn)))
;;

let credential_path_exists file =
  try
    let _stat = run_blocking_io (fun () -> Unix.lstat file) in
    Ok true
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (error, operation, argument) ->
    Error (System (System_error.IoError
      (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
  | Sys_error detail -> Error (System (System_error.IoError detail))
  | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn)))
;;

let read_regular_auth_file_with_open ~open_file path =
  let ( let* ) = Result.bind in
  let* result = credential_read_result (fun () -> run_blocking_io (fun () ->
    (* Following a regular-file symlink remains supported. Nonblocking open
       prevents a replacement FIFO from waiting for a writer before fstat. *)
    let fd = open_file path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      let before = Unix.fstat fd in
      if before.Unix.st_kind <> Unix.S_REG then
        Error (System (System_error.ValidationError
          (Printf.sprintf "auth path is not a regular file: %s" path)))
      else
        let content = In_channel.input_all channel in
        let after = Unix.fstat fd in
        let named = Unix.stat path in
        if before.Unix.st_size <> after.Unix.st_size
           || before.Unix.st_mtime <> after.Unix.st_mtime
           || before.Unix.st_ctime <> after.Unix.st_ctime
           || after.Unix.st_dev <> named.Unix.st_dev
           || after.Unix.st_ino <> named.Unix.st_ino then
          Error (System (System_error.IoError
            (Printf.sprintf "auth path changed during verified read: %s" path)))
        else Ok content))) in
  result
;;

let read_regular_auth_file path =
  read_regular_auth_file_with_open ~open_file:Unix.openfile path
;;

module Regular_read_for_testing = struct
  let read_with_open = read_regular_auth_file_with_open
end
;;

(** Ensure auth directories exist *)
let ensure_auth_dirs config =
  let auth = auth_dir config in
  let agents = agents_dir config in
  Fs_compat.mkdir_p auth;
  Fs_compat.mkdir_p agents
;;

(** Write the initial admin agent name (bootstrap grace).
    The agent who enables auth is always granted full permission. *)
let write_initial_admin config agent_name =
  ensure_auth_dirs config;
  let file = initial_admin_file config in
  write_text_file file (String.trim agent_name);
  chmod file 0o600
;;

let save_private_text_file path content =
  match Fs_compat.save_file_atomic_strict path content with
  | Ok () -> chmod path 0o600
  | Error reason -> raise (Sys_error reason)
;;

let load_internal_keeper_token_hash config =
  match read_regular_auth_file (internal_keeper_token_hash_file config) with
  | Error _ -> None
  | Ok content ->
    let hash = String.trim content in
    if hash = "" then None else Some hash
;;

let save_internal_keeper_token_hash config ~raw_token =
  ensure_auth_dirs config;
  let file = internal_keeper_token_hash_file config in
  save_private_text_file file (sha256_hash raw_token)
;;

let verify_internal_keeper_token config ~token =
  match load_internal_keeper_token_hash config with
  | Some stored_hash -> constant_time_string_equal stored_hash (sha256_hash token)
  | None -> false
;;

let ensure_internal_keeper_token config =
  let existing_env =
    match Sys.getenv_opt internal_keeper_token_env_key with
    | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
    | None -> None
  in
  match existing_env with
  | Some raw_token ->
    save_internal_keeper_token_hash config ~raw_token;
    Atomic.set internal_keeper_token_holder (Some raw_token);
    raw_token
  | None ->
    let raw_token = generate_token () in
    save_internal_keeper_token_hash config ~raw_token;
    Unix.putenv internal_keeper_token_env_key raw_token;
    Atomic.set internal_keeper_token_holder (Some raw_token);
    raw_token
;;

(** Read the initial admin agent name, if set. *)
let read_initial_admin config : string option =
  match read_regular_auth_file (initial_admin_file config) with
  | Error _ -> None
  | Ok content ->
    let name = String.trim content in
    if name = "" then None else Some name
;;

(* ============================================ *)
(* Auth config management                       *)
(* ============================================ *)

let persist_auth_config config (auth_cfg : auth_config) =
  ensure_auth_dirs config;
  let file = auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  save_private_text_file file (Yojson.Safe.pretty_to_string json)
;;

exception Auth_config_error of {
  file : string;
  reason : string;
}

let () =
  Printexc.register_printer (function
    | Auth_config_error _ -> Some "Auth.Auth_config_error"
    | _ -> None)

let raise_auth_config_error ~file reason =
  Log.Auth.error "auth configuration rejected file=%s reason=%s" file reason;
  raise (Auth_config_error { file; reason })
;;

(* HIGH-RISK-UNREVIEWED: authenticated requests use this configuration.
   Metadata checks run on system threads through the shared Auth reader,
   allowing other fibers to proceed while the filesystem answers. *)
(** Load auth config. Only an absent path selects the secure default;
    occupied unreadable/nonregular paths refuse before any open or mutation. *)
let load_auth_config config : auth_config =
  let file = auth_config_file config in
  match credential_path_exists file with
  | Error error -> raise_auth_config_error ~file (masc_error_to_string error)
  | Ok false -> default_auth_config
  | Ok true ->
    (match read_regular_auth_file file with
     | Error error -> raise_auth_config_error ~file (masc_error_to_string error)
     | Ok content ->
       (try
          let json = Yojson.Safe.from_string content in
          match auth_config_of_yojson json with
          | Ok parsed -> parsed
          | Error msg -> raise_auth_config_error ~file msg
        with
        | Yojson.Json_error msg -> raise_auth_config_error ~file msg))
;;

(** Save auth config *)
let save_auth_config config (auth_cfg : auth_config) =
  let file = auth_config_file config in
  match auth_config_of_yojson (auth_config_to_yojson auth_cfg) with
  | Ok _ -> persist_auth_config config auth_cfg
  | Error reason -> raise_auth_config_error ~file reason
;;

let init_workspace_secret config : string =
  ensure_auth_dirs config;
  let secret = generate_token () in
  let hash = sha256_hash secret in
  save_private_text_file (workspace_secret_file config) hash;
  let cfg = load_auth_config config in
  save_auth_config config { cfg with workspace_secret_hash = Some hash };
  secret
;;

(* ============================================ *)
(* Credential management                        *)
(* ============================================ *)

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (Common.safe_filename agent_name ^ ".json")
;;

module Nickname_helpers = Auth_nickname

let is_generated_nickname_shape = Nickname_helpers.is_generated_nickname_shape
let keeper_transport_alias_stable_name = Nickname_helpers.keeper_transport_alias_stable_name
let extract_agent_type_prefix = Nickname_helpers.extract_agent_type_prefix
let credential_agent_name = Nickname_helpers.credential_agent_name

let raw_token_file config agent_name =
  Filename.concat (auth_dir config) (Common.safe_filename agent_name ^ ".token")
;;

(* Decode an already-read JSON value and retain credential parse diagnostics. *)
let credential_of_json agent_name json : agent_credential option =
  match agent_credential_of_yojson json with
  | Ok cred -> Some cred
  | Error msg ->
    Log.Auth.warn "[load_credential] parse error for %s: %s" agent_name msg;
    None
;;

(* One credential file at [path]: [None] when it is absent, cannot be read,
   or does not decode. *)
let load_credential_from_path_raw _config agent_name path : agent_credential option =
  match read_regular_auth_file path with
  | Error _ -> None
  | Ok content ->
    (try credential_of_json agent_name (Yojson.Safe.from_string content) with
     | Yojson.Json_error _ -> None)
;;

let credential_uuid_file config cid =
  Filename.concat (agents_dir config) (Credential_id.to_string cid ^ ".json")
;;

let redirect_target_file config target =
  if Filename.basename target = target && Filename.check_suffix target ".json"
  then Some (Filename.concat (agents_dir config) target)
  else None
;;

let load_redirect_target config path =
  match read_regular_auth_file path with
  | Error _ -> None
  | Ok content ->
    (try
       match Yojson.Safe.from_string content with
       | `Assoc fields ->
         (match List.assoc_opt "redirect_to" fields with
          | Some (`String target) -> redirect_target_file config target
          | _ -> None)
       | _ -> None
     with
     | Yojson.Json_error _ -> None)
;;

let remove_file_if_exists path =
  try run_blocking_io (fun () -> Unix.unlink path) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(* [agent_name]'s own file, then the id-named file its redirect stub points
   to. A name that signs in with another name's token (a generated nickname,
   a Keeper transport alias) has no file of its own; the token check maps it
   to the owner ([Auth_credential_token.verify_token_owner_alias]), not this
   lookup. *)
let load_credential config agent_name : agent_credential option =
  match read_regular_auth_file (credential_file config agent_name) with
  | Error _ -> None
  | Ok content ->
    (try
       let json = Yojson.Safe.from_string content in
       match json with
       | `Assoc fields ->
         (match List.assoc_opt "redirect_to" fields with
          | Some (`String target) ->
            (match redirect_target_file config target with
             | Some redirect_path ->
               load_credential_from_path_raw config agent_name redirect_path
             | None -> None)
          | Some _ -> None
          | None -> credential_of_json agent_name json)
       | _ -> credential_of_json agent_name json
     with
     | Yojson.Json_error _ -> None)
;;

type load_credential_error =
  | Credential_missing of { ctx_agent_name : string }
  | Credential_mismatch of
      { ctx_agent_name : string
      ; resolved_credential_stem : string
      }

let pp_load_credential_error fmt = function
  | Credential_missing { ctx_agent_name } ->
    Format.fprintf fmt "Credential_missing { ctx_agent_name = %S }" ctx_agent_name
  | Credential_mismatch { ctx_agent_name; resolved_credential_stem } ->
    Format.fprintf
      fmt
      "Credential_mismatch { ctx_agent_name = %S; resolved_credential_stem = %S }"
      ctx_agent_name
      resolved_credential_stem
;;

let show_load_credential_error err = Format.asprintf "%a" pp_load_credential_error err

let load_credential_of config ~ctx_agent_name ~resolved_credential_stem
  : (agent_credential, load_credential_error) result
  =
  if String.equal resolved_credential_stem ctx_agent_name
  then (
    match load_credential config ctx_agent_name with
    | Some cred -> Ok cred
    | None -> Error (Credential_missing { ctx_agent_name }))
  else Error (Credential_mismatch { ctx_agent_name; resolved_credential_stem })
;;

(** Forward-declared invalidator for [credential_index_cache], wired
    later in this file once the cache state is in scope.  Default is a
    no-op so [save_credential] / [delete_credential] do not break if
    [register_credential_cache_invalidator] is somehow skipped; the
    TTL bound in the cache still guarantees eventual freshness. *)
let credential_cache_invalidator_ref
  : (string -> unit) ref
  =
  ref (fun (_ : string) -> ())
;;

type credential_transaction = Credential_transaction of string

let with_credential_transaction config f =
  let lock_path =
    try
      ensure_auth_dirs config;
      (* One path spelling also gives aliases of the base directory the same
         in-process gate; POSIX record locks alone do not exclude own threads. *)
      Ok (run_blocking_io (fun () ->
        Filename.concat (Unix.realpath (auth_dir config)) ".credentials.lock"))
    with
    | Sys_error detail -> Error (System (System_error.IoError detail))
    | Unix.Unix_error (error, operation, argument) ->
      Error (System (System_error.IoError
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
    | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn)))
  in
  match lock_path with
  | Error _ as error -> error
  | Ok lock_path ->
    match File_lock_eio.with_durable_lock_observed ~lock_path
        (fun () -> f (Credential_transaction config)) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (System (System_error.IoError (File_lock_eio.durable_lock_error_to_string error)))
    | File_lock_eio.Body_completed { value; release_error } ->
      (match release_error with
       | None -> ()
       | Some error ->
         Log.Auth.error "credential transaction completed but lock release failed: %s"
           (File_lock_eio.durable_lock_error_to_string error));
      Ok value
;;



let credential_exists_in_transaction (Credential_transaction config) agent_name =
  credential_path_exists (credential_file config agent_name)
;;

(** Save agent credential.

    When [cred.id] is present the credential is stored under
    [{uuid}.json] and a redirect stub [{agent_name}.json] is written so
    legacy lookup paths still resolve. *)
let save_credential_in_transaction (Credential_transaction config) (cred : agent_credential) =
  let json = agent_credential_to_yojson cred in
  let json_str = Yojson.Safe.pretty_to_string json in
  let stub_file = credential_file config cred.agent_name in
  let previous_target = load_redirect_target config stub_file in
  Fun.protect ~finally:(fun () -> !credential_cache_invalidator_ref config) (fun () ->
    match cred.id with
    | Some cid ->
      let uuid_file = credential_uuid_file config cid in
      save_private_text_file uuid_file json_str;
      let stub =
        `Assoc [ "redirect_to", `String (Credential_id.to_string cid ^ ".json") ] in
      save_private_text_file stub_file (Yojson.Safe.pretty_to_string stub);
      (match previous_target with
       | Some old_file when old_file <> uuid_file -> remove_file_if_exists old_file
       | _ -> ())
    | None ->
      save_private_text_file stub_file json_str;
      Option.iter remove_file_if_exists previous_target)

;;

let save_credential config cred =
  let saved = with_credential_transaction config (fun transaction ->
    save_credential_in_transaction transaction cred) in
  match saved with
  | Ok () -> ()
  | Error error -> raise (Sys_error (masc_error_to_string error))
;;

(** #10440: write a short-form alias [<alias_name>.json] as a
    redirect stub pointing at the same UUID file as
    [<canonical_name>.json].

    Issue #10440 documented credential file asymmetry: 6/14
    keepers had a short-form [<keeper>.json] (created via some
    other path) and 8/14 had only the long-form
    [keeper-<n>-agent.json]. Callers that look up by
    [agent_name=<keeper>] hit ENOENT for the 8 long-form-only
    keepers, which is the [feedback_keeper-credential-name-drift]
    fail mode. This helper writes the short-form alias once at
    bootstrap so all 14 keepers resolve via a single
    [load_credential] call.

    Idempotent: pre-existing alias with the same redirect target
    is a no-op; a stale alias pointing elsewhere is overwritten so
    operators can recover from manual file edits.

    Returns [Error] if the canonical credential is itself a
    direct (non-redirect) credential, since "alias" semantics
    require both sides to share the same UUID file. *)
let ensure_credential_alias config ~canonical_name ~alias_name : (unit, masc_error) result
  =
  let result = with_credential_transaction config (fun _transaction ->
  if String.equal canonical_name alias_name
  then Ok ()
  else (
    let canonical_file = credential_file config canonical_name in
    if not (file_exists canonical_file)
    then
      Error
        (System
           (System_error.IoError
              (Printf.sprintf
                 "canonical credential not found for alias setup: canonical=%s alias=%s"
                 canonical_name
                 alias_name)))
    else (
      match load_redirect_target config canonical_file with
      | None ->
        Error
          (System
             (System_error.IoError
                (Printf.sprintf
                   "canonical credential %s is not a redirect stub; cannot create alias \
                    %s without a UUID-backed credential"
                   canonical_name
                   alias_name)))
      | Some uuid_file ->
        let uuid_basename = Filename.basename uuid_file in
        let alias_file = credential_file config alias_name in
        let desired_stub = `Assoc [ "redirect_to", `String uuid_basename ] in
        let already_correct =
          match load_redirect_target config alias_file with
          | Some existing when Filename.basename existing = uuid_basename -> true
          | _ -> false
        in
        if already_correct
        then Ok ()
        else (
          try
            ensure_auth_dirs config;
            save_private_text_file alias_file (Yojson.Safe.pretty_to_string desired_stub);
            !credential_cache_invalidator_ref config;
            Ok ()
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Error
              (System
                 (System_error.IoError
                    (Printf.sprintf
                       "Failed to write alias %s -> %s: %s"
                       alias_name
                       canonical_name
                       (Printexc.to_string exn)))))))) in
  Result.join result
;;

let load_raw_token config ~agent_name =
  match read_regular_auth_file (raw_token_file config agent_name) with
  | Error _ -> None
  | Ok raw -> if String.trim raw = "" then None else Some raw
;;

let persist_raw_token config ~agent_name raw_token =
  ensure_auth_dirs config;
  save_private_text_file (raw_token_file config agent_name) raw_token
;;

(* Open nonblocking and validate the descriptor we actually read. Following a
   regular-file symlink is allowed; special-file replacement cannot block. *)
let read_regular_credential_text path =
  run_blocking_io (fun () ->
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let before = Unix.fstat fd in
      if before.Unix.st_kind <> Unix.S_REG then
        raise (Sys_error (Printf.sprintf "credential path is not a regular file: %s" path));
      let content = Buffer.create 256 in
      let chunk = Bytes.create 4096 in
      let rec read () =
        let count = Unix.read fd chunk 0 (Bytes.length chunk) in
        if count > 0 then (Buffer.add_subbytes content chunk 0 count; read ()) in
      read ();
      let after = Unix.fstat fd in
      let named = Unix.stat path in
      if before.Unix.st_dev <> after.Unix.st_dev || before.Unix.st_ino <> after.Unix.st_ino
         || before.Unix.st_size <> after.Unix.st_size || before.Unix.st_mtime <> after.Unix.st_mtime
         || before.Unix.st_ctime <> after.Unix.st_ctime
         || after.Unix.st_dev <> named.Unix.st_dev || after.Unix.st_ino <> named.Unix.st_ino
      then raise (Sys_error (Printf.sprintf "credential changed during verified read: %s" path));
      Buffer.contents content))
;;

(* Revocation admits only the payload's canonical name. Expiry need not decode,
   but an alias must not retire another owner's UUID and leave its raw bearer. *)
let credential_revocation_targets config agent_name =
  let file = credential_file config agent_name in
  let refused detail = Error (System (System_error.ValidationError
      (Printf.sprintf "cannot revoke %s: %s" agent_name detail))) in
  let read_json path =
    try
      Ok (Some (Yojson.Safe.from_string (read_regular_credential_text path)))
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | Yojson.Json_error _ -> refused "credential owner cannot be decoded"
    | Sys_error detail -> Error (System (System_error.IoError detail))
    | Unix.Unix_error (error, operation, argument) ->
      Error (System (System_error.IoError
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
    | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn))) in
  let ( let* ) = Result.bind in
  let require_owner = function
    | None -> Ok ()
    | Some (`Assoc fields) ->
      (match List.assoc_opt "agent_name" fields with
       | Some (`String owner) when String.equal owner agent_name -> Ok ()
       | Some (`String _) -> refused "requested name is an alias, not the canonical owner"
       | _ -> refused "credential owner cannot be decoded")
    | Some _ -> refused "credential owner cannot be decoded" in
  let* named = read_json file in
  let* redirect, payload = match named with
    | Some (`Assoc fields) ->
      (match List.assoc_opt "redirect_to" fields with
       | Some (`String target) ->
         (match redirect_target_file config target with
          | Some path -> let* payload = read_json path in Ok (Some path, payload)
          | None -> refused "invalid redirect target")
       | _ -> Ok (None, named))
    | _ -> Ok (None, named) in
  let* () = require_owner payload in
  (* Keep the embedded ID even when expiry or another unrelated field cannot
     decode. Verify every payload owner before deleting any named/raw path. *)
  let* uuid = match payload with
    | Some (`Assoc fields) ->
      (match List.assoc_opt "id" fields with
       | None | Some `Null -> Ok None
       | Some (`String id) ->
         (match redirect_target_file config (id ^ ".json") with
          | None -> refused "credential UUID is not a store filename"
          | Some path ->
            let* target = read_json path in
            let* () = require_owner target in
            let* () = match target with
              | Some (`Assoc fields) ->
                (match List.assoc_opt "id" fields with
                 | Some (`String target_id) when String.equal id target_id -> Ok ()
                 | _ -> refused "UUID payload does not carry its referenced ID")
              | None -> Ok ()
              | Some _ -> refused "UUID payload cannot be decoded" in
            Ok (Some path))
       | Some _ -> refused "credential UUID cannot be decoded")
    | None -> Ok None
    | Some _ -> refused "credential owner cannot be decoded" in
  Ok (List.sort_uniq String.compare (List.filter_map Fun.id [redirect; uuid]))

;;

(** Delete using the caller's admitted workspace. The public wrapper and
    multi-effect transactions share this implementation. *)
let delete_credential_in_transaction (Credential_transaction config) agent_name =
  let ( let* ) = Result.bind in
  let* targets = credential_revocation_targets config agent_name in
  try
    Fun.protect ~finally:(fun () -> !credential_cache_invalidator_ref config)
      (fun () ->
        let file = credential_file config agent_name in
        let raw_token = raw_token_file config agent_name in
        remove_file_if_exists file;
        remove_file_if_exists raw_token;
        List.iter remove_file_if_exists targets;
        Ok ())
  with
  | Sys_error detail -> Error (System (System_error.IoError detail))
  | Unix.Unix_error (error, operation, argument) ->
    Error (System (System_error.IoError
      (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
  | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn)))
;;

(** Delete agent credential *)
let delete_credential config agent_name =
  let deleted = with_credential_transaction config (fun transaction ->
    delete_credential_in_transaction transaction agent_name) in
  match Result.join deleted with
  | Ok () -> ()
  | Error error -> raise (Sys_error (masc_error_to_string error))
;;

(** List all credentials.

    Only the exact named owner publishes authentication authority. UUID
    payloads and aliases may remain after failed cleanup or publication;
    they cannot replace the current named record in this listing. *)
let list_credentials config : agent_credential list =
  let dir = agents_dir config in
  if file_exists dir
  then
    read_dir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
      let name = Filename.chop_suffix f ".json" in
      match load_credential config name with
      | Some credential when String.equal name (Common.safe_filename credential.agent_name) -> Some credential
      | Some _ | None -> None)
    |> List.fold_left
         (fun acc cred ->
            if List.exists (fun c -> c.agent_name = cred.agent_name) acc
            then acc
            else cred :: acc)
         []
    |> List.rev
  else []
;;



let read_owned_credential_text config path =
  let ( let* ) = Result.bind in
  (* Prune holds the shared publisher transaction: a FIFO must never wait for
     a writer here. This existing reader opens nonblocking, verifies the real
     FD and no-follow path identity, closes it, and propagates cancellation. *)
  (* The transaction already canonicalizes its store root. Preserve relative
     base paths and directory aliases without following the JSON leaf. All
     callers supply discovered or validated direct children of this store. *)
  let* ownership_root =
    credential_read_result (fun () ->
      run_blocking_io (fun () -> Unix.realpath (agents_dir config)))
  in
  let owned_path = Filename.concat ownership_root (Filename.basename path) in
  match Fs_compat.load_owned_regular_file ~ownership_root owned_path with
    | Ok (Some content) -> Ok content
    | Ok None ->
        Error (System (System_error.IoError
          (Printf.sprintf "credential disappeared before verified read: %s" path)))
    | Error error ->
        Error (System (System_error.IoError
          (Fs_compat.owned_regular_file_read_error_to_string error)))

;;

type credential_listing_error =
  | Invalid_credential_expiry of
      { agent_name : string; role : agent_role; timestamp : string }
  | Unreadable_credential of { path : string; reason : string }

let credential_listing_error_to_string = function
  | Invalid_credential_expiry { agent_name; timestamp; _ } ->
    Printf.sprintf "invalid credential expiry for %s: %S" agent_name timestamp
  | Unreadable_credential { path; reason } ->
    Printf.sprintf "credential %s is unreadable: %s" path reason
;;

let list_credential_results config =
  let unreadable path reason = Error (Unreadable_credential { path; reason }) in
  let decode path json =
    match agent_credential_of_yojson json with
    | Ok credential -> Ok credential
    | Error reason ->
      (* Parse the remaining fields only to identify the rejected record for
         diagnostics. The placeholder never escapes as a valid credential. *)
      (match json with
       | `Assoc fields ->
         (match List.assoc_opt "expires_at" fields with
          | Some (`String timestamp) ->
            (match Credential_expiry.parse (Some timestamp) with
             | Ok _ -> unreadable path reason
             | Error (Credential_expiry.Invalid_timestamp _) ->
               let without_expiry = `Assoc (List.map (fun (key, value) ->
                 key, if String.equal key "expires_at" then `Null else value) fields) in
               (match agent_credential_of_yojson without_expiry with
                | Error _ -> unreadable path reason
                | Ok credential -> Error (Invalid_credential_expiry
                    { agent_name = credential.agent_name; role = credential.role; timestamp })))
          | Some _ | None -> unreadable path reason)
       | _ -> unreadable path reason)
  in
  let read_json path =
    match read_owned_credential_text config path with
    | Error error -> unreadable path (masc_error_to_string error)
    | Ok content ->
    try Ok (Yojson.Safe.from_string content) with
    | Sys_error reason | Yojson.Json_error reason -> unreadable path reason
    | Unix.Unix_error (error, operation, argument) ->
      unreadable path (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
    | Eio.Io _ as exn -> unreadable path (Printexc.to_string exn)
  in
  let read path =
    let ( let* ) = Result.bind in
    let* json = read_json path in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "redirect_to" fields with
       | Some (`String target) ->
         (match redirect_target_file config target with
          | None -> unreadable path "invalid redirect target"
          | Some target_path ->
            let* target_json = read_json target_path in
            decode target_path target_json)
       | _ -> decode path json)
    | _ -> decode path json
  in
  let dir = agents_dir config in
  let entries =
    try
      let present =
        try
          let _ = run_blocking_io (fun () -> Unix.lstat dir) in true
        with Unix.Unix_error (Unix.ENOENT, _, _) -> false in
      if not present then []
      else read_dir dir |> Array.to_list
        |> List.filter (fun file -> Filename.check_suffix file ".json")
        |> List.sort String.compare
        |> List.map (fun file -> read (Filename.concat dir file))
    with
    | Sys_error reason -> [ unreadable dir reason ]
    | Unix.Unix_error (error, operation, argument) ->
      [ unreadable dir (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error)) ]
    | Eio.Io _ as exn -> [ unreadable dir (Printexc.to_string exn) ]
  in
  List.sort_uniq compare entries
;;

(* Current-store discovery keeps decode failures distinct from I/O failure: the former
   preserve their file, the latter abort the whole plan before mutation. These
   helpers are private to the Auth library and require its current admission. *)
type stored_credential =
  | Stored_credential of agent_credential
  | Stored_redirect of string
  | Unresolved_credential



(* File-backed bearers must survive HTTP header construction and extraction
   without changing the bytes that were hashed. Direct token APIs retain
   their separate opaque-token contract. *)
let validate_file_backed_bearer raw_token =
  if raw_token = "" || String.exists (fun c -> Char.code c <= 0x20 || Char.code c = 0x7f) raw_token
  then Error (Auth (Auth_error.InvalidToken
    "File-backed bearer must not contain whitespace or ASCII control bytes"))
  else Ok ()
;;

let read_regular_credential_file path =
  credential_read_result (fun () -> read_regular_credential_text path)
;;

type credential_leaf_policy = Owned_regular_only | Follow_regular_symlink

let read_stored_credential ?(leaf_policy = Owned_regular_only) config name path =
  let ( let* ) = Result.bind in
  let* content = match leaf_policy with
    | Owned_regular_only -> read_owned_credential_text config path
    | Follow_regular_symlink -> read_regular_credential_file path in
  match Yojson.Safe.from_string content with
  | exception Yojson.Json_error _ -> Ok Unresolved_credential
  | json ->
    let redirect = match json with
      | `Assoc fields -> List.assoc_opt "redirect_to" fields
      | _ -> None in
    (match redirect with
     | Some (`String target) ->
       (match redirect_target_file config target with
        | Some path -> Ok (Stored_redirect path)
        | None -> Ok Unresolved_credential)
     | _ ->
       match credential_of_json name json with
       | Some credential -> Ok (Stored_credential credential)
       | None -> Ok Unresolved_credential)
;;

let resolve_stored_credential ?(leaf_policy = Owned_regular_only) config name = function
  | Stored_credential credential -> Ok (Some credential)
  | Unresolved_credential -> Ok None
  | Stored_redirect target ->
    let ( let* ) = Result.bind in
    let* present = credential_path_exists target in
    if not present then Ok None
    else
      let* stored = read_stored_credential ~leaf_policy config name target in
      (match stored with
       | Stored_credential credential -> Ok (Some credential)
       | Stored_redirect _ | Unresolved_credential -> Ok None)
;;

type credential_prune_retirement =
  { retiring_agent_name : string; uuid_target : string option; alias_names : string list }

type credential_prune_snapshot =
  { credentials : (agent_credential * credential_prune_retirement) list
  ; orphaned_redirects : credential_prune_retirement list }

let credential_prune_authority config name stored (credential : agent_credential) =
  let ( let* ) = Result.bind in
  let refused detail = Error (System (System_error.ValidationError
      (Printf.sprintf "cannot prune %s: %s" name detail))) in
  let uuid_path id =
    match redirect_target_file config (Credential_id.to_string id ^ ".json") with
    | Some target -> Ok target
    | None -> refused "credential UUID is not a store filename" in
  match stored, credential.id with
  | Stored_credential _, None -> Ok { retiring_agent_name = name; uuid_target = None; alias_names = [] }
  | Stored_redirect target, Some id ->
    let* uuid = uuid_path id in
    if String.equal target uuid
    then Ok { retiring_agent_name = name; uuid_target = Some target; alias_names = [] }
    else refused "redirect target disagrees with the credential UUID"
  | Stored_credential _, Some id ->
    let* target = uuid_path id in
    let* present = credential_path_exists target in
    if not present then Ok { retiring_agent_name = name; uuid_target = None; alias_names = [] }
    else
      let* target_record = read_stored_credential config name target in
      (match target_record with
       | Stored_credential current when current = credential ->
         Ok { retiring_agent_name = name; uuid_target = Some target; alias_names = [] }
       | Stored_credential _ | Stored_redirect _ | Unresolved_credential ->
         refused "embedded UUID resolves to another credential")
  | Stored_redirect _, None -> refused "redirected credential has no UUID binding"
  | Unresolved_credential, (Some _ | None) -> refused "credential cannot be resolved"
;;

(* Existing UUID payloads must belong to the exact current credential; a
   redirect must name its embedded UUID. Missing direct UUID payloads are
   distinguishable from an owned existing target. *)
let credential_owned_uuid_target ?(leaf_policy = Owned_regular_only) config name stored (credential : agent_credential) =
  let ( let* ) = Result.bind in
  let refused detail = Error (System (System_error.ValidationError
      (Printf.sprintf "credential storage authority for %s: %s" name detail))) in
  let uuid_path id =
    let spelling = Credential_id.to_string id in
    if spelling = "" || not (String.for_all
        (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) spelling)
    then refused "credential UUID must use canonical lowercase ASCII letters, digits and hyphens"
    else match redirect_target_file config (spelling ^ ".json") with
    | Some target when String.equal target (credential_file config name) ->
      refused "UUID payload and named credential would share a path"
    | Some target -> Ok target
    | None -> refused "credential UUID is not a store filename" in
  match stored, credential.id with
  | Stored_credential _, None -> Ok None
  | Stored_redirect target, Some id ->
    let* uuid = uuid_path id in
    if String.equal target uuid
    then Ok (Some target)
    else refused "redirect target disagrees with the credential UUID"
  | Stored_credential _, Some id ->
    let* target = uuid_path id in
    let* present = credential_path_exists target in
    if not present then Ok None
    else
      let* target_record = read_stored_credential ~leaf_policy config name target in
      (match target_record with
       | Stored_credential current
         when String.equal current.agent_name credential.agent_name
           && Option.equal Credential_id.equal current.id credential.id
           && Option.equal Agent_id.equal current.agent_id credential.agent_id ->
         (* The named direct record may still be old after a UUID payload
            was published but replacing its stub failed. It is the same
            owner, so a later admitted publisher can finish or replace it. *)
         Ok (Some target)
       | Stored_credential _ | Stored_redirect _ | Unresolved_credential ->
         refused "embedded UUID resolves to another credential")
  | Stored_redirect _, None -> refused "redirected credential has no UUID binding"
  | Unresolved_credential, (Some _ | None) -> refused "credential cannot be resolved"
;;

(* A file-backed publisher must distinguish true absence from an unreadable
   name or UUID binding before it authorizes replacement or recreation. *)
let current_credential_in_transaction (Credential_transaction config) name =
  let ( let* ) = Result.bind in
  let refused detail = Error (System (System_error.ValidationError
      (Printf.sprintf "credential storage authority for %s: %s" name detail))) in
  let* present = credential_path_exists (credential_file config name) in
  if not present then Ok None
  else
    let* stored = read_stored_credential ~leaf_policy:Follow_regular_symlink config name (credential_file config name) in
    let* resolved = resolve_stored_credential ~leaf_policy:Follow_regular_symlink config name stored in
    match resolved with
    | None -> refused "current credential cannot be resolved"
    | Some credential when not (String.equal credential.agent_name name) ->
      refused "current credential belongs to another name"
    | Some credential ->
      let* _owned_uuid = credential_owned_uuid_target ~leaf_policy:Follow_regular_symlink config name stored credential in
      Ok (Some credential)
;;

let raw_token_in_transaction (Credential_transaction config) name =
  let ( let* ) = Result.bind in
  let path = raw_token_file config name in
  let* present = credential_path_exists path in
  if not present then Ok None
  else
    let* raw = read_regular_auth_file path in
    (* Empty readable material can be replaced. An opaque bearer that is not
       blank retains its exact bytes, matching the supplied-token contract. *)
    if String.trim raw = "" then Ok None else Ok (Some raw)
;;

let credential_auth_config_result config =
  try credential_read_result (fun () -> load_auth_config config) with
  | Auth_config_error { file; reason } ->
    Error (System (System_error.ValidationError
      (Printf.sprintf "auth configuration %s: %s" file reason)))
;;

let require_live_credential ~now (credential : agent_credential) =
  match Credential_expiry.parse credential.expires_at with
  | Error (Credential_expiry.Invalid_timestamp stamp) ->
    Error (Auth (Auth_error.InvalidToken
      (Printf.sprintf "Invalid credential expiry for %s: %S" credential.agent_name stamp)))
  | Ok expiry ->
    if Credential_expiry.is_expired ~now expiry
    then Error (Auth (Auth_error.TokenExpired credential.agent_name))
    else Ok credential
;;

type credential_publication = Published | Not_published | Publication_unreadable of masc_error

type credential_publication_failure =
  { error : masc_error
  ; raw_token : credential_publication
  ; credential : credential_publication }

let credential_publication_failure_to_string failure =
  let render = function
    | Published -> "published"
    | Not_published -> "not published"
    | Publication_unreadable error -> "unreadable: " ^ masc_error_to_string error in
  Printf.sprintf "%s (raw token: %s; credential: %s)"
    (masc_error_to_string failure.error) (render failure.raw_token) (render failure.credential)
;;

let observe_credential_publication config (expected : agent_credential) =
  let observe f = match f () with
    | Ok true -> Published
    | Ok false -> Not_published
    | Error error -> Publication_unreadable error in
  let ( let* ) = Result.bind in
  let raw_token = observe (fun () ->
    let path = raw_token_file config expected.agent_name in
    let* present = credential_path_exists path in
    if not present then Ok false
    else
      let* raw = read_regular_auth_file path in
      Ok (String.equal (sha256_hash raw) expected.token)) in
  let credential = observe (fun () ->
    let path = credential_file config expected.agent_name in
    let* present = credential_path_exists path in
    if not present then Ok false
    else
      let* stored = read_stored_credential ~leaf_policy:Follow_regular_symlink config expected.agent_name path in
      let* current = resolve_stored_credential ~leaf_policy:Follow_regular_symlink config expected.agent_name stored in
      Ok (current = Some expected)) in
  raw_token, credential
;;

let publish_file_backed_credential_in_transaction
    ((Credential_transaction config) as transaction) credential ~raw_token =
  let ( let* ) = Result.bind in
  let saved_bytes path =
    let* present = credential_path_exists path in
    if present then read_regular_credential_file path |> Result.map Option.some
    else Ok None in
  let raw_path = raw_token_file config credential.agent_name in
  let named_path = credential_file config credential.agent_name in
  let failure error =
    let raw_token, credential = observe_credential_publication config credential in
    Error { error; raw_token; credential } in
  Fun.protect ~finally:(fun () -> !credential_cache_invalidator_ref config) (fun () ->
    match (let* raw = saved_bytes raw_path in
           let* named = saved_bytes named_path in Ok (raw, named)) with
    | Error error -> failure error
    | Ok (previous_raw, previous_named) ->
      match credential_read_result (fun () ->
        persist_raw_token config ~agent_name:credential.agent_name raw_token;
        save_credential_in_transaction transaction credential) with
      | Ok () -> Ok ()
      | Error error ->
        let _, published = observe_credential_publication config credential in
        (* A redirect can keep identical bytes while its UUID payload advances.
           Never restore the old raw token when the new credential is current. *)
        match published, saved_bytes named_path with
        | Not_published, Ok current_named when current_named = previous_named ->
          (match credential_read_result (fun () ->
             match previous_raw with
             | Some raw -> save_private_text_file raw_path raw
             | None -> remove_file_if_exists raw_path) with
           | Ok () -> failure error
           | Error restore_error -> failure (System (System_error.IoError
               (Printf.sprintf "credential publication failed: %s; raw token restoration failed: %s"
                  (masc_error_to_string error) (masc_error_to_string restore_error)))))
        | _, Error observation_error -> failure (System (System_error.IoError
            (Printf.sprintf "credential publication failed: %s; named publication is unreadable: %s"
               (masc_error_to_string error) (masc_error_to_string observation_error))))
        | Published, Ok _ | Publication_unreadable _, Ok _ | Not_published, Ok _ -> failure error)
;;

let file_backed_publication_error failure =
  let detail = credential_publication_failure_to_string failure in
  Log.Auth.error "file-backed credential publication failed: %s" detail;
  System (System_error.IoError detail)
;;

type credential_store_snapshot =
  { current_credentials : (stored_credential * agent_credential) list
  ; orphaned_names : string list
  ; aliases : (string * string * agent_credential) list }

let credential_store_snapshot_in_transaction ?(leaf_policy = Owned_regular_only) (Credential_transaction config) =
  let ( let* ) = Result.bind in
  let* files = credential_read_result (fun () -> read_dir (agents_dir config)) in
  let files = Array.to_list files |> List.filter (fun file -> Filename.check_suffix file ".json")
      |> List.sort String.compare in
  let rec discover names orphans aliases = function
    | [] -> Ok (List.sort_uniq String.compare names, List.sort_uniq String.compare orphans, aliases)
    | file :: rest ->
      let name = Filename.chop_suffix file ".json" in
      let path = Filename.concat (agents_dir config) file in
      let* present = credential_path_exists path in
      if not present then discover names orphans aliases rest
      else
        let* stored = read_stored_credential ~leaf_policy config name path in
        (match stored with
         | Unresolved_credential -> discover names orphans aliases rest
         | Stored_credential credential -> discover (credential.agent_name :: names) orphans aliases rest
         | Stored_redirect target ->
           let* present = credential_path_exists target in
           if not present then discover names (name :: orphans) aliases rest
           else
             let* resolved = resolve_stored_credential ~leaf_policy config name stored in
             (match resolved with
              | None -> discover names orphans aliases rest
              | Some credential -> discover (credential.agent_name :: names) orphans
                  ((name, target, credential) :: aliases) rest))
  in
  let* names, orphans, aliases = discover [] [] [] files in
  let rec current_credentials acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest ->
      let* present = credential_path_exists (credential_file config name) in
      if not present then current_credentials acc rest
      else
        let* stored = read_stored_credential ~leaf_policy config name (credential_file config name) in
        let* resolved = resolve_stored_credential ~leaf_policy config name stored in
        (match resolved with
         | Some credential when String.equal credential.agent_name name ->
           current_credentials ((stored, credential) :: acc) rest
         | Some _ | None -> current_credentials acc rest)
  in
  let* credentials = current_credentials [] names in
  (* Check each named stub again, through its canonical filename. A raw UUID
     entry or an unrelated owner's alias cannot authorize a name deletion. *)
  let rec current_orphans acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest ->
      let* present = credential_path_exists (credential_file config name) in
      if not present then current_orphans acc rest
      else
        let* stored = read_stored_credential ~leaf_policy config name (credential_file config name) in
        (match stored with
         | Stored_redirect target ->
           let* present = credential_path_exists target in
           if present then current_orphans acc rest
           else current_orphans (name :: acc) rest
         | Stored_credential _ | Unresolved_credential -> current_orphans acc rest)
  in
  let* orphaned_names = current_orphans [] orphans in
  Ok { current_credentials = credentials; orphaned_names; aliases }
;;

(* Prune adds deletion authority only after current-store discovery. Rotation
   uses the same current records without inheriting a deletion manifest. *)
let credential_prune_snapshot_in_transaction ((Credential_transaction config) as transaction) =
  let ( let* ) = Result.bind in
  let* snapshot = credential_store_snapshot_in_transaction transaction in
  let rec validate acc = function
    | [] -> Ok (List.rev acc)
    | (stored, credential) :: rest ->
      let* authority = credential_prune_authority config credential.agent_name stored credential in
      let alias_names = List.filter_map (fun (alias, target, resolved) ->
        if not (String.equal (credential_file config alias) (credential_file config credential.agent_name))
           && resolved = credential
           && authority.uuid_target = Some target
        then Some alias else None) snapshot.aliases
        |> List.sort_uniq String.compare in
      let authority = { authority with alias_names } in
      validate ((credential, authority) :: acc) rest in
  let* credentials = validate [] snapshot.current_credentials in
  let orphaned_redirects = List.map (fun agent_name -> { retiring_agent_name = agent_name; uuid_target = None; alias_names = [] })
      snapshot.orphaned_names in
  Ok { credentials; orphaned_redirects }
;;

(* The plan carries only paths whose ownership was validated during discovery.
   Do not re-interpret a record's embedded id with the explicit revoke primitive. *)
let unlink_prune_path path =
  try run_blocking_io (fun () -> Unix.unlink path) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let retire_prune_credential_in_transaction (Credential_transaction config) retirement =
  try
    Fun.protect ~finally:(fun () -> !credential_cache_invalidator_ref config)
      (fun () ->
        (* Keep canonical discovery authority until every dependent path is
           retired. A failed sidecar/alias/UUID unlink must remain retryable. *)
        unlink_prune_path (raw_token_file config retirement.retiring_agent_name);
        List.iter (fun alias -> unlink_prune_path (credential_file config alias))
          retirement.alias_names;
        Option.iter unlink_prune_path retirement.uuid_target;
        unlink_prune_path (credential_file config retirement.retiring_agent_name);
        Ok ())
  with
  | Sys_error detail -> Error (System (System_error.IoError detail))
  | Unix.Unix_error (error, operation, argument) ->
    Error (System (System_error.IoError
      (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
  | Eio.Io _ as exn -> Error (System (System_error.IoError (Printexc.to_string exn)))
;;

(* ============================================ *)
(* Credential token-hash index cache             *)
(* ============================================ *)

(** In-memory cache of [list_credentials] indexed by token hash, used
    by [Auth_credential_token.find_credential_by_token].  Without it,
    every auth-gated request re-reads the credential directory
    ([read_dir] + N x JSON parse) through [Eio_guard.run_in_systhread]
    roundtrips.  Live measurement (2026-05-26 fleet, 6 credentials,
    cold filesystem): 9.9s for the first request, 0.21-0.45s warm.
    Cached lookup is an O(1) hashtable read under a single mutex
    acquire.

    Cache semantics:
    - TTL bound (60s) so external in-place edits eventually surface
      without restarting the server.
    - Explicit invalidation from [save_credential] / [delete_credential]
      so writes through this module are visible immediately.
    - Token hash -> [agent_credential list] (not single value) so the
      #9786 ambiguous-lookup warn path still sees all matches.  The
      list is built in [list_credentials] order so first-match
      semantics stay identical to the pre-cache implementation. *)

type credential_index_cache_entry = {
  loaded_at : float;
  by_token : (string, agent_credential list) Hashtbl.t;
}

let credential_index_cache_ttl_sec = 60.0

(* Plain [Stdlib.Mutex], not [Eio.Mutex]: [save_credential] is also
   called from non-Eio call sites (CLI bootstrap, tests outside
   [with_eio_runtime]).  [Eio_guard.run_in_systhread] already falls
   back to direct invocation when Eio is not ready, so the rest of
   the credential-base I/O works in both contexts — the cache mutex
   must keep that property.  Stdlib.Mutex is cooperative under Eio
   because the critical section is short (hashtable lookup or
   replace) and never blocks on I/O. *)
let credential_index_cache_mu : Mutex.t = Mutex.create ()

let with_credential_index_cache_lock f =
  Mutex.lock credential_index_cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock credential_index_cache_mu) f

let credential_index_cache
  : (string, credential_index_cache_entry) Hashtbl.t
  =
  Hashtbl.create 4

let build_token_index (creds : agent_credential list)
  : (string, agent_credential list) Hashtbl.t
  =
  let idx = Hashtbl.create (max 8 (List.length creds)) in
  List.iter
    (fun (cred : agent_credential) ->
       let prev =
         Hashtbl.find_opt idx cred.token |> Option.value ~default:[]
       in
       Hashtbl.replace idx cred.token (cred :: prev))
    creds;
  (* Reverse each bucket so callers see [list_credentials] order
     (first-match semantics match the legacy [List.filter] flow). *)
  Hashtbl.filter_map_inplace
    (fun _ entries -> Some (List.rev entries))
    idx;
  idx
;;

let invalidate_credential_index_cache config =
  let key = agents_dir config in
  with_credential_index_cache_lock (fun () ->
    Hashtbl.remove credential_index_cache key)
;;

let credential_token_index config
  : ((string, agent_credential list) Hashtbl.t, masc_error) result
  =
  let key = agents_dir config in
  let now = Time_compat.now () in
  (* The cache mutex covers memory only. A cold read publishes under the
     credential transaction, so it cannot restore an old index after a
     writer invalidated it. Cache hits keep the short in-memory path. *)
  let cached =
    with_credential_index_cache_lock (fun () ->
      match Hashtbl.find_opt credential_index_cache key with
      | Some entry
        when now -. entry.loaded_at < credential_index_cache_ttl_sec ->
        Some entry.by_token
      | _ -> None)
  in
  match cached with
  | Some by_token ->
    Auth_metric_store.inc_counter
      Auth_metric_store.metric_auth_credential_index_cache_hits
      ();
    Ok by_token
  | None ->
    Auth_metric_store.inc_counter
      Auth_metric_store.metric_auth_credential_index_cache_misses
      ();
    with_credential_transaction config (fun _transaction ->
       let creds = list_credentials config in
       let by_token = build_token_index creds in
       with_credential_index_cache_lock (fun () ->
         Hashtbl.replace credential_index_cache key { loaded_at = now; by_token });
       by_token)
;;

(* Wire the forward-declared invalidator so [save_credential] and
   [delete_credential] can drop their cache entry without forming a
   forward reference to the cache helpers above. *)
let () =
  credential_cache_invalidator_ref := invalidate_credential_index_cache
;;

(** #9786: detect credentials sharing the same bearer token.

    The 2026-04-23 audit found [external MCP clients] and [admin]
    tokens being presented for [keeper-example-keeper-agent] /
    [example-keeper-sage-heron] requests — symptom of multiple
    credentials hashing to the same token, or a single MCP
    client connection being reused across agent identities.

    [find_credential_by_token]'s [List.find_opt] returns the FIRST
    matching credential, so when two credentials share a token the
    second agent's auth silently routes to the first agent's
    identity — which is exactly the [bearer token belongs to X]
    rejection observed in #9786 once the requested name does not
    match the routed credential's owner.

    This audit walks the credential store and returns groups of
    [(token_hash_prefix, agent_names)] where [List.length
    agent_names >= 2].  Empty list means every credential's token
    hash is unique. *)

(** #10304: indexed credential view used by both
    {!audit_token_uniqueness} (detection) and {!rotate_shared_tokens}
    (prevention).  Returns [(token_hash, credentials)] so rotation
    can preserve credential IDs / roles while minting fresh bearer
    material. *)
let group_credentials_by_token config : (string * agent_credential list) list =
  let creds = list_credentials config in
  let by_token : (string, agent_credential list) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (cred : agent_credential) ->
       let prev = Hashtbl.find_opt by_token cred.token |> Option.value ~default:[] in
       Hashtbl.replace by_token cred.token (cred :: prev))
    creds;
  Hashtbl.fold (fun token_hash entries acc -> (token_hash, entries) :: acc) by_token []
;;

let token_hash_prefix_of token_hash =
  if String.length token_hash >= 12 then String.sub token_hash 0 12 else token_hash
;;

let audit_token_uniqueness config : (string * string list) list =
  group_credentials_by_token config
  |> List.filter_map (fun (token_hash, entries) ->
    match entries with
    | [] | [ _ ] -> None
    | xs ->
      let names =
        List.map (fun (cred : agent_credential) -> cred.agent_name) xs
        |> List.sort String.compare
      in
      Some (token_hash_prefix_of token_hash, names))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

(* #10304: rotation_outcome type + rotate_shared_tokens defined
   later in the file (after save_raw_token_credential).  This block
   intentionally left as a forward-pointer comment so the audit and
   rotation surfaces are co-located in the API but the
   implementation respects definition order. *)
