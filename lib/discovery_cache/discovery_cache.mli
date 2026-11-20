(** Discovery_cache — TTL-cached wrapper over the AGENT_CORE provider
    discovery probe.

    All HTTP probing logic lives in [Llm_provider.Discovery]; this
    module adds:
    - 30-second TTL caching measured by monotonic elapsed time, as one
      immutable atomic snapshot;
    - Eio capability injection via {!set_env} at server init so
      the cached probe can issue HTTP without threading the
      runtime through every caller.

    The HTTP probe runs outside atomic publication, so callers never wait
    behind a lock held during multi-second network I/O. A stale caller still
    performs its own synchronous probe. The environment, endpoint list and
    refresh timestamp form one immutable state snapshot, so readers cannot
    observe fields from different generations. A result is published only when
    the state observed before probing is still current.

    The cache cells are private. Global endpoint snapshots are read through
    {!get_cached_or_refresh}. *)

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

    The staleness decision reads the endpoints and monotonic timestamp from the
    same immutable snapshot. Wall-clock adjustments do not change the TTL;
    {!cache_age_seconds} remains a separate wall-clock observation.
    Global probes use each active endpoint's declared
    [discovery_timeout_s] with the captured clock. No fallback deadline is chosen;
    an undeclared endpoint retains its existing unbounded behavior. *)

val cache_age_seconds : unit -> float
(** Wall-clock seconds since the last successful refresh. *)
