open Keeper_shutdown_types

type submit_error =
  | Prepare_error of Keeper_shutdown_prepare_join.error
  | Existing_operation_load_error of Keeper_shutdown_store.error

let submit_error_to_string = function
  | Prepare_error error -> Keeper_shutdown_prepare_join.error_to_string error
  | Existing_operation_load_error error -> Keeper_shutdown_store.error_to_string error
;;

let worker_mu = Eio.Mutex.create ()
let active_workers : (string, unit) Hashtbl.t = Hashtbl.create 17

let worker_key operation = Operation_id.to_string operation.operation_id

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

let persist_unhandled_failure ~config operation exn =
  let blocked =
    { operation with
      phase = Blocked { stage = Record_update; detail = Printexc.to_string exn }
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  match Keeper_shutdown_store.replace ~config blocked with
  | Ok () -> ()
  | Error store_error ->
    Log.Keeper.error
      "shutdown operation %s failed and its blocked state could not be persisted: %s"
      (worker_key operation)
      (Keeper_shutdown_store.error_to_string store_error)
;;

let finalize_if_ready ~config ~entry operation =
  match operation.phase with
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _ ->
    (match Keeper_shutdown_finalize.run ~config ~entry:(Some entry) operation with
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
  | Finalized _
  | Blocked _ -> ()
;;

let run_worker ~config ~entry operation =
  match operation.phase with
  | Prepared ->
    (match Keeper_shutdown_prepare_join.join_prepared ~config ~entry ~operation with
     | Ok joined -> finalize_if_ready ~config ~entry joined
     | Error error ->
       Log.Keeper.error
         "Keeper shutdown join stopped: keeper=%s operation=%s error=%s"
         operation.keeper_name
         (worker_key operation)
         (Keeper_shutdown_prepare_join.error_to_string error))
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _ -> finalize_if_ready ~config ~entry operation
  | Reconciliation_required _
  | Finalized _
  | Blocked _ -> ()
;;

let start_worker ~sw ~config ~entry operation =
  if claim_worker operation
  then
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> release_worker operation)
        (fun () ->
           try run_worker ~config ~entry operation with
           | Eio.Cancel.Cancelled _ ->
             Log.Keeper.info
               "Keeper shutdown worker cancelled by server teardown; durable recovery retained: keeper=%s operation=%s"
               operation.keeper_name
               (worker_key operation)
           | exn -> persist_unhandled_failure ~config operation exn);
      `Stop_daemon)
;;

let submit ~sw ~config ~entry ~request =
  match Keeper_shutdown_prepare_join.prepare ~config ~entry ~request with
  | Ok operation ->
    start_worker ~sw ~config ~entry operation;
    Ok operation
  | Error (Keeper_shutdown_prepare_join.Existing_operation operation_id) ->
    (match Keeper_shutdown_store.load ~config operation_id with
     | Error error -> Error (Existing_operation_load_error error)
     | Ok operation ->
       start_worker ~sw ~config ~entry operation;
       Ok operation)
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
    join_evidence = Some evidence
  ; phase
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let recover_one ~config operation =
  let operation_result =
    match operation.phase with
    | Prepared ->
      let recovered = recovered_join_state operation in
      (match Keeper_shutdown_store.replace ~config recovered with
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
     | Cleanup_ready _ ->
       Keeper_shutdown_finalize.run ~config ~entry:None recovered
       |> Result.map_error Keeper_shutdown_finalize.error_to_string
     | Prepared
     | Reconciliation_required _
     | Finalized _
     | Blocked _ -> Ok recovered)
;;

let recover_at_boot ~config =
  match Keeper_shutdown_store.list_all ~config with
  | Error error -> [ Error (Keeper_shutdown_store.error_to_string error) ]
  | Ok operations -> List.map (recover_one ~config) operations
;;
