module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text
module Message_layout = Masc_tui_message_layout
module Numbered_list = Masc_tui_numbered_list
module Page_line = Masc_tui_page_line

let detail_indent = "  "

let wrap_indented_line ~max_cells style text =
  let single = Terminal_text.single_line text in
  if String.equal (String.trim single) "" then [ style, "" ]
  else
    Message_layout.wrap_words ~max_cells:(max 1 max_cells) single
    |> List.map (fun line -> style, detail_indent ^ line)

let wrap_indented_lines ~max_cells style lines =
  List.concat_map (wrap_indented_line ~max_cells style) lines

let label_cells_cap = 24
let min_value_cells = 16

let tone_style = function
  | Page_line.Quiet -> Theme.recede ()
  | Page_line.Plain -> Ansi.reset
  | Page_line.Info -> Theme.info ()
  | Page_line.Success -> Theme.ok ()
  | Page_line.Attention -> Theme.warn ()
  | Page_line.Failure -> Theme.bad ()

let widest_word_cells text =
  List.fold_left
    (fun widest word -> max widest (Message_layout.display_width word))
    0 (String.split_on_char ' ' text)

let fact_rows ~max_cells ~label_cells ~tone label value =
  let label = Terminal_text.single_line label ^ ":" in
  let value = Terminal_text.single_line value in
  let styled_label = Theme.recede () ^ label ^ Ansi.reset in
  let styled_value text = tone_style tone ^ text ^ Ansi.reset in
  let value_cells = max_cells - label_cells - 1 in
  if Message_layout.display_width label > label_cells
     || value_cells < min_value_cells
     || widest_word_cells value > value_cells
  then
    (Ansi.reset, detail_indent ^ styled_label)
    :: List.map
         (fun line -> Ansi.reset, detail_indent ^ detail_indent ^ styled_value line)
         (Message_layout.wrap_words
            ~max_cells:(max 1 (max_cells - String.length detail_indent))
            value)
  else
    let pad = String.make (label_cells + 1 - Message_layout.display_width label) ' ' in
    match Message_layout.wrap_words ~max_cells:value_cells value with
    | [] -> [ Ansi.reset, detail_indent ^ styled_label ]
    | first :: rest ->
      (Ansi.reset, detail_indent ^ styled_label ^ pad ^ styled_value first)
      :: List.map
           (fun line ->
              Ansi.reset, detail_indent ^ String.make (label_cells + 1) ' ' ^ styled_value line)
           rest

(* A list is its label on a row of its own and one numbered row under it for
   each value, a further indent in, so a value that wraps stays under its own
   number. A list with no values draws nothing: a label with nothing under it
   would read as a value that is missing. *)
let items_rows ~max_cells ~tone label values =
  match values with
  | [] -> []
  | _ :: _ ->
    wrap_indented_line ~max_cells (Theme.recede ()) (label ^ ":")
    @ List.map
        (fun row -> tone_style tone, detail_indent ^ detail_indent ^ row)
        (Numbered_list.rows
           ~max_cells:(max 1 (max_cells - String.length detail_indent))
           (List.map Terminal_text.single_line values))

let widest_label_cells lines =
  List.fold_left
    (fun widest -> function
       | Page_line.Fact { label; _ } ->
         let cells =
           Message_layout.display_width (Terminal_text.single_line label) + 1
         in
         if cells <= label_cells_cap then max widest cells else widest
       | Page_line.Title _ | Page_line.Note _ | Page_line.Items _ -> widest)
    0 lines

let rows ?label_cells ~max_cells (lines : Page_line.t list) =
  let label_cells =
    match label_cells with
    | Some cells -> cells
    | None -> widest_label_cells lines
  in
  List.concat_map
    (function
      | Page_line.Title text -> wrap_indented_line ~max_cells Ansi.bold text
      | Page_line.Note { text; tone } ->
        wrap_indented_line ~max_cells (tone_style tone) text
      | Page_line.Fact { label; value; tone } ->
        fact_rows ~max_cells ~label_cells ~tone label value
      | Page_line.Items { label; values; tone } ->
        items_rows ~max_cells ~tone label values)
    lines
