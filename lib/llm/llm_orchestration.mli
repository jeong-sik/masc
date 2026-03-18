(** Llm_orchestration — Concurrency control, response caching, and cascade logic for LLM calls. *)

val max_concurrent_llm : int

val llm_semaphore_available : unit -> int

val llm_permits_in_use : unit -> int

val cache_key_of_request : Llm_types.completion_request -> string

(** Filter cascade requests by provider health.
    Removes local (Llama) providers when all local endpoints are unhealthy,
    allowing cloud providers to serve as fallback.
    Cloud providers always pass through. *)
val filter_by_provider_health :
  Llm_types.completion_request list -> Llm_types.completion_request list

val complete :
  ?timeout_sec:int ->
  Llm_types.completion_request ->
  (Llm_types.completion_response, string) result

val cascade :
  ?accept:(Llm_types.completion_response -> bool) ->
  ?timeout_sec:int ->
  Llm_types.completion_request list ->
  (Llm_types.completion_response, string) result

val run_prompt_cascade :
  ?temperature:float ->
  ?timeout_sec:int ->
  ?accept:(Llm_types.completion_response -> bool) ->
  ?system:string ->
  model_specs:Llm_types.model_spec list ->
  max_tokens:int ->
  prompt:string ->
  unit ->
  (Llm_types.completion_response, string) result

(** Streaming completion for a single request.
    Calls the provider in streaming mode and invokes [on_event] for each SSE
    event as it arrives. Returns the assembled final response.
    Uses the same concurrency permit as {!complete}.

    Stub: until the real streaming implementation lands, this calls {!complete}
    in batch mode and synthesises a single ContentBlockDelta event with the
    full text.

    @since 2.110.0 *)
val call_provider_stream :
  ?timeout_sec:float ->
  Llm_types.completion_request ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  (Llm_types.completion_response, string) result
