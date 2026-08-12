(** Keeper projection for the official Claude Code subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Claude Code candidate result plus the explicit tool-effect observation
    available at its runtime boundary. Preflight failures remain
    [No_effect_observed]; once the model turn is dispatched, the adapter fails
    closed with [Observation_unavailable]. *)

module For_testing : sig
  val bounded_probe_config
    :  fallback_timeout_s:float
    -> Runtime_claude_code.config
    -> Runtime_claude_code.config
  (** Keep an explicit turn bound unchanged and give an unbounded turn config a
      finite login-probe fallback. *)

  val host_stop_turn_identity : session_id:string -> turn_count:int -> string
  (** Deterministic durable identity used when a dynamic-tool host stop arrives
      before Claude emits its terminal result-frame turn id. *)
end

val run :
  runtime_id:string ->
  keeper_name:string ->
  base_path:string ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.claude_code ->
  attempt_outcome
