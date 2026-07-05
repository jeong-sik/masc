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

let lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

(* Bound chosen to absorb a normal dashboard message burst while keeping the
   worst-case pile-up behind a long autonomous turn small; rejected callers
   get a typed error and can retry. *)
let max_waiting_chat_requests = 8

type slot =
  { turn_mu : Eio.Mutex.t
    (* Held across the whole admitted turn (possibly minutes): must be
       fiber-cooperative, hence Eio.Mutex. Manipulated with raw
       lock/try_lock/unlock — [use_rw] would poison the slot when a turn
       raises, deadlocking the keeper forever. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [info]/[waiting]. Critical sections never yield, so the
       non-cooperative mutex is the right choice here. *)
  ; mutable info : in_flight_info option
  ; mutable waiting : int
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
        { turn_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; info = None
        ; waiting = 0
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
  then (
    let waiting = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.waiting) in
    `Rejected { waiting; in_flight = peek_info slot })
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

module For_testing = struct
  let reset () = Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.reset slots)

  let peek ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
    |> Option.map (fun slot ->
      Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info, slot.waiting))
  ;;
end
