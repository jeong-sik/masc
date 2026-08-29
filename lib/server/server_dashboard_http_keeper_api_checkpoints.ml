open Server_dashboard_http_keeper_api_types

let stat_json_of_path (path : string) =
  try
    let stat = Unix.stat path in
    `Assoc [ "size_bytes", `Int stat.st_size; "mtime", `Float stat.st_mtime ]
  with
  | Unix.Unix_error _ -> `Null
;;

let agent_core_checkpoint_summary_json
      ~(source_kind : string)
      ~(snapshot_id : string)
      ~(path : string)
      ~(is_current : bool)
      (checkpoint : Agent_core.Checkpoint.t)
  =
  let messages = checkpoint.messages in
  `Assoc
    [ "snapshot_id", `String snapshot_id
    ; "source_kind", `String source_kind
    ; "is_current", `Bool is_current
    ; "status", `String "available"
    ; "path", `String path
    ; "created_at", `Float checkpoint.created_at
    ; "message_count", `Int (List.length messages)
    ; ( "system_prompt_present"
      , `Bool
          (match checkpoint.system_prompt with
           | Some prompt -> Option.is_some (String_util.trim_nonempty prompt)
           | None -> false) )
    ; ( "latest_preview", Json_util.string_opt_to_json (latest_preview_of_messages messages) )
    ; "file_stat", stat_json_of_path path
    ]
;;

(* The fields, not the object: callers that splice this into a larger row need
   the association list, and taking it back apart from a [Yojson.Safe.t] forced
   them to handle a shape this function cannot produce. *)
let checkpoint_load_error_fields
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  : (string * Yojson.Safe.t) list
  =
  let status, kind, detail =
    match error with
    | Not_found -> "missing", "not_found", `Null
    | Store_error detail -> "unavailable", "store_error", `String detail
    | Parse_error detail -> "unavailable", "parse_error", `String detail
    | Io_error detail -> "unavailable", "io_error", `String detail
    | Agent_core_error detail ->
      "unavailable", "agent_core_error", `String detail
  in
  [ "status", `String status
  ; "error_kind", `String kind
  ; "error_detail", detail
  ]
;;

let checkpoint_load_error_json
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  `Assoc (checkpoint_load_error_fields error)
;;

let current_checkpoint_error_json
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  match error with
  | Not_found -> `Null
  | Store_error detail ->
    `Assoc [ "kind", `String "store_error"; "detail", `String detail ]
  | Parse_error detail ->
    `Assoc [ "kind", `String "parse_error"; "detail", `String detail ]
  | Io_error detail ->
    `Assoc [ "kind", `String "io_error"; "detail", `String detail ]
  | Agent_core_error detail ->
    `Assoc [ "kind", `String "agent_core_error"; "detail", `String detail ]
;;

let checkpoint_load_failure_json
      ~(source_kind : string)
      ~(snapshot_id : string)
      ~(path : string)
      ~(is_current : bool)
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  let identity_fields =
    [ "snapshot_id", `String snapshot_id
    ; "source_kind", `String source_kind
    ; "is_current", `Bool is_current
    ; "path", `String path
    ; "file_stat", stat_json_of_path path
    ]
  in
  `Assoc (identity_fields @ checkpoint_load_error_fields error)
;;

let inventory_json (config : Workspace.config) (name : string)
  : [ `OK | `Not_found ] * Yojson.Safe.t
  =
  match Keeper_meta_store.read_meta_resolved config name with
  | Error msg -> `Not_found, `Assoc [ "error", `String msg ]
  | Ok None ->
    ( `Not_found
    , `Assoc [ "error", `String (Printf.sprintf "keeper %S not found" name) ] )
  | Ok (Some (_, meta)) ->
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
    let current_path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id
    in
    let current_json, current_history_snapshot_id, current_status, current_error =
      match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id with
      | Ok checkpoint ->
        let current_history_snapshot_id =
          Keeper_checkpoint_store.agent_core_history_snapshot_id_of_checkpoint checkpoint
        in
        agent_core_checkpoint_summary_json
          ~source_kind:"agent_core_current"
          ~snapshot_id:(Filename.basename current_path)
          ~path:current_path
          ~is_current:true
          checkpoint
        |> fun json -> Some json, current_history_snapshot_id, "available", `Null
      | Error error ->
        let status =
          match error with
          | Keeper_checkpoint_store.Not_found -> "missing"
          | Store_error _ | Parse_error _ | Io_error _ | Agent_core_error _ ->
            "unavailable"
        in
        None, "", status, current_checkpoint_error_json error
    in
    let history_json, history_errors =
      Keeper_checkpoint_store.list_agent_core_history_files ~session_dir
      |> List.filter (fun snapshot_id ->
        snapshot_id <> current_history_snapshot_id)
      |> List.fold_left
           (fun (available, failures) snapshot_id ->
             let path =
               Keeper_checkpoint_store.agent_core_history_path ~session_dir ~snapshot_id
             in
             match
               Keeper_checkpoint_store.load_agent_core_history_file ~session_dir ~snapshot_id
             with
             | Ok checkpoint ->
               ( agent_core_checkpoint_summary_json
                   ~source_kind:"agent_core_history"
                   ~snapshot_id
                   ~path
                   ~is_current:false
                   checkpoint
                 :: available
               , failures )
             | Error error ->
               ( available
               , checkpoint_load_failure_json
                   ~source_kind:"agent_core_history"
                   ~snapshot_id
                   ~path
                   ~is_current:false
                   error
                 :: failures ))
           ([], [])
      |> fun (available, failures) -> List.rev available, List.rev failures
    in
    ( `OK
    , `Assoc
        [ "keeper", `String name
        ; "trace_id", `String trace_id
        ; "session_dir", `String session_dir
        ; ( "current"
          , match current_json with
            | Some json -> json
            | None -> `Null )
        ; "current_status", `String current_status
        ; "current_error", current_error
        ; "history", `List history_json
        ; "history_errors", `List history_errors
        ] )
;;

type purge_report =
  { messages_before : int
  ; messages_after : int
  ; bytes_before : int
  ; bytes_after : int
  ; duplicates_dropped : int
  ; reasoning_blocks_stripped : int
  ; reasoning_messages_dropped : int
  ; tool_results_cleared : int
  }

type purge_result =
  { keeper : string
  ; trace_id : string
  ; apply_allowed : bool
  ; applied : bool
  ; backup_path : string option
  ; report : purge_report
  ; warnings : string list
  }

type purge_error =
  | Purge_invalid_keeper_name of string
  | Purge_keeper_not_found of string
  | Purge_keeper_active of string
  | Purge_checkpoint_unavailable of string
  | Purge_checkpoint_invalid of string
  | Purge_backup_failed of string
  | Purge_source_changed
  | Purge_install_failed of string

let purge_error_to_string = function
  | Purge_invalid_keeper_name keeper ->
    Printf.sprintf "invalid keeper name: %s" keeper
  | Purge_keeper_not_found keeper ->
    Printf.sprintf "keeper %S not found" keeper
  | Purge_keeper_active keeper ->
    Printf.sprintf
      "keeper %S is still registered; shut it down completely before applying checkpoint purge"
      keeper
  | Purge_checkpoint_unavailable detail ->
    "checkpoint unavailable: " ^ detail
  | Purge_checkpoint_invalid detail ->
    "checkpoint purge refused: " ^ detail
  | Purge_backup_failed detail ->
    "checkpoint backup failed: " ^ detail
  | Purge_source_changed ->
    "checkpoint changed after preview; preview the current checkpoint again"
  | Purge_install_failed detail ->
    "checkpoint purge install failed: " ^ detail
;;

let checkpoint_load_error_to_string = function
  | Keeper_checkpoint_store.Not_found -> "not found"
  | Store_error detail -> "store error: " ^ detail
  | Parse_error detail -> "parse error: " ^ detail
  | Io_error detail -> "io error: " ^ detail
  | Agent_core_error detail -> "agent core error: " ^ detail
;;

let checkpoint_ref_create_error_to_string = function
  | Keeper_checkpoint_ref.Negative_turn_count value ->
    Printf.sprintf "negative turn count %d" value
  | Invalid_sha256 value ->
    Printf.sprintf "invalid checkpoint sha256 %S" value
;;

let checkpoint_identity_error_to_string = function
  | Keeper_checkpoint_store.Session_id_invalid detail ->
    "invalid session id: " ^ detail
  | Ref_create_failed error -> checkpoint_ref_create_error_to_string error
;;

let checkpoint_ref_load_error_to_string = function
  | Keeper_checkpoint_store.Ref_not_found -> "not found"
  | Ref_read_failed error -> checkpoint_load_error_to_string error
  | Ref_identity_invalid error -> checkpoint_identity_error_to_string error
  | Ref_session_mismatch { expected; actual } ->
    Printf.sprintf
      "session mismatch expected=%s actual=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string actual)
  | Ref_lock_failed detail -> "checkpoint lock failed: " ^ detail
;;

let checkpoint_cas_error_to_string = function
  | Keeper_checkpoint_store.Source_unavailable error ->
    "source unavailable: " ^ checkpoint_ref_load_error_to_string error
  | Source_changed _ -> "source changed"
  | Candidate_identity_invalid error ->
    "candidate identity invalid: " ^ checkpoint_identity_error_to_string error
  | Candidate_session_mismatch { expected; candidate } ->
    Printf.sprintf
      "candidate session mismatch expected=%s candidate=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string candidate)
  | Candidate_generation_mismatch { expected; candidate } ->
    Printf.sprintf
      "candidate generation mismatch expected=%d candidate=%d"
      expected
      candidate
  | Candidate_turn_regressed { source_turn; candidate_turn } ->
    Printf.sprintf
      "candidate turn regressed source=%d candidate=%d"
      source_turn
      candidate_turn
  | Commit_not_installed error -> Keeper_fs.durable_write_error_to_string error
;;

let exception_detail (exn, _backtrace) = Printexc.to_string exn

let checkpoint_installation_auxiliary_to_string = function
  | Keeper_checkpoint_store.Commit_durability_unknown error ->
    "commit durability unknown: " ^ Keeper_fs.durable_write_error_to_string error
  | Commit_observer_failed failure ->
    "commit observer failed: " ^ exception_detail failure
  | Release_process_lock_failed error ->
    "checkpoint lock release failed: "
    ^ File_lock_eio.durable_lock_error_to_string error
  | Post_commit_unwind_interrupted failure ->
    "post-commit unwind interrupted: " ^ exception_detail failure
  | History_write_failed failure ->
    "history write failed: " ^ exception_detail failure
;;

let purge_report_json report =
  `Assoc
    [ "messages_before", `Int report.messages_before
    ; "messages_after", `Int report.messages_after
    ; "bytes_before", `Int report.bytes_before
    ; "bytes_after", `Int report.bytes_after
    ; "bytes_removed", `Int (report.bytes_before - report.bytes_after)
    ; "duplicates_dropped", `Int report.duplicates_dropped
    ; "reasoning_blocks_stripped", `Int report.reasoning_blocks_stripped
    ; "reasoning_messages_dropped", `Int report.reasoning_messages_dropped
    ; "tool_results_cleared", `Int report.tool_results_cleared
    ]
;;

let purge_result_json ~action result =
  `Assoc
    [ "schema", `String "masc.keeper_checkpoint_purge.v1"
    ; "ok", `Bool true
    ; "action", `String action
    ; "keeper", `String result.keeper
    ; "trace_id", `String result.trace_id
    ; "apply_allowed", `Bool result.apply_allowed
    ; "applied", `Bool result.applied
    ; "backup_path", Json_util.string_opt_to_json result.backup_path
    ; "report", purge_report_json result.report
    ; "warnings", Json_util.json_string_list result.warnings
    ]
;;

let backup_path_for_source ~config ~trace_id
      (source_ref : Keeper_checkpoint_ref.t) =
  let backup_dir =
    Filename.concat
      (Workspace.masc_root_dir config)
      (Printf.sprintf
         "backups-checkpoint-purge-%s-%s"
         trace_id
         source_ref.sha256)
  in
  Filename.concat backup_dir (trace_id ^ ".json")
;;

let ensure_exact_backup ~config ~trace_id ~source_ref source_bytes =
  let backup_path = backup_path_for_source ~config ~trace_id source_ref in
  let read_back () =
    try Ok (Fs_compat.load_file backup_path) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  match Fs_compat.load_file_opt backup_path with
  | Some existing when String.equal existing source_bytes -> Ok backup_path
  | Some _ ->
    Error
      (Printf.sprintf
         "existing backup content does not match source ref %s"
         source_ref.sha256)
  | None ->
    (match
       Keeper_fs.save_bytes_durable_atomic
         ~ownership_root:(Workspace.masc_root_dir config)
         backup_path
         source_bytes
     with
     | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
     | Ok () ->
       (match read_back () with
        | Ok exact when String.equal exact source_bytes -> Ok backup_path
        | Ok _ -> Error "backup exact read-back mismatch"
        | Error detail -> Error ("backup read-back failed: " ^ detail)))
;;

let checkpoint_purge_error_to_string = function
  | Keeper_checkpoint_purge.Invalid_config detail -> "invalid config: " ^ detail
  | Invalid_input_structure structural ->
    Keeper_transcript_unit.show_structural_error structural
  | Invalid_output_structure structural ->
    "purge produced invalid structure: "
    ^ Keeper_transcript_unit.show_structural_error structural
;;

let purge_current_unlocked config ~keeper_name ~apply =
  match Keeper_meta_store.read_meta_resolved config keeper_name with
  | Error detail -> Error (Purge_checkpoint_unavailable detail)
  | Ok None -> Error (Purge_keeper_not_found keeper_name)
  | Ok (Some (_, meta)) ->
    if apply
       && Keeper_registry.is_registered
            ~base_path:config.Workspace.base_path
            keeper_name
    then Error (Purge_keeper_active keeper_name)
    else
      let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
      (match
         Keeper_checkpoint_store.load_agent_core_exact_snapshot
           ~session_dir
           ~session_id:trace_id
       with
       | Error error ->
         Error
           (Purge_checkpoint_unavailable
              (checkpoint_ref_load_error_to_string error))
       | Ok snapshot ->
         let source_ref = Keeper_checkpoint_store.exact_snapshot_reference snapshot in
         let source_bytes =
           Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot
         in
         let purge_result =
           Domain_pool_ref.submit_cpu_or_inline (fun () ->
             match Agent_core.Checkpoint.of_string source_bytes with
             | Error error ->
               Error
                 (Purge_checkpoint_invalid
                    (Agent_core.Error.to_string error))
             | Ok checkpoint ->
               (match
                  Keeper_checkpoint_purge.purge
                    ~config:Keeper_checkpoint_purge.default_config
                    checkpoint
                with
                | Error error ->
                  Error
                    (Purge_checkpoint_invalid
                       (checkpoint_purge_error_to_string error))
                | Ok (purged, purge_report) ->
                  let purged_bytes = Agent_core.Checkpoint.to_string purged in
                  Ok (purged, purged_bytes, purge_report)))
         in
         (match purge_result with
          | Error _ as error -> error
          | Ok (purged, purged_bytes, raw_report) ->
            let report =
              { messages_before = raw_report.messages_before
              ; messages_after = raw_report.messages_after
              ; bytes_before = String.length source_bytes
              ; bytes_after = String.length purged_bytes
              ; duplicates_dropped = raw_report.duplicates_dropped
              ; reasoning_blocks_stripped = raw_report.reasoning_blocks_stripped
              ; reasoning_messages_dropped = raw_report.reasoning_messages_dropped
              ; tool_results_cleared = raw_report.tool_results_cleared
              }
            in
            let apply_allowed =
              not
                (Keeper_registry.is_registered
                   ~base_path:config.Workspace.base_path
                   keeper_name)
            in
            if not apply
            then
              Ok
                { keeper = keeper_name
                ; trace_id
                ; apply_allowed
                ; applied = false
                ; backup_path = None
                ; report
                ; warnings = []
                }
            else if String.equal source_bytes purged_bytes
            then
              Ok
                { keeper = keeper_name
                ; trace_id
                ; apply_allowed = true
                ; applied = false
                ; backup_path = None
                ; report
                ; warnings = []
                }
            else
              (match
                 ensure_exact_backup
                   ~config
                   ~trace_id
                   ~source_ref
                   source_bytes
               with
               | Error detail -> Error (Purge_backup_failed detail)
               | Ok backup_path ->
                 (match
                    Keeper_checkpoint_store.save_agent_core_if_source
                      ~session_dir
                      ~expected_source_ref:source_ref
                      purged
                  with
                  | Keeper_checkpoint_store.Not_installed
                      { cause = Source_changed _; _ } ->
                    Error Purge_source_changed
                  | Not_installed { cause; _ } ->
                    Error
                      (Purge_install_failed
                         (checkpoint_cas_error_to_string cause))
                  | Installed installed ->
                    Ok
                      { keeper = keeper_name
                      ; trace_id
                      ; apply_allowed = true
                      ; applied = true
                      ; backup_path = Some backup_path
                      ; report
                      ; warnings =
                          List.map
                            checkpoint_installation_auxiliary_to_string
                            installed.auxiliary
                      }))))
;;

let purge_current config ~keeper_name ~apply =
  let keeper_name = String.trim keeper_name in
  if not (Keeper_config.validate_name keeper_name)
  then Error (Purge_invalid_keeper_name keeper_name)
  else if apply
  then
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun () -> purge_current_unlocked config ~keeper_name ~apply:true)
  else purge_current_unlocked config ~keeper_name ~apply:false
;;

let linked_artifact_json ~kind path =
  `Assoc
    [ "kind", `String kind
    ; "path", `String path
    ; "present", `Bool (Fs_compat.file_exists path)
    ; "file_stat", stat_json_of_path path
    ]
;;
