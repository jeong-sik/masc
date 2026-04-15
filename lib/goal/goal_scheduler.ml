type scheduler_state = {
  last_daily : float option;
  last_weekly : float option;
  last_monthly : float option;
}
[@@deriving yojson]

let default_state = { last_daily = None; last_weekly = None; last_monthly = None }

let state_path config = Goal_store.scheduler_state_path config

let read_state config =
  let path = state_path config in
  if Coord.path_exists config path then
    let json = Coord.read_json config path in
    match scheduler_state_of_yojson json with
    | Ok s -> s
    | Error _ -> default_state
  else
    default_state

let write_state config state =
  Coord.write_json config (state_path config) (scheduler_state_to_yojson state)

let interval_sec : Goal_store.refresh_mode -> float = function
  | Daily -> 86_400.0
  | Weekly -> 86_400.0 *. 7.0
  | Monthly -> 86_400.0 *. 30.0

let last_run state : Goal_store.refresh_mode -> float option = function
  | Daily -> state.last_daily
  | Weekly -> state.last_weekly
  | Monthly -> state.last_monthly

let should_run_mode state ~mode ~now =
  let gap = interval_sec mode in
  match last_run state mode with
  | None -> true
  | Some ts -> now -. ts >= gap

let mark_run state ~mode ~now =
  match (mode : Goal_store.refresh_mode) with
  | Daily -> { state with last_daily = Some now }
  | Weekly -> { state with last_weekly = Some now }
  | Monthly -> { state with last_monthly = Some now }

let all_modes : Goal_store.refresh_mode list = [ Daily; Weekly; Monthly ]

let due_modes config ~now =
  let state = read_state config in
  all_modes
  |> List.filter (fun mode -> should_run_mode state ~mode ~now)

let commit_run config ~mode ~now =
  let lock_path = state_path config in
  Coord.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      let updated = mark_run state ~mode ~now in
      write_state config updated)
