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
  if i > 0 && i < len && t.[i] = ' ' then
    String.trim (String.sub t i (len - i))
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

let format_addressing_hint ~max_cells kind =
  match kind with
  | Broadcast_all ->
      Printf.sprintf "  %s%s[Broadcast: @@all -> wakes all active keepers]%s"
        Ansi.bold
        (Masc_tui_theme.tone Masc_tui_theme.Accent)
        Ansi.reset
  | Mentions targets ->
      let target_str = String.concat ", @" targets in
      Printf.sprintf "  %s[Mentions: @%s -> notifies targeted keepers]%s"
        (Masc_tui_theme.tone Masc_tui_theme.Accent)
        (fit_width target_str (max 10 (max_cells - 20)))
        Ansi.reset
  | Unsupported_broadcast selectors ->
      Printf.sprintf "  %s[Warning: unsupported broadcast @@%s (use @@all)]%s"
        (Theme.bad ())
        (String.concat ", " selectors)
        Ansi.reset
  | Discoverable_unaddressed ->
      Printf.sprintf "  %s[Tip: Unmentioned posts are Discoverable — use @<keeper> or @@all to wake keepers]%s"
        Ansi.dim Ansi.reset
;;

let compute_caret_position ~chrome_top_rows ~cols ~visible_lines =
  let line_count = List.length visible_lines in
  let caret_row = chrome_top_rows + max 1 line_count in
  let last_line =
    match List.rev visible_lines with
    | line :: _ -> line
    | [] -> ""
  in
  let text_width = Masc_tui_message_layout.display_width last_line in
  (* column 1 (base) + 2 (box_line margin) + 2 (indent) = 5 *)
  let caret_col = min (cols - 3) (5 + text_width) in
  (caret_row, max 5 caret_col)
;;
