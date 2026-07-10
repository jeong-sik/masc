(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

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

(** Render the dashboard (original view) *)
let render_dashboard (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  (* Clear screen *)
  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  (* Header *)
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Dashboard  %s[%s]%s  %s  %s"
    Ansi.cyan state.workspace Ansi.reset timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "degraded" -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  (* Top border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

  (* Header line *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (Ansi.bold ^ header)
    (String.make (max 0 (cols - String.length header - 20)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Divider after header *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Calculate panel sizes *)
  let panel_width = (cols - 3) / 2 in  (* -3 for borders *)
  let content_height = rows - 10 in  (* Reserve space for header/footer *)

  (* Agents panel (left side) *)
  let agents_title = " Agents " in
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s%s%s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold agents_title Ansi.reset
    (String.make (max 0 (panel_width - String.length agents_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset)
    " Events "
    (String.make (max 0 (panel_width - 8)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Agent/Event rows *)
  let agent_rows = min content_height (max 3 (List.length state.agents)) in
  for i = 0 to agent_rows - 1 do
    (* Agent column *)
    let agent_str =
      if i < List.length state.agents then
        let a = List.nth state.agents i in
        Printf.sprintf "%s %s%s%s %s%s%s"
          (agent_icon a.name)
          (agent_color a.name) a.name Ansi.reset
          (status_color a.status) a.status Ansi.reset
      else ""
    in
    (* Event column *)
    let event_str =
      if i < List.length state.events then
        let e = List.nth state.events i in
        Printf.sprintf "%s[%s]%s %s"
          Ansi.dim e.timestamp Ansi.reset
          (fit_width e.content (panel_width - 12))
      else ""
    in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s %s %s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width agent_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width event_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset)
  done;

  (* Tasks section divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Tasks header *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %sTasks%s %s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold Ansi.reset
    (String.make (max 0 (cols - 10)) ' ')
    Ansi.gray Ansi.box_v Ansi.reset);

  (* Task rows *)
  let task_rows = min 5 (List.length state.tasks) in
  if task_rows = 0 then
    Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no tasks)%s %s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      Ansi.dim Ansi.reset
      (String.make (max 0 (cols - 15)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset)
  else
    for i = 0 to task_rows - 1 do
      let t = List.nth state.tasks i in
      let claimed_str = match t.claimed_by with
        | Some a -> Printf.sprintf " @%s" a
        | None -> ""
      in
      let task_line = Printf.sprintf "  %s [%s] %s (%s%s) %s"
        (task_status_icon t.status)
        t.id
        t.title
        t.status
        claimed_str
        (priority_indicator t.priority)
      in
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (fit_width task_line (cols - 4))
        Ansi.gray Ansi.box_v Ansi.reset)
    done;

  (* Bottom border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset);

  (* Footer *)
  Buffer.add_string buf (Printf.sprintf "%s  q:quit  r:refresh  Tab:keepers  | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim state.refresh_interval state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render the Overview surface (Dashboard V2 shell/briefing summary). *)
let render_overview (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Overview  %s[%s]%s  %s  %s"
    Ansi.cyan state.workspace Ansi.reset timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "degraded" -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let ov = state.overview in

  (* Summary line *)
  let summary_line =
    match (ov, state.overview_error) with
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
        Printf.sprintf "  Health: %s%s%s  Agents: %d  Approvals: %d  Incidents: %d"
          health_color health_label Ansi.reset
          o.ov_active_agents o.ov_pending_approvals o.ov_incident_count
  in
  box_line buf cols summary_line;

  (* Cluster/project line *)
  (match ov with
   | None -> ()
   | Some o ->
       let cluster_line =
         Printf.sprintf "  Cluster: %s%s%s  Project: %s"
           Ansi.dim (fit_width o.ov_cluster 24) Ansi.reset
           (fit_width o.ov_project 32)
       in
       box_line buf cols cluster_line);

  box_divider buf cols;

  (* Attention panel *)
  let attention_items =
    match ov with
    | None -> []
    | Some o -> o.ov_attention_items
  in
  let panel_width = (cols - 3) / 2 in
  let attention_title = " Attention " in
  let events_title = " Recent Events " in
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s%s%s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold attention_title Ansi.reset
    (String.make (max 0 (panel_width - String.length attention_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset)
    events_title
    (String.make (max 0 (panel_width - String.length events_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  let attention_rows = min 6 (max 1 (List.length attention_items)) in
  for i = 0 to attention_rows - 1 do
    let attention_str =
      if i < List.length attention_items then
        let a = List.nth attention_items i in
        let sev_color = attention_severity_color a.ai_severity in
        let severity_label = attention_severity_label a.ai_severity in
        Printf.sprintf "%s[%s]%s %s"
          sev_color (fit_width severity_label 5) Ansi.reset
          (fit_width a.ai_summary (panel_width - 12))
      else ""
    in
    let event_str =
      if i < List.length state.events then
        let e = List.nth state.events i in
        Printf.sprintf "%s[%s]%s %s"
          Ansi.dim e.timestamp Ansi.reset
          (fit_width e.content (panel_width - 12))
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

  let task_rows = min 5 (List.length state.tasks) in
  if task_rows = 0 then
    box_line buf cols (Ansi.dim ^ "  (no tasks)" ^ Ansi.reset)
  else
    for i = 0 to task_rows - 1 do
      let t = List.nth state.tasks i in
      let claimed_str = match t.claimed_by with
        | Some a -> Printf.sprintf " @%s" a
        | None -> ""
      in
      let task_line = Printf.sprintf "  %s [%s] %s (%s%s) %s"
        (task_status_icon t.status)
        t.id
        t.title
        t.status
        claimed_str
        (priority_indicator t.priority)
      in
      box_line buf cols task_line
    done;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  q:quit  r:refresh  Tab:next  2:keepers  | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim state.refresh_interval state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render the Approvals surface (pending confirmations). *)
let render_approvals (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let approvals =
    match state.overview with
    | None -> []
    | Some o -> o.ov_pending_confirms
  in
  let count = List.length approvals in
  let header = Printf.sprintf " MASC Approvals (%d)  %s  %s"
    count timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "degraded" -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  if count = 0 then begin
    (match state.overview_error with
     | Some err ->
         box_line buf cols
           (Ansi.red ^ "  (data unreliable: "
           ^ fit_width err (cols - 24)
           ^ ")" ^ Ansi.reset)
     | None ->
         box_line buf cols
           (Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset));
    for _ = 1 to rows - 8 do
      box_empty buf cols
    done
  end else begin
    let content_height = rows - 8 in
    let scroll_offset =
      if state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let a = List.nth approvals idx in
        let is_selected = idx = state.approval_cursor in
        let target_id = Option.value ~default:"-" a.ap_target_id in
        let line =
          Printf.sprintf "  %s  %s  %s  %s"
            (fit_width a.ap_actor 16)
            (fit_width a.ap_action_type 20)
            (fit_width a.ap_target_type 16)
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
      match state.pending_approval_action with
      | Some { paa_token; paa_decision }
        when String.equal paa_token a.ap_token ->
          let key =
            match paa_decision with
            | Confirm -> "y"
            | Deny -> "n"
          in
          Printf.sprintf "  %sPress %s again: %s%s" Ansi.yellow key
            (fit_width a.ap_summary (cols - 22))
            Ansi.reset
      | _ ->
          Printf.sprintf "  %s%s%s"
            Ansi.dim (fit_width a.ap_summary (cols - 6)) Ansi.reset
    else
      ""
  in
  Buffer.add_string buf (Printf.sprintf "%s\n" detail_line);

  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  y:confirm  n:deny  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render the Board surface (list view). *)
let render_board_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  let header = Printf.sprintf " MASC Board (%d)  %s  %s"
    count timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "degraded" -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  if count = 0 then begin
    (match state.board_error with
     | Some err ->
         box_line buf cols
           (Ansi.red ^ "  (data unreliable: "
           ^ fit_width err (cols - 24)
           ^ ")" ^ Ansi.reset)
     | None ->
         box_line buf cols (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset));
    for _ = 1 to rows - 7 do
      box_empty buf cols
    done
  end else begin
    let content_height = rows - 7 in
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
            (fit_width p.bp_id 12)
            (fit_width p.bp_author 16)
            (fit_width p.bp_title (cols - 52))
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

  print_string (Buffer.contents buf);
  flush stdout

(** Render the Board surface (read view). *)
let render_board_read (state : state) (post : board_post) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let header = Printf.sprintf " MASC Board  %s[%s]%s  by %s  +%d  c%d"
    Ansi.cyan (fit_width post.bp_id 12) Ansi.reset
    post.bp_author post.bp_votes post.bp_comment_count
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let title_line = Printf.sprintf "  %s%s%s"
    Ansi.bold (fit_width post.bp_title (cols - 6)) Ansi.reset
  in
  box_line buf cols title_line;
  box_line buf cols (Ansi.dim ^ "  " ^ fit_width post.bp_created_at 40 ^ Ansi.reset);
  box_divider buf cols;

  (* Body lines *)
  let text_width = cols - 8 in
  let body_lines =
    let words = String.split_on_char ' ' post.bp_body in
    let rec wrap acc current = function
      | [] -> List.rev (if current = "" then acc else current :: acc)
      | w :: ws ->
          let candidate = if current = "" then w else current ^ " " ^ w in
          if String.length candidate <= text_width then
            wrap acc candidate ws
          else
            wrap (current :: acc) w ws
    in
    wrap [] "" words
  in
  let content_height = rows - 10 in
  let total_lines = List.length body_lines in
  let scroll = min state.board_scroll (max 0 (total_lines - content_height)) in
  for i = 0 to content_height - 1 do
    let idx = i + scroll in
    if idx < total_lines then
      box_line buf cols ("  " ^ List.nth body_lines idx)
    else
      box_empty buf cols
  done;

  if List.length state.board_comments > 0 then begin
    box_divider buf cols;
    box_line buf cols (Ansi.bold ^ "  Comments" ^ Ansi.reset);
    let comment_height = min 5 (List.length state.board_comments) in
    for i = 0 to comment_height - 1 do
      let c = List.nth state.board_comments i in
      let line = Printf.sprintf "  %s: %s"
        (fit_width c.bc_author 16)
        (fit_width c.bc_content (cols - 24))
      in
      box_line buf cols line
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

let planning_status_label = function
  | Planning_goal_active -> "active"
  | Planning_goal_paused -> "paused"
  | Planning_goal_done -> "done"
  | Planning_goal_dropped -> "dropped"

let planning_status_color = function
  | Planning_goal_active -> Ansi.cyan
  | Planning_goal_paused -> Ansi.yellow
  | Planning_goal_done -> Ansi.green
  | Planning_goal_dropped -> Ansi.red

(** Render the Planning surface (list view). *)
let render_planning_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Planning  %s  %s"
    timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "degraded" -> Ansi.yellow ^ "[degraded]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p -> planning_visible_goals p.pl_goals
  in
  let count = List.length goals in

  (match state.planning with
   | None ->
       (match state.planning_error with
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
         Printf.sprintf "  Active: %d  Paused: %d  Done: %d  Dropped: %d"
           p.pl_rollup.pr_active p.pl_rollup.pr_paused p.pl_rollup.pr_done p.pl_rollup.pr_dropped
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
             let status_color = planning_status_color g.pg_status in
             let status_label = planning_status_label g.pg_status in
             let due = match g.pg_due_date with Some d -> "  " ^ d | None -> "" in
             let line =
               Printf.sprintf "%s%s%s[%s]%s P%d  %s%s"
                 indent branch status_color
                 (fit_width status_label 8)
                 Ansi.reset
                 g.pg_priority
                 (fit_width g.pg_title (cols - 30 - (depth * 2) - String.length due))
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

  print_string (Buffer.contents buf);
  flush stdout

(** Render the Planning surface (detail view). *)
let render_planning_detail (state : state) (goal : planning_goal) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  let status_color = planning_status_color goal.pg_status in
  let status_label = planning_status_label goal.pg_status in
  let header = Printf.sprintf " MASC Planning  %s[%s]%s  %s"
    status_color (fit_width status_label 8) Ansi.reset
    (fit_width goal.pg_id 20)
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols (Printf.sprintf "  %s%s%s"
    Ansi.bold (fit_width goal.pg_title (cols - 6)) Ansi.reset);
  box_line buf cols (Printf.sprintf "  Phase: %s  Priority: P%d"
    (fit_width goal.pg_phase 14) goal.pg_priority);
  (match goal.pg_due_date with
   | Some d -> box_line buf cols (Printf.sprintf "  Due: %s" d)
   | None -> box_empty buf cols);
  (match goal.pg_metric with
   | Some m ->
       let target = match goal.pg_target_value with Some t -> " = " ^ t | None -> "" in
       box_line buf cols (Printf.sprintf "  Metric: %s%s" m target)
   | None -> box_empty buf cols);
  (match goal.pg_parent_goal_id with
   | Some pid -> box_line buf cols (Printf.sprintf "  Parent: %s" pid)
   | None -> box_empty buf cols);
  box_divider buf cols;

  for _ = 1 to rows - 14 do
    box_empty buf cols
  done;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  r:refresh  Tab:next  | Port: %d%s\n"
    Ansi.dim state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render the keeper list view *)
let render_keeper_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

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
  let col_header = Printf.sprintf "  %s  %-16s %-14s %5s  %-20s %s  %s"
    " " "Name" "Profile" "Gen" "Model" "Pro" "Goal" in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.dim (fit_width col_header (cols - 4)) Ansi.reset
    Ansi.gray Ansi.box_v Ansi.reset);

  (* Divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Keeper rows *)
  let content_height = rows - 8 in  (* header + column header + footer *)
  let visible_count = min content_height (List.length state.keepers) in
  (* Scroll offset: keep cursor visible *)
  let scroll_offset =
    if state.keeper_cursor >= content_height then
      state.keeper_cursor - content_height + 1
    else 0
  in

  if visible_count = 0 then begin
    Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no keepers found in .masc/keepers/)%s %s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      Ansi.dim Ansi.reset
      (String.make (max 0 (cols - 50)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);
    for _ = 1 to max 0 (content_height - 1) do
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (String.make (cols - 4) ' ')
        Ansi.gray Ansi.box_v Ansi.reset)
    done
  end else begin
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < List.length state.keepers then begin
        let k = List.nth state.keepers idx in
        let is_selected = idx = state.keeper_cursor in
        let model_short = short_model (Option.value ~default:"-" k.k_active_model) in
        let proactive_str = if k.k_proactive_enabled then
          Ansi.green ^ "on" ^ Ansi.reset
        else
          Ansi.gray ^ "--" ^ Ansi.reset
        in
        (* Truncate goal to remaining space *)
        let goal_width = max 10 (cols - 68) in
        let goal_trunc = fit_width k.k_goal goal_width in
        let name_col = Printf.sprintf "%-16s" k.k_name in
        let gen_col = Printf.sprintf "%5d" k.k_generation in
        let model_col = Printf.sprintf "%-20s" model_short in
        let line_content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset
            ^ "  " ^ Ansi.bold ^ name_col ^ Ansi.reset
            ^ " " ^ gen_col
            ^ "  " ^ model_col
            ^ " " ^ proactive_str
            ^ "  " ^ Ansi.dim ^ goal_trunc ^ Ansi.reset
          else
            " "
            ^ "  " ^ name_col
            ^ " " ^ gen_col
            ^ "  " ^ model_col
            ^ " " ^ proactive_str
            ^ "  " ^ Ansi.dim ^ goal_trunc ^ Ansi.reset
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
  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  Enter:detail  Tab:dashboard  q:quit  r:refresh%s\n"
    Ansi.dim Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render keeper detail view with live context and scrolling *)
let render_keeper_detail (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
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
    add_row "Name:" k.k_name;
    add_row "Generation:" (string_of_int k.k_generation);
    add_row "Trigger Mode:" k.k_trigger_mode;
    add_row "Verify:" (bool_indicator k.k_verify);
    add_empty ();

    (* Goals section *)
    add_section "Goals";
    add_row "Goal:" (fit_width k.k_goal (inner - 26));
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    if state.live_context_max > 0 then begin
      let pct = state.live_context_ratio *. 100.0 in
      let bar_width = min 30 (inner - 40) in
      add_row "Context:" (Printf.sprintf "%s%.1f%%%s  %s  %d / %d tokens"
        (ctx_color state.live_context_ratio) pct Ansi.reset
        (ctx_bar state.live_context_ratio bar_width)
        state.live_context_tokens state.live_context_max);
      add_row "Messages:" (string_of_int state.live_message_count);
    end else begin
      add_row "Context:" (Ansi.dim ^ "(no metrics data)" ^ Ansi.reset);
    end;
    add_empty ();

    (* Model section *)
    add_section "Model";
    add_row "Active Model:" (Option.value ~default:"-" k.k_active_model);
    add_row "Available:" (String.concat ", " k.k_models);
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (short_ts k.k_last_turn_ts);
    add_row "Compactions:" (string_of_int k.k_compaction_count);
    add_row "Compaction Gate:" (Printf.sprintf "%.0f%%" (k.k_compaction_ratio_gate *. 100.0));
    add_row "Context Budget:" (string_of_int k.k_context_budget);
    add_row "Handoff Threshold:" (Printf.sprintf "%.0f%%" (k.k_handoff_threshold *. 100.0));
    add_empty ();

    (* Behavior section *)
    add_section "Behavior";
    add_row "Proactive:" (bool_indicator k.k_proactive_enabled);
    add_row "Initiative:" (bool_indicator (Option.value ~default:false k.k_initiative_enabled));
    add_row "Drift:" (bool_indicator k.k_drift_enabled);
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (short_ts k.k_created_at);
    add_row "Updated:" (short_ts k.k_updated_at);

    (* Reverse to get correct order *)
    let all_lines = List.rev !lines in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title *)
    let title = Printf.sprintf " Keeper: %s%s%s " Ansi.bold k.k_name Ansi.reset in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      title
      (String.make (max 0 (inner - String.length title + 10)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling *)
    let content_height = rows - 6 in  (* header + title + divider + bottom + footer + extra *)
    let visible_lines = min content_height total_lines in
    let scroll = min state.detail_scroll (max 0 (total_lines - content_height)) in

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
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  l:logs  m:message  Esc:back  Tab:dashboard  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header = Printf.sprintf " Keeper Logs: %s%s%s  (%d entries)"
      Ansi.bold k.k_name Ansi.reset total_entries in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* Column header *)
    let col_hdr = Printf.sprintf "%s  %-8s %-5s %-7s %12s %8s %7s %6s  %-10s%s"
      Ansi.dim "Time" "Chan" "Ctx" "Tokens" "In/Out" "Lat" "Cost" "Work" Ansi.reset in
    box_line buf cols col_hdr;
    box_divider buf cols;

    (* Content area *)
    let content_height = rows - 8 in
    let scroll = min state.log_scroll (max 0 (total_entries - content_height)) in

    if total_entries = 0 then begin
      box_line buf cols (Ansi.dim ^ "  (no log entries found)" ^ Ansi.reset);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx < total_entries then begin
          let e = List.nth state.log_entries idx in
          (* Extract just the time portion from ts *)
          let time_str =
            if String.length e.le_ts >= 19 then
              String.sub e.le_ts 11 8  (* HH:MM:SS *)
            else e.le_ts
          in
          let pct = e.le_context_ratio *. 100.0 in
          let ctx_str = Printf.sprintf "%s%5.1f%%%s"
            (ctx_color e.le_context_ratio) pct Ansi.reset in
          let tokens_str = Printf.sprintf "%6d/%6d"
            e.le_context_tokens e.le_context_max in
          let io_str =
            match e.le_input_tokens, e.le_output_tokens with
            | Some input, Some output -> Printf.sprintf "%4d/%4d" input output
            | _ -> Ansi.dim ^ "   --/--" ^ Ansi.reset
          in
          let lat_str =
            match e.le_latency_ms with
            | Some latency when latency > 0 -> Printf.sprintf "%5dms" latency
            | _ -> Ansi.dim ^ "     --" ^ Ansi.reset
          in
          let cost_str =
            match e.le_cost_usd with
            | Some cost when cost > 0.0 -> Printf.sprintf "$%.3f" cost
            | _ -> Ansi.dim ^ "   --" ^ Ansi.reset
          in
          let tools_str =
            if List.length e.le_tools_used > 0 then
              " " ^ Ansi.dim ^ (String.concat "," (List.filteri (fun i _ -> i < 2) e.le_tools_used)) ^ Ansi.reset
            else ""
          in
          let work_kind = Option.value ~default:"" e.le_work_kind in
          let line = Printf.sprintf "  %s %s %s %s %s %s %s  %-10s%s"
            time_str (channel_color e.le_channel) ctx_str tokens_str
            io_str lat_str cost_str work_kind tools_str
          in
          box_line buf cols line
        end else
          box_empty buf cols
      done
    end;

    (* Scroll indicator *)
    if total_entries > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d entries, scroll %d]%s"
        Ansi.dim total_entries (total_entries) scroll Ansi.reset in
      box_line buf cols indicator
    end;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Render message input/conversation view *)
let render_keeper_message (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.show_cursor;  (* Show cursor for text input *)

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in

    (* Header *)
    let header = Printf.sprintf " Message to: %s%s%s  (port %d)"
      Ansi.bold k.k_name Ansi.reset state.port in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* Message history *)
    let history_height = rows - 10 in  (* Reserve space for input area *)
    let msg_count = List.length state.msg_history in
    let start_idx = max 0 (msg_count - history_height) in

    if msg_count = 0 then begin
      box_line buf cols (Ansi.dim ^ "  (no messages yet -- type below and press Enter)" ^ Ansi.reset);
      for _ = 1 to history_height - 1 do
        box_empty buf cols
      done
    end else begin
      let displayed = ref 0 in
      List.iteri (fun i m ->
        if i >= start_idx && !displayed < history_height then begin
          let role_color = match m.me_role with
            | "user" -> Ansi.cyan
            | "assistant" -> Ansi.green
            | _ -> Ansi.white
          in
          let role_label = match m.me_role with
            | "user" -> "you"
            | "assistant" -> k.k_name
            | s -> s
          in
          let prefix = Printf.sprintf "  %s[%s] %s:%s "
            role_color m.me_timestamp role_label Ansi.reset in
          (* Word-wrap the message text across multiple lines *)
          let text_width = max 20 (cols - 30) in
          let text = m.me_text in
          let text_len = String.length text in
          if text_len <= text_width then begin
            box_line buf cols (prefix ^ text);
            incr displayed
          end else begin
            (* First line with prefix *)
            box_line buf cols (prefix ^ String.sub text 0 text_width);
            incr displayed;
            (* Continuation lines *)
            let indent = String.make (String.length "  [HH:MM:SS] xxxxxxx: ") ' ' in
            let pos = ref text_width in
            while !pos < text_len && !displayed < history_height do
              let chunk_len = min text_width (text_len - !pos) in
              box_line buf cols (indent ^ String.sub text !pos chunk_len);
              pos := !pos + chunk_len;
              incr displayed
            done
          end
        end
      ) state.msg_history;
      (* Fill remaining space *)
      for _ = !displayed to history_height - 1 do
        box_empty buf cols
      done
    end;

    (* Input area divider *)
    box_divider buf cols;

    (* Input line *)
    let input_text = Buffer.contents state.msg_input in
    let prompt =
      if state.msg_sending then
        Printf.sprintf "  %s(sending...)%s" Ansi.yellow Ansi.reset
      else
        Printf.sprintf "  %s>%s %s" Ansi.cyan Ansi.reset input_text
    in
    box_line buf cols prompt;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  Enter:send  Esc:back  Ctrl-U:clear line%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Dispatch render based on current surface *)
let render (state : state) =
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
