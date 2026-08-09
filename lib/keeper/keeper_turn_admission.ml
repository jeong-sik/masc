(** Per-keeper turn single-flight gate. See keeper_turn_admission.mli. *)

type lane =
  | Autonomous
  | Chat

type slot_transition =
  | Turn_released
  | Shutdown_rolled_back

type slot_transition_observer =
  base_path:string ->
  keeper_name:string ->
  transition:slot_transition ->
  unit

type in_flight_info =
  { lane : lane
  ; started_at : float
  }

type autonomous_block =
  | Turn_busy of in_flight_info option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t

type shutdown_reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t
  ; in_flight : in_flight_info option
  }

type begin_shutdown_result =
  | Shutdown_reserved of shutdown_reservation
  | Shutdown_already_reserved of shutdown_reservation

type rollback_shutdown_result =
  | Shutdown_rolled_back
  | Shutdown_not_reserved
  | Shutdown_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_shutdown_result =
  | Shutdown_restored
  | Shutdown_already_restored
  | Shutdown_restore_conflict of Keeper_shutdown_types.Operation_id.t

type transition_shutdown_result =
  | Shutdown_transition_applied
  | Shutdown_transition_already_applied
  | Shutdown_transition_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type 'a registration_commit_result =
  | Registration_committed of 'a
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type slot_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_slot_created : bool
  ; snapshot_in_flight : in_flight_info option
  ; snapshot_shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type fleet_snapshot =
  { fleet_keeper_count : int
  ; fleet_in_flight_keeper_count : int
  ; fleet_shutdown_keeper_count : int
  ; fleet_slots : slot_snapshot list
  }

let lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

let autonomous_block_kind = function
  | Turn_busy _ -> "turn_busy"
  | Shutdown_requested _ -> "shutdown_requested"
;;

let autonomous_block_to_string = function
  | Turn_busy None -> "reason=turn_busy holder=unpublished"
  | Turn_busy (Some { lane; started_at }) ->
    Printf.sprintf
      "reason=turn_busy holder_lane=%s holder_started_at=%.17g"
      (lane_to_string lane)
      started_at
  | Shutdown_requested operation_id ->
    Printf.sprintf
      "reason=shutdown_requested operation_id=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
;;

let autonomous_block_to_yojson = function
  | Turn_busy holder ->
    let holder_json =
      match holder with
      | None -> `Null
      | Some { lane; started_at } ->
        `Assoc
          [ "lane", `String (lane_to_string lane)
          ; "started_at", `Float started_at
          ]
    in
    `Assoc [ "kind", `String "turn_busy"; "holder", holder_json ]
  | Shutdown_requested operation_id ->
    `Assoc
      [ "kind", `String "shutdown_requested"
      ; ( "operation_id"
        , `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
      ]
;;

type slot =
  { base_path : string
  ; keeper_name : string
  ; turn_mu : Eio.Mutex.t
    (* Held across the whole admitted turn (possibly minutes): must be
       fiber-cooperative, hence Eio.Mutex. Manipulated with raw
       lock/try_lock/unlock — [use_rw] would poison the slot when a turn
       raises, deadlocking the keeper forever. *)
  ; intake_mu : Eio.Mutex.t
    (* Serializes durable external intake with shutdown join. Unlike
       [state_mu], callers may suspend while holding this cooperative mutex. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [info]/[shutdown_operation_id]. Critical sections never yield, so the
       non-cooperative mutex is the right choice here. *)
  ; mutable info : in_flight_info option
  ; mutable shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type intake_token =
  { intake_slot : slot
  ; mutable intake_active : bool
  }

type token =
  { mutable active : bool
  ; mutable before_dispatch_authority : (unit -> (unit, string) result) option
  }

let install_before_dispatch_authority token authority =
  if not token.active
  then Error "keeper turn admission token is no longer active"
  else
    match token.before_dispatch_authority with
    | Some _ -> Error "keeper turn dispatch authority is already installed"
    | None ->
      token.before_dispatch_authority <- Some authority;
      Ok ()
;;

let validate_before_dispatch token =
  if not token.active
  then Error "keeper turn admission token is no longer active"
  else
    match token.before_dispatch_authority with
    | None -> Error "keeper turn dispatch authority is not installed"
    | Some authority -> authority ()
;;

let slot_transition_observer : slot_transition_observer option Atomic.t =
  Atomic.make None

let set_slot_transition_observer observer =
  Atomic.set slot_transition_observer observer

let notify_slot_transition slot transition =
  match Atomic.get slot_transition_observer with
  | None -> ()
  | Some observer ->
    (try
       observer
         ~base_path:slot.base_path
         ~keeper_name:slot.keeper_name
         ~transition
     with
     | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
     | exn ->
       Log.Keeper.error
         "keeper_turn_admission: slot transition observer failed keeper=%s error=%s"
         slot.keeper_name
         (Printexc.to_string exn))

let slots : (string, slot) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup can be reached
   outside an Eio context (e.g. test setup) and the critical section never
   yields. *)
let slots_mu = Stdlib.Mutex.create ()

let slot_for ~base_path ~keeper_name =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect slots_mu (fun () ->
    match Hashtbl.find_opt slots key with
    | Some slot -> slot
    | None ->
      let slot =
        { base_path
        ; keeper_name
        ; turn_mu = Eio.Mutex.create ()
        ; intake_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; info = None
        ; shutdown_operation_id = None
        }
      in
      Hashtbl.add slots key slot;
      slot)
;;

let set_info slot info = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info <- info)
let peek_info slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info)
let peek_shutdown slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.shutdown_operation_id)

(* Precondition: the calling fiber holds [slot.turn_mu]. There is no
   suspension point between acquiring the mutex and entering [f], so
   cancellation cannot leak the slot; the exception arm releases on every
   raise out of [f], including [Eio.Cancel.Cancelled]. *)
let run_locked_with_token slot ~lane f =
  let token = { active = true; before_dispatch_authority = None } in
  let admission =
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id with
      | Some operation_id -> Error operation_id
      | None ->
        (* NDT-OK: admission timestamp is observability evidence only. *)
        slot.info <- Some { lane; started_at = Unix.gettimeofday () };
        Ok ())
  in
  match admission with
  | Error operation_id ->
    token.active <- false;
    Eio.Mutex.unlock slot.turn_mu;
    `Shutdown_requested operation_id
  | Ok () ->
    let release () =
      token.active <- false;
      set_info slot None;
      Eio.Mutex.unlock slot.turn_mu;
      notify_slot_transition slot Turn_released
    in
    (match f token with
     | v ->
       release ();
       `Ran v
     | exception exn ->
       release ();
       raise exn)
;;

let run_if_free_with_token ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  match peek_shutdown slot with
  | Some operation_id -> `Busy (Shutdown_requested operation_id)
  | None ->
    if Eio.Mutex.try_lock slot.turn_mu
    then
      match run_locked_with_token slot ~lane:Autonomous f with
      | `Ran value -> `Ran value
      | `Shutdown_requested operation_id ->
        `Busy (Shutdown_requested operation_id)
    else `Busy (Turn_busy (peek_info slot))
;;

let run_if_free ~base_path ~keeper_name f =
  run_if_free_with_token
    ~base_path
    ~keeper_name
    (fun _token -> f ())
;;

let in_flight ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> None
  | Some slot -> peek_info slot
;;

let reservation_of_slot slot operation_id = { operation_id; in_flight = slot.info }

let begin_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Shutdown_reserved (reservation_of_slot slot operation_id)
    | Some existing ->
      Shutdown_already_reserved (reservation_of_slot slot existing))
;;

let rollback_shutdown ~base_path ~keeper_name ~operation_id =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> Shutdown_not_reserved
  | Some slot ->
    let result =
      Stdlib.Mutex.protect slot.state_mu (fun () ->
        match slot.shutdown_operation_id with
        | None -> Shutdown_not_reserved
        | Some existing
          when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
          slot.shutdown_operation_id <- None;
          Shutdown_rolled_back
        | Some existing -> Shutdown_reserved_by_other existing)
    in
    (match result with
     | Shutdown_rolled_back ->
       notify_slot_transition slot Shutdown_rolled_back
     | Shutdown_not_reserved | Shutdown_reserved_by_other _ -> ());
    result
;;

let restore_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Shutdown_restored
    | Some existing when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
      Shutdown_already_restored
    | Some existing -> Shutdown_restore_conflict existing)
;;

let transition_shutdown
      ~base_path
      ~keeper_name
      ~from_operation_id
      ~to_operation_id
  =
  let transition slot =
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id, to_operation_id with
      | Some existing, _
        when Keeper_shutdown_types.Operation_id.equal existing from_operation_id ->
        slot.shutdown_operation_id <- to_operation_id;
        Shutdown_transition_applied
      | None, None -> Shutdown_transition_already_applied
      | Some existing, Some successor
        when Keeper_shutdown_types.Operation_id.equal existing successor ->
        Shutdown_transition_already_applied
      | None, Some successor ->
        slot.shutdown_operation_id <- Some successor;
        Shutdown_transition_applied
      | Some existing, _ -> Shutdown_transition_reserved_by_other existing)
  in
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  let slot =
    match to_operation_id with
    | Some _ -> Some (slot_for ~base_path ~keeper_name)
    | None -> Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
  in
  match slot with
  | None -> Shutdown_transition_already_applied
  | Some slot ->
    let result = transition slot in
    (match result, to_operation_id with
     | Shutdown_transition_applied, None ->
       notify_slot_transition slot Shutdown_rolled_back
     | ( Shutdown_transition_applied
       | Shutdown_transition_already_applied
       | Shutdown_transition_reserved_by_other _ ),
       Some _
     | ( Shutdown_transition_already_applied
       | Shutdown_transition_reserved_by_other _ ),
       None -> ());
    result
;;

let commit_registration_if_open ~base_path ~keeper_name commit =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | Some operation_id -> Registration_shutdown_reserved operation_id
    | None -> Registration_committed (commit ()))
;;

type 'a durable_intake_result =
  | Intake_committed of 'a
  | Intake_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a transfer_intake_result =
  | Transfer_intake_committed of 'a
  | Transfer_intake_source_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Transfer_intake_target_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

let run_durable_intake_if_open ~base_path ~keeper_name intake =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.intake_mu;
  let release () = Eio.Mutex.unlock slot.intake_mu in
  match peek_shutdown slot with
  | Some operation_id ->
    release ();
    Intake_shutdown_reserved operation_id
  | None ->
    let intake_token = { intake_slot = slot; intake_active = true } in
    (match intake intake_token with
     | value ->
       intake_token.intake_active <- false;
       release ();
       Intake_committed value
     | exception exn ->
       intake_token.intake_active <- false;
       release ();
       raise exn)
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
  token.intake_active
  && token.intake_slot == slot_for ~base_path ~keeper_name
;;

let await_idle_after_shutdown ~base_path ~keeper_name =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.turn_mu;
  Eio.Mutex.unlock slot.turn_mu;
  Eio.Mutex.lock slot.intake_mu;
  Eio.Mutex.unlock slot.intake_mu
;;

let zero_snapshot ~keeper_name =
  { snapshot_keeper_name = keeper_name
  ; snapshot_slot_created = false
  ; snapshot_in_flight = None
  ; snapshot_shutdown_operation_id = None
  }
;;

let snapshot_of_slot slot =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    { snapshot_keeper_name = slot.keeper_name
    ; snapshot_slot_created = true
    ; snapshot_in_flight = slot.info
    ; snapshot_shutdown_operation_id = slot.shutdown_operation_id
    })
;;

let snapshot_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> zero_snapshot ~keeper_name
  | Some slot -> snapshot_of_slot slot
;;

let live_keeper_names ~base_path =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  Stdlib.Mutex.protect slots_mu (fun () ->
    Hashtbl.fold
      (fun _key slot acc ->
        if String.equal slot.base_path base_path then slot.keeper_name :: acc else acc)
      slots
      [])
;;

let fleet_snapshot ~base_path ~keeper_names =
  let keeper_names =
    List.sort_uniq String.compare (keeper_names @ live_keeper_names ~base_path)
  in
  let fleet_slots =
    List.map (fun keeper_name -> snapshot_for ~base_path ~keeper_name) keeper_names
  in
  let fleet_in_flight_keeper_count =
    List.fold_left
      (fun acc slot ->
        match slot.snapshot_in_flight with
        | Some _ -> acc + 1
        | None -> acc)
      0
      fleet_slots
  in
  let fleet_shutdown_keeper_count =
    List.fold_left
      (fun acc slot ->
        match slot.snapshot_shutdown_operation_id with
        | Some _ -> acc + 1
        | None -> acc)
      0
      fleet_slots
  in
  { fleet_keeper_count = List.length keeper_names
  ; fleet_in_flight_keeper_count
  ; fleet_shutdown_keeper_count
  ; fleet_slots
  }
;;

let in_flight_to_yojson = function
  | None -> `Null
  | Some { lane; started_at } ->
    `Assoc
      [ "lane", `String (lane_to_string lane)
      ; "started_at_unix", `Float started_at
      ]
;;

let slot_snapshot_to_yojson slot =
  `Assoc
    [ "keeper_name", `String slot.snapshot_keeper_name
    ; "slot_created", `Bool slot.snapshot_slot_created
    ; "in_flight", in_flight_to_yojson slot.snapshot_in_flight
    ; ( "shutdown_operation_id"
      , match slot.snapshot_shutdown_operation_id with
        | None -> `Null
        | Some operation_id ->
          `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
    ]
;;

let fleet_health_json ~base_path ~keeper_names =
  let snapshot = fleet_snapshot ~base_path ~keeper_names in
  `Assoc
    [ "schema", `String "masc.keeper_turn_admission.v1"
    ; "status", `String "ok"
    ; "operator_action_required", `Bool false
    ; "status_reasons", `List []
    ; "keeper_count", `Int snapshot.fleet_keeper_count
    ; ( "keeper_names"
      , `List
          (List.map
             (fun slot -> `String slot.snapshot_keeper_name)
             snapshot.fleet_slots) )
    ; "in_flight_keeper_count", `Int snapshot.fleet_in_flight_keeper_count
    ; "shutdown_keeper_count", `Int snapshot.fleet_shutdown_keeper_count
    ; "keepers", `List (List.map slot_snapshot_to_yojson snapshot.fleet_slots)
    ]
;;

module For_testing = struct
  let reset () =
    Atomic.set slot_transition_observer None;
    Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.reset slots)

  let peek ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
    |> Option.map (fun slot ->
      Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info))
  ;;
end
