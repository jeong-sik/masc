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

(* A reason the server gives for needing the operator is wrapped like a row and
   drawn in the warning colour on every line it takes. *)
let reason_lines ~cells reason =
  List.map (fun line -> Theme.warn () ^ line ^ Ansi.reset) (row_lines ~cells reason)

let reasons_title count = Printf.sprintf "Action needed (%d)" count

type reasons =
  { shown : string list list
  ; omitted : int
  }

let heading_rows = 1
let note_rows = 1

let reasons_height { shown; omitted } =
  match shown with
  | [] -> 0
  | _ :: _ ->
      heading_rows
      + List.fold_left (fun sum lines -> sum + List.length lines) 0 shown
      + if omitted > 0 then note_rows else 0

(* Reasons are taken in order and only whole. When they do not all fit, the
   note row is kept back before any is taken, and the first reason that does
   not fit ends the list: a short one after a long one never jumps ahead. *)
let plain_reasons ~cells ~rows reasons =
  let drawn = List.map (reason_lines ~cells) reasons in
  if reasons_height { shown = drawn; omitted = 0 } <= rows then
    { shown = drawn; omitted = 0 }
  else begin
    let budget = rows - heading_rows - note_rows in
    let rec take used shown = function
      | lines :: rest when used + List.length lines <= budget ->
          take (used + List.length lines) (lines :: shown) rest
      | rest -> { shown = List.rev shown; omitted = List.length rest }
    in
    take 0 [] drawn
  end

(* The band covers the card's whole content width on every line of the row, so
   a row that wraps is still one selected thing. *)
let band ~cells line =
  Masc_tui_theme.selection ^ Layout.fit_width line cells ^ Ansi.reset

let row_body ~is_selected ~cells (action, label) =
  let lines = row_lines ~cells label in
  if is_selected action then List.map (band ~cells) lines else lines

let draw ~inner ~rows ~is_selected ~decisions ~decisions_whole ~continuation ~status ~actions =
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
    let actions_card =
      { Masc_tui_card.title = reasons_title (List.length actions)
      ; body = (fun ~cells -> List.concat_map (reason_lines ~cells) actions)
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
    | _ :: _ ->
        (match grid [ status_card; actions_card ] with
         | Some _ as drawn -> drawn
         | None -> grid [ status_card ])
  end
