(** Active-guidance layer for operator digest.

    Resolves whether a fresh operator judgment exists and builds the guidance
    fields plus the effective recommendation projection. Without a judgment,
    deterministic observations remain visible but cannot become actions.

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
  fallback_observation_summary:Yojson.Safe.t ->
  empty_recommendation_summary:Yojson.Safe.t ->
  projection
(** Build the digest's [active_*] guidance fields and effective top-level
    recommendation projection. When a fresh
    operator judgment exists, emits
    [judgment_owner = "operator_keeper"] with the judgment's
    summary/recommendation; otherwise emits
    [judgment_owner = "fallback_read_model"], preserves the supplied
    observation summary, and emits no recommendation. *)
