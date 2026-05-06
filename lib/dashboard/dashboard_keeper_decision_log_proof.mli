type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}

type turn_span_stat

val empty_scheduled_stat : scheduled_stat

val scheduled_stats :
  config:Coord.config ->
  string ->
  scheduled_stat

val scheduled_evidence_json : scheduled_stat -> Yojson.Safe.t

val turn_span_stats :
  config:Coord.config ->
  string ->
  turn_span_stat

val has_persistent_turn_span :
  now:float ->
  turn_span_stat ->
  bool

val persistent_turn_window_hours : float
val recent_turn_max_age_hours : float

val turn_span_evidence_json :
  now:float ->
  string ->
  turn_span_stat ->
  Yojson.Safe.t
