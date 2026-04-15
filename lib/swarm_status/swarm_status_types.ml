
module U = Yojson.Safe.Util

type lane_kind =
  | Managed
  | Projected
  | Supervised

(** Lane lifecycle phase — derived deterministically from lane metrics.
    Never deserialized from JSON; computed in [swarm_status_classify.lane_phase]. *)
type lane_phase =
  | Forming           (** No active operations or detachments *)
  | Dispatching       (** Active operations exist but no detachments yet *)
  | Executing         (** Detachments or workers are active *)
  | Blocked           (** Motion is stalled with no approvals pending *)
  | Awaiting_approval (** Manual approval is gating progress *)
  | Lane_completed    (** All operations terminal, no pending approvals *)

(** Lane motion state — freshness-based classification.
    Computed from timestamps in [swarm_status_classify.lane_motion_state]. *)
type lane_motion =
  | Waiting   (** Not present, or within stale window with no fresh signal *)
  | Moving    (** Fresh event within [moving_window_sec] *)
  | Stalled   (** No event within [stale_window_sec] *)
  | Terminal  (** Lane phase is [Lane_completed] *)

(** Flag severity — two-level classification for lane diagnostic flags. *)
type flag_severity = Flag_bad | Flag_warn

(** Flag code — closed set of diagnostic flag identifiers.
    Each flag is computed deterministically in [swarm_status_classify.lane_flags]. *)
type flag_code =
  | Projected_only
  | Missing_trace_events
  | Pending_manual_confirmation
  | Missing_worker_binding
  | Missing_runtime_progress
  | Stale_data
  | Dashboard_source_split

type flag = {
  code : flag_code;
  severity : flag_severity;
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
  kind : lane_kind;
  present : bool;
  phase : lane_phase;
  motion_state : lane_motion;
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

(** Operation lifecycle status — mirrors Cp_types.operation_status for the
    swarm_status read-only view. Parsed at JSON boundary in swarm_status_parse. *)
type swarm_operation_status =
  | SOp_active | SOp_planned | SOp_paused
  | SOp_completed | SOp_cancelled | SOp_failed

(** Detachment lifecycle status — mirrors Cp_types.detachment_status. *)
type swarm_detachment_status =
  | SDet_active | SDet_awaiting_approval | SDet_stalled
  | SDet_completed | SDet_cancelled | SDet_failed | SDet_stopped

(** Decision lifecycle status — mirrors Cp_types.decision_status. *)
type swarm_decision_status =
  | SDec_pending | SDec_approved | SDec_denied | SDec_expired

type operation_info = {
  operation_id : string;
  objective : string;
  source : string;
  status : swarm_operation_status;
  trace_id : string;
  detachment_session_id : string option;
  note : string option;
  updated_at : string option;
}

type detachment_info = {
  detachment_id : string;
  operation_id : string;
  source : string;
  status : swarm_detachment_status;
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
  status : swarm_decision_status;
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

(** Time window for "moving" (actively progressing) status.
    300s (5 min): A typical tool-call round trip (LLM inference 10-20s + tool
    execution 5-30s + network latency) completes within 1-2 minutes. 5 minutes
    accommodates 2-3 consecutive round trips without false "stalled" signals.
    If no event occurs within this window, the lane transitions to "waiting".
    Self-contained config (masc_swarm_status is below masc_config). *)
let moving_window_sec =
  match Sys.getenv_opt "MASC_SWARM_MOVING_WINDOW_SEC" with
  | Some s -> (try Float.max 30.0 (float_of_string s) with _ -> 300.0)
  | None -> 300.0

(** Time window for "stalled" (no activity, likely stuck) status.
    900s (15 min) = 3x moving_window. The 1:3 ratio mirrors common
    heartbeat:timeout conventions in distributed systems (e.g., Raft election
    timeouts are typically 5-10x heartbeat intervals). 15 minutes allows for
    one failed turn + retry + human think time before declaring "stalled". *)
let stale_window_sec = 900.0

(** Maximum timeline entries shown in dashboard swarm status.
    20 entries: fits comfortably in a dashboard panel without scrolling,
    while covering the last ~100 minutes of activity at typical event rates
    (1 event per 5 minutes). *)
let timeline_limit = 20
