module Layout = Masc_tui_message_layout
module Box = Masc_tui_theme.Box

type t =
  { title : string
  ; body : cells:int -> string list
  }

type style =
  { edge : string
  ; title_style : string
  ; reset : string
  }

(* A side, one cell of padding, a cell of content, one cell of padding, a side. *)
let side_and_padding_cells = 4
let min_width = side_and_padding_cells + 1
let min_height = 3
let content_cells ~width = max 0 (width - side_and_padding_cells)

(* The top edge reads [┌─ Title ───┐]: the corner and one rule cell before the
   title, a space on each side of it, and the closing corner. *)
let top_edge_fixed_cells = 5

let repeat text count = String.concat "" (List.init (max 0 count) (fun _ -> text))
let blank width = String.make (max 0 width) ' '

let top_edge ~style ~width title =
  let room = max 0 (width - top_edge_fixed_cells) in
  let label_cells = min room (Layout.display_width title) in
  let label = Layout.fit_width title label_cells in
  let fill = width - top_edge_fixed_cells - label_cells in
  String.concat ""
    [ style.edge; Box.tl; Box.h; " "; style.reset
    ; style.title_style; label; style.reset
    ; style.edge; " "; repeat Box.h fill; Box.tr; style.reset
    ]

let bottom_edge ~style ~width =
  String.concat ""
    [ style.edge; Box.bl; repeat Box.h (width - 2); Box.br; style.reset ]

let body_row ~style ~width content =
  String.concat ""
    [ style.edge; Box.v; style.reset; " "
    ; Layout.fit_width content (content_cells ~width)
    ; " "; style.edge; Box.v; style.reset
    ]

(* What a body shows in [rows] rows: all of it when it fits, otherwise all but
   the last row, which says how many rows are not shown. *)
let window ~style ~rows body =
  let count = List.length body in
  if count <= rows then body
  else
    let shown = rows - 1 in
    let hidden = count - shown in
    List.filteri (fun index _ -> index < shown) body
    @ [ style.edge ^ Printf.sprintf "+%d more" hidden ^ style.reset ]

let render ~style ~width ~height card =
  if width < min_width || height < min_height then
    List.init (max 0 height) (fun _ -> blank width)
  else begin
    let rows = height - 2 in
    let body = window ~style ~rows (card.body ~cells:(content_cells ~width)) in
    let filler = List.init (rows - List.length body) (fun _ -> "") in
    (top_edge ~style ~width card.title
     :: List.map (body_row ~style ~width) (body @ filler))
    @ [ bottom_edge ~style ~width ]
  end

let columns_that_fit ~inner_width ~gap ~min_card_width ~max_columns =
  let per_column = max 1 (min_card_width + gap) in
  max 1 (min (max 1 max_columns) ((inner_width + gap) / per_column))

let column_width ~inner_width ~gap ~columns ~index =
  let columns = max 1 columns in
  let room = max 0 (inner_width - (gap * (columns - 1))) in
  let base = room / columns and extra = room mod columns in
  base + if index < extra then 1 else 0

let column_widths ~inner_width ~gap ~columns =
  List.init (max 1 columns) (fun index ->
    column_width ~inner_width ~gap ~columns ~index)

(* A card's height with nothing to stretch it: its body and the two edges. *)
let natural_height ~width card =
  max min_height (List.length (card.body ~cells:(content_cells ~width)) + 2)

let stack_height ~row_gap heights =
  List.fold_left ( + ) 0 heights + (row_gap * max 0 (List.length heights - 1))

let natural_heights ~width stack = List.map (natural_height ~width) stack

let grid_height ~inner_width ~gap ~row_gap columns =
  let count = List.length columns in
  List.mapi
    (fun index stack ->
       let width = column_width ~inner_width ~gap ~columns:count ~index in
       stack_height ~row_gap (natural_heights ~width stack))
    columns
  |> List.fold_left max 0

(* The last card of a column takes whatever the column lacks against the
   tallest, so every column ends on the same row. *)
let column_rows ~style ~row_gap ~width ~height stack =
  let extra =
    max 0 (height - stack_height ~row_gap (natural_heights ~width stack))
  in
  let last = List.length stack - 1 in
  let drawn =
    List.mapi
      (fun index card ->
         let card_height =
           natural_height ~width card + if index = last then extra else 0
         in
         render ~style ~width ~height:card_height card)
      stack
  in
  let gap_rows = List.init row_gap (fun _ -> blank width) in
  List.concat
    (List.mapi (fun index rows -> if index = 0 then rows else gap_rows @ rows) drawn)

let grid ~style ~inner_width ~gap ~row_gap columns =
  let count = List.length columns in
  let height = grid_height ~inner_width ~gap ~row_gap columns in
  let drawn =
    List.mapi
      (fun index stack ->
         let width = column_width ~inner_width ~gap ~columns:count ~index in
         let rows = column_rows ~style ~row_gap ~width ~height stack in
         (* A column with no cards is blank rows of its width. *)
         if rows = [] then List.init height (fun _ -> blank width) else rows)
      columns
  in
  let rec zip rows =
    if List.for_all (function [] -> true | _ :: _ -> false) rows then []
    else
      let heads = List.map (function [] -> "" | head :: _ -> head) rows in
      let tails = List.map (function [] -> [] | _ :: tail -> tail) rows in
      String.concat (blank gap) heads :: zip tails
  in
  zip drawn
