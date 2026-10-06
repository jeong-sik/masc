open Masc.Tui_decode_connectors
(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc.Tui_decode_fusion
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press
open Masc_tui_render_chat

module Frame_presenter = Masc_tui_frame_presenter
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Browser_lane_layout = Masc_tui_browser_lane_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
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
module Overview_providers = Masc_tui_overview_providers
module Layout = Masc_tui_layout
module Agenda = Masc_tui_agenda
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Item_account = Masc_tui_keeper_items
module Task_selection = Masc_tui_task_selection
module Overview_tasks = Masc_tui_overview_tasks
module Tool_tree = Masc_tui_tool_tree
module Theme_choice = Masc_tui_theme_choice
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Keeper_snapshot_unread = Masc.Keeper_snapshot_unread
module Render_tools = Masc_tui_render_tools
module Span = Masc_tui_span
module Diff = Masc_tui_diff
module Chart = Masc_tui_chart
module Render_memory = Masc_tui_render_memory
module Metrics_page = Masc_tui_render_metrics

type memory_state = Render_memory.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error


let json_assoc_member_opt = Masc_tui_json.member_opt

let acting_pane_target_at ~line =
  let targets = !acting_pane_row_targets in
  if line >= 0 && line < Array.length targets then targets.(line)
  else Masc_tui_acting_pane.Target_none

let acting_pane_drawn_cols () = !acting_pane_reserved_cols
let acting_pane_row_count () = Array.length !acting_pane_row_targets
let acting_pane_scroll_limit () = !acting_pane_scroll_max
let set_table_frame enabled = table_frame_enabled := enabled

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

let acting_pane_suppressed (state : state) =
  let modal =
    Option.is_some state.account_login || Option.is_some state.lane_addons || state.palette_open
    || Masc_tui_types.modal_owns_keys state
    || state.answering_open || state.memory_fact_detail_open
  in
  modal
  || Masc_tui_types.on_activity_screen state.view
  || Option.is_some (browser_lane_on_screen state)

let acting_pane_columns (state : state) ~terminal_cols =
  if acting_pane_suppressed state then 0
  else Masc_tui_acting_pane.drawn_cols ~layout:(acting_pane_layout state) ~cols:terminal_cols

(* The runtime picker measures this string to decide its column widths, so the
   format lives beside that arithmetic. *)
let format_context_tokens = Masc_tui_types.format_context_tokens

let keepers_for_lane (state : state) (lane_id : string) : Tui_decode.keeper list =
  let default_target =
    match state.runtime_surface with
    | Some s -> s.rss_resolved.rrs_default_runtime_id
    | None -> None
  in
  state.keepers
  |> List.filter (fun (k : Tui_decode.keeper) ->
       match
         List.find_opt
           (fun (a : Tui_decode.runtime_assignment) ->
              String.equal a.ra_keeper k.k_name)
           state.runtime_assignments
       with
       | Some a -> runtime_assignment_targets a lane_id
       | None ->
           match default_target with
           | Some def -> String.equal def lane_id
           | None -> false)

let keepers_for_runtime (state : state) (runtime_id : string) : Tui_decode.keeper list =
  let default_target =
    match state.runtime_surface with
    | Some s -> s.rss_resolved.rrs_default_runtime_id
    | None -> None
  in
  state.keepers
  |> List.filter (fun (k : Tui_decode.keeper) ->
       match
         List.find_opt
           (fun (a : Tui_decode.runtime_assignment) ->
              String.equal a.ra_keeper k.k_name)
           state.runtime_assignments
       with
       | Some a -> runtime_assignment_targets a runtime_id
       | None ->
           match default_target with
           | Some def -> String.equal def runtime_id
           | None -> false)

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

module Task_id_set = Set.Make (String)

let task_line ~cols ~ordinal ~task_ids ~use_ordinals (task : task) =
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
  let prefix id =
    Printf.sprintf "%s%s%s %s[%s]%s " status_color
      (task_status_icon task.status) Ansi.reset Ansi.dim id Ansi.reset
  in
  let suffix status owner =
    Printf.sprintf " %s(%s%s)%s %s" status_color status owner Ansi.reset
      (priority_indicator task.priority)
  in
  (* Preserve the Task number before spending cells on its owner and title.
     The canonical prefix may yield on narrow screens, but its digits do not
     share a truncation budget with unrelated fields. *)
  let available = max 0 (framed_inner_width cols - 1) in
  let id = Terminal_text.single_line task.id in
  let short_id =
    if String.starts_with ~prefix:"task-" id then
      let digits = String.sub id 5 (String.length id - 5) in
      if digits <> "" && String.for_all (fun c -> c >= '0' && c <= '9') digits then digits else id
    else id in
  let status =
    let required = Message_layout.display_width (prefix "")
      + Message_layout.display_width (suffix status "")
      + Message_layout.display_width id + Message_layout.display_width "Task" in
    if required <= available then status
    else match task.status with
      | Masc_domain.Todo -> "todo"
      | Masc_domain.Claimed _ -> "claimed"
      | Masc_domain.InProgress _ -> "active"
      | Masc_domain.AwaitingVerification _ -> "verify"
      | Masc_domain.Done _ -> "done"
      | Masc_domain.Cancelled _ -> "cancelled"
  in
  let fixed_chrome = Message_layout.display_width (prefix "")
    + Message_layout.display_width (suffix status "") in
  let fields = max 0 (available - fixed_chrome) in
  let id = if Message_layout.display_width id + Message_layout.display_width "Task" <= fields
    then id else short_id in
  (* A row coordinate stays distinct when an opaque ID cannot fit. The
     original identifier remains the selection key and is readable in detail. *)
  let id =
    if use_ordinals || Message_layout.display_width id > fields
       || (not (String.equal id task.id)
           && Task_id_set.mem id task_ids)
    then Printf.sprintf "row %d" ordinal else id
  in
  let remainder = max 0 (fields - Message_layout.display_width id) in
  let title = Terminal_text.single_line task.title in
  (* A short title needs only its measured cells. Its spare allocation can
     show the owner instead of padding beside a shortened identity. *)
  let title_cells = min (remainder / 2) (Message_layout.display_width title) in
  let assignee =
    fit_width assignee
      (min (remainder - title_cells) (Message_layout.display_width assignee))
  in
  let prefix = prefix id in
  let suffix = suffix status assignee in
  let fixed = Message_layout.display_width prefix + Message_layout.display_width suffix in
  let goal_tag =
    if fixed + Message_layout.display_width title
       + Message_layout.display_width goal_tag <= available
    then goal_tag else ""
  in
  prefix ^ fit_width title
    (max 0 (available - fixed - Message_layout.display_width goal_tag))
  ^ suffix ^ goal_tag

(* Dashboard rows summarize sources without changing their meaning. The full
   task list lives in Work, Keeper rows in Keepers, and account windows in
   Usage. A missing reading is never projected as a zero. *)
(* The Dashboard keeps its working layout through loading and failure. *)
let overview_header (state : state) =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%s  %s[%s]%s  %02d:%02d:%02d  %s"
    (screen_title " MASC Dashboard")
    (Masc_tui_theme.tone Masc_tui_theme.Accent)
    (Terminal_text.single_line state.workspace) Ansi.reset
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec
    (connection_badge state)

let render_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let all_decisions = Masc_tui_home.home_decision_rows state in
  let continuation = Masc_tui_home.home_continue_rows state in
  let selected = Masc_tui_home.home_selected_action state in
  let health =
    match Terminal_text.optional_single_line state.overview_error, state.overview with
    | Some error, _ -> " Health: unavailable · " ^ error
    | None, None ->
        let status =
          match state.connection_status, state.http_refresh_started_ns with
          | Connecting, _ -> "Connecting to workspace…"
          | Booting, _ -> "Workspace server is starting…"
          | (Connected | Degraded | Reconnecting | Disconnected), Some _ ->
              "Loading Dashboard…"
          | (Connected | Degraded | Reconnecting | Disconnected), None ->
              "Health: not observed — press 'r' to refresh"
        in
        " " ^ status
    | None, Some overview ->
        " Health: " ^ workspace_health_label overview.ov_workspace_health
        ^ (match overview.ov_keeper_listing with
           | Keeper_snapshot_unread.Unreadable detail ->
               " · Keepers unlisted: " ^ Terminal_text.single_line detail
           | Not_listed -> " · Keepers not observed"
           | Listed ->
               match overview.ov_keeper_liveness.klc_unreadable with
               | 0 -> ""
               | count -> Printf.sprintf " · %d Keeper states unreadable" count)
  in
  let health =
    match Masc_tui_candle.compact_status state.candle_observation with
    | None -> health
    | Some status -> health ^ " · " ^ status
  in
  let work =
    match state.task_flow, state.tasks_error with
    | _, Some _ -> " Work: reading unavailable · open Work for the source"
    | None, None -> " Work: not observed"
    | Some flow, None ->
        if flow.Masc_tui_task_flow.unparseable_timestamps > 0 then
          " Work: partial timestamp coverage · details in Work"
        else
          Printf.sprintf " Work: %d currently done in the last 24h · details in Work"
            flow.Masc_tui_task_flow.recent.completed
  in
  surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"overview"
    ~title:(overview_header state)
    ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
    ~hints:(Masc_tui_keys.footer_hints Overview)
    ~body:(fun ~budget c ->
      c.push
        (" " ^ pressable (Press_surface Approvals)
           (Ansi.bold ^ Theme.info () ^ "p:Approvals / Questions" ^ Ansi.reset));
      let budget = max 0 (budget - 1) in
      let draw_row (action, label) =
        let line = "  " ^ label in
        if Some action = selected then c.push_selected line else c.push line
      in
      let selection_changed =
        Option.is_some state.home_selected && Option.is_none selected
      in
      let warning_rows = if selection_changed then 1 else 0 in
      (* Keep continuation and new work visible while the request window
         follows the selected identity. All rows remain reachable with j/k. *)
      let first, capacity = Masc_tui_home.home_decision_window state ~budget in
      let decisions = List.drop first all_decisions |> List.take capacity in
      let actions = decisions @ continuation in
      (* Headers and action destinations take precedence over health/history
         context. The request window preserves continuation below it even
         when the queue contains more rows than the viewport. *)
      let essential_rows = List.length actions + 2 + warning_rows in
      if budget >= essential_rows && (all_decisions = [] || capacity > 0) then begin
        let spare = budget - essential_rows in
        let context =
          let candle = Masc_tui_candle.summary_lines state.candle_observation
            |> List.concat_map (fun line ->
              Message_layout.wrap_words ~max_cells:(max 1 (cols - 4))
                (Terminal_text.single_line line))
            |> List.map (fun line -> None, " " ^ line) in
          let notice_rows =
            (if Option.is_some state.opening_notice then 1 else 0)
            + (if Option.is_some state.home_decision_receipt then 1 else 0) in
          let candle_fits = spare >= 2 + notice_rows + List.length candle in
          let health = if candle_fits then health else
            match Masc_tui_candle.compact_status state.candle_observation with
            | None -> health
            | Some status -> " " ^ status ^ " · " ^ health in
          let readings =
            (match state.home_decision_receipt with
             | None -> []
             | Some (_, receipt) ->
                 [None, " Last decision receipt · " ^ Terminal_text.single_line receipt])
            @ [ (None, health); (Some (Theme.recede ()), work) ]
            @ (if candle_fits then candle else [])
          in
          match state.opening_notice with
          | None -> readings
          | Some notice ->
              let notice = (None, " " ^ Terminal_text.single_line notice) in
              if spare < List.length readings + 1 then notice :: readings
              else readings @ [notice]
        in
        let shown_context = List.take (min spare (List.length context)) context in
        List.iter
          (function
            | None, text -> c.push text
            | Some style, text -> c.push_styled ~style text)
          shown_context;
        let gaps = spare - List.length shown_context in
        if gaps > 0 then c.push_empty ();
        (match decisions with
         | [] -> c.push_styled ~style:(Theme.recede ())
             (if all_decisions = [] then " No decision is waiting on you."
              else " Decision rows above · j/k to choose")
         | _ :: _ ->
             c.push_styled ~style:Ansi.bold
               (if List.length decisions = List.length all_decisions then " Needs your decision"
                else Printf.sprintf " Needs your decision · rows %d-%d/%d · j/k for more"
                  (first + 1) (first + List.length decisions) (List.length all_decisions));
             List.iter draw_row decisions);
        if gaps > 1 then c.push_empty ();
        c.push_styled ~style:Ansi.bold " Continue";
        List.iter draw_row continuation
      end else begin
        (* Extremely short terminals show destinations around the selected
           identity. j/k reaches every destination; this is a viewport limit,
           never a limit on requests or execution. *)
        let actions = all_decisions @ continuation in
        let available = max 0 (budget - warning_rows) in
        let count = List.length actions in
        let index =
          match List.find_index (fun (action, _) -> Some action = selected) actions with
          | Some index -> index
          | None -> 0
        in
        let show_position = available > 1 in
        let height = max 0 (available - if show_position then 1 else 0) in
        let first = max 0 (min index (count - height)) in
        let window = List.drop first actions |> List.take height in
        if show_position then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf " Home destinations · %d-%d/%d · j/k to choose"
               (first + 1) (first + List.length window) count);
        List.iter draw_row window
      end;
      if selection_changed then
        c.push_styled ~style:(Theme.warn ()) " Selection changed · j/k to choose again")

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

let task_detail_lines (state : state) ~cols (task : Masc_domain.task) =
  let width = max 1 (framed_inner_width cols - 2) in
  let labeled_lines label text =
    let prefix = "  " ^ label ^ ": " in
    let prefix_width = Message_layout.display_width prefix in
    if prefix_width < framed_inner_width cols then
      Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols - prefix_width) text
      |> List.mapi (fun index line ->
           (if index = 0 then prefix else String.make prefix_width ' ') ^ line)
    else
      (Message_layout.wrap_words ~max_cells:width label
       |> List.map (fun line -> "  " ^ line))
      @ (Masc_tui_text_block.rows ~max_cells:width text
         |> List.map (fun line -> "  " ^ line))
  in
  let some_lines label = function None -> [] | Some text -> labeled_lines label text in
  let list_lines label items = List.concat_map (labeled_lines label) items in
  let goal_lines =
    match task_goal_reading state ~task_id:task.id with
    | Masc_tui_agenda.Not_read ->
        labeled_lines "goal" "(membership unknown: links not read)"
    | Masc_tui_agenda.Read_failed reason ->
        labeled_lines "goal" ("(membership unknown: " ^ reason ^ ")")
    | Masc_tui_agenda.Read [] -> labeled_lines "goal" "(not linked to a goal)"
    | Masc_tui_agenda.Read goal_ids -> List.concat_map (fun goal_id ->
        labeled_lines "goal" goal_id @ labeled_lines "link" (Link.reference Goal goal_id)) goal_ids
  in
  (* Status, actor and every transition's evidence are real rows in the same
     reading as the description. No metadata field is a one-line preview. *)
  let status_lines =
    match task.task_status with
    | Masc_domain.Todo -> labeled_lines "status" "todo — unclaimed"
    | Masc_domain.Claimed { assignee; claimed_at } ->
        labeled_lines "status" "claimed" @ labeled_lines "actor" assignee
        @ labeled_lines "claimed" claimed_at
    | Masc_domain.InProgress { assignee; started_at } ->
        labeled_lines "status" "in progress" @ labeled_lines "actor" assignee
        @ labeled_lines "started" started_at
    | Masc_domain.AwaitingVerification { assignee; started_at; submitted_at; verification_id } ->
        labeled_lines "status" "awaiting verification" @ labeled_lines "actor" assignee
        @ labeled_lines "started" started_at @ labeled_lines "submitted" submitted_at
        @ labeled_lines "verification" verification_id
    | Masc_domain.Done { assignee; completed_at; notes } ->
        labeled_lines "status" "done" @ labeled_lines "actor" assignee
        @ labeled_lines "completed" completed_at @ some_lines "notes" notes
    | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
        labeled_lines "status" "cancelled" @ labeled_lines "actor" cancelled_by
        @ labeled_lines "cancelled" cancelled_at @ some_lines "reason" reason
  in
  labeled_lines "title" task.title @ labeled_lines "id" task.id @ goal_lines
  @ status_lines
  @ labeled_lines "created" task.created_at
  @ labeled_lines "creator" (match task.created_by with Some by -> by | None -> Masc_tui_theme.Glyph.no_value)
  @ labeled_lines "priority" (string_of_int task.priority)
  @ labeled_lines "cycles" (string_of_int task.cycle_count)
  @ some_lines "predecessor" task.predecessor_task_id
  @ some_lines "operation" task.execution_links.operation_id
  @ some_lines "session" task.execution_links.session_id
  @ some_lines "reclaim policy"
      (Option.map Masc_domain.task_reclaim_policy_to_string task.reclaim_policy)
  @ some_lines "do not reclaim" task.do_not_reclaim_reason
  @ List.concat_map (fun skill ->
      labeled_lines "skill" (Yojson.Safe.to_string (Skill_reference.to_yojson skill))) task.skills
  @ (if String.equal task.description "" then [] else labeled_lines "what" task.description)
  @ (match task.handoff_context with
     | None -> []
     | Some handoff ->
         some_lines "why" handoff.Masc_domain.reason
         @ (if String.equal handoff.Masc_domain.summary "" then [] else labeled_lines "handoff" handoff.Masc_domain.summary)
         @ some_lines "next" handoff.Masc_domain.next_step
         @ some_lines "failure" handoff.Masc_domain.failure_mode
         @ some_lines "handoff reclaim policy"
             (Option.map Masc_domain.task_reclaim_policy_to_string
                handoff.Masc_domain.reclaim_policy)
         @ some_lines "handoff updated" handoff.Masc_domain.updated_at
         @ some_lines "handoff updater" handoff.Masc_domain.updated_by
         @ list_lines "evidence" handoff.Masc_domain.evidence_refs)
  @ (match task.contract with
     | None -> []
     | Some contract ->
         (if contract.Masc_domain.strict then ["  contract strict"] else [])
         @ list_lines "done-when" contract.Masc_domain.completion_contract
         @ list_lines "evidence" contract.Masc_domain.required_evidence
         @ list_lines "inspection evidence" contract.Masc_domain.inspect_gate_evidence
         @ list_lines "verification evidence" contract.Masc_domain.verify_gate_evidence)
  @ list_lines "file" task.files
  @ (task_history_lines state task.id
     |> List.concat_map (fun line ->
          if String.equal line "" then [""]
          else Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols) line))

let task_detail_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:framed_chrome_rows ~count
    ~preview_keep:None ~overflow_takes_row:true

let task_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let pane_cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  let count = match Task_selection.detail_row ~detail_id:state.task_detail_id ~tasks:state.tasks_domain with
    | None -> 0
    | Some task -> List.length (task_detail_lines state ~cols:pane_cols task)
  in
  count, task_detail_height ~rows ~count

let task_detail_pane (state : state) ~rows ~cols (task : Masc_domain.task) buf =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s%s%s  %s  %s"
    (screen_title " MASC Task") (Masc_tui_theme.tone Masc_tui_theme.Accent)
    (bracketed ~max_cells:20 (Terminal_text.single_line task.id)) Ansi.reset timestamp (connection_badge state) in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let lines = task_detail_lines state ~cols task in
  let count = List.length lines in
  let height = task_detail_height ~rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.task_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line_styled buf cols ~style:Ansi.dim line
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
  scroll
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
      (* The highlight names the task this detail shows, not the cursor: a
         done or cancelled task opened from the palette or a link has no row
         here, and the row the cursor last rested on would be a different
         task. *)
      (* The id follows each title because the shared sidebar fold keeps the
         tail, so titles with the same opening and ending still differ. *)
      write_list_sidebar_selection left_buf ~rows ~cols:left_cols
        ~title:"Tasks" ~focused:false
        (* [Overview_tasks.work_rows] drops what is done or cancelled.
           A filter is not a page: what it left out is a different kind of
           row, not more of these, so there is no second number to draw. *)
        ~holding:None
        ~labels:
          (List.map
             (fun (row : Tui_decode.task) ->
               Render_schedule.sidebar_row_label ~about:row.title
                 ~apart:(Some row.id))
             (Overview_tasks.work_rows state.tasks))
        ~selection:(Overview_tasks.work_selected_index state.tasks
                      ~selected:(Some task.id));
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
       ~hints:"j/k:scroll  PgUp/PgDn:page  Home/End  x:cancel  Left / Esc:back  r:refresh");

  finish_surface state ~clamped:(Task_detail offset) ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

let render_work_tasks (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Overview_tasks.work_rows state.tasks in
  let task_ids =
    Task_id_set.of_list
      (List.map (fun (task : Tui_decode.task) -> Terminal_text.single_line task.id) rows)
  in
  let ordinal_labels =
    Task_id_set.of_list (List.mapi (fun index _ -> Printf.sprintf "row %d" (index + 1)) rows)
  in
  (* A canonical ID may itself occupy the row-coordinate namespace. In
     that population every row uses its unique coordinate, so no fallback
     can impersonate a different Task. Detail and selection retain IDs. *)
  let use_ordinals = not (Task_id_set.disjoint task_ids ordinal_labels) in
  let selected =
    Overview_tasks.work_selected_index state.tasks
      ~selected:(Overview_tasks.selection state.task_focus)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"work-tasks"
    ~title:(screen_title " MASC Work / Tasks")
    ~hints:Masc_tui_keys.footer_hints_work_tasks
    ~body:(fun ~budget c ->
      (match state.local_workspace, state.task_flow with
       | Local_workspace_unread, _ ->
           c.push " Active tasks · not observed"
       | Local_workspace_read, None ->
           c.push " Active tasks · unavailable"
       | Local_workspace_read, Some _ ->
           c.push (Printf.sprintf
             " Open tasks · %d in progress, awaiting verification, claimed, or todo"
             (List.length rows)));
      (match state.task_flow with
       | None -> c.push " Task history · not observed"
       | Some flow ->
           let completed =
             List.map (fun (day : Masc_tui_task_flow.day) ->
               day.d_completed) flow.daily in
           c.push (Printf.sprintf " Currently done by UTC day (%d days): %s"
                     (List.length flow.daily) (Chart.sparkline ~min:0 completed)));
      let link_error = match state.goal_task_links with
        | Goal_links_read_failed reason -> Some reason
        | Goal_links_not_read | Goal_links_read _ -> None in
      let reasons =
        [ Terminal_text.optional_single_line state.tasks_error
        ; Terminal_text.optional_single_line link_error
        ]
        |> List.filter_map Fun.id in
      (match reasons with
       | [] -> ()
       | reasons -> c.push (" Coverage: " ^ String.concat " · " reasons));
      c.push "";
      let room = max 0 (budget - 4) in
      if rows = [] && Option.is_some state.task_flow then
        c.push " No open tasks";
      let first =
        match selected with
        | None -> 0
        | Some index -> max 0 (index - room + 1)
      in
      (* [task_line] is the one row a task draws: its status icon and word in
         one colour, id, title, assignee, priority and Goal, each through the
         terminal sanitiser. *)
      List.iteri
        (fun index (task : Tui_decode.task) ->
           if index >= first && index < first + room then
             let line = " " ^ task_line ~cols ~ordinal:(index + 1) ~task_ids ~use_ordinals task in
             if Some index = selected then
               c.push_selected (Masc_tui_theme.strip_sgr line)
             else c.push line)
        rows)

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
  | (Goal_phase.Paused _ | Goal_phase.Blocked _) as suspended ->
    planning_phase_color suspended ^ "[" ^ planning_phase_label suspended ^ "]" ^ Ansi.reset
    ^ (match Goal_phase.resume_phase suspended with
       | None -> "" | Some target -> "  resumes " ^ planning_phase_label target)
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

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> (Theme.ok ())
  | Planning_detail.Refused -> (Theme.bad ())
  | Planning_detail.Waiting | Planning_detail.Unreadable -> (Theme.warn ())
  | Planning_detail.Note | Planning_detail.Quiet -> Ansi.dim

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
    let tone, text = Planning_detail.verifying_next_step goal.pg_verifier_unreconciled in
    (planning_detail_tone tone, text)
  | Goal_phase.Awaiting_confirmation, _ ->
    (Theme.warn (), "proof passed - [a] reads the proof for your final confirmation")
  | Goal_phase.Completed, _ -> (Ansi.dim, "reached its target - [o] reopens it")
  | Goal_phase.Dropped, _ -> (Ansi.dim, "abandoned - [o] reopens it")
  | Goal_phase.Paused _, _ -> (Theme.warn (), "paused - [r] restores the prior state; linked Tasks continue independently")
  | Goal_phase.Blocked _, _ -> (Theme.bad (), "blocked - [u] restores the prior state; linked Tasks continue independently")
;;

(* The line under the list, for the goal the cursor is on. A verdict without its
   reason is a colour and nothing else; the reason is what the judge produced
   and the only thing that says what to do next. *)
let planning_proof_detail (goal : planning_goal) =
  match goal.pg_verifier_unreconciled with
  | Some blocked ->
    (* The judge's last word is not what holds this goal: the latest verifier
       scan could not settle it, and only this line says why. *)
    Some
      ( Theme.bad ()
      , Printf.sprintf "%s: %s"
          (Planning_detail.unreconciled_heading blocked.vu_step)
          (Terminal_text.single_line blocked.vu_detail) )
  | None ->
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some ((Theme.ok ()), "proven")
  | Tui_decode.Proof_proven (Some evidence) ->
      Some ((Theme.ok ()), "proven: " ^ Terminal_text.single_line evidence)
  | Tui_decode.Proof_refuted None -> Some ((Theme.bad ()), "refused")
  | Tui_decode.Proof_refuted (Some reason) ->
      Some ((Theme.bad ()), "refused: " ^ Terminal_text.single_line reason)
  | Tui_decode.Proof_pending -> Some ((Theme.warn ()), "waiting for the completion judge")
  | Tui_decode.Proof_stale _ ->
      Some ((Theme.warn ()), "criterion changed; previous proof is historical")
  | Tui_decode.Proof_unreadable None ->
      Some ((Theme.warn ()), "verification ledger unreadable")
  | Tui_decode.Proof_unreadable (Some detail) ->
      Some ((Theme.warn ()), "verification ledger unreadable: " ^ Terminal_text.single_line detail)
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

(* Panels use terminal cell widths, including styled and wide-script text.
   Callers choose their height from the available rows and retain selection. *)
let studio_panel ~width ~title ~lines =
  let inner = max 1 (width - 4) in
  let border left right =
    Theme.recede () ^ left ^ draw_hline (max 0 (width - 2)) ^ right ^ Ansi.reset
  in
  [ Theme.info () ^ "┌ " ^ fit_width title (max 1 (width - 4)) ^ " ┐" ^ Ansi.reset ]
  @ List.map (fun line ->
      Theme.recede () ^ "│ " ^ Ansi.reset ^ fit_width line inner
      ^ Theme.recede () ^ " │" ^ Ansi.reset) lines
  @ [ border "└" "┘" ]

let studio_pair ~width left right =
  let gutter = 2 in
  let left_width = (width - gutter) / 2 in
  let right_width = width - gutter - left_width in
  let left = left left_width and right = right right_width in
  let count = max (List.length left) (List.length right) in
  List.init count (fun index ->
    fit_width (Option.value (List.nth_opt left index) ~default:"") left_width
    ^ String.make gutter ' '
    ^ fit_width (Option.value (List.nth_opt right index) ~default:"") right_width)

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
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view));
  let tail_rows = count_frame_lines tail in

  let now_unix = Unix.gettimeofday () in
  let now = Unix.localtime now_unix in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let modes = Printf.sprintf "sort:%s  filter:%s"
    (planning_sort_label state.planning_sort)
    (planning_filter_label state.planning_filter) in
  (* The clock and the badge always ride this row; the modes ride it when the
     row can hold them, and take one of their own when it cannot. *)
  let chrome = Printf.sprintf "  %s  %s" timestamp (connection_badge state) in
  (* The whole tail, measured as the row draws it. [planning_workspace_title]
     sizes its strip against what follows, so modes inserted after that
     measurement spend the cells the badge was holding: at a hundred columns
     the row ran to 112 of the 96 it had, and the reading lost "HTTP
     [connected]" and the seconds off its clock -- the two facts that say
     whether what is on the screen is live. Asking the question of
     [title ^ "  " ^ modes] alone could only ever answer it for a row with no
     chrome on it, which this row has never been. *)
  let riding = "  " ^ modes ^ chrome in
  let title_alone =
    planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
      ~after:chrome
  in
  let title_with_modes =
    planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
      ~after:riding
  in
  (* The modes ride when they cost nothing: the strip drawn beside them is the
     same strip, and the row still fits. Measuring only the width let the strip
     pay instead -- it cuts rather than overflowing, so any row "fits" once the
     tabs are allowed to disappear, and at a hundred columns Planning answered
     yes by hiding "Task Review" and "Task Verdicts". The modes have a row of
     their own; the two other tabs and the badge have nowhere else to go. *)
  let modes_fit_header =
    String.equal title_alone title_with_modes
    && Message_layout.display_width (title_with_modes ^ riding)
       <= framed_inner_width cols
  in
  let header =
    if modes_fit_header then title_with_modes ^ riding else title_alone ^ chrome
  in

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
       let ended =
         List.length
           (List.filter
              (fun (row : planning_goal_history) -> Option.is_some row.pgh_closed_at)
              history)
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         (planning_goal_history_summary ~unlisted:(List.length history) ~ended);
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
       let rollup = planning_rollup_row ~cols p.pl_rollup in
       (* The backlog counts are a list. [▸] joined them -- the mark the tab
          strip puts on the surface you are on -- so "todo ▸ claimed" read as a
          path. *)
       let backlog_sep = Printf.sprintf " %s·%s " (Theme.recede ()) Ansi.reset in
       let backlog =
         let items = planning_backlog_counts p.pl_backlog in
         let counts = List.map (fun (k, v, _) -> k, v) items in
         let bands = Magnitude.of_counts counts in
         List.map2
           (fun (_, _, label) (_, value, band) ->
              Printf.sprintf "%s%s=%d%s" (magnitude_tone band) label value
                Ansi.reset)
           items bands
         |> String.concat backlog_sep
       in
       (* Budget summary chrome against the actual header and divider rows.
          Retained history and wrapped modes already occupy [buf]; preserve
          a goal (or empty note), its selected detail and the footer before
          adding optional trend/backlog rows. *)
       let phase_width = planning_phase_column + 2 in
       let goal_layout =
         Render_schedule.planning_layout
           ~inner_width:(max 1 (framed_inner_width cols - 2))
           ~phase_width
       in
       let list_header = Buffer.create 256 in
       box_line_styled list_header cols ~style:(Theme.recede ())
         ("  "
         ^ Render_schedule.planning_header_row ~phase_width ~layout:goal_layout);
       let divider = Buffer.create 128 in
       box_divider divider cols;
       let selection_rows = if count = 0 then 0 else 1 in
       let reserved_rows =
         count_frame_lines list_header + (2 * count_frame_lines divider)
         + 1 + selection_rows + tail_rows
       in
       let add_summary_if_fits summary =
         if count_frame_lines buf + count_frame_lines summary + reserved_rows <= rows
         then Buffer.add_buffer buf summary
       in
       let summary_width = framed_inner_width cols in
       let summary_cards =
         studio_pair ~width:summary_width
           (fun width -> studio_panel ~width ~title:"Goals · measured outcomes"
              ~lines:(Message_layout.wrap_words ~max_cells:(max 1 (width - 4))
                (planning_rollup_row ~cols:width p.pl_rollup)))
           (fun width -> studio_panel ~width ~title:"Tasks · Backlog:"
              ~lines:(Message_layout.wrap_words ~max_cells:(max 1 (width - 4)) backlog))
       in
       let summary_card_rows = List.length summary_cards in
       let cards_fit =
         summary_width >= Message_layout.display_width "Goals · measured outcomes  Tasks · current backlog" * 2
         && count_frame_lines buf + summary_card_rows + reserved_rows <= rows
       in
       if cards_fit then List.iter (box_line buf cols) summary_cards
       else box_line buf cols rollup;
       let trend = Buffer.create 256 in
       box_line_styled trend cols ~style:(Theme.info ())
         (match state.planning_baseline with
          | None -> "  Trend: waiting for the first successful reading"
          | Some first ->
              (* How long the reading has been running, not the clock it
                 started at. The baseline is the first successful read of
                 this process and is never replaced, so on a screen left open
                 overnight "since 09:31:39" named a moment on a day the
                 reader had no way to identify.

                 The sentence names where the span starts, because the span
                 is not a window anyone chose: "over the last 1d21h" reads
                 like a day-and-a-half report, when what it measures is how
                 long this screen has been open. *)
              Printf.sprintf
                "  Net change since this TUI's first reading %s ago: Goals done %+d · Tasks done %+d · Goal reviews pending %+d"
                (Masc_tui_wire_age.text ~now:now_unix first.pl_generated_at)
                (p.pl_rollup.pr_done - first.pl_rollup.pr_done)
                (p.pl_backlog.pb_done - first.pl_backlog.pb_done)
                (p.pl_rollup.pr_verifying - first.pl_rollup.pr_verifying));
       add_summary_if_fits trend;
       let backlog_summary = Buffer.create 256 in
       box_line backlog_summary cols
         (Printf.sprintf "  %sBacklog:%s %s" Ansi.dim Ansi.reset backlog);
       if not cards_fit then add_summary_if_fits backlog_summary;
       Buffer.add_buffer buf divider;
       (* The list drew rows and never said what they were. *)
       Buffer.add_buffer buf list_header;
       (* What the JUDGE column's marks mean, once, under the header that
          names it. The glyphs are the only part of a row an operator cannot
          read straight off, and every one of them changes what to do next --
          which is why the legend says the marks this list draws and only those.
          Wrap complete explanations within the frame's cell width: a clipped
          legend would lose a verdict and add a truncation mark identical to
          the stale-proof glyph. A list narrow enough to give up the JUDGE
          column draws no marks, so it draws no legend either. *)
       (* Reserve the divider, a goal (or empty note), and the selected
          verdict before spending rows on the legend. At the minimum
          height the headers and summary stay in place and a goal remains
          visible; taller frames get the legend back. *)
       let rows_after_legend = 1 + 1 + selection_rows + tail_rows in
       let judge_legend =
         if
           List.mem Render_schedule.Planning_proof
             goal_layout.Masc_tui_table.shown
         then
           Masc_tui_planning_proof_mark.legend_rows
             ~max_cells:(framed_inner_width cols)
             ~max_rows:(rows - count_frame_lines buf - rows_after_legend)
             (List.map (fun (g : planning_goal) -> g.pg_proof) goals)
         else []
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
         (* Where the list stands, when it does not hold every goal. At
            sixty columns and twenty-four rows the active filter held eight
            and the frame drew seven, and nothing on the screen said an
            eighth existed -- the rollup above counts every goal in the
            store, not the ones this filter and this frame leave off. The
            reading costs one of the rows it describes, which is the rule
            [Masc_tui_scroll.content_height ~overflow_takes_row:true] already
            holds for the roster and the reading panes. The chrome is zero
            here because [content_height] above has already taken it. *)
         let list_rows =
           (* A short frame may leave no list row at all. When it leaves
              one, that row is the selected goal: the cursor row is what
              [j/k] and Enter act on, and the count needs a second row. *)
           if content_height <= 0 then 0
           else if content_height = 1 then 1
           else
             Masc_tui_scroll.content_height ~rows:content_height ~chrome:0
               ~count ~preview_keep:None ~overflow_takes_row:true
         in
         let overflowing = content_height > 1 && count > list_rows in
         let scroll_offset =
           if list_rows = 0 then 0
           else if state.planning_cursor >= list_rows then
             state.planning_cursor - list_rows + 1
           else 0
         in
         let goals_window = Rows.of_list ~first:scroll_offset ~height:list_rows goals in
         for i = 0 to list_rows - 1 do
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
                   ~priority_style ~open_style ~phase_width ~layout:goal_layout
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
         if overflowing then
           box_line_styled buf cols ~style:(Theme.recede ())
             (Printf.sprintf "  [goals %s]"
                (Masc_tui_scroll.window_text ~scroll:scroll_offset
                   ~height:list_rows count));
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

let planning_measurement_lines (state : state) (goal : planning_goal) =
  let line tone text = { Planning_detail.tone; text } in
  let unavailable reason =
    [ line Planning_detail.Unreadable
        ("Actual measurement unavailable: " ^ Terminal_text.single_line reason) ]
  in
  if Option.is_none goal.pg_criterion_revision then []
  else match state.overview_goals with
  | Goals_unread -> [ line Planning_detail.Waiting "Actual measurement not observed" ]
  | Goals_failed reason -> unavailable reason
  | Goals_read goals ->
      (match List.find_opt
               (fun (row : Tui_decode.overview_goal) ->
                 String.equal row.og_id goal.pg_id) goals with
       | None -> unavailable "Goal missing from the current measurement tree"
       | Some row ->
           if not (Option.equal String.equal goal.pg_criterion_revision
                        row.og_criterion_revision)
              || not (Option.equal String.equal goal.pg_metric row.og_metric)
              || not (Option.equal String.equal goal.pg_target_value
                        row.og_target_value)
           then unavailable "criterion revision or target differs between Work and the Goal tree"
           else
             let tasks =
               line Planning_detail.Quiet
                 (Printf.sprintf "Linked Tasks: %d/%d done (separate from the measurement)"
                    row.og_task_done_count row.og_task_count)
             in
             (match row.og_measurement with
              | Goal_measurement_unread ->
                  [ line Planning_detail.Waiting "Actual measurement not observed"; tasks ]
              | Goal_measurement_not_recorded ->
                  [ line Planning_detail.Quiet "Actual measurement not recorded"; tasks ]
              | Goal_measurement_unavailable reason -> unavailable reason @ [ tasks ]
              | Goal_measurement_reported { value; evidence; actor; recorded_at } ->
                  [ line Planning_detail.Proven
                      ("Actual: " ^ Terminal_text.single_line value ^ " (reported)")
                  ; line Planning_detail.Note
                      ("Evidence: " ^ Terminal_text.single_line evidence
                       ^ " · " ^ Terminal_text.single_line actor
                       ^ " · " ^ Terminal_text.single_line recorded_at)
                  ; tasks ]))

let planning_confirmation_view (state : state) ~goal_id =
  match state.goal_confirmation with
  | Planning_detail.Inspecting read ->
      `Inspect (Masc_tui_fetched.view_for ~equal:String.equal read ~key:goal_id)
  | Planning_detail.Submitting (submitted_goal, _) when String.equal submitted_goal goal_id -> `Submitting
  | Planning_detail.Submitting _ -> `Inspect Absent

let planning_detail_action_rows ~cols ~armed (goal : planning_goal) =
  let item action =
    let key = planning_action_key action and label = planning_action_label action in
    let text = Printf.sprintf "[%s] %s" key label in
    if Goal_phase.moves_goal ~phase:goal.pg_phase
         ~action:(Goal_phase.Public_action.to_action action)
    then text else Ansi.dim ^ text ^ Ansi.reset
  in
  let actions = List.map item Goal_phase.Public_action.all
    @ (if Goal_phase.moves_goal ~phase:goal.pg_phase ~action:Goal_phase.Confirm_completion
       then ["[a] Confirm proof"] else []) in
  (* These are commands, so every action stays visible while its evidence is
     read. Their physical rows are subtracted before the reader is allocated. *)
  Message_layout.wrap_styled_words ~max_cells:(max 1 (framed_inner_width cols - 2))
    ("Actions: " ^ String.concat "   " actions)
  |> List.map (fun line -> "  " ^ line)
  |> fun rows -> rows @ (match armed with
       | None -> []
       | Some action ->
           Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols - 2))
             (Printf.sprintf "ARMED: %s [%s] -- press again to submit; other keys cancel"
                (planning_action_label action) (planning_action_key action))
           |> List.map (fun line -> "  " ^ Theme.warn () ^ line ^ Ansi.reset))

let planning_proof_rows ~width lines =
  List.concat_map (fun (line : Planning_detail.line) ->
    match Masc_tui_text_block.rows ~max_cells:width line.text with
    | [] -> [{line with text=""}]
    | rows -> List.map (fun text -> {line with text="  " ^ text}) rows) lines

let planning_detail_lines (state : state) ~confirmation ~cols (goal : planning_goal) =
  let width = max 1 (framed_inner_width cols - 2) in
  let field ?(tone = Planning_detail.Note) label text =
    let prefix = "  " ^ label ^ ": " in
    let cells = Message_layout.display_width prefix in
    let project text = { Planning_detail.tone; text } in
    if cells < framed_inner_width cols then
      (match Masc_tui_text_block.rows ~max_cells:(framed_inner_width cols - cells) text with
       | [] -> [project prefix]
       | lines -> List.mapi (fun index line ->
           project ((if index = 0 then prefix else String.make cells ' ') ^ line)) lines)
    else
      (Message_layout.wrap_words ~max_cells:width label |> List.map (fun line -> project ("  " ^ line)))
      @ (Masc_tui_text_block.rows ~max_cells:width text |> List.map (fun line -> project ("  " ^ line)))
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let _, next_text = planning_next_step goal in
  let metadata =
    field "Title" goal.pg_title @ field "Goal" goal.pg_id
    @ field "Stage" (Masc_tui_theme.strip_sgr (planning_stage_rail goal.pg_phase ^ "  " ^ planning_proof_mark goal.pg_proof))
    @ field "Next" next_text
    @ field "Metric" (optional goal.pg_metric)
    @ field "Target" (optional goal.pg_target_value)
    @ field "Due" (optional goal.pg_due_date)
    @ field "Priority" (Printf.sprintf "P%d" goal.pg_priority)
    @ (List.concat_map (fun (label, value) -> match value with
         | None -> [] | Some value -> field ~tone:Planning_detail.Quiet label value)
         ["Created", goal.pg_created_at; "Updated", goal.pg_updated_at; "Reviewed", goal.pg_last_review_at])
    @ field ~tone:Planning_detail.Quiet "Link" (Link.reference Goal goal.pg_id)
    @ (match state.goal_action_error with None -> [] | Some error -> field ~tone:Planning_detail.Refused "Error" error)
  in
  let linked_tasks = List.filter (fun (row : Tui_decode.task) -> List.mem goal.pg_id row.goal_ids) state.tasks in
  let linked = match linked_tasks with
    | [] ->
        let note = match state.task_reading with
          | Masc_tui_overview_tasks.Rows_unavailable _ -> page_failed_note
          | Rows_unread -> page_unread_note
          | Rows_read _ ->
              (match state.goal_task_links with
               | Goal_links_not_read -> "(links not read)"
               | Goal_links_read_failed _ -> "(links unavailable)"
               | Goal_links_read _ -> "(none)") in
        field ~tone:Planning_detail.Quiet "Open tasks" note
    | tasks -> field "Open tasks" (string_of_int (List.length tasks))
        @ List.concat_map (fun (task : Tui_decode.task) ->
            field "Task" task.id @ field "Title" task.title
            @ field ~tone:Planning_detail.Quiet "Link" (Link.reference Task task.id)) tasks
  in
  let confirmation_rows =
    (match confirmation with
       | `Submitting -> [{Planning_detail.tone = Waiting; text = "Sending proof confirmation..."}]
       | `Inspect (Masc_tui_fetched.Ready value) -> Planning_detail.confirmation_lines ~width value
       | `Inspect Loading -> [{Planning_detail.tone = Waiting; text = "Reading the proof to confirm..."}]
       | `Inspect (Stale (_, reason) | Failed reason) -> [{Planning_detail.tone = Unreadable; text = reason}]
       | `Inspect Masc_tui_fetched.Absent ->
           (match goal.pg_verifier_unreconciled with Some blocked -> Planning_detail.unreconciled_lines ~width blocked | None -> [])
           @ Planning_detail.body ~width goal.pg_proof goal.pg_last_review_note)
  in
  let measurement = planning_measurement_lines state goal in
  let proof =
    (match confirmation with
     | `Inspect Masc_tui_fetched.Absent -> measurement @ confirmation_rows
     | `Submitting | `Inspect (Masc_tui_fetched.Ready _ | Loading | Stale _ | Failed _) ->
         confirmation_rows @ measurement)
    @ Planning_detail.timeline ~width ~goal_id:goal.pg_id state.goal_timeline in
  let wrapped_proof = planning_proof_rows ~width proof in
  (match confirmation with
   | `Inspect Masc_tui_fetched.Absent -> metadata @ linked @ wrapped_proof
   | `Submitting | `Inspect (Masc_tui_fetched.Ready _ | Loading | Stale _ | Failed _) ->
       wrapped_proof @ metadata @ linked)

let planning_detail_header_rows (state : state) ~cols (goal : planning_goal) =
  let phase = "  " ^ bracketed ~max_cells:planning_phase_column
      (planning_phase_label goal.pg_phase) in
  let identity = Terminal_text.single_line goal.pg_id in
  let tail = phase ^ " " ^ identity in
  let header = planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
    ~after:tail ^ tail in
  if Message_layout.display_width header <= framed_inner_width cols then [header]
  else
    (planning_workspace_title state ~cols ~tab:Planning_goals ~window:""
       ~after:phase ^ phase)
    :: (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2))
          ("Goal: " ^ identity)
        |> List.map (fun line -> "  " ^ line))

let planning_detail_height ~rows ~header_rows ~action_rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:(framed_chrome_rows + max 0 (header_rows - 1) + action_rows)
    ~count ~preview_keep:None ~overflow_takes_row:true

let planning_detail_fits ~rows ~header_rows ~action_rows ~count =
  let height = planning_detail_height ~rows ~header_rows ~action_rows ~count in
  framed_chrome_rows + max 0 (header_rows - 1) + action_rows + height
    + (if count > height then 1 else 0) <= rows

let planning_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  match state.planning_mode, state.planning with
  | Planning_detail goal_id, Some snapshot ->
      (match List.find_opt (fun (goal : planning_goal) -> String.equal goal.pg_id goal_id) snapshot.pl_goals with
       | None -> 0, max 1 (rows - framed_chrome_rows)
       | Some goal ->
           let action_rows = List.length (planning_detail_action_rows ~cols ~armed:(goal_action_armed_for state goal_id) goal) in
           let count = List.length (planning_detail_lines state ~cols goal
             ~confirmation:(planning_confirmation_view state ~goal_id)) in
           let header_rows = List.length (planning_detail_header_rows state ~cols goal) in
           if planning_detail_fits ~rows ~header_rows ~action_rows ~count
           then count, planning_detail_height ~rows ~header_rows ~action_rows ~count
           else 0, 1)
  | Planning_list, _ | Planning_detail _, None -> 0, max 1 (rows - framed_chrome_rows)

let planning_detail_pane (state : state) ~armed ~confirmation ~rows ~cols (goal : planning_goal) buf =
  let headers = planning_detail_header_rows state ~cols goal in
  box_top buf cols;
  List.iter (box_line buf cols) headers;
  box_divider buf cols;
  let actions = planning_detail_action_rows ~cols ~armed goal in
  List.iter (box_line buf cols) actions;
  let lines = planning_detail_lines state ~confirmation ~cols goal in
  let count = List.length lines in
  let height = planning_detail_height ~rows ~header_rows:(List.length headers)
    ~action_rows:(List.length actions) ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.planning_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line_styled buf cols ~style:(planning_detail_tone line.Planning_detail.tone) line.text
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
  let seen = match confirmation with
    | `Inspect (Masc_tui_fetched.Ready proof) ->
        let width = max 1 (framed_inner_width cols - 2) in
        let last = List.length (planning_proof_rows ~width
          (Planning_detail.confirmation_lines ~width proof)) - 1 in
        if last >= scroll && last < scroll + height then Some proof else None
    | `Submitting | `Inspect (Masc_tui_fetched.Absent | Loading | Stale _ | Failed _) -> None in
  scroll, seen
;;

(* The goal list stays beside its detail. Opening one used to replace the
   other, so reading a row cost the reader their place in the list. Below the
   split width there is no room for both and the detail keeps the screen,
   which is the rule the Board read pane already follows. *)
let render_planning_detail (state : state)
    ~(armed : Goal_phase.Public_action.t option) ~confirmation (goal : planning_goal) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let detail_cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  let action_rows = List.length (planning_detail_action_rows ~cols:detail_cols ~armed goal) in
  let count = List.length (planning_detail_lines state ~confirmation ~cols:detail_cols goal) in
  let header_rows = List.length (planning_detail_header_rows state ~cols:detail_cols goal) in
  if not (planning_detail_fits ~rows ~header_rows ~action_rows ~count) then begin
    let buf = Buffer.create 96 in
    Buffer.add_string buf (fit_width "Goal detail needs more room; resize to read and act" cols);
    Buffer.add_char buf '\n';
    finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols buf
  end else begin
  let buf = Buffer.create 4096 in
  let scroll, seen =
    if cols < keeper_split_threshold_cols then
      planning_detail_pane state ~armed ~confirmation ~rows ~cols goal buf
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
          | Goal_phase.Paused _ -> "[pause]"
          | Goal_phase.Blocked _ -> "[block]"
        in
        Printf.sprintf "%s P%d %s" phase_badge row.pg_priority
          (Terminal_text.single_line row.pg_title)
      in
      (* The goal filter narrows to a phase; the goals it leaves out are on
         the other side of a filter, not behind a page boundary. *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Work"
        ~holding:None
        ~focused:false
        ~labels:(List.map format_sidebar_goal goals)
        ~selected;
      let scroll, seen =
        planning_detail_pane state ~armed ~confirmation ~rows ~cols:(cols - left_cols) goal
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      scroll, seen
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~detail_open:true state.view));
  finish_surface state ~clamped:(Planning_confirmation_scroll (scroll, seen))
      ~surface_key:"planning-detail" ~rows:terminal_rows ~cols buf
  end

(* The store's status vocabulary, as colours. An unknown word keeps its own
   text and no colour: the row is still a fact about the store, just one this
   build does not rank. *)
(* Who the wake reaches. The server's keeper name takes precedence over the
   encoded target. An older server has only the target, which stays unchanged
   rather than being parsed as a name. Rows without either fall back to the
   summary, then the source, so every row names something.

   Lifted out of the row loop because the column measures itself from the
   rows now: the width and the cell have to be reading the same string. *)
let schedule_row_subject (row : Masc_tui_types.schedule_row) =
  match Masc_tui_types.schedule_row_who row with
  | Some who -> who
  | None -> (
    match row.sch_payload_summary with
    | Some summary -> summary
    | None -> row.sch_source)
;;

let schedule_status_color status =
  semantic_status_color status

(* The wake's status is the contract's own word, so the list column is as
   wide as the widest word the contract can send and no wider: the value
   was a string, and the column a literal 10 that happened to fit
   "succeeded". Measured once from the contract's list, the column and
   the vocabulary cannot drift apart. *)
let schedule_wake_word = Schedule_contract_values.wake_status_to_string

let schedule_wake_word_cells =
  List.fold_left
    (fun widest word -> max widest (Message_layout.display_width word))
    0 Schedule_contract_values.wake_status_strings

(* The same rule for the schedule's own status. [sch_status] arrives as a
   string rather than the contract's variant, so the cell is cut to this
   width as well: a word the contract does not name cannot push the columns
   beside it out of line. *)
let schedule_status_word_cells =
  List.fold_left
    (fun widest word -> max widest (Message_layout.display_width word))
    0 Schedule_contract_values.schedule_status_strings


(* The width of the request clock column, read off the format rather than
   typed. [short_timestamp] answers a parsed stamp in this shape, but an
   unparsed one comes back as the source text and an absent one as "(never)",
   and either of those pulls the three columns after it out of line -- the
   same shape as the printf padding this row gave up. *)
let schedule_requested_clock_cells =
  Message_layout.display_width (Terminal_text.short_timestamp_of_unix 0.)

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
  | None -> Masc_tui_theme.Glyph.no_value
  | Some status -> cut status

(* What the last occurrence came to, for a row that has one line to say it.

   A wake that did not succeed is the outcome. A succeeded wake hands the
   column to the furthest step the ledger recorded -- the reading that
   separates a wake merely taken from one that finished a turn. No wake at
   all is no outcome: the reaction evidence beside it belongs to the
   occurrence before (a held occurrence has no wake of its own, and a
   projection between occurrences still carries the last one's reading), so
   drawing it would pair a dash in the trigger column with a word about a
   different occurrence in this one. The word is the server's own, cut of
   its [matched_] prefix, and the caller sanitises it the way it sanitises
   every other reading from this projection. *)
let schedule_outcome_word (row : schedule_row) =
  match row.sch_last_wake_status with
  | Some Schedule_contract_values.Wake_succeeded ->
      schedule_delivery_word row
  | Some other -> schedule_wake_word other
  | None -> Masc_tui_theme.Glyph.no_value

(* Whether a status word names a schedule that can still act. The word is
   the projection's own; a word this build does not name stays with the live
   rows rather than being buried under the closed rule -- the same promise
   the word itself makes by rendering as itself. *)
let schedule_status_is_terminal word =
  match Schedule_domain.schedule_status_of_string word with
  | Ok status -> Schedule_domain.is_terminal status
  | Error _ -> false

let schedule_delivery_summary ~freshness ~runner (row : schedule_row) =
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
  (* A held occurrence has no wake of its own, so the queue and reaction
     readings on the next line still describe the previous one. The hold says
     so on the identity line, next to the status it would otherwise leave
     reading as a late [due]. The short tag, because the line is already
     most of a narrow screen; the detail pane carries the full sentence.
     Unless the list is the latest answer and the runner is [ok], the hold
     is drawn at the time the runner read it: the tag names that time instead
     of the due -- the same width, and the due column above still has the
     due (#38411). *)
  let hold =
    match row.sch_runner_hold with
    | None -> ""
    | Some hold ->
        " \xc2\xb7 "
        ^ (match Tui_decode.schedule_hold_reading ~freshness ~runner hold with
           | Tui_decode.Hold_current ->
               Render_schedule.schedule_hold_tag
                 ~due:(Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso)
           | Tui_decode.Hold_as_of checked ->
               Render_schedule.schedule_hold_as_of_tag
                 ~checked:(Terminal_text.short_timestamp_of_unix checked))
  in
  ( Printf.sprintf "%s \xc2\xb7 status:%s%s" row.sch_schedule_id
      row.sch_status hold
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

(* The list on screen is the newest answer only while its last load
   succeeded. A failed reload keeps the previous list on screen, and a hold on
   it is then an earlier reading whatever the runner said at the time. *)
let schedule_list_freshness (state : state) =
  match state.schedules_error with
  | None -> Tui_decode.List_latest
  | Some _ -> Tui_decode.List_kept

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedule_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s  %s"
    (screen_title " MASC Keepers / Schedules")
    timestamp
    (connection_badge state) in

  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"schedules" ~title:header
    ~hints:(Masc_tui_keys.footer_hints ~detail_open:false Schedules)
    ~body:(fun ~budget c ->
  (match state.schedules with
   | None ->
       (match schedule_source_warning state with
        | Some err ->
            c.push (data_unreliable_row ~cols err)
        | None ->
            c.push (Ansi.dim ^ page_unread_note ^ Ansi.reset))
   | Some snapshot ->
       let warning_rows =
         match schedule_source_warning state with
         | None -> 0
         | Some err ->
             c.push (data_unreliable_row ~cols err);
             1
       in
       (* The arm and the server's last refusal take a row each under the
          list while they stand. *)
       let cancel_rows =
         (if Option.is_some state.schedule_cancel_armed then 1 else 0)
         + (if Option.is_some state.schedule_cancel_error then 1 else 0)
       in
       if not (String.equal snapshot.scs_status "ok") then begin
         (* The server's "unknown" is a failed store read, not an empty list;
            the row says which, so a dead ledger cannot read as "nothing is
            scheduled". *)
         (match snapshot.scs_read_error with
          | Some err ->
              c.push (data_unreliable_row ~cols err)
          | None ->
              c.push
                ((Theme.bad ()) ^ "  (schedule store unreadable)" ^ Ansi.reset))
       end else begin
         let count_text =
           match snapshot.scs_request_count with
           | Some total when snapshot.scs_truncated ->
               Printf.sprintf "  Requests: %d  (page shows first %d)" total
                 (List.length snapshot.scs_rows)
           | Some total ->
               Printf.sprintf "  Requests: %d" total
           | None -> "  Requests: " ^ Masc_tui_theme.Glyph.no_value
         in
         (* One row, not two. The count and the next wake are a phrase each,
            and with nothing due the second row was drawn blank -- a row of
            the list given up to say nothing. *)
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               Printf.sprintf "%s  \xc2\xb7  Next due: %s%s" Ansi.dim
                 (Terminal_text.short_timestamp iso) Ansi.reset
           | None -> ""
         in
         c.push (Ansi.bold ^ count_text ^ Ansi.reset ^ next_due_text);
         c.push_divider ();

         let count = List.length snapshot.scs_rows in
         if count = 0 then begin
           (* The key that fills this list, on the row that says it is empty.
              [n] is an Act key on a surface whose Navigate keys take the
              footer first -- j/k, PgUp/PgDn, [ / ] -- so at a hundred and ten
              columns the footer drops every action this screen has, [n] with
              them. An operator looking at an empty Schedules screen then has
              nowhere on it saying a schedule can be made at all. Same move
              [page_unread_note] made for [r]. *)
           c.push
             (Ansi.dim
             ^ "  (no scheduled automation \xe2\x80\x94 press n to create one)"
             ^ Ansi.reset)
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
               Render_schedule.schedule_minimum_target_width snapshot.scs_rows
             |> min Render_schedule.schedule_maximum_target_width
           in
           let wake_width = schedule_wake_word_cells in
           (* Measured, like the target beside it. The column was a literal
              12, and the words the projection sends run past it: live,
              [turn_finished] drew as [tur...finished], and
              [terminal_cancelled] and [conflicting_terminal_evidence] are
              longer still. The wake column next to it takes its width from
              the contract's own list; this one has no such list to read
              (#38350), so it is measured from the rows on the page. *)
           let delivery_width =
             Render_schedule.schedule_delivery_width
               (List.map
                  (fun row ->
                    Terminal_text.single_line (schedule_delivery_word row))
                  snapshot.scs_rows)
           in
           let layout =
             Render_schedule.schedule_layout
               ~inner_width:(max 1 (framed_inner_width cols - 2))
               ~target_width:subject_width ~wake_width ~delivery_width
           in
           c.push_styled ~style:(Theme.recede ())
             ("  " ^ Render_schedule.schedule_header_row ~layout);
           c.push_divider ();
           (* The column names and the rule under them, the two rows every
              other list on this screen already spends to say what it draws. *)
           let header_rows = 2 in
           (* The body outside the list: the source warning, the request count,
              next due and its divider, the column names and their rule, the
              two delivery rows, and the cancel rows. *)
           let content_height =
             max 1 (budget - warning_rows - 3 - header_rows - 2 - cancel_rows)
           in
           let scroll_offset =
             if state.schedule_cursor >= content_height then
               state.schedule_cursor - content_height + 1
             else 0
           in
           let scs_rows_window = Rows.of_list ~first:scroll_offset ~height:content_height snapshot.scs_rows in
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             match Rows.at scs_rows_window idx with
             | None -> c.push_empty ()
             | Some row -> begin
               let is_selected = idx = state.schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Terminal_text.short_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
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
                 Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:schedule_wake_word
                   row.sch_last_wake_status
               in
               (* The enqueue result and what became of the wake are two
                  facts, and the list carried only the first: a wake the queue
                  cancelled forty seconds later still read [wake:succeeded].
                  Both are here, each under its own name.

                  The target is measured from the rows rather than given the
                  rest of the line. The subject is a keeper name on every row
                  that has a payload target, so [cols - 76] spent ninety cells
                  on [edgar.a.poe] and the recurrence past it -- which is where
                  the timezone lives -- read [daily 08:00:00 A~]. The fallback
                  summary can be long, so it is capped rather than trusted. *)
               let line =
                 Render_schedule.schedule_row ~status_style:status_color
                   ~wake_style:(schedule_status_color last_wake)
                   ~recurrence_style:Ansi.dim ~layout
                   { Render_schedule.srow_status =
                       bracketed ~max_cells:10 row.sch_status
                   ; srow_due = due
                   ; srow_target = Terminal_text.single_line subject
                   ; srow_wake = last_wake
                   ; srow_delivery =
                       Terminal_text.single_line (schedule_delivery_word row)
                   ; srow_recurrence =
                       Terminal_text.single_line row.sch_recurrence_summary
                   }
               in
               let content =
                 if is_selected then
                   Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
                 else
                   "  " ^ line
               in
               c.push content
             end
           done;
           (match List.nth_opt snapshot.scs_rows state.schedule_cursor with
            | None ->
                c.push_empty ();
                c.push_empty ()
            | Some selected ->
                let identity, delivery =
                  schedule_delivery_summary
                    ~freshness:(schedule_list_freshness state)
                    ~runner:snapshot.scs_runner_status selected
                in
                c.push_styled ~style:(Theme.recede ())
                  ("  " ^ identity);
                c.push_styled ~style:(Theme.recede ())
                  ("  " ^ delivery))
         end;
         (* The arm and the server's last refusal sit under the list, the
            same rows the goal detail carries them on. *)
         (match state.schedule_cancel_armed with
          | Some schedule_id ->
              c.push
                ((Theme.warn ())
                ^ Printf.sprintf
                    "  armed: cancel %s -- same key again to send"
                    (Terminal_text.single_line schedule_id)
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some (schedule_id, err) ->
              c.push
                ((Theme.bad ()) ^ "  "
                ^ fit_width (Terminal_text.single_line (schedule_id ^ ": " ^ err)) (cols - 8)
                ^ Ansi.reset)
          | None -> ())
       end))

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
      | None -> field label Masc_tui_theme.Glyph.no_value
      | Some value ->
          let tone =
            if value = bad_when_true then Theme.bad () else Theme.ok ()
          in
          let at =
            match value, recorded_at with
            | true, Some timestamp ->
              " \xc2\xb7 " ^ timestamp
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
          (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_reaction_kind)
      ; field
          ~style:(if Option.is_some row.sch_reaction_reason then Theme.warn () else Ansi.dim)
          "Reason" (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_reaction_reason)
    ; field
        ~style:
          (match row.sch_reaction_quarantined with
           | Some count when count > 0 -> Theme.warn ()
           | Some _ | None -> Ansi.dim)
        "Quarantined"
        (match row.sch_reaction_quarantined with
         | None -> Masc_tui_theme.Glyph.no_value
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
    [ (let word =
         Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:schedule_wake_word
           row.sch_last_wake_status
       in
       field
         ~style:
           (if Option.is_some row.sch_last_wake_status then
              schedule_status_color word
            else Ansi.dim)
         "Status" word)
    ; field "Started" (timestamp row.sch_last_wake_started_at_iso)
    ; field
        ~style:(if Option.is_some row.sch_last_wake_error then Theme.bad () else Ansi.dim)
        "Error" (Option.value ~default:Masc_tui_theme.Glyph.no_value row.sch_last_wake_error)
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
      @ [ (Theme.bad (), "  Wake history: " ^ Terminal_text.single_line err) ]
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
                (* The status is the row's label, drawn through [field] so
                   the times start in the column every other value on the
                   page starts in. A literal 12 here put them two cells to
                   the left of the Reaction time below. *)
                let word = schedule_wake_word wake.swk_status in
                let head =
                  field ~style:(schedule_status_color word) word
                    (Printf.sprintf "%s \xe2\x86\x92 %s" started finished)
                in
                match wake.swk_error with
                | None -> [ head ]
                | Some err -> [ head; field ~style:(Theme.bad ()) "" err ])
             wakes

let schedule_detail_lines ~width ~freshness ~runner (row : schedule_row)
      ~(wake_history : schedule_wake_history option)
      ~(wake_history_error : (string * string) option) =
  let field ?(style = Ansi.reset) label value =
    let prefix = Printf.sprintf "  %-14s " label in
    let prefix_cells = Message_layout.display_width prefix in
    let rows =
      if width - prefix_cells >= width / 2 then
        let values = Masc_tui_text_block.rows ~max_cells:(max 1 (width - prefix_cells)) value in
        (match values with
         | [] -> [prefix]
         | values -> List.mapi (fun index line ->
             (if index = 0 then prefix else String.make prefix_cells ' ') ^ line) values)
      else
        (if String.equal label "" then [] else ["  " ^ label])
        @ Masc_tui_text_block.rows ~max_cells:width value in
    style, String.concat "\n" rows
  in
  let optional value = Option.value ~default:Masc_tui_theme.Glyph.no_value value in
  let timestamp value =
    match value with
    | None -> Masc_tui_theme.Glyph.no_value
    | Some iso -> iso
  in
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> status
    | None, Some count -> Printf.sprintf "pending=%d" count
    | Some status, Some count -> Printf.sprintf "%s  pending=%d" status count
  in
  let reaction =
    match row.sch_reaction_projection_status, row.sch_reaction_latest_at_iso with
    | None, None -> Masc_tui_theme.Glyph.no_value
    | Some status, None -> status
    | None, Some at -> at
    | Some status, Some at ->
        Printf.sprintf "%s  %s" status at
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
      row.sch_requested_at_iso
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
  (* The four headings around this one -- SCHEDULE, PAYLOAD, PAYLOAD JSON and
     DELIVERY EVIDENCE -- are drawn bold at this indent, and so are the field
     labels. Caps are what tells the two apart: "Summary" sat directly under
     "Digest  digest-..." with nothing beside it, which reads as a field whose
     value is missing rather than as the section that follows. *)
  ; Ansi.bold, "  SUMMARY"
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
  @ (match row.sch_runner_hold with
     | None -> []
     | Some hold ->
         [ field ~style:(Theme.warn ()) "Held"
             (match Tui_decode.schedule_hold_reading ~freshness ~runner hold with
              | Tui_decode.Hold_current ->
                  let due = Terminal_text.short_timestamp hold.Tui_decode.srh_due_at_iso in
                  (match hold.Tui_decode.srh_reason with
                   | Tui_decode.Hold_previous_wake_untaken ->
                       Render_schedule.schedule_hold_reading ~due
                   | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                       Render_schedule.schedule_fence_hold_reading
                         ~due ~target ~fence_owner)
              | Tui_decode.Hold_as_of checked ->
                  let checked = Terminal_text.short_timestamp_of_unix checked in
                  (match hold.Tui_decode.srh_reason with
                   | Tui_decode.Hold_previous_wake_untaken ->
                       Render_schedule.schedule_hold_as_of_reading ~checked
                   | Tui_decode.Hold_target_shutdown_fenced { target; fence_owner } ->
                       Render_schedule.schedule_fence_hold_as_of_reading
                         ~checked ~target ~fence_owner))
         ; field "Held id" hold.Tui_decode.srh_occurrence_id
         ; field "Held due" hold.Tui_decode.srh_due_at_iso
         ])
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

let schedule_detail_content (state : state) ~cols ~runner (row : schedule_row) =
  let width = max 1 (framed_inner_width cols) in
  let wire text = String.concat "\n"
      (List.map Terminal_text.single_line (String.split_on_char '\n' text)) in
  let warnings =
    (* The latest action refusal is the row the result handler reveals.
       Source freshness still has its fixed summary outside this document. *)
    (match state.schedule_cancel_error with
     | Some (schedule_id, error) when String.equal schedule_id row.sch_schedule_id ->
         [Theme.bad (), "Cancel error: " ^ wire error]
     | Some _ | None -> [])
    @ (match schedule_source_warning state with
       | None -> [] | Some error -> [Theme.bad (), "Source: " ^ wire error])
    @ (match state.schedule_cancel_armed with
       | None -> [] | Some id -> [Theme.warn (), "Armed: cancel " ^ wire id ^ " -- press x again to submit"]) in
  let fields = schedule_detail_lines ~width
      ~freshness:(schedule_list_freshness state) ~runner row
      ~wake_history:state.schedule_wake_history
      ~wake_history_error:state.schedule_wake_history_error in
  List.concat_map (fun (style, text) ->
      String.split_on_char '\n' text |> List.concat_map (fun line ->
        if Message_layout.display_width line <= width then [style, line]
        else match Message_layout.wrap_words ~max_cells:width line with
        | [] -> [style, ""]
        | lines -> List.map (fun text -> style, text) lines))
    (warnings @ fields)

let schedule_detail_height ~rows ~warning_rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:(framed_chrome_rows + warning_rows) ~count
    ~preview_keep:None ~overflow_takes_row:true

let schedule_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let cols = if cols < keeper_split_threshold_cols then cols else cols - keeper_roster_pane_cols in
  let count = match state.schedule_detail_id, state.schedules with
    | Some id, Some snapshot ->
        (match List.find_opt (fun row -> String.equal row.sch_schedule_id id) snapshot.scs_rows with
         | None -> 0
         | Some row -> List.length (schedule_detail_content state ~cols ~runner:snapshot.scs_runner_status row))
    | Some _, None | None, _ -> 0 in
  let warning_rows = if Option.is_some (schedule_source_warning state) then 1 else 0 in
  count, schedule_detail_height ~rows ~warning_rows ~count

let schedule_detail_pane (state : state) ~rows ~cols ~runner (row : schedule_row) buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s[%s]%s"
       (screen_title " MASC Keepers / Schedules ▸ details")
       (schedule_status_color row.sch_status)
       (Terminal_text.single_line row.sch_status) Ansi.reset);
  box_divider buf cols;
  (* Source freshness governs every evidence row, so it stays visible while
     the reader moves. The complete warning also remains in the reader for
     narrow viewports or a refusal longer than the fixed status summary. *)
  let warning_rows = match schedule_source_warning state with
    | None -> 0
    | Some error -> box_line buf cols (data_unreliable_row ~cols error); 1 in
  let lines = schedule_detail_content state ~cols ~runner row in
  let count = List.length lines in
  let height = schedule_detail_height ~rows ~warning_rows ~count in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.schedule_scroll in
  let lines_window = Rows.of_list ~first:scroll ~height lines in
  for index = 0 to height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height count);
  box_bottom buf cols;
  scroll, Masc_tui_scroll.maximum ~count ~height
;;

(* The schedule list stays beside the schedule. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_schedule_detail (state : state) ~runner (row : schedule_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, _max_scroll =
    if cols < keeper_split_threshold_cols then
      schedule_detail_pane state ~rows ~cols ~runner row buf
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
        ~focused:false
        ~holding:
          (Option.bind state.schedules (fun snapshot ->
               snapshot.scs_request_count))
        ~labels ~selected:state.schedule_cursor;
      let answer =
        schedule_detail_pane state ~rows ~cols:(cols - left_cols) row
          ~runner right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:true Schedules));
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
       | Some row ->
           render_schedule_detail state ~runner:snapshot.scs_runner_status row
       | None -> render_schedule_list state)
  | Some _, None | None, _ -> render_schedule_list state

(* The table's variant: the normal state is silent. On a healthy fleet every
   row said "healthy" while the heading counted "11 healthy" and the summary
   said "fleet ok" — the same fact four times, and the glyph beside the word
   already carries the health colour. Only a deviation earns a word, so the
   one deviating row is the only row with text in the column. The single-keeper
   chat header keeps {!keeper_health_word}: alone, the word is identity, not
   repetition. *)
let keeper_health_deviation_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> (
      match Tui_decode.keeper_health_reading value with
      | Tui_decode.Health_running -> ""
      | Tui_decode.Health_idle | Tui_decode.Health_failing | Tui_decode.Health_offline ->
          Tui_decode.keeper_health_to_string value)

(* [runtime_id] is the producer-owned runtime identity. Keep it whole instead
   of deriving a model by splitting its spelling: the phase is a separate
   typed reading, while the sanitized id is the exact identity the gate named. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some row ->
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        (Terminal_text.single_line row.kr_runtime_id)

(* The two halves of the runtime cell, so the column that has to be wide
   enough for them is measured from the same strings that get drawn. *)
let keeper_runtime_parts (row : keeper_runtime) =
  let phase =
    if row.kr_paused then "paused "
    else if Tui_decode.keeper_phase_is_running row.kr_phase then ""
    else Tui_decode.keeper_phase_to_string row.kr_phase ^ " "
  in
  (phase, Terminal_text.single_line row.kr_runtime_id)

(* What the widest row would spend on this cell. A keeper the roster cannot
   see draws an em dash, which is one cell. *)
let keeper_runtime_cells (runtime : keeper_runtime option) =
  match runtime with
  | None -> 1
  | Some row ->
      let phase, runtime_id = keeper_runtime_parts row in
      Message_layout.display_width phase
      + Message_layout.display_width runtime_id

let keeper_runtime_cell ~width (runtime : keeper_runtime option) =
  match runtime with
  | None -> fit_width Masc_tui_theme.Glyph.no_value width
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
      let phase, runtime_id = keeper_runtime_parts row in
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
      let module Mark = Masc_tui_keeper_mark in
      let sandbox =
        match Mark.sandbox_of_profile row.kr_sandbox_profile, row.kr_sandbox_profile with
        | Some (Mark.Docker as known), _ ->
          (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Microvm as known), _ ->
          (Theme.category Theme.Slot_2) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Local as known), _ -> Ansi.dim ^ Mark.sandbox_letter known ^ Ansi.reset
        | None, other when String.length other > 0 ->
          (Theme.warn ()) ^ String.uppercase_ascii (String.sub other 0 1) ^ Ansi.reset
        | None, _ -> Ansi.dim ^ "?" ^ Ansi.reset
      in
      Mark.activation_letter row.kr_activation_mode ^ " " ^ sandbox

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
    ; (* TURN, not LAST: where the runtime column is hidden this heading and
         TASK sit one cell apart, and "LAST TASK" read as one column over the
         two cells under it. *)
      " " ^ Message_layout.pad_left "TURN" Render_schedule.keeper_last_turn_width
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
  (* A keeper with an open turn draws the turn's mark in the HEALTH cell. The
     mark moves while the turn is being worked: it is the one thing on the
     screen that is changing as the reader looks at it.

     The word beside the mark is the health word on every row, open turn or
     not, because it is the word the roster header counts: a healthy keeper
     says nothing, a failing one says "failing". How long the turn has run
     belongs to the TURN cell (see [Masc_tui_keeper_mark.turn_clock]), on
     every row alike. A failing keeper's row keeps its health word, so a
     clock drawn here was left out of exactly that row, and the TURN cell's
     last recorded turn -- the failure -- was the only age beside a moving
     mark: "failing 7m45s" read as the work in progress, under a turn that
     had run for half a minute (code-reviewer, 2026-09-24).

     A failing keeper's mark keeps moving in its next-action colour: its
     keepalive is running the next attempt. A turn whose keeper the health
     reading calls offline was never closed and nothing works it: the mark
     stops and takes the failure colour. *)
  let health_word = keeper_health_deviation_word health in
  let glyph, status_color =
    match (turn : Tui_decode.keeper_turn_state option) with
    | Some (Tui_decode.Keeper_turn_running _) -> (
        match
          Masc_tui_keeper_mark.open_turn
            (Option.map Tui_decode.keeper_health_reading health)
        with
        | Masc_tui_keeper_mark.Worked ->
            (Masc_tui_answering.running_glyph ~frame, Theme.info ())
        | Masc_tui_keeper_mark.Worked_while_failing ->
            (Masc_tui_answering.running_glyph ~frame, status_color)
        | Masc_tui_keeper_mark.Left_open ->
            (Masc_tui_answering.running_glyph ~frame:(-1), Theme.bad ()))
    | Some Tui_decode.Keeper_turn_idle
    | Some (Tui_decode.Keeper_turn_unavailable _)
    | None ->
      (keeper_state_glyph ~paused ~health, status_color)
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
      (match keeper.k_activity with
       | None -> "not observed"
       | Some activity ->
         Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
           activity.k_current_task_id)
      columns.kcol_task
  in
  String.concat ""
    [ "   "
    ; status_color ^ glyph ^ " "
      ^ fit_width health_word (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; " "
    ; (* A keeper whose gate runs every call unasked wears its name in
         red: the stance has no column of its own, and the name is what
         the eye finds first. On the selected row the band folds this red
         with every other cell colour. *)
      (if yolo then (Theme.bad ()) ^ name ^ Ansi.reset else name)
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; (* The lifetime turn count said nothing an operator acts on; how long
         this keeper has been at its turn, or since it last turned, does. An
         open turn is what the keeper is doing now, so it wins, and it is
         drawn in the mark's colour; a finished turn is past and stays dim.
         A keeper that never turned, or one whose last turn reads from the
         future, draws the dash every unknown draws. The count itself still
         lives on the detail pane. *)
      (let dash = Masc_tui_theme.Glyph.no_value in
       let turn_color, turn_age =
         match
           Masc_tui_keeper_mark.turn_clock ~turn
             ~last_turn_at:(Option.bind keeper.k_activity (fun activity ->
               Masc_domain.parse_iso8601_opt activity.k_last_turn_ts))
         with
         | Masc_tui_keeper_mark.Open_turn_started started_at ->
             (status_color, Masc_tui_answering.elapsed_text ~now started_at)
         | Masc_tui_keeper_mark.Last_turn_recorded since -> (
             match Message_layout.age_text ~now ~since with
             | Some text -> (Ansi.dim, text)
             | None -> (Ansi.dim, dash))
         | Masc_tui_keeper_mark.No_turn_recorded -> (Ansi.dim, dash)
       in
       Printf.sprintf " %s%s%s" turn_color
         (Message_layout.pad_left turn_age Render_schedule.keeper_last_turn_width)
         Ansi.reset)
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
   health vocabulary. A word is parsed back into a health reading rather than
   compared as text, so a new reading is a compile error here instead of a word
   that falls to dim. A word that is not a health -- [unread], [absent],
   [config error] -- is the roster not answering, which is dim rather than any
   health colour. *)
let keeper_roster_status_color label =
  match Tui_decode.keeper_health_of_string label with
  | None -> Ansi.dim
  | Some health -> (
      match Tui_decode.keeper_health_reading health with
      | Tui_decode.Health_running -> Theme.ok ()
      | Tui_decode.Health_failing -> Theme.warn ()
      | Tui_decode.Health_idle | Tui_decode.Health_offline -> Theme.muted ())

(* The tally is [Keeper_control.status_tally], so every word here is a word the
   status column shows for the same keeper. This function only paints it. *)
let keeper_roster_summary readings =
  Keeper_control.health_tally readings
  |> List.map (fun (label, count) ->
         Printf.sprintf "%s%d %s%s" (keeper_roster_status_color label) count
           label Ansi.reset)

(* The subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wants with no live turn-executing fiber is bootable minus executable,
   while a keeper whose fiber is alive but whose durable demand is not
   admissible is running minus executable. Reporting the second as "not
   running" sent an operator to boot ten keepers that were already up, and
   subtracting the Running-phase list instead of the executable list here put
   every Failing keeper in "not running" too -- a failing keepalive still
   runs its turns, so keepers that were visibly turning were listed as not
   running (2026-09-16). Executable is the set with a live fiber (Running or
   Failing), which is the fact the label names. *)
let keeper_fleet_gap_lines (fleet : fleet_safety) =
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let not_running = subtract fleet.fs_bootable_names fleet.fs_executable_names in
  let running_without_turn =
    subtract fleet.fs_running_names fleet.fs_executable_names
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (not_running, "not running", (Theme.bad ()))
    ; (running_without_turn, "running, cannot take a turn", (Theme.warn ()))
    ; (* Failing subsets that need operator action: turn configuration
         errors survive every retry, so the names are listed where the
         failing counter only counts them. Unscoped on purpose -- the
         configuration_blocked_* wire fields are autoboot-scoped and skip a
         blocked keeper booted on request. *)
      ( fleet.fs_turn_configuration_error_names
      , "config-blocked"
      , (Theme.bad ()) )
    ; ( fleet.fs_official_client_recovery_required_names
      , "session recovery required"
      , (Theme.bad ()) )
    ]


(* The conditions that share a phase with another: either health reading
   makes a keeper failing, and a pending launch is one of the ways it is
   offline. Each of the other conditions has a phase of its own, which the
   lifecycle word already says, so naming it again would add nothing. *)
let keeper_lane_phase_causes (conditions : Tui_decode.keeper_lane_conditions) =
  List.filter_map
    (fun (holds, words) -> if holds then Some words else None)
    [ (not conditions.klc_turn_healthy, "last turn failed")
    ; (not conditions.klc_heartbeat_healthy, "heartbeat failed")
    ; (conditions.klc_launch_pending, "launch pending")
    ]

let keeper_lane_lifecycle_text (lane : Tui_decode.keeper_lane) =
  let phase =
    Terminal_text.single_line (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
  in
  match keeper_lane_phase_causes lane.kl_conditions with
  | [] -> phase
  | causes -> Printf.sprintf "%s (%s)" phase (String.concat ", " causes)

let keeper_operations_outcome_text = function
  | None -> Masc_tui_theme.Glyph.no_value
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
           let target_note =
             match
               List.find_opt
                 (fun (a : Tui_decode.runtime_assignment) ->
                    String.equal a.ra_keeper keeper.k_name)
                 state.runtime_assignments
             with
             | Some a -> " \xc2\xb7 target " ^ runtime_assignment_label a
             | None ->
                 match state.runtime_surface with
                 | Some s ->
                     (match s.rss_resolved.rrs_default_runtime_id with
                      | Some def -> Printf.sprintf " \xc2\xb7 target %s (default)" def
                      | None -> "")
                 | None -> ""
           in
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
                  ; keeper_lane_lifecycle_text lane
                  ; " · turn "
                  ; Terminal_text.single_line
                      (Tui_decode.keeper_lane_turn_phase_to_string
                         lane.kl_turn_phase)
                  ; " · idle "
                  ; keeper_lane_idle_text lane.kl_idle_seconds
                  ; " · last "
                  ; keeper_operations_outcome_text lane.kl_last_outcome
                  ; target_note
                  ]
            | None ->
                Ansi.dim ^ "  OPERATIONS  no composite row for "
                ^ Terminal_text.single_line keeper.k_name ^ target_note ^ Ansi.reset)
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
  let keepers_error = Terminal_text.optional_single_line state.keepers_error in

  Buffer.add_char buf '\n';

  (* One clock read for the frame: the header clock and the age of a stale
     fleet reading below are the same instant. *)
  let now_unix = Unix.gettimeofday () in
  let now = Unix.localtime now_unix in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading =
    screen_title
      (Printf.sprintf " MASC Keepers %s"
         (match state.keepers, keeper_rows_page state ~error:keepers_error with
          | _ :: _, _ | [], Page_empty ->
              Printf.sprintf "(%d)" (List.length state.keepers)
          | [], (Page_unread | Page_failed) ->
              title_missing_reading ~error:keepers_error))
    (* The same marker the footer draws. These two said different things
       about the same pair of fields: the heading kept its own spelling and
       so reported no count, and named n/N on surfaces where those keys do
       nothing. *)
    ^ search_marker_styled state
  in
  (* The roster is the surface an operator watches to see which keepers are
     up, and it was the one top-level surface whose title never said whether
     the reading was live: "1 healthy · 1 idle" read the same over a dead
     coordinator as over a live one. The badge also carries the workspace
     mismatch, which this screen could not report at all. It sits at the right
     edge, where the clock was, and the clock moves left of it. *)
  let badge = connection_badge state in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading - String.length timestamp
       - 2 - Message_layout.display_width badge)
  in
  box_line buf cols
    (heading ^ String.make gap ' ' ^ Ansi.dim ^ timestamp ^ Ansi.reset ^ "  "
     ^ badge);

  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  (match keeper_roster_summary readings with
   | [] -> ()
   | parts ->
       box_line buf cols
         ("  Health  " ^ String.concat (Ansi.dim ^ " · " ^ Ansi.reset) parts));

  (match (state.fleet_safety, state.fleet_safety_error) with
   | _, Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  fleet: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None, None -> ()
   | Some (Fleet_not_measured { status }), None ->
       box_line buf cols
         ((Theme.warn ()) ^ "  fleet "
          ^ Masc_tui_fleet_line.not_measured_text ~status
          ^ Ansi.reset)
   | Some (Fleet_measured { fleet; freshness }), None ->
       let tone =
         if fleet.fs_operator_action_required then (Theme.bad ())
         else if Masc_tui_fleet_line.status_is_ok fleet.fs_status then (Theme.ok ())
         else (Theme.warn ())
       in
       let blocker =
         match Masc_tui_fleet_line.blocker_text fleet with
         | None -> ""
         | Some text -> "   " ^ text
       in
       box_line buf cols
         (Printf.sprintf
            "%s  fleet %s%s   running %d/%d   turn capacity %d/%d%s%s%s" tone
            (Masc_tui_fleet_line.status_text fleet.fs_status)
            Ansi.reset fleet.fs_running_count
            fleet.fs_bootable_count
            (fleet.fs_target_reaction_capacity
            - fleet.fs_reaction_capacity_shortfall)
            fleet.fs_target_reaction_capacity Ansi.dim blocker Ansi.reset);
       (* Its own row under the fleet line rather than a tail on it: the
          frame cuts a row from the right, and the counts are what a narrow
          screen keeps. *)
       Option.iter
         (fun text ->
            box_line buf cols
              ((Theme.warn ()) ^ "  fleet reading: " ^ text ^ Ansi.reset))
         (Masc_tui_fleet_line.freshness_text ~now:now_unix freshness);
       let failing_entry =
         Option.to_list (Masc_tui_fleet_line.failing_text fleet)
       in
       let entry label n =
         if n > 0 then [ Printf.sprintf "%s %d" label n ] else []
       in
       (* The owner count keeps its place in the row and brings its own
          shortfall, which is the only reading that says the scan came up
          short: an unread Keeper does not move the fleet status. *)
       let counts =
         failing_entry
         @ entry "paused" fleet.fs_paused_count
         @ Option.to_list (Masc_tui_fleet_line.owner_scan_text fleet)
         @ entry "awaiting verdict" fleet.fs_completion_authority_pending_count
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
            "%s  live status covers %d of %s; the rest read as unknown%s"
            (Theme.warn ()) (List.length observed) (Masc_tui_message_layout.count_noun total "keeper") Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  (* Measured over every reading rather than the rows on screen, so the
     columns do not move while a reader scrolls. *)
  let widest_runtime =
    List.fold_left
      (fun widest (reading : Keeper_control.reading) ->
        let runtime =
          match reading.Keeper_control.liveness with
          | Keeper_control.Present row -> Some row
          | Keeper_control.Absent | Keeper_control.Unobserved
          | Keeper_control.Invalid _ -> None
        in
        max widest (keeper_runtime_cells runtime))
      0 readings
  in
  let columns =
    Render_schedule.allocate_keeper_columns ~inner_width:inner ~widest_runtime
  in
  box_line_styled buf cols ~style:(Theme.recede ()) (keeper_column_header columns);
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = count_frame_lines buf in
  let footer_rows = 3 in
  let list_rows = max 0 (rows - chrome_rows - footer_rows) in
  let keeper_count = List.length state.keepers in
  (* A roster with more keepers than rows says which of them these are, the
     way every other scrolled list on this screen does. The line costs one of
     the rows it describes, so it is drawn only where there is something to
     say, and only where there is a row to spend on it: with no rows left the
     roster draws nothing and the line would push the frame past its budget. *)
  let overflowing = list_rows > 0 && keeper_count > list_rows in
  let keeper_rows = if overflowing then max 0 (list_rows - 1) else list_rows in
  (* The window stays where the last frame drew it while the cursor is on it,
     and moves only as far as the cursor needs. *)
  let scroll_offset =
    if keeper_rows > 0 then
      min
        (max 0 (keeper_count - keeper_rows))
        (Masc_tui_scroll.ensure_visible ~cursor:state.keeper_cursor
           ~height:keeper_rows state.keeper_list_scroll)
    else 0
  in
  let keepers_window = Rows.of_list ~first:scroll_offset ~height:keeper_rows state.keepers in
  let readings_window = Rows.of_list ~first:scroll_offset ~height:keeper_rows readings in
  if keeper_count = 0 then begin
    (* A roster that was never read is as empty as one that holds no files;
       only the second is "no keeper metadata". *)
    let note =
      match keeper_rows_page state ~error:keepers_error with
      | Page_empty -> Some (match state.workspace_identity with
          | Workspace_identity_mismatch _ -> "   server Keeper roster is empty"
          | Workspace_identity_match | Workspace_identity_unread ->
            "   no keeper metadata under .masc/keepers/")
      | Page_unread -> Some page_unread_note
      | Page_failed -> None
    in
    Option.iter
      (fun note ->
        if keeper_rows > 0 then box_line buf cols (Ansi.dim ^ note ^ Ansi.reset))
      note;
    let filled = if Option.is_some note then 1 else 0 in
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
          (* Fitted before it is marked: a cut that fell after the mark
             would drop its close, and the row's press would run on into
             the Activity pane drawn beside it. *)
          let press text =
            pressable (Press_keeper_row keeper.k_name) (fit_width text inner)
          in
          if position = state.keeper_cursor then
            box_line_selected buf cols (press (Masc_tui_theme.strip_sgr row))
          else box_line buf cols (press row)
      | Some _, None | None, Some _ | None, None -> box_empty buf cols
    done;

  if overflowing then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[keepers %s]"
         (Masc_tui_scroll.window_text ~scroll:scroll_offset ~height:keeper_rows
            keeper_count));

  box_line buf cols (keeper_operations_preview state);
  (* A section rule, drawn by the helper the rest of this surface uses, so it
     reads as the two rules above it do. No corners: the Keepers frame holds
     no box_tl, box_tr or edge bar for a corner to point at. *)
  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state
       ~status:(keeper_action_status state)
       ~max_cells:cols
       ~hints:(keeper_control_hints ~offers_back:false state selected_reading));

  finish_surface state ~clamped:(Keeper_list_scroll scroll_offset)
    ~surface_key:"keeper-list" ~rows:terminal_rows ~cols buf

(* A refusal is bad news about the key pressed; a pending write is a warning
   about what the screen shows, as is a list that may be stale
   ([Masc_tui_types.runtime_lane_stale_lines], drawn in warn). *)
let runtime_lane_notice_style = function
  | Masc_tui_types.Lane_write_refused _ -> Theme.bad ()
  | Masc_tui_types.Lane_write_pending -> Theme.warn ()
  | Masc_tui_types.Lane_write_committed receipt ->
    if Masc_tui_runtime_config_receipt.lane_needs_attention receipt then Theme.warn ()
    else Theme.info ()

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
  let answer = Tui_decode.standalone_lane_answer lane in
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
    Tui_decode.standalone_lane_configuration_phrase
      lane.sl_configuration_state
  in
  let last_run =
    match lane.sl_last_outcome, lane.sl_last_terminal_at with
    | None, _ -> "no retained terminal observation"
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
    | Tui_decode.Lane_off -> Theme.recede ()
    | Tui_decode.Lane_ready -> Ansi.reset
    | Tui_decode.Lane_slotless | Tui_decode.Lane_unconfigured -> Theme.warn ()
    | Tui_decode.Lane_registry_unavailable -> Theme.bad ()
  in
  let jev_lines =
    match lane.sl_jev with
    | None -> []
    | Some Tui_decode.Jev_off -> wrap (Theme.recede ()) "JEV OFF"
    | Some Tui_decode.Jev_cli_only ->
      wrap (Theme.recede ()) "JEV unavailable: Board lane is CLI-only"
    | Some Tui_decode.Jev_lane_unavailable ->
      wrap (Theme.warn ()) "JEV unavailable: Board lane is not ready"
    | Some (Tui_decode.Jev_configured { destinations }) ->
      let named (destination : Tui_decode.standalone_lane_jev_destination) =
        Printf.sprintf "%s (%s)" destination.sljd_destination_uri destination.sljd_model
      in
      wrap Ansi.reset
        (Printf.sprintf
           "JEV CONFIGURED \xc2\xb7 %s"
           (Terminal_text.single_line (String.concat ", " (List.map named destinations))))
  in
  let activity =
    let status = Tui_decode.standalone_lane_status_to_string lane.sl_status in
    match lane.sl_status, lane.sl_last_started_at with
    | Tui_decode.Standalone_off, _ ->
        Printf.sprintf "Activity: off · %d accepted runs finishing" lane.sl_running_count
    | Tui_decode.Standalone_running, Some started ->
        Printf.sprintf "Activity: %d running · latest started %s ago"
          lane.sl_running_count (Masc_tui_answering.elapsed_text ~now started)
    | _ -> "Activity: " ^ status in
  let run_stats =
    let total = lane.sl_retained_run_count in
    if total > 0 then
      let rate =
        float_of_int lane.sl_succeeded_count /. float_of_int total *. 100.0
      in
      let p50_str =
        (* Use the shared elapsed-time formatting for this observation. *)
        match lane.sl_p50_elapsed_s with
        | Some s -> (
            match Message_layout.elapsed_text s with
            | Some text -> Printf.sprintf " · p50 latency %s" text
            | None -> "")
        | None -> ""
      in
      Printf.sprintf "Runs: %d retained (%d ok / %d fail / %d cancel) · %.1f%% success%s"
        total lane.sl_succeeded_count lane.sl_failed_count
        lane.sl_cancelled_count rate p50_str
    else "Runs: no runs retained yet"
  in
  let slot_distribution =
    (* Every finished run, by who answered it. The slot counts cover only
       runs that named a slot; the rest come from the server by why they
       named none. On Board Attention most of those are Vendor System One,
       which answers before any slot is bound (#37296), so a reader who saw
       only the slots would take its answers for missing records. *)
    let dist =
      match lane.sl_selected_slots with
      | [] -> []
      | scs ->
        [ String.concat ", "
            (List.map
               (fun (sc : Tui_decode.standalone_lane_slot_count) ->
                  Printf.sprintf "%s: %d"
                    (Terminal_text.single_line sc.slsc_slot_id) sc.slsc_count)
               scs) ]
    in
    match dist @ standalone_lane_runs_without_slot_parts lane with
    | [] -> []
    | parts ->
      wrap Ansi.reset
        ("Slot selection history: " ^ String.concat " \xc2\xb7 " parts)
  in
  wrap Ansi.bold
    (Printf.sprintf "%s · %s" (Terminal_text.single_line lane.sl_label)
       (Terminal_text.single_line purpose))
  @ wrap state_style
      (Printf.sprintf "%s lane · %s · %s" obligation
         configuration last_run)
  @ wrap Ansi.dim
      (Printf.sprintf "Config: [runtime.exact_output_lanes.%s]"
         (Standalone_lane.to_id lane.sl_lane))
  @ jev_lines
  @ wrap Ansi.reset activity
  @ wrap (if lane.sl_failed_count > 0 then Theme.warn () else Ansi.reset)
      run_stats
  @ slot_distribution
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
  (* The file's shape and the editor [e] opens are the same two sentences on
     every lane, so they cost four of this pane's rows to say what no lane
     answers. They are under [?] with the key that acts on them, the move the
     Keeper columns and the Memory ST words already made. What stays here is
     what this lane answers: the section it configures is on the Config row
     above, and the evidence line below says what its runs retain. *)
  @ wrap Ansi.reset answer.sla_output_meaning
  @ wrap Ansi.dim answer.sla_evidence

let rec take_rows remaining acc = function
  | _ when remaining <= 0 -> List.rev acc
  | [] -> List.rev acc
  | row :: rest -> take_rows (remaining - 1) (row :: acc) rest

(* Editing takes the pane while it is open. A long CLI tail otherwise sits
   below the lane matrix and can put the acting cursor outside the frame. *)
let render_exact_lane_provider_editor (state : state) editor =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let lane = Masc_tui_types.slot_editor_target_name editor.Masc_tui_types.se_target in
  let entries = Masc_tui_types.slot_editor_rows state in
  let count = List.length entries in
  let selected_index = Masc_tui_types.slot_editor_cursor_index state in
  (* j/k stop on slots, never on a group's title, so an empty group has no
     row to move into. Its title says where a slot comes from instead: [a]
     picks one, and the runtime's kind decides the group it joins. *)
  let group_rows kind title =
    let rows =
      entries
      |> List.mapi (fun index row -> index, row)
      |> List.filter (fun (_, row) -> row.Masc_tui_types.sr_kind = kind)
    in
    let heading =
      match rows with
      | [] -> Printf.sprintf "  %s (0) · a adds one" title
      | _ :: _ -> Printf.sprintf "  %s (%d)" title (List.length rows)
    in
    (None, heading)
    :: List.map (fun (index, row) -> Some index, row.Masc_tui_types.sr_slot) rows
  in
  let display_rows =
    group_rows Masc_tui_types.Catalog_slot "HTTP slots · tried first"
    @ group_rows Masc_tui_types.Official_client_slot
        "CLI slots · tried after every HTTP slot"
  in
  box_top buf cols;
  box_line buf cols (screen_title (" MASC / " ^ lane ^ " / Model order"));
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.info ())
    (Printf.sprintf "  %s · HTTP candidates first, then CLI candidates"
       (Terminal_text.single_line lane));
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
     box_lines_styled buf cols ~style:(Theme.warn ())
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
     box_lines_styled buf cols ~style:(runtime_lane_notice_style notice)
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true
          (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line -> box_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (match state.runtime_lane_write with
   | Masc_tui_types.Lane_write_posting ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Saving candidate order..."
   | Masc_tui_types.Lane_write_rereading _ ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Reading current candidate order..."
   | Masc_tui_types.Lane_write_idle -> ());
  (match Masc_tui_types.runtime_picker_projection
     ~page:(Masc_tui_types.runtime_exact_picker_page state ~terminal_rows ~cols) state with
   | Some picker ->
     let action = match picker.Masc_tui_types.rlp_pick with
       | Masc_tui_types.Pick_exact_lane_replacement _ -> "Replace selected candidate", "Enter replace"
       | _ -> "Add fallback candidate", "Enter add" in
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ fst action);
     box_line_styled buf cols ~style:(Theme.recede ())
       ("  " ^ picker.Masc_tui_types.rlp_summary);
     if picker.Masc_tui_types.rlp_choices = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         (Masc_tui_types.runtime_picker_empty_note picker)
     else
       picker.Masc_tui_types.rlp_choices
       |> List.iteri (fun offset choice ->
            match choice with
            | Masc_tui_types.Lane_choice _ -> ()
            | Masc_tui_types.Runtime_choice runtime ->
            let destination =
              match picker.rlp_pick, runtime.ro_exact_slot_group with
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_http_slots -> "HTTP replacement"
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_cli_slots -> "CLI replacement"
              | _, Tui_decode.Exact_http_slots -> "HTTP tail"
              | _, Tui_decode.Exact_cli_slots -> "CLI tail"
              | _, Tui_decode.Exact_output_unsupported -> "no output schema"
            in
            let line bracket note =
              Printf.sprintf "  %s [%s] %s%s"
                (if picker.Masc_tui_types.rlp_selected_row = Some offset
                 then ">" else " ")
                bracket
                (Masc_tui_types.runtime_model_picker_title runtime)
                note
            in
            (match
              Masc_tui_types.runtime_pick_availability
                picker.Masc_tui_types.rlp_pick runtime
            with
            | Masc_tui_types.Pick_refused refusal ->
              (* The bracket carries the refusal: a note after the model
                 is the first thing the frame cuts. *)
              box_line_styled buf cols ~style:(Theme.recede ())
                (line (Masc_tui_types.runtime_pick_refusal_tag refusal) "")
            | Masc_tui_types.Pick_available ->
              (if picker.rlp_selected_row = Some offset
               then box_line_selected buf cols
               else box_line buf cols)
                (line destination
                   (if List.mem runtime.ro_id picker.rlp_already
                    then "  (already declared)" else "")));
            let prefix = "      Quota scope " in
            let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
            let scope_width =
              max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
            box_line_styled buf cols ~style:(Theme.recede ())
              (prefix ^ Masc_tui_message_layout.fit_middle scope_width
                 (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix));
     (match picker.rlp_selected_row with
      | Some offset ->
        (match List.nth_opt picker.rlp_choices offset with
         | Some (Masc_tui_types.Runtime_choice runtime) ->
           box_line_styled buf cols ~style:(Theme.recede ())
             ("  " ^ Masc_tui_message_layout.fit_middle (max 1 (cols - 6))
                (Terminal_text.single_line ("Connection " ^ runtime.ro_provider_id ^ " · Selected " ^ runtime.ro_id)))
         | Some (Masc_tui_types.Lane_choice _) | None -> ())
      | None -> ());
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ Masc_tui_types.runtime_picker_keys (snd action) picker.rlp_filter)
   | None ->
     let catalog = match state.runtime_catalog_reading with
       | Runtime_catalog_read -> state.runtime_catalog
       | Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_failed _ -> [] in
     (match state.runtime_catalog_reading with
      | Runtime_catalog_read -> ()
      | Runtime_catalog_unread ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue unread · showing slot IDs"
      | Runtime_catalog_loading ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue loading · showing slot IDs"
      | Runtime_catalog_failed detail ->
          box_line_styled buf cols ~style:(Theme.warn ())
            ("  runtime catalogue read failed: " ^ Terminal_text.single_line detail ^ " · showing slot IDs"));
     (* Reserve a key line and the frame bottom; at least the selected row
        stays visible on a short terminal. The ordinal places the moving
        window in the complete declaration. *)
     let visible =
       let reserved = if entries <> [] && Option.is_none selected_index then 8 else 7 in
       max 1 (min (List.length display_rows) (rows - count_frame_lines buf - reserved))
     in
     let selected_display_index =
       display_rows
       |> List.find_mapi (fun display_index (index, _) ->
            if index <> None && index = selected_index
            then Some display_index
            else None)
       |> Option.value ~default:0
     in
     let first =
       min (max 0 (List.length display_rows - visible))
         (max 0 (selected_display_index - (visible / 2)))
     in
     if entries = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         "  no provider slots declared; a adds one"
     else
       display_rows
       |> List.iteri (fun display_index (index, label) ->
            if display_index >= first && display_index < first + visible then (
              match index with
              | None -> box_line_styled buf cols ~style:(Theme.info ()) label
              | Some index ->
              let row = List.nth entries index in
              let kind =
                match row.Masc_tui_types.sr_kind with
                | Masc_tui_types.Catalog_slot -> "HTTP"
                | Masc_tui_types.Official_client_slot -> "CLI"
                | Masc_tui_types.Media_route_slot -> "ROUTE"
              in
              let line =
                Printf.sprintf "  %s %d/%d  [%s] %s%s"
                  (if Some index = selected_index then ">" else " ")
                  (index + 1) count kind
                  (match List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
                     String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog with
                   | Some runtime -> Masc_tui_types.runtime_model_picker_title runtime
                   | None -> Terminal_text.single_line row.Masc_tui_types.sr_slot)
                  (if row.Masc_tui_types.sr_admitted then ""
                   else "  (not admitted)")
              in
              if Some index = selected_index
              then box_line_selected buf cols line
              else box_line buf cols line));
     if entries <> [] && Option.is_none (selected_index) then
       box_line_styled buf cols ~style:(Theme.warn ())
         "  no slot selected; j/k selects a current slot";
     (match Masc_tui_types.slot_editor_cursor_row state with
      | None -> ()
      | Some row ->
        let selected_runtime = List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
           String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog in
        let identity = Terminal_text.single_line
          ((match selected_runtime with
            | Some runtime -> "Connection " ^ runtime.ro_provider_id ^ " · "
            | None -> "") ^ "Selected " ^ row.sr_slot) in
        (match selected_runtime with
         | Some runtime ->
           let prefix = "  Quota scope " in
           let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
           let scope_width =
             max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
           box_line_styled buf cols ~style:(Theme.info ())
             (prefix ^ Masc_tui_message_layout.fit_middle scope_width
                (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix)
         | None -> box_line_styled buf cols ~style:(Theme.warn ()) "  Model details unavailable");
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Masc_tui_message_layout.fit_middle (max 1 (cols - 6)) identity));
     box_line_styled buf cols ~style:(Theme.recede ())
       "  arrows/j/k select · r replace model/effort · a add fallback · 1 first in group";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  J/K reorder · x remove · Enter/d settings · e TOML · Esc back";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  Changes save immediately; file and application results are shown separately");
  for _ = 1 to max 0 (rows - count_frame_lines buf - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

let render_lanes_overview (state : state) =
  match state.slot_editor with
  | Some ({ Masc_tui_types.se_target = Masc_tui_types.Exact_lane_slots _; _ } as editor) ->
    render_exact_lane_provider_editor state editor
  | None | Some { Masc_tui_types.se_target = Masc_tui_types.Media_failover_slots; _ } ->
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
    (* Both readings come from [runtime_surface], which the Runtime screen
       loads and this one does not, so on a first visit here they were zeros
       nobody measured. *)
    let lane_reading =
      Option.map
        (fun snapshot ->
          string_of_int (List.length snapshot.rss_resolved.rrs_lanes))
        state.runtime_surface
    in
    let all_reading =
      Option.map
        (fun snapshot ->
          string_of_int (List.length snapshot.rss_resolved.rrs_runtimes))
        state.runtime_surface
    in
    let lane_count = lanes_inventory_count state in
    match state.lane_inventory with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Lanes") (title_missing_reading ~error:state.standalone_lanes_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Lanes")
          (tab_strip
             ~width:
               (tab_strip_width ~cols
                  ~before:(screen_title " MASC Lanes" ^ tab_strip_gap)
                  ~after:("  " ^ timestamp ^ "  " ^ connection_badge state))
             ~press:pressable
             [ ( tab_entry_label "Candidate orders" lane_reading
               , false
               , Press_runtime_mode Masc_tui_types.Runtime_lanes )
             ; ( tab_entry_label "All runtimes" all_reading
               , false
               , Press_runtime_mode Masc_tui_types.Runtime_all )
             ; ( tab_entry_label "Lanes"
                   (Some
                      (Masc_tui_message_layout.count_noun lane_count "lane"))
               , true
               , Press_standalone_lanes )
             ])
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let observed_heading = match state.lane_inventory with
    | None -> "  All lanes"
    | Some snapshot ->
        let observed = Unix.localtime snapshot.Masc.Tui_decode_lane_inventory.observed_at in
        Printf.sprintf "  All lanes · observed %02d:%02d:%02d"
          observed.Unix.tm_hour observed.Unix.tm_min observed.Unix.tm_sec in
  box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) observed_heading;
  List.iter (fun notice -> box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ notice))
    (Masc_tui_types.lane_inventory_notice_lines ~cols state);
  let inventory = lane_inventory_rows state in
  let layout = Masc_tui_types.lanes_scrolled ~cols state in
  let height = Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row in
  let scroll = Masc_tui_scroll.normalize ~count:layout.sc_count ~height state.lanes_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor:state.lanes_cursor ~height in
  let summary row = Terminal_text.single_line (match state.lane_inventory with
    | Some snapshot -> Masc_tui_lane_inventory.row_summary_in snapshot row
    | None -> Masc_tui_lane_inventory.row_summary row) in
  let status_width = List.fold_left (fun width row -> max width
      (Message_layout.display_width (summary row))) (String.length "STATE") inventory
    |> min (max 1 (inner / 2)) in
  let label_width = max 1 (inner - status_width - 2) in
  box_line_styled buf cols ~style:(Theme.recede ())
    (fit_width "LANE" label_width ^ "  " ^ fit_width "STATE" status_width);
  let window = Rows.of_list ~first:scroll ~height inventory in
  for offset = 0 to height - 1 do
    let index = scroll + offset in
    match Rows.at window index with
    | None when offset = 0 && Option.is_none state.lane_inventory ->
        box_line_styled buf cols ~style:(Theme.recede ())
          (if Option.is_some state.standalone_lanes_error then "  r: retry inventory"
           else "  reading all lanes…")
    | None -> box_empty buf cols
    | Some row ->
        let label = Masc_tui_lane_inventory.family_label row.selection ^ " · " ^ row.label
          |> Terminal_text.single_line in
        let text = fit_width label label_width ^ "  " ^ fit_width (summary row) status_width in
        (* The final frame owns click geometry, including narrow terminals and
           scrolling. A retained mark names an identity, never a former index. *)
        let marked = pressable (Press_lane_row row.id) (fit_width text inner) in
        if index = state.lanes_cursor then box_line_selected buf cols marked
        else box_line buf cols marked
  done;
  (match Masc_tui_scroll.position_row ~scroll ~height (List.length inventory) with
   | None -> ()
   | Some text -> box_line_styled buf cols ~style:(Theme.recede ()) text);
  (* The selected row gets the remaining preview space; the list scrolls
     independently and Enter opens the full existing management surface. *)
  (match selected_inventory_lane state with
   | None -> ()
   | Some inventory_row ->
       let action_error_rows =
         (match state.lanes_action_error with
          | None -> 0
          | Some detail ->
              box_lines_row_count ~cols
                (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail))
         + (match state.runtime_lane_notice with
            | None -> 0
            | Some notice ->
                box_lines_row_count ~cols
                  (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                     (Masc_tui_types.runtime_lane_notice_text notice)))
         + List.length (Masc_tui_types.runtime_lane_stale_lines state)
       in
       let picker_rows =
         match Masc_tui_types.runtime_picker_projection state with
         | None -> 0
         | Some picker -> 1 + max 1 (2 * List.length picker.rlp_choices)
       in
       let available =
         max 0
           (rows - count_frame_lines buf - action_error_rows - picker_rows - 3)
       in
       if available > 0 then begin
         box_divider buf cols;
         let detail = match selected_standalone_lane state with
           | Some lane ->
               (Theme.info (), "  Space: activity · s: models · a: candidate")
               :: standalone_lane_detail_lines ~now:(Unix.gettimeofday ()) ~width:inner lane
           | None ->
               ((match inventory_row.Masc.Tui_decode_lane_inventory.selection with
                 | Browser _ -> ["Space: activity · Enter: browser"]
                 | Machine _ -> ["Space: activity · Enter: spectate"]
                 | Exact _ | Declaration _ | Manual_instance _ -> [])
                @ Masc_tui_lane_inventory.detail_lines inventory_row)
               |> List.concat_map (fun line ->
                    Terminal_text.single_line line
                    |> Message_layout.wrap_words ~max_cells:(max 1 (inner - 2))
                    |> List.map (fun line -> Theme.recede (), "  " ^ line))
         in
         let shown = take_rows available [] detail in
         let shown =
           if List.length detail <= available then shown
           else
             match List.rev shown with
             | [] -> []
             | _ :: rest ->
               List.rev ((Theme.warn (), "  … d: full reading") :: rest)
         in
         List.iter
           (fun (style, line) -> box_line_styled buf cols ~style line)
           shown
       end);
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
       box_lines_styled buf cols ~style:(Theme.warn ())
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (* The lane editor's notice is the Runtime view's too: a standalone lane's
     slots are written from here, and a write started on either view can
     still be out when the other is opened. *)
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
       (* The refusal can be the server's own multi-line sentence, which wraps
          to more rows than the frame has left. Bound it to what remains after
          the picker and the footer, keeping the "lane write refused" head and
          the actionable tail. *)
       let picker_rows =
         match Masc_tui_types.runtime_picker_projection state with
         | None -> 0
         | Some picker -> 1 + max 1 (2 * List.length picker.rlp_choices)
       in
       let budget = max 1 (rows - count_frame_lines buf - picker_rows - 4) in
       box_lines_styled_bounded buf cols ~style:(runtime_lane_notice_style notice) ~budget
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                   (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line ->
       box_line_styled buf cols ~style:(Theme.warn ())
         ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (* The runtime-candidate picker the "a" key opens. Same projection the
     Runtime surface draws; the row order both render and the key handler
     read is the picker's own, so the cursor and the drawing cannot drift. *)
  (match Masc_tui_types.runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       box_line_styled buf cols ~style:(Theme.info ())
         (Printf.sprintf
            "  adding a candidate to the candidate order of %s — %s — %s"
            (Terminal_text.single_line picker.Masc_tui_types.rlp_lane)
            picker.Masc_tui_types.rlp_summary
            (Masc_tui_types.runtime_picker_keys "Enter append"
               picker.Masc_tui_types.rlp_filter));
       if picker.Masc_tui_types.rlp_choices = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           (Masc_tui_types.runtime_picker_empty_note picker)
       else
         List.iteri
           (fun offset choice ->
              match choice with
              | Masc_tui_types.Lane_choice _ -> ()
              | Masc_tui_types.Runtime_choice runtime ->
              (* A refusal leads the row, as in the provider editor: a note
                 after the label is the first thing the frame cuts. *)
              let refusal_prefix, note =
                match
                  Masc_tui_types.runtime_pick_availability
                    picker.Masc_tui_types.rlp_pick runtime
                with
                | Masc_tui_types.Pick_refused refusal ->
                  ( Ansi.dim ^ "[" ^ Masc_tui_types.runtime_pick_refusal_tag refusal
                    ^ "] " ^ Ansi.reset
                  , "" )
                | Masc_tui_types.Pick_available ->
                  ( ""
                  , if List.exists (String.equal runtime.ro_id) picker.rlp_already
                    then "  (already a slot)"
                    else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                    then "  (same provider as a current slot)"
                    else "" )
              in
              let mark =
                if picker.Masc_tui_types.rlp_selected_row = Some offset then ">" else " "
              in
              let ctx =
                Printf.sprintf " [%s context]"
                  (format_context_tokens runtime.ro_effective_max_context)
              in
              let def = if runtime.ro_is_default then " [default]" else "" in
              box_line buf cols
                (Printf.sprintf "  %s %s%s%s%s%s"
                   mark refusal_prefix
                   (Masc_tui_types.runtime_model_picker_title runtime)
                   ctx def
                   (Ansi.dim ^ note ^ Ansi.reset));
              box_line_styled buf cols ~style:(Theme.recede ())
                ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                  ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                  ^ " · " ^ Terminal_text.single_line runtime.ro_id))
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
  | Tui_decode.Lane_run_running -> Theme.info ()
  | Tui_decode.Lane_run_other _ -> Theme.muted ()

let lane_run_clock started_at =
  let tm = Unix.localtime started_at in
  Printf.sprintf "%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let standalone_lane_label (state : state) (target : Standalone_lane.t) =
  match state.standalone_lanes with
  | None -> Standalone_lane.to_id target
  | Some snapshot ->
      (match
         List.find_opt
           (fun (lane : Tui_decode.standalone_lane) ->
             Standalone_lane.equal lane.sl_lane target)
           snapshot.Tui_decode.sls_lanes
       with
       | Some lane -> lane.sl_label
       | None -> Standalone_lane.to_id target)

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
let render_lane_run_list (state : state) ~(lane : Standalone_lane.t) =
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
         (Terminal_text.single_line (standalone_lane_label state lane))
         20)
      coverage (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let identity_heading =
    match lane with
    | Standalone_lane.Verifier -> "SUBJECT"
    | Standalone_lane.Librarian
    | Standalone_lane.Hitl_auto_judge
    | Standalone_lane.Board_attention
    | Standalone_lane.Workspace_curator
    | Standalone_lane.Candle_appraiser
    | Standalone_lane.Browser_stagehand -> "ACTOR"
  in
  (* The slot takes what the drawn columns leave. *)
  let run_layout =
    Render_schedule.lane_run_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  "
    ^ Render_schedule.lane_run_header_row ~identity_header:identity_heading
        ~layout:run_layout);
  box_divider buf cols;
  (match state.lane_runs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let layout = lanes_scrolled state ~cols in
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
            | None -> Masc_tui_theme.Glyph.no_value
            | Some seconds -> (
                match Message_layout.elapsed_text seconds with
                | Some text -> text
                | None -> Masc_tui_theme.Glyph.no_value)
          in
          let line =
            "  "
            ^ Render_schedule.lane_run_row ~identity_header:identity_heading
                ~status_style:(lane_run_status_style run.lrs_status)
                ~layout:run_layout
                { Render_schedule.lrow_started =
                    lane_run_clock run.lrs_started_at
                ; lrow_subject =
                    Terminal_text.single_line (lane_run_subject run)
                ; lrow_status =
                    Tui_decode.lane_run_status_label run.lrs_status
                ; lrow_elapsed = elapsed
                ; lrow_slot =
                    Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                      run.lrs_selected_slot
                }
          in
          if index + scroll = state.lane_runs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[runs %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_lanes_run_list);
  finish_surface state ~surface_key:"lane-runs" ~rows:terminal_rows ~cols buf

(* The total preview includes labels, fences and notices. Complete payloads
   that fit stay complete; oversized fields share the space left after each
   field's minimum preview. If even those minima do not fit, preserve the
   original prefix and name the omitted suffix count. Stored bytes do not change. *)
let lane_run_preview_source_max_bytes = 65536

type lane_run_prepared_document =
  { full_text : string
  ; document : string
  ; notice : string
  }

type lane_run_prepared_field =
  { index : int
  ; heading : string
  ; heading_bytes : int
  ; prepared : lane_run_prepared_document
  ; minimum_bytes : int
  ; full_bytes : int
  }

let lane_run_payload_lines ~width json =
  let fence = fenced_document_text ~language:"json" in
  let prepare_document value =
    let full_text = Yojson.Safe.pretty_to_string value in
    let document = fence full_text in
    let notice = Printf.sprintf "… truncated, total %d bytes" (String.length full_text) in
    { full_text; document; notice }
  in
  let minimum_document_bytes prepared =
    min (String.length prepared.document)
      (String.length prepared.document - String.length prepared.full_text
       + String.length prepared.notice + 1)
  in
  (* Field allocation reserves the minimum above; non-object payloads receive
     the full preview budget. Both callers therefore leave a non-negative room. *)
  let render_document ~budget prepared =
    let document, notices =
      if String.length prepared.document <= budget then prepared.document, []
      else
        let wrapper_bytes = String.length prepared.document - String.length prepared.full_text in
        let room = budget - wrapper_bytes - String.length prepared.notice - 1 in
        let cut =
          match String.rindex_from_opt prepared.full_text room '\n' with
          | Some newline -> newline
          | None -> String_util.utf8_char_boundary prepared.full_text room
        in
        fence (String.sub prepared.full_text 0 cut), [ Theme.warn (), prepared.notice ]
    in
    let lines =
      document_markdown ~width document
      |> List.map (fun line -> Ansi.reset, line)
    in
    lines @ notices
  in
  match json with
  | `Assoc (_ :: _ as fields) ->
    let omitted count = Printf.sprintf "… %d more field(s) not rendered" count in
    let fields =
      List.mapi
        (fun index (name, value) ->
          let heading = Yojson.Safe.to_string (`String name) |> Terminal_text.single_line in
          let heading_bytes = String.length heading + 1 in
          let prepared = prepare_document value in
          { index; heading; heading_bytes; prepared
          ; minimum_bytes = heading_bytes + minimum_document_bytes prepared
          ; full_bytes = heading_bytes + String.length prepared.document })
        fields
    in
    let render_field budget field =
      (Ansi.bold, field.heading)
      :: render_document ~budget:(budget - field.heading_bytes) field.prepared
    in
    let total = List.fold_left (fun n field -> n + field.full_bytes) 0 fields in
    if total <= lane_run_preview_source_max_bytes then
      List.concat_map (fun field -> render_field field.full_bytes field) fields
    else begin
      let minimum_total fields =
        List.fold_left (fun n field -> n + field.minimum_bytes) 0 fields
      in
      let notice_bytes = function None -> 0 | Some text -> String.length text + 1 in
      let fields, suffix_notice =
        if minimum_total fields <= lane_run_preview_source_max_bytes then fields, None
        else
          let rec prefix used remaining notice acc = function
            | [] -> List.rev acc, None
            | field :: rest ->
              let next_notice =
                if List.is_empty rest then None else Some (omitted (remaining - 1))
              in
              if used + field.minimum_bytes + notice_bytes next_notice <= lane_run_preview_source_max_bytes then
                prefix (used + field.minimum_bytes) (remaining - 1) next_notice (field :: acc) rest
              else List.rev acc, notice
          in
          let count = List.length fields in
          prefix 0 count (Some (omitted count)) [] fields
      in
      let needed field = field.full_bytes - field.minimum_bytes in
      let ranked = List.stable_sort (fun a b -> Int.compare (needed a) (needed b)) fields in
      let rec allocate extra remaining = function
        | [] -> []
        | field :: rest ->
          let added = min (needed field) (extra / remaining) in
          (field, field.minimum_bytes + added) :: allocate (extra - added) (remaining - 1) rest
      in
      let extra = lane_run_preview_source_max_bytes - notice_bytes suffix_notice - minimum_total fields in
      let allocated =
        allocate extra (List.length fields) ranked
        |> List.sort (fun (a, _) (b, _) -> Int.compare a.index b.index)
      in
      let lines = List.concat_map (fun (field, budget) -> render_field budget field) allocated in
      match suffix_notice with None -> lines | Some text -> lines @ [ Theme.warn (), text ]
    end
  | _ ->
    render_document ~budget:lane_run_preview_source_max_bytes (prepare_document json)

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
    "SKILLS  none · these runs do not load Keeper Skill instructions"
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
    | Some seconds -> (
        match Message_layout.elapsed_text seconds with
        | Some text -> Printf.sprintf "  ·  %s" text
        | None -> "")
  in
  let slot =
    match detail.lrd_answer_source, detail.lrd_selected_slot with
    | Some _, _ | None, None -> ""
    | None, Some slot -> "  ·  SLOT " ^ Terminal_text.single_line slot
  in
  let answer_source =
    match detail.lrd_answer_source with
    | None -> []
    | Some (Tui_decode.Lane_run_answer_exact_attempt slot) ->
      [ Ansi.reset, "  ANSWER  EXACT · " ^ Terminal_text.single_line slot ]
    | Some (Tui_decode.Lane_run_answer_cli_slot slot) ->
      [ Ansi.reset, "  ANSWER  CLI · " ^ Terminal_text.single_line slot ]
    | Some (Tui_decode.Lane_run_answer_vendor_system_one { model; endpoint = _ }) ->
      [ ( Ansi.reset
        , "  ANSWER  VENDOR SYSTEM ONE · "
          ^ Terminal_text.single_line model
          ^ " · NO EXACT-FLOW RECEIPT" ) ]
  in
  let failure =
    match detail.lrd_failure with
    | None -> []
    | Some failure ->
      [ ( Theme.bad ()
        , Printf.sprintf
            "  CODE  %s  ·  %s"
            (Terminal_text.single_line failure.lrf_code)
            (Terminal_text.single_line failure.lrf_detail) ) ]
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
        (Standalone_lane.to_id detail.lrd_lane)
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
  @ failure
  @ answer_source
  @ gate_judgment
  @ [ tool_style, "  " ^ tools; skill_style, "  " ^ skills ]

let lane_run_panel_titles (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_run_kind, detail.lrd_tool_evidence with
  | Tui_decode.Lane_run_exact_output, _ ->
    "INPUT · RUN INPUT", "OUTPUT · RUN RESULT"
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

let lane_run_output_lines ~details ~width (detail : Tui_decode.lane_run_detail) =
  let preflight_lines = match detail.lrd_librarian_preflight with
    | None -> []
    | Some reading ->
      let decision = match reading.lp_status with
        | Tui_decode.Preflight_awaiting -> "응답 대기"
        | Tui_decode.Preflight_not_called reason -> "호출하지 않음 · " ^ reason
        | Tui_decode.Preflight_failed reason -> if details then "호출 실패 · " ^ reason else "호출 실패"
        | Tui_decode.Preflight_invalid reason -> "답변 거절 · " ^ reason
        | Tui_decode.Preflight_judged judgment ->
          Masc.Typesafeai_librarian_preflight.decision_label judgment.choice in
      let path = match reading.lp_generation_path with
        | Tui_decode.Generation_not_entered -> "생성 Lane 진입 전"
        | Tui_decode.Generation_full_lane -> "생성 Lane 진입 · 실제 요청 수는 별도 기록"
        | Tui_decode.Generation_jev_no_change -> "생성 호출 생략 · 빈 변경 검증 통과" in
      let probabilities = match reading.lp_status with
        | Tui_decode.Preflight_judged judgment ->
          [Printf.sprintf "Confidence %.3f" judgment.confidence]
          @ List.map (fun (decision, probability) ->
              Printf.sprintf "%s %.3f" (Masc.Typesafeai_librarian_preflight.decision_label decision) probability)
              judgment.probabilities
        | _ -> [] in
      let elapsed = match reading.lp_elapsed_s with
        | None -> [] | Some seconds -> [Printf.sprintf "JEV elapsed %.3fs" seconds] in
      let model = match reading.lp_model with None -> [] | Some model -> ["Model " ^ model] in
      let rejection = match reading.lp_domain_rejection with
        | None -> [] | Some reason -> ["검증 거절 → 생성 Lane · " ^ reason] in
      let memory = match reading.lp_memory_result with
        | None -> "기억 snapshot: 적용 결과가 기록되지 않음"
        | Some (Tui_decode.Librarian_memory_unchanged (revision, facts)) ->
          Printf.sprintf "기억 snapshot: 변경 없음 · revision %d · %d facts" revision facts
        | Some (Tui_decode.Librarian_memory_rewritten {revision;facts;added;removed}) ->
          Printf.sprintf "기억 snapshot: +%d / -%d · revision %d · %d facts" added removed revision facts in
      let side_writes = List.map (fun (kind, status) ->
        let label = match kind with
          | Tui_decode.Context_write -> "Context"
          | Tui_decode.Continuity_write -> "Continuity" in
        let outcome = match status with
          | Tui_decode.Side_not_attempted -> "not attempted"
          | Tui_decode.Side_answer_missing -> "answer missing"
          | Tui_decode.Side_withheld -> "withheld"
          | Tui_decode.Side_outcome_unconfirmed -> "outcome unconfirmed"
          | Tui_decode.Side_committed -> "committed"
          | Tui_decode.Side_answer_refused detail -> "answer refused · " ^ detail
          | Tui_decode.Side_failed detail -> "failed · " ^ detail in
        label ^ ": " ^ outcome) reading.lp_side_writes in
      let document = String.concat "\n"
        ([path; memory] @ side_writes @ ["JEV 판정 · " ^ decision] @ rejection
      @ (if details then model @ elapsed @ probabilities @ [""; "원문 실행 증거"]
         else ["d: 모델·확률·원문 펼치기"])) in
      let document =
        if String.length document <= lane_run_preview_source_max_bytes then document
        else
          let notice = Printf.sprintf "\n… truncated preflight, total %d bytes" (String.length document) in
          let room = lane_run_preview_source_max_bytes - String.length notice in
          let cut = String_util.utf8_char_boundary document room in
          String.sub document 0 cut ^ notice in
      String.split_on_char '\n' document
      |> List.concat_map (fun text ->
          Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
          |> List.map (fun line -> Theme.info (), line))
  in
  let fold_memory_evidence = match detail.lrd_librarian_preflight with
    | Some {lp_context_only=false;_} -> true
    | _ -> false in
  preflight_lines @ (if not details && fold_memory_evidence then [] else
  match detail.lrd_output_availability, detail.lrd_output with
  | None, _ -> [ Theme.muted (), "실행 중 · 아직 출력이 기록되지 않았습니다" ]
  | Some availability, output ->
    lane_run_payload_availability_lines ~width availability output)

module Continuity_report = Masc.Librarian_continuity_report

type run_inspection =
  | Inspection_lane of Tui_decode.lane_run_detail
  | Inspection_measurement of string * Measurement.t

let measurement_summary_lines (report : Continuity_report.t) =
  let counts = Measurement.counts report in
  let provenance = match report.provenance with
    | Continuity_report.Synthetic -> "SYNTHETIC INPUT" in
  [ Ansi.reset, "  MEANING PRESERVATION  " ^ Terminal_text.single_line report.run_id
  ; Ansi.dim, "  " ^ provenance ^ "  ·  " ^ Terminal_text.single_line report.started_at
  ; Ansi.reset,
    Printf.sprintf "  SAMPLES  %d  ·  SCORED %d  ·  FAILED %d  ·  INCOMPLETE %d"
      (List.length report.samples) counts.scored counts.failed counts.incomplete
  ]

let measurement_text_lines ~width lines =
  List.concat_map
    (fun (style, text) ->
      String.split_on_char '\n' text
      |> List.concat_map (fun line ->
        Message_layout.wrap_words ~max_cells:(max 1 width)
          (Terminal_text.single_line line)
        |> List.map (fun line -> style, line)))
    lines

let measurement_input_lines ~width ~sha256 (measurement : Measurement.t) =
  let report = measurement.report in
  let module R = Continuity_report in
  let metadata =
    [ "AUTHORITATIVE FILE  " ^ report.output_path
    ; "BLOB SHA256  " ^ sha256
    ; "Published blob is a copy; it may be collected."
    ; "INPUT  " ^ report.input_path
    ; "INPUT SHA256  " ^ report.input_sha256
    ; "CONFIG REVISION  " ^ report.config_revision
    ]
    @ (match report.binary_commit with None -> [] | Some value -> [ "BINARY COMMIT  " ^ value ])
    @ (match report.executable_sha256 with None -> [] | Some value -> [ "EXECUTABLE SHA256  " ^ value ])
    @ List.map (fun (id, sha256) ->
        "CONTEXT SHA256  " ^ id ^ "  " ^ sha256) measurement.context_hashes
  in
  measurement_text_lines ~width (List.map (fun text -> Ansi.dim, text) metadata)
  @ lane_run_payload_lines ~width
      (`List (List.map (fun (sample : R.sample) -> R.case_to_yojson sample.case) report.samples))

(* Apply the same byte ceiling as exact lane payloads before wrapping. The
   report and its full score distribution remain intact; only text is a preview. *)
let measurement_output_preview ~width ~output_path lines =
  let rec take remaining reversed = function
    | [] -> List.rev reversed, false
    | (style, text) :: rest ->
      let bytes = String.length text + 1 in
      if bytes <= remaining then take (remaining - bytes) ((style, text) :: reversed) rest
      else
        let prefix = String_util.utf8_prefix ~max_bytes:(max 0 remaining) text in
        List.rev ((style, prefix) :: reversed), true
  in
  let preview, truncated = take lane_run_preview_source_max_bytes [] lines in
  let notice =
    if truncated then
      [ Theme.warn (), Printf.sprintf
          "PREVIEW · output truncated at %d bytes; full report: %s"
          lane_run_preview_source_max_bytes output_path ]
    else []
  in
  measurement_text_lines ~width (notice @ preview)

let measurement_output_lines ~width (report : Continuity_report.t) =
  let module R = Continuity_report in
  let prepared (request : R.generation_request) =
    List.concat_map
      (fun (wire : Llm_provider.Request_wire_observer.observation) ->
        [ "PREPARED REQUEST  " ^ wire.provider ^ "  ·  " ^ wire.model
        ; "PRE-DISPATCH SHA256  " ^ wire.body_sha256 ])
      request.prepared_requests
  in
  let generation label (value : R.generation) =
    [ label ^ "  " ^ value.response.model ^ "  ·  runtime " ^ value.request.runtime_id
    ; "RESPONSE  " ^ value.response.response_id
    ; value.response.text
    ] @ prepared value.request
  in
  let question_lines = function
    | R.Provided text -> [ "QUESTION PROVIDED"; text ]
    | R.Generated value -> generation "QUESTION GENERATED" value
  in
  (* The sample header names the failed stage. Retain the stage when the
     header scrolls away, without repeating the FAILED status. *)
  let failed_generation label (value : R.failed_generation) =
    [ label ^ " CAUSE  " ^ value.error
    ; "REQUESTED  " ^ value.request.requested_model ^ "  ·  runtime " ^ value.request.runtime_id
    ] @ prepared value.request
    @ (match value.incomplete_response with
       | None -> []
       | Some response -> [ "INCOMPLETE RESPONSE  " ^ response.model ^ "  ·  " ^ response.response_id; response.text ])
  in
  let values =
    List.filter_map (fun (sample : R.sample) -> match sample.progress with
      | R.Scored { judgment; _ } -> Some (judgment.probability, sample.case.id)
      | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _
      | R.Answer_ready _ | R.Judge_failed _ -> None) report.samples
    |> List.sort (fun (a, id_a) (b, id_b) ->
        let order = Float.compare a b in if order = 0 then String.compare id_a id_b else order)
  in
  let probabilities =
    (Ansi.bold, "RAW PROBABILITIES · NO PASS THRESHOLD")
    :: (match values with
        | [] -> [ Theme.muted (), "No scored samples" ]
        | values -> List.map (fun (probability, id) ->
            Ansi.reset, id ^ "  " ^ Yojson.Safe.to_string (`Float probability)) values)
  in
  let samples = List.concat_map (fun (sample : R.sample) ->
      let style, status, lines = match sample.progress with
        | R.Not_started -> Theme.muted (), "NOT STARTED", []
        | R.Question_failed failed -> Theme.bad (), "QUESTION FAILED", failed_generation "QUESTION" failed
        | R.Question_ready question -> Theme.info (), "INCOMPLETE · QUESTION READY", question_lines question
        | R.Answer_failed (question, failed) -> Theme.bad (), "ANSWER FAILED",
            question_lines question @ failed_generation "ANSWER" failed
        | R.Answer_ready { question; answer } -> Theme.info (), "INCOMPLETE · ANSWER READY",
            question_lines question @ generation "ANSWER" answer
        | R.Judge_failed { question; answer; failure } -> Theme.bad (), "JUDGE FAILED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE REQUESTED  " ^ failure.request.model ^ "  ·  " ^ failure.request.endpoint
              ; "JUDGE CAUSE  " ^ failure.error ]
        | R.Scored { question; answer; judgment } -> Ansi.reset, "SCORED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE  " ^ judgment.response_model ^ "  ·  " ^ judgment.request.endpoint
              ; "Noul  " ^ Yojson.Safe.to_string (`Float judgment.probability)
              ; "TRUE  " ^ judgment.request.true_criteria
              ; "FALSE  " ^ judgment.request.false_criteria
              ; "REQUEST SHA256  " ^ judgment.request_body_sha256 ]
      in
      [ Ansi.dim, ""; style, sample.case.id ^ "  ·  " ^ status ]
      @ List.map (fun line -> Ansi.reset, line) lines) report.samples
  in
  measurement_output_preview ~width ~output_path:report.output_path (probabilities @ samples)

let inspection_summary_lines = function
  | Inspection_lane detail -> lane_run_summary_lines detail
  | Inspection_measurement (_, measurement) -> measurement_summary_lines measurement.report

let inspection_panel_titles = function
  | Inspection_lane detail -> lane_run_panel_titles detail
  | Inspection_measurement (_, measurement) ->
    (match measurement.report.provenance with
     | Continuity_report.Synthetic -> "INPUT · SYNTHETIC CASES"),
    "OBSERVATIONS · NO VERDICT"

let inspection_input_lines ~width = function
  | Inspection_lane detail -> lane_run_input_lines ~width detail
  | Inspection_measurement (sha256, report) -> measurement_input_lines ~width ~sha256 report

let inspection_output_lines ~details ~width = function
  | Inspection_lane detail -> lane_run_output_lines ~details ~width detail
  | Inspection_measurement (_, measurement) -> measurement_output_lines ~width measurement.report

let lane_run_stacked_lines ~details ~width detail =
  let input_title, output_title = inspection_panel_titles detail in
  let indent lines = List.map (fun (style, line) -> style, "  " ^ line) lines in
  [ Ansi.bold, "  " ^ input_title ]
  @ indent (inspection_input_lines ~width detail)
  @ [ Ansi.dim, ""; Ansi.bold, "  " ^ output_title ]
  @ indent (inspection_output_lines ~details ~width detail)

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

(* Top, header, its divider, bottom and footer. A loaded run also draws
   the divider beneath its summary. Split panes use one payload row for titles. *)
let lane_run_chrome_rows_without_summary = framed_chrome_rows
let lane_run_chrome_rows = lane_run_chrome_rows_without_summary + 1

let render_lane_run_detail (state : state) ~run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let measurement = match state.lanes_mode with
    | Lanes_measurement_detail _ -> true
    | Lanes_overview | Lanes_run_list _ | Lanes_run_detail _ | Lanes_inventory_detail _ -> false in
  let detail =
    if measurement then Option.map (fun report -> Inspection_measurement (run_id, report)) state.measurement_report
    else match state.lane_run_detail with
    | Some detail when String.equal detail.Tui_decode.lrd_run_id run_id ->
        Some (Inspection_lane detail)
    | Some _ | None -> None
  in
  let header =
    detail_heading ~cols
      ~lead:
        (Lead_text
           (screen_title
              (if measurement then measurement_detail_title
               else lane_run_detail_title)
           ^ "  "))
      ~id:run_id ~after:"" ~tail:(connection_badge state)
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
  let chrome_rows_for_error =
    match detail, state.lane_run_detail_error with
    | Some _, Some _ -> 1
    | None, Some _ -> 2
    | (Some _ | None), None -> 0
  in
  (* The position the footer carries: [None] where the drawing already says
     it -- nothing to read yet, or two panes whose titles each name their
     own window. *)
  let scroll, position, content_height =
    match detail, state.lane_run_detail_error with
    | None, error ->
      let filler_rows = max 1 (rows - lane_run_chrome_rows_without_summary - chrome_rows_for_error) in
      let line =
        match error with
        | None -> Ansi.dim, (if measurement then "  (loading measurement artifact)" else "  (loading exact run record)")
        | Some _ -> Ansi.dim, page_failed_note
      in
      box_line_styled buf cols ~style:(fst line) (snd line);
      for _ = 2 to filler_rows do
        box_empty buf cols
      done;
      0, None, 0
    | Some detail, (Some _ | None) ->
      let summary = inspection_summary_lines detail in
      let compact_preflight = match detail with
        | Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_} -> not state.lane_run_preflight_details
        | _ -> false in
      let split = cols >= keeper_split_threshold_cols && not compact_preflight in
      let payload_rows =
        max 0
          (rows - List.length summary - lane_run_chrome_rows - chrome_rows_for_error)
      in
      let title_rows = if split then 1 else 0 in
      let content_height = max 0 (payload_rows - title_rows) in
      List.iter
        (fun (style, line) -> box_line_styled buf cols ~style line)
        summary;
      box_divider buf cols;
      if split then begin
        let inner = framed_inner_width cols in
        let divider_width = 3 in
        let left_width = max 1 ((inner - divider_width) / 2) in
        let right_width = max 1 (inner - left_width - divider_width) in
        let input_lines =
          inspection_input_lines ~width:left_width detail
        in
        let output_lines = inspection_output_lines ~details:state.lane_run_preflight_details ~width:right_width detail in
        if payload_rows = 0
        then 0, None, content_height
        else begin
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
          let input_title, output_title = inspection_panel_titles detail in
          lane_run_split_line buf cols ~left_width
            ~left:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" input_title
                  (Masc_tui_scroll.window_text ~scroll:input_scroll
                     ~height:content_height (List.length input_lines)) )
            ~right:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" output_title
                  (Masc_tui_scroll.window_text ~scroll:output_scroll
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
          scroll, None, content_height
        end
      end
      else begin
        let lines =
          if compact_preflight then
            inspection_output_lines ~details:false ~width:(max 1 (cols - 8)) detail
          else lane_run_stacked_lines ~details:state.lane_run_preflight_details ~width:(max 1 (cols - 8)) detail
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
        scroll,
        Some (Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines)),
        content_height
      end
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ?position ~hints:(Masc_tui_keys.footer_hints_lanes_run_detail_for
         ~preflight:(match detail with
           | Some (Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_}) -> true
           | _ -> false)));
  finish_surface state ~clamped:(Lane_run_detail_scroll { scroll; content_height })
    ~surface_key:"lane-run" ~rows:terminal_rows ~cols buf

(* The clients roster: everyone attached to this workspace in one reading —
   directory agents, state-backed sessions, runtime fibers. The keeper
   roster answers "which Keepers exist"; this answers "who is here now",
   which includes identities no other surface lists, such as a non-keeper
   MCP client. One row per identity, sorted by name on the server, with the
   status dot, the type, the keeper a row is bound to when it is, and what
   task it holds. *)
type client_table_column =
  | Client_status_column | Client_name_column | Client_type_column
  | Client_acting_for_column | Client_task_column | Client_last_seen_column

let render_client_detail state (client : Masc.Tui_decode.client_row) =
  let terminal_rows, cols = get_terminal_size () in
  let width = max 1 (framed_inner_width cols - 2) in
  let field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Message_layout.wrap_words ~max_cells:width (Terminal_text.single_line value)
        |> List.map (fun line -> "  " ^ line))
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let lines = field "Name:" client.cr_name
    @ field "Status:" (Masc.Tui_decode.client_status_to_string client.cr_status)
    @ field "Type:" client.cr_agent_type
    @ field "Acting for:" (optional client.cr_keeper_name)
    @ field "Task:" (optional client.cr_current_task)
    @ field "Last seen (as read):" client.cr_last_seen
    @ field "Observation age:" (Masc_tui_wire_age.text ~now:(Unix.gettimeofday ()) client.cr_last_seen)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"client-detail"
    ~frame:Chrome_overlay ~title:(screen_title " MASC Client Detail")
    ~hints:"j/k:scroll  PgUp/PgDn:page  g/G:first/last  Esc:clients"
    ~overflow:(Scrolled {scroll=state.client_detail_scroll;
                        report=(fun scroll -> Client_detail_scroll scroll)})
    ~body:(fun ~budget:_ c -> List.iter c.push lines)

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
  (* One reading of the clock for the frame: the header and every row's span
     are distances from the same instant, and two readings would put them a
     render apart. *)
  let now_s = Unix.gettimeofday () in
  let now = Unix.localtime now_s in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.clients_surface with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC System / Runtime / Clients") (title_missing_reading ~error:state.clients_surface_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d attached)  %s  %s"
          (screen_title " MASC System / Runtime / Clients") shown timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows like the verification submitter column: a fixed
     width puts the columns after the longest name out of line with the
     rest, and session names are the column the eye scans by. *)
  let table_width = max 0 (framed_inner_width cols - 2) in
  let last_seen_width =
    List.fold_left (fun widest (row : Masc.Tui_decode.client_row) ->
      max widest (Message_layout.display_width (Masc_tui_wire_age.text ~now:now_s row.cr_last_seen)))
      (Message_layout.display_width "LAST SEEN") clients
    (* The table keeps its status and identity floor. Exact observations that
       exceed this share are read in the selected client's scrollable detail. *)
    |> min (max 9 (table_width - 9 - 16 - 2 * Masc_tui_table.cell_gap))
  in
  let name_width =
    List.fold_left
      (fun widest (row : Masc.Tui_decode.client_row) ->
         max widest
           (Message_layout.display_width
              (Terminal_text.single_line row.Masc.Tui_decode.cr_name)))
      16 clients
    |> min 24
    (* A future or unreadable stamp is deliberately shown verbatim by the age
       projection. Give its measured width priority over the identity floor,
       rather than disguising a raw clock as a folded age. *)
    |> min (max 1 (table_width - 9 - last_seen_width - 2 * Masc_tui_table.cell_gap))
  in
  (* The column carries a reading only where a client is bound to a Keeper
     under a name of its own. Where no row has one, its cells and header are
     seventeen blank columns, and the clock at the end of the row is what
     loses them: "last seen 01:4…" is not a time. *)
  let acting_for_drawn = Masc_tui_types.clients_act_for_others clients in
  let column_width = function
    | Client_status_column | Client_task_column -> 9
    | Client_last_seen_column -> last_seen_width
    | Client_name_column -> name_width
    | Client_type_column -> 10
    | Client_acting_for_column -> 16
  in
  let columns =
    [ Client_status_column; Client_name_column; Client_type_column ]
    @ (if acting_for_drawn then [ Client_acting_for_column ] else [])
    @ [ Client_task_column; Client_last_seen_column ]
  in
  (* Keep identity, state and the observation age. Bindings, implementation
     type and task links yield in that order before the clock is cut. *)
  let layout = Masc_tui_table.fit ~inner_width:table_width
    ~width:column_width ~flex:Client_name_column
    ~drop_order:[ Client_acting_for_column; Client_type_column; Client_task_column ] columns in
  let cells ~status ~name ~agent_type ~keeper ~task ~last_seen =
    List.map (fun column ->
      let header, value = match column with
        | Client_status_column -> "STATUS", status
        | Client_name_column -> "NAME", name
        | Client_type_column -> "TYPE", agent_type
        | Client_acting_for_column -> "ACTING FOR", keeper
        | Client_task_column -> "TASK", task
        | Client_last_seen_column -> "LAST SEEN", last_seen
      in
      let width = if column = Client_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let col_hdr = "  " ^ Masc_tui_table.header_row
    (cells ~status:"" ~name:"" ~agent_type:"" ~keeper:"" ~task:"" ~last_seen:"") in
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
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.clients_surface ~error:state.clients_surface_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (nobody attached)"
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
          (* Both sides sanitized before they are compared: the cell is
             drawn from this reading, and a name that differs only in the
             bytes [Terminal_text] strips is the same name on screen. *)
          let keeper =
            match
              Masc_tui_types.client_acting_for ~name
                ~keeper_name:
                  (Option.map Terminal_text.single_line row.cr_keeper_name)
            with
            | Some keeper -> keeper
            | None -> ""
          in
          let task =
            match row.cr_current_task with
            | Some task -> Terminal_text.single_line task
            | None -> Masc_tui_theme.Glyph.no_value
          in
          let line =
            "  " ^ Masc_tui_table.row (cells ~status ~name
              ~agent_type:(Terminal_text.single_line row.cr_agent_type) ~keeper ~task
              (* How long ago, not when. The cell drew the clock alone on
                 the reading that the header's clock gives it a distance,
                 which holds only while the two are the same day: a dashboard
                 session last seen on 2026-09-21 drew "11:49:28" under a
                 header reading 09:31:39 on 2026-09-23, and the distance a
                 reader could take from that pointed two hours ahead. A span
                 carries its own day. *)
              ~last_seen:(Masc_tui_wire_age.text ~now:now_s row.cr_last_seen))
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
  box_bottom buf cols;
  (* [listing_chrome] already counts this row. Without it the keys the table
     declares for Clients went unshown, and so did an armed search's query,
     which rides the same row. *)
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Masc_tui_types.Clients));
  finish_surface state ~surface_key:"clients" ~rows:terminal_rows ~cols buf
;;

let render_lane_inventory_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let width = max 1 (framed_inner_width cols - 2) in
  let content = match state.lane_inventory with
    | None -> ["Lane inventory has not been read. r: refresh"]
    | Some snapshot ->
        (match target with
         | None -> "Inventory diagnostics" :: (match Masc_tui_lane_inventory.snapshot_notices snapshot with
             | [] -> ["No inventory read issues observed."]
             | notices -> notices)
         | Some id ->
             (match List.find_opt (fun (row : Masc.Tui_decode_lane_inventory.row) -> String.equal row.id id) snapshot.rows with
              | None -> ["This Lane is absent from the current reading. Esc returns to the inventory."]
              | Some row ->
                  (match row.Masc.Tui_decode_lane_inventory.selection with
                   | Exact lane ->
                       (match List.find_opt (fun (item : Tui_decode.standalone_lane) ->
                            Standalone_lane.equal item.sl_lane lane) snapshot.exact_snapshot.sls_lanes with
                        | Some item -> standalone_lane_detail_lines ~now:(Unix.gettimeofday ()) ~width item
                            |> List.map (fun (_,line) -> Masc_tui_theme.strip_sgr line)
                        | None -> Masc_tui_lane_inventory.detail_lines row)
                   | Browser _ | Machine _ | Declaration _ | Manual_instance _ ->
                       Masc_tui_lane_inventory.detail_lines row))) in
  let content = (match state.standalone_lanes_error with
    | None -> [] | Some detail -> ["STALE · " ^ detail]) @ content in
  let lines = content |> List.concat_map (fun text -> Terminal_text.single_line text
    |> Message_layout.wrap_words ~max_cells:width) in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.lane_run_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title " MASC Lane reading" ^ "  " ^ connection_badge state);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols ("  " ^ line)
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length lines))
    ~hints:"j/k:scroll  PgUp/PgDn:page  Home/End:top/bottom  r:refresh  Esc/Left:inventory");
  finish_surface state ~clamped:(Lane_run_detail_scroll {scroll;content_height=height})
    ~surface_key:"lane-inventory-detail" ~rows:terminal_rows ~cols buf

let render_machine_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let width = max 1 (framed_inner_width cols - 2) in
  let lines = Masc_tui_machine_activity.lines session
    |> List.concat_map (fun text -> Terminal_text.single_line text
      |> Message_layout.wrap_words ~max_cells:width) in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.lane_run_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title " MASC Machine activity" ^ "  " ^ connection_badge state);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols ("  " ^ line)
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length lines))
    ~hints:"Space:draft  s:save  r:read  u:reapply  x:discard  ?:help  Esc:back");
  finish_surface state ~clamped:(Lane_run_detail_scroll {scroll;content_height=height})
    ~surface_key:"machine-activity" ~rows:terminal_rows ~cols buf

let render_browser_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let width = max 1 (framed_inner_width cols - 2) in
  let lines = Masc_tui_browser_activity.lines session
    |> List.concat_map (fun text -> Terminal_text.single_line text
      |> Message_layout.wrap_words ~max_cells:width) in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.lane_run_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title " MASC Browser activity" ^ "  " ^ connection_badge state);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols ("  " ^ line)
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length lines))
    ~hints:"Space:draft  s:save  r:read  u:reapply  x:discard  ?:help  Esc:back");
  finish_surface state ~clamped:(Lane_run_detail_scroll {scroll;content_height=height})
    ~surface_key:"browser-activity" ~rows:terminal_rows ~cols buf

let render_exact_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let width = max 1 (framed_inner_width cols - 2) in
  let lines = Masc_tui_exact_activity.lines session
    |> List.concat_map (fun text -> Terminal_text.single_line text
      |> Message_layout.wrap_words ~max_cells:width) in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.lane_run_detail_scroll in
  let window = Rows.of_list ~first:scroll ~height lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title " MASC Exact activity" ^ "  " ^ connection_badge state);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols ("  " ^ line)
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length lines))
    ~hints:"Space:draft  s:save  r:read  u:reapply  x:discard  ?:help  Esc:back");
  finish_surface state ~clamped:(Lane_run_detail_scroll {scroll;content_height=height})
    ~surface_key:"exact-activity" ~rows:terminal_rows ~cols buf

let render_lanes (state : state) =
  match Masc_tui_types.shown_machine_activity state with
  | Some session -> render_machine_activity state session
  | None -> match Masc_tui_types.shown_browser_activity state with
  | Some session -> render_browser_activity state session
  | None -> match Masc_tui_types.shown_exact_activity state with
  | Some session -> render_exact_activity state session
  | None -> match state.lanes_mode with
  | Lanes_overview -> render_lanes_overview state
  | Lanes_inventory_detail target -> render_lane_inventory_detail state target
  | Lanes_run_list lane -> render_lane_run_list state ~lane
  | Lanes_run_detail (_, run_id) -> render_lane_run_detail state ~run_id
  | Lanes_measurement_detail sha256 -> render_lane_run_detail state ~run_id:sha256

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
   send. [None] here is the first; the tab decides what to say about it from
   the Lanes reading the list rides on, because a list that is empty after a
   failed read and one that is empty before any read are the same list. *)
let secret_lines (state : state) (k : keeper) =
  let dim line = Ansi.dim ^ line ^ Ansi.reset in
  match
    List.find_opt
      (fun (p : Masc.Tui_decode.keeper_secret_projection) ->
        String.equal p.Masc.Tui_decode.ksp_keeper k.k_name)
      state.keeper_secrets
  with
  | None -> None
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
      |> Option.some

(* The Identity tab's body. Numbering comes from
   [Masc_tui_identity_model.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let proactive_outcome_word = function
  | Masc.Keeper_meta_contract.Proactive_never_started -> "never started"
  | Masc.Keeper_meta_contract.Proactive_unknown -> "unknown"
  | Masc.Keeper_meta_contract.Proactive_silent -> "silent"
  | Masc.Keeper_meta_contract.Proactive_text_response -> "replied with text"
  | Masc.Keeper_meta_contract.Proactive_tool_use -> "used tools"
  | Masc.Keeper_meta_contract.Proactive_mixed_response -> "text and tools"
  | Masc.Keeper_meta_contract.Proactive_error -> "error"

let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols
    ~origin:(origin_row, origin_col) buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = framed_inner_width cols in
    (* What the pane has written so far, so the portrait's placement is
       counted from what was drawn above it rather than by hand. *)
    let pane_start = Buffer.length buf in
    (* The content rows under the title and divider, before an overflow
       indicator takes one of them. *)
    let base_height = max 0 (rows - framed_chrome_rows) in
    (* Info shows the current outfit; Items changes only the drawing for its
       selected preview. Both use the server's observed equipment. *)
    let portrait_reading = match (keeper_reading state k).Keeper_control.liveness with
      | Keeper_control.Present runtime -> runtime.kr_portrait
      | Keeper_control.Unobserved -> Tui_decode.Unavailable "not yet read"
      | Keeper_control.Absent -> Tui_decode.Unavailable "absent from live roster"
      | Keeper_control.Invalid detail -> Tui_decode.Unavailable detail in
    let selected_item =
      List.nth_opt Keeper_portrait_item.all state.item_cursor
    in
    let account =
      match state.item_account with
      | Some (name, (_, account)) when String.equal name k.k_name -> Some account
      | Some _ | None -> None
    in
    let milli value = Printf.sprintf "%d.%03d" (value / 1000) (value mod 1000) in
    let account_line =
      match account, state.item_account_error with
      | Some (Item_account.Ready account), _ ->
          "  Balance " ^ milli account.balance_milli ^ " Candle · preview only"
      | Some Item_account.Off, _ -> "  Candle off · preview only"
      | Some (Item_account.Disabled reason), _ ->
          "  Candle disabled: " ^ Terminal_text.single_line reason
      | None, Some detail ->
          "  Account unavailable: " ^ Terminal_text.single_line detail
      | None, None -> "  Loading Item account…"
    in
    let item_account_facts item =
      match account with
      | Some (Item_account.Ready account) ->
          let owned =
            List.exists (fun owned ->
              String.equal (Keeper_portrait_item.id owned)
                (Keeper_portrait_item.id item)) account.owned_items in
          let price =
            match List.find_opt (fun (entry : Item_account.entry) ->
              String.equal (Keeper_portrait_item.id entry.item)
                (Keeper_portrait_item.id item)) account.catalog with
            | Some entry ->
              (match entry.price with
               | Item_account.Unpriced -> "unpriced"
               | Item_account.Priced amount -> milli amount)
            | None -> "catalog unavailable"
          in
          Some (price ^ (if owned then " owned" else ""))
      | Some (Item_account.Off | Item_account.Disabled _) | None -> None
    in
    let portrait =
      match state.detail_tab, portrait_reading with
      | Detail_info, Tui_decode.Ready equipment ->
          Masc_tui_keeper_portrait.shown ~name:k.k_name ~equipment
            ~content_rows:base_height ~content_cols:inner
      | Detail_items, Tui_decode.Ready equipment ->
          Option.bind selected_item (fun item ->
            Masc_tui_keeper_portrait.preview ~name:k.k_name
              ~equipment:(Keeper_portrait_item.preview item equipment)
              ~content_rows:base_height ~content_cols:inner)
      | (Detail_info | Detail_items), Tui_decode.Unavailable _
      | (Detail_sandbox | Detail_instructions | Detail_secrets | Detail_github
        | Detail_identity | Detail_channels | Detail_automation | Detail_runs), _ -> None
    in

    let item_row cursor index item =
      let worn =
        match portrait_reading with
        | Tui_decode.Unavailable _ -> false
        | Tui_decode.Ready equipment ->
            (match Keeper_portrait_item.in_slot equipment
                     (Keeper_portrait_item.slot item) with
             | None -> false
             | Some equipped ->
                 String.equal (Keeper_portrait_item.id equipped)
                   (Keeper_portrait_item.id item))
      in
      let account_facts =
        if inner < 90 then ""
        else match item_account_facts item with
          | Some facts -> "  " ^ facts
          | None -> ""
      in
      Printf.sprintf "  %s %2d %-5s %s%s%s"
        (if index = cursor then ">" else " ") (index + 1)
        (Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item))
        (Keeper_portrait_item.id item) account_facts
        (if worn then "  equipped" else "")
    in
    let item_headline cursor count =
      [ Printf.sprintf "  Items %d/%d · j/k to preview" (cursor + 1) count
      ; account_line
      ]
    in
    let portrait =
      match state.detail_tab, portrait with
      | Detail_items, Some band ->
          let count = List.length Keeper_portrait_item.all in
          let cursor = max 0 (min (count - 1) state.item_cursor) in
          let labels = item_headline cursor count
            @ List.mapi (item_row cursor) Keeper_portrait_item.all in
          if List.exists (fun line -> Message_layout.display_width line > inner)
               (Masc_tui_keeper_portrait.beside band labels)
          then None else Some band
      | _, portrait -> portrait
    in
    let item_lines () =
      let items = Keeper_portrait_item.all in
      let count = List.length items in
      let cursor = max 0 (min (count - 1) state.item_cursor) in
      let headline = item_headline cursor count in
      let observation =
        match portrait_reading with
        | Tui_decode.Ready _ -> []
        | Tui_decode.Unavailable reason ->
            [ "  Portrait unavailable: " ^ Terminal_text.single_line reason ] in
      let selected_facts =
        match List.nth_opt items cursor with
        | None -> []
        | Some item ->
            (match item_account_facts item with
             | Some facts -> [ "  Selected: " ^ facts ]
             | None -> []) in
      let footer = [ "  Preview changes this picture only." ] in
      let reserved = List.length headline + List.length selected_facts
                     + List.length observation + List.length footer in
      let visible = min count (max 1 (base_height - reserved)) in
      let first = max 0 (min (cursor - (visible / 2)) (count - visible)) in
      let rows =
        items
        |> List.mapi (fun index item -> index, item)
        |> List.filter_map (fun (index, item) ->
             if index < first || index >= first + visible then None
             else Some (item_row cursor index item))
      in
      let listing =
        match portrait with
        | Some band -> Masc_tui_keeper_portrait.beside band (headline @ rows)
        | None -> headline @ rows
      in
      listing @ selected_facts @ observation @ footer
    in
    (* A long value takes the width below its label, rather than the few
       cells a fixed label column leaves beside it. These are actual display
       rows, counted before the detail window is sliced. Values have already
       passed their wire-boundary sanitizer and may carry this pane's SGR. *)
    let field_rows ~width ~label_cells ~label_style label value =
      let prefix = "  " ^ label_style ^ fit_width label label_cells ^ Ansi.reset ^ " " in
      if Message_layout.display_width (prefix ^ value) <= width then
        [prefix ^ value]
      else
        ("  " ^ label_style ^ label ^ Ansi.reset)
        :: (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 4)) value
            |> List.map (fun line -> "    " ^ line ^ Ansi.reset))
    in

    (* Each tab projects only when selected. Retained data for the other
       tabs must not be walked and formatted on every scroll frame. These
       functions capture this frame, so switching tabs reads current state. *)
    let info_lines () =
      (* Build all detail lines first, then apply scroll *)
      let lines = ref [] in
      let add_line s = lines := s :: !lines in

      (* Helper to add a labeled row *)
      let row_lines ~width label value =
        field_rows ~width ~label_cells:22
          ~label_style:(Masc_tui_theme.tone Masc_tui_theme.Accent) label value
      in
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in
      let add_empty () = add_line "" in
      let section_line title = Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset in
      let add_section title = add_line (section_line title) in

      (* Identity, current task and context share the icon's header. These
         facts use the same label column, rather than leaving the portrait's
         lower rows blank while the current work falls below the viewport. *)
      let header_width = match portrait with
        | None -> inner
        | Some band -> max 1 (inner - 2 - band.Masc_tui_keeper_portrait.box.cols)
      in
      let identity =
        let width = header_width in
        [ section_line "Identity" ]
        @ row_lines ~width "Name:" (Terminal_text.single_line k.k_name)
        @ row_lines ~width "Paused:"
            (match k.k_origin, (keeper_reading state k).Keeper_control.liveness with
             | Tui_decode.Remote_keeper,
                 (Keeper_control.Invalid _ | Unobserved | Absent) ->
                 Ansi.dim ^ "not observed" ^ Ansi.reset
             | (Tui_decode.Persisted_keeper | Declared_keeper _), _
             | Remote_keeper, Keeper_control.Present _ ->
                 if k.k_paused then (Theme.warn ()) ^ "yes" ^ Ansi.reset
                 else Ansi.dim ^ "no" ^ Ansi.reset)
        @ (let amount = match (keeper_reading state k).Keeper_control.liveness with
            | Keeper_control.Present runtime -> runtime.kr_candle_balance_milli
            | Keeper_control.Unobserved | Keeper_control.Absent | Keeper_control.Invalid _ -> None in
           match Masc_tui_candle.balance_text state.candle_observation amount with
           | None -> []
           | Some value -> row_lines ~width "Candle balance:" (Terminal_text.single_line value))
      in
      List.iter add_line identity;
      (match portrait_reading with
       | Tui_decode.Ready _ -> ()
       | Tui_decode.Unavailable reason -> add_row "Portrait:" ("unavailable: " ^ Terminal_text.single_line reason));
      add_empty ();
      let add_row label value =
        List.iter add_line (row_lines ~width:header_width label value)
      in
      (* Current work section *)
      add_section "Current Work";
      add_row "Task:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity -> Terminal_text.single_line_or
             ~default:Masc_tui_theme.Glyph.no_value activity.k_current_task_id);
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
                       Layout.keeper_context_bar_width
                         ~inner_width:header_width
                     in
                     add_row "Context:"
                       (Printf.sprintf "%s%.1f%%%s  %s  %s / %s tokens"
                          (ctx_color ratio) pct Ansi.reset
                          (ctx_bar ratio bar_width)
                          (Masc_tui_message_layout.compact_count
                             observation.tokens)
                          (Masc_tui_message_layout.compact_count
                             observation.maximum));
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
                          "%s tokens in context; window not observed"
                          (Masc_tui_message_layout.compact_count
                             observation.tokens));
                     add_row "Observed:"
                       (Terminal_text.short_timestamp observation.observed_at);
                     add_row "Turn Ref:"
                       (Terminal_text.single_line observation.turn_ref)
                 | Observation_layout.Context_unavailable reason ->
                     add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset))
            | None, None ->
                add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)));
      add_empty ();

      let header_lines = List.rev !lines in
      lines := [];
      List.iter add_line
        (match portrait with
         | Some band -> Masc_tui_keeper_portrait.beside band header_lines
         | None -> header_lines);
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in

      (* The live roster owns this reading, including its absence after a
         successful turn. Neither historical last_error nor the last outcome
         can answer for the current failure. *)
      add_section "Current failure";
      let failure_tone, failure_text =
        match (keeper_reading state k).Keeper_control.liveness with
        | Keeper_control.Present runtime ->
            (match runtime.kr_runtime_blocker_summary with
             | Some summary -> Theme.bad (), summary
             | None -> Ansi.dim, "none")
        | Keeper_control.Unobserved -> Ansi.dim, "unread"
        | Keeper_control.Absent -> Ansi.dim, "absent from live roster"
        | Keeper_control.Invalid detail -> Theme.bad (), "config error: " ^ detail
      in
      let indent = "  " in
      Message_layout.wrap_words
        ~max_cells:(max 1 (inner - Message_layout.display_width indent))
        (Terminal_text.single_line failure_text)
      |> List.iter (fun line -> add_line (indent ^ failure_tone ^ line ^ Ansi.reset));
      add_empty ();

      (* Blocked Board-attention partitions wait here for an
         operator's requeue, and nothing else on the screens said they existed.
         Beside the current failure because it is one: this Keeper's Board
         judgments for those posts do not move until someone presses Q. *)
      add_section "Board attention";
      Masc_tui_board_quarantine.lines ~now:(Unix.gettimeofday ())
        state.keeper_board_quarantines ~keeper_name:k.k_name
      |> List.iter (fun (tone, text) ->
           let color =
             match tone with
             | Masc_tui_board_quarantine.Plain -> ""
             | Masc_tui_board_quarantine.Dim -> Ansi.dim
             | Masc_tui_board_quarantine.Warn -> Theme.warn ()
             | Masc_tui_board_quarantine.Bad -> Theme.bad ()
           in
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 2)) text
           |> List.iter (fun line -> add_line (indent ^ color ^ line ^ Ansi.reset)));
      add_empty ();

      (* Gate section. Two settings with similar names decide different things,
         so both are named rather than merged: YOLO is the in-memory stance that
         stops this chat asking and a restart clears, while the Gate mode is
         durable and is what an external effect -- a write to a service this
         Keeper is attached to -- is actually decided under. An operator reading
         one for the other is how a call gets made that nobody meant to allow. *)
      add_section "Gate";
      (* The same word the chat header wears in capitals and the footer offers
         after g, with what it does beside it. This row said "asked" under a
         header saying AUTO. *)
      add_row "Tool calls:"
        (let mode =
           if List.mem k.k_name state.keeper_yolo_names then
             Masc.Keeper_tool_approval_mode.Yolo
           else Masc.Keeper_tool_approval_mode.Auto
         in
         let tone =
           match mode with
           | Masc.Keeper_tool_approval_mode.Yolo -> Theme.bad ()
           | Masc.Keeper_tool_approval_mode.Auto -> Ansi.dim
         in
         tone ^ Masc_tui_types.tool_mode_word mode ^ " \xc2\xb7 "
         ^ Masc_tui_types.tool_mode_effect mode ^ Ansi.reset);
      (* "workspace" is where the stance comes from, not what it is. The chat
         header resolves the same inheritance before drawing it; this row left
         the reader to go and look it up. *)
      add_row "Effects (Gate mode):"
        (let inherited =
           Option.map
             (fun (modes : Tui_decode.gate_lane_modes) ->
               gate_mode_word_of_wire modes.Tui_decode.glm_workspace)
             state.gate_modes
         in
         match List.assoc_opt k.k_name state.keeper_gate_modes with
         | Some mode when not (String.equal mode "workspace") ->
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             ^ Terminal_text.single_line (gate_mode_word_of_wire mode)
             ^ Ansi.reset
         | Some _ | None ->
             Ansi.dim ^ "workspace"
             ^ (match inherited with
                | Some word -> " \xc2\xb7 " ^ Terminal_text.single_line word
                | None -> "")
             ^ Ansi.reset);
      add_row "Lane first:"
        (match
           List.filter
             (fun (first : Tui_decode.keeper_exact_lane_first) ->
               String.equal first.Tui_decode.kel_keeper k.k_name)
             state.keeper_exact_lane_firsts
         with
         | [] -> Ansi.dim ^ "lane order" ^ Ansi.reset
         | firsts ->
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             ^ Terminal_text.single_line
                 (String.concat ", "
                    (List.map
                       (fun (first : Tui_decode.keeper_exact_lane_first) ->
                         (* The marker leads: a narrow pane cuts the row's
                            tail, and the slot id is the part it can lose. *)
                         (if first.kel_offered then ""
                          else "not offered, lane order \xc2\xb7 ")
                         ^ first.Tui_decode.kel_lane_id ^ " \xe2\x86\x92 "
                         ^ first.kel_slot_id)
                       firsts))
             ^ Ansi.reset);
      (match state.keeper_gate_settings_unread with
       | None -> ()
       | Some reason ->
           add_row "Gate settings:"
             (Theme.bad () ^ "unread \xc2\xb7 "
              ^ Terminal_text.single_line reason ^ Ansi.reset));
      add_empty ();

      (* Runtime section *)
      add_section "Runtime Stats";
      let assignment =
        List.find_opt
          (fun (a : Tui_decode.runtime_assignment) ->
             String.equal a.ra_keeper k.k_name)
          state.runtime_assignments
      in
      let target_str =
        match assignment with
        | Some a -> runtime_assignment_label a
        | None ->
            let def_name =
              match state.runtime_surface with
              | Some s ->
                  (match s.rss_resolved.rrs_default_runtime_id with
                   | Some d -> Printf.sprintf "inherited: %s" d
                   | None -> "inherited")
              | None -> "inherited"
            in
            Printf.sprintf "default (%s)" def_name
      in
      add_row "Runtime Target:" target_str;
      (match assignment with
       | Some { ra_resolution = Runtime_assignment_lane tid; _ } ->
           (match
              List.find_opt
                (fun (l : Tui_decode.runtime_resolved_lane) ->
                   String.equal l.rrl_id tid)
                state.runtime_lanes
            with
            | Some lane ->
                let hops =
                  String.concat " \xe2\x86\x92 "
                    (List.map runtime_id_model_part lane.rrl_runtime_ids)
                in
                add_row "Candidate Chain:" hops;
                (match lane.rrl_runtime_ids with
                 | first :: _ -> add_row "Head Candidate:" first
                 | [] -> ())
            | None -> ())
       | Some
           { ra_resolution =
               (Runtime_assignment_missing | Runtime_assignment_unavailable _)
           ; _
           } ->
         ()
       | None ->
           (match state.runtime_surface with
            | Some snap ->
                (match snap.rss_resolved.rrs_default_runtime_id with
                 | Some def_id ->
                     (match
                        List.find_opt
                          (fun (ro : Tui_decode.runtime_option) -> String.equal ro.ro_id def_id)
                          snap.rss_resolved.rrs_runtimes
                      with
                      | Some ro ->
                          add_row "Default Context:"
                            (Printf.sprintf "%s \xc2\xb7 max output %s"
                               (format_context_tokens ro.ro_effective_max_context)
                               (match ro.ro_max_output_tokens with
                                | Some t -> format_context_tokens t
                                | None -> "default"))
                      | None -> ())
                 | None -> ())
            | None -> ()));
      (match k.k_origin with
       | Tui_decode.Persisted_keeper -> ()
       | Remote_keeper -> add_row "Source:" "server roster"
       | Declared_keeper requirements ->
         add_row "Preparation:" (String.concat " · "
           (List.map Masc.Keeper_declared_roster.requirement_label requirements)));
      (match k.k_activity with
       | None -> add_row "Activity:" "not observed"
       | Some activity ->
      add_row "Total Turns:" (string_of_int activity.k_total_turns);
      (* Read at a glance, the way the Acting pane's block already reads its
         token figures. A live roster drew "75111274" here: eight digits a
         reader counts rather than reads. Turns and tool calls keep their
         digits -- three or four of them, and a count of things done rather
         than a size. *)
      add_row "Total Tokens:"
        (Masc_tui_message_layout.compact_count activity.k_total_tokens);
      add_row "Total Cost:" (Printf.sprintf "$%.4f" activity.k_total_cost_usd);
      add_row "Last Turn:" (Terminal_text.short_timestamp activity.k_last_turn_ts));
      add_empty ();

      (* Recent activity, folded from the metrics rows already read for this
         Keeper. The window is bounded by row count, so it can fall short of the
         span; when it does, say what it reached instead of implying a full day.
         With no rows there is nothing to total, so the section says why and
         draws no zeros: the same sentence the Logs tab gives for the same
         read. *)
      add_section "Last 24h";
      (match
         Keeper_activity.read
           ~since:
             (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
           state.log_entries
       with
       | Keeper_activity.No_rows ->
         add_row "Window:"
           (Ansi.dim ^ Metrics_tail.empty_message state.log_error ^ Ansi.reset)
       | Keeper_activity.Rows activity ->
         if not activity.Keeper_activity.aw_covered then
           add_row "Window:"
             (match activity.Keeper_activity.aw_oldest_ts with
              | Some oldest ->
                Printf.sprintf "partial, reaches %s"
                  (Terminal_text.short_timestamp oldest)
              | None -> "partial");
         add_row "Turns / Heartbeats:"
           (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
              activity.Keeper_activity.aw_heartbeats);
         add_row "Tokens In / Out:"
           (Printf.sprintf "%s / %s"
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_input_tokens)
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_output_tokens));
         add_row "Cost:"
           (match activity.Keeper_activity.aw_cost_usd with
            | Some cost -> Printf.sprintf "$%.4f" cost
            | None -> Ansi.dim ^ "not priced by the provider" ^ Ansi.reset);
         add_row "Tool Calls:"
           (string_of_int activity.Keeper_activity.aw_tool_calls);
         add_row "Top Tools:"
           (match activity.Keeper_activity.aw_top_tools with
            | [] -> Masc_tui_theme.Glyph.no_value
            | tools ->
              tools
              |> List.map (fun (tool : Keeper_activity.tool_use) ->
                     Printf.sprintf "%s x%d"
                       (Terminal_text.single_line tool.Keeper_activity.tu_name)
                       tool.Keeper_activity.tu_calls)
              |> String.concat "  "));
      add_empty ();

      add_section "Autonomy";
      add_row "Last Outcome:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity ->
           (match activity.k_last_proactive_outcome with
            | Some outcome -> proactive_outcome_word outcome
            | None -> Masc_tui_theme.Glyph.no_value));
      add_empty ();

      (* Timestamps section *)
      add_section "Timestamps";
      (match k.k_identity with
       | Ok identity ->
         add_row "Created:" (Terminal_text.short_timestamp identity.k_created_at);
         add_row "Updated:" (Terminal_text.short_timestamp identity.k_updated_at)
       | Error reason ->
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 26))
             (Terminal_text.single_line reason)
           |> List.iteri (fun index line ->
                add_row (if index = 0 then "Metadata:" else "") line));

      List.rev !lines
    in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    (* A pending read says how long it has been pending. Five to sixteen
       seconds is what the Sandbox tab's status took against a live server,
       and a bare "(loading...)" through that window reads as a stall.

       The stamp is the read's own: the tab read and the container-log read are
       two reads and the operator starts the second long after the first has
       landed. One reading of the clock for the frame, so two rows drawn in the
       same frame cannot disagree about what time it is. *)
    let now_ns = Mtime_clock.elapsed_ns () in
    let loading_row ?started_ns what =
      Ansi.dim ^ "  "
      ^ Masc_tui_types.loading_notice
          ?elapsed_s:(Masc_tui_types.pending_elapsed_s ~now_ns started_ns)
          what
      ^ Ansi.reset
    in
    let tab_loading_row what =
      loading_row
        ?started_ns:
          (Masc_tui_types.detail_read_started state ~tab:state.detail_tab
             ~keeper:k.k_name)
        what
    in
    let stamped_or view error =
      match error with
      | Some detail -> [ (Theme.bad ()) ^ "  " ^ detail ^ Ansi.reset ]
      | None -> (
          match view with
          | Some (stamp, lines) when String.equal stamp k.k_name ->
              List.map (fun line -> "  " ^ line) lines
          | Some _ | None -> [ tab_loading_row "loading" ])
    in
    let channel_lines () =
      match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
            ^ Ansi.reset ]
      | _, None -> [ Ansi.dim ^ "  (loading channel transports…)" ^ Ansi.reset ]
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
          in
          (* The list row and the detail badge spell the same connection, so
             they read the same table. This pane kept a byte-identical copy of
             it, which meant a change to the vocabulary could land in one
             place and leave the omission rule in [Masc_tui_connector_state]
             judging against the other. *)
          let connection_label (connector : Masc.Tui_decode_connectors.connector) =
            let word =
              Masc_tui_connector_state.badge_word connector.cn_connection
            in
            match connector.cn_connection with
            | Masc.Tui_decode_connectors.Connector_connected ->
                (Theme.ok ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_connected_unavailable ->
                (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_disconnected -> (Theme.bad ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_offline -> Ansi.dim ^ "○ " ^ word ^ Ansi.reset
            | Connector_stale -> (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
          in
          let transport_rows =
            List.mapi
              (fun index (connector : Masc.Tui_decode_connectors.connector) ->
                 let here_count =
                   List.length
                     (List.filter
                        (fun (binding : Masc.Tui_decode_connectors.connector_binding) ->
                           String.equal binding.cb_keeper_name k.k_name)
                        connector.cn_bindings)
                 in
                 let tail =
                   Printf.sprintf "  %d here / %d total" here_count
                     (List.length connector.cn_bindings)
                 in
                 (* Two cells of indent, two for the cursor mark, two between
                    the name and the badge: the padding the row spends before
                    its columns. *)
                 let name_cells =
                   Masc_tui_connector_state.list_row_name_cells
                     ~inner:(framed_inner_width cols) ~fixed_cells:6
                     ~tail_cells:(String.length tail)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "▸ " else "  ")
                   ^ fit_width
                       (Terminal_text.single_line connector.cn_display_name)
                       name_cells
                   ^ "  "
                   ^ fit_width
                       (Masc_tui_connector_state.badge_word
                          connector.cn_connection)
                       Masc_tui_connector_state.badge_column_cells
                   ^ tail
                 in
                 if index = selected_index then Ansi.reverse ^ line ^ Ansi.reset
                 else line)
              connectors
          in
          let refused_rows =
            List.map
              (fun (refusal : Masc.Tui_decode_connectors.connector_refusal) ->
                 let name =
                   match refusal.cr_connector_id with
                   | Some id -> Terminal_text.single_line id
                   | None -> Printf.sprintf "connectors[%d]" refusal.cr_row
                 in
                 (Theme.bad ()) ^ "    " ^ name ^ "  unreadable: "
                 ^ Terminal_text.single_line refusal.cr_reason ^ Ansi.reset)
              snapshot.cs_refused
          in
          let selected_lines =
            match List.nth_opt connectors selected_index, snapshot.cs_refused with
            | None, [] ->
                [ Ansi.dim ^ "  (no channel transports registered)" ^ Ansi.reset ]
            | None, _ :: _ -> []
            | Some connector, _ ->
                let field label value =
                  field_rows ~width:inner ~label_cells:18 ~label_style:"" label value
                in
                let optional_row label value =
                  match value with
                  | None -> []
                  | Some value ->
                      field label (Terminal_text.single_line value)
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
                let binding_reference (binding : Masc.Tui_decode_connectors.connector_binding) =
                  Masc_tui_connector_unbind.channel_label
                    ~channel_id:binding.cb_channel_id
                    ~channel_name:binding.cb_channel_name
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some "readable"
                  | Some false -> Some "UNREADABLE"
                  | None -> None
                in
                let binding_lines =
                  List.mapi
                    (fun index (binding : Masc.Tui_decode_connectors.connector_binding) ->
                      let here = String.equal binding.cb_keeper_name k.k_name in
                      let selected = index = state.connectors_binding_cursor in
                      let missing_keeper =
                        not (keeper_is_present binding.cb_keeper_name)
                      in
                      let line =
                        Printf.sprintf "    %s %s → %s%s"
                          (if selected then Masc_tui_theme.Glyph.current_entry else " ")
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
                ]
                @ field "Binding target"
                    (match selected_binding with
                     | None -> "(no binding selected)"
                     | Some binding -> binding_reference binding)
                  (* The badge is read from the status the row would print
                     beside it ([decode_connector_connection] takes status,
                     available and connected), so the word never differs from
                     the badge and the row said the same thing twice. *)
                @ field "Connection"
                    (connection_label connector)
                @ field "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                @ field "Channel type"
                    (Terminal_text.single_line_or
                       ~default:Masc_tui_theme.Glyph.no_value connector.cn_channel)
                @ optional_row "Runtime state"
                    (Masc_tui_connector_state.runtime_state_to_draw connector)
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
                         | Masc.Tui_decode_connectors.Connector_directory_not_started ->
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
                     field "Authentication"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     field "Permission limits"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     field "Directory errors"
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     )
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
                       @ List.concat_map
                           (fun (mapping : Masc.Tui_decode_connectors.connector_name_mapping) ->
                              Printf.sprintf "%-7s %s ↔ %s"
                                (match mapping.cnm_kind with
                                 | Masc.Tui_decode_connectors.Connector_channel_name -> "channel"
                                 | Connector_person_name -> "person"
                                 | Connector_server_name -> "server")
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name)
                              |> Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
                              |> List.map (fun line -> "    " ^ line))
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
                 [ (Theme.bad ()) ^ "  STALE · "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ transport_rows @ refused_rows @ selected_lines
    in
    let automation_lines () =
      (* This tab reads the Keeper's own page from the server rather than
         filtering the fleet page: that page caps at its own limit with active
         rows first, so a Keeper whose schedules are terminal or further down
         was absent from it and the tab said none existed. The page it asks for
         can still truncate, which is why the absence reading stays. *)
      let error_lines =
        match state.keeper_schedules_error with
        | Some (keeper_name, err) when String.equal keeper_name k.k_name ->
            let stale = match state.keeper_schedules with
              | Some (name, _) when String.equal name k.k_name -> "STALE · "
              | Some _ | None -> ""
            in
            [ (Theme.bad ()) ^ "  " ^ stale ^ Terminal_text.single_line err ^ Ansi.reset ]
        | Some _ | None -> []
      in
      let snapshot_lines = match state.keeper_schedules with
      | Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
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
            (* What the store holds, above the rows it sent. The rows come
               live-first, and a Keeper whose store has run for weeks answers
               with a page of closed work behind the one live row -- without
               this line a reader learns that only by scrolling to the end.
               The counts describe the whole store, so they stay right when
               the page below them is capped. *)
            (match snapshot.scs_counts with
             | None -> []
             | Some counts ->
                 [ Ansi.dim ^ "  "
                   ^ Masc_tui_types.schedule_counts_line counts
                   ^ Ansi.reset
                 ; ""
                 ])
            @ (let outcome_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line (schedule_outcome_word row))
                   rows
               in
               let by_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_requested_by)
                   rows
               in
               let recurrence_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_recurrence_summary)
                   rows
               in
               (* Every line carries a two-cell lead before the table, so the
                  table is fitted to what the lead leaves -- the same reserve
                  the Schedules list makes, without which the frame cuts the
                  last column's tail on every row. *)
               let table_inner = max 1 (inner - 2) in
               let layout =
                 Render_schedule.kauto_layout ~inner_width:table_inner
                   ~status_width:schedule_status_word_cells
                   ~clock_width:schedule_requested_clock_cells
                   ~outcome_width:
                     (Render_schedule.schedule_delivery_width outcome_words)
                   ~recurrence_width:
                     (Render_schedule.kauto_recurrence_width recurrence_words)
                   ~by_width:(Render_schedule.kauto_by_width by_words)
               in
               let header = Render_schedule.kauto_header_row ~layout in
               (* The rule under the names runs the header's own width, so a
                  pane narrower than the table does not draw a rule longer
                  than the rows under it. The closed rule below ends at the
                  same cell, so the two rules read as one margin. *)
               let rule_cells =
                 min table_inner (Message_layout.display_width header) in
               let occurrence_clock = function
                 | Some iso -> Terminal_text.short_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
               in
               let row_line (row : schedule_row) =
                 (* The mark and the state word wear one colour, the state's
                    own; the outcome wears the outcome's, so a failed wake
                    reads red beside a state still reading live. *)
                 let status_style = schedule_status_color row.sch_status in
                 (* A held occurrence has no wake of its own, and the wake and
                    ledger fields on the row still describe the occurrence
                    before it (#38205): while the hold holds, the three
                    occurrence cells draw nothing rather than the previous
                    occurrence's clocks beside a state that reads due-now.
                    Why it holds is the Schedules list's own reading -- its
                    row carries the hold tag -- which this tab's capped-page
                    line already points the reader to. *)
                 let held = Option.is_some row.sch_runner_hold in
                 let occurrence_clock value =
                   if held then Masc_tui_theme.Glyph.no_value
                   else occurrence_clock value
                 in
                 let outcome =
                   if held then Masc_tui_theme.Glyph.no_value
                   else Terminal_text.single_line (schedule_outcome_word row)
                 in
                 "  "
                 ^ Render_schedule.kauto_row ~layout
                     ~styles:
                       ({ kstyle_mark = status_style
                        ; kstyle_status = status_style
                        ; kstyle_outcome = semantic_status_color outcome
                        ; kstyle_recurrence = Ansi.dim
                        ; kstyle_by = Theme.recede ()
                        } : Render_schedule.kauto_row_styles)
                     { Render_schedule.krow_mark =
                         Render_schedule.kauto_status_mark row.sch_status
                     ; krow_status = Terminal_text.single_line row.sch_status
                     ; krow_triggered =
                         occurrence_clock row.sch_last_wake_started_at_iso
                     ; krow_outcome = outcome
                     ; krow_received =
                         occurrence_clock row.sch_stimulus_recorded_at_iso
                     ; krow_recurrence =
                         Terminal_text.single_line row.sch_recurrence_summary
                     ; krow_by = Terminal_text.single_line row.sch_requested_by
                     ; krow_requested =
                         Terminal_text.short_timestamp row.sch_requested_at_iso
                     ; krow_what =
                         Terminal_text.single_line
                           (Option.value ~default:row.sch_schedule_id
                              row.sch_payload_summary)
                     }
               in
               (* The page's live rows, then its closed ones under a labelled
                  rule. The server sends live-first; the partition keeps each
                  group's order and makes the grouping this pane's own rather
                  than the server's sort happening to be right. *)
               let live, closed =
                 List.partition
                   (fun (row : schedule_row) ->
                      not (schedule_status_is_terminal row.sch_status))
                   rows
               in
               let closed_rule =
                 if closed = [] || live = [] then []
                 else
                   let words =
                     List.map
                       (fun (row : schedule_row) -> row.sch_status)
                       closed
                   in
                   let rec first_seen acc = function
                     | [] -> List.rev acc
                     | word :: rest ->
                         if List.mem word acc then first_seen acc rest
                         else first_seen (word :: acc) rest
                   in
                   let label =
                     Render_schedule.kauto_group_label ~title:"closed"
                       (List.map
                          (fun word ->
                             Printf.sprintf "%d %s"
                               (List.length
                                  (List.filter (String.equal word) words))
                               (Terminal_text.single_line word))
                          (first_seen [] words))
                   in
                   let lead = "  \xe2\x94\x80\xe2\x94\x80 " ^ label ^ " " in
                   let rest_cells =
                     max 0
                       (min (2 + rule_cells) inner
                          - Message_layout.display_width lead)
                   in
                   [ Theme.recede () ^ lead ^ draw_hline rest_cells
                     ^ Ansi.reset
                   ]
               in
               [ Theme.recede () ^ "  " ^ header ^ Ansi.reset
               ; Theme.recede () ^ "  " ^ draw_hline rule_cells ^ Ansi.reset
               ]
               @ List.map row_line live
               @ closed_rule
               @ List.map row_line closed)
      | Some _ | None ->
          if error_lines <> [] then []
          else [ tab_loading_row "loading this Keeper's schedules" ]
      in
      error_lines @ snapshot_lines
    in
    let run_lines () =
      let failure detail =
        (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset
      in
      let listing runs =
        "  Fusion runs · j/k:select · Enter:open · same IDs as Fusion" ::
        (if runs = [] then ["  No retained Fusion runs for this Keeper"]
         else List.mapi (fun index (run : Masc.Tui_decode_fusion.fusion_run) ->
           (* The clock the Fusion list and the run detail already draw for
              this field, rather than a second copy of its format: three
              lists show a run's start, and a copy is one that stops
              following when the other two change. *)
           Printf.sprintf "%s %s · %s · %s · %s"
             (if Option.fold ~none:false ~some:(fun (cursor, _) -> index = cursor)
                   (Masc_tui_fusion_model.selected_keeper_run state) then ">" else " ")
             (fusion_run_clock run)
             (Masc.Tui_decode_fusion.fusion_run_status_to_string run.fur_status)
             (Terminal_text.single_line run.fur_preset)
             (Terminal_text.single_line run.fur_run_id)) runs)
      in
      match Masc_tui_fusion_model.keeper_runs_view state with
      | Masc_tui_fetched.Absent -> [ Ansi.dim ^ page_unread_note ^ Ansi.reset ]
      | Masc_tui_fetched.Loading -> [ loading_row "loading Fusion runs" ]
      | Masc_tui_fetched.Failed detail -> [ failure detail ]
      (* Rows already held stay on a failed refresh, as they do on the Fusion
         surface, with the failure above them so they read as stale. *)
      | Masc_tui_fetched.Stale (runs, detail) -> failure detail :: listing runs
      | Masc_tui_fetched.Ready runs -> listing runs
    in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines ()
      | Detail_items -> item_lines ()
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
            | Some request when String.equal request.slr_keeper k.k_name ->
              [ loading_row ~started_ns:request.slr_started_ns
                  "loading actual container logs" ]
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
      | Detail_secrets -> (
          match secret_lines state k with
          | Some lines -> lines
          | None -> (
              (* The projection rides the Lanes reading. Before that reading
                 has answered, and after one that failed, the list is empty
                 for every Keeper, and this tab said "no projection reported"
                 -- an answer the server had not given. *)
              match state.lanes, state.lanes_error with
              | None, Some detail ->
                  [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ]
              | None, None -> [ tab_loading_row "loading" ]
              | Some _, _ ->
                  [ Ansi.dim ^ "  (no projection reported for this Keeper)" ^ Ansi.reset ]))
      | Detail_github ->
          let base =
            stamped_or state.github_identity_view
              state.github_identity_view_error
          in
          Masc_tui_render_github.lines
            { token_input = state.github_token_input
            ; save_status = state.github_token_save_status
            ; login_scopes = state.github_login_scopes
            }
            ~base
      | Detail_identity ->
          stamped_or
            (Option.map
               (fun (stamp, providers) ->
                 ( stamp
                 , Masc_tui_render_identity.lines ~cols
                     { keeper_name = k.k_name
                     ; providers
                     ; filter = state.identity_filter
                     ; cursor = state.identity_cursor
                     ; logins = state.identity_logins
                     ; attempt_error = state.identity_attempt_error
                     ; app_form = state.identity_app_form
                     } ))
               state.identity_view)
            state.identity_view_error
      | Detail_channels ->
          channel_lines ()
      | Detail_automation -> automation_lines ()
      | Detail_runs -> run_lines ()
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
       another tab, so a reader with no mark had a wrong guess waiting.

       Drawn through [tab_strip] with the row's width: ten tabs are wider
       than the row beside the roster pane, and cut from the right the mark
       on Runs was the part that went. *)
    let before =
      Printf.sprintf " Keepers \xe2\x96\xb8 %s%s%s%s" Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset tab_strip_gap
    in
    let tabs =
      tab_strip ~width:(tab_strip_width ~cols ~before ~after:"")
        ~press:(fun tab text -> pressable (Press_keeper_tab tab) text)
        (List.map
           (fun tab ->
             ( Masc_tui_types.keeper_detail_tab_label tab
             , tab = state.detail_tab
             , tab ))
           Masc_tui_types.keeper_detail_tabs)
    in
    let title = before ^ tabs in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
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
            (Masc_tui_fusion_model.selected_keeper_run state)
        else scroll
    in
    let all_lines_window = Rows.of_list ~first:scroll ~height:visible_lines all_lines in

    (* Real pixels go over the blank cells the band left, from the first
       content row: the lines this pane drew above it, under whatever the
       caller drew above the pane. *)
    Option.iter
      (fun band ->
        Masc_tui_keeper_portrait.placement band ~scroll ~visible_rows:visible_lines
          ~origin:
            ( origin_row + lines_ended_since buf ~start:pane_start
            , origin_col + framed_content_column )
        |> Option.iter Masc_tui_portrait_view.request)
      portrait;

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
      let indicator =
        Ansi.dim
        ^ Masc_tui_scroll.window_text ~scroll ~height:content_height total_lines
        ^ Ansi.reset
      in
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
    (* The row the Keepers list draws, through the same [footer_line]: the
       armed or running action as a status item, the keys as items the fitter
       can drop whole, [Esc] and [q] kept whatever else goes. It was cut with
       [fit_width] instead, which keeps the front and loses the back -- where
       [Left / Esc] and [q] sit -- so at 80 columns the row ended "t:c…" and
       named no way out. [key:label] for the roster pane's key too. *)
    (* The open tab's own keys lead, and a Keeper control on a key the tab
       answers itself leaves the row. They were a strip at the end of the
       title row, which the frame cut at 120 columns ("o:act…", "L:log…"),
       while this row said "s:shutdown" and "o:container logs" on the
       Sandbox tab, where [s] sets the remote_ssh backend and [o] reads the
       container logs the strip called "actual logs". *)
    let hints =
      Masc_tui_keys.keeper_detail_tab_hint state.detail_tab
      ^ "  "
      ^ keeper_control_hints
          ~taken:(Masc_tui_keys.keeper_detail_tab_taken_keys state.detail_tab)
          state (Some (keeper_reading state k))
    in
    let hints =
      if keeper_roster_pane_shown state ~cols then "h/l:pane  " ^ hints
      else hints
    in
    let footer =
      footer_line state ~status:(keeper_action_status state) ~max_cells:cols ~hints
    in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll =
        keeper_detail_pane state k ~framed:false ~rows ~cols
          ~origin:(strip_rows, 0) buf
      in
      Buffer.add_string buf footer;
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
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols
          ~origin:(strip_rows, left_cols) right_buf
      in
      write_two_panes buf ~left_cols:left_cols ~left:left_buf
        ~right:right_buf;
      Buffer.add_string buf footer;
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
      Printf.sprintf "%s  (%s)"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        (Masc_tui_message_layout.count_noun ~plural:"entries" total_entries "entry")
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    box_line_styled buf cols ~style:(Theme.recede ())
      "  TIME  KIND  LATENCY · full facts below";
    box_divider buf cols;

    let log_rows = Masc_tui_types.keeper_log_rows state ~cols in
    let row_count = List.length log_rows in
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:None
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:row_count ~content_height
        (if state.log_wrap_cols = Some cols then state.log_scroll else 0)
    in
    let visible = Rows.of_list ~first:scroll ~height:content_height log_rows in
    for index = 0 to content_height - 1 do
      if row_count = 0 && index = 0 then
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Metrics_tail.empty_message state.log_error)
      else
        match Rows.at visible (scroll + index) with
        | Some (diagnostic, line) ->
            let style = match diagnostic with
              | None -> Ansi.reset
              | Some (Metrics_tail.Storage_error _) -> Theme.bad ()
              | Some (Metrics_tail.Row_errors _) -> Theme.warn ()
              | Some (Metrics_tail.Remote_workspace | Metrics_tail.Workspace_unconfirmed) ->
                  Theme.recede () in
            box_line_styled buf cols ~style line
        | None -> box_empty buf cols
    done;
    if row_count > content_height then
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "newest rows %d-%d of %d" (scroll + 1)
           (min row_count (scroll + content_height)) row_count);

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints state.view));

    finish_surface state ~clamped:(Keeper_logs_scroll { scroll; cols })
      ~surface_key:"keeper-logs" ~rows:terminal_rows
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
  | [] -> [ style, prefix ^ Masc_tui_theme.Glyph.no_value ]
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
      let turn =
        Option.map string_of_int entry.sl_turn
        |> Option.value ~default:Masc_tui_theme.Glyph.no_value
      in
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
        (* One name for the section, whichever branch draws it: the empty
           branch called it "Details" and the other "Structured details", so
           the same part of the pane answered to two names depending on
           whether it had anything in it. Caps for the heading, the way every
           other detail pane spells one. *)
        match entry.sl_details with
        | `Null -> [ Ansi.dim, "  STRUCTURED DETAILS  none" ]
        | json ->
            let source =
              "```json\n" ^ Yojson.Safe.pretty_to_string json ^ "\n```"
            in
            (Ansi.bold, "  STRUCTURED DETAILS")
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
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:true System_logs));
  finish_surface state ~clamped:(System_log_detail_scroll scroll)
    ~surface_key:"system-log-detail" ~rows:terminal_rows ~cols buf

(* Which of Activity's two readings is on screen. Drawn the way the other two
   tab strips in this product draw it -- a mark on the one you are on, the
   names beside it -- rather than the third spelling it had: [1 Events |
   2 Logs*], where a "*" moved between two hand-written literals and the keys
   were spelled into the title.

   Three literals carried that strip and two of them spelled it one way and one
   the other, so the mark and the surface could disagree and nothing would say
   so. The keys leave with it: the Activity footer projects from the key table,
   which names 1 / 2 there, and no other surface puts its keys in its title. *)
let activity_tab_strip ~cols ~on_logs ~after =
  tab_strip
    ~width:
      (tab_strip_width ~cols
         ~before:(screen_title " MASC Activity" ^ tab_strip_gap) ~after)
    ~press:(fun surface text -> pressable (Press_surface surface) text)
    [ ("Events", not on_logs, Acting); ("Logs", on_logs, System_logs) ]

(* The title: the strip, then what the reading on screen holds, after a dot.
   The count used to follow the strip directly, so on Events it sat against
   the tab that is not open -- "▸Events  Logs (0 rows · 0 events held)" -- and read
   as that tab's count. It stays after the strip rather than moving before it,
   so the tabs do not shift sideways when the count grows a digit. *)
(* [after] is what the caller draws past this title on the same row -- the
   clock and the badge -- so the strip can leave room for it. *)
let activity_title ~cols ~on_logs ~after reading =
  let strip =
    activity_tab_strip ~cols ~on_logs
      ~after:(Printf.sprintf "  \xc2\xb7  %s%s" reading after)
  in
  (* The dot is the strip's, not the row's. It was a literal in this format
     string, so when the row ran out of width and the strip drew nothing the
     dot stayed: at 56 columns the title read "MASC Activity    \xc2\xb7  (0 rows
     \xc2\xb7 0 events held)", a separator with its left side missing. A strip that
     draws nothing takes its separator with it. *)
  let strip_part =
    if Masc_tui_message_layout.display_width strip = 0 then ""
    else Printf.sprintf "  %s  \xc2\xb7" strip
  in
  Printf.sprintf "%s%s  %s" (screen_title " MASC Activity") strip_part reading

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
     says why it is twelve rather than reading as a quiet ring.

     [verbose] is not a second field: [v] and [l] write the one floor, and
     verbose is the floor being DEBUG. The header spent thirteen cells saying
     that a second time, on a row that drops the tab strip at a hundred
     columns and the connection badge below eighty. *)
  let filter_note =
    let level =
      match state.system_logs_min_level with
      | None -> "  level\xe2\x89\xa5DEBUG"
      | Some floor ->
          Printf.sprintf "  level\xe2\x89\xa5%s"
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
  (* What the reader set, on a read that brought back nothing. [l] and [v]
     write the floor and refetch; with the fetch failing the rows are the only
     other thing that moves, so pressing either redrew a frame identical to
     the one before it. The default floor is not something anyone pressed, and
     the note's other job -- saying why a short page is short -- needs a page,
     so at the default this stays off the row rather than spending its width
     on the surface that has least to spare. *)
  let set_filter_note =
    match state.system_logs_min_level, state.system_logs_category with
    | None, None -> ""
    | _ -> filter_note
  in
  let header =
    match state.system_logs with
    | None ->
        let reading_note =
          match state.system_logs_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s"
          (activity_title ~cols ~on_logs:true
             ~after:(Printf.sprintf "  %s  %s" timestamp (connection_badge state))
             (reading_note ^ set_filter_note))
          timestamp (connection_badge state)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        Printf.sprintf "%s  %s  %s"
          (activity_title ~cols ~on_logs:true
             ~after:(Printf.sprintf "  %s  %s" timestamp (connection_badge state))
             (Printf.sprintf "(%d of %d, seq %d)%s" total_entries
                snapshot.sys_total snapshot.sys_latest_seq filter_note))
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* The message takes what the named columns leave, asked of the columns. *)
  let log_layout =
    Render_schedule.system_log_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.system_log_header_row ~layout:log_layout
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.system_logs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The scroll row is a frame row while the page holds more entries than
     fit, and only then; the layout the keypress reads says so. *)
  let content_height =
    match scrolled_surface state ~cols System_logs with
    | Some s ->
        Masc_tui_scroll.content_height ~rows ~chrome:s.sc_chrome ~count:s.sc_count
          ~preview_keep:s.sc_preview_keep ~overflow_takes_row:s.sc_overflow_takes_row
    | None -> max 1 (rows - listing_chrome ~error:state.system_logs_error)
  in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min state.system_logs_scroll max_scroll) in
  let entries_window = Rows.of_list ~first:scroll ~height:content_height entries in
  if total_entries = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.system_logs ~error:state.system_logs_error
      with
      (* [empty_page_of] returns [Page_failed] for an error with no snapshot
         and for an error over one, so a note about the title's count is true
         only in the second: with no snapshot the header draws no count at
         all and the note pointed at a row that is not on the screen. The
         shared note holds in both, and the staleness is already said twice
         above -- by the badge and by the error row this listing draws. *)
      | Page_failed -> page_failed_note
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
            match e.sl_keeper with None -> Masc_tui_theme.Glyph.no_value | Some name -> name
          in
          let category = system_log_category_text e in
          let level_style = system_log_level_style e.sl_level in
          (* Every cell is fitted to the width its header is drawn at; a long
             module name used to push every column right of it out of line. *)
          let line =
            "  "
            ^ Render_schedule.system_log_row ~layout:log_layout ~level_style
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
      (Printf.sprintf "[entries %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height total_entries));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view));
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
        let reading_note =
          match state.verification_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        let after =
          Printf.sprintf "  %s  %s  %s" reading_note timestamp
            (connection_badge state)
        in
        Printf.sprintf "%s%s"
          (planning_workspace_title state ~cols ~tab:Planning_task_review ~window:""
             ~after)
          after
    | Some snapshot ->
        (* Both numbers, for the same reason the log surface shows both: "12"
           beside a list of 12 would read as "that is all of them".

           Except when the tab's own badge already carries the total: it
           wears the count once the queue is above zero, and a page holding
           the whole queue then read "Task Review·2 (2 of 2)". The window
           stays for a cut page, where it says how much of the badge's number
           is on screen, and for an empty read, which has no badge to say
           the read happened at all. *)
        let total = snapshot.Masc.Tui_decode.vs_total in
        let window =
          if total > 0 && shown >= total then ""
          else Printf.sprintf " (%d of %d)" shown total
        in
        Printf.sprintf "%s  %s  %s"
          (planning_workspace_title state ~cols ~tab:Planning_task_review ~window
             ~after:(Printf.sprintf "  %s  %s" timestamp (connection_badge state)))
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
  let title_width =
    Render_schedule.verification_title_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
      ~submitter_width
  in
  let col_hdr =
    "  " ^ Render_schedule.verification_header_row ~submitter_width ~title_width
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The height the keypress bounds its step with, asked of the same layout:
     it counts the rows drawn under the list as well as the frame. *)
  let content_height =
    match scrolled_surface state ~cols Verification with
    | Some layout ->
        Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
          ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
          ~overflow_takes_row:layout.sc_overflow_takes_row
    | None -> max 1 (rows - listing_chrome ~error:state.verification_error)
  in
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
            "  "
            ^ Render_schedule.verification_row ~submitter_width ~title_width
                { Render_schedule.vrow_task =
                    Terminal_text.single_line r.vr_task_id
                ; vrow_submitted_by =
                    Terminal_text.single_line r.vr_submitted_by
                ; vrow_evidence = evidence
                ; vrow_title = Terminal_text.single_line asks
                }
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
  (* Which list this is, and where in it -- drawn on every read rather than
     only on a cut page. The same row count means "nothing else is waiting" in
     the queue and "the newest page of what was ever submitted" in the
     history, and the rows themselves do not say which. *)
  (match state.verification with
   | None -> ()
   | Some snapshot ->
       let total = snapshot.Masc.Tui_decode.vs_total in
       let offset = snapshot.Masc.Tui_decode.vs_offset in
       let place =
         match snapshot.Masc.Tui_decode.vs_view with
         | Masc.Tui_decode.Awaiting_queue -> Printf.sprintf "awaiting %d" total
         | Masc.Tui_decode.Full_history ->
             if shown = 0 then Printf.sprintf "history 0 of %d" total
             else
               Printf.sprintf "history %d-%d of %d" (offset + 1)
                 (offset + shown) total
       in
       let rows_window =
         if shown > content_height then
           Printf.sprintf " \xc2\xb7 rows %s"
             (Masc_tui_scroll.window_text ~scroll ~height:content_height shown)
         else ""
       in
       (* Named because the key is not on the footer of a narrow terminal, and
          a page with more behind it that says so is the difference between
          "that is all" and "there is more". *)
       let more =
         if snapshot.Masc.Tui_decode.vs_truncated then " \xc2\xb7 > next page"
         else ""
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "[%s%s%s]" place rows_window more);
       (* An empty queue carrying a reason is not an empty queue. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_error with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.bad ())
              (Printf.sprintf "  the queue could not be read: %s"
                 (Terminal_text.single_line detail))
        | None -> ());
       (* A queue built from a recovery snapshot is a queue of real rows that
          is older than the workspace. Drawn, because the rows themselves look
          exactly like a current queue and nothing else on this screen would
          say otherwise. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_recovery with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "  this queue is as old as the snapshot it came from: %s"
                 (Terminal_text.single_line detail))
        | None -> ());
       (* A task waiting on a record the store does not hold cannot be moved
          from this surface, and no other surface says so either. *)
       (match snapshot.Masc.Tui_decode.vs_awaiting_unresolved with
        | [] -> ()
        | ids ->
            let named = List.filteri (fun i _ -> i < 3) ids in
            (* The list is one page; the total counts them all. *)
            let rest =
              snapshot.Masc.Tui_decode.vs_awaiting_unresolved_total
              - List.length named
            in
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "  waiting on a record this store does not hold: %s%s"
                 (String.concat ", " named)
                 (if rest > 0 then Printf.sprintf " (+%d)" rest else ""))));
  (* The arm and the server's last refusal sit under the list, the same rows
     the schedule cancel carries them on. *)
  (match state.verification_verdict_armed with
   | Some (task_id, request_id) ->
       (* No width padding on the id: padding to a reserved column pushes the
          "same key again" tail past the box on a narrow terminal, and the
          tail is the half that instructs. *)
       box_line buf cols
         ((Theme.warn ())
         ^ Printf.sprintf "  armed: approve %s -- same key again to send [%s]"
             (Terminal_text.single_line task_id)
             (Terminal_text.single_line request_id)
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
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

(* Complete judgement metadata is a physical document. Rows that fit keep
   their field alignment; longer rows remain literal and reachable by scroll. *)
let judgement_detail_rows ~width lines =
  List.concat_map
    (fun (style, text) ->
       if Message_layout.display_width text <= width then [style, text]
       else Message_layout.wrap_words ~max_cells:(max 1 width) text
            |> List.map (fun row -> style, row)) lines

let verification_detail_lines ~width
    (request : Masc.Tui_decode.verification_request) =
  let field label value =
    ( Ansi.reset
    , Printf.sprintf "  %-15s %s" label (Terminal_text.single_line value) )
  in
  let wrapped_block label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body
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
  ; field "Created" (Terminal_text.short_timestamp request.vr_created_at)
  ; Ansi.dim, ""
  ]
  (* [Kind], [What is being judged] and [What moves it forward] stood here.
     Their three fields were literals in the producer -- "normal", "" and "" --
     so the three rows read the same on every request this pane has ever
     drawn, two of them as "No X was recorded". The pane already tells a
     reader how to read the request from its artifacts and evidence, which is
     what those rows were pointing away from. *)
  @ [ Ansi.dim, ""; Ansi.bold, "  HOW TO READ THIS" ]
    (* Wrapped like the evidence items under it. As one row it was cut at
       "what the verifier can …" beside the roster pane, and a reading
       instruction that stops mid-sentence instructs nothing. *)
  @ (Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
       ~sanitize:Keeper_chat.terminal_safe_text
       "Required artifacts say what must exist. Submitted evidence says what the verifier can inspect now."
     |> List.map (fun line -> Ansi.dim, "    " ^ line))
  @ [ Ansi.dim, ""
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
                | Masc.Tui_decode.Ev_collaboration {ev_reference; ev_content; ev_sha256} ->
                    ((Ansi.reset, Printf.sprintf "    - submitted source %s (sha256 %s)"
                        (Terminal_text.single_line ev_reference) ev_sha256)
                     :: wrap ~prefix:"      " ev_content)
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
            (* The producer's reason is already the evidence access verdict. *)
            wrap ~prefix:"    " reason
        | Error (Masc_tui_types.Verification_evidence_read.Transport detail) ->
            (* The transport boundary already says "GET failed". *)
            wrap ~prefix:"    " detail
        | Error (Masc_tui_types.Verification_evidence_read.Http_error detail) ->
            wrap ~prefix:"    Read failed: " detail
        | Error (Masc_tui_types.Verification_evidence_read.Invalid_json detail) ->
            wrap ~prefix:"    Invalid JSON: " detail
        | Error (Masc_tui_types.Verification_evidence_read.Invalid_payload detail) ->
            wrap ~prefix:"    Decode failed: " detail
        | Error (Masc_tui_types.Verification_evidence_read.Launch_failure detail) ->
            wrap ~prefix:"    Read failed: " detail)
    | _ -> [ Ansi.dim, "    loading..." ]
  in
  (Ansi.dim, "") :: (Ansi.bold, "  EVIDENCE CONTENT") :: rows

let verification_detail_pane (state : state) ~rows ~cols request buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s"
       (planning_workspace_title state ~cols ~tab:Planning_task_review ~window:""
          ~after:
            (Printf.sprintf " \xe2\x96\xb8 details  %s"
               (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id))
        ^ " \xe2\x96\xb8 details")
       (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id));
  box_divider buf cols;
  let width = max 1 (framed_inner_width cols) in
  let armed_note =
    match state.verification_verdict_armed with
    | Some (task_id, request_id)
      when String.equal task_id request.Masc.Tui_decode.vr_task_id
           && String.equal request_id request.vr_request_id ->
        Some (Printf.sprintf "  ARMED: a again to approve %s [%s]"
          (Terminal_text.single_line task_id)
          (Terminal_text.single_line request_id))
    | Some _ | None -> None
  in
  let lines =
    verification_detail_lines ~width request
    @ verification_evidence_lines state ~width request.Masc.Tui_decode.vr_task_id
    @ (match armed_note with None -> [] | Some note -> [Theme.warn (), note])
    @ (match state.verification_verdict_error with
       | None -> []
       | Some detail -> [Theme.bad (), "  Verdict action failed: " ^ Terminal_text.single_line detail])
    |> judgement_detail_rows ~width
  in
  let verdict_action = "  a twice: approve; x: reject with reason" in
  let verdict_action_rows =
    if Message_layout.display_width verdict_action <= width then
      [ verdict_action ]
    else [ "  a twice: approve"; "  x: reject with reason" ]
  in
  (* The position and action rows are fixed chrome; subtract exactly what
     this pane draws so the reported window matches the visible body. *)
  let fixed_rows =
    1 + List.length verdict_action_rows
      + (if Option.is_some armed_note then 1 else 0)
      + (if Option.is_some state.verification_verdict_error then 1 else 0)
  in
  let content_height = max 1 (rows - framed_chrome_rows - fixed_rows) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.verification_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  Option.iter
    (fun note -> box_line_styled buf cols ~style:(Theme.warn ())
      (fit_width note (cols - 4)))
    armed_note;
  Option.iter
    (fun err -> box_line_styled buf cols ~style:(Theme.bad ())
      (fit_width ("  " ^ Terminal_text.single_line err) (cols - 4)))
    state.verification_verdict_error;
  (* This reading has its own pane row: pinned footer keys can consume the
     whole footer at 30 and 40 columns, leaving its trailing position cut. *)
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  [rows %s]"
       (Masc_tui_scroll.window_text ~scroll ~height:content_height
          (List.length lines)));
  List.iter
    (box_line_styled buf cols ~style:(Theme.warn ()))
    verdict_action_rows;
  box_bottom buf cols;
  scroll
;;

(* The queue stays beside the request under review. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_verification_detail (state : state) request =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll =
    if cols < keeper_split_threshold_cols then
      verification_detail_pane state ~rows ~cols request buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.verification with
        | None -> []
        | Some snapshot ->
          List.map
            (fun (row : Tui_decode.verification_request) ->
              (* The request id is one per row and never moves. The age it
                 replaced rounded two requests six minutes apart to the same
                 "1d12h", and spelled seconds under an hour, so an index row
                 changed while the reader was looking at it. *)
              Render_schedule.task_history_sidebar_label
                ~task_id:row.Tui_decode.vr_task_id
                ~apart:(Some row.Tui_decode.vr_request_id))
            snapshot.Tui_decode.vs_requests
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* One server page: the list screen next door draws "history 1-50 of
         664" off the same snapshot, and this index drew "(50)". *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Task Review"
        ~focused:false
        ~holding:
          (Option.map
             (fun (snapshot : Tui_decode.verification_snapshot) ->
               snapshot.Tui_decode.vs_total)
             state.verification)
        ~labels ~selected:state.verification_cursor;
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
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:true state.view));
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
            ; row_with_field ~cols
                ~lead:(Printf.sprintf "  %sgate%s    " Ansi.dim Ansi.reset)
                ~field:gates ~tail:""
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
        let reading_note =
          match state.harness_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        let after =
          Printf.sprintf "  %s  %s  %s" reading_note timestamp
            (connection_badge state)
        in
        Printf.sprintf "%s%s"
          (planning_workspace_title state ~cols ~tab:Planning_verdicts ~window:""
             ~after)
          after
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
          (planning_workspace_title state ~cols ~tab:Planning_verdicts
             ~window:
               (Printf.sprintf " (%d%s%s)" shown of_total by_fallback)
             ~after:(Printf.sprintf "  %s  %s" timestamp (connection_badge state)))
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
  (* The reason takes the cells the drawn columns leave. *)
  let verdict_layout =
    Render_schedule.harness_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.harness_header_row ~layout:verdict_layout
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.harness_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* Every row above the list, counted off the buffer they were drawn into
     rather than declared beside them. The constant said seven where the head
     draws nine: rows were added above the list and the number was not, so the
     surface ran three rows past its budget. [finish_surface] takes an overrun
     off the end, and the end of this surface is its footer -- the screen drew
     no key hints at all, at every terminal height. The ledger block is a list
     whose length varies, which is why this is measured and not counted by
     hand. *)
  let head_rows = count_frame_lines buf in
  (* The rows still to come under the list: the frame's closing row and the
     footer. Drawn now so their height is the same measured fact. *)
  let tail = Buffer.create 256 in
  box_bottom tail cols;
  let link_hint =
    match List.nth_opt verdicts state.harness_cursor with
    | None -> ""
    | Some verdict ->
        "  selected:"
        ^ Link.reference Task
            (Terminal_text.single_line verdict.Masc.Tui_decode.hv_task_id)
  in
  Buffer.add_string tail
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~detail_open:false state.view ^ link_hint));
  let room = max 1 (rows - head_rows - count_frame_lines tail) in
  (* The window reading costs one of the rows it describes. *)
  let content_height = if shown > room then max 1 (room - 1) else room in
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
                  ~verdict_style:(semantic_status_color ruling)
                  ~layout:verdict_layout
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
      (Printf.sprintf "[verdicts %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  Buffer.add_buffer buf tail;
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

(* Which goals the judged task serves, and what those goals are aiming at.
   The verdict names a task, the task names its goals, and a goal carries the
   metric it is measured by -- three hops that were all present and never
   walked, so a verdict said "pass" without saying what it was passing
   towards. *)
let harness_goal_lines (state : state) (verdict : Masc.Tui_decode.harness_verdict) =
  let goal_of id =
    Option.bind state.planning (fun snapshot ->
      List.find_opt
        (fun (goal : Tui_decode.planning_goal) -> String.equal goal.pg_id id)
        snapshot.Tui_decode.pl_goals)
  in
  match task_goal_reading state ~task_id:verdict.hv_task_id with
  | Masc_tui_agenda.Not_read ->
    [ Ansi.dim, "  Towards      goal links not read" ]
  | Read_failed _ ->
    [ Ansi.dim, "  Towards      goal links unavailable" ]
  | Read [] ->
    (* Two different silences, told apart. A task this screen has never seen
       (the backlog has not loaded, or the verdict judged something already
       archived) is not the same as a task that serves no goal, and drawing
       nothing for both leaves the reader unable to tell which. *)
    let known_task =
      List.exists
        (fun (row : Masc_domain.task) -> String.equal row.id verdict.hv_task_id)
        state.tasks_domain
    in
    if known_task then
      [ Ansi.dim, "  Towards      this task is not linked to a goal" ]
    else
      [ Ansi.dim, "  Towards      the judged task is not in this backlog" ]
  | Read goal_ids ->
    (Ansi.bold, "  TOWARDS")
    :: List.concat_map
         (fun id ->
           match goal_of id with
           | None ->
             (* Linked to a goal this snapshot does not carry -- terminal, or
                simply not in the page that was fetched. Named rather than
                dropped: the link is a fact even when the goal is not here. *)
             [ Ansi.reset, Printf.sprintf "  %-12s %s" "Goal" (Terminal_text.single_line id)
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
             ; Ansi.reset, Printf.sprintf "  %-12s %s" "Aim" (Terminal_text.single_line aim)
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
    :: (Message_layout.wrap_body
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
    (harness_detail_heading state ~cols
       ~task_id:verdict.Masc.Tui_decode.hv_task_id
       ~tail:(connection_badge state));
  box_divider buf cols;
  let lines =
    harness_detail_lines ~width:(max 1 (framed_inner_width cols)) verdict
    (* Appended rather than woven in: the verdict block is what the server
       said, and what the task is aiming at is read from two other surfaces.
       Keeping them in that order keeps the judged fact above the context. *)
    @ (match harness_goal_lines state verdict with
       | [] -> []
       | goal_lines -> (Ansi.dim, "") :: goal_lines)
    |> judgement_detail_rows ~width:(max 1 (framed_inner_width cols))
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
  (* A position, not a key. Packed into the hints string it was read as a key
     item and dropped from the back before any of them, so the one screen that
     exists for reading a ruling in full never said which part of it was on
     screen -- at a hundred, a hundred and thirty and a hundred and sixty
     columns alike. *)
  ( scroll
  , Some
      (Masc_tui_scroll.window_text ~scroll ~height:content_height
         (List.length lines)) )
;;

(* The verdict list stays beside the verdict. A verdict is a judgement
   about one task among many, and which ones came out the same way is
   most of what it means. Below the split width the detail keeps the
   screen. *)
let render_harness_detail (state : state) verdict =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, position =
    if cols < keeper_split_threshold_cols then
      harness_detail_pane state ~rows ~cols verdict buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.harness with
        | None -> []
        | Some snapshot ->
          (* A verdict has no id of its own on the wire. The notes hash is
             shared by repeat verdicts on one submission, and a clock alone
             can name several verdicts recorded in the same second. *)
          snapshot.Tui_decode.hs_verdicts
          |> List.map (fun (row : Tui_decode.harness_verdict) ->
               row.hv_task_id, lane_run_clock row.hv_at)
          |> Render_schedule.verdict_sidebar_labels
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* The harness snapshot carries its verdicts whole; there is no page
         behind them. *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Verdicts"
        ~focused:false ~holding:None ~labels ~selected:state.harness_cursor;
      let answer =
        harness_detail_pane state ~rows ~cols:(cols - left_cols) verdict
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (* The key table, not a literal. This row was written out here, and what
       it left out was the pair that answers a ruling -- [y / x] -- on the one
       screen that exists for reading a ruling in full. It also left out
       [[ / ]], which the dispatcher answers here and only here. *)
    (footer_line state ~max_cells:cols ?position
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:true Masc_tui_types.Harness));
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
  (* The status column has room for the word and not for the cause, and a
     repository whose clone or fetch failed keeps that cause in its status.
     The row says "error" and this says what it was; every other status has
     nothing here to add. *)
  let failure =
    match Masc.Tui_decode.repository_status_reason repo.rp_status with
    | None -> []
    | Some reason -> wrap "Error" reason
  in
  failure
  @ wrap "Path" repo.rp_resolved_local_path
  @ stored_path
  @ wrap "Keepers" keepers

type workspace_activity_column = Activity_date | Activity_keeper | Activity_task | Activity_result | Activity_path

let workspace_activity_cells ~cols ~date ~keeper ~task ~result ~path =
  let width = function
    | Activity_date -> 16 | Activity_keeper -> 18 | Activity_task -> 16
    | Activity_result -> String.length "RESULT" | Activity_path -> 8 in
  let layout = Masc_tui_table.fit ~inner_width:(max 1 (framed_inner_width cols - 2))
    ~width ~flex:Activity_path ~drop_order:[Activity_task; Activity_date; Activity_keeper]
    [Activity_date; Activity_keeper; Activity_task; Activity_result; Activity_path] in
  List.map (fun column ->
    let header, value, fold = match column with
      | Activity_date -> "DATE", date, Masc_tui_table.Fold_tail
      | Activity_keeper -> "KEEPER", keeper, Masc_tui_table.Fold_middle
      | Activity_task -> "TASK", task, Masc_tui_table.Fold_middle
      | Activity_result -> "RESULT", result, Masc_tui_table.Fold_tail
      | Activity_path -> "FILE", path, Masc_tui_table.Fold_middle in
    Masc_tui_table.cell ~header ~fold
      ~width:(if column = Activity_path then layout.flex_width else width column) value) layout.shown

let render_workspace_activity (state : state) repo_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows, cursor, selected = workspace_activity_selection state in
  let title = match state.workspace_activity_context_scroll with
    | None -> " MASC Workspace / Activity · " ^ Terminal_text.single_line repo_id
    | Some requested ->
        let count = List.length (workspace_activity_context_lines state ~cols) in
        let height = workspace_activity_context_height state
          ~surface_rows:(surface_body_rows state ~terminal_rows) in
        let scroll = max 0 (min requested (max 0 (count - height))) in
        " Context [" ^ Masc_tui_scroll.window_text ~scroll ~height count ^ "]" in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"workspace-activity"
    ~title:(screen_title title)
    ~hints:(match state.workspace_activity_context_scroll with
      | None -> "v:context  j/k:select  PgUp/PgDn:page  Enter:file  r:refresh  Esc:back"
      | Some _ -> "j/k:scroll  PgUp/PgDn:page  Home/End:edges  Enter:file  r:refresh  Esc:list")
    ~body:(fun ~budget c ->
      let listing ~budget reading =
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
          let cells = workspace_activity_cells ~cols in
          c.push ("  " ^ Masc_tui_table.header_row (cells ~date:"" ~keeper:"" ~task:"" ~result:"" ~path:""));
          c.push_divider ();
          let room = max 1 (budget - 7) in
          let first = max 0 (cursor - room + 1) in
          let rows_window = Rows.of_list ~first:first ~height:room rows in
          for i = 0 to room - 1 do
            match Rows.at rows_window (first + i) with
            | None -> if i = 0 && rows = [] then c.push "  No recorded clone writes in this window" else c.push_empty ()
            | Some (change, path) ->
                let tm = Unix.localtime change.Tui_decode.fc_at in
                let date = Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                  (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min in
                let task = match change.fc_task_id with None -> "unlinked" | Some id -> id in
                let line = "  " ^ Masc_tui_table.row (cells ~date
                  ~keeper:(Terminal_text.single_line change.fc_keeper)
                  ~task:(Terminal_text.single_line task)
                  ~result:(if change.fc_succeeded then "ok" else "failed")
                  ~path:(Terminal_text.single_line path)) in
                if first + i = cursor then c.push_selected line else c.push line
          done;
          c.push_divider ();
          c.push (match selected with
            | None -> "  Task and file links appear when a recorded change names them"
            | Some (_, path) ->
                "  v:context · " ^ Message_layout.fit_middle
                  (max 1 (framed_inner_width cols - Message_layout.display_width "  v:context · "))
                  (Terminal_text.single_line path))
      in
      let show ~budget reading = match state.workspace_activity_context_scroll with
        | None -> listing ~budget reading
        | Some requested ->
            let lines = workspace_activity_context_lines state ~cols in
            let scroll = max 0 (min requested (max 0 (List.length lines - budget))) in
            let window = Rows.of_list ~first:scroll ~height:budget lines in
            for index = 0 to budget - 1 do
              match Rows.at window (scroll + index) with
              | None -> c.push_empty () | Some line -> c.push line
            done in
      match Masc_tui_fetched.view_for ~equal:String.equal state.workspace_activity ~key:repo_id with
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> c.push "  Reading recorded file changes..."
      | Masc_tui_fetched.Failed message -> c.push_styled ~style:(Theme.bad ()) ("  " ^ Terminal_text.single_line message)
      | Masc_tui_fetched.Ready reading -> show ~budget reading
      (* The changes already read stay, with the failed refresh above them so
         they read as the last good reading rather than a fresh one. *)
      | Masc_tui_fetched.Stale (reading, message) ->
          c.push_styled ~style:(Theme.bad ())
            ("  Refresh failed, showing the last read: " ^ Terminal_text.single_line message);
          show ~budget:(max 1 (budget - 1)) reading)

let repository_studio_geometry (state : state) ~cols ~budget ~cursor =
  let repos = match state.repositories with
    | None -> [] | Some snapshot -> snapshot.rs_repositories in
  let shown = List.length repos in
      let width = framed_inner_width cols in
      let named_width =
        Render_schedule.workspace_minimum_width + 4
      in
      let detail_minimum = Message_layout.display_width "Keepers: none assigned" + 4 in
      let split = width >= named_width + detail_minimum + 2 && budget >= 8 in
      let detail_width = if split then min (width - named_width - 2) (max detail_minimum (width / 3)) else width in
      let list_width = if split then width - detail_width - 2 else width in
      let selected = List.nth_opt repos cursor in
      let context_lines = match selected with
        | None -> []
        | Some repo -> repository_context_lines ~width:(detail_width - 4) repo in
      let detail_title = match selected with
        | None -> "Selected repository"
        | Some repo -> Terminal_text.single_line repo.rp_name in
      let errors = match state.repositories_error with
        | None -> []
        | Some detail ->
            Message_layout.wrap_words ~max_cells:(max 1 (list_width - 4))
              (Terminal_text.single_line detail)
            |> List.map (fun line -> Theme.bad () ^ line ^ Ansi.reset) in
      (* Keep the header, panel edges and a selected repository visible.
         The stacked layout also needs the selected-context panel edges. *)
      let error_budget = max 0 (budget - if split then 4 else 6) in
      let errors =
        if List.length errors <= error_budget then errors
        else List.take (max 0 (error_budget - 1)) errors
          @ (if error_budget > 0 then ["More error detail · enlarge terminal"] else []) in
      let context_budget = max 0 (if split then budget - 2 else budget - 6 - List.length errors) in
      let truncated = List.length context_lines > context_budget in
      let show_notice = truncated && context_budget >= 2 in
      let visible_context =
        List.take (max 0 (context_budget - if show_notice then 1 else 0)) context_lines in
      let detail = studio_panel ~width:detail_width ~title:detail_title
          ~lines:(visible_context @
            (if show_notice
             then ["More context · enlarge the terminal"] else [])) in
      let list_budget =
        if split then budget else max 4 (budget - List.length detail) in
      let room = max 1 (list_budget - 3 - List.length errors) in
      let overflowing = shown > room && room > 1 in
      let content_height = if overflowing && room > 1 then room - 1 else room in
  (split, list_width, detail_width, detail, errors, content_height, overflowing)

let repository_studio_content_height state ~cols ~budget ~cursor =
  let _, _, _, _, _, content_height, _ =
    repository_studio_geometry state ~cols ~budget ~cursor in
  content_height

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
        let reading_note =
          match state.repositories_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Workspace") reading_note timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Workspace") shown timestamp
          (connection_badge state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"repositories"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      let split, list_width, detail_width, detail, errors, content_height, overflowing =
        repository_studio_geometry state ~cols ~budget ~cursor:state.repositories_cursor in
      let repository_layout = Render_schedule.workspace_layout
          ~inner_width:(max 1 (list_width - 4)) in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min max_scroll
          (Masc_tui_scroll.ensure_visible ~cursor:state.repositories_cursor
             ~height:content_height state.repositories_scroll)) in
      let repos_window = Rows.of_list ~first:scroll ~height:content_height repos in
      let lines =
        if shown = 0 then
          [match empty_page_of ~snapshot:state.repositories ~error:state.repositories_error with
           | Page_failed -> page_failed_note
           | Page_unread -> page_unread_note
           | Page_empty -> "(no repositories registered)"]
        else List.init content_height (fun i ->
          let idx = i + scroll in
          match Rows.at repos_window idx with
          | None -> ""
          | Some r ->
              let line = Render_schedule.workspace_row ~layout:repository_layout
                { Render_schedule.wrow_name = Terminal_text.single_line r.rp_name
                ; wrow_branch = Terminal_text.single_line r.rp_default_branch
                ; wrow_status = Terminal_text.single_line
                    (Masc.Tui_decode.repository_status_word r.rp_status)
                ; wrow_sync = if r.rp_auto_sync then "auto" else "manual"
                ; wrow_path = Terminal_text.single_line r.rp_resolved_local_path } in
              if idx = state.repositories_cursor then
                Theme.selection ^ fit_width line (list_width - 4) ^ Ansi.reset
              else line)
      in
      let lines = [Theme.recede () ^ Render_schedule.workspace_header_row ~layout:repository_layout ^ Ansi.reset]
        @ errors @ lines
        @ (if overflowing then
             ["repositories " ^ Masc_tui_scroll.window_text ~scroll ~height:content_height shown]
           else []) in
      let listing = studio_panel ~width:list_width ~title:"Repositories · j/k select" ~lines in
      if split then begin
        let height = max (List.length listing) (List.length detail) in
        let count = min budget height in
        (* Both panels through the list-window helper the scroll panes read:
           one array per panel, each row reads its own cells. No row of the
           loop walks either list to find itself -- the walk is what #40177's
           for-shaped zip left here, and it survives a [List.init] reshape,
           so the guard going green on that reshape would have been the
           shape leaving, not the walk. *)
        let left = Rows.of_list ~first:0 ~height:count listing in
        let right = Rows.of_list ~first:0 ~height:count detail in
        for index = 0 to count - 1 do
          c.push
            (fit_width (Option.value (Rows.at left index) ~default:"") list_width
            ^ "  "
            ^ fit_width (Option.value (Rows.at right index) ~default:"")
                detail_width)
        done
      end else begin
        List.iter c.push listing;
        List.iter c.push detail
      end)

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
        detail_heading ~cols ~lead:(Lead_text " MASC Git Changes — ")
          ~id:scope_name
          ~after:(Printf.sprintf " (%d)" (List.length changes))
          ~tail:(connection_badge state)
      in
      let selected_path =
        match List.nth_opt changes state.repository_changes_cursor with
        | Some row -> Some row.rc_path
        | None -> None
      in
      let change_ctx = resolve_change_context state ~path_opt:selected_path in
      let context_lines = build_change_context_lines change_ctx in
      surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"repository-changes"
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
  let open Masc.Tui_decode_memory_health in
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
        let reading_note =
          match state.memory_health_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Memory") reading_note timestamp
          (connection_badge state)
    | Some s ->
        Printf.sprintf "%s · %s · %s need memory · read %s  %s"
          (screen_title " MASC Memory") (Masc_tui_message_layout.count_noun shown "keeper")
          (match current_memory_starving_count s with
           | Some count -> string_of_int count
           | None -> "? (unread rows)")
          (let tm = Unix.localtime s.mhs_generated_at in
           Printf.sprintf "%04d-%02d-%02d %02d:%02d"
             (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
             tm.Unix.tm_hour tm.Unix.tm_min)
          (connection_badge state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"memory"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      Render_memory.render_memory_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

(* The Memory facts list's [Enter] reading: the whole fact wrapped to this
   overlay's own width and windowed, instead of the narrow block the list
   draws under the row. Same lines, more columns and more rows, and a scroll
   of its own -- the list stays behind it and is redrawn when it closes.

   It wears the shared overlay chrome, [Chrome_overlay], the frame the contract
   names for a surface opened over another one: the box, the title and the
   footer come from there, and the window it clamps to is the frame's own
   budget rather than a second tally of the same rows. The contract draws the
   window's "[lines a-b/n]" row under it. *)
let render_memory_fact_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let facts = Masc_tui_types.memory_fact_rows state in
  let total = List.length facts in
  let cursor = max 0 (min state.memory_facts_cursor (max 0 (total - 1))) in
  let lines =
    match List.nth_opt facts cursor with
    | None -> [ "    This list has no fact row to read." ]
    | Some row -> Render_memory.memory_fact_detail_lines ~cols row
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory-fact-detail"
    ~frame:Chrome_overlay
    (* The drawing says what it actually clamped to, so [G]'s sentinel and a
       scroll past the end are corrected in the state rather than only on the
       screen. *)
    ~overflow:
      (Scrolled
         { scroll = state.memory_fact_detail_scroll
         ; report = (fun scroll -> Memory_fact_detail_scroll scroll) })
    ~title:(screen_title " MASC MEMORY - FACT DETAIL")
    (* The keys project the same bindings the help sheet carries, so the
       footer and [?] cannot teach different keys. *)
    ~hints:Masc_tui_keys.memory_fact_detail_hints
    ~body:(fun ~budget:_ c -> List.iter c.push lines)

let rec render_memory_facts (state : state) =
  if state.memory_fact_detail_open then render_memory_fact_detail state
  else render_memory_facts_list state

and render_memory_facts_list (state : state) =
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
    Render_memory.facts_title ~cols
      ~screen:(screen_title " MASC Memory")
      ~keeper:keeper_name
      ~reading:
        (match Masc_tui_types.memory_facts_snapshot state with
         | None ->
           Render_memory.Facts_unread
             { reading = title_missing_reading ~error:(Masc_tui_types.memory_facts_failure state) }
         | Some _ ->
           Render_memory.Facts_loaded { total; filter_label; query_label })
      ~timestamp
      ~badge:(connection_badge state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"memory-facts"
    ~title ~hints:Masc_tui_keys.footer_hints_memory_facts
    ~body:(fun ~budget c ->
      Render_memory.render_memory_facts_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_repositories (state : state) =
  if state.repository_changes_open then render_repository_changes state
  else render_repository_list state

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
    | Masc.Tui_decode.Fc_materialized { bytes; _ } ->
      Printf.sprintf "(materialized %d bytes)" bytes
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
  | Masc.Tui_decode.Fc_materialized _ ->
    (Masc_tui_theme.tone Masc_tui_theme.Accent), "WRITE"

let change_result_badge (change : Masc.Tui_decode.file_change) =
  if change.Masc.Tui_decode.fc_succeeded then Theme.ok (), "APPLIED"
  else Theme.bad (), "FAILED"

(* A row of the diff, drawn as layers rather than as one styled string.

   Three styles overlap on every line: the row's background, the gutter's
   weight, and the text's own colour. Concatenating them would let the
   gutter's reset close the background, and the line would lose its colour
   from the marker onward -- the fault [Masc_tui_span] exists for. *)
let diff_row_span ?(hscroll = 0) ~width (row : Diff.row) =
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
      ; Span.text text_style (Message_layout.drop_cells (Terminal_text.single_line text) hscroll)
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
  | Masc.Tui_decode.Fc_materialized _ -> ("", "")

let render_changes_diff (state : state) (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let before, after = change_diff_halves change in
  let diff_rows = Diff.rows ~before ~after in
  let removed, added = Diff.counts diff_rows in
  let total = List.length diff_rows in
  let header =
    detail_heading ~cols ~lead:(Lead_text (screen_title " MASC Change" ^ " "))
      ~id:(change_row_address change)
      ~after:(Printf.sprintf "  -%d +%d" removed added)
      ~tail:(connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Facts about the change the rows themselves cannot carry. *)
  let notes =
    let turn =
      Printf.sprintf "  turn %s  task %s  %s"
        (Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:string_of_int
           change.Masc.Tui_decode.fc_turn)
        (Terminal_text.single_line
           (Option.value ~default:Masc_tui_theme.Glyph.no_value change.Masc.Tui_decode.fc_task_id))
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
    | Masc.Tui_decode.Fc_materialized _ ->
        (* The call names the blob, not its bytes, so the log has no text to
           show. Saying so is the difference between an empty diff and a
           change that wrote nothing. *)
        [ turn; "  the log holds the blob's coordinates, not its bytes" ]
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
  (* The position row carries the esc hint at every count, so it is one of
     [listing_rows_below_the_body] and needs no row of its own. *)
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:chrome_rows ~count:total
      ~preview_keep:None ~overflow_takes_row:false
  in
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
      | Some row -> box_line_span buf cols (diff_row_span ~hscroll:state.changes_diff_hscroll ~width:(framed_inner_width cols) row)
    done;
  let position = match Masc_tui_scroll.position_row ~scroll ~height:content_height total with
    | None -> ""
    | Some text -> " · " ^ String.trim text in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  col %d%s · esc closes" (state.changes_diff_hscroll + 1) position);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"Shift-Left / Shift-Right:pan  j/k:scroll  Left / Esc:back  o:open in editor  q:quit");
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
    | Some name -> name
  in
  let heading ~after =
    detail_heading ~cols
      ~lead:(Lead_text (screen_title " MASC Changes" ^ " "))
      ~id:whose ~after
      ~tail:(timestamp ^ "  " ^ connection_badge state)
  in
  let header =
    match state.changes with
    | None ->
        heading
          ~after:("  " ^ title_missing_reading ~error:state.changes_error)
    | Some s ->
        (* The window and the call count are stated because the list alone
           does not say what was looked at: no changes in a window and no
           calls in a window are different facts. *)
        heading
          ~after:
            (Printf.sprintf " (%d in %.0fh of %s)" shown
               s.Masc.Tui_decode.fcs_window_hours
               (Masc_tui_message_layout.count_noun
                  s.Masc.Tui_decode.fcs_calls_in_window "call"))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* What the turn did takes the cells the drawn columns leave. *)
  let file_change_layout =
    Render_schedule.change_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.change_header_row ~layout:file_change_layout
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
    match scrolled_surface state ~cols Changes with
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
  (* The list's rows as the keypress counts them: what the preview leaves,
     less the scroll row while the list overflows. *)
  let content_height =
    match scrolled_surface state ~cols Changes with
    | Some s ->
        Masc_tui_scroll.content_height ~rows ~chrome:s.sc_chrome ~count:s.sc_count
          ~preview_keep:s.sc_preview_keep ~overflow_takes_row:s.sc_overflow_takes_row
    | None -> max 1 (total_content - preview_height)
  in
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
                ~layout:file_change_layout
                { Render_schedule.crow_turn =
                    Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:string_of_int
                      change.Masc.Tui_decode.fc_turn
                ; crow_task =
                    Terminal_text.single_line
                      (Option.value ~default:Masc_tui_theme.Glyph.no_value
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
      (Printf.sprintf "[changes %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  box_bottom buf cols;
  Buffer.add_string buf
    (* The footer is the key table's (for_surface Changes); never a literal here. *)
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Changes));
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
    ; ds_hscroll = state.changes_diff_hscroll
    ; ds_unchanged = "  (this file matches its last commit)"
    ; ds_esc_hint = "esc closes"
    ; ds_footer_hints = "Shift-Left / Shift-Right:pan  j/k:scroll  Left / Esc:back  o:open in editor  q:quit"
    ; ds_surface_key = "changes"
    ; ds_clamped = (fun scroll -> Changes_diff_scroll scroll)
    }

(* The surface has two readings: the list, and one change opened. The open row
   is held as an index, so a refresh that shortens the list closes the diff
   rather than drawing a change the answer no longer holds. *)
let render_changes (state : state) =
  match Masc_tui_types.opened_file_change state with
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
      (screen_title " MASC Browser Lane") (source_name view.source ^ " · "
       ^ Option.value (browser_label view) ~default:"no browser")
      read_style (Browser_lane_view.read_status_label read_status) Ansi.reset in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(match view.client_picker, view.url_draft with
      | Some _, _ -> "↑/↓:choose  Enter:use browser  r:reload connections  Esc:cancel"
      | None, Some _ when busy view -> "Capture in flight • Enter after completion • Esc:cancel URL"
      | None, Some _ -> "Enter:go  Esc:cancel  Ctrl-U:clear  Ctrl-O:screenshot"
      | None, None when Option.is_some view.scene ->
          let action = match Option.bind (selected_scene_target view) scene_target_action with
            | Some Read_region -> "Enter:read region  "
            | Some Follow_link -> "Enter:follow link  "
            | Some Click_control -> "Enter:click  "
            | None -> "" in
          let article_hint =
            if Browser_lane_view.scene_has_articles view then "N/P:article  " else "" in
          "b:choose browser  " ^ action ^ "m:main  J/K:page scroll  Tab/Shift-Tab:action  " ^ article_hint ^ "n/p:element  v:regions  s:text  y:copy  h:observations  Ctrl-O:image"
      | None, None when Option.is_some view.scene_guard ->
          "b:choose browser  m:main  J/K:page scroll  r:recheck followed destination  s:recheck text  h:observations  Ctrl-O:image"
      | None, None -> Masc_tui_keys.footer_hints_browser_lane ^ "  s:scene  v:regions  h:observations")
    ~body:(fun ~budget c ->
      let status, style = match view.load with
        | Loading (_, Discover _) -> "Reading browser connections…", Theme.info ()
        | Loading (_, Read) ->
            (match browser_label view with
             | Some browser -> "Reading " ^ browser ^ "…"
             | None -> "Reading…"), Theme.info ()
        | Loading (_, Read_refresh) -> "Refreshing browser text…", Theme.info ()
        | Loading (_, Open_session) -> "Opening " ^ source_name view.source ^ " browser…", Theme.info ()
        | Loading (_, Close_session) -> "Closing " ^ source_name view.source ^ " browser…", Theme.info ()
        | Loading (_, Goto _) -> "Navigating " ^ source_name view.source ^ " browser…", Theme.info ()
        | Loading (_, Scene_regions _) -> "Reading page regions…", Theme.info ()
        | Loading (_, Scene_scroll _) -> "Scrolling page and refreshing scene…", Theme.info ()
        | Loading (_, Scene_focus _) -> "Reading selected page region…", Theme.info ()
        | Loading (_, Scene_read _) -> "Reading browser text and controls…", Theme.info ()
        | Loading (_, Scene_refresh _) -> "Refreshing current browser view…", Theme.info ()
        | Loading (_, Scene_follow _) -> "Following observed browser link…", Theme.info ()
        | Loading (_, Scene_follow_refresh _) -> "Rechecking followed browser destination…", Theme.info ()
        | Loading (_, Scene_click _) -> "Clicking observed browser control…", Theme.info ()
        | Loading (_, (Viewport_refresh _ | Viewport_cadence _)) -> "Refreshing selected browser viewport…", Theme.info ()
        | Loading (_, Viewport_pointer {action=Browser_lane.Scroll_at _;_}) -> "Scrolling selected browser viewport…", Theme.info ()
        | Loading (_, Viewport_pointer _) -> "Interacting with selected browser viewport…", Theme.info ()
        | Loading (_, Screenshot _) ->
            (match browser_label view with
             | Some browser -> "Capturing selected " ^ browser ^ " tab… (any key cancels preview)"
             | None -> "Capturing selected tab… (any key cancels preview)"), Theme.info ()
        | Failed detail ->
            let retry = match view.scene_guard with
              | Some _ -> " · followed destination pending · r:recheck"
              | None -> "" in
            "Cause: " ^ Terminal_text.single_line detail ^ retry, Theme.bad ()
        | No_browser ->
            (match view.source with
             | Live -> "Browser bridge not connected"
             | Automation | Stagehand -> "Browser session closed • o:open"), Theme.recede ()
        | Idle when Option.is_some view.scene ->
            (match view.scene with
             | Some scene ->
                 let summary = match Browser_lane_view.scene_summary scene with
                   | None -> ""
                   | Some text -> " • " ^ text in
                 let delta = match view.scene_delta with
                   | None -> ""
                   | Some {added; removed; unchanged; changed} ->
                       let changed_text = if changed = 0 then ""
                         else Printf.sprintf " · %d changed" changed in
                       Printf.sprintf " • Δ +%d new · -%d out · =%d same%s"
                         added removed unchanged changed_text in
                 let truncation = if scene.content.truncated then " • truncated" else "" in
                 Printf.sprintf "Scene %.1f ms • %d nodes%s%s%s" scene.elapsed_ms
                   (List.length scene.content.nodes)
                   truncation summary delta, Theme.ok ()
             | None -> "Not read yet", Theme.recede ())
        | Idle -> (match view.reading with
            | None -> "Not read yet", Theme.recede ()
            | Some reading -> Printf.sprintf "Read %.1f ms • %d tabs"
                reading.elapsed_ms (List.length reading.tabs), Theme.recede ())
      in
      (* The global coordinator status is not the result of the browser HTTP
         request. Keep it labeled, including the existing workspace warning. *)
      c.push (coordinator_status_row state ~style status);
      match view.client_picker with
      | Some cursor ->
          c.push_styled ~style:(Theme.info ()) "  Choose browser · separate sessions do not share login";
          c.push_divider ();
          let room = max 1 (budget - 4) in
          let start = max 0 (cursor - room + 1) in
          browser_choices view |> List.iteri (fun index choice ->
            if index >= start && index < start + room then
              let line = "  " ^ Terminal_text.single_line (browser_choice_label choice)
                ^ (if browser_choice_selected view choice then " (current)" else "") in
              if index = cursor then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          (match browser_lane_picker_empty_line view with
           | None -> ()
           | Some line ->
            c.push_styled ~style:(Theme.recede ()) line;
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
             | Live ->
               (match browser_label view with
                | Some browser -> "  Live " ^ browser ^ " • b:choose browser • a:automation • c:stagehand"
                | None -> "  Live • b:choose browser • a:automation • c:stagehand")
             | Automation -> "  Independent browser • b:choose browser • g:URL • o:open / x:close • l:live • c:stagehand"
             | Stagehand -> "  Stagehand Chromium • b:choose browser • g:URL • o:open / x:close • l:live • a:automation");
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
         | Some tab -> Printf.sprintf "  [%d/%d] %s%s  [ / ]:select tab · 1-9:jump"
             (index + 1) tab_count (Terminal_text.single_line tab.title)
             (if tab.active then " (active)" else ""));
      c.push_styled ~style:(Theme.recede ())
        (match view.scene, page with
         | Some scene, _ ->
             let scope = match scene.content.view, scene.content.scope with
               | Browser_lane.Regions, _ -> "Page regions"
               | Content, Some target ->
                   (match view.scene_scope with
                    | Some context when context.target = target ->
                        "Selected " ^ Masc.Browser_scene.region_role_to_string context.role
                        ^ " · " ^ fit_width (Terminal_text.single_line context.label)
                            (max 8 (cols - 32))
                    | None | Some _ -> "Selected region")
               | Content, None -> "Page content" in
             let viewport = Printf.sprintf "page scroll x=%.0f y=%.0f"
                 scene.content.scroll_x scene.content.scroll_y in
             "  " ^ scope ^ " · " ^ viewport ^ " · " ^
             Terminal_text.single_line scene.content.url
         | None, None -> "  No page content"
         | None, Some page -> Printf.sprintf "  %s • %s%s%s"
             (Terminal_text.single_line page.url) (Masc_tui_message_layout.count_noun page.chars "char")
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
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
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

type connector_table_column =
  | Connector_name_column | Connector_configured_column
  | Connector_reachable_column | Connector_status_column | Connector_channel_column

let render_connectors (state : state) =
  match browser_lane_on_screen state, state.browser_history with
  | Some _, Some history -> render_browser_history state history
  | Some view, None -> render_browser_lane state view
  | None, _ ->
  let terminal_rows, cols = get_terminal_size () in
  let connectors =
    match state.connectors with
    | None -> []
    | Some s -> s.Masc.Tui_decode_connectors.cs_connectors
  in
  let shown = List.length connectors in
  let column_width = function
    | Connector_name_column -> 12
    | Connector_configured_column -> 10
    | Connector_reachable_column -> 9
    | Connector_status_column -> 12
    | Connector_channel_column -> 16
  in
  (* Configuration is secondary to whether this connector can be reached
     and which channel it serves. Name is flexible; every other field keeps
     its column even when another row has a long Unicode name. *)
  let layout = Masc_tui_table.fit ~inner_width:(max 0 (framed_inner_width cols - 2))
    ~width:column_width ~flex:Connector_name_column
    ~drop_order:[ Connector_configured_column ]
    [ Connector_name_column; Connector_configured_column; Connector_reachable_column;
      Connector_status_column; Connector_channel_column ] in
  let cells ~name ~configured ~reachable ~status ~channel =
    List.map (fun column ->
      let header, value = match column with
        | Connector_name_column -> "CONNECTOR", name
        | Connector_configured_column -> "CONFIGURED", configured
        | Connector_reachable_column -> "REACHABLE", reachable
        | Connector_status_column -> "STATUS", status
        | Connector_channel_column -> "CHANNEL", channel
      in
      let width = if column = Connector_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.connectors with
    | None ->
        Printf.sprintf "%s  %s  %s"
          (screen_title " MASC Connectors") timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d of %d available)  %s  %s"
          (screen_title " MASC Connectors")
          snapshot.Masc.Tui_decode_connectors.cs_active snapshot.Masc.Tui_decode_connectors.cs_total
          timestamp (connection_badge state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    (* Names the exit, which this row did not. Esc leaves for the selected
       Keeper (masc_tui.ml reads it under [Connectors]) and the key sheet
       says so, but the footer named no exit key at all. Surfaces built
       through [hints_of_bindings] cannot drift this way -- footer and sheet
       come from one list -- and this one writes its own. Esc goes last
       because [drop_hint_items] never gives it up. *)
    ~hints:"B:Browser Lane  j/k:scroll  b:bind  u:unbind  r:refresh  Esc:keeper"
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        ("  " ^ Masc_tui_table.header_row
          (cells ~name:"" ~configured:"" ~reachable:"" ~status:"" ~channel:""));
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
              let open Masc.Tui_decode_connectors in
              let yes_no flag = if flag then "yes" else "no" in
              let line =
                "  " ^ Masc_tui_table.row (cells
                  ~name:(Terminal_text.single_line connector.cn_display_name)
                  ~configured:(yes_no connector.cn_available)
                  ~reachable:(yes_no connector.cn_connected)
                  ~status:(Terminal_text.single_line connector.cn_status)
                  ~channel:(Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                     connector.cn_channel))
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
            (Printf.sprintf "[connectors %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
      end)

let runtime_refresh_badge refresh_state =
  let open Masc.Tui_decode_runtime_probe in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> "fresh", (Theme.ok ())
    | Runtime_probe_recent -> "recent", (Theme.info ())
    | Runtime_probe_served_stale -> "stale", (Theme.warn ())
    | Runtime_probe_warming_up -> "warming", (Theme.warn ())
  in
  style ^ label ^ Ansi.reset

let runtime_overall_badge status =
  let open Masc.Tui_decode_runtime_probe in
  let style =
    match status with
    | Runtime_probe_reachable -> (Theme.ok ())
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_probe_status_to_string status ^ Ansi.reset

let runtime_usage_badge state runtime =
  match state.runtime_surface with
  | None -> Some (Ansi.dim ^ "usage unknown" ^ Ansi.reset)
  | Some snapshot ->
      match runtime_spent_usage snapshot.rss_resolved runtime with
      | Error _ -> Some (Ansi.dim ^ "usage unknown" ^ Ansi.reset)
      | Ok [] -> None
      | Ok (_ :: _) -> Some (Theme.warn () ^ "account limit spent" ^ Ansi.reset)

let runtime_route_badge state (runtime : Masc.Tui_decode.runtime_option) =
  match
    List.filter_map Fun.id
      [ runtime_quota_badge runtime; runtime_rate_limit_badge runtime; runtime_usage_badge state runtime ]
  with
  | [] -> (Theme.info ()) ^ "no refusal" ^ Ansi.reset
  | badges -> String.concat " " badges

let runtime_probe_badge = function
  | None -> Ansi.dim ^ "unobserved" ^ Ansi.reset
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
      let open Masc.Tui_decode_runtime_probe in
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

let runtime_route_probe_badge state runtime probe =
  runtime_route_badge state runtime ^ " / " ^ runtime_probe_badge probe

let runtime_probe_detail = function
  | None -> []
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
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

type runtime_table_column =
  | Runtime_lane_column
  | Runtime_candidate_column
  | Runtime_identity_column
  | Runtime_status_column
  | Runtime_detail_column

let runtime_table_cells ~cols ~status_cells ~mode ~lane ~lane_is_label ~candidate ~identity ~status ~detail =
  let lane_width, candidate_width, identity_width, minimum_status_width = runtime_column_widths cols in
  let status_width = max minimum_status_width status_cells in
  let inner_width = max 1 (framed_inner_width cols - 2) in
  let candidate_heading =
    match mode with Masc_tui_types.Runtime_lanes -> "CANDIDATE" | Runtime_all -> "RUNTIME"
  in
  (* Reserve the mode's identifying columns before allocating long status. *)
  let status_width, candidate_floor, drop_order = match mode with
    | Masc_tui_types.Runtime_lanes ->
        (* Lane identity and candidate order stay visible even when another
           row has a long combined status. Full status is in summary/detail. *)
        let remaining = inner_width - lane_width - (2 * Masc_tui_table.cell_gap) in
        let candidate_floor = min candidate_width (max 1 (remaining - 1)) in
        min status_width (max 1 (remaining - candidate_floor)), candidate_floor,
        [Runtime_detail_column; Runtime_identity_column]
    | Runtime_all ->
        let status_width = min status_width
          (max 1 (inner_width - Message_layout.display_width candidate_heading
                  - Masc_tui_table.cell_gap)) in
        status_width, min candidate_width (max 1 (inner_width - status_width - Masc_tui_table.cell_gap)),
        [Runtime_detail_column; Runtime_identity_column; Runtime_lane_column]
  in
  let width = function
    | Runtime_lane_column -> lane_width
    | Runtime_candidate_column -> candidate_floor
    | Runtime_identity_column -> identity_width
    | Runtime_status_column -> status_width
    | Runtime_detail_column ->
        max (Message_layout.display_width "single candidate")
          (inner_width - lane_width - candidate_floor - identity_width - status_width
           - (4 * Masc_tui_table.cell_gap)) in
  let layout = Masc_tui_table.fit ~inner_width ~width
    ~flex:Runtime_candidate_column
    ~drop_order
    [Runtime_lane_column; Runtime_candidate_column; Runtime_identity_column;
     Runtime_status_column; Runtime_detail_column] in
  List.map (fun column ->
    let header, value, fold = match column with
      | Runtime_lane_column ->
          (match mode with Masc_tui_types.Runtime_lanes -> "LANE" | Runtime_all -> "USED BY"),
          lane, (if lane_is_label then Masc_tui_table.Fold_tail else Fold_middle)
      | Runtime_candidate_column ->
          candidate_heading, candidate, Masc_tui_table.Fold_middle
      | Runtime_identity_column -> "PROVIDER / MODEL", identity, Masc_tui_table.Fold_middle
      | Runtime_status_column -> "ROUTE / PROBE", status, Masc_tui_table.Fold_tail
      | Runtime_detail_column -> "DETAIL", detail, Masc_tui_table.Fold_tail in
    let column_width = if column = Runtime_candidate_column then layout.flex_width else width column in
    Masc_tui_table.cell ~header ~width:column_width ~fold value) layout.shown

let runtime_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  let lines =
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  in
  if Message_layout.display_width prefix >= width then
    Message_layout.wrap_words ~max_cells:width
      (prefix ^ Terminal_text.single_line value)
    |> List.map (fun line -> style, line)
  else match lines with
  | [] -> [ style, prefix ^ Masc_tui_theme.Glyph.no_value ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let runtime_bool = function true -> "yes" | false -> "no"

(* A route is not a candidate. This reading remains available when the
   inventory is empty, and retains diagnostics beside a last-good snapshot. *)
let runtime_routes_detail_lines state ~width =
  let field ?(style = Ansi.reset) label value =
    runtime_detail_field ~width ~style label value
  in
  let optional label = function
    | None -> []
    | Some value -> field ~style:(Theme.warn ()) label value
  in
  let resolved =
    match state.runtime_surface with
    | None -> field "Resolved" "Configuration has not been read"
    | Some snapshot ->
        let resolved = snapshot.Tui_decode.rss_resolved in
        let route label values =
          match values with
          | [] -> field label "none"
          | values ->
              List.mapi
                (fun index value ->
                  field (Printf.sprintf "%s %d" label (index + 1)) value)
                values
              |> List.concat
        in
        let dropped =
          List.filter
            (fun id -> not (List.exists (String.equal id) resolved.rrs_media_failover))
            resolved.rrs_media_failover_declared
        in
        field "Source" (Option.value resolved.rrs_config_path ~default:"unavailable")
        @ field "Recorded" resolved.rrs_generated_at_iso
        @ field "Default route" (Option.value resolved.rrs_default_route ~default:"none")
        @ field "Entry runtime" (Option.value resolved.rrs_default_runtime_id ~default:"none")
        @ route "Declared media" resolved.rrs_media_failover_declared
        @ route "Admitted media" resolved.rrs_media_failover
        @ route "Unresolved media" dropped
        @ optional "Probe read error" snapshot.rss_probe_error
        @ (match snapshot.rss_probe with
           | None -> field "Probe" "unavailable; no observation has been read"
           | Some probe ->
               field "Probe status" (Masc.Tui_decode_runtime_probe.runtime_probe_status_to_string probe.rps_status)
               @ List.concat_map (field ~style:(Theme.warn ()) "Probe error") probe.rps_errors
               @ List.concat_map (field "Probe limitation") probe.rps_limitations)
  in
  optional "Runtime read warning" state.runtime_surface_error
  @ resolved
  @ (match state.runtime_lane_notice with
     | None -> []
     | Some notice ->
         field ~style:(runtime_lane_notice_style notice) "Action result"
           (Masc_tui_types.runtime_lane_notice_text notice))
  @ List.concat_map (field ~style:(Theme.warn ()) "Stale configuration")
      (Masc_tui_types.runtime_lane_stale_lines state)
;;

let runtime_detail_lines state target ~width =
  let open Masc.Tui_decode in
  let reading =
    match state.runtime_surface, target with
    | None, _ | Some _, Runtime_routes -> None
    | Some snapshot, Runtime_lane_candidate { lane_id; runtime_id } ->
        snapshot.rss_candidates
        |> List.find_opt (fun row ->
               String.equal row.rcr_lane_id lane_id
               && String.equal row.rcr_runtime.ro_id runtime_id)
        |> Option.map (fun row ->
               (* Not [[ row.rcr_lane_id ]]: that is the lane the reader came
                  through, which the header already names, and the field is
                  labelled "Used by lanes". A runtime several lanes fall back
                  to answered this door with one lane and the catalog door
                  with all of them. *)
               ( row.rcr_runtime
               , runtime_lanes_using snapshot ~runtime_id:row.rcr_runtime.ro_id
               , Some
                   ( row.rcr_lane_id
                   , row.rcr_position
                   , row.rcr_candidate_count )
               , row.rcr_probe ))
    | Some snapshot, Runtime_catalog_entry { runtime_id } ->
        runtime_all_rows snapshot
        |> List.find_opt (fun (runtime, _) -> String.equal runtime.ro_id runtime_id)
        |> Option.map (fun (runtime, lanes) ->
               let probe =
                 Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id
               in
               runtime, lanes, None, probe)
  in
  match reading with
  | None ->
      (match target with
       | Runtime_routes -> runtime_routes_detail_lines state ~width
       | Runtime_lane_candidate _ | Runtime_catalog_entry _ ->
           runtime_detail_field ~width ~style:(Theme.warn ()) "Runtime"
             "This runtime row is no longer present in the refreshed projection")
  | Some (runtime, lanes, position, probe) ->
      let fields =
        runtime_detail_field ~width ~style:Ansi.reset "Runtime ID" runtime.ro_id
        @ runtime_detail_field ~width ~style:Ansi.reset "Provider" runtime.ro_provider
        @ runtime_detail_field ~width ~style:Ansi.reset "Quota scope" (runtime_quota_scope_label runtime)
        @ runtime_detail_field ~width ~style:Ansi.reset "Response-local quota scope"
            (Option.value ~default:"not reported" runtime.ro_quota_scope)
        @ runtime_detail_field ~width ~style:Ansi.reset "Connection / provider ID" runtime.ro_provider_id
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
        @ runtime_detail_field ~width ~style:Ansi.reset "Default runtime"
            (runtime_bool runtime.ro_is_default)
      in
      let candidate =
        match position with
        | None -> []
        | Some (lane, at, total) ->
            (* The lane is named because "Used by lanes" above can now hold
               several, and a position without its lane is a place in an
               unnamed list. *)
            runtime_detail_field ~width ~style:Ansi.reset "Lane position"
              (Printf.sprintf "%d of %d in %s" at total lane)
      in
      let quota =
        match runtime_quota_badge runtime with
        | None -> []
        | Some _ ->
            runtime_detail_field ~width ~style:(Theme.warn ()) "Quota"
              (match runtime.ro_quota_resets_at with
               | Some resets_at ->
                 let tm = Unix.localtime resets_at in
                 Printf.sprintf "exhausted, resets %02d:%02d"
                   tm.Unix.tm_hour tm.Unix.tm_min
               | None -> "exhausted, no reset stated")
      in
      let rate_limit =
        match runtime.ro_rate_limited, runtime.ro_rate_limit_resets_at with
        | false, _ -> []
        | true, Some resets_at ->
          let tm = Unix.localtime resets_at in
          runtime_detail_field ~width ~style:(Theme.warn ()) "Rate limit"
            (Printf.sprintf "until %02d:%02d or the next successful answer"
               tm.Unix.tm_hour tm.Unix.tm_min)
        | true, None ->
          runtime_detail_field ~width ~style:(Theme.warn ()) "Rate limit"
            "no wait stated, cleared by the next successful answer"
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
            @ runtime_detail_field ~width ~style:Ansi.reset "Checked at"
                (Terminal_text.short_timestamp row.rpp_checked_at)
            (* No Reachable row: the decoder admits a probe only when its
               reachable flag agrees with its status, so the row could only
               repeat the status two rows above it -- "reachable" then
               "yes". *)
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
      let probe_limitations =
        match state.runtime_surface with
        | Some { rss_probe = Some snapshot; _ } ->
            List.concat_map
              (runtime_detail_field ~width ~style:Ansi.reset "Probe limitation")
              snapshot.rps_limitations
        | Some { rss_probe = None; _ } | None -> []
      in
      let keeper_lines =
        let target_keepers =
          match target with
          | Runtime_routes -> []
          | Runtime_lane_candidate { lane_id; runtime_id = _ } ->
              keepers_for_lane state lane_id
          | Runtime_catalog_entry { runtime_id } ->
              let direct = keepers_for_runtime state runtime_id in
              let via_lanes = List.concat_map (keepers_for_lane state) lanes in
              List.fold_left
                (fun acc (k : Tui_decode.keeper) ->
                   if List.exists (fun (existing : Tui_decode.keeper) -> String.equal existing.k_name k.k_name) acc then acc
                   else k :: acc)
                direct via_lanes
        in
        match target_keepers with
        | [] ->
            runtime_detail_field ~width ~style:Ansi.dim "Bound keepers" "none"
        | ks ->
            let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) ks) in
            let activity_str = match aggregate_keeper_stats ks with
              | None -> "activity not observed"
              | Some (turns, tokens, cost) ->
                Printf.sprintf "%d turns · %s tokens · $%.4f" turns
                  (format_context_tokens tokens) cost
            in
            runtime_detail_field ~width ~style:Ansi.reset "Bound keepers" names
            @ runtime_detail_field ~width ~style:Ansi.reset "Keeper lifetime" (activity_str ^ " · across all runtimes")
      in
      let usage_lines =
        match state.runtime_surface with
        | None -> runtime_detail_field ~width ~style:Ansi.dim "Account usage" "unavailable"
        | Some snapshot ->
          match runtime_spent_usage snapshot.rss_resolved runtime with
          | Error detail -> runtime_detail_field ~width ~style:Ansi.dim "Account usage"
              (Terminal_text.single_line detail)
          | Ok [] -> []
          | Ok windows ->
            runtime_detail_field ~width ~style:(Theme.warn ()) "Account usage"
              "A model-call limit is spent; this account report does not identify which models are refused."
            @ List.concat_map (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
                let limit = match window.puw_limit_id with
                  | Some id -> Terminal_text.single_line id
                  | None -> "account" in
                let tm = Unix.localtime window.puw_observed_at in
                let observed = Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
                    tm.Unix.tm_hour tm.Unix.tm_min in
                runtime_detail_field ~width ~style:(Theme.warn ()) "Spent limit"
                  (limit ^ " (observed " ^ observed ^ ")")) windows
      in
      let evidence_lines = match state.runtime_evidence with
        | None -> runtime_detail_field ~width ~style:Ansi.dim "Runtime history" "not read"
        | Some (Error detail) -> runtime_detail_field ~width ~style:Ansi.dim "Runtime history" detail
        | Some (Ok evidence) ->
          Masc_tui_runtime_evidence.lines evidence ~runtime_id:runtime.ro_id
          |> List.concat_map (fun (label, value) ->
            runtime_detail_field ~width ~style:Ansi.reset label value) in
      fields @ candidate @ evidence_lines @ usage_lines @ quota @ rate_limit @ keeper_lines @ probe_lines @ probe_limitations

let render_runtime_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let target_label =
    match target with
    | Runtime_routes -> "routes / status"
    | Runtime_lane_candidate { lane_id; runtime_id } -> lane_id ^ " / " ^ runtime_id
    | Runtime_catalog_entry { runtime_id } -> runtime_id
  in
  box_top buf cols;
  box_line buf cols
    (detail_heading ~cols
       ~lead:(Lead_text (screen_title runtime_detail_title ^ "  "))
       ~id:target_label ~after:"" ~tail:(connection_badge state));
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
       ~hints:(Masc_tui_keys.footer_hints_runtime_detail ()));
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* Lane candidates come from /runtime/resolved; reachability comes from the
   cached runtime-probe document. Exact runtime-id joining happened in the
   decoder module, so drawing never parses ids or reconstructs a lane. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ( runtime_lane_width
      , runtime_candidate_width
      , _
      , _ ) =
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
  let timestamp =
    match state.runtime_surface with
    | None -> "reading unavailable"
    | Some snapshot ->
        (match Masc_domain.parse_iso8601_opt snapshot.rss_resolved.rrs_generated_at_iso with
         | None -> "reading time unavailable"
         | Some generated_at ->
             let recorded = Unix.localtime generated_at in
             Printf.sprintf "reading %02d:%02d:%02d"
               recorded.Unix.tm_hour recorded.Unix.tm_min recorded.Unix.tm_sec)
  in
  let header =
    match state.runtime_surface with
    | None ->
        let reading_note =
          match state.runtime_surface_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC System / Runtime") reading_note timestamp
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
        let all_count =
          List.length snapshot.rss_resolved.Masc.Tui_decode.rrs_runtimes
        in
        (* [standalone_lanes] is the Lanes screen's reading, which this one
           does not load, so its absence is not a count of zero. *)
        let standalone_reading =
          Option.map
            (fun (snapshot : Masc.Tui_decode.standalone_lanes_snapshot) ->
              string_of_int (List.length snapshot.sls_lanes))
            state.standalone_lanes
        in
        let lanes_active = state.runtime_mode = Masc_tui_types.Runtime_lanes in
        Printf.sprintf "%s  %s  %s%s  %s  %s"
          (screen_title " MASC System / Runtime")
          (tab_strip
             ~width:
               (tab_strip_width ~cols
                  ~before:(screen_title " MASC System / Runtime" ^ tab_strip_gap)
                  ~after:
                    (Printf.sprintf "  %s%s  %s  %s" probe_status probe_read
                       timestamp (connection_badge state)))
             ~press:pressable
             [ ( tab_entry_label "Candidate orders"
                   (Some
                      (Printf.sprintf "%s, %s"
                         (Masc_tui_message_layout.count_noun lane_count "lane")
                         (Masc_tui_message_layout.count_noun
                            (List.length snapshot.rss_candidates) "slot")))
               , lanes_active
               , Press_runtime_mode Masc_tui_types.Runtime_lanes )
             ; ( tab_entry_label "All runtimes" (Some (string_of_int all_count))
               , not lanes_active
               , Press_runtime_mode Masc_tui_types.Runtime_all )
             ; ( tab_entry_label "Lanes" standalone_reading
               , false
               , Press_standalone_lanes )
             ])
          probe_status probe_read timestamp (connection_badge state)
  in
  let authority_rows = Masc_tui_types.runtime_authority_rows ~cols state in
  let selection_rows = runtime_selection_summary_for_viewport ~rows ~cols state in
  (* One measured status width for the whole reading, shared by the header and
     every row. A report that has several independent limits can still exceed
     the pane; full evidence stays in the selected summary or Enter's detail. *)
  let status_cells =
    let statuses = match state.runtime_mode with
      | Runtime_lanes -> List.map (fun row -> runtime_route_probe_text state
          row.Tui_decode.rcr_runtime row.rcr_probe) candidates
      | Runtime_all -> List.map (fun (runtime, _) ->
          let probe = Option.bind state.runtime_surface (fun snapshot ->
            Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.rss_probe ~runtime_id:runtime.Tui_decode.ro_id) in
          runtime_route_probe_text state runtime probe) all_runtimes in
    List.fold_left (fun width text -> max width (Message_layout.display_width text)) 0 statuses in
  (* The budget counts the rows this screen draws, so it comes from the same
     call the drawing reads rather than a fixed one. *)
  let chrome_rows = runtime_surface_listing_chrome ~rows ~cols state in
  let content_height = max 0 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  let scroll =
    if content_height = 0 then scroll
    else if state.runtime_cursor < scroll then max 0 state.runtime_cursor
    else if state.runtime_cursor >= scroll + content_height
    then min max_scroll (state.runtime_cursor - content_height + 1)
    else scroll in
  let all_runtimes_window = Rows.of_list ~first:scroll ~height:content_height all_runtimes in
  let candidates_window = Rows.of_list ~first:scroll ~height:content_height candidates in
  let scroll_hint =
    if shown > content_height then
      Printf.sprintf "[rows %s]  " (Masc_tui_scroll.window_text ~scroll ~height:content_height shown)
    else ""
  in
  let hints =
    scroll_hint ^ Masc_tui_keys.footer_hints_runtime ~mode:state.runtime_mode
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"runtime" ~title:header ~hints
    ~body:(fun ~budget:_ c ->
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> (Theme.warn ())
    | Some _ | None -> Ansi.dim
  in
  List.iter (fun row -> c.push_styled ~style:authority_style row) authority_rows;
  c.push_divider ();
  if selection_rows <> [] then begin
    List.iter c.push selection_rows;
    c.push_divider ()
  end;
  (* The two routes that are not lanes. They hold runtime ids and nothing
     dispatches a keeper turn to them, so they sit above the lane table rather
     than among its rows, where the lane count and the lane-editing keys would
     both be wrong about them. *)
  (match state.runtime_mode with
   | Masc_tui_types.Runtime_all -> ()
   | Masc_tui_types.Runtime_lanes ->
       let missing_resolved_value =
         match state.runtime_surface_error with
         | None -> field_missing_reading ~error:None
         | Some _ -> Ansi.dim ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset
       in
       let resolved =
         Option.map (fun (s : Tui_decode.runtime_surface_snapshot) -> s.rss_resolved)
           state.runtime_surface
       in
       let media_text =
         match resolved with
         | None -> missing_resolved_value
         | Some resolved ->
             let declared = resolved.rrs_media_failover_declared in
             let admitted = resolved.rrs_media_failover in
             let dropped =
               List.filter
                 (fun id -> not (List.exists (String.equal id) admitted))
                 declared
             in
             (match declared, dropped with
              | [], [] -> Ansi.dim ^ "none — no vision runtimes" ^ Ansi.reset
              | declared, dropped ->
                  String.concat " → "
                    (List.map Terminal_text.single_line declared)
                  ^
                  (match dropped with
                   | [] -> ""
                   | _ ->
                     (Theme.warn ())
                     ^ Printf.sprintf "  (%s unresolved at boot: %s)"
                         (Message_layout.count_noun (List.length dropped) "entry")
                         (String.concat ", " (List.map Terminal_text.single_line dropped))
                     ^ Ansi.reset))
       in
       List.iter
         (fun line -> c.push_styled ~style:(Theme.recede ()) ("  " ^ line))
         (Masc_tui_types.runtime_default_route_lines ~cols state);
       c.push_styled ~style:(Theme.recede ())
         (Printf.sprintf "  %s %s   %s"
            (runtime_column runtime_lane_width "media_failover")
            (runtime_column runtime_candidate_width media_text)
            (Ansi.dim ^ "m edits it · the vision runtimes, in call order" ^ Ansi.reset));
       c.push_divider ());
  let table_cells = runtime_table_cells ~cols ~status_cells ~mode:state.runtime_mode in
  c.push_styled ~style:(Theme.recede ())
    ("  " ^ Masc_tui_table.header_row
      (table_cells ~lane:"" ~lane_is_label:false ~candidate:"" ~identity:"" ~status:"" ~detail:""));
  c.push_divider ();
  (match state.runtime_surface_error with
   | None -> ()
   | Some detail ->
       c.push_styled ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       c.push_divider ());
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
       List.iter
         (fun line ->
            c.push_styled ~style:(runtime_lane_notice_style notice) ("  " ^ line))
         (String.split_on_char '\n'
            (Keeper_chat.terminal_safe_text ~preserve_newlines:true
               (Masc_tui_types.runtime_lane_notice_text notice)));
       c.push_divider ());
  (* Counted in [runtime_surface_listing_chrome] as one row each and a
     divider. *)
  (match Masc_tui_types.runtime_lane_stale_lines state with
   | [] -> ()
   | lines ->
       List.iter
         (fun line ->
            c.push_styled ~style:(Theme.warn ())
              ("  " ^ Keeper_chat.terminal_safe_text line))
         lines;
       c.push_divider ());
  (* Counted in [runtime_surface_listing_chrome] as two rows, like the refusal
     above, so the footer keeps its row while the prompt is up. *)
  (match Masc_tui_types.runtime_lane_prompt state with
   | None -> ()
   | Some (Masc_tui_types.Lane_rename_prompt (lane, draft)) ->
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf
            "  rename lane %s to: %s_  — Enter renames it and every reference, Esc cancel"
            (Terminal_text.single_line lane)
            (Terminal_text.single_line draft));
       c.push_divider ()
   | Some (Masc_tui_types.Lane_name_prompt draft) ->
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf "  new lane name: %s_  — Enter pick its first runtime, Esc cancel"
            (Terminal_text.single_line draft));
       c.push_divider ()
   | Some (Masc_tui_types.Lane_remove_prompt lane) ->
       c.push_styled ~style:(Theme.warn ())
         (Printf.sprintf "  press D again to remove lane %s"
            (Terminal_text.single_line lane));
       c.push_divider ());
  (* The route editor, drawn here when it was opened on media_failover. The
     Lanes surface draws the same editor for an exact lane's slots; both show
     one ordered list of runtime ids and take the same keys. *)
  (match state.slot_editor with
   | None | Some { Masc_tui_types.se_target = Masc_tui_types.Exact_lane_slots _; _ } -> ()
   | Some { se_target = Masc_tui_types.Media_failover_slots; _ } ->
       c.push_styled ~style:(Theme.info ())
         "  [runtime].media_failover — the order the vision runtimes are called in";
       let entries = Masc_tui_types.slot_editor_rows state in
       let selected_index = Masc_tui_types.slot_editor_cursor_index state in
       if entries = [] then
         c.push_styled ~style:(Theme.recede ())
           "  (empty — no vision runtimes; a adds the first runtime)"
       else
         List.iteri
           (fun index (row : Masc_tui_types.slot_editor_row) ->
              c.push
                (Printf.sprintf "  %s %d  %s"
                   (if Some index = selected_index then ">" else " ")
                   (index + 1)
                   (Terminal_text.single_line row.Masc_tui_types.sr_slot)))
           entries;
       if entries <> [] && Option.is_none (selected_index) then
         c.push_styled ~style:(Theme.warn ())
           "  no slot selected; j/k selects a current slot";
       c.push_styled ~style:(Theme.recede ())
         "  j/k move · a add · x drop · J/K reorder · Esc close";
       c.push_divider ());
  (match runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       let what, enter =
         match picker.rlp_pick with
         | Masc_tui_types.Pick_new_lane lane ->
             ( Printf.sprintf "first runtime of new lane %s" (Terminal_text.single_line lane)
             , "Enter create" )
         | (Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_exact_lane _) as pick ->
             ( Printf.sprintf "adding a candidate to the candidate order of %s"
                 (Terminal_text.single_line (Masc_tui_types.runtime_lane_pick_name pick))
             , "Enter append" )
         | Masc_tui_types.Pick_media_failover ->
             ( "adding to [runtime].media_failover, the order the vision runtimes are called in"
             , "Enter append" )
         | Masc_tui_types.Pick_exact_lane_replacement _ ->
             ("Replace selected candidate at its current position", "Enter replace")
         | Masc_tui_types.Pick_route_default ->
             (* Replaces rather than appends, and the row it replaces is
                marked "(already a candidate)" in the choices below. *)
             ("the route an unassigned keeper walks", "Enter replace")
       in
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf "  %s — %s — %s" what picker.rlp_summary
            (Masc_tui_types.runtime_picker_keys enter picker.rlp_filter));
       if picker.rlp_choices = [] then
         c.push_styled ~style:(Theme.recede ())
           (Masc_tui_types.runtime_picker_empty_note picker)
       else
         List.iteri (fun offset choice ->
           let mark = if picker.rlp_selected_row = Some offset then ">" else " " in
           let label = match choice, picker.rlp_pick with
             | Masc_tui_types.Runtime_choice runtime,
               (Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _) ->
                 Masc_tui_types.runtime_model_picker_title runtime
             | _ -> Masc_tui_types.runtime_picker_label_for picker.rlp_pick choice in
           match choice with
           | Masc_tui_types.Lane_choice lane ->
               let note =
                 if List.exists (String.equal lane.rrl_id) picker.rlp_already
                 then "  (current route)" else "" in
               c.push
                 (Printf.sprintf "  %s %s%s" mark
                    label
                    (Ansi.dim ^ note ^ Ansi.reset))
           | Masc_tui_types.Runtime_choice runtime ->
               let note =
                 if List.exists (String.equal runtime.ro_id) picker.rlp_already
                 then (match picker.rlp_pick with
                   | Masc_tui_types.Pick_route_default -> "  (current route)"
                   | _ -> "  (already a candidate)")
                 else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                 then "  (same provider as a current candidate)"
                 else ""
               in
               let ctx =
                 Printf.sprintf " [%s %s]"
                   (format_context_tokens runtime.ro_effective_max_context)
                   (match picker.rlp_pick with
                    | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ -> "context"
                    | _ -> "ctx")
               in
               let def = if runtime.ro_is_default then
                 (match picker.rlp_pick with
                  | Masc_tui_types.Pick_route_default -> " [entry runtime]"
                  | _ -> " [default]") else "" in
               c.push
                 (Printf.sprintf "  %s %s%s%s%s" mark
                    label
                    ctx def
                    (Ansi.dim ^ note ^ Ansi.reset));
               (match picker.rlp_pick with
                | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
                    c.push ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                      ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                      ^ " · " ^ Terminal_text.single_line runtime.ro_id)
                | _ -> ())) picker.rlp_choices;
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
           | Masc_tui_types.Runtime_lanes -> "  (no runtime candidate orders configured)"
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
               let bound_keepers =
                 let direct = keepers_for_runtime state runtime.ro_id in
                 let via_lanes = List.concat_map (keepers_for_lane state) lanes in
                 List.fold_left
                   (fun acc (k : Tui_decode.keeper) ->
                      if List.exists (fun (existing : Tui_decode.keeper) -> String.equal existing.k_name k.k_name) acc then acc
                      else k :: acc)
                   direct via_lanes
               in
               let default_fact =
                 if runtime.ro_is_default then [ (Theme.ok ()) ^ "[DEFAULT]" ^ Ansi.reset ] else []
               in
               let assignment_fact =
                 match bound_keepers with
                 | [] -> [ (Theme.recede ()) ^ "[no keepers]" ^ Ansi.reset ]
                 | [ one ] ->
                     let stats = keeper_assignment_activity bound_keepers in
                     [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" one.k_name stats ^ Ansi.reset ]
                 | many ->
                     let stats = keeper_assignment_activity bound_keepers in
                     let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) many) in
                     [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" names stats ^ Ansi.reset ]
               in
               let detail =
                 String.concat " \xc2\xb7 "
                   (default_fact @ assignment_fact
                    @ (match lanes with [] -> [] | l -> [ String.concat ", " l ])
                    @ runtime_probe_detail
                        (Option.bind state.runtime_surface (fun snapshot ->
                           Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
               in
               let line = "  " ^ Masc_tui_table.row
                 (table_cells ~lane:(Terminal_text.single_line (Masc_tui_theme.strip_sgr used_by)) ~lane_is_label:(lanes = [])
                   ~candidate:(Terminal_text.single_line runtime.ro_id)
                   ~identity:(Terminal_text.single_line (runtime.ro_provider ^ " / " ^ runtime.ro_model))
                   ~status:(runtime_route_probe_badge state runtime
                     (Option.bind state.runtime_surface (fun snapshot ->
                       Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
                   ~detail:(Terminal_text.single_line (Masc_tui_theme.strip_sgr detail))) in
               if index + scroll = state.runtime_cursor then
                 c.push_selected (Masc_tui_theme.strip_sgr line)
               else c.push line)
      | Masc_tui_types.Runtime_lanes ->
      match Rows.at candidates_window (index + scroll) with
      | None -> c.push_empty ()
      | Some candidate ->
          let open Masc.Tui_decode in
          let runtime = candidate.rcr_runtime in
          let is_first = candidate.rcr_position = 1 in
          let is_last = candidate.rcr_position = candidate.rcr_candidate_count in
          (* Names preserve both ends; the fallback label preserves its head. *)
          let lane_cell =
            if candidate.rcr_candidate_count <= 1 || is_first then
              Terminal_text.single_line candidate.rcr_lane_id
            else
              (Printf.sprintf "  %s fallback #%d"
                   (if is_last then "\xe2\x94\x94\xe2\x94\x80" else "\xe2\x94\x9c\xe2\x94\x80")
                   (candidate.rcr_position - 1))
          in
          let candidate_label =
            Printf.sprintf "%d/%d %s"
              candidate.rcr_position
              candidate.rcr_candidate_count
              (Terminal_text.single_line runtime.ro_id)
          in
          let provider_model =
            Terminal_text.single_line
              (runtime.ro_provider ^ " / " ^ runtime.ro_model)
          in
          let route_probe =
            runtime_route_probe_badge state runtime candidate.rcr_probe
          in
          let lane_keepers = keepers_for_lane state candidate.rcr_lane_id in
          let assignment_fact =
            if is_first then
              match lane_keepers with
              | [] -> [ (Theme.recede ()) ^ "[unassigned]" ^ Ansi.reset ]
              | [ one ] ->
                  let stats = keeper_assignment_activity lane_keepers in
                  [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" one.k_name stats ^ Ansi.reset ]
              | many ->
                  let stats = keeper_assignment_activity lane_keepers in
                  let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) many) in
                  [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" names stats ^ Ansi.reset ]
            else []
          in
          let lane_fact =
            (* [Lane_undeclared] reads like a one-candidate lane on the wire --
               one candidate, first position -- so until this row said so there
               was nothing on the surface telling them apart. A declared lane
               of one candidate has no next candidate either; what separates this
               one is that [D] has no table to remove. *)
            match Masc_tui_types.runtime_lane_fact_of_row candidate with
            | Masc_tui_types.Lane_undeclared ->
              [ (Theme.recede ()) ^ "runtime, not a declared lane" ^ Ansi.reset ]
            | Masc_tui_types.Lane_single_candidate -> [ "single candidate" ]
            | Masc_tui_types.Lane_head -> [ "head" ]
            | Masc_tui_types.Lane_fallback position ->
              [ Printf.sprintf "fallback #%d" position ]
          in
          let default_fact = if runtime.ro_is_default then [ (Theme.ok ()) ^ "[default]" ^ Ansi.reset ] else [] in
          (* The detail column leads with the lane fact. When it does not fit,
             Enter still opens the complete candidate reading. *)
          let detail =
            String.concat " \xc2\xb7 "
              (lane_fact @ assignment_fact @ default_fact
               @ runtime_probe_detail candidate.rcr_probe)
          in
          let line = "  " ^ Masc_tui_table.row
            (table_cells ~lane:lane_cell
              ~lane_is_label:(candidate.rcr_candidate_count > 1 && not is_first)
              ~candidate:candidate_label ~identity:provider_model ~status:route_probe
              ~detail:(Terminal_text.single_line (Masc_tui_theme.strip_sgr detail))) in
          if index + scroll = state.runtime_cursor then
            c.push_selected (Masc_tui_theme.strip_sgr line)
          else c.push line
    done;
)
;;

let tools_scrolled state =
  let _, cols = get_terminal_size () in
  tools_scrolled_for_lines state (Render_tools.tools_display_lines ~cols state)
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
      (screen_title " MASC System / Tools") timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_line buf cols (" " ^ Render_tools.tools_pane_strip ~cols state);
  box_line_styled buf cols ~style:Theme.selection
    (Render_tools.tools_selection_line ~cols state);
  box_divider buf cols;
  (match state.tools_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let display_lines = Render_tools.tools_display_lines ~cols state in
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
      (Printf.sprintf "[rows %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height drawable));
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
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading ~after =
    detail_heading ~cols ~lead:(Lead_text keeper_calls_lead) ~id:keeper_name
      ~after ~tail:(timestamp ^ "  " ^ connection_badge state)
  in
  let header =
    match state.keeper_calls with
    | Some snapshot when state.keeper_calls_loading ->
        heading
          ~after:
            (Printf.sprintf " \xe2\x96\xb8 calls (%d)  refreshing..."
               (List.length snapshot.Masc.Tui_decode.kcs_entries))
    | None when state.keeper_calls_loading ->
        heading ~after:" \xe2\x96\xb8 calls  (loading...)"
    | None ->
        heading
          ~after:
            (" \xe2\x96\xb8 calls  "
            ^ title_missing_reading ~error:state.keeper_calls_error)
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
          let health =
            Masc.Tui_decode.keeper_call_log_health_to_string
              snapshot.Masc.Tui_decode.kcs_health
          in
          match snapshot.Masc.Tui_decode.kcs_latest_age_s with
          | Some age -> Printf.sprintf "%s · latest %.0fs ago%s" health age reason
          | None -> health ^ reason
        in
        heading
          ~after:
            (Printf.sprintf " \xe2\x96\xb8 calls (%d)  %s"
               (List.length snapshot.Masc.Tui_decode.kcs_entries)
               freshness)
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
           match call.kc_outcome with
           | Tool_result.Recorded_succeeded -> ("✓", Ansi.reset)
           | Tool_result.Recorded_failed -> ("✗", (Theme.bad ()))
           | Tool_result.Recorded_deferred -> ("◌", (Theme.info ()))
           | Tool_result.Recorded_unsettled | Tool_result.Recorded_malformed ->
             ("?", Ansi.reset)
         in
         let duration =
           match Option.bind call.kc_duration_ms Masc_tui_acting.elapsed_text with
           | Some text -> text
           | None -> Masc_tui_theme.Glyph.no_value
         in
         let turn =
           match call.kc_turn with Some value -> string_of_int value | None -> Masc_tui_theme.Glyph.no_value
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
           (* This is the recorded-call inspector. A timeline digest drops
              structured receipt fields and can hide an assessment behind a
              later failure; preserve the stored output and let rows scroll. *)
           match call.kc_output with
           | None -> []
           | Some output ->
             labeled_rows ~call_index
               ~style:
                 (match call.kc_outcome with
                  | Tool_result.Recorded_failed -> Theme.bad ()
                  | Tool_result.Recorded_succeeded | Tool_result.Recorded_deferred
                  | Tool_result.Recorded_unsettled | Tool_result.Recorded_malformed ->
                    Ansi.dim)
               ~label:"output" output
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
    let window =
      Masc_tui_scroll.window_text ~scroll ~height:content_height total_rows
    in
    let detailed_footer =
      Printf.sprintf "[%s · %s]" (Masc_tui_message_layout.count_noun shown "call") window
    in
    let compact_footer = "[" ^ window ^ "]" in
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
              :: (document_markdown ~width:(max 1 (cols - 7))
                    ("```json\n" ^ Yojson.Safe.pretty_to_string value ^ "\n```")
                  |> List.map (fun line -> "  " ^ line)) in
        let preview label = function
          | None -> ["  " ^ label ^ ": not carried"]
          | Some text ->
              ("  " ^ label ^ " (producer-redacted preview)")
              :: (document_markdown ~width:(max 1 (cols - 7))
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
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  [evidence rows %s]"
       (Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines)));
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
  let trace_reading = Tui_decode.keeper_trace_projection state.keepers in
  let traces = trace_reading.bindings in
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
      | Masc_tui_observer.Keeper_turn_observation _
      | Masc_tui_observer.Keeper_composite_changed _
      | Masc_tui_observer.Keeper_chat_appended _
      | Masc_tui_observer.Keeper_chat_stream_frame _
      | Masc_tui_observer.Keeper_waiting_inventory_changed _
      | Masc_tui_observer.Fusion_run_status _
      | Masc_tui_observer.Internal_agent_runs_changed
      | Masc_tui_observer.Lane_resource _
      | Masc_tui_observer.Snapshot _
      | Masc_tui_observer.Other _ ->
          None
    in
    Acting.keeper_row_of_entry ~traces ~duration_ms entry
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
    (* The count sits straight after the state word, so it reads as the count
       its "live N" sibling above uses. *)
    | Observer_closed_after_live { events; reason; _ } ->
        Printf.sprintf "feed: closed %d (%s)" events
          (Terminal_text.single_line reason)
    (* No count: the stream never answered, so there is nothing it carried. *)
    | Observer_closed_before_answer { reason; _ } ->
        Printf.sprintf "feed: failed to open (%s)"
          (Terminal_text.single_line reason)
  in
  (* Rows and events, each with its noun. This read "(3 of 120 held, turns)",
     but under Turns a row is a folded turn and the held count is events, so
     "3 of 120" compared two different things as if one were part of the
     other. The scope name left with it: the row under the feed says it,
     "scope turns · …", one line down. *)
  let header =
    Printf.sprintf "%s  %s  %s"
      (activity_title ~cols ~on_logs:false
         ~after:(Printf.sprintf "  %s  %s" timestamp (connection_badge state))
         (Masc_tui_types.activity_title_reading ~observer:state.observer
            ~shown ~held))
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
  (match Masc_tui_acting_pane.trace_unavailable_summary trace_reading.unavailable with
   | None -> ()
   | Some summary -> box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ summary));
  box_divider buf cols;
  (* Measured over every row the filter keeps, not the page on screen, so the
     columns do not move while a reader scrolls. Only the two named columns
     are measured, so this asks the event for its keeper and its label rather
     than building a row: a row carries the detail sentence too, and spelling
     one per kept entry on every frame is work the screen never shows. The
     chunked list is already built, so its rows are read as they are. *)
  let table_columns =
    let measured =
      match chunked with
      | Some rows -> List.map Acting.measured_of_row rows
      | None ->
          List.map
            (fun (entry, _older) ->
              Acting.measured_of_event ~traces entry.Acting.ae_event)
            visible
    in
    Acting.columns ~inner_width:(framed_inner_width cols) measured
  in
  let col_hdr =
    Printf.sprintf "  %-8s %-*s %s %-*s %s" "TIME"
      table_columns.Acting.keeper_cells "KEEPER" " "
      table_columns.Acting.label_cells "EVENT" "DETAIL"
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
      | Observer_closed_after_live _ ->
          if held = 0 then "  (the feed closed before any event arrived)"
          else "  (nothing under this filter; f shows everything)"
      | Observer_closed_before_answer _ ->
          if held = 0 then "  (no events yet: the feed failed to open)"
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
            | Acting.Turn_done -> Ansi.bold
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
            let keeper_cell =
              fit_width
                (Terminal_text.single_line row.Acting.keeper)
                table_columns.Acting.keeper_cells
            in
            if detail = "" then
              Printf.sprintf "  %-8s %s %s %s" clock keeper_cell
                (Acting.glyph_text row.Acting.glyph)
                label
            else
              Printf.sprintf "  %-8s %s %s %s %s" clock keeper_cell
                (Acting.glyph_text row.Acting.glyph)
                (fit_width label table_columns.Acting.label_cells)
                detail
          in
          let selected = state.acting_filter <> Acting.Turns && idx = cursor in
          let line = if selected then "> " ^ String.sub line 2 (String.length line - 2) else line in
          box_line_styled buf cols ~style:(if selected then Theme.selection else style) line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[rows %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (* Same straggler, same fix. The literal named five of this surface's
            nine keys: 1/2 (Events / Logs), l (logs), Esc and q never reached
            the screen they work on. *)
         (Masc_tui_keys.footer_hints Acting));
  let clamped = match state.acting_filter with
    | Acting.Turns -> Acting scroll
    | Actions | Everything -> Acting_selection (scroll, cursor) in
  finish_surface state ~clamped ~surface_key:"acting" ~rows:terminal_rows ~cols buf

let provider_history_lines ~cols (state : state) =
  match state.provider_history with
  | Provider_history_unread ->
      [ Printf.sprintf " Quota scope trend (%d UTC days) · not observed"
          state.provider_history_days ]
  | Provider_history_error reason ->
      [ Printf.sprintf " Quota scope trend (%d UTC days) · unavailable: %s"
          state.provider_history_days (Terminal_text.single_line reason) ]
  | Provider_history_read trend ->
      let days = trend.Masc_tui_usage_trend.days in
      let as_of = Unix.gmtime trend.generated_at in
      let scopes =
        match state.overview_providers with
        | Providers_read reading -> reading.puws_accounts
        | Providers_unread | Providers_failed _ -> []
      in
      let label scope_id =
        match List.find_opt
                (fun account ->
                  String.equal (Overview_providers.scope_id account) scope_id)
                scopes with
        | None ->
            "scope "
            ^ Terminal_text.single_line
                (String.sub scope_id 0
                   (min Overview_providers.scope_id_cells
                      (String.length scope_id)))
        | Some account -> Overview_providers.scope_name account
      in
      let width = max 1 (cols - 7) in
      let minimum_card_cells = max 64 (7 + days * 2 + 4) in
      let paired = width >= 2 * minimum_card_cells + 2 in
      let card_width = if paired then (width - 2) / 2 else width in
      let inner = max 1 (card_width - 4) in
      let wrap text = Message_layout.wrap_words ~max_cells:inner text in
      let chart (row : Masc_tui_usage_trend.row) =
        let account = List.find_opt (fun account ->
          String.equal (Overview_providers.scope_id account) row.scope_id) scopes in
        let email = Option.bind account (Overview_providers.account_email
          ~account_emails:state.overview_account_emails) in
        let limit = Option.fold ~none:"" ~some:(fun id -> id ^ " ") row.limit_id in
        let latest = match Masc_tui_usage_trend.latest row with
          | None -> "No reports in this window"
          | Some sample ->
            let time = Unix.gmtime sample.observed_at in
            Printf.sprintf "Latest report %s · %02d-%02d %02d:%02d UTC"
              (match sample.report with
               | Masc_tui_usage_trend.Measured (value, _) -> Overview_providers.utilization_text value
               | Masc_tui_usage_trend.Reported_no_windows -> "reported no windows")
              (time.Unix.tm_mon + 1) time.Unix.tm_mday time.Unix.tm_hour time.Unix.tm_min in
        let body = wrap (Terminal_text.single_line limit ^ Terminal_text.single_line row.kind)
          @ (match email with None -> [] | Some email -> wrap email)
          @ wrap latest
          @ Masc_tui_usage_trend.plot ~width:inner trend row
          @ wrap (Printf.sprintf "%d/%d UTC days reported" row.reported_days days) in
        let heading = Message_layout.fit_middle inner (label row.scope_id) in
        let line text = Theme.recede () ^ Ansi.box_v ^ Ansi.reset ^ " "
          ^ Message_layout.fit_width text inner ^ " " ^ Theme.recede () ^ Ansi.box_v ^ Ansi.reset in
        (Theme.info () ^ Ansi.box_tl ^ " " ^ Ansi.bold ^ heading ^ Ansi.reset ^ Theme.info ()
         ^ " " ^ draw_hline (max 0 (card_width - Message_layout.display_width heading - 4))
         ^ Ansi.box_tr ^ Ansi.reset)
        :: List.map line body
        @ [Theme.recede () ^ Ansi.box_bl ^ draw_hline (max 0 (card_width - 2)) ^ Ansi.box_br ^ Ansi.reset]
      in
      let rec arrange = function
        | [] -> []
        | left :: right :: rest when paired ->
          let left = chart left and right = chart right in
          let height = max (List.length left) (List.length right) in
          let row lines index = Option.value ~default:(String.make card_width ' ') (List.nth_opt lines index) in
          List.init height (fun index -> "   " ^ row left index ^ "  " ^ row right index)
          @ [""] @ arrange rest
        | row :: rest -> List.map (fun line -> "   " ^ line) (chart row) @ [""] @ arrange rest in
      let first = Unix.gmtime (trend.generated_at -. float_of_int (days - 1) *. 86400.0) in
      (Printf.sprintf
         " Quota scope trend (%d UTC days) · latest report per day · as of %02d-%02d %02d:%02d UTC"
         days (as_of.Unix.tm_mon + 1) as_of.Unix.tm_mday as_of.Unix.tm_hour as_of.Unix.tm_min)
      :: Printf.sprintf " %02d-%02d → %02d-%02d UTC · 0–100%% used · 0 = reported zero · · = no report · ○ = reported no windows · $ = uncapped USD use"
           (first.Unix.tm_mon + 1) first.Unix.tm_mday (as_of.Unix.tm_mon + 1) as_of.Unix.tm_mday
      :: " ↓ below zero · ↑ above limit"
      :: (match trend.unreadable_reports with
          | 0 -> []
          | count -> [Printf.sprintf "   %d stored reports could not be read; missing days stay absent" count])
      @ (match trend.rows with
         | [] -> [ "   No reports recorded in this window" ]
         | rows -> arrange rows)

let usage_lines ~cols (state : state) =
  let open Masc.Tui_decode_usage in
  let scopes =
    match Overview_providers.section
            ~providers:state.overview_providers ~history:state.provider_history ~runtimes:state.overview_quota
            ~account_emails:state.overview_account_emails
            ~now:(Unix.gettimeofday ()) ~width:(max 20 (cols - 4)) with
    | Some section -> section.title :: section.lines
    (* [section] answers [None] only before the first read. *)
    | None -> [ " Plan usage · not observed" ]
  in
  let keepers =
    match state.keeper_usage with
    | Keeper_usage_unread -> [ " Keeper usage (24h) · not observed" ]
    | Keeper_usage_error reason ->
        [ " Keeper usage (24h) · unavailable: " ^ Terminal_text.single_line reason ]
    | Keeper_usage_read Keeper_usage_loading ->
        [ " Keeper usage (24h) · collecting" ]
    | Keeper_usage_read (Keeper_usage_window { kuw_rows; kuw_window_minutes; kuw_freshness; kuw_generated_at }) ->
        let freshness = match kuw_freshness with
          | Keeper_usage_fresh -> ""
          | Keeper_usage_stale { age_s; last_error } ->
              Printf.sprintf " · %.0fs old%s" age_s
                (Option.fold ~none:" · refreshing"
                   ~some:(fun reason -> " · refresh failed: " ^ Terminal_text.single_line reason)
                   last_error)
        in
        let readable row = match row.kur_coverage with
          | Keeper_usage_failed _ | Keeper_usage_partial _ -> false
          | Keeper_usage_complete -> true
        in
        let token_value row = Option.map float_of_int row.kur_tokens in
        let cost_value row = row.kur_cost_usd in
        let valid value = Float.is_finite value && value >= 0. in
        let largest value = List.fold_left
            (fun highest row ->
              if readable row then
                match value row with
                | Some amount when valid amount ->
                    Some (Option.fold ~none:amount ~some:(max amount) highest)
                | _ -> highest
              else highest) None kuw_rows in
        let token_max = largest token_value and cost_max = largest cost_value in
        let scale value format = function
          | Some amount -> format amount
          | None when List.exists (fun row ->
              Option.fold ~none:false ~some:valid (value row)) kuw_rows ->
              "unavailable (no complete window)"
          | None -> "unreported"
        in
        let width = max 1 (cols - 7) in
        let bar_cells = min 32 (max 1 (width - 2)) in
        let meter value highest row =
          match value row with
          | Some amount when readable row && valid amount ->
              let maximum = Option.value ~default:0. highest in
              let filled = if maximum = 0. then 0
                else min bar_cells (int_of_float (amount /. maximum *. float_of_int bar_cells)) in
              "[" ^ String.concat "" (List.init bar_cells
                (fun index -> if index < filled then "█" else "░")) ^ "]"
              ^ (if amount = 0. then " 0" else "")
          | _ -> "[unavailable · no comparison bar]"
        in
        let generated = Unix.gmtime kuw_generated_at in
        [ Printf.sprintf " Keeper usage · last %dm · recorded turn metrics%s"
            kuw_window_minutes freshness
        ; Printf.sprintf " As of %04d-%02d-%02d %02d:%02d UTC"
            (generated.Unix.tm_year + 1900) (generated.Unix.tm_mon + 1)
            generated.Unix.tm_mday generated.Unix.tm_hour generated.Unix.tm_min
        ; " Bars compare read windows; each metric scales to its largest Keeper."
        ; " Partial windows have no comparison bar; missing metrics can understate totals; bars are not quota."
        ; Printf.sprintf " Scale: tokens %s · cost %s"
            (scale token_value (Printf.sprintf "%.0f") token_max)
            (scale cost_value (Printf.sprintf "$%.4f") cost_max)
        ; "" ]
        @ (if kuw_rows = [] then [ "   No Keepers in the returned roster" ]
            else List.concat_map
              (fun (row : Masc.Tui_decode_usage.keeper_usage_row) ->
                let tokens =
                  Option.fold ~none:"unreported" ~some:string_of_int row.kur_tokens in
                let cost =
                  Option.fold ~none:"unreported"
                    ~some:(Printf.sprintf "$%.4f") row.kur_cost_usd in
                let coverage =
                  match row.kur_coverage with
                  | Keeper_usage_complete -> "read"
                  | Keeper_usage_partial { malformed_rows; unread_turn_rows } ->
                      Printf.sprintf "partial (%d malformed rows, %d unread turn rows)"
                        malformed_rows unread_turn_rows
                  | Keeper_usage_failed reason ->
                      "unavailable: " ^ Terminal_text.single_line reason
                in
                let width = max 1 (cols - 7) in
                let heading = Masc_tui_message_layout.fit_middle width
                    (Terminal_text.single_line row.kur_name) in
                [ "   " ^ Theme.info () ^ Ansi.bold ^ heading ^ Ansi.reset ]
                @ List.concat_map
                    (fun line -> List.map (fun text -> "   " ^ text)
                        (Masc_tui_message_layout.wrap_words ~max_cells:width line))
                    [ Printf.sprintf "%d turns · %s" row.kur_turn_samples coverage
                    ; Printf.sprintf "Tokens  %s · %d reported, %d missing"
                        tokens row.kur_tokens_reported row.kur_tokens_missing
                    ; meter token_value token_max row
                    ; Printf.sprintf "Cost    %s · %d reported, %d missing"
                        cost row.kur_cost_reported row.kur_cost_missing
                    ; meter cost_value cost_max row
                    ; "" ])
              kuw_rows)
  in
  let wrap_evidence lines =
    (* Wrap before the scroll window is counted. Coverage and missing samples
       remain reachable rows on narrow terminals. *)
    List.concat_map
      (fun line ->
        if String.equal line "" then [ "" ]
        else if Message_layout.display_width line <= framed_inner_width cols then [line]
        else
          let rec leading index =
            if index < String.length line && Char.equal line.[index] ' '
            then leading (index + 1) else index in
          let indent_cells = leading 0 in
          let indent = String.make indent_cells ' ' in
          let body = String.sub line indent_cells (String.length line - indent_cells) in
          Message_layout.split_styled_cells
            ~max_cells:(max 1 (framed_inner_width cols - indent_cells)) body
          |> List.map (fun text -> indent ^ text))
      lines
  in
  match state.usage_section with
  (* Plan cards already have a cell-sized border and wrapped contents. *)
  | Usage_plan -> scopes
  | Usage_trend -> wrap_evidence (provider_history_lines ~cols state)
  | Usage_keepers ->
      let currency = match Masc_tui_candle.summary_lines state.candle_observation with
        | [] -> []
        | lines ->
            [ " " ^ Ansi.bold ^ "Candle · workspace supply" ^ Ansi.reset ]
            @ List.map (fun line -> "   " ^ Terminal_text.single_line line) lines
            @ [ Theme.recede () ^ draw_hline (framed_inner_width cols) ^ Ansi.reset ]
      in
      wrap_evidence (currency @ keepers)

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec
  in
  (* The section being read is marked on the strip under this row, so the
     title does not name it a second time. *)
  let title =
    Printf.sprintf "%s  %s  %s"
      (screen_title
         (if state.usage_telemetry_open then " MASC Usage / Telemetry"
          else " MASC Usage"))
      timestamp (connection_badge state)
  in
  (* The section's lines are formatted by the drawing, so the row it could
     start at is known only once it has. The body writes it here and the
     contract reads it back out. *)
  let drawn_metrics_scroll = ref state.metrics_scroll in
  surface_chrome
    ~overflow:(Self_scrolled (fun () -> Metrics_scroll !drawn_metrics_scroll))
    state ~terminal_rows ~cols ~surface_key:"metrics"
    ~title
    ~hints:(Masc_tui_keys.footer_hints_metrics
              ~telemetry:state.usage_telemetry_open)
    ~body:(fun ~budget c ->
      if state.usage_telemetry_open then
        Metrics_page.render_metrics_body ~cols ~budget state
          ~report_scroll:(fun scroll -> drawn_metrics_scroll := scroll)
          ~push:c.push ~push_styled:c.push_styled
          ~push_selected:c.push_selected ~push_divider:c.push_divider
          ~push_empty:c.push_empty
      else begin
        let pill section label =
          if state.usage_section = section then Ansi.reverse ^ " " ^ label ^ " " ^ Ansi.reset
          else Theme.recede () ^ " " ^ label ^ " " ^ Ansi.reset
        in
        let navigation_rows = if budget >= 3 then 1 else 0 in
        let spacing_rows = if budget >= 6 then 1 else 0 in
        if navigation_rows > 0 then
          c.push (pill Usage_plan "Plan" ^ "  " ^ pill Usage_trend "Trend"
                  ^ "  " ^ pill Usage_keepers "Keepers" ^ "   v:next view");
        if spacing_rows > 0 then c.push "";
        let lines = usage_lines ~cols state in
        let content_budget = max 0 (budget - navigation_rows - spacing_rows) in
        let overflow_rows = if content_budget >= 2 && List.length lines > content_budget then 1 else 0 in
        let height = content_budget - overflow_rows in
        let max_scroll = max 0 (List.length lines - height) in
        let scroll = min max_scroll (max 0 state.metrics_scroll) in
        drawn_metrics_scroll := scroll;
        List.iteri
          (fun index line ->
            if index >= scroll && index < scroll + height then c.push line)
          lines;
        if overflow_rows > 0 then
          c.push (Printf.sprintf " [rows %s · j/k to scroll]"
                    (Masc_tui_scroll.window_text ~scroll ~height
                       (List.length lines)))
      end)

(** Render the runtime picker: the dispatchable catalogue, with the keeper it
    is choosing for and where that keeper points today in the header. *)
(* Through the surface contract. Drawn by hand, the frame spent [rows - 7] on
   its rows and did not count the failure or loading row above the options, so
   the footer stood one row above the composer, or two once the list filled.
   Its failure row was a seventh spelling of [data_unreliable_row] with its own
   width, which padded the error and then cut the closing bracket off. Its
   footer named the keys "assign", "back to default" and "cancel" where the key
   table and the help sheet say "choose", "use the default" and "back". *)
let render_runtime_pick (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let keeper_name =
    Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
      state.runtime_pick_keeper
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
    | Some a -> runtime_assignment_label a
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let items = Masc_tui_types.runtime_picker_items state in
  (* The columns are measured over every item, not the filtered window, so
     typing a filter does not move them. *)
  let target_width, route_width =
    Masc_tui_types.runtime_pick_column_widths ~cols items
  in
  let view = Masc_tui_types.keeper_runtime_picker_view state ~terminal_rows in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"runtime-pick"
    ~title:
      (Printf.sprintf "%s  %scurrent: %s%s"
         (screen_title
            (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 runtime" keeper_name))
         Ansi.dim current Ansi.reset)
    ~hints:(Masc_tui_keys.footer_hints (Keepers Keeper_runtime_pick))
    ~body:(fun ~budget:_ c ->
      c.push_styled ~style:(Theme.info ())
        ("  " ^ Masc_tui_types.keeper_runtime_picker_summary view);
      (match state.runtime_catalog_reading, Masc_tui_types.keeper_runtime_picker_empty_note view with
       | Runtime_catalog_failed err, _ -> c.push (data_unreliable_row ~cols err)
       | (Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_read), Some note -> c.push (Ansi.dim ^ note ^ Ansi.reset)
       | (Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_read), None ->
           (* The first header cell spans badge and target, as the rows
              do. *)
           let header =
             Printf.sprintf "  %s  %s  %s"
               (fit_width "KIND   TARGET"
                  (Masc_tui_types.runtime_pick_badge_cells + target_width))
               (fit_width "CONFIGURED ROUTE / MODEL" route_width)
               (fit_width "PROPERTIES / CANDIDATES"
                  (Masc_tui_types.runtime_pick_properties_room ~cols
                     ~target:target_width ~route:route_width))
           in
           c.push (Ansi.dim ^ header ^ Ansi.reset));
      List.iteri
        (fun row item ->
          let line =
            (* The target column draws ids, and an id tells its neighbours
               apart at both ends: [claude_code.claude-sonnet-5-low] and
               [-high] share everything but the last four cells, which a
               head-keeping cut drops. [fit_middle] keeps both ends, which
               is what it says it is for. *)
            let columns = Masc_tui_types.runtime_pick_columns item in
            let badge_style =
              match item with
              | Masc_tui_types.Pick_lane _ -> Ansi.cyan
              | Masc_tui_types.Pick_model _ -> Ansi.dim
            in
            let badge =
              badge_style
              ^ fit_width columns.Masc_tui_types.rpc_badge
                  Masc_tui_types.runtime_pick_badge_cells
              ^ Ansi.reset
            in
            let target =
              Message_layout.fit_middle target_width columns.Masc_tui_types.rpc_target
              |> fun text -> fit_width text target_width
            in
            let route_col =
              Message_layout.fit_middle route_width columns.Masc_tui_types.rpc_route
              |> fun text -> fit_width text route_width
            in
            let facts =
              Masc_tui_types.runtime_pick_visible_facts ~cols item
              |> List.map (fun (fact : Masc_tui_types.runtime_pick_fact) ->
                   if fact.rpf_warn
                   then (Theme.warn ()) ^ fact.rpf_text ^ Ansi.reset
                   else fact.rpf_text)
              |> String.concat " "
            in
            Printf.sprintf "%s%s  %s  %s" badge target route_col facts
          in
          if view.Masc_tui_pick_list.selected_row = Some row then
            c.push_selected ("> " ^ Masc_tui_theme.strip_sgr line)
          else c.push ("  " ^ line))
        view.Masc_tui_pick_list.rows)

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
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC System") state);
  (* Where the overrides live leads, because it is the only thing on this row
     the reader cannot get anywhere else, and it was what the row cut first:
     at eighty columns it read "overrides persist in .masc/run\xe2\x80\xa6" and at
     sixty-four "overrides pers\xe2\x80\xa6", while the two key phrases in front of it
     survived whole.

     [Enter] is gone from the row. The footer is pinned to keep it at every
     width ([Masc_tui_footer.never_dropped_keys]), so "Enter edits by type"
     was the footer's own hint said a second time on a row that had no space
     for it -- and [e] opens the same editor, which the row never said.

     [E] stays. The footer drops it at eighty columns, so below that this row
     is the only place the advanced editor is named. *)
  (match state.runtime_params_notice with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ())
       "  overrides persist in .masc/runtime_params.json · E is advanced JSON"
   | Some (ok, detail) ->
     box_line_styled buf cols ~style:(if ok then Theme.ok () else Theme.bad ())
       ("  " ^ Terminal_text.single_line detail));
  let selected = List.nth_opt state.runtime_params state.runtime_params_cursor in
  let field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 4)) value
        |> List.map (fun line -> "    " ^ line))
  in
  (* Values are exact JSON. Word wrapping can discard a space at a chunk
     boundary, so split the sanitised value only between terminal cells. *)
  let value_field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Message_layout.split_cells
          ~max_cells:(max 1 (framed_inner_width cols - 4))
          (Masc.Tui_terminal_text.sanitize_terminal_text value)
        |> List.map (fun line -> "    " ^ line))
  in
  let selected_lines =
    (match state.runtime_params_notice with
     | None -> []
     | Some (ok, text) -> field (if ok then "Result" else "Refused") text)
    @
    match selected with
    | None -> ["  Select a row to see its contract"]
    | Some row ->
      let open Tui_decode in
      field "Key" row.rpr_key
      @ value_field "Current" row.rpr_current_json
      @ value_field "Default" row.rpr_default_json
      @ field "Type" (if String.trim row.rpr_value_type = "" then "typed value" else row.rpr_value_type)
      @ (match row.rpr_min_json with None -> [] | Some value -> value_field "Minimum" value)
      @ (match row.rpr_max_json with None -> [] | Some value -> value_field "Maximum" value)
      @ (row.rpr_choices
         |> List.mapi (fun index choice ->
              value_field (Printf.sprintf "Choice %d" (index + 1))
                (Yojson.Safe.to_string (`String choice)))
         |> List.concat)
      @ field "Contract" row.rpr_description
      @ field "Source" (if row.rpr_has_override then "override" else "default")
      @ (match row.rpr_surface with
         | None -> []
         | Some surface -> field "Group" (surface.rps_id ^ " · " ^ surface.rps_description))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    "  j/k selects · PgUp/PgDn reads the complete value and contract";
  box_divider buf cols;
  (* Editing adds a divider and two form rows.  Spend those rows out of the
     list budget so the footer remains visible instead of falling underneath
     the always-present composer. *)
  let list_height, detail_height =
    Masc_tui_types.runtime_params_viewport state ~terminal_rows in
  let count = List.length state.runtime_params in
  let cursor = max 0 (min state.runtime_params_cursor (count - 1)) in
  (match state.runtime_params_error with
   | Some detail ->
     box_line buf cols ((Theme.bad ()) ^ "설정을 읽지 못했습니다: " ^ Ansi.reset
                        ^ Terminal_text.single_line detail);
     for _ = 2 to list_height do box_empty buf cols done
   | None ->
     if state.runtime_params_loading && state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  (loading runtime parameters…)" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end
     else if state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  등록된 설정 없음" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end else begin
       (* Rows arrive in registry-group order (Tui_decode sorts them by
          surface). Headers are lines on this screen, not decoration outside it:
          they are built into the same list the window scrolls over, so a group
          heading costs a row from [list_height] instead of pushing the last
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
         if total <= list_height then 0
         else if cursor_display < list_height then 0
         else min (total - list_height) (cursor_display - list_height + 1)
       in
       let display_window = Rows.of_list ~first:first ~height:list_height display in
       for index = 0 to list_height - 1 do
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
           let value_width = max 4 (min 16 ((framed_inner_width cols - 7) / 3)) in
           let key_width = max 1 (framed_inner_width cols - 7 - value_width) in
           let line =
             Printf.sprintf "    %s %s %s"
               (Masc_tui_config_mark.param_glyph
                  ~has_override:row.rpr_has_override)
               (Message_layout.fit_middle key_width (Terminal_text.single_line row.rpr_key)
                |> fun key -> fit_width key key_width)
               (fit_width (Terminal_text.single_line
                  (runtime_param_value_text ~value_type:row.rpr_value_type
                     row.rpr_current_json)) value_width)
           in
           if row_index = cursor then box_line_selected buf cols line
           else
             box_line_styled buf cols
               ~style:(if row.rpr_has_override then (Masc_tui_theme.tone Masc_tui_theme.Accent) else Ansi.dim) line
       done
     end);
  let scroll = Masc_tui_scroll.normalize ~count:(List.length selected_lines)
      ~height:(max 1 detail_height) state.config_scroll in
  let reading = Masc_tui_scroll.window_reading ~noun:"Detail" ~scroll
      ~height:detail_height (List.length selected_lines) in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height selected_lines in
  let visible_lines = List.init detail_height (fun index ->
      Option.value (Rows.at detail_window (scroll + index)) ~default:"") in
  let panel_title = Option.map (fun row ->
      "Selected setting · " ^ Terminal_text.single_line row.Tui_decode.rpr_key
      ^ " · " ^ reading) selected in
  (* The panel replaces the divider and position row, so the document keeps
     the shared paging height. Use plain rows when panel borders would trim
     any exact JSON row or hide the document position. *)
  (match panel_title with
   | Some title
     when Message_layout.display_width title <= framed_inner_width cols - 4
       && List.for_all
            (fun line -> Message_layout.display_width line <= framed_inner_width cols - 4)
            selected_lines ->
       studio_panel ~width:(framed_inner_width cols) ~title ~lines:visible_lines
       |> List.iter (box_line buf cols)
   | Some _ | None ->
       box_divider buf cols;
       List.iter (box_line buf cols) visible_lines;
       box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ reading));
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
     let runtime_param_edit_row =
       row_with_field ~cols
         ~lead:(Printf.sprintf "  %s%s%s " Ansi.bold field_label Ansi.reset)
         ~field:draft ~tail:""
     in
     box_line buf cols runtime_param_edit_row;
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
          | None -> Masc_tui_keys.footer_hints_config ~pane:Config_params));
  finish_surface state ~clamped:(Runtime_params_scroll scroll)
    ~surface_key:"config-params" ~rows:terminal_rows ~cols buf
;;

(* Where the prompt catalog is, for the one row both prompt screens draw above
   their list. A failed refresh says so above the rows it kept, so they read as
   the last good catalog rather than a fresh one; a first read that failed has
   no rows under it. *)
let prompt_catalog_status_row prompts =
  match prompts with
  | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent -> None
  | Masc_tui_fetched.Loading -> Some (Theme.recede (), "프롬프트 목록을 읽는 중…")
  | Masc_tui_fetched.Stale (_, detail) ->
    Some
      ( Theme.bad ()
      , "새로고침 실패 · 마지막으로 읽은 목록입니다 — " ^ Terminal_text.single_line detail )
  | Masc_tui_fetched.Failed detail -> Some (Theme.bad (), Terminal_text.single_line detail)
;;

let prompts_detail_layout state ~rows ~error_rows =
  let fixed_rows = if state.prompts_show_runtime_assets then 9 else 8 in
  let combined = max 1 (rows - fixed_rows - error_rows) in
  let list_height = min 8 (combined / 3) in
  (list_height, max 1 (combined - list_height))

let prompts_detail_lines (state : state) ~cols =
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let wrap text =
    Message_layout.wrap_body ~max_cells:(max 1 (cols - 6))
      ~sanitize:Terminal_text.single_line text
  in
  let body text =
    Message_layout.wrap_body ~markdown:document_markdown
      ~max_cells:(max 1 (cols - 6)) ~sanitize:Terminal_text.single_line text
  in
  let field name text = name ^ ": " ^ Terminal_text.single_line text in
  let status = match prompt_catalog_status_row prompts with
    | None -> [] | Some (_, text) -> wrap text
  in
  let document = match Masc_tui_fetched.value prompts with
    | None -> wrap "선택한 프롬프트가 없습니다"
    | Some snapshot when state.prompts_show_runtime_assets ->
        let assets = snapshot.Tui_decode.ps_runtime_assets in
        let selected = List.nth_opt assets
            (max 0 (min state.prompts_cursor (List.length assets - 1))) in
        (match selected with
         | None -> wrap "런타임 프롬프트 자산이 없습니다"
         | Some asset ->
             wrap "이 자산은 registry override·편집 대상이 아닙니다"
             @ body asset.pra_value
             @ List.concat_map wrap
                 [field "자산" asset.pra_path;
                  field "소스" (if asset.pra_file_exists then "런타임 파일" else "누락");
                  field "파일" asset.pra_file_path])
    | Some snapshot ->
        let rows = Tui_decode.prompt_rows_for_operator
            ~show_fragments:state.prompts_show_fragments snapshot in
        let selected = List.nth_opt rows
            (max 0 (min state.prompts_cursor (List.length rows - 1))) in
        (match selected with
         | None -> wrap "선택한 프롬프트가 없습니다"
         | Some row ->
             let notices =
               match List.find_opt
                       (fun (entry : Tui_decode.held_back_override) ->
                         String.equal entry.hbo_key row.pr_key)
                       snapshot.ps_held_back with
               | None -> []
               | Some entry ->
                   List.concat_map wrap
                     [Printf.sprintf "⊘ 적용 안 됨 · 저장된 오버라이드 %d바이트가 그대로 있습니다" entry.hbo_bytes;
                      entry.hbo_reason;
                      "그 변수를 빼고 같은 키를 다시 저장하면 적용됩니다"]
             in
             let moved = if row.pr_override_default_moved then
                 wrap "△ 기본 프롬프트가 이 오버라이드를 쓴 뒤에 바뀌었습니다 · 오버라이드는 그대로 적용 중이니 현재 기본값과 한 번 대조하세요"
               else []
             in
             let actual_input =
               if not (String.equal row.pr_category "librarian") then []
               else if state.prompts_librarian_input_loading
                       && not (Option.exists
                            (fun (key, _) -> String.equal key row.pr_key)
                            state.prompts_librarian_input) then
                 ["최근 실제 Librarian 입력"; "(Admin 실행 상세를 불러오는 중...)"]
               else match state.prompts_librarian_input_error with
                 | Some detail -> ["최근 실제 Librarian 입력"; "불러올 수 없음: " ^ Terminal_text.single_line detail]
                 | None ->
                     (match state.prompts_librarian_input with
                      | Some (key, lines) when String.equal key row.pr_key -> lines @ [""]
                      | Some _ | None -> [])
             in
             let source = match row.pr_source with
               | Tui_decode.Prompt_override -> "override 사용 · MD는 기본값"
               | Tui_decode.Prompt_file -> "MD 파일 사용"
               | Tui_decode.Prompt_missing -> "없음"
             in
             let contract =
               if String.equal row.pr_category "librarian" then
                 wrap "입력: Keeper 지침 | 현재 기억 | 제한된 대화 | 상대 관측 | 사실 최대 바이트"
               else []
             in
             notices @ moved @ List.concat_map wrap actual_input
             @ wrap "유효 템플릿 본문" @ body row.pr_effective
             @ List.concat_map wrap
                 [field "키" row.pr_key; field "소스" source;
                  field "파일" row.pr_file_path; field "분류" row.pr_category;
                  field "설명" row.pr_description;
                  field "템플릿 변수" (match row.pr_template_variables with
                    | [] -> "없음" | variables -> String.concat " | " variables);
                  field "읽기" (match row.pr_operator_surface with
                    | Tui_decode.Prompt_primary -> "주 프롬프트"
                    | Tui_decode.Prompt_fragment -> "내부 조각")]
             @ contract)
  in
  status @ document

let prompts_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let error_rows = if Option.is_some (prompt_catalog_status_row prompts) then 1 else 0 in
  let _, height = prompts_detail_layout state ~rows ~error_rows in
  (List.length (prompts_detail_lines state ~cols), height)

let render_prompts_detail state buf ~cols ~height =
  let rendered = prompts_detail_lines state ~cols in
  let total = List.length rendered in
  let scroll = Masc_tui_scroll.normalize ~count:total ~height state.config_scroll in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  Detail [%d-%d/%d]" (scroll + 1)
       (min total (scroll + height)) total);
  let window = Rows.of_list ~first:scroll ~height rendered in
  for index = 0 to height - 1 do
    match Rows.at window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ line)
    | None -> box_empty buf cols
  done

let render_prompt_registry (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  (* A failed refresh keeps the catalog it read last: its rows, its count and
     its held-back overrides stay drawn, and the status row below says the
     refresh failed. Only a first read with no answer has none of them. *)
  let snapshot = Masc_tui_fetched.value prompts in
  let prompt_rows =
    match snapshot with
    | Some snapshot ->
        Tui_decode.prompt_rows_for_operator
          ~show_fragments:state.prompts_show_fragments snapshot
    | None -> []
  in
  let all_prompt_count =
    match snapshot with
    | Some snapshot -> List.length snapshot.Tui_decode.ps_rows
    | None -> 0
  in
  (* Overrides the registry declined to restore. A held-back key still draws
     from its file, so without this it renders exactly like a prompt nobody
     ever customized -- which is how an operator loses an override without
     learning they lost it. *)
  let held_back =
    match snapshot with
    | Some snapshot -> snapshot.Tui_decode.ps_held_back
    | None -> []
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
  (* A count only once the registry has answered. "0/0개" stood for a
     registry not asked yet and for one whose read failed, the same as for a
     registry with no prompts. *)
  let count_text =
    title_count_of_view prompts ~count:(fun _ ->
        Printf.sprintf "%d/%d개" total all_prompt_count)
  in
  box_top buf cols;
  (* The count the registry answered, and -- before any decoration that can
     be cut -- how many overrides it held back. The row keeps a fixed floor
     for the tab strip, so at a hundred and twenty columns the reading can
     run a cell short and [config_pane_title_head] shortens the tail first.
     An override the registry declined is exactly the warning an operator
     must not lose to an ellipsis, so it sits beside the count the row
     protects rather than after the part that gives way. *)
  let held_back_note =
    match held_back with
    | [] -> ""
    | entries ->
      Printf.sprintf " %s적용 안 된 오버라이드 %d개%s" (Theme.warn ())
        (List.length entries) Ansi.reset
  in
  let reading =
    Printf.sprintf "%s%s%s%s · %s%s"
      Ansi.dim count_text
      held_back_note
      Ansi.dim
      (if state.prompts_show_fragments then "내부 조각 포함" else "주 프롬프트")
      Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC 프롬프트") ~reading state);
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows in
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
          let held_back = Option.is_some (held_back_for row.Tui_decode.pr_key) in
          let glyph =
            Masc_tui_config_mark.prompt_glyph ~held_back row.Tui_decode.pr_source
          in
          (* Colour is this pane's, the glyph the mark module's, because the
             help sheet draws the same glyph with no colour at all. *)
          match held_back, row.Tui_decode.pr_source with
          | true, _ -> (Theme.bad ()) ^ glyph ^ Ansi.reset
          | false, Tui_decode.Prompt_override -> (Theme.warn ()) ^ glyph ^ Ansi.reset
          | false, Tui_decode.Prompt_file -> glyph
          | false, Tui_decode.Prompt_missing -> (Theme.bad ()) ^ glyph ^ Ansi.reset
        in
        let label = mark ^ " "
            ^ Message_layout.fit_middle (max 1 (cols - 7))
                (Terminal_text.single_line row.Tui_decode.pr_key) in
        if index = cursor then
          box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    prompt_rows;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Message_layout.fit_middle (max 1 (cols - 6))
       (match selected with
        | None -> "선택 없음"
        | Some row -> Terminal_text.single_line row.Tui_decode.pr_key));
  render_prompts_detail state buf ~cols ~height:detail_height;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_prompts));
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
    match Masc_tui_fetched.value prompts with
    | Some snapshot -> snapshot.Tui_decode.ps_runtime_assets
    | None -> []
  in
  let total = List.length assets in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt assets cursor in
  let count_text =
    title_count_of_view prompts ~count:(fun _ -> Printf.sprintf "%d개" total)
  in
  box_top buf cols;
  let reading =
    Printf.sprintf "%s%s · 읽기 전용%s" Ansi.dim count_text Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title " MASC 런타임 프롬프트 자산") ~reading state);
  box_line_styled buf cols ~style:(Theme.recede ())
    "  배포된 .txt 지시문 · registry override 대상이 아님";
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows in
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
         let line = mark ^ " "
             ^ Message_layout.fit_middle (max 1 (cols - 7))
                 (Terminal_text.single_line asset.pra_path) in
         if index = cursor then box_line buf cols (Theme.selection ^ " " ^ line ^ Ansi.reset)
         else box_line buf cols (" " ^ line)
       end)
    assets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Message_layout.fit_middle (max 1 (cols - 6))
       (match selected with
        | None -> "선택 없음"
        | Some asset -> Terminal_text.single_line asset.Tui_decode.pra_path));
  render_prompts_detail state buf ~cols ~height:detail_height;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_prompt_assets);
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
let preset_detail_lines (state : state) ~cols ~selected =
  let unreadable = match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_unreadable
  in
  let detail = Masc_tui_preset_text.detail_lines ~selected
    ~detail:(match selected with
      | None -> Masc_tui_fetched.Absent
      | Some m -> Masc_tui_fetched.view_for ~equal:String.equal
          state.preset_detail ~key:m.Tui_decode.pm_name)
    ~report:state.preset_report
  in
  let errors = match state.presets_error with
    | None -> []
    | Some error -> ["Refresh failed: " ^ error; ""]
  in
  errors @ detail
  @ List.map (fun (name, reason) -> "! " ^ name ^ " — " ^ reason) unreadable
  |> List.concat_map (fun line ->
       if String.equal line "" then [""]
       else Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2)) line)

let preset_pane_heights (state : state) ~rows ~count =
  let error_rows = if Option.is_some state.presets_error then 1 else 0 in
  let entry_rows = if Option.is_some state.preset_save_draft then 1 else 0 in
  (* Top, title, divider, list/detail divider, bottom, and footer. The error
     is outside the selection list, so a retained list keeps its full slot. *)
  let combined_height = max 2 (rows - 6 - error_rows - entry_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_rows = max 1 (combined_height - list_height) in
  let detail_height = Masc_tui_scroll.content_height ~rows:detail_rows ~chrome:0
      ~count ~preview_keep:None ~overflow_takes_row:true
  in
  list_height, detail_height

let presets_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let presets = match state.presets_snapshot with
    | None -> [] | Some snapshot -> snapshot.Tui_decode.pss_presets in
  let cursor = max 0 (min state.presets_cursor (List.length presets - 1)) in
  let selected = List.nth_opt presets cursor in
  let count = List.length (preset_detail_lines state ~cols ~selected) in
  let _, height = preset_pane_heights state
      ~rows:(Masc_tui_types.surface_body_rows state ~terminal_rows) ~count in
  count, height

let render_presets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let presets =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_presets
  in
  let total = List.length presets in
  let cursor = max 0 (min state.presets_cursor (total - 1)) in
  let selected = List.nth_opt presets cursor in
  (* The same rule as the prompt registry's title: no count before a
     snapshot has arrived, and none after a first read that failed. *)
  let count_text =
    match state.presets_snapshot with
    | Some _ -> Printf.sprintf "%d개" total
    | None -> title_missing_reading ~error:state.presets_error
  in
  box_top buf cols;
  let reading = Printf.sprintf "%s%s%s" Ansi.dim count_text Ansi.reset in
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC 프리셋") ~reading
       state);
  box_divider buf cols;
  let detail = preset_detail_lines state ~cols ~selected in
  let count = List.length detail in
  let list_height, detail_height = preset_pane_heights state ~rows ~count in
  let preset_rows = list_height in
  let first = if cursor < preset_rows then 0 else cursor - preset_rows + 1 in
  (match state.presets_error with
   | Some detail ->
     box_line buf cols
       (Theme.bad () ^ "  " ^ fit_width (Terminal_text.single_line detail) (cols - 6)
        ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  (* A read that failed said "불러오는 중..." under its own failure row: the
     empty row asked only whether a snapshot had arrived. *)
  (match state.presets_snapshot, state.presets_error with
   | None, Some _ ->
       incr drawn;
       box_line_styled buf cols ~style:(Theme.recede ()) page_failed_note
   | None, None ->
       incr drawn;
       box_line_styled buf cols ~style:(Theme.recede ()) page_unread_note
   | Some snapshot, (Some _ | None) ->
       Option.iter
         (fun line ->
           incr drawn;
           box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ line))
         (Masc_tui_preset_text.pane_empty_line snapshot));
  List.iteri
    (fun index (manifest : Tui_decode.preset_manifest) ->
      if index >= first && index < first + preset_rows then begin
        incr drawn;
        let armed =
          state.preset_restore_armed = Some manifest.Tui_decode.pm_name
        in
        let mark = if armed then Theme.warn () ^ "r" ^ Ansi.reset else " " in
        let label =
          row_with_field ~cols ~lead:(" " ^ mark ^ " ")
            ~field:(Terminal_text.single_line (Masc_tui_preset_text.pane_row manifest))
            ~tail:""
        in
        if index = cursor then box_line buf cols (Theme.selection ^ label ^ Ansi.reset)
        else box_line buf cols label
      end)
    presets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  let scroll = Masc_tui_scroll.normalize ~count ~height:detail_height state.config_scroll in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height detail in
  for index = 0 to detail_height - 1 do
    match Rows.at detail_window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ line)
    | None -> box_empty buf cols
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height:detail_height count);
  (match state.preset_save_draft with
   | Some draft ->
     box_line buf cols
       (row_with_field ~cols
          ~lead:(Theme.info () ^ "  이름: " ^ Ansi.reset)
          ~field:(Terminal_text.single_line draft)
          ~tail:(Ansi.dim ^ "  Enter:저장  Esc:취소" ^ Ansi.reset))
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_presets));
  finish_surface state ~clamped:(Preset_detail_scroll scroll)
    ~surface_key:"presets" ~rows:terminal_rows ~cols buf

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
    (config_pane_title ~cols ~name:(screen_title " MASC Themes")
       ~reading:
         (Printf.sprintf "%s%d themes · %d native-pass%s" Ansi.dim
            (List.length entries) native_count Ansi.reset)
       state);
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  " ^ fit_width "theme" (name_width + 2) ^ " "
     ^ fit_width "colours" 16 ^ "  " ^ fit_width "page" 9 ^ " "
     ^ fit_width "contrast" 12)
  ;
  (* The key the way the footer spells it, then the three filters as the
     product's tab strip draws a choice: the one in force marked. It read
     "Filter: [f] [All 53] · Dark 40 · Light 13", where the brackets meant a
     key once and the chosen filter once, on the same row. *)
  let explanation =
    if cols >= 92 then
      "  ·  "
      ^ (if lift_on then "native 7/7=no lift · lift N/7=N raised"
         else "native 7/7=all pass · N/7 low=below 4.5:1")
    else ""
  in
  let filter_tag =
    let chip label filter count =
      (label ^ " " ^ string_of_int count, state.theme_filter = filter, filter)
    in
    Ansi.dim ^ "f:filter  " ^ Ansi.reset
    ^ tab_strip
        ~width:
          (tab_strip_width ~cols ~before:"  f:filter  " ~after:explanation)
        ~press:(fun filter text -> pressable (Press_theme_filter filter) text)
        [ chip "All" `All (List.length all_entries)
        ; chip "Dark" `Dark dark_count
        ; chip "Light" `Light light_count
        ]
  in
  box_line buf cols ("  " ^ filter_tag ^ Ansi.dim ^ explanation ^ Ansi.reset);
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
      (Printf.sprintf "  Sample: %s● Ok%s  %s▲ Warn%s  %s× Bad%s  %s◆ Info%s  %s@keeper%s  %s⚡ tool%s"
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
    (* What is in force, then its keys in the footer's spelling. [f] is on
       the filter row above, so it is not said twice. *)
    (match chosen with
     | None ->
       "  terminal colours  \xc2\xb7  Enter:pick a theme"
     | Some name ->
       Printf.sprintf "  %s  \xc2\xb7  Enter:pick another  x:follow terminal"
         (Terminal_text.single_line name));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:state.config_pane));
  finish_surface state ~surface_key:"themes" ~rows:terminal_rows ~cols buf

(* Where the config file being read lives, for the title row beside the strip
   that already names the file. Said from the server's masc root, which is the
   same for every screen in the session and named on the Config pane's identity
   row. Until the server has said where its root is, the whole path is the only
   honest reading. *)
let config_path_note (state : state) =
  match state.runtime_config_view, state.runtime_config_view_error with
  | Some reading, _ ->
      let path = Terminal_text.single_line reading.rcv_path in
      let shown =
        match state.server_identity with
        | Some identity ->
            path_from_root ~root:identity.Tui_decode.sid_masc_root path
        | None -> path
      in
      Ansi.dim ^ shown ^ Ansi.reset
  | None, Some _ -> ""
  | None, None ->
      Ansi.dim ^ title_missing_reading ~error:None ^ Ansi.reset

(* The model knobs sit in different tables -- [reasoning-effort] and
   [temperature] under [models.NAME], [max-tokens] under
   [PROVIDER.NAME] -- and runtime.toml is 2,300 lines, so reading it top to
   bottom never puts them side by side. On 2026-08-29 nine of ten
   ollama_cloud bindings carried neither; a request with no reasoning_effort
   has Ollama turn thinking on by itself, and one keeper spent a turn
   producing 2,000 characters of reasoning and no answer. This pane is the
   same source the runtime.toml pane shows, arranged so a missing knob is a
   column and not an absence.

   Structured edits and copies use the runtime.toml preview-checked writer. *)
let render_config_models (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows_avail = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note = config_path_note state in
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC Models") ~note:path_note
       state);
  box_divider buf cols;
  let content_height = max 1 (rows_avail - 5) in
  (match state.runtime_model_form with
   | Some form ->
       let lines = Masc_tui_model_form.rows ~width:(max 1 (cols - 6)) ~height:content_height form in
       List.iter (fun line -> box_line buf cols ("  " ^ Terminal_text.single_line line)) lines;
       for _ = List.length lines + 1 to content_height do box_empty buf cols done
   | None when Option.is_some state.runtime_model_jump ->
       box_line buf cols (Ansi.dim ^ "  Loading selected account/model settings… Esc cancels" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
   | None -> match config_models_read_error state, state.runtime_config_view with
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
          which reads as a blank value. The pane is the truth the table is
          fitted against: handing the table a floor of 40 on a terminal
          narrower than that drew mandatory readings into cells the frame
          then cut (#28905 review). [render] uses the pane to choose the
          stacked layout before that cut can eat a value. *)
       let table =
         Masc_tui_model_runtime_table.render
           ~width:(max 40 (cols - 6 - 2))
           ~pane:(max 1 (cols - 6 - 2))
           state.config_models_rows
       in
       let total = List.length table in
       (* The cursor walks bindings, not lines. In table mode line 0 is the
          header, so binding [i] is line [i+1] and that is what the window
          follows. In stacked mode the item's first line is the binding's
          line: the cursor still selects the same record it did before the
          resize, which is the whole point of the transition. *)
       let pane_width = max 1 (cols - 6 - 2) in
       let table_mode =
         Masc_tui_model_runtime_table.fits ~width:pane_width state.config_models_rows
       in
       let cursor_line =
         if table_mode then state.config_models_cursor + 1
         else
           List.nth_opt
             (Masc_tui_model_runtime_table.stacked_item_starts ~pane:pane_width state.config_models_rows)
             state.config_models_cursor
           |> Option.value ~default:0
       in
       let max_scroll = max 0 (total - table_height) in
       (* The window follows the cursor rather than the other way round: a
          cursor the frame does not draw is a selection the reader cannot
          see, and [e] would act on a row that is off screen. *)
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let scroll =
         if cursor_line < scroll then cursor_line
         else if cursor_line >= scroll + table_height
         then min max_scroll (cursor_line - table_height + 1)
         else scroll
       in
       (* The window is cut at the scroll the cursor settled, not the stored
          one. Cut before, a cursor that moved further than a row -- a page
          key, a list that shrank -- drew its rows outside the window, and
          they came out blank. *)
       let table_window = Rows.of_list ~first:scroll ~height:table_height table in
       (* Row 0 of [table] is the header in table mode, so a cursor over the
          data rows is one lower than the line it marks. Stacked mode has no
          header: line 0 is the first binding's item. *)
       for i = 0 to table_height - 1 do
         let index = scroll + i in
         match Rows.at table_window index with
         | Some line ->
             let marked =
               if table_mode && index = 0 then "  " ^ Ansi.bold ^ line ^ Ansi.reset
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
                 "  " ^ fit_width (Terminal_text.single_line line) (max 1 (cols - 7))
               in
               if i = 0
               then box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) line
               else box_line_styled buf cols ~style:(Theme.recede ()) line))
           detail));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_models));
  finish_surface state ~surface_key:"config_models" ~rows:terminal_rows ~cols buf

let config_metadata_style = function
  | Masc_tui_runtime_config_view.Neutral -> Theme.recede ()
  | Good -> Theme.ok () | Warning -> Theme.warn () | Bad -> Theme.bad ()

(* What the runtime.toml body spends above the source: the server identity,
   one row per metadata line, and the rule under them. *)
let config_heading_rows ~cols (state : state) =
  1 + List.length (config_metadata_summary state) + 1
  + List.length (runtime_config_edit_lines ~cols state)
  + (if Option.is_none state.runtime_account_form
        && Option.is_some state.runtime_config_view_error then 1 else 0)

(* The source rows the frame shows, and the height the cursor keeps itself
   inside. One number for both: the frame is [surface_chrome]'s, so what it
   spends is [surface_chrome_rows] and the heading above, not a literal. *)
let config_content_height (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  max 1
    (Masc_tui_types.surface_body_rows state ~terminal_rows
     - surface_chrome_rows - config_heading_rows ~cols state)

let runtime_config_status_scroll_limit state ~terminal_rows ~cols =
  let room = max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows - 5) in
  max 0 (List.length (runtime_config_status_lines state ~cols) - room)

let render_runtime_config_status state =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"config-status"
    ~title:(screen_title " MASC System / runtime.toml status")
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
(* The voice pane and its wizard: a fixed head and footer around lines read
   through [state.config_scroll]. Both drew every line into the surface budget,
   and [finish_surface] keeps the leading rows of a frame that runs over, so a
   long endpoint list or probe report lost its tail and then its footer with no
   key that could bring them back. The offset is clamped here, against the
   lines actually laid out, and reported back as [Voice_scroll]. *)
let finish_voice_surface (state : state) ~terminal_rows ~cols ~head ~body ~hints =
  let lines = frame_lines body in
  let height =
    (* The rows under the head, less the box bottom and the footer. *)
    max 1
      (Masc_tui_types.surface_body_rows state ~terminal_rows
       - List.length (frame_lines head) - 2)
  in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.config_scroll
  in
  let buf = Buffer.create (Buffer.length head + Buffer.length body + 256) in
  Buffer.add_buffer buf head;
  List.iteri
    (fun index line ->
      if index >= scroll && index < scroll + height then begin
        Buffer.add_string buf line;
        Buffer.add_char buf '\n'
      end)
    lines;
  (* The rows the reading does not fill. Without them the box bottom and the
     footer sit under the last line drawn, wherever that lands, and the pane
     ends in the middle of the frame with blank rows under it. It is the same
     hand-drawn frame the cheat sheet and the answering overlay were moved off
     for the same reason.

     How many were drawn is the window, not a tally of it: [normalize] holds
     [scroll] at or under [count - height], so the loop above draws exactly
     this many. *)
  let drawn = min height (max 0 (List.length lines - scroll)) in
  for _ = drawn + 1 to height do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);
  finish_surface state ~clamped:(Voice_scroll scroll) ~surface_key:"voice"
    ~rows:terminal_rows ~cols buf
;;

(* Voice metadata is a literal document. Wrap before boxing, so the boxed
   rows counted by [finish_voice_surface] include every endpoint and draft
   value rather than the clipped prefix of each logical line. *)
let voice_body_rows cols content =
  let width = framed_inner_width cols in
  if Message_layout.display_width content <= width then [ content ]
  else Message_layout.wrap_words ~max_cells:width content
;;

let voice_body_line buf cols content =
  List.iter (fun row -> box_line buf cols (row ^ Ansi.reset))
    (voice_body_rows cols content)
;;

let voice_body_line_styled buf cols ~style content =
  List.iter (box_line_styled buf cols ~style) (voice_body_rows cols content)
;;

let render_voice_wizard (state : state) (session : Masc_tui_voice_wizard_session.voice_wizard_session) =
  let terminal_rows, cols = get_terminal_size () in
  let head = Buffer.create 256 in
  let buf = Buffer.create 2048 in
  let field name value =
    voice_body_line buf cols
      (Printf.sprintf "  %s%-12s%s %s" Ansi.dim name Ansi.reset (Terminal_text.single_line value))
  in
  let draft = session.vws_draft in
  let side =
    match draft.Voice_wizard.section with
    | Voice_setup.Tts -> "speech out"
    | Voice_setup.Stt -> "speech in"
  in
  let shown value = if String.trim value = "" then Masc_tui_theme.Glyph.no_value else value in
  let steps = Voice_wizard.steps draft in
  let position =
    let rec index n = function
      | [] -> None
      | step :: rest -> if step = session.vws_step then Some n else index (n + 1) rest
    in
    match index 1 steps with
    | Some n -> Printf.sprintf "%d/%d" n (List.length steps)
    | None -> Masc_tui_theme.Glyph.no_value
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title " MASC Voice · setup") state);
  voice_body_line buf cols "";
  voice_body_line buf cols
    (Printf.sprintf "  %sstep %s%s  %s" Ansi.dim position Ansi.reset
       (Voice_wizard.step_prompt session.vws_step));
  voice_body_line buf cols "";
  (* The answer being given. A closed set shows its current value and the keys
     that walk it; a text field shows what has been typed, with a cursor so an
     empty field is visibly a field. *)
  (match session.vws_step with
   | Voice_wizard.Section ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold side
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Provider ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold
          (Voice_wizard.provider_label draft.Voice_wizard.provider)
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Review ->
     (match Voice_wizard.gaps draft with
      | [] ->
        voice_body_line buf cols
          (Printf.sprintf "    %senter saves this%s" Ansi.bold Ansi.reset)
      | gaps ->
        List.iter
          (fun gap ->
            voice_body_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "    %s" (Voice_wizard.gap_message gap)))
          gaps)
   | Voice_wizard.Name
   | Voice_wizard.Address
   | Voice_wizard.Credential
   | Voice_wizard.Model
   | Voice_wizard.Voice ->
     let caret = if Masc_tui_voice_wizard_session.voice_wizard_is_sending session then "" else "▏" in
     let input =
       Message_layout.input_viewport
         ~max_cells:(max 0 (framed_inner_width cols - 4 - Message_layout.display_width caret))
         (Terminal_text.single_line session.vws_input)
     in
     box_line head cols
       (Printf.sprintf "    %s%s%s%s" Ansi.bold input Ansi.reset caret));
  (match session.vws_step with
   | Voice_wizard.Name | Voice_wizard.Address | Voice_wizard.Credential
   | Voice_wizard.Model | Voice_wizard.Voice ->
       field "typing" session.vws_input
   | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Review -> ());
  (* A local server that never asked for a key answers 200 only while nothing
     sends it one, so the blank is worth saying out loud rather than leaving as
     an empty line. *)
  (match session.vws_step with
   | Voice_wizard.Credential when String.trim session.vws_input = "" ->
     voice_body_line buf cols
       (Printf.sprintf "    %sblank sends no Authorization header%s" Ansi.dim Ansi.reset)
   | Voice_wizard.Address when String.trim session.vws_input = "" ->
     List.iter
       (fun (what, address) ->
         voice_body_line buf cols
           (Printf.sprintf "    %stry %s: %s%s" Ansi.dim what address Ansi.reset))
       (Voice_wizard.suggested_addresses draft.Voice_wizard.section)
   | _ -> ());
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sdraft%s" Ansi.bold Ansi.reset);
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
     voice_body_line buf cols "";
     voice_body_line_styled buf cols ~style:(Theme.warn ()) (Printf.sprintf "  %s" (Terminal_text.single_line status)));
  (* Every endpoint, not just the first that answered. A chain stops at the
     first, which is why a dead fallback reads as healthy until the endpoint in
     front of it goes away. *)
  (match session.vws_probe with
   | [] -> ()
   | lines ->
     voice_body_line buf cols "";
     voice_body_line buf cols (Printf.sprintf "  %swhat answered%s" Ansi.bold Ansi.reset);
     List.iter (fun line -> voice_body_line buf cols (Printf.sprintf "    %s" (Terminal_text.single_line line))) lines);
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:"Enter:next  Up:back  PgUp/PgDn:scroll  Esc:cancel"
;;

(* Assigning a voice to a keeper: two lists, the keeper walking under up and
   down and the voice under the arrows. Drawn instead of the pane rather than
   over it, because both are lists and a list over a list is two cursors a
   reader has to keep apart. *)
let render_voice_agent (state : state) (session : voice_agent_session) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let head = Buffer.create 256 in
  let selector label items cursor draw =
    let position =
      if items = [] then "0/0"
      else Printf.sprintf "%d/%d" (cursor + 1) (List.length items)
    in
    let prefix = Printf.sprintf "  %s %s: " label position in
    let value =
      match List.nth_opt items cursor with
      | None -> Masc_tui_theme.Glyph.no_value
      | Some item -> draw item
    in
    let room = max 1 (framed_inner_width cols - Message_layout.display_width prefix) in
    box_line head cols
      (prefix ^ Ansi.bold ^ Message_layout.fit_middle room value ^ Ansi.reset)
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title " MASC Voice · keeper voices") state);
  (* Both selected owners stay above the scrolling document. Enter therefore
     acts on the displayed pair even after paging through long metadata. *)
  selector "keeper" session.vas_agents session.vas_agent_cursor
    Terminal_text.single_line;
  selector "voice" session.vas_voices session.vas_voice_cursor
    (fun (_, label) -> Terminal_text.single_line label);
  voice_body_line buf cols "";
  (match List.nth_opt session.vas_agents session.vas_agent_cursor with
   | None -> ()
   | Some agent ->
       voice_body_line buf cols ("  Keeper: " ^ Terminal_text.single_line agent));
  (match List.nth_opt session.vas_voices session.vas_voice_cursor with
   | None -> ()
   | Some (voice_id, label) ->
       voice_body_line buf cols ("  Voice: " ^ Terminal_text.single_line label);
       voice_body_line buf cols ("  Voice ID: " ^ Terminal_text.single_line voice_id));
  (match session.vas_status with
   | None -> ()
   | Some status ->
     voice_body_line buf cols "";
     voice_body_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Terminal_text.single_line status));
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_voice_agent ~saving:session.vas_saving ())
;;

let render_voice (state : state) =
  match state.voice_agent_voices, state.voice_wizard with
  | Some session, _ -> render_voice_agent state session
  | None, Some session -> render_voice_wizard state session
  | None, None ->
  let terminal_rows, cols = get_terminal_size () in
  let head = Buffer.create 256 in
  let buf = Buffer.create 2048 in
  let field name value =
    voice_body_line buf cols
      (Printf.sprintf "  %s%-18s%s %s" Ansi.dim name Ansi.reset (Terminal_text.single_line value))
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
                    (* The server resolves it the way the transport does.
                       Choosing between base_url and mcp_url here showed
                       base_url for a voice_mcp endpoint that is called at
                       its mcp_url. A command kind has no address. *)
                    let address =
                      Option.value (string_of [ "address" ] item) ~default:Masc_tui_theme.Glyph.no_value
                    in
                    let off =
                      match member [ "enabled" ] item with
                      | Some (`Bool false) -> "  (disabled)"
                      | Some _ | None -> ""
                    in
                    (* runtime.toml is an operator's file, not this pane's
                       output. box_line's fit_width keeps ANSI, so an id, kind
                       or address carrying control bytes rewrote the screen the
                       moment the voice pane opened. The probe rows below
                       already pass through the same filter. *)
                    Some
                      (Printf.sprintf "    %-20s %s%-18s%s %s%s"
                         (Terminal_text.single_line id) Ansi.dim
                         (Terminal_text.single_line kind)
                         Ansi.reset (Terminal_text.single_line address) off))
              items
        | Some _ | None -> [])
  in
  let show_endpoints section =
    match endpoints section with
    | [] -> ()
    | lines -> List.iter (fun line -> voice_body_line buf cols line) lines
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title " MASC Voice") state);
  voice_body_line buf cols "";
  (* Two independent reads feed this pane: the public config says what loaded,
     and the setup read says which endpoints are declared. They used to share
     one match, so a failed config read also erased the endpoint identities the
     other read had returned. Each section now draws whatever it has. *)
  let loaded_config =
    match (state.voice_config, state.voice_config_error) with
    | Some json, None -> Some json
    | Some _, Some _ | None, Some _ | None, None -> None
  in
  let from_config render =
    match loaded_config with Some json -> render json | None -> ()
  in
  (match (state.voice_config, state.voice_config_error) with
   | _, Some message ->
       (* The distinction the pane exists for, said in words rather than drawn
          as an empty section. *)
       voice_body_line_styled buf cols ~style:(Theme.warn ()) "  voice did not load";
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset)
   | None, None ->
       voice_body_line buf cols (Printf.sprintf "  %sreading…%s" Ansi.dim Ansi.reset)
   | Some json, None ->
       field "status"
         (Option.value (string_of [ "status" ] json)
            ~default:Masc_tui_theme.Glyph.no_value));
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sTTS%s" Ansi.bold Ansi.reset);
  from_config (fun json ->
    field "model"
      (Option.value (string_of [ "tts"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field "voice"
      (Option.value (string_of [ "tts"; "default_voice" ] json) ~default:Masc_tui_theme.Glyph.no_value));
  show_endpoints "tts";
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sSTT%s" Ansi.bold Ansi.reset);
  from_config (fun json ->
    field "model"
      (Option.value (string_of [ "stt"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field "endpoint"
      (Option.value
         (string_of [ "stt"; "active_endpoint"; "enabled" ] json)
         ~default:Masc_tui_theme.Glyph.no_value);
    field "fallback"
      (Option.value
         (string_of [ "stt"; "active_endpoint"; "fallback_configured" ] json)
         ~default:Masc_tui_theme.Glyph.no_value));
  show_endpoints "stt";
  (* Said once, not per section: the endpoints are missing from both when this
     read fails, and repeating it twice would read as two faults. *)
  (match state.voice_setup_error with
   | None -> ()
   | Some message ->
       voice_body_line buf cols "";
       voice_body_line_styled buf cols ~style:(Theme.warn ())
         "  the endpoint list could not be read";
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset));
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sInput%s" Ansi.bold Ansi.reset);
  field "device" (Option.value state.voice_input_device ~default:"unknown");
  voice_body_line buf cols "";
  (* Where the endpoints above come from. With no [voice] section the loader
     reads the standalone JSON, and naming runtime.toml there sent a reader to a
     file that declares nothing. *)
  let declared_by =
    match Option.map (member [ "source" ]) state.voice_setup with
    | Some (Some (`Assoc source)) -> (
        match List.assoc_opt "path" source with
        | Some (`String path) -> Terminal_text.single_line path
        | Some _ | None -> "runtime.toml [voice]")
    | Some (Some _ | None) | None -> "runtime.toml [voice]"
  in
  voice_body_line buf cols
    (Printf.sprintf "  %s%s declares this; the server says what loaded%s"
       Ansi.dim declared_by Ansi.reset);
  (* The keys are the table's, as on every other Config pane. The row was
     written here and left out Esc and q, which the fitter keeps only when
     the hints name them, so the voice pane was the one Config pane that
     named no way out. *)
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_voice)
;;

let render_config (state : state) =
  if state.runtime_config_status_open then render_runtime_config_status state else
  let terminal_rows, cols = get_terminal_size () in
  let path_note = config_path_note state in
  let title =
    config_pane_title ~cols ~name:(screen_title " MASC System") ~note:path_note
      ~clock:
        (Printf.sprintf "%s%s%s" Ansi.dim
           (let now = Unix.localtime (Unix.gettimeofday ()) in
            Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
              now.Unix.tm_sec)
           Ansi.reset)
      state
  in
  (* The frame, its fill and the footer are the contract's. The surface
     subtracted a literal 7 and drew six fixed rows, so the footer stood one
     row above the composer; the key handler read the same short number. *)
  surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"config" ~title
    ~hints:
      (* Projected from the key table rather than spelled here. The literal
         named five keys and no way out -- not because the row ran out of
         cells (78 of 150 at the time) but because nobody wrote Esc or q
         into it. It also named PgUp/PgDn, which the table did not have, so
         the two had drifted in both directions. *)
      (match state.runtime_account_form with
       | Some form when Masc_tui_runtime_account_form.is_saved form ->
         Masc_tui_keys.footer_hints_runtime_account_saved ()
       | Some _ -> Masc_tui_keys.footer_hints_runtime_account_form ()
       | None -> Masc_tui_keys.footer_hints_config ~pane:state.config_pane)
    ~body:(fun ~budget:_ c ->
      (* Where this server reads from, and how old the binary serving it is.
         A stale binary answers every request as confidently as a current
         one, so the age is the only thing on screen that separates them.

         The age is measured first and the paths take what is left: they
         were padded to 28 and 32 cells and cut from the right, so on a
         workspace under /var/folders both read as the same "/var/folders/
         bv/cjrbl01x52s…" while the age behind them left the row. A path's
         deciding end is its tail, which [fit_middle] keeps. *)
      (match state.server_identity with
       | None -> c.push (Ansi.dim ^ "  (server identity unread)" ^ Ansi.reset)
       | Some identity ->
           let base = Terminal_text.single_line identity.Tui_decode.sid_base_path in
           let masc = Terminal_text.single_line identity.Tui_decode.sid_masc_root in
           let age = binary_age_text identity.Tui_decode.sid_binary_commit_age_s in
           (* On a workspace that follows the convention the masc root is the
              base path with one segment added, so drawing it whole spends the
              base path's cells saying the base path again. Under /var/folders
              both were cut to "/var/fold\xe2\x80\xa6" and neither could be read.
              Named against the label beside it the nested case costs twelve
              cells and the base keeps the rest. A root that is not under the
              base is the reading worth the room, and still draws whole. *)
           let masc =
             let prefix = base ^ "/" in
             let prefix_len = String.length prefix in
             if String.length masc > prefix_len
                && String.starts_with ~prefix masc
             then
               "<base>/"
               ^ String.sub masc prefix_len (String.length masc - prefix_len)
             else masc
           in
           let labels = "  base " ^ "   masc " ^ "   binary " in
           let room =
             framed_inner_width cols
             - Message_layout.display_width labels
             - Message_layout.display_width age
           in
           let base_cells = Message_layout.display_width base in
           let masc_cells = Message_layout.display_width masc in
           let base, masc =
             if base_cells + masc_cells <= room then base, masc
             else
               (* A path that fits its half keeps its whole self and the
                  other takes the rest; two long ones split the room. The
                  shorter path is never cut to make room for a blank. *)
               let half = room / 2 in
               let base_room, masc_room =
                 if base_cells <= half then base_cells, room - base_cells
                 else if masc_cells <= half then room - masc_cells, masc_cells
                 else half, room - half
               in
               ( Message_layout.fit_middle base_room base
               , Message_layout.fit_middle masc_room masc )
           in
           c.push
             (Printf.sprintf "%s  base %s   masc %s   binary %s%s" Ansi.dim base masc
                age Ansi.reset));
      List.iter (fun (tone, text) ->
        c.push_styled ~style:(config_metadata_style tone)
          ("  " ^ Terminal_text.single_line text)) (config_metadata_summary state);
      List.iter (fun line -> c.push_styled ~style:(Theme.warn ()) ("  " ^ line))
        (runtime_config_edit_lines ~cols state);
      c.push_divider ();
      let content_height = config_content_height state in
      (* The account form stands where the file is drawn: it is opened on that
         file, and what it saves is that file with one provider added. *)
      match state.runtime_account_form with
      | Some form ->
          List.iter c.push
            (Masc_tui_runtime_account_form.rows ~width:(framed_inner_width cols) form);
          (* The saved form stays open for its copy key, and the footer can
             lose it: the save notice leads that row and the fitter keeps only
             the way out, so CI run 36397938379 drew "Enter / Esc:close"
             without [y]. The card names its keys itself, as the link card
             does. *)
          if Masc_tui_runtime_account_form.is_saved form then
            c.push ("  " ^ Masc_tui_keys.footer_hints_runtime_account_saved ())
      | None ->
      (match state.runtime_config_view_error with
       | Some detail ->
         c.push ((Theme.bad ()) ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset)
       | None -> ());
      match state.runtime_config_view with
      | None ->
          if Option.is_none state.runtime_config_view_error then
            c.push (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset)
      | Some _ ->
          let rows = runtime_config_active_rows state in
          let total = List.length rows in
          let max_scroll = max 0 (total - content_height) in
          let scroll = max 0 (min state.config_scroll max_scroll) in
          let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
          for i = 0 to content_height - 1 do
            match Rows.at rows_window (scroll + i) with
            | Some segments ->
                (* Painted through [lexed_span], the table the Code surface
                   reads. The runtime config is TOML and the lexer already
                   answers for it; what was missing was anyone asking. *)
                let line = String.concat "" (List.map lexed_span segments) in
                let line =
                  Printf.sprintf "%s%4d%s  %s" Ansi.dim (scroll + i + 1)
                    Ansi.reset line
                in
                if scroll + i = state.runtime_config_cursor then
                  c.push_selected (Masc_tui_theme.strip_sgr line)
                else c.push line
            | None -> ()
          done)

(* /about: the candle over the surface, with what the TUI is running under
   -- its colour scheme and how many Keepers the workspace holds. *)
let render_about (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let theme =
    Terminal_text.single_line_or ~default:"default" state.theme_choice
  in
  let keepers =
    match state.keepers_error, state.local_workspace with
    | Some _, _ -> Masc_tui_emblem_screen.Keepers_unreadable
    | None, Local_workspace_unread -> Masc_tui_emblem_screen.Keepers_unread
    | None, Local_workspace_read ->
        Masc_tui_emblem_screen.Keepers_read (List.length state.keepers)
  in
  surface_chrome ~overflow:Fits ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"about" ~title:(screen_title " MASC") ~hints:"c:candle  Esc:close"
    ~body:(fun ~budget c ->
      Masc_tui_emblem_screen.about_body
        ~cols:(framed_inner_width cols) ~rows:budget
        ~origin:(c.next_origin ())
        ~frame:state.emblem_frame
        ~keepers:(match keepers with
          | Masc_tui_emblem_screen.Keepers_read _ ->
              List.map (fun (keeper : Tui_decode.keeper) ->
                let portrait =
                  match (keeper_reading state keeper).Keeper_control.liveness with
                  | Keeper_control.Present runtime -> runtime.kr_portrait
                  | Keeper_control.Unobserved | Keeper_control.Absent
                  | Keeper_control.Invalid _ ->
                      Keeper_portrait_equipment.Unavailable "Keeper equipment not observed"
                in
                keeper.k_name, portrait) state.keepers
          | Masc_tui_emblem_screen.Keepers_unreadable
          | Masc_tui_emblem_screen.Keepers_unread -> [])
        ~caption:
          [ Masc_tui_theme.tone Masc_tui_theme.Accent
            ^ "MASC \xc2\xb7 Multi-Agent Shared Context" ^ Ansi.reset
          ; Ansi.dim
            ^ Masc_tui_emblem_screen.about_facts ~theme keepers
            ^ Ansi.reset
          ]
      |> List.iter c.push)

let render_surface (state : state) =
  match state.view with
  | Overview -> render_overview state
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
       | Board_list -> Masc_tui_render_board.render_board_list state
       | Board_compose -> Masc_tui_render_board.render_board_compose state
       | Board_read post_id ->
           match Board_detail.view_for state.board_detail ~post_id with
           | Board_detail.Ready (post, _, _) -> Masc_tui_render_board.render_board_read state post
           | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
               (match List.find_opt (fun p -> p.bp_id = post_id) state.board_posts with
                | Some post -> Masc_tui_render_board.render_board_read state post
                | None ->
                    let terminal_rows, cols = get_terminal_size () in
                    surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"board-read"
                      ~title:(screen_title (" MASC Board / " ^ Terminal_text.single_line post_id))
                      ~hints:Masc_tui_keys.footer_hints_board_pending
                      ~body:(fun ~budget:_ c ->
                        match Board_detail.view_for state.board_detail ~post_id with
                        | Board_detail.Failed detail ->
                            c.push_styled ~style:(Theme.bad ())
                              ("  " ^ Terminal_text.single_line detail)
                        | Board_detail.Absent -> c.push "  Board post has not been loaded. Press r to retry."
                        | Board_detail.Loading -> c.push "  Loading Board post..."
                        | Board_detail.Ready _ -> ())))
  | Planning ->
      (match state.task_detail_id, state.task_focus, state.planning_mode with
       | Some _, Overview_tasks.Task_focus _, Planning_list ->
           (match Task_selection.detail_row
                    ~detail_id:state.task_detail_id ~tasks:state.tasks_domain with
            | Some task -> render_task_detail state task
            | None -> render_work_tasks state)
       | None, Overview_tasks.Task_focus _, Planning_list -> render_work_tasks state
       | _, _, Planning_list -> render_planning_list state
       | _, _, Planning_detail goal_id ->
           let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
           match List.find_opt (fun g -> g.pg_id = goal_id) goals with
           | Some goal ->
               let confirmation = planning_confirmation_view state ~goal_id in
               render_planning_detail state
                 ~armed:(goal_action_armed_for state goal_id) ~confirmation goal
           | None ->
               (match state.home_opened_request with
                | Some (Home_goal_confirmation selected) when selected = goal_id ->
                    let terminal_rows, cols = get_terminal_size () in
                    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
                      ~surface_key:"planning_detail"
                      ~title:("Goal · " ^ Terminal_text.single_line goal_id)
                      ~status:[] ~hints:"Esc:Dashboard  r:refresh"
                      ~body:(fun ~budget:_ c ->
                        c.push (match state.planning_error with
                          | Some error -> " Goal detail unavailable · " ^ Terminal_text.single_line error
                          | None -> " Goal detail not read · waiting for its source"))
                | Some _ | None -> render_planning_list state))
  | Approvals when (match state.ask_answer_mode with Ask_answering _ -> true | Ask_browsing -> false) ->
      Masc_tui_render_approvals.render_question_reader state
  | Approvals ->
      (* Open on the row the cursor is on. An ask that resolves while it is
         open takes the row with it, so the detail closes rather than showing
         something the queue no longer holds. *)
      (match
         if state.approval_detail_open then
           List.nth_opt (Masc_tui_approvals_model.approval_items state) state.approval_cursor
         else None
       with
       | Some row -> Masc_tui_render_approvals.render_approval_detail state row
       | None -> Masc_tui_render_approvals.render_approvals state)
  | Verification -> render_verification state
  | Harness -> render_harness state
  | Fusion ->
      (match state.fusion_launch, state.fusion_mode with
       | Some (Fusion_launch_reading_presets _), _ -> Masc_tui_render_fusion.render_fusion_launch state ~form:None
       | Some (Fusion_launch_open form), _ -> Masc_tui_render_fusion.render_fusion_launch state ~form:(Some form)
       | Some (Fusion_launch_started _), Fusion_list | None, Fusion_list ->
           Masc_tui_render_fusion.render_fusion_list state
       | (Some (Fusion_launch_started _) | None), Fusion_detail run_id ->
           Masc_tui_render_fusion.render_fusion_detail state run_id
       | (Some (Fusion_launch_started _) | None), Fusion_historical_detail reference ->
           Masc_tui_render_fusion.render_fusion_detail state reference.fhe_run_id)
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
  | Resources -> Masc_tui_render_resources.render_resources state
  | Code ->
      if state.repository_changes_open then render_repository_changes state
      else Masc_tui_render_code.render_code state
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

(* The plain body's line count and the window the frame shows it in, for the
   keys that scroll it. *)
let context_inspector_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let count =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, _) -> List.length lines
    | Split _ -> 0
  in
  (count, surface_window_height state ~terminal_rows ~count)

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

(* The context inspector, through the overlay contract. The frame counts its
   rows and fills under a short body, which this pane did by hand with a loop
   of empty lines.

   The title opened on " Context" where every other overlay opens on MASC and
   its name, and spelled the tabs "1:stack 2:request 3:proof" -- key and label
   in the grammar of a footer hint, with the current one told apart only by
   colour. The tabs are the shared strip now, and the digits are the footer's
   to name. The footer's "[/] turn" had no colon, so the fitter read it as a
   note rather than a key. *)
let render_context_inspector state =
  let terminal_rows, cols = get_terminal_size () in
  let keeper =
    Option.value ~default:"no Keeper" state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  (* What the numbers describe: a reading in flight, or one received some
     time ago. The pane does not poll, so without the age a reading from
     before the current turn read as the current turn. *)
  let refreshing =
    if state.context_inspector_loading then Ansi.dim ^ "  refreshing" ^ Ansi.reset
    else
      match state.context_inspector_reading, state.context_inspector_read_at with
      | Some _, Some read_at ->
          let age = Float.max 0. (Unix.gettimeofday () -. read_at) in
          Ansi.dim ^ "  read " ^ Masc_tui_message_layout.span_text age ^ " ago" ^ Ansi.reset
      | Some _, None | None, (Some _ | None) -> ""
  in
  (* The search query, drawn where the typing lands: the Keepers strip's
     own indicator sits on a surface this pane replaced. *)
  let search_marker = search_marker_styled state in
  let tabs =
    tab_strip
      ~width:
        (tab_strip_width ~cols
           ~before:(screen_title " MASC Context" ^ "  " ^ keeper ^ refreshing ^ "  ")
           ~after:search_marker)
      ~press:(fun tab text -> pressable (Press_context_tab tab) text)
      (List.map
         (fun (label, tab) -> (label, state.context_inspector_tab = tab, tab))
         [ ("stack", Masc_tui_context_inspector.Composition)
         ; ("request", Masc_tui_context_inspector.Exact_input)
         ; ("proof", Masc_tui_context_inspector.Input_map)
         ])
  in
  let hints =
    match state.context_inspector_exact with
    | Some _ -> "j/k:scroll  Esc:list"
    | None -> (
        match
          state.context_inspector_tab, cols >= keeper_split_threshold_cols
        with
        | (Masc_tui_context_inspector.Exact_input | Masc_tui_context_inspector.Input_map), true ->
            "1/2/3 or Tab:switch  [ / ]:turn  /:search  j/k:select or scroll  h/l:pane  Enter:open exact  r:refresh  Esc:close"
        | _ ->
            "1/2/3 or Tab:switch  [ / ]:turn  /:search  j/k:select  Enter:open exact  r:refresh  Esc:close")
  in
  let content = context_inspector_content_lines ~cols state in
  (* The plain shapes are one list, so the contract windows it and says which
     of its lines are showing; the inspector's overflow used to be cut with
     nothing saying so (#38623). The split pins its summary and headers above
     two windows of its own. *)
  let overflow =
    match content with
    | Plain (lines, selected) ->
        let height =
          surface_window_height state ~terminal_rows ~count:(List.length lines)
        in
        (* The cursor names a row, the window follows it: on the single-column
           shapes nothing lives under the row, so the smallest move that keeps
           it drawn is the right one. *)
        let scroll =
          match selected with
          | None -> state.context_inspector_scroll
          | Some cursor ->
              Masc_tui_scroll.ensure_visible ~cursor ~height
                (Masc_tui_scroll.normalize ~count:(List.length lines) ~height
                   state.context_inspector_scroll)
        in
        Scrolled
          { scroll; report = (fun scroll -> Context_inspector_scroll scroll) }
    | Split _ -> Paged_by_cursor
  in
  surface_chrome ~overflow state ~terminal_rows ~cols
    ~surface_key:"context-inspector"
    ~frame:Chrome_overlay
    ~title:
      (screen_title " MASC Context" ^ "  " ^ keeper ^ refreshing ^ "  " ^ tabs
       ^ search_marker)
    ~hints
    ~body:(fun ~budget:content_height c ->
      match content with
      | Plain (lines, _) -> List.iter c.push lines
      | Split { common; left; right } ->
          (* The summary clips to the frame rather than overflowing it: on a
             short terminal the split gives way before the pane draws a row
             past its last. *)
          List.iteri
            (fun index line -> if index < content_height then c.push line)
            common;
          let split_height =
            context_split_pane_height ~content_height
              ~common_len:(List.length common)
          in
          if split_height > 0 then begin
            (* Both columns are header :: rows, so the heads are total. The
               header row stays pinned above the windows -- it carries the
               focus caret, and a caret that scrolls away stops saying which
               pane hears j/k. *)
            context_split_lines ~cols ~left_width:(context_split_width cols)
              ~left:[ List.hd left ] ~right:[ List.hd right ]
            |> List.iter c.push;
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
            context_split_lines ~cols ~left_width:(context_split_width cols)
              ~left:
                (context_split_window ~height:body_height ~offset:left_offset
                   (List.tl left))
              ~right:
                (context_split_window ~height:body_height ~offset:right_offset
                   (List.tl right))
            |> List.iter c.push
          end)

(* The height an overlay shows [count] rows in, for the overlays that say
   which of their lines are showing: one row comes off when they overflow,
   because the "[lines a-b/n]" row is drawn inside the same body.
   [Masc_tui_scroll.content_height] owns that rule; the frame supplies the
   chrome. *)
let overlay_window_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:framed_chrome_rows ~count
    ~preview_keep:None ~overflow_takes_row:true

(* The "[lines a-b/n]" row an overflowing overlay draws under its rows, or
   nothing when every row fits. The row's height is the one
   [overlay_window_height] took off. *)
let overlay_window_row ~scroll ~height count =
  Option.map
    (fun row -> Theme.recede () ^ row ^ Ansi.reset)
    (Masc_tui_scroll.position_row ~scroll ~height count)

(* The sheet's rows and the viewport that shows them, at this width. One
   answer for the two readers -- the keypress that bounds the scroll and the
   frame that draws it -- so [G] cannot land the scroll a row past what the
   frame is showing, and a press the frame cannot spend is not taken. *)
let help_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let header = help_masthead state in
  let count =
    List.length
      (Masc_tui_help.sheet ~header ~cols
         (help_lines ~width:(Masc_tui_help.line_cells ~cols) state))
  in
  (count, overlay_window_height ~rows ~count)

(* The [:] palette: a typed filter over every jump the strip and roster
   offer. The list is the same [Masc_tui_palette.palette_matches] the Enter key resolves, so
   what is highlighted is what will run. *)
let render_palette (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let typed_question =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        Masc_tui_palette.palette_typed_question state.palette_query
    | Masc_tui_types.Palette_choice _ -> None
  in
  let explicit_question =
    match typed_question with
    | Some (question, Some symbol) -> Some (question, symbol)
    | Some (_, None) | None -> None
  in
  let matches = Masc_tui_palette.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  let origin =
    if Option.is_some state.lane_addons then "Lane Add-ons"
    else match List.find_opt (fun (_, surface) -> surface = state.view)
        Masc_tui_keys.help_surfaces with
      | Some (title, _) -> title
      | None -> "current screen"
  in
  let title, prompt, action =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        (" MASC Command palette", ":", if Option.is_some typed_question then "ask" else "run")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_palette.code_cursor_line_symbols state) in
        ( Printf.sprintf " %s · %d names on line %d" choice_question names choice_line
        , "filter:", "ask" )
  in
  (* The title names the palette the way the key table does (":" command
     palette) and the prompt follows it. It was "Quick Jump & Navigation" with
     a lightning glyph between them: the glyph said nothing, and the entries
     are not all jumps -- settings, the gate modes, a task or a post run from
     the same list, which is why Enter reads "run".

     The overlay contract draws the box and fills the rows under a short list
     of matches, so the footer stays on the composer's row. *)
  let caret = "\xe2\x96\x8c" in
  let prompt = Ansi.bold ^ prompt ^ Ansi.reset ^ " " in
  let inner_width = framed_inner_width cols in
  let prompt_width = Message_layout.display_width prompt in
  let caret_width = Message_layout.display_width caret in
  (* Keep the end being edited on screen. The masthead yields before the
     filter loses all of its cells; it returns as the viewport grows. *)
  let query = Terminal_text.single_line state.palette_query in
  let title = screen_title title ^ "  " in
  let title =
    if Message_layout.display_width title + prompt_width + caret_width
       + Message_layout.display_width query > inner_width
    then "" else title
  in
  let query_width =
    max 0
      (inner_width - Message_layout.display_width title - prompt_width
       - caret_width)
  in
  let query =
    Message_layout.input_viewport ~max_cells:query_width
      query
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"palette"
    ~frame:Chrome_overlay
    ~title:
      (title ^ prompt ^ query
       ^ Masc_tui_theme.tone Masc_tui_theme.Accent ^ caret ^ Ansi.reset)
    (* [key:label] items, two spaces apart, the way every other footer is
       written. In the dotted form this row was one item with no colon, so
       {!Masc_tui_footer} could shed no whole key and keep no door: it fell
       through to the cell cut, where [Esc] survived only when the budget
       happened to reach it. test_a_row_in_another_grammar_loses_its_door
       measures that across widths. The count keeps no colon on purpose --
       it is not a key, and it is the first thing a narrow row should give
       up. *)
    ~hints:
      (Printf.sprintf "%d/%d  Enter:%s  Up/Down:select  Home/End:first/last  Ctrl-U:clear  Esc:close"
         (if total = 0 then 0 else cursor + 1)
         total action)
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        ("   From " ^ origin ^ " · Esc returns here");
      match explicit_question with
      | Some (question, symbol) ->
          c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ question ^ " "
            ^ Terminal_text.single_line symbol);
          c.push "   Ask about this symbol in the file open on Code"
      | None ->
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "   %d commands · %d/%d · type to filter"
              total (if total = 0 then 0 else cursor + 1) total);
          let list_rows = max 1 (budget - 2) in
          let first = max 0 (cursor - list_rows + 1) in
          matches
          |> List.filteri (fun i _ -> i >= first && i < first + list_rows)
          |> List.iteri (fun visible_index (label, _) ->
               if first + visible_index = cursor then
                 c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ label)
               else c.push ("   " ^ label));
          if total = 0 then c.push "   No matching command · Ctrl-U clears the filter")

(* The patch review overlay. [surface_chrome] owns the box, the fill and the
   footer's row, so the rows are not counted here and the keys on screen are
   the footer's alone. *)
(* The diff's rows and the rows the overlay shows, computed once for the
   renderer that draws them and the keys that scroll them. The keys used to
   move ten rows whatever the window was, and to reach the end by leaving five
   rows on screen -- a number the renderer's own clamp then corrected, which is
   why it went unnoticed. *)
let patch_modal_horizontal_limit (state : state) =
  let _, cols = get_terminal_size () in
  let width = framed_inner_width cols in
  match state.patch_modal_diff with
  | None -> 0
  | Some (_, diff) ->
      List.fold_left
        (fun limit row ->
          let body_width = max 1 (width - Message_layout.display_width (tree_diff_gutter row)) in
          let cells =
            Message_layout.display_width (Terminal_text.single_line row.Tui_decode.gdr_text)
          in
          max limit (max 0 (cells - body_width)))
        0 diff.Tui_decode.gd_rows
;;

let patch_modal_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> None
  in
  let total =
    match diff_opt with
    | Some diff -> List.length diff.Masc.Tui_decode.gd_rows
    | None -> 0
  in
  (* The column heading and the divider under it open the body. *)
  let heading_rows = 2 in
  ( total
  , Masc_tui_scroll.content_height
      ~rows:(Masc_tui_types.surface_body_rows state ~terminal_rows)
      ~chrome:(surface_chrome_rows + heading_rows) ~count:total
      ~preview_keep:None ~overflow_takes_row:true )

let render_patch_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let path_label =
    match state.patch_modal_path with
    | Some p -> p
    | None -> "Active Working Tree"
  in
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> None
  in
  let diff_rows =
    match diff_opt with
    | Some diff -> diff.Masc.Tui_decode.gd_rows
    | None -> []
  in
  let total, content_height = patch_modal_viewport state in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.patch_modal_scroll max_scroll) in
  let limit = patch_modal_horizontal_limit state in
  let hscroll = max 0 (min state.patch_modal_hscroll limit) in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"patch-modal"
    ~frame:Chrome_overlay
    ~overflow:(Self_scrolled (fun () -> Patch_modal_scroll (scroll, hscroll)))
    ~title:
      (screen_title " MASC Patch review" ^ "  " ^ Ansi.bold
       ^ Terminal_text.single_line path_label ^ Ansi.reset)
    ~hints:(Masc_tui_keys.footer_hints_patch_review ())
    ~body:(fun ~budget:_ c ->
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  old / new · col %d/%d" (hscroll + 1) (limit + 1));
      c.push_divider ();
      if total = 0 then
        c.push
          (Ansi.dim
           ^ (match state.patch_modal_error with
              | Some e ->
                  Printf.sprintf "   (diff load error: %s)" (Terminal_text.single_line e)
              | None ->
                  (match diff_opt with
                   | None -> "   (reading patch diff…)"
                   | Some _ -> "   (no pending patch diff loaded)"))
           ^ Ansi.reset)
      else begin
        let width = framed_inner_width cols in
        List.iteri
          (fun index row ->
            if index >= scroll && index < scroll + content_height then
              c.push
                (fit_width
                   (Masc_tui_span.render (tree_diff_row_span ~hscroll ~width row))
                   width))
          diff_rows
      end;
      (* The window's position is a body row, as on the other overlays, and
         [patch_modal_viewport] took its row off when the diff overflows. *)
      Option.iter c.push (overlay_window_row ~scroll ~height:content_height total))

(* The link preview overlay, through the same contract. The title names the
   site, so the footer carries only keys. *)
(* The card, its height and the line count, computed once for the two readers
   that need to agree: the renderer that draws it and the keys that scroll it.
   They did not agree before -- the renderer sized the card to the window while
   the keys moved a fixed five lines -- so a page key covered a quarter of a
   tall window and four windows of a short one. *)
let link_modal_card (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let url_opt =
    match state.link_modal_url with
    | Some u -> Some u
    | None ->
        (match state.link_modal_links with
         | first :: _ -> Some first
         | [] -> None)
  in
  match url_opt with
  | None -> None
  | Some url ->
      let preview = Masc_tui_link_preview.get_preview url in
      let total_links = List.length state.link_modal_links in
      (* Which link of several, and the divider under it. *)
      let nav_rows = if total_links > 1 then 2 else 0 in
      let content_height =
        max 1
          (Masc_tui_types.surface_body_rows state ~terminal_rows
           - surface_chrome_rows - nav_rows)
      in
      let content_lines =
        Masc_tui_link_preview.render_modal_card
          ~width:(framed_inner_width cols) ~height:content_height preview
      in
      Some (url, preview, total_links, content_height, content_lines)

(* The rows the modal shows and the rows it holds, for the page keys. *)
let link_modal_viewport (state : state) =
  match link_modal_card state with
  | None -> (0, 1)
  | Some (_, _, _, content_height, content_lines) ->
      (List.length content_lines, content_height)

let render_link_preview_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  match link_modal_card state with
  | None ->
      surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ~title:
          (screen_title " MASC Link preview" ^ "  " ^ Ansi.dim ^ "(no links)"
           ^ Ansi.reset)
        ~hints:"Esc:close"
        ~body:(fun ~budget:_ c ->
          c.push "  (no web links found in this conversation to preview)")
  | Some (_url, preview, total_links, content_height, content_lines) ->
      let site = Masc_tui_link_preview.site_label preview in
      let total = List.length content_lines in
      let max_scroll = max 0 (total - content_height) in
      let scroll = max 0 (min state.link_modal_scroll max_scroll) in
      surface_chrome state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ~overflow:(Self_scrolled (fun () -> Link_modal_scroll scroll))
        ~title:
          (screen_title " MASC Link preview" ^ "  " ^ Ansi.bold
           ^ Terminal_text.single_line site ^ Ansi.reset)
        ~hints:
          (Masc_tui_link_preview.modal_hints ~total_links
             ~has_image:(Option.is_some preview.Masc_tui_link_preview.image_url))
        ~body:(fun ~budget:_ c ->
          if total_links > 1 then begin
            c.push_styled ~style:(Theme.warn ())
              (Printf.sprintf "  link %d of %d" (state.link_modal_cursor + 1)
                 total_links);
            c.push_divider ()
          end;
          List.iteri
            (fun index line ->
              if index >= scroll && index < scroll + content_height then
                c.push line)
            content_lines)

(* The invite card: the link a /play invite answer carries, and its QR. Where
   each row falls, and whether the QR fits at all, is decided by
   [Masc_tui_play_card.draw]; this only gives each kind of row its look. The
   QR rows arrive coloured and go in as they are: a theme colour on them would
   turn the code into a picture that no phone reads. *)
let play_card_indent = "  "

let render_play_card (state : state) card =
  let terminal_rows, cols = get_terminal_size () in
  (* The window as the operator sees it. The rows and columns a frame is laid
     out in are that less the navigation strip and any pane beside the surface,
     so a size the card asks for is added to this, not to those. *)
  let window_rows, window_cols = Masc_tui_ansi.get_terminal_size () in
  surface_chrome
    ~overflow:(Scrolled { scroll = state.play_invite_scroll;
                          report = (fun scroll -> Play_invite_scroll scroll) })
    state ~terminal_rows ~cols ~surface_key:"play-invite"
    ~frame:Chrome_overlay
    ~title:(screen_title " MASC Play invite")
    ~hints:"j/k:scroll  y:copy link  Esc:close"
    ~body:(fun ~budget c ->
      let width = framed_inner_width cols - String.length play_card_indent in
      List.iter
        (fun row ->
          match row with
          | Masc_tui_play_card.Heading text ->
              c.push_styled ~style:Ansi.bold (play_card_indent ^ text)
          | Masc_tui_play_card.Advice text ->
              c.push_styled ~style:(Theme.recede ()) (play_card_indent ^ text)
          | Masc_tui_play_card.Link_row text | Masc_tui_play_card.Qr_row text ->
              c.push (play_card_indent ^ text)
          | Masc_tui_play_card.Note text ->
              c.push_styled ~style:(Theme.warn ()) (play_card_indent ^ text)
          | Masc_tui_play_card.Qr_needs { columns; rows } ->
              (* The card counts its own cells and says what it lacks. What
                 surrounds them -- the frame, the composer, the agenda strip,
                 the navigation strip -- stays the same when the window grows,
                 so the window needs what it has now plus the card's shortfall
                 in each direction. *)
              c.push_styled ~style:(Theme.warn ())
                (Printf.sprintf
                   "%sthe QR needs a window of %d columns by %d rows"
                   play_card_indent
                   (window_cols + max 0 (columns - width))
                   (window_rows + max 0 (rows - budget)))
          | Masc_tui_play_card.Blank -> c.push_empty ())
        (Masc_tui_play_card.draw card ~width ~rows:budget))

(* The record's rows and the viewport that shows them, the way
   [help_viewport] answers for the sheet: one pair for the keypress that
   bounds the scroll and the frame that draws it, and one row off the height
   when the record has more rows than it can show. *)
let keeper_deletions_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count = List.length (keeper_deletions_lines state ~cols) in
  (count, overlay_window_height ~rows ~count)

(* The deletion record overlay drew its rows and closed the box under them,
   with nothing filling the rows between: on a short record the footer stood in
   the middle of the screen with the composer alone at the bottom (150x44, a
   failed read, footer on row 9). The contract fills to the bottom. *)
let render_keeper_deletions (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = keeper_deletions_lines state ~cols in
  let count, height = keeper_deletions_viewport state in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"keeper-deletions"
    ~frame:Chrome_overlay
    ~title:
      (screen_title " 키퍼 삭제 기록"
       ^ (if state.keeper_deletions_loading then " · 조회/재시도 중" else ""))
    ~hints:(keeper_deletions_hints state ~scrollable:(count > height))
    (* [keeper_deletions_viewport] rather than the budget it is derived from:
       the keypress bounds the scroll against that pair. *)
    ~body:(fun ~budget:_ c ->
      let scroll =
        Masc_tui_scroll.normalize ~count ~height state.keeper_deletions_scroll
      in
      List.iteri
        (fun index text ->
          if index >= scroll && index < scroll + height then c.push text)
        lines;
      (* The record is one JSON document. Measured on the live server, it ran
         past every height: at 44 rows it ended mid-object on "kind":
         "delivered", and the footer named the scroll keys without saying how
         far they had to go. *)
      Option.iter c.push (overlay_window_row ~scroll ~height count))

(* The cheat sheet, through the overlay contract. It drew its box and its rows
   by hand and closed the box under the last row, so a sheet shorter than the
   screen -- a narrow filter, a tall terminal -- put the footer mid-screen. *)
let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let header = help_masthead state in
  let rendered_rows =
    Masc_tui_help.sheet ~header ~cols
      (help_lines ~width:(Masc_tui_help.line_cells ~cols) state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"help"
    ~frame:Chrome_overlay
    (* The title says what state the sheet is in; the keys that change it are
       the footer's, which draws h and Esc on this overlay and never drops Esc.
       Both rows spelled them, so the title said the footer twice. *)
    ~title:
      (screen_title " MASC Cheat Sheet" ^ "  " ^ Ansi.dim
      ^ "hints "
      ^ (if state.hints_visible then "on" else "off")
      ^ Ansi.reset)
    (* The sheet that names every other surface's keys did not name its own.
       It is longer than any terminal -- at 150x78 the later sections are
       still off screen -- so [G] is the difference between reading them and
       pressing [j] forty times, and nothing said [G] exists. The keys are
       handled at masc_tui.ml: "pageup" | "pagedown", "g", "G". *)
    ~hints:"j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  Esc:close"
    (* [help_viewport] rather than the budget it is derived from: the
       keypress bounds the scroll against that pair, and a sheet whose
       drawing used a different height would leave [G] one row short. *)
    ~body:(fun ~budget:_ c ->
      let count, height = help_viewport state in
      let scroll =
        Masc_tui_scroll.normalize ~count ~height state.help_scroll
      in
      List.iteri
        (fun index line ->
          if index >= scroll && index < scroll + height then c.push line)
        rendered_rows;
      (* Which of them these are. The sheet is longer than any terminal --
         at 150x78 the later sections are still off screen -- so a reader
         pressing [j] had no way of telling a page from a hundred. *)
      Option.iter c.push (overlay_window_row ~scroll ~height count))

(* Rows the agenda panel can show, and how many it has. The keypress bounds
   the scroll from the same pair the frame draws with -- the shape
   [Masc_tui_scroll] exists to keep in one place. *)
(* The panel's rows. Built in one place because three readers ask for them:
   the viewport that bounds the scroll, the frame that draws them, and the
   keypress that walks the ones Enter can act on. Three builders would be
   three chances for the cursor to name a row the frame is not drawing. *)
let agenda_lines (state : state) =
  let _terminal_rows, cols = get_terminal_size () in
  Agenda.overlay
    ~now:(Unix.gettimeofday ())
    ~localtime:Unix.localtime
    ~cols:(framed_inner_width cols)
    (Masc_tui_types.agenda state)

(* The panel's rows and the viewport that shows them, the way
   [help_viewport] answers for the sheet: one pair for the keypress that
   bounds the cursor and the frame that draws it, and one row off the height
   when the panel has more rows than it can show. *)
let agenda_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count = List.length (agenda_lines state) in
  (count, overlay_window_height ~rows ~count)

let agenda_scroll_position (state : state) =
  let lines = agenda_lines state in
  let count, height = agenda_viewport state in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.agenda_scroll in
  match state.agenda_navigation with
  | Agenda_read_rows -> scroll
  | Agenda_follow_selection ->
      (match Agenda.selected_index lines ~selected:state.agenda_selected with
       | Some cursor -> Masc_tui_scroll.ensure_visible ~cursor ~height scroll
       | None -> scroll)

let answering_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  ( List.length (answering_lines state)
  , max 1 (framed_content_height ~rows - answering_preview_rows) )

let answering_selected_target (state : state) ~lines =
  let count = List.length lines in
  let _, height = answering_viewport state in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.answering_scroll in
  if state.answering_cursor < scroll || state.answering_cursor >= scroll + height then None
  else
    match List.nth_opt lines state.answering_cursor with
    | Some line -> line.Masc_tui_answering.target
    | None -> None

(* The answering overlay, through the overlay contract. Drawn by hand, a short
   list closed the box right under the preview panel, so the footer stood on
   row 10 of a 26-row terminal. The list now fills its height, the preview
   panel sits on the frame's last rows, and the frame fills nothing because
   nothing is left. Its title was "Live Keeper Turns & Answering" with a half
   circle glyph; the key table names the overlay "answering". *)
let render_answering (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = answering_lines state in
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
      if selected && Option.is_some line.Masc_tui_answering.target then Masc_tui_theme.Glyph.current_entry ^ " "
      else "  "
    in
    caret ^ tone_prefix ^ line.Masc_tui_answering.text ^ Ansi.reset
  in
  let preview_lines =
    let cursor_preview =
      match answering_selected_target state ~lines with
      | Some keeper_name ->
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
      | None -> None
    in
    match cursor_preview with
    | Some (keeper_name, preview) ->
        let doing = Terminal_text.single_line preview.Tui_decode.ktp_status_text in
        let tail =
          match
            Terminal_text.single_line preview.Tui_decode.ktp_text_tail
          with
          | "" -> "(no text reported yet)"
          | tail -> tail
        in
        let preview_width = framed_inner_width cols in
        let name_width = min (Masc_tui_message_layout.display_width (Terminal_text.single_line keeper_name))
          (max 0 ((preview_width - 2) / 2)) in
        [ Ansi.bold ^ fit_width (Terminal_text.single_line keeper_name) name_width
          ^ Ansi.reset ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
          ^ fit_width doing (max 0 (preview_width - name_width - 2))
          ^ Ansi.reset
        ; Ansi.dim ^ tail ^ Ansi.reset
        ]
    | None ->
        [ Ansi.dim ^ "live preview \xe2\x80\x94 none for this row" ^ Ansi.reset
        ; ""
        ]
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"answering"
    ~frame:Chrome_overlay
    (* Enter and Esc are in the footer row below this overlay. *)
    ~title:(screen_title " MASC Answering")
    ~hints:"j/k:move  PgUp/PgDn:page  Home/End  Enter:chat  Esc:close"
    ~body:(fun ~budget c ->
      let content_height = max 1 (budget - answering_preview_rows) in
      let scroll =
        Masc_tui_scroll.normalize
          ~count:(List.length lines)
          ~height:content_height
          state.answering_scroll
      in
      let drawn = ref 0 in
      List.iteri
        (fun i line ->
          if i >= scroll && i < scroll + content_height then begin
            incr drawn;
            c.push (paint ~selected:(i = state.answering_cursor) line)
          end)
        lines;
      for _ = !drawn + 1 to content_height do
        c.push_empty ()
      done;
      (* The fixed preview panel: what the cursor's keeper is doing right now,
         from the turns poll's live glance. Drawn empty rather than omitted so
         the list above never reflows with the cursor. The rule over it says
         which of the list's rows are showing when they overflow, so it costs
         the list no row (#38623). *)
      (match overlay_window_row ~scroll ~height:content_height (List.length lines) with
       | Some row -> c.push row
       | None -> c.push_divider ());
      List.iter c.push preview_lines)
;;

(* The agenda, through the overlay contract. Its sections are usually a few
   rows, and drawn by hand the box closed under them: the footer stood on row
   11 of a 26-row terminal with the composer alone at the bottom. The title was
   "Agenda & Upcoming Timers"; the sections are what is coming up and what is
   waiting on the operator, and the other overlays open on MASC and their name. *)
let render_agenda (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = agenda_lines state in
  let selected = Agenda.selected_index lines ~selected:state.agenda_selected in
  let paint ~selected (line : Agenda.line) =
    let body =
      match line.Agenda.tone with
      | Agenda.Heading -> Ansi.bold ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Wake -> (Theme.recede ()) ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Question -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Quiet -> Ansi.dim ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Failed -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
    in
    (* Reversed rather than marked with a glyph: the rows are already fitted
       to the column and a leading mark would push the right half off. *)
    if selected then Ansi.reverse ^ body ^ Ansi.reset else body
  in
  (* A panel with nothing to open says so on its own footer rather than
     naming a key that would do nothing. *)
  let hints =
    match Agenda.target_indexes lines with
    | [] -> "j/k:scroll  PgUp/PgDn:page  g/G:first/last  Esc:close"
    | _ -> "j/k:move  PgUp/PgDn:page  g/G:first/last  Enter:open  Esc:close"
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"agenda"
    ~frame:Chrome_overlay
    ~title:(screen_title " MASC Agenda")
    ~hints
    (* [agenda_viewport] rather than the budget it is derived from: the
       keypress bounds the cursor against that pair. *)
    ~body:(fun ~budget:_ c ->
      let count, height = agenda_viewport state in
      (* Selection follows refreshes while navigating targets. Reading pages
         owns its window, so repainting cannot pull it away from schedules. *)
      let scroll = agenda_scroll_position state in
      List.iteri
        (fun index line ->
          if index >= scroll && index < scroll + height then
            c.push (paint ~selected:(selected = Some index) line))
        lines;
      (* What falls off this panel is not more of the same: measured at 24
         rows and 100 columns, the panel drew sixteen of its twenty coming
         rows and neither of the two sections under them, and nothing said
         "Waiting on you" and "Stuck on you" were there. *)
      Option.iter c.push (overlay_window_row ~scroll ~height count))
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
  finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows ~cols
    buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render_account_login state view =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"account-login" ~title:(screen_title " MASC Account Login")
    ~hints:(Masc_tui_account_login.hints view)
    ~body:(fun ~budget c ->
      let lines = Masc_tui_account_login.visible_lines ~height:budget ~width:(framed_inner_width cols) view
        |> List.map (function
          | Masc_tui_account_login.Text text -> Masc.Tui_terminal_text.sanitize_terminal_text text
          | Masc_tui_account_login.Terminal line ->
            Masc_tui_sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text line) in
      List.iter (fun line -> c.push (fit_width line (framed_inner_width cols))) lines)


let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"lanes"
    ~title:(screen_title " MASC Lane Add-ons")
    ~hints:(if Option.is_some view.evidence_prompt then "j/k:choose  Enter:preserve  Esc:back"
      else if Option.is_some view.subscription_panel then "j/k:select  Enter:choose/save  a:add  d:remove  J/K:scroll  r:refresh  Esc:back"
      else if Option.is_some view.installer || Option.exists (fun (menu : Masc_tui_lane_addons.action_menu) -> Option.is_some menu.form) view.action_menu
        then "Tab:field  Left/Right:choice  Ctrl-E:items  Ctrl-U:unset  Ctrl-S:review  Esc:cancel"
      else if Option.is_some view.action_menu then "j/k:choose action  Enter:run once  J/K:scroll details  Esc:cancel"
      else Masc_tui_lane_addons.overview_hints view)
    ~body:(fun ~budget c ->
      let lines = Masc_tui_lane_addons.lines ~height:budget ~width:(framed_inner_width cols) view in
      let scroll = max 0 (min view.scroll (max 0 (List.length lines - budget))) in
      lines
      |> List.filteri (fun index _ -> index >= scroll && index < scroll + budget)
      |> List.iter c.push)

(* Whether a frame is a surface or something drawn over one. An overlay
   keeps the surface's strip on its first row, and a press there would change
   the surface under a modal no key can leave that way; it answers only the
   presses that act inside it ([press_changes_the_surface]). *)
type drawn = Surface_drawn | Overlay_drawn

(* One pure frame choice owns overlay priority for both drawing and the
   application's preparation of state tied to an actually visible surface. *)
let frame_choice (state : state) ~terminal_rows =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  if Render_schedule.Viewport.requires_compact_frame ~rows then `Too_small rows
  else match play_card_shown state with
  | Some card -> `Play_card card
  | None -> match state.account_login with
  | Some view -> `Account_login view
  | None when state.palette_open -> `Palette
  | None -> match state.lane_addons with
  | Some view -> `Lane_addons view
  | None ->
      if state.about_open then `About
      else if state.context_inspector_open then `Context
      else if state.keeper_deletions_open then `Keeper_deletions
      else if state.help_open then `Help
      else if state.agenda_open then `Agenda
      else if state.answering_open then `Answering
      else if state.patch_modal_open then `Patch
      else if state.link_modal_open then `Link
      else match state.client_detail with
        | Some client -> `Client_detail client
        | None -> `Surface

let render (state : state) =
  (* Marks number the targets of this frame alone. *)
  Masc_tui_hit.reset press_marks;
  (* And the candle, and any placed picture, is on this frame only if this
     frame draws it. *)
  Masc_tui_emblem_screen.begin_frame ();
  Masc_tui_portrait_view.begin_frame ();
  let frame, clamped, approval, drawn =
  (* Decide the pane before any surface measures the terminal. Modals draw
     over the whole terminal and the Activity screen, both its tabs,
     already fills its own, so neither reserves the columns. *)
  (acting_pane_reserved_cols :=
     let _rows, terminal_cols = Masc_tui_ansi.get_terminal_size () in
     acting_pane_columns state ~terminal_cols);
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  match frame_choice state ~terminal_rows with
  | `Too_small rows ->
    let frame, clamped = render_terminal_too_small state ~rows ~cols in
    (frame, clamped, None, Overlay_drawn)
  | `Play_card card ->
    let frame, clamped = render_play_card state card in
    (frame, clamped, None, Overlay_drawn)
  | `Account_login view -> let frame, clamped = render_account_login state view in (frame,clamped,None,Overlay_drawn)
  | `Lane_addons view ->
    let frame, clamped = render_lane_addons state view in
    (frame, clamped, None, Overlay_drawn)
  | `About ->
    let frame, clamped = render_about state in (frame, clamped, None, Overlay_drawn)
  | `Palette ->
    let frame, clamped = render_palette state in (frame, clamped, None, Overlay_drawn)
  | `Context ->
    let frame, clamped = render_context_inspector state in (frame, clamped, None, Overlay_drawn)
  | `Keeper_deletions ->
    let frame, clamped = render_keeper_deletions state in (frame, clamped, None, Overlay_drawn)
  | `Help ->
    let frame, clamped = render_help state in (frame, clamped, None, Overlay_drawn)
  | `Agenda ->
    let frame, clamped = render_agenda state in (frame, clamped, None, Overlay_drawn)
  | `Answering ->
    let frame, clamped = render_answering state in (frame, clamped, None, Overlay_drawn)
  | `Patch ->
    let frame, clamped = render_patch_modal state in (frame, clamped, None, Overlay_drawn)
  | `Link ->
    let frame, clamped = render_link_preview_modal state in (frame, clamped, None, Overlay_drawn)
  | `Client_detail client ->
    let frame, clamped = render_client_detail state client in
    (frame, clamped, None, Overlay_drawn)
  | `Surface ->
    let frame, clamped = render_surface state in
    let presented_approval =
      match state.view with
      | Approvals ->
          List.nth_opt (Masc_tui_approvals_model.approval_items state) state.approval_cursor
      | Overview | Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
      | Planning
      | Schedules | Verification | Harness | Fusion | Repositories | Changes
      | Connectors | Runtime | Config | Resources | Code | Tools
      | System_logs -> None
    in
    (frame, clamped, presented_approval, Surface_drawn)
  in
  (* The rows are final here, whichever branch drew them: read where each
     pressable text landed and hand the terminal rows without the marks. *)
  let lines, presses =
    Masc_tui_hit.extract press_marks frame.Frame_presenter.lines
  in
  let presses =
    match drawn with
    | Surface_drawn -> presses
    | Overlay_drawn ->
        Masc_tui_hit.filter
          (fun target -> not (press_changes_the_surface target))
          presses
  in
  ({ frame with Frame_presenter.lines }, clamped, approval, presses)
