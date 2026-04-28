(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. This module funnels them through a short-lived
    actor-scoped cache so warm refresh loops and repeated navigation
    do not recompute identical reads. *)

val normalize_actor_name : string option -> string
(** Trim and default a missing/empty actor to ["dashboard"]. *)

val get_or_compute_snapshot_json :
  config:Coord_utils.config ->
  actor:string option ->
  (string -> Yojson.Safe.t) ->
  Yojson.Safe.t
(** Cached read with TTL [3.0 s]. The compute callback receives the
    normalized actor name produced by {!normalize_actor_name}. *)

val invalidate_snapshot_json : config:Coord_utils.config -> unit
(** Drop every snapshot cache entry for the given config (all actors). *)

val get_or_compute_digest_json :
  config:Coord_utils.config ->
  actor:string option ->
  (string -> Yojson.Safe.t) ->
  Yojson.Safe.t
(** Cached read with TTL [5.0 s] for the heavier digest projection. *)
