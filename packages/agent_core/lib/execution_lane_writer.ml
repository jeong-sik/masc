module Event = Execution_event
module Journal = Execution_journal

let _log = Log.create ~module_name:"execution_lane_writer" ()

type reconciliation_evidence =
  { first_outcome_unknown : Journal.error
  ; latest_outcome_unknown : Journal.error
  ; outcome_count : int
  }

type reconciliation_wake_source =
  | Durability_health_changed
  | Operator_requested

type reconciliation_wake_event =
  | External_wake of reconciliation_wake_source
  | Close_requested

type scope_failure =
  | Initialization_failed of Journal.error
  | Initialization_reconciliation_failed of
      { evidence : reconciliation_evidence
      ; reconciliation_error : Journal.error
      }
  | Mutation_writer_failed of Journal.error
  | Reconciliation_failed of
      { evidence : reconciliation_evidence
      ; reconciliation_error : Journal.error
      }
  | Reconciliation_interrupted of
      { evidence : reconciliation_evidence
      ; interruption : exn
      }
  | Reconciliation_unresolved_on_close of { evidence : reconciliation_evidence }
  | Supervisor_cancelled of exn
  | Unexpected_exception of exn

exception Callback_failed_after_scope_failure of exn * scope_failure

type submit_error =
  | Admission_closed
  | Admission_failed of scope_failure

type ticket_error =
  | Transaction_rejected of Journal.error
  | Scope_failed of scope_failure

type ticket_phase =
  | Queued
  | Committing
  | Reconciling
  | Settled

type admission =
  | Accepting
  | Draining
  | Failed of scope_failure
  | Closed

type worker_phase =
  | Starting
  | Idle
  | Committing_group
  | Reconciling_group
  | Awaiting_reconciliation_wake

type 'a receipt =
  { value : 'a
  ; through : Journal.cursor
  ; group_event_count : int
  }

type stats =
  { admission : admission
  ; worker_phase : worker_phase
  ; queue_depth : int
  ; in_flight_commands : int
  ; accepted : int
  ; settled : int
  ; committed_groups : int
  ; committed_commands : int
  ; committed_events : int
  ; reconciliation_unknowns : int
  ; reconciliation_wakes : int
  ; current_reconciliation : reconciliation_evidence option
  ; last_reconciliation_wake : reconciliation_wake_event option
  }

type read_error =
  | Journal_not_ready
  | Journal_reconciling
  | Journal_unavailable of scope_failure
  | Journal_read_failed of Journal.error

type page =
  { events : Event.t list
  ; next_cursor : Journal.cursor
  ; high_watermark : Journal.cursor
  ; has_more : bool
  }

type 'a ticket =
  { mu : Eio.Mutex.t
  ; mutable phase : ticket_phase
  ; settled : ('a receipt, ticket_error) result Eio.Promise.t
  ; settle : ('a receipt, ticket_error) result Eio.Promise.u
  }

type packed_command =
  | Command :
      { transaction : 'a Journal.Transaction.t
      ; ticket : 'a ticket
      }
      -> packed_command

type staged_command =
  | Staged :
      { ticket : 'a ticket
      ; value : 'a
      }
      -> staged_command

type journal_view =
  | No_journal
  | Available of Journal.t
  | Reconciliation_in_progress
  | Unavailable of scope_failure

type open_mode =
  | Create of Event.Correlation_id.t option
  | Open_existing

type t =
  { dir : Eio.Fs.dir_ty Eio.Path.t
  ; codec : Execution_codec_executor.t
  ; initial_mode : open_mode
  ; mu : Eio.Mutex.t
  ; changed : Eio.Condition.t
  ; mutable newest_first : packed_command list
  ; mutable queue_depth : int
  ; mutable in_flight : packed_command list
  ; mutable in_flight_commands : int
  ; mutable admission : admission
  ; mutable worker_phase : worker_phase
  ; mutable journal_view : journal_view
  ; mutable pending_outcome : reconciliation_evidence option
  ; mutable reconciliation_wake_token : unit ref
  ; mutable last_reconciliation_wake : reconciliation_wake_event option
  ; mutable accepted : int
  ; mutable settled : int
  ; mutable committed_groups : int
  ; mutable committed_commands : int
  ; mutable committed_events : int
  ; mutable reconciliation_unknowns : int
  ; mutable reconciliation_wakes : int
  ; ready : (unit, scope_failure) result Eio.Promise.t
  ; resolve_ready : (unit, scope_failure) result Eio.Promise.u
  ; closed : (unit, scope_failure) result Eio.Promise.t
  ; resolve_closed : (unit, scope_failure) result Eio.Promise.u
  }

type pending_group =
  { batch : Journal.batch
  ; staged : staged_command list
  ; command_count : int
  ; event_count : int
  ; evidence : reconciliation_evidence
  }

type pending_reconciliation =
  | Initialization_outcome_unknown of reconciliation_evidence
  | Group_outcome_unknown of pending_group

type epoch_result =
  | Epoch_closed
  | Epoch_reconcile of pending_reconciliation
  | Epoch_await_reconciliation_wake of
      { pending : pending_reconciliation
      ; observed_wake : unit ref
      }
  | Epoch_failed of scope_failure

type group_result =
  | Continue
  | Reconcile of pending_group
  | Await_reconciliation_wake of pending_group
  | Group_failed of scope_failure

let reconciliation_evidence_to_string evidence =
  Printf.sprintf
    "%d unknown outcome(s); first=%s; latest=%s"
    evidence.outcome_count
    (Journal.error_to_string evidence.first_outcome_unknown)
    (Journal.error_to_string evidence.latest_outcome_unknown)
;;

let scope_failure_to_string = function
  | Initialization_failed error ->
    "execution lane writer initialization failed: " ^ Journal.error_to_string error
  | Initialization_reconciliation_failed { evidence; reconciliation_error } ->
    "execution lane writer initialization reconciliation failed after "
    ^ reconciliation_evidence_to_string evidence
    ^ ": "
    ^ Journal.error_to_string reconciliation_error
  | Mutation_writer_failed error ->
    "execution lane writer mutation failed: " ^ Journal.error_to_string error
  | Reconciliation_failed { evidence; reconciliation_error } ->
    "execution lane writer reconciliation failed after "
    ^ reconciliation_evidence_to_string evidence
    ^ ": "
    ^ Journal.error_to_string reconciliation_error
  | Reconciliation_interrupted { evidence; interruption } ->
    "execution lane writer reconciliation interrupted after "
    ^ reconciliation_evidence_to_string evidence
    ^ ": "
    ^ Printexc.to_string interruption
  | Reconciliation_unresolved_on_close { evidence } ->
    "execution lane writer closed with an unresolved commit outcome after "
    ^ reconciliation_evidence_to_string evidence
  | Supervisor_cancelled reason ->
    "execution lane writer supervisor cancelled: " ^ Printexc.to_string reason
  | Unexpected_exception exn ->
    "execution lane writer raised unexpectedly: " ^ Printexc.to_string exn
;;

let submit_error_to_string = function
  | Admission_closed -> "execution lane writer admission is closed"
  | Admission_failed failure -> scope_failure_to_string failure
;;

let ticket_error_to_string = function
  | Transaction_rejected error ->
    "execution transaction rejected: " ^ Journal.error_to_string error
  | Scope_failed failure -> scope_failure_to_string failure
;;

let read_error_to_string = function
  | Journal_not_ready -> "execution journal is not ready"
  | Journal_reconciling -> "execution journal is reconciling a commit outcome"
  | Journal_unavailable failure -> scope_failure_to_string failure
  | Journal_read_failed error -> Journal.error_to_string error
;;

let with_lock mu f = Eio.Mutex.use_rw ~protect:true mu f

let make_ticket () : _ ticket =
  let settled, settle = Eio.Promise.create () in
  { mu = Eio.Mutex.create (); phase = Queued; settled; settle }
;;

let ticket_phase (ticket : _ ticket) = with_lock ticket.mu (fun () -> ticket.phase)

let set_ticket_phase (ticket : _ ticket) (phase : ticket_phase) =
  with_lock ticket.mu (fun () ->
    match ticket.phase with
    | Settled -> ()
    | Queued | Committing | Reconciling -> ticket.phase <- phase)
;;

let settle_ticket (ticket : _ ticket) result =
  let should_resolve =
    with_lock ticket.mu (fun () ->
      match ticket.phase with
      | Settled -> false
      | Queued | Committing | Reconciling ->
        ticket.phase <- Settled;
        true)
  in
  should_resolve && Eio.Promise.try_resolve ticket.settle result
;;

let await (ticket : _ ticket) = Eio.Promise.await ticket.settled

let settle_command failure (Command { ticket; _ }) =
  settle_ticket ticket (Error (Scope_failed failure))
;;

let record_settled writer count =
  if count > 0
  then with_lock writer.mu (fun () -> writer.settled <- writer.settled + count)
;;

let finish_empty_group writer =
  Eio.Cancel.protect (fun () ->
    with_lock writer.mu (fun () ->
      writer.in_flight <- [];
      writer.in_flight_commands <- 0;
      writer.worker_phase <- Idle))
;;

let finish_durable_group writer journal staged command_count event_count =
  Eio.Cancel.protect (fun () ->
    let through = Journal.current_cursor journal in
    let rec settle settled = function
      | [] -> settled
      | Staged { ticket; value } :: rest ->
        let settled =
          if settle_ticket ticket (Ok { value; through; group_event_count = event_count })
          then settled + 1
          else settled
        in
        Eio.Fiber.yield ();
        settle settled rest
    in
    let newly_settled = settle 0 staged in
    with_lock writer.mu (fun () ->
      writer.journal_view <- Available journal;
      writer.pending_outcome <- None;
      writer.in_flight <- [];
      writer.in_flight_commands <- 0;
      writer.worker_phase <- Idle;
      writer.committed_groups <- writer.committed_groups + 1;
      writer.committed_commands <- writer.committed_commands + command_count;
      writer.committed_events <- writer.committed_events + event_count;
      writer.settled <- writer.settled + newly_settled))
;;

let reject_transaction writer ticket error =
  Eio.Cancel.protect (fun () ->
    if settle_ticket ticket (Error (Transaction_rejected error))
    then record_settled writer 1)
;;

let rec reverse_staged chronological = function
  | [] -> chronological
  | staged :: rest ->
    Eio.Fiber.yield ();
    reverse_staged (staged :: chronological) rest
;;

let rec stage_ready writer batch staged_rev staged_count = function
  | [] -> batch, reverse_staged [] staged_rev, staged_count
  | Command { transaction; ticket } :: rest ->
    let continue batch staged_rev staged_count =
      Eio.Fiber.yield ();
      stage_ready writer batch staged_rev staged_count rest
    in
    set_ticket_phase ticket Committing;
    let before = Journal.batch_length batch in
    (match Journal.stage batch transaction with
     | Error error ->
       reject_transaction writer ticket error;
       continue batch staged_rev staged_count
     | Ok (next_batch, value) ->
       if Journal.batch_length next_batch = before
       then (
         reject_transaction writer ticket Journal.Empty_batch;
         continue batch staged_rev staged_count)
       else continue next_batch (Staged { ticket; value } :: staged_rev) (staged_count + 1))
;;

let reverse_ready newest_first =
  let rec loop chronological = function
    | [] -> chronological
    | command :: rest ->
      Eio.Fiber.yield ();
      loop (command :: chronological) rest
  in
  loop [] newest_first
;;

let initial_reconciliation_evidence error =
  { first_outcome_unknown = error; latest_outcome_unknown = error; outcome_count = 1 }
;;

let observe_reconciliation_unknown evidence error =
  { evidence with
    latest_outcome_unknown = error
  ; outcome_count = evidence.outcome_count + 1
  }
;;

let unresolved_on_close writer evidence =
  with_lock writer.mu (fun () ->
    match writer.admission with
    | Draining -> Some (Reconciliation_unresolved_on_close { evidence })
    | Accepting | Failed _ | Closed -> None)
;;

let mark_reconciling writer staged evidence =
  Eio.Cancel.protect (fun () ->
    with_lock writer.mu (fun () ->
      writer.worker_phase <- Reconciling_group;
      writer.journal_view <- Reconciliation_in_progress;
      if Option.is_none writer.pending_outcome
      then writer.last_reconciliation_wake <- None;
      writer.pending_outcome <- Some evidence;
      writer.reconciliation_unknowns <- writer.reconciliation_unknowns + 1);
    let rec mark = function
      | [] -> ()
      | Staged { ticket; _ } :: rest ->
        set_ticket_phase ticket Reconciling;
        Eio.Fiber.yield ();
        mark rest
    in
    mark staged)
;;

let mark_initialization_reconciling writer evidence =
  Eio.Cancel.protect (fun () ->
    with_lock writer.mu (fun () ->
      writer.worker_phase <- Reconciling_group;
      writer.journal_view <- Reconciliation_in_progress;
      if Option.is_none writer.pending_outcome
      then writer.last_reconciliation_wake <- None;
      writer.pending_outcome <- Some evidence;
      writer.reconciliation_unknowns <- writer.reconciliation_unknowns + 1))
;;

let process_ready writer durable_writer journal commands =
  let batch = Journal.begin_durable_batch durable_writer in
  let batch, staged, command_count = stage_ready writer batch [] 0 commands in
  match staged with
  | [] ->
    finish_empty_group writer;
    Continue
  | _ ->
    let event_count = Journal.batch_length batch in
    (match Journal.commit_durable_batch durable_writer batch with
     | Ok _events ->
       finish_durable_group writer journal staged command_count event_count;
       Continue
     | Error error ->
       (match Journal.commit_error_disposition error with
        | Journal.Reconcile_required ->
          let evidence = initial_reconciliation_evidence error in
          mark_reconciling writer staged evidence;
          Reconcile { batch; staged; command_count; event_count; evidence }
        | Journal.Final_failure -> Group_failed (Mutation_writer_failed error)))
;;

let detach_ready writer =
  let rec await () =
    Eio.Mutex.lock writer.mu;
    match writer.newest_first, writer.admission with
    | [], Accepting ->
      (match Eio.Condition.await writer.changed writer.mu with
       | () ->
         Eio.Mutex.unlock writer.mu;
         await ()
       | exception exn ->
         Eio.Mutex.unlock writer.mu;
         raise exn)
    | [], (Draining | Failed _ | Closed) ->
      Eio.Mutex.unlock writer.mu;
      None
    | newest_first, _ ->
      let command_count = writer.queue_depth in
      writer.newest_first <- [];
      writer.queue_depth <- 0;
      writer.in_flight <- newest_first;
      writer.in_flight_commands <- command_count;
      writer.worker_phase <- Committing_group;
      Eio.Mutex.unlock writer.mu;
      Some (reverse_ready newest_first)
  in
  await ()
;;

let reconciliation_wake_token writer =
  with_lock writer.mu (fun () -> writer.reconciliation_wake_token)
;;

let rec run_ready writer durable_writer journal =
  match detach_ready writer with
  | None -> Epoch_closed
  | Some commands ->
    (match process_ready writer durable_writer journal commands with
     | Continue ->
       Eio.Fiber.check ();
       run_ready writer durable_writer journal
     | Reconcile pending -> Epoch_reconcile (Group_outcome_unknown pending)
     | Await_reconciliation_wake pending ->
       Epoch_await_reconciliation_wake
         { pending = Group_outcome_unknown pending
         ; observed_wake = reconciliation_wake_token writer
         }
     | Group_failed failure -> Epoch_failed failure)
;;

let open_writer writer ~sw mode =
  match mode with
  | Create correlation_id ->
    (match
       Journal.create_durable_writer
         ~sw
         ~codec:writer.codec
         ~dir:writer.dir
         ?correlation_id
         ()
     with
     | Error error -> Error error
     | Ok (durable_writer, _initialization) ->
       Ok (durable_writer, Journal.durable_writer_journal durable_writer))
  | Open_existing ->
    (match Journal.open_durable_writer ~sw ~codec:writer.codec ~dir:writer.dir with
     | Error error -> Error error
     | Ok (durable_writer, _recovery) ->
       Ok (durable_writer, Journal.durable_writer_journal durable_writer))
;;

let publish_open_journal writer journal =
  Eio.Cancel.protect (fun () ->
    with_lock writer.mu (fun () ->
      writer.journal_view <- Available journal;
      writer.pending_outcome <- None;
      writer.worker_phase <- Idle);
    ignore (Eio.Promise.try_resolve writer.resolve_ready (Ok ())))
;;

let reconcile_pending writer durable_writer journal pending =
  match Journal.reconcile_durable_batch durable_writer pending.batch with
  | Ok (Journal.Applied _events | Journal.Already_durable _events) ->
    finish_durable_group
      writer
      journal
      pending.staged
      pending.command_count
      pending.event_count;
    Continue
  | Error error ->
    (match Journal.commit_error_disposition error with
     | Journal.Reconcile_required ->
       let evidence = observe_reconciliation_unknown pending.evidence error in
       mark_reconciling writer pending.staged evidence;
       (match unresolved_on_close writer evidence with
        | Some failure -> Group_failed failure
        | None -> Await_reconciliation_wake { pending with evidence })
     | Journal.Final_failure ->
       Group_failed
         (Reconciliation_failed
            { evidence = pending.evidence; reconciliation_error = error }))
;;

let mark_pending_reconciliation writer = function
  | Initialization_outcome_unknown evidence ->
    mark_initialization_reconciling writer evidence
  | Group_outcome_unknown pending ->
    mark_reconciling writer pending.staged pending.evidence
;;

let pending_with_unknown pending error =
  match pending with
  | Initialization_outcome_unknown evidence ->
    Initialization_outcome_unknown (observe_reconciliation_unknown evidence error)
  | Group_outcome_unknown group ->
    Group_outcome_unknown
      { group with evidence = observe_reconciliation_unknown group.evidence error }
;;

let failure_after_reconciliation pending reconciliation_error =
  match pending with
  | Initialization_outcome_unknown evidence ->
    Initialization_reconciliation_failed { evidence; reconciliation_error }
  | Group_outcome_unknown pending ->
    Reconciliation_failed { evidence = pending.evidence; reconciliation_error }
;;

let run_epoch writer mode pending =
  let observed_wake = reconciliation_wake_token writer in
  Eio.Switch.run (fun store_sw ->
    match open_writer writer ~sw:store_sw mode with
    | Error error ->
      (match Journal.commit_error_disposition error, pending with
       | Journal.Reconcile_required, None ->
         let evidence = initial_reconciliation_evidence error in
         mark_initialization_reconciling writer evidence;
         Epoch_reconcile (Initialization_outcome_unknown evidence)
       | Journal.Reconcile_required, Some pending ->
         let pending = pending_with_unknown pending error in
         mark_pending_reconciliation writer pending;
         let evidence =
           match pending with
           | Initialization_outcome_unknown evidence -> evidence
           | Group_outcome_unknown pending -> pending.evidence
         in
         (match unresolved_on_close writer evidence with
          | Some failure -> Epoch_failed failure
          | None -> Epoch_await_reconciliation_wake { pending; observed_wake })
       | Journal.Final_failure, None -> Epoch_failed (Initialization_failed error)
       | Journal.Final_failure, Some pending ->
         Epoch_failed (failure_after_reconciliation pending error))
    | Ok (durable_writer, journal) ->
      (match pending with
       | None ->
         publish_open_journal writer journal;
         run_ready writer durable_writer journal
       | Some (Initialization_outcome_unknown _) ->
         publish_open_journal writer journal;
         Eio.Fiber.check ();
         run_ready writer durable_writer journal
       | Some (Group_outcome_unknown pending) ->
         (match reconcile_pending writer durable_writer journal pending with
          | Continue ->
            Eio.Fiber.check ();
            run_ready writer durable_writer journal
          | Reconcile pending -> Epoch_reconcile (Group_outcome_unknown pending)
          | Await_reconciliation_wake pending ->
            Epoch_await_reconciliation_wake
              { pending = Group_outcome_unknown pending; observed_wake }
          | Group_failed failure -> Epoch_failed failure)))
;;

let complete_actor writer =
  Eio.Cancel.protect (fun () ->
    let transitioned =
      with_lock writer.mu (fun () ->
        match writer.admission with
        | Failed _ | Closed -> false
        | Accepting | Draining ->
          writer.admission <- Closed;
          writer.worker_phase <- Idle;
          writer.pending_outcome <- None;
          writer.in_flight <- [];
          writer.in_flight_commands <- 0;
          true)
    in
    if transitioned
    then (
      ignore (Eio.Promise.try_resolve writer.resolve_ready (Ok ()));
      ignore (Eio.Promise.try_resolve writer.resolve_closed (Ok ()))))
;;

let fail_actor writer failure =
  Eio.Cancel.protect (fun () ->
    let pending =
      with_lock writer.mu (fun () ->
        match writer.admission with
        | Failed _ | Closed -> None
        | Accepting | Draining ->
          let failure =
            match writer.pending_outcome, failure with
            | Some evidence, Supervisor_cancelled interruption
            | Some evidence, Unexpected_exception interruption ->
              Reconciliation_interrupted { evidence; interruption }
            | None, _
            | ( Some _
              , ( Initialization_failed _
                | Initialization_reconciliation_failed _
                | Mutation_writer_failed _
                | Reconciliation_failed _
                | Reconciliation_interrupted _
                | Reconciliation_unresolved_on_close _ ) ) -> failure
          in
          writer.admission <- Failed failure;
          writer.worker_phase <- Idle;
          writer.journal_view <- Unavailable failure;
          writer.pending_outcome <- None;
          let in_flight = writer.in_flight in
          let queued = writer.newest_first in
          writer.in_flight <- [];
          writer.in_flight_commands <- 0;
          writer.newest_first <- [];
          writer.queue_depth <- 0;
          Some (failure, in_flight, queued))
    in
    match pending with
    | None -> ()
    | Some (failure, in_flight, queued) ->
      ignore (Eio.Promise.try_resolve writer.resolve_ready (Error failure));
      let rec settle_all count = function
        | [] -> count
        | command :: rest ->
          let count = if settle_command failure command then count + 1 else count in
          Eio.Fiber.yield ();
          settle_all count rest
      in
      let newly_settled = settle_all (settle_all 0 in_flight) queued in
      record_settled writer newly_settled;
      ignore (Eio.Promise.try_resolve writer.resolve_closed (Error failure)))
;;

let await_reconciliation_wake writer observed_wake =
  let rec await () =
    Eio.Mutex.lock writer.mu;
    if writer.reconciliation_wake_token != observed_wake
    then (
      let wake = writer.last_reconciliation_wake in
      Eio.Mutex.unlock writer.mu;
      match wake with
      | Some wake -> wake
      | None -> invalid_arg "execution lane reconciliation wake has no typed source")
    else (
      match writer.admission with
      | Failed _ | Closed ->
        Eio.Mutex.unlock writer.mu;
        invalid_arg "execution lane reconciliation wait outlived its admission"
      | Draining ->
        writer.reconciliation_wake_token <- ref ();
        writer.last_reconciliation_wake <- Some Close_requested;
        writer.reconciliation_wakes <- writer.reconciliation_wakes + 1;
        writer.worker_phase <- Reconciling_group;
        Eio.Mutex.unlock writer.mu;
        Close_requested
      | Accepting ->
        writer.worker_phase <- Awaiting_reconciliation_wake;
        (match Eio.Condition.await writer.changed writer.mu with
         | () ->
           Eio.Mutex.unlock writer.mu;
           await ()
         | exception exn ->
           Eio.Mutex.unlock writer.mu;
           raise exn))
  in
  await ()
;;

let run_actor writer =
  let rec epochs mode pending =
    match run_epoch writer mode pending with
    | Epoch_closed -> complete_actor writer
    | Epoch_failed failure -> fail_actor writer failure
    | Epoch_reconcile next ->
      Eio.Fiber.yield ();
      Eio.Fiber.check ();
      epochs Open_existing (Some next)
    | Epoch_await_reconciliation_wake { pending; observed_wake } ->
      let _wake = await_reconciliation_wake writer observed_wake in
      Eio.Fiber.check ();
      epochs Open_existing (Some pending)
  in
  match epochs writer.initial_mode None with
  | () -> ()
  | exception (Eio.Cancel.Cancelled reason as exn) ->
    let bt = Printexc.get_raw_backtrace () in
    fail_actor writer (Supervisor_cancelled reason);
    Printexc.raise_with_backtrace exn bt
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) ->
    let bt = Printexc.get_raw_backtrace () in
    fail_actor writer (Unexpected_exception exn);
    Printexc.raise_with_backtrace exn bt
  | exception exn -> fail_actor writer (Unexpected_exception exn)
;;

let spawn ~sw ~codec ~dir initial_mode =
  let ready, resolve_ready = Eio.Promise.create () in
  let closed, resolve_closed = Eio.Promise.create () in
  let writer =
    { dir
    ; codec
    ; initial_mode
    ; mu = Eio.Mutex.create ()
    ; changed = Eio.Condition.create ()
    ; newest_first = []
    ; queue_depth = 0
    ; in_flight = []
    ; in_flight_commands = 0
    ; admission = Accepting
    ; worker_phase = Starting
    ; journal_view = No_journal
    ; pending_outcome = None
    ; reconciliation_wake_token = ref ()
    ; last_reconciliation_wake = None
    ; accepted = 0
    ; settled = 0
    ; committed_groups = 0
    ; committed_commands = 0
    ; committed_events = 0
    ; reconciliation_unknowns = 0
    ; reconciliation_wakes = 0
    ; ready
    ; resolve_ready
    ; closed
    ; resolve_closed
    }
  in
  (match Eio.Switch.get_error sw with
   | Some (Eio.Cancel.Cancelled reason) -> fail_actor writer (Supervisor_cancelled reason)
   | Some reason -> fail_actor writer (Supervisor_cancelled reason)
   | None ->
     Eio.Fiber.fork_daemon ~sw (fun () ->
       run_actor writer;
       `Stop_daemon));
  writer
;;

let signal_reconciliation_locked writer event =
  match writer.pending_outcome, writer.journal_view, writer.worker_phase with
  | Some _, Reconciliation_in_progress, Awaiting_reconciliation_wake ->
    writer.reconciliation_wake_token <- ref ();
    writer.last_reconciliation_wake <- Some event;
    writer.reconciliation_wakes <- writer.reconciliation_wakes + 1;
    writer.worker_phase <- Reconciling_group;
    true
  | None, _, _
  | Some _, (No_journal | Available _ | Unavailable _), _
  | ( Some _
    , Reconciliation_in_progress
    , (Starting | Idle | Committing_group | Reconciling_group) ) -> false
;;

let wake_reconciliation writer ~source =
  let wake =
    with_lock writer.mu (fun () ->
      signal_reconciliation_locked writer (External_wake source))
  in
  if wake then Eio.Condition.broadcast writer.changed;
  wake
;;

let submit writer transaction =
  let ticket = make_ticket () in
  let result, wake =
    with_lock writer.mu (fun () ->
      match writer.admission with
      | Failed failure -> Error (Admission_failed failure), false
      | Draining | Closed -> Error Admission_closed, false
      | Accepting ->
        let wake = writer.newest_first = [] in
        writer.newest_first <- Command { transaction; ticket } :: writer.newest_first;
        writer.queue_depth <- writer.queue_depth + 1;
        writer.accepted <- writer.accepted + 1;
        Ok ticket, wake)
  in
  if wake then Eio.Condition.broadcast writer.changed;
  result
;;

let close writer =
  let wake =
    with_lock writer.mu (fun () ->
      match writer.admission with
      | Accepting ->
        ignore (signal_reconciliation_locked writer Close_requested);
        writer.admission <- Draining;
        true
      | Draining | Failed _ | Closed -> false)
  in
  if wake then Eio.Condition.broadcast writer.changed
;;

let await_closed writer = Eio.Promise.await writer.closed
let await_ready writer = Eio.Promise.await writer.ready

let close_and_await writer =
  close writer;
  await_closed writer
;;

let run_with_mode ~codec ~dir mode f =
  Eio.Switch.run (fun sw ->
    let writer = spawn ~sw ~codec ~dir mode in
    match f ~sw writer with
    | value ->
      (match close_and_await writer with
       | Ok () -> Ok value
       | Error failure -> Error failure)
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      let shutdown =
        match Eio.Cancel.protect (fun () -> close_and_await writer) with
        | result -> result
        | exception shutdown_exn ->
          let shutdown_backtrace = Printexc.get_raw_backtrace () in
          (match Llm_provider.Reserved_exn.reraise_if_reserved exn with
           | () ->
             let combined, combined_backtrace =
               Eio.Exn.combine (exn, backtrace) (shutdown_exn, shutdown_backtrace)
             in
             Printexc.raise_with_backtrace combined combined_backtrace
           | exception reserved ->
             Log.error
               _log
               "writer shutdown raised after reserved callback exception"
               [ Log.S ("shutdown_exception", Printexc.to_string shutdown_exn) ];
             Printexc.raise_with_backtrace reserved backtrace)
      in
      (match shutdown with
       | Ok () -> Printexc.raise_with_backtrace exn backtrace
       | Error failure ->
         (match Llm_provider.Reserved_exn.reraise_if_reserved exn with
          | () ->
            Printexc.raise_with_backtrace
              (Callback_failed_after_scope_failure (exn, failure))
              backtrace
          | exception reserved ->
            Log.error
              _log
              "writer shutdown failed after reserved callback exception"
              [ Log.S ("scope_failure", scope_failure_to_string failure) ];
            Printexc.raise_with_backtrace reserved backtrace)))
;;

let run ~codec ~dir ?correlation_id f =
  run_with_mode ~codec ~dir (Create correlation_id) f
;;

let resume ~codec ~dir f = run_with_mode ~codec ~dir Open_existing f

let read_journal writer f =
  let journal_view = with_lock writer.mu (fun () -> writer.journal_view) in
  match journal_view with
  | No_journal -> Error Journal_not_ready
  | Reconciliation_in_progress -> Error Journal_reconciling
  | Unavailable failure -> Error (Journal_unavailable failure)
  | Available journal -> f journal
;;

let current_cursor writer =
  read_journal writer (fun journal -> Ok (Journal.current_cursor journal))
;;

let find_node writer node =
  read_journal writer (fun journal -> Ok (Journal.find_node journal node))
;;

let find_run writer run_id =
  read_journal writer (fun journal -> Ok (Journal.find_run journal run_id))
;;

let read_page writer ~after ?through ~limit () =
  read_journal writer (fun journal ->
    match Journal.read_page journal ~after ?through ~limit () with
    | Ok page ->
      Ok
        { events = page.events
        ; next_cursor = page.next_cursor
        ; high_watermark = page.high_watermark
        ; has_more = page.has_more
        }
    | Error error -> Error (Journal_read_failed error))
;;

let stats writer =
  with_lock writer.mu (fun () ->
    { admission = writer.admission
    ; worker_phase = writer.worker_phase
    ; queue_depth = writer.queue_depth
    ; in_flight_commands = writer.in_flight_commands
    ; accepted = writer.accepted
    ; settled = writer.settled
    ; committed_groups = writer.committed_groups
    ; committed_commands = writer.committed_commands
    ; committed_events = writer.committed_events
    ; reconciliation_unknowns = writer.reconciliation_unknowns
    ; reconciliation_wakes = writer.reconciliation_wakes
    ; current_reconciliation = writer.pending_outcome
    ; last_reconciliation_wake = writer.last_reconciliation_wake
    })
;;
