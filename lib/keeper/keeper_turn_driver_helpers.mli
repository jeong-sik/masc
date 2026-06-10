(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val resolved_tool_lane_label :
  effective_tools:Agent_sdk.Tool.t list ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string

val fail_open_health_filtered_candidates :
  health_tracker:Keeper_binding_health.t ->
  tool_filtered_candidates:'a list ->
  health_filtered_candidates:'a list ->
  provider_key_of:('a -> string) ->
  'a list * bool
(** [fail_open_health_filtered_candidates ~health_tracker ~tool_filtered_candidates
    ~health_filtered_candidates ~provider_key_of] preserves health-filtered candidates unless
    the health/cooldown filter would empty an otherwise tool-capable candidate
    set. In that all-cooldown case it picks the {e least-recently-failed}
    provider from [tool_filtered_candidates] for re-probe, allowing the runtime
    to attempt a single recovered provider instead of either stopping at
    [no_providers_available] or blindly re-opening the full set. *)

val apply_stream_idle_timeout_default : float option -> float option

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
