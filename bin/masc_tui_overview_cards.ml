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

(* A reason the server gives for needing the operator is wrapped like a row and
   drawn in the warning colour on every line it takes. *)
let reason_lines ~cells reason =
  List.map (fun line -> Theme.warn () ^ line ^ Ansi.reset) (row_lines ~cells reason)

let reasons_title count = Printf.sprintf "Action needed (%d)" count

(* The reasons as the plain layout draws them, one element to a row: the
   heading, the lines of each reason that is drawn and, when some are left out,
   a last row that says how many. The layout draws exactly this list, so its
   length is its height. The reasons drawn are the first ones, whole and in
   order: all of them when they fit [rows], else the longest run that fits
   together with the note. A short reason after one that does not fit never
   jumps ahead. *)
let plain_reasons ~indent ~inner ~rows reasons =
  let cells = inner - Layout.display_width indent in
  let blocks = List.map (reason_lines ~cells) reasons in
  let total = List.length blocks in
  let heading = Some Ansi.bold, " " ^ reasons_title total in
  let drawn count =
    let omitted = total - count in
    let lines =
      List.concat_map (List.map (fun line -> None, indent ^ line)) (List.take count blocks)
    in
    (heading :: lines)
    @ if omitted > 0 then [ Some (Theme.recede ()), indent ^ Masc_tui_card.more_text omitted ] else []
  in
  let rec longest count =
    if count = 0 then []
    else begin
      let candidate = drawn count in
      if List.length candidate <= rows then candidate else longest (count - 1)
    end
  in
  longest total

(* The band covers the card's whole content width on every line of the row, so
   a row that wraps is still one selected thing. *)
let band ~cells line =
  Masc_tui_theme.selection ^ Layout.fit_width line cells ^ Ansi.reset

let row_body ~is_selected ~cells (action, label) =
  let lines = row_lines ~cells label in
  if is_selected action then List.map (band ~cells) lines else lines

let draw ~(titles : titles) ~inner ~rows ~is_selected ~decisions ~decisions_whole ~continuation ~status ~actions =
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
             | [] -> [ Theme.recede () ^ "No decision is waiting on you." ^ Ansi.reset ]
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
