module Core = Capability_recovery_obligation
module Reconciler = Capability_recovery_reconciler

type owner = Core.owner

type owner_inventory_row =
  | Valid_owner of owner
  | Invalid_owner_name of string
  | Unexpected_owner_kind of
      { owner : owner
      ; kind : Eio.File.Stat.kind
      }
  | Missing_owner_entry of owner
  | Owner_entry_unavailable of
      { owner : owner
      ; error : Core.transition_error
      }

type owner_inventory = owner_inventory_row list

type inventory_error =
  | Registry_inventory_in_progress
  | Registry_inventory_failed of Core.transition_error

type owner_block =
  | Owner_inventory_block of owner_inventory_row
  | Owner_reconciliation_block of Reconciler.report
  | Owner_reconciliation_crash of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_reconciliation_cancelled_block of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_activation_rejected_block of owner

type reconciliation_error =
  | Owner_inventory_required of owner
  | Owner_inventory_in_progress of owner
  | Owner_not_in_inventory of owner
  | Owner_reconciliation_in_progress of owner
  | Owner_inventory_prevents_reconciliation of owner_inventory_row
  | Owner_reconciliation_crashed of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_reconciliation_cancelled of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_activation_rejected of owner

type activation_rejection_error =
  | Activation_inventory_required of owner
  | Activation_inventory_in_progress of owner
  | Activation_owner_not_in_inventory of owner
  | Activation_owner_reconciliation_running of owner
  | Activation_owner_already_ready of owner
  | Activation_owner_already_blocked of owner_block

type readiness =
  | Reconciliation_pending
  | Reconciliation_running
  | Reconciliation_ready of Reconciler.report
  | Reconciliation_blocked_state of owner_block

type readiness_entry =
  { readiness : readiness
  ; settled : unit Eio.Promise.t
  ; resolve_settled : unit Eio.Promise.u
  }

module Owner_map = Map.Make (String)

type registry_phase =
  | Inventory_required
  | Inventory_running
  | Inventory_complete of
      { rows : owner_inventory
      ; readiness : readiness_entry Owner_map.t
      }

type registry =
  { core : Core.registry
  ; readiness_mutex : Eio.Mutex.t
  ; mutable registry_phase : registry_phase
  }

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Core.validation_error
  | Reconciliation_required of owner
  | Reconciliation_in_progress of owner
  | Reconciliation_blocked of owner_block
  | Store_failed of Core.transition_error

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved
  | Inventory_finished_outside_running
  | Reconciliation_finished_before_inventory
  | Reconciliation_owner_not_running of string
  | Reconciliation_settled_twice of string
  | Reconciliation_settled_before_terminal of string
  | Cleanup_body_outcome_lost

exception Invariant_violation of invariant_violation

type cleanup_failure =
  { body : Eio.Exn.with_bt option
  ; cancellation : Eio.Exn.with_bt option
  ; cleanup : Eio.Exn.with_bt
  }

exception Cleanup_failed of cleanup_failure

type body_failed_during_cancellation =
  { body : Eio.Exn.with_bt
  ; cancellation : Eio.Exn.with_bt
  }

exception Body_failed_during_cancellation of
  body_failed_during_cancellation

type reconciliation_crash_terminalization_failure =
  { reconciliation : Eio.Exn.with_bt
  ; terminalization : Eio.Exn.with_bt
  }

exception Reconciliation_crash_terminalization_failed of
  reconciliation_crash_terminalization_failure

type reconciliation_cancellation_terminalization_failure =
  { cancellation : Eio.Exn.with_bt
  ; terminalization : Eio.Exn.with_bt
  }

exception Reconciliation_cancellation_terminalization_failed of
  reconciliation_cancellation_terminalization_failure

type phase =
  | Open
  | Closing
  | Closed

type t =
  { store : Core.store
  ; mutex : Eio.Mutex.t
  ; mutable phase : phase
  ; mutable in_flight : int
  ; drained : unit Eio.Promise.t
  ; resolve_drained : unit Eio.Promise.u
  }

type 'a outcome =
  | Returned of 'a
  | Raised of Eio.Exn.with_bt

type borrow_decision =
  | Borrowed of Core.store
  | Borrow_rejected
  | Borrow_invariant of invariant_violation

type release_decision =
  | Released
  | Release_and_signal
  | Release_invariant of invariant_violation

type close_decision =
  | Close_and_signal
  | Await_drain
  | Already_drained
  | Close_invariant of invariant_violation

let access_error_to_string = function
  | Keeper_lane_not_available ->
    "keeper lane publication recovery store is not available"
;;

let validation_error_to_string = Core.validation_error_to_string
let transition_error_to_string = Core.transition_error_to_string

let owner_to_string = Core.owner_to_string

let owner_inventory_row_to_string = function
  | Valid_owner owner ->
    Printf.sprintf "valid_owner(%S)" (owner_to_string owner)
  | Invalid_owner_name name ->
    Printf.sprintf "invalid_owner_name(%S)" name
  | Unexpected_owner_kind { owner; kind } ->
    Format.asprintf
      "unexpected_owner_kind(%S,%a)"
      (owner_to_string owner)
      Eio.File.Stat.pp_kind
      kind
  | Missing_owner_entry owner ->
    Printf.sprintf "missing_owner_entry(%S)" (owner_to_string owner)
  | Owner_entry_unavailable { owner; error } ->
    Printf.sprintf
      "owner_entry_unavailable(%S,%s)"
      (owner_to_string owner)
      (Core.transition_error_to_string error)
;;

let owner_block_to_string = function
  | Owner_inventory_block row -> owner_inventory_row_to_string row
  | Owner_reconciliation_block report -> Reconciler.report_to_string report
  | Owner_reconciliation_crash { owner; exception_; _ } ->
    Printf.sprintf
      "owner_reconciliation_crash(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string exception_)
  | Owner_reconciliation_cancelled_block { owner; reason; _ } ->
    Printf.sprintf
      "owner_reconciliation_cancelled(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string reason)
  | Owner_activation_rejected_block owner ->
    Printf.sprintf
      "owner_activation_rejected(%S)"
      (owner_to_string owner)
;;

let inventory_error_to_string = function
  | Registry_inventory_in_progress ->
    "publication recovery owner inventory is already in progress"
  | Registry_inventory_failed error -> Core.transition_error_to_string error
;;

let reconciliation_error_to_string = function
  | Owner_inventory_required owner ->
    Printf.sprintf
      "publication recovery owner inventory is required before reconciling owner %S"
      (owner_to_string owner)
  | Owner_inventory_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inventory is in progress before reconciling owner %S"
      (owner_to_string owner)
  | Owner_not_in_inventory owner ->
    Printf.sprintf
      "publication recovery owner %S was not present in the startup inventory"
      (owner_to_string owner)
  | Owner_reconciliation_in_progress owner ->
    Printf.sprintf
      "publication recovery reconciliation is already in progress for owner %S"
      (owner_to_string owner)
  | Owner_inventory_prevents_reconciliation row ->
    Printf.sprintf
      "owner inventory prevents publication recovery reconciliation: %s"
      (owner_inventory_row_to_string row)
  | Owner_reconciliation_crashed { owner; exception_; _ } ->
    Printf.sprintf
      "publication recovery reconciliation crashed for owner %S: %s"
      (owner_to_string owner)
      (Printexc.to_string exception_)
  | Owner_reconciliation_cancelled { owner; reason; _ } ->
    Printf.sprintf
      "publication recovery reconciliation was internally cancelled for owner %S: %s"
      (owner_to_string owner)
      (Printexc.to_string reason)
  | Owner_activation_rejected owner ->
    Printf.sprintf
      "publication recovery activation was rejected for owner %S"
      (owner_to_string owner)
;;

let activation_rejection_error_to_string = function
  | Activation_inventory_required owner ->
    Printf.sprintf
      "publication recovery owner inventory is required before rejecting activation for owner %S"
      (owner_to_string owner)
  | Activation_inventory_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inventory is in progress while rejecting activation for owner %S"
      (owner_to_string owner)
  | Activation_owner_not_in_inventory owner ->
    Printf.sprintf
      "publication recovery owner %S was not present in the startup inventory"
      (owner_to_string owner)
  | Activation_owner_reconciliation_running owner ->
    Printf.sprintf
      "publication recovery reconciliation is running while rejecting activation for owner %S"
      (owner_to_string owner)
  | Activation_owner_already_ready owner ->
    Printf.sprintf
      "publication recovery owner %S was already ready when activation rejection arrived"
      (owner_to_string owner)
  | Activation_owner_already_blocked block ->
    Printf.sprintf
      "publication recovery owner was already terminal when activation rejection arrived: %s"
      (owner_block_to_string block)
;;

let lane_open_error_to_string = function
  | Invalid_owner error -> Core.validation_error_to_string error
  | Reconciliation_required owner ->
    Printf.sprintf
      "publication recovery reconciliation is required for owner %S"
      (owner_to_string owner)
  | Reconciliation_in_progress owner ->
    Printf.sprintf
      "publication recovery reconciliation is in progress for owner %S"
      (owner_to_string owner)
  | Reconciliation_blocked block ->
    Printf.sprintf
      "publication recovery reconciliation blocks this owner: %s"
      (owner_block_to_string block)
  | Store_failed error -> Core.transition_error_to_string error
;;

let open_registry ~sw ~registry_root =
  match Core.open_registry ~sw ~registry_root with
  | Error _ as error -> error
  | Ok core ->
    Ok
      { core
      ; readiness_mutex = Eio.Mutex.create ()
      ; registry_phase = Inventory_required
      }
;;

let map_owner_inventory_row = function
  | Core.Valid_owner owner -> Valid_owner owner
  | Core.Invalid_owner_name name -> Invalid_owner_name name
  | Core.Unexpected_owner_kind { owner; kind } ->
    Unexpected_owner_kind { owner; kind }
  | Core.Missing_owner_entry owner -> Missing_owner_entry owner
  | Core.Owner_entry_unavailable { owner; error } ->
    Owner_entry_unavailable { owner; error }
;;

let make_readiness_entry readiness =
  let settled, resolve_settled = Eio.Promise.create () in
  { readiness; settled; resolve_settled }
;;

let settle_owner key resolve_settled =
  if not (Eio.Promise.try_resolve resolve_settled ())
  then
    raise
      (Invariant_violation (Reconciliation_settled_twice key))
;;

let add_inventory_readiness (readiness, terminal_resolvers) row =
  let owner_and_readiness =
    match row with
    | Valid_owner owner -> Some (owner, Reconciliation_pending)
    | Missing_owner_entry owner ->
      Some
        ( owner
        , Reconciliation_blocked_state (Owner_inventory_block row) )
    | Owner_entry_unavailable { owner; _ } ->
      Some
        ( owner
        , Reconciliation_blocked_state (Owner_inventory_block row) )
    | Unexpected_owner_kind { owner; _ } ->
      Some
        ( owner
        , Reconciliation_blocked_state (Owner_inventory_block row) )
    | Invalid_owner_name _ -> None
  in
  match owner_and_readiness with
  | None -> readiness, terminal_resolvers
  | Some (owner, replacement) ->
    let key = owner_to_string owner in
    let entry = make_readiness_entry replacement in
    let terminal_resolvers =
      match replacement with
      | Reconciliation_blocked_state _ ->
        (key, entry.resolve_settled) :: terminal_resolvers
      | Reconciliation_pending
      | Reconciliation_running
      | Reconciliation_ready _ -> terminal_resolvers
    in
    Owner_map.add key entry readiness, terminal_resolvers
;;

type begin_inventory =
  | Begin_inventory
  | Existing_inventory of owner_inventory
  | Inventory_already_running

let begin_inventory registry =
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_required ->
      registry.registry_phase <- Inventory_running;
      Begin_inventory
    | Inventory_running -> Inventory_already_running
    | Inventory_complete { rows; _ } -> Existing_inventory rows)
;;

let reset_interrupted_inventory registry =
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_running -> registry.registry_phase <- Inventory_required
    | Inventory_required | Inventory_complete _ -> ())
;;

let finish_inventory registry rows =
  let readiness, terminal_resolvers =
    List.fold_left
      add_inventory_readiness
      (Owner_map.empty, [])
      rows
  in
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_running ->
      registry.registry_phase <- Inventory_complete { rows; readiness }
    | Inventory_required | Inventory_complete _ ->
      raise
        (Invariant_violation Inventory_finished_outside_running));
  List.iter
    (fun (key, resolve_settled) -> settle_owner key resolve_settled)
    (List.rev terminal_resolvers)
;;

let inventory_owners registry =
  match begin_inventory registry with
  | Existing_inventory rows -> Ok rows
  | Inventory_already_running -> Error Registry_inventory_in_progress
  | Begin_inventory ->
    (match Core.inventory_owners registry.core with
     | Error error ->
       reset_interrupted_inventory registry;
       Error (Registry_inventory_failed error)
     | Ok rows ->
       let rows = List.map map_owner_inventory_row rows in
       finish_inventory registry rows;
       Ok rows
     | exception exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       reset_interrupted_inventory registry;
       Printexc.raise_with_backtrace exception_ backtrace)
;;

type begin_reconciliation =
  | Begin_reconciliation
  | Existing_report of Reconciler.report
  | Begin_reconciliation_failed of reconciliation_error

let begin_reconciliation registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_required ->
      Begin_reconciliation_failed (Owner_inventory_required owner)
    | Inventory_running ->
      Begin_reconciliation_failed (Owner_inventory_in_progress owner)
    | Inventory_complete state ->
      (match Owner_map.find_opt key state.readiness with
       | None -> Begin_reconciliation_failed (Owner_not_in_inventory owner)
       | Some ({ readiness = Reconciliation_pending; _ } as entry) ->
         registry.registry_phase <-
           Inventory_complete
             { state with
               readiness =
                 Owner_map.add
                   key
                   { entry with readiness = Reconciliation_running }
                   state.readiness
             };
         Begin_reconciliation
       | Some { readiness = Reconciliation_running; _ } ->
         Begin_reconciliation_failed
           (Owner_reconciliation_in_progress owner)
       | Some { readiness = Reconciliation_ready report; _ } ->
         Existing_report report
       | Some
           { readiness =
               Reconciliation_blocked_state
                 (Owner_reconciliation_block report)
           ; _
           } ->
         Existing_report report
       | Some
           { readiness =
               Reconciliation_blocked_state (Owner_inventory_block row)
           ; _
           } ->
         Begin_reconciliation_failed
           (Owner_inventory_prevents_reconciliation row)
       | Some
           { readiness =
               Reconciliation_blocked_state
                 (Owner_reconciliation_crash
                   { owner; exception_; backtrace })
           ; _
           } ->
         Begin_reconciliation_failed
           (Owner_reconciliation_crashed { owner; exception_; backtrace })
       | Some
           { readiness =
               Reconciliation_blocked_state
                 (Owner_reconciliation_cancelled_block
                   { owner; reason; backtrace })
           ; _
           } ->
         Begin_reconciliation_failed
           (Owner_reconciliation_cancelled { owner; reason; backtrace })
       | Some
           { readiness =
               Reconciliation_blocked_state
                 (Owner_activation_rejected_block owner)
           ; _
           } ->
         Begin_reconciliation_failed (Owner_activation_rejected owner)))
;;

let finish_reconciliation_terminal registry owner terminal =
  let key = owner_to_string owner in
  let resolve_settled =
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Inventory_complete state ->
        (match Owner_map.find_opt key state.readiness with
         | Some ({ readiness = Reconciliation_running; _ } as entry) ->
           registry.registry_phase <-
             Inventory_complete
               { state with
                 readiness =
                   Owner_map.add
                     key
                     { entry with readiness = terminal }
                     state.readiness
               };
           entry.resolve_settled
         | None
         | Some
             { readiness =
                 ( Reconciliation_pending
                 | Reconciliation_ready _
                 | Reconciliation_blocked_state _ )
             ; _
             } ->
           raise
             (Invariant_violation
                (Reconciliation_owner_not_running key)))
      | Inventory_required | Inventory_running ->
        raise
          (Invariant_violation Reconciliation_finished_before_inventory))
  in
  settle_owner key resolve_settled
;;

let finish_reconciliation registry owner report =
  let terminal =
    if Reconciler.report_is_ready report
    then Reconciliation_ready report
    else
      Reconciliation_blocked_state
        (Owner_reconciliation_block report)
  in
  finish_reconciliation_terminal registry owner terminal
;;

let finish_reconciliation_crash registry owner exception_ backtrace =
  finish_reconciliation_terminal
    registry
    owner
    (Reconciliation_blocked_state
       (Owner_reconciliation_crash { owner; exception_; backtrace }))
;;

let finish_reconciliation_cancelled registry owner reason backtrace =
  finish_reconciliation_terminal
    registry
    owner
    (Reconciliation_blocked_state
       (Owner_reconciliation_cancelled_block { owner; reason; backtrace }))
;;

let reset_interrupted_reconciliation registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_complete state ->
      (match Owner_map.find_opt key state.readiness with
       | Some ({ readiness = Reconciliation_running; _ } as entry) ->
         registry.registry_phase <-
           Inventory_complete
             { state with
               readiness =
                 Owner_map.add
                   key
                   { entry with readiness = Reconciliation_pending }
                   state.readiness
             }
       | None
       | Some
           { readiness =
               ( Reconciliation_pending
               | Reconciliation_ready _
               | Reconciliation_blocked_state _ )
           ; _
           } -> ())
    | Inventory_required | Inventory_running -> ())
;;

type activation_rejection_decision =
  | Reject_activation of string * unit Eio.Promise.u
  | Reject_activation_failed of activation_rejection_error

let reject_owner_activation ~registry ~owner =
  let key = owner_to_string owner in
  let decision =
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Inventory_required ->
        Reject_activation_failed (Activation_inventory_required owner)
      | Inventory_running ->
        Reject_activation_failed (Activation_inventory_in_progress owner)
      | Inventory_complete state ->
        (match Owner_map.find_opt key state.readiness with
         | None ->
           Reject_activation_failed (Activation_owner_not_in_inventory owner)
         | Some ({ readiness = Reconciliation_pending; _ } as entry) ->
           let block = Owner_activation_rejected_block owner in
           registry.registry_phase <-
             Inventory_complete
               { state with
                 readiness =
                   Owner_map.add
                     key
                     { entry with
                       readiness = Reconciliation_blocked_state block
                     }
                     state.readiness
               };
           Reject_activation (key, entry.resolve_settled)
         | Some { readiness = Reconciliation_running; _ } ->
           Reject_activation_failed
             (Activation_owner_reconciliation_running owner)
         | Some { readiness = Reconciliation_ready _; _ } ->
           Reject_activation_failed (Activation_owner_already_ready owner)
         | Some { readiness = Reconciliation_blocked_state block; _ } ->
           Reject_activation_failed (Activation_owner_already_blocked block)))
  in
  match decision with
  | Reject_activation (key, resolve_settled) ->
    settle_owner key resolve_settled;
    Ok ()
  | Reject_activation_failed error -> Error error
;;

let reconcile_owner_with ~reconcile ~fs ~registry ~owner =
  match begin_reconciliation registry owner with
  | Existing_report report -> Ok report
  | Begin_reconciliation_failed error -> Error error
  | Begin_reconciliation ->
    let report =
      try reconcile ~fs ~registry:registry.core ~owner with
      | Eio.Cancel.Cancelled reason as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        let current_context_cancelled =
          match Eio.Fiber.check () with
          | () -> false
          | exception Eio.Cancel.Cancelled _ -> true
        in
        if current_context_cancelled
        then (
          reset_interrupted_reconciliation registry owner;
          Printexc.raise_with_backtrace cancellation backtrace)
        else
          (match
             finish_reconciliation_cancelled
               registry
               owner
               reason
               backtrace
           with
           | () -> Printexc.raise_with_backtrace cancellation backtrace
           | exception terminalization_exception ->
             let terminalization_backtrace = Printexc.get_raw_backtrace () in
             Printexc.raise_with_backtrace
               (Reconciliation_cancellation_terminalization_failed
                  { cancellation = cancellation, backtrace
                  ; terminalization =
                      terminalization_exception, terminalization_backtrace
                  })
               terminalization_backtrace)
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        (match
           finish_reconciliation_crash
             registry
             owner
             exception_
             backtrace
         with
         | () -> Printexc.raise_with_backtrace exception_ backtrace
         | exception terminalization_exception ->
           let terminalization_backtrace = Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace
             (Reconciliation_crash_terminalization_failed
                { reconciliation = exception_, backtrace
                ; terminalization =
                    terminalization_exception, terminalization_backtrace
                })
             terminalization_backtrace)
    in
    finish_reconciliation registry owner report;
    Ok report
;;

let reconcile_owner =
  reconcile_owner_with ~reconcile:Reconciler.reconcile_owner
;;

let with_core_store_for_testing ~registry ~owner f =
  match Core.owner_of_string owner with
  | Error error -> Error (Invalid_owner error)
  | Ok owner ->
    (match Core.with_store ~registry:registry.core ~owner f with
     | Ok value -> Ok value
     | Error error -> Error (Store_failed error))
;;

let create store =
  let drained, resolve_drained = Eio.Promise.create () in
  { store
  ; mutex = Eio.Mutex.create ()
  ; phase = Open
  ; in_flight = 0
  ; drained
  ; resolve_drained
  }
;;

let capture f =
  match f () with
  | value -> Returned value
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Raised (exception_, backtrace)
;;

let raise_with_backtrace (exception_, backtrace) =
  Printexc.raise_with_backtrace exception_ backtrace
;;

let run_with_cleanup ~cleanup body =
  let body_outcome = capture body in
  let cleanup_outcome =
    Eio.Cancel.protect (fun () -> capture cleanup)
  in
  let parent_outcome = capture Eio.Fiber.check in
  let body_cancellation, body_failure =
    match body_outcome with
    | Raised (((Eio.Cancel.Cancelled _) as exception_), backtrace) ->
      Some (exception_, backtrace), None
    | Raised failure -> None, Some failure
    | Returned _ -> None, None
  in
  let parent_cancellation =
    match parent_outcome with
    | Raised (((Eio.Cancel.Cancelled _) as exception_), backtrace) ->
      Some (exception_, backtrace)
    | Returned () -> None
    | Raised failure -> raise_with_backtrace failure
  in
  let cancellation =
    match body_cancellation with
    | Some _ as cancellation -> cancellation
    | None -> parent_cancellation
  in
  match cleanup_outcome, cancellation, body_failure, body_outcome with
  | Raised cleanup, Some ((_, cancellation_backtrace) as cancellation), _, _ ->
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Cleanup_failed { body = body_failure; cancellation = Some cancellation; cleanup }))
      cancellation_backtrace
  | Raised cleanup, None, body, _ ->
    Printexc.raise_with_backtrace
      (Cleanup_failed { body; cancellation = None; cleanup })
      (snd cleanup)
  | Returned (), Some ((_, cancellation_backtrace) as cancellation), Some body, _ ->
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Body_failed_during_cancellation { body; cancellation }))
      cancellation_backtrace
  | Returned (), Some cancellation, None, _ -> raise_with_backtrace cancellation
  | Returned (), None, Some body, _ -> raise_with_backtrace body
  | Returned (), None, None, Returned value -> value
  | Returned (), None, None, Raised _ ->
    raise (Invariant_violation Cleanup_body_outcome_lost)
;;

let signal_drained t =
  if not (Eio.Promise.try_resolve t.resolve_drained ())
  then raise (Invariant_violation Drain_signal_already_resolved)
;;

let borrow t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match t.phase with
    | Open when t.in_flight = max_int ->
      Borrow_invariant Borrow_count_overflow
    | Open ->
      t.in_flight <- t.in_flight + 1;
      Borrowed t.store
    | Closing when t.in_flight <= 0 ->
      Borrow_invariant Closing_without_active_borrows
    | Closing -> Borrow_rejected
    | Closed when t.in_flight <> 0 ->
      Borrow_invariant (Closed_with_active_borrows t.in_flight)
    | Closed -> Borrow_rejected)
;;

let release t =
  let decision =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if t.in_flight <= 0
      then Release_invariant Borrow_count_underflow
      else
        match t.phase with
        | Open ->
          t.in_flight <- t.in_flight - 1;
          Released
        | Closing ->
          t.in_flight <- t.in_flight - 1;
          if t.in_flight = 0
          then (
            t.phase <- Closed;
            Release_and_signal)
          else Released
        | Closed ->
          Release_invariant
            (Closed_with_active_borrows t.in_flight))
  in
  match decision with
  | Released -> ()
  | Release_and_signal -> signal_drained t
  | Release_invariant invariant -> raise (Invariant_violation invariant)
;;

let close_and_drain t =
  let decision =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match t.phase with
      | Open when t.in_flight < 0 ->
        Close_invariant Borrow_count_underflow
      | Open when t.in_flight = 0 ->
        t.phase <- Closed;
        Close_and_signal
      | Open ->
        t.phase <- Closing;
        Await_drain
      | Closing when t.in_flight <= 0 ->
        Close_invariant Closing_without_active_borrows
      | Closing -> Await_drain
      | Closed when t.in_flight <> 0 ->
        Close_invariant (Closed_with_active_borrows t.in_flight)
      | Closed -> Already_drained)
  in
  match decision with
  | Close_and_signal -> signal_drained t
  | Await_drain -> Eio.Promise.await t.drained
  | Already_drained ->
    (match Eio.Promise.peek t.drained with
     | Some () -> ()
     | None -> raise (Invariant_violation Closed_without_drain_signal))
  | Close_invariant invariant -> raise (Invariant_violation invariant)
;;

let with_store t f =
  match borrow t with
  | Borrow_rejected ->
    Eio.Fiber.check ();
    Error Keeper_lane_not_available
  | Borrow_invariant invariant -> raise (Invariant_violation invariant)
  | Borrowed store ->
    run_with_cleanup
      ~cleanup:(fun () -> release t)
      (fun () ->
         Eio.Fiber.check ();
         Ok (f store))
;;

type lane_readiness =
  | Lane_ready
  | Lane_reconciliation_required
  | Lane_reconciliation_running
  | Lane_reconciliation_blocked of owner_block

type lane_wait_decision =
  | Lane_wait_ready
  | Lane_wait_inventory_required
  | Lane_wait_inventory_running
  | Lane_wait_pending of unit Eio.Promise.t
  | Lane_wait_running of unit Eio.Promise.t
  | Lane_wait_blocked of owner_block

let lane_wait_decision registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_ro registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Inventory_required -> Lane_wait_inventory_required
    | Inventory_running -> Lane_wait_inventory_running
    | Inventory_complete { readiness; _ } ->
      (match Owner_map.find_opt key readiness with
       | None | Some { readiness = Reconciliation_ready _; _ } ->
         Lane_wait_ready
       | Some { readiness = Reconciliation_pending; settled; _ } ->
         Lane_wait_pending settled
       | Some { readiness = Reconciliation_running; settled; _ } ->
         Lane_wait_running settled
       | Some
           { readiness = Reconciliation_blocked_state block; _ } ->
         Lane_wait_blocked block))
;;

let lane_readiness registry owner =
  match lane_wait_decision registry owner with
  | Lane_wait_ready -> Lane_ready
  | Lane_wait_inventory_required | Lane_wait_pending _ ->
    Lane_reconciliation_required
  | Lane_wait_inventory_running | Lane_wait_running _ ->
    Lane_reconciliation_running
  | Lane_wait_blocked block -> Lane_reconciliation_blocked block
;;

let await_lane_reconciliation ~registry ~owner =
  match Core.owner_of_string owner with
  | Error error -> Error (Invalid_owner error)
  | Ok owner ->
    let key = owner_to_string owner in
    let rec await_terminal settled_once =
      match lane_wait_decision registry owner with
      | Lane_wait_ready -> Ok ()
      | Lane_wait_inventory_required ->
        Error (Reconciliation_required owner)
      | Lane_wait_inventory_running ->
        Error (Reconciliation_in_progress owner)
      | Lane_wait_blocked block -> Error (Reconciliation_blocked block)
      | Lane_wait_pending settled | Lane_wait_running settled ->
        if settled_once
        then
          raise
            (Invariant_violation
               (Reconciliation_settled_before_terminal key));
        Eio.Promise.await settled;
        await_terminal true
    in
    await_terminal false
;;

let with_lane ~registry ~owner f =
  match Core.owner_of_string owner with
  | Error error -> Error (Invalid_owner error)
  | Ok owner ->
    (match lane_readiness registry owner with
     | Lane_reconciliation_required ->
       Error (Reconciliation_required owner)
     | Lane_reconciliation_running ->
       Error (Reconciliation_in_progress owner)
     | Lane_reconciliation_blocked block ->
       Error (Reconciliation_blocked block)
     | Lane_ready ->
       (match
          Core.with_store ~registry:registry.core ~owner (fun store ->
            let access = create store in
            run_with_cleanup
              ~cleanup:(fun () -> close_and_drain access)
              (fun () -> f access))
        with
        | Ok value -> Ok value
        | Error error -> Error (Store_failed error)))
;;

module For_testing = struct
  type reconciliation_interruption =
    | Cancel_reconciliation of exn
    | Crash_reconciliation of exn

  type cleanup_body =
    | Return_cleanup_value of string
    | Raise_cleanup_body of exn
    | Cancel_cleanup_body of exn

  type observed_failure =
    { exception_ : exn
    ; backtrace : Printexc.raw_backtrace
    }

  type cleanup_evidence =
    | Cleanup_returned of string
    | Cleanup_failed_without_cancellation of
        { body : observed_failure option
        ; cleanup : observed_failure
        }
    | Cancellation_primary_with_cleanup_failure of
        { body : observed_failure option
        ; cancellation : observed_failure
        ; cleanup : observed_failure
        }
    | Body_failure_during_cancellation of
        { body : observed_failure
        ; cancellation : observed_failure
        }
    | Cancellation_primary of observed_failure
    | Cleanup_boundary_raised of observed_failure

  type single_borrow_evidence =
    | Single_borrow_balance of
        { during_borrow : int
        ; after_release : int
        ; close_completed : bool
        }
    | Single_borrow_rejected
    | Single_borrow_invariant of invariant_violation
    | Single_borrow_raised of observed_failure

  type owner_settlement =
    | Owner_untracked
    | Owner_unsettled
    | Owner_settled

  let observed_failure (exception_, backtrace) =
    { exception_; backtrace }
  ;;

  let interrupt_reconciliation ~fs ~registry ~owner interruption =
    let reconcile ~fs:_ ~registry:_ ~owner:_ =
      match interruption with
      | Cancel_reconciliation reason ->
        raise (Eio.Cancel.Cancelled reason)
      | Crash_reconciliation exception_ -> raise exception_
    in
    reconcile_owner_with ~reconcile ~fs ~registry ~owner
  ;;

  let run_cleanup_boundary ~body ~cleanup_failure =
    let body () =
      match body with
      | Return_cleanup_value value -> value
      | Raise_cleanup_body exception_ -> raise exception_
      | Cancel_cleanup_body reason -> raise (Eio.Cancel.Cancelled reason)
    in
    let cleanup () = Option.iter raise cleanup_failure in
    match run_with_cleanup ~cleanup body with
    | value -> Cleanup_returned value
    | exception
        Eio.Cancel.Cancelled
          (Cleanup_failed { body; cancellation = Some cancellation; cleanup }) ->
      Cancellation_primary_with_cleanup_failure
        { body = Option.map observed_failure body
        ; cancellation = observed_failure cancellation
        ; cleanup = observed_failure cleanup
        }
    | exception Cleanup_failed { body; cancellation = None; cleanup } ->
      Cleanup_failed_without_cancellation
        { body = Option.map observed_failure body
        ; cleanup = observed_failure cleanup
        }
    | exception
        Eio.Cancel.Cancelled
          (Body_failed_during_cancellation { body; cancellation }) ->
      Body_failure_during_cancellation
        { body = observed_failure body
        ; cancellation = observed_failure cancellation
        }
    | exception Eio.Cancel.Cancelled reason ->
      let backtrace = Printexc.get_raw_backtrace () in
      Cancellation_primary { exception_ = reason; backtrace }
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Cleanup_boundary_raised { exception_; backtrace }
  ;;

  let in_flight t =
    Eio.Mutex.use_ro t.mutex (fun () -> t.in_flight)
  ;;

  let single_borrow_balance ~registry ~owner =
    with_core_store_for_testing ~registry ~owner @@ fun store ->
    let access = create store in
    match borrow access with
    | Borrow_rejected -> Single_borrow_rejected
    | Borrow_invariant invariant -> Single_borrow_invariant invariant
    | Borrowed _ ->
      let during_borrow = in_flight access in
      (match release access with
       | () ->
         let after_release = in_flight access in
         let close_completed =
           if after_release = 0
           then (
             close_and_drain access;
             true)
           else false
         in
         Single_borrow_balance
           { during_borrow; after_release; close_completed }
       | exception (Invariant_violation invariant) ->
         Single_borrow_invariant invariant
       | exception exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         Single_borrow_raised { exception_; backtrace })
  ;;

  let owner_settlement registry owner =
    let key = owner_to_string owner in
    Eio.Mutex.use_ro registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Inventory_required | Inventory_running -> Owner_untracked
      | Inventory_complete { readiness; _ } ->
        (match Owner_map.find_opt key readiness with
         | None -> Owner_untracked
         | Some { settled; _ } ->
           (match Eio.Promise.peek settled with
            | None -> Owner_unsettled
            | Some () -> Owner_settled)))
  ;;
end
