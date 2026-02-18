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
  if Room.path_exists config path then
    let json = Room.read_json config path in
    match scheduler_state_of_yojson json with
    | Ok s -> s
    | Error _ -> default_state
  else
    default_state

let write_state config state =
  Room.write_json config (state_path config) (scheduler_state_to_yojson state)

let interval_sec = function
  | "daily" -> 86_400.0
  | "weekly" -> 86_400.0 *. 7.0
  | "monthly" -> 86_400.0 *. 30.0
  | _ -> 0.0

let last_run state = function
  | "daily" -> state.last_daily
  | "weekly" -> state.last_weekly
  | "monthly" -> state.last_monthly
  | _ -> None

let should_run_mode state ~mode ~now =
  let gap = interval_sec mode in
  match last_run state mode with
  | None -> true
  | Some ts -> now -. ts >= gap

let mark_run state ~mode ~now =
  match mode with
  | "daily" -> { state with last_daily = Some now }
  | "weekly" -> { state with last_weekly = Some now }
  | "monthly" -> { state with last_monthly = Some now }
  | _ -> state

let due_modes config ~now =
  let state = read_state config in
  [ "daily"; "weekly"; "monthly" ]
  |> List.filter (fun mode -> should_run_mode state ~mode ~now)

let commit_run config ~mode ~now =
  let lock_path = state_path config in
  Room.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      let updated = mark_run state ~mode ~now in
      write_state config updated)
