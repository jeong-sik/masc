(* Three modules are included here. [Publication_recovery_access_model] is the
   vocabulary of this module, [Publication_recovery_access_text] the text form
   of its rows and errors, and [Publication_recovery_access_lease] the lease on
   the store of one lane. *)
include Publication_recovery_access_model
include Publication_recovery_access_text
include Publication_recovery_access_lease

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
  ; retryable_lane_failure_count = 0
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

let lane_failure_count_after_transition
      ~previous
      ~next
      count
  =
  match previous, next with
  | None, None
  | Some _, Some _ -> count
  | None, Some _ ->
    change_counter
      ~counter:Retryable_lane_failure_counter
      ~change:Increment_health_counter
      count
  | Some _, None ->
    change_counter
      ~counter:Retryable_lane_failure_counter
      ~change:Decrement_health_counter
      count
;;

let set_lane_store_failure registry key failure =
  Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
      let previous =
        Owner_map.find_opt key registry.lane_store_failures
      in
      let retryable_lane_failure_count =
        lane_failure_count_after_transition
          ~previous
          ~next:failure
          registry.health.retryable_lane_failure_count
      in
      registry.lane_store_failures <-
        (match failure with
         | None -> Owner_map.remove key registry.lane_store_failures
         | Some failure ->
           Owner_map.add key failure registry.lane_store_failures);
      registry.health <-
        { registry.health with retryable_lane_failure_count }))
;;

let from_core ~fs result =
  match result with
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
      ; lane_store_failures = Owner_map.empty
      ; health = initial_health_snapshot
      }
;;

let open_registry ~sw ~fs ~registry_root =
  from_core ~fs (Core.open_registry ~sw ~registry_root)
;;

let open_namespaced_registry ~sw ~fs ~registry_root ~namespace =
  from_core ~fs (Core.open_namespaced_registry ~sw ~registry_root ~namespace)
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

let finish_owner_inspection
    registry
    owner
    ~replacement
    ~start_new_generation
  =
  let key = owner_to_string owner in
  Eio.Cancel.protect (fun () ->
    let resolve_settled =
      Eio.Mutex.use_rw ~protect:true registry.readiness_mutex (fun () ->
        match Owner_map.find_opt key registry.readiness with
        | Some ({ readiness = Owner_inventory_running_state; _ } as entry) ->
          let replacement_entry =
            if start_new_generation
            then make_readiness_entry owner replacement
            else { entry with readiness = replacement }
          in
          set_readiness_entry registry key replacement_entry;
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
            (Invariant_violation
               (Owner_inventory_owner_not_running key)))
    in
    settle_owner key resolve_settled)
;;

let finish_owner_inspection_row registry owner row =
  match row with
  | Valid_owner _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:Reconciliation_pending
      ~start_new_generation:true
  | Missing_owner_entry _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:(No_recovery_obligation row)
      ~start_new_generation:false
  | Unexpected_owner_kind _
  | Owner_entry_unavailable _
  | Owner_inventory_cancelled _
  | Owner_inventory_crashed _ ->
    finish_owner_inspection
      registry
      owner
      ~replacement:
        (Reconciliation_blocked_state (Owner_inventory_block row))
      ~start_new_generation:false
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
          | exception terminalization_exception -> (* cancel-guard-ok: the scrutinee cannot raise Cancelled -- the hook is (fun () -> ()) on every production path and finish_reconciliation_terminal's body is wholly Eio.Cancel.protect *)
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
        | exception terminalization_exception -> (* cancel-guard-ok: same as the cancellation arm above -- the hook cannot raise in production and finish_reconciliation_terminal runs under Eio.Cancel.protect *)
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

let with_lane ~registry ~owner f =
  match ensure_owner_ready ~registry ~owner with
  | Error _ as error -> error
  | Ok () ->
    (match Core.owner_of_string owner with
     | Error error -> Error (Invalid_owner error)
     | Ok owner ->
       let key = owner_to_string owner in
       (match
          Core.with_store
            ~registry:registry.core
            ~owner
            ~on_release_failure:(fun release_failure ->
              set_lane_store_failure
                registry
                key
                (Some (Lane_store_release_failed release_failure)))
            (fun store ->
            set_lane_store_failure registry key None;
            let access = create store in
            run_with_cleanup
              ~cleanup:(fun () -> close_and_drain access)
              (fun () -> f access))
        with
        | Ok (Core.Store_scope_released value) ->
          Ok (Lane_released value)
        | Ok
            (Core.Store_scope_release_failed
              { value; release_failure }) ->
          Ok (Lane_release_failed { value; release_failure })
        | Error error ->
          set_lane_store_failure
            registry
            key
            (Some (Lane_store_open_failed error));
          Error (Store_failed error)))
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

  let with_core_store ~registry ~owner f =
    match Core.owner_of_string owner with
    | Error error -> Error (Invalid_owner error)
    | Ok owner ->
      (match
         Core.with_store
           ~registry:registry.core
           ~owner
           ~on_release_failure:(fun _ -> ())
           f
       with
       | Ok (Core.Store_scope_released value) -> Ok value
       | Ok (Core.Store_scope_release_failed { release_failure; _ }) ->
         Error
           (Store_failed
              { Core.store_effect = Core.No_record_change
              ; failure = release_failure.failure
              ; cleanup_failures = []
              })
       | Error error -> Error (Store_failed error))
  ;;

  let record_lane_store_open_failure
        ~registry
        ~owner
        ~exception_
        ~backtrace
    =
    match Core.owner_of_string owner with
    | Error _ as error -> error
    | Ok owner ->
      let key = owner_to_string owner in
      let failure =
        { Core.store_effect = Core.No_record_change
        ; failure =
            { operation = Core.Open_directory
            ; subject = Core.Lane_root owner
            ; cause = Core.Io_failed { exception_; backtrace }
            }
        ; cleanup_failures = []
        }
      in
      set_lane_store_failure
        registry
        key
        (Some (Lane_store_open_failed failure));
      Ok ()
  ;;

  let record_lane_store_open_success ~registry ~owner =
    match Core.owner_of_string owner with
    | Error _ as error -> error
    | Ok owner ->
      let key = owner_to_string owner in
      set_lane_store_failure registry key None;
      Ok ()
  ;;

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
    with_core_store ~registry ~owner @@ fun store ->
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
       (* [release] takes a mutex, and waiting for one is a cancellation point
          even with [~protect:true], which covers only the critical section
          (eio_mutex.mli:30). Recording that cancellation as evidence would
          hand the probe's caller a verdict and let it keep asserting after
          its own fiber was cancelled. No consumer asserts on a cancellation:
          both turn [Single_borrow_raised] into a failure message. *)
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
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
