module Layout = Masc_tui_message_layout
module Box = Masc_tui_theme.Box
module Value = Masc_tui_value

type count =
  | Whole of int
  | Partial of { loaded : int; total : int }

type symbol =
  | Mark of Value.Mark.t
  | Unknown of Value.Unknown.t

type status =
  { symbol : symbol
  ; word : string
  ; tone : string
  }

type focus =
  | Focused
  | Unfocused

type edge =
  { name : string
  ; key : (string * string) option
  ; status : status option
  ; count : count option
  ; focus : focus
  }

type t =
  { edge : edge
  ; body : cells:int -> string list
  }

type style =
  { border : string
  ; title_style : string
  ; reset : string
  }

type name_fit =
  | Whole_name
  | Shortened_name of int
  | No_name

type top_fit =
  { key_kept : bool
  ; name_kept : name_fit
  ; word_kept : bool
  ; symbol_kept : bool
  ; count_kept : bool
  }

(* A side, one cell of padding, a cell of content, one cell of padding, a side. *)
let side_and_padding_cells = 4
let min_width = side_and_padding_cells + 1
let min_height = 3
let content_cells ~width = max 0 (width - side_and_padding_cells)

(* The top edge reads [╭─ left ───── count ─╮]. [left] is the key, the name,
   the symbol and the word, one space between each. What the edge spends
   around them, by which of the two it holds: *)

(* the corner, a rule cell and a space before [left]; a space and the corner
   after it. *)
let left_only_cells = 5

(* the same before [left]; after it a space, at least one rule cell, a space,
   the count, a space, a rule cell and the corner. *)
let left_and_count_cells = 9

(* the corner and a rule cell; a space either side of the count, a rule cell
   and the corner. *)
let count_only_cells = 6

(* The bottom edge reads [╰───── 외 3 ─╯]: the corner and at least one rule
   cell, a space either side of the text, a rule cell and the corner. *)
let bottom_text_cells = 6

(* A character takes at most two cells, so two cells always hold a name's
   first character, and the cut mark says the rest was cut. A shorter name is
   shown whole or not at all. *)
let shortest_name_cells = 2 + Layout.cut_mark_cells

let cells = Layout.display_width
let repeat text count = String.concat "" (List.init (max 0 count) (fun _ -> text))
let blank width = String.make (max 0 width) ' '

let symbol_glyph = function
  | Mark mark -> Value.Mark.glyph mark
  | Unknown why -> Value.Unknown.glyph why

let count_text ~ko = function
  | Whole rows -> Value.Count.grouped rows
  | Partial { loaded; total } -> Value.Count.partial ~ko ~loaded ~total

(* Zone 2's position counts a focused list, so its card does not. *)
let shown_count edge =
  match edge.focus with
  | Focused -> None
  | Unfocused -> edge.count

let key_text (tag, _) = Masc_tui_theme.strip_sgr tag

(* The cells of the parts that are there, one space between each. *)
let joined_cells parts =
  match List.filter (fun part -> part > 0) parts with
  | [] -> 0
  | present -> List.fold_left ( + ) 0 present + List.length present - 1

let bare =
  { key_kept = false
  ; name_kept = No_name
  ; word_kept = false
  ; symbol_kept = false
  ; count_kept = false
  }

let top_fit ~ko ~width edge =
  let key_cells = match edge.key with None -> 0 | Some key -> cells (key_text key) in
  let name_cells = cells edge.name in
  let symbol_cells, word_cells =
    match edge.status with
    | None -> (0, 0)
    | Some status -> (cells (symbol_glyph status.symbol), cells status.word)
  in
  let count_cells =
    match shown_count edge with None -> 0 | Some count -> cells (count_text ~ko count)
  in
  let fits ~left =
    match left > 0, count_cells > 0 with
    | true, true -> left + count_cells + left_and_count_cells <= width
    | true, false -> left + left_only_cells <= width
    | false, true -> count_cells + count_only_cells <= width
    | false, false -> true
  in
  (* The name beside [others]: whole when it fits, else as many cells as the
     edge leaves it, when that still holds its first character. *)
  let name_beside others =
    let beside = match joined_cells others with 0 -> 0 | spent -> spent + 1 in
    let room =
      (if count_cells > 0 then width - count_cells - left_and_count_cells
       else width - left_only_cells)
      - beside
    in
    if name_cells <= room then Some Whole_name
    else if room >= shortest_name_cells then Some (Shortened_name room)
    else None
  in
  let kept ~key ~name ~word =
    { key_kept = key && key_cells > 0
    ; name_kept = name
    ; word_kept = word && word_cells > 0
    ; symbol_kept = symbol_cells > 0
    ; count_kept = count_cells > 0
    }
  in
  let whole ~key =
    joined_cells
      [ (if key then key_cells else 0); name_cells; symbol_cells; word_cells ]
  in
  if fits ~left:(whole ~key:true) then kept ~key:true ~name:Whole_name ~word:true
  else if fits ~left:(whole ~key:false) then kept ~key:false ~name:Whole_name ~word:true
  else
    match name_beside [ symbol_cells; word_cells ] with
    | Some name -> kept ~key:false ~name ~word:true
    | None -> (
        match name_beside [ symbol_cells ] with
        | Some name -> kept ~key:false ~name ~word:false
        | None ->
            if fits ~left:symbol_cells then kept ~key:false ~name:No_name ~word:false
            else bare)

let border_style ~style = function
  | Focused -> Masc_tui_theme.border_focus
  | Unfocused -> style.border

let top_edge ~ko ~style ~width edge =
  let fit = top_fit ~ko ~width edge in
  let border = border_style ~style edge.focus in
  let paint code text = code ^ text ^ style.reset in
  let key =
    match edge.key with
    | Some ((_, tag_style) as key) when fit.key_kept -> [ paint tag_style (key_text key) ]
    | Some _ | None -> []
  in
  let name =
    match fit.name_kept with
    | Whole_name when cells edge.name > 0 -> [ paint style.title_style edge.name ]
    | Whole_name | No_name -> []
    | Shortened_name room -> [ paint style.title_style (Layout.fit_width edge.name room) ]
  in
  let status =
    match edge.status with
    | None -> []
    | Some status ->
        (if fit.symbol_kept then [ paint status.tone (symbol_glyph status.symbol) ] else [])
        @ if fit.word_kept then [ paint status.tone status.word ] else []
  in
  let left = String.concat " " (key @ name @ status) in
  let left_cells = cells left in
  let count =
    match shown_count edge with
    | Some count when fit.count_kept -> Some (count_text ~ko count)
    | Some _ | None -> None
  in
  let opening = Box.tl_round ^ Box.h in
  let closing = Box.h ^ Box.tr_round in
  match left_cells > 0, count with
  | false, None -> paint border (Box.tl_round ^ repeat Box.h (width - 2) ^ Box.tr_round)
  | true, None ->
      paint border (opening ^ " ") ^ left
      ^ paint border (" " ^ repeat Box.h (width - left_cells - left_only_cells) ^ Box.tr_round)
  | false, Some count ->
      paint border
        (opening
         ^ repeat Box.h (width - cells count - count_only_cells)
         ^ " " ^ count ^ " " ^ closing)
  | true, Some count ->
      (* [fits] left at least one rule cell between the two. *)
      let rule = width - left_cells - cells count - left_and_count_cells + 1 in
      paint border (opening ^ " ") ^ left
      ^ paint border (" " ^ repeat Box.h rule ^ " " ^ count ^ " " ^ closing)

(* A card too narrow to hold the text keeps a plain edge: five or six cells
   wide, its body is one or two cells and nothing in it reads anyway. *)
let bottom_edge ~ko ~border ~reset ~width hidden =
  let paint text = border ^ text ^ reset in
  let plain = paint (Box.bl_round ^ repeat Box.h (width - 2) ^ Box.br_round) in
  let room = width - bottom_text_cells in
  if hidden <= 0 || room < 1 then plain
  else
    let text = Value.Count.more ~ko hidden in
    let text = if cells text <= room then text else Layout.fit_width text room in
    paint
      (Box.bl_round
       ^ repeat Box.h (width - cells text - bottom_text_cells + 1)
       ^ " " ^ text ^ " " ^ Box.h ^ Box.br_round)

let body_row ~border ~reset ~width content =
  String.concat ""
    [ border; Box.v; reset; " "
    ; Layout.fit_width content (content_cells ~width)
    ; " "; border; Box.v; reset
    ]

let window ~rows body =
  let rows = max 0 rows in
  let count = List.length body in
  if count <= rows then (body, 0)
  else (List.filteri (fun index _ -> index < rows) body, count - rows)

(* [body] is the rows already asked of the card at its content width, so a
   body that wraps is asked once per card however many times the layout reads
   its height. *)
let render_body ~ko ~style ~width ~height edge body =
  if width < min_width || height < min_height then
    List.init (max 0 height) (fun _ -> blank width)
  else begin
    let rows = height - 2 in
    let shown, hidden = window ~rows body in
    let border = border_style ~style edge.focus in
    let filler = List.init (rows - List.length shown) (fun _ -> "") in
    (top_edge ~ko ~style ~width edge
     :: List.map (body_row ~border ~reset:style.reset ~width) (shown @ filler))
    @ [ bottom_edge ~ko ~border ~reset:style.reset ~width hidden ]
  end

let render ~ko ~style ~width ~height card =
  render_body ~ko ~style ~width ~height card.edge
    (card.body ~cells:(content_cells ~width))

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
let natural_height body = max min_height (List.length body + 2)

let stack_height ~row_gap heights =
  List.fold_left ( + ) 0 heights + (row_gap * max 0 (List.length heights - 1))

(* Each card of a column with its body, asked once at the column's width. *)
let prepare_column ~width stack =
  List.map (fun card -> (card.edge, card.body ~cells:(content_cells ~width))) stack

let prepared_height ~row_gap prepared =
  stack_height ~row_gap (List.map (fun (_, body) -> natural_height body) prepared)

(* The last card of a column takes whatever the column lacks against the
   tallest, so every column ends on the same row. *)
let column_rows ~ko ~style ~row_gap ~width ~height prepared =
  let extra = max 0 (height - prepared_height ~row_gap prepared) in
  let last = List.length prepared - 1 in
  let drawn =
    List.mapi
      (fun index (edge, body) ->
         let card_height = natural_height body + if index = last then extra else 0 in
         render_body ~ko ~style ~width ~height:card_height edge body)
      prepared
  in
  let gap_rows = List.init row_gap (fun _ -> blank width) in
  List.concat
    (List.mapi (fun index rows -> if index = 0 then rows else gap_rows @ rows) drawn)

let grid ~ko ~style ~inner_width ~gap ~row_gap ~max_rows columns =
  let count = List.length columns in
  let prepared =
    List.mapi
      (fun index stack ->
         let width = column_width ~inner_width ~gap ~columns:count ~index in
         (width, prepare_column ~width stack))
      columns
  in
  let height =
    List.fold_left
      (fun tallest (_, column) -> max tallest (prepared_height ~row_gap column))
      0 prepared
  in
  if height > max_rows then None
  else begin
    let drawn =
      List.map
        (fun (width, column) ->
           match column with
           (* A column with no cards is blank rows of its width. *)
           | [] -> List.init height (fun _ -> blank width)
           | _ :: _ -> column_rows ~ko ~style ~row_gap ~width ~height column)
        prepared
    in
    let rec zip rows =
      if List.for_all (function [] -> true | _ :: _ -> false) rows then []
      else
        let heads = List.map (function [] -> "" | head :: _ -> head) rows in
        let tails = List.map (function [] -> [] | _ :: tail -> tail) rows in
        String.concat (blank gap) heads :: zip tails
    in
    Some (zip drawn)
  end
