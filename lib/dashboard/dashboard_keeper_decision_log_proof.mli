type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}

val empty_scheduled_stat : scheduled_stat

val scheduled_stats :
  config:Workspace.config ->
  string ->
  scheduled_stat

val scheduled_evidence_json : scheduled_stat -> Yojson.Safe.t

(** How old a keeper's last recorded activity may be and still count as
    current. Read by the meta counter features, which have no window of their
    own. *)
val recent_turn_max_age_hours : float
