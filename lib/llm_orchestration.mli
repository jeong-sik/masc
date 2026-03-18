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
