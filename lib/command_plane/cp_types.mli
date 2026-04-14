module U = Yojson.Safe.Util

type unit_kind = Company | Platoon | Squad | Agent_unit
type policy_envelope = {
  policy_class : string;
  approval_class : string;
  tool_allowlist : string list;
  model_allowlist : string list;
  requires_human_for : string list;
  escalation_timeout_sec : int;
  kill_switch : bool;
  frozen : bool;
}
val tool_policy_of_envelope : policy_envelope -> Tool_access_policy.t
type budget_envelope = {
  headcount_cap : int;
  active_operation_cap : int;
  max_cost_usd : float;
  max_tokens : int;
}
type unit_record = {
  unit_id : string;
  label : string;
  kind : unit_kind;
  parent_unit_id : string option;
  leader_id : string option;
  roster : string list;
  capability_profile : string list;
  policy : policy_envelope;
  budget : budget_envelope;
  source : string;
  created_at : string;
  updated_at : string;
}
type operation_status =
    Planned
  | Active
  | Paused
  | Completed
  | Cancelled
  | Failed
type operation_record = {
  operation_id : string;
  objective : string;
  intent_id : string option;
  assigned_unit_id : string;
  policy_class : string;
  budget_class : string;
  workload_template : string option;
  workload_profile : string;
  stage : string option;
  artifact_scope : string list;
  depends_on_operation_ids : string list;
  search_strategy : string;
  detachment_session_id : string option;
  trace_id : string;
  checkpoint_ref : string option;
  active_goal_ids : string list;
  note : string option;
  created_by : string;
  source : string;
  status : operation_status;
  created_at : string;
  updated_at : string;
}
type intent_state =
    Adopted
  | Active_intent
  | Blocked_intent
  | Suspended_intent
  | Handoff_ready
  | Completed_intent
  | Dropped_intent
type intent_focus = {
  stage : string option;
  artifact_scope : string list;
  unit_id : string option;
  verification_state : string option;
}
type intent_record = {
  intent_id : string;
  title : string;
  owner : string;
  workload_profile : string;
  success_metric : Yojson.Safe.t option;
  invariants : string list;
  artifact_priors : string list;
  state : intent_state;
  current_focus : intent_focus;
  checkpoint_ref : string option;
  source : string;
  created_at : string;
  updated_at : string;
}
type event_record = {
  event_id : string;
  trace_id : string;
  event_type : string;
  operation_id : string option;
  unit_id : string option;
  actor : string option;
  source : string;
  ts : string;
  detail : Yojson.Safe.t;
}
type detachment_status =
  | Det_active
  | Det_awaiting_approval
  | Det_stalled
  | Det_completed
  | Det_cancelled
  | Det_failed
  | Det_stopped

type decision_status =
  | Dec_pending
  | Dec_approved
  | Dec_denied
  | Dec_expired

type detachment_record = {
  detachment_id : string;
  operation_id : string;
  assigned_unit_id : string;
  leader_id : string option;
  roster : string list;
  session_id : string option;
  checkpoint_ref : string option;
  runtime_kind : string option;
  runtime_ref : string option;
  source : string;
  status : detachment_status;
  last_event_at : string option;
  last_progress_at : string option;
  heartbeat_deadline : string option;
  created_at : string;
  updated_at : string;
}
type policy_decision_record = {
  decision_id : string;
  trace_id : string;
  requested_action : string;
  scope_type : string;
  scope_id : string;
  operation_id : string option;
  target_unit_id : string option;
  requested_by : string;
  status : decision_status;
  reason : string option;
  source : string;
  detail : Yojson.Safe.t;
  created_at : string;
  decided_at : string option;
  expires_at : string option;
}
type operation_status_counts = {
  planned_count : int;
  active_count : int;
  paused_count : int;
  completed_count : int;
  failed_count : int;
  cancelled_count : int;
}
type topology_summary = {
  total_units : int;
  company_count : int;
  platoon_count : int;
  squad_count : int;
  leaf_agent_unit_count : int;
  live_agent_count : int;
  managed_unit_count : int;
  active_operation_count : int;
  stale_unit_count : int;
  operation_status_counts : operation_status_counts;
}
