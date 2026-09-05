open Keeper_shutdown_types

module String_map = Map.Make (String)

type submit_error =
  | Prepare_error of Keeper_shutdown_prepare_join.error
  | Existing_operation_load_error of Keeper_shutdown_store.error
  | Existing_operation_lane_mismatch of Keeper_shutdown_types.t
  | Existing_operation_intent_mismatch of Keeper_shutdown_types.t
  | Worker_start_error of worker_start_error

and worker_start_error =
  | Worker_supervisor_unavailable
  | Worker_supervisor_stopping of exn
  | Worker_fork_failed of exn

type restored_inventory =
  { operations : Keeper_shutdown_types.t list
  ; blocked_keeper_names : string list
  ; corrupt_records : Keeper_shutdown_store.corrupt_record list
  ; corrupt_owner_fences : corrupt_owner_fence list
  }

and corrupt_owner_fence =
  { keeper_name : string
  ; operation_id : Operation_id.t
  }

let submit_error_to_string = function
  | Prepare_error error -> Keeper_shutdown_prepare_join.error_to_string error
  | Existing_operation_load_error error -> Keeper_shutdown_store.error_to_string error
  | Existing_operation_lane_mismatch operation ->
    Printf.sprintf
      "existing shutdown operation has incompatible lane ownership: keeper=%s operation=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
  | Existing_operation_intent_mismatch operation ->
    Printf.sprintf
      "existing shutdown operation has incompatible cleanup intent: keeper=%s operation=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
  | Worker_start_error Worker_supervisor_unavailable ->
    "Keeper shutdown process supervisor is unavailable"
  | Worker_start_error (Worker_supervisor_stopping exn) ->
    Printf.sprintf "Keeper shutdown process supervisor is stopping: %s" (Printexc.to_string exn)
  | Worker_start_error (Worker_fork_failed exn) ->
    Printf.sprintf "Keeper shutdown worker fork failed: %s" (Printexc.to_string exn)
;;

let operation_requires_fence (operation : Keeper_shutdown_types.t) =
  Keeper_shutdown_types.requires_admission_fence operation
;;

type ownerless_restore_policy =
  | Require_removal_evidence of Keeper_shutdown_types.t
  | Restore_corrupt_fence

let restore_admission ~config ~ownerless_policy ~keeper_name ~operation_id =
  match
    Keeper_owner_registry.restore_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~operation_id
  with
  | Ok Keeper_owner.Shutdown_restored
  | Ok Keeper_owner.Shutdown_already_restored -> Ok ()
  | Ok (Keeper_owner.Shutdown_restore_conflict existing) ->
    Error
      (Printf.sprintf
         "shutdown admission restore conflict: keeper=%s durable=%s existing=%s"
         keeper_name
         (Operation_id.to_string operation_id)
         (Operation_id.to_string existing))
  | Error
      (Keeper_owner_registry.Command_lookup_failed
         (Keeper_owner_registry.Owner_not_found _) as error) ->
    let may_restore_ownerless =
      match ownerless_policy with
      | Restore_corrupt_fence -> true
      | Require_removal_evidence operation ->
        Keeper_shutdown_finalize.admission_already_released_by_removal
          ~config
          operation
          error
    in
    if not may_restore_ownerless
    then Error (Keeper_owner_registry.command_error_to_string error)
    else
      (* [complete_cleanup] can remove both metadata and its Owner before a
         remove-meta cleanup or pending completion is settled. The Owner-local
         fence is gone in that state, but the independent intake fence must
         remain until recovery reaches a durable non-fenced phase. Corrupt
         records also remain fail-closed without readable intent evidence. *)
      (match
         Keeper_shutdown_intake_fence.restore_shutdown
           ~base_path:config.Workspace.base_path
           ~keeper_name
           ~operation_id
       with
       | Keeper_shutdown_intake_fence.Restored
       | Keeper_shutdown_intake_fence.Already_restored ->
         Log.Keeper.info
           "restored ownerless shutdown intake fence: keeper=%s operation=%s"
           keeper_name
           (Operation_id.to_string operation_id);
         Ok ()
       | Keeper_shutdown_intake_fence.Restore_conflict existing ->
         Error
           (Printf.sprintf
              "shutdown admission restore conflict: keeper=%s durable=%s existing=%s"
              keeper_name
              (Operation_id.to_string operation_id)
              (Operation_id.to_string existing)))
  | Error error -> Error (Keeper_owner_registry.command_error_to_string error)
;;

let restore_inventory_admission ~config inventory =
  let corrupt_fences =
    Keeper_shutdown_store.canonical_corrupt_operation_ids inventory
    |> List.fold_left
         (fun fences (keeper_name, operation_id) ->
            String_map.add keeper_name operation_id fences)
         String_map.empty
  in
  let corrupt_records =
    List.filter_map
      (function
        | Keeper_shutdown_store.Operation _ -> None
        | Keeper_shutdown_store.Corrupt_record corrupt -> Some corrupt)
      inventory
  in
  let current_fences_result =
    List.fold_left
      (fun fences -> function
         | Keeper_shutdown_store.Corrupt_record _ -> fences
         | Keeper_shutdown_store.Operation operation
           when operation_requires_fence operation ->
           (match fences with
            | Error _ as error -> error
            | Ok fences ->
              (match String_map.find_opt operation.keeper_name fences with
               | None ->
                 Ok
                   (String_map.add
                      operation.keeper_name
                      operation
                      fences)
               | Some existing
                 when Operation_id.equal
                        existing.operation_id
                        operation.operation_id ->
                 Ok fences
               | Some existing ->
                 Error
                   (Printf.sprintf
                      "multiple current shutdown admission owners: keeper=%s first=%s second=%s"
                      operation.keeper_name
                      (Operation_id.to_string existing.operation_id)
                      (Operation_id.to_string operation.operation_id))))
         | Keeper_shutdown_store.Operation _ -> fences)
      (Ok String_map.empty)
      inventory
  in
  match current_fences_result with
  | Error _ as error -> error
  | Ok current_fences ->
    let corrupt_owner_fences =
      String_map.bindings corrupt_fences
      |> List.map (fun (keeper_name, operation_id) -> { keeper_name; operation_id })
    in
    let rec restore_corrupt_fences blocked = function
      | [] -> Ok blocked
      | { keeper_name; operation_id } :: rest ->
        let operation_id, ownerless_policy =
          match String_map.find_opt keeper_name current_fences with
          | Some current ->
            current.operation_id, Require_removal_evidence current
          | None -> operation_id, Restore_corrupt_fence
        in
        (match
           restore_admission
             ~config
             ~ownerless_policy
             ~keeper_name
             ~operation_id
         with
         | Error _ as error -> error
         | Ok () -> restore_corrupt_fences (keeper_name :: blocked) rest)
    in
    let rec loop operations blocked = function
      | [] ->
        Ok
          { operations = List.rev operations
          ; blocked_keeper_names = List.sort_uniq String.compare blocked
          ; corrupt_records
          ; corrupt_owner_fences
          }
      | Keeper_shutdown_store.Operation operation :: rest ->
        if String_map.mem operation.keeper_name corrupt_fences
        then
          if operation_requires_fence operation
          then loop (operation :: operations) blocked rest
          else loop operations blocked rest
        else if operation_requires_fence operation
        then
          (match
             restore_admission
               ~config
               ~ownerless_policy:(Require_removal_evidence operation)
               ~keeper_name:operation.keeper_name
               ~operation_id:operation.operation_id
           with
           | Error _ as error -> error
           | Ok () ->
             loop
               (operation :: operations)
               (operation.keeper_name :: blocked)
               rest)
        else loop (operation :: operations) blocked rest
      | Keeper_shutdown_store.Corrupt_record _ :: rest -> loop operations blocked rest
    in
    (match restore_corrupt_fences [] corrupt_owner_fences with
     | Error _ as error -> error
     | Ok blocked -> loop [] blocked inventory)
;;

let worker_mu = Eio.Mutex.create ()
let active_workers : (string, unit) Hashtbl.t = Hashtbl.create 17

let worker_key (operation : Keeper_shutdown_types.t) =
  Operation_id.to_string operation.operation_id
;;

let claim_worker (operation : Keeper_shutdown_types.t) =
  Eio.Mutex.use_rw ~protect:true worker_mu (fun () ->
    let key = worker_key operation in
    if Hashtbl.mem active_workers key
    then false
    else (
      Hashtbl.add active_workers key ();
      true))
;;

let release_worker (operation : Keeper_shutdown_types.t) =
  Eio.Mutex.use_rw ~protect:true worker_mu (fun () ->
    Hashtbl.remove active_workers (worker_key operation))
;;

let persist_unhandled_failure
    ~now
    ~config
    (operation : Keeper_shutdown_types.t)
    exn
  =
  let detail = Printexc.to_string exn in
  Eio.Cancel.protect (fun () ->
    Log.Keeper.error
      "shutdown worker failed; persisting durable failure evidence: keeper=%s operation=%s error=%s"
      operation.keeper_name
      (worker_key operation)
      detail;
    match
      Keeper_shutdown_store.persist_blocked_latest
        ~config
        ~identity:operation
        ~failure:{ stage = Unhandled_worker; detail }
        ~now
    with
    | Ok (Keeper_shutdown_store.Blocked_persisted blocked) ->
      Log.Keeper.error
        "shutdown worker failed; blocked state persisted: keeper=%s operation=%s revision=%d error=%s"
        blocked.keeper_name
        (worker_key blocked)
        blocked.revision
        detail
    | Ok (Keeper_shutdown_store.State_preserved current) ->
      Log.Keeper.error
        "shutdown worker failed after a durable non-progress state; preserving it: keeper=%s operation=%s revision=%d error=%s"
        current.keeper_name
        (worker_key current)
        current.revision
        detail
    | Error store_error ->
      Log.Keeper.error
        "shutdown operation %s failed and its blocked state could not be persisted: worker_error=%s store_error=%s"
        (worker_key operation)
        detail
        (Keeper_shutdown_store.error_to_string store_error))
;;

let finalize_if_ready ~config ~entry (operation : Keeper_shutdown_types.t) =
  match operation.phase with
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Finalized _ ->
    (match Keeper_shutdown_finalize.run ~config ~entry operation with
     | Ok finalized ->
       Log.Keeper.info
         "Keeper shutdown operation finalized: keeper=%s operation=%s"
         finalized.keeper_name
         (worker_key finalized)
     | Error error ->
       Log.Keeper.error
         "Keeper shutdown finalization stopped: keeper=%s operation=%s error=%s"
         operation.keeper_name
         (worker_key operation)
         (Keeper_shutdown_finalize.error_to_string error))
  | Prepared
  | Joining_lanes
  | Reconciliation_required _
  | Blocked _
  | Superseded _ -> ()
;;

let run_worker ~config ~entry (operation : Keeper_shutdown_types.t) =
  match operation.phase with
  | Prepared
  | Joining_lanes ->
    (match entry with
     | None ->
       persist_unhandled_failure
         ~now:Masc_domain.now_iso
         ~config
         operation
         (Failure "prepared registered-lane shutdown worker lost its exact entry")
     | Some exact_entry ->
       (match
          Keeper_shutdown_prepare_join.join_prepared
            ~config
            ~entry:exact_entry
            ~operation
        with
        | Ok joined -> finalize_if_ready ~config ~entry joined
        | Error error ->
          Log.Keeper.error
            "Keeper shutdown join stopped: keeper=%s operation=%s error=%s"
            operation.keeper_name
            (worker_key operation)
            (Keeper_shutdown_prepare_join.error_to_string error)))
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Finalized _ -> finalize_if_ready ~config ~entry operation
  | Reconciliation_required _
  | Blocked _
  | Superseded _ -> ()
;;

type worker_start_result =
  | Worker_started
  | Worker_already_active
  | Worker_start_rejected of worker_start_error

let start_worker ~config ~entry (operation : Keeper_shutdown_types.t) =
  match Keeper_process_switch.get () with
  | None -> Worker_start_rejected Worker_supervisor_unavailable
  | Some sw ->
    Eio.Cancel.protect (fun () ->
      match Eio.Switch.get_error sw with
      | Some cause -> Worker_start_rejected (Worker_supervisor_stopping cause)
      | None when not (claim_worker operation) -> Worker_already_active
      | None ->
        let started = Atomic.make false in
        (try
           Eio.Fiber.fork ~sw (fun () ->
             Atomic.set started true;
             Fun.protect
               ~finally:(fun () -> release_worker operation)
               (fun () ->
                  try run_worker ~config ~entry operation with
                  | Eio.Cancel.Cancelled _ ->
                    Log.Keeper.info
                      "Keeper shutdown worker cancelled by server teardown; durable recovery retained: keeper=%s operation=%s"
                      operation.keeper_name
                      (worker_key operation)
                  | exn ->
                    persist_unhandled_failure
                      ~now:Masc_domain.now_iso
                      ~config
                      operation
                      exn));
           if Atomic.get started
           then Worker_started
           else
             (match Eio.Switch.get_error sw with
              | None -> Worker_started
              | Some cause ->
                release_worker operation;
                Worker_start_rejected (Worker_supervisor_stopping cause))
         with
         | exn ->
           release_worker operation;
           Worker_start_rejected (Worker_fork_failed exn)))
;;

let start_or_error ~config ~entry (operation : Keeper_shutdown_types.t) =
  match start_worker ~config ~entry operation with
  | Worker_started | Worker_already_active -> Ok operation
  | Worker_start_rejected error -> Error (Worker_start_error error)
;;

let existing_operation_intent ~request (operation : Keeper_shutdown_types.t) =
  if
    Keeper_shutdown_types.cleanup_intent_equal
      request.Keeper_shutdown_prepare_join.cleanup_intent
      operation.cleanup_intent
  then Ok operation
  else Error (Existing_operation_intent_mismatch operation)
;;

let rec submit ~config ~entry ~request =
  if not (Eio_context.root_switch_on_current_domain ())
     && Option.is_some (Eio_context.get_root_switch_opt ())
  then
    Eio_context.run_on_owner_domain (fun () ->
      submit ~config ~entry ~request)
  else
    match Keeper_shutdown_prepare_join.prepare ~config ~entry ~request with
    | Ok operation ->
      start_or_error ~config ~entry:(Some entry) operation
    | Error (Keeper_shutdown_prepare_join.Existing_operation operation_id) ->
      (match Keeper_shutdown_store.load ~config ~keeper_name:entry.name operation_id with
       | Error error -> Error (Existing_operation_load_error error)
       | Ok operation ->
         (match existing_operation_intent ~request operation with
          | Error _ as error -> error
          | Ok ({ lane_ownership = Registered_lane lane_id; _ } as operation)
            when Keeper_lane.Id.equal lane_id (Keeper_lane.id entry.lane) ->
            start_or_error ~config ~entry:(Some entry) operation
          | Ok operation -> Error (Existing_operation_lane_mismatch operation)))
    | Error error -> Error (Prepare_error error)
;;

let rec submit_dormant ~config ~meta ~request =
  if not (Eio_context.root_switch_on_current_domain ())
     && Option.is_some (Eio_context.get_root_switch_opt ())
  then
    Eio_context.run_on_owner_domain (fun () ->
      submit_dormant ~config ~meta ~request)
  else
    match Keeper_shutdown_prepare_join.prepare_dormant ~config ~meta ~request with
    | Ok operation -> start_or_error ~config ~entry:None operation
    | Error (Keeper_shutdown_prepare_join.Existing_operation operation_id) ->
      (match Keeper_shutdown_store.load ~config ~keeper_name:meta.name operation_id with
       | Error error -> Error (Existing_operation_load_error error)
       | Ok ({ lane_ownership = Dormant_meta; _ } as operation) ->
         (match existing_operation_intent ~request operation with
          | Error _ as error -> error
          | Ok operation -> start_or_error ~config ~entry:None operation)
       | Ok operation -> Error (Existing_operation_lane_mismatch operation))
    | Error error -> Error (Prepare_error error)
;;

(* Boot recovery is the reconciliation procedure for an admission-time
   in-flight turn (#25491). Recovery runs exactly once per boot over
   operations scanned at startup, so any turn such an operation references
   ran inside a previous server process — a process that has terminally
   ended. The turn therefore cannot still be executing, and the admission
   fence has no live execution left to serialize against. What stays
   unresolved is whether that turn's external effects completed before the
   process died; holding the fence cannot answer that, so the question is
   recorded durably instead: [turn_disposition] keeps the admission-time
   observation and [join_evidence.terminal = Terminal_crashed] names the
   process death. Cleanup then settles durable state as it exists.
   Before this settlement existed, [Reconciliation_required] was an
   absorbing phase — worker no-op, recovery no-op, finalize
   [Unsupported_phase], supersession rejected — and five keepers stayed
   unbootable across restarts (2026-07-20/21 fleet wedge). *)
let process_boundary_evidence =
  { lane_outcome = Lane_cancelled_by_parent "server process ended before lane receipt"
  ; terminal = Terminal_crashed "server process ended before lane receipt"
  ; cleanup_error = None
  }

let log_boot_settled_inflight_turn
    (operation : Keeper_shutdown_types.t)
    turn
  =
  Log.Keeper.warn
    "boot recovery settled in-flight-turn shutdown: keeper=%s operation=%s observed_turn=%s — owning process ended, turn cannot still be executing; external-effect completion stays recorded as unknown"
    operation.keeper_name
    (Operation_id.to_string operation.operation_id)
    (match turn.observed_turn_id with
     | Some turn_id -> string_of_int turn_id
     | None -> "id-unobserved")
;;

let recovered_join_state (operation : Keeper_shutdown_types.t) =
  (match operation.turn_disposition with
   | No_inflight_turn -> ()
   | Inflight_effect_unknown turn -> log_boot_settled_inflight_turn operation turn);
  { operation with
    revision = operation.revision + 1
  ; join_evidence = Some process_boundary_evidence
  ; phase = Joined_idle
  ; updated_at = Masc_domain.now_iso ()
  }
;;

(* A durable [Reconciliation_required] operation reaching boot recovery was
   written either by a previous boot's recovery (before that phase settled
   here) or by the pre-fix live join path that derived the phase from the
   stale admission-time snapshot. Both classes reference a turn owned by an
   ended process; settle them identically. Join evidence already recorded by
   a live join is preserved — it is more precise than the process-boundary
   evidence. *)
let settled_reconciliation_state
    (operation : Keeper_shutdown_types.t)
    turn
  =
  log_boot_settled_inflight_turn operation turn;
  let join_evidence =
    match operation.join_evidence with
    | Some _ as recorded -> recorded
    | None -> Some process_boundary_evidence
  in
  { operation with
    revision = operation.revision + 1
  ; join_evidence
  ; phase = Joined_idle
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let blocked_interrupted_join_state (operation : Keeper_shutdown_types.t) =
  { operation with
    revision = operation.revision + 1
  ; phase =
      Blocked
        { stage = Lane_join
        ; detail =
            "server process ended while joining Keeper and Librarian lanes; Librarian completion is unknown"
        }
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let recover_operation
    ~config
    ?successor_operation_id
    (operation : Keeper_shutdown_types.t)
  =
  let persist_recovered recovered =
    match
      Keeper_shutdown_store.replace
        ~config
        ~expected_revision:operation.revision
        recovered
    with
    | Ok () -> Ok recovered
    | Error error -> Error (Keeper_shutdown_store.error_to_string error)
  in
  let operation_result =
    match operation.phase with
    | Prepared -> persist_recovered (recovered_join_state operation)
    | Joining_lanes -> persist_recovered (blocked_interrupted_join_state operation)
    | Reconciliation_required turn ->
      persist_recovered (settled_reconciliation_state operation turn)
    | Joined_idle
    | Finalizing_tasks _
    | Cleanup_ready _
    | Finalized _
    | Blocked _
    | Superseded _ -> Ok operation
  in
  match operation_result with
  | Error _ as error -> error
  | Ok recovered ->
    (match recovered.phase with
     | Joined_idle
     | Finalizing_tasks _
     | Cleanup_ready _
     | Finalized _ ->
       Keeper_shutdown_finalize.run
         ~config
         ~entry:None
         ?successor_operation_id
         recovered
       |> Result.map_error Keeper_shutdown_finalize.error_to_string
     | Prepared
     | Joining_lanes
     | Reconciliation_required _
     | Blocked _
     | Superseded _ -> Ok recovered)
;;

(* Recovery has just confirmed the admission transition for a settled
   operation. Reclaim its record so the next boot does not walk the same
   settled operation again. A reclaim failure only means the record survives
   until the next boot, so it never fails the recovery. *)
let reclaim_settled_record ~config (recovered : Keeper_shutdown_types.t) =
  match
    Keeper_shutdown_store.delete_terminal
      ~config
      ~keeper_name:recovered.keeper_name
      ~operation_id:recovered.operation_id
  with
  | Ok Keeper_shutdown_store.Terminal_deleted ->
    Log.Keeper.info
      "reclaimed settled shutdown record keeper=%s operation=%s"
      recovered.keeper_name
      (Operation_id.to_string recovered.operation_id)
  | Ok Keeper_shutdown_store.Terminal_retained -> ()
  | Error error ->
    Log.Keeper.warn
      "settled shutdown record reclaim failed keeper=%s operation=%s error=%s"
      recovered.keeper_name
      (Operation_id.to_string recovered.operation_id)
      (Keeper_shutdown_store.error_to_string error)
;;

let recover_operation_with_corrupt_owner_fence
    ~config
    ~corrupt_owner_fence
    operation
  =
  let successor_operation_id =
    Option.map (fun fence -> fence.operation_id) corrupt_owner_fence
  in
  match recover_operation ~config ?successor_operation_id operation with
  | Error _ as error -> error
  | Ok recovered ->
    if Keeper_shutdown_types.requires_admission_fence recovered
    then Ok recovered
    else
      let keeper_name, successor_operation_id =
        match corrupt_owner_fence with
        | None -> operation.keeper_name, None
        | Some fence -> fence.keeper_name, Some fence.operation_id
      in
      (match
         Keeper_owner_registry.transition_shutdown
           ~base_path:config.Workspace.base_path
           ~keeper_name
           ~from_operation_id:operation.operation_id
           ~to_operation_id:successor_operation_id
       with
       | Ok Keeper_owner.Shutdown_transition_applied
       | Ok Keeper_owner.Shutdown_transition_already_applied ->
         reclaim_settled_record ~config recovered;
         Ok recovered
       | Ok (Keeper_owner.Shutdown_transition_reserved_by_other existing) ->
         Error
           (Printf.sprintf
              "shutdown admission restore conflict: keeper=%s recovered=%s existing=%s"
              keeper_name
              (Operation_id.to_string operation.operation_id)
              (Operation_id.to_string existing))
       | Error error ->
         if
           Keeper_shutdown_finalize.admission_already_released_by_removal
             ~config
             operation
             error
         then
           (match
              Keeper_shutdown_intake_fence.transition_shutdown
                ~base_path:config.Workspace.base_path
                ~keeper_name
                ~from_operation_id:operation.operation_id
                ~to_operation_id:successor_operation_id
            with
            | Keeper_shutdown_intake_fence.Transition_applied
            | Keeper_shutdown_intake_fence.Transition_already_applied ->
              reclaim_settled_record ~config recovered;
              Ok recovered
            | Keeper_shutdown_intake_fence.Transition_reserved_by_other existing ->
              Error
                (Printf.sprintf
                   "shutdown admission restore conflict: keeper=%s recovered=%s existing=%s"
                   keeper_name
                   (Operation_id.to_string operation.operation_id)
                   (Operation_id.to_string existing)))
         else Error (Keeper_owner_registry.command_error_to_string error))
;;

let recover_at_boot ~config =
  match Keeper_shutdown_store.scan_inventory ~config with
  | Error error -> [ Error (Keeper_shutdown_store.error_to_string error) ]
  | Ok inventory ->
    (match restore_inventory_admission ~config inventory with
     | Error detail -> [ Error detail ]
     | Ok restored ->
       let corrupt_results =
         List.map
           (fun (corrupt : Keeper_shutdown_store.corrupt_record) ->
              Error
                (Printf.sprintf
                   "corrupt shutdown operation fenced: keeper=%s operation=%s path=%s error=%s"
                   corrupt.Keeper_shutdown_store.keeper_name
                   (Operation_id.to_string corrupt.operation_id)
                   corrupt.path
                   (Keeper_shutdown_store.error_to_string corrupt.error)))
           restored.corrupt_records
       in
       let recover (operation : Keeper_shutdown_types.t) =
         let corrupt_owner_fence =
           List.find_opt
             (fun (fence : corrupt_owner_fence) ->
                String.equal fence.keeper_name operation.keeper_name)
             restored.corrupt_owner_fences
         in
         recover_operation_with_corrupt_owner_fence
           ~config
           ~corrupt_owner_fence
           operation
       in
       List.map recover restored.operations @ corrupt_results)
;;

module For_testing = struct
  let persist_unhandled_failure = persist_unhandled_failure
end
