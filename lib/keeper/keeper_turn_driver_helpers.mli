(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val resolved_tool_lane_label :
  effective_tools:Agent_sdk.Tool.t list ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string

val fail_open_health_filtered_candidates :
  tool_filtered_candidates:'a list ->
  health_filtered_candidates:'a list ->
  'a list * bool
[@@deprecated
  "Compatibility-only legacy helper; RFC-0206 removed its production path. Do not use in new runtime dispatch code."]
(** [fail_open_health_filtered_candidates ~tool_filtered_candidates
    ~health_filtered_candidates] preserves health-filtered candidates unless
    the health/cooldown filter would empty an otherwise tool-capable candidate
    set. In that all-cooldown case it returns the pre-health-filter candidates
    plus [true], preserving the pre-RFC-0206 public API for downstream source
    compatibility. *)

val apply_stream_idle_timeout_default : float option -> float option

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
