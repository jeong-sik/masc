(** Cascade health filtering — classify HTTP errors and prune the
    provider list by local-discovery health and API-key presence.

    Extracted from [Cascade_config] for cohesion (@since 0.99.5).

    The cascade-failure classification itself lives in
    [Oas_compat.Http_client] so the exhaustive match over the
    [http_error] variants exists in exactly one place; this module
    only re-exposes the {b decision} predicates needed by the cascade
    runtime. Internal helpers ([classify_failure],
    [has_required_api_key], [filter_healthy_internal]) are hidden. *)

val should_cascade_to_next :
  Llm_provider.Http_client.http_error -> bool
(** [true] iff the error class indicates the cascade should advance to
    the next provider (transient HTTP, network, capability mismatch).
    Delegates to [Oas_compat.Http_client.should_cascade]. *)

val is_local_provider : Llm_provider.Provider_config.t -> bool
(** [true] iff the provider is a local endpoint (Ollama, llama-server,
    LM Studio, etc.) — i.e. an endpoint that does not require an API key
    and is subject to {!filter_healthy} discovery probing. *)

val filter_healthy :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list
(** Return the providers that should remain in the cascade after:

    {ol
      {- dropping cloud providers missing an [api_key] (kept all if the
         filter would empty the list — a fail-open guard);}
      {- if any local provider exists, refreshing the shared
         [model_endpoints] index via [Llm_provider.Discovery.refresh_and_sync];}
      {- when {b every} local endpoint is unhealthy and at least one
         cloud provider exists, falling back to the cloud-only set
         (logged at info via [Diag]).}}

    The function is invoked at startup and on each cascade reload. *)
