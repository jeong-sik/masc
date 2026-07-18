type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | Connector_attention
  | Hitl_resolved
  | Failure_judgment
  | Manual_compaction
  | Goal_assigned

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type urgency =
  | Immediate
  | Normal
  | Low

type stimulus =
  { kind : stimulus_kind
  ; post_id : string
  ; urgency : urgency
  ; arrived_at : float
  ; board_updated_at : float option
  }

type reaction_source =
  { stimulus_kind : stimulus_kind
  ; post_id : string
  }

type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type event_payload =
  | Stimulus_event of stimulus
  | Turn_started_event of reaction_source
  | Cursor_ack_event of cursor

type event =
  { event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; payload : event_payload
  }

type settlement_kind =
  | Ack
  | Requeue
  | Escalate

type transition_source =
  { event_id : string
  ; stimulus_id : string
  ; stimulus_kind : stimulus_kind
  ; post_id : string
  }

type transition =
  { transition_id : string
  ; transition_event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement_kind : settlement_kind
  ; settlement_identity : string
  ; external_input_requested : bool
  ; sources : transition_source list
  }

type stored_payload =
  | Stored_stimulus of stimulus
  | Stored_turn_started of reaction_source
  | Stored_transition_settlement of
      { reaction_kind : reaction_kind
      ; source : reaction_source
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      ; external_input_requested : bool
      }
  | Stored_cursor_ack of cursor

type stored_event =
  { sequence : int64
  ; event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; payload : stored_payload
  }

type stimulus_evidence =
  { matched_record_count : int
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_recorded_at : float option
  ; latest_reaction_event : stored_event option
  }

type write_outcome =
  | Inserted
  | Already_recorded

type transition_write_outcome =
  | Transition_inserted
  | Transition_already_recorded

type exact_summary =
  { row_count : int
  ; stimulus_count : int
  ; reaction_count : int
  ; turn_started_count : int
  ; event_queue_ack_count : int
  ; event_queue_requeue_count : int
  ; event_queue_escalation_count : int
  ; event_queue_external_input_count : int
  ; cursor_ack_count : int
  ; cursor_swept_stimulus_count : int
  ; orphan_reaction_stimulus_count : int
  ; in_progress_stimulus_count : int
  ; acked_stimulus_count : int
  ; escalated_stimulus_count : int
  ; external_input_requested_stimulus_count : int
  ; pending_stimulus_count : int
  ; pending_stimulus_ids : string list
  ; pending_ids_truncated : bool
  ; latest_recorded_at : float option
  ; latest_stimulus_id : string option
  }

type read_observation =
  { cursor : cursor option
  ; exact_summary : exact_summary
  }

type path_operation =
  | Inspect_parent
  | Prepare_parent
  | Inspect_database
  | Inspect_sidecar
  | Inspect_lock
  | Prepare_lock
  | Prepare_staging
  | Validate_identity
  | Publish_database

type sqlite_operation =
  | Open_database
  | Configure_connection
  | Initialize_schema
  | Validate_schema
  | Prepare_statement
  | Bind_parameter
  | Step_statement
  | Begin_transaction
  | Commit_transaction
  | Rollback_transaction
  | Finalize_statement
  | Close_database

type error =
  | Invalid_keeper_name of string
  | Invalid_event_identity of { field : string }
  | Invalid_timestamp of { field : string; value : float }
  | Invalid_transition of string
  | Lock_failure of File_lock_eio.durable_lock_error
  | Path_failure of
      { operation : path_operation
      ; path : string
      ; detail : string
      }
  | Database_identity_changed of string
  | Orphan_database_sidecars of
      { database_path : string
      ; sidecars : string list
      }
  | Application_id_mismatch of { expected : int64; actual : int64 }
  | User_version_mismatch of { expected : int64; actual : int64 }
  | Keeper_identity_mismatch of { expected : string; actual : string }
  | Schema_mismatch of string
  | Integrity_failure of string
  | Sqlite_failure of
      { operation : sqlite_operation
      ; rc : Sqlite3.Rc.t option
      ; detail : string
      }
  | Event_identity_conflict of { event_id : string }
  | Transition_identity_conflict of { transition_id : string }
  | Transition_source_conflict of
      { transition_id : string
      ; source_index : int
      }
  | Transition_cardinality_violation of
      { transition_id : string
      ; expected : int
      ; actual : int
      }
  | Commit_outcome_indeterminate of error
  | Cleanup_failure of { primary : error; cleanup : error }

type discovery =
  { keeper_names : string list
  ; errors : error list
  }

let ( let* ) = Result.bind
module String_set = Set.Make (String)

(* v4 is the first mergeable authority for the canonical v2 event-queue
   stimulus identity. Draft v3 databases used the earlier digest preimage;
   accepting one here would split a single queued stimulus across two durable
   identities. There is intentionally no compatibility migration. *)
let database_schema = "keeper.reaction_ledger.sqlite.v4"
let database_user_version = 4L
let database_application_id = 0x4d43524cL
let database_file = Common.keeper_reaction_database_filename
let microseconds_per_second = 1_000_000.

let stimulus_kind_to_string = function
  | Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | Fusion_completed -> "fusion_completed"
  | Bg_completed -> "bg_completed"
  | Schedule_due -> "schedule_due"
  | Connector_attention -> "connector_attention"
  | Hitl_resolved -> "hitl_resolved"
  | Failure_judgment -> "failure_judgment"
  | Manual_compaction -> "manual_compaction"
  | Goal_assigned -> "goal_assigned"
;;

let stimulus_kind_of_string = function
  | "board_signal" -> Some Board_signal
  | "bootstrap" -> Some Bootstrap
  | "fusion_completed" -> Some Fusion_completed
  | "bg_completed" -> Some Bg_completed
  | "schedule_due" -> Some Schedule_due
  | "connector_attention" -> Some Connector_attention
  | "hitl_resolved" -> Some Hitl_resolved
  | "failure_judgment" -> Some Failure_judgment
  | "manual_compaction" -> Some Manual_compaction
  | "goal_assigned" -> Some Goal_assigned
  | _ -> None
;;

let reaction_kind_to_string = function
  | Turn_started -> "turn_started"
  | Event_queue_ack -> "event_queue_ack"
  | Event_queue_requeued -> "event_queue_requeued"
  | Event_queue_escalated -> "event_queue_escalated"
  | Cursor_ack -> "cursor_ack"
;;

let reaction_kind_of_string = function
  | "turn_started" -> Some Turn_started
  | "event_queue_ack" -> Some Event_queue_ack
  | "event_queue_requeued" -> Some Event_queue_requeued
  | "event_queue_escalated" -> Some Event_queue_escalated
  | "cursor_ack" -> Some Cursor_ack
  | _ -> None
;;

let urgency_to_string = function
  | Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"
;;

let urgency_of_string = function
  | "immediate" -> Some Immediate
  | "normal" -> Some Normal
  | "low" -> Some Low
  | _ -> None
;;

let settlement_kind_to_string = function
  | Ack -> "ack"
  | Requeue -> "requeue"
  | Escalate -> "escalate"
;;

let settlement_kind_of_string = function
  | "ack" -> Some Ack
  | "requeue" -> Some Requeue
  | "escalate" -> Some Escalate
  | _ -> None
;;

let reaction_kind_of_settlement = function
  | Ack -> Event_queue_ack
  | Requeue -> Event_queue_requeued
  | Escalate -> Event_queue_escalated
;;

let path_operation_to_string = function
  | Inspect_parent -> "inspect_parent"
  | Prepare_parent -> "prepare_parent"
  | Inspect_database -> "inspect_database"
  | Inspect_sidecar -> "inspect_sidecar"
  | Inspect_lock -> "inspect_lock"
  | Prepare_lock -> "prepare_lock"
  | Prepare_staging -> "prepare_staging"
  | Validate_identity -> "validate_identity"
  | Publish_database -> "publish_database"
;;

let sqlite_operation_to_string = function
  | Open_database -> "open_database"
  | Configure_connection -> "configure_connection"
  | Initialize_schema -> "initialize_schema"
  | Validate_schema -> "validate_schema"
  | Prepare_statement -> "prepare_statement"
  | Bind_parameter -> "bind_parameter"
  | Step_statement -> "step_statement"
  | Begin_transaction -> "begin_transaction"
  | Commit_transaction -> "commit_transaction"
  | Rollback_transaction -> "rollback_transaction"
  | Finalize_statement -> "finalize_statement"
  | Close_database -> "close_database"
;;

let rec error_to_string = function
  | Invalid_keeper_name detail -> "invalid keeper name: " ^ detail
  | Invalid_event_identity { field } -> "empty reaction event identity field: " ^ field
  | Invalid_timestamp { field; value } ->
    Printf.sprintf "invalid reaction timestamp %s=%g" field value
  | Invalid_transition detail -> "invalid reaction transition: " ^ detail
  | Lock_failure error ->
    "reaction database lock failure: "
    ^ File_lock_eio.durable_lock_error_to_string error
  | Path_failure { operation; path; detail } ->
    Printf.sprintf
      "reaction database path failure operation=%s path=%s: %s"
      (path_operation_to_string operation)
      path
      detail
  | Database_identity_changed path ->
    "reaction database identity changed while open: " ^ path
  | Orphan_database_sidecars { database_path; sidecars } ->
    Printf.sprintf
      "reaction database is absent but sidecars remain path=%s sidecars=[%s]"
      database_path
      (String.concat "," sidecars)
  | Application_id_mismatch { expected; actual } ->
    Printf.sprintf
      "reaction database application_id mismatch expected=%Ld actual=%Ld"
      expected
      actual
  | User_version_mismatch { expected; actual } ->
    Printf.sprintf
      "reaction database user_version mismatch expected=%Ld actual=%Ld"
      expected
      actual
  | Keeper_identity_mismatch { expected; actual } ->
    Printf.sprintf
      "reaction database keeper identity mismatch expected=%s actual=%s"
      expected
      actual
  | Schema_mismatch detail -> "reaction database schema mismatch: " ^ detail
  | Integrity_failure detail -> "reaction database integrity failure: " ^ detail
  | Sqlite_failure { operation; rc; detail } ->
    Printf.sprintf
      "SQLite reaction operation=%s rc=%s: %s"
      (sqlite_operation_to_string operation)
      (match rc with
       | None -> "exception"
       | Some value -> Sqlite3.Rc.to_string value)
      detail
  | Event_identity_conflict { event_id } ->
    "reaction event identity conflict: " ^ event_id
  | Transition_identity_conflict { transition_id } ->
    "reaction transition identity conflict: " ^ transition_id
  | Transition_source_conflict { transition_id; source_index } ->
    Printf.sprintf
      "reaction transition source conflict transition=%s index=%d"
      transition_id
      source_index
  | Transition_cardinality_violation { transition_id; expected; actual } ->
    Printf.sprintf
      "reaction transition cardinality violation transition=%s expected=%d actual=%d"
      transition_id
      expected
      actual
  | Commit_outcome_indeterminate cause ->
    "reaction transaction commit outcome indeterminate: " ^ error_to_string cause
  | Cleanup_failure { primary; cleanup } ->
    Printf.sprintf
      "%s; cleanup also failed: %s"
      (error_to_string primary)
      (error_to_string cleanup)
;;

let sqlite_failure ?rc operation detail =
  Sqlite_failure { operation; rc; detail }
;;

let sqlite_rc_failure operation db rc =
  sqlite_failure ~rc operation (Sqlite3.errmsg db)
;;

let combine_cleanup primary cleanup =
  match primary, cleanup with
  | Ok value, Ok () -> Ok value
  | Error error, Ok () -> Error error
  | Ok _, Error error -> Error error
  | Error primary, Error cleanup -> Error (Cleanup_failure { primary; cleanup })
;;

let non_empty field value =
  if String.equal value "" then Error (Invalid_event_identity { field }) else Ok ()
;;

let timestamp_to_microseconds ~field value =
  let scaled = Float.round (value *. microseconds_per_second) in
  if
    (not (Float.is_finite value))
    || not (Float.is_finite scaled)
    || Float.compare scaled (Int64.to_float Int64.min_int) <= 0
    || Float.compare scaled (Int64.to_float Int64.max_int) >= 0
  then Error (Invalid_timestamp { field; value })
  else Ok (Int64.of_float scaled)
;;

let timestamp_of_microseconds value =
  Int64.to_float value /. microseconds_per_second
;;

let normalize_cursor (cursor : cursor) =
  let* cursor_ts_us =
    timestamp_to_microseconds ~field:"cursor_ts" cursor.cursor_ts
  in
  Ok { cursor with cursor_ts = timestamp_of_microseconds cursor_ts_us }
;;

let compare_normalized_cursor (left : cursor) (right : cursor) =
  match Float.compare left.cursor_ts right.cursor_ts with
  | 0 -> Option.compare String.compare left.post_id right.post_id
  | ordering -> ordering
;;

let cursor_identity_id (cursor : cursor) =
  let* cursor_ts_us =
    timestamp_to_microseconds ~field:"cursor_ts" cursor.cursor_ts
  in
  let canonical =
    `Assoc
      [ "cursor_ts_unix_us", `Intlit (Int64.to_string cursor_ts_us)
      ; ( "post_id"
        , match cursor.post_id with
          | None -> `Null
          | Some value -> `String value )
      ]
    |> Yojson.Safe.to_string
  in
  Ok
    ("keeper-cursor:sha256:"
     ^ Digestif.SHA256.(digest_string canonical |> to_hex))
;;

let database_path ~base_path ~keeper_name =
  match Keeper_id.Keeper_name.of_string keeper_name with
  | Error detail -> Error (Invalid_keeper_name detail)
  | Ok keeper_name ->
    let keeper_name = Keeper_id.Keeper_name.to_string keeper_name in
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         database_file)
;;

type regular_path_observation =
  | Path_absent
  | Regular_path of Unix.stats

let unix_file_kind_to_string = function
  | Unix.S_REG -> "regular"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let private_file_rejection_without_link_count stat =
  if stat.Unix.st_kind <> Unix.S_REG
  then Some ("expected regular file, observed " ^ unix_file_kind_to_string stat.st_kind)
  else if stat.Unix.st_uid <> Unix.geteuid ()
  then
    Some
      (Printf.sprintf
         "owner mismatch expected_uid=%d actual_uid=%d"
         (Unix.geteuid ())
         stat.Unix.st_uid)
  else if stat.Unix.st_perm land 0o777 <> 0o600
  then
    Some
      (Printf.sprintf
         "permissions must be 0600, observed %04o"
         (stat.Unix.st_perm land 0o777))
  else None
;;

let private_file_rejection stat =
  match private_file_rejection_without_link_count stat with
  | Some _ as rejection -> rejection
  | None when stat.Unix.st_nlink <> 1 ->
    Some (Printf.sprintf "link count must be one, observed %d" stat.Unix.st_nlink)
  | None -> None
;;

let inspect_regular_or_absent ~operation path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Path_absent
  | exception exn ->
    Error (Path_failure { operation; path; detail = Printexc.to_string exn })
  | stat ->
    (match private_file_rejection stat with
     | None -> Ok (Regular_path stat)
     | Some detail ->
       Error
         (Path_failure
            { operation
            ; path
            ; detail
            }))
;;

type private_file_prepare_outcome =
  | Private_file_created
  | Private_file_existing

let prepare_private_file ~operation path =
  let validate_open_file fd =
    let fd_stat = Unix.fstat fd in
    let path_stat = Unix.lstat path in
    match private_file_rejection fd_stat with
    | Some detail -> Error detail
    | None
      when fd_stat.Unix.st_kind <> Unix.S_REG
           || path_stat.Unix.st_kind <> Unix.S_REG
           || fd_stat.Unix.st_dev <> path_stat.Unix.st_dev
           || fd_stat.Unix.st_ino <> path_stat.Unix.st_ino ->
      Error "opened file and path identities differ"
    | None -> Ok ()
  in
  try
    let fd =
      Unix.openfile
        path
        [ Unix.O_CLOEXEC; Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR ]
        0o600
    in
    let validation =
      match validate_open_file fd with
      | Ok () -> Ok Private_file_created
      | Error detail -> Error (Path_failure { operation; path; detail })
      | exception exn ->
        Error (Path_failure { operation; path; detail = Printexc.to_string exn })
    in
    let close =
      try
        Unix.close fd;
        Ok ()
      with exn ->
        Error (Path_failure { operation; path; detail = Printexc.to_string exn })
    in
    combine_cleanup validation close
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) ->
    let* observed = inspect_regular_or_absent ~operation path in
    (match observed with
     | Regular_path _ -> Ok Private_file_existing
     | Path_absent ->
       Error
         (Path_failure
            { operation
            ; path
            ; detail = "exclusive create reported EEXIST but path is absent"
            }))
  | exn ->
    Error
      (Path_failure
         { operation
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let same_regular_identity left right =
  left.Unix.st_kind = Unix.S_REG
  && right.Unix.st_kind = Unix.S_REG
  && left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
;;

type parent_observation =
  | Parent_absent
  | Parent_present

let inspect_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  try
    match Fs_compat.inspect_owned_directory_chain ~ownership_root parent with
    | Ok Fs_compat.Owned_directory_missing -> Ok Parent_absent
    | Ok (Fs_compat.Owned_directory _) -> Ok Parent_present
    | Error rejection ->
      Error
        (Path_failure
           { operation = Inspect_parent
           ; path = parent
           ; detail = Fs_compat.owned_directory_chain_rejection_to_string rejection
           })
  with exn ->
    Error
      (Path_failure
         { operation = Inspect_parent
         ; path = parent
         ; detail = Printexc.to_string exn
         })
;;

let directory_chain_error_to_string = function
  | Keeper_fs_durable_directory.Non_directory_ancestor { path } ->
    "non-directory ancestor: " ^ path
  | Keeper_fs_durable_directory.Outside_ownership_root { ownership_root; path } ->
    Printf.sprintf "path %s is outside ownership root %s" path ownership_root
  | Keeper_fs_durable_directory.Missing_root { path } -> "missing root: " ^ path
  | Keeper_fs_durable_directory.Creation_not_observed { path } ->
    "directory creation was not observed: " ^ path
;;

let directory_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed error ->
    directory_chain_error_to_string error
  | Keeper_fs_durable_directory.Operation_failed (exn, _) -> Printexc.to_string exn
;;

let ensure_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  match
    Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ())
      ~ownership_root
      parent
  with
  | Error failure ->
    Error
      (Path_failure
         { operation = Prepare_parent
         ; path = parent
         ; detail = directory_failure_to_string failure
         })
  | Ok _ ->
    let* observed = inspect_owned_parent ~ownership_root path in
    (match observed with
     | Parent_present -> Ok ()
     | Parent_absent ->
       Error
         (Path_failure
            { operation = Prepare_parent
            ; path = parent
            ; detail = "directory preparation returned without a visible directory"
            }))
;;

let database_sidecars path = [ path ^ "-journal"; path ^ "-wal"; path ^ "-shm" ]

let inspect_database_sidecars path =
  List.fold_left
    (fun state sidecar ->
      let* present = state in
      let* observed = inspect_regular_or_absent ~operation:Inspect_sidecar sidecar in
      match observed with
      | Path_absent -> Ok present
      | Regular_path _ -> Ok (sidecar :: present))
    (Ok [])
    (database_sidecars path)
  |> Result.map List.rev
;;

let inspect_database_paths ~ownership_root path =
  let* parent = inspect_owned_parent ~ownership_root path in
  match parent with
  | Parent_absent -> Ok Path_absent
  | Parent_present ->
    let* database = inspect_regular_or_absent ~operation:Inspect_database path in
    let* sidecars = inspect_database_sidecars path in
    (match database, sidecars with
     | Path_absent, _ :: _ -> Error (Orphan_database_sidecars { database_path = path; sidecars })
     | Path_absent, [] | Regular_path _, _ -> Ok database)
;;

let discover_keeper_names ~base_path =
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  Eio_guard.run_in_systhread (fun () ->
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path keepers_dir with
    | Ok Fs_compat.Owned_directory_missing -> { keeper_names = []; errors = [] }
    | Error rejection ->
      { keeper_names = []
      ; errors =
          [ Path_failure
              { operation = Inspect_parent
              ; path = keepers_dir
              ; detail = Fs_compat.owned_directory_chain_rejection_to_string rejection
              }
          ]
      }
    | Ok (Fs_compat.Owned_directory _) ->
      (match Sys.readdir keepers_dir with
       | exception exn ->
         { keeper_names = []
         ; errors =
             [ Path_failure
                 { operation = Inspect_parent
                 ; path = keepers_dir
                 ; detail = Printexc.to_string exn
                 }
             ]
         }
       | entries ->
         let keeper_names, errors =
           Array.fold_left
             (fun (names, errors) entry ->
               let keeper_path = Filename.concat keepers_dir entry in
               match Unix.lstat keeper_path with
               | exception exn ->
                 ( names
                 , Path_failure
                     { operation = Inspect_parent
                     ; path = keeper_path
                     ; detail = Printexc.to_string exn
                     }
                   :: errors )
               | { Unix.st_kind = Unix.S_REG; _ } -> names, errors
               | { Unix.st_kind = Unix.S_DIR; _ } ->
                 let path = Filename.concat keeper_path database_file in
                 (match Keeper_id.Keeper_name.of_string entry with
                  | Error detail ->
                    (match Unix.lstat path with
                     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> names, errors
                     | exception exn ->
                       ( names
                       , Path_failure
                           { operation = Inspect_database
                           ; path
                           ; detail = Printexc.to_string exn
                           }
                         :: errors )
                     | _ -> names, Invalid_keeper_name detail :: errors)
                  | Ok keeper_name ->
                    (match inspect_database_paths ~ownership_root:base_path path with
                     | Ok Path_absent -> names, errors
                     | Ok (Regular_path _) ->
                       Keeper_id.Keeper_name.to_string keeper_name :: names, errors
                     | Error error -> names, error :: errors))
               | _ ->
                 ( names
                 , Path_failure
                     { operation = Inspect_parent
                     ; path = keeper_path
                     ; detail = "unexpected non-file keeper runtime entry"
                     }
                   :: errors ))
             ([], [])
             entries
         in
         { keeper_names = List.sort_uniq String.compare keeper_names
         ; errors = List.rev errors
         }))
;;

let sqlite_exec db ~operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_rc_failure operation db rc)
  | exception exn -> Error (sqlite_failure operation (Printexc.to_string exn))
;;

let sqlite_bind db stmt index data =
  match Sqlite3.bind stmt index data with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_rc_failure Bind_parameter db rc)
  | exception exn ->
    Error (sqlite_failure Bind_parameter (Printexc.to_string exn))
;;

let sqlite_expect_done db stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (sqlite_rc_failure Step_statement db rc)
  | exception exn -> Error (sqlite_failure Step_statement (Printexc.to_string exn))
;;

let sqlite_finalize db stmt =
  let result =
    match Sqlite3.finalize stmt with
    | rc when Sqlite3.Rc.is_success rc -> Ok ()
    | rc -> Error (sqlite_rc_failure Finalize_statement db rc)
    | exception exn ->
      Error (sqlite_failure Finalize_statement (Printexc.to_string exn))
  in
  (* See sqlite3 binding lifetime: keep the finalized statement reachable
     until after the native finalize call has returned. *)
  ignore (Sys.opaque_identity stmt);
  result
;;

let with_statement db sql body =
  match
    try Ok (Sqlite3.prepare db sql) with
    | exn -> Error (sqlite_failure Prepare_statement (Printexc.to_string exn))
  with
  | Error _ as error -> error
  | Ok stmt ->
    let body_result =
      try body stmt with
      | Eio.Cancel.Cancelled _ as exn ->
        (match sqlite_finalize db stmt with
         | Ok () -> ()
         | Error error ->
           Log.Keeper.error
             "reaction store statement finalize failed during cancellation: %s"
             (error_to_string error));
        raise exn
      | exn -> Error (sqlite_failure Step_statement (Printexc.to_string exn))
    in
    combine_cleanup body_result (sqlite_finalize db stmt)
;;

let sqlite_single_int64 db ~operation sql =
  with_statement db sql (fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let value = Sqlite3.column_int64 stmt 0 in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok value
       | rc -> Error (sqlite_rc_failure operation db rc))
    | rc -> Error (sqlite_rc_failure operation db rc))
;;

let sqlite_single_text db ~operation sql =
  with_statement db sql (fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW when not (Sqlite3.column_is_null stmt 0) ->
      let value = Sqlite3.column_text stmt 0 in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok value
       | rc -> Error (sqlite_rc_failure operation db rc))
    | Sqlite3.Rc.ROW -> Error (Schema_mismatch "unexpected NULL scalar")
    | rc -> Error (sqlite_rc_failure operation db rc))
;;

let meta_table_sql =
  "CREATE TABLE ledger_meta (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version TEXT NOT NULL, keeper_name TEXT NOT NULL CHECK (length(keeper_name) > 0)) STRICT"
;;

let transitions_table_sql =
  "CREATE TABLE transitions (transition_id TEXT PRIMARY KEY NOT NULL CHECK (length(transition_id) > 0), transition_event_id TEXT NOT NULL CHECK (length(transition_event_id) > 0), lease_id TEXT NOT NULL CHECK (length(lease_id) > 0), lease_sequence INTEGER NOT NULL CHECK (lease_sequence > 0), settled_at_unix_us INTEGER NOT NULL, settlement_kind TEXT NOT NULL CHECK (settlement_kind IN ('ack', 'requeue', 'escalate')), settlement_identity TEXT NOT NULL CHECK (length(settlement_identity) > 0), external_input_requested INTEGER NOT NULL CHECK (external_input_requested IN (0, 1)), source_count INTEGER NOT NULL CHECK (source_count > 0), CHECK (external_input_requested = 0 OR settlement_kind = 'escalate')) STRICT, WITHOUT ROWID"
;;

let events_table_sql =
  "CREATE TABLE events (sequence INTEGER PRIMARY KEY CHECK (sequence > 0), event_id TEXT NOT NULL CHECK (length(event_id) > 0), stimulus_id TEXT NOT NULL CHECK (length(stimulus_id) > 0), record_kind TEXT NOT NULL CHECK (record_kind IN ('stimulus', 'turn_started', 'transition_settlement', 'cursor_ack')), recorded_at_unix_us INTEGER NOT NULL, stimulus_kind TEXT CHECK (stimulus_kind IN ('board_signal', 'bootstrap', 'fusion_completed', 'bg_completed', 'schedule_due', 'connector_attention', 'hitl_resolved', 'failure_judgment', 'manual_compaction', 'goal_assigned')), post_id TEXT, urgency TEXT, arrived_at_unix_us INTEGER, board_updated_at_unix_us INTEGER, reaction_kind TEXT, transition_id TEXT, source_index INTEGER, source_count INTEGER, cursor_ts_unix_us INTEGER, cursor_post_id TEXT, FOREIGN KEY (stimulus_id, stimulus_kind, post_id) REFERENCES stimulus_state (stimulus_id, stimulus_kind, post_id), FOREIGN KEY (transition_id, source_count) REFERENCES transitions (transition_id, source_count), CHECK ((record_kind = 'stimulus' AND stimulus_kind IS NOT NULL AND post_id IS NOT NULL AND urgency IN ('immediate', 'normal', 'low') AND arrived_at_unix_us IS NOT NULL AND reaction_kind IS NULL AND transition_id IS NULL AND source_index IS NULL AND source_count IS NULL AND cursor_ts_unix_us IS NULL AND cursor_post_id IS NULL) OR (record_kind = 'turn_started' AND stimulus_kind IS NOT NULL AND post_id IS NOT NULL AND urgency IS NULL AND arrived_at_unix_us IS NULL AND board_updated_at_unix_us IS NULL AND reaction_kind = 'turn_started' AND transition_id IS NULL AND source_index IS NULL AND source_count IS NULL AND cursor_ts_unix_us IS NULL AND cursor_post_id IS NULL) OR (record_kind = 'transition_settlement' AND stimulus_kind IS NOT NULL AND post_id IS NOT NULL AND urgency IS NULL AND arrived_at_unix_us IS NULL AND board_updated_at_unix_us IS NULL AND reaction_kind IN ('event_queue_ack', 'event_queue_requeued', 'event_queue_escalated') AND transition_id IS NOT NULL AND source_index >= 0 AND source_index < source_count AND cursor_ts_unix_us IS NULL AND cursor_post_id IS NULL) OR (record_kind = 'cursor_ack' AND stimulus_kind IS NULL AND post_id IS NULL AND urgency IS NULL AND arrived_at_unix_us IS NULL AND board_updated_at_unix_us IS NULL AND reaction_kind = 'cursor_ack' AND transition_id IS NULL AND source_index IS NULL AND source_count IS NULL AND cursor_ts_unix_us IS NOT NULL))) STRICT"
;;

let cursor_state_table_sql =
  "CREATE TABLE cursor_state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), cursor_ts_unix_us INTEGER, cursor_post_id TEXT, CHECK (cursor_ts_unix_us IS NOT NULL OR cursor_post_id IS NULL)) STRICT"
;;

let ledger_summary_table_sql =
  "CREATE TABLE ledger_summary (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), row_count INTEGER NOT NULL CHECK (row_count >= 0), stimulus_count INTEGER NOT NULL CHECK (stimulus_count >= 0), reaction_count INTEGER NOT NULL CHECK (reaction_count >= 0), turn_started_count INTEGER NOT NULL CHECK (turn_started_count >= 0), event_queue_ack_count INTEGER NOT NULL CHECK (event_queue_ack_count >= 0), event_queue_requeue_count INTEGER NOT NULL CHECK (event_queue_requeue_count >= 0), event_queue_escalation_count INTEGER NOT NULL CHECK (event_queue_escalation_count >= 0), event_queue_external_input_count INTEGER NOT NULL CHECK (event_queue_external_input_count >= 0), cursor_ack_count INTEGER NOT NULL CHECK (cursor_ack_count >= 0), cursor_swept_stimulus_count INTEGER NOT NULL CHECK (cursor_swept_stimulus_count >= 0), orphan_reaction_stimulus_count INTEGER NOT NULL CHECK (orphan_reaction_stimulus_count >= 0), in_progress_stimulus_count INTEGER NOT NULL CHECK (in_progress_stimulus_count >= 0), acked_stimulus_count INTEGER NOT NULL CHECK (acked_stimulus_count >= 0), escalated_stimulus_count INTEGER NOT NULL CHECK (escalated_stimulus_count >= 0), external_input_requested_stimulus_count INTEGER NOT NULL CHECK (external_input_requested_stimulus_count >= 0), pending_stimulus_count INTEGER NOT NULL CHECK (pending_stimulus_count >= 0), latest_sequence INTEGER, latest_recorded_at_unix_us INTEGER, latest_stimulus_id TEXT, CHECK ((latest_sequence IS NULL AND latest_recorded_at_unix_us IS NULL AND latest_stimulus_id IS NULL) OR (latest_sequence > 0 AND latest_recorded_at_unix_us IS NOT NULL AND latest_stimulus_id IS NOT NULL AND length(latest_stimulus_id) > 0))) STRICT"
;;

let stimulus_state_table_sql =
  "CREATE TABLE stimulus_state (stimulus_id TEXT PRIMARY KEY NOT NULL CHECK (length(stimulus_id) > 0), stimulus_seen INTEGER NOT NULL CHECK (stimulus_seen IN (0, 1)), stimulus_sequence INTEGER, stimulus_kind TEXT NOT NULL CHECK (stimulus_kind IN ('board_signal', 'bootstrap', 'fusion_completed', 'bg_completed', 'schedule_due', 'connector_attention', 'hitl_resolved', 'failure_judgment', 'manual_compaction', 'goal_assigned')), post_id TEXT NOT NULL, board_updated_at_unix_us INTEGER, latest_handling_sequence INTEGER, latest_handling_state TEXT CHECK (latest_handling_state IN ('pending', 'in_progress', 'acked', 'escalated', 'external_input')), current_state TEXT NOT NULL CHECK (current_state IN ('orphan', 'pending', 'swept', 'in_progress', 'acked', 'escalated', 'external_input')), CHECK ((latest_handling_sequence IS NULL AND latest_handling_state IS NULL) OR (latest_handling_sequence > 0 AND latest_handling_state IS NOT NULL)), CHECK ((stimulus_seen = 0 AND stimulus_sequence IS NULL AND board_updated_at_unix_us IS NULL AND current_state = 'orphan') OR (stimulus_seen = 1 AND stimulus_sequence > 0 AND current_state <> 'orphan')), CHECK (stimulus_seen = 0 OR latest_handling_state IS NULL OR current_state = latest_handling_state)) STRICT, WITHOUT ROWID"
;;

let transitions_event_id_index_sql =
  "CREATE UNIQUE INDEX transitions_event_id ON transitions (transition_event_id)"
;;

let transitions_lease_id_index_sql =
  "CREATE UNIQUE INDEX transitions_lease_id ON transitions (lease_id)"
;;

let transitions_lease_sequence_index_sql =
  "CREATE UNIQUE INDEX transitions_lease_sequence ON transitions (lease_sequence)"
;;

let transitions_cardinality_index_sql =
  "CREATE UNIQUE INDEX transitions_identity_cardinality ON transitions (transition_id, source_count)"
;;

let events_event_id_index_sql =
  "CREATE UNIQUE INDEX events_event_id ON events (event_id)"
;;

let events_stimulus_sequence_index_sql =
  "CREATE INDEX events_stimulus_sequence ON events (stimulus_id, sequence)"
;;

let events_stimulus_identity_index_sql =
  "CREATE UNIQUE INDEX events_stimulus_identity ON events (stimulus_id) WHERE record_kind = 'stimulus'"
;;

let events_transition_source_index_sql =
  "CREATE UNIQUE INDEX events_transition_source ON events (transition_id, source_index) WHERE record_kind = 'transition_settlement'"
;;

let stimulus_state_cursor_sweep_index_sql =
  "CREATE INDEX stimulus_state_cursor_sweep ON stimulus_state (stimulus_kind, board_updated_at_unix_us, post_id) WHERE stimulus_seen = 1 AND latest_handling_sequence IS NULL"
;;

let stimulus_state_identity_index_sql =
  "CREATE UNIQUE INDEX stimulus_state_identity ON stimulus_state (stimulus_id, stimulus_kind, post_id)"
;;

let stimulus_state_pending_order_index_sql =
  "CREATE INDEX stimulus_state_pending_order ON stimulus_state (current_state, stimulus_sequence, stimulus_id)"
;;

let events_project_summary_trigger_sql =
  "CREATE TRIGGER events_project_summary AFTER INSERT ON events BEGIN UPDATE ledger_summary SET row_count = row_count + 1, stimulus_count = stimulus_count + CASE WHEN NEW.record_kind = 'stimulus' THEN 1 ELSE 0 END, reaction_count = reaction_count + CASE WHEN NEW.record_kind <> 'stimulus' THEN 1 ELSE 0 END, turn_started_count = turn_started_count + CASE WHEN NEW.record_kind = 'turn_started' THEN 1 ELSE 0 END, event_queue_ack_count = event_queue_ack_count + CASE WHEN NEW.reaction_kind = 'event_queue_ack' THEN 1 ELSE 0 END, event_queue_requeue_count = event_queue_requeue_count + CASE WHEN NEW.reaction_kind = 'event_queue_requeued' THEN 1 ELSE 0 END, event_queue_escalation_count = event_queue_escalation_count + CASE WHEN NEW.reaction_kind = 'event_queue_escalated' THEN 1 ELSE 0 END, event_queue_external_input_count = event_queue_external_input_count + CASE WHEN NEW.reaction_kind = 'event_queue_escalated' AND EXISTS (SELECT 1 FROM transitions WHERE transition_id = NEW.transition_id AND external_input_requested = 1) THEN 1 ELSE 0 END, cursor_ack_count = cursor_ack_count + CASE WHEN NEW.record_kind = 'cursor_ack' THEN 1 ELSE 0 END, latest_sequence = NEW.sequence, latest_recorded_at_unix_us = NEW.recorded_at_unix_us, latest_stimulus_id = NEW.stimulus_id WHERE singleton = 1; END"
;;

let events_project_stimulus_trigger_sql =
  "CREATE TRIGGER events_project_stimulus AFTER INSERT ON events WHEN NEW.record_kind = 'stimulus' BEGIN INSERT INTO stimulus_state(stimulus_id, stimulus_seen, stimulus_sequence, stimulus_kind, post_id, board_updated_at_unix_us, latest_handling_sequence, latest_handling_state, current_state) VALUES (NEW.stimulus_id, 1, NEW.sequence, NEW.stimulus_kind, NEW.post_id, NEW.board_updated_at_unix_us, NULL, NULL, CASE WHEN NEW.stimulus_kind = 'board_signal' AND NEW.board_updated_at_unix_us IS NOT NULL AND (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) IS NOT NULL AND (NEW.board_updated_at_unix_us < (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) OR (NEW.board_updated_at_unix_us = (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) AND (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1) IS NOT NULL AND NEW.post_id <= (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1))) THEN 'swept' ELSE 'pending' END) ON CONFLICT(stimulus_id) DO UPDATE SET stimulus_seen = 1, stimulus_sequence = excluded.stimulus_sequence, stimulus_kind = excluded.stimulus_kind, post_id = excluded.post_id, board_updated_at_unix_us = excluded.board_updated_at_unix_us, current_state = CASE WHEN stimulus_state.latest_handling_state IS NOT NULL THEN stimulus_state.latest_handling_state WHEN excluded.stimulus_kind = 'board_signal' AND excluded.board_updated_at_unix_us IS NOT NULL AND (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) IS NOT NULL AND (excluded.board_updated_at_unix_us < (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) OR (excluded.board_updated_at_unix_us = (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) AND (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1) IS NOT NULL AND excluded.post_id <= (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1))) THEN 'swept' ELSE 'pending' END; END"
;;

let events_project_handling_trigger_sql =
  "CREATE TRIGGER events_project_handling AFTER INSERT ON events WHEN NEW.record_kind IN ('turn_started', 'transition_settlement') BEGIN INSERT INTO stimulus_state(stimulus_id, stimulus_seen, stimulus_sequence, stimulus_kind, post_id, board_updated_at_unix_us, latest_handling_sequence, latest_handling_state, current_state) VALUES (NEW.stimulus_id, 0, NULL, NEW.stimulus_kind, NEW.post_id, NULL, NEW.sequence, CASE WHEN NEW.reaction_kind = 'event_queue_requeued' THEN 'pending' WHEN NEW.reaction_kind = 'event_queue_escalated' AND EXISTS (SELECT 1 FROM transitions WHERE transition_id = NEW.transition_id AND external_input_requested = 1) THEN 'external_input' WHEN NEW.reaction_kind = 'event_queue_escalated' THEN 'escalated' WHEN NEW.reaction_kind = 'event_queue_ack' THEN 'acked' ELSE 'in_progress' END, 'orphan') ON CONFLICT(stimulus_id) DO UPDATE SET stimulus_kind = CASE WHEN stimulus_state.stimulus_seen = 0 THEN excluded.stimulus_kind ELSE stimulus_state.stimulus_kind END, post_id = CASE WHEN stimulus_state.stimulus_seen = 0 THEN excluded.post_id ELSE stimulus_state.post_id END, latest_handling_sequence = excluded.latest_handling_sequence, latest_handling_state = excluded.latest_handling_state, current_state = CASE WHEN stimulus_state.stimulus_seen = 0 THEN 'orphan' ELSE excluded.latest_handling_state END; END"
;;

let events_project_cursor_trigger_sql =
  "CREATE TRIGGER events_project_cursor AFTER INSERT ON events WHEN NEW.record_kind = 'cursor_ack' BEGIN UPDATE cursor_state SET cursor_ts_unix_us = NEW.cursor_ts_unix_us, cursor_post_id = NEW.cursor_post_id WHERE singleton = 1 AND (cursor_ts_unix_us IS NULL OR NEW.cursor_ts_unix_us > cursor_ts_unix_us OR (NEW.cursor_ts_unix_us = cursor_ts_unix_us AND NEW.cursor_post_id IS NOT NULL AND (cursor_post_id IS NULL OR NEW.cursor_post_id > cursor_post_id))); UPDATE stimulus_state SET current_state = 'swept' WHERE stimulus_seen = 1 AND latest_handling_sequence IS NULL AND stimulus_kind = 'board_signal' AND board_updated_at_unix_us IS NOT NULL AND (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) IS NOT NULL AND (board_updated_at_unix_us < (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) OR (board_updated_at_unix_us = (SELECT cursor_ts_unix_us FROM cursor_state WHERE singleton = 1) AND (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1) IS NOT NULL AND post_id <= (SELECT cursor_post_id FROM cursor_state WHERE singleton = 1))); END"
;;

let stimulus_state_count_insert_trigger_sql =
  "CREATE TRIGGER stimulus_state_count_insert AFTER INSERT ON stimulus_state BEGIN UPDATE ledger_summary SET orphan_reaction_stimulus_count = orphan_reaction_stimulus_count + (NEW.current_state = 'orphan'), pending_stimulus_count = pending_stimulus_count + (NEW.current_state = 'pending'), cursor_swept_stimulus_count = cursor_swept_stimulus_count + (NEW.current_state = 'swept'), in_progress_stimulus_count = in_progress_stimulus_count + (NEW.current_state = 'in_progress'), acked_stimulus_count = acked_stimulus_count + (NEW.current_state = 'acked'), escalated_stimulus_count = escalated_stimulus_count + (NEW.current_state = 'escalated'), external_input_requested_stimulus_count = external_input_requested_stimulus_count + (NEW.current_state = 'external_input') WHERE singleton = 1; END"
;;

let stimulus_state_count_update_trigger_sql =
  "CREATE TRIGGER stimulus_state_count_update AFTER UPDATE OF current_state ON stimulus_state WHEN OLD.current_state <> NEW.current_state BEGIN UPDATE ledger_summary SET orphan_reaction_stimulus_count = orphan_reaction_stimulus_count - (OLD.current_state = 'orphan') + (NEW.current_state = 'orphan'), pending_stimulus_count = pending_stimulus_count - (OLD.current_state = 'pending') + (NEW.current_state = 'pending'), cursor_swept_stimulus_count = cursor_swept_stimulus_count - (OLD.current_state = 'swept') + (NEW.current_state = 'swept'), in_progress_stimulus_count = in_progress_stimulus_count - (OLD.current_state = 'in_progress') + (NEW.current_state = 'in_progress'), acked_stimulus_count = acked_stimulus_count - (OLD.current_state = 'acked') + (NEW.current_state = 'acked'), escalated_stimulus_count = escalated_stimulus_count - (OLD.current_state = 'escalated') + (NEW.current_state = 'escalated'), external_input_requested_stimulus_count = external_input_requested_stimulus_count - (OLD.current_state = 'external_input') + (NEW.current_state = 'external_input') WHERE singleton = 1; END"
;;

let expected_schema_objects =
  [ "index", "events_event_id", events_event_id_index_sql
  ; "index", "events_stimulus_identity", events_stimulus_identity_index_sql
  ; "index", "events_stimulus_sequence", events_stimulus_sequence_index_sql
  ; "index", "events_transition_source", events_transition_source_index_sql
  ; "index", "stimulus_state_cursor_sweep", stimulus_state_cursor_sweep_index_sql
  ; "index", "stimulus_state_identity", stimulus_state_identity_index_sql
  ; "index", "stimulus_state_pending_order", stimulus_state_pending_order_index_sql
  ; "index", "transitions_event_id", transitions_event_id_index_sql
  ; "index", "transitions_identity_cardinality", transitions_cardinality_index_sql
  ; "index", "transitions_lease_id", transitions_lease_id_index_sql
  ; "index", "transitions_lease_sequence", transitions_lease_sequence_index_sql
  ; "table", "cursor_state", cursor_state_table_sql
  ; "table", "events", events_table_sql
  ; "table", "ledger_meta", meta_table_sql
  ; "table", "ledger_summary", ledger_summary_table_sql
  ; "table", "stimulus_state", stimulus_state_table_sql
  ; "table", "transitions", transitions_table_sql
  ; "trigger", "events_project_cursor", events_project_cursor_trigger_sql
  ; "trigger", "events_project_handling", events_project_handling_trigger_sql
  ; "trigger", "events_project_stimulus", events_project_stimulus_trigger_sql
  ; "trigger", "events_project_summary", events_project_summary_trigger_sql
  ; "trigger", "stimulus_state_count_insert", stimulus_state_count_insert_trigger_sql
  ; "trigger", "stimulus_state_count_update", stimulus_state_count_update_trigger_sql
  ]
;;

let configure_connection db =
  let* mode =
    sqlite_single_text
      db
      ~operation:Configure_connection
      "PRAGMA journal_mode=DELETE"
  in
  let* () =
    if String.equal mode "delete"
    then Ok ()
    else Error (Integrity_failure ("SQLite refused DELETE journal mode: " ^ mode))
  in
  let* () =
    sqlite_exec db ~operation:Configure_connection "PRAGMA synchronous=EXTRA"
  in
  let* () =
    sqlite_exec db ~operation:Configure_connection "PRAGMA foreign_keys=ON"
  in
  let* () =
    sqlite_exec db ~operation:Configure_connection "PRAGMA trusted_schema=OFF"
  in
  let* synchronous =
    sqlite_single_int64 db ~operation:Configure_connection "PRAGMA synchronous"
  in
  let* foreign_keys =
    sqlite_single_int64 db ~operation:Configure_connection "PRAGMA foreign_keys"
  in
  let* trusted_schema =
    sqlite_single_int64 db ~operation:Configure_connection "PRAGMA trusted_schema"
  in
  if not (Int64.equal synchronous 3L)
  then Error (Integrity_failure "SQLite synchronous mode is not EXTRA")
  else if not (Int64.equal foreign_keys 1L)
  then Error (Integrity_failure "SQLite foreign key enforcement is disabled")
  else if not (Int64.equal trusted_schema 0L)
  then Error (Integrity_failure "SQLite trusted_schema is enabled")
  else Ok ()
;;

let initialize_database db ~keeper_name ~path =
  let* () = sqlite_exec db ~operation:Begin_transaction "BEGIN EXCLUSIVE" in
  let body =
    let* () = sqlite_exec db ~operation:Initialize_schema meta_table_sql in
    let* () = sqlite_exec db ~operation:Initialize_schema transitions_table_sql in
    let* () = sqlite_exec db ~operation:Initialize_schema events_table_sql in
    let* () = sqlite_exec db ~operation:Initialize_schema cursor_state_table_sql in
    let* () = sqlite_exec db ~operation:Initialize_schema ledger_summary_table_sql in
    let* () = sqlite_exec db ~operation:Initialize_schema stimulus_state_table_sql in
    let* () =
      List.fold_left
        (fun state (_, _, sql) ->
          let* () = state in
          sqlite_exec db ~operation:Initialize_schema sql)
        (Ok ())
        (List.filter
           (fun (kind, _, _) ->
             String.equal kind "index" || String.equal kind "trigger")
           expected_schema_objects)
    in
    let* () =
      with_statement db
        "INSERT INTO ledger_meta(singleton, schema_version, keeper_name) VALUES (1, ?, ?)"
        (fun stmt ->
          let* () = sqlite_bind db stmt 1 (Sqlite3.Data.TEXT database_schema) in
          let* () = sqlite_bind db stmt 2 (Sqlite3.Data.TEXT keeper_name) in
          sqlite_expect_done db stmt)
    in
    let* () =
      sqlite_exec
        db
        ~operation:Initialize_schema
        "INSERT INTO cursor_state(singleton, cursor_ts_unix_us, cursor_post_id) VALUES (1, NULL, NULL)"
    in
    let* () =
      sqlite_exec
        db
        ~operation:Initialize_schema
        "INSERT INTO ledger_summary(singleton, row_count, stimulus_count, reaction_count, turn_started_count, event_queue_ack_count, event_queue_requeue_count, event_queue_escalation_count, event_queue_external_input_count, cursor_ack_count, cursor_swept_stimulus_count, orphan_reaction_stimulus_count, in_progress_stimulus_count, acked_stimulus_count, escalated_stimulus_count, external_input_requested_stimulus_count, pending_stimulus_count, latest_sequence, latest_recorded_at_unix_us, latest_stimulus_id) VALUES (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, NULL)"
    in
    let* () =
      sqlite_exec
        db
        ~operation:Initialize_schema
        (Printf.sprintf "PRAGMA application_id=%Ld" database_application_id)
    in
    let* () =
      sqlite_exec
        db
        ~operation:Initialize_schema
        (Printf.sprintf "PRAGMA user_version=%Ld" database_user_version)
    in
    sqlite_exec db ~operation:Commit_transaction "COMMIT"
  in
  match body with
  | Ok () ->
    (try
       Keeper_fs_durable_directory.fsync_directory (Filename.dirname path);
       Ok ()
     with exn ->
       Error
         (Path_failure
            { operation = Publish_database
            ; path
            ; detail = Printexc.to_string exn
            }))
  | Error primary ->
    combine_cleanup
      (Error primary)
      (sqlite_exec db ~operation:Rollback_transaction "ROLLBACK")
;;

let full_schema_validation_count = Atomic.make 0

let read_schema_objects db =
  Atomic.incr full_schema_validation_count;
  with_statement db
    "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
    (fun stmt ->
      let rec loop acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok (List.rev acc)
        | Sqlite3.Rc.ROW ->
          if Sqlite3.column_is_null stmt 2
          then Error (Schema_mismatch "schema object has no canonical SQL")
          else
            loop
              (( Sqlite3.column_text stmt 0
               , Sqlite3.column_text stmt 1
               , Sqlite3.column_text stmt 2 )
               :: acc)
        | rc -> Error (sqlite_rc_failure Validate_schema db rc)
      in
      loop [])
;;

type database_validation_stamp =
  { sqlite_schema_version : int64
  ; application_id : int64
  ; user_version : int64
  ; keeper_name : string
  ; store_schema : string
  }

let read_database_validation_stamp_after_schema_version db ~sqlite_schema_version =
  let* application_id =
    sqlite_single_int64 db ~operation:Validate_schema "PRAGMA application_id"
  in
  let* user_version =
    sqlite_single_int64 db ~operation:Validate_schema "PRAGMA user_version"
  in
  let* keeper_name =
    sqlite_single_text
      db
      ~operation:Validate_schema
      "SELECT keeper_name FROM ledger_meta WHERE singleton = 1"
  in
  let* store_schema =
    sqlite_single_text
      db
      ~operation:Validate_schema
      "SELECT schema_version FROM ledger_meta WHERE singleton = 1"
  in
  Ok
    { sqlite_schema_version
    ; application_id
    ; user_version
    ; keeper_name
    ; store_schema
    }
;;

let read_database_validation_stamp db =
  let* sqlite_schema_version =
    sqlite_single_int64 db ~operation:Validate_schema "PRAGMA schema_version"
  in
  read_database_validation_stamp_after_schema_version db ~sqlite_schema_version
;;

let equal_database_validation_stamp left right =
  Int64.equal left.sqlite_schema_version right.sqlite_schema_version
  && Int64.equal left.application_id right.application_id
  && Int64.equal left.user_version right.user_version
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.store_schema right.store_schema
;;

let cached_database_stamp_matches db expected =
  let* sqlite_schema_version =
    sqlite_single_int64 db ~operation:Validate_schema "PRAGMA schema_version"
  in
  if not (Int64.equal sqlite_schema_version expected.sqlite_schema_version)
  then Ok false
  else
    let* observed =
      read_database_validation_stamp_after_schema_version db ~sqlite_schema_version
    in
    Ok (equal_database_validation_stamp observed expected)
;;

let validate_database db ~keeper_name =
  let* stamp = read_database_validation_stamp db in
  if not (Int64.equal stamp.application_id database_application_id)
  then
    Error
      (Application_id_mismatch
         { expected = database_application_id; actual = stamp.application_id })
  else if not (Int64.equal stamp.user_version database_user_version)
  then
    Error
      (User_version_mismatch
         { expected = database_user_version; actual = stamp.user_version })
  else if not (String.equal stamp.keeper_name keeper_name)
  then
    Error
      (Keeper_identity_mismatch { expected = keeper_name; actual = stamp.keeper_name })
  else if not (String.equal stamp.store_schema database_schema)
  then Error (Schema_mismatch ("unsupported schema version: " ^ stamp.store_schema))
  else
    let* meta_count =
      sqlite_single_int64
        db
        ~operation:Validate_schema
        "SELECT COUNT(*) FROM ledger_meta"
    in
    if not (Int64.equal meta_count 1L)
    then Error (Schema_mismatch "ledger_meta must contain exactly one row")
    else
      let* summary_count =
        sqlite_single_int64
          db
          ~operation:Validate_schema
          "SELECT COUNT(*) FROM ledger_summary"
      in
      let* cursor_count =
        sqlite_single_int64
          db
          ~operation:Validate_schema
          "SELECT COUNT(*) FROM cursor_state"
      in
      if not (Int64.equal summary_count 1L)
      then Error (Schema_mismatch "ledger_summary must contain exactly one row")
      else if not (Int64.equal cursor_count 1L)
      then Error (Schema_mismatch "cursor_state must contain exactly one row")
      else
        let* objects = read_schema_objects db in
        if objects <> expected_schema_objects
        then Error (Schema_mismatch "schema objects do not match v3 exactly")
        else Ok stamp
;;

type open_database =
  { db : Sqlite3.db
  ; path : string
  ; ownership_root : string
  ; initial_identity : Unix.stats option
  }

type validated_database =
  { handle : open_database
  ; stamp : database_validation_stamp
  }

let fsync_parent ~operation path =
  try
    Keeper_fs_durable_directory.fsync_directory (Filename.dirname path);
    Ok ()
  with exn ->
    Error
      (Path_failure
         { operation
         ; path = Filename.dirname path
         ; detail = Printexc.to_string exn
         })
;;

let unlink_private_if_present ~operation path =
  let* observed = inspect_regular_or_absent ~operation path in
  match observed with
  | Path_absent -> Ok false
  | Regular_path _ ->
    (try
       Unix.unlink path;
       Ok true
     with
     | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
     | exn ->
       Error
         (Path_failure
            { operation
            ; path
            ; detail = Printexc.to_string exn
            }))
;;

let discard_private_database_files ~operation path =
  let* removed =
    List.fold_left
      (fun state candidate ->
        let* removed_any = state in
        let* removed = unlink_private_if_present ~operation candidate in
        Ok (removed_any || removed))
      (Ok false)
      (path :: database_sidecars path)
  in
  if removed then fsync_parent ~operation path else Ok ()
;;

let close_database_connection handle =
  let result =
    try
      if Sqlite3.db_close handle.db
      then Ok ()
      else Error (sqlite_failure Close_database "database reported a busy handle")
    with exn -> Error (sqlite_failure Close_database (Printexc.to_string exn))
  in
  (* See sqlite3 binding lifetime: keep the closed database reachable until
     after the native close call has returned. *)
  ignore (Sys.opaque_identity handle.db);
  result
;;

let close_database handle =
  let close_result = close_database_connection handle in
  let identity_result =
    let* parent = inspect_owned_parent ~ownership_root:handle.ownership_root handle.path in
    match parent with
    | Parent_absent -> Error (Database_identity_changed handle.path)
    | Parent_present ->
      let* final = inspect_regular_or_absent ~operation:Validate_identity handle.path in
      (match handle.initial_identity, final with
       | None, Regular_path _ -> Ok ()
       | Some initial, Regular_path final when same_regular_identity initial final -> Ok ()
       | None, Path_absent | Some _, Path_absent | Some _, Regular_path _ ->
         Error (Database_identity_changed handle.path))
  in
  combine_cleanup close_result identity_result
;;

let open_existing_database ~ownership_root ~path ~keeper_name =
  let* observed = inspect_database_paths ~ownership_root path in
  match observed with
  | Path_absent -> Ok None
  | Regular_path initial_identity ->
    let db_result =
      try
        Ok
          (Sqlite3.db_open ~mode:`NO_CREATE ~mutex:`FULL path)
      with exn -> Error (sqlite_failure Open_database (Printexc.to_string exn))
    in
    let* db = db_result in
    let handle =
      { db
      ; path
      ; ownership_root
      ; initial_identity = Some initial_identity
      }
    in
    let prepared =
      let* () = configure_connection db in
      validate_database db ~keeper_name
    in
    (match prepared with
     | Ok stamp -> Ok (Some { handle; stamp })
     | Error primary ->
       (match close_database handle with
        | Ok () -> Error primary
       | Error cleanup -> Error (Cleanup_failure { primary; cleanup })))
;;

let staging_path path = path ^ ".initializing"
let lock_path path = path ^ ".lock"

type publish_path_observation =
  | Publish_path_absent
  | Publish_path_regular of Unix.stats

type database_prelock_observation =
  | Prelock_database_absent
  | Prelock_database_ready
  | Prelock_interrupted_publish

let inspect_publish_path ~operation path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Publish_path_absent
  | exception exn ->
    Error (Path_failure { operation; path; detail = Printexc.to_string exn })
  | stat ->
    (match private_file_rejection_without_link_count stat with
     | Some detail -> Error (Path_failure { operation; path; detail })
     | None when stat.Unix.st_nlink = 1 || stat.Unix.st_nlink = 2 ->
       Ok (Publish_path_regular stat)
     | None ->
       Error
         (Path_failure
            { operation
            ; path
            ; detail =
                Printf.sprintf
                  "publish path link count must be one or two, observed %d"
                  stat.Unix.st_nlink
            }))
;;

let require_interrupted_publish_pair ~path final =
  let staging = staging_path path in
  let* staged = inspect_publish_path ~operation:Publish_database staging in
  match staged with
  | Publish_path_regular staged
    when final.Unix.st_nlink = 2
         && staged.Unix.st_nlink = 2
         && same_regular_identity final staged -> Ok ()
  | Publish_path_absent | Publish_path_regular _ ->
    Error
      (Path_failure
         { operation = Publish_database
         ; path
         ; detail =
             "database has two links without the exact same-inode initializing link"
         })
;;

let inspect_database_before_lock ~ownership_root path =
  let* parent = inspect_owned_parent ~ownership_root path in
  match parent with
  | Parent_absent -> Ok Prelock_database_absent
  | Parent_present ->
    let* database = inspect_publish_path ~operation:Inspect_database path in
    (match database with
     | Publish_path_absent ->
       let* sidecars = inspect_database_sidecars path in
       (match sidecars with
        | [] -> Ok Prelock_database_absent
        | _ :: _ -> Error (Orphan_database_sidecars { database_path = path; sidecars }))
     | Publish_path_regular stat when stat.Unix.st_nlink = 1 ->
       let* _ = inspect_database_sidecars path in
       Ok Prelock_database_ready
     | Publish_path_regular stat ->
       let* () = require_interrupted_publish_pair ~path stat in
       let* _ = inspect_database_sidecars path in
       Ok Prelock_interrupted_publish)
;;

let recover_interrupted_publish ~ownership_root ~path =
  let staging = staging_path path in
  let* final = inspect_publish_path ~operation:Publish_database path in
  let* staged = inspect_publish_path ~operation:Publish_database staging in
  match final, staged with
  | Publish_path_absent, Publish_path_absent -> Ok ()
  | Publish_path_absent, Publish_path_regular staged when staged.Unix.st_nlink = 1 ->
    Ok ()
  | Publish_path_absent, Publish_path_regular _ ->
    Error
      (Path_failure
         { operation = Publish_database
         ; path
         ; detail = "initializing path has multiple links but final database is absent"
         })
  | Publish_path_regular final, Publish_path_absent when final.Unix.st_nlink = 1 ->
    Ok ()
  | ( Publish_path_regular final
    , Publish_path_regular staged )
    when final.Unix.st_nlink = 1 && staged.Unix.st_nlink = 1 ->
    discard_private_database_files ~operation:Prepare_staging staging
  | ( Publish_path_regular final
    , Publish_path_regular staged )
    when final.Unix.st_nlink = 2
         && staged.Unix.st_nlink = 2
         && same_regular_identity final staged ->
    (try
       Unix.unlink staging;
       let* () = fsync_parent ~operation:Publish_database path in
       let* () =
         discard_private_database_files ~operation:Prepare_staging staging
       in
       let* observed = inspect_database_paths ~ownership_root path in
       (match observed with
        | Regular_path _ -> Ok ()
        | Path_absent ->
          Error
            (Path_failure
               { operation = Publish_database
               ; path
               ; detail = "published database disappeared during recovery"
               }))
     with exn ->
       Error
         (Path_failure
            { operation = Publish_database
            ; path
            ; detail = Printexc.to_string exn
            }))
  | Publish_path_regular _, Publish_path_absent
  | Publish_path_regular _, Publish_path_regular _ ->
    Error
      (Path_failure
         { operation = Publish_database
         ; path
         ; detail = "database and initializing paths are not a recoverable publish state"
         })
;;

let initialize_staged_database ~ownership_root ~path ~keeper_name =
  let staging = staging_path path in
  let* () =
    discard_private_database_files ~operation:Prepare_staging staging
  in
  let* prepared = prepare_private_file ~operation:Prepare_staging staging in
  let* () =
    match prepared with
    | Private_file_created -> Ok ()
    | Private_file_existing ->
      Error
        (Path_failure
           { operation = Prepare_staging
           ; path = staging
           ; detail = "staging path remained after locked cleanup"
           })
  in
  let* observed = inspect_regular_or_absent ~operation:Prepare_staging staging in
  let* initial_identity =
    match observed with
    | Regular_path stat -> Ok stat
    | Path_absent ->
      Error
        (Path_failure
           { operation = Prepare_staging
           ; path = staging
           ; detail = "staging path disappeared after exclusive creation"
           })
  in
  let initialized =
    let db_result =
      try
        Ok (Sqlite3.db_open ~mode:`NO_CREATE ~mutex:`FULL staging)
      with exn -> Error (sqlite_failure Open_database (Printexc.to_string exn))
    in
    let* db = db_result in
    let handle =
      { db
      ; path = staging
      ; ownership_root
      ; initial_identity = Some initial_identity
      }
    in
    let body =
      let* () = configure_connection db in
      initialize_database db ~keeper_name ~path:staging
    in
    combine_cleanup body (close_database handle)
  in
  match initialized with
  | Error primary ->
    combine_cleanup
      (Error primary)
      (discard_private_database_files ~operation:Prepare_staging staging)
  | Ok () ->
    let* () = fsync_parent ~operation:Publish_database staging in
    let* final = inspect_database_paths ~ownership_root path in
    let* () =
      match final with
      | Path_absent -> Ok ()
      | Regular_path _ ->
        Error
          (Path_failure
             { operation = Publish_database
             ; path
             ; detail = "final database appeared before no-replace publish"
             })
    in
    (try
       Unix.link staging path;
       let* () = fsync_parent ~operation:Publish_database path in
       Unix.unlink staging;
       fsync_parent ~operation:Publish_database path
     with exn ->
       Error
         (Path_failure
            { operation = Publish_database
            ; path
            ; detail = Printexc.to_string exn
            }))
;;

let with_database ~base_path ~keeper_name ~create body =
  let* path = database_path ~base_path ~keeper_name in
  let ownership_root = base_path in
  let* prelock =
    Eio_guard.run_in_systhread (fun () ->
      let* () = if create then ensure_owned_parent ~ownership_root path else Ok () in
      let* observed = inspect_database_before_lock ~ownership_root path in
      if observed = Prelock_database_absent && not create
      then Ok None
      else
        let lock_path = lock_path path in
        let* _ = prepare_private_file ~operation:Prepare_lock lock_path in
        Ok (Some lock_path))
  in
  match prelock with
  | None -> Ok None
  | Some lock_path ->
    match
      File_lock_eio.with_durable_lock ~lock_path (fun () ->
        Eio_guard.run_in_systhread (fun () ->
          try
            let* () = recover_interrupted_publish ~ownership_root ~path in
            let* observed = inspect_database_paths ~ownership_root path in
            let* () =
              match observed, create with
              | Path_absent, true ->
                initialize_staged_database ~ownership_root ~path ~keeper_name
              | Path_absent, false | Regular_path _, _ -> Ok ()
            in
            let* handle = open_existing_database ~ownership_root ~path ~keeper_name in
            match handle with
            | None -> Ok None
            | Some validated ->
              let handle = validated.handle in
              let body_result =
                try Result.map Option.some (body handle.db) with
                | Eio.Cancel.Cancelled _ as exn ->
                  (match close_database handle with
                   | Ok () -> ()
                   | Error error ->
                     Log.Keeper.error
                       "reaction database close failed during cancellation: %s"
                       (error_to_string error));
                  raise exn
                | exn ->
                  Error (sqlite_failure Step_statement (Printexc.to_string exn))
              in
              combine_cleanup body_result (close_database handle)
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (sqlite_failure Open_database (Printexc.to_string exn))))
    with
    | Ok result -> result
    | Error error -> Error (Lock_failure error)
;;

type event_columns =
  { event_id : string
  ; stimulus_id : string
  ; record_kind : string
  ; recorded_at_us : int64
  ; stimulus_kind : string option
  ; post_id : string option
  ; urgency : string option
  ; arrived_at_us : int64 option
  ; board_updated_at_us : int64 option
  ; reaction_kind : string option
  ; transition_id : string option
  ; source_index : int64 option
  ; source_count : int64 option
  ; cursor_ts_us : int64 option
  ; cursor_post_id : string option
  }

let option_timestamp_to_microseconds ~field = function
  | None -> Ok None
  | Some value -> Result.map Option.some (timestamp_to_microseconds ~field value)
;;

let event_columns_of_event (event : event) =
  let* () = non_empty "event_id" event.event_id in
  let* () = non_empty "stimulus_id" event.stimulus_id in
  let* recorded_at_us =
    timestamp_to_microseconds ~field:"recorded_at" event.recorded_at
  in
  match event.payload with
  | Stimulus_event stimulus ->
    let* arrived_at_us =
      timestamp_to_microseconds ~field:"arrived_at" stimulus.arrived_at
    in
    let* board_updated_at_us =
      option_timestamp_to_microseconds
        ~field:"board_updated_at"
        stimulus.board_updated_at
    in
    Ok
      { event_id = event.event_id
      ; stimulus_id = event.stimulus_id
      ; record_kind = "stimulus"
      ; recorded_at_us
      ; stimulus_kind = Some (stimulus_kind_to_string stimulus.kind)
      ; post_id = Some stimulus.post_id
      ; urgency = Some (urgency_to_string stimulus.urgency)
      ; arrived_at_us = Some arrived_at_us
      ; board_updated_at_us
      ; reaction_kind = None
      ; transition_id = None
      ; source_index = None
      ; source_count = None
      ; cursor_ts_us = None
      ; cursor_post_id = None
      }
  | Turn_started_event source ->
    Ok
      { event_id = event.event_id
      ; stimulus_id = event.stimulus_id
      ; record_kind = "turn_started"
      ; recorded_at_us
      ; stimulus_kind = Some (stimulus_kind_to_string source.stimulus_kind)
      ; post_id = Some source.post_id
      ; urgency = None
      ; arrived_at_us = None
      ; board_updated_at_us = None
      ; reaction_kind = Some (reaction_kind_to_string Turn_started)
      ; transition_id = None
      ; source_index = None
      ; source_count = None
      ; cursor_ts_us = None
      ; cursor_post_id = None
      }
  | Cursor_ack_event cursor ->
    let* cursor_ts_us = timestamp_to_microseconds ~field:"cursor_ts" cursor.cursor_ts in
    Ok
      { event_id = event.event_id
      ; stimulus_id = event.stimulus_id
      ; record_kind = "cursor_ack"
      ; recorded_at_us
      ; stimulus_kind = None
      ; post_id = None
      ; urgency = None
      ; arrived_at_us = None
      ; board_updated_at_us = None
      ; reaction_kind = Some (reaction_kind_to_string Cursor_ack)
      ; transition_id = None
      ; source_index = None
      ; source_count = None
      ; cursor_ts_us = Some cursor_ts_us
      ; cursor_post_id = cursor.post_id
      }
;;

let transition_source_columns
      (transition : transition)
      ~source_index
      ~source_count
      (source : transition_source)
  =
  let* () = non_empty "event_id" source.event_id in
  let* () = non_empty "stimulus_id" source.stimulus_id in
  let* recorded_at_us =
    timestamp_to_microseconds ~field:"settled_at" transition.settled_at
  in
  Ok
    { event_id = source.event_id
    ; stimulus_id = source.stimulus_id
    ; record_kind = "transition_settlement"
    ; recorded_at_us
    ; stimulus_kind = Some (stimulus_kind_to_string source.stimulus_kind)
    ; post_id = Some source.post_id
    ; urgency = None
    ; arrived_at_us = None
    ; board_updated_at_us = None
    ; reaction_kind =
        Some
          (reaction_kind_to_string
             (reaction_kind_of_settlement transition.settlement_kind))
    ; transition_id = Some transition.transition_id
    ; source_index = Some (Int64.of_int source_index)
    ; source_count = Some (Int64.of_int source_count)
    ; cursor_ts_us = None
    ; cursor_post_id = None
    }
;;

let sqlite_data_of_text_opt = function
  | None -> Sqlite3.Data.NULL
  | Some value -> Sqlite3.Data.TEXT value
;;

let sqlite_data_of_int64_opt = function
  | None -> Sqlite3.Data.NULL
  | Some value -> Sqlite3.Data.INT value
;;

let insert_event_sql =
  "INSERT INTO events(event_id, stimulus_id, record_kind, recorded_at_unix_us, stimulus_kind, post_id, urgency, arrived_at_unix_us, board_updated_at_unix_us, reaction_kind, transition_id, source_index, source_count, cursor_ts_unix_us, cursor_post_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
;;

type insert_step =
  | Insert_step_done
  | Insert_step_constraint of Sqlite3.Rc.t

let acknowledge_handled_constraint db stmt constraint_rc =
  match Sqlite3.reset stmt with
  | rc when Sqlite3.Rc.is_success rc || rc = constraint_rc -> Ok ()
  | rc -> Error (sqlite_rc_failure Step_statement db rc)
  | exception exn ->
    Error (sqlite_failure Step_statement (Printexc.to_string exn))
;;

let bind_event_columns db stmt columns =
  let values =
    [ Sqlite3.Data.TEXT columns.event_id
    ; Sqlite3.Data.TEXT columns.stimulus_id
    ; Sqlite3.Data.TEXT columns.record_kind
    ; Sqlite3.Data.INT columns.recorded_at_us
    ; sqlite_data_of_text_opt columns.stimulus_kind
    ; sqlite_data_of_text_opt columns.post_id
    ; sqlite_data_of_text_opt columns.urgency
    ; sqlite_data_of_int64_opt columns.arrived_at_us
    ; sqlite_data_of_int64_opt columns.board_updated_at_us
    ; sqlite_data_of_text_opt columns.reaction_kind
    ; sqlite_data_of_text_opt columns.transition_id
    ; sqlite_data_of_int64_opt columns.source_index
    ; sqlite_data_of_int64_opt columns.source_count
    ; sqlite_data_of_int64_opt columns.cursor_ts_us
    ; sqlite_data_of_text_opt columns.cursor_post_id
    ]
  in
  let _, result =
    List.fold_left
      (fun (index, state) value ->
        let next =
          let* () = state in
          sqlite_bind db stmt index value
        in
        index + 1, next)
      (1, Ok ())
      values
  in
  result
;;

let try_insert_event db columns =
  with_statement db insert_event_sql (fun stmt ->
    let* () = bind_event_columns db stmt columns in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok Insert_step_done
    | Sqlite3.Rc.CONSTRAINT as rc ->
      let* () = acknowledge_handled_constraint db stmt rc in
      Ok (Insert_step_constraint rc)
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let selected_event_columns prefix =
  [ "sequence"
  ; "event_id"
  ; "stimulus_id"
  ; "record_kind"
  ; "recorded_at_unix_us"
  ; "stimulus_kind"
  ; "post_id"
  ; "urgency"
  ; "arrived_at_unix_us"
  ; "board_updated_at_unix_us"
  ; "reaction_kind"
  ; "transition_id"
  ; "source_index"
  ; "source_count"
  ; "cursor_ts_unix_us"
  ; "cursor_post_id"
  ]
  |> List.map (fun column -> prefix ^ column)
  |> String.concat ", "
;;

let require_text stmt index field =
  if Sqlite3.column_is_null stmt index
  then Error (Integrity_failure (field ^ " is NULL"))
  else Ok (Sqlite3.column_text stmt index)
;;

let require_int64 stmt index field =
  if Sqlite3.column_is_null stmt index
  then Error (Integrity_failure (field ^ " is NULL"))
  else Ok (Sqlite3.column_int64 stmt index)
;;

let optional_text stmt index =
  if Sqlite3.column_is_null stmt index then None else Some (Sqlite3.column_text stmt index)
;;

let optional_int64 stmt index =
  if Sqlite3.column_is_null stmt index then None else Some (Sqlite3.column_int64 stmt index)
;;

let nonnegative_int_of_int64 ~field value =
  if Int64.compare value 0L < 0 || Int64.compare value (Int64.of_int max_int) > 0
  then Error (Integrity_failure (field ^ " is outside the OCaml int range"))
  else Ok (Int64.to_int value)
;;

let decode_stimulus_kind value =
  match stimulus_kind_of_string value with
  | Some kind -> Ok kind
  | None -> Error (Integrity_failure ("unknown stimulus kind: " ^ value))
;;

let decode_reaction_kind value =
  match reaction_kind_of_string value with
  | Some kind -> Ok kind
  | None -> Error (Integrity_failure ("unknown reaction kind: " ^ value))
;;

let decode_urgency value =
  match urgency_of_string value with
  | Some urgency -> Ok urgency
  | None -> Error (Integrity_failure ("unknown urgency: " ^ value))
;;

let stored_event_of_statement stmt ~offset ~external_input_requested =
  let column index = offset + index in
  let* sequence = require_int64 stmt (column 0) "sequence" in
  let* event_id = require_text stmt (column 1) "event_id" in
  let* stimulus_id = require_text stmt (column 2) "stimulus_id" in
  let* record_kind = require_text stmt (column 3) "record_kind" in
  let* recorded_at_us = require_int64 stmt (column 4) "recorded_at_unix_us" in
  let stimulus_kind = optional_text stmt (column 5) in
  let post_id = optional_text stmt (column 6) in
  let urgency = optional_text stmt (column 7) in
  let arrived_at_us = optional_int64 stmt (column 8) in
  let board_updated_at_us = optional_int64 stmt (column 9) in
  let reaction_kind = optional_text stmt (column 10) in
  let transition_id = optional_text stmt (column 11) in
  let source_index = optional_int64 stmt (column 12) in
  let source_count = optional_int64 stmt (column 13) in
  let cursor_ts_us = optional_int64 stmt (column 14) in
  let cursor_post_id = optional_text stmt (column 15) in
  let* payload =
    match record_kind with
    | "stimulus" ->
      let* kind =
        match stimulus_kind with
        | Some value -> decode_stimulus_kind value
        | None -> Error (Integrity_failure "stimulus kind is NULL")
      in
      let* post_id =
        match post_id with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "stimulus post_id is NULL")
      in
      let* urgency =
        match urgency with
        | Some value -> decode_urgency value
        | None -> Error (Integrity_failure "stimulus urgency is NULL")
      in
      let* arrived_at_us =
        match arrived_at_us with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "stimulus arrived_at is NULL")
      in
      Ok
        (Stored_stimulus
           { kind
           ; post_id
           ; urgency
           ; arrived_at = timestamp_of_microseconds arrived_at_us
           ; board_updated_at = Option.map timestamp_of_microseconds board_updated_at_us
           })
    | "turn_started" ->
      let* stimulus_kind =
        match stimulus_kind with
        | Some value -> decode_stimulus_kind value
        | None -> Error (Integrity_failure "turn source kind is NULL")
      in
      let* post_id =
        match post_id with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "turn source post_id is NULL")
      in
      let* observed_reaction =
        match reaction_kind with
        | Some value -> decode_reaction_kind value
        | None -> Error (Integrity_failure "turn reaction kind is NULL")
      in
      if observed_reaction = Turn_started
      then Ok (Stored_turn_started { stimulus_kind; post_id })
      else Error (Integrity_failure "turn row has a non-turn reaction kind")
    | "transition_settlement" ->
      let* stimulus_kind =
        match stimulus_kind with
        | Some value -> decode_stimulus_kind value
        | None -> Error (Integrity_failure "transition source kind is NULL")
      in
      let* post_id =
        match post_id with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "transition source post_id is NULL")
      in
      let* reaction_kind =
        match reaction_kind with
        | Some value -> decode_reaction_kind value
        | None -> Error (Integrity_failure "transition reaction kind is NULL")
      in
      let* transition_id =
        match transition_id with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "transition_id is NULL")
      in
      let* source_index =
        match source_index with
        | Some value -> nonnegative_int_of_int64 ~field:"transition source_index" value
        | None -> Error (Integrity_failure "transition source_index is NULL")
      in
      let* source_count =
        match source_count with
        | Some value -> nonnegative_int_of_int64 ~field:"transition source_count" value
        | None -> Error (Integrity_failure "transition source_count is NULL")
      in
      Ok
        (Stored_transition_settlement
           { reaction_kind
           ; source = { stimulus_kind; post_id }
           ; transition_id
           ; source_index
           ; source_count
           ; external_input_requested
           })
    | "cursor_ack" ->
      let* cursor_ts_us =
        match cursor_ts_us with
        | Some value -> Ok value
        | None -> Error (Integrity_failure "cursor timestamp is NULL")
      in
      Ok
        (Stored_cursor_ack
           { cursor_ts = timestamp_of_microseconds cursor_ts_us
           ; post_id = cursor_post_id
           })
    | value -> Error (Integrity_failure ("unknown record kind: " ^ value))
  in
  Ok
    { sequence
    ; event_id
    ; stimulus_id
    ; recorded_at = timestamp_of_microseconds recorded_at_us
    ; payload
    }
;;

let select_event_projection alias =
  selected_event_columns (alias ^ ".")
  ^ ", t.transition_id, t.external_input_requested, t.source_count, t.settled_at_unix_us, t.settlement_kind"
;;

let stored_joined_event_of_statement stmt ~offset =
  let event_transition_id = optional_text stmt (offset + 11) in
  let event_source_count = optional_int64 stmt (offset + 13) in
  let parent_transition_id = optional_text stmt (offset + 16) in
  let parent_external_input = optional_int64 stmt (offset + 17) in
  let parent_source_count = optional_int64 stmt (offset + 18) in
  let parent_settled_at = optional_int64 stmt (offset + 19) in
  let parent_settlement_kind = optional_text stmt (offset + 20) in
  let record_kind =
    if Sqlite3.column_is_null stmt (offset + 3)
    then None
    else Some (Sqlite3.column_text stmt (offset + 3))
  in
  let* external_input_requested =
    match record_kind with
    | Some "transition_settlement" ->
      (match
         event_transition_id,
         event_source_count,
         parent_transition_id,
         parent_external_input,
         parent_source_count,
         parent_settled_at,
         parent_settlement_kind,
         optional_text stmt (offset + 10)
       with
       | ( Some event_transition_id
         , Some event_source_count
         , Some parent_transition_id
         , Some parent_external_input
         , Some parent_source_count
         , Some parent_settled_at
         , Some parent_settlement_kind
         , Some child_reaction_kind )
         when String.equal event_transition_id parent_transition_id
              && Int64.equal event_source_count parent_source_count
              && Int64.equal
                   (Sqlite3.column_int64 stmt (offset + 4))
                   parent_settled_at ->
         let* settlement_kind =
           match settlement_kind_of_string parent_settlement_kind with
           | Some kind -> Ok kind
           | None -> Error (Integrity_failure "invalid parent settlement kind")
         in
         let* child_reaction_kind = decode_reaction_kind child_reaction_kind in
         let* () =
           if child_reaction_kind = reaction_kind_of_settlement settlement_kind
           then Ok ()
           else
             Error
               (Integrity_failure
                  "transition child reaction kind disagrees with parent settlement kind")
         in
         (match parent_external_input, settlement_kind with
          | 0L, _ -> Ok false
          | 1L, Escalate -> Ok true
          | 1L, (Ack | Requeue) ->
            Error
              (Integrity_failure
                 "external input flag requires an escalated parent settlement")
          | _ -> Error (Integrity_failure "invalid transition external-input flag"))
       | _ ->
         Error
           (Integrity_failure
              "transition settlement is missing or disagrees with its parent header"))
    | Some ("stimulus" | "turn_started" | "cursor_ack") ->
      (match
         parent_transition_id,
         parent_external_input,
         parent_source_count,
         parent_settled_at,
         parent_settlement_kind
       with
       | None, None, None, None, None -> Ok false
       | _ -> Error (Integrity_failure "non-transition event joined a transition header"))
    | Some other -> Error (Integrity_failure ("unknown record kind: " ^ other))
    | None -> Error (Integrity_failure "record kind is NULL")
  in
  stored_event_of_statement stmt ~offset ~external_input_requested
;;

let find_event_by_id db event_id =
  let sql =
    "SELECT "
    ^ select_event_projection "e"
    ^ " FROM events AS e INDEXED BY events_event_id LEFT JOIN transitions AS t ON t.transition_id = e.transition_id WHERE e.event_id = ?"
  in
  with_statement db sql (fun stmt ->
    let* () = sqlite_bind db stmt 1 (Sqlite3.Data.TEXT event_id) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok None
    | Sqlite3.Rc.ROW ->
      let* event = stored_joined_event_of_statement stmt ~offset:0 in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok (Some event)
       | Sqlite3.Rc.ROW -> Error (Integrity_failure "event_id index is not unique")
       | rc -> Error (sqlite_rc_failure Step_statement db rc))
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let normalized_timestamp_equal ~field left right =
  match timestamp_to_microseconds ~field left, timestamp_to_microseconds ~field right with
  | Ok left, Ok right -> Int64.equal left right
  | Error _, _ | _, Error _ -> false
;;

let normalized_optional_timestamp_equal ~field left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> normalized_timestamp_equal ~field left right
  | None, Some _ | Some _, None -> false
;;

let event_matches (stored : stored_event) (event : event) =
  String.equal stored.event_id event.event_id
  && String.equal stored.stimulus_id event.stimulus_id
  &&
  match stored.payload, event.payload with
  | Stored_stimulus stored, Stimulus_event candidate ->
    stored.kind = candidate.kind
    && String.equal stored.post_id candidate.post_id
    && stored.urgency = candidate.urgency
    && normalized_optional_timestamp_equal
         ~field:"board_updated_at"
         stored.board_updated_at
         candidate.board_updated_at
  | Stored_turn_started stored, Turn_started_event candidate ->
    stored.stimulus_kind = candidate.stimulus_kind
    && String.equal stored.post_id candidate.post_id
  | Stored_cursor_ack stored, Cursor_ack_event candidate ->
    normalized_timestamp_equal ~field:"cursor_ts" stored.cursor_ts candidate.cursor_ts
    && Option.equal String.equal stored.post_id candidate.post_id
  | Stored_transition_settlement _, _
  | Stored_stimulus _, (Turn_started_event _ | Cursor_ack_event _)
  | Stored_turn_started _, (Stimulus_event _ | Cursor_ack_event _)
  | Stored_cursor_ack _, (Stimulus_event _ | Turn_started_event _) -> false
;;

let transition_source_matches
      (stored : stored_event)
      (transition : transition)
      ~source_index
      ~source_count
      (source : transition_source)
  =
  String.equal stored.event_id source.event_id
  && String.equal stored.stimulus_id source.stimulus_id
  && normalized_timestamp_equal
       ~field:"settled_at"
       stored.recorded_at
       transition.settled_at
  &&
  match stored.payload with
  | Stored_transition_settlement stored ->
    stored.reaction_kind = reaction_kind_of_settlement transition.settlement_kind
    && stored.source.stimulus_kind = source.stimulus_kind
    && String.equal stored.source.post_id source.post_id
    && String.equal stored.transition_id transition.transition_id
    && stored.source_index = source_index
    && stored.source_count = source_count
    && Bool.equal stored.external_input_requested transition.external_input_requested
  | Stored_stimulus _ | Stored_turn_started _ | Stored_cursor_ack _ -> false
;;

let with_transaction db ~begin_sql body =
  let* () = sqlite_exec db ~operation:Begin_transaction begin_sql in
  try
    match body () with
    | Error primary ->
      combine_cleanup
        (Error primary)
        (sqlite_exec db ~operation:Rollback_transaction "ROLLBACK")
    | Ok value ->
      (match sqlite_exec db ~operation:Commit_transaction "COMMIT" with
       | Ok () -> Ok value
       | Error cause ->
         combine_cleanup
           (Error (Commit_outcome_indeterminate cause))
           (sqlite_exec db ~operation:Rollback_transaction "ROLLBACK"))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match sqlite_exec db ~operation:Rollback_transaction "ROLLBACK" with
     | Ok () -> ()
     | Error error ->
       Log.Keeper.error
         "reaction transaction rollback failed during cancellation: %s"
         (error_to_string error));
    Printexc.raise_with_backtrace exn backtrace
  | exn ->
    combine_cleanup
      (Error (sqlite_failure Step_statement (Printexc.to_string exn)))
      (sqlite_exec db ~operation:Rollback_transaction "ROLLBACK")
;;

let with_write_transaction db body =
  with_transaction db ~begin_sql:"BEGIN IMMEDIATE" body
;;

let append_event_in_transaction db (event : event) columns =
  let* step = try_insert_event db columns in
  match step with
  | Insert_step_done -> Ok Inserted
  | Insert_step_constraint rc ->
    let* existing = find_event_by_id db event.event_id in
    (match existing with
     | Some existing when event_matches existing event -> Ok Already_recorded
     | Some _ -> Error (Event_identity_conflict { event_id = event.event_id })
     | None -> Error (sqlite_rc_failure Step_statement db rc))
;;

let event_entries events =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | event :: rest ->
      let* columns = event_columns_of_event event in
      loop ((event, columns) :: reversed) rest
  in
  loop [] events
;;

let append_event_entries_in_transaction db entries =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | (event, columns) :: rest ->
      let* outcome = append_event_in_transaction db event columns in
      loop (outcome :: reversed) rest
  in
  loop [] entries
;;

let append_events ~base_path ~keeper_name events =
  match events with
  | [] -> Ok []
  | _ :: _ ->
    let* entries = event_entries events in
    let body db =
      with_write_transaction db (fun () -> append_event_entries_in_transaction db entries)
    in
    let* result = with_database ~base_path ~keeper_name ~create:true body in
    (match result with
     | Some outcomes -> Ok outcomes
     | None -> Error (Integrity_failure "write database was not created"))
;;

let append_event ~base_path ~keeper_name event =
  let* outcomes = append_events ~base_path ~keeper_name [ event ] in
  match outcomes with
  | [ outcome ] -> Ok outcome
  | [] | _ :: _ :: _ ->
    Error (Integrity_failure "single event append returned a non-singleton outcome")
;;

type stored_transition =
  { transition_id : string
  ; transition_event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at_us : int64
  ; settlement_kind : string
  ; settlement_identity : string
  ; external_input_requested : bool
  ; source_count : int
  }

let validate_transition (transition : transition) =
  let* () = non_empty "transition_id" transition.transition_id in
  let* () = non_empty "transition_event_id" transition.transition_event_id in
  let* () = non_empty "lease_id" transition.lease_id in
  let* () = non_empty "settlement_identity" transition.settlement_identity in
  let* _ = timestamp_to_microseconds ~field:"settled_at" transition.settled_at in
  if Int64.compare transition.lease_sequence 0L <= 0
  then Error (Invalid_transition "lease_sequence must be positive")
  else if transition.sources = []
  then Error (Invalid_transition "source set must be non-empty")
  else if transition.external_input_requested && transition.settlement_kind <> Escalate
  then
    Error
      (Invalid_transition
         "external_input_requested is valid only for an escalated settlement")
  else
    let rec validate_sources event_ids stimulus_ids = function
      | [] -> Ok ()
      | (source : transition_source) :: rest ->
        let* () = non_empty "source.event_id" source.event_id in
        let* () = non_empty "source.stimulus_id" source.stimulus_id in
        if String_set.mem source.event_id event_ids
        then Error (Invalid_transition "source event identities must be unique")
        else if String_set.mem source.stimulus_id stimulus_ids
        then Error (Invalid_transition "source stimulus identities must be unique")
        else
          validate_sources
            (String_set.add source.event_id event_ids)
            (String_set.add source.stimulus_id stimulus_ids)
            rest
    in
    validate_sources String_set.empty String_set.empty transition.sources
;;

let insert_transition_sql =
  "INSERT INTO transitions(transition_id, transition_event_id, lease_id, lease_sequence, settled_at_unix_us, settlement_kind, settlement_identity, external_input_requested, source_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
;;

let try_insert_transition
      db
      (transition : transition)
      ~settled_at_us
      ~source_count
  =
  with_statement db insert_transition_sql (fun stmt ->
    let values =
      [ Sqlite3.Data.TEXT transition.transition_id
      ; Sqlite3.Data.TEXT transition.transition_event_id
      ; Sqlite3.Data.TEXT transition.lease_id
      ; Sqlite3.Data.INT transition.lease_sequence
      ; Sqlite3.Data.INT settled_at_us
      ; Sqlite3.Data.TEXT (settlement_kind_to_string transition.settlement_kind)
      ; Sqlite3.Data.TEXT transition.settlement_identity
      ; Sqlite3.Data.INT (if transition.external_input_requested then 1L else 0L)
      ; Sqlite3.Data.INT (Int64.of_int source_count)
      ]
    in
    let _, bound =
      List.fold_left
        (fun (index, state) value ->
          let next =
            let* () = state in
            sqlite_bind db stmt index value
          in
          index + 1, next)
        (1, Ok ())
        values
    in
    let* () = bound in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok Insert_step_done
    | Sqlite3.Rc.CONSTRAINT as rc ->
      let* () = acknowledge_handled_constraint db stmt rc in
      Ok (Insert_step_constraint rc)
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let stored_transition_of_statement stmt =
  let* transition_id = require_text stmt 0 "transition_id" in
  let* transition_event_id = require_text stmt 1 "transition_event_id" in
  let* lease_id = require_text stmt 2 "lease_id" in
  let* lease_sequence = require_int64 stmt 3 "lease_sequence" in
  let* settled_at_us = require_int64 stmt 4 "settled_at_unix_us" in
  let* settlement_kind = require_text stmt 5 "settlement_kind" in
  let* settlement_identity = require_text stmt 6 "settlement_identity" in
  let* external_input_requested =
    let* value = require_int64 stmt 7 "external_input_requested" in
    match value with
    | 0L -> Ok false
    | 1L -> Ok true
    | _ -> Error (Integrity_failure "invalid transition external-input flag")
  in
  let* source_count =
    let* value = require_int64 stmt 8 "source_count" in
    if Int64.compare value (Int64.of_int max_int) > 0
    then Error (Integrity_failure "transition source_count exceeds OCaml int")
    else Ok (Int64.to_int value)
  in
  Ok
    { transition_id
    ; transition_event_id
    ; lease_id
    ; lease_sequence
    ; settled_at_us
    ; settlement_kind
    ; settlement_identity
    ; external_input_requested
    ; source_count
    }
;;

let transition_select_columns =
  "transition_id, transition_event_id, lease_id, lease_sequence, settled_at_unix_us, settlement_kind, settlement_identity, external_input_requested, source_count"
;;

let find_transition_by_index db ~index ~field value =
  let sql =
    Printf.sprintf
      "SELECT %s FROM transitions INDEXED BY %s WHERE %s = ?"
      transition_select_columns
      index
      field
  in
  with_statement db sql (fun stmt ->
    let* () = sqlite_bind db stmt 1 value in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok None
    | Sqlite3.Rc.ROW ->
      let* transition = stored_transition_of_statement stmt in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok (Some transition)
       | Sqlite3.Rc.ROW -> Error (Integrity_failure "transition index is not unique")
       | rc -> Error (sqlite_rc_failure Step_statement db rc))
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let find_transition_by_id db transition_id =
  let sql =
    Printf.sprintf
      "SELECT %s FROM transitions WHERE transition_id = ?"
      transition_select_columns
  in
  with_statement db sql (fun stmt ->
    let* () = sqlite_bind db stmt 1 (Sqlite3.Data.TEXT transition_id) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok None
    | Sqlite3.Rc.ROW ->
      let* transition = stored_transition_of_statement stmt in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok (Some transition)
       | Sqlite3.Rc.ROW ->
         Error (Integrity_failure "transition primary key is not unique")
       | rc -> Error (sqlite_rc_failure Step_statement db rc))
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let transition_header_matches
      (stored : stored_transition)
      (transition : transition)
      ~settled_at_us
      ~source_count
  =
  String.equal stored.transition_id transition.transition_id
  && String.equal stored.transition_event_id transition.transition_event_id
  && String.equal stored.lease_id transition.lease_id
  && Int64.equal stored.lease_sequence transition.lease_sequence
  && Int64.equal stored.settled_at_us settled_at_us
  && String.equal
       stored.settlement_kind
       (settlement_kind_to_string transition.settlement_kind)
  && String.equal stored.settlement_identity transition.settlement_identity
  && Bool.equal stored.external_input_requested transition.external_input_requested
  && stored.source_count = source_count
;;

let any_transition_alias_exists db (transition : transition) =
  let queries =
    [ ( "transitions_event_id"
      , "transition_event_id"
      , Sqlite3.Data.TEXT transition.transition_event_id )
    ; "transitions_lease_id", "lease_id", Sqlite3.Data.TEXT transition.lease_id
    ; ( "transitions_lease_sequence"
      , "lease_sequence"
      , Sqlite3.Data.INT transition.lease_sequence )
    ]
  in
  let rec loop = function
    | [] -> Ok false
    | (index, field, value) :: rest ->
      let* found = find_transition_by_index db ~index ~field value in
      (match found with
       | Some _ -> Ok true
       | None -> loop rest)
  in
  loop queries
;;

let find_transition_source db ~transition_id ~source_index =
  let sql =
    "SELECT "
    ^ select_event_projection "e"
    ^ " FROM events AS e INDEXED BY events_transition_source JOIN transitions AS t ON t.transition_id = e.transition_id WHERE e.record_kind = 'transition_settlement' AND e.transition_id = ? AND e.source_index = ?"
  in
  with_statement db sql (fun stmt ->
    let* () = sqlite_bind db stmt 1 (Sqlite3.Data.TEXT transition_id) in
    let* () = sqlite_bind db stmt 2 (Sqlite3.Data.INT (Int64.of_int source_index)) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok None
    | Sqlite3.Rc.ROW ->
      let* event = stored_joined_event_of_statement stmt ~offset:0 in
      (match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok (Some event)
       | Sqlite3.Rc.ROW ->
         Error (Integrity_failure "transition source index is not unique")
       | rc -> Error (sqlite_rc_failure Step_statement db rc))
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let insert_transition_source
      db
      (transition : transition)
      ~source_index
      ~source_count
      (source : transition_source)
  =
  let* columns =
    transition_source_columns transition ~source_index ~source_count source
  in
  let* step = try_insert_event db columns in
  match step with
  | Insert_step_done -> Ok Inserted
  | Insert_step_constraint rc ->
    let* by_event_id = find_event_by_id db source.event_id in
    (match by_event_id with
     | Some existing
       when transition_source_matches
              existing
              transition
              ~source_index
              ~source_count
              source -> Ok Already_recorded
     | Some _ -> Error (Event_identity_conflict { event_id = source.event_id })
     | None ->
       let* by_source =
         find_transition_source db ~transition_id:transition.transition_id ~source_index
       in
       (match by_source with
        | Some _ ->
          Error
            (Transition_source_conflict
               { transition_id = transition.transition_id; source_index })
        | None -> Error (sqlite_rc_failure Step_statement db rc)))
;;

let validate_transition_cardinality db transition_id expected =
  let sql =
    "SELECT COUNT(*), MIN(source_index), MAX(source_index) FROM events INDEXED BY events_transition_source WHERE record_kind = 'transition_settlement' AND transition_id = ?"
  in
  with_statement db sql (fun stmt ->
    let* () = sqlite_bind db stmt 1 (Sqlite3.Data.TEXT transition_id) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let actual = Int64.to_int (Sqlite3.column_int64 stmt 0) in
      let min_index = optional_int64 stmt 1 in
      let max_index = optional_int64 stmt 2 in
      let* () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok ()
        | rc -> Error (sqlite_rc_failure Step_statement db rc)
      in
      if
        actual = expected
        && min_index = Some 0L
        && max_index = Some (Int64.of_int (expected - 1))
      then Ok ()
      else
        Error
          (Transition_cardinality_violation
             { transition_id; expected; actual })
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let append_transition_in_transaction
      db
      (transition : transition)
      ~settled_at_us
      ~source_count
  =
      let* header_step =
        try_insert_transition db transition ~settled_at_us ~source_count
      in
      let* header_outcome =
        match header_step with
        | Insert_step_done -> Ok `New
        | Insert_step_constraint rc ->
          let* existing = find_transition_by_id db transition.transition_id in
          (match existing with
           | Some existing
             when transition_header_matches
                    existing
                    transition
                    ~settled_at_us
                    ~source_count -> Ok `Replay
           | Some _ ->
             Error
               (Transition_identity_conflict
                  { transition_id = transition.transition_id })
           | None ->
             let* alias_exists = any_transition_alias_exists db transition in
             if alias_exists
             then
               Error
                 (Transition_identity_conflict
                    { transition_id = transition.transition_id })
             else Error (sqlite_rc_failure Step_statement db rc))
      in
      let rec insert_new_sources index = function
        | [] -> Ok ()
        | (source : transition_source) :: rest ->
          let* outcome =
            insert_transition_source
              db
              transition
              ~source_index:index
              ~source_count
              source
          in
          (match outcome with
           | Inserted -> insert_new_sources (index + 1) rest
           | Already_recorded ->
             Error
               (Transition_source_conflict
                  { transition_id = transition.transition_id
                  ; source_index = index
                  }))
      in
      let rec validate_replay_sources index = function
        | [] -> Ok ()
        | (source : transition_source) :: rest ->
          let* existing = find_event_by_id db source.event_id in
          (match existing with
           | Some existing
             when transition_source_matches
                    existing
                    transition
                    ~source_index:index
                    ~source_count
                    source -> validate_replay_sources (index + 1) rest
           | Some _ | None ->
             Error
               (Transition_source_conflict
                  { transition_id = transition.transition_id
                  ; source_index = index
                  }))
      in
      (match header_outcome with
       | `New ->
         let* () = insert_new_sources 0 transition.sources in
         let* () =
           validate_transition_cardinality db transition.transition_id source_count
         in
         Ok Transition_inserted
       | `Replay ->
         let* () =
           validate_transition_cardinality db transition.transition_id source_count
         in
         let* () = validate_replay_sources 0 transition.sources in
         Ok Transition_already_recorded)
;;

let append_events_and_transition
      ~base_path
      ~keeper_name
      ~events
      (transition : transition)
  =
  let* entries = event_entries events in
  let* () = validate_transition transition in
  let* settled_at_us =
    timestamp_to_microseconds ~field:"settled_at" transition.settled_at
  in
  let source_count = List.length transition.sources in
  let body db =
    with_write_transaction db (fun () ->
      let* _ = append_event_entries_in_transaction db entries in
      append_transition_in_transaction db transition ~settled_at_us ~source_count)
  in
  let* result = with_database ~base_path ~keeper_name ~create:true body in
  match result with
  | Some outcome -> Ok outcome
  | None -> Error (Integrity_failure "write database was not created")
;;

let append_transition ~base_path ~keeper_name transition =
  append_events_and_transition ~base_path ~keeper_name ~events:[] transition
;;

let with_read_transaction db body =
  with_transaction db ~begin_sql:"BEGIN" body
;;

type read_capability_entry =
  { mutex : Stdlib.Mutex.t
  ; path : string
  ; ownership_root : string
  ; keeper_name : string
  ; mutable capability : validated_database option
  }

type capability_invalidation =
  | Capability_inode_changed
  | Capability_validation_stamp_changed

type 'a capability_read =
  | Capability_value of 'a
  | Capability_stale of capability_invalidation

let read_capability_pool_mutex = Stdlib.Mutex.create ()

let read_capability_pool
  : ((string * string * string), read_capability_entry) Hashtbl.t
  =
  Hashtbl.create 0
;;

let read_capability_entry ~ownership_root ~path ~keeper_name =
  Stdlib.Mutex.protect read_capability_pool_mutex (fun () ->
    let key = ownership_root, path, keeper_name in
    match Hashtbl.find_opt read_capability_pool key with
    | Some entry -> entry
    | None ->
      let entry =
        { mutex = Stdlib.Mutex.create ()
        ; path
        ; ownership_root
        ; keeper_name
        ; capability = None
        }
      in
      Hashtbl.add read_capability_pool key entry;
      entry)
;;

let capability_path_matches (database : validated_database) =
  let handle = database.handle in
  let* observed =
    inspect_database_paths ~ownership_root:handle.ownership_root handle.path
  in
  match handle.initial_identity, observed with
  | Some initial, Regular_path current -> Ok (same_regular_identity initial current)
  | None, Path_absent -> Ok true
  | None, Regular_path _ | Some _, Path_absent -> Ok false
;;

let read_from_capability (database : validated_database) body =
  let* path_matches_before = capability_path_matches database in
  if not path_matches_before
  then Ok (Capability_stale Capability_inode_changed)
  else
    let* read =
      with_read_transaction database.handle.db (fun () ->
        let* stamp_matches =
          cached_database_stamp_matches database.handle.db database.stamp
        in
        if stamp_matches
        then Result.map (fun value -> Capability_value value) (body database.handle.db)
        else Ok (Capability_stale Capability_validation_stamp_changed))
    in
    match read with
    | Capability_stale reason -> Ok (Capability_stale reason)
    | Capability_value value ->
      let* path_matches_after = capability_path_matches database in
      if path_matches_after
      then Ok (Capability_value value)
      else Ok (Capability_stale Capability_inode_changed)
;;

let close_read_capability_entry entry =
  match entry.capability with
  | None -> Ok ()
  | Some database ->
    let* () = close_database_connection database.handle in
    entry.capability <- None;
    Ok ()
;;

let open_read_capability entry =
  let* database =
    open_existing_database
      ~ownership_root:entry.ownership_root
      ~path:entry.path
      ~keeper_name:entry.keeper_name
  in
  entry.capability <- database;
  Ok database
;;

let read_from_new_capability entry body =
  let* database = open_read_capability entry in
  match database with
  | None -> Ok None
  | Some database ->
    let* read = read_from_capability database body in
    (match read with
     | Capability_value value -> Ok (Some value)
     | Capability_stale reason ->
       let* () = close_read_capability_entry entry in
       (match reason with
        | Capability_inode_changed -> Error (Database_identity_changed entry.path)
        | Capability_validation_stamp_changed ->
          Error
            (Schema_mismatch
               "validation stamp changed during strict read capability validation")))
;;

let read_with_capability_entry entry body =
  match entry.capability with
  | None -> read_from_new_capability entry body
  | Some database ->
    let* read = read_from_capability database body in
    (match read with
     | Capability_value value -> Ok (Some value)
     | Capability_stale _ ->
       let* () = close_read_capability_entry entry in
       read_from_new_capability entry body)
;;

let with_validated_read_capability ~base_path ~keeper_name body =
  let* path = database_path ~base_path ~keeper_name in
  Eio_guard.run_in_systhread (fun () ->
    let entry =
      read_capability_entry
        ~ownership_root:base_path
        ~path
        ~keeper_name
    in
    Stdlib.Mutex.protect entry.mutex (fun () ->
      try read_with_capability_entry entry body with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (sqlite_failure Open_database (Printexc.to_string exn))))
;;

let close_all_read_capabilities () =
  Stdlib.Mutex.protect read_capability_pool_mutex (fun () ->
    let entries =
      Hashtbl.fold (fun key entry entries -> (key, entry) :: entries) read_capability_pool []
    in
    entries
    |> List.fold_left
         (fun errors (key, entry) ->
            match
              Stdlib.Mutex.protect entry.mutex (fun () ->
                close_read_capability_entry entry)
            with
            | Ok () ->
              Hashtbl.remove read_capability_pool key;
              errors
            | Error error -> error :: errors)
         []
    |> List.rev)
;;

let release_read_capability ~base_path ~keeper_name =
  let* path = database_path ~base_path ~keeper_name in
  Eio_guard.run_in_systhread (fun () ->
    Stdlib.Mutex.protect read_capability_pool_mutex (fun () ->
      let key = base_path, path, keeper_name in
      match Hashtbl.find_opt read_capability_pool key with
      | None -> Ok ()
      | Some entry ->
        Stdlib.Mutex.protect entry.mutex (fun () ->
          let* () = close_read_capability_entry entry in
          Hashtbl.remove read_capability_pool key;
          Ok ())))
;;

let () =
  Stdlib.at_exit (fun () ->
    close_all_read_capabilities ()
    |> List.iter (fun error ->
      Log.Keeper.error
        "reaction read capability close failed at process exit: %s"
        (error_to_string error)))
;;

let read_current_cursor db =
  with_statement db
    "SELECT cursor_ts_unix_us, cursor_post_id FROM cursor_state WHERE singleton = 1"
    (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let* cursor =
          match optional_int64 stmt 0, optional_text stmt 1 with
          | None, None -> Ok None
          | Some cursor_ts_us, post_id ->
            Ok
              (Some
                 { cursor_ts = timestamp_of_microseconds cursor_ts_us
                 ; post_id
                 })
          | None, Some _ ->
            Error (Integrity_failure "cursor projection has a post id without a timestamp")
        in
        let* () =
          match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok ()
          | Sqlite3.Rc.ROW ->
            Error (Integrity_failure "cursor projection singleton is not unique")
          | rc -> Error (sqlite_rc_failure Step_statement db rc)
        in
        Ok cursor
      | Sqlite3.Rc.DONE ->
        Error (Integrity_failure "cursor projection singleton is absent")
      | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let unique_stimulus_ids stimulus_ids =
  let rec loop seen reversed = function
    | [] -> Ok (List.rev reversed)
    | stimulus_id :: rest ->
      let* () = non_empty "stimulus_id" stimulus_id in
      if String_set.mem stimulus_id seen
      then loop seen reversed rest
      else loop (String_set.add stimulus_id seen) (stimulus_id :: reversed) rest
  in
  loop String_set.empty [] stimulus_ids
;;

let populate_requested_stimuli db stimulus_ids =
  let* () =
    sqlite_exec
      db
      ~operation:Step_statement
      "CREATE TEMP TABLE requested_stimuli (ordinal INTEGER PRIMARY KEY CHECK (ordinal >= 0), stimulus_id TEXT NOT NULL UNIQUE CHECK (length(stimulus_id) > 0)) STRICT"
  in
  with_statement db
    "INSERT INTO requested_stimuli(ordinal, stimulus_id) VALUES (?, ?)"
    (fun stmt ->
      let rec loop ordinal = function
        | [] -> Ok ()
        | stimulus_id :: rest ->
          let* () =
            sqlite_bind db stmt 1 (Sqlite3.Data.INT (Int64.of_int ordinal))
          in
          let* () = sqlite_bind db stmt 2 (Sqlite3.Data.TEXT stimulus_id) in
          let* () = sqlite_expect_done db stmt in
          let reset = Sqlite3.reset stmt in
          if not (Sqlite3.Rc.is_success reset)
          then Error (sqlite_rc_failure Step_statement db reset)
          else
            let clear = Sqlite3.clear_bindings stmt in
            if not (Sqlite3.Rc.is_success clear)
            then Error (sqlite_rc_failure Bind_parameter db clear)
            else loop (ordinal + 1) rest
      in
      loop 0 stimulus_ids)
;;

let read_requested_events db stimulus_ids =
  let result = Array.of_list (List.map (fun id -> id, []) stimulus_ids) in
  let sql =
    "SELECT r.ordinal, "
    ^ select_event_projection "e"
    ^ " FROM requested_stimuli AS r JOIN events AS e INDEXED BY events_stimulus_sequence ON e.stimulus_id = r.stimulus_id LEFT JOIN transitions AS t ON t.transition_id = e.transition_id ORDER BY r.ordinal, e.sequence"
  in
  let* () =
    with_statement db sql (fun stmt ->
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok ()
        | Sqlite3.Rc.ROW ->
          let ordinal_value = Sqlite3.column_int64 stmt 0 in
          if
            Int64.compare ordinal_value 0L < 0
            || Int64.compare ordinal_value (Int64.of_int (Array.length result)) >= 0
          then Error (Integrity_failure "requested stimulus ordinal is out of range")
          else
            let ordinal = Int64.to_int ordinal_value in
            let* event = stored_joined_event_of_statement stmt ~offset:1 in
            let stimulus_id, reversed = result.(ordinal) in
            if not (String.equal stimulus_id event.stimulus_id)
            then Error (Integrity_failure "stimulus index returned a foreign identity")
            else begin
              result.(ordinal) <- stimulus_id, event :: reversed;
              loop ()
            end
        | rc -> Error (sqlite_rc_failure Step_statement db rc)
      in
      loop ())
  in
  Ok
    (Array.to_list result
     |> List.map (fun (stimulus_id, reversed) -> stimulus_id, List.rev reversed))
;;

let events_for_stimuli ~base_path ~keeper_name ~stimulus_ids =
  let* stimulus_ids = unique_stimulus_ids stimulus_ids in
  match stimulus_ids with
  | [] -> Ok []
  | _ ->
    let body db =
      with_read_transaction db (fun () ->
        let* () = populate_requested_stimuli db stimulus_ids in
        read_requested_events db stimulus_ids)
    in
    let* result = with_database ~base_path ~keeper_name ~create:false body in
    (match result with
     | None -> Ok (List.map (fun stimulus_id -> stimulus_id, []) stimulus_ids)
     | Some rows -> Ok rows)
;;

let count_to_int ~field value =
  if Int64.compare value 0L < 0 || Int64.compare value (Int64.of_int max_int) > 0
  then Error (Integrity_failure (field ^ " exceeds the OCaml count representation"))
  else Ok (Int64.to_int value)
;;

let empty_stimulus_evidence =
  { matched_record_count = 0
  ; stimulus_recorded_at = None
  ; turn_started_recorded_at = None
  ; event_queue_ack_recorded_at = None
  ; latest_recorded_at = None
  ; latest_reaction_event = None
  }
;;

let read_evidence_aggregates db stimulus_ids =
  let evidence = Array.make (List.length stimulus_ids) empty_stimulus_evidence in
  let sql =
    "WITH aggregates AS (SELECT r.ordinal AS ordinal, COUNT(e.sequence) AS matched_count, MAX(CASE WHEN e.record_kind = 'stimulus' THEN e.recorded_at_unix_us END) AS stimulus_recorded_at, MAX(CASE WHEN e.record_kind = 'turn_started' THEN e.recorded_at_unix_us END) AS turn_recorded_at, MAX(CASE WHEN e.reaction_kind = 'event_queue_ack' THEN e.recorded_at_unix_us END) AS ack_recorded_at, MAX(e.sequence) AS latest_sequence FROM requested_stimuli AS r LEFT JOIN events AS e INDEXED BY events_stimulus_sequence ON e.stimulus_id = r.stimulus_id GROUP BY r.ordinal) SELECT a.ordinal, a.matched_count, a.stimulus_recorded_at, a.turn_recorded_at, a.ack_recorded_at, latest.recorded_at_unix_us FROM aggregates AS a LEFT JOIN events AS latest ON latest.sequence = a.latest_sequence ORDER BY a.ordinal"
  in
  let* () =
    with_statement db sql (fun stmt ->
      let rec loop expected_ordinal =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE ->
          if expected_ordinal = Array.length evidence
          then Ok ()
          else Error (Integrity_failure "evidence aggregate omitted a request ordinal")
        | Sqlite3.Rc.ROW ->
          let ordinal = Sqlite3.column_int64 stmt 0 in
          if not (Int64.equal ordinal (Int64.of_int expected_ordinal))
          then Error (Integrity_failure "evidence aggregate ordinal is not contiguous")
          else
            let* matched_record_count =
              count_to_int ~field:"matched_record_count" (Sqlite3.column_int64 stmt 1)
            in
            let timestamp index =
              Option.map timestamp_of_microseconds (optional_int64 stmt index)
            in
            evidence.(expected_ordinal)
              <- { matched_record_count
                 ; stimulus_recorded_at = timestamp 2
                 ; turn_started_recorded_at = timestamp 3
                 ; event_queue_ack_recorded_at = timestamp 4
                 ; latest_recorded_at = timestamp 5
                 ; latest_reaction_event = None
                 };
            loop (expected_ordinal + 1)
        | rc -> Error (sqlite_rc_failure Step_statement db rc)
      in
      loop 0)
  in
  Ok evidence
;;

let attach_latest_reactions db evidence =
  let sql =
    "WITH latest_reactions AS (SELECT r.ordinal AS ordinal, MAX(e.sequence) AS sequence FROM requested_stimuli AS r LEFT JOIN events AS e INDEXED BY events_stimulus_sequence ON e.stimulus_id = r.stimulus_id AND e.record_kind IN ('turn_started', 'transition_settlement') GROUP BY r.ordinal) SELECT latest.ordinal, "
    ^ select_event_projection "e"
    ^ " FROM latest_reactions AS latest JOIN events AS e ON e.sequence = latest.sequence LEFT JOIN transitions AS t ON t.transition_id = e.transition_id ORDER BY latest.ordinal"
  in
  with_statement db sql (fun stmt ->
    let rec loop () =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> Ok ()
      | Sqlite3.Rc.ROW ->
        let ordinal_value = Sqlite3.column_int64 stmt 0 in
        if
          Int64.compare ordinal_value 0L < 0
          || Int64.compare ordinal_value (Int64.of_int (Array.length evidence)) >= 0
        then Error (Integrity_failure "latest reaction ordinal is out of range")
        else
          let ordinal = Int64.to_int ordinal_value in
          let* event = stored_joined_event_of_statement stmt ~offset:1 in
          evidence.(ordinal) <- { evidence.(ordinal) with latest_reaction_event = Some event };
          loop ()
      | rc -> Error (sqlite_rc_failure Step_statement db rc)
    in
    loop ())
;;

let evidence_for_stimuli ~base_path ~keeper_name ~stimulus_ids =
  let* stimulus_ids = unique_stimulus_ids stimulus_ids in
  match stimulus_ids with
  | [] -> Ok []
  | _ ->
    let body db =
      with_read_transaction db (fun () ->
        let* () = populate_requested_stimuli db stimulus_ids in
        let* evidence = read_evidence_aggregates db stimulus_ids in
        let* () = attach_latest_reactions db evidence in
        Ok
          (List.map2
             (fun stimulus_id evidence -> stimulus_id, evidence)
             stimulus_ids
             (Array.to_list evidence)))
    in
    let* result = with_database ~base_path ~keeper_name ~create:false body in
    (match result with
     | Some evidence -> Ok evidence
     | None ->
       Ok
         (List.map
            (fun stimulus_id -> stimulus_id, empty_stimulus_evidence)
            stimulus_ids))
;;

let read_projected_summary db =
  let sql =
    "SELECT row_count, stimulus_count, reaction_count, turn_started_count, event_queue_ack_count, event_queue_requeue_count, event_queue_escalation_count, event_queue_external_input_count, cursor_ack_count, cursor_swept_stimulus_count, orphan_reaction_stimulus_count, in_progress_stimulus_count, acked_stimulus_count, escalated_stimulus_count, external_input_requested_stimulus_count, pending_stimulus_count, latest_sequence, latest_recorded_at_unix_us, latest_stimulus_id FROM ledger_summary WHERE singleton = 1"
  in
  with_statement db sql (fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let count field index =
        let* value = require_int64 stmt index field in
        count_to_int ~field value
      in
      let* row_count = count "row_count" 0 in
      let* stimulus_count = count "stimulus_count" 1 in
      let* reaction_count = count "reaction_count" 2 in
      let* turn_started_count = count "turn_started_count" 3 in
      let* event_queue_ack_count = count "event_queue_ack_count" 4 in
      let* event_queue_requeue_count = count "event_queue_requeue_count" 5 in
      let* event_queue_escalation_count = count "event_queue_escalation_count" 6 in
      let* event_queue_external_input_count =
        count "event_queue_external_input_count" 7
      in
      let* cursor_ack_count = count "cursor_ack_count" 8 in
      let* cursor_swept_stimulus_count =
        count "cursor_swept_stimulus_count" 9
      in
      let* orphan_reaction_stimulus_count =
        count "orphan_reaction_stimulus_count" 10
      in
      let* in_progress_stimulus_count = count "in_progress_stimulus_count" 11 in
      let* acked_stimulus_count = count "acked_stimulus_count" 12 in
      let* escalated_stimulus_count = count "escalated_stimulus_count" 13 in
      let* external_input_requested_stimulus_count =
        count "external_input_requested_stimulus_count" 14
      in
      let* pending_stimulus_count = count "pending_stimulus_count" 15 in
      let* latest_recorded_at, latest_stimulus_id =
        match
          optional_int64 stmt 16,
          optional_int64 stmt 17,
          optional_text stmt 18
        with
        | None, None, None -> Ok (None, None)
        | Some sequence, Some recorded_at_us, Some stimulus_id
          when Int64.compare sequence 0L > 0 && not (String.equal stimulus_id "") ->
          Ok
            ( Some (timestamp_of_microseconds recorded_at_us)
            , Some stimulus_id )
        | _ -> Error (Integrity_failure "ledger summary latest-event projection is partial")
      in
      let* () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok ()
        | Sqlite3.Rc.ROW ->
          Error (Integrity_failure "ledger summary singleton is not unique")
        | rc -> Error (sqlite_rc_failure Step_statement db rc)
      in
      Ok
        { row_count
        ; stimulus_count
        ; reaction_count
        ; turn_started_count
        ; event_queue_ack_count
        ; event_queue_requeue_count
        ; event_queue_escalation_count
        ; event_queue_external_input_count
        ; cursor_ack_count
        ; cursor_swept_stimulus_count
        ; orphan_reaction_stimulus_count
        ; in_progress_stimulus_count
        ; acked_stimulus_count
        ; escalated_stimulus_count
        ; external_input_requested_stimulus_count
        ; pending_stimulus_count
        ; pending_stimulus_ids = []
        ; pending_ids_truncated = false
        ; latest_recorded_at
        ; latest_stimulus_id
        }
    | Sqlite3.Rc.DONE -> Error (Integrity_failure "ledger summary singleton is absent")
    | rc -> Error (sqlite_rc_failure Step_statement db rc))
;;

let read_pending_identity_sample db limit =
  if limit = 0
  then Ok []
  else
    with_statement db
      "SELECT stimulus_id FROM stimulus_state INDEXED BY stimulus_state_pending_order WHERE current_state = 'pending' ORDER BY stimulus_sequence, stimulus_id LIMIT ?"
      (fun stmt ->
        let* () = sqlite_bind db stmt 1 (Sqlite3.Data.INT (Int64.of_int limit)) in
        let rec loop reversed =
          match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok (List.rev reversed)
          | Sqlite3.Rc.ROW ->
            let* stimulus_id = require_text stmt 0 "pending stimulus_id" in
            loop (stimulus_id :: reversed)
          | rc -> Error (sqlite_rc_failure Step_statement db rc)
        in
        loop [])
;;

let empty_exact_summary =
  { row_count = 0
  ; stimulus_count = 0
  ; reaction_count = 0
  ; turn_started_count = 0
  ; event_queue_ack_count = 0
  ; event_queue_requeue_count = 0
  ; event_queue_escalation_count = 0
  ; event_queue_external_input_count = 0
  ; cursor_ack_count = 0
  ; cursor_swept_stimulus_count = 0
  ; orphan_reaction_stimulus_count = 0
  ; in_progress_stimulus_count = 0
  ; acked_stimulus_count = 0
  ; escalated_stimulus_count = 0
  ; external_input_requested_stimulus_count = 0
  ; pending_stimulus_count = 0
  ; pending_stimulus_ids = []
  ; pending_ids_truncated = false
  ; latest_recorded_at = None
  ; latest_stimulus_id = None
  }
;;

let read_exact_summary db ~pending_id_display_limit =
  let* projected = read_projected_summary db in
  let* pending_stimulus_ids =
    read_pending_identity_sample db pending_id_display_limit
  in
  Ok
    { projected with
      pending_stimulus_ids
    ; pending_ids_truncated =
        projected.pending_stimulus_count > List.length pending_stimulus_ids
    }
;;

let read_observation ~base_path ~keeper_name ~pending_id_display_limit =
  if pending_id_display_limit < 0
  then Error (Invalid_transition "pending identity display limit must be non-negative")
  else
    let body db =
      let* cursor = read_current_cursor db in
      let* exact_summary = read_exact_summary db ~pending_id_display_limit in
      Ok { cursor; exact_summary }
    in
    let* result =
      with_validated_read_capability ~base_path ~keeper_name body
    in
    Ok
      (Option.value
         result
         ~default:{ cursor = None; exact_summary = empty_exact_summary })
;;

let current_cursor ~base_path ~keeper_name =
  read_observation ~base_path ~keeper_name ~pending_id_display_limit:0
  |> Result.map (fun observation -> observation.cursor)
;;

let exact_summary ~base_path ~keeper_name ~pending_id_display_limit =
  read_observation ~base_path ~keeper_name ~pending_id_display_limit
  |> Result.map (fun observation -> observation.exact_summary)
;;

let recent_events ~base_path ~keeper_name ~limit =
  if limit <= 0
  then Ok []
  else
    let body db =
      with_read_transaction db (fun () ->
        let sql =
          "SELECT "
          ^ select_event_projection "e"
          ^ " FROM events AS e LEFT JOIN transitions AS t ON t.transition_id = e.transition_id ORDER BY e.sequence DESC LIMIT ?"
        in
        with_statement db sql (fun stmt ->
          let* () = sqlite_bind db stmt 1 (Sqlite3.Data.INT (Int64.of_int limit)) in
          let rec loop reversed =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.DONE -> Ok (List.rev reversed)
            | Sqlite3.Rc.ROW ->
              let* event = stored_joined_event_of_statement stmt ~offset:0 in
              loop (event :: reversed)
            | rc -> Error (sqlite_rc_failure Step_statement db rc)
          in
          loop []))
    in
    let* result = with_database ~base_path ~keeper_name ~create:false body in
    (match result with
     | None -> Ok []
     | Some events -> Ok events)
;;

module For_testing = struct
  let full_schema_validation_count () = Atomic.get full_schema_validation_count

  let close_read_capabilities () =
    match close_all_read_capabilities () with
    | [] -> Ok ()
    | errors -> Error errors
  ;;
end
