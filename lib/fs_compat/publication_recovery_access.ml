module Core = Capability_recovery_obligation
module Reconciler = Capability_recovery_reconciler

type owner = Core.owner

type owner_discovery_row =
  | Discovered_owner of owner
  | Invalid_owner_name of string

type owner_inventory_row =
  | Valid_owner of owner
  | Unexpected_owner_kind of
      { owner : owner
      ; kind : Eio.File.Stat.kind
      }
  | Missing_owner_entry of owner
  | Owner_entry_unavailable of
      { owner : owner
      ; error : Core.transition_error
      }
  | Owner_inventory_cancelled of
      { owner : owner
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Owner_inventory_crashed of
      { owner : owner
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type discovery_failure =
  | Registry_discovery_failed of Core.transition_error
  | Registry_discovery_cancelled of
      { reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Registry_discovery_crashed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type discovery_error =
  | Registry_discovery_in_progress
  | Registry_discovery_terminal of discovery_failure

type inspection_error =
  | Inspection_owner_in_progress of owner
  | Inspection_owner_already_terminal of owner_block

and owner_block =
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

type reconciliation_error =
  | Owner_inventory_pending of owner
  | Owner_inventory_in_progress of owner
  | Owner_reconciliation_not_required of owner
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

type readiness =
  | Owner_inventory_pending_state
  | Owner_inventory_running_state
  | No_recovery_obligation of owner_inventory_row
  | Reconciliation_pending
  | Reconciliation_running
  | Reconciliation_ready of Reconciler.report
  | Reconciliation_blocked_state of owner_block

type readiness_entry =
  { owner : owner
  ; readiness : readiness
  ; settled : unit Eio.Promise.t
  ; resolve_settled : unit Eio.Promise.u
  }

module Owner_map = Map.Make (String)

type registry_phase =
  | Discovery_required_state
  | Discovery_running_state
  | Discovery_failed_state of discovery_failure
  | Discovery_complete_state of owner_discovery_row list

type discovery_health_phase =
  | Health_discovery_required
  | Health_discovery_running
  | Health_discovery_failed
  | Health_discovery_complete

type owner_health_counts =
  { inspection_pending : int
  ; inspection_running : int
  ; reconciliation_pending : int
  ; reconciliation_running : int
  ; ready_without_obligation : int
  ; ready : int
  ; blocked : int
  }

type health_snapshot =
  { discovery_phase : discovery_health_phase
  ; discovery_row_count : int
  ; discovered_owner_count : int
  ; invalid_owner_name_count : int
  ; owners : owner_health_counts
  }

type registry =
  { core : Core.registry
  ; fs : Eio.Fs.dir_ty Eio.Path.t
  ; readiness_mutex : Eio.Mutex.t
  ; discovery_settled : unit Eio.Promise.t
  ; resolve_discovery_settled : unit Eio.Promise.u
  ; mutable registry_phase : registry_phase
  ; mutable readiness : readiness_entry Owner_map.t
  ; mutable health : health_snapshot
  }

type access_error = Keeper_lane_not_available

type lane_open_error =
  | Invalid_owner of Core.validation_error
  | Reconciliation_blocked of owner_block
  | Store_failed of Core.transition_error

type discovery_snapshot =
  | Snapshot_discovery_required
  | Snapshot_discovery_running
  | Snapshot_discovery_failed of discovery_failure
  | Snapshot_discovery_complete of owner_discovery_row list

type owner_activation_snapshot =
  | Snapshot_owner_inventory_pending of owner
  | Snapshot_owner_inventory_running of owner
  | Snapshot_owner_reconciliation_pending of owner
  | Snapshot_owner_reconciliation_running of owner
  | Snapshot_owner_ready_without_obligation of owner
  | Snapshot_owner_ready of owner * Reconciler.report
  | Snapshot_owner_blocked of owner * owner_block

type registry_snapshot =
  { discovery : discovery_snapshot
  ; owners : owner_activation_snapshot list
  }

type health_counter =
  | Discovery_row_counter
  | Discovered_owner_counter
  | Invalid_owner_name_counter
  | Inspection_pending_counter
  | Inspection_running_counter
  | Reconciliation_pending_counter
  | Reconciliation_running_counter
  | Ready_without_obligation_counter
  | Ready_counter
  | Blocked_counter

type health_counter_change =
  | Increment_health_counter
  | Decrement_health_counter

type invariant_violation =
  | Borrow_count_underflow
  | Borrow_count_overflow
  | Closing_without_active_borrows
  | Closed_with_active_borrows of int
  | Closed_without_drain_signal
  | Drain_signal_already_resolved
  | Discovery_settled_twice
  | Discovery_finished_outside_running
  | Owner_inventory_owner_not_running of string
  | Reconciliation_owner_not_running of string
  | Owner_generation_settled_twice of string
  | Owner_generation_settled_before_terminal of string
  | Health_counter_underflow of health_counter
  | Health_counter_overflow of health_counter
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

let owner_discovery_row_to_string = function
  | Discovered_owner owner ->
    Printf.sprintf "discovered_owner(%S)" (owner_to_string owner)
  | Invalid_owner_name name ->
    Printf.sprintf "invalid_owner_name(%S)" name
;;

let owner_inventory_row_to_string = function
  | Valid_owner owner ->
    Printf.sprintf "valid_owner(%S)" (owner_to_string owner)
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
  | Owner_inventory_cancelled { owner; reason; _ } ->
    Printf.sprintf
      "owner_inventory_cancelled(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string reason)
  | Owner_inventory_crashed { owner; exception_; _ } ->
    Printf.sprintf
      "owner_inventory_crashed(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string exception_)
;;

let discovery_failure_to_string = function
  | Registry_discovery_failed error ->
    Core.transition_error_to_string error
  | Registry_discovery_cancelled { reason; _ } ->
    Printf.sprintf
      "publication recovery registry discovery cancelled: %s"
      (Printexc.to_string reason)
  | Registry_discovery_crashed { exception_; _ } ->
    Printf.sprintf
      "publication recovery registry discovery crashed: %s"
      (Printexc.to_string exception_)
;;

let discovery_error_to_string = function
  | Registry_discovery_in_progress ->
    "publication recovery registry discovery is already in progress"
  | Registry_discovery_terminal failure ->
    discovery_failure_to_string failure
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
;;

let inspection_error_to_string = function
  | Inspection_owner_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inspection is already in progress for %S"
      (owner_to_string owner)
  | Inspection_owner_already_terminal block ->
    Printf.sprintf
      "publication recovery owner was already terminal before inspection: %s"
      (owner_block_to_string block)
;;

let reconciliation_error_to_string = function
  | Owner_inventory_pending owner ->
    Printf.sprintf
      "publication recovery owner inspection is required before reconciling owner %S"
      (owner_to_string owner)
  | Owner_inventory_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inspection is in progress before reconciling owner %S"
      (owner_to_string owner)
  | Owner_reconciliation_not_required owner ->
    Printf.sprintf
      "publication recovery owner %S has no recovery obligation"
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
;;

let lane_open_error_to_string = function
  | Invalid_owner error -> Core.validation_error_to_string error
  | Reconciliation_blocked block ->
    Printf.sprintf
      "publication recovery reconciliation blocks this owner: %s"
      (owner_block_to_string block)
  | Store_failed error -> Core.transition_error_to_string error
;;

let empty_owner_health_counts =
  { inspection_pending = 0
  ; inspection_running = 0
  ; reconciliation_pending = 0
  ; reconciliation_running = 0
  ; ready_without_obligation = 0
  ; ready = 0
  ; blocked = 0
  }
;;

let initial_health_snapshot =
  { discovery_phase = Health_discovery_required
  ; discovery_row_count = 0
  ; discovered_owner_count = 0
  ; invalid_owner_name_count = 0
  ; owners = empty_owner_health_counts
  }
;;

let change_counter ~counter ~change value =
  match change with
  | Increment_health_counter ->
    if value = Int.max_int
    then raise (Invariant_violation (Health_counter_overflow counter))
    else value + 1
  | Decrement_health_counter ->
    if value = 0
    then raise (Invariant_violation (Health_counter_underflow counter))
    else value - 1
;;

let change_readiness_count counts readiness change =
  match readiness with
  | Owner_inventory_pending_state ->
    { counts with
      inspection_pending =
        change_counter
          ~counter:Inspection_pending_counter
          ~change
          counts.inspection_pending
    }
  | Owner_inventory_running_state ->
    { counts with
      inspection_running =
        change_counter
          ~counter:Inspection_running_counter
          ~change
          counts.inspection_running
    }
  | Reconciliation_pending ->
    { counts with
      reconciliation_pending =
        change_counter
          ~counter:Reconciliation_pending_counter
          ~change
          counts.reconciliation_pending
    }
  | Reconciliation_running ->
    { counts with
      reconciliation_running =
        change_counter
          ~counter:Reconciliation_running_counter
          ~change
          counts.reconciliation_running
    }
  | No_recovery_obligation _ ->
    { counts with
      ready_without_obligation =
        change_counter
          ~counter:Ready_without_obligation_counter
          ~change
          counts.ready_without_obligation
    }
  | Reconciliation_ready _ ->
    { counts with
      ready =
        change_counter ~counter:Ready_counter ~change counts.ready
    }
  | Reconciliation_blocked_state _ ->
    { counts with
      blocked =
        change_counter ~counter:Blocked_counter ~change counts.blocked
    }
;;

let set_readiness_entry
    (registry : registry)
    key
    (entry : readiness_entry)
  =
  let counts =
    match Owner_map.find_opt key registry.readiness with
    | None -> registry.health.owners
    | Some previous ->
      change_readiness_count
        registry.health.owners
        previous.readiness
        Decrement_health_counter
  in
  registry.health <-
    { registry.health with
      owners =
        change_readiness_count
          counts
          entry.readiness
          Increment_health_counter
    };
  registry.readiness <- Owner_map.add key entry registry.readiness
;;

let open_registry ~sw ~fs ~registry_root =
  match Core.open_registry ~sw ~registry_root with
  | Error _ as error -> error
  | Ok core ->
    let discovery_settled, resolve_discovery_settled = Eio.Promise.create () in
    Ok
      { core
      ; fs
      ; readiness_mutex = Eio.Mutex.create ()
      ; discovery_settled
      ; resolve_discovery_settled
      ; registry_phase = Discovery_required_state
      ; readiness = Owner_map.empty
      ; health = initial_health_snapshot
      }
;;

let map_owner_discovery_row = function
  | Core.Discovered_owner owner -> Discovered_owner owner
  | Core.Invalid_owner_name name -> Invalid_owner_name name
;;

let map_owner_inspection owner = function
  | Core.Valid_owner -> Valid_owner owner
  | Core.Unexpected_owner_kind kind ->
    Unexpected_owner_kind { owner; kind }
  | Core.Missing_owner_entry -> Missing_owner_entry owner
  | Core.Owner_entry_unavailable error ->
    Owner_entry_unavailable { owner; error }
;;

let make_readiness_entry owner readiness =
  let settled, resolve_settled = Eio.Promise.create () in
  { owner; readiness; settled; resolve_settled }
;;

let settle_owner key resolve_settled =
  if not (Eio.Promise.try_resolve resolve_settled ())
  then
    raise
      (Invariant_violation (Owner_generation_settled_twice key))
;;

let settle_discovery registry =
  if not (Eio.Promise.try_resolve registry.resolve_discovery_settled ())
  then raise (Invariant_violation Discovery_settled_twice)
;;

type begin_discovery =
  | Begin_discovery
  | Existing_discovery of owner_discovery_row list
  | Discovery_already_running
  | Existing_discovery_failure of discovery_failure

let begin_discovery registry =
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match registry.registry_phase with
    | Discovery_required_state ->
      registry.registry_phase <- Discovery_running_state;
      registry.health <-
        { registry.health with discovery_phase = Health_discovery_running };
      Begin_discovery
    | Discovery_running_state -> Discovery_already_running
    | Discovery_failed_state failure -> Existing_discovery_failure failure
    | Discovery_complete_state rows -> Existing_discovery rows)
;;

let finish_discovery registry terminal =
  Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Discovery_running_state ->
        registry.registry_phase <- terminal;
        registry.health <-
          { registry.health with discovery_phase = Health_discovery_failed }
      | Discovery_required_state
      | Discovery_failed_state _
      | Discovery_complete_state _ ->
        raise (Invariant_violation Discovery_finished_outside_running));
    settle_discovery registry)
;;

let finish_discovery_success registry rows =
  let discovery_row_count, discovered_owner_count, invalid_owner_name_count =
    List.fold_left
      (fun (row_count, discovered, invalid) row ->
        let row_count =
          change_counter
            ~counter:Discovery_row_counter
            ~change:Increment_health_counter
            row_count
        in
        match row with
        | Discovered_owner _ ->
          ( row_count
          , change_counter
              ~counter:Discovered_owner_counter
              ~change:Increment_health_counter
              discovered
          , invalid )
        | Invalid_owner_name _ ->
          ( row_count
          , discovered
          , change_counter
              ~counter:Invalid_owner_name_counter
              ~change:Increment_health_counter
              invalid ))
      (0, 0, 0)
      rows
  in
  Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Discovery_running_state ->
        registry.registry_phase <- Discovery_complete_state rows;
        registry.health <-
          { registry.health with
            discovery_phase = Health_discovery_complete
          ; discovery_row_count
          ; discovered_owner_count
          ; invalid_owner_name_count
          }
      | Discovery_required_state
      | Discovery_failed_state _
      | Discovery_complete_state _ ->
        raise (Invariant_violation Discovery_finished_outside_running));
    settle_discovery registry)
;;

let finish_discovery_failure registry failure =
  finish_discovery registry (Discovery_failed_state failure)
;;

let discover_owners_with
    ~before_discovery
    ~before_terminalization
    registry
  =
  match begin_discovery registry with
  | Existing_discovery rows -> Ok rows
  | Discovery_already_running -> Error Registry_discovery_in_progress
  | Existing_discovery_failure failure ->
    Error (Registry_discovery_terminal failure)
  | Begin_discovery ->
    let observation =
      try
        before_discovery ();
        `Returned (Core.discover_owners registry.core)
      with
      | Eio.Cancel.Cancelled reason as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Cancelled (reason, cancellation, backtrace)
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Crashed (exception_, backtrace)
    in
    (match observation with
     | `Returned (Ok rows) ->
       let rows = List.map map_owner_discovery_row rows in
       before_terminalization ();
       finish_discovery_success registry rows;
       Eio.Fiber.check ();
       Ok rows
     | `Returned (Error error) ->
       let failure = Registry_discovery_failed error in
       before_terminalization ();
       finish_discovery_failure registry failure;
       Eio.Fiber.check ();
       Error (Registry_discovery_terminal failure)
     | `Cancelled (reason, cancellation, backtrace) ->
       let current_context_cancelled =
         match Eio.Fiber.check () with
         | () -> false
         | exception Eio.Cancel.Cancelled _ -> true
       in
       let failure = Registry_discovery_cancelled { reason; backtrace } in
       before_terminalization ();
       finish_discovery_failure registry failure;
       if current_context_cancelled
       then Printexc.raise_with_backtrace cancellation backtrace
       else (
         Eio.Fiber.check ();
         Error (Registry_discovery_terminal failure))
     | `Crashed (exception_, backtrace) ->
       let failure = Registry_discovery_crashed { exception_; backtrace } in
       before_terminalization ();
       finish_discovery_failure registry failure;
       Eio.Fiber.check ();
       Error (Registry_discovery_terminal failure))
;;

let discover_owners =
  discover_owners_with
    ~before_discovery:(fun () -> ())
    ~before_terminalization:(fun () -> ())
;;

type begin_owner_inspection =
  | Begin_owner_inspection
  | Existing_owner_inspection of owner_inventory_row
  | Begin_owner_inspection_failed of inspection_error

let begin_owner_inspection registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match Owner_map.find_opt key registry.readiness with
    | None ->
      set_readiness_entry
        registry
        key
        (make_readiness_entry owner Owner_inventory_running_state);
      Begin_owner_inspection
    | Some ({ readiness = Owner_inventory_pending_state; _ } as entry) ->
      set_readiness_entry
        registry
        key
        { entry with readiness = Owner_inventory_running_state };
      Begin_owner_inspection
    | Some { readiness = Owner_inventory_running_state; _ } ->
      Begin_owner_inspection_failed
        (Inspection_owner_in_progress owner)
    | Some { readiness = No_recovery_obligation row; _ } ->
      Existing_owner_inspection row
    | Some
        { readiness =
            ( Reconciliation_pending
            | Reconciliation_running
            | Reconciliation_ready _ )
        ; _
        } ->
      Existing_owner_inspection (Valid_owner owner)
    | Some { readiness = Reconciliation_blocked_state block; _ } ->
      (match block with
       | Owner_inventory_block row -> Existing_owner_inspection row
       | Owner_reconciliation_block _
       | Owner_reconciliation_crash _
       | Owner_reconciliation_cancelled_block _ ->
         Begin_owner_inspection_failed
           (Inspection_owner_already_terminal block)))
;;

let finish_owner_inspection registry owner ~replacement ~settle =
  let key = owner_to_string owner in
  Eio.Cancel.protect (fun () ->
    let resolve_settled =
      Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
        match Owner_map.find_opt key registry.readiness with
        | Some ({ readiness = Owner_inventory_running_state; _ } as entry) ->
          set_readiness_entry registry key { entry with readiness = replacement };
          Some entry.resolve_settled
        | None
        | Some
            { readiness =
                ( Owner_inventory_pending_state
                | No_recovery_obligation _
                | Reconciliation_pending
                | Reconciliation_running
                | Reconciliation_ready _
                | Reconciliation_blocked_state _ )
            ; _
            } ->
          raise
            (Invariant_violation
               (Owner_inventory_owner_not_running key)))
    in
    match settle, resolve_settled with
    | true, Some resolver -> settle_owner key resolver
    | false, Some _ -> ()
    | _, None ->
      raise (Invariant_violation (Owner_inventory_owner_not_running key)))
;;

let finish_owner_inspection_row registry owner row =
  match row with
  | Valid_owner _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:Reconciliation_pending
      ~settle:false
  | Missing_owner_entry _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:(No_recovery_obligation row)
      ~settle:true
  | Unexpected_owner_kind _
  | Owner_entry_unavailable _
  | Owner_inventory_cancelled _
  | Owner_inventory_crashed _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:
        (Reconciliation_blocked_state (Owner_inventory_block row))
      ~settle:true
;;

let reset_interrupted_owner_inspection registry owner =
  let key = owner_to_string owner in
  let old_resolver =
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match Owner_map.find_opt key registry.readiness with
      | Some ({ readiness = Owner_inventory_running_state; _ } as entry) ->
        set_readiness_entry
          registry
          key
          (make_readiness_entry owner Owner_inventory_pending_state);
        entry.resolve_settled
      | None
      | Some
          { readiness =
              ( Owner_inventory_pending_state
              | No_recovery_obligation _
              | Reconciliation_pending
              | Reconciliation_running
              | Reconciliation_ready _
              | Reconciliation_blocked_state _ )
          ; _
          } ->
        raise
          (Invariant_violation (Owner_inventory_owner_not_running key)))
  in
  settle_owner key old_resolver
;;

let inspect_owner_with
    ~before_inspection
    ~before_terminalization
    ~registry
    ~owner
  =
  match begin_owner_inspection registry owner with
  | Existing_owner_inspection row -> Ok row
  | Begin_owner_inspection_failed error -> Error error
  | Begin_owner_inspection ->
    let observation =
      try
        before_inspection ();
        `Returned
          (map_owner_inspection
             owner
             (Core.inspect_owner registry.core owner))
      with
      | Eio.Cancel.Cancelled reason as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Cancelled (reason, cancellation, backtrace)
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Crashed (exception_, backtrace)
    in
    (match observation with
     | `Returned row ->
       before_terminalization ();
       finish_owner_inspection_row registry owner row;
       Eio.Fiber.check ();
       Ok row
     | `Cancelled (reason, cancellation, backtrace) ->
       (match Eio.Fiber.check () with
        | () ->
         let row = Owner_inventory_cancelled { owner; reason; backtrace } in
          before_terminalization ();
          finish_owner_inspection_row registry owner row;
          Eio.Fiber.check ();
          Ok row
       | exception Eio.Cancel.Cancelled _ ->
          before_terminalization ();
          Eio.Cancel.protect (fun () ->
            reset_interrupted_owner_inspection registry owner);
          Printexc.raise_with_backtrace cancellation backtrace)
     | `Crashed (exception_, backtrace) ->
       let row = Owner_inventory_crashed { owner; exception_; backtrace } in
       before_terminalization ();
       finish_owner_inspection_row registry owner row;
       Eio.Fiber.check ();
       Ok row)
;;

let inspect_owner =
  inspect_owner_with
    ~before_inspection:(fun () -> ())
    ~before_terminalization:(fun () -> ())
;;

let snapshot_owner_activation ({ owner; readiness; _ } : readiness_entry) =
  match readiness with
  | Owner_inventory_pending_state -> Snapshot_owner_inventory_pending owner
  | Owner_inventory_running_state -> Snapshot_owner_inventory_running owner
  | No_recovery_obligation _ -> Snapshot_owner_ready_without_obligation owner
  | Reconciliation_pending -> Snapshot_owner_reconciliation_pending owner
  | Reconciliation_running -> Snapshot_owner_reconciliation_running owner
  | Reconciliation_ready report -> Snapshot_owner_ready (owner, report)
  | Reconciliation_blocked_state block ->
    Snapshot_owner_blocked (owner, block)
;;

let snapshot registry =
  let discovery, readiness =
    Eio.Mutex.use_ro registry.readiness_mutex (fun () ->
      let discovery =
        match registry.registry_phase with
        | Discovery_required_state -> Snapshot_discovery_required
        | Discovery_running_state -> Snapshot_discovery_running
        | Discovery_failed_state failure -> Snapshot_discovery_failed failure
        | Discovery_complete_state rows -> Snapshot_discovery_complete rows
      in
      discovery, registry.readiness)
  in
  { discovery
  ; owners =
      readiness
      |> Owner_map.bindings
      |> List.map (fun (_, entry) -> snapshot_owner_activation entry)
  }
;;

let health_snapshot registry =
  Eio.Mutex.use_ro registry.readiness_mutex (fun () -> registry.health)
;;

type begin_reconciliation =
  | Begin_reconciliation
  | Existing_report of Reconciler.report
  | Begin_reconciliation_failed of reconciliation_error

let begin_reconciliation registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
    match Owner_map.find_opt key registry.readiness with
       | None -> Begin_reconciliation_failed (Owner_inventory_pending owner)
       | Some { readiness = No_recovery_obligation _; _ } ->
         Begin_reconciliation_failed (Owner_reconciliation_not_required owner)
       | Some { readiness = Owner_inventory_pending_state; _ } ->
         Begin_reconciliation_failed (Owner_inventory_pending owner)
       | Some { readiness = Owner_inventory_running_state; _ } ->
      Begin_reconciliation_failed (Owner_inventory_in_progress owner)
       | Some ({ readiness = Reconciliation_pending; _ } as entry) ->
         set_readiness_entry
           registry
           key
           { entry with readiness = Reconciliation_running };
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
       )
;;

let finish_reconciliation_terminal registry owner terminal =
  let key = owner_to_string owner in
  Eio.Cancel.protect (fun () ->
    let resolve_settled =
      Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
        match Owner_map.find_opt key registry.readiness with
        | Some ({ readiness = Reconciliation_running; _ } as entry) ->
          set_readiness_entry registry key { entry with readiness = terminal };
          entry.resolve_settled
        | None
        | Some
            { readiness =
                ( Owner_inventory_pending_state
                | Owner_inventory_running_state
                | No_recovery_obligation _
                | Reconciliation_pending
                | Reconciliation_ready _
                | Reconciliation_blocked_state _ )
            ; _
            } ->
          raise
            (Invariant_violation
               (Reconciliation_owner_not_running key)))
    in
    settle_owner key resolve_settled)
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
  let old_resolver =
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      match Owner_map.find_opt key registry.readiness with
      | Some ({ readiness = Reconciliation_running; _ } as entry) ->
        set_readiness_entry
          registry
          key
          (make_readiness_entry owner Reconciliation_pending);
        entry.resolve_settled
      | None
      | Some
          { readiness =
              ( Owner_inventory_pending_state
              | Owner_inventory_running_state
              | No_recovery_obligation _
              | Reconciliation_pending
              | Reconciliation_ready _
              | Reconciliation_blocked_state _ )
          ; _
          } ->
        raise
          (Invariant_violation (Reconciliation_owner_not_running key)))
  in
  settle_owner key old_resolver
;;

let reconcile_owner_with
    ~reconcile
    ~before_terminalization
    ~registry
    ~owner
  =
  match begin_reconciliation registry owner with
  | Existing_report report -> Ok report
  | Begin_reconciliation_failed error -> Error error
  | Begin_reconciliation ->
    let observation =
      try
        `Report
          (reconcile ~fs:registry.fs ~registry:registry.core ~owner)
      with
      | Eio.Cancel.Cancelled reason as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Cancelled (reason, cancellation, backtrace)
      | exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        `Crashed (exception_, backtrace)
    in
    (match observation with
     | `Report report ->
       before_terminalization ();
       finish_reconciliation registry owner report;
       Eio.Fiber.check ();
       Ok report
     | `Cancelled (reason, cancellation, backtrace) ->
       let current_context_cancelled =
         match Eio.Fiber.check () with
         | () -> false
         | exception Eio.Cancel.Cancelled _ -> true
       in
       if current_context_cancelled
       then (
         before_terminalization ();
         Eio.Cancel.protect (fun () ->
           reset_interrupted_reconciliation registry owner);
         Printexc.raise_with_backtrace cancellation backtrace)
       else
         (match
            before_terminalization ();
            finish_reconciliation_cancelled
              registry
              owner
              reason
              backtrace
          with
          | () ->
            Eio.Fiber.check ();
            Error
              (Owner_reconciliation_cancelled
                 { owner; reason; backtrace })
          | exception terminalization_exception ->
            let terminalization_backtrace = Printexc.get_raw_backtrace () in
            Printexc.raise_with_backtrace
              (Reconciliation_cancellation_terminalization_failed
                 { cancellation = cancellation, backtrace
                 ; terminalization =
                     terminalization_exception, terminalization_backtrace
                 })
              terminalization_backtrace)
     | `Crashed (exception_, backtrace) ->
       (match
          before_terminalization ();
          finish_reconciliation_crash
            registry
            owner
            exception_
            backtrace
        with
        | () ->
          Eio.Fiber.check ();
          Error
            (Owner_reconciliation_crashed
               { owner; exception_; backtrace })
        | exception terminalization_exception ->
          let terminalization_backtrace = Printexc.get_raw_backtrace () in
          Printexc.raise_with_backtrace
            (Reconciliation_crash_terminalization_failed
               { reconciliation = exception_, backtrace
               ; terminalization =
                   terminalization_exception, terminalization_backtrace
               })
            terminalization_backtrace))
;;

let reconcile_owner =
  reconcile_owner_with
    ~reconcile:Reconciler.reconcile_owner
    ~before_terminalization:(fun () -> ())
;;

let report_owner = Reconciler.report_owner
let report_is_ready = Reconciler.report_is_ready
let report_to_yojson = Reconciler.report_to_yojson

type demand_decision =
  | Demand_ready
  | Demand_inspect_owner of owner
  | Demand_reconcile_owner of owner
  | Demand_wait_owner of unit Eio.Promise.t
  | Demand_blocked of owner_block

let demand_decision registry owner =
  let key = owner_to_string owner in
  Eio.Mutex.use_ro registry.readiness_mutex (fun () ->
    match Owner_map.find_opt key registry.readiness with
       | None -> Demand_inspect_owner owner
       | Some
           { readiness =
               (No_recovery_obligation _ | Reconciliation_ready _)
           ; _
           } ->
         Demand_ready
       | Some { readiness = Owner_inventory_pending_state; _ } ->
         Demand_inspect_owner owner
       | Some { readiness = Reconciliation_pending; _ } ->
         Demand_reconcile_owner owner
       | Some
           { readiness =
               (Owner_inventory_running_state | Reconciliation_running)
           ; settled
           ; _
           } ->
         Demand_wait_owner settled
       | Some { readiness = Reconciliation_blocked_state block; _ } ->
         Demand_blocked block)
;;

let ensure_owner_ready_with
    ~before_owner_settlement_wait
    ~after_owner_settlement
    ~registry
    ~owner
  =
  match Core.owner_of_string owner with
  | Error error -> Error (Invalid_owner error)
  | Ok owner ->
    let rec drive () =
      match demand_decision registry owner with
      | Demand_ready -> Ok ()
      | Demand_blocked block -> Error (Reconciliation_blocked block)
      | Demand_wait_owner settled ->
        before_owner_settlement_wait settled;
        Eio.Promise.await settled;
        after_owner_settlement settled;
        (match demand_decision registry owner with
         | Demand_wait_owner current when current == settled ->
           raise
             (Invariant_violation
                (Owner_generation_settled_before_terminal
                   (owner_to_string owner)))
         | Demand_wait_owner _ -> drive ()
         | Demand_ready
         | Demand_inspect_owner _
         | Demand_reconcile_owner _
         | Demand_blocked _ -> drive ())
      | Demand_inspect_owner owner ->
        (match inspect_owner ~registry ~owner with
         | Ok _ -> drive ()
         | Error (Inspection_owner_in_progress _) -> drive ()
         | Error (Inspection_owner_already_terminal block) ->
           Error (Reconciliation_blocked block))
      | Demand_reconcile_owner owner ->
        (match reconcile_owner ~registry ~owner with
         | Ok _ -> drive ()
         | Error
             ( Owner_inventory_pending _
             | Owner_inventory_in_progress _
             | Owner_reconciliation_in_progress _ ) -> drive ()
         | Error (Owner_reconciliation_not_required _) -> Ok ()
         | Error (Owner_inventory_prevents_reconciliation row) ->
           Error
             (Reconciliation_blocked (Owner_inventory_block row))
         | Error
             (Owner_reconciliation_crashed
               { owner; exception_; backtrace }) ->
           Error
             (Reconciliation_blocked
                (Owner_reconciliation_crash
                   { owner; exception_; backtrace }))
         | Error
             (Owner_reconciliation_cancelled
               { owner; reason; backtrace }) ->
           Error
             (Reconciliation_blocked
                (Owner_reconciliation_cancelled_block
                   { owner; reason; backtrace })))
    in
    drive ()
;;

let ensure_owner_ready =
  ensure_owner_ready_with
    ~before_owner_settlement_wait:(fun _ -> ())
    ~after_owner_settlement:(fun _ -> ())
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

let with_lane ~registry ~owner f =
  match ensure_owner_ready ~registry ~owner with
  | Error _ as error -> error
  | Ok () ->
    (match Core.owner_of_string owner with
     | Error error -> Error (Invalid_owner error)
     | Ok owner ->
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

  type discovery_phase =
    | Discovery_required
    | Discovery_running
    | Discovery_failed
    | Discovery_complete

  type discovery_settlement =
    | Discovery_unsettled
    | Discovery_settled

  let discover_owners ~before_discovery registry =
    discover_owners_with
      ~before_discovery
      ~before_terminalization:(fun () -> ())
      registry
  ;;

  let discover_owners_terminalization ~before_terminalization registry =
    discover_owners_with
      ~before_discovery:(fun () -> ())
      ~before_terminalization
      registry
  ;;

  let inspect_owner ~before_inspection ~registry ~owner =
    inspect_owner_with
      ~before_inspection
      ~before_terminalization:(fun () -> ())
      ~registry
      ~owner
  ;;

  let inspect_owner_terminalization
      ~before_terminalization
      ~registry
      ~owner
    =
    inspect_owner_with
      ~before_inspection:(fun () -> ())
      ~before_terminalization
      ~registry
      ~owner
  ;;

  let observed_failure (exception_, backtrace) =
    { exception_; backtrace }
  ;;

  let interrupt_reconciliation ~registry ~owner interruption =
    let reconcile ~fs:_ ~registry:_ ~owner:_ =
      match interruption with
      | Cancel_reconciliation reason ->
        raise (Eio.Cancel.Cancelled reason)
      | Crash_reconciliation exception_ -> raise exception_
    in
    reconcile_owner_with
      ~reconcile
      ~before_terminalization:(fun () -> ())
      ~registry
      ~owner
  ;;

  let reconcile_owner ~before_reconciliation ~registry ~owner =
    reconcile_owner_with
      ~reconcile:(fun ~fs ~registry ~owner ->
        before_reconciliation ();
        Reconciler.reconcile_owner ~fs ~registry ~owner)
      ~before_terminalization:(fun () -> ())
      ~registry
      ~owner
  ;;

  let reconcile_owner_terminalization
      ~before_terminalization
      ~registry
      ~owner
    =
    reconcile_owner_with
      ~reconcile:Reconciler.reconcile_owner
      ~before_terminalization
      ~registry
      ~owner
  ;;

  let with_readiness_lock registry callback =
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex callback
  ;;

  let ensure_owner_ready
      ~before_owner_settlement_wait
      ~after_owner_settlement
      ~registry
      ~owner
    =
    ensure_owner_ready_with
      ~before_owner_settlement_wait
      ~after_owner_settlement
      ~registry
      ~owner
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
      match Owner_map.find_opt key registry.readiness with
      | None -> Owner_untracked
      | Some { settled; _ } ->
        (match Eio.Promise.peek settled with
         | None -> Owner_unsettled
         | Some () -> Owner_settled))
  ;;

  let discovery_phase registry =
    Eio.Mutex.use_ro registry.readiness_mutex (fun () ->
      match registry.registry_phase with
      | Discovery_required_state -> Discovery_required
      | Discovery_running_state -> Discovery_running
      | Discovery_failed_state _ -> Discovery_failed
      | Discovery_complete_state _ -> Discovery_complete)
  ;;

  let discovery_settlement registry =
    match Eio.Promise.peek registry.discovery_settled with
    | None -> Discovery_unsettled
    | Some () -> Discovery_settled
  ;;

  let await_discovery_settlement registry =
    Eio.Promise.await registry.discovery_settled
  ;;

  let snapshot registry = snapshot registry

  let health_counter_transition ~counter ~change ~value =
    match change_counter ~counter ~change value with
    | updated -> Ok updated
    | exception Invariant_violation invariant -> Error invariant
  ;;
end
