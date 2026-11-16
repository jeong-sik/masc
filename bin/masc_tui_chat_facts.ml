module Layout = Masc_tui_message_layout

type 'reading tone =
  | Who
  | Amount
  | Reading of 'reading
  | Plain

type 'reading t =
  { label : string
  ; value : string
  ; tone : 'reading tone
  }

let fact ?(label = "") tone value = { label; value; tone }

type 'reading piece =
  | Label of string
  | Value of 'reading tone * string
  | Separator
  | More of string

let separator = " \xc2\xb7 "
let separator_cells = Layout.display_width separator

type 'reading layout =
  { rows : 'reading piece list list
  ; omitted : int
  ; cut : bool
  }

(* What a row holds: a fact, or the mark that says how many are not drawn. *)
type 'reading item =
  | Fact of 'reading t
  | Mark of string

let piece_text = function
  | Label text | Value (_, text) | More text -> text
  | Separator -> separator

let text row = String.concat "" (List.map piece_text row)

let item_pieces = function
  | Fact { label = ""; value; tone } -> [ Value (tone, value) ]
  | Fact { label; value; tone } -> [ Label label; Value (tone, value) ]
  | Mark text -> [ More text ]

let row_cells row = Layout.display_width (text row)

(* An item wider than a whole row. Its label and the head of its value take
   the first row, the value's remainder takes whole rows, and the last part
   is returned like any other row so the next item can share it. *)
let broken_rows ~max_cells item =
  let value_rows tone text =
    List.map (fun chunk -> [ Value (tone, chunk) ]) (Layout.split_cells ~max_cells text)
  in
  match item with
  | Mark text ->
    List.map (fun chunk -> [ More chunk ]) (Layout.split_cells ~max_cells text)
  | Fact { label; value; tone } ->
    let label_cells = Layout.display_width label in
    if label_cells = 0 || label_cells >= max_cells
    then value_rows tone (label ^ value)
    else (
      let head, rest =
        Layout.split_cells_after_prefix
          ~prefix_cells:(max_cells - label_cells)
          ~max_cells
          value
      in
      [ Label label; Value (tone, head) ]
      :: List.map (fun chunk -> [ Value (tone, chunk) ]) rest)

(* Rows are filled in order and never revisited: an item joins the open row
   when it fits after a separator, and otherwise starts the next one. [closed]
   holds finished rows newest first; [open_row] holds the growing row's pieces
   newest first. *)
let fill ~max_cells items =
  let close (closed, open_row, _) =
    match open_row with
    | [] -> closed
    | _ :: _ -> List.rev open_row :: closed
  in
  let place ((closed, open_row, cells) as state) item =
    let width = row_cells (item_pieces item) in
    match open_row with
    | _ :: _ when cells + separator_cells + width <= max_cells ->
      ( closed
      , List.rev_append (item_pieces item) (Separator :: open_row)
      , cells + separator_cells + width )
    | [] | _ :: _ ->
      if width <= max_cells
      then close state, List.rev (item_pieces item), width
      else (
        match List.rev (broken_rows ~max_cells item) with
        | [] -> state
        | last :: earlier -> earlier @ close state, List.rev last, row_cells last)
  in
  List.fold_left place ([], [], 0) items |> close |> List.rev

let facts_as_items facts = List.map (fun fact -> Fact fact) facts

(* A fact with no text has nothing to draw. Left in, it would still take a
   separator, and a row could begin with one. *)
let said facts =
  List.filter
    (fun fact -> not (String.equal fact.label "" && String.equal fact.value ""))
    facts

let rows_wanted ~max_cells facts =
  List.length (fill ~max_cells:(Int.max 1 max_cells) (facts_as_items (said facts)))

let cut_mark = "\xe2\x80\xa6"

let cut_to ~cells text =
  fst (Layout.split_cells_after_prefix ~prefix_cells:cells ~max_cells:(Int.max 1 cells) text)

(* The head of a fact wider than a row, in [cells] cells. *)
let head_pieces ~cells { label; value; tone } =
  let label_cells = Layout.display_width label in
  if label_cells = 0 || label_cells >= cells
  then [ Value (tone, cut_to ~cells (label ^ value)) ]
  else [ Label label; Value (tone, cut_to ~cells:(cells - label_cells) value) ]

(* [kept] whole facts, then as much of the fact after them as the rows left
   hold, its cut marked, then the count of the [after] facts behind it. The
   fact is wider than a row, so it is drawn in pieces whatever the cap is;
   dropping it for a count would hide a failed turn's message behind a
   number. [None] when no row has room for a head. *)
let cut_rows ~max_cells ~max_rows ~more ~after kept long =
  let tail = More cut_mark :: (if after > 0 then [ Separator; More (more after) ] else []) in
  let room = max_cells - row_cells tail in
  let before = fill ~max_cells (facts_as_items kept) in
  let rows_left = max_rows - List.length before in
  if rows_left > 0
  then (
    (* On rows of its own, as an uncapped block lays it out. *)
    let pieces = broken_rows ~max_cells (Fact long) in
    let whole_rows = List.take (rows_left - 1) pieces in
    if room < 1 || List.compare_length_with pieces rows_left < 0
    then None
    else (
      let last =
        match whole_rows, List.nth_opt pieces (rows_left - 1) with
        | [], (Some _ | None) -> Some (head_pieces ~cells:room long)
        | _ :: _, Some [ Value (tone, chunk) ] -> Some [ Value (tone, cut_to ~cells:room chunk) ]
        | _ :: _, (Some ([] | [ (Label _ | Separator | More _) ] | _ :: _ :: _) | None) -> None
      in
      Option.map (fun last -> before @ whole_rows @ [ last @ tail ]) last))
  else (
    (* No row of its own: its head shares the last row when a cell of it
       fits there. *)
    match List.rev before with
    | [] -> None
    | last :: earlier ->
      let cells = room - row_cells last - separator_cells in
      if cells < 1
      then None
      else Some (List.rev earlier @ [ last @ (Separator :: head_pieces ~cells long) @ tail ]))

let layout ~max_cells ~max_rows ~more facts =
  let facts = said facts in
  let max_cells = Int.max 1 max_cells in
  let uncapped = fill ~max_cells (facts_as_items facts) in
  if List.compare_length_with uncapped max_rows <= 0
  then { rows = uncapped; omitted = 0; cut = false }
  else if max_rows <= 0
  then { rows = []; omitted = List.length facts; cut = false }
  else (
    let total = List.length facts in
    (* The longest leading run of whole facts that fits with the mark behind
       it. The mark alone is the shortest run and ends the search. *)
    let rec capped kept =
      let omitted = total - kept in
      let rows =
        fill ~max_cells (facts_as_items (List.take kept facts) @ [ Mark (more omitted) ])
      in
      if kept = 0 || List.compare_length_with rows max_rows <= 0
      then { rows = List.take max_rows rows; omitted; cut = false }
      else capped (kept - 1)
    in
    let whole = capped (total - 1) in
    let kept = total - whole.omitted in
    match List.nth_opt facts kept with
    | Some next when row_cells (item_pieces (Fact next)) > max_cells ->
      let after = total - kept - 1 in
      (match cut_rows ~max_cells ~max_rows ~more ~after (List.take kept facts) next with
       | Some rows -> { rows; omitted = after; cut = true }
       | None -> whole)
    | Some _ | None -> whole)

type 'reading palette =
  { label_style : string
  ; who_style : string
  ; amount_style : string
  ; reading_style : 'reading -> string
  ; reset : string
  }

let draw palette row =
  let span style text =
    if String.equal style "" then text else style ^ text ^ palette.reset
  in
  String.concat
    ""
    (List.map
       (function
         | Label text | More text -> span palette.label_style text
         | Separator -> span palette.label_style separator
         | Value (Who, text) -> span palette.who_style text
         | Value (Amount, text) -> span palette.amount_style text
         | Value (Reading reading, text) -> span (palette.reading_style reading) text
         | Value (Plain, text) -> text)
       row)
