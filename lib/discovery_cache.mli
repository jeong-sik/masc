(** Discovery_cache — TTL-cached wrapper over the OAS provider
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

    Test-only mutable state ([cached_endpoints] /
    [cache_updated_at]) is exposed deliberately —
    [test_tool_local_runtime_verify] needs to seed and restore
    the cache before / after exercising consumers. The .mli
    documents this so a future "make these private" refactor
    sees the test contract it would break. *)

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

val set_base_path : string -> unit
(** Capture the base path used by {!Discovery_history} to
    persist probe snapshots. When unset, probe persistence is
    skipped silently — the cache itself works without a base
    path. *)

(** {1 Cache state (test-visible)} *)

val cached_endpoints : endpoint_info list ref
(** Current cached probe result. Exposed for the
    [test_tool_local_runtime_verify] suite which needs to seed
    a deterministic value and restore the original after the
    test. Production callers should go through
    {!get_cached_or_refresh} instead. *)

val cache_updated_at : float Atomic.t
(** Unix timestamp of the most recent successful refresh. The
    TTL check in {!get_cached_or_refresh} reads this without
    taking the cache mutex. Exposed for the same testing
    reason as {!cached_endpoints}. *)

(** {1 Refresh + read} *)

val refresh_cache : unit -> unit
(** Run the discovery probe (HTTP, no lock held) and install
    the result under the cache mutex. Also persists the snapshot
    to {!Discovery_history} when {!set_base_path} has been called.
    No-op when {!set_env} has not yet captured the Eio handles. *)

val get_cached_or_refresh : unit -> endpoint_info list
(** Return the cached endpoint list, refreshing first when:
    - the TTL has elapsed (30 seconds), or
    - the cache is still empty (first call after boot).

    The staleness check uses an atomic read so it does not
    contend with concurrent refreshes. *)

val cache_age_seconds : unit -> float
(** Wall-clock seconds since the last successful refresh. *)

(** {1 Convenience queries} *)

val any_local_healthy : unit -> bool
(** [true] iff at least one cached endpoint reports healthy.
    Implicitly refreshes via {!get_cached_or_refresh}. *)

val idle_slot_count : unit -> int
(** Sum of [slot.idle] across cached endpoints; endpoints with
    no slot info contribute 0. Implicitly refreshes via
    {!get_cached_or_refresh}. *)

val busy_slot_count : unit -> int
(** Sum of [slot.busy] across cached endpoints; endpoints with
    no slot info contribute 0. Implicitly refreshes via
    {!get_cached_or_refresh}. *)

(** {1 JSON projections} *)

val endpoint_to_json : endpoint_info -> Yojson.Safe.t
(** Re-export of [Llm_provider.Discovery.endpoint_status_to_json]
    so dashboard consumers do not have to spell the path. *)

val summary_to_json : endpoint_info list -> Yojson.Safe.t
(** Re-export of [Llm_provider.Discovery.summary_to_json] so
    dashboard consumers do not have to spell the path. *)
