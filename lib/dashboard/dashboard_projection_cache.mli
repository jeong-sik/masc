(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. This module funnels them through a short-lived
    actor-scoped cache so warm refresh loops and repeated navigation
    do not recompute identical reads. *)

val normalize_actor_name : string option -> string
(** Trim and default a missing/empty actor to ["dashboard"]. *)

val get_or_compute_snapshot_json :
  config:Workspace_utils.config ->
  actor:string option ->
  (string -> Yojson.Safe.t) ->
  Yojson.Safe.t
(** Cached read with TTL [3.0 s]. The compute callback receives the
    normalized actor name produced by {!normalize_actor_name}. *)

val invalidate_snapshot_json : config:Workspace_utils.config -> unit
(** Drop every snapshot cache entry for the given config (all actors). *)

val get_or_compute_digest_json :
  config:Workspace_utils.config ->
  actor:string option ->
  (string -> Yojson.Safe.t) ->
  Yojson.Safe.t
(** Cached read with TTL [5.0 s] for the heavier digest projection. *)

type operator_snapshot_fn = {
  snapshot : 'a.
    ?actor:string ->
    ?view:string ->
    ?include_messages:bool ->
    ?include_keepers:bool ->
    ?include_summary_fields:bool ->
    ?lightweight_summary:bool ->
    'a Tool_operator.context ->
    Yojson.Safe.t;
}

type operator_digest_fn = {
  digest : 'a.
    ?actor:string ->
    ?target_type:string ->
    ?target_id:string ->
    ?include_workers:bool ->
    'a Tool_operator.context ->
    (Yojson.Safe.t, string) result;
}

val register_operator_snapshot_json : operator_snapshot_fn -> unit

val register_operator_digest_json : operator_digest_fn -> unit

val operator_snapshot_json :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_keepers:bool ->
  ?include_summary_fields:bool ->
  ?lightweight_summary:bool ->
  'a Tool_operator.context ->
  Yojson.Safe.t

val operator_digest_json :
  ?actor:string ->
  ?target_type:string ->
  ?target_id:string ->
  ?include_workers:bool ->
  'a Tool_operator.context ->
  (Yojson.Safe.t, string) result


