open Keeper_msg_async_types
open Keeper_msg_async_record
open Keeper_msg_async_state
open Keeper_msg_async_locks
open Keeper_msg_async_store
open Keeper_msg_async_recovery

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
