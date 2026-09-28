(* One table row's cells.

   A screen describes its columns once -- the order, the width and the
   alignment -- and its header and every data row are drawn from that one
   description. Nothing here knows what any screen shows. It knows one thing:
   a header and the rows under it must not be able to disagree about where a
   column is.

   That disagreement is what this was pulled out of. A screen printing its
   widths twice, once in the header's format string and once in the row's, has
   two copies of one layout, and printf's width is a floor rather than a width:
   a value longer than the field is printed whole and every cell after it moves
   right. On the live fleet the Memory table drew a keeper named in 24 cells
   against a field of 18, which put that row's remaining cells six columns off
   the headers naming them. *)

type align =
  | Left
  | Right

type fold =
  | Fold_middle
  | Fold_tail

type cell = {
  header : string;
  width : int;
  align : align;
  fold : fold;
  value : string;
  style : string;
}

let cell ?(align = Left) ?(fold = Fold_middle) ?(style = "") ~header ~width
    value =
  { header; width; align; fold; value; style }

(* A cell's dress closes back to the row's own, not to a bare reset: a reset
   would strip the dimming or the selection band the caller wrapped the whole
   row in, and the rest of the row after a coloured cell would come out
   undressed. *)
let default_close = "\027[0m"

(* One cell between columns, on every table on every screen.

   It used to be each table's own number. Nine of the ten picked one and the
   Memory table picked two, for no reason it recorded, so moving between two
   screens moved the columns under the reader's eye. A screen cannot pick its
   own any more: there is nothing to pass. *)
let cell_gap = 1
let separator = String.make cell_gap ' '

let used_width cells =
  List.fold_left (fun total cell -> total + cell.width) 0 cells
  + (cell_gap * max 0 (List.length cells - 1))

(* Which columns a table draws at a width, and what its one flexible column
   gets.

   A table with a column whose reading is a sentence sized that column as
   whatever the named columns left, never below a floor. Below the floor the
   row ran past the frame and the frame cut its tail: at eighty columns the
   Board title sat at its floor of twelve and the row ran six cells past the
   frame, so REPLIES was cut away, while the id column beside the title kept
   every one of its twelve. Nothing said which of
   the columns mattered less, so the one that gave way was whichever sat last.

   A table now says it. Its columns are its own closed variant; [drop_order]
   names the ones that may go, first to go first. Columns it does not name,
   and the flexible one, stay. The flexible column counts at its floor while
   the table decides what fits and takes every cell the others leave. When
   everything that may go has gone and the rest still does not fit, the
   flexible column stays at its floor and the row is wider than the space,
   which is what the frame's cut is left for.

   Columns are compared as values of the table's variant, the way a match
   would read them; no header text is involved. *)
type 'col layout = {
  shown : 'col list;
  flex_width : int;
}

let fit ~inner_width ~width ~flex ~drop_order columns =
  let needs shown =
    List.fold_left (fun total col -> total + width col) 0 shown
    + (cell_gap * max 0 (List.length shown - 1))
  in
  let rec settle shown = function
    | [] -> shown
    | next :: later ->
        if needs shown <= inner_width then shown
        else if next = flex then settle shown later
        else settle (List.filter (fun col -> col <> next) shown) later
  in
  let shown = settle columns drop_order in
  let others =
    List.fold_left
      (fun total col -> if col = flex then total else total + width col)
      0 shown
  in
  let gaps = cell_gap * max 0 (List.length shown - 1) in
  { shown; flex_width = max (width flex) (inner_width - others - gaps) }

(* Where a reading gives way is the column's choice. An identifier keeps both
   ends and folds in the middle: cut at the head it reads as a different
   identifier, and a number cut at either end is a wrong number. A sentence
   keeps its head and gives way at the tail, because it is read from the front
   and its subject is there.

   Only a reading that overruns its column is folded. [fit_middle] pads a short
   reading out to the column on the left, which left no slack for this to place
   and made {!Right} a column that declared an alignment it never got: every
   count and size drew flush left under a right-aligned name. *)
let pad cell text =
  let fitted =
    if Masc_tui_message_layout.display_width text <= cell.width then text
    else
      match cell.fold with
      | Fold_middle -> Masc_tui_message_layout.fit_middle cell.width text
      | Fold_tail -> Masc_tui_message_layout.fit_width text cell.width
  in
  let slack =
    max 0 (cell.width - Masc_tui_message_layout.display_width fitted)
  in
  match cell.align with
  | Left -> fitted ^ String.make slack ' '
  | Right -> String.make slack ' ' ^ fitted

let line ~pick ~dress cells =
  String.concat separator
    (List.map (fun cell -> dress cell (pad cell (pick cell))) cells)

(* Column names carry no reading, so they carry no reading's colour. The header
   wears whatever the caller dressed the line in. *)
let header_row cells =
  line ~pick:(fun cell -> cell.header) ~dress:(fun _ text -> text) cells

let row ?(close = default_close) cells =
  line
    ~pick:(fun cell -> cell.value)
    ~dress:(fun cell text ->
      if String.equal cell.style "" then text else cell.style ^ text ^ close)
    cells
