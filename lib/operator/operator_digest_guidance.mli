(** Active-guidance layer for operator digest.

    Resolves whether a fresh operator judgment exists and builds the guidance
    fields plus the effective recommendation projection. Falls back to
    deterministic recommendations when no judgment is available.

    Internal helpers ([fresh_operator_judgment], [judgment_summary_json]) are
    intentionally hidden — only the
    composer used by [operator_digest.ml] is exposed. *)

type projection = {
  fields : (string * Yojson.Safe.t) list;
  recommended_actions : Yojson.Safe.t list;
  recommendation_summary : Yojson.Safe.t;
}

val active_guidance :
  config:Workspace.config ->
  target_type:string ->
  target_id:string option ->
  fallback_recommendations:Yojson.Safe.t list ->
  fallback_summary:Yojson.Safe.t ->
  projection
(** Build the digest's [active_*] guidance fields and effective top-level
    recommendation projection. When a fresh
    operator judgment exists, emits
    [judgment_owner = "operator_keeper"] with the judgment's
    summary/recommendation; otherwise emits
    [judgment_owner = "fallback_read_model"] and keeps the supplied
    fallback projection. *)
