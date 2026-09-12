(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_render_chat

module Frame_presenter = Masc_tui_frame_presenter
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Board_read_layout = Masc_tui_board_read_layout
module Browser_lane_layout = Masc_tui_browser_lane_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Board_comment_thread = Masc_tui_board_comment_thread
module Message_layout = Masc_tui_message_layout
module Tool_detail = Masc_tui_tool_detail
module Retained_view = Masc_tui_retained_view
module Metrics_tail = Masc_tui_metrics_tail
module Rows = Masc_tui_rows
module Observation_layout = Masc_tui_observation_layout
module Context_state = Masc_tui_context_state
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_diff = Masc_tui_keeper_chat_diff
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Agenda = Masc_tui_agenda
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Task_selection = Masc_tui_task_selection
module Tool_tree = Masc_tui_tool_tree
module Theme_choice = Masc_tui_theme_choice
module File_icon = Masc_tui_file_icon
module Approval_detail = Masc_tui_approval_detail
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Render_tools = Masc_tui_render_tools
module Span = Masc_tui_span
module Diff = Masc_tui_diff
module Chart = Masc_tui_chart
module Render_metrics = Masc_tui_render_metrics
module Render_memory = Masc_tui_render_memory

type memory_state = Render_memory.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

module Board_composer = Masc_tui_board_composer

let json_assoc_member_opt = Masc_tui_json.member_opt

let acting_pane_target_at ~line =
  let targets = !acting_pane_row_targets in
  if line >= 0 && line < Array.length targets then targets.(line)
  else Masc_tui_acting_pane.Target_none

let acting_pane_drawn_cols () = !acting_pane_reserved_cols
let acting_pane_scroll_limit () = !acting_pane_scroll_max
let set_table_frame enabled = table_frame_enabled := enabled

let fenced_pretty_json text =
  let pretty =
    match Yojson.Safe.from_string text with
    | json -> Yojson.Safe.pretty_to_string json
    | exception Yojson.Json_error _ -> text
  in
  fenced_document_text ~language:"json" pretty

(* Board accepts ordinary Markdown, so JSON detection is deliberately the
   narrow whole-document case. Objects and arrays are operational payloads;
   a post containing a scalar or a JSON-shaped fragment remains exactly the
   Markdown its author wrote. *)
let board_document_source body =
  let trimmed = String.trim body in
  match Yojson.Safe.from_string trimmed with
  | (`Assoc _ | `List _) as json ->
      Yojson.Safe.pretty_to_string json
      |> fenced_document_text ~language:"json"
  | _ -> body
  | exception Yojson.Json_error _ -> body

let board_document_markdown ~width body =
  document_markdown ~width (board_document_source body)

let keeper_roster_name_cells = Masc_tui_roster_pane.pane_cols - 7

(* The main loop uses the target identity to restart the motion when selection
   changes. A short name has no animation target and therefore costs no idle
   repaint. *)
let keeper_roster_marquee_target (state : state) ~cols =
  if not (keeper_roster_pane_shown state ~cols) then None
  else
    match state.view, selected_keeper state with
    | Keepers (Keeper_detail | Keeper_message), Some keeper ->
        let name = Terminal_text.single_line keeper.k_name in
        if Message_layout.display_width name > keeper_roster_name_cells then
          Some name
        else None
    | _ -> None

let acting_pane_columns (state : state) ~terminal_cols =
  let modal =
    Option.is_some state.lane_addons || state.palette_open || state.context_inspector_open || state.keeper_deletions_open || state.help_open
    || state.agenda_open || state.answering_open
  in
  if modal || state.view = Acting || Option.is_some (browser_lane_on_screen state)
  then 0
  else if Masc_tui_acting_pane.shown ~hidden:state.acting_pane_hidden ~cols:terminal_cols
  then Masc_tui_acting_pane.pane_cols
  else 0

(* Pure preparation shared with the loop. Terminal dimensions are the raw
   cached measurement, before the surface strip and composer reserve rows. *)
let acting_pane_chunk_projection (state : state) ~terminal_rows ~terminal_cols =
  let rows = surface_body_rows state ~terminal_rows:(max 1 (terminal_rows - 1)) in
  if acting_pane_columns state ~terminal_cols = 0
     || Render_schedule.Viewport.requires_compact_frame ~rows
     || state.acting_pane_tab = Masc_tui_acting_pane.Tab_changes
  then None
  else Some (recent_chunk_projection state)
;;

let workspace_health_label = function
  | Workspace_health_critical -> "critical"
  | Workspace_health_bad -> "bad"
  | Workspace_health_risk -> "risk"
  | Workspace_health_warning -> "warning"
  | Workspace_health_degraded -> "degraded"
  | Workspace_health_initializing -> "initializing"
  | Workspace_health_ok -> "ok"
  | Workspace_health_unknown -> "unknown"

let workspace_health_color = function
  | Workspace_health_critical
  | Workspace_health_bad
  | Workspace_health_risk -> (Theme.bad ())
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_unknown -> (Theme.warn ())
  | Workspace_health_ok -> (Theme.ok ())

(* Syslog's own names for these levels, which is why "crit" is the word and
   not a short spelling of one. The level used to read "critical" and the
   badge fitted it to five cells, so the row that most needed reading was the
   only one drawn cut: [crit~]. *)
let attention_severity_label = function
  | Attention_critical -> "crit"
  | Attention_bad -> "bad"
  | Attention_warning -> "warn"
  | Attention_info -> "info"

let attention_severity_color = function
  | Attention_critical | Attention_bad -> (Theme.bad ())
  | Attention_warning -> (Theme.warn ())
  | Attention_info -> (Theme.info ())

(* The badge column, measured from the vocabulary rather than chosen for it.
   Fitting the label to a fixed five cells did two things: it cut the longest
   level, and it padded the shorter ones inside their own brackets, which drew
   [bad  ] and [warn ] -- a gap before a closing bracket reads as a typo, not
   as a column. Taking the width from the labels means a level added or
   renamed later widens the column instead of being cut by it.

   Critical and bad share a colour (see above), so the word is the only thing
   that tells those two rows apart. That is the reason the word may not be
   cut, and the reason this is measured instead of assumed. *)
let attention_severity_badge_cells =
  let bracket_cells = 2 in
  bracket_cells
  + List.fold_left
      (fun widest severity ->
        max widest
          (Message_layout.display_width (attention_severity_label severity)))
      0
      [ Attention_critical; Attention_bad; Attention_warning; Attention_info ]

(* [level] in its colour, padded to the column outside the colour so a theme
   that paints a background does not paint the gap. *)
let attention_severity_badge severity =
  let drawn = "[" ^ attention_severity_label severity ^ "]" in
  attention_severity_color severity
  ^ drawn ^ Ansi.reset
  ^ String.make
      (max 0 (attention_severity_badge_cells - Message_layout.display_width drawn))
      ' '

(* Blame reaches further back than the two surfaces [keeper_lane_idle_text]
   serves. A line untouched since a repository's first year is ordinary, and
   "3684d" is not a reading anyone converts in their head. Weeks and years
   continue where that helper stops; the whole label fits three cells so the
   margin stays a margin. *)
let blame_age_text ~now_s at_ms =
  let seconds = Float.max 0. (now_s -. (at_ms /. 1000.)) in
  let days = int_of_float (seconds /. 86400.) in
  if days < 1 then Printf.sprintf "%dh" (int_of_float (seconds /. 3600.))
  else if days < 14 then Printf.sprintf "%dd" days
  else if days < 365 then Printf.sprintf "%dw" (days / 7)
  else Printf.sprintf "%dy" (days / 365)

(* The margin's own width: a name and a relative age, which is the smallest
   pair that answers "who, and how long ago" without a second lookup. Fixed
   so the code below it stays aligned whether or not a run starts on the
   row. *)
let blame_author_cells = 9
let blame_age_cells = 3
let blame_margin_cells = blame_author_cells + blame_age_cells + 2

let task_line (task : task) =
  let status = Masc_domain.task_status_to_string task.status in
  (* The icon and the status word share one color so the row's state reads at
     a glance: in-flight rows in cyan, waiting rows dimmed. Terminal states
     never reach this list ([active_tasks_of_domain] filters them); they keep
     the default so a future caller showing one is visible rather than wrong. *)
  let status_color =
    match task.status with
    | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> (Theme.info ())
    | Masc_domain.AwaitingVerification _ -> Theme.warn ()
    | Masc_domain.Todo -> Ansi.dim
    | Masc_domain.Done _ | Masc_domain.Cancelled _ -> ""
  in
  let assignee =
    match Masc_domain.task_assignee_of_status task.status with
    | Some name -> Printf.sprintf " @%s" (Terminal_text.single_line name)
    | None -> ""
  in
  let goal_tag =
    match task.goal_ids with
    | [] -> ""
    | goal :: _ ->
        Printf.sprintf " %s%s%s" (Theme.recede ())
          (Terminal_text.single_line goal)
          Ansi.reset
  in
  Printf.sprintf "%s%s%s %s[%s]%s %s %s(%s%s)%s %s%s"
    status_color
    (task_status_icon task.status)
    Ansi.reset
    Ansi.dim
    (Terminal_text.single_line task.id)
    Ansi.reset
    (Terminal_text.single_line task.title)
    status_color
    status
    assignee
    Ansi.reset
    (priority_indicator task.priority)
    goal_tag

(** Project the shared Overview row budget and its sanitized variable inputs. *)
let overview_layout (state : state) ~terminal_rows =
  let attention_items =
    match state.overview with
    | None -> []
    | Some overview -> overview.ov_attention_items
  in
  let tasks_error = Terminal_text.optional_single_line state.tasks_error in
  let row_budget =
    Render_schedule.allocate_overview ~terminal_rows
      ~has_cluster:(Option.is_some state.overview)
      ~attention_count:(List.length attention_items)
      ~event_count:(List.length state.events)
      ~task_count:(List.length state.tasks)
      ~has_task_error:(Option.is_some tasks_error)
  in
  attention_items, tasks_error, row_budget

(** Render the Overview surface (Dashboard V2 shell/briefing summary). *)
let render_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Overview")
    (Masc_tui_theme.tone Masc_tui_theme.Accent) (Terminal_text.single_line state.workspace) Ansi.reset timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let ov = state.overview in
  let overview_error =
    Terminal_text.optional_single_line state.overview_error
  in

  (* Summary line *)
  let summary_line =
    match (ov, overview_error) with
    | _, Some err ->
        data_unreliable_row ~cols err
    | None, None ->
        Printf.sprintf "  %s(no overview data — press 'r' to refresh)%s"
          Ansi.dim Ansi.reset
    | Some o, None ->
        let health_color = workspace_health_color o.ov_workspace_health in
        let health_label = workspace_health_label o.ov_workspace_health in
        (* The tab strip's badge counts held keeper tool calls, pending gate
           rows, and confirm-queue entries together, and so does the Approvals
           screen's own header. This row counted only the third of those, off
           the confirm queue's own visible count, so a runtime holding one
           keeper tool call drew "Approvals: 0" beside a tab reading
           "Approvals·1" -- one name over two populations. All three now walk
           [approval_items].

           The "?" tail marks a count no source will stand behind, and it does
           not say which way the number is wrong, because the failures do not
           agree on that. A dropped confirm queue empties its list, leaving the
           count short. A failed held-calls or gate poll replaces nothing --
           the previous rows stay on screen, which the Approvals header calls
           "held calls stale" -- so that count can just as easily be long,
           describing rows the server no longer holds. Which list failed is a
           question that header answers; at this width the row says only that
           one did. *)
        let approval_count =
          let on_screen = List.length (Masc_tui_types.approval_items state) in
          let source_unread =
            Option.is_none state.approval_snapshot
            || Option.is_some state.approvals_error
            || Option.is_some state.keeper_tool_approvals_error
            || Option.is_some state.gate_error
            || Option.is_some state.gate_queue_unavailable
          in
          if source_unread then Printf.sprintf "%d?" on_screen
          else string_of_int on_screen
        in
        (* Keepers and MCP clients are counted apart: a row reading
           "Agents: 2" over a runtime with ten keepers named the wrong
           population.

           The incident count used to ride here too, over an Attention panel
           three lines below drawing those same incidents one per row. A
           number above the list it counts is not a summary of anything the
           reader cannot already see; where the panel cannot fit them all,
           the panel's own title says so. *)
        (* Nine Keepers with two that had stopped doing anything and one an
           operator had paused read exactly like nine running ones. The
           briefing has carried the control plane's word for each of them all
           along; only the number reached this row.

           The states that are not "active" are the ones an operator acts on,
           so those are the ones named. A fleet where every Keeper is active
           says only its number -- an always-on breakdown would be texture,
           the way an always-on tab badge would be. *)
        let keeper_note =
          let l = o.ov_keeper_liveness in
          let parts =
            List.filter_map
              (fun (count, label) ->
                if count = 0 then None
                else Some (Printf.sprintf "%d %s" count label))
              [ (l.klc_paused, "paused")
              ; (l.klc_offline, "offline")
              ; (l.klc_inactive, "inactive")
              ; (l.klc_idle, "idle")
              ; (l.klc_unreadable, "unreadable")
              ]
          in
          match parts with
          | [] -> ""
          | _ :: _ -> Printf.sprintf " (%s)" (String.concat ", " parts)
        in
        let pulse_suffix =
          if cols >= 92 then
            let activity_samples =
              match state.keeper_turn_finishes with
              | [] -> [ 0; 0; 0; 0; 0; 0; 0; 0 ]
              | finishes ->
                  let now = Unix.gettimeofday () in
                  let buckets = Array.make 8 0 in
                  List.iter
                    (fun (_, ts) ->
                      let delta = max 0.0 (now -. ts) in
                      let idx = min 7 (int_of_float (delta /. 15.0)) in
                      let slot = 7 - idx in
                      if slot >= 0 && slot < 8 then buckets.(slot) <- buckets.(slot) + 1)
                    finishes;
                  Array.to_list buckets
            in
            let spark = Chart.sparkline activity_samples in
            Printf.sprintf "  %sPulse:%s %s" Ansi.bold Ansi.reset spark
          else ""
        in
        Printf.sprintf
          "  Health: %s%s%s  Keepers: %d%s  MCP agents: %d  Approvals: %s%s"
          health_color health_label Ansi.reset o.ov_keepers keeper_note
          o.ov_mcp_agents approval_count pulse_suffix
  in
  box_line buf cols summary_line;

  (* Cluster/project line *)
  (match ov with
   | None -> ()
   | Some o ->
         (* The transport summary rides this row rather than taking one of its
            own: a narrow viewport must not trade an event line for it. A path
            that is not listening reads "off" instead of zero sessions, and
            dropped events are called out because a steady queue that drops is
            not a healthy transport. *)
         let transport_summary =
           match state.transport with
           | None -> ""
           | Some t ->
             let websocket =
               match t.th_websocket_sessions with
               | Some sessions -> Printf.sprintf "ws %d" sessions
               | None -> "ws off"
             in
             let grpc =
               match t.th_grpc_port with
               | Some port -> Printf.sprintf "grpc :%d" port
               | None -> "grpc off"
             in
             let dropped =
               if t.th_events_dropped = 0 then ""
               else Printf.sprintf "  dropped %d" t.th_events_dropped
             in
             (* No padding here: this rides the tail of the row, so a long
                value trims itself against the border instead of pushing the
                cluster and project columns around. *)
             Printf.sprintf "  %s/%s  sse %d  %s  %s%s"
               (* Both come off a closed type now, so there is no arbitrary
                  text to sanitize here. *)
               (Masc.Transport_metrics.primary_path_kind_to_string t.th_primary_path)
               (Masc.Transport_metrics.queue_pressure_kind_to_string
                  t.th_queue_pressure)
               t.th_sse_sessions websocket grpc dropped
         in
         (* The runtime event feed rides the same tail. "live N" counts the
            frames this stream has delivered; a closed feed keeps its count
            and says why it closed, so a stream that dropped after a thousand
            events and one that never opened do not read alike. *)
         let observer_summary =
           match state.observer with
           | Observer_off -> ""
           | Observer_opening -> "  feed: opening"
           | Observer_live { events; _ } -> Printf.sprintf "  feed: live %d" events
           | Observer_closed { events; _ } ->
               (* The reason is in TUI Session Events and on the Activity status
                  row; here it would push the count off a narrow row. *)
               Printf.sprintf "  feed: closed after %d" events
         in
         let cluster_line =
           Printf.sprintf "  Cluster: %s%s%s  Project: %s%s%s"
             Ansi.dim
             (fit_width (Terminal_text.single_line o.ov_cluster) 24)
             Ansi.reset
             (fit_width (Terminal_text.single_line o.ov_project) 20)
             transport_summary observer_summary
       in
       box_line buf cols cluster_line);

  box_divider buf cols;

  (* Attention panel *)
  let attention_items, tasks_error, row_budget =
    overview_layout state ~terminal_rows:rows
  in
  (* Three verticals plus two panels have to add up to the box the rest of the
     screen draws. An odd remainder used to be dropped by the division, so on
     any odd width the Attention/Events band ended one column short of every
     other row and the right edge stepped in and back out. The odd column goes
     to the right panel. *)
  let panel_width = (cols - 3) / 2 in
  let right_panel_width = cols - 3 - panel_width in
  (* The count used to ride the summary row three lines above, over the very
     rows it counted. It belongs to the panel, and it earns its place only
     where it says something the rows cannot: that some did not fit. The
     Events panel beside it states its window the same way. *)
  let attention_count = List.length attention_items in
  let attention_title =
    if attention_count = 0 then " Attention "
    else if attention_count <= row_budget.attention_rows then
      Printf.sprintf " Attention %d " attention_count
    else
      Printf.sprintf " Attention %d/%d " row_budget.attention_rows
        attention_count
  in
  (* A burst of identical lines (manual refreshes, a broadcast fan-out) folds
     into one row with a ×N tail; the window scrolls over folded rows. *)
  let collapsed_events =
    Render_schedule.collapse_consecutive
      ~key:Masc_tui_types.overview_event_collapse_key state.events
  in
  let event_count = List.length collapsed_events in
  let event_window =
    Render_schedule.project_overview_event_window ~event_count
      ~visible_rows:row_budget.attention_rows state.overview_event_scroll
  in
  let events_title =
    let title =
      if event_window.oew_first_position = 0 then " TUI Session Events "
      else
        Printf.sprintf " TUI Session Events %d-%d/%d "
          event_window.oew_first_position event_window.oew_last_position
          event_count
    in
    fit_width title (max 0 panel_width)
  in
  Buffer.add_string buf (Printf.sprintf " %s%s%s%s%s%s\n"
    Ansi.bold attention_title Ansi.reset
    (String.make (max 0 (panel_width - String.length attention_title)) ' ')
    ((Theme.recede ()) ^ Ansi.box_v ^ Ansi.reset)
    events_title);

  let attention_items_window = Rows.of_list ~first:0 ~height:row_budget.attention_rows attention_items in
  let collapsed_events_window =
    Rows.of_list ~first:event_window.oew_offset
      ~height:row_budget.attention_rows collapsed_events
  in
  for i = 0 to row_budget.attention_rows - 1 do
    let attention_str =
      (* No length guard: the window already answers [None] past the end,
         which is the blank this drew. The guard that stood here counted the
         whole list once per row. *)
      match Rows.at attention_items_window i with
      | None -> ""
      | Some a ->
        let severity_badge = attention_severity_badge a.ai_severity in
        (* The age answers "why is this still here": a stamped item shows how
           long ago its evidence happened, an unstamped one (a paused keeper,
           a waiting confirmation) shows an em dash because its producer put
           no time on it -- it stands until its condition clears. A fixed
           three-cell column, like the severity label, so summaries start on
           one edge. *)
        let age_label =
          match a.ai_evidence_ts with
          | Some ts ->
              keeper_lane_idle_text
                (int_of_float (Unix.gettimeofday () -. ts))
          | None -> "\xe2\x80\x94"
        in
          (* Fitted once, by the fit that draws the row. Fitting the summary
             here as well meant guessing how many cells the label ahead of it
             spends, and the events column beside this one guessed one too
             many: every event row came out a cell over its budget and was
             marked truncated whether or not anything was cut. The severity
             badge pads itself to its own column, which is measured from the
             level names rather than guessed at -- so it is the one part of
             the row that is finished before it gets here. *)
          Printf.sprintf "%s %s%s%s %s" severity_badge
            Ansi.dim (fit_width age_label 3) Ansi.reset
            (Terminal_text.single_line a.ai_summary)
    in
    let event_str =
      let event_index = i + event_window.oew_offset in
      match Rows.at collapsed_events_window event_index with
      | None -> ""
      | Some (e, run) ->
        let tail =
          if run > 1 then Printf.sprintf " %s\xc3\x97%d%s" Ansi.dim run Ansi.reset
          else ""
        in
        Printf.sprintf "%s[%s]%s %s%s"
          Ansi.dim e.timestamp Ansi.reset
          (Terminal_text.single_line e.content)
          tail
    in
    Buffer.add_string buf (Printf.sprintf "  %s %s%s%s %s\n"
      (fit_width attention_str (panel_width - 2))
      (Theme.recede ()) Ansi.box_v Ansi.reset
      (fit_width event_str (right_panel_width - 2)))
  done;

  box_divider buf cols;

  (* Tasks section *)
  let task_header =
    if List.is_empty state.tasks then Printf.sprintf " %sTasks%s\n" Ansi.bold Ansi.reset
    else
      let count = List.length state.tasks in
      let done_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with Done _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let active_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with InProgress _ | Claimed _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let awaiting_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with AwaitingVerification _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let todo_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with Todo -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      Printf.sprintf " %sTasks%s (%d · %s%d done%s · %s%d active%s · %s%d awaiting%s · %s%d todo%s)\n"
        Ansi.bold Ansi.reset
        count
        (Theme.ok ()) done_c Ansi.reset
        (Theme.info ()) active_c Ansi.reset
        (Theme.warn ()) awaiting_c Ansi.reset
        Ansi.dim todo_c Ansi.reset
  in
  Buffer.add_string buf task_header;

  (match tasks_error with
   | Some err when row_budget.task_error_rows > 0 ->
        box_line buf cols
          ((Theme.bad ()) ^ "  "
          ^ fit_width err (cols - 8)
          ^ Ansi.reset)
   | None | Some _ -> ());
  if row_budget.task_rows > 0 && List.is_empty state.tasks
     && Option.is_none tasks_error then
    box_line buf cols (Ansi.dim ^ "  (no tasks)" ^ Ansi.reset)
  else begin
    (* The panel is shorter than the list can get, so the cursor can sit below
       the last visible row; the window follows it the way Board's does. *)
    let task_scroll_offset =
      max 0 (state.task_cursor - row_budget.task_rows + 1)
    in
    let tasks_window = Rows.of_list ~first:task_scroll_offset ~height:row_budget.task_rows state.tasks in
    for i = 0 to row_budget.task_rows - 1 do
      let idx = i + task_scroll_offset in
      match Rows.at tasks_window idx with
      | None -> ()
      | Some t -> begin
        let is_selected = state.task_focus = Right_pane && idx = state.task_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ task_line t))
        else
          box_line buf cols ("  " ^ task_line t)
      end
    done
  end;

  (* Carry the frame to the bottom of the terminal. Without this the surface
     stops where its content does and the footer under it lands wherever that
     happens to be -- halfway up a tall window. *)
  for _ = 1 to row_budget.filler_rows do
    box_empty buf cols
  done;

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:
         (Masc_tui_keys.footer_hints_overview
            ~task_focus:(state.task_focus = Right_pane)));

  finish_surface state ~clamped:(Overview_events event_window.oew_offset) ~surface_key:"overview" ~rows:terminal_rows
      ~cols buf

(* One task's event history, appended after the detail body so it rides the
   same scroll. Loaded lazily on detail entry; the id check drops an answer
   for a task the operator already left. Rows are raw event-stream lines, so
   only the fields present are drawn. *)
let task_history_lines (state : state) task_id =
  let header = "  HISTORY" in
  let rows =
    match state.task_history with
    | Some (id, result) when String.equal id task_id -> (
        match result with
        | Ok [] -> [ "    (no events recorded)" ]
        | Ok events ->
            List.concat_map
              (fun (event : Tui_decode.task_history_event) ->
                let transition =
                  match event.Tui_decode.th_from_status, event.th_to_status with
                  | Some from_status, Some to_status ->
                      Printf.sprintf "  %s -> %s" from_status to_status
                  | Some from_status, None -> "  from " ^ from_status
                  | None, Some to_status -> "  -> " ^ to_status
                  | None, None -> ""
                in
                let actor =
                  match event.th_actor with
                  | Some actor -> "  by " ^ actor
                  | None -> ""
                in
                Printf.sprintf "    %s  %s%s%s"
                  (Planning_detail.short_ts event.th_ts)
                  event.th_label transition actor
                :: (match event.th_note with
                    | Some note -> [ "      " ^ note ]
                    | None -> []))
              events
        | Error err -> [ "    load failed: " ^ err ])
    | _ -> [ "    loading..." ]
  in
  ("" :: header :: rows)

let task_detail_pane (state : state) ~rows ~cols (task : Masc_domain.task) buf =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Task")
    (Masc_tui_theme.tone Masc_tui_theme.Accent) (fit_width task.id 20) Ansi.reset timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols
    (Ansi.bold ^ "  "
    ^ fit_width (Terminal_text.single_line task.title) (cols - 6)
    ^ Ansi.reset);
  (* What this task serves. The task record carries no goal -- the goal-task
     registry is the source of truth -- so this reads the links the loader
     resolved rather than a field that would always be empty.

     Written as a reference so Ctrl-] can follow it: naming a goal the
     operator then has to go find by hand is the gap this closes. *)
  (match
     List.find_opt (fun (row : Tui_decode.task) -> String.equal row.id task.id)
       state.tasks
   with
   | None -> ()
   | Some row ->
     (match row.goal_ids with
      | [] ->
        box_line buf cols
          (Ansi.dim ^ "  Goal        (not linked to a goal)" ^ Ansi.reset)
      | goal_ids ->
        List.iteri
          (fun index goal_id ->
            let label = if index = 0 then "Goal" else "" in
            box_line buf cols
              (Printf.sprintf "  %-11s %s  %s" label
                 (fit_width goal_id 28)
                 (Ansi.dim ^ Link.reference Goal goal_id ^ Ansi.reset)))
          goal_ids));
  (* Each status carries its own timestamps and actors; one exhaustive match
     keeps the row and the status from disagreeing about who did what. The
     note lines stay counted so the body budget below shrinks with them --
     a verification id must not push the helper row off the screen. *)
  let status_line, note_lines =
    match task.task_status with
    | Masc_domain.Todo -> ("todo — unclaimed", [])
    | Masc_domain.Claimed { assignee; claimed_at } ->
        ( Printf.sprintf "claimed by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line claimed_at)
        , [] )
    | Masc_domain.InProgress { assignee; started_at } ->
        ( Printf.sprintf "in progress by %s since %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line started_at)
        , [] )
    | Masc_domain.AwaitingVerification
        { assignee; submitted_at; verification_id; _ } ->
        ( Printf.sprintf "awaiting verification by %s, submitted %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line submitted_at)
        , [Printf.sprintf "verification %s"
             (Terminal_text.single_line verification_id)] )
    | Masc_domain.Done { assignee; completed_at; notes } ->
        ( Printf.sprintf "done by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line completed_at)
        , match notes with None -> [] | Some note -> [note] )
    | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
        ( Printf.sprintf "cancelled by %s at %s"
            (Terminal_text.single_line cancelled_by)
            (Terminal_text.single_line cancelled_at)
        , match reason with None -> [] | Some r -> [r] )
  in
  box_line buf cols
    (Ansi.dim ^ "  status   " ^ Ansi.reset
    ^ fit_width status_line (cols - 16));
  List.iter
    (fun note ->
       box_line buf cols
         (Ansi.dim ^ "           " ^ fit_width
            (Terminal_text.single_line note) (cols - 16)
         ^ Ansi.reset))
    note_lines;
  box_line buf cols
    (Ansi.dim ^ Printf.sprintf "  created  %s by %s  priority %d  cycles %d"
       (Terminal_text.single_line task.created_at)
       (match task.created_by with
        | Some by -> Terminal_text.single_line by
        | None -> "-")
       task.priority task.cycle_count
    ^ Ansi.reset);
  box_divider buf cols;

  (* Labeled block: the label rides the first wrapped line and continuation
     lines keep the text column, so long handoff summaries stay readable. *)
  let labeled_lines label text =
    let width = max 10 (cols - 16) in
    Message_layout.wrap_words ~max_cells:width
      (Terminal_text.single_line text)
    |> List.mapi
         (fun index line ->
            if index = 0 then Printf.sprintf "  %-8s %s" label line
            else Printf.sprintf "           %s" line)
  in
  let some_lines label = function
    | None -> []
    | Some text -> labeled_lines label text
  in
  let list_lines label items =
    List.concat_map (fun item -> labeled_lines label item) items
  in
  let body_lines =
    (if String.equal task.description "" then [] else labeled_lines "what" task.description)
    @ (match task.handoff_context with
       | None -> []
       | Some handoff ->
           some_lines "why" handoff.Masc_domain.reason
           @ (if String.equal handoff.Masc_domain.summary "" then []
              else labeled_lines "handoff" handoff.Masc_domain.summary)
           @ some_lines "next" handoff.Masc_domain.next_step
           @ some_lines "failure" handoff.Masc_domain.failure_mode
           @ list_lines "evidence" handoff.Masc_domain.evidence_refs)
    @ (match task.contract with
       | None -> []
       | Some contract ->
           (if contract.Masc_domain.strict then
              ["  contract strict"]
            else [])
           @ list_lines "done-when" contract.Masc_domain.completion_contract
           @ list_lines "evidence" contract.Masc_domain.required_evidence)
    @ list_lines "file" task.files
    @ task_history_lines state task.id
  in
  let total_lines = List.length body_lines in
  (* Chrome above and below the scrolling body: top border, header, divider,
     the title block, the bottom border, the helper row and the composer row.
     Clamped through the same helper the keeper log pane uses. Ten, not nine:
     at nine the frame came out one row taller than its budget, which cost the
     surface the composer row rather than a body row. On top of the ten, the
     status note lines vary by state -- a verification id or cancellation
     reason must shrink the body, not push rows off the bottom. *)
  let content_height = max 1 (rows - boxed_surface_chrome_rows - List.length note_lines) in
  let offset =
    min state.task_detail_scroll
      (Metrics_tail.maximum_scroll ~entry_count:total_lines ~content_height)
  in
  let body_lines_window = Rows.of_list ~first:offset ~height:content_height body_lines in
  for i = 0 to content_height - 1 do
    let line_index = i + offset in
    let text =
      if line_index < total_lines then
        Option.value (Rows.at body_lines_window line_index) ~default:""
      else ""
    in
    box_line buf cols
      (Ansi.dim ^ fit_width (Terminal_text.single_line text) (cols - 8)
      ^ Ansi.reset)
  done;

  box_bottom buf cols;
  offset
;;

(* The task list stays beside the task. Overview's rows are the queue
   this task sits in, and reading one used to cost the reader their
   place in it. Below the split width the detail keeps the screen. *)
let render_task_detail (state : state) (task : Masc_domain.task) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let offset =
    if cols < keeper_split_threshold_cols then
      task_detail_pane state ~rows ~cols task buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Tasks"
        ~focused:false
        ~labels:
          (List.map (fun (row : Tui_decode.task) -> row.title) state.tasks)
        ~selected:state.task_cursor;
      let answer =
        task_detail_pane state ~rows ~cols:(cols - left_cols) task right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:"j/k:scroll  x:cancel  Left / Esc:back  r:refresh");

  finish_surface state ~clamped:(Task_detail offset) ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

(** Render the Approvals surface (pending confirmations). *)
(* The ask, whole. The list row is one line through [single_line], which
   turns a newline into the six characters [\x0A] and then cuts; an [Edit]
   carrying a page of code read as its first forty characters and there was
   no second screen. This is that screen. *)
let approval_detail_pane (state : state) ~clamped ~rows ~cols (row : approval_row) buf =
  let width = max 8 (cols - 6) in
  let fields =
    match row with
    | Keeper_tool_row held ->
      [ "keeper", held.Tui_decode.kta_keeper
      ; "tool", held.Tui_decode.kta_tool
      ; "call", held.Tui_decode.kta_tool_call_id
      ; "question", held.Tui_decode.kta_question
      ; "args", held.Tui_decode.kta_args
      ]
    | Gate_row pending ->
      let phase =
        match pending.Tui_decode.gp_phase with
        | Gate_queued -> "queued"
        | Gate_judging -> "judging"
        | Gate_human_required -> "human required"
        | Gate_blocked -> "auto judge blocked"
      in
      let blocked_fields =
        match pending.Tui_decode.gp_phase with
        | Gate_blocked ->
          [ ( "reason"
            , Option.value
                ~default:"(the server recorded no detail)"
                pending.Tui_decode.gp_auto_judge_detail
              |> Keeper_chat.terminal_safe_text ~preserve_newlines:true )
          ; ( "next"
            , match pending.Tui_decode.gp_retry_request with
              | Some _ -> "R: retry Auto Judge; y/n: decide now"
              | None ->
                  "y/n: decide now (this exact attempt cannot be replayed)" )
          ]
        | Gate_queued | Gate_judging | Gate_human_required -> []
      in
      [ "keeper", pending.Tui_decode.gp_keeper
      ; "tool", pending.Tui_decode.gp_display_tool
      ; "operation", pending.Tui_decode.gp_operation
      ; "state", phase
      ]
      @ blocked_fields
      @ [
        ( "approval", pending.Tui_decode.gp_id )
      ; ( "sandbox"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_sandbox )
      ; ( "working directory"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_cwd )
      ; "input",
        (match pending.Tui_decode.gp_input_preview with
         | Some preview -> preview
         | None -> "")
      ]
    | Operator_row a ->
      [ "actor", a.Masc_tui_operator_projection.ap_actor
      ; "action", a.Masc_tui_operator_projection.ap_action_type
      ; "target", a.Masc_tui_operator_projection.ap_target_type
      ; "summary", a.Masc_tui_operator_projection.ap_summary
      ; "payload",
        Yojson.Safe.pretty_to_string a.Masc_tui_operator_projection.ap_payload
      ]
  in
  let lines = Approval_detail.of_fields ~width fields in
  box_top buf cols;
  box_line buf cols (screen_title " Approval" ^ "  " ^ Ansi.dim
    ^ "Esc: back to the list" ^ Ansi.reset);
  box_divider buf cols;
  let content_height = max 1 (rows - 6) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height:content_height
      state.approval_detail_scroll
  in
  (* The pane is where the field count and the drawn height meet, so the row
     it could actually use is reported back rather than recomputed outside. *)
  clamped := scroll;
  let drawn =
    lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun (line : Approval_detail.line) ->
      let text = line.Approval_detail.text in
      match line.Approval_detail.label with
      | Some _ ->
        box_line buf cols
          (Printf.sprintf "  %s%s%s" Ansi.bold (fit_width text (cols - 6)) Ansi.reset)
      | None ->
        box_line buf cols (Printf.sprintf "  %s" (fit_width text (cols - 6))))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;
  box_bottom buf cols
;;

(* The queue stays beside the ask. Reading one used to hide the rest, and the
   rest is what tells an operator whether this one is the urgent one. *)
let approval_sidebar_label (row : approval_row) =
  match row with
  | Keeper_tool_row held -> held.Tui_decode.kta_tool
  | Gate_row pending -> pending.Tui_decode.gp_display_tool
  | Operator_row item -> item.ap_action_type

let render_approval_detail (state : state) (row : approval_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll = ref state.approval_detail_scroll in
  if cols < keeper_split_threshold_cols then
    approval_detail_pane state ~clamped:scroll ~rows ~cols row buf
  else begin
    let left_cols = keeper_roster_pane_cols in
    let left_buf = Buffer.create 1024 in
    let right_buf = Buffer.create 4096 in
    (* Not "Asks": this surface already calls a Keeper's question to a human
       an ask, and these rows are the confirmations waiting on an operator. *)
    write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Approvals"
      ~focused:false
      ~labels:(List.map approval_sidebar_label (approval_items state))
      ~selected:state.approval_cursor;
    approval_detail_pane state ~clamped:scroll ~rows
      ~cols:(cols - left_cols) row right_buf;
    write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf
  end;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:scroll  y:confirm  n:deny  R:retry if offered  Esc:back");
  finish_surface state ~clamped:(Approval_detail_scroll !scroll)
    ~surface_key:"approval-detail" ~rows:terminal_rows ~cols buf

(* One line for an ask the cursor is not on: who is waiting and how much they
   asked. What the operator needs from a folded ask is that it exists and can
   be reached; the choices belong to the one they are on. *)
let ask_summary_line ~(row : Masc.Tui_decode.ask_row) =
  let count = List.length row.Masc.Tui_decode.ar_questions in
  Printf.sprintf " %s%s  %d question%s waiting%s" Ansi.dim
    (fit_width (Terminal_text.single_line row.Masc.Tui_decode.ar_keeper) 16)
    count
    (if count = 1 then "" else "s")
    Ansi.reset

let draw_ask_questions buf cols (state : state) ~budget =
  (* Questions Keepers put to a human sit under the approval queue rather than
     in it. Nothing is held waiting on them -- the Keeper that asked kept
     working -- so they are not a queue of blocked calls, but an operator
     deciding things belongs in one place either way. *)
  let answering_ask_id =
    match state.ask_answer_mode with
    | Ask_answering { aam_ask_id } -> Some aam_ask_id
    | Ask_browsing -> None
  in
  match state.asks_snapshot with
  | None -> ()
  | Some snapshot -> (
      let open_rows = Ask_projection.open_rows snapshot in
      box_divider buf cols;
      box_line buf cols
        (Printf.sprintf "  %s%s[?] Questions waiting on you (%d) · a:open answers%s" Ansi.bold (Theme.warn ())
           (List.length open_rows) Ansi.reset);
      match open_rows with
      | [] ->
          box_line buf cols
            (Printf.sprintf "  %snone -- no Keeper is waiting on a decision%s"
               Ansi.dim Ansi.reset)
      | rows ->
          (* Only the ask under the cursor keeps its questions; every other one
             folds to a line. Before this the panel drew all of them and the
             surface, which puts this block last, dropped whatever ran past its
             budget -- an ask of four questions was enough to push the rest off
             the bottom, the cursor with it, so [/] and j/k moved a selection
             nothing on screen showed. *)
          let count = List.length rows in
          let cursor = min (max 0 state.ask_cursor) (count - 1) in
          let selected = List.nth rows cursor in
          let draft = Ask_projection.draft_for state.ask_draft ~row:selected in
          let answering =
            match answering_ask_id with
            | Some ask_id -> String.equal ask_id selected.Masc.Tui_decode.ar_id
            | None -> false
          in
          let questions = selected.Masc.Tui_decode.ar_questions in
          let question_blocks =
            List.mapi
              (fun index question ->
                ask_block (fun b ->
                    draw_ask_question b cols state ~row:selected ~draft ~question
                      ~answering
                      ~selected_question:(index = state.ask_question_cursor)))
              questions
          in
          let why_text, why_rows =
            ask_block (fun b -> draw_ask_context b cols ~row:selected)
          in
          let plan =
            Ask_layout.plan ~budget ~spent:(ask_section_rows buf)
              ~question_heights:(List.map snd question_blocks)
              ~question_cursor:state.ask_question_cursor
              ~context_height:why_rows ~other_asks:(count - 1)
          in
          List.iteri
            (fun index (text, _) ->
              if
                index >= plan.Ask_layout.question_start
                && index
                   < plan.Ask_layout.question_start
                     + plan.Ask_layout.questions_shown
              then Buffer.add_string buf text)
            question_blocks;
          if plan.Ask_layout.questions_hidden > 0 then
            box_line buf cols
              (Printf.sprintf "    %s+%d more question%s -- j/k to reach%s"
                 Ansi.dim plan.Ask_layout.questions_hidden
                 (if plan.Ask_layout.questions_hidden = 1 then "" else "s")
                 Ansi.reset);
          if plan.Ask_layout.context_shown then Buffer.add_string buf why_text;
          let printed = ref 0 in
          List.iteri
            (fun index row ->
              if index <> cursor && !printed < plan.Ask_layout.summaries_shown
              then begin
                box_line buf cols (ask_summary_line ~row);
                incr printed
              end)
            rows;
          if plan.Ask_layout.summaries_hidden > 0 then
            box_line buf cols
              (Printf.sprintf "  %s+%d more ask%s -- [/] to reach%s" Ansi.dim
                 plan.Ask_layout.summaries_hidden
                 (if plan.Ask_layout.summaries_hidden = 1 then "" else "s")
                 Ansi.reset))

(* The selected row's detail, and the only one of the three detail rows whose
   height depends on which kind is selected. A held tool call answers two
   questions -- what is being asked, and why it was held -- and the ask runs
   the width of the pane, so at eighty columns the two cannot share a row.

   Built here rather than inline so the surface can ask its height before it
   spends the rows, the way [ask_section_rows] already measures the ask block
   it is about to draw. The row budget and the drawing call this, so they
   cannot disagree about how tall it is; until 2026-08-31 the second row was
   spelled as a literal ["\\n"] -- backslash and n, printed as those two
   characters -- because a real newline would have drawn a row nobody
   counted. *)
let approval_detail_line (state : state) ~approvals ~cols ~action_inflight =
    match List.nth_opt approvals state.approval_cursor with
    | Some (Operator_row a) -> (
        if action_inflight then
          Printf.sprintf "  %sApproval request in progress…%s" (Theme.warn ())
            Ansi.reset
        else
          match state.pending_approval_action with
          | Some { paa_token; paa_decision }
            when String.equal paa_token a.ap_token ->
              let key =
                match paa_decision with
                | Confirm -> "y"
                | Deny -> "n"
              in
              Printf.sprintf "  %sPress %s again: %s%s" (Theme.warn ()) key
                (fit_width (Terminal_text.single_line a.ap_summary) (cols - 22))
                Ansi.reset
          | _ ->
              let summary =
                fit_width (Terminal_text.single_line a.ap_summary) (max 8 (cols - 34))
              in
              Printf.sprintf "  %s%s%s  %s[y] Approve  [n] Reject%s"
                Ansi.dim summary Ansi.reset
                (Theme.info ()) Ansi.reset)
    | Some (Keeper_tool_row held) ->
        (* One press answers a held call, matching the chat pane's [y]. The
           question is the whole ask, so it is the row the eye lands on;
           the because is why this call was held at all — an operator
           repeating the same yes needs the reason visible, not the name
           of a policy table they cannot open. *)
        (* Two rows. This carried a literal "\n" -- backslash and n, printed as
           those two characters -- because a real newline would have drawn a
           row nobody had budgeted for. [detail_extra_rows] above budgets it. *)
        Printf.sprintf "  %s%s%s  %s[y] Allow  [n] Deny%s\n  %swhy: %s%s"
          (Theme.warn ())
          (fit_width
             (Terminal_text.single_line held.kta_question)
             (max 8 (cols - 28)))
          Ansi.reset
          (Theme.info ()) Ansi.reset
          Ansi.dim
          (fit_width
             (Terminal_text.single_line_or ~default:"(not provided)"
                held.kta_because)
             (max 8 (cols - 12)))
          Ansi.reset
    | Some (Gate_row pending) ->
        (* A durable Gate ask: it keeps until answered, and the answer goes
           through the dashboard resolve route. What the eye needs is who
           wants to touch what, and that the decision spends here. *)
        (* The name is not padded here. This is one line with nothing under
           it to line up with, so a fixed twenty both cut
           "rw-e0-r9-20260820-review" and left short names trailing spaces.
           The list above it now sizes its column to the names it holds and
           this line disagreed with it three rows apart.

           What follows absorbs the difference, which is the same order the
           list uses: the identifier is why the line exists. *)
        let keeper =
          Terminal_text.single_line pending.Tui_decode.gp_keeper
        in
        let phase, tone =
          match pending.Tui_decode.gp_phase with
          | Gate_queued -> "QUEUED", (Theme.warn ())
          | Gate_judging -> "JUDGING", (Theme.info ())
          | Gate_human_required -> "HUMAN REQUIRED", (Theme.warn ())
          | Gate_blocked -> "AUTO JUDGE BLOCKED", (Theme.bad ())
        in
        let actions = "  " ^ (Theme.info ()) ^ "[y] Approve  [n] Reject" ^ Ansi.reset in
        let headline =
          Printf.sprintf "  %s%s → %s · %s%s%s"
            tone
            keeper
            (fit_width
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
               (max 8 (cols - 56 - Message_layout.display_width keeper
                       - Message_layout.display_width phase)))
            phase
            Ansi.reset
            actions
        in
        (match pending.gp_phase with
         | Gate_blocked ->
             let detail =
               Terminal_text.single_line_or ~default:"(the server recorded no detail)"
                 pending.gp_auto_judge_detail
             in
             let next =
               match pending.gp_retry_request with
               | Some _ -> "R: retry Auto Judge; y/n: decide now"
               | None -> "y/n: decide now (this exact attempt cannot be replayed)"
             in
             Printf.sprintf "%s\n  %sreason: %s%s\n  %s%s%s"
               headline Ansi.dim
               (fit_width detail (max 8 (cols - 12))) Ansi.reset
               Ansi.dim (fit_width next (max 8 (cols - 4))) Ansi.reset
         | Gate_queued | Gate_judging | Gate_human_required -> headline)
    | None -> ""
;;


(* Rows [approval_detail_line] draws. One newline is one extra row, counted the
   same way [ask_section_rows] counts the block above it. *)
let approval_detail_rows line =
  let n = ref 1 in
  String.iter (fun c -> if c = '\n' then incr n) line;
  !n

let render_approvals (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  (* Two extra chrome rows on this surface only, both always drawn between
     the header and the divider: the Gate lane line, and the standing
     always-allow rule line under it. *)
  let gate_lane_rows = 2 in
  let approvals = approval_items state in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  (* Asked of the line itself, not declared beside it. [boxed_surface_chrome_rows]
     budgets one row for this detail and every kind but one takes it; a held
     tool call takes two. Reading the height off the string the pane is about
     to draw is what keeps the two from drifting -- the same thing
     [ask_section_rows] does for the block below. *)
  let detail_line =
    approval_detail_line state ~approvals ~cols ~action_inflight
  in
  let detail_extra_rows = approval_detail_rows detail_line - 1 in
  (* What the questions may spend. The block is drawn last, and a surface that
     overruns loses its final rows, so an unbudgeted question list does not
     push the approval queue off the screen -- it pushes itself off, cursor and
     all. One row is held back for the queue, which is what the [max 1] below
     was already trying to promise and could not keep. *)
  let ask_budget =
    max 4
      (rows - boxed_surface_chrome_rows - gate_lane_rows - detail_extra_rows - 1)
  in
  (* Drawn before the queue's own budget is settled so its height is a measured
     fact rather than a second estimate that can disagree with the drawing. *)
  let ask_buf = Buffer.create 1024 in
  draw_ask_questions ask_buf cols state ~budget:ask_budget;
  let ask_rows = ask_section_rows ask_buf in
  let approval_body_rows =
    max 1
      (rows - boxed_surface_chrome_rows - gate_lane_rows - ask_rows
       - detail_extra_rows)
  in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length approvals in
  (* The count is what is on screen. It used to be the pending-confirm queue's
     own visible/total pair, and that queue is one of the three lists this
     screen draws: with seven Gate rows waiting and no confirm entries, the
     title read "(0/0, hidden 0)" while the tab beside it read "7".

     The filter clause stays -- an actor filter really does hide confirm
     entries, and [visible_entries]/[hidden_entries] partition the same list,
     so the hidden count is the whole of what the old total said. It now
     reads as a note about that queue rather than as the screen's count. *)
  let queue_note =
    match state.approval_snapshot with
    | None -> ", confirm queue unread"
    | Some snapshot ->
      if snapshot.aps_hidden_count = 0 then ""
      else
        Printf.sprintf ", %d hidden from %s" snapshot.aps_hidden_count
          (Terminal_text.single_line_or ~default:"?" snapshot.aps_actor_filter)
  in
  (* A failed held-calls poll keeps the previous rows on screen: the handler
     in [masc_tui.ml] replaces [keeper_tool_approvals] only on [Ok], so the
     count beside the title can describe a list the server no longer holds.
     The empty branch below already refuses to let an unreadable queue wear
     the face of an empty one; a stale list is the same lie with rows on it,
     and it is the one an operator decides against. *)
  let held_note =
    match state.keeper_tool_approvals_error with
    | Some _ -> ", held calls stale"
    | None -> ""
  in
  let action_badge = if action_inflight then "  [submitting]" else "" in
  let type_breakdown =
    let held_c = List.length state.keeper_tool_approvals in
    let gate_c = List.length state.gate_pending in
    let op_c = List.length (operator_approval_items state) in
    if count > 0 then
      Printf.sprintf " [%s%d held%s · %s%d gate%s · %s%d op%s]"
        (Theme.warn ()) held_c Ansi.reset
        (Theme.bad ()) gate_c Ansi.reset
        (Theme.info ()) op_c Ansi.reset
    else ""
  in
  let header =
    Printf.sprintf
      "%s (%d%s%s%s)  %s  %s%s"
      (screen_title " MASC Approvals")
      count type_breakdown queue_note held_note timestamp
      (connection_badge state) action_badge
  in

  box_top buf cols;
  box_line buf cols header;
  (* Both Gate lanes, always on screen here — one row, counted with the rule
     row below it in [gate_lane_rows] so the body arithmetic can subtract
     both as a constant. The durable rows obey
     the external lane, and an operator deciding them needs to see which
     switch they are under. The [e] that cycles the external lane is a
     footer key like any other -- it reaches the footer and the [?] help
     through the Approvals row of Masc_tui_keys, which is where it was
     missing until 2026-08-29. *)
  box_line buf cols
    (match state.gate_modes, Terminal_text.optional_single_line state.gate_error with
     | Some modes, _ ->
         Printf.sprintf
           "  %s[w] Workspace: %s  |  [e] Outside services: %s%s"
           (Theme.info ())
           (match Masc.Keeper_gate_mode.of_string modes.Tui_decode.glm_workspace with
            | Some mode -> gate_mode_label mode | None -> "Unknown mode")
           (match Masc.Keeper_gate_mode.of_string modes.Tui_decode.glm_external with
            | Some mode -> gate_mode_label mode | None -> "Unknown mode")
           Ansi.reset
     (* No prefix: [data_unreliable_row] already opens "(data unreliable: "
        and the loader's message already opens "gate load failed:", so a third
        "gate:" in front read as a stutter -- "(data unreliable: gate: gate
        load failed: ...)". Same rule the schedule warning is written to. The
        two rows below keep their prefixes because the detail there is the
        server's own sentence about the store, which does not name itself. *)
     | None, Some err -> data_unreliable_row ~cols err
     | None, None ->
         Ansi.dim ^ "  Gate lanes: loading" ^ Ansi.reset);
  (* Standing always-allow rules, on the row under the lanes. A rule answers
     its call before the call can reach the queue, so an operator reading an
     empty queue is reading the rules' work without seeing them. One row: the
     count, and who the newest one covers. *)
  box_line buf cols
    (match state.gate_rules_unavailable, state.gate_rules with
     | Some detail, _ ->
         data_unreliable_row ~cols ("always-allow rules: " ^ detail)
     | None, [] ->
         Ansi.dim ^ "  Always-allow rules: none" ^ Ansi.reset
     | None, (newest :: _ as rules) ->
         Printf.sprintf
           "  %sAlways-allow rules: %d  ·  newest %s / %s%s%s"
           Ansi.dim
           (List.length rules)
           newest.Tui_decode.gr_keeper
           newest.Tui_decode.gr_tool
           (match newest.Tui_decode.gr_expires_at with
            | Some _ -> " (expires)"
            | None -> "")
           Ansi.reset);
  box_divider buf cols;

  let approvals_error =
    Terminal_text.optional_single_line state.approvals_error
  in
  if count = 0 then begin
    (match state.approval_snapshot, approvals_error with
     | _, Some err ->
         box_line buf cols (data_unreliable_row ~cols err);
         for _ = 1 to max 0 (approval_body_rows - 1) do
           box_empty buf cols
         done
     | None, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no approval data — press 'r' to refresh)"
           ^ Ansi.reset);
         for _ = 1 to max 0 (approval_body_rows - 1) do
           box_empty buf cols
         done
     | Some _, None ->
         (* An unreadable approval-queue store and an empty queue must not
            share a face: the server says which one it was, and "no pending
            approvals" over a store nobody could read is the lie an operator
            acts on. *)
         (match state.gate_queue_unavailable with
          | Some detail ->
              box_line buf cols
                (data_unreliable_row ~cols ("approval queue unavailable: " ^ detail));
              for _ = 1 to max 0 (approval_body_rows - 1) do
                box_empty buf cols
              done
          | None ->
              box_line buf cols
                (Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset);
              for _ = 1 to max 0 (approval_body_rows - 1) do
                box_empty buf cols
              done));
  end else begin
    let content_height = approval_body_rows in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let now_unix = Unix.gettimeofday () in
    (* The name column, sized to the names it has to hold rather than to a
       number chosen once. Sixteen cells cut "rw-e0-r9-20260820-review" to
       "rw-e0-r9-202608~", and two keepers whose names share a long prefix
       then read alike -- which is the whole job of the column.

       The cells come out of the last one, which carries the server's input
       preview. That preview is a JSON envelope, so at this width it shows
       "{\"schema\":\"ma~" and nothing a reader can act on; ten fewer of those
       characters costs nothing and buys the identifier back. The cap keeps
       one long name from taking the row. *)
    (* Sanitised here, not at the call below. These are external names and
       every path that reads one goes through [Terminal_text] -- measuring is
       a path like any other, and a measurement taken off the raw field would
       size the column to control characters the screen never draws. *)
    let approval_row_name = function
      | Operator_row a -> Terminal_text.single_line a.ap_actor
      | Keeper_tool_row held ->
        Terminal_text.single_line held.Tui_decode.kta_keeper
      | Gate_row pending ->
        Terminal_text.single_line pending.Tui_decode.gp_keeper
    in
    let name_width =
      List.fold_left
        (fun widest row ->
          max widest (Message_layout.display_width (approval_row_name row)))
        16 approvals
      |> min 26
    in
    let approvals_window = Rows.of_list ~first:scroll_offset ~height:content_height approvals in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let line =
          match Rows.at approvals_window idx with
          | None -> ""
          | Some (Operator_row a) ->
              let target_id =
                Terminal_text.single_line_or ~default:"-" a.ap_target_id
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line a.ap_actor) name_width)
                (fit_width (Terminal_text.single_line a.ap_action_type) 20)
                (fit_width (Terminal_text.single_line a.ap_target_type) 16)
                target_id
          | Some (Keeper_tool_row held) ->
              (* The remaining wait, not the age: this row disappears on its
                 own when it runs out, and what an operator weighs is how
                 long they still have. *)
              let remaining =
                max 0.
                  (held.kta_asked_at +. held.kta_timeout_sec -. now_unix)
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line held.kta_keeper) name_width)
                (fit_width
                   ("tool: " ^ Terminal_text.single_line held.kta_tool)
                   20)
                (fit_width
                   (Masc_tui_answering.duration_text remaining ^ " left")
                   16)
                (Terminal_text.single_line held.kta_question ^ " — "
                ^ Terminal_text.single_line_or ~default:"(not provided)"
                    held.kta_because)
          | Some (Gate_row pending) ->
              (* The age is not worker duration. A durable row survives after
                 Auto Judge hands off to a human or fails, so pair age with
                 the canonical phase instead of calling every row waiting. *)
              let age =
                match pending.Tui_decode.gp_waiting_s with
                | Some seconds ->
                  Masc_tui_answering.duration_text seconds
                | None -> "?"
              in
              let phase, tone =
                match pending.Tui_decode.gp_phase with
                | Gate_queued -> "queued", (Theme.warn ())
                | Gate_judging -> "judging", (Theme.info ())
                | Gate_human_required -> "human", (Theme.warn ())
                | Gate_blocked -> "blocked", (Theme.bad ())
              in
              let phase_cell =
                tone ^ fit_width (age ^ " " ^ phase) 16 ^ Ansi.reset
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width
                   (Terminal_text.single_line pending.Tui_decode.gp_keeper)
                   name_width)
                (fit_width
                   ("gate: "
                   ^ Terminal_text.single_line
                       pending.Tui_decode.gp_display_tool)
                   20)
                phase_cell
                (Terminal_text.single_line_or ~default:"(no input preview)"
                   pending.Tui_decode.gp_input_preview)
        in
        let is_selected = idx = state.approval_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ line))
        else
          box_line buf cols ("  " ^ line)
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s\n" detail_line);

  let metadata_line, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> "", ""
    | Some (Operator_row approval) ->
        let expires =
          Terminal_text.single_line_or ~default:"-" approval.ap_expires_at
        in
        let payload =
          Masc_tui_operator_projection.approval_payload_for_terminal
            approval.ap_payload
        in
        ( Printf.sprintf "  %strace=%s  created=%s  expires=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line approval.ap_trace_id) 18)
            (Terminal_text.single_line approval.ap_created_at)
            expires Ansi.reset
        , Printf.sprintf "  %spayload=%s%s" Ansi.dim
            (fit_width payload (max 8 (cols - 12)))
            Ansi.reset )
    | Some (Keeper_tool_row held) ->
        ( Printf.sprintf "  %skeeper=%s  call=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line held.kta_keeper) 20)
            (fit_width (Terminal_text.single_line held.kta_tool_call_id) 28)
            Ansi.reset
        , Printf.sprintf "  %sargs=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.preview_line held.kta_args)
               (max 8 (cols - 9)))
            Ansi.reset )
    | Some (Gate_row pending) ->
        (* The keeper name is not repeated here: the line directly above is
           "<keeper> -> <what it wants>", so this line spends its width on
           what that line cannot say. Where the command would run comes first
           among those -- the same command means different things on the host
           and in a container -- and the approval id, a uuid nobody reads off
           a screen, takes what is left. *)
        (* Ordered by what survives a narrow window. The sandbox is short and
           decides the most -- host or container -- so it goes first; the
           working directory refines it and is long, so it truncates first.
           At eighty columns the old order lost the sandbox entirely. *)
        let site =
          match
            pending.Tui_decode.gp_execution_sandbox,
            pending.Tui_decode.gp_execution_cwd
          with
          | None, None -> ""
          | sandbox, cwd ->
            Printf.sprintf "sandbox=%s  at=%s"
              (Terminal_text.single_line_or ~default:"?" sandbox)
              (Terminal_text.single_line_or ~default:"?" cwd)
        in
        (* The operation is already the right-hand side of the line above
           whenever the two agree, which is every operation but an identity
           call. Repeating it there costs the width this line needs. *)
        let operation =
          let name = Terminal_text.single_line pending.Tui_decode.gp_operation in
          if String.equal name
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
          then ""
          else Printf.sprintf "operation=%s" (fit_width name 20)
        in
        let described =
          List.filter (fun part -> part <> "") [ operation; site ]
          |> String.concat "  "
        in
        ( Printf.sprintf "  %s%s  approval=%s%s" Ansi.dim
            described
            (fit_width (Terminal_text.single_line pending.Tui_decode.gp_id)
               (max 8 (cols - 22 - Message_layout.display_width described)))
            Ansi.reset
        , Printf.sprintf "  %sinput=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.single_line_or ~default:"(no input preview)"
                  pending.Tui_decode.gp_input_preview)
               (max 8 (cols - 10)))
            Ansi.reset )
  in
  Buffer.add_string buf (Printf.sprintf "%s\n%s\n" metadata_line payload_line);

  Buffer.add_buffer buf ask_buf;

  let hints = question_hints state
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

let ask_question_page_size state = snd (ask_question_viewport state)

let ask_question_scroll_limit state =
  let lines, room = ask_question_viewport state in
  max 0 (List.length lines - room)

let render_question_reader (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let asks = question_asks state in
  let selected = List.nth_opt asks state.ask_cursor in
  box_top buf cols;
  box_line buf cols (screen_title " MASC Approvals / Questions");
  box_line buf cols
    (match selected with
     | None -> "  No questions waiting"
     | Some row ->
         let draft = Ask_projection.draft_for state.ask_draft ~row in
         let answered = List.filter (fun question ->
             Option.is_some (Ask_projection.response_for draft ~question)) row.ar_questions |> List.length in
         Printf.sprintf "  %s%s · Ask %d/%d · Question %d/%d · %d answered%s"
           (Theme.warn ()) (Terminal_text.single_line row.ar_keeper)
           (state.ask_cursor + 1) (List.length asks) (state.ask_question_cursor + 1)
           (List.length row.ar_questions) answered Ansi.reset);
  box_line buf cols
    (if Option.is_some state.ask_text_entry then "  Enter: save written answer · Esc: cancel writing"
     else
       "  Left/Right: previous/next question · [/]: previous/next ask · "
       ^ "PgUp/PgDn: page · Home/End: top/bottom · Esc: approvals");
  box_divider buf cols;
  let lines, room = ask_question_viewport state in
  let limit = max 0 (List.length lines - room) in
  let scroll =
    if Option.is_some state.ask_text_entry then limit
    else max 0 (min state.ask_question_scroll limit)
  in
  let lines_window = Rows.of_list ~first:scroll ~height:room lines in
  for i = 0 to room - 1 do
    match Rows.at lines_window (scroll + i) with
    | Some line -> Buffer.add_string buf (line ^ "\n")
    | None -> box_empty buf cols
  done;
  box_divider buf cols;
  box_line buf cols
    (if Option.is_some state.ask_text_entry then "  Writing answer · Enter saves locally before you send"
     else Printf.sprintf "  Lines %d-%d/%d · PgUp/PgDn or wheel to read"
       (if lines = [] then 0 else scroll + 1) (min (List.length lines) (scroll + room)) (List.length lines));
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints:(question_hints state));
  finish_surface state ~surface_key:"approval-questions" ~rows:terminal_rows ~cols buf

(* Who wrote it, in one column. 1561 of this workspace's 2171 posts are system
   posts and 588 are automation; the 22 a person wrote are what an operator is
   scanning for, so those are the ones that get a mark. *)
(* The widths now live beside their column names in [Render_schedule], which
   is the one place the header and the rows both read. The age column is sized
   for the widest [span_text] draws, "1d00h": a board's oldest live threads are
   days old, so the day tier is the one it holds. *)

(* Four cells of lead sit ahead of the mark on the header and on every row, so
   the table gets what the frame leaves less those four. Summing the widths and
   their gaps by hand is what the column description replaced: the sum was
   written once for the rows and once for the header, and the two drifted until
   REPLIES sat past the right edge whatever the title was sized to. *)
let board_table_lead = 4

let board_title_width ~cols =
  Render_schedule.board_title_width
    ~inner_width:(max 0 (framed_inner_width cols - board_table_lead))

(* Colour here, the glyph in {!Masc_tui_board_kind_mark}, which the help sheet
   reads from the same function. Nothing explained these marks anywhere before:
   a reader met "@" in the first column and had to guess. *)
let board_kind_mark kind =
  let mark = Masc_tui_board_kind_mark.glyph kind in
  match kind with
  | Some Post_by_person -> Ansi.bold ^ (Theme.info ()) ^ mark ^ Ansi.reset
  | Some Post_by_automation -> (Theme.warn ()) ^ mark ^ Ansi.reset
  | Some (Post_kind_unknown _) -> (Theme.warn ()) ^ mark ^ Ansi.reset
  | Some Post_by_system | None -> mark

(** The draft pane. For a new post the commit-message convention is stated
    on screen rather than assumed: first line is the title, the rest is the
    body. A reply sends the whole draft as one comment, so its hint drops
    the title convention. A draft taller than the viewport shows its tail,
    where the caret is -- the operator is always writing at the bottom. *)
let render_board_compose (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let draft_content = Buffer.contents state.board_draft in
  let draft_chars = String.length draft_content in
  let raw_lines = String.split_on_char '\n' draft_content in
  let line_count = List.length raw_lines in
  let kind_line =
    match state.board_compose_reply_to with
    | Some post_id ->
        Printf.sprintf "  comment on %s  Enter: newline  Ctrl-E: $EDITOR"
          (fit_width (Terminal_text.single_line post_id) 16)
    | None ->
        let hearth_label =
          match state.board_compose_hearth with
          | Some h -> "#" ^ h
          | None -> "(default)"
        in
        Printf.sprintf "  first line: title  rest: body  hearth: %s  Enter: newline  Ctrl-E: $EDITOR"
          hearth_label
  in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s(%d lines, %d chars)%s"
    (screen_title " MASC Board")
    (Masc_tui_theme.tone Masc_tui_theme.Accent)
    (match state.board_compose_reply_to with
     | Some _ -> "reply" | None -> "new post")
    Ansi.reset
    (connection_badge state)
    Ansi.dim line_count draft_chars Ansi.reset
  in
  let addressing_kind = Board_composer.analyze_addressing draft_content in
  let addressing_line = Board_composer.format_addressing_hint ~max_cells:cols addressing_kind in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line buf cols (Ansi.dim ^ kind_line ^ Ansi.reset);
  box_line buf cols addressing_line;
  (match state.board_post_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;
  let text_width = max 10 (cols - 8) in
  let draft_lines =
    raw_lines
    |> List.concat_map (fun line ->
           let w = Message_layout.wrap_words ~max_cells:text_width
             (Terminal_text.single_line line) in
           if w = [] then [ "" ] else w)
  in
  let error_rows = if Option.is_some state.board_post_error then 1 else 0 in
  let chrome_top_rows = 5 + error_rows in
  let content_height = max 1 (rows - (chrome_top_rows + 3)) in
  let visible_lines =
    let total = List.length draft_lines in
    if total > content_height then
      List.filteri
        (fun index _ -> index >= total - content_height)
        draft_lines
    else draft_lines
  in
  List.iter
    (fun line ->
       box_line buf cols
         ("  " ^ fit_width line (cols - 8)))
    visible_lines;
  box_bottom buf cols;
  let prompt =
    if state.board_compose_armed then
      let hearth_hint =
        if Option.is_none state.board_compose_reply_to then "  h:cycle hearth"
        else ""
      in
      Printf.sprintf "s:send  e:edit in $EDITOR%s  d:discard  esc:keep writing" hearth_hint
    else
      (* No [q] here. While the draft has the keys, [q] is a printable
         scalar and goes into the draft like any other letter; the footer
         offered it as quit, so the operator who took the offer got a [q]
         in their post. Leaving the pane is [esc] and then [d], which the
         armed footer above names. *)
      "type to write  Ctrl-E:$EDITOR  esc:menu  Tab:surfaces"
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints:prompt);
  let cursor =
    if state.board_compose_armed then
      Frame_presenter.Hidden
    else
      let (row, column) =
        Board_composer.compute_caret_position
          ~chrome_top_rows:(chrome_top_rows + 1)
          ~cols ~visible_lines
      in
      Frame_presenter.Visible_at { row = min (rows - 2) row; column }
  in
  finish_frame_with_strip state ~surface_key:"board-compose" ~cursor ~rows
    ~cols buf


(* Rows the Board list spends before any post: the box, its title and the
   hearth census under it, the column header and its rule, then the closing
   rule, the border, the detail line and the footer. Nine until the census
   line joined them; naming it is what lets a tenth reader check the
   arithmetic instead of trusting a literal that two places have to agree
   on. *)
let board_list_chrome_rows = 11

(* Every hearth on the board and how many posts it holds, with the one being
   read marked. [f] walked this list and drew none of it, so narrowing was a
   press into the dark: a reader could not see which hearths existed, which
   held most of the board, or where in the cycle they had got to.

   Counts come from the board's own census rather than the page on screen.
   The page is one listing of fifty and the hearth it belongs to may hold
   hundreds; a count taken from it would understate every hearth and
   understate the crowded ones most. *)
let board_hearth_census_line ~cols (state : state) =
  match state.board_hearths with
  | [] ->
      Ansi.dim
      (* The row above this one always names H, so the empty census says
         only what is its own to say: that nothing is counted yet, and
         that f walks hearths once something is. It used to open with
         "H:choose hearth" too, which put that key on two adjacent rows
         whenever the board had no counted hearth. *)
      ^ "  f/F:next/previous · none counted yet \xe2\x80\x94 f narrows once they are"
      ^ Ansi.reset
  | census ->
      let total = List.fold_left (fun sum (_, count) -> sum + count) 0 census in
      (* Banded over the whole census, then cut to what fits. Banding the
         visible slice would rank each hearth against the four that happened
         to fit beside it, which is a different question from the one the row
         asks. *)
      let banded = Magnitude.of_counts census in
      let entry (name, count, band) =
        let selected = Option.equal String.equal state.board_hearth (Some name) in
        let text = Printf.sprintf "%s %d" (Terminal_text.single_line name) count in
        (* Selection wins over size: which hearth is being read is a different
           axis from how big it is, and the reverse block says the first
           without leaving the second unsaid -- the count is in the text. *)
        if selected then Ansi.reverse ^ text ^ Ansi.reset
        else magnitude_tone band ^ text ^ Ansi.reset
      in
      (* What fits, then how many it could not carry. The board here holds
         eleven hearths and a narrow pane holds four of them; a row sized by
         how many exist is a row that runs off the edge on the next one. *)
      let rec take kept used = function
        | [] -> (List.rev kept, 0)
        | ((name, count, _) as banded_entry) :: rest ->
            let width =
              Message_layout.display_width
                (Printf.sprintf "%s %d" name count)
              + if kept = [] then 0 else 3
            in
            if used + width > max 8 (cols - 26) then
              (List.rev kept, 1 + List.length rest)
            else take (banded_entry :: kept) (used + width) rest
      in
      let kept, dropped = take [] 0 banded in
      let shown =
        List.map entry kept |> String.concat (Ansi.dim ^ "  \xc2\xb7  " ^ Ansi.reset)
      in
      Printf.sprintf "  %shearths%s %s%s%s" Ansi.dim Ansi.reset shown
        (if dropped = 0 then ""
         else Printf.sprintf "%s  \xc2\xb7  +%d%s" Ansi.dim dropped Ansi.reset)
        (Printf.sprintf "%s   %d posts%s" Ansi.dim total Ansi.reset)

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  (* Which sub-board is being read. Said only when the list is narrowed: "all
     hearths" is what a reader assumes, and 24 of them share this board with
     1550 of 2171 posts in one, so a narrowed list that did not say so would
     look like a board that had gone quiet. *)
  let hearth =
    match state.board_hearth with
    | None -> ""
    | Some hearth ->
        Printf.sprintf "  %shearth:%s%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line hearth) Ansi.reset
  in
  (* No sort here. The row under this one says it in the words that answer
     what the order is -- "latest changed first" rather than "updated" -- and
     it is the row with space for them. "updated" is the token the board list
     is asked for (the request's sort_by) and the token the workspace config
     keeps, so a title that spelled it showed the operator a protocol value. *)
  let header = Printf.sprintf "%s (%d)%s  %s  %s"
    (screen_title " MASC Board")
    count hearth timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_line_styled buf cols ~style:(Theme.recede ())
    (* The sort first. It has no other home on this surface now, and this row
       is cut to the frame's inner width: at 34 columns the key hint alone
       spent all 30 cells, so the order the rows are in was invisible while
       the key to change it was not. H is in the sheet under [?]. *)
    (Printf.sprintf "  Sort [s]: %s · H:choose hearth"
       (board_sort_explanation state.board_sort));
  box_line buf cols (board_hearth_census_line ~cols state);
  box_divider buf cols;
  (* The header is laid out by the same arithmetic as the rows below it,
     because a header laid out by its own is a header that stops describing
     them. It did: the rows size their title to [cols - 68] and the header
     claimed a fixed 20, so at eighty columns the header ran eight cells
     long. The overflow pushed SCORE into the frame's edge and REPLIES off
     it -- two columns still drawn on every row, with nothing left saying
     what they were. The mark ahead of the id is one cell and the header
     reserved two, which put every label one cell right of its data.

     The column description in [Render_schedule] is the one place either of
     them asks. *)
  let title_w = board_title_width ~cols in
  box_line_styled buf cols ~style:(Theme.recede ())
    (String.make board_table_lead ' '
     ^ Render_schedule.board_header_row ~title_width:title_w);
  box_divider buf cols;

  let board_list_error =
    Terminal_text.optional_single_line state.board_list_error
  in
  let render_list_error err =
    box_line buf cols (data_unreliable_row ~cols err)
  in
  if count = 0 then begin
    (match board_list_error with
     | Some err -> render_list_error err
     | None ->
         box_line buf cols (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset));
    for _ = 1 to rows - board_list_chrome_rows do
      box_empty buf cols
    done
  end else begin
    Option.iter render_list_error board_list_error;
    let error_rows = if Option.is_some board_list_error then 1 else 0 in
    let content_height = max 0 (rows - board_list_chrome_rows - error_rows) in
    let scroll_offset =
      if state.board_cursor >= content_height then
        state.board_cursor - content_height + 1
      else 0
    in
    (* One clock read for the whole page, so two rows drawn in the same frame
       cannot report ages a tick apart. *)
    let now_unix = Unix.gettimeofday () in
    let board_posts_window = Rows.of_list ~first:scroll_offset ~height:content_height state.board_posts in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      match Rows.at board_posts_window idx with
      | None -> box_empty buf cols
      | Some p -> begin
        let is_selected = idx = state.board_cursor in
        (* The age is since the post or one of its comments last moved. A
           board's list had no timestamp at all, so "what is still alive" --
           the question the [recent] and [updated] sort orders answer -- could
           only be read off the order the rows happened to arrive in. Spelled
           with the same ladder the Approvals queue uses, so a span reads the
           same on both. *)
        let hearth_text =
          match Terminal_text.optional_single_line p.bp_hearth with
          | Some h when not (String.equal h "") -> "#" ^ h
          | _ -> ""
        in
        let score_text =
          if p.bp_votes > 0 then Printf.sprintf "▲%+d" p.bp_votes
          else if p.bp_votes < 0 then Printf.sprintf "▼%d" p.bp_votes
          else " 0"
        in
        let replies_text =
          if p.bp_comment_count > 0 then Printf.sprintf "%d" p.bp_comment_count
          else "0"
        in
        let values =
          { Render_schedule.brow_mark = board_kind_mark p.bp_kind
          ; brow_id = Terminal_text.single_line p.bp_id
          ; brow_hearth = hearth_text
          ; brow_author = Terminal_text.single_line p.bp_author
          ; brow_title = Terminal_text.single_line p.bp_title
          ; brow_age = Message_layout.span_text (now_unix -. p.bp_updated_at)
          ; brow_score = score_text
          ; brow_replies = replies_text
          }
        in
        let styles =
          { Render_schedule.bstyle_id = Theme.recede ()
          ; bstyle_hearth =
              if String.equal hearth_text "" then Ansi.dim else (Theme.info ())
          ; bstyle_author = Theme.ok ()
          ; bstyle_age = Ansi.dim
          ; bstyle_score = board_score_style p.bp_votes
          ; bstyle_replies =
              if p.bp_comment_count > 0 then (Theme.ok ()) else Ansi.dim
          }
        in
        let content =
          String.make board_table_lead ' '
          ^ Render_schedule.board_row ~styles ~title_width:title_w values
        in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr content)
        else
          box_line buf cols content
      end
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));

  finish_surface state ~surface_key:"board-list" ~rows:terminal_rows
      ~cols buf

(* Owned by the single render loop, like the chat Markdown cache. Only the
   currently read document is retained; input and live status are never cached. *)
let board_read_layout = Board_read_layout.create ()
;;

(** Render the Board surface (read view). *)
(* The read post alone -- borders, header, body, comments -- at [cols]
   wide, footer excluded, so a caller can lay it beside the post list.
   Returns the scroll the frame used. *)
let board_read_pane (state : state) (list_post : board_post) ~rows ~cols buf =
  let detail =
    Board_detail.view_for state.board_detail ~post_id:list_post.bp_id
  in
  let post =
    match detail with
    | Board_detail.Ready (detail_post, _) -> detail_post
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        list_post
  in

  let hearth_tag =
    match Terminal_text.optional_single_line post.bp_hearth with
    | Some h when not (String.equal h "") ->
        Printf.sprintf "  %s#%s%s" (Theme.info ()) h Ansi.reset
    | _ -> ""
  in
  let score_chip =
    if post.bp_votes > 0 then
      Printf.sprintf "%s▲%+d%s" (board_score_style post.bp_votes) post.bp_votes Ansi.reset
    else if post.bp_votes < 0 then
      Printf.sprintf "%s▼%d%s" (board_score_style post.bp_votes) post.bp_votes Ansi.reset
    else
      Printf.sprintf "%s 0%s" (board_score_style post.bp_votes) Ansi.reset
  in
  let replies_chip =
    if post.bp_comment_count > 0 then
      Printf.sprintf "%s💬%d%s" (Theme.ok ()) post.bp_comment_count Ansi.reset
    else
      Printf.sprintf "%sc0%s" Ansi.dim Ansi.reset
  in
  let header =
    Printf.sprintf "%s  %s[%s]%s%s  %s  %s"
      (screen_title " MASC Board")
      (Masc_tui_theme.tone Masc_tui_theme.Accent)
      (fit_width (Terminal_text.single_line post.bp_id) 12)
      Ansi.reset
      hearth_tag
      score_chip
      replies_chip
  in

  box_top buf cols;
  box_line buf cols header;
  box_line buf cols
    (Printf.sprintf "  Actions:  %s[c]%s Reply   %s[v/V]%s Vote (+/-)   %s[Y]%s Copy Link   %s[Esc]%s Back"
       (Theme.ok ()) Ansi.reset
       (Theme.warn ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.recede ()) Ansi.reset);
  box_divider buf cols;

  let title_line = Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line post.bp_title) (cols - 6))
    Ansi.reset
  in
  box_line buf cols title_line;
  let author_chip =
    let author_name = Terminal_text.single_line post.bp_author in
    match post.bp_kind with
    | Some Post_by_automation ->
        Printf.sprintf "%s@%s%s %s[Keeper]%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
    | Some Post_by_person ->
        Printf.sprintf "%s@%s%s %s[Author]%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
          (Theme.info ())
          Ansi.reset
    | _ ->
        Printf.sprintf "%s@%s%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "  %s  %s\xc2\xb7%s  %s  %s\xc2\xb7%s  %s%s%s"
       author_chip
       Ansi.dim Ansi.reset
       (Terminal_text.single_line post.bp_created_at)
       Ansi.dim Ansi.reset
       Ansi.dim
       (Link.reference Board_post (Terminal_text.single_line post.bp_id))
       Ansi.reset);
  box_divider buf cols;

  let source : Board_read_layout.source =
    { post; detail; related_posts = state.board_posts;
      keeper_names = List.map (fun (k : Tui_decode.keeper) -> k.k_name) state.keepers;
      columns = cols;
      styles = [ Theme.info (); Theme.warn (); Theme.bad (); Theme.recede ();
                 Masc_tui_theme.tone Masc_tui_theme.Accent ];
      table_frame = !table_frame_enabled }
  in
  let document =
    Board_read_layout.get board_read_layout ~source ~render:(fun () ->
      (* Body lines *)
      let text_width = cols - 8 in
      (* Sanitised a line at a time. A newline is a control byte, so sanitising the
         body whole escaped every break and the post arrived as one unbroken run
         with "\x0A" printed through it. *)
      (* Board posts are written in markdown -- headings, fences, rules -- and were
         drawn as the source they were typed as. The chat pane has rendered them
         for a while; this surface reads the same kind of document. *)
      let body_lines =
        Message_layout.wrap_body
          ~markdown:board_document_markdown
          ~max_cells:text_width
          ~sanitize:Terminal_text.single_line
          post.bp_body
      in
      (* What this post points at, and who else points at the same thing.
         Read from the references the writer actually wrote -- [Link.scan] takes
         only what [Link.reference] could have produced. An id spelled in prose is
         not a link: a connection the writer did not make is one nobody checked,
         and following it would go somewhere they never meant.

         Appended to the body so the surface's own scroll carries them; this pane
         measures its lines rather than reserving rows. *)
      let referenced = Link.scan post.bp_body in
      let related =
        match referenced with
        | [] -> []
        | referenced ->
          state.board_posts
          |> List.filter (fun (other : board_post) ->
            (not (String.equal other.bp_id post.bp_id))
            && List.exists
                 (fun hit -> List.mem hit referenced)
                 (Link.scan other.bp_body))
      in
      let reference_lines =
        match referenced with
        | [] -> []
        | referenced ->
          (Ansi.dim ^ "" ^ Ansi.reset)
          :: (Ansi.bold ^ "  POINTS AT" ^ Ansi.reset)
          :: List.map
               (fun (kind, id) ->
                 (* [Link.parse] percent-decodes the id segment, so a body that
                    writes masc://board/%1b%5b2J hands this line real escape
                    bytes. The kind is a closed variant and needs no sanitizer;
                    the id is whatever the writer typed. *)
                 Printf.sprintf "  %s%-10s %s%s" Ansi.reset
                   (Link.kind_label kind)
                   (fit_width (Terminal_text.single_line id) (max 8 (cols - 16)))
                   Ansi.reset)
               referenced
      in
      let related_lines =
        match related with
        | [] -> []
        | related ->
          (Ansi.dim ^ "" ^ Ansi.reset)
          :: (Ansi.bold
              ^ Printf.sprintf "  ALSO ABOUT THIS (%d)" (List.length related)
              ^ Ansi.reset)
          :: (related
              |> List.filteri (fun index _ -> index < 5)
              |> List.map (fun (other : board_post) ->
                   Printf.sprintf "  %s  %s%s%s"
                     (fit_width (Terminal_text.single_line other.bp_id) 12)
                     Ansi.dim
                     (fit_width (Terminal_text.single_line other.bp_title)
                        (max 8 (cols - 26)))
                     Ansi.reset))
      in
      let body_lines = body_lines @ reference_lines @ related_lines in
      let detail_lines =
        match detail with
        | Board_detail.Absent ->
            [Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset]
        | Board_detail.Loading ->
            [Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset]
        | Board_detail.Failed error ->
            [ (Theme.bad ()) ^ "  Board detail unavailable: "
              ^ fit_width (Terminal_text.single_line error) (max 1 (cols - 32))
              ^ Ansi.reset
            ]
        | Board_detail.Ready (_, comments) ->
            (* A reply and the thing it answers used to sit at one indent in clock
               order, so a thread read as unrelated remarks. [parent_id] has been
               on the wire since comments existed -- 152 of this workspace's 1364
               comments carry one -- and the pane simply never decoded it. *)
            Board_comment_thread.order comments
            |> List.concat_map
              (fun (depth, c) ->
                 let rail =
                   if depth <= 0 then ""
                   else
                     let bar = (Theme.recede ()) ^ "\xe2\x94\x82 " ^ Ansi.reset in
                     let indent = String.make (2 * (min depth 4 - 1)) ' ' in
                     indent ^ bar
                 in
                 let author = Terminal_text.single_line c.bc_author in
                 let created_at = Terminal_text.single_line c.bc_created_at in
                 let author_role =
                   if String.equal author (Terminal_text.single_line post.bp_author) then
                     " " ^ (Theme.info ()) ^ "[Author]" ^ Ansi.reset
                   else if List.exists (fun (k : Tui_decode.keeper) -> String.equal k.k_name author) state.keepers then
                     " " ^ (Theme.warn ()) ^ "[Keeper]" ^ Ansi.reset
                   else ""
                 in
                 let heading =
                   Printf.sprintf "  %s%s@%s%s%s  %s%s%s"
                     rail
                     (Masc_tui_theme.tone Masc_tui_theme.Accent)
                     author
                     Ansi.reset
                     author_role
                     Ansi.dim
                     created_at
                     Ansi.reset
                 in
                 let body =
                   Message_layout.wrap_body ~markdown:board_document_markdown
                     ~max_cells:
                       (max 1
                          (cols - 10 - Message_layout.display_width rail))
                     ~sanitize:Terminal_text.single_line c.bc_content
                 in
                 match body with
                 | [ line ] -> [ heading ^ "  " ^ line ]
                 | [] -> [ heading ^ "  " ^ Ansi.dim ^ "\xc2\xb7" ^ Ansi.reset ]
                 | lines ->
                     heading
                     :: List.map
                          (fun line -> "  " ^ rail ^ "  " ^ line) lines)
      in
      (body_lines, detail_lines))
  in
  let total_lines = Board_read_layout.body_count document in
  let detail_line_count = Board_read_layout.comment_count document in
  let row_budget =
    Render_schedule.allocate_board_read ~terminal_rows:rows
      ~body_line_count:total_lines
      ~comment_count:detail_line_count
  in
  let content_height = row_budget.body_rows in
  let comment_height = row_budget.comment_rows in
  let scroll =
    Render_schedule.project_board_read_scroll ~body_line_count:total_lines
      ~body_rows:content_height
      ~comment_count:detail_line_count
      ~comment_rows:comment_height state.board_scroll
  in
  for i = 0 to content_height - 1 do
    let idx = i + scroll.body_offset in
    if idx < total_lines then
      box_line buf cols ("  " ^ Board_read_layout.body_line document idx)
    else
      box_empty buf cols
  done;

  if comment_height > 0 then begin
    box_divider buf cols;
    box_line buf cols (Ansi.bold ^ "  Comments" ^ Ansi.reset);
    for i = 0 to comment_height - 1 do
      box_line buf cols (Board_read_layout.comment_line document (i + scroll.comment_offset))
    done
  end;

  (* Reading without a position is guessing: the post body and the comment
     thread each name where they stand, the same "rows X-Y of Z" shape the
     other reading surfaces carry. *)
  if total_lines > content_height || detail_line_count > comment_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "post rows %d-%d of %d%s"
         (min total_lines (scroll.body_offset + 1))
         (min total_lines (scroll.body_offset + content_height))
         total_lines
         (if detail_line_count > comment_height then
            Printf.sprintf "  \xc2\xb7  comments rows %d-%d of %d"
              (min detail_line_count (scroll.comment_offset + 1))
              (min detail_line_count (scroll.comment_offset + comment_height))
              detail_line_count
          else ""));
  box_bottom buf cols;
  scroll.normalized_scroll

(* The post list beside the read: position context with the open post
   marked, exactly the roster-beside-detail shape. *)
let board_list_pane (state : state) ~(open_post : board_post) ~rows ~cols buf =
  let selected =
    let rec find i = function
      | [] -> 0
      | (post : board_post) :: rest ->
          if String.equal post.bp_id open_post.bp_id then i
          else find (i + 1) rest
    in
    find 0 state.board_posts
  in
  let format_sidebar_post (post : board_post) =
    let hearth_prefix =
      match Terminal_text.optional_single_line post.bp_hearth with
      | Some h when not (String.equal h "") -> "#" ^ h ^ " "
      | _ -> ""
    in
    let vote_prefix =
      if post.bp_votes > 0 then Printf.sprintf "+%d " post.bp_votes
      else if post.bp_votes < 0 then Printf.sprintf "%d " post.bp_votes
      else ""
    in
    Printf.sprintf "%s%s%s" hearth_prefix vote_prefix
      (Terminal_text.single_line post.bp_title)
  in
  write_list_sidebar buf ~rows ~cols ~title:"Board"
    ~focused:(state.board_focus = Left_pane)
    ~labels:(List.map format_sidebar_post state.board_posts)
    ~selected

let render_board_read (state : state) (list_post : board_post) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let footer =
    let pane_hint =
      if cols >= keeper_split_threshold_cols && not state.board_detail_wide then
        "  h/l:pane  Ctrl-W:switch"
      else ""
    in
    footer_line state ~max_cells:cols
      ~hints:
        (Printf.sprintf
           "j/k:%s  [/]:post  PgUp/PgDn:page%s  z:wide  Y:copy link  left/Esc:back  c:reply  r:refresh  Tab:next"
           (if state.board_focus = Left_pane then "posts" else "scroll")
           pane_hint)
  in
  if cols < keeper_split_threshold_cols || state.board_detail_wide then begin
    let scroll = board_read_pane state list_post ~rows ~cols buf in
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end
  else begin
    let left_cols = keeper_roster_pane_cols in
    let right_cols = cols - left_cols in
    let left_buf = Buffer.create 1024 in
    let right_buf = Buffer.create 4096 in
    board_list_pane state ~open_post:list_post ~rows ~cols:left_cols left_buf;
    let scroll =
      board_read_pane state list_post ~rows ~cols:right_cols right_buf
    in
    write_two_panes buf ~left_cols:left_cols ~left:left_buf
      ~right:right_buf;
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end

(* The lifecycle as a rail, not a single word. The phase says where the goal
   is; it never said what the stages are or which way they run, so "what does
   [c] do here" was a question the screen could not answer. The occupied stop
   is bracketed and keeps its colour, the rest stay dim.

   [Dropped] is not a stop on this line -- it leaves the line -- so a dropped
   goal draws what it is and how to come back instead of highlighting a stop
   on a rail it is no longer on. *)
let planning_stage_rail (phase : Goal_phase.t) =
  let stop stage =
    let label = planning_phase_label stage in
    if stage = phase then
      planning_phase_color stage ^ Ansi.bold ^ "[" ^ label ^ "]" ^ Ansi.reset
    else Ansi.dim ^ " " ^ label ^ " " ^ Ansi.reset
  in
  let arrow = Ansi.dim ^ "\xe2\x94\x80\xe2\x96\xb6" ^ Ansi.reset in
  match phase with
  | Goal_phase.Dropped ->
    planning_phase_color Goal_phase.Dropped
    ^ Ansi.bold ^ "[dropped]" ^ Ansi.reset
    ^ Ansi.dim ^ "  (off the line; [o] puts it back on executing)" ^ Ansi.reset
  | Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation | Goal_phase.Completed ->
    String.concat arrow
      [ stop Goal_phase.Executing
      ; stop Goal_phase.Verifying
      ; stop Goal_phase.Awaiting_confirmation
      ; stop Goal_phase.Completed
      ]
;;

(* What moves this goal next, in one sentence, from the pair the operator can
   see separately but had to combine themselves: the phase and the judge's
   last word. [executing] with a refusal on the ledger is a different
   instruction from [executing] with nothing on it, and both drew the same
   word. Only the goal phase decides here -- the linked tasks have their own
   surface and their own verdicts. *)
let planning_next_step (goal : planning_goal) =
  match goal.pg_phase, goal.pg_proof with
  | Goal_phase.Executing, Tui_decode.Proof_refuted _ ->
    ( (Theme.bad ())
    , "refused - fix what the verdict names below, then [c] to resubmit" )
  | Goal_phase.Executing, _ ->
    ( Ansi.dim
    , "work the linked tasks, then [c] to submit it for verification" )
  | Goal_phase.Verifying, _ ->
    ( (Theme.warn ())
    , "with the completion judge - nothing to press; [c] re-arms the request" )
  | Goal_phase.Awaiting_confirmation, _ -> (Theme.warn (), "proof passed - operator confirmation required via goal confirmation CLI")
  | Goal_phase.Completed, _ -> (Ansi.dim, "reached its target - [o] reopens it")
  | Goal_phase.Dropped, _ -> (Ansi.dim, "abandoned - [o] reopens it")
;;

(* The line under the list, for the goal the cursor is on. A verdict without its
   reason is a colour and nothing else; the reason is what the judge produced
   and the only thing that says what to do next. *)
let planning_proof_detail (goal : planning_goal) =
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some ((Theme.ok ()), "proven")
  | Tui_decode.Proof_proven (Some evidence) -> Some ((Theme.ok ()), "proven: " ^ evidence)
  | Tui_decode.Proof_refuted None -> Some ((Theme.bad ()), "refused")
  | Tui_decode.Proof_refuted (Some reason) -> Some ((Theme.bad ()), "refused: " ^ reason)
  | Tui_decode.Proof_pending -> Some ((Theme.warn ()), "waiting for the completion judge")
  | Tui_decode.Proof_stale _ ->
      Some ((Theme.warn ()), "criterion changed; previous proof is historical")
  | Tui_decode.Proof_unreadable None ->
      Some ((Theme.warn ()), "verification ledger unreadable")
  | Tui_decode.Proof_unreadable (Some detail) ->
      Some ((Theme.warn ()), "verification ledger unreadable: " ^ detail)
  | Tui_decode.Proof_idle ->
      (* Nothing from the judge. A keeper's own note is the next best thing the
         row has to say, and it is what the operator wrote there to be read. *)
      Option.map
        (fun note -> (Ansi.dim, "note: " ^ note))
        (Terminal_text.optional_single_line goal.pg_last_review_note)
;;

let planning_selected_detail (goal : planning_goal) =
  let metric =
    match
      Terminal_text.optional_single_line goal.pg_metric,
      Terminal_text.optional_single_line goal.pg_target_value
    with
    | Some name, Some target ->
        Printf.sprintf "metric: %s \xe2\x86\x92 %s" name target
    | Some name, None -> "metric: " ^ name
    | None, Some target -> "target: " ^ target
    | None, None -> "metric: \xe2\x80\x94"
  in
  match planning_proof_detail goal with
  | None -> Ansi.dim, Printf.sprintf "%s \xc2\xb7 %s" goal.pg_id metric
  | Some (colour, proof) ->
      colour,
      Printf.sprintf "%s \xc2\xb7 %s \xc2\xb7 %s" goal.pg_id metric proof
;;

(* Freshness in one short word: the exact timestamps live in the detail
   pane; the row only needs to separate "touched today" from "quiet for
   weeks". A timestamp that does not parse renders nothing here -- the raw
   string is still shown unmodified in the detail pane. *)
let planning_updated_age ~now (goal : planning_goal) =
  match goal.pg_updated_at with
  | None -> None
  | Some iso ->
      Option.map
        (fun then_ ->
           let delta = max 0. (now -. then_) in
           if delta < 60. then "now"
           else if delta < 3600. then
             Printf.sprintf "%dm" (int_of_float (delta /. 60.))
           else if delta < 86400. then
             Printf.sprintf "%dh" (int_of_float (delta /. 3600.))
           else Printf.sprintf "%dd" (int_of_float (delta /. 86400.)))
        (Masc_domain.parse_iso8601_opt iso)

(** Render the Planning surface (list view). *)

let render_planning_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let tail = Buffer.create 256 in
  box_bottom tail cols;
  Buffer.add_string tail
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));
  let tail_rows = count_frame_lines tail in

  let now_unix = Unix.gettimeofday () in
  let now = Unix.localtime now_unix in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let title = planning_workspace_title state ~tab:Planning_goals ~window:"" in
  let modes = Printf.sprintf "sort:%s  filter:%s"
    (planning_sort_label state.planning_sort)
    (planning_filter_label state.planning_filter) in
  let modes_fit_header =
    (* The timestamp can overflow and require a truncation cell after modes. *)
    Message_layout.display_width (title ^ "  " ^ modes) < framed_inner_width cols
  in
  let header = Printf.sprintf "%s%s  %s  %s" title
    (if modes_fit_header then "  " ^ modes else "")
    timestamp (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  (* Show the modes once, but do not hide them behind a clipped title. *)
  if not modes_fit_header then
    box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ modes);
  (* The list below can only show goals the store still holds. A goal that
     completed and left goals.json left every planning surface with it, so
     "what did we finish" had no answer here at all. These two lines are what
     the event log remembers; they sit above the divider because they are not
     rows the cursor walks. *)
  (match state.planning with
   | None -> ()
   | Some planning -> (
     match planning.pl_goal_history with
     | [] -> ()
     | history ->
       let closed =
         List.length
           (List.filter
              (fun (row : planning_goal_history) -> Option.is_some row.pgh_closed_at)
              history)
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  No longer listed: %d · reached an end: %d"
            (List.length history) closed);
       let lifetime_label hours =
         if hours >= 48. then Printf.sprintf "%.1fd" (hours /. 24.)
         else Printf.sprintf "%.1fh" hours
       in
       let named =
         List.map
           (fun (row : planning_goal_history) ->
             (* No title means the goal was opened before the server recorded
                openings, so the id is all there is to call it. *)
             let name =
               match row.pgh_title with
               | Some title -> title
               | None -> row.pgh_goal_id
             in
             match row.pgh_lifetime_hours with
             | Some hours -> name ^ " " ^ lifetime_label hours
             | None -> name)
           history
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         ("  " ^ String.concat " · " named)));
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p ->
        planning_visible_goals ~filter:state.planning_filter
          ~sort:state.planning_sort p.pl_goals
  in
  let count = List.length goals in
  let planning_error =
    Terminal_text.optional_single_line state.planning_error
  in

  (match state.planning with
   | None ->
       (match planning_error with
        | Some err ->
            box_line buf cols (data_unreliable_row ~cols err)
        | None ->
            box_line buf cols (Ansi.dim ^ page_unread_note ^ Ansi.reset));
       for _ = 1 to rows - count_frame_lines buf - tail_rows do
         box_empty buf cols
       done
   | Some p ->
       (* Every phase counts, or the denominator drops the goals waiting on a
          human and reports a completion share higher than the truth. *)
       let total_goals =
         p.pl_rollup.pr_active + p.pl_rollup.pr_verifying
         + p.pl_rollup.pr_awaiting_confirmation + p.pl_rollup.pr_done
         + p.pl_rollup.pr_dropped
       in
       let progress_pct =
         if total_goals > 0 then p.pl_rollup.pr_done * 100 / total_goals else 0
       in
       let bar_width = if cols < 90 then 8 else 12 in
       let progress_bar =
         if total_goals > 0 then
           Printf.sprintf "[%s] %2d%% (%d/%d)"
             (Masc_tui_context_bars.ratio_bar ~width:bar_width
                ~numerator:p.pl_rollup.pr_done ~denominator:total_goals)
             progress_pct p.pl_rollup.pr_done total_goals
         else "no goals"
       in
       let phase_counters =
         Printf.sprintf
           "%s● Exec: %d%s  %s◆ Ver: %d%s  %s◇ Conf: %d%s  %s✓ Done: %d%s  \
            %s✕ Drop: %d%s"
           (planning_phase_color Goal_phase.Executing)
           p.pl_rollup.pr_active Ansi.reset
           (planning_phase_color Goal_phase.Verifying)
           p.pl_rollup.pr_verifying Ansi.reset
           (planning_phase_color Goal_phase.Awaiting_confirmation)
           p.pl_rollup.pr_awaiting_confirmation Ansi.reset
           (planning_phase_color Goal_phase.Completed)
           p.pl_rollup.pr_done Ansi.reset
           (planning_phase_color Goal_phase.Dropped)
           p.pl_rollup.pr_dropped Ansi.reset
       in
       let rollup =
         Printf.sprintf "  Goals: %s%s%s %s  %s│%s  %s"
           Ansi.bold (string_of_int total_goals) Ansi.reset
           progress_bar (Theme.recede ()) Ansi.reset phase_counters
       in
       let backlog_sep =
         Printf.sprintf " %s%s%s " (Theme.recede ())
           Masc_tui_theme.Glyph.breadcrumb_sep Ansi.reset
       in
       let backlog =
         let items =
           [ ("todo", p.pl_backlog.pb_todo, Masc_tui_theme.Glyph.task_todo ^ " todo")
           ; ("claimed", p.pl_backlog.pb_claimed, "claimed")
           ; ("running", p.pl_backlog.pb_running, Masc_tui_theme.Glyph.task_active ^ " running")
           ; ("done", p.pl_backlog.pb_done, Masc_tui_theme.Glyph.task_done ^ " done")
           ; ("cancelled", p.pl_backlog.pb_cancelled, Masc_tui_theme.Glyph.task_cancelled ^ " cancelled")
           ]
         in
         let counts = List.map (fun (k, v, _) -> k, v) items in
         let bands = Magnitude.of_counts counts in
         List.map2
           (fun (_, _, label) (_, value, band) ->
              Printf.sprintf "%s%s=%d%s" (magnitude_tone band) label value
                Ansi.reset)
           items bands
         |> String.concat backlog_sep
       in
       box_line buf cols rollup;
       box_line_styled buf cols ~style:(Theme.info ())
         (match state.planning_baseline with
          | None -> "  Trend: waiting for the first successful reading"
          | Some first ->
              Printf.sprintf "  Net change since %s: Goals done %+d · Tasks done %+d · Goal reviews pending %+d"
                (Terminal_text.single_line first.pl_generated_at)
                (p.pl_rollup.pr_done - first.pl_rollup.pr_done)
                (p.pl_backlog.pb_done - first.pl_backlog.pb_done)
                (p.pl_rollup.pr_verifying - first.pl_rollup.pr_verifying));
       box_line buf cols
         (Printf.sprintf "  %sBacklog:%s %s" Ansi.dim Ansi.reset backlog);
       box_divider buf cols;
       (* The list drew rows and never said what they were. *)
       let phase_width = planning_phase_column + 2 in
       let title_width =
         Render_schedule.planning_title_width
           ~inner_width:(max 1 (framed_inner_width cols - 2))
           ~phase_width
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         ("  " ^ Render_schedule.planning_header_row ~phase_width ~title_width);
       (* What the JUDGE column's marks mean, once, under the header that
          names it. The glyphs are the only part of a row an operator cannot
          read straight off, and every one of them changes what to do next --
          which is why the legend says the marks this list draws and only those.
          Wrap complete explanations within the frame's cell width: a clipped
          legend would lose a verdict and add a truncation mark identical to
          the stale-proof glyph. *)
       (* Reserve the divider, a goal (or empty note), and the selected
          verdict before spending rows on the legend. At the minimum
          height the headers and summary stay in place and a goal remains
          visible; taller frames get the legend back. *)
       let selection_rows = if count = 0 then 0 else 1 in
       let rows_after_legend = 1 + 1 + selection_rows + tail_rows in
       let judge_legend =
         Masc_tui_planning_proof_mark.legend_rows
           ~max_cells:(framed_inner_width cols)
           ~max_rows:(rows - count_frame_lines buf - rows_after_legend)
           (List.map (fun (g : planning_goal) -> g.pg_proof) goals)
       in
       List.iter (box_line_styled buf cols ~style:Ansi.dim) judge_legend;
       box_divider buf cols;

       if count = 0 then begin
         (* An empty filter and an empty store are different facts: the first
            says how to see the rest, the second has nothing to show. *)
         let empty_note =
           match p.pl_goals with
           | [] -> "  (no goals)"
           | _ -> "  no goals in this filter (f to change)"
         in
         box_line buf cols (Ansi.dim ^ empty_note ^ Ansi.reset);
         for _ = 1 to rows - count_frame_lines buf - tail_rows do
           box_empty buf cols
         done
       end else begin
         (* One row is reserved below the list for the selected goal's verdict. *)
         let content_height =
           rows - count_frame_lines buf - selection_rows - tail_rows
         in
         let scroll_offset =
           if state.planning_cursor >= content_height then
             state.planning_cursor - content_height + 1
           else 0
         in
         let goals_window = Rows.of_list ~first:scroll_offset ~height:content_height goals in
         for i = 0 to content_height - 1 do
           let idx = i + scroll_offset in
           match Rows.at goals_window idx with
           | None -> box_empty buf cols
           | Some g -> begin
             let is_selected = idx = state.planning_cursor in
             let status_color = planning_phase_color g.pg_phase in
             let status_label = planning_phase_label g.pg_phase in
            (* The gap belonged to the reading before; the columns space
               themselves now, and an absent date leaves its cell empty rather
               than moving the one beside it. *)
            let due =
              match Terminal_text.optional_single_line g.pg_due_date with
              | Some d -> d
              | None -> ""
            in
             let age =
               match planning_updated_age ~now:now_unix g with
               | Some a -> a
               | None -> ""
             in
             (* What is being done about this goal, on the row itself. The
                detail panel below already resolves the same links, but only
                for the goal under the cursor: reading which of seventeen
                goals had work stuck in verification took seventeen moves.

                [state.tasks] drops terminal rows and the goal links ride
                only on it ([task_of_domain] takes goal_ids as an argument;
                the domain record does not carry them), so this counts open
                work, not progress. A "5 of 12 done" would need the server to
                carry the link on finished rows too.

                One signal, not three: verification is the one that means
                something is not moving, so it wins the cell when both are
                present. *)
             let open_note, open_style =
                let linked =
                  List.filter
                    (fun (t : Tui_decode.task) -> List.mem g.pg_id t.goal_ids)
                    state.tasks
                in
                match linked with
                | [] -> "", ""
                | _ ->
                    let tally predicate =
                      List.length (List.filter predicate linked)
                    in
                    let awaiting =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.AwaitingVerification _ -> true
                          | _ -> false)
                    in
                    let running =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.InProgress _ -> true
                          | _ -> false)
                    in
                    let total = List.length linked in
                    if awaiting > 0 then
                      Printf.sprintf "%d open %d ver" total awaiting, (Theme.warn ())
                    else if running > 0 then
                      Printf.sprintf "%d open %d run" total running, (Theme.info ())
                    else Printf.sprintf "%d open" total, Ansi.dim
             in
             let priority_style =
               match g.pg_priority with
               | 1 -> (Theme.bad ()) ^ Ansi.bold
               | 2 -> (Theme.warn ())
               | 3 -> Ansi.reset
               | _ -> Ansi.dim
             in
             let lead = if is_selected then "> " else "  " in
             let line =
               lead
               ^ Render_schedule.planning_row ~phase_style:status_color
                   ~priority_style ~open_style ~phase_width ~title_width
                   { Render_schedule.prow_phase = "[" ^ status_label ^ "]"
                   ; prow_proof = planning_proof_mark g.pg_proof
                   ; prow_priority = Printf.sprintf "P%d" g.pg_priority
                   ; prow_open = open_note
                   ; prow_title = Terminal_text.single_line g.pg_title
                   ; prow_age = age
                   ; prow_due = due
                   }
             in
             if is_selected then
               box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
             else
               box_line buf cols line
           end
         done;
         match List.nth_opt goals state.planning_cursor with
         | None -> box_empty buf cols
         | Some selected ->
             let colour, text = planning_selected_detail selected in
             box_line buf cols
               (colour ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset)
       end);

  Buffer.add_buffer buf tail;

  finish_surface state ~surface_key:"planning-list" ~rows:terminal_rows
      ~cols buf

(** Render the Planning surface (detail view). *)
(* Border, header, divider, title, phase, due, metric, blank, divider,
   border, footer: the eleven rows the detail draws whatever the goal says.
   A lifecycle arm, a refused request, and each present goal timestamp each
   add one more when they are there, so the block is measured against them
   rather than against a constant that would push the footer off a full
   screen. *)
(* One more than it was: the stage rail took the phase word's row and the
   next-step sentence is a row of its own. Counted here, drawn below. *)
let planning_detail_fixed_rows = 12

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> (Theme.ok ())
  | Planning_detail.Refused -> (Theme.bad ())
  | Planning_detail.Waiting | Planning_detail.Unreadable -> (Theme.warn ())
  | Planning_detail.Note | Planning_detail.Quiet -> Ansi.dim

let planning_detail_pane (state : state)
    ~(armed : Goal_phase.Public_action.t option) ~rows ~cols
    (goal : planning_goal) buf =

  let status_color = planning_phase_color goal.pg_phase in
  let status_label = planning_phase_label goal.pg_phase in
  let header = Printf.sprintf "%s  %s[%s]%s  %s"
    (planning_workspace_title state ~tab:Planning_goals ~window:"")
    status_color (fit_width status_label planning_phase_column) Ansi.reset
    (fit_width (Terminal_text.single_line goal.pg_id) 20)
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols (Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line goal.pg_title) (cols - 6))
    Ansi.reset);
  let prio_color =
    match goal.pg_priority with
    | 1 -> (Theme.bad ()) ^ Ansi.bold
    | 2 -> (Theme.warn ())
    | 3 -> Ansi.reset
    | _ -> Ansi.dim
  in
  let proof_glyph = planning_proof_mark goal.pg_proof in
  box_line buf cols
    (Printf.sprintf "  Stage:   %s   %s"
       (planning_stage_rail goal.pg_phase) proof_glyph);
  let next_colour, next_text = planning_next_step goal in
  box_line buf cols
    (Printf.sprintf "  Next:    %s%s%s" next_colour next_text Ansi.reset);
  let due_text =
    match Terminal_text.optional_single_line goal.pg_due_date with
    | Some d -> d
    | None -> "\xe2\x80\x94"
  in
  let metric_text =
    match Terminal_text.optional_single_line goal.pg_metric with
    | Some m ->
        let target =
          match Terminal_text.optional_single_line goal.pg_target_value with
          | Some t -> " = " ^ t
          | None -> ""
        in
        m ^ target
    | None -> "\xe2\x80\x94"
  in
  box_line buf cols
    (Printf.sprintf "  Target:  %s   Due: %s   Priority: %sP%d%s"
       metric_text due_text prio_color goal.pg_priority Ansi.reset);
  box_line buf cols
    (Printf.sprintf "  Actions:  %s[c]%s Complete   %s[x]%s Drop   %s[o]%s Reopen"
       (Theme.ok ()) Ansi.reset
       (Theme.bad ()) Ansi.reset
       (Theme.info ()) Ansi.reset);
  (* The goal's own timeline, dim like the Board read pane's timestamps:
     when it was opened, when it last moved, when it was last reviewed. *)
  let timestamp_lines =
    List.filter_map
      (fun (label, value) ->
         Option.map
           (fun iso ->
              Planning_detail.timestamp_line ~label
                (Terminal_text.short_timestamp (Terminal_text.single_line iso)))
           value)
      [ "created", goal.pg_created_at
      ; "updated", goal.pg_updated_at
      ; "reviewed", goal.pg_last_review_at
      ]
  in
  List.iter
    (fun line -> box_line_styled buf cols ~style:Ansi.dim line)
    timestamp_lines;
  box_line_styled buf cols ~style:Ansi.dim
    ("  Link: "
     ^ Link.reference Goal (Terminal_text.single_line goal.pg_id));
  (* A lifecycle request is the one state the detail carries between frames,
     so it gets a row rather than an event log: the arm says what the next
     press of the same key would do, and the error says what the server said
     when the last one was refused. *)
  (match armed with
   | Some armed_action ->
       box_line buf cols
         ((Theme.warn ()) ^ Ansi.bold
          ^ Printf.sprintf "  ARMED: %s -- press same key again to submit, any other key to cancel"
             (match armed_action with
              | Goal_phase.Public_action.Request_complete -> "Request Completion [c]"
              | Goal_phase.Public_action.Drop -> "Drop Goal [x]"
              | Goal_phase.Public_action.Reopen -> "Reopen Goal [o]")
          ^ Ansi.reset)
   | None -> ());
  (match state.goal_action_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  Error: "
         ^ fit_width (Terminal_text.single_line err) (cols - 12)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;

  (* The verdict and the keeper's note: the two things the list draws under
     the cursor and the detail used to leave out, so opening a goal showed
     less than the row it was opened from. They wrap, so this is what the
     surface's scroll moves through. *)
  let body =
    Planning_detail.body ~width:(cols - 6) goal.pg_proof goal.pg_last_review_note
    @ Planning_detail.timeline ~width:(cols - 6) ~goal_id:goal.pg_id
        state.goal_timeline
  in
  (* What is being done about this goal. The goal record does not carry its
     tasks -- the goal-task registry is the source of truth and the loader
     resolved it onto each task -- so this reads them back the other way.
     Linear over the open tasks, which is a short list and costs nothing
     against keeping a second copy of the same links in the state.

     Capped: a goal with thirty tasks would take the whole frame and the
     proof underneath would never be seen. What is left out is said, because
     a list that stops without saying so reads as the whole list. *)
  let linked_tasks =
    List.filter
      (fun (row : Tui_decode.task) -> List.mem goal.pg_id row.goal_ids)
      state.tasks
  in
  let linked_drawn = List.filteri (fun index _ -> index < 6) linked_tasks in
  let linked_omitted = List.length linked_tasks - List.length linked_drawn in
  let linked_rows =
    match linked_tasks with
    | [] -> 1
    | _ -> 1 + List.length linked_drawn + (if linked_omitted > 0 then 1 else 0)
  in
  let chrome_rows =
    planning_detail_fixed_rows
    + List.length timestamp_lines
    + linked_rows
    + (match armed with Some _ -> 1 | None -> 0)
    + (match state.goal_action_error with Some _ -> 1 | None -> 0)
  in
  (* Drawn here, counted above: the two move together or the frame runs past
     the terminal and the presenter drops whatever fell off. *)
  (match linked_tasks with
   | [] ->
     box_line buf cols (Ansi.dim ^ "  Tasks       (none linked)" ^ Ansi.reset)
   | _ ->
     box_line buf cols (Ansi.bold ^ "  TASKS" ^ Ansi.reset);
     List.iter
       (fun (row : Tui_decode.task) ->
         box_line buf cols
           (Printf.sprintf "  %s  %s  %s"
              (fit_width (Terminal_text.single_line row.id) 22)
              (fit_width (Terminal_text.single_line row.title) (max 8 (cols - 60)))
              (Ansi.dim ^ Link.reference Task row.id ^ Ansi.reset)))
       linked_drawn;
     if linked_omitted > 0 then
       box_line buf cols
         (Printf.sprintf "%s  and %d more%s" Ansi.dim linked_omitted Ansi.reset));
  let content_height = max 1 (rows - chrome_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length body) ~height:content_height
      state.planning_scroll
  in
  let drawn =
    body
    |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun (line : Planning_detail.line) ->
      box_line buf cols
        (Printf.sprintf "  %s%s%s"
           (planning_detail_tone line.Planning_detail.tone)
           (fit_width line.Planning_detail.text (cols - 6))
           Ansi.reset))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;

  box_bottom buf cols;
  scroll
;;

(* The goal list stays beside its detail. Opening one used to replace the
   other, so reading a row cost the reader their place in the list. Below the
   split width there is no room for both and the detail keeps the screen,
   which is the rule the Board read pane already follows. *)
let render_planning_detail (state : state)
    ~(armed : Goal_phase.Public_action.t option) (goal : planning_goal) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll =
    if cols < keeper_split_threshold_cols then
      planning_detail_pane state ~armed ~rows ~cols goal buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let goals =
        match state.planning with
        | None -> []
        | Some p ->
            planning_visible_goals ~filter:state.planning_filter
              ~sort:state.planning_sort p.pl_goals
      in
      let selected =
        let rec find i = function
          | [] -> 0
          | (row : planning_goal) :: rest ->
            if String.equal row.pg_id goal.pg_id then i else find (i + 1) rest
        in
        find 0 goals
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      let format_sidebar_goal (row : planning_goal) =
        let phase_badge =
          match row.pg_phase with
          | Goal_phase.Executing -> "[exec]"
          | Goal_phase.Verifying -> "[ver ]"
          | Goal_phase.Awaiting_confirmation -> "[human]"
          | Goal_phase.Completed -> "[done]"
          | Goal_phase.Dropped -> "[drop]"
        in
        Printf.sprintf "%s P%d %s" phase_badge row.pg_priority
          (Terminal_text.single_line row.pg_title)
      in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Planning"
        ~focused:false
        ~labels:(List.map format_sidebar_goal goals)
        ~selected;
      let scroll =
        planning_detail_pane state ~armed ~rows ~cols:(cols - left_cols) goal
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      scroll
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints state.view));
  finish_surface state ~clamped:(Planning_detail_scroll scroll)
      ~surface_key:"planning-detail" ~rows:terminal_rows ~cols buf

(* The store's status vocabulary, as colours. An unknown word keeps its own
   text and no colour: the row is still a fact about the store, just one this
   build does not rank. *)
(* Who the wake reaches. The payload target names a keeper on the rows this
   list can draw; rows without one fall back to the summary, then the source,
   so every row names something.

   The kind prefix comes off first. It is "keeper:" on every row here, so it
   separates nothing and takes seven cells out of the name -- which left two
   schedules for two different keepers both reading "keeper:~". The agenda
   strip has stripped it since it was written; this list is the surface that
   did not.

   Lifted out of the row loop because the column measures itself from the
   rows now: the width and the cell have to be reading the same string. *)
let schedule_row_subject (row : Masc_tui_types.schedule_row) =
  match row.sch_payload_target with
  | Some target -> Masc_tui_agenda.short_who target
  | None -> (
    match row.sch_payload_summary with
    | Some summary -> summary
    | None -> row.sch_source)
;;

let schedule_status_color status =
  semantic_status_color status

(* What became of the wake, for a list row that has one line to say it in.

   The word is the server's own [projection_status], not a reading of it.
   That status is written at a dozen places in
   [server_dashboard_schedule_projection.ml] as bare strings, and the live
   store holds values this file has never heard of; a table of meanings
   here would be a second classifier over that same open axis, drifting
   from the ledger's the first time the server learns a word. Showing the
   word the server wrote cannot drift.

   The [matched_] prefix comes off. It sits on most of the values and
   separates none of them, which is the reason the subject drops
   [keeper:] a few lines below.

   [None] is the ledger saying nothing, and the row then shows an em dash
   rather than a delivery it does not know. That is not the same as a wake
   that failed, which [wake:] beside it already names. *)
let schedule_delivery_word (row : schedule_row) =
  let matched = "matched_" in
  let cut status =
    let n = String.length matched in
    if String.length status > n && String.equal (String.sub status 0 n) matched then
      String.sub status n (String.length status - n)
    else status
  in
  match row.sch_reaction_projection_status with
  | None -> "\xe2\x80\x94"
  | Some status -> cut status

let schedule_delivery_summary (row : schedule_row) =
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> "queue:\xe2\x80\x94"
    | Some status, None -> "queue:" ^ status
    | None, Some count -> Printf.sprintf "queue:pending=%d" count
    | Some status, Some count ->
        Printf.sprintf "queue:%s/%d pending" status count
  in
  let reaction =
    match row.sch_reaction_projection_status with
    | None -> "reaction:\xe2\x80\x94"
    | Some status -> "reaction:" ^ status
  in
  ( Printf.sprintf "%s \xc2\xb7 status:%s" row.sch_schedule_id
      row.sch_status
  , Printf.sprintf "%s \xc2\xb7 %s" queue reaction )

(* Both readers draw this through [data_unreliable_row], which already opens
   "(data unreliable: ". So each branch says only what that frame cannot:
   nothing, when there is no snapshot and the error is the whole story; and
   that the rows on screen are the previous read, when there is one. *)
let schedule_source_warning (state : state) =
  Terminal_text.optional_single_line state.schedules_error
  |> Option.map (fun err ->
         match state.schedules with
         | None -> err
         | Some _ -> "이전 조회 유지 · " ^ err)

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedule_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface lays
     out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s  %s"
    (screen_title " MASC Schedules")
    timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  (match state.schedules with
   | None ->
       (match schedule_source_warning state with
        | Some err ->
            box_line buf cols (data_unreliable_row ~cols err)
        | None ->
            box_line buf cols (Ansi.dim ^ page_unread_note ^ Ansi.reset));
       for _ = 1 to rows - boxed_surface_chrome_rows do
         box_empty buf cols
       done
   | Some snapshot ->
       let warning_rows =
         match schedule_source_warning state with
         | None -> 0
         | Some err ->
             box_line buf cols (data_unreliable_row ~cols err);
             1
       in
       let rows = rows - warning_rows in
       if not (String.equal snapshot.scs_status "ok") then begin
         (* The server's "unknown" is a failed store read, not an empty list;
            the row says which, so a dead ledger cannot read as "nothing is
            scheduled". *)
         (match snapshot.scs_read_error with
          | Some err ->
              box_line buf cols (data_unreliable_row ~cols err)
          | None ->
              box_line buf cols
                ((Theme.bad ()) ^ "  (schedule store unreadable)" ^ Ansi.reset));
         for _ = 1 to rows - boxed_surface_chrome_rows do
           box_empty buf cols
         done
       end else begin
         let count_text =
           match snapshot.scs_request_count with
           | Some total when snapshot.scs_truncated ->
               Printf.sprintf "  Requests: %d  (page shows first %d)" total
                 (List.length snapshot.scs_rows)
           | Some total ->
               Printf.sprintf "  Requests: %d" total
           | None -> "  Requests: ?"
         in
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               Printf.sprintf "  Next due: %s"
                 (Tui_decode.short_timestamp_for_terminal iso)
           | None -> ""
         in
         box_line buf cols (Ansi.bold ^ count_text ^ Ansi.reset);
         box_line buf cols (Ansi.dim ^ next_due_text ^ Ansi.reset);
         box_divider buf cols;

         let count = List.length snapshot.scs_rows in
         if count = 0 then begin
           box_line buf cols (Ansi.dim ^ "  (no scheduled automation)" ^ Ansi.reset);
           for _ = 1 to rows - 12 do
             box_empty buf cols
           done
         end else begin
           (* Keep two factual rows below the list for delivery state. Without
              it the list says when a wake is due but not whether the dispatch,
              queue, and reaction projections agree. Two rows keep all three
              projections readable at the 100-column regression viewport. *)
           let subject_width =
             List.fold_left
               (fun widest row ->
                 max widest
                   (Message_layout.display_width
                      (Terminal_text.single_line (schedule_row_subject row))))
               16 snapshot.scs_rows
             |> min 40
           in
           let content_height = rows - 14 in
           let scroll_offset =
             if state.schedule_cursor >= content_height then
               state.schedule_cursor - content_height + 1
             else 0
           in
           let scs_rows_window = Rows.of_list ~first:scroll_offset ~height:content_height snapshot.scs_rows in
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             match Rows.at scs_rows_window idx with
             | None -> box_empty buf cols
             | Some row -> begin
               let is_selected = idx = state.schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Tui_decode.short_timestamp_for_terminal iso
                 | None -> "-"
               in
               (* The payload target names who the wake reaches (a keeper for
                  keeper wakes); rows without one fall back to the summary,
                  then the source, so every row names something.

                  The kind prefix comes off first. It is "keeper:" on every
                  row this list can draw, so it separates nothing and takes
                  seven cells out of the name -- which left two schedules for
                  two different keepers both reading "keeper:~". The agenda
                  strip has stripped it since it was written; this list is
                  the surface that did not. *)
               let subject = schedule_row_subject row in
               let status_color = schedule_status_color row.sch_status in
               let last_wake =
                 Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_status
               in
               let line =
                 Printf.sprintf "%s[%s]%s %s  %s  wake:%s%s%s\xc2\xb7%s  %s"
                   status_color
                   (fit_width row.sch_status 10)
                   Ansi.reset
                   due
                   (* Measured from the rows rather than given the rest of the
                      line. The subject is a keeper name on every row that has
                      a payload target, so [cols - 76] spent ninety cells on
                      [edgar.a.poe] and the recurrence past it -- which is
                      where the timezone lives -- read [daily 08:00:00 A~].
                      The fallback summary can be long, so it is capped rather
                      than trusted. *)
                   (fit_width (Terminal_text.single_line subject)
                      subject_width)
                   (schedule_status_color last_wake)
                   (fit_width (Terminal_text.single_line last_wake) 10)
                   Ansi.reset
                   (* The enqueue result and what became of the wake are two
                      facts, and the list carried only the first: a wake the
                      queue cancelled forty seconds later still read
                      [wake:succeeded]. Both are here now, in that order. *)
                   (fit_width
                      (Terminal_text.single_line (schedule_delivery_word row))
                      12)
                   (Ansi.dim ^ row.sch_recurrence_summary ^ Ansi.reset)
               in
               let content =
                 if is_selected then
                   Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
                 else
                   "  " ^ line
               in
               box_line buf cols content
             end
           done;
           (match List.nth_opt snapshot.scs_rows state.schedule_cursor with
            | None ->
                box_empty buf cols;
                box_empty buf cols
            | Some selected ->
                let identity, delivery = schedule_delivery_summary selected in
                box_line_styled buf cols ~style:(Theme.recede ())
                  ("  " ^ identity);
                box_line_styled buf cols ~style:(Theme.recede ())
                  ("  " ^ delivery))
         end;
         (* The arm and the server's last refusal sit under the list, the
            same rows the goal detail carries them on. *)
         (match state.schedule_cancel_armed with
          | Some schedule_id ->
              box_line buf cols
                ((Theme.warn ())
                ^ Printf.sprintf
                    "  armed: cancel %s -- same key again to send"
                    (Terminal_text.single_line schedule_id)
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some err ->
              box_line buf cols
                ((Theme.bad ()) ^ "  "
                ^ fit_width (Terminal_text.single_line err) (cols - 8)
                ^ Ansi.reset)
          | None -> ())
       end);

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Schedules));

  finish_surface state ~surface_key:"schedules" ~rows:terminal_rows
      ~cols buf

(* What became of the wake. The pane could say a schedule fired and stop
   there: [LAST WAKE] reports the dispatch and [DELIVERY EVIDENCE] reports one
   word of verdict, and neither answers "did the Keeper do anything". The
   reaction ledger records four steps and the projection folds all four into
   that one word, so a wake delivered to a Keeper that never took a turn reads
   the same as one that did.

   Drawn only when the ledger said something. A schedule that has not fired
   has no trail, and four rows of "--" under it would be four rows saying the
   same nothing the empty [LAST WAKE] block already says. *)
let schedule_turn_rows
      ~(field : ?style:string -> string -> string -> string * string)
      (row : schedule_row) =
  let step_observed =
    [ row.sch_wake_seen
    ; row.sch_turn_started
    ; row.sch_turn_finished
    ; row.sch_queue_ack_seen
    ; row.sch_wake_cancelled
    ]
    |> List.exists Option.is_some
  in
  let metadata_observed =
    [ row.sch_reaction_keeper_name
    ; row.sch_reaction_stimulus_id
    ; row.sch_reaction_post_id
    ; row.sch_reaction_reason
    ; row.sch_stimulus_recorded_at_iso
    ; row.sch_turn_started_recorded_at_iso
    ; row.sch_turn_finished_recorded_at_iso
    ; row.sch_queue_ack_recorded_at_iso
    ; row.sch_wake_cancelled_recorded_at_iso
    ]
    |> List.exists Option.is_some
  in
  if not (step_observed || metadata_observed || Option.is_some row.sch_reaction_quarantined)
  then []
  else
    (* [None] is not [false]. A step the ledger never spoke about draws the
       same dash every unknown draws on this pane, in the dim every unknown
       takes -- claiming "no" for it would report a failure nobody observed. *)
    let step ?(bad_when_true = false) label observed recorded_at =
      match observed with
      | None -> field label "\xe2\x80\x94"
      | Some value ->
          let tone =
            if value = bad_when_true then Theme.bad () else Theme.ok ()
          in
          let at =
            match value, recorded_at with
            | true, Some timestamp ->
              " \xc2\xb7 " ^ Tui_decode.short_timestamp_for_terminal timestamp
            | _, _ -> ""
          in
          field ~style:tone label ((if value then "yes" else "no") ^ at)
    in
    let identity_rows =
      [ Option.map
          (fun keeper ->
             field "Keeper evidence"
               (Link.reference Keeper (Terminal_text.single_line keeper)))
          row.sch_reaction_keeper_name
      ; Option.map
          (fun stimulus -> field "Stimulus" stimulus)
          row.sch_reaction_stimulus_id
      ; Option.map
          (fun occurrence -> field "Occurrence" occurrence)
          row.sch_reaction_post_id
      ]
      |> List.filter_map Fun.id
    in
    [ Ansi.dim, ""
    ; Ansi.bold, "  TURN"
    ]
    @ identity_rows
    @ [ step "Wake seen" row.sch_wake_seen row.sch_stimulus_recorded_at_iso
      ; step "Turn started" row.sch_turn_started
          row.sch_turn_started_recorded_at_iso
      ; step "Turn finished" row.sch_turn_finished
          row.sch_turn_finished_recorded_at_iso
      ; step "Queue ack" row.sch_queue_ack_seen row.sch_queue_ack_recorded_at_iso
      ; step ~bad_when_true:true "Cancelled" row.sch_wake_cancelled
          row.sch_wake_cancelled_recorded_at_iso
      ; field "Reaction kind"
          (Option.value ~default:"\xe2\x80\x94" row.sch_reaction_kind)
      ; field
          ~style:(if Option.is_some row.sch_reaction_reason then Theme.warn () else Ansi.dim)
          "Reason" (Option.value ~default:"\xe2\x80\x94" row.sch_reaction_reason)
    ; field
        ~style:
          (match row.sch_reaction_quarantined with
           | Some count when count > 0 -> Theme.warn ()
           | Some _ | None -> Ansi.dim)
        "Quarantined"
        (match row.sch_reaction_quarantined with
         | None -> "\xe2\x80\x94"
         | Some count -> string_of_int count)
      ]

(* The wake block. The row carries the newest attempt and the exact lookup
   carries the retained list, so this pane reports whichever it has and says
   which: one attempt out of up to 32 read as a schedule's whole past for as
   long as the list was the only thing not projected. The three unloaded
   readings stay three sentences. *)
let schedule_wake_lines
      ~(field : ?style:string -> string -> string -> string * string)
      ~(timestamp : string option -> string) ~(row : schedule_row)
      ~(history : schedule_wake_history option)
      ~(history_error : (string * string) option) =
  let last_wake_fields =
    [ field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_last_wake_status)
        "Status" (Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_status)
    ; field "Started" (timestamp row.sch_last_wake_started_at_iso)
    ; field
        ~style:(if Option.is_some row.sch_last_wake_error then Theme.bad () else Ansi.dim)
        "Error" (Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_error)
    ]
  in
  match
    Render_schedule.classify_wake_reading
      ~history_error:(Option.map snd history_error)
      ~history:
        (Option.map
           (fun h -> (List.length h.swh_wakes, h.swh_retention_per_schedule))
           history)
  with
  | Render_schedule.Wake_history_failed err ->
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Theme.bad (), "  wake history unavailable: " ^ Terminal_text.single_line err) ]
  | Render_schedule.Wake_last_only ->
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Ansi.dim, "  (loading the rest of this schedule's wakes\xe2\x80\xa6)") ]
  | Render_schedule.Wake_never ->
      [ Ansi.bold, "  WAKES"; (Ansi.dim, "  (this schedule has not woken)") ]
  | Render_schedule.Wake_history { count; retention } ->
      let wakes =
        match history with Some h -> h.swh_wakes | None -> []
      in
        (Ansi.bold
        , Printf.sprintf "  WAKES (%d retained, ceiling %d per schedule)"
            count retention )
        :: List.concat_map
             (fun (wake : schedule_wake) ->
                let started = timestamp wake.swk_started_at_iso in
                let finished = timestamp wake.swk_finished_at_iso in
                let head =
                  ( schedule_status_color wake.swk_status
                  , Printf.sprintf "  %-12s %s \xe2\x86\x92 %s"
                      (Terminal_text.single_line wake.swk_status) started finished )
                in
                match wake.swk_error with
                | None -> [ head ]
                | Some err ->
                    [ head
                    ; ( Theme.bad ()
                      , "               " ^ Terminal_text.single_line err )
                    ])
             wakes

let schedule_detail_lines ~width (row : schedule_row)
      ~(wake_history : schedule_wake_history option)
      ~(wake_history_error : (string * string) option) =
  let field ?(style = Ansi.reset) label value =
    ( style
    , Printf.sprintf "  %-14s %s" label (Terminal_text.single_line value) )
  in
  let optional value = Option.value ~default:"\xe2\x80\x94" value in
  let timestamp value =
    match value with
    | None -> "\xe2\x80\x94"
    | Some iso -> Tui_decode.short_timestamp_for_terminal iso
  in
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> "\xe2\x80\x94"
    | Some status, None -> status
    | None, Some count -> Printf.sprintf "pending=%d" count
    | Some status, Some count -> Printf.sprintf "%s  pending=%d" status count
  in
  let reaction =
    match row.sch_reaction_projection_status, row.sch_reaction_latest_at_iso with
    | None, None -> "\xe2\x80\x94"
    | Some status, None -> status
    | None, Some at -> Tui_decode.short_timestamp_for_terminal at
    | Some status, Some at ->
        Printf.sprintf "%s  %s" status
          (Tui_decode.short_timestamp_for_terminal at)
  in
  let summary =
    Option.value ~default:"(no payload summary)" row.sch_payload_summary
  in
  let keeper_wake =
    match row.sch_payload_kind with
    | Some ("keeper_wake" | "masc.keeper_wake") -> true
    | Some _ | None -> false
  in
  let target_link =
    match keeper_wake, row.sch_payload_target with
    | true, Some keeper ->
        [ field "Keeper link"
            (Link.reference Keeper (Terminal_text.single_line keeper))
        ]
    | _, _ -> []
  in
  [ Ansi.bold, "  SCHEDULE"
  ; field "Link"
      (Link.reference Schedule
         (Terminal_text.single_line row.sch_schedule_id))
  ; field "Schedule" row.sch_schedule_id
  ; field "Instance" row.sch_schedule_instance_id
  ; field ~style:(schedule_status_color row.sch_status) "Status" row.sch_status
  ; field "Source" row.sch_source
  ; field "Requested by" row.sch_requested_by
  ; field "Scheduled by" row.sch_scheduled_by
  ; field "Requested"
      (Tui_decode.short_timestamp_for_terminal row.sch_requested_at_iso)
  ; field "Due" (timestamp row.sch_due_at_iso)
  ; field "Next due" (timestamp row.sch_next_due_at_iso)
  ; field "Expires" (timestamp row.sch_expires_at_iso)
  ; field "Recurrence" row.sch_recurrence_summary
  ; Ansi.dim, ""
  ; Ansi.bold, "  PAYLOAD"
  ; field "Kind" (optional row.sch_payload_kind)
  ; field "Support" row.sch_payload_support
  ; field "Dispatch tool" (optional row.sch_payload_dispatch_tool)
  ; field "Target" (optional row.sch_payload_target)
  ]
  @ target_link
  @ [ field "Digest" row.sch_payload_digest
  ; Ansi.bold, "  Summary"
  ]
  @ (Message_layout.wrap_body ~markdown:document_markdown
       ~max_cells:(max 1 (width - 4)) ~sanitize:Terminal_text.single_line summary
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  PAYLOAD JSON"
    ]
  @ (document_markdown ~width:(max 1 (width - 4))
       ("```json\n" ^ Yojson.Safe.pretty_to_string row.sch_payload ^ "\n```")
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ (Ansi.dim, "") ]
  @ schedule_wake_lines ~field ~timestamp ~row ~history:wake_history
      ~history_error:wake_history_error
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  DELIVERY EVIDENCE"
    ; field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_queue_projection_status)
        "Queue" queue
    ; field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_reaction_projection_status)
        "Reaction" reaction
    ]
  @ schedule_turn_rows ~field row
  @ (if keeper_wake then
       [ Ansi.dim, ""
       ; Ansi.bold, "  WORK RESULT"
       ; field "Attribution"
           "the turn this wake opened, bounded by its start and finish rows"
       ; field "Inspect"
           "Keeper Calls or Activity between the two recorded times"
       ]
     else [])

let schedule_detail_pane (state : state) ~rows ~cols (row : schedule_row) buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s[%s]%s"
       (screen_title " MASC Schedules \xe2\x96\xb8 details")
       (schedule_status_color row.sch_status)
       (Terminal_text.single_line row.sch_status) Ansi.reset);
  box_divider buf cols;
  let warning_rows =
    match schedule_source_warning state with
    | None -> 0
    | Some err ->
        box_line buf cols (data_unreliable_row ~cols err);
        1
  in
  let lines =
    schedule_detail_lines
      ~width:(max 1 (framed_inner_width cols))
      row
      ~wake_history:state.schedule_wake_history
      ~wake_history_error:state.schedule_wake_history_error
  in
  let content_height = max 1 (rows - 6 - warning_rows) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.schedule_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The schedule list stays beside the schedule. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_schedule_detail (state : state) (row : schedule_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, _max_scroll =
    if cols < keeper_split_threshold_cols then
      schedule_detail_pane state ~rows ~cols row buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.schedules with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : schedule_row) -> row.sch_schedule_id)
            snapshot.scs_rows
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Schedules"
        ~focused:false ~labels ~selected:state.schedule_cursor;
      let answer =
        schedule_detail_pane state ~rows ~cols:(cols - left_cols) row
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Schedules));
  finish_surface state ~clamped:(Schedule_detail_scroll scroll)
    ~surface_key:"schedule-detail" ~rows:terminal_rows ~cols buf

let render_schedules (state : state) =
  match state.schedule_detail_id, state.schedules with
  | Some schedule_id, Some snapshot ->
      (match
         List.find_opt
           (fun row -> String.equal row.sch_schedule_id schedule_id)
           snapshot.scs_rows
       with
       | Some row -> render_schedule_detail state row
       | None -> render_schedule_list state)
  | Some _, None | None, _ -> render_schedule_list state

(* The table's variant: the normal state is silent. On a healthy fleet every
   row said "healthy" while the heading counted "11 healthy" and the summary
   said "fleet ok" — the same fact four times, and the glyph beside the word
   already carries the health colour. Only a deviation earns a word, so the
   one stale row is the only row with text in the column. The single-keeper
   chat header keeps {!keeper_health_word}: alone, the word is identity, not
   repetition. *)
let keeper_health_deviation_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> (
      match Tui_decode.keeper_health_reading value with
      | Tui_decode.Health_running -> ""
      | Tui_decode.Health_idle | Tui_decode.Health_offline
      | Tui_decode.Health_stale | Tui_decode.Health_degraded
      | Tui_decode.Health_zombie ->
          Tui_decode.keeper_health_to_string value)

(* [runtime_id] is the producer-owned runtime identity. Keep it whole instead
   of deriving a model by splitting its spelling: the phase is a separate
   typed reading, while the sanitized id is the exact identity the gate named. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> "\xe2\x80\x94"
  | Some row ->
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        (Terminal_text.single_line row.kr_runtime_id)

let keeper_runtime_cell ~width (runtime : keeper_runtime option) =
  match runtime with
  | None -> fit_width "\xe2\x80\x94" width
  | Some row ->
      (* Running is the normal lifecycle and stays silent — eleven rows all
         reading "running" said nothing any row could act on; the cells go to
         the runtime identity instead. Every other phase keeps its word. *)
      (* A paused keeper says so instead of saying its phase. [kr_paused] is
         a separate reading from [kr_phase] and the two disagree in practice:
         on the live gate, two of sixteen keepers report phase offline with
         paused true, and a third reports offline with paused false. The word
         "offline" drew all three the same, and the difference is the one an
         operator acts on -- a person stopped that one, so nothing is wrong
         with it. The phase this replaces is still on the chat header, which
         draws [kr_phase] unconditionally. *)
      let phase =
        if row.kr_paused then "paused "
        else if Tui_decode.keeper_phase_is_running row.kr_phase then ""
        else Tui_decode.keeper_phase_to_string row.kr_phase ^ " "
      in
      let runtime_id = Terminal_text.single_line row.kr_runtime_id in
      let phase_width = Message_layout.display_width phase in
      if phase_width >= width then fit_width (keeper_runtime_label runtime) width
      else
        fit_width
          (phase ^ fit_runtime_id (width - phase_width) runtime_id)
          width

(* One activation mode and the sandbox declaration from the roster row. *)
let keeper_flag_cell (runtime : keeper_runtime option) =
  match runtime with
  | None -> Ansi.dim ^ "- -" ^ Ansi.reset
  | Some row ->
      let sandbox =
        match row.kr_sandbox_profile with
        | "docker" -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "D" ^ Ansi.reset
        | "microvm" -> (Theme.category Theme.Slot_2) ^ "M" ^ Ansi.reset
        | "local" -> Ansi.dim ^ "L" ^ Ansi.reset
        | other when String.length other > 0 ->
          (Theme.warn ()) ^ String.uppercase_ascii (String.sub other 0 1) ^ Ansi.reset
        | _ -> Ansi.dim ^ "?" ^ Ansi.reset
      in
      (match row.kr_activation_mode with
       | Activation_manual -> "M"
       | Activation_on_demand -> "D"
       | Activation_autonomous -> "A")
      ^ " "
      ^ sandbox

(* Column header labels line up with the cell budgets
   [Render_schedule.allocate_keeper_columns] hands out, so the arithmetic lives
   in one tested place instead of once here and once in the row. *)
let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Printf.sprintf "%-*s" Render_schedule.keeper_status_width "HEALTH"
    ; " "
    ; Printf.sprintf "%-*s" columns.kcol_name "KEEPER"
    ; (if columns.kcol_show_flags then
         " " ^ Printf.sprintf "%-*s" Render_schedule.keeper_flags_width "Mode S"
       else "")
    ; Printf.sprintf " %*s" Render_schedule.keeper_last_turn_width "LAST"
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width "LIFECYCLE / RUNTIME" columns.kcol_runtime
       else "")
    ; " "
    ; "TASK"
    ]

(* Each cell is fitted as plain text and styled afterwards, so a long keeper
   name cannot push the columns to its right out of the frame and the style
   bytes never count toward the width. *)
let keeper_row_content ~(columns : Render_schedule.keeper_columns)
    ~now ~frame ~yolo ~paused ~health ~turn ~next_action ~keeper ~runtime =
  let status_color = keeper_action_color next_action in
  (* A running turn takes the cell whole -- both the mark and the word.
     Splitting them is what this column used to do, and it produced rows
     that argued with themselves: the mark came from the heartbeat and the
     word from the turn, so a keeper answering on a stale heartbeat drew
     "? answering". One of those was wrong and the reader could not tell
     which.

     The word is the elapsed time rather than "answering". The mark already
     says it is answering, and it says so by moving; spending eight columns
     to repeat that leaves no room for the fact the mark cannot carry, which
     is how long. Eight seconds and forty minutes are different situations
     and they used to be the same row. It also ends the truncation: this
     column is cut for "healthy", and "answering" never fit in it.

     Idle and unavailable rows keep the health word -- unavailable is the
     owner lookup failing, which the health column describes better than a
     blank would. *)
  (* A turn record that outlives the process it belongs to. The summary above
     this table read "2 offline / not running" while
     one listed keeper's own row drew a turning mark and a climbing clock: its turn
     had started and never been closed, and the process behind it had gone.
     The row that most needed reading looked like the healthiest kind.

     The elapsed stays -- a turn open two minutes is the fact -- but the mark
     stops. Motion here means work is progressing, and for a keeper the health
     reading calls offline or zombie, nothing is. *)
  let turn_is_being_worked =
    match Option.map Tui_decode.keeper_health_reading health with
    | Some (Tui_decode.Health_offline | Tui_decode.Health_zombie) -> false
    | Some
        ( Tui_decode.Health_running | Tui_decode.Health_idle
        | Tui_decode.Health_stale | Tui_decode.Health_degraded )
    | None ->
      true
  in
  let glyph, status_word, status_color =
    match (turn : Tui_decode.keeper_turn_state option) with
    | Some (Tui_decode.Keeper_turn_running { started_at_unix; _ }) ->
      ( Masc_tui_answering.running_glyph
          ~frame:(if turn_is_being_worked then frame else -1)
      , Masc_tui_answering.elapsed_text ~now started_at_unix
      , if turn_is_being_worked then (Theme.info ()) else (Theme.bad ()) )
    | Some Tui_decode.Keeper_turn_idle
    | Some (Tui_decode.Keeper_turn_unavailable _)
    | None ->
      ( keeper_state_glyph ~paused ~health
      , keeper_health_deviation_word health
      , status_color )
  in
  (* Selection is the full-row band the caller draws (box_line_selected over
     a strip_sgr'd copy of this row), so the row itself carries no marker.
     The caret's three gutter cells stay as spaces so columns do not shift
     between the selected row and its neighbours. *)
  (* Names, not prose: the Keepers table is where two keepers sharing a prefix
     have to be told apart, and the tail is what does it. See
     [Message_layout.fit_middle]. *)
  let name =
    Message_layout.fit_middle columns.kcol_name
      (Terminal_text.single_line keeper.k_name)
  in
  let task =
    fit_width
      (Terminal_text.single_line_or ~default:"\xe2\x80\x93"
         keeper.k_current_task_id)
      columns.kcol_task
  in
  String.concat ""
    [ "   "
    ; status_color ^ glyph ^ " "
      ^ fit_width status_word (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; " "
    ; (* A keeper whose gate runs every call unasked wears its name in
         red: the stance has no column of its own, and the name is what
         the eye finds first. On the selected row the band folds this red
         with every other cell colour. *)
      (if yolo then (Theme.bad ()) ^ name ^ Ansi.reset else name)
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; (* The lifetime turn count said nothing an operator acts on; how long
         since this keeper last turned does. A running row already carries
         its elapsed time in the HEALTH cell, so this column answers the
         idle rows. A keeper that never turned, or one whose last turn reads
         from the future, draws the dash every unknown draws. The count
         itself still lives on the detail pane. *)
      (let last_turn_age =
         match Masc_domain.parse_iso8601_opt keeper.k_last_turn_ts with
         | None -> "\xe2\x80\x94"
         | Some since -> (
             match Message_layout.age_text ~now ~since with
             | Some text -> text
             | None -> "\xe2\x80\x94")
       in
       Printf.sprintf " %s%*s%s" Ansi.dim
         Render_schedule.keeper_last_turn_width last_turn_age Ansi.reset)
    ; (if columns.kcol_show_runtime then
         " " ^ (Theme.recede ())
         ^ keeper_runtime_cell ~width:columns.kcol_runtime runtime
         ^ Ansi.reset
       else "")
    ; " "
    ; Ansi.dim ^ task ^ Ansi.reset
    ]

(* Counted from the same readings the rows are drawn from, so the heading
   cannot disagree with the list under it. *)
(* Tally words come from [Keeper_control.health_label], so this paints the
   health vocabulary. [unread] is the roster not answering, which is dim rather
   than any health colour. *)
let keeper_roster_status_color = function
  | "healthy" -> (Theme.ok ())
  | "stale" | "degraded" -> (Theme.warn ())
  | "zombie" -> (Theme.bad ())
  | "offline" | "idle" -> (Theme.muted ())
  | _ -> Ansi.dim

(* The tally is [Keeper_control.status_tally], so every word here is a word the
   status column shows for the same keeper. This function only paints it. *)
let keeper_roster_summary readings =
  Keeper_control.health_tally readings
  |> List.map (fun (label, count) ->
         Printf.sprintf "%s%d %s%s" (keeper_roster_status_color label) count
           label Ansi.reset)

(* The two subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wanted and never started is bootable minus running, while a keeper whose
   fiber is alive but whose durable demand is not admissible is running minus
   executable. Reporting the second as "not running" sent an operator to boot
   ten keepers that were already up. *)
let keeper_fleet_gap_lines (fleet : fleet_safety) =
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let never_started = subtract fleet.fs_bootable_names fleet.fs_running_names in
  let running_without_turn =
    subtract fleet.fs_running_names fleet.fs_executable_names
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (never_started, "not running", (Theme.bad ()))
    ; (running_without_turn, "running, cannot take a turn", (Theme.warn ()))
    ]


let keeper_operations_outcome_text = function
  | None -> "—"
  | Some (outcome : Tui_decode.keeper_lane_last_outcome) ->
      let state = Terminal_text.single_line outcome.klo_runtime_state in
      (match outcome.klo_selected_model with
       | Some model when String.trim model <> "" ->
           state ^ " · " ^ Terminal_text.single_line model
       | Some _ | None -> state)

(* The Keeper composite used to live only in Lanes. Keep the roster compact,
   then give the selected Keeper one exact operational line: no lifecycle fact
   is dropped, and Lanes no longer has to repeat the whole Keeper table. *)
let keeper_operations_preview (state : state) =
  match selected_keeper state with
  | None -> Ansi.dim ^ "  Keeper operations: no Keeper selected" ^ Ansi.reset
  | Some keeper ->
      (match state.lanes with
       | Some snapshot ->
           (match
              List.find_opt
                (fun (lane : Tui_decode.keeper_lane) ->
                  String.equal lane.kl_keeper keeper.k_name)
                snapshot.kls_lanes
            with
            | Some lane ->
                String.concat ""
                  [ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                  ; "  OPERATIONS"
                  ; Ansi.reset
                  ; "  lifecycle "
                  ; Terminal_text.single_line
                      (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
                  ; " · turn "
                  ; Terminal_text.single_line
                      (Tui_decode.keeper_lane_turn_phase_to_string
                         lane.kl_turn_phase)
                  ; " · idle "
                  ; keeper_lane_idle_text lane.kl_idle_seconds
                  ; " · last "
                  ; keeper_operations_outcome_text lane.kl_last_outcome
                  ; " · "
                  ; Terminal_text.single_line_or ~default:"no diagnosis"
                      lane.kl_diagnosis
                  ]
            | None ->
                Ansi.dim ^ "  OPERATIONS  no composite row for "
                ^ Terminal_text.single_line keeper.k_name ^ Ansi.reset)
       | None ->
           (match state.lanes_error with
            | Some detail ->
                (Theme.warn ()) ^ "  OPERATIONS unavailable · "
                ^ Terminal_text.single_line detail ^ Ansi.reset
            | None -> Ansi.dim ^ "  OPERATIONS loading…" ^ Ansi.reset))

let render_keeper_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let inner = max 1 (framed_inner_width cols) in
  let readings = List.map (keeper_reading state) state.keepers in
  let selected_reading =
    Option.map (keeper_reading state) (selected_keeper state)
  in

  Buffer.add_char buf '\n';

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading =
    screen_title
      (Printf.sprintf " MASC Keepers (%d)" (List.length state.keepers))
    ^ (match state.search with
       | Some query ->
           Printf.sprintf "  %s/%s%s\xe2\x96\x8c%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
             (Terminal_text.single_line query) Ansi.reset Ansi.reset
       | None ->
           if state.search_last = "" then ""
           else
             Printf.sprintf "  %s/%s (n/N)%s" Ansi.dim
               (Terminal_text.single_line state.search_last)
               Ansi.reset)
    ^ (match keeper_roster_summary readings with
       | [] -> ""
       | parts ->
           Ansi.dim ^ "   " ^ Ansi.reset
           ^ String.concat (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset) parts)
  in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading - String.length timestamp)
  in
  box_line buf cols
    (heading ^ String.make gap ' ' ^ Ansi.dim ^ timestamp ^ Ansi.reset);

  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  (match (state.fleet_safety, state.fleet_safety_error) with
   | _, Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  fleet: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None, None -> ()
   | Some fleet, None ->
       let tone =
         if fleet.fs_operator_action_required then (Theme.bad ())
         else if String.equal fleet.fs_status "ok" then (Theme.ok ())
         else (Theme.warn ())
       in
       let blocker =
         match fleet.fs_blocker with None -> "" | Some b -> "   blocker: " ^ b
       in
       box_line buf cols
         (Printf.sprintf
            "%s  fleet %s%s   running %d/%d   turn capacity %d/%d%s%s%s" tone
            fleet.fs_status Ansi.reset fleet.fs_running_count
            fleet.fs_bootable_count
            (fleet.fs_target_reaction_capacity
            - fleet.fs_reaction_capacity_shortfall)
            fleet.fs_target_reaction_capacity Ansi.dim blocker Ansi.reset);
       let counts =
         [ ("paused", fleet.fs_paused_count)
         ; ("failing", fleet.fs_failing_count)
         ; ("recovering", fleet.fs_recovering_count)
         ; ( "task owner without fiber"
           , fleet.fs_active_task_owner_without_fiber_count )
         ; ("awaiting verdict", fleet.fs_completion_authority_pending_count)
         ]
         |> List.filter (fun (_, n) -> n > 0)
         |> List.map (fun (label, n) -> Printf.sprintf "%s %d" label n)
       in
       if counts <> [] then
         box_line buf cols
           (Ansi.dim ^ "  " ^ String.concat "   " counts ^ Ansi.reset);
       List.iter
         (fun (color, label, names) ->
            box_line buf cols
              (Printf.sprintf "%s  %s: %s%s" color label
                 (Terminal_text.single_line names) Ansi.reset))
         (keeper_fleet_gap_lines fleet));

  (* The roster's own failure. The rows below still come from disk so they stay
     on screen; this says the live half of every one of them is missing, which
     does not prevent confirmed deletion through the authoritative server. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         ((Theme.warn ()) ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_roster with
   | Keeper_control.Roster_invalid { errors; _ } ->
       box_line buf cols
         (Printf.sprintf "%s  configuration errors: %d; select a keeper for details%s"
            (Theme.warn ()) (List.length errors) Ansi.reset);
       (match selected_reading with
        | Some { Keeper_control.name; liveness = Keeper_control.Invalid detail; _ } ->
            box_line buf cols ((Theme.warn ()) ^ "  "
              ^ Terminal_text.single_line (name ^ ": " ^ detail) ^ Ansi.reset)
        | Some _ | None -> ())
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %d keepers; the rest read as unknown%s"
            (Theme.warn ()) (List.length observed) total Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  let columns = Render_schedule.allocate_keeper_columns ~inner_width:inner in
  box_line_styled buf cols ~style:(Theme.recede ())
    "  Health = heartbeat/readiness   Lifecycle = keeper process   Last = time since last turn";
  box_line_styled buf cols ~style:(Theme.recede ())
    "  Mode: M manual / D on demand / A autonomous   S = sandbox (D docker \xc2\xb7 M microvm \xc2\xb7 L local)";
  box_line_styled buf cols ~style:(Theme.recede ()) (keeper_column_header columns);
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  let keepers_error = Terminal_text.optional_single_line state.keepers_error in
  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = count_frame_lines buf in
  let footer_rows = 3 in
  let keeper_rows = max 0 (rows - chrome_rows - footer_rows) in
  let keeper_count = List.length state.keepers in
  let scroll_offset =
    if keeper_rows > 0 && state.keeper_cursor >= keeper_rows then
      state.keeper_cursor - keeper_rows + 1
    else 0
  in
  let keepers_window = Rows.of_list ~first:scroll_offset ~height:keeper_rows state.keepers in
  let readings_window = Rows.of_list ~first:scroll_offset ~height:keeper_rows readings in
  if keeper_count = 0 then begin
    if keeper_rows > 0 && Option.is_none keepers_error then
      box_line buf cols
        (Ansi.dim ^ "   no keeper metadata under .masc/keepers/" ^ Ansi.reset);
    let filled = if Option.is_none keepers_error then 1 else 0 in
    for _ = 1 to max 0 (keeper_rows - filled) do
      box_empty buf cols
    done
  end
  else
    for index = 0 to keeper_rows - 1 do
      let position = index + scroll_offset in
      match
        (Rows.at keepers_window position, Rows.at readings_window position)
      with
      | Some keeper, Some reading ->
          let runtime =
            match reading.Keeper_control.liveness with
            | Keeper_control.Present row -> Some row
            | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None
          in
          let turn =
            List.find_map
              (fun (row : Tui_decode.keeper_turn_row) ->
                if String.equal row.ktr_keeper_name keeper.k_name then
                  Some row.ktr_state
                else None)
              state.keeper_turns
          in
          let row =
            keeper_row_content ~columns
              ~now:(Unix.gettimeofday ())
              ~frame:state.activity_frame
              ~yolo:(List.mem keeper.k_name state.keeper_yolo_names)
              ~paused:reading.Keeper_control.paused
              ~health:(Keeper_control.health reading)
              ~turn
              ~next_action:(Keeper_control.next_action reading)
              ~keeper ~runtime
          in
          if position = state.keeper_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
          else box_line buf cols row
      | Some _, None | None, Some _ | None, None -> box_empty buf cols
    done;

  box_line buf cols (keeper_operations_preview state);
  (* A section rule, drawn by the helper the rest of this surface uses, so it
     reads as the two rules above it do. No corners: the Keepers frame holds
     no box_tl, box_tr or edge bar for a corner to point at. *)
  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(keeper_action_hints ~offers_back:false state selected_reading));

  finish_surface state ~surface_key:"keeper-list" ~rows:terminal_rows
      ~cols buf

(* Through the semantic names, not the colour names. A raw [Ansi.red] is the
   terminal's red whatever the page behind it is; [Theme.bad ()] is the same
   reading lifted until it clears the readable floor on the scheme in force.
   These four are states, so they are what the rule is about. *)
let standalone_lane_status_style = function
  | Tui_decode.Standalone_running -> (Theme.warn ())
  | Tui_decode.Standalone_idle -> (Theme.ok ())
  | Tui_decode.Standalone_degraded
  | Tui_decode.Standalone_unavailable -> (Theme.bad ())
  | Tui_decode.Standalone_no_retained_observation -> (Theme.muted ())

let standalone_lane_row ~now ~frame width (lane : Tui_decode.standalone_lane) =
  let status = Tui_decode.standalone_lane_status_to_string lane.sl_status in
  (* A lane that is running says so twice and neither says for how long: the
     word "running", and a count of how many. The server has sent the start
     of the newest run all along and the decoder threw it away under an
     underscore, so the one fact an operator weighs -- is this a lane doing
     work or a lane stuck -- was decoded and dropped one layer from the
     screen.

     Same treatment as a keeper mid-turn: the mark moves while it runs, and
     the word carries the elapsed. A lane with no start recorded keeps the
     still mark rather than inventing an age. *)
  let mark, status =
    match lane.sl_status, lane.sl_last_started_at with
    | Tui_decode.Standalone_running, Some started_at ->
      ( Masc_tui_answering.running_glyph ~frame
      , status ^ " " ^ Masc_tui_answering.elapsed_text ~now started_at )
    (* One mark per colour class, so a reader who cannot tell the colours
       apart gets the split the colours make. Four states shared a single
       [\xe2\x97\x8f] while the style beside them was green, red or grey: on
       a column of identical marks, the lane failing 133 of 1095 runs looked
       exactly like the four that were fine.

       This says what the style says and no more -- the mapping is the same
       three-way split, not a second opinion about severity. *)
    | (Tui_decode.Standalone_idle | Tui_decode.Standalone_running), _ ->
      ("\xe2\x97\x8f", status)
    | ( (Tui_decode.Standalone_degraded | Tui_decode.Standalone_unavailable)
      , _ ) ->
      ("\xe2\x9c\x97", status)
    | Tui_decode.Standalone_no_retained_observation, _ -> ("\xc2\xb7", status)
  in
  (* Why the lane cannot admit, where the cell used to restate that it cannot.
     "no admitted slot" says the same thing the status word beside it already
     says; the projection carries the reason -- an unconfigured lane and a lane
     whose registry could not be read are different problems and the operator
     acts on them differently -- and nothing drew it. *)
  let slots =
    let base =
      match lane.sl_admitted_slots, lane.sl_admission_error with
      | [], Some reason -> reason
      | [], None ->
        (* CLI-only lanes are legal (RFC cli-runtimes-as-lane-slots): with a
           cli suffix declared, an empty catalog list is a shape, not a
           failure. *)
        if lane.sl_cli_slots = [] then "no admitted slot" else "cli-only"
      | admitted, None -> String.concat "," admitted
      | admitted, Some reason ->
        String.concat "," admitted ^ " \xc2\xb7 " ^ reason
    in
    let base =
      match lane.sl_cli_slots with
      | [] -> base
      | cli -> base ^ " +cli:" ^ String.concat "," cli
    in
    (* A declared slot publication could not admit is the difference between
       "configured single" and "configured double, one silently dropped" —
       the boot WARN was the only place that said so before this. *)
    match lane.sl_dropped_slots with
    | [] -> base
    | dropped -> base ^ " (dropped " ^ String.concat "," dropped ^ ")"
  in
  let observed_slots =
    match lane.sl_selected_slots with
    | [] -> "none"
    | slots ->
        slots
        |> List.map (fun slot ->
          Printf.sprintf "%s×%d" slot.slsc_slot_id slot.slsc_count)
        |> String.concat ","
  in
  let p50 =
    match lane.sl_p50_elapsed_s with
    | None -> "—"
    | Some seconds -> Printf.sprintf "%.1fs" seconds
  in
  let prefix = standalone_lane_status_style lane.sl_status in
  let line =
    Printf.sprintf
      "  %s%s %-15s %-14s%s slots %-20s active %d  runs %d  ok/fail/cancel %d/%d/%d  p50 %s  observed %s"
      prefix mark lane.sl_label status Ansi.reset slots lane.sl_running_count
      lane.sl_retained_run_count lane.sl_succeeded_count lane.sl_failed_count
      lane.sl_cancelled_count p50 observed_slots
  in
  fit_width line width

(* The row is deliberately dense for comparison, but it cannot also carry
   full slot ids, the consumer contract, and the fallback rule without
   clipping. Keep those facts in a wrapped selected-row block underneath the
   four-row matrix. The order is the execution contract: admitted catalog
   slots first, official-client runtimes only after catalog exhaustion. *)
let standalone_lane_detail_lines ~now ~width (lane : Tui_decode.standalone_lane) =
  let ordered values =
    match values with
    | [] -> "(none)"
    | values ->
      values
      |> List.mapi (fun index value ->
        Printf.sprintf "%d %s" (index + 1) (Terminal_text.single_line value))
      |> String.concat "  →  "
  in
  let wrap style text =
    Message_layout.wrap_words ~max_cells:(max 1 (width - 4)) text
    |> List.map (fun line -> style, "  " ^ line)
  in
  let purpose =
    Option.value ~default:"No consumer purpose reported by this server."
      lane.sl_purpose
  in
  let exact_lane which =
    Masc.Exact_lane_run_registry.lane_key which
    |> String.equal lane.sl_lane_id
  in
  let output_meaning, evidence_contract =
    if exact_lane Masc.Exact_lane_run_registry.Board_attention then
      ( "Output meaning: the accepted candidate judgment JSON."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if exact_lane Masc.Exact_lane_run_registry.Hitl_auto_judge then
      ( "Output meaning: the validated and durably settled approval-context judgment summary."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if exact_lane Masc.Exact_lane_run_registry.Librarian then
      ( "Output meaning: selected memory facts plus committed snapshot metadata."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if String.equal lane.sl_lane_id Runtime.verifier_exact_lane_id then
      ( "Output meaning: Task completion or Goal proof verdict, reason, and evaluator runtime."
      , "Evidence: Verifier review records also retain MASC tool observations; open a run to inspect inputs, dispositions, excerpts, duration, and truncation." )
    else
      ( "Output meaning: open a retained run for its exact result."
      , "Evidence: this server did not report a known standalone-lane evidence contract." )
  in
  (* Three facts the server has always sent and nothing drew.

     [required] is the one that changes what an operator does about a lane
     that cannot run: an optional lane nobody configured is a choice, and a
     required one is a hole.

     [configuration_state] separates "nobody configured this" from "the
     registry could not be read", which the status word beside the lane
     collapses into one "unavailable". The block draws the admission error
     below, and those two states each carry one, so this is the typed half
     of a distinction that was only ever legible as prose.

     The last terminal run is what the totals cannot say. [ok/fail/cancel
     962/133/0] reads the same whether the failures were this morning or
     last quarter, and an idle lane says nothing at all about when it last
     did work. *)
  let obligation = if lane.sl_required then "Required" else "Optional" in
  let configuration =
    Tui_decode.standalone_lane_configuration_to_string
      lane.sl_configuration_state
  in
  let last_run =
    match lane.sl_last_outcome, lane.sl_last_terminal_at with
    | None, _ -> "no run has finished"
    | Some outcome, None -> "last run " ^ Terminal_text.single_line outcome
    | Some outcome, Some at ->
      Printf.sprintf "last run %s %s ago"
        (Terminal_text.single_line outcome)
        (Masc_tui_answering.elapsed_text ~now at)
  in
  (* By the state alone. This block draws no glyph, so a colour that also
     answered "is it required" would make a split nothing else in the block
     recovers -- the row two lines up gives every colour class its own mark
     for exactly that reason. The obligation is in the words. *)
  let state_style =
    match lane.sl_configuration_state with
    | Tui_decode.Lane_ready -> Ansi.reset
    | Tui_decode.Lane_slotless | Tui_decode.Lane_unconfigured -> Theme.warn ()
    | Tui_decode.Lane_registry_unavailable -> Theme.bad ()
  in
  wrap Ansi.bold
    (Printf.sprintf "%s · %s" (Terminal_text.single_line lane.sl_label)
       (Terminal_text.single_line purpose))
  @ wrap state_style
      (Printf.sprintf "%s lane · configuration %s · %s" obligation
         configuration last_run)
  @ wrap Ansi.dim
      (Printf.sprintf "Config: [runtime.exact_output_lanes.%s]"
         (Terminal_text.single_line lane.sl_lane_id))
  @ wrap Ansi.reset
      ("Catalog attempts (admitted order): " ^ ordered lane.sl_admitted_slots)
  @ wrap Ansi.reset
      ("Then CLI (after catalog exhaustion): " ^ ordered lane.sl_cli_slots)
  @ wrap
      (if lane.sl_dropped_slots = [] then Ansi.dim else Theme.warn ())
      ("Dropped before execution: " ^ ordered lane.sl_dropped_slots)
  @ (match lane.sl_admission_error with
     | None -> []
     | Some error ->
       wrap (Theme.bad ())
         ("Admission error: " ^ Terminal_text.single_line error))
  @ wrap Ansi.dim
      "TOML spec: slots = required non-empty catalog-ref array; cli_slots = optional official-client runtime-id array."
  @ wrap Ansi.dim
      "Lane configuration is TOML. Run Input/Output is retained JSON evidence. Press e to open this section in the preview-checked runtime.toml editor."
  @ wrap Ansi.reset output_meaning
  @ wrap Ansi.dim evidence_contract

let rec take_rows remaining acc = function
  | _ when remaining <= 0 -> List.rev acc
  | [] -> List.rev acc
  | row :: rest -> take_rows (remaining - 1) (row :: acc) rest

let render_lanes_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let inner = max 1 (framed_inner_width cols) in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.standalone_lanes with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Lanes · Standalone") (title_missing_reading ~error:state.standalone_lanes_error) timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d lanes)  %s  %s"
          (screen_title " MASC Lanes · Standalone")
          (List.length snapshot.sls_lanes) timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let standalone_heading =
    match state.standalone_lanes with
    | None -> "  Standalone LLM lanes · a appends a failover slot"
    | Some snapshot ->
        let observed = Unix.localtime snapshot.sls_observed_at_unix in
        Printf.sprintf
          "  Standalone LLM lanes · a appends a failover slot · observed %02d:%02d:%02d"
          observed.Unix.tm_hour observed.Unix.tm_min observed.Unix.tm_sec
  in
  box_line_styled buf cols ~style:(Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)) standalone_heading;
  (* The standalone rows are drawn directly rather than through a row list
     because the selection band has to land on a lane row, not on the
     windowed/stale notes that follow them. *)
  (match state.standalone_lanes with
   | Some snapshot ->
       List.iteri
         (fun index (lane : Tui_decode.standalone_lane) ->
           let row =
             standalone_lane_row ~now:(Unix.gettimeofday ())
               ~frame:state.activity_frame inner lane
           in
           if
             index = state.lanes_standalone_cursor
           then box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
           else box_line buf cols row)
         snapshot.Tui_decode.sls_lanes;
       if snapshot.sls_lanes = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           "  (no standalone lane observations)";
       if snapshot.sls_exact_run_projection_truncated then
         box_line buf cols
           (Printf.sprintf
              "%s  WINDOWED · exact runs %d/%d; counts and p50 use newest bounded window%s"
              (Theme.warn ()) snapshot.sls_exact_run_projection_count
              snapshot.sls_exact_run_source_total Ansi.reset);
       (match state.standalone_lanes_error with
        | None -> ()
        | Some detail ->
            box_line buf cols
              ((Theme.warn ()) ^ "  STALE · refresh failed: "
               ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset))
   | None ->
       box_line buf cols
         (match state.standalone_lanes_error with
          | None -> Ansi.dim ^ "  loading standalone lane observations…" ^ Ansi.reset
          | Some detail ->
              (Theme.bad ()) ^ "  standalone lane observation unavailable: "
              ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset));
  (* Use only the body's remaining rows. At small terminal heights the matrix
     stays complete and the detail truncates explicitly; at ordinary heights
     the wrapped block shows every slot id without the row's [fit_width]. *)
  (match selected_standalone_lane state with
   | None -> ()
   | Some lane ->
       let action_error_rows =
         match state.lanes_action_error with None -> 0 | Some _ -> 1
       in
       let available =
         max 0
           (rows - count_frame_lines buf - action_error_rows - 3)
       in
       if available > 0 then begin
         box_divider buf cols;
         let detail =
           standalone_lane_detail_lines ~now:(Unix.gettimeofday ())
             ~width:inner lane
         in
         let shown = take_rows available [] detail in
         let shown =
           if List.length detail <= available then shown
           else
             match List.rev shown with
             | [] -> []
             | _ :: rest ->
               List.rev ((Theme.warn (), "  … more; enlarge the terminal") :: rest)
         in
         List.iter
           (fun (style, line) -> box_line_styled buf cols ~style line)
           shown
       end);
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.warn ())
         ("  " ^ Keeper_chat.terminal_safe_text detail));
  (* The failover-candidate picker the "a" key opens. Same projection the
     Runtime surface draws; the row order both render and the key handler
     read is the picker's own, so the cursor and the drawing cannot drift. *)
  (match Masc_tui_types.runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       box_line_styled buf cols ~style:(Theme.info ())
         (Printf.sprintf
            "  adding a failover candidate to %s — j/k move, Enter append, e cancel"
            (Terminal_text.single_line picker.Masc_tui_types.rlp_lane));
       if picker.Masc_tui_types.rlp_choices = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           "  (runtime catalogue unread)"
       else
         List.iteri
           (fun offset (runtime : Masc.Tui_decode.runtime_option) ->
              let note =
                if List.exists (String.equal runtime.ro_id) picker.rlp_already
                then "  (already a slot)"
                else if not runtime.ro_dispatchable then "  (blocked)"
                else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                then "  (same provider as a current slot)"
                else ""
              in
              let mark = if offset = state.runtime_lane_pick_cursor then ">" else " " in
              box_line buf cols
                (Printf.sprintf "  %s %s   %s / %s%s"
                   mark
                   (Terminal_text.single_line runtime.ro_id)
                   (Terminal_text.single_line runtime.ro_provider)
                   (Terminal_text.single_line runtime.ro_model)
                   (Ansi.dim ^ note ^ Ansi.reset)))
           picker.Masc_tui_types.rlp_choices);
  let used_rows = count_frame_lines buf in
  for _ = 1 to max 0 (rows - used_rows - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

(* Status colours for standalone-lane runs, keyed on the decoded variant; a label
   the producer adds later decodes to [Lane_run_other] and reads muted until
   it is named here. *)
let lane_run_status_style = function
  | Tui_decode.Lane_run_succeeded
  | Tui_decode.Lane_run_approved
  | Tui_decode.Lane_run_reviewed
  | Tui_decode.Lane_run_committed -> Theme.ok ()
  | Tui_decode.Lane_run_cancelled
  | Tui_decode.Lane_run_rejected
  | Tui_decode.Lane_run_superseded
  | Tui_decode.Lane_run_deferred
  | Tui_decode.Lane_run_review_cancelled -> Theme.warn ()
  | Tui_decode.Lane_run_failed
  | Tui_decode.Lane_run_completion_persistence_failed
  | Tui_decode.Lane_run_completion_durability_unknown
  | Tui_decode.Lane_run_infrastructure_unavailable
  | Tui_decode.Lane_run_not_reviewed
  | Tui_decode.Lane_run_commit_failed
  | Tui_decode.Lane_run_raised -> Theme.bad ()
  | Tui_decode.Lane_run_running
  | Tui_decode.Lane_run_operator_routed -> Theme.info ()
  | Tui_decode.Lane_run_other _ -> Theme.muted ()

let lane_run_clock started_at =
  let tm = Unix.localtime started_at in
  Printf.sprintf "%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let standalone_lane_label (state : state) lane_id =
  match state.standalone_lanes with
  | None -> lane_id
  | Some snapshot ->
      (match
         List.find_opt
           (fun (lane : Tui_decode.standalone_lane) ->
             String.equal lane.sl_lane_id lane_id)
           snapshot.Tui_decode.sls_lanes
       with
       | Some lane -> lane.sl_label
       | None -> lane_id)

let lane_run_subject (run : Tui_decode.lane_run_summary) =
  match run.lrs_run_kind, run.lrs_subject_id with
  | Tui_decode.Lane_run_task_verification, Some subject -> "task " ^ subject
  | Tui_decode.Lane_run_goal_verification, Some subject -> "goal " ^ subject
  | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    None ->
    run.lrs_actor
;;

(** Recent retained runs of one standalone lane. The list is the paged summary:
    no payload ever crosses it, so Enter fetches one exact detail. *)
let render_lane_run_list (state : state) ~lane_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.lane_runs with
    | None -> []
    | Some runs -> runs
  in
  let shown = List.length runs in
  let coverage =
    let count = match state.lane_runs_total with
      | Some total -> Printf.sprintf "%d loaded / %d retained" shown total
      | None -> Printf.sprintf "%d loaded" shown in
    let continuation =
      if state.lane_runs_loading then " · loading"
      else match state.lane_runs_next with
        | Some _ -> " · ] older"
        | None -> if Option.is_some state.lane_runs then " · end" else "" in
    count ^ continuation in
  let header =
    Printf.sprintf "%s · %s (%s)  %s"
      (screen_title " MASC Lanes")
      (fit_width
         (Terminal_text.single_line (standalone_lane_label state lane_id))
         20)
      coverage (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let identity_heading =
    if String.equal lane_id Runtime.verifier_exact_lane_id then "SUBJECT"
    else "ACTOR"
  in
  (* The run id takes what the named columns leave; it used to run off the
     header with no end while the row cut it at twelve. *)
  let run_id_width =
    Render_schedule.lane_run_id_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  "
    ^ Render_schedule.lane_run_header_row ~identity_header:identity_heading
        ~run_id_width);
  box_divider buf cols;
  (match state.lane_runs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let layout = lanes_scrolled state in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.lane_runs_scroll max_scroll) in
  let runs_window = Rows.of_list ~first:scroll ~height:content_height runs in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.lane_runs ~error:state.lane_runs_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no retained runs for this lane)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match Rows.at runs_window (index + scroll) with
      | None -> box_empty buf cols
      | Some (run : Tui_decode.lane_run_summary) ->
          let elapsed =
            match run.lrs_elapsed_s with
            | None -> "—"
            | Some seconds -> Printf.sprintf "%.1fs" seconds
          in
          let line =
            "  "
            ^ Render_schedule.lane_run_row ~identity_header:identity_heading
                ~status_style:(lane_run_status_style run.lrs_status)
                ~run_id_width
                { Render_schedule.lrow_started =
                    lane_run_clock run.lrs_started_at
                ; lrow_subject =
                    Terminal_text.single_line (lane_run_subject run)
                ; lrow_status =
                    Tui_decode.lane_run_status_label run.lrs_status
                ; lrow_elapsed = elapsed
                ; lrow_slot =
                    Terminal_text.single_line_or ~default:"—"
                      run.lrs_selected_slot
                ; lrow_run_id = Terminal_text.single_line run.lrs_run_id
                }
          in
          if index + scroll = state.lane_runs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d runs, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_lanes_run_list);
  finish_surface state ~surface_key:"lane-runs" ~rows:terminal_rows ~cols buf

(* A payload renders whole up to a bound; past it the frame shows the head and
   says so, rather than hanging the TUI on the kind of body that made the
   listing drop payloads. The cut lands on a line boundary so no multibyte
   sequence is split. *)
let lane_run_render_max_bytes = 65536

let lane_run_payload_lines ~width json =
  let full = Yojson.Safe.pretty_to_string json in
  let text, truncated =
    if String.length full <= lane_run_render_max_bytes then full, false
    else
      let cut =
        match String.rindex_from_opt full lane_run_render_max_bytes '\n' with
        | Some newline -> newline
        | None -> lane_run_render_max_bytes
      in
      String.sub full 0 cut, true
  in
  let rendered =
    fenced_document_text ~language:"json" text
    |> document_markdown ~width
    |> List.map (fun line -> Ansi.reset, line)
  in
  if truncated then
    rendered
    @ [ ( Theme.warn ()
        , Printf.sprintf "… truncated, total %d bytes" (String.length full) ) ]
  else rendered

let lane_run_decision_badge (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_decision with
  | Tui_decode.Lane_run_decision_approved -> Theme.ok (), "APPROVED"
  | Tui_decode.Lane_run_decision_rejected -> Theme.warn (), "REJECTED"
  | Tui_decode.Lane_run_decision_reviewed -> Theme.ok (), "REVIEWED"
  | Tui_decode.Lane_run_decision_committed -> Theme.ok (), "COMMITTED"
  | Tui_decode.Lane_run_decision_superseded -> Theme.info (), "SUPERSEDED"
  | Tui_decode.Lane_run_decision_pending -> Theme.info (), "NO DECISION YET"
  | Tui_decode.Lane_run_decision_not_reached -> Theme.warn (), "NO DECISION"
  | Tui_decode.Lane_run_not_a_decision -> Theme.info (), "NOT A VERDICT"
  | Tui_decode.Lane_run_decision_unknown -> Theme.muted (), "UNKNOWN"

let lane_run_tool_disposition_presentation = function
  | Tui_decode.Lane_run_tool_completed -> Theme.ok (), "✓"
  | Tui_decode.Lane_run_tool_deferred -> Theme.warn (), "△"
  | Tui_decode.Lane_run_tool_failed -> Theme.bad (), "✗"
  | Tui_decode.Lane_run_tool_disposition_other _ -> Theme.warn (), "?"

let lane_run_tool_call_summary (tool : Tui_decode.lane_run_tool) =
  let style, mark =
    lane_run_tool_disposition_presentation tool.lrt_disposition
  in
  let disposition =
    Tui_decode.lane_run_tool_disposition_label tool.lrt_disposition
    |> Terminal_text.single_line
  in
  Printf.sprintf "%s%s%s %s%s%s ‹%s · %.0fms›%s"
    style Ansi.bold mark
    (Terminal_text.single_line tool.lrt_name)
    Ansi.reset style disposition tool.lrt_duration_ms Ansi.reset

type lane_run_tool_counts =
  { completed : int
  ; deferred : int
  ; failed : int
  ; other : int
  }

let lane_run_tool_count_summary tools =
  let counts =
    List.fold_left
      (fun counts (tool : Tui_decode.lane_run_tool) ->
         match tool.lrt_disposition with
         | Tui_decode.Lane_run_tool_completed ->
           { counts with completed = counts.completed + 1 }
         | Tui_decode.Lane_run_tool_deferred ->
           { counts with deferred = counts.deferred + 1 }
         | Tui_decode.Lane_run_tool_failed ->
           { counts with failed = counts.failed + 1 }
         | Tui_decode.Lane_run_tool_disposition_other _ ->
           { counts with other = counts.other + 1 })
      { completed = 0; deferred = 0; failed = 0; other = 0 }
      tools
  in
  [ Theme.bad (), "✗", counts.failed, "failed"
  ; Theme.warn (), "△", counts.deferred, "deferred"
  ; Theme.warn (), "?", counts.other, "other"
  ; Theme.ok (), "✓", counts.completed, "completed"
  ]
  |> List.filter_map (fun (style, mark, count, label) ->
    if count = 0 then None
    else
      Some
        (Printf.sprintf "%s%s%s %s %s %d %s" style Ansi.reverse Ansi.bold mark
           (String.uppercase_ascii label) count Ansi.reset))
  |> String.concat " "

let lane_run_tool_summary = function
  | Tui_decode.Lane_run_no_tools_by_contract ->
    Theme.muted (), "TOOLS  none · exact-output runs do not use the MASC tool loop"
  | Tui_decode.Lane_run_tools_pending ->
    Theme.info (), "TOOLS  pending · the verifier run is still in progress"
  | Tui_decode.Lane_run_tools_contract_unknown ->
    Theme.muted (), "TOOLS  unknown · this run kind has no typed tool contract"
  | Tui_decode.Lane_run_tools_observed tools ->
    let calls = List.length tools in
    let counts = lane_run_tool_count_summary tools in
    let names =
      List.map lane_run_tool_call_summary tools
      |> String.concat "  │  "
    in
    let evidence =
      [ names ]
      |> List.filter (fun value -> not (String.equal value ""))
      |> String.concat "  ·  "
    in
    let call_count =
      Printf.sprintf "%d %s" calls (if calls = 1 then "CALL" else "CALLS")
    in
    let overview =
      if String.equal counts "" then call_count else counts ^ "  ──  " ^ call_count
    in
    (* fit_width clips the right edge, so put the worst typed disposition
       immediately after the label. Even an ultra-narrow terminal retains the
       operator-significant failure/deferred badge before call metadata. *)
    ( Ansi.reset
    , Printf.sprintf "%sTOOLS%s %s%s" Ansi.bold Ansi.reset overview
        (if String.equal evidence "" then "" else "  │  " ^ evidence) )

let lane_run_skill_summary = function
  | Tui_decode.Lane_run_no_skills_by_contract ->
    Theme.muted (),
    "SKILLS  none · standalone runs do not load Keeper Skill instructions"
  | Tui_decode.Lane_run_skills_contract_unknown ->
    Theme.muted (), "SKILLS  unknown · this run kind has no typed Skill contract"

let lane_run_gate_judgment_summary = function
  | Tui_decode.Lane_run_not_gate_judgment -> None
  | Tui_decode.Lane_run_gate_judgment_pending ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %spending%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.info ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_judgment_unavailable ->
    Some (Theme.warn (), "JUDGMENT  원문 사용 불가 · 판정 여부를 확인할 수 없습니다")
  | Tui_decode.Lane_run_gate_judgment_not_reached ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %snone%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.warn ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_advisory judgment ->
    let style =
      match judgment with
      | Keeper_approval_queue_rules_types.Approve -> Theme.ok ()
      | Keeper_approval_queue_rules_types.Deny -> Theme.warn ()
      | Keeper_approval_queue_rules_types.Require_human -> Theme.info ()
    in
    let label =
      Keeper_approval_queue_rules_types.advisory_judgment_to_string judgment
      |> String.uppercase_ascii
    in
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %sADVISORY %s%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset style label Ansi.reset )

let lane_run_summary_lines (detail : Tui_decode.lane_run_detail) =
  let subject =
    match detail.lrd_run_kind, detail.lrd_subject_id with
    | Tui_decode.Lane_run_task_verification, Some subject ->
      "  ·  TASK " ^ Terminal_text.single_line subject
    | Tui_decode.Lane_run_goal_verification, Some subject ->
      "  ·  GOAL " ^ Terminal_text.single_line subject
    | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
    | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
      None ->
      ""
  in
  let elapsed =
    match detail.lrd_elapsed_s with
    | None -> ""
    | Some seconds -> Printf.sprintf "  ·  %.1fs" seconds
  in
  let slot =
    match detail.lrd_selected_slot with
    | None -> ""
    | Some slot -> "  ·  SLOT " ^ Terminal_text.single_line slot
  in
  let decision_style, decision = lane_run_decision_badge detail in
  let tool_style, tools = lane_run_tool_summary detail.lrd_tool_evidence in
  let skill_style, skills = lane_run_skill_summary detail.lrd_skill_evidence in
  let gate_judgment =
    match lane_run_gate_judgment_summary detail.lrd_gate_judgment with
    | None -> []
    | Some (style, line) -> [ style, "  " ^ line ]
  in
  [ ( Ansi.reset
    , Printf.sprintf "  LANE  %s  ·  %s%s"
        (Terminal_text.single_line detail.lrd_lane)
        (Terminal_text.single_line
           (Tui_decode.lane_run_kind_label detail.lrd_run_kind))
        subject )
  ; ( Ansi.dim
    , Printf.sprintf "  ACTOR  %s  ·  STARTED %s%s%s"
        (Terminal_text.single_line detail.lrd_actor)
        (lane_run_clock detail.lrd_started_at) elapsed slot )
  ; ( Ansi.reset
    , Printf.sprintf "  DECISION  %s%s%s  ·  RUN  %s%s%s" decision_style
        decision Ansi.reset (lane_run_status_style detail.lrd_status)
        (Terminal_text.single_line
           (Tui_decode.lane_run_status_label detail.lrd_status))
        Ansi.reset )
  ]
  @ gate_judgment
  @ [ tool_style, "  " ^ tools; skill_style, "  " ^ skills ]

let lane_run_panel_titles (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_run_kind, detail.lrd_tool_evidence with
  | Tui_decode.Lane_run_exact_output, _ ->
    "INPUT · PROMPT PAYLOAD", "OUTPUT · MODEL RESPONSE"
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    Tui_decode.Lane_run_tools_observed tools ->
    ( "INPUT · VERIFICATION REQUEST"
    , Printf.sprintf "OUTPUT · VERDICT + TOOL EVIDENCE (%d %s)"
        (List.length tools)
        (if List.length tools = 1 then "CALL" else "CALLS") )
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    (Tui_decode.Lane_run_tools_pending | Tui_decode.Lane_run_no_tools_by_contract
    | Tui_decode.Lane_run_tools_contract_unknown) ->
    "INPUT · VERIFICATION REQUEST", "OUTPUT · VERDICT + TOOL EVIDENCE"
  | Tui_decode.Lane_run_kind_other _, _ -> "INPUT", "OUTPUT"

let lane_run_payload_availability_lines ~width availability payload =
  match availability with
  | Masc.Exact_lane_run_registry.Available ->
    (match payload with
     | Some value -> lane_run_payload_lines ~width value
     | None -> [ Theme.warn (), "원문 상태 불일치: 사용 가능한 원문 필드가 없습니다" ])
  | Masc.Exact_lane_run_registry.Not_loaded ->
    [ Theme.muted (), "원문을 불러오지 않았습니다" ]
  | Masc.Exact_lane_run_registry.Unavailable error ->
    let text = "원문 사용 불가: " ^ Masc.Exact_lane_run_registry.payload_read_error_to_string error in
    Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
    |> List.map (fun line -> Theme.warn (), line)

let lane_run_input_lines ~width (detail : Tui_decode.lane_run_detail) =
  lane_run_payload_availability_lines ~width detail.lrd_input_availability (Some detail.lrd_input_payload)

let lane_run_output_lines ~width (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_output_availability, detail.lrd_output with
  | None, _ -> [ Theme.muted (), "실행 중 · 아직 출력이 기록되지 않았습니다" ]
  | Some availability, output ->
    lane_run_payload_availability_lines ~width availability output

let lane_run_stacked_lines ~width (detail : Tui_decode.lane_run_detail) =
  let input_title, output_title = lane_run_panel_titles detail in
  let indent lines = List.map (fun (style, line) -> style, "  " ^ line) lines in
  [ Ansi.bold, "  " ^ input_title ]
  @ indent (lane_run_input_lines ~width detail)
  @ [ Ansi.dim, ""; Ansi.bold, "  " ^ output_title ]
  @ indent (lane_run_output_lines ~width detail)

let lane_run_pane_progress ~scroll ~height total =
  if total = 0 then "0/0"
  else if height <= 0 then Printf.sprintf "0/%d" total
  else
    Printf.sprintf "%d-%d/%d" (scroll + 1) (min total (scroll + height)) total

let lane_run_split_line buf cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = " │ " in
  let divider_width = 3 in
  let right_width = max 1 (inner - left_width - divider_width) in
  let styled width (style, line) =
    fit_width (style ^ line ^ Ansi.reset) width
  in
  box_line buf cols
    (styled left_width left ^ Theme.recede () ^ divider ^ Ansi.reset
     ^ styled right_width right)

let render_lane_run_detail (state : state) ~run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let detail =
    match state.lane_run_detail with
    | Some detail when String.equal detail.Tui_decode.lrd_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title " MASC Lane Run")
      (fit_width (Terminal_text.single_line run_id) 38)
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.lane_run_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       if Option.is_none detail then box_divider buf cols);
  let error_rows =
    match detail, state.lane_run_detail_error with
    | Some _, Some _ -> 1
    | None, Some _ -> 2
    | (Some _ | None), None -> 0
  in
  let scroll, max_scroll =
    match detail, state.lane_run_detail_error with
    | None, error ->
      let content_height = max 1 (rows - 5 - error_rows) in
      let line =
        match error with
        | None -> Ansi.dim, "  (loading exact run record)"
        | Some _ -> Ansi.dim, page_failed_note
      in
      box_line_styled buf cols ~style:(fst line) (snd line);
      for _ = 2 to content_height do
        box_empty buf cols
      done;
      0, 0
    | Some detail, (Some _ | None) ->
      let summary = lane_run_summary_lines detail in
      List.iter
        (fun (style, line) -> box_line_styled buf cols ~style line)
        summary;
      box_divider buf cols;
      if cols >= keeper_split_threshold_cols then begin
        let inner = framed_inner_width cols in
        let divider_width = 3 in
        let left_width = max 1 ((inner - divider_width) / 2) in
        let right_width = max 1 (inner - left_width - divider_width) in
        let input_lines =
          lane_run_input_lines ~width:left_width detail
        in
        let output_lines = lane_run_output_lines ~width:right_width detail in
        let payload_rows =
          max 0 (rows - List.length summary - 6 - error_rows)
        in
        if payload_rows = 0
        then 0, 0
        else begin
          let content_height = payload_rows - 1 in
          let input_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length input_lines - content_height)
          in
          let output_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length output_lines - content_height)
          in
          let max_scroll = max input_max_scroll output_max_scroll in
          let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
          let input_scroll = min scroll input_max_scroll in
          let input_lines_window = Rows.of_list ~first:input_scroll ~height:content_height input_lines in
          let output_scroll = min scroll output_max_scroll in
          let input_title, output_title = lane_run_panel_titles detail in
          lane_run_split_line buf cols ~left_width
            ~left:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" input_title
                  (lane_run_pane_progress ~scroll:input_scroll
                     ~height:content_height (List.length input_lines)) )
            ~right:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" output_title
                  (lane_run_pane_progress ~scroll:output_scroll
                     ~height:content_height (List.length output_lines)) );
            let output_lines_window = Rows.of_list ~first:output_scroll ~height:content_height output_lines in
          for index = 0 to content_height - 1 do
            let left =
              Option.value
                (Rows.at input_lines_window (index + input_scroll))
                ~default:(Ansi.reset, "")
            in
            let right =
              Option.value
                (Rows.at output_lines_window (index + output_scroll))
                ~default:(Ansi.reset, "")
            in
            lane_run_split_line buf cols ~left_width ~left ~right
          done;
          scroll, max_scroll
        end
      end
      else begin
        let lines =
          lane_run_stacked_lines ~width:(max 1 (cols - 8)) detail
        in
        let content_height =
          max 0 (rows - List.length summary - 6 - error_rows)
        in
        let max_scroll =
          if content_height = 0
          then 0
          else max 0 (List.length lines - content_height)
        in
        let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
        let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
        for index = 0 to content_height - 1 do
          match Rows.at lines_window (index + scroll) with
          | None -> box_empty buf cols
          | Some (style, line) -> box_line_styled buf cols ~style line
        done;
        scroll, max_scroll
      end
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_lanes_run_detail ~scroll ~max_scroll));
  finish_surface state ~clamped:(Lane_run_detail_scroll scroll)
    ~surface_key:"lane-run" ~rows:terminal_rows ~cols buf

(* The clients roster: everyone attached to this workspace in one reading —
   directory agents, state-backed sessions, runtime fibers. The keeper
   roster answers "which Keepers exist"; this answers "who is here now",
   which includes identities no other surface lists, such as a non-keeper
   MCP client. One row per identity, sorted by name on the server, with the
   status dot, the type, the keeper a row is bound to when it is, and what
   task it holds. *)
let render_clients (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let clients =
    match state.clients_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.cls_clients
  in
  let shown = List.length clients in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.clients_surface with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Config / Runtime · Clients") (title_missing_reading ~error:state.clients_surface_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d attached)  %s  %s"
          (screen_title " MASC Config / Runtime · Clients") shown timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows like the verification submitter column: a fixed
     width puts the columns after the longest name out of line with the
     rest, and session names are the column the eye scans by. *)
  let name_width =
    List.fold_left
      (fun widest (row : Masc.Tui_decode.client_row) ->
         max widest
           (Message_layout.display_width
              (Terminal_text.single_line row.Masc.Tui_decode.cr_name)))
      16 clients
    |> min 24
  in
  let col_hdr =
    Printf.sprintf "  %-9s %-*s %-10s %-16s %-9s %s" "Status" name_width
      "Name" "Type" "Keeper" "Task" "Last seen"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.clients_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.clients_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.clients_surface_scroll max_scroll) in
  let clients_window = Rows.of_list ~first:scroll ~height:content_height clients in
  (* The wire carries RFC3339; the roster only needs the clock, the same
     reading the header's own timestamp gives it a distance to. *)
  let clock_of_iso value =
    match String.index_opt value 'T' with
    | Some at when String.length value - at >= 9 ->
        String.sub value (at + 1) 8
    | _ -> value
  in
  if shown = 0 then begin
    let empty =
      match state.clients_surface_error with
      | Some _ -> page_failed_note
      | None -> "  (nobody attached)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at clients_window idx with
      | None -> box_empty buf cols
      | Some row ->
          let open Masc.Tui_decode in
          let status = client_status_to_string row.cr_status in
          let name = Terminal_text.single_line row.cr_name in
          let keeper =
            match row.cr_keeper_name with
            | Some keeper -> Terminal_text.single_line keeper
            | None -> "-"
          in
          let task =
            match row.cr_current_task with
            | Some task -> Terminal_text.single_line task
            | None -> "-"
          in
          let line =
            Printf.sprintf "  %-9s %s %-10s %-16s %-9s %s" status
              (fit_width name name_width)
              (fit_width (Terminal_text.single_line row.cr_agent_type) 10)
              (fit_width keeper 16)
              (fit_width task 9)
              (clock_of_iso row.cr_last_seen)
          in
          (* Inactive rows stay in the roster -- "who left" is part of the
             reading -- but they recede, the way the empty-state rows do. *)
          let style =
            match row.cr_status with
            | Client_inactive -> Theme.recede ()
            | _ -> Ansi.reset
          in
          if idx = state.clients_surface_cursor then
            box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d attached, scroll %d]" shown scroll);
  box_bottom buf cols;
  finish_surface state ~surface_key:"clients" ~rows:terminal_rows ~cols buf
;;

let render_lanes (state : state) =
  match state.lanes_mode with
  | Lanes_overview -> render_lanes_overview state
  | Lanes_run_list lane_id -> render_lane_run_list state ~lane_id
  | Lanes_run_detail (_, run_id) -> render_lane_run_detail state ~run_id

(** Render keeper detail view with live context and scrolling *)
(* The detail box alone -- borders, title, scrolled content -- written into
   [buf] at [cols] wide, footer excluded so a caller can lay it beside the
   roster pane. Returns the scroll the frame actually used. *)
(* What the Keeper carries to reach a service, by name.

   Values are not here to be hidden -- the producer never sends them. The
   composite body carries names, counts and a validation flag, so this pane
   cannot show a credential by accident.

   A Keeper absent from the projection list is a different reading from one
   whose projection says [absent]: the first means the producer has not
   answered for this Keeper yet, the second means it answered that no root is
   configured. Saying "none" for both would report a fact the server did not
   send. *)
let secret_lines (state : state) (k : keeper) =
  let dim line = Ansi.dim ^ line ^ Ansi.reset in
  match
    List.find_opt
      (fun (p : Masc.Tui_decode.keeper_secret_projection) ->
        String.equal p.Masc.Tui_decode.ksp_keeper k.k_name)
      state.keeper_secrets
  with
  | None -> [ dim "  (no projection reported for this Keeper)" ]
  | Some p ->
      let status = Masc.Tui_decode.keeper_secret_status_to_string p.ksp_status in
      let status_line =
        match p.ksp_status with
        | Masc.Tui_decode.Secret_ready ->
            "  Status:  " ^ (Theme.ok ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_error ->
            "  Status:  " ^ (Theme.bad ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_empty | Masc.Tui_decode.Secret_absent
        | Masc.Tui_decode.Secret_status_unknown _ ->
            "  Status:  " ^ Ansi.dim ^ status ^ Ansi.reset
      in
      let entry_lines label = function
        | [] -> [ dim (Printf.sprintf "  %s  -" label) ]
        | names ->
            List.mapi
              (fun index name ->
                let lead = if index = 0 then label else String.make (String.length label) ' ' in
                Printf.sprintf "  %s  %s" lead (Terminal_text.single_line name))
              names
      in
      [ status_line
      ; Printf.sprintf "  Root:    %s" (Terminal_text.single_line p.ksp_root)
      ; ""
      ]
      @ entry_lines "Env: " p.ksp_env_names
      @ (match p.ksp_file_paths with
         | [] -> []
         | paths -> "" :: entry_lines "Files:" paths)
      @ (match p.ksp_error with
         | None -> []
         | Some detail ->
             [ ""; (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ])
      @ [ ""
        ; dim
            (if p.ksp_values_validated then
               "  Values were read and validated. They are never sent here."
             else "  Values were not validated on the last read.")
        ]

(* The Identity tab's body. Numbering comes from
   [Masc_tui_types.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let identity_lines (state : state) (k : keeper) ~cols providers =
  (* Everything on this pane reads the filtered list: the rows drawn, the
     number beside each one, and the row the marker is on. A screen that
     numbered the whole set while the keys acted on a subset would start the
     wrong service. *)
  let query = Option.value state.identity_filter ~default:"" in
  let connectable = Masc_tui_types.identity_connectable ~query providers in
  let tools_of id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared { idp_id; idp_tools; _ }
          when String.equal idp_id id -> Some idp_tools
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _ ->
            None)
      providers
    |> Option.join
  in
  (* Which other Keepers hold this one. Shown on both states: on an attached
     row it says the coverage, and on an unattached one it says the service
     is already in use somewhere, which is the row an operator is most likely
     to have lost track of. *)
  let switch_of id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared
            { idp_id; idp_enabled; idp_switch_problem; _ }
          when String.equal idp_id id -> Some (idp_enabled, idp_switch_problem)
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _
          -> None)
      providers
  in
  let also_on id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared { idp_id; idp_also_on; _ }
          when String.equal idp_id id -> Some idp_also_on
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _
          -> None)
      providers
    |> Option.value ~default:[]
  in
  let numbered =
    List.mapi
      (fun index (id, label) ->
        (* Attached-and-offering-nothing is a third state. Reading it as "not
           attached" would tell an operator to consent again for no reason. *)
        let row_state =
          match tools_of id with
          | None -> Ansi.dim ^ "not attached" ^ Ansi.reset
          | Some [] -> Ansi.dim ^ "attached, no tools" ^ Ansi.reset
          | Some names -> (
              (* The switch outranks the tool count: a service an operator
                 turned off is handing this keeper nothing, however many
                 tools its catalog names, and an unreadable switch store
                 must not render as on. *)
              match switch_of id with
              | Some (_, Some _) ->
                  (Theme.bad ()) ^ "switch unreadable" ^ Ansi.reset
              | Some (Some false, None) ->
                  (Theme.warn ()) ^ "off" ^ Ansi.reset
              | Some ((Some true | None), None) | None ->
                  Printf.sprintf "%s%d tools%s" (Theme.ok ())
                    (List.length names) Ansi.reset)
        in
        (* The row the arrows are on is marked rather than merely numbered:
           past nine the number is no longer a key an operator can press,
           and the marker is what says which one enter would start. *)
        let here =
          index
          = Masc_tui_types.identity_cursor_clamped ~query ~providers
              state.identity_cursor
        in
        let marker = if here then Theme.ok () ^ ">" ^ Ansi.reset else " " in
        (* Padded before it is emphasised: the escape codes are characters
           to a width specifier and nothing on screen, so padding afterwards
           shortens the column by however long the codes are. *)
        let padded = Printf.sprintf "%-24s" (Terminal_text.single_line label) in
        let shown = if here then Ansi.bold ^ padded ^ Ansi.reset else padded in
        let elsewhere =
          match also_on id with
          | [] -> ""
          | names ->
            Ansi.dim ^ "  · also " ^ String.concat ", " names ^ Ansi.reset
        in
        Printf.sprintf "%s %2d  %s %s%s" marker (index + 1) shown row_state
          elsewhere)
      connectable
  in
  let attached_tool_lines =
    connectable
    |> List.concat_map (fun (id, _) ->
           match tools_of id with
           | None | Some [] -> []
           | Some names ->
               ""
               :: (Ansi.dim ^ "  " ^ Terminal_text.single_line id ^ Ansi.reset)
               :: List.map
                    (fun name -> "    " ^ Terminal_text.single_line name)
                    names)
  in
  let rejected =
    List.filter_map
      (function
        | Masc_tui_types.Identity_declared _ -> None
        | Masc_tui_types.Identity_unreadable { idp_id; idp_problem } ->
            Some
              (Printf.sprintf "  -  %s  %s%s%s"
                 (Terminal_text.single_line idp_id)
                 (Theme.bad ())
                 (Terminal_text.single_line idp_problem)
                 Ansi.reset))
      providers
  in
  let started =
    match state.identity_login with
    | Some login when String.equal login.ils_keeper k.k_name ->
        (* Wrapped, not truncated. The URL is about nine hundred characters
           and a pane cuts it at its own width; a cut URL cannot be selected
           or copied, so the login stopped there. The TUI opens it as well --
           this is what is left when the machine has no opener. *)
        let url = Terminal_text.single_line login.ils_url in
        let width = max 20 (cols - 6) in
        let rec fold at acc =
          if at >= String.length url then List.rev acc
          else
            let take = min width (String.length url - at) in
            fold (at + take) (("    " ^ String.sub url at take) :: acc)
        in
        ("" :: (Ansi.bold ^ "  A browser should have opened to consent as "
                ^ Terminal_text.single_line login.ils_label ^ "." ^ Ansi.reset)
         :: (Ansi.dim ^ "  If it did not, the URL is here:" ^ Ansi.reset)
         :: fold 0 [])
        @ [ Ansi.dim
            ^ "  Nothing is written to this keeper until you come back."
            ^ Ansi.reset ]
    | Some _ | None -> []
  in
  (* What one attempt answered. Wrapped, because the message that matters
     most here is the long one: a provider that registers no client says what
     to make and where to put it, and a single truncated line is the half of
     that sentence an operator cannot act on. *)
  (* Built by the shared function and only coloured here: the key handler
     counts these rows to know where the list starts, and two places wrapping
     the same text at their own idea of the width would disagree. *)
  let attempt_kind =
    Option.map fst state.identity_attempt_error
  in
  let attempt =
    Masc_tui_types.identity_notice ~cols
      (Option.map
         (fun (kind, text) -> (kind, Terminal_text.single_line text))
         state.identity_attempt_error)
  in
  (* Green when it worked and red when it did not. One line reports both, and
     drawing a recorded app in the colour of a refusal is a report that reads
     as its own opposite. *)
  let attempt =
    let body =
      match attempt_kind with
      | Some Masc_tui_types.Notice_ok -> Theme.ok ()
      | Some Masc_tui_types.Notice_bad | None -> Theme.bad ()
    in
    List.mapi
      (fun index line ->
        if line = "" then line
        else if index = List.length attempt - 1 then Ansi.dim ^ line ^ Ansi.reset
        else body ^ line ^ Ansi.reset)
      attempt
  in
  (* The query, and what it left. Shown even when it matches nothing --
     otherwise an empty pane is indistinguishable from a service list that
     failed to load. *)
  let filter_rows =
    List.map
      (fun line -> if line = "" then line else Theme.ok () ^ line ^ Ansi.reset)
      (Masc_tui_types.identity_filter_rows ~providers state.identity_filter)
  in
  if numbered = [] && rejected = [] && state.identity_filter <> None then
    Masc_tui_types.identity_preamble
      ~keeper:(Terminal_text.single_line k.k_name)
      ~notice:
        (attempt @ started @ Masc_tui_types.identity_app_form_rows state.identity_app_form
        @ filter_rows)
    @ [ Ansi.dim ^ "  Nothing here matches. esc to see them all." ^ Ansi.reset ]
  else if numbered = [] && rejected = [] then
    [ Ansi.dim ^ "  Nothing is declared under config/identity/." ^ Ansi.reset ]
  else
    Masc_tui_types.identity_preamble
      ~keeper:(Terminal_text.single_line k.k_name)
      ~notice:
        (attempt @ started @ Masc_tui_types.identity_app_form_rows state.identity_app_form
        @ filter_rows)
    @ numbered @ rejected @ attached_tool_lines

let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = framed_inner_width cols in

    (* Build all detail lines first, then apply scroll *)
    let lines = ref [] in
    let add_line s = lines := s :: !lines in

    (* Helper to add a labeled row *)
    let add_row label value =
      add_line (Printf.sprintf "  %s%-22s%s %s" (Masc_tui_theme.tone Masc_tui_theme.Accent) label Ansi.reset value)
    in
    let add_empty () = add_line "" in
    let add_section title =
      add_line (Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" (Terminal_text.single_line k.k_name);
    add_row "Paused:"
      (if k.k_paused then (Theme.warn ()) ^ "yes" ^ Ansi.reset
       else Ansi.dim ^ "no" ^ Ansi.reset);
    add_empty ();

    (* Gate section. Two settings with similar names decide different things,
       so both are named rather than merged: YOLO is the in-memory stance that
       stops this chat asking and a restart clears, while the Gate mode is
       durable and is what an external effect -- a write to a service this
       Keeper is attached to -- is actually decided under. An operator reading
       one for the other is how a call gets made that nobody meant to allow. *)
    add_section "Gate";
    add_row "Chat asks (YOLO):"
      (if List.mem k.k_name state.keeper_yolo_names then
         (Theme.bad ()) ^ "skipped" ^ Ansi.reset
       else Ansi.dim ^ "asked" ^ Ansi.reset);
    add_row "Effects (Gate mode):"
      (match List.assoc_opt k.k_name state.keeper_gate_modes with
       | Some mode -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Terminal_text.single_line mode ^ Ansi.reset
       | None -> Ansi.dim ^ "workspace" ^ Ansi.reset);
    add_row "Judge first:"
      (match List.assoc_opt k.k_name state.keeper_gate_judges with
       | Some slot -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Terminal_text.single_line slot ^ Ansi.reset
       | None -> Ansi.dim ^ "lane order" ^ Ansi.reset);
    add_empty ();

    (* Current work section *)
    add_section "Current Work";
    add_row "Task:"
      (Terminal_text.single_line_or ~default:"-" k.k_current_task_id);
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    (match
       Context_state.reading_for_keeper ~keeper_name:k.k_name
         state.live_context
     with
     | None ->
         add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)
     | Some reading ->
         (match
            Terminal_text.optional_single_line reading.error,
            reading.observation
          with
          | Some error, _ ->
              add_row "Context:" ((Theme.bad ()) ^ error ^ Ansi.reset)
          | None, Some observation ->
              (match Observation_layout.context_summary observation with
               | Observation_layout.Context_measured observation ->
                   let ratio = observation.ratio in
                   let pct =
                     Float.of_int (Observation_layout.percentage_tenths ratio)
                     /. 10.0
                   in
                   let bar_width =
                     Masc_tui_render_schedule.keeper_context_bar_width
                       ~inner_width:inner
                   in
                   add_row "Context:"
                     (Printf.sprintf "%s%.1f%%%s  %s  %d / %d tokens"
                        (ctx_color ratio) pct Ansi.reset
                        (ctx_bar ratio bar_width) observation.tokens
                        observation.maximum);
                   add_row "Observed:"
                     (Terminal_text.short_timestamp observation.observed_at);
                   add_row "Turn Ref:"
                     (Terminal_text.single_line observation.turn_ref)
               | Observation_layout.Context_partial observation ->
                   (* The one reading in this row that printed a bare number.
                      The row also carries a cumulative figure, which says
                      "cumulative usage" in its own sentence, and a measured
                      one, which carries a percentage and a window -- so a
                      number alone was the only thing here a reader had to
                      guess the scope of, and the two differ by an order of
                      magnitude (#33791). This one is occupancy: the
                      projection emits an observation only once it has
                      confirmed the turn's own usage. *)
                   add_row "Context:"
                     (Printf.sprintf
                        "%d tokens in context; window not observed"
                        observation.tokens);
                   add_row "Observed:"
                     (Terminal_text.short_timestamp observation.observed_at);
                   add_row "Turn Ref:"
                     (Terminal_text.single_line observation.turn_ref)
               | Observation_layout.Context_unavailable reason ->
                   add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset))
          | None, None ->
              add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)));
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    (match k.k_origin with
     | Tui_decode.Persisted_keeper -> ()
     | Declared_keeper requirements ->
       add_row "Preparation:" (String.concat " · "
         (List.map Masc.Keeper_declared_roster.requirement_label requirements)));
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (Terminal_text.short_timestamp k.k_last_turn_ts);
    add_empty ();

    (* Recent activity, folded from the metrics rows already read for this
       Keeper. The window is bounded by row count, so it can fall short of the
       span; when it does, say what it reached instead of implying a full day. *)
    let activity =
      Keeper_activity.summarize
        ~since:
          (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
        state.log_entries
    in
    add_section "Last 24h";
    if not activity.Keeper_activity.aw_covered then
      add_row "Window:"
        (match activity.Keeper_activity.aw_oldest_ts with
         | Some oldest ->
           Printf.sprintf "partial, reaches %s"
             (Terminal_text.short_timestamp oldest)
         | None -> "no metrics rows read");
    add_row "Turns / Heartbeats:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
         activity.Keeper_activity.aw_heartbeats);
    add_row "Tokens In / Out:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_input_tokens
         activity.Keeper_activity.aw_output_tokens);
    add_row "Cost:"
      (Printf.sprintf "$%.4f" activity.Keeper_activity.aw_cost_usd);
    add_row "Tool Calls:"
      (string_of_int activity.Keeper_activity.aw_tool_calls);
    add_row "Top Tools:"
      (match activity.Keeper_activity.aw_top_tools with
       | [] -> "-"
       | tools ->
         tools
         |> List.map (fun (tool : Keeper_activity.tool_use) ->
                Printf.sprintf "%s x%d"
                  (Terminal_text.single_line tool.Keeper_activity.tu_name)
                  tool.Keeper_activity.tu_calls)
         |> String.concat "  ");
    add_empty ();

    add_section "Autonomy";
    add_row "Last Outcome:" k.k_last_proactive_outcome;
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (Terminal_text.short_timestamp k.k_created_at);
    add_row "Updated:" (Terminal_text.short_timestamp k.k_updated_at);

    (* Reverse to get correct order *)
    let info_lines = List.rev !lines in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    let stamped_or view error =
      match error with
      | Some detail -> [ (Theme.bad ()) ^ "  " ^ detail ^ Ansi.reset ]
      | None -> (
          match view with
          | Some (stamp, lines) when String.equal stamp k.k_name ->
              List.map (fun line -> "  " ^ line) lines
          | Some _ | None -> [ Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset ])
    in
    let channel_lines =
      match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  channel transports unavailable: "
            ^ Terminal_text.single_line detail ^ Ansi.reset
          ]
      | _, None -> [ Ansi.dim ^ "  (loading channel transports…)" ^ Ansi.reset ]
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
          in
          let connection_text (connector : Tui_decode.connector) =
            match connector.cn_connection with
            | Tui_decode.Connector_connected -> "CONNECTED"
            | Connector_connected_unavailable -> "CONNECTED / UNAVAILABLE"
            | Connector_disconnected -> "DISCONNECTED"
            | Connector_offline -> "UNAVAILABLE"
            | Connector_stale -> "STALE"
          in
          let connection_label (connector : Tui_decode.connector) =
            match connector.cn_connection with
            | Tui_decode.Connector_connected ->
                (Theme.ok ()) ^ "● CONNECTED" ^ Ansi.reset
            | Connector_connected_unavailable ->
                (Theme.warn ()) ^ "● CONNECTED / UNAVAILABLE" ^ Ansi.reset
            | Connector_disconnected ->
                (Theme.bad ()) ^ "● DISCONNECTED" ^ Ansi.reset
            | Connector_offline -> Ansi.dim ^ "○ UNAVAILABLE" ^ Ansi.reset
            | Connector_stale -> (Theme.warn ()) ^ "● STALE" ^ Ansi.reset
          in
          let transport_rows =
            List.mapi
              (fun index (connector : Tui_decode.connector) ->
                 let here_count =
                   List.length
                     (List.filter
                        (fun (binding : Tui_decode.connector_binding) ->
                           String.equal binding.cb_keeper_name k.k_name)
                        connector.cn_bindings)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "▸ " else "  ")
                   ^ fit_width
                       (Terminal_text.single_line connector.cn_display_name)
                       14
                   ^ "  " ^ fit_width (connection_text connector) 12
                   ^ Printf.sprintf "  %d here / %d total" here_count
                       (List.length connector.cn_bindings)
                 in
                 if index = selected_index then Ansi.reverse ^ line ^ Ansi.reset
                 else line)
              connectors
          in
          let selected_lines =
            match List.nth_opt connectors selected_index with
            | None -> [ Ansi.dim ^ "  (no channel transports registered)" ^ Ansi.reset ]
            | Some connector ->
                let optional_row label value =
                  match value with
                  | None -> []
                  | Some value ->
                      [ Printf.sprintf "  %-18s %s" label
                          (Terminal_text.single_line value)
                      ]
                in
                let optional_bool_row label value =
                  optional_row label
                    (Option.map (fun present -> if present then "yes" else "no") value)
                in
                let optional_int_row label value =
                  optional_row label (Option.map string_of_int value)
                in
                let selected_binding =
                  List.nth_opt connector.cn_bindings state.connectors_binding_cursor
                in
                let keeper_is_present keeper_name =
                  List.exists
                    (fun (keeper : Tui_decode.keeper) ->
                       String.equal keeper.k_name keeper_name)
                    state.keepers
                in
                let binding_reference (binding : Tui_decode.connector_binding) =
                  match binding.cb_channel_name with
                  | None -> Terminal_text.single_line binding.cb_channel_id
                  | Some name ->
                      Printf.sprintf "%s (%s)"
                        (Terminal_text.single_line name)
                        (Terminal_text.single_line binding.cb_channel_id)
                in
                let runtime_state =
                  match connector.cn_gateway_state, connector.cn_poll_state with
                  | Some value, _ | None, Some value -> Some value
                  | None, None -> None
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some "readable"
                  | Some false -> Some "UNREADABLE"
                  | None -> None
                in
                let binding_lines =
                  List.mapi
                    (fun index (binding : Tui_decode.connector_binding) ->
                      let here = String.equal binding.cb_keeper_name k.k_name in
                      let selected = index = state.connectors_binding_cursor in
                      let missing_keeper =
                        not (keeper_is_present binding.cb_keeper_name)
                      in
                      let line =
                        Printf.sprintf "    %s %s → %s%s"
                          (if selected then "▸" else " ")
                          (binding_reference binding)
                          (Terminal_text.single_line binding.cb_keeper_name)
                          (if here then "  (this Keeper)"
                           else if missing_keeper then
                             "  (MISSING KEEPER · e reassign · u u remove)"
                           else "")
                      in
                      if selected then Ansi.reverse ^ line ^ Ansi.reset
                      else if missing_keeper then
                        (Theme.bad ()) ^ line ^ Ansi.reset
                      else line)
                    connector.cn_bindings
                  |> function
                  | [] -> [ Ansi.dim ^ "    (no channel bindings)" ^ Ansi.reset ]
                  | lines -> lines
                in
                [ ""
                ; Ansi.bold ^ "  Selected · "
                  ^ Terminal_text.single_line connector.cn_display_name
                  ^ Ansi.reset
                ; Printf.sprintf "  %-18s %s" "Binding target"
                    (match selected_binding with
                     | None -> "(no binding selected)"
                     | Some binding -> binding_reference binding)
                ; Printf.sprintf "  %-18s %s · %s" "Connection"
                    (connection_label connector)
                    (Terminal_text.single_line connector.cn_status)
                ; Printf.sprintf "  %-18s %s" "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                ; Printf.sprintf "  %-18s %s" "Channel type"
                    (Terminal_text.single_line_or ~default:"-" connector.cn_channel)
                ]
                @ optional_row "Runtime state" runtime_state
                @ optional_row "Status source" connector.cn_status_source
                @ optional_row "Remote endpoint" connector.cn_endpoint
                @ optional_row "Status file" connector.cn_status_path
                @ optional_row "Binding store" connector.cn_binding_store_path
                @ optional_row "Store state" store_state
                @ optional_row "Binding source" connector.cn_binding_source
                @ optional_row "Trigger policy" connector.cn_trigger_policy
                @ optional_row "Reply mode" connector.cn_reply_mode
                @ optional_row "Chat database" connector.cn_chat_db_path
                @ optional_row "Bot user" connector.cn_bot_user_name
                @ optional_row "Bot user id" connector.cn_bot_user_id
                @ optional_bool_row "Bot token ready" connector.cn_bot_token_present
                @ optional_bool_row "App token ready" connector.cn_app_token_present
                @ optional_bool_row "Gate healthy" connector.cn_gate_healthy
                @ optional_int_row "Server pid" connector.cn_pid
                @ optional_int_row "Guilds" connector.cn_guild_count
                @ optional_row "Directory state"
                    (Option.map
                       (function
                         | Tui_decode.Connector_directory_not_started ->
                           "not started"
                         | Connector_directory_refreshing -> "refreshing"
                         | Connector_directory_complete -> "complete"
                         | Connector_directory_partial -> "partial")
                       connector.cn_directory_state)
                @ optional_int_row "Servers learned"
                    connector.cn_directory_server_count
                @ optional_int_row "Channels learned"
                    connector.cn_directory_channel_count
                @ optional_int_row "People learned"
                    connector.cn_directory_person_count
                @ (match connector.cn_directory_authentication_failed with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Authentication"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     ])
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Permission limits"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     ])
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Directory errors"
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     ])
                @ optional_row "Directory updated"
                    connector.cn_directory_updated_at
                @ optional_row "Workspace id" connector.cn_workspace_id
                @ optional_row "Server names" connector.cn_server_names_path
                @ optional_row "Channel names" connector.cn_channel_names_path
                @ optional_row "People names" connector.cn_people_names_path
                @ optional_row "Mapping scope" connector.cn_name_mapping_scope
                @ optional_row "Names read error" connector.cn_names_error
                @ optional_row "Updated" connector.cn_updated_at
                @ optional_row "Connection error" connector.cn_error
                @ optional_row "Store error" connector.cn_binding_store_error
                @ [ ""; Ansi.bold ^ "  Channel → Keeper bindings" ^ Ansi.reset ]
                @ binding_lines
                @ (match connector.cn_name_mappings with
                   | [] -> []
                   | mappings ->
                       [ ""; Ansi.bold ^ "  Known ID ↔ names" ^ Ansi.reset ]
                       @ List.map
                           (fun (mapping : Tui_decode.connector_name_mapping) ->
                              Printf.sprintf "    %-7s %s ↔ %s"
                                (match mapping.cnm_kind with
                                 | Tui_decode.Connector_channel_name -> "channel"
                                 | Connector_person_name -> "person"
                                 | Connector_server_name -> "server")
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name))
                           mappings)
                @ [ ""
                  ; Ansi.dim
                    ^ "  j/k transport · J/K binding · b bind · e reassign · u u remove"
                    ^ Ansi.reset
                  ; Ansi.dim
                    ^ "  These actions change channel routing, not the connector process."
                    ^ Ansi.reset
                  ; Ansi.dim ^ "  PgUp/PgDn scrolls this detail" ^ Ansi.reset
                  ; Ansi.dim ^ "  r reloads bindings and learned names" ^ Ansi.reset
                  ]
          in
          [ Printf.sprintf "  %d transports · %d available · actions target %s"
              snapshot.cs_total snapshot.cs_active
              (Terminal_text.single_line k.k_name)
          ]
          @ (match error with
             | None -> []
             | Some detail ->
                 [ (Theme.bad ()) ^ "  refresh failed: "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ transport_rows @ selected_lines
    in
    let automation_lines =
      (* This tab reads the Keeper's own page from the server rather than
         filtering the fleet page: that page caps at its own limit with active
         rows first, so a Keeper whose schedules are terminal or further down
         was absent from it and the tab said none existed. The page it asks for
         can still truncate, which is why the absence reading stays. *)
      match state.keeper_schedules_error, state.keeper_schedules with
      | Some (keeper_name, err), _ when String.equal keeper_name k.k_name ->
          [ (Theme.bad ()) ^ "  schedules unavailable: "
            ^ Terminal_text.single_line err ^ Ansi.reset ]
      | _, Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
          let rows = snapshot.scs_rows in
          if not (String.equal snapshot.scs_status "ok") then
            [ (Theme.bad ())
              ^ (match snapshot.scs_read_error with
                 | Some err -> "  " ^ Terminal_text.single_line err
                 | None -> "  (schedule store unreadable)")
              ^ Ansi.reset ]
          else if rows = [] then
            match
              Render_schedule.classify_keeper_schedule_absence
                ~truncated:snapshot.scs_truncated
                ~shown:(List.length snapshot.scs_rows)
                ~total:snapshot.scs_request_count
            with
            | Render_schedule.Store_has_none ->
                [ Ansi.dim ^ "  (no schedules for this Keeper)" ^ Ansi.reset ]
            | Render_schedule.Page_capped { shown; total } ->
                let of_total =
                  match total with
                  | Some total -> Printf.sprintf " -- %d of %d requests" shown total
                  | None -> ""
                in
                [ Ansi.dim
                  ^ Printf.sprintf
                      "  (none on the page the server sent%s; open Schedules \
                       for the full list)"
                      of_total
                  ^ Ansi.reset
                ]
          else
            List.map
              (fun (row : schedule_row) ->
                 Printf.sprintf "  %-12s %-18s %s"
                   (Terminal_text.single_line row.sch_status)
                   (Terminal_text.single_line row.sch_recurrence_summary)
                   (Terminal_text.single_line
                      (Option.value ~default:row.sch_schedule_id row.sch_payload_summary)))
              rows
      | _, _ ->
          [ Ansi.dim ^ "  (loading this Keeper's schedules…)" ^ Ansi.reset ]
    in
    let run_lines =
      match state.fusion_runs with
      | None -> ["  Loading Fusion runs..."]
      | Some _ ->
          let runs = selected_keeper_runs state in
          "  Fusion runs · j/k:select · Enter:open · same IDs as Fusion" ::
          (if runs = [] then ["  No retained Fusion runs for this Keeper"]
           else List.mapi (fun index (run : Tui_decode.fusion_run) ->
             let tm = Unix.localtime run.fur_started_at in
             Printf.sprintf "%s %04d-%02d-%02d %02d:%02d · %s · %s · %s"
               (if Option.fold ~none:false ~some:(fun (cursor, _) -> index = cursor)
                     (selected_keeper_run state) then ">" else " ")
               (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
               tm.Unix.tm_hour tm.Unix.tm_min
               (Tui_decode.fusion_run_status_to_string run.fur_status)
               (Terminal_text.single_line run.fur_preset)
               (Terminal_text.single_line run.fur_run_id)) runs)
    in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines
      | Detail_sandbox ->
          let width = max 24 (cols - 8) in
          let status =
            stamped_or
              (Option.map
                 (fun (stamp, reading) ->
                   stamp, Masc_tui_keeper_sandbox.view_lines ~width reading)
                 state.keeper_sandbox_view)
              state.keeper_sandbox_view_error
          in
          let logs =
            match state.keeper_sandbox_logs_inflight with
            | Some (keeper_name, _) when String.equal keeper_name k.k_name ->
              [ Ansi.dim ^ "  (loading actual container logs…)" ^ Ansi.reset ]
            | Some _ | None ->
              match state.keeper_sandbox_logs_error with
              | Some (stamp, detail) when String.equal stamp k.k_name ->
                [ (Theme.bad ()) ^ "  Container logs unavailable: "
                  ^ Terminal_text.single_line detail ^ Ansi.reset
                ]
              | Some _ | None ->
                (match state.keeper_sandbox_logs with
                 | Some (stamp, logs) when String.equal stamp k.k_name ->
                   Masc_tui_keeper_sandbox.logs_view_lines ~width logs
                   |> List.map (fun line -> "  " ^ line)
                 | Some _ | None -> [])
          in
          status @ logs
      | Detail_instructions ->
          stamped_or state.keeper_config_view state.keeper_config_view_error
      | Detail_secrets -> secret_lines state k
      | Detail_github ->
          stamped_or state.github_identity_view
            state.github_identity_view_error
      | Detail_identity ->
          stamped_or
            (Option.map
               (fun (stamp, providers) ->
                 (stamp, identity_lines state k ~cols providers))
               state.identity_view)
            state.identity_view_error
      | Detail_channels -> channel_lines
      | Detail_automation -> automation_lines
      | Detail_runs -> run_lines
    in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title, with the tab walk on the same row so the chrome height the
       scroll math counts does not move. *)
    (* The tab you are on carries the mark the surface strip puts on the
       surface you are on. Bold and underline said it alone before, so the
       answer was gone from a monochrome terminal, from one that drops
       underline, and from every text capture -- a frame dump, a screenshot
       pasted into an issue, the keyboard-input fixtures. Info's own body
       opens with a section called "Identity", which is also the name of
       another tab, so a reader with no mark had a wrong guess waiting. *)
    let tabs =
      Masc_tui_types.keeper_detail_tabs
      |> List.map (fun tab ->
             let label = Masc_tui_types.keeper_detail_tab_label tab in
             if tab = state.detail_tab then
               Ansi.bold ^ Ansi.underline
               ^ Masc_tui_theme.Glyph.current_entry
               ^ label ^ Ansi.reset
             else Ansi.dim ^ label ^ Ansi.reset)
      |> String.concat "  "
    in
    let tab_hint = Masc_tui_keys.keeper_detail_tab_hint state.detail_tab in
    let title =
      Printf.sprintf " Keepers \xe2\x96\xb8 %s%s%s   %s   %s%s%s" Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset tabs Ansi.dim tab_hint Ansi.reset
    in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
    let base_height = max 0 (rows - framed_chrome_rows) in
    let content_height =
      if total_lines > base_height then max 0 (base_height - 1)
      else base_height
    in
    let visible_lines = min content_height total_lines in
    let scroll =
      Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
        ~content_height state.detail_scroll
      |> fun scroll ->
        if state.detail_tab = Detail_runs then
          Option.fold ~none:scroll
            ~some:(fun (cursor, _) ->
              Masc_tui_scroll.ensure_visible ~cursor:(cursor + 1)
                ~height:(max 1 content_height) scroll)
            (selected_keeper_run state)
        else scroll
    in
    let all_lines_window = Rows.of_list ~first:scroll ~height:visible_lines all_lines in

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (Option.value (Rows.at all_lines_window idx) ~default:"")
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* Scroll indicator *)
    if total_lines > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d]%s" Ansi.dim (scroll + 1) (total_lines - content_height + 1) Ansi.reset in
      box_line buf cols indicator
    end;

    (* Bottom border *)
    box_bottom buf cols;
    scroll


let render_keeper_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-detail" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let footer =
      keeper_action_hints state (Some (keeper_reading state k))
    in
    let footer =
      if keeper_roster_pane_shown state ~cols then "  h/l pane" ^ footer
      else footer
    in
    (* Cut to the terminal, the way every other footer is: [footer_line] takes
       [~max_cells] and this one never did. The row is about 150 cells wide
       across its fourteen hints, and the roster pane adds ten more in front,
       so on any ordinary terminal the tail went past the edge. Autowrap is off
       while a frame draws, so nothing moved -- the last hints were simply
       dropped by the terminal, silently, with the keys still working.
       [fit_width] counts cells rather than bytes and closes the style it cut
       through. *)
    let footer = Message_layout.fit_width footer (max 1 cols) in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll = keeper_detail_pane state k ~framed:false ~rows ~cols buf in
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
    else begin
      (* Wide terminals keep the roster in sight beside the detail. Both
         panes draw the same number of rows, so the zip below is a plain
         row-by-row join. *)
      let left_cols = keeper_roster_pane_cols in
      let right_cols = cols - left_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      keeper_roster_pane
        ~focused:(state.keeper_detail_focus = Left_pane)
        state ~rows ~cols:left_cols left_buf;
      let scroll =
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols right_buf
      in
      write_two_panes buf ~left_cols:left_cols ~left:left_buf
        ~right:right_buf;
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header =
      Printf.sprintf "%s  (%d entries)"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        total_entries
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* The names come from the same description as the readings, in the module
       that owns the widths. Written here, they were eight numbers away from
       the eight they named. *)
    box_line_styled buf cols ~style:(Theme.recede ())
      Observation_layout.plain_log_header;
    box_divider buf cols;

    (match state.log_error with
      | None -> ()
      | Some error ->
          let style =
            match error with
            | Metrics_tail.Storage_error _ -> (Theme.bad ())
            | Metrics_tail.Row_errors _ -> (Theme.warn ())
          in
          let diagnostic =
            Keeper_chat.terminal_safe_text
              (Metrics_tail.error_to_string error)
          in
          box_line_styled buf cols ~style
            ("  " ^ diagnostic);
          box_divider buf cols);

    (* Content area *)
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:state.log_error
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:total_entries ~content_height
        state.log_scroll
    in

    if total_entries = 0 then begin
      box_line_styled buf cols ~style:(Theme.recede ())
        ("  " ^ Metrics_tail.empty_message state.log_error);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      let visible =
        Metrics_tail.visible ~entries:state.log_entries ~content_height ~scroll
      in
      let drawn = ref 0 in
      List.iter
        (fun (e : Tui_decode.log_entry) ->
          incr drawn;
          let time_str = Terminal_text.clock_timestamp e.le_ts in
          let tool_names = Terminal_text.single_lines e.le_tools_used in
          let tools_str =
            if List.length tool_names > 0 then
              " "
              ^ String.concat ","
                  (List.filteri (fun i _ -> i < 2) tool_names)
            else ""
          in
          let terminal_entry =
            { e with
              le_work_kind =
                Terminal_text.optional_single_line e.le_work_kind
            }
          in
          let line =
            Observation_layout.plain_log_row ~time:time_str terminal_entry
            ^ tools_str
          in
          box_line buf cols line)
        visible;
      for _ = !drawn to content_height - 1 do
        box_empty buf cols
      done
    end;

    (* Scroll indicator: the same "rows X-Y of Z" shape the tool-call pane
       reads, so one glance answers both how far and how much is left -- a
       bare "scroll N" said the offset but not the distance either way. *)
    if total_entries > content_height then begin
      (* Counted back from the newest, because that is the direction the rows
         are drawn in: row 1 is the last thing that happened. A bare
         "rows 1-20 of 300" read as the start of the file. *)
      let indicator =
        Printf.sprintf "newest %d-%d of %d" (scroll + 1)
          (min total_entries (scroll + content_height))
          total_entries
      in
      box_line_styled buf cols ~style:(Theme.recede ()) indicator
    end;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints state.view));

    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

let system_log_level_mark : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> "\xc2\xb7"
  | System_info -> "\xe2\x80\xa2"
  | System_warn -> "!"
  | System_error -> "\xc3\x97"
  | System_level_unknown _ -> "?"

let system_log_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  match
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  with
  | [] -> [ style, prefix ^ "-" ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let system_log_detail_lines (state : state) ~seq ~width =
  let entry =
    Option.bind state.system_logs (fun snapshot ->
        List.find_opt
          (fun entry -> entry.Masc.Tui_decode.sl_seq = seq)
          snapshot.Masc.Tui_decode.sys_entries)
  in
  match entry with
  | None ->
      [ Theme.warn (),
        "  This log entry is no longer present in the retained page; reload or return to the list."
      ]
  | Some entry ->
      let level_style = system_log_level_style entry.sl_level in
      let keeper = Option.value ~default:"system" entry.sl_keeper in
      let turn = Option.map string_of_int entry.sl_turn |> Option.value ~default:"-" in
      let fields =
        system_log_detail_field ~width ~style:Ansi.dim "Sequence"
          (string_of_int entry.sl_seq)
        @ system_log_detail_field ~width ~style:Ansi.dim "Timestamp" entry.sl_ts
        @ system_log_detail_field ~width ~style:level_style "Level"
            (Masc.Tui_decode.system_log_level_label entry.sl_level |> String.trim)
        @ system_log_detail_field ~width ~style:Ansi.dim "Category"
            (system_log_category_text entry)
        @ system_log_detail_field ~width ~style:Ansi.dim "Source"
            (Masc.Tui_decode.system_log_source_label entry.sl_source)
        @ system_log_detail_field ~width ~style:Ansi.dim "Module" entry.sl_module
        @ system_log_detail_field ~width ~style:Ansi.dim "Keeper" keeper
        @ system_log_detail_field ~width ~style:Ansi.dim "Turn" turn
        @ system_log_detail_field ~width ~style:Ansi.reset "Message"
            entry.sl_message
      in
      let details =
        match entry.sl_details with
        | `Null -> [ Ansi.dim, "  Details: none" ]
        | json ->
            let source =
              "```json\n" ^ Yojson.Safe.pretty_to_string json ^ "\n```"
            in
            (Ansi.bold, "  Structured details")
            :: (document_markdown ~width source
                |> List.map (fun line -> Ansi.reset, "  " ^ line))
      in
      fields @ details

let render_system_log_detail (state : state) seq =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  seq %d  %s" (screen_title " MASC Log detail") seq
       (connection_badge state));
  box_divider buf cols;
  let lines = system_log_detail_lines state ~seq ~width:(max 1 (cols - 8)) in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.system_logs_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints System_logs));
  finish_surface state ~clamped:(System_log_detail_scroll scroll)
    ~surface_key:"system-log-detail" ~rows:terminal_rows ~cols buf

let render_system_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let entries = Masc_tui_types.visible_system_log_entries state in
  let total_entries = List.length entries in
  let loaded_entries =
    match state.system_logs with
    | None -> 0
    | Some snapshot -> List.length snapshot.sys_entries
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  (* The active filters ride in the header, so a page trimmed to twelve rows
     says why it is twelve rather than reading as a quiet ring. *)
  let filter_note =
    let level =
      match state.system_logs_min_level with
      | None -> "  level\xe2\x89\xa5DEBUG  verbose:on"
      | Some floor ->
          Printf.sprintf "  level\xe2\x89\xa5%s  verbose:off"
            (String.trim (Masc.Tui_decode.system_log_level_label floor))
    in
    let category =
      match state.system_logs_category with
      | None -> ""
      | Some category ->
          "  category:" ^ Terminal_text.single_line category
    in
    level ^ category
  in
  let header =
    match state.system_logs with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Activity  [1 Events | 2 Logs*]") (title_missing_reading ~error:state.system_logs_error) timestamp
          (connection_badge state)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        Printf.sprintf "%s (%d of %d, seq %d)%s  %s  %s"
          (screen_title " MASC Activity  [1 Events | 2 Logs*]")
          total_entries snapshot.sys_total snapshot.sys_latest_seq filter_note
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* The message takes what the named columns leave, asked of the columns. *)
  let message_width =
    Render_schedule.system_log_message_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.system_log_header_row ~message_width
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.system_logs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The scroll indicator is a real row whenever this page has more entries
     than fit. Reserving it unconditionally keeps the bottom border and footer
     from becoming the frame's overflow casualty. *)
  let chrome_rows = system_log_listing_chrome ~error:state.system_logs_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min state.system_logs_scroll max_scroll) in
  let entries_window = Rows.of_list ~first:scroll ~height:content_height entries in
  if total_entries = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.system_logs ~error:state.system_logs_error
      with
      | Page_failed -> "  (load failed; the count above is not a reading)"
      | Page_unread -> page_unread_note
      | Page_empty when loaded_entries > 0 ->
          "  (no entries match the current category filter)"
      | Page_empty -> "  (no entries)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at entries_window idx with
      | None -> box_empty buf cols
      | Some e ->
          let keeper =
            match e.sl_keeper with None -> "-" | Some name -> name
          in
          let category = system_log_category_text e in
          let level_style = system_log_level_style e.sl_level in
          (* Every cell is fitted to the width its header is drawn at; a long
             module name used to push every column right of it out of line. *)
          let line =
            "  "
            ^ Render_schedule.system_log_row ~message_width ~level_style
                ~styles:
                  { Render_schedule.slog_time_style = Ansi.dim
                  ; slog_module_style =
                      Masc_tui_theme.tone Masc_tui_theme.Accent
                  ; slog_keeper_style = Theme.keeper_origin ()
                  ; slog_category_style = Ansi.dim
                  }
                { Render_schedule.slog_time =
                    Terminal_text.clock_timestamp e.sl_ts
                ; slog_level =
                    system_log_level_mark e.sl_level ^ " "
                    ^ Masc.Tui_decode.system_log_level_label e.sl_level
                ; slog_module = Terminal_text.single_line e.sl_module
                ; slog_keeper = Terminal_text.single_line keeper
                ; slog_category = Terminal_text.single_line category
                ; slog_message = Terminal_text.single_line e.sl_message
                }
          in
          if idx = state.system_logs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if total_entries > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d entries, scroll %d]" total_entries scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"system-logs" ~rows:terminal_rows
      ~cols buf

(* What is waiting on a verdict.

   The columns answer the questions an operator opens this for: which task,
   who submitted it, and what would move it forward. Evidence counts rather
   than paths -- a row is a queue entry, and the paths belong to whoever opens
   the task. *)
let render_verification_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let requests =
    match state.verification with None -> [] | Some s -> s.Masc.Tui_decode.vs_requests
  in
  let shown = List.length requests in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.verification with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (planning_workspace_title state ~tab:Planning_task_review ~window:"")
          (title_missing_reading ~error:state.verification_error) timestamp (connection_badge state)
    | Some snapshot ->
        (* Both numbers, for the same reason the log surface shows both: "12"
           beside a list of 12 would read as "that is all of them". *)
        Printf.sprintf "%s  %s  %s"
          (planning_workspace_title state ~tab:Planning_task_review
             ~window:
               (Printf.sprintf " (%d of %d)" shown
                  snapshot.Masc.Tui_decode.vs_total))
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows. Sixteen was the fixed width and the longest
     submitter on the wire is thirty-seven, so every [keeper-*-agent] row
     pushed the two columns after it out of line with the rest. *)
  let submitter_width =
    List.fold_left
      (fun widest (r : Masc.Tui_decode.verification_request) ->
        max widest
          (Message_layout.display_width
             (Terminal_text.single_line r.Masc.Tui_decode.vr_submitted_by)))
      16 requests
    |> min 26
  in
  let col_hdr =
    Printf.sprintf "  %-14s %-*s %-9s %s" "Task" submitter_width
      "Submitted by" "Evidence" "What it asks for"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The same frame the other listings draw, and the same two rows for a load
     error -- written out here as its own 9-or-7 rather than asked for. A
     surface that re-types the count does not move when the frame does. *)
  let chrome_rows = listing_chrome ~error:state.verification_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.verification_scroll max_scroll) in
  let requests_window = Rows.of_list ~first:scroll ~height:content_height requests in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.verification
          ~error:state.verification_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (nothing waiting on a verdict)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at requests_window idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          (* Submitted against required. A request that owes three artifacts
             and has one is the row an operator acts on first, and the pair
             says that where a single count would not. *)
          let evidence =
            match r.vr_evidence_error with
            | Some _ -> "unreadable"
            | None ->
                Printf.sprintf "%d/%d"
                  (List.length r.vr_submitted_evidence)
                  (List.length r.vr_required_artifacts)
          in
          (* The task's own title. This column read [next_action] and fell
             back to [request_summary], and both are literals in the producer:
             [submit_request_spec] sets [request_summary = ""] and
             [next_action = ""] and writes them into the request. All 200
             rows on the wire carry both empty, so the column had a header and
             no content on every row that has ever been drawn.

             The title is in the same object, filled on all 200, decoded into
             [vr_task_title] already, and shown in the detail pane below --
             just not in the list. What a verification request asks for is
             that this task be verified, so the title is what it asks for. *)
          let asks = r.vr_task_title in
          let line =
            Printf.sprintf "  %-14s %s %-9s %s"
              (Terminal_text.single_line r.vr_task_id)
              (fit_width (Terminal_text.single_line r.vr_submitted_by)
                 submitter_width)
              evidence
              (Terminal_text.single_line asks)
          in
          let style =
            (* Evidence that cannot be read is the one row that cannot be
               judged as it stands, so it reads as a problem rather than as a
               queue entry. *)
            match r.vr_evidence_error with
            | Some _ -> (Theme.bad ())
            | None -> Ansi.reset
          in
          if idx = state.verification_cursor then box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d requests, scroll %d]" shown scroll);
  (* The arm and the server's last refusal sit under the list, the same rows
     the schedule cancel carries them on. *)
  (match state.verification_verdict_armed with
   | Some task_id ->
       (* No width padding on the id: padding to a reserved column pushes the
          "same key again" tail past the box on a narrow terminal, and the
          tail is the half that instructs. *)
       box_line buf cols
         ((Theme.warn ())
         ^ Printf.sprintf "  armed: approve %s -- same key again to send"
             (Terminal_text.single_line task_id)
         ^ Ansi.reset)
   | None -> ());
  (match state.verification_verdict_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

let verification_detail_lines ~width
    (request : Masc.Tui_decode.verification_request) =
  let field label value =
    ( Ansi.reset
    , Printf.sprintf "  %-15s %s" label (Terminal_text.single_line value) )
  in
  let wrapped_block label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body ~markdown:document_markdown
          ~max_cells:(max 1 (width - 4))
          ~sanitize:Keeper_chat.terminal_safe_text text
        |> List.map (fun line -> Ansi.reset, "    " ^ line))
  in
  let item_lines empty_label items =
    match items with
    | [] -> [ Ansi.dim, "    (" ^ empty_label ^ ")" ]
    | _ ->
        List.concat_map
          (fun item ->
             Message_layout.wrap_body ~max_cells:(max 1 (width - 6))
               ~sanitize:Keeper_chat.terminal_safe_text item
             |> List.mapi (fun index line ->
                    Ansi.reset, (if index = 0 then "    - " else "      ") ^ line))
          items
  in
  [ Ansi.bold, "  VERIFICATION REQUEST"
  ; field "Request" request.vr_request_id
  ; field "Task" request.vr_task_id
  ; field "Title" request.vr_task_title
  ; field "Submitted by" request.vr_submitted_by
  ; field "Created" request.vr_created_at
  ; Ansi.dim, ""
  ]
  (* [Kind], [What is being judged] and [What moves it forward] stood here.
     Their three fields were literals in the producer -- "normal", "" and "" --
     so the three rows read the same on every request this pane has ever
     drawn, two of them as "No X was recorded". The pane already tells a
     reader how to read the request from its artifacts and evidence, which is
     what those rows were pointing away from. *)
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  HOW TO READ THIS"
    ; ( Ansi.dim
      , "    Required artifacts say what must exist. Submitted evidence says what the verifier can inspect now." )
    ; Ansi.dim, ""
    ; Ansi.bold
    , Printf.sprintf "  REQUIRED ARTIFACTS (%d)"
        (List.length request.vr_required_artifacts)
    ]
  @ item_lines "none required" request.vr_required_artifacts
  @ [ Ansi.dim, ""
    ; Ansi.bold
    , Printf.sprintf "  SUBMITTED EVIDENCE (%d)"
        (List.length request.vr_submitted_evidence)
    ]
  @ item_lines "none submitted" request.vr_submitted_evidence
  @
  match request.vr_evidence_error with
  | None -> []
  | Some detail ->
      [ Ansi.dim, "" ]
      @ wrapped_block "Evidence projection error" detail

(* What the verifier can actually inspect: the operator evidence bundle,
   lazily fetched on detail entry. The snapshot above lists references; this
   carries artifact content prefixes (server-capped, truncation marked) and
   the typed reason when an artifact could not be read — the judge's actual
   input, drawn beside the verdict keys so approval is not blind. *)
let verification_evidence_lines (state : state) ~width task_id =
  let wrap ~prefix text =
    Message_layout.wrap_body ~max_cells:(max 1 (width - 6))
      ~sanitize:Keeper_chat.terminal_safe_text text
    |> List.mapi (fun index line ->
           Ansi.reset, (if index = 0 then prefix else "      ") ^ line)
  in
  let rows =
    match state.verification_evidence with
    | Some (id, result) when String.equal id task_id -> (
        match result with
        | Ok (Masc.Tui_decode.Evidence_items []) ->
            [ Ansi.dim, "    (no inspectable evidence)" ]
        | Ok (Masc.Tui_decode.Evidence_items items) ->
            List.concat_map
              (fun (item : Masc.Tui_decode.verification_evidence_item) ->
                match item with
                | Masc.Tui_decode.Ev_note note -> wrap ~prefix:"    - note: " note
                | Masc.Tui_decode.Ev_artifact
                    { ev_reference; ev_content; ev_bytes; ev_truncated } ->
                    (( Ansi.reset
                     , Printf.sprintf "    - artifact %s (%dB%s)"
                         (Terminal_text.single_line ev_reference) ev_bytes
                         (if ev_truncated then ", truncated" else "") )
                     :: wrap ~prefix:"      " ev_content)
                | Masc.Tui_decode.Ev_artifact_unreadable
                    { ev_u_reference; ev_u_reason } ->
                    wrap
                      ~prefix:"    - artifact unreadable: "
                      (Printf.sprintf "%s %s"
                         (Option.value ev_u_reference ~default:"(no reference)")
                         ev_u_reason))
              items
        | Ok (Masc.Tui_decode.Evidence_access_unavailable reason) ->
            wrap ~prefix:"    evidence unavailable: " reason
        | Error err -> wrap ~prefix:"    evidence load failed: " err)
    | _ -> [ Ansi.dim, "    loading..." ]
  in
  (Ansi.dim, "") :: (Ansi.bold, "  EVIDENCE CONTENT") :: rows

let verification_detail_pane (state : state) ~rows ~cols request buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s"
       (planning_workspace_title state ~tab:Planning_task_review ~window:""
        ^ " \xe2\x96\xb8 details")
       (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id));
  box_divider buf cols;
  let width = max 1 (framed_inner_width cols) in
  let lines =
    verification_detail_lines ~width request
    @ verification_evidence_lines state ~width request.Masc.Tui_decode.vr_task_id
  in
  let content_height = max 1 (rows - 6) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.verification_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The queue stays beside the request under review. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_verification_detail (state : state) request =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      verification_detail_pane state ~rows ~cols request buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.verification with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : Tui_decode.verification_request) -> row.Tui_decode.vr_task_id)
            snapshot.Tui_decode.vs_requests
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Task Review"
        ~focused:false ~labels ~selected:state.verification_cursor;
      let answer =
        verification_detail_pane state ~rows ~cols:(cols - left_cols) request
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf "%s  (%d/%d)"
            (Masc_tui_keys.footer_hints state.view) scroll max_scroll));
  finish_surface state
    ~clamped:(Verification_detail_scroll scroll)
    ~surface_key:"verification-detail" ~rows:terminal_rows ~cols buf

let render_verification (state : state) =
  match state.verification_detail_request_id, state.verification with
  | Some request_id, Some snapshot ->
      (match
         List.find_opt
           (fun request ->
              String.equal request.Masc.Tui_decode.vr_request_id request_id)
           snapshot.Masc.Tui_decode.vs_requests
       with
       | Some request -> render_verification_detail state request
       | None -> render_verification_list state)
  | Some _, None | None, _ -> render_verification_list state

(* What the harness decided, most recent first.

   A verdict reached by a fallback evaluator is not the verdict that was asked
   for, so the row says which evaluator answered and marks the ones that were
   not the intended one. Reading a column of "approve" without that would say
   the gate is working when it may only be degrading quietly. *)
(* What the judge has decided over its whole life. The pane drew the recent
   page and nothing else, so the line promising to say "where a fallback
   answered instead" was the one thing it could not answer: 1,983 of this
   workspace's 4,197 verdicts came from the fallback gate and the screen
   showed a page of eight.

   Rates are stated against what they were computed from. [labeled_count] is
   zero here, which makes the agreement rate and the false-positive and
   false-negative counts zero for want of ground truth rather than for want
   of disagreement -- drawn as "0.0" they would read as a judge that never
   errs. The pane says which of the two it is instead of printing the
   number. *)
let harness_ledger_lines ~cols snapshot =
  match snapshot with
  | None -> []
  | Some snapshot -> (
      match snapshot.Masc.Tui_decode.hs_calibration with
      | None -> []
      | Some calibration ->
          let open Masc.Tui_decode in
          if calibration.hcal_total <= 0 then []
          else
            let share count =
              100. *. float_of_int count /. float_of_int calibration.hcal_total
            in
            (* Banded over every gate, then cut to the four that fit. The
               tail is where the small ones are, so ranking only what is
               drawn would rank four leaders out of four. *)
            let gates =
              Magnitude.of_counts calibration.hcal_gates
              |> List.filteri (fun index _ -> index < 4)
              |> List.map (fun (gate, count, band) ->
                     Printf.sprintf "%s%s %d (%.0f%%)%s" (magnitude_tone band)
                       gate count (share count) Ansi.reset)
              |> String.concat "  \xc2\xb7  "
            in
            let remaining = max 0 (List.length calibration.hcal_gates - 4) in
            let gates =
              if remaining = 0 then gates
              else Printf.sprintf "%s  \xc2\xb7  +%d more" gates remaining
            in
            let evaluator =
              match snapshot.hs_overview with
              | None -> ""
              | Some overview ->
                  Printf.sprintf "  \xc2\xb7  evaluator %s"
                    (Terminal_text.single_line overview.hov_evaluator_status)
            in
            [ Printf.sprintf "  %sledger%s  %d ruled  \xc2\xb7  approve %d  \xc2\xb7  reject %d%s"
                Ansi.dim Ansi.reset calibration.hcal_total
                calibration.hcal_approve calibration.hcal_reject evaluator
            ; Printf.sprintf "  %sgate%s    %s" Ansi.dim Ansi.reset
                (fit_width gates (max 8 (cols - 12)))
            ; (if calibration.hcal_labeled > 0 then
                 Printf.sprintf "  %slabelled%s %d" Ansi.dim Ansi.reset
                   calibration.hcal_labeled
               else
                 Printf.sprintf
                   "  %slabelled%s none \xe2\x80\x94 agreement and the error counts have no ground truth"
                   Ansi.dim Ansi.reset)
            ])

let render_harness_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let verdicts =
    match state.harness with
    | None -> []
    | Some s -> s.Masc.Tui_decode.hs_verdicts
  in
  let shown = List.length verdicts in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let fallbacks =
    List.length
      (List.filter
         (fun (v : Masc.Tui_decode.harness_verdict) ->
           Option.is_some v.Masc.Tui_decode.hv_fallback_reason)
         verdicts)
  in
  let header =
    match state.harness with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (planning_workspace_title state ~tab:Planning_verdicts ~window:"")
          (title_missing_reading ~error:state.harness_error) timestamp (connection_badge state)
    | Some snapshot ->
        (* The page and the ledger, apart. This read "(8 verdicts)" while the
           server was reporting 4,197: the eight are the recent page, and
           every proportion below is computed over the rest. A page count
           worn as the total is the one number on this screen a reader would
           act on. *)
        let of_total =
          match snapshot.Masc.Tui_decode.hs_calibration with
          | Some calibration when calibration.Masc.Tui_decode.hcal_total > 0 ->
              Printf.sprintf " of %d"
                calibration.Masc.Tui_decode.hcal_total
          | Some _ | None -> ""
        in
        let by_fallback =
          if fallbacks > 0 then Printf.sprintf ", %d by fallback" fallbacks
          else ""
        in
        Printf.sprintf "%s  %s  %s"
          (planning_workspace_title state ~tab:Planning_verdicts
             ~window:
               (Printf.sprintf " (%d%s%s)" shown of_total by_fallback))
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* The tab name alone says nothing; the surface introduces itself. Said in
     terms of the queue next door, because that is the other half of it: Task
     Review is what is still waiting for a ruling and this is what was ruled,
     by whom, and where a fallback answered instead of the evaluator the Gate
     names. *)
  box_line_styled buf cols ~style:(Theme.recede ())
    "  Task Verdicts = automatic Gate rulings on Tasks; not Goal proof.";
  List.iter (box_line buf cols) (harness_ledger_lines ~cols state.harness);
  (* A ledger that quietly stopped is this screen's own failure mode: it once
     starved for a month while the judge kept running, and the stale rows
     read as a working gate. Say the age instead of letting old rows pass as
     current. *)
  let stale_note =
    match verdicts with
    | [] -> None
    | newest :: _ ->
        let age_days =
          (Unix.gettimeofday () -. newest.Masc.Tui_decode.hv_at) /. 86_400.
        in
        if age_days >= 2. then
          Some (Printf.sprintf "  last verdict %.0f days ago \xe2\x80\x94 the judge runs but nothing is being recorded" age_days)
        else None
  in
  (match stale_note with
   | None -> ()
   | Some note -> box_line_styled buf cols ~style:(Theme.warn ()) note);
  (* The reason takes the cells the named columns leave. *)
  let reason_width =
    Render_schedule.harness_reason_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr = "  " ^ Render_schedule.harness_header_row ~reason_width in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.harness_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows =
    (if Option.is_some state.harness_error then 9 else 7)
    + 1
    + (if Option.is_some stale_note then 1 else 0)
  in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.harness_scroll max_scroll) in
  let verdicts_window = Rows.of_list ~first:scroll ~height:content_height verdicts in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.harness ~error:state.harness_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no verdicts recorded)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at verdicts_window idx with
      | None -> box_empty buf cols
      | Some v ->
          let open Masc.Tui_decode in
          let evaluator =
            match v.hv_fallback_reason with
            | None -> v.hv_evaluator
            | Some reason ->
                Printf.sprintf "%s (fallback: %s)" v.hv_evaluator reason
          in
          let verdict = Terminal_text.single_line v.hv_verdict in
          (* A rejection arrives as "reject:<why>", and the why runs to a
             couple of hundred characters. Poured into the nine-column
             verdict cell it pushed Evaluator off the right edge, so the
             column that says who judged was readable on approvals and
             missing on exactly the rows an operator opens: the rejections.

             The ruling holds the cell; the reason follows the evaluator and
             takes what width is left. The detail pane wraps it whole. *)
          let ruling, reason =
            match String.index_opt verdict ':' with
            | None -> verdict, ""
            | Some at ->
                ( String.sub verdict 0 at
                , String.trim
                    (String.sub verdict (at + 1)
                       (String.length verdict - at - 1)) )
          in
            let line =
              "  "
              ^ Render_schedule.harness_row
                  ~verdict_style:(semantic_status_color ruling) ~reason_width
                  { Render_schedule.hrow_time =
                    Terminal_text.clock_timestamp
                      (Masc_domain.iso8601_of_unix_seconds v.hv_at)
                ; hrow_task = Terminal_text.single_line v.hv_task_id
                ; hrow_gate = Terminal_text.single_line v.hv_gate
                ; hrow_verdict = ruling
                ; hrow_evaluator = Terminal_text.single_line evaluator
                ; hrow_reason = reason
                }
          in
          let style =
            match v.hv_fallback_reason with
            | Some _ -> (Theme.warn ())
            | None -> Ansi.reset
          in
          if idx = state.harness_cursor then box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d verdicts, scroll %d]" shown scroll);
  box_bottom buf cols;
  let link_hint =
    match List.nth_opt verdicts state.harness_cursor with
    | None -> ""
    | Some verdict ->
        "  selected:"
        ^ Link.reference Task
            (Terminal_text.single_line verdict.Masc.Tui_decode.hv_task_id)
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view ^ link_hint));
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

(* Which goals the judged task serves, and what those goals are aiming at.
   The verdict names a task, the task names its goals, and a goal carries the
   metric it is measured by -- three hops that were all present and never
   walked, so a verdict said "pass" without saying what it was passing
   towards. *)
let harness_goal_lines (state : state) (verdict : Masc.Tui_decode.harness_verdict) =
  let goal_ids =
    match
      List.find_opt
        (fun (row : Tui_decode.task) -> String.equal row.id verdict.hv_task_id)
        state.tasks
    with
    | Some row -> row.goal_ids
    | None -> []
  in
  let goal_of id =
    Option.bind state.planning (fun snapshot ->
      List.find_opt
        (fun (goal : Tui_decode.planning_goal) -> String.equal goal.pg_id id)
        snapshot.Tui_decode.pl_goals)
  in
  match goal_ids with
  | [] ->
    (* Two different silences, told apart. A task this screen has never seen
       (the backlog has not loaded, or the verdict judged something already
       archived) is not the same as a task that serves no goal, and drawing
       nothing for both leaves the reader unable to tell which. *)
    let known_task =
      List.exists
        (fun (row : Tui_decode.task) -> String.equal row.id verdict.hv_task_id)
        state.tasks
    in
    if known_task then
      [ Ansi.dim, "  Towards      this task is not linked to a goal" ]
    else
      [ Ansi.dim, "  Towards      the judged task is not in this backlog" ]
  | goal_ids ->
    (Ansi.bold, "  TOWARDS")
    :: List.concat_map
         (fun id ->
           match goal_of id with
           | None ->
             (* Linked to a goal this snapshot does not carry -- terminal, or
                simply not in the page that was fetched. Named rather than
                dropped: the link is a fact even when the goal is not here. *)
             [ Ansi.reset, Printf.sprintf "  %-12s %s" "Goal" id
             ; Ansi.dim, Printf.sprintf "  %-12s %s" "" (Link.reference Goal id)
             ]
           | Some goal ->
             let aim =
               match goal.pg_metric, goal.pg_target_value with
               | Some metric, Some target -> Printf.sprintf "%s -> %s" metric target
               | Some metric, None -> metric
               | None, Some target -> Printf.sprintf "target %s" target
               | None, None -> "no metric declared"
             in
             [ Ansi.reset,
               Printf.sprintf "  %-12s %s" "Goal"
                 (Terminal_text.single_line goal.pg_title)
             ; Ansi.reset, Printf.sprintf "  %-12s %s" "Aim" aim
             ; Ansi.dim, Printf.sprintf "  %-12s %s" "" (Link.reference Goal id)
             ])
         goal_ids
;;

let harness_detail_lines ~width (verdict : Masc.Tui_decode.harness_verdict) =
  let field ?(style = Ansi.reset) label value =
    style,
    Printf.sprintf "  %-12s %s" label (Terminal_text.single_line value)
  in
  let wrapped label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body ~markdown:document_markdown
          ~max_cells:(max 1 (width - 6))
          ~sanitize:Keeper_chat.terminal_safe_text text
        |> List.map (fun line -> Ansi.reset, "    " ^ line))
  in
  let fallback =
    match verdict.hv_fallback_reason with
    | None -> [ Ansi.dim, "  Fallback     none; the named evaluator answered" ]
    | Some reason ->
        [ (Theme.warn ()), "  FALLBACK EVALUATION" ]
        @ wrapped "Why the requested evaluator did not run" reason
  in
  let ruling, reason =
    let whole = verdict.hv_verdict in
    match String.index_opt whole ':' with
    | None -> Terminal_text.single_line whole, ""
    | Some at ->
        ( Terminal_text.single_line (String.sub whole 0 at)
        , String.trim
            (String.sub whole (at + 1) (String.length whole - at - 1)) )
  in
  [ Ansi.bold, "  EVALUATOR VERDICT"
  ; field "Task link" (Link.reference Task verdict.hv_task_id)
  ; field "Task" verdict.hv_task_id
  ]
  @ wrapped "Title" verdict.hv_task_title
  @ [ field "Agent" verdict.hv_agent
    ; Ansi.dim, ""
    ; Ansi.bold, "  DECISION"
    ; field ~style:(semantic_status_color ruling) "Verdict" ruling
    ; field "Gate" verdict.hv_gate
    ; field "Evaluator" verdict.hv_evaluator
    ; field "Recorded"
        (Masc_domain.iso8601_of_unix_seconds verdict.hv_at)
    ]
  (* The reason a task was rejected or approved is the sentence the operator came
     here to read, and it runs long. [field] is one [single_line], so it was cut at
     the pane's width and the rest existed nowhere on the surface. The title
     above already wraps for the same reason. *)
  @ (if reason = "" then [] else wrapped "Reason" reason)
  @ [ Ansi.dim, "" ]
  @ fallback

let harness_detail_pane (state : state) ~rows ~cols verdict buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (planning_workspace_title state ~tab:Planning_verdicts ~window:""
        ^ " \xe2\x96\xb8 verdict")
       (Terminal_text.single_line verdict.Masc.Tui_decode.hv_task_id)
       (connection_badge state));
  box_divider buf cols;
  let lines =
    harness_detail_lines ~width:(max 1 (framed_inner_width cols)) verdict
    (* Appended rather than woven in: the verdict block is what the server
       said, and what the task is aiming at is read from two other surfaces.
       Keeping them in that order keeps the judged fact above the context. *)
    @ (match harness_goal_lines state verdict with
       | [] -> []
       | goal_lines -> (Ansi.dim, "") :: goal_lines)
  in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.harness_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The verdict list stays beside the verdict. A verdict is a judgement
   about one task among many, and which ones came out the same way is
   most of what it means. Below the split width the detail keeps the
   screen. *)
let render_harness_detail (state : state) verdict =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      harness_detail_pane state ~rows ~cols verdict buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.harness with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : Tui_decode.harness_verdict) -> row.Tui_decode.hv_task_id)
            snapshot.Tui_decode.hs_verdicts
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Verdicts"
        ~focused:false ~labels ~selected:state.harness_cursor;
      let answer =
        harness_detail_pane state ~rows ~cols:(cols - left_cols) verdict
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf
            "j/k:scroll (%d/%d)  PgUp/PgDn:page  left/Esc:list  Y:copy task  r:refresh"
            scroll max_scroll));
  finish_surface state ~clamped:(Harness_detail_scroll scroll)
    ~surface_key:"harness-detail" ~rows:terminal_rows ~cols buf

let render_harness (state : state) =
  match state.harness_detail, state.harness with
  | Some (task_id, at), Some snapshot ->
      (match
         List.find_opt
           (fun verdict ->
              String.equal verdict.Masc.Tui_decode.hv_task_id task_id
              && Float.equal verdict.hv_at at)
           snapshot.Masc.Tui_decode.hs_verdicts
       with
       | Some verdict -> render_harness_detail state verdict
       | None -> render_harness_list state)
  | Some _, None | None, _ -> render_harness_list state

let fusion_run_stage_compact = function
  | Fusion_stage_accepted -> "accepted"
  | Fusion_stage_panel { frs_expected } ->
      Printf.sprintf "panel(%d)" frs_expected
  | Fusion_stage_judge { frs_answered; frs_failed; _ } ->
      Printf.sprintf "judge(%d/%d)" frs_answered frs_failed
  | Fusion_stage_computed { frs_answered; frs_failed; _ } ->
      Printf.sprintf "computed(%d/%d)" frs_answered frs_failed
  | Fusion_stage_recording_evidence { frs_answered; frs_failed; _ } ->
      Printf.sprintf "recording(%d/%d)" frs_answered frs_failed
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"

let fusion_run_summary run =
  let flow = "Flow: Question \xe2\x86\x92 Panel \xe2\x86\x92 Judge \xe2\x86\x92 Evidence" in
  match run.fur_status with
  | Fusion_running ->
      ((Masc_tui_theme.tone Masc_tui_theme.Accent), flow ^ " \xc2\xb7 " ^ fusion_run_progress_text run.fur_stage)
  | Fusion_completed ->
      (match run.fur_decision, run.fur_summary with
       | Some decision, Some summary ->
           ( (Theme.ok ())
           , Terminal_text.single_line decision ^ " \xc2\xb7 "
             ^ Terminal_text.single_line summary )
       | (Some _ | None), (Some _ | None) ->
           ( (Theme.ok ())
           , flow ^ " \xc2\xb7 evidence retained; Enter opens panel and judge" ))
  | Fusion_failed failure ->
      ( (Theme.bad ())
      , Printf.sprintf "%s \xc2\xb7 failed [%s]: %s" flow
          (Terminal_text.single_line failure.frs_failure_code)
          (Terminal_text.single_line failure.frs_error) )

let fusion_replay_warning = function
  | Tui_decode.Fusion_not_replayed | Tui_decode.Fusion_log_absent -> None
  | Tui_decode.Fusion_replayed { malformed_lines = 0; dropped_running = 0;
                                incomplete = false } -> None
  | Tui_decode.Fusion_replayed { malformed_lines; dropped_running; incomplete } ->
      Some (Printf.sprintf
        "Registry startup read: %d invalid rows; %d registrations omitted%s"
        malformed_lines dropped_running (if incomplete then "; read incomplete" else ""))

let render_fusion_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.fusion_runs with
    | None -> []
    | Some snapshot -> snapshot.fus_runs
  in
  let entries = fusion_list_entries state in
  let shown = List.length entries in
  let history_count = shown - List.length runs in
  let replay_warning = Option.bind state.fusion_runs
      (fun snapshot -> fusion_replay_warning snapshot.fus_replay) in
  let now_epoch = Unix.gettimeofday () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.fusion_runs with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Fusion") (title_missing_reading ~error:state.fusion_error) timestamp
          (connection_badge state)
    | Some _ ->
        let completed_count =
          List.fold_left
            (fun acc (r : Tui_decode.fusion_run) ->
               if r.fur_status = Tui_decode.Fusion_completed then acc + 1 else acc)
            0 runs
        in
        let failed_count =
          List.fold_left
            (fun acc (r : Tui_decode.fusion_run) ->
               match r.fur_status with Tui_decode.Fusion_failed _ -> acc + 1 | _ -> acc)
            0 runs
        in
        let running_count = Stdlib.max 0 (List.length runs - completed_count - failed_count) in
        let stats_note =
          Printf.sprintf " (%d runs · %s%d done%s · %s%d run%s%s)"
            (List.length runs)
            (Theme.ok ()) completed_count Ansi.reset
            (Theme.info ()) running_count Ansi.reset
            (if failed_count > 0 then Printf.sprintf " · %s%d fail%s" (Theme.bad ()) failed_count Ansi.reset else "")
        in
        Printf.sprintf "%s%s  %s  %s"
          (screen_title " MASC Fusion")
          (stats_note ^ (if history_count = 0 then "" else
             Printf.sprintf " · %d Board evidence" history_count)) timestamp
          (connection_badge state)
  in
  (* Measured from the rows, the way the Approvals table measures its own
     name column. Eighteen of twenty-eight keepers were cut at sixteen while
     RUN, a [kmsg-] and thirty-two hex digits nobody reads off a screen, sat
     whole beside them -- and the detail pane already carries that id in full
     under Link. RUN is last, so what it loses is the end of an identifier the
     pane below repeats. *)
  let keeper_width =
    List.fold_left
      (fun widest (run : Tui_decode.fusion_run) ->
        max widest
          (Message_layout.display_width
             (Terminal_text.single_line run.fur_keeper)))
      16 runs
    |> min 26
  in
  (* The run id takes what the named columns leave, once the keeper column has
     been sized to the names it actually holds. *)
  let columns =
    Render_schedule.allocate_fusion_columns ~keeper_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Render_schedule.fusion_header_row columns);
  box_divider buf cols;
  (match state.fusion_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  Option.iter (fun warning ->
      box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ warning);
      box_divider buf cols) replay_warning;
  let chrome_rows = listing_chrome ~error:state.fusion_error
      + (if Option.is_some replay_warning then 2 else 0) in
  (* The selected run's lifecycle is a reading, not footer help. Reserve one
     row for it so every run says where it is in the four-stage flow. *)
  let content_height = max 1 (rows - chrome_rows - 1) in
  let scroll =
    if state.fusion_cursor >= content_height then
      state.fusion_cursor - content_height + 1
    else 0
  in
  let entries_window = Rows.of_list ~first:scroll ~height:content_height entries in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.fusion_runs ~error:state.fusion_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty ->
          if Option.is_some replay_warning then "  No readable retained runs; see startup read warning above"
          else "  (no retained Fusion runs)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      let row_index = index + scroll in
      match Rows.at entries_window row_index with
      | None -> box_empty buf cols
      | Some (Tui_decode.Fusion_historical_evidence evidence) ->
          let line = "Board evidence · " ^ Terminal_text.single_line evidence.fhe_title
              ^ " · " ^ Link.reference Board_post evidence.fhe_post_id in
          let marker = if row_index = state.fusion_cursor then
              Ansi.reverse ^ ">" ^ Ansi.reset else " " in
          box_line buf cols (marker ^ " " ^ line)
      | Some (Tui_decode.Fusion_retained_run run) ->
          let status = fusion_run_status_to_string run.fur_status in
          let state_text =
            match run.fur_status with
            | Fusion_running -> fusion_run_stage_compact run.fur_stage
            | Fusion_completed | Fusion_failed _ -> status
          in
          let line =
            Render_schedule.fusion_row columns
              ~state_style:(fusion_run_status_color run.fur_status)
              { Render_schedule.frow_time = fusion_run_clock run
              ; frow_age = fusion_run_age ~now:now_epoch run
              ; frow_state = state_text
              ; frow_keeper = Terminal_text.single_line run.fur_keeper
              ; frow_preset = Terminal_text.single_line run.fur_preset
              ; frow_run = Terminal_text.single_line run.fur_run_id
              }
          in
          if row_index = state.fusion_cursor then
            box_line buf cols (Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line)
          else box_line buf cols ("  " ^ line)
    done;
  (match List.nth_opt entries state.fusion_cursor with
   | None -> box_empty buf cols
   | Some (Tui_decode.Fusion_historical_evidence _) ->
       box_line_styled buf cols ~style:(Theme.warn ())
         "  Historical Board evidence; run lifecycle unavailable · Enter:read original result"
   | Some (Tui_decode.Fusion_retained_run selected) ->
       let style, summary = fusion_run_summary selected in
       box_line_styled buf cols ~style ("  " ^ fusion_run_duration ~now:now_epoch selected ^ " · " ^ summary));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints Fusion));
  finish_surface state ~surface_key:"fusion-list" ~rows:terminal_rows ~cols buf

(* The panel as marks, one per model, filled where the model answered.

   Which preset ran and whether the panel that fed the judge was whole is the
   first thing an operator reads off a run, and the pane said it in a sentence
   of counts -- "judge-of-judges  first x3  meta x1" -- with the failures
   counted somewhere else entirely. A model that did not answer is a hole in
   the row here, so a thin panel is seen before it is read.

   Past the cap the row would stop being countable at a glance, so it becomes
   the two numbers it was drawn from. *)
let fusion_panel_dots ~answered ~failed =
  let cap = 24 in
  let filled = "\xe2\x97\x8f" in
  let hollow = "\xe2\x97\x8b" in
  let run style mark n =
    if n <= 0 then ""
    else style ^ String.concat "" (List.init n (fun _ -> mark)) ^ Ansi.reset
  in
  match answered + failed with
  | 0 -> ""
  | total when total > cap ->
    Printf.sprintf "%s%d\xc3\x97%s%s  %s%d\xc3\x97%s%s"
      (Theme.ok ()) answered filled Ansi.reset
      (Theme.bad ()) failed hollow Ansi.reset
  | _ -> run (Theme.ok ()) filled answered ^ run (Theme.bad ()) hollow failed
;;

let fusion_wrapped_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  String.split_on_char '\n' text
  |> List.concat_map (fun raw ->
         let safe = Terminal_text.single_line raw in
         if String.equal safe "" then [ indent ^ "(empty)" ]
         else
           Message_layout.wrap_words ~max_cells:body_width safe
           |> List.map (fun line -> indent ^ line))
  |> List.map (fun line -> Ansi.reset, line)

let fusion_markdown_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  if String.equal (String.trim text) "" then [ Ansi.dim, indent ^ "(empty)" ]
  else
    document_markdown ~width:body_width text
    |> List.map (fun line -> Ansi.reset, indent ^ line)

let fusion_labeled_markdown ~width ~label text =
  (Ansi.bold, "  " ^ label)
  :: fusion_markdown_block ~width ~indent:"    " text

let fusion_tool_actor_text actor =
  match actor.fta_phase with
  | Fusion_tool_panel -> "panel/" ^ Terminal_text.single_line actor.fta_identity
  | Fusion_tool_judge role ->
      Printf.sprintf "judge/%s/%s" (fusion_judge_role_label role)
        (Terminal_text.single_line actor.fta_identity)

let fusion_tool_agent_suffix actor agent_name =
  if String.equal actor.fta_identity agent_name
  then ""
  else "  agent=" ^ Terminal_text.single_line agent_name

let fusion_tool_preview_lines ~width ~label preview =
  let size =
    if preview.ftp_truncated
    then Printf.sprintf "%d bytes; preview truncated" preview.ftp_bytes
    else Printf.sprintf "%d bytes" preview.ftp_bytes
  in
  let payload_text =
    if preview.ftp_truncated
    then preview.ftp_text
    else
      try
        preview.ftp_text
        |> Yojson.Safe.from_string
        |> Yojson.Safe.pretty_to_string
      with
      | Yojson.Json_error _ -> preview.ftp_text
  in
  let trimmed = String.trim payload_text in
  let body =
    if String.starts_with ~prefix:"{" trimmed
       || String.starts_with ~prefix:"[" trimmed
    then "```json\n" ^ payload_text ^ "\n```"
    else payload_text
  in
  [ Ansi.dim, Printf.sprintf "    %s (%s)" label size ]
  @ fusion_markdown_block ~width ~indent:"      " body

let fusion_tool_event_lines ~width = function
  | Fusion_tool_called event ->
      [ ( (Masc_tui_theme.tone Masc_tui_theme.Accent)
        , Printf.sprintf "  [called] %s%s  %s  turn %d/%d  id=%s"
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id) )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Input" event.fte_input
  | Fusion_tool_completed event ->
      let status, style, output, failure_suffix =
        match event.fte_completion with
        | Fusion_tool_succeeded output -> ("succeeded", Theme.ok (), output, "")
        | Fusion_tool_failed { ftc_output; ftc_recoverable; ftc_error_class }
          ->
          ( "failed"
          , Theme.bad ()
          , ftc_output
          , Printf.sprintf "  recoverable=%b%s" ftc_recoverable
              (match ftc_error_class with
               | Some class_ -> " class=" ^ Terminal_text.single_line class_
               | None -> " class=unavailable") )
      in
      [ ( style
        , Printf.sprintf "  [%s] %s%s  %s  turn %d/%d  id=%s%s" status
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id)
            failure_suffix )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Output" output

let fusion_tool_trace_lines ~width (trace : Tui_decode.fusion_tool_trace) =
      let coverage =
        if trace.ftt_complete
        then
          ( Theme.ok ()
          , Printf.sprintf "  Coverage: complete across %d AGENT_CORE actor(s)"
              (List.length trace.ftt_observed_actors) )
        else
          ( Theme.warn ()
          , Printf.sprintf
              "  Coverage: partial across %d actor(s) (%d dropped event(s), %d gap(s))"
              (List.length trace.ftt_observed_actors)
              trace.ftt_dropped_events (List.length trace.ftt_gaps) )
      in
      let observed =
        match trace.ftt_observed_actors with
        | [] -> [ Ansi.dim, "  Observed actors: (none)" ]
        | actors ->
            fusion_wrapped_block ~width ~indent:"  "
              ("Observed actors: "
               ^ String.concat ", " (List.map fusion_tool_actor_text actors))
      in
      let gaps =
        List.map
          (fun gap ->
             ( Theme.warn ()
             , Printf.sprintf "  Gap: %s [%s]"
                 (fusion_tool_actor_text gap.ftg_actor)
                 (Terminal_text.single_line gap.ftg_reason) ))
          trace.ftt_gaps
      in
      let events =
        match trace.ftt_events with
        | [] when trace.ftt_complete ->
            [ Ansi.dim, "  No Tool calls were observed for instrumented actors" ]
        | [] -> [ Ansi.dim, "  No Tool events retained in this partial ledger" ]
        | events ->
            events
            |> List.concat_map (fun event ->
                   (Ansi.dim, "") :: fusion_tool_event_lines ~width event)
      in
      (coverage :: observed) @ gaps @ events

let fusion_pipeline_diagram (run : Tui_decode.fusion_run) =
  let glyph_done = (Theme.ok ()) ^ "\xe2\x97\x8f" ^ Ansi.reset in
  let glyph_active = (Theme.warn ()) ^ "\xe2\x97\x90" ^ Ansi.reset in
  let glyph_waiting = Ansi.dim ^ "\xe2\x97\x8b" ^ Ansi.reset in
  let glyph_failed = (Theme.bad ()) ^ "\xc3\x97" ^ Ansi.reset in
  let arrow = " " ^ (Theme.recede ()) ^ "\xe2\x96\xb8" ^ Ansi.reset ^ " " in
  let status =
    match run.fur_status with
    | Fusion_completed -> `Completed
    | Fusion_running -> `Running
    | Fusion_failed _ -> `Failed
  in
  let stage, panel_answered, panel_expected =
    match run.fur_stage with
    | Fusion_stage_accepted -> `Accepted, 0, 0
    | Fusion_stage_panel { frs_expected } -> `Panel, 0, frs_expected
    | Fusion_stage_judge { frs_expected; frs_answered; _ } -> `Judge, frs_answered, frs_expected
    | Fusion_stage_computed { frs_answered; frs_expected; _ }
    | Fusion_stage_recording_evidence { frs_answered; frs_expected; _ } -> `Evidence, frs_answered, frs_expected
    | Fusion_stage_completed -> `Completed, 0, 0
    | Fusion_stage_failed -> `Failed, 0, 0
  in
  Render_schedule.fusion_pipeline_diagram
    ~glyph_done ~glyph_active ~glyph_waiting ~glyph_failed ~arrow
    ~status ~stage ~panel_answered ~panel_expected ()

let fusion_evidence_lines ~width (evidence : fusion_evidence) =
  let answered, failed, input_tokens, output_tokens =
    List.fold_left
      (fun (answered, failed, input_tokens, output_tokens) result ->
        match result with
        | Fusion_panel_answered answer ->
            ( answered + 1
            , failed
            , input_tokens + answer.fpa_input_tokens
            , output_tokens + answer.fpa_output_tokens )
        | Fusion_panel_failed _ ->
            answered, failed + 1, input_tokens, output_tokens)
      (0, 0, 0, 0) evidence.fe_panel
  in
  let panel_lines =
    evidence.fe_panel
    |> List.mapi (fun index result ->
           match result with
           | Fusion_panel_answered answer ->
               [ ( (Theme.ok ())
                 , Printf.sprintf
                     "  Panel %d [answered] %s  (%d in / %d out)"
                     (index + 1)
                     (Terminal_text.single_line answer.fpa_model)
                     answer.fpa_input_tokens answer.fpa_output_tokens )
               ]
               @ fusion_markdown_block ~width ~indent:"    "
                   answer.fpa_answer
           | Fusion_panel_failed failure ->
               [ ( (Theme.bad ())
                 , Printf.sprintf "  Panel %d [failed] %s  [%s]"
                     (index + 1)
                     (Terminal_text.single_line failure.fpf_model)
                     (Terminal_text.single_line failure.fpf_reason_code) )
               ; Ansi.dim, "    Token usage: not recorded"
               ]
               @ fusion_wrapped_block ~width ~indent:"    "
                   failure.fpf_reason_detail)
    |> List.concat
  in
  let panel_token_items =
    List.filter_map
      (function
        | Fusion_panel_answered answer ->
            Some
              { Chart.name = Terminal_text.single_line answer.fpa_model
              ; count = answer.fpa_input_tokens + answer.fpa_output_tokens
              ; style = Some (Chart.Status Masc_tui_theme.Ok)
              }
        | Fusion_panel_failed _ -> None)
      evidence.fe_panel
  in
  let panel_chart_lines =
    if List.length panel_token_items >= 2 then
      ( Ansi.dim
      , if failed = 0 then "  Model token distribution:"
        else Printf.sprintf "  Model token distribution (measured %d/%d panels):"
            answered (answered + failed) )
      :: List.map (fun row -> (Ansi.reset, row)) (Chart.distribution_bars ~width panel_token_items)
      @ [ Ansi.dim, "" ]
    else []
  in
  let judge_lines =
    match evidence.fe_judge with
    | Fusion_judge_synthesized judge ->
        [ ( (Theme.info ())
          , "  Judge [synthesized] "
            ^ Terminal_text.single_line judge.fj_decision )
        ]
        @ fusion_labeled_markdown ~width ~label:"Resolved"
            judge.fj_resolved_answer
        @ fusion_labeled_markdown ~width ~label:"Reason" judge.fj_reason
    | Fusion_judge_failed failure ->
        [ ( (Theme.bad ())
          , "  Judge [failed] ["
            ^ Terminal_text.single_line failure.fj_failure_code
            ^ "]" )
        ]
        @ fusion_wrapped_block ~width ~indent:"    " failure.fj_error
  in
  (* RFC-0284 judge nodes. The canonical [Judge] row above is the final
     synthesis; this block is the topology it came through -- first the
     observed shape as one line, then one card per first-pass lens.
     Meta/stage/final nodes stay in the shape line only: their output
     is intermediate synthesis, and printing it next to the final one
     would render the same deliberation twice. Pre-RFC posts decode
     with no nodes and draw none of this. *)
  let judges_lines =
    match evidence.fe_judges with
    | [] -> []
    | nodes ->
        let count_role wanted =
          List.fold_left
            (fun n node ->
              if node.fjn_role = wanted then n + 1 else n)
            0 nodes
        in
        let firsts = count_role Judge_first in
        let metas = count_role Judge_meta in
        let stage_metas = count_role Judge_stage_meta in
        let final_metas = count_role Judge_final_meta in
        let refines = count_role Judge_refine in
        let singles = count_role Judge_single in
        let shape =
          (* Same reading the dashboard's shape classifier makes: a
             first-pass judge only exists in a judge-of-judges run,
             and stage/final metas only in the staged one. *)
          if stage_metas > 0 || final_metas > 0 then "staged judge-of-judges"
          else if firsts > 0 then "judge-of-judges"
          else if refines > 0 then "refine"
          else "single"
        in
        let counts =
          List.filter_map
            (fun (label, n) ->
              if n > 0 then Some (Printf.sprintf "%s \xc3\x97%d" label n) else None)
            [ ("first", firsts); ("meta", metas); ("stage-meta", stage_metas)
            ; ("final-meta", final_metas); ("refine", refines)
            ; ("single", singles) ]
        in
        let first_cards =
          nodes
          |> List.filter (fun node -> node.fjn_role = Judge_first)
          |> List.mapi (fun index node ->
                 match node.fjn_outcome with
                 | Judge_node_synthesized synthesized ->
                     [ ( (Theme.info ())
                       , Printf.sprintf
                           "  First %d [synthesized] %s  (%d in / %d out)"
                           (index + 1)
                           (Terminal_text.single_line node.fjn_identity)
                           synthesized.fjno_input_tokens
                           synthesized.fjno_output_tokens )
                     ]
                     @ fusion_labeled_markdown ~width
                         ~label:
                           (Printf.sprintf "First %d %s" (index + 1)
                              (Terminal_text.single_line node.fjn_identity))
                         synthesized.fjno_resolved_answer
                 | Judge_node_failed failed ->
                     let clock =
                       match (failed.fjno_timed_out, failed.fjno_elapsed_s) with
                       | true, _ -> "  (timed out)"
                       | false, Some seconds ->
                           Printf.sprintf "  (%.0fs)" seconds
                       | false, None -> ""
                     in
                     [ ( (Theme.bad ())
                       , Printf.sprintf
                           "  First %d [failed] %s  [%s]%s"
                           (index + 1)
                           (Terminal_text.single_line node.fjn_identity)
                           (Terminal_text.single_line failed.fjno_failure_code)
                           clock )
                     ]
                     @ fusion_wrapped_block ~width ~indent:"    "
                         failed.fjno_error)
          |> List.concat
        in
        [ Ansi.dim, "" ]
        (* The counts are already in pipeline order, so joining them
           with the same arrow the Goal stage rail uses draws the run
           rather than describing it. The shape name stays, at the end,
           because it is what the preset is called. *)
        @ ( Ansi.dim
          , Printf.sprintf "  %s  \xe2\x94\x80\xe2\x96\xb6  %s  \xc2\xb7  %s"
              (fusion_panel_dots ~answered ~failed)
              (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " counts)
              shape )
        :: first_cards
  in
  let tool_lines =
    fusion_tool_trace_lines ~width evidence.fe_tool_trace
  in
  [ Ansi.bold, "  Title: " ^ Terminal_text.single_line evidence.fe_title
  ; Ansi.dim, ""
  ; Ansi.bold, "  1  QUESTION"
  ]
  @ fusion_markdown_block ~width ~indent:"    " evidence.fe_question
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  2  PANEL RESPONSES"
    ; ( Ansi.dim
      , let usage =
          if answered = 0 then "panel token usage: not recorded"
          else if failed = 0 then
            Printf.sprintf "%d input / %d output tokens" input_tokens output_tokens
          else
            Printf.sprintf "measured %d/%d panels: %d input / %d output tokens"
              answered (answered + failed) input_tokens output_tokens
        in
        Printf.sprintf "  %d answered / %d failed  \xc2\xb7  %s"
          answered failed usage )
  ]
  @ [ Ansi.dim, "" ]
  @ panel_chart_lines
  @ panel_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  3  JUDGE"
    ]
  @ judge_lines
  @ judges_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  4  TOOL EXECUTIONS"
    ]
  @ tool_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  5  EVIDENCE RECORDED"
    ; ( Ansi.dim
      , "  Board link: "
        ^ Link.reference Board_post
            (Terminal_text.single_line evidence.fe_post_id) )
    ]

let fusion_detail_lines ~width (detail : fusion_detail) =
  let run = detail.fud_run in
  let status = fusion_run_status_to_string run.fur_status in
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime run.fur_started_at in
  let date_time =
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let age = fusion_run_age ~now run in
  let started_text = Printf.sprintf "%s (%s ago)" date_time age in
  let pipeline = fusion_pipeline_diagram run in
  let run_lines =
    [ Ansi.bold, "  RUN"
    ; (Masc_tui_theme.tone Masc_tui_theme.Accent), "  Flow: Question \xe2\x86\x92 Panel \xe2\x86\x92 Judge \xe2\x86\x92 Evidence"
    ; Ansi.reset, "  Pipeline: " ^ pipeline
    ; ( Ansi.reset
      , Printf.sprintf "  Actions: K Keeper · B Board · %s[Y]%s Copy Link   %s[PgUp/PgDn]%s Page   %s[Esc]%s Back to Runs"
          (Theme.info ()) Ansi.reset
          (Theme.info ()) Ansi.reset
          (Theme.info ()) Ansi.reset )
    ; ( Ansi.dim
      , "  Link: "
        ^ Link.reference Fusion_run
            (Terminal_text.single_line run.fur_run_id) )
    ; ( Ansi.reset
      , Printf.sprintf "  Caller: %s@%s%s %s[Keeper]%s  \xc2\xb7  %s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line run.fur_keeper)
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
          (Link.reference Keeper (Terminal_text.single_line run.fur_keeper)) )
    ; fusion_run_status_color run.fur_status, "  Status: " ^ status
    ; (Masc_tui_theme.tone Masc_tui_theme.Accent), "  Stage: " ^ fusion_run_stage_to_string run.fur_stage
    ; Ansi.dim, "  Progress: " ^ fusion_run_progress_text run.fur_stage
    ; ( Ansi.reset
    , "  Configuration: " ^ Terminal_text.single_line run.fur_preset ^ " \xc2\xb7 "
      ^ Fusion_types.fusion_topology_to_string run.fur_topology )
    ; Ansi.dim, "  Started: " ^ started_text ^ " (local)"
    ; Ansi.reset, "  Duration: " ^ fusion_run_duration ~now run
    ]
    @ (match detail.fud_evidence with
       | None -> [Ansi.dim, "  Original question and Board link: awaiting evidence"]
       | Some evidence ->
           [ Theme.info (), "  Board: " ^ Link.reference Board_post evidence.fe_post_id
           ; Ansi.bold, "  Original question: " ^ Terminal_text.single_line evidence.fe_question ])
    @
    match run.fur_status with
    | Fusion_running -> []
    | Fusion_completed ->
        (match run.fur_decision, run.fur_summary with
         | Some decision, Some summary ->
             [ (Theme.ok ()), "  Outcome: " ^ Terminal_text.single_line decision ]
             @ fusion_labeled_markdown ~width ~label:"Outcome summary" summary
         | (Some _ | None), (Some _ | None) -> [])
    | Fusion_failed failure ->
        [ (Theme.bad ())
        , Printf.sprintf "  Registry failure [%s]: %s"
            (Terminal_text.single_line failure.frs_failure_code)
            (Terminal_text.single_line failure.frs_error)
        ]
  in
  let evidence_lines =
    match detail.fud_evidence_status, detail.fud_evidence with
    | Fusion_evidence_pending, None ->
        [ (Theme.warn ()), "  Evidence: pending (run is still running)" ]
    | Fusion_evidence_absent, None ->
        [ (Theme.warn ())
        , "  Evidence: absent (no current Board projection for this retained run)"
        ]
    | Fusion_evidence_recorded, Some evidence -> fusion_evidence_lines ~width evidence
    | Fusion_evidence_recorded, None
    | Fusion_evidence_pending, Some _
    | Fusion_evidence_absent, Some _ ->
        (* The strict decoder makes these states unreachable. Keeping the row
           explicit protects locally-constructed test state from looking like
           a legitimate empty reading. *)
        [ (Theme.bad ()), "  Fusion evidence invariant violated" ]
  in
  run_lines @ [ Ansi.dim, "" ] @ evidence_lines

let fusion_historical_lines ~width (detail : fusion_historical_detail) =
  [ Ansi.bold, "  HISTORICAL BOARD EVIDENCE"
  ; Theme.warn (), "  This Board evidence does not provide execution status or finish time"
  ; Ansi.reset, "  Run reference: " ^ Terminal_text.single_line detail.fhd_reference.fhe_run_id
  ; Ansi.reset, "  Board author: " ^ Terminal_text.single_line detail.fhd_author
  ; Theme.info (), "  Board: " ^ Link.reference Board_post detail.fhd_reference.fhe_post_id
  ; Ansi.reset, "  Title: " ^ Terminal_text.single_line detail.fhd_title
  ]
  @ (match detail.fhd_observations with
     | Error error ->
         [ Theme.bad (), "  Observed usage could not be decoded: " ^ Terminal_text.single_line error ]
     | Ok (usage, cost_usd) ->
         [ Ansi.reset, (match usage with
             | None -> "  Observed tokens: not recorded"
             | Some (input, output) -> Printf.sprintf "  Observed tokens: %d input / %d output" input output)
         ; Ansi.reset, (match cost_usd with
             | None -> "  Observed cost: not recorded"
             | Some cost -> Printf.sprintf "  Observed cost: $%.4f" cost) ])
  @ [ Ansi.dim, "  B: Board original · Y: copy Board link · Esc: back to Fusion list"
  ; Ansi.dim, "" ]
  @ (match detail.fhd_evidence with
     | Ok evidence -> fusion_evidence_lines ~width evidence
     | Error error -> [ Theme.bad (), "  Structured Fusion evidence could not be decoded: " ^ Terminal_text.single_line error ])
  @ [ Ansi.dim, ""; Ansi.bold, "  BOARD ORIGINAL" ]
  @ fusion_markdown_block ~width ~indent:"    " detail.fhd_body

let fusion_detail_pane (state : state) ~rows ~cols run_id buf =
  let detail =
    match state.fusion_detail with
    | Some detail when String.equal detail.fud_run.fur_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    Printf.sprintf "%s  %s  %s" (screen_title " MASC Fusion")
      (fit_width (Terminal_text.single_line run_id) 38)
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.fusion_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       box_divider buf cols);
  let chrome_rows =
    if Option.is_some state.fusion_detail_error then 7 else 5
  in
  let content_height = max 1 (rows - chrome_rows) in
  let lines =
    match state.fusion_mode with
    | Fusion_historical_detail reference ->
        (match state.fusion_historical_detail with
         | Some original when original.fhd_reference.fhe_post_id = reference.fhe_post_id
                              && original.fhd_reference.fhe_run_id = reference.fhe_run_id ->
             (if Option.is_some state.fusion_detail_error then [ Theme.warn (), "  Previous Board reading (refresh failed)" ] else [])
             @ fusion_historical_lines ~width:(max 1 (cols - 8)) original
         | Some _ | None -> [ Ansi.dim, "  (waiting for the selected Board original; r retries)" ])
    | Fusion_list | Fusion_detail _ ->
        (match detail, state.fusion_detail_error with
         | None, None -> [ Ansi.dim, "  (loading exact Fusion detail)" ]
         | None, Some _ -> [ Ansi.dim, page_failed_note ]
         | Some detail, (Some _ | None) -> fusion_detail_lines ~width:(max 1 (cols - 8)) detail)
  in
  let total = List.length lines in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.fusion_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (index + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The run list stays beside the run. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_fusion_detail (state : state) run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      fusion_detail_pane state ~rows ~cols run_id buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let format_sidebar_fusion (row : Tui_decode.fusion_run) =
        let status =
          match row.fur_status with
          | Tui_decode.Fusion_running -> "run "
          | Tui_decode.Fusion_completed -> "done"
          | Tui_decode.Fusion_failed _ -> "fail"
        in
        let time = fusion_run_clock row in
        let keeper = Terminal_text.single_line row.fur_keeper in
        let run_id = Terminal_text.single_line row.fur_run_id in
        Render_schedule.fusion_sidebar_label ~status ~time ~keeper ~run_id
      in
      let labels =
        fusion_list_entries state
        |> List.map (function
            | Fusion_retained_run run -> format_sidebar_fusion run
            | Fusion_historical_evidence reference ->
                "history " ^ Terminal_text.single_line reference.fhe_title)
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* No list row is selected when its original remains open after the
         refreshed inventory omits it. The sidebar's index API uses -1 for
         no matching row; the domain selection stays optional. *)
      let selected = Option.value (fusion_detail_entry_index state) ~default:(-1) in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Fusion"
        ~focused:false ~labels ~selected;
      let answer =
        fusion_detail_pane state ~rows ~cols:(cols - left_cols) run_id
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_fusion_detail ~scroll ~max_scroll));
  finish_surface state ~clamped:(Fusion_detail_scroll scroll)
    ~surface_key:"fusion-detail" ~rows:terminal_rows ~cols buf

(* The repositories a keeper can work in.  The server sends both the stored
   path spelling and the absolute path it actually resolves.  The latter is
   what an operator needs before opening a shell or comparing another
   checkout; resolving the stored spelling again in the TUI would use the
   TUI's cwd instead of the server's base path. *)
let repository_context_lines ~width (repo : Masc.Tui_decode.repository) =
  let wrap label value =
    Message_layout.wrap_words ~max_cells:(max 1 width)
      (Printf.sprintf "  %s: %s" label (Terminal_text.single_line value))
  in
  let stored_path =
    if String.equal repo.rp_local_path repo.rp_resolved_local_path then []
    else wrap "Stored as" repo.rp_local_path
  in
  let keepers =
    match repo.rp_keepers with
    | [] -> "none assigned"
    | names -> String.concat ", " names
  in
  wrap "Path" repo.rp_resolved_local_path
  @ stored_path
  @ wrap "Keepers" keepers

let render_workspace_activity (state : state) repo_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows, cursor, selected = workspace_activity_selection state in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"workspace-activity"
    ~title:(screen_title (" MASC Workspace / Activity · " ^ Terminal_text.single_line repo_id))
    ~hints:"j/k:select  PgUp/PgDn:page  Enter:file  r:refresh  Esc:repositories"
    ~body:(fun ~budget c ->
      match Masc_tui_fetched.view_for ~equal:String.equal state.workspace_activity ~key:repo_id with
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> c.push "  Reading recorded file changes..."
      | Masc_tui_fetched.Failed message -> c.push_styled ~style:(Theme.bad ()) ("  " ^ Terminal_text.single_line message)
      | Masc_tui_fetched.Ready reading ->
          let failures, omitted = List.fold_left (fun (failures, omitted) (_, result) ->
              match result with
              | Error _ -> (failures + 1, omitted)
              | Ok (snapshot : Tui_decode.file_change_snapshot) ->
                  (failures, omitted + snapshot.fcs_over_budget + snapshot.fcs_malformed)) (0,0) reading.war_keepers in
          c.push (Printf.sprintf "  Last %.0fh · %d recorded changes · %d successful · %d Keeper reads failed · %d unparsed calls"
            reading.war_hours (List.length rows)
            (List.length (List.filter (fun ((change : Tui_decode.file_change), _) -> change.fc_succeeded) rows)) failures omitted);
          let names = List.map (fun ((change : Tui_decode.file_change), _) -> change.fc_keeper) rows |> List.sort_uniq String.compare in
          c.push ("  Changes by Keeper: " ^ String.concat " · " (List.map (fun name ->
              Printf.sprintf "%s %d" (Terminal_text.single_line name)
                (List.length (List.filter (fun ((change : Tui_decode.file_change), _) -> change.fc_keeper = name) rows))) names));
          c.push_styled ~style:(Theme.recede ()) "  Recorded clone writes from loaded Keepers · Enter opens file; H history, m notes in Code";
          c.push "  DATE (local)      KEEPER             TASK             FILE";
          c.push_divider ();
          let room = max 1 (budget - 7) in
          let first = max 0 (cursor - room + 1) in
          let rows_window = Rows.of_list ~first:first ~height:room rows in
          for i = 0 to room - 1 do
            match Rows.at rows_window (first + i) with
            | None -> if i = 0 && rows = [] then c.push "  No recorded clone writes in this window" else c.push_empty ()
            | Some (change, path) ->
                let tm = Unix.localtime change.Tui_decode.fc_at in
                let line = Printf.sprintf "  %04d-%02d-%02d %02d:%02d %-18s %-16s %s"
                  (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
                  (fit_width (Terminal_text.single_line change.fc_keeper) 18)
                  (fit_width (Terminal_text.single_line (Option.value change.fc_task_id ~default:"unlinked")) 16)
                  (Terminal_text.single_line path) in
                if first + i = cursor then c.push_selected line else c.push line
          done;
          c.push_divider ();
          c.push (match selected with
            | None -> "  Task and file links appear when a recorded change names them"
            | Some (change, path) ->
                "  " ^ Terminal_text.single_line path ^ " · " ^
                (match change.fc_task_id with
                 | None -> "No Task recorded"
                 | Some id ->
                     match List.find_opt (fun (t : Tui_decode.task) -> t.id = id) state.tasks with
                     | None -> "Task " ^ Terminal_text.single_line id
                     | Some task -> Terminal_text.single_line (task.id ^ " · " ^ task.title))))

let render_repository_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let repos =
    match state.repositories with
    | None -> []
    | Some s -> s.Masc.Tui_decode.rs_repositories
  in
  let shown = List.length repos in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.repositories with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Workspace") (title_missing_reading ~error:state.repositories_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Workspace") shown timestamp
          (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"repositories"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      (* The path takes what the named columns leave, asked of the columns
         rather than of a constant standing in for their total. *)
      let path_width =
        Render_schedule.workspace_path_width
          ~inner_width:(max 1 (framed_inner_width cols - 2))
      in
      c.push_styled ~style:(Theme.recede ())
        ("  " ^ Render_schedule.workspace_header_row ~path_width);
      c.push_divider ();
      (match state.repositories_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let context_lines =
        match List.nth_opt repos state.repositories_cursor with
        | None -> []
        | Some repo -> repository_context_lines ~width:(cols - 6) repo
      in
      let context_rows =
        match context_lines with [] -> 0 | _ -> 1 + List.length context_lines
      in
      let fixed =
        2 + context_rows
        + (if Option.is_some state.repositories_error then 2 else 0)
      in
      let room = max 1 (budget - fixed) in
      let overflowing = shown > room in
      let content_height = if overflowing then max 1 (room - 1) else room in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.repositories_scroll max_scroll) in
      let repos_window = Rows.of_list ~first:scroll ~height:content_height repos in
      if shown = 0 then
        let empty =
          match
            empty_page_of ~snapshot:state.repositories
              ~error:state.repositories_error
          with
          | Page_failed -> page_failed_note
          | Page_unread -> page_unread_note
          | Page_empty -> "  (no repositories registered)"
        in
        c.push_styled ~style:(Theme.recede ()) empty
      else begin
        for i = 0 to content_height - 1 do
          let idx = i + scroll in
          match Rows.at repos_window idx with
          | None -> c.push_empty ()
          | Some r ->
              let open Masc.Tui_decode in
              let line =
                "  "
                ^ Render_schedule.workspace_row ~path_width
                    { Render_schedule.wrow_name =
                        Terminal_text.single_line r.rp_name
                    ; wrow_branch =
                        Terminal_text.single_line r.rp_default_branch
                    ; wrow_status = Terminal_text.single_line r.rp_status
                    ; wrow_sync = (if r.rp_auto_sync then "auto" else "manual")
                    ; wrow_path =
                        Terminal_text.single_line r.rp_resolved_local_path
                    }
              in
              if idx = state.repositories_cursor then c.push_selected line
              else c.push line
        done;
        if overflowing then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "[%d repositories, scroll %d]" shown scroll)
      end;
      (match context_lines with
       | [] -> ()
       | lines ->
           c.push_divider ();
           List.iter (c.push_styled ~style:(Theme.recede ())) lines))

let render_repository_changes (state : state) =
  match state.repository_changes_diff_path with
  | Some path -> render_repository_changes_diff state ~path
  | None ->
      let terminal_rows, cols = get_terminal_size () in
      let changes =
        match state.repository_changes with
        | Some snapshot -> snapshot.Masc.Tui_decode.rcs_changes
        | None -> []
      in
      let scope_name =
        match state.repository_changes_scope, state.repositories with
        | Some Tui_decode.Repository_change_project, _ -> "Project workspace"
        | Some (Tui_decode.Repository_change_repository id), Some snapshot ->
            (match
               List.find_opt
                 (fun (repo : Masc.Tui_decode.repository) ->
                   String.equal repo.rp_id id)
                 snapshot.rs_repositories
             with
             | Some repo -> repo.rp_name
             | None -> id)
        | Some (Tui_decode.Repository_change_repository id), None -> id
        | None, _ -> "Git workspace"
      in
      let title =
        Printf.sprintf " MASC Git Changes — %s (%d)  %s"
          (Terminal_text.single_line scope_name) (List.length changes)
          (connection_badge state)
      in
      let selected_path =
        match List.nth_opt changes state.repository_changes_cursor with
        | Some row -> Some row.rc_path
        | None -> None
      in
      let change_ctx = resolve_change_context state ~path_opt:selected_path in
      let context_lines = build_change_context_lines change_ctx in
      surface_chrome state ~terminal_rows ~cols ~surface_key:"repository-changes"
        ~title ~hints:Masc_tui_keys.footer_hints_git_changes
        ~body:(fun ~budget c ->
          List.iter
            (fun ctx_line ->
              c.push ctx_line;
              c.push_divider ())
            context_lines;
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "  %-18s %s" "State" "Path");
          c.push_divider ();
          (match state.repository_changes_error with
           | None -> ()
           | Some detail ->
               c.push_styled ~style:(Theme.bad ())
                 ("  " ^ Keeper_chat.terminal_safe_text detail);
               c.push_divider ());
          let fixed =
            2
            + (List.length context_lines * 2)
            + if Option.is_some state.repository_changes_error then 2 else 0
          in
          let room = max 1 (budget - fixed) in
          if changes = [] then
            c.push_styled ~style:(Theme.recede ())
              (match state.repository_changes, state.repository_changes_error with
               | None, None -> "  (loading Git changes)"
               | Some _, None -> "  (working tree clean)"
               | _, Some _ -> "  (Git changes unavailable)")
          else
            let changes_window = Rows.of_list ~first:state.repository_changes_scroll ~height:room changes in
            for i = 0 to room - 1 do
              let idx = state.repository_changes_scroll + i in
              match Rows.at changes_window idx with
              | None -> c.push_empty ()
              | Some row ->
                  let attr =
                    match state.msg_file_changes with
                    | Some snap ->
                        (match
                           List.find_opt
                             (file_change_matches_path row.rc_path)
                             snap.Masc.Tui_decode.fcs_changes
                         with
                         | Some fc ->
                             let t =
                               match fc.fc_task_id with
                               | Some tid -> tid
                               | None -> fc.fc_keeper
                             in
                             " [" ^ t ^ "]"
                         | None -> "")
                    | None -> ""
                  in
                  let line =
                    Printf.sprintf "  %-18s %s%s"
                      (repository_change_status row)
                      (Message_layout.fit_middle (max 8 (cols - 28 - String.length attr))
                         (Terminal_text.single_line row.rc_path))
                      attr
                  in
                  if idx = state.repository_changes_cursor then c.push_selected line
                  else c.push line
            done)

let render_memory (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let open Masc.Tui_decode in
  let keepers =
    match state.memory_health with
    | None -> []
    | Some s -> s.mhs_keepers
  in
  let shown = List.length keepers in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.memory_health with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Memory") (title_missing_reading ~error:state.memory_health_error) timestamp
          (connection_badge state)
    | Some s ->
        Printf.sprintf "%s · %d keepers · %d need memory · read %s (local)  %s"
          (screen_title " MASC Memory") shown s.mhs_starving_keepers
          (let tm = Unix.localtime s.mhs_generated_at in
           Printf.sprintf "%04d-%02d-%02d %02d:%02d"
             (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
             tm.Unix.tm_hour tm.Unix.tm_min)
          (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      Render_memory.render_memory_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_memory_facts (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let open Masc.Tui_decode in
  let keeper_name = Render_memory.facts_keeper_label state.memory_facts_keeper in
  let rows = Masc_tui_types.memory_fact_rows state in
  let total = List.length rows in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let filter_label =
    Masc_tui_types.memory_category_filter_label state.memory_facts_category
  in
  let query_label =
    match state.search with
    | Some q when String.length (String.trim q) > 0 ->
        Printf.sprintf " \xc2\xb7 find \"%s\"" (Terminal_text.single_line (String.trim q))
    | Some _ -> " \xc2\xb7 find \"\""
    | None ->
        if String.length (String.trim state.search_last) > 0 then
          Printf.sprintf " \xc2\xb7 filter \"%s\"" (Terminal_text.single_line (String.trim state.search_last))
        else ""
  in
  let title =
    Render_memory.facts_title
      ~screen:(screen_title " MASC Memory")
      ~keeper:keeper_name
      ~reading:
        (match state.memory_facts with
         | None ->
           Render_memory.Facts_unread
             { reading = title_missing_reading ~error:state.memory_facts_error }
         | Some _ ->
           Render_memory.Facts_loaded { total; filter_label; query_label })
      ~timestamp
      ~badge:(connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory-facts"
    ~title ~hints:Masc_tui_keys.footer_hints_memory_facts
    ~body:(fun ~budget c ->
      Render_memory.render_memory_facts_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_repositories (state : state) =
  if state.repository_changes_open then render_repository_changes state
  else render_repository_list state

let file_change_ranges (change : Masc.Tui_decode.file_change) =
  match change.fc_line_evidence with
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = Some range }) ->
    [ range ]
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrences = Some occurrences; _ }) ->
    List.map
      (fun (occurrence : Masc.Keeper_file_change_evidence.edit_occurrence) ->
        Option.value ~default:occurrence.old_range occurrence.new_range)
      occurrences
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = None })
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrences = None; _ })
  | None -> []

(* One line of what the change put there. An edit shows the text it wrote
   rather than the text it removed: the question a reader has is what the file
   says now. A write shows its size, because the whole body is never one row
   and a truncated first line of a new file says less than its length. *)
let change_row_summary (change : Masc.Tui_decode.file_change) =
  let content =
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { after; _ } -> Terminal_text.preview_line after
    | Masc.Tui_decode.Fc_inserted { text; _ } -> Terminal_text.preview_line text
    | Masc.Tui_decode.Fc_written { content } ->
      Printf.sprintf "(wrote %d bytes)" (String.length content)
  in
  match file_change_evidence_label change.fc_line_evidence with
  | None -> content
  | Some label ->
    Printf.sprintf "%s%s[%s]%s %s" Ansi.bold (Theme.info ()) label Ansi.reset
      content

let change_kind_badge (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited _ -> Theme.category Theme.Slot_2, "EDIT"
  | Masc.Tui_decode.Fc_inserted _ -> Theme.category Theme.Slot_2, "MEMO"
  | Masc.Tui_decode.Fc_written _ -> (Masc_tui_theme.tone Masc_tui_theme.Accent), "WRITE"

let change_result_badge (change : Masc.Tui_decode.file_change) =
  if change.Masc.Tui_decode.fc_succeeded then Theme.ok (), "APPLIED"
  else Theme.bad (), "FAILED"

(* A row of the diff, drawn as layers rather than as one styled string.

   Three styles overlap on every line: the row's background, the gutter's
   weight, and the text's own colour. Concatenating them would let the
   gutter's reset close the background, and the line would lose its colour
   from the marker onward -- the fault [Masc_tui_span] exists for. *)
let diff_row_span ~width (row : Diff.row) =
  let background, marker, text =
    match row with
    | Diff.Removed line -> (Span.bg Theme.Syntax.diff_removed_bg, "-", line)
    | Diff.Added line -> (Span.bg Theme.Syntax.diff_added_bg, "+", line)
    | Diff.Context line -> (Span.plain, " ", line)
  in
  (* Context is dim so the changed lines are what an eye lands on. The marker
     is bold against the same background, which is what tells the two apart
     where the terminal has no colour. *)
  let text_style =
    match row with
    | Diff.Context _ -> Span.combine background (Span.weight Ansi.dim)
    | Diff.Removed _ | Diff.Added _ -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.bold)) (marker ^ " ")
      ; Span.text text_style (Terminal_text.single_line text)
      ]
  in
  (* Padded to the full width with the row's own background: colour that stops
     at the last character makes lines of different lengths look like
     different kinds of line. Truncated first, because padding does not
     shorten. *)
  Span.pad_to width background (Span.truncate width composed)

(* The two halves of one change. A write has no removed half: its before is
   empty, so every line arrives as an addition, which is what a new file is. *)
let change_diff_halves (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited { before; after; _ } -> (before, after)
  | Masc.Tui_decode.Fc_inserted { text; _ } -> ("", text)
  | Masc.Tui_decode.Fc_written { content } -> ("", content)

let render_changes_diff (state : state) (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let before, after = change_diff_halves change in
  let diff_rows = Diff.rows ~before ~after in
  let removed, added = Diff.counts diff_rows in
  let total = List.length diff_rows in
  let header =
    Printf.sprintf "%s %s  -%d +%d  %s"
      (screen_title " MASC Change")
      (Terminal_text.single_line (change_row_address change))
      removed added
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Facts about the change the rows themselves cannot carry. *)
  let notes =
    let turn =
      Printf.sprintf "  turn %s  task %s  %s"
        (Option.fold ~none:"-" ~some:string_of_int change.Masc.Tui_decode.fc_turn)
        (Terminal_text.single_line
           (Option.value ~default:"-" change.Masc.Tui_decode.fc_task_id))
        (if change.Masc.Tui_decode.fc_succeeded then "applied"
         else "the call failed; this is what it tried to write")
    in
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { replace_all = true; _ } ->
        (* Every occurrence changed, and the log records the text once. Showing
           one pair without saying so would undercount the change. *)
        [ turn; "  replace_all: every occurrence changed; the log holds the text once" ]
    | Masc.Tui_decode.Fc_edited { replace_all = false; _ }
    | Masc.Tui_decode.Fc_inserted _
    | Masc.Tui_decode.Fc_written _ -> [ turn ]
  in
  let notes =
    match file_change_evidence_label change.fc_line_evidence with
    | None -> notes
    | Some label -> notes @ [ "  producer lines " ^ label ]
  in
  List.iter (fun note -> box_line_styled buf cols ~style:(Theme.recede ()) note) notes;
  box_divider buf cols;
  (* Counted, not tallied. The tally read "7 + notes - 1" against four fixed
     rows plus the notes, which left the surface one row over its budget --
     and the row [finish_surface] then dropped was the footer, so the diff was
     the one screen that did not say how to leave it. *)
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.changes_diff_scroll max_scroll) in
  let diff_rows_window = Rows.of_list ~first:scroll ~height:content_height diff_rows in
  if total = 0 then begin
    box_line_styled buf cols ~style:(Theme.recede ())
      "  (the call recorded no text; there is nothing to compare)";
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match Rows.at diff_rows_window (i + scroll) with
      | None -> box_empty buf cols
      | Some row -> box_line_span buf cols (diff_row_span ~width:(framed_inner_width cols) row)
    done;
  if total > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d lines, scroll %d]  esc closes" total scroll)
  else box_line_styled buf cols ~style:(Theme.recede ()) "  esc closes";
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"j/k:scroll  Left / Esc:back  o:open in editor  q:quit");
  finish_surface state ~clamped:(Changes_diff_scroll scroll)
    ~surface_key:"changes" ~rows:terminal_rows ~cols buf

let render_changes_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let changes =
    match state.changes with
    | None -> []
    | Some s -> s.Masc.Tui_decode.fcs_changes
  in
  let shown = List.length changes in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let whose =
    match state.changes_keeper with
    | None -> "(no keeper selected)"
    | Some name -> Terminal_text.single_line name
  in
  let header =
    match state.changes with
    | None ->
        Printf.sprintf "%s %s  %s  %s  %s"
          (screen_title " MASC Changes") whose (title_missing_reading ~error:state.changes_error) timestamp
          (connection_badge state)
    | Some s ->
        (* The window and the call count are stated because the list alone
           does not say what was looked at: no changes in a window and no
           calls in a window are different facts. *)
        Printf.sprintf "%s %s (%d in %.0fh of %d calls)  %s  %s"
          (screen_title " MASC Changes") whose shown
          s.Masc.Tui_decode.fcs_window_hours s.Masc.Tui_decode.fcs_calls_in_window
          timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* What the turn did takes the cells the named columns leave. *)
  let summary_width =
    Render_schedule.change_summary_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.change_header_row ~summary_width
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.changes_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* Changes the log could not carry are said out loud. A list that showed
     only what it had would tell an operator the turn wrote less than it did. *)
  let budget_note =
    match state.changes with
    | Some s when s.Masc.Tui_decode.fcs_over_budget > 0 ->
        Some
          (Printf.sprintf
             "  %d change(s) outgrew the tool-call log's inline budget; their text is not on disk"
             s.Masc.Tui_decode.fcs_over_budget)
    | Some _ | None -> None
  in
  (match budget_note with
   | None -> ()
   | Some note ->
       box_line_styled buf cols ~style:(Theme.recede ()) note;
       box_divider buf cols);
  (* The chrome and the preview's share both come from [scrolled_surface],
     which the keypress reads too. Working them out again here is what drifted
     the last time: this counted the over-budget note's two rows and the bound
     did not, and then the preview took half the body and the bound still did
     not know. *)
  let chrome_rows, preview_keep =
    match scrolled_surface state Changes with
    | Some s -> (s.sc_chrome, s.sc_preview_keep)
    | None -> (listing_chrome ~error:state.changes_error, None)
  in
  let total_content = max 1 (rows - chrome_rows) in
  (* The cursor row's recorded diff previews under the list, from the same
     local snapshot Enter renders -- no request rides a keypress. The list
     keeps at least [changes_preview_keep_rows] rows; the preview takes what
     remains.

     The split comes from Masc_tui_scroll because the keypress has to obey
     the height this draws. It also cannot depend on which row the cursor is
     on: reading the unclamped scroll to decide whether there is a preview
     made the height depend on the value that height was bounding, and the
     rows past the shortened list became unreachable. *)
  let preview_height =
    match preview_keep with
    | None -> 0
    | Some _ when shown = 0 -> 0
    | Some keep -> Masc_tui_scroll.preview_height ~total:total_content ~keep
  in
  let content_height = max 1 (total_content - preview_height) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.changes_scroll max_scroll) in
  let changes_window = Rows.of_list ~first:scroll ~height:content_height changes in
  (* The marked row, not the window's top row. They were the same field, so
     the mark never left the first drawn row: every row below it was visible
     and unselectable, and Enter always opened whichever change the window
     happened to start on. *)
  let cursor = max 0 (min state.changes_cursor (max 0 (shown - 1))) in
  let cursor_change = List.nth_opt changes cursor in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.changes ~error:state.changes_error with
      | Page_failed -> page_failed_note
      | Page_unread -> "  (pick a keeper on the Keepers surface, then press r)"
      | Page_empty -> "  (this keeper wrote no files in the window)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at changes_window idx with
      | None -> box_empty buf cols
      | Some change ->
          let kind_style, kind = change_kind_badge change in
          let result_style, result = change_result_badge change in
          let line =
            "  "
            ^ Render_schedule.change_row ~op_style:kind_style ~result_style
                ~summary_width
                { Render_schedule.crow_turn =
                    Option.fold ~none:"-" ~some:string_of_int
                      change.Masc.Tui_decode.fc_turn
                ; crow_task =
                    Terminal_text.single_line
                      (Option.value ~default:"-"
                         change.Masc.Tui_decode.fc_task_id)
                ; crow_op = kind
                ; crow_result = result
                ; crow_file =
                    Terminal_text.single_line (change_row_address change)
                ; crow_summary = change_row_summary change
                }
          in
          (* A call that failed still changed what the keeper tried to do, and
             it is the row an operator is looking for. Dim marks it as an
             attempt rather than hiding it. *)
          if idx = cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  (match cursor_change with
   | None -> ()
   | Some change when preview_height >= 2 ->
       let before, after = change_diff_halves change in
       let diff_rows = Diff.rows ~before ~after in
       let removed, added = Diff.counts diff_rows in
       box_divider buf cols;
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  preview %s  -%d +%d  (Enter opens, scrolls)"
            (Terminal_text.single_line (change_row_address change))
            removed added);
       let body_height = preview_height - 2 in
       let diff_rows_window = Rows.of_list ~first:0 ~height:body_height diff_rows in
       for i = 0 to body_height - 1 do
         match Rows.at diff_rows_window i with
         | Some row ->
             box_line_span buf cols (diff_row_span ~width:(framed_inner_width cols) row)
         | None -> box_empty buf cols
       done
   | Some _ -> ());
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d changes, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"j/k:move  right/Enter:diff  [/]:keeper  d:tree diff  v:code  o:editor  r:refresh  q:quit");
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf


(* What the tree holds for the file the cursor names. Separate from the
   tool-call reading by decision, not by accident: one says what the keeper
   tried to write and the other what survived, and a single view would make
   whichever it drew look like the whole answer. *)
let render_changes_tree_diff (state : state)
    (change : Masc.Tui_decode.file_change) =
  render_diff_surface state
    { ds_title = " MASC Tree"
    ; ds_address = Terminal_text.single_line (change_row_address change)
    ; ds_context_lines = []
    ; ds_diff = state.changes_tree_diff
    ; ds_error = state.changes_tree_diff_error
    ; ds_scroll = state.changes_diff_scroll
    ; ds_unchanged = "  (this file matches its last commit)"
    ; ds_esc_hint = "esc closes"
    ; ds_footer_hints = "j/k:scroll  Left / Esc:back  o:open in editor  q:quit"
    ; ds_surface_key = "changes"
    ; ds_clamped = (fun scroll -> Changes_diff_scroll scroll)
    }

(* The surface has two readings: the list, and one change opened. The open row
   is held as an index, so a refresh that shortens the list closes the diff
   rather than drawing a change the answer no longer holds. *)
let render_changes (state : state) =
  let opened =
    match (state.changes_diff_row, state.changes) with
    | Some row, Some snapshot ->
        List.nth_opt snapshot.Masc.Tui_decode.fcs_changes row
    | Some _, None | None, (Some _ | None) -> None
  in
  match opened with
  | Some change ->
      (* A path being read names the tree reading. Both readings of the same
         row exist at once; which one is drawn is the operator's last key, not
         whichever answer arrived last. *)
      if Option.is_some state.changes_tree_diff_path then
        render_changes_tree_diff state change
      else render_changes_diff state change
  | None -> render_changes_list state

(* Where the gate can deliver.

   Configured and reachable are separate columns because they call for
   different actions: one is a setup gap, the other is something that was
   working and is not. A connector that is set up but unreachable is the row
   an operator acts on. *)
let browser_lane_source_hint view =
  match Browser_lane_view.selected_scene_target view with
  | None -> None
  | Some node ->
      (match node.Masc.Browser_scene.source_context with
       | Masc.Browser_source_context.Unmapped -> None
       | (Located _ | Invalid _) as source ->
           Some (Masc.Browser_source_context.label source))

let browser_lane_fixed_rows view =
  (* Status, selection, tab, URL, divider and text position are always drawn.
     A source hint contributes a row only when the selected node has one. *)
  6 + (if Option.is_some (browser_lane_source_hint view) then 1 else 0)

let browser_lane_visible_rows (state : state) ~terminal_rows view =
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  max 0 (max 1 (body_rows - 5) - browser_lane_fixed_rows view)

let browser_lane_scroll_limit state ~terminal_rows ~cols view =
  let room = browser_lane_visible_rows state ~terminal_rows view in
  max 0 (Browser_lane_layout.count (browser_lane_rows ~cols view) - room)

let browser_lane_selection_scroll state ~terminal_rows ~cols view =
  let rows = browser_lane_rows ~cols view in
  let room = browser_lane_visible_rows state ~terminal_rows view in
  let limit = max 0 (Browser_lane_layout.count rows - room) in
  let scroll = min limit view.Browser_lane_view.scroll in
  match Browser_lane_layout.selected_row rows with
  | None -> scroll
  | Some _ when room = 0 -> scroll
  | Some row when row < scroll -> row
  | Some row when row >= scroll + room -> min limit (row - room + 1)
  | Some _ -> scroll

let render_browser_lane (state : state) (view : Browser_lane_view.t) =
  let open Browser_lane_view in
  let terminal_rows, cols = get_terminal_size () in
  let read_status = Browser_lane_view.read_status view in
  let read_style = match read_status with
    | Read_ok -> Theme.ok ()
    | Read_failed -> Theme.bad ()
    | Reading | Operating -> Theme.info ()
    | Unread | Browser_missing -> Theme.recede ()
  in
  let title = Printf.sprintf "%s  %s  %s[%s]%s"
      (screen_title " MASC Browser Lane") (source_name view.source ^ " · " ^ browser_label view)
      read_style (Browser_lane_view.read_status_label read_status) Ansi.reset in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(match view.client_picker, view.url_draft with
      | Some _, _ -> "j/k:choose  Enter:connect  r:reload connections  a:automation  h:observations  Esc:back"
      | None, Some _ when busy view -> "Capture in flight • Enter after completion • Esc:cancel URL"
      | None, Some _ -> "Enter:go  Esc:cancel  Ctrl-U:clear  Ctrl-O:screenshot"
      | None, None when Option.is_some view.scene ->
          let action = match Option.bind (selected_scene_target view) scene_target_action with
            | Some Read_region -> "Enter:read region  "
            | Some Click_control -> "Enter:click  "
            | None -> "" in
          action ^ "Tab/Shift-Tab:action  n/p:element  v:regions  s:text  y:copy  h:observations  Ctrl-O:image"
      | None, None -> Masc_tui_keys.footer_hints_browser_lane ^ "  s:scene  v:regions  h:observations")
    ~body:(fun ~budget c ->
      let status, style = match view.load with
        | Loading (_, Discover _) -> "Reading browser connections…", Theme.info ()
        | Loading (_, Read) -> "Reading " ^ browser_label view ^ "…", Theme.info ()
        | Loading (_, Read_refresh) -> "Refreshing browser text…", Theme.info ()
        | Loading (_, Open_session) -> "Opening automation browser…", Theme.info ()
        | Loading (_, Close_session) -> "Closing automation browser…", Theme.info ()
        | Loading (_, Goto _) -> "Navigating automation browser…", Theme.info ()
        | Loading (_, Scene_regions _) -> "Reading page regions…", Theme.info ()
        | Loading (_, Scene_focus _) -> "Reading selected page region…", Theme.info ()
        | Loading (_, Scene_read _) -> "Reading browser text and controls…", Theme.info ()
        | Loading (_, Scene_refresh _) -> "Refreshing current browser view…", Theme.info ()
        | Loading (_, Scene_click _) -> "Clicking observed browser control…", Theme.info ()
        | Loading (_, Viewport_refresh _) -> "Refreshing selected browser viewport…", Theme.info ()
        | Loading (_, Viewport_pointer {action=Browser_lane.Scroll_at _;_}) -> "Scrolling selected browser viewport…", Theme.info ()
        | Loading (_, Viewport_pointer _) -> "Interacting with selected browser viewport…", Theme.info ()
        | Loading (_, Screenshot _) -> "Capturing selected " ^ browser_label view ^ " tab… (any key cancels preview)", Theme.info ()
        | Failed detail -> "Read/action failed: " ^ Terminal_text.single_line detail, Theme.bad ()
        | No_browser -> "Browser bridge not connected", Theme.recede ()
        | Idle when Option.is_some view.scene ->
            (match view.scene with
             | Some scene -> Printf.sprintf "Scene %.1f ms • %d nodes%s" scene.elapsed_ms
                 (List.length scene.content.nodes) (if scene.content.truncated then " • truncated" else ""), Theme.ok ()
             | None -> "Not read yet", Theme.recede ())
        | Idle -> (match view.reading with
            | None -> "Not read yet", Theme.recede ()
            | Some reading -> Printf.sprintf "Read %.1f ms • %d tabs"
                reading.elapsed_ms (List.length reading.tabs), Theme.recede ())
      in
      (* The global coordinator status is not the result of the browser HTTP
         request. Keep it labeled, including the existing workspace warning. *)
      c.push_styled ~style ("  coordinator " ^ connection_badge state ^ "  " ^ status);
      match view.client_picker with
      | Some cursor ->
          c.push_styled ~style:(Theme.info ()) "  Choose a connected browser";
          c.push_divider ();
          let room = max 1 (budget - 4) in
          let start = max 0 (cursor - room + 1) in
          view.clients |> List.iteri (fun index (client : client) ->
            if index >= start && index < start + room then
              let line = Printf.sprintf "  %s%s · %s" (browser_name client.browser)
                (if Some client = view.selected_client then " (selected)" else "") (Terminal_text.single_line client.client_id) in
              if index = cursor then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          if view.clients = [] then (
            c.push_styled ~style:(Theme.recede ())
              (if busy view then "  Waiting for active connections…" else "  No active native browser connections");
            if awaiting_browser view then (
              c.push_styled ~style:(Theme.info ()) "  Live requires the MASC extension and its registered native host.";
              c.push_styled ~style:(Theme.recede ()) "  Setup: connectors/browser/host/README.md";
              c.push_styled ~style:(Theme.recede ()) "  Enable the extension in your Zen/Firefox profile, then r:refresh."))
      | None ->
      c.push_styled ~style:(Theme.info ())
        (match view.url_draft with
         | Some draft -> browser_lane_url_line ~cols draft
         | None when Option.is_some view.scene ->
             (match List.nth_opt (scene_targets view) view.scene_cursor with
              | Some node ->
                  let label = match node.kind with Region _ -> "Region" | _ -> "Element" in
                  Printf.sprintf "  %s %d/%d: %s • n/p:select • y:copy context"
                    label (view.scene_cursor + 1) (List.length (scene_targets view)) (Terminal_text.single_line node.text)
              | None -> "  No observed elements in this viewport • Ctrl-O:image")
         | None -> match view.source with
             | Live -> "  Live " ^ browser_label view ^ " • b:choose browser • a:automation"
             | Automation -> "  Automation browser • g:URL • o:open / x:close • l:live");
      let tabs, page = match view.reading with
        | None -> [], None
        | Some reading -> reading.tabs, reading.page
      in
      let tab_count = List.length tabs in
      let index =
        let rec find i = function
          | [] -> 0
          | (tab : tab) :: rest -> if Some tab.id = view.selected_tab then i else find (i + 1) rest
        in find 0 tabs
      in
      let selected = List.nth_opt tabs index in
      c.push_styled ~style:(Theme.info ())
        (match selected with
         | None -> "  No open tabs • Open a page in the selected browser connection"
         | Some tab -> Printf.sprintf "  [%d/%d] %s%s  [ / ]:select tab"
             (index + 1) tab_count (Terminal_text.single_line tab.title)
             (if tab.active then " (active)" else ""));
      c.push_styled ~style:(Theme.recede ())
        (match view.scene, page with
         | Some scene, _ ->
             let scope = match scene.content.view, scene.content.scope with
               | Browser_lane.Regions, _ -> "Page regions"
               | Content, Some _ -> "Selected region"
               | Content, None -> "Page content" in
             "  " ^ scope ^ " · viewport only · " ^ Terminal_text.single_line scene.content.url
         | None, None -> "  No page content"
         | None, Some page -> Printf.sprintf "  %s • %d chars%s%s"
             (Terminal_text.single_line page.url) page.chars
             (if page.truncated then " • truncated" else "")
             (match view.load with Idle -> "" | No_browser | Loading _ | Failed _ -> " • previous read"));
      (match browser_lane_source_hint view with
       | None -> ()
       | Some hint -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Terminal_text.single_line hint));
      c.push_divider ();
      let lines = browser_lane_rows ~cols view in
      let total = Browser_lane_layout.count lines in
      let room = max 0 (budget - browser_lane_fixed_rows view) in
      let max_scroll = max 0 (total - room) in
      let scroll = min max_scroll view.scroll in
      (* Read the window out of the retained array. [List.filteri] walked every
         row of a 50,000-character page to reach the ones on screen. *)
      for index = scroll to min (scroll + room - 1) (total - 1) do
        c.push_styled ~style:Ansi.reset ("  " ^ Browser_lane_layout.line lines index)
      done;
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  Text %d/%d • j/k:scroll • r:refresh • Ctrl-^ / Esc:hide lane"
           (if total = 0 then 0 else scroll + 1) total))

let browser_history_fixed_rows = 6

let browser_history_scroll_limit state ~terminal_rows ~cols history =
  let view = Browser_history.page_view history in
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let room = max 0 (max 1 (body_rows-5) - browser_history_fixed_rows) in
  max 0 (Browser_lane_layout.count (browser_lane_rows ~cols view) - room)

let render_browser_history (state : state) (history : Browser_history.t) =
  let terminal_rows, cols = get_terminal_size () in
  let title = screen_title (" MASC Browser Lane · " ^ Terminal_text.single_line history.keeper_name ^ " · retained observations") in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:"[/]:observation  j/k:scroll  y:copy record  r:reload list  h/Esc:back to browser"
    ~body:(fun ~budget c ->
      let status = match history.content with
        | Listing -> "Reading the Keeper's recent tool receipts…"
        | List_failed detail -> "Could not read observations: " ^ Terminal_text.single_line detail
        | Entries {entries;cursor;selection} ->
          let position = Printf.sprintf "Observation %d/%d · from 100 recent tool calls"
            (if entries=[] then 0 else cursor+1) (List.length entries) in
          position ^ (match selection with Loading -> " · loading saved page…"
            | Failed detail -> " · " ^ Terminal_text.single_line detail | Observed _ -> "") in
      c.push_styled ~style:(Theme.info ()) ("  " ^ status);
      c.push_styled ~style:(Theme.recede ()) "  Historical read · browser actions and live screenshots are inactive here";
      (match Browser_history.selected history with
       | None -> c.push_styled ~style:(Theme.recede ()) "  No selected observation"
       | Some entry -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Terminal_text.single_line (Masc_domain.iso8601_of_unix_seconds entry.at)
            ^ " · " ^ entry.execution_id));
      (match Browser_history.observation history with
       | None -> c.push_styled ~style:(Theme.recede ()) "  Page content has not been loaded"
       | Some observation -> c.push_styled ~style:(Theme.info ())
           ("  " ^ Terminal_text.single_line observation.scene.title ^ " · "
            ^ Terminal_text.single_line observation.scene.url
            ^ (if observation.scene.truncated then " · partial observation" else " · observed viewport")));
      c.push_divider ();
      let view = Browser_history.page_view history in
      let lines = browser_lane_rows ~cols view in
      let count = Browser_lane_layout.count lines in
      let room = max 0 (budget - browser_history_fixed_rows) in
      let scroll = min history.scroll (max 0 (count-room)) in
      for index=scroll to min (scroll+room-1) (count-1) do
        c.push_styled ~style:Ansi.reset ("  " ^ Browser_lane_layout.line lines index)
      done;
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  Text %d/%d" (if count=0 then 0 else scroll+1) count))

let render_connectors (state : state) =
  match browser_lane_on_screen state, state.browser_history with
  | Some _, Some history -> render_browser_history state history
  | Some view, None -> render_browser_lane state view
  | None, _ ->
  let terminal_rows, cols = get_terminal_size () in
  let connectors =
    match state.connectors with
    | None -> []
    | Some s -> s.Masc.Tui_decode.cs_connectors
  in
  let shown = List.length connectors in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.connectors with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Connectors") (title_missing_reading ~error:state.connectors_error) timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d of %d available)  %s  %s"
          (screen_title " MASC Connectors")
          snapshot.Masc.Tui_decode.cs_active snapshot.Masc.Tui_decode.cs_total
          timestamp (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:"B:Browser Lane  j/k:scroll  b:bind  u:unbind  r:refresh"
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  %-16s %-11s %-11s %-10s %s" "Connector"
           "Configured" "Reachable" "Status" "Channel");
      c.push_divider ();
      (match state.connectors_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let fixed = 2 + (if Option.is_some state.connectors_error then 2 else 0) in
      let room = max 1 (budget - fixed) in
      let overflowing = shown > room in
      let content_height = if overflowing then max 1 (room - 1) else room in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.connectors_scroll max_scroll) in
      let connectors_window = Rows.of_list ~first:scroll ~height:content_height connectors in
      if shown = 0 then
        let empty =
          match
            empty_page_of ~snapshot:state.connectors
              ~error:state.connectors_error
          with
          | Page_failed -> page_failed_note
          | Page_unread -> page_unread_note
          | Page_empty -> "  (no connectors registered)"
        in
        c.push_styled ~style:(Theme.recede ()) empty
      else begin
        for i = 0 to content_height - 1 do
          let idx = i + scroll in
          match Rows.at connectors_window idx with
          | None -> c.push_empty ()
          | Some connector ->
              let open Masc.Tui_decode in
              let yes_no flag = if flag then "yes" else "no" in
              let line =
                Printf.sprintf "  %-16s %-11s %-11s %-10s %s"
                  (Terminal_text.single_line connector.cn_display_name)
                  (yes_no connector.cn_available)
                  (yes_no connector.cn_connected)
                  (Terminal_text.single_line connector.cn_status)
                  (Terminal_text.single_line_or ~default:"-"
                     connector.cn_channel)
              in
              let style =
                (* Set up and unreachable is the row to act on: it was
                   working. Never configured is dim -- it is a choice, not a
                   fault. *)
                if connector.cn_available && not connector.cn_connected then
                  Theme.bad ()
                else if not connector.cn_available then Ansi.dim
                else Ansi.reset
              in
              if idx = state.connectors_cursor then c.push_selected line
              else c.push_styled ~style line
        done;
        if overflowing then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "[%d connectors, scroll %d]" shown scroll)
      end)

let runtime_refresh_badge refresh_state =
  let open Masc.Tui_decode in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> "fresh", (Theme.ok ())
    | Runtime_probe_recent -> "recent", (Theme.info ())
    | Runtime_probe_served_stale -> "stale", (Theme.warn ())
    | Runtime_probe_warming_up -> "warming", (Theme.warn ())
  in
  style ^ label ^ Ansi.reset

let runtime_overall_badge status =
  let open Masc.Tui_decode in
  let style =
    match status with
    | Runtime_probe_reachable -> (Theme.ok ())
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_probe_status_to_string status ^ Ansi.reset

let runtime_route_badge (runtime : Masc.Tui_decode.runtime_option) =
  if not runtime.ro_dispatchable then (Theme.bad ()) ^ "blocked" ^ Ansi.reset
  else
    (match runtime_quota_badge runtime with
     | Some badge -> badge
     | None -> (Theme.info ()) ^ "ready" ^ Ansi.reset)

let runtime_probe_badge = function
  | None -> Ansi.dim ^ "unobserved" ^ Ansi.reset
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let open Masc.Tui_decode in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> (Theme.ok ())
        | Runtime_provider_skipped_cli | Runtime_provider_skipped_native_auth -> Ansi.dim
        | Runtime_provider_missing_auth | Runtime_provider_auth_failed ->
            (Theme.warn ())
        | Runtime_provider_network_error
        | Runtime_provider_server_error
        | Runtime_provider_endpoint_not_found
        | Runtime_provider_http_error
        | Runtime_provider_unknown_http_status
        | Runtime_provider_invalid_endpoint
        | Runtime_provider_invalid_execution_transport -> (Theme.bad ())
      in
      let label = runtime_probe_status_label probe.rpp_status in
      style ^ label ^ Ansi.reset

let runtime_route_probe_badge runtime probe =
  runtime_route_badge runtime ^ " / " ^ runtime_probe_badge probe

let runtime_probe_detail = function
  | None -> []
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let latency =
        Option.map (fun value -> Printf.sprintf "%.0fms" value) probe.rpp_latency_ms
      in
      let http =
        Option.map (fun value -> Printf.sprintf "HTTP %d" value) probe.rpp_http_status
      in
      let error = Terminal_text.optional_single_line probe.rpp_error in
      let checked =
        Some ("checked " ^ Terminal_text.clock_timestamp probe.rpp_checked_at)
      in
      List.filter_map Fun.id [ latency; http; error; checked ]

let runtime_column_widths cols =
  if cols >= 140 then 18, 30, 30, 22
  else if cols >= 120 then 14, 24, 24, 22
  else 10, 20, 20, 22

let runtime_column width text =
  let clipped = fit_width text width in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

(* A column that holds names rather than prose. Lane and candidate ids share
   long prefixes -- glm-coding-…-a, glm-coding-…-b -- and at eighty columns
   the lane column is ten cells, so cutting from the end drew four different
   lanes as four identical "glm-codin~". The tail is what tells them apart,
   which is the same reason the Keepers table fits its names from the middle.

   Padded to the column afterwards, like {!runtime_column}, so the columns to
   the right do not move. *)
let runtime_name_column width text =
  let clipped = Message_layout.fit_middle width text in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

let runtime_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  let lines =
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  in
  match lines with
  | [] -> [ style, prefix ^ "—" ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let runtime_bool = function true -> "yes" | false -> "no"

let runtime_detail_lines state target ~width =
  let open Masc.Tui_decode in
  let reading =
    match state.runtime_surface, target with
    | None, _ -> None
    | Some snapshot, Runtime_lane_candidate { lane_id; runtime_id } ->
        snapshot.rss_candidates
        |> List.find_opt (fun row ->
               String.equal row.rcr_lane_id lane_id
               && String.equal row.rcr_runtime.ro_id runtime_id)
        |> Option.map (fun row ->
               ( row.rcr_runtime
               , [ row.rcr_lane_id ]
               , Some (row.rcr_position, row.rcr_candidate_count)
               , row.rcr_preferred_at_ts
               , row.rcr_probe ))
    | Some snapshot, Runtime_catalog_entry { runtime_id } ->
        runtime_all_rows snapshot
        |> List.find_opt (fun (runtime, _) -> String.equal runtime.ro_id runtime_id)
        |> Option.map (fun (runtime, lanes) ->
               let probe =
                 Tui_decode.runtime_probe_for_id snapshot ~runtime_id:runtime.ro_id
               in
               runtime, lanes, None, None, probe)
  in
  match reading with
  | None ->
      [ Theme.warn (),
        "  This runtime row is no longer present in the refreshed projection"
      ]
  | Some (runtime, lanes, position, preferred_at, probe) ->
      let fields =
        runtime_detail_field ~width ~style:Ansi.reset "Runtime ID" runtime.ro_id
        @ runtime_detail_field ~width ~style:Ansi.reset "Provider" runtime.ro_provider
        @ runtime_detail_field ~width ~style:Ansi.reset "Model" runtime.ro_model
        @ runtime_detail_field ~width ~style:Ansi.reset "Effective context"
            (Printf.sprintf "%d tokens" runtime.ro_effective_max_context)
        @ runtime_detail_field ~width ~style:Ansi.reset "Context source"
            (runtime_context_source_label runtime.ro_max_context_source)
        @ runtime_detail_field ~width ~style:Ansi.reset "Max output"
            (match runtime.ro_max_output_tokens with
             | Some tokens -> Printf.sprintf "%d tokens" tokens
             | None -> "not specified")
        @ runtime_detail_field ~width ~style:Ansi.reset "Local runtime"
            (runtime_bool runtime.ro_is_local)
        @ runtime_detail_field ~width ~style:Ansi.reset "Used by lanes"
            (match lanes with [] -> "unassigned" | values -> String.concat ", " values)
        @ runtime_detail_field ~width ~style:Ansi.reset "Dispatchable"
            (runtime_bool runtime.ro_dispatchable)
        @ runtime_detail_field ~width ~style:Ansi.reset "Default runtime"
            (runtime_bool runtime.ro_is_default)
      in
      let candidate =
        match position with
        | None -> []
        | Some (at, total) ->
            runtime_detail_field ~width ~style:Ansi.reset "Lane position"
              (Printf.sprintf "%d of %d" at total)
      in
      let blocker =
        match runtime.ro_blocked_reason with
        | None -> []
        | Some reason ->
            runtime_detail_field ~width ~style:(Theme.bad ()) "Blocked because" reason
      in
      let sticky =
        match preferred_at with
        | None -> []
        | Some at ->
            runtime_detail_field ~width ~style:Ansi.dim "Last successful at"
              (Masc_domain.iso8601_of_unix_seconds at)
      in
      let quota =
        match runtime_quota_badge runtime with
        | None -> []
        | Some _ ->
            (match runtime.ro_quota_scope with
             | None -> []
             | Some scope ->
               runtime_detail_field ~width ~style:(Theme.warn ()) "Quota"
                 (match runtime.ro_quota_resets_at with
                  | Some resets_at ->
                    let tm = Unix.localtime resets_at in
                    Printf.sprintf "exhausted, resets %02d:%02d (%s)"
                      tm.Unix.tm_hour tm.Unix.tm_min scope
                  | None ->
                    Printf.sprintf "exhausted, no reset stated (%s)" scope))
      in
      let probe_lines =
        match probe with
        | None -> [ Ansi.dim, "  Probe: unobserved" ]
        | Some row ->
            let transport =
              match row.rpp_transport with
              | Runtime_probe_http -> "http"
              | Runtime_probe_cli -> "cli"
            in
            runtime_detail_field ~width ~style:Ansi.reset "Probe status"
              (runtime_probe_status_label row.rpp_status)
            @ runtime_detail_field ~width ~style:Ansi.reset "Probe transport" transport
            @ runtime_detail_field ~width ~style:Ansi.reset "Checked at" row.rpp_checked_at
            @ (match row.rpp_reachable with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "Reachable"
                     (runtime_bool value))
            @ (match row.rpp_http_status with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "HTTP status"
                     (string_of_int value))
            @ (match row.rpp_latency_ms with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "Latency"
                     (Printf.sprintf "%.0fms" value))
            @ (match runtime_probe_annotation ~status:row.rpp_status row.rpp_error with
               | None -> []
               | Some (Runtime_probe_note note) ->
                   runtime_detail_field ~width ~style:Ansi.dim "Probe note" note
               | Some (Runtime_probe_failure error) ->
                   runtime_detail_field ~width ~style:(Theme.bad ()) "Probe error" error)
      in
      fields @ candidate @ blocker @ sticky @ quota @ probe_lines

let render_runtime_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let target_label =
    match target with
    | Runtime_lane_candidate { lane_id; runtime_id } -> lane_id ^ " / " ^ runtime_id
    | Runtime_catalog_entry { runtime_id } -> runtime_id
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s" (screen_title " MASC Config / Runtime detail")
       (Terminal_text.single_line target_label) (connection_badge state));
  box_divider buf cols;
  let lines = runtime_detail_lines state target ~width:(max 1 (cols - 8)) in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.runtime_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:scroll  PgUp/PgDn:page  left/Esc:list  r:refresh  Tab:next");
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* Lane candidates come from /runtime/resolved; reachability comes from the
   cached runtime-probe document. Exact runtime-id joining happened in the
   decoder module, so drawing never parses ids or reconstructs a lane. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ( runtime_lane_width
      , runtime_candidate_width
      , runtime_identity_width
      , runtime_status_width ) =
    runtime_column_widths cols
  in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let candidates =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.rss_candidates
  in
  (* The roster the lane view cannot show: every runtime the workspace can
     call, with the lanes that name it. A runtime no lane names has an empty
     [lanes] and is exactly what an operator is looking for when they ask why
     a model they configured is nowhere on this screen. *)
  let all_runtimes =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> runtime_all_rows snapshot
  in
  let shown =
    match state.runtime_mode with
    | Masc_tui_types.Runtime_lanes -> List.length candidates
    | Masc_tui_types.Runtime_all -> List.length all_runtimes
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.runtime_surface with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Config / Runtime") (title_missing_reading ~error:state.runtime_surface_error) timestamp
          (connection_badge state)
    | Some snapshot ->
        let lane_count = List.length snapshot.rss_resolved.rrs_lanes in
        let probe_status =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> (Theme.warn ()) ^ "probe unavailable" ^ Ansi.reset
          | Some probe ->
              runtime_overall_badge probe.rps_status ^ " / "
              ^ runtime_refresh_badge probe.rps_refresh_state
        in
        let probe_read =
          if Option.is_some snapshot.rss_probe_error then
            (Theme.warn ()) ^ " / read failed" ^ Ansi.reset
          else ""
        in
        let tab ~active label =
          if active then
            (Theme.info ()) ^ Ansi.bold ^ "\xe2\x96\xb8" ^ label ^ Ansi.reset
          else Ansi.dim ^ label ^ Ansi.reset
        in
        let all_count =
          List.length snapshot.rss_resolved.Masc.Tui_decode.rrs_runtimes
        in
        let lanes_active = state.runtime_mode = Masc_tui_types.Runtime_lanes in
        Printf.sprintf "%s  %s  %s  %s%s  %s  %s"
          (screen_title " MASC Config / Runtime")
          (tab ~active:lanes_active
             (Printf.sprintf "Lanes (%d lanes, %d slots)" lane_count
                 (List.length snapshot.rss_candidates)))
          (tab ~active:(not lanes_active)
             (Printf.sprintf "All runtimes (%d)" all_count))
          probe_status probe_read timestamp (connection_badge state)
  in
  let authority_line =
    match state.runtime_surface with
    | None ->
        "  SSOT: runtime.toml  projections: /api/v1/runtime/resolved + runtime-probe"
    | Some snapshot ->
        let config =
          Terminal_text.single_line_or ~default:"config path unavailable"
            snapshot.rss_resolved.rrs_config_path
        in
        let summary_text =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> "probe unavailable"
          | Some probe ->
              let summary = probe.rps_summary in
              Printf.sprintf "%d reachable / %d failed / %d skipped"
                summary.rpsu_reachable summary.rpsu_failed summary.rpsu_skipped
        in
        let probe_note =
          match snapshot.rss_probe_error, snapshot.rss_probe with
          | Some detail, _ -> "  probe: " ^ Terminal_text.single_line detail
          | None, Some probe ->
              (match probe.rps_errors with
               | detail :: _ -> "  probe: " ^ Terminal_text.single_line detail
               | [] -> "")
          | None, None -> ""
        in
        let probe_only_note =
          match snapshot.rss_unassigned_probe_count with
          | 0 -> ""
          | count -> Printf.sprintf "  %d probe-only" count
        in
        Printf.sprintf
          "  SSOT: runtime.toml  projections: resolved + probe  %s  %s%s%s"
          summary_text config probe_only_note probe_note
  in
  let chrome_rows = runtime_surface_listing_chrome state in
  let content_height = max 0 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  let all_runtimes_window = Rows.of_list ~first:scroll ~height:content_height all_runtimes in
  let candidates_window = Rows.of_list ~first:scroll ~height:content_height candidates in
  let scroll_hint =
    if shown > content_height then Printf.sprintf "[%d rows, scroll %d]  " shown scroll else ""
  in
  let hints =
    Printf.sprintf "%sj/k:scroll  Enter:detail  p:%s  Tab:next  q:quit  r:live refresh"
      scroll_hint
      (match state.runtime_mode with Runtime_lanes -> "all runtimes" | Runtime_all -> "service lanes")
    ^ (match state.runtime_mode with Runtime_lanes -> "  e:add failover" | Runtime_all -> "")
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"runtime" ~title:header ~hints
    ~body:(fun ~budget:_ c ->
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> (Theme.warn ())
    | Some _ | None -> Ansi.dim
  in
  c.push_styled ~style:authority_style authority_line;
  c.push_divider ();
  c.push_styled ~style:(Theme.recede ())
    ("  "
     ^ runtime_column runtime_lane_width
         (match state.runtime_mode with
          | Masc_tui_types.Runtime_lanes -> "LANE"
          | Masc_tui_types.Runtime_all -> "USED BY")
     ^ " "
     ^ runtime_column runtime_candidate_width
         (match state.runtime_mode with
          | Masc_tui_types.Runtime_lanes -> "CANDIDATE"
          | Masc_tui_types.Runtime_all -> "RUNTIME")
     ^ " "
     ^ runtime_column runtime_identity_width "PROVIDER / MODEL" ^ " "
     ^ runtime_column runtime_status_width "ROUTE / PROBE"
     ^ " DETAIL");
  c.push_divider ();
  (match state.runtime_surface_error with
   | None -> ()
   | Some detail ->
       c.push_styled ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       c.push_divider ());
  (match state.runtime_lane_error with
   | None -> ()
   | Some detail ->
       c.push_styled ~style:(Theme.bad ())
         ("  lane write refused: " ^ Keeper_chat.terminal_safe_text detail);
       c.push_divider ());
  (match runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf "  adding a failover candidate to %s — j/k move, Enter append, e cancel"
            (Terminal_text.single_line picker.rlp_lane));
       if picker.rlp_choices = [] then
         c.push_styled ~style:(Theme.recede ()) "  (runtime catalogue unread)"
       else
         List.iteri (fun offset (runtime : Masc.Tui_decode.runtime_option) ->
           let note =
             if List.exists (String.equal runtime.ro_id) picker.rlp_already
             then "  (already a candidate)"
             else if not runtime.ro_dispatchable then "  (blocked)"
             else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
             then "  (same provider as a current candidate)"
             else ""
           in
           c.push
             (Printf.sprintf "  %s %s   %s / %s%s"
                (if offset = 0 then ">" else " ")
                (Terminal_text.single_line runtime.ro_id)
                (Terminal_text.single_line runtime.ro_provider)
                (Terminal_text.single_line runtime.ro_model)
                (Ansi.dim ^ note ^ Ansi.reset))) picker.rlp_choices;
       c.push_divider ());
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.runtime_surface
          ~error:state.runtime_surface_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty ->
          (match state.runtime_mode with
           | Masc_tui_types.Runtime_lanes -> "  (no runtime lanes configured)"
           | Masc_tui_types.Runtime_all -> "  (no runtimes configured)")
    in
    c.push_styled ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      c.push_empty ()
    done
  end
  else
    for index = 0 to content_height - 1 do
      match state.runtime_mode with
      | Masc_tui_types.Runtime_all ->
          (match Rows.at all_runtimes_window (index + scroll) with
           | None -> c.push_empty ()
           | Some (runtime, lanes) ->
               let open Masc.Tui_decode in
               let used_by =
                 match lanes with
                 | [] -> (Theme.recede ()) ^ "unassigned" ^ Ansi.reset
                 | [ one ] -> one
                 | many -> Printf.sprintf "%d lanes" (List.length many)
               in
               let detail =
                 String.concat " \xc2\xb7 "
                   ((if runtime.ro_is_default then [ "default" ] else [])
                    @ (match
                         Terminal_text.optional_single_line runtime.ro_blocked_reason
                       with
                       | Some reason -> [ "blocked: " ^ reason ]
                       | None -> [])
                    @ (match lanes with [] -> [] | l -> [ String.concat ", " l ])
                    @ runtime_probe_detail
                        (Option.bind state.runtime_surface (fun snapshot ->
                           Tui_decode.runtime_probe_for_id snapshot ~runtime_id:runtime.ro_id)))
               in
               let line =
                 "  " ^ runtime_column runtime_lane_width used_by ^ " "
                 ^ runtime_column runtime_candidate_width
                     (Terminal_text.single_line runtime.ro_id) ^ " "
                 ^ runtime_column runtime_identity_width
                     (Terminal_text.single_line
                        (runtime.ro_provider ^ " / " ^ runtime.ro_model)) ^ " "
                 ^ runtime_column runtime_status_width
                      (runtime_route_probe_badge runtime
                         (Option.bind state.runtime_surface (fun snapshot ->
                            Tui_decode.runtime_probe_for_id snapshot ~runtime_id:runtime.ro_id)))
                 ^ " " ^ Ansi.dim ^ detail ^ Ansi.reset
               in
               if index + scroll = state.runtime_cursor then
                 c.push_selected (Masc_tui_theme.strip_sgr line)
               else c.push line)
      | Masc_tui_types.Runtime_lanes ->
      match Rows.at candidates_window (index + scroll) with
      | None -> c.push_empty ()
      | Some candidate ->
          let open Masc.Tui_decode in
          let runtime = candidate.rcr_runtime in
          let candidate_label =
            Printf.sprintf "%d/%d %s" candidate.rcr_position
              candidate.rcr_candidate_count
              (Terminal_text.single_line runtime.ro_id)
          in
          let provider_model =
            Terminal_text.single_line
              (runtime.ro_provider ^ " / " ^ runtime.ro_model)
          in
          let route_probe =
            runtime_route_probe_badge runtime candidate.rcr_probe
          in
          let route_detail =
            if runtime.ro_dispatchable then []
            else
              match Terminal_text.optional_single_line runtime.ro_blocked_reason with
              | Some reason -> [ "blocked: " ^ reason ]
              | None -> []
          in
          let lane_fact =
            match candidate.rcr_preferred_at_ts with
            | Some at ->
                [ "last success "
                  ^ Terminal_text.clock_timestamp
                      (Masc_domain.iso8601_of_unix_seconds at)
                ]
            | None when candidate.rcr_candidate_count = 1 -> [ "single candidate" ]
            | None -> []
          in
          let default_fact = if runtime.ro_is_default then [ "default" ] else [] in
          let detail =
            String.concat " \xc2\xb7 "
              (route_detail @ default_fact @ lane_fact
               @ runtime_probe_detail candidate.rcr_probe)
          in
          let line =
            "  "
            ^ runtime_name_column runtime_lane_width
                (Terminal_text.single_line candidate.rcr_lane_id)
            ^ " " ^ runtime_name_column runtime_candidate_width candidate_label
            ^ " " ^ runtime_column runtime_identity_width provider_model
            ^ " " ^ runtime_column runtime_status_width route_probe
            ^ " " ^ detail
          in
          if index + scroll = state.runtime_cursor then
            c.push_selected (Masc_tui_theme.strip_sgr line)
          else c.push line
    done;
)
;;

let tools_scrolled state =
  tools_scrolled_for_lines state (Render_tools.tools_display_lines state)
;;

let render_tools (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title " MASC Tools") timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_line buf cols (" " ^ Render_tools.tools_pane_strip state);
  box_divider buf cols;
  (match state.tools_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let display_lines = Render_tools.tools_display_lines state in
  let layout = tools_scrolled_for_lines state display_lines in
  let drawable = layout.sc_count in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:drawable ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min state.tools_scroll max_scroll) in
  let display_lines_window = Rows.of_list ~first:scroll ~height:content_height display_lines in
  for i = 0 to content_height - 1 do
    match Rows.at display_lines_window (i + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  if drawable > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d rows, scroll %d]" drawable scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf

(** Dispatch a normal-height render based on the current surface. *)
(* One keeper's durable tool-call log, using the same row vocabulary as the
   chat pane: the finished glyph for a call that returned, the failure glyph
   for one that returned an error, and the exact fields recorded for it. The
   server's own freshness verdict rides the header - a stale page must not
   read as a quiet keeper. *)
let render_keeper_calls (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let keeper_name =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> keeper.k_name
    | None -> "?"
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.keeper_calls with
    | Some snapshot when state.keeper_calls_loading ->
        Printf.sprintf
          " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls (%d)  refreshing...  %s  %s"
          (Terminal_text.single_line keeper_name)
          (List.length snapshot.Masc.Tui_decode.kcs_entries)
          timestamp (connection_badge state)
    | None when state.keeper_calls_loading ->
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls  (loading...)  %s  %s"
          (Terminal_text.single_line keeper_name)
          timestamp (connection_badge state)
    | None ->
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls  %s  %s  %s"
          (Terminal_text.single_line keeper_name)
          (title_missing_reading ~error:state.keeper_calls_error)
          timestamp
          (connection_badge state)
    | Some snapshot ->
        (* The verdict says what is wrong with the log; the reason says why,
           and it is not always the verdict said twice. Four of the words
           this route can send come with a reason derived from themselves --
           "empty" arrives with "no_entries" -- but "coverage_gap" carries
           the gap record's own message, which nothing else on this header
           can supply.

           The "ok" arm that used to open this match built the same string
           the arm below it builds, so it decided nothing, and matched a
           health word by its spelling to do it. *)
        let freshness =
          let reason =
            match snapshot.Masc.Tui_decode.kcs_stale_reason with
            | None -> ""
            | Some reason -> " · " ^ Terminal_text.single_line reason
          in
          match
            (snapshot.Masc.Tui_decode.kcs_health,
             snapshot.Masc.Tui_decode.kcs_latest_age_s)
          with
          | health, Some age ->
            Printf.sprintf "%s · latest %.0fs ago%s" health age reason
          | health, None -> health ^ reason
        in
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls (%d)  %s  %s  %s"
          (Terminal_text.single_line keeper_name)
          (List.length snapshot.Masc.Tui_decode.kcs_entries)
          freshness timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line_styled buf cols ~style:Ansi.bold header;
  box_divider buf cols;
  let col_hdr =
    "  j/k rows · exact fields: tool | input | output"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.keeper_calls_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (match state.keeper_calls with
   | Some snapshot when snapshot.Masc.Tui_decode.kcs_mismatched > 0 ->
       box_line_styled buf cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d row(s) named another keeper and were not drawn"
            snapshot.Masc.Tui_decode.kcs_mismatched);
       box_divider buf cols
   | Some _ | None -> ());
  let entries =
    match state.keeper_calls with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.kcs_entries
  in
  let shown = List.length entries in
  (* The error row and the mismatch row are drawn above; counting the buffer
     asks what was drawn rather than restating the two conditions. *)
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  (* The scroll unit is one rendered row, not one call. A canonical proposal
     identity plus its input and output cannot fit a two-row short viewport;
     compressing those fields into the two rows made the rightmost identity
     disappear permanently. Each exact field therefore owns rows that j/k can
     reach independently. *)
  let inner_cells = max 1 (framed_inner_width cols) in
  let labeled_rows ~call_index ~style ~label value =
    let prefix = Printf.sprintf "  #%d %s " (call_index + 1) label in
    let value = Terminal_text.single_line value in
    let value = if String.equal value "" then "(empty)" else value in
    let narrow_rows () =
      (* Drop decorative indentation before wrapping the exact header. The
         TUI requests at most 100 entries, so even [#100
         provenance] fits the 15-cell framed body of a 19-column terminal. *)
      let field_header =
        Printf.sprintf "#%d %s" (call_index + 1) label
      in
      let header_rows =
        Message_layout.split_cells ~max_cells:inner_cells field_header
        |> List.map (fun part -> call_index, style, part)
      in
      let value_rows =
        Message_layout.split_cells ~max_cells:inner_cells value
        |> List.map (fun part -> call_index, style, part)
      in
      List.concat_map
        (fun value_row -> header_rows @ [ value_row ] @ header_rows)
        value_rows
    in
    if Message_layout.display_width prefix < inner_cells then
      let body_cells = inner_cells - Message_layout.display_width prefix in
      let parts = Message_layout.split_cells ~max_cells:body_cells value in
      if
        List.for_all
          (fun part -> Message_layout.display_width part <= body_cells)
          parts
      then List.map (fun part -> call_index, style, prefix ^ part) parts
      else narrow_rows ()
    else
      (* On a narrow terminal the full field prefix may consume the framed
         width. Keeping it inline would make every value byte permanently
         unreachable after [box_line_styled] clips the row. Draw the exact
         call/field label on both sides of every value chunk so a two-row
         viewport never separates a continuation from its field context. *)
      narrow_rows ()
  in
  let rows =
    entries
    |> List.mapi (fun call_index (call : Masc.Tui_decode.keeper_call) ->
         let open Masc.Tui_decode in
         let glyph, style =
           if call.kc_success then ("✓", Ansi.reset)
           else ("✗", (Theme.bad ()))
         in
         let duration =
           match call.kc_duration_ms with
           | Some ms -> Masc_tui_acting.elapsed_text ms
           | None -> "-"
         in
         let turn =
           match call.kc_turn with Some value -> string_of_int value | None -> "-"
         in
         let summary =
           Printf.sprintf "  #%d %s %s · %s · turn %s"
             (call_index + 1)
             (Terminal_text.clock_timestamp
                (Masc_domain.iso8601_of_unix_seconds call.kc_at))
             glyph duration turn
         in
         let exact_rows =
           labeled_rows ~call_index ~style:Ansi.dim ~label:"tool" call.kc_tool
           @ labeled_rows ~call_index ~style:Ansi.dim ~label:"input" call.kc_input
         in
         let output_rows =
           match
             Option.bind call.kc_output (fun result ->
               Masc.Keeper_chat_tool_trail.tool_result_digest ~result)
           with
           | None -> []
           | Some digest ->
             labeled_rows ~call_index
               ~style:(if call.kc_success then Ansi.dim else (Theme.bad ()))
               ~label:"output" digest
         in
         (call_index, style, summary) :: exact_rows @ output_rows)
    |> List.concat
  in
  let total_rows = List.length rows in
  let max_scroll = max 0 (total_rows - content_height) in
  let scroll = max 0 (min state.keeper_calls_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      if state.keeper_calls_loading && Option.is_none state.keeper_calls then
        "  (loading exact call records...)"
      else
      match (state.keeper_calls, state.keeper_calls_error) with
      | _, Some _ -> page_failed_note
      | None, None -> page_unread_note
      | Some _, None -> "  (no calls recorded)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else begin
    let visible_rows =
      rows
      |> List.filteri (fun index _ ->
           index >= scroll && index < scroll + content_height)
    in
    List.iter
      (fun (_, style, text) -> box_line_styled buf cols ~style text)
      visible_rows;
    for _ = List.length visible_rows + 1 to content_height do
      box_empty buf cols
    done
  end;
  if scroll > 0 || total_rows > content_height then
    let last_visible = min total_rows (scroll + content_height) in
    let detailed_footer =
      Printf.sprintf "[%d calls · rows %d-%d of %d]" shown (scroll + 1)
        last_visible total_rows
    in
    let compact_footer =
      Printf.sprintf "[%d/%d]" (scroll + 1) total_rows
    in
    let footer =
      if Message_layout.display_width detailed_footer <= framed_inner_width cols
      then detailed_footer
      else compact_footer
    in
    box_line_styled buf cols ~style:(Theme.recede ())
      footer
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~clamped:(Keeper_calls scroll) ~surface_key:"keeper-calls" ~rows:terminal_rows ~cols buf

(* The runtime's event feed, newest first, for watching every keeper act at
   once. Rows are built from the events the TUI holds; the filter decides
   which kinds draw; a completed call is paired with its start for a
   duration. Scrolling away from the newest row freezes the view and counts
   what arrives above it, so an operator reading the past is not pushed off
   it by the present. *)
let render_acting_evidence (state : state) entry =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title " ACTING EVENT EVIDENCE");
  box_line_styled buf cols ~style:Ansi.dim " Selected event snapshot; new arrivals do not replace this reading";
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf " Retained feed events: %d (selection pinned)" (List.length state.acting));
  box_line_styled buf cols ~style:Ansi.dim
    (" " ^ Terminal_text.single_line (observer_replay_description state.observer_replay));
  box_divider buf cols;
  let lines =
    Masc_tui_acting.evidence_fields entry
    |> List.concat_map (fun (label, value) ->
        let prefix = "  " ^ label ^ ": " in
        let text = match value with
          | None -> "not carried"
          | Some "" -> "(empty string)"
          | Some value -> Terminal_text.single_line value in
        let continuation = String.make (Message_layout.display_width prefix) ' ' in
        match Message_layout.wrap_words
                ~max_cells:(max 1 (cols - 4 - Message_layout.display_width prefix)) text with
        | [] -> [prefix]
        | first :: rest -> (prefix ^ first) :: List.map (fun line -> continuation ^ line) rest)
  in
  let io_lines =
    match entry.Masc_tui_acting.ae_event with
    | Masc_tui_observer.Keeper_tool_call call ->
        let json label = function
          | None -> ["  " ^ label ^ ": not carried"]
          | Some value ->
              ("  " ^ label ^ " (producer-redacted JSON)")
              :: (document_markdown ~width:(max 1 (cols - 6))
                    ("```json\n" ^ Yojson.Safe.pretty_to_string value ^ "\n```")
                  |> List.map (fun line -> "  " ^ line)) in
        let preview label = function
          | None -> ["  " ^ label ^ ": not carried"]
          | Some text ->
              ("  " ^ label ^ " (producer-redacted preview)")
              :: (document_markdown ~width:(max 1 (cols - 6))
                    (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
                  |> List.map (fun line -> "  " ^ line)) in
        [""; "  INPUT / OUTPUT OBSERVATIONS"]
        @ json "Input" call.kt_tool_args
        @ preview "Input preview" call.kt_tool_args_preview
        @ json "Output" call.kt_tool_result
        @ preview "Output preview" call.kt_tool_output_preview
    | _ -> []
  in
  let lines = lines @ io_lines in
  let content_height = max 1 (rows - count_frame_lines buf - listing_rows_below_the_body) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = min max_scroll (max 0 state.acting_detail_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for i = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + i) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols line
  done;
  box_line_styled buf cols ~style:Ansi.dim (Printf.sprintf "  [%d evidence rows, scroll %d]" (List.length lines) scroll);
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
      ~hints:"j/k:scroll  PgUp/PgDn:page  Esc:back to events");
  finish_surface state ~clamped:(Acting_detail_scroll scroll)
    ~surface_key:"acting-evidence" ~rows:terminal_rows ~cols buf

let render_acting (state : state) =
  match state.acting_detail with
  | Some entry -> render_acting_evidence state entry
  | None ->
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let module Acting = Masc_tui_acting in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let held = List.length state.acting in
  (* The agent_core family names its runtime lane, not the keeper; the
     keeper is the one whose trace the event's correlation id carries. *)
  let traces =
    List.map (fun keeper -> (keeper.k_name, keeper.k_trace_id)) state.keepers
  in
  (* Visible entries, newest first, paired with the events older than each
     -- in a newest-first list, the tail after it -- so a completed call on
     the page can look up its start. Rows are built only for the page: the
     pairing walks the older events, and doing it for a thousand held
     entries on every frame is work the screen never shows. *)
  let visible =
    let rec walk acc = function
      | [] -> List.rev acc
      | entry :: older ->
          if Acting.visible state.acting_filter entry.Acting.ae_event then
            walk ((entry, older) :: acc) older
          else walk acc older
    in
    walk [] state.acting
  in
  let row_of (entry, older) =
    let event = entry.Acting.ae_event in
    let duration_ms =
      match event with
      | Masc_tui_observer.Agent_core
          ({ Masc_tui_observer.kind = Masc_tui_observer.Tool_completed; _ } as
           completed) ->
          Acting.duration_of_completion
            ~before:(List.map (fun e -> e.Acting.ae_event) older)
            completed
      | Masc_tui_observer.Agent_core _ | Masc_tui_observer.Keeper_heartbeat _
      | Masc_tui_observer.Keeper_tool_call _
      | Masc_tui_observer.Keeper_turn_complete _
      | Masc_tui_observer.Keeper_composite_changed _
      | Masc_tui_observer.Keeper_chat_appended _
      | Masc_tui_observer.Keeper_chat_stream_frame _
      | Masc_tui_observer.Keeper_waiting_inventory_changed _
      | Masc_tui_observer.Fusion_run_status _
      | Masc_tui_observer.Snapshot _
      | Masc_tui_observer.Other _ ->
          None
    in
    let row = Acting.row_of_entry ~duration_ms entry in
    { row with Acting.keeper = Acting.keeper_of_event ~traces event }
  in
  (* [Turns] folds the whole ring into per-turn rows; the flat filters keep
     the page-lazy pairing above. *)
  let chunked =
    match state.acting_filter with
    | Acting.Turns -> Some (Acting.chunk_rows ~traces state.acting)
    | Acting.Actions | Acting.Everything -> None
  in
  let shown =
    match chunked with
    | Some rows -> List.length rows
    | None -> List.length visible
  in
  let row_at idx =
    match chunked with
    | Some rows -> List.nth_opt rows idx
    | None -> Option.map row_of (List.nth_opt visible idx)
  in
  let feed =
    match state.observer with
    | Observer_off -> "feed: off"
    | Observer_opening -> "feed: opening"
    | Observer_live { events; _ } -> Printf.sprintf "feed: live %d" events
    | Observer_closed { events; reason; _ } ->
        Printf.sprintf "feed: closed after %d (%s)" events
          (Terminal_text.single_line reason)
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title
         (Printf.sprintf " MASC Activity  [1 Events* | 2 Logs] (%d of %d held, %s)" shown held
            (Acting.filter_label state.acting_filter)))
      timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let dropped =
    if state.acting_dropped = 0 then ""
    else Printf.sprintf "  dropped %d" state.acting_dropped
  in
  let undecodable =
    match state.acting_undecodable_last with
    | None -> ""
    | Some reason ->
        Printf.sprintf "  undecodable %d (last: %s)" state.acting_undecodable
          (Terminal_text.single_line reason)
  in
  let unseen =
    if state.acting_unseen = 0 then ""
    else Printf.sprintf "  %d new above (g)" state.acting_unseen
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  %s%s%s%s" feed dropped undecodable unseen);
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Terminal_text.single_line (observer_replay_description state.observer_replay));
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Acting.filter_explanation state.acting_filter);
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-16s %s %-16s %s" "Time" "Keeper" " " "Event"
      "Detail"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let cursor = max 0 (min state.acting_cursor (shown - 1)) in
  let scroll =
    let previous = max 0 (min state.acting_scroll max_scroll) in
    match state.acting_filter with
    | Acting.Turns -> previous
    | Actions | Everything ->
        if cursor < previous then cursor
        else if cursor >= previous + content_height then cursor - content_height + 1
        else previous
  in
  if shown = 0 then begin
    let empty =
      match state.observer with
      | Observer_off | Observer_opening -> "  (no events yet: the feed is not open)"
      | Observer_live _ ->
          if held = 0 then "  (no events yet)"
          else "  (nothing under this filter; f shows everything)"
      | Observer_closed _ ->
          if held = 0 then "  (the feed closed before any event arrived)"
          else "  (nothing under this filter; f shows everything)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match row_at idx with
      | None -> box_empty buf cols
      | Some row ->
          let style =
            match row.Acting.glyph with
            | Acting.Call_started -> (Theme.info ())
            | Acting.Call_returned -> (Theme.ok ())
            | Acting.Turn_boundary -> Ansi.reset
            | Acting.Turn_settled -> Ansi.bold
            | Acting.Failure -> (Theme.bad ())
            | Acting.Attention -> (Theme.warn ())
            | Acting.Quiet -> Ansi.dim
          in
          (* Every row carries the moment the TUI received it, so there is no
             longer a clockless row to draw a blank for. *)
          let clock =
            Terminal_text.clock_timestamp
              (Masc_domain.iso8601_of_unix_seconds row.Acting.at)
          in
          (* The Event column is sized for the two-word labels the taught
             events carry ("agent start", "waiting queue"). A type this build
             was not taught has no such label -- its name is all there is, and
             it is a wire identifier, so it ran off the column at every width:
             [approval:summar~], [transport_healt~]. Those rows have no detail
             either, so the label takes the empty column rather than the
             reader losing the only thing the row says. *)
          let detail = Terminal_text.single_line row.Acting.detail in
          let label = Terminal_text.single_line row.Acting.label in
          let line =
            if detail = "" then
              Printf.sprintf "  %-8s %-16s %s %s" clock
                (fit_width (Terminal_text.single_line row.Acting.keeper) 16)
                (Acting.glyph_text row.Acting.glyph)
                label
            else
              Printf.sprintf "  %-8s %-16s %s %-16s %s" clock
                (fit_width (Terminal_text.single_line row.Acting.keeper) 16)
                (Acting.glyph_text row.Acting.glyph)
                (fit_width label 16) detail
          in
          let selected = state.acting_filter <> Acting.Turns && idx = cursor in
          let line = if selected then "> " ^ String.sub line 2 (String.length line - 2) else line in
          box_line_styled buf cols ~style:(if selected then Theme.selection else style) line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d rows, scroll %d]" shown scroll)
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:select/scroll  Enter:evidence  g:newest  G:oldest  f:turns/actions/everything");
  let clamped = match state.acting_filter with
    | Acting.Turns -> Acting scroll
    | Actions | Everything -> Acting_selection (scroll, cursor) in
  finish_surface state ~clamped ~surface_key:"acting" ~rows:terminal_rows ~cols buf

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec
  in
  let sec_label = Masc_tui_types.metrics_section_label state.metrics_section in
  let title =
    Printf.sprintf "%s  [%s]  %s  %s"
      (screen_title " MASC Metrics & Performance Telemetry")
      sec_label timestamp (connection_badge state)
  in
  (* The section's lines are formatted by the drawing, so the row it could
     start at is known only once it has. The body writes it here and the
     contract reads it back out. *)
  let drawn_metrics_scroll = ref state.metrics_scroll in
  surface_chrome
    ~clamped:(fun () -> Some (Metrics_scroll !drawn_metrics_scroll))
    state ~terminal_rows ~cols ~surface_key:"metrics"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      Render_metrics.render_metrics_body ~cols ~budget state
        ~report_scroll:(fun scroll -> drawn_metrics_scroll := scroll)
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

(** Render the runtime picker: the dispatchable catalogue, with the keeper it
    is choosing for and where that keeper points today in the header. *)
let render_runtime_pick (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let keeper_name =
    Terminal_text.single_line_or ~default:"?" state.runtime_pick_keeper
  in
  let current =
    match
      List.find_opt
        (fun (a : Tui_decode.runtime_assignment) ->
          match state.runtime_pick_keeper with
          | Some keeper -> String.equal a.ra_keeper keeper
          | None -> false)
        state.runtime_assignments
    with
    | Some a ->
        Printf.sprintf "%s (%s)%s"
          (Terminal_text.single_line_or ~default:"-" a.ra_target_id)
          (Terminal_text.single_line a.ra_source)
          (match a.ra_unavailable_reason with
           | None -> ""
           | Some reason -> " — unavailable: " ^ Terminal_text.single_line reason)
    | None -> "-"
  in
  (* Only what a keeper can actually be pointed at. The catalogue also lists
     rows the dispatcher refuses; offering one would end in the server's
     rejection, so the picker does not draw them. *)
  let options =
    List.filter
      (fun (o : Tui_decode.runtime_option) -> o.ro_dispatchable)
      state.runtime_catalog
  in
  let count = List.length options in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %scurrent: %s%s"
       (screen_title
         (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 runtime" keeper_name))
       Ansi.dim current Ansi.reset);
  box_divider buf cols;
  (match Terminal_text.optional_single_line state.runtime_catalog_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  (catalogue unreliable: "
         ^ fit_width err (max 8 (cols - 28))
         ^ ")" ^ Ansi.reset)
   | None ->
       if count = 0 then
         box_line buf cols
           (Ansi.dim ^ "  (loading runtime catalogue\xe2\x80\xa6)" ^ Ansi.reset));
  let content_height = max 0 (rows - 7) in
  let scroll_offset =
    if content_height > 0 && state.runtime_pick_cursor >= content_height then
      state.runtime_pick_cursor - content_height + 1
    else 0
  in
  let options_window = Rows.of_list ~first:scroll_offset ~height:content_height options in
  for i = 0 to content_height - 1 do
    let idx = i + scroll_offset in
    match Rows.at options_window idx with
    | Some option ->
        let is_selected = idx = state.runtime_pick_cursor in
        let line =
          Printf.sprintf "  %s  %s%s"
            (fit_width (Terminal_text.single_line option.ro_id) 44)
            (fit_width
               (Terminal_text.single_line
                  (option.ro_provider ^ " / " ^ option.ro_model))
               (max 8 (cols - 56)))
            (if option.ro_is_default then " [default]" else "")
        in
        box_line buf cols
          (if is_selected then Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
           else "  " ^ line)
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf "%sj/k%s move  %senter%s assign  %sd%s back to default  esc cancel"
            (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset));
  finish_surface state ~surface_key:"runtime-pick" ~rows:terminal_rows ~cols
    buf

(* The Resources surface: the MCP resource inventory on the left, the
   selected read on the right. Wide terminals show both; narrow ones show
   the list, and Enter swaps to the content until Esc. *)

(* The Code surface: one directory level on the left, the opened file on the
   right. Entries come from the lazy /workspace/children route; the file is
   lexed once at load (masc_tui_code_lexer) and drawn as styled spans.
   fit_width measures cells past the SGR bytes and closes a cut style, so a
   long row truncates without bleeding colour into the margin. *)
(* The file pane's usable rows: top gap, title, divider, bottom gap, and
   the footer. One owner — the dispatch keeps the cursor visible against the
   same number the renderer draws with. *)
let code_pane_content_height (state : state) =
  let terminal_rows, _ = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  framed_content_height ~rows

let render_code (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  let list_rows_budget = framed_content_height ~rows in
  let entries = state.code_entries in
  let total = List.length entries in
  let cursor = max 0 (min state.code_cursor (total - 1)) in
  let span = lexed_span in
  let list_pane ~framed pane_buf pane_cols =
    (* Beside the file pane the box is the pane separator; alone on a narrow
       terminal it is the redundant outer frame every other surface dropped
       (same rule as keeper_detail_pane). *)
    let framed_top = if framed then framed_top else box_top in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.code_focus_file = Left_pane in
    let where = if String.equal state.code_dir "" then "/" else state.code_dir in
    (* Whose tree this is: a keeper workspace or a repository reads
       differently from the project's, and the same relative path exists in
       more than one of them. *)
    let where =
      match state.code_scope with
      | Code_scope_project -> where
      | Code_scope_keeper keeper -> keeper ^ " \xe2\x96\xb8 " ^ where
      | Code_scope_repo repo -> repo ^ " \xe2\x96\xb8 " ^ where
    in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim)
       ^ (if list_focused then " \xe2\x96\xb8 " else " ")
       ^ Terminal_text.single_line where
       ^ workspace_entries_count_label total
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    let status_rows =
      match state.code_entries_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          if total = 0 then begin
            framed_line pane_buf pane_cols
              (Ansi.dim ^ " (loading\xe2\x80\xa6)" ^ Ansi.reset);
            1
          end
          else 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    let entries_window = Rows.of_list ~first:first ~height:list_rows_budget entries in
    for i = 0 to list_rows_budget - 1 do
      match Rows.at entries_window (first + i) with
      | Some node ->
          let name =
            Terminal_text.single_line node.Masc.Tui_decode.wt_label
          in
          let selected = first + i = cursor in
          (* A folder keeps the "▸" it has always drawn; a file takes a
             type mark by extension. The colour is dropped on the selected
             row, where the selection band already owns the whole line and a
             mid-line reset would tear a hole in it.

             The folder mark takes the same slot as a code file, which is
             the cyan it always had: both were bright cyan to the byte until
             one of them started resolving through the theme and the other
             did not, leaving two cyans in one column. *)
          let marker =
            if node.Masc.Tui_decode.wt_has_children then
              if selected then "\xe2\x96\xb8 "
              (* The mark colour the files below it take. A folder is not a
                 kind of file, and the arrow already says which of the two
                 this row is. *)
              else (Theme.category Theme.Slot_1) ^ "\xe2\x96\xb8 " ^ Ansi.reset
            else
              let kind =
                File_icon.kind_of_name node.Masc.Tui_decode.wt_label
              in
              let glyph = File_icon.glyph kind in
              if selected then glyph ^ " "
              else
                let colour =
                  (* One colour for "this is a file mark". Which kind it is
                     belongs to the glyph, and the glyph already carries it --
                     seven kinds, seven distinct marks in File_icon.glyph.

                     Colour used to carry the kind, over four slots, and it
                     could not. Two reasons, both measured.

                     RFC-0431 measured the slot hues across every shipped
                     scheme: 0.0014 to 0.0044 apart in Oklab under
                     deuteranopia and protanopia, against the 0.024 a colour
                     has to clear to read as a distinction at all. About a
                     seventh of it. For roughly one reader in twelve the axis
                     was never splitting, whatever the slots held.

                     And it cost what it could not buy. write_two_panes joins
                     this listing to the content pane on one terminal row, and
                     that pane draws Theme.bad, ok, info and warn -- red,
                     green, cyan, yellow. Of the seven colours a theme names
                     that leaves blue and magenta, so a kind axis wider than
                     two was a status token to the byte on somebody's row.
                     #33477 caught red against bad, when a .png in the listing
                     drew the blame failure's escape beside it. #33722 caught
                     green against ok. Cyan against info and yellow against
                     warn were the same defect and outlived both, because the
                     test that was supposed to stop this named only bad and
                     ok.

                     Blue rather than magenta, because magenta already means
                     Verifying, microvm, EDIT, MEMO and two context readings
                     elsewhere, and one more meaning on it is the pile
                     RFC-0431 was opened to take apart.

                     Plain recedes rather than taking a constant [dim], so a
                     mark nobody classified still moves with the theme. *)
                  match kind with
                  | File_icon.Code | File_icon.Web | File_icon.Data
                  | File_icon.Prose | File_icon.Script | File_icon.Media ->
                    Theme.category Theme.Slot_1
                  | File_icon.Plain -> Theme.recede ()
                in
                colour ^ glyph ^ Ansi.reset ^ " "
          in
          let line =
            if selected then
              Theme.selection ^ " " ^ marker ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 7
                      - Message_layout.display_width (marker ^ name)))
                  ' '
              ^ Ansi.reset
            else " " ^ marker ^ name
          in
          framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane pane_buf pane_cols =
    let history_showing = state.code_history_open in
    let diff_showing = state.code_diff_open in
    let notes_showing = state.code_notes_open in
    let title =
      match Masc_tui_fetched.current_key state.code_file with
      | Some path ->
          let path = Terminal_text.single_line path in
          let path =
            (* Say the view is shifted; a pane that silently starts at
               column 41 reads as a file whose lines begin mid-word. *)
            if
              state.code_file_hscroll > 0 && not history_showing
              && not diff_showing && not notes_showing
            then
              Printf.sprintf "%s  (col %d)" path
                (state.code_file_hscroll + 1)
            else path
          in
          let base =
            if notes_showing then "notes: " ^ path
            else if diff_showing then "diff vs HEAD: " ^ path
            else if history_showing then "history: " ^ path
            else path
          in
          (* The note (a language-server answer, a PR link) rides the title
             in every view: the history's Enter writes one too. *)
          let with_note =
            match state.code_lsp_note with
            | Some note ->
                base ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                ^ Terminal_text.single_line note ^ Ansi.reset
            | None -> base
          in
          (* What the memo on the cursor's line says. The gutter already
             marks which rows carry one (RFC-0429 §3.1); a mark alone makes
             the reader open the list to learn what it marks. This rides the
             title for the same reason blame's status does: the margin is one
             cell wide and has no pane to speak in.

             Only where the body is the thing on screen. The overlays replace
             it, so under them the cursor's line is not drawn and the rider
             would caption a row nobody can see.

             No width arithmetic here: framed_line fits the title to the pane,
             which is the truncation §3.1 asks for. *)
          let with_note =
            if notes_showing || diff_showing || history_showing then with_note
            else
              let line = state.code_file_cursor + 1 in
              match
                List.find_opt
                  (fun found -> Masc_tui_memo.line_of found = line)
                  state.code_memos
              with
              | None -> with_note
              | Some (Masc_tui_memo.Memo_at (_, memo)) ->
                  let kind =
                    match Ide_memo.kind_word memo.Ide_memo.kind with
                    | None -> ""
                    | Some word -> " (" ^ word ^ ")"
                  in
                  with_note ^ "  "
                  ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                  ^ "memo "
                  ^ Terminal_text.single_line memo.Ide_memo.author
                  ^ kind ^ Ansi.reset ^ " "
                  ^ Terminal_text.single_line memo.Ide_memo.text
              | Some (Masc_tui_memo.Broken_at (_, why)) ->
                  with_note ^ "  " ^ Theme.bad () ^ "memo unreadable: "
                  ^ Terminal_text.single_line why ^ Ansi.reset
          in
          (* A blame that did not come back has no pane of its own to say so
             in -- the margin is beside the code, not instead of it -- so the
             refusal rides the title the way a language-server answer does.
             In the bad tone rather than the accent: this one is a failure. *)
          (* The margin has no pane of its own to speak in, so both the
             refusal and the wait ride the title. *)
          (match Masc_tui_fetched.current state.code_blame with
           | Some (_, Masc_tui_fetched.Failed detail) ->
               with_note ^ "  " ^ Theme.bad () ^ "blame: "
               ^ Terminal_text.single_line detail ^ Ansi.reset
           | Some (_, Masc_tui_fetched.Loading) ->
               with_note ^ "  " ^ Theme.recede () ^ "blame 읽는 중…" ^ Ansi.reset
           | Some (_, (Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent))
           | None -> with_note)
      | None -> "(Enter opens the selected file)"
    in
    box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.code_focus_file = Right_pane then Ansi.bold else Ansi.dim)
       ^ (if state.code_focus_file = Right_pane then " \xe2\x96\xb8 " else " ")
       ^ title
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = code_pane_content_height state in
    (if notes_showing then
       (* The memos are the file's own comments, so the overlay lists what
          the loaded rows hold in the file's comment syntax and has no
          reading state of its own. *)
       (* Read off the rows at load, so this is a lookup. Shown only while
          the file they came from is the loaded one: clearing the file
          leaves the field behind, and a list captioning bytes that are no
          longer on screen is worse than none. *)
       let memos =
         match Masc_tui_fetched.current state.code_file with
         | Some (_, Masc_tui_fetched.Ready _) -> state.code_memos
         | Some
             ( _
             , ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
               | Masc_tui_fetched.Failed _ ) )
         | None -> []
       in
       match memos with
       | [] ->
           box_line pane_buf pane_cols
             (Ansi.dim
             ^ "  (no memo in this file: a comment on its own row reading \
                masc(name): text)"
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | _ :: _ ->
           let total = List.length memos in
           let max_scroll = max 0 (total - content_height) in
           let scroll = max 0 (min state.code_notes_scroll max_scroll) in
           let memos_window = Rows.of_list ~first:scroll ~height:content_height memos in
           for i = 0 to content_height - 1 do
             match Rows.at memos_window (scroll + i) with
             | Some (Masc_tui_memo.Memo_at (line, memo)) ->
                 let kind =
                   match Ide_memo.kind_word memo.Ide_memo.kind with
                   | None -> ""
                   | Some word -> " (" ^ word ^ ")"
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%-6s%s %s%s%s%s  %s" Ansi.dim
                      (Printf.sprintf "L%d" line)
                      Ansi.reset
                      (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      (Terminal_text.single_line memo.Ide_memo.author)
                      kind Ansi.reset
                      (Terminal_text.single_line memo.Ide_memo.text))
             | Some (Masc_tui_memo.Broken_at (line, why)) ->
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%-6s%s %smemo unreadable: %s%s" Ansi.dim
                      (Printf.sprintf "L%d" line)
                      Ansi.reset (Theme.bad ())
                      (Terminal_text.single_line why)
                      Ansi.reset)
             | None -> box_empty pane_buf pane_cols
           done
     else if diff_showing then
       match Masc_tui_fetched.current state.code_diff with
       | Some (_, Masc_tui_fetched.Failed detail) ->
           box_line pane_buf pane_cols
             ((Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Loading) ->
           box_line pane_buf pane_cols
             (Ansi.dim ^ "  (reading the tree)" ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready diff) -> (
           match diff.Masc.Tui_decode.gd_rows with
           | [] ->
               box_line pane_buf pane_cols
                 (Ansi.dim
                 ^ (if diff.Masc.Tui_decode.gd_has_changes then
                      "  (the tree reports a change and sent no lines)"
                    else "  (this file matches its last commit)")
                 ^ Ansi.reset);
               for _ = 2 to content_height do
                 box_empty pane_buf pane_cols
               done
           | rows ->
               let total = List.length rows in
               let max_scroll = max 0 (total - content_height) in
               let scroll =
                 max 0 (min state.code_diff_scroll max_scroll)
               in
               let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
               (* An add or context row is the working tree's own line, so
                  the lexed row the pane already holds is its exact
                  colouring -- resolved by the row's new-line number, not by
                  matching text. A delete row is the old blob's content,
                  which was never lexed; it keeps the plain red band. Each
                  lexed segment's reset is followed by re-opening the diff
                  background, so the band survives the lexer's own resets. *)
               let lexed_rows =
                 match Masc_tui_fetched.current state.code_file with
                 | Some (_, Masc_tui_fetched.Ready file_rows) ->
                     Rows.of_array file_rows
                 | Some (_, _) | None -> Rows.of_array [||]
               in
               let lexed_line index = Rows.at lexed_rows (index - 1) in
               for i = 0 to content_height - 1 do
                 match Rows.at rows_window (scroll + i) with
                 | Some row ->
                     let open Masc.Tui_decode in
                     let gutter =
                       Printf.sprintf "  %s %s %s "
                         (Diff.line_number_cell row.gdr_old_line)
                         (Diff.line_number_cell row.gdr_new_line)
                         (match row.gdr_kind with
                          | Gd_removed -> "-"
                          | Gd_added -> "+"
                          | Gd_context -> " ")
                     in
                     let lexed =
                       match row.gdr_kind, row.gdr_new_line with
                       | (Gd_added | Gd_context), Some line ->
                           lexed_line line
                       | _ -> None
                     in
                     let body =
                       match lexed with
                       | Some segments -> (
                           match row.gdr_kind with
                           | Gd_added ->
                               let bg = Theme.Syntax.diff_added_bg in
                               bg
                               ^ String.concat ""
                                   (List.map
                                      (fun segment ->
                                        span segment ^ bg)
                                      segments)
                               ^ Ansi.reset
                           | Gd_context | Gd_removed ->
                               String.concat "" (List.map span segments))
                       | None -> (
                           let text =
                             Terminal_text.single_line row.gdr_text
                           in
                           match row.gdr_kind with
                           | Gd_removed ->
                               Theme.Syntax.diff_removed_bg ^ text
                               ^ Ansi.reset
                           | Gd_added ->
                               Theme.Syntax.diff_added_bg ^ text ^ Ansi.reset
                           | Gd_context -> Ansi.dim ^ text ^ Ansi.reset)
                     in
                     box_line pane_buf pane_cols
                       (Ansi.dim ^ gutter ^ Ansi.reset ^ body)
                 | None -> box_empty pane_buf pane_cols
               done)
     else if history_showing then
       (* "(loading history)" used to be what an unasked overlay said as well
          as a reading one. Now it is only the reading one. *)
       match Masc_tui_fetched.current state.code_history with
       | Some (_, Masc_tui_fetched.Failed detail) ->
           box_line pane_buf pane_cols
             ((Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Loading) ->
           box_line pane_buf pane_cols
             (Ansi.dim ^ "  (loading history)" ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready { chl_entries = []; chl_activity_note }) ->
           box_line pane_buf pane_cols
             (Ansi.dim
              ^ "  (no commit or exact Keeper change touches this file)"
              ^ Ansi.reset);
           box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
             ("  " ^ Terminal_text.single_line chl_activity_note);
           for _ = 3 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready { chl_entries; chl_activity_note }) ->
           box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
             ("  " ^ Terminal_text.single_line chl_activity_note);
           let list_height = max 1 (content_height - 1) in
           let total = List.length chl_entries in
           let max_scroll = max 0 (total - list_height) in
           let scroll = max 0 (min state.code_history_scroll max_scroll) in
           let chl_entries_window = Rows.of_list ~first:scroll ~height:list_height chl_entries in
           let at_of ms =
             let t = Unix.localtime (ms /. 1000.) in
             Printf.sprintf "%02d-%02d %02d:%02d" (t.Unix.tm_mon + 1)
               t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
           in
           for i = 0 to list_height - 1 do
             match Rows.at chl_entries_window (scroll + i) with
             | Some (Hist_keeper_change change) ->
                 let open Masc.Tui_decode in
                 (* File-change rows carry Unix seconds; git history carries
                    epoch milliseconds. [at_of] takes the latter because the
                    two kinds are sorted in that unit too. *)
                 let at = at_of (change.fc_at *. 1000.) in
                 let anchor =
                   Option.value ~default:"L?"
                     (file_change_evidence_label change.fc_line_evidence)
                 in
                 let kind =
                   match change.fc_kind with
                   | Fc_edited _ -> "EDIT"
                   | Fc_inserted _ -> "MEMO"
                   | Fc_written _ -> "WRITE"
                 in
                 let result_style, result =
                   if change.fc_succeeded
                   then Theme.ok (), "✓"
                   else Theme.bad (), "✗"
                 in
                 let provenance =
                   [ Option.map (fun task -> "task " ^ task) change.fc_task_id
                   ; Option.map
                       (fun turn -> Printf.sprintf "turn %d" turn)
                       change.fc_turn
                   ; Option.map (fun id -> "exec " ^ id) change.fc_execution_id
                   ]
                   |> List.filter_map Fun.id
                   |> String.concat " · "
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf
                      "  %s%s%s  %s%s%s  %s%s%s %-5s  %s%s%s  %s"
                      Ansi.dim at Ansi.reset Ansi.dim (fit_width anchor 12)
                      Ansi.reset result_style result Ansi.reset kind (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      (Terminal_text.single_line change.fc_keeper)
                      Ansi.reset
                      (Terminal_text.single_line provenance))
             | Some (Hist_commit row) ->
                 let open Masc.Tui_decode in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%s%s  %s%s%s  %s  %s" Ansi.dim
                      (at_of row.gl_at_ms) Ansi.reset
                      (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      row.gl_hash Ansi.reset
                      (Terminal_text.single_line row.gl_author)
                      (Terminal_text.single_line row.gl_subject))
             | None -> box_empty pane_buf pane_cols
           done
     else
       (* A blank pane used to mean three things: no file open, a file being
          read, and a file that failed to read. Two of them now say so. *)
       let say style text =
         box_line pane_buf pane_cols
           (style ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset);
         for _ = 2 to content_height do
           box_empty pane_buf pane_cols
         done
       in
       match Masc_tui_fetched.current state.code_file with
       | Some (_, Masc_tui_fetched.Failed detail) -> say (Theme.bad ()) detail
       | Some (path, Masc_tui_fetched.Loading) ->
           say (Theme.recede ()) (path ^ " 읽는 중…")
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (open_path, Masc_tui_fetched.Ready file_rows) ->
           let total_lines = Array.length file_rows in
           let max_scroll = max 0 (total_lines - content_height) in
           let scroll = max 0 (min state.code_file_scroll max_scroll) in
           let hscroll =
             max 0
               (min state.code_file_hscroll
                  (max 0 (state.code_file_max_width - 1)))
           in
           (* Which lines carry a note or a durable Keeper change -- only what
              is already loaded (m or H has been opened for this file); the
              pane does not fetch merely to decorate. *)
           let matches_open_file loaded_path =
             match Masc_tui_fetched.current_key state.code_file with
             | Some open_path -> String.equal loaded_path open_path
             | None -> false
           in
           let note_spans =
             List.map
               (fun found ->
                 let line = Masc_tui_memo.line_of found in
                 (line, line))
               state.code_memos
           in
           let keeper_spans =
             match Masc_tui_fetched.current state.code_history with
             | Some ((_, loaded_path), Masc_tui_fetched.Ready listing)
               when matches_open_file loaded_path ->
                 List.concat_map
                   (function
                     | Hist_keeper_change change ->
                       List.map
                         (fun range -> (range.Masc.Keeper_file_change_evidence.start_line,
                           range.end_line))
                         (file_change_ranges change)
                     | Hist_commit _ -> [])
                   listing.chl_entries
             | _ -> []
           in
           let covers line spans =
             List.exists (fun (a, b) -> line >= a && line <= b) spans
           in
           (* Who last touched each run, when [b] has read it for this file.
              Same rule as the two span lists above: the pane decorates what
              is loaded and does not fetch to decorate. *)
           let blame_blocks =
             match Masc_tui_fetched.current state.code_blame with
             | Some (loaded_path, Masc_tui_fetched.Ready blocks)
               when matches_open_file loaded_path -> blocks
             | Some _ | None -> []
           in
           let blame_now_s = Unix.gettimeofday () in
           (* One name per run, not one per line: the run boundary is the fact
              worth drawing, and repeating the author down every line of a
              block is what hides it. Continuation rows hold the same cells in
              blanks so the code stays in one column.

              No colour of its own. The theme's three tones are Normal, Dim
              and the single accent, and a colour outside them is a claim
              about state -- blame carries no state, only who and when. So
              the answer (the name) draws Normal and the qualifier (the age)
              draws Dim, and nothing here competes with the lexer's own
              colours in the code beside it. *)
           let blame_cell line =
             match blame_blocks with
             | [] -> ""
             | _ -> (
               match Masc.Tui_decode.blame_block_at blame_blocks line with
               | Some (block, true) ->
                   Printf.sprintf "%s%s %s%s%s "
                     (Masc_tui_theme.tone Masc_tui_theme.Normal)
                     (Message_layout.fit_width block.bb_author
                        blame_author_cells)
                     Ansi.dim
                     (Message_layout.fit_width
                        (blame_age_text ~now_s:blame_now_s block.bb_at_ms)
                        blame_age_cells)
                     Ansi.reset
               | Some (_, false) | None -> String.make blame_margin_cells ' ')
           in
           let file_rows_window = Rows.of_array file_rows in
           for i = 0 to content_height - 1 do
             match Rows.at file_rows_window (scroll + i) with
             | Some segments ->
                 let body =
                   String.concat "" (List.map span segments)
                 in
                 (* The gutter stays put; only the code scrolls sideways. *)
                 let body = Message_layout.drop_cells body hscroll in
                 let row_index = scroll + i in
                 let gutter_style =
                   (* The cursor line carries the gutter in reverse video:
                      a full-row band would sit on top of the lexer's own
                      colours, and the gutter is the row's stable margin. *)
                   if row_index = state.code_file_cursor then Ansi.reverse
                   else Ansi.dim
                 in
                 let mark =
                   let line = row_index + 1 in
                   if covers line note_spans then
                     (Masc_tui_theme.tone Masc_tui_theme.Accent)
                     ^ "\xe2\x97\x8f" ^ Ansi.reset
                   else if covers line keeper_spans then Ansi.dim ^ "\xc2\xb7" ^ Ansi.reset
                   else " "
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "%s%s%s%4d%s %s"
                      (blame_cell (row_index + 1))
                      mark gutter_style (row_index + 1) Ansi.reset body)
             | None -> box_empty pane_buf pane_cols
           done;
           (* A file pane without a position is a corridor without doors:
              the same "rows X-Y of Z" line the reading surfaces carry. The
              fetched-match closes with this loop's done-paren, so the line
              belongs inside the arm, before box_bottom draws for every
              arm. *)
           if total_lines > content_height then
             box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
               (Printf.sprintf "lines %d-%d of %d" (scroll + 1)
                  (min total_lines (scroll + content_height))
                  total_lines));
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.code_focus_file = Right_pane then content_pane buf cols
   else list_pane ~framed:false buf cols);
  let code_pane =
    if state.code_focus_file <> Right_pane then Masc_tui_keys.Code_tree
    else if
      state.code_history_open || state.code_diff_open || state.code_notes_open
    then Masc_tui_keys.Code_overlay
    else Masc_tui_keys.Code_file
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_code ~pane:code_pane));
  finish_surface state ~surface_key:"code" ~rows:terminal_rows ~cols buf

let resource_mime_essence mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | essence :: _ -> String.trim essence
  | [] -> ""

let resource_language_of_mime mime =
  let mime = resource_mime_essence mime in
  if
    String.equal mime "application/json"
    || String.equal mime "text/json"
    || String.ends_with ~suffix:"+json" mime
  then Some "json"
  else if List.mem mime [ "application/toml"; "text/toml"; "text/x-toml" ]
  then Some "toml"
  else if
    List.mem mime
      [ "application/yaml"; "application/x-yaml"; "text/yaml"; "text/x-yaml" ]
  then Some "yaml"
  else None

let resource_mime_is_markdown mime =
  List.mem (resource_mime_essence mime)
    [ "text/markdown"; "text/x-markdown"; "application/markdown" ]

let pretty_resource_text ~mime text =
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> fenced_document_text ~language text
  | None when resource_mime_is_markdown mime -> text
  | None -> text

let resource_document (resource : Masc_tui_mcp.resource)
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested =
  let present = function
    | Some text when String.trim text <> "" -> text
    | Some _ | None -> "not supplied"
  in
  let size =
    match resource.size with
    | Some bytes -> Printf.sprintf "%d bytes" bytes
    | None -> "size unknown"
  in
  let mime = present resource.mime_type in
  let metadata =
    String.concat "\n\n"
      [ "MCP resource — read-only data exposed by this server."
      ; "**About:** " ^ present resource.description
      ; "**URI:** `" ^ resource.uri ^ "`"
      ; "**Name:** " ^ resource.name
      ; "**Type:** `" ^ mime ^ "` · **Size:** " ^ size
      ]
  in
  let part_document index (part : Masc_tui_mcp.resource_content) =
    let part_mime = Option.value part.rc_mime_type ~default:mime in
    let body =
      match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
          pretty_resource_text ~mime:part_mime text
      | Masc_tui_mcp.Resource_blob { base64_bytes } ->
          Printf.sprintf
            "Binary data · `%s` · %d base64 bytes · preview unavailable"
            part_mime base64_bytes
    in
    match contents with
    | Some (_ :: _ :: _) ->
        Printf.sprintf "### Part %d · %s\n\n%s" index part_mime body
    | Some (_ :: []) | Some [] | None -> body
  in
  let body =
    match (error, contents) with
    | Some detail, _ -> "**Read failed:** " ^ detail
    | None, None when requested -> "(reading resource…)"
    | None, None -> "(Enter reads the selected resource.)"
    | None, Some parts ->
        parts |> List.mapi (fun index part -> part_document (index + 1) part)
        |> String.concat "\n\n"
  in
  metadata ^ "\n\n---\n\n" ^ body

let render_resources (state : state) =
  let drawn_resource_scroll = ref state.resource_scroll in
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  let list_rows_budget = framed_content_height ~rows in
  let rows_list =
    match state.resources_list with Some rows -> rows | None -> []
  in
  let total = List.length rows_list in
  let cursor = max 0 (min state.resources_cursor (total - 1)) in
  let list_pane ~framed pane_buf pane_cols =
    (* Same rule as the code surface: beside the content pane the box is the
       pane separator; alone on a narrow terminal it is the redundant outer
       frame every other surface dropped. *)
    let framed_top = if framed then framed_top else box_top in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.resource_focus = Left_pane in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim)
       ^ (if list_focused then " \xe2\x96\xb8 " else " ")
       ^ "Resources"
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    let status_rows =
      match state.resources_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          if total = 0 then begin
            framed_line pane_buf pane_cols
              (Ansi.dim ^ " (loading\xe2\x80\xa6)" ^ Ansi.reset);
            1
          end
          else 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    let rows_list_window = Rows.of_list ~first:first ~height:list_rows_budget rows_list in
    for i = 0 to list_rows_budget - 1 do
      match Rows.at rows_list_window (first + i) with
      | Some resource ->
          let selected = first + i = cursor in
          let name = Masc_tui_mcp.display_name resource in
          let line =
            if selected then
              Theme.selection ^ " " ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 5 - Message_layout.display_width name))
                  ' '
              ^ Ansi.reset
            else " " ^ name
          in
          framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane pane_buf pane_cols =
    let selected_resource = List.nth_opt rows_list cursor in
    let error_uri = Option.map fst state.resource_content_error in
    let content_uri = Option.map fst state.resource_content in
    let shown_uri =
      match state.resource_pending_uri, error_uri, content_uri with
      | Some uri, _, _ -> Some uri
      | None, Some uri, _ -> Some uri
      | None, None, Some uri -> Some uri
      | None, None, None -> Option.map (fun resource -> resource.Masc_tui_mcp.uri) selected_resource
    in
    let shown_resource =
      Option.bind shown_uri (fun uri ->
          List.find_opt
            (fun (resource : Masc_tui_mcp.resource) ->
               String.equal resource.uri uri)
            rows_list)
    in
    let title =
      match shown_resource with
      | Some resource -> "Resource · " ^ Masc_tui_mcp.display_name resource
      | None -> "Resource detail"
    in
    box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.resource_focus = Right_pane then Ansi.bold else Ansi.dim)
       ^ (if state.resource_focus = Right_pane then " \xe2\x96\xb8 " else " ")
       ^ title
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = framed_content_height ~rows in
    (match shown_resource with
     | None ->
         for _ = 1 to content_height do
           box_empty pane_buf pane_cols
         done
     | Some resource ->
         let contents =
           match state.resource_content, shown_uri with
           | Some (content_uri, parts), Some uri
             when String.equal content_uri uri -> Some parts
           | Some _, (Some _ | None) | None, _ -> None
         in
         let error =
           match state.resource_content_error, shown_uri with
           | Some (error_uri, detail), Some uri
             when String.equal error_uri uri -> Some detail
           | Some _, (Some _ | None) | None, _ -> None
         in
         let requested =
           match state.resource_pending_uri, shown_uri with
           | Some pending_uri, Some uri -> String.equal pending_uri uri
           | Some _, None | None, _ -> false
         in
         let rendered =
           Message_layout.wrap_body ~markdown:document_markdown
             ~max_cells:(max 1 (pane_cols - 8))
             ~sanitize:Terminal_text.single_line
             (resource_document resource contents ~error ~requested)
         in
         let total_lines = List.length rendered in
         let max_scroll = max 0 (total_lines - content_height) in
         let scroll = max 0 (min state.resource_scroll max_scroll) in
         let rendered_window = Rows.of_list ~first:scroll ~height:content_height rendered in
         (* The pane is the only place that knows how many rows the text
            actually used, so it reports the row it could draw back out. *)
         drawn_resource_scroll := scroll;
         for i = 0 to content_height - 1 do
           match Rows.at rendered_window (scroll + i) with
           | Some line -> box_line pane_buf pane_cols ("  " ^ line)
           | None -> box_empty pane_buf pane_cols
         done);
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.resource_focus = Right_pane then content_pane buf cols
   else list_pane ~framed:false buf cols);
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_resources
            ~detail_focus:(state.resource_focus = Right_pane)));
  finish_surface state ~clamped:(Resource_scroll !drawn_resource_scroll)
    ~surface_key:"resources" ~rows:terminal_rows ~cols buf

(* How long ago the running binary's commit landed. Coarse on purpose: the
   question is "is this the build I think it is", and minutes answer it while
   seconds only look precise. *)
let binary_age_text = function
  | None -> "age unknown"
  | Some seconds when seconds < 60. -> "built just now"
  | Some seconds when seconds < 3600. ->
      Printf.sprintf "built %.0fm ago" (seconds /. 60.)
  | Some seconds when seconds < 86400. ->
      Printf.sprintf "built %.0fh ago" (seconds /. 3600.)
  | Some seconds -> Printf.sprintf "built %.0fd ago" (seconds /. 86400.)

(* The Runtime_params registry. A view, not a second place values live:
   overrides are written by the server to .masc/runtime_params.json, and this
   shows what is there beside what it would be without them.

   runtime.toml sits in the pane next door and answers a different question --
   which runtimes and lanes exist. One value claimed by two files is how "I set
   it and it did not take" happens, so these stay two panes over one store. *)
let render_runtime_params (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Config")
       (config_pane_strip state)
       (connection_badge state));
  (match state.runtime_params_notice with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ())
       "  Enter edits by type · E is advanced JSON · overrides persist in .masc/runtime_params.json"
   | Some (ok, detail) ->
     box_line_styled buf cols ~style:(if ok then Theme.ok () else Theme.bad ())
       ("  " ^ Terminal_text.single_line detail));
  let selected = List.nth_opt state.runtime_params state.runtime_params_cursor in
  let selected_contract =
    match selected with
    | None -> "  Select a row to see its contract"
    | Some row ->
      let open Tui_decode in
      let type_name =
        if String.trim row.rpr_value_type = "" then "typed value"
        else row.rpr_value_type
      in
      let bounds =
        [ Option.map (fun value -> "min " ^ value) row.rpr_min_json
        ; Option.map (fun value -> "max " ^ value) row.rpr_max_json
        ]
        |> List.filter_map Fun.id
        |> String.concat " · "
      in
      String.concat " · "
        (List.filter (fun text -> String.trim text <> "")
           [ "  " ^ type_name; bounds; row.rpr_description ])
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (fit_width (Terminal_text.single_line selected_contract) (max 1 (cols - 1)));
  box_divider buf cols;
  let editing = Option.is_some state.runtime_param_edit in
  (* Editing adds a divider and two form rows.  Spend those rows out of the
     list budget so the footer remains visible instead of falling underneath
     the always-present composer. *)
  let content_height = max 1 (rows - (if editing then 10 else 7)) in
  let count = List.length state.runtime_params in
  let cursor = max 0 (min state.runtime_params_cursor (count - 1)) in
  (match state.runtime_params_error with
   | Some detail ->
     box_line buf cols ((Theme.bad ()) ^ "설정을 읽지 못했습니다: " ^ Ansi.reset
                        ^ Terminal_text.single_line detail);
     for _ = 2 to content_height do box_empty buf cols done
   | None ->
     if state.runtime_params_loading && state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  (loading runtime parameters…)" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
     end
     else if state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  등록된 설정 없음" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
     end else begin
       (* Rows arrive in registry-group order (Tui_decode sorts them by
          surface). Headers are lines on this screen, not decoration outside it:
          they are built into the same list the window scrolls over, so a group
          heading costs a row from [content_height] instead of pushing the last
          param off the bottom.

          The cursor stays an index into [state.runtime_params] — key handling
          and the edit target read it — so the window is positioned by where
          that row lands in the display list. *)
       let unfiled_description =
         "그룹 없음 — 레지스트리가 이 param 을 어느 surface 에도 넣지 않았습니다"
       in
       let surface_of (row : Tui_decode.runtime_param_row) =
         match row.Tui_decode.rpr_surface with
         | Some s -> (s.Tui_decode.rps_id, s.Tui_decode.rps_description)
         | None -> ("", unfiled_description)
       in
       let display =
         let rec build previous index acc = function
           | [] -> List.rev acc
           | row :: rest ->
             let id, description = surface_of row in
             let acc =
               match previous with
               | Some prev when String.equal prev id -> acc
               | Some _ | None -> `Header (id, description) :: acc
             in
             build (Some id) (index + 1) (`Row (index, row) :: acc) rest
         in
         build None 0 [] state.runtime_params
       in
       let cursor_display =
         let rec find index = function
           | [] -> 0
           | `Row (row_index, _) :: _ when row_index = cursor -> index
           | _ :: rest -> find (index + 1) rest
         in
         find 0 display
       in
       let total = List.length display in
       let first =
         if total <= content_height then 0
         else if cursor_display < content_height then 0
         else min (total - content_height) (cursor_display - content_height + 1)
       in
       let display_window = Rows.of_list ~first:first ~height:content_height display in
       for index = 0 to content_height - 1 do
         match Rows.at display_window (first + index) with
         | None -> box_empty buf cols
         | Some (`Header (id, description)) ->
           let label = if String.equal id "" then "(unfiled)" else id in
           box_line_styled buf cols
             ~style:(Masc_tui_theme.tone Masc_tui_theme.Accent)
             (Printf.sprintf "  %s %s"
                (Terminal_text.single_line label)
                (Ansi.dim ^ Terminal_text.single_line description ^ Ansi.reset))
         | Some (`Row (row_index, row)) ->
           let open Tui_decode in
           let line =
             Printf.sprintf "    %s %-41s %-16s%s"
               (if row.rpr_has_override then "\xe2\x97\x8f" else "\xe2\x97\x8b")
               (Terminal_text.single_line row.rpr_key)
               (Terminal_text.single_line
                  (runtime_param_value_text ~value_type:row.rpr_value_type
                     row.rpr_current_json))
               (if row.rpr_has_override
                then Printf.sprintf "  default %s"
                       (Terminal_text.single_line
                          (runtime_param_value_text
                             ~value_type:row.rpr_value_type
                             row.rpr_default_json))
                else "")
           in
           if row_index = cursor then box_line_selected buf cols line
           else
             box_line_styled buf cols
               ~style:(if row.rpr_has_override then (Masc_tui_theme.tone Masc_tui_theme.Accent) else Ansi.dim) line
       done
     end);
  (match state.runtime_param_edit with
   | None -> ()
   | Some edit ->
     let friendly_bool =
       edit.rpe_mode = Friendly_value
       && List.mem (runtime_param_type_name edit.rpe_value_type)
            [ "bool"; "boolean" ]
     in
     (* A param with a closed set is walked the way a bool is toggled — the
        reader is choosing, not typing — so both draw as a choice. *)
     let friendly_choice =
       edit.rpe_mode = Friendly_value && edit.rpe_choices <> []
     in
     let picking = friendly_bool || friendly_choice in
     let field_label =
       match edit.rpe_mode with
       | Advanced_json -> "JSON>"
       | Friendly_value when picking -> "choice>"
       | Friendly_value -> "value>"
     in
     let draft = Terminal_text.single_line edit.rpe_draft in
     let draft =
       if edit.rpe_replace_on_type && not picking
       then Theme.selection ^ draft ^ Ansi.reset
       else draft
     in
     box_divider buf cols;
     box_line buf cols
       (Printf.sprintf "  %s%s%s %s" Ansi.bold field_label Ansi.reset
          (fit_width draft (max 1 (cols - 12))));
     box_line_styled buf cols ~style:(Theme.recede ())
       (Printf.sprintf "  editing %s · %s"
          (Terminal_text.single_line edit.rpe_key)
          (match edit.rpe_mode with
           | Advanced_json -> "advanced JSON · Enter apply · Esc cancel"
           | Friendly_value when friendly_bool ->
             "Left/Right/Space toggle · Enter apply · Esc cancel"
           | Friendly_value when friendly_choice ->
             (* The set is spelled out: a reader walking it one key at a time
                cannot otherwise see how many values there are, or that a form
                they can type by hand exists beside them. *)
             Printf.sprintf
               "Left/Right/Space cycle (%s) · Enter apply · Esc cancel"
               (String.concat " · " edit.rpe_choices)
           | Friendly_value ->
             "type to replace · Enter apply · Esc cancel")));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (match state.runtime_param_edit with
          | Some edit
            when edit.rpe_mode = Friendly_value
                 && List.mem (runtime_param_type_name edit.rpe_value_type)
                      [ "bool"; "boolean" ] ->
            "Left/Right/Space:toggle  Enter:apply  Esc:cancel"
          | Some edit
            when edit.rpe_mode = Friendly_value && edit.rpe_choices <> [] ->
            "Left/Right/Space:cycle  Enter:apply  Esc:cancel"
          | Some { rpe_mode = Friendly_value; _ } ->
            "type:value  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | Some { rpe_mode = Advanced_json; _ } ->
            "type JSON  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | None ->
            "j/k:select  Enter/e:edit  E:advanced JSON  x:default  p:next"));
  finish_surface state ~surface_key:"config-params" ~rows:terminal_rows ~cols buf
;;

let render_prompt_registry (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let prompt_rows =
    match prompts with
    | Masc_tui_fetched.Ready snapshot ->
        Tui_decode.prompt_rows_for_operator
          ~show_fragments:state.prompts_show_fragments snapshot
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ ->
        []
  in
  let all_prompt_count =
    match prompts with
    | Masc_tui_fetched.Ready snapshot -> List.length snapshot.Tui_decode.ps_rows
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ -> 0
  in
  (* Overrides the registry declined to restore. A held-back key still draws
     from its file, so without this it renders exactly like a prompt nobody
     ever customized -- which is how an operator loses an override without
     learning they lost it. *)
  let held_back =
    match prompts with
    | Masc_tui_fetched.Ready snapshot -> snapshot.Tui_decode.ps_held_back
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
    | Masc_tui_fetched.Failed _ -> []
  in
  let held_back_for key =
    List.find_opt
      (fun (entry : Tui_decode.held_back_override) ->
        String.equal entry.Tui_decode.hbo_key key)
      held_back
  in
  let total = List.length prompt_rows in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt prompt_rows cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d/%d개 · %s%s%s  %s  %s"
       (screen_title " MASC 프롬프트")
       Ansi.dim total all_prompt_count
       (if state.prompts_show_fragments then "내부 조각 포함" else "주 프롬프트")
       Ansi.reset
       (match held_back with
        | [] -> ""
        | entries ->
          Printf.sprintf "  %s적용 안 된 오버라이드 %d개%s" (Theme.warn ())
            (List.length entries) Ansi.reset)
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row =
    match prompts with
    | Masc_tui_fetched.Ready _ -> None
    | Masc_tui_fetched.Absent -> None
    | Masc_tui_fetched.Loading -> Some ((Theme.recede ()), "프롬프트 목록을 읽는 중…")
    | Masc_tui_fetched.Failed detail ->
      Some ((Theme.bad ()), Terminal_text.single_line detail)
  in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let notice_rows = match selected with
    | None -> 0
    | Some row ->
        (if Option.is_some (held_back_for row.Tui_decode.pr_key) then 3 else 0)
        + (if row.pr_override_default_moved then 1 else 0)
  in
  let combined_height = max 2 (rows - 9 - error_rows - notice_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (cols - 6) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (row : Tui_decode.prompt_row) ->
      if index >= first && index < first + list_height then begin
        incr drawn;
        let mark =
          (* Held back outranks the source, which reads [Prompt_file] for
             exactly these rows: the file is what a turn gets, and saying so
             is what hides the override the reader still has on disk. *)
          match held_back_for row.Tui_decode.pr_key, row.Tui_decode.pr_source with
          | Some _, _ -> (Theme.bad ()) ^ "\xe2\x8a\x98" ^ Ansi.reset
          | None, Tui_decode.Prompt_override -> (Theme.warn ()) ^ "*" ^ Ansi.reset
          | None, Tui_decode.Prompt_file -> " "
          | None, Tui_decode.Prompt_missing -> (Theme.bad ()) ^ "!" ^ Ansi.reset
        in
        let category =
          match row.Tui_decode.pr_category with
          | "keeper" -> "키퍼"
          | "librarian" -> "기억"
          | "verification" -> "검증"
          | "judge" -> "판정"
          | "general" -> "일반"
          | category -> Terminal_text.single_line category
        in
        let surface =
          match row.Tui_decode.pr_operator_surface with
          | Tui_decode.Prompt_primary -> ""
          | Tui_decode.Prompt_fragment -> "조각"
        in
        let label =
          Printf.sprintf "%s %-4s %-4s %s  %s"
            mark
            (fit_width category 4)
            surface
            (fit_width (Terminal_text.single_line row.Tui_decode.pr_key) 30)
            (Ansi.dim
             ^ fit_width
                 (Terminal_text.single_line row.Tui_decode.pr_description)
                 (max 4 (cols - 52))
             ^ Ansi.reset)
        in
        if index = cursor then
          box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    prompt_rows;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  (match selected with
   | None ->
       box_line_styled buf cols ~style:(Theme.recede ()) "  선택한 프롬프트가 없습니다";
       box_line_styled buf cols ~style:(Theme.recede ()) "  입력 계약을 표시할 수 없습니다";
       box_divider buf cols;
       for _ = 1 to detail_height do
         box_empty buf cols
       done
   | Some row ->
       let source =
         match row.Tui_decode.pr_source with
         | Tui_decode.Prompt_override -> "override 사용 · MD는 기본값"
         | Tui_decode.Prompt_file -> "MD 파일 사용"
         | Tui_decode.Prompt_missing -> "없음"
       in
       box_line buf cols
         (Printf.sprintf "  선택: %s \xc2\xb7 %s \xc2\xb7 %s"
            (Terminal_text.single_line row.pr_key)
            (Terminal_text.single_line source)
            (Terminal_text.single_line row.pr_file_path));
       (* Two facts an operator needs and cannot get anywhere else: the
          override is still on disk, and re-saving it is what puts it back in
          force. Without the second line the mark says something is wrong and
          leaves the reader with no move. *)
       (match held_back_for row.Tui_decode.pr_key with
        | None -> ()
        | Some entry ->
          box_line buf cols
            (Printf.sprintf "  %s\xe2\x8a\x98 적용 안 됨%s  저장된 오버라이드 %d바이트가 그대로 있습니다"
               (Theme.bad ()) Ansi.reset entry.Tui_decode.hbo_bytes);
          box_line_styled buf cols ~style:(Theme.recede ())
            ("  " ^ Terminal_text.single_line entry.Tui_decode.hbo_reason);
          box_line_styled buf cols ~style:(Theme.recede ())
            "  그 변수를 빼고 같은 키를 다시 저장하면 적용됩니다");
       (* The override applies. This line says only that the shipped text it
          replaced has changed since it was written, so the reader knows to
          compare the two once rather than discovering a new default months
          later. *)
       if row.Tui_decode.pr_override_default_moved then
         box_line_styled buf cols ~style:(Theme.warn ())
           "  \xe2\x96\xb3 기본 프롬프트가 이 오버라이드를 쓴 뒤에 바뀌었습니다 \xc2\xb7 오버라이드는 그대로 적용 중이니 현재 기본값과 한 번 대조하세요";
       let input_contract =
         if String.equal row.pr_category "librarian" then
           "입력: Keeper 지침 | 현재 기억 | 제한된 대화 | 상대 관측 | 사실 최대 바이트"
         else
           match row.pr_template_variables with
           | [] -> "템플릿 입력: 없음"
           | variables -> "템플릿 입력: " ^ String.concat " | " variables
       in
       box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ input_contract);
       box_divider buf cols;
       let body_width = max 1 (cols - 6) in
       let effective_lines =
         Message_layout.wrap_body ~markdown:document_markdown
           ~max_cells:body_width ~sanitize:Terminal_text.single_line
           row.pr_effective
       in
       let actual_input_lines =
         if not (String.equal row.pr_category "librarian") then []
         else if state.prompts_librarian_input_loading then
           [ "최근 실제 Librarian 입력"; "(Admin 실행 상세를 불러오는 중...)"; "" ]
         else
           match state.prompts_librarian_input_error with
           | Some detail ->
               [ "최근 실제 Librarian 입력"
               ; "불러올 수 없음: " ^ Terminal_text.single_line detail
               ; ""
               ]
           | None ->
               (match state.prompts_librarian_input with
                | Some (key, lines) when String.equal key row.pr_key ->
                    lines @ [ "" ]
                | Some _ | None -> [])
       in
       let rendered = actual_input_lines @ ("유효 템플릿 본문" :: effective_lines) in
       let max_scroll = max 0 (List.length rendered - detail_height) in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let rendered_window = Rows.of_list ~first:scroll ~height:detail_height rendered in
       for index = 0 to detail_height - 1 do
         match Rows.at rendered_window (scroll + index) with
         | Some line -> box_line buf cols ("  " ^ line)
         | None -> box_empty buf cols
       done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:선택  PgUp/PgDn:읽기  a:내부 조각  i:최근 입력  e:편집  x:재정의 삭제  o:런타임 자산");
  finish_surface state ~surface_key:"prompts" ~rows:terminal_rows ~cols buf

(* The raw text assets are distributed with the binary and deliberately have
   no override contract.  They use the same Config page as the editable
   Markdown registry, but a distinct mode makes the missing edit controls an
   explicit capability boundary rather than an accidental omission. *)
let render_runtime_prompt_assets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let assets =
    match prompts with
    | Masc_tui_fetched.Ready snapshot -> snapshot.Tui_decode.ps_runtime_assets
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ ->
        []
  in
  let total = List.length assets in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt assets cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d개 · 읽기 전용%s  %s  %s"
       (screen_title " MASC 런타임 프롬프트 자산")
       Ansi.dim total Ansi.reset
       (config_pane_strip state)
       (connection_badge state));
  box_line_styled buf cols ~style:(Theme.recede ())
    "  배포된 .txt 지시문 · registry override 대상이 아님";
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row =
    match prompts with
    | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent -> None
    | Masc_tui_fetched.Loading -> Some ((Theme.recede ()), "프롬프트 목록을 읽는 중…")
    | Masc_tui_fetched.Failed detail ->
      Some ((Theme.bad ()), Terminal_text.single_line detail)
  in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let combined_height = max 2 (rows - 10 - error_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (cols - 6) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (asset : Tui_decode.runtime_prompt_asset) ->
       if index >= first && index < first + list_height then begin
         incr drawn;
         let mark = if asset.pra_file_exists then " " else (Theme.bad ()) ^ "!" ^ Ansi.reset in
         let line =
           Printf.sprintf "%s %-32s %s"
             mark
             (fit_width (Terminal_text.single_line asset.pra_path) 32)
             (Ansi.dim
             ^ (if asset.pra_file_exists then "런타임 파일" else "동기화 후 누락")
              ^ Ansi.reset)
         in
         if index = cursor then box_line buf cols (Theme.selection ^ " " ^ line ^ Ansi.reset)
         else box_line buf cols (" " ^ line)
       end)
    assets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  (match selected with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ()) "  런타임 프롬프트 자산이 없습니다";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  서버가 오래되었거나 배포 자산을 아직 동기화하지 않았을 수 있습니다";
     box_divider buf cols;
     for _ = 1 to detail_height do box_empty buf cols done
   | Some asset ->
     let source = if asset.pra_file_exists then "런타임 파일" else "누락" in
     box_line buf cols
       (Printf.sprintf "  읽기 전용 자산  %s · %s · %s"
          (Terminal_text.single_line asset.pra_path)
          source
          (Terminal_text.single_line asset.pra_file_path));
     box_line_styled buf cols ~style:(Theme.recede ())
       "  이 자산은 registry override·편집 대상이 아닙니다";
     box_divider buf cols;
     let body_width = max 1 (cols - 6) in
     let rendered =
       Message_layout.wrap_body ~markdown:document_markdown
         ~max_cells:body_width ~sanitize:Terminal_text.single_line asset.pra_value
     in
     let max_scroll = max 0 (List.length rendered - detail_height) in
     let scroll = max 0 (min state.config_scroll max_scroll) in
     let rendered_window = Rows.of_list ~first:scroll ~height:detail_height rendered in
     for index = 0 to detail_height - 1 do
       match Rows.at rendered_window (scroll + index) with
       | Some line -> box_line buf cols ("  " ^ line)
       | None -> box_empty buf cols
     done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:선택  PgUp/PgDn:읽기  o:레지스트리  r:새로고침");
  finish_surface state ~surface_key:"prompt-runtime-assets" ~rows:terminal_rows ~cols buf
;;

let render_prompts (state : state) =
  if state.prompts_show_runtime_assets
  then render_runtime_prompt_assets state
  else render_prompt_registry state
;;

(* The row the reader is on. A check rather than a colour, because the point
   of this screen is that colours are about to change. *)
let chosen_mark = "\xe2\x9c\x93"

(* Everything right of the theme name has a fixed cell budget: the palette
   blocks, page kind, and contrast result. Give the name what remains, up to
   the longest bundled name. Unlike a printf width this counts terminal cells
   and truncates, so gruvbox-material-light-medium cannot push the next three
   columns sideways. *)
let theme_name_width ~cols =
  let fixed_cells = 45 in
  max 8 (min 29 (framed_inner_width cols - fixed_cells))
;;

(* Prompt presets (#32777). A preset is one named snapshot of three
   surfaces the operator changes together: the prompt override table, each
   keeper's instructions, and runtime.toml's assignments and exact-output
   lanes. The pane lists them, saves the live state under a typed name, and
   restores one behind a two-press arm — a restore rewrites all three, and
   the report below the list is the only place it says what it skipped and
   whether runtime.toml committed. *)
let render_presets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let presets =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_presets
  in
  let unreadable =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_unreadable
  in
  let total = List.length presets in
  let cursor = max 0 (min state.presets_cursor (total - 1)) in
  let selected = List.nth_opt presets cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d개%s  %s  %s"
       (screen_title " MASC 프리셋")
       Ansi.dim total Ansi.reset
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  let error_rows = if Option.is_some state.presets_error then 1 else 0 in
  let entry_rows = if Option.is_some state.preset_save_draft then 1 else 0 in
  let combined_height = max 2 (rows - 9 - error_rows - entry_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match state.presets_error with
   | Some detail ->
     box_line buf cols
       (Theme.bad () ^ "  " ^ fit_width (Terminal_text.single_line detail) (cols - 6)
        ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  if total = 0 then begin
    incr drawn;
    box_line_styled buf cols ~style:(Theme.recede ())
      (match state.presets_snapshot with
       | None -> "  불러오는 중..."
       | Some _ -> "  아직 프리셋이 없습니다 · s 로 지금 상태를 저장하세요")
  end;
  List.iteri
    (fun index (manifest : Tui_decode.preset_manifest) ->
      if index >= first && index < first + list_height then begin
        incr drawn;
        let armed =
          state.preset_restore_armed = Some manifest.Tui_decode.pm_name
        in
        let mark = if armed then Theme.warn () ^ "r" ^ Ansi.reset else " " in
        let label =
          mark ^ " "
          ^ fit_width
              (Terminal_text.single_line (Masc_tui_preset_text.pane_row manifest))
              (max 4 (cols - 6))
        in
        if index = cursor then box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    presets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  let detail =
    Masc_tui_preset_text.detail_lines
      ~selected
      ~detail:
        (match selected with
         | None -> Masc_tui_fetched.Absent
         | Some (m : Tui_decode.preset_manifest) ->
           Masc_tui_fetched.view_for
             ~equal:String.equal
             state.preset_detail
             ~key:m.Tui_decode.pm_name)
      ~report:state.preset_report
    @ List.map
        (fun (name, reason) -> Printf.sprintf "! %s — %s" name reason)
        unreadable
  in
  let max_scroll = max 0 (List.length detail - detail_height) in
  let scroll = max 0 (min state.config_scroll max_scroll) in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height detail in
  for index = 0 to detail_height - 1 do
    match Rows.at detail_window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ fit_width (Terminal_text.single_line line) (max 4 (cols - 6)))
    | None -> box_empty buf cols
  done;
  (match state.preset_save_draft with
   | Some draft ->
     box_line buf cols
       (Theme.info () ^ "  이름: " ^ Ansi.reset
        ^ fit_width (Terminal_text.single_line draft) (max 4 (cols - 14))
        ^ Ansi.dim ^ "  Enter:저장  Esc:취소" ^ Ansi.reset)
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:선택  PgUp/PgDn:읽기  n:저장  u,u:되돌리기  r:새로고침");
  finish_surface state ~surface_key:"presets" ~rows:terminal_rows ~cols buf

let render_themes (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let all_entries = Theme_choice.entries () in
  let dark_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if not entry.light then count + 1 else count)
      0 all_entries
  in
  let light_count = List.length all_entries - dark_count in
  let entries =
    match state.theme_filter with
    | `All -> all_entries
    | `Dark ->
        List.filter
          (fun (entry : Theme_choice.entry) -> not entry.light)
          all_entries
    | `Light ->
        List.filter
          (fun (entry : Theme_choice.entry) -> entry.light)
          all_entries
  in
  let native_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if entry.lifted = 0 then count + 1 else count)
      0 entries
  in
  let show_sample = rows >= 20 in
  let chrome_rows = if show_sample then 11 else 8 in
  let content_height = max 1 (rows - chrome_rows) in
  let cursor =
    max 0 (min state.theme_cursor (max 0 (List.length entries - 1)))
  in
  let scroll = max 0 (cursor - content_height + 1) in
  let lift_on = Masc_tui_theme.lift_is_enabled () in
  let name_width = theme_name_width ~cols in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title
          (Printf.sprintf " MASC Themes · %d themes · %d native-pass"
             (List.length entries) native_count))
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  " ^ fit_width "theme" (name_width + 2) ^ " "
     ^ fit_width "colours" 16 ^ "  " ^ fit_width "page" 9 ^ " "
     ^ fit_width "contrast" 12)
  ;
  let filter_tag =
    let chip label active count =
      if active then "[" ^ label ^ " " ^ string_of_int count ^ "]"
      else label ^ " " ^ string_of_int count
    in
    Printf.sprintf "Filter: [f] %s · %s · %s"
      (chip "All" (state.theme_filter = `All) (List.length all_entries))
      (chip "Dark" (state.theme_filter = `Dark) dark_count)
      (chip "Light" (state.theme_filter = `Light) light_count)
  in
  let explanation =
    if cols >= 92 then
      "  ·  "
      ^ (if lift_on then "native 7/7=no lift · lift N/7=N raised"
         else "native 7/7=all pass · N/7 low=below 4.5:1")
    else ""
  in
  box_line_styled buf cols ~style:Ansi.dim ("  " ^ filter_tag ^ explanation);
  let chosen = state.theme_choice in
  List.iteri
    (fun index (entry : Theme_choice.entry) ->
      if index >= scroll && index < scroll + content_height then begin
        let picked =
          match chosen with
          | Some name -> String.equal name entry.name
          | None -> false
        in
        let swatch = Theme_choice.swatch_cells entry in
        let row =
          Printf.sprintf "  %s %s " (if picked then chosen_mark else " ")
            (fit_width (Terminal_text.single_line entry.name) name_width)
          ^ swatch
          ^ "  "
          ^ fit_width (if entry.light then "light" else "dark") 9
          ^ " "
          ^ fit_width (Theme_choice.contrast_status ~lift_on entry) 12
        in
        if index = cursor then box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
        else box_line buf cols row
      end)
    entries;
  let drawn = min content_height (List.length entries) in
  for _ = drawn to content_height - 1 do
    box_empty buf cols
  done;
  if show_sample then begin
    box_divider buf cols;
    box_line buf cols
      (Printf.sprintf "  Sample: %s[● Ok]%s  %s[▲ Warn]%s  %s[× Bad]%s  %s[◆ Info]%s  %s[@keeper]%s  %s[⚡ tool]%s"
         (Theme.ok ()) Ansi.reset
         (Theme.warn ()) Ansi.reset
         (Theme.bad ()) Ansi.reset
         (Theme.info ()) Ansi.reset
         (Theme.keeper_origin ()) Ansi.reset
         (Theme.tool_origin ()) Ansi.reset);
    box_line buf cols
      (Printf.sprintf "  Syntax: %slet%s x = %s\"val\"%s in %s123%s  %s(+gain)%s  %s(-loss)%s"
         Theme.Syntax.keyword Ansi.reset
         Theme.Syntax.string Ansi.reset
         Theme.Syntax.code_number Ansi.reset
         Theme.Syntax.diff_added Ansi.reset
         Theme.Syntax.diff_removed Ansi.reset);
  end;
  box_line_styled buf cols ~style:Ansi.dim
    (match chosen with
     | None ->
       "  following the terminal's own colours \xe2\x80\x94 Enter picks a theme, f filters"
     | Some name ->
       Printf.sprintf "  %s \xe2\x80\x94 Enter picks another, x follows terminal, f filters"
         (Terminal_text.single_line name));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"themes" ~rows:terminal_rows ~cols buf

(* The model knobs sit in different tables -- [reasoning-effort] and
   [temperature] under [models.NAME], [max-tokens] under
   [PROVIDER.NAME] -- and runtime.toml is 2,300 lines, so reading it top to
   bottom never puts them side by side. On 2026-08-29 nine of ten
   ollama_cloud bindings carried neither; a request with no reasoning_effort
   has Ollama turn thinking on by itself, and one keeper spent a turn
   producing 2,000 characters of reasoning and no answer. This pane is the
   same source the runtime.toml pane shows, arranged so a missing knob is a
   column and not an absence.

   Read-only. Editing lands in the runtime.toml pane next door, which already
   has the preview-checked write path. *)
let render_config_models (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows_avail = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note =
    match state.runtime_config_view with
    | Some reading -> Ansi.dim ^ Terminal_text.single_line reading.rcv_path ^ Ansi.reset
    | None -> Ansi.dim
        ^ title_missing_reading ~error:state.runtime_config_view_error
        ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "%s  %s  %s  %s" (screen_title " MASC Models")
       (config_pane_strip state) path_note (connection_badge state));
  box_divider buf cols;
  let content_height = max 1 (rows_avail - 5) in
  (match state.runtime_config_view_error, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols
         (Theme.bad () ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some _ ->
       let detail =
         List.nth_opt state.config_models_rows state.config_models_cursor
         |> Option.map Masc_tui_model_runtime_table.detail_lines
         |> Option.value ~default:[]
       in
       (* Keep the explanation attached to the selected row. Five rows are
          enough to name both owning sections without adding another modal or
          another editor path. On a very short terminal the table still keeps
          one visible row. *)
       let detail_height = min (List.length detail) (max 0 (content_height - 2)) in
       let table_height =
         max 1 (content_height - detail_height - if detail_height > 0 then 1 else 0)
       in
       (* [box_line] spends cells on the two border glyphs and the padding
          either side, and this pane adds two more for its own indent. A
          width that ignores them wraps the last column onto its own row,
          which reads as a blank value. *)
       let table =
         Masc_tui_model_runtime_table.render
           ~width:(max 40 (cols - 6 - 2))
           state.config_models_rows
       in
       let total = List.length table in
       let max_scroll = max 0 (total - table_height) in
       (* The window follows the cursor rather than the other way round: a
          cursor the frame does not draw is a selection the reader cannot
          see, and [e] would act on a row that is off screen. *)
       let cursor_line = state.config_models_cursor + 1 in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let table_window = Rows.of_list ~first:scroll ~height:table_height table in
       let scroll =
         if cursor_line < scroll then cursor_line
         else if cursor_line >= scroll + table_height
         then min max_scroll (cursor_line - table_height + 1)
         else scroll
       in
       (* Row 0 of [table] is the header, so a cursor over the data rows is
          one lower than the line it marks. *)
       for i = 0 to table_height - 1 do
         let index = scroll + i in
         match Rows.at table_window index with
         | Some line ->
             let marked =
               if index = 0 then "  " ^ Ansi.bold ^ line ^ Ansi.reset
               else if index = cursor_line then Ansi.bold ^ Theme.info () ^ "> " ^ line ^ Ansi.reset
               else "  " ^ line
             in
             box_line buf cols marked
         | None -> box_empty buf cols
       done;
       if detail_height > 0
       then (
         box_divider buf cols;
         List.iteri
           (fun i line ->
             if i < detail_height
             then (
               let line =
                 "  " ^ fit_width (Terminal_text.single_line line) (max 1 (cols - 6))
               in
               if i = 0
               then box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) line
               else box_line_styled buf cols ~style:(Theme.recede ()) line))
           detail));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:row  e:open [models.NAME]  p:next pane  r:reload  Tab:next");
  finish_surface state ~surface_key:"config_models" ~rows:terminal_rows ~cols buf

let config_metadata_style = function
  | Masc_tui_runtime_config_view.Neutral -> Theme.recede ()
  | Good -> Theme.ok () | Warning -> Theme.warn () | Bad -> Theme.bad ()

let config_content_height (state : state) =
  let terminal_rows, _ = get_terminal_size () in
  max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows
         - 7 - List.length (config_metadata_summary state))

let runtime_config_status_scroll_limit state ~terminal_rows ~cols =
  let room = max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows - 5) in
  max 0 (List.length (runtime_config_status_lines state ~cols) - room)

let render_runtime_config_status state =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"config-status"
    ~title:(screen_title " MASC Config / runtime.toml status")
    ~hints:"j/k:scroll  PgUp/PgDn:page  v/Esc:source  r:reload"
    ~body:(fun ~budget c ->
      let lines = runtime_config_status_lines state ~cols in
      let scroll = min state.runtime_config_status_scroll (max 0 (List.length lines - budget)) in
      lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + budget)
      |> List.iter (fun (tone, text) -> c.push_styled ~style:(config_metadata_style tone) ("  " ^ text)))

(* What voice resolved to, and on which microphone.

   Three facts an operator cannot get from runtime.toml. Whether the config
   loaded at all: a section that does not parse reads the same as one that was
   never written, and telling those apart took six days once. Which STT
   endpoint answers first, since a local server that is down falls back to a
   paid one silently. And the input device, because a capture that comes back
   empty is more often the wrong microphone than a threshold. *)
(* The wizard screen. The questions, their order and the completeness rule are
   Voice_wizard's; what is drawn here is only how a terminal shows them. *)
let render_voice_wizard (state : state) (session : voice_wizard_session) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let field name value =
    box_line buf cols
      (Printf.sprintf "  %s%-12s%s %s" Ansi.dim name Ansi.reset
         (Terminal_text.single_line value))
  in
  let draft = session.vws_draft in
  let side =
    match draft.Voice_wizard.section with
    | Voice_setup.Tts -> "speech out"
    | Voice_setup.Stt -> "speech in"
  in
  let shown value = if String.trim value = "" then "—" else value in
  let steps = Voice_wizard.steps draft in
  let position =
    let rec index n = function
      | [] -> None
      | step :: rest -> if step = session.vws_step then Some n else index (n + 1) rest
    in
    match index 1 steps with
    | Some n -> Printf.sprintf "%d/%d" n (List.length steps)
    | None -> "?"
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Voice · setup")
       (config_pane_strip state)
       (connection_badge state));
  box_line buf cols "";
  box_line buf cols
    (Printf.sprintf "  %sstep %s%s  %s" Ansi.dim position Ansi.reset
       (Voice_wizard.step_prompt session.vws_step));
  box_line buf cols "";
  (* The answer being given. A closed set shows its current value and the keys
     that walk it; a text field shows what has been typed, with a cursor so an
     empty field is visibly a field. *)
  (match session.vws_step with
   | Voice_wizard.Section ->
     box_line buf cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold side
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Provider ->
     box_line buf cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold
          (Voice_wizard.provider_label draft.Voice_wizard.provider)
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Review ->
     (match Voice_wizard.gaps draft with
      | [] ->
        box_line buf cols
          (Printf.sprintf "    %senter saves this%s" Ansi.bold Ansi.reset)
      | gaps ->
        List.iter
          (fun gap ->
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "    %s" (Voice_wizard.gap_message gap)))
          gaps)
   | Voice_wizard.Name
   | Voice_wizard.Address
   | Voice_wizard.Credential
   | Voice_wizard.Model
   | Voice_wizard.Voice ->
     box_line buf cols
       (Printf.sprintf "    %s%s%s%s" Ansi.bold
          (Terminal_text.single_line session.vws_input) Ansi.reset
          (if session.vws_saving then "" else "▏")));
  (* A local server that never asked for a key answers 200 only while nothing
     sends it one, so the blank is worth saying out loud rather than leaving as
     an empty line. *)
  (match session.vws_step with
   | Voice_wizard.Credential when String.trim session.vws_input = "" ->
     box_line buf cols
       (Printf.sprintf "    %sblank sends no Authorization header%s" Ansi.dim Ansi.reset)
   (* The offered voices, with the one under the cursor marked. Shown rather
      than left to typing because say does not fail on a name it does not have:
      it speaks in the system voice, so a wrong name is silent. *)
   | Voice_wizard.Voice when session.vws_voices <> [] ->
     let count = List.length session.vws_voices in
     let window = 5 in
     let first = max 0 (min (session.vws_voice_cursor - (window / 2)) (count - window)) in
     List.iteri
       (fun index (_id, label) ->
         let label = Terminal_text.single_line label in
         if index >= first && index < first + window
         then
           box_line buf cols
             (if index = session.vws_voice_cursor
              then Printf.sprintf "    %s\xe2\x96\xb8 %s%s" Ansi.bold label Ansi.reset
              else Printf.sprintf "    %s  %s%s" Ansi.dim label Ansi.reset))
       session.vws_voices;
     box_line buf cols
       (Printf.sprintf "    %s%d of %d  \xe2\x86\x90/\xe2\x86\x92 to walk, or type an id%s"
          Ansi.dim (session.vws_voice_cursor + 1) count Ansi.reset)
   | Voice_wizard.Address when String.trim session.vws_input = "" ->
     List.iter
       (fun (what, address) ->
         box_line buf cols
           (Printf.sprintf "    %stry %s: %s%s" Ansi.dim what address Ansi.reset))
       (Voice_wizard.suggested_addresses draft.Voice_wizard.section)
   | _ -> ());
  box_line buf cols "";
  box_line buf cols (Printf.sprintf "  %sdraft%s" Ansi.bold Ansi.reset);
  field "side" side;
  field "provider" (Voice_wizard.provider_label draft.Voice_wizard.provider);
  field "name" (shown draft.Voice_wizard.endpoint_id);
  field "address" (shown draft.Voice_wizard.address);
  field "key var" (shown draft.Voice_wizard.credential_variable);
  field "model" (shown draft.Voice_wizard.model);
  (match draft.Voice_wizard.section with
   | Voice_setup.Tts -> field "voice" (shown draft.Voice_wizard.voice)
   | Voice_setup.Stt -> ());
  (match session.vws_status with
   | None -> ()
   | Some status ->
     box_line buf cols "";
     box_line_styled buf cols ~style:(Theme.warn ())
       (Printf.sprintf "  %s" (Terminal_text.single_line status)));
  (* Every endpoint, not just the first that answered. A chain stops at the
     first, which is why a dead fallback reads as healthy until the endpoint in
     front of it goes away. *)
  (match session.vws_probe with
   | [] -> ()
   | lines ->
     box_line buf cols "";
     box_line buf cols (Printf.sprintf "  %swhat answered%s" Ansi.bold Ansi.reset);
     List.iter
       (fun line ->
         box_line buf cols (Printf.sprintf "    %s" (Terminal_text.single_line line)))
       lines);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"enter:next  up:back  esc:cancel");
  finish_surface state ~surface_key:"voice" ~rows:terminal_rows ~cols buf
;;

(* Assigning a voice to a keeper: two lists side by side, the keeper walking
   under up and down and the voice under the arrows. Drawn instead of the pane
   rather than over it, because both are lists and a list over a list is two
   cursors a reader has to keep apart. *)
let render_voice_agent (state : state) (session : voice_agent_session) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let window = 6 in
  let rows label items cursor draw =
    box_line buf cols (Printf.sprintf "  %s%s%s" Ansi.bold label Ansi.reset);
    let count = List.length items in
    if count = 0
    then box_line buf cols (Printf.sprintf "    %s—%s" Ansi.dim Ansi.reset)
    else (
      let first = max 0 (min (cursor - (window / 2)) (count - window)) in
      List.iteri
        (fun index item ->
          let label = Terminal_text.single_line (draw item) in
          if index >= first && index < first + window
          then
            box_line buf cols
              (if index = cursor
               then Printf.sprintf "    %s\xe2\x96\xb8 %s%s" Ansi.bold label Ansi.reset
               else Printf.sprintf "    %s  %s%s" Ansi.dim label Ansi.reset))
        items;
      box_line buf cols
        (Printf.sprintf "    %s%d of %d%s" Ansi.dim (cursor + 1) count Ansi.reset))
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Voice \xc2\xb7 keeper voices")
       (config_pane_strip state)
       (connection_badge state));
  box_line buf cols "";
  rows "keeper  (up/down)" session.vas_agents session.vas_agent_cursor (fun agent -> agent);
  box_line buf cols "";
  rows "voice  (left/right)" session.vas_voices session.vas_voice_cursor snd;
  box_line buf cols
    (Printf.sprintf "  voice ID (type or paste): %s%s%s"
       Ansi.bold (Terminal_text.single_line session.vas_manual_voice) Ansi.reset);
  (match session.vas_status with
   | None -> ()
   | Some status ->
     box_line buf cols "";
     box_line_styled buf cols ~style:(Theme.warn ())
       (Printf.sprintf "  %s" (Terminal_text.single_line status)));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"enter:assign  esc:back");
  finish_surface state ~surface_key:"voice" ~rows:terminal_rows ~cols buf
;;

let render_voice (state : state) =
  match state.voice_agent_voices, state.voice_wizard with
  | Some session, _ -> render_voice_agent state session
  | None, Some session -> render_voice_wizard state session
  | None, None ->
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let field name value =
    box_line buf cols
      (Printf.sprintf "  %s%-18s%s %s" Ansi.dim name Ansi.reset
         (Terminal_text.single_line value))
  in
  let member path json =
    List.fold_left
      (fun acc key ->
        match acc with
        | Some (`Assoc fields) -> List.assoc_opt key fields
        | Some _ | None -> None)
      (Some json) path
  in
  let string_of path json =
    match member path json with
    | Some (`String v) -> Some v
    | Some (`Bool b) -> Some (if b then "yes" else "no")
    | Some (`Int i) -> Some (string_of_int i)
    | Some _ | None -> None
  in
  (* One line per endpoint, from the admin setup read. The public config route
     answers whether a fallback is configured and not which one, so a chain that
     has quietly gone dead reads there exactly like a healthy one. *)
  let endpoints section =
    match state.voice_setup with
    | None -> []
    | Some json -> (
        match member [ section; "endpoints" ] json with
        | Some (`List items) ->
            List.filter_map
              (fun item ->
                match string_of [ "id" ] item with
                | None -> None
                | Some id ->
                    let kind = Option.value (string_of [ "kind" ] item) ~default:"?" in
                    let address =
                      match
                        (string_of [ "base_url" ] item, string_of [ "mcp_url" ] item)
                      with
                      | Some url, _ -> url
                      | None, Some url -> url
                      | None, None -> "—"
                    in
                    let off =
                      match member [ "enabled" ] item with
                      | Some (`Bool false) -> "  (disabled)"
                      | Some _ | None -> ""
                    in
                    Some
                      (Printf.sprintf "    %-20s %s%-18s%s %s%s"
                         (Terminal_text.single_line id) Ansi.dim
                         (Terminal_text.single_line kind) Ansi.reset
                         (Terminal_text.single_line address) off))
              items
        | Some _ | None -> [])
  in
  let show_endpoints section =
    match endpoints section with
    | [] -> ()
    | lines -> List.iter (fun line -> box_line buf cols line) lines
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Voice")
       (config_pane_strip state)
       (connection_badge state));
  box_line buf cols "";
  (match (state.voice_config, state.voice_config_error) with
   | _, Some message ->
       (* The distinction the pane exists for, said in words rather than drawn
          as an empty section. *)
       box_line_styled buf cols ~style:(Theme.warn ()) "  voice did not load";
       box_line buf cols
         (Printf.sprintf "  %s%s%s" Ansi.dim
            (Terminal_text.single_line message) Ansi.reset)
   | None, None ->
       box_line buf cols (Printf.sprintf "  %sreading…%s" Ansi.dim Ansi.reset)
   | Some json, None ->
       field "status" (Option.value (string_of [ "status" ] json) ~default:"?");
       box_line buf cols "";
       box_line buf cols (Printf.sprintf "  %sTTS%s" Ansi.bold Ansi.reset);
       field "model"
         (Option.value (string_of [ "tts"; "default_model" ] json) ~default:"—");
       field "voice"
         (Option.value (string_of [ "tts"; "default_voice" ] json) ~default:"—");
       show_endpoints "tts";
       box_line buf cols "";
       box_line buf cols (Printf.sprintf "  %sSTT%s" Ansi.bold Ansi.reset);
       field "model"
         (Option.value (string_of [ "stt"; "default_model" ] json) ~default:"—");
       field "endpoint"
         (Option.value
            (string_of [ "stt"; "active_endpoint"; "enabled" ] json)
            ~default:"—");
       field "fallback"
         (Option.value
            (string_of [ "stt"; "active_endpoint"; "fallback_configured" ] json)
            ~default:"—");
       show_endpoints "stt");
  (* Said once, not per section: the endpoints are missing from both when this
     read fails, and repeating it twice would read as two faults. *)
  (match state.voice_setup_error with
   | None -> ()
   | Some message ->
       box_line buf cols "";
       box_line_styled buf cols ~style:(Theme.warn ())
         "  the endpoint list could not be read";
       box_line buf cols
         (Printf.sprintf "  %s%s%s" Ansi.dim
            (Terminal_text.single_line message) Ansi.reset));
  box_line buf cols "";
  box_line buf cols (Printf.sprintf "  %sInput%s" Ansi.bold Ansi.reset);
  field "device" (Option.value state.voice_input_device ~default:"unknown");
  box_line buf cols "";
  box_line buf cols
    (Printf.sprintf
       "  %sruntime.toml [voice] declares this; the server says what loaded%s"
       Ansi.dim Ansi.reset);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"p:next pane  r:refresh  e:set up");
  finish_surface state ~surface_key:"voice" ~rows:terminal_rows ~cols buf
;;

let render_config (state : state) =
  if state.runtime_config_status_open then render_runtime_config_status state else
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note =
    match state.runtime_config_view with
    | Some reading -> Ansi.dim ^ Terminal_text.single_line reading.rcv_path ^ Ansi.reset
    | None -> Ansi.dim
        ^ title_missing_reading ~error:state.runtime_config_view_error
        ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "%s  %s  %s  %s  %s" (screen_title " MASC Config")
       (config_pane_strip state) path_note
       (Printf.sprintf "%s%s%s" Ansi.dim
          (let now = Unix.localtime (Unix.gettimeofday ()) in
           Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
             now.Unix.tm_sec)
          Ansi.reset)
       (connection_badge state));
  (* Where this server reads from, and how old the binary serving it is. A
     stale binary answers every request as confidently as a current one, so
     the age is the only thing on screen that separates them. *)
  (match state.server_identity with
   | None -> box_line buf cols (Ansi.dim ^ "  (server identity unread)" ^ Ansi.reset)
   | Some identity ->
       box_line buf cols
         (Printf.sprintf "%s  base %s   masc %s   binary %s%s" Ansi.dim
            (fit_width identity.Tui_decode.sid_base_path 28)
            (fit_width identity.Tui_decode.sid_masc_root 32)
            (binary_age_text identity.Tui_decode.sid_binary_commit_age_s)
            Ansi.reset));
  List.iter (fun (tone, text) ->
    box_line_styled buf cols ~style:(config_metadata_style tone)
      ("  " ^ Terminal_text.single_line text)) (config_metadata_summary state);
  box_divider buf cols;
  let content_height = config_content_height state in
  (match state.runtime_config_view_error, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols ((Theme.bad ()) ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some { rcv_rows = rows; _ } ->
       let total = List.length rows in
       let max_scroll = max 0 (total - content_height) in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
       for i = 0 to content_height - 1 do
         match Rows.at rows_window (scroll + i) with
         | Some segments ->
             (* Painted through [lexed_span], the table the Code surface reads.
                The runtime config is TOML and the lexer already answers for it;
                what was missing was anyone asking. *)
             let line = String.concat "" (List.map lexed_span segments) in
             let line =
               Printf.sprintf "%s%4d%s  %s" Ansi.dim (scroll + i + 1)
                 Ansi.reset line
             in
             if scroll + i = state.runtime_config_cursor then
               box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
             else box_line buf cols line
         | None -> box_empty buf cols
       done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:value field  v:read status  PgUp/PgDn:page  e:edit (preview-checked)  r:reload");
  finish_surface state ~surface_key:"config" ~rows:terminal_rows ~cols buf

let render_surface (state : state) =
  match state.view with
  | Overview ->
      (* Same fallback shape as Board/Planning detail: a detail id whose row
         left the backlog renders the list, not a frame for a missing task. *)
      (match state.task_detail_id with
       | Some _ -> (
           match
             Task_selection.detail_row
               ~detail_id:state.task_detail_id
               ~tasks:state.tasks_domain
           with
           | Some task -> render_task_detail state task
           | None -> render_overview state )
       | None -> render_overview state)
  | Keepers Keeper_list ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_list state
  | Keepers Keeper_detail ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_detail state
  | Keepers Keeper_logs -> render_keeper_logs state
  | Keepers Keeper_calls -> render_keeper_calls state
  | Keepers Keeper_message ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_message state
  | Keepers Keeper_runtime_pick -> render_runtime_pick state
  | Lanes -> render_lanes state
  | Clients -> render_clients state
  | Board ->
      (match state.board_mode with
       | Board_list -> render_board_list state
       | Board_compose -> render_board_compose state
       | Board_read post_id ->
           match Board_detail.view_for state.board_detail ~post_id with
           | Board_detail.Ready (post, _) -> render_board_read state post
           | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
               (match List.find_opt (fun p -> p.bp_id = post_id) state.board_posts with
                | Some post -> render_board_read state post
                | None ->
                    let terminal_rows, cols = get_terminal_size () in
                    surface_chrome state ~terminal_rows ~cols ~surface_key:"board-read"
                      ~title:(screen_title (" MASC Board / " ^ Terminal_text.single_line post_id))
                      ~hints:"r:retry  Esc:back  Tab:next"
                      ~body:(fun ~budget:_ c ->
                        match Board_detail.view_for state.board_detail ~post_id with
                        | Board_detail.Failed detail ->
                            c.push_styled ~style:(Theme.bad ())
                              ("  Board post load failed: " ^ Terminal_text.single_line detail)
                        | Board_detail.Absent -> c.push "  Board post has not been loaded. Press r to retry."
                        | Board_detail.Loading -> c.push "  Loading Board post..."
                        | Board_detail.Ready _ -> ())))
  | Planning ->
      (match state.planning_mode with
       | Planning_list -> render_planning_list state
       | Planning_detail goal_id ->
           let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
           match List.find_opt (fun g -> g.pg_id = goal_id) goals with
           | Some goal ->
               render_planning_detail state
                 ~armed:(goal_action_armed_for state goal_id) goal
           | None -> render_planning_list state)
  | Approvals when (match state.ask_answer_mode with Ask_answering _ -> true | Ask_browsing -> false) ->
      render_question_reader state
  | Approvals ->
      (* Open on the row the cursor is on. An ask that resolves while it is
         open takes the row with it, so the detail closes rather than showing
         something the queue no longer holds. *)
      (match
         if state.approval_detail_open then
           List.nth_opt (approval_items state) state.approval_cursor
         else None
       with
       | Some row -> render_approval_detail state row
       | None -> render_approvals state)
  | Verification -> render_verification state
  | Harness -> render_harness state
  | Fusion ->
      (match state.fusion_mode with
       | Fusion_list -> render_fusion_list state
       | Fusion_detail run_id -> render_fusion_detail state run_id
       | Fusion_historical_detail reference -> render_fusion_detail state reference.fhe_run_id)
  | Memory ->
      if Option.is_some state.memory_facts_keeper then
        render_memory_facts state
      else render_memory state
  | Repositories ->
      (match state.workspace_activity_repo with
       | Some repo_id -> render_workspace_activity state repo_id
       | None -> render_repositories state)
  | Changes -> render_changes state
  | Connectors -> render_connectors state
  | Runtime ->
      (match state.runtime_detail_target with
       | None -> render_runtime state
       | Some target -> render_runtime_detail state target)
  | Config -> (
    match state.config_pane with
    | Config_prompts -> render_prompts state
    | Config_presets -> render_presets state
    | Config_themes -> render_themes state
    | Config_runtime -> render_config state
    | Config_models -> render_config_models state
    | Config_params -> render_runtime_params state
    | Config_voice -> render_voice state)
  | Resources -> render_resources state
  | Code ->
      if state.repository_changes_open then render_repository_changes state
      else render_code state
  | Tools -> render_tools state
  | Acting -> render_acting state
  | Metrics -> render_metrics state
  | System_logs ->
      (match state.system_logs_detail_seq with
       | None -> render_system_logs state
       | Some seq -> render_system_log_detail state seq)
  | Schedules -> render_schedules state

let context_split_lines ~cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = Theme.recede () ^ " │ " ^ Ansi.reset in
  let right_width = max 1 (inner - left_width - 3) in
  let count = max (List.length left) (List.length right) in
  List.init count (fun index ->
      let left = Option.value ~default:"" (List.nth_opt left index) in
      let right = Option.value ~default:"" (List.nth_opt right index) in
      fit_width left left_width ^ divider ^ fit_width right right_width)

(* The plain body's line count, for the keys that scroll it. *)
let context_inspector_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, _) -> List.length lines
    | Split _ -> 0
  in
  (count, framed_content_height ~rows)

(* The split detail column's body line count and its window height, for the
   keys that scroll it. The pinned header row is not theirs to scroll. *)
let context_inspector_detail_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  match context_inspector_content_lines ~cols state with
  | Plain _ -> (0, 0)
  | Split { common; right; _ } ->
      let split_height =
        context_split_pane_height ~content_height:(framed_content_height ~rows)
          ~common_len:(List.length common)
      in
      ( List.length right - 1
      , max 0 (split_height - 1) )

let context_split_window ~height ~offset lines =
  lines |> List.filteri (fun index _ -> index >= offset && index < offset + height)

let render_context_inspector state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let keeper =
    Option.value ~default:"no Keeper" state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  let refreshing =
    if state.context_inspector_loading then Ansi.dim ^ "  refreshing" ^ Ansi.reset
    else ""
  in
  let tab_label tab number label =
    if state.context_inspector_tab = tab then
      Ansi.bold ^ (Theme.info ()) ^ number ^ ":" ^ label ^ Ansi.reset
    else Ansi.dim ^ number ^ ":" ^ label ^ Ansi.reset
  in
  (* The search query, drawn where the typing lands: the Keepers strip's
     own indicator sits on a surface this pane replaced. *)
  let search_marker =
    match state.search with
    | Some query ->
        Printf.sprintf "  %s/%s▌%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line query)
          Ansi.reset
    | None ->
        if state.search_last = "" then ""
        else
          Printf.sprintf "  %s/%s (n/N)%s" Ansi.dim
            (Terminal_text.single_line state.search_last)
            Ansi.reset
  in
  framed_top buf cols;
  framed_line buf cols
    (Printf.sprintf "%s Context  %s%s  %s  %s"
       (screen_title "") keeper refreshing
       (tab_label Masc_tui_context_inspector.Composition "1" "stack")
       (tab_label Masc_tui_context_inspector.Exact_input "2" "request")
       ^ "  "
       ^ (tab_label Masc_tui_context_inspector.Input_map "3" "proof")
       ^ search_marker);
  framed_divider buf cols;
  let content_height = framed_content_height ~rows in
  let drawn =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, selected) ->
        let scroll =
          Masc_tui_scroll.normalize ~count:(List.length lines)
            ~height:content_height state.context_inspector_scroll
        in
        (* The cursor names a row, the window follows it: on the single-column
           shapes nothing lives under the row, so the smallest move that keeps
           it drawn is the right one. *)
        let scroll =
          match selected with
          | None -> scroll
          | Some cursor ->
              Masc_tui_scroll.normalize ~count:(List.length lines)
                ~height:content_height
                (Masc_tui_scroll.ensure_visible ~cursor ~height:content_height scroll)
        in
        let window =
          lines
          |> List.filteri (fun index _ ->
               index >= scroll && index < scroll + content_height)
        in
        List.iter (framed_line buf cols) window;
        List.length window
    | Split { common; left; right } ->
        (* The summary clips to the frame rather than overflowing it: on a
           short terminal the split gives way before the pane draws a row
           past its last. *)
        let common_rows =
          common |> List.filteri (fun index _ -> index < content_height)
        in
        List.iter (framed_line buf cols) common_rows;
        let split_height =
          context_split_pane_height ~content_height
            ~common_len:(List.length common)
        in
        let split_drawn =
          if split_height <= 0 then 0
          else begin
            (* Both columns are header :: rows, so the heads are total. The
               header row stays pinned above the windows -- it carries the
               focus caret, and a caret that scrolls away stops saying which
               pane hears j/k. *)
            let pinned =
              context_split_lines ~cols ~left_width:(context_split_width cols)
                ~left:[ List.hd left ] ~right:[ List.hd right ]
            in
            List.iter (framed_line buf cols) pinned;
            let body_height = split_height - 1 in
            let items = List.length left - 1 in
            let cursor =
              min (max 0 (items - 1)) (max 0 state.context_inspector_cursor)
            in
            (* Stateless bottom-pin over the item rows; the detail column
               owns its scroll, so neither pane drags the other. *)
            let left_offset =
              Masc_tui_scroll.ensure_visible ~cursor ~height:body_height 0
            in
            let right_offset =
              Masc_tui_scroll.normalize ~count:(List.length right - 1)
                ~height:body_height state.context_inspector_detail_scroll
            in
            let window =
              context_split_lines ~cols ~left_width:(context_split_width cols)
                ~left:
                  (context_split_window ~height:body_height ~offset:left_offset
                     (List.tl left))
                ~right:
                  (context_split_window ~height:body_height ~offset:right_offset
                     (List.tl right))
            in
            List.iter (framed_line buf cols) window;
            split_height
          end
        in
        List.length common_rows + split_drawn
  in
  for _ = 1 to max 0 (content_height - drawn) do
    framed_line buf cols ""
  done;
  framed_bottom buf cols;
  let hints =
    match state.context_inspector_exact with
    | Some _ -> "j/k:scroll  Esc:list"
    | None -> (
        match
          state.context_inspector_tab, cols >= keeper_split_threshold_cols
        with
        | (Masc_tui_context_inspector.Exact_input | Masc_tui_context_inspector.Input_map), true ->
            "1/2/3 or Tab:switch  [/] turn  /:search  j/k:select or scroll  h/l:pane  Enter:open exact  r:refresh  Esc:close"
        | _ ->
            "1/2/3 or Tab:switch  [/] turn  /:search  j/k:select  Enter:open exact  r:refresh  Esc:close")
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);
  finish_surface state ~surface_key:"context-inspector" ~rows:terminal_rows
    ~cols buf

(* What the help overlay can show right now: the rows its sheet folds to at
   this width, and the height it draws them in. The key handler bounds its
   step against this, so a press that the frame cannot spend is not taken. *)
let help_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let header = help_ascii_banner ~cols state in
  ( List.length (Masc_tui_help.sheet ~header ~cols (help_lines state))
  , framed_content_height ~rows )

(* The [:] palette: a typed filter over every jump the strip and roster
   offer. The list is the same [palette_matches] the Enter key resolves, so
   what is highlighted is what will run. *)
let render_palette (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  let matches = Masc_tui_types.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  framed_shadow_top buf cols;
  (* A choice says which question, how many names and which line; the
     prompt is a filter over those names, not a jump query. *)
  let title, prompt, action =
    match state.palette_mode with
    (* The action reads as a footer label now, so it is spelled like one:
       lower case, the way every other [key:label] item is. *)
    | Masc_tui_types.Palette_jump -> (" Quick Jump & Navigation", ":", "jump")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_types.code_cursor_line_symbols state) in
        ( Printf.sprintf " %s \xc2\xb7 %d name%s on line %d" choice_question names
            (if names = 1 then "" else "s") choice_line
        , "filter:"
        , "ask" )
  in
  framed_shadow_line buf cols
    (screen_title title ^ "  "
     ^ (Theme.warn ()) ^ "\xe2\x9a\xa1" ^ Ansi.reset ^ "  "
     ^ Ansi.bold ^ prompt ^ Ansi.reset ^ " "
     ^ (Terminal_text.single_line state.palette_query)
     ^ ((Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "\xe2\x96\x8c" ^ Ansi.reset));
  framed_shadow_divider buf cols;
  let content_height = framed_content_height ~rows in
  let first =
    if cursor < content_height then 0
    else cursor - content_height + 1
  in
  matches
  |> List.filteri (fun i _ -> i >= first && i < first + content_height)
  |> List.iteri (fun visible_index (label, _) ->
       let selected = first + visible_index = cursor in
       if selected then
         framed_shadow_line_styled buf cols ~style:Theme.selection (" \xe2\x96\xb8 " ^ label)
       else
         framed_shadow_line buf cols ("   " ^ label));
  if total = 0 then
    framed_shadow_line buf cols (Ansi.dim ^ "   (no match)" ^ Ansi.reset);
  framed_shadow_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       (* [key:label] items, two spaces apart, the way every other footer is
          written. In the dotted form this row was one item with no colon, so
          {!Masc_tui_footer} could shed no whole key and keep no door: it fell
          through to the cell cut, where [Esc] survived only when the budget
          happened to reach it. test_a_row_in_another_grammar_loses_its_door
          measures that across widths. The count keeps no colon on purpose --
          it is not a key, and it is the first thing a narrow row should give
          up. *)
       ~hints:
         (Printf.sprintf "%d/%d  Enter:%s  Up/Down:navigate  Esc:close"
            (if total = 0 then 0 else cursor + 1)
            total action));
  finish_surface state ~surface_key:"palette" ~rows:terminal_rows ~cols buf

let render_patch_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let path_label =
    match state.patch_modal_path with
    | Some p -> p
    | None -> (match state.repository_changes_diff_path with Some p -> p | None -> "Active Working Tree")
  in
  framed_shadow_top buf cols;
  framed_shadow_line buf cols
    (screen_title " Patch & Diff Review" ^ "  "
     ^ (Theme.info ()) ^ "\xe2\x9a\xa1 " ^ Ansi.reset
     ^ Ansi.bold ^ Terminal_text.single_line path_label ^ Ansi.reset);
  framed_shadow_divider buf cols;
  framed_shadow_line_styled buf cols ~style:(Theme.recede ())
    "  old   new     diff preview (syntax colored)";
  framed_shadow_divider buf cols;
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> (match state.repository_changes_diff with Some (_, d) -> Some d | None -> None)
  in
  let diff_rows =
    match diff_opt with
    | Some diff -> diff.Masc.Tui_decode.gd_rows
    | None -> []
  in
  let total = List.length diff_rows in
  let fixed_chrome = 9 in
  let content_height = max 1 (rows - fixed_chrome) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.patch_modal_scroll max_scroll) in
  if total = 0 then begin
    let msg =
      match state.patch_modal_error with
      | Some e -> Printf.sprintf "(diff load error: %s — Esc to close)" e
      | None ->
          (match state.repository_changes_diff_error with
           | Some e -> Printf.sprintf "(diff load error: %s — Esc to close)" e
           | None -> "(no pending patch diff loaded — Esc to close)")
    in
    framed_shadow_line buf cols (Ansi.dim ^ "   " ^ msg ^ Ansi.reset);
    for _ = 1 to content_height - 1 do
      framed_shadow_empty buf cols
    done
  end else begin
    let diff_array = Array.of_list diff_rows in
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      if idx >= total then
        framed_shadow_empty buf cols
      else
        let row = diff_array.(idx) in
        let inner = framed_inner_width (cols - 1) in
        let span = tree_diff_row_span ~width:inner row in
        let rendered_line = Masc_tui_span.render span in
        framed_shadow_line buf cols (fit_width rendered_line inner)
    done
  end;
  framed_shadow_divider buf cols;
  framed_shadow_line buf cols
    (Printf.sprintf "  %s[e]%s Edit ($EDITOR)   %s[j/k]%s Scroll   %s[g/G]%s Top/Bottom   %s[Esc/q]%s Close"
       (Theme.info ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.recede ()) Ansi.reset);
  framed_shadow_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Printf.sprintf "[%d lines, scroll %d]  e:edit  j/k:scroll  g/G:top/bottom  Esc/q:close" total scroll));
  finish_surface state ~clamped:(Patch_modal_scroll scroll)
    ~surface_key:"patch-modal" ~rows:terminal_rows ~cols buf
;;

let render_link_preview_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let url_opt =
    match state.link_modal_url with
    | Some u -> Some u
    | None ->
        (match state.link_modal_links with
         | first :: _ -> Some first
         | [] -> None)
  in
  match url_opt with
  | None ->
      framed_shadow_top buf cols;
      framed_shadow_line buf cols
        (screen_title " Web Link Preview & Embed" ^ "  "
         ^ (Theme.info ()) ^ "\xf0\x9f\x8c\x90 " ^ Ansi.reset
         ^ Ansi.dim ^ "(no links)" ^ Ansi.reset);
      framed_shadow_divider buf cols;
      let fixed_chrome = 7 in
      let content_height = max 1 (rows - fixed_chrome) in
      framed_shadow_line buf cols "  (no web links found in this conversation to preview — Esc to close)";
      for _ = 2 to content_height do
        framed_shadow_empty buf cols
      done;
      framed_shadow_divider buf cols;
      framed_shadow_line buf cols
        (Printf.sprintf "  %s[Esc/q]%s Close" (Theme.recede ()) Ansi.reset);
      framed_shadow_bottom buf cols;
      Buffer.add_string buf
        (footer_line state ~max_cells:cols ~hints:"Esc:close");
      finish_surface state ~surface_key:"link-modal" ~rows:terminal_rows ~cols buf
  | Some url ->
      let preview = Masc_tui_link_preview.get_preview url in
      framed_shadow_top buf cols;
      framed_shadow_line buf cols
        (screen_title " Web Link Preview & Embed" ^ "  "
         ^ (Theme.info ()) ^ "\xf0\x9f\x8c\x90 " ^ Ansi.reset
         ^ Ansi.bold ^ Terminal_text.single_line (Masc_tui_link_preview.site_label preview) ^ Ansi.reset);
      framed_shadow_divider buf cols;
      let total_links = List.length state.link_modal_links in
      let nav_line_count =
        if total_links > 1 then begin
          let nav =
            Printf.sprintf "  %s[Link %d of %d]%s  [n] Next link   [p] Previous link   [o] Open in browser"
              (Theme.warn ()) (state.link_modal_cursor + 1) total_links Ansi.reset
          in
          framed_shadow_line buf cols nav;
          framed_shadow_divider buf cols;
          2
        end else 0
      in
      let fixed_chrome = 7 + nav_line_count in
      let content_height = max 1 (rows - fixed_chrome) in
      let content_lines =
        Masc_tui_link_preview.render_modal_card
          ~width:(framed_inner_width (cols - 1)) ~height:content_height preview
      in
      let total = List.length content_lines in
      let max_scroll = max 0 (total - content_height) in
      let scroll = max 0 (min state.link_modal_scroll max_scroll) in
      let lines_array = Array.of_list content_lines in
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx >= total then
          framed_shadow_empty buf cols
        else
          let line = lines_array.(idx) in
          framed_shadow_line buf cols line
      done;
      framed_shadow_divider buf cols;
      framed_shadow_line buf cols
        (Printf.sprintf "  %s[o]%s Browser   %s[y]%s Copy URL   %s[v]%s View Image   %s[j/k]%s Scroll   %s[Esc/q]%s Close"
           (Theme.ok ()) Ansi.reset
           (Theme.info ()) Ansi.reset
           (Theme.info ()) Ansi.reset
           (Theme.recede ()) Ansi.reset
           (Theme.recede ()) Ansi.reset);
      framed_shadow_bottom buf cols;
      Buffer.add_string buf
        (footer_line state ~max_cells:cols
           ~hints:(Printf.sprintf "[%s] o:browser  y:copy  v:image  n/p:cycle  j/k:scroll  Esc:close"
                     (Masc_tui_link_preview.site_label preview)));
      finish_surface state ~clamped:(Link_modal_scroll scroll)
        ~surface_key:"link-modal" ~rows:terminal_rows ~cols buf

let keeper_deletions_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  List.length (keeper_deletions_lines state ~cols), framed_content_height ~rows

let render_keeper_deletions (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  framed_top buf cols;
  framed_line buf cols (screen_title " 키퍼 삭제 기록"
    ^ (if state.keeper_deletions_loading then " · 조회/재시도 중" else ""));
  framed_divider buf cols;
  let lines = keeper_deletions_lines state ~cols in
  let height = framed_content_height ~rows in
  let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.keeper_deletions_scroll in
  lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + height)
    |> List.iter (framed_line buf cols);
  framed_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~hints:"j/k:작업  J/K/PgUp/PgDn:원문  r:조회  t:정리 재시도  Esc:닫기");
  finish_surface state ~surface_key:"keeper-deletions" ~rows:terminal_rows ~cols buf

let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  framed_top buf cols;
  framed_line buf cols
    (screen_title " MASC Cheat Sheet" ^ "  " ^ Ansi.dim
    ^ "hints "
    ^ (if state.hints_visible then "on" else "off")
    ^ " \xc2\xb7 [h] toggle \xc2\xb7 [Esc] close" ^ Ansi.reset);
  framed_divider buf cols;
  let header = help_ascii_banner ~cols state in
  let lines = help_lines state in
  let rendered_rows = Masc_tui_help.sheet ~header ~cols lines in
  let content_height = framed_content_height ~rows in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length rendered_rows) ~height:content_height state.help_scroll
  in
  rendered_rows
  |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun line -> framed_line buf cols line);
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       (* The sheet that names every other surface's keys did not name its own.
          It is longer than any terminal -- at 150x78 the later sections are
          still off screen -- so [G] is the difference between reading them and
          pressing [j] forty times, and nothing said [G] exists. The keys are
          handled at masc_tui.ml: "pageup" | "pagedown", "g", "G". *)
       ~hints:
         "j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  Esc:close");
  finish_surface state ~surface_key:"help" ~rows:terminal_rows ~cols buf

(* Rows the agenda panel can show, and how many it has. The keypress bounds
   the scroll from the same pair the frame draws with -- the shape
   [Masc_tui_scroll] exists to keep in one place. *)
let agenda_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let lines =
    Agenda.overlay
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols:(framed_inner_width cols)
      (Masc_tui_types.agenda state)
  in
  (List.length lines, framed_content_height ~rows)

let answering_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  ( List.length (answering_lines state)
  , max 1 (framed_content_height ~rows - answering_preview_rows) )

let render_answering (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  framed_top buf cols;
  framed_line
    buf
    cols
    (screen_title " Live Keeper Turns & Answering" ^ "  "
     ^ (Theme.info ()) ^ "\xe2\x97\x90" ^ Ansi.reset ^ "  "
     ^ Ansi.dim ^ "· [Enter] Chat · [Esc] Close" ^ Ansi.reset);
  framed_divider buf cols;
  let lines = answering_lines state in
  let content_height =
    max 1 (framed_content_height ~rows - answering_preview_rows)
  in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length lines)
      ~height:content_height
      state.answering_scroll
  in
  let paint ~selected (line : Masc_tui_answering.line) =
    let tone_prefix =
      match line.Masc_tui_answering.tone with
      | Masc_tui_answering.Heading -> Ansi.bold
      | Masc_tui_answering.Running -> (Theme.info ())
      | Masc_tui_answering.Done -> Theme.ok ()
      | Masc_tui_answering.Unknown -> Theme.warn ()
      | Masc_tui_answering.Quiet -> Ansi.dim
    in
    (* The cursor is a gutter caret, not a full-row band: the row keeps its
       tone, and rows Enter cannot act on never wear the caret. *)
    let caret =
      if selected && Option.is_some line.Masc_tui_answering.target then "\xe2\x96\xb8 "
      else "  "
    in
    caret ^ tone_prefix ^ line.Masc_tui_answering.text ^ Ansi.reset
  in
  lines
  |> List.mapi (fun i line -> (i, line))
  |> List.filter (fun (i, _) -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun (i, line) ->
         framed_line buf cols (paint ~selected:(i = state.answering_cursor) line));
  (* The fixed preview panel: what the cursor's keeper is doing right now,
     from the turns poll's live glance. Drawn empty rather than omitted so
     the list above never reflows with the cursor. *)
  framed_divider buf cols;
  let preview_lines =
    let cursor_preview =
      match List.nth_opt lines state.answering_cursor with
      | Some { Masc_tui_answering.target = Some keeper_name; _ } ->
          List.find_map
            (fun (row : Tui_decode.keeper_turn_row) ->
              if String.equal row.ktr_keeper_name keeper_name then
                match row.ktr_state with
                | Tui_decode.Keeper_turn_running { preview = Some preview; _ }
                  ->
                    Some (keeper_name, preview)
                | Tui_decode.Keeper_turn_running { preview = None; _ }
                | Tui_decode.Keeper_turn_idle
                | Tui_decode.Keeper_turn_unavailable _ -> None
              else None)
            state.keeper_turns
      | Some _ | None -> None
    in
    match cursor_preview with
    | Some (keeper_name, preview) ->
        let doing =
          match preview.Tui_decode.ktp_current_tool with
          | Some tool_name -> "\xe2\x96\xb6 " ^ tool_name
          | None -> "\xe2\x96\xb6 writing"
        in
        let tail =
          match
            Terminal_text.single_line preview.Tui_decode.ktp_text_tail
          with
          | "" -> "(no text yet \xe2\x80\x94 tool calls only)"
          | tail -> tail
        in
        [ Ansi.bold ^ keeper_name ^ Ansi.reset ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ doing
          ^ Ansi.reset
        ; Ansi.dim ^ tail ^ Ansi.reset
        ]
    | None ->
        [ Ansi.dim ^ "live preview \xe2\x80\x94 none for this row" ^ Ansi.reset
        ; ""
        ]
  in
  List.iter (fun line -> framed_line buf cols line) preview_lines;
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:move  Enter:open chat  Esc:close");
  finish_surface state ~surface_key:"answering" ~rows:terminal_rows ~cols buf
;;

let render_agenda (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  framed_top buf cols;
  framed_line
    buf
    cols
    (screen_title " Agenda & Upcoming Timers" ^ "  " ^ Ansi.dim ^ "· [j/k] Scroll · [Esc] Close" ^ Ansi.reset);
  framed_divider buf cols;
  let lines =
    Agenda.overlay
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols:(framed_inner_width cols)
      (Masc_tui_types.agenda state)
  in
  let content_height = framed_content_height ~rows in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length lines)
      ~height:content_height
      state.agenda_scroll
  in
  let paint (line : Agenda.line) =
    match line.Agenda.tone with
    | Agenda.Heading -> Ansi.bold ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Wake -> (Theme.recede ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Question -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Quiet -> Ansi.dim ^ line.Agenda.text ^ Ansi.reset
  in
  lines
  |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun line -> framed_line buf cols (paint line));
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"j/k:scroll  Esc:close");
  finish_surface state ~surface_key:"agenda" ~rows:terminal_rows ~cols buf
;;

let render_terminal_too_small state ~rows ~cols =
  (* The hint names physical terminal rows, whereas the guard receives the
     body after navigation, agenda, and composer allocation. At the minimum
     body size the composer can be absent; evaluate its policy at the proposed
     surface size rather than copying the current tiny viewport's overhead. *)
  let surface_rows =
    Render_schedule.Viewport.minimum_fixed_chrome_rows
    + Masc_tui_types.agenda_chrome_rows state
  in
  let minimum_terminal_rows =
    navigation_rows + surface_rows
    + Masc_tui_composer.rows_for ~terminal_rows:surface_rows
  in
  let buf = Buffer.create 64 in
  Buffer.add_string buf
    (fit_width
       (Printf.sprintf "terminal too small -- resize to at least %d rows; q: quit"
          minimum_terminal_rows)
       cols);
  Buffer.add_char buf '\n';
  finish_frame ~compact_frame:true ~surface_key:"terminal-too-small"
    ~cursor:Frame_presenter.Hidden ~rows ~cols buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"lanes"
    ~title:(screen_title " MASC Lane Add-ons")
    ~hints:"Tab:instances/rows  j/k:select  J/K:scroll  space:mark  e:preserve  o:observe  d:detach  r:inspect  :command  Esc:back"
    ~body:(fun ~budget c ->
      Masc_tui_lane_addons.lines ~width:(framed_inner_width cols) view
      |> List.filteri (fun index _ -> index >= view.scroll && index < view.scroll + budget)
      |> List.iter (fun line -> c.push (Terminal_text.single_line line)))

let render (state : state) =
  (* Decide the pane before any surface measures the terminal. Modals draw
     over the whole terminal and the Activity feed already fills its own
     screen, so neither reserves the columns. *)
  (acting_pane_reserved_cols :=
     let _rows, terminal_cols = Masc_tui_ansi.get_terminal_size () in
     acting_pane_columns state ~terminal_cols);
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  if Render_schedule.Viewport.requires_compact_frame ~rows
  then
    let frame, clamped = render_terminal_too_small state ~rows ~cols in
    (frame, clamped, None)
  else match state.lane_addons with
  | Some view ->
    let frame, clamped = render_lane_addons state view in
    (frame, clamped, None)
  | None -> if state.palette_open then
    let frame, clamped = render_palette state in
    (frame, clamped, None)
  else if state.context_inspector_open then
    let frame, clamped = render_context_inspector state in
    (frame, clamped, None)
  else if state.keeper_deletions_open then
    let frame, clamped = render_keeper_deletions state in
    (frame, clamped, None)
  else if state.help_open then
    let frame, clamped = render_help state in
    (frame, clamped, None)
  else if state.agenda_open then
    let frame, clamped = render_agenda state in
    (frame, clamped, None)
  else if state.answering_open then
    let frame, clamped = render_answering state in
    (frame, clamped, None)
  else if state.patch_modal_open then
    let frame, clamped = render_patch_modal state in
    (frame, clamped, None)
  else if state.link_modal_open then
    let frame, clamped = render_link_preview_modal state in
    (frame, clamped, None)
  else
    let frame, clamped = render_surface state in
    let presented_approval =
      match state.view with
      | Approvals ->
          List.nth_opt (approval_items state) state.approval_cursor
      | Overview | Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
      | Planning
      | Schedules | Verification | Harness | Fusion | Repositories | Changes
      | Connectors | Runtime | Config | Resources | Code | Tools
      | System_logs -> None
    in
    (frame, clamped, presented_approval)
