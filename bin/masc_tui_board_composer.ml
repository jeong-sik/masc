(** Masc_tui_board_composer — draft parsing, formatting, template management,
    and addressing analysis for the MASC TUI Board compose pane. *)

open Masc_tui_ansi

type addressing_kind =
  | Broadcast_all
  | Mentions of string list
  | Unsupported_broadcast of string list
  | Discoverable_unaddressed

let strip_markdown_title_prefix raw =
  let t = String.trim raw in
  let len = String.length t in
  let rec skip_hash i =
    if i < len && t.[i] = '#' then skip_hash (i + 1)
    else i
  in
  let i = skip_hash 0 in
  if i > 0 && i < len && (t.[i] = ' ' || t.[i] = '\t') then
    String.trim (String.sub t i (len - i))
  else if i > 0 && i = len then
    ""
  else
    t
;;

let split_draft text =
  let lines = String.split_on_char '\n' text in
  let rec find_title = function
    | [] -> ("", [])
    | line :: rest ->
        let trimmed = String.trim line in
        if String.equal trimmed "" then find_title rest
        else (strip_markdown_title_prefix trimmed, rest)
  in
  let title, rest_lines = find_title lines in
  let body = String.concat "\n" rest_lines in
  (title, body)
;;

let template_for_new_post () =
  "# Title\n\nWrite post body here in Markdown.\n\n<!-- Tip: Mention @<keeper> or @@all to wake keepers -->\n"
;;

let is_untouched_template ~draft =
  let trimmed = String.trim draft in
  String.equal trimmed ""
  || String.equal trimmed (String.trim (template_for_new_post ()))
;;

let analyze_addressing text =
  match Board_addressing.parse text with
  | Board_addressing.Broadcast_all -> Broadcast_all
  | Board_addressing.Raw_targets targets -> Mentions targets
  | Board_addressing.Unsupported_broadcast selectors -> Unsupported_broadcast selectors
  | Board_addressing.No_explicit_address -> Discoverable_unaddressed
;;

let format_addressing_hint ?(ko = false) ~max_cells kind =
  match kind with
  | Broadcast_all ->
      Printf.sprintf "%s%s%s%s"
        Ansi.bold
        (Theme.accent ())
        (if ko then "[전체 알림: @@all -> 모든 활성 키퍼 호출]"
         else "[Broadcast: @@all -> wakes all active keepers]")
        Ansi.reset
  | Mentions targets ->
      let target_str = String.concat ", @" targets in
      let prefix = if ko then "[멘션: @" else "[Mentions: @" in
      let suffix = if ko then " -> 지정 키퍼에 알림]" else " -> notifies targeted keepers]" in
      let cells = Masc_tui_message_layout.display_width in
      let target_cells = max 0 (max_cells - cells prefix - cells suffix) in
      let fit text width =
        if cells text <= width then text
        else Masc_tui_message_layout.fit_width text width
      in
      let line = prefix ^ fit target_str target_cells ^ suffix in
      Printf.sprintf "%s%s%s"
        (Theme.accent ())
        (fit line (max 0 max_cells))
        Ansi.reset
  | Unsupported_broadcast selectors ->
      Printf.sprintf
        (if ko then "%s[경고: 지원하지 않는 브로드캐스트 @@%s (@@all 사용)]%s"
         else "%s[Warning: unsupported broadcast @@%s (use @@all)]%s")
        (Theme.bad ())
        (String.concat ", " selectors)
        Ansi.reset
  | Discoverable_unaddressed ->
      Printf.sprintf "%s%s%s"
        Ansi.dim
        (if ko then "[안내: 멘션 없는 글은 탐색 가능 상태 · @<키퍼> 또는 @@all로 키퍼를 깨우세요]"
         else "[Tip: Unmentioned posts are Discoverable · use @<keeper> or @@all to wake keepers]")
        Ansi.reset
;;

(* The caret sits one cell past the last character typed, so a draft row
   leaves that cell free: a full row keeps the caret on it instead of on the
   frame's margin. *)
let caret_cells = 1

(* The narrowest a draft row is wrapped to, however narrow the terminal. *)
let draft_min_cells = 10

let draft_cells ~cols =
  max draft_min_cells (Masc_tui_frame.inner_width ~cols - caret_cells)
;;

(* Terminal columns are 1-based and the frame's content column counts from
   0, so the draft's first character is drawn one past the content column. *)
let draft_first_column = 1 + Masc_tui_frame.content_column

let compute_caret_position ~chrome_top_rows ~cols ~visible_lines =
  let line_count = List.length visible_lines in
  let caret_row = chrome_top_rows + max 1 line_count in
  let last_line =
    match List.rev visible_lines with
    | line :: _ -> line
    | [] -> ""
  in
  let text_width = Masc_tui_message_layout.display_width last_line in
  let last_content_column =
    draft_first_column + Masc_tui_frame.inner_width ~cols - 1
  in
  let caret_col = min last_content_column (draft_first_column + text_width) in
  (caret_row, max draft_first_column caret_col)
;;
