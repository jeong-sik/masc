type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
  read_errors : Yojson.Safe.t list;
}

type turn_span_stat

val empty_scheduled_stat : scheduled_stat

val scheduled_stats :
  config:Workspace.config ->
  string ->
  scheduled_stat

val scheduled_read_errors : scheduled_stat -> Yojson.Safe.t list

val scheduled_evidence_json : scheduled_stat -> Yojson.Safe.t

val turn_span_stats :
  config:Workspace.config ->
  string ->
  turn_span_stat

val turn_span_read_errors : turn_span_stat -> Yojson.Safe.t list

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
