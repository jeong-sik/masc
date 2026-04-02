type attention_item = {
  kind : string;
  severity : string;
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
  severity : string;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

type worker_card = {
  actor : string option;
  spawn_agent : string option;
  spawn_role : string option;
  spawn_model : string option;
  execution_scope : string option;
  worker_class : string option;
  parent_actor : string option;
  capsule_mode : string option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : string option;
  control_domain : string option;
  supervisor_actor : string option;
  task_profile : string option;
  risk_level : string option;
  routing_confidence : float option;
  routing_reason : string option;
  status : string;
  turn_count : int;
  empty_note_turn_count : int;
  has_turn : bool;
  last_turn_age_sec : int option;
  evidence_source : string;
  last_turn_ts_iso : string option;
}

type session_digest = {
  session_id : string;
  goal : string;
  status : string;
  health : string;
  scale_profile : string;
  planned_worker_count : int;
  active_agent_count : int;
  last_turn_age_sec : int option;
  control_profile : string;
  worker_class_counts : Yojson.Safe.t;
  runtime_pool_counts : Yojson.Safe.t;
  lane_counts : Yojson.Safe.t;
  controller_counts : Yojson.Safe.t;
  control_domain_counts : Yojson.Safe.t;
  task_profile_counts : Yojson.Safe.t;
  escalation_count : int;
  controller_tree : Yojson.Safe.t;
  lane_health : Yojson.Safe.t;
  confidence_heatmap : Yojson.Safe.t;
  context_pressure_by_lane : Yojson.Safe.t;
  intervention_counters : Yojson.Safe.t;
  local_runtime : Yojson.Safe.t;
  attention_items : attention_item list;
  recommended_actions : recommended_action list;
  worker_cards : worker_card list;
  risk_digest : Yojson.Safe.t;
}

val stalled_session_threshold_sec : float
val planned_worker_turn_grace_sec : float
val room_digest_session_limit : int

val severity_rank : string -> int
val compare_attention : attention_item -> attention_item -> int
val compare_recommendation : recommended_action -> recommended_action -> int
val compare_worker_card : worker_card -> worker_card -> int
val compare_session_digest : session_digest -> session_digest -> int

val attention_item_to_yojson : attention_item -> Yojson.Safe.t
val recommended_confirm_required : string -> bool
val recommended_action_to_yojson : actor:string -> recommended_action -> Yojson.Safe.t
val worker_card_to_yojson : worker_card -> Yojson.Safe.t

val spawn_batch_template_of_cards : worker_card list -> Yojson.Safe.t

val aggregate_worker_class_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_runtime_pool_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_lane_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_controller_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_control_domain_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_task_profile_counts : Team_session_types.session list -> Yojson.Safe.t
val aggregate_escalation_count : Team_session_types.session list -> int
val aggregate_all_worker_metrics :
  Team_session_types.session list ->
  Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t *
  Yojson.Safe.t * Yojson.Safe.t * int
val aggregated_local_runtime_json : Team_session_types.session list -> Yojson.Safe.t

val session_card_to_yojson : actor:string -> session_digest -> Yojson.Safe.t
val summary_of_attention_items : attention_item list -> Yojson.Safe.t
val dedup_recommendations : recommended_action list -> recommended_action list
val summary_of_recommendations : actor:string -> recommended_action list -> Yojson.Safe.t

val health_from_attention_items : attention_item list -> string
val normalize_team_health : string -> string

val build_worker_cards :
  session:Team_session_types.session ->
  events:Yojson.Safe.t list ->
  now:float ->
  worker_card list

val session_attention_items :
  session:Team_session_types.session ->
  events:Yojson.Safe.t list ->
  worker_cards:worker_card list ->
  now:float ->
  attention_item list

val session_recommendations :
  session:Team_session_types.session ->
  attentions:attention_item list ->
  worker_cards:worker_card list ->
  recommended_action list

val build_session_digest :
  ?status_json:Yojson.Safe.t ->
  Room.config ->
  Team_session_types.session ->
  now:float ->
  session_digest

val build_room_attention_items :
  ?command_plane_summary:Yojson.Safe.t ->
  Room.config ->
  attention_item list

val room_recommendations :
  ?command_plane_summary:Yojson.Safe.t ->
  Room.config ->
  recommended_action list

val normalize_digest_target_type :
  string option -> (string, string) result

val digest_json :
  ?actor:string ->
  ?target_type:string ->
  ?target_id:string ->
  ?include_workers:bool ->
  ?sessions:Team_session_types.session list ->
  ?command_plane_summary:Yojson.Safe.t ->
  ?swarm_status:Yojson.Safe.t ->
  'a Operator_pending_confirm.context ->
  (Yojson.Safe.t, string) result
