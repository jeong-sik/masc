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
type keeper_runtime = Tui_decode.keeper_runtime

(** A single metrics/log entry (from Tui_decode) *)
type log_entry = Tui_decode.log_entry

type msg_role =
  | Message_user of string
      (** A row addressed to the keeper, carrying the name to draw beside it.
          ["you"] for what this pane sent; otherwise whoever the server named,
          with the surface it arrived on. The role alone used to be the label,
          which is why an agent's broadcast and the operator's own line were
          indistinguishable. *)
  | Message_keeper
  | Message_status
  | Message_error
  | Message_tool
      (** The tool calls of one finished turn, as the row block the live pane
          drew while it ran. The strict stream decode carries no tool
          information, so without this a turn that read six files and edited
          two scrolls back looking like one answered from memory. *)

(** Request-correlated message history entry. *)
type msg_entry = {
  me_role: msg_role;
  me_text: string;
  me_timestamp: string;
  me_keeper_name: string;
  me_request_id: string;
  (* Unix time, the key the pane orders by. The durable transcript and this
     session's own notices are two sources of rows and neither knows the
     other's positions, so they are merged on a shared clock rather than
     concatenated. [me_timestamp] is a wall-clock string for display and
     cannot serve: it has no date and does not sort across midnight. *)
  me_at: float;
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
  | Board_compose
      (** New-post draft. The first line of the draft is the title, the rest
          is the body -- the commit-message convention, so one buffer covers
          both fields and no second input mode is needed. Sending is a
          two-step arm, not a key: [esc] offers send-or-discard, so a stray
          Enter during writing cannot publish. *)

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
type system_log_snapshot = Tui_decode.system_log_snapshot
type system_log_entry = Tui_decode.system_log_entry

type planning_goal = Tui_decode.planning_goal
  = {
  pg_id: string;
  pg_title: string;
  pg_phase: Goal_phase.t;
  pg_priority: int;
  pg_due_date: string option;
  pg_metric: string option;
  pg_target_value: string option;
  pg_proof: Tui_decode.goal_proof;
  pg_last_review_note: string option;
}

type planning_rollup = Tui_decode.planning_rollup
  = {
  pr_active: int;
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

type fleet_safety = Tui_decode.fleet_safety
  = {
  fs_status: string;
  fs_blocker: string option;
  fs_operator_action_required: bool;
  fs_bootable_count: int;
  fs_running_count: int;
  fs_executable_count: int;
  fs_failing_count: int;
  fs_recovering_count: int;
  fs_paused_count: int;
  fs_target_reaction_capacity: int;
  fs_reaction_capacity_shortfall: int;
  fs_bootable_names: string list;
  fs_running_names: string list;
  fs_executable_names: string list;
  fs_active_task_owner_without_fiber_count: int;
  fs_completion_authority_pending_count: int;
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
  | System_logs

(** Dashboard state *)
type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  (* The full domain rows the Overview list is projected from, kept so the
     detail view can show a task after it turns terminal -- the active list
     drops exactly those rows. Replaced wholesale with [tasks] on each load. *)
  mutable tasks_domain: Masc_domain.task list;
  mutable task_focus: bool;
  mutable task_cursor: int;
  mutable task_detail_id: string option;
  mutable task_detail_scroll: int;
  mutable tasks_error: string option;
  mutable events: event list;
  mutable overview_event_scroll: int;
  mutable keepers: keeper list;
  mutable keepers_error: string option;
  (* The live roster reading, separate from the durable one above: it answers
     whether a keepalive fiber is running each keeper, which metadata on disk
     cannot. It is typed rather than a plain list because "the roster did not
     arrive" and "the roster arrived without this keeper" license different
     lifecycle actions. *)
  mutable keeper_roster: Masc_tui_keeper_control.roster;
  mutable keeper_roster_error: string option;
  mutable keeper_action_inflight:
    (string * Masc_tui_keeper_control.action) option;
  mutable keeper_action_pending: Masc_tui_keeper_control.pending option;
  mutable keeper_action_serial: int;
  (* The composer occupies the last terminal row on every surface. It is drawn
     whether or not it holds the keystrokes: an input line that appears only
     once it is already receiving text cannot be found by looking. Focus is
     what routes keys into it, and the operator takes and releases that. *)
  mutable composer_focused: bool;
  (* The keeper list holds one row per running keeper, so a keeper that failed
     to start is absent from it rather than shown as failed. This carries the
     fleet's own reading of what is missing. *)
  mutable fleet_safety: fleet_safety option;
  mutable fleet_safety_error: string option;
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
  mutable transport: Tui_decode.transport_health option;
  mutable transport_error: string option;
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
  (* The new-post draft and its send arm. The arm is the operator's explicit
     answer to "publish what is typed": while it is unset, esc re-offers
     send-or-discard and no other key can send. *)
  mutable board_draft: Buffer.t;
  mutable board_compose_armed: bool;
  mutable board_post_error: string option;
  mutable planning: planning_snapshot option;
  mutable planning_error: string option;
  mutable planning_cursor: int;
  mutable planning_scroll: int;
  mutable planning_mode: planning_mode;
  mutable system_logs: system_log_snapshot option;
  mutable system_logs_error: string option;
  mutable system_logs_scroll: int;
  mutable msg_input: Buffer.t;
  mutable msg_target_keeper_name: string option;
  mutable msg_drafts: (string * string) list;
  mutable msg_history: msg_entry list;
  (* The turn currently streaming, if any. Drawn below the history and
     discarded when the turn settles; its tool rows are committed to the
     history first. Never authoritative -- the recorded reply comes from the
     strict whole-body decode. *)
  mutable msg_live: Masc_tui_keeper_chat_transcript.t option;
  (* The keeper's durable transcript as last loaded, for the keeper the pane is
     showing. Replaced wholesale by a load rather than merged: the server holds
     the record of what was said, and reconciling two copies of it row by row
     needs an identity the two do not share. *)
  mutable msg_loaded: msg_entry list;
  mutable msg_loaded_keeper: string option;
  mutable msg_loaded_error: string option;
  mutable msg_loaded_dropped: int;
  (* How many rows above the newest the chat pane is showing. 0 is the bottom,
     where the pane follows a running turn. Held rather than derived: an
     operator reading back should stay where they are while the keeper keeps
     talking. *)
  mutable msg_scroll: int;
  (* Where the next older page starts, and whether one exists. Both come from
     the server rather than being derived here: it owns the rule for what
     "older than this" means across rows that share a timestamp. None with
     [msg_older_exist] true means the pane has not learned a cursor yet. *)
  mutable msg_older_cursor: float option;
  mutable msg_older_exist: bool;
  mutable msg_older_loading: bool;
  mutable msg_older_error: string option;
  (* Messages typed while a turn was running, oldest first, each with the
     keeper it was addressed to. Dispatch is serialized on one in-flight
     request, so a second Enter used to be answered with "already in progress"
     and the text was gone. Holding it and sending it when the turn settles is
     what every other agent console does, and it is what an operator means by
     pressing Enter twice.

     The keeper travels with the text because the operator can switch keepers
     while a turn runs; sending a queued line to whoever happens to be selected
     later would put it in front of the wrong keeper. *)
  mutable msg_queued: Masc_tui_keeper_chat_queue.t;
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

(** One keeper as the Keepers surface reads it: durable pause from the
    metadata row, live runtime from the roster. *)
let keeper_reading (state : state) (keeper : keeper) :
    Masc_tui_keeper_control.reading =
  { name = keeper.k_name
  ; paused = keeper.k_paused
  ; liveness =
      Masc_tui_keeper_control.liveness_of_roster state.keeper_roster
        keeper.k_name
  }

let selected_keeper (state : state) =
  List.nth_opt state.keepers state.keeper_cursor

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
  tasks_domain = [];
  task_focus = false;
  task_cursor = 0;
  task_detail_id = None;
  task_detail_scroll = 0;
  tasks_error = None;
  events = [];
  overview_event_scroll = 0;
  keepers = [];
  keepers_error = None;
  keeper_roster = Masc_tui_keeper_control.Roster_unobserved;
  keeper_roster_error = None;
  keeper_action_inflight = None;
  keeper_action_pending = None;
  keeper_action_serial = 0;
  composer_focused = false;
  fleet_safety = None;
  fleet_safety_error = None;
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
  transport = None;
  transport_error = None;
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
  board_draft = Buffer.create 256;
  board_compose_armed = false;
  board_post_error = None;
  planning = None;
  planning_error = None;
  planning_cursor = 0;
  planning_scroll = 0;
  planning_mode = Planning_list;
  system_logs = None;
  system_logs_error = None;
  system_logs_scroll = 0;
  msg_input = Buffer.create 256;
  msg_target_keeper_name = None;
  msg_drafts = [];
  msg_history = [];
  msg_live = None;
  msg_loaded = [];
  msg_loaded_keeper = None;
  msg_loaded_error = None;
  msg_loaded_dropped = 0;
  msg_scroll = 0;
  msg_older_cursor = None;
  msg_older_exist = false;
  msg_older_loading = false;
  msg_older_error = None;
  msg_queued = Masc_tui_keeper_chat_queue.empty;
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
(* The rows the chat pane draws for one keeper: the durable transcript as last
   loaded, plus this session's own rows, ordered on a shared clock. Two sources
   with no identity between them, so they are merged by time rather than
   concatenated -- a notice the TUI wrote belongs where it happened, not after
   everything the server knows about. Ties keep the loaded row first, which is
   what [stable_sort] over [loaded @ session] gives. *)
let chat_rows_for (state : state) keeper_name =
  let loaded =
    match state.msg_loaded_keeper with
    | Some loaded_keeper when String.equal loaded_keeper keeper_name ->
        state.msg_loaded
    | Some _ | None -> []
  in
  let session =
    List.filter
      (fun entry -> String.equal entry.me_keeper_name keeper_name)
      state.msg_history
  in
  List.stable_sort
    (fun left right -> Float.compare left.me_at right.me_at)
    (loaded @ session)

(* Rows the composer needs beyond its first. Folded into the status-row count
   because that one number already sets both the history height and the cursor
   row, so a composer that grew would otherwise push the cursor off the line it
   is editing. *)
let composer_extra_rows (state : state) =
  let lines =
    Masc_tui_message_layout.composer_lines
      ~max_rows:Masc_tui_message_layout.composer_max_rows
      (Buffer.contents state.msg_input)
  in
  max 0 (List.length lines - 1)

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
  + (match state.msg_live with
     | None -> 0
     | Some live ->
         List.length (Masc_tui_keeper_chat_transcript.status_rows live))
  + (if Option.is_some state.msg_loaded_error then 1 else 0)
  + (if state.msg_loaded_dropped > 0 then 1 else 0)
  + (if state.msg_scroll > 0 then 1 else 0)
  + (if state.msg_older_loading || Option.is_some state.msg_older_error then 1
     else 0)
  + composer_extra_rows state

let approval_items (state : state) =
  match state.approval_snapshot with
  | Some snapshot -> snapshot.aps_items
  | None -> []
