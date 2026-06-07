type fleet_state = Keeper_turn_admission.fleet_state =
  | Running
  | Paused
  | Stopped

type admission_error = Keeper_turn_admission.rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

type token = Keeper_turn_admission.token

type snapshot =
  { fleet_state : fleet_state
  ; global_inflight : int
  }

let fleet_state_to_string = Keeper_turn_admission.fleet_state_to_string
let admission_error_to_string = Keeper_turn_admission.rejection_to_string

let snapshot () =
  let snapshot = Keeper_turn_admission.snapshot ~limit:max_int () in
  { fleet_state = snapshot.fleet_state; global_inflight = snapshot.global_inflight }
;;

let pause_fleet () = ignore (Keeper_turn_admission.pause_fleet () : Keeper_turn_admission.fleet_policy)
let resume_fleet () = ignore (Keeper_turn_admission.resume_fleet () : Keeper_turn_admission.fleet_policy)
let stop_fleet () = ignore (Keeper_turn_admission.stop_fleet () : Keeper_turn_admission.fleet_policy)

let acquire_turn ~limit =
  match Keeper_turn_admission.acquire_global_slot ~limit ~timeout_s:0.0 () with
  | Ok (token, _) -> Ok token
  | Error rejection -> Error rejection
;;

let release_turn token = Keeper_turn_admission.release_global_slot token
let available_turns = Keeper_turn_admission.available_turns
let reset_for_test = Keeper_turn_admission.reset_for_test
