(** Llm_orchestration — Concurrency diagnostics and response caching.

    Inference functions ([complete], [cascade], [run_prompt_cascade],
    [call_provider_stream]) are deprecated. Use {!Llm_cascade} instead,
    which routes all calls through OAS Cascade_config.complete_named.

    Retained: concurrency counters, cache helpers, health filtering. *)

(** {1 Concurrency Diagnostics (not deprecated)} *)

val max_concurrent_llm : int

val llm_semaphore_available : unit -> int

val llm_permits_in_use : unit -> int

(** {1 Cache (not deprecated)} *)

val cache_key_of_request : Llm_types.completion_request -> string

(** {1 Health Filtering (not deprecated)} *)

(** Filter cascade requests by provider health.
    Removes local (Llama) providers when all local endpoints are unhealthy,
    allowing cloud providers to serve as fallback.
    Cloud providers always pass through. *)
val filter_by_provider_health :
  Llm_types.completion_request list -> Llm_types.completion_request list

(** {1 Deprecated Inference Functions} *)

(** @deprecated Use {!Llm_cascade.call} or {!Llm_cascade.call_raw}. *)
val complete :
  ?timeout_sec:int ->
  Llm_types.completion_request ->
  (Llm_types.api_response, string) result

(** @deprecated Use {!Llm_cascade.call_with_tools}. *)
val cascade :
  ?accept:(Llm_types.api_response -> bool) ->
  ?timeout_sec:int ->
  Llm_types.completion_request list ->
  (Llm_types.api_response, string) result

(** @deprecated Use {!Llm_cascade.call}. *)
val run_prompt_cascade :
  ?temperature:float ->
  ?timeout_sec:int ->
  ?accept:(Llm_types.api_response -> bool) ->
  ?system:string ->
  model_specs:Llm_types.model_spec list ->
  max_tokens:int ->
  prompt:string ->
  unit ->
  (Llm_types.api_response, string) result

(** @deprecated Streaming handled at adapter level with batch fallback. *)
val call_provider_stream :
  ?timeout_sec:float ->
  Llm_types.completion_request ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  (Llm_types.api_response, string) result
