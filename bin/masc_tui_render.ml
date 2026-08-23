(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

module Frame_presenter = Masc_tui_frame_presenter
module Board_detail = Masc_tui_board_detail
module Message_layout = Masc_tui_message_layout
module Metrics_tail = Masc_tui_metrics_tail
module Observation_layout = Masc_tui_observation_layout
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Keeper_control = Masc_tui_keeper_control
module Status = Masc.Keeper_status_runtime

let frame_lines buf =
  match List.rev (String.split_on_char '\n' (Buffer.contents buf)) with
  | "" :: reversed -> List.rev reversed
  | reversed -> List.rev reversed

let finish_frame ~surface_key ~cursor ~rows ~cols buf :
    Frame_presenter.frame =
  { surface_key;
    terminal_rows = rows;
    terminal_cols = cols;
    cursor;
    lines = frame_lines buf;
  }

(* Exhaustive over [connection_status]: a new state is a compile error
   here rather than an unexplained [disconnected] on screen. *)
let connection_badge : Masc_tui_types.connection_status -> string = function
  | Connected -> Ansi.green ^ "[connected]" ^ Ansi.reset
  | Degraded -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
  | Connecting -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
  | Reconnecting -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
  | Disconnected -> Ansi.red ^ "[disconnected]" ^ Ansi.reset
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
  | Workspace_health_risk -> Ansi.red
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_unknown -> Ansi.yellow
  | Workspace_health_ok -> Ansi.green

let attention_severity_label = function
  | Attention_critical -> "critical"
  | Attention_bad -> "bad"
  | Attention_warning -> "warn"
  | Attention_info -> "info"

let attention_severity_color = function
  | Attention_critical | Attention_bad -> Ansi.red
  | Attention_warning -> Ansi.yellow
  | Attention_info -> Ansi.cyan

let task_line (task : task) =
  let status = Masc_domain.task_status_to_string task.status in
  let assignee =
    match Masc_domain.task_assignee_of_status task.status with
    | Some name -> Printf.sprintf " @%s" (Terminal_text.single_line name)
    | None -> ""
  in
  Printf.sprintf "  %s [%s] %s (%s%s) %s"
    (task_status_icon task.status)
    (Terminal_text.single_line task.id)
    (Terminal_text.single_line task.title)
    status
    assignee
    (priority_indicator task.priority)

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
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Overview  %s[%s]%s  %s  %s"
    Ansi.cyan (Terminal_text.single_line state.workspace) Ansi.reset timestamp
    (connection_badge state.connection_status) in

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
        Printf.sprintf "  %s(data unreliable: %s)%s" Ansi.red
          (fit_width err (cols - 24))
          Ansi.reset
    | None, None ->
        Printf.sprintf "  %s(no overview data — press 'r' to refresh)%s"
          Ansi.dim Ansi.reset
    | Some o, None ->
        let health_color = workspace_health_color o.ov_workspace_health in
        let health_label = workspace_health_label o.ov_workspace_health in
        let approval_count =
          match state.approval_snapshot, state.approvals_error with
          | Some snapshot, None -> string_of_int snapshot.aps_visible_count
          | None, _ | Some _, Some _ -> "?"
        in
        Printf.sprintf "  Health: %s%s%s  Agents: %d  Approvals: %s  Incidents: %d"
          health_color health_label Ansi.reset
          o.ov_active_agents approval_count o.ov_incident_count
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
               (Terminal_text.single_line t.th_primary_path)
               (Terminal_text.single_line t.th_queue_pressure)
               t.th_sse_sessions websocket grpc dropped
         in
         let cluster_line =
           Printf.sprintf "  Cluster: %s%s%s  Project: %s%s"
             Ansi.dim
             (fit_width (Terminal_text.single_line o.ov_cluster) 24)
             Ansi.reset
             (fit_width (Terminal_text.single_line o.ov_project) 20)
             transport_summary
       in
       box_line buf cols cluster_line);

  box_divider buf cols;

  (* Attention panel *)
  let attention_items, tasks_error, row_budget =
    overview_layout state ~terminal_rows:rows
  in
  let panel_width = (cols - 3) / 2 in
  let attention_title = " Attention " in
  let event_count = List.length state.events in
  let event_window =
    Render_schedule.project_overview_event_window ~event_count
      ~visible_rows:row_budget.attention_rows state.overview_event_scroll
  in
  state.overview_event_scroll <- event_window.oew_offset;
  let events_title =
    let title =
      if event_window.oew_first_position = 0 then " Recent Events "
      else
        Printf.sprintf " Recent Events %d-%d/%d "
          event_window.oew_first_position event_window.oew_last_position
          event_count
    in
    fit_width title (max 0 panel_width)
  in
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s%s%s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold attention_title Ansi.reset
    (String.make (max 0 (panel_width - String.length attention_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset)
    events_title
    (String.make (max 0 (panel_width - String.length events_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  for i = 0 to row_budget.attention_rows - 1 do
    let attention_str =
      if i < List.length attention_items then
        let a = List.nth attention_items i in
        let sev_color = attention_severity_color a.ai_severity in
        let severity_label = attention_severity_label a.ai_severity in
          Printf.sprintf "%s[%s]%s %s"
            sev_color (fit_width severity_label 5) Ansi.reset
            (fit_width
               (Terminal_text.single_line a.ai_summary)
               (panel_width - 12))
      else ""
    in
    let event_str =
      let event_index = i + event_window.oew_offset in
      if event_index < event_count then
        let e = List.nth state.events event_index in
        Printf.sprintf "%s[%s]%s %s"
          Ansi.dim e.timestamp Ansi.reset
          (fit_width (Terminal_text.single_line e.content) (panel_width - 12))
      else ""
    in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s %s %s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width attention_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width event_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset)
  done;

  box_divider buf cols;

  (* Tasks section *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %sTasks%s %s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold Ansi.reset
    (String.make (max 0 (cols - 10)) ' ')
    Ansi.gray Ansi.box_v Ansi.reset);

  (match tasks_error with
   | Some err when row_budget.task_error_rows > 0 ->
        box_line buf cols
          (Ansi.red ^ "  "
          ^ fit_width err (cols - 8)
          ^ Ansi.reset)
   | None | Some _ -> ());
  if row_budget.task_rows > 0 && List.is_empty state.tasks
     && Option.is_none tasks_error then
    box_line buf cols (Ansi.dim ^ "  (no tasks)" ^ Ansi.reset)
  else
    for i = 0 to row_budget.task_rows - 1 do
      let t = List.nth state.tasks i in
      box_line buf cols (task_line t)
    done;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:events  q:quit  r:refresh  Tab:next  2:keepers  | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim state.refresh_interval state.port Ansi.reset);

  finish_frame ~surface_key:"overview" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

(** Render the Approvals surface (pending confirmations). *)
let render_approvals (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let approvals = approval_items state in
  let scope, visible_count, total_count, hidden_count =
    match state.approval_snapshot with
    | None -> "-", "?", "?", "?"
     | Some snapshot ->
        ( (if snapshot.aps_filter_active then
             Terminal_text.single_line_or ~default:"?"
               snapshot.aps_actor_filter
           else "all")
        , string_of_int snapshot.aps_visible_count
        , string_of_int snapshot.aps_total_count
        , string_of_int snapshot.aps_hidden_count )
  in
  let count = List.length approvals in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  let action_badge = if action_inflight then "  [submitting]" else "" in
  let header =
    Printf.sprintf
      " MASC Approvals (%s/%s, hidden %s, actor %s)  %s  %s%s"
      visible_count total_count hidden_count scope timestamp
      (connection_badge state.connection_status) action_badge
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let approvals_error =
    Terminal_text.optional_single_line state.approvals_error
  in
  if count = 0 then begin
    (match state.approval_snapshot, approvals_error with
     | _, Some err ->
         box_line buf cols
           (Ansi.red ^ "  (data unreliable: "
           ^ fit_width err (cols - 24)
           ^ ")" ^ Ansi.reset)
     | None, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no approval data — press 'r' to refresh)"
           ^ Ansi.reset)
     | Some _, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset));
    for _ = 1 to rows - 10 do
      box_empty buf cols
    done
  end else begin
    let content_height = max 0 (rows - 10) in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let a = List.nth approvals idx in
        let is_selected = idx = state.approval_cursor in
        let target_id =
          Terminal_text.single_line_or ~default:"-" a.ap_target_id
        in
        let line =
          Printf.sprintf "  %s  %s  %s  %s"
            (fit_width (Terminal_text.single_line a.ap_actor) 16)
            (fit_width (Terminal_text.single_line a.ap_action_type) 20)
            (fit_width (Terminal_text.single_line a.ap_target_type) 16)
            target_id
        in
        let content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
          else
            "  " ^ line
        in
        box_line buf cols content
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  let detail_line =
    if state.approval_cursor < count then
      let a = List.nth approvals state.approval_cursor in
      if action_inflight then
        Printf.sprintf "  %sApproval request in progress…%s" Ansi.yellow
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
          Printf.sprintf "  %sPress %s again: %s%s" Ansi.yellow key
            (fit_width (Terminal_text.single_line a.ap_summary) (cols - 22))
            Ansi.reset
      | _ ->
          Printf.sprintf "  %s%s%s"
            Ansi.dim
            (fit_width (Terminal_text.single_line a.ap_summary) (cols - 6))
            Ansi.reset
    else
      ""
  in
  Buffer.add_string buf (Printf.sprintf "%s\n" detail_line);

  let metadata_line, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> "", ""
    | Some approval ->
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
  in
  Buffer.add_string buf (Printf.sprintf "%s\n%s\n" metadata_line payload_line);

  Buffer.add_string buf
    (Printf.sprintf
       "%s  j/k:move  y/y:confirm  n/n:deny  r:refresh  Tab:next  | Port: %d%s\n"
       Ansi.dim state.port Ansi.reset);

  finish_frame ~surface_key:"approvals" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

(** Render the Board surface (list view). *)
let render_board_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  let header = Printf.sprintf " MASC Board (%d)  %s  %s"
    count timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let board_list_error =
    Terminal_text.optional_single_line state.board_list_error
  in
  let render_list_error err =
    box_line buf cols
      (Ansi.red ^ "  (data unreliable: "
      ^ fit_width err (max 1 (cols - 24))
      ^ ")" ^ Ansi.reset)
  in
  if count = 0 then begin
    (match board_list_error with
     | Some err -> render_list_error err
     | None ->
         box_line buf cols (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset));
    for _ = 1 to rows - 7 do
      box_empty buf cols
    done
  end else begin
    Option.iter render_list_error board_list_error;
    let error_rows = if Option.is_some board_list_error then 1 else 0 in
    let content_height = max 0 (rows - 7 - error_rows) in
    let scroll_offset =
      if state.board_cursor >= content_height then
        state.board_cursor - content_height + 1
      else 0
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let p = List.nth state.board_posts idx in
        let is_selected = idx = state.board_cursor in
        let line =
          Printf.sprintf "  %s  %s  %s  +%d  c%d"
            (fit_width (Terminal_text.single_line p.bp_id) 12)
            (fit_width (Terminal_text.single_line p.bp_author) 16)
            (fit_width (Terminal_text.single_line p.bp_title) (cols - 52))
            p.bp_votes
            p.bp_comment_count
        in
        let content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
          else
            "  " ^ line
        in
        box_line buf cols content
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  Enter:read  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  finish_frame ~surface_key:"board-list" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

(** Render the Board surface (read view). *)
let render_board_read (state : state) (list_post : board_post) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let detail =
    Board_detail.view_for state.board_detail ~post_id:list_post.bp_id
  in
  let post =
    match detail with
    | Board_detail.Ready (detail_post, _) -> detail_post
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        list_post
  in

  let header = Printf.sprintf " MASC Board  %s[%s]%s  by %s  +%d  c%d"
    Ansi.cyan
    (fit_width (Terminal_text.single_line post.bp_id) 12)
    Ansi.reset
    (Terminal_text.single_line post.bp_author)
    post.bp_votes post.bp_comment_count
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let title_line = Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line post.bp_title) (cols - 6))
    Ansi.reset
  in
  box_line buf cols title_line;
  box_line buf cols
    (Ansi.dim ^ "  "
    ^ fit_width (Terminal_text.single_line post.bp_created_at) 40
    ^ Ansi.reset);
  box_divider buf cols;

  (* Body lines *)
  let text_width = cols - 8 in
  let body_lines =
    Message_layout.wrap_words ~max_cells:text_width
      (Terminal_text.single_line post.bp_body)
  in
  let total_lines = List.length body_lines in
  let detail_lines =
    match detail with
    | Board_detail.Absent ->
        [Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset]
    | Board_detail.Loading ->
        [Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset]
    | Board_detail.Failed error ->
        [ Ansi.red ^ "  Board detail unavailable: "
          ^ fit_width (Terminal_text.single_line error) (max 1 (cols - 32))
          ^ Ansi.reset
        ]
    | Board_detail.Ready (_, comments) ->
        List.map
          (fun c ->
             Printf.sprintf "  %s: %s"
               (fit_width (Terminal_text.single_line c.bc_author) 16)
               (fit_width (Terminal_text.single_line c.bc_content) (cols - 24)))
          comments
  in
  let detail_line_count = List.length detail_lines in
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
  state.board_scroll <- scroll.normalized_scroll;
  for i = 0 to content_height - 1 do
    let idx = i + scroll.body_offset in
    if idx < total_lines then
      box_line buf cols ("  " ^ List.nth body_lines idx)
    else
      box_empty buf cols
  done;

  if comment_height > 0 then begin
    box_divider buf cols;
    box_line buf cols (Ansi.bold ^ "  Comments" ^ Ansi.reset);
    for i = 0 to comment_height - 1 do
      box_line buf cols (List.nth detail_lines (i + scroll.comment_offset))
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  finish_frame ~surface_key:"board-read" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

let planning_phase_label phase = Goal_phase.to_string phase

let planning_phase_color = function
  | Goal_phase.Executing -> Ansi.cyan
  | Goal_phase.Verifying -> Ansi.magenta
  | Goal_phase.Completed -> Ansi.green
  | Goal_phase.Dropped -> Ansi.gray

(** Render the Planning surface (list view). *)
let render_planning_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Planning  %s  %s"
    timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p -> planning_visible_goals p.pl_goals
  in
  let count = List.length goals in
  let planning_error =
    Terminal_text.optional_single_line state.planning_error
  in

  (match state.planning with
   | None ->
       (match planning_error with
        | Some err ->
            box_line buf cols
              (Ansi.red ^ "  (data unreliable: "
              ^ fit_width err (cols - 24)
              ^ ")" ^ Ansi.reset)
        | None ->
            box_line buf cols (Ansi.dim ^ "  (no planning data)" ^ Ansi.reset));
       for _ = 1 to rows - 10 do
         box_empty buf cols
       done
   | Some p ->
       let rollup =
         Printf.sprintf
           "  Executing: %d  Verifying: %d  Done: %d  Dropped: %d"
           p.pl_rollup.pr_active
           p.pl_rollup.pr_verifying p.pl_rollup.pr_done
           p.pl_rollup.pr_dropped
       in
       let backlog =
         Printf.sprintf "  Backlog: todo=%d  claimed=%d  running=%d  done=%d  cancelled=%d"
           p.pl_backlog.pb_todo p.pl_backlog.pb_claimed p.pl_backlog.pb_running
           p.pl_backlog.pb_done p.pl_backlog.pb_cancelled
       in
       box_line buf cols (Ansi.bold ^ rollup ^ Ansi.reset);
       box_line buf cols (Ansi.dim ^ backlog ^ Ansi.reset);
       box_divider buf cols;

       if count = 0 then begin
         box_line buf cols (Ansi.dim ^ "  (no goals)" ^ Ansi.reset);
         for _ = 1 to rows - 11 do
           box_empty buf cols
         done
       end else begin
         let content_height = rows - 12 in
         let scroll_offset =
           if state.planning_cursor >= content_height then
             state.planning_cursor - content_height + 1
           else 0
         in
         for i = 0 to content_height - 1 do
           let idx = i + scroll_offset in
           if idx < count then begin
             let g = List.nth goals idx in
             let is_selected = idx = state.planning_cursor in
             let depth = planning_goal_depth p.pl_goals g in
             let indent = String.make (depth * 2) ' ' in
             let branch = if depth > 0 then "└─ " else "  " in
             let status_color = planning_phase_color g.pg_phase in
             let status_label = planning_phase_label g.pg_phase in
            let due =
              match Terminal_text.optional_single_line g.pg_due_date with
              | Some d -> "  " ^ d
              | None -> ""
            in
             let line =
               Printf.sprintf "%s%s%s[%s]%s P%d  %s%s"
                 indent branch status_color
                 (fit_width status_label 8)
                 Ansi.reset
                 g.pg_priority
                 (fit_width
                    (Terminal_text.single_line g.pg_title)
                    (cols - 30 - (depth * 2)
                   - Message_layout.display_width due))
                 (Ansi.dim ^ due ^ Ansi.reset)
             in
             let content =
               if is_selected then
                 Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
               else
                 "  " ^ line
             in
             box_line buf cols content
           end else
             box_empty buf cols
         done
       end);

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  Enter:detail  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  finish_frame ~surface_key:"planning-list" ~cursor:Frame_presenter.Hidden
    ~rows ~cols buf

(** Render the Planning surface (detail view). *)
let render_planning_detail (state : state) (goal : planning_goal) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  let status_color = planning_phase_color goal.pg_phase in
  let status_label = planning_phase_label goal.pg_phase in
  let header = Printf.sprintf " MASC Planning  %s[%s]%s  %s"
    status_color (fit_width status_label 8) Ansi.reset
    (fit_width (Terminal_text.single_line goal.pg_id) 20)
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols (Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line goal.pg_title) (cols - 6))
    Ansi.reset);
  box_line buf cols (Printf.sprintf "  Phase: %s  Priority: P%d"
    (fit_width (planning_phase_label goal.pg_phase) 14) goal.pg_priority);
  (match Terminal_text.optional_single_line goal.pg_due_date with
   | Some d ->
       box_line buf cols
         (Printf.sprintf "  Due: %s" d)
   | None -> box_empty buf cols);
  (match Terminal_text.optional_single_line goal.pg_metric with
   | Some m ->
       let target =
         match Terminal_text.optional_single_line goal.pg_target_value with
         | Some t -> " = " ^ t
         | None -> ""
       in
       box_line buf cols
         (Printf.sprintf "  Metric: %s%s" m target)
   | None -> box_empty buf cols);
  box_empty buf cols;
  box_divider buf cols;

  for _ = 1 to rows - 14 do
    box_empty buf cols
  done;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  finish_frame ~surface_key:"planning-detail" ~cursor:Frame_presenter.Hidden
    ~rows ~cols buf

(** Render the keeper list view *)
(* Status is shown as a glyph and a word. The glyph is the coarse reading an
   operator scans a column for -- a fiber running, a fiber sleeping, no fiber,
   nothing observed -- and the word next to it is the exact published status,
   so the column stays legible at four shapes instead of needing a distinct
   glyph per label. *)
let keeper_status_glyph (status : Status.control_plane_status option) =
  match status with
  | None -> (Ansi.dim, "?")
  | Some Status.Cp_paused -> (Ansi.yellow, "\xe2\x97\x8b")
  | Some (Status.Cp_surface surface) -> (
      match surface with
      | Status.Surface_active -> (Ansi.green, "\xe2\x97\x8f")
      | Status.Surface_busy -> (Ansi.cyan, "\xe2\x97\x8f")
      | Status.Surface_listening -> (Ansi.blue, "\xe2\x97\x8f")
      | Status.Surface_idle -> (Ansi.gray, "\xe2\x97\x8f")
      | Status.Surface_inactive -> (Ansi.yellow, "\xe2\x97\x90")
      | Status.Surface_offline -> (Ansi.gray, "\xc3\x97"))

let keeper_status_word (status : Status.control_plane_status option) =
  match status with
  | None -> "unknown"
  | Some value -> Status.control_plane_status_to_string value

(* The runtime id is [provider.model], and the provider half repeats inside the
   model half often enough that printing both costs the column its width. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> "\xe2\x80\x94"
  | Some row -> (
      let raw = Terminal_text.single_line row.kr_runtime_id in
      match String.index_opt raw '.' with
      | Some idx when idx + 1 < String.length raw ->
          String.sub raw (idx + 1) (String.length raw - idx - 1)
      | Some _ | None -> raw)

(* Two dispositions an operator needs before stopping anything: whether the
   keeper comes back by itself, and whether it takes turns without being
   asked. Both are on the roster row. *)
let keeper_flag_cell (runtime : keeper_runtime option) =
  match runtime with
  | None -> Ansi.dim ^ "- -" ^ Ansi.reset
  | Some row ->
      let flag enabled letter =
        if enabled then Ansi.cyan ^ letter ^ Ansi.reset
        else Ansi.dim ^ "-" ^ Ansi.reset
      in
      flag row.kr_autoboot_enabled "A" ^ " " ^ flag row.kr_proactive_enabled "P"

(* Column header labels line up with the cell budgets
   [Render_schedule.allocate_keeper_columns] hands out, so the arithmetic lives
   in one tested place instead of once here and once in the row. *)
let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Printf.sprintf "%-*s" Render_schedule.keeper_status_width "STATUS"
    ; " "
    ; Printf.sprintf "%-*s" columns.kcol_name "KEEPER"
    ; (if columns.kcol_show_flags then
         " " ^ Printf.sprintf "%-*s" Render_schedule.keeper_flags_width "A P"
       else "")
    ; Printf.sprintf " %*s" Render_schedule.keeper_turns_width "TURNS"
    ; (if columns.kcol_show_runtime then
         " " ^ Printf.sprintf "%-*s" columns.kcol_runtime "RUNTIME"
       else "")
    ; " "
    ; "TASK"
    ]

(* Each cell is fitted as plain text and styled afterwards, so a long keeper
   name cannot push the columns to its right out of the frame and the style
   bytes never count toward the width. *)
let keeper_row_content ~(columns : Render_schedule.keeper_columns) ~selected
    ~status ~keeper ~runtime =
  let status_color, glyph = keeper_status_glyph status in
  (* Same gutter marker the Approvals, Board and Planning lists draw. A
     selection cursor that changes shape when the operator switches surface
     reads as a different control, not the same one. *)
  let marker = if selected then Ansi.reverse ^ ">" ^ Ansi.reset else " " in
  let name =
    fit_width (Terminal_text.single_line keeper.k_name) columns.kcol_name
  in
  let task =
    fit_width
      (Terminal_text.single_line_or ~default:"\xe2\x80\x93"
         keeper.k_current_task_id)
      columns.kcol_task
  in
  String.concat ""
    [ " "
    ; marker
    ; " "
    ; status_color ^ glyph ^ " "
      ^ fit_width (keeper_status_word status)
          (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; " "
    ; (if selected then Ansi.bold ^ name ^ Ansi.reset else name)
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; Printf.sprintf " %s%*d%s" Ansi.dim Render_schedule.keeper_turns_width
        keeper.k_total_turns Ansi.reset
    ; (if columns.kcol_show_runtime then
         " " ^ Ansi.gray
         ^ fit_width (keeper_runtime_label runtime) columns.kcol_runtime
         ^ Ansi.reset
       else "")
    ; " "
    ; Ansi.dim ^ task ^ Ansi.reset
    ]

(* The footer names the action behind each key for the keeper under the cursor,
   because which action the toggle sends depends on that keeper's state. A key
   with nothing behind it is dimmed rather than dropped, so the row of keys
   does not shift as the cursor travels. *)
let keeper_action_hints ?(offers_chat = true) state reading =
  let available =
    match reading with None -> [] | Some r -> Keeper_control.available r
  in
  (* An action that ends a fiber is toned apart from the reversible ones, so the
     key that needs two presses does not read like the keys that need one. *)
  let hint action label =
    let key_color =
      if Keeper_control.requires_confirmation action then Ansi.red else Ansi.cyan
    in
    if List.mem action available then
      Printf.sprintf "%s%s%s %s" key_color (Keeper_control.action_key action)
        Ansi.reset label
    else
      Printf.sprintf "%s%s %s%s" Ansi.dim (Keeper_control.action_key action)
        label Ansi.reset
  in
  let toggle =
    match Option.bind reading Keeper_control.primary with
    | Some action -> hint action (Keeper_control.action_label action)
    | None -> Printf.sprintf "%sp pause%s" Ansi.dim Ansi.reset
  in
  match (state.keeper_action_inflight, state.keeper_action_pending) with
  | Some (keeper_name, action), _ ->
      Printf.sprintf "  %s%s %s\xe2\x80\xa6%s" Ansi.cyan
        (Keeper_control.action_gerund action)
        (Terminal_text.single_line keeper_name)
        Ansi.reset
  | None, Some pending ->
      Printf.sprintf "  %s%spress %s again to %s %s%s" Ansi.bold Ansi.yellow
        (Keeper_control.action_key pending.Keeper_control.pending_action)
        (Keeper_control.action_label pending.Keeper_control.pending_action)
        (Terminal_text.single_line pending.Keeper_control.pending_keeper)
        Ansi.reset
  | None, None ->
      "  "
      ^ String.concat
          (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset)
          [ Ansi.dim ^ "j/k move" ^ Ansi.reset
          ; toggle
          ; hint Keeper_control.Wakeup "wake"
          ; hint Keeper_control.Shutdown "shutdown"
          ; Ansi.cyan ^ "l" ^ Ansi.reset ^ " logs"
            (* Dimmed rather than dropped, the same way an unavailable
               lifecycle key is: chat lives in detail, and a key that vanishes
               between surfaces reads as a key that does not exist. *)
          ; (if offers_chat then Ansi.cyan ^ "c" ^ Ansi.reset ^ " chat"
             else Ansi.dim ^ "c chat" ^ Ansi.reset)
          ; (if offers_chat then Ansi.dim ^ "esc back" ^ Ansi.reset
             else Ansi.cyan ^ "enter" ^ Ansi.reset ^ " detail")
          ; Ansi.dim ^ "r refresh" ^ Ansi.reset
          ; Ansi.dim ^ "q quit" ^ Ansi.reset
          ]

(* Counted from the same readings the rows are drawn from, so the heading
   cannot disagree with the list under it. *)
let keeper_roster_summary readings =
  let tally (live, paused, offline, unknown) reading =
    match Keeper_control.display_status reading with
    | None -> (live, paused, offline, unknown + 1)
    | Some Status.Cp_paused -> (live, paused + 1, offline, unknown)
    | Some (Status.Cp_surface Status.Surface_offline) ->
        (live, paused, offline + 1, unknown)
    | Some
        (Status.Cp_surface
           ( Status.Surface_active | Status.Surface_busy
           | Status.Surface_listening | Status.Surface_idle
           | Status.Surface_inactive )) ->
        (live + 1, paused, offline, unknown)
  in
  let live, paused, offline, unknown =
    List.fold_left tally (0, 0, 0, 0) readings
  in
  [ (live, "running", Ansi.green)
  ; (paused, "paused", Ansi.yellow)
  ; (offline, "offline", Ansi.gray)
  ; (unknown, "unread", Ansi.dim)
  ]
  |> List.filter (fun (count, _, _) -> count > 0)
  |> List.map (fun (count, label, color) ->
         Printf.sprintf "%s%d %s%s" color count label Ansi.reset)

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
    [ (never_started, "not running", Ansi.red)
    ; (running_without_turn, "running, cannot take a turn", Ansi.yellow)
    ]

let render_keeper_list (state : state) =
  let rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let inner = max 1 (cols - 4) in
  let readings = List.map (keeper_reading state) state.keepers in
  let selected_reading =
    Option.map (keeper_reading state) (selected_keeper state)
  in

  Buffer.add_string buf
    (Printf.sprintf "%s%s%s%s%s\n" Ansi.gray Ansi.box_tl
       (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading =
    Printf.sprintf " %sMASC Keepers (%d)%s" Ansi.bold (List.length state.keepers)
      Ansi.reset
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
    (Printf.sprintf "%s%s%s%s%s\n" Ansi.gray Ansi.box_l (draw_hline (cols - 2))
       Ansi.box_r Ansi.reset);

  (match (state.fleet_safety, state.fleet_safety_error) with
   | _, Some err ->
       box_line buf cols
         (Ansi.red ^ "  fleet: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None, None -> ()
   | Some fleet, None ->
       let tone =
         if fleet.fs_operator_action_required then Ansi.red
         else if String.equal fleet.fs_status "ok" then Ansi.green
         else Ansi.yellow
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
     is why the lifecycle keys stop offering anything. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         (Ansi.yellow ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_roster with
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %d keepers; the rest read as unknown%s"
            Ansi.yellow (List.length observed) total Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  let columns = Render_schedule.allocate_keeper_columns ~inner_width:inner in
  box_line_styled buf cols ~style:Ansi.dim (keeper_column_header columns);
  Buffer.add_string buf
    (Printf.sprintf "%s%s%s%s%s\n" Ansi.gray Ansi.box_l (draw_hline (cols - 2))
       Ansi.box_r Ansi.reset);

  let keepers_error = Terminal_text.optional_single_line state.keepers_error in
  (match keepers_error with
   | Some err -> box_line buf cols (Ansi.red ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = List.length (frame_lines buf) in
  let footer_rows = 2 in
  let keeper_rows = max 0 (rows - chrome_rows - footer_rows) in
  let keeper_count = List.length state.keepers in
  let scroll_offset =
    if keeper_rows > 0 && state.keeper_cursor >= keeper_rows then
      state.keeper_cursor - keeper_rows + 1
    else 0
  in
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
        (List.nth_opt state.keepers position, List.nth_opt readings position)
      with
      | Some keeper, Some reading ->
          let runtime =
            match reading.Keeper_control.liveness with
            | Keeper_control.Present row -> Some row
            | Keeper_control.Absent | Keeper_control.Unobserved -> None
          in
          box_line buf cols
            (keeper_row_content ~columns
               ~selected:(position = state.keeper_cursor)
               ~status:(Keeper_control.display_status reading) ~keeper ~runtime)
      | Some _, None | None, Some _ | None, None -> box_empty buf cols
    done;

  Buffer.add_string buf
    (Printf.sprintf "%s%s%s%s%s\n" Ansi.gray Ansi.box_bl (draw_hline (cols - 2))
       Ansi.box_br Ansi.reset);
  Buffer.add_string buf
    (keeper_action_hints ~offers_chat:false state selected_reading ^ "\n");

  finish_frame ~surface_key:"keeper-list" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

(** Render keeper detail view with live context and scrolling *)
let render_keeper_detail (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame ~surface_key:"keeper-detail" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let inner = cols - 4 in  (* width inside borders *)

    (* Build all detail lines first, then apply scroll *)
    let lines = ref [] in
    let add_line s = lines := s :: !lines in

    (* Helper to add a labeled row *)
    let add_row label value =
      add_line (Printf.sprintf "  %s%-22s%s %s" Ansi.cyan label Ansi.reset value)
    in
    let add_empty () = add_line "" in
    let add_section title =
      add_line (Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" (Terminal_text.single_line k.k_name);
    add_row "Paused:"
      (if k.k_paused then Ansi.yellow ^ "yes" ^ Ansi.reset
       else Ansi.dim ^ "no" ^ Ansi.reset);
    add_empty ();

    (* Current work section *)
    add_section "Current Work";
    add_row "Task:"
      (Terminal_text.single_line_or ~default:"-" k.k_current_task_id);
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    (match
       Terminal_text.optional_single_line state.live_context_error,
       state.live_context
     with
     | Some error, _ ->
         add_row "Context:" (Ansi.red ^ error ^ Ansi.reset)
     | None, Some observation ->
         (match Observation_layout.context_summary observation with
          | Observation_layout.Context_measured observation ->
              let ratio = observation.ratio in
              let pct = ratio *. 100.0 in
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
              add_row "Context:"
                (Printf.sprintf "%d tokens; context window not observed"
                   observation.tokens);
              add_row "Observed:"
                (Terminal_text.short_timestamp observation.observed_at);
              add_row "Turn Ref:"
                (Terminal_text.single_line observation.turn_ref)
          | Observation_layout.Context_unavailable reason ->
              add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset))
     | None, None ->
         add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset));
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (Terminal_text.short_timestamp k.k_last_turn_ts);
    add_row "Compactions:" (string_of_int k.k_compaction_count);
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

    (* Autonomy section *)
    add_section "Autonomy";
    add_row "Autonomous Turns:"
      (string_of_int k.k_autonomous_turn_count);
    add_row "Text / Tool:"
      (Printf.sprintf "%d / %d" k.k_autonomous_text_turn_count
         k.k_autonomous_tool_turn_count);
    add_row "Board / Mention:"
      (Printf.sprintf "%d / %d" k.k_board_reactive_turn_count
         k.k_mention_reactive_turn_count);
    add_row "No-op Turns:" (string_of_int k.k_noop_turn_count);
    add_row "Last Outcome:" k.k_last_proactive_outcome;
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (Terminal_text.short_timestamp k.k_created_at);
    add_row "Updated:" (Terminal_text.short_timestamp k.k_updated_at);

    (* Reverse to get correct order *)
    let all_lines = List.rev !lines in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title *)
    let title =
      Printf.sprintf " Keeper: %s%s%s " Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset
    in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      title
      (String.make (max 0 (inner - String.length title + 10)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling *)
    let content_height = max 0 (rows - 6) in  (* header + title + divider + bottom + footer + extra *)
    let visible_lines = min content_height total_lines in
    let scroll =
      Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
        ~content_height state.detail_scroll
    in
    state.detail_scroll <- scroll;

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (List.nth all_lines idx)
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

    (* Footer. The lifecycle keys work here as well as on the roster, so the
       footer names the same actions with the same keys; a detail view that
       listed a different set would read as a different set of powers. *)
    Buffer.add_string buf
      (keeper_action_hints state (Some (keeper_reading state k)) ^ "\n");

    finish_frame ~surface_key:"keeper-detail" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame ~surface_key:"keeper-logs" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header =
      Printf.sprintf " Keeper Logs: %s  (%d entries)"
        (Terminal_text.single_line k.k_name)
        total_entries
    in

    box_top buf cols;
    box_line_styled buf cols ~style:Ansi.bold header;
    box_divider buf cols;

    (* Column header *)
    let col_hdr =
      Printf.sprintf "  %-8s %-4s %-8s %5s %13s %9s %9s  %-10s" "Time"
        "Kind" "Channel" "Msgs" "In/Out" "Lat" "Cost" "Work"
    in
    box_line_styled buf cols ~style:Ansi.dim col_hdr;
    box_divider buf cols;

    (match state.log_error with
      | None -> ()
      | Some error ->
          let style =
            match error with
            | Metrics_tail.Storage_error _ -> Ansi.red
            | Metrics_tail.Row_errors _ -> Ansi.yellow
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
    state.log_scroll <- scroll;

    if total_entries = 0 then begin
      box_line_styled buf cols ~style:Ansi.dim
        ("  " ^ Metrics_tail.empty_message state.log_error);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx < total_entries then begin
          let e = List.nth state.log_entries idx in
          (* Extract just the time portion from ts *)
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
          box_line buf cols line
        end else
          box_empty buf cols
      done
    end;

    (* Scroll indicator *)
    if total_entries > content_height then begin
      let indicator =
        Printf.sprintf "[%d/%d entries, scroll %d]" total_entries total_entries
          scroll
      in
      box_line_styled buf cols ~style:Ansi.dim indicator
    end;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    finish_frame ~surface_key:"keeper-logs" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  end

(** Render message input/conversation view *)
let render_keeper_message (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  match state.msg_target_keeper_name with
  | None ->
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame ~surface_key:"keeper-message" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  | Some keeper_name ->
    let display_keeper_name = Keeper_chat.terminal_safe_text keeper_name in
    let header =
      Printf.sprintf " Message to: %s  (port %d)" display_keeper_name state.port
    in
    let target_registered =
      keeper_available_for_new_message state keeper_name
    in
    let status_rows = keeper_message_status_rows state in
    if
      not
        (Message_layout.message_viewport_supported ~terminal_rows:rows
           ~terminal_cols:cols ~status_rows)
    then begin
      let notice =
        " Keeper chat needs a larger terminal; resize to type (Ctrl-R:recover, Esc:back)"
      in
      Buffer.add_string buf
        (Message_layout.fit_width notice (max 1 (cols - 1)));
      finish_frame ~surface_key:"keeper-message"
        ~cursor:Frame_presenter.Hidden ~rows ~cols buf
    end else begin
    (* Header *)
    box_top buf cols;
    box_line_styled buf cols ~style:Ansi.bold header;
    box_divider buf cols;

    (* Message history *)
    let history_height = max 0 (rows - 10 - status_rows) in
    let messages = chat_rows_for state keeper_name in
    let layout_entries =
      List.map
        (fun message ->
          let style, role_label =
            match message.me_role with
            | Message_user -> Message_layout.User, "you"
            | Message_keeper ->
                ( Message_layout.Keeper
                , Keeper_chat.terminal_safe_text message.me_keeper_name )
            | Message_status -> Message_layout.Status, "status"
            | Message_error -> Message_layout.Error, "error"
            | Message_tool -> Message_layout.Tool, "tools"
          in
          ({ style;
             timestamp = message.me_timestamp;
             role_label;
             request_label =
               Keeper_chat.compact_request_id message.me_request_id;
             body = message.me_text;
           }
            : Message_layout.entry))
        messages
    in
    (* Rows for the turn still streaming, drawn under the committed history so
       the streaming reply sits at the bottom edge, where the eye rests while
       waiting for it. Reasoning is kept to its last line: it arrives faster
       than anything else and a full transcript of it would push the reply and
       the tool rows off the pane. *)
    let live_entries =
      match state.msg_live with
      | Some live
        when String.equal (Keeper_chat_transcript.keeper_name live) keeper_name
        ->
          let request_label =
            Keeper_chat.compact_request_id
              (Keeper_chat_transcript.request_id live)
          in
          let entry style role_label body =
            ({ style;
               timestamp = "live";
               role_label;
               request_label;
               body;
             }
              : Message_layout.entry)
          in
          let thinking_tail =
            Keeper_chat_transcript.thinking live
            |> String.split_on_char '\n'
            |> List.filter (fun line -> String.trim line <> "")
            |> List.rev
            |> function
            | [] -> []
            | last :: _ -> [ entry Message_layout.Thinking "thinking" last ]
          in
          let tool_entry =
            match Keeper_chat_transcript.tool_rows live with
            | [] -> []
            | rows ->
                [ entry Message_layout.Tool "tools" (String.concat "\n" rows) ]
          in
          let text_entry =
            match Keeper_chat_transcript.text live with
            | "" -> []
            | text ->
                [ entry Message_layout.Keeper
                    (Keeper_chat.terminal_safe_text
                       (Keeper_chat_transcript.keeper_name live))
                    text
                ]
          in
          thinking_tail @ tool_entry @ text_entry
      | Some _ | None -> []
    in
    let layout_entries = layout_entries @ live_entries in
    let inner_width = max 1 (cols - 4) in
    (* Clamped here rather than where the key is handled: the limit depends on
       the terminal width and the pane's height, and a resize changes both
       under a scroll position that was legal before it. *)
    let scroll =
      min state.msg_scroll
        (Message_layout.max_scroll ~inner_width ~height:history_height
           layout_entries)
    in
    let visible_rows =
      Message_layout.scrolled_rows ~inner_width ~height:history_height
        ~from_bottom:scroll layout_entries
    in

    if visible_rows = [] then begin
      if history_height > 0 then
        box_line_styled buf cols ~style:Ansi.dim
          "  (no messages yet -- type below and press Enter)";
      for _ = 1 to history_height - 1 do
        box_empty buf cols
      done
    end else begin
      List.iter
        (fun (row : Message_layout.row) ->
          let style =
            match row.style with
            | Message_layout.User -> Ansi.cyan
            | Message_layout.Keeper -> Ansi.green
            | Message_layout.Status -> Ansi.yellow
            | Message_layout.Error -> Ansi.red
            | Message_layout.Tool -> Ansi.dim
            | Message_layout.Thinking -> Ansi.dim
          in
          box_line_styled buf cols ~style row.text)
        visible_rows;
      (* Fill remaining space *)
      for _ = List.length visible_rows to history_height - 1 do
        box_empty buf cols
      done
    end;

    (* Input area divider *)
    box_divider buf cols;

    (* Input line *)
    (match state.msg_inflight, state.msg_inflight_kind with
     | Some request, Some Dispatch_claim ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (waiting for serialized dispatch %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Operation_get ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (reconciling exact operation %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Cleanup_delete ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (finishing durable cleanup %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Chat_post
       when Option.exists
              (Keeper_chat.same_request_identity request)
              state.msg_unverified ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (replaying exact request %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Chat_post
       when String.equal request.keeper_name keeper_name ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (sending %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Chat_post ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (sending to %s: %s)"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, None ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf "  (processing %s…)"
              (Keeper_chat.compact_request_id request.request_id))
     | None, Some _ | None, None -> ());
    (if scroll > 0 then
       box_line_styled buf cols ~style:Ansi.yellow
         (Printf.sprintf
            "  scrolled back %d row(s); down or Ctrl-E returns to the newest"
            scroll));
    (match state.msg_loaded_error with
     | Some detail ->
         box_line_styled buf cols ~style:Ansi.yellow
           ("  saved conversation could not be loaded; showing this session \
             only: " ^ detail)
     | None -> ());
    (if state.msg_loaded_dropped > 0 then
       box_line_styled buf cols ~style:Ansi.yellow
         (Printf.sprintf
            "  %d saved row(s) could not be read and are not shown"
            state.msg_loaded_dropped));
    (match state.msg_live with
     | Some live ->
         List.iter
           (fun (kind, text) ->
             let style =
               match kind with
               | Keeper_chat_transcript.Progress -> Ansi.dim
               | Keeper_chat_transcript.Attention -> Ansi.yellow
             in
             box_line_styled buf cols ~style ("  " ^ text))
           (Keeper_chat_transcript.status_rows live)
     | None -> ());
    (match state.msg_prepared with
     | Some request when state.msg_inflight = None ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf
              "  prepared fence: %s %s; Ctrl-R retries the first serialized dispatch"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some _ | None -> ());
    (match state.msg_unverified, state.msg_inflight_kind with
     | Some request, Some Dispatch_claim ->
         box_line_styled buf cols ~style:Ansi.red
           (Printf.sprintf
              "  prior outcome unverified: %s %s; waiting for the serialized phase recheck"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Chat_post ->
         box_line_styled buf cols ~style:Ansi.red
           (Printf.sprintf
              "  prior outcome unverified: %s %s; replaying the same request ID"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Operation_get ->
         box_line_styled buf cols ~style:Ansi.red
           (Printf.sprintf
              "  outcome unverified: %s %s; polling the exact operation"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, Some Cleanup_delete ->
         box_line_styled buf cols ~style:Ansi.red
           (Printf.sprintf
              "  request settled: %s %s; durable cleanup is in progress"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | Some request, None ->
         box_line_styled buf cols ~style:Ansi.red
           (Printf.sprintf
              "  outcome unverified: %s %s; Ctrl-R resumes the exact request"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | None, Some _ | None, None -> ());
    (match state.msg_cleanup_pending with
     | Some request ->
         box_line_styled buf cols ~style:Ansi.yellow
           (Printf.sprintf
              "  request settled: %s %s; Ctrl-R finishes durable cleanup"
              (Keeper_chat.terminal_safe_text request.keeper_name)
              (Keeper_chat.compact_request_id request.request_id))
     | None -> ());
    (match
       state.msg_prepared, state.msg_cleanup_pending, state.msg_recovery_error
     with
     | Some _, _, Some (Recovery_blocked detail) ->
         box_line_styled buf cols ~style:Ansi.red
           ("  prepared recovery blocked; no new request may start: "
          ^ Keeper_chat.terminal_safe_text detail)
     | None, Some _, Some (Recovery_blocked detail) ->
         box_line_styled buf cols ~style:Ansi.red
           ("  cleanup retry failed; no POST or GET will be issued: "
          ^ Keeper_chat.terminal_safe_text detail)
     | None, None, Some (Recovery_blocked detail) ->
         box_line_styled buf cols ~style:Ansi.red
           ("  recovery needs retry; Ctrl-R reloads durable recovery state: "
          ^ Keeper_chat.terminal_safe_text detail)
     | Some _, _, None | None, Some _, None | None, None, None -> ());
    if not target_registered then begin
      let unavailable_message =
        match state.keepers_error with
        | Some _ ->
            "  Keeper roster is unavailable; draft retained; Esc to choose another"
        | None ->
            Printf.sprintf
              "  Keeper %s is no longer registered; draft retained; Esc to choose another"
              display_keeper_name
      in
      box_line_styled buf cols ~style:Ansi.red unavailable_message
    end;
    let input = Buffer.contents state.msg_input in
    let composer =
      Message_layout.composer_lines
        ~max_rows:Message_layout.composer_max_rows input
      |> List.map (Message_layout.input_viewport ~max_cells:(max 0 (cols - 8)))
    in
    (* The cursor sits on the last composer line, which the row budget has
       already made room for. *)
    let visible_input =
      match List.rev composer with [] -> "" | last :: _ -> last
    in
    let input_row =
      Message_layout.input_cursor_row ~terminal_rows:rows ~history_height
        ~status_rows
    in
    List.iteri
      (fun index line ->
        (* Only the first line carries the prompt; the rest line up under it so
           a wrapped thought reads as one message rather than several. *)
        let prefix = if index = 0 then "  > " else "    " in
        box_line_styled buf cols ~style:Ansi.cyan (prefix ^ line))
      composer;

    box_bottom buf cols;

    (* Footer *)
    let enter_hint =
      match state.msg_inflight, state.msg_inflight_kind, state.msg_unverified with
      | Some _, Some Dispatch_claim, _ ->
          "waiting for serialized dispatch  Enter:blocked"
      | Some _, Some Operation_get, _ ->
          "reconciling exact operation  Enter:blocked"
      | Some _, Some Cleanup_delete, _ ->
          "finishing durable cleanup  Enter:blocked"
      | Some _, Some Chat_post, Some _ ->
          "replaying exact request  Enter:blocked"
      | Some _, (Some Chat_post | None), _ -> "Enter:wait for current request"
      | None, Some _, _ -> "Enter:wait for current request"
      | None, None, _ ->
      match state.msg_cleanup_pending, state.msg_prepared, state.msg_recovery_error
      with
      | Some _, _, _ -> "Ctrl-R:finish durable cleanup  Enter:blocked"
      | None, Some _, _ -> "Ctrl-R:retry prepared fence  Enter:blocked"
      | None, None, Some (Recovery_blocked _) ->
          "Ctrl-R:reload exact recovery  Enter:blocked"
      | None, None, None ->
          (match state.msg_unverified, target_registered with
           | Some _, _ -> "Ctrl-R:resume exact request  Enter:blocked"
           | None, false when Option.is_some state.keepers_error ->
               "Enter:disabled (roster unavailable)"
           | None, false -> "Enter:disabled (Keeper unavailable)"
           | None, true -> "Enter:send")
    in
    let scroll_hint =
      if scroll > 0 then "up/down:scroll  Ctrl-E:newest" else "up:scroll back"
    in
    let escape_hint =
      match state.msg_live with
      | Some live
        when Keeper_chat_transcript.interrupt live
             = Keeper_chat_transcript.Not_requested ->
          "Esc:interrupt turn"
      | Some _ -> "Esc:interrupt sent"
      | None -> "Esc:back"
    in
    let footer =
      Printf.sprintf "%s  %s  Ctrl-J:newline  %s  %s  Ctrl-U:clear%s" Ansi.dim
        enter_hint scroll_hint escape_hint Ansi.reset
    in
    Buffer.add_string buf
      (Message_layout.fit_width footer (max 1 (cols - 1)));
    Buffer.add_char buf '\n';

    let input_column =
      Message_layout.input_cursor_column ~terminal_cols:cols
        ~input:visible_input
    in
    finish_frame ~surface_key:"keeper-message"
      ~cursor:
        (Frame_presenter.Visible_at
           { row = input_row; column = input_column })
      ~rows ~cols buf
    end

(* One colour per level so an operator scanning the column sees severity before
   reading the text. A level this build does not name keeps its own text and
   renders unstyled rather than borrowing another level's colour. *)
let system_log_level_style : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> Ansi.dim
  | System_info -> Ansi.reset
  | System_warn -> Ansi.yellow
  | System_error -> Ansi.red
  | System_level_unknown _ -> Ansi.reset

let render_system_logs (state : state) =
  let rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let entries =
    match state.system_logs with None -> [] | Some s -> s.sys_entries
  in
  let total_entries = List.length entries in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.system_logs with
    | None ->
        Printf.sprintf " MASC System Logs  (not loaded)  %s  %s" timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        Printf.sprintf " MASC System Logs (%d of %d, seq %d)  %s  %s"
          total_entries snapshot.sys_total snapshot.sys_latest_seq timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line_styled buf cols ~style:Ansi.bold header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-5s %-16s %-12s %s" "Time" "Level" "Module" "Keeper"
      "Message"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.system_logs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Ansi.red
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.system_logs_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min state.system_logs_scroll max_scroll) in
  state.system_logs_scroll <- scroll;
  if total_entries = 0 then begin
    let empty =
      match state.system_logs_error with
      | Some _ -> "  (load failed; the count above is not a reading)"
      | None -> "  (no entries)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt entries idx with
      | None -> box_empty buf cols
      | Some e ->
          let keeper =
            match e.sl_keeper with None -> "-" | Some name -> name
          in
          let line =
            Printf.sprintf "  %-8s %-5s %-16s %-12s %s"
              (Terminal_text.clock_timestamp e.sl_ts)
              (Masc.Tui_decode.system_log_level_label e.sl_level)
              (Terminal_text.single_line e.sl_module)
              (Terminal_text.single_line keeper)
              (Terminal_text.single_line e.sl_message)
          in
          box_line_styled buf cols ~style:(system_log_level_style e.sl_level) line
    done;
  if total_entries > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d entries, scroll %d]" total_entries scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (Printf.sprintf "%s  j/k:scroll  Tab:next  q:quit  r:refresh  | Port: %d%s\n"
       Ansi.dim state.port Ansi.reset);
  finish_frame ~surface_key:"system-logs" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

(** Dispatch a normal-height render based on the current surface. *)
let render_surface (state : state) =
  match state.view with
  | Overview -> render_overview state
  | Keepers Keeper_list -> render_keeper_list state
  | Keepers Keeper_detail -> render_keeper_detail state
  | Keepers Keeper_logs -> render_keeper_logs state
  | Keepers Keeper_message -> render_keeper_message state
  | Board ->
      (match state.board_mode with
       | Board_list -> render_board_list state
       | Board_read post_id ->
           match List.find_opt (fun p -> p.bp_id = post_id) state.board_posts with
           | Some post -> render_board_read state post
           | None -> render_board_list state)
  | Planning ->
      (match state.planning_mode with
       | Planning_list -> render_planning_list state
       | Planning_detail goal_id ->
           let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
           match List.find_opt (fun g -> g.pg_id = goal_id) goals with
           | Some goal -> render_planning_detail state goal
           | None -> render_planning_list state)
  | Approvals -> render_approvals state
  | System_logs -> render_system_logs state

let render_terminal_too_small ~rows ~cols =
  let buf = Buffer.create 64 in
  Buffer.add_string buf
    (fit_width
       (Printf.sprintf "terminal too small -- resize to at least %d rows; q: quit"
          Render_schedule.Viewport.minimum_fixed_chrome_rows)
       cols);
  Buffer.add_char buf '\n';
  finish_frame ~surface_key:"terminal-too-small"
    ~cursor:Frame_presenter.Hidden ~rows ~cols buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render (state : state) =
  let rows, cols = get_terminal_size () in
  if Render_schedule.Viewport.requires_compact_frame ~rows
  then render_terminal_too_small ~rows ~cols
  else render_surface state
