(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val required_tool_names_for_no_tool_error :
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  tools:Agent_sdk.Tool.t list ->
  string list

val materialized_tool_names_after_lane :
  effective_tools:Agent_sdk.Tool.t list ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list

val resolved_tool_lane_label :
  effective_tools:Agent_sdk.Tool.t list ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string

val missing_required_tool_names_after_lane :
  required_tool_names:string list ->
  effective_tools:Agent_sdk.Tool.t list ->
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list

val missing_required_tool_names_after_lane_by_name :
  required_tool_names:string list ->
  materialized_tool_names:string list ->
  string list

val provider_rejections_for_no_tool_error :
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  Cascade_runtime_candidate.t list ->
  Cascade_error_classify.provider_rejection list

val apply_stream_idle_timeout_default : float option -> float option

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
