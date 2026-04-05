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
  | Keeper_state_machine.Offline -> Stopped
  | Keeper_state_machine.Running -> Running
  | Keeper_state_machine.Failing -> Running
  | Keeper_state_machine.Compacting -> Running
  | Keeper_state_machine.HandingOff -> Running
  | Keeper_state_machine.Draining -> Running
  | Keeper_state_machine.Paused -> Paused
  | Keeper_state_machine.Stopped -> Stopped
  | Keeper_state_machine.Crashed -> Crashed
  | Keeper_state_machine.Restarting -> Crashed
  | Keeper_state_machine.Dead -> Dead
