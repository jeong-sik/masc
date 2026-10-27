(** Discovery_cache — TTL-cached wrapper over the AGENT_CORE provider
    discovery probe.

    All HTTP probing logic lives in [Llm_provider.Discovery]; this
    module adds:
    - 30-second TTL caching as one immutable atomic snapshot;
    - Eio capability injection via {!set_env} at server init so
      the cached probe can issue HTTP without threading the
      runtime through every caller.

    The HTTP probe runs outside atomic publication, so callers never wait
    behind a lock held during multi-second network I/O. A stale caller still
    performs its own synchronous probe. The environment, endpoint list,
    scoped model observations and refresh timestamp form one immutable state
    snapshot, so readers cannot observe fields from different generations.
    A result is published only when the state observed before probing is still
    current. Global refresh replaces the identities it actually probed and
    retains other fresh observations instead of discarding them merely because
    they are absent from the global registry.

    The cache cells are private. Global endpoint snapshots are read through
    {!get_cached_or_refresh}; selected Ollama models are read through
    {!first_ollama_model_id_for_url}. *)

(** {1 Type aliases} *)

type endpoint_info = Llm_provider.Discovery.endpoint_status
(** Re-export of [Llm_provider.Discovery.endpoint_status] so
    callers do not have to spell the long path. *)

(** {1 Capability injection} *)

val set_env :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit
(** Capture the Eio switch, clock and net handle for later HTTP probing.
    Called once at server init by [server_runtime_bootstrap]; safe to
    re-call. All capabilities are published together, the cache is
    invalidated, and an in-flight result from the prior environment cannot
    overwrite the new state. *)

(** {1 Refresh + read} *)

val get_cached_or_refresh : unit -> endpoint_info list
(** Return the cached endpoint list, refreshing first when:
    - the TTL has elapsed (30 seconds), or
    - the cached result is empty (including every call after an empty probe).

    The staleness decision reads the endpoints and timestamp from the
    same immutable snapshot. Global probes use each active endpoint's declared
    [discovery_timeout_s] with the captured clock. No fallback deadline is chosen;
    an undeclared endpoint retains its existing unbounded behavior. *)

val cache_age_seconds : unit -> float
(** Wall-clock seconds since the last successful refresh. *)

val first_ollama_model_id_for_url :
  timeout_s:float -> ?headers:(string * string) list -> string -> string option
(** Return the first nonblank model of a healthy Ollama endpoint with this exact URL.
    Reuse a fresh positive observation only for the same URL, native protocol and
    header fingerprint scope. A stale or missing observation probes only that endpoint
    with the caller-declared total HTTP deadline; no fallback deadline is chosen here.
    Successful results are published by compare-and-set if the pre-probe state is still
    current. The scope stores a SHA-256 digest of the exact header list, never its
    plaintext. Never borrow another endpoint's model. [None] means there is no healthy
    exact endpoint/model, no captured environment, or the probe exceeded its deadline. *)
