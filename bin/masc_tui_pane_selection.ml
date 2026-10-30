module Message_layout = Masc_tui_message_layout
module Theme = Masc_tui_theme

type pane_kind =
  | Roster
  | Main
  | Activity

type rect = { top : int; bottom : int; left : int; right : int }

type pane = { kind : pane_kind; rect : rect }

type layout = pane list

let no_panes = []

type roster_split = { roster_cols : int; roster_rows : int }

(* Panes start at the terminal's left edge. *)
let first_terminal_column = 1

let frame_layout ~first_row ~body_rows ~main_cols ~activity_cols ~roster =
  let last_row = first_row + body_rows - 1 in
  let pane kind ~bottom ~left ~right =
    if bottom < first_row || right < left then []
    else [ { kind; rect = { top = first_row; bottom; left; right } } ]
  in
  let surface =
    match roster with
    | None -> pane Main ~bottom:last_row ~left:first_terminal_column ~right:main_cols
    | Some { roster_cols; roster_rows } ->
        let bottom = min last_row (first_row + roster_rows - 1) in
        pane Roster ~bottom ~left:first_terminal_column ~right:roster_cols
        @ pane Main ~bottom ~left:(roster_cols + 1) ~right:main_cols
  in
  surface
  @ pane Activity ~bottom:last_row ~left:(main_cols + 1)
      ~right:(main_cols + activity_cols)

let contains { top; bottom; left; right } ~row ~column =
  row >= top && row <= bottom && column >= left && column <= right

let pane_at layout ~row ~column =
  List.find_opt (fun pane -> contains pane.rect ~row ~column) layout

type point = { row : int; column : int }

type selection = { pane : pane; anchor : point; focus : point }

type gesture =
  | Idle
  | Pressed of { at : point; pane : pane option }
  | Drag_without_pane
  | Selecting of selection

type outcome =
  | Click of point
  | Copy of selection
  | Nothing

let same_point a b = a.row = b.row && a.column = b.column

(* The pointer may leave the pane; the selection stays at its edge, the way
   a terminal's selection stays inside the window. *)
let clamp { rect = { top; bottom; left; right }; kind = _ } { row; column } =
  { row = max top (min bottom row); column = max left (min right column) }

let press layout ~row ~column =
  Pressed { at = { row; column }; pane = pane_at layout ~row ~column }

let drag gesture ~row ~column =
  let at = { row; column } in
  match gesture with
  | Idle -> Idle
  | Pressed { at = pressed; pane = _ } when same_point pressed at -> gesture
  | Pressed { at = anchor; pane = Some pane } ->
      Selecting { pane; anchor; focus = clamp pane at }
  | Pressed { at = _; pane = None } -> Drag_without_pane
  | Drag_without_pane -> Drag_without_pane
  | Selecting selection ->
      Selecting { selection with focus = clamp selection.pane at }

let release gesture ~row ~column =
  match gesture with
  | Pressed { at; pane = _ } when same_point at { row; column } -> Click at
  | Idle | Pressed _ | Drag_without_pane | Selecting _ -> (
      match drag gesture ~row ~column with
      | Selecting selection -> Copy selection
      | Idle | Pressed _ | Drag_without_pane -> Nothing)

let in_progress = function
  | Idle -> false
  | Pressed _ | Drag_without_pane | Selecting _ -> true

type span = { span_row : int; first_column : int; last_column : int }

let reading_order a b =
  if a.row < b.row || (a.row = b.row && a.column <= b.column) then (a, b)
  else (b, a)

let spans { pane; anchor; focus } =
  let first, last = reading_order anchor focus in
  List.init
    (last.row - first.row + 1)
    (fun offset ->
      let row = first.row + offset in
      { span_row = row;
        first_column = (if row = first.row then first.column else pane.rect.left);
        last_column = (if row = last.row then last.column else pane.rect.right);
      })

(* A span widened to whole characters of [plain], a row with its styles
   removed: a character any of whose cells the span covers is taken whole, so
   neither the highlight nor the copy cuts a wide one in half. Past the end
   of the row's text every cell is a blank of its own. *)
let snap plain ~first_column ~last_column =
  let width = Message_layout.display_width plain in
  let first =
    if first_column > width then first_column
    else
      let before, _ = Message_layout.split_at_cells plain (first_column - 1) in
      Message_layout.display_width before + 1
  in
  let last =
    if last_column >= width then last_column
    else
      let inside, rest = Message_layout.split_at_cells plain last_column in
      let inside_cells = Message_layout.display_width inside in
      if inside_cells = last_column || String.equal rest "" then last_column
      else
        (* The character after [inside] starts in the span and ends past it.
           [split_at_cells] gives it up until the cells hold all of it. *)
        let rec straddling cells =
          match Message_layout.split_at_cells rest cells with
          | "", _ -> straddling (cells + 1)
          | head, _ -> inside_cells + Message_layout.display_width head
        in
        straddling (last_column - inside_cells + 1)
  in
  (first, last)

let cells_between text ~first ~last =
  Message_layout.take_cells
    (Message_layout.drop_cells text (first - 1))
    (last - first + 1)

let trim_trailing_spaces text =
  let rec stop index =
    if index > 0 && Char.equal text.[index - 1] ' ' then stop (index - 1)
    else index
  in
  String.sub text 0 (stop (String.length text))

let row_text line { first_column; last_column; span_row = _ } =
  let plain = Theme.strip_sgr line in
  let first, last = snap plain ~first_column ~last_column in
  trim_trailing_spaces (cells_between plain ~first ~last)

(* The selected cells lose their own colours: a reverse-video band cannot
   carry inner styles, the first inner reset would end it ([Theme.strip_sgr]).
   What follows the band opens under every style the row set before it,
   because [drop_cells] keeps the escapes it passes. *)
let highlight_row line { first_column; last_column; span_row = _ } =
  let first, last =
    snap (Theme.strip_sgr line) ~first_column ~last_column
  in
  let drawn = Message_layout.display_width line in
  let line =
    if drawn >= last then line
    else line ^ Theme.Sgr.reset ^ String.make (last - drawn) ' '
  in
  Message_layout.take_cells line (first - 1)
  ^ Theme.Sgr.reset ^ Theme.selection
  ^ Theme.strip_sgr (cells_between line ~first ~last)
  ^ Theme.Sgr.reset
  ^ Message_layout.drop_cells line last

let span_of_row selection =
  let by_row = spans selection in
  fun row -> List.find_opt (fun span -> span.span_row = row) by_row

let highlight selection rows =
  let span_at = span_of_row selection in
  List.mapi
    (fun index line ->
      match span_at (index + 1) with
      | Some span -> highlight_row line span
      | None -> line)
    rows

let text selection rows =
  let rows = Array.of_list rows in
  let lines =
    List.map
      (fun span ->
        let index = span.span_row - 1 in
        if index < 0 || index >= Array.length rows then ""
        else row_text rows.(index) span)
      (spans selection)
  in
  if List.for_all (String.equal "") lines then None
  else Some (String.concat "\n" lines)
