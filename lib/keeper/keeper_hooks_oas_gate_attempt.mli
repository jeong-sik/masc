(** Pre-tool gate attempt rendering and telemetry for OAS keeper hooks. *)

val render_pre_tool_gate_output :
  Keeper_guards.gate_decision_event -> string

val pre_tool_gate_error :
  Keeper_guards.gate_decision_event -> string

val trajectory_duration_ms : float -> int

val record_pre_tool_gate_attempt :
  meta_ref:Keeper_types.keeper_meta ref ->
  tool_call_count_ref:int ref ->
  ?trajectory_acc:Trajectory.accumulator ->
  Keeper_guards.gate_decision_event ->
  unit
