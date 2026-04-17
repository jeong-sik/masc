type operator_severity = Sev_critical | Sev_bad | Sev_warn

val operator_severity_to_string : operator_severity -> string
val operator_severity_of_string : string -> operator_severity
val operator_severity_of_failure_envelope :
  Failure_envelope.severity -> operator_severity

type attention_item = {
  kind : string;
  severity : operator_severity;
  summary : string;
  target_type : string;
  target_id : string option;
  actor : string option;
  evidence : Yojson.Safe.t;
}

type recommended_action = {
  action_type : string;
  target_type : string;
  target_id : string option;
  severity : operator_severity;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

val severity_rank : operator_severity -> int
val compare_attention : attention_item -> attention_item -> int
val compare_recommendation : recommended_action -> recommended_action -> int

val attention_item_to_yojson : attention_item -> Yojson.Safe.t
val recommended_confirm_required : string -> bool
val recommended_action_to_yojson : actor:string -> recommended_action -> Yojson.Safe.t

val summary_of_attention_items : attention_item list -> Yojson.Safe.t
val dedup_recommendations : recommended_action list -> recommended_action list
val summary_of_recommendations : actor:string -> recommended_action list -> Yojson.Safe.t

val health_from_attention_items : attention_item list -> string
val normalize_team_health : string -> string

val build_room_attention_items : Coord.config -> attention_item list

val room_recommendations : Coord.config -> recommended_action list

val normalize_digest_target_type :
  string option -> (string, string) result

val digest_json :
  ?actor:string ->
  ?target_type:string ->
  ?target_id:string ->
  ?include_workers:bool ->
  'a Operator_pending_confirm.context ->
  (Yojson.Safe.t, string) result
