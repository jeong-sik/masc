(** Operator broadcast and cache state for dashboard HTTP core. *)

type operator_snapshot_publication =
  { epoch : string
  ; generation : int
  ; compute_sequence : int
  ; terminal_sequence : int
  ; json : Yojson.Safe.t
  ; has_success : bool
  }

type operator_snapshot_compute =
  { generation : int
  ; sequence : int
  }

val operator_snapshot_broadcast_ref : (operator_snapshot_publication -> unit) ref
val operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref
val _operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref
val operator_snapshot_publication : unit -> operator_snapshot_publication
val operator_snapshot_publication_json : operator_snapshot_publication -> Yojson.Safe.t
val operator_snapshot_cache_diagnostics_json : unit -> Yojson.Safe.t

val publish_operator_snapshot_invalidation_if_current :
  generation:int -> operator_snapshot_publication option
(** Install or return the canonical generation tombstone only while
    [generation] is still current. A delayed observer returns [None] after a
    newer generation or any same-generation terminal publication. *)

val begin_operator_snapshot_compute : unit -> operator_snapshot_compute

val publish_operator_snapshot_if_current :
  compute:operator_snapshot_compute ->
  Yojson.Safe.t ->
  operator_snapshot_publication option

val mark_operator_snapshot_error_if_current :
  compute:operator_snapshot_compute ->
  exn ->
  operator_snapshot_publication option

val operator_digest_cache : Server_dashboard_http_cache.cached_surface
val _operator_digest_cache : Server_dashboard_http_cache.cached_surface
val operator_refresh_interval_s : float
val operator_snapshot_extra : unit -> (string * Yojson.Safe.t) list

module For_testing : sig
  val operator_snapshot_cache : Server_dashboard_http_cache.cached_surface
end
