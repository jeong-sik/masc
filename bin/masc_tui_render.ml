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
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Message_layout = Masc_tui_message_layout
module Tool_detail = Masc_tui_tool_detail
module Retained_view = Masc_tui_retained_view
module Metrics_tail = Masc_tui_metrics_tail
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
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Keeper_snapshot_unread = Masc.Keeper_snapshot_unread
module Render_tools = Masc_tui_render_tools
module Span = Masc_tui_span
module Diff = Masc_tui_diff
module Render_memory = Masc_tui_render_memory

type memory_state = Render_memory.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error


let set_table_frame enabled = table_frame_enabled := enabled

let keeper_roster_name_cells = Masc_tui_roster_pane.pane_cols - 7

(* The main loop uses the target identity to restart the motion when selection
   changes. A short name has no animation target and therefore costs no idle
   repaint. *)
let keeper_roster_marquee_target (state : state) ~cols =
  if not (keeper_roster_pane_shown state ~cols)
     || (state.view = Overview && not state.keeper_navigation_open) then None
  else
    match state.view, selected_keeper state with
    | (Overview | Keepers (Keeper_detail | Keeper_message)), Some keeper ->
        let name = Terminal_text.single_line keeper.k_name in
        if Message_layout.display_width name > keeper_roster_name_cells then
          Some name
        else None
    | ((Overview | Keepers (Keeper_detail | Keeper_message)), None)
    | (Keepers (Keeper_list | (Keeper_logs | (Keeper_calls | Keeper_runtime_pick))), _)
    | ((Acting | (Metrics | (Memory | (Lanes | (Clients | (Board | (Approvals | (Planning | (Schedules | (Verification | (Harness | (Fusion | (Repositories | (Code | (Changes | (Connectors | (Runtime | (Config | (Resources | (Tools | System_logs)))))))))))))))))))), _) -> None

let base_acting_pane_suppressed (state : state) =
  let modal =
    Option.is_some state.account_login || Option.is_some state.lane_addons || state.palette_open
    || Masc_tui_types.modal_owns_keys state
    || state.answering_open || state.memory_fact_detail_open
  in
  modal
  || Masc_tui_types.on_activity_screen state.view
  || Option.is_some (browser_lane_on_screen state)

let normal_acting_pane_columns (state : state) ~terminal_cols =
  if base_acting_pane_suppressed state then 0
  else Masc_tui_acting_pane.drawn_cols ~layout:(acting_pane_layout state) ~cols:terminal_cols

(* If the complete exit warning cannot fit the surface footer, give it the
   whole terminal. The arm's ordinary notice is its identity; stale arms do
   not get to change the frame or authorize a later key. *)
let quit_requires_full_frame (state : state) ~terminal_cols =
  match state.quit_armed, Masc_tui_action_notice.ordinary state.last_action with
  | Some arm, Some ordinary
    when ordinary == Masc_tui_action_notice.quit_ordinary arm.qa_confirmation
         && quit_arm_matches state arm ->
      let content_cols = terminal_cols - normal_acting_pane_columns state ~terminal_cols in
      Message_layout.display_width (fst ordinary) > framed_inner_width content_cols
  | (Some _ | None), (Some _ | None) -> false

let notice_requires_full_frame (state : state) ~terminal_cols ~now =
  let content_cols = terminal_cols - normal_acting_pane_columns state ~terminal_cols in
  let rejection = Masc_tui_action_notice.rejection state.last_action
      ~now ~window:Masc_tui_types.last_action_window_s in
  quit_requires_full_frame state ~terminal_cols
  || Option.exists (fun notice ->
       Message_layout.display_width (Masc_tui_action_notice.rejection_text notice)
       > framed_inner_width content_cols) rejection

let acting_pane_suppressed (state : state) =
  let _, terminal_cols = Masc_tui_ansi.get_terminal_size () in
  base_acting_pane_suppressed state
  || notice_requires_full_frame state ~terminal_cols ~now:(Unix.gettimeofday ())

let acting_pane_columns_at (state : state) ~terminal_cols ~now =
  if notice_requires_full_frame state ~terminal_cols ~now then 0
  else normal_acting_pane_columns state ~terminal_cols

let acting_pane_columns (state : state) ~terminal_cols =
  acting_pane_columns_at state ~terminal_cols ~now:(Unix.gettimeofday ())

(* Pure preparation shared with the loop. Terminal dimensions are the raw
   cached measurement, before the surface strip and composer reserve rows. *)
let acting_pane_chunk_projection (state : state) ~terminal_rows ~terminal_cols ~now =
  let rows = surface_body_rows state ~terminal_rows:(max 1 (terminal_rows - 1)) in
  if acting_pane_columns_at state ~terminal_cols ~now = 0
     || Render_schedule.Viewport.requires_compact_frame ~rows
     || state.acting_pane_tab = Masc_tui_acting_pane.Tab_changes
  then None
  else Some (recent_chunk_projection state)
;;

let operator_action_section state item : Masc_tui_detail_reading.section =
  { heading = Masc_tui_home.operator_action_label state item
  ; body = Masc.Operator_action_reason.diagnostic item ^ "\n\n"
      ^ Yojson.Safe.pretty_to_string (Masc.Operator_action_reason.to_json item) }

let operator_notice_sections state =
  match Masc_tui_home.home_notice_lines (Masc_tui_home.prepare state) with
  | [] -> []
  | notices -> [{ Masc_tui_detail_reading.heading = ui_text state ~ko:"운영 알림 · 별도 관측" ~en:"Operations notices · separate observations"
                ; body=String.concat "\n" notices }]

let operator_action_reading state item =
  Masc_tui_detail_reading.create ~ko:(state.ui_language=Lang_ko)
    ~title:(ui_text state ~ko:"원래 조치 관측" ~en:"Original action observation")
    (operator_action_section state item :: operator_notice_sections state)

let operator_actions_reading (state : state) =
  let text ko en = ui_text state ~ko ~en in
  let sections = match operator_action_observation state with
    | None ->
        [{ Masc_tui_detail_reading.heading = text "조치 원인 미확인" "Reasons unavailable"
         ; body = text "서버의 구조화된 조치 관측을 아직 확인하지 못했습니다."
             "The server's structured action observation has not been confirmed." }]
    | Some (Tui_decode.Operator_actions_unavailable {diagnostics;error}) ->
        [{ Masc_tui_detail_reading.heading = text "원래 서버 진단 · 이동 대상 미확인" "Original server diagnostics · targets unknown"
         ; body = String.concat "\n" diagnostics ^ "\n\n"
             ^ text "구조화된 관측을 읽지 못함: " "Structured observation unavailable: " ^ error }]
    | Some (Tui_decode.Operator_actions_observed []) ->
        [{ Masc_tui_detail_reading.heading = text "조치 원인" "Action reasons"
         ; body = text "이 서버 관측에는 조치가 필요한 이유가 없습니다."
             "This server observation reports no reason requiring action." }]
    | Some (Tui_decode.Operator_actions_observed items) -> List.map (operator_action_section state) items in
  Masc_tui_detail_reading.create ~ko:(state.ui_language=Lang_ko)
    ~title:(text "조치가 필요한 이유" "Why action is needed")
    (let retained = match state.home_selected with
      | Some (Home_operator_action (authority,_,original)) when authority=state.workspace_authority
          && not (Option.exists (List.exists (Masc.Operator_action_reason.equal original)) (operator_actions state)) ->
          let section = operator_action_section state original in
          [{section with heading=ui_text state ~ko:"이전 선택 · " ~en:"Prior selection · " ^ section.heading}]
      | Some (Home_operator_action _ | Home_request _ | Home_approvals | Home_agenda
          | Home_resume _ | Home_read_last _ | Home_choose_keeper | Home_create_keeper) | None -> [] in
     retained @ sections @ operator_notice_sections state)

(* Requests and capacity have separate observation paths. In particular a
   working HTTP connection does not make a retained fleet reading current. *)
let overview_capacity_lines (state : state) =
  let text ko en = ui_text state ~ko ~en in
  let quiet line = Theme.recede () ^ line ^ Ansi.reset in
  let warning line = Theme.warn () ^ line ^ Ansi.reset in
  let now = Unix.gettimeofday () in
  let ko = state.ui_language = Lang_ko in
  match fleet_stream_view state with
  | Masc_tui_fleet_stream.Awaiting_first_reading ->
      [warning (text "미관측 · fleet 첫 관측 대기" "Not observed · awaiting fleet reading")]
  | Unreachable { since } ->
      [warning (text "미관측 · fleet에 연결하지 못함" "Not observed · fleet unreachable")
      ; quiet (Masc_tui_fleet_line.unreachable_text ~ko ~now ~since)]
  | Unavailable { degradation; disconnected_since } ->
      [warning (text "미관측 · fleet 스캔 실패" "Not observed · fleet scan unavailable")
      ; quiet (Masc_tui_fleet_line.unavailable_text ~ko ~now ~degradation ~disconnected_since)]
  | Cannot_read failure ->
      [warning (text "미관측 · fleet 응답을 읽지 못함" "Not observed · fleet response unreadable")
      ; quiet (Masc_tui_fleet_line.failure_text ~ko failure)]
  | Reading { reading; trouble } ->
      let fleet = reading.fleet in
      let retained = Option.is_some trouble
        || state.workspace_identity <> Workspace_identity_match in
      let scope =
        if retained then
          [warning (text "이전 관측 · 현재 여력 미확인" "Retained reading · current capacity unknown")]
        else []
      in
      let grade = Masc_tui_fleet_line.status_text ~ko fleet.fs_status in
      let grade_style =
        if retained then Theme.warn ()
        else if fleet.fs_operator_action_required then Theme.bad ()
        else if not (Masc_tui_fleet_line.status_is_ok fleet.fs_status)
        then Theme.warn () else Theme.ok () in
      scope
      @ (if not retained && Masc_tui_fleet_line.status_is_ok fleet.fs_status
            && not fleet.fs_operator_action_required then []
         else [grade_style ^ grade ^ Ansi.reset])
      @ [text
          (Printf.sprintf "실행 중 %d · 기동 가능 %d" fleet.fs_running_count fleet.fs_bootable_count)
          (Printf.sprintf "Running %d · bootable %d" fleet.fs_running_count fleet.fs_bootable_count)
      ; text
          (Printf.sprintf "턴 여력 %d/%d · 부족 %d"
             (fleet.fs_target_reaction_capacity - fleet.fs_reaction_capacity_shortfall)
             fleet.fs_target_reaction_capacity fleet.fs_reaction_capacity_shortfall)
          (Printf.sprintf "Turn capacity %d/%d · shortfall %d"
             (fleet.fs_target_reaction_capacity - fleet.fs_reaction_capacity_shortfall)
             fleet.fs_target_reaction_capacity fleet.fs_reaction_capacity_shortfall)]
      @ Option.to_list (Option.map (fun detail -> warning (Masc_tui_fleet_line.trouble_text ~ko ~now detail)) trouble)
      @ (if state.workspace_identity = Workspace_identity_match then [] else
           [warning (workspace_identity_unconfirmed ~ko)])
      @ Option.to_list (Option.map (fun detail ->
          (if retained then quiet else warning) (Terminal_text.single_line detail))
          (Masc_tui_fleet_line.blocker_text ~ko fleet))
      @ Option.to_list (Option.map quiet (Masc_tui_fleet_line.owner_scan_text ~ko fleet))

let overview_header (state : state) ~cols =
  here_row ~cols state ~path:[]
    ~readings:[ Terminal_text.single_line state.workspace ] ~position:None

let render_overview (state : state) home =
  let terminal_rows, full_cols = get_terminal_size () in
  let sidebar =
    if state.keeper_navigation_open then
      Some (keeper_roster_pane_cols,
        fun ~rows buf -> keeper_roster_pane ~focused:true state
          ~rows:(rows + 1) ~cols:keeper_roster_pane_cols buf)
    else None
  in
  let cols = full_cols - (match sidebar with None -> 0 | Some (width, _) -> width) in
  let all_decisions = Masc_tui_home.home_decision_rows home in
  let continuation = Masc_tui_home.home_continue_rows home in
  let selected = Masc_tui_home.home_selected_action home in
  let capacity_lines = overview_capacity_lines state in
  (* The last day of tool calls, whatever window Usage's [w] holds
     ([tool_series_days]). A reading that is missing says so in words, never as
     a count of zero. A press on the line opens Usage on its Calls section. *)
  let tool_calls_line ~cells =
    let window = Masc_tui_usage_calls.Last_day in
    pressable Press_usage_calls
      (match state.tool_series with
       | Tool_series_read calls when calls.Masc_tui_usage_calls.window = window ->
           Masc_tui_usage_calls.summary_line ~cells calls
       | Tool_series_read _ | Tool_series_unread ->
           Masc_tui_usage_calls.summary_note ~cells window "reading…"
       | Tool_series_error reason ->
           Masc_tui_usage_calls.summary_note ~cells window
             ("unavailable: " ^ Terminal_text.single_line reason))
  in
  surface_chrome ~overflow:Fits ?sidebar state ~terminal_rows ~cols:full_cols ~surface_key:"overview"
    ~title:(overview_header state ~cols)
    ~status:[]
    ~hints:(if state.keeper_navigation_open then
              Masc_tui_keys.keeper_navigation_hints ~lang:state.ui_language
            else Masc_tui_keys.footer_hints ~lang:state.ui_language Overview)
    ~body:(fun ~budget:chrome_budget c ->
      let rows_started = Masc_tui_frame_timing.start_stage () in
      let body = Masc_tui_home.home_body home ~scroll:state.home_decision_scroll ~budget:chrome_budget in
      if body.hb_help then
        c.push (" " ^ Ansi.dim
          ^ Masc_tui_footer.help_hint ~ko:(state.ui_language = Lang_ko)
          ^ ui_text state ~ko:" — 화면별 조작" ~en:" — every screen's keys" ^ Ansi.reset);
      if body.hb_shortcuts then
        c.push (" " ^ ui_text state ~ko:"v:조치 원인" ~en:"v:action reasons"
          ^ "  " ^ pressable (Press_surface Approvals)
              (ui_text state ~ko:"p:승인·질문" ~en:"p:Requests")
          ^ "  " ^ pressable (Press_surface Metrics)
              (ui_text state ~ko:"m:사용량" ~en:"m:Usage"));
      List.iter c.push body.hb_notices;
      if body.hb_selection_changed then
        c.push_styled ~style:(Theme.warn ())
          (ui_text state ~ko:" 선택한 관측이 바뀌었습니다 · j/k:다시 선택"
             ~en:" Selected observation changed · j/k to choose again");
      let draw_row (action,label) =
        let line = "  " ^ label in
        if Option.equal equal_home_action (Some action) selected then c.push_selected line
        else c.push line in
      let available = List.length body.hb_rows + body.hb_spare in
      let card_rows =
        if List.length body.hb_rows <> body.hb_total then None
        else
          let titles : Masc_tui_overview_cards.titles =
            { decisions=ui_text state ~ko:"확인할 일" ~en:"Needs your decision"
            ; continuation=ui_text state ~ko:"대화" ~en:"Conversations"
            ; capacity=ui_text state ~ko:"실행 여력" ~en:"Execution capacity"
            ; actions=ui_text state ~ko:"조치가 필요한 이유" ~en:"Why action is needed" } in
          let status ~cells = List.concat_map
              (Message_layout.wrap_styled_words ~max_cells:(max 1 cells)) capacity_lines in
          Masc_tui_overview_cards.draw ~titles
            ~empty_decisions:(ui_text state ~ko:"대기 중인 요청이 없습니다." ~en:"No decision is waiting on you.")
            ~inner:(framed_inner_width cols) ~rows:available
            ~is_selected:(fun action -> Option.equal equal_home_action (Some action) selected)
            ~decisions:all_decisions ~decisions_whole:true ~continuation ~status
            ~actions:(Masc_tui_home.home_operator_rows home) in
      (match card_rows with
       | Some rows ->
           List.iter c.push rows;
           if available > List.length rows then c.push (tool_calls_line ~cells:(framed_inner_width cols))
       | None ->
           if body.hb_spare > 0 then
             c.push_styled ~style:Ansi.bold
               (ui_text state ~ko:" 바로가기" ~en:" Destinations");
           List.iter draw_row body.hb_rows;
           let spare = max 0 (body.hb_spare - 1) in
           List.take spare (capacity_lines @ [tool_calls_line ~cells:(framed_inner_width cols)])
           |> List.iter c.push);
      Masc_tui_frame_timing.finish_stage ~name:"overview.rows" rows_started)


let task_detail_viewport = Masc_tui_render_work.task_detail_viewport
let planning_detail_viewport = Masc_tui_render_work.planning_detail_viewport
let schedule_detail_viewport = Masc_tui_render_work.schedule_detail_viewport

type lane_run_tool_counts = Masc_tui_render_lanes.lane_run_tool_counts = {
  completed : int;
  deferred : int;
  failed : int;
  other : int;
}

let render_client_detail = Masc_tui_render_lanes.render_client_detail
let render_clients = Masc_tui_render_lanes.render_clients
let render_lanes = Masc_tui_render_lanes.render_lanes

let render_keeper_list = Masc_tui_render_keepers.render_keeper_list
let render_keeper_detail = Masc_tui_render_keepers.render_keeper_detail
let render_keeper_logs = Masc_tui_render_keepers.render_keeper_logs

let render_system_log_detail = Masc_tui_render_activity.render_system_log_detail
let render_system_logs = Masc_tui_render_activity.render_system_logs
let render_keeper_calls = Masc_tui_render_activity.render_keeper_calls
let render_acting = Masc_tui_render_activity.render_acting



(* The step the memory screens take from Keepers. *)
let memory_step (state : state) = ui_text state ~ko:"기억" ~en:"memory"

let render_memory (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let open Masc.Tui_decode_memory_health in
  let keepers =
    match state.memory_health with
    | None -> []
    | Some s -> s.mhs_keepers
  in
  let shown = List.length keepers in
  let memory_title readings =
    here_row ~cols state ~path:[ memory_step state ] ~readings ~position:None
  in
  let title =
    match state.memory_health with
    | None ->
        let reading_note =
          match state.memory_health_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        memory_title [ String.trim reading_note ]
    | Some s ->
        memory_title
          [ count_reading state Masc_tui_value.Count.Keeper shown
          ; (match current_memory_starving_count s with
             | Some count -> Printf.sprintf (if ko then "기억 필요 %d" else "%d need memory") count
             | None -> if ko then "기억 필요 ? (일부 미조회)" else "? need memory (unread rows)")
          ; (let tm = Unix.localtime s.mhs_generated_at in
             Printf.sprintf (if ko then "%02d/%02d %02d:%02d 관측" else "read %02d/%02d %02d:%02d")
               (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
               tm.Unix.tm_hour tm.Unix.tm_min)
          ]
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"memory"
    ~title ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view)
    ~body:(fun ~budget c ->
      Render_memory.render_memory_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_memory_changes (state : state) keeper_name =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"memory-changes"
    ~title:
      (here_row ~cols state
         ~path:
           [ memory_step state
           ; Terminal_text.single_line keeper_name
           ; ui_text state ~ko:"변화" ~en:"changes" ]
         ~readings:[] ~position:None)
    ~hints:(Masc_tui_keys.footer_hints_memory_changes ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      Masc_tui_render_keeper_memory.changes_lines state ~cols ~max_lines:budget
        ~now:(Unix.gettimeofday ()) ~keeper_name |> List.iter c.push)

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
  let ko = state.ui_language = Lang_ko in
  let facts = Masc_tui_types.memory_fact_rows state in
  let total = List.length facts in
  let cursor = max 0 (min state.memory_facts_cursor (max 0 (total - 1))) in
  let lines =
    match List.nth_opt facts cursor with
    | None -> [ ui_text state ~ko:"    읽을 사실이 없습니다." ~en:"    This list has no fact row to read." ]
    | Some row -> Render_memory.memory_fact_detail_lines ~ko ~cols row
  in
  let lines = Render_memory.memory_facts_scope_lines ~full:true ~cols state @ lines in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory-fact-detail"
    ~frame:Chrome_overlay
    (* The drawing says what it actually clamped to, so [G]'s sentinel and a
       scroll past the end are corrected in the state rather than only on the
       screen. *)
    ~overflow:
      (Scrolled
         { scroll = state.memory_fact_detail_scroll
         ; report = (fun scroll -> Memory_fact_detail_scroll scroll) })
    ~title:
      (here_row ~cols state
         ~path:[ memory_step state; ui_text state ~ko:"사실" ~en:"fact" ]
         ~readings:[] ~position:None)
    (* The keys project the same bindings the help sheet carries, so the
       footer and [?] cannot teach different keys. *)
    ~hints:(Masc_tui_keys.memory_fact_detail_hints ~lang:state.ui_language)
    ~body:(fun ~budget:_ c -> List.iter c.push lines)

let rec render_memory_facts (state : state) =
  if state.memory_fact_detail_open then render_memory_fact_detail state
  else render_memory_facts_list state

and render_memory_facts_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let open Masc.Tui_decode in
  let ko = state.ui_language = Lang_ko in
  let keeper_name = Render_memory.facts_keeper_label ~ko state.memory_facts_keeper in
  let rows = Masc_tui_types.memory_fact_rows state in
  let total = List.length rows in
  let filter_label =
    Render_memory.memory_category_filter_text ~ko state.memory_facts_category
  in
  let query_label =
    match state.search with
    | Some q when String.length (String.trim q) > 0 ->
        Printf.sprintf (if ko then " · 찾기 \"%s\"" else " · find \"%s\"") (Terminal_text.single_line (String.trim q))
    | Some _ -> if ko then " · 찾기 \"\"" else " · find \"\""
    | None ->
        if String.length (String.trim state.search_last) > 0 then
          Printf.sprintf (if ko then " · 필터 \"%s\"" else " · filter \"%s\"") (Terminal_text.single_line (String.trim state.search_last))
        else ""
  in
  let title =
    here_row ~cols state ~path:[ memory_step state; keeper_name ]
      ~position:None
      ~readings:
        [ Render_memory.facts_title_reading ~ko
        (match Masc_tui_types.memory_facts_snapshot state with
         | None ->
           Render_memory.Facts_unread
             { reading =
                 here_missing_reading state
                   ~error:(Masc_tui_types.memory_facts_failure state) }
         | Some _ ->
           Render_memory.Facts_loaded { total; filter_label; query_label }) ]
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"memory-facts"
    ~title ~hints:(Masc_tui_keys.footer_hints_memory_facts ~lang:state.ui_language ~cols ~has_rows:(total > 0))
    ~body:(fun ~budget c ->
      Render_memory.render_memory_facts_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)


let repository_studio_content_height =
  Masc_tui_render_repositories.repository_studio_content_height

let browser_lane_scroll_limit =
  Masc_tui_render_connectors.browser_lane_scroll_limit
let browser_lane_selection_scroll =
  Masc_tui_render_connectors.browser_lane_selection_scroll
let browser_history_scroll_limit =
  Masc_tui_render_connectors.browser_history_scroll_limit
let render_connectors = Masc_tui_render_connectors.render_connectors

let render_runtime_detail = Masc_tui_render_runtime.render_runtime_detail
let render_runtime = Masc_tui_render_runtime.render_runtime
let tools_scrolled = Masc_tui_render_runtime.tools_scrolled
let render_tools = Masc_tui_render_runtime.render_tools
let render_metrics = Masc_tui_render_runtime.render_metrics
let render_runtime_pick = Masc_tui_render_runtime.render_runtime_pick

let config_models_scrolled = Masc_tui_render_config.config_models_scrolled
let config_models_stacked = Masc_tui_render_config.config_models_stacked
let config_content_height = Masc_tui_render_config.config_content_height
let prompts_detail_viewport = Masc_tui_render_config.prompts_detail_viewport
let presets_viewport = Masc_tui_render_config.presets_viewport
let runtime_config_status_scroll_limit =
  Masc_tui_render_config.runtime_config_status_scroll_limit
let render_runtime_params = Masc_tui_render_config.render_runtime_params
let render_prompts = Masc_tui_render_config.render_prompts
let render_presets = Masc_tui_render_config.render_presets
let render_themes = Masc_tui_render_config.render_themes
let render_config_models = Masc_tui_render_config.render_config_models
let render_voice = Masc_tui_render_config.render_voice
let render_config = Masc_tui_render_config.render_config


let render_about = Masc_tui_render_overlays.render_about
let render_keeper_navigation = Masc_tui_render_overlays.render_keeper_navigation

let render_surface ~home (state : state) =
  let _, cols = get_terminal_size () in
  if state.keeper_navigation_open && cols < keeper_split_threshold_cols then
    render_keeper_navigation state
  else
  match state.view with
  | Overview -> render_overview state (Lazy.force home)
  | Keepers Keeper_list ->
      if state.repository_changes_open then Masc_tui_render_repositories.render_repository_changes state
      else render_keeper_list state
  | Keepers Keeper_detail ->
      if state.repository_changes_open then Masc_tui_render_repositories.render_repository_changes state
      else render_keeper_detail state
  | Keepers Keeper_logs -> render_keeper_logs state
  | Keepers Keeper_calls -> render_keeper_calls state
  | Keepers Keeper_message ->
      if state.repository_changes_open then Masc_tui_render_repositories.render_repository_changes state
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
               (match List.find_opt (fun p -> p.bp_id = post_id) (board_posts state) with
                | Some post -> Masc_tui_render_board.render_board_read state post
                | None ->
                    let terminal_rows, cols = get_terminal_size () in
                    surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"board-read"
                      ~title:
                        (here_row ~cols state
                           ~path:
                             [ Masc_tui_render_board.board_step state
                             ; Terminal_text.single_line post_id ]
                           ~readings:[] ~position:None)
                      ~hints:(Masc_tui_keys.footer_hints_board_pending ~lang:state.ui_language)
                      ~body:(fun ~budget:_ c ->
                        match Board_detail.view_for state.board_detail ~post_id with
                        | Board_detail.Failed detail ->
                            c.push_styled ~style:(Theme.bad ())
                              ("  " ^ Terminal_text.single_line detail)
                        | Board_detail.Absent -> c.push (ui_text state ~ko:"  글을 아직 읽지 못했습니다. r로 다시 읽습니다." ~en:"  Board post has not been loaded. Press r to retry.")
                        | Board_detail.Loading -> c.push (ui_text state ~ko:"  글을 읽는 중…" ~en:"  Loading Board post…")
                        | Board_detail.Ready _ -> ())))
  | Planning -> Masc_tui_render_work.render_planning state
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
  | Verification -> Masc_tui_render_verification.render_verification state
  | Harness -> Masc_tui_render_verification.render_harness state
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
      (match state.memory_facts_keeper, state.memory_page with
       | Some keeper_name, Memory_changes -> render_memory_changes state keeper_name
       | Some _, Memory_facts -> render_memory_facts state
       | None, (Memory_facts | Memory_changes) -> render_memory state)
  | Repositories ->
      (match state.workspace_activity_repo with
       | Some repo_id -> Masc_tui_render_repositories.render_workspace_activity state repo_id
       | None -> Masc_tui_render_repositories.render_repositories state)
  | Changes -> Masc_tui_render_repositories.render_changes state
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
      if state.repository_changes_open then Masc_tui_render_repositories.render_repository_changes state
      else Masc_tui_render_code.render_code state
  | Tools -> render_tools state
  | Acting -> render_acting state
  | Metrics -> render_metrics state
  | System_logs ->
      (match (system_logs_page state).lp_detail_seq with
       | None -> render_system_logs state
       | Some seq -> render_system_log_detail state seq)
  | Schedules -> Masc_tui_render_work.render_schedules state

let context_inspector_viewport =
  Masc_tui_render_overlays.context_inspector_viewport
let context_inspector_detail_viewport =
  Masc_tui_render_overlays.context_inspector_detail_viewport
let render_context_inspector = Masc_tui_render_overlays.render_context_inspector
let help_viewport = Masc_tui_render_overlays.help_viewport
let render_palette = Masc_tui_render_overlays.render_palette
let patch_modal_horizontal_limit =
  Masc_tui_render_overlays.patch_modal_horizontal_limit
let patch_modal_viewport = Masc_tui_render_overlays.patch_modal_viewport
let render_patch_modal = Masc_tui_render_overlays.render_patch_modal
let link_modal_viewport = Masc_tui_render_overlays.link_modal_viewport
let render_link_preview_modal =
  Masc_tui_render_overlays.render_link_preview_modal
let render_play_card = Masc_tui_render_overlays.render_play_card
let keeper_deletions_viewport =
  Masc_tui_render_overlays.keeper_deletions_viewport
let render_keeper_deletions = Masc_tui_render_overlays.render_keeper_deletions
let render_help = Masc_tui_render_overlays.render_help
let agenda_lines = Masc_tui_render_overlays.agenda_lines
let agenda_viewport = Masc_tui_render_overlays.agenda_viewport
let agenda_scroll_position = Masc_tui_render_overlays.agenda_scroll_position
let answering_viewport = Masc_tui_render_overlays.answering_viewport
let answering_selected_target =
  Masc_tui_render_overlays.answering_selected_target
let render_answering = Masc_tui_render_overlays.render_answering
let render_agenda = Masc_tui_render_overlays.render_agenda
let render_terminal_too_small =
  Masc_tui_render_overlays.render_terminal_too_small
let render_account_login = Masc_tui_render_overlays.render_account_login
let render_collab = Masc_tui_render_overlays.render_collab
let render_lane_addons = Masc_tui_render_overlays.render_lane_addons
(* Whether a frame is a surface or something drawn over one. An overlay
   keeps the surface's strip on its first row, and a press there would change
   the surface under a modal no key can leave that way; it answers only the
   presses that act inside it ([press_changes_the_surface]). *)
type drawn = Surface_drawn | Overlay_drawn

(* One pure frame choice owns overlay priority for both drawing and the
   application's preparation of state tied to an actually visible surface. *)
let frame_choice_after_play (state : state) =
  match state.account_login with
  | Some view -> `Account_login view
  | None when state.palette_open -> `Palette
  | None -> match state.collab with
  | Some view -> `Collab view
  | None -> match state.lane_addons with
  | Some view -> `Lane_addons view
  | None -> match current_board_reader state with
  | Some reader -> `Detail_reading (Masc_tui_board_reader.document reader)
  | None -> match current_chat_call_reader state with
  | Some reader -> `Detail_reading (Masc_tui_chat_call_reader.document reader)
  | None -> match current_task_inspector state with
  | Some reader -> `Detail_reading (Masc_tui_original_task_read.document (task_inspection_source reader.tci_original))
  | None -> match current_detail_reading state with
  | Some reading -> `Detail_reading reading
  | None ->
      if state.help_open then `Help
      else if state.about_open then `About
      else if state.context_inspector_open then `Context
      else if state.keeper_deletions_open then `Keeper_deletions
      else match state.queue_panel with
      | Some panel -> `Queue panel
      | None ->
        if state.agenda_open then `Agenda
        else if state.answering_open then `Answering
        else if state.patch_modal_open then `Patch
        else if state.link_modal_open then `Link
        else match state.client_detail with
          | Some client -> `Client_detail client
          | None -> `Surface

let compact_frame_required (state : state) ~terminal_rows ~terminal_cols ~now =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  Render_schedule.Viewport.requires_compact_frame ~rows
  || notice_requires_full_frame state ~terminal_cols ~now

let frame_choice (state : state) ~terminal_rows ~terminal_cols ~now =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  if compact_frame_required state ~terminal_rows ~terminal_cols ~now then `Too_small rows
  else match play_card_shown state with
  | Some card -> `Play_card card
  | None -> frame_choice_after_play state

let queue_below_play state ~terminal_rows ~terminal_cols ~now =
  if compact_frame_required state ~terminal_rows ~terminal_cols ~now then None
  else match frame_choice_after_play state with
    | `Queue panel -> Some panel
    | `Account_login _ | `Palette | `Collab _ | `Lane_addons _ | `Detail_reading _
    | `About | `Context | `Keeper_deletions | `Help | `Agenda | `Answering
    | `Patch | `Link | `Client_detail _ | `Surface -> None

(* Input follows the same top frame as rendering. Only the inspector's visible
   row-search editor accepts text; its covered surface never owns paste. *)
let panel_input_owner (state : state) ~terminal_rows ~terminal_cols ~now =
  let module Presented = Masc_tui_presented in
  match frame_choice state ~terminal_rows ~terminal_cols ~now with
  | `Help -> Some Presented.Help
  | `About -> Some Presented.About
  | `Context ->
      Some (if Option.is_some state.search then Presented.Context_search
            else Presented.Context)
  | `Agenda -> Some Presented.Agenda
  | `Answering -> Some Presented.Answering
  | `Too_small _ | `Play_card _ | `Account_login _ | `Palette | `Collab _
  | `Lane_addons _ | `Detail_reading _ | `Keeper_deletions
  | `Queue _ | `Patch | `Link | `Client_detail _ | `Surface -> None

let render ~home ~compact_recovery_notice (state : state) =
  let fusion_detail_owned =
    let detail = match state.fusion_mode with
      | Fusion_detail _ | Fusion_historical_detail _ -> true
      | Fusion_list -> false in
    let unobscured = match state.fusion_launch with
      | None | Some (Fusion_launch_started _) -> true
      | Some (Fusion_launch_reading_presets _ | Fusion_launch_open _) -> false in
    state.view = Fusion && detail && unobscured in
  if not fusion_detail_owned then Masc_tui_render_fusion.clear_fusion_trace_projection ();
  (* Marks number the targets of this frame alone. *)
  Masc_tui_hit.reset press_marks;
  (* So do the panes: a frame that ends without recording any, the
     too-small notice, has none to select from. *)
  frame_panes := Masc_tui_pane_selection.no_panes;
  frame_acting_pane := Masc_tui_acting_pane.empty_frame;
  frame_tools_task := None;
  reset_chat_row_actions ();
  (* And the candle, and any placed picture, is on this frame only if this
     frame draws it. *)
  Render_schedule.Activity_tick.begin_frame ();
  Masc_tui_emblem_screen.begin_frame ();
  Masc_tui_portrait_view.begin_frame ();
  let frame, clamped, approval, drawn =
  (* Decide the pane before any surface measures the terminal. Modals draw
     over the whole terminal and the Activity screen, both its tabs,
     already fills its own, so neither reserves the columns. *)
  let now = Unix.gettimeofday () in
  (acting_pane_reserved_cols :=
     let _rows, terminal_cols = Masc_tui_ansi.get_terminal_size () in
     acting_pane_columns_at state ~terminal_cols ~now);
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let _, terminal_cols = Masc_tui_ansi.get_terminal_size () in
  match frame_choice state ~terminal_rows ~terminal_cols ~now with
  | `Too_small _ ->
    let frame, clamped = render_terminal_too_small state
        ~recovery_notice:compact_recovery_notice ~rows:terminal_rows ~cols in
    (frame, clamped, None, Overlay_drawn)
  | `Play_card card ->
    let frame, clamped = render_play_card state card in
    (frame, clamped, None, Overlay_drawn)
  | `Account_login view -> let frame, clamped = render_account_login state view in (frame,clamped,None,Overlay_drawn)
  | `Collab view -> let frame, clamped = render_collab state view in (frame,clamped,None,Overlay_drawn)
  | `Lane_addons view ->
    let frame, clamped = render_lane_addons state view in
    (frame, clamped, None, Overlay_drawn)
  | `Detail_reading reading ->
    let frame, clamped = Masc_tui_render_overlays.render_detail_reading state reading in
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
  | `Queue panel ->
    let frame, clamped = Masc_tui_render_overlays.render_queue_panel state panel in
    (frame, clamped, None, Overlay_drawn)
  | `Patch ->
    let frame, clamped = render_patch_modal state in (frame, clamped, None, Overlay_drawn)
  | `Link ->
    let frame, clamped = render_link_preview_modal state in (frame, clamped, None, Overlay_drawn)
  | `Client_detail client ->
    let frame, clamped = render_client_detail state client in
    (frame, clamped, None, Overlay_drawn)
  | `Surface ->
    let frame, clamped = render_surface ~home state in
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
  ({ frame with Frame_presenter.lines }, clamped, approval, presses, !frame_panes,
   !frame_acting_pane, chat_row_actions (), !frame_tools_task)
