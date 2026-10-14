(** Phase-gate turn plan helpers for [Keeper_unified_turn]. *)

(** What the phase gate decided for one keeper turn. The gate appends it as
    the manifest [Phase_gate_decided] row and then takes the matching
    branch. Private: whether a phase is executable is
    {!Keeper_state_machine.can_execute_turn}'s answer, so a plan is built only
    by {!supervisor_stopped} or {!turn_plan_of_registry_phase}. *)
type turn_plan = private
  | Supervisor_stopped
    (** The supervisor's stop flag was up at turn entry. The registry phase
        is not read. *)
  | Registry_phase_missing
  | Phase_not_executable of Keeper_state_machine.phase
  | Phase_executable of Keeper_state_machine.phase

val supervisor_stopped : turn_plan

val turn_plan_of_registry_phase : Keeper_state_machine.phase option -> turn_plan
(** The plan for a turn whose supervisor has not asked it to stop. *)

val turn_plan_manifest_status : turn_plan -> string
val turn_plan_manifest_decision : turn_plan -> Yojson.Safe.t
