(** Google ADC access tokens cached in memory with single-flight refresh.
    The gcloud process owns ADC/service-account refresh; tokens are never
    persisted on disk. *)

type runner = string list -> (string, unit) result

(** Default in-memory TTL for cached ADC access tokens (45 minutes, leaving a
    15-minute safety margin beneath Google's 1-hour OAuth access-token
    lifetime). *)
val default_ttl_s : float

(** In-memory TTL cache with single-flight refresh serialization across Eio
    fibers and non-Eio callers. *)
type cache

(** Create an isolated ADC token cache. [ttl_s] defaults to {!default_ttl_s}
    and must be finite and strictly positive. [now] supplies monotonic seconds
    for expiry checks (defaulting to the monotonic OS clock). *)
val create_cache : ?ttl_s:float -> ?now:(unit -> float) -> unit -> cache

(** Evict any cached token from [cache] immediately so the next call fetches a
    fresh ADC access token. *)
val invalidate_cache : cache -> unit

(** Evict any cached token from the process-wide default ADC cache (e.g. after
    HTTP 401 or credential rotation). *)
val invalidate : unit -> unit

(** Execute one uncached ADC token lookup via [run], validating that the
    trimmed stdout is a single non-empty token free of control characters. *)
val refresh_with
  :  run:runner
  -> unit
  -> (Llm_provider.Secret.t, Llm_provider.Provider_config.credential_refresh_error) result

(** Return a cached ADC token from [cache] (defaulting to the process-wide
    cache) or perform a single-flight refresh via [run] on cache miss or
    expiry. Concurrent callers serialize via {!Cross_context_mutex} without
    holding a [Stdlib.Mutex] across subprocess I/O or Eio yields, and without
    raising [Effect.Unhandled] on non-Eio threads. *)
val get_token_with
  :  ?cache:cache
  -> run:runner
  -> unit
  -> (Llm_provider.Secret.t, Llm_provider.Provider_config.credential_refresh_error) result

(** Build a refreshable {!Llm_provider.Provider_config.credential_source}
    backed by [cache] (defaulting to the process-wide cache) and [run], wired
    with immediate cache invalidation on HTTP 401. *)
val credential_source_with
  :  ?cache:cache
  -> run:runner
  -> unit
  -> Llm_provider.Provider_config.credential_source

(** Process-wide ADC credential source backed by the shared TTL cache and wired
    for immediate invalidation on HTTP 401. *)
val credential_source : unit -> Llm_provider.Provider_config.credential_source
