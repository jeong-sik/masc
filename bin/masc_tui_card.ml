module Layout = Masc_tui_message_layout
module Box = Masc_tui_theme.Box
module Value = Masc_tui_value

type count =
  | Whole of int
  | Partial of { loaded : int; total : int }
  | At_least of int

type symbol =
  | Mark of Value.Mark.t
  | Unknown of Value.Unknown.t

type status =
  { symbol : symbol
  ; word : string
  ; tone : string
  }

type focus =
  | Unfocused
  | Focused_list
  | Focused_other

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
  ; focused_border : string
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

type bottom_fit =
  | Says_more
  | Number_only
  | Plain

type height =
  | Full
  | Squashed

type selection =
  | Unselectable
  | Selectable
  | Holds_selected_row

type squash =
  | By_selection of selection
  | Owns_keyboard

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
  | At_least rows -> Value.Count.lower_bound rows

(* Zone 2's position counts a focused list, so its card does not. A focused
   card that is not a list keeps its count: zone 2 counts something else. *)
let shown_count edge =
  match edge.focus with
  | Focused_list -> None
  | Focused_other | Unfocused -> edge.count

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
  (* Whether [left] fits, beside the count when [count] keeps it. *)
  let fits ~left ~count =
    let count_cells = if count then count_cells else 0 in
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
  let kept ?(symbol = true) ?(count = true) ~key ~name ~word () =
    { key_kept = key && key_cells > 0
    ; name_kept = name
    ; word_kept = word && word_cells > 0
    ; symbol_kept = symbol && symbol_cells > 0
    ; count_kept = count && count_cells > 0
    }
  in
  let whole ~key =
    joined_cells
      [ (if key then key_cells else 0); name_cells; symbol_cells; word_cells ]
  in
  (* With no name left the symbol and the count are all the edge holds: both
     when they fit together, then the symbol alone, then the count alone for
     an edge with no symbol. *)
  let tail () =
    match
      List.find_opt
        (fun (symbol, count) ->
           fits ~left:(if symbol then symbol_cells else 0) ~count)
        [ (true, true); (true, false); (false, true) ]
    with
    | Some (symbol, count) -> kept ~symbol ~count ~key:false ~name:No_name ~word:false ()
    | None -> bare
  in
  if fits ~left:(whole ~key:true) ~count:true then
    kept ~key:true ~name:Whole_name ~word:true ()
  else if fits ~left:(whole ~key:false) ~count:true then
    kept ~key:false ~name:Whole_name ~word:true ()
  else
    match name_beside [ symbol_cells; word_cells ] with
    | Some name -> kept ~key:false ~name ~word:true ()
    | None -> (
        match name_beside [ symbol_cells ] with
        | Some name -> kept ~key:false ~name ~word:false ()
        | None -> tail ())

let border_style ~style = function
  | Focused_list | Focused_other -> style.focused_border
  | Unfocused -> style.border

(* The ends of a squashed card are half rules, after lazygit's squashed frame:
   a row with corners would read as a box that never closes, and the half
   rules tell it from a full card's top edge without colour. Each is one cell,
   as a corner is, so both shapes keep the same {!top_fit}. *)
let squashed_start = "\xe2\x95\xb6" (* ╶ *)
let squashed_end = "\xe2\x95\xb4" (* ╴ *)

let edge_ends = function
  | Full -> (Box.tl_round, Box.tr_round)
  | Squashed -> (squashed_start, squashed_end)

(* [shape] is the card's height: a full card's top edge, or the one row of a
   squashed card. Both say the same things in the same places. *)
let top_edge ~ko ~style ~width ~shape edge =
  let start, finish = edge_ends shape in
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
  let opening = start ^ Box.h in
  let closing = Box.h ^ finish in
  match left_cells > 0, count with
  | false, None -> paint border (start ^ repeat Box.h (width - 2) ^ finish)
  | true, None ->
      paint border (opening ^ " ") ^ left
      ^ paint border (" " ^ repeat Box.h (width - left_cells - left_only_cells) ^ finish)
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

let bottom_fit ~ko ~width ~hidden =
  let room = width - bottom_text_cells in
  if hidden <= 0 then Plain
  else if cells (Value.Count.more ~ko hidden) <= room then Says_more
  else if cells (Value.Count.grouped hidden) <= room then Number_only
  else Plain

let bottom_edge ~ko ~border ~reset ~width hidden =
  let paint text = border ^ text ^ reset in
  let with_text text =
    paint
      (Box.bl_round
       ^ repeat Box.h (width - cells text - bottom_text_cells + 1)
       ^ " " ^ text ^ " " ^ Box.h ^ Box.br_round)
  in
  match bottom_fit ~ko ~width ~hidden with
  | Says_more -> with_text (Value.Count.more ~ko hidden)
  | Number_only -> with_text (Value.Count.grouped hidden)
  | Plain -> paint (Box.bl_round ^ repeat Box.h (width - 2) ^ Box.br_round)

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
    (top_edge ~ko ~style ~width ~shape:Full edge
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

(* A squashed card is its top edge alone. *)
let squashed_rows = 1

let stack_height ~row_gap heights =
  List.fold_left ( + ) 0 heights + (row_gap * max 0 (List.length heights - 1))

(* A focused card owns the keyboard; the selection reaches any other card as
   its caller says. *)
let squash_of card selection =
  match card.edge.focus with
  | Focused_list | Focused_other -> Owns_keyboard
  | Unfocused -> By_selection selection

(* {!heights} over any card: [natural] and [squash] read what it needs, and
   each card comes back with its height, so the caller never zips two lists. *)
let choose_heights ~row_gap ~max_rows ~natural ~squash columns =
  let fits rows = stack_height ~row_gap rows <= max_rows in
  let full_now card =
    match squash card with
    | Owns_keyboard | By_selection Holds_selected_row -> true
    | By_selection (Selectable | Unselectable) -> false
  in
  (* The rows a card takes when its column squashes all it may now. *)
  let least card = if full_now card then natural card else squashed_rows in
  (* The column with the selection on the card at [opened], or on no card:
     that card and the focused ones full, every other card squashed. *)
  let with_selection_on ~opened column =
    List.mapi
      (fun index card ->
         match squash card with
         | Owns_keyboard -> natural card
         | By_selection (Holds_selected_row | Selectable) ->
             if Option.equal Int.equal opened (Some index) then natural card
             else squashed_rows
         | By_selection Unselectable -> squashed_rows)
      column
  in
  let reachable card =
    match squash card with
    | By_selection (Holds_selected_row | Selectable) -> true
    | By_selection Unselectable | Owns_keyboard -> false
  in
  (* Wherever the selection goes, the column still fits. *)
  let fits_every_selection column =
    match
      List.concat (List.mapi (fun index card -> if reachable card then [ index ] else []) column)
    with
    | [] -> fits (with_selection_on ~opened:None column)
    | reached ->
        List.for_all (fun index -> fits (with_selection_on ~opened:(Some index) column)) reached
  in
  (* Top card first: a card is full when it fits with the cards above as
     settled and every card under it at its least. Each step keeps the column
     inside [max_rows] when its least does, so the settled column does too. *)
  let settle column =
    let rec down ~above = function
      | [] -> []
      | card :: below ->
          let shape =
            if full_now card || fits (List.rev_append above (natural card :: List.map least below))
            then Full
            else Squashed
          in
          let rows = match shape with Full -> natural card | Squashed -> squashed_rows in
          (card, shape) :: down ~above:(rows :: above) below
    in
    down ~above:[] column
  in
  (* The least checks the cards full now together: two cards that each hold
     the selected row would both stay full. *)
  let column_fits column = fits_every_selection column && fits (List.map least column) in
  if List.for_all column_fits columns then Some (List.map settle columns) else None

let heights ~row_gap ~max_rows columns =
  choose_heights ~row_gap ~max_rows ~natural:fst ~squash:snd columns
  |> Option.map (List.map (List.map snd))

(* Each card of a column with its squash and its body, the body asked once at
   the column's width. *)
let prepare_column ~width stack =
  List.map
    (fun (card, selection) ->
       (card, squash_of card selection, card.body ~cells:(content_cells ~width)))
    stack

let drawn_height ~body = function
  | Full -> natural_height body
  | Squashed -> squashed_rows

let squashed_row ~ko ~style ~width edge =
  if width < min_width then blank width
  else top_edge ~ko ~style ~width ~shape:Squashed edge

(* The lowest full card of a column takes whatever the column lacks against
   the tallest, so every column ends on the same row. A column with no full
   card ends in blank rows. *)
let column_rows ~ko ~style ~row_gap ~width ~height placed =
  let used =
    stack_height ~row_gap (List.map (fun ((_, _, body), shape) -> drawn_height ~body shape) placed)
  in
  let extra = max 0 (height - used) in
  let stretched =
    List.fold_left
      (fun (index, found) (_, shape) ->
         match shape with
         | Full -> (index + 1, Some index)
         | Squashed -> (index + 1, found))
      (0, None) placed
    |> snd
  in
  let drawn =
    List.mapi
      (fun index ((card, _, body), shape) ->
         match shape with
         | Squashed -> [ squashed_row ~ko ~style ~width card.edge ]
         | Full ->
             let stretch = if Option.equal Int.equal (Some index) stretched then extra else 0 in
             render_body ~ko ~style ~width ~height:(natural_height body + stretch) card.edge body)
      placed
  in
  let gap_rows = List.init row_gap (fun _ -> blank width) in
  let foot =
    match stretched with
    | Some _ -> []
    | None -> List.init extra (fun _ -> blank width)
  in
  List.concat
    (List.mapi (fun index rows -> if index = 0 then rows else gap_rows @ rows) drawn)
  @ foot

let grid ~ko ~style ~inner_width ~gap ~row_gap ~max_rows columns =
  let count = List.length columns in
  let width index = column_width ~inner_width ~gap ~columns:count ~index in
  let prepared =
    List.mapi (fun index stack -> prepare_column ~width:(width index) stack) columns
  in
  let planned =
    choose_heights ~row_gap ~max_rows
      ~natural:(fun (_, _, body) -> natural_height body)
      ~squash:(fun (_, squash, _) -> squash)
      prepared
  in
  match planned with
  | None -> None
  | Some plan ->
      let column_height placed =
        stack_height ~row_gap
          (List.map (fun ((_, _, body), shape) -> drawn_height ~body shape) placed)
      in
      let height = List.fold_left (fun tallest placed -> max tallest (column_height placed)) 0 plan in
      let drawn =
        List.mapi
          (fun index placed ->
             let width = width index in
             match placed with
             (* A column with no cards is blank rows of its width. *)
             | [] -> List.init height (fun _ -> blank width)
             | _ :: _ -> column_rows ~ko ~style ~row_gap ~width ~height placed)
          plan
      in
      let rec zip rows =
        if List.for_all (function [] -> true | _ :: _ -> false) rows then []
        else
          let heads = List.map (function [] -> "" | head :: _ -> head) rows in
          let tails = List.map (function [] -> [] | _ :: tail -> tail) rows in
          String.concat (blank gap) heads :: zip tails
      in
      Some (zip drawn)
