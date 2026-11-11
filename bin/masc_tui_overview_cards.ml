module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text

type titles =
  { decisions : string
  ; continuation : string
  ; capacity : string
  ; actions : string
  }

let column_gap = 2
let min_card_width = 44
let card_row_gap = 1
let column_count = 2

(* A row that wraps hangs its later lines in by this much, so a long name that
   breaks reads as one row and not as the next one. *)
let hanging_indent = "  "

(* A row is not hung when less than this many cells are left beside the
   indent: the text would wrap at nearly every word. *)
let min_hung_text_cells = 8

let row_lines ~cells label =
  let text = Terminal_text.single_line label in
  let wrapped width = Layout.wrap_words ~max_cells:(max 1 width) text in
  match wrapped cells with
  | [] -> [ "" ]
  | [ _ ] as line -> line
  | _ :: _ :: _ as flat ->
      let text_cells = cells - Layout.display_width hanging_indent in
      if text_cells < min_hung_text_cells then flat
      else begin
        match wrapped text_cells with
        | first :: (_ :: _ as later) ->
            first :: List.map (fun line -> hanging_indent ^ line) later
        | [] | [ _ ] -> flat
      end

(* The band covers the card's whole content width on every line of the row, so
   a row that wraps is still one selected thing. *)
let band ~cells line =
  Masc_tui_theme.selection ^ Layout.fit_width line cells ^ Ansi.reset

let row_body ~is_selected ~cells (action, label) =
  let lines = row_lines ~cells label in
  if is_selected action then List.map (band ~cells) lines else lines

let draw ~(titles : titles) ~empty_decisions ~inner ~rows ~is_selected ~decisions ~decisions_whole ~continuation ~status ~actions =
  let fits =
    Masc_tui_card.columns_that_fit ~inner_width:inner ~gap:column_gap
      ~min_card_width ~max_columns:column_count
  in
  if fits < column_count || not decisions_whole then None
  else begin
    let rows_of entries ~cells =
      List.concat_map (row_body ~is_selected ~cells) entries
    in
    let decision_card =
      { Masc_tui_card.title = titles.decisions
      ; body =
          (fun ~cells ->
             match decisions with
             (* The cards are drawn only for a whole window, so an empty list
                means no decision waits. *)
             | [] -> [ Theme.recede () ^ empty_decisions ^ Ansi.reset ]
             | _ :: _ -> rows_of decisions ~cells)
      }
    in
    let continue_card =
      { Masc_tui_card.title = titles.continuation; body = rows_of continuation }
    in
    let status_card =
      { Masc_tui_card.title = titles.capacity; body = (fun ~cells -> status ~cells) }
    in
    let actions_card =
      { Masc_tui_card.title = titles.actions
      ; body = rows_of actions
      }
    in
    let style =
      { Masc_tui_card.edge = Theme.recede ()
      ; title_style = Ansi.bold
      ; reset = Ansi.reset
      }
    in
    let grid status_column =
      Masc_tui_card.grid ~style ~inner_width:inner ~gap:column_gap
        ~row_gap:card_row_gap ~max_rows:rows
        [ [ decision_card; continue_card ]; status_column ]
    in
    match actions with
    | [] -> grid [ status_card ]
    | _ :: _ -> grid [ status_card; actions_card ]
  end
