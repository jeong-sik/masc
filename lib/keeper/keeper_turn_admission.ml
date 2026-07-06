(** Per-keeper turn single-flight gate. See keeper_turn_admission.mli. *)

type lane =
  | Autonomous
  | Chat

type in_flight_info =
  { lane : lane
  ; started_at : float
  }

type rejection =
  { waiting : int
  ; in_flight : in_flight_info option
  }

type slot_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_slot_created : bool
  ; snapshot_in_flight : in_flight_info option
  ; snapshot_waiting : int
  ; snapshot_waiting_cap : int
  ; snapshot_waiting_full : bool
  ; snapshot_rejected_chat_count : int
  }

type fleet_snapshot =
  { fleet_keeper_count : int
  ; fleet_waiting_keeper_count : int
  ; fleet_waiting_total : int
  ; fleet_waiting_full_keeper_count : int
  ; fleet_rejected_chat_total : int
  ; fleet_in_flight_keeper_count : int
  ; fleet_slots : slot_snapshot list
  }

let lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

(* Bound sourced from the keeper runtime policy surface so the admission
   constraint is operator-visible instead of an inline heuristic. Rejected
   callers still get a typed error and can retry. *)
let max_waiting_chat_requests =
  Env_config_keeper.KeeperTurnAdmission.max_waiting_chat_requests
;;

type slot =
  { base_path : string
  ; keeper_name : string
  ; turn_mu : Eio.Mutex.t
    (* Held across the whole admitted turn (possibly minutes): must be
       fiber-cooperative, hence Eio.Mutex. Manipulated with raw
       lock/try_lock/unlock — [use_rw] would poison the slot when a turn
       raises, deadlocking the keeper forever. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [info]/[waiting]. Critical sections never yield, so the
       non-cooperative mutex is the right choice here. *)
  ; mutable info : in_flight_info option
  ; mutable waiting : int
  ; mutable rejected_chat_count : int
  }

let slots : (string, slot) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup can be reached
   outside an Eio context (e.g. test setup) and the critical section never
   yields. *)
let slots_mu = Stdlib.Mutex.create ()

let slot_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect slots_mu (fun () ->
    match Hashtbl.find_opt slots key with
    | Some slot -> slot
    | None ->
      let slot =
        { base_path
        ; keeper_name
        ; turn_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; info = None
        ; waiting = 0
        ; rejected_chat_count = 0
        }
      in
      Hashtbl.add slots key slot;
      slot)
;;

let set_info slot info = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info <- info)
let peek_info slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info)

(* Precondition: the calling fiber holds [slot.turn_mu]. There is no
   suspension point between acquiring the mutex and entering [f], so
   cancellation cannot leak the slot; the exception arm releases on every
   raise out of [f], including [Eio.Cancel.Cancelled]. *)
let run_locked slot ~lane f =
  (* NDT-OK: gettimeofday timestamps the in-flight info for observability only *)
  set_info slot (Some { lane; started_at = Unix.gettimeofday () });
  match f () with
  | v ->
    set_info slot None;
    Eio.Mutex.unlock slot.turn_mu;
    `Ran v
  | exception exn ->
    set_info slot None;
    Eio.Mutex.unlock slot.turn_mu;
    raise exn
;;

let waiting_count slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.waiting)

let rejected_snapshot slot =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    slot.rejected_chat_count <- slot.rejected_chat_count + 1;
    { waiting = slot.waiting; in_flight = slot.info })
;;

let run_if_free ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  (* Yield to a parked chat before touching the lock. [waiting > 0] implies
     the slot is held (a waiter only parks because a turn is in flight), so
     [try_lock] would fail here anyway; the explicit check keeps the
     autonomous lane from competing for a slot a dashboard/connector message
     is already queued on and documents the intent at the entry point. *)
  if waiting_count slot > 0
  then `Busy (peek_info slot)
  else if Eio.Mutex.try_lock slot.turn_mu
  then run_locked slot ~lane:Autonomous f
  else `Busy (peek_info slot)
;;

let run_serialized ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  let may_wait =
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      if slot.waiting >= max_waiting_chat_requests
      then false
      else (
        slot.waiting <- slot.waiting + 1;
        true))
  in
  if not may_wait
  then `Rejected (rejected_snapshot slot)
  else (
    (* [Fun.protect] rather than [Switch.on_release]: there is no ambient
       switch here, the finally never raises and never yields, and the only
       suspension point it covers is the cancellable [Eio.Mutex.lock] wait
       itself — a cancelled waiter leaves the queue, a successful one stops
       counting as waiting once it holds the slot. *)
    Fun.protect
      ~finally:(fun () ->
        Stdlib.Mutex.protect slot.state_mu (fun () -> slot.waiting <- slot.waiting - 1))
      (fun () -> Eio.Mutex.lock slot.turn_mu);
    run_locked slot ~lane:Chat f)
;;

let rejection_snapshot slot =
  let waiting = waiting_count slot in
  { waiting; in_flight = peek_info slot }
;;

let run_chat_if_free ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  if waiting_count slot > 0
  then `Busy (rejection_snapshot slot)
  else if Eio.Mutex.try_lock slot.turn_mu
  then run_locked slot ~lane:Chat f
  else `Busy (rejection_snapshot slot)
;;

let in_flight ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> None
  | Some slot -> peek_info slot
;;

let chat_waiting ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> false (* no slot yet ⇒ no turn ran ⇒ no chat can be waiting *)
  | Some slot -> waiting_count slot > 0
;;

let zero_snapshot ~keeper_name =
  { snapshot_keeper_name = keeper_name
  ; snapshot_slot_created = false
  ; snapshot_in_flight = None
  ; snapshot_waiting = 0
  ; snapshot_waiting_cap = max_waiting_chat_requests
  ; snapshot_waiting_full = false
  ; snapshot_rejected_chat_count = 0
  }
;;

let snapshot_of_slot slot =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    { snapshot_keeper_name = slot.keeper_name
    ; snapshot_slot_created = true
    ; snapshot_in_flight = slot.info
    ; snapshot_waiting = slot.waiting
    ; snapshot_waiting_cap = max_waiting_chat_requests
    ; snapshot_waiting_full = slot.waiting >= max_waiting_chat_requests
    ; snapshot_rejected_chat_count = slot.rejected_chat_count
    })
;;

let snapshot_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> zero_snapshot ~keeper_name
  | Some slot -> snapshot_of_slot slot
;;

let live_keeper_names ~base_path =
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
  let fleet_waiting_keeper_count =
    List.fold_left
      (fun acc slot -> if slot.snapshot_waiting > 0 then acc + 1 else acc)
      0
      fleet_slots
  in
  let fleet_waiting_total =
    List.fold_left
      (fun acc slot -> acc + slot.snapshot_waiting)
      0
      fleet_slots
  in
  let fleet_waiting_full_keeper_count =
    List.fold_left
      (fun acc slot -> if slot.snapshot_waiting_full then acc + 1 else acc)
      0
      fleet_slots
  in
  let fleet_rejected_chat_total =
    List.fold_left
      (fun acc slot -> acc + slot.snapshot_rejected_chat_count)
      0
      fleet_slots
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
  { fleet_keeper_count = List.length keeper_names
  ; fleet_waiting_keeper_count
  ; fleet_waiting_total
  ; fleet_waiting_full_keeper_count
  ; fleet_rejected_chat_total
  ; fleet_in_flight_keeper_count
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
    ; "chat_waiting_count", `Int slot.snapshot_waiting
    ; "chat_waiting_cap", `Int slot.snapshot_waiting_cap
    ; "chat_waiting_full", `Bool slot.snapshot_waiting_full
    ; "chat_rejected_count", `Int slot.snapshot_rejected_chat_count
    ]
;;

let fleet_health_json ~base_path ~keeper_names =
  let snapshot = fleet_snapshot ~base_path ~keeper_names in
  let status_reasons =
    if snapshot.fleet_waiting_full_keeper_count > 0
    then [ "chat_waiting_queue_full" ]
    else []
  in
  let operator_action_required = status_reasons <> [] in
  `Assoc
    [ "schema", `String "masc.keeper_turn_admission.v1"
    ; "status", `String (if operator_action_required then "degraded" else "ok")
    ; "operator_action_required", `Bool operator_action_required
    ; "status_reasons", `List (List.map (fun value -> `String value) status_reasons)
    ; "keeper_count", `Int snapshot.fleet_keeper_count
    ; ( "keeper_names"
      , `List
          (List.map
             (fun slot -> `String slot.snapshot_keeper_name)
             snapshot.fleet_slots) )
    ; "max_waiting_chat_requests", `Int max_waiting_chat_requests
    ; "chat_waiting_keeper_count", `Int snapshot.fleet_waiting_keeper_count
    ; "chat_waiting_total_count", `Int snapshot.fleet_waiting_total
    ; "chat_waiting_full_keeper_count", `Int snapshot.fleet_waiting_full_keeper_count
    ; "chat_rejected_total_count", `Int snapshot.fleet_rejected_chat_total
    ; "in_flight_keeper_count", `Int snapshot.fleet_in_flight_keeper_count
    ; "keepers", `List (List.map slot_snapshot_to_yojson snapshot.fleet_slots)
    ]
;;

module For_testing = struct
  let reset () = Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.reset slots)

  let peek ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
    |> Option.map (fun slot ->
      Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info, slot.waiting))
  ;;
end
