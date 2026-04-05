(** Keeper State Compat — Backward-compatible 5-state projection (RFC-0002). *)

type legacy_state =
  | Running
  | Paused
  | Stopped
  | Crashed
  | Dead

let legacy_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"
  | Crashed -> "crashed"
  | Dead -> "dead"

let legacy_of_string = function
  | "running" -> Some Running
  | "paused" -> Some Paused
  | "stopped" -> Some Stopped
  | "crashed" -> Some Crashed
  | "dead" -> Some Dead
  | _ -> None

let to_legacy : Keeper_state_machine.phase -> legacy_state = function
  | Offline -> Stopped
  | Running -> Running
  | Failing -> Running
  | Compacting -> Running
  | HandingOff -> Running
  | Draining -> Running
  | Paused -> Paused
  | Stopped -> Stopped
  | Crashed -> Crashed
  | Restarting -> Crashed
  | Dead -> Dead
