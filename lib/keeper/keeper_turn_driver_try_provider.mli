(** Extracted provider-attempt runner for keeper runtime turns. *)

type try_provider_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; max_request_body_bytes : int
  ; model_input_capacity_bytes : int
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; goal_blocks : Agent_core.Types.content_block list option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; initial_messages : Agent_core.Types.message list
  ; model_input_projection : Agent_core.Agent.model_input_projection option
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; provider_call_deadline_sec : float option
  ; temperature : float option
  ; accept : Agent_core.Types.api_response -> bool
  ; hooks : Agent_core.Hooks.hooks option
  ; raw_trace : Agent_core.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport_resolved : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; checkpoint_sink : Agent_core.Agent.checkpoint_sink option
  ; checkpoint_stage_observed : bool Atomic.t
  ; context_injector : Agent_core.Hooks.context_injector option
  ; context : Agent_core.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; cooperative_yield_probe : Runtime_agent.cooperative_yield_probe option
  ; agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; on_event : (Agent_core.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_core.Agent.t option ref option
  ; on_runtime_observation :
      (Runtime_observation.runtime_observation -> unit) option
  ; on_request_wire_observation :
      (runtime_id:string ->
       max_request_body_bytes:int ->
       body_bytes:int ->
       unit)
        option
  ; event_bus : Agent_core.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

val apply_accept :
  runtime_id:string ->
  accept:(Agent_core.Types.api_response -> bool) ->
  Runtime_agent.run_result ->
  (Runtime_agent.run_result, Agent_core.Error.t) result

val observe_checkpoint_stage :
  bool Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit

val same_run_retry_allowed : bool Atomic.t -> bool

val run_try_provider :
  try_provider_ctx ->
  ?enable_thinking_override:bool ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

val run_try_provider_with_context_overflow_shrink :
  try_provider_ctx ->
  ?enable_thinking_override:bool ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_core.Types.api_response ->
  Agent_core.Error.t

module For_testing : sig
  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val observe_request_wire_error :
    runtime_id:string ->
    max_request_body_bytes:int ->
    on_request_wire_observation:
      (runtime_id:string ->
       max_request_body_bytes:int ->
       body_bytes:int ->
       unit)
        option ->
    Agent_core.Error.t ->
    unit

  val memoize_message_measurement :
    (Agent_core.Types.message -> int) -> Agent_core.Types.message -> int

  val offload_model_input_cpu : (unit -> 'a) -> 'a

  val context_overflow_shrink_max_attempts : int
  val context_overflow_shrink_divisor : int

  val context_overflow_shrink_sequence :
    starting_capacity_bytes:int ->
    same_run_retry_authorized:(unit -> bool) ->
    record_success:(capacity_bytes:int -> unit) ->
    on_shrink_retry:
      (shrink_attempt:int ->
       previous_capacity_bytes:int ->
       capacity_bytes:int ->
       unit) ->
    attempt:(capacity_bytes:int -> ('ok, Agent_core.Error.t) result) ->
    ('ok, Agent_core.Error.t) result
end
