(** Extracted provider-attempt runner for keeper runtime turns. *)

type try_provider_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; require_tool_choice_support : bool
  ; require_tool_support : bool
  ; priority : Llm_provider.Request_priority.t option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; temperature : float
  ; max_tokens : int
  ; max_input_tokens : int option
  ; max_cost_usd : float option
  ; guardrails : Agent_sdk.Guardrails.t option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; memory : Agent_sdk.Memory.t option
  ; tool_retry_policy : Agent_sdk.Tool_retry_policy.t option
  ; required_tool_satisfaction :
      Agent_sdk.Completion_contract.required_tool_satisfaction
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; transport_resolved : Masc_grpc_transport.t
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; slot_id : int option
  ; enable_thinking : bool option
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
  ; event_bus : Agent_sdk.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; runtime_manifest_required_tool_names : string list
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

val run_try_provider :
  try_provider_ctx ->
  ?resume_checkpoint:Agent_sdk.Checkpoint.t ->
  ?per_provider_timeout_s:float ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
  * Agent_sdk.Checkpoint.t option
  * (string * Keeper_attempt_liveness_config.success_sample) option

module For_testing : sig
  val sanitize_runtime_mcp_external_tool_choice :
    runtime_mcp_external_tools:bool ->
    Agent_sdk.Hooks.turn_params ->
    Agent_sdk.Hooks.turn_params
end
