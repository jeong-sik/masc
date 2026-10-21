(* The result is committed before it is announced. The one-shot queue writer
   confirms strict snapshot durability before updating the live queue, so
   an [Error] here means the submitter has not been told and the caller can
   report the delivery as failed instead of acknowledging one that never
   landed.

   The wake that follows is a hint, not the delivery: it reaches only a
   [Running] Keeper, and a paused or unregistered one is left alone, exactly
   as the Board, Fusion and delegation wakes do. Its failure is logged rather
   than raised because the stimulus is already committed and the Keeper reads
   it on its next admitted turn. Eio structural cancellation is re-raised. *)
let outcome_label : Keeper_event_queue.composition_terminal -> string = function
  | Keeper_event_queue.Composition_succeeded -> "succeeded"
  | Keeper_event_queue.Composition_failed _ -> "failed"
  | Keeper_event_queue.Composition_cancelled _ -> "cancelled"
;;

let deliver ~not_before ~base_path ~keeper_name ~request_id ~composition_tool ~terminal =
  let completion =
    { Keeper_event_queue.cc_request_id = request_id
    ; cc_tool = composition_tool
    ; cc_terminal = terminal
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { Keeper_event_queue.post_id =
        Keeper_event_queue.composition_completion_post_id completion
      (* [pending_entries] is urgency-sorted and stable, so [Normal] would put
         this behind every Board stimulus already queued. Measured on the live
         fleet: a Keeper with 151 pending would read its own result 151 turns
         after it landed, which is worse than the polling this replaces.

         [Immediate] is what [Hitl_resolved] uses, and for the same reason: an
         answer to something this Keeper asked for is not the same kind of
         event as somebody else posting to the Board. A Board post can be read
         later; work the Keeper started and is counting on cannot.

         [Fusion_completed] and [Delegate_completed] are still [Normal] and
         have the same argument for moving. Not changed here — each is its own
         call, and one of them wakes a different Keeper than the one that
         asked. *)
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Composition_completed completion
    }
  in
  match
    try
      match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result ~not_before ~base_path keeper_name stimulus with
      | Keeper_registry_event_queue.Stimulus_enqueued
      | Keeper_registry_event_queue.Stimulus_already_present -> Ok ()
      | Keeper_registry_event_queue.Stimulus_storage_error detail -> Error detail
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error reason ->
    Log.Keeper.error
      ~keeper_name
      "composition result commit failed request_id=%s tool=%s: %s"
      request_id
      composition_tool
      reason;
    Error reason
  | Ok () ->
    (* The level comes from the outcome: the commit succeeded either way, but
       a composition that could not finish is not routine for the Keeper that
       is still counting on it. *)
    (match terminal with
     | Keeper_event_queue.Composition_failed _
     | Keeper_event_queue.Composition_cancelled _ -> Log.Keeper.warn
     | Keeper_event_queue.Composition_succeeded -> Log.Keeper.info)
      ~keeper_name
      "composition result committed request_id=%s tool=%s outcome=%s"
      request_id
      composition_tool
      (outcome_label terminal);
    (try
       match
         Keeper_registry.wakeup_running
           ~intent:Keeper_registry.Reactive_signal
           ~base_path
           keeper_name
       with
       | Keeper_registry.Signaled -> ()
       | Keeper_registry.Deferred_unregistered ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred: submitter is no longer registered \
            request_id=%s"
           request_id
       | Keeper_registry.Deferred_not_running phase ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred: phase=%s request_id=%s"
           (Keeper_state_machine.phase_to_string phase)
           request_id
       | Keeper_registry.Deferred_lifecycle denial ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred by lifecycle: reason=%s request_id=%s"
           (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
           request_id
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         ~keeper_name
         "composition result wake hint failed after commit request_id=%s: %s"
         request_id
         (Printexc.to_string exn));
    Ok ()
;;

(* Which settled statuses are worth waking a Keeper for.

   Spelled out per status rather than defaulted: a status added to
   [Keeper_msg_async] must decide here whether the submitter hears about it,
   instead of inheriting silence — which is the failure this whole module
   exists to end. *)
let terminal_of_status : Keeper_msg_async.request_status -> Keeper_event_queue.composition_terminal option
  = function
  | Keeper_msg_async.Done { ok = true; _ } ->
    Some Keeper_event_queue.Composition_succeeded
  | Keeper_msg_async.Done { ok = false; body; _ } ->
    Some (Keeper_event_queue.Composition_failed body)
  | Keeper_msg_async.Lost { reason } ->
    Some (Keeper_event_queue.Composition_failed reason)
  | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
    Some
      (Keeper_event_queue.Composition_failed
         (Printf.sprintf "persisting %s failed: %s" (Keeper_msg_async.persistence_target_to_string attempted_status) reason))
  | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
    Some
      (Keeper_event_queue.Composition_cancelled
         (Printf.sprintf "%s: %s" cancelled_by reason))
  (* Not settled. Nothing to announce. *)
  | Keeper_msg_async.Queued
  | Keeper_msg_async.Running
  | Keeper_msg_async.Cancelling _ -> None
  | Keeper_msg_async.Waiting_for_dependencies _ -> None
;;

let on_worker_settled ~base_path ~composition_tool settlement =
  match settlement with
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Durable; origin = _ } ->
    (match Keeper_tool_execution_journal.completion_pending ~base_path entry with
     | Error error -> Log.Keeper.error ~keeper_name:entry.submitted_by
         "composition completion awaits original recovery authority request_id=%s: %s"
         entry.request_id (Keeper_tool_execution_journal.error_to_string error)
     | Ok true ->
       (match Keeper_composition_completion_outbox.acknowledge ~base_path
           ~keeper_name:entry.submitted_by ~request_id:entry.request_id with
        | Ok () -> ()
        | Error error -> Log.Keeper.error ~keeper_name:entry.submitted_by
            "recoverable physical attempt completion retirement failed request_id=%s: %s"
            entry.request_id (Keeper_composition_completion_outbox.error_to_string error))
     | Ok false ->
    (match terminal_of_status entry.Keeper_msg_async.status with
     | None ->
       (match entry.status with
        | Keeper_msg_async.Waiting_for_dependencies _ ->
          (* The released attempt has no composition terminal to announce.
             Its job wait and original occurrence remain in the run journal. *)
          (match Keeper_composition_completion_outbox.acknowledge_waiting
              ~base_path ~keeper_name:entry.submitted_by ~request_id:entry.request_id
              ~composition_tool with
           | Ok () -> ()
           | Error error -> Log.Keeper.error ~keeper_name:entry.submitted_by
               "composition waiting attempt delivery retirement failed request_id=%s: %s"
               entry.request_id (Keeper_composition_completion_outbox.error_to_string error))
        | Queued | Running | Cancelling _ | Lost _ | Cancelled _
        | Persistence_failed _ | Done _ -> ())
     | Some terminal ->
       (match
          deliver
            ~base_path
            ~not_before:entry.Keeper_msg_async.submitted_at
            ~keeper_name:entry.Keeper_msg_async.submitted_by
            ~request_id:entry.Keeper_msg_async.request_id
            ~composition_tool
            ~terminal
        with
        | Ok () ->
          (match Keeper_composition_completion_outbox.acknowledge
                   ~base_path ~keeper_name:entry.submitted_by ~request_id:entry.Keeper_msg_async.request_id with
           | Ok () -> ()
           | Error error -> Log.Keeper.error ~keeper_name:entry.submitted_by
               "composition delivery acknowledged by queue but outbox retirement failed request_id=%s: %s"
               entry.request_id (Keeper_composition_completion_outbox.error_to_string error))
        (* [deliver] already logged the reason. The pre-dispatch obligation
           remains for canonical-result reconciliation; only delivery is
           retried, while the result remains in the original request record. *)
        | Error _ -> ())))
  (* The store does not hold this settlement as canonical truth. Telling the
     Keeper its work succeeded on evidence that may not survive would be worse
     than leaving it to read the record. *)
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Volatile_persistence_failure; origin = _ } ->
    Log.Keeper.error
      ~keeper_name:entry.Keeper_msg_async.submitted_by
      "composition result not announced: settlement is visible but not durably \
       canonical request_id=%s tool=%s"
      entry.Keeper_msg_async.request_id
      composition_tool
  | Keeper_msg_async.Settlement_projection_error { attempted_entry; poll_result = _ } ->
    Log.Keeper.error
      ~keeper_name:attempted_entry.Keeper_msg_async.submitted_by
      "composition result not announced: settlement disagrees with canonical \
       request truth request_id=%s tool=%s"
      attempted_entry.Keeper_msg_async.request_id
      composition_tool
;;

let deliver_entry ~base_path ~composition_tool (entry : Keeper_msg_async.entry) =
  match terminal_of_status entry.status with
  | None -> Error "canonical composition completion has a nonterminal status"
  | Some terminal -> deliver ~base_path ~not_before:entry.submitted_at
      ~keeper_name:entry.submitted_by
      ~request_id:entry.request_id ~composition_tool ~terminal

let reconcile ~base_path =
  Keeper_composition_completion_outbox.flush ~base_path ~deliver:(deliver_entry ~base_path)
;;

module Outbox = Keeper_composition_completion_outbox
module Completion_owners = Map.Make (String)

type recovery_phase = Reserved | Started | Settled of Outbox.report | Interrupted | Raised

let observe_recovery ~keeper_name ~started_ns phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase, detail = match phase with
        | Reserved -> "reserved", ""
        | Started -> "started", ""
        | Interrupted -> "interrupted", ""
        | Raised -> "raised", ""
        | Settled report -> "settled", Printf.sprintf
            " inspected=%d delivered=%d waiting=%d failures=%d"
            report.inspected report.delivered report.waiting (List.length report.failures) in
      Printf.sprintf "composition_completion_recovery keeper=%s started_ns=%Ld phase=%s at_ns=%Ld%s"
        keeper_name started_ns phase (Mtime_clock.elapsed_ns ()) detail)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let log_report ~keeper_name (report : Outbox.report) =
  List.iter (fun (request_id,error) ->
    Log.Server.warn "composition completion delivery retained keeper=%s request=%s error=%s"
      keeper_name request_id (Outbox.error_to_string error)) report.failures;
  if report.delivered > 0 then Log.Server.info
    "composition completion recovery keeper=%s inspected=%d delivered=%d waiting=%d failures=%d"
    keeper_name report.inspected report.delivered report.waiting (List.length report.failures)

let log_discovery ~base_path:_ = function
  | Ok () -> ()
  | Error error -> Log.Server.warn "composition completion outbox unavailable: %s"
      (Outbox.error_to_string error)

type t =
  { base_path : string
  ; on_report : keeper_name:string -> Outbox.report -> unit
  ; on_discovery : base_path:string -> (unit, Outbox.error) result -> unit
  ; mutable active : Set_util.StringSet.t
  ; mutable discovery_active : bool }

let create ~base_path ?(on_report=log_report) ?(on_discovery=log_discovery) () =
  {base_path;on_report;on_discovery;active=Set_util.StringSet.empty;discovery_active=false}

let recover_owner pending =
  let empty : Outbox.report = {inspected=0;waiting=0;delivered=0;failures=[]} in
  let report = List.fold_left (fun (report : Outbox.report) (pending : Outbox.pending) ->
    let report = {report with inspected=report.inspected+1} in
    match Outbox.recover pending ~deliver:(deliver_entry ~base_path:pending.base_path) with
    | Ok Outbox.Retired -> report
    | Ok Outbox.Waiting -> {report with waiting=report.waiting+1}
    | Ok Outbox.Delivered -> {report with delivered=report.delivered+1}
    | Error error -> {report with failures=(pending.request_id,error)::report.failures}) empty pending in
  {report with failures=List.rev report.failures}

let discover_and_schedule ~sw supervisor =
  Eio.Switch.check sw;
  let ( let* ) = Result.bind in
  let* discovery = Outbox.discover ~base_path:supervisor.base_path in
  List.iter (fun (identity,error) ->
    Log.Server.warn "composition completion discovery retained pending_record=%s error=%s"
      identity (Outbox.error_to_string error)) discovery.failures;
  let owners = List.fold_left (fun owners (pending : Outbox.pending) ->
    if Set_util.StringSet.mem pending.keeper_name supervisor.active then owners
    else
      let previous = match Completion_owners.find_opt pending.keeper_name owners with
        | None -> [] | Some previous -> previous in
      Completion_owners.add pending.keeper_name (pending::previous) owners)
    Completion_owners.empty discovery.entries in
  Completion_owners.iter (fun keeper_name reversed ->
    if not (Set_util.StringSet.mem keeper_name supervisor.active) then (
      Eio.Switch.check sw;
      let pending = List.rev reversed in
      let started_ns = Mtime_clock.elapsed_ns () in
      supervisor.active <- Set_util.StringSet.add keeper_name supervisor.active;
      let release () = supervisor.active <- Set_util.StringSet.remove keeper_name supervisor.active in
      try
        observe_recovery ~keeper_name ~started_ns Reserved;
        Eio.Switch.check sw;
        Eio.Fiber.fork ~sw (fun () ->
          Fun.protect ~finally:release (fun () ->
            try
              Eio.Fiber.yield ();
              observe_recovery ~keeper_name ~started_ns Started;
              let report = recover_owner pending in
              observe_recovery ~keeper_name ~started_ns (Settled report);
              (try supervisor.on_report ~keeper_name report with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn -> Log.Server.warn "composition completion observer failed keeper=%s: %s"
                   keeper_name (Printexc.to_string exn))
            with
            | Eio.Cancel.Cancelled _ as exn ->
                observe_recovery ~keeper_name ~started_ns Interrupted;
                raise exn
            | exn ->
                observe_recovery ~keeper_name ~started_ns Raised;
                Log.Server.warn "composition completion worker retained keeper=%s: %s"
                  keeper_name (Printexc.to_string exn)))
      with exn ->
        let bt = Printexc.get_raw_backtrace () in
        release ();
        Printexc.raise_with_backtrace exn bt)) owners;
  Ok ()

type discovery_phase =
  | Discovery_reserved | Discovery_started
  | Discovery_settled of (unit, Outbox.error) result
  | Discovery_interrupted | Discovery_raised

let observe_discovery ~base_path ~reserved_ns phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase, detail = match phase with
        | Discovery_reserved -> "reserved", Printf.sprintf " base_path=%S" base_path
        | Discovery_started -> "started", ""
        | Discovery_settled result -> "settled",
            (match result with Ok () -> " outcome=returned" | Error _ -> " outcome=failed")
        | Discovery_interrupted -> "interrupted", ""
        | Discovery_raised -> "raised", "" in
      Printf.sprintf "composition_completion_discovery reserved_ns=%Ld phase=%s at_ns=%Ld%s"
        reserved_ns phase (Mtime_clock.elapsed_ns ()) detail)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let pulse ~sw supervisor =
  Eio.Switch.check sw;
  if not supervisor.discovery_active then (
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe_discovery ~base_path:supervisor.base_path ~reserved_ns in
    supervisor.discovery_active <- true;
    let release () = supervisor.discovery_active <- false in
    try
      observe Discovery_reserved;
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          try
            Eio.Fiber.yield ();
            observe Discovery_started;
            let result = discover_and_schedule ~sw supervisor in
            observe (Discovery_settled result);
            (try supervisor.on_discovery ~base_path:supervisor.base_path result with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Log.Server.warn "composition completion discovery observer failed: %s"
                 (Printexc.to_string exn))
          with
          | Eio.Cancel.Cancelled _ as exn -> observe Discovery_interrupted; raise exn
          | exn ->
              observe Discovery_raised;
              Log.Server.warn "composition completion discovery worker retained: %s"
                (Printexc.to_string exn)))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
