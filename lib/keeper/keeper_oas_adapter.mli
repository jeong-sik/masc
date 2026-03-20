(** Keeper_oas_adapter — OAS wrappers for keeper LLM calls.

    Uses cascade-name-based model resolution (no [model_spec] construction).
    Delegates to [Oas_worker.run_named] for agent loops and
    [Cascade.complete] for single-shot cascade calls.

    @since OAS migration Phase 1
    @since LLM-free cascade Phase 2 *)

open Keeper_types

(** Result of [run_with_tools], including tool execution history. *)
type tools_run_result = {
  oas_result : Oas_worker.run_result;
  tools_executed : string list;
}

(** Tool loop LLM call (proactive, autonomy, social board events).
    Wraps [Oas_worker.run_named_with_masc_tools] with keeper tool dispatch.
    [cascade_name] selects the model cascade (e.g. "keeper_autonomy").
    When [gate_config] is provided, each tool call is wrapped with
    [Eval_gate.guarded_execute] for cost/entropy/destructive checks. *)
val run_with_tools :
  config:Room.config ->
  meta:keeper_meta ->
  cascade_name:string ->
  system_prompt:string ->
  goal:string ->
  max_turns:int ->
  temperature:float ->
  max_tokens:int ->
  ?gate_config:Eval_gate.gate_config ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  unit ->
  (tools_run_result, string) result

(** Tool-free LLM call (deliberation, correction, forced grounding).
    Wraps [Oas_worker.run_named] without tools. Single turn.
    [cascade_name] selects the model cascade (e.g. "keeper_deliberation"). *)
val run_simple :
  config:Room.config ->
  meta:keeper_meta ->
  cascade_name:string ->
  system_prompt:string ->
  prompt:string ->
  temperature:float ->
  max_tokens:int ->
  unit ->
  (Oas_worker.run_result, string) result

(** Extract text content from an OAS run result. *)
val text_of_run_result : Oas_worker.run_result -> string

(** Extract usage from an OAS run result.
    Returns zero usage if response has no usage data. *)
val usage_of_run_result : Oas_worker.run_result -> Agent_sdk.Types.api_usage

(** Extract model ID string from an OAS run result. *)
val model_of_run_result : Oas_worker.run_result -> string

(** Cascade through [Cascade.complete] — single-shot, no agent loop.
    [cascade_name] defaults to ["keeper_turn"]. *)
val run_cascade :
  ?cascade_name:string ->
  ?timeout_sec:int ->
  messages:Agent_sdk.Types.message list ->
  temperature:float ->
  max_tokens:int ->
  unit ->
  (Llm_provider.Types.api_response, string) result

(** Streaming cascade with synthetic SSE events.
    [cascade_name] defaults to ["keeper_turn"]. *)
val run_cascade_stream :
  ?cascade_name:string ->
  ?timeout_sec:float ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  messages:Agent_sdk.Types.message list ->
  temperature:float ->
  max_tokens:int ->
  unit ->
  (Llm_provider.Types.api_response, string) result
