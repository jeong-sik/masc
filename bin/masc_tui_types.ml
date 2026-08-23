[@@@warning "-32-69"]
module Tui_decode = Masc.Tui_decode
module Metrics_tail = Masc_tui_metrics_tail

(** TUI shared types — split from masc_tui.ml (#3808) *)

(** Agent type with status (from Tui_decode) *)
type agent = Tui_decode.agent

(** Task type (from Tui_decode) *)
type task = Tui_decode.task

(** Event for the event log *)
(* The five states the refresh loop can put the TUI in. It was a string
   with a catch-all at each of the five render sites, so a typo rendered
   as [disconnected] and a new state would have too. *)
type connection_status =
  | Disconnected
  | Connecting
  | Reconnecting
  | Degraded
  | Connected

type event = {
  timestamp: string;
  event_type: string;
  content: string;
}

(** Keeper metadata (from Tui_decode) *)
type keeper = Tui_decode.keeper

(** A single metrics/log entry (from Tui_decode) *)
type log_entry = Tui_decode.log_entry

type msg_role =
  | Message_user
  | Message_keeper
  | Message_status
  | Message_error

(** Request-correlated message history entry. *)
type msg_entry = {
  me_role: msg_role;
  me_text: string;
  me_timestamp: string;
  me_keeper_name: string;
  me_request_id: string;
}

type msg_recovery_error = Recovery_blocked of string

type msg_inflight_kind =
  | Dispatch_claim
  | Chat_post
  | Operation_get
  | Cleanup_delete

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

(** Actor-scoped pending confirmation from the exact operator projection. *)
type approval_item = Masc_tui_operator_projection.approval_item
  = {
  ap_token: string;
  ap_trace_id: string;
  ap_actor: string;
  ap_action_type: string;
  ap_target_type: string;
  ap_target_id: string option;
  ap_payload: Yojson.Safe.t;
  ap_delegated_tool: string;
  ap_created_at: string;
  ap_expires_at: string option;
  ap_summary: string;
}

type approval_snapshot = Masc_tui_operator_projection.approval_snapshot
  = {
  aps_items: approval_item list;
  aps_actor_filter: string option;
  aps_filter_active: bool;
  aps_visible_count: int;
  aps_total_count: int;
  aps_hidden_count: int;
}

type approval_decision = Masc_tui_operator_projection.approval_decision =
  | Confirm
  | Deny

type pending_approval_action = Masc_tui_operator_projection.pending_approval_action = {
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
  ov_incident_count: int;
  ov_attention_items: attention_item list;
  ov_top_attention: attention_item option;
  ov_generated_at: string;
}

(** Planning projections from [Tui_decode], which owns the current wire
    contract and its behavioral decoder tests. *)
type planning_goal = Tui_decode.planning_goal
  = {
  pg_id: string;
  pg_title: string;
  pg_phase: Goal_phase.t;
  pg_priority: int;
  pg_due_date: string option;
  pg_metric: string option;
  pg_target_value: string option;
}

type planning_rollup = Tui_decode.planning_rollup
  = {
  pr_active: int;
  pr_paused: int;
  pr_verifying: int;
  pr_done: int;
  pr_dropped: int;
}

type planning_backlog = Tui_decode.planning_backlog
  = {
  pb_todo: int;
  pb_claimed: int;
  pb_running: int;
  pb_done: int;
  pb_cancelled: int;
}

type planning_snapshot = Tui_decode.planning_snapshot
  = {
  pl_goals: planning_goal list;
  pl_rollup: planning_rollup;
  pl_backlog: planning_backlog;
  pl_generated_at: string;
}

(* Goals no longer nest, so every goal sits at depth 0. *)
let planning_goal_depth (_goals : planning_goal list) (_goal : planning_goal) = 0

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
  | Dashboard_chat

(** Dashboard state *)
type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  mutable tasks_error: string option;
  mutable events: event list;
  mutable overview_event_scroll: int;
  mutable keepers: keeper list;
  mutable keepers_error: string option;
  mutable connection_status: connection_status;
  mutable last_refresh: float;
  mutable view: surface;
  mutable keeper_cursor: int;
  mutable log_entries: log_entry list;
  mutable log_error: Metrics_tail.load_error option;
  mutable log_scroll: int;
  mutable live_context: Tui_decode.context_observation option;
  mutable live_context_error: string option;
  mutable overview: overview_snapshot option;
  mutable overview_error: string option;
  mutable approval_snapshot: approval_snapshot option;
  mutable approvals_error: string option;
  mutable approval_flow: Masc_tui_operator_projection.Flow.t;
  mutable approval_cursor: int;
  mutable pending_approval_action: pending_approval_action option;
  mutable board_posts: board_post list;
  mutable board_detail:
    (board_post * board_comment list) Masc_tui_board_detail.t;
  mutable board_list_error: string option;
  mutable board_cursor: int;
  mutable board_scroll: int;
  mutable board_mode: board_mode;
  mutable planning: planning_snapshot option;
  mutable planning_error: string option;
  mutable planning_cursor: int;
  mutable planning_scroll: int;
  mutable planning_mode: planning_mode;
  mutable msg_input: Buffer.t;
  mutable msg_target_keeper_name: string option;
  mutable msg_drafts: (string * string) list;
  mutable msg_history: msg_entry list;
  mutable msg_inflight: Masc_tui_keeper_chat_projection.request option;
  mutable msg_inflight_kind: msg_inflight_kind option;
  mutable msg_prepared: Masc_tui_keeper_chat_projection.request option;
  mutable msg_unverified: Masc_tui_keeper_chat_projection.request option;
  mutable msg_cleanup_pending: Masc_tui_keeper_chat_projection.request option;
  mutable msg_recovery_error: msg_recovery_error option;
  mutable detail_scroll: int;
  workspace: string;
  port: int;
  refresh_interval: float;
}

(** New Keeper messages require a complete roster observation. [state.keepers]
    may intentionally retain the previous complete roster while a detail or log
    view survives a transient metadata read failure, so membership alone is not
    authorization for an external effect. *)
let keeper_available_for_new_message (state : state) keeper_name =
  Option.is_none state.keepers_error
  && List.exists
       (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
       state.keepers

(** Create initial state *)
let create_state ~workspace ~port ~refresh_interval = {
  agents = [];
  tasks = [];
  tasks_error = None;
  events = [];
  overview_event_scroll = 0;
  keepers = [];
  keepers_error = None;
  connection_status = Disconnected;
  last_refresh = 0.0;
  view = Overview;
  keeper_cursor = 0;
  log_entries = [];
  log_error = None;
  log_scroll = 0;
  live_context = None;
  live_context_error = None;
  overview = None;
  overview_error = None;
  approval_snapshot = None;
  approvals_error = None;
  approval_flow = Masc_tui_operator_projection.Flow.initial;
  approval_cursor = 0;
  pending_approval_action = None;
  board_posts = [];
  board_detail = Masc_tui_board_detail.initial;
  board_list_error = None;
  board_cursor = 0;
  board_scroll = 0;
  board_mode = Board_list;
  planning = None;
  planning_error = None;
  planning_cursor = 0;
  planning_scroll = 0;
  planning_mode = Planning_list;
  msg_input = Buffer.create 256;
  msg_target_keeper_name = None;
  msg_drafts = [];
  msg_history = [];
  msg_inflight = None;
  msg_inflight_kind = None;
  msg_prepared = None;
  msg_unverified = None;
  msg_cleanup_pending = None;
  msg_recovery_error = None;
  detail_scroll = 0;
  workspace;
  port;
  refresh_interval;
}

(* The row the renderer draws and the row this counts have to come from one
   predicate. A roster that failed to load leaves stale entries behind, so
   "registered" answers true while the send path is closed; counting on that
   answer hid the unavailable row and left the send hint reading Enter:send. *)
let keeper_message_status_rows (state : state) =
  let unavailable_target =
    match state.msg_target_keeper_name with
    | Some keeper_name when keeper_available_for_new_message state keeper_name
      -> 0
    | Some _ | None -> 1
  in
  (if Option.is_some state.msg_inflight then 1 else 0)
  + (if Option.is_none state.msg_inflight && Option.is_some state.msg_prepared
     then 1
     else 0)
  + (if Option.is_some state.msg_unverified then 1 else 0)
  + (if Option.is_some state.msg_cleanup_pending then 1 else 0)
  + (if Option.is_some state.msg_recovery_error then 1 else 0)
  + unavailable_target

let approval_items (state : state) =
  match state.approval_snapshot with
  | Some snapshot -> snapshot.aps_items
  | None -> []
