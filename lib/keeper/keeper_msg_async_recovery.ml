open Result.Syntax
open Keeper_msg_async_types
open Keeper_msg_async_record
open Keeper_msg_async_state
open Keeper_msg_async_locks
open Keeper_msg_async_store

let status_after_worker_absence ~reason = function
  | Cancelling {reason;cancelled_by} -> Cancelled {reason;cancelled_by}
  | Queued | Running -> Lost {reason}
  | (Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ | Done _) as terminal -> terminal

let settle_unowned_record_after_recovery ?source_path (entry : entry) =
  let reason =
    "keeper_msg request was accepted but no live worker owns it; the server may have \
     restarted or evicted the request before terminal result"
  in
  let settled =
    { entry with status = status_after_worker_absence ~reason entry.status;
      completed_at = Some (Time_compat.now ()) }
  in
  match
    persist_entry ~ops:production_request_ops ?source_path settled
    |> observe_persist_error ~operation:"recovery" settled
  with
  | Ok () -> Ok settled
  | Error error -> Error (persist_error_to_string error)
;;

let request_has_live_worker ~base_path ~submitted_by request_id =
  let key = request_key ~base_path ~submitted_by ~request_id in
  Eio.Mutex.use_ro mu (fun () -> Request_table.mem pending key)
;;

type terminal_destination_state =
  | No_terminal_destination
  | Cleanup_source
  | Invalid_terminal_destination of persist_integrity_error

let terminal_destination_state (entry : entry) =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Invalid_terminal_destination Unsafe_request_id
  | Some terminal_path ->
    (match
       load_record_at_path
         ~base_path:entry.base_path
         ~request_id:entry.request_id
         terminal_path
     with
      | Found terminal_entry when is_terminal_status terminal_entry.status ->
        if not (same_request_identity entry terminal_entry)
        then Invalid_terminal_destination Terminal_conflict
        else if
          (not (is_terminal_status entry.status))
          || same_entry_record terminal_entry entry
        then Cleanup_source
        else
          Invalid_terminal_destination Terminal_conflict
      | Found _ ->
        Invalid_terminal_destination Terminal_partition_nonterminal
      | Unreadable reason ->
        Invalid_terminal_destination (Terminal_unreadable reason)
      | Absent -> No_terminal_destination
      | Rejected rejection ->
        Invalid_terminal_destination (Terminal_access_rejected rejection))
;;

let finalize_existing_terminal_source ~(entry : entry) source_path =
  with_entry_persistence_transaction entry (fun () ->
    match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
    | None -> Error (Integrity_failed Unsafe_request_id)
    | Some terminal_path ->
      let* () = save_entry_durable ~ops:production_request_ops terminal_path entry in
      Ok
        (remove_duplicate_source_unlocked
           ~ops:production_request_ops
           ~entry
           source_path))
;;

let empty_recovery_report =
  { lost = 0
  ; finalized = 0
  ; cleaned = 0
  ; staging_files_inspected = 0
  ; staging_files_deleted = 0
  ; staging_files_preserved = 0
  ; unreadable = 0
  ; failed = 0
  ; store_errors = []
  ; record_errors = []
  }
;;

let recovery_record_error_kind_to_string = function
  | Recovery_record_unreadable reason -> "unreadable: " ^ reason
  | Recovery_record_missing -> "record disappeared during recovery"
  | Recovery_record_not_file -> "record path is not a regular file"
  | Recovery_record_rejected rejection ->
    "record identity rejected: "
    ^ (access_rejection_to_json rejection |> Yojson.Safe.to_string)
  | Recovery_terminal_integrity reason -> "terminal integrity: " ^ reason
  | Recovery_persistence_failed reason -> "persistence failed: " ^ reason
  | Recovery_source_cleanup_failed -> "source cleanup failed"
  | Recovery_entry_exception reason -> "entry exception: " ^ reason
;;

let record_error ~store ~path ~request_id ?keeper_name kind report =
  let keeper_label =
    match keeper_name with
    | Some keeper_name -> keeper_name
    | None -> "<unattributed>"
  in
  Log.Keeper.error
    "keeper_msg_async: recovery record failed store=%s request_id=%s keeper=%s path=%s error=%s"
    (match store with
     | Active_store -> "active"
     | Atomic_staging_store -> "atomic_staging")
    request_id
    keeper_label
    path
    (recovery_record_error_kind_to_string kind);
  { report with
    record_errors =
      { store; path; request_id; keeper_name; kind } :: report.record_errors
  }
;;

let recover_record_path ~base_path ~request_id path report =
  match load_record_at_path ~base_path ~request_id path with
  | Found entry ->
    (match terminal_destination_state entry with
     | Cleanup_source ->
       (match
          with_entry_persistence_transaction entry (fun () ->
            Ok
              (remove_duplicate_source_unlocked
                 ~ops:production_request_ops
                 ~entry
                 path))
        with
        | Ok true -> { report with cleaned = report.cleaned + 1 }
        | Ok false ->
          { (record_error
               ~store:Active_store
               ~path
               ~request_id
               ~keeper_name:entry.keeper_name
               Recovery_source_cleanup_failed
               report) with
            failed = report.failed + 1
          }
        | Error error ->
          ignore
            (observe_persist_error
               ~operation:"recovery_source_cleanup"
               entry
               (Error error)
              : (unit, persist_error) result);
          { (record_error
               ~store:Active_store
               ~path
               ~request_id
               ~keeper_name:entry.keeper_name
               (Recovery_persistence_failed (persist_error_to_string error))
               report) with
            failed = report.failed + 1
          })
     | Invalid_terminal_destination integrity_error ->
       ignore
         (observe_persist_error
            ~operation:"recovery_terminal_conflict"
            entry
           (Error (Integrity_failed integrity_error))
           : (unit, persist_error) result);
       { (record_error
            ~store:Active_store
            ~path
            ~request_id
            ~keeper_name:entry.keeper_name
            (Recovery_terminal_integrity
               (persist_integrity_error_to_string integrity_error))
            report) with
         failed = report.failed + 1
       }
     | No_terminal_destination ->
       if is_terminal_status entry.status
       then (
         match
           finalize_existing_terminal_source ~entry path
         with
         | Ok true -> { report with finalized = report.finalized + 1 }
         | Ok false ->
           { (record_error
                ~store:Active_store
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                Recovery_source_cleanup_failed
                report) with
             failed = report.failed + 1
           }
         | Error error ->
           ignore
             (observe_persist_error
                ~operation:"active_terminal_finalize"
                entry
                (Error error)
               : (unit, persist_error) result);
           { (record_error
                ~store:Active_store
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                (Recovery_persistence_failed (persist_error_to_string error))
                report) with
             failed = report.failed + 1
           })
       else if
         request_has_live_worker
           ~base_path
           ~submitted_by:entry.submitted_by
           request_id
       then report
       else (
         match settle_unowned_record_after_recovery ~source_path:path entry with
         | Ok settled ->
           (match settled.status with
            | Cancelled _ | Done _ | Persistence_failed _ | Waiting_for_dependencies _ ->
              { report with finalized = report.finalized + 1 }
            | Lost _ -> { report with lost = report.lost + 1 }
            | Queued | Running | Cancelling _ ->
              { (record_error ~store:Active_store ~path ~request_id
                   ~keeper_name:entry.keeper_name
                   (Recovery_persistence_failed "worker absence did not settle the request") report) with
                failed = report.failed + 1 })
         | Error reason ->
           { (record_error
                ~store:Active_store
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                (Recovery_persistence_failed reason)
                report) with
             failed = report.failed + 1
           }))
  | Unreadable reason ->
    { (record_error
         ~store:Active_store
         ~path
         ~request_id
         (Recovery_record_unreadable reason)
         report) with
      unreadable = report.unreadable + 1
    }
  | Absent ->
    { (record_error
         ~store:Active_store
         ~path
         ~request_id
         Recovery_record_missing
         report) with
      failed = report.failed + 1
    }
  | Rejected rejection ->
    { (record_error
         ~store:Active_store
         ~path
         ~request_id
         (Recovery_record_rejected rejection)
         report) with
      failed = report.failed + 1
    }
;;

let store_error ~store ~path reason report =
  { report with
    failed = report.failed + 1
  ; store_errors = { store; path; reason } :: report.store_errors
  }
;;

let merge_staging_cleanup_report cleanup report =
  let record_cleaned size_class count =
    if count > 0
    then
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_fs_atomic_orphans_cleaned
        ~labels:
          [ "size_class", Fs_compat.Atomic_orphan_size_class.to_label size_class ]
        ~delta:(Float.of_int count)
        ()
  in
  record_cleaned Fs_compat.Atomic_orphan_size_class.Empty cleanup.Fs_compat.deleted;
  record_cleaned
    Fs_compat.Atomic_orphan_size_class.With_data
    cleanup.Fs_compat.preserved;
  let report =
    { report with
      staging_files_inspected =
        report.staging_files_inspected + cleanup.Fs_compat.inspected
    ; staging_files_deleted = report.staging_files_deleted + cleanup.Fs_compat.deleted
    ; staging_files_preserved =
        report.staging_files_preserved + cleanup.Fs_compat.preserved
    }
  in
  List.fold_left
    (fun report failure ->
       store_error
         ~store:Atomic_staging_store
         ~path:failure.Fs_compat.path
         (Fs_compat.atomic_orphan_cleanup_failure_to_string failure)
         report)
    report
    cleanup.Fs_compat.failures
;;

let run_staging_cleanup_in_systhread ~ownership_root path =
  let result =
    Eio_guard.run_in_systhread ~label:"msg-async-cleanup-atomic-orphans" (fun () ->
      Fs_compat.cleanup_atomic_orphans
        ~ownership_root
        ~base_path:path
        ())
  in
  Eio_guard.check_if_ready ();
  result
;;

let sweep_request_staging_files ~base_path report =
  let staging = atomic_staging_dir ~base_path in
  let cleanup = run_staging_cleanup_in_systhread ~ownership_root:base_path staging in
  if cleanup.deleted + cleanup.preserved > 0
  then
    Log.Keeper.warn
      "keeper_msg_async: startup atomic staging cleanup deleted=%d preserved=%d staging=%s"
      cleanup.deleted
      cleanup.preserved
      staging;
  merge_staging_cleanup_report cleanup report
;;

let recover_active_record_directory ~base_path dir report =
  try
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path dir with
    | Ok Fs_compat.Owned_directory_missing -> report
    | Error rejection ->
      store_error
        ~store:Active_store
        ~path:dir
        (Fs_compat.owned_directory_chain_rejection_to_string rejection)
        report
    | Ok (Fs_compat.Owned_directory _) ->
      Fs_compat.read_dir dir
      |> List.fold_left
           (fun report name ->
              Eio_guard.fair_yield ();
              match request_id_of_record_filename name with
              | None -> report
              | Some request_id ->
                let path = Filename.concat dir name in
                (try
                   match Unix.lstat path with
                   | stat when stat.Unix.st_kind = Unix.S_REG ->
                     with_store_transition_lock
                       ~base_path
                       ~request_id
                       (fun () ->
                          recover_record_path
                            ~base_path
                            ~request_id
                            path
                            report)
                   | _ ->
                     { (record_error
                          ~store:Active_store
                          ~path
                          ~request_id
                          Recovery_record_not_file
                          report) with
                       failed = report.failed + 1
                     }
                   | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                     { (record_error
                          ~store:Active_store
                          ~path
                          ~request_id
                          Recovery_record_missing
                          report) with
                       failed = report.failed + 1
                     }
                 with
                 | Eio.Cancel.Cancelled _ as exn -> raise exn
                 | exn ->
                   Log.Keeper.error
                     "keeper_msg_async: recovery entry failed request_id=%s path=%s error=%s"
                     request_id
                     path
                     (Printexc.to_string exn);
                   { (record_error
                        ~store:Active_store
                        ~path
                        ~request_id
                        (Recovery_entry_exception (Printexc.to_string exn))
                        report) with
                     failed = report.failed + 1
                   }))
           report
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error
      "keeper_msg_async: recovery directory failed dir=%s error=%s"
      dir
      (Printexc.to_string exn);
    store_error ~store:Active_store ~path:dir (Printexc.to_string exn) report
;;

let recover_lost_disk_records_canonical ~base_path =
  let active_dir = active_request_dir ~base_path in
  let report =
    sweep_request_staging_files ~base_path empty_recovery_report
    |> recover_active_record_directory ~base_path active_dir
  in
  { report with
    store_errors = List.rev report.store_errors
  ; record_errors = List.rev report.record_errors
  }
;;

let recover_lost_disk_records ~base_path () =
  match canonical_base_path base_path with
  | Ok base_path -> recover_lost_disk_records_canonical ~base_path
  | Error rejection ->
    Log.Keeper.error
      "keeper_msg_async: recovery rejected base_path error=%s"
      (Yojson.Safe.to_string (access_rejection_to_json rejection));
    { empty_recovery_report with failed = 1 }
;;
