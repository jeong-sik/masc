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
  ; body_timeout_s : float option
  ; temperature : float
  ; accept : Agent_sdk_response.api_response -> bool
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport_resolved : Masc_grpc_transport.t
  ; allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; tool_failure_judge : Agent_sdk.Tool_failure_recovery.judge option
  ; compact_ratio : float option
  ; context_window_tokens : int option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
  ; checkpoint_stage_observed : bool Atomic.t
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

val observe_checkpoint_stage :
  bool Atomic.t -> Agent_sdk.Agent.checkpoint_stage -> unit

val same_run_retry_allowed : bool Atomic.t -> bool

val run_try_provider :
  try_provider_ctx ->
  ?enable_thinking_override:bool ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
  * Agent_sdk.Checkpoint.t option
  * (string * Obj.t) option

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_sdk_response.api_response ->
  Agent_sdk.Error.sdk_error

module For_testing : sig
  val apply_accept :
    runtime_id:string ->
    accept:(Agent_sdk_response.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
end
