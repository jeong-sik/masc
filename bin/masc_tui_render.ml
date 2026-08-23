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
module Render_schedule = Masc_tui_render_schedule

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
(* Only offered while the server is unreachable. A hint for an action that
   would be refused is worse than no hint. *)
let server_start_hint : Masc_tui_types.connection_status -> string = function
  | Disconnected | Degraded -> "  s:start server"
  | Connecting | Reconnecting | Connected -> ""

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

  Buffer.add_string buf (Printf.sprintf "%s  j/k:events  q:quit  r:refresh  Tab:next  2:keepers%s  | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim (server_start_hint state.connection_status)
    state.refresh_interval state.port Ansi.reset);

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
let render_keeper_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  (* Header *)
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let keeper_count = List.length state.keepers in
  let header = Printf.sprintf " MASC Keepers (%d)  %s" keeper_count timestamp in

  (* Top border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

  (* Header line *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold header Ansi.reset
    (String.make (max 0 (cols - String.length header - 6)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Column headers *)
  let col_header = Printf.sprintf "  %s  %-20s %5s  %-8s %10s  %s"
    " " "Name" "Gen" "Paused" "Turns" "Current Task" in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.dim (fit_width col_header (cols - 4)) Ansi.reset
    Ansi.gray Ansi.box_v Ansi.reset);

  (* Divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Keeper rows *)
  let content_height = max 0 (rows - 8) in
  let keepers_error =
    Terminal_text.optional_single_line state.keepers_error
  in
  let keeper_rows =
    match keepers_error with
    | None -> content_height
    | Some err ->
        box_line buf cols
          (Ansi.red ^ "  "
          ^ fit_width err (cols - 8)
          ^ Ansi.reset);
        max 0 (content_height - 1)
  in
  let visible_count = min keeper_rows (List.length state.keepers) in
  (* Scroll offset: keep cursor visible *)
  let scroll_offset =
    if keeper_rows > 0 && state.keeper_cursor >= keeper_rows then
      state.keeper_cursor - keeper_rows + 1
    else 0
  in

  if visible_count = 0 then begin
    let empty_rows =
      match keepers_error with
      | Some _ -> keeper_rows
      | None ->
          Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no keepers found in .masc/keepers/)%s %s%s%s%s\n"
            Ansi.gray Ansi.box_v Ansi.reset
            Ansi.dim Ansi.reset
            (String.make (max 0 (cols - 50)) ' ')
            Ansi.gray Ansi.box_v Ansi.reset);
          max 0 (keeper_rows - 1)
    in
    for _ = 1 to empty_rows do
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (String.make (cols - 4) ' ')
        Ansi.gray Ansi.box_v Ansi.reset)
    done
  end else begin
    for i = 0 to keeper_rows - 1 do
      let idx = i + scroll_offset in
      if idx < List.length state.keepers then begin
        let k = List.nth state.keepers idx in
        let is_selected = idx = state.keeper_cursor in
        let paused_str = if k.k_paused then
          Ansi.yellow ^ "yes" ^ Ansi.reset
        else
          Ansi.dim ^ "no" ^ Ansi.reset
        in
        let task_width = max 8 (cols - 58) in
        let current_task =
          fit_width
            (Terminal_text.single_line_or ~default:"-" k.k_current_task_id)
            task_width
        in
        let name_col =
          Printf.sprintf "%-20s" (Terminal_text.single_line k.k_name)
        in
        let gen_col = Printf.sprintf "%5d" k.k_generation in
        let turns_col = Printf.sprintf "%10d" k.k_total_turns in
        let line_content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset
            ^ "  " ^ Ansi.bold ^ name_col ^ Ansi.reset
            ^ " " ^ gen_col
            ^ "  " ^ paused_str
            ^ " " ^ turns_col
            ^ "  " ^ Ansi.dim ^ current_task ^ Ansi.reset
          else
            " "
            ^ "  " ^ name_col
            ^ " " ^ gen_col
            ^ "  " ^ paused_str
            ^ " " ^ turns_col
            ^ "  " ^ Ansi.dim ^ current_task ^ Ansi.reset
        in
        Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
          Ansi.gray Ansi.box_v Ansi.reset
          (fit_width line_content (cols - 4))
          Ansi.gray Ansi.box_v Ansi.reset)
      end else
        Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
          Ansi.gray Ansi.box_v Ansi.reset
          (String.make (cols - 4) ' ')
          Ansi.gray Ansi.box_v Ansi.reset)
    done
  end;

  (* Bottom border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset);

  (* Footer *)
  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  Enter:detail  Tab:next  q:quit  r:refresh%s\n"
    Ansi.dim Ansi.reset);

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
    add_row "Generation:" (string_of_int k.k_generation);
    add_row "Paused:"
      (if k.k_paused then Ansi.yellow ^ "yes" ^ Ansi.reset
       else Ansi.dim ^ "no" ^ Ansi.reset);
    add_empty ();

    (* Current work section *)
    add_section "Current Work";
    add_row "Task:"
      (Terminal_text.single_line_or ~default:"-" k.k_current_task_id);
    add_row "Last Blocker:" (Tui_decode.keeper_blocker_for_terminal k);
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

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  l:logs  m:message  Esc:back  Tab:next  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

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
    let messages =
      List.filter
        (fun message -> String.equal message.me_keeper_name keeper_name)
        state.msg_history
    in
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
    let visible_rows =
      Message_layout.visible_rows ~inner_width:(max 1 (cols - 4))
        ~height:history_height layout_entries
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
    let visible_input =
      Message_layout.input_viewport ~max_cells:(max 0 (cols - 8)) input
    in
    let input_row =
      Message_layout.input_cursor_row ~terminal_rows:rows ~history_height
        ~status_rows
    in
    box_line_styled buf cols ~style:Ansi.cyan
      (Printf.sprintf "  > %s" visible_input);

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
    let footer =
      Printf.sprintf "%s  %s  Esc:back  Ctrl-U:clear line%s" Ansi.dim
        enter_hint Ansi.reset
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
