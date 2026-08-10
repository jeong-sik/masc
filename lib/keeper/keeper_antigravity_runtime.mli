(** Keeper projection for the official Antigravity subscription runtime. *)

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
  config:Runtime_execution.antigravity_cli ->
  (Runtime_agent.run_result, Agent_core.Error.t) result

module For_testing : sig
  type history_window =
    { history : string
    ; admitted : int
    ; dropped : int
    }

  val window_history_to_budget : budget:int -> string list -> history_window
  (** Keeps the most recent rendered messages that fit [budget] bytes including
      the separators between them, and reports how many older ones were left
      out. The start-turn prompt travels as one argv entry, so this bound is the
      exec boundary rather than the model's context window. *)

  val fixed_prompt_label_bytes : int
  (** Bytes the prompt frame costs before any content, charged against the argv
      budget by the caller. *)
end
