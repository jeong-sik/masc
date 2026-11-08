open Keeper_types_profile
open Result.Syntax
open Keeper_msg_async_types
open Keeper_msg_async_record
open Keeper_msg_async_state
open Keeper_msg_async_locks
open Keeper_msg_async_store
open Keeper_msg_async_lifecycle

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
         it runs (e.g. publish_completion in server_routes_http_keeper_stream's
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
