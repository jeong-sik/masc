(** Extracted provider-attempt runner for keeper runtime turns. *)

type try_provider_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; goal_blocks : Agent_sdk.Types.content_block list option
  ; priority : Llm_provider.Request_priority.t option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; execution_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; temperature : float
  ; max_tokens : int
  ; accept : Agent_sdk_response.api_response -> bool
  ; guardrails : Agent_sdk.Guardrails.t option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport_resolved : Masc_grpc_transport.t
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; context_window_tokens : int option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; approval : Agent_sdk.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> Runtime_agent.stop_reason * string option) option
  ; summarizer : (Agent_sdk.Types.message list -> string) option
  ; oas_checkpoint : Agent_sdk.Checkpoint.t option
  ; sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; on_event : (Agent_sdk.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_sdk.Agent.t option ref option
  ; on_runtime_observation :
      (Runtime_observation.runtime_observation -> unit) option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

type last_tool_progress_context =
  { tool_name : string
  ; tool_effect : Keeper_internal_error.tool_progress_effect
  ; any_mutating_tool : bool
  ; tool_effects_seen : Keeper_internal_error.tool_progress_effect list
  }

val run_try_provider :
  try_provider_ctx ->
  ?resume_checkpoint:Agent_sdk.Checkpoint.t ->
  ?per_provider_timeout_s:float ->
  ?enable_thinking_override:bool ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
  * Agent_sdk.Checkpoint.t option
  * (string * Obj.t) option

val accept_rejected_error :
  last_tool_context:last_tool_progress_context option ->
  runtime_id:string ->
  response:Agent_sdk_response.api_response ->
  Agent_sdk.Error.sdk_error

val accept_rejection_context_of_run_result :
  ?initial_messages:Agent_sdk.Types.message list ->
  Runtime_agent.run_result ->
  last_tool_progress_context option

module For_testing : sig
  val max_execution_time_for_attempt :
    ?per_provider_timeout_s:float -> unit -> float option

  val stream_idle_timeout_for_attempt :
    configured:float option -> float option

  val sanitize_runtime_mcp_external_tool_choice :
    runtime_mcp_external_tools:bool ->
    Agent_sdk.Hooks.turn_params ->
    Agent_sdk.Hooks.turn_params

  val apply_accept :
    ?initial_messages:Agent_sdk.Types.message list ->
    runtime_id:string ->
    accept:(Agent_sdk_response.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result

  val last_tool_progress_context_of_messages :
    Agent_sdk.Types.message list -> last_tool_progress_context option

  val format_last_tool_progress_context :
    last_tool_progress_context option -> string option
end
