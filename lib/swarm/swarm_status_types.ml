
module U = Yojson.Safe.Util

type lane_kind =
  | Managed
  | Projected
  | Supervised

type flag = {
  code : string;
  severity : string;
  summary : string;
}

type timeline_event = {
  event_id : string;
  lane_id : string;
  kind : string;
  timestamp : string;
  title : string;
  detail : string;
  tone : string;
  source : string;
}

type lane = {
  lane_id : string;
  label : string;
  kind : string;
  present : bool;
  phase : string;
  motion_state : string;
  source_of_truth : string;
  last_movement_at : string option;
  movement_reason : string;
  current_step : string;
  blockers : string list;
  operations : int;
  detachments : int;
  workers : int;
  approvals : int;
  alerts : int;
  hard_flags : flag list;
}

type recommendation = {
  tool : string;
  label : string;
  reason : string;
  lane_id : string option;
}

type operation_info = {
  operation_id : string;
  objective : string;
  source : string;
  status : string;
  trace_id : string;
  detachment_session_id : string option;
  note : string option;
  updated_at : string option;
}

type detachment_info = {
  detachment_id : string;
  operation_id : string;
  source : string;
  status : string;
  runtime_kind : string option;
  session_id : string option;
  roster : string list;
  leader_id : string option;
  last_event_at : string option;
  last_progress_at : string option;
  updated_at : string option;
}

type alert_info = {
  alert_id : string;
  severity : string;
  scope_type : string option;
  scope_id : string option;
  title : string option;
  detail : string option;
  timestamp : string option;
}

type decision_info = {
  decision_id : string;
  source : string;
  status : string;
  scope_type : string option;
  scope_id : string option;
  operation_id : string option;
  requested_action : string option;
  created_at : string option;
}

type trace_info = {
  event_id : string;
  event_type : string;
  source : string;
  trace_id : string;
  operation_id : string option;
  actor : string option;
  timestamp : string option;
  detail : Yojson.Safe.t;
}

type session_info = {
  session_id : string;
  goal : string;
  status : string;
  started_at : float;
  updated_at_iso : string;
  last_event_at : string option;
  last_turn_at : string option;
  worker_names : string list;
  min_agents_violation_streak : int;
  policy_violation_count : int;
}

let moving_window_sec = 300.0
let stale_window_sec = 900.0
let timeline_limit = 20
