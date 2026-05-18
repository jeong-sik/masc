(** Shared DashboardSurface envelope helpers.

    The envelope is additive: callers keep their current JSON body and attach
    [dashboard_surface_envelope] so frontend/read-model migrations can consume a
    stable metadata shape before any endpoint body is versioned. *)

type cache_metadata = {
  state : string;
  key : string option;
  ttl_s : float option;
  stale : bool;
  stale_reason : string option;
  latest_age_s : float option;
  health : string option;
}

type t = {
  schema : string;
  schema_version : int;
  surface : string;
  source : string;
  generated_at_iso : string;
  cache : cache_metadata;
}

val to_json : t -> Yojson.Safe.t

val attach :
  ?cache_key:string ->
  ?ttl_s:float ->
  ?cache_state:string ->
  surface:string ->
  source:string ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** [attach json] returns [json] with a [dashboard_surface_envelope] field when
    [json] is an object. Existing root fields are preserved. *)
