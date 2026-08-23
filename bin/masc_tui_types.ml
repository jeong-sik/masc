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
  | Message_thinking
      (** The reasoning of one autonomous turn as the transcript carried it:
          the lines the server kept and the count it withheld. Drawn with the
          live pane's thinking style, so a turn the keeper ran on its own and
          one watched live read alike. *)

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

(** Who put a post on the board. Mirrors [Board_types.post_kind]: the wire
    strings are ["direct"], ["automation"] and ["system"].

    Worth a column because of the ratio. On this workspace's 2171 posts:
    1561 system, 588 automation, and 22 that a person wrote. Without the
    distinction those 22 are buried in the other 2149 and the board reads as
    machine noise. *)
type board_post_kind =
  | Post_by_person
  | Post_by_automation
  | Post_by_system
  | Post_kind_unknown of string
      (** A kind this build was not taught. Named rather than folded into
          one of the others, so a new kind shows as unfamiliar instead of
          quietly becoming "system". *)

(** Board post (light projection for list view) *)
type board_post = {
  bp_id: string;
  bp_author: string;
  bp_title: string;
  bp_body: string;
  bp_votes: int;
  bp_comment_count: int;
  bp_created_at: string;
  bp_hearth: string option;
      (** The sub-board it lives in. 24 of them here, and 1550 of 2171 posts
          sit in [verification] alone — a flat list is 71% one topic with
          nothing saying so. *)
  bp_kind: board_post_kind option;
      (** [None] when the row did not say. Not folded into a kind: "the post
          did not state one" and "the post is a system post" are different
          facts, and only one of them is a claim about who wrote it. *)
}

(** Board comment *)
type board_comment = {
  bc_id: string;
  bc_author: string;
  bc_content: string;
  bc_created_at: string;
}

(** One scheduled-automation row, from the dashboard schedule projection.
    [sch_status] stays a string rather than a variant: the pane projects the
    store's own status vocabulary, and a status this build does not name
    renders as itself rather than disappearing. *)
type schedule_row = {
  sch_schedule_id: string;
  sch_status: string;
  sch_source: string;
  sch_due_at_iso: string option;
  sch_recurrence_summary: string;
  sch_payload_target: string option;
  sch_payload_summary: string option;
}

(** Schedule list snapshot. [scs_request_count] is [None] exactly when the
    store read failed -- the server reports that as [status = "unknown"]
    rather than an empty list, and the pane keeps the two facts apart the
    same way. *)
type schedule_snapshot = {
  scs_status: string;
  scs_read_error: string option;
  scs_request_count: int option;
  scs_truncated: bool;
  scs_next_due_iso: string option;
  scs_rows: schedule_row list;
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

(** What the runtime event feed ([GET /mcp?sse_kind=observer]) is doing.
    The feed is opened once the server has answered a refresh and reopened
    on the refresh cadence after it closes, so an operator reads the same
    row for "no server yet" and "the stream dropped" -- with the reason. *)
type observer_status =
  | Observer_off  (** not opened: no server has answered yet *)
  | Observer_opening  (** initialize and subscribe in flight *)
  | Observer_live of {
      session_id : string;
      since : float;
      events : int;  (** frames received on this stream *)
    }
  | Observer_closed of {
      reason : string;
      at : float;
      events : int;  (** frames the stream delivered before it closed *)
    }

(** One event off the feed, kept for the Acting surface. *)
type acting_entry = {
  ae_at : float;  (** when the TUI received it *)
  ae_event : Masc_tui_observer.event;
}

(* How many feed events the TUI keeps. On the live runtime the feed ran at
   about four events a second, so this is a few minutes of scrollback; what
   falls off the end is counted in [acting_dropped], not lost in silence. *)
let acting_retained_entries = 1000

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
  | Keeper_calls
  | Keeper_message

(** Top-level TUI surface. *)
type surface =
  | Overview
  | Acting
  | Keepers of keeper_mode
  | Board
  | Approvals
  | Planning
  | Schedules
  | Verification
  | Harness
  | Repositories
  | Connectors
  | Tools
  | Autonomy
  | System_logs

(** What a surface needs loaded to draw itself.

    Declared per surface in one place rather than asked as a separate
    exhaustive match per datum: a surface added later answers every question
    at once, in a record the compiler makes it fill, instead of being spelled
    into one match per fetch and quietly defaulting to false in the one that
    was missed. *)
type surface_needs = {
  needs_transport : bool;
  needs_keeper_roster : bool;
}

let surface_needs : surface -> surface_needs = function
  | Overview -> { needs_transport = true; needs_keeper_roster = false }
  | Acting -> { needs_transport = false; needs_keeper_roster = false }
  | Keepers _ -> { needs_transport = false; needs_keeper_roster = true }
  | Board | Approvals | Planning | Schedules | Verification | Harness
  | Repositories | Connectors | Tools | Autonomy | System_logs ->
      { needs_transport = false; needs_keeper_roster = false }

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
  mutable keeper_calls: Tui_decode.keeper_calls_snapshot option;
  mutable keeper_calls_error: string option;
  mutable keeper_calls_scroll: int;
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
  (* The compose draft and its send arm. The arm is the operator's explicit
     answer to "publish what is typed": while it is unset, esc re-offers
     send-or-discard and no other key can send. [board_compose_reply_to]
     names what a sent draft answers -- [None] publishes a new post,
     [Some post_id] adds a comment to that post -- so one pane covers both
     writes and the payload alone decides which. *)
  mutable board_draft: Buffer.t;
  mutable board_compose_armed: bool;
  mutable board_compose_reply_to: string option;
  mutable board_post_error: string option;
  (* A vote armed for a second keypress: which post, and up or down. The
     cursor can move between the two presses, so the post id is captured at
     arm time and a press on a different row re-arms for that row. *)
  mutable board_vote_armed: (string * bool) option;
  mutable planning: planning_snapshot option;
  mutable planning_error: string option;
  mutable planning_cursor: int;
  mutable planning_scroll: int;
  mutable planning_mode: planning_mode;
  (* A goal lifecycle request armed for a second keypress, and what the last
     one answered. Arming rather than pressing keeps the detail view's plain
     letters safe: c/x/o are lifecycle only once, and any other key disarms. *)
  mutable goal_action_armed:
    (string * Goal_phase.Public_action.t) option;
  mutable goal_action_error: string option;
  (* The schedule list and its cursor. The snapshot keeps the server's
     ok/unknown split so a failed store read never draws as "no schedules". *)
  mutable schedules: schedule_snapshot option;
  mutable schedules_error: string option;
  mutable schedule_cursor: int;
  mutable schedule_scroll: int;
  (* A cancel armed for a second keypress: which schedule. The cursor can move
     between the two presses, so the schedule id is captured at arm time and a
     press on a different row re-arms for that row. *)
  mutable schedule_cancel_armed: string option;
  mutable schedule_cancel_error: string option;
  (* What is waiting on a verdict. Loaded when the surface is opened rather
     than on every refresh: it is a queue an operator visits, not a number the
     other surfaces read. *)
  mutable tools_inventory: Tui_decode.tool_snapshot option;
  mutable tools_error: string option;
  mutable tools_scroll: int;
  mutable connectors: Tui_decode.connector_snapshot option;
  mutable connectors_error: string option;
  mutable connectors_scroll: int;
  mutable repositories: Tui_decode.repository_snapshot option;
  mutable repositories_error: string option;
  mutable repositories_scroll: int;
  mutable harness: Tui_decode.harness_snapshot option;
  mutable harness_error: string option;
  mutable harness_scroll: int;
  (* The feature-proof reading. Kept beside its error rather than collapsed
     into an option: a report that failed to load must not draw as a report
     with no features, which reads as "nothing is proven". *)
  mutable autonomy: Tui_decode.autonomy_snapshot option;
  mutable autonomy_error: string option;
  mutable autonomy_scroll: int;
  mutable observer: observer_status;
  mutable mcp_session: string option;
      (** The MCP session the server issued, kept across streams: the server
          holds it after a stream closes, so reopening the feed and calling
          tools reuse it rather than minting one per attempt. Cleared when
          the server refuses it. *)
  mutable acting: acting_entry list;  (** newest first, at most [acting_retained_entries] *)
  mutable acting_dropped: int;  (** events that fell off the end of [acting] *)
  mutable acting_undecodable: int;  (** frames the feed reader could not read *)
  mutable acting_undecodable_last: string option;  (** why, for the most recent one *)
  mutable acting_scroll: int;  (** rows from the newest, 0 = pinned to the newest *)
  mutable acting_unseen: int;  (** events that arrived while scrolled away from the newest *)
  mutable acting_filter: Masc_tui_acting.filter;
  mutable verification: Tui_decode.verification_snapshot option;
  mutable verification_error: string option;
  mutable verification_scroll: int;
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
  (* One request per keeper, not one per workspace. Dispatch used to be
     serialized on a single slot because the durable recovery fence held one
     un-acknowledged POST for the whole workspace; with that gone the only
     reason left is per keeper, which is how the server runs turns anyway. *)
  mutable msg_inflight: Masc_tui_keeper_chat_projection.request list;
  mutable detail_scroll: int;
  workspace: string;
  port: int;
  refresh_interval: float;
}

(* One reading of the state for both the send path and the footer; the order
   and the reasoning live in [Masc_tui_send_disposition]. *)
type send_disposition =
  Masc_tui_keeper_chat_projection.request Masc_tui_send_disposition.t

(* The keeper the composer is pointed at, since a turn running for another
   keeper does not decide what Enter does here. *)
let inflight_for_keeper state keeper_name =
  List.find_opt
    (fun (request : Masc_tui_keeper_chat_projection.request) ->
      String.equal request.keeper_name keeper_name)
    state.msg_inflight
;;

(* [prepared], [cleanup_pending], [recovery_blocked] and [unverified] were the
   durable chat fence's states. The fence is gone — the server refuses a second
   submission of the same request id, so the client does not carry its own —
   and with it those four are always absent. Passed as [None] rather than
   removed from the vocabulary: this module's ordering contract is what makes
   the footer and the send path agree, and narrowing it is a separate change
   from removing the states it ranked. *)
let send_disposition state ~keeper_name : send_disposition =
  Masc_tui_send_disposition.of_state ~prepared:None ~cleanup_pending:None
    ~recovery_blocked:None
    ~inflight:(inflight_for_keeper state keeper_name)
    ~unverified:None

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

(** Whether a goal lifecycle arm targets this goal. Answered here rather
    than at the renderer so the renderer never reads [pg_id] outside
    [Terminal_text] -- the sanitize guard counts every access, comparison
    included. *)
let goal_action_armed_for (state : state) (goal_id : string) =
  match state.goal_action_armed with
  | Some (armed_goal, armed_action) when String.equal armed_goal goal_id ->
      Some armed_action
  | Some _ | None -> None

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
  keeper_calls = None;
  keeper_calls_error = None;
  keeper_calls_scroll = 0;
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
  board_compose_reply_to = None;
  board_post_error = None;
  board_vote_armed = None;
  planning = None;
  planning_error = None;
  planning_cursor = 0;
  planning_scroll = 0;
  planning_mode = Planning_list;
  goal_action_armed = None;
  goal_action_error = None;
  schedules = None;
  schedules_error = None;
  schedule_cursor = 0;
  schedule_scroll = 0;
  schedule_cancel_armed = None;
  schedule_cancel_error = None;
  system_logs = None;
  system_logs_error = None;
  tools_inventory = None;
  tools_error = None;
  tools_scroll = 0;
  connectors = None;
  connectors_error = None;
  connectors_scroll = 0;
  repositories = None;
  repositories_error = None;
  repositories_scroll = 0;
  harness = None;
  harness_error = None;
  harness_scroll = 0;
  autonomy = None;
  autonomy_error = None;
  autonomy_scroll = 0;
  observer = Observer_off;
  mcp_session = None;
  acting = [];
  acting_dropped = 0;
  acting_undecodable = 0;
  acting_undecodable_last = None;
  acting_scroll = 0;
  acting_unseen = 0;
  acting_filter = Masc_tui_acting.Actions;
  verification = None;
  verification_error = None;
  verification_scroll = 0;
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
  msg_inflight = [];
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
(* What a polled surface can say when it has no rows to draw. Three facts,
   not one: nothing has been read yet, the read failed, or the read came back
   with nothing. The first was drawn as the third -- "nothing waiting on a
   verdict" on a Verification surface that had not yet asked -- so an
   operator read an empty queue off a screen that knew no queue at all. *)
type empty_page =
  | Page_unread
  | Page_failed
  | Page_empty

let empty_page_of ~snapshot ~error =
  match (snapshot, error) with
  | _, Some _ -> Page_failed
  | None, None -> Page_unread
  | Some _, None -> Page_empty

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
  List.length state.msg_inflight
  + unavailable_target
  + (match state.msg_live with
     | None -> 0
     | Some live ->
         (* Same call the drawing makes, so the budget cannot count a
            different number of rows than the pane draws. The age in the
            progress row changes the text, never the row count, so the
            two clock reads cannot disagree on the number. *)
         List.length
           (Masc_tui_keeper_chat_transcript.status_rows
              ~now:(Unix.gettimeofday ()) live))
  (* One row per waiting line, drawn in full so an operator can see which
     lines are held. Same call the pane makes, for the same reason as the
     live rows above: a row that is drawn and not counted pushes the frame
     past the terminal, and the presenter drops whatever ran off the bottom. *)
  + List.length (Masc_tui_keeper_chat_queue.waiting state.msg_queued)
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
