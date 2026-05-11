(** Ollama [/api/ps] capacity probe.

    Phase A introduced {!Cascade_client_capacity} as a process-local
    semaphore for endpoints {!Cascade_throttle} cannot probe (ollama
    HTTP, CLI transports, etc.).  The Phase A semaphore is accurate
    for *this* OCaml process, but it cannot see request load from
    other clients (other keepers, dashboard, manual curl) hitting
    the same ollama server.

    Phase C adds a real server-side probe via Ollama's [/api/ps]
    endpoint, which lists currently-loaded models.  When a model is
    loaded, ollama is "warm"; when [models] is empty, it is "cold"
    and the next request will pay a model-load latency hit.  We
    surface that as a {!Cascade_throttle.capacity_info} record with
    [source = Discovered], so the strategy treats it like a real
    capacity probe and prefers it over the client semaphore.

    The probe is deliberately {b synchronous} from the strategy's
    point of view: [cached_capacity] is a pure cache read.  The
    caller (typically the cascade entry in [oas_worker_named.ml])
    is responsible for invoking [try_probe] periodically — usually
    once per cascade attempt — to keep the cache warm.

    Cache TTL is short (a few seconds) because ollama state changes
    when other clients run inference.  Treating an old cache entry
    as authoritative is worse than missing the optimisation.

    @since 0.9.8 *)

(** {1 URL classification} *)

(** [is_ollama_url url] mirrors the heuristic in
    {!Cascade_client_capacity.looks_like_ollama}: any URL whose
    host:port substring contains [:11434].  Re-exported here so
    callers do not have to depend on both modules. *)
val is_ollama_url : string -> bool

(** {1 Cache lookup (synchronous, IO-free)} *)

(** [cached_capacity ?now url] returns the most recent cache entry
    for [url] when its [recorded_at + ttl_ms / 1000 > now], or
    [None] when the cache is empty / expired / [url] was never
    probed.  The default [now] is [Unix.gettimeofday ()].

    Pure: never performs IO.  Safe to call from inside the
    strategy's pure [order_candidates] without breaking the
    strategy's "no IO" invariant — the IO already happened in
    the corresponding {!try_probe}. *)
val cached_capacity : ?now:float -> string -> Cascade_throttle.capacity_info option

(** {1 Active probe (performs HTTP GET)} *)

(** [try_probe ~sw ~net url] issues [GET <url>/api/ps] with a short
    timeout, parses the JSON body, and updates the cache.  Returns
    the freshly-recorded [capacity_info] on success; returns [None]
    (and does not touch the cache) on timeout, non-200, or parse
    failure.

    Default [timeout_s] is read from [MASC_OLLAMA_PROBE_TIMEOUT_SEC]
    on every call (range [0.05, 30.0], literal fallback [0.5]).
    Pass an explicit [?timeout_s] argument to override per-call.

    Caller is responsible for picking [url]s that look like ollama
    (use {!is_ollama_url}); calling on a non-ollama URL will fail
    with a network error and return [None].

    The HTTP error path is intentionally silent — failed probes
    must never break the cascade, only deny the optimisation. *)
val try_probe
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> ?timeout_s:float
  -> ?now:float
  -> string
  -> Cascade_throttle.capacity_info option

(** {1 Probing many URLs} *)

(** [refresh_many ~sw ~net urls] runs {!try_probe} on every URL in
    [urls] that {!is_ollama_url} accepts and is not already covered
    by a fresh cache entry.  Probes run sequentially in the
    caller's fiber; aggregate latency is bounded by [N * timeout_s]
    where [N] is the number of probes actually issued.

    Idempotent: URLs whose cache is still fresh are skipped. *)
val refresh_many
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> ?timeout_s:float
  -> string list
  -> unit

(** {1 Pure JSON parser (test surface)} *)

(** [parse_response ?total ?now json] interprets an ollama
    [/api/ps] response.  Returns [Some info] when [json] is a JSON
    object containing a [models] field that is a JSON array;
    [process_active] is set to the array length and
    [process_available] is [total - process_active] (clamped at
    zero).  [total] defaults to [1] (matches [OLLAMA_NUM_PARALLEL=1],
    the ollama default since 0.5).

    Returns [None] on any other shape — no field, wrong type,
    invalid JSON.  This makes the parser easy to unit-test without
    spinning up an HTTP server. *)
val parse_response
  :  ?total:int
  -> ?now:float
  -> Yojson.Safe.t
  -> Cascade_throttle.capacity_info option

(** {1 Test helpers} *)

(** Empty the probe cache.  Test helper. *)
val cache_clear : unit -> unit

(** Number of cached entries.  Test helper. *)
val cache_size : unit -> int

(** {1 Probe adapter for {!Cascade_capacity_probe}} *)

(** First-class probe wrapper for registration with
    {!Cascade_capacity_probe.register}.  Structurally satisfies
    {!Cascade_capacity_probe.Probe}. *)
module Ollama_probe : sig
  val can_probe : url:string -> bool

  val probe
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> ?timeout_s:float
    -> unit
    -> Cascade_throttle.capacity_info option

  val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option

  val refresh_many
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> urls:string list
    -> ?timeout_s:float
    -> unit
    -> unit
end
