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

let decide_turn_plan_at_phase_gate
      ~keeper_turn_id
      ~supervisor_stop_at_entry
      phase_opt
  =
  if supervisor_stop_at_entry
  then
    { turn_plan_keeper_turn_id = keeper_turn_id
    ; turn_plan_phase = Option.map Keeper_state_machine.phase_to_string phase_opt
    ; turn_plan_status = Turn_plan_cancelled
    ; turn_plan_executable = false
    ; turn_plan_reason = "supervisor_stop"
    ; turn_plan_terminal_reason_code = Some "supervisor_stop"
    }
  else
    match phase_opt with
    | None ->
      { turn_plan_keeper_turn_id = keeper_turn_id
      ; turn_plan_phase = None
      ; turn_plan_status = Turn_plan_error
      ; turn_plan_executable = false
      ; turn_plan_reason = "registry_phase_missing"
      ; turn_plan_terminal_reason_code = Some "registry_phase_missing"
      }
    | Some phase ->
      let phase_string = Keeper_state_machine.phase_to_string phase in
      if Keeper_state_machine.can_execute_turn phase
      then
        { turn_plan_keeper_turn_id = keeper_turn_id
        ; turn_plan_phase = Some phase_string
        ; turn_plan_status = Turn_plan_dispatch
        ; turn_plan_executable = true
        ; turn_plan_reason = "executable_phase"
        ; turn_plan_terminal_reason_code = None
        }
      else
        { turn_plan_keeper_turn_id = keeper_turn_id
        ; turn_plan_phase = Some phase_string
        ; turn_plan_status = Turn_plan_skipped
        ; turn_plan_executable = false
        ; turn_plan_reason = "non_executable_phase"
        ; turn_plan_terminal_reason_code =
            Some (Printf.sprintf "non_executable_phase:%s" phase_string)
        }
;;

let turn_plan_manifest_status plan =
  match plan.turn_plan_status with
  | Turn_plan_dispatch -> "ok"
  | Turn_plan_skipped -> "skipped"
  | Turn_plan_cancelled -> "cancelled"
  | Turn_plan_error -> "error"
;;

let turn_plan_manifest_decision plan =
  let phase_fields =
    match plan.turn_plan_phase, plan.turn_plan_status with
    | Some phase, _ -> [ "phase", `String phase ]
    | None, Turn_plan_error -> [ "phase", `Null ]
    | None, _ -> []
  in
  `Assoc
    (phase_fields
     @ [ "reason", `String plan.turn_plan_reason
       ; "executable", `Bool plan.turn_plan_executable
       ])
;;
