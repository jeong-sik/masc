(** Phase-gate turn plan helpers for [Keeper_unified_turn]. *)

type turn_plan =
  | Supervisor_stopped
  | Registry_phase_missing
  | Phase_not_executable of Keeper_state_machine.phase
  | Phase_executable of Keeper_state_machine.phase

let supervisor_stopped = Supervisor_stopped

let turn_plan_of_registry_phase = function
  | None -> Registry_phase_missing
  | Some phase when Keeper_state_machine.can_execute_turn phase ->
    Phase_executable phase
  | Some phase -> Phase_not_executable phase
;;

let turn_plan_manifest_status = function
  | Phase_executable _ -> "ok"
  | Phase_not_executable _ -> "skipped"
  | Supervisor_stopped -> "cancelled"
  | Registry_phase_missing -> "error"
;;

let turn_plan_manifest_decision plan =
  let phase_field phase =
    "phase", `String (Keeper_state_machine.phase_to_string phase)
  in
  let fields =
    match plan with
    | Supervisor_stopped -> [ "reason", `String "supervisor_stop" ]
    | Registry_phase_missing ->
      [ "phase", `Null; "reason", `String "registry_phase_missing" ]
    | Phase_not_executable phase ->
      [ phase_field phase; "reason", `String "non_executable_phase" ]
    | Phase_executable phase ->
      [ phase_field phase; "reason", `String "executable_phase" ]
  in
  let executable =
    match plan with
    | Phase_executable _ -> true
    | Supervisor_stopped | Registry_phase_missing | Phase_not_executable _ -> false
  in
  `Assoc (fields @ [ "executable", `Bool executable ])
;;
