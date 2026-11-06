(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Process memory owns active request workers only. Terminal entries leave the
    active index after a durable namespace move into the terminal partition and
    remain queryable by exact request id until an explicit cleanup policy
    removes them. Startup recovery scans only the active partition; historical
    terminal volume is not on the synchronous recovery path. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

open Result.Syntax

include Keeper_msg_async_types
open Keeper_msg_async_record
include Keeper_msg_async_state
include Keeper_msg_async_locks
include Keeper_msg_async_store

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

let with_lock f = Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

let validate_request_store_root ~base_path =
  match
    Fs_compat.inspect_owned_directory_chain
      ~ownership_root:base_path
      (request_dir ~base_path)
  with
  | Ok (Fs_compat.Owned_directory_missing | Fs_compat.Owned_directory _) -> Ok ()
  | Error rejection ->
    Error
      (Invalid_base_path
         { reason = Fs_compat.owned_directory_chain_rejection_to_string rejection })
;;

let reserve_new_request
      ~ops
      ~base_path
      ~submitted_by
      ~keeper_name
      ~request_context
  =
  let rec reserve () =
    let request_id = ops.generate_request_id () in
    if not (is_safe_request_id request_id)
    then reserve ()
    else
      match
        with_store_transition_lock ~base_path ~request_id (fun () ->
          match load_record_canonical_located ~base_path ~request_id with
          | Located_absent ->
            with_lock (fun () ->
              let reservation_key : Store_transition_key.t =
                { base_path; request_id }
              in
              if Store_transition_table.mem reserved_request_ids reservation_key
              then `Collision
              else
                let entry =
                  { request_id
                  ; keeper_name
                  ; base_path
                  ; submitted_by
                  ; request_context
                  ; status = Queued
                  ; submitted_at = Time_compat.now ()
                  ; completed_at = None
                  }
                in
                let key = request_key ~base_path ~submitted_by ~request_id in
                let transition_lock = Eio.Mutex.create () in
                Store_transition_table.add
                  reserved_request_ids
                  reservation_key
                  ();
                Request_table.add pending key entry;
                Request_table.add transition_locks key transition_lock;
                `Reserved (request_id, entry, key, transition_lock))
          | Located _ -> `Collision
          | Located_unreadable _ ->
            (match validate_request_store_root ~base_path with
             | Ok () -> `Collision
             | Error rejection -> `Rejected rejection)
          | Located_rejected rejection -> `Rejected rejection)
      with
      | `Reserved reserved -> Ok reserved
      | `Collision -> reserve ()
      | `Rejected rejection -> Error rejection
  in
  match validate_request_store_root ~base_path with
  | Ok () -> reserve ()
  | Error _ as error -> error
;;

let remove_runtime_tables_if_owned ~release_reservation key transition_lock =
  with_lock (fun () ->
    match Request_table.find_opt transition_locks key with
    | Some current when current == transition_lock ->
      if release_reservation
      then
        Store_transition_table.remove
          reserved_request_ids
          ({ base_path = key.base_path; request_id = key.request_id }
            : Store_transition_key.t);
      Request_table.remove pending key;
      Request_table.remove transition_locks key
    | Some _ | None -> ())
;;

let remove_runtime_if_owned =
  remove_runtime_tables_if_owned ~release_reservation:true
;;

let detach_runtime_preserving_reservation_if_owned =
  remove_runtime_tables_if_owned ~release_reservation:false
;;

let publish_if_owned key transition_lock entry =
  with_lock (fun () ->
    match Request_table.find_opt transition_locks key with
    | Some current when current == transition_lock ->
      Request_table.replace pending key entry
    | Some _ | None -> ())
;;

let project_canonical_integrity_failure_locked ~ops key transition_lock
    (attempted_entry : entry) =
  (* An integrity error means another durable record is already authoritative
     or the namespace cannot be trusted. Do not attempt a competing marker
     write and do not shadow it with process-local polling truth. The closed
     projection carries exact canonical lookup truth, including an explicit
     load error when no terminal [request_status] can represent it. *)
  ops.before_integrity_projection ();
  let poll_result =
    load_record_canonical
      ~base_path:attempted_entry.base_path
      ~request_id:attempted_entry.request_id
  in
  (match poll_result with
   | Absent ->
     (* Keep the ambiguous request id reserved for request-local
        reconciliation, but do not turn one request's persistence failure into
        lifecycle authority over later work in the Keeper lane. *)
     detach_runtime_preserving_reservation_if_owned key transition_lock
   | Found _ | Unreadable _ | Rejected _ ->
     remove_runtime_if_owned key transition_lock);
  match poll_result with
  | Found canonical when is_terminal_status canonical.status ->
    Status_settlement
      { entry = canonical
      ; durability = Durable
      ; origin = Canonical_reconciliation
      }
  | (Absent | Unreadable _ | Rejected _ | Found _) as poll_result -> Settlement_projection_error { attempted_entry; poll_result }
;;

let persist_failure_locked ~ops key transition_lock (attempted_entry : entry) reason =
  let failure_entry =
    { attempted_entry with
      status =
        Persistence_failed
          { attempted_status = (match attempted_entry.status with
              | Persistence_failed {attempted_status;_} -> attempted_status
              | Queued | Running | Cancelling _ | Lost _ | Cancelled _
              | Waiting_for_dependencies _ | Done _ -> State_transition (status_to_string attempted_entry.status))
          ; reason }
    ; completed_at = Some (Time_compat.now ())
    }
  in
  match
    persist_entry ~ops failure_entry
    |> observe_persist_error ~operation:"persistence_failure_marker" failure_entry
  with
  | Ok () ->
    remove_runtime_if_owned key transition_lock;
    Status_settlement
      { entry = failure_entry
      ; durability = Durable
      ; origin = Transition_commit
      }
  | Error (Write_failed (Published_uncertain _)) ->
    publish_if_owned key transition_lock failure_entry;
    Status_settlement
      { entry = failure_entry
      ; durability = Volatile_persistence_failure
      ; origin = Transition_commit
      }
  | Error (Write_failed (Not_published _)) ->
    (* The durable row still contains the previous non-terminal status. Keep
       an explicit volatile terminal overlay in this process so polling cannot
       hang indefinitely; restart recovery later converts the stale durable
       row to typed [Lost]. *)
    publish_if_owned key transition_lock failure_entry;
    Status_settlement
      { entry = failure_entry
      ; durability = Volatile_persistence_failure
      ; origin = Transition_commit
      }
  | Error (Integrity_failed _) ->
    project_canonical_integrity_failure_locked
      ~ops
      key
      transition_lock
      failure_entry
;;

let transition_lock_for_key key =
  with_lock (fun () -> Request_table.find_opt transition_locks key)
;;

let with_canonical_request_read ~base_path ~caller ~request_id f =
  let read () = with_store_transition_lock ~base_path ~request_id f in
  let key = request_key ~base_path ~submitted_by:caller ~request_id in
  (* Status writers hold this owner lock through durable replacement and
     runtime publication/removal. The store lock alone only excludes other
     canonical readers and startup recovery, not a live status writer.
     Preserve the writer-to-store order; startup recovery never acquires an
     owner's transition lock while holding the store lock. *)
  match transition_lock_for_key key with
  | None -> read ()
  | Some owner_lock -> Eio.Mutex.use_ro owner_lock read
;;

let set_status ~ops ?(preserve_terminal = false) key status =
  match transition_lock_for_key key with
  | None -> None
  | Some transition_lock ->
    Eio.Mutex.use_rw ~protect:true transition_lock (fun () ->
      let current =
        with_lock (fun () ->
          match
            Request_table.find_opt transition_locks key,
            Request_table.find_opt pending key
          with
          | Some owned, Some entry when owned == transition_lock -> Some entry
          | _ -> None)
      in
      match current with
      | None -> None
      | Some entry when preserve_terminal && is_terminal_status entry.status -> None
      | Some { status = Cancelling _; _ } when status = Running -> None
      | Some
          ({ status =
               ( Queued
               | Running
               | Cancelling _
               | Lost _
               | Cancelled _
               | Persistence_failed _
               | Waiting_for_dependencies _
               | Done _ )
           ; _
           } as entry) ->
        (* A closed worker scope cannot consume a pending cancellation,
           including when signalling failed and the worker returned normally.
           The exact durable intent wins over any ordinary terminal outcome;
           persistence failure remains explicit. *)
        let status = match entry.status with
          | Cancelling {reason;cancelled_by} ->
            (match status with
             | Lost _ | Cancelled _ | Waiting_for_dependencies _ | Done _ -> Cancelled {reason;cancelled_by}
             | Queued | Running | Cancelling _ | Persistence_failed _ -> status)
          | Queued | Running | Lost _ | Cancelled _ | Persistence_failed _
          | Waiting_for_dependencies _ | Done _ ->
            (match status with
             | Lost {reason} -> status_after_worker_absence ~reason entry.status
             | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
             | Waiting_for_dependencies _ | Done _ -> status) in
        let completed_at =
          match status with
          | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
            (* NDT-OK: completed_at is observational wall-clock metadata for
               terminal request records; state transitions are status-derived. *)
            Some (Time_compat.now ())
          | Queued | Running | Cancelling _ -> None
        in
        let updated = { entry with status; completed_at } in
        (match
           persist_entry ~ops updated
           |> observe_persist_error ~operation:"status_update" updated
         with
         | Ok () ->
           if is_terminal_status updated.status
           then remove_runtime_if_owned key transition_lock
           else publish_if_owned key transition_lock updated;
           Some
             (Status_settlement
                { entry = updated
                ; durability = Durable
                ; origin = Transition_commit
                })
         | Error (Write_failed (Published_uncertain _)) ->
           (* The new bytes are visible but their parent-directory fsync did
              not commit. Keep the typed attempted state in memory so exact
              poll cannot disagree with the currently published file, and
              report volatile durability to every live projection. *)
           publish_if_owned key transition_lock updated;
           Some
             (Status_settlement
                { entry = updated
                ; durability = Volatile_persistence_failure
                ; origin = Transition_commit
                })
         | Error (Write_failed (Not_published error)) ->
           Some
             (persist_failure_locked
                ~ops
                key
                transition_lock
                updated
                (Keeper_fs.durable_write_error_to_string error))
         | Error (Integrity_failed _) ->
           Some
             (project_canonical_integrity_failure_locked
                ~ops
                key
                transition_lock
                updated)))
;;

let set_status_protected ~ops ?preserve_terminal key status =
  Eio.Cancel.protect (fun () -> set_status ~ops ?preserve_terminal key status)
;;

let clear_active_switch key =
  Eio.Cancel.protect (fun () ->
    with_lock (fun () -> Request_table.remove active_switches key))
;;

let cancelled_status ~cancelled_by reason =
  Cancelled { reason; cancelled_by }
;;

let operator_cancel_reason = "keeper_msg request was cancelled by operator"

let operator_cancelling_status () =
  Cancelling
    { reason = operator_cancel_reason
    ; cancelled_by = worker_cancel_source_to_string Operator_request
    }
;;

let operator_cancelled_status () =
  cancelled_status
    ~cancelled_by:(worker_cancel_source_to_string Operator_request)
    operator_cancel_reason
;;

let runtime_cancelled_status () =
  cancelled_status
    ~cancelled_by:"runtime"
    "keeper_msg worker was cancelled by runtime before terminal result"
;;

let submit_worker_with_ops ops ?request_context ?on_accepted ?on_worker_aborted
    ?on_worker_settled ~background_sw ~base_path ~caller
    ~(f : request_id:string -> Eio.Switch.t -> worker_outcome)
    ~keeper_name () :
    (submit_outcome, submit_error) result =
  let* request_context =
    normalize_request_context request_context
    |> Result.map_error (fun reason -> Submit_invalid_request_context { reason })
  in
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Error (Submit_rejected rejection)
  | Ok (base_path, submitted_by) ->
    (match Keeper_id.Keeper_name.of_string keeper_name with
     | Error reason -> Error (Submit_invalid_keeper_name { reason })
     | Ok keeper_name_id ->
    let keeper_name = Keeper_id.Keeper_name.to_string keeper_name_id in
    (* One admission deadline per submit, shared by the submission-lane and
       persistence-lane acquisitions below (RFC-0348 PR-1, #25398). *)
    let wait_budget_sec =
      Env_config_keeper.KeeperLaneGate.admission_wait_budget_sec ()
    in
    let admission_started = Mtime_clock.now () in
    let remaining_budget () =
      Float.max 0.0 (wait_budget_sec -. elapsed_seconds admission_started)
    in
    (try
       with_keeper_submission_lock
         ~wait_budget:(remaining_budget ())
         ~base_path
         ~keeper_name:keeper_name_id
         (fun () ->
    match
      reserve_new_request
        ~ops
        ~base_path
        ~submitted_by
        ~keeper_name
        ~request_context
    with
    | Error rejection -> Error (Submit_rejected rejection)
    | Ok (request_id, entry, key, transition_lock) ->
    (* Any exceptional exit before the request is durably accepted must not
       leak the fresh reservation: the finally below drops it exactly like
       the [Not_published] rollback path. Once the worker daemon is forked
       and the caller gets [Durably_accepted], ownership has moved to the
       active request and the finally must stand down. *)
    let durably_accepted = ref false in
    Fun.protect
      ~finally:(fun () ->
        if not !durably_accepted then remove_runtime_if_owned key transition_lock)
      (fun () ->
    let reconciliation_outcome reason =
      Ok
        { request_id
        ; acceptance = Reconciliation_required { reason }
        }
    in
    let initial_persistence =
      try
        with_keeper_persistence_lock
          ~wait_budget:(remaining_budget ())
          ~base_path
          ~keeper_name:keeper_name_id
          (fun () ->
           match
             persist_entry_unlocked ~ops entry
             |> observe_persist_error ~operation:"initial" entry
           with
           | Ok () -> `Persisted
           | Error error ->
             let reason = persist_error_to_string error in
             (match error with
              | Write_failed (Published_uncertain _) ->
                (match active_record_path ~base_path ~request_id with
                 | None ->
                   detach_runtime_preserving_reservation_if_owned
                     key
                     transition_lock;
                   `Settled
                     (reconciliation_outcome
                        (Printf.sprintf
                           "%s; published request path could not be reconstructed for durable rollback"
                           reason))
                 | Some path ->
                   (match
                      rollback_rejected_record_file_unlocked
                        ~ops
                        ~ownership_root:base_path
                        ~keeper_name:entry.keeper_name
                        path
                    with
                    | Ok () ->
                      remove_runtime_if_owned key transition_lock;
                      `Settled (Error (Initial_persistence_failed { reason }))
                    | Error rollback_error ->
                      detach_runtime_preserving_reservation_if_owned
                        key
                        transition_lock;
                      `Settled
                        (reconciliation_outcome
                           (Printf.sprintf
                              "%s; rollback=%s"
                              reason
                              (Keeper_fs.durable_remove_error_to_string
                                 rollback_error)))))
              | Write_failed (Not_published _) | Integrity_failed _ ->
                remove_runtime_if_owned key transition_lock;
                `Settled (Error (Initial_persistence_failed { reason }))))
      with
      | Lane_admission_timeout lane ->
        (* Admission expired before the initial durable write started: the
           reservation was never persisted, so drop it exactly like the
           [Not_published] rollback path above. *)
        remove_runtime_if_owned key transition_lock;
        `Settled (Error (Submit_lane_unavailable { lane; wait_budget_sec }))
    in
    (match initial_persistence with
     | `Settled result -> result
     | `Persisted ->
       let acceptance_result =
         match on_accepted with
         | None -> Ok ()
         | Some callback ->
           Eio.Cancel.protect (fun () ->
             match callback request_id with
             | Ok () -> Ok ()
             | Error _ as error -> error
             | exception exn -> (* cancel-guard-ok: the body is Eio.Cancel.protect, so the ambient cancellation cannot fire inside it. *)
               Error (Printexc.to_string exn))
       in
       (match acceptance_result with
        | Error reason ->
          ignore
            (set_status_protected
               ~ops
               key
               (Persistence_failed
                  { attempted_status = Acceptance_callback; reason })
             : worker_settlement option);
          Error (Acceptance_persistence_failed { request_id; reason })
        | Ok () ->
          let notify_aborted reason =
            match on_worker_aborted with
            | None -> Ok ()
            | Some callback ->
              Eio.Cancel.protect (fun () ->
                match callback reason with
                | Ok () -> Ok ()
                | Error detail -> Error detail
                | exception exn -> (* cancel-guard-ok: the body is Eio.Cancel.protect, so the ambient cancellation cannot fire inside it. *)
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleCallbackFailures)
                    ~labels:[ "callback", "keeper_msg_async_on_worker_aborted" ]
                    ();
                  Log.Keeper.error
                    "keeper_msg_async: on_worker_aborted callback failed request_id=%s error=%s"
                    request_id
                    (Printexc.to_string exn);
                  Error (Printexc.to_string exn))
          in
          let notify_settled settlement =
            match on_worker_settled with
            | None -> ()
            | Some callback ->
              Eio.Cancel.protect (fun () ->
                try callback settlement with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleCallbackFailures)
                    ~labels:[ "callback", "keeper_msg_async_on_worker_settled" ]
                    ();
                  Log.Keeper.error
                    "keeper_msg_async: on_worker_settled callback failed request_id=%s status=%s error=%s"
                    request_id
                    (match settlement with
                     | Status_settlement { entry; _ } ->
                       status_to_string entry.status
                     | Settlement_projection_error _ -> "projection_error")
                    (Printexc.to_string exn))
          in
          let persist_abort_status ~attempted_status reason =
            match notify_aborted reason with
            | Ok () -> set_status_protected ~ops key attempted_status
            | Error callback_error ->
              set_status_protected
                ~ops
                key
                (Persistence_failed
                   { attempted_status = State_transition (status_to_string attempted_status)
                   ; reason = callback_error
                   })
          in
          let background_start_failed reason =
            let reason =
              Printf.sprintf
                "keeper_msg request was persisted but its background worker could not start: %s"
                reason
            in
            (* No worker scope was admitted, so [on_worker_aborted] does not
               own this path. The synchronous submit caller emits the single
               rejected transport terminal; invoking the callback here would
               publish a false cancellation first and duplicate transcript
               persistence. *)
            ignore
              (set_status_protected ~ops key (Lost { reason })
                : worker_settlement option);
            Error (Background_fork_failed { request_id; reason })
          in
          let worker_started = Atomic.make false in
          (match
          Eio.Fiber.fork_daemon ~sw:background_sw (fun () ->
    Atomic.set worker_started true;
    let running_settlement =
      set_status_protected ~ops ~preserve_terminal:true key Running
    in
    match running_settlement with
    | Some (Status_settlement { entry; _ } as settlement)
      when is_terminal_status entry.status ->
      (* A failed Running write can durably commit its Persistence_failed
         marker and remove the runtime row. Project that exact settlement
         before stopping: falling through to worker admission would
         misclassify it as runtime cancellation and lose the durable SSOT. *)
      notify_settled settlement;
      `Stop_daemon
    | Some (Settlement_projection_error _ as settlement) ->
      notify_settled settlement;
      `Stop_daemon
    | Some (Status_settlement _) | None ->
      (* [f] owns any terminal signal it emits on its own side channels while
         it runs (e.g. push_worker_event in server_routes_http_keeper_stream's
         process_single_turn). Every catch arm below fires exactly when [f] was
         cut off before reaching that code, so the caller's channel would
         otherwise see nothing — see masc#23924. Eio.Cancel.protect matches
         set_status_protected above: at these catch sites the ambient switch
         may still be tearing down, so an unprotected call could itself be
         cancelled before the callback runs. *)
      let result =
        try
          Eio.Switch.run (fun req_sw ->
          let admission =
            with_lock (fun () ->
              Request_table.replace active_switches key req_sw;
              match Request_table.find_opt pending key with
              | Some { status = Queued | Running; _ } -> `Run
              | Some { status = Cancelling _; _ } -> `Operator_cancelled
              | Some
                  ({ status =
                       (Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _)
                   ; _
                   } as entry) ->
                `Already_settled entry
              | None -> `Preempted "keeper_msg request disappeared before worker start")
          in
          (match admission with
           | `Run -> ()
           | `Operator_cancelled -> raise CancelledByOperator
           | `Already_settled entry -> raise (Worker_already_settled entry)
           | `Preempted reason -> raise (Worker_preempted reason));
          let outcome = f ~request_id req_sw in
          let result_data result =
            match Tool_result.data result with
            | `String _ -> None
            | data -> Some data
          in
          match outcome with
          | Worker_interrupted {reason} -> Lost {reason}
          | Worker_finished result ->
              Done {ok=tool_result_success result;body=tool_result_body result;data=result_data result}
          | Worker_waiting {dependencies;result} ->
              Waiting_for_dependencies {dependencies;body=tool_result_body result;data=result_data result})
      with
      | CancelledByOperator ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(operator_cancelled_status ())
              (Worker_cancelled
                 { cancelled_by = Operator_request
                 ; reason = operator_cancel_reason
                 })
            |> Option.iter notify_settled);
        operator_cancelled_status ()
      | Worker_preempted reason ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(runtime_cancelled_status ())
              (Worker_cancelled { cancelled_by = Runtime_cancellation; reason })
            |> Option.iter notify_settled);
        runtime_cancelled_status ()
      | Worker_already_settled entry ->
        clear_active_switch key;
        notify_settled
          (Status_settlement
             { entry
             ; durability = Volatile_persistence_failure
             ; origin = Transition_commit
             });
        entry.status
      | Eio.Cancel.Cancelled _ as e ->
        (* [notify_aborted] observes callback exceptions without letting one
           request fail the server root switch. The switch-table release must
           still be exception-safe because cancellation cleanup below can be
           interrupted by unrelated bookkeeping failures.
           [clear_active_switch] protects mutex acquisition as well as the
           table removal from ambient cancellation; it performs no storage I/O. *)
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(runtime_cancelled_status ())
              (Worker_cancelled
                 { cancelled_by = Runtime_cancellation
                 ; reason =
                     "keeper_msg worker was cancelled by runtime before terminal result"
                 })
            |> Option.iter notify_settled);
        raise e
      | exn ->
        Done
          { ok = false
          ; body = Printf.sprintf "keeper_msg failed: %s" (Printexc.to_string exn)
          ; data = None
          }
      in
      Fun.protect
        ~finally:(fun () -> clear_active_switch key)
        (fun () ->
          set_status_protected ~ops ~preserve_terminal:true key result
          |> Option.iter notify_settled);
      `Stop_daemon)
        with
        | () ->
          if Atomic.get worker_started
          then (
            durably_accepted := true;
            Ok { request_id; acceptance = Durably_accepted })
          else (
            match Eio.Switch.get_error background_sw with
            | None ->
              (* Eio accepted the daemon. A child can remain unscheduled here,
                 but Eio only drops it when the target switch is already
                 cancelling. *)
              durably_accepted := true;
              Ok { request_id; acceptance = Durably_accepted }
            | Some cause -> background_start_failed (Printexc.to_string cause))
        | exception exn ->
          (* The request is already persisted and no worker scope was
             admitted. Settle Lost or its exact pending cancellation before
             leaving; no worker remains to consume that intent. Write on the cancelled path too, before the
             exception leaves -- [set_status_protected] completes while
             unwinding. *)
          let backtrace = Printexc.get_raw_backtrace () in
          let outcome = background_start_failed (Printexc.to_string exn) in
          (match exn with
           | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace exn backtrace
           | _ -> outcome))))))
     with
     | Lane_admission_timeout lane ->
       (* Submission-lane admission expired before any reservation existed,
          so there is nothing to clean up here. *)
       Error (Submit_lane_unavailable { lane; wait_budget_sec })))
;;

let submit_worker_with_request_id = submit_worker_with_ops production_request_ops

let submit_with_ops ops ?request_context ?on_accepted ?on_worker_aborted
    ?on_worker_settled ~background_sw ~base_path ~caller ~f ~keeper_name () =
  submit_worker_with_ops ops ?request_context ?on_accepted ?on_worker_aborted
    ?on_worker_settled ~background_sw ~base_path ~caller
    ~f:(fun ~request_id request_sw -> worker_finished (f ~request_id request_sw))
    ~keeper_name ()
;;

let submit_with_request_id = submit_with_ops production_request_ops

let submit ?request_context ?on_accepted ?on_worker_aborted ?on_worker_settled
    ~background_sw ~base_path ~caller ~f ~keeper_name () =
  submit_with_request_id ?request_context ?on_accepted ?on_worker_aborted
    ?on_worker_settled ~background_sw ~base_path ~caller
    ~f:(fun ~request_id:_ request_sw -> f request_sw)
    ~keeper_name ()
;;

(** Exact owner check for both the process-global table and persisted rows. *)
let owner_rejection ~caller (entry : entry) =
  if not (String.equal entry.submitted_by caller)
  then Some Caller_mismatch
  else None
;;

(** Poll for the result of an async keeper_msg request. *)
let poll ~base_path ~caller request_id : load_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      match Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key) with
      | Some entry ->
        (match owner_rejection ~caller entry with
         | Some rejection -> Rejected rejection
         | None -> Found entry)
      | None ->
        (match load_record_canonical_located ~base_path ~request_id with
         | Located (entry, _) ->
           (match owner_rejection ~caller entry with
            | Some rejection -> Rejected rejection
            | None ->
              (match entry.status with
               | Queued | Running | Cancelling _ ->
                 (* A poller cannot prove that another process does not own
                    this worker. Only the exclusive startup recovery boundary
                    may convert disk-only non-terminal state to [Lost]. *)
                 Found entry
               | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ -> Found entry))
         | Located_absent -> Absent
         | Located_unreadable reason -> Unreadable reason
         | Located_rejected rejection -> Rejected rejection))
;;

let load_canonical_request ~base_path ~caller request_id =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id) then Rejected Invalid_request_id
    else with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
      match load_record_canonical_located ~base_path ~request_id with
      | Located_absent -> Absent
      | Located_unreadable reason -> Unreadable reason
      | Located_rejected rejection -> Rejected rejection
      | Located (entry, _) ->
        match owner_rejection ~caller entry with
        | Some rejection -> Rejected rejection
        | None -> Found entry)
;;

let with_canonical_durable_terminal ~base_path ~caller request_id ~f =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Error (Canonical_terminal_access_rejected rejection)
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Error (Canonical_terminal_access_rejected Invalid_request_id)
    else
      with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
        let key = request_key ~base_path ~submitted_by:caller ~request_id in
        match
          Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key)
        with
        | Some entry when is_terminal_status entry.status ->
          Error (Canonical_terminal_publication_ambiguous entry.status)
        | Some entry -> Error (Canonical_terminal_runtime_active entry.status)
        | None ->
          (match load_record_canonical_located ~base_path ~request_id with
           | Located_absent -> Error Canonical_terminal_absent
           | Located_unreadable reason ->
             Error (Canonical_terminal_unreadable reason)
           | Located_rejected rejection ->
             Error (Canonical_terminal_access_rejected rejection)
           | Located (entry, location) ->
             (match owner_rejection ~caller entry with
              | Some rejection ->
                Error (Canonical_terminal_access_rejected rejection)
              | None ->
                if not (is_terminal_status entry.status)
                then Error (Canonical_terminal_nonterminal entry.status)
                else
                  match location with
                  | Terminal_location -> Ok (f { terminal_entry = entry })
                  | Active_location ->
                    Error
                      (Canonical_terminal_noncanonical_location entry.status))))
;;

let load_canonical_durable_terminal ~base_path ~caller request_id =
  with_canonical_durable_terminal ~base_path ~caller request_id ~f:Fun.id
;;

let queued_proof_of_record ~caller ~location ~local (entry : entry) =
  match owner_rejection ~caller entry with
  | Some rejection -> Error (Canonical_queued_access_rejected rejection)
  | None ->
    match entry.status with
    | Running | Cancelling _ | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
      Error (Canonical_queued_not_queued entry.status)
    | Queued ->
      match location with
      | Terminal_location -> Error (Canonical_queued_noncanonical_location entry.status)
      | Active_location ->
        match local with
        | None -> Ok { queued_entry = entry }
        | Some local ->
          match local.status with
          | Running | Cancelling _ -> Error (Canonical_queued_runtime_nonqueued local.status)
          | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
            Error (Canonical_queued_publication_ambiguous local.status)
          | Queued ->
            if same_entry_record local entry then Ok { queued_entry = entry }
            else Error Canonical_queued_runtime_conflict
;;

let load_canonical_durable_queued ~base_path ~caller request_id =
  let* base_path, caller =
    resolve_access_identity ~base_path ~caller
    |> Result.map_error (fun rejection -> Canonical_queued_access_rejected rejection)
  in
  if not (is_safe_request_id request_id)
  then Error (Canonical_queued_access_rejected Invalid_request_id)
  else
    with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
      (* Canonical disk authority takes precedence over any cached reservation.
         The existing decoder also refuses unreadable/conflicting partitions. *)
      match load_record_canonical_located ~base_path ~request_id with
      | Located_absent -> Error Canonical_queued_absent
      | Located_unreadable reason -> Error (Canonical_queued_unreadable reason)
      | Located_rejected rejection -> Error (Canonical_queued_access_rejected rejection)
      | Located (entry, location) ->
        let key = request_key ~base_path ~submitted_by:caller ~request_id in
        let local = Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key) in
        queued_proof_of_record ~caller ~location ~local entry)
;;

(** List only this caller lane; cross-lane rows are intentionally omitted. *)
let list_for_keeper ~base_path ~caller ?keeper_name () :
    (entry list, access_rejection) result =
  let* base_path, caller = resolve_access_identity ~base_path ~caller in
  let entries =
    Eio.Mutex.use_ro mu (fun () ->
      Request_table.fold
        (fun _id entry acc ->
           if
             (not (String.equal entry.base_path base_path))
             || Option.is_some (owner_rejection ~caller entry)
           then acc
           else
             match entry.status, keeper_name with
             | (Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _), _ -> acc
             | (Queued | Running | Cancelling _), Some name
               when not (String.equal entry.keeper_name name) -> acc
             | (Queued | Running | Cancelling _), (Some _ | None) -> entry :: acc)
        pending
        [])
    |> List.sort (fun a b ->
         let cmp = Float.compare b.submitted_at a.submitted_at in
         if cmp <> 0 then cmp else String.compare a.request_id b.request_id)
  in
  Ok entries
;;

let entry_to_fields (e : entry) =
  let now =
    match e.completed_at with
    | Some completed_at -> completed_at
    | None -> Time_compat.now ()
  in
  Keeper_msg_async_record.entry_to_fields ~now e
;;

let entry_to_json (e : entry) = `Assoc (entry_to_fields e)
;;

let cancel_disk_record ~base_path ~caller ~request_id =
  match load_record_canonical_located ~base_path ~request_id with
  | Located_absent -> Cancel_not_found
  | Located_unreadable reason -> Cancel_unreadable reason
  | Located_rejected rejection -> Cancel_rejected rejection
  | Located (entry, _) ->
    (match owner_rejection ~caller entry with
     | Some rejection -> Cancel_rejected rejection
     | None when is_terminal_status entry.status ->
       Cancel_already_terminal entry.status
     | None ->
       (* Process-local absence is not proof of worker absence: stdio and
          HTTP runtimes can observe the same BasePath. Startup recovery runs
          only under the exclusive server ownership boundary; an arbitrary
          cancel caller must not steal another process's live request. *)
       Cancel_worker_ownership_unknown entry.status)
;;

let signal_operator_cancel ~ops request_sw =
  ops.signal_cancel request_sw CancelledByOperator
;;

let cancel_with_ops ops ~base_path ~caller request_id : cancel_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Cancel_rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Cancel_rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      match transition_lock_for_key key with
      | None -> cancel_disk_record ~base_path ~caller ~request_id
      | Some transition_lock ->
        let result =
          Eio.Mutex.use_rw ~protect:true transition_lock (fun () ->
            let current =
              with_lock (fun () ->
                match
                  Request_table.find_opt transition_locks key,
                  Request_table.find_opt pending key
                with
                | None, None -> `Load_disk
                | Some owned, Some entry when owned == transition_lock -> `Entry entry
                | Some _, Some _ ->
                  `Invariant
                    "request transition lock ownership changed during cancellation"
                | Some _, None ->
                  `Invariant
                    "request transition lock exists without an active request entry"
                | None, Some _ ->
                  `Invariant
                    "active request entry exists without its transition lock")
            in
            match current with
            | `Load_disk -> `Load_disk
            | `Invariant reason -> `Result (Cancel_state_invariant_failed { reason })
            | `Entry entry ->
              (match owner_rejection ~caller entry with
               | Some rejection -> `Result (Cancel_rejected rejection)
               | None ->
                 let commit_and_signal cancelling =
                    let persistence =
                      match
                        persist_entry ~ops cancelling
                        |> observe_persist_error ~operation:"operator_cancel" cancelling
                      with
                      | Ok () -> Ok `Durable
                      | Error (Write_failed (Published_uncertain error)) ->
                        Ok
                          (`Volatile
                              (Keeper_fs.durable_write_error_to_string error))
                      | Error ((Write_failed (Not_published _) | Integrity_failed _) as error) ->
                        Error
                          (Cancel_persistence_failed
                             { reason = persist_error_to_string error })
                    in
                    (match persistence with
                     | Error result -> `Result result
                     | Ok durability ->
                       let publication =
                         with_lock (fun () ->
                           match
                             Request_table.find_opt transition_locks key,
                             Request_table.find_opt pending key
                           with
                           | Some owned, Some _ when owned == transition_lock ->
                             Request_table.replace pending key cancelling;
                             `Published (Request_table.find_opt active_switches key)
                           | _ ->
                             `Invariant
                               "request runtime state disappeared after cancellation was published")
                       in
                       let accepted_result =
                         match durability with
                         | `Durable -> Cancellation_requested Durably_committed
                         | `Volatile reason ->
                           Cancellation_requested
                             (Published_unconfirmed { reason })
                       in
                       (match publication with
                        | `Invariant reason ->
                          `Result (Cancel_state_invariant_failed { reason })
                        | `Published None -> `Result accepted_result
                        | `Published (Some request_sw) ->
                          (try
                             signal_operator_cancel ~ops request_sw;
                             `Result accepted_result
                           with
                           | Eio.Cancel.Cancelled _ as e -> raise e
                           | exn ->
                             `Result
                               (Cancel_worker_signal_failed
                                  { durability =
                                      (match durability with
                                       | `Durable -> Durably_committed
                                       | `Volatile reason ->
                                         Published_unconfirmed { reason })
                                  ; reason = Printexc.to_string exn
                                  }))))
                 in
                 (match entry.status with
                  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
                    `Result (Cancel_already_terminal entry.status)
                  | Cancelling _ ->
                    (* The operator's next explicit cancel call is the retry
                       boundary. Re-persist the same intent to recover an exact
                       durability result, then signal the currently owned
                       request switch again. No timer or retry count guesses
                       whether the worker is still live. *)
                    commit_and_signal entry
                  | Queued | Running ->
                    commit_and_signal
                      { entry with
                        status = operator_cancelling_status ()
                      ; completed_at = None
                      }))
              )
        in
        (match result with
         | `Load_disk -> cancel_disk_record ~base_path ~caller ~request_id
         | `Result result -> result))
;;

let cancel = cancel_with_ops production_request_ops

module For_testing = struct
  type nonrec request_ops = request_ops

  let persist_terminal_record (entry : entry) =
    if is_terminal_status entry.status
    then persist_entry ~ops:production_request_ops entry
         |> Result.map_error persist_error_to_string
    else Error "offline request fixture must have a terminal status"
  ;;

  let make_request_ops ?before_durable_write ?before_durable_remove
      ?(generate_request_id = production_request_ops.generate_request_id)
      ?(before_integrity_projection =
        production_request_ops.before_integrity_projection)
      ?(signal_cancel = production_request_ops.signal_cancel) () =
    let save_json_durable =
      match before_durable_write with
      | None -> production_request_ops.save_json_durable
      | Some before_stage ->
        (fun ~ownership_root ~temp_dir path json ->
           Keeper_fs.For_testing.save_json_durable_atomic
             ~before_stage
             ~ownership_root
             ~temp_dir
             path
             json)
    in
    let remove_file_durable =
      match before_durable_remove with
      | None -> production_request_ops.remove_file_durable
      | Some before_stage ->
        (fun ~ownership_root path ->
           Keeper_fs.For_testing.remove_file_durable
             ~before_stage
             ~ownership_root
             path)
    in
    { save_json_durable
    ; remove_file_durable
    ; generate_request_id
    ; before_integrity_projection
    ; signal_cancel
    }
  ;;

  let record_schema_version = record_schema_version
  let is_safe_request_id = is_safe_request_id
  let forget ~base_path ~caller ~request_id =
    match resolve_access_identity ~base_path ~caller with
    | Error rejection ->
      Log.Keeper.warn
        "keeper_msg_async: For_testing.forget rejected request_id=%s error=%s"
        request_id
        (Yojson.Safe.to_string (access_rejection_to_json rejection))
    | Ok (base_path, submitted_by) ->
      let key = request_key ~base_path ~submitted_by ~request_id in
      with_lock (fun () ->
        match Request_table.find_opt transition_locks key with
        | None -> ()
        | Some _ ->
          Store_transition_table.remove
            reserved_request_ids
            ({ base_path; request_id } : Store_transition_key.t);
          Request_table.remove pending key;
          Request_table.remove transition_locks key)
  ;;

  let clear () =
    with_lock (fun () ->
      Request_table.clear pending;
      Request_table.clear transition_locks;
      Request_table.clear active_switches;
      Store_transition_table.clear store_transition_locks;
      Store_transition_table.clear reserved_request_ids;
      Keeper_lane_table.clear keeper_submission_locks;
      Keeper_lane_table.clear keeper_persistence_locks)
  ;;
  let active_record_path = active_record_path
  let terminal_record_path = terminal_record_path
  let atomic_staging_dir = atomic_staging_dir
  let load_record = load_record
  let recover_lost_disk_records = recover_lost_disk_records
  let submit ops ?request_context ?on_accepted ?on_worker_aborted ?on_worker_settled
      ~background_sw ~base_path ~caller ~f ~keeper_name () =
    submit_with_ops ops ?request_context ?on_accepted ?on_worker_aborted
      ?on_worker_settled ~background_sw ~base_path ~caller
      ~f:(fun ~request_id:_ request_sw -> f request_sw)
      ~keeper_name ()
  ;;
  let cancel = cancel_with_ops
  let reserved_request_id_count () =
    Eio.Mutex.use_ro mu (fun () -> Store_transition_table.length reserved_request_ids)
  ;;
  let active_switch_count () =
    Eio.Mutex.use_ro mu (fun () -> Request_table.length active_switches)
  ;;

  let persistence_lane_samples = persistence_lane_samples

end
