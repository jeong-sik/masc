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
  let lines = system_log_detail_lines state ~seq ~width:(max 1 (framed_inner_width cols - 4)) in
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
       ~position:(Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines))
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
      (Printf.sprintf "  [entries %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height total_entries));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view));
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
  box_line buf cols (screen_title " ACTING EVENT EVIDENCE" ^ "  " ^ connection_badge state);
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
                ~max_cells:(max 1 (framed_inner_width cols - Message_layout.display_width prefix)) text with
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
              :: (document_markdown ~width:(max 1 (framed_inner_width cols - 3))
                    ("```json\n" ^ Yojson.Safe.pretty_to_string value ^ "\n```")
                  |> List.map (fun line -> "  " ^ line)) in
        let preview label = function
          | None -> ["  " ^ label ^ ": not carried"]
          | Some text ->
              ("  " ^ label ^ " (producer-redacted preview)")
              :: (document_markdown ~width:(max 1 (framed_inner_width cols - 3))
                    (Keeper_chat.terminal_safe_text ~preserve_newlines:true text)
                  |> List.map (fun line -> "  " ^ line)) in
        [""; "  INPUT / OUTPUT OBSERVATIONS"]
        @ json "Input" call.kt_tool_args
        @ preview "Input preview" call.kt_tool_args_preview
        @ json "Output" call.kt_tool_result
        @ preview "Output preview" call.kt_tool_output_preview
    | Masc_tui_observer.Internal_agent_runs_changed | Masc_tui_observer.Agent_core _
    | Masc_tui_observer.Keeper_heartbeat _ | Masc_tui_observer.Keeper_turn_complete _
    | Masc_tui_observer.Keeper_turn_observation _ | Masc_tui_observer.Keeper_composite_changed _
    | Masc_tui_observer.Keeper_chat_appended _ | Masc_tui_observer.Keeper_chat_stream_frame _
    | Masc_tui_observer.Keeper_turn_stream_frame _
    | Masc_tui_observer.Keeper_waiting_inventory_changed _ | Masc_tui_observer.Fusion_run_status _
    | Masc_tui_observer.Lane_resource _ | Masc_tui_observer.Snapshot _ | Masc_tui_observer.Other _ -> []
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
      ~hints:Masc_tui_keys.acting_evidence_hints);
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
              | Masc_tui_observer.Agent_core_other _ )
          ; _
          }
      | Masc_tui_observer.Keeper_heartbeat _
      | Masc_tui_observer.Keeper_tool_call _
      | Masc_tui_observer.Keeper_turn_complete _
      | Masc_tui_observer.Keeper_turn_observation _
      | Masc_tui_observer.Keeper_composite_changed _
      | Masc_tui_observer.Keeper_chat_appended _
      | Masc_tui_observer.Keeper_chat_stream_frame _
      | Masc_tui_observer.Keeper_turn_stream_frame _
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
      (Printf.sprintf "  [rows %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
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
