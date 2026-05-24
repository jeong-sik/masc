(** Pre-tool gate attempt rendering and telemetry.

    Extracted from [Keeper_hooks_oas] to keep the parent module under
    1000 lines. All functions in this module are pure or perform
    telemetry side-effects; they do not modify keeper state.

    @since 2026-05-24 *)

val render_pre_tool_gate_source_hint :
  Keeper_guards.gate_decision_event -> string

val tool_approval_required_tag : string

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
