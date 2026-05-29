(** Generic HTTP capacity/health probe.

    Probes HTTP endpoints for basic health and capacity discovery.
    Two modes:
    - [Ollama]: probes [/api/ps] and parses [models] array length
    - [Generic]: probes a configurable path; any 200 + parseable JSON
      counts as [process_available = 1]

    Registered in {!Cascade_capacity_probe} at module load.

    @since 0.10.0 *)

(** {1 Probe mode} *)

type probe_mode =
  | Ollama
  | Generic of { endpoint_path : string }

(** {1 Explicit URL registry} *)

(** [register_url ?mode ~url ()] adds [url] to the probe registry.
    [~mode] defaults to [Ollama].  Idempotent. *)
val register_url : ?mode:probe_mode -> url:string -> unit -> unit

(** [is_registered ~url] reports whether [url] has been registered. *)
val is_registered : url:string -> bool

(** Number of registered URLs.  Test helper. *)
val registered_count : unit -> int

(** Empty the URL registry.  Test helper. *)
val registry_clear : unit -> unit

(** {1 Cache lookup (synchronous, IO-free)} *)

(** [cached_capacity ?now url] returns the most recent cache entry
    for [url] when its [recorded_at + ttl_ms / 1000 > now], or
    [None] when the cache is empty / expired / [url] was never
    probed.

    Pure: never performs IO. *)
val cached_capacity : ?now:float -> string -> Cascade_throttle.capacity_info option

(** {1 Active probe (performs HTTP GET)} *)

(** [try_probe ~sw ~net url] issues GET to the registered endpoint for
    [url], parses the JSON body, and updates the cache.  Returns the
    freshly-recorded [capacity_info] on success; returns [None] on
    timeout, non-200, or parse failure.

    Default [timeout_s] is [0.5] seconds. *)
val try_probe
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> ?timeout_s:float
  -> ?now:float
  -> string
  -> Cascade_throttle.capacity_info option

(** {1 Probing many URLs} *)

(** [refresh_many ~sw ~net urls] runs {!try_probe} on every registered URL in
    [urls] that is not already covered by a fresh cache entry. *)
val refresh_many
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> ?timeout_s:float
  -> string list
  -> unit

(** {1 Pure JSON parser (test surface)} *)

(** [parse_ollama_response ?total json] interprets an ollama [/api/ps]
    response.  Returns [Some info] when [json] contains a [models]
    array; [process_available] is [total - array length] (clamped at
    zero).  [total] defaults to [1]. *)
val parse_ollama_response
  :  ?total:int
  -> Yojson.Safe.t
  -> Cascade_throttle.capacity_info option

(** {1 Test helpers} *)

(** Empty the probe cache.  Test helper. *)
val cache_clear : unit -> unit

(** Number of cached entries.  Test helper. *)
val cache_size : unit -> int

(** {1 Probe adapter for {!Cascade_capacity_probe}} *)

module Http_probe : sig
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
