(** Central admission for keeper runtime-turn execution.

    V1 manages only the runtime-turn resource. Per-keeper turn ordering and
    autonomous/reactive channel fairness remain in [Keeper_turn_slot]. *)

type resource_kind =
  | Runtime_turn

type fleet_admission_state =
  | Running
  | Paused
  | Stopped

type runtime_capacity_snapshot =
  { resource_kind : resource_kind
  ; runtime_limit : int
  ; runtime_inflight : int
  }

type admission_error =
  | Fleet_paused
  | Fleet_stopped
  | Runtime_capacity_exceeded of runtime_capacity_snapshot

let resource_kind_to_string = function
  | Runtime_turn -> "runtime_turn"
;;

let fleet_admission_state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"
;;

let admission_error_to_string = function
  | Fleet_paused -> "fleet_paused"
  | Fleet_stopped -> "fleet_stopped"
  | Runtime_capacity_exceeded snapshot ->
    Printf.sprintf
      "%s_capacity_exceeded(inflight=%d,limit=%d)"
      (resource_kind_to_string snapshot.resource_kind)
      snapshot.runtime_inflight
      snapshot.runtime_limit
;;

let fleet_state = Atomic.make Running
let global_runtime_limit = Atomic.make 32
let global_runtime_inflight = Atomic.make 0

let configure_runtime_turn_limit limit =
  Atomic.set global_runtime_limit (max 1 limit)
;;

let runtime_turn_limit () = Atomic.get global_runtime_limit
let runtime_turn_inflight () = Atomic.get global_runtime_inflight

let pause_fleet_admission () = Atomic.set fleet_state Paused
let resume_fleet_admission () = Atomic.set fleet_state Running
let stop_fleet_admission () = Atomic.set fleet_state Stopped
let fleet_admission_state () = Atomic.get fleet_state

let check_fleet_admission () =
  match fleet_admission_state () with
  | Running -> Ok ()
  | Paused -> Error Fleet_paused
  | Stopped -> Error Fleet_stopped
;;

let capacity_snapshot ~runtime_limit ~runtime_inflight =
  { resource_kind = Runtime_turn; runtime_limit; runtime_inflight }
;;

let acquire_runtime_turn_lease ~keeper_name ~channel () =
  let channel_label = Keeper_world_observation.channel_to_string channel in
  let rec loop () =
    match check_fleet_admission () with
    | Error _ as error -> error
    | Ok () ->
      let current = Atomic.get global_runtime_inflight in
      let limit = runtime_turn_limit () in
      if current >= limit
      then (
        Log.Keeper.routine
          "runtime_admission: capacity exceeded keeper=%s channel=%s inflight=%d limit=%d"
          keeper_name
          channel_label
          current
          limit;
        Error (Runtime_capacity_exceeded (capacity_snapshot ~runtime_limit:limit ~runtime_inflight:current)))
      else if Atomic.compare_and_set global_runtime_inflight current (current + 1)
      then Ok ()
      else loop ()
  in
  loop ()
;;

let release_runtime_turn_lease () =
  let rec loop () =
    let current = Atomic.get global_runtime_inflight in
    if current <= 0
    then Log.Keeper.warn "runtime_admission: release requested with inflight=%d" current
    else if not (Atomic.compare_and_set global_runtime_inflight current (current - 1))
    then loop ()
  in
  loop ()
;;

let with_runtime_turn_lease ~keeper_name ~channel f =
  match acquire_runtime_turn_lease ~keeper_name ~channel () with
  | Error _ as error -> error
  | Ok () ->
    Eio_guard.protect
      ~finally:release_runtime_turn_lease
      (fun () -> Ok (f ()))
;;

let reset_for_test ?(runtime_turn_limit = 32) () =
  Atomic.set fleet_state Running;
  Atomic.set global_runtime_inflight 0;
  configure_runtime_turn_limit runtime_turn_limit
;;
