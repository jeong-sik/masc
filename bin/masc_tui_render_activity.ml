(** Activity (Acting events + evidence, System_logs + detail, and Keeper_calls)
    screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule
module Page_line = Masc_tui_page_line

let system_log_level_mark : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> "\xc2\xb7"
  | System_info -> "\xe2\x80\xa2"
  | System_warn -> "!"
  | System_error -> "\xc3\x97"
  | System_level_unknown _ -> "?"

(* How loudly a level reads on the detail page. The list draws the same four
   levels through [system_log_level_style]. *)
let system_log_level_tone : Masc.Tui_decode.system_log_level -> Page_line.tone = function
  | System_debug -> Page_line.Quiet
  | System_info -> Page_line.Plain
  | System_warn -> Page_line.Attention
  | System_error -> Page_line.Failure
  | System_level_unknown _ -> Page_line.Plain

(* A field the entry did not record reads as the empty mark, receded, so a
   missing value cannot be taken for a value that happens to be a dash. *)
let system_log_missing_fact label =
  Page_line.fact ~tone:Page_line.Quiet label Masc_tui_theme.Glyph.no_value

let system_log_fact label value =
  if String.equal (String.trim (Terminal_text.single_line value)) "" then
    system_log_missing_fact label
  else Page_line.fact label value

let system_log_optional_fact label = function
  | Some value -> system_log_fact label value
  | None -> system_log_missing_fact label

let system_log_detail_section = detail_section_heading

let system_log_detail_lines (state : state) ~seq ~width =
  let t korean english = ui_text state ~ko:korean ~en:english in
  let entry =
    Option.bind (system_logs_page state).lp_snapshot (fun snapshot ->
        List.find_opt
          (fun entry -> entry.Masc.Tui_decode.sl_seq = seq)
          snapshot.Masc.Tui_decode.sys_entries)
  in
  match entry with
  | None ->
      [ Theme.warn (),
        t "  이 로그 줄은 보관 중인 쪽에 더 없음 · 다시 읽거나 목록으로 돌아가기"
          "  This log entry is no longer present in the retained page; reload or return to the list."
      ]
  | Some entry ->
      let core_facts =
        [ system_log_fact (t "메시지" "Message") entry.sl_message
        ; Page_line.fact ~tone:(system_log_level_tone entry.sl_level) (t "수준" "Level")
            (system_log_level_mark entry.sl_level ^ " "
             ^ String.trim (Masc.Tui_decode.system_log_level_label entry.sl_level))
        ; system_log_fact (t "시각" "Timestamp") entry.sl_ts
        ; system_log_optional_fact (t "분류" "Category") entry.sl_category
        ]
      in
      let metadata_facts =
        [ system_log_optional_fact (t "Keeper" "Keeper") entry.sl_keeper
        ; system_log_optional_fact (t "턴" "Turn") (Option.map string_of_int entry.sl_turn)
        ; system_log_fact (t "모듈" "Module") entry.sl_module
        ; system_log_fact (t "출처" "Source")
            (Masc.Tui_decode.system_log_source_label entry.sl_source)
        ; system_log_fact (t "읽은 곳" "Origin")
            (System_logs_view.source_label (System_logs_view.source state.system_logs))
        ; system_log_fact (t "순번" "Sequence") (string_of_int entry.sl_seq)
        ]
      in
      let blocks =
        (match (system_logs_page state).lp_error with
         | None -> []
         | Some error ->
             [ ui_text state ~ko:"이전 관측 · 조회 실패" ~en:"Last read · refresh failed",
               [ Page_line.note ~tone:Page_line.Failure error ] ])
        @ [ t "1. 로그 메시지 · 핵심 상태" "1. Message & Severity", core_facts
        ; t "2. 발생 위치 · 메타데이터" "2. Origin & Context", metadata_facts
        ]
      in
      let details_title = t "3. 구조화 상세" "3. Structured Details" in
      (match entry.sl_details with
       | `Null ->
           detail_page ~width
             (blocks @ [ details_title, [ Page_line.note ~tone:Page_line.Quiet (t "없음" "none") ] ])
       | json ->
           detail_page ~width blocks
           @ system_log_detail_section details_title
           @ (document_json ~width (Yojson.Safe.pretty_to_string json)
              |> List.map (fun line -> Ansi.reset, "  " ^ line)))

let render_system_log_detail (state : state) seq =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (here_row ~cols state
       ~path:[ ui_text state ~ko:"로그" ~en:"logs"; Printf.sprintf "seq %d" seq ]
       ~readings:
         [ System_logs_view.source_label
             (System_logs_view.source state.system_logs) ]
       ~position:None);
  box_divider buf cols;
  let lines = system_log_detail_lines state ~seq ~width:(max 1 (framed_inner_width cols - 4)) in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min (system_logs_page state).lp_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~position:(Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines))
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:true System_logs));
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
let acting_tab_label ~ko = if ko then "활동" else "Events"

let activity_tabs ~ko ~on_logs : (string * bool * surface) list =
  [ (acting_tab_label ~ko, not on_logs, Acting)
  ; ((if ko then "로그" else "Logs"), on_logs, System_logs)
  ]

(* Keep the reading's identity, including the selected log source. Ordinary
   HTTP and the wall clock need no repeated header; exceptional connection
   evidence uses the shared bounded summary before it can displace identity. *)
let activity_heading (state : state) ~cols ~on_logs ~reading =
  let ko = state.ui_language = Lang_ko in
  let tabs = activity_tabs ~ko ~on_logs in
  let source = System_logs_view.source state.system_logs in
  (* The strip marks which of the two readings is on screen. Where it has no
     room the path names that reading in its place. *)
  let title =
    here_path state
      ~path:
        (List.filter_map
           (fun (label, active, _) -> if active then Some label else None)
           tabs)
  in
  let reading =
    if on_logs then
      ("  "
       ^ (match source with
          | Server -> ui_text state ~ko:"서버" ~en:"Server"
          | This_tui -> ui_text state ~ko:"이 TUI" ~en:"This TUI"))
      :: reading
    else reading
  in
  let before = here_path state ~path:[] ^ "  " and dot = "  \xc2\xb7" in
  let cells text =
    Message_layout.display_width (Masc_tui_theme.strip_sgr text)
  in
  let around = cells before + cells dot in
  let tail =
    match on_logs, source with
    | true, This_tui -> ""
    | (false, (Server | This_tui)) | (true, Server) ->
        (match reading_connection_notice state with
         | None -> ""
         | Some notice ->
             let room = max 0 (framed_inner_width cols - cells title - 2) in
             if cells notice <= room then notice
             else String.trim (reading_connection_summary ~width:room state))
  in
  detail_heading ~cols
    ~lead:
      (Lead_strip
         { floor = cells title
         ; draw =
             (fun width ->
               let room = width - around in
               if room < tab_strip_min_width tabs
               then title
               else
                 before
                 ^ tab_strip ~width:room
                     ~press:(fun surface text ->
                       pressable (Press_surface surface) text)
                     tabs
                 ^ dot)
         })
    ~id:"" ~after:reading ~tail

let render_system_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let entries = Masc_tui_types.visible_system_log_entries state in
  let total_entries = List.length entries in
  let loaded_entries =
    match (system_logs_page state).lp_snapshot with
    | None -> 0
    | Some snapshot -> List.length snapshot.sys_entries
  in
  (* The active filters ride in the header, so a page trimmed to twelve rows
     says why it is twelve rather than reading as a quiet ring.

     [verbose] is not a second field: [v] and [l] write the one floor, and
     verbose is the floor being DEBUG. The header spent thirteen cells saying
     that a second time, on a row that drops the tab strip at a hundred
     columns and the connection badge below eighty. *)
  let filter_pieces =
    let level =
      match (system_logs_page state).lp_min_level with
      | None -> ui_text state ~ko:"  수준\xe2\x89\xa5DEBUG" ~en:"  level\xe2\x89\xa5DEBUG"
      | Some floor ->
          Printf.sprintf
            (if state.ui_language = Lang_ko then "  수준\xe2\x89\xa5%s"
             else "  level\xe2\x89\xa5%s")
            (String.trim (Masc.Tui_decode.system_log_level_label floor))
    in
    let category =
      match (system_logs_page state).lp_category with
      | None -> []
      | Some category ->
          [ ui_text state ~ko:"  분류:" ~en:"  category:"
            ^ Terminal_text.single_line category ]
    in
    level :: category
  in
  (* What the reader set, on a read that brought back nothing. [l] and [v]
     write the floor and refetch; with the fetch failing the rows are the only
     other thing that moves, so pressing either redrew a frame identical to
     the one before it. The default floor is not something anyone pressed, and
     the note's other job -- saying why a short page is short -- needs a page,
     so at the default this stays off the row rather than spending its width
     on the surface that has least to spare. *)
  let set_filter_pieces =
    match (system_logs_page state).lp_min_level, (system_logs_page state).lp_category with
    | None, None -> []
    | _ -> filter_pieces
  in
  let header =
    match (system_logs_page state).lp_snapshot with
    | None ->
        let reading_note =
          match (system_logs_page state).lp_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        activity_heading state ~cols ~on_logs:true
          ~reading:(("  " ^ reading_note) :: set_filter_pieces)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        activity_heading state ~cols ~on_logs:true
          ~reading:
            ((if state.ui_language = Lang_ko then
                Printf.sprintf "  (%s개 중 %s개)"
                  (Masc_tui_value.Count.grouped snapshot.sys_total)
                  (Masc_tui_value.Count.grouped total_entries)
              else
                Printf.sprintf "  (%s of %s)"
                  (Masc_tui_value.Count.grouped total_entries)
                  (Masc_tui_value.Count.grouped snapshot.sys_total))
             :: (match snapshot.sys_latest_seq with
                 | None -> []
                 | Some seq -> [ Printf.sprintf "  seq %d" seq ])
             @ filter_pieces)
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
    "  " ^ Render_schedule.system_log_header_row
           ~ko:(state.ui_language = Lang_ko) ~layout:log_layout
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match (system_logs_page state).lp_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  "
          ^ (match (system_logs_page state).lp_snapshot with
             | None -> ""
             | Some _ -> ui_text state ~ko:"이전 관측 · " ~en:"Last read · ")
          ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The scroll row is a frame row while the page holds more entries than
     fit, and only then; the layout the keypress reads says so. *)
  let content_height =
    match scrolled_surface state ~cols System_logs with
    | Some s ->
        Masc_tui_scroll.content_height ~rows ~chrome:s.sc_chrome ~count:s.sc_count
          ~preview_keep:s.sc_preview_keep ~overflow_takes_row:s.sc_overflow_takes_row
    | None -> max 1 (rows - listing_chrome ~error:(system_logs_page state).lp_error)
  in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min (system_logs_page state).lp_scroll max_scroll) in
  let entries_window = Rows.of_list ~first:scroll ~height:content_height entries in
  if total_entries = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:(system_logs_page state).lp_snapshot ~error:(system_logs_page state).lp_error
      with
      (* [empty_page_of] returns [Page_failed] for an error with no snapshot
         and for an error over one, so a note about the title's count is true
         only in the second: with no snapshot the header draws no count at
         all and the note pointed at a row that is not on the screen. The
         shared note holds in both, and the staleness is already said twice
         above -- by the badge and by the error row this listing draws. *)
      | Page_failed -> page_failed_note ~ko:(state.ui_language = Lang_ko)
      | Page_unread ->
          (* The server page reads through a stream that stays open while the
             page is on screen, and its first frame is the first answer. *)
          page_unread_note_while ~ko:(state.ui_language = Lang_ko) ~reading:(Option.is_some state.system_log_stream)
      | Page_empty when loaded_entries > 0 ->
          ui_text state ~ko:"  (지금 분류 필터에 맞는 로그 줄 없음)"
            ~en:"  (no entries match the current category filter)"
      | Page_empty -> ui_text state ~ko:"  (로그 줄 없음)" ~en:"  (no entries)"
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
                      Theme.accent ()
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
          if idx = (system_logs_page state).lp_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if total_entries > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf
         (if state.ui_language = Lang_ko then "  [줄 %s]" else "  [entries %s]")
         (Masc_tui_scroll.window_text ~scroll ~height:content_height total_entries));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:false
            ~has_rows:(total_entries > 0) state.view));
  finish_surface state ~surface_key:"system-logs" ~rows:terminal_rows
      ~cols buf

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
  (* The name is a string the server sent. It is drawn as a step ahead of
     the last one, which the row lays out as given, so it is made printable
     here: as the id of the title this row replaced it was made printable by
     the title itself. *)
  let keeper_name =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> Terminal_text.single_line keeper.k_name
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let heading ~readings =
    here_row ~cols state
      ~path:[ keeper_name; ui_text state ~ko:"호출" ~en:"calls" ]
      ~readings ~position:None
  in
  let header =
    match state.keeper_calls with
    | Some snapshot when state.keeper_calls_loading ->
        heading
          ~readings:
            [ count_reading state Masc_tui_value.Count.Call
                (List.length snapshot.Masc.Tui_decode.kcs_entries)
            ; ui_text state ~ko:"다시 읽는 중" ~en:"refreshing" ]
    | None when state.keeper_calls_loading ->
        heading ~readings:[ ui_text state ~ko:"읽는 중" ~en:"loading" ]
    | None ->
        heading
          ~readings:
            [ field_missing_reading
                ~ko:(state.ui_language = Lang_ko)
                ~error:state.keeper_calls_error
            ]
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
          ~readings:
            [ count_reading state Masc_tui_value.Count.Call
                (List.length snapshot.Masc.Tui_decode.kcs_entries)
            ; freshness ]
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    ui_text state ~ko:"  j/k 줄 단위 · 원문 필드: tool | input | output"
      ~en:"  j/k rows · exact fields: tool | input | output"
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
            (if state.ui_language = Lang_ko then
               "  다른 Keeper 를 가리킨 %d줄은 그리지 않음"
             else "  %d row(s) named another keeper and were not drawn")
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
    let value =
      if String.equal value "" then ui_text state ~ko:"(빈 값)" ~en:"(empty)"
      else value
    in
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
           Printf.sprintf
             (if state.ui_language = Lang_ko then "  #%d %s %s · %s · 턴 %s"
              else "  #%d %s %s · %s · turn %s")
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
        ui_text state ~ko:"  (호출 기록 조회 중…)" ~en:"  (loading exact call records...)"
      else
      match (state.keeper_calls, state.keeper_calls_error) with
      | _, Some _ -> page_failed_note ~ko:(state.ui_language = Lang_ko)
      | None, None -> page_unread_note ~ko:(state.ui_language = Lang_ko)
      | Some _, None -> ui_text state ~ko:"  (기록된 호출 없음)" ~en:"  (no calls recorded)"
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
      Printf.sprintf "[%s · %s]" (count_reading state Masc_tui_value.Count.Call shown) window
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
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view));
  finish_surface state ~clamped:(Keeper_calls scroll) ~surface_key:"keeper-calls" ~rows:terminal_rows ~cols buf

(* The runtime's event feed, newest first, for watching every keeper act at
   once. Rows are built from the events the TUI holds; the filter decides
   which kinds draw; a completed call is paired with its start for a
   duration. Scrolling away from the newest row freezes the view and counts
   what arrives above it, so an operator reading the past is not pushed off
   it by the present. *)
let acting_evidence_intro (state : state) =
  [ Ansi.dim
    , ui_text state ~ko:" 고른 이벤트의 스냅샷 · 새로 온 이벤트가 이 화면을 바꾸지 않음"
        ~en:" Selected event snapshot; new arrivals do not replace this reading"
  ; Ansi.dim
    , Printf.sprintf
        (if state.ui_language = Lang_ko then " 보유한 이벤트: %d개 (고른 것은 고정)"
         else " Retained feed events: %d (selection pinned)")
        (List.length state.acting)
  ; Ansi.dim, " " ^ Terminal_text.single_line
      (observer_replay_description ~ko:(state.ui_language = Lang_ko)
         ~source_loss:state.observer_source_loss state.observer_replay)
  ]

(* The here row above the intro. *)
let acting_evidence_here_rows = 1

let acting_evidence_content_height ~rows ~intro =
  (* Top and divider surround the here row and the intro the renderer consumes. *)
  max 1
    (rows
     - (2 + acting_evidence_here_rows + List.length intro
        + listing_rows_below_the_body))

let acting_evidence_page_rows state ~terminal_rows =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let intro = acting_evidence_intro state in
  Masc_tui_scroll.page_step ~height:(acting_evidence_content_height ~rows ~intro)

let render_acting_evidence (state : state) entry =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let intro = acting_evidence_intro state in
  (* A field the event did not carry, as opposed to one it carried empty. *)
  let not_carried = ui_text state ~ko:"실려 오지 않음" ~en:"not carried" in
  box_top buf cols;
  box_line buf cols
    (here_row ~cols state
       ~path:[ acting_tab_label ~ko:(state.ui_language = Lang_ko)
             ; ui_text state ~ko:"증거" ~en:"evidence" ]
       ~readings:[] ~position:None);
  List.iter (fun (style, line) -> box_line_styled buf cols ~style line) intro;
  box_divider buf cols;
  let lines =
    detail_section_lines ~first:true
      (ui_text state ~ko:"1. 이벤트 식별 · 실행 컨텍스트"
         ~en:"1. Event Identity & Execution Context")
    @ ((ui_text state ~ko:"TUI 수신 시각" ~en:"TUI received at",
         Some (Masc_domain.iso8601_of_unix_seconds entry.Masc_tui_acting.ae_at))
       :: Masc_tui_acting.evidence_fields entry
       |> List.concat_map (fun (label, value) ->
           let prefix = "  " ^ label ^ ": " in
           let text = match value with
             | None -> not_carried
             | Some "" -> ui_text state ~ko:"(빈 문자열)" ~en:"(empty string)"
             | Some value -> Terminal_text.single_line value in
           let continuation = String.make (Message_layout.display_width prefix) ' ' in
           match Message_layout.wrap_words
                   ~max_cells:(max 1 (framed_inner_width cols - Message_layout.display_width prefix)) text with
           | [] -> [prefix]
           | first :: rest -> (prefix ^ first) :: List.map (fun line -> continuation ^ line) rest))
  in
  let io_lines =
    match entry.Masc_tui_acting.ae_event with
    | Masc_tui_observer.Keeper_tool_call call ->
        let json label = function
          | None -> ["  " ^ label ^ ": " ^ not_carried]
          | Some value ->
              ("  " ^ label
               ^ ui_text state ~ko:" (보낸 쪽이 가린 JSON)" ~en:" (producer-redacted JSON)")
              :: (document_json ~width:(max 1 (framed_inner_width cols - 3))
                    (Yojson.Safe.pretty_to_string value)
                  |> List.map (fun line -> "  " ^ line)) in
        let preview label = function
          | None -> ["  " ^ label ^ ": " ^ not_carried]
          | Some text ->
              ("  " ^ label
               ^ ui_text state ~ko:" (보낸 쪽이 가린 미리보기)" ~en:" (producer-redacted preview)")
              :: (document_markdown ~width:(max 1 (framed_inner_width cols - 3))
                    (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
                  |> List.map (fun line -> "  " ^ line)) in
        detail_section_lines
          (ui_text state ~ko:"2. 입출력 관측 기록" ~en:"2. Input / Output Observations")
        @ json (ui_text state ~ko:"입력" ~en:"Input") call.kt_tool_args
        @ preview (ui_text state ~ko:"입력 미리보기" ~en:"Input preview") call.kt_tool_args_preview
        @ json (ui_text state ~ko:"출력" ~en:"Output") call.kt_tool_result
        @ preview (ui_text state ~ko:"출력 미리보기" ~en:"Output preview")
            call.kt_tool_output_preview
    | Masc_tui_observer.Internal_agent_runs_changed _ | Masc_tui_observer.Workspace_store_changed _ | Masc_tui_observer.Dataset_changed _ | Masc_tui_observer.Gate_connector_changed _ | Masc_tui_observer.Keeper_event_queue_changed _ | Masc_tui_observer.Board_changed _ | Masc_tui_observer.Approval_change _ | Masc_tui_observer.Agent_core _
    | Masc_tui_observer.Keeper_heartbeat _ | Masc_tui_observer.Keeper_turn_complete _
    | Masc_tui_observer.Keeper_turn_observation _ | Masc_tui_observer.Keeper_composite_changed _ | Masc_tui_observer.Keeper_metrics_appended _
    | Masc_tui_observer.Keeper_chat_appended _ | Masc_tui_observer.Keeper_memory_journal_appended _ | Masc_tui_observer.Keeper_runtime_journal_appended _
    | Masc_tui_observer.Keeper_chat_stream_frame _
    | Masc_tui_observer.Keeper_turn_stream_frame _
    | Masc_tui_observer.Keeper_waiting_inventory_changed _ | Masc_tui_observer.Keeper_async_requests_changed _ | Masc_tui_observer.Keeper_skill_activations_changed _ | Masc_tui_observer.Keeper_roster_change _ | Masc_tui_observer.Keeper_turn_changed _ | Masc_tui_observer.Fusion_run_status _
    | Masc_tui_observer.Lane_resource _ | Masc_tui_observer.Snapshot _ | Masc_tui_observer.Execution_snapshot | Masc_tui_observer.Other _ -> []
  in
  let lines = lines @ io_lines in
  let content_height = acting_evidence_content_height ~rows ~intro in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = min max_scroll (max 0 state.acting_detail_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for i = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + i) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols line
  done;
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf
       (if state.ui_language = Lang_ko then "  [증거 줄 %s]" else "  [evidence rows %s]")
       (Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines)));
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols
      ~hints:(Masc_tui_keys.acting_evidence_hints ~lang:state.ui_language));
  finish_surface state ~clamped:(Acting_detail_scroll scroll)
    ~surface_key:"acting-evidence" ~rows:terminal_rows ~cols buf

(* Only exceptional feed/replay observations spend body rows. Each fact has
   its own row, so a narrow feed failure cannot hide a dropped/unseen count.
   Their number is also the paging projection; rendering does not guess it. *)
let acting_notices (state : state) ~trace_unavailable =
  let retained =
    if state.acting = [] then ""
    else ui_text state ~ko:" · 이전 이벤트" ~en:" · retained events"
  in
  let feed =
    match state.observer with
    | Observer_live _ -> None
    | Observer_off -> Some (ui_text state ~ko:"수신 꺼짐" ~en:"Feed off" ^ retained)
    | Observer_opening -> Some (ui_text state ~ko:"수신 연결 중" ~en:"Feed opening" ^ retained)
    | Observer_closed_after_live { events; reason; _ } ->
        Some (Printf.sprintf "%s %d%s · %s"
          (ui_text state ~ko:"수신 닫힘" ~en:"Feed closed") events retained
          (Terminal_text.single_line reason))
    | Observer_closed_before_answer { reason; _ } ->
        Some (ui_text state ~ko:"수신 시작 실패" ~en:"Feed failed to open"
          ^ retained ^ " · " ^ Terminal_text.single_line reason)
  in
  let dropped =
    if state.acting_dropped = 0 then None
    else Some (Printf.sprintf "%s %d"
      (ui_text state ~ko:"보관에서 빠진 이벤트" ~en:"Dropped events") state.acting_dropped)
  in
  let undecodable =
    if state.acting_undecodable = 0 then None
    else Some (Printf.sprintf "%s %d%s"
      (ui_text state ~ko:"해석하지 못한 이벤트" ~en:"Undecodable events")
      state.acting_undecodable
      (match state.acting_undecodable_last with
       | None -> ""
       | Some reason -> " · " ^ Terminal_text.single_line reason))
  in
  let unseen =
    if state.acting_unseen = 0 then None
    else Some (Printf.sprintf "%s %d (g)"
      (ui_text state ~ko:"위쪽 새 이벤트" ~en:"New above") state.acting_unseen)
  in
  let replay =
    match state.observer_replay with
    | Observer_replay_scoped { replay = (Sse_wire.Fresh | Sse_wire.Resumed); _ }
      when not state.observer_source_loss -> None
    | Observer_replay_unobserved | Observer_replay_unavailable _
    | Observer_replay_rejected _
    | Observer_replay_scoped
        { replay = (Sse_wire.Fresh | Sse_wire.Resumed | Sse_wire.Resumed_after_gap _
                   | Sse_wire.Reset (Sse_wire.Instance_changed | Sse_wire.Unscoped_cursor
                                    | Sse_wire.Cursor_ahead)); _ } ->
        Some (Terminal_text.single_line
          (observer_replay_description ~ko:(state.ui_language = Lang_ko)
             ~source_loss:state.observer_source_loss state.observer_replay))
  in
  let warning text = Theme.warn (), text in
  let trace =
    Option.map
      (fun text ->
        ( (if Masc_tui_acting_pane.trace_absences_warn trace_unavailable then Theme.warn ()
           else Theme.recede ())
        , text ))
      (Masc_tui_acting_pane.trace_unavailable_summary ~ko:(state.ui_language = Lang_ko)
         trace_unavailable)
  in
  List.filter_map Fun.id
    [ Option.map warning feed; Option.map warning dropped; Option.map warning undecodable
    ; Option.map warning unseen; Option.map warning replay; trace ]

let acting_content_height ~rows ~notices =
  (* Top/title/divider, column heading, then overflow/bottom/footer. *)
  max 1 (rows - (4 + List.length notices + listing_rows_below_the_body))

let acting_page_rows state ~terminal_rows =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let trace_reading = Tui_decode.keeper_trace_projection state.keepers in
  let notices = acting_notices state ~trace_unavailable:trace_reading.unavailable in
  Masc_tui_scroll.page_step ~height:(acting_content_height ~rows ~notices)

let render_acting (state : state) =
  match state.acting_detail with
  | Some entry -> render_acting_evidence state entry
  | None ->
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let module Acting = Masc_tui_acting in
  let held = List.length state.acting in
  (* The agent_core family names its runtime lane, not the keeper; the
     keeper is the one whose trace the event's correlation id carries. *)
  let trace_reading = Tui_decode.keeper_trace_projection state.keepers in
  let traces = trace_reading.bindings in
  let notices = acting_notices state ~trace_unavailable:trace_reading.unavailable in
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
      | Masc_tui_observer.Agent_core
          { Masc_tui_observer.kind =
              ( Masc_tui_observer.Tool_called
              | Masc_tui_observer.Turn_started
              | Masc_tui_observer.Turn_ready
              | Masc_tui_observer.Turn_completed
              | Masc_tui_observer.Agent_started
              | Masc_tui_observer.Agent_completed _
              | Masc_tui_observer.Agent_failed _
              | Masc_tui_observer.Agent_yielded _
              | Masc_tui_observer.Agent_input_required _
              | Masc_tui_observer.Tool_approval_completed
              | Masc_tui_observer.Telemetry
              | Masc_tui_observer.Relay_subscription_loss _
              | Masc_tui_observer.Agent_core_other _ )
          ; _
          }
      | Masc_tui_observer.Keeper_heartbeat _
      | Masc_tui_observer.Keeper_tool_call _
      | Masc_tui_observer.Keeper_turn_complete _
      | Masc_tui_observer.Keeper_turn_observation _
      | Masc_tui_observer.Keeper_composite_changed _ | Masc_tui_observer.Keeper_metrics_appended _
      | Masc_tui_observer.Keeper_chat_appended _
      | Masc_tui_observer.Keeper_memory_journal_appended _ | Masc_tui_observer.Keeper_runtime_journal_appended _
      | Masc_tui_observer.Keeper_chat_stream_frame _
      | Masc_tui_observer.Keeper_turn_stream_frame _
      | Masc_tui_observer.Keeper_waiting_inventory_changed _ | Masc_tui_observer.Keeper_async_requests_changed _ | Masc_tui_observer.Keeper_skill_activations_changed _ | Masc_tui_observer.Keeper_roster_change _ | Masc_tui_observer.Keeper_turn_changed _
      | Masc_tui_observer.Fusion_run_status _
      | Masc_tui_observer.Internal_agent_runs_changed _ | Masc_tui_observer.Workspace_store_changed _ | Masc_tui_observer.Dataset_changed _ | Masc_tui_observer.Gate_connector_changed _ | Masc_tui_observer.Keeper_event_queue_changed _ | Masc_tui_observer.Board_changed _ | Masc_tui_observer.Approval_change _
      | Masc_tui_observer.Lane_resource _
      | Masc_tui_observer.Snapshot _ | Masc_tui_observer.Execution_snapshot
      | Masc_tui_observer.Other _ ->
          None
    in
    Acting.keeper_row_of_entry ~ko:(state.ui_language = Lang_ko) ~traces ~duration_ms entry
  in
  (* [Turns] folds the whole ring into per-turn rows; the flat filters keep
     the page-lazy pairing above. *)
  let chunked =
    match state.acting_filter with
    | Acting.Turns ->
        Some (Acting.chunk_rows ~ko:(state.ui_language = Lang_ko) ~traces state.acting)
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
  let header =
    activity_heading state ~cols ~on_logs:false
      ~reading:
        (("  " ^ Acting.filter_label ~ko:(state.ui_language = Lang_ko) state.acting_filter)
         ::
         (match
            Masc_tui_types.activity_title_reading ~observer:state.observer
              ~shown ~held
          with
          | Activity_unanswered { error } ->
              [ "  " ^ here_missing_reading state ~error ]
          | Activity_counted { shown; held } ->
              [ "  " ^ count_reading state Masc_tui_value.Count.Row shown
              ; reading_separator
                ^ count_reading state Masc_tui_value.Count.Event held
                ^ ui_text state ~ko:" 보유" ~en:" held" ]))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  List.iter
    (fun (style, notice) -> box_line_styled buf cols ~style ("  " ^ notice))
    notices;
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
              Acting.measured_of_event ~ko:(state.ui_language = Lang_ko) ~traces
                entry.Acting.ae_event)
            visible
    in
    Acting.columns ~inner_width:(framed_inner_width cols) measured
  in
  let column_line ~glyph ~content ~actor ~clock =
    "  " ^ glyph ^ " "
    ^ fit_width content table_columns.Acting.content_cells ^ " "
    ^ fit_width
        (Message_layout.fit_middle table_columns.Acting.keeper_cells actor)
        table_columns.Acting.keeper_cells
    ^ (if table_columns.Acting.show_clock then " " ^ clock else "")
  in
  let col_hdr =
    column_line ~glyph:" "
      ~content:(ui_text state ~ko:"이벤트" ~en:"EVENT")
      ~actor:(ui_text state ~ko:"주체" ~en:"ACTOR")
      ~clock:(ui_text state ~ko:"시각" ~en:"TIME")
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  let content_height = acting_content_height ~rows ~notices in
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
    let nothing_under_filter =
      ui_text state ~ko:"  (이 필터에 해당하는 것 없음 · f 로 전체 보기)"
        ~en:"  (nothing under this filter; f shows everything)"
    in
    let empty =
      match state.observer with
      | Observer_off | Observer_opening ->
          ui_text state ~ko:"  (아직 이벤트 없음: 피드가 열리지 않음)"
            ~en:"  (no events yet: the feed is not open)"
      | Observer_live _ ->
          if held = 0 then
            ui_text state ~ko:"  (아직 이벤트 없음)" ~en:"  (no events yet)"
          else nothing_under_filter
      | Observer_closed_after_live _ ->
          if held = 0 then
            ui_text state ~ko:"  (이벤트가 오기 전에 피드가 닫힘)"
              ~en:"  (the feed closed before any event arrived)"
          else nothing_under_filter
      | Observer_closed_before_answer _ ->
          if held = 0 then
            ui_text state ~ko:"  (아직 이벤트 없음: 피드를 열지 못함)"
              ~en:"  (no events yet: the feed failed to open)"
          else nothing_under_filter
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
          let content =
            Terminal_text.single_line row.Acting.label
            ^ (if row.Acting.detail = "" then ""
               else " · " ^ Terminal_text.single_line row.Acting.detail)
          in
          let clock =
            Terminal_text.clock_timestamp
              (Masc_domain.iso8601_of_unix_seconds row.Acting.at)
          in
          let line =
            column_line ~glyph:(Acting.glyph_text row.Acting.glyph)
              ~content ~actor:(Terminal_text.single_line row.Acting.keeper) ~clock
          in
          let selected = state.acting_filter <> Acting.Turns && idx = cursor in
          let line = if selected then "> " ^ String.sub line 2 (String.length line - 2) else line in
          box_line_styled buf cols ~style:(if selected then Theme.selection else style) line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf
         (if state.ui_language = Lang_ko then "  [줄 %s]" else "  [rows %s]")
         (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:false
            ~has_rows:(shown > 0)
            ~has_reading:(state.acting_filter <> Acting.Turns && shown > 0) Acting));
  let clamped = match state.acting_filter with
    | Acting.Turns -> Acting scroll
    | Actions | Everything -> Acting_selection (scroll, cursor) in
  finish_surface state ~clamped ~surface_key:"acting" ~rows:terminal_rows ~cols buf
