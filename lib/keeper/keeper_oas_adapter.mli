(** Keeper_oas_adapter — OAS Agent.run wrappers for keeper LLM calls.

    Replaces direct [Llm_orchestration.cascade] usage in keeper modules.
    Uses [Oas_worker] for agent build/run and [keeper_exec_tools] for
    tool dispatch.

    @since OAS migration Phase 1 *)

open Keeper_types

(** Tool loop LLM call (proactive, autonomy, social board events).
    Wraps [Oas_worker.run_with_masc_tools] with keeper tool dispatch.
    The [goal] string is the prompt/instruction for the agent. *)
val run_with_tools :
  config:Room.config ->
  meta:keeper_meta ->
  system_prompt:string ->
  goal:string ->
  max_turns:int ->
  temperature:float ->
  max_tokens:int ->
  (Oas_worker.run_result, string) result

(** Tool-free LLM call (deliberation, correction, forced grounding).
    Wraps [Oas_worker.run] without tools. *)
val run_simple :
  config:Room.config ->
  meta:keeper_meta ->
  system_prompt:string ->
  prompt:string ->
  temperature:float ->
  max_tokens:int ->
  (Oas_worker.run_result, string) result

(** Extract text content from an OAS run result. *)
val text_of_run_result : Oas_worker.run_result -> string

(** Extract usage from an OAS run result.
    Returns zero usage if response has no usage data. *)
val usage_of_run_result : Oas_worker.run_result -> Llm_types.token_usage

(** Extract model ID string from an OAS run result. *)
val model_of_run_result : Oas_worker.run_result -> string

(** Parameters extracted from a cascade request list for OAS execution. *)
type cascade_params = {
  primary_spec : Llm_types.model_spec;
  fallback_specs : Llm_types.model_spec list;
  system_prompt : string;
  goal : string;
  temperature : float;
  max_tokens : int;
}

(** Extract OAS execution parameters from a cascade request list.
    Separates system messages into [system_prompt], remaining messages
    into [goal] text. Returns [Error] on empty list or no user messages. *)
val cascade_config_of_requests :
  Llm_types.completion_request list ->
  (cascade_params, string) result

(** Cascade through OAS Agent.t — tries each model spec in order via
    [Oas_worker.run]. Falls back to next model on failure.
    Prefer [run_with_tools] or [run_simple] for new code. *)
val run_cascade :
  ?timeout_sec:int ->
  Llm_types.completion_request list ->
  (Llm_provider.Types.api_response, string) result

(** Streaming cascade — uses [Llm_orchestration.call_provider_stream]
    for streaming (OAS Agent SDK lacks streaming API). Falls back to
    OAS batch [run_cascade] on streaming failure. *)
val run_cascade_stream :
  ?timeout_sec:float ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  Llm_types.completion_request ->
  fallback:Llm_types.completion_request list ->
  (Llm_provider.Types.api_response, string) result

(** Expose model spec resolution for testing. *)
val resolve_primary_model_spec :
  keeper_meta -> (Llm_types.model_spec, string) result
