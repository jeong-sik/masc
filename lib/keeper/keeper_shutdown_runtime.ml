open Keeper_shutdown_types

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
  match operation.phase with
  | Finalized { completion = Completion_pending _; _ } -> true
  | Finalized
      { completion = (Completion_not_requested | Completion_delivered _); _ } -> false
  | Prepared
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Reconciliation_required _
  | Blocked _ -> true
;;

let restore_admission ~config ~keeper_name ~operation_id =
  match
    Keeper_turn_admission.restore_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~operation_id
  with
  | Keeper_turn_admission.Shutdown_restored
  | Keeper_turn_admission.Shutdown_already_restored -> Ok ()
  | Keeper_turn_admission.Shutdown_restore_conflict existing ->
    Error
      (Printf.sprintf
         "shutdown admission restore conflict: keeper=%s durable=%s existing=%s"
         keeper_name
         (Operation_id.to_string operation_id)
         (Operation_id.to_string existing))
;;

let restore_inventory_admission ~config inventory =
  let rec loop operations blocked corrupt_records = function
    | [] ->
      Ok
        { operations = List.rev operations
        ; blocked_keeper_names = List.sort_uniq String.compare blocked
        ; corrupt_records = List.rev corrupt_records
        }
    | Keeper_shutdown_store.Operation operation :: rest ->
      if operation_requires_fence operation
      then
        (match
           restore_admission
             ~config
             ~keeper_name:operation.keeper_name
             ~operation_id:operation.operation_id
         with
         | Error _ as error -> error
         | Ok () ->
           loop
             (operation :: operations)
             (operation.keeper_name :: blocked)
             corrupt_records
             rest)
      else loop (operation :: operations) blocked corrupt_records rest
    | Keeper_shutdown_store.Corrupt_record corrupt :: rest ->
      (match
         restore_admission
           ~config
           ~keeper_name:corrupt.keeper_name
           ~operation_id:corrupt.operation_id
       with
       | Error _ as error -> error
       | Ok () ->
         loop
           operations
           (corrupt.keeper_name :: blocked)
           (corrupt :: corrupt_records)
           rest)
  in
  loop [] [] [] inventory
;;

let worker_mu = Eio.Mutex.create ()
let active_workers : (string, unit) Hashtbl.t = Hashtbl.create 17

let worker_key (operation : Keeper_shutdown_types.t) =
  Operation_id.to_string operation.operation_id
;;

let claim_worker operation =
  Eio.Mutex.use_rw ~protect:true worker_mu (fun () ->
    let key = worker_key operation in
    if Hashtbl.mem active_workers key
    then false
    else (
      Hashtbl.add active_workers key ();
      true))
;;

let release_worker operation =
  Eio.Mutex.use_rw ~protect:true worker_mu (fun () ->
    Hashtbl.remove active_workers (worker_key operation))
;;

let persist_unhandled_failure ~now ~config operation exn =
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

let finalize_if_ready ~config ~entry operation =
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
  | Reconciliation_required _
  | Blocked _ -> ()
;;

let run_worker ~config ~entry operation =
  match operation.phase with
  | Prepared ->
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
  | Blocked _ -> ()
;;

type worker_start_result =
  | Worker_started
  | Worker_already_active
  | Worker_start_rejected of worker_start_error

let start_worker ~config ~entry operation =
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

let start_or_error ~config ~entry operation =
  match start_worker ~config ~entry operation with
  | Worker_started | Worker_already_active -> Ok operation
  | Worker_start_rejected error -> Error (Worker_start_error error)
;;

let existing_operation_intent ~request operation =
  if
    Keeper_shutdown_types.cleanup_intent_equal
      request.Keeper_shutdown_prepare_join.cleanup_intent
      operation.cleanup_intent
  then Ok operation
  else Error (Existing_operation_intent_mismatch operation)
;;

let submit ~config ~entry ~request =
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

let submit_dormant ~config ~meta ~request =
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

let recovered_join_state operation =
  let evidence =
    { lane_outcome = Lane_cancelled_by_parent "server process ended before lane receipt"
    ; terminal = Terminal_crashed "server process ended before lane receipt"
    ; cleanup_error = None
    }
  in
  let phase =
    match operation.turn_disposition with
    | No_inflight_turn -> Joined_idle
    | Inflight_effect_unknown turn -> Reconciliation_required turn
  in
  { operation with
    revision = operation.revision + 1
  ; join_evidence = Some evidence
  ; phase
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let recover_operation ~config operation =
  let operation_result =
    match operation.phase with
    | Prepared ->
      let recovered = recovered_join_state operation in
      (match
         Keeper_shutdown_store.replace
           ~config
           ~expected_revision:operation.revision
           recovered
       with
       | Ok () -> Ok recovered
       | Error error -> Error (Keeper_shutdown_store.error_to_string error))
    | Joined_idle
    | Finalizing_tasks _
    | Cleanup_ready _
    | Reconciliation_required _
    | Finalized _
    | Blocked _ -> Ok operation
  in
  match operation_result with
  | Error _ as error -> error
  | Ok recovered ->
    (match recovered.phase with
     | Joined_idle
     | Finalizing_tasks _
     | Cleanup_ready _
     | Finalized _ ->
       Keeper_shutdown_finalize.run ~config ~entry:None recovered
       |> Result.map_error Keeper_shutdown_finalize.error_to_string
     | Prepared
     | Reconciliation_required _
     | Blocked _ -> Ok recovered)
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
           (fun corrupt ->
              Error
                (Printf.sprintf
                   "corrupt shutdown operation fenced: keeper=%s operation=%s path=%s error=%s"
                   corrupt.Keeper_shutdown_store.keeper_name
                   (Operation_id.to_string corrupt.operation_id)
                   corrupt.path
                   (Keeper_shutdown_store.error_to_string corrupt.error)))
           restored.corrupt_records
       in
       List.map (recover_operation ~config) restored.operations @ corrupt_results)
;;

module For_testing = struct
  let persist_unhandled_failure = persist_unhandled_failure
end
