type reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t }

type begin_result =
  | Reserved of reservation
  | Already_reserved of reservation

type rollback_result =
  | Rolled_back
  | Not_reserved
  | Reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_result =
  | Restored
  | Already_restored
  | Restore_conflict of Keeper_shutdown_types.Operation_id.t

type transition_result =
  | Transition_applied
  | Transition_already_applied
  | Transition_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type 'a registration_commit_result =
  | Registration_committed of 'a
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a durable_intake_result =
  | Intake_committed of 'a
  | Intake_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a transfer_intake_result =
  | Transfer_intake_committed of 'a
  | Transfer_intake_source_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Transfer_intake_target_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type slot =
  { intake_mu : Eio.Mutex.t
  ; state_mu : Stdlib.Mutex.t
  ; mutable shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type intake_token =
  { intake_slot : slot
  ; mutable intake_active : bool
  }

let slots : (string, slot) Hashtbl.t = Hashtbl.create 16
let slots_mu = Stdlib.Mutex.create ()

let slot_for ~base_path ~keeper_name =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect slots_mu (fun () ->
    match Hashtbl.find_opt slots key with
    | Some slot -> slot
    | None ->
      let slot =
        { intake_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; shutdown_operation_id = None
        }
      in
      Hashtbl.add slots key slot;
      slot)
;;

let find_slot ~base_path ~keeper_name =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
;;

let peek_shutdown slot =
  Stdlib.Mutex.protect slot.state_mu (fun () -> slot.shutdown_operation_id)
;;

let begin_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Reserved { operation_id }
    | Some existing -> Already_reserved { operation_id = existing })
;;

let rollback_shutdown ~base_path ~keeper_name ~operation_id =
  match find_slot ~base_path ~keeper_name with
  | None -> Not_reserved
  | Some slot ->
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id with
      | None -> Not_reserved
      | Some existing
        when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
        slot.shutdown_operation_id <- None;
        Rolled_back
      | Some existing -> Reserved_by_other existing)
;;

let restore_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Restored
    | Some existing when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
      Already_restored
    | Some existing -> Restore_conflict existing)
;;

let transition_shutdown
      ~base_path
      ~keeper_name
      ~from_operation_id
      ~to_operation_id
  =
  let slot =
    match to_operation_id with
    | Some _ -> Some (slot_for ~base_path ~keeper_name)
    | None -> find_slot ~base_path ~keeper_name
  in
  match slot with
  | None -> Transition_already_applied
  | Some slot ->
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id, to_operation_id with
      | Some existing, _
        when Keeper_shutdown_types.Operation_id.equal existing from_operation_id ->
        slot.shutdown_operation_id <- to_operation_id;
        Transition_applied
      | None, None -> Transition_already_applied
      | Some existing, Some successor
        when Keeper_shutdown_types.Operation_id.equal existing successor ->
        Transition_already_applied
      | None, Some successor ->
        slot.shutdown_operation_id <- Some successor;
        Transition_applied
      | Some existing, _ -> Transition_reserved_by_other existing)
;;

let shutdown_operation_id ~base_path ~keeper_name =
  match find_slot ~base_path ~keeper_name with
  | None -> None
  | Some slot -> peek_shutdown slot
;;

let commit_registration_if_open ~base_path ~keeper_name commit =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | Some operation_id -> Registration_shutdown_reserved operation_id
    | None -> Registration_committed (commit ()))
;;

let run_durable_intake_if_open ~base_path ~keeper_name intake =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.intake_mu;
  let release () = Eio.Mutex.unlock slot.intake_mu in
  match peek_shutdown slot with
  | Some operation_id ->
    release ();
    Intake_shutdown_reserved operation_id
  | None ->
    let token = { intake_slot = slot; intake_active = true } in
    (match intake token with
     | value ->
       token.intake_active <- false;
       release ();
       Intake_committed value
     | exception exn ->
       token.intake_active <- false;
       release ();
       raise exn)
;;

(* Observation, not authority. A reserved slot says a shutdown began, not that
   it is still running: a shutdown that never reaches [Finalized] never calls
   [rollback_shutdown], so the reservation outlives it with no path to clear
   it. On 2026-08-20 one such reservation stood for 15h32m and every 30s sweep
   round was refused by it, which is what produced 38,910 abandoned session
   directories (#29566, #29586). The caller runs regardless and is told who
   holds the slot, so a stuck shutdown cannot stop the fleet. *)
let run_durable_intake_observing ~base_path ~keeper_name intake =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.intake_mu;
  let release () = Eio.Mutex.unlock slot.intake_mu in
  let reserved_by = peek_shutdown slot in
  let token = { intake_slot = slot; intake_active = true } in
  match intake token with
  | value ->
    token.intake_active <- false;
    release ();
    value, reserved_by
  | exception exn ->
    token.intake_active <- false;
    release ();
    raise exn
;;

let run_transfer_intake_if_open
      ~base_path
      ~from_keeper
      ~to_keeper
      operation
  =
  let acquire_source_then_target () =
    match
      run_durable_intake_if_open
        ~base_path
        ~keeper_name:from_keeper
        (fun source_intake_token ->
           if String.equal from_keeper to_keeper
           then
             Transfer_intake_committed
               (operation
                  ~source_intake_token
                  ~target_intake_token:source_intake_token)
           else
             match
               run_durable_intake_if_open
                 ~base_path
                 ~keeper_name:to_keeper
                 (fun target_intake_token ->
                    operation ~source_intake_token ~target_intake_token)
             with
             | Intake_committed result -> Transfer_intake_committed result
             | Intake_shutdown_reserved operation_id ->
               Transfer_intake_target_shutdown_reserved operation_id)
    with
    | Intake_committed result -> result
    | Intake_shutdown_reserved operation_id ->
      Transfer_intake_source_shutdown_reserved operation_id
  in
  let acquire_target_then_source () =
    match
      run_durable_intake_if_open
        ~base_path
        ~keeper_name:to_keeper
        (fun target_intake_token ->
           match
             run_durable_intake_if_open
               ~base_path
               ~keeper_name:from_keeper
               (fun source_intake_token ->
                  operation ~source_intake_token ~target_intake_token)
           with
           | Intake_committed result -> Transfer_intake_committed result
           | Intake_shutdown_reserved operation_id ->
             Transfer_intake_source_shutdown_reserved operation_id)
    with
    | Intake_committed result -> result
    | Intake_shutdown_reserved operation_id ->
      Transfer_intake_target_shutdown_reserved operation_id
  in
  if String.compare from_keeper to_keeper <= 0
  then acquire_source_then_target ()
  else acquire_target_then_source ()
;;

let intake_token_matches token ~base_path ~keeper_name =
  token.intake_active && token.intake_slot == slot_for ~base_path ~keeper_name
;;

let await_idle_after_shutdown ~base_path ~keeper_name =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.intake_mu;
  Eio.Mutex.unlock slot.intake_mu
;;

module For_testing = struct
  let reset () = Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.reset slots)
end
