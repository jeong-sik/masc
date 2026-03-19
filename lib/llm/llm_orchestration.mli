(** Llm_orchestration — Concurrency diagnostics, response caching, and health filtering.

    All inference functions have been removed. LLM calls route through
    {!Oas_worker.complete} / {!Oas_worker.prompt_cascade} or {!Llm_cascade}. *)

(** {1 Concurrency Diagnostics} *)

val max_concurrent_llm : int

val llm_semaphore_available : unit -> int

val llm_permits_in_use : unit -> int

(** {1 Cache} *)

val cache_key_of_request : Llm_types.completion_request -> string

val cache_bypass_reason : Llm_types.completion_request -> string option

val record_cache_bypass : string -> unit

(** {1 Health Filtering} *)

(** Filter cascade requests by provider health.
    Removes local (Llama) providers when all local endpoints are unhealthy,
    allowing cloud providers to serve as fallback. *)
val filter_by_provider_health :
  Llm_types.completion_request list -> Llm_types.completion_request list
