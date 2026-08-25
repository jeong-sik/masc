(** Discovery_cache — TTL-cached wrapper over the AGENT_CORE provider
    discovery probe.

    All HTTP probing logic lives in [Llm_provider.Discovery]; this
    module adds:
    - 30-second TTL caching keyed off an [Atomic.t] timestamp
      so the staleness check needs no lock;
    - convenience queries (any-local-healthy / idle-slot count /
      busy-slot count);
    - Eio capability injection via {!set_env} at server init so
      the cached probe can issue HTTP without threading the
      runtime through every caller.

    The cache mutex protects the result list only — the HTTP
    probe itself runs **outside** the lock to keep dashboard /
    local-runtime consumers from waiting on multi-second network
    I/O. Two concurrent refreshers may both probe; that is
    wasteful but correct, and the 30 s TTL narrows the window.

    The cache cells themselves are private. They were exposed for a
    [test_tool_local_runtime_verify] suite that seeds and restores them, and
    that suite does not exist -- no file, no module, no caller anywhere. The
    only way in is {!get_cached_or_refresh}. *)

(** {1 Type aliases} *)

type endpoint_info = Llm_provider.Discovery.endpoint_status
(** Re-export of [Llm_provider.Discovery.endpoint_status] so
    callers do not have to spell the long path. *)

(** {1 Capability injection} *)

val set_env :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit
(** Capture the Eio switch and net handle for later HTTP
    probing. Called once at server init by
    [server_runtime_bootstrap]; safe to re-call (last-writer-wins
    on the underlying [Atomic.t]). *)

(** {1 Refresh + read} *)

val get_cached_or_refresh : unit -> endpoint_info list
(** Return the cached endpoint list, refreshing first when:
    - the TTL has elapsed (30 seconds), or
    - the cache is still empty (first call after boot).

    The staleness check uses an atomic read so it does not
    contend with concurrent refreshes. *)

val cache_age_seconds : unit -> float
(** Wall-clock seconds since the last successful refresh. *)

(** {1 Convenience queries} *)

(** Sum of [slot.idle] across cached endpoints; endpoints with
    no slot info contribute 0. Implicitly refreshes via
    {!get_cached_or_refresh}. *)

(** Sum of [slot.busy] across cached endpoints; endpoints with
    no slot info contribute 0. Implicitly refreshes via
    {!get_cached_or_refresh}. *)

(** {1 JSON projections} *)

(** Re-export of [Llm_provider.Discovery.endpoint_status_to_json]
    so dashboard consumers do not have to spell the path. *)
