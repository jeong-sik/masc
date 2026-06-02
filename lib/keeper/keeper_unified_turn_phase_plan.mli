(** Phase-gate turn plan helpers for [Keeper_unified_turn]. *)

type turn_plan_status =
  | Turn_plan_dispatch
  | Turn_plan_skipped
  | Turn_plan_cancelled
  | Turn_plan_error

type turn_plan =
  { turn_plan_keeper_turn_id : int
  ; turn_plan_phase : string option
  ; turn_plan_status : turn_plan_status
  ; turn_plan_executable : bool
  ; turn_plan_reason : string
  ; turn_plan_terminal_reason_code : string option
  }

val decide_turn_plan_at_phase_gate
  :  keeper_turn_id:int
  -> supervisor_stop_at_entry:bool
  -> Keeper_state_machine.phase option
  -> turn_plan

val turn_plan_manifest_status : turn_plan -> string
val turn_plan_manifest_decision : turn_plan -> Yojson.Safe.t
