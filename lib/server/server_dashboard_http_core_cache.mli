(** Cache key, timeout, and projection diagnostics for dashboard HTTP core. *)

val dashboard_request_timeout_s : float
val standard_cache_ttl_s : float
val deep_surface_cache_ttl_s : float
val shell_surface_cache_ttl_s : float
val freshness_slo_s : float
val config_cache_ttl_s : float
val live_cache_ttl_s : float
val realtime_cache_ttl_s : float
val feature_health_cache_ttl_s : float
val dashboard_projection_cache_ttl_s : float
val shell_warmed : bool Atomic.t
val _shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val _shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val _last_good_shell : Yojson.Safe.t Atomic.t
val last_good_shell_light : Yojson.Safe.t Atomic.t
val _last_good_shell_light : Yojson.Safe.t Atomic.t

val with_dashboard_timeout :
  clock:_ Eio.Time.clock -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t

val cache_partition_segment : Workspace.config -> string
val dashboard_cache_key : Workspace.config -> string -> string -> string
val dashboard_query_cache_segment : string option -> string
val dashboard_query_cache_key :
  Workspace.config -> string -> (string * string option) list -> string
val dashboard_briefing_timeout_s : float

val attach_projection_diagnostics :
  Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t

val projection_diagnostics_json :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val initialized_json_opt :
  ?allow_initializing:bool -> Yojson.Safe.t -> Yojson.Safe.t option
