open Keeper_shutdown_types

type request =
  { actor : string
  ; cleanup_intent : cleanup_intent
  }

type error =
  | Registry_lane_replaced
  | Dormant_registry_lane_present
  | Existing_operation of Operation_id.t
  | Meta_snapshot_missing
  | Meta_snapshot_identity_changed
  | Meta_snapshot_version_changed of
      { expected : int
      ; actual : int
      }
  | Meta_snapshot_read_failed of string
  | Task_discovery_failed of string
  | Prepare_persist_failed of Keeper_shutdown_store.error
  | Cancellation_failed of Keeper_shutdown_types.t
  | Join_failed of Keeper_shutdown_types.t
  | Join_record_update_failed of Keeper_shutdown_store.error

let error_to_string = function
  | Registry_lane_replaced -> "Keeper registry lane changed before shutdown prepare"
  | Dormant_registry_lane_present ->
    "dormant Keeper gained a registered lane before shutdown prepare"
  | Existing_operation operation_id ->
    Printf.sprintf
      "Keeper shutdown already reserved by operation %s"
      (Operation_id.to_string operation_id)
  | Meta_snapshot_missing -> "Keeper shutdown metadata is absent"
  | Meta_snapshot_identity_changed ->
    "Keeper shutdown metadata identity changed before durable prepare"
  | Meta_snapshot_version_changed { expected; actual } ->
    Printf.sprintf
      "Keeper shutdown metadata version changed before durable prepare: expected %d, actual %d"
      expected
      actual
  | Meta_snapshot_read_failed detail ->
    Printf.sprintf "Keeper shutdown metadata read failed: %s" detail
  | Task_discovery_failed detail ->
    Printf.sprintf "Keeper shutdown task discovery failed: %s" detail
  | Prepare_persist_failed error -> Keeper_shutdown_store.error_to_string error
  | Cancellation_failed operation ->
    Printf.sprintf
      "Keeper shutdown cancellation blocked in operation %s"
      (Operation_id.to_string operation.operation_id)
  | Join_failed operation ->
    Printf.sprintf
      "Keeper shutdown join blocked in operation %s"
      (Operation_id.to_string operation.operation_id)
  | Join_record_update_failed error -> Keeper_shutdown_store.error_to_string error
;;

let same_lane left right =
  Keeper_lane.Id.equal
    (Keeper_lane.id left.Keeper_registry.lane)
    (Keeper_lane.id right.Keeper_registry.lane)
;;

let current_entry ~config (observed : Keeper_registry.registry_entry) =
  match Keeper_registry.get ~base_path:config.Workspace.base_path observed.name with
  | Some current when same_lane current observed -> Ok current
  | Some _ | None -> Error Registry_lane_replaced
;;

let admission_lane = function
  | Keeper_turn_admission.Autonomous -> Autonomous
  | Keeper_turn_admission.Chat -> Chat
;;

let active_turn_of_snapshots reservation current =
  let observation : Keeper_registry.turn_observation option =
    current.Keeper_registry.current_turn_observation
  in
  match reservation.Keeper_turn_admission.in_flight, observation with
  | None, None -> No_inflight_turn
  | in_flight, observation ->
    let lane, admitted_at =
      match in_flight with
      | Some info -> Some (admission_lane info.lane), Some info.started_at
      | None -> None, None
    in
    Inflight_effect_unknown
      { lane
      ; admitted_at
      ; observed_turn_id =
          Option.map
            (fun (obs : Keeper_registry.turn_observation) -> obs.turn_id)
            observation
      ; observation_started_at =
          Option.map
            (fun (obs : Keeper_registry.turn_observation) -> obs.started_at)
            observation
      }
;;

let rollback_reservation ~config ~keeper_name operation_id =
  match
    Keeper_turn_admission.rollback_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~operation_id
  with
  | Keeper_turn_admission.Shutdown_rolled_back
  | Keeper_turn_admission.Shutdown_not_reserved -> ()
  | Keeper_turn_admission.Shutdown_reserved_by_other existing ->
    Log.Keeper.error
      "%s: shutdown rollback for %s found reservation %s"
      keeper_name
      (Operation_id.to_string operation_id)
      (Operation_id.to_string existing)
;;

let validate_cleanup_reason reason (meta : Keeper_meta_contract.keeper_meta) =
  match reason with
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup -> Ok ()
  | Dashboard_keeper_purge context ->
    if Int.equal meta.meta_version context.meta_version
    then Ok ()
    else
      Error
        (Meta_snapshot_version_changed
           { expected = context.meta_version; actual = meta.meta_version })
;;

let read_guarded_meta
    ~config
    ~(observed : Keeper_meta_contract.keeper_meta)
    ~cleanup_reason
  =
  match Keeper_meta_store.read_meta config observed.name with
  | Error detail -> Error (Meta_snapshot_read_failed detail)
  | Ok None -> Error Meta_snapshot_missing
  | Ok (Some latest)
    when not
           (Keeper_id.Trace_id.equal
              latest.runtime.trace_id
              observed.runtime.trace_id)
         || not
              (Int.equal
                 latest.runtime.generation
                 observed.runtime.generation) ->
    Error Meta_snapshot_identity_changed
  | Ok (Some latest) ->
    (match validate_cleanup_reason cleanup_reason latest with
     | Error _ as error -> error
     | Ok () -> Ok latest)
;;

let persist_blocked ~config operation stage detail =
  let blocked =
    { operation with
      revision = operation.revision + 1
    ; phase = Blocked { stage; detail }
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  match
    Keeper_shutdown_store.replace
      ~config
      ~expected_revision:operation.revision
      blocked
  with
  | Ok () -> Ok blocked
  | Error error -> Error error
;;

let cancellation_error ~config operation stage detail =
  match persist_blocked ~config operation stage detail with
  | Ok blocked -> Error (Cancellation_failed blocked)
  | Error error -> Error (Join_record_update_failed error)
;;

let lane_outcome = function
  | Keeper_lane.Completed -> Lane_completed
  | Keeper_lane.Shutdown_before_start -> Lane_shutdown_requested
  | Keeper_lane.Shutdown_requested -> Lane_shutdown_requested
  | Keeper_lane.Shutdown_cancel_failed failure ->
    Lane_failed (Printexc.to_string failure.cause)
  | Keeper_lane.Cancelled_by_parent exn ->
    Lane_cancelled_by_parent (Printexc.to_string exn)
  | Keeper_lane.Failed exn -> Lane_failed (Printexc.to_string exn)
;;

let terminal = function
  | `Stopped -> Terminal_stopped
  | `Crashed detail -> Terminal_crashed detail
;;

let prepare ~config ~(entry : Keeper_registry.registry_entry) ~request =
  let operation_id = Operation_id.generate () in
  match
    Keeper_turn_admission.begin_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name:entry.name
      ~operation_id
  with
  | Keeper_turn_admission.Shutdown_already_reserved reservation ->
    Error (Existing_operation reservation.operation_id)
  | Keeper_turn_admission.Shutdown_reserved reservation ->
    let durable_prepare_committed = Atomic.make false in
    Fun.protect
      ~finally:(fun () ->
        if not (Atomic.get durable_prepare_committed)
        then rollback_reservation ~config ~keeper_name:entry.name operation_id)
      (fun () ->
         match current_entry ~config entry with
         | Error error -> Error error
         | Ok current ->
           (match
              read_guarded_meta
                ~config
                ~observed:current.meta
                ~cleanup_reason:request.cleanup_intent.reason
            with
            | Error _ as error -> error
            | Ok durable_meta ->
              (match
                 Keeper_current_task_reconcile.owned_active_tasks_snapshot_for_meta_strict
                   ~config
                   ~meta:durable_meta
               with
               | Error detail -> Error (Task_discovery_failed detail)
               | Ok owned_snapshot ->
                 let owned_tasks = owned_snapshot.tasks in
                 let now = Masc_domain.now_iso () in
                 let turn_disposition = active_turn_of_snapshots reservation current in
                 let operation =
                   { schema_version
                   ; revision = 0
                   ; operation_id
                   ; keeper_name = current.name
                   ; lane_ownership = Registered_lane (Keeper_lane.id current.lane)
                   ; trace_id = durable_meta.runtime.trace_id
                   ; generation = durable_meta.runtime.generation
                   ; actor = request.actor
                   ; cleanup_intent = request.cleanup_intent
                   ; turn_disposition
                   ; expected_backlog_version = owned_snapshot.backlog_version
                   ; owned_task_ids =
                       List.map
                         (fun task -> task.Keeper_current_task_reconcile.task_id)
                         owned_tasks
                   ; join_evidence = None
                   ; phase = Prepared
                   ; created_at = now
                   ; updated_at = now
                   }
                 in
                 let persist_result =
                   Eio.Cancel.protect (fun () ->
                     match Keeper_shutdown_store.persist_new ~config operation with
                     | Ok () as committed ->
                       Atomic.set durable_prepare_committed true;
                       committed
                     | Error _ as error -> error)
                 in
                 (match persist_result with
                  | Error store_error -> Error (Prepare_persist_failed store_error)
                  | Ok () -> Ok operation))))
;;

let prepare_dormant
    ~config
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~request
  =
  let operation_id = Operation_id.generate () in
  match
    Keeper_turn_admission.begin_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name:meta.name
      ~operation_id
  with
  | Keeper_turn_admission.Shutdown_already_reserved reservation ->
    Error (Existing_operation reservation.operation_id)
  | Keeper_turn_admission.Shutdown_reserved _ ->
    let durable_prepare_committed = Atomic.make false in
    Fun.protect
      ~finally:(fun () ->
        if not (Atomic.get durable_prepare_committed)
        then rollback_reservation ~config ~keeper_name:meta.name operation_id)
      (fun () ->
         match Keeper_registry.get ~base_path:config.base_path meta.name with
         | Some _ -> Error Dormant_registry_lane_present
         | None ->
           (match
              read_guarded_meta
                ~config
                ~observed:meta
                ~cleanup_reason:request.cleanup_intent.reason
            with
            | Error _ as error -> error
            | Ok durable_meta ->
              (match
                 Keeper_current_task_reconcile.owned_active_tasks_snapshot_for_meta_strict
                   ~config
                   ~meta:durable_meta
               with
               | Error detail -> Error (Task_discovery_failed detail)
               | Ok owned_snapshot ->
                 let now = Masc_domain.now_iso () in
                 let operation =
                   { schema_version
                   ; revision = 0
                   ; operation_id
                   ; keeper_name = durable_meta.name
                   ; lane_ownership = Dormant_meta
                   ; trace_id = durable_meta.runtime.trace_id
                   ; generation = durable_meta.runtime.generation
                   ; actor = request.actor
                   ; cleanup_intent = request.cleanup_intent
                   ; turn_disposition = No_inflight_turn
                   ; expected_backlog_version = owned_snapshot.backlog_version
                   ; owned_task_ids =
                       List.map
                         (fun task -> task.Keeper_current_task_reconcile.task_id)
                         owned_snapshot.tasks
                   ; join_evidence = None
                   ; phase = Joined_idle
                   ; created_at = now
                   ; updated_at = now
                   }
                 in
                 let persist_result =
                   Eio.Cancel.protect (fun () ->
                     match Keeper_shutdown_store.persist_new ~config operation with
                     | Ok () as committed ->
                       Atomic.set durable_prepare_committed true;
                       committed
                     | Error _ as error -> error)
                 in
                 (match persist_result with
                  | Error store_error ->
                    Error (Prepare_persist_failed store_error)
                  | Ok () -> Ok operation))))
;;

let join_prepared ~config ~(entry : Keeper_registry.registry_entry) ~operation =
  match current_entry ~config entry with
  | Error error -> Error error
  | Ok current
    when not
           (match operation.lane_ownership with
            | Registered_lane lane_id ->
              Keeper_lane.Id.equal (Keeper_lane.id current.lane) lane_id
            | Dormant_meta -> false) -> Error Registry_lane_replaced
  | Ok current ->
    Keeper_keepalive.request_entry_stop current;
    let turn_cancel = Keeper_registry.interrupt_current_turn_exact current in
    let turn_cancel_error =
      match operation.turn_disposition, turn_cancel with
      | No_inflight_turn, Keeper_registry.Exact_no_turn_in_flight
      | Inflight_effect_unknown _, Keeper_registry.Exact_turn_cancelled _ -> None
      | No_inflight_turn, Keeper_registry.Exact_turn_cancelled _ ->
        Some "turn appeared after shutdown admission was fenced"
      | Inflight_effect_unknown _, Keeper_registry.Exact_no_turn_in_flight -> None
      | _, Keeper_registry.Exact_turn_cancel_failed { detail; _ } -> Some detail
    in
    (match turn_cancel_error with
     | Some detail -> cancellation_error ~config operation Turn_cancel detail
     | None ->
       (match Keeper_lane.request_cancel current.lane with
        | Keeper_lane.Cancel_not_committed exn
        | Keeper_lane.Cancel_committed_with_failure exn ->
          cancellation_error ~config operation Lane_cancel (Printexc.to_string exn)
        | Keeper_lane.Cancel_wrong_domain ->
          cancellation_error
            ~config
            operation
            Lane_cancel
            "lane cancellation requested from a non-owning domain"
        | Keeper_lane.Cancel_requested
        | Keeper_lane.Cancel_already_requested
        | Keeper_lane.Cancel_already_exiting ->
          Keeper_turn_admission.await_idle_after_shutdown
            ~base_path:config.Workspace.base_path
            ~keeper_name:current.name;
          let lane_exit = Keeper_lane.await_exit current.lane in
          (match lane_exit.outcome with
           | Keeper_lane.Shutdown_before_start ->
             (match
                Keeper_registry.resolve_done
                  current
                  ~source:"shutdown_before_lane_start"
                  `Stopped
              with
              | Keeper_registry.Done_resolved _
              | Keeper_registry.Done_already_resolved { previous = `Stopped; _ } -> ()
              | Keeper_registry.Done_already_resolved
                  { previous = `Crashed detail; _ } ->
                Log.Keeper.warn
                  "%s: shutdown before lane start preserved prior crash terminal: %s"
                  current.name
                  detail)
           | Keeper_lane.Completed
           | Keeper_lane.Shutdown_requested
           | Keeper_lane.Shutdown_cancel_failed _
           | Keeper_lane.Cancelled_by_parent _
           | Keeper_lane.Failed _ -> ());
          let terminal_result = Eio.Promise.await current.done_p in
          let evidence =
            { lane_outcome = lane_outcome lane_exit.outcome
            ; terminal = terminal terminal_result
            ; cleanup_error = lane_exit.cleanup_error
            }
          in
          let phase =
            match operation.turn_disposition with
            | No_inflight_turn -> Joined_idle
            | Inflight_effect_unknown turn -> Reconciliation_required turn
          in
          let joined =
            { operation with
              revision = operation.revision + 1
            ; join_evidence = Some evidence
            ; phase
            ; updated_at = Masc_domain.now_iso ()
            }
          in
          (match lane_exit.cleanup_error with
           | Some detail ->
             let blocked =
               { joined with
                 phase = Blocked { stage = Lane_join; detail }
               ; updated_at = Masc_domain.now_iso ()
               }
             in
             (match
                Keeper_shutdown_store.replace
                  ~config
                  ~expected_revision:operation.revision
                  blocked
              with
              | Ok () -> Error (Join_failed blocked)
              | Error error -> Error (Join_record_update_failed error))
           | None ->
             (match
                Keeper_shutdown_store.replace
                  ~config
                  ~expected_revision:operation.revision
                  joined
              with
              | Ok () -> Ok joined
              | Error error -> Error (Join_record_update_failed error)))))
;;

let run ~config ~entry ~request =
  match prepare ~config ~entry ~request with
  | Error _ as error -> error
  | Ok operation -> join_prepared ~config ~entry ~operation
;;
