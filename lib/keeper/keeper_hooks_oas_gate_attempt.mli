(** Keeper_hooks_oas_gate_attempt — pre-tool gate attempt rendering and
    telemetry. Sibling module of [Keeper_hooks_oas]; see the .ml header
    for the decomposition history. *)

val render_pre_tool_gate_output :
  Keeper_guards.gate_decision_event -> string
(** Render the user-visible output text for a pre-tool gate decision.
    Approval-required decisions get a [tool_approval_required] tag and
    keep source-path hints; rejection decisions defer to
    {!Keeper_guards.render_inline_skip_reason} (with source when known). *)

val pre_tool_gate_error :
  Keeper_guards.gate_decision_event -> string
(** Format a [decision:reason_code: reason_text] string for trajectory
    [error] fields and log entries. *)

val trajectory_duration_ms : float -> int
(** Round and clamp a sub-millisecond float duration to the integer ms
    used in trajectory entries. Non-finite and non-positive inputs
    collapse to [0]; positive values round to the nearest ms with a
    floor of [1] so genuinely sub-ms positives are not lost. *)

val record_pre_tool_gate_attempt :
  meta_ref:Keeper_types.keeper_meta ref ->
  tool_call_count_ref:int ref ->
  ?trajectory_acc:Trajectory.accumulator ->
  Keeper_guards.gate_decision_event ->
  unit
(** Record a rejected/blocked pre-tool gate attempt: increments the
    per-turn tool-call counter, logs the gate decision to the tool-call
    log (with redaction), and appends a trajectory entry when
    [trajectory_acc] is provided. Lifecycle callback failures are caught
    and counted via [Keeper_metrics] rather than propagated. *)
