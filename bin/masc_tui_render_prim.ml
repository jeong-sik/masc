(** Drawing and layout primitives shared by screen renderers.
    This module depends on shared state and presentation components,
    without referring back to a surface renderer. *)

open Masc_tui_types
open Tui_decode
open Masc.Tui_decode_fusion
open Masc_tui_ansi
open Masc_tui_press





(* Every surface lays out against a viewport one row shorter than the
   terminal: the top row belongs to the surface strip, prepended when a frame
   is finished. Shadowing the probe here (and, via open order, in masc_tui.ml)
   keeps all sixteen surfaces' row budgets and the input layer's paging math
   in step without touching each formula. *)
(* The columns the Activity pane holds on the right of the current frame.
   [render] sets it once per frame from the reader's preference and the
   terminal's width, so every surface that reads [get_terminal_size] below
   lays out beside the pane without knowing it is there, and the input
   layer's paging math (which reads the same probe) agrees with the drawn
   frame. Zero when the pane is hidden, too narrow, or the surface is the
   Activity feed itself. *)

module Agenda = Masc_tui_agenda
module Ask_projection = Masc_tui_ask_projection
module Browser_lane_layout = Masc_tui_browser_lane_layout
module Chart = Masc_tui_chart
module Diff = Masc_tui_diff
module Keeper_chat = Masc_tui_keeper_chat_projection
module Magnitude = Masc_tui_magnitude
module Render_schedule = Masc_tui_render_schedule
module Retained_view = Masc_tui_retained_view
module Span = Masc_tui_span
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Frame_presenter = Masc_tui_frame_presenter
module Status = Masc.Keeper_status_runtime
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Keeper_control = Masc_tui_keeper_control

(* One header row, and only for a read that has been running past the display
   bar in [Masc_tui_types.pending_display_bar_ns]. A read inside the bar
   draws nothing: it is expected to settle before a person could read about
   it, and the row appearing and disappearing on every poll is what made the
   Keeper list jump. The stage words live on here because at this age they
   have stopped flickering -- they name where the read is stuck -- and the
   structured tui_local_read log keeps the millisecond choreography. *)
let local_source_pending_note state source =
  match local_source_slow_pending state source with
  | None -> None
  | Some (phase, age_ns) ->
      let step = match phase with
        | Local_read_observation.Awaiting_start -> ui_text state ~ko:"시작 대기" ~en:"starting read"
        | Io_queued -> ui_text state ~ko:"I/O 대기" ~en:"waiting for I/O worker"
        | Io_running -> ui_text state ~ko:"로컬 파일 읽는 중" ~en:"reading local files"
        | Io_returning -> ui_text state ~ko:"I/O 결과 전달 중" ~en:"returning I/O result"
        | Preparing -> ui_text state ~ko:"스냅샷 준비 중" ~en:"preparing snapshot"
        | Comparison_queued -> ui_text state ~ko:"Task 비교 대기" ~en:"waiting for Task comparison worker"
        | Comparison_running -> ui_text state ~ko:"Task 값 비교 중" ~en:"comparing Task values"
        | Comparison_returning -> ui_text state ~ko:"비교 결과 전달 중" ~en:"returning Task comparison"
        | Awaiting_ui -> ui_text state ~ko:"상태 적용 대기" ~en:"result awaiting state application"
        | Local_read_observation.Read_failed Raised -> ui_text state ~ko:"읽기 실패" ~en:"read failed"
        | Local_read_observation.Read_failed Interrupted -> ui_text state ~ko:"읽기 중단됨" ~en:"read interrupted"
        | Read_not_started -> ui_text state ~ko:"읽기 시작 전" ~en:"read not started" in
      let name = match source with
        | Local_keepers -> ui_text state ~ko:"Keeper 메타데이터" ~en:"Keeper metadata"
        | Local_work -> ui_text state ~ko:"작업 목록" ~en:"Work" in
      let seconds = Printf.sprintf "%.1f" (Int64.to_float age_ns /. 1e9) ^ ui_text state ~ko:"초" ~en:"s" in
      let lead = match phase with
        | Local_read_observation.Read_failed _ | Read_not_started -> name
        | Awaiting_start | Io_queued | Io_running | Io_returning | Preparing
        | Comparison_queued | Comparison_running | Comparison_returning | Awaiting_ui ->
            ui_text state ~ko:(name ^ " 읽는 중") ~en:(name ^ " reading") in
      Some (Theme.recede () ^ "  " ^ String.concat " · " [lead; step; seconds] ^ Ansi.reset)
module Markdown = Masc_tui_markdown
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows

let runtime_assignment_label (assignment : runtime_assignment) =
  let source =
    match assignment.ra_source with
    | Default_runtime -> "default"
    | Explicit_runtime -> "explicit"
  in
  match assignment.ra_resolution with
  | Runtime_assignment_lane lane_id ->
    Printf.sprintf "%s (lane, %s)" (Terminal_text.single_line lane_id) source
  | Runtime_assignment_missing -> Printf.sprintf "- (missing, %s)" source
  | Runtime_assignment_unavailable
      { runtime_id; reason = Missing_catalog_model { provider_label; model_id } } ->
    Printf.sprintf
      "%s (not in catalog: %s / %s, %s)"
      (Terminal_text.single_line runtime_id)
      (Terminal_text.single_line provider_label)
      (Terminal_text.single_line model_id)
      source
;;

let acting_pane_reserved_cols = ref 0


(* A synchronous draw constructs one candidate. Only the main loop can
   publish it after the terminal accepts its frame. *)
let frame_acting_pane = ref Masc_tui_acting_pane.empty_frame
let frame_tools_task : tools_task_frame option ref = ref None

(* Context insertion changes the screen row for every Activity target below
   it. Keep focus inside the pane on its stable header when that happens. *)
let acting_pane_context_rows = ref 0

(* Where each pane of the frame being drawn sits on the terminal. The surface
   ends set it, the render hands it out beside the frame, and the loop reads
   a drag against the copy the terminal accepted, never this one. *)
let frame_panes = ref Masc_tui_pane_selection.no_panes



(* The value [Masc_tui_types.apply_clamped_scroll] writes, read back from
   [state]; the two are the same table read in opposite directions. A frame
   says which scroll is on screen; a notch moves that scroll from where it is
   now, because keys and notches that arrive between two frames each move it
   and the frame's own reading is behind all of them. *)
let clamped_scroll_now (state : state) = function
  | Task_detail (_, viewport) -> Task_detail (state.task_detail_scroll, viewport)
  | Board_read _ ->
      Board_read (state.board_scroll, state.board_comment_scroll)
  | Message_scroll _ -> Message_scroll {scroll=state.msg_scroll; pin=state.msg_scroll_pin}
  | Schedule_detail_scroll _ -> Schedule_detail_scroll state.schedule_scroll
  | Keeper_detail _ -> Keeper_detail state.detail_scroll
  | Keeper_terminal_scroll _ ->
      Keeper_terminal_scroll
        (Masc_tui_execute_terminal.back (Masc_tui_types.keeper_terminal_hold state))
  | Keeper_calls _ -> Keeper_calls state.keeper_calls_scroll
  | Keeper_logs_scroll { cols; _ } ->
      Keeper_logs_scroll { scroll = state.log_scroll; cols }
  | Acting _ -> Acting state.acting_scroll
  | Acting_selection _ ->
      Acting_selection (state.acting_scroll, state.acting_cursor)
  | Acting_detail_scroll _ -> Acting_detail_scroll state.acting_detail_scroll
  | Memory_fact_detail_scroll _ ->
      Memory_fact_detail_scroll state.memory_fact_detail_scroll
  | Client_detail_scroll _ -> Client_detail_scroll state.client_detail_scroll
  | Verification_detail_scroll _ ->
      Verification_detail_scroll state.verification_detail_scroll
  | Harness_detail_scroll _ -> Harness_detail_scroll state.harness_detail_scroll
  | Fusion_detail_scroll _ -> Fusion_detail_scroll state.fusion_scroll
  | Runtime_detail_scroll _ -> Runtime_detail_scroll state.runtime_detail_scroll
  | Runtime_params_scroll _ ->
      Runtime_params_scroll
        { scroll = state.config_scroll;
          max_scroll = state.config_document_max_scroll }
  | System_log_detail_scroll _ ->
      System_log_detail_scroll (system_logs_page state).lp_detail_scroll
  | Planning_detail_scroll _ | Planning_confirmation_scroll _ ->
      Planning_detail_scroll (planning_scroll_value state.planning_scroll)
  | Planning_list_page_rows _ -> Planning_list_page_rows state.planning_list_page_rows
  | Lane_run_detail_scroll _ ->
      Lane_run_detail_scroll
        { scroll = state.lane_run_detail_scroll;
          content_height = state.lane_run_detail_content_height }
  | Changes_diff_scroll _ -> Changes_diff_scroll state.changes_diff_scroll
  | Repository_changes_diff_scroll _ ->
      Repository_changes_diff_scroll state.repository_changes_diff_scroll
  | Resource_scroll _ -> Resource_scroll state.resource_scroll
  | Metrics_scroll _ ->
      Metrics_scroll { scroll = state.metrics_scroll;
                       content_height = state.metrics_content_height;
                       card_rows = state.metrics_scroll_card_rows }
  | Approval_detail_scroll (_, viewport) ->
      Approval_detail_scroll (state.approval_detail_scroll, viewport)
  | Patch_modal_scroll _ -> Patch_modal_scroll (state.patch_modal_scroll, state.patch_modal_hscroll)
  | Link_modal_scroll _ -> Link_modal_scroll state.link_modal_scroll
  | Play_invite_scroll (card, _) -> Play_invite_scroll (card, state.play_invite_scroll)
  | Queue_panel_presented owner -> Queue_panel_presented owner
  | Help_presented -> Help_presented
  | Voice_scroll _ -> Voice_scroll state.config_scroll
  | Preset_detail_scroll { confirmation; _ } ->
      Preset_detail_scroll
        { scroll = state.config_scroll;
          max_scroll = state.config_document_max_scroll;
          confirmation }
  | Keeper_list_scroll _ -> Keeper_list_scroll state.keeper_list_scroll
  | Context_inspector_scroll _ ->
      Context_inspector_scroll state.context_inspector_scroll
  | Context_inspector_response_scroll _ ->
      Context_inspector_response_scroll state.context_inspector_response_scroll

(* Where one wheel notch leaves a reader: as far as [j] or [k] moves it, one
   row. The wheel used to arrive as a key that only list arms knew, so over an
   open fact or event reading it moved the list hidden behind it instead.

   [reader] is the reader's position now ([clamped_scroll_now]), not as a
   frame drew it: notches and keys that arrive between two frames each move
   it. [None] for the scrolls the wheel reaches another way, and for a reader
   with no row left to move to that way. Listed one by one
   so a new reader is a compile error here, not a notch that quietly moves a
   list. *)
let reader_after_wheel (reader : clamped_scroll)
    (direction : Masc.Tui_mouse_protocol.wheel_direction) : clamped_scroll option =
  let step value =
    match direction with
    | Masc.Tui_mouse_protocol.Wheel_down -> Masc_tui_types.scroll_down_from value ~by:1
    | Masc.Tui_mouse_protocol.Wheel_up -> max 0 (value - 1)
  in
  (* The row a document under a list moves to, or [None] when it has no row
     to move to that way. *)
  let within ~scroll ~max_scroll =
    let from = min scroll max_scroll in
    let moved =
      match direction with
      | Masc.Tui_mouse_protocol.Wheel_down -> min max_scroll (from + 1)
      | Masc.Tui_mouse_protocol.Wheel_up -> max 0 (from - 1)
    in
    if moved = from then None else Some moved
  in
  match reader with
  | Task_detail (value, viewport) -> Some (Task_detail (step value, viewport))
  | Schedule_detail_scroll value -> Some (Schedule_detail_scroll (step value))
  | Acting_detail_scroll value -> Some (Acting_detail_scroll (step value))
  | Memory_fact_detail_scroll value -> Some (Memory_fact_detail_scroll (step value))
  | Client_detail_scroll value -> Some (Client_detail_scroll (step value))
  | Verification_detail_scroll value ->
      Some (Verification_detail_scroll (step value))
  | Harness_detail_scroll value -> Some (Harness_detail_scroll (step value))
  | Fusion_detail_scroll value -> Some (Fusion_detail_scroll (step value))
  | Runtime_detail_scroll value -> Some (Runtime_detail_scroll (step value))
  (* The list is on screen beside the document. The document takes the notch
     while it can move that way; at its ends, and when it fits whole, the
     notch reaches the list as the key. *)
  | Runtime_params_scroll { scroll; max_scroll } ->
      Option.map
        (fun moved -> Runtime_params_scroll { scroll = moved; max_scroll })
        (within ~scroll ~max_scroll)
  | System_log_detail_scroll value -> Some (System_log_detail_scroll (step value))
  | Planning_detail_scroll value | Planning_confirmation_scroll (value, _) ->
      Some (Planning_detail_scroll (step value))
  | Lane_run_detail_scroll { scroll; content_height } ->
      Some (Lane_run_detail_scroll { scroll = step scroll; content_height })
  | Changes_diff_scroll value -> Some (Changes_diff_scroll (step value))
  | Repository_changes_diff_scroll value ->
      Some (Repository_changes_diff_scroll (step value))
  | Metrics_scroll { scroll; content_height; card_rows } ->
      Some (Metrics_scroll { scroll = step scroll; content_height; card_rows })
  | Approval_detail_scroll (value, Some viewport) ->
      let move = match direction with
        | Masc.Tui_mouse_protocol.Wheel_down -> Masc_tui_scroll.down
        | Masc.Tui_mouse_protocol.Wheel_up -> Masc_tui_scroll.up in
      Some (Approval_detail_scroll
        (move ~count:viewport.adv_count ~height:viewport.adv_height value, Some viewport))
  | Approval_detail_scroll (value, None) ->
      Some (Approval_detail_scroll (step value, None))
  | Patch_modal_scroll (vertical, horizontal) ->
      Some (Patch_modal_scroll (step vertical, horizontal))
  | Link_modal_scroll value -> Some (Link_modal_scroll (step value))
  | Play_invite_scroll (card, value) -> Some (Play_invite_scroll (card, step value))
  | Queue_panel_presented _ | Help_presented -> None
  | Voice_scroll value -> Some (Voice_scroll (step value))
  (* Presets draws its list beside the document the same way. While a save
     warning is the document, a notch always reads it: any other key ends the
     armed save, so a notch past the end must not reach the loop as one. *)
  | Preset_detail_scroll { scroll; max_scroll; confirmation = (Some _ as confirmation) } ->
      Some (Preset_detail_scroll { scroll = step scroll; max_scroll; confirmation })
  | Preset_detail_scroll { scroll; max_scroll; confirmation = None } ->
      Option.map
        (fun moved ->
          Preset_detail_scroll { scroll = moved; max_scroll; confirmation = None })
        (within ~scroll ~max_scroll)
  | Context_inspector_scroll value ->
      Some (Context_inspector_scroll (step value))
  | Context_inspector_response_scroll value ->
      Some (Context_inspector_response_scroll (step value))
  (* The chat reads its own wheel, three rows a notch, and its scroll counts
     rows up from the newest message rather than down from the top. *)
  | Message_scroll _ -> None
  (* The Board read draws its comments beside the post with a scroll of their
     own, which the notch cannot yet tell apart from the post's. *)
  | Board_read _ -> None
  (* Some Keeper detail tabs and the calls view move a row cursor on [j]; the
     notch keeps reaching them as that key. The Terminal tab counts its scroll
     back from the newest output, and [j] and [k] already move that. *)
  | Keeper_detail _ | Keeper_terminal_scroll _ | Keeper_calls _ -> None
  (* Logs use their own bounded Metrics_tail movement through the key path. *)
  | Keeper_logs_scroll _ -> None
  (* List scrolls: the notch moves the list's cursor as the arrow does. *)
  | Acting _ | Acting_selection _ | Keeper_list_scroll _ | Planning_list_page_rows _ -> None
  (* Resources has panes of its own that [h] and [l] move between. *)
  | Resource_scroll _ -> None


let navigation_rows = 1


let get_terminal_size () =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  (max 1 (rows - navigation_rows), max 1 (cols - !acting_pane_reserved_cols))


(* The lines a buffer has ended since [start]: how far down a frame the next
   row lands, counted from what was drawn rather than by hand, for a picture
   placed over the rows drawn after it. *)
let lines_ended_since buf ~start =
  let ended = ref 0 in
  for index = start to Buffer.length buf - 1 do
    if Buffer.nth buf index = '\n' then incr ended
  done;
  !ended

let frame_lines buf =
  let str = Buffer.contents buf in
  let len = String.length str in
  if len = 0 then []
  else
    let limit = if str.[len - 1] = '\n' then len - 1 else len in
    let rows = ref [] in
    let stop = ref limit in
    for index = limit - 1 downto 0 do
      if str.[index] = '\n' then begin
        rows := String.sub str (index + 1) (!stop - index - 1) :: !rows;
        stop := index
      end
    done;
    String.sub str 0 !stop :: !rows


(* Two already-drawn panes, side by side, one terminal row per line.

   The left pane's own width pads the rows it ran out of. Without that a
   short list lets the right pane's remaining lines slide to column zero,
   which reads as the detail having changed panes. Five surfaces had copied
   this loop; a sixth copy is how the padding rule drifts. *)
let write_two_panes buf ~left_cols ~left ~right =
  let left_lines = frame_lines left in
  let right_lines = frame_lines right in
  let blank_left = ref None in
  let get_blank_left () =
    match !blank_left with
    | Some s -> s
    | None ->
        let s = String.make left_cols ' ' in
        blank_left := Some s;
        s
  in
  let rec loop l_list r_list =
    match l_list, r_list with
    | [], [] -> ()
    | l :: lt, r :: rt ->
        Buffer.add_string buf l;
        Buffer.add_string buf r;
        Buffer.add_char buf '\n';
        loop lt rt
    | [], r :: rt ->
        Buffer.add_string buf (get_blank_left ());
        Buffer.add_string buf r;
        Buffer.add_char buf '\n';
        loop [] rt
    | l :: lt, [] ->
        Buffer.add_string buf l;
        Buffer.add_char buf '\n';
        loop lt []
  in
  loop left_lines right_lines

;;

(* A frame, and what it had to clamp to build itself. The clamp travels beside
   the frame rather than being written into the state mid-draw; see
   [clamped_scroll]. Surfaces that clamp nothing pass nothing. *)
let finish_frame ?clamped ?(compact_frame = false) ~surface_key ~cursor ~rows
    ~cols buf :
    Frame_presenter.frame * clamped_scroll option =
  ( { surface_key;
      compact_frame;
      terminal_rows = rows;
      terminal_cols = cols;
      cursor;
      lines = frame_lines buf;
    }
  , clamped )

;;

(* The one frame drawn without the strip and the Activity pane: a terminal too
   small for any surface holds the notice alone. Surfaces end through
   [finish_surface] or [finish_frame_beside_acting_pane], so a surface cannot
   reserve the pane's columns and then skip drawing it. *)
let finish_terminal_too_small_frame ~cursor ~rows ~cols buf =
  finish_frame ~compact_frame:true ~surface_key:"terminal-too-small" ~cursor
    ~rows ~cols buf

(* Chat and Resources search share the exact terminal document authority. *)
let table_frame_enabled = Masc_tui_markdown_theme.table_frame_enabled
let chat_markdown_palette = Masc_tui_markdown_theme.palette
let markdown_with_closing = Masc_tui_markdown_theme.render
let document_markdown = Masc_tui_markdown_theme.document

(* [text] must be canonical Yojson output, or a prefix starting at byte zero.
   Leave out the gutter so it cannot clip a wide grapheme at the frame edge. *)
let document_json ~width text =
  let palette =
    { (Masc_tui_markdown_theme.palette ~closing:Ansi.reset) with code_gutter = "" } in
  text
  |> Masc.Tui_terminal_json.sanitize_canonical_preview
  |> Masc_tui_markdown_theme.fenced ~language:"json"
  |> Masc_tui_markdown.render ~palette ~width

(* A level meter, only while a capture is running.

   A dead input device and a quiet room both end the same way — an empty draft
   — and nothing else distinguishes them. The bar spans -60 dB to 0, which puts
   an ordinary room near a third and speech visibly above it.

   Part of the prompt rather than drawn beside it, so the cursor column, which
   is computed from the prompt's width, does not have to know about it. *)
let voice_meter_text (state : state) =
  match state.voice_capture, state.voice_capture_phase, state.voice_level_db with
  (* The old capture still occupies the slot until its terminal reply; a
     retargeted draft must not advertise that it is recording new speech. *)
  | Some _, _, _ when state.voice_capture_withdrawn -> "[이전 음성 종료 대기] "
  (* Continuous mode between utterances: no capture is running, but the row is
     still listening and the operator needs to know before speaking. *)
  | None, _, _ when state.voice_continuous <> None -> "[대기] "
  | None, _, _ -> ""
  | Some _, Voice_calibrating, _ -> "[마이크 보정 중] "
  | Some _, Voice_starting, _ -> "[음성 시작 중] "
  | Some _, Voice_stopping, _ -> "[음성 종료 대기] "
  | Some _, Voice_processing, _ -> "[음성 처리 중] "
  | Some _, Voice_recording, None -> "[입력 관측 대기] "
  | Some _, Voice_recording, Some db ->
    let width = 12 in
    let filled =
      if db = Float.neg_infinity
      then 0
      else max 0 (min width (int_of_float ((db +. 60.) /. 5.)))
    in
    Printf.sprintf
      "[%s%s] "
      (String.concat "" (List.init filled (fun _ -> "\xe2\x96\x88")))
      (String.concat "" (List.init (width - filled) (fun _ -> "\xc2\xb7")))

;;

(* The fewest cells between what the composer row says and the key at its
   right end. *)
let composer_hint_gap_cells = 2

let composer_prompt_text ?(voice = "") ~ko composer =
  Printf.sprintf " %s %s%s " "\xe2\x80\xba" voice (Composer.prompt ~ko composer)


(* Unfocused the row is dim and says which key opens it; focused it is drawn in
   full and carries the cursor. Either way it occupies the same single row, so
   taking focus does not move the frame above it. *)
(* The one line that tells an operator on any surface that a keeper is holding
   a tool call. Returns None when nothing is held, which is the common case. *)
let awaiting_approval_notice (state : state) =
  match state.msg_live with
  | None -> None
  | Some live -> (
      match Keeper_chat_transcript.awaiting_approval live.tl_transcript with
      | None -> None
      | Some awaiting ->
          let where =
            match state.view with
            | Keepers Keeper_message -> ""
            | Overview | Acting | Metrics
            | Keepers
                ( Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls
                | Keeper_runtime_pick )
            | Lanes | Clients | Board
            | Approvals | Planning
            | Memory | Schedules | Verification | Harness | Fusion
            | Repositories | Code | Changes | Connectors | Runtime | Config
            | Resources | Tools | System_logs ->
                (* The keys are read from the key table: this line went on
                   saying [2 then m] after Keepers moved to [3] and the chat
                   to [c]. *)
                let screen = Masc_tui_keys.keepers_jump.Masc_tui_keys.key
                and chat = Masc_tui_keys.keeper_chat_key in
                ui_text state
                  ~ko:(Printf.sprintf "  (%s 다음 %s 에서 답하기)" screen chat)
                  ~en:(Printf.sprintf "  (%s then %s to answer)" screen chat)
          in
          let keeper =
            Terminal_text.single_line (Masc_tui_types.turn_log_keeper_name live)
          and tool =
            Terminal_text.single_line awaiting.Keeper_chat_transcript.tool_name
          in
          Some
            (ui_text state
               ~ko:(Printf.sprintf "  %s · %s 호출이 답을 기다림%s" keeper tool where)
               ~en:(Printf.sprintf "  %s is holding %s%s" keeper tool where)))

;;

(* Where key hints live: the footer, and only the footer. A surface's body
   may say *state* — an armed two-step ("same key again to send"), what the
   composer's Enter will do — but never list available keys; a key listed in
   two places drifts in one of them, and a reader who has to scan the body
   for keys on one screen and the footer on another reports exactly
   "the key help keeps moving around" (2026-08-28). *)
(* The query on screen and how many rows it reaches, or [None] when no query
   is on screen.

   Both states, not only the armed one. Enter used to take the query off the
   footer while n and N went on stepping through its matches, so the keys
   that hunt said nothing about what they were hunting for. The caret marks
   the one still being typed; "n/N" marks the one those keys now step.

   The count is what tells a query that matches nothing from a query whose
   only match is already under the cursor -- both move no cursor and, without
   a number, look the same.

   The count follows the current row source. Code reuses a count only while
   its immutable fetched rows and query are unchanged, so background repaints
   do not flatten and scan the entire open file. List/detail transitions on
   other surfaces continue to consult their live row projection.

   "n/N" appears only where those keys do something. They ask
   [Masc_tui_surface_search.surface_row_texts] the same question and return without moving when it
   answers [None], so a detail pane or a cursorless surface that printed the
   suffix would be naming keys that are not there. It is also a key hint, so
   hints off drops it and keeps the query and its count.

   A settled query is drawn only where those keys have rows. On Schedules,
   Overview or a detail pane "/" does not open and n/N do not move, so the
   query would name a hunt that cannot happen there; Enter on Board used to
   leave "/board" in the footer of every screen after it. [state.search_last]
   keeps it and the surface with the list draws it again. A query still being
   typed always shows, with its caret.

   One spelling, because three surfaces draw this: the footer every surface
   carries, the Keepers heading, and the context inspector's own title. They
   said three different things about the same pair of fields. *)
let search_marker (state : state) =
  let rows_reached query =
    Masc_tui_surface_search.surface_search_count ~cols:(snd (get_terminal_size ())) state state.view ~query
  in
  let marker query ~reached ~settled =
    let has_query = surface_search_query state.view query <> "" in
    let found =
      match reached with
      | None -> ""
      | Some _ when not has_query -> ""
      | Some reached ->
          if reached = 0 then " (none)" else Printf.sprintf " (%d)" reached
    in
    let tail =
      if not settled then "\xe2\x96\x8c"
      else if not state.hints_visible || not has_query then
        (* "n/N" names keys, and hints off is the reader saying they know the
           keys -- the setting leaves "?:help" as the only one and takes the
           room back for status. The query and its count are status, so they
           stay; naming two more keys next to them contradicted both halves of
           that setting. *)
        ""
      else " n/N"
    in
    Printf.sprintf "/%s%s%s" (Terminal_text.single_line query) found tail
  in
  match state.search with
  | Some query -> Some (marker query ~reached:(rows_reached query) ~settled:false)
  | None ->
      if state.search_last = "" then None
      else
        (match rows_reached state.search_last with
         | None -> None
         | Some _ as reached -> Some (marker state.search_last ~reached ~settled:true))

(* The marker with the colour the two headings give it: accented while the
   query is being typed, dim once it is settled. Empty when there is no
   query. The footer takes the plain one because it dims its whole line. *)
let search_marker_styled (state : state) =
  match search_marker state with
  | None -> ""
  | Some marker ->
      Printf.sprintf "  %s%s%s"
        (match state.search with
         | Some _ -> Theme.accent ()
         | None -> Ansi.dim)
        marker Ansi.reset

let keeper_action_status (state : state) : Masc_tui_footer.status_item list =
  let ko = state.ui_language = Lang_ko in
  match (state.keeper_action_inflight, state.keeper_action_pending) with
  | Some (keeper_name, action), _ ->
    [ Masc_tui_footer.Keeper_action_running
        { gerund = Keeper_control.action_gerund ~ko action
        ; keeper = Terminal_text.single_line keeper_name
        }
    ]
  | None, Some pending ->
    [ Masc_tui_footer.Keeper_action_armed
        { key = Keeper_control.action_key pending.Keeper_control.pending_action
        ; action =
            Keeper_control.action_label ~ko pending.Keeper_control.pending_action
        ; keeper =
            Terminal_text.single_line pending.Keeper_control.pending_keeper
        }
    ]
  | None, None -> []


let task_creation_status (state : state) =
  List.rev state.task_dispatch_requests |> List.filter_map (fun request ->
    if request.tdr_authority <> state.workspace_authority then None else
    let intent = Masc_tui_task_dispatch.intent request.tdr_dispatch in
    let phase = match Masc_tui_task_dispatch.progress request.tdr_dispatch with
      | Not_started -> Masc_tui_footer.Task_not_started
      | Reserved -> Task_reserved
      | Preparing -> Task_preparing | Sending -> Task_awaiting_reply
      | Completed _ -> Task_awaiting_application in
    Some (Masc_tui_footer.Task_creation {keeper=Terminal_text.single_line intent.keeper;phase}))


type recovery_row = {
  recovery_text : string;
  recovery_quit : Masc_tui_action_notice.quit_confirmation option;
}

let recovery_slot (state : state) ~max_cells =
  let module Notice = Masc_tui_action_notice in
  let now = Unix.gettimeofday () in
  let window = Masc_tui_types.last_action_window_s in
  let fits text = Message_layout.display_width text <= max 0 max_cells in
  let rejection_fits =
    Option.exists (fun notice -> fits (Notice.rejection_text notice))
      (Notice.rejection state.last_action ~now ~window) in
  let quit = current_quit_confirmation state ~now in
  let recovery = Notice.recovery_slot state.last_action ~now ~window
      ~csi_fits:(fits Notice.csi_recovery_text) ~rejection_fits in
  match recovery, quit with
  | (Csi_recovery | No_preferred), (Some _ | None)
    when Notice.csi_active state.last_action ->
      (match recovery with
       | Csi_recovery -> Some { recovery_text = Notice.csi_recovery_text; recovery_quit = None }
       | No_preferred -> None
       | Rejection _ -> None)
  | No_preferred, Some confirmation
    when fits (fst (Notice.quit_ordinary confirmation)) ->
      let text = fst (Notice.quit_ordinary confirmation) in
      Some { recovery_text = pressable (Press_quit_confirmation confirmation) text;
             recovery_quit = Some confirmation }
  | (No_preferred | Rejection _ | Csi_recovery), (Some _ | None) ->
      (match recovery with
       | No_preferred -> None
       | Csi_recovery -> Some { recovery_text = Notice.csi_recovery_text; recovery_quit = None }
       | Rejection notice ->
           Some { recovery_text = pressable (Press_input_rejection notice) (Notice.rejection_text notice);
                  recovery_quit = None })

let draw_box_bottom_with_recovery buf ~cols = function
  | None -> box_bottom buf cols
  | Some row -> box_line_styled buf cols ~style:(Theme.warn ()) row.recovery_text

let recovery_box_bottom state buf ~cols =
  let selected = recovery_slot state ~max_cells:(framed_inner_width cols) in
  draw_box_bottom_with_recovery buf ~cols selected;
  selected

let footer_line ?help_door ?(status = []) ?position ?(recovery_in_slot = None) ?choices
    (state : state) ~max_cells ~hints =
  (* Hints off trades the key text for status room. "?:help" stays only
     when the current input owner lets that key open the help sheet. *)
  (* The same seam names the sheet while the keys are visible, and asks the
     one named question for where [?] answers -- the rule and its reasons
     live with [Masc_tui_types.help_key_answers], beside the predicates it
     is made of. *)
  let door_answers = Option.value help_door
      ~default:(help_key_answers ~compact_viewport:false state) in
  let help_hint = Masc_tui_footer.help_hint ~ko:(state.ui_language = Lang_ko) in
  let hints =
    if not state.hints_visible then
      if door_answers then help_hint else ""
    else if door_answers then
      (* Inspect the key, as the shared fitter does, rather than its label. *)
      if List.exists (fun item ->
           match Masc_tui_footer.item_key item with
           | Some key -> List.mem "?" (Masc_tui_footer.key_atoms key)
           | None -> false) (Masc_tui_footer.split_on_double_space hints)
      then hints else hints ^ "  " ^ help_hint
    else hints
  in
  (* The keys this frame announces, for the navigation trace (RFC-0485). *)
  Masc_tui_nav_trace_log.announce
    (match choices with None -> hints | Some text -> text ^ "  " ^ hints);
  (* Search status is literal text, not key hints: runs of spaces belong
     to the user's query and must survive compact hint-item fitting. *)
  let literal_prefix = search_marker state in
  (* What the last keypress did, in front of the keys for the same reason the
     search query is: the status tail is dropped whole before a single hint
     is, so a fact placed there cannot be read on a surface whose own keys
     already fill the row -- which is every surface at eighty columns. The
     outcomes of the editor-backed actions used to go only to the event log,
     which Overview alone draws, so an operator who pressed [a] on Workspace
     could not tell a registration from an editor that never started.

     Expired here rather than cleared by the setter: the setter is a key
     handler that has already returned, and nothing runs on a timer to come
     back for it. *)
  (* The footer keeps action text separate from hints and search status so
     a long outcome cannot drop a confirmation or identity warning. *)
  (* Acquisition belongs to the pending read, never to conversation history.
     Completion clears it; a cancelled generation or withdrawn source stops
     displaying it even before that worker's late result reaches the UI. *)
  let image_progress =
    match state.sent_image_read with
    | Some pending
      when pending.sir_generation = state.image_request_generation
           && pending.sir_view = state.view
           && Masc_tui_types.image_request_keeper_is_current state pending
           && Masc_tui_types.image_reading_is_current state pending
           && not state.msx_open ->
        Some (Terminal_text.single_line
          (Printf.sprintf (if state.ui_language = Lang_ko
             then "이미지 조회 중 (아무 키로 취소): %s"
             else "Loading image (any key cancels): %s") pending.sir_name))
    | Some _ | None -> None
  in
  let current_quit = current_quit_confirmation state ~now:(Unix.gettimeofday ()) in
  let quit_in_slot = Option.bind recovery_in_slot (fun row -> row.recovery_quit) in
  let action_text, quit_action =
    match Masc_tui_types.runtime_form_save_notice state with
    | Some notice -> Some (Terminal_text.single_line notice), None
    | None -> (match Masc_tui_types.runtime_assignment_notice state with
    | Some notice -> Some (Terminal_text.single_line notice), None
    | None -> (match Masc_tui_types.keeper_settings_editor_notice state with
    | Some notice -> Some (Terminal_text.single_line notice), None
    | None -> (match Masc_tui_types.keeper_settings_save_notice state with
    | Some notice -> Some (Terminal_text.single_line notice), None
    | None -> (match image_progress with
    | Some _ -> image_progress, None
    | None -> (match Masc_tui_action_notice.ordinary_visible state.last_action
        ~now:(Unix.gettimeofday ()) ~window:Masc_tui_types.last_action_window_s with
    | Some _ when Option.is_some recovery_in_slot
                  && Masc_tui_action_notice.ordinary_is_csi state.last_action -> None, None
    | Some ((text, _) as ordinary)
      when (not
                 (String.starts_with
                    ~prefix:Masc_tui_types.armed_ask_submit_notice_prefix text)
               || Masc_tui_types.ask_submit_is_armed state) ->
      (match state.quit_armed with
       | Some arm when ordinary == Masc_tui_action_notice.quit_ordinary arm.qa_confirmation ->
           (match current_quit with
            | Some confirmation ->
                if Option.exists (Masc_tui_action_notice.same_quit confirmation) quit_in_slot
                then None, None
                else Some (ui_text state ~ko:"창을 넓혀 종료 확인" ~en:"Resize to confirm quit"), Some confirmation
            | None when Masc_tui_action_notice.csi_active state.last_action
                        || Option.is_some (Masc_tui_action_notice.rejection state.last_action
                             ~now:(Unix.gettimeofday ()) ~window:last_action_window_s) ->
                None, None
            | None -> Some (ui_text state ~ko:"종료 조건 변경; 다시 시도" ~en:"Quit changed; retry"), None)
       | Some _ | None -> Some text, None)
    | Some _ | None -> None, None)))))
  in
  let preferred_action =
    match quit_action with
    | Some confirmation ->
        Some (Masc_tui_footer.Pending_question
                (fst (Masc_tui_action_notice.quit_ordinary confirmation),
                 pressable (Press_quit_confirmation confirmation)))
    | None when Option.is_some recovery_in_slot -> None
    | None -> (match Masc_tui_action_notice.preferred state.last_action
            ~existing_action:(Option.is_some action_text)
            ~now:(Unix.gettimeofday ()) ~window:Masc_tui_types.last_action_window_s with
    | No_preferred ->
        Option.map (fun text -> Masc_tui_footer.Menu_choices text) choices
    | Csi_recovery ->
        Some (Masc_tui_footer.Outcome (Masc_tui_action_notice.csi_recovery_text, Fun.id))
    | Rejection notice ->
        Some (Masc_tui_footer.Outcome (Masc_tui_action_notice.rejection_text notice,
              pressable (Press_input_rejection notice)))) in
  let identity =
    match state.server_identity with
    | None -> []
    | Some identity ->
        (* Only a definite yes warns: an older server that cannot say
           (None) must not read as either lane. *)
        (match identity.Tui_decode.sid_executable_in_worktree with
         | Some true -> [ Masc_tui_footer.Server_worktree_binary ]
         | Some false | None -> [])
        @
        (* The server's rollup, from the probe it serves on every refresh. *)
        (match Masc_tui_types.operator_actions state with
         | Some (_ :: rest) ->
           let count = 1 + List.length rest in
           let notice =
             ui_text state
               ~ko:(Printf.sprintf "조치 필요 %d" count)
               ~en:(Printf.sprintf "Action needed %d" count)
             |> pressable (Press_surface Overview)
           in
           [ Masc_tui_footer.Operator_action
               { notice
               ; detail = ui_text state ~ko:"운영에서 확인" ~en:"Open Operations"
               } ]
         | Some [] -> []
         | None ->
             [ Masc_tui_footer.Operator_action
                 { notice = pressable (Press_surface Overview)
                     (ui_text state ~ko:"조치 원인 미관측" ~en:"Action reasons unobserved")
                 ; detail = ui_text state ~ko:"운영에서 확인" ~en:"Open Operations" } ])
        @
        (* This TUI's own embedded commit against the server's: the pair
           that told "restart masc" apart from "the feature is not merged"
           by hand every time. Silent when either side cannot testify. *)
        (match
           Masc_tui_footer.build_mismatch_item
             ~tui_commit:Masc.Build_identity.embedded_commit
             ~tui_age_s:
               (Option.map float_of_int
                  (Masc.Build_identity.embedded_commit_age_seconds
                     ~now:(Unix.gettimeofday ())))
             ~server_commit:identity.Tui_decode.sid_binary_commit
             ~server_age_s:identity.Tui_decode.sid_binary_commit_age_s
         with
         | Some item -> [ item ]
         | None -> [])
  in
  (* A workspace disagreement rides the footer every surface already draws,
     rather than replacing the screen. The reads that would be wrong under a
     mismatch are refused where they happen -- [begin_local_workspace_read],
     [live_context_keeper], [begin_keeper_log_read],
     [handle_composer_key], [handle_paste] -- and [clear_local_workspace]
     empties what a previous match had loaded. Drawing nothing but the notice
     took away Overview, Keepers, Board and Changes as well, and those read the
     server's answer, not this filesystem. *)
  let conflict =
    match state.workspace_identity with
    | Masc_tui_types.Workspace_identity_mismatch { local_base_path; _ } ->
        [ Masc_tui_footer.Workspace_mismatch
            (Terminal_text.single_line local_base_path)
        ]
    | Masc_tui_types.Workspace_identity_match_unconfirmed _ ->
        [ Masc_tui_footer.Workspace_unconfirmed ]
    | Masc_tui_types.Workspace_identity_unread
    | Masc_tui_types.Workspace_identity_match -> []
  in
  Masc_tui_footer.line ?literal_prefix ?action_text ?preferred_action ?position
    ~help_key_answers:door_answers ~ko:(state.ui_language = Lang_ko)
    ~status:(keeper_action_status state @ task_creation_status state
      @ List.filter (fun item -> Masc_tui_footer.needs_operator item
          && not (List.mem item (keeper_action_status state))) status
      @ identity @ conflict)
    ~dim:Ansi.dim ~reset:Ansi.reset ~max_cells ~hints ()


(* The slash word being typed, painted: the run already pressed in the accent,
   a word that is no command in the bad tone. [restore] is the colour the row
   around it is drawn in, so a painted span hands that back rather than
   resetting it. *)
let slash_hint_text ~restore draft =
  let paint (span : Masc_tui_command.hint_span) =
    match span with
    | Masc_tui_command.Typed text ->
        Theme.accent () ^ text ^ restore
    | Masc_tui_command.Wrong text -> Theme.bad () ^ text ^ restore
    | Masc_tui_command.Untyped text | Masc_tui_command.Detail text -> text
  in
  match Masc_tui_command.hint_spans (Masc_tui_command.hint draft) with
  | [] -> None
  | spans -> Some (String.concat "" (List.map paint spans))

(* One synchronous frame owns the recipient, prompt and fitted draft used by
   both its row and caret. Nothing survives to the next frame or key handler. *)
let composer_row state ~rows ~cols =
  let ko = state.ui_language = Lang_ko in
  let focus_hint word = Composer.focus_key ^ ":" ^ word in
  if state.view = Overview && not state.composer_focused then
    let note=match Composer.reading_note ~ko (Composer_projection.source_reading state) with
      | None ->
          ui_text state ~ko:"쓰기 전에 키퍼를 고르세요"
            ~en:"Choose a Keeper before writing"
      | Some note -> Terminal_text.single_line note in
    let choose = focus_hint (ui_text state ~ko:"고르기" ~en:"choose") in
    (Theme.recede () ^ fit_width (" " ^ note ^ " · " ^ choose) cols ^ Ansi.reset,
     Frame_presenter.Hidden)
  else match browser_lane_on_screen state with
  (* The page reader owns the keys here, so there is no composer to draw. The
     row it would take stays empty: the title already names the lane, its
     source and its browser, and a second copy down here is a state the reader
     has to match up by position. *)
  | Some _ -> (Theme.recede () ^ fit_width "" cols ^ Ansi.reset, Frame_presenter.Hidden)
  | None ->
  let composer = Composer_projection.of_state state in
  let prompt = composer_prompt_text ~voice:(voice_meter_text state) ~ko composer in
  (* The caret uses exactly the prompt the row draws, including the voice
     meter, and exactly the escaped, grapheme-aligned draft window below. *)
  let prompt_cells = Message_layout.display_width prompt in
  let draft, draft_cells =
    let draft = Terminal_text.single_line composer.Composer.draft in
    (* Editing stops at whole grapheme boundaries, so this prefix cannot end
       inside a ZWJ/variation-selector sequence whose escaping needs its suffix. *)
    let before = match composer.Composer.focus with
      | Composer.Focused ->
          Terminal_text.single_line (Masc_tui_message_input.before_cursor state.msg_input)
      | Composer.Unfocused -> draft in
    Message_layout.input_window ~max_cells:(max 0 (cols - prompt_cells))
      ~cursor:(String.length before) draft
  in
  let tone =
    match (composer.Composer.focus, composer.Composer.target) with
    | Composer.Focused, _ -> Ansi.default_fg
    | Composer.Unfocused, Composer.Ready _ -> Ansi.dim
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) ->
        Ansi.dim
  in
  let hint =
    match (composer.Composer.focus, composer.Composer.target) with
    (* A focused row draws the draft alone; the voice keys are on the key
       sheet ([Masc_tui_keys], "…?"). *)
    | Composer.Focused, _ -> ""
    | Composer.Unfocused, Composer.Ready _ ->
        focus_hint (ui_text state ~ko:"쓰기" ~en:"write")
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) -> ""
  in
  (* A slash command sent from this row runs as it does from the chat pane,
     but only the chat pane's footer said what the word being typed was:
     "/tsk" read here as a message until Enter, and the candidates for "/t"
     showed nowhere. The hint follows the draft, so the cursor, which is
     placed after the draft, does not move. *)
  let slash_hint =
    match composer.Composer.focus with
    | Composer.Focused -> slash_hint_text ~restore:tone composer.Composer.draft
    | Composer.Unfocused -> None
  in
  let body =
    match String.equal draft "", slash_hint with
    | true, _ -> prompt
    | false, None -> prompt ^ draft
    | false, Some line -> prompt ^ draft ^ "   " ^ line
  in
  let body=match Composer.row_note ~ko composer with
    | None -> body
    | Some note -> body ^ "  · " ^ Terminal_text.single_line note in
  (* The key that opens the row sits at the right end, one cell in from the
     edge as the prompt is one cell in from the left. After the recipient it
     moved with the length of every name the cursor passed. It is drawn only
     beside an empty draft, and gives way whole when the row is too narrow
     for the recipient, its note and the key. *)
  let body =
    let hint_cells = Message_layout.display_width hint in
    let edge_cells = 1 in
    let body_cells = cols - hint_cells - edge_cells in
    if String.equal hint "" || not (String.equal draft "")
       || Message_layout.display_width body + composer_hint_gap_cells > body_cells
    then fit_width body cols
    else fit_width body body_cells ^ hint ^ String.make edge_cells ' '
  in
  (* A held tool call is drawn on whatever surface the operator is looking at.
     Its prompt lives in the chat pane, and a turn holding a call is denied
     when the wait runs out -- so an operator reading the Board would lose the
     call without ever seeing that it was waiting. This line says a keeper is
     waiting and where to answer; the answer itself stays in the chat pane,
     where it is unambiguous which keeper and which call it is for. *)
  let line = match awaiting_approval_notice state with
    | Some notice -> (Theme.warn ()) ^ fit_width notice cols ^ Ansi.reset
    | None -> tone ^ fit_width body cols ^ Ansi.reset
  in
  let cursor = match composer.Composer.focus with
    | Composer.Unfocused -> Frame_presenter.Hidden
    | Composer.Focused ->
        Frame_presenter.Visible_at
          { row = rows
          ; column = Composer.cursor_column ~prompt_cells ~draft_cells ~terminal_cols:cols
          }
  in
  (line, cursor)

;;

(* The Overview's Pulse: Keeper turns that finished in each of the last eight
   fifteen-second windows, oldest first. The finishes are counted from two
   successive keeper-turn readings, so until one reading has come back there is
   nothing to count -- and eight flat bars said "nothing finished" for a read
   that had not been made or had been refused. The shared words say which. *)

let connection_status_parts ~ko (status : Masc_tui_types.connection_status) =
  (* This badge summarizes HTTP refreshes. A rejected read (for example 429)
     can fail while the independent Recent event feed remains live. *)
  match status with
  | Connected -> Theme.text_status Masc_tui_theme.Ok,
      (if ko then "연결됨" else "connected"),
      (if ko then ["HTTP 연결됨", false; "연결됨", true] else ["HTTP connected", false; "connected", true; "HTTP up", true])
  | Degraded -> Theme.text_status Masc_tui_theme.Warn,
      (if ko then "일부 관측" else "partial"),
      (if ko then ["HTTP 일부 관측", false; "일부 관측", true] else ["HTTP partial", false; "partial", true])
  | Connecting -> Theme.text_status Masc_tui_theme.Warn,
      (if ko then "조회 중" else "loading"),
      (if ko then ["HTTP 조회 중", false; "조회 중", true] else ["HTTP loading", false; "loading", true])
  | Booting -> Theme.text_status Masc_tui_theme.Warn,
      (if ko then "서버 시작 중" else "server booting"),
      (if ko then ["서버 시작 중", false; "시작 중", true] else ["server booting", false; "booting", true])
  | Disconnected -> Theme.text_status Masc_tui_theme.Bad,
      (if ko then "조회 실패" else "refresh failed"),
      (if ko then ["HTTP 조회 실패", false; "조회 실패", true] else ["HTTP refresh failed", false; "HTTP failed", true; "failed", true])

type compact_connection_state =
  | Compact_workspace_mismatch
  | Compact_workspace_unconfirmed
  | Compact_workspace_unread
  | Compact_read_failed
  | Compact_read_partial
  | Compact_read_interrupted
  | Compact_read_unfinished
  | Compact_reading
  | Compact_http of connection_status

let compact_connection_state (state : state) =
  let progress = match state.http_refresh_progress with
    | Some (authority, progress) when authority = state.workspace_authority -> Some progress
    | Some _ | None -> None in
  let failed, partial, interrupted, unfinished, in_flight =
    match progress with
    | None -> false, false, false, false, false
    | Some progress ->
        let counts = Http_refresh_progress.counts progress in
        let failed, interrupted, unfinished =
          Http_refresh_progress.unreturned_component_reads progress
          |> List.fold_left (fun (failed, interrupted, unfinished) reading ->
               match reading.Http_refresh_progress.cr_status with
               | Component_pending | Component_settled (_, Component_returned Part_received) ->
                   failed, interrupted, unfinished
               | Component_settled (_, (Component_returned Part_failed | Component_exception)) ->
                   true, interrupted, unfinished
               | Component_settled (_, Component_interrupted) -> failed, true, unfinished
               | Component_settled (_, Component_unfinished) -> failed, interrupted, true)
               (false, false, false) in
        failed || counts.failed > 0, counts.partial > 0,
        interrupted || counts.interrupted > 0, unfinished,
        (match progress.phase with In_flight -> true | Finished _ -> false) in
  let scoped_reading = surface_reads_pending state <> [] in
  match state.workspace_identity with
  | Workspace_identity_mismatch _ -> Compact_workspace_mismatch
  | Workspace_identity_match_unconfirmed _ -> Compact_workspace_unconfirmed
  | Workspace_identity_unread when state.connection_status = Connected
                                   || state.connection_status = Degraded ->
      Compact_workspace_unread
  | Workspace_identity_unread | Workspace_identity_match ->
      if state.connection_status = Disconnected then Compact_http Disconnected
      else if failed then Compact_read_failed
      else if partial then Compact_read_partial
      else if interrupted then Compact_read_interrupted
      else if unfinished then Compact_read_unfinished
      else match state.connection_status with
        | Connected when in_flight || scoped_reading -> Compact_reading
        | Connected | Degraded | Connecting | Booting | Disconnected as status -> Compact_http status

(* The words for each connection state, longest first, with whether a
   spelling leaves out what the full badge says and whether the state needs
   the full badge beside it whatever the spelling. *)
let compact_connection_wording ~ko compact =
  let options ko_label en_labels = if ko then [ko_label, true] else en_labels in
  let spelled whole state = [ whole ~ko, false; state ~ko, true ] in
  match compact with
  | Compact_workspace_mismatch -> Theme.text_status Masc_tui_theme.Bad, spelled workspace_mismatch field_mismatch, true
  | Compact_workspace_unconfirmed -> Theme.text_status Masc_tui_theme.Warn, spelled workspace_identity_unconfirmed field_unconfirmed, true
  | Compact_workspace_unread -> Theme.text_status Masc_tui_theme.Warn, spelled workspace_identity_unread field_unread, true
  | Compact_read_failed -> Theme.text_status Masc_tui_theme.Bad, options "조회 실패" ["read failed", true; "failed", true], true
  | Compact_read_partial -> Theme.text_status Masc_tui_theme.Warn, options "일부 관측" ["read partial", true; "partial", true], true
  | Compact_read_interrupted -> Theme.text_status Masc_tui_theme.Warn, options "조회 중단" ["read interrupted", true; "interrupted", true], true
  | Compact_read_unfinished -> Theme.text_status Masc_tui_theme.Warn, options "조회 미완료" ["read unfinished", true; "unfinished", true], true
  | Compact_reading -> Theme.text_status Masc_tui_theme.Warn, options "조회 중" ["reading data", true; "reading", true], true
  | Compact_http status ->
      let style, _, options = connection_status_parts ~ko status in
      style, options, false

(* What the top row says about the connection: one mark and the shortest
   word for the state. A refresh in flight is not a state of the connection --
   it comes and goes with every read, and the row every screen starts with
   would change with it -- so it reads as the HTTP status under it. *)
let strip_connection_reading (state : state) =
  let ko = state.ui_language = Lang_ko in
  let compact =
    match compact_connection_state state with
    | Compact_reading -> Compact_http state.connection_status
    | ( Compact_workspace_mismatch | Compact_workspace_unconfirmed
      | Compact_workspace_unread | Compact_read_failed | Compact_read_partial
      | Compact_read_interrupted | Compact_read_unfinished | Compact_http _ ) as
      compact -> compact
  in
  let mark : Masc_tui_value.Mark.t =
    match compact with
    | Compact_http Connected -> Settled
    | Compact_http (Connecting | Booting) | Compact_reading -> Under_way
    | Compact_http Degraded | Compact_workspace_unconfirmed
    | Compact_workspace_unread | Compact_read_partial
    | Compact_read_interrupted | Compact_read_unfinished -> Caution
    | Compact_http Disconnected | Compact_workspace_mismatch
    | Compact_read_failed -> Failed
  in
  let style, word =
    match compact with
    | Compact_http status ->
        let style, word, _ = connection_status_parts ~ko status in
        style, word
    | Compact_workspace_mismatch | Compact_workspace_unconfirmed
    | Compact_workspace_unread | Compact_read_failed | Compact_read_partial
    | Compact_read_interrupted | Compact_read_unfinished | Compact_reading ->
        let style, spellings, _ = compact_connection_wording ~ko compact in
        style, List.fold_left (fun _ (spelling, _) -> spelling) "" spellings
  in
  style, Masc_tui_value.Mark.glyph mark ^ " " ^ word

(* The gap between the last ring entry and the waiting badge. *)
let waiting_badge_gap_cells = 3

(* The cells ahead of the connection reading at the right-hand end of the
   strip, and between it and the clock. *)
let strip_reading_gap_cells = 2

(* The strip above every surface: the Tab ring with the active family
   highlighted, then what waits on the operator. Wider terminals see the whole
   ring; narrower ones see a window around the active entry with how many
   entries hide past each edge, so position in the cycle stays readable at any
   width.

   The badge is drawn first and the ring windows into what is left: the ring
   has the Tab key to reach what a window hides, and a count that waited on
   the operator behind that window would never be seen. The badge may take at
   most half the row. *)
let surface_strip (state : state) ~cols =
  (* An array because the strip is drawn by index: the width probe, the
     label and the cell each read entry [i], and a list answers that by
     walking. The short ring makes that cost nothing -- it is an array so the
     renderer holds no row lookup that walks, with no exception to carry. *)
  let ring = Array.of_list Masc_tui_types.surface_ring in
  let n = Array.length ring in
  let active = Masc_tui_surface_navigation.surface_ring_index state.view in
  (* A count rides the entry it belongs to, so pending work is visible from
     every surface without a spare row. Zero draws nothing -- an always-on
     badge would be texture, not information. *)
  let badge_of_surface surface =
    match (surface : surface) with
    | Planning ->
        (match state.verification with
         | Some snapshot when snapshot.Masc.Tui_decode.vs_total > 0 ->
             Printf.sprintf "\xc2\xb7%d" snapshot.Masc.Tui_decode.vs_total
         | Some _ | None -> "")
    | Overview | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | Tools | System_logs | Keepers _ -> ""
  in
  let badge =
    Agenda.waiting_label ~ko:(state.ui_language = Lang_ko) ~cells:(cols / 2)
      (Masc_tui_types.agenda state)
  in
  let badge_reserved =
    if badge = "" then 0
    else Message_layout.display_width badge + waiting_badge_gap_cells
  in
  (* The right-hand end: the connection, then the clock and the zone every
     moment on the screen is drawn in. The clock is drawn while the whole ring
     still fits beside it; a row too narrow for both keeps the ring, which is
     how the operator moves. The mark and its word are always drawn, because
     a screen that draws nothing is explained by them. *)
  let connection_style, connection = strip_connection_reading state in
  let wall_clock = Masc_tui_value.Instant.wall_clock ~now:(Unix.gettimeofday ()) in
  let ring_cells =
    let cells = ref 0 in
    Array.iteri
      (fun i (surface, name) ->
        cells :=
          !cells
          + Message_layout.display_width
              (Masc_tui_types.surface_ring_display_label ~lang:state.ui_language
                 surface name
               ^ badge_of_surface surface)
          + (if i = active then 1 else 0)
          + (if i > 0 then 2 else 0))
      ring;
    !cells
  in
  let reading_clock =
    if 1 + ring_cells + badge_reserved + strip_reading_gap_cells
       + Message_layout.display_width connection + strip_reading_gap_cells
       + Message_layout.display_width wall_clock <= cols
    then Some wall_clock
    else None
  in
  let reading_cells =
    Message_layout.display_width connection
    + (match reading_clock with
       | Some clock -> strip_reading_gap_cells + Message_layout.display_width clock
       | None -> 0)
  in
  let reading_reserved = reading_cells + strip_reading_gap_cells in
  let budget = max 8 (cols - 1 - badge_reserved - reading_reserved) in
  let active_hidden_cells =
    (if active > 0 then Message_layout.display_width (hidden_before_mark active) + 1 else 0)
    + (if active < n - 1 then
         Message_layout.display_width (hidden_after_mark (n - 1 - active)) + 1
       else 0)
  in
  let active_label_cells =
    max 0 (budget - active_hidden_cells
           - Message_layout.display_width Masc_tui_theme.Glyph.current_entry)
  in
  let label i =
    let surface, name = ring.(i) in
    let text =
      Masc_tui_types.surface_ring_display_label ~lang:state.ui_language
        surface name
      ^ badge_of_surface surface
    in
    (* Even a window containing only the active entry must leave room for
       its hidden-entry markers and the operator's waiting badge. Measurement
       and drawing both use this same cell-bounded label. *)
    if i = active then Message_layout.truncate_middle active_label_cells text
    else text
  in
  (* Plain-cell width of entry [i] inside a window starting at [lo]. *)
  let entry_width ~lo i =
    (* Cells, not bytes: the badge's middle dot is two bytes and one cell,
       and a byte count windows the strip one entry early. *)
    Message_layout.display_width (label i)
    + (if i = active then 1 else 0)
    + (if i > lo then 2 else 0)
  in
  let window_width lo hi =
    let rec sum i acc =
      if i > hi then acc else sum (i + 1) (acc + entry_width ~lo i)
    in
    sum lo 0
  in
  let lo, hi =
    if window_width 0 (n - 1) <= budget then (0, n - 1)
    else begin
      (* The active-only window has the largest hidden-entry markers. Any
         expansion can only reduce their cost; never borrow badge cells. *)
      let budget = max 0 (budget - active_hidden_cells) in
      let lo = ref active and hi = ref active in
      let grew = ref true in
      while !grew do
        grew := false;
        if !hi + 1 < n && window_width !lo (!hi + 1) <= budget then begin
          incr hi;
          grew := true
        end;
        if !lo > 0 && window_width (!lo - 1) !hi <= budget then begin
          decr lo;
          grew := true
        end
      done;
      (!lo, !hi)
    end
  in
  let parts = Buffer.create 128 in
  Buffer.add_char parts ' ';
  (* Every entry and both hidden counts are pressable. A press on an entry is
     Tab walked to it; a press on a count is one Tab step toward that edge. *)
  if lo > 0 then
    Buffer.add_string parts
      (Printf.sprintf "%s%s%s " Ansi.dim
         (pressable (Press_ring_edge Ring_before) (hidden_before_mark lo))
         Ansi.reset);
  for i = lo to hi do
    if i > lo then Buffer.add_string parts "  ";
    let surface, _ = ring.(i) in
    let entry =
      if i = active then
        Theme.sidebar_selection () ^ Ansi.bold ^ Masc_tui_theme.Glyph.current_entry
        ^ label i ^ Ansi.reset
      else Ansi.dim ^ label i ^ Ansi.reset
    in
    Buffer.add_string parts (pressable (Press_surface surface) entry)
  done;
  if hi < n - 1 then
    Buffer.add_string parts
      (Printf.sprintf " %s%s%s" Ansi.dim
         (pressable (Press_ring_edge Ring_after) (hidden_after_mark (n - 1 - hi)))
         Ansi.reset);
  if badge <> "" then
    Buffer.add_string parts
      (String.make waiting_badge_gap_cells ' ' ^ Theme.bad () ^ badge ^ Ansi.reset);
  (* Flush right: the clock keeps its column whatever the ring shows, and the
     ring keeps its column whatever the connection says. *)
  let drawn_cells =
    1
    + (if lo > 0 then Message_layout.display_width (hidden_before_mark lo) + 1 else 0)
    + window_width lo hi
    + (if hi < n - 1 then
         Message_layout.display_width (hidden_after_mark (n - 1 - hi)) + 1
       else 0)
    + badge_reserved
  in
  Buffer.add_string parts
    (String.make (max strip_reading_gap_cells (cols - drawn_cells - reading_cells)) ' ');
  Buffer.add_string parts (connection_style ^ connection ^ Ansi.reset);
  (match reading_clock with
   | Some clock ->
       Buffer.add_string parts
         (String.make strip_reading_gap_cells ' ' ^ Ansi.dim ^ clock ^ Ansi.reset)
   | None -> ());
  Buffer.contents parts


(* Side-by-side panes share one threshold and one context-pane width, so
   every split surface folds at the same terminal size. *)
let keeper_split_threshold_cols = Masc_tui_roster_pane.threshold_cols

let keeper_roster_pane_cols = Masc_tui_roster_pane.pane_cols


(* The line [surface_strip] draws above every surface. A row a surface counts
   in its own frame sits this many lines lower in the terminal's. *)
let strip_rows = 1

(* Finish a frame with the strip on top. Surfaces measured cursor rows inside
   their own frame, so a visible cursor shifts down with the prepend, and the
   declared height grows back to the terminal's real row count. *)
let finish_frame_with_strip (state : state) ?clamped ~surface_key ~cursor ~rows
    ~cols buf =
  let cursor =
    match cursor with
    | Frame_presenter.Hidden -> Frame_presenter.Hidden
    | Frame_presenter.Visible_at { row; column } ->
      Frame_presenter.Visible_at { row = row + strip_rows; column }
  in
  let framed = Buffer.create (Buffer.length buf + 160) in
  Buffer.add_string framed (surface_strip state ~cols);
  Buffer.add_char framed '\n';
  Buffer.add_buffer framed buf;
  finish_frame ?clamped ~surface_key ~cursor ~rows:(rows + strip_rows) ~cols framed


(* The agenda strip: one row above the composer, on surfaces that end in
   [finish_surface]. It holds the next wake and recedes -- a schedule that
   fires in an hour is ambient, and painting it warn would make the screen
   shout every hour. What waits on the operator is not here: the surface strip
   at the top carries it in red, on every surface. The row starts at the same
   column as the rows around it: the surface strip above and the composer
   below both leave the frame's margin. *)
let agenda_line agenda ~ko ~cols =
  let margin = Masc_tui_ansi.framed_content_column in
  match
    Agenda.strip
      ~ko
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols:(cols - margin)
      agenda
  with
  | None -> None
  | Some clock ->
    Some (String.make margin ' ' ^ (Theme.recede ()) ^ clock ^ Ansi.reset)

;;

(* Close a surface: pad its frame to the row above the composer, then draw the
   composer on the terminal's last row.

   The padding is what keeps the two in step. Each surface computes its own
   height, and one that came out short used to leave its footer stranded
   partway up the screen; now it would push the composer up with it, and the
   row an operator reaches for would move per surface. *)
(* What the Activity pane reads, gathered from the state the surfaces
   already hold. The pane module interprets none of it: health becomes a
   mark and a tone here, the feed's status becomes its four words here, and
   the agent-core correlation ids resolve through the same trace table the
   Activity surface uses. *)
(* The address a change is listed under and the range label it carries.
   Named here, ahead of every surface, because the Activity pane lists the
   selected keeper's changes the same way the Changes surface does -- and the
   address itself is Tui_decode's now, so the row search can read the same
   one without the renderer. *)
let change_row_address = Masc.Tui_decode.file_change_address


let file_change_range_label
      (range : Masc.Keeper_file_change_evidence.line_range)
  =
  if range.start_line = range.end_line
  then Printf.sprintf "L%d" range.start_line
  else Printf.sprintf "L%d-%d" range.start_line range.end_line


let file_change_evidence_label ~ko = function
  | None -> None
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = None }) ->
    Some (if ko then "빈 파일" else "empty file")
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = Some range }) ->
    Some (file_change_range_label range)
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = None }) ->
    Some
      (Printf.sprintf
         (if ko then "%d건 일치 · 범위 생략" else "%d matches; ranges omitted")
         occurrence_count)
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = Some occurrences }) ->
    (match occurrences with
     | [] ->
       Some (Printf.sprintf (if ko then "%d건 일치" else "%d matches") occurrence_count)
     | first :: _ ->
       let old_range = file_change_range_label first.old_range in
       let changed =
         match first.new_range with
         | Some new_range -> old_range ^ "→" ^ file_change_range_label new_range
         | None -> old_range ^ (if ko then "→삭제" else "→deleted")
       in
       if occurrence_count = 1
       then Some changed
       else Some (Printf.sprintf "%s (+%d)" changed (occurrence_count - 1)))


(* The selected keeper's file changes as the pane's Changes tab draws
   them: the fetch helper's four states named one by one, each change
   read to the address, the kind, whether it landed, and its range. *)
let acting_pane_changes_and_source (state : state) =
  let module Pane = Masc_tui_acting_pane in
  match selected_keeper state with
  | None -> Pane.Changes_absent, None
  | Some (keeper : keeper) -> (
      let ready_changes (reading : acting_pane_read) ~refresh_failed =
        let snapshot = reading.apr_snapshot in
        let file (change : Masc.Tui_decode.file_change) =
          { Pane.file_path = change_row_address change
          ; file_kind =
              (match change.fc_kind with
               | Masc.Tui_decode.Fc_edited _ | Masc.Tui_decode.Fc_inserted _ ->
                 Pane.File_edited
               | Masc.Tui_decode.Fc_written _
               | Masc.Tui_decode.Fc_materialized _ -> Pane.File_written)
          ; file_succeeded = change.fc_succeeded
          ; file_at = change.fc_at
          ; file_where =
              file_change_evidence_label ~ko:(state.ui_language = Lang_ko)
                change.fc_line_evidence
          }
        in
        let changes = Pane.Changes_ready
          { keeper = snapshot.fcs_keeper
          ; files = List.map file snapshot.fcs_changes
          ; fetched_at =
              (* [Ready] is only ever set beside the stamp; a missing
                 stamp reads as an answer from this instant. *)
              Option.value state.acting_pane_changes_at
                ~default:(Unix.gettimeofday ())
          ; window_hours = snapshot.fcs_window_hours
          ; calls = snapshot.fcs_calls_in_window
          ; over_budget = snapshot.fcs_over_budget
          ; malformed = snapshot.fcs_malformed
          ; authority =
              (if not (server_authority_ready state) then Pane.Changes_workspace_unconfirmed
               else if same_acting_pane_scope reading.apr_scope
                   (state.workspace_authority, state.workspace_read_authority)
               then Pane.Changes_current
               else if Masc_tui_fetched.in_flight state.acting_pane_changes
               then Pane.Changes_revalidating
               else Pane.Changes_needs_revalidation)
          ; refresh_failed
          }
        in
        let source =
          { aps_keeper = keeper.k_name
          ; aps_read = reading
          }
        in
        changes, Some source
      in
      match
        Masc_tui_fetched.view_for ~equal:same_acting_pane_keeper state.acting_pane_changes
          ~key:{apk_keeper=keeper.k_name; apk_scope=state.workspace_authority, state.workspace_read_authority}
      with
      | Masc_tui_fetched.Absent -> Pane.Changes_absent, None
      | Masc_tui_fetched.Loading -> Pane.Changes_loading, None
      | Masc_tui_fetched.Failed detail -> Pane.Changes_failed detail, None
      | Masc_tui_fetched.Ready snapshot -> ready_changes snapshot ~refresh_failed:None
      (* The files already read stay listed; the status row says the refresh
         after them failed. *)
      | Masc_tui_fetched.Stale (snapshot, detail) ->
          ready_changes snapshot ~refresh_failed:(Some detail))

let recent_chunk_projection (state : state) =
  let trace_reading = Tui_decode.keeper_trace_projection state.keepers in
  let traces = trace_reading.bindings in
  Masc_tui_acting.refresh_projection
    ~previous:state.acting_chunk_projection ~traces state.acting


let acting_pane_input (state : state) =
  let module Pane = Masc_tui_acting_pane in
  let selected = selected_keeper state in
  let pane_keeper (keeper : keeper) : Pane.keeper =
    let reading = keeper_reading state keeper in
    let health = Keeper_control.health reading in
    let paused = reading.Keeper_control.paused in
    let reading_of_health = Option.map Tui_decode.keeper_health_reading health in
    let mark_tone =
      if paused then Pane.Dim
      else
        match reading_of_health with
        | Some Tui_decode.Health_running -> Pane.Ok
        | Some Tui_decode.Health_idle -> Pane.Dim
        | Some Tui_decode.Health_failing -> Pane.Warn
        | Some Tui_decode.Health_offline -> Pane.Bad
        | None -> Pane.Dim
    in
    { Pane.name = keeper.k_name
    ; mark = Masc_tui_keeper_mark.glyph ~paused reading_of_health
    ; mark_tone
    ; health = reading_of_health
    }
  in
  let keepers =
    match keeper_rows_page state ~error:state.keepers_error with
    | Page_unread -> None
    | Page_empty | Page_failed -> Some (List.map pane_keeper state.keepers)
  in
  let feed =
    match state.observer with
    | Observer_off -> Pane.Feed_off
    | Observer_opening -> Pane.Feed_opening
    | Observer_live { events; _ } -> Pane.Feed_live events
    | Observer_closed_before_answer { reason; _ }
    | Observer_closed_after_live { reason; _ } -> Pane.Feed_closed reason
  in
  (* This input is built only when the pane is visible. Changes does not
     consume event chunks, so retain the previous projection without folding. *)
  let chunks = match state.acting_pane_tab with
    | Pane.Tab_changes -> []
    | Pane.Tab_fleet ->
      (* The loop normally prepared this projection. Direct render callers
         still get current chunks on a miss, without changing their state. *)
      Masc_tui_acting.projection_chunks (recent_chunk_projection state)
  in
  let keeper_context = match state.view, selected with
    | Keepers Keeper_list, Some keeper ->
        let workspace_ready =
          state.workspace_identity = Workspace_identity_match
          && server_authority_ready state in
        let waiting =
          (* A waiting change only marks the Keeper unverified until the read
             that follows lands. Keeping the last observed row through that
             window stops the pane line from flapping between the warning and
             the count on every change burst; a Keeper never observed, or a
             workspace that cannot answer, still shows the warning. *)
          let last_row =
            List.find_opt (fun (row : Tui_decode.keeper_waiting_row) ->
              String.equal row.kwr_keeper_name keeper.k_name) state.keeper_waiting
          in
          if not workspace_ready then Masc_tui_keeper_list_model.Waiting_unavailable
          else match last_row with
            | Some row -> Masc_tui_keeper_list_model.Waiting_observed row
            | None ->
                if List.mem keeper.k_name state.keeper_waiting_unverified
                   || Option.is_some state.keeper_waiting_failure
                then Masc_tui_keeper_list_model.Waiting_unavailable
                else Masc_tui_keeper_list_model.Waiting_unobserved in
        let task_source = match state.local_keepers with
          | Local_workspace_unread -> Pane.Task_source_unread
          | Local_workspace_read -> Pane.Task_source_read
          | Local_workspace_failed _ -> Pane.Task_source_failed in
        let task = Pane.summarize_keeper_task ~workspace_ready ~source:task_source
          ~metadata_failed:(Option.is_some state.keepers_error)
          ~task_id:(Option.bind keeper.k_activity (fun activity -> activity.k_current_task_id)) in
        Some Pane.{ keeper_name = keeper.k_name; task;
          waiting; waiting_stale = Option.is_some state.keeper_turns_error;
          waiting_revalidating = List.mem keeper.k_name state.keeper_waiting_unverified;
          waiting_failed = Option.is_some state.keeper_waiting_failure
                           || Option.is_some state.keeper_waiting_error }
    | (Keepers Keeper_list | Keepers (Keeper_detail | Keeper_logs | Keeper_calls
        | Keeper_message | Keeper_runtime_pick) | Overview | Acting | Metrics | Memory
      | Lanes | Clients | Board | Approvals | Planning | Schedules | Verification
      | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
      | Config | Resources | Tools | System_logs), (Some _ | None) -> None in
  let changes, source =
    match state.acting_pane_tab with
    | Pane.Tab_changes -> acting_pane_changes_and_source state
    | Pane.Tab_fleet -> Pane.Changes_absent, None
  in
  ({ Pane.now = Unix.gettimeofday ()
  ; tab = state.acting_pane_tab
  ; scope =
      (match state.view with
       | Keepers Keeper_list -> Pane.Selected_only
       | Keepers
           (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
       | Overview | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning
       | Schedules | Verification | Harness | Fusion | Repositories | Code | Changes
       | Connectors | Runtime | Config | Resources | Tools | System_logs ->
           Pane.Whole_fleet)
  ; feed
  ; keepers
  ; trace_unavailable = (Tui_decode.keeper_trace_projection state.keepers).unavailable
  ; keepers_error = state.keepers_error
  ; selected = Option.map (fun (keeper : keeper) -> keeper.k_name) selected
  ; keeper_context
  ; approvals =
      (* Every kind of pending approval the Approvals surface lists, read to
         the two facts the pane states: whose, and for which tool. *)
      List.map
        (fun (row : Masc_tui_approvals_model.approval_row) ->
          match row with
          | Masc_tui_approvals_model.Keeper_tool_row held ->
              { Pane.approval_keeper = held.kta_keeper; approval_tool = held.kta_tool }
          | Masc_tui_approvals_model.Gate_row pending ->
              { Pane.approval_keeper = pending.gp_keeper
              ; approval_tool = pending.gp_display_tool
              }
          | Masc_tui_approvals_model.Operator_row item ->
              { Pane.approval_keeper = item.ap_actor
              ; approval_tool = item.ap_delegated_tool
              })
        (Masc_tui_approvals_model.approval_items state)
  ; chunks
  ; changes
  ; call_order = state.acting_pane_call_order
  ; expanded = state.acting_pane_expanded
  ; ko = state.ui_language = Lang_ko
  }, source)


(* A pane tone is a reading; the theme answers with the colour. *)
let acting_pane_sgr (tone : Masc_tui_acting_pane.tone) =
  match tone with
  | Masc_tui_acting_pane.Plain -> ""
  | Masc_tui_acting_pane.Dim -> Theme.recede ()
  | Masc_tui_acting_pane.Accent -> Ansi.bold ^ Theme.info ()
  | Masc_tui_acting_pane.Ok -> Theme.ok ()
  | Masc_tui_acting_pane.Warn -> Theme.warn ()
  | Masc_tui_acting_pane.Bad -> Theme.bad ()
  | Masc_tui_acting_pane.Info -> Theme.info ()


(* The pane sits on its own ground. Every span's reset would drop the row
   back to the page's ground mid-row, so the ground is re-opened after each
   one; the row ends on a full reset so the surface's next row starts on the
   page. Without a palette the ground is [""] and the row draws as before. *)
let paint_acting_pane_line ?(selected = false) ~ground
    (line : Masc_tui_acting_pane.line) =
  (* The cursor row is reverse video over the whole row, re-opened after
     each span's reset the way the ground is: an attribute, not a colour,
     so NO_COLOR keeps it. *)
  let ground = if selected then ground ^ Ansi.reverse else ground in
  let restore = if String.equal ground "" then "" else Ansi.reset ^ ground in
  let close = if String.equal ground "" then "" else Ansi.reset in
  ground
  ^ String.concat ""
      (List.map
         (fun (span : Masc_tui_acting_pane.span) ->
           match acting_pane_sgr span.tone with
           | "" -> span.text
           | sgr -> sgr ^ span.text ^ Ansi.reset ^ restore)
         line)
  ^ close


(* A surface's rows with the Activity pane beside the first [pane_rows] of
   them, when the pane shows. [cols] is what the surface laid out against:
   the terminal less the pane. Rows past [pane_rows] draw alone. The pane's
   press targets and scroll bound are this frame's either way -- a frame that
   reserved the pane's columns without drawing it left the last surface's
   targets under a press on the empty columns. *)
let add_rows_beside_acting_pane (state : state) framed ~cols ~pane_rows lines =
  let pane_cols = !acting_pane_reserved_cols in
  if pane_cols > 0 then begin
    let left = Buffer.create 4096 in
    List.iter
      (fun line ->
         Buffer.add_string left (Message_layout.fit_width line cols);
         Buffer.add_char left '\n')
      lines;
    let input, source = acting_pane_input state in
    let rendering =
      Masc_tui_acting_pane.lines ~rows:pane_rows ~cols:pane_cols
        ~scroll:state.acting_pane_scroll input
    in
    state.acting_pane_cursor <- Masc_tui_acting_pane.reconcile_context_cursor
      ~previous_rows:!acting_pane_context_rows
      ~current_rows:rendering.Masc_tui_acting_pane.context_rows state.acting_pane_cursor;
    acting_pane_context_rows := rendering.Masc_tui_acting_pane.context_rows;
    frame_acting_pane :=
      { Masc_tui_acting_pane.frame_columns = pane_cols
      ; frame_targets = rendering.Masc_tui_acting_pane.targets
      ; frame_scroll_max = rendering.Masc_tui_acting_pane.scroll_max
      ; frame_source = Some { aps_scope = state.workspace_authority, state.workspace_read_authority
                      ; aps_file_source = source }
      };
    let ground = Theme.side_pane_background () in
    let right = Buffer.create 4096 in
    let cursor = Option.value state.acting_pane_cursor ~default:(-1) in
    List.iteri
      (fun index line ->
         Buffer.add_string right
           (paint_acting_pane_line ~selected:(index = cursor) ~ground line);
         Buffer.add_char right '\n')
      rendering.Masc_tui_acting_pane.rows;
    write_two_panes framed ~left_cols:cols ~left ~right
  end
  else begin
    acting_pane_context_rows := 0;
    List.iter
      (fun line ->
         Buffer.add_string framed line;
         Buffer.add_char framed '\n')
      lines
  end


let finish_surface (state : state) ?clamped ~surface_key ~rows ~cols buf =
  let body_started = Masc_tui_frame_timing.start_stage () in
  (* [surface_body_rows] removes the strip before either the frame or the
     typed scroll layout receives its body budget. Two readers of that one
     budget: the row the frame draws is the row the keypress stops short of. *)
  let agenda_rows = Masc_tui_types.agenda_chrome_rows state in
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows:rows in
  let drawn = frame_lines buf in
  let body =
    if List.length drawn <= body_rows then
      drawn @ List.init (body_rows - List.length drawn) (fun _ -> "")
    else
      (* A surface that came out taller than its budget loses its last rows
         rather than the composer. The body is already scrollable and the
         composer is a fixed contract -- the row an operator reaches for cannot
         be the one that disappears when a surface miscounts. *)
      List.filteri (fun index _ -> index < body_rows) drawn
  in
  Masc_tui_frame_timing.finish_stage ~name:"surface.body" body_started;
  let pane_started = Masc_tui_frame_timing.start_stage () in
  (* [cols] is what the surface laid out against: the terminal less the
     Activity pane when the pane shows. The body shares its rows with the
     pane; the agenda, the composer, and the strip span the whole terminal,
     the way an editor's side bar stops above the command line. *)
  let pane_cols = !acting_pane_reserved_cols in
  let full_cols = cols + pane_cols in
  let framed = Buffer.create (Buffer.length buf + 256) in
  add_rows_beside_acting_pane state framed ~cols ~pane_rows:body_rows body;
  frame_panes :=
    Masc_tui_pane_selection.frame_layout ~first_row:(strip_rows + 1)
      ~body_rows ~main_cols:cols ~activity_cols:pane_cols ~roster:None;
  Masc_tui_frame_timing.finish_stage ~name:"surface.panes" pane_started;
  let chrome_started = Masc_tui_frame_timing.start_stage () in
  (if agenda_rows > 0 then
     match agenda_line (Masc_tui_types.agenda state)
       ~ko:(state.ui_language = Lang_ko) ~cols:full_cols with
     | Some line -> Buffer.add_string framed (line ^ "\n")
     | None -> ());
  let composer, cursor =
    if state.keeper_navigation_open then ("", Frame_presenter.Hidden)
    else composer_row state ~rows ~cols:full_cols in
  Buffer.add_string framed (composer ^ "\n");
  Masc_tui_frame_timing.finish_stage ~name:"surface.chrome" chrome_started;
  Masc_tui_frame_timing.time_stage ~name:"surface.strip_frame" (fun () ->
    finish_frame_with_strip state ?clamped ~surface_key
      ~cursor ~rows ~cols:full_cols framed)


(* The footer a frame beside the Activity pane ends with. [No_footer] is for
   the chat's notice that the terminal cannot hold it, which is that frame's
   last row instead. *)
type acting_pane_footer =
  | Footer_hints of { hints : string; position : string option }
  | Footer_choices of { choices : string; hints : string }
  | No_footer

(* The end of a surface that draws its own composer and footer -- the Keeper
   chat, the Board composer -- instead of taking the shared composer row. It
   laid out against the same [cols] every surface does, the terminal less the
   Activity pane, so the pane is drawn in those columns here too, beside the
   rows above its own footer. The strip
   spans the whole terminal. [roster] is the Keeper roster the chat drew at
   its left edge, a pane of its own for a drag.

   The footer is drawn here rather than by each frame, because these frames
   draw no agenda row: an open question would otherwise be on screen nowhere
   while the operator chats, which is where a Keeper's question goes unseen. *)
let finish_frame_beside_acting_pane (state : state) ?clamped ?roster ?(recovery_in_slot = None)
    ?help_door
    ~surface_key ~cursor ~rows ~cols ~footer buf =
  (match footer with
   | No_footer -> ()
   | Footer_hints { hints; position } ->
       Buffer.add_string buf
         (footer_line ?help_door ?position ~recovery_in_slot state ~max_cells:cols ~hints)
   | Footer_choices { choices; hints } ->
       Buffer.add_string buf
         (footer_line ?help_door ~choices ~recovery_in_slot state ~max_cells:cols ~hints));
  let framed = Buffer.create (Buffer.length buf + 4096) in
  let lines = frame_lines buf in
  (* These frames draw neither the shared composer nor the agenda. Only
     their final footer stays below the pane; use the actual drawn height. *)
  let pane_rows = max 0 (min (rows - 1) (List.length lines - 1)) in
  add_rows_beside_acting_pane state framed ~cols ~pane_rows lines;
  frame_panes :=
    Masc_tui_pane_selection.frame_layout ~first_row:(strip_rows + 1)
      ~body_rows:pane_rows ~main_cols:cols
      ~activity_cols:!acting_pane_reserved_cols ~roster;
  finish_frame_with_strip state ?clamped ~surface_key ~cursor ~rows
    ~cols:(cols + !acting_pane_reserved_cols) framed


(* Exhaustive over [connection_status]: a new state is a compile error
   here rather than an unexplained [disconnected] on screen. *)
(* ── the A-family surface chrome contract ─────────────────────────────
   One owner for the fixed rows of a surface, or of an overlay drawn over
   one: top, title row, divider, height fill, bottom, and the status-tail
   footer. The body
   pushes its rows through the record and the contract counts them, so the
   hand-tallied chrome_rows constants (the fixed-chrome-row trap: add a row,
   forget the count, lose a body line) cannot drift — there is nothing left
   to tally by hand. Surfaces keep composing their own title (screen_title
   plus whatever meta) and hints; the contract owns geometry only. *)

type chrome_body = {
  push : string -> unit;
  push_styled : style:string -> string -> unit;
  push_selected : string -> unit;
  push_divider : unit -> unit;
  push_empty : unit -> unit;
  next_origin : unit -> int * int;
      (** The terminal frame's line and cell where the next pushed row's
          content will start -- where a picture placed over body rows goes.
          Holds while the body stays inside its budget, which a [Fits] body
          does. *)
}

(* top + title + divider + bottom + footer: the rows [surface_chrome] draws
   itself. Everything else is the body's budget. The framed panels count the
   same five rows, and a key handler bounding an overlay's scroll with
   [framed_content_height] must agree with what this draws, so the number has
   one owner. *)
let surface_chrome_rows = framed_chrome_rows

let surface_chrome_budget state ~terminal_rows =
  max 1
    (Masc_tui_types.surface_body_rows state ~terminal_rows
    - surface_chrome_rows)

(* Which frame the contract draws. A surface is the terminal's whole screen and
   its edge is already the frame, so it draws rules and no box. An overlay is
   opened over a surface and keeps its box, which is how a reader tells the two
   apart. The rows around the body are five either way, so the budget is the
   same. *)
type chrome_frame = Chrome_screen | Chrome_overlay

(* What a body does with rows past its budget, said at the call rather than
   left to a default. An optional clamp cost nothing to leave out, so a body
   that fits, a body the keypress windows and a body that was silently losing
   its tail all read the same at the call (#35716). *)
type overflow =
  | Fits
  | Paged_by_cursor
  | Scrolled of { scroll : int; report : int -> clamped_scroll }
  | Self_scrolled of (unit -> clamped_scroll)

(* The window a [Scrolled] body gets out of [count] rows: the budget, less the
   position row when they overflow. The key handler that bounds the scroll and
   the frame that draws it both ask this. *)
let surface_window_height state ~terminal_rows ~count =
  Masc_tui_scroll.content_height
    ~rows:(Masc_tui_types.surface_body_rows state ~terminal_rows)
    ~chrome:surface_chrome_rows ~count ~preview_keep:None
    ~overflow_takes_row:true

let surface_chrome ~overflow ?help_door ?(frame = Chrome_screen) ?status ?sidebar (state : state)
    ~terminal_rows ~cols ~surface_key ~title ~hints
    ~(body : budget:int -> chrome_body -> unit) =
  let setup_started = Masc_tui_frame_timing.start_stage () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let full_cols = cols in
  let sidebar_cols = match sidebar with None -> 0 | Some (width, _) -> width in
  let cols = cols - sidebar_cols in
  (* Measure the row after the sidebar reservation, using the width actually
     available to each kind of bottom row. The same choice also controls the
     footer, so an unfitted notice keeps the existing fallback. *)
  let recovery_in_slot =
    let max_cells = match frame with
      | Chrome_overlay -> framed_rule_width cols
      | Chrome_screen -> framed_inner_width cols in
    recovery_slot state ~max_cells in
  let buf = Buffer.create 4096 in
  let top, line, line_styled, line_selected, divider, empty, bottom =
    match frame with
    | Chrome_screen ->
        ( box_top, box_line, box_line_styled, box_line_selected, box_divider
        , box_empty, box_bottom )
    | Chrome_overlay ->
        ( framed_top
        , framed_line
        , framed_line_styled
        , (fun buf cols content ->
            framed_line_styled buf cols ~style:Masc_tui_theme.selection content)
        , framed_divider
        , framed_empty
        , framed_bottom )
  in
  top buf cols;
  line buf cols title;
  divider buf cols;
  (* The lines drawn above the body, counted from what was drawn rather than
     by hand, and the strip [finish_surface] puts above them. *)
  let body_top = strip_rows + lines_ended_since buf ~start:0 in
  let budget = max 1 (rows - surface_chrome_rows) in
  (* The body's rows are held until it has finished, because only then is
     their count known: which of them the budget shows, and what the row that
     says so reads, are the contract's to work out, not the body's. *)
  let pushed = ref [] in
  let hold draw = pushed := draw :: !pushed in
  let body_pushers =
    { push = (fun text -> hold (fun () -> line buf cols text))
    ; push_styled =
        (fun ~style text -> hold (fun () -> line_styled buf cols ~style text))
    ; push_selected = (fun text -> hold (fun () -> line_selected buf cols text))
    ; push_divider = (fun () -> hold (fun () -> divider buf cols))
    ; push_empty = (fun () -> hold (fun () -> empty buf cols))
    ; next_origin =
        (fun () -> (body_top + List.length !pushed,
                    sidebar_cols + Masc_tui_ansi.framed_content_column))
    }
  in
  Masc_tui_frame_timing.finish_stage ~name:"surface.setup" setup_started;
  let content_started = Masc_tui_frame_timing.start_stage () in
  body ~budget body_pushers;
  Masc_tui_frame_timing.finish_stage ~name:"surface.content" content_started;
  let materialize_started = Masc_tui_frame_timing.start_stage () in
  let held = List.rev !pushed in
  let count = List.length held in
  (* No row is drawn past the budget: one more shoves the bottom rule and the
     footer off the screen. *)
  let used = ref 0 in
  let draw_row draw =
    if !used < budget then begin incr used; draw () end
  in
  let draw_note text =
    draw_row (fun () -> line_styled buf cols ~style:(Theme.recede ()) text)
  in
  (* A body that came out taller than its budget keeps its head and says how
     much of its tail the screen could not hold. Cut without the note, the
     missing rows did not exist for the reader. *)
  let draw_cut () =
    if count <= budget then List.iter draw_row held
    else begin
      List.iteri (fun index draw -> if index < budget - 1 then draw_row draw) held;
      let hidden = count - (budget - 1) in
      draw_note
        (Printf.sprintf "  +%d %s not shown" hidden
           (if hidden = 1 then "row" else "rows"))
    end
  in
  let clamped =
    match overflow with
    | Fits | Paged_by_cursor -> draw_cut (); None
    | Self_scrolled read ->
        draw_cut ();
        (* Read after the body, because that is the only moment the value
           exists: a body that windows part of itself cannot say what it
           clamped to before it has drawn. *)
        Some (read ())
    | Scrolled { scroll; report } ->
        let height = surface_window_height state ~terminal_rows ~count in
        let scroll = Masc_tui_scroll.normalize ~count ~height scroll in
        List.iteri
          (fun index draw ->
            if index >= scroll && index < scroll + height then draw_row draw)
          held;
        Option.iter draw_note
          (Masc_tui_scroll.position_row ~ko:(state.ui_language = Lang_ko) ~scroll ~height count);
        Some (report scroll)
  in
  for _ = !used + 1 to budget do
    empty buf cols
  done;
  (match recovery_in_slot, frame with
   | selected, Chrome_screen -> draw_box_bottom_with_recovery buf ~cols selected
   | None, Chrome_overlay -> bottom buf cols
   | Some row, Chrome_overlay ->
       let text = row.recovery_text in
       let remaining = max 0 (framed_rule_width cols - Message_layout.display_width text) in
       let edge = Theme.recede () in
       Buffer.add_string buf
         (edge ^ Ansi.box_bl ^ Ansi.reset ^ Theme.warn () ^ text ^ Ansi.reset
          ^ edge ^ draw_hline remaining ^ Ansi.box_br ^ Ansi.reset ^ "\n"));
  let buf = match sidebar with
    | None -> buf
    | Some (left_cols, draw) ->
        let left = Buffer.create 1024 in
        draw ~rows:(lines_ended_since buf ~start:0) left;
        let combined = Buffer.create (Buffer.length left + Buffer.length buf) in
        write_two_panes combined ~left_cols ~left ~right:buf;
        combined
  in
  Buffer.add_string buf
    (footer_line ?help_door ?status ~recovery_in_slot
       state ~max_cells:full_cols ~hints);
  Masc_tui_frame_timing.finish_stage ~name:"surface.materialize" materialize_started;
  finish_surface state ?clamped ~surface_key ~rows:terminal_rows ~cols:full_cols buf


(* What the reads under way and the reads that failed have to say, one piece
   each. The connection itself and the workspace it serves are on the top row
   ([strip_connection_reading]); these are the particulars behind its word. *)
let refresh_progress_pieces (state : state) =
  let ko = state.ui_language = Lang_ko in
  let text = ui_text state in
  let surface_name source = if not ko then Surface_read_order.source_name source else
    match source with
    | Surface_read_source.Transport -> "연결" | Board -> "게시판" | Planning -> "목표·작업"
    | Runtime_quota -> "제공자 한도" | Keeper_usage -> "Keeper 사용량"
    | Provider_history -> "제공자 기록" | Overview_goals -> "목표"
    | Account_emails -> "계정" | Tool_series -> "도구 호출" in
  let source_name source = if not ko then Http_refresh_progress.source_name source else
    match source with
    | Http_refresh_progress.Identity_before -> workspace_name ~ko
    | Approvals -> "승인" | Questions -> "질문" | Keepers -> "Keeper"
    | Surface_data source -> surface_name source
    | Identity_after -> workspace_name ~ko ^ " 확인" in
  let component_name component = if not ko then Http_refresh_progress.component_name component else
    match component with
    | Http_refresh_progress.Runtime_catalogue -> "런타임 목록" | Provider_windows -> "제공자 한도"
    | Board_posts -> "게시글" | Board_hearths -> "하위 게시판"
    | Keeper_roster -> "Keeper 목록" | Keeper_candle -> "Candle" in
  let component_outcome outcome = if not ko then Http_refresh_progress.component_outcome_name outcome else
    match outcome with
    | Http_refresh_progress.Component_returned Part_received -> "관측됨"
    | Component_returned Part_failed | Component_exception -> "조회 실패"
    | Component_interrupted -> "조회 중단" | Component_unfinished -> "조회 미완료" in
  let foreground =
    match surface_reads_pending state with
    | [] -> []
    | source :: rest ->
        [ text ~ko:"조회 중: " ~en:"reading " ^ surface_name source
          ^ (match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest)) ]
  in
  match state.http_refresh_progress with
  | Some (authority, progress) when authority = state.workspace_authority ->
      let outcome_notice completion label =
        match Http_refresh_progress.settled_sources ~completion progress with
        | [] -> []
        | source :: rest ->
            [ source_name source ^ " " ^ label
              ^ (match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest)) ] in
      let partials = match Http_refresh_progress.partial_readings progress with
        | [] -> []
        | (_,parts) :: rest ->
            let names outcome = Http_refresh_progress.components parts
              |> List.filter_map (fun (component,observed) -> if observed=outcome
                then Some (component_name component) else None)
              |> String.concat ", " in
            [ text ~ko:"일부 관측: " ~en:"partial: " ^ names Http_refresh_progress.Part_failed
              ^ text ~ko:" 조회 실패; " ~en:" failed; "
              ^ names Http_refresh_progress.Part_received ^ text ~ko:" 관측됨" ~en:" received"
              ^ (match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest)) ] in
      let notices = outcome_notice Http_refresh_progress.Failed_read (text ~ko:"조회 실패" ~en:"read failed")
        @ outcome_notice Http_refresh_progress.Interrupted_read (text ~ko:"조회 중단" ~en:"interrupted") @ partials in
      let component_reads = Http_refresh_progress.unreturned_component_reads progress in
      let component_notices = component_reads |> List.filter_map (fun part ->
        match part.Http_refresh_progress.cr_status with
        | Http_refresh_progress.Component_pending -> None
        | Http_refresh_progress.Component_settled (_,outcome) ->
            Some (component_name part.cr_component ^ " "
              ^ component_outcome outcome)) |> String.concat "; " in
      let notices = notices @ (if component_notices="" then [] else [ component_notices ]) in
      (match progress.Http_refresh_progress.phase with
       | Http_refresh_progress.Finished _ -> notices @ foreground
       | Http_refresh_progress.In_flight ->
           if foreground <> [] then notices @ foreground else
           let pending_components = List.filter (fun part ->
             match part.Http_refresh_progress.cr_status with
             | Http_refresh_progress.Component_pending -> true
             | Http_refresh_progress.Component_settled _ -> false) component_reads in
           let pending = match pending_components with
             | part :: rest -> text ~ko:"조회 중: " ~en:"reading " ^ component_name part.cr_component
                 ^ (match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest))
             | [] -> (match Http_refresh_progress.pending_sources progress with
                 | [] -> (match progress.Http_refresh_progress.readings with
                     | [] -> text ~ko:"새로 조회 중" ~en:"refreshing"
                     | _ :: _ -> text ~ko:"조회 마무리 중" ~en:"finishing refresh")
                 | source :: rest -> text ~ko:"조회 중: " ~en:"reading " ^ source_name source
                     ^ (match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest))) in
           notices @ [ pending ])
  | Some _ | None -> foreground

let reading_separator = " \xc2\xb7 "

let refresh_progress_badge (state : state) =
  String.concat reading_separator (refresh_progress_pieces state)

let observer_loss_badge (state : state) =
  if state.observer_source_loss then
    Some (Theme.warn () ^ ui_text state ~ko:"[이벤트 유실]" ~en:"[events lost]" ^ Ansi.reset)
  else None

(* What a title row adds to the top row's one word: that the event feed lost
   events, and which reads are under way or failed. Empty while the feed is
   whole and nothing is being read -- the title then ends with its own
   readings, and "connected" is said once, above. *)
let connection_badge (state : state) =
  String.concat reading_separator
    (Option.to_list (observer_loss_badge state) @ refresh_progress_pieces state)

let reading_connection_notice (state : state) =
  let exceptional =
    state.observer_source_loss
    || match compact_connection_state state with
       | Compact_http Connected | Compact_reading -> false
       | Compact_workspace_mismatch | Compact_workspace_unconfirmed
       | Compact_workspace_unread | Compact_read_failed | Compact_read_partial
       | Compact_read_interrupted | Compact_read_unfinished
       | Compact_http (Degraded | Connecting | Booting | Disconnected) -> true
  in
  if exceptional then
    match connection_badge state with
    | "" -> None
    | particulars -> Some particulars
  else None

(* A narrow Usage title keeps a textual state visible while its longer
   workspace and refresh details remain available in the scrolled body. *)
let compact_connection_badge (state : state) ~width =
  let ko = state.ui_language = Lang_ko in
  let choose options =
    match List.find_opt (fun (label, _) -> Message_layout.display_width label <= width) options with
    | Some choice -> choice
    | None -> List.hd (List.rev options)
  in
  let style, options, needs_context =
    compact_connection_wording ~ko (compact_connection_state state) in
  let label, needs_full_status = choose options in
  let details =
    if needs_context || needs_full_status then connection_badge state
    else refresh_progress_badge state in
  style ^ label ^ Ansi.reset, (if String.equal details "" then None else Some details)

let reading_connection_summary ~width state =
  let compact width = fst (compact_connection_badge state ~width:(max 0 width)) in
  let summary =
    if not state.observer_source_loss then compact width
    else
      let gap label =
        let separator = " · " in
        let remaining = width - Message_layout.display_width (label ^ separator) in
        Theme.warn () ^ label ^ Ansi.reset ^ separator ^ compact remaining
      in
      let full = gap (ui_text state ~ko:"이벤트 유실" ~en:"events lost") in
      if Message_layout.display_width full <= width then full
      else gap (ui_text state ~ko:"유실" ~en:"gap")
  in
  fit_width summary (max 0 width)

(* The particulars can exceed the title's width. The feed's loss is kept
   whole ahead of the reads, and the ellipsis says the rest was left out. *)
let surface_connection_badge (state : state) ~width =
  let cells text = Message_layout.display_width (Masc_tui_theme.strip_sgr text) in
  let full = connection_badge state in
  if cells full <= width then full
  else if width < 1 then ""
  else
    let omitted = " \xe2\x80\xa6" in
    let room = width - cells omitted in
    let warning = Theme.warn () ^ "!" ^ Ansi.reset in
    match observer_loss_badge state with
    | Some loss when cells loss <= room -> loss ^ omitted
    | Some _ | None -> if room < 1 then warning else String.trim omitted

(* The row under the top row: where this screen is -- the top-row screen it
   belongs to, then each step taken into it -- then what the screen has to
   say about its own reading, and how far down it the reader is. One function
   draws it so that a path, a count and a position look the same on every
   screen that has them (RFC tui-one-screen-grammar, section 2). The product
   name is not part of a place and is not drawn.

   The last step is the one that folds when the row is narrow: it is the id
   of the thing being read, and the steps before it are how to get back. *)
let here_step_separator = " \xe2\x80\xba "

(* The cells kept clear ahead of the position. *)
let here_position_gap_cells = 2

(* The top-row screen the current one belongs to, by the name the top row
   draws for it. *)
let here_screen_name (state : state) =
  let index = Masc_tui_surface_navigation.surface_ring_index state.view in
  match List.nth_opt Masc_tui_types.surface_ring index with
  | Some (surface, name) ->
      Masc_tui_types.surface_ring_display_label ~lang:state.ui_language surface name
  | None -> ""

(* The path alone, every step drawn whole: for a row that lays out what
   follows the path itself. *)
let here_path (state : state) ~path =
  let step text = Ansi.dim ^ here_step_separator ^ Ansi.reset ^ text in
  screen_title (" " ^ here_screen_name state)
  ^ String.concat "" (List.map step path)

(* The steps ahead of the last one, in the cells the row has for them. A
   step the row cannot hold whole is folded in the middle, the longest first
   and none below [heading_id_floor], so a long keeper name or lane label
   keeps both its ends and the step after it stays on the row. Without this
   the lead was cut at its end: the name lost its tail and the last step --
   which view of that keeper this is -- went with it. A step that carries a
   style of its own is left as given. *)
let fit_here_steps ~cells:room steps =
  let cells text = Message_layout.display_width (Masc_tui_theme.strip_sgr text) in
  let foldable step =
    (not (String.contains step '\027')) && cells step > heading_id_floor
  in
  let rec shrink steps over =
    let longest =
      List.fold_left
        (fun widest step -> if foldable step then max widest (cells step) else widest)
        0 steps
    in
    if over <= 0 || longest = 0 then steps
    else
      let cut = min over (longest - heading_id_floor) in
      let rec fold_first = function
        | [] -> []
        | step :: rest when foldable step && cells step = longest ->
            Message_layout.truncate_middle (longest - cut) step :: rest
        | step :: rest -> step :: fold_first rest
      in
      shrink (fold_first steps) (over - cut)
  in
  shrink steps (List.fold_left (fun sum step -> sum + cells step) 0 steps - room)

(* A count and what it counts, in the screen's language. *)
let count_reading (state : state) noun count =
  Masc_tui_value.Count.reading ~ko:(state.ui_language = Lang_ko) noun count

(* The cells the steps of a path share on a row [cols] wide: what the screen
   name, one separator a step, and the [after] cells the row must keep leave. *)
let here_steps_room ~cols (state : state) ~steps ~after =
  let cells text = Message_layout.display_width (Masc_tui_theme.strip_sgr text) in
  framed_inner_width cols
  - cells (here_path state ~path:[])
  - (steps * cells here_step_separator)
  - after

let here_row ~cols (state : state) ~path ~readings ~position =
  (* Every step is text to read, and a step may be a string the server sent:
     a keeper name, a run id, a lane label. The last one becomes the title's
     id, which the title makes printable; the steps ahead of it reach the row
     as given. Left to each caller, the keeper calls row forgot one. A step
     that needs a style of its own is drawn with [here_path], by a caller
     that lays out its own row. *)
  let path = List.map Terminal_text.single_line path in
  let position =
    Option.map
      (fun position ->
        Ansi.dim
        ^ Masc_tui_value.Position.text
            ~whole:(ui_text state ~ko:"전체" ~en:"of") position
        ^ Ansi.reset)
      position
  in
  let cells text = Message_layout.display_width (Masc_tui_theme.strip_sgr text) in
  (* The position ends the row: the path and the readings are laid out in the
     cells left of it, then padded, so it keeps its column whatever the path
     says. *)
  let position_cells =
    match position with
    | Some text -> cells text + here_position_gap_cells
    | None -> 0
  in
  let left_cols = cols - position_cells in
  (* Reads come and go with every refresh, and a row that changed with them
     would never sit still. Each screen says what it is still reading in its
     own body; the row speaks up only for what went wrong. *)
  let tail =
    match reading_connection_notice state with
    | None -> ""
    | Some _ ->
        surface_connection_badge state
          ~width:(max 0 (framed_inner_width left_cols - 2))
  in
  let lead, id =
    match List.rev path with
    | [] -> here_path state ~path:[], ""
    | last :: before ->
        let before = List.rev before in
        (* The last step keeps its floor and the tail its cells, gap
           included; the steps ahead of them share the rest. Counted without
           the tail's gap, the steps took two cells too many and the last
           step was cut to its mark: "logs" drew as an ellipsis. *)
        let room =
          here_steps_room ~cols:left_cols state
            ~steps:(List.length before + 1)
            ~after:
              (min (cells last) heading_id_floor
               + cells (heading_tail_gap ^ tail))
        in
        ( here_path state ~path:(fit_here_steps ~cells:room before)
          ^ Ansi.dim ^ here_step_separator ^ Ansi.reset,
          last )
  in
  let left =
    detail_heading ~cols:left_cols ~lead:(Lead_text lead) ~id
      ~after:
        (* One gap ahead of the first reading, one mark between readings, and
           an empty reading takes no room. *)
        (List.filter (fun reading -> reading <> "") readings
         |> List.mapi (fun index reading ->
                (if index = 0 then "  " else reading_separator) ^ reading))
      ~tail
  in
  match position with
  | None -> left
  | Some position ->
      left
      ^ String.make
          (max here_position_gap_cells
             (framed_inner_width cols - cells left - cells position))
          ' '
      ^ position

(* The step the Runtime screens take from System, and a keeper's runtime
   takes from that keeper. *)
let runtime_step (state : state) = ui_text state ~ko:"런타임" ~en:"runtime"

(* The coordinator's badge beside a reading of the surface's own. The badge
   brings its colour and its reset, so a style laid over the whole row painted
   only the words in front of it -- "coordinator HTTP" went red beside a green
   [connected] when a browser read failed -- and the reset left the failure
   itself uncoloured. Each part wears its colour where it stands. *)
let coordinator_status_row (state : state) ~style status =
  "  coordinator " ^ connection_badge state ^ "  " ^ style ^ status ^ Ansi.reset


(* The rows a buffer holds. A surface that lays a block out against a height
   declared beside the drawing loses whatever the two disagree by: the ask
   section drew its header into the one row left over and pushed every
   question off-screen, and the Approvals surface spent its Gate lane rows
   twice and left its footer floating two rows above the composer. Reading the
   height back off the buffer is what the surfaces use instead.

   A last line with no newline after it is a row: the terminal draws it, and a
   footer is written that way. Counting newlines alone was a second reading of
   this one question, off by that row, and the two lived under two names. *)
let count_frame_lines buf =
  let len = Buffer.length buf in
  if len = 0 then 0
  else
    let n = ref 0 in
    for i = 0 to len - 1 do
      if Buffer.nth buf i = '\n' then incr n
    done;
    if Buffer.nth buf (len - 1) = '\n' then !n
    else !n + 1


(* Resolve navigation visibility and the explicit choice before applying the terminal's
   width constraint; resizing never overwrites the reader's preference. *)
let keeper_roster_pane_shown (state : state) ~cols =
  Masc_tui_roster_pane.shown ~hidden:(roster_pane_hidden state) ~cols


(** Render the keeper list view *)
(* Status is shown as a glyph and a word. The glyph is the coarse reading an
   operator scans a column for -- a fiber running, a fiber sleeping, no fiber,
   nothing observed -- and the word next to it is the exact published status,
   so the column stays legible at four shapes instead of needing a distinct
   glyph per label. *)
(* The colour reinforces the runtime's suggested action; the selected Keeper
   also names that action in text, including when colours are unavailable.
   Pause, health and lifecycle remain separate readings. *)
let keeper_action_color
    (action : Status.keeper_next_action_path option) =
  match action with
  | None -> Ansi.dim
  | Some Status.Recover -> (Theme.warn ())
  | Some Status.Probe -> Theme.action_probe ()
  (* Green until this measurement. The cell draws its readings in separate
     channels and this is the only one carried by colour alone, so the three
     action colours have to stay apart for a reader who cannot separate red
     from green -- roughly one man in twelve.

     Simulated (Machado 2009, severity 1.0) over the twelve base16 schemes the
     contrast harness measures, the closest pair was not red against green but
     [Recover] against [Direct_message] -- yellow and green both arrive
     yellowish -- at 0.015 in Oklab. Magenta is the only candidate that
     improves every reading rather than trading one for another: 0.070 to
     0.121 for ordinary vision, 0.015 to 0.044 for deuteranopia, 0.019 to
     0.027 for protanopia. Blue and white came out worse than green even for
     ordinary vision, because they close on [Probe]'s cyan. *)
  | Some Status.Direct_message -> Theme.action_message ()

(* Preserve what was actually observed: a runtime that names no action is not
   evidence that nothing needs doing, and an unread roster is not absence. *)
let keeper_suggested_action ~ko reading =
  let say korean english = if ko then korean else english in
  match reading.Keeper_control.liveness with
  | Keeper_control.Unobserved | Keeper_control.Invalid _ | Keeper_control.Absent ->
      Keeper_control.health_label ~ko reading
  | Keeper_control.Present runtime ->
      match runtime.kr_next_action with
      | None -> say "보고 없음" "not reported"
      | Some Status.Recover -> say "복구" "recover"
      | Some Status.Probe -> say "점검" "probe"
      | Some Status.Direct_message -> say "직접 메시지" "direct message"


let keeper_state_glyph ~paused ~(health : Tui_decode.keeper_health option) =
  Masc_tui_keeper_mark.glyph ~paused
    (Option.map Tui_decode.keeper_health_reading health)


(* Runtime ids are opaque identifiers, so a fixed-width surface keeps both
   ends instead of sacrificing the distinguishing tail to a shared prefix.
   Returning the unpadded id when it already fits lets a chat header spend the
   remaining cells on context instead of blank padding. *)
let fit_runtime_id width runtime_id =
  Message_layout.truncate_middle width runtime_id


(* Keeper and document indexes share one quiet edge. The row, including its
   padding, owns its background and selection; the separator never reverses. *)
let sidebar_line ?(style = "") buf ~cols text =
  Buffer.add_string buf
    (Theme.side_pane_background () ^ style ^ fit_width text (max 0 (cols - 1))
     ^ Ansi.reset ^ Theme.recede () ^ "│" ^ Ansi.reset ^ "\n")

let sidebar_rule ~cols = "  " ^ draw_hline (max 0 (cols - 5)) ^ "  "

let sidebar_heading ~cols ~title ~count =
  let title = "  " ^ Terminal_text.single_line title in
  let count = Terminal_text.single_line count in
  let count_cells = Message_layout.display_width count in
  let title_cells = max 0 (cols - 1 - count_cells - 3) in
  fit_width title title_cells ^ " " ^ count ^ "  "

(* A quiet rail beside the conversation. Only the cursor row gets a band when
   this pane owns the keys; the selected Keeper's readings sit below the list.
   [rows] includes the caller's footer, as it does for the detail/chat panes. *)
let keeper_roster_pane ?(focused = false) (state : state) ~rows ~cols buf =
  let height = max 0 (rows - 1) in
  let inner = max 0 (cols - 1) in
  let ground = Theme.side_pane_background () in
  let restore = Ansi.reset ^ ground in
  let draw ?style text = sidebar_line ?style buf ~cols text in
  let rule = sidebar_rule ~cols in
  let selected = selected_keeper state in
  let action =
    Option.fold ~none:[]
      ~some:
      (fun keeper ->
        let indent = if inner >= 3 then "  " else "" in
        Message_layout.wrap_words ~max_cells:(max 1 (inner - String.length indent))
          (ui_text state ~ko:"고른 Keeper 의 다음: " ~en:"Selected next: "
           ^ keeper_suggested_action ~ko:(state.ui_language = Lang_ko)
               (keeper_reading state keeper))
        |> List.map (fun line -> "", indent ^ line))
      selected
  in
  let details =
    if not focused then []
    else match selected with
      | None -> []
      | Some keeper ->
          let reading = keeper_reading state keeper in
          let ko = state.ui_language = Lang_ko in
          let status = Keeper_control.status_label ~ko reading in
          let runtime = match reading.liveness with
            | Keeper_control.Present runtime -> runtime.kr_runtime_id
            | Unobserved | Absent | Invalid _ ->
                if ko then "런타임 확인 불가" else "Runtime unavailable"
          in
          let label =
            if state.view = Keepers Keeper_message
               && state.msg_target_keeper_name = Some keeper.k_name
            then (if ko then "현재 대화" else "Current conversation")
            else (if ko then "선택한 키퍼" else "Selected Keeper")
          in
          [ Theme.recede (), rule
          ; Theme.recede (), "  " ^ label
          ; Ansi.bold, "  " ^ Message_layout.fit_middle (max 0 (inner - 4))
              (Terminal_text.single_line keeper.k_name)
          ; "", "  " ^ keeper_action_color (Keeper_control.next_action reading)
              ^ keeper_state_glyph ~paused:reading.paused
                  ~health:(Keeper_control.health reading)
              ^ restore ^ " " ^ Theme.recede () ^ status
          ; Theme.recede (), "  " ^ fit_runtime_id (max 0 (inner - 4))
              (Terminal_text.single_line runtime)
          ]
  in
  let header_rows = min 3 height in
  let available = height - header_rows in
  let count = List.length state.keepers in
  (* Supplementary details get no more rows than the list keeps, unless the
     entire fleet already fits beside them. Short viewports favor the list. *)
  let detail_rows = List.length details in
  let details =
    if available >= detail_rows + min count detail_rows then details else []
  in
  (* Decide the existing detail block first. When the action needs more room,
     drop its separator and heading before any name, health or runtime. *)
  let list_minimum = if count > 0 then 1 else 0 in
  let fits_action details =
    available - List.length details >= List.length action + list_minimum
  in
  let details, action =
    match action with
    | [] -> details, []
    | _ when fits_action details -> details, action
    | _ ->
        (match details with
         | _rule :: rest when fits_action rest -> rest, action
         | _rule :: _heading :: rest when fits_action rest -> rest, action
         | _ -> details, [])
  in
  let capacity = available - List.length details - List.length action in
  let first = max 0 (min (state.keeper_cursor - capacity + 1) (count - capacity)) in
  let window = Rows.of_list ~first ~height:capacity state.keepers in
  let count_label =
    if count > capacity && capacity > 0 then
      Printf.sprintf "%d–%d/%d" (first + 1) (first + Rows.length window) count
    else string_of_int count
  in
  let header = [ ""; sidebar_heading ~cols ~title:"KEEPERS" ~count:count_label; rule ] in
  List.iter (draw ~style:(Theme.recede ())) (List.take header_rows header);
  for i = 0 to capacity - 1 do
    match Rows.at window (first + i) with
    | Some (keeper : keeper) ->
        let selected = first + i = state.keeper_cursor in
        let name = Masc_tui_roster_pane.name_window ~selected
          ~frame:state.roster_marquee_frame ~width:(max 0 (cols - 7))
          (Terminal_text.single_line keeper.k_name) in
        let reading = keeper_reading state keeper in
        let glyph = keeper_state_glyph ~paused:reading.paused
          ~health:(Keeper_control.health reading) in
        if selected && focused then
          draw ~style:(Theme.sidebar_selection ()) (" › " ^ glyph ^ " " ^ name ^ " ")
        else
          let caret = if selected then " › " else "   " in
          draw (caret ^ keeper_action_color (Keeper_control.next_action reading)
                ^ glyph ^ restore ^ " "
                ^ name ^ restore ^ " ")
    | None when i = 0 && count = 0 ->
        draw ~style:(Theme.recede ())
          (match state.keeper_roster_error with
           | Some error -> "  " ^ Terminal_text.single_line error
           | None -> "  No Keepers listed")
    | None -> draw ""
  done;
  List.iter (fun (style, text) -> draw ~style text) details;
  List.iter (fun (style, text) -> draw ~style text) action


(* What a boxed listing draws under its rows: the scroll line -- a row whether
   or not there is anything to report, so a list that overflows does not push
   the help line off the bottom -- then the frame's bottom, then the footer.

   Named once because three surfaces were tallying their whole chrome by hand,
   and being one row over the budget is not a visible mistake: [finish_surface]
   drops the last rows, and the last row is the footer. *)
let listing_rows_below_the_body = 3

;;

(* A narrow list beside an open detail: which row you are on, and what else
   is there. Only the label -- the columns a full list carries do not fit
   thirty cells, and a truncated author reads as a different author.

   [selection] indexes [labels]; the pane scrolls to keep that row drawn.
   [None] draws no row as selected.
   [focused] says whether the arrow keys are pointed here, which is a
   different question from which row is open. *)
(* What a row draws before its label when the cursor is on it. The fold below
   measures this instead of counting its cells here, so the two cannot drift
   apart, and the mark is the one the rest of the file draws rather than a
   second spelling of its bytes. *)
let sidebar_caret_lead = " " ^ Masc_tui_theme.Glyph.current_entry ^ " "

(* Every row folds to the room the widest lead leaves, so the fold does not
   move when the cursor does. *)
let sidebar_row_lead_cells = Message_layout.display_width sidebar_caret_lead

(* How many rows an index is holding, and how many the surface holds. Three
   surfaces draw a server page beside a detail -- the Board's fifty posts,
   the Schedules page, the Task Review page -- and each one's index said the
   page size alone: a board of a hundred and seven posts drew "(50)" with no
   second number anywhere near it, so the fifty-seven the page does not carry
   were invisible. Equal counts say it once: a page that carries everything
   has no difference to report. *)
let list_count_text ~loaded ~holding =
  match holding with
  | Some holding when holding > loaded ->
      Printf.sprintf "(%s of %s)" (Masc_tui_value.Count.grouped loaded)
        (Masc_tui_value.Count.grouped holding)
  | Some _ | None -> Printf.sprintf "(%s)" (Masc_tui_value.Count.grouped loaded)

(* [holding] is what the surface holds when that is more than this index was
   given: the Board's own header reads "(50 of 198)" one keypress away, and
   this row read "(50)", which is a count of the whole board to anyone who
   did not just come from that header. Both spell it through
   [list_count_text], so the two cannot disagree.

   Asked of every caller rather than defaulted: a list that is filtered
   rather than paged has nothing more to hold, and passing [None] says so
   where leaving it out could not be told from forgetting. *)
let write_list_sidebar_selection buf ~rows ~cols ~title ~focused ~holding
    ~labels ~selection =
  let draw ?style text = sidebar_line ?style buf ~cols text in
  draw "";
  draw ~style:(Theme.recede ())
    (sidebar_heading ~cols ~title
       ~count:(list_count_text ~loaded:(List.length labels) ~holding));
  draw ~style:(Theme.recede ()) (sidebar_rule ~cols);
  let content_height = max 0 (rows - framed_chrome_rows) in
  let first =
    match selection with
    | Some selected when selected >= content_height ->
        selected - content_height + 1
    | Some _ | None -> 0
  in
  let labels_window = Rows.of_list ~first:first ~height:content_height labels in
  for i = 0 to content_height - 1 do
    match Rows.at labels_window (first + i) with
    | Some label ->
      (* A separate name for the sanitized text. Shadowing [label] left four
         uses that read as raw ones to anything checking by name, the reader
         included.

         Folded from the middle, the way a table folds a name: the frame
         cuts a tail, and a reader's index is a column of names whose ends
         are what part them. Measured on the live Board, 50 posts: a tail cut
         left nine rows in three groups a reader could not tell apart -- four
         read "#verification Approved task...", three "#verification Verify:
         wkbl ..." -- and folding from the middle leaves all fifty distinct.

         Every row uses the same lead and folding width, whether or not
         the cursor is on it. Moving the caret never shifts the label. *)
      let drawn =
        Message_layout.fit_middle
          (max 1 (framed_inner_width cols - sidebar_row_lead_cells))
          (Terminal_text.single_line label)
      in
      if Option.equal Int.equal selection (Some (first + i)) then
        draw ~style:(if focused then Theme.sidebar_selection () else "")
          (sidebar_caret_lead ^ drawn)
      else draw (String.make sidebar_row_lead_cells ' ' ^ drawn)
    | None -> draw ""
  done;
  draw ""

(* The same index for a list whose open row is always in it. *)
let write_list_sidebar buf ~rows ~cols ~title ~focused ~holding ~labels
    ~selected =
  write_list_sidebar_selection buf ~rows ~cols ~title ~focused ~holding ~labels
    ~selection:(Some selected)


(* The row a surface draws when its load failed. Six copies wrote the sentence
   out and each reserved [cols - 24] for the error beside it -- one cell more
   than the frame gives, so a long error was cut where its closing bracket
   should have been. The room is worked out from the sentence here, which is
   what stops the two from drifting the next time the wording changes. *)
let data_unreliable_open = "  (data unreliable: "

let data_unreliable_close = ")"


let data_unreliable_row ~cols err =
  let err = Masc.Tui_terminal_text.sanitize_terminal_text err in
  let room =
    max 8
      (framed_inner_width cols
       - Message_layout.display_width data_unreliable_open
       - Message_layout.display_width data_unreliable_close)
  in
  (* Generic HTTP bodies and diagnostics carry their actionable prefix.
     Transport failures put the request target before their verbose reason.

     Cut only when the error is longer than the room. [fit_width] also pads a
     shorter one out to the room, which is right for a column and wrong for a
     sentence: the closing bracket stood at the right edge of the frame, a
     screen's width away from the words it closes. *)
  let shown =
    if Message_layout.display_width err > room then fit_width err room else err
  in
  (Theme.bad ())
  ^ data_unreliable_open
  ^ shown
  ^ data_unreliable_close
  ^ Ansi.reset


let fenced_document_text = Masc_tui_markdown_theme.fenced

(* The server names itself in every footer, because "which masc is this"
   is a question every surface can raise and none of them answered: the tail
   named only its listening endpoint and two checkouts there read identically. *)
(* One hue per token kind, for every surface that draws lexed rows. It was a
   local function inside the Code surface until Config started drawing the same
   segments; a second copy would be a second answer the first time one of them
   gained a kind. *)
let lexed_span (text, kind) =
  if String.length text = 0 then ""
  else
    let style =
      if String.equal kind Masc_tui_code_lexer.kind_keyword then
        Theme.Syntax.keyword ()
      else if String.equal kind Masc_tui_code_lexer.kind_string then
        Theme.Syntax.string ()
      else if String.equal kind Masc_tui_code_lexer.kind_comment then
        Theme.Syntax.code_comment ()
      else if String.equal kind Masc_tui_code_lexer.kind_number then
        Theme.Syntax.code_number ()
      else if String.equal kind Masc_tui_code_lexer.kind_type then
        Ansi.bold ^ Theme.Syntax.code_type ()
      else if String.equal kind Masc_tui_code_lexer.kind_json_key then
        Theme.Syntax.json_key ()
      else if String.equal kind Masc_tui_code_lexer.kind_json_number then
        Theme.Syntax.json_number ()
      else if String.equal kind Masc_tui_code_lexer.kind_json_literal then
        Theme.Syntax.json_literal ()
      else if String.equal kind Masc_tui_code_lexer.kind_json_punctuation then
        Theme.Syntax.json_punctuation
      else ""
    in
    if String.equal style "" then text else style ^ text ^ Ansi.reset


(* Compact "how long" text the Lanes table's idle column and the Keeper
   operations preview share -- the preview kept a byte-for-byte copy of this
   under its own name, 3,600 lines below, until the two were counted. *)
let keeper_lane_idle_text seconds =
  let seconds = max 0 seconds in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)


(* Long question, choice, and reason text was cut to one line with a trailing
   "~", so an operator could not read the decision being asked of them. Each
   field wraps instead: the first row carries [head] (the caret and Keeper
   name, or a choice's number and mark), and every wrapped row after it is
   indented to [head]'s visible width so the text stays in one column. [head]'s
   ANSI is not counted toward the indent -- display_width reads cells, not
   escape bytes. box_line pads content to the inner width, so a row of exactly
   the inner width is filled, not truncated. *)
(* A block, not a line. [single_line] escapes every control byte, and a
   newline is one: run over a body whole it prints "\x0A" at each break and
   hands back one unbroken paragraph. Two of the three questions the live
   fleet was holding carried newlines in their context -- eleven in one -- so
   the pane drew the operator's own paragraph breaks into the sentence.
   [wrap_body] escapes line by line, which covers what the escape is for and
   leaves the breaks as breaks. *)
let box_wrapped_field buf cols ~head ~style body =
  let indent = Message_layout.display_width head in
  let avail = max 8 (framed_inner_width cols - indent) in
  match
    Message_layout.wrap_body ~max_cells:avail
      ~sanitize:Terminal_text.single_line body
  with
  | [] -> box_line buf cols head
  | first :: rest ->
      box_line buf cols (head ^ style ^ first ^ Ansi.reset);
      let hang = String.make indent ' ' in
      List.iter
        (fun segment -> box_line buf cols (hang ^ style ^ segment ^ Ansi.reset))
        rest


let draw_ask_text_entry buf cols ~draft ~question (entry : ask_text_entry) =
  box_wrapped_field buf cols
    ~head:(Printf.sprintf "      %swrite: " Ansi.bold)
    ~style:Ansi.bold
    (Terminal_text.single_line entry.ate_text ^ "\xe2\x96\x8c");
  match Ask_projection.response_for draft ~question with
  | Some (Ask_projection.Draft_chose _) ->
      box_line buf cols
        (Printf.sprintf "      %ssaving replaces what you picked%s"
           Ansi.dim Ansi.reset)
  | Some (Ask_projection.Draft_wrote _)
  | Some Ask_projection.Draft_skipped
  | None -> ()


(* One question with everything the operator answers it by: the prompt, the
   choices and their marks, whatever the draft holds, and the free-text line.
   Lifted out of the panel so the panel can draw a question into a buffer of
   its own and ask how tall it came out before deciding to spend those rows. *)
let draw_ask_question buf cols ~text_entry ~(row : Masc.Tui_decode_asks.ask_row)
    ~draft ~(question : Masc.Tui_decode_asks.ask_question) ~answering
    ~selected_question =
  (* The caret is the only thing saying where the cursor is: which question
     [a] opens while browsing, and which one the digits land on while
     answering. A blank on every row reads as no selection at all. *)
  let caret = if selected_question then ">" else " " in
  box_wrapped_field buf cols
    ~head:
      (Printf.sprintf " %s%s%s%s%s  " caret
         (if selected_question then Ansi.bold else "")
         (fit_width (Terminal_text.single_line (Masc.Tui_decode_asks.ask_asker_label row.Masc.Tui_decode_asks.ar_asker)) 16)
         (if selected_question then Ansi.reset else "")
         Ansi.reset)
    ~style:(if selected_question then Ansi.bold else "")
    question.Masc.Tui_decode_asks.aq_prompt;
  let chosen =
    match Ask_projection.response_for draft ~question with
    | Some (Ask_projection.Draft_chose ids) -> ids
    | Some (Ask_projection.Draft_wrote _)
    | Some Ask_projection.Draft_skipped
    | None -> []
  in
  List.iteri
    (fun choice_index (choice : Masc.Tui_decode_asks.ask_choice) ->
      let picked =
        List.exists (String.equal choice.Masc.Tui_decode_asks.ac_id) chosen
      in
      (* One mark shape per mode: a round one where only one answer fits, a
         square one where several do. The operator should not have to read the
         header to know whether picking a second choice replaces the first. *)
      let mark =
        match (question.Masc.Tui_decode_asks.aq_mode, picked) with
        | Masc.Tui_decode_asks.Ask_single, true -> "(o)"
        | Masc.Tui_decode_asks.Ask_single, false -> "( )"
        | Masc.Tui_decode_asks.Ask_multi, true -> "[x]"
        | Masc.Tui_decode_asks.Ask_multi, false -> "[ ]"
      in
      (* Numbers only where they do something: the digits answer the question
         under the caret, and only once the operator is answering it. A number
         on every row, or one drawn while browsing, promises a key that does
         nothing. *)
      let position =
        if answering && selected_question && choice_index < 9 then
          Printf.sprintf "%d" (choice_index + 1)
        else " "
      in
      box_wrapped_field buf cols
        (* Choice ids bind the draft and POST. The operator selects by the
           displayed position and reads the label; an opaque id spends the
           narrow pane's label width without adding another action. *)
        ~head:(Printf.sprintf "    %s %s " position mark)
        ~style:(if picked then Ansi.bold ^ Theme.ok () else Theme.info ())
        choice.Masc.Tui_decode_asks.ac_label;
      (* What picking this commits to. The wire carries it, the dashboard
         draws it under the label, and this pane dropped it -- so the operator
         answering from the terminal weighed a label where the one answering
         from a browser weighed a label and its consequence. *)
      match choice.Masc.Tui_decode_asks.ac_description with
      | None -> ()
      | Some description ->
        (* Not [single_line] here: the field is a block and the escaping is
           the block reader's, one line at a time. Sanitising first would
           leave nothing for it to break on. *)
        box_wrapped_field buf cols
          ~head:"          "
          ~style:Ansi.dim
          description)
    question.Masc.Tui_decode_asks.aq_choices;
  (* What the operator has put down so far, in the two shapes a list of
     choices cannot show. *)
  (match Ask_projection.response_for draft ~question with
   | Some (Ask_projection.Draft_wrote text) ->
       box_wrapped_field buf cols
         ~head:(Printf.sprintf "      %swrote: " Ansi.bold)
         ~style:Ansi.bold text
   | Some Ask_projection.Draft_skipped ->
       box_line buf cols (Printf.sprintf "      %sskipped%s" Ansi.dim Ansi.reset)
   | Some (Ask_projection.Draft_chose _) | None -> ());
  let ask = Masc.Tui_decode_asks.ask_key row in
  let slot = Ask_projection.free_text_slot ~ask question in
  let aft_hint = Ask_projection.free_text_hint slot in
  (
      (* The editor belongs to one question of one ask, and the slot it holds
         names both. Matching on that rather than on the cursor means a
         snapshot arriving mid-sentence cannot move the typing onto another
         row -- nor onto another ask's question of the same id, since
         masc_ask numbers every ask from q1. *)
      let editing_here =
        match text_entry with
        | Some entry
          when Masc.Tui_decode_asks.equal_ask_key (Ask_projection.free_text_ask entry.ate_slot) ask
               && String.equal
                    (Ask_projection.free_text_question_id entry.ate_slot)
                    question.Masc.Tui_decode_asks.aq_id ->
            Some entry
        | Some _ | None -> None
      in
      match editing_here with
      (* The typing is drawn where it lands, with the same block caret the row
         search uses. Without it the keys went into a buffer nothing on screen
         showed, which reads as a terminal that has stopped listening. *)
      | Some entry ->
          draw_ask_text_entry buf cols ~draft ~question entry
      | None -> (
          let key =
            if not (answering && selected_question) then ""
            else match Ask_projection.alternative_position question with
              | Some position -> Printf.sprintf "[%d/t] " position
              | None -> "[t] "
          in
          let label =
            if question.Masc.Tui_decode_asks.aq_choices = [] then "Write your answer"
            else "Other: write your own answer"
          in
          box_line buf cols
            (Printf.sprintf "      %s%s%s%s" (Theme.info ()) key label Ansi.reset);
          Option.iter (fun hint ->
            box_wrapped_field buf cols ~head:"      " ~style:Ansi.dim hint) aft_hint))


(* The reason is what separates a decision that matters from one that does
   not, so it is drawn, not hidden behind a detail view. *)
let draw_ask_context buf cols ~(row : Masc.Tui_decode_asks.ask_row) =
  match row.Masc.Tui_decode_asks.ar_context with
  | None -> ()
  | Some context ->
      box_wrapped_field buf cols
        ~head:(Printf.sprintf "    %swhy: " Ansi.dim)
        ~style:Ansi.dim context


(* Draw [f] into a buffer of its own and report how tall it came out. Height
   is a measured fact here rather than an estimate: a prompt wraps against the
   terminal's width, so the only honest way to know what a question costs is
   to draw it. *)
let ask_block f =
  let b = Buffer.create 256 in
  f b;
  (Buffer.contents b, count_frame_lines b)


let question_hints (state : state) =
  let open Masc_tui_keys in
  match state.ask_answer_mode with
  | Ask_browsing ->
      let asks =
        match open_ask_rows state with
        | [] -> No_asks
        | _ :: _ ->
            (match selected_ask_row state with
             | Some _ -> Ask_selected
             | None -> Asks_unselected)
      in
      footer_hints_approvals ~lang:state.ui_language
        (Approval_browsing
           { approvals = not (List.is_empty (Masc_tui_approvals_model.approval_items state))
           ; asks
           ; source = Option.is_some (selected_ask_origin state)
           ; last_answer = Option.is_some (current_ask_answer_feedback state)
           })
  | Ask_answering _ ->
      (match state.ask_text_entry with
       | Some _ -> footer_hints_approvals ~lang:state.ui_language Approval_writing
       | None ->
           if Masc_tui_types.ask_submit_is_armed state then
             footer_hints_approvals ~lang:state.ui_language Approval_armed
           else
             let question = selected_ask_question state in
             let has_choices =
               match question with
               | Some (q : Masc.Tui_decode_asks.ask_question) ->
                   q.Masc.Tui_decode_asks.aq_choices <> []
               | None -> false
             in
             let takes_text = Option.is_some question in
             footer_hints_approvals ~lang:state.ui_language
               (Approval_answering { has_choices; takes_text }))

let draw_ask_origin buf cols (state : state) =
  Option.iter (fun (origin : Ask_projection.origin) ->
    box_divider buf cols;
    box_wrapped_field buf cols ~head:"  " ~style:(Theme.info ())
      "Recorded question source · o:close";
    box_wrapped_field buf cols ~head:"  Keeper: " ~style:Ansi.dim origin.ao_keeper_name;
    box_wrapped_field buf cols ~head:"  Question: " ~style:Ansi.dim origin.ao_ask_id;
    match origin.ao_source_turn_ref with
    | None -> box_wrapped_field buf cols ~head:"  " ~style:Ansi.dim
        "Calling turn was not recorded. Current Keeper activity does not establish it."
    | Some reference ->
        box_wrapped_field buf cols ~head:"  Asking turn: " ~style:Ansi.dim
          (Ids.Turn_ref.to_string reference);
        box_wrapped_field buf cols ~head:"  " ~style:Ansi.dim
          "O:inspect this turn · Esc returns to the question") (Masc_tui_types.current_ask_origin state)

let ask_question_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let text_entry = state.ask_text_entry in
  let lines =
    let asks = Masc_tui_types.open_ask_rows state in
    match Ask_projection.selected_row asks state.ask_cursor with
    | None when asks <> [] -> ["  Nothing selected -- [ or ] chooses a question"]
    | None -> ["  No questions waiting"]
    | Some row ->
        let draft = Ask_projection.draft_for state.ask_draft ~row in
        (match List.nth_opt row.ar_questions state.ask_question_cursor with
         | None -> ["  No question selected"]
         | Some question ->
             let text, _ = ask_block (fun b ->
               match text_entry with
               | Some entry
                 when Masc.Tui_decode_asks.(equal_ask_key (Ask_projection.free_text_ask entry.ate_slot) (ask_key row))
                      && String.equal
                           (Ask_projection.free_text_question_id entry.ate_slot) question.aq_id ->
                   (* Typing owns the keys. Keep the editor separate from
                      choices and context that can fill the reader. The slot
                      must own this Ask too: question IDs repeat across Asks,
                      and saving still targets the slot's original owner. *)
                   box_wrapped_field b cols ~head:"  " ~style:Ansi.bold
                     question.aq_prompt;
                   draw_ask_text_entry b cols ~draft ~question entry
               | Some _ | None ->
                   draw_ask_origin b cols state;
                   draw_ask_question b cols ~text_entry ~row ~draft ~question
                     ~answering:true ~selected_question:true;
                   draw_ask_context b cols ~row) in
             String.split_on_char '\n' text |> List.filter (fun line -> line <> ""))
  in
  (* title, progress, help, two dividers, outer edges and footer *)
  let room = max 1 (rows - 9) in
  (lines, room)

;;

(* The score is a reading, not text: up-voted draws ok, down-voted bad, and
   zero -- most posts -- stays muted rather than claiming a colour. *)
let board_score_style votes =
  if votes > 0 then (Theme.ok ())
  else if votes < 0 then (Theme.bad ())
  else (Theme.muted ())

let board_score_text votes =
  if votes > 0 then Printf.sprintf "▲%+d" votes
  else if votes < 0 then Printf.sprintf "▼%d" votes
  else " 0"

(* A value in brackets: [text], folded in the middle only when it runs past
   [max_cells]. Four places fitted the value with [fit_width] first, which
   pads as well as cuts, so a short one closed its bracket after a run of
   spaces -- "[post-a      ]", "[executing ]", "[active    ]". A row that
   needs the bracket to line up pads after it. *)
let bracketed ~max_cells text =
  "[" ^ Message_layout.truncate_middle max_cells text ^ "]"

(* The Board reader's title row: the screen, which post, its hearth, its score
   and its replies. The id uses the compact reference width. Replies read "💬3"
   and then "c0" at zero -- a second spelling for the same count -- and are one
   spelling now, receding at zero. *)
let board_read_title ~screen ~id ~hearth ~votes ~replies =
  let id = bracketed ~max_cells:Render_schedule.board_id_width id in
  let hearth_tag =
    match hearth with
    | Some h when not (String.equal h "") ->
        Printf.sprintf "  %s#%s%s" (Theme.info ()) h Ansi.reset
    | _ -> ""
  in
  Printf.sprintf "%s  %s%s%s%s  %s%s%s  %s💬%d%s" screen
    (Theme.accent ()) id Ansi.reset hearth_tag
    (board_score_style votes) (board_score_text votes) Ansi.reset
    (if replies > 0 then Theme.ok () else Ansi.dim) replies Ansi.reset


(* Three steps for three bands, from the palette every other reading on this
   screen draws through. Emphasis only ever restates what the count beside it
   already says, so NO_COLOR costs a reader nothing they cannot read. *)
let magnitude_tone = function
  | Magnitude.Leading -> (Theme.accent ())
  | Magnitude.Ordinary -> Ansi.reset
  | Magnitude.Below_even_share -> Ansi.dim


(* One slot for the browser scene on screen. Module state rather than a field
   on [state], like [board_read_layout]: a wrapped row is a derived reading,
   not authority, and the input layer would otherwise invalidate it at every
   scroll. *)
let browser_lane_layout = Browser_lane_layout.create ()


let browser_lane_rows ~cols (view : Browser_lane_view.t) =
  (* The same three branches browser_lane_page_layout takes, so the key holds
     every input that decides a row. *)
  let content =
    match view.Browser_lane_view.scene with
    | Some scene -> Browser_lane_layout.Scene scene.content.Masc.Browser_scene.nodes
    | None ->
      (match view.Browser_lane_view.reading with
       | Some { page = Some page; _ } -> Browser_lane_layout.Page page.text
       | Some _ | None -> Browser_lane_layout.Empty)
  in
  let source =
    { Browser_lane_layout.content
    ; scene_cursor = view.Browser_lane_view.scene_cursor
    ; columns = cols
    }
  in
  Browser_lane_layout.get browser_lane_layout ~source ~render:(fun () ->
    browser_lane_page_layout ~cols view)


(* A shared, deliberately small status vocabulary for operational surfaces.
   Only the status token receives colour; titles and identifiers stay neutral,
   so colour says what changed rather than becoming row decoration. Unknown
   producer words remain visible and unranked. *)
let semantic_status_color status =
  (* Status producers already own their canonical wire vocabulary. Keeping
     that spelling intact also preserves Planning's Goal_phase SSOT: a renderer
     must not normalize domain status strings behind the decoder's back. *)
  match String.trim status with
  | "running" | "executing" | "active" | "in_progress" -> (Theme.info ())
  | "scheduled" | "due" | "pending" | "waiting" | "verifying"
  | "fallback" | "unknown" | "queued" | "degraded" | "matched_pending" ->
      (Theme.warn ())
  | "failed" | "failure" | "rejected" | "reject" | "refuted"
  | "unreadable" | "blocked" | "error" | "deny" | "denied" | "read_error"
  | "not_found" | "unrecognized_detail" | "unrecognized_receipt"
  | "missing_stimulus_id" | "invalid_stimulus_id" -> (Theme.bad ())
  | "succeeded" | "success" | "completed" | "complete" | "proven"
  | "approve" | "approved" | "answered" | "recorded" | "applied" | "ok"
  | "ready" | "pass" | "passed" | "allowed" | "matched_recorded"
  | "recognized" ->
      (Theme.ok ())
  | "cancelled" | "canceled" | "dropped" | "expired" | "skipped" ->
      Ansi.dim
  | _ -> Ansi.reset


(* The screen's word for a phase, not the wire's. [Goal_phase.to_string] is
   the value a tool filter and a stored goal carry, and one of them is
   [awaiting_confirmation] at 21 cells. The column below is as wide as the
   widest label, and TITLE gets what is left, so spelling the wire token here
   spent twelve columns of every planning row on one phase name and folded
   titles at 80 and 99 columns alike. Each label is a match arm so a new
   phase has to be given a word rather than inheriting a long one. *)
let planning_phase_label ~ko = function
  | Goal_phase.Executing -> if ko then "진행 중" else "executing"
  | Goal_phase.Verifying -> if ko then "검증 중" else "verifying"
  | Goal_phase.Awaiting_confirmation -> if ko then "최종 확인 대기" else "confirming"
  | Goal_phase.Completed -> if ko then "완료" else "completed"
  | Goal_phase.Dropped -> if ko then "중단" else "dropped"
  | Goal_phase.Paused _ -> if ko then "일시 정지" else "paused"
  | Goal_phase.Blocked _ -> if ko then "막힘" else "blocked"

(* The key and label a Goal detail uses for each lifecycle request. [c]
   requests completion or recovery; its submission does not prove a judge was
   dispatched. Operator confirmation reads and binds the exact proof through
   the admin route. [p] is Pause and Resume both: no phase offers the two
   ([Goal_phase.decide_transition]), so the Goal on screen picks the one [p]
   sends, and [r] stays the refresh it is on every other screen. *)
let planning_action_key = function
  | Goal_phase.Public_action.Request_complete -> "c"
  | Goal_phase.Public_action.Drop -> "x"
  | Goal_phase.Public_action.Reopen -> "o"
  | Goal_phase.Public_action.Pause | Goal_phase.Public_action.Resume -> "p"
  | Goal_phase.Public_action.Block -> "b"
  | Goal_phase.Public_action.Unblock -> "u"

let planning_action_of_key ~offers key =
  let key = String.lowercase_ascii key in
  List.find_opt (fun action -> String.equal (planning_action_key action) key && offers action)
    Goal_phase.Public_action.all

let planning_action_confirmation_keys action =
  let key = planning_action_key action in
  [ key; String.uppercase_ascii key ]

let planning_action_label ~ko = function
  | Goal_phase.Public_action.Request_complete -> if ko then "완료 요청" else "Request completion"
  | Goal_phase.Public_action.Drop -> if ko then "중단" else "Drop"
  | Goal_phase.Public_action.Reopen -> if ko then "다시 열기" else "Reopen"
  | Goal_phase.Public_action.Pause -> if ko then "일시 정지" else "Pause"
  | Goal_phase.Public_action.Resume -> if ko then "재개" else "Resume"
  | Goal_phase.Public_action.Block -> if ko then "막힘 설정" else "Block"
  | Goal_phase.Public_action.Unblock -> if ko then "막힘 해제" else "Unblock"


(* As wide as the widest phase rather than a literal. Three of the four labels
   are nine cells and the column was eight, so nearly every planning row read
   [complet~] with sixty columns of space to its right -- the mark that says
   "there was more" on a value nothing was cut from. Taken from the phase list
   so a new phase widens the column instead of losing its last letter. *)
let planning_phase_column ~ko =
  List.fold_left
    (fun widest phase ->
      max widest (Message_layout.display_width (planning_phase_label ~ko phase)))
    0
    Goal_phase.all


(* Three of the four phases are a health reading and one is not. Executing,
   Completed and Dropped are how the goal is doing; Verifying is where it
   is, and a goal under review is neither well nor unwell. It used to keep a
   raw colour for want of anywhere else to put it -- the theme had [status]
   for health, dim and the accent for weight and [Syntax] for what a token
   is, and nothing for a kind.

   It takes a categorical slot now (RFC-0431). Slot 4 is magenta, the hue it
   already drew, and magenta is one of the two the status axis does not
   claim -- which matters here, because the three phases beside it are
   status tokens and a slot aliasing one of those would read as a verdict.

   The count of these was thirteen. This is the last of them. *)
let planning_phase_color = function
  | Goal_phase.Executing -> (Theme.info ())
  | Goal_phase.Verifying -> Theme.category Theme.Slot_2
  | Goal_phase.Awaiting_confirmation -> Theme.warn ()
  | Goal_phase.Completed -> (Theme.ok ())
  | Goal_phase.Dropped -> (Theme.muted ())
  | Goal_phase.Paused _ -> Theme.warn ()
  | Goal_phase.Blocked _ -> Theme.bad ()

;;

(* The goal count, the completed share and one counter per phase that has a
   goal in it. With no goals the row read the count, a sentence saying the
   count, and five zero counters over a list that says "(no goals)" itself.
   The count is the whole reading there.

   A phase with nothing in it is left out for the same reason: the list
   under the row names every goal's phase, so a zero here repeats what the
   list already does not show. Written out, the five counters with single
   digits are 92 cells, and beside the roster pane at 150 columns the row
   ends at "Drop:" with its count cut off -- and under the active filter
   the list hides ended goals, so that count is not in the rows either.
   The Overview's Keepers count names its non-active states the same way.

   Executing, Completed and Dropped wear the {!Masc_tui_theme.Glyph} progress
   marks the Backlog row under them wears for running, done and cancelled.
   Verifying and awaiting confirmation are stages only a Goal has, so their
   diamonds are theirs. *)
let planning_rollup_clauses ~cols (rollup : planning_rollup) =
  let phases =
    [ (Goal_phase.Executing, Masc_tui_theme.Glyph.progress_active, "Exec", rollup.pr_active)
    ; (Goal_phase.Verifying, "◆", "Ver", rollup.pr_verifying)
    ; (Goal_phase.Awaiting_confirmation, "◇", "Conf", rollup.pr_awaiting_confirmation)
    ; (Goal_phase.Completed, Masc_tui_theme.Glyph.progress_done, "Done", rollup.pr_done)
    ; (Goal_phase.Paused Goal_phase.Resume_executing, "Ⅱ", "Pause", rollup.pr_paused)
    ; (Goal_phase.Blocked Goal_phase.Resume_executing, "!", "Block", rollup.pr_blocked)
    ; (Goal_phase.Dropped, Masc_tui_theme.Glyph.progress_ended, "Drop", rollup.pr_dropped)
    ]
  in
  let total_goals = List.fold_left (fun total (_, _, _, value) -> total + value) 0 phases in
  let count = Printf.sprintf "Goals: %s%d%s" Ansi.bold total_goals Ansi.reset in
  if total_goals = 0 then (count, [])
  else
    let bar_width = if cols < 90 then 8 else 12 in
    let progress_bar =
      Printf.sprintf "[%s] %2d%% (%d/%d)"
        (Masc_tui_context_bars.ratio_bar ~width:bar_width
           ~numerator:rollup.pr_done ~denominator:total_goals)
        (rollup.pr_done * 100 / total_goals) rollup.pr_done total_goals
    in
    let counter phase glyph name value =
      Printf.sprintf "%s%s %s: %d%s" (planning_phase_color phase) glyph name value
        Ansi.reset
    in
    let counters =
      phases
      |> List.filter_map (fun (phase, glyph, name, value) ->
             if value = 0 then None else Some (counter phase glyph name value))
    in
    (Printf.sprintf "%s %s" count progress_bar, counters)

let planning_rollup_row ~cols (rollup : planning_rollup) =
  match planning_rollup_clauses ~cols rollup with
  | head, [] -> "  " ^ head
  | head, counters ->
      Printf.sprintf "  %s  %s│%s  %s" head (Theme.recede ()) Ansi.reset
        (String.concat "  " counters)

let planning_rollup_rows ~cols (rollup : planning_rollup) =
  let single = planning_rollup_row ~cols rollup in
  if Message_layout.display_width single <= framed_inner_width cols then
    [ single ]
  else
    let head, counters = planning_rollup_clauses ~cols rollup in
    let max_cells = max 1 (framed_inner_width cols - 2) in
    Message_layout.pack_clauses ~max_cells (head :: counters)
    |> List.map (fun row -> "  " ^ row)

(* The Backlog counts, each with the mark its Task rows wear. Claimed had no
   mark here while a claimed Task row draws the half circle, so the one count a
   reader could match to a row was the one left bare. *)
let planning_backlog_counts (backlog : planning_backlog) =
  let open Masc_tui_theme.Glyph in
  [ ("todo", backlog.pb_todo, progress_waiting ^ " todo")
  ; ("claimed", backlog.pb_claimed, progress_active ^ " claimed")
  (* "in_progress", not "running": the wire field this count decodes is
     [in_progress], the Task row two screens over draws the same state as
     [in_progress], and so does the CLI's own tally. This row was the only
     place that renamed it, so one state read as two on one screen. *)
  ; ("in_progress", backlog.pb_running, progress_active ^ " in_progress")
  (* Work that is finished and waiting on a verifier, which is the queue the
     Task Review tab counts on this same surface. It sat inside [in_progress],
     so the row said twenty-one were being worked while seven of them were
     waiting for a reader. *)
  ; ( "awaiting_verification"
    , backlog.pb_awaiting_verification
    , progress_active ^ " awaiting_verification" )
  ; ("done", backlog.pb_done, progress_done ^ " done")
  ; ("cancelled", backlog.pb_cancelled, progress_ended ^ " cancelled")
  ]

let planning_backlog_clauses (backlog : planning_backlog) =
  let items = planning_backlog_counts backlog in
  let counts = List.map (fun (k, v, _) -> k, v) items in
  let bands = Magnitude.of_counts counts in
  List.mapi
    (fun i ((_, _, label), (_, value, band)) ->
       let item =
         Printf.sprintf "%s%s=%d%s" (magnitude_tone band) label value
           Ansi.reset
       in
       if i = 0 then
         Printf.sprintf "%sBacklog:%s %s" Ansi.dim Ansi.reset item
       else item)
    (List.combine items bands)

let planning_change_clauses ~ko ~(baseline : planning_snapshot option)
    (current : planning_snapshot) =
  match baseline with
  | None -> [ if ko then "첫 성공 스냅샷 대기" else "Change: waiting for the first successful snapshot" ]
  | Some first ->
      [ Printf.sprintf (if ko then "완료 단계 목표 %+d" else "Change from baseline: Goals in completed phase %+d")
          (current.pl_rollup.pr_done - first.pl_rollup.pr_done)
      ; Printf.sprintf (if ko then "완료 Task %+d" else "Tasks done %+d")
          (current.pl_backlog.pb_done - first.pl_backlog.pb_done)
      ; Printf.sprintf (if ko then "검증 단계 목표 %+d" else "Goals in verifying phase %+d")
          (current.pl_rollup.pr_verifying - first.pl_rollup.pr_verifying)
      ]

let pack_planning_summary_rows ~cols (clauses : string list) =
  let summary_inner = max 1 (framed_inner_width cols - 2) in
  Message_layout.pack_clauses ~max_cells:summary_inner clauses
  |> List.map (fun row -> "  " ^ row)

let work_tasks_room ~budget ~header_rows ~count =
  if budget <= header_rows then 0
  else if budget - header_rows = 1 then 1
  else
    Masc_tui_scroll.content_height ~rows:budget ~chrome:header_rows
      ~count ~preview_keep:None ~overflow_takes_row:true

(* The retained-history count above the Goal list. The row carried two numbers
   joined by the same separator the Backlog counts use for disjoint parts, but
   the goals that reached an end are a subset of the goals no longer listed --
   so when every one of them ended, the row said the same number twice and
   never said the difference. That difference is the reading an operator
   cannot take off a row: the server fills [closed_at] only for a goal whose
   last phase is terminal, so a goal counted here without one left the list
   with no outcome recorded. *)
let planning_goal_history_summary ~unlisted ~ended =
  let without_an_outcome = unlisted - ended in
  if without_an_outcome <= 0 then Printf.sprintf "  No longer listed: %d" unlisted
  else
    Printf.sprintf "  No longer listed: %d · %d with no outcome" unlisted
      without_an_outcome

(* Planning is one operator workspace with three authorities behind it: Goal
   lifecycle, the Task verdict queue, and the verdicts the judge recorded.
   Keep their APIs separate, but make the hierarchy visible in the title
   instead of presenting unrelated top-level destinations.

   Verdicts arrived here from a top-level tab called "Harness", which named a
   mechanism rather than a thing an operator wants. It is the far half of Task
   Review: one lists what is waiting for a ruling and the other what was
   ruled, and they were a screen apart with nothing saying they were the same
   subject. *)
type planning_tab = Render_schedule.planning_tab =
  | Planning_goals
  | Planning_task_review
  | Planning_verdicts

(* [window] is the page-versus-ledger reading for the tab the reader is on,
   already formatted, e.g. " (8 of 4223)". It rides the active label because a
   count set loose at the end of the strip attaches itself to whatever label
   happens to be last: the verdict page count read as a Fusion count for as
   long as Schedules and Fusion were named here. Surfaces with nothing to
   count pass "". *)
(* [after] is what the caller draws past this title on the same row: the mode
   words, the clock, the badge, or the record a detail pane names. The strip
   leaves room for it rather than taking the row and letting the frame cut
   whatever followed -- at a hundred columns this title lost its badge and
   half its clock. Callers build that tail once and hand the same value here
   and to the row, so the measurement and the drawing cannot disagree. *)
let planning_workspace_lead (state : state) =
  screen_title (" " ^ here_screen_name state) ^ "  "

let planning_workspace_tabs (state : state) ~(tab : planning_tab) ~(window : string) =
  let review_count = Option.map (fun s -> s.vs_total) state.verification in
  let verifying_count =
    (* Other Work tabs retain the previous unavailable-count behavior. The
       retained Goal rows carry their provenance on their own list/detail. *)
    match state.workspace_identity, state.planning_error with
    | Workspace_identity_match, None -> Option.map
        (fun (p : planning_snapshot) -> p.pl_rollup.pr_verifying) state.planning
    | (Workspace_identity_unread | Workspace_identity_match_unconfirmed _ | Workspace_identity_mismatch _), _
    | Workspace_identity_match, Some _ -> None
  in
  let stops =
    Render_schedule.planning_strip_plain ~tab ~review_count ~verifying_count
      ~window
  in
  let stops = if state.ui_language <> Lang_ko then stops else
    let counted label = function
      | Some count when count > 0 -> Printf.sprintf "%s·%d" label count
      | Some _ | None -> label in
    List.map (fun (stop, _) ->
      let label = match stop with
        | Planning_goals -> counted "목표" verifying_count
        | Planning_task_review -> counted "작업 검토" review_count
        | Planning_verdicts -> "작업 판정" in
      stop, if stop = tab then label ^ window else label) stops
  in
  (* Each stop is a surface of its own; [v] walks them in this order. *)
  let surface_of_stop = function
    | Planning_goals -> Planning
    | Planning_task_review -> Verification
    | Planning_verdicts -> Harness
  in
  List.map
    (fun (stop, label) -> (label, stop = tab, surface_of_stop stop))
    stops

let planning_workspace_strip ~width tabs =
  tab_strip ~width
    ~press:(fun surface text -> pressable (Press_surface surface) text)
    tabs

let planning_workspace_title (state : state) ~cols ~(tab : planning_tab) ~(window : string) ~(after : string) =
  let planning_workspace_lead = planning_workspace_lead state in
  planning_workspace_lead
  ^ planning_workspace_strip
      ~width:(tab_strip_width ~cols ~before:planning_workspace_lead ~after)
      (planning_workspace_tabs state ~tab ~window)

(* One verdict's heading: the Planning strip with Verdicts current, then the
   task the verdict is about, then the badge. The strip keeps the width that
   holds its current entry: below that it drops that entry too and the marks a
   press lands on, so the task id folds before the strip goes under it. Above
   it, the strip takes what the id leaves (#39712 review). *)
let harness_detail_heading (state : state) ~cols ~task_id ~tail =
  let cells text =
    Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)
  in
  let tabs = planning_workspace_tabs state ~tab:Planning_verdicts ~window:"" in
  let planning_workspace_lead = planning_workspace_lead state in
  let mark = " \xe2\x96\xb8 verdict  " in
  let around = cells planning_workspace_lead + cells mark in
  detail_heading ~cols
    ~lead:
      (Lead_strip
         { floor = around + tab_strip_min_width tabs
         ; draw =
             (fun width ->
               planning_workspace_lead
               ^ planning_workspace_strip ~width:(width - around) tabs
               ^ mark)
         })
    ~id:task_id ~after:[] ~tail


(* Where the goal stands with the completion judge, in one column. The phase
   reads [executing] both for a goal nobody asked about and for one the judge
   refused; without this the two are the same row. Idle is a blank rather than
   a glyph — most goals have never been asked, and a mark on all of them would
   carry no information. *)
(* Colour here, the glyph in {!Masc_tui_planning_proof_mark}, which the legend
   under the column reads from the same function. The two used to be separate
   literals and the legend was a state short. *)
let planning_proof_mark proof =
  let mark = Masc_tui_planning_proof_mark.glyph proof in
  match proof with
  | Tui_decode.Proof_idle -> mark
  | Tui_decode.Proof_proven _ -> (Theme.ok ()) ^ mark ^ Ansi.reset
  | Tui_decode.Proof_refuted _ -> (Theme.bad ()) ^ mark ^ Ansi.reset
  | Tui_decode.Proof_pending
  | Tui_decode.Proof_stale _
  | Tui_decode.Proof_unreadable _ ->
      (Theme.warn ()) ^ mark ^ Ansi.reset


(* The footer names the action behind each key for the keeper under the cursor,
   because which action the toggle sends depends on that keeper's state. A key
   with nothing behind it is dimmed rather than dropped, so the row of keys
   does not shift as the cursor travels. *)
(* A destructive action armed, or one already running. Status rather than a hint:
   [?] cannot recover "press d again to delete analyst", and the next unrelated
   key cancels the arm, so a footer that gives this up to fit something else
   gives up the only notice of a state the operator is standing in. The keys stay
   on the row beside it now instead of being replaced by it. *)

let keeper_control_hints ?(offers_chat = true) ?(offers_back = true) ?(taken = [])
    state reading =
  let available =
    match reading with None -> [] | Some r -> Keeper_control.available r
  in
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let action_word = Keeper_control.action_label ~ko in
  (* An action that ends a fiber is toned apart from the reversible ones, so the
     key that needs two presses does not read like the keys that need one. *)
  let hint action label =
    let key_color =
      if Keeper_control.requires_confirmation action then (Theme.bad ()) else (Theme.accent ())
    in
    if List.mem action available then
      Printf.sprintf "%s%s%s:%s" key_color (Keeper_control.action_key action)
        Ansi.reset label
    else
      Printf.sprintf "%s%s:%s%s" Ansi.dim (Keeper_control.action_key action)
        label Ansi.reset
  in
  let toggle =
    match Option.bind reading Keeper_control.primary with
    | Some action -> hint action (action_word action)
    | None ->
        Printf.sprintf "%sp:%s%s" Ansi.dim (action_word Keeper_control.Pause)
          Ansi.reset
  in
  let gate_hint =
    match reading with
    | Some reading
      when List.mem reading.Keeper_control.name state.keeper_yolo_names ->
        (Theme.accent ()) ^ "g" ^ Ansi.reset ^ ":auto"
    | Some _ | None -> (Theme.bad ()) ^ "g" ^ Ansi.reset ^ ":yolo"
  in
  let toggle_key =
    match Option.bind reading Keeper_control.primary with
    | Some action -> Keeper_control.action_key action
    | None -> "p"
  in
  (* [key:label] items, two spaces apart: the shape every other footer
     uses, so Masc_tui_footer can split the row, drop the lowest priority
     item when the row is tight, and keep the keys it never drops. Written
     "key label" and joined with a middle dot, the whole legend was one
     item nothing could split -- at 60 columns the row cut mid-word and
     "q quit", last in the list, went first. The two keys the footer pins
     lead with a plain key so it can read them past the colour.

     Each item carries its key, so a detail tab that answers one of these
     keys itself can take it off the row. The Sandbox tab's [s] sets the
     remote_ssh backend, and the row beside it still said "s:shutdown". *)
  let view_and_order =
    if state.view = Keepers Keeper_list then
      [ "v", (Theme.accent ()) ^ "v" ^ Ansi.reset ^ ":" ^ say "보기" "view"
      ; "o", (Theme.accent ()) ^ "o" ^ Ansi.reset ^ ":" ^ say "정렬" "order"
      ]
    else []
  in
  (* The key that leaves this screen and, on the roster, the key that opens a
     Keeper. They are spelled the way the key table and every other footer
     spell them. The roster wrote [right/enter] in lowercase, which
     [Masc_tui_footer.never_dropped_keys] does not pin, and gave no way back
     to the Dashboard at all. *)
  let accent key = (Theme.accent ()) ^ key ^ Ansi.reset in
  (* The Story window belongs to the list. It takes Enter, Esc and Tab while it
     is open, and [s] and [m] with them. *)
  let story = if state.view = Keepers Keeper_list then state.keeper_story else None in
  let way =
    if offers_back then
      [ "Left / Esc", "Left / Esc:" ^ Ansi.dim ^ say "뒤로" "back" ^ Ansi.reset ]
    else
      let esc =
        "Esc",
        "Esc:" ^ Ansi.dim
        ^ (match story with
           | None -> say "뒤로" "dashboard"
           | Some _ -> say "닫기" "close")
        ^ Ansi.reset
      in
      (* A heading opens no Keeper; its arrows fold the group under it. On a
         Keeper, Enter and Right are one item so that the pinned Enter keeps
         Right on the row too: they were one item while both opened the
         detail, and Right alone would be the first key a narrow row loses
         after [r]. The labels follow the keys in order. *)
      if keeper_list_on_heading state then
        [ "Left / Right", accent "Left / Right" ^ ":" ^ say "접기 / 펴기" "fold"; esc ]
      else if state.view = Keepers Keeper_list
              && keeper_list_stop state = Some Masc_tui_keeper_list_model.Stop_world then
        [ "Enter",
          accent "Enter" ^ ":"
          ^ (match story with None -> say "World" "world" | Some _ -> say "닫기" "close")
        ; esc
        ]
      else
        let enter =
          match story with
          | None -> say "Story" "story"
          | Some (Masc_tui_keeper_story.Story | Masc_tui_keeper_story.World) ->
              say "닫기" "close"
          | Some Masc_tui_keeper_story.Schedule -> say "Story" "story"
          | Some Masc_tui_keeper_story.Memory -> say "기억 열기" "browse"
        in
        [ "Enter / Right",
          accent "Enter / Right" ^ ":" ^ enter ^ " / " ^ say "상세" "detail"
        ; esc
        ]
  in
  let story_hints =
    match story with
    | None -> []
    | Some Masc_tui_keeper_story.World -> []
    | Some (Masc_tui_keeper_story.Story | Masc_tui_keeper_story.Schedule | Masc_tui_keeper_story.Memory) ->
        [ accent "Tab" ^ ":" ^ say "쪽" "page"
        ; accent "s" ^ ":" ^ say "일정" "schedules"
        ; accent "m" ^ ":" ^ say "기억" "memory"
        ]
  in
  (* [s] shuts a Keeper down only while the window is closed. *)
  let taken = match story with None -> taken | Some _ -> "s" :: taken in
  let items =
      view_and_order
      @ [ "j/k", Ansi.dim ^ "j/k:" ^ say "선택" "move" ^ Ansi.reset
          ; toggle_key, toggle
          ; Keeper_control.action_key Keeper_control.Wakeup,
            hint Keeper_control.Wakeup (action_word Keeper_control.Wakeup)
          (* RFC tui-server-lifecycle: with no server up, "s" starts one
             rather than shutting a keeper down, so the hint follows suit. *)
          ; "s", (match state.connection_status with
             | Disconnected ->
                 (Theme.accent ()) ^ "s" ^ Ansi.reset ^ ":"
                 ^ say "서버 시작" "start server"
             | Connecting | Booting | Degraded | Connected ->
                 hint Keeper_control.Shutdown (action_word Keeper_control.Shutdown))
            (* Delete is the only action a keeper whose configuration failed to
               read still offers, and [primary] deliberately withholds it from
               the toggle. Without its own hint the footer showed that keeper a
               dimmed "p pause" and nothing else, so the one key that worked was
               the one key nothing named. *)
          ; Keeper_control.action_key Keeper_control.Delete,
            hint Keeper_control.Delete (action_word Keeper_control.Delete)
          ; "e", (Theme.accent ()) ^ "e" ^ Ansi.reset ^ ":" ^ say "설정" "settings"
          ; "a", (Theme.accent ()) ^ "a" ^ Ansi.reset ^ ":" ^ say "새 키퍼" "new"
          ; (if state.view = Keepers Keeper_detail then
               "o", (Theme.accent ()) ^ "o" ^ Ansi.reset ^ ":" ^ say "로그" "logs"
             else "l", (Theme.accent ()) ^ "l" ^ Ansi.reset ^ ":" ^ say "로그" "logs")
          ; "t", (Theme.accent ()) ^ "t" ^ Ansi.reset ^ ":" ^ say "호출" "calls"
          ; "g", gate_hint
          ; (if state.view = Keepers Keeper_detail then "U" else "u"),
            (Theme.accent ())
            ^ (if state.view = Keepers Keeper_detail then "U" else "u")
            ^ Ansi.reset ^ ":" ^ say "런타임" "runtime"
            (* Dimmed rather than dropped, the same way an unavailable
               lifecycle key is: chat lives in detail, and a key that vanishes
               between surfaces reads as a key that does not exist. *)
          ; "c", (if offers_chat then
                    (Theme.accent ()) ^ "c" ^ Ansi.reset ^ ":" ^ say "채팅" "chat"
                  else Ansi.dim ^ "c:" ^ say "채팅" "chat" ^ Ansi.reset)
          ]
      @ way
      @ [ "r", Ansi.dim ^ "r:" ^ say "새로 조회" "refresh" ^ Ansi.reset
        ; "q", "q:" ^ Ansi.dim ^ say "종료" "quit" ^ Ansi.reset
        ]
  in
  story_hints
  @ (items
     |> List.filter (fun (key, _) ->
            not
              (List.exists
                 (fun atom -> List.mem atom taken)
                 (Masc_tui_keys.key_atoms key)))
     |> List.map snd)
  |> String.concat "  "


(* One colour per level so an operator scanning the column sees severity before
   reading the text. A level this build does not name keeps its own text and
   renders unstyled rather than borrowing another level's colour. *)

let system_log_level_style : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> Ansi.dim
  | System_info -> Ansi.reset
  | System_warn -> (Theme.warn ())
  | System_error -> (Theme.bad ())
  | System_level_unknown _ -> Ansi.reset


let system_log_category_text (entry : Masc.Tui_decode.system_log_entry) =
  match entry.sl_category with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some category -> category


let fusion_run_status_color = function
  | Fusion_running -> (Theme.info ())
  | Fusion_completed -> (Theme.ok ())
  | Fusion_failed _ -> (Theme.bad ())

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

(* A failed run says how it failed: the list is scanned for why runs fail,
   and a timeout, a provider error and panels that never answered are three
   different things to go and fix. The code is a tag from the judge's or the
   delivery's closed set, not a sentence, so it fits the cell; it is drawn in
   the failure colour, and the line under the table carries the full error for
   the selected run. *)
let fusion_run_state_text ~status ~stage =
  match status with
  | Fusion_running -> fusion_run_stage_compact stage
  | Fusion_completed -> fusion_run_status_to_string status
  | Fusion_failed failure -> Terminal_text.single_line failure.frs_failure_code


let fusion_run_progress_text = function
  | Fusion_stage_accepted -> "accepted; waiting for panel dispatch"
  | Fusion_stage_panel { frs_expected } ->
      Printf.sprintf "panel deliberation running across %d model(s)" frs_expected
  | Fusion_stage_judge { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "panel complete: %d answered / %d failed of %d; judge running"
        frs_answered frs_failed frs_expected
  | Fusion_stage_computed { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "compute complete: %d answered / %d failed of %d; awaiting durable projection"
        frs_answered frs_failed frs_expected
  | Fusion_stage_recording_evidence { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "recording evidence: %d answered / %d failed of %d"
        frs_answered frs_failed frs_expected
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"


let fusion_run_clock run =
  let tm = Unix.localtime run.fur_started_at in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min



let fusion_run_duration ~now run =
  match run.fur_status, run.fur_finished_at with
  | Fusion_running, _ -> Message_layout.span_text (now -. run.fur_started_at) ^ " running"
  | (Fusion_completed | Fusion_failed _), Some finished ->
      Message_layout.span_text (finished -. run.fur_started_at)
  | (Fusion_completed | Fusion_failed _), None -> "not recorded"


let fusion_run_age ~now run =
  Option.value ~default:Masc_tui_theme.Glyph.no_value
    (Message_layout.age_text ~now ~since:run.fur_started_at)


let repository_change_status (row : Masc.Tui_decode.repository_change) =
  if row.rc_conflicted then "conflict"
  else if row.rc_untracked then "untracked"
  else
    match row.rc_staged, row.rc_unstaged with
    | true, true -> "staged+worktree"
    | true, false -> "staged"
    | false, true -> "worktree"
    | false, false -> "unknown"


let box_line_span buf cols span =
  let inner = framed_inner_width cols in
  Buffer.add_string buf
    (Printf.sprintf "  %s  \n" (Span.render (Span.pad_to inner Span.plain (Span.truncate inner span))))


type change_context = {
  ctx_keeper : string option;
  ctx_task_id : string option;
  ctx_task_title : string option;
  ctx_task_description : string option;
  ctx_goal_id : string option;
  ctx_goal_title : string option;
  ctx_turn : int option;
  ctx_comment : string option;
  ctx_pr : Masc_tui_pr_ref.t option;
  ctx_pr_slug : string option;
      (** An explicit PR reference from the task title or description. A bare
          [#n] is a list item as often as a PR and is not read as one. *)
}

let file_change_matches_path ~scope (path : string) (fc : Masc.Tui_decode.file_change) =
  match scope, fc.Masc.Tui_decode.fc_location with
  | Some (Tui_decode.Repository_change_repository selected),
    Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      String.equal selected repo_id && String.equal relative_path path
  | Some (Tui_decode.Repository_change_repository _),
    (Masc.Tui_decode.Fc_in_bundle _ | Masc.Tui_decode.Fc_at_absolute_path _)
  | (None | Some Tui_decode.Repository_change_project), _ -> false


let first_line_summary ?(max_len = 34) (s : string) : string =
  let lines = String.split_on_char '\n' s in
  let rec find_first = function
    | [] -> ""
    | l :: rest ->
        let tr = String.trim l in
        if String.length tr > 0 then tr else find_first rest
  in
  let line = find_first lines in
  Terminal_text.single_line (Message_layout.fit_middle max_len line)


let resolve_change_context (state : state) ~(path_opt : string option) : change_context =
  let matched_change =
    match path_opt, current_keeper_chat_file_changes state with
    | Some path, Some snapshot ->
        List.find_opt
          (file_change_matches_path ~scope:state.repository_changes_scope path)
          snapshot.Masc.Tui_decode.fcs_changes
    | _ -> None
  in
  let keeper =
    match matched_change with
    | Some fc -> Some fc.Masc.Tui_decode.fc_keeper
    | None -> None
  in
  let task_id =
    match matched_change with
    | Some fc -> fc.Masc.Tui_decode.fc_task_id
    | None -> None
  in
  let turn =
    match matched_change with
    | Some fc -> fc.Masc.Tui_decode.fc_turn
    | None -> None
  in
  let task =
    match task_id with
    | Some tid ->
        List.find_opt
          (fun (t : Masc.Tui_decode.task) -> String.equal t.Masc.Tui_decode.id tid)
          state.tasks
    | None -> None
  in
  let domain_task =
    match task_id with
    | Some tid ->
        List.find_opt
          (fun (t : Masc_domain.task) -> String.equal t.id tid)
          (Masc_tui_types.task_domain_values state)
    | None -> None
  in
  let task_title =
    match task with
    | Some t -> Some t.Masc.Tui_decode.title
    | None ->
        (match domain_task with
         | Some dt -> Some dt.title
         | None -> None)
  in
  let task_description =
    match domain_task with
    | Some dt when not (String.equal (String.trim dt.description) "") ->
        Some dt.description
    | _ -> None
  in
  let goal_id =
    match task with
    | Some t -> List.nth_opt t.Masc.Tui_decode.goal_ids 0
    | None -> None
  in
  let goal_title =
    match goal_id, state.planning with
    | Some gid, Some snapshot ->
        (match
           List.find_opt
             (fun (g : planning_goal) -> String.equal g.pg_id gid)
             snapshot.pl_goals
         with
         | Some g -> Some g.pg_title
         | None -> None)
    | _ -> None
  in
  let pr =
    List.find_map
      (fun text -> Option.bind text Masc_tui_pr_ref.find)
      [ task_title; task_description ]
  in
  let pr_slug =
    match pr with
    | Some (Masc_tui_pr_ref.Pull_url {slug; _}) -> Some slug
    | Some (Masc_tui_pr_ref.Pr_token _) ->
        (match state.repository_changes_scope, state.repositories with
         | Some (Tui_decode.Repository_change_repository id), Some snapshot ->
             Option.bind
               (List.find_opt (fun (repo : Tui_decode.repository) -> String.equal repo.rp_id id)
                  snapshot.rs_repositories)
               (fun repo -> Masc_tui_pr_ref.github_slug_of_remote repo.rp_url)
         | (Some Tui_decode.Repository_change_project | None), (Some _ | None)
         | Some (Tui_decode.Repository_change_repository _), None -> None)
    | None -> None in
  { ctx_keeper = keeper
  ; ctx_task_id = task_id
  ; ctx_task_title = task_title
  ; ctx_task_description = task_description
  ; ctx_goal_id = goal_id
  ; ctx_goal_title = goal_title
  ; ctx_turn = turn
  ; ctx_comment = task_description
  ; ctx_pr = pr
  ; ctx_pr_slug = pr_slug
  }


let build_change_context_lines ~cols (change_ctx : change_context) : string list =
  let items =
    [ Option.map (fun keeper -> "Record: Keeper: " ^ keeper) change_ctx.ctx_keeper
    ; (match change_ctx.ctx_task_id, change_ctx.ctx_task_title with
       | Some id, Some title -> Some (Printf.sprintf "Task: %s (%s)" id
           (Message_layout.truncate_middle 26 title))
       | Some id, None -> Some ("Task: " ^ id)
       | None, (Some _ | None) -> None)
    ; (match change_ctx.ctx_goal_id, change_ctx.ctx_goal_title with
       | Some id, Some title -> Some (Printf.sprintf "Goal: %s (%s)" id
           (Message_layout.truncate_middle 24 title))
       | Some id, None -> Some ("Goal: " ^ id)
       | None, (Some _ | None) -> None)
    ; Option.map (fun _ -> "Checkout unverified") change_ctx.ctx_keeper
    ; Option.map (fun turn -> Printf.sprintf "Turn #%d" turn) change_ctx.ctx_turn
    ; (match change_ctx.ctx_pr, change_ctx.ctx_pr_slug with
       | Some pr, Some slug -> Some (Printf.sprintf "PR: %s#%d" slug (Masc_tui_pr_ref.number pr))
       | Some pr, None -> Some (Printf.sprintf "PR: #%d (repository unknown)" (Masc_tui_pr_ref.number pr))
       | None, (Some _ | None) -> None)
    ; (match change_ctx.ctx_comment with
       | Some text when String.trim text <> "" -> Some ("Note: " ^ first_line_summary ~max_len:34 text)
       | Some _ | None -> None)
    ] |> List.filter_map Fun.id in
  let width = max 1 (framed_inner_width cols - 2) in
  items
  |> List.concat_map (fun item -> Message_layout.wrap_words ~max_cells:width
      (Keeper_chat.terminal_safe_text item))
  |> List.map (fun line -> "  " ^ line)


let tree_diff_gutter (row : Masc.Tui_decode.git_diff_row) =
  let marker =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_removed -> "-"
    | Masc.Tui_decode.Gd_added -> "+"
    | Masc.Tui_decode.Gd_context -> " "
  in
  Printf.sprintf "%s %s %s "
    (Diff.line_number_cell row.Masc.Tui_decode.gdr_old_line)
    (Diff.line_number_cell row.Masc.Tui_decode.gdr_new_line) marker
;;

let tree_diff_row_span ?(hscroll = 0) ~width (row : Masc.Tui_decode.git_diff_row) =
  let background =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_removed -> Span.bg Theme.Syntax.diff_removed_bg
    | Masc.Tui_decode.Gd_added -> Span.bg Theme.Syntax.diff_added_bg
    | Masc.Tui_decode.Gd_context -> Span.plain
  in
  let gutter = tree_diff_gutter row in
  let text_style =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_context -> Span.combine background (Span.weight Ansi.dim)
    | Masc.Tui_decode.Gd_added | Masc.Tui_decode.Gd_removed -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.dim)) gutter
      ; Span.text text_style
          (Message_layout.drop_cells
             (Terminal_text.single_line row.Masc.Tui_decode.gdr_text) hscroll)
      ]
  in
  Span.pad_to width background (Span.truncate width composed)


(* The two diff readings -- a Git Changes file against HEAD, and a change on
   the Changes tree -- draw one frame from different state. What differs is
   listed once here and the frame is drawn once below; each copy used to
   count its own chrome by hand. *)
type diff_surface =
  { ds_path : string list
        (** the steps from the top-row screen to this reading's list *)
  ; ds_address : string  (** what the header names beside "vs HEAD" *)
  ; ds_context_lines : string list
        (** drawn under the header, each followed by a divider *)
  ; ds_diff : Masc.Tui_decode.git_diff option  (** [None] until the tree is read *)
  ; ds_error : string option
  ; ds_scroll : int  (** the stored scroll, clamped here and reported back *)
  ; ds_hscroll : int  (** body offset in display cells; gutters remain fixed *)
  ; ds_unchanged : string  (** the empty line when the tree reports no change *)
  ; ds_esc_hint : string  (** what esc does on this surface *)
  ; ds_footer_hints : string
  ; ds_surface_key : string
  ; ds_clamped : int -> clamped_scroll
  }

(* Top, title, divider, caption, divider, status, bottom and footer. *)
let diff_surface_fixed_chrome_rows = 8

let diff_surface_rows_per_context_line = 2

let diff_surface_minimum_rows = diff_surface_fixed_chrome_rows + 1

type diff_surface_geometry =
  { dsg_context_lines : string list
  ; dsg_error_rows : int
  ; dsg_content_height : int
  }

let diff_surface_geometry ~rows ~context_lines ~has_error =
  let error_rows =
    if not has_error then 0
    else if rows >= diff_surface_minimum_rows + 2 then 2
    else if rows >= diff_surface_minimum_rows + 1 then 1
    else 0 in
  let context_lines =
    if rows >= diff_surface_minimum_rows
       && (List.length context_lines * diff_surface_rows_per_context_line)
          <= rows - diff_surface_minimum_rows - error_rows
    then context_lines else [] in
  let content_height = max 1 (rows - diff_surface_fixed_chrome_rows - error_rows
      - (List.length context_lines * diff_surface_rows_per_context_line)) in
  { dsg_context_lines = context_lines; dsg_error_rows = error_rows;
    dsg_content_height = content_height }


(* The step the Git Changes list and its diffs take from Workspace. *)
let git_changes_step (state : state) = ui_text state ~ko:"Git 변경" ~en:"git changes"

let render_diff_surface (state : state) (ds : diff_surface) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let diff_rows =
    match ds.ds_diff with
    | None -> []
    | Some diff -> diff.Masc.Tui_decode.gd_rows
  in
  let total = List.length diff_rows in
  let header =
    here_row ~cols state ~path:(ds.ds_path @ [ ds.ds_address ])
      ~readings:[ "vs HEAD" ] ~position:None
  in
  if rows < diff_surface_minimum_rows then begin
    Buffer.add_string buf (Message_layout.fit_width
      " Git diff needs a larger terminal; resize to inspect (Esc:back)"
      (max 1 (cols - 1)));
    finish_surface state ~surface_key:ds.ds_surface_key ~rows:terminal_rows ~cols buf
  end else begin
  let geometry = diff_surface_geometry ~rows ~context_lines:ds.ds_context_lines
      ~has_error:(Option.is_some ds.ds_error) in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  List.iter
    (fun ctx_line ->
      box_line buf cols ctx_line;
      box_divider buf cols)
    geometry.dsg_context_lines;
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  col %d · old / new · working tree vs HEAD" (ds.ds_hscroll + 1));
  box_divider buf cols;
  (match ds.ds_error, geometry.dsg_error_rows with
   | None, _ -> ()
   | Some detail, count when count > 0 ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       if count = 2 then box_divider buf cols
   | Some _, _ -> ());
  let content_height = geometry.dsg_content_height in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min ds.ds_scroll max_scroll) in
  let diff_rows_window = Rows.of_list ~first:scroll ~height:content_height diff_rows in
  if Option.is_some ds.ds_error && geometry.dsg_error_rows = 0 then
    box_line_styled buf cols ~style:(Theme.bad ()) (page_failed_note ~ko:(state.ui_language = Lang_ko))
  else if total = 0 then begin
    (* Three different facts, and none of them is the others: not read yet, a
       failed read, and a file that matches its last commit. *)
    let empty =
      match (ds.ds_diff, ds.ds_error) with
      | (Some _ | None), Some _ -> page_failed_note ~ko:(state.ui_language = Lang_ko)
      | None, None -> "  (reading the tree)"
      | Some diff, None ->
          if diff.Masc.Tui_decode.gd_has_changes then
            "  (the tree reports a change and sent no lines)"
          else ds.ds_unchanged
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match Rows.at diff_rows_window (i + scroll) with
      | None -> box_empty buf cols
      | Some row ->
          box_line_span buf cols (tree_diff_row_span ~hscroll:ds.ds_hscroll ~width:(framed_inner_width cols) row)
    done;
  (* The status line carries the esc hint at every count, so it is one of
     the fixed chrome rows above and the reading needs no row of its own. *)
  Option.iter
    (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~ko:(state.ui_language = Lang_ko) ~scroll ~height:content_height
       ~hint:ds.ds_esc_hint total);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:ds.ds_footer_hints);
  finish_surface state ~clamped:(ds.ds_clamped scroll)
    ~surface_key:ds.ds_surface_key ~rows:terminal_rows ~cols buf
  end


let repository_changes_diff_geometry state ~terminal_rows ~cols ~path =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let context = build_change_context_lines ~cols
      (resolve_change_context state ~path_opt:(Some path)) in
  diff_surface_geometry ~rows ~context_lines:context
    ~has_error:(Option.is_some state.repository_changes_diff_error)

let repository_changes_diff_context_visible state ~terminal_rows ~cols ~path =
  (repository_changes_diff_geometry state ~terminal_rows ~cols ~path).dsg_context_lines <> []

let repository_changes_diff_page_rows state ~terminal_rows ~cols ~path =
  let geometry = repository_changes_diff_geometry state ~terminal_rows ~cols ~path in
  Masc_tui_scroll.page_step ~height:geometry.dsg_content_height

let render_repository_changes_diff (state : state) ~path =
  let _, cols = get_terminal_size () in
  let change_ctx = resolve_change_context state ~path_opt:(Some path) in
  render_diff_surface state
    { ds_path = [ git_changes_step state ]
    ; ds_address = Terminal_text.single_line path
    ; ds_context_lines = build_change_context_lines ~cols change_ctx
    ; ds_diff =
        (* A diff held for another path is not this file's reading. *)
        (match state.repository_changes_diff with
         | Some (p, diff) when String.equal p path -> Some diff
         | Some _ | None -> None)
    ; ds_error = state.repository_changes_diff_error
    ; ds_scroll = state.repository_changes_diff_scroll
    ; ds_hscroll = state.repository_changes_diff_hscroll
    ; ds_unchanged =
        ui_text state ~ko:"  (이 파일은 마지막 커밋과 같거나 추적되지 않음)"
          ~en:"  (this file matches its last commit, or is untracked)"
    ; ds_esc_hint = ui_text state ~ko:"Esc:파일 목록" ~en:"esc back to files"
    ; ds_footer_hints = Masc_tui_keys.footer_hints_git_diff ~lang:state.ui_language
    ; ds_surface_key = "repository-changes-diff"
    ; ds_clamped = (fun scroll -> Repository_changes_diff_scroll scroll)
    }


(* Quota life state beside dispatchability: a dispatchable runtime whose
   provider side is refusing work for quota is "alive on paper" and the
   operator asked to see that distinction (2026-09-12). [resets_at] is the
   provider-stated deadline; its absence means a hard-quota rejection that
   claimed no reset -- it rests until the fallback cap after it was noted,
   and the next success on the scope clears it sooner. *)
let runtime_quota_badge ~ko (runtime : Masc.Tui_decode.runtime_option) =
  Option.map (fun label -> Theme.warn () ^ label ^ Ansi.reset)
    (runtime_quota_label ~ko runtime)

(* The other half of "alive on paper": this process saw a 429 on the runtime
   whose provider wait has not ended and no successful answer has cleared.
   It is a different fact from the quota
   window above, so a runtime can carry both. [resets_at] is the provider's
   own Retry-After and is present only while it is still ahead. *)


(* Which lanes list this runtime among their candidates, in the order the
   resolved projection holds them. The runtime detail asks the same question
   from two doors -- the catalog row and a lane's candidate row -- and a
   runtime that several lanes fall back to must answer both doors the same,
   so the answer is computed here rather than at either door. *)
let runtime_lanes_using (snapshot : Masc.Tui_decode.runtime_surface_snapshot)
    ~runtime_id =
  let open Masc.Tui_decode in
  snapshot.rss_resolved.rrs_lanes
  |> List.filter (fun (lane : runtime_resolved_lane) ->
         List.exists (String.equal runtime_id) lane.rrl_runtime_ids)
  |> List.map (fun (lane : runtime_resolved_lane) -> lane.rrl_id)

let runtime_all_rows (snapshot : Masc.Tui_decode.runtime_surface_snapshot) =
  let open Masc.Tui_decode in
  List.map
    (fun (runtime : runtime_option) ->
       runtime, runtime_lanes_using snapshot ~runtime_id:runtime.ro_id)
    snapshot.rss_resolved.rrs_runtimes


let tools_scrolled_for_lines state display_lines =
  tools_scroll_layout state ~count:(List.length display_lines)


(* The Config surface: runtime.toml exactly as the server reads it. The
   text is the truth an editor session starts from; editing itself hands
   the terminal to $EDITOR and posts back through the preview gate. *)
(* The prompt registry as a list plus the selected caller's effective template.
   Some prompts feed a Keeper turn while others, such as Librarian, belong to
   separate exact lanes. The detail pane keeps that distinction visible before
   an operator chooses to hand the same text to [$EDITOR]. *)
(* Which of the three the Config surface is showing, and that [p] moves
   between them. This used to appear on Themes alone, as a list of names with
   no mark on it: it said the key exists and not where pressing it lands, and
   a reader on runtime.toml was told neither. *)
(* The two keys this row draws in front of its strip. Named here because the
   row has to count them when it decides what is left for the file it is
   reading, and a second copy of the spelling would drift from this one. *)
let config_pane_keys (state : state) =
  Masc_tui_types.ui_text state ~ko:"9:런타임  p:다음  " ~en:"9:Runtime  p:next  "

(* A file's address said from a directory it is under. The Config panes read
   one file whose prefix is the server's masc root -- the same for every screen
   in a session, and named on the Config pane's own identity row -- so the
   title says the path from there and keeps its cells for the part that is
   this file. A path that is not under [root] is returned whole: there the
   address is the news. *)
let path_from_root ~root path =
  let root = if root = "" then "" else root ^ Filename.dir_sep in
  if root <> "" && String.starts_with ~prefix:root path then
    String.sub path (String.length root) (String.length path - String.length root)
  else path

let config_pane_tabs (state : state) =
  List.map
    (fun (pane, label) ->
      ( Masc_tui_types.config_pane_display_label ~lang:state.ui_language pane
          label
      , state.config_pane = pane
      , pane ))
    config_panes

let system_subnav_row ~cells (state : state) =
  let item surface ko en =
    pressable (Press_surface surface) (Masc_tui_types.ui_text state ~ko ~en)
  in
  let lang_chip =
    pressable Press_ui_language
      (Masc_tui_types.ui_text state
         ~ko:("[언어:" ^ Masc_tui_types.ui_language_code state.ui_language ^ " 전환]")
         ~en:("[Lang:" ^ Masc_tui_types.ui_language_code state.ui_language ^ " toggle]"))
  in
  let menu =
    "  "
    ^ Masc_tui_types.ui_text state ~ko:"시스템 메뉴:" ~en:"System views:"
    ^ " "
    ^ item Runtime "9:런타임" "9:Runtime"
    ^ " · "
    ^ item Resources "s:리소스" "s:Resources"
    ^ " · "
    ^ item Tools "t:도구·스킬" "t:Tools&Skills"
    ^ " · "
    ^ item Acting "A:활동" "A:Activity"
    ^ " · "
    ^ item System_logs "L:로그" "L:Logs"
  in
  (* The language chip is the row's last item. On a row too narrow for it the
     frame cut it in the middle ("[언어:KO…"), which reads as a broken label;
     it is left out whole instead. [:language] and a click toggle it as well. *)
  Message_layout.join_fitting ~sep:"   " ~cells [ menu; lang_chip ]

let config_pane_strip ~cols ~before ~after (state : state) =
  let keys = config_pane_keys state in
  Ansi.dim ^ keys ^ Ansi.reset
  ^ tab_strip
      (* [before] carries its own trailing gap -- every pane spells this row
         that way -- and nothing else sits between it and the keys. Counting
         another gap here reserved two cells the row never draws, which came
         straight out of the strip. *)
      ~width:(tab_strip_width ~cols ~before:(before ^ keys) ~after)
      ~press:(fun pane text -> pressable (Press_config_pane pane) text)
      (config_pane_tabs state)

(* What a Config pane's title row draws in [room] cells: the name the pane is
   known by, and the reading it has to add beside it.

   The reading gives way first and is cut with a mark. The name is not cut --
   it is drawn whole or it is not drawn. A cut name is not a reading: at
   eighty columns the row read "MASC Conf" and a mark, which says nothing the
   tab strip a row above does not already say, and it still spent the cells
   the strip needs to name the pane the reader is on -- one of eleven panes
   was drawn beside that stub, where at sixty columns, the name gone
   entirely, three were. This is the rule the footer states for its own row:
   what has a second way to be found gives way to what has none. *)
let config_pane_title_head ~room ~name ~reading =
  let cells text =
    Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)
  in
  let gap = cells tab_strip_gap in
  let name_row = name ^ tab_strip_gap in
  if cells name_row > room then ""
  else
    let left = room - cells name_row in
    if reading = "" || left <= gap then name_row
    else if cells reading + gap <= left then name_row ^ reading ^ tab_strip_gap
    else
      name_row
      ^ Masc_tui_message_layout.fit_width reading (left - gap)
      ^ tab_strip_gap


(* The whole title row a Config pane draws: its name, the strip, and the badge
   at the end -- with the file it is reading between them where the pane has
   one to show. Eleven panes built this row and nine of them
   spelled it identically, each appending the badge itself. That is also why
   none of them could tell the strip to leave room for it: at a hundred
   columns the strip took the row and the frame cut the badge, the clock and
   half of "(load failed)" with it. Built once, the row knows both halves. *)
let config_pane_title ~cols ?(path = []) ?(reading = "") ?(note = "") (state : state) =
  let name = here_path state ~path in
  let keys = config_pane_keys state in
  let piece text = if text = "" then "" else "  " ^ text in
  let cells text =
    Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)
  in
  let tail = "  " ^ connection_badge state in
  (* The note is the one part of this row whose width a workspace chooses: it
     is the path of the file the pane is reading. Everything else either
     cannot give way or knows how to. The badge says whether the screen is a
     live reading and has no way of saying it was shortened;
     the strip drops tabs and marks the cut. The note could do neither, so at
     eighty columns the row ran eighteen cells past the frame and the frame
     took them off the end -- the badge.

     It now takes what the row has left over the parts that cannot give way,
     and is cut the way the workspace paths two rows below it are cut: a
     path's deciding end is its tail, which [fit_middle] keeps. When nothing
     is left it goes entirely, gap and all, and the strip and the badge have
     the row. *)
  (* The strip's floor comes off the row before anything that can give way
     spends it. Bounding the note alone was not enough: a pane whose name
     carries a reading of its own -- prompts with the prompt it has selected,
     themes with its counts -- left the strip six cells for an eight-cell
     entry, and beside the acting pane at a hundred and fifty columns the row
     read "@p@" and "@them@" where it meant prompts and themes. The strip
     cannot say it was cut that far; it has already spent its marks. *)
  let strip_floor = tab_strip_min_width (config_pane_tabs state) in
  if cells keys + strip_floor + cells tail > framed_inner_width cols then
    (* The strip is what marks the pane the reader is on. Without it the path
       says so, unless the caller's path already goes further than the pane. *)
    let active_name =
      match path with
      | _ :: _ -> name
      | [] ->
          here_path state
            ~path:
              (config_pane_tabs state
               |> List.filter_map (fun (label, active, _) ->
                      if active then Some label else None))
    in
    let badge = surface_connection_badge state
        ~width:(max 0 (framed_inner_width cols - cells active_name - cells "  ")) in
    detail_heading ~cols ~lead:(Lead_text active_name) ~id:""
      ~after:[piece reading; piece keys; piece note] ~tail:badge
  else
  (* What the title gives way with is its tail: the reading first, and then
     the name whole. [config_pane_title_head] owns that order. *)
  let before =
    let room =
      framed_inner_width cols - cells keys - strip_floor - cells tail
    in
    config_pane_title_head ~room ~name ~reading
  in
  let note =
    if note = "" then ""
    else
      let room =
        framed_inner_width cols - cells before - cells keys
        - strip_floor - cells tail - cells "  "
      in
      Masc_tui_message_layout.truncate_middle (max 0 room) note
  in
  before ^ config_pane_strip ~cols ~before ~after:(piece note ^ tail) state
  ^ piece note ^ tail


let runtime_config_unmatched_current (state : state) =
  match runtime_config_edit_session state, state.runtime_config_view with
  | Some {rce_view=Config_edit_current _;rce_session={current=Some current;_};_}, Some reading
    when current.source_revision <> reading.rcv_metadata.source_revision -> Some current
  | None, _
  | Some {rce_view=Config_edit_draft;_}, _
  | Some {rce_view=Config_edit_current _;rce_session={current=None;_};_}, _
  | Some {rce_view=Config_edit_current _;rce_session={current=Some _;_};_}, _ -> None

let config_metadata_summary (state : state) =
  match runtime_config_unmatched_current state with
  | Some current -> [Masc_tui_runtime_config_view.Neutral,
      ui_text state ~ko:"현재 스냅샷 revision: " ~en:"Current snapshot revision: "
      ^ current.source_revision;
      Masc_tui_runtime_config_view.Warning,
      ui_text state ~ko:"이 스냅샷의 검증·적용 상태는 읽지 않음"
        ~en:"Validation and application state not read for this snapshot"]
  | None -> match state.runtime_config_view with
  | None -> []
  | Some reading ->
      let lines =
        Masc_tui_runtime_config_view.summary_lines ~ko:(state.ui_language = Lang_ko)
          reading.rcv_metadata
      in
      (match lines, state.runtime_config_view_error with
       | (tone, text) :: rest, Some _ ->
           (tone, ui_text state ~ko:"이전 관측 · " ~en:"Previous read · " ^ text) :: rest
       | _ -> lines)


(* The sheet's masthead: the product's name and a blank row. It carries no keys
   and no surface name: both scroll away with it, and both are said by rows
   that do not. The overlay's title row is fixed chrome that says whether hints
   are on, the footer row under the frame draws h and Esc, and the sheet's
   first section names the active surface two rows under this.

   It was a three-row box-drawing logo with a tagline and a rule under it, five
   rows at 72 columns and up. The title row above already says MASC Cheat
   Sheet, so on a 30-row terminal those rows came out of the keys the sheet is
   opened to read. *)
let help_masthead (_state : state) =
  [ "  " ^ Ansi.bold ^ Theme.accent () ^ "MASC"
    ^ Ansi.reset ^ Ansi.dim ^ " \xc2\xb7 Multi-Agent Shared Context" ^ Ansi.reset
  ; ""
  ]


(* The rows one help entry takes in [width] cells: [lead] (its key or usage,
   [lead_cells] wide) with the start of [text], and the rest of [text] on rows
   that start at [column], where every entry's text starts.

   The sheet cut each entry to its column. Two columns at 120 cells are 57
   each, and 23 of the 29 slash-command rows and 16 of the 20 Config rows ran
   past that, so a summary ended in an ellipsis where it said what the key
   does. A usage too long to leave [help_text_minimum_cells] beside it puts the
   text on the rows under it, rather than one word to a row. *)
let help_text_minimum_cells = 20

(* The key column: two cells of indent, the key padded to this, and a space. *)
let help_key_cells = 16

let help_entry_rows ~width ~lead ~lead_cells ~column text =
  let indent = String.make column ' ' in
  let under words =
    List.map
      (fun piece -> indent ^ piece)
      (Message_layout.wrap_words ~max_cells:(max 1 (width - column)) words)
  in
  let beside = width - lead_cells in
  if lead_cells > column && beside < help_text_minimum_cells then
    lead :: under text
  else
    match Message_layout.wrap_words ~max_cells:(max 1 beside) text with
    | [] -> [ lead ]
    | [ first ] -> [ lead ^ first ]
    | first :: rest -> (lead ^ first) :: under (String.concat " " rest)

(* The [?] help screen: every binding, grouped by the surface that answers
   it. The rows come from Masc_tui_keys -- the same table the footers read --
   so the two displays cannot drift apart. A key added to the dispatch gets
   its row there, once. *)
let help_lines ~width (state : state) =
  (* What the reader typed after [/]. An empty query matches everything, so
     the sheet is whole until something is typed. *)
  let query = Masc_tui_help.filter_query state.help_filter in
  let matches_query text = Masc_tui_pick_list.lowercase_contains ~needle:query text in
  (* A section's name without the mark that says it is the reader's own. *)
  let heading title =
    if String.ends_with ~suffix:Masc_tui_keys.here_marker title then
      String.sub title 0
        (String.length title - String.length Masc_tui_keys.here_marker)
    else title
  in
  (* A section's heading and each key's rows, a wrapped sentence kept with
     its key so a caller that parts the section does not part a key from the
     end of its own sentence. *)
  let section_parts (title, entries) =
    let is_current =
      String.ends_with ~suffix:Masc_tui_keys.here_marker title
    in
    (* One heading style, named as the key table names the section. The
       surface being read wears the filled mark; every other section the hollow
       one. The current section used to read "ACTIVE: OVERVIEW" in capitals,
       Global was renamed "GLOBAL NAVIGATION", and the rest were mixed case, so
       three spellings sat on one sheet and the table's own names appeared on
       only one of them. *)
    let header_line =
      if is_current then
        (Theme.info ()) ^ "\xe2\x97\x86 " ^ Ansi.bold ^ heading title ^ Ansi.reset
      else
        Ansi.dim ^ "\xe2\x97\x87 " ^ Ansi.reset ^ Ansi.bold ^ title ^ Ansi.reset
    in
    (* The key as the table spells it, in its own column. Each key used to be
       wrapped in brackets unless it already started and ended with one, so
       [/] for find and [ / ] for previous / next -- the bracket keys
       themselves -- sat on neighbouring rows looking like the same key. The
       column already sets the key apart, and the footer and the slash
       commands below draw theirs without brackets. *)
    ( header_line
    , List.map
         (fun (key, action) ->
           (* Padded in cells, not bytes. [%-*s] counts bytes, and the five
              legend sections put a glyph in this column, and a glyph is one
              cell in three bytes -- so its word started two columns left of
              the word beside a one-byte "?" a row down, and every mark row
              in the sheet sat at its own indent. The wrap column below already measured this
              cell with [display_width], which is why only the padding
              drifted. *)
           let key = String.trim key in
           let key_cell =
             key
             ^ String.make
                 (max 0 (help_key_cells - Message_layout.display_width key))
                 ' '
           in
           help_entry_rows ~width
             ~lead:
               (Printf.sprintf "  %s%s%s " (Theme.accent ())
                  key_cell Ansi.reset)
             ~lead_cells:(2 + Message_layout.display_width key_cell + 1)
             ~column:(2 + help_key_cells + 1) action)
         entries )
  in
  let section titled =
    let header_line, entry_rows = section_parts titled in
    (header_line :: List.concat entry_rows) @ [ "" ]
  in
  let commands =
    List.filter
      (fun (cmd : Masc_tui_command.command_help) ->
        matches_query (Masc_tui_command.help_usage cmd) || matches_query cmd.summary)
      Masc_tui_command.catalog
  in
  let slash_commands =
    match commands with
    | [] -> []
    | _ :: _ ->
    (Ansi.dim ^ "\xe2\x97\x87 " ^ Ansi.reset ^ Ansi.bold ^ "Slash commands" ^ Ansi.reset)
    :: List.concat_map
         (fun (cmd : Masc_tui_command.command_help) ->
           (* The column and its width come from the command module, which the
              [/help] list reads through the same two functions: the sheet
              colours the halves, it does not size them. *)
           let text = Masc_tui_command.help_usage cmd in
           let column = 2 + Masc_tui_command.help_summary_column in
           let summary_rows lead lead_cells =
             help_entry_rows ~width ~lead ~lead_cells ~column cmd.summary
           in
           if 2 + Message_layout.display_width text > width then
             (* The usage alone is wider than the panel, so it wrapped rather
                than being cut. What the frame's ellipsis took was the tail of
                the option list -- the part that says what the command
                accepts: at a hundred columns [/addons] lost three of its six
                subcommands and [/queue] two of its five, on the one screen
                whose whole job is to say what can be typed. *)
             List.map
               (fun piece -> "  " ^ (Theme.warn ()) ^ piece ^ Ansi.reset)
               (Message_layout.wrap_words ~max_cells:(max 1 (width - 2)) text)
             @ summary_rows (String.make column ' ') column
           else
             let padding = Masc_tui_command.help_summary_padding text in
             summary_rows
               (Printf.sprintf "  %s%s%s%s" (Theme.warn ()) text Ansi.reset padding)
               (2 + Message_layout.display_width (text ^ padding)))
         commands
    @ [ "" ]
  in
  (* After any live Candle details, the first key section is the reader's
     own surface.
     The eleven lines of slash commands used to sit above it and pushed the
     answer past the fold; they are a reference and read as one here.

     [help_sections] puts Global first where the surface has no section of its
     own, so the head of this list is the most relevant thing either way and
     nothing has to look for it by name. *)
  let candle =
    match Masc_tui_candle.summary_lines ~now:(Unix.gettimeofday ()) state.candle_observation with
    | [] -> []
    | _ :: _ when not (String.equal query "") -> []
    | lines ->
      (Ansi.bold ^ "Candle details" ^ Ansi.reset)
      :: (List.concat_map
            (fun line -> Message_layout.wrap_words ~max_cells:(max 1 width)
              (Terminal_text.single_line line)) lines @ [ "" ])
  in
  let _, cols = get_terminal_size () in
  let rows =
    candle
    @ (match
         Masc_tui_help.filter_sections ~query ~heading
           (Masc_tui_keys.help_sections_for_state ~cols state)
       with
       | [] -> slash_commands
       | first :: rest ->
           if Masc_tui_help.shows_everything state.help_filter state.help_scope
           then section first @ slash_commands @ List.concat_map section rest
           else
             (* The reader's own screen and nothing behind it. The sections
                after it are another screen's keys, and they followed the
                first with no line between a reader could stop at. *)
             let header_line, entry_rows = section_parts first in
             Masc_tui_help.one_section ~cols ~heading:header_line entry_rows)
  in
  match rows with
  | _ :: _ -> rows
  | [] ->
      [ Printf.sprintf "%s  No key or command matches \"%s\".%s" Ansi.dim
          (Terminal_text.single_line query) Ansi.reset ]


module Context_bars = Masc_tui_context_bars

(* One colour and one shade per producer, on every tab. Seven kinds took
   seven colours picked kind by kind: two of them were the terminal's default,
   so "Assistant text" and "Keeper instructions" were the same white row, and
   the shade beside them cycled with the row's position, which put the same
   shade on unrelated kinds and moved it when the sizes changed. Colour says
   where the bytes came in; the composition tree, the request tab's kinds and
   the proof tab's blocks all read from this one answer. *)
let context_source_style = function
  | Masc_tui_context_inspector.Turn_prompt_assembly -> Theme.warn ()
  | Masc_tui_context_inspector.Effective_tool_surface ->
      Theme.accent ()
  | Masc_tui_context_inspector.Provider_message_list ->
      Theme.category Theme.Slot_2

(* Shade as well as colour, so the groups stay apart where the terminal
   reports no colour support. *)
let context_source_glyph = function
  | Masc_tui_context_inspector.Turn_prompt_assembly -> Context_bars.bar_full
  | Masc_tui_context_inspector.Effective_tool_surface -> Context_bars.bar_dark
  | Masc_tui_context_inspector.Provider_message_list -> Context_bars.bar_medium

(* What the shades stand for, for a tab that draws them without a column
   naming the producer beside every row. *)
let context_source_legend =
  String.concat
    (Ansi.dim ^ "  \xc2\xb7  " ^ Ansi.reset)
    (List.map
       (fun source ->
         context_source_style source
         ^ context_source_glyph source
         ^ Ansi.reset ^ Ansi.dim ^ " "
         ^ Masc_tui_context_inspector.input_source_label source
         ^ Ansi.reset)
       Masc_tui_context_inspector.input_sources)

let context_component_style component =
  context_source_style (Masc_tui_context_inspector.input_source component)

(* The elbow a composition row hangs from. One producer with a single
   component gets a straight run rather than a branch that forks into
   nothing. *)
let context_branch ~index ~last =
  if last = 0 then " \xe2\x94\x80\xe2\x94\x80 "
  else if index = 0 then " \xe2\x94\x80\xe2\x94\xac "
  else if index = last then "  \xe2\x94\x94 "
  else "  \xe2\x94\x9c "

(* Everything a composition row spends outside the producer name and the
   component name: the indent, the elbow, the shade, the share and the
   estimated token figure ("≈" and six cells, then " tok") with their
   separators. Taken from the row below so the two move together. *)
let context_flow_row_chrome_cells = 2 + 4 + 1 + 1 + 1 + 6 + 2 + 11

let pad_cells ~width text =
  text
  ^ String.make
      (max 0 (width - Message_layout.display_width text))
      ' '


let context_evidence_style = function
  | Masc_tui_context_inspector.Verified_exact_text ->
      Ansi.bold ^ Theme.ok ()
  | Masc_tui_context_inspector.Serialized_turn_snapshot ->
      Ansi.bold ^ Theme.info ()
  | Masc_tui_context_inspector.Producer_digest_only ->
      Ansi.bold ^ Theme.category Theme.Slot_2
  | Masc_tui_context_inspector.Byte_count_only ->
      Ansi.bold ^ (Theme.recede ())


let context_evidence_badge evidence =
  Printf.sprintf "%s[ %s ]%s"
    (context_evidence_style evidence)
    (Masc_tui_context_inspector.input_evidence_label evidence)
    Ansi.reset


let context_split_width cols =
  let available = max 1 (framed_inner_width cols - 3) in
  min 62 (max 44 (available * 45 / 100))


(* A cluster wider than the body cannot fit on any physical row. Preserve its
   scalar values visibly rather than letting the frame replace it with an
   ellipsis. This is only needed for unusually wide individual clusters. *)
let context_escape_wide_clusters ~width text =
  if Message_layout.widest_grapheme_cells text <= width then text
  else
    let output = Buffer.create (String.length text) in
    let copy start stop = Buffer.add_substring output text start (stop - start) in
    let escape start stop =
      let rec loop offset =
        if offset < stop then begin
          let decoded = String.get_utf_8_uchar text offset in
          let length = Uchar.utf_decode_length decoded in
          if Uchar.utf_decode_is_valid decoded then begin
            let scalar = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
            if scalar <= 0xffff then Printf.bprintf output "\\u%04X" scalar
            else Printf.bprintf output "\\U%08X" scalar
          end else Printf.bprintf output "\\x%02X" (Char.code text.[offset]);
          loop (offset + length)
        end
      in
      loop start
    in
    Message_layout.iter_display_pieces text
      ~ascii:copy
      ~piece:(fun start stop cells ansi ->
        if ansi || cells <= width then copy start stop else escape start stop);
    Buffer.contents output

let context_wrapped_lines ~cols ~style text =
  let inner = framed_inner_width cols in
  let indent = min 2 (max 0 (inner - 1)) in
  let width = max 1 (inner - indent) in
  let text = context_escape_wide_clusters ~width text in
  Context_bars.wrap ~width text
  |> List.concat_map (Message_layout.split_cells ~max_cells:width)
  |> List.map (fun line -> String.make indent ' ' ^ style ^ line ^ Ansi.reset)

let context_detail_preview detail =
  Keeper_chat.bounded_http_error_ends detail |> Keeper_chat.terminal_safe_text

let context_error_lines ~cols ~label detail =
  context_wrapped_lines ~cols ~style:(Theme.bad ())
    (label ^ ": " ^ context_detail_preview detail)

let context_next_request_lines ?(runtime_details = fun _ -> []) ?(show_scale_note = false) ~cols ~scale
    (forecast : (Masc_tui_context_inspector.forecast, string) result) =
  let width = max 1 (framed_inner_width cols - 2) in
  let prose text =
    List.map
      (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset)
      (Context_bars.wrap ~width text)
  in
  let fact text =
    List.map (fun line -> "  " ^ line) (Context_bars.wrap ~width text)
  in
  let detail ~dim text =
    context_wrapped_lines ~cols ~style:(if dim then Ansi.dim else "") text
  in
  [ "  "
    ^ Context_bars.band ~width ~title:"NEXT REQUEST"
        ~caption:"what the next Agent Core request would carry, computed now"
  ]
  @ Masc_tui_next_request_band.lines ~runtime_details ~prose ~fact ~detail
      ~error:(context_error_lines ~cols)
      ~safe:Keeper_chat.terminal_safe_text ~safe_detail:context_detail_preview
      ~scale forecast
  @ (if show_scale_note
     then prose (Masc_tui_token_scale.note scale)
     else [])
  @ [ "" ]


(* The width of a token figure in the recent-turns rows. "1.2M" and the
   no-value mark both sit in it, so the rows line up on the same column. *)
let token_cell_width = 7

let context_composition_lines ?(runtime_details = fun _ -> []) ~cols ~turn_back
    ?forecast
    (selection : Masc_tui_context_inspector.selection) =
  let module Inspector = Masc_tui_context_inspector in
  (* The usable cells after the two-space indent every row carries. No floor
     above one: a floor wider than the pane makes the rows overrun and the
     frame cut them, and every row builder here is exact at any width. *)
  let width = max 1 (framed_inner_width cols - 2) in
  let bar_width = min 60 width in
  (* Every reading outside the composition band describes the newest turn. The
     band describes the newest turn that recorded an exact composition, which
     is not always the same turn -- so the two are labelled separately rather
     than drawn as one turn's report. *)
  (* The row the operator stepped back to, or the newest one. Every
     reading in this stack describes this record; the composition band
     below keeps its own rule about which row it measured. *)
  let record =
    match List.nth_opt selection.Inspector.rows turn_back with
    | Some stepped -> stepped
    | None -> selection.Inspector.latest
  in
  (* The sentences under a bar carry what its number means, so they are folded
     to the pane rather than cut by it. *)
  let prose text =
    List.map
      (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset)
      (Context_bars.wrap ~width text)
  in
  (* Same folding for a row of figures, which keeps its own colour. *)
  let fact text =
    List.map (fun line -> "  " ^ line) (Context_bars.wrap ~width text)
  in
  let selected_model =
    Option.value ~default:"model not observed" record.selected_model
  in
  (* Three short rows rather than one long one. Joined, the turn number and
     the timestamp fall off the right edge of a narrow pane, and the turn
     number is what an operator matches against the chat above. *)
  let identity =
    Printf.sprintf "  %s%s%s  %s%s%s" Ansi.bold
      (Keeper_chat.terminal_safe_text selected_model)
      Ansi.reset Ansi.dim
      (Keeper_chat.terminal_safe_text record.runtime_profile)
      Ansi.reset
  in
  let turn =
    Printf.sprintf "  %sturn #%d  ·  %s%s" Ansi.dim record.absolute_turn
      (Masc_domain.iso8601_of_unix_seconds record.ts)
      Ansi.reset
  in
  let trace =
    Printf.sprintf "  %s%s%s" Ansi.dim
      (Keeper_chat.terminal_safe_text record.trace_id)
      Ansi.reset
  in
  (* Every size on this screen is read in tokens: the window is sized in
     tokens and the input figure is recorded in tokens, while masc measured bytes before
     dispatch. The scale is this record's own wire body over its
     per-request count when it has both, else the page's median, else the
     fleet figure; the sentence under the rows names which. *)
  let scale = Masc_tui_token_scale.of_turn ~rows:selection.Inspector.rows record in
  (* The recorded input figure leads the band; the estimate from the
     prepared body follows it, with the bytes it was read from. *)
  let wire_lines =
    match record.request_wire_observation with
    | Some observation ->
        [ Printf.sprintf "  %s%s tok in the body masc sent  ·  %s%s" Ansi.dim
            (Masc_tui_token_scale.format_estimate scale observation.body_bytes)
            (Keeper_chat.terminal_safe_text observation.runtime_profile)
            Ansi.reset
        ]
    | None ->
        (* No body was serialized here, which is the ordinary case on a lane
           whose client assembles the request itself, not a failure to
           observe one. What masc handed that client is the composition
           above, when it belongs to this turn; a resumed client session
           already holds the earlier turns, so that figure is a ceiling on
           what went out and not a count of it. *)
        let handed =
          match selection.Inspector.attributed with
          | Some { Inspector.record = attributed; components; _ }
            when attributed.Turn_record.absolute_turn = record.absolute_turn ->
              let total =
                List.fold_left
                  (fun sum (component : Turn_record.input_component) ->
                    sum + component.bytes)
                  0 components
              in
              Printf.sprintf
                "; masc handed it the %s tok of prompt, tools and history \
                 above, which a resumed session already held in part"
                (Masc_tui_token_scale.format_estimate scale total)
          | Some _ | None -> ""
        in
        prose
          ("No body was serialized here: the runtime client assembled the \
            request itself" ^ handed ^ ".")
  in
  let non_request_token_lines count_label =
    match record.usage.input_tokens, record.context_window with
    | Some tokens, Some maximum when maximum > 0 ->
        [ Printf.sprintf
            "  %s %s  %s(this request's own share was not reported)%s"
            (Inspector.format_tokens tokens) count_label Ansi.dim Ansi.reset
        ; Printf.sprintf "  %sWindow %s tokens; no per-request figure to place in it%s"
            Ansi.dim (Inspector.format_tokens maximum) Ansi.reset
        ]
    | Some tokens, (None | Some _) ->
        [ Printf.sprintf "  %s %s  %s(window not observed)%s"
            (Inspector.format_tokens tokens) count_label Ansi.dim Ansi.reset
        ]
    | None, _ -> [ "  Context usage was not reported for this turn" ]
  in
  let token_lines =
    match record.usage.scope with
    | Runtime_usage_scope.Turn_total ->
        non_request_token_lines "tokens counted across the client turn"
    | Runtime_usage_scope.Conversation_cumulative ->
        non_request_token_lines "tokens counted across the conversation"
    | Runtime_usage_scope.Usage_scope_unavailable ->
        non_request_token_lines "tokens reported with unknown scope"
    | Runtime_usage_scope.Per_request -> (
        match record.usage.input_tokens, record.context_window with
        (* A figure above MASC's effective shaping ceiling cannot become a
           percentage of that ceiling. The client may report a different
           model window; its size is shown separately below. *)
        | Some tokens, Some maximum when maximum > 0 && tokens > maximum ->
            fact
              (Printf.sprintf
                 "%s recorded input tokens exceed the %s-token MASC shaping ceiling; \
                  ctx-fill against that ceiling is unavailable"
                 (Inspector.format_tokens tokens)
                 (Inspector.format_tokens maximum))
        | Some tokens, Some maximum when maximum > 0 ->
            fact
              (Printf.sprintf
                 "%s / %s tokens  ·  %.1f%% of MASC shaping ceiling  ·  %s left"
                 (Inspector.format_tokens tokens)
                 (Inspector.format_tokens maximum)
                 (float tokens /. float maximum *. 100.)
                 (Inspector.format_tokens (max 0 (maximum - tokens))))
            @ [ "  "
                ^ Context_bars.ratio_bar ~width:bar_width ~numerator:tokens
                    ~denominator:maximum
              ]
        | Some tokens, (None | Some _) ->
            [ Printf.sprintf "  %s input tokens; window not observed"
                (Inspector.format_tokens tokens) ]
        | None, _ -> [ "  Context usage was not reported for this turn" ])
  in
  let provider_context_lines =
    let occupied =
      Inspector.client_context_tokens ~scope:record.usage.scope
        ~input_tokens:record.usage.input_tokens
        ~output_tokens:record.usage.output_tokens
    in
    match occupied, record.provider_context_window with
    (* [Turn_record.of_json] admits only a positive window, so no guard here. *)
    | Some tokens, Some window ->
      fact
        (Printf.sprintf
           "Client reports active context %s / provider window %s tokens%s; \
            this is separate from MASC's shaping ceiling"
           (Inspector.format_tokens tokens)
           (Inspector.format_tokens window)
           (if tokens > window then " (over the reported window)" else ""))
    | None, Some window ->
      fact
        (Printf.sprintf "Client reports a %s-token model window; active context unavailable"
           (Inspector.format_tokens window))
    | (Some _ | None), None -> []
  in
  let cache_lines =
    let parts =
      List.filter_map Fun.id
        [ Option.map
            (fun n -> "cache read " ^ Inspector.format_tokens n)
            record.usage.cache_read_input_tokens
        ; Option.map
            (fun n -> "cache created " ^ Inspector.format_tokens n)
            record.usage.cache_creation_input_tokens
        ; Option.map
            (fun n -> "output " ^ Inspector.format_tokens n)
            record.usage.output_tokens
        ; Option.map
            (fun n -> "turn output " ^ Inspector.format_tokens n)
            record.turn_output_tokens
        ]
    in
    let label =
      match record.usage.scope with
      | Runtime_usage_scope.Turn_total -> "client turn total  "
      | Runtime_usage_scope.Conversation_cumulative -> "cumulative  "
      | Runtime_usage_scope.Usage_scope_unavailable -> "scope unknown  "
      | Runtime_usage_scope.Per_request -> ""
    in
    match parts with
    | [] -> []
    | _ -> prose (label ^ String.concat "  ·  " parts)
  in
  let history_lines =
    match record.model_input_window with
    | Some window ->
        let transmitted = window.transmitted_atoms in
        let total = window.total_atoms in
        let share =
          if total <= 0 then 0. else float transmitted /. float total *. 100.
        in
        (* The last projection in this turn does not record its runtime.
           Wire and durable shapes describe the measurement basis; neither
           attributes this range to the runtime in the turn's heading. *)
        let measured, label, reach_prose =
          match window.measurement with
          | Turn_record.Wire_shape ->
              ( "wire shape"
              , "projected range"
              , Printf.sprintf
                  "An atom is one user message, or one assistant message \
                   with the tool results it caused. %d older atoms were \
                   outside this projected range. A cut falls between atoms, \
                   so a tool result and the call it answers are kept together."
                  (max 0 (total - transmitted)) )
          | Turn_record.Durable_shape ->
              ( "durable shape"
              , "prepared history"
              , Printf.sprintf
                  "An atom is one user message, or one assistant message \
                   with the tool results it caused. %d older atoms were \
                   outside this prepared range. Measured on the history list \
                   prepared for a client; its final request is not measured \
                   here. A cut falls between atoms, so a \
                   tool result and the call it answers stay together."
                  (max 0 (total - transmitted)) )
        in
        prose "Last observed history range"
        @ [ Printf.sprintf "  %s%d of %d kept atoms%s  ·  %.1f%%  ·  %s%s%s" Ansi.bold
            transmitted total Ansi.reset share Ansi.dim measured Ansi.reset
        ; "  "
          ^ Context_bars.reach_bar ~width:bar_width ~transmitted ~total
              ~sent_style:(Theme.info ())
        ; "  "
          ^ Context_bars.reach_pointer ~label ~width:bar_width ~transmitted
              ~total
        ]
        @ prose "Range observation runtime: not recorded"
        @ prose reach_prose
    | None ->
        context_wrapped_lines ~cols ~style:(Theme.bad ())
          "Conversation history window was not observed"
  in
  let component_lines =
    match
      (if turn_back > 0 then
         Option.map
           (fun components ->
              Masc_tui_context_inspector.
                { record; components; turns_behind_latest = 0 })
           record.Turn_record.input_components
       else selection.Inspector.attributed)
    with
    | None ->
        (if turn_back > 0 then
           context_wrapped_lines ~cols ~style:(Theme.bad ())
             (Printf.sprintf "Turn #%d recorded no exact input composition"
                record.Turn_record.absolute_turn)
         else
           context_wrapped_lines ~cols ~style:(Theme.bad ())
             "No turn on this page recorded an exact input composition"
           @ context_wrapped_lines ~cols ~style:Ansi.dim
               "The readings above still describe the latest turn.")
    | Some { Inspector.record = attributed; components; turns_behind_latest } ->
        let total =
          List.fold_left
            (fun total (component : Turn_record.input_component) ->
              total + component.bytes)
            0 components
        in
        (* The gap is the whole point of showing it: without it an operator
           reads a turn the keeper left behind as the current one. *)
        let gap =
          if turns_behind_latest = 0 then []
          else
            context_wrapped_lines ~cols ~style:(Theme.warn ())
              (Printf.sprintf
                 "Measured on turn #%d, %d turns before the readings above."
                 attributed.Turn_record.absolute_turn turns_behind_latest)
        in
        (* Grouped by the producer the bytes entered through, in the order a
           turn assembles them, and biggest share first inside a group. The
           list was ranked by size alone: it named seven kinds in one column
           and never said that three of them are the prompt this turn built
           and three more are the conversation the provider was handed. *)
        let ranked =
          List.stable_sort
            (fun (left : Turn_record.input_component)
                 (right : Turn_record.input_component) ->
              compare right.bytes left.bytes)
            components
        in
        let by_source =
          List.filter_map
            (fun source ->
              match
                List.filter
                  (fun (component : Turn_record.input_component) ->
                    Inspector.input_source component.component = source)
                  ranked
              with
              | [] -> None
              | grouped -> Some (source, grouped))
            Inspector.input_sources
        in
        let bar =
          if total = 0 then []
          else
            [ "  "
              ^ Context_bars.stacked_bar ~width:bar_width
                  ~segments:
                    (List.concat_map
                       (fun (source, grouped) ->
                         List.map
                           (fun (component : Turn_record.input_component) ->
                             ( context_source_style source
                             , context_source_glyph source
                             , component.bytes ))
                           grouped)
                       by_source)
            ]
        in
        let source_width =
          List.fold_left
            (fun widest (source, _) ->
              max widest
                (String.length (Inspector.input_source_label source)))
            0 by_source
        in
        (* Wide enough for the longest component name on screen and no wider:
           the share and the byte count belong beside the name they describe,
           not at the far edge of a 140-column overlay. *)
        let label_cells =
          List.fold_left
            (fun widest (_, grouped) ->
              List.fold_left
                (fun widest (component : Turn_record.input_component) ->
                  max widest
                    (Message_layout.display_width
                       (Inspector.input_component_label component.component)))
                widest grouped)
            0 by_source
        in
        let label_width =
          min label_cells
            (max 10 (width - source_width - context_flow_row_chrome_cells))
        in
        (* The rows describe [attributed], which is not always the record the
           band above reads: when the keeper kept turning after its last
           attributed row, the composition is older than [latest] and its
           bytes must be read at its own ratio, not the latest turn's. *)
        let attributed_scale =
          Masc_tui_token_scale.of_turn ~rows:selection.Inspector.rows attributed
        in
        (* The row's size in the unit the window is sized in. The bytes it
           was read from stand once under the rows, beside the basis. *)
        let token_cell bytes =
          Printf.sprintf "\xe2\x89\x88%6s tok"
            (Inspector.format_tokens
               (Masc_tui_token_scale.estimate attributed_scale bytes))
        in
        let rows =
          List.concat_map
            (fun (source, grouped) ->
              let style = context_source_style source in
              let last = List.length grouped - 1 in
              List.mapi
                (fun index (component : Turn_record.input_component) ->
                  let share =
                    if total = 0 then 0.
                    else float component.bytes /. float total *. 100.
                  in
                  (* A component with bytes in it must not print as 0.0%: the
                     screen would then name a kind and deny it in the same
                     row. *)
                  let share_text =
                    if component.bytes > 0 && share < 0.05 then "<0.1%"
                    else Printf.sprintf "%.1f%%" share
                  in
                  String.concat ""
                    [ "  "
                    ; Ansi.dim
                    ; pad_cells ~width:source_width
                        (if index = 0 then Inspector.input_source_label source
                         else "")
                    ; context_branch ~index ~last
                    ; Ansi.reset
                    ; style
                    ; context_source_glyph source
                    ; " "
                    ; fit_width
                        (Inspector.input_component_label component.component)
                        label_width
                    ; Ansi.reset
                    ; Printf.sprintf " %6s  " share_text
                    ; Ansi.dim
                    ; token_cell component.bytes
                    ; Ansi.reset
                    ])
                grouped)
            by_source
        in
        (* Attributed and serialized figures are compared on the same turn,
           never across two, and they measure different things: the rows
           count the content of each block, the request counts the JSON it
           was wrapped in. On 2026-09-01 the attributed total ran about a
           fifth above the body across 1,556 turns. Naming both is what keeps
           an operator from reading the rows as the volume shipped. *)
        let against_wire =
          (match attributed.Turn_record.request_wire_observation with
           | Some observation when total > 0 && observation.body_bytes > 0 ->
               prose
                 (Printf.sprintf
                    "%s tok attributed here, %s tok in the serialized request. \
                     The rows count content and the request counts the JSON \
                     around it, so the two are compared on one turn and not \
                     expected to match. Read the shares as proportions and the \
                     request band as this turn's size."
                    (Masc_tui_token_scale.format_estimate attributed_scale total)
                    (Masc_tui_token_scale.format_estimate attributed_scale
                       observation.body_bytes))
           | Some _ ->
               prose
                 (Printf.sprintf
                    "%s tok attributed here; the serialized request recorded \
                     no size to set it against."
                    (Masc_tui_token_scale.format_estimate attributed_scale total))
           | None ->
               prose
                 (Printf.sprintf
                    "%s tok attributed here. No body was serialized on this \
                     lane, so there is no request figure to set it against."
                    (Masc_tui_token_scale.format_estimate attributed_scale total)))
          @ prose (Masc_tui_token_scale.note attributed_scale)
        in
        (* The arrow says the rows above are what the request below is made
           of. Drawn only when both readings are the same turn: where the
           composition is older, [gap] says so and an arrow into this turn's
           request would deny it. *)
        let into_request =
          if turns_behind_latest > 0 then []
          else
            let indent = String.make (2 + source_width + 2) ' ' in
            [ Ansi.dim ^ indent ^ "\xe2\x94\x82" ^ Ansi.reset
            ; Ansi.dim ^ indent ^ "\xe2\x96\xbc  serialized and dispatched"
              ^ Ansi.reset
            ]
        in
        gap @ bar @ rows @ into_request @ against_wire
  in
  (* Recorded per-request-scoped input, newest first, one row per decoded
     turn the page holds. A post-compaction context estimate travels with
     its provenance and gets its own sentence, so it is never read as a
     dispatched request's count. A provider that reports its usage across
     the whole conversation gets a row that says so rather than a number
     that looks like this turn's. *)
  let recent_turns_lines =
    let row index (recent : Inspector.recent_turn) =
      let ts = Masc_domain.iso8601_of_unix_seconds recent.ts in
      (* The sentence each row can honestly carry depends on why a figure is
         absent: a conversation-cumulative provider has a number that is not
         about this turn, while a per-request provider that reported nothing
         simply reported nothing. One None in the data covers both, so the
         scope -- which the record owns -- decides. *)
      let marker = if index = turn_back then Ansi.bold ^ Masc_tui_theme.Glyph.current_entry else " " in
      let usage_lines = match recent.scope, recent.input_tokens with
      | Runtime_usage_scope.Turn_total, _ ->
          [ marker ^ Ansi.dim
            ^ Printf.sprintf " #%-4d %s  client turn total, not per request" recent.turn ts
            ^ Ansi.reset ]
      | Runtime_usage_scope.Usage_scope_unavailable, _ ->
          [ marker ^ Ansi.dim
            ^ Printf.sprintf " #%-4d %s  usage scope unknown" recent.turn ts
            ^ Ansi.reset ]
      | Runtime_usage_scope.Conversation_cumulative, _ ->
          [ marker
            ^ Ansi.dim
            ^ Printf.sprintf
                " #%-4d %s  counted across the conversation, not per request"
                recent.turn ts
            ^ Ansi.reset
          ]
      | Runtime_usage_scope.Per_request, Some input -> (
          match recent.input_provenance with
          | Some Turn_input_provenance.Context_estimate ->
              [ marker ^ Ansi.dim
                ^ Printf.sprintf
                    " #%-4d %s  context estimate %s after compaction, not a \
                     dispatched request"
                    recent.turn ts (Inspector.format_tokens input)
                ^ Ansi.reset
              ]
          | Some Turn_input_provenance.Measured_request | None -> (
          fact
            (* fit_width, not %-7s: the cells hold the no-value mark, which is
               three bytes and one column, and byte padding would end the row
               two cells short of where the unset ones end. *)
            (Printf.sprintf "%s #%-4d %s  in %s  cache read %s  out %s"
               (if index = turn_back then Masc_tui_theme.Glyph.current_entry else " ")
               recent.turn ts
               (Message_layout.fit_width (Inspector.format_tokens input)
                  token_cell_width)
               (Message_layout.fit_width
                  (match recent.cache_read with
                   | Some tokens -> Inspector.format_tokens tokens
                   | None -> Masc_tui_theme.Glyph.no_value)
                  token_cell_width)
               (* The request's own output when reported; otherwise the
                  client turn's, marked so it is not read as one request's. *)
               (match recent.output_tokens, recent.turn_output_tokens with
                 | Some tokens, _ -> Inspector.format_tokens tokens
                 | None, Some tokens -> "turn " ^ Inspector.format_tokens tokens
                 | None, None -> Masc_tui_theme.Glyph.no_value))))
      | Runtime_usage_scope.Per_request, None ->
          [ (if index = turn_back then Ansi.bold ^ Masc_tui_theme.Glyph.current_entry else " ")
            ^ Ansi.dim
            ^ Printf.sprintf
                " #%-4d %s  input not reported for this turn"
                recent.turn ts
            ^ Ansi.reset
          ]
      in
      usage_lines
      @ (match
           Inspector.client_context_tokens ~scope:recent.scope
             ~input_tokens:recent.input_tokens ~output_tokens:recent.output_tokens,
           recent.provider_context_window
         with
         | Some tokens, Some window ->
           fact
             (Printf.sprintf "    client ctx %s/%s"
                (Inspector.format_tokens tokens)
                (Inspector.format_tokens window))
         | None, Some window ->
           fact
             (Printf.sprintf "    client window %s; active context unavailable"
                (Inspector.format_tokens window))
         | (Some _ | None), None -> [])
    in
    let trend = Inspector.recent_input_trend selection.Inspector.recent in
    let inputs = trend.Inspector.samples in
    let wrapped style text = context_wrapped_lines ~cols ~style text in
    let input_trend_lines =
      match inputs with
      | _ :: _ ->
          let bars, scale = match trend.Inspector.bounds with
            | None -> List.map (fun _ -> "") inputs, "no scale"
            | Some (minimum, maximum) ->
                let scaled_inputs = List.map (function
                  | Inspector.Input_count n -> n
                  | Inspector.Input_estimate n -> n
                  | Inspector.Input_invalid _ | Inspector.Input_unavailable -> minimum) inputs in
                Chart.sparkline_marks ~min:minimum ~max:maximum scaled_inputs,
                Printf.sprintf "scale %d–%d tokens" minimum maximum in
          let marks = List.map2 (fun sample bar -> match sample with
            | Inspector.Input_unavailable -> "·"
            | Inspector.Input_invalid _ -> "!"
            | Inspector.Input_estimate _ -> "~"
            | Inspector.Input_count 0 -> "0"
            | Inspector.Input_count _ -> bar) inputs bars |> String.concat "" in
          let legends =
            [ (List.exists (( = ) Inspector.Input_unavailable) inputs, "· unavailable")
            ; (List.exists (( = ) (Inspector.Input_count 0)) inputs, "0 recorded zero")
            ; (List.exists (function Inspector.Input_estimate _ -> true
                       | Inspector.Input_count _ | Inspector.Input_invalid _
                       | Inspector.Input_unavailable -> false) inputs,
               "~ context estimate, no dispatched request")
            ; (List.exists (function Inspector.Input_invalid _ -> true
                       | Inspector.Input_count _ | Inspector.Input_estimate _
                       | Inspector.Input_unavailable -> false) inputs,
               "! invalid negative count")
            ]
            |> List.filter_map (fun (present, text) -> if present then Some text else None) in
          wrapped "" ("Input by turn: " ^ marks)
          @ wrapped Ansi.dim (Printf.sprintf
              "Oldest to newest; %d measured and %d estimated of %d turns; %s%s."
              trend.Inspector.measured_count trend.Inspector.estimate_count
              (List.length inputs) scale
              (if legends = [] then "" else "; " ^ String.concat "; " legends))
          @ wrapped Ansi.dim
              "Records older than provenance may hold estimates among the unmarked values too."
      | [] -> []
    in
    let source_warning = match selection.Inspector.recent, selection.skipped_rows with
      | [], _ | _, Some 0 -> []
      | _ :: _, Some count ->
          wrapped Ansi.dim (Printf.sprintf
            "Source omitted %d unreadable records on this page; their positions are unknown."
            count)
      | _ :: _, None ->
          wrapped Ansi.dim "Source skipped-record count unavailable; page completeness unknown."
    in
    [ "  "
      ^ Context_bars.band ~width ~title:"RECENT TURNS"
          ~caption:
            "recorded input, one row per decoded turn"
    ]
    @ input_trend_lines
    @ source_warning
    @ List.concat (List.mapi row selection.Inspector.recent)
  in
  (* Read top to bottom as the turn is built: what came in, what was sent,
     how far back it reached, and what was recorded on the turns
     before it. The request stood above the components it is made of, so the
     screen opened on a total whose parts were three sections further down. *)
  [ identity; turn; trace; "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"WHAT WENT IN"
          ~caption:"the pieces this request was built from, in estimated tokens"
    ]
  @ component_lines @ [ "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"RECORDED INPUT"
          ~caption:"input value and observed serialized body, when available"
    ]
  @ token_lines
  @ (match record.usage.scope, record.usage.input_tokens with
     | Runtime_usage_scope.Per_request, Some _ ->
         context_wrapped_lines ~cols ~style:Ansi.dim
           "Recorded input can be a post-compaction context estimate; its provenance is not recorded."
     | Runtime_usage_scope.Per_request, None
     | (Runtime_usage_scope.Turn_total | Runtime_usage_scope.Conversation_cumulative
       | Runtime_usage_scope.Usage_scope_unavailable), _ -> [])
  @ provider_context_lines
  @ wire_lines
  @ cache_lines
  @ [ "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"HOW FAR BACK"
          ~caption:"how much of the kept conversation this request carried"
    ]
  @ history_lines
  @ [ "" ]
  @ Option.fold ~none:[] ~some:(context_next_request_lines ~runtime_details ~cols ~scale) forecast
  @ (if selection.Inspector.recent = [] then [] else recent_turns_lines) @ [ "" ]
  @ prose
      "Three readings of one turn, not three views of one number: none of \
       them is a breakdown of another, and they do not add up."



(* The pane body comes in two shapes. The plain one scrolls as one list and
   carries the line its highlight sits on, if it has one. The split one is two
   columns with independent windows: the list keeps the cursor, the detail
   column keeps its own scroll, and neither drags the other. *)
type context_pane_body =
  | Plain of string list * int option
  | Split of
      { common : string list
      ; left : string list
      ; right : string list
      }

(* The reading of one listed part, as the loop's part read left it. A part
   read for another Keeper, turn or item reads as not asked, so a pane never
   draws one part's text under another's row. *)
let context_part_view state (input : Masc_tui_context_inspector.provider_input)
    item =
  match state.context_inspector_keeper with
  | None -> Masc_tui_fetched.Absent
  | Some keeper ->
      Masc_tui_fetched.view_for ~equal:Masc_tui_context_inspector.same_part_key
        state.context_inspector_part
        ~key:
          { Masc_tui_context_inspector.part_keeper = keeper
          ; part_turn_ref = input.turn_ref
          ; part_item = item
          }

(* The part's text when it has been read, or one line saying where its read
   stands. *)
let context_part_text_or_status = function
  | Masc_tui_fetched.Ready text | Masc_tui_fetched.Stale (text, _) -> Ok text
  | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading ->
      Error (Ansi.dim ^ "Reading this part…" ^ Ansi.reset)
  | Masc_tui_fetched.Failed detail ->
      Error
        ((Theme.bad ()) ^ "This part could not be read: "
         ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset)

type context_retained_projection =
  { retained_text : string
  ; retained_width : int
  ; retained_palette_generation : int
  ; retained_table_frame : bool
  ; retained_lines : string list
  }

let context_retained_projection = ref None

let context_retained_body_lines ~width text =
  let generation = Masc_tui_terminal_palette.(snapshot_generation (snapshot ())) in
  match !context_retained_projection with
  | Some cached
    when cached.retained_text == text
         && cached.retained_width = width
         && cached.retained_palette_generation = generation
         && cached.retained_table_frame = !table_frame_enabled -> cached.retained_lines
  | Some _ | None ->
      let section_lines = function
        | Retained_view.Text text ->
            document_markdown ~width
              (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
        | Retained_view.Json payload ->
            Masc_tui_markdown_theme.code ~language:"json" ~width
              (Keeper_chat.terminal_safe_text ~preserve_newlines:true payload)
        | Retained_view.Marker label ->
            [ Ansi.bold ^ "▸ " ^ Keeper_chat.terminal_safe_text label ^ Ansi.reset ]
      in
      let lines = Retained_view.sections ~text
        |> List.concat_map (fun group -> section_lines group @ [ "" ]) in
      context_retained_projection := Some
          { retained_text = text; retained_width = width
          ; retained_palette_generation = generation
          ; retained_table_frame = !table_frame_enabled; retained_lines = lines };
      lines

let context_exact_item_detail_lines ~width ~scale ~part
    (item : Masc_tui_context_inspector.exact_input_item) =
  let module Inspector = Masc_tui_context_inspector in
  (* A message's text is wire JSON; its typed blocks are where the prose
     lives. Walking the blocks and rendering each part for what it is --
     markdown prose, a highlighted JSON payload, a structural label -- is the
     difference between reading the item and re-reading the envelope. *)
  let body =
    match context_part_text_or_status part with
    | Error status -> [ status ]
    | Ok text -> context_retained_body_lines ~width text
  in
  [ Ansi.bold ^ Theme.info () ^ "[ RETAINED ITEM ]" ^ Ansi.reset
  ; Ansi.bold ^ Inspector.exact_input_label item.kind ^ Ansi.reset
  ; Printf.sprintf "%s tok (%s)  ·  sha256 %s"
      (Masc_tui_token_scale.format_estimate scale item.bytes)
      (Inspector.exact_bytes item.bytes)
      (String.sub item.sha256 0 12)
  ; ""
  ; Ansi.dim ^ Masc_tui_token_scale.note scale ^ Ansi.reset
  ; ""
  ; Ansi.dim ^ "RETAINED PRE-DISPATCH CONTENT" ^ Ansi.reset
  ]
  @ body


(* Items grouped by kind, biggest group first, so the tab answers "what is
   this request made of" before it answers "what is item 34". Counted from the
   same items the list below draws, never from the composition tab's separate
   meter. *)
let context_exact_input_summary ~width ~scale
    (items : Masc_tui_context_inspector.exact_input_item list) =
  let module Inspector = Masc_tui_context_inspector in
  let tally = Hashtbl.create 8 in
  let order = ref [] in
  List.iter
    (fun (item : Inspector.exact_input_item) ->
      let key = Inspector.exact_input_category item.kind in
      let source = Inspector.exact_input_source item.kind in
      match Hashtbl.find_opt tally key with
      | None ->
          order := key :: !order;
          Hashtbl.replace tally key (1, item.bytes, source)
      | Some (count, bytes, source) ->
          Hashtbl.replace tally key (count + 1, bytes + item.bytes, source))
    items;
  let groups =
    List.filter_map
      (fun key ->
        match Hashtbl.find_opt tally key with
        | None -> None
        | Some (count, bytes, source) -> Some (key, count, bytes, source))
      (List.rev !order)
  in
  (* Producer first, then size, the way the composition tab groups the same
     bytes: a reader who learned there that the pink shade is the conversation
     handed to the provider reads it here without a second legend. *)
  let source_rank source =
    let rec index position = function
      | [] -> List.length Inspector.input_sources
      | candidate :: rest ->
          if candidate = source then position else index (position + 1) rest
    in
    index 0 Inspector.input_sources
  in
  let ranked =
    List.stable_sort
      (fun (_, _, left_bytes, left_source) (_, _, right_bytes, right_source) ->
        match compare (source_rank left_source) (source_rank right_source) with
        | 0 -> compare right_bytes left_bytes
        | order -> order)
      groups
  in
  let total =
    List.fold_left (fun sum (_, _, bytes, _) -> sum + bytes) 0 ranked
  in
  let bar_width = min 60 width in
  let bar =
    if total = 0 then []
    else
      [ "  "
        ^ Context_bars.stacked_bar ~width:bar_width
            ~segments:
              (List.map
                 (fun (_, _, bytes, source) ->
                   ( context_source_style source
                   , context_source_glyph source
                   , bytes ))
                 ranked)
      ]
  in
  let rows =
    List.map
      (fun (key, count, bytes, source) ->
        let share =
          if total = 0 then 0. else float bytes /. float total *. 100.
        in
        let share_text =
          if bytes > 0 && share < 0.05 then "<0.1%"
          else Printf.sprintf "%.1f%%" share
        in
        let label =
          key
          ^ String.make
              (max 0 (22 - Message_layout.display_width key))
              ' '
        in
        Printf.sprintf "  %s%s %s%s %s%3d %s%s  %9s  \xe2\x89\x88%6s tok  %6s"
          (context_source_style source)
          (context_source_glyph source)
          label Ansi.reset Ansi.dim count
          (if count = 1 then "item " else "items")
          Ansi.reset
          (Masc_tui_context_inspector.exact_bytes bytes)
          (Masc_tui_context_inspector.format_tokens
             (Masc_tui_token_scale.estimate scale bytes))
          share_text)
      ranked
  in
  ( [ "  "
      ^ Context_bars.band ~width ~title:"BY KIND"
          ~caption:
            (Printf.sprintf "%s, %s tok (%s) retained"
               (Masc_tui_message_layout.count_noun (List.length items) "item")
               (Masc_tui_token_scale.format_estimate scale total)
               (Masc_tui_context_inspector.exact_bytes total))
    ]
    @ bar @ rows
  , total )


(* Only the explicit response reader projects its complete Markdown. Keep
   one immutable projection across row counting, painting and scrolling; the
   request list must not pay for a body it no longer previews. Identity and
   display inputs belong in the key, including terminal theme changes. *)
type context_response_projection =
  { response_keeper : string option
  ; response_target : Masc_tui_context_inspector.target
  ; response_parts : Masc_tui_context_inspector.response_part list
  ; response_width : int
  ; response_palette_generation : int
  ; response_table_frame : bool
  ; response_lines : string list
  }

let context_response_projection = ref None

let context_response_target_equal left right =
  let module Inspector = Masc_tui_context_inspector in
  match left, right with
  | Inspector.Recent left, Inspector.Recent right -> left = right
  | Inspector.Pinned left, Inspector.Pinned right -> Ids.Turn_ref.equal left right
  | Inspector.Recent _, Inspector.Pinned _
  | Inspector.Pinned _, Inspector.Recent _ -> false

let context_response_body_lines ~width state parts =
  let generation = Masc_tui_terminal_palette.(snapshot_generation (snapshot ())) in
  match !context_response_projection with
  | Some cached
    when cached.response_keeper = state.context_inspector_keeper
         && context_response_target_equal cached.response_target state.context_inspector_target
         && cached.response_parts == parts
         && cached.response_width = width
         && cached.response_palette_generation = generation
         && cached.response_table_frame = !table_frame_enabled -> cached.response_lines
  | Some _ | None ->
      let lines = List.concat_map
          (function
            | Masc_tui_context_inspector.Reply_text text ->
                document_markdown ~width
                  (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
            | Masc_tui_context_inspector.Request_failure detail ->
                List.map (fun line -> (Theme.bad ()) ^ line ^ Ansi.reset)
                  (Context_bars.wrap ~width
                     ("Request failed: " ^ Keeper_chat.terminal_safe_text detail))
            | Masc_tui_context_inspector.Tool_steps rows ->
                List.concat_map (fun row ->
                    Context_bars.wrap ~width (Keeper_chat.terminal_safe_text row)
                    |> List.map (fun line -> Ansi.dim ^ line ^ Ansi.reset)) rows
            | Masc_tui_context_inspector.Reasoning_lines rows ->
                List.concat_map (fun row ->
                    Context_bars.wrap ~width ("· " ^ Keeper_chat.terminal_safe_text row)
                    |> List.map (fun line -> Ansi.dim ^ line ^ Ansi.reset)) rows)
          parts in
      context_response_projection := Some
          { response_keeper = state.context_inspector_keeper
          ; response_target = state.context_inspector_target
          ; response_parts = parts
          ; response_width = width
          ; response_palette_generation = generation
          ; response_table_frame = !table_frame_enabled
          ; response_lines = lines };
      lines

let context_response_lines ~cols state observation =
  let module Inspector = Masc_tui_context_inspector in
  let width = max 1 (framed_inner_width cols - 2) in
  let lines = match observation with
    | Inspector.Pending -> [ Ansi.dim ^ "  Response observation is still loading" ^ Ansi.reset ]
    | Inspector.Observed (Error detail) ->
        context_error_lines ~cols ~label:"Response unavailable" detail
    | Inspector.Observed (Ok { Inspector.parts; source }) ->
        let caption, empty = match source with
          | Inspector.Newest_history_page ->
              "response in the newest history page",
              "This turn's reply is not in the newest history page"
          | Inspector.Exact_turn_transcript ->
              "response from the retained turn transcript",
              "No assistant response was recorded in the retained turn transcript" in
        [ "  " ^ Context_bars.band ~width ~title:"RESPONSE" ~caption; "" ]
        @ (match parts with
           | [] -> [ Ansi.dim ^ "  " ^ empty ^ Ansi.reset ]
           | _ -> context_response_body_lines ~width state parts) in
  Plain (lines, None)

let context_response_summary observation =
  let module Inspector = Masc_tui_context_inspector in
  match observation with
  | Inspector.Pending -> Ansi.dim ^ "  Response loading · 4:response" ^ Ansi.reset
  | Inspector.Observed (Error _) -> (Theme.bad ()) ^ "  Response unavailable · 4:response" ^ Ansi.reset
  | Inspector.Observed (Ok { Inspector.parts = []; source }) ->
      (match source with
       | Inspector.Newest_history_page ->
           Ansi.dim ^ "  Response not in newest history page · 4:response" ^ Ansi.reset
       | Inspector.Exact_turn_transcript ->
           Ansi.dim ^ "  No assistant response in retained transcript · 4:response" ^ Ansi.reset)
  | Inspector.Observed (Ok { parts = _ :: _ as parts; source = _ }) ->
      let count, failures = List.fold_left (fun (count, failures) part ->
          count + 1,
          failures + (match part with
            | Inspector.Request_failure _ -> 1
            | Inspector.Reply_text _
            | Inspector.Tool_steps _
            | Inspector.Reasoning_lines _ -> 0))
          (0, 0) parts in
      let failure = if failures = 0 then "" else
          Printf.sprintf " · %d request failures" failures in
      (if failures = 0 then Ansi.dim else Theme.bad ())
      ^ Printf.sprintf "  Response · %d retained parts%s · 4:response" count failure ^ Ansi.reset


let context_exact_input_lines ~cols ~scale state ~response ~response_parts
    (input : Masc_tui_context_inspector.provider_input) =
  let module Inspector = Masc_tui_context_inspector in
  let items = Inspector.exact_input_items input in
  let width = max 1 (framed_inner_width cols - 2) in
  match state.context_inspector_exact with
  | Some index ->
      (match List.nth_opt items index with
       | None ->
           Plain
             ( [ (Theme.bad ()) ^ "  Selected input item is no longer present"
                 ^ Ansi.reset
               ]
             , None )
       | Some item ->
           let detail =
             context_exact_item_detail_lines ~width ~scale
               ~part:(context_part_view state input item) item
             |> List.map (fun line -> "  " ^ line)
           in
           Plain (detail, None))
  | None ->
      let identity =
        Printf.sprintf "  Exact provider input  %s  %s"
          (Keeper_chat.terminal_safe_text
             (Ids.Turn_ref.to_string input.turn_ref))
          (Masc_domain.iso8601_of_unix_seconds input.captured_at)
      in
      let wire =
        Printf.sprintf "  Prepared request  %s · %s · %s tok (%s) · %s"
          input.wire.provider input.wire.model
          (Masc_tui_token_scale.format_estimate scale input.wire.body_bytes)
          (Inspector.exact_bytes input.wire.body_bytes)
          (String.sub input.wire.body_sha256 0 12)
      in
      let summary, retained =
        context_exact_input_summary ~width ~scale items
      in
      let against_wire =
        (if retained > 0 && input.wire.body_bytes > 0 then
           [ Printf.sprintf
               "  %s%s tok (%s) retained here, %s tok (%s) in the serialized \
                request%s"
               Ansi.dim
               (Masc_tui_token_scale.format_estimate scale retained)
               (Inspector.exact_bytes retained)
               (Masc_tui_token_scale.format_estimate scale input.wire.body_bytes)
               (Inspector.exact_bytes input.wire.body_bytes)
               Ansi.reset
           ]
         else [])
        @ [ Ansi.dim ^ "  " ^ Masc_tui_token_scale.note scale ^ Ansi.reset ]
        @ (Context_bars.wrap ~width
             "Item token estimates can change with this ratio even when their bytes and SHA-256 stay identical."
           |> List.map (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset))
      in
      (* What came back for this exact request, to the extent the turn
         record observed it. The response text lives in the chat store and
         is not joined here; the counts and the finish reason are the
         turn's own. *)
      let response_line =
        match response with
        | None -> []
        | Some (record : Turn_record.t) ->
            let parts =
              List.filter_map Fun.id
                [ Option.map
                    (fun tokens -> "output " ^ Inspector.format_tokens tokens)
                    record.usage.output_tokens
                ; Option.map
                    (fun tokens -> "turn output " ^ Inspector.format_tokens tokens)
                    record.turn_output_tokens
                ; Option.map
                    (fun reason ->
                       "finish "
                       ^ Keeper_chat.terminal_safe_text reason)
                    record.finish_reason
                ]
            in
            match parts with
            | [] -> []
            | _ ->
                [ Printf.sprintf "  Response  ·  %s" (String.concat "  ·  " parts) ]
      in
      (* Usage belongs to the last reported request in the turn. A retained
         pre-dispatch snapshot can instead name a later failed attempt; the
         record has no response-to-capture ID, so do not label this as a hit
         on the prepared request above. All counts here are provider-reported,
         independent of the byte-to-token scale used for individual items. *)
      let cache_lines =
        match response with
        | None -> [ Ansi.dim ^ "  Provider cache usage unavailable" ^ Ansi.reset ]
        | Some (record : Turn_record.t) ->
            Context_bars.wrap ~width
              (Inspector.provider_usage_summary record.usage)
            |> List.map (fun line -> "  " ^ line)
      in
      let common =
        [ identity; wire ] @ response_line @ cache_lines @ [ "" ] @ summary @ against_wire
        @ [ context_response_summary response_parts; "" ]
      in
      (* One letter per row says where the item stands in the assembly. The
         wire is append-only, so the last message is this turn's newest
         addition and every earlier message is history the window carried
         forward. The system prompt can include changing turn observations;
         its position alone does not establish cacheability. The letter
         states a position on the wire, not a join
         the pane would have to invent. *)
      let last_message_index =
        List.fold_left
          (fun acc (index, (item : Inspector.exact_input_item)) ->
             match item.kind with
             | Inspector.Message _ -> Some index
             | Inspector.System_prompt | Inspector.Tool_schema _ -> acc)
          None
          (List.mapi (fun index item -> (index, item)) items)
      in
      let kind_letter index (item : Inspector.exact_input_item) =
        match item.kind with
        | Inspector.System_prompt -> "P"
        | Inspector.Tool_schema _ -> "S"
        | Inspector.Message _ ->
            if Some index = last_message_index then "N" else "H"
      in
      let rows width =
        List.mapi
          (fun index (item : Inspector.exact_input_item) ->
             let selected = index = state.context_inspector_cursor in
             let marker, style =
               if selected then ">", Theme.selection else " ", Ansi.reset
             in
             let label_width = max 8 (width - 22) in
             (* The list carries the producer's colour the summary above it
                groups by, except under the selection band, whose own styling
                owns the whole row. *)
             let label =
               fit_width (Inspector.exact_input_label item.kind) label_width
             in
             let label =
               if selected then label
               else
                 context_source_style (Inspector.exact_input_source item.kind)
                 ^ label ^ Ansi.reset
             in
             Printf.sprintf "%s %s %2d %s  %s  \xe2\x89\x88%6s tok%s" style
               marker (index + 1) (kind_letter index item) label
               (Inspector.format_tokens
                  (Masc_tui_token_scale.estimate scale item.bytes))
               Ansi.reset)
          items
      in
      let legend =
        ("  " ^ context_source_legend)
        :: (Context_bars.wrap ~width
              "P system prompt (may include turn observations) · H history · N new this turn · S schema"
           |> List.map (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset))
      in
      let common = common @ legend @ [ "" ] in
      if cols >= keeper_split_threshold_cols then
        let left_width = context_split_width cols in
        let cursor =
          Masc_tui_context_inspector.normalized_cursor
            ~count:(List.length items)
            state.context_inspector_cursor
        in
        let selected = List.nth_opt items cursor in
        (* The caret names the pane that hears j/k, the way the roster and
           the board say it; the keys themselves stay in the footer. *)
        let caret pane = if state.context_inspector_focus = pane then "▸ " else "" in
        let left =
          (Ansi.bold
           ^ "╭─ " ^ caret Left_pane ^ "REQUEST ITEMS"
           ^ Ansi.reset)
          :: (match rows left_width with
              | [] -> [ Ansi.dim ^ "  (no retained items)" ^ Ansi.reset ]
              | rows -> rows)
        in
        let right_width = max 8 (framed_inner_width cols - left_width - 3) in
        let selected_detail =
          match selected with
          | None -> [ Ansi.dim ^ "  Select an item with j/k" ^ Ansi.reset ]
          | Some item ->
              context_exact_item_detail_lines ~width:right_width ~scale
                ~part:(context_part_view state input item) item
        in
        (* The detail column starts at the top of its own window and keeps
           its own scroll. It used to be padded down to sit beside the
           selected row, which tied reading an item to standing on its row:
           the longer the list grew, the less of the item the pane could
           show. *)
        let right =
          (Ansi.bold
           ^ "╭─ " ^ caret Right_pane ^ "SELECTED INPUT"
           ^ Ansi.reset)
          :: selected_detail
        in
        Split { common; left; right }
      else
        let header =
          common
          @ [ "  "
              ^ Context_bars.band ~width ~title:"ITEMS"
                  ~caption:"in the order the request carries them"
            ]
        in
        let body =
          match rows (framed_inner_width cols) with
          | [] -> [ "  (this request carried no retained items)" ]
          | rows -> rows
        in
        let selected =
          if items = [] then None
          else
            Some
              (List.length header
              + min (List.length items - 1)
                  (max 0 state.context_inspector_cursor))
        in
        Plain
          ( header @ body
            @ [ ""
              ; Ansi.dim
                ^ "  Enter opens one retained item. The request digest identifies the pre-dispatch serialized body; each row carries its own retained digest."
                ^ Ansi.reset
              ]
          , selected )


let context_input_map_detail_lines ~width ~scale ~part_of
    (row : Masc_tui_context_inspector.input_map_row) =
  let module Inspector = Masc_tui_context_inspector in
  let digest =
    match row.digest with
    | None -> "digest  —"
    | Some digest ->
        "digest  " ^ String.sub digest 0 (min 12 (String.length digest))
  in
  let explanation =
    match row.evidence with
    | Inspector.Verified_exact_text ->
        "The retained part's SHA-256 and byte count match the producer's digest and byte count."
    | Inspector.Serialized_turn_snapshot ->
        "A same-turn pre-dispatch serialization snapshot exists, but no item-level join key binds this component row to one retained item. Inspect 2:request for the exact retained items."
    | Inspector.Producer_digest_only ->
        "The producer retained this prompt block's digest and byte count, but no same-turn exact snapshot is joined. The text cannot be verified or opened."
    | Inspector.Byte_count_only ->
        "Only the producer's component byte count is available. No exact provider snapshot is joined to this turn."
  in
  let wrap text =
    Message_layout.wrap_body ~max_cells:width
      ~sanitize:Keeper_chat.terminal_safe_text text
  in
  [ context_evidence_badge row.evidence
  ; Ansi.bold ^ Inspector.input_component_label row.component ^ Ansi.reset
  ; Printf.sprintf "%s tok (%s)  ·  %s"
      (Masc_tui_token_scale.format_estimate scale row.bytes)
      (Inspector.exact_bytes row.bytes)
      (Inspector.input_source_label row.source)
  ; Ansi.dim ^ digest ^ Ansi.reset
  ; ""
  ]
  @ wrap explanation
  @
  match row.verified_item with
  | None -> []
  | Some item ->
      [ ""; Ansi.dim ^ "VERIFIED TEXT" ^ Ansi.reset ]
      @ (match context_part_text_or_status (part_of item) with
         | Ok text -> wrap text
         | Error status -> [ status ])


let context_input_map_lines ~cols ~scale state (record : Turn_record.t)
    (provider_input : Masc_tui_context_inspector.provider_input Masc_tui_context_inspector.observation) =
  let module Inspector = Masc_tui_context_inspector in
  (* Only a verified row names a part, and only the joined input lists it. *)
  let part_of item =
    match provider_input with
    | Inspector.Observed (Ok input) -> context_part_view state input item
    | Inspector.Pending | Inspector.Observed (Error _) -> Masc_tui_fetched.Absent
  in
  let rows, exact_input, error_rows =
    match provider_input with
    | Inspector.Observed (Ok input) -> Inspector.input_map_rows record (Some input), Some input, []
    | Inspector.Pending ->
        ( Inspector.input_map_rows record None, None
        , [ Ansi.dim ^ "  Original input is still loading; verification is pending" ^ Ansi.reset ] )
    | Inspector.Observed (Error detail) ->
        ( Inspector.input_map_rows record None
        , None
        , context_error_lines ~cols ~label:"Exact input unavailable" detail )
  in
  match state.context_inspector_exact with
  | Some index ->
      (match List.nth_opt rows index with
       | Some ({ verified_item = Some item; _ } as row) ->
           let width = max 8 (framed_inner_width cols - 4) in
           let heading =
             Printf.sprintf "  %s%s%s  ·  %s tok (%s)  ·  %s  ·  %s"
               Ansi.bold
               (Inspector.input_component_label row.component)
               Ansi.reset
               (Masc_tui_token_scale.format_estimate scale row.bytes)
               (Inspector.exact_bytes row.bytes)
               (Inspector.input_source_label row.source)
               (context_evidence_badge row.evidence)
           in
           let digest =
             match row.digest with
             | None -> ""
             | Some digest ->
                 Printf.sprintf "  %sdigest %s%s" Ansi.dim
                   (String.sub digest 0 (min 12 (String.length digest)))
                   Ansi.reset
           in
           let body =
             (match context_part_text_or_status (part_of item) with
              | Ok text ->
                  Message_layout.wrap_body ~max_cells:width
                    ~sanitize:Keeper_chat.terminal_safe_text text
              | Error status -> [ status ])
             |> List.map (fun line -> "  " ^ line)
           in
           Plain (error_rows @ (heading :: digest :: "" :: body), None)
       | Some _ | None ->
           Plain
             ( error_rows @ [ (Theme.bad ())
                 ^ "  Exact text is not retained for this component" ^ Ansi.reset
               ]
             , None ))
  | None ->
      let identity =
        Printf.sprintf "  Provider request map  %s#%d"
          (Keeper_chat.terminal_safe_text record.trace_id)
          record.absolute_turn
      in
      let joined =
        match exact_input with
        | Some input when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
            Ansi.bold ^ Theme.ok () ^ "[ EXACT TURN JOIN ]" ^ Ansi.reset
        | Some _ | None ->
            Ansi.bold ^ Theme.warn () ^ "[ NO EXACT INPUT JOIN ]" ^ Ansi.reset
      in
      (* One name column for every row, sized by the widest badge on the
         page, so the token figures line up whatever each row's badge says. *)
      let badge_cells =
        List.fold_left
          (fun widest (row : Inspector.input_map_row) ->
             max widest (Inspector.input_evidence_badge_cells row.evidence))
          0 rows
      in
      let mapped width =
        let label_width = max 4 (width - 19 - badge_cells) in
        List.mapi
          (fun index (row : Inspector.input_map_row) ->
             let selected = index = state.context_inspector_cursor in
             let marker, selection =
               if selected then ">", Theme.selection else " ", Ansi.reset
             in
             let branch = if index = List.length rows - 1 then "└─" else "├─" in
             Printf.sprintf "%s %s %s %s%s%s \xe2\x89\x88%6s tok %s%s"
               selection marker branch
               (context_component_style row.component)
               (fit_width (Inspector.input_component_label row.component) label_width)
               Ansi.reset
               (Inspector.format_tokens
                  (Masc_tui_token_scale.estimate scale row.bytes))
               (context_evidence_badge row.evidence)
               Ansi.reset)
          rows
      in
      if cols >= keeper_split_threshold_cols then
        let left_width = context_split_width cols in
        let cursor =
          Masc_tui_context_inspector.normalized_cursor
            ~count:(List.length rows)
            state.context_inspector_cursor
        in
        let caret pane = if state.context_inspector_focus = pane then "▸ " else "" in
        let left =
          (Ansi.bold
           ^ "╭─ " ^ caret Left_pane ^ "CONTEXT STACK"
           ^ Ansi.reset)
          :: (match mapped left_width with
              | [] -> [ Ansi.dim ^ "  (no component attribution)" ^ Ansi.reset ]
              | mapped -> mapped)
        in
        let right_width = max 8 (framed_inner_width cols - left_width - 3) in
        let selected_detail =
          match List.nth_opt rows cursor with
          | None -> [ Ansi.dim ^ "  Select a block with j/k" ^ Ansi.reset ]
          | Some row ->
              context_input_map_detail_lines ~width:right_width ~scale ~part_of row
        in
        let right =
          (Ansi.bold
           ^ "╭─ " ^ caret Right_pane ^ "SELECTED BLOCK"
           ^ Ansi.reset)
          :: selected_detail
        in
        Split
          { common =
              [ identity
              ; "  " ^ joined
              ]
              @ error_rows
              @ [ Ansi.dim ^ "  " ^ Masc_tui_token_scale.note scale ^ Ansi.reset
                ; ""
                ]
          ; left
          ; right
          }
      else
        let header =
          [ identity
          ; "  " ^ joined
          ]
          @ error_rows
          @ [ Ansi.dim ^ "  " ^ Masc_tui_token_scale.note scale ^ Ansi.reset
            ; ""
            ; Ansi.bold ^ "  What the runtime prepared, and why" ^ Ansi.reset
            ]
        in
        let cursor =
          Masc_tui_context_inspector.normalized_cursor
            ~count:(List.length rows)
            state.context_inspector_cursor
        in
        let body =
          match mapped (framed_inner_width cols) with
          | [] -> [ "  (exact component attribution unavailable)" ]
          | mapped ->
              List.mapi
                (fun index line ->
                   if index <> cursor
                   then [ line ]
                   else
                     let detail =
                       match List.nth_opt rows cursor with
                       | None -> []
                       | Some row ->
                           context_input_map_detail_lines
                             ~width:(max 8 (framed_inner_width cols - 4))
                             ~scale ~part_of row
                           |> List.map (fun detail -> "    " ^ detail)
                     in
                     line
                     :: (Ansi.bold ^ "   ╰─ SELECTED BLOCK" ^ Ansi.reset)
                     :: detail)
                mapped
              |> List.concat
        in
        let selected =
          if rows = [] then None
          else
            Some
              (List.length header
              + min (List.length rows - 1)
                  (max 0 state.context_inspector_cursor))
        in
        Plain
          ( header @ body
            @ [ ""
              ; Ansi.dim
                ^ "  Enter opens VERIFIED text. Use 2:request for exact retained items."
                ^ Ansi.reset
              ]
          , selected )


(* The pane's rows, in either shape the tabs draw. A plain body carries the
   line its highlight sits on when it has one, so the window can follow it;
   only this module knows how many header rows a tab draws above its list,
   and a caller that guessed would scroll to the wrong row every time the
   header changed. *)
let context_inspector_content_lines ~cols state : context_pane_body =
  let runtime_details id =
    match state.runtime_catalog_reading with
    | Runtime_catalog_read | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ ->
      let notice = match state.runtime_catalog_reading with
        | Runtime_catalog_read -> []
        | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ ->
            [Masc_tui_types.runtime_catalog_reading_suffix ~ko:(state.ui_language = Lang_ko)
               state.runtime_catalog_reading]
        | Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_failed _ -> [] in
      notice @ (match List.find_opt (fun (r:Tui_decode.runtime_option) -> String.equal r.ro_id id) state.runtime_catalog with
       | None -> ["Connection/model configuration unavailable in the current catalogue"]
       | Some runtime ->
         (* Every line of this block is English, so the scope fallback is too. *)
         [ Printf.sprintf "Quota scope %s · %s" (runtime_quota_scope_label ~ko:false runtime) runtime.ro_provider
         ; "Connection " ^ runtime.ro_provider_id
         ; Printf.sprintf "Configured context %d tokens (%s) · model %s"
             runtime.ro_effective_max_context (Tui_decode.runtime_context_source_label runtime.ro_max_context_source) runtime.ro_model
         ; "Last observed configuration; the captured turn above retains its own runtime and context." ])
    | Runtime_catalog_loading -> ["Loading connection/model configuration…"]
    | Runtime_catalog_unread | Runtime_catalog_failed _ -> ["Connection/model configuration unavailable; refresh to read it"] in
  match state.context_inspector_reading with
  | None ->
      Plain
        ( [ (if state.context_inspector_loading then
                "  Loading provider-input evidence..."
              else "  No context reading has been requested.")
          ]
        , None )
  | Some (_, Masc_tui_context_inspector.Request_failed detail) ->
      Plain
        ( context_error_lines ~cols ~label:"Context read failed" detail
        , None )
  | Some (_, Masc_tui_context_inspector.Turn_read_failed { detail; forecast }) ->
      (match state.context_inspector_tab with
       | Masc_tui_context_inspector.Composition ->
           Plain
             ( context_error_lines ~cols ~label:"Composition unavailable" detail
               @ [ "" ]
               @ context_next_request_lines ~runtime_details ~cols
                   ~scale:Masc_tui_token_scale.fleet
                   ~show_scale_note:true forecast
             , None )
       | Masc_tui_context_inspector.Exact_input ->
           Plain
             ( context_error_lines ~cols ~label:"Exact input unavailable" detail
             , None )
       | Masc_tui_context_inspector.Response ->
           context_response_lines ~cols state (Masc_tui_context_inspector.Observed (Error detail))
       | Masc_tui_context_inspector.Input_map ->
           Plain
             ( context_error_lines ~cols ~label:"Input map unavailable" detail
             , None ))
  | Some (_, Masc_tui_context_inspector.Exact_read reading) ->
      let module Inspector = Masc_tui_context_inspector in
      let record = Inspector.inspected_record ~target:state.context_inspector_target
          (Inspector.Exact_read reading) in
      let prefix =
        [ "  Original question turn: "
          ^ Keeper_chat.terminal_safe_text (Ids.Turn_ref.to_string reading.turn_ref) ]
        @ (match reading.record with
           | Inspector.Pending -> [ Ansi.dim ^ "  Turn record is still loading" ^ Ansi.reset ]
           | Inspector.Observed (Error detail) ->
               context_error_lines ~cols ~label:"Turn record unavailable" detail
           | Inspector.Observed (Ok exact) ->
               if exact.skipped_rows = 0 then [] else
                 [ Ansi.dim ^ Printf.sprintf "  Exact record found; %d unreadable history rows were encountered"
                     exact.skipped_rows ^ Ansi.reset ])
      in
      let prepend = function
        | Plain (lines, selected) ->
            Plain (prefix @ lines, Option.map (fun row -> List.length prefix + row) selected)
        | Split body -> Split { body with common = prefix @ body.common }
      in
      let pending label = Plain ([ Ansi.dim ^ "  " ^ label ^ " is still loading" ^ Ansi.reset ], None) in
      let unavailable label detail =
        Plain
          ( context_error_lines ~cols
              ~label:(label ^ " unavailable") detail
          , None ) in
      let scale = Option.fold ~none:Masc_tui_token_scale.fleet
          ~some:(fun record -> Masc_tui_token_scale.of_turn ~rows:[ record ] record) record in
      let body = match state.context_inspector_tab with
        | Inspector.Response -> context_response_lines ~cols state reading.response
        | Inspector.Composition ->
            (match record with
             | None -> Plain ([], None)
             | Some record ->
                 let selection : Inspector.selection =
                   { latest = record
                   ; attributed = Option.map
                       (fun components -> { Inspector.record; components; turns_behind_latest = 0 })
                       record.input_components
                   ; recent = []
                   ; rows = [ record ]
                   ; skipped_rows = None } in
                 Plain (context_composition_lines ~cols ~turn_back:0 selection, None))
        | Inspector.Exact_input ->
            (match reading.provider_input with
             | Inspector.Pending -> pending "Original input"
             | Inspector.Observed (Error detail) -> unavailable "Original input" detail
             | Inspector.Observed (Ok input) ->
                 context_exact_input_lines ~cols ~scale state ~response:record
                   ~response_parts:reading.response input)
        | Inspector.Input_map ->
            (match record with
             | None -> Plain ([], None)
             | Some record -> context_input_map_lines ~cols ~scale state record
                 reading.provider_input)
      in
      prepend body
  | Some
      ( _
      , Masc_tui_context_inspector.Turn_read
          { selection; provider_input; response; forecast } ) ->
      (match state.context_inspector_target with
       | Masc_tui_context_inspector.Pinned _ ->
           Plain ([ "  Waiting for the requested immutable source" ], None)
       | Masc_tui_context_inspector.Recent turn_back ->
      (match state.context_inspector_tab with
       | Masc_tui_context_inspector.Response ->
           context_response_lines ~cols state (Masc_tui_context_inspector.Observed response)
       | Masc_tui_context_inspector.Composition ->
           Plain
             ( context_composition_lines ~runtime_details ~cols
                 ~turn_back ~forecast selection
             , None )
       | Masc_tui_context_inspector.Exact_input ->
           (match provider_input with
            | Ok input ->
                (* The same stepped/attributed record names the input,
                   token scale and response counters on this tab. *)
                let record = Masc_tui_context_inspector.viewing_record selection ~turn_back in
                let scale = Option.fold ~none:Masc_tui_token_scale.fleet
                    ~some:(Masc_tui_token_scale.of_turn ~rows:selection.Masc_tui_context_inspector.rows) record in
                context_exact_input_lines ~cols ~scale state
                  ~response:record
                  ~response_parts:(Masc_tui_context_inspector.Observed response) input
            | Error detail ->
                Plain
                  ( context_error_lines ~cols
                      ~label:"Exact input unavailable" detail
                  , None ))
       | Masc_tui_context_inspector.Input_map ->
           (
                (* The row the exact provider input was fetched for, so the
                   join on this tab stays honest; the keys walk the same
                   row's components. *)
                match
                  Masc_tui_context_inspector.viewing_record selection
                    ~turn_back
                with
                | None ->
                    (* The map is a per-component table; with no attribution
                       there are no rows to draw, and inventing them from the
                       latest turn's totals would state bytes nobody
                       measured. *)
                    Plain
                      ( context_wrapped_lines ~cols ~style:(Theme.bad ())
                          "No turn on this page recorded an exact input composition"
                      , None )
                | Some record ->
                    let scale =
                      Masc_tui_token_scale.of_turn
                        ~rows:selection.Masc_tui_context_inspector.rows record
                    in
                    context_input_map_lines ~cols ~scale state record
                      (Masc_tui_context_inspector.Observed provider_input))))


(* The rows a split body holds below the common summary: one pinned header
   row that carries both column titles and the focus caret, then the window
   the two columns share. The key handler and the frame both ask this,
   because keys that step past what the frame can show are the bug this pane
   was already carrying once. *)
let context_split_pane_height ~content_height ~common_len =
  max 0 (content_height - common_len - 1)

;;

let keeper_deletions_lines (state : state) ~cols =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let receipt = Option.fold ~none:[] ~some:(fun (_, message) -> [message])
      state.keeper_deletions_retry_receipt in
  let lines = match state.keeper_deletions with
    | None -> [ say "삭제 기록 조회 중…" "Loading deletion records…" ]
    | Some (Error detail) ->
      [ say "삭제 기록 조회 실패: " "Deletion records load failed: " ^ detail ]
    | Some (Ok inventory) ->
      let errors =
        List.map
          (fun error -> say "종료 기록 오류: " "Shutdown record error: " ^ error)
          inventory.errors in
      let selected = List.nth_opt inventory.operations state.keeper_deletions_cursor in
      errors @ (match selected with
        | None -> [ say "저장된 키퍼 삭제 기록이 없습니다." "No saved keeper deletion records." ]
        | Some row ->
          [Printf.sprintf "%d / %d · %s · %s"
             (state.keeper_deletions_cursor + 1) (List.length inventory.operations)
             (Keeper_control.deletion_keeper_name row)
             (Keeper_control.deletion_status ~ko row)]
          @ (if row.Keeper_control.can_retry then []
             else [ say "이 단계는 정리 재시도 대상이 아닙니다." "This phase cannot retry cleanup." ])
          @ [ say "종료 원장 원문 (설정·파일 정리 실패 원인 포함):"
                "Shutdown ledger record (including cleanup failure causes):" ]
          @ String.split_on_char '\n'
              (Yojson.Safe.pretty_to_string (Keeper_control.deletion_json row)))
  in
  List.concat_map (fun line ->
    Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols))
      (Terminal_text.single_line line)) (receipt @ lines)

(* The deletion overlay's keys for what it shows. [j/k] steps between records
   and [t] retries the selected record only when it can be retried
   (masc_tui.ml); the row named both on a failed read and on a single record,
   where neither does anything. The body said [r] and [t] a second time under
   the record, so those lines are gone and the row is the one place. *)
let keeper_deletions_hints (state : state) ~scrollable =
  let operations, can_retry =
    match state.keeper_deletions with
    | Some (Ok inventory) ->
      ( List.length inventory.operations
      , match List.nth_opt inventory.operations state.keeper_deletions_cursor with
        | Some row -> row.Keeper_control.can_retry
        | None -> false )
    | Some (Error _) | None -> (0, false)
  in
  let say korean english = if state.ui_language = Lang_ko then korean else english in
  String.concat "  "
    ((if operations > 1 then [ say "j/k:기록" "j/k:record" ] else [])
     @ (if scrollable then [ say "J/K/PgUp/PgDn:원문" "J/K/PgUp/PgDn:raw" ] else [])
     @ [ say "r:다시 읽기" "r:reload" ]
     @ (if can_retry && Option.is_none state.keeper_deletions_retry_receipt
        then [ say "t:정리 재시도" "t:retry cleanup" ] else [])
     @ [ say "Esc:닫기" "Esc:close" ])

;;

(* The panel behind [@]: who is mid-turn or just finished, from the turns
   poll. *)
let answering_lines (state : state) =
  let _, cols = get_terminal_size () in
  Masc_tui_answering.overlay
    ~ko:(state.ui_language = Lang_ko)
    ~width:(max 0 (framed_inner_width cols - 2))
    ~now:(Unix.gettimeofday ())
    ~chat_target:state.msg_target_keeper_name
    ~error:state.keeper_turns_error
    ~observed_at:state.keeper_turns_observed_at
    ~finishes:state.keeper_turn_finishes
    state.keeper_turns


(* The overlay ends in a fixed preview panel (divider + two lines): always
   drawn, so the list height never shifts with what the cursor is on — the
   fixed-chrome rule, applied before the panel exists rather than patched
   after. *)
let answering_preview_rows = 3

(* The two-pane surfaces -- Code and Resources -- opened on their list pane's
   header ("▸ /", "▸ Resources") with no row above it. Every other surface
   opens on its name and the connection badge, and the badge is the
   row that says the server has gone; on these two nothing did. The title row
   sits above both panes, so each pane gives up one row to it. *)
let pane_surface_title_rows = 1

let pane_surface_title (state : state) ~cols ~path =
  here_row ~cols state ~path ~readings:[] ~position:None

(* The row between the strip and the title, then the title. Every other
   surface draws that row first -- a gap on its own, the box's top edge beside
   a roster -- and its title under it. The two pane surfaces drew the title
   first and left the row to the pane, so alone on the surface the gap fell
   between the title and the pane's own heading: the title sat one row higher
   than on every other screen, and the heading read as a second, detached
   block. Beside the other pane the list's box draws its top edge on that row,
   so a split frame keeps it there. The row count is the same either way. *)
let pane_surface_header buf cols (state : state) ~path ~split =
  if not split then box_top buf cols;
  box_line buf cols (pane_surface_title state ~cols ~path)

let pane_surface_content_height ~rows =
  max 1 (framed_content_height ~rows - pane_surface_title_rows)

let models_account_reading ~provider = function
  | Account_emails_unread -> None, ["Account emails: not yet read"]
  | Account_emails_failed reason ->
      None, ["Account emails unread: " ^ Masc.Tui_terminal_text.sanitize_terminal_text reason]
  | Account_emails_read { emails; unreadable_rows } ->
      let email = List.assoc_opt provider emails
        |> Option.map Masc.Tui_terminal_text.sanitize_terminal_text in
      let notes = if unreadable_rows > 0 then
          [Printf.sprintf "Account emails: %d rows this build cannot read" unreadable_rows]
        else [] in
      email, notes

(* Read from the same published source observation as Models rows. Usage's
   loaded-runtime observation is deliberately not an input to this join. *)
let models_source_account_reading ~provider reading =
  let open Masc_tui_account_login in
  match reading with
  | None -> models_account_reading ~provider Account_emails_unread
  | Some reading ->
    match reading.rcv_account_emails with
    | Error detail -> models_account_reading ~provider (Account_emails_failed detail)
    | Ok Email_list_unrecognized ->
        models_account_reading ~provider
          (Account_emails_failed "the response carries no readable account email list")
    | Ok (Email_rows {rows; unattributed}) ->
        let unreadable_rows = unattributed + List.length (List.filter (function
          | _, Unrecognized -> true
          | _, (Email _ | Not_read _) -> false) rows) in
        let emails = List.filter_map (function
          | id, Email email -> Some (id, email)
          | _, (Not_read _ | Unrecognized) -> None) rows in
        let email, notes = models_account_reading ~provider
          (Account_emails_read {emails; unreadable_rows}) in
        let gap = match List.assoc_opt provider rows with
          | Some (Not_read Login_file_unreadable) -> Some "Account email unread: login file unavailable"
          | Some (Not_read Login_file_unrecognized) -> Some "Account email unread: unrecognized login file"
          | Some (Not_read Email_not_displayable) -> Some "Account email unread: invalid email"
          | Some (Not_read Email_not_reported) -> Some "Account email: not reported by the client"
          | Some (Not_read Environment_credential) -> Some "Account email: environment credential"
          | Some (Email _ | Unrecognized) | None -> None in
        email, (match gap with Some note -> note :: notes | None -> notes)

let studio_panel ~width ~title ~lines =
  let inner = max 1 (width - 4) in
  let heading = Message_layout.truncate_middle inner title in
  let border left right =
    Theme.recede () ^ left ^ draw_hline (max 0 (width - 2)) ^ right ^ Ansi.reset
  in
  [ Theme.info () ^ "┌ " ^ heading ^ " "
    ^ draw_hline (max 0 (width - Message_layout.display_width heading - 4))
    ^ "┐" ^ Ansi.reset ]
  @ List.map (fun line ->
      Theme.recede () ^ "│ " ^ Ansi.reset ^ fit_width line inner
      ^ Theme.recede () ^ " │" ^ Ansi.reset) lines
  @ [ border "└" "┘" ]

let detail_heading_rows ~first lines =
  let heading =
    List.map (fun line -> Theme.info () ^ Ansi.bold, "  " ^ line) lines
  in
  if first then heading else (Ansi.dim, "") :: heading

let detail_section_heading ?(first = false) title =
  detail_heading_rows ~first [ "[ " ^ title ^ " ]" ]

(* A detail page of headed blocks of [Page_line] lines. One label column
   serves every block, so the values of the whole page start at one cell and
   not at a different cell under each heading.

   A heading wraps like every other line of the page. Drawn as one row it is
   cut at the pane's edge, and the English half of a long title is what the
   cut takes: at 80 columns the configuration status page lost "Applied Keys)". *)
let detail_page ~width blocks =
  let label_cells =
    Masc_tui_page_reading.widest_label_cells (List.concat_map snd blocks)
  in
  let max_cells =
    max 1 (width - String.length Masc_tui_page_reading.detail_indent)
  in
  List.concat
    (List.mapi
       (fun index (title, lines) ->
          detail_heading_rows ~first:(index = 0)
            (Message_layout.wrap_words ~max_cells ("[ " ^ title ^ " ]"))
          @ Masc_tui_page_reading.rows ~label_cells ~max_cells lines)
       blocks)

(* The status page of the runtime configuration: the source it names, then the
   validation and application state the server read with it. A page with no
   reading to draw (none read yet, or a snapshot the read does not match) is the
   same first block with what is known. The rows come back styled, the width
   they are drawn at the frame's own. *)
let runtime_config_status_lines state ~cols =
  let module Line = Masc_tui_page_line in
  let module View = Masc_tui_runtime_config_view in
  let error =
    match state.runtime_config_view_error with
    | None -> []
    | Some detail -> [ Line.note ~tone:Line.Failure detail ]
  in
  let blocks =
    match runtime_config_unmatched_current state with
    | Some current ->
      [ ( View.source_heading ~ko:(state.ui_language = Lang_ko),
          error
          @ [ Line.note ~tone:Line.Attention
                (ui_text state ~ko:"이 스냅샷의 검증·적용 상태는 읽지 않음"
                   ~en:"Validation and application state not read for this snapshot");
              Line.fact (ui_text state ~ko:"원본" ~en:"Source") current.path;
              Line.fact (ui_text state ~ko:"현재 스냅샷 revision" ~en:"Current snapshot revision")
                current.source_revision ] ) ]
    | None ->
      (match state.runtime_config_view with
       | None ->
         [ ( View.source_heading ~ko:(state.ui_language = Lang_ko),
             error
             @ [ Line.note ~tone:Line.Quiet
                   (ui_text state ~ko:"설정을 아직 읽지 않음" ~en:"Configuration has not been read") ] ) ]
       | Some reading ->
         let source =
           if Option.is_some state.runtime_config_view_error then
             ui_text state ~ko:"이전 원본" ~en:"Previous source"
           else ui_text state ~ko:"원본" ~en:"Source"
         in
         View.detail_blocks ~ko:(state.ui_language = Lang_ko)
           ~notices:(error @ (if Option.is_some state.runtime_config_view_error then
             [Line.note ~tone:Line.Attention
                (ui_text state ~ko:"마지막으로 본 설정 · 지금 상태는 모름"
                   ~en:"Last observed settings · current status unknown")]
             else []))
           ~lead:[ Line.fact source reading.rcv_path ]
           reading.rcv_metadata)
  in
  detail_page ~width:(framed_inner_width cols) blocks

let detail_section_lines ?(first = false) title =
  let heading = [ "  " ^ Theme.info () ^ Ansi.bold ^ "[ " ^ title ^ " ]" ^ Ansi.reset ] in
  if first then heading else "" :: heading

let wrap_summary_column_items ~width items =
  let width = max 1 width in
  List.concat_map
    (fun (style, text) ->
       let clean = Terminal_text.single_line text in
       if Message_layout.display_width clean <= width then
         [ style, clean ]
       else
         match Message_layout.wrap_words ~max_cells:(max 1 (width - 2)) clean with
         | [] -> []
         | first :: rest ->
           (style, first)
           :: List.map (fun line -> style, "  " ^ line) rest)
    items

let split_summary_columns ~titled ~cols ~left_title ~left_rows ~right_title
    ~right_rows =
  let inner = max 1 (framed_inner_width cols) in
  let heading_style = Theme.recede () ^ Ansi.bold in
  if cols >= keeper_split_threshold_cols then begin
    let indent = "  " in
    let indent_width = 2 in
    let divider = " │ " in
    let divider_width = 3 in
    let body_width = max 2 (inner - indent_width) in
    let left_width = max 1 ((body_width - divider_width) / 2) in
    let right_width = max 1 (body_width - left_width - divider_width) in
    let column title rows ~width =
      let items = wrap_summary_column_items ~width rows in
      if titled then (heading_style, title) :: items else items
    in
    let left_lines = column left_title left_rows ~width:left_width in
    let right_lines = column right_title right_rows ~width:right_width in
    let total = max (List.length left_lines) (List.length right_lines) in
    let cell width (style, text) =
      fit_width (style ^ text ^ Ansi.reset) width
    in
    List.init total (fun index ->
      let left =
        Option.value (List.nth_opt left_lines index) ~default:(Ansi.reset, "")
      in
      let right =
        Option.value (List.nth_opt right_lines index) ~default:(Ansi.reset, "")
      in
      ( ""
      , indent
        ^ cell left_width left
        ^ Theme.recede () ^ divider ^ Ansi.reset
        ^ cell right_width right ))
  end
  else begin
    (* Under a title the rows nest two cells in; without one they start where
       the title would. *)
    let section title rows =
      let indent = if titled then "    " else "  " in
      let width = max 1 (inner - String.length indent) in
      let items =
        wrap_summary_column_items ~width rows
        |> List.map (fun (style, line) -> style, indent ^ line)
      in
      if titled then (heading_style, "  " ^ title) :: items else items
    in
    section left_title left_rows @ section right_title right_rows
  end

let runtime_substrate_tabs (state : state)
    ~(current : [ `Runtime_lanes | `Runtime_all | `Features | `Clients ]) =
  let ko = state.ui_language = Lang_ko in
  let lane_reading =
    Option.map
      (fun (snapshot : Masc.Tui_decode.runtime_surface_snapshot) ->
        let lane_count = List.length snapshot.rss_resolved.rrs_lanes in
        match current with
        | `Runtime_lanes | `Runtime_all ->
          if ko then Printf.sprintf "레인 %d, 후보 %d" lane_count (List.length snapshot.rss_candidates)
          else Printf.sprintf "%s, %s"
              (Message_layout.count_noun lane_count "lane")
              (Message_layout.count_noun (List.length snapshot.rss_candidates) "slot")
        | `Features | `Clients -> string_of_int lane_count)
      state.runtime_surface
  in
  let all_reading =
    Option.map
      (fun (snapshot : Masc.Tui_decode.runtime_surface_snapshot) ->
        string_of_int (List.length snapshot.rss_resolved.rrs_runtimes))
      state.runtime_surface
  in
  let feature_reading =
    Option.map
      (fun (snapshot : Masc.Tui_decode_lane_inventory.snapshot) ->
        let count = List.length snapshot.rows in
        match current with
        | `Features -> if ko then Printf.sprintf "%d개" count else Message_layout.count_noun count "feature"
        | `Runtime_lanes | `Runtime_all | `Clients -> string_of_int count)
      state.lane_inventory
  in
  let client_reading =
    Option.map
      (fun (snapshot : Masc.Tui_decode.clients_snapshot) ->
        let count = List.length snapshot.cls_clients in
        match current with
        | `Clients -> Printf.sprintf (if ko then "%d개 연결" else "%d attached") count
        | `Runtime_lanes | `Runtime_all | `Features -> string_of_int count)
      state.clients_surface
  in
  [ ( tab_entry_label (if ko then "후보 순서" else "Candidate orders") lane_reading
    , current = `Runtime_lanes
    , Press_runtime_mode Runtime_lanes )
  ; ( tab_entry_label (if ko then "전체 런타임" else "All runtimes") all_reading
    , current = `Runtime_all
    , Press_runtime_mode Runtime_all )
  ; ( tab_entry_label (if ko then "기능" else "Features") feature_reading
    , current = `Features
    , Press_standalone_lanes )
  ; ( tab_entry_label (if ko then "클라이언트" else "Clients") client_reading
    , current = `Clients
    , Press_surface Clients )
  ]

(* The Runtime title, its related destinations, the pieces of [after] and the
   connection badge last. It is laid out
   by [detail_heading] like the Activity row, so the badge stays whole, the
   pieces of [after] are left out whole from the end, and the strip draws in
   what they leave. The strip is whole or it is not drawn, and a strip that
   draws nothing takes its separator with it. Each row used to hand the strip
   the cells that were left after [after] and drew the row with [box_line],
   which cut the badge when [after] alone was wider than the row.

   [detail_heading] keeps the first piece of [after] and cuts it at its end
   when it does not fit, which leaves a clock as "1…". A reading time is no
   use cut, so an empty piece goes first: every real piece is then whole or
   left out. *)
let runtime_substrate_heading (state : state) ~cols ~title ~current ~after =
  let tabs = runtime_substrate_tabs state ~current in
  let cells text =
    Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)
  in
  let before = title ^ tab_strip_gap in
  detail_heading ~cols
    ~lead:
      (Lead_strip
         { floor = cells title
         ; draw =
             (fun width ->
               let room = width - cells before in
               if room < tab_strip_min_width tabs then title
               else before ^ tab_strip ~width:room ~press:pressable tabs)
         })
    ~id:"" ~after:("" :: after) ~tail:(connection_badge state)
