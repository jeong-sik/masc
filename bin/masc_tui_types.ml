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

(** One authority for the Fusion surface's list/detail state. The top-level
    [surface] only says Fusion is open; it does not repeat this mode. *)
type fusion_mode =
  | Fusion_list
  | Fusion_detail of string

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
  ov_keepers: int;  (** [keeper_briefs] the briefing carried *)
  ov_mcp_agents: int;  (** [agent_briefs]: MCP clients, not keepers *)
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
  | Keeper_runtime_pick
      (** Choosing a runtime for the keeper under the roster cursor. *)

(** Which face the detail pane is showing. Tabs inside one panel, cycled
    with [ and ]: different views of the same selected keeper, exactly the
    case a tab earns (unrelated content would want its own surface). *)
type keeper_detail_tab =
  | Detail_info
  | Detail_instructions
  | Detail_github

let keeper_detail_tabs = [ Detail_info; Detail_instructions; Detail_github ]

let keeper_detail_tab_label = function
  | Detail_info -> "Info"
  | Detail_instructions -> "Instructions"
  | Detail_github -> "GitHub"

(** Where [Esc] returns after the chat pane was opened. Keeping only the two
    legal destinations makes a new Keeper sub-view an explicit compiler error
    instead of silently becoming the detail view. *)
type keeper_chat_return =
  | Keeper_chat_return_list
  | Keeper_chat_return_detail

(** Top-level TUI surface. *)
(* A picture currently on the terminal. Only the drawn case: a refusal has
   nothing to draw, and putting one here would take the screen away from the
   frame to show a message the frame is the only thing that can show. Refusals
   go to the pane as text, like every other thing that did not happen. *)
type image_shown = {
  image_path : string;
  image_bytes : int;
}

type surface =
  | Overview
  | Acting
  | Keepers of keeper_mode
  | Lanes
  | Board
  | Approvals
  | Planning
  | Schedules
  | Verification
  | Harness
  | Fusion
  | Repositories
  | Changes
  | Connectors
  | Runtime
  | Config
  | Resources
  | Tools
  | System_logs

(* The Tab cycle and the strip drawn above every surface share this order,
   so the strip cannot disagree with where Tab actually goes. Labels are the
   strip's spelling; the Keepers entry stands for every keeper sub-mode. *)
let surface_ring : (surface * string) list =
  [ (Overview, "Overview");
    (Acting, "Acting");
    (Keepers Keeper_list, "Keepers");
    (Lanes, "Lanes");
    (Approvals, "Approvals");
    (Board, "Board");
    (Planning, "Planning");
    (Schedules, "Schedules");
    (Verification, "Verify");
    (Harness, "Harness");
    (Fusion, "Fusion");
    (Repositories, "Repos");
    (Changes, "Changes");
    (Connectors, "Connectors");
    (Runtime, "Runtime");
    (Config, "Config");
    (Resources, "Resources");
    (Tools, "Tools");
    (System_logs, "Logs");
  ]

(* Ring position of the family a view belongs to. Keeper sub-modes collapse
   onto the Keepers entry; every other surface is its own entry. *)
let surface_ring_index (view : surface) =
  let family = match view with Keepers _ -> Keepers Keeper_list | v -> v in
  let rec find i = function
    | [] -> 0
    | (surface, _) :: rest -> if surface = family then i else find (i + 1) rest
  in
  find 0 surface_ring

(** What a surface needs loaded to draw itself.

    Declared per surface in one place rather than asked as a separate
    exhaustive match per datum: a surface added later answers every question
    at once, in a record the compiler makes it fill, instead of being spelled
    into one match per fetch and quietly defaulting to false in the one that
    was missed. *)
type surface_needs = {
  needs_transport : bool;
  needs_keeper_roster : bool;
  needs_fleet_safety : bool;
  needs_board : bool;
  needs_planning : bool;
  needs_system_logs : bool;
  needs_keeper_chat : bool;
}

let nothing =
  { needs_transport = false;
    needs_keeper_roster = false;
    needs_fleet_safety = false;
    needs_board = false;
    needs_planning = false;
    needs_system_logs = false;
    needs_keeper_chat = false;
  }

(* Each datum is read by the one surface that draws it, so a refresh spends a
   request and a decode on it only while that surface is open. The planning and
   system-log payloads are tens of kilobytes each, and fetching them behind
   every other surface cost that on every tick for rows nobody was looking at. *)
let surface_needs : surface -> surface_needs = function
  | Overview -> { nothing with needs_transport = true }
  (* Its rows come from the acting store and the keeper list, neither of which
     is fetched here. *)
  | Acting -> nothing
  (* Exhaustive over the sub-mode rather than [Keepers _]: the chat pane is
     the one that was missed. It loaded its history when it opened and never
     again, so a message that arrived while it was on screen only appeared
     after leaving and coming back. *)
  | Keepers (Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls)
  (* The picker keeps the roster fresh for the same reason the list does: the
     keeper it is choosing for can leave the roster while it is open. Its
     catalogue has its own loader, fetched when the picker opens. *)
  | Keepers Keeper_runtime_pick ->
      { nothing with needs_keeper_roster = true; needs_fleet_safety = true }
  | Keepers Keeper_message ->
      { nothing with
        needs_keeper_roster = true
      ; needs_fleet_safety = true
      ; needs_keeper_chat = true
      }
  | Board -> { nothing with needs_board = true }
  | Planning -> { nothing with needs_planning = true }
  | System_logs -> { nothing with needs_system_logs = true }
  | Lanes | Approvals | Schedules | Verification | Harness | Fusion
  | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools ->
      nothing

(** How far a surface's list can scroll, given the terminal's height.

    A bound belongs where the move happens, and the move is a keypress. The
    drawing used to work it out mid-frame and write the clamped value back
    into the state -- the same four lines copied once per surface -- so
    drawing a frame corrected the state it was drawing from. Declared here,
    the key handler and the drawing read one answer and the drawing only
    reads.

    [None] is a surface whose rows the state cannot count: its row count is
    built by the drawing, out of text the drawing formats. Those report the
    value they used as a {!clamped_scroll} beside the frame instead, so the
    drawing still does not write. *)
type scrolled = {
  sc_count : int;  (** rows of content the surface has *)
  sc_chrome : int;  (** rows it spends on its own frame *)
}

(* These seven draw the same frame: a title, a column row, three dividers, the
   scroll line and the footer -- and two more rows when a load error is on
   screen. The number is the drawing's; a surface whose chrome moves has to
   move it here in the same change. *)
let listing_chrome ~error = if Option.is_some error then 9 else 7
let runtime_listing_chrome ~error = listing_chrome ~error + 2

(** Dashboard state *)
(* A request that has been POSTed and has not settled, with when it went out.
   The instant rides with the request rather than in a second structure keyed
   by id: a turn taking minutes is normal here and an operator watching one
   needs to see it advancing, but two structures for one fact drift the moment
   somebody adds a third place that removes a request. *)
type inflight =
  { sent_request : Masc_tui_keeper_chat_projection.request
  ; sent_at : float
  }

type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  (* The full domain rows the Overview list is projected from, kept so the
     detail view can show a task after it turns terminal -- the active list
     drops exactly those rows. Replaced wholesale with [tasks] on each load. *)
  mutable tasks_domain: Masc_domain.task list;
  mutable task_focus: bool;
  (* The [?] help overlay: open replaces the surface body until Esc/? closes
     it. The scroll survives only while it is open. *)
  mutable help_open: bool;
  mutable help_scroll: int;
  (* An image the operator asked to see, drawn over the whole terminal rather
     than into a frame. A picture does not live in a row: the terminal keeps
     it in its own layer, and the frame presenter redraws only the rows that
     changed, so a frame drawn on top would clear part of the picture and
     leave the rest. While this is set the loop draws no frames at all, and
     the next key takes the picture away and repaints everything. *)
  mutable image_open: image_shown option;
  (* The [:] command palette: a typed filter over jump targets. Query and
     cursor live only while it is open. *)
  mutable palette_open: bool;
  mutable palette_query: string;
  mutable palette_cursor: int;
  (* [/] on the roster: a search that moves the cursor, not a filter that
     subsets the list -- every action reads the same [keepers] the rows
     draw, so nothing can act on a hidden row. [Some q] while typing;
     [roster_search_last] feeds n/N after Enter. *)
  mutable roster_search: string option;
  mutable roster_search_last: string;
  (* Detail pane tab, and the per-keeper reads the non-Info tabs show. Each
     read is stamped with the keeper it answers for, so a cursor move cannot
     show one keeper's instructions under another's name. *)
  (* The Config surface: runtime.toml's path and text as the server read
     them, refreshed on entry and after every save. *)
  (* The Resources surface: the MCP resource inventory, and the one read
     the content pane shows, stamped with its uri. *)
  mutable resources_list: (string * string) list option;
  mutable resources_error: string option;
  mutable resources_cursor: int;
  mutable resource_content: (string * string list) option;
  mutable resource_content_error: string option;
  mutable resource_scroll: int;
  mutable resource_focus: bool;
  mutable runtime_config_view: (string * string list) option;
  mutable runtime_config_view_error: string option;
  mutable config_scroll: int;
  mutable detail_tab: keeper_detail_tab;
  mutable keeper_config_view: (string * string list) option;
  mutable keeper_config_view_error: string option;
  mutable github_identity_view: (string * string list) option;
  mutable github_identity_view_error: string option;
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
  (* The runtime picker: the keeper it is choosing for, its cursor into the
     dispatchable catalogue, and the catalogue itself with where every keeper
     points today. Loaded when the picker opens; absent otherwise. *)
  mutable runtime_pick_keeper: string option;
  mutable runtime_pick_cursor: int;
  mutable runtime_catalog: Tui_decode.runtime_option list;
  mutable runtime_assignments: Tui_decode.runtime_assignment list;
  mutable runtime_catalog_error: string option;
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
  (* The tool calls keepers are holding, drawn above the operator actions on
     the same surface. Live registry state on the server; refreshed with the
     surface. *)
  mutable keeper_tool_approvals: Tui_decode.keeper_tool_approval list;
  mutable keeper_tool_approvals_error: string option;
  (* Keepers whose approval gate runs every call unasked. Names only: the
     wire carries (keeper, mode) pairs and [auto] is the absent default, so
     what the pane needs is exactly the yolo set. *)
  mutable keeper_yolo_names: string list;
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
  (* One send at a time: the gate a slow server needs so s-s cannot post
     the same draft twice, and the completion knows it owns the clear. *)
  mutable board_post_inflight: bool;
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
  mutable lanes: Tui_decode.keeper_lanes_snapshot option;
  mutable lanes_error: string option;
  mutable lanes_scroll: int;
  (* What is waiting on a verdict. Loaded when the surface is opened rather
     than on every refresh: it is a queue an operator visits, not a number the
     other surfaces read. *)
  mutable tools_inventory: Tui_decode.tool_snapshot option;
  mutable tools_error: string option;
  mutable tools_scroll: int;
  mutable connectors: Tui_decode.connector_snapshot option;
  mutable connectors_error: string option;
  mutable connectors_scroll: int;
  (* Two server-owned documents joined by exact runtime id: resolved owns
     lanes/provider/model identity, probe owns cached reachability. *)
  mutable runtime_surface: Tui_decode.runtime_surface_snapshot option;
  mutable runtime_surface_error: string option;
  mutable runtime_surface_scroll: int;
  mutable runtime_surface_generation: int;
  mutable runtime_surface_inflight: int option;
  mutable runtime_surface_force_pending: bool;
  mutable repositories: Tui_decode.repository_snapshot option;
  mutable repositories_error: string option;
  mutable repositories_scroll: int;
  (* The keeper whose changes the Changes surface is showing, and what it
     answered. The name is held separately from the snapshot because a
     surface that has asked and not yet heard back is a different state from
     one that has never asked, and the scroll belongs to the list on screen
     rather than to the keeper. *)
  mutable changes_keeper: string option;
  mutable changes: Tui_decode.file_change_snapshot option;
  mutable changes_error: string option;
  mutable changes_scroll: int;
  mutable harness: Tui_decode.harness_snapshot option;
  mutable harness_error: string option;
  mutable harness_scroll: int;
  mutable fusion_runs: Tui_decode.fusion_snapshot option;
  mutable fusion_error: string option;
  mutable fusion_cursor: int;
  mutable fusion_scroll: int;
  mutable fusion_mode: fusion_mode;
  mutable fusion_runs_generation: int;
  mutable fusion_runs_inflight: int option;
  mutable fusion_detail: Tui_decode.fusion_detail option;
  mutable fusion_detail_error: string option;
  (* A detail GET captures this generation. A late response for a run the
     operator already left cannot replace the exact run now on screen. *)
  mutable fusion_detail_generation: int;
  (* The current generation/run pair already being read. Periodic refreshes
     do not pile another GET on top of it; changing runs still starts a new
     request immediately, whose pair replaces this marker. *)
  mutable fusion_detail_inflight: (int * string) option;
  (* The feature-proof reading. Kept beside its error rather than collapsed
     into an option: a report that failed to load must not draw as a report
     with no features, which reads as "nothing is proven". *)
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
  mutable msg_return: keeper_chat_return;
  mutable msg_drafts: (string * string) list;
  mutable msg_history: msg_entry list;
  (* How far back the arrows have walked through what this pane sent, and the
     draft they set aside to do it. [None] means the composer holds the
     operator's own text, so pressing down has nothing to give back. *)
  mutable msg_recall_at: int option;
  mutable msg_recall_draft: string;
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
  (* Every full-history GET captures this generation. Keeper identity alone is
     not enough after alpha -> beta -> alpha: the first alpha response can
     arrive after the second alpha request and still name the visible Keeper. *)
  mutable msg_history_load_generation: int;
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
  (* Whether this pane folds reasoning blocks to a one-line count. A view
     preference, not data: toggled by /thinking and never persisted. *)
  mutable msg_thinking_collapsed: bool;
  (* Messages typed while a turn was running, oldest first, each with the
     keeper it was addressed to. Dispatch is serialized on one in-flight
     request, so a second Enter used to be answered with "already in progress"
     and the text was gone. Holding it and sending it when the turn settles is
     what every other agent console does, and it is what an operator means by
     pressing Enter twice.

     The keeper travels with the text because the operator can switch keepers
     while a turn runs; sending a queued line to whoever happens to be selected
     later would put it in front of the wrong keeper. *)
  (* A paste too big for the composer. The draft carries one line saying what
     it is; the text itself waits here and goes back into the message on the
     way out. Kept beside the draft rather than in it because the draft is
     what the operator reads, and five rows cannot hold four hundred lines. *)
  mutable msg_spill: Masc_tui_paste_spill.t option;
  mutable msg_queued: Masc_tui_keeper_chat_queue.t;
  (* One request per keeper, not one per workspace. Dispatch used to be
     serialized on a single slot because the durable recovery fence held one
     un-acknowledged POST for the whole workspace; with that gone the only
     reason left is per keeper, which is how the server runs turns anyway. *)
  mutable msg_inflight: inflight list;
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
    (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
    state.msg_inflight
;;

let send_disposition state ~keeper_name : send_disposition =
  Masc_tui_send_disposition.of_state
    ~inflight:
      (Option.map
         (fun entry -> entry.sent_request)
         (inflight_for_keeper state keeper_name))

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

(** The next target both the input path and footer agree is safe to select.
    A pending request or live transcript stays pinned to its Keeper until that
    turn settles. A retained roster is not enough after a failed refresh:
    switching is disabled until the roster is readable again. *)
let next_keeper_message_target (state : state) =
  if
    Option.is_some state.keepers_error
    || Option.is_some state.msg_live
    || state.msg_inflight <> []
  then
    Masc_tui_keeper_selection.No_alternative
  else
    match state.msg_target_keeper_name with
    | None -> Masc_tui_keeper_selection.No_alternative
    | Some current_keeper ->
        Masc_tui_keeper_selection.next_message_target ~current_keeper
          ~keeper_ids:
            (List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers)

(** Create initial state *)
let create_state ~workspace ~port ~refresh_interval = {
  agents = [];
  tasks = [];
  tasks_domain = [];
  task_focus = false;
  help_open = false;
  help_scroll = 0;
  image_open = None;
  palette_open = false;
  palette_query = "";
  palette_cursor = 0;
  roster_search = None;
  roster_search_last = "";
  resources_list = None;
  resources_error = None;
  resources_cursor = 0;
  resource_content = None;
  resource_content_error = None;
  resource_scroll = 0;
  resource_focus = false;
  runtime_config_view = None;
  runtime_config_view_error = None;
  config_scroll = 0;
  detail_tab = Detail_info;
  keeper_config_view = None;
  keeper_config_view_error = None;
  github_identity_view = None;
  github_identity_view_error = None;
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
  runtime_pick_keeper = None;
  runtime_pick_cursor = 0;
  runtime_catalog = [];
  runtime_assignments = [];
  runtime_catalog_error = None;
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
  keeper_tool_approvals = [];
  keeper_tool_approvals_error = None;
  keeper_yolo_names = [];
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
  board_post_inflight = false;
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
  lanes = None;
  lanes_error = None;
  lanes_scroll = 0;
  system_logs = None;
  system_logs_error = None;
  tools_inventory = None;
  tools_error = None;
  tools_scroll = 0;
  connectors = None;
  connectors_error = None;
  connectors_scroll = 0;
  runtime_surface = None;
  runtime_surface_error = None;
  runtime_surface_scroll = 0;
  runtime_surface_generation = 0;
  runtime_surface_inflight = None;
  runtime_surface_force_pending = false;
  repositories = None;
  repositories_error = None;
  repositories_scroll = 0;
  changes_keeper = None;
  changes = None;
  changes_error = None;
  changes_scroll = 0;
  harness = None;
  harness_error = None;
  harness_scroll = 0;
  fusion_runs = None;
  fusion_error = None;
  fusion_cursor = 0;
  fusion_scroll = 0;
  fusion_mode = Fusion_list;
  fusion_runs_generation = 0;
  fusion_runs_inflight = None;
  fusion_detail = None;
  fusion_detail_error = None;
  fusion_detail_generation = 0;
  fusion_detail_inflight = None;
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
  msg_return = Keeper_chat_return_detail;
  msg_drafts = [];
  msg_history = [];
  msg_recall_at = None;
  msg_recall_draft = "";
  msg_live = None;
  msg_loaded = [];
  msg_loaded_keeper = None;
  msg_loaded_error = None;
  msg_loaded_dropped = 0;
  msg_history_load_generation = 0;
  msg_scroll = 0;
  msg_older_cursor = None;
  msg_older_exist = false;
  msg_older_loading = false;
  msg_older_error = None;
  msg_thinking_collapsed = false;
  msg_spill = None;
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

(** A scroll a frame had to hold inside what it could show.

    {!scrolled_surface} answers this before the frame is built, for the
    surfaces whose rows the state can count. The rest count rows the drawing
    formats -- lines of a task's notes, of a board post, of a keeper's detail
    -- so the bound is not knowable until the frame exists. Those frames say
    which value they used and the loop stores it, which is not the same as the
    drawing reaching back into the state it is drawing from: the drawing is a
    function of the state again, and every write lives on one side of it. *)
type clamped_scroll =
  | Overview_events of int
  | Task_detail of int
  | Board_read of int
  | Keeper_detail of int
  | Keeper_calls of int
  | Acting of int
  | Fusion_detail_scroll of int
  | Planning_detail_scroll of int

let apply_clamped_scroll (state : state) = function
  | Overview_events value -> state.overview_event_scroll <- value
  | Task_detail value -> state.task_detail_scroll <- value
  | Board_read value -> state.board_scroll <- value
  | Keeper_detail value -> state.detail_scroll <- value
  | Keeper_calls value -> state.keeper_calls_scroll <- value
  | Acting value -> state.acting_scroll <- value
  | Fusion_detail_scroll value -> state.fusion_scroll <- value
  | Planning_detail_scroll value -> state.planning_scroll <- value

let scrolled_surface (state : state) : surface -> scrolled option =
  let listing ~error count = Some { sc_count = count; sc_chrome = listing_chrome ~error } in
  function
  | System_logs ->
      listing ~error:state.system_logs_error
        (match state.system_logs with
         | None -> 0
         | Some s -> List.length s.Tui_decode.sys_entries)
  | Verification ->
      listing ~error:state.verification_error
        (match state.verification with
         | None -> 0
         | Some s -> List.length s.Tui_decode.vs_requests)
  | Lanes ->
      listing ~error:state.lanes_error
        (match state.lanes with
         | None -> 0
         | Some s -> List.length s.Tui_decode.kls_lanes)
  | Harness ->
      listing ~error:state.harness_error
        (match state.harness with
         | None -> 0
         | Some s -> List.length s.Tui_decode.hs_verdicts)
  | Repositories ->
      listing ~error:state.repositories_error
        (match state.repositories with
         | None -> 0
         | Some s -> List.length s.Tui_decode.rs_repositories)
  | Changes ->
      listing ~error:state.changes_error
        (match state.changes with
         | None -> 0
         | Some s -> List.length s.Tui_decode.fcs_changes)
  | Connectors ->
      listing ~error:state.connectors_error
        (match state.connectors with
         | None -> 0
         | Some s -> List.length s.Tui_decode.cs_connectors)
  | Runtime ->
      Some
        { sc_count =
            (match state.runtime_surface with
             | None -> 0
             | Some s -> List.length s.Tui_decode.rss_candidates)
        ; sc_chrome = runtime_listing_chrome ~error:state.runtime_surface_error
        }
  | Tools ->
      listing ~error:state.tools_error
        (match state.tools_inventory with
         | None -> 0
         | Some s -> List.length s.Tui_decode.ts_tools)
  | Config ->
      listing ~error:state.runtime_config_view_error
        (match state.runtime_config_view with
         | None -> 0
         | Some (_, lines) -> List.length lines)
  (* Acting counts rows the drawing builds out of formatted text, not rows the
     state holds; counting them here would be a second copy of the formatting,
     so it reports a [clamped_scroll] instead. Overview, Keepers, Board,
     Planning and Schedules move a cursor or a detail pane rather than a plain
     list. *)
  | Overview | Acting | Keepers _ | Board | Approvals | Planning | Schedules
  | Fusion | Resources ->
      None

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
     | Some live
       when state.msg_target_keeper_name
            <> Some (Masc_tui_keeper_chat_transcript.keeper_name live) ->
         (* Another keeper's live turn draws nothing on this screen, so it
            must reserve nothing -- the counter mirrors the pane. *)
         0
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
  + (if state.msg_older_loading || Option.is_some state.msg_older_error then 1
     else 0)
  + composer_extra_rows state

(* One list under one cursor: the calls keepers are holding first (they run
   out in [kta_timeout_sec]; the operator actions keep), then the operator
   actions. The two kinds answer through different routes, so the row is a
   sum the key handler matches on rather than a shape it infers. *)
type approval_row =
  | Keeper_tool_row of Tui_decode.keeper_tool_approval
  | Operator_row of Masc_tui_operator_projection.approval_item

let operator_approval_items (state : state) =
  match state.approval_snapshot with
  | Some snapshot -> snapshot.aps_items
  | None -> []

let approval_items (state : state) =
  List.map (fun held -> Keeper_tool_row held) state.keeper_tool_approvals
  @ List.map (fun item -> Operator_row item) (operator_approval_items state)


(* Command-palette jump targets. Surfaces come from the same ring the strip
   draws; keepers come from the loaded roster, so the palette can only offer
   a chat the roster can open. *)
type palette_action =
  | Palette_goto of surface
  | Palette_chat of string

let palette_contains ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.length needle and hl = String.length h in
  if n = 0 then true
  else begin
    let found = ref false in
    for start = 0 to hl - n do
      if (not !found) && String.equal (String.sub h start n) needle then
        found := true
    done;
    !found
  end

let palette_entries (state : state) =
  List.map
    (fun (surface, label) -> ("go " ^ label, Palette_goto surface))
    surface_ring
  @ List.map
      (fun (keeper : keeper) ->
        ("keeper " ^ keeper.k_name, Palette_chat keeper.k_name))
      state.keepers

(* Subsequence match: every query character appears in order. "kadm" finds
   "keeper adm-race". *)
let palette_subsequence ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let hl = String.length h and nl = String.length needle in
  let rec walk hi ni =
    if ni >= nl then true
    else if hi >= hl then false
    else if Char.equal h.[hi] needle.[ni] then walk (hi + 1) (ni + 1)
    else walk (hi + 1) ni
  in
  walk 0 0

let palette_matches (state : state) =
  let needle =
    String.lowercase_ascii (String.trim state.palette_query)
  in
  let entries = palette_entries state in
  (* Substring hits rank above subsequence-only hits, both keep entry
     order inside their rank. *)
  let substring_hits =
    List.filter (fun (label, _) -> palette_contains ~needle label) entries
  in
  let subsequence_hits =
    List.filter
      (fun (label, _) ->
        (not (palette_contains ~needle label))
        && palette_subsequence ~needle label)
      entries
  in
  substring_hits @ subsequence_hits
