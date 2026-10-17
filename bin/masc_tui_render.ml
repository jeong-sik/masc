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
let schedule_status_color = Masc_tui_render_work.schedule_status_color
let schedule_status_word_cells = Masc_tui_render_work.schedule_status_word_cells
let schedule_requested_clock_cells = Masc_tui_render_work.schedule_requested_clock_cells
let schedule_outcome_word = Masc_tui_render_work.schedule_outcome_word
let schedule_status_is_terminal = Masc_tui_render_work.schedule_status_is_terminal

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
        | Some (Mark.Micro_vm as known), _ ->
          (Theme.category Theme.Slot_2) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Remote_ssh as known), _ ->
          (Theme.category Theme.Slot_1) ^ Mark.sandbox_letter known ^ Ansi.reset
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
    ; Printf.sprintf "%-*s" columns.kcol_name "KEEPER"
    ; " "
    ; Printf.sprintf "%-*s" Render_schedule.keeper_status_width "HEALTH"
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
     not: a healthy keeper says nothing, a failing one says "failing". How
     long the turn has run belongs to TURN (see [Masc_tui_keeper_mark.turn_clock]), on
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
    ; (* A keeper whose gate runs every call unasked wears its name in
         red: the stance has no column of its own, and the name is what
         the eye finds first. On the selected row the band folds this red
         with every other cell colour. *)
      (if yolo then (Theme.bad ()) ^ name ^ Ansi.reset else name)
    ; " "
    ; status_color ^ glyph ^ " "
      ^ fit_width health_word (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
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

(* Composite execution facts belong to this Keeper's Info pane. Separate
   fields use the pane's wrapped, scrollable rows; a long one-line preview
   beside the list footer silently lost its outcome and runtime target. *)
let keeper_operations_fields (state : state) ~keeper_name =
  let fields = match state.lanes with
  | Some snapshot ->
      (match
         List.find_opt
           (fun (lane : Tui_decode.keeper_lane) ->
             String.equal lane.kl_keeper keeper_name)
           snapshot.kls_lanes
       with
       | Some lane ->
           [ "Lifecycle:", keeper_lane_lifecycle_text lane
           ; "Turn:", Terminal_text.single_line
               (Tui_decode.keeper_lane_turn_phase_to_string lane.kl_turn_phase)
           ; "Idle:", keeper_lane_idle_text lane.kl_idle_seconds
           ; "Last outcome:", keeper_operations_outcome_text lane.kl_last_outcome
           ]
       | None ->
           [ "Execution:", Ansi.dim ^ "no composite row for "
             ^ Terminal_text.single_line keeper_name ^ Ansi.reset ])
  | None ->
      (match state.lanes_error with
       | Some detail ->
           [ "Execution:", Theme.warn () ^ "unavailable · "
             ^ Terminal_text.single_line detail ^ Ansi.reset ]
       | None -> [ "Execution:", Ansi.dim ^ "loading…" ^ Ansi.reset ])
  in
  match state.lanes, state.lanes_error with
  | Some _, Some detail ->
      ("Execution:", Theme.warn () ^ "stale · refresh failed: "
        ^ Terminal_text.single_line detail ^ Ansi.reset) :: fields
  | Some _, None | None, _ -> fields

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

  (* One observation time for stale fleet readings and roster turn ages. *)
  let now_unix = Unix.gettimeofday () in
  let heading =
    screen_title
      (Printf.sprintf " MASC Keepers %s"
         (match state.keepers, keeper_rows_page state ~error:keepers_error with
          | _ :: _, _ | [], Page_empty ->
              Printf.sprintf "(%d)" (List.length state.keepers)
          | [], (Page_unread | Page_failed) ->
              title_missing_reading ~error:keepers_error))
  in
  (* The roster is the surface an operator watches to see which keepers are
     up, and it was the one top-level surface whose title never said whether
     the reading was live: "1 healthy · 1 idle" read the same over a dead
     coordinator as over a live one. The badge also carries the workspace
     mismatch, which this screen could not report at all. *)
  let badge = connection_badge state in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading
       - Message_layout.display_width badge)
  in
  box_line buf cols (heading ^ String.make gap ' ' ^ badge);
  box_empty buf cols;

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
        | Some
            { Keeper_control.liveness =
                ( Keeper_control.Unobserved | Keeper_control.Absent
                | Keeper_control.Present _ )
            ; _
            }
        | None -> ())
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

  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = count_frame_lines buf in
  let footer_rows = 2 in
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
          | Workspace_identity_match | Workspace_identity_match_unconfirmed _
          | Workspace_identity_unread ->
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
              ~now:now_unix
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
      (Printf.sprintf "  [keepers %s]"
         (Masc_tui_scroll.window_text ~scroll:scroll_offset ~height:keeper_rows
            keeper_count));

  (* One quiet boundary between the roster and its actions. *)
  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state
       ~status:(keeper_action_status state)
       ~max_cells:cols
       ~hints:(keeper_control_hints ~offers_back:false state selected_reading));

  finish_surface state ~clamped:(Keeper_list_scroll scroll_offset)
    ~surface_key:"keeper-list" ~rows:terminal_rows ~cols buf

type lane_run_tool_counts = Masc_tui_render_lanes.lane_run_tool_counts = {
  completed : int;
  deferred : int;
  failed : int;
  other : int;
}

let runtime_lane_notice_style = Masc_tui_render_lanes.runtime_lane_notice_style
let render_client_detail = Masc_tui_render_lanes.render_client_detail
let render_clients = Masc_tui_render_lanes.render_clients
let render_lanes = Masc_tui_render_lanes.render_lanes

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
    let is_worn item =
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
    (* Equipped implies owned: the state word is exclusive so a worn row
       never reads "owned". The row suffix below carries "equipped", bold
       so worn rows stand out from owned rows. The word stays the
       distinguisher: Sgr.bold is colors-gated, so NO_COLOR drops the
       weight and the words still tell the states apart. *)
    let equipped_word = "  " ^ Ansi.bold ^ "equipped" ^ Ansi.reset in
    let item_account_facts item =
      match account with
      | Some (Item_account.Ready account) ->
          let worn = is_worn item in
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
          Some (price ^ (if worn then "" else if owned then " owned" else ""))
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
      let worn = is_worn item in
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
        (if worn then equipped_word else "")
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
      | (Detail_info, portrait) | (Detail_items, portrait) | (Detail_sandbox, portrait)
      | (Detail_instructions, portrait) | (Detail_secrets, portrait) | (Detail_github, portrait)
      | (Detail_identity, portrait) | (Detail_channels, portrait) | (Detail_automation, portrait)
      | (Detail_runs, portrait) -> portrait
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
             | Some facts ->
               [ "  Selected: " ^ facts ^ (if is_worn item then equipped_word else "") ]
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
      if Message_layout.display_width label <= label_cells
         && Message_layout.display_width (prefix ^ value) <= width then
        [prefix ^ value]
      else
        (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 2)) label
         |> List.map (fun line -> "  " ^ label_style ^ line ^ Ansi.reset))
        @ (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 4)) value
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
        field_rows ~width ~label_cells:18
          ~label_style:Ansi.dim label value
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
         can answer for the current failure. A blocker may carry a signature:
         the machine wire its summary replaced with a human sentence. It is
         drawn dimmed underneath, so the wire a log search keys on stays on
         screen without ever leading the row. *)
      add_section "Current failure";
      let indent = "  " in
      let wrap ?(tone = "") text =
        Message_layout.wrap_words
          ~max_cells:(max 1 (inner - Message_layout.display_width indent))
          (Terminal_text.single_line text)
        |> List.iter (fun line -> add_line (indent ^ tone ^ line ^ Ansi.reset))
      in
      let () =
        match (keeper_reading state k).Keeper_control.liveness with
        | Keeper_control.Present runtime -> (
            match runtime.kr_runtime_blocker_summary with
            | Some summary ->
                wrap ~tone:(Theme.bad ()) summary;
                (match runtime.kr_runtime_blocker_signature with
                | Some signature -> wrap ~tone:Ansi.dim signature
                | None -> ())
            | None -> wrap ~tone:Ansi.dim "none")
        | Keeper_control.Unobserved -> wrap ~tone:Ansi.dim "unread"
        | Keeper_control.Absent -> wrap ~tone:Ansi.dim "absent from live roster"
        | Keeper_control.Invalid detail ->
            wrap ~tone:(Theme.bad ()) ("config error: " ^ detail)
      in
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
               gate_mode_reading_word modes.Tui_decode.glm_workspace)
             state.gate_modes
         in
         match List.assoc_opt k.k_name state.keeper_gate_modes with
         | Some mode ->
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             ^ Terminal_text.single_line (gate_mode_reading_word mode)
             ^ Ansi.reset
         | None ->
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
      List.iter (fun (label, value) -> add_row label value)
        (keeper_operations_fields state ~keeper_name:k.k_name);
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
    Option.iter
      (fun row ->
        box_line buf cols ((Theme.recede ()) ^ row ^ Ansi.reset))
      (Masc_tui_scroll.position_row ~scroll ~height:content_height total_lines);

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
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-detail"
      ~title:
        (Printf.sprintf "%s  %s"
           (screen_title " Keepers \xe2\x96\xb8 detail")
           (connection_badge state))
      ~hints:(Masc_tui_keys.footer_hints state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
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
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-logs"
      ~title:
        (Printf.sprintf "%s  %s"
           (screen_title " Keepers \xe2\x96\xb8 logs")
           (connection_badge state))
      ~hints:(Masc_tui_keys.footer_hints state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header =
      Printf.sprintf "%s  (%s)  %s"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        (Masc_tui_message_layout.count_noun ~plural:"entries" total_entries "entry")
        (connection_badge state)
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
        (Printf.sprintf "  [newest rows %d-%d of %d]" (scroll + 1)
           (min row_count (scroll + content_height)) row_count)
    else box_empty buf cols;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints state.view));

    finish_surface state ~clamped:(Keeper_logs_scroll { scroll; cols })
      ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

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
      let failed_attempt =
        match runtime.ro_failed_attempt with
        | None -> []
        | Some attempt ->
          runtime_detail_field ~width ~style:(Theme.warn ()) "Last failure"
            (Terminal_text.single_line (runtime_failed_attempt_text attempt))
      in
      fields @ candidate @ evidence_lines @ usage_lines @ quota @ rate_limit @ failed_attempt
      @ keeper_lines @ probe_lines @ probe_limitations

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
  let total = List.length lines in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.runtime_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  let position =
    if total > content_height then
      Some
        (Printf.sprintf "lines %s"
           (Masc_tui_scroll.window_text ~scroll ~height:content_height total))
    else None
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ?position
       ~hints:
         (Masc_tui_keys.footer_hints_runtime_detail
            ~routes:(target = Runtime_routes) ()));
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
       (* A short viewport folds the media_failover row and its divider away so
          the table header and the selected row keep a place (#41143's rule for
          the status column, applied to height). *)
       if not (Masc_tui_types.runtime_media_row_folded ~rows ~cols state) then begin
         c.push_styled ~style:(Theme.recede ())
           (Printf.sprintf "  %s %s   %s"
              (runtime_column runtime_lane_width "media_failover")
              (runtime_column runtime_candidate_width media_text)
              (Ansi.dim ^ "m edits it · the vision runtimes, in call order" ^ Ansi.reset));
         c.push_divider ()
       end);
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
             | Masc_tui_types.Runtime_choice _,
               (Masc_tui_types.Pick_route_default | Masc_tui_types.Pick_media_failover
               | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_new_lane _)
             | Masc_tui_types.Lane_choice _,
               (Masc_tui_types.Pick_route_default | Masc_tui_types.Pick_media_failover
               | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_exact_lane _
               | Masc_tui_types.Pick_exact_lane_replacement _ | Masc_tui_types.Pick_new_lane _) ->
                 Masc_tui_types.runtime_picker_label_for picker.rlp_pick choice in
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
                   | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
                   | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ -> "  (already a candidate)")
                 else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                 then "  (same provider as a current candidate)"
                 else ""
               in
               let ctx =
                 Printf.sprintf " [%s %s]"
                   (format_context_tokens runtime.ro_effective_max_context)
                   (match picker.rlp_pick with
                    | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ -> "context"
                    | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
                    | Pick_new_lane _ -> "ctx")
               in
               let def = if runtime.ro_is_default then
                 (match picker.rlp_pick with
                  | Masc_tui_types.Pick_route_default -> " [entry runtime]"
                  | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
                  | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ -> " [default]") else "" in
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
                | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
                | Pick_new_lane _ -> ())) picker.rlp_choices;
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
               else if Masc_tui_types.runtime_row_deemphasized state runtime then
                 c.push_styled ~style:(Theme.recede ()) (Masc_tui_theme.strip_sgr line)
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
          else if Masc_tui_types.runtime_row_deemphasized state runtime then
            c.push_styled ~style:(Theme.recede ()) (Masc_tui_theme.strip_sgr line)
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
      (Printf.sprintf "  [rows %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height drawable));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf


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
        let heading = Message_layout.truncate_middle inner (label row.scope_id) in
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
            ~providers:state.overview_providers ~runtimes:state.overview_quota
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
                      Printf.sprintf "partial (%d malformed rows, %d unread turn rows) · reported totals are lower bounds"
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
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "  [rows %s · j/k to scroll]"
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
            in
            let route_col =
              Message_layout.fit_middle route_width columns.Masc_tui_types.rpc_route
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

let render_keeper_navigation (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  keeper_roster_pane ~focused:true state ~rows:terminal_rows ~cols buf;
  Buffer.add_string buf (footer_line state ~max_cells:cols
    ~hints:Masc_tui_keys.keeper_navigation_hints);
  finish_frame_beside_acting_pane state ~surface_key:"keeper-navigation"
    ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols buf

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
        | ((Masc_tui_context_inspector.Exact_input | Masc_tui_context_inspector.Input_map), false)
        | (Masc_tui_context_inspector.Composition, _) -> "1/2/3 or Tab:switch  [ / ]:turn  /:search  j/k:select  Enter:open exact  r:refresh  Esc:close")
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


let render_collab state view =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"collab" ~title:(screen_title " MASC Collab")
    ~hints:(Masc_tui_collab.hints view)
    ~body:(fun ~budget c ->
      Masc_tui_collab.lines ~height:budget view
      |> List.iter (fun line -> c.push (fit_width
          (Masc.Tui_terminal_text.sanitize_terminal_text line) (framed_inner_width cols))))

let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"lanes"
    ~title:(screen_title " MASC Lane Add-ons")
    ~hints:(if Option.is_some view.evidence_prompt then "j/k:choose  Enter:preserve  Esc:back"
      else if Option.is_some view.subscription_panel then "j/k:select  Enter:choose/save  a:add  d:remove  J/K:scroll  r:refresh  Esc:back"
      else if Option.is_some view.installer then Option.fold ~none:"" ~some:Masc_tui_lane_installer.hints view.installer
      else if Option.exists (fun (menu : Masc_tui_lane_addons.action_menu) -> Option.is_some menu.form) view.action_menu
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
