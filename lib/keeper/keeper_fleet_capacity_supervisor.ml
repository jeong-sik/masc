module Spawn_reason = struct
  type t =
    | Below_target_reaction_capacity
    | Below_minimum_running_fibers
    | Recovery_from_cold_start

  let to_string = function
    | Below_target_reaction_capacity -> "below_target_reaction_capacity"
    | Below_minimum_running_fibers -> "below_minimum_running_fibers"
    | Recovery_from_cold_start -> "recovery_from_cold_start"
  ;;
end

module Backpressure_reason = struct
  type t =
    | Admission_queue_saturated
    | Disk_pressure_active
    | Fd_pressure_active

  let to_string = function
    | Admission_queue_saturated -> "admission_queue_saturated"
    | Disk_pressure_active -> "disk_pressure_active"
    | Fd_pressure_active -> "fd_pressure_active"
  ;;
end

module Noop_reason = struct
  type t =
    | Capacity_at_target
    | Capacity_above_target
    | Already_recently_acted

  let to_string = function
    | Capacity_at_target -> "capacity_at_target"
    | Capacity_above_target -> "capacity_above_target"
    | Already_recently_acted -> "already_recently_acted"
  ;;
end

type observation =
  { running_keeper_fiber_count : int
  ; target_reaction_capacity_count : int
  ; minimum_running_fibers : int
  ; reaction_capacity_shortfall_count : int
  ; admission_blocked_count : int
  ; admission_queue_saturated_cap : int
  ; disk_pressure_active : bool
  ; fd_pressure_active : bool
  ; cold_start_in_progress : bool
  ; now : float
  ; last_action_at : float option
  ; cooldown_seconds : float
  }

type spawn_request =
  { reason : Spawn_reason.t
  ; suggested_keeper_count : int
  }

type decision =
  | Spawn of spawn_request
  | Backpressure of Backpressure_reason.t
  | Noop of Noop_reason.t

type execution_result =
  { decision : decision
  ; requested_keeper_names : string list
  ; started_keeper_names : string list
  ; failed_keeper_names : (string * string) list
  }

let decision_to_string = function
  | Spawn { reason; suggested_keeper_count } ->
    Printf.sprintf
      "spawn(reason=%s,count=%d)"
      (Spawn_reason.to_string reason)
      suggested_keeper_count
  | Backpressure reason ->
    Printf.sprintf "backpressure(%s)" (Backpressure_reason.to_string reason)
  | Noop reason -> Printf.sprintf "noop(%s)" (Noop_reason.to_string reason)
;;

let take_at_most count values =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

(* TEL-OK: pure executor returns requested/started/failed names; caller owns
   spawn telemetry after binding this result to its concrete boot path. *)
let execute ~spawn_keeper ~suggested_keeper_names decision =
  match decision with
  | Spawn { suggested_keeper_count; _ } ->
    let requested_keeper_names =
      take_at_most suggested_keeper_count suggested_keeper_names
    in
    let started_keeper_names, failed_keeper_names =
      List.fold_left
        (fun (started, failed) keeper_name ->
           match
             try spawn_keeper keeper_name with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Error (Printexc.to_string exn)
           with
           | Ok () -> (keeper_name :: started, failed)
           | Error error -> (started, (keeper_name, error) :: failed))
        ([], [])
        requested_keeper_names
    in
    { decision
    ; requested_keeper_names
    ; started_keeper_names = List.rev started_keeper_names
    ; failed_keeper_names = List.rev failed_keeper_names
    }
  | Backpressure _ | Noop _ ->
    { decision
    ; requested_keeper_names = []
    ; started_keeper_names = []
    ; failed_keeper_names = []
    }
;;

let cooldown_elapsed ~now ~last_action_at ~cooldown_seconds =
  match last_action_at with
  | None -> true
  | Some t -> Float.(now -. t >= cooldown_seconds)
;;

let tick (obs : observation) : decision =
  if obs.disk_pressure_active
  then Backpressure Disk_pressure_active
  else if obs.fd_pressure_active
  then Backpressure Fd_pressure_active
  else if obs.admission_blocked_count > obs.admission_queue_saturated_cap
  then Backpressure Admission_queue_saturated
  else if not
            (cooldown_elapsed
               ~now:obs.now
               ~last_action_at:obs.last_action_at
               ~cooldown_seconds:obs.cooldown_seconds)
  then Noop Already_recently_acted
  else if obs.cold_start_in_progress
  then
    Spawn
      { reason = Recovery_from_cold_start
      ; suggested_keeper_count = max 1 obs.reaction_capacity_shortfall_count
      }
  else if obs.running_keeper_fiber_count < obs.minimum_running_fibers
  then
    Spawn
      { reason = Below_minimum_running_fibers
      ; suggested_keeper_count =
          max 1 (obs.minimum_running_fibers - obs.running_keeper_fiber_count)
      }
  else if obs.reaction_capacity_shortfall_count > 0
  then
    Spawn
      { reason = Below_target_reaction_capacity
      ; suggested_keeper_count = obs.reaction_capacity_shortfall_count
      }
  else if obs.running_keeper_fiber_count > obs.target_reaction_capacity_count
  then Noop Capacity_above_target
  else Noop Capacity_at_target
;;
