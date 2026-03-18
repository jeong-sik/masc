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

(** Cascade through OAS provider — compatibility wrapper for call sites
    that already construct [completion_request list].
    Routes through [Llm_orchestration.cascade] which uses OAS provider
    internally. This is a transitional API: prefer [run_with_tools] or
    [run_simple] for new code. *)
val run_cascade :
  ?timeout_sec:int ->
  Llm_types.completion_request list ->
  (Llm_provider.Types.api_response, string) result

(** Streaming cascade through OAS provider — compatibility wrapper for
    call sites that need SSE text deltas. Falls back to batch cascade
    on streaming failure. *)
val run_cascade_stream :
  ?timeout_sec:float ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  Llm_types.completion_request ->
  fallback:Llm_types.completion_request list ->
  (Llm_provider.Types.api_response, string) result
