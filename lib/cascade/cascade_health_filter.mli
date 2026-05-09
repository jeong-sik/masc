(** Cascade health filtering — classify HTTP errors and prune the
    provider list by local-discovery health and API-key presence.

    Extracted from [Cascade_config] for cohesion (@since 0.99.5).

    The cascade-failure classification itself lives in
    [Oas_compat.Http_client] so the exhaustive match over the
    [http_error] variants exists in exactly one place; this module
    re-exposes the {b decision} predicates needed by the cascade
    runtime plus {!classify_failure} for telemetry / tests. Internal
    helpers ([has_required_api_key], [filter_healthy_internal]) stay
    hidden. *)

(* ── Strict-mode rejection ──────────────────────────────── *)

type health_filter_rejection =
  | All_missing_api_key of int
      (** All N providers lack required API key credentials. *)
  | All_local_unhealthy of { local_count : int; cloud_count : int }
      (** All local endpoints unhealthy; strict mode disallows cloud fallback. *)

val health_filter_rejection_to_string : health_filter_rejection -> string

(** Mirror of [Oas_compat.Http_client.cascade_failure_class] so callers
    can pattern-match without having to depend on the OAS surface. *)
type cascade_failure_class =
  Oas_compat.Http_client.cascade_failure_class =
  | Local_resource_exhaustion
  | Context_overflow
  | Provider_parse_error
  | Transient_http of int
  | Terminal_http of int
  | Accept_rejected_capability_mismatch
  | Accept_rejected_terminal
  | Cli_transport_required
  | Network_error
  | Provider_terminal
  | Provider_capacity_exhausted
  | Provider_hard_quota
  | Provider_capability_mismatch
  | Provider_cli_policy_invalid
  | Provider_cli_startup_failed
  | Provider_failure_parse_error
  | Provider_failure_unknown

val classify_failure :
  Llm_provider.Http_client.http_error -> cascade_failure_class
(** Classify [err] into one of the cascade-failure buckets used by the
    runtime to decide whether to retry, advance, or terminate. Pure
    delegate to [Oas_compat.Http_client.classify]. *)

val should_cascade_to_next :
  Llm_provider.Http_client.http_error -> bool
(** [true] iff the error class indicates the cascade should advance to
    the next provider (transient HTTP, network, capability mismatch).
    Delegates to [Oas_compat.Http_client.should_cascade]. *)

val is_local_provider : Llm_provider.Provider_config.t -> bool
(** [true] iff the provider is a local endpoint (Ollama, llama-server,
    LM Studio, etc.) — i.e. an endpoint that does not require an API key
    and is subject to {!filter_healthy} discovery probing. *)

val filter_healthy_strict :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  Llm_provider.Provider_config.t list ->
  (Llm_provider.Provider_config.t list, health_filter_rejection) result
(** Filter providers that should remain in the cascade after:

    {ol
      {- dropping cloud providers missing an [api_key];}
      {- if any local provider exists, refreshing the shared
         [model_endpoints] index via [Llm_provider.Discovery.refresh_and_sync];}
      {- when {b every} local endpoint is unhealthy and at least one
         cloud provider exists, falling back to the cloud-only set.}}

    Returns [Error] when:
    {ul
      {- all providers lack required API keys ([All_missing_api_key]);}
      {- all local endpoints are unhealthy and no cloud fallback exists
         ([All_local_unhealthy]).}}

    Replaces the prior fail-open [filter_healthy] variant: provider drift
    is now surfaced as a typed blocker on every call site instead of
    being silently dropped. The function is invoked at startup and on
    each cascade reload as well as on the keeper execution path. *)
