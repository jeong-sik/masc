[@@@warning "-32-69"]
module Tui_decode = Masc.Tui_decode

(** TUI shared types — split from masc_tui.ml (#3808) *)

(** Agent type with status (from Tui_decode) *)
type agent = Tui_decode.agent

(** Task type (from Tui_decode) *)
type task = Tui_decode.task

(** Event for the event log *)
type event = {
  timestamp: string;
  event_type: string;
  content: string;
}

(** Keeper metadata (from Tui_decode) *)
type keeper = Tui_decode.keeper

(** A single metrics/log entry (from Tui_decode) *)
type log_entry = Tui_decode.log_entry

(** Message history entry *)
type msg_entry = {
  me_role: string;
  me_text: string;
  me_timestamp: string;
}

(** Attention item for the Overview surface *)
type attention_severity =
  | Attention_critical
  | Attention_bad
  | Attention_warning
  | Attention_info

type attention_item = {
  ai_kind: string;
  ai_severity: attention_severity;
  ai_summary: string;
  ai_target_type: string;
  ai_target_id: string option;
}

(** Board post (light projection for list view) *)
type board_post = {
  bp_id: string;
  bp_author: string;
  bp_title: string;
  bp_body: string;
  bp_votes: int;
  bp_comment_count: int;
  bp_created_at: string;
}

(** Board comment *)
type board_comment = {
  bc_id: string;
  bc_author: string;
  bc_content: string;
  bc_created_at: string;
}

(** Board surface sub-mode *)
type board_mode =
  | Board_list
  | Board_read of string

(** Planning surface sub-mode *)
type planning_mode =
  | Planning_list
  | Planning_detail of string

(** Goal status from /api/v1/dashboard/planning. Unknown wire values are
    rejected at decode time so the renderer cannot silently dim a new state. *)
type planning_goal_status =
  | Planning_goal_active
  | Planning_goal_paused
  | Planning_goal_done
  | Planning_goal_dropped

(** Approval / pending confirmation item *)
type approval_item = {
  ap_token: string;
  ap_actor: string;
  ap_action_type: string;
  ap_target_type: string;
  ap_target_id: string option;
  ap_delegated_tool: string;
  ap_summary: string;
}

type approval_decision =
  | Confirm
  | Deny

type pending_approval_action = {
  paa_token: string;
  paa_decision: approval_decision;
}

(** Overview snapshot from /api/v1/dashboard/briefing *)
type workspace_health =
  | Workspace_health_critical
  | Workspace_health_bad
  | Workspace_health_risk
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_ok
  | Workspace_health_unknown

type overview_snapshot = {
  ov_workspace_health: workspace_health;
  ov_cluster: string;
  ov_project: string;
  ov_active_agents: int;
  ov_pending_approvals: int;
  ov_incident_count: int;
  ov_attention_items: attention_item list;
  ov_top_attention: attention_item option;
  ov_pending_confirms: approval_item list;
  ov_generated_at: string;
}

(** Planning goal from /api/v1/dashboard/planning *)
type planning_goal = {
  pg_id: string;
  pg_title: string;
  pg_status: planning_goal_status;
  pg_phase: string;
  pg_priority: int;
  pg_due_date: string option;
  pg_parent_goal_id: string option;
  pg_metric: string option;
  pg_target_value: string option;
}

(** Planning rollup from /api/v1/dashboard/planning *)
type planning_rollup = {
  pr_active: int;
  pr_paused: int;
  pr_done: int;
  pr_dropped: int;
}

(** Planning task backlog summary *)
type planning_backlog = {
  pb_todo: int;
  pb_claimed: int;
  pb_running: int;
  pb_done: int;
  pb_cancelled: int;
}

(** Planning snapshot from /api/v1/dashboard/planning *)
type planning_snapshot = {
  pl_goals: planning_goal list;
  pl_rollup: planning_rollup;
  pl_backlog: planning_backlog;
  pl_generated_at: string;
}

let planning_goal_depth (goals : planning_goal list) (goal : planning_goal) =
  Tui_decode.bounded_parent_depth ~id_of:(fun g -> g.pg_id)
    ~parent_id_of:(fun g -> g.pg_parent_goal_id)
    goals goal

let planning_visible_goals (goals : planning_goal list) : planning_goal list =
  goals
  |> List.mapi (fun index goal -> (index, goal))
  |> List.stable_sort (fun (left_index, left_goal) (right_index, right_goal) ->
         match
           Int.compare
             (planning_goal_depth goals left_goal)
             (planning_goal_depth goals right_goal)
         with
         | 0 -> Int.compare left_index right_index
         | depth_cmp -> depth_cmp)
  |> List.map snd

(** Sub-mode inside the Keepers surface *)
type keeper_mode =
  | Keeper_list
  | Keeper_detail
  | Keeper_logs
  | Keeper_message

(** Top-level TUI surface. *)
type surface =
  | Overview
  | Keepers of keeper_mode
  | Board
  | Approvals
  | Planning

(** Backward-compatible alias. *)
type view_mode = surface

(** Dashboard state *)
type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  mutable events: event list;
  mutable keepers: keeper list;
  mutable connection_status: string;
  mutable last_refresh: float;
  mutable view: view_mode;
  mutable keeper_cursor: int;
  mutable log_entries: log_entry list;
  mutable log_scroll: int;
  mutable live_context_ratio: float;
  mutable live_context_tokens: int;
  mutable live_context_max: int;
  mutable live_message_count: int;
  mutable overview: overview_snapshot option;
  mutable overview_error: string option;
  mutable approval_cursor: int;
  mutable pending_approval_action: pending_approval_action option;
  mutable board_posts: board_post list;
  mutable board_comments: board_comment list;
  mutable board_error: string option;
  mutable board_cursor: int;
  mutable board_scroll: int;
  mutable board_mode: board_mode;
  mutable planning: planning_snapshot option;
  mutable planning_error: string option;
  mutable planning_cursor: int;
  mutable planning_scroll: int;
  mutable planning_mode: planning_mode;
  mutable msg_input: Buffer.t;
  mutable msg_history: msg_entry list;
  mutable msg_sending: bool;
  mutable detail_scroll: int;
  workspace: string;
  port: int;
  refresh_interval: float;
}

(** Create initial state *)
let create_state ~workspace ~port ~refresh_interval = {
  agents = [];
  tasks = [];
  events = [];
  keepers = [];
  connection_status = "disconnected";
  last_refresh = 0.0;
  view = Overview;
  keeper_cursor = 0;
  log_entries = [];
  log_scroll = 0;
  live_context_ratio = 0.0;
  live_context_tokens = 0;
  live_context_max = 0;
  live_message_count = 0;
  overview = None;
  overview_error = None;
  approval_cursor = 0;
  pending_approval_action = None;
  board_posts = [];
  board_comments = [];
  board_error = None;
  board_cursor = 0;
  board_scroll = 0;
  board_mode = Board_list;
  planning = None;
  planning_error = None;
  planning_cursor = 0;
  planning_scroll = 0;
  planning_mode = Planning_list;
  msg_input = Buffer.create 256;
  msg_history = [];
  msg_sending = false;
  detail_scroll = 0;
  workspace;
  port;
  refresh_interval;
}
