module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text

type edges =
  { decisions : Masc_tui_card.edge
  ; continuation : Masc_tui_card.edge
  ; capacity : Masc_tui_card.edge
  ; actions : Masc_tui_card.edge
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
  Theme.selection_style ()
  ^ Layout.fit_width (Masc_tui_theme.strip_sgr line) cells
  ^ Ansi.reset

let row_body ~is_selected ~cells (action, label) =
  let gutter = 2 in
  let text_cells = max 1 (cells - gutter) in
  let selected = is_selected action in
  let lines =
    row_lines ~cells:text_cells label
    |> List.mapi (fun index line ->
         (if selected && index = 0 then "› " else "  ") ^ line)
  in
  if selected then List.map (band ~cells) lines else lines

(* Every row a card lists is a destination the selection moves over, so a
   card with rows can hold it and a card with none cannot. *)
let card_selection ~is_selected entries =
  match entries with
  | [] -> Masc_tui_card.Unselectable
  | _ :: _ ->
      if List.exists (fun (action, _) -> is_selected action) entries then
        Masc_tui_card.Holds_selected_row
      else Masc_tui_card.Selectable

let draw ~ko ~(edges : edges) ~inner
    ~rows ~is_selected ~decisions ~decisions_whole ~continuation ~status
    ~keep_actions_card ~actions =
  let fits =
    Masc_tui_card.columns_that_fit ~inner_width:inner ~gap:column_gap
      ~min_card_width ~max_columns:column_count
  in
  if inner < min_card_width || not decisions_whole then None
  else begin
    let rows_of entries ~cells =
      List.concat_map (row_body ~is_selected ~cells) entries
    in
    let selection_in = card_selection ~is_selected in
    (* With no decision waiting the edge's count says so, and the body has
       nothing to list, as the conversations card with none. *)
    let decision_card =
      ( { Masc_tui_card.edge = edges.decisions; body = rows_of decisions }
      , selection_in decisions )
    in
    let continue_card =
      ( { Masc_tui_card.edge = edges.continuation; body = rows_of continuation }
      , selection_in continuation )
    in
    (* The status readings are not destinations. *)
    let status_card =
      ( { Masc_tui_card.edge = edges.capacity; body = (fun ~cells -> status ~cells) }
      , Masc_tui_card.Unselectable )
    in
    let actions_card =
      ({ Masc_tui_card.edge = edges.actions; body = rows_of actions }, selection_in actions)
    in
    let style =
      { Masc_tui_card.border = Theme.border_muted ()
      ; focused_border = Theme.border_focus ()
      ; title_style = Ansi.bold
      ; reset = Ansi.reset
      }
    in
    let show_actions_card =
      match actions, keep_actions_card with
      | [], false -> false
      | [], true | _ :: _, (true | false) -> true
    in
    let status_column =
      if show_actions_card then [ status_card; actions_card ]
      else [ status_card ]
    in
    let columns =
      if fits >= column_count then
        [ [ decision_card; continue_card ]; status_column ]
      else
        (* Narrow terminals (44..89 inner cells) step down to a single-column
           card stack ordered to match [Masc_tui_home.destinations]
           (decisions -> operator actions -> continuation -> status) so j/k
           traversal stays monotonically top-to-bottom. *)
        let single_column =
          if show_actions_card then
            [ decision_card; actions_card; continue_card; status_card ]
          else [ decision_card; continue_card; status_card ]
        in
        [ single_column ]
    in
    Masc_tui_card.grid ~ko ~style ~inner_width:inner
      ~gap:column_gap ~row_gap:card_row_gap ~max_rows:rows columns
  end
