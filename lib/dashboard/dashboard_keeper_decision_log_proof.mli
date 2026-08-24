type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}

type turn_span_stat

type persistence_tier =
  { id : string
  ; required_span_hours : float
  }

val empty_scheduled_stat : scheduled_stat

val scheduled_stats :
  config:Workspace.config ->
  string ->
  scheduled_stat

val scheduled_evidence_json : scheduled_stat -> Yojson.Safe.t

val turn_span_stats :
  config:Workspace.config ->
  now:float ->
  string ->
  turn_span_stat

val has_persistent_turn_span :
  now:float ->
  turn_span_stat ->
  bool

val has_persistent_turn_span_for :
  required_span_hours:float ->
  now:float ->
  turn_span_stat ->
  bool

(** What the reader could establish about a required span.

    [Span_not_met] is an answer about the keeper: its readable history does
    not show the span. [Span_undetermined] is the absence of an answer: the
    segment head budget ended before the earliest turn row was reached, so
    the span is unknown rather than short.

    Both read [false] through {!has_persistent_turn_span_for}, which is
    correct for "was it proven" and wrong for any report that turns an
    unproven span into a keeper that failed to persist turns. *)
type span_reading =
  | Span_met
  | Span_not_met
  | Span_undetermined

val persistent_turn_span_reading :
  required_span_hours:float ->
  now:float ->
  turn_span_stat ->
  span_reading

val persistent_turn_window_hours : float
val recent_turn_max_age_hours : float
val persistence_tiers : persistence_tier list

val turn_span_evidence_json :
  now:float ->
  string ->
  turn_span_stat ->
  Yojson.Safe.t
