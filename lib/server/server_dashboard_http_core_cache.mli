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

val invalidate_board_projections : unit -> unit
(** Drop every cached board projection. Called on each board write so the
    next read, including the one the [notifications/board] SSE event
    triggers in the dashboard, computes from the store. *)
val shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val last_good_shell_light : Yojson.Safe.t Atomic.t

val with_dashboard_timeout :
  clock:_ Eio.Time.clock -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t

val dashboard_cache_key : Workspace.config -> string -> string -> string
val dashboard_query_cache_segment : string option -> string
val dashboard_query_cache_key :
  Workspace.config -> string -> (string * string option) list -> string
val dashboard_briefing_timeout_s : float

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t
