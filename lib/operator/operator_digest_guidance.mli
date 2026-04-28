(** Active-guidance layer for operator digest.

    Resolves whether a fresh operator judgment exists for the given
    target and builds the guidance fields accordingly. Falls back to
    deterministic recommendations when no judgment is available.

    Internal helpers ([normalize_target_type],
    [judgment_surface_for_target_type], [fresh_operator_judgment],
    [judgment_summary_json]) are intentionally hidden — only the
    composer used by [operator_digest.ml] is exposed. *)

val active_guidance_fields :
  config:Coord.config ->
  actor:string ->
  target_type:string ->
  target_id:string option ->
  fallback_recommendations:Operator_digest_types.recommended_action list ->
  fallback_summary:Yojson.Safe.t ->
  (string * Yojson.Safe.t) list
(** Build the digest's [active_*] guidance fields. When a fresh
    operator judgment exists for [(target_type, target_id)] under the
    judgment surface implied by [target_type], emits
    [judgment_owner = "operator_keeper"] with the judgment's
    summary/recommendation; otherwise emits
    [judgment_owner = "fallback_read_model"] with the supplied
    fallback summary and recommendations.

    Returns the field list (not wrapped in [`Assoc]) so the caller
    can splice it into a larger digest object. *)
