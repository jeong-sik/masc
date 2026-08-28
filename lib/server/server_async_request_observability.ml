let access_rejection_code = function
  | Keeper_msg_async.Invalid_base_path _ -> "invalid_base_path"
  | Invalid_caller -> "invalid_caller"
  | Invalid_request_id -> "invalid_request_id"
  | Caller_mismatch -> "caller_mismatch"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular"
  | S_DIR -> "directory"
  | S_CHR -> "character_device"
  | S_BLK -> "block_device"
  | S_LNK -> "symlink"
  | S_FIFO -> "fifo"
  | S_SOCK -> "socket"
;;

let record_error_kind_to_yojson = function
  | Keeper_msg_async.Invalid_record_name -> `Assoc [ "kind", `String "invalid_record_name" ]
  | Record_missing -> `Assoc [ "kind", `String "record_missing" ]
  | Record_not_regular file_kind ->
    `Assoc
      [ "kind", `String "record_not_regular"
      ; "file_kind", `String (file_kind_to_string file_kind)
      ]
  | Record_unreadable reason ->
    `Assoc [ "kind", `String "record_unreadable"; "reason", `String reason ]
  | Record_inspection_failed { reason } ->
    `Assoc [ "kind", `String "record_inspection_failed"; "reason", `String reason ]
  | Record_terminal_status status ->
    `Assoc
      [ "kind", `String "record_terminal_status"
      ; "status", `String (Keeper_msg_async.status_to_string status)
      ]
;;

let record_error_to_yojson
      ({ request_id; kind; _ } : Keeper_msg_async.active_inventory_record_error) =
  match record_error_kind_to_yojson kind with
  | `Assoc fields ->
    `Assoc
      (("request_id", Option.fold ~none:`Null ~some:(fun value -> `String value) request_id)
       :: fields)
  | _ -> assert false
;;

let store_error_to_yojson = function
  | Keeper_msg_async.Inventory_access_rejected rejection ->
    `Assoc
      [ "kind", `String "access_rejected"
      ; "reason", `String (access_rejection_code rejection)
      ]
  | Inventory_directory_rejected _ ->
    `Assoc [ "kind", `String "directory_rejected" ]
  | Inventory_directory_read_failed { reason; _ } ->
    `Assoc
      [ "kind", `String "directory_read_failed"
      ; "reason", `String reason
      ]
;;

module String_set = Set.Make (String)

let runtime_owned_request_ids ~base_path entries =
  let callers =
    List.fold_left
      (fun callers (entry : Keeper_msg_async.entry) ->
         String_set.add entry.submitted_by callers)
      String_set.empty
      entries
  in
  String_set.fold
    (fun caller owned ->
       match Keeper_msg_async.list_for_keeper ~base_path ~caller () with
       | Error _ -> owned
       | Ok entries ->
         List.fold_left
           (fun owned (entry : Keeper_msg_async.entry) ->
              String_set.add entry.request_id owned)
           owned
           entries)
    callers
    String_set.empty
;;

let entry_to_yojson ~runtime_owned_ids (entry : Keeper_msg_async.entry) =
  let ownership =
    if String_set.mem entry.request_id runtime_owned_ids
    then "runtime_owned"
    else "disk_only_ownership_unknown"
  in
  match Keeper_msg_async.entry_to_json entry with
  | `Assoc fields -> `Assoc (("worker_ownership", `String ownership) :: fields)
  | _ -> assert false
;;

let recovery_store_to_string = function
  | Keeper_msg_async.Active_store -> "active"
  | Atomic_staging_store -> "atomic_staging"
;;

let recovery_store_error_to_yojson
      ({ store; reason; _ } : Keeper_msg_async.recovery_store_error) =
  `Assoc
    [ "store", `String (recovery_store_to_string store)
    ; "reason", `String reason
    ]
;;

let recovery_record_error_kind_to_string = function
  | Keeper_msg_async.Recovery_record_unreadable _ -> "record_unreadable"
  | Recovery_record_missing -> "record_missing"
  | Recovery_record_not_file -> "record_not_file"
  | Recovery_record_rejected _ -> "record_rejected"
  | Recovery_terminal_integrity _ -> "terminal_integrity"
  | Recovery_persistence_failed _ -> "persistence_failed"
  | Recovery_source_cleanup_failed -> "source_cleanup_failed"
  | Recovery_entry_exception _ -> "entry_exception"
;;

let recovery_record_error_to_yojson
      ({ store; request_id; keeper_name; kind; _ } :
        Keeper_msg_async.recovery_record_error) =
  `Assoc
    [ "store", `String (recovery_store_to_string store)
    ; "request_id", `String request_id
    ; ( "keeper_name"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) keeper_name )
    ; "kind", `String (recovery_record_error_kind_to_string kind)
    ]
;;

let recovery_report_to_yojson (report : Keeper_msg_async.recovery_report) =
  `Assoc
    [ "lost", `Int report.lost
    ; "finalized", `Int report.finalized
    ; "cleaned", `Int report.cleaned
    ; "staging_files_inspected", `Int report.staging_files_inspected
    ; "staging_files_deleted", `Int report.staging_files_deleted
    ; "staging_files_preserved", `Int report.staging_files_preserved
    ; "unreadable", `Int report.unreadable
    ; "failed", `Int report.failed
    ; "store_errors", `List (List.map recovery_store_error_to_yojson report.store_errors)
    ; "record_errors", `List (List.map recovery_record_error_to_yojson report.record_errors)
    ]
;;

let project ~base_path =
  let startup_recovery =
    Server_bootstrap_maintenance.latest_keeper_msg_recovery_observation ()
    |> Option.fold ~none:`Null ~some:recovery_report_to_yojson
  in
  match Keeper_msg_async.read_durable_active_inventory ~base_path with
  | Error error ->
    `Assoc
      [ "schema", `String "masc.async-request-observation/v1"
      ; "status", `String "unavailable"
      ; "error", store_error_to_yojson error
      ; "startup_recovery", startup_recovery
      ]
  | Ok inventory ->
    let runtime_owned_ids =
      runtime_owned_request_ids ~base_path inventory.entries
    in
    let requests =
      List.map (entry_to_yojson ~runtime_owned_ids) inventory.entries
    in
    let runtime_owned =
      List.fold_left
        (fun count row ->
           match Json_util.assoc_member_opt "worker_ownership" row with
           | Some (`String "runtime_owned") -> count + 1
           | _ -> count)
        0
        requests
    in
    `Assoc
      [ "schema", `String "masc.async-request-observation/v1"
      ; "status", `String "ready"
      ; ( "summary"
        , `Assoc
            [ "active", `Int (List.length requests)
            ; "runtime_owned", `Int runtime_owned
            ; "ownership_unknown", `Int (List.length requests - runtime_owned)
            ; "record_errors", `Int (List.length inventory.record_errors)
            ] )
      ; "requests", `List requests
      ; "record_errors", `List (List.map record_error_to_yojson inventory.record_errors)
      ; "startup_recovery", startup_recovery
      ]
;;
