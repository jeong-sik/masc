module SMap = Set_util.StringMap
module SSet = Set_util.StringSet

type session =
  { session_id : string
  ; protocol_version : string
  ; tool_profile : Server_mcp_transport_http_types.tool_profile
  ; owner : Server_transport_admission.identity
  ; started_at : float
  ; transport_context : Otel_dispatch_hook.transport_context option
  }

type tombstone =
  { session_id : string
  ; deleted_at : float
  }

type session_state =
  | Active of session
  | Deleted of tombstone

type validation_error =
  | Empty_session_id
  | Empty_protocol_version
  | Unsupported_protocol_version of string
  | Empty_owner_agent_name
  | Non_finite_started_at
  | Non_finite_deleted_at

type schema_error =
  | Expected_object of
      { context : string
      }
  | Missing_field of
      { context : string
      ; field : string
      }
  | Duplicate_field of
      { context : string
      ; field : string
      }
  | Unexpected_field of
      { context : string
      ; field : string
      }
  | Invalid_field of
      { context : string
      ; field : string
      ; expected : string
      }
  | Unsupported_schema_version of int
  | Unsupported_state_kind of string
  | Unsupported_tool_profile of string
  | Unsupported_owner_role of string
  | Invalid_session of validation_error
  | Invalid_tombstone of validation_error

type restore_failure =
  | Unexpected_store_entry of
      { entry_name : string
      }
  | Store_entry_not_regular_file of
      { entry_name : string
      }
  | Store_entry_unreadable of
      { path : string
      ; message : string
      }
  | Store_entry_json_invalid of
      { path : string
      ; message : string
      }
  | Store_entry_schema_invalid of
      { path : string
      ; error : schema_error
      }
  | Store_entry_filename_mismatch of
      { path : string
      ; expected_name : string
      ; actual_name : string
      ; session_id : string
      }
  | Duplicate_session_id of
      { session_id : string
      ; path : string
      }
  | Store_temporary_quarantine_failed of
      { path : string
      ; recovery_dir : string
      ; message : string
      }

type open_stage =
  | Create_store_directory
  | Resolve_store_path
  | Validate_store_directory
  | Open_lifetime_lock
  | Acquire_lifetime_lock
  | Validate_lifetime_lock
  | Release_lifetime_lock_after_failure

type open_error =
  | Invalid_base_path
  | Store_locked of
      { lock_path : string
      }
  | Open_filesystem_error of
      { stage : open_stage
      ; path : string
      ; message : string
      }
  | Restore_failed of restore_failure
  | Restore_and_lock_release_failed of
      { restore_failure : restore_failure
      ; lock_path : string
      ; release_message : string
      }

exception Lifetime_lock_release_failed of
  { lock_path : string
  ; message : string
  }

type not_committed_failure =
  { path : string
  ; stage : Fs_compat.Atomic_write.not_committed_stage
  ; message : string
  ; cleanup : Fs_compat.Atomic_write.temporary_cleanup
  }

type durability_unknown_failure =
  { path : string
  ; stage : Fs_compat.Atomic_write.uncertain_commit_stage
  ; message : string
  ; cleanup : Fs_compat.Atomic_write.temporary_cleanup
  }

type mutation_operation =
  | Initialize_session
  | Delete_session
  | Repair_session

type indeterminate_cause =
  | Atomic_commit_unknown of durability_unknown_failure
  | Retry_not_committed of not_committed_failure
  | Recovery_cleanup_failed of
      { temporary_path : string
      ; message : string
      }
  | Unexpected_mutation_failure of
      { message : string
      }

type persistence_indeterminate =
  { session_id : string
  ; operation : mutation_operation
  ; cause : indeterminate_cause
  }

type mutation_error =
  | Store_closed
  | Invalid_session_record of validation_error
  | Invalid_delete_request of validation_error
  | Session_already_active of string
  | Session_already_deleted of string
  | Session_unknown of string
  | Session_filename_collision of
      { session_id : string
      ; conflicting_session_id : string
      }
  | Session_lane_unavailable of
      { session_id : string
      ; message : string
      }
  | Persistence_not_committed of not_committed_failure
  | Persistence_indeterminate of persistence_indeterminate

type delete_result =
  | Deleted_now
  | Already_deleted of tombstone

type repair_result =
  | Repaired of session_state
  | Already_stable of session_state

type lookup =
  | Stable_state of session_state
  | Pending_state of
      { intended : session_state
      ; indeterminate : persistence_indeterminate
      }

type snapshot_entry =
  | Stable of session_state
  | Durability_pending of
      { intended : session_state
      ; indeterminate : persistence_indeterminate
      ; recovery_paths : SSet.t
      }

type snapshot = snapshot_entry SMap.t

type session_lane =
  { storage_key : string
  ; mutex : Eio.Mutex.t
  }

type t =
  { base_path : string
  ; store_dir : string
  ; recovery_dir : string
  ; snapshot : snapshot Atomic.t
  ; lanes : session_lane SMap.t Atomic.t
  ; closed : bool Atomic.t
  ; active_mutations : int Atomic.t
  ; mutations_drained : unit Eio.Promise.t
  ; resolve_mutations_drained : unit Eio.Promise.u
  }

let schema_version = 1
let store_directory_name = "mcp_transport_sessions"
let recovery_directory_name = "mcp_transport_session_recovery"
let lifetime_lock_name = "mcp_transport_sessions.lock"
let session_file_suffix = ".json"
let private_directory_permissions = 0o700
let private_file_permissions = 0o600

(* POSIX record locks are process-associated, so a second [F_TLOCK] in the
   same process can coalesce with the first instead of reporting contention.
   This immutable CAS set closes that in-process multi-writer gap; the OS lock
   remains the cross-process authority. *)
let open_lock_paths : SSet.t Atomic.t = Atomic.make SSet.empty

let rec reserve_process_lock_path lock_path =
  let current = Atomic.get open_lock_paths in
  if SSet.mem lock_path current
  then false
  else if Atomic.compare_and_set open_lock_paths current (SSet.add lock_path current)
  then true
  else reserve_process_lock_path lock_path

let rec release_process_lock_path lock_path =
  let current = Atomic.get open_lock_paths in
  if not (SSet.mem lock_path current)
  then ()
  else if Atomic.compare_and_set open_lock_paths current (SSet.remove lock_path current)
  then ()
  else release_process_lock_path lock_path

let validation_error_to_string = function
  | Empty_session_id -> "session_id must be a non-empty string"
  | Empty_protocol_version -> "protocol_version must be a non-empty string"
  | Unsupported_protocol_version version ->
    Printf.sprintf "unsupported MCP protocol version %S" version
  | Empty_owner_agent_name -> "owner.agent_name must be a non-empty string"
  | Non_finite_started_at -> "started_at must be finite"
  | Non_finite_deleted_at -> "deleted_at must be finite"

let schema_error_to_string = function
  | Expected_object { context } -> Printf.sprintf "%s must be a JSON object" context
  | Missing_field { context; field } ->
    Printf.sprintf "%s is missing required field %S" context field
  | Duplicate_field { context; field } ->
    Printf.sprintf "%s contains duplicate field %S" context field
  | Unexpected_field { context; field } ->
    Printf.sprintf "%s contains unsupported field %S" context field
  | Invalid_field { context; field; expected } ->
    Printf.sprintf "%s.%s must be %s" context field expected
  | Unsupported_schema_version version ->
    Printf.sprintf "unsupported session-store schema version %d" version
  | Unsupported_state_kind kind ->
    Printf.sprintf "unsupported session state kind %S" kind
  | Unsupported_tool_profile profile ->
    Printf.sprintf "unsupported MCP tool profile %S" profile
  | Unsupported_owner_role role ->
    Printf.sprintf "unsupported session owner role %S" role
  | Invalid_session error -> validation_error_to_string error
  | Invalid_tombstone error -> validation_error_to_string error

let restore_failure_to_string = function
  | Unexpected_store_entry { entry_name } ->
    Printf.sprintf "unexpected entry %S in MCP transport session store" entry_name
  | Store_entry_not_regular_file { entry_name } ->
    Printf.sprintf "MCP transport session entry %S is not a regular file" entry_name
  | Store_entry_unreadable { path; message } ->
    Printf.sprintf "cannot read MCP transport session entry %s: %s" path message
  | Store_entry_json_invalid { path; message } ->
    Printf.sprintf "invalid JSON in MCP transport session entry %s: %s" path message
  | Store_entry_schema_invalid { path; error } ->
    Printf.sprintf
      "invalid MCP transport session entry %s: %s"
      path
      (schema_error_to_string error)
  | Store_entry_filename_mismatch
      { path; expected_name; actual_name; session_id } ->
    Printf.sprintf
      "MCP transport session entry %s contains session %S but filename is %S (expected %S)"
      path
      session_id
      actual_name
      expected_name
  | Duplicate_session_id { session_id; path } ->
    Printf.sprintf "duplicate MCP transport session %S restored from %s" session_id path
  | Store_temporary_quarantine_failed { path; recovery_dir; message } ->
    Printf.sprintf
      "cannot quarantine MCP transport session temporary %s into %s: %s"
      path recovery_dir message

let open_stage_to_string = function
  | Create_store_directory -> "create_store_directory"
  | Resolve_store_path -> "resolve_store_path"
  | Validate_store_directory -> "validate_store_directory"
  | Open_lifetime_lock -> "open_lifetime_lock"
  | Acquire_lifetime_lock -> "acquire_lifetime_lock"
  | Validate_lifetime_lock -> "validate_lifetime_lock"
  | Release_lifetime_lock_after_failure -> "release_lifetime_lock_after_failure"

let open_error_to_string = function
  | Invalid_base_path -> "HTTP MCP transport session store requires an explicit BasePath"
  | Store_locked { lock_path } ->
    Printf.sprintf "HTTP MCP transport session store is already locked: %s" lock_path
  | Open_filesystem_error { stage; path; message } ->
    Printf.sprintf
      "HTTP MCP transport session store open failed: stage=%s path=%s error=%s"
      (open_stage_to_string stage)
      path
      message
  | Restore_failed failure -> restore_failure_to_string failure
  | Restore_and_lock_release_failed
      { restore_failure; lock_path; release_message } ->
    Printf.sprintf
      "%s; additionally failed to release lifetime lock %s: %s"
      (restore_failure_to_string restore_failure)
      lock_path
      release_message

let not_committed_failure_to_string failure =
  Printf.sprintf
    "path=%s stage=%s cleanup=%s error=%s"
    failure.path
    (Fs_compat.Atomic_write.not_committed_stage_label failure.stage)
    (Fs_compat.Atomic_write.temporary_cleanup_label failure.cleanup)
    failure.message

let durability_unknown_failure_to_string failure =
  Printf.sprintf
    "path=%s stage=%s cleanup=%s error=%s"
    failure.path
    (Fs_compat.Atomic_write.uncertain_commit_stage_label failure.stage)
    (Fs_compat.Atomic_write.temporary_cleanup_label failure.cleanup)
    failure.message

let mutation_operation_label = function
  | Initialize_session -> "initialize"
  | Delete_session -> "delete"
  | Repair_session -> "repair"

let indeterminate_cause_to_string = function
  | Atomic_commit_unknown failure ->
    durability_unknown_failure_to_string failure
  | Retry_not_committed failure ->
    Printf.sprintf
      "durability repair was not committed: %s"
      (not_committed_failure_to_string failure)
  | Recovery_cleanup_failed { temporary_path; message } ->
    Printf.sprintf
      "temporary recovery cleanup failed: path=%s error=%s"
      temporary_path message
  | Unexpected_mutation_failure { message } -> message

let persistence_indeterminate_to_string indeterminate =
  Printf.sprintf
    "session=%S operation=%s error=%s"
    indeterminate.session_id
    (mutation_operation_label indeterminate.operation)
    (indeterminate_cause_to_string indeterminate.cause)

let mutation_error_to_string = function
  | Store_closed -> "HTTP MCP transport session store is closed"
  | Invalid_session_record error -> validation_error_to_string error
  | Invalid_delete_request error -> validation_error_to_string error
  | Session_already_active session_id ->
    Printf.sprintf "MCP transport session %S is already active" session_id
  | Session_already_deleted session_id ->
    Printf.sprintf "MCP transport session %S is already deleted" session_id
  | Session_unknown session_id ->
    Printf.sprintf "MCP transport session %S is unknown" session_id
  | Session_filename_collision { session_id; conflicting_session_id } ->
    Printf.sprintf
      "MCP transport session ids %S and %S map to the same storage key"
      session_id conflicting_session_id
  | Session_lane_unavailable { session_id; message } ->
    Printf.sprintf
      "MCP transport session lane is unavailable: session=%S error=%s"
      session_id message
  | Persistence_not_committed failure ->
    Printf.sprintf
      "MCP transport session persistence was not committed: %s"
      (not_committed_failure_to_string failure)
  | Persistence_indeterminate indeterminate ->
    Printf.sprintf
      "MCP transport session persistence is indeterminate: %s"
      (persistence_indeterminate_to_string indeterminate)

let ( let* ) = Result.bind

let is_nonempty value = not (String.equal (String.trim value) "")

let is_finite value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false

let validate_session session =
  if not (is_nonempty session.session_id)
  then Error Empty_session_id
  else if not (is_nonempty session.protocol_version)
  then Error Empty_protocol_version
  else if not (Mcp_transport_protocol.is_supported_protocol_version session.protocol_version)
  then Error (Unsupported_protocol_version session.protocol_version)
  else if not (is_nonempty session.owner.Server_transport_admission.agent_name)
  then Error Empty_owner_agent_name
  else if not (is_finite session.started_at)
  then Error Non_finite_started_at
  else Ok ()

let validate_tombstone tombstone =
  if not (is_nonempty tombstone.session_id)
  then Error Empty_session_id
  else if not (is_finite tombstone.deleted_at)
  then Error Non_finite_deleted_at
  else Ok ()

let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let filename_for_session_id session_id =
  sha256_hex session_id ^ session_file_suffix

let path_for_session_id t session_id =
  Filename.concat t.store_dir (filename_for_session_id session_id)

let profile_to_string = function
  | Server_mcp_transport_http_types.Full -> "full"
  | Managed_agent -> "managed_agent"
  | Operator_remote -> "operator_remote"

let profile_of_string = function
  | "full" -> Ok Server_mcp_transport_http_types.Full
  | "managed_agent" -> Ok Server_mcp_transport_http_types.Managed_agent
  | "operator_remote" -> Ok Server_mcp_transport_http_types.Operator_remote
  | profile -> Error (Unsupported_tool_profile profile)

let option_string_to_json = function
  | None -> `Null
  | Some value -> `String value

let transport_context_to_json = function
  | None -> `Null
  | Some context ->
    `Assoc
      [ ( "network_protocol_name"
        , option_string_to_json context.Otel_dispatch_hook.network_protocol_name )
      ; ( "network_protocol_version"
        , option_string_to_json context.network_protocol_version )
      ; "network_transport", option_string_to_json context.network_transport
      ]

let owner_to_json owner =
  `Assoc
    [ "agent_name", `String owner.Server_transport_admission.agent_name
    ; "role", `String (Masc_domain.agent_role_to_string owner.role)
    ]

let session_state_to_json = function
  | Active session ->
    `Assoc
      [ "schema_version", `Int schema_version
      ; "session_id", `String session.session_id
      ; ( "state"
        , `Assoc
            [ "kind", `String "active"
            ; "protocol_version", `String session.protocol_version
            ; "tool_profile", `String (profile_to_string session.tool_profile)
            ; "owner", owner_to_json session.owner
            ; "started_at", `Float session.started_at
            ; "transport_context", transport_context_to_json session.transport_context
            ] )
      ]
  | Deleted tombstone ->
    `Assoc
      [ "schema_version", `Int schema_version
      ; "session_id", `String tombstone.session_id
      ; ( "state"
        , `Assoc
            [ "kind", `String "deleted"
            ; "deleted_at", `Float tombstone.deleted_at
            ] )
      ]

let string_set values =
  List.fold_left (fun set value -> SSet.add value set) SSet.empty values

let validate_object_fields ~context ~required fields =
  let allowed = string_set required in
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun field -> not (SSet.mem field seen)) required with
       | Some field -> Error (Missing_field { context; field })
       | None -> Ok ())
    | (field, _) :: _ when SSet.mem field seen ->
      Error (Duplicate_field { context; field })
    | (field, _) :: _ when not (SSet.mem field allowed) ->
      Error (Unexpected_field { context; field })
    | (field, _) :: rest -> loop (SSet.add field seen) rest
  in
  loop SSet.empty fields

let decode_object ~context ~required = function
  | `Assoc fields ->
    let* () = validate_object_fields ~context ~required fields in
    Ok fields
  | _ -> Error (Expected_object { context })

let decode_string ~context ~field fields =
  match List.assoc_opt field fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Invalid_field { context; field; expected = "a JSON string" })
  | None -> Error (Missing_field { context; field })

let decode_nonempty_string ~context ~field fields =
  let* value = decode_string ~context ~field fields in
  if is_nonempty value
  then Ok value
  else Error (Invalid_field { context; field; expected = "a non-empty JSON string" })

let decode_number ~context ~field fields =
  match List.assoc_opt field fields with
  | Some (`Float value) when is_finite value -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> Error (Invalid_field { context; field; expected = "a finite JSON number" })
  | None -> Error (Missing_field { context; field })

let decode_nullable_string ~context ~field fields =
  match List.assoc_opt field fields with
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Invalid_field { context; field; expected = "a string or null" })
  | None -> Error (Missing_field { context; field })

let decode_owner json =
  let context = "state.owner" in
  let* fields = decode_object ~context ~required:[ "agent_name"; "role" ] json in
  let* agent_name = decode_nonempty_string ~context ~field:"agent_name" fields in
  let* role_name = decode_nonempty_string ~context ~field:"role" fields in
  match Masc_domain.agent_role_of_string role_name with
  | Ok role ->
    Ok ({ agent_name; role } : Server_transport_admission.identity)
  | Error _ -> Error (Unsupported_owner_role role_name)

let decode_transport_context = function
  | `Null -> Ok None
  | json ->
    let context = "state.transport_context" in
    let* fields =
      decode_object
        ~context
        ~required:
          [ "network_protocol_name"; "network_protocol_version"; "network_transport" ]
        json
    in
    let* network_protocol_name =
      decode_nullable_string ~context ~field:"network_protocol_name" fields
    in
    let* network_protocol_version =
      decode_nullable_string ~context ~field:"network_protocol_version" fields
    in
    let* network_transport =
      decode_nullable_string ~context ~field:"network_transport" fields
    in
    Ok
      (Some
         { Otel_dispatch_hook.network_protocol_name
         ; network_protocol_version
         ; network_transport
         })

let decode_active ~session_id fields =
  let context = "state" in
  let* () =
    validate_object_fields
      ~context
      ~required:
        [ "kind"
        ; "protocol_version"
        ; "tool_profile"
        ; "owner"
        ; "started_at"
        ; "transport_context"
        ]
      fields
  in
  let* protocol_version =
    decode_nonempty_string ~context ~field:"protocol_version" fields
  in
  let* tool_profile_name =
    decode_nonempty_string ~context ~field:"tool_profile" fields
  in
  let* tool_profile = profile_of_string tool_profile_name in
  let* owner_json =
    match List.assoc_opt "owner" fields with
    | Some json -> Ok json
    | None -> Error (Missing_field { context; field = "owner" })
  in
  let* owner = decode_owner owner_json in
  let* started_at = decode_number ~context ~field:"started_at" fields in
  let* transport_json =
    match List.assoc_opt "transport_context" fields with
    | Some json -> Ok json
    | None -> Error (Missing_field { context; field = "transport_context" })
  in
  let* transport_context = decode_transport_context transport_json in
  let session =
    { session_id
    ; protocol_version
    ; tool_profile
    ; owner
    ; started_at
    ; transport_context
    }
  in
  let* () = Result.map_error (fun error -> Invalid_session error) (validate_session session) in
  Ok (Active session)

let decode_deleted ~session_id fields =
  let context = "state" in
  let* () =
    validate_object_fields ~context ~required:[ "kind"; "deleted_at" ] fields
  in
  let* deleted_at = decode_number ~context ~field:"deleted_at" fields in
  let tombstone = { session_id; deleted_at } in
  let* () =
    Result.map_error (fun error -> Invalid_tombstone error) (validate_tombstone tombstone)
  in
  Ok (Deleted tombstone)

let session_state_of_json json =
  let context = "session" in
  let* fields =
    decode_object
      ~context
      ~required:[ "schema_version"; "session_id"; "state" ]
      json
  in
  let* version =
    match List.assoc_opt "schema_version" fields with
    | Some (`Int version) -> Ok version
    | Some _ ->
      Error
        (Invalid_field
           { context; field = "schema_version"; expected = "an integer" })
    | None -> Error (Missing_field { context; field = "schema_version" })
  in
  let* () =
    if version = schema_version
    then Ok ()
    else Error (Unsupported_schema_version version)
  in
  let* session_id = decode_nonempty_string ~context ~field:"session_id" fields in
  let* state_fields =
    match List.assoc_opt "state" fields with
    | Some (`Assoc state_fields) -> Ok state_fields
    | Some _ -> Error (Expected_object { context = "state" })
    | None -> Error (Missing_field { context; field = "state" })
  in
  let* kind = decode_nonempty_string ~context:"state" ~field:"kind" state_fields in
  let* state =
    match kind with
    | "active" -> decode_active ~session_id state_fields
    | "deleted" -> decode_deleted ~session_id state_fields
    | unsupported -> Error (Unsupported_state_kind unsupported)
  in
  Ok (session_id, state)

let unix_error_message error operation argument =
  Printf.sprintf "%s (%s %s)" (Unix.error_message error) operation argument

let exception_message = function
  | Unix.Unix_error (error, operation, argument) ->
    unix_error_message error operation argument
  | exn -> Printexc.to_string exn

let fsync_directory_strict directory =
  let fd = Unix.openfile directory [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let sync_result =
    try
      Unix.fsync fd;
      Ok ()
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error (unix_error_message error operation argument)
  in
  let close_result =
    try
      Unix.close fd;
      Ok ()
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error (unix_error_message error operation argument)
  in
  match sync_result, close_result with
  | Ok (), Ok () -> ()
  | Error message, Ok () | Ok (), Error message -> raise (Sys_error message)
  | Error sync_message, Error close_message ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s; additionally failed to close directory: %s"
            sync_message close_message))

let mkdir_p_strict path =
  let rec ensure directory =
    if
      String.equal directory ""
      || String.equal directory "."
      || String.equal directory "/"
    then ()
    else
      match Unix.stat directory with
      | { Unix.st_kind = Unix.S_DIR; _ } -> ()
      | _ -> raise (Unix.Unix_error (Unix.ENOTDIR, "mkdir", directory))
      | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        let parent = Filename.dirname directory in
        ensure parent;
        (try Unix.mkdir directory private_directory_permissions with
         | Unix.Unix_error (Unix.EEXIST, _, _) ->
           (match Unix.stat directory with
            | { Unix.st_kind = Unix.S_DIR; _ } -> ()
            | _ -> raise (Unix.Unix_error (Unix.ENOTDIR, "mkdir", directory))));
        fsync_directory_strict parent
  in
  ensure path

let validate_private_directory_unix path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_DIR
    then Error "path must be a directory and must not be a symlink"
    else if stat.Unix.st_uid <> Unix.getuid ()
    then
      Error
        (Printf.sprintf
           "directory owner uid %d does not match process uid %d"
           stat.Unix.st_uid (Unix.getuid ()))
    else if stat.Unix.st_perm land 0o077 <> 0
    then
      Error
        (Printf.sprintf
           "directory permissions %o expose session state to group or other users"
           stat.Unix.st_perm)
    else Ok ()
  with
  | exn -> Error (exception_message exn)

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino

let ensure_recovery_directory_unix recovery_dir =
  let recovery_root = Filename.dirname recovery_dir in
  let root_result =
    try
      mkdir_p_strict recovery_root;
      Ok ()
    with
    | exn -> Error (exception_message exn)
  in
  match root_result with
  | Error _ as error -> error
  | Ok () ->
    (match validate_private_directory_unix recovery_root with
     | Error _ as error -> error
     | Ok () ->
       let recovery_result =
         try
           mkdir_p_strict recovery_dir;
           Ok ()
         with
         | exn -> Error (exception_message exn)
       in
       Result.bind recovery_result (fun () -> validate_private_directory_unix recovery_dir))

let quarantine_atomic_temporary_unix ~store_dir ~recovery_dir temporary_path =
  match ensure_recovery_directory_unix recovery_dir with
  | Error message -> Error message
  | Ok () ->
    (try
       let destination =
         Filename.concat recovery_dir (Filename.basename temporary_path)
       in
       match Unix.lstat temporary_path with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
         fsync_directory_strict store_dir;
         Ok (recovery_dir, 0)
       | source_stat ->
         if source_stat.Unix.st_kind <> Unix.S_REG
         then Error "temporary recovery source is not a regular file"
         else
           let rec reserve_destination index =
             let candidate =
               if index = 0
               then destination
               else destination ^ "." ^ string_of_int index
             in
             match Unix.lstat candidate with
             | candidate_stat
               when candidate_stat.Unix.st_kind = Unix.S_REG
                    && same_inode source_stat candidate_stat ->
               Ok candidate
             | _ -> reserve_destination (index + 1)
             | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
               Unix.link temporary_path candidate;
               fsync_directory_strict recovery_dir;
               Ok candidate
           in
           (match reserve_destination 0 with
            | Error _ as error -> error
            | Ok destination ->
              Unix.unlink temporary_path;
              fsync_directory_strict store_dir;
              Ok (destination, source_stat.Unix.st_size))
     with
     | exn -> Error (exception_message exn))

let quarantine_owned_temporaries_unix ~store_dir ~recovery_dir =
  Sys.readdir store_dir
  |> Array.to_list
  |> List.filter Fs_compat.Atomic_write.is_atomic_orphan_name
  |> List.sort String.compare
  |> List.fold_left
       (fun result entry_name ->
         let* quarantined = result in
         let path = Filename.concat store_dir entry_name in
         match
           quarantine_atomic_temporary_unix ~store_dir ~recovery_dir path
         with
         | Ok evidence -> Ok (evidence :: quarantined)
         | Error message ->
           Error
             (Store_temporary_quarantine_failed
                { path; recovery_dir; message }))
       (Ok [])
  |> Result.map List.rev

type strict_read_error =
  | Strict_read_not_regular
  | Strict_read_path_changed
  | Strict_read_io of string

let read_file_strict path =
  try
    let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    let channel =
      try Unix.in_channel_of_descr fd with
      | channel_exn ->
        let channel_message = exception_message channel_exn in
        let close_message =
          try
            Unix.close fd;
            None
          with
          | close_exn -> Some (exception_message close_exn)
        in
        (match close_message with
         | None -> raise channel_exn
         | Some close_message ->
           failwith
             (Printf.sprintf
                "%s; additionally failed to close descriptor: %s"
                channel_message close_message))
    in
    let read_result =
      try
        let fd_stat = Unix.fstat fd in
        let path_stat = Unix.lstat path in
        if
          fd_stat.Unix.st_kind <> Unix.S_REG
          || path_stat.Unix.st_kind <> Unix.S_REG
        then Error Strict_read_not_regular
        else if not (same_inode fd_stat path_stat)
        then Error Strict_read_path_changed
        else
          let length = in_channel_length channel in
          Ok (really_input_string channel length)
      with
      | End_of_file -> Error Strict_read_path_changed
      | exn -> Error (Strict_read_io (exception_message exn))
    in
    let close_result =
      try
        close_in channel;
        Ok ()
      with
      | exn -> Error (exception_message exn)
    in
    (match read_result, close_result with
     | Ok content, Ok () -> Ok content
     | Error error, Ok () -> Error error
     | Ok _, Error message -> Error (Strict_read_io message)
     | Error error, Error close_message ->
       let read_message =
         match error with
         | Strict_read_not_regular -> "entry is not a regular file"
         | Strict_read_path_changed -> "entry path changed while it was being read"
         | Strict_read_io message -> message
       in
       Error
         (Strict_read_io
            (Printf.sprintf
               "%s; additionally failed to close input: %s"
               read_message close_message)))
  with
  | exn -> Error (Strict_read_io (exception_message exn))

let restore_store_unix store_dir =
  let entry_names = Sys.readdir store_dir |> Array.to_list |> List.sort String.compare in
  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  let is_session_filename entry_name =
    let digest_length = Digestif.SHA256.digest_size * 2 in
    let suffix_length = String.length session_file_suffix in
    let expected_length = digest_length + suffix_length in
    String.length entry_name = expected_length
    && String.ends_with ~suffix:session_file_suffix entry_name
    && String.for_all is_lower_hex (String.sub entry_name 0 digest_length)
  in
  let rec restore snapshot = function
    | [] -> Ok snapshot
    | entry_name :: rest when String.equal entry_name lifetime_lock_name ->
      restore snapshot rest
    | entry_name :: rest ->
      let path = Filename.concat store_dir entry_name in
      if not (is_session_filename entry_name)
      then Error (Unexpected_store_entry { entry_name })
      else
        (match read_file_strict path with
         | Error Strict_read_not_regular ->
           Error (Store_entry_not_regular_file { entry_name })
         | Error Strict_read_path_changed ->
           Error
             (Store_entry_unreadable
                { path; message = "entry path changed while it was being read" })
         | Error (Strict_read_io message) ->
           Error (Store_entry_unreadable { path; message })
         | Ok content ->
           (match
              try Ok (Yojson.Safe.from_string content) with
              | Yojson.Json_error message -> Error message
            with
            | Error message -> Error (Store_entry_json_invalid { path; message })
            | Ok json ->
              (match session_state_of_json json with
               | Error error -> Error (Store_entry_schema_invalid { path; error })
               | Ok (session_id, state) ->
                 let expected_name = filename_for_session_id session_id in
                 if not (String.equal expected_name entry_name)
                 then
                   Error
                     (Store_entry_filename_mismatch
                        { path
                        ; expected_name
                        ; actual_name = entry_name
                        ; session_id
                        })
                 else if SMap.mem session_id snapshot
                 then Error (Duplicate_session_id { session_id; path })
                 else restore (SMap.add session_id (Stable state) snapshot) rest)))
  in
  restore SMap.empty entry_names

let release_lock_unix fd =
  try
    (* Closing the owning descriptor releases the process-associated lock.
       A separate F_ULOCK adds a second failure surface without improving the
       lifetime contract. *)
    Unix.close fd;
    Ok ()
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_error_message error operation argument)

let close_unlocked_fd_unix fd =
  try
    Unix.close fd;
    Ok ()
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_error_message error operation argument)

let validate_lifetime_lock_fd_unix ~lock_path fd =
  try
    let path_stat = Unix.lstat lock_path in
    let fd_stat = Unix.fstat fd in
    if path_stat.Unix.st_kind <> Unix.S_REG
    then Error "lifetime lock path must be a regular file and must not be a symlink"
    else if
      path_stat.Unix.st_dev <> fd_stat.Unix.st_dev
      || path_stat.Unix.st_ino <> fd_stat.Unix.st_ino
    then Error "lifetime lock path changed while it was being opened"
    else if path_stat.Unix.st_uid <> Unix.getuid ()
    then Error "lifetime lock owner does not match the server process uid"
    else if path_stat.Unix.st_perm land 0o077 <> 0
    then Error "lifetime lock permissions expose state to group or other users"
    else Ok ()
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_error_message error operation argument)

type persistence_outcome =
  | Write_durable
  | Write_not_committed of not_committed_failure
  | Write_indeterminate of durability_unknown_failure

let persistence_outcome = function
  | Ok () -> Write_durable
  | Error
      (Fs_compat.Atomic_write.Not_committed { path; stage; message; cleanup }) ->
    Write_not_committed { path; stage; message; cleanup }
  | Error
      (Fs_compat.Atomic_write.Commit_durability_unknown
        { path; stage; message; cleanup }) ->
    Write_indeterminate { path; stage; message; cleanup }

let write_session_state t session_id state =
  let path = path_for_session_id t session_id in
  let content = Yojson.Safe.to_string (session_state_to_json state) ^ "\n" in
  Eio_guard.run_in_systhread (fun () ->
    Fs_compat.Atomic_write.save_file_atomic_strict path content)
  |> persistence_outcome

let rec publish_entry t session_id entry =
  let current = Atomic.get t.snapshot in
  let updated = SMap.add session_id entry current in
  if not (Atomic.compare_and_set t.snapshot current updated)
  then publish_entry t session_id entry

let session_id_of_state = function
  | Active session -> session.session_id
  | Deleted tombstone -> tombstone.session_id

let session_id_of_entry = function
  | Stable state -> session_id_of_state state
  | Durability_pending { intended; _ } -> session_id_of_state intended

let conflicting_storage_owner snapshot session_id =
  let storage_key = filename_for_session_id session_id in
  SMap.fold
    (fun _ entry conflict ->
      match conflict with
      | Some _ -> conflict
      | None ->
        let existing_session_id = session_id_of_entry entry in
        if
          (not (String.equal existing_session_id session_id))
          && String.equal
               (filename_for_session_id existing_session_id)
               storage_key
        then Some existing_session_id
        else None)
    snapshot None

let make_indeterminate ~session_id ~operation cause =
  { session_id; operation; cause }

let recovery_path_of_cleanup = function
  | Fs_compat.Atomic_write.Temporary_cleanup_failed { temporary_path; _ } ->
    Some temporary_path
  | Fs_compat.Atomic_write.No_temporary
  | Fs_compat.Atomic_write.Temporary_removed _
  | Fs_compat.Atomic_write.Temporary_absent _ ->
    None

let recovery_path_of_cause = function
  | Atomic_commit_unknown failure -> recovery_path_of_cleanup failure.cleanup
  | Retry_not_committed failure -> recovery_path_of_cleanup failure.cleanup
  | Recovery_cleanup_failed { temporary_path; _ } -> Some temporary_path
  | Unexpected_mutation_failure _ -> None

let rec publish_indeterminate t ~session_id ~operation ~intended cause =
  let indeterminate = make_indeterminate ~session_id ~operation cause in
  let snapshot = Atomic.get t.snapshot in
  let recovery_paths =
    match SMap.find_opt session_id snapshot with
    | Some (Durability_pending { recovery_paths; _ }) -> recovery_paths
    | Some (Stable _) | None -> SSet.empty
  in
  let recovery_paths =
    match recovery_path_of_cause cause with
    | Some path -> SSet.add path recovery_paths
    | None -> recovery_paths
  in
  let updated =
    SMap.add session_id
      (Durability_pending { intended; indeterminate; recovery_paths })
      snapshot
  in
  if Atomic.compare_and_set t.snapshot snapshot updated
  then begin
    Log.Server.error
      "MCP transport session entered explicit durability quarantine: %s"
      (persistence_indeterminate_to_string indeterminate);
    Error (Persistence_indeterminate indeterminate)
  end
  else publish_indeterminate t ~session_id ~operation ~intended cause

let cleanup_recovery_path t temporary_path =
  try
    Eio_guard.run_in_systhread (fun () ->
      let parent = Unix.realpath (Filename.dirname temporary_path) in
      if not (String.equal parent t.store_dir)
      then
        Error
          (Printf.sprintf
             "temporary recovery path escaped the canonical session store: parent=%s store=%s"
             parent t.store_dir)
      else
        Result.map
          (fun (_destination, _size) -> ())
          (quarantine_atomic_temporary_unix
             ~store_dir:t.store_dir ~recovery_dir:t.recovery_dir
             temporary_path))
  with
  | exn -> Error (exception_message exn)

let rec clear_pending_recovery_paths t session_id =
  let snapshot = Atomic.get t.snapshot in
  match SMap.find_opt session_id snapshot with
  | Some (Durability_pending pending) ->
    let updated =
      SMap.add session_id
        (Durability_pending { pending with recovery_paths = SSet.empty })
        snapshot
    in
    if not (Atomic.compare_and_set t.snapshot snapshot updated)
    then clear_pending_recovery_paths t session_id
  | Some (Stable _) | None -> ()

let cleanup_pending_recovery_paths t ~session_id ~operation ~intended =
  let recovery_paths =
    match SMap.find_opt session_id (Atomic.get t.snapshot) with
    | Some (Durability_pending { recovery_paths; _ }) ->
      SSet.elements recovery_paths
    | Some (Stable _) | None -> []
  in
  let rec cleanup = function
    | [] ->
      clear_pending_recovery_paths t session_id;
      Ok ()
    | temporary_path :: rest ->
      (match cleanup_recovery_path t temporary_path with
       | Ok () -> cleanup rest
       | Error message ->
         publish_indeterminate
           t ~session_id ~operation ~intended
           (Recovery_cleanup_failed { temporary_path; message }))
  in
  cleanup recovery_paths

let persist_new_intended t ~session_id ~operation ~intended =
  match write_session_state t session_id intended with
  | Write_durable ->
    publish_entry t session_id (Stable intended);
    Ok ()
  | Write_not_committed failure ->
    (match recovery_path_of_cleanup failure.cleanup with
     | None -> Error (Persistence_not_committed failure)
     | Some _ ->
       publish_indeterminate
         t ~session_id ~operation ~intended
         (Retry_not_committed failure))
  | Write_indeterminate failure ->
    publish_indeterminate
      t ~session_id ~operation ~intended
      (Atomic_commit_unknown failure)

let persist_pending_intended t ~session_id ~operation ~intended =
  match cleanup_pending_recovery_paths t ~session_id ~operation ~intended with
  | Error _ as error -> error
  | Ok () ->
    (match write_session_state t session_id intended with
     | Write_durable ->
       publish_entry t session_id (Stable intended);
       Ok ()
     | Write_not_committed failure ->
       publish_indeterminate
         t ~session_id ~operation ~intended
         (Retry_not_committed failure)
     | Write_indeterminate failure ->
       publish_indeterminate
         t ~session_id ~operation ~intended
         (Atomic_commit_unknown failure))

let handle_initialize t session =
  let snapshot = Atomic.get t.snapshot in
  match conflicting_storage_owner snapshot session.session_id with
  | Some conflicting_session_id ->
    Error
      (Session_filename_collision
         { session_id = session.session_id; conflicting_session_id })
  | None ->
    (match SMap.find_opt session.session_id snapshot with
     | Some (Stable (Active _)) ->
       Error (Session_already_active session.session_id)
     | Some (Stable (Deleted _)) ->
       Error (Session_already_deleted session.session_id)
     | Some (Durability_pending { indeterminate; _ }) ->
       Error (Persistence_indeterminate indeterminate)
     | None ->
       persist_new_intended
         t ~session_id:session.session_id ~operation:Initialize_session
         ~intended:(Active session))

let handle_delete t ~session_id ~deleted_at =
  match SMap.find_opt session_id (Atomic.get t.snapshot) with
  | None -> Error (Session_unknown session_id)
  | Some (Stable (Deleted tombstone)) -> Ok (Already_deleted tombstone)
  | Some (Stable (Active _)) ->
    let intended = Deleted { session_id; deleted_at } in
    Result.map
      (fun () -> Deleted_now)
      (persist_new_intended t ~session_id ~operation:Delete_session ~intended)
  | Some (Durability_pending { intended = Deleted tombstone; _ }) ->
    Result.map
      (fun () -> Deleted_now)
      (persist_pending_intended
         t ~session_id ~operation:Delete_session
         ~intended:(Deleted tombstone))
  | Some (Durability_pending { intended = Active _; _ }) ->
    let intended = Deleted { session_id; deleted_at } in
    Result.map
      (fun () -> Deleted_now)
      (persist_pending_intended t ~session_id ~operation:Delete_session ~intended)

let rec lane_for_session t session_id =
  let storage_key = filename_for_session_id session_id in
  let lanes = Atomic.get t.lanes in
  match SMap.find_opt storage_key lanes with
  | Some lane -> lane
  | None ->
    let lane = { storage_key; mutex = Eio.Mutex.create () } in
    if Atomic.compare_and_set t.lanes lanes (SMap.add storage_key lane lanes)
    then lane
    else lane_for_session t session_id

let rec begin_mutation t =
  if Atomic.get t.closed
  then false
  else
    let active = Atomic.get t.active_mutations in
    if Atomic.compare_and_set t.active_mutations active (active + 1)
    then
      if Atomic.get t.closed
      then begin
        let previous = Atomic.fetch_and_add t.active_mutations (-1) in
        if previous = 1
        then ignore (Eio.Promise.try_resolve t.resolve_mutations_drained () : bool);
        false
      end
      else true
    else begin_mutation t

let finish_mutation t =
  let previous = Atomic.fetch_and_add t.active_mutations (-1) in
  if previous <= 0
  then
    Log.Server.error
      "MCP transport session store mutation counter underflow: previous=%d"
      previous
  else if previous = 1 && Atomic.get t.closed
  then ignore (Eio.Promise.try_resolve t.resolve_mutations_drained () : bool)

let unexpected_indeterminate t ~session_id ~operation ~intended exn =
  let message = Printexc.to_string exn in
  Log.Server.error
    "MCP transport session mutation failed indeterminately: operation=%s session=%s error=%s"
    (mutation_operation_label operation) session_id message;
  publish_indeterminate
    t ~session_id ~operation ~intended
    (Unexpected_mutation_failure { message })

let run_in_session_lane t ~session_id ~operation ~intended mutation =
  let lane = lane_for_session t session_id in
  try
    Eio.Mutex.use_rw ~protect:true lane.mutex (fun () ->
      if not (begin_mutation t)
      then Error Store_closed
      else
        Fun.protect
          ~finally:(fun () -> finish_mutation t)
          (fun () ->
            try mutation () with
            | exn ->
              unexpected_indeterminate t ~session_id ~operation ~intended exn))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Eio.Mutex.Poisoned exn ->
    let message = Printexc.to_string exn in
    Log.Server.error
      "MCP transport session lane is poisoned: session=%s operation=%s error=%s"
      session_id (mutation_operation_label operation) message;
    Error (Session_lane_unavailable { session_id; message })
  | exn ->
    let message = Printexc.to_string exn in
    Log.Server.error
      "MCP transport session lane failed: session=%s operation=%s error=%s"
      session_id (mutation_operation_label operation) message;
    Error (Session_lane_unavailable { session_id; message })

let open_ ~sw ~base_path =
  if not (is_nonempty base_path)
  then Error Invalid_base_path
  else
    let masc_root = Config_dir_resolver.masc_root ~base_path in
    let requested_store_dir = Filename.concat masc_root store_directory_name in
    let preexisting_symlink_check =
      match Unix.lstat requested_store_dir with
      | { Unix.st_kind = Unix.S_LNK; _ } ->
        Error
          (Open_filesystem_error
             { stage = Validate_store_directory
             ; path = requested_store_dir
             ; message = "store directory symlinks are not permitted"
             })
      | _ -> Ok ()
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
      | exception Unix.Unix_error (error, operation, argument) ->
        Error
          (Open_filesystem_error
             { stage = Validate_store_directory
             ; path = requested_store_dir
             ; message = unix_error_message error operation argument
             })
    in
    let* () = preexisting_symlink_check in
    let directory_result =
      try
        Eio_guard.run_in_systhread (fun () -> mkdir_p_strict requested_store_dir);
        Ok ()
      with
      | Unix.Unix_error (error, operation, argument) ->
        Error
          (Open_filesystem_error
             { stage = Create_store_directory
             ; path = requested_store_dir
             ; message = unix_error_message error operation argument
             })
      | Sys_error message ->
        Error
          (Open_filesystem_error
             { stage = Create_store_directory
             ; path = requested_store_dir
             ; message
             })
    in
    let* () = directory_result in
    let directory_validation =
      match
        Eio_guard.run_in_systhread (fun () ->
          validate_private_directory_unix requested_store_dir)
      with
      | Ok () -> Ok ()
      | Error message ->
        Error
          (Open_filesystem_error
             { stage = Validate_store_directory
             ; path = requested_store_dir
             ; message
             })
    in
    let* () = directory_validation in
    let canonical_store_dir =
      try
        Ok
          (Eio_guard.run_in_systhread (fun () ->
             Unix.realpath requested_store_dir))
      with
      | Unix.Unix_error (error, operation, argument) ->
        Error
          (Open_filesystem_error
             { stage = Resolve_store_path
             ; path = requested_store_dir
             ; message = unix_error_message error operation argument
             })
      | Sys_error message ->
        Error
          (Open_filesystem_error
             { stage = Resolve_store_path; path = requested_store_dir; message })
    in
    let* store_dir = canonical_store_dir in
    let recovery_dir =
      Filename.concat
        (Filename.concat (Filename.dirname store_dir) recovery_directory_name)
        (sha256_hex store_dir)
    in
    let lock_path = Filename.concat store_dir lifetime_lock_name in
    let process_reservation_released = Atomic.make false in
    let release_process_reservation_once () =
      if Atomic.compare_and_set process_reservation_released false true
      then release_process_lock_path lock_path
    in
    let* () =
      if reserve_process_lock_path lock_path
      then begin
        (* POSIX locks do not reject a second writer in the same process.  The
           process reservation is released only after the owning descriptor
           has been closed successfully. *)
        Ok ()
      end
      else Error (Store_locked { lock_path })
    in
    let lock_result =
      Eio.Cancel.protect (fun () ->
        Eio_guard.run_in_systhread (fun () ->
          match
            try
              let fd =
                Unix.openfile
                  lock_path
                  [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
                  private_file_permissions
              in
              Ok fd
            with
            | Unix.Unix_error (error, operation, argument) ->
              Error
                (Open_filesystem_error
                   { stage = Open_lifetime_lock
                   ; path = lock_path
                   ; message = unix_error_message error operation argument
                   })
          with
          | Error _ as error -> error
          | Ok fd ->
            (match Unix.lockf fd Unix.F_TLOCK 0 with
             | () ->
               (match validate_lifetime_lock_fd_unix ~lock_path fd with
                | Ok () -> Ok fd
                | Error primary ->
                  (match close_unlocked_fd_unix fd with
                   | Ok () ->
                     Error
                       (Open_filesystem_error
                          { stage = Validate_lifetime_lock
                          ; path = lock_path
                          ; message = primary
                          })
                   | Error release_message ->
                     Error
                       (Open_filesystem_error
                          { stage = Release_lifetime_lock_after_failure
                          ; path = lock_path
                          ; message =
                              Printf.sprintf
                                "%s; preceding validation failure: %s"
                                release_message
                                primary
                          })))
             | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
               (match close_unlocked_fd_unix fd with
                | Ok () -> Error (Store_locked { lock_path })
                | Error message ->
                  Error
                    (Open_filesystem_error
                       { stage = Release_lifetime_lock_after_failure
                       ; path = lock_path
                       ; message
                       }))
             | exception Unix.Unix_error (error, operation, argument) ->
               let primary = unix_error_message error operation argument in
               (match close_unlocked_fd_unix fd with
                | Ok () ->
                  Error
                    (Open_filesystem_error
                       { stage = Acquire_lifetime_lock
                       ; path = lock_path
                       ; message = primary
                       })
                | Error release_message ->
                  Error
                    (Open_filesystem_error
                       { stage = Release_lifetime_lock_after_failure
                       ; path = lock_path
                       ; message =
                           Printf.sprintf
                             "%s; preceding lock failure: %s"
                             release_message
                             primary
                       })))))
    in
    (match lock_result with
     | Error error ->
       (match error with
        | Open_filesystem_error
            { stage = Release_lifetime_lock_after_failure; _ } ->
          Log.Server.error
            "MCP transport session lock cleanup failed; retaining process reservation for fail-closed behavior: %s"
            (open_error_to_string error)
        | Invalid_base_path | Store_locked _ | Open_filesystem_error _ | Restore_failed _
        | Restore_and_lock_release_failed _ ->
          release_process_reservation_once ());
       Error error
     | Ok lock_fd ->
       (* Register lifetime cleanup immediately after acquisition.  Restore is
          blocking system-thread work and may be cancelled; delaying registration
          until after restore would leak the fd and process lock on that path. *)
       let closed = Atomic.make false in
       let lock_released = Atomic.make false in
       let release_mutex = Stdlib.Mutex.create () in
       let release_lifetime_lock_once () =
         Eio_guard.run_in_systhread (fun () ->
           Stdlib.Mutex.protect release_mutex (fun () ->
             if Atomic.get lock_released
             then Ok ()
             else
               match release_lock_unix lock_fd with
               | Ok () ->
                 Atomic.set lock_released true;
                 Ok ()
               | Error _ as error -> error))
       in
       let release_lifetime_resources_once () =
         match release_lifetime_lock_once () with
         | Ok () ->
           release_process_reservation_once ();
           Ok ()
         | Error _ as error -> error
       in
       Eio.Switch.on_release sw (fun () ->
         match release_lifetime_resources_once () with
         | Ok () -> ()
         | Error message ->
           raise (Lifetime_lock_release_failed { lock_path; message }));
       Eio.Fiber.check ();
       let restore_result =
         try
           Eio_guard.run_in_systhread (fun () ->
             let* quarantined =
               quarantine_owned_temporaries_unix ~store_dir ~recovery_dir
             in
             let* restored = restore_store_unix store_dir in
             Ok (quarantined, restored))
         with
         | Eio.Cancel.Cancelled _ as exn ->
           (match release_lifetime_resources_once () with
            | Ok () -> ()
            | Error message ->
              Log.Server.error
                "MCP transport session restore cancellation could not release lock %s: %s"
                lock_path message);
           raise exn
         | Unix.Unix_error (error, operation, argument) ->
           Error
             (Store_entry_unreadable
                { path = store_dir
                ; message = unix_error_message error operation argument
                })
         | Sys_error message ->
           Error (Store_entry_unreadable { path = store_dir; message })
         | exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           (match release_lifetime_resources_once () with
            | Ok () -> ()
            | Error message ->
              Log.Server.error
                "MCP transport session restore exception could not release lock %s: primary=%s cleanup=%s"
                lock_path
                (Printexc.to_string exn)
                message);
           Printexc.raise_with_backtrace exn backtrace
       in
       (match restore_result with
        | Error restore_failure ->
          (match release_lifetime_resources_once () with
           | Ok () -> Error (Restore_failed restore_failure)
           | Error release_message ->
             Error
               (Restore_and_lock_release_failed
                  { restore_failure; lock_path; release_message }))
        | Ok (quarantined, restored_snapshot) ->
          List.iter
            (fun (destination, size) ->
              Log.Server.warn
                "MCP transport session temporary quarantined before restore: destination=%s size=%d"
                destination size)
            quarantined;
          let mutations_drained, resolve_mutations_drained = Eio.Promise.create () in
          let t =
            { base_path
            ; store_dir
            ; recovery_dir
            ; snapshot = Atomic.make restored_snapshot
            ; lanes = Atomic.make SMap.empty
            ; closed
            ; active_mutations = Atomic.make 0
            ; mutations_drained
            ; resolve_mutations_drained
            }
          in
          (* This hook is registered after the lifetime-lock hook and therefore
             runs first (Eio release hooks are LIFO).  It closes mutation
             admission and waits only for operations that already crossed a
             per-session lane boundary before the file lock can be released. *)
          Eio.Switch.on_release sw (fun () ->
            Atomic.set closed true;
            if Atomic.get t.active_mutations = 0
            then
              ignore
                (Eio.Promise.try_resolve t.resolve_mutations_drained () : bool);
            Eio.Promise.await t.mutations_drained);
          Ok t))

let find_entry t ~session_id = SMap.find_opt session_id (Atomic.get t.snapshot)

let find t ~session_id =
  match find_entry t ~session_id with
  | Some (Stable state) -> Some (Stable_state state)
  | Some (Durability_pending { intended; indeterminate; _ }) ->
    Some (Pending_state { intended; indeterminate })
  | None -> None

let base_path t = t.base_path

let find_active t ~session_id =
  match find_entry t ~session_id with
  | Some (Stable (Active session)) -> Some session
  | Some (Stable (Deleted _)) | Some (Durability_pending _) | None -> None

let active_sessions t =
  SMap.fold
    (fun _ entry sessions ->
      match entry with
      | Stable (Active session) -> session :: sessions
      | Stable (Deleted _) | Durability_pending _ -> sessions)
    (Atomic.get t.snapshot)
    []
  |> List.rev

let pending_sessions t =
  SMap.fold
    (fun _ entry pending ->
      match entry with
      | Durability_pending { indeterminate; _ } -> indeterminate :: pending
      | Stable _ -> pending)
    (Atomic.get t.snapshot)
    []
  |> List.rev

let initialize t session =
  match validate_session session with
  | Error error -> Error (Invalid_session_record error)
  | Ok () when Atomic.get t.closed -> Error Store_closed
  | Ok () ->
    run_in_session_lane
      t ~session_id:session.session_id ~operation:Initialize_session
      ~intended:(Active session)
      (fun () -> handle_initialize t session)

let delete t ~session_id ~deleted_at =
  let tombstone = { session_id; deleted_at } in
  match validate_tombstone tombstone with
  | Error error -> Error (Invalid_delete_request error)
  | Ok () when Atomic.get t.closed -> Error Store_closed
  | Ok () ->
    run_in_session_lane
      t ~session_id ~operation:Delete_session
      ~intended:(Deleted tombstone)
      (fun () -> handle_delete t ~session_id ~deleted_at)

let repair_pending t ~session_id =
  match find_entry t ~session_id with
  | None -> Error (Session_unknown session_id)
  | Some (Stable state) -> Ok (Already_stable state)
  | Some (Durability_pending { intended = observed_intended; _ }) ->
    run_in_session_lane
      t ~session_id ~operation:Repair_session ~intended:observed_intended
      (fun () ->
        match find_entry t ~session_id with
        | None -> Error (Session_unknown session_id)
        | Some (Stable state) -> Ok (Already_stable state)
        | Some (Durability_pending { intended; _ }) ->
          Result.map
            (fun () -> Repaired intended)
            (persist_pending_intended
               t ~session_id ~operation:Repair_session ~intended))
