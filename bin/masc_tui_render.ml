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

(* Dashboard rows summarize sources without changing their meaning. The full
   task list lives in Work, Keeper rows in Keepers, and account windows in
   Usage. A missing reading is never projected as a zero. *)
(* The Dashboard keeps its working layout through loading and failure. *)
let overview_header (state : state) =
  Printf.sprintf "%s  %s[%s]%s  %s"
    (screen_title " MASC Dashboard") Ansi.dim
    (Terminal_text.single_line state.workspace) Ansi.reset
    (connection_badge state)

let render_overview (state : state) =
  let terminal_rows, full_cols = get_terminal_size () in
  let sidebar =
    if state.keeper_navigation_open then
      Some (keeper_roster_pane_cols,
        fun ~rows buf -> keeper_roster_pane ~focused:true state
          ~rows:(rows + 1) ~cols:keeper_roster_pane_cols buf)
    else None
  in
  let cols = full_cols - (match sidebar with None -> 0 | Some (width, _) -> width) in
  let all_decisions = Masc_tui_home.home_decision_rows state in
  let continuation = Masc_tui_home.home_continue_rows state in
  let selected = Masc_tui_home.home_selected_action state in
  let overview_error, overview = overview_refresh_reading state in
  let health =
    match Terminal_text.optional_single_line overview_error, overview with
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
  surface_chrome ~overflow:Fits ?sidebar state ~terminal_rows ~cols:full_cols ~surface_key:"overview"
    ~title:(overview_header state)
    ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
    ~hints:(if state.keeper_navigation_open then Masc_tui_keys.keeper_navigation_hints
            else Masc_tui_keys.footer_hints Overview)
    ~body:(fun ~budget c ->
      (* The one-time door line: the first screen a reader meets names the
         sheet's key, because a footer item is easy to read past before the
         habit of reading footers exists. The first input of any kind
         retires it and writes [tui].help_hint_shown. *)
      let budget =
        if state.help_hint_shown then budget
        else begin
          c.push
            (" " ^ Ansi.dim
             ^ Masc_tui_footer.help_hint_item ^ " — every screen's keys"
             ^ Ansi.reset);
          max 0 (budget - 1)
        end
      in
      c.push
        (" " ^ pressable (Press_surface Approvals)
           (Ansi.dim ^ "p:Approvals / Questions" ^ Ansi.reset));
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
      let notices = Masc_tui_home.home_notice_lines state
        |> List.take (max 0 (budget - warning_rows)) in
      List.iter c.push notices;
      let budget = max 0 (budget - List.length notices) in
      let decisions = List.drop first all_decisions |> List.take capacity in
      let actions = decisions @ continuation in
      (* Headers and action destinations take precedence over health/history
         context. The request window preserves continuation below it even
         when the queue contains more rows than the viewport. *)
      let essential_rows = List.length actions + 2 + warning_rows in
      if budget >= essential_rows && (all_decisions = [] || capacity > 0) then begin
        let spare = budget - essential_rows in
        (* Action outcomes stay above the destinations they affect. Passive
           health/history context follows the destinations, using only spare
           rows, so opening Home starts with a decision or a place to resume. *)
        let candle = Masc_tui_candle.summary_lines state.candle_observation
          |> List.concat_map (fun line ->
            Message_layout.wrap_words ~max_cells:(max 1 (cols - 4))
              (Terminal_text.single_line line))
          |> List.map (fun line -> None, " " ^ line) in
        let candle_fits = spare >= 2 + List.length candle in
        let health = if candle_fits then health else
          match Masc_tui_candle.compact_status state.candle_observation with
          | None -> health
          | Some status -> " " ^ status ^ " ·" ^ health in
        let readings = [None, health; Some (Theme.recede ()), work]
          @ (if candle_fits then candle else []) in
        let shown_readings = List.take spare readings in
        let draw_context = List.iter (function
          | None, text -> c.push text
          | Some style, text -> c.push_styled ~style text) in
        let gaps = spare - List.length shown_readings in
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
        if gaps > 0 then c.push_empty ();
        c.push_styled ~style:Ansi.bold " Continue";
        List.iter draw_row continuation;
        if gaps > 1 && shown_readings <> [] then c.push_empty ();
        draw_context shown_readings
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
    ~title ~hints:(Masc_tui_keys.footer_hints_memory_facts ~cols)
    ~body:(fun ~budget c ->
      Render_memory.render_memory_facts_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)


let repository_studio_content_height =
  Masc_tui_render_repositories.repository_studio_content_height

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
     A source hint contributes a row only when the selected node has one, and
     a refused gesture its rows until the next input. *)
  6 + (if Option.is_some (browser_lane_source_hint view) then 1 else 0)
  + List.length (Browser_lane_view.unserved_rows view)

(* The picker's rows besides its choices and what an empty connection list
   says: the status row, the heading and the divider above the choices, and
   the detail row for the highlighted choice below them. *)
let browser_picker_frame_rows = 4

(* The cells a BiDi host row has behind the surface's two-cell indent. *)
let browser_host_row_cells ~cols = max 1 (framed_inner_width cols - 2)

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
       ^ Option.value (connection_label view) ~default:"no browser")
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
        | Loading
            ( _
            , Viewport_pointer
                { action =
                    ( Browser_lane.Activate_tab | Browser_lane.Click _
                    | Browser_lane.Fill _ | Browser_lane.Scroll _
                    | Browser_lane.Hover_at _ | Browser_lane.Click_at _
                    | Browser_lane.Drag _ | Browser_lane.Follow_link _
                    | Browser_lane.Click_node _ | Browser_lane.Fill_node _ )
                ; _
                } ) -> "Interacting with selected browser viewport…", Theme.info ()
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
          (* The rows under the choices cannot be scrolled to. Where they
             report a BiDi host, one that runs or ran, the first of them
             keep a place however many choices there are, with the row that
             says more is hidden, unless that would leave too few choices to
             choose from. *)
          let host_rows =
            Browser_lane_view.bidi_host_rows ~width:(browser_host_row_cells ~cols) view in
          let empty_line = browser_lane_picker_empty_line view in
          let extension_rows =
            if Option.is_some empty_line && awaiting_browser view then
              [ Theme.info (), "  The MASC extension and its registered native host connect a live browser."
              ; Theme.recede (), "  " ^ transport_setup_row [Browser_lane.Web_extension]
              ; Theme.recede (), "  Enable the extension in your Zen/Firefox profile, then r:refresh." ]
            else [] in
          let choices = browser_choices view in
          let reports_a_host = Browser_lane_view.host_rows_report_a_host view in
          let room =
            Browser_lane_view.picker_choice_rows
              ~rows:(budget - browser_picker_frame_rows - List.length (Option.to_list empty_line))
              ~choices:(List.length choices)
              ~below:(if reports_a_host
                      then List.length host_rows + List.length extension_rows else 0) in
          let start = max 0 (cursor - room + 1) in
          choices |> List.iteri (fun index choice ->
            if index >= start && index < start + room then
              let line = "  " ^ Terminal_text.single_line (browser_choice_label choice)
                ^ (if browser_choice_selected view choice then " (current)" else "") in
              if index = cursor then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          (* One row whatever the choice, so the rows below do not move with
             the cursor. *)
          c.push_styled ~style:(Theme.recede ())
            ("  " ^ Option.value ~default:""
               (Option.bind (List.nth_opt choices cursor) browser_choice_detail));
          Option.iter (c.push_styled ~style:(Theme.recede ())) empty_line;
          (* A terminal too short for everything loses rows from the end.
             With no host yet, the host's rows only say how one is started:
             they take no row from what is above them, and are drawn where
             the screen has rows left. Rows that report a host come before
             the rows on the extension. On a screen that holds all of both
             the host's rows stay together; on a shorter one the host's
             first rows are followed by the extension's, and what is cut
             from the end is the rest of the host's. *)
          let draw_host rows =
            List.iter (fun row -> c.push_styled ~style:(Theme.recede ()) ("  " ^ row)) rows in
          let draw_extension () =
            List.iter (fun (style, row) -> c.push_styled ~style row) extension_rows in
          let above =
            browser_picker_frame_rows + min room (List.length choices)
            + List.length (Option.to_list empty_line) in
          let extension = List.length extension_rows in
          if not reports_a_host then (
            draw_extension ();
            if budget > above + extension then draw_host host_rows)
          else if above + List.length host_rows + extension <= budget then (
            draw_host host_rows;
            draw_extension ())
          else (
            let head, rest = Browser_lane_view.picker_host_head host_rows in
            draw_host head;
            draw_extension ();
            draw_host rest)
      | None ->
      List.iter (fun row -> c.push_styled ~style:(Theme.warn ()) ("  " ^ row))
        (Browser_lane_view.unserved_rows view);
      c.push_styled ~style:(Theme.info ())
        (match view.url_draft with
         | Some draft -> browser_lane_url_line ~cols draft
         | None when Option.is_some view.scene ->
             (match List.nth_opt (scene_targets view) view.scene_cursor with
              | Some node ->
                  let label = match node.kind with
                    | Region _ -> "Region"
                    | Text | Raster | Control _ -> "Element" in
                  Printf.sprintf "  %s %d/%d: %s • n/p:select • y:copy context"
                    label (view.scene_cursor + 1) (List.length (scene_targets view)) (Terminal_text.single_line node.text)
              | None -> "  No observed elements in this viewport • Ctrl-O:image")
         | None -> match view.source with
             | Live -> live_connection_row view
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
    ~hints:"[/]:observation  j/k:scroll  y:copy record  r:reload list  R:recheck workspace  h/Esc:back to browser"
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
            (Printf.sprintf "  [connectors %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
      end)

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

let render_surface (state : state) =
  let _, cols = get_terminal_size () in
  if state.keeper_navigation_open && cols < keeper_split_threshold_cols then
    render_keeper_navigation state
  else
  match state.view with
  | Overview -> render_overview state
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
      if Option.is_some state.memory_facts_keeper then
        render_memory_facts state
      else render_memory state
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
      (match state.system_logs_detail_seq with
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
let frame_choice (state : state) ~terminal_rows =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  if Render_schedule.Viewport.requires_compact_frame ~rows then `Too_small rows
  else match play_card_shown state with
  | Some card -> `Play_card card
  | None -> match state.account_login with
  | Some view -> `Account_login view
  | None when state.palette_open -> `Palette
  | None -> match state.collab with
  | Some view -> `Collab view
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
  | `Collab view -> let frame, clamped = render_collab state view in (frame,clamped,None,Overlay_drawn)
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
