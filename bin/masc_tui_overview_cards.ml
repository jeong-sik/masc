module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text

let column_gap = 2
let min_card_width = 44
let card_row_gap = 1
let column_count = 2

let row_lines ~cells label =
  match Layout.wrap_words ~max_cells:(max 1 cells) (Terminal_text.single_line label) with
  | [] -> [ "" ]
  | lines -> lines

(* The band covers the card's whole content width on every line of the row, so
   a row that wraps is still one selected thing. *)
let band ~cells line =
  Masc_tui_theme.selection ^ Layout.fit_width line cells ^ Ansi.reset

let row_body ~is_selected ~cells (action, label) =
  let lines = row_lines ~cells label in
  if is_selected action then List.map (band ~cells) lines else lines

let draw ~inner ~rows ~is_selected ~decisions ~decisions_whole ~continuation ~status =
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
      { Masc_tui_card.title = "Needs your decision"
      ; body =
          (fun ~cells ->
             match decisions with
             (* The cards are drawn only for a whole window, so an empty list
                means no decision waits. *)
             | [] -> [ Theme.recede () ^ "No decision is waiting on you." ^ Ansi.reset ]
             | _ :: _ -> rows_of decisions ~cells)
      }
    in
    let continue_card =
      { Masc_tui_card.title = "Continue"; body = rows_of continuation }
    in
    let status_card =
      { Masc_tui_card.title = "Status"; body = (fun ~cells -> status ~cells) }
    in
    let style =
      { Masc_tui_card.edge = Theme.recede ()
      ; title_style = Ansi.bold
      ; reset = Ansi.reset
      }
    in
    Masc_tui_card.grid ~style ~inner_width:inner ~gap:column_gap
      ~row_gap:card_row_gap ~max_rows:rows
      [ [ decision_card; continue_card ]; [ status_card ] ]
  end
