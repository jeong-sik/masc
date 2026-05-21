(** Operator broadcast and cache state cluster for dashboard HTTP core. *)

val operator_actor_hint : Httpun.Request.t -> string option

val operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref
val _operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref

val operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref
val _operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref

val operator_snapshot_cache : Server_dashboard_http_cache.cached_surface
val _operator_snapshot_cache : Server_dashboard_http_cache.cached_surface

val operator_digest_cache : Server_dashboard_http_cache.cached_surface
val _operator_digest_cache : Server_dashboard_http_cache.cached_surface

val operator_refresh_interval_s : float

val operator_snapshot_extra : unit -> (string * Yojson.Safe.t) list
