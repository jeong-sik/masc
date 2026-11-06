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
include Keeper_msg_async_recovery
include Keeper_msg_async_lifecycle

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
